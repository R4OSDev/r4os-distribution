const std = @import("std");
const base_glyphs = @import("base_glyphs");
const r4f = @import("r4f_format");
const r4f_writer = @import("r4f_writer");

const western_codepoints = [_]u32{ 0x00C4, 0x00D6, 0x00DC, 0x00DF, 0x00E4, 0x00F6, 0x00FC };
const glyph_count = 95 + western_codepoints.len;

const Variant = struct {
    height: u16,
    weight: u16,
    bold: bool,
    face_name: []const u8,
};

const variants = [_]Variant{
    .{ .height = 8, .weight = 400, .bold = false, .face_name = "R4 Sans 8 Regular" },
    .{ .height = 8, .weight = 700, .bold = true, .face_name = "R4 Sans 8 Bold" },
    .{ .height = 12, .weight = 400, .bold = false, .face_name = "R4 Sans 12 Regular" },
    .{ .height = 12, .weight = 700, .bold = true, .face_name = "R4 Sans 12 Bold" },
    .{ .height = 16, .weight = 400, .bold = false, .face_name = "R4 Sans 16 Regular" },
    .{ .height = 16, .weight = 700, .bold = true, .face_name = "R4 Sans 16 Bold" },
    .{ .height = 24, .weight = 400, .bold = false, .face_name = "R4 Sans 24 Regular" },
    .{ .height = 24, .weight = 700, .bold = true, .face_name = "R4 Sans 24 Bold" },
    .{ .height = 32, .weight = 400, .bold = false, .face_name = "R4 Sans 32 Regular" },
    .{ .height = 32, .weight = 700, .bold = true, .face_name = "R4 Sans 32 Bold" },
    .{ .height = 40, .weight = 400, .bold = false, .face_name = "R4 Sans 40 Regular" },
    .{ .height = 40, .weight = 700, .bold = true, .face_name = "R4 Sans 40 Bold" },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != variants.len + 1) {
        std.debug.print("usage: r4sans_fontgen <12 output.r4f paths>\n", .{});
        return error.BadArgs;
    }
    for (variants, 0..) |variant, index| {
        const output = try buildVariant(init.gpa, variant);
        defer init.gpa.free(output);
        if (output.len > 64 * 1024) return error.FontArtifactTooLarge;
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[index + 1], .data = output });
    }
}

fn buildVariant(allocator: std.mem.Allocator, variant: Variant) ![]u8 {
    const max_width = variant.height;
    const max_bytes_per_row = (@as(usize, max_width) + 7) / 8;
    const storage = try allocator.alloc(u8, glyph_count * max_bytes_per_row * variant.height);
    defer allocator.free(storage);
    @memset(storage, 0);
    const raster = try allocator.alloc(r4f_writer.RasterGlyph, glyph_count);
    defer allocator.free(raster);

    var storage_offset: usize = 0;
    var glyph_index: usize = 0;
    var codepoint: u32 = 0x20;
    while (codepoint <= 0x7E) : (codepoint += 1) {
        const rows = base_glyphs.builtin_ascii_font[codepoint - 0x20];
        raster[glyph_index] = rasterizeGlyph(codepoint, rows, variant, storage, &storage_offset);
        glyph_index += 1;
    }
    for (western_codepoints) |western| {
        raster[glyph_index] = rasterizeGlyph(western, base_glyphs.westernGlyph(western), variant, storage, &storage_offset);
        glyph_index += 1;
    }

    const descent: i16 = @intCast(@max(@as(u16, 1), variant.height / 8));
    const ascent: i16 = @intCast(variant.height - @as(u16, @intCast(descent)));
    const line_height: i16 = @intCast(variant.height + @max(@as(u16, 1), variant.height / 8));
    return r4f_writer.writeRasterFont(allocator, raster, .{
        .family_name = "R4 Sans",
        .face_name = variant.face_name,
        .style_name = if (variant.bold) "Bold" else "Regular",
        .source_name = "Code/System/Fonts/R4Sans",
        .pixel_height = variant.height,
        .ascent = ascent,
        .descent = descent,
        .line_height = line_height,
        .weight = variant.weight,
        .style_flags = if (variant.bold) r4f.STYLE_BOLD else 0,
    });
}

