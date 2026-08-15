// NTFS 3.1 volume builder (0.60.5).
//
// Formats a complete NTFS volume in memory: boot sector plus backup, MFT
// with the mkntfs-proven system record subset (0-15 plus $Extend children
// $Quota/$ObjId/$Reparse), cluster/MFT bitmaps, $LogFile filled 0xFF and a
// user file tree with collation-sorted $I30 B+ trees.  Volume-independent
// metadata ($UpCase, $AttrDef, $Secure descriptor stream and view-index
// blocks, security descriptors) comes from Windows-authored templates
// extracted from the reference fixture (ExtractNtfsMeta0605.zig).
//
// The TxF/$RmMetadata tree is intentionally absent: Windows creates it on
// first read-write mount; chkdsk accepts volumes without it (mkntfs model).

const std = @import("std");
const ntfs = @import("ntfs_format");

const SECTOR: usize = 512;
const CLUSTER: usize = 4096;
const RECORD: usize = 1024;
const INDEX_BLOCK: usize = 4096;
const MFT_INITIAL_RECORDS: usize = 512;
const MFT_BITMAP_DATA: usize = 4104;
const LOGFILE_BYTES: usize = 2 * 1024 * 1024;
const FIRST_USER_RECORD: u64 = 27;

pub const Meta = struct {
    upcase: []const u8,
    upcase_info: []const u8,
    attrdef: []const u8,
    sds_prefix: []const u8,
    sdh_root: []const u8,
    sii_root: []const u8,
    sdh_alloc: []const u8,
    sii_alloc: []const u8,
    sdh_bitmap: []const u8,
    sii_bitmap: []const u8,
    objid_o_root: []const u8,
    quota_o_root: []const u8,
    quota_q_root: []const u8,
    reparse_r_root: []const u8,
    root_sd: []const u8,
    boot_sd: []const u8,
    security_id_file: u32 = 265,
    security_id_dir: u32 = 264,
    security_id_sys: u32 = 256,
    security_id_sys_dir: u32 = 257,
};

pub const Error = error{
    VolumeTooSmall,
    TooManyFiles,
    NameInvalid,
    IndexOverflow,
    RecordOverflow,
    OutOfMemory,
};

const NodeIndex = u32;

const Node = struct {
    name: []const u8,
    is_dir: bool,
    data: []const u8 = &[_]u8{},
    parent: NodeIndex = 0,
    children: std.ArrayList(NodeIndex) = .empty,
    record: u64 = 0,
    // filled during layout:
    data_lcn: u64 = 0,
    data_clusters: u64 = 0,
    index: DirIndex = .{},
};

