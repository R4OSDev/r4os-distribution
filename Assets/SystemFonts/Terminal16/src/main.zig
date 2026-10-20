const std = @import("std");
const glyphs = @import("glyphs.zig");
const r4f_writer = @import("r4f_writer");

const output_height: u8 = 16;
const row_scale: usize = 2;
const extra = @import("extended_glyphs");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: terminal16_fontgen <output.r4f>\n", .{});
        return error.BadArgs;
    }

    const out = try r4f_writer.writeBuiltinAsciiBitmap(init.gpa, glyphs.builtin_ascii_font[0..], .{
        .family_name = "Terminal",
        .face_name = "Terminal 16",
        .source_name = "Distribution/Assets/SystemFonts/Terminal16 0.85.40",
        .pixel_height = output_height,
        .row_scale = row_scale,
        .extra_glyphs = extra.extra_glyphs[0..],
    });
    defer init.gpa.free(out);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = out });
}
