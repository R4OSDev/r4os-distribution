const std = @import("std");
const r4f = @import("r4f_format");

const Table = struct {
    tag: u32,
    offset: u32,
    size: u32,
    flags: u32 = 0,
};

pub const BitmapGlyph = struct {
    codepoint: u32,
    rows: [8]u8,
};

const BitmapOptions = struct {
    family_name: []const u8,
    face_name: []const u8,
    style_name: []const u8 = "Regular",
    source_name: []const u8 = "generated",
    first_codepoint: u32 = 0x20,
    pixel_width: u16 = 8,
    pixel_height: u16,
    row_scale: usize = 1,
    weight: u16 = 400,
    style_flags: u32 = r4f.STYLE_MONOSPACE,
    charset: u16 = r4f.CHARSET_CP437,
    extra_glyphs: []const BitmapGlyph = &.{},
};

pub fn writeBuiltinAsciiBitmap(allocator: std.mem.Allocator, glyphs: []const [8]u8, opts: BitmapOptions) ![]u8 {
    if (opts.pixel_width != 8 or opts.pixel_height == 0 or opts.pixel_height > 64) return error.UnsupportedBitmapSize;
    if (opts.row_scale == 0 or opts.pixel_height != 8 * opts.row_scale) return error.BadRowScale;
    const glyph_count = glyphs.len + opts.extra_glyphs.len;
    if (glyphs.len == 0 or glyph_count > std.math.maxInt(u16)) return error.BadGlyphCount;

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(allocator);
    try names.append(allocator, 0);
    const family_off = try addName(&names, allocator, opts.family_name);
    const face_off = try addName(&names, allocator, opts.face_name);
    const style_off = try addName(&names, allocator, opts.style_name);
    const source_off = try addName(&names, allocator, opts.source_name);

    var face: std.ArrayList(u8) = .empty;
    defer face.deinit(allocator);
    try writeFaceRecord(&face, allocator, .{
        .kind = r4f.FONT_KIND_BITMAP,
        .style_flags = opts.style_flags,
        .weight = opts.weight,
        .charset_flags = charsetFlags(opts.charset) | r4f.CHARSET_FLAG_UNICODE,
        .units_per_em = opts.pixel_height,
        .ascent = @intCast(opts.pixel_height - 1),
        .descent = 1,
        .line_height = @intCast(opts.pixel_height),
        .family_off = family_off,
        .face_off = face_off,
        .style_off = style_off,
        .source_off = source_off,
        .raw_table = 0,
    });

    var strike: std.ArrayList(u8) = .empty;
    defer strike.deinit(allocator);
    try appendU16(&strike, allocator, 0);
    try appendU16(&strike, allocator, 0);
    try appendU16(&strike, allocator, opts.pixel_width);
    try appendU16(&strike, allocator, opts.pixel_height);
    try appendU16(&strike, allocator, opts.pixel_width);
    try appendU16(&strike, allocator, opts.pixel_height);
    try appendI16(&strike, allocator, @intCast(opts.pixel_height - 1));
    try appendI16(&strike, allocator, 1);
    try appendI16(&strike, allocator, @intCast(opts.pixel_height));
    try appendI16(&strike, allocator, @intCast(opts.pixel_height - 1));
    try appendU16(&strike, allocator, r4f.BITMAP_FORMAT_MONO1_MSB);
    try appendU16(&strike, allocator, 1);
    try appendU32(&strike, allocator, @intCast(glyph_count));
    try appendU32(&strike, allocator, 0);
    try appendU32(&strike, allocator, 0);
    try appendU32(&strike, allocator, 0);

    var gmap: std.ArrayList(u8) = .empty;
    defer gmap.deinit(allocator);
    try appendU32(&gmap, allocator, @intCast(glyph_count));
    for (glyphs, 0..) |_, glyph_id| {
        try appendU16(&gmap, allocator, 0);
        try appendU16(&gmap, allocator, opts.charset);
        try appendU32(&gmap, allocator, opts.first_codepoint + @as(u32, @intCast(glyph_id)));
        try appendU32(&gmap, allocator, @intCast(glyph_id));
        try appendU32(&gmap, allocator, 0);
    }
    for (opts.extra_glyphs, glyphs.len..) |glyph, glyph_id| {
        try appendU16(&gmap, allocator, 0);
        try appendU16(&gmap, allocator, opts.charset);
        try appendU32(&gmap, allocator, glyph.codepoint);
        try appendU32(&gmap, allocator, @intCast(glyph_id));
        try appendU32(&gmap, allocator, 0);
    }

    var gmet: std.ArrayList(u8) = .empty;
    defer gmet.deinit(allocator);
    try appendU32(&gmet, allocator, @intCast(glyph_count));
    var metric_glyph_id: usize = 0;
    while (metric_glyph_id < glyph_count) : (metric_glyph_id += 1) {
        try appendU32(&gmet, allocator, @intCast(metric_glyph_id));
        try appendI16(&gmet, allocator, @intCast(opts.pixel_width));
        try appendI16(&gmet, allocator, 0);
        try appendI16(&gmet, allocator, 0);
        try appendI16(&gmet, allocator, @intCast(opts.pixel_height - 1));
        try appendI16(&gmet, allocator, 0);
        try appendI16(&gmet, allocator, 0);
        try appendI16(&gmet, allocator, @intCast(opts.pixel_width));
        try appendI16(&gmet, allocator, @intCast(opts.pixel_height));
        try appendU16(&gmet, allocator, 0);
        try appendU16(&gmet, allocator, 0);
    }

    var bdat: std.ArrayList(u8) = .empty;
    defer bdat.deinit(allocator);
    const record_area_size: usize = 8 + glyph_count * r4f.BITMAP_GLYPH_RECORD_SIZE;
    try appendU32(&bdat, allocator, @intCast(glyph_count));
    try appendU32(&bdat, allocator, @intCast(record_area_size));
    var payload_offset: u32 = @intCast(record_area_size);
    for (glyphs, 0..) |_, glyph_id| {
        try appendU32(&bdat, allocator, @intCast(glyph_id));
        try appendU16(&bdat, allocator, 0);
        try appendU16(&bdat, allocator, r4f.BITMAP_FORMAT_MONO1_MSB);
        try appendU32(&bdat, allocator, payload_offset);
        try appendU32(&bdat, allocator, opts.pixel_height);
        payload_offset += opts.pixel_height;
    }
    for (opts.extra_glyphs, glyphs.len..) |_, glyph_id| {
        try appendU32(&bdat, allocator, @intCast(glyph_id));
        try appendU16(&bdat, allocator, 0);
        try appendU16(&bdat, allocator, r4f.BITMAP_FORMAT_MONO1_MSB);
        try appendU32(&bdat, allocator, payload_offset);
        try appendU32(&bdat, allocator, opts.pixel_height);
        payload_offset += opts.pixel_height;
    }
    for (glyphs) |glyph| {
        for (glyph) |row| {
            var n: usize = 0;
            while (n < opts.row_scale) : (n += 1) {
                try bdat.append(allocator, row);
            }
        }
    }
    for (opts.extra_glyphs) |glyph| {
        for (glyph.rows) |row| {
            var n: usize = 0;
            while (n < opts.row_scale) : (n += 1) try bdat.append(allocator, row);
        }
    }

    const tables = [_]Table{
        .{ .tag = r4f.TABLE_NAME, .offset = 0, .size = @intCast(names.items.len) },
        .{ .tag = r4f.TABLE_FACE, .offset = 0, .size = @intCast(face.items.len) },
        .{ .tag = r4f.TABLE_STRIKE, .offset = 0, .size = @intCast(strike.items.len) },
        .{ .tag = r4f.TABLE_GLYPH_MAP, .offset = 0, .size = @intCast(gmap.items.len) },
        .{ .tag = r4f.TABLE_GLYPH_METRICS, .offset = 0, .size = @intCast(gmet.items.len) },
        .{ .tag = r4f.TABLE_BITMAP_DATA, .offset = 0, .size = @intCast(bdat.items.len) },
    };
    const payloads = [_][]const u8{ names.items, face.items, strike.items, gmap.items, gmet.items, bdat.items };
    return writeContainer(allocator, r4f.FLAG_HAS_BITMAP, 1, 1, @intCast(glyph_count), tables[0..], payloads[0..]);
}

