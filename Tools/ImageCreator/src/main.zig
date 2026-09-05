// R4OS ImageCreator
//
// Creates a bootable disk image with:
//   - MBR + one active FAT32-LBA partition
//   - FAT32 filesystem with MBR partitioning
//   - Arbitrary files at arbitrary paths (subdirectories, long names via LFN)
//
// Usage:
//   imagecreater --output disk.img [--size 64]
//                --add <source>:</target-path> [--add ...]
//                [--add-list add-list.txt]
//                [--volume-only] (FAT32 volume at sector zero, no MBR)
//
// Example:
//   imagecreater --output disk.img --size 64 \
//       --add limine.conf:/boot/limine.conf \
//       --add limine-bios.sys:/boot/limine-bios.sys \
//       --add r4os.elf:/boot/r4os.elf

const std = @import("std");
const ntfs_cli = @import("ntfs_cli.zig");
const ntfs_mkfs = @import("ntfs_mkfs.zig");

// --- Layout-Konstanten ----------------------------------------------------
const SECTOR: u32 = 512;
const SMALL_IMAGE_SPC: u32 = 1; // Keeps 64/128 MB FAT32 images above the FAT32 cluster-count threshold.
const LARGE_IMAGE_SPC: u32 = 8; // 4 KB clusters for normal system images and large transfer/update workloads.
const LARGE_CLUSTER_MIN_MB: u32 = 512;
const RESERVED_SECTORS: u32 = 32;
const NUM_FATS: u32 = 2;
const ROOT_ENTRIES: u32 = 0;
const ROOT_DIR_SECTORS: u32 = 0;
const PART_START_SECTOR: u32 = 2048;
const FAT32_EOC: u32 = 0x0FFF_FFFF;
const FAT32_LAST_DATA_CLUSTER: u32 = 0x0FFF_FFF6;
const ROOT_CLUSTER: u32 = 2;

// --- Input-Struct -------------------------------------------------------
const AddEntry = struct { src: []const u8, dest: []const u8 };

fn appendAddList(a: std.mem.Allocator, data: []const u8, entries: *std.ArrayList(AddEntry)) !void {
    var rest = data;
    while (rest.len > 0) {
        const split = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const raw_line = rest[0..split];
        rest = if (split < rest.len) rest[split + 1 ..] else rest[split..];

        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sep = std.mem.indexOfScalar(u8, line, '|') orelse
            (std.mem.lastIndexOfScalar(u8, line, ':') orelse return error.BadAddListLine);
        const src = std.mem.trim(u8, line[0..sep], " \t\r");
        const dest = std.mem.trim(u8, line[sep + 1 ..], " \t\r");
        if (src.len == 0 or dest.len == 0) return error.BadAddListLine;
        try entries.append(a, .{ .src = src, .dest = dest });
    }
}

// --- Filesystem tree, flat with parent indices -----------------------------
const NodeKind = enum { dir, file };

const Node = struct {
    kind: NodeKind,
    name: []const u8, // last path segment, original case/special characters
    parent: u32, // index, 0 = root
    data: []const u8 = &[_]u8{}, // file contents
    children: std.ArrayList(u32) = .empty, // child indices for directories
    first_cluster: u32 = 0, // first cluster of the file/directory
    cluster_count: u32 = 0,
};

// --- Helpers: small endian writers ----------------------------------------
fn wU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}
fn wU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

