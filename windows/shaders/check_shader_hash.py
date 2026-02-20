#!/usr/bin/env python3
"""
CI check: verify that compiled_shaders.zig is up-to-date with main.hlsl.

Computes SHA256 of main.hlsl (LF-normalized) and compares it against the
hlsl_sha256 constant in compiled_shaders.zig.

Exit code 0 = match (or no bytecodes generated yet).
Exit code 1 = mismatch (main.hlsl changed but shaders not recompiled).
"""

import hashlib
import os
import re
import sys


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    hlsl_path = os.path.join(script_dir, "main.hlsl")
    zig_path = os.path.join(script_dir, "compiled_shaders.zig")

    if not os.path.exists(hlsl_path):
        print(f"ERROR: {hlsl_path} not found")
        sys.exit(1)
    if not os.path.exists(zig_path):
        print(f"ERROR: {zig_path} not found")
        sys.exit(1)

    # Read the recorded hash from compiled_shaders.zig
    with open(zig_path, "r") as f:
        zig_content = f.read()

    m = re.search(r'pub const hlsl_sha256 = "([0-9a-f]*)";', zig_content)
    if not m:
        print("ERROR: hlsl_sha256 constant not found in compiled_shaders.zig")
        sys.exit(1)

    recorded_hash = m.group(1)

    if recorded_hash == "":
        # No bytecodes generated yet — nothing to check
        print("OK: No pre-compiled bytecodes (hlsl_sha256 is empty), skipping check.")
        sys.exit(0)

    # Compute live hash of main.hlsl (LF-normalized)
    with open(hlsl_path, "rb") as f:
        raw = f.read()
    normalized = raw.replace(b"\r\n", b"\n")
    live_hash = hashlib.sha256(normalized).hexdigest()

    if live_hash == recorded_hash:
        print(f"OK: main.hlsl hash matches compiled_shaders.zig ({live_hash[:16]}...)")
        sys.exit(0)
    else:
        print("FAIL: main.hlsl has changed since shaders were pre-compiled!")
        print(f"  main.hlsl:           {live_hash}")
        print(f"  compiled_shaders.zig: {recorded_hash}")
        print()
        print("Fix: Run on Windows:")
        print("  cd windows\\shaders")
        print("  compile.bat")
        print("  python generate_zig.py")
        sys.exit(1)


if __name__ == "__main__":
    main()
