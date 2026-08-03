//! Message routing engine, modelled on noice.nvim's `noice/config/routes.lua`
//! and `noice/message/router.lua`.
//!
//! Two properties the previous implementation lacked, and which noice relies on:
//!
//!   1. User routes are PREPENDED to the built-in defaults rather than
//!      replacing them (noice `config/routes.lua:8-18`). Declaring one rule
//!      can no longer silently disable unrelated events.
//!
//!   2. "Nothing matched" cannot happen: the default tail always matches, and
//!      hiding is an explicit `skip` opt (noice `config/routes.lua:70-78`), so
//!      a forgotten route and a deliberately hidden one are distinguishable.
//!
//! Also mirrored from noice: the common knobs are named view settings
//! (`view`, `view_error`, `view_warn`, `view_history`, `view_search` —
//! noice `config/init.lua:39-43`) that the default routes read, so users
//! retarget messages without writing routes at all.
//!
//! Deliberately NOT mirrored: noice's `opts.stop = false`, which lets one
//! message fan out to several views. Zonvie has no caller that needs it, and
//! supporting it would force a multi-result routing API on every call site.
//! Routing here is first-match-wins.

const std = @import("std");

/// Message events that can be routed. Mirrors noice `ui/msg.lua:12-20`,
/// minus the events that never reach a view (`msg_clear`, `msg_history_clear`).
pub const MsgEvent = enum {
    msg_show,
    msg_showmode,
    msg_showcmd,
    msg_ruler,
    msg_history_show,

    pub fn fromString(s: []const u8) ?MsgEvent {
        if (std.mem.eql(u8, s, "msg_show")) return .msg_show;
        if (std.mem.eql(u8, s, "msg_showmode")) return .msg_showmode;
        if (std.mem.eql(u8, s, "msg_showcmd")) return .msg_showcmd;
        if (std.mem.eql(u8, s, "msg_ruler")) return .msg_ruler;
        if (std.mem.eql(u8, s, "msg_history_show")) return .msg_history_show;
        return null;
    }
};

/// Where a routed message is displayed. Values are part of the C ABI
/// (`zonvie_msg_view_type` in include/zonvie_core.h) and must not be renumbered.
pub const MsgViewType = enum(u8) {
    mini = 0,
    ext_float = 1,
    confirm = 2,
    split = 3,
    none = 4,
    notification = 5,

    pub fn fromString(s: []const u8) ?MsgViewType {
        if (std.mem.eql(u8, s, "mini")) return .mini;
        if (std.mem.eql(u8, s, "ext-float")) return .ext_float;
        if (std.mem.eql(u8, s, "confirm")) return .confirm;
        if (std.mem.eql(u8, s, "split")) return .split;
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "notification")) return .notification;
        return null;
    }
};

/// Severity derived from a msg_show `kind`. Mirrors noice `ui/msg.lua:67-73`.
pub const MsgLevel = enum { info, warn, err };

pub fn levelForKind(kind: []const u8) MsgLevel {
    if (std.mem.eql(u8, kind, "emsg") or
        std.mem.eql(u8, kind, "echoerr") or
        std.mem.eql(u8, kind, "lua_error") or
        std.mem.eql(u8, kind, "rpc_error")) return .err;
    if (std.mem.eql(u8, kind, "wmsg")) return .warn;
    return .info;
}

/// `return_prompt` never reaches a view. noice answers it immediately at the
/// event layer with a single `nvim_input("<cr>")` (`ui/msg.lua:86-87,149-151`)
/// instead of routing it, which is also what keeps the CR from being sent twice.
pub fn isReturnPrompt(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "return_prompt");
}

/// A route predicate. All present fields must match (logical AND); absent
/// fields match anything.
pub const MsgFilter = struct {
    event: ?MsgEvent = null,
    kinds: ?[]const []const u8 = null,
    min_height: ?u32 = null,
    max_height: ?u32 = null,
    level: ?MsgLevel = null,

    pub fn matches(self: MsgFilter, event: MsgEvent, kind: []const u8, line_count: u32) bool {
        if (self.event) |e| {
            if (e != event) return false;
        }
        if (self.min_height) |min| {
            if (line_count < min) return false;
        }
        if (self.max_height) |max| {
            if (line_count > max) return false;
        }
        if (self.level) |lv| {
            if (lv != levelForKind(kind)) return false;
        }
        if (self.kinds) |ks| {
            for (ks) |k| {
                if (std.mem.eql(u8, k, kind)) break;
            } else return false;
        }
        return true;
    }
};

