const std = @import("std");

const magic = "R4R1";
const header_size: usize = 96;
const key_record_size: usize = 32;
const value_record_size: usize = 32;
const invalid_index: u32 = 0xffff_ffff;

// Includes old 0.46.X default hive names only so stale files vanish from Release\RegistryDefaults.
const stale_or_default_hive_files = [_][]const u8{
    "SYSTEM.R4R",
    "SOFTWARE.R4R",
    "DESKTOP.R4R",
    "USER.R4R",
};

const bool_true = [_]u8{1};
const bool_false = [_]u8{0};
const default_terminal_path = "C:\\R4OS\\SOFTWARE\\TERMINAL;C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG";
const sshd_registry_key = "SYSTEM\\Services\\SSHD";

const ValueType = enum(u16) {
    string = 1,
    u32 = 2,
    u64 = 3,
    bool = 4,
    binary = 5,
    multi_string = 6,
};

const BuildValue = struct {
    key_path: []const u8,
    name: []const u8,
    value_type: ValueType,
    data: []const u8,
};

const BuildNode = struct {
    parent: u32,
    name: []const u8,
    children: std.ArrayList(u32) = .empty,
    values: std.ArrayList(BuildValue) = .empty,
    flat_index: u32 = invalid_index,

    fn deinit(self: *BuildNode, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        self.values.deinit(allocator);
    }
};

const FlatKey = struct {
    parent_index: u32,
    name_offset: u32,
    name_len: u16,
    first_value_index: u32,
    value_count: u32,
    first_child_index: u32,
    child_count: u32,
};

const FlatValue = struct {
    owner_key_index: u32,
    name_offset: u32,
    name_len: u16,
    value_type: ValueType,
    data_offset: u32,
    data_len: u32,
};

const QuickLaunchSpec = struct {
    kind: []const u8,
    title: []const u8,
    path: []const u8 = "",
    args: []const u8 = "",
    policy: []const u8,
    icon: []const u8 = "",
};

const quick_launch_items = [_]QuickLaunchSpec{
    .{ .kind = "show_desktop", .title = "Desktop anzeigen", .policy = "action" },
    .{ .kind = "program", .title = "Computer", .path = "/R4OS/SOFTWARE/DESKTOP/EXPLORER.R4X", .policy = "gui", .icon = "/R4OS/Media/Icons/Folder.ico" },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var output_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            output_dir = args[i];
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return error.BadArgs;
        }
    }

    const out_dir = output_dir orelse return error.MissingOutput;

    for (stale_or_default_hive_files) |file_name| {
        const stale_path = try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ out_dir, file_name });
        defer allocator.free(stale_path);
        cwd.deleteFile(io, stale_path) catch {};
    }

    const bytes = try buildSystemHive(allocator);
    defer allocator.free(bytes);

    const out_path = try std.fmt.allocPrint(allocator, "{s}\\SYSTEM.R4R", .{out_dir});
    defer allocator.free(out_path);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = bytes });

    std.debug.print("Default Registry hives created: {s}\n", .{out_dir});
}

fn buildSystemHive(allocator: std.mem.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();

    var values: std.ArrayList(BuildValue) = .empty;
    defer values.deinit(scratch);

    try addString(scratch, &values, "SYSTEM\\Environment", "PATH", default_terminal_path);

    try addBool(scratch, &values, "SYSTEM\\Shell\\Taskbar\\QuickLaunch", "Enabled", true);
    try addU32(scratch, &values, "SYSTEM\\Shell\\Taskbar\\QuickLaunch", "Count", quick_launch_items.len);
    for (quick_launch_items, 0..) |item, index| {
        const key = try std.fmt.allocPrint(scratch, "SYSTEM\\Shell\\Taskbar\\QuickLaunch\\Item{d}", .{index});
        try addString(scratch, &values, key, "Kind", item.kind);
        try addString(scratch, &values, key, "Title", item.title);
        try addString(scratch, &values, key, "Policy", item.policy);
        if (item.path.len != 0) try addString(scratch, &values, key, "Path", item.path);
        if (item.args.len != 0) try addString(scratch, &values, key, "Args", item.args);
        if (item.icon.len != 0) try addString(scratch, &values, key, "Icon", item.icon);
    }

    try addBool(scratch, &values, "SYSTEM\\Shell\\RecentDocuments", "Enabled", true);
    try addU32(scratch, &values, "SYSTEM\\Shell\\RecentDocuments", "Count", 0);
    try addU32(scratch, &values, "SYSTEM\\Shell\\RecentDocuments", "MaxItems", 8);

    try addBool(scratch, &values, sshd_registry_key, "Enabled", true);
    try addString(scratch, &values, sshd_registry_key, "ClientTarget", "WindowsOpenSSH");
    try addString(scratch, &values, sshd_registry_key, "UserName", "r4os");
    try addString(scratch, &values, sshd_registry_key, "Password", "rosebud");
    try addU32(scratch, &values, sshd_registry_key, "ListenPort", 22);
    try addU32(scratch, &values, sshd_registry_key, "MaxSessions", 8);
    try addBool(scratch, &values, sshd_registry_key, "LogPasswords", true);
    try addString(scratch, &values, sshd_registry_key, "ShellPath", "C:\\R4OS\\SOFTWARE\\TERMINAL\\TERMINAL.R4X");
    try addString(scratch, &values, sshd_registry_key, "ShellArgs", "/NOAUTOEXEC");
    try addString(scratch, &values, sshd_registry_key, "SftpRoot", "/C/");
    try addString(scratch, &values, sshd_registry_key, "HostKeyType", "ed25519");

    return buildHive(allocator, values.items);
}