const DirIndex = struct {
    resident_entries: []u8 = &[_]u8{},
    blocks: []u8 = &[_]u8{},
    block_count: usize = 0,
    lcn: u64 = 0,
    root_has_children: bool = false,
    root_child_vcn: u64 = 0,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    meta: Meta,
    label: []const u8,
    partition_lba: u32,
    total_bytes: u64,
    timestamp: u64,
    serial: u64,
    nodes: std.ArrayList(Node) = .empty,
    // Layout values needed by the root index (set in finalize before
    // directory indexes are built).
    layout_mft_bytes: u64 = 0,
    layout_bitmap_alloc: u64 = 0,
    layout_bitmap_bytes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, total_bytes: u64, label: []const u8, partition_lba: u32, meta: Meta, timestamp_filetime: u64, serial: u64) !Builder {
        var builder = Builder{
            .allocator = allocator,
            .meta = meta,
            .label = label,
            .partition_lba = partition_lba,
            .total_bytes = total_bytes,
            .timestamp = timestamp_filetime,
            .serial = serial,
        };
        try builder.nodes.append(allocator, .{ .name = "", .is_dir = true, .record = ntfs.MFT_RECORD_ROOT });
        return builder;
    }

    pub fn root(self: *Builder) NodeIndex {
        _ = self;
        return 0;
    }

    pub fn addDirectory(self: *Builder, parent: NodeIndex, name: []const u8) !NodeIndex {
        if (!validName(name)) return Error.NameInvalid;
        const index: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .name = name, .is_dir = true, .parent = parent });
        try self.nodes.items[parent].children.append(self.allocator, index);
        return index;
    }

    /// Returns an existing child directory by name or creates it.
    pub fn ensureDirectory(self: *Builder, parent: NodeIndex, name: []const u8) !NodeIndex {
        for (self.nodes.items[parent].children.items) |child_index| {
            const child = &self.nodes.items[child_index];
            if (child.is_dir and std.ascii.eqlIgnoreCase(child.name, name)) return child_index;
        }
        return self.addDirectory(parent, name);
    }

    pub fn addFile(self: *Builder, parent: NodeIndex, name: []const u8, data: []const u8) !void {
        if (!validName(name)) return Error.NameInvalid;
        const index: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .name = name, .is_dir = false, .data = data, .parent = parent });
        try self.nodes.items[parent].children.append(self.allocator, index);
    }

    /// Builds the complete volume.  Caller owns the returned buffer.
    pub fn finalize(self: *Builder) ![]u8 {
        const total_sectors: u64 = self.total_bytes / SECTOR - 1;
        const total_clusters: u64 = total_sectors * SECTOR / CLUSTER;
        if (total_clusters < 4096) return Error.VolumeTooSmall;

        const image = try self.allocator.alloc(u8, @intCast(self.total_bytes));
        errdefer self.allocator.free(image);
        @memset(image, 0);

        var mft_records = MFT_INITIAL_RECORDS;
        while (FIRST_USER_RECORD + self.nodes.items.len + 16 > mft_records) mft_records += 256;
        if (mft_records > 4096) return Error.TooManyFiles;

        // ---- Cluster layout (bump allocation, bitmap maintained inline) ----
        const alloc_map = try self.allocator.alloc(u8, @intCast((total_clusters + 7) / 8));
        defer self.allocator.free(alloc_map);
        @memset(alloc_map, 0);
        var next_lcn: u64 = 0;

        const lcn_boot = try self.take(alloc_map, &next_lcn, total_clusters, 2);
        const logfile_clusters = LOGFILE_BYTES / CLUSTER;
        const lcn_logfile = try self.take(alloc_map, &next_lcn, total_clusters, logfile_clusters);
        const lcn_attrdef = try self.take(alloc_map, &next_lcn, total_clusters, 1);
        const bitmap_data: usize = @intCast(std.mem.alignForward(u64, (total_clusters + 7) / 8, 8));
        const bitmap_clusters = (bitmap_data + CLUSTER - 1) / CLUSTER;
        const lcn_bitmap = try self.take(alloc_map, &next_lcn, total_clusters, bitmap_clusters);
        const lcn_upcase = try self.take(alloc_map, &next_lcn, total_clusters, ntfs.UPCASE_BYTES / CLUSTER);
        const sds_data: usize = 0x40000 + std.mem.alignForward(usize, self.meta.sds_prefix.len, 4);
        const sds_clusters = (sds_data + CLUSTER - 1) / CLUSTER;
        const lcn_sds = try self.take(alloc_map, &next_lcn, total_clusters, sds_clusters);
        const lcn_sdh = try self.take(alloc_map, &next_lcn, total_clusters, 1);
        const lcn_sii = try self.take(alloc_map, &next_lcn, total_clusters, 1);
        const mft_clusters = mft_records * RECORD / CLUSTER;
        const lcn_mft = try self.take(alloc_map, &next_lcn, total_clusters, mft_clusters);
        const lcn_mft_bitmap = try self.take(alloc_map, &next_lcn, total_clusters, (MFT_BITMAP_DATA + CLUSTER - 1) / CLUSTER);
        const lcn_mftmirr = try self.take(alloc_map, &next_lcn, total_clusters, 1);

        self.layout_mft_bytes = mft_records * RECORD;
        self.layout_bitmap_alloc = bitmap_clusters * CLUSTER;
        self.layout_bitmap_bytes = bitmap_data;

        // User records, file data and directory indexes.
        var record_cursor: u64 = FIRST_USER_RECORD;
        for (self.nodes.items[1..]) |*node| {
            node.record = record_cursor;
            record_cursor += 1;
        }
        for (self.nodes.items[1..]) |*node| {
            if (node.is_dir or node.data.len == 0) continue;
            if (node.data.len > residentDataBudget()) {
                node.data_clusters = (node.data.len + CLUSTER - 1) / CLUSTER;
                node.data_lcn = try self.take(alloc_map, &next_lcn, total_clusters, node.data_clusters);
            }
        }
        for (self.nodes.items, 0..) |*node, node_index| {
            if (!node.is_dir) continue;
            try self.buildDirIndex(@intCast(node_index), alloc_map, &next_lcn, total_clusters);
        }

        // ---- Emit raw regions ----
        @memset(image[@intCast(lcn_logfile * CLUSTER)..@intCast(lcn_logfile * CLUSTER + LOGFILE_BYTES)], 0xFF);
        copyTo(image, lcn_attrdef * CLUSTER, self.meta.attrdef);
        copyTo(image, lcn_upcase * CLUSTER, self.meta.upcase);
        copyTo(image, lcn_sds * CLUSTER, self.meta.sds_prefix);
        copyTo(image, lcn_sds * CLUSTER + 0x40000, self.meta.sds_prefix);
        try self.emitTemplateIndx(image, lcn_sdh, self.meta.sdh_alloc);
        try self.emitTemplateIndx(image, lcn_sii, self.meta.sii_alloc);
        for (self.nodes.items[1..]) |*node| {
            if (node.is_dir or node.data_clusters == 0) continue;
            copyTo(image, node.data_lcn * CLUSTER, node.data);
        }
        for (self.nodes.items) |*node| {
            if (!node.is_dir or node.index.block_count == 0) continue;
            copyTo(image, node.index.lcn * CLUSTER, node.index.blocks[0 .. node.index.block_count * INDEX_BLOCK]);
        }

        // ---- MFT records ----
        const mft_base: usize = @intCast(lcn_mft * CLUSTER);
        var rb = RecordBuilder{ .builder = self };

        // 0 $MFT
        try rb.begin(image, mft_base, 0, 1, 0x01, 1);
        rb.si72(0x06, self.meta.security_id_sys);
        rb.fileName("$MFT", 0x06, false, mft_records * RECORD, mft_records * RECORD);
        rb.dataRun(&[_]u8{}, lcn_mft, mft_clusters, mft_records * RECORD, .{});
        rb.bitmapRun(lcn_mft_bitmap, (MFT_BITMAP_DATA + CLUSTER - 1) / CLUSTER, MFT_BITMAP_DATA);
        try rb.finish();

        // 1 $MFTMirr
        try rb.begin(image, mft_base, 1, 1, 0x01, 1);
        rb.si72(0x06, self.meta.security_id_sys);
        rb.fileName("$MFTMirr", 0x06, false, CLUSTER, CLUSTER);
        rb.dataRun(&[_]u8{}, lcn_mftmirr, 1, CLUSTER, .{});
        try rb.finish();

        // 2 $LogFile
        try rb.begin(image, mft_base, 2, 2, 0x01, 1);
        rb.si72(0x06, self.meta.security_id_sys);
        rb.fileName("$LogFile", 0x06, false, LOGFILE_BYTES, LOGFILE_BYTES);
        rb.dataRun(&[_]u8{}, lcn_logfile, logfile_clusters, LOGFILE_BYTES, .{});
        try rb.finish();

        // 3 $Volume
        try rb.begin(image, mft_base, 3, 3, 0x01, 1);
        rb.si72(0x06, self.meta.security_id_sys_dir);
        rb.fileName("$Volume", 0x06, false, 0, 0);
        rb.volumeName();
        rb.volumeInformation();
        rb.residentData(&[_]u8{}, &[_]u8{});
        try rb.finish();

        // 4 $AttrDef
        try rb.begin(image, mft_base, 4, 4, 0x01, 1);
        rb.si72(0x06, self.meta.security_id_sys);
        rb.fileName("$AttrDef", 0x06, false, alignUp(self.meta.attrdef.len, CLUSTER), self.meta.attrdef.len);
        rb.dataRun(&[_]u8{}, lcn_attrdef, 1, self.meta.attrdef.len, .{});
        try rb.finish();

        // 5 root directory
        try rb.begin(image, mft_base, 5, 5, 0x03, 1);
        rb.si48(0x06);
        rb.fileNameDot();
        rb.securityDescriptor(self.meta.root_sd);
        try rb.dirIndexAttrs(&self.nodes.items[0].index);
        try rb.finish();

        // 6 $Bitmap
        try rb.begin(image, mft_base, 6, 6, 0x01, 1);
        rb.si72(0x06, self.meta.security_id_sys);
        rb.fileName("$Bitmap", 0x06, false, bitmap_clusters * CLUSTER, bitmap_data);
        rb.dataRun(&[_]u8{}, lcn_bitmap, bitmap_clusters, bitmap_data, .{});
        try rb.finish();

        // 7 $Boot
        try rb.begin(image, mft_base, 7, 7, 0x01, 1);
        rb.si48(0x06);
        rb.fileName("$Boot", 0x06, false, 2 * CLUSTER, 8192);
        rb.securityDescriptor(self.meta.boot_sd);
        rb.dataRun(&[_]u8{}, lcn_boot, 2, 8192, .{});
        try rb.finish();

        // 8 $BadClus
        try rb.begin(image, mft_base, 8, 8, 0x01, 1);
        rb.si72(0x06, self.meta.security_id_sys);
        rb.fileName("$BadClus", 0x06, false, 0, 0);
        rb.residentData(&[_]u8{}, &[_]u8{});
        rb.sparseData("$Bad", total_clusters, total_clusters * CLUSTER);
        try rb.finish();

        // 9 $Secure
        try rb.begin(image, mft_base, 9, 9, 0x09, 1);
        rb.si72(0x06, self.meta.security_id_sys_dir);
        rb.fileName("$Secure", 0x20000006, false, 0, 0);
        rb.dataRun(utf16Of("$SDS"), lcn_sds, sds_clusters, sds_data, .{});
        rb.residentAttr(.index_root, utf16Of("$SDH"), self.meta.sdh_root, 0);
        rb.residentAttr(.index_root, utf16Of("$SII"), self.meta.sii_root, 0);
        rb.allocationRun(utf16Of("$SDH"), lcn_sdh, 1);
        rb.allocationRun(utf16Of("$SII"), lcn_sii, 1);
        rb.residentAttr(.bitmap, utf16Of("$SDH"), self.meta.sdh_bitmap, 0);
        rb.residentAttr(.bitmap, utf16Of("$SII"), self.meta.sii_bitmap, 0);
        try rb.finish();

        // 10 $UpCase
        try rb.begin(image, mft_base, 10, 10, 0x01, 1);
        rb.si72(0x06, self.meta.security_id_sys);
        rb.fileName("$UpCase", 0x06, false, ntfs.UPCASE_BYTES, ntfs.UPCASE_BYTES);
        rb.dataRun(&[_]u8{}, lcn_upcase, ntfs.UPCASE_BYTES / CLUSTER, ntfs.UPCASE_BYTES, .{});
        if (self.meta.upcase_info.len > 0) rb.residentAttr(.data, utf16Of("$Info"), self.meta.upcase_info, 0);
        try rb.finish();

        // 11 $Extend
        try rb.begin(image, mft_base, 11, 11, 0x03, 1);
        rb.si72(0x06, self.meta.security_id_sys_dir);
        rb.fileName("$Extend", 0x06, true, 0, 0);
        rb.extendIndex();
        try rb.finish();

        // 12-15 reserved
        var reserved: u64 = 12;
        while (reserved <= 15) : (reserved += 1) {
            try rb.begin(image, mft_base, reserved, @intCast(reserved), 0x01, 0);
            rb.si48(0x06);
            rb.securityDescriptor(self.meta.boot_sd);
            rb.residentData(&[_]u8{}, &[_]u8{});
            try rb.finish();
        }

        // 24 $Quota, 25 $ObjId, 26 $Reparse
        // View-index children carry the index-view attribute (0x20000006)
        // in both $STANDARD_INFORMATION and $FILE_NAME.
        try rb.begin(image, mft_base, 24, 1, 0x0D, 1);
        rb.si72(0x20000006, self.meta.security_id_sys_dir);
        rb.fileNameExtendChild("$Quota");
        rb.residentAttr(.index_root, utf16Of("$O"), self.meta.quota_o_root, 0);
        rb.residentAttr(.index_root, utf16Of("$Q"), self.meta.quota_q_root, 0);
        try rb.finish();
        try rb.begin(image, mft_base, 25, 1, 0x0D, 1);
        rb.si72(0x20000006, self.meta.security_id_sys_dir);
        rb.fileNameExtendChild("$ObjId");
        rb.residentAttr(.index_root, utf16Of("$O"), self.meta.objid_o_root, 0);
        try rb.finish();
        try rb.begin(image, mft_base, 26, 1, 0x0D, 1);
        rb.si72(0x20000006, self.meta.security_id_sys_dir);
        rb.fileNameExtendChild("$Reparse");
        rb.residentAttr(.index_root, utf16Of("$R"), self.meta.reparse_r_root, 0);
        try rb.finish();

        // User nodes.
        for (self.nodes.items[1..]) |*node| {
            const flags: u16 = if (node.is_dir) 0x03 else 0x01;
            try rb.begin(image, mft_base, node.record, 1, flags, 1);
            if (node.is_dir) {
                rb.si72(0x00, self.meta.security_id_dir);
            } else {
                rb.si72(0x20, self.meta.security_id_file);
            }
            rb.userFileName(node, self.nodes.items[node.parent].record);
            if (node.is_dir) {
                try rb.dirIndexAttrs(&node.index);
            } else if (node.data_clusters > 0) {
                rb.dataRun(&[_]u8{}, node.data_lcn, node.data_clusters, node.data.len, .{});
            } else {
                rb.residentData(&[_]u8{}, node.data);
            }
            try rb.finish();
        }

        // ---- Bitmaps, mirror, boot sectors ----
        const bitmap_off: usize = @intCast(lcn_bitmap * CLUSTER);
        @memcpy(image[bitmap_off .. bitmap_off + alloc_map.len], alloc_map);
        // Pad bits beyond the cluster count as allocated (Windows practice).
        var pad_bit: u64 = total_clusters;
        while (pad_bit < @as(u64, bitmap_data) * 8) : (pad_bit += 1) {
            image[bitmap_off + @as(usize, @intCast(pad_bit / 8))] |= @as(u8, 1) << @intCast(pad_bit % 8);
        }

        const mft_bitmap_off: usize = @intCast(lcn_mft_bitmap * CLUSTER);
        var used_record: u64 = 0;
        while (used_record < record_cursor) : (used_record += 1) {
            if (used_record >= 16 and used_record < 24) continue;
            image[mft_bitmap_off + @as(usize, @intCast(used_record / 8))] |= @as(u8, 1) << @intCast(used_record % 8);
        }

        const mirr_off: usize = @intCast(lcn_mftmirr * CLUSTER);
        @memcpy(image[mirr_off .. mirr_off + 4 * RECORD], image[mft_base .. mft_base + 4 * RECORD]);

        self.writeBootSector(image[0..SECTOR], total_sectors, lcn_mft, lcn_mftmirr);
        const backup_off: usize = @intCast(total_sectors * SECTOR);
        @memcpy(image[backup_off .. backup_off + SECTOR], image[0..SECTOR]);

        return image;
    }

    fn take(self: *Builder, alloc_map: []u8, next_lcn: *u64, total_clusters: u64, clusters: u64) !u64 {
        _ = self;
        if (next_lcn.* + clusters > total_clusters) return Error.VolumeTooSmall;
        const start = next_lcn.*;
        var c = start;
        while (c < start + clusters) : (c += 1) {
            alloc_map[@intCast(c / 8)] |= @as(u8, 1) << @intCast(c % 8);
        }
        next_lcn.* = start + clusters;
        return start;
    }

    fn emitTemplateIndx(self: *Builder, image: []u8, lcn: u64, template: []const u8) !void {
        _ = self;
        const offset: usize = @intCast(lcn * CLUSTER);
        copyTo(image, lcn * CLUSTER, template);
        const block = image[offset .. offset + INDEX_BLOCK];
        // Neutralize the Windows $LogFile LSN and restamp fixups.
        if (ntfs.applyFixups(block) != .ok) return Error.IndexOverflow;
        std.mem.writeInt(u64, block[0x08..0x10], 0, .little);
        if (ntfs.installFixups(block, 0) != .ok) return Error.IndexOverflow;
    }

    // ---- Directory index construction -------------------------------------

    fn buildDirIndex(self: *Builder, node_index: NodeIndex, alloc_map: []u8, next_lcn: *u64, total_clusters: u64) !void {
        const node = &self.nodes.items[node_index];
        var keys: std.ArrayList([]u8) = .empty;
        defer {
            for (keys.items) |k| self.allocator.free(k);
            keys.deinit(self.allocator);
        }

        if (node_index == 0) {
            // Duplicated FILE_NAME data in the index must match the record
            // FILE_NAME attributes byte for byte.
            const system_names = [_]struct { name: []const u8, record: u64, seq: u16, flags: u32, alloc: u64, size: u64 }{
                .{ .name = "$AttrDef", .record = 4, .seq = 4, .flags = 0x06, .alloc = CLUSTER, .size = self.meta.attrdef.len },
                .{ .name = "$BadClus", .record = 8, .seq = 8, .flags = 0x06, .alloc = 0, .size = 0 },
                .{ .name = "$Bitmap", .record = 6, .seq = 6, .flags = 0x06, .alloc = self.layout_bitmap_alloc, .size = self.layout_bitmap_bytes },
                .{ .name = "$Boot", .record = 7, .seq = 7, .flags = 0x06, .alloc = 2 * CLUSTER, .size = 8192 },
                .{ .name = "$Extend", .record = 11, .seq = 11, .flags = 0x10000006, .alloc = 0, .size = 0 },
                .{ .name = "$LogFile", .record = 2, .seq = 2, .flags = 0x06, .alloc = LOGFILE_BYTES, .size = LOGFILE_BYTES },
                .{ .name = "$MFT", .record = 0, .seq = 1, .flags = 0x06, .alloc = self.layout_mft_bytes, .size = self.layout_mft_bytes },
                .{ .name = "$MFTMirr", .record = 1, .seq = 1, .flags = 0x06, .alloc = CLUSTER, .size = CLUSTER },
                .{ .name = "$Secure", .record = 9, .seq = 9, .flags = 0x20000006, .alloc = 0, .size = 0 },
                .{ .name = "$UpCase", .record = 10, .seq = 10, .flags = 0x06, .alloc = ntfs.UPCASE_BYTES, .size = ntfs.UPCASE_BYTES },
                .{ .name = "$Volume", .record = 3, .seq = 3, .flags = 0x06, .alloc = 0, .size = 0 },
            };
            for (system_names) |sys| {
                try keys.append(self.allocator, try self.makeFileNameKey(sys.name, sys.record, sys.seq, sys.flags, false, sys.alloc, sys.size, 3));
            }
            try keys.append(self.allocator, try self.makeFileNameKey(".", 5, 5, 0x10000006, true, 0, 0, 3));
        }

        for (node.children.items) |child_index| {
            const child = &self.nodes.items[child_index];
            const namespace: u8 = if (is83Safe(child.name)) 3 else 0;
            const flags: u32 = if (child.is_dir) 0x10000000 else 0x20;
            const data_alloc: u64 = if (child.data_clusters > 0) child.data_clusters * CLUSTER else alignUp(child.data.len, 8);
            try keys.append(self.allocator, try self.makeFileNameKey(child.name, child.record, 1, flags, child.is_dir, data_alloc, child.data.len, namespace));
        }

        // Sort by collation order.
        const upcase = self.meta.upcase;
        std.mem.sort([]u8, keys.items, upcase, keyLess);

        try self.assembleIndex(node, keys.items, alloc_map, next_lcn, total_clusters);
    }

    fn keyLess(upcase: []const u8, a: []u8, b: []u8) bool {
        const na = keyName(a);
        const nb = keyName(b);
        return ntfs.compareFileNames(upcase, na, nb) == .lt;
    }

    fn keyName(key: []u8) []const u8 {
        const len = key[8 + 0x40];
        return key[8 + 0x42 .. 8 + 0x42 + @as(usize, len) * 2];
    }

    /// Builds one FILE_NAME index key prefixed with its 8-byte reference.
    fn makeFileNameKey(self: *Builder, name: []const u8, record: u64, seq: u16, base_flags: u32, is_dir: bool, alloc_size: u64, data_size: u64, namespace: u8) ![]u8 {
        var flags = base_flags;
        if (is_dir) flags |= 0x10000000;
        const fn_len = 0x42 + name.len * 2;
        const key = try self.allocator.alloc(u8, 8 + fn_len);
        @memset(key, 0);
        std.mem.writeInt(u64, key[0..8], ntfs.FileReference.pack(.{ .record = record, .sequence = seq }), .little);
        const value = key[8..];
        std.mem.writeInt(u64, value[0..8], ntfs.FileReference.pack(.{ .record = 5, .sequence = 5 }), .little);
        var t: usize = 0x08;
        while (t <= 0x20) : (t += 8) std.mem.writeInt(u64, value[t..][0..8], self.timestamp, .little);
        std.mem.writeInt(u64, value[0x28..][0..8], alloc_size, .little);
        std.mem.writeInt(u64, value[0x30..][0..8], data_size, .little);
        std.mem.writeInt(u32, value[0x38..][0..4], flags, .little);
        value[0x40] = @intCast(name.len);
        value[0x41] = namespace;
        for (name, 0..) |c, i| {
            value[0x42 + i * 2] = c;
            value[0x42 + i * 2 + 1] = 0;
        }
        return key;
    }

    const ROOT_ENTRY_BUDGET: usize = 0x150;

    fn assembleIndex(self: *Builder, node: *Node, keys: [][]u8, alloc_map: []u8, next_lcn: *u64, total_clusters: u64) !void {
        // Parent references inside keys point at record 5 by default; patch
        // to the real parent for non-root directories.
        for (keys) |key| {
            std.mem.writeInt(u64, key[8..][0..8], ntfs.FileReference.pack(.{
                .record = node.record,
                .sequence = if (node.record <= 15) @intCast(@max(node.record, 1)) else 1,
            }), .little);
        }

        var resident_total: usize = 0;
        for (keys) |key| resident_total += entryLength(key.len - 8, false);
        if (resident_total + 0x10 <= ROOT_ENTRY_BUDGET) {
            // Small directory: all entries resident in INDEX_ROOT.
            var buffer = try self.allocator.alloc(u8, resident_total + 0x10);
            var offset: usize = 0;
            for (keys) |key| offset += writeEntry(buffer[offset..], key, null);
            offset += writeEndEntry(buffer[offset..], null);
            node.index.resident_entries = buffer[0..offset];
            return;
        }

        // Large directory: bottom-up B+ tree.  A block that overflows is
        // closed with END(child = overflowing entry's own child); the
        // overflowing entry is promoted upward carrying the closed block.
        // The trailing block of each level becomes the END child one level
        // up; the final single block is the root child.
        var finished: std.ArrayList([]u8) = .empty;
        defer finished.deinit(self.allocator);
        errdefer for (finished.items) |b| self.allocator.free(b);

        var current: std.ArrayList(PendingEntry) = .empty;
        defer current.deinit(self.allocator);
        for (keys) |key| try current.append(self.allocator, .{ .key = key, .child = null });

        var trailing_child: ?u64 = null;
        var top_vcn: u64 = 0;
        var depth_guard: usize = 0;
        while (true) {
            depth_guard += 1;
            if (depth_guard > 8) return Error.IndexOverflow;
            var promoted: std.ArrayList(PendingEntry) = .empty;
            defer promoted.deinit(self.allocator);

            var open: std.ArrayList(PendingEntry) = .empty;
            defer open.deinit(self.allocator);
            var used: usize = 0;
            const capacity = INDEX_BLOCK - 0x40 - 0x18;

            for (current.items) |pending| {
                const len = entryLength(pending.key.len - 8, pending.child != null);
                if (used + len > capacity) {
                    const vcn = try self.closeIndexBlock(&finished, open.items, pending.child);
                    try promoted.append(self.allocator, .{ .key = pending.key, .child = vcn });
                    open.clearRetainingCapacity();
                    used = 0;
                    continue;
                }
                try open.append(self.allocator, pending);
                used += len;
            }
            const last_vcn = try self.closeIndexBlock(&finished, open.items, trailing_child);

            if (promoted.items.len == 0) {
                top_vcn = last_vcn;
                break;
            }
            current.clearRetainingCapacity();
            for (promoted.items) |p| try current.append(self.allocator, p);
            trailing_child = last_vcn;
        }

        const total_blocks = finished.items.len;
        if (total_blocks > 4096) return Error.IndexOverflow;
        const blocks = try self.allocator.alloc(u8, total_blocks * INDEX_BLOCK);
        for (finished.items, 0..) |b, bi| {
            @memcpy(blocks[bi * INDEX_BLOCK .. (bi + 1) * INDEX_BLOCK], b);
            self.allocator.free(b);
        }
        finished.clearRetainingCapacity();

        const lcn = try self.take(alloc_map, next_lcn, total_clusters, total_blocks);
        node.index.blocks = blocks;
        node.index.block_count = total_blocks;
        node.index.lcn = lcn;
        node.index.root_child_vcn = top_vcn;
        node.index.root_has_children = true;
    }

    /// Writes one finished INDX block; entries keep their children, the END
    /// entry carries `end_child`.  Returns the block's VCN.
    fn closeIndexBlock(self: *Builder, finished: *std.ArrayList([]u8), entries: []const PendingEntry, end_child: ?u64) !u64 {
        const block = try self.allocator.alloc(u8, INDEX_BLOCK);
        @memset(block, 0);
        var offset: usize = 0x40;
        var has_children = end_child != null;
        for (entries) |pending| {
            if (pending.child != null) has_children = true;
            offset += writeEntry(block[offset..], pending.key, pending.child);
        }
        offset += writeEndEntry(block[offset..], end_child);
        const vcn: u64 = finished.items.len;
        writeIndxHeader(block, vcn, offset, has_children);
        if (ntfs.installFixups(block, 0) != .ok) return Error.IndexOverflow;
        try finished.append(self.allocator, block);
        return vcn;
    }

    // ---- Boot sector -------------------------------------------------------

    fn writeBootSector(self: *Builder, sector: []u8, total_sectors: u64, mft_lcn: u64, mftmirr_lcn: u64) void {
        @memset(sector, 0);
        sector[0] = 0xEB;
        sector[1] = 0x52;
        sector[2] = 0x90;
        @memcpy(sector[3..11], "NTFS    ");
        std.mem.writeInt(u16, sector[0x0B..0x0D], SECTOR, .little);
        sector[0x0D] = CLUSTER / SECTOR;
        sector[0x15] = 0xF8;
        std.mem.writeInt(u16, sector[0x18..0x1A], 63, .little);
        std.mem.writeInt(u16, sector[0x1A..0x1C], 255, .little);
        std.mem.writeInt(u32, sector[0x1C..0x20], self.partition_lba, .little);
        std.mem.writeInt(u32, sector[0x24..0x28], 0x00800080, .little);
        std.mem.writeInt(u64, sector[0x28..0x30], total_sectors, .little);
        std.mem.writeInt(u64, sector[0x30..0x38], mft_lcn, .little);
        std.mem.writeInt(u64, sector[0x38..0x40], mftmirr_lcn, .little);
        sector[0x40] = 0xF6; // 1024-byte records
        sector[0x44] = 0x01; // one cluster per index block
        std.mem.writeInt(u64, sector[0x48..0x50], self.serial, .little);
        sector[0x1FE] = 0x55;
        sector[0x1FF] = 0xAA;
    }
};

