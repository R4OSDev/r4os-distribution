const std = @import("std");
const artifact = @import("r4u_artifact");
const contract = artifact.contract;

const checksum_seed: u32 = 2166136261;
const stream_buffer_bytes = 64 * 1024;
// SYSUPD and UPDSVC stream through bounded buffers, but their file offsets
// still use the R4SYS u32 interface. Bound the complete package, including
// its envelope, instead of rejecting firmware-bearing modules above 32 MB.
const maximum_package_bytes: u64 = std.math.maxInt(u32);

const Payload = struct {
    src: []const u8,
    target: []const u8,
    canonical_target: []u8,
    kind: []const u8,
    name: []const u8,
    file: std.Io.File,
    size: u64,
    modified: std.Io.Timestamp,
    offset: u64,
    checksum: u32,
    component: ?artifact.Identity,
};

const Requirement = struct {
    kind: contract.ComponentKind,
    name: []const u8,
    target: []u8,
    version: []const u8,
    state: contract.RequirementState,
};

const Options = struct {
    output: []const u8 = "",
    package: []const u8 = "",
    package_version: []const u8 = "",
    release: []const u8 = "",
    title: []const u8 = "",
    description_file: []const u8 = "",
    activation_assert: ?contract.InstallMode = null,
    priority_assert: ?contract.Priority = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var opts: Options = .{};
    var payload_specs: std.ArrayList([]const u8) = .empty;
    defer payload_specs.deinit(allocator);
    var requirement_specs: std.ArrayList([]const u8) = .empty;
    defer requirement_specs.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return usage("missing --output value");
            opts.output = args[i];
        } else if (std.mem.eql(u8, arg, "--package")) {
            i += 1;
            if (i >= args.len) return usage("missing --package value");
            opts.package = args[i];
        } else if (std.mem.eql(u8, arg, "--version")) {
            i += 1;
            if (i >= args.len) return usage("missing --version value");
            opts.package_version = args[i];
        } else if (std.mem.eql(u8, arg, "--release")) {
            i += 1;
            if (i >= args.len) return usage("missing --release value");
            opts.release = args[i];
        } else if (std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i >= args.len) return usage("missing --title value");
            opts.title = args[i];
        } else if (std.mem.eql(u8, arg, "--description-file")) {
            i += 1;
            if (i >= args.len) return usage("missing --description-file value");
            opts.description_file = args[i];
        } else if (std.mem.eql(u8, arg, "--activation")) {
            i += 1;
            if (i >= args.len) return usage("missing --activation value");
            opts.activation_assert = contract.InstallMode.parse(args[i]) orelse return usage("invalid --activation");
        } else if (std.mem.eql(u8, arg, "--priority")) {
            i += 1;
            if (i >= args.len) return usage("missing --priority value");
            opts.priority_assert = contract.Priority.parse(args[i]) orelse return usage("invalid --priority");
        } else if (std.mem.eql(u8, arg, "--payload")) {
            i += 1;
            if (i >= args.len) return usage("missing --payload value");
            if (payload_specs.items.len >= contract.max_package_payloads) return usage("at most 32 payloads are supported");
            try payload_specs.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--require")) {
            i += 1;
            if (i >= args.len) return usage("missing --require value");
            if (requirement_specs.items.len >= contract.max_package_payloads) return usage("at most 32 requirements are supported");
            try requirement_specs.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "/?")) {
            try printUsage();
            return;
        } else {
            std.debug.print("R4UPack: unknown argument: {s}\n", .{arg});
            return error.BadArgument;
        }
    }

    if (opts.output.len == 0) return usage("missing --output");
    if (payload_specs.items.len == 0) return usage("at least one --payload is required");
    if (!contract.validToken(opts.package, contract.package_name_max_bytes) or
        !contract.validSemanticVersion(opts.package_version) or
        !contract.validSemanticVersion(opts.release) or
        !contract.validDisplayText(opts.title, contract.title_max_bytes) or
        opts.description_file.len == 0)
    {
        return usage("bad or missing package metadata");
    }

    const description_storage = try cwd.readFileAlloc(io, opts.description_file, allocator, .limited(contract.description_max_bytes + 5));
    defer allocator.free(description_storage);
    const description = stripSingleLineEnding(stripUtf8Bom(description_storage));
    if (!contract.validDisplayText(description, contract.description_max_bytes)) return usage("description file is not valid bounded plain UTF-8 text");

    var payloads: std.ArrayList(Payload) = .empty;
    defer payloads.deinit(allocator);
    defer for (payloads.items) |payload| {
        payload.file.close(io);
        allocator.free(payload.canonical_target);
    };

    var payload_offset: u64 = 0;
    var derived_class: contract.DerivedClass = .{};
    var component_count: usize = 0;
    var has_unversioned_payload = false;
    var scratch: [stream_buffer_bytes]u8 = undefined;
    for (payload_specs.items) |spec| {
        var payload = try parsePayloadSpec(allocator, cwd, io, spec, &scratch);
        errdefer payload.file.close(io);
        errdefer allocator.free(payload.canonical_target);
        payload.offset = payload_offset;
        payload_offset = std.math.add(u64, payload_offset, payload.size) catch return error.PackageTooLarge;
        if (payload.component) |identity| {
            contract.includeComponent(&derived_class, identity.kind, payload.canonical_target);
            component_count += 1;
        } else {
            has_unversioned_payload = true;
        }
        try payloads.append(allocator, payload);
    }
    try validateUniquePayloads(payloads.items);
    if (opts.activation_assert) |expected| {
        if (expected != derived_class.activation) return usage("--activation contradicts contained components");
    }
    if (opts.priority_assert) |expected| {
        if (expected != derived_class.priority) return usage("--priority contradicts contained components");
    }

    var requirements: std.ArrayList(Requirement) = .empty;
    defer requirements.deinit(allocator);
    defer for (requirements.items) |requirement| allocator.free(requirement.target);
    for (requirement_specs.items) |spec| {
        const requirement = try parseRequirement(allocator, spec);
        errdefer allocator.free(requirement.target);
        try requirements.append(allocator, requirement);
    }
    try validateUniqueRequirements(requirements.items);
    if (has_unversioned_payload and requirements.items.len == 0) {
        return usage("configuration, font and SDK payloads require at least one concrete component requirement");
    }

    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(allocator);
    try buildManifest(allocator, &manifest, opts, description, derived_class, payloads.items, component_count, requirements.items);
    if (manifest.items.len > contract.manifest_max_bytes) return error.ManifestTooLarge;

    const package_hash = try writePackage(cwd, io, opts.output, manifest.items, payloads.items, payload_offset, derived_class.activation == .restart, &scratch);
    std.debug.print(
        "R4U2 created: {s} release={s} package-version={s} payloads={d} components={d} activation={s} priority={s} checksum={d}\n",
        .{
            opts.output,
            opts.release,
            opts.package_version,
            payloads.items.len,
            component_count,
            derived_class.activation.text(),
            derived_class.priority.text(),
            package_hash,
        },
    );
}

