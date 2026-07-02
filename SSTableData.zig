const std = @import("std");
const Allocator = std.mem.Allocator;
const defaultRestartInterval = 16;
const defaultDataBlockSize = 4096; // 4 KB
const writeInt = @import("ioutils.zig").writeInt;
const readInt = @import("ioutils.zig").readInt;
const defaultEndian = @import("ioutils.zig").defaultEndian;
pub const Err = error{NotFound};
pub const Footer = struct {
    indexBlockOffset: usize,
    pub fn writeTo(self: Footer, wr: *std.Io.Writer) !void {
        try writeInt(usize, wr, self.indexBlockOffset);
    }
    pub fn readFrom(self: *Footer, rd: *std.Io.Reader) !void {
        try readInt(usize, rd, &self.indexBlockOffset);
    }
};

// DataBlock: [DataEntry_1][DataEntry_2]...[DataEntry_N][RestartPoint1][RestartPoint2]...[RestartPointM]
pub const DataBlock = struct {
    entries: []DataEntry,
    restart_interval: usize = defaultRestartInterval,
    pub const restartPoint = usize;
    pub const restartPointCount = u16;
    pub const blockSize = usize;
    pub const offset = usize;
    pub fn writeEntries(self: *DataBlock, wr: *std.Io.Writer) !usize {
        const writtenEntries = self.compressKeys();
        try writeInt(blockSize, wr, self.size(writtenEntries));
        try writeInt(u16, wr, @intCast(writtenEntries));
        for (self.entries[0..writtenEntries]) |*entry| {
            try entry.writeTo(wr);
        }
        try self.writeRestartPoints(wr, writtenEntries);
        return writtenEntries;
    }

    pub fn readEntries(self: *DataBlock, allocator: Allocator, rd: std.Io.Reader) !void {
        var entryCount: u16 = 0;
        try readInt(u16, rd, &entryCount);
        self.entries = try allocator.alloc(DataEntry, entryCount);
        for (self.entries) |*entry| {
            try entry.readFrom(allocator, rd);
        }
    }
    pub fn readRestartPoints(pts: []restartPoint, rd: *std.Io.Reader) !void {
        for (pts) |*pt| {
            try readInt(restartPoint, rd, pt);
        }
    }
    pub fn restartPtCount(rd: *std.Io.Reader) !restartPointCount {
        var count: restartPointCount = undefined;
        try readInt(restartPointCount, rd, &count);
        return count;
    }
    pub fn readSize(rd: *std.Io.Reader) !blockSize {
        var siz: blockSize = 0;
        try readInt(blockSize, rd, &siz);
        return siz;
    }
    pub fn size(self: DataBlock, entries: usize) usize {
        var s: usize = @sizeOf(blockSize) + @sizeOf(u16); //  total block size + entry count
        for (
            self.entries[0..entries],
        ) |*entry| {
            s += entry.size();
        }
        s += ((entries + self.restart_interval - 1) / self.restart_interval) * @sizeOf(restartPoint); // restart points
        s += @sizeOf(restartPointCount); // restart point count
        return s;
    }
    fn writeRestartPoints(self: DataBlock, wr: *std.Io.Writer, entries: usize) !void {
        var _offset: usize = 0;
        for (0..entries) |i| {
            if (i % self.restart_interval == 0) {
                try writeInt(usize, wr, _offset);
            }
            _offset += self.entries[i].size();
        }
        try writeInt(restartPointCount, wr, @intCast((entries + self.restart_interval - 1) / self.restart_interval)); // restart point count
    }
    fn compressKeys(self: *DataBlock) usize {
        var rawPreviousKey: []u8 = undefined;
        var i: usize = 0;
        var _size: usize = 0;
        while (i < self.entries.len) : (i += 1) {
            if (_size > defaultDataBlockSize) {
                break; // Stop compressing entries if the block size limit is exceeded
            }
            if (i % self.restart_interval == 0) {
                self.entries[i].sharedKeyLen = 0;
                self.entries[i].unshreadKeyLen = @intCast(self.entries[i].key.len);
            } else {
                const l = @min(self.entries[i].key.len, rawPreviousKey.len);
                var j: usize = 0;
                while (j < l and self.entries[i].key[j] == rawPreviousKey[j]) : (j += 1) {
                    self.entries[i].sharedKeyLen = @intCast(j + 1);
                    self.entries[i].unshreadKeyLen = @intCast(self.entries[i].key.len - (j + 1));
                }
            }
            _size = self.size(i + 1);
            rawPreviousKey = @constCast(self.entries[i].key);
        }
        return i; // Return the number of entries that were compressed (and can fit in the block)
    }
};
pub const DataEntry = struct {
    pub const lenSharedKey = u16;
    pub const lenUnsharedKey = u16;
    pub const lenValue = u32;
    pub const metaInfo = u64;
    sharedKeyLen: lenSharedKey,
    unshreadKeyLen: lenUnsharedKey,
    valuelen: lenValue,
    seqnum: u56,
    entryType: u8,
    key: []const u8,
    value: []const u8,
    pub fn size(self: DataEntry) usize {
        var s: usize = @sizeOf(lenSharedKey) + @sizeOf(lenUnsharedKey);
        s += @sizeOf(lenValue);
        s += @sizeOf(metaInfo);
        s += self.unshreadKeyLen;
        s += self.valuelen;
        return s;
    }
    pub fn writeTo(self: DataEntry, wr: *std.Io.Writer) !void {
        try writeInt(lenSharedKey, wr, self.sharedKeyLen);
        try writeInt(lenUnsharedKey, wr, self.unshreadKeyLen);
        try writeInt(lenValue, wr, self.valuelen);
        var meta: metaInfo = 0;
        meta |= (self.seqnum << 8);
        meta |= self.entryType;
        try writeInt(metaInfo, wr, meta);
        _ = try wr.write(self.key[self.sharedKeyLen..]);
        _ = try wr.write(self.value);
    }

    pub fn readFrom(self: *DataEntry, rd: *std.Io.Reader) !void {
        try readInt(u16, rd, &self.sharedKeyLen);
        try readInt(u16, rd, &self.unshreadKeyLen);
        try readInt(u32, rd, &self.valuelen);
        var meta: u64 = 0;
        try readInt(u64, rd, &meta);
        self.seqnum = meta >> 8;
        self.entryType = @intCast(meta & 0xFF);
        self.key = rd.take(self.unshreadKeyLen);
        self.value = rd.take(self.valuelen);
    }
};

