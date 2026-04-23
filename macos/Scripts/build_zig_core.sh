#!/bin/sh
# Build the Zig core + its shader-compile deps (glslang family +
# SPIRV-Cross) for both macOS arches, then merge everything into a
# single universal libzonvie_core.a that the Xcode link step consumes.
#
# Invoked from the Xcode "Run Script" build phase.

set -euo pipefail

# Ensure zig is discoverable (Profile/Archive may not inherit shell PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

command -v zig >/dev/null 2>&1 || {
    echo "error: zig not found. PATH=$PATH"
    exit 1
}

ROOT="${SRCROOT}/.."
OUT="${ROOT}/zig-out/lib"
mkdir -p "${OUT}"

# Map Xcode configuration -> Zig optimize mode
case "${CONFIGURATION}" in
    Debug)
        ZIG_OPT=Debug
        ;;
    Release|Profile)
        ZIG_OPT=ReleaseSafe
        ;;
    *)
        ZIG_OPT=ReleaseSafe
        ;;
esac

echo "Building Zig core (${ZIG_OPT}) for CONFIGURATION=${CONFIGURATION}"

cd "${ROOT}"

# Build per-arch using zig build (fetches and compiles glslang + SPIRV-Cross
# as transitive deps declared in build.zig.zon).
zig build core -Dtarget=aarch64-macos -Doptimize="${ZIG_OPT}" --prefix "${ROOT}/zig-out-arm64"
zig build core -Dtarget=x86_64-macos  -Doptimize="${ZIG_OPT}" --prefix "${ROOT}/zig-out-x64"

# Shader-compile dep libs that accompany libzonvie_core.a in zig-out/lib.
# Zig does not cascade static-library deps through another static library,
# so we must libtool them all into one fat archive for Xcode to link.
SHADER_LIBS="
    libglslang.a
    libMachineIndependent.a
    libOSDependent.a
    libGenericCodeGen.a
    libSPIRV.a
    libSPVRemapper.a
    libglslang-default-resource-limits.a
    libSPIRV-Tools.a
    libSPIRV-Tools-opt.a
    libSPIRV-Tools-link.a
    libSPIRV-Tools-reduce.a
    libspirv_cross.a
"

for ARCH in arm64 x64; do
    ARCH_LIB_DIR="${ROOT}/zig-out-${ARCH}/lib"
    MERGED="${ARCH_LIB_DIR}/libzonvie_core_merged.a"
    rm -f "${MERGED}"
    LIB_LIST="${ARCH_LIB_DIR}/libzonvie_core.a"
    for L in ${SHADER_LIBS}; do
        LIB_LIST="${LIB_LIST} ${ARCH_LIB_DIR}/${L}"
    done
    # shellcheck disable=SC2086
    xcrun libtool -static -o "${MERGED}" ${LIB_LIST}
done

# Universal static lib containing core + all shader-compile deps.
lipo -create \
    "${ROOT}/zig-out-arm64/lib/libzonvie_core_merged.a" \
    "${ROOT}/zig-out-x64/lib/libzonvie_core_merged.a" \
    -output "${OUT}/libzonvie_core.a"
