# zonvie AI-agent tab status

Show whether an AI coding agent (Claude Code, Codex, …) running inside a Neovim
`:terminal` is currently working, as a glyph on the zonvie ext_tabline tab.

```
┌──────────────┬──────────────────┬───────────┐
│ ● term://claude │ term://codex   │ main.zig  │   ← ● = agent working
└──────────────┴──────────────────┴───────────┘
```

## How it works

The agent CLI sets its terminal's OSC window title. While thinking it animates a
Braille spinner (`⠋⠙⠹…`, U+2800–U+28FF) as the leading glyph; when idle it shows
a static marker (Claude: `✳`, Codex: bare title). `zonvie_agent_status.lua`
captures the title via the `TermRequest` autocmd, classifies the first codepoint,
and broadcasts `working`/`idle` per tabpage to zonvie with
`vim.rpcnotify(0, "zonvie_agent_status", …)`. zonvie's core prefixes `● ` to the
working tab's label (no agent-side configuration required).

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

- Only **working ↔ idle** is distinguishable from the OSC title. "Waiting for
  user input" stops the spinner and is therefore reported as idle. Distinguishing
  it would require agent-side hooks (Claude Code `Notification`/`Stop`), a
  separate, opt-in mechanism.
- The glyph is plain text on the tab label; it is not colored.
