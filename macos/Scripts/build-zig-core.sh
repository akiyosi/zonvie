#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT_DIR"
zig build core -Doptimize=Debug

# copy for XCode
mkdir -p "$ROOT_DIR/macos/Vendor/zig-out"
rsync -a --delete "$ROOT_DIR/zig-out/" "$ROOT_DIR/macos/Vendor/zig-out/"

