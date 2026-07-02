const std = @import("std");
const Allocator = std.mem.Allocator;
const maxLevel = 32;
pub const Err = error{ Duplicate, NotFound };
pub const Cmp = std.math.Order;
const SkipList = @This();
pub fn List(comptime keyT: type, comptime valT: type, comptime cmpFn: fn (keyT, keyT) Cmp) type {
    const Node = struct {
        key: keyT,
        val: valT,
        succ: []?*@This(),
        fn findInsertablePos(self: *@This(), routeTaken: []?*@This(), key: keyT) !void {
            const lastSuccessorIndex = self.succ.len - 1;
            routeTaken[lastSuccessorIndex] = self;
            var i: usize = 0;
            while (i < self.succ.len) : (i += 1) {
                routeTaken[lastSuccessorIndex - i] = self;
                if (self.succ[lastSuccessorIndex - i]) |suc| {
                    const next_val = suc.key;
                    const cmp = cmpFn(next_val, key);
                    if (cmp == .lt) {
                        return try suc.findInsertablePos(routeTaken, key);
                    } else if (cmp == .eq) {
                        return Err.Duplicate;
                    }
                }
            }
        }
        fn findRemovablePos(self: *@This(), routeTaken: []?*@This(), key: keyT) !void {
            const lastSuccessorIndex = self.succ.len - 1;
            routeTaken[lastSuccessorIndex] = self;
            var i: usize = 0;
            while (i < self.succ.len) : (i += 1) {
                routeTaken[lastSuccessorIndex - i] = self;
                if (self.succ[lastSuccessorIndex - i]) |suc| {
                    const next_val = suc.key;
                    if (cmpFn(next_val, key) == .lt) {
                        return try suc.findRemovablePos(routeTaken, key);
                    }
                }
            }
            if (cmpFn(routeTaken[0].?.succ[0].?.key, key) != .eq) {
                return Err.NotFound;
            }
        }

        fn findNode(self: *@This(), key: keyT, val: *valT) !void {
            const lastSuccessorIndex = self.succ.len - 1;
            var i: usize = 0;
            while (i < self.succ.len) : (i += 1) {
                if (self.succ[lastSuccessorIndex - i]) |suc| {
                    const next_val = suc.key;
                    const cmp = cmpFn(next_val, key);
                    if (cmp == .lt) {
                        return try suc.findNode(key, val);
                    } else if (cmp == .eq) {
                        val.* = suc.val;
                        return;
                    }
                }
            }
            return Err.NotFound;
        }
        fn findNodeOrClosestPredecessor(self: *@This(), key: keyT) !*@This() {
            const lastSuccessorIndex = self.succ.len - 1;
            var i: usize = 0;
            while (i < self.succ.len) : (i += 1) {
                if (self.succ[lastSuccessorIndex - i]) |suc| {
                    const next_val = suc.key;
                    const cmp = cmpFn(next_val, key);
                    if (cmp == .lt) {
                        return try suc.findNodeOrClosestPredecessor(key);
                    } else if (cmp == .eq) {
                        return suc;
                    }
                }
            }
            return self; // As the recursion goes down, the self.key is the closest predecessor to the key if it doesn't exist in the list
        }

        fn findNodeOrClosestSuccessor(self: *@This(), key: keyT) !*@This() {
            const lastSuccessorIndex = self.succ.len - 1;
            var i: usize = 0;
            var res: ?*@This() = null;
            while (i < self.succ.len) : (i += 1) {
                if (self.succ[lastSuccessorIndex - i]) |suc| {
                    const next_val = suc.key;
                    const cmp = cmpFn(next_val, key);

                    if (cmp == .lt) {
                        return try suc.findNodeOrClosestSuccessor(key);
                    } else if (cmp == .eq) {
                        return suc;
                    }
                    res = suc;
                }
            }
            if (res) |r| {
                return r;
            }
            return Err.NotFound;
        }

        fn init(allocator: Allocator, lvl: u8, key: keyT, val: valT) !*@This() {
            var node = try allocator.create(@This());
            node.key = key;
            node.val = val;
            node.succ = try allocator.alloc(?*@This(), lvl);
            @memset(node.succ, null);
            return node;
        }
        fn initHeader(allocator: Allocator) !*@This() {
            var node = try allocator.create(@This());
            node.succ = try allocator.alloc(?*@This(), 1);
            @memset(node.succ, null);
            return node;
        }
    };

    const Iterator = struct {
        const Self = @This();
        nextNode: ?*Node,
        pub fn next(self: *Self, key: *keyT, val: *valT) bool {
            if (self.nextNode) |node| {
                self.nextNode = node.succ[0];
                key.* = node.key;
                val.* = node.val;
                return true;
            }
            return false;
        }
        fn init(head: *Node) Self {
            return Self{
                .nextNode = head.succ[0],
            };
        }
    };

    return struct {
        const Self = @This();
        head: *Node,
        count: u16 = 0,
        random: std.Random,
        traversePath: []?*Node,
        pub fn init(allocator: Allocator, rng: std.Random) !Self {
            var x: Self = .{
                .random = rng,
                .head = try Node.initHeader(allocator),
                .traversePath = try allocator.alloc(?*Node, 1),
            };
            x.traversePath[0] = null;
            return x;
        }
        fn insertAfter(self: *Self, allocator: Allocator, key: keyT, val: valT, routeTaken: []?*Node) !void {
            const lvl = randomLevels(self.random);
            const newNode = try Node.init(allocator, lvl, key, val);
            if (lvl > self.head.succ.len) {
                const pl = self.head.succ.len;
                self.head.succ = try allocator.realloc(self.head.succ, lvl);
                @memset(self.head.succ[pl..], newNode);
            }
            try snitchPtrsAfterInsertion(lvl, newNode, routeTaken);
        }
        fn removeAfter(_: *Self, allocator: Allocator, routeTaken: []?*Node, val: *valT) void {
            const targetNode = routeTaken[0].?.succ[0].?;
            snitchPtrAfterRemoval(targetNode, routeTaken);
            defer allocator.destroy(targetNode);
            defer allocator.free(targetNode.succ);
            val.* = targetNode.val;
        }
        inline fn incLen(self: *Self) void {
            self.count += 1;
        }
        inline fn decrLen(self: *Self) void {
            self.count -= 1;
        }
        pub inline fn len(self: Self) u16 {
            return self.count;
        }
        fn resetAndResetTraversePath(self: *Self, allocator: Allocator) !void {
            if (self.traversePath.len < self.head.succ.len) {
                self.traversePath = try allocator.realloc(self.traversePath, self.head.succ.len);
            }
            self.resetTraversePath();
        }
        inline fn resetTraversePath(self: *Self) void {
            @memset(self.traversePath, null);
        }

        pub fn add(self: *Self, allocator: Allocator, key: keyT, val: valT) !void {
            try self.resetAndResetTraversePath(allocator);
            try self.head.findInsertablePos(self.traversePath, key);
            try self.insertAfter(allocator, key, val, self.traversePath);
            self.incLen();
        }
        pub fn remove(self: *Self, allocator: Allocator, key: keyT, val: *valT) !void {
            if (self.len() == 0) {
                return Err.NotFound;
            }
            try self.resetAndResetTraversePath(allocator);
            try self.head.findRemovablePos(self.traversePath, key);
            self.removeAfter(allocator, self.traversePath, val);
            self.decrLen();
        }
        pub fn get(self: *Self, key: keyT, val: *valT) !void {
            if (self.len() == 0) {
                return Err.NotFound;
            }
            return try self.head.findNode(key, val);
        }
        pub fn getOrClosestPredecessor(self: *Self, key: keyT, fkey: *keyT, val: *valT) !void {
            if (self.len() == 0) {
                return Err.NotFound;
            }
            const node = try self.head.findNodeOrClosestPredecessor(key);
            if (node == self.head) {
                return Err.NotFound;
            }
            fkey.* = node.key;
            val.* = node.val;
        }
        pub fn getOrClosestSuccessor(self: *Self, key: keyT, fkey: *keyT, val: *valT) !void {
            if (self.len() == 0) {
                return Err.NotFound;
            }
            const node = try self.head.findNodeOrClosestSuccessor(key);
            fkey.* = node.key;
            val.* = node.val;
        }
        pub fn iterator(self: Self) Iterator {
            return Iterator.init(self.head);
        }
        fn list(self: *Self, allocator: Allocator) ![]valT {
            const l = try allocator.alloc(valT, self.count);
            var i: u16 = 0;
            var iter = self.iterator();
            var key: keyT = undefined;
            var val: valT = undefined;
            while (iter.next(&key, &val)) {
                l[i] = val;
                i += 1;
            }
            return l;
        }
        fn snitchPtrAfterRemoval(node: *Node, routeTaken: []?*Node) void {
            // Snitch the pointer of traversed predecessor to the newNode
            const lvl = node.succ.len;
            for (0..lvl) |i| {
                routeTaken[i].?.succ[i] = node.succ[i];
            }
        }
        fn snitchPtrsAfterInsertion(new_node_lvl: usize, newNode: *Node, traversePath: []?*Node) !void {
            // Snitch the pointer of traversed predecessor to the newNode
            const min_len = @min(new_node_lvl, traversePath.len);
            for (0..min_len) |i| {
                newNode.succ[i] = traversePath[i].?.succ[i];
                traversePath[i].?.succ[i] = newNode;
            }
        }
        pub fn deinit(self: *Self, allocator: Allocator) void {
            var n: ?*Node = self.head;
            while (n != null) {
                const d = n.?;
                n = d.succ[0];
                allocator.free(d.succ);
                allocator.destroy(d);
            }
            allocator.free(self.traversePath);
        }
    };
}
fn randomLevels(rd: std.Random) u8 {
    var lvl: u8 = 1;
    while (rd.boolean() and lvl < maxLevel) {
        lvl += 1;
    }
    return lvl;
}
fn _cmpFn(a: i64, b: i64) Cmp {
    if (a < b) {
        return .lt;
    } else if (a > b) {
        return .gt;
    } else {
        return .eq;
    }
}
test "only_insert" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    const t = List(i64, i64, _cmpFn);
    var sl = try t.init(gpa, rng);
    defer sl.deinit(gpa);
    try sl.add(gpa, 5, 5);
    try sl.add(gpa, 2, 2);
    try sl.add(gpa, 9, 9);
    try sl.add(gpa, 8, 8);
    try sl.add(gpa, 1, 1);
    try sl.add(gpa, 3, 3);
    try sl.add(gpa, 6, 6);
    try sl.add(gpa, 7, 7);
    try sl.add(gpa, 4, 4);

    const result = try sl.list(gpa);
    defer gpa.free(result);

    try std.testing.expectEqual(@as(u16, 9), sl.len());
    try std.testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, result);
}

