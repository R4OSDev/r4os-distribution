// R4OS ImageCreator
//
// Creates a bootable disk image with:
//   - MBR + one active FAT32-LBA partition
//   - FAT32 filesystem with MBR partitioning
//   - Arbitrary files at arbitrary paths (subdirectories, long names via LFN)
//
// Usage:
//   imagecreater --output disk.img [--size 64]
//                --add <source>:</target-path> [--add ...]
//                [--add-list add-list.txt]
//                [--volume-only] (FAT32 volume at sector zero, no MBR)
//
// Example:
//   imagecreater --output disk.img --size 64 \
//       --add limine.conf:/boot/limine.conf \
//       --add limine-bios.sys:/boot/limine-bios.sys \
//       --add r4os.elf:/boot/r4os.elf

const std = @import("std");
const ntfs_cli = @import("ntfs_cli.zig");
const storage_tools = @import("storage_tools");
const ntfs_mkfs = storage_tools.ntfs;

// --- Layout-Konstanten ----------------------------------------------------
const SECTOR: u32 = 512;
const SMALL_IMAGE_SPC: u32 = 1; // Keeps 64/128 MB FAT32 images above the FAT32 cluster-count threshold.
const LARGE_IMAGE_SPC: u32 = 8; // 4 KB clusters for normal system images and large transfer/update workloads.
const LARGE_CLUSTER_MIN_MB: u32 = 512;
const PART_START_SECTOR: u32 = 2048;

// --- Input-Struct -------------------------------------------------------
const AddEntry = struct { src: []const u8, dest: []const u8, data: ?[]const u8 = null };

fn appendAddList(a: std.mem.Allocator, data: []const u8, entries: *std.ArrayList(AddEntry)) !void {
    var rest = data;
    while (rest.len > 0) {
        const split = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const raw_line = rest[0..split];
        rest = if (split < rest.len) rest[split + 1 ..] else rest[split..];

        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sep = std.mem.indexOfScalar(u8, line, '|') orelse
            (std.mem.lastIndexOfScalar(u8, line, ':') orelse return error.BadAddListLine);
        const src = std.mem.trim(u8, line[0..sep], " \t\r");
        const dest = std.mem.trim(u8, line[sep + 1 ..], " \t\r");
        if (src.len == 0 or dest.len == 0) return error.BadAddListLine;
        try entries.append(a, .{ .src = src, .dest = dest });
    }
}

fn wU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}
fn wU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

// --- Initialisierung ------------------------------------------------------
fn sectorsPerClusterForSize(size_mb: u32) u32 {
    return if (size_mb >= LARGE_CLUSTER_MIN_MB) LARGE_IMAGE_SPC else SMALL_IMAGE_SPC;
}

fn buildMbr(buf: []u8, total_sectors: u32, part_sectors: u32) void {
    @memset(buf[0..446], 0);
    @memset(buf[446..510], 0);
    // Partition entry 1
    const pe = buf[446..462];
    pe[0] = 0x80; // active
    // CHS fields with "invalid" / LBA fallback.
    pe[1] = 0xFE;
    pe[2] = 0xFF;
    pe[3] = 0xFF;
    pe[4] = 0x0C; // FAT32 LBA
    pe[5] = 0xFE;
    pe[6] = 0xFF;
    pe[7] = 0xFF;
    wU32(buf, 446 + 8, PART_START_SECTOR);
    wU32(buf, 446 + 12, part_sectors);
    _ = total_sectors;
    buf[510] = 0x55;
    buf[511] = 0xAA;
}