fn writePackage(cwd: std.Io.Dir, io: std.Io, output_path: []const u8, manifest: []const u8, payloads: []const Payload, payload_size: u64, reboot: bool, scratch: []u8) !u32 {
    if (manifest.len > maximum_package_bytes - contract.header_size or
        payload_size > maximum_package_bytes - contract.header_size - manifest.len)
        return error.PackageTooLarge;
    // The final path changes only after all source bytes and hashes agree.
    // An I/O error or a source changed between passes preserves prior output.
    var output = try cwd.createFileAtomic(io, output_path, .{ .replace = true });
    defer output.deinit(io);
    try output.file.writePositionalAll(io, manifest, contract.header_size);
    var writer = PackageWriter{
        .file = output.file,
        .io = io,
        .offset = contract.header_size + manifest.len,
        .package_hash = checksum(manifest),
    };
    for (payloads) |payload| {
        try validateSource(payload, io);
        const streamed = try streamPayload(FileReader{ .file = payload.file, .io = io }, &writer, payload.size, scratch);
        if (streamed != payload.checksum) return error.SourceChanged;
        try validateSource(payload, io);
    }
    var header: [contract.header_size]u8 = undefined;
    writeHeader(
        &header,
        manifest.len,
        payload_size,
        checksum(manifest),
        writer.payload_hash,
        writer.package_hash,
        @intCast(payloads.len),
        reboot,
    );
    try output.file.writePositionalAll(io, &header, 0);
    try output.file.sync(io);
    try output.replace(io);
    return writer.package_hash;
}