fn addString(allocator: std.mem.Allocator, values: *std.ArrayList(BuildValue), key_path: []const u8, name: []const u8, data: []const u8) !void {
    try values.append(allocator, .{ .key_path = key_path, .name = name, .value_type = .string, .data = data });
}

fn addBool(allocator: std.mem.Allocator, values: *std.ArrayList(BuildValue), key_path: []const u8, name: []const u8, value: bool) !void {
    const data = if (value) bool_true[0..] else bool_false[0..];
    try values.append(allocator, .{ .key_path = key_path, .name = name, .value_type = .bool, .data = data });
}

fn addU32(allocator: std.mem.Allocator, values: *std.ArrayList(BuildValue), key_path: []const u8, name: []const u8, value: usize) !void {
    const data = try allocator.alloc(u8, 4);
    const v: u32 = @intCast(value);
    data[0] = @intCast(v & 0xff);
    data[1] = @intCast((v >> 8) & 0xff);
    data[2] = @intCast((v >> 16) & 0xff);
    data[3] = @intCast((v >> 24) & 0xff);
    try values.append(allocator, .{ .key_path = key_path, .name = name, .value_type = .u32, .data = data });
}

fn buildHive(allocator: std.mem.Allocator, values: []const BuildValue) ![]u8 {
    var nodes: std.ArrayList(BuildNode) = .empty;
    defer {
        for (nodes.items) |*node| node.deinit(allocator);
        nodes.deinit(allocator);
    }
    try nodes.append(allocator, .{ .parent = invalid_index, .name = "" });

    for (values) |value| {
        const key_index = try ensureKeyPath(allocator, &nodes, value.key_path);
        try nodes.items[key_index].values.append(allocator, value);
    }

    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(allocator);
    try order.append(allocator, 0);
    nodes.items[0].flat_index = 0;
    var cursor: usize = 0;
    while (cursor < order.items.len) : (cursor += 1) {
        const build_index = order.items[cursor];
        for (nodes.items[build_index].children.items) |child_index| {
            nodes.items[child_index].flat_index = @intCast(order.items.len);
            try order.append(allocator, child_index);
        }
    }

    var string_heap: std.ArrayList(u8) = .empty;
    defer string_heap.deinit(allocator);
    var data_heap: std.ArrayList(u8) = .empty;
    defer data_heap.deinit(allocator);
    var flat_keys: std.ArrayList(FlatKey) = .empty;
    defer flat_keys.deinit(allocator);
    var flat_values: std.ArrayList(FlatValue) = .empty;
    defer flat_values.deinit(allocator);

    for (order.items) |build_index| {
        const node = &nodes.items[build_index];
        const first_value = if (node.values.items.len == 0) invalid_index else @as(u32, @intCast(flat_values.items.len));
        for (node.values.items) |value| {
            try flat_values.append(allocator, .{
                .owner_key_index = node.flat_index,
                .name_offset = try appendHeap(allocator, &string_heap, value.name),
                .name_len = @intCast(value.name.len),
                .value_type = value.value_type,
                .data_offset = try appendHeap(allocator, &data_heap, value.data),
                .data_len = @intCast(value.data.len),
            });
        }

        try flat_keys.append(allocator, .{
            .parent_index = if (node.parent == invalid_index) invalid_index else nodes.items[node.parent].flat_index,
            .name_offset = if (node.name.len == 0) 0 else try appendHeap(allocator, &string_heap, node.name),
            .name_len = @intCast(node.name.len),
            .first_value_index = first_value,
            .value_count = @intCast(node.values.items.len),
            .first_child_index = if (node.children.items.len == 0) invalid_index else nodes.items[node.children.items[0]].flat_index,
            .child_count = @intCast(node.children.items.len),
        });
    }

    return emitHive(allocator, flat_keys.items, flat_values.items, string_heap.items, data_heap.items);
}

fn ensureKeyPath(allocator: std.mem.Allocator, nodes: *std.ArrayList(BuildNode), path: []const u8) !u32 {
    var rest = stripSystemRoot(path) orelse return error.BadPath;
    var current: u32 = 0;
    while (nextComponent(&rest)) |component| {
        if (findBuildChild(nodes.*, current, component)) |existing| {
            current = existing;
            continue;
        }
        const new_index: u32 = @intCast(nodes.items.len);
        try nodes.append(allocator, .{ .parent = current, .name = component });
        try nodes.items[current].children.append(allocator, new_index);
        current = new_index;
    }
    return current;
}

