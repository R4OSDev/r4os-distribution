const std = @import("std");

const TreeSpec = struct {
    source_root: []const u8,
    target_root: []const u8,
};

const OverlaySpec = struct {
    source_root: []const u8,
    optional: bool,
};

const PlanEntry = struct {
    source: []const u8,
    target: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var output: ?[]const u8 = null;
    var check = false;
    var plans: std.ArrayList([]const u8) = .empty;
    defer plans.deinit(allocator);
    var trees: std.ArrayList(TreeSpec) = .empty;
    defer trees.deinit(allocator);
    var overlays: std.ArrayList(OverlaySpec) = .empty;
    defer overlays.deinit(allocator);

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= args.len) return usage("missing --output value");
            output = args[index];
        } else if (std.mem.eql(u8, arg, "--plan")) {
            index += 1;
            if (index >= args.len) return usage("missing --plan value");
            try plans.append(allocator, args[index]);
        } else if (std.mem.eql(u8, arg, "--tree")) {
            index += 1;
            if (index >= args.len) return usage("missing --tree value");
            try trees.append(allocator, try parseTreeSpec(args[index]));
        } else if (std.mem.eql(u8, arg, "--overlay")) {
            index += 1;
            if (index >= args.len) return usage("missing --overlay value");
            try overlays.append(allocator, .{ .source_root = args[index], .optional = false });
        } else if (std.mem.eql(u8, arg, "--optional-overlay")) {
            index += 1;
            if (index >= args.len) return usage("missing --optional-overlay value");
            try overlays.append(allocator, .{ .source_root = args[index], .optional = true });
        } else if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "/?")) {
            printUsage();
            return;
        } else {
            std.debug.print("image-plan: unknown argument: {s}\n", .{arg});
            return error.BadArgument;
        }
    }

    const output_path = output orelse return usage("missing --output");
    if (plans.items.len == 0) return usage("at least one --plan is required");

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var plan_entry_count: usize = 0;
    for (plans.items) |path| plan_entry_count += try addPlanFile(&result, allocator, io, cwd, path);
    for (trees.items) |tree| try addTree(&result, allocator, io, cwd, tree);
    for (overlays.items, 0..) |overlay, overlay_index| {
        try addOverlay(&result, allocator, io, cwd, overlays.items, overlay_index, overlay);
    }

    const total_entries = try validateImagePlan(allocator, io, cwd, result.items);
    if (check) {
        const expected = try cwd.readFileAlloc(io, output_path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(expected);
        if (!std.mem.eql(u8, expected, result.items)) {
            std.debug.print("image-plan: generated plan differs from {s}\n", .{output_path});
            return error.PlanMismatch;
        }
        std.debug.print("image-plan: OK {s} ({d} entries)\n", .{ output_path, total_entries });
        return;
    }

    try cwd.writeFile(io, .{ .sub_path = output_path, .data = result.items });
    std.debug.print(
        "image-plan: created {s} ({d} entries, {d} explicit plan entries)\n",
        .{ output_path, total_entries, plan_entry_count },
    );
}

fn usage(reason: []const u8) !void {
    std.debug.print("image-plan: {s}\n", .{reason});
    printUsage();
    return error.BadArgument;
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  image-plan --output FILE --plan FILE [--plan FILE ...]
        \\      [--tree SOURCE_ROOT|/TARGET_ROOT ...]
        \\      [--overlay ROOT ...] [--optional-overlay ROOT ...] [--check]
        \\
        \\Plans use SOURCE:/TARGET lines. The last colon is the separator, so
        \\Windows drive letters remain valid. Later overlays replace matching
        \\relative paths from earlier overlays. No component is built.
        \\
    , .{});
}

fn parseTreeSpec(raw: []const u8) !TreeSpec {
    const split = std.mem.indexOfScalar(u8, raw, '|') orelse return error.BadTreeSpec;
    if (split == 0 or split + 1 >= raw.len or std.mem.indexOfScalarPos(u8, raw, split + 1, '|') != null) {
        return error.BadTreeSpec;
    }
    const source_root = std.mem.trim(u8, raw[0..split], " \t\r\n");
    const target_root = std.mem.trim(u8, raw[split + 1 ..], " \t\r\n");
    if (source_root.len == 0 or !isValidImageTarget(target_root)) return error.BadTreeSpec;
    return .{ .source_root = source_root, .target_root = trimTrailingSlash(target_root) };
}

fn parsePlanEntry(raw: []const u8) !PlanEntry {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    const split = std.mem.lastIndexOfScalar(u8, line, ':') orelse return error.BadPlanLine;
    const source = std.mem.trim(u8, line[0..split], " \t\r\n");
    const target = std.mem.trim(u8, line[split + 1 ..], " \t\r\n");
    if (source.len == 0 or !isValidImageTarget(target)) return error.BadPlanLine;
    return .{ .source = source, .target = target };
}

fn addPlanFile(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
) !usize {
    const text = try cwd.readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(text);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const entry = try parsePlanEntry(line);
        try add(out, allocator, entry.source, entry.target);
        count += 1;
    }
    return count;
}

