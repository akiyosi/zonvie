// Test-only shim.
//
// MetalTypes.swift is compiled here for the sake of ScrollRetention, but its
// tail also holds the fixed-float mask and scroll-offset builders, which name
// types owned by MetalTerminalRenderer — and pulling that in would drag the
// whole app. These declarations exist ONLY so the file typechecks; nothing in
// scroll_retention_test.swift calls the functions that use them.
//
// They are not a second source of truth: the app build is, and if a real
// declaration grows a member MetalTypes.swift uses, this file stops compiling
// and has to be updated. That failure is the point.

import Foundation

enum MetalTerminalRenderer {
    struct ScrollOffset {
        var grid_id: Int32
        var offset_y: Float
        var content_top_y: Float
        var content_bottom_y: Float
        var move_all: Int32 = 0
        var pin_edges: Int32 = 1
        var zindex: Int32 = 0
    }

    struct FixedFloatRect: Equatable {
        var x0: Float
        var x1: Float
        var top: Float
        var bottom: Float
        var zindex: Int32
    }

    struct FixedFloatBand {
        var top: Float
        var bottom: Float
        var intervalStart: UInt32
        var intervalCount: UInt32
    }

    struct FixedFloatInterval {
        var x0: Float
        var x1: Float
        var z: Float = 0
    }
}

final class ZonvieConfig {
    static let shared = ZonvieConfig()
    var backgroundAlpha: Float = 1.0
}