const PendingEntry = struct {
    key: []const u8, // 8-byte reference + FILE_NAME value
    child: ?u64, // VCN of the subtree with smaller keys
};

fn residentDataBudget() usize {
    return 0x2C0;
}

fn entryLength(fn_value_len: usize, has_child: bool) usize {
    var len = std.mem.alignForward(usize, 0x10 + fn_value_len, 8);
    if (has_child) len += 8;
    return len;
}

fn writeEntry(out: []u8, key: []const u8, child_vcn: ?u64) usize {
    const fn_value = key[8..];
    const len = entryLength(fn_value.len, child_vcn != null);
    @memset(out[0..len], 0);
    @memcpy(out[0..8], key[0..8]);
    std.mem.writeInt(u16, out[8..10], @intCast(len), .little);
    std.mem.writeInt(u16, out[10..12], @intCast(fn_value.len), .little);
    std.mem.writeInt(u16, out[12..14], if (child_vcn != null) ntfs.INDEX_ENTRY_NODE else 0, .little);
    @memcpy(out[0x10 .. 0x10 + fn_value.len], fn_value);
    if (child_vcn) |vcn| std.mem.writeInt(u64, out[len - 8 ..][0..8], vcn, .little);
    return len;
}

fn writeEndEntry(out: []u8, child_vcn: ?u64) usize {
    const len: usize = if (child_vcn != null) 0x18 else 0x10;
    @memset(out[0..len], 0);
    std.mem.writeInt(u16, out[8..10], @intCast(len), .little);
    std.mem.writeInt(u16, out[12..14], if (child_vcn != null) ntfs.INDEX_ENTRY_END | ntfs.INDEX_ENTRY_NODE else ntfs.INDEX_ENTRY_END, .little);
    if (child_vcn) |vcn| std.mem.writeInt(u64, out[len - 8 ..][0..8], vcn, .little);
    return len;
}

