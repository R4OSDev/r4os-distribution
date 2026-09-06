//! Fresh DATA in a disposable host work copy. The release source is never
//! passed here; callers bind it by hash before making their private copy.
const std = @import("std");
const tools = @import("storage_tools");
const setup = tools.installation;
pub fn run(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var path: ?[]const u8 = null;
    var add: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.Arguments;
        if (std.mem.eql(u8, args[i], "--image")) path = args[i + 1] else if (std.mem.eql(u8, args[i], "--add")) add = args[i + 1] else return error.Arguments;
    }
    const file = try cwd.openFile(io, path orelse return error.Arguments, .{ .mode = .read_write });
    defer file.close(io);
    var target = try tools.host_file.File.init(file, io);
    try target.acquire();
    defer target.release();
    const disk = target.device(null);
    const work = try a.alloc(u8, tools.io.scratch_bytes);
    const table = try tools.partition.Plan.read(disk, work);
    const part = table.entries[4];
    if (table.kind != .gpt or !part.present or !std.mem.eql(u16, &part.name, &try tools.partition.asciiName("DATA")) or
        part.first != setup.first_lbas[4] or part.count != disk.sectors - 33 - part.first) return error.Geometry;
    var builder = try tools.ntfs.Builder.init(a, part.count * 512, "DATA", @intCast(part.first), tools.standardNtfsMetadata(), 0, std.mem.readInt(u64, part.unique_guid[0..8], .little));
    for ([_][]const u8{ "DOCS", "MEDIA", "TEMP" }) |name| _ = try builder.addDirectory(builder.root(), name);
    if (add) |spec| {
        const split = std.mem.lastIndexOfScalar(u8, spec, '|') orelse return error.Arguments;
        const bytes = try cwd.readFileAlloc(io, spec[0..split], a, .limited(64 * 1024 * 1024));
        try @import("ntfs_cli.zig").addPath(&builder, a, spec[split + 1 ..], bytes);
    }
    var plan = try builder.prepare();
    var region = tools.io.Region{ .parent = disk, .first = part.first, .count = part.count };
    try plan.execute(try region.device(), false, work);
    std.debug.print("Fresh DATA verified: {d} sectors, optional request={s}\n", .{ part.count, if (add == null) "no" else "yes" });
}
