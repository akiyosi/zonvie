// Shelf-based atlas packer for core-managed glyph atlas (Phase 2).
// Zero allocations: all state is inline fields.

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// Upper bound on tracked shelves. A shelf is as tall as the tallest glyph
/// that opened it, so a small font over a tall atlas produces many of them.
/// Exceeding this sets `shelf_overflow`, which only disables recycling — bump
/// packing stays exact.
pub const max_shelves = 1024;

/// One closed shelf. `x` is the reuse cursor and is only meaningful while
/// `recycled` is set. Fields are u16 because both dimensions are bounded by
/// the frontend-supported maximum atlas size.
const Shelf = struct {
    y: u16,
    h: u16,
    x: u16,
    recycled: bool,
    /// Flush epoch this shelf last received a glyph in. Reclaiming a shelf the
    /// current flush is still filling would throw away glyphs it has already
    /// composed rows against.
    epoch: u32 = 0,
};

const AllocUndo = enum { none, bump, recycled };

pub const ShelfPacker = struct {
    width: u32,
    height: u32,
    next_x: u32 = 1, // start at 1 for 1-pixel border
    next_y: u32 = 1,
    row_h: u32 = 0,
    padding: u32 = 1,

    // Recycling bookkeeping. A shelf is recorded when it is closed (the bump
    // cursor wrapped past it); the still-open shelf is described by
    // next_y/row_h and is never recyclable.
    shelf_count: u32 = 0,
    shelf_overflow: bool = false,
    epoch: u32 = 0,
    shelves: [max_shelves]Shelf = @splat(.{ .y = 0, .h = 0, .x = 0, .recycled = false }),

    // Undo state for exactly one allocation. packAndUploadBitmap rolls the
    // last alloc back when the frontend rejects the upload; keeping this
    // inline avoids snapshotting the whole (multi-KB) packer per glyph.
    undo_kind: AllocUndo = .none,
    undo_index: u32 = 0,
    undo_x: u32 = 0,
    undo_y: u32 = 0,
    undo_row_h: u32 = 0,
    undo_shelf_count: u32 = 0,

    pub fn init(w: u32, h: u32) ShelfPacker {
        return .{ .width = w, .height = h };
    }

    /// Open a new allocation epoch. Everything filled after this point is
    /// off-limits to reclamation until the next epoch.
    pub fn beginEpoch(self: *ShelfPacker) void {
        self.epoch +%= 1;
    }

    /// Allocate a rect for a glyph of the given pixel size.
    /// The returned rect includes padding on all sides.
    /// Returns null if the atlas is full, without mutating any state.
    pub fn alloc(self: *ShelfPacker, glyph_w: u32, glyph_h: u32) ?Rect {
        const packed_w = glyph_w + self.padding * 2;
        const packed_h = glyph_h + self.padding * 2;

        // Reclaimed shelves first, tightest height that still fits, so a tall
        // shelf stays available for a tall glyph.
        if (self.allocFromRecycled(packed_w, packed_h)) |rect| return rect;

        // Wrap to next shelf row if current row is too narrow. Computed
        // tentatively: a rejected allocation must leave the packer untouched.
        var nx = self.next_x;
        var ny = self.next_y;
        var rh = self.row_h;
        const wrapped = nx + packed_w > self.width;
        if (wrapped) {
            nx = 1;
            ny += rh;
            rh = 0;
        }

        // Atlas full: no more vertical space.
        if (ny + packed_h > self.height) return null;
        // Glyph too wide to ever fit on a fresh shelf row: reject only if the
        // actual written glyph region (nx + padding + glyph_w, i.e.
        // nx + packed_w - padding) would extend past the buffer's right
        // edge. Deliberately NOT `nx + packed_w > self.width`: that
        // would also reject the packed_w == width boundary at nx == 1,
        // which is the current caller's normal (safe) upper bound — see
        // fix-plan Item 2/3 write-region analysis. At nx = 1,
        // packed_w = width: 1 + width - 1 = width > width is false, so the
        // boundary is still admitted; a glyph that is genuinely too wide
        // (packed_w > width) is still rejected.
        if (nx + packed_w - self.padding > self.width) return null;

        self.undo_kind = .bump;
        self.undo_x = self.next_x;
        self.undo_y = self.next_y;
        self.undo_row_h = self.row_h;
        self.undo_shelf_count = self.shelf_count;
        if (wrapped) self.closeShelf(self.next_y, self.row_h);

        const rect = Rect{
            .x = nx,
            .y = ny,
            .w = packed_w,
            .h = packed_h,
        };
        self.next_x = nx + packed_w;
        self.next_y = ny;
        self.row_h = @max(rh, packed_h);
        return rect;
    }

    /// Undo the most recent successful `alloc`. Only valid immediately after
    /// that call, before any other allocation.
    pub fn undoLastAlloc(self: *ShelfPacker) void {
        switch (self.undo_kind) {
            .none => {},
            .bump => {
                self.next_x = self.undo_x;
                self.next_y = self.undo_y;
                self.row_h = self.undo_row_h;
                self.shelf_count = self.undo_shelf_count;
            },
            .recycled => {
                self.shelves[self.undo_index].x = @intCast(self.undo_x);
            },
        }
        self.undo_kind = .none;
    }

    fn allocFromRecycled(self: *ShelfPacker, packed_w: u32, packed_h: u32) ?Rect {
        var best: ?u32 = null;
        var i: u32 = 0;
        while (i < self.shelf_count) : (i += 1) {
            const shelf = self.shelves[i];
            if (!shelf.recycled) continue;
            if (shelf.h < packed_h) continue;
            if (@as(u32, shelf.x) + packed_w > self.width) continue;
            if (@as(u32, shelf.x) + packed_w - self.padding > self.width) continue;
            if (best) |b| {
                if (shelf.h >= self.shelves[b].h) continue;
            }
            best = i;
        }
        const idx = best orelse return null;
        // An empty shelf much taller than this glyph is split, so the surplus
        // band stays available for a taller glyph instead of being wasted for
        // as long as the shelf lives. Without splitting, reclaimed space
        // degenerates into a few huge shelves that stay occupied because one
        // surviving glyph is enough to pin the whole band.
        if (self.shelves[idx].x == 1 and self.shelf_count < max_shelves) {
            const surplus = @as(u32, self.shelves[idx].h) - packed_h;
            if (surplus > self.padding * 2) {
                self.shelves[self.shelf_count] = .{
                    .y = @intCast(@as(u32, self.shelves[idx].y) + packed_h),
                    .h = @intCast(surplus),
                    .x = 1,
                    .recycled = true,
                    .epoch = self.epoch,
                };
                self.shelf_count += 1;
                self.shelves[idx].h = @intCast(packed_h);
            }
        }
        const shelf = &self.shelves[idx];
        const rect = Rect{
            .x = shelf.x,
            .y = shelf.y,
            .w = packed_w,
            .h = packed_h,
        };
        self.undo_kind = .recycled;
        self.undo_index = idx;
        self.undo_x = shelf.x;
        shelf.epoch = self.epoch;
        shelf.x = @intCast(@as(u32, shelf.x) + packed_w);
        return rect;
    }

    fn closeShelf(self: *ShelfPacker, y: u32, h: u32) void {
        if (h == 0) return;
        if (self.shelf_count >= max_shelves or y > 0xFFFF or h > 0xFFFF) {
            self.shelf_overflow = true;
            return;
        }
        self.shelves[self.shelf_count] = .{
            .y = @intCast(y),
            .h = @intCast(h),
            .x = 1,
            .recycled = false,
            .epoch = self.epoch,
        };
        self.shelf_count += 1;
    }

    /// Index of the closed shelf covering `y`, or null when `y` belongs to the
    /// still-open shelf or to no shelf at all.
    pub fn shelfIndexForY(self: *const ShelfPacker, y: u32) ?u32 {
        var i: u32 = 0;
        while (i < self.shelf_count) : (i += 1) {
            const shelf = self.shelves[i];
            if (y >= shelf.y and y < @as(u32, shelf.y) + shelf.h) return i;
        }
        return null;
    }

    /// Make every closed shelf whose `live` entry is false available for reuse.
    /// Returns how many shelves became reusable. The caller is responsible for
    /// having proven that nothing on screen references those shelves and for
    /// invalidating the glyph cache entries that point into them.
    pub fn recycleDeadShelves(self: *ShelfPacker, live: []const bool) u32 {
        var recycled: u32 = 0;
        var i: u32 = 0;
        while (i < self.shelf_count and i < live.len) : (i += 1) {
            if (live[i]) continue;
            // An already-recycled shelf that never refilled contributes no new
            // space, so it does not count as progress.
            if (self.shelves[i].epoch == self.epoch) continue;
            if (self.shelves[i].recycled and self.shelves[i].x == 1) continue;
            self.shelves[i].recycled = true;
            self.shelves[i].x = 1;
            recycled += 1;
        }
        if (recycled != 0) self.undo_kind = .none;
        return recycled;
    }

    /// Fuse runs of adjacent, empty, reclaimed shelves into one taller shelf.
    ///
    /// Without this, reclaimed space is permanently partitioned by the glyph
    /// heights that happened to open each shelf: a run of free 14px shelves
    /// cannot accept an 18px glyph, so allocation fails with most of the atlas
    /// unused, which the caller can only answer with a full atlas reset. Call
    /// after the caller has invalidated the cache entries that referenced the
    /// reclaimed shelves — merging renumbers shelves, so index-keyed liveness
    /// data from before the call no longer applies.
    pub fn mergeAdjacentRecycled(self: *ShelfPacker) void {
        if (self.shelf_count < 2) return;
        // Splitting appends surplus bands, so shelves are not in y order and
        // neighbours have to be found by coordinate.
        var merged_any = true;
        while (merged_any) {
            merged_any = false;
            var i: u32 = 0;
            while (i < self.shelf_count) : (i += 1) {
                if (!self.isFreeBand(i)) continue;
                const end = @as(u32, self.shelves[i].y) + self.shelves[i].h;
                var j: u32 = 0;
                while (j < self.shelf_count) : (j += 1) {
                    if (j == i or !self.isFreeBand(j)) continue;
                    if (self.shelves[j].y != end) continue;
                    const merged_h = @as(u32, self.shelves[i].h) + self.shelves[j].h;
                    if (merged_h > 0xFFFF) continue;
                    self.shelves[i].h = @intCast(merged_h);
                    self.shelf_count -= 1;
                    self.shelves[j] = self.shelves[self.shelf_count];
                    merged_any = true;
                    break;
                }
            }
        }
        self.undo_kind = .none;
    }

    fn isFreeBand(self: *const ShelfPacker, index: u32) bool {
        return self.shelves[index].recycled and self.shelves[index].x == 1;
    }

    /// Unused atlas area in pixels: the bump frontier plus what reclaimed
    /// shelves still have to the right of their reuse cursor.
    pub fn freeAreaPx(self: *const ShelfPacker) u64 {
        var free: u64 = 0;
        if (self.height > self.next_y) {
            free += @as(u64, self.height - self.next_y) * self.width;
        }
        var i: u32 = 0;
        while (i < self.shelf_count) : (i += 1) {
            const shelf = self.shelves[i];
            if (!shelf.recycled) continue;
            if (shelf.x >= self.width) continue;
            free += @as(u64, self.width - shelf.x) * shelf.h;
        }
        return free;
    }

    /// Reset packer state (after atlas recreation).
    pub fn reset(self: *ShelfPacker) void {
        self.next_x = 1;
        self.next_y = 1;
        self.row_h = 0;
        self.shelf_count = 0;
        self.shelf_overflow = false;
        self.undo_kind = .none;
    }

    /// Compute normalized UV coordinates for a glyph bitmap placed at (rect_x, rect_y).
    /// Returns { u0, v0, u1, v1 } in [0..1] range, excluding padding.
    pub fn computeUV(self: *const ShelfPacker, rect_x: u32, rect_y: u32, bitmap_w: u32, bitmap_h: u32) [4]f32 {
        const p = self.padding;
        const inv_w = 1.0 / @as(f32, @floatFromInt(self.width));
        const inv_h = 1.0 / @as(f32, @floatFromInt(self.height));
        return .{
            @as(f32, @floatFromInt(rect_x + p)) * inv_w,
            @as(f32, @floatFromInt(rect_y + p)) * inv_h,
            @as(f32, @floatFromInt(rect_x + p + bitmap_w)) * inv_w,
            @as(f32, @floatFromInt(rect_y + p + bitmap_h)) * inv_h,
        };
    }
};