pub const RasterGlyph = struct {
    codepoint: u32,
    width: u16,
    height: u16,
    advance: i16,
    data: []const u8,
};

pub const RasterOptions = struct {
    family_name: []const u8,
    face_name: []const u8,
    style_name: []const u8 = "Regular",
    source_name: []const u8,
    pixel_height: u16,
    ascent: i16,
    descent: i16,
    line_height: i16,
    weight: u16 = 400,
    style_flags: u32 = 0,
    charset: u16 = r4f.CHARSET_WINDOWS_1252,
};

pub fn writeRasterFont(allocator: std.mem.Allocator, glyphs: []const RasterGlyph, opts: RasterOptions) ![]u8 {
    if (glyphs.len == 0 or glyphs.len > std.math.maxInt(u16)) return error.BadGlyphCount;
    if (opts.pixel_height == 0) return error.UnsupportedBitmapSize;
    var max_width: u16 = 0;
    var max_bytes_per_row: u16 = 0;
    for (glyphs) |g| {
        if (g.height != opts.pixel_height or g.width == 0) return error.UnsupportedBitmapSize;
        const bpr: u16 = @intCast((@as(usize, g.width) + 7) / 8);
        if (g.data.len < @as(usize, bpr) * opts.pixel_height) return error.ShortGlyphData;
        if (g.width > max_width) max_width = g.width;
        if (bpr > max_bytes_per_row) max_bytes_per_row = bpr;
    }

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(allocator);
    try names.append(allocator, 0);
    const family_off = try addName(&names, allocator, opts.family_name);
    const face_off = try addName(&names, allocator, opts.face_name);
    const style_off = try addName(&names, allocator, opts.style_name);
    const source_off = try addName(&names, allocator, opts.source_name);

    var face: std.ArrayList(u8) = .empty;
    defer face.deinit(allocator);
    try writeFaceRecord(&face, allocator, .{
        .kind = r4f.FONT_KIND_BITMAP,
        .style_flags = opts.style_flags,
        .weight = opts.weight,
        .charset_flags = charsetFlags(opts.charset) | r4f.CHARSET_FLAG_UNICODE,
        .units_per_em = opts.pixel_height,
        .ascent = opts.ascent,
        .descent = opts.descent,
        .line_height = opts.line_height,
        .family_off = family_off,
        .face_off = face_off,
        .style_off = style_off,
        .source_off = source_off,
        .raw_table = 0,
    });

    var strike: std.ArrayList(u8) = .empty;
    defer strike.deinit(allocator);
    try appendU16(&strike, allocator, 0);
    try appendU16(&strike, allocator, 0);
    try appendU16(&strike, allocator, opts.pixel_height);
    try appendU16(&strike, allocator, opts.pixel_height);
    try appendU16(&strike, allocator, max_width);
    try appendU16(&strike, allocator, opts.pixel_height);
    try appendI16(&strike, allocator, opts.ascent);
    try appendI16(&strike, allocator, opts.descent);
    try appendI16(&strike, allocator, opts.line_height);
    try appendI16(&strike, allocator, opts.ascent);
    try appendU16(&strike, allocator, r4f.BITMAP_FORMAT_MONO1_MSB);
    try appendU16(&strike, allocator, max_bytes_per_row);
    try appendU32(&strike, allocator, @intCast(glyphs.len));
    try appendU32(&strike, allocator, 0);
    try appendU32(&strike, allocator, 0);
    try appendU32(&strike, allocator, 0);

    var gmap: std.ArrayList(u8) = .empty;
    defer gmap.deinit(allocator);
    try appendU32(&gmap, allocator, @intCast(glyphs.len));
    for (glyphs, 0..) |g, glyph_id| {
        try appendU16(&gmap, allocator, 0);
        try appendU16(&gmap, allocator, opts.charset);
        try appendU32(&gmap, allocator, g.codepoint);
        try appendU32(&gmap, allocator, @intCast(glyph_id));
        try appendU32(&gmap, allocator, 0);
    }

    var gmet: std.ArrayList(u8) = .empty;
    defer gmet.deinit(allocator);
    try appendU32(&gmet, allocator, @intCast(glyphs.len));
    for (glyphs, 0..) |g, glyph_id| {
        try appendU32(&gmet, allocator, @intCast(glyph_id));
        try appendI16(&gmet, allocator, g.advance);
        try appendI16(&gmet, allocator, 0);
        try appendI16(&gmet, allocator, 0);
        try appendI16(&gmet, allocator, opts.ascent);
        try appendI16(&gmet, allocator, 0);
        try appendI16(&gmet, allocator, 0);
        try appendI16(&gmet, allocator, @intCast(g.width));
        try appendI16(&gmet, allocator, @intCast(g.height));
        try appendU16(&gmet, allocator, 0);
        try appendU16(&gmet, allocator, 0);
    }

    var bdat: std.ArrayList(u8) = .empty;
    defer bdat.deinit(allocator);
    const record_area_size: usize = 8 + glyphs.len * r4f.BITMAP_GLYPH_RECORD_SIZE;
    try appendU32(&bdat, allocator, @intCast(glyphs.len));
    try appendU32(&bdat, allocator, @intCast(record_area_size));
    var payload_offset: u32 = @intCast(record_area_size);
    for (glyphs, 0..) |g, glyph_id| {
        const size: u32 = @intCast(@as(usize, max_bytes_per_row) * g.height);
        try appendU32(&bdat, allocator, @intCast(glyph_id));
        try appendU16(&bdat, allocator, 0);
        try appendU16(&bdat, allocator, r4f.BITMAP_FORMAT_MONO1_MSB);
        try appendU32(&bdat, allocator, payload_offset);
        try appendU32(&bdat, allocator, size);
        payload_offset += size;
    }
    for (glyphs) |g| {
        const glyph_bytes_per_row: usize = (@as(usize, g.width) + 7) / 8;
        var row: usize = 0;
        while (row < g.height) : (row += 1) {
            const source = row * glyph_bytes_per_row;
            try bdat.appendSlice(allocator, g.data[source .. source + glyph_bytes_per_row]);
            var padding = glyph_bytes_per_row;
            while (padding < max_bytes_per_row) : (padding += 1) try bdat.append(allocator, 0);
        }
    }

    const tables = [_]Table{
        .{ .tag = r4f.TABLE_NAME, .offset = 0, .size = @intCast(names.items.len) },
        .{ .tag = r4f.TABLE_FACE, .offset = 0, .size = @intCast(face.items.len) },
        .{ .tag = r4f.TABLE_STRIKE, .offset = 0, .size = @intCast(strike.items.len) },
        .{ .tag = r4f.TABLE_GLYPH_MAP, .offset = 0, .size = @intCast(gmap.items.len) },
        .{ .tag = r4f.TABLE_GLYPH_METRICS, .offset = 0, .size = @intCast(gmet.items.len) },
        .{ .tag = r4f.TABLE_BITMAP_DATA, .offset = 0, .size = @intCast(bdat.items.len) },
    };
    const payloads = [_][]const u8{ names.items, face.items, strike.items, gmap.items, gmet.items, bdat.items };
    return writeContainer(allocator, r4f.FLAG_HAS_BITMAP, 1, 1, @intCast(glyphs.len), tables[0..], payloads[0..]);
}

