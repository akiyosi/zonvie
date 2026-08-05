//! Tests for the noice.nvim-style message router (`src/core/msg_route.zig`).
//!
//! The first two groups pin the properties the previous routing layer lacked:
//! user routes must compose with the defaults instead of replacing them, and
//! "no route matched" must not be reachable.

const std = @import("std");
const msg_route = @import("msg_route");

const Router = msg_route.Router;
const MsgRoute = msg_route.MsgRoute;
const ViewSettings = msg_route.ViewSettings;

// -- user routes compose with defaults ---------------------------------------

test "a user route does not disable unrelated events" {
    // The regression this rewrite exists for: declaring a single msg_show rule
    // used to replace the whole table, dropping msg_history_show to `none`.
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show }, .view = .split },
    };
    const r: Router = .{ .user_routes = &user };

    try std.testing.expectEqual(msg_route.MsgViewType.split, r.route(.msg_show, "", 1).view);

    // Everything the user did not mention keeps its default.
    try std.testing.expectEqual(msg_route.MsgViewType.split, r.route(.msg_history_show, "", 1).view);
    try std.testing.expectEqual(msg_route.MsgViewType.mini, r.route(.msg_showmode, "", 1).view);
    try std.testing.expectEqual(msg_route.MsgViewType.mini, r.route(.msg_showcmd, "", 1).view);
}

test "user routes take precedence over defaults" {
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_showmode }, .view = .none },
    };
    const r: Router = .{ .user_routes = &user };

    try std.testing.expectEqual(msg_route.MsgViewType.none, r.route(.msg_showmode, "", 1).view);
    try std.testing.expectEqual(msg_route.MsgViewType.mini, r.route(.msg_showcmd, "", 1).view);
}

test "first matching user route wins" {
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show, .max_height = 5 }, .view = .mini },
        .{ .filter = .{ .event = .msg_show }, .view = .split },
    };
    const r: Router = .{ .user_routes = &user };

    try std.testing.expectEqual(msg_route.MsgViewType.mini, r.route(.msg_show, "", 3).view);
    try std.testing.expectEqual(msg_route.MsgViewType.split, r.route(.msg_show, "", 40).view);
}

// -- "unmatched" is unreachable ----------------------------------------------

test "every event reaches a view with no routes configured" {
    const r: Router = .{};
    for ([_]msg_route.MsgEvent{ .msg_show, .msg_showmode, .msg_showcmd, .msg_ruler, .msg_history_show }) |ev| {
        const res = r.route(ev, "", 1);
        try std.testing.expect(!res.skip);
        try std.testing.expect(res.view != .none);
    }
}

test "an unknown kind falls through to the catch-all, not to none" {
    const r: Router = .{};
    const res = r.route(.msg_show, "some_future_nvim_kind", 1);
    try std.testing.expectEqual(msg_route.MsgViewType.ext_float, res.view);
    try std.testing.expect(!res.skip);
}

test "hiding requires an explicit skip" {
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_ruler }, .opts = .{ .skip = true } },
    };
    const r: Router = .{ .user_routes = &user };

    const hidden = r.route(.msg_ruler, "", 1);
    try std.testing.expect(hidden.skip);
    try std.testing.expectEqual(msg_route.MsgViewType.none, hidden.view);

    // A neighbouring event is unaffected.
    try std.testing.expect(!r.route(.msg_showcmd, "", 1).skip);
}

// -- named view settings ------------------------------------------------------

test "view settings retarget the defaults without writing routes" {
    const r: Router = .{ .views = .{
        .view = .mini,
        .view_error = .notification,
        .view_history = .ext_float,
        .view_search = .none,
    } };

    try std.testing.expectEqual(msg_route.MsgViewType.mini, r.route(.msg_show, "echo", 1).view);
    try std.testing.expectEqual(msg_route.MsgViewType.notification, r.route(.msg_show, "emsg", 1).view);
    try std.testing.expectEqual(msg_route.MsgViewType.ext_float, r.route(.msg_history_show, "", 1).view);
    try std.testing.expectEqual(msg_route.MsgViewType.none, r.route(.msg_show, "search_count", 1).view);
}

// -- filters ------------------------------------------------------------------

test "level filter classifies error and warning kinds" {
    const r: Router = .{ .views = .{ .view_error = .confirm, .view_warn = .split, .view = .mini } };

    for ([_][]const u8{ "emsg", "echoerr", "lua_error", "rpc_error" }) |kind| {
        try std.testing.expectEqual(msg_route.MsgViewType.confirm, r.route(.msg_show, kind, 1).view);
    }
    try std.testing.expectEqual(msg_route.MsgViewType.split, r.route(.msg_show, "wmsg", 1).view);
    try std.testing.expectEqual(msg_route.MsgViewType.mini, r.route(.msg_show, "echomsg", 1).view);
}