pub const RouteOpts = struct {
    /// Explicitly do not display. Distinct from "no route matched", which
    /// cannot occur.
    skip: bool = false,
    /// Seconds before auto-hide. null = view default, 0 = never auto-hide.
    timeout: ?f32 = null,
};

pub const MsgRoute = struct {
    filter: MsgFilter = .{},
    view: MsgViewType = .ext_float,
    opts: RouteOpts = .{},
};

/// Named view settings the default routes read. Mirrors noice
/// `config/init.lua:39-43`. Zonvie's centre of gravity is the external float
/// window, so `view` and the error/warning views default to `ext_float`
/// where noice defaults to `notify`.
pub const ViewSettings = struct {
    view: MsgViewType = .ext_float,
    view_error: MsgViewType = .ext_float,
    view_warn: MsgViewType = .ext_float,
    view_history: MsgViewType = .split,
    view_search: MsgViewType = .mini,
};

pub const RouteResult = struct {
    view: MsgViewType,
    timeout: f32,
    /// True when a route matched with `skip`. Callers must not display.
    skip: bool,
};

/// Timeout for the transient views when a route does not override it.
pub const default_timeout_sec: f32 = 4.0;

/// Per-view auto-hide default, overridable by a route's `timeout`. noice keeps
/// this on the view rather than the route (`config/views.lua:170` gives `mini`
/// a timeout; `split` and `popup` have none), so a message routed to a view
/// meant to be read does not vanish on its own.
pub fn viewDefaultTimeout(view: MsgViewType) f32 {
    return switch (view) {
        .mini, .ext_float => default_timeout_sec,
        .split, .confirm, .notification, .none => 0,
    };
}

/// Number of built-in default routes.
pub const default_route_count = 9;

/// Build the default route tail. Depends on `views`, so it is a function
/// rather than a constant; the result lives on the caller's stack.
pub fn defaultRoutes(views: ViewSettings) [default_route_count]MsgRoute {
    return .{
        // Interactive prompts. Kept ahead of everything else because routing
        // them anywhere but `confirm` loses the ability to answer them.
        .{
            .filter = .{ .event = .msg_show, .kinds = &.{ "confirm", "confirm_sub", "number_prompt" } },
            .view = .confirm,
            .opts = .{ .timeout = 0 },
        },
        .{ .filter = .{ .event = .msg_history_show }, .view = views.view_history, .opts = .{ .timeout = 0 } },
        .{
            .filter = .{ .event = .msg_show, .kinds = &.{"search_count"} },
            .view = views.view_search,
            .opts = .{ .timeout = 2.0 },
        },
        // Errors never auto-hide.
        .{ .filter = .{ .event = .msg_show, .level = .err }, .view = views.view_error, .opts = .{ .timeout = 0 } },
        .{ .filter = .{ .event = .msg_show, .level = .warn }, .view = views.view_warn },
        .{ .filter = .{ .event = .msg_showmode }, .view = .mini },
        .{ .filter = .{ .event = .msg_showcmd }, .view = .mini },
        .{ .filter = .{ .event = .msg_ruler }, .view = .mini },
        // Catch-all. Guarantees every message reaches a view, so "unmatched"
        // is not a reachable state.
        .{ .filter = .{}, .view = views.view },
    };
}

/// Routes messages to views. User routes are consulted first, then the
/// defaults; the first match wins.
pub const Router = struct {
    /// Borrowed. Owned and freed by the config layer.
    user_routes: []const MsgRoute = &.{},
    views: ViewSettings = .{},

    pub fn route(self: Router, event: MsgEvent, kind: []const u8, line_count: u32) RouteResult {
        for (self.user_routes) |r| {
            if (r.filter.matches(event, kind, line_count)) return resolve(r);
        }
        const defaults = defaultRoutes(self.views);
        for (defaults) |r| {
            if (r.filter.matches(event, kind, line_count)) return resolve(r);
        }
        unreachable; // the default tail has an empty filter
    }

    fn resolve(r: MsgRoute) RouteResult {
        const view: MsgViewType = if (r.opts.skip) .none else r.view;
        return .{
            .view = view,
            .timeout = r.opts.timeout orelse viewDefaultTimeout(view),
            .skip = r.opts.skip,
        };
    }
};