// --- main -----------------------------------------------------------------
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const cwd = std.Io.Dir.cwd();
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len >= 2 and std.mem.eql(u8, args[1], "format-ntfs")) {
        return ntfs_cli.run(a, io, cwd, args[2..]);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "create-system")) {
        return runCreateSystem(a, io, cwd, args[2..]);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "create-installation")) {
        return runCreateInstallation(a, io, cwd, args[2..]);
    }

    var output_path: ?[]const u8 = null;
    var size_mb: u32 = 64;
    var volume_only = false;
    var entries: std.ArrayList(AddEntry) = .empty;
    defer entries.deinit(a);
    var list_buffers: std.ArrayList([]u8) = .empty;
    defer {
        for (list_buffers.items) |buffer| a.free(buffer);
        list_buffers.deinit(a);
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--volume-only")) {
            volume_only = true;
        } else if (std.mem.eql(u8, arg, "--size")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            size_mb = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--add")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            // The last ':' separates source from destination so Windows drive letters (D:\...) remain valid in source paths.
            const colon = std.mem.lastIndexOfScalar(u8, args[i], ':') orelse return error.BadAddArg;
            if (colon == 0 or colon + 1 >= args[i].len) return error.BadAddArg;
            try entries.append(a, .{ .src = args[i][0..colon], .dest = args[i][colon + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--add-list")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            const data = try cwd.readFileAlloc(io, args[i], a, .unlimited);
            errdefer a.free(data);
            try list_buffers.append(a, data);
            try appendAddList(a, data, &entries);
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return error.BadArgs;
        }
    }

    const out = output_path orelse {
        std.debug.print("--output missing\n", .{});
        return error.BadArgs;
    };

    const total_bytes: u64 = @as(u64, size_mb) * 1024 * 1024;
    const total_sectors_u64 = total_bytes / SECTOR;
    if (total_sectors_u64 > std.math.maxInt(u32)) return error.SizeTooLarge;
    const total_sectors: u32 = @intCast(total_sectors_u64);
    const first_sector: u32 = if (volume_only) 0 else PART_START_SECTOR;
    if (total_sectors <= first_sector) return error.SizeTooSmall;
    const part_sectors: u32 = total_sectors - first_sector;

    const image_bytes: usize = @as(usize, total_sectors) * SECTOR;
    const image = try a.alloc(u8, image_bytes);
    defer a.free(image);
    @memset(image, 0);

    // MBR
    if (!volume_only) buildMbr(image[0..SECTOR], total_sectors, part_sectors);
    const stats = try buildFat32PartitionInto(a, io, cwd, image, first_sector, total_sectors, part_sectors, size_mb, entries.items);

    // Output.
    try cwd.writeFile(io, .{ .sub_path = out, .data = image });

    std.debug.print(
        "FAT32 image created: {s} ({d} MB)\n  Partition: sector {d}, {d} sectors\n  FAT size: {d} sectors per FAT\n  Cluster: {d} bytes\n",
        .{ out, size_mb, first_sector, part_sectors, stats.sectors_per_fat, SECTOR * stats.sectors_per_cluster },
    );
}

const FatBuildStats = struct { sectors_per_fat: u32, sectors_per_cluster: u32 };

/// Builds the FAT32 partition content (BPB, FATs, tree) into `image` at the
/// selected partition offset. Shared by standalone volumes, the classic
/// single-partition image and the boot partition of the system layout.
fn buildFat32PartitionInto(a: std.mem.Allocator, io: anytype, cwd: std.Io.Dir, image: []u8, first_sector: u32, total_sectors: u32, part_sectors: u32, size_mb: u32, entries: []const AddEntry) !FatBuildStats {
    _ = total_sectors;
    var files: std.ArrayList(storage_tools.fat32_image.File) = .empty;
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |bytes| a.free(bytes);
        owned.deinit(a);
        files.deinit(a);
    }
    for (entries) |entry| {
        const bytes = if (entry.data) |data| data else read: {
            const data = try cwd.readFileAlloc(io, entry.src, a, .unlimited);
            errdefer a.free(data);
            try owned.append(a, data);
            break :read data;
        };
        try files.append(a, .{ .path = entry.dest, .bytes = bytes });
    }
    const offset = @as(usize, first_sector) * 512;
    const size = @as(usize, part_sectors) * 512;
    if (offset > image.len or size > image.len - offset) return error.Geometry;
    const result = try storage_tools.fat32_image.buildInto(a, image[offset..][0..size], first_sector, sectorsPerClusterForSize(size_mb), "R4OS BOOT", 0xCAFEBABE, files.items);
    return .{ .sectors_per_fat = result.geometry.sectors_per_fat, .sectors_per_cluster = result.geometry.sectors_per_cluster };
}

// --- create-system: FAT32 boot partition + NTFS system volume ---------------

