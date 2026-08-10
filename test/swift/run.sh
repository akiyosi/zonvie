#!/bin/sh
# Swift-side unit tests. Compiles the REAL app sources under test alongside a
# small shim (app_shim.swift) that stands in for the app types those sources
# name but the tests never exercise.
#
# Not wired into `zig build`: the Xcode project is not file-system synchronised,
# so a proper test target would mean editing project.pbxproj. Run it directly.
set -e
repo=$(cd "$(dirname "$0")/../.." && pwd)
out="${repo}/tmp/swift-tests"
mkdir -p "${out}"

swiftc -O \
    "${repo}/macos/Sources/Rendering/MetalTypes.swift" \
    "${repo}/test/swift/app_shim.swift" \
    "${repo}/test/swift/scroll_retention_test.swift" \
    -o "${out}/scroll_retention_test"

"${out}/scroll_retention_test"