// --- 8.3 name generation ---------------------------------------------------
// Returns true when the name is already a perfect 8.3 name and needs no LFN.
fn buildShortName(orig: []const u8, out: *[11]u8) bool {
    @memset(out, ' ');
    var dot_pos: ?usize = null;
    var i: usize = orig.len;
    while (i > 0) : (i -= 1) {
        if (orig[i - 1] == '.') {
            dot_pos = i - 1;
            break;
        }
    }
    const base = if (dot_pos) |p| orig[0..p] else orig;
    const ext = if (dot_pos) |p| orig[p + 1 ..] else "";

    var perfect = true;
    if (base.len > 8 or ext.len > 3 or base.len == 0) perfect = false;
    if (dot_pos != null and (dot_pos.? == 0)) perfect = false;

    // Allowed chars in 8.3: A-Z 0-9 ! # $ % & ' ( ) - @ ^ _ ` { } ~
    const allowed = "!#$%&'()-@^_`{}~";
    var bcount: usize = 0;
    for (base) |c| {
        if (bcount >= 6 and !perfect) break; // tilde suffix leaves six base characters
        if (bcount >= 8) {
            perfect = false;
            break;
        }
        var oc: u8 = c;
        if (oc >= 'a' and oc <= 'z') oc -= 32;
        const is_alnum = (oc >= 'A' and oc <= 'Z') or (oc >= '0' and oc <= '9');
        var ok = is_alnum;
        if (!ok) for (allowed) |a| {
            if (oc == a) {
                ok = true;
                break;
            }
        };
        if (!ok) {
            oc = '_';
            perfect = false;
        }
        out[bcount] = oc;
        bcount += 1;
    }

    var ecount: usize = 0;
    for (ext) |c| {
        if (ecount >= 3) {
            perfect = false;
            break;
        }
        var oc: u8 = c;
        if (oc >= 'a' and oc <= 'z') oc -= 32;
        const is_alnum = (oc >= 'A' and oc <= 'Z') or (oc >= '0' and oc <= '9');
        var ok = is_alnum;
        if (!ok) for (allowed) |a| {
            if (oc == a) {
                ok = true;
                break;
            }
        };
        if (!ok) {
            oc = '_';
            perfect = false;
        }
        out[8 + ecount] = oc;
        ecount += 1;
    }

    if (!perfect) {
        // First tilde suffix. Collisions are resolved later as ~2, ~3, ...
        // Keep shorter base names unchanged.
        const tilde_pos: usize = if (bcount > 6) 6 else bcount;
        out[tilde_pos] = '~';
        out[tilde_pos + 1] = '1';
    }
    return perfect;
}

fn applyTildeSuffix(short: *[11]u8, suffix: u32) !void {
    if (suffix == 0 or suffix > 999_999) return error.TooManyShortNameCollisions;

    var digits: [6]u8 = undefined;
    var n = suffix;
    var digit_count: usize = 0;
    while (n > 0) : (n /= 10) {
        digits[digits.len - 1 - digit_count] = @intCast('0' + (n % 10));
        digit_count += 1;
    }

    const tilde_pos = 8 - digit_count - 1;
    @memset(short[tilde_pos..8], ' ');
    short[tilde_pos] = '~';
    @memcpy(short[tilde_pos + 1 .. 8], digits[digits.len - digit_count ..]);
}

fn shortNameUsed(used: []const [11]u8, short: [11]u8) bool {
    for (used) |existing| {
        if (std.mem.eql(u8, &existing, &short)) return true;
    }
    return false;
}

fn lfnChecksum(short: [11]u8) u8 {
    var sum: u8 = 0;
    for (short) |c| {
        const lo: u8 = if ((sum & 1) != 0) 0x80 else 0;
        sum = lo +% (sum >> 1) +% c;
    }
    return sum;
}