const FileReader = struct {
    file: std.Io.File,
    io: std.Io,

    pub fn readAt(self: FileReader, offset: u64, out: []u8) bool {
        const got = self.file.readPositionalAll(self.io, out, offset) catch return false;
        return got == out.len;
    }
};

const DiscardWriter = struct {
    pub fn writeAll(_: DiscardWriter, _: []const u8) !void {}
};

const PackageWriter = struct {
    file: std.Io.File,
    io: std.Io,
    offset: u64,
    payload_hash: u32 = checksum_seed,
    package_hash: u32,

    pub fn writeAll(self: *PackageWriter, bytes: []const u8) !void {
        try self.file.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
        self.payload_hash = checksumUpdate(self.payload_hash, bytes);
        self.package_hash = checksumUpdate(self.package_hash, bytes);
    }
};

fn streamPayload(reader: anytype, writer: anytype, size: u64, scratch: []u8) !u32 {
    std.debug.assert(scratch.len != 0);
    var offset: u64 = 0;
    var hash = checksum_seed;
    while (offset < size) {
        const count: usize = @intCast(@min(scratch.len, size - offset));
        const bytes = scratch[0..count];
        if (!reader.readAt(offset, bytes)) return error.SourceReadFailed;
        try writer.writeAll(bytes);
        hash = checksumUpdate(hash, bytes);
        offset += count;
    }
    return hash;
}

fn validateSource(payload: Payload, io: std.Io) !void {
    const stat = try payload.file.stat(io);
    if (stat.size != payload.size or stat.mtime.nanoseconds != payload.modified.nanoseconds) return error.SourceChanged;
}

fn usage(reason: []const u8) !void {
    std.debug.print("R4UPack: {s}\n", .{reason});
    try printUsage();
    return error.BadArgument;
}

fn printUsage() !void {
    std.debug.print(
        \\Usage:
        \\  r4upack --output FILE.R4U --package ID --version X.Y.Z --release X.Y.Z --title TEXT --description-file UTF8.TXT [--activation live|restart] [--priority normal|foundation] --payload SRC|TARGET|KIND [--require KIND|NAME|TARGET|MIN_VERSION|installed|active ...]
        \\
        \\Versioned payload KIND values are boot-kernel, system-library, driver, protocol, service and software.
        \\R4UPack reads component identity and version from the ELF/R4M0 artifact. Font, config and sdk payloads carry no invented component version and require a concrete --require.
        \\At most 32 payloads and 32 requirements, a 32-KB manifest and 4294967295 bytes per complete package are supported. Payloads stream through a 64-KB buffer.
        \\The data kind and foreign-drive targets are not supported by R4UPack.
        \\
    , .{});
}

