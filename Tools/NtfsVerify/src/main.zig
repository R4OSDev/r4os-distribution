// NtfsVerify: structural NTFS 3.1 volume verifier (0.60.5).
//
// Manifest-free integrity check for NTFS volumes produced by the R4OS
// formatter and for reference volumes: boot sector plus backup, every FILE
// record (fixups, identity), $MFTMirr synchronization, complete cluster
// accounting of all non-resident attribute extents against $Bitmap, $MFT
// record accounting against $MFT/$BITMAP, full $I30 tree walk with per-node
// collation order, reference sequence checks and directory-flag consistency,
// $Volume version and dirty flag.
//
// Usage: ntfsverify <image> [--volume] [--allow-dirty]
//   --volume       image is a bare volume (no MBR, boot sector at offset 0)
//   --allow-dirty  do not fail on a set volume dirty flag

const std = @import("std");
const tools = @import("storage_tools");
const ntfs = tools.ntfs_format;

// Includes the common 2048-MB GPT image. Partition views below are bounded
// to their own extent, so corrupt NTFS runs cannot borrow a sibling volume.
const MAX_IMAGE_BYTES: usize = 4 * 1024 * 1024 * 1024 + 1;
const MAX_ATTR_RUNS: usize = 1024;

var failures: usize = 0;

fn fail(comptime format: []const u8, args: anytype) void {
    failures += 1;
    std.debug.print("NTFSVERIFY FAIL: " ++ format ++ "\n", args);
}

const Volume = struct {
    image: []const u8,
    part_offset: usize,
    boot: ntfs.BootSector,
    record_size: usize,
    mft_runs: [128]ntfs.Run = undefined,
    mft_run_count: usize = 0,
    mft_record_count: u64 = 0,
    upcase: []const u8 = &[_]u8{},

    fn clusterBytes(self: *const Volume) usize {
        return self.boot.cluster_bytes;
    }

    fn lcnOffset(self: *const Volume, lcn: u64) ?usize {
        const offset = self.part_offset + @as(usize, @intCast(lcn)) * self.clusterBytes();
        if (offset >= self.image.len) return null;
        return offset;
    }

    fn mftRecordRaw(self: *const Volume, number: u64) ?[]const u8 {
        var byte_index = number * self.record_size;
        var run_index: usize = 0;
        while (run_index < self.mft_run_count) : (run_index += 1) {
            const run = self.mft_runs[run_index];
            const run_bytes = run.length_clusters * self.clusterBytes();
            if (byte_index < run_bytes) {
                const lcn = run.lcn orelse return null;
                const base = self.lcnOffset(lcn) orelse return null;
                const offset = base + @as(usize, @intCast(byte_index));
                if (offset + self.record_size > self.image.len) return null;
                return self.image[offset .. offset + self.record_size];
            }
            byte_index -= run_bytes;
        }
        return null;
    }

    fn loadRecord(self: *const Volume, number: u64, buf: []u8) ?ntfs.FileRecordHeader {
        const raw = self.mftRecordRaw(number) orelse return null;
        const record = buf[0..self.record_size];
        @memcpy(record, raw);
        if (ntfs.applyFixups(record) != .ok) return null;
        const header = ntfs.FileRecordHeader.parse(record) orelse return null;
        if (header.record_number != number) return null;
        if (!header.inUse()) return null;
        return header;
    }
};

const AttrRuns = struct {
    runs: [MAX_ATTR_RUNS]ntfs.Run = undefined,
    count: usize = 0,
    data_size: u64 = 0,
    initialized_size: u64 = 0,
    flags: u16 = 0,
    resident: bool = false,
    resident_copy: [4096]u8 = undefined,
    resident_len: usize = 0,

    fn appendMapping(self: *AttrRuns, mapping: []const u8) bool {
        var iterator = ntfs.RunlistIterator.init(mapping);
        while (iterator.next()) |run| {
            if (self.count >= self.runs.len) return false;
            self.runs[self.count] = run;
            self.count += 1;
        }
        return !iterator.hadError();
    }
};

fn captureAttribute(attribute: ntfs.Attribute, out: *AttrRuns, is_first: bool) bool {
    if (!attribute.non_resident) {
        if (attribute.value.len > out.resident_copy.len) return false;
        out.resident = true;
        @memcpy(out.resident_copy[0..attribute.value.len], attribute.value);
        out.resident_len = attribute.value.len;
        out.data_size = attribute.value.len;
        out.initialized_size = attribute.value.len;
        out.flags = attribute.flags;
        return true;
    }
    if (is_first) {
        out.data_size = attribute.data_size;
        out.initialized_size = attribute.initialized_size;
        out.flags = attribute.flags;
    }
    return out.appendMapping(attribute.mapping_pairs);
}