// --- Image-Builder --------------------------------------------------------
const Image = struct {
    allocator: std.mem.Allocator,
    image: []u8,
    total_sectors: u32,
    part_start_sector: u32,
    part_sectors: u32,
    sectors_per_fat: u32,
    sectors_per_cluster: u32,
    data_start_sector: u32, // relativ zum Partitionsstart
    nodes: std.ArrayList(Node),
    next_free_cluster: u32 = ROOT_CLUSTER + 1,

    fn partOffset(self: *const Image, sector_in_part: u32) usize {
        return @as(usize, self.part_start_sector + sector_in_part) * SECTOR;
    }

    fn clusterOffset(self: *Image, cluster: u32) usize {
        const sec = self.data_start_sector + (cluster - 2) * self.sectors_per_cluster;
        return self.partOffset(sec);
    }

    fn clusterSize(self: *const Image) u32 {
        return SECTOR * self.sectors_per_cluster;
    }

    fn dataClusterCount(self: *const Image) u32 {
        if (self.part_sectors <= self.data_start_sector) return 0;
        return (self.part_sectors - self.data_start_sector) / self.sectors_per_cluster;
    }

    fn fatEntry(self: *const Image, cluster: u32) u32 {
        const fat0_off = self.partOffset(RESERVED_SECTORS);
        return std.mem.readInt(u32, self.image[fat0_off + @as(usize, cluster) * 4 ..][0..4], .little) & 0x0FFF_FFFF;
    }

    fn updateFsInfoFromFat(self: *Image) void {
        const total_clusters = self.dataClusterCount();
        var free_count: u32 = 0;
        var next_free: u32 = 0xFFFF_FFFF;
        var cluster: u32 = 2;
        const end = total_clusters + 2;
        while (cluster < end) : (cluster += 1) {
            if (self.fatEntry(cluster) == 0) {
                free_count += 1;
                if (next_free == 0xFFFF_FFFF) next_free = cluster;
            }
        }
        buildFsInfo(self.image[self.partOffset(1)..][0..SECTOR], free_count, next_free);
        @memcpy(
            self.image[self.partOffset(7)..][0..SECTOR],
            self.image[self.partOffset(1)..][0..SECTOR],
        );
    }

    // Write cluster chains to both FATs (list of clusters).
    fn writeChain(self: *Image, clusters: []const u32) void {
        const fat0_off = self.partOffset(RESERVED_SECTORS);
        const fat1_off = self.partOffset(RESERVED_SECTORS + self.sectors_per_fat);
        for (clusters, 0..) |c, i| {
            const next: u32 = if (i + 1 < clusters.len) clusters[i + 1] else FAT32_EOC;
            wU32(self.image, fat0_off + @as(usize, c) * 4, next);
            wU32(self.image, fat1_off + @as(usize, c) * 4, next);
        }
    }

    fn allocClusters(self: *Image, count: u32) !std.ArrayList(u32) {
        try self.ensureClustersAvailable(count);
        var list: std.ArrayList(u32) = .empty;
        try list.ensureTotalCapacity(self.allocator, count);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const c = self.next_free_cluster;
            self.next_free_cluster += 1;
            try list.append(self.allocator, c);
        }
        return list;
    }

    fn ensureClustersAvailable(self: *const Image, count: u32) !void {
        if (count == 0) return;
        if (self.next_free_cluster + count - 1 > FAT32_LAST_DATA_CLUSTER) {
            return error.ImageTooLargeForFat32;
        }
        if (@as(u64, self.next_free_cluster) + count > @as(u64, self.dataClusterCount()) + 2) {
            return error.ImageFull;
        }
    }

    // Insert a path like "/boot/limine.conf" into the tree and attach file data.
    fn insertFile(self: *Image, dest: []const u8, data: []const u8) !void {
        var iter = std.mem.tokenizeScalar(u8, dest, '/');
        var current: u32 = 0; // root
        var last_seg: ?[]const u8 = null;
        while (iter.next()) |seg| {
            if (last_seg) |ls| {
                // Create or find the previous segment as a subdirectory.
                current = try self.findOrCreateDir(current, ls);
            }
            last_seg = seg;
        }
        const filename = last_seg orelse return error.EmptyDest;
        // File node.
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .kind = .file,
            .name = try self.allocator.dupe(u8, filename),
            .parent = current,
            .data = data,
        });
        try self.nodes.items[current].children.append(self.allocator, idx);
    }

    fn findOrCreateDir(self: *Image, parent: u32, name: []const u8) !u32 {
        for (self.nodes.items[parent].children.items) |ci| {
            const child = &self.nodes.items[ci];
            if (child.kind == .dir and std.mem.eql(u8, child.name, name)) return ci;
        }
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .kind = .dir,
            .name = try self.allocator.dupe(u8, name),
            .parent = parent,
        });
        try self.nodes.items[parent].children.append(self.allocator, idx);
        return idx;
    }

    // Recursively compute cluster demand and assign first_cluster/cluster_count.
    fn allocateLayout(self: *Image, node_idx: u32) !void {
        const n = &self.nodes.items[node_idx];
        switch (n.kind) {
            .file => {
                if (n.data.len == 0) {
                    n.first_cluster = 0;
                    n.cluster_count = 0;
                } else {
                    const cluster_size = self.clusterSize();
                    const cnt = (@as(u32, @intCast(n.data.len)) + cluster_size - 1) / cluster_size;
                    try self.ensureClustersAvailable(cnt);
                    n.cluster_count = cnt;
                    n.first_cluster = self.next_free_cluster;
                    self.next_free_cluster += @intCast(cnt);
                }
            },
            .dir => {
                // Reserve the whole root chain before any children; otherwise
                // a root larger than one cluster overlaps the first file.
                if (node_idx == 0) {
                    var total_entries: u32 = 1; // volume label
                    for (n.children.items) |ci| total_entries += entriesForName(self.nodes.items[ci].name);
                    n.cluster_count = @max(1, (total_entries * 32 + self.clusterSize() - 1) / self.clusterSize());
                    self.next_free_cluster = ROOT_CLUSTER;
                    try self.ensureClustersAvailable(n.cluster_count);
                    n.first_cluster = ROOT_CLUSTER;
                    self.next_free_cluster += n.cluster_count;
                    for (n.children.items) |ci| try self.allocateLayout(ci);
                    return;
                }
                // Allocate children first so their cluster numbers are final
                // before directory entries are written.
                for (n.children.items) |ci| try self.allocateLayout(ci);
                // Entries per child: one short entry plus optional LFN entries.
                var total_entries: u32 = if (node_idx == 0) 0 else 2; // "." and ".."
                for (n.children.items) |ci| {
                    total_entries += entriesForName(self.nodes.items[ci].name);
                }
                const bytes = total_entries * 32;
                const cluster_size = self.clusterSize();
                const cnt = (bytes + cluster_size - 1) / cluster_size;
                n.cluster_count = if (cnt == 0) 1 else cnt;
                try self.ensureClustersAvailable(n.cluster_count);
                n.first_cluster = if (node_idx == 0) ROOT_CLUSTER else self.next_free_cluster;
                self.next_free_cluster += @intCast(n.cluster_count);
            },
        }
    }

    fn writeAll(self: *Image) !void {
        // FAT reserved entries.
        const fat0_off = self.partOffset(RESERVED_SECTORS);
        const fat1_off = self.partOffset(RESERVED_SECTORS + self.sectors_per_fat);
        wU32(self.image, fat0_off + 0, 0x0FFFF_FF8);
        wU32(self.image, fat0_off + 4, FAT32_EOC);
        wU32(self.image, fat1_off + 0, 0x0FFFF_FF8);
        wU32(self.image, fat1_off + 4, FAT32_EOC);

        // Write files and directories recursively.
        try self.writeNode(0);
    }

    fn writeNode(self: *Image, node_idx: u32) !void {
        const n = &self.nodes.items[node_idx];
        switch (n.kind) {
            .file => {
                if (n.cluster_count == 0) return;
                // Build cluster list.
                var clusters: std.ArrayList(u32) = .empty;
                defer clusters.deinit(self.allocator);
                var i: u32 = 0;
                while (i < n.cluster_count) : (i += 1) {
                    try clusters.append(self.allocator, n.first_cluster + i);
                }
                self.writeChain(clusters.items);
                // Write data.
                const dst = self.clusterOffset(n.first_cluster);
                @memcpy(self.image[dst .. dst + n.data.len], n.data);
            },
            .dir => {
                // Build directory entry buffer.
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);
                var used_short_names: std.ArrayList([11]u8) = .empty;
                defer used_short_names.deinit(self.allocator);

                if (node_idx != 0) {
                    // "." Eintrag
                    try writeShortDir(&buf, self.allocator, ".          ".*, true, n.first_cluster, 0);
                    // ".." Eintrag (parent-cluster, root = 0)
                    const parent_cluster: u32 = if (n.parent == 0) 0 else self.nodes.items[n.parent].first_cluster;
                    try writeShortDir(&buf, self.allocator, "..         ".*, true, parent_cluster, 0);
                } else {
                    var label: [32]u8 = .{0} ** 32;
                    @memcpy(label[0..11], "R4OS BOOT  ");
                    label[11] = 0x08;
                    try buf.appendSlice(self.allocator, &label);
                }

                for (n.children.items) |ci| {
                    const c = &self.nodes.items[ci];
                    var short: [11]u8 = undefined;
                    const perfect = buildShortName(c.name, &short);
                    if (perfect and shortNameUsed(used_short_names.items, short)) return error.DuplicateShortName;

                    if (!perfect) {
                        var suffix: u32 = 1;
                        while (shortNameUsed(used_short_names.items, short)) : (suffix += 1) {
                            short = undefined;
                            _ = buildShortName(c.name, &short);
                            try applyTildeSuffix(&short, suffix + 1);
                        }
                    }

                    try used_short_names.append(self.allocator, short);
                    try writeDirEntryWithShort(&buf, self.allocator, c, short, perfect);
                }

                var clusters: std.ArrayList(u32) = .empty;
                defer clusters.deinit(self.allocator);
                var i: u32 = 0;
                while (i < n.cluster_count) : (i += 1) {
                    try clusters.append(self.allocator, n.first_cluster + i);
                }
                self.writeChain(clusters.items);
                const off = self.clusterOffset(n.first_cluster);
                @memcpy(self.image[off .. off + buf.items.len], buf.items);

                for (n.children.items) |ci| try self.writeNode(ci);
            },
        }
    }
};