fn stripSystemRoot(path: []const u8) ?[]const u8 {
    const split = findRootEnd(path);
    if (!equalsIgnoreCase(path[0..split], "SYSTEM")) return null;
    if (split >= path.len) return "";
    return trimSeparators(path[split + 1 ..]);
}

fn nextComponent(rest: *[]const u8) ?[]const u8 {
    rest.* = trimSeparators(rest.*);
    if (rest.len == 0) return null;
    const split = findRootEnd(rest.*);
    const component = rest.*[0..split];
    if (split < rest.len) {
        rest.* = rest.*[split + 1 ..];
    } else {
        rest.* = rest.*[split..];
    }
    return component;
}

fn findBuildChild(nodes: std.ArrayList(BuildNode), parent_index: u32, name: []const u8) ?u32 {
    for (nodes.items[parent_index].children.items) |child_index| {
        if (equalsIgnoreCase(nodes.items[child_index].name, name)) return child_index;
    }
    return null;
}

fn emitHive(allocator: std.mem.Allocator, keys: []const FlatKey, values: []const FlatValue, string_heap: []const u8, data_heap: []const u8) ![]u8 {
    const key_table_offset: usize = header_size;
    const key_table_size = keys.len * key_record_size;
    const value_table_offset = key_table_offset + key_table_size;
    const value_table_size = values.len * value_record_size;
    const string_heap_offset = value_table_offset + value_table_size;
    const data_heap_offset = string_heap_offset + string_heap.len;
    const file_size = data_heap_offset + data_heap.len;

    const out = try allocator.alloc(u8, file_size);
    @memset(out, 0);
    @memcpy(out[0..4], magic);
    writeU16(out, 4, 1);
    writeU16(out, 6, header_size);
    writeU16(out, 8, 1);
    writeU16(out, 10, 1);
    writeU64(out, 16, file_size);
    writeU64(out, 24, 1);
    writeU32(out, 32, @intCast(key_table_offset));
    writeU32(out, 36, @intCast(keys.len));
    writeU32(out, 40, if (values.len == 0) 0 else @as(u32, @intCast(value_table_offset)));
    writeU32(out, 44, @intCast(values.len));
    writeU32(out, 48, if (string_heap.len == 0) 0 else @as(u32, @intCast(string_heap_offset)));
    writeU32(out, 52, @intCast(string_heap.len));
    writeU32(out, 56, if (data_heap.len == 0) 0 else @as(u32, @intCast(data_heap_offset)));
    writeU32(out, 60, @intCast(data_heap.len));

    for (keys, 0..) |key, index| {
        const offset = key_table_offset + index * key_record_size;
        writeU32(out, offset + 0, key.parent_index);
        writeU32(out, offset + 4, key.name_offset);
        writeU16(out, offset + 8, key.name_len);
        writeU32(out, offset + 12, key.first_value_index);
        writeU32(out, offset + 16, key.value_count);
        writeU32(out, offset + 20, key.first_child_index);
        writeU32(out, offset + 24, key.child_count);
    }

    for (values, 0..) |value, index| {
        const offset = value_table_offset + index * value_record_size;
        writeU32(out, offset + 0, value.owner_key_index);
        writeU32(out, offset + 4, value.name_offset);
        writeU16(out, offset + 8, value.name_len);
        writeU16(out, offset + 10, @intFromEnum(value.value_type));
        writeU32(out, offset + 16, value.data_offset);
        writeU32(out, offset + 20, value.data_len);
    }

    if (string_heap.len > 0) @memcpy(out[string_heap_offset .. string_heap_offset + string_heap.len], string_heap);
    if (data_heap.len > 0) @memcpy(out[data_heap_offset .. data_heap_offset + data_heap.len], data_heap);
    return out;
}

fn appendHeap(allocator: std.mem.Allocator, heap: *std.ArrayList(u8), data: []const u8) !u32 {
    const offset: u32 = @intCast(heap.items.len);
    try heap.appendSlice(allocator, data);
    return offset;
}

fn findRootEnd(path: []const u8) usize {
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '\\' or path[index] == '/') return index;
    }
    return path.len;
}

fn trimSeparators(path: []const u8) []const u8 {
    var start: usize = 0;
    var end = path.len;
    while (start < end and (path[start] == '\\' or path[start] == '/')) : (start += 1) {}
    while (end > start and (path[end - 1] == '\\' or path[end - 1] == '/')) : (end -= 1) {}
    return path[start..end];
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (asciiUpper(a[index]) != asciiUpper(b[index])) return false;
    }
    return true;
}

fn asciiUpper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @intCast(value & 0xff);
    bytes[offset + 1] = @intCast((value >> 8) & 0xff);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @intCast(value & 0xff);
    bytes[offset + 1] = @intCast((value >> 8) & 0xff);
    bytes[offset + 2] = @intCast((value >> 16) & 0xff);
    bytes[offset + 3] = @intCast((value >> 24) & 0xff);
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    writeU32(bytes, offset, @intCast(value & 0xffff_ffff));
    writeU32(bytes, offset + 4, @intCast(value >> 32));
}
