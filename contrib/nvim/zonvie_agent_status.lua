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
--   state: 0=none, 1=idle (agent present, done), 2=working/claude,
--          3=working/braille (codex & generic), 4=waiting for user input.
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
--
-- Install: place on your runtimepath and call:
--   require("zonvie_agent_status").setup()
local M = {}

-- state codes (see contract above)
local STATE_NONE = 0
local STATE_IDLE = 1
local STATE_WORKING = 3

local last = {} -- tabpage handle -> last reported state (integer)

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

local function report(tab, state, title)
  if last[tab] == state then return end -- debounce spinner-frame churn
  last[tab] = state
  -- Broadcast to all RPC channels; zonvie's UI channel handles it.
  vim.rpcnotify(0, "zonvie_agent_status", { tab = tab, state = state, title = title or "" })
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
      for _, tab in ipairs(tabs_for_buf(ev.buf)) do
        report(tab, state, body)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TermClose", {
    callback = function(ev)
      for _, tab in ipairs(tabs_for_buf(ev.buf)) do
        report(tab, STATE_NONE, nil)
      end
    end,
  })
end

return M