fn entriesForName(name: []const u8) u32 {
    var short: [11]u8 = undefined;
    const perfect = buildShortName(name, &short);
    if (perfect) return 1;
    // LFN entry count: ceil(len/13).
    const lfn_count: u32 = (@as(u32, @intCast(name.len)) + 12) / 13;
    return lfn_count + 1;
}

fn writeShortDir(
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,
    short: [11]u8,
    is_dir: bool,
    first_cluster: u32,
    size: u32,
) !void {
    var e: [32]u8 = .{0} ** 32;
    @memcpy(e[0..11], &short);
    e[11] = if (is_dir) 0x10 else 0x20;
    wU16(&e, 20, @truncate(first_cluster >> 16));
    wU16(&e, 26, @truncate(first_cluster));
    wU32(&e, 28, size);
    try buf.appendSlice(a, &e);
}

fn writeDirEntryWithShort(
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,
    n: *const Node,
    short: [11]u8,
    perfect: bool,
) !void {
    if (!perfect) {
        const checksum = lfnChecksum(short);
        const lfn_count: u32 = (@as(u32, @intCast(n.name.len)) + 12) / 13;
        // Reverse order: highest sequence value with 0x40 first, then descending.
        var seq: u32 = lfn_count;
        while (seq >= 1) : (seq -= 1) {
            var e: [32]u8 = .{0} ** 32;
            const seq_byte: u8 = @intCast(seq);
            e[0] = if (seq == lfn_count) seq_byte | 0x40 else seq_byte;
            e[11] = 0x0F;
            e[12] = 0;
            e[13] = checksum;
            // LFN cluster field is always 0.
            // Fill 13 characters from the name as UCS-2 LE; pad the rest with
            // 0xFFFF after the 0x0000 terminator.
            const start: usize = (seq - 1) * 13;
            const slot_indices = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
            var ended = false;
            var k: usize = 0;
            while (k < 13) : (k += 1) {
                const off = slot_indices[k];
                if (start + k < n.name.len) {
                    e[off] = n.name[start + k];
                    e[off + 1] = 0;
                } else if (!ended) {
                    e[off] = 0;
                    e[off + 1] = 0;
                    ended = true;
                } else {
                    e[off] = 0xFF;
                    e[off + 1] = 0xFF;
                }
            }
            try buf.appendSlice(a, &e);
            if (seq == 1) break;
        }
    }

    const size: u32 = if (n.kind == .file) @intCast(n.data.len) else 0;
    try writeShortDir(buf, a, short, n.kind == .dir, n.first_cluster, size);
}

