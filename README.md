# Zonvie

<img src="zonvie.png" width="100" height="100" alt="Zonvie">

Zonvie is a Fast, feature-rich Neovim GUI built with Zig, native on macOS and Windows.

## Features

- **Native Performance**: Zig core with Metal (macOS) and D3D11 (Windows) rendering
- **Zero-allocation Hot Paths**: Optimized for minimal latency during redraw/flush
- **Full Neovim UI API Compliance**: Supports ext_cmdline, ext_popupmenu, ext_messages, ext_tabline
- **Remote Development**:
  - SSH connection to remote hosts
  - Devcontainer support for containerized development environments
- **Customizable**: TOML configuration file

## Roadmap

| # | Step | Status |
|---|------|--------|
| 1 | Standard Neovim GUI functionality | ✅ |
| 2 | Multigrid Events compliance and rich window integration | ⚠️ |
| 3 | Basic customization (fonts, colors, blur, variable fonts, etc.) | ✅ |
| 4 | Cross-platform (macOS, Windows, Linux) | ⚠️ |
| 5 | Remote connection (SSH, server mode, devcontainer) | ⚠️ |
| 6 | Fancy features (cursor animation, neon/glow, smooth scroll, etc.) | ⚠️ |

## Platforms

- **macOS**: AppKit + Swift + Metal
- **Windows**: Win32 + D3D11/DXGI + DirectWrite

## Installation

### macOS

Build from source (requires Xcode):

```bash
xcodebuild -project macos/zonvie.xcodeproj -scheme zonvie -configuration Release build
```

### Windows

Build from source (requires Zig 0.15.x):

```bash
zig build windows -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

## Usage

```bash
zonvie [OPTIONS] [--] [NVIM_ARGS...]
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `--nofork` | Don't fork; stay attached to terminal, keep cwd |
| `--nvim <path>` | Path to Neovim executable (overrides config) |
| `--log <path>` | Write application logs to specified file path |
| `--extcmdline` | Enable external command line UI |
| `--extpopup` | Enable external popup menu UI |
| `--extmessages` | Enable external messages UI |
| `--exttabline` | Enable external tabline UI |
| `--extwindows` | Enable external windows (each Neovim window as OS window) |
| `--ssh=<user@host[:port]>` | Connect to remote host via SSH |
| `--ssh-identity=<path>` | Path to SSH private key file |
| `--devcontainer=<workspace>` | Run inside a devcontainer |
| `--devcontainer-config=<path>` | Path to devcontainer.json |
| `--devcontainer-rebuild` | Rebuild devcontainer before starting |
| `--connect-nvim=<addr>` | Attach to a running Neovim server. Address: POSIX (macOS/Linux) — TCP `host:port` or Unix socket path; Windows — named pipe path (e.g. `\\.\pipe\nvim.31920.0`). Mutually exclusive with `--ssh` / `--devcontainer` / `--wsl`. |
| `--remote-ui=<addr>` | Alias of `--connect-nvim`, mirrors `nvim --remote-ui` |
| `--install` | Create default config file and exit |
| `--` | Pass all remaining arguments to nvim |
| `--help`, `-h` | Show help message |

### Examples

```bash
# Open a file
zonvie file.txt

# Use custom nvim config
zonvie -- -u ~/.config/nvim/minimal.lua

# Connect to remote host via SSH
zonvie --ssh=user@example.com

# Run in devcontainer
zonvie --devcontainer=/path/to/project

# Attach to a Neovim server already running (e.g. started elsewhere with
# `nvim --headless --listen /tmp/nvim.sock` or `:detach`'d from another UI)
zonvie --connect-nvim=/tmp/nvim.sock          # POSIX: Unix socket
zonvie --connect-nvim=127.0.0.1:6789          # POSIX: TCP
zonvie --connect-nvim=\\.\pipe\nvim.31920.0  # Windows: named pipe
```

## Configuration

Configuration file location:
- `~/.config/zonvie/config.toml`
- Or `$XDG_CONFIG_HOME/zonvie/config.toml`

### Example Configuration

