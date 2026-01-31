#!/usr/bin/env python3
"""
Generate compiled_shaders.zig from .cso files.
Run this after compile.bat to embed shader bytecode.
"""

import os
import sys

def read_cso(filename):
    with open(filename, 'rb') as f:
        return f.read()

def format_bytes(data, name):
    lines = [f"pub const {name} = [_]u8{{"]

    # Format bytes in rows of 16
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        hex_vals = ", ".join(f"0x{b:02x}" for b in chunk)
        lines.append(f"    {hex_vals},")

    lines.append("};")
    return "\n".join(lines)

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    vs_path = os.path.join(script_dir, "vs_main.cso")
    ps_path = os.path.join(script_dir, "ps_main.cso")
    out_path = os.path.join(script_dir, "compiled_shaders.zig")

    if not os.path.exists(vs_path):
        print(f"Error: {vs_path} not found. Run compile.bat first.")
        sys.exit(1)
    if not os.path.exists(ps_path):
        print(f"Error: {ps_path} not found. Run compile.bat first.")
        sys.exit(1)

    vs_data = read_cso(vs_path)
    ps_data = read_cso(ps_path)

    print(f"VS bytecode size: {len(vs_data)} bytes")
    print(f"PS bytecode size: {len(ps_data)} bytes")

    output = f"""// Auto-generated shader bytecode - DO NOT EDIT
// Generated from main.hlsl using compile.bat + generate_zig.py

{format_bytes(vs_data, "vs_bytecode")}

{format_bytes(ps_data, "ps_bytecode")}
"""

    with open(out_path, 'w') as f:
        f.write(output)

    print(f"Generated: {out_path}")

if __name__ == "__main__":
    main()