test "only_remove" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);
    try sl.add(gpa, 5, 5);
    try sl.add(gpa, 2, 2);
    try sl.add(gpa, 9, 9);
    try sl.add(gpa, 8, 8);
    try sl.add(gpa, 1, 1);
    try sl.add(gpa, 3, 3);
    try sl.add(gpa, 6, 6);
    try sl.add(gpa, 7, 7);
    try sl.add(gpa, 4, 4);
    const result = try sl.list(gpa);
    defer gpa.free(result);

    try std.testing.expectEqual(@as(u16, 9), sl.len());
    try std.testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, result);
    var val: i64 = undefined;
    try sl.remove(gpa, 1, &val);
    try sl.remove(gpa, 5, &val);
    try sl.remove(gpa, 9, &val);

    const result1 = try sl.list(gpa);
    defer gpa.free(result1);

    try std.testing.expectEqual(@as(u16, 6), sl.len());
    try std.testing.expectEqualSlices(i64, &[_]i64{ 2, 3, 4, 6, 7, 8 }, result1);
}

test "insert single element" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 42, 100);

    try std.testing.expectEqual(@as(u16, 1), sl.len());
    var val: i64 = undefined;
    try sl.get(42, &val);
    try std.testing.expectEqual(@as(i64, 100), val);
}

