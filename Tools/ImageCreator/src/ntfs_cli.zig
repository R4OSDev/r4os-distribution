// ImageCreator "format-ntfs" subcommand (0.60.5).
//
// Formats a standalone NTFS 3.1 volume, either bare (boot sector at offset 0)
// or wrapped in a single-partition MBR disk, from Windows-authored metadata
// templates plus an add-list of host files.  Reuses the shared ntfs_mkfs
// builder so ImageCreator and the host test harness produce identical bytes.
//
// Usage:
//   imagecreater format-ntfs --output vol.img --meta <dir> [options]
//     --size <MB>            volume size (default 32)
//     --label <name>         volume label (default R4OSNTFS)
//     --partition            wrap in an MBR disk (partition at LBA 2048)
//     --full                 zero all volume sectors (default: quick)
//     --serial <hex>         64-bit serial (default derived)
//     --add SRC:DEST         add a host file at an NTFS path (repeatable)
//     --add-list <file>      add SRC|DEST or SRC:DEST lines from a file

const std = @import("std");
const storage_tools = @import("storage_tools");
const mkfs = storage_tools.ntfs;

const PART_LBA: u32 = 2048;

const AddEntry = struct { src: []const u8, dest: []const u8 };

pub fn run(gpa: std.mem.Allocator, io: anytype, cwd: std.Io.Dir, args: []const []const u8) !void {
    // One-shot tool: an arena keeps template/file ownership trivial and
    // avoids per-buffer frees on the exit path.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var output_path: ?[]const u8 = null;
    var meta_dir_path: ?[]const u8 = null;
    var size_mb: u32 = 32;
    var label: []const u8 = "R4OSNTFS";
    var partition = false;
    var full = false;
    var serial: u64 = 0x5234_4F53_4E54_4653;
    var entries: std.ArrayList(AddEntry) = .empty;
    defer entries.deinit(a);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            output_path = argVal(args, i);
        } else if (std.mem.eql(u8, arg, "--meta")) {
            i += 1;
            meta_dir_path = argVal(args, i);
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            size_mb = try std.fmt.parseInt(u32, argVal(args, i) orelse return error.BadArgs, 10);
        } else if (std.mem.eql(u8, arg, "--label")) {
            i += 1;
            label = argVal(args, i) orelse return error.BadArgs;
        } else if (std.mem.eql(u8, arg, "--serial")) {
            i += 1;
            serial = try std.fmt.parseInt(u64, argVal(args, i) orelse return error.BadArgs, 16);
        } else if (std.mem.eql(u8, arg, "--partition")) {
            partition = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            full = true;
        } else if (std.mem.eql(u8, arg, "--add")) {
            i += 1;
            const spec = argVal(args, i) orelse return error.BadArgs;
            const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return error.BadAddArg;
            if (colon == 0 or colon + 1 >= spec.len) return error.BadAddArg;
            try entries.append(a, .{ .src = spec[0..colon], .dest = spec[colon + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--add-list")) {
            i += 1;
            const list_path = argVal(args, i) orelse return error.BadArgs;
            const data = try cwd.readFileAlloc(io, list_path, a, .unlimited);
            try appendAddList(a, data, &entries);
        } else {
            std.debug.print("format-ntfs: unknown argument {s}\n", .{arg});
            return error.BadArgs;
        }
    }

    const out = output_path orelse return error.MissingOutput;
    const meta_path = meta_dir_path orelse return error.MissingMeta;

    var meta_dir = try cwd.openDir(io, meta_path, .{});
    defer meta_dir.close(io);
    const meta = try loadMeta(a, io, meta_dir);

    const total_bytes: u64 = @as(u64, size_mb) * 1024 * 1024;
    const timestamp: u64 = 132_000_000_000_000_000;
    const part_lba: u32 = if (partition) PART_LBA else 0;
    var builder = try mkfs.Builder.init(a, total_bytes, label, part_lba, meta, timestamp, serial);

    for (entries.items) |entry| {
        const data = try cwd.readFileAlloc(io, entry.src, a, .limited(64 * 1024 * 1024));
        try addPath(&builder, a, entry.dest, data);
    }

    var plan = try builder.prepare();
    defer plan.deinit();
    const sectors = total_bytes / 512;
    if (partition and sectors + PART_LBA > @as(u64, std.math.maxInt(u32)) + 1) return error.MbrCapacity;
    const work = try a.alloc(u8, 128 * 1024);
    // Geometry, templates, records and buffers are ready before the output
    // may change. Open without truncation and acquire the host file lock.
    const output = try cwd.createFile(io, out, .{ .read = true, .truncate = false });
    defer output.close(io);
    var target = storage_tools.host_file.File{ .file = output, .io = io, .sectors = 0 };
    try target.acquire();
    defer target.release();
    try target.resize(@as(u64, part_lba) + sectors);
    var progress = storage_tools.io.Progress{};
    const device = target.device(&progress);
    if (partition) {
        try storage_tools.partition.clean(device, false, work);
        var layout = try storage_tools.partition.Plan.read(device, work);
        try layout.initializeMbr(@max(@as(u32, 1), @as(u32, @truncate(serial))));
        _ = try layout.add(.{ .present = true, .first = PART_LBA, .count = sectors, .mbr_type = 0x07 });
        try layout.commit(device, work);
    }
    var region = storage_tools.io.Region{ .parent = device, .first = part_lba, .count = sectors };
    try plan.execute(try region.device(), full, work);
    std.debug.print("format-ntfs: OK bytes={d} partition_lba={d} mode={s} streamed=yes\n", .{ total_bytes, part_lba, if (full) "full" else "quick" });
}

fn argVal(args: []const []const u8, i: usize) ?[]const u8 {
    if (i >= args.len) return null;
    return args[i];
}

/// Adds a file at an NTFS path, creating parent directories on demand.
pub fn addPath(builder: *mkfs.Builder, a: std.mem.Allocator, dest: []const u8, data: []const u8) !void {
    var parent = builder.root();
    var rest = dest;
    while (std.mem.indexOfAny(u8, rest, "/\\")) |sep| {
        const segment = rest[0..sep];
        rest = rest[sep + 1 ..];
        if (segment.len == 0) continue;
        parent = try builder.ensureDirectory(parent, segment);
    }
    if (rest.len == 0) return error.BadDestPath;
    const owned = try a.dupe(u8, rest);
    try builder.addFile(parent, owned, data);
}

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

fn loadReq(a: std.mem.Allocator, io: anytype, dir: std.Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(io, name, a, .limited(1 << 20));
}

fn loadOpt(a: std.mem.Allocator, io: anytype, dir: std.Io.Dir, name: []const u8) []u8 {
    return dir.readFileAlloc(io, name, a, .limited(1 << 20)) catch &[_]u8{};
}

pub fn loadMeta(a: std.mem.Allocator, io: anytype, dir: std.Io.Dir) !mkfs.Meta {
    return .{
        .upcase = try loadReq(a, io, dir, "upcase.bin"),
        .upcase_info = loadOpt(a, io, dir, "upcase_info.bin"),
        .attrdef = try loadReq(a, io, dir, "attrdef.bin"),
        .sds_prefix = try loadReq(a, io, dir, "secure_sds_prefix.bin"),
        .sdh_root = try loadReq(a, io, dir, "secure_sdh_root.bin"),
        .sii_root = try loadReq(a, io, dir, "secure_sii_root.bin"),
        .sdh_alloc = try loadReq(a, io, dir, "secure_SDH_alloc.bin"),
        .sii_alloc = try loadReq(a, io, dir, "secure_SII_alloc.bin"),
        .sdh_bitmap = try loadReq(a, io, dir, "secure_SDH_bitmap.bin"),
        .sii_bitmap = try loadReq(a, io, dir, "secure_SII_bitmap.bin"),
        .objid_o_root = try loadReq(a, io, dir, "extend_objid_o_root.bin"),
        .quota_o_root = try loadReq(a, io, dir, "extend_quota_o_root.bin"),
        .quota_q_root = try loadReq(a, io, dir, "extend_quota_q_root.bin"),
        .reparse_r_root = try loadReq(a, io, dir, "extend_reparse_r_root.bin"),
        .root_sd = try loadReq(a, io, dir, "root_sd.bin"),
        .boot_sd = try loadReq(a, io, dir, "boot_sd.bin"),
    };
}
