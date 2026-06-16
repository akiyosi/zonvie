# Testing Guide

This document describes how to run and maintain tests in Zonvie.

## Overview

Zonvie has three test suites:

- **Unit tests** (`zig build test`) — Core library tests
- **E2E tests** (`zig build e2e`) — End-to-end Neovim integration tests
- **GUI tests** (`zig build gui-test`) — Visual regression tests (requires display)

## Running Tests Locally

### All Tests
```bash
zig build test
```

### E2E Tests
```bash
zig build e2e --summary all
```

Measures:
- Callback ordering correctness
- Viewport calculation stability
- Font initialization order
- Ligature caching performance
- Floating window lifecycle

Requires a running `nvim` instance (or `ZONVIE_TEST_NVIM` env var set to the path).

### GUI Visual Tests
```bash
zig build gui-test --summary all
```

Captures:
- Float border continuity
- Pop-up menu selection bounds
- Vertical cursor width
- Command-line cursor animation
- Emoji cursor width

**Note**: Requires display support (macOS/Windows native windowing). In CI, tests are skipped gracefully.

### Regenerating Visual Goldens
On a known-good build:
```bash
ZONVIE_GUI_UPDATE_GOLDEN=1 zig build gui-test --summary all
```

This regenerates the golden reference images in `test/gui/golden/<os>/` for the current platform.
Goldens are environment-specific (font rendering, DPI) and **must** be regenerated when:
- Font metrics change
- DPI/scaling changes
- Platform code changes (Metal, D3D11, DWrite, FreeType)

Goldens are gitignored; each developer maintains their own for their environment.

## Test Organization

### Phase 1: Critical Correctness (Complete)
- Flush callback ordering
- Viewport calculation independence
- Font initialization sequence
- Basic scroll/navigation
- Window lifecycle

### Phase 2: Visual Regression (In Progress)
- Float borders and compositing
- Pop-up menu clipping
- Cursor width with ligatures/emoji
- Command-line animation frames

### Phase 3: Polish & Edge Cases (Future)
- Diagnostics rendering
- Scroll animation smoothness
- Multi-grid pane interactions
- IME preedit rendering

## CI Integration

GitHub Actions runs:
1. **Linux unit tests** — `zig build test`
2. **macOS E2E** — `zig build e2e --summary all`
3. **Windows cross-compile** — `zig build windows -Dtarget=x86_64-windows-gnu`

See `.github/workflows/test.yml` for full configuration.

## Debugging Test Failures

### E2E Failures
1. Check harness logs in stderr
2. Look for grid ID, row/col assertions
3. Verify `nvim` is running and responding
4. Check `ZONVIE_TEST_NVIM` if tests can't find the binary

### GUI Visual Failures
1. Check `tmp/` directory for `actual.png` and `diff.png` on test failure
2. Regenerate golden with `ZONVIE_GUI_UPDATE_GOLDEN=1` if expected
3. Verify window capture on platform (macOS/Windows only; Linux skips)

## Adding New Tests

### E2E Scenario
Create `test/e2e/scenarios/your_test.zig`:
```zig
const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    
    const g = h.winGrid();
    
    try h.command("set option=value");
    try h.input("normal command");
    try h.waitRowText(g, 0, "expected", h.opts.timeout_ms);
    // Assert test invariants
}
```

Register in `test/e2e/runner.zig` scenarios list.

### GUI Visual Scenario
Create `test/gui/scenarios/visual/your_test.zig`:
```zig
const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();
    
    // Set up test state
    try g.exec("command");
    
    var img = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img.deinit(alloc);
    try visual.assertMatch(alloc, "test_name", img, .{});
}
```

Register in `test/gui/scenarios/visual.zig` scenarios list.

## Performance Considerations

E2E tests should complete in ~10-30 seconds total. If a single scenario exceeds 30s:
1. Profile with longer timeouts disabled
2. Check for Neovim I/O bottlenecks
3. Reduce buffer size if testing scales

GUI tests skip on headless (CI). Local runs depend on display performance.