/// Splits at the /boot and /EFI prefixes: boot files AND the UEFI
/// removable-media path (/EFI/BOOT/BOOTX64.EFI) live on the FAT32 boot
/// partition -- UEFI firmware only reads FAT, so an /EFI tree on the NTFS
/// system volume would silently not boot (real Lenovo finding, 0.60.11).
/// Everything else goes to the NTFS system volume.
fn isBootDest(dest: []const u8) bool {
    return hasTopDir(dest, "boot") or hasTopDir(dest, "efi");
}

fn hasTopDir(dest: []const u8, comptime name: []const u8) bool {
    var path = dest;
    if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) path = path[1..];
    if (path.len < name.len) return false;
    for (name, 0..) |expected, i| {
        const ch = path[i];
        const folded = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        if (folded != expected) return false;
    }
    return path.len == name.len or path[name.len] == '/' or path[name.len] == '\\';
}

fn runCreateSystem(gpa: std.mem.Allocator, io: anytype, cwd: std.Io.Dir, args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var output_path: ?[]const u8 = null;
    var meta_dir_path: ?[]const u8 = null;
    var boot_mb: u32 = 128;
    var system_mb: u32 = 512;
    var label: []const u8 = "R4OS";
    var serial: u64 = 0x5234_4F53_5359_5354;
    var entries: std.ArrayList(AddEntry) = .empty;
    defer entries.deinit(a);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--meta")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            meta_dir_path = args[i];
        } else if (std.mem.eql(u8, arg, "--boot-mb")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            boot_mb = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--system-mb")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            system_mb = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--label")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            label = args[i];
        } else if (std.mem.eql(u8, arg, "--serial")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            serial = try std.fmt.parseInt(u64, args[i], 16);
        } else if (std.mem.eql(u8, arg, "--add")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            const colon = std.mem.lastIndexOfScalar(u8, args[i], ':') orelse return error.BadAddArg;
            if (colon == 0 or colon + 1 >= args[i].len) return error.BadAddArg;
            try entries.append(a, .{ .src = args[i][0..colon], .dest = args[i][colon + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--add-list")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            const data = try cwd.readFileAlloc(io, args[i], a, .unlimited);
            try appendAddList(a, data, &entries);
        } else {
            std.debug.print("create-system: unknown argument {s}\n", .{arg});
            return error.BadArgs;
        }
    }

    const out = output_path orelse return error.BadArgs;
    const meta_path = meta_dir_path orelse return error.BadArgs;
    if (boot_mb < 16 or system_mb < 16) return error.SizeTooSmall;

    var boot_entries: std.ArrayList(AddEntry) = .empty;
    defer boot_entries.deinit(a);
    var system_entries: std.ArrayList(AddEntry) = .empty;
    defer system_entries.deinit(a);
    for (entries.items) |e| {
        if (isBootDest(e.dest)) {
            try boot_entries.append(a, e);
        } else {
            try system_entries.append(a, e);
        }
    }

    const boot_part_sectors: u32 = boot_mb * (1024 * 1024 / SECTOR);
    const system_bytes: u64 = @as(u64, system_mb) * 1024 * 1024;
    const system_sectors: u32 = @intCast(system_bytes / SECTOR);
    const ntfs_lba: u32 = PART_START_SECTOR + boot_part_sectors;
    const total_sectors: u32 = ntfs_lba + system_sectors;

    const image = try a.alloc(u8, @as(usize, total_sectors) * SECTOR);
    @memset(image, 0);

    // FAT32 boot partition at the classic offset.
    _ = try buildFat32PartitionInto(a, io, cwd, image, PART_START_SECTOR, total_sectors, boot_part_sectors, boot_mb, boot_entries.items);

    // NTFS system volume behind it.
    var meta_dir = try cwd.openDir(io, meta_path, .{});
    defer meta_dir.close(io);
    const meta = try ntfs_cli.loadMeta(a, io, meta_dir);
    const timestamp: u64 = 132_000_000_000_000_000;
    var builder = try ntfs_mkfs.Builder.init(a, system_bytes, label, ntfs_lba, meta, timestamp, serial);
    for (system_entries.items) |e| {
        const data = cwd.readFileAlloc(io, e.src, a, .unlimited) catch |err| {
            std.debug.print("Cannot read '{s}': {s}\n", .{ e.src, @errorName(err) });
            return err;
        };
        try ntfs_cli.addPath(&builder, a, e.dest, data);
    }
    const volume = try builder.finalize();
    if (volume.len != system_bytes) return error.NtfsSizeMismatch;
    @memcpy(image[@as(usize, ntfs_lba) * SECTOR ..][0..volume.len], volume);

    // MBR with both partitions.
    const mbr = image[0..SECTOR];
    @memset(mbr[0..510], 0);
    wU32(mbr, 0x1B8, @truncate(serial));
    const p1 = mbr[446..462];
    p1[0] = 0x80; // active boot partition
    p1[1] = 0xFE;
    p1[2] = 0xFF;
    p1[3] = 0xFF;
    p1[4] = 0x0C; // FAT32 LBA
    p1[5] = 0xFE;
    p1[6] = 0xFF;
    p1[7] = 0xFF;
    wU32(mbr, 446 + 8, PART_START_SECTOR);
    wU32(mbr, 446 + 12, boot_part_sectors);
    const p2 = mbr[462..478];
    p2[0] = 0x00;
    p2[1] = 0xFE;
    p2[2] = 0xFF;
    p2[3] = 0xFF;
    p2[4] = 0x07; // NTFS
    p2[5] = 0xFE;
    p2[6] = 0xFF;
    p2[7] = 0xFF;
    wU32(mbr, 462 + 8, ntfs_lba);
    wU32(mbr, 462 + 12, system_sectors);
    mbr[510] = 0x55;
    mbr[511] = 0xAA;

    try cwd.writeFile(io, .{ .sub_path = out, .data = image });
    std.debug.print(
        "System image created: {s}\n  Boot partition (FAT32): sector {d}, {d} sectors ({d} boot files)\n  System volume (NTFS): sector {d}, {d} sectors ({d} files)\n",
        .{ out, PART_START_SECTOR, boot_part_sectors, boot_entries.items.len, ntfs_lba, system_sectors, system_entries.items.len },
    );
}

const ImageDevice = struct {
    bytes: []u8,
    fn read(raw: *anyopaque, lba: u64, out: []u8) i32 {
        const self: *ImageDevice = @ptrCast(@alignCast(raw));
        @memcpy(out, self.bytes[@intCast(lba * 512)..][0..out.len]);
        return 0;
    }
    fn write(raw: *anyopaque, lba: u64, bytes: []const u8) i32 {
        const self: *ImageDevice = @ptrCast(@alignCast(raw));
        @memcpy(self.bytes[@intCast(lba * 512)..][0..bytes.len], bytes);
        return 0;
    }
    fn flush(_: *anyopaque) i32 {
        return 0;
    }
    fn device(self: *ImageDevice) storage_tools.io.Device {
        return .{ .context = self, .sectors = self.bytes.len / 512, .exclusive = true, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
};

fn runCreateInstallation(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const common = storage_tools.installation;
    var output: ?[]const u8 = null;
    var manifest_output: ?[]const u8 = null;
    var release: ?[]const u8 = null;
    var kernel: ?[]const u8 = null;
    var medium: common.Medium = .local;
    var entries: std.ArrayList(AddEntry) = .empty;
    var recovery: std.ArrayList(AddEntry) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.BadArgs;
        const arg = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, arg, "--output")) output = value else if (std.mem.eql(u8, arg, "--manifest-out")) manifest_output = value else if (std.mem.eql(u8, arg, "--release-version")) release = value else if (std.mem.eql(u8, arg, "--kernel-version")) kernel = value else if (std.mem.eql(u8, arg, "--medium")) {
            medium = std.meta.stringToEnum(common.Medium, value) orelse return error.BadArgs;
        } else if (std.mem.eql(u8, arg, "--add-list")) {
            try appendAddList(a, try cwd.readFileAlloc(io, value, a, .limited(4 * 1024 * 1024)), &entries);
        } else if (std.mem.eql(u8, arg, "--recovery-list")) {
            try appendAddList(a, try cwd.readFileAlloc(io, value, a, .limited(4 * 1024 * 1024)), &recovery);
        } else return error.BadArgs;
    }
    const destination = output orelse return error.MissingOutput;
    const release_version = release orelse return error.MissingVersion;
    const kernel_version = kernel orelse return error.MissingVersion;
    var entropy: [7][16]u8 = undefined;
    std.Io.random(io, std.mem.asBytes(&entropy));
    const ids = try common.Identifiers.fromEntropy(entropy);
    const layout = try common.Layout.prepare(common.standard_bytes / 512, 512, ids);
    var boot_entries: std.ArrayList(AddEntry) = .empty;
    var system_entries: std.ArrayList(AddEntry) = .empty;
    var boot_files: std.ArrayList([]const u8) = .empty;
    for (entries.items) |entry| {
        if (isBootDest(entry.dest)) {
            const path = std.mem.trimStart(u8, entry.dest, "/");
            if (std.ascii.eqlIgnoreCase(path, "boot/limine.conf")) continue;
            if (std.ascii.eqlIgnoreCase(path, "boot/r4os-installation.json") or !common.bootPath(path)) return error.BootPath;
            try boot_files.append(a, path);
            try boot_entries.append(a, entry);
        } else try system_entries.append(a, entry);
    }
    for (common.boot_paths) |required| {
        var found = false;
        for (boot_files.items) |path| if (std.mem.eql(u8, path, required)) {
            found = true;
            break;
        };
        if (!found) return error.MissingBootFile;
    }
    for ([_][]const u8{ "/CURRENT/recovery.elf", "/CURRENT/runtime.img", "/CURRENT/manifest.json", "/PREVIOUS/recovery.elf", "/PREVIOUS/runtime.img", "/PREVIOUS/manifest.json" }) |required| {
        var found = false;
        for (recovery.items) |entry| if (std.mem.eql(u8, entry.dest, required)) {
            found = true;
            break;
        };
        if (!found) return error.MissingRecoveryFile;
    }
    const manifest = try layout.manifest(a, release_version, kernel_version, boot_files.items);
    const config = try layout.limineConfig(a, medium);
    try boot_entries.append(a, .{ .src = "", .dest = "/boot/r4os-installation.json", .data = manifest });
    try boot_entries.append(a, .{ .src = "", .dest = "/boot/limine.conf", .data = config });

    const bytes = try a.alloc(u8, @intCast(common.standard_bytes));
    @memset(bytes, 0);
    var ram = ImageDevice{ .bytes = bytes };
    const device = ram.device();
    const work = try a.alloc(u8, storage_tools.io.scratch_bytes);
    var table = try storage_tools.partition.Plan.read(device, work);
    try layout.bind(&table);
    try table.commit(device, work);
    for ([_]common.Role{ .BOOT, .RECOVERY }) |role| {
        const region = layout.part(role);
        _ = try buildFat32PartitionInto(a, io, cwd, bytes, @intCast(region.first), @intCast(layout.sectors), @intCast(region.count), @intCast(region.count / 2048), if (role == .BOOT) boot_entries.items else recovery.items);
    }
    for ([_]common.Role{ .SYSTEM, .DATA }) |role| {
        const region = layout.part(role);
        const serial = std.mem.readInt(u64, ids.partitions[@intFromEnum(role)][0..8], .little);
        var builder = try ntfs_mkfs.Builder.init(a, region.count * 512, @tagName(role), @intCast(region.first), storage_tools.standardNtfsMetadata(), 132_000_000_000_000_000, serial);
        if (role == .SYSTEM) {
            for (system_entries.items) |entry| {
                const contents = try cwd.readFileAlloc(io, entry.src, a, .unlimited);
                try ntfs_cli.addPath(&builder, a, entry.dest, contents);
            }
        } else {
            for ([_][]const u8{ "DOCS", "MEDIA", "TEMP" }) |name| {
                _ = try builder.addDirectory(builder.root(), name);
            }
        }
        const volume = try builder.finalize();
        if (volume.len != region.count * 512) return error.NtfsSizeMismatch;
        @memcpy(bytes[@intCast(region.first * 512)..][0..volume.len], volume);
    }
    const committed = try storage_tools.partition.Plan.read(device, work);
    try storage_tools.limine.installBios(device, &committed, work);
    // Only complete host files are published. The product guest uses the
    // same layout/BIOS helper over its explicit device claim, not this CLI.
    try cwd.writeFile(io, .{ .sub_path = destination, .data = bytes });
    if (manifest_output) |path| try cwd.writeFile(io, .{ .sub_path = path, .data = manifest });
    std.debug.print("R4OS five-partition image: {s}, 2048 MB, disk {s}, default {s}\n", .{ destination, common.guid.format(ids.disk), @tagName(medium) });
}