test "insert duplicate returns error" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 5, 5);
    const result = sl.add(gpa, 5, 10);

    try std.testing.expectError(Err.Duplicate, result);
    try std.testing.expectEqual(@as(u16, 1), sl.len());
}

test "insert maintains sorted order" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 50, 50);
    try sl.add(gpa, 10, 10);
    try sl.add(gpa, 90, 90);
    try sl.add(gpa, 30, 30);
    try sl.add(gpa, 70, 70);

    const result = try sl.list(gpa);
    defer gpa.free(result);

    try std.testing.expectEqualSlices(i64, &[_]i64{ 10, 30, 50, 70, 90 }, result);
}

test "remove from empty list returns error" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    var val: i64 = undefined;
    const result = sl.remove(gpa, 5, &val);

    try std.testing.expectError(Err.NotFound, result);
}

test "remove non-existent key returns error" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 1, 1);
    try sl.add(gpa, 3, 3);

    var val: i64 = undefined;
    const result = sl.remove(gpa, 2, &val);

    try std.testing.expectError(Err.NotFound, result);
}

test "remove returns correct value" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 10, 100);
    try sl.add(gpa, 20, 200);
    try sl.add(gpa, 30, 300);

    var val: i64 = undefined;
    try sl.remove(gpa, 20, &val);

    try std.testing.expectEqual(@as(i64, 200), val);
    try std.testing.expectEqual(@as(u16, 2), sl.len());
}

