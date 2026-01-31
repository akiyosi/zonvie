# Development Guide

This document covers setting up a development environment and building Zonvie.

## Prerequisites

### Common
- **Zig 0.15.x**: Required for building the core and Windows frontend
- **Git**: For version control

### macOS
- **Xcode**: For Swift/Metal frontend development
- **Command Line Tools**: `xcode-select --install`

### Windows
- **Windows SDK**: For Win32/D3D11 development
- **Visual Studio Build Tools** (optional): For debugging

## Repository Structure

```
zonvie/
├── include/                 # C ABI headers
│   ├── zonvie_core.h       # Core API + callback contracts
│   └── zonvie_hbft.h       # HarfBuzz/FreeType helper API
├── src/
│   └── shared/             # Zig core (cross-platform)
│       ├── nvim_core.zig   # Neovim RPC/UI event handling
│       ├── grid.zig        # Grid state management
│       ├── redraw_handler.zig
│       ├── vertexgen.zig   # GPU vertex generation
│       ├── config.zig      # Configuration parsing
│       └── c_api.zig       # C ABI exports
├── macos/                  # macOS frontend (Swift/Metal)
│   ├── Sources/
│   │   ├── main.swift
│   │   ├── AppDelegate.swift
│   │   ├── ViewController.swift
│   │   ├── ZonvieCore.swift
│   │   └── MetalTerminalRenderer.swift
│   └── zonvie.xcodeproj
├── windows/                # Windows frontend (Zig/D3D11)
│   ├── main.zig
│   ├── d3d11_renderer.zig
│   └── dwrite_d2d_renderer.zig
└── build.zig              # Zig build system
```

## Building

### macOS (Debug)

```bash
# Build Zig core library
zig build

# Build macOS app
xcodebuild -project macos/zonvie.xcodeproj \
  -scheme zonvie \
  -configuration Debug \
  -derivedDataPath macos/.derived \
  -destination "platform=macOS,arch=arm64" \
  build
```

The app will be at `macos/.derived/Build/Products/Debug/zonvie.app`.

### macOS (Release)

```bash
xcodebuild -project macos/zonvie.xcodeproj \
  -scheme zonvie \
  -configuration Release \
  build
```

### Windows

```bash
# x86_64
zig build windows -Dtarget=x86_64-windows-gnu

# With optimizations
zig build windows -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

Output will be in `zig-out/bin/`.

## Architecture Overview

Zonvie follows a layered architecture with a shared Zig core and platform-specific frontends.

### Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        Frontend (UI Layer)                      │
│  macOS: AppKit + Swift + Metal                                  │
│  Windows: Win32 + D3D11/DXGI + DirectWrite                      │
└───────────────────────────┬─────────────────────────────────────┘
                            │ C ABI (include/zonvie_core.h)
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Zig Core (src/shared/)                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │  nvim_core   │→ │    grid      │→ │     vertexgen        │   │
│  │  (RPC/MsgPack)  │  (state mgmt)│  │  (GPU vertex gen)    │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│         │                                       │               │
│         ▼                                       ▼               │
│  ┌──────────────┐                    ┌──────────────────────┐   │
│  │redraw_handler│                    │   HarfBuzz/FreeType  │   │
│  │ (UI events)  │                    │   (glyph shaping)    │   │
│  └──────────────┘                    └──────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Components

| Component | Location | Responsibility |
|-----------|----------|----------------|
| **nvim_core** | `src/shared/nvim_core.zig` | Neovim process management, MsgPack RPC, UI event dispatch |
| **grid** | `src/shared/grid.zig` | Grid state (cells, highlights, cursor position) |
| **redraw_handler** | `src/shared/redraw_handler.zig` | Parse and apply Neovim `redraw` events to grid state |
| **vertexgen** | `src/shared/vertexgen.zig` | Convert grid state to GPU-ready vertex buffers |
| **c_api** | `src/shared/c_api.zig` | C ABI exports for frontend integration |
| **config** | `src/shared/config.zig` | TOML configuration parsing |

### Core ↔ Frontend Contract

The Zig core communicates with frontends via C ABI callbacks defined in `include/zonvie_core.h`:

```
Frontend                    Core (Zig)
   │                           │
   │  zonvie_core_create()     │
   │────────────────────────>  │
   │                           │
   │  zonvie_core_start()      │
   │────────────────────────>  │
   │                           │
   │  <── on_vertices_row()    │  (callback: submit GPU vertices)
   │  <── on_guifont()         │  (callback: font changed)
   │  <── on_exit()            │  (callback: nvim terminated)
   │                           │
   │  send_key_event()         │
   │────────────────────────>  │
   │                           │
   │  update_layout_px()       │
   │────────────────────────>  │
```

### Rendering Pipeline

1. **Neovim sends redraw events** via MsgPack RPC
2. **redraw_handler** parses events and updates grid state
3. **vertexgen** generates vertex data for changed regions
4. **Core invokes callbacks** to submit vertices to frontend
5. **Frontend renders** using Metal (macOS) or D3D11 (Windows)

## Debugging

### Enable Logging

```bash
# macOS
zonvie --log /tmp/zonvie.log

# Or in config.toml
[log]
enabled = true
path = "/tmp/zonvie.log"
```

### macOS Debug Build

The debug build includes:
- Xcode debugger support
- Metal validation layers
- Detailed logging


## Testing

### Manual Testing Checklist

- [ ] Basic text editing
- [ ] Cursor movement and rendering
- [ ] Window resize
- [ ] Font size change (`:set guifont=...`)
- [ ] External cmdline (`:` commands)
- [ ] External popup menu (completion)
- [ ] External messages
- [ ] SSH mode connection
- [ ] Devcontainer mode

