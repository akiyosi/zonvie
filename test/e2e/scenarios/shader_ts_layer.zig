// shader_ts_layer — the markers of the Tree-sitter layer reach the cells'
// shader group masks through a real Neovim, and the cursor reaches the core
// as two ids without changing any cell.
//
// A shader that declares `ZonvieTs*` names gets src/core/shader_ts_layer.lua
// run in Neovim; it places those groups from the buffer's tree, and each
// cell's attribute id then resolves to the declared bits. This covers the
// whole chain: the layer is sent, the marker groups get attribute ids of
// their own, ext_hlstate names them, the mask table follows, and the
// `zonvie_ts_cursor` notification sets the ids shaders compare against.
// Exercises: sendShaderHlUnlink, hl_attr_define info, rebuildShaderHlMasks,
// handleRpcNotification.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const declaration =
    "// @zonvie-hl-groups: ZonvieTsFnB0 ZonvieTsFnB1 ZonvieTsScopeB0 ZonvieTsScopeB1 ZonvieTsScopeB2 " ++
    "ZonvieTsDepthB0 ZonvieTsDepthB1 ZonvieTsParam ZonvieTsParamB0 ZonvieTsParamB1 ZonvieTsSignFn ZonvieTsCursorBuf\n";
const fn0: u32 = 1 << 0;
const fn1: u32 = 1 << 1;
const sc0: u32 = 1 << 2;
const sc1: u32 = 1 << 3;
const d0: u32 = 1 << 5;
const d1: u32 = 1 << 6;
const param: u32 = 1 << 7;
const p0: u32 = 1 << 8;
const p1: u32 = 1 << 9;
const sign_fn: u32 = 1 << 10;
/// Every cell of the buffer the cursor is in.
const cb: u32 = 1 << 11;

/// 'signcolumn=yes': buffer column c is grid column c + sign_cols.
const sign_cols: u32 = 2;

fn maskAt(h: *Harness, grid: i64, row: u32, col: u32) u32 {
    const cell = h.cellAt(grid, row, col);
    h.core.grid_mu.lockUncancelable(zc.clock.io());
    defer h.core.grid_mu.unlock(zc.clock.io());
    const masks = h.core.shader_hl_masks.items;
    return if (cell.hl < masks.len) masks[cell.hl] else 0;
}

fn expectMask(h: *Harness, grid: i64, row: u32, buf_col: u32, want: u32) !void {
    const got = maskAt(h, grid, row, buf_col + sign_cols);
    if (got != want) {
        std.debug.print("[e2e] row {d} col {d}: mask {b}, want {b}\n", .{ row, buf_col, got, want });
        return error.MaskMismatch;
    }
}

const Probe = struct { grid: i64, row: u32, col: u32, want: u32 };

/// Wait for the mask of a grid cell (sign column included in `grid_col`).
fn waitGridMask(h: *Harness, grid: i64, row: u32, grid_col: u32, want: u32) !void {
    h.waitUntil(Probe{ .grid = grid, .row = row, .col = grid_col, .want = want }, struct {
        fn check(p: Probe, hh: *Harness) bool {
            return maskAt(hh, p.grid, p.row, p.col) == p.want;
        }
    }.check, h.opts.timeout_ms) catch |e| {
        std.debug.print("[e2e] row {d} grid col {d}: mask {b}, waited for {b}\n", .{
            row, grid_col, maskAt(h, grid, row, grid_col), want,
        });
        return e;
    };
}

fn waitMask(h: *Harness, grid: i64, row: u32, buf_col: u32, want: u32) !void {
    return waitGridMask(h, grid, row, buf_col + sign_cols, want);
}

const Ids = struct { func: u32, scope: u32 };