fn parsePayloadSpec(allocator: std.mem.Allocator, cwd: std.Io.Dir, io: std.Io, spec_raw: []const u8, scratch: []u8) !Payload {
    const spec = std.mem.trim(u8, spec_raw, " \t\r\n");
    const first = std.mem.indexOfScalar(u8, spec, '|') orelse return error.BadPayloadSpec;
    const second = std.mem.indexOfScalarPos(u8, spec, first + 1, '|') orelse return error.BadPayloadSpec;
    if (std.mem.indexOfScalarPos(u8, spec, second + 1, '|') != null) return error.BadPayloadSpec;
    const src = std.mem.trim(u8, spec[0..first], " \t\r\n");
    const target = std.mem.trim(u8, spec[first + 1 .. second], " \t\r\n");
    const kind_raw = std.mem.trim(u8, spec[second + 1 ..], " \t\r\n");
    if (src.len == 0 or target.len == 0 or kind_raw.len == 0) return error.BadPayloadSpec;
    if (std.ascii.eqlIgnoreCase(kind_raw, "data") or isForeignDriveTarget(target)) return error.UnsupportedDataPayload;
    if (!validTarget(target)) return error.BadTargetPath;
    const kind = if (std.ascii.eqlIgnoreCase(kind_raw, "auto")) kindFromTarget(target) else kind_raw;
    if (!validKind(kind) or !kindMatchesTarget(kind, target)) return error.KindTargetMismatch;

    var target_buffer: [1024]u8 = undefined;
    const canonical = contract.canonicalInventoryTarget(target_buffer[0..], target) orelse return error.BadTargetPath;
    const canonical_owned = try allocator.dupe(u8, canonical);
    errdefer allocator.free(canonical_owned);
    if (contract.isManagedStateTarget(canonical_owned)) return error.ManagedStatePayloadForbidden;

    const file = try cwd.openFile(io, src, .{});
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.PayloadNotFile;
    if (stat.size > maximum_package_bytes - contract.header_size) return error.PayloadTooLarge;
    const reader = FileReader{ .file = file, .io = io };

    var identity: ?artifact.Identity = null;
    if (contract.componentKindForPayload(kind, canonical_owned)) |expected_kind| {
        const inspected = artifact.inspect(reader, stat.size) orelse return error.MissingArtifactIdentity;
        if (inspected.kind != expected_kind) return error.ArtifactKindMismatch;
        const expected_name = componentNameFromTarget(target, expected_kind);
        if (!std.ascii.eqlIgnoreCase(expected_name, inspected.nameText())) return error.ArtifactNameMismatch;
        identity = inspected;
    }

    const result: Payload = .{
        .src = src,
        .target = target,
        .canonical_target = canonical_owned,
        .kind = kind,
        .name = baseName(target),
        .file = file,
        .size = stat.size,
        .modified = stat.mtime,
        .offset = 0,
        .checksum = try streamPayload(reader, DiscardWriter{}, stat.size, scratch),
        .component = identity,
    };
    try validateSource(result, io);
    return result;
}

fn parseRequirement(allocator: std.mem.Allocator, spec_raw: []const u8) !Requirement {
    var fields: [5][]const u8 = undefined;
    var field_count: usize = 0;
    var split = std.mem.splitScalar(u8, std.mem.trim(u8, spec_raw, " \t\r\n"), '|');
    while (split.next()) |field_raw| {
        if (field_count >= fields.len) return error.BadRequirementSpec;
        fields[field_count] = std.mem.trim(u8, field_raw, " \t\r\n");
        field_count += 1;
    }
    if (field_count != fields.len) return error.BadRequirementSpec;
    const kind = contract.ComponentKind.parse(fields[0]) orelse return error.BadRequirementKind;
    if (!contract.validToken(fields[1], contract.component_name_max_bytes)) return error.BadRequirementName;
    if (!contract.validSemanticVersion(fields[3])) return error.BadRequirementVersion;
    const state = contract.RequirementState.parse(fields[4]) orelse return error.BadRequirementState;
    if (state == .active and kind != .kernel) return error.BadRequirementState;
    var target_buffer: [1024]u8 = undefined;
    const canonical = contract.canonicalInventoryTarget(target_buffer[0..], fields[2]) orelse return error.BadRequirementTarget;
    if (!componentTargetMatchesKind(kind, canonical)) return error.BadRequirementTarget;
    return .{
        .kind = kind,
        .name = fields[1],
        .target = try allocator.dupe(u8, canonical),
        .version = fields[3],
        .state = state,
    };
}

fn validateUniquePayloads(payloads: []const Payload) !void {
    for (payloads, 0..) |payload, index| {
        for (payloads[0..index]) |prior| {
            if (contract.targetEquals(payload.canonical_target, prior.canonical_target)) {
                return error.DuplicatePayloadTarget;
            }
            const identity = payload.component orelse continue;
            const prior_identity = prior.component orelse continue;
            if (identity.kind == prior_identity.kind and
                std.ascii.eqlIgnoreCase(identity.nameText(), prior_identity.nameText()))
            {
                return error.DuplicateComponent;
            }
        }
    }
}

fn validateUniqueRequirements(requirements: []const Requirement) !void {
    for (requirements, 0..) |requirement, index| {
        for (requirements[0..index]) |prior| {
            if (requirement.kind == prior.kind and
                std.ascii.eqlIgnoreCase(requirement.name, prior.name) and
                contract.targetEquals(requirement.target, prior.target) and
                requirement.state == prior.state)
            {
                return error.DuplicateRequirement;
            }
        }
    }
}