fn collectAttribute(volume: *const Volume, record_number: u64, attr_type: ntfs.AttrType, name_utf16: []const u8, out: *AttrRuns) bool {
    var record_buf: [4096]u8 = undefined;
    const header = volume.loadRecord(record_number, record_buf[0..]) orelse return false;
    const record = record_buf[0..volume.record_size];

    if (ntfs.findAttribute(record, header, .attribute_list, &[_]u8{})) |list_attr| {
        if (list_attr.non_resident) return false;
        var found_any = false;
        var iterator = ntfs.AttributeListIterator.init(list_attr.value);
        while (iterator.next()) |entry| {
            if (entry.attr_type != @intFromEnum(attr_type)) continue;
            if (!std.mem.eql(u8, entry.name, name_utf16)) continue;
            var part_buf: [4096]u8 = undefined;
            const part_header = volume.loadRecord(entry.mft_reference.record, part_buf[0..]) orelse return false;
            const part_record = part_buf[0..volume.record_size];
            var part_iter = ntfs.AttributeIterator.init(part_record, part_header);
            while (part_iter.next()) |attribute| {
                if (attribute.attr_type != @intFromEnum(attr_type)) continue;
                if (!std.mem.eql(u8, attribute.name, name_utf16)) continue;
                if (attribute.non_resident and attribute.lowest_vcn != entry.lowest_vcn) continue;
                if (!captureAttribute(attribute, out, entry.lowest_vcn == 0)) return false;
                found_any = true;
            }
        }
        if (found_any) return true;
    }

    const attribute = ntfs.findAttribute(record, header, attr_type, name_utf16) orelse return false;
    return captureAttribute(attribute, out, true);
}

/// Verifies every $ATTRIBUTE_LIST entry of a base record: the referenced
/// record must exist, be in use, match the entry's sequence, contain an
/// attribute of the entry's {type, name, lowest_vcn} whose instance id equals
/// the entry's instance, and extension records must reference the base back.
fn verifyAttributeList(volume: *const Volume, base_number: u64, base_sequence: u16, list_value: []const u8) void {
    var iterator = ntfs.AttributeListIterator.init(list_value);
    while (iterator.next()) |entry| {
        const target = entry.mft_reference.record;
        var target_buf: [4096]u8 = undefined;
        const target_header = volume.loadRecord(target, target_buf[0..]) orelse {
            fail("record {d}: attribute list entry (type 0x{X}) references unreadable record {d}", .{ base_number, entry.attr_type, target });
            continue;
        };
        const target_record = target_buf[0..volume.record_size];
        if (!target_header.inUse()) {
            fail("record {d}: attribute list entry references free record {d}", .{ base_number, target });
            continue;
        }
        if (target_header.sequence != entry.mft_reference.sequence) {
            fail("record {d}: attribute list entry sequence {d} != record {d} sequence {d}", .{ base_number, entry.mft_reference.sequence, target, target_header.sequence });
        }
        if (target != base_number) {
            if (target_header.base_record.record != base_number or target_header.base_record.sequence != base_sequence) {
                fail("record {d}: extension record {d} does not reference the base back", .{ base_number, target });
            }
        }
        var found = false;
        var attrs = ntfs.AttributeIterator.init(target_record, target_header);
        while (attrs.next()) |attribute| {
            if (attribute.attr_type != entry.attr_type) continue;
            if (!std.mem.eql(u8, attribute.name, entry.name)) continue;
            if (attribute.non_resident and attribute.lowest_vcn != entry.lowest_vcn) continue;
            found = true;
            if (attribute.instance != entry.instance) {
                fail("record {d}: attribute list entry (type 0x{X}) instance {d} != attribute instance {d} in record {d}", .{ base_number, entry.attr_type, entry.instance, attribute.instance, target });
            }
            break;
        }
        if (!found) {
            fail("record {d}: attribute list entry (type 0x{X}, vcn {d}) has no matching attribute in record {d}", .{ base_number, entry.attr_type, entry.lowest_vcn, target });
        }
    }
}

