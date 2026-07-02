const std = @import("std");
const Skiplist = @import("SkipList.zig");
const ErrSkiplist = Skiplist.Err;
const Allocator = std.mem.Allocator;
const Self = @This();
const max64 = std.math.maxInt(u64);
const SortedList = Skiplist.List(EntryKey, EntryVal, cmpFn);
pub const Err = error{
    NotFound,
};

_size: usize,
table: SortedList,

pub fn init(allocator: Allocator, rng: std.Random) !Self {
    return Self{
        ._size = 0,
        .table = try SortedList.init(allocator, rng),
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.table.deinit(allocator);
}

pub fn size(self: *Self) usize {
    return self._size;
}
pub fn put(self: *Self, allocator: Allocator, key: []u8, value: []u8, seqNum: u64) !void {
    const entry = EntryVal{
        .tombstone = false,
        .value = value,
    };
    const eKey = EntryKey{
        .key = key,
        .seqNum = seqNum,
    };
    self._size += entry.size() + eKey.size();
    try self.table.add(allocator, eKey, entry);
}
pub fn delete(self: *Self, allocator: Allocator, key: []u8, seqNum: u64) !void {
    const entry = EntryVal{
        .tombstone = true,
    };
    const eKey = EntryKey{
        .key = key,
        .seqNum = seqNum,
    };
    self._size += entry.size() + eKey.size();
    try self.table.add(allocator, eKey, entry);
}
pub fn get(self: *Self, key: []u8) ![]u8 {
    const eKey = EntryKey{
        .key = key,
        .seqNum = max64,
    };
    var val: EntryVal = undefined;
    var fkey: EntryKey = undefined;

    self.table.getOrClosestSuccessor(eKey, &fkey, &val) catch |err| {
        switch (err) {
            ErrSkiplist.NotFound => return Err.NotFound,
            else => return err,
        }
    };
    if (val.tombstone) {
        return Err.NotFound;
    }
    return val.value;
}
fn cmpFn(a: EntryKey, b: EntryKey) std.math.Order {
    const kOrder = std.mem.order(u8, a.key, b.key);
    if (kOrder == .eq) {
        // Descending order for seqNum to ensure that the latest entry is returned for a key during a search,
        // and tombstone entries are correctly handled during flushes to SSTables
        return std.math.order(b.seqNum, a.seqNum);
    }
    return kOrder;
}
pub const EntryVal = struct {
    tombstone: bool = false,
    value: []u8 = undefined,

    fn size(self: EntryVal) usize {
        return self.value.len + @sizeOf(bool); // 1 byte for tombstone
    }
};
pub const EntryKey = struct {
    key: []u8,
    seqNum: u64,
    fn size(self: EntryKey) usize {
        return self.key.len + @sizeOf(u64); // 8 bytes for seqNum
    }
};

const MemTable = @This();

test "put single entry and get" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    const key = "testkey";
    const value = "testvalue";
    try mt.put(gpa, @constCast(key), @constCast(value), 1);
    try mt.put(gpa, @constCast(key), @constCast(value), 0);

    const result = try mt.get(@constCast(key));
    try std.testing.expectEqualStrings(value, result);
}

test "put multiple entries and get" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    try mt.put(gpa, @constCast("key1"), @constCast("value1"), 1);
    try mt.put(gpa, @constCast("key2"), @constCast("value2"), 2);
    try mt.put(gpa, @constCast("key3"), @constCast("value3"), 3);

    try std.testing.expectEqualStrings("value1", try mt.get(@constCast("key1")));
    try std.testing.expectEqualStrings("value2", try mt.get(@constCast("key2")));
    try std.testing.expectEqualStrings("value3", try mt.get(@constCast("key3")));
}

test "get non-existent key returns NotFound" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    const result = mt.get(@constCast("nonexistent"));
    try std.testing.expectError(MemTable.Err.NotFound, result);
}

test "delete marks entry as tombstone" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    try mt.put(gpa, @constCast("key1"), @constCast("value1"), 1);
    try mt.delete(gpa, @constCast("key1"), 2);

    const result = mt.get(@constCast("key1"));
    try std.testing.expectError(MemTable.Err.NotFound, result);
}

test "put same key with higher seqNum returns latest value" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    try mt.put(gpa, @constCast("key1"), @constCast("old_value"), 1);
    try mt.put(gpa, @constCast("key1"), @constCast("new_value"), 2);

    const result = try mt.get(@constCast("key1"));
    try std.testing.expectEqualStrings("new_value", result);
}

test "keys are sorted in ascending order" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    try mt.put(gpa, @constCast("zebra"), @constCast("v1"), 1);
    try mt.put(gpa, @constCast("apple"), @constCast("v2"), 2);
    try mt.put(gpa, @constCast("mango"), @constCast("v3"), 3);
    try mt.put(gpa, @constCast("banana"), @constCast("v4"), 4);

    try std.testing.expectEqualStrings("v2", try mt.get(@constCast("apple")));
    try std.testing.expectEqualStrings("v4", try mt.get(@constCast("banana")));
    try std.testing.expectEqualStrings("v3", try mt.get(@constCast("mango")));
    try std.testing.expectEqualStrings("v1", try mt.get(@constCast("zebra")));
}

test "seqNum descending order for same key" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    try mt.put(gpa, @constCast("key"), @constCast("first"), 100);
    try mt.put(gpa, @constCast("key"), @constCast("second"), 200);
    try mt.put(gpa, @constCast("key"), @constCast("third"), 300);

    const result = try mt.get(@constCast("key"));
    try std.testing.expectEqualStrings("third", result);
}

test "delete then put same key" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    try mt.put(gpa, @constCast("key1"), @constCast("value1"), 1);
    try mt.delete(gpa, @constCast("key1"), 2);
    try mt.put(gpa, @constCast("key1"), @constCast("value2"), 3);

    const result = try mt.get(@constCast("key1"));
    try std.testing.expectEqualStrings("value2", result);
}

test "size increases after put" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    const initial_size = mt.size();
    try mt.put(gpa, @constCast("key1"), @constCast("value1"), 1);
    const after_put_size = mt.size();

    try std.testing.expect(after_put_size > initial_size);
}

test "size increases after delete" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    try mt.put(gpa, @constCast("key1"), @constCast("value1"), 1);
    const before_delete_size = mt.size();
    try mt.delete(gpa, @constCast("key1"), 2);
    const after_delete_size = mt.size();

    try std.testing.expect(after_delete_size > before_delete_size);
}

test "multiple keys with mixed operations" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();

    var mt = try MemTable.init(gpa, rng);
    defer mt.deinit(gpa);

    try mt.put(gpa, @constCast("a"), @constCast("val_a"), 1);
    try mt.put(gpa, @constCast("b"), @constCast("val_b"), 2);
    try mt.put(gpa, @constCast("c"), @constCast("val_c"), 3);
    try mt.delete(gpa, @constCast("b"), 4);
    try mt.put(gpa, @constCast("d"), @constCast("val_d"), 5);

    try std.testing.expectEqualStrings("val_a", try mt.get(@constCast("a")));
    try std.testing.expectError(MemTable.Err.NotFound, mt.get(@constCast("b")));
    try std.testing.expectEqualStrings("val_c", try mt.get(@constCast("c")));
    try std.testing.expectEqualStrings("val_d", try mt.get(@constCast("d")));
}