test "height filters bound a route" {
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show, .min_height = 20 }, .view = .split },
    };
    const r: Router = .{ .user_routes = &user };

    try std.testing.expectEqual(msg_route.MsgViewType.ext_float, r.route(.msg_show, "", 19).view);
    try std.testing.expectEqual(msg_route.MsgViewType.split, r.route(.msg_show, "", 20).view);
    try std.testing.expectEqual(msg_route.MsgViewType.split, r.route(.msg_show, "", 2034).view);
}

test "kinds filter matches any listed kind" {
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show, .kinds = &.{ "list_cmd", "shell_out" } }, .view = .split },
    };
    const r: Router = .{ .user_routes = &user };

    try std.testing.expectEqual(msg_route.MsgViewType.split, r.route(.msg_show, "list_cmd", 1).view);
    try std.testing.expectEqual(msg_route.MsgViewType.split, r.route(.msg_show, "shell_out", 1).view);
    try std.testing.expectEqual(msg_route.MsgViewType.ext_float, r.route(.msg_show, "echo", 1).view);
}

test "an empty filter matches everything" {
    const user = [_]MsgRoute{
        .{ .filter = .{}, .view = .notification },
    };
    const r: Router = .{ .user_routes = &user };

    try std.testing.expectEqual(msg_route.MsgViewType.notification, r.route(.msg_show, "emsg", 1).view);
    try std.testing.expectEqual(msg_route.MsgViewType.notification, r.route(.msg_ruler, "", 1).view);
}

// -- prompts ------------------------------------------------------------------

test "confirm kinds reach the confirm view with no configuration" {
    const r: Router = .{};
    for ([_][]const u8{ "confirm", "confirm_sub", "number_prompt" }) |kind| {
        const res = r.route(.msg_show, kind, 1);
        try std.testing.expectEqual(msg_route.MsgViewType.confirm, res.view);
        try std.testing.expectEqual(@as(f32, 0), res.timeout);
    }
}

test "interactive prompts cannot be routed away by broad user routes" {
    // Regression: the old pre-route hardcode was replaced by an overridable
    // default route, so a catch-all user route captured confirm dialogs and
    // sent them to a view where they cannot be answered — Neovim then
    // blocked on a question the user never saw. Prompts are pinned ahead of
    // every route again, user or default.
    const catch_all = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show }, .view = .split },
    };
    const r1: Router = .{ .user_routes = &catch_all };
    for ([_][]const u8{ "confirm", "confirm_sub", "number_prompt" }) |kind| {
        const res = r1.route(.msg_show, kind, 1);
        try std.testing.expectEqual(msg_route.MsgViewType.confirm, res.view);
        try std.testing.expect(!res.skip);
        // The captured route's timeout must not ride along: a prompt Neovim
        // is blocked on can never be allowed to auto-hide.
        try std.testing.expectEqual(@as(f32, 0), res.timeout);
    }
    // Non-prompt kinds still follow the user's route.
    try std.testing.expectEqual(msg_route.MsgViewType.split, r1.route(.msg_show, "echo", 1).view);
}

test "interactive prompts cannot be skipped" {
    const skip_all = [_]MsgRoute{
        .{ .filter = .{}, .opts = .{ .skip = true } },
    };
    const r: Router = .{ .user_routes = &skip_all };
    const res = r.route(.msg_show, "confirm", 1);
    try std.testing.expectEqual(msg_route.MsgViewType.confirm, res.view);
    try std.testing.expect(!res.skip);
    // The skip still applies to everything that is not a prompt.
    try std.testing.expect(r.route(.msg_show, "echo", 1).skip);
}

test "not even a confirm-targeting route can time out a blocking prompt" {
    // The escape hatch this replaces let a route that resolved to `.confirm`
    // keep its own timeout — so the one view that CAN answer a prompt was
    // allowed to auto-hide while Neovim still blocked on it, which is the
    // very hang the net exists to prevent. There is no exception now.
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show, .kinds = &.{"confirm"} }, .view = .confirm, .opts = .{ .timeout = 5.0 } },
    };
    const r: Router = .{ .user_routes = &user };
    const res = r.route(.msg_show, "confirm", 1);
    try std.testing.expectEqual(msg_route.MsgViewType.confirm, res.view);
    try std.testing.expectEqual(@as(f32, 0), res.timeout);

    // Non-prompt kinds are untouched by the net and keep the route's timeout.
    const echo_route = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show, .kinds = &.{"echo"} }, .view = .confirm, .opts = .{ .timeout = 5.0 } },
    };
    const r2: Router = .{ .user_routes = &echo_route };
    try std.testing.expectEqual(@as(f32, 5.0), r2.route(.msg_show, "echo", 1).timeout);
}