```toml
[neovim]
path = "nvim"
wsl = false
wsl_distro = "Ubuntu"
ssh = false
ssh_host = "user@example.com"
ssh_port = 22
ssh_identity = "~/.ssh/id_rsa"

[font]
family = "JetBrains Mono"
size = 14
linespace = 2

[window]
blur = true
opacity = 0.85
blur_radius = 20

[scrollbar]
enabled = true
show_mode = "scroll"  # "always", "hover", "scroll", or combinations like "hover,scroll"
opacity = 0.7
delay = 1.0

[cmdline]
external = true

[popup]
external = true

[messages]
external = true
msg_pos = { ext-float = "window", mini = "grid" }  # display, window, or grid

# Message routing rules (processed in order, first match wins)
[[messages.routes]]
event = "msg_show"
kind = ["emsg", "echoerr", "lua_error", "rpc_error"]
view = "ext-float"
timeout = 0  # 0 = no auto-hide

[[messages.routes]]
event = "msg_show"
kind = ["wmsg"]
view = "ext-float"
timeout = 4.0

[[messages.routes]]
event = "msg_show"
kind = ["search_count"]
view = "mini"
timeout = 2.0

[[messages.routes]]
event = "msg_show"
view = "ext-float"  # fallback for other msg_show

[[messages.routes]]
event = "msg_showmode"
view = "mini"

[[messages.routes]]
event = "msg_showcmd"
view = "mini"

[[messages.routes]]
event = "msg_ruler"
view = "mini"

[[messages.routes]]
event = "msg_history_show"
view = "split"

[tabline]
external = true
style = "titlebar"  # "titlebar", "menu", or "sidebar"
sidebar_position = "left"  # "left" or "right" (for sidebar style)
sidebar_width = 200  # 100-500 (for sidebar style)

[windows]
external = false  # Each Neovim window as a separate OS window

[log]
enabled = false
path = "/tmp/zonvie.log"

[performance]
glyph_cache_ascii_size = 512
glyph_cache_non_ascii_size = 256
hl_cache_size = 2048
shape_cache_size = 4096
atlas_size = 2048

[ime]
disable_on_activate = false
disable_on_modechange = false
option_as_meta = "both"  # "both", "none", "only_left", "only_right"
preedit_mode = "overlay"  # "overlay" (floating overlay) or "extmark" (inline virt_text)

[input]
swap_colon_semicolon = false  # swap the `:` and `;` keys (single keypresses only)

[shaders]
enabled = false
post_process = "after_bloom"  # only "after_bloom" is implemented today
# Drop-in compatible with Shadertoy / Ghostty GLSL shaders. Multiple
# entries form a chain: each shader's output feeds the next; the
# final pass writes to the swapchain. Paths MUST be absolute — they
# are opened verbatim, so launches from Finder / Explorer (whose
# CWD is set to the system root) won't find relative entries.
paths = [
    # "/absolute/path/to/your/ghostty-shaders/starfield.glsl",
    # "/absolute/path/to/your/ghostty-shaders/cursor_blaze.glsl",
]
```

### Configuration Options

#### [neovim]
| Key | Description |
|-----|-------------|
| `path` | Path to Neovim executable |
| `wsl` | Enable WSL mode on Windows (true/false) |
| `wsl_distro` | WSL distribution name |
| `ssh` | Enable SSH mode (true/false) |
| `ssh_host` | SSH host (user@host format) |
| `ssh_port` | SSH port number |
| `ssh_identity` | Path to SSH private key |

#### [font]
| Key | Description |
|-----|-------------|
| `family` | Font family name |
| `size` | Font size in points |
| `linespace` | Extra line spacing in pixels |

#### [window]
| Key | Description |
|-----|-------------|
| `blur` | Enable blur effect (true/false) |
| `opacity` | Background opacity (0.0-1.0, when blur=true) |
| `blur_radius` | Blur radius (1-100, when blur=true) |

#### [scrollbar]
| Key | Description |
|-----|-------------|
| `enabled` | Show scrollbar (true/false) |
| `show_mode` | When to show: "always", "hover", "scroll", or combinations like "hover,scroll" |
| `opacity` | Scrollbar opacity (0.0-1.0) |
| `delay` | Delay in seconds before hiding (0.1-10.0, for "scroll" mode) |

#### [cmdline]
| Key | Description |
|-----|-------------|
| `external` | Use external command line UI (true/false) |

#### [popup]
| Key | Description |
|-----|-------------|
| `external` | Use external popup menu UI (true/false) |

#### [messages]
| Key | Description |
|-----|-------------|
| `external` | Use external messages UI (true/false) |
| `msg_pos` | Position anchor for message views: `{ ext-float = "...", mini = "..." }`. Values: "display", "window", "grid" |

##### [[messages.routes]]

Message routing rules are processed in order; first match wins.

| Key | Description |
|-----|-------------|
| `event` | Event type: "msg_show", "msg_showmode", "msg_showcmd", "msg_ruler", "msg_history_show" |
| `kind` | Array of message kinds to match (optional, omit to match all). Kinds: "emsg", "echoerr", "lua_error", "rpc_error", "wmsg", "search_count", "confirm", "confirm_sub", "return_prompt", etc. |
| `view` | View type: "mini", "ext-float", "confirm", "split", "none", "notification" |
| `timeout` | Auto-hide timeout in seconds (optional, 0 = no auto-hide) |
| `min_height` | Minimum line count to match (optional) |
| `max_height` | Maximum line count to match (optional) |
| `auto_dismiss` | Auto-dismiss return_prompt by sending \<CR\> (optional, default depends on view) |