// --- Initialisierung ------------------------------------------------------
fn buildBpb(buf: []u8, first_sector: u32, total_sectors_part: u32, sectors_per_fat: u32, sectors_per_cluster: u32) void {
    @memset(buf[0..512], 0);
    // Jump
    buf[0] = 0xEB;
    buf[1] = 0x58;
    buf[2] = 0x90;
    // OEM
    @memcpy(buf[3..11], "R4OS    ");
    wU16(buf, 11, @intCast(SECTOR));
    buf[13] = @intCast(sectors_per_cluster);
    wU16(buf, 14, @intCast(RESERVED_SECTORS));
    buf[16] = @intCast(NUM_FATS);
    wU16(buf, 17, @intCast(ROOT_ENTRIES));
    wU16(buf, 19, 0); // total sectors 16: 0 -> use 32-bit field
    buf[21] = 0xF8;
    wU16(buf, 22, 0);
    wU16(buf, 24, 32);
    wU16(buf, 26, 64);
    wU32(buf, 28, first_sector); // hidden sectors; zero for a standalone volume
    wU32(buf, 32, total_sectors_part);
    wU32(buf, 36, sectors_per_fat);
    wU16(buf, 40, 0);
    wU16(buf, 42, 0);
    wU32(buf, 44, ROOT_CLUSTER);
    wU16(buf, 48, 1);
    wU16(buf, 50, 6);
    buf[64] = 0x80;
    buf[65] = 0;
    buf[66] = 0x29;
    wU32(buf, 67, 0xCAFEBABE);
    @memcpy(buf[71..82], "R4OS BOOT  ");
    @memcpy(buf[82..90], "FAT32   ");
    // Boot sig
    buf[510] = 0x55;
    buf[511] = 0xAA;
}

fn buildFsInfo(buf: []u8, free_count: u32, next_free: u32) void {
    @memset(buf[0..512], 0);
    wU32(buf, 0, 0x41615252);
    wU32(buf, 484, 0x61417272);
    wU32(buf, 488, free_count);
    wU32(buf, 492, next_free);
    wU32(buf, 508, 0xAA55_0000);
}

fn sectorsPerClusterForSize(size_mb: u32) u32 {
    return if (size_mb >= LARGE_CLUSTER_MIN_MB) LARGE_IMAGE_SPC else SMALL_IMAGE_SPC;
}