fn writeIndxHeader(block: []u8, vcn: u64, used_end: usize, has_children: bool) void {
    std.mem.writeInt(u32, block[0..4], ntfs.INDX_MAGIC, .little);
    std.mem.writeInt(u16, block[4..6], 0x28, .little);
    std.mem.writeInt(u16, block[6..8], 9, .little);
    std.mem.writeInt(u64, block[8..16], 0, .little);
    std.mem.writeInt(u64, block[16..24], vcn, .little);
    std.mem.writeInt(u32, block[0x18..][0..4], 0x28, .little); // entries_offset (rel 0x18)
    std.mem.writeInt(u32, block[0x1C..][0..4], @intCast(used_end - 0x18), .little);
    std.mem.writeInt(u32, block[0x20..][0..4], INDEX_BLOCK - 0x18, .little);
    block[0x24] = if (has_children) 1 else 0;
}

fn copyTo(image: []u8, offset: u64, bytes: []const u8) void {
    const off: usize = @intCast(offset);
    @memcpy(image[off .. off + bytes.len], bytes);
}

fn alignUp(value: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, value, alignment);
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    for (name) |c| {
        if (c < 0x20 or c > 0x7E) return false;
        switch (c) {
            '"', '*', '/', ':', '<', '>', '?', '\\', '|' => return false,
            else => {},
        }
    }
    return true;
}

