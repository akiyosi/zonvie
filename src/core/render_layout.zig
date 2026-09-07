const std = @import("std");

/// Physical CPU storage for retained layouts, including replacement overlap.
/// Separate budgets are owned by the core and each frontend.
pub const Budget = struct {
    pub const limit_bytes = 8 * 1024 * 1024;
    live_bytes: std.atomic.Value(usize) = .init(0),

    fn reserve(self: *Budget, bytes: usize) error{LayoutBudgetExceeded}!void {
        var old = self.live_bytes.load(.monotonic);
        while (true) {
            if (bytes > limit_bytes -| old) return error.LayoutBudgetExceeded;
            old = self.live_bytes.cmpxchgWeak(old, old + bytes, .monotonic, .monotonic) orelse return;
        }
    }

    fn release(self: *Budget, bytes: usize) void {
        const old = self.live_bytes.fetchSub(bytes, .monotonic);
        std.debug.assert(old >= bytes);
    }
};

/// Retained snapshot. Writers must call resize before modifying items; that
/// detaches shared storage. Copying this value requires retain(), and every
/// owner must deinit(). Readers never allocate or copy the layer array.
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();
        const Storage = struct {
            refs: std.atomic.Value(usize) = .init(1),
            alloc: std.mem.Allocator,
            budget: *Budget,
            items: []T,
        };

        storage: ?*Storage = null,
        items: []T = &.{},
        len: usize = 0,

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        pub fn root(self: *const Self) ?T {
            return if (self.len == 0) null else self.items[0];
        }

        pub fn retain(self: Self) Self {
            if (self.storage) |s| _ = s.refs.fetchAdd(1, .monotonic);
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.storage) |s| {
                if (s.refs.fetchSub(1, .acq_rel) == 1) {
                    const budget = s.budget;
                    const bytes = @sizeOf(Storage) + s.items.len * @sizeOf(T);
                    const alloc = s.alloc;
                    alloc.free(s.items);
                    alloc.destroy(s);
                    budget.release(bytes);
                }
            }
            self.* = .{};
        }

        pub fn resize(self: *Self, alloc: std.mem.Allocator, budget: *Budget, len: usize) !void {
            if (self.storage) |s| {
                if (s.refs.load(.acquire) == 1 and s.items.len >= len) {
                    self.len = len;
                    self.items = s.items[0..len];
                    return;
                }
            } else if (len == 0) return;
            const old_capacity = if (self.storage) |s| s.items.len else 0;
            const capacity = if (len > old_capacity) @max(len, old_capacity *| 2) else old_capacity;
            const data_bytes = std.math.mul(usize, capacity, @sizeOf(T)) catch return error.LayoutBudgetExceeded;
            const bytes = std.math.add(usize, data_bytes, @sizeOf(Storage)) catch return error.LayoutBudgetExceeded;
            try budget.reserve(bytes);
            errdefer budget.release(bytes);
            const storage = try alloc.create(Storage);
            errdefer alloc.destroy(storage);
            const items = try alloc.alloc(T, capacity);
            storage.* = .{ .alloc = alloc, .budget = budget, .items = items };
            const preserved = @min(self.len, len);
            @memcpy(items[0..preserved], self.items[0..preserved]);
            self.deinit();
            self.* = .{ .storage = storage, .items = items[0..len], .len = len };
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
            self.items = self.items[0..0];
        }

        pub fn append(self: *Self, alloc: std.mem.Allocator, budget: *Budget, value: T) !void {
            const old_len = self.len;
            try self.resize(alloc, budget, old_len + 1);
            self.items[old_len] = value;
        }
    };
}

test "layout replacement preserves paint snapshots and reuses exclusive capacity" {
    var budget = Budget{};
    var list = List(u64){};
    defer list.deinit();
    try list.resize(std.testing.allocator, &budget, 128);
    @memset(list.items, 7);
    var paint = list.retain();
    try list.resize(std.testing.allocator, &budget, 65);
    list.items[0] = 9;
    try std.testing.expectEqual(@as(u64, 7), paint.items[0]);
    paint.deinit();
    const storage = list.storage;
    try list.resize(std.testing.allocator, &budget, 64);
    try std.testing.expectEqual(storage, list.storage);
    list.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.live_bytes.load(.monotonic));
}

test "layout budget rejects growth without changing the committed contents" {
    var budget = Budget{};
    var list = List(u8){};
    defer list.deinit();
    try list.resize(std.testing.allocator, &budget, 65);
    @memset(list.items, 42);
    const before = budget.live_bytes.load(.monotonic);
    try std.testing.expectError(error.LayoutBudgetExceeded, list.resize(std.testing.allocator, &budget, Budget.limit_bytes));
    try std.testing.expectEqual(before, budget.live_bytes.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 65), list.len);
    try std.testing.expectEqual(@as(u8, 42), list.items[0]);
}
