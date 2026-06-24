# zonvie AI-agent tab status

Show whether an AI coding agent (Claude Code, Codex, …) running inside a Neovim
`:terminal` is currently working, as a glyph on the zonvie ext_tabline tab.

```
┌──────────────┬──────────────────┬───────────┐
│ ✶ term://claude │ 🤖 term://codex │ main.zig  │   ← spinner = working, 🤖 = idle, ⏸ = waiting
└──────────────┴──────────────────┴───────────┘
```

## How it works

The agent CLI sets its terminal's OSC window title. While thinking it animates a
Braille spinner (`⠋⠙⠹…`, U+2800–U+28FF) as the leading glyph; when idle it shows
a static marker (Claude: `✳`, Codex: bare title). `zonvie_agent_status.lua`
captures the title via the `TermRequest` autocmd, classifies the first codepoint,
and broadcasts a per-tabpage integer `state` to zonvie with
`vim.rpcnotify(0, "zonvie_agent_status", { tab = <int>, state = <int>, title = <str> })`.
zonvie's frontend owns the per-tab indicator glyph + spinner (no agent-side
configuration required). State codes (see `include/zonvie_core.h`): `0`=none,
`1`=idle, `2`=working/claude, `3`=working/braille, `4`=waiting for user input.

## Install

**Nothing to install.** zonvie auto-injects this reporter into the Neovim it
connects to (see `setupAgentStatus` in `src/core/rpc_session.zig`), so no
user-side config is required. Just make the tabline visible and run an agent:

```lua
vim.opt.showtabline = 2 -- so the tabline (and glyph) is always visible
```
```
:tabnew | terminal claude
```

> Do **not** add `require("zonvie_agent_status")` to your config — the module is
> not on your runtimepath and that line errors with E5108. The standalone file
> in this directory is only a readable reference / starting point if you want to
> customize the detection and load it yourself.

## Limitations

- The OSC title alone only exposes **working ↔ stopped** (the spinner stops for
  both "done" and "waiting for input"). The auto-injected reporter tells the two
  apart heuristically: ~0.8s after the spinner stops it scrapes the terminal tail
  for pending-prompt strings (`Do you want`, `Enter to select`, `[y/n]`, …) and
  reports `4`=waiting vs `1`=idle. The patterns are English-only and fragile by
  nature, so a missed prompt simply falls back to idle. The minimal reference file
  in this directory does **not** do this scrape and reports waiting as idle.
- The glyph is plain text on the tab label; it is not colored.