fn is83Safe(name: []const u8) bool {
    var dot: ?usize = null;
    for (name, 0..) |c, i| {
        if (c == '.') {
            if (dot != null) return false;
            dot = i;
            continue;
        }
        const upper_ok = (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '~' or c == '$' or c == '@' or c == '!' or c == '#' or c == '%' or c == '&' or c == '\'' or c == '(' or c == ')' or c == '{' or c == '}' or c == '^' or c == '`';
        if (!upper_ok) return false;
    }
    const base_len = dot orelse name.len;
    if (base_len == 0 or base_len > 8) return false;
    if (dot) |d| {
        const ext_len = name.len - d - 1;
        if (ext_len == 0 or ext_len > 3) return false;
    }
    return true;
}

var utf16_scratch: [16][64]u8 = undefined;
var utf16_scratch_next: usize = 0;

fn utf16Of(ascii: []const u8) []const u8 {
    const slot = &utf16_scratch[utf16_scratch_next];
    utf16_scratch_next = (utf16_scratch_next + 1) % utf16_scratch.len;
    for (ascii, 0..) |c, i| {
        slot[i * 2] = c;
        slot[i * 2 + 1] = 0;
    }
    return slot[0 .. ascii.len * 2];
}

// ---------------------------------------------------------------------------
// MFT record builder
// ---------------------------------------------------------------------------

const RecordBuilder = struct {
    builder: *Builder = undefined,
    record: []u8 = &[_]u8{},
    offset: usize = 0,
    instance: u16 = 0,
    number: u64 = 0,
    failed: bool = false,

    fn begin(self: *RecordBuilder, image: []u8, mft_base: usize, number: u64, sequence: u16, flags: u16, link_count: u16) !void {
        const off = mft_base + @as(usize, @intCast(number)) * RECORD;
        self.record = image[off .. off + RECORD];
        self.number = number;
        self.instance = 0;
        self.failed = false;
        const r = self.record;
        @memset(r, 0);
        std.mem.writeInt(u32, r[0..4], ntfs.FILE_MAGIC, .little);
        std.mem.writeInt(u16, r[4..6], 0x30, .little); // usa_ofs
        std.mem.writeInt(u16, r[6..8], 3, .little); // usa_count (1 KB record)
        std.mem.writeInt(u16, r[0x10..0x12], sequence, .little);
        std.mem.writeInt(u16, r[0x12..0x14], link_count, .little);
        std.mem.writeInt(u16, r[0x14..0x16], 0x38, .little); // attrs_offset
        std.mem.writeInt(u16, r[0x16..0x18], flags, .little);
        std.mem.writeInt(u32, r[0x1C..0x20], RECORD, .little);
        std.mem.writeInt(u32, r[0x2C..0x30], @intCast(number), .little);
        self.offset = 0x38;
    }

    fn finish(self: *RecordBuilder) !void {
        if (self.failed or self.offset + 8 > RECORD) return Error.RecordOverflow;
        const r = self.record;
        std.mem.writeInt(u32, r[self.offset..][0..4], ntfs.END_MARKER, .little);
        std.mem.writeInt(u32, r[self.offset + 4 ..][0..4], 0, .little);
        std.mem.writeInt(u32, r[0x18..0x1C], @intCast(self.offset + 8), .little);
        std.mem.writeInt(u16, r[0x28..0x2A], self.instance, .little);
        if (ntfs.installFixups(r, 0) != .ok) return Error.RecordOverflow;
    }

    fn attrHeader(self: *RecordBuilder, attr_type: ntfs.AttrType, name_utf16: []const u8, non_resident: bool, attr_flags: u16, body_len: usize) ?usize {
        const name_offset: usize = if (non_resident) 0x40 else 0x18;
        const value_offset = std.mem.alignForward(usize, name_offset + name_utf16.len, 8);
        const total = std.mem.alignForward(usize, value_offset + body_len, 8);
        if (self.offset + total + 8 > RECORD) {
            self.failed = true;
            return null;
        }
        const a = self.record[self.offset..];
        @memset(a[0..total], 0);
        std.mem.writeInt(u32, a[0..4], @intFromEnum(attr_type), .little);
        std.mem.writeInt(u32, a[4..8], @intCast(total), .little);
        a[8] = if (non_resident) 1 else 0;
        a[9] = @intCast(name_utf16.len / 2);
        std.mem.writeInt(u16, a[10..12], @intCast(name_offset), .little);
        std.mem.writeInt(u16, a[12..14], attr_flags, .little);
        std.mem.writeInt(u16, a[14..16], self.instance, .little);
        self.instance += 1;
        if (name_utf16.len > 0) @memcpy(a[name_offset .. name_offset + name_utf16.len], name_utf16);
        const at = self.offset;
        self.offset += total;
        return at;
    }

    fn residentAttr(self: *RecordBuilder, attr_type: ntfs.AttrType, name_utf16: []const u8, value: []const u8, indexed: u8) void {
        const name_offset: usize = 0x18;
        const value_offset = std.mem.alignForward(usize, name_offset + name_utf16.len, 8);
        const at = self.attrHeader(attr_type, name_utf16, false, 0, (value_offset - name_offset) + value.len) orelse return;
        const a = self.record[at..];
        std.mem.writeInt(u32, a[0x10..][0..4], @intCast(value.len), .little);
        std.mem.writeInt(u16, a[0x14..][0..2], @intCast(value_offset), .little);
        a[0x16] = indexed;
        @memcpy(a[value_offset .. value_offset + value.len], value);
        // Correct the total length (attrHeader assumed body starts at name_offset).
        const total = std.mem.alignForward(usize, value_offset + value.len, 8);
        std.mem.writeInt(u32, a[4..8], @intCast(total), .little);
        self.offset = at + total;
    }

    fn nonResidentAttr(self: *RecordBuilder, attr_type: ntfs.AttrType, name_utf16: []const u8, runs: []const RunSpec, data_size: u64, init_size: u64, alloc_size: u64, attr_flags: u16) void {
        var mapping: [64]u8 = undefined;
        var mapping_len: usize = 0;
        var previous: i64 = 0;
        var vcn_total: u64 = 0;
        for (runs) |run| {
            const delta: ?i64 = if (run.lcn) |lcn| @as(i64, @intCast(lcn)) - previous else null;
            const written = ntfs.encodeRun(mapping[mapping_len..], run.clusters, delta) orelse {
                self.failed = true;
                return;
            };
            mapping_len += written;
            if (run.lcn) |lcn| previous = @intCast(lcn);
            vcn_total += run.clusters;
        }
        mapping[mapping_len] = 0;
        mapping_len += 1;

        const name_offset: usize = 0x40;
        const mapping_offset = std.mem.alignForward(usize, name_offset + name_utf16.len, 8);
        const at = self.attrHeader(attr_type, name_utf16, true, attr_flags, (mapping_offset - name_offset) + mapping_len) orelse return;
        const a = self.record[at..];
        std.mem.writeInt(u64, a[0x18..][0..8], vcn_total - 1, .little); // highest_vcn
        std.mem.writeInt(u16, a[0x20..][0..2], @intCast(mapping_offset), .little);
        std.mem.writeInt(u64, a[0x28..][0..8], alloc_size, .little);
        std.mem.writeInt(u64, a[0x30..][0..8], data_size, .little);
        std.mem.writeInt(u64, a[0x38..][0..8], init_size, .little);
        @memcpy(a[mapping_offset .. mapping_offset + mapping_len], mapping[0..mapping_len]);
        const total = std.mem.alignForward(usize, mapping_offset + mapping_len, 8);
        std.mem.writeInt(u32, a[4..8], @intCast(total), .little);
        self.offset = at + total;
    }

    const RunSpec = struct { lcn: ?u64, clusters: u64 };
    const DataOpts = struct { init_size: ?u64 = null };

    fn dataRun(self: *RecordBuilder, name_utf16: []const u8, lcn: u64, clusters: u64, data_size: u64, opts: DataOpts) void {
        self.nonResidentAttr(.data, name_utf16, &[_]RunSpec{.{ .lcn = lcn, .clusters = clusters }}, data_size, opts.init_size orelse data_size, clusters * CLUSTER, 0);
    }

    fn bitmapRun(self: *RecordBuilder, lcn: u64, clusters: u64, data_size: u64) void {
        self.nonResidentAttr(.bitmap, &[_]u8{}, &[_]RunSpec{.{ .lcn = lcn, .clusters = clusters }}, data_size, data_size, clusters * CLUSTER, 0);
    }

    fn allocationRun(self: *RecordBuilder, name_utf16: []const u8, lcn: u64, clusters: u64) void {
        self.nonResidentAttr(.index_allocation, name_utf16, &[_]RunSpec{.{ .lcn = lcn, .clusters = clusters }}, clusters * CLUSTER, clusters * CLUSTER, clusters * CLUSTER, 0);
    }

    fn sparseData(self: *RecordBuilder, name_ascii: []const u8, clusters: u64, data_size: u64) void {
        self.nonResidentAttr(.data, utf16Of(name_ascii), &[_]RunSpec{.{ .lcn = null, .clusters = clusters }}, data_size, 0, data_size, 0);
    }

    fn residentData(self: *RecordBuilder, name_utf16: []const u8, value: []const u8) void {
        self.residentAttr(.data, name_utf16, value, 0);
    }

    fn si72(self: *RecordBuilder, file_attrs: u32, security_id: u32) void {
        var value: [0x48]u8 = .{0} ** 0x48;
        var t: usize = 0;
        while (t < 0x20) : (t += 8) std.mem.writeInt(u64, value[t..][0..8], self.builder.timestamp, .little);
        std.mem.writeInt(u32, value[0x20..][0..4], file_attrs, .little);
        std.mem.writeInt(u32, value[0x34..][0..4], security_id, .little);
        self.residentAttr(.standard_information, &[_]u8{}, value[0..], 0);
    }

    fn si48(self: *RecordBuilder, file_attrs: u32) void {
        var value: [0x30]u8 = .{0} ** 0x30;
        var t: usize = 0;
        while (t < 0x20) : (t += 8) std.mem.writeInt(u64, value[t..][0..8], self.builder.timestamp, .little);
        std.mem.writeInt(u32, value[0x20..][0..4], file_attrs, .little);
        self.residentAttr(.standard_information, &[_]u8{}, value[0..], 0);
    }

    fn securityDescriptor(self: *RecordBuilder, sd: []const u8) void {
        self.residentAttr(.security_descriptor, &[_]u8{}, sd, 0);
    }

    fn fileNameValue(self: *RecordBuilder, name: []const u8, parent_record: u64, parent_seq: u16, flags: u32, alloc_size: u64, data_size: u64, namespace: u8) void {
        var value: [0x42 + 2 * 255]u8 = undefined;
        const len = 0x42 + name.len * 2;
        @memset(value[0..len], 0);
        std.mem.writeInt(u64, value[0..8], ntfs.FileReference.pack(.{ .record = parent_record, .sequence = parent_seq }), .little);
        var t: usize = 0x08;
        while (t <= 0x20) : (t += 8) std.mem.writeInt(u64, value[t..][0..8], self.builder.timestamp, .little);
        std.mem.writeInt(u64, value[0x28..][0..8], alloc_size, .little);
        std.mem.writeInt(u64, value[0x30..][0..8], data_size, .little);
        std.mem.writeInt(u32, value[0x38..][0..4], flags, .little);
        value[0x40] = @intCast(name.len);
        value[0x41] = namespace;
        for (name, 0..) |c, i| {
            value[0x42 + i * 2] = c;
            value[0x42 + i * 2 + 1] = 0;
        }
        self.residentAttr(.file_name, &[_]u8{}, value[0..len], 1);
    }

    fn fileName(self: *RecordBuilder, name: []const u8, attr_flags: u32, is_dir: bool, alloc_size: u64, data_size: u64) void {
        var flags = attr_flags;
        if (is_dir) flags |= 0x10000000;
        self.fileNameValue(name, 5, 5, flags, alloc_size, data_size, 3);
    }

    fn fileNameDot(self: *RecordBuilder) void {
        self.fileNameValue(".", 5, 5, 0x10000006, 0, 0, 3);
    }

    fn fileNameExtendChild(self: *RecordBuilder, name: []const u8) void {
        // $Quota/$ObjId/$Reparse are view-index carriers, not directories:
        // Windows sets FILE_ATTRIBUTE_INDEX_VIEW (0x20000000) in both
        // $STANDARD_INFORMATION and $FILE_NAME, not the 0x10000000 dir bit.
        self.fileNameValue(name, 11, 11, 0x20000006, 0, 0, 3);
    }

    fn userFileName(self: *RecordBuilder, node: *const Node, parent_record: u64) void {
        // Lone non-8.3 names are POSIX namespace (chkdsk normalizes lone
        // Win32 names on 8.3-enabled volumes); resident data reports its
        // 8-aligned in-record allocation.
        const namespace: u8 = if (is83Safe(node.name)) 3 else 0;
        const flags: u32 = if (node.is_dir) 0x10000000 else 0x20;
        const parent_seq: u16 = if (parent_record <= 15) @intCast(@max(parent_record, 1)) else 1;
        const data_alloc: u64 = if (node.data_clusters > 0) node.data_clusters * CLUSTER else alignUp(node.data.len, 8);
        self.fileNameValue(node.name, parent_record, parent_seq, flags, data_alloc, node.data.len, namespace);
    }

    fn volumeName(self: *RecordBuilder) void {
        var value: [128]u8 = undefined;
        const count = @min(self.builder.label.len, 32);
        for (self.builder.label[0..count], 0..) |c, i| {
            value[i * 2] = c;
            value[i * 2 + 1] = 0;
        }
        self.residentAttr(.volume_name, &[_]u8{}, value[0 .. count * 2], 0);
    }

    fn volumeInformation(self: *RecordBuilder) void {
        var value: [12]u8 = .{0} ** 12;
        value[8] = 3;
        value[9] = 1;
        self.residentAttr(.volume_information, &[_]u8{}, value[0..], 0);
    }

    /// $Extend directory index: entries for $ObjId, $Quota, $Reparse in
    /// collation order (all directories), resident in INDEX_ROOT.
    fn extendIndex(self: *RecordBuilder) void {
        const children = [_]struct { name: []const u8, record: u64 }{
            .{ .name = "$ObjId", .record = 25 },
            .{ .name = "$Quota", .record = 24 },
            .{ .name = "$Reparse", .record = 26 },
        };
        var root_value: [0x200]u8 = undefined;
        @memset(root_value[0..0x10], 0);
        std.mem.writeInt(u32, root_value[0..4], 0x30, .little);
        std.mem.writeInt(u32, root_value[4..8], ntfs.COLLATION_FILE_NAME, .little);
        std.mem.writeInt(u32, root_value[8..12], INDEX_BLOCK, .little);
        root_value[12] = 1;
        const header_at: usize = 0x10;
        std.mem.writeInt(u32, root_value[header_at..][0..4], 0x10, .little);
        var e = header_at + 0x10;
        for (children) |child| {
            var key: [8 + 0x42 + 2 * 16]u8 = undefined;
            const fn_len = 0x42 + child.name.len * 2;
            @memset(key[0 .. 8 + fn_len], 0);
            std.mem.writeInt(u64, key[0..8], ntfs.FileReference.pack(.{ .record = child.record, .sequence = 1 }), .little);
            const value = key[8..];
            std.mem.writeInt(u64, value[0..8], ntfs.FileReference.pack(.{ .record = 11, .sequence = 11 }), .little);
            var t: usize = 0x08;
            while (t <= 0x20) : (t += 8) std.mem.writeInt(u64, value[t..][0..8], self.builder.timestamp, .little);
            std.mem.writeInt(u32, value[0x38..][0..4], 0x20000006, .little);
            value[0x40] = @intCast(child.name.len);
            value[0x41] = 3;
            for (child.name, 0..) |c, i| value[0x42 + i * 2] = c;
            e += writeEntry(root_value[e..], key[0 .. 8 + fn_len], null);
        }
        e += writeEndEntry(root_value[e..], null);
        std.mem.writeInt(u32, root_value[header_at + 4 ..][0..4], @intCast(e - header_at), .little);
        std.mem.writeInt(u32, root_value[header_at + 8 ..][0..4], @intCast(e - header_at), .little);
        root_value[header_at + 0x0C] = 0;
        self.residentAttr(.index_root, utf16Of("$I30"), root_value[0..e], 0);
    }

    fn dirIndexAttrs(self: *RecordBuilder, index: *const DirIndex) !void {
        var root_value: [0x200]u8 = undefined;
        var offset: usize = 0;
        std.mem.writeInt(u32, root_value[0..4], 0x30, .little);
        std.mem.writeInt(u32, root_value[4..8], ntfs.COLLATION_FILE_NAME, .little);
        std.mem.writeInt(u32, root_value[8..12], INDEX_BLOCK, .little);
        root_value[12] = 1;
        root_value[13] = 0;
        root_value[14] = 0;
        root_value[15] = 0;
        offset = 0x10;
        if (index.root_has_children) {
            const header_at = offset;
            std.mem.writeInt(u32, root_value[header_at..][0..4], 0x10, .little);
            var e = header_at + 0x10;
            e += writeEndEntry(root_value[e..], index.root_child_vcn);
            std.mem.writeInt(u32, root_value[header_at + 4 ..][0..4], @intCast(e - header_at), .little);
            std.mem.writeInt(u32, root_value[header_at + 8 ..][0..4], @intCast(e - header_at), .little);
            root_value[header_at + 0x0C] = 1;
            offset = e;
        } else {
            const header_at = offset;
            std.mem.writeInt(u32, root_value[header_at..][0..4], 0x10, .little);
            const entries = index.resident_entries;
            if (header_at + 0x10 + entries.len > root_value.len) return Error.IndexOverflow;
            @memcpy(root_value[header_at + 0x10 .. header_at + 0x10 + entries.len], entries);
            const e = header_at + 0x10 + entries.len;
            std.mem.writeInt(u32, root_value[header_at + 4 ..][0..4], @intCast(e - header_at), .little);
            std.mem.writeInt(u32, root_value[header_at + 8 ..][0..4], @intCast(e - header_at), .little);
            root_value[header_at + 0x0C] = 0;
            offset = e;
        }
        self.residentAttr(.index_root, utf16Of("$I30"), root_value[0..offset], 0);
        if (index.block_count > 0) {
            self.allocationRun(utf16Of("$I30"), index.lcn, index.block_count);
            var bitmap_value: [64]u8 = .{0} ** 64;
            var bit: usize = 0;
            while (bit < index.block_count) : (bit += 1) {
                bitmap_value[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
            }
            const bitmap_len = std.mem.alignForward(usize, (index.block_count + 7) / 8, 8);
            self.residentAttr(.bitmap, utf16Of("$I30"), bitmap_value[0..bitmap_len], 0);
        }
    }
};