fn readRunsInto(volume: *const Volume, attr: *const AttrRuns, out: []u8) ?usize {
    const total: usize = @intCast(attr.data_size);
    if (total > out.len) return null;
    if (attr.resident) {
        @memcpy(out[0..attr.resident_len], attr.resident_copy[0..attr.resident_len]);
        return attr.resident_len;
    }
    @memset(out[0..total], 0);
    const cluster = volume.clusterBytes();
    var position: usize = 0;
    var run_index: usize = 0;
    while (run_index < attr.count and position < total) : (run_index += 1) {
        const run = attr.runs[run_index];
        var run_bytes = @as(usize, @intCast(run.length_clusters)) * cluster;
        if (position + run_bytes > total) run_bytes = total - position;
        if (run.lcn) |lcn| {
            const src = volume.lcnOffset(lcn) orelse return null;
            if (src + run_bytes > volume.image.len) return null;
            var copy_bytes = run_bytes;
            if (position >= attr.initialized_size) {
                copy_bytes = 0;
            } else if (position + copy_bytes > attr.initialized_size) {
                copy_bytes = @intCast(attr.initialized_size - position);
            }
            @memcpy(out[position .. position + copy_bytes], volume.image[src .. src + copy_bytes]);
        }
        position += run_bytes;
    }
    return total;
}

// ---------------------------------------------------------------------------
// Tree walk
// ---------------------------------------------------------------------------

const WalkStats = struct {
    files: usize = 0,
    dirs: usize = 0,
    entries: usize = 0,
    visited: []u8 = &[_]u8{},
};

fn isDotName(name_utf16: []const u8) bool {
    return name_utf16.len == 2 and name_utf16[0] == '.' and name_utf16[1] == 0;
}

/// Per-directory traversal state: strict global in-order collation and the
/// set of index-block VCNs actually referenced by the tree (compared with
/// the $I30 $BITMAP afterwards, mirroring chkdsk).
const DirCtx = struct {
    last: [512]u8 = undefined,
    last_len: usize = 0,
    has_last: bool = false,
    vcn_used: []u8 = &[_]u8{},
};

fn walkDirectory(volume: *const Volume, allocator: std.mem.Allocator, record_number: u64, stats: *WalkStats, depth: usize) void {
    if (depth > 24) {
        fail("directory depth over 24 at record {d}", .{record_number});
        return;
    }
    var record_buf: [4096]u8 = undefined;
    const header = volume.loadRecord(record_number, record_buf[0..]) orelse {
        fail("directory record {d} unreadable", .{record_number});
        return;
    };
    const record = record_buf[0..volume.record_size];
    const root_attr = ntfs.findAttribute(record, header, .index_root, &ntfs.I30_NAME_UTF16) orelse {
        fail("directory record {d} without $I30 root", .{record_number});
        return;
    };
    const index_root = ntfs.IndexRoot.parse(root_attr.value) orelse {
        fail("INDEX_ROOT parse failed in record {d}", .{record_number});
        return;
    };
    if (index_root.collation_rule != ntfs.COLLATION_FILE_NAME) {
        fail("collation {d} != FILE_NAME in record {d}", .{ index_root.collation_rule, record_number });
        return;
    }

    var dirctx = DirCtx{};
    defer if (dirctx.vcn_used.len > 0) allocator.free(dirctx.vcn_used);

    var blocks: ?[]u8 = null;
    defer if (blocks) |b| allocator.free(b);
    var total_blocks: u64 = 0;
    if (index_root.header.hasSubNodes()) {
        var attr = AttrRuns{};
        if (!collectAttribute(volume, record_number, .index_allocation, &ntfs.I30_NAME_UTF16, &attr)) {
            fail("INDEX_ALLOCATION missing for record {d}", .{record_number});
            return;
        }
        const buffer = allocator.alloc(u8, @intCast(attr.data_size)) catch {
            fail("oom for INDEX_ALLOCATION of record {d}", .{record_number});
            return;
        };
        blocks = buffer;
        if (readRunsInto(volume, &attr, buffer) == null) {
            fail("INDEX_ALLOCATION read failed for record {d}", .{record_number});
            return;
        }
        total_blocks = attr.data_size / index_root.index_block_bytes;
        dirctx.vcn_used = allocator.alloc(u8, @intCast((total_blocks + 7) / 8)) catch return;
        @memset(dirctx.vcn_used, 0);
    }

    walkEntries(volume, allocator, index_root.entries, blocks, index_root.index_block_bytes, record_number, stats, depth, &dirctx);

    // $I30 bitmap must match the referenced VCNs exactly (chkdsk parity).
    if (index_root.header.hasSubNodes()) {
        var bmp = AttrRuns{};
        if (!collectAttribute(volume, record_number, .bitmap, &ntfs.I30_NAME_UTF16, &bmp)) {
            fail("$I30 bitmap missing for record {d}", .{record_number});
            return;
        }
        var bitmap_buf: [4096]u8 = undefined;
        var bitmap: []const u8 = undefined;
        if (bmp.resident) {
            bitmap = bmp.resident_copy[0..bmp.resident_len];
        } else {
            if (bmp.data_size > bitmap_buf.len) {
                fail("$I30 bitmap too large for record {d}", .{record_number});
                return;
            }
            if (readRunsInto(volume, &bmp, bitmap_buf[0..@intCast(bmp.data_size)]) == null) {
                fail("$I30 bitmap read failed for record {d}", .{record_number});
                return;
            }
            bitmap = bitmap_buf[0..@intCast(bmp.data_size)];
        }
        var vcn: u64 = 0;
        while (vcn < total_blocks) : (vcn += 1) {
            const byte: usize = @intCast(vcn / 8);
            const set = byte < bitmap.len and ((bitmap[byte] >> @intCast(vcn % 8)) & 1) != 0;
            const used = ((dirctx.vcn_used[@intCast(vcn / 8)] >> @intCast(vcn % 8)) & 1) != 0;
            if (set and !used) fail("$I30 bitmap: unreferenced block VCN {d} marked used in record {d}", .{ vcn, record_number });
            if (!set and used) fail("$I30 bitmap: referenced block VCN {d} marked free in record {d}", .{ vcn, record_number });
        }
    }
}

