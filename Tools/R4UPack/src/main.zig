const std = @import("std");
const artifact = @import("r4u_artifact");
const contract = artifact.contract;

const checksum_seed: u32 = 2166136261;

const Payload = struct {
    src: []const u8,
    target: []const u8,
    canonical_target: []u8,
    kind: []const u8,
    name: []const u8,
    bytes: []const u8,
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
            try payload_specs.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--require")) {
            i += 1;
            if (i >= args.len) return usage("missing --require value");
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
        allocator.free(payload.bytes);
        allocator.free(payload.canonical_target);
    };

    var payload_offset: u64 = 0;
    var derived_class: contract.DerivedClass = .{};
    var component_count: usize = 0;
    var has_unversioned_payload = false;
    for (payload_specs.items) |spec| {
        var payload = try parsePayloadSpec(allocator, cwd, io, spec);
        payload.offset = payload_offset;
        payload_offset = std.math.add(u64, payload_offset, payload.bytes.len) catch return error.PackageTooLarge;
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
        try requirements.append(allocator, try parseRequirement(allocator, spec));
    }
    try validateUniqueRequirements(requirements.items);
    if (has_unversioned_payload and requirements.items.len == 0) {
        return usage("configuration, data, font and SDK payloads require at least one concrete component requirement");
    }

    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(allocator);
    try buildManifest(allocator, &manifest, opts, description, derived_class, payloads.items, component_count, requirements.items);

    var payload_blob: std.ArrayList(u8) = .empty;
    defer payload_blob.deinit(allocator);
    for (payloads.items) |payload| try payload_blob.appendSlice(allocator, payload.bytes);

    const manifest_checksum = checksum(manifest.items);
    const payload_checksum = checksum(payload_blob.items);
    var package_hash = checksum_seed;
    package_hash = checksumUpdate(package_hash, manifest.items);
    package_hash = checksumUpdate(package_hash, payload_blob.items);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendNTimes(allocator, 0, contract.header_size);
    writeHeader(
        out.items[0..contract.header_size],
        manifest.items.len,
        payload_blob.items.len,
        manifest_checksum,
        payload_checksum,
        package_hash,
        @intCast(payloads.items.len),
        derived_class.activation == .restart,
    );
    try out.appendSlice(allocator, manifest.items);
    try out.appendSlice(allocator, payload_blob.items);

    try cwd.writeFile(io, .{ .sub_path = opts.output, .data = out.items });
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
        \\R4UPack reads component identity and version from the ELF/R4M0 artifact. Font, config, sdk and data payloads carry no invented component version and require a concrete --require.
        \\
    , .{});
}

fn parsePayloadSpec(allocator: std.mem.Allocator, cwd: std.Io.Dir, io: std.Io, spec_raw: []const u8) !Payload {
    const spec = std.mem.trim(u8, spec_raw, " \t\r\n");
    const first = std.mem.indexOfScalar(u8, spec, '|') orelse return error.BadPayloadSpec;
    const second = std.mem.indexOfScalarPos(u8, spec, first + 1, '|') orelse return error.BadPayloadSpec;
    if (std.mem.indexOfScalarPos(u8, spec, second + 1, '|') != null) return error.BadPayloadSpec;
    const src = std.mem.trim(u8, spec[0..first], " \t\r\n");
    const target = std.mem.trim(u8, spec[first + 1 .. second], " \t\r\n");
    const kind_raw = std.mem.trim(u8, spec[second + 1 ..], " \t\r\n");
    if (src.len == 0 or target.len == 0 or kind_raw.len == 0) return error.BadPayloadSpec;
    if (!validTarget(target)) return error.BadTargetPath;
    const kind = if (std.ascii.eqlIgnoreCase(kind_raw, "auto")) kindFromTarget(target) else kind_raw;
    if (!validKind(kind) or !kindMatchesTarget(kind, target)) return error.KindTargetMismatch;

    const bytes = try cwd.readFileAlloc(io, src, allocator, .limited(32 * 1024 * 1024));
    errdefer allocator.free(bytes);
    var target_buffer: [1024]u8 = undefined;
    const canonical = contract.canonicalInventoryTarget(target_buffer[0..], target) orelse return error.BadTargetPath;
    const canonical_owned = try allocator.dupe(u8, canonical);
    errdefer allocator.free(canonical_owned);
    if (contract.isManagedStateTarget(canonical_owned)) return error.ManagedStatePayloadForbidden;

    var identity: ?artifact.Identity = null;
    if (contract.componentKindForPayload(kind, canonical_owned)) |expected_kind| {
        const inspected = artifact.inspect(artifact.SliceReader{ .bytes = bytes }, bytes.len) orelse return error.MissingArtifactIdentity;
        if (inspected.kind != expected_kind) return error.ArtifactKindMismatch;
        const expected_name = componentNameFromTarget(target, expected_kind);
        if (!std.ascii.eqlIgnoreCase(expected_name, inspected.nameText())) return error.ArtifactNameMismatch;
        identity = inspected;
    }

    return .{
        .src = src,
        .target = target,
        .canonical_target = canonical_owned,
        .kind = kind,
        .name = baseName(target),
        .bytes = bytes,
        .offset = 0,
        .checksum = checksum(bytes),
        .component = identity,
    };
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
                std.ascii.eqlIgnoreCase(identity.nameText(), prior_identity.nameText())) {
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
            .{ index, payload.name, payload.target, payload.kind, payload.bytes.len, payload.checksum, payload.offset },
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
    payload_len: usize,
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
        std.mem.eql(u8, kind, "sdk") or
        std.mem.eql(u8, kind, "data");
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
    if (isForeignDriveTarget(target)) return "data";
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
