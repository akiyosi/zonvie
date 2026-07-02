// agent_status_notify — the OS-notification flag (bit 7 of the
// on_agent_status wire state) actually reaches the frontend for every
// notify-worthy transition, including the cases the macOS/Windows edge
// detection used to miss before it moved into the core Lua reporter:
//   - the agent's terminal buffer is hidden when it finishes (RC1)
//   - the "needs input" prompt renders late, after the first done-vs-waiting
//     scrape (RC2, the second-chance re-scrape)
//
// No real AI agent is needed: a `:terminal`-backed shell script emits the
// same OSC 0 title sequences an agent CLI does (Braille spinner -> Claude's
// idle marker) and, for the waiting-for-input cases, prints the plain
// English menu-chrome text `waiting_prompt` (rpc_session.zig) scrapes for.
// Each script ends with a trailing `sleep` past the relevant decision delay
// (800ms, or +1.7s more for the second-chance re-scrape) -- the job exiting
// fires TermClose, which reports state 0 unconditionally and (by bumping
// the reporter's `pend` token) cancels any still-pending decide_stopped,
// so ending the script too early would race the notification away.
//
// Lua code below is a Zig raw multiline string sent verbatim (no Zig escape
// processing -- see requestExecLua) as Lua *source text* to nvim_exec_lua,
// so `\\033`/`\\007` (written with two backslashes here) are needed to
// produce a Lua *runtime* string containing a literal single backslash +
// "033"/"007" -- the octal escapes the spawned shell's own `printf` then
// interprets as ESC/BEL. This mirrors the escaping in setupAgentStatus's
// injected reporter (e.g. `\27%]0;` there wants Lua to see the escape
// directly; here we want Lua to pass it through untouched to the shell).

const std = @import("std");
const Harness = @import("../harness.zig").Harness;
const AgentEvent = @import("../harness.zig").AgentEvent;

fn flagged(e: AgentEvent, base: u8) bool {
    return (e.state & 0x80) != 0 and (e.state & 0x7f) == base;
}
fn isWorking(e: AgentEvent) bool {
    return (e.state & 0x80) == 0 and e.state == 3;
}
fn isFlaggedFinished(e: AgentEvent) bool {
    return flagged(e, 1);
}
fn isFlaggedWaiting(e: AgentEvent) bool {
    return flagged(e, 4);
}

pub fn run(alloc: std.mem.Allocator) !void {
    try testVisibleFinish(alloc);
    try testHiddenFinish(alloc);
    try testNeedsInput(alloc);
    try testLatePrompt(alloc);
}

// Case 1: agent finishes while its terminal is the visible window -> a
// flagged (bit 7) base-1 ("finished") report must arrive.
fn testVisibleFinish(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.core.requestExecLua(
        \\vim.cmd('enew')
        \\vim.fn.termopen("printf '\\033]0;⠋ working\\007'; sleep 0.3; printf '\\033]0;✳ done\\007'; sleep 1.2")
    );
    try h.waitAgentStatus(isWorking, 3000);
    try h.waitAgentStatus(isFlaggedFinished, 3000);
}

// Case 2 (RC1): the terminal's window is switched to another buffer
// (`:enew`, hiding the agent's terminal) before it finishes. The completion
// report must still reach the frontend via the buftab[] fallback -- before
// the fix, tabs_for_buf() returned empty for a hidden buffer and the
// completion silently went nowhere.
fn testHiddenFinish(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.core.requestExecLua(
        \\vim.cmd('enew')
        \\vim.fn.termopen("printf '\\033]0;⠋ working\\007'; sleep 1.0; printf '\\033]0;✳ done\\007'; sleep 1.2")
    );
    try h.waitAgentStatus(isWorking, 3000);
    try h.command("enew"); // hide the terminal buffer in its only window
    try h.waitAgentStatus(isFlaggedFinished, 5000);
}

// Case 3 (RC2): the decision-prompt menu chrome is already on screen by the
// time the 800ms done-vs-waiting scrape runs -> a flagged base-4 ("needs
// input") report, not "finished".
fn testNeedsInput(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.core.requestExecLua(
        \\vim.cmd('enew')
        \\vim.fn.termopen("printf '\\033]0;⠋ working\\007'; sleep 0.3; echo 'Do you want to proceed?'; printf '\\033]0;✳ done\\007'; sleep 1.2")
    );
    try h.waitAgentStatus(isWorking, 3000);
    try h.waitAgentStatus(isFlaggedWaiting, 3000);
}

// Case 4 (RC2 second chance): the prompt renders too late for the first
// 800ms scrape (idle title flips immediately, so that scrape reports
// "finished") but arrives before the +1.7s second-chance re-scrape, which
// must upgrade to a flagged base-4 ("needs input") report.
fn testLatePrompt(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.core.requestExecLua(
        \\vim.cmd('enew')
        \\vim.fn.termopen("printf '\\033]0;⠋ working\\007'; sleep 0.3; printf '\\033]0;✳ done\\007'; sleep 1.2; echo 'Do you want to proceed?'; sleep 1.5")
    );
    try h.waitAgentStatus(isWorking, 3000);
    try h.waitAgentStatus(isFlaggedFinished, 3000);
    try h.waitAgentStatus(isFlaggedWaiting, 6000);
}