test "remove all elements" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 1, 1);
    try sl.add(gpa, 2, 2);
    try sl.add(gpa, 3, 3);

    var val: i64 = undefined;
    try sl.remove(gpa, 2, &val);
    try sl.remove(gpa, 1, &val);
    try sl.remove(gpa, 3, &val);

    try std.testing.expectEqual(@as(u16, 0), sl.len());
}

test "get from empty list returns error" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    var val: i64 = undefined;
    const result = sl.get(5, &val);

    try std.testing.expectError(Err.NotFound, result);
}

test "get non-existent key returns error" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 1, 10);
    try sl.add(gpa, 3, 30);

    var val: i64 = undefined;
    const result = sl.get(2, &val);

    try std.testing.expectError(Err.NotFound, result);
}

test "get returns correct value" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 10, 100);
    try sl.add(gpa, 20, 200);
    try sl.add(gpa, 30, 300);

    var val: i64 = undefined;
    try sl.get(20, &val);
    try std.testing.expectEqual(@as(i64, 200), val);

    try sl.get(10, &val);
    try std.testing.expectEqual(@as(i64, 100), val);

    try sl.get(30, &val);
    try std.testing.expectEqual(@as(i64, 300), val);
}

test "get after remove returns error" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 5, 50);

    var val: i64 = undefined;
    try sl.remove(gpa, 5, &val);

    const result = sl.get(5, &val);
    try std.testing.expectError(Err.NotFound, result);
}

test "insert remove insert same key" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 5, 50);

    var val: i64 = undefined;
    try sl.remove(gpa, 5, &val);
    try std.testing.expectEqual(@as(i64, 50), val);

    try sl.add(gpa, 5, 500);
    try sl.get(5, &val);
    try std.testing.expectEqual(@as(i64, 500), val);
}

test "large number of insertions" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    const count: i64 = 100;
    var i: i64 = count;
    while (i > 0) : (i -= 1) {
        try sl.add(gpa, i, i * 10);
    }

    try std.testing.expectEqual(@as(u16, @intCast(count)), sl.len());

    var val: i64 = undefined;
    try sl.get(50, &val);
    try std.testing.expectEqual(@as(i64, 500), val);

    try sl.get(1, &val);
    try std.testing.expectEqual(@as(i64, 10), val);

    try sl.get(100, &val);
    try std.testing.expectEqual(@as(i64, 1000), val);
}

test "getOrClosestPredecessor returns exact match" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 10, 100);
    try sl.add(gpa, 20, 200);
    try sl.add(gpa, 30, 300);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    try sl.getOrClosestPredecessor(20, &fkey, &val);

    try std.testing.expectEqual(@as(i64, 20), fkey);
    try std.testing.expectEqual(@as(i64, 200), val);
}

test "getOrClosestPredecessor returns closest predecessor" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 10, 100);
    try sl.add(gpa, 20, 200);
    try sl.add(gpa, 40, 400);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    try sl.getOrClosestPredecessor(30, &fkey, &val);

    try std.testing.expectEqual(@as(i64, 20), fkey);
    try std.testing.expectEqual(@as(i64, 200), val);
}

test "getOrClosestPredecessor on empty list returns error" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    const result = sl.getOrClosestPredecessor(5, &fkey, &val);

    try std.testing.expectError(Err.NotFound, result);
}

test "getOrClosestPredecessor with key less than all elements" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 50, 500);
    try sl.add(gpa, 60, 600);

    var fkey: i64 = undefined;
    var val: i64 = undefined;

    try std.testing.expectError(Err.NotFound, sl.getOrClosestPredecessor(30, &fkey, &val));
}

test "getOrClosestPredecessor with multiple predecessors" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 5, 50);
    try sl.add(gpa, 15, 150);
    try sl.add(gpa, 25, 250);
    try sl.add(gpa, 35, 350);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    try sl.getOrClosestPredecessor(32, &fkey, &val);

    try std.testing.expectEqual(@as(i64, 25), fkey);
    try std.testing.expectEqual(@as(i64, 250), val);
}

