const std = @import("std");

const MAGIC = "R4I0";
const VERSION: u16 = 1;
const HEADER_SIZE: usize = 64;
const ENTRY_SIZE: usize = 128;
const MAX_NAME: usize = 32;
const MAX_ROLE: usize = 48;

const Kind = enum(u16) {
    r4l = 1,
    r4p = 2,
    r4d = 3,
};

const EntrySpec = struct {
    kind: Kind,
    name: []const u8,
    role: []const u8,
    path: []const u8,
    bytes: []u8,
    offset: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var output_path: ?[]const u8 = null;
    var entries: std.ArrayList(EntrySpec) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.bytes);
        entries.deinit(allocator);
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--add")) {
            if (i + 4 >= args.len) return error.BadArgs;
            const kind = parseKind(args[i + 1]) orelse return error.BadKind;
            const name = args[i + 2];
            const role = args[i + 3];
            const path = args[i + 4];
            i += 4;
            if (name.len == 0 or name.len > MAX_NAME) return error.BadName;
            if (role.len > MAX_ROLE) return error.BadRole;
            const bytes = try cwd.readFileAlloc(io, path, allocator, .unlimited);
            errdefer allocator.free(bytes);
            if (bytes.len > std.math.maxInt(u32)) return error.FileTooLarge;
            try entries.append(allocator, .{
                .kind = kind,
                .name = name,
                .role = role,
                .path = path,
                .bytes = bytes,
            });
        } else {
            std.debug.print("Unbekanntes Argument: {s}\n", .{arg});
            return error.BadArgs;
        }
    }

    const out = output_path orelse return error.MissingOutput;
    if (entries.items.len == 0) return error.NoEntries;
    if (entries.items.len > std.math.maxInt(u32)) return error.TooManyEntries;

    const data_offset = HEADER_SIZE + entries.items.len * ENTRY_SIZE;
    var total_size: usize = data_offset;
    for (entries.items) |*entry| {
        entry.offset = @intCast(total_size);
        total_size += entry.bytes.len;
    }
    if (total_size > std.math.maxInt(u32)) return error.ImageTooLarge;

    const image = try allocator.alloc(u8, total_size);
    defer allocator.free(image);
    @memset(image, 0);

    @memcpy(image[0..4], MAGIC);
    writeLe16(image[4..6], VERSION);
    writeLe16(image[6..8], HEADER_SIZE);
    writeLe32(image[8..12], @intCast(entries.items.len));
    writeLe32(image[12..16], HEADER_SIZE);
    writeLe32(image[16..20], @intCast(data_offset));
    writeLe32(image[20..24], @intCast(total_size));

    for (entries.items, 0..) |entry, index| {
        const off = HEADER_SIZE + index * ENTRY_SIZE;
        const record = image[off .. off + ENTRY_SIZE];
        writeLe16(record[0..2], @intFromEnum(entry.kind));
        writeLe16(record[2..4], 0);
        writeLe16(record[4..6], @intCast(entry.name.len));
        writeLe16(record[6..8], @intCast(entry.role.len));
        @memcpy(record[8 .. 8 + entry.name.len], entry.name);
        @memcpy(record[40 .. 40 + entry.role.len], entry.role);
        writeLe32(record[88..92], entry.offset);
        writeLe32(record[92..96], @intCast(entry.bytes.len));
        @memcpy(image[entry.offset .. entry.offset + entry.bytes.len], entry.bytes);
    }

    try cwd.writeFile(io, .{ .sub_path = out, .data = image });
    std.debug.print("PRELOAD.R4I created: {s} ({d} entries, {d} bytes)\n", .{ out, entries.items.len, total_size });
}

fn parseKind(value: []const u8) ?Kind {
    if (std.ascii.eqlIgnoreCase(value, "r4l")) return .r4l;
    if (std.ascii.eqlIgnoreCase(value, "r4p")) return .r4p;
    if (std.ascii.eqlIgnoreCase(value, "r4d")) return .r4d;
    return null;
}

fn writeLe16(out: []u8, value: u16) void {
    out[0] = @intCast(value & 0xff);
    out[1] = @intCast(value >> 8);
}

fn writeLe32(out: []u8, value: u32) void {
    out[0] = @intCast(value & 0xff);
    out[1] = @intCast((value >> 8) & 0xff);
    out[2] = @intCast((value >> 16) & 0xff);
    out[3] = @intCast(value >> 24);
}