fn buildMbr(buf: []u8, total_sectors: u32, part_sectors: u32) void {
    @memset(buf[0..446], 0);
    @memset(buf[446..510], 0);
    // Partition entry 1
    const pe = buf[446..462];
    pe[0] = 0x80; // active
    // CHS fields with "invalid" / LBA fallback.
    pe[1] = 0xFE;
    pe[2] = 0xFF;
    pe[3] = 0xFF;
    pe[4] = 0x0C; // FAT32 LBA
    pe[5] = 0xFE;
    pe[6] = 0xFF;
    pe[7] = 0xFF;
    wU32(buf, 446 + 8, PART_START_SECTOR);
    wU32(buf, 446 + 12, part_sectors);
    _ = total_sectors;
    buf[510] = 0x55;
    buf[511] = 0xAA;
}

// --- main -----------------------------------------------------------------
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const cwd = std.Io.Dir.cwd();
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len >= 2 and std.mem.eql(u8, args[1], "format-ntfs")) {
        return ntfs_cli.run(a, io, cwd, args[2..]);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "create-system")) {
        return runCreateSystem(a, io, cwd, args[2..]);
    }

    var output_path: ?[]const u8 = null;
    var size_mb: u32 = 64;
    var volume_only = false;
    var entries: std.ArrayList(AddEntry) = .empty;
    defer entries.deinit(a);
    var list_buffers: std.ArrayList([]u8) = .empty;
    defer {
        for (list_buffers.items) |buffer| a.free(buffer);
        list_buffers.deinit(a);
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--volume-only")) {
            volume_only = true;
        } else if (std.mem.eql(u8, arg, "--size")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            size_mb = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--add")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            // The last ':' separates source from destination so Windows drive letters (D:\...) remain valid in source paths.
            const colon = std.mem.lastIndexOfScalar(u8, args[i], ':') orelse return error.BadAddArg;
            if (colon == 0 or colon + 1 >= args[i].len) return error.BadAddArg;
            try entries.append(a, .{ .src = args[i][0..colon], .dest = args[i][colon + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--add-list")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            const data = try cwd.readFileAlloc(io, args[i], a, .unlimited);
            errdefer a.free(data);
            try list_buffers.append(a, data);
            try appendAddList(a, data, &entries);
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return error.BadArgs;
        }
    }

    const out = output_path orelse {
        std.debug.print("--output missing\n", .{});
        return error.BadArgs;
    };

    const total_bytes: u64 = @as(u64, size_mb) * 1024 * 1024;
    const total_sectors_u64 = total_bytes / SECTOR;
    if (total_sectors_u64 > std.math.maxInt(u32)) return error.SizeTooLarge;
    const total_sectors: u32 = @intCast(total_sectors_u64);
    const first_sector: u32 = if (volume_only) 0 else PART_START_SECTOR;
    if (total_sectors <= first_sector) return error.SizeTooSmall;
    const part_sectors: u32 = total_sectors - first_sector;

    const image_bytes: usize = @as(usize, total_sectors) * SECTOR;
    const image = try a.alloc(u8, image_bytes);
    defer a.free(image);
    @memset(image, 0);

    // MBR
    if (!volume_only) buildMbr(image[0..SECTOR], total_sectors, part_sectors);
    const stats = try buildFat32PartitionInto(a, io, cwd, image, first_sector, total_sectors, part_sectors, size_mb, entries.items);

    // Output.
    try cwd.writeFile(io, .{ .sub_path = out, .data = image });

    std.debug.print(
        "FAT32 image created: {s} ({d} MB)\n  Partition: sector {d}, {d} sectors\n  FAT size: {d} sectors per FAT\n  Cluster: {d} bytes\n",
        .{ out, size_mb, first_sector, part_sectors, stats.sectors_per_fat, SECTOR * stats.sectors_per_cluster },
    );
}

const FatBuildStats = struct { sectors_per_fat: u32, sectors_per_cluster: u32 };

/// Builds the FAT32 partition content (BPB, FATs, tree) into `image` at the
/// selected partition offset. Shared by standalone volumes, the classic
/// single-partition image and the boot partition of the system layout.
fn buildFat32PartitionInto(a: std.mem.Allocator, io: anytype, cwd: std.Io.Dir, image: []u8, first_sector: u32, total_sectors: u32, part_sectors: u32, size_mb: u32, entries: []const AddEntry) !FatBuildStats {
    const sectors_per_cluster = sectorsPerClusterForSize(size_mb);

    // Compute FAT size pessimistically, then iterate until stable.
    var sectors_per_fat: u32 = 1;
    while (true) {
        const meta = RESERVED_SECTORS + NUM_FATS * sectors_per_fat + ROOT_DIR_SECTORS;
        if (meta >= part_sectors) return error.SizeTooSmall;
        const data_sectors = part_sectors - meta;
        const cluster_count = data_sectors / sectors_per_cluster + 2; // +2 reserved
        const needed = (cluster_count * 4 + SECTOR - 1) / SECTOR;
        if (needed <= sectors_per_fat) break;
        sectors_per_fat = needed;
    }

    const data_start_sector = RESERVED_SECTORS + NUM_FATS * sectors_per_fat + ROOT_DIR_SECTORS;

    // BPB
    buildBpb(image[first_sector * SECTOR ..][0..SECTOR], first_sector, part_sectors, sectors_per_fat, sectors_per_cluster);
    buildFsInfo(image[(first_sector + 1) * SECTOR ..][0..SECTOR], 0xFFFF_FFFF, 0xFFFF_FFFF);
    @memcpy(
        image[(first_sector + 6) * SECTOR ..][0..SECTOR],
        image[first_sector * SECTOR ..][0..SECTOR],
    );
    @memcpy(
        image[(first_sector + 7) * SECTOR ..][0..SECTOR],
        image[(first_sector + 1) * SECTOR ..][0..SECTOR],
    );

    // Create image builder.
    var img: Image = .{
        .allocator = a,
        .image = image,
        .total_sectors = total_sectors,
        .part_start_sector = first_sector,
        .part_sectors = part_sectors,
        .sectors_per_fat = sectors_per_fat,
        .sectors_per_cluster = sectors_per_cluster,
        .data_start_sector = data_start_sector,
        .nodes = .empty,
    };
    defer {
        for (img.nodes.items) |*n| {
            if (n.name.len > 0) a.free(n.name);
            if (n.kind == .file and n.data.len > 0) a.free(n.data);
            n.children.deinit(a);
        }
        img.nodes.deinit(a);
    }

    // Root node.
    try img.nodes.append(a, .{
        .kind = .dir,
        .name = "",
        .parent = 0,
    });

    // Read files.
    for (entries) |e| {
        const data = cwd.readFileAlloc(io, e.src, a, .unlimited) catch |err| {
            std.debug.print("Cannot read '{s}': {s}\n", .{ e.src, @errorName(err) });
            return err;
        };
        try img.insertFile(e.dest, data);
    }

    // Compute and write layout.
    try img.allocateLayout(0);
    try img.writeAll();
    img.updateFsInfoFromFat();

    return .{ .sectors_per_fat = sectors_per_fat, .sectors_per_cluster = sectors_per_cluster };
}

// --- create-system: FAT32 boot partition + NTFS system volume ---------------

/// Splits at the /boot and /EFI prefixes: boot files AND the UEFI
/// removable-media path (/EFI/BOOT/BOOTX64.EFI) live on the FAT32 boot
/// partition -- UEFI firmware only reads FAT, so an /EFI tree on the NTFS
/// system volume would silently not boot (real Lenovo finding, 0.60.11).
/// Everything else goes to the NTFS system volume.
fn isBootDest(dest: []const u8) bool {
    return hasTopDir(dest, "boot") or hasTopDir(dest, "efi");
}

fn hasTopDir(dest: []const u8, comptime name: []const u8) bool {
    var path = dest;
    if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) path = path[1..];
    if (path.len < name.len) return false;
    for (name, 0..) |expected, i| {
        const ch = path[i];
        const folded = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        if (folded != expected) return false;
    }
    return path.len == name.len or path[name.len] == '/' or path[name.len] == '\\';
}