test "a route's enter reaches the result; unset stays the channel default" {
    // `enter` rides the route like `timeout` does. null must survive to the
    // dispatch layer untouched — it means "channel default" (`:messages`
    // enters, routed messages do not), and resolving it here would lose
    // which channel is asking.
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show, .kinds = &.{"echo"} }, .view = .split, .opts = .{ .enter = true } },
        .{ .filter = .{ .event = .msg_history_show }, .view = .split, .opts = .{ .enter = false } },
    };
    const r: Router = .{ .user_routes = &user };
    try std.testing.expectEqual(@as(?bool, true), r.route(.msg_show, "echo", 1).enter);
    try std.testing.expectEqual(@as(?bool, false), r.route(.msg_history_show, "", 1).enter);
    // No route sets it: the default routes leave it null.
    try std.testing.expectEqual(@as(?bool, null), r.route(.msg_show, "emsg", 1).enter);
}

test "pinned prompts carry no enter override" {
    // The confirm view is a frontend dialog with no cursor; the pin must not
    // invent an enter value a broad user route could otherwise smuggle in.
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show }, .view = .split, .opts = .{ .enter = true } },
    };
    const r: Router = .{ .user_routes = &user };
    try std.testing.expectEqual(@as(?bool, null), r.route(.msg_show, "number_prompt", 1).enter);
}

test "return_prompt is identified for event-layer dismissal" {
    try std.testing.expect(msg_route.isReturnPrompt("return_prompt"));
    try std.testing.expect(!msg_route.isReturnPrompt("confirm"));
    try std.testing.expect(!msg_route.isReturnPrompt(""));
}

// -- timeouts -----------------------------------------------------------------

test "timeout falls back to the default when unset" {
    const r: Router = .{};
    try std.testing.expectEqual(msg_route.default_timeout_sec, r.route(.msg_show, "echo", 1).timeout);
}

test "errors and history do not auto-hide" {
    const r: Router = .{};
    try std.testing.expectEqual(@as(f32, 0), r.route(.msg_show, "emsg", 1).timeout);
    try std.testing.expectEqual(@as(f32, 0), r.route(.msg_history_show, "", 1).timeout);
}

test "a view meant to be read does not auto-hide by default" {
    // Regression: the catch-all's 4s default used to leak onto `split`, so a
    // split the user routed messages into vanished on its own.
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show }, .view = .split },
    };
    const r: Router = .{ .user_routes = &user };
    try std.testing.expectEqual(@as(f32, 0), r.route(.msg_show, "echo", 1).timeout);
}

test "an explicit route timeout overrides the view default" {
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show }, .view = .split, .opts = .{ .timeout = 2.0 } },
    };
    const r: Router = .{ .user_routes = &user };
    try std.testing.expectEqual(@as(f32, 2.0), r.route(.msg_show, "echo", 1).timeout);
}

test "view default timeouts follow noice's view-level layering" {
    try std.testing.expectEqual(msg_route.default_timeout_sec, msg_route.viewDefaultTimeout(.mini));
    try std.testing.expectEqual(msg_route.default_timeout_sec, msg_route.viewDefaultTimeout(.ext_float));
    try std.testing.expectEqual(@as(f32, 0), msg_route.viewDefaultTimeout(.split));
    try std.testing.expectEqual(@as(f32, 0), msg_route.viewDefaultTimeout(.confirm));
    try std.testing.expectEqual(@as(f32, 0), msg_route.viewDefaultTimeout(.notification));
}

test "a user route timeout of zero survives resolution" {
    const user = [_]MsgRoute{
        .{ .filter = .{ .event = .msg_show }, .view = .mini, .opts = .{ .timeout = 0 } },
    };
    const r: Router = .{ .user_routes = &user };
    try std.testing.expectEqual(@as(f32, 0), r.route(.msg_show, "echo", 1).timeout);
}

// -- parsing ------------------------------------------------------------------

test "view names round-trip from config strings" {
    try std.testing.expectEqual(msg_route.MsgViewType.mini, msg_route.MsgViewType.fromString("mini").?);
    try std.testing.expectEqual(msg_route.MsgViewType.ext_float, msg_route.MsgViewType.fromString("ext-float").?);
    try std.testing.expectEqual(msg_route.MsgViewType.confirm, msg_route.MsgViewType.fromString("confirm").?);
    try std.testing.expectEqual(msg_route.MsgViewType.split, msg_route.MsgViewType.fromString("split").?);
    try std.testing.expectEqual(msg_route.MsgViewType.none, msg_route.MsgViewType.fromString("none").?);
    try std.testing.expectEqual(msg_route.MsgViewType.notification, msg_route.MsgViewType.fromString("notification").?);
    try std.testing.expect(msg_route.MsgViewType.fromString("ext_float") == null);
}

test "view enum values match the C ABI" {
    // include/zonvie_core.h: zonvie_msg_view_type
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(msg_route.MsgViewType.mini));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(msg_route.MsgViewType.ext_float));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(msg_route.MsgViewType.confirm));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(msg_route.MsgViewType.split));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(msg_route.MsgViewType.none));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(msg_route.MsgViewType.notification));
}