fn rasterizeGlyph(
    codepoint: u32,
    rows: [8]u8,
    variant: Variant,
    storage: []u8,
    storage_offset: *usize,
) r4f_writer.RasterGlyph {
    const bounds = inkBounds(rows);
    const spacing = @max(@as(u16, 1), variant.height / 8);
    const bold_pixels: u16 = if (variant.bold) @max(@as(u16, 1), variant.height / 16) else 0;
    const space_width = @max(@as(u16, 2), @divTrunc(variant.height * 3 + 4, 8));
    const source_width: u16 = if (bounds.present) bounds.right - bounds.left + 1 else 0;
    const available_width = variant.height - bold_pixels;
    const scaled_width: u16 = if (bounds.present)
        @max(@as(u16, 1), @as(u16, @intCast(@divTrunc(@as(u32, source_width) * available_width + 7, 8))))
    else
        space_width;
    const width = scaled_width + if (bounds.present) bold_pixels else 0;
    const bytes_per_row = (@as(usize, width) + 7) / 8;
    const byte_count = bytes_per_row * variant.height;
    const data = storage[storage_offset.* .. storage_offset.* + byte_count];
    storage_offset.* += byte_count;
    @memset(data, 0);

    if (bounds.present) {
        var target_y: u16 = 0;
        while (target_y < variant.height) : (target_y += 1) {
            const source_y: usize = @intCast(@divTrunc(@as(u32, target_y) * 8, variant.height));
            var target_x: u16 = 0;
            while (target_x < scaled_width) : (target_x += 1) {
                const source_x: u16 = bounds.left + @as(u16, @intCast(@divTrunc(@as(u32, target_x) * source_width, scaled_width)));
                if ((rows[source_y] & (@as(u8, 0x80) >> @intCast(source_x))) == 0) continue;
                var thick: u16 = 0;
                while (thick <= bold_pixels and target_x + thick < width) : (thick += 1) {
                    setPixel(data, bytes_per_row, target_x + thick, target_y);
                }
            }
        }
    }

    return .{
        .codepoint = codepoint,
        .width = width,
        .height = variant.height,
        .advance = @intCast(if (codepoint == ' ') width else width + spacing),
        .data = data,
    };
}

const Bounds = struct {
    present: bool = false,
    left: u16 = 0,
    right: u16 = 0,
};

fn inkBounds(rows: [8]u8) Bounds {
    var result = Bounds{ .left = 7 };
    for (rows) |row| {
        var x: u16 = 0;
        while (x < 8) : (x += 1) {
            if ((row & (@as(u8, 0x80) >> @intCast(x))) == 0) continue;
            result.present = true;
            result.left = @min(result.left, x);
            result.right = @max(result.right, x);
        }
    }
    return result;
}

fn setPixel(data: []u8, bytes_per_row: usize, x: u16, y: u16) void {
    const byte_index = @as(usize, y) * bytes_per_row + x / 8;
    data[byte_index] |= @as(u8, 0x80) >> @intCast(x % 8);
}

test "R4 Sans derives proportional advances and bounded artifacts" {
    const regular = Variant{ .height = 16, .weight = 400, .bold = false, .face_name = "R4 Sans 16 Regular" };
    const output = try buildVariant(std.testing.allocator, regular);
    defer std.testing.allocator.free(output);
    try std.testing.expect(output.len > 0 and output.len <= 64 * 1024);

    var storage: [256]u8 = undefined;
    var offset: usize = 0;
    const narrow = rasterizeGlyph('i', base_glyphs.builtin_ascii_font['i' - 0x20], regular, storage[0..], &offset);
    const wide = rasterizeGlyph('W', base_glyphs.builtin_ascii_font['W' - 0x20], regular, storage[0..], &offset);
    try std.testing.expect(narrow.advance < wide.advance);
    try std.testing.expect(narrow.width < wide.width);
}

test "R4 Sans bold strike thickens glyphs without becoming monospace" {
    const bold = Variant{ .height = 24, .weight = 700, .bold = true, .face_name = "R4 Sans 24 Bold" };
    var storage: [1024]u8 = undefined;
    var offset: usize = 0;
    const narrow = rasterizeGlyph('i', base_glyphs.builtin_ascii_font['i' - 0x20], bold, storage[0..], &offset);
    const wide = rasterizeGlyph('W', base_glyphs.builtin_ascii_font['W' - 0x20], bold, storage[0..], &offset);
    try std.testing.expect(narrow.advance < wide.advance);
    try std.testing.expect(narrow.width >= 2);
}

test "every bold native face remains inside its R4F em width" {
    var storage: [4096]u8 = undefined;
    for (variants) |variant| {
        if (!variant.bold) continue;
        var offset: usize = 0;
        const glyph = rasterizeGlyph('W', base_glyphs.builtin_ascii_font['W' - 0x20], variant, storage[0..], &offset);
        try std.testing.expect(glyph.width <= variant.height);
        try std.testing.expect(@as(i32, glyph.advance) <= @as(i32, variant.height + @max(@as(u16, 1), variant.height / 8)));
    }
}