pub const IndexEntry = DataEntry;
// IndexBlock: [Index_1][Index_2]...[Index_3][RestartPoint1][RestartPoint2]...[RestartPointM]
pub const IndexBlock = DataBlock;

const BlockTraverser = struct {
    it: IndexTraverser,
    pub fn init(buf: []u8) BlockTraverser {
        return .{ .it = IndexTraverser.init(buf) };
    }
    pub fn getRestartPointsCount(self: BlockTraverser) !DataBlock.restartPointCount {
        return try self.getRestartPointsCount();
    }
    pub fn readRestartPoints(self: BlockTraverser, dest: []DataBlock.restartPoint) !void {
        try self.it.readRestartPoints(dest);
    }
    pub fn restartPointsPos(self: BlockTraverser, ptsLen: usize) usize {
        const len = self.it.buf.len;
        return len - (ptsLen * @sizeOf(DataBlock.restartPoint)) - @sizeOf(DataBlock.restartPointCount);
    }
    pub fn searchKey(self: BlockTraverser, pts: []DataBlock.restartPoint, key: []u8, entry: *DataEntry) !void {
        const tup = try self.it.binarySearch(pts, key, entry);
        const ord = tup.ord;
        const mid = tup.offset;
        const restartPtPos = self.restartPointsPos(pts.len);
        if (ord == .lt and mid > 0) {
            // Start from mid -1
            ord = self.findExactMatch(pts[mid - 1], restartPtPos, key, entry);
        } else if (ord == .gt) {
            // start from mid only
            ord = self.findExactMatch(pts[mid], restartPtPos, key, entry);
        }
        if (ord == .eq) return else Err.NotFound;
    }
    fn findExactMatch(self: BlockTraverser, offset: usize, restartPtPos: usize, key: []u8, entry: *DataEntry) !std.math.Order {
        var rd = std.Io.Reader.fixed(self.it.buf);
        rd.discardAll(offset);
        var i: i64 = 0;
        var prevKeySharedLen: [defaultRestartInterval]usize = undefined;
        var prevUnsharedKeys: [defaultRestartInterval][]u8 = undefined;
        while (i < defaultRestartInterval and rd.seek < restartPtPos) : (i += 1) {
            try entry.readFrom(&rd);
            prevUnsharedKeys[i] = entry.key;
            prevKeySharedLen[i] = entry.sharedKeyLen;
            var j: i64 = i;
            while (j >= 0 and prevKeySharedLen[j] > 0) : (j -= 1) {}
            const ord = fullKeyMatch(key, prevUnsharedKeys[j..(i + 1)]);
            if (ord == .gt) continue else return ord;
        }
        return .gt;
    }

    fn fullKeyMatch(key: []u8, prevUnsharedKeys: [][]u8) std.math.Order {
        var i = 0;
        var j = 0;
        var ord: std.math.Order = undefined;
        while (i < prevUnsharedKeys.len) : (i += 1) {
            const end = @min(key.len, j + prevUnsharedKeys[i].len);
            const start = @min(key.len - 1, j);
            ord = std.mem.order(key[start..end], prevUnsharedKeys[i]);
            j += prevUnsharedKeys[i].len;
            if (ord != .eq) return ord else {
                continue;
            }
        }
        return ord;
    }
};