fn buildManifest(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    opts: Options,
    description: []const u8,
    derived_class: contract.DerivedClass,
    payloads: []const Payload,
    component_count: usize,
    requirements: []const Requirement,
) !void {
    try appendFmt(
        out,
        allocator,
        \\R4U_MANIFEST=2
        \\PACKAGE={s}
        \\PACKAGE_VERSION={s}
        \\RELEASE={s}
        \\TITLE={s}
        \\DESCRIPTION={s}
        \\ACTIVATION={s}
        \\PRIORITY={s}
        \\PAYLOADS={d}
        \\COMPONENTS={d}
        \\REQUIRES={d}
        \\ABI;R4M0=1;R4L=1;R4D=1;R4P=1;R4XSTART=1;R4U_COMPONENTS=1
        \\
    ,
        .{
            opts.package,
            opts.package_version,
            opts.release,
            opts.title,
            description,
            derived_class.activation.text(),
            derived_class.priority.text(),
            payloads.len,
            component_count,
            requirements.len,
        },
    );
    for (payloads, 0..) |payload, index| {
        try appendFmt(
            out,
            allocator,
            "PAYLOAD;index={d};name={s};target={s};kind={s};size={d};checksum={d};offset={d};abi=R4M0:1\n",
            .{ index, payload.name, payload.target, payload.kind, payload.size, payload.checksum, payload.offset },
        );
        if (isBootKernelTarget(payload.target)) {
            try appendFmt(out, allocator, "ROLLBACK;target={s};backup=/boot/r4os-prev.elf;strategy=replace\n", .{payload.target});
        } else {
            try appendFmt(out, allocator, "ROLLBACK;target={s};backup={s}.prev;strategy=replace\n", .{ payload.target, payload.target });
        }
    }
    for (payloads, 0..) |payload, index| {
        if (payload.component) |identity| {
            try appendFmt(
                out,
                allocator,
                "COMPONENT;payload={d};kind={s};name={s};target={s};version={s};install={s}\n",
                .{
                    index,
                    identity.kind.text(),
                    identity.nameText(),
                    payload.canonical_target,
                    identity.versionText(),
                    contract.installModeFor(identity.kind, payload.canonical_target).text(),
                },
            );
        }
    }
    for (requirements) |requirement| {
        try appendFmt(
            out,
            allocator,
            "REQUIRE;kind={s};name={s};target={s};version={s};state={s}\n",
            .{ requirement.kind.text(), requirement.name, requirement.target, requirement.version, requirement.state.text() },
        );
    }
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn writeHeader(
    out: []u8,
    manifest_len: usize,
    payload_len: u64,
    manifest_checksum: u32,
    payload_checksum: u32,
    package_checksum: u32,
    payload_count: u32,
    reboot: bool,
) void {
    @memset(out, 0);
    @memcpy(out[0..4], contract.header_magic);
    wU16(out, 4, contract.header_version);
    wU16(out, 6, contract.header_size);
    wU64(out, 8, manifest_len);
    wU64(out, 16, payload_len);
    wU32(out, 24, manifest_checksum);
    wU32(out, 28, payload_checksum);
    wU32(out, 32, package_checksum);
    wU32(out, 36, payload_count);
    wU32(out, 40, if (reboot) 1 else 0);
}

fn wU16(buf: []u8, off: usize, value: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], value, .little);
}

fn wU32(buf: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], value, .little);
}

fn wU64(buf: []u8, off: usize, value: u64) void {
    std.mem.writeInt(u64, buf[off..][0..8], value, .little);
}

fn checksum(data: []const u8) u32 {
    return checksumUpdate(checksum_seed, data);
}

fn checksumUpdate(seed: u32, data: []const u8) u32 {
    var out = seed;
    for (data) |byte| {
        out ^= byte;
        out *%= 16777619;
    }
    return out;
}