test "getOrClosestSuccessor returns exact match" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try SkipList.List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 10, 100);
    try sl.add(gpa, 20, 200);
    try sl.add(gpa, 30, 300);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    try sl.getOrClosestSuccessor(20, &fkey, &val);

    try std.testing.expectEqual(@as(i64, 20), fkey);
    try std.testing.expectEqual(@as(i64, 200), val);
}

test "getOrClosestSuccessor returns closest successor" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try SkipList.List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 10, 100);
    try sl.add(gpa, 20, 200);
    try sl.add(gpa, 40, 400);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    try sl.getOrClosestSuccessor(25, &fkey, &val);

    try std.testing.expectEqual(@as(i64, 40), fkey);
    try std.testing.expectEqual(@as(i64, 400), val);
}

test "getOrClosestSuccessor on empty list returns error" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try SkipList.List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    const result = sl.getOrClosestSuccessor(5, &fkey, &val);

    try std.testing.expectError(Err.NotFound, result);
}

test "getOrClosestSuccessor with key greater than all elements returns error" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try SkipList.List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 10, 100);
    try sl.add(gpa, 20, 200);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    const result = sl.getOrClosestSuccessor(30, &fkey, &val);

    try std.testing.expectError(Err.NotFound, result);
}

test "getOrClosestSuccessor with key less than all elements returns first element" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try SkipList.List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 50, 500);
    try sl.add(gpa, 60, 600);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    try sl.getOrClosestSuccessor(30, &fkey, &val);

    try std.testing.expectEqual(@as(i64, 50), fkey);
    try std.testing.expectEqual(@as(i64, 500), val);
}

test "getOrClosestSuccessor with multiple successors returns closest" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try SkipList.List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 5, 50);
    try sl.add(gpa, 15, 150);
    try sl.add(gpa, 25, 250);
    try sl.add(gpa, 35, 350);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    try sl.getOrClosestSuccessor(18, &fkey, &val);

    try std.testing.expectEqual(@as(i64, 25), fkey);
    try std.testing.expectEqual(@as(i64, 250), val);
}

test "getOrClosestSuccessor with single element exact match" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try SkipList.List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 42, 420);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    try sl.getOrClosestSuccessor(42, &fkey, &val);

    try std.testing.expectEqual(@as(i64, 42), fkey);
    try std.testing.expectEqual(@as(i64, 420), val);
}

test "getOrClosestSuccessor with single element as successor" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try SkipList.List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 42, 420);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    try sl.getOrClosestSuccessor(10, &fkey, &val);

    try std.testing.expectEqual(@as(i64, 42), fkey);
    try std.testing.expectEqual(@as(i64, 420), val);
}

test "getOrClosestSuccessor boundary cases" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try SkipList.List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 10, 100);
    try sl.add(gpa, 20, 200);
    try sl.add(gpa, 30, 300);

    var fkey: i64 = undefined;
    var val: i64 = undefined;

    // Key just before first element
    try sl.getOrClosestSuccessor(9, &fkey, &val);
    try std.testing.expectEqual(@as(i64, 10), fkey);
    try std.testing.expectEqual(@as(i64, 100), val);

    // Key just after first element
    try sl.getOrClosestSuccessor(11, &fkey, &val);
    try std.testing.expectEqual(@as(i64, 20), fkey);
    try std.testing.expectEqual(@as(i64, 200), val);

    // Key just before last element
    try sl.getOrClosestSuccessor(29, &fkey, &val);
    try std.testing.expectEqual(@as(i64, 30), fkey);
    try std.testing.expectEqual(@as(i64, 300), val);
}

test "getOrClosestSuccessor after removal" {
    const gpa = std.testing.allocator;
    const seed: u64 = @intCast(std.testing.random_seed);
    var xrng = std.Random.Xoroshiro128.init(seed);
    const rng = xrng.random();
    var sl = try SkipList.List(i64, i64, _cmpFn).init(gpa, rng);
    defer sl.deinit(gpa);

    try sl.add(gpa, 10, 100);
    try sl.add(gpa, 20, 200);
    try sl.add(gpa, 30, 300);

    var removed_val: i64 = undefined;
    try sl.remove(gpa, 20, &removed_val);

    var fkey: i64 = undefined;
    var val: i64 = undefined;
    try sl.getOrClosestSuccessor(15, &fkey, &val);

    try std.testing.expectEqual(@as(i64, 30), fkey);
    try std.testing.expectEqual(@as(i64, 300), val);
}