pub const SfntOptions = struct {
    family_name: []const u8,
    face_name: []const u8,
    style_name: []const u8 = "Regular",
    source_name: []const u8,
    weight: u16 = 400,
    style_flags: u32 = 0,
    units_per_em: u16 = 0,
    ascent: i16 = 0,
    descent: i16 = 0,
    line_height: i16 = 0,
    required_mask: u32,
};

pub fn writeSfntFont(allocator: std.mem.Allocator, sfnt: []const u8, opts: SfntOptions) ![]u8 {
    if (sfnt.len == 0 or sfnt.len > std.math.maxInt(u32)) return error.BadSfntSize;
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(allocator);
    try names.append(allocator, 0);
    const family_off = try addName(&names, allocator, opts.family_name);
    const face_off = try addName(&names, allocator, opts.face_name);
    const style_off = try addName(&names, allocator, opts.style_name);
    const source_off = try addName(&names, allocator, opts.source_name);

    var face: std.ArrayList(u8) = .empty;
    defer face.deinit(allocator);
    try writeFaceRecord(&face, allocator, .{
        .kind = r4f.FONT_KIND_SFNT_TRUETYPE,
        .style_flags = opts.style_flags,
        .weight = opts.weight,
        .charset_flags = r4f.CHARSET_FLAG_UNICODE | r4f.CHARSET_FLAG_WINDOWS_1252,
        .units_per_em = opts.units_per_em,
        .ascent = opts.ascent,
        .descent = opts.descent,
        .line_height = opts.line_height,
        .family_off = family_off,
        .face_off = face_off,
        .style_off = style_off,
        .source_off = source_off,
        .raw_table = r4f.TABLE_SFNT,
    });

    var sfnt_table: std.ArrayList(u8) = .empty;
    defer sfnt_table.deinit(allocator);
    const payload_offset = 4 + r4f.SFNT_RECORD_SIZE;
    try appendU32(&sfnt_table, allocator, 1);
    try appendU16(&sfnt_table, allocator, 0);
    try appendU16(&sfnt_table, allocator, r4f.SFNT_KIND_TRUETYPE);
    try appendU16(&sfnt_table, allocator, opts.units_per_em);
    try appendU16(&sfnt_table, allocator, 0);
    try appendU32(&sfnt_table, allocator, payload_offset);
    try appendU32(&sfnt_table, allocator, @intCast(sfnt.len));
    try appendU32(&sfnt_table, allocator, checksum(sfnt));
    try appendU32(&sfnt_table, allocator, opts.required_mask);
    try sfnt_table.appendSlice(allocator, sfnt);

    const tables = [_]Table{
        .{ .tag = r4f.TABLE_NAME, .offset = 0, .size = @intCast(names.items.len) },
        .{ .tag = r4f.TABLE_FACE, .offset = 0, .size = @intCast(face.items.len) },
        .{ .tag = r4f.TABLE_SFNT, .offset = 0, .size = @intCast(sfnt_table.items.len) },
    };
    const payloads = [_][]const u8{ names.items, face.items, sfnt_table.items };
    return writeContainer(allocator, r4f.FLAG_HAS_SFNT | r4f.FLAG_HAS_OUTLINE, 1, 0, 0, tables[0..], payloads[0..]);
}