fn addTree(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    tree: TreeSpec,
) !void {
    var dir = cwd.openDir(io, tree.source_root, .{ .iterate = true }) catch |err| {
        std.debug.print("image-plan: tree root unavailable: {s} ({s})\n", .{ tree.source_root, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    const paths = try collectFiles(allocator, io, dir);
    defer freePaths(allocator, paths);
    for (paths) |path| {
        const source = try std.fs.path.join(allocator, &.{ tree.source_root, path });
        defer allocator.free(source);
        const normalized = try normalizedCopy(allocator, path);
        defer allocator.free(normalized);
        const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tree.target_root, normalized });
        defer allocator.free(target);
        try add(out, allocator, source, target);
    }
}

fn addOverlay(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    overlays: []const OverlaySpec,
    overlay_index: usize,
    overlay: OverlaySpec,
) !void {
    var dir = cwd.openDir(io, overlay.source_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => if (overlay.optional) return else {
            std.debug.print("image-plan: overlay root missing: {s}\n", .{overlay.source_root});
            return err;
        },
        else => return err,
    };
    defer dir.close(io);

    const paths = try collectFiles(allocator, io, dir);
    defer freePaths(allocator, paths);
    for (paths) |path| {
        if (try isOverridden(allocator, io, cwd, overlays[overlay_index + 1 ..], path)) continue;
        const source = try std.fs.path.join(allocator, &.{ overlay.source_root, path });
        defer allocator.free(source);
        const normalized = try normalizedCopy(allocator, path);
        defer allocator.free(normalized);
        const target = try std.fmt.allocPrint(allocator, "/{s}", .{normalized});
        defer allocator.free(target);
        try add(out, allocator, source, target);
    }
}

fn isOverridden(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    later_overlays: []const OverlaySpec,
    relative_path: []const u8,
) !bool {
    for (later_overlays) |later| {
        const candidate = try std.fs.path.join(allocator, &.{ later.source_root, relative_path });
        defer allocator.free(candidate);
        if (exists(cwd, io, candidate)) return true;
    }
    return false;
}

fn collectFiles(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![][]const u8 {
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer freePaths(allocator, paths.items);

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or shouldSkipSourcePath(entry.path)) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessPathIgnoreCase);
    return try paths.toOwnedSlice(allocator);
}

fn freePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn add(out: *std.ArrayList(u8), allocator: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    for (source) |char| try out.append(allocator, if (char == '\\') '/' else char);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, target);
    try out.appendSlice(allocator, "\r\n");
}

fn validateImagePlan(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, text: []const u8) !usize {
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(allocator);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const entry = try parsePlanEntry(line);
        cwd.access(io, entry.source, .{}) catch |err| {
            std.debug.print("image-plan: source missing: {s} -> {s} ({s})\n", .{ entry.source, entry.target, @errorName(err) });
            return error.ImageSourceMissing;
        };
        for (targets.items) |prior| {
            if (std.ascii.eqlIgnoreCase(prior, entry.target)) {
                std.debug.print("image-plan: duplicate target: {s}\n", .{entry.target});
                return error.DuplicateImageTarget;
            }
        }
        try targets.append(allocator, entry.target);
        count += 1;
    }
    return count;
}

fn isValidImageTarget(target: []const u8) bool {
    if (target.len < 2 or target[0] != '/' or std.mem.indexOfScalar(u8, target, '\\') != null or std.mem.indexOfScalar(u8, target, ':') != null) return false;
    if (std.mem.indexOf(u8, target, "//") != null) return false;
    var components = std.mem.tokenizeScalar(u8, target, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn trimTrailingSlash(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
    return path[0..end];
}

fn normalizedCopy(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, path);
    for (result) |*char| if (char.* == '\\') {
        char.* = '/';
    };
    return result;
}

fn lessPathIgnoreCase(_: void, left: []const u8, right: []const u8) bool {
    const count = @min(left.len, right.len);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const left_folded = std.ascii.toLower(left[index]);
        const right_folded = std.ascii.toLower(right[index]);
        if (left_folded != right_folded) return left_folded < right_folded;
    }
    if (left.len != right.len) return left.len < right.len;
    return std.mem.order(u8, left, right) == .lt;
}

fn exists(cwd: std.Io.Dir, io: std.Io, path: []const u8) bool {
    cwd.access(io, path, .{}) catch return false;
    return true;
}

fn shouldSkipSourcePath(relative_path: []const u8) bool {
    var components = std.mem.tokenizeAny(u8, relative_path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".git") or
            std.mem.eql(u8, component, ".zig-cache") or
            std.mem.eql(u8, component, "zig-out") or
            std.mem.eql(u8, component, "zig-pkg")) return true;
    }
    return false;
}

test "plan separator preserves a Windows drive prefix" {
    const entry = try parsePlanEntry("D:/R4OS/Artifacts/KERNEL.ELF:/boot/r4os.elf");
    try std.testing.expectEqualStrings("D:/R4OS/Artifacts/KERNEL.ELF", entry.source);
    try std.testing.expectEqualStrings("/boot/r4os.elf", entry.target);
}

test "image targets reject traversal, separators and drive syntax" {
    try std.testing.expect(isValidImageTarget("/R4OS/SOFTWARE/APP.R4X"));
    try std.testing.expect(!isValidImageTarget("R4OS/SOFTWARE/APP.R4X"));
    try std.testing.expect(!isValidImageTarget("/R4OS/../APP.R4X"));
    try std.testing.expect(!isValidImageTarget("/R4OS\\APP.R4X"));
    try std.testing.expect(!isValidImageTarget("/C:/APP.R4X"));
}

test "tree specifications require one valid target root" {
    const tree = try parseTreeSpec("SDK/Shared/C/include|/R4OS/SDK/Include/C");
    try std.testing.expectEqualStrings("SDK/Shared/C/include", tree.source_root);
    try std.testing.expectEqualStrings("/R4OS/SDK/Include/C", tree.target_root);
    try std.testing.expectError(error.BadTreeSpec, parseTreeSpec("SDK/Shared/C/include"));
}