fn runCreateSystem(gpa: std.mem.Allocator, io: anytype, cwd: std.Io.Dir, args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var output_path: ?[]const u8 = null;
    var meta_dir_path: ?[]const u8 = null;
    var boot_mb: u32 = 128;
    var system_mb: u32 = 512;
    var label: []const u8 = "R4OS";
    var serial: u64 = 0x5234_4F53_5359_5354;
    var entries: std.ArrayList(AddEntry) = .empty;
    defer entries.deinit(a);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--meta")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            meta_dir_path = args[i];
        } else if (std.mem.eql(u8, arg, "--boot-mb")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            boot_mb = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--system-mb")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            system_mb = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--label")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            label = args[i];
        } else if (std.mem.eql(u8, arg, "--serial")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            serial = try std.fmt.parseInt(u64, args[i], 16);
        } else if (std.mem.eql(u8, arg, "--add")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            const colon = std.mem.lastIndexOfScalar(u8, args[i], ':') orelse return error.BadAddArg;
            if (colon == 0 or colon + 1 >= args[i].len) return error.BadAddArg;
            try entries.append(a, .{ .src = args[i][0..colon], .dest = args[i][colon + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--add-list")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            const data = try cwd.readFileAlloc(io, args[i], a, .unlimited);
            try appendAddList(a, data, &entries);
        } else {
            std.debug.print("create-system: unknown argument {s}\n", .{arg});
            return error.BadArgs;
        }
    }

    const out = output_path orelse return error.BadArgs;
    const meta_path = meta_dir_path orelse return error.BadArgs;
    if (boot_mb < 16 or system_mb < 16) return error.SizeTooSmall;

    var boot_entries: std.ArrayList(AddEntry) = .empty;
    defer boot_entries.deinit(a);
    var system_entries: std.ArrayList(AddEntry) = .empty;
    defer system_entries.deinit(a);
    for (entries.items) |e| {
        if (isBootDest(e.dest)) {
            try boot_entries.append(a, e);
        } else {
            try system_entries.append(a, e);
        }
    }

    const boot_part_sectors: u32 = boot_mb * (1024 * 1024 / SECTOR);
    const system_bytes: u64 = @as(u64, system_mb) * 1024 * 1024;
    const system_sectors: u32 = @intCast(system_bytes / SECTOR);
    const ntfs_lba: u32 = PART_START_SECTOR + boot_part_sectors;
    const total_sectors: u32 = ntfs_lba + system_sectors;

    const image = try a.alloc(u8, @as(usize, total_sectors) * SECTOR);
    @memset(image, 0);

    // FAT32 boot partition at the classic offset.
    _ = try buildFat32PartitionInto(a, io, cwd, image, PART_START_SECTOR, total_sectors, boot_part_sectors, boot_mb, boot_entries.items);

    // NTFS system volume behind it.
    var meta_dir = try cwd.openDir(io, meta_path, .{});
    defer meta_dir.close(io);
    const meta = try ntfs_cli.loadMeta(a, io, meta_dir);
    const timestamp: u64 = 132_000_000_000_000_000;
    var builder = try ntfs_mkfs.Builder.init(a, system_bytes, label, ntfs_lba, meta, timestamp, serial);
    for (system_entries.items) |e| {
        const data = cwd.readFileAlloc(io, e.src, a, .unlimited) catch |err| {
            std.debug.print("Cannot read '{s}': {s}\n", .{ e.src, @errorName(err) });
            return err;
        };
        try ntfs_cli.addPath(&builder, a, e.dest, data);
    }
    const volume = try builder.finalize();
    if (volume.len != system_bytes) return error.NtfsSizeMismatch;
    @memcpy(image[@as(usize, ntfs_lba) * SECTOR ..][0..volume.len], volume);

    // MBR with both partitions.
    const mbr = image[0..SECTOR];
    @memset(mbr[0..510], 0);
    wU32(mbr, 0x1B8, @truncate(serial));
    const p1 = mbr[446..462];
    p1[0] = 0x80; // active boot partition
    p1[1] = 0xFE;
    p1[2] = 0xFF;
    p1[3] = 0xFF;
    p1[4] = 0x0C; // FAT32 LBA
    p1[5] = 0xFE;
    p1[6] = 0xFF;
    p1[7] = 0xFF;
    wU32(mbr, 446 + 8, PART_START_SECTOR);
    wU32(mbr, 446 + 12, boot_part_sectors);
    const p2 = mbr[462..478];
    p2[0] = 0x00;
    p2[1] = 0xFE;
    p2[2] = 0xFF;
    p2[3] = 0xFF;
    p2[4] = 0x07; // NTFS
    p2[5] = 0xFE;
    p2[6] = 0xFF;
    p2[7] = 0xFF;
    wU32(mbr, 462 + 8, ntfs_lba);
    wU32(mbr, 462 + 12, system_sectors);
    mbr[510] = 0x55;
    mbr[511] = 0xAA;

    try cwd.writeFile(io, .{ .sub_path = out, .data = image });
    std.debug.print(
        "System image created: {s}\n  Boot partition (FAT32): sector {d}, {d} sectors ({d} boot files)\n  System volume (NTFS): sector {d}, {d} sectors ({d} files)\n",
        .{ out, PART_START_SECTOR, boot_part_sectors, boot_entries.items.len, ntfs_lba, system_sectors, system_entries.items.len },
    );
}