pub const OutlineOptions = struct {
    family_name: []const u8,
    face_name: []const u8,
    style_name: []const u8 = "Regular",
    source_name: []const u8,
    kind: u16 = r4f.OUTLINE_KIND_WINDOWS_VECTOR_FNT,
    weight: u16 = 400,
    style_flags: u32 = 0,
    units_per_em: u16 = 0,
    ascent: i16 = 0,
    descent: i16 = 0,
    line_height: i16 = 0,
};

pub fn writeOutlineFont(allocator: std.mem.Allocator, outline: []const u8, opts: OutlineOptions) ![]u8 {
    if (outline.len == 0 or outline.len > std.math.maxInt(u32)) return error.BadOutlineSize;
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(allocator);
    try names.append(allocator, 0);
    const family_off = try addName(&names, allocator, opts.family_name);
    const face_off = try addName(&names, allocator, opts.face_name);
    const style_off = try addName(&names, allocator, opts.style_name);
    const source_off = try addName(&names, allocator, opts.source_name);

    var face: std.ArrayList(u8) = .empty;
    defer face.deinit(allocator);
    try writeFaceRecord(&face, allocator, .{
        .kind = r4f.FONT_KIND_WINDOWS_VECTOR,
        .style_flags = opts.style_flags,
        .weight = opts.weight,
        .charset_flags = r4f.CHARSET_FLAG_WINDOWS_1252,
        .units_per_em = opts.units_per_em,
        .ascent = opts.ascent,
        .descent = opts.descent,
        .line_height = opts.line_height,
        .family_off = family_off,
        .face_off = face_off,
        .style_off = style_off,
        .source_off = source_off,
        .raw_table = r4f.TABLE_OUTLINE,
    });

    var outl: std.ArrayList(u8) = .empty;
    defer outl.deinit(allocator);
    const payload_offset = 4 + r4f.OUTLINE_RECORD_SIZE;
    try appendU32(&outl, allocator, 1);
    try appendU16(&outl, allocator, 0);
    try appendU16(&outl, allocator, opts.kind);
    try appendU16(&outl, allocator, opts.units_per_em);
    try appendU16(&outl, allocator, 0);
    try appendU32(&outl, allocator, payload_offset);
    try appendU32(&outl, allocator, @intCast(outline.len));
    try appendU32(&outl, allocator, 0);
    try appendU32(&outl, allocator, 0);
    try outl.appendSlice(allocator, outline);

    const tables = [_]Table{
        .{ .tag = r4f.TABLE_NAME, .offset = 0, .size = @intCast(names.items.len) },
        .{ .tag = r4f.TABLE_FACE, .offset = 0, .size = @intCast(face.items.len) },
        .{ .tag = r4f.TABLE_OUTLINE, .offset = 0, .size = @intCast(outl.items.len) },
    };
    const payloads = [_][]const u8{ names.items, face.items, outl.items };
    return writeContainer(allocator, r4f.FLAG_HAS_OUTLINE, 1, 0, 0, tables[0..], payloads[0..]);
}