fn waitCursorIds(h: *Harness, want: Ids) !void {
    h.waitUntil(want, struct {
        fn check(w: Ids, hh: *Harness) bool {
            return hh.core.ts_cursor_fn.load(.acquire) == w.func and hh.core.ts_cursor_scope.load(.acquire) == w.scope;
        }
    }.check, h.opts.timeout_ms) catch |e| {
        std.debug.print("[e2e] cursor ids fn={d} scope={d}, waited for fn={d} scope={d}\n", .{
            h.core.ts_cursor_fn.load(.acquire), h.core.ts_cursor_scope.load(.acquire), want.func, want.scope,
        });
        return e;
    };
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("set signcolumn=yes");
    //  0  if true then                          scope 1
    //  1    local function add(first, second)   scope 2, function 1
    //  2      if first then                     scope 3
    //  3        return first + second
    //  4  (blank)
    //  5      end
    //  6    end
    //  7  end
    //  8  (blank)
    //  9  local x = 1
    try h.command(
        \\lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'if true then', '  local function add(first, second)', '    if first then', '      return first + second', '', '    end', '  end', 'end', '', 'local x = 1' }) vim.bo.filetype = 'lua'
    );
    try h.command("normal! 4G");

    h.core.grid_mu.lockUncancelable(zc.clock.io());
    h.core.setShaderHlGroupsLocked(declaration);
    h.core.grid_mu.unlock(zc.clock.io());
    h.core.sendShaderHlUnlink();

    const g = h.winGrid();
    // `return` sits in scope 3, which is in function 1, three scopes deep.
    try waitMask(h, g, 3, 6, sc0 | sc1 | fn0 | d0 | d1 | cb);
    // The cursor is there too: the core holds the two ids, no cell says so.
    try waitCursorIds(h, .{ .func = 1, .scope = 3 });

    // Ids and depth are per cell: each scope covers the cells from its
    // first line's indent rightward.
    try expectMask(h, g, 3, 0, sc0 | d0 | cb);
    try expectMask(h, g, 3, 2, sc1 | fn0 | d1 | cb);
    try expectMask(h, g, 3, 4, sc0 | sc1 | fn0 | d0 | d1 | cb);
    // A blank line keeps the same steps, in its cells past the line's end.
    try expectMask(h, g, 4, 0, sc0 | d0 | cb);
    try expectMask(h, g, 4, 2, sc1 | fn0 | d1 | cb);
    try expectMask(h, g, 4, 4, sc0 | sc1 | fn0 | d0 | d1 | cb);
    try expectMask(h, g, 4, 40, sc0 | sc1 | fn0 | d0 | d1 | cb);
    // A scope's first and closing rows carry its id at the depth of the
    // scope around it.
    try expectMask(h, g, 0, 0, sc0 | cb);
    try expectMask(h, g, 1, 0, sc0 | d0 | cb);
    try expectMask(h, g, 1, 2, sc1 | fn0 | d0 | cb);
    try expectMask(h, g, 2, 4, sc0 | sc1 | fn0 | d1 | cb);
    try expectMask(h, g, 6, 2, sc1 | fn0 | d0 | cb);
    try expectMask(h, g, 7, 0, sc0 | cb);
    // A parameter carries its position where it is declared and used.
    try expectMask(h, g, 1, 21, sc1 | fn0 | d0 | cb | param | p0);
    try expectMask(h, g, 1, 28, sc1 | fn0 | d0 | cb | param | p1);
    try expectMask(h, g, 2, 7, sc0 | sc1 | fn0 | d1 | cb | p0);
    try expectMask(h, g, 3, 13, sc0 | sc1 | fn0 | d0 | d1 | cb | p0);
    try expectMask(h, g, 3, 21, sc0 | sc1 | fn0 | d0 | d1 | cb | p1);
    // The function's first row carries its sign; code outside every scope
    // carries only the cursor buffer's bit.
    try std.testing.expectEqual(sign_fn, maskAt(h, g, 1, 0));
    try std.testing.expectEqual(@as(u32, 0), maskAt(h, g, 2, 0));
    try expectMask(h, g, 9, 0, cb);

    // The cursor leaves every scope: the ids go to zero, the cells stay.
    try h.command("normal! 10G");
    try waitCursorIds(h, .{ .func = 0, .scope = 0 });
    try expectMask(h, g, 3, 6, sc0 | sc1 | fn0 | d0 | d1 | cb);
    try expectMask(h, g, 1, 21, sc1 | fn0 | d0 | cb | param | p0);

    // A second grammar, and a buffer no Tree-sitter highlighter runs on:
    // C names its nodes differently (parameters hang off a declarator, the
    // braces are rows of their own) and gets the same markers.
    //  0  int sum(const int *items, int count)   scope 1, function 1
    //  1  {
    //  2      int total = 0;
    //  3      for (int i = 0; i < count; i++) {   scope 2
    //  4          total += items[i];
    //  5      }
    //  6      return total;
    //  7  }
    try h.command(
        \\lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'int sum(const int *items, int count)', '{', '    int total = 0;', '    for (int i = 0; i < count; i++) {', '        total += items[i];', '    }', '    return total;', '}' }) vim.bo.filetype = 'c'
    );
    try h.command("normal! 5G");
    try waitMask(h, g, 4, 8, sc1 | fn0 | d1 | cb);
    try waitCursorIds(h, .{ .func = 1, .scope = 2 });
    try expectMask(h, g, 4, 0, sc0 | fn0 | d0 | cb);
    try expectMask(h, g, 4, 17, sc1 | fn0 | d1 | cb | p0);
    try expectMask(h, g, 0, 19, sc0 | fn0 | cb | param | p0);
    try expectMask(h, g, 0, 30, sc0 | fn0 | cb | param | p1);
    try expectMask(h, g, 1, 0, sc0 | fn0 | d0 | cb);
    try expectMask(h, g, 7, 0, sc0 | fn0 | cb);
    try waitGridMask(h, g, 0, 0, sign_fn);

    // Two functions. Moving between them changes the two ids and no cell;
    // an edit above one leaves its ids as they were.
    //  0  local function a()   scope 1, function 1
    //  1    return 1
    //  2  end
    //  3  (blank)
    //  4  local function b()   scope 2, function 2
    //  5    return 2
    //  6  end
    try h.command(
        \\lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local function a()', '  return 1', 'end', '', 'local function b()', '  return 2', 'end' }) vim.bo.filetype = 'lua'
    );
    try h.command("normal! 2G");
    try waitMask(h, g, 5, 2, sc1 | fn1 | d0 | cb);
    try waitCursorIds(h, .{ .func = 1, .scope = 1 });
    try expectMask(h, g, 1, 2, sc0 | fn0 | d0 | cb);
    try expectMask(h, g, 3, 0, cb);

    try h.command("normal! 6G");
    try waitCursorIds(h, .{ .func = 2, .scope = 2 });
    try expectMask(h, g, 1, 2, sc0 | fn0 | d0 | cb);
    try expectMask(h, g, 5, 2, sc1 | fn1 | d0 | cb);
    try h.command("normal! 4G");
    try waitCursorIds(h, .{ .func = 0, .scope = 0 });

    // A line added inside `a` moves `b` down a row; `b` is still scope 2,
    // function 2.
    try h.command("normal! 1Gox = 1");
    // `a` now ends a row lower (its `end` took the blank row's place)...
    try waitMask(h, g, 3, 0, sc0 | fn0 | cb);
    // ...the new line is in `a` once the layer has caught up with the edit...
    try waitMask(h, g, 1, 0, sc0 | fn0 | d0 | cb);
    // ...and `b`, which only moved, is what it was.
    try expectMask(h, g, 6, 2, sc1 | fn1 | d0 | cb);
    try expectMask(h, g, 5, 0, sc1 | fn1 | cb);
}