fn validTarget(value: []const u8) bool {
    if (value.len == 0 or value.len > 1023) return false;
    const drive_absolute = value.len >= 3 and std.ascii.isAlphabetic(value[0]) and value[1] == ':' and (value[2] == '\\' or value[2] == '/');
    if (!drive_absolute and value[0] != '\\' and value[0] != '/') return false;
    var start: usize = if (drive_absolute) 3 else 1;
    while (start < value.len) {
        while (start < value.len and (value[start] == '\\' or value[start] == '/')) : (start += 1) {}
        if (start >= value.len) break;
        var end = start;
        while (end < value.len and value[end] != '\\' and value[end] != '/') : (end += 1) {}
        const component = value[start..end];
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..") or component[component.len - 1] == ' ' or component[component.len - 1] == '.') return false;
        for (component) |byte| {
            if (byte < ' ' or byte == 0x7f or byte >= 0x80 or
                byte == '"' or byte == '*' or byte == ':' or byte == ';' or byte == '<' or byte == '>' or byte == '?' or byte == '|')
            {
                return false;
            }
        }
        start = end;
    }
    return true;
}

fn validKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "boot-kernel") or
        std.mem.eql(u8, kind, "system-library") or
        std.mem.eql(u8, kind, "driver") or
        std.mem.eql(u8, kind, "protocol") or
        std.mem.eql(u8, kind, "service") or
        std.mem.eql(u8, kind, "software") or
        std.mem.eql(u8, kind, "font") or
        std.mem.eql(u8, kind, "config") or
        std.mem.eql(u8, kind, "sdk");
}

fn kindFromTarget(target: []const u8) []const u8 {
    if (pathEquals(target, "/boot/r4os.elf") or pathEquals(target, "\\boot\\r4os.elf")) return "boot-kernel";
    if (pathEquals(target, "C:\\CONFIG.R4S")) return "config";
    if (pathHasPrefix(target, "C:\\R4OS\\LIBS\\") and std.ascii.endsWithIgnoreCase(target, ".R4L")) return "system-library";
    if (pathHasPrefix(target, "C:\\R4OS\\DRIVERS\\") and std.ascii.endsWithIgnoreCase(target, ".R4D")) return "driver";
    if (pathHasPrefix(target, "C:\\R4OS\\PROTOCOLS\\") and std.ascii.endsWithIgnoreCase(target, ".R4P")) return "protocol";
    if (pathHasPrefix(target, "C:\\R4OS\\SERVICES\\") and std.ascii.endsWithIgnoreCase(target, ".R4X")) return "service";
    if ((pathHasPrefix(target, "C:\\R4OS\\SOFTWARE\\") or pathHasPrefix(target, "C:\\SOFTWARE\\")) and std.ascii.endsWithIgnoreCase(target, ".R4X")) return "software";
    if (pathHasPrefix(target, "C:\\R4OS\\SUBSYSTEMS\\") and std.ascii.endsWithIgnoreCase(target, ".R4X")) return "software";
    if (pathHasPrefix(target, "C:\\R4OS\\FONTS\\") and std.ascii.endsWithIgnoreCase(target, ".R4F")) return "font";
    if (pathHasPrefix(target, "C:\\R4OS\\CONFIG\\")) return "config";
    if (pathHasPrefix(target, "C:\\R4OS\\SDK\\")) return "sdk";
    return "unknown";
}

fn isForeignDriveTarget(target: []const u8) bool {
    if (target.len < 4) return false;
    const letter = pathChar(target[0]);
    if (letter < 'A' or letter > 'Z' or letter == 'C') return false;
    return target[1] == ':' and (target[2] == '\\' or target[2] == '/');
}

fn kindMatchesTarget(kind: []const u8, target: []const u8) bool {
    return std.mem.eql(u8, kind, kindFromTarget(target));
}

fn componentTargetMatchesKind(kind: contract.ComponentKind, target: []const u8) bool {
    return switch (kind) {
        .kernel => contract.targetEquals(target, "/boot/r4os.elf"),
        .r4l => pathHasPrefix(target, "/R4OS/LIBS/") and std.ascii.endsWithIgnoreCase(target, ".R4L"),
        .r4d => pathHasPrefix(target, "/R4OS/DRIVERS/") and std.ascii.endsWithIgnoreCase(target, ".R4D"),
        .r4p => pathHasPrefix(target, "/R4OS/PROTOCOLS/") and std.ascii.endsWithIgnoreCase(target, ".R4P"),
        .r4x => target.len > 1 and target[0] == '/' and std.ascii.endsWithIgnoreCase(target, ".R4X"),
    };
}

