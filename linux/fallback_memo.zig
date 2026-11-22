//! What earlier best-match queries already decide about later ones.
//!
//! A best match picks, from a set of candidates walked in a fixed order, the
//! first one no other candidate beats, by a ranking that depends on each
//! candidate alone. So once candidate `w` has won over a set `C`, it also wins
//! over every subset of `C` that contains it: a candidate earlier in the walk
//! was strictly worse, and a later one was no better. The same holds for the
//! union of all the sets `w` has won over.
//!
//! The memo keeps that union per winner, as a bitset over the candidates'
//! walk order. A query whose candidates all lie inside one winner's union,
//! and include the winner, is answered without ranking anything. Every answer
//! it gives is the one the full match would give; what it cannot decide it
//! leaves to the caller.

const std = @import("std");

/// Winners remembered. A query that no remembered winner decides is still
/// answered correctly by the caller's full match; it is just not shortened.
/// One winner per script is typical, and a text mixing two dozen scripts
/// reached fourteen.
pub const max_winners = 32;

pub const Memo = struct {
    /// u64 words per candidate set: `(candidates + 63) / 64`.
    words: usize,
    /// `winner_len` unions, `words` each, in the order of `winners`.
    beaten: []u64,
    winners: [max_winners]u32 = undefined,
    winner_len: usize = 0,

    pub fn init(alloc: std.mem.Allocator, candidates: usize) !Memo {
        const words = (candidates + 63) / 64;
        const beaten = try alloc.alloc(u64, words * max_winners);
        @memset(beaten, 0);
        return .{ .words = words, .beaten = beaten };
    }

    pub fn deinit(self: *Memo, alloc: std.mem.Allocator) void {
        alloc.free(self.beaten);
    }

    /// The best match among `set`, when an earlier result decides it.
    /// Pre: `set.len == words`.
    pub fn lookup(self: *const Memo, set: []const u64) ?u32 {
        std.debug.assert(set.len == self.words);
        for (self.winners[0..self.winner_len], 0..) |w, i| {
            if (!has(set, w)) continue;
            const beaten = self.beaten[i * self.words ..][0..self.words];
            const inside = for (set, beaten) |s, b| {
                if (s & ~b != 0) break false;
            } else true;
            if (inside) return w;
        }
        return null;
    }

    /// `winner` was the best match among `set`.
    /// Pre: `set.len == words`, and `set` contains `winner`.
    pub fn record(self: *Memo, winner: u32, set: []const u64) void {
        std.debug.assert(set.len == self.words);
        std.debug.assert(has(set, winner));
        const i = for (self.winners[0..self.winner_len], 0..) |w, i| {
            if (w == winner) break i;
        } else blk: {
            if (self.winner_len == max_winners) return;
            self.winners[self.winner_len] = winner;
            self.winner_len += 1;
            break :blk self.winner_len - 1;
        };
        for (self.beaten[i * self.words ..][0..self.words], set) |*b, s| b.* |= s;
    }
};

pub fn has(set: []const u64, candidate: u32) bool {
    return set[candidate / 64] & (@as(u64, 1) << @intCast(candidate % 64)) != 0;
}

pub fn add(set: []u64, candidate: u32) void {
    set[candidate / 64] |= @as(u64, 1) << @intCast(candidate % 64);
}

const testing = std.testing;

fn setOf(buf: []u64, members: []const u32) []const u64 {
    @memset(buf, 0);
    for (members) |m| add(buf, m);
    return buf;
}

test "a winner decides every subset of what it has beaten that contains it" {
    var memo = try Memo.init(testing.allocator, 130);
    defer memo.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), memo.words);
    var buf: [3]u64 = undefined;

    // Nothing is known yet.
    try testing.expectEqual(@as(?u32, null), memo.lookup(setOf(&buf, &.{ 3, 5 })));

    memo.record(3, setOf(&buf, &.{ 1, 3, 5, 129 }));
    try testing.expectEqual(@as(?u32, 3), memo.lookup(setOf(&buf, &.{ 3, 5 })));
    try testing.expectEqual(@as(?u32, 3), memo.lookup(setOf(&buf, &.{3})));
    try testing.expectEqual(@as(?u32, 3), memo.lookup(setOf(&buf, &.{ 1, 3, 129 })));
    // A candidate it never met may beat it.
    try testing.expectEqual(@as(?u32, null), memo.lookup(setOf(&buf, &.{ 3, 7 })));
    // Without the winner, its wins say nothing about which of the rest is best.
    try testing.expectEqual(@as(?u32, null), memo.lookup(setOf(&buf, &.{ 1, 5 })));
}

test "what a winner has beaten grows with each set it wins" {
    var memo = try Memo.init(testing.allocator, 64);
    defer memo.deinit(testing.allocator);
    var buf: [1]u64 = undefined;
    memo.record(3, setOf(&buf, &.{ 3, 5 }));
    memo.record(3, setOf(&buf, &.{ 3, 7 }));
    // Neither win alone covers this set; together they do.
    try testing.expectEqual(@as(?u32, 3), memo.lookup(setOf(&buf, &.{ 3, 5, 7 })));
    try testing.expectEqual(@as(usize, 1), memo.winner_len);
}

test "two winners each decide their own sets" {
    var memo = try Memo.init(testing.allocator, 64);
    defer memo.deinit(testing.allocator);
    var buf: [1]u64 = undefined;
    memo.record(2, setOf(&buf, &.{ 2, 9 }));
    memo.record(4, setOf(&buf, &.{ 4, 9, 11 }));
    try testing.expectEqual(@as(?u32, 2), memo.lookup(setOf(&buf, &.{ 2, 9 })));
    try testing.expectEqual(@as(?u32, 4), memo.lookup(setOf(&buf, &.{ 4, 11 })));
    // 2 and 4 never met: no result ranks them.
    try testing.expectEqual(@as(?u32, null), memo.lookup(setOf(&buf, &.{ 2, 4, 9 })));
}

test "a full memo stops learning new winners and keeps answering" {
    var memo = try Memo.init(testing.allocator, 64);
    defer memo.deinit(testing.allocator);
    var buf: [1]u64 = undefined;
    for (0..max_winners) |i| memo.record(@intCast(i), setOf(&buf, &.{ @intCast(i), 40 }));
    memo.record(50, setOf(&buf, &.{ 50, 51 }));
    try testing.expectEqual(@as(usize, max_winners), memo.winner_len);
    try testing.expectEqual(@as(?u32, null), memo.lookup(setOf(&buf, &.{ 50, 51 })));
    try testing.expectEqual(@as(?u32, 5), memo.lookup(setOf(&buf, &.{ 5, 40 })));
}