#### [tabline]
| Key | Description |
|-----|-------------|
| `external` | Use external tabline UI (true/false) |
| `style` | Tabline style: "titlebar", "menu", or "sidebar" |
| `sidebar_position` | Sidebar position: "left" or "right" (for sidebar style) |
| `sidebar_width` | Sidebar width in pixels (100-500, for sidebar style) |

#### [windows]
| Key | Description |
|-----|-------------|
| `external` | Each Neovim window as a separate OS window (true/false) |

#### [log]
| Key | Description |
|-----|-------------|
| `enabled` | Enable logging (true/false) |
| `path` | Log file path |

#### [performance]
| Key | Description |
|-----|-------------|
| `glyph_cache_ascii_size` | Cache size for ASCII glyphs (min: 128, default: 512) |
| `glyph_cache_non_ascii_size` | Cache size for non-ASCII glyphs (min: 64, default: 256) |
| `hl_cache_size` | Highlight attribute cache size for vertex generation (range: 64-2048, default: 2048) |
| `shape_cache_size` | Text shaping result cache size (range: 512-65536, default: 4096) |
| `atlas_size` | Glyph atlas texture size in pixels (range: 1024-4096, default: 2048) |

#### [ime]
| Key | Description |
|-----|-------------|
| `disable_on_activate` | Disable IME when app becomes active (true/false) |
| `disable_on_modechange` | Disable IME on Vim mode change (true/false) |
| `option_as_meta` | Map Option key as Meta: "both", "none", "only_left", "only_right" |
| `preedit_mode` | IME preedit display: "overlay" (floating overlay) or "extmark" (inline virt_text that shifts following text; falls back to overlay outside insert/replace) |

#### [input]
| Key | Description |
|-----|-------------|
| `swap_colon_semicolon` | Swap the `:` and `;` keys (true/false). Applies to single keypresses only; pasted text and IME commits are unaffected |

#### [shaders]
| Key | Description |
|-----|-------------|
| `enabled` | Enable user-supplied custom GLSL post-process shaders (true/false) |
| `post_process` | Where the chain runs: `"after_bloom"` (only implemented mode); `"before_bloom"` / `"replace_bloom"` are accepted but warn + fall back to `after_bloom` |
| `paths` | Array of GLSL file paths. **Absolute paths only** — entries are opened verbatim, so launches from Finder / Explorer break with relative paths. Multiple entries form a chain: each pass's output feeds the next; the final pass writes to the swapchain. Drop-in compatible with Shadertoy / Ghostty shader source. |

Supported uniforms (Shadertoy + Ghostty 1.1+):
`iResolution`, `iTime`, `iTimeDelta`, `iFrame`, `iFrameRate`, `iSampleRate`,
`iDate`, `iWindowOffset`, `iWindowSize` (drop-in for ext windows),
`iCurrentCursor`, `iPreviousCursor`, `iCurrentCursorColor`,
`iPreviousCursorColor`, `iTimeCursorChange`. `iMouse` is reserved but
currently unimplemented (always zero).

`iChannel0` aliases the terminal contents (back buffer) so existing
Ghostty / Shadertoy shaders that sample `texture(iChannel0, uv)`
work without modification.

## Neovim Integration

Zonvie exposes several Neovim-side variables and RPC notifications for runtime customization.

### vim.g.zonvie_channel

Set automatically on startup. Contains the RPC channel ID for communication with Zonvie.

### vim.g.zonvie_glow (Neon Glow Effect)

Configure a bloom/glow post-processing effect for specific highlight groups:

```lua
vim.g.zonvie_glow = {
  groups = { "Keyword", "String", "Function" },  -- or "all" for every cell
  radius = 6,       -- blur radius in pixels (2-16)
  intensity = 0.8,  -- glow brightness (0.0-1.0)
}
```

Zonvie reads this variable on startup (with automatic retry for lazy plugin initialization) and applies a Dual Kawase bloom shader to matching highlight groups.

### zonvie_option_as_meta (RPC notification)

Dynamically change the Option-as-Meta behavior at runtime, equivalent to Neovim-Qt's `macmeta` option:

```lua
vim.rpcnotify(vim.g.zonvie_channel, "zonvie_option_as_meta", "both")
-- Values: "both", "none", "only_left", "only_right"
```

This can also be set statically via the `[ime] option_as_meta` config key.

### zonvie_ime_off (RPC notification)

Programmatically disable the IME input method:

```lua
vim.rpcnotify(vim.g.zonvie_channel, "zonvie_ime_off")
```

Useful for automatically switching off IME when entering normal mode via autocommands.

## License

MIT License