fn componentNameFromTarget(target: []const u8, kind: contract.ComponentKind) []const u8 {
    if (kind == .kernel) return "KERNEL";
    const base = baseName(target);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return base[0..dot];
}

fn isBootKernelTarget(target: []const u8) bool {
    return std.mem.eql(u8, kindFromTarget(target), "boot-kernel");
}

test "subsystem R4X payloads use the software update class" {
    const target = "C:\\R4OS\\SUBSYSTEMS\\r4os.gb\\R4GB.R4X";
    try std.testing.expectEqualStrings("software", kindFromTarget(target));
    try std.testing.expect(kindMatchesTarget("software", target));
    try std.testing.expect(componentTargetMatchesKind(.r4x, "/R4OS/SUBSYSTEMS/r4os.gb/R4GB.R4X"));
    try std.testing.expectEqualStrings("unknown", kindFromTarget("C:\\R4OS\\SUBSYSTEMS\\r4os.gb\\README.TXT"));
}

test "stream chunks preserve bytes and stop on source or destination failure" {
    const Source = struct {
        bytes: []const u8,
        maximum_read: usize = 0,
        fail_at: ?u64 = null,
        pub fn readAt(self: *@This(), offset: u64, out: []u8) bool {
            self.maximum_read = @max(self.maximum_read, out.len);
            if (self.fail_at) |at| if (offset >= at) return false;
            @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
            return true;
        }
    };
    const Sink = struct {
        bytes: [129]u8 = undefined,
        used: usize = 0,
        fail_at: ?usize = null,
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            if (self.fail_at) |at| if (self.used >= at) return error.OutputFailed;
            @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
            self.used += bytes.len;
        }
    };
    var bytes: [129]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index * 37);
    var source = Source{ .bytes = &bytes };
    var sink = Sink{};
    var scratch: [17]u8 = undefined;
    try std.testing.expectEqual(checksum(&bytes), try streamPayload(&source, &sink, bytes.len, &scratch));
    try std.testing.expectEqualSlices(u8, &bytes, sink.bytes[0..sink.used]);
    try std.testing.expectEqual(@as(usize, 17), source.maximum_read);
    source.fail_at = 34;
    sink = .{};
    try std.testing.expectError(error.SourceReadFailed, streamPayload(&source, &sink, bytes.len, &scratch));
    try std.testing.expectEqual(@as(usize, 34), sink.used);
    source.fail_at = null;
    sink = .{ .fail_at = 34 };
    try std.testing.expectError(error.OutputFailed, streamPayload(&source, &sink, bytes.len, &scratch));
    try std.testing.expectEqual(@as(usize, 34), sink.used);
}

test "changed streamed source preserves the previous complete output" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "source.bin", .data = "original" });
    try temporary.dir.writeFile(io, .{ .sub_path = "output.r4u", .data = "previous-package" });
    var scratch: [17]u8 = undefined;
    var payload = try parsePayloadSpec(std.testing.allocator, temporary.dir, io, "source.bin|C:\\R4OS\\CONFIG\\TEST.R4S|config", &scratch);
    defer payload.file.close(io);
    defer std.testing.allocator.free(payload.canonical_target);
    try temporary.dir.writeFile(io, .{ .sub_path = "source.bin", .data = "modified" });
    // Keep the recorded mtime current to exercise the independent second-pass
    // byte checksum, even on filesystems with coarse timestamp resolution.
    payload.modified = (try payload.file.stat(io)).mtime;
    try std.testing.expectError(error.SourceChanged, writePackage(temporary.dir, io, "output.r4u", "manifest", &.{payload}, payload.size, false, &scratch));
    const unchanged = try temporary.dir.readFileAlloc(io, "output.r4u", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("previous-package", unchanged);
}

