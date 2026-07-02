const std = @import("std");
const MemTable = @import("MemTable.zig");
const ioutils = @import("ioutils.zig");
const SSTableData = @import("SSTableData.zig");
const DataBlock = SSTableData.DataBlock;
const DataEntry = SSTableData.DataEntry;
const IndexBlock = SSTableData.IndexBlock;
const IndexEntry = SSTableData.IndexEntry;
const Footer = SSTableData.Footer;
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const defaultIndexBlockRestartInterval = 1; // Restart point every 1 entries in index block
const KeyErr = error{ NotFound, FoundDeleted };
const tombstone: u8 = 1;
const Self = @This();
const SSTable = Self;

pub fn loadIndex(allocator: Allocator, buf: []u8, f: *File) ![]u8 {
    var foo: Footer = undefined;
    try f.seekFromEnd(@sizeOf(foo.indexBlockOffset));
    var ird = f.reader(buf).interface;
    // We are assuming that ird reader and file discriptor are in-sync.
    try foo.readFrom(&ird);
    // Time to load index block
    try f.seekTo(@intCast(foo.indexBlockOffset));
    const blockSize = try DataBlock.readSize(&ird);
    return try ird.readAlloc(allocator, blockSize - @sizeOf(DataBlock.blockSize));
}

pub fn flush(allocator: Allocator, memt: MemTable, wr: *std.Io.Writer) !void {
    const t = memt.table;
    var iter = t.iterator();
    var key: MemTable.EntryKey = undefined;
    var val: MemTable.EntryVal = undefined;
    const dEntries = try allocator.alloc(DataEntry, t.len());
    defer allocator.free(dEntries);
    var i: usize = 0;
    while (iter.next(&key, &val)) : (i += 1) {
        dEntries[i] = DataEntry{
            .sharedKeyLen = 0, // Will be set during compression
            .unshreadKeyLen = @intCast(key.key.len),
            .valuelen = @intCast(val.value.len),
            .seqnum = @intCast(key.seqNum),
            .entryType = if (val.tombstone) tombstone else 0,
            .key = key.key,
            .value = val.value,
        };
    }
    try flushBlocksIndiciesFooter(allocator, dEntries, wr);
}

const Indicies = std.ArrayList(IndexEntry);
fn flushBlocksIndiciesFooter(allocator: Allocator, dEntries: []DataEntry, wr: *std.Io.Writer) !void {
    var i: usize = 0;
    var indicies: Indicies = Indicies.empty;
    var blockOffset: usize = 0;
    while (i < dEntries.len) {
        var block = DataBlock{
            .entries = dEntries[i..],
        };

        const writtenEntries = try block.writeEntries(wr);
        if (writtenEntries == 0) {
            // Done with all the entries
            break;
        }
        const firstEntry = block.entries[0];
        const lastEntry = block.entries[writtenEntries - 1];
        var off: [@sizeOf(usize)]u8 = undefined;
        std.mem.writeInt(usize, &off, blockOffset, ioutils.defaultEndian);
        var lastEntryKey = DataEntry{
            .sharedKeyLen = 0,
            .unshreadKeyLen = @intCast(lastEntry.key.len),
            .valuelen = @intCast(off.len),
            .seqnum = lastEntry.seqnum, // Not used for index entries
            .entryType = lastEntry.entryType,
            .key = lastEntry.key,
            .value = off[0..],
        };
        const lastEntrybuf = try allocator.alloc(u8, lastEntryKey.size());
        defer allocator.free(lastEntrybuf);
        var twr = std.Io.Writer.fixed(lastEntrybuf);
        try lastEntryKey.writeTo(&twr);
        const indexEntry = IndexEntry{
            .sharedKeyLen = 0,
            .unshreadKeyLen = @intCast(firstEntry.key.len),
            .valuelen = @intCast(lastEntryKey.size()),
            .seqnum = firstEntry.seqnum, // Not used for index entries
            .entryType = firstEntry.entryType,
            .key = firstEntry.key,
            .value = lastEntrybuf,
        };
        try indicies.append(allocator, indexEntry);
        blockOffset += block.size(writtenEntries);

        i += writtenEntries; // Move to the next set of entries for the next block
    }
    const indexBlockOffset = blockOffset;
    try flushIndicies(allocator, &indicies, wr);
    try flushFooter(indexBlockOffset, wr);
}

fn flushFooter(indexBlockOffset: usize, wr: *std.Io.Writer) !void {
    var footer = Footer{
        .indexBlockOffset = indexBlockOffset,
    };
    try footer.writeTo(wr);
}

fn flushIndicies(allocator: Allocator, indicies: *Indicies, wr: *std.Io.Writer) !void {
    var indexBlock = IndexBlock{
        .entries = try indicies.toOwnedSlice(allocator),
        .restart_interval = defaultIndexBlockRestartInterval,
    };
    defer allocator.free(indexBlock.entries);
    _ = try indexBlock.writeEntries(wr);
}

test "flush_happy_flow" {
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    const allocator = std.testing.allocator;
    var memt = try MemTable.init(allocator, rng);
    defer memt.deinit(allocator);
    try memt.put(allocator, @constCast("key1"), @constCast("value1"), 1);
    try memt.put(allocator, @constCast("key2"), @constCast("value2"), 2);
    try memt.put(allocator, @constCast("key3"), @constCast("value3"), 3);
    var buf: [1024]u8 = undefined;
    var file = try std.fs.cwd().createFile("/tmp/sstable_test_data", .{});
    defer file.close();
    const wr = file.writer(&buf);
    var iwf = wr.interface;
    try flush(allocator, memt, &iwf);
    try iwf.flush();
    std.debug.assert(iwf.buffered().len == 0);
}