const FaceRecordOptions = struct {
    kind: u16,
    style_flags: u32,
    weight: u16,
    charset_flags: u32,
    units_per_em: u16,
    ascent: i16,
    descent: i16,
    line_height: i16,
    family_off: u32,
    face_off: u32,
    style_off: u32,
    source_off: u32,
    raw_table: u32,
};

fn writeFaceRecord(out: *std.ArrayList(u8), allocator: std.mem.Allocator, opts: FaceRecordOptions) !void {
    try appendU16(out, allocator, 0);
    try appendU16(out, allocator, opts.kind);
    try appendU32(out, allocator, opts.style_flags);
    try appendU16(out, allocator, opts.weight);
    try appendU16(out, allocator, 5);
    try appendU32(out, allocator, opts.charset_flags);
    try appendU16(out, allocator, opts.units_per_em);
    try appendI16(out, allocator, opts.ascent);
    try appendI16(out, allocator, opts.descent);
    try appendI16(out, allocator, 0);
    try appendI16(out, allocator, 0);
    try appendI16(out, allocator, 0);
    try appendI16(out, allocator, opts.line_height);
    try appendU32(out, allocator, opts.family_off);
    try appendU32(out, allocator, opts.face_off);
    try appendU32(out, allocator, opts.style_off);
    try appendU32(out, allocator, opts.source_off);
    try appendU16(out, allocator, 0);
    try appendU16(out, allocator, 0);
    try appendU32(out, allocator, opts.raw_table);
    try appendU32(out, allocator, 0);
    try appendU32(out, allocator, 0);
    try appendU16(out, allocator, 0);
}

