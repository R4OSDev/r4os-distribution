//! Prepare a disposable sparse host image; never opens a physical device.
//! The common PowerShell writer applies these verified extents under its
//! host-specific claim. DATA free sectors are deliberately not copied.
const std = @import("std");
const tools = @import("storage_tools");
const block = tools.io;
const setup = tools.installation;
const windows = struct {
    extern "kernel32" fn DeviceIoControl(handle: std.os.windows.HANDLE, code: u32, input: ?*const anyopaque, input_bytes: u32, output: ?*anyopaque, output_bytes: u32, returned: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
};
const Extent = struct { first: u64, count: u64 };
const Step = struct { source: []const u8 = "prepared", first: u64, count: u64 };
const Recorder = struct {
    target: block.Device,
    extents: [32768]Extent = undefined,
    count: usize = 0,
    fn read(raw: *anyopaque, lba: u64, bytes: []u8) i32 {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        self.target.read(lba, bytes) catch return -1;
        return 0;
    }
    fn write(raw: *anyopaque, lba: u64, bytes: []const u8) i32 {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        if (self.count == self.extents.len) return -2;
        self.target.write(lba, bytes) catch return -1;
        self.extents[self.count] = .{ .first = lba, .count = bytes.len / 512 };
        self.count += 1;
        return 0;
    }
    fn flush(raw: *anyopaque) i32 {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        self.target.flush() catch return -1;
        return 0;
    }
    fn device(self: *Recorder) block.Device {
        return .{ .context = self, .sectors = self.target.sectors, .exclusive = true, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
};
fn regionBytes(a: std.mem.Allocator, device: block.Device, range: tools.partition.Range) ![]u8 {
    const bytes = try a.alloc(u8, @intCast(range.count * 512));
    try device.read(range.first, bytes);
    return bytes;
}
pub fn run(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var image: ?[]const u8 = null;
    var zip: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var plan_path: ?[]const u8 = null;
    var sectors: u64 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.Arguments;
        const key = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, key, "--image")) image = value else if (std.mem.eql(u8, key, "--zip")) zip = value else if (std.mem.eql(u8, key, "--output")) output = value else if (std.mem.eql(u8, key, "--plan")) plan_path = value else if (std.mem.eql(u8, key, "--sectors")) sectors = try std.fmt.parseInt(u64, value, 10) else return error.Arguments;
    }
    var entropy: [7][16]u8 = undefined;
    std.Io.random(io, std.mem.asBytes(&entropy));
    const ids = try setup.Identifiers.fromEntropy(entropy);
    const layout = try setup.Layout.prepare(sectors, 512, ids);
    const source_file = try cwd.openFile(io, image orelse return error.Arguments, .{});
    defer source_file.close(io);
    var source = try tools.host_file.File.init(source_file, io);
    if (source.sectors * 512 != setup.standard_bytes) return error.SourceGeometry;
    const work = try a.alloc(u8, block.scratch_bytes);
    const source_table = try tools.partition.Plan.read(source.device(null), work);
    try tools.limine.verifyBios(source.device(null), &source_table, work);
    const boot_range = layout.part(.BOOT);
    const recovery_range = layout.part(.RECOVERY);
    const boot_bytes = try regionBytes(a, source.device(null), boot_range);
    const boot_view = try tools.fat32_view.View.init(boot_bytes, boot_range.first);
    const old_manifest = try boot_view.readFile(a, "boot/r4os-installation.json", 65536);
    const Source = struct { releaseVersion: []const u8, kernelVersion: []const u8, bootFiles: []const []const u8 };
    const manifest = try std.json.parseFromSlice(Source, a, old_manifest, .{ .ignore_unknown_fields = true });
    const new_manifest = try layout.manifest(a, manifest.value.releaseVersion, manifest.value.kernelVersion, manifest.value.bootFiles);
    const config = try layout.limineConfig(a, .usb);
    const boot = try tools.fat32_update.prepare(a, boot_bytes, boot_range.first, &.{
        .{ .path = "boot/r4os-installation.json", .bytes = new_manifest }, .{ .path = "boot/limine.conf", .bytes = config },
    });
    const recovery_bytes = try regionBytes(a, source.device(null), recovery_range);
    const original = try cwd.readFileAlloc(io, zip orelse return error.Arguments, a, .limited(1024 * 1024 * 1024));
    const recovery = try tools.fat32_update.prepare(a, recovery_bytes, recovery_range.first, &.{.{ .path = "INSTALL/RELEASE.ZIP", .bytes = original }});
    const data_range = layout.part(.DATA);
    var data_builder = try tools.ntfs.Builder.init(a, data_range.count * 512, "DATA", @intCast(data_range.first), tools.standardNtfsMetadata(), 0, std.mem.readInt(u64, ids.partitions[4][0..8], .little));
    for ([_][]const u8{ "DOCS", "MEDIA", "TEMP" }) |name| _ = try data_builder.addDirectory(data_builder.root(), name);
    var data = try data_builder.prepare();
    // All filesystem/layout preparation has succeeded before creating output.
    const destination = try cwd.createFile(io, output orelse return error.Arguments, .{ .read = true, .exclusive = true });
    defer destination.close(io);
    if (@import("builtin").os.tag == .windows) {
        var returned: u32 = 0;
        if (windows.DeviceIoControl(destination.handle, 0x900c4, null, 0, null, 0, &returned, null) == 0) return error.SparseWorkFileRequired;
    }
    var target = tools.host_file.File{ .file = destination, .io = io, .sectors = 0 };
    try target.acquire();
    defer target.release();
    try target.resize(sectors);
    const disk = target.device(null);
    var at: u64 = 0;
    while (at < data_range.first) {
        const count = @min(work.len / 512, data_range.first - at);
        const chunk = work[0..@intCast(count * 512)];
        try source.device(null).read(at, chunk);
        try disk.write(at, chunk);
        at += count;
    }
    try tools.partition.clean(disk, false, work);
    var table = try tools.partition.Plan.read(disk, work);
    try layout.bind(&table);
    try table.commit(disk, work);
    try disk.write(boot_range.first, boot.bytes);
    try disk.write(recovery_range.first, recovery.bytes);
    const recorder = try a.create(Recorder);
    recorder.* = .{ .target = disk };
    var data_region = block.Region{ .parent = recorder.device(), .first = data_range.first, .count = data_range.count };
    try data.execute(try data_region.device(), false, work);
    table = try tools.partition.Plan.read(disk, work);
    try tools.limine.installBios(disk, &table, work);
    try disk.flush();
    var steps: std.ArrayList(Step) = .empty;
    try steps.append(a, .{ .first = 0, .count = recovery_range.first });
    // The source slots are installed first. The original ZIP is published
    // only in phase two, after the complete bootable layout was verified.
    try steps.append(a, .{ .source = "image", .first = recovery_range.first, .count = recovery_range.count });
    std.mem.sort(Extent, recorder.extents[0..recorder.count], {}, struct {
        fn less(_: void, left: Extent, right: Extent) bool {
            return left.first < right.first;
        }
    }.less);
    for (recorder.extents[0..recorder.count]) |extent| {
        if (steps.items.len > 2) {
            const last = &steps.items[steps.items.len - 1];
            if (extent.first <= last.first + last.count) {
                last.count = @max(last.first + last.count, extent.first + extent.count) - last.first;
                continue;
            }
        }
        try steps.append(a, .{ .first = extent.first, .count = extent.count });
    }
    try steps.append(a, .{ .first = sectors - 33, .count = 33 });
    const cache = [_]Step{.{ .first = recovery_range.first, .count = recovery_range.count }};
    const description = try std.json.Stringify.valueAlloc(a, .{ .schema = @as(u32, 1), .targetBytes = sectors * 512, .minimumBytes = (setup.first_lbas[4] + setup.minimum_data_sectors + 33) * 512, .image = steps.items, .cache = &cache }, .{ .whitespace = .indent_2 });
    try cwd.writeFile(io, .{ .sub_path = plan_path orelse return error.Arguments, .data = description });
    std.debug.print("USB host preparation: {d} sectors, DATA {d}, identity {s}, cache {d} bytes\n", .{ sectors, data_range.count, setup.guid.format(ids.installation), original.len });
}