test "large firmware payloads stream while the complete package stays within guest file offsets" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const size = 33 * 1024 * 1024 + 137;
    {
        const source = try temporary.dir.createFile(io, "large.bin", .{});
        defer source.close(io);
        try source.setLength(io, size);
        try source.writePositionalAll(io, "beyond-the-old-limit", size - "beyond-the-old-limit".len);
    }
    var scratch: [stream_buffer_bytes]u8 = undefined;
    var payload = try parsePayloadSpec(std.testing.allocator, temporary.dir, io, "large.bin|C:\\R4OS\\SDK\\LARGE.BIN|sdk", &scratch);
    defer payload.file.close(io);
    defer std.testing.allocator.free(payload.canonical_target);
    try std.testing.expectEqual(@as(u64, size), payload.size);
    const manifest = "large-payload-fixture";
    _ = try writePackage(temporary.dir, io, "large.r4u", manifest, &.{payload}, payload.size, false, &scratch);
    const package = try temporary.dir.openFile(io, "large.r4u", .{});
    defer package.close(io);
    const envelope = contract.header_size + manifest.len;
    try std.testing.expectEqual(@as(u64, envelope + size), (try package.stat(io)).size);
    var header: [contract.header_size]u8 = undefined;
    try std.testing.expectEqual(header.len, try package.readPositionalAll(io, &header, 0));
    const PayloadReader = struct {
        file: FileReader,
        pub fn readAt(self: @This(), offset: u64, out: []u8) bool {
            return self.file.readAt(envelope + offset, out);
        }
    };
    try std.testing.expectEqual(payload.checksum, try streamPayload(PayloadReader{ .file = .{ .file = package, .io = io } }, DiscardWriter{}, size, &scratch));
    // Each payload could fit by itself while the envelope makes the package
    // unreadable through the existing guest API. Reject before replacement.
    try std.testing.expectError(error.PackageTooLarge, writePackage(temporary.dir, io, "large.r4u", manifest, &.{}, maximum_package_bytes - contract.header_size, false, &scratch));
    try std.testing.expectError(error.PackageTooLarge, writePackage(temporary.dir, io, "large.r4u", manifest, &.{}, std.math.maxInt(u64), false, &scratch));
    const preserved = try temporary.dir.openFile(io, "large.r4u", .{});
    defer preserved.close(io);
    try std.testing.expectEqual(@as(u64, envelope + size), (try preserved.stat(io)).size);
    var after: [contract.header_size]u8 = undefined;
    try std.testing.expectEqual(after.len, try preserved.readPositionalAll(io, &after, 0));
    try std.testing.expectEqualSlices(u8, &header, &after);
    {
        const oversized = try temporary.dir.createFile(io, "oversized.bin", .{});
        defer oversized.close(io);
        try oversized.setLength(io, maximum_package_bytes - contract.header_size + 1);
    }
    // Sparse length rejection occurs before attempting a multi-GB checksum.
    try std.testing.expectError(error.PayloadTooLarge, parsePayloadSpec(std.testing.allocator, temporary.dir, io, "oversized.bin|C:\\R4OS\\SDK\\LARGE.BIN|sdk", &scratch));
}

fn pathHasPrefix(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        if (pathChar(path[i]) != pathChar(prefix[i])) return false;
    }
    return true;
}

fn pathEquals(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    var i: usize = 0;
    while (i < left.len) : (i += 1) {
        if (pathChar(left[i]) != pathChar(right[i])) return false;
    }
    return true;
}

fn pathChar(byte: u8) u8 {
    const normalized = if (byte == '/') '\\' else byte;
    return std.ascii.toUpper(normalized);
}

fn baseName(path: []const u8) []const u8 {
    var pos: usize = path.len;
    while (pos > 0) : (pos -= 1) {
        const byte = path[pos - 1];
        if (byte == '\\' or byte == '/') return path[pos..];
    }
    return path;
}

fn stripUtf8Bom(value: []const u8) []const u8 {
    if (value.len >= 3 and value[0] == 0xef and value[1] == 0xbb and value[2] == 0xbf) return value[3..];
    return value;
}

fn stripSingleLineEnding(value: []const u8) []const u8 {
    if (std.mem.endsWith(u8, value, "\r\n")) return value[0 .. value.len - 2];
    if (std.mem.endsWith(u8, value, "\n") or std.mem.endsWith(u8, value, "\r")) return value[0 .. value.len - 1];
    return value;
}