fn writeContainer(
    allocator: std.mem.Allocator,
    flags: u32,
    face_count: u16,
    strike_count: u16,
    glyph_count: u32,
    table_defs: []const Table,
    payloads: []const []const u8,
) ![]u8 {
    if (table_defs.len != payloads.len) return error.BadTableList;
    if (table_defs.len > std.math.maxInt(u16)) return error.TooManyTables;
    const dir_offset: usize = r4f.HEADER_SIZE;
    var cursor: usize = r4f.HEADER_SIZE + table_defs.len * r4f.TABLE_ENTRY_SIZE;
    cursor = align4(cursor);

    var tables = try allocator.alloc(Table, table_defs.len);
    defer allocator.free(tables);
    for (table_defs, 0..) |def, i| {
        cursor = align4(cursor);
        tables[i] = def;
        tables[i].offset = @intCast(cursor);
        tables[i].size = @intCast(payloads[i].len);
        cursor += payloads[i].len;
    }
    const file_size = align4(cursor);

    var out = try std.ArrayList(u8).initCapacity(allocator, file_size);
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &r4f.MAGIC);
    try appendU16(&out, allocator, r4f.VERSION);
    try appendU16(&out, allocator, @intCast(r4f.HEADER_SIZE));
    try appendU32(&out, allocator, flags);
    try appendU32(&out, allocator, @intCast(file_size));
    try appendU32(&out, allocator, @intCast(dir_offset));
    try appendU16(&out, allocator, @intCast(tables.len));
    try appendU16(&out, allocator, face_count);
    try appendU16(&out, allocator, strike_count);
    try appendU16(&out, allocator, 0);
    try appendU32(&out, allocator, glyph_count);

    for (tables) |table_record| {
        try appendU32(&out, allocator, table_record.tag);
        try appendU32(&out, allocator, table_record.offset);
        try appendU32(&out, allocator, table_record.size);
        try appendU32(&out, allocator, table_record.flags);
    }
    try padTo(&out, allocator, align4(out.items.len));
    for (payloads, 0..) |payload, i| {
        try padTo(&out, allocator, tables[i].offset);
        try out.appendSlice(allocator, payload);
    }
    try padTo(&out, allocator, file_size);
    return out.toOwnedSlice(allocator);
}

