#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Map Xcode ARCHS env to Zig target triple (set by xcodebuild)
ZIG_TARGET_FLAG=""
case "${ARCHS:-}" in
    x86_64) ZIG_TARGET_FLAG="-Dtarget=x86_64-macos" ;;
    arm64)  ZIG_TARGET_FLAG="-Dtarget=aarch64-macos" ;;
esac

cd "$ROOT_DIR"
zig build core -Doptimize=Debug $ZIG_TARGET_FLAG

# copy for XCode
mkdir -p "$ROOT_DIR/macos/Vendor/zig-out"
rsync -a --delete "$ROOT_DIR/zig-out/" "$ROOT_DIR/macos/Vendor/zig-out/"

