-- zonvie AI-agent tab status reporter.
--
-- Shows whether an AI coding agent (Claude Code, Codex, ...) running inside a
-- :terminal is currently working, as a glyph on the zonvie ext_tabline tab.
--
-- How it works (zero agent-side configuration):
--   The agent CLI writes an OSC window title into its terminal. While the agent
--   is thinking it animates a Braille spinner as the leading glyph; when idle it
--   shows a static marker (Claude: U+2733, Codex: bare title). We classify the
--   title's first codepoint and broadcast working/idle per tabpage to zonvie,
--   which prefixes a "U+25CF" dot to the working tab's label.
--
-- Limitations:
--   * Only working <-> idle is distinguishable via OSC. "Waiting for user input"
--     looks identical to idle (the spinner stops), so it is reported as idle.
--   * The tabline must be visible to see the glyph (e.g. `set showtabline=2`).
--
-- Install: place on your runtimepath and call:
--   require("zonvie_agent_status").setup()
local M = {}

local last = {} -- tabpage handle -> last reported status ("working"/"idle")

local function status_from_title(title)
  if not title or title == "" then return "idle" end
  local cp = vim.fn.char2nr(title) -- codepoint of the first character
  -- Braille Patterns block: every agent CLI animates its spinner from here.
  if cp >= 0x2800 and cp <= 0x28FF then return "working" end
  return "idle"
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

local function report(tab, status, title)
  if last[tab] == status then return end -- debounce spinner-frame churn
  last[tab] = status
  -- Broadcast to all RPC channels; zonvie's UI channel handles it.
  vim.rpcnotify(0, "zonvie_agent_status", { tab = tab, status = status, title = title })
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
      local status = status_from_title(body)
      for _, tab in ipairs(tabs_for_buf(ev.buf)) do
        report(tab, status, body)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TermClose", {
    callback = function(ev)
      for _, tab in ipairs(tabs_for_buf(ev.buf)) do
        report(tab, "idle", nil)
      end
    end,
  })
end

return M