fn addName(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !u32 {
    if (out.items.len > std.math.maxInt(u32)) return error.NameTableTooLarge;
    const off: u32 = @intCast(out.items.len);
    try out.appendSlice(allocator, value);
    try out.append(allocator, 0);
    return off;
}

fn charsetFlags(charset: u16) u32 {
    if (charset == r4f.CHARSET_CP437) return r4f.CHARSET_FLAG_CP437;
    if (charset == r4f.CHARSET_WINDOWS_1252) return r4f.CHARSET_FLAG_WINDOWS_1252;
    if (charset == r4f.CHARSET_UNICODE) return r4f.CHARSET_FLAG_UNICODE;
    return 0;
}

fn checksum(bytes: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        sum +%= bytes[i];
    }
    return sum;
}

fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], value, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendI16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i16) !void {
    try appendU16(out, allocator, @as(u16, @bitCast(value)));
}

fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], value, .little);
    try out.appendSlice(allocator, &buf);
}

fn align4(value: usize) usize {
    return (value + 3) & ~@as(usize, 3);
}

fn padTo(out: *std.ArrayList(u8), allocator: std.mem.Allocator, target: usize) !void {
    while (out.items.len < target) {
        try out.append(allocator, 0);
    }
}

test "bitmap writer emits R4F1 tables" {
    const allocator = std.testing.allocator;
    const glyphs = [_][8]u8{.{0} ** 8} ** 2;
    const bytes = try writeBuiltinAsciiBitmap(allocator, glyphs[0..], .{
        .family_name = "Test",
        .face_name = "Test 8",
        .source_name = "test",
        .pixel_height = 8,
    });
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &r4f.MAGIC, bytes[0..4]);
    try std.testing.expectEqual(@as(u16, r4f.VERSION), r4f.readU16(bytes[4..6]));
    try std.testing.expectEqual(@as(u16, 6), r4f.readU16(bytes[20..22]));
}

test "bitmap writer includes mapped unicode extras" {
    const allocator = std.testing.allocator;
    const glyphs = [_][8]u8{.{0} ** 8} ** 2;
    const extras = [_]BitmapGlyph{.{ .codepoint = 0xE4, .rows = .{0x18} ** 8 }};
    const bytes = try writeBuiltinAsciiBitmap(allocator, glyphs[0..], .{
        .family_name = "Test",
        .face_name = "Test 8",
        .source_name = "test",
        .pixel_height = 8,
        .extra_glyphs = extras[0..],
    });
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(u32, 3), r4f.readU32(bytes[28..32]));

    const table_count = r4f.readU16(bytes[20..22]);
    var table_index: usize = 0;
    var map_offset: usize = 0;
    while (table_index < table_count) : (table_index += 1) {
        const entry = r4f.HEADER_SIZE + table_index * r4f.TABLE_ENTRY_SIZE;
        if (r4f.readU32(bytes[entry .. entry + 4]) == r4f.TABLE_GLYPH_MAP) {
            map_offset = r4f.readU32(bytes[entry + 4 .. entry + 8]);
            break;
        }
    }
    try std.testing.expect(map_offset > 0);
    const extra_record = map_offset + 4 + 2 * 16;
    try std.testing.expectEqual(@as(u32, 0xE4), r4f.readU32(bytes[extra_record + 4 .. extra_record + 8]));
    try std.testing.expectEqual(@as(u32, 2), r4f.readU32(bytes[extra_record + 8 .. extra_record + 12]));
}