fn walkBlock(volume: *const Volume, allocator: std.mem.Allocator, blocks: ?[]u8, block_bytes: u32, vcn: u64, record_number: u64, stats: *WalkStats, depth: usize, dirctx: *DirCtx) void {
    const all = blocks orelse {
        fail("sub-node VCN {d} without allocation in record {d}", .{ vcn, record_number });
        return;
    };
    const cluster = volume.clusterBytes();
    if (cluster > block_bytes) {
        fail("cluster larger than index block in record {d}", .{record_number});
        return;
    }
    const start = @as(usize, @intCast(vcn)) * cluster;
    if (start + block_bytes > all.len) {
        fail("index VCN {d} outside allocation in record {d}", .{ vcn, record_number });
        return;
    }
    // The $I30 bitmap indexes BLOCKS while sub-node VCNs count clusters
    // (identical only when one cluster spans one index block).
    const block_index = vcn * cluster / block_bytes;
    const byte: usize = @intCast(block_index / 8);
    if (byte < dirctx.vcn_used.len) {
        const mask = @as(u8, 1) << @intCast(block_index % 8);
        if ((dirctx.vcn_used[byte] & mask) != 0) {
            fail("index block VCN {d} referenced twice in record {d}", .{ vcn, record_number });
            return;
        }
        dirctx.vcn_used[byte] |= mask;
    }
    const block = all[start .. start + block_bytes];
    if (ntfs.applyFixups(block) != .ok) {
        if (std.mem.readInt(u32, block[0..4], .little) != ntfs.INDX_MAGIC) {
            fail("index block fixup failed at VCN {d} record {d}", .{ vcn, record_number });
            return;
        }
    }
    const parsed = ntfs.IndexBlock.parse(block) orelse {
        fail("index block parse failed at VCN {d} record {d}", .{ vcn, record_number });
        return;
    };
    if (parsed.vcn != vcn) {
        fail("index block VCN self-mismatch {d}!={d} record {d}", .{ parsed.vcn, vcn, record_number });
        return;
    }
    // chkdsk parity: a referenced block must carry at least one real entry.
    {
        var probe = ntfs.IndexEntryIterator.init(parsed.entries);
        if (probe.next()) |first| {
            if (first.isEnd()) fail("empty index block VCN {d} referenced in record {d}", .{ vcn, record_number });
        }
    }
    walkEntries(volume, allocator, parsed.entries, blocks, block_bytes, record_number, stats, depth, dirctx);
}