const IndexTraverser = struct {
    buf: []const u8,
    const tuple = struct {
        ord: std.math.Order,
        offset: usize,
    };
    pub fn init(buf: []u8) IndexTraverser {
        return .{ .buf = buf };
    }
    pub fn getRestartPointsCount(self: IndexTraverser) !IndexBlock.restartPointCount {
        var rd = std.Io.Reader.fixed(self.buf);
        try rd.discardAll(self.buf.len - @sizeOf(IndexBlock.restartPointCount));
        const count = try rd.takeInt(IndexBlock.restartPointCount, defaultEndian);
        return count;
    }
    pub fn readRestartPoints(self: IndexTraverser, dest: []IndexBlock.restartPoint) !void {
        var rd = std.Io.Reader.fixed(self.buf);
        try rd.discardAll(self.buf.len - @sizeOf(IndexBlock.restartPointCount) - (dest.len * @sizeOf(IndexBlock.restartPoint)));
        for (dest) |*p| {
            p.* = try rd.takeInt(IndexBlock.restartPoint, defaultEndian);
        }
    }
    fn binarySearch(self: IndexTraverser, pts: []IndexBlock.restartPoint, key: []u8, indexEntry: *IndexEntry) !tuple {
        var start = 0;
        var end = pts.len;
        var mid: usize = 0;
        var ord: std.math.Order = undefined;
        while (start < end) {
            mid = (start + end) / 2;
            try decodeEntry(self.buf, pts[mid], &indexEntry);
            ord = cmpKey(key, &indexEntry);
            if (ord == .lt) {
                end = mid;
            } else if (ord == .gt) {
                start = mid;
            } else {
                break;
            }
        }
        return .{ .ord = ord, .offset = mid };
    }

    pub fn searchKey(self: IndexTraverser, pts: []IndexBlock.restartPoint, key: []u8) !IndexBlock.offset {
        var indexEntry: IndexEntry = undefined;
        const t = try self.binarySearch(pts, key, &indexEntry);
        const ord = t.ord;
        const mid = t.offset;
        var lastEntry: IndexEntry = undefined;
        if (ord == .lt and mid > 0) {
            // key is less than keyAt(mid)
            // previous block (mid-1) could have the key
            try decodeEntry(self.buf, pts[mid - 1], &indexEntry);
            try decodeEntry(indexEntry.value, 0, &lastEntry);
            return std.mem.readInt(DataBlock.offset, lastEntry.value, defaultEndian);
        }
        if (ord == .gt) {
            try decodeEntry(indexEntry.value, 0, &lastEntry);
            ord = cmpKey(key, &lastEntry);
            ord = self.cmpEndKey(pts, key, mid);
            if (ord == .lt) {
                return std.mem.readInt(DataBlock.offset, lastEntry.value, defaultEndian);
            }
        }
        return Err.NotFound;
    }
    fn cmpKey(key: []u8, indexEntry: *IndexEntry) std.math.Order {
        const target: entryKey = .{ .key = key, .seq = std.math.maxInt(u64) };
        const suspect: entryKey = .{ .key = indexEntry.key, .seq = @intCast(indexEntry.seqnum) };
        return cmpFn(target, suspect);
    }
    fn decodeEntry(buf: []u8, skip: usize, indexEntry: *IndexEntry) void {
        var rd = std.Io.Reader.fixed(buf);
        try rd.discardAll(skip);
        try indexEntry.readFrom(&rd);
    }
};

const entryKey = struct {
    key: []u8,
    seq: u64,
};
fn cmpFn(a: entryKey, b: entryKey) std.math.Order {
    const ord = std.mem.order(u8, a.key, b.key);
    return if (ord == .eq) std.math.order(b.seq, a.seq) else ord;
}
