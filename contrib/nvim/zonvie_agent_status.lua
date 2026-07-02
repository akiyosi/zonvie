-- zonvie AI-agent tab status reporter.
--
-- Shows whether an AI coding agent (Claude Code, Codex, ...) running inside a
-- :terminal is currently working, as a glyph on the zonvie ext_tabline tab.
--
-- How it works (zero agent-side configuration):
--   The agent CLI writes an OSC window title into its terminal. While the agent
--   is thinking it animates a Braille spinner as the leading glyph; when idle it
--   shows a static marker (Claude: U+2733, Codex: bare title). We classify the
--   title's first codepoint and broadcast a per-tabpage `state` to zonvie, which
--   owns the per-tab indicator glyph + spinner animation.
--
-- Payload contract (must match include/zonvie_core.h on_agent_status):
--   vim.rpcnotify(0, 'zonvie_agent_status', { tab = <int>, state = <int>, title = <str> })
--   Low 7 bits of state: 0=none, 1=idle (agent present, done), 2=working/claude,
--          3=working/braille (codex & generic), 4=waiting for user input.
--   Bit 7 (0x80) is a "fire the OS notification now" flag, set on a
--   working(3) -> idle(1) edge; zonvie renders the indicator from
--   `state & 0x7F` and requires the flag to fire a completion notification.
--
-- This is a readable, intentionally minimal reference. It reports only
-- 0/1/3 (none / idle / working). The auto-injected reporter that ships in the
-- zonvie core additionally distinguishes 2 (claude) and 4 (waiting for input).
--
-- Limitations:
--   * Working <-> idle is what OSC reliably exposes. "Waiting for user input"
--     (state 4) looks identical to idle here (the spinner stops), so this
--     reference reports it as idle.
--   * The tabline must be visible to see the glyph (e.g. `set showtabline=2`).
--   * Completion is edge-detected per buffer (not per tab, since a hidden
--     buffer keeps its identity); only the working(3) -> idle(1) edge is
--     flagged for a notification here (no waiting-for-input distinction).
--
-- Install: place on your runtimepath and call:
--   require("zonvie_agent_status").setup()
local M = {}

-- state codes (see contract above)
local STATE_NONE = 0
local STATE_IDLE = 1
local STATE_WORKING = 3

local last = {} -- tabpage handle -> last reported state (integer)
local bufstate = {} -- terminal buffer handle -> last working/idle state
local prevb = {} -- terminal buffer handle -> previous state, for the
-- working(3) -> idle(1) completion edge (per buffer, not per tab, since a
-- hidden buffer keeps its identity across tab/window switches).

local function state_from_title(title)
  if not title or title == "" then return STATE_IDLE end
  local cp = vim.fn.char2nr(title) -- codepoint of the first character
  -- Braille Patterns block: every agent CLI animates its spinner from here.
  if cp >= 0x2800 and cp <= 0x28FF then return STATE_WORKING end
  return STATE_IDLE
end

local function tabs_for_buf(buf)
  local out = {}
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(t)) do
      if vim.api.nvim_win_get_buf(w) == buf then
        out[#out + 1] = t
        break
      end
    end
  end
  return out
end

-- notify (bit 7 of the wire state) tells zonvie to fire its OS notification
-- now; it bypasses the debounce below since it must fire even if last[tab]
-- already equals state (e.g. the tab has been showing idle(1) since before
-- this buffer's own completion edge).
local function report(tab, state, title, notify)
  if not notify and last[tab] == state then return end -- debounce spinner-frame churn
  last[tab] = state
  -- Broadcast to all RPC channels; zonvie's UI channel handles it.
  vim.rpcnotify(0, "zonvie_agent_status",
    { tab = tab, state = notify and (state + 128) or state, title = title or "" })
end

-- The state a tab should show right now, from the terminal buffers currently
-- displayed in its windows (working wins over idle).
local function tab_state(tab)
  local best = STATE_NONE
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local s = bufstate[vim.api.nvim_win_get_buf(w)]
    if s and s > best then best = s end
  end
  return best
end

-- Re-derive every tab's indicator from the live window layout, so switching a
-- window away from the agent terminal drops the tab's stale indicator.
local function refresh_tabs()
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    report(t, tab_state(t), nil)
  end
end

function M.setup()
  vim.api.nvim_create_autocmd("TermRequest", {
    callback = function(ev)
      local seq = ev.data and ev.data.sequence or ""
      -- Only OSC 0/1/2 (window/icon title) carry the spinner/idle marker.
      local body = seq:match("^\27%]0;(.*)$")
        or seq:match("^\27%]1;(.*)$")
        or seq:match("^\27%]2;(.*)$")
      if not body then return end
      local state = state_from_title(body)
      bufstate[ev.buf] = state
      local notify = prevb[ev.buf] == STATE_WORKING and state == STATE_IDLE
      prevb[ev.buf] = state
      for _, tab in ipairs(tabs_for_buf(ev.buf)) do
        report(tab, state, body, notify)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TermClose", {
    callback = function(ev)
      bufstate[ev.buf] = nil
      prevb[ev.buf] = nil
      for _, tab in ipairs(tabs_for_buf(ev.buf)) do
        report(tab, STATE_NONE, nil)
      end
    end,
  })
  -- Agent state is latched per buffer but shown per tab, so re-derive a tab's
  -- indicator whenever its window layout changes.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWinLeave", "WinEnter", "WinClosed" }, {
    callback = function()
      vim.schedule(refresh_tabs)
    end,
  })
end

return M