fn walkEntries(volume: *const Volume, allocator: std.mem.Allocator, entries: []const u8, blocks: ?[]u8, block_bytes: u32, record_number: u64, stats: *WalkStats, depth: usize, dirctx: *DirCtx) void {
    var iterator = ntfs.IndexEntryIterator.init(entries);
    while (iterator.next()) |entry| {
        var name_copy: [512]u8 = undefined;
        var pending: ?ntfs.FileName = null;
        if (!entry.isEnd()) {
            const file_name = entry.fileName() orelse {
                fail("index entry without FILE_NAME in record {d}", .{record_number});
                return;
            };
            if (file_name.name.len <= name_copy.len) {
                @memcpy(name_copy[0..file_name.name.len], file_name.name);
                var copied = file_name;
                copied.name = name_copy[0..file_name.name.len];
                pending = copied;
            }
        }
        const is_end = entry.isEnd();
        const reference = ntfs.FileReference.parse(entry.file_reference);
        if (entry.hasSubNode()) {
            walkBlock(volume, allocator, blocks, block_bytes, entry.sub_node_vcn.?, record_number, stats, depth, dirctx);
        }
        if (is_end) return;
        const file_name = pending orelse continue;
        // Strict global in-order collation across the whole directory tree
        // (the subtree with smaller keys was visited first).
        if (dirctx.has_last) {
            if (ntfs.compareFileNames(volume.upcase, dirctx.last[0..dirctx.last_len], file_name.name) != .lt) {
                fail("global collation order violated in record {d}", .{record_number});
            }
        }
        if (file_name.name.len <= dirctx.last.len) {
            @memcpy(dirctx.last[0..file_name.name.len], file_name.name);
            dirctx.last_len = file_name.name.len;
            dirctx.has_last = true;
        }
        stats.entries += 1;
        if (file_name.namespace == ntfs.NAMESPACE_DOS) continue;
        if (isDotName(file_name.name)) continue;

        var target_buf: [4096]u8 = undefined;
        const target_header = volume.loadRecord(reference.record, target_buf[0..]) orelse {
            fail("entry references unreadable record {d} (dir {d})", .{ reference.record, record_number });
            continue;
        };
        if (target_header.sequence != reference.sequence) {
            fail("stale reference to record {d}: seq {d} != {d}", .{ reference.record, reference.sequence, target_header.sequence });
            continue;
        }
        const entry_is_dir = (file_name.flags & ntfs.FILE_ATTR_DIRECTORY_DUP) != 0;
        if (entry_is_dir != target_header.isDirectory()) {
            fail("directory flag mismatch for record {d}", .{reference.record});
            continue;
        }
        if (entry_is_dir) {
            stats.dirs += 1;
            if (reference.record < stats.visited.len) {
                if (stats.visited[@intCast(reference.record)] != 0) {
                    fail("directory record {d} reachable twice (cycle or cross-link)", .{reference.record});
                    continue;
                }
                stats.visited[@intCast(reference.record)] = 1;
            }
            walkDirectory(volume, allocator, reference.record, stats, depth + 1);
        } else {
            stats.files += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var image_path: ?[]const u8 = null;
    var bare_volume = false;
    var allow_dirty = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--volume")) {
            bare_volume = true;
        } else if (std.mem.eql(u8, arg, "--allow-dirty")) {
            allow_dirty = true;
        } else if (image_path == null) {
            image_path = arg;
        } else {
            std.debug.print("unexpected argument: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    const path = image_path orelse {
        std.debug.print("Usage: ntfsverify <image> [--volume] [--allow-dirty]\n", .{});
        std.process.exit(2);
    };

    const image = try cwd.readFileAlloc(io, path, allocator, .limited(MAX_IMAGE_BYTES));
    defer allocator.free(image);

    if (!bare_volume and image.len >= 1024 and std.mem.eql(u8, image[512..520], "EFI PART")) {
        const ReadOnly = struct {
            bytes: []const u8,
            fn read(raw: *anyopaque, lba: u64, out: []u8) i32 {
                const self: *@This() = @ptrCast(@alignCast(raw));
                @memcpy(out, self.bytes[@intCast(lba * 512)..][0..out.len]);
                return 0;
            }
            fn write(_: *anyopaque, _: u64, _: []const u8) i32 {
                return -1;
            }
            fn flush(_: *anyopaque) i32 {
                return -1;
            }
        };
        var source = ReadOnly{ .bytes = image };
        const device = tools.io.Device{ .context = &source, .sectors = image.len / 512, .read_fn = ReadOnly.read, .write_fn = ReadOnly.write, .flush_fn = ReadOnly.flush };
        var work: [tools.io.scratch_bytes]u8 = undefined;
        const table = try tools.partition.Plan.read(device, &work);
        if (table.kind != .gpt) return error.Gpt;
        var found: usize = 0;
        for (table.entries) |part| {
            if (!part.present) continue;
            const first: usize = @intCast(part.first * 512);
            const length: usize = @intCast(part.count * 512);
            if (length < 512 or first > image.len - length) return error.Geometry;
            if (!std.mem.eql(u8, image[first + 3 ..][0..8], "NTFS    ")) continue;
            found += 1;
            try verifyVolume(allocator, image[first..][0..length], 0, allow_dirty);
        }
        if (found != 2) return error.ExpectedSystemAndData;
        return;
    }

    var part_offset: usize = 0;
    if (!bare_volume) {
        if (image.len < 512) {
            std.debug.print("image too small\n", .{});
            std.process.exit(1);
        }
        // Pick the first NTFS-typed (0x07) MBR partition; fall back to the
        // first entry for single-partition NTFS disks written before the
        // system layout carried a FAT32 boot partition in slot 1.
        var part_lba = std.mem.readInt(u32, image[446 + 8 ..][0..4], .little);
        var slot: usize = 0;
        while (slot < 4) : (slot += 1) {
            const entry = image[446 + slot * 16 ..][0..16];
            if (entry[4] == 0x07) {
                part_lba = std.mem.readInt(u32, entry[8..12], .little);
                break;
            }
        }
        part_offset = @as(usize, part_lba) * 512;
    }

    if (part_offset > image.len or image.len - part_offset < 512) return error.Geometry;
    try verifyVolume(allocator, image, part_offset, allow_dirty);
}

fn verifyVolume(allocator: std.mem.Allocator, image: []const u8, part_offset: usize, allow_dirty: bool) !void {
    var boot: ntfs.BootSector = undefined;
    const boot_result = ntfs.BootSector.parse(image[part_offset..], &boot);
    if (boot_result != .ok) {
        std.debug.print("boot sector parse failed: {s}\n", .{@tagName(boot_result)});
        std.process.exit(1);
    }

    var volume = Volume{
        .image = image,
        .part_offset = part_offset,
        .boot = boot,
        .record_size = boot.file_record_bytes,
    };

    // Backup boot sector: identical copy in the sector after total_sectors.
    {
        const backup_offset = part_offset + @as(usize, @intCast(boot.total_sectors)) * 512;
        if (backup_offset + 512 > image.len) {
            fail("backup boot sector outside image (offset {d})", .{backup_offset});
        } else if (!std.mem.eql(u8, image[part_offset .. part_offset + 512], image[backup_offset .. backup_offset + 512])) {
            fail("backup boot sector differs from boot sector", .{});
        }
    }

    // MFT bootstrap.
    {
        const mft_offset = volume.lcnOffset(boot.mft_lcn) orelse {
            std.debug.print("MFT LCN outside image\n", .{});
            std.process.exit(1);
        };
        var record_buf: [4096]u8 = undefined;
        const record = record_buf[0..volume.record_size];
        @memcpy(record, image[mft_offset .. mft_offset + volume.record_size]);
        if (ntfs.applyFixups(record) != .ok) {
            std.debug.print("MFT record 0 fixups failed\n", .{});
            std.process.exit(1);
        }
        const header = ntfs.FileRecordHeader.parse(record) orelse {
            std.debug.print("MFT record 0 parse failed\n", .{});
            std.process.exit(1);
        };
        const data_attr = ntfs.findAttribute(record, header, .data, &[_]u8{}) orelse {
            std.debug.print("MFT record 0 without $DATA\n", .{});
            std.process.exit(1);
        };
        var iterator = ntfs.RunlistIterator.init(data_attr.mapping_pairs);
        while (iterator.next()) |run| {
            if (volume.mft_run_count >= volume.mft_runs.len) break;
            volume.mft_runs[volume.mft_run_count] = run;
            volume.mft_run_count += 1;
        }
        if (iterator.hadError() or volume.mft_run_count == 0) {
            std.debug.print("MFT runlist decode failed\n", .{});
            std.process.exit(1);
        }
        volume.mft_record_count = data_attr.data_size / volume.record_size;
    }

    // Upcase.
    {
        var attr = AttrRuns{};
        if (!collectAttribute(&volume, ntfs.MFT_RECORD_UPCASE, .data, &[_]u8{}, &attr) or attr.data_size != ntfs.UPCASE_BYTES) {
            fail("$UpCase missing or wrong size", .{});
        } else {
            const upcase = try allocator.alloc(u8, ntfs.UPCASE_BYTES);
            if (readRunsInto(&volume, &attr, upcase) == null) {
                fail("$UpCase read failed", .{});
                allocator.free(upcase);
            } else {
                volume.upcase = upcase;
            }
        }
    }
    defer if (volume.upcase.len > 0) allocator.free(@constCast(volume.upcase));

    // $MFTMirr must mirror the first MFT records byte-exactly (raw).
    {
        var attr = AttrRuns{};
        if (!collectAttribute(&volume, ntfs.MFT_RECORD_MFTMIRR, .data, &[_]u8{}, &attr)) {
            fail("$MFTMirr unreadable", .{});
        } else {
            const mirror_records: usize = @intCast(@min(attr.data_size / volume.record_size, 8));
            if (mirror_records < 4) fail("$MFTMirr smaller than four records", .{});
            const mirror = try allocator.alloc(u8, @intCast(attr.data_size));
            defer allocator.free(mirror);
            if (readRunsInto(&volume, &attr, mirror) == null) {
                fail("$MFTMirr read failed", .{});
            } else {
                var index: usize = 0;
                while (index < mirror_records) : (index += 1) {
                    const raw = volume.mftRecordRaw(index) orelse {
                        fail("MFT record {d} unreadable for mirror compare", .{index});
                        continue;
                    };
                    if (!std.mem.eql(u8, raw, mirror[index * volume.record_size .. (index + 1) * volume.record_size])) {
                        fail("$MFTMirr differs from MFT record {d}", .{index});
                    }
                }
            }
        }
    }

    // Cluster accounting over every in-use record.
    const total_clusters: usize = @intCast(boot.total_sectors * 512 / boot.cluster_bytes);
    const refmap = try allocator.alloc(u8, total_clusters);
    defer allocator.free(refmap);
    @memset(refmap, 0);
    const expected_inuse = try allocator.alloc(u8, @intCast(volume.mft_record_count));
    defer allocator.free(expected_inuse);
    @memset(expected_inuse, 0);

    var overlaps: usize = 0;
    var records_in_use: usize = 0;
    {
        var number: u64 = 0;
        while (number < volume.mft_record_count) : (number += 1) {
            const raw = volume.mftRecordRaw(number) orelse continue;
            const magic = std.mem.readInt(u32, raw[0..4], .little);
            if (magic == ntfs.BAAD_MAGIC) {
                fail("record {d} is BAAD", .{number});
                continue;
            }
            if (magic != ntfs.FILE_MAGIC) continue;
            var record_buf: [4096]u8 = undefined;
            const record = record_buf[0..volume.record_size];
            @memcpy(record, raw);
            if (ntfs.applyFixups(record) != .ok) {
                fail("record {d} fixups failed", .{number});
                continue;
            }
            const header = ntfs.FileRecordHeader.parse(record) orelse continue;
            if (!header.inUse()) continue;
            records_in_use += 1;
            expected_inuse[@intCast(number)] = 1;

            // $ATTRIBUTE_LIST cross-check (0.60.16): each entry must point at
            // a live record whose matching attribute carries the SAME instance
            // id; extension records must reference the base back.  chkdsk
            // enforces exactly this ({type, name, VCN, instance}) and flags
            // mismatches as corrupt attribute-list entries.
            if (header.base_record.record == 0) {
                if (ntfs.findAttribute(record, header, .attribute_list, &[_]u8{})) |list_attr| {
                    if (list_attr.non_resident) {
                        fail("record {d}: non-resident $ATTRIBUTE_LIST unsupported by verifier", .{number});
                    } else {
                        verifyAttributeList(&volume, number, header.sequence, list_attr.value);
                    }
                }
            }

            var iterator = ntfs.AttributeIterator.init(record, header);
            while (iterator.next()) |attribute| {
                if (!attribute.non_resident) continue;
                var runs = ntfs.RunlistIterator.init(attribute.mapping_pairs);
                while (runs.next()) |run| {
                    const lcn = run.lcn orelse continue;
                    var cluster_index: u64 = 0;
                    while (cluster_index < run.length_clusters) : (cluster_index += 1) {
                        const c = lcn + cluster_index;
                        if (c >= total_clusters) {
                            fail("record {d} references cluster {d} outside volume", .{ number, c });
                            break;
                        }
                        if (refmap[@intCast(c)] != 0) overlaps += 1;
                        refmap[@intCast(c)] +|= 1;
                    }
                }
                if (runs.hadError()) fail("record {d} runlist decode failed", .{number});
            }
        }
    }
    if (overlaps != 0) fail("{d} cluster(s) referenced more than once", .{overlaps});

    // Compare against $Bitmap.
    {
        var attr = AttrRuns{};
        if (!collectAttribute(&volume, ntfs.MFT_RECORD_BITMAP, .data, &[_]u8{}, &attr)) {
            fail("$Bitmap unreadable", .{});
        } else {
            const bitmap = try allocator.alloc(u8, @intCast(attr.data_size));
            defer allocator.free(bitmap);
            if (readRunsInto(&volume, &attr, bitmap) == null) {
                fail("$Bitmap read failed", .{});
            } else {
                var used_but_free: usize = 0;
                var set_but_unused: usize = 0;
                var c: usize = 0;
                while (c < total_clusters) : (c += 1) {
                    const bit = (bitmap[c / 8] >> @intCast(c % 8)) & 1;
                    const referenced = refmap[c] != 0;
                    if (referenced and bit == 0) used_but_free += 1;
                    if (!referenced and bit == 1) set_but_unused += 1;
                }
                if (used_but_free != 0) fail("{d} referenced cluster(s) marked free in $Bitmap", .{used_but_free});
                if (set_but_unused != 0) fail("{d} allocated cluster(s) without any referencing attribute", .{set_but_unused});
            }
        }
    }

    // Compare $MFT/$BITMAP against real in-use flags.
    {
        var attr = AttrRuns{};
        if (!collectAttribute(&volume, ntfs.MFT_RECORD_MFT, .bitmap, &[_]u8{}, &attr)) {
            fail("$MFT $BITMAP unreadable", .{});
        } else {
            const bitmap = try allocator.alloc(u8, @intCast(attr.data_size));
            defer allocator.free(bitmap);
            if (readRunsInto(&volume, &attr, bitmap) == null) {
                fail("$MFT $BITMAP read failed", .{});
            } else {
                var mismatches: usize = 0;
                var number: usize = 0;
                while (number < volume.mft_record_count) : (number += 1) {
                    if (number / 8 >= bitmap.len) break;
                    const bit = (bitmap[number / 8] >> @intCast(number % 8)) & 1;
                    if ((bit == 1) != (expected_inuse[number] == 1)) mismatches += 1;
                }
                if (mismatches != 0) fail("$MFT $BITMAP disagrees with {d} record header(s)", .{mismatches});
            }
        }
    }

    // $Volume version and dirty flag.
    {
        var record_buf: [4096]u8 = undefined;
        if (volume.loadRecord(ntfs.MFT_RECORD_VOLUME, record_buf[0..])) |header| {
            const record = record_buf[0..volume.record_size];
            if (ntfs.findAttribute(record, header, .volume_information, &[_]u8{})) |attr| {
                if (ntfs.VolumeInformation.parse(attr.value)) |info| {
                    if (info.major != 3 or info.minor != 1) fail("volume version {d}.{d} != 3.1", .{ info.major, info.minor });
                    if (!allow_dirty and (info.flags & ntfs.VOLUME_FLAG_DIRTY) != 0) fail("volume dirty flag is set", .{});
                } else fail("$VOLUME_INFORMATION parse failed", .{});
            } else fail("$VOLUME_INFORMATION missing", .{});
        } else fail("$Volume record unreadable", .{});
    }

    // Full tree walk.
    var stats = WalkStats{};
    stats.visited = try allocator.alloc(u8, @intCast(volume.mft_record_count));
    defer allocator.free(stats.visited);
    @memset(stats.visited, 0);
    stats.visited[@intCast(ntfs.MFT_RECORD_ROOT)] = 1;
    walkDirectory(&volume, allocator, ntfs.MFT_RECORD_ROOT, &stats, 0);

    if (failures != 0) {
        std.debug.print("NTFSVERIFY result: FAILED ({d} failure(s))\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print(
        "NTFSVERIFY result: OK records={d} files={d} dirs={d} entries={d} clusters={d} cluster_bytes={d}\n",
        .{ records_in_use, stats.files, stats.dirs, stats.entries, total_clusters, boot.cluster_bytes },
    );
}
