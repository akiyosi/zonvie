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
| 3 | Basic customization (fonts, colors, blur, etc.) | ✅ |
| 4 | Cross-platform (macOS, Windows, Linux) | ⚠️ |
| 5 | Remote connection (SSH, server mode, devcontainer) | ⚠️ |
| 6 | Fancy features (cursor animation, neon/glow effects, etc.) | ❌ |

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
| `--log <path>` | Write application logs to specified file path |
| `--extcmdline` | Enable external command line UI |
| `--extpopup` | Enable external popup menu UI |
| `--extmessages` | Enable external messages UI |
| `--exttabline` | Enable external tabline UI (Chrome-style tabs) |
| `--ssh=<user@host[:port]>` | Connect to remote host via SSH |
| `--ssh-identity=<path>` | Path to SSH private key file |
| `--devcontainer=<workspace>` | Run inside a devcontainer |
| `--devcontainer-config=<path>` | Path to devcontainer.json |
| `--devcontainer-rebuild` | Rebuild devcontainer before starting |
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

[log]
enabled = false
path = "/tmp/zonvie.log"

[performance]
glyph_cache_ascii_size = 512
glyph_cache_non_ascii_size = 256
hl_cache_size = 512

[ime]
disable_on_activate = false
disable_on_modechange = false
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
| `hl_cache_size` | Highlight attribute cache size for vertex generation (range: 64-2048, default: 512) |

#### [ime]
| Key | Description |
|-----|-------------|
| `disable_on_activate` | Disable IME when app becomes active (true/false) |
| `disable_on_modechange` | Disable IME on Vim mode change (true/false) |

## License

MIT License
