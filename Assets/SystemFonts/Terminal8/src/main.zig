const std = @import("std");
const glyphs = @import("glyphs.zig");
const r4f_writer = @import("r4f_writer");

const output_height: u8 = 8;
const row_scale: usize = 1;
const western_glyphs = [_]r4f_writer.BitmapGlyph{
    .{ .codepoint = 0x00C4, .rows = glyphs.westernGlyph(0x00C4) },
    .{ .codepoint = 0x00D6, .rows = glyphs.westernGlyph(0x00D6) },
    .{ .codepoint = 0x00DC, .rows = glyphs.westernGlyph(0x00DC) },
    .{ .codepoint = 0x00DF, .rows = glyphs.westernGlyph(0x00DF) },
    .{ .codepoint = 0x00E4, .rows = glyphs.westernGlyph(0x00E4) },
    .{ .codepoint = 0x00F6, .rows = glyphs.westernGlyph(0x00F6) },
    .{ .codepoint = 0x00FC, .rows = glyphs.westernGlyph(0x00FC) },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: terminal8_fontgen <output.r4f>\n", .{});
        return error.BadArgs;
    }

    const out = try r4f_writer.writeBuiltinAsciiBitmap(init.gpa, glyphs.builtin_ascii_font[0..], .{
        .family_name = "Terminal",
        .face_name = "Terminal 8",
        .source_name = "Code/System/Fonts/Terminal8",
        .pixel_height = output_height,
        .row_scale = row_scale,
        .extra_glyphs = western_glyphs[0..],
    });
    defer init.gpa.free(out);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = out });
}
