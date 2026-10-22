// The Swift halves of three shared rules, compiled without the app:
//
// - SurfaceFrameDecision: every SurfaceFrameTerms field reaches the
//   zonvie_surface_frame_terms field of the same meaning (zonvie_frontend.h),
//   and every decision field and ZONVIE_ROW_PASS_* value comes back.
// - SurfaceDamageBands.addPlacementChanges: a moved, resized, restacked,
//   added or removed layer damages its old and its new extent; an unchanged
//   one damages nothing.
// - SurfaceRowCapacityLedger.require: a requirement only ever rises.
//
// The core entry points are replaced by the stubs below, so this checks the
// bridge, not the core's decision (src/core tests own that).

import Foundation
import simd

// Minimal collaborators required when MetalTypes.swift is compiled as a
// standalone test executable (as in SurfaceRowProvisionTests).
final class ZonvieConfig {
    static let shared = ZonvieConfig()
    var backgroundAlpha: Float = 1.0
}

final class GridSurfaceRenderer {
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

private enum Stub {
    static var lastTerms = zonvie_surface_frame_terms()
    static var decision = zonvie_surface_frame_decision()
}

@_cdecl("zonvie_core_surface_frame_decision")
func stubSurfaceFrameDecision(
    _ terms: UnsafePointer<zonvie_surface_frame_terms>?,
    _ out: UnsafeMutablePointer<zonvie_surface_frame_decision>?
) {
    Stub.lastTerms = terms!.pointee
    out!.pointee = Stub.decision
}

/// Identity: each span comes back as one band, so `bands` shows the spans.
@_cdecl("zonvie_core_damage_bands")
func stubDamageBands(
    _ spans: UnsafePointer<zonvie_damage_band>?, _ spanCount: Int,
    _ rowHeightPx: Int32, _ surfaceHeightPx: Int32,
    _ out: UnsafeMutablePointer<zonvie_damage_band>?, _ outCapacity: Int
) -> Int {
    let n = min(spanCount, outCapacity)
    for i in 0..<n { out![i] = spans![i] }
    return n
}

@_cdecl("zonvie_core_damage_band_layer_rows")
func stubDamageBandLayerRows(
    _ band: zonvie_damage_band, _ originYPx: Int32, _ layerRows: UInt32, _ rowHeightPx: Int32,
    _ first: UnsafeMutablePointer<UInt32>?, _ last: UnsafeMutablePointer<UInt32>?
) -> Bool {
    // The rows the band overlaps; enough to check the Swift margin rule on top.
    let top = Int(band.top_px) - Int(originYPx)
    let bottom = Int(band.bottom_px) - Int(originYPx)
    let h = Int(rowHeightPx)
    guard h > 0, layerRows > 0, bottom > 0, top < Int(layerRows) * h else { return false }
    first!.pointee = UInt32(max(0, top) / h)
    last!.pointee = UInt32(min(Int(layerRows) - 1, (bottom - 1) / h))
    return true
}

@_cdecl("zonvie_core_damage_band_for_layer_row")
func stubDamageBandForLayerRow(
    _ bands: UnsafePointer<zonvie_damage_band>?, _ count: Int, _ originYPx: Int32,
    _ row: UInt32, _ rowHeightPx: Int32, _ out: UnsafeMutablePointer<zonvie_damage_band>?
) -> Bool {
    fatalError("not used by this test")
}

@main
private enum SurfaceFramePureTests {
    private static var failures = 0

    private static func fail(_ message: String) {
        failures += 1
        print("FAIL \(message)")
    }

    /// Every C field's value, by name.
    private static func fields<T>(_ value: T) -> [String: String] {
        var out: [String: String] = [:]
        for child in Mirror(reflecting: value).children {
            if let label = child.label { out[label] = "\(child.value)" }
        }
        return out
    }

    private static func verifyTermsBridge() {
        typealias Pair = (swift: WritableKeyPath<SurfaceFrameTerms, Bool>, c: String)
        let pairs: [String: Pair] = [
            "rowMode": (\.rowMode, "row_mode"),
            "rowModeSatisfied": (\.rowModeSatisfied, "row_mode_satisfied"),
            "hasPresentedOnce": (\.hasPresentedOnce, "has_presented_once"),
            "drawableSizeChanged": (\.drawableSizeChanged, "drawable_size_changed"),
            "isSmoothScrolling": (\.isSmoothScrolling, "is_smooth_scrolling"),
            "blurEnabled": (\.blurEnabled, "blur_enabled"),
            "useTwoPass": (\.useTwoPass, "use_two_pass"),
            "glowEnabled": (\.glowEnabled, "glow_enabled"),
            "isDecoratedSurface": (\.isDecoratedSurface, "is_decorated_surface"),
            "isPopupmenu": (\.isPopupmenu, "is_popupmenu"),
            "shaderChainConsumesSurface": (\.shaderChainConsumesSurface, "shader_chain_consumes_surface"),
            "fontIsCurrent": (\.fontIsCurrent, "font_is_current"),
            "hasLayoutDamage": (\.hasLayoutDamage, "has_layout_damage"),
            "hasDirtyRect": (\.hasDirtyRect, "has_dirty_rect"),
            "hasDirtyRows": (\.hasDirtyRows, "has_dirty_rows"),
            "hasLayerWork": (\.hasLayerWork, "has_layer_work"),
            "commitChangesNoPixels": (\.commitChangesNoPixels, "commit_changes_no_pixels"),
            "hasStagedScroll": (\.hasStagedScroll, "has_staged_scroll"),
            "scrollOffsetChanged": (\.scrollOffsetChanged, "scroll_offset_changed"),
            "hostsLayersOutsideDirtySet": (\.hostsLayersOutsideDirtySet, "hosts_layers_outside_dirty_set"),
            "scrollBlitKeptBackTexture": (\.scrollBlitKeptBackTexture, "scroll_blit_kept_back_texture"),
            "rootScrollBlitVacatedBand": (\.rootScrollBlitVacatedBand, "root_scroll_blit_vacated_band"),
        ]

        // Every Swift term is covered here, and every C term but the
        // Windows-only refuses_reuse has a Swift term behind it.
        let swiftLabels = Set(Mirror(reflecting: SurfaceFrameTerms()).children.compactMap(\.label))
        let covered = Set(pairs.keys).union(["configuredBlurAlpha"])
        if swiftLabels != covered {
            fail("Swift terms not covered: \(swiftLabels.symmetricDifference(covered).sorted())")
        }
        let cLabels = Set(fields(zonvie_surface_frame_terms()).keys)
        let cCovered = Set(pairs.values.map(\.c)).union(["configured_blur_alpha", "refuses_reuse"])
        if cLabels != cCovered {
            fail("C terms not covered: \(cLabels.symmetricDifference(cCovered).sorted())")
        }

        // The header's defaults.
        _ = SurfaceFrameDecision.make(terms: SurfaceFrameTerms())
        let base = fields(Stub.lastTerms)
        let defaultTrue: Set<String> = ["row_mode", "row_mode_satisfied", "font_is_current", "commit_changes_no_pixels"]
        for (label, value) in base where label != "configured_blur_alpha" {
            let want = defaultTrue.contains(label) ? "true" : "false"
            if value != want { fail("default \(label)=\(value), header says \(want)") }
        }
        if Stub.lastTerms.configured_blur_alpha != 1 {
            fail("default configured_blur_alpha=\(Stub.lastTerms.configured_blur_alpha), header says 1")
        }

        // One term at a time: exactly its C field moves.
        for (name, pair) in pairs.sorted(by: { $0.key < $1.key }) {
            var t = SurfaceFrameTerms()
            t[keyPath: pair.swift].toggle()
            _ = SurfaceFrameDecision.make(terms: t)
            let got = fields(Stub.lastTerms)
            let moved = got.keys.filter { got[$0] != base[$0] }.sorted()
            if moved != [pair.c] { fail("\(name) moved C fields \(moved), expected [\(pair.c)]") }
        }
        var t = SurfaceFrameTerms()
        t.configuredBlurAlpha = 0.25
        _ = SurfaceFrameDecision.make(terms: t)
        let got = fields(Stub.lastTerms)
        let moved = got.keys.filter { got[$0] != base[$0] }.sorted()
        if moved != ["configured_blur_alpha"] || Stub.lastTerms.configured_blur_alpha != 0.25 {
            fail("configuredBlurAlpha moved C fields \(moved)")
        }
    }

    private static func verifyDecisionBridge() {
        typealias Pair = (c: WritableKeyPath<zonvie_surface_frame_decision, Bool>, swift: KeyPath<SurfaceFrameDecision, Bool>, name: String)
        let pairs: [Pair] = [
            (\.reuses_root_contents, \.reusesRootContents, "reuses_root_contents"),
            (\.reuses_hosted_contents, \.reusesHostedContents, "reuses_hosted_contents"),
            (\.partial_hosted_contents, \.partialHostedContents, "partial_hosted_contents"),
            (\.skips_surface_pass, \.skipsSurfacePass, "skips_surface_pass"),
            (\.can_dirty_only_with_blur, \.canDirtyOnlyWithBlur, "can_dirty_only_with_blur"),
            (\.loads_previous_contents, \.loadsPreviousContents, "loads_previous_contents"),
        ]
        for pair in pairs {
            var d = zonvie_surface_frame_decision()
            d.row_pass_plan = UInt8(ZONVIE_ROW_PASS_ALL_ROWS)
            d[keyPath: pair.c] = true
            Stub.decision = d
            let s = SurfaceFrameDecision.make(terms: SurfaceFrameTerms())
            for other in pairs where s[keyPath: other.swift] != (other.name == pair.name) {
                fail("C \(pair.name)=true read back \(other.name)=\(s[keyPath: other.swift])")
            }
        }
        let plans: [(UInt32, SurfaceRowPassPlan)] = [
            (UInt32(ZONVIE_ROW_PASS_DIRTY_ROWS_ONLY), .dirtyRowsOnly),
            (UInt32(ZONVIE_ROW_PASS_DIRTY_ROWS_AFTER_SCROLL_BLIT), .dirtyRowsAfterScrollBlit),
            (UInt32(ZONVIE_ROW_PASS_ALL_ROWS_WITH_RETAINED), .allRowsWithRetained),
            (UInt32(ZONVIE_ROW_PASS_ALL_ROWS), .allRows),
        ]
        for (raw, plan) in plans {
            var d = zonvie_surface_frame_decision()
            d.row_pass_plan = UInt8(raw)
            d.background_alpha = 0.5
            Stub.decision = d
            let s = SurfaceFrameDecision.make(terms: SurfaceFrameTerms())
            if s.rowPassPlan != plan { fail("row_pass_plan \(raw) read back \(s.rowPassPlan), expected \(plan)") }
            if s.backgroundAlpha != 0.5 { fail("background_alpha read back \(s.backgroundAlpha)") }
        }
        Stub.decision = zonvie_surface_frame_decision()
    }

    private static func layer(_ id: Int64, y: Float, rows: Int, cols: Int = 10) -> SurfaceLayerFrame {
        SurfaceLayerFrame(
            layer: SurfaceLayer(gridId: id, anchorGrid: 1, originPx: simd_float2(0, y),
                                rows: rows, cols: cols, z: 1, followsScroll: false),
            set: nil, state: nil)
    }

    /// The spans one frame's placements add, as (top, bottom) pixel pairs.
    private static func damage(_ bands: SurfaceDamageBands, _ frames: [SurfaceLayerFrame]) -> [[Int]] {
        bands.reset()
        bands.addPlacementChanges(frames, rowHeightPx: 10)
        bands.resolve(rowHeightPx: 10, surfaceHeightPx: 1000)
        return bands.bands.map { [Int($0.top_px), Int($0.bottom_px)] }.sorted { $0[0] < $1[0] }
    }

    private static func verifyPlacementDamage() {
        func expect(_ got: [[Int]], _ want: [[Int]], _ what: String) {
            if got != want { fail("placement \(what): damaged \(got), expected \(want)") }
        }
        let b = SurfaceDamageBands()
        expect(damage(b, [layer(2, y: 0, rows: 2)]), [[0, 20]], "added")
        expect(damage(b, [layer(2, y: 0, rows: 2)]), [], "unchanged")
        expect(damage(b, [layer(2, y: 30, rows: 2)]), [[0, 20], [30, 50]], "moved")
        expect(damage(b, [layer(2, y: 30, rows: 4)]), [[30, 50], [30, 70]], "resized")
        expect(damage(b, [layer(2, y: 30, rows: 4, cols: 5)]), [[30, 70], [30, 70]], "narrowed")
        expect(damage(b, [layer(2, y: 30, rows: 4, cols: 5), layer(3, y: 100, rows: 1)]),
               [[100, 110]], "second layer added")
        expect(damage(b, [layer(3, y: 100, rows: 1), layer(2, y: 30, rows: 4, cols: 5)]),
               [[30, 70], [30, 70], [100, 110], [100, 110]], "restacked")
        expect(damage(b, [layer(2, y: 30, rows: 4, cols: 5)]),
               [[30, 70], [30, 70], [100, 110]], "removed")
        expect(damage(b, []), [[30, 70]], "all removed")
    }

    /// A grid in its own font (on_grid_font): rows of its own height, clipped
    /// to its extent, whose bottom margin belongs to its last row.
    private static func verifyFontLayerGeometry() {
        var font = SurfaceLayer(gridId: 2, anchorGrid: 1, originPx: simd_float2(0, 30),
                                rows: 3, cols: 13, z: 1, followsScroll: false)
        font.cellWidthPx = 7
        font.cellHeightPx = 12
        font.extentWidthPx = 100
        font.extentHeightPx = 40
        if font.rowHeightPx(surfaceCellHeightPx: 10) != 12 { fail("font layer row height \(font.rowHeightPx(surfaceCellHeightPx: 10))") }
        if font.drawWidthPx(surfaceCellWidthPx: 8) != 100 { fail("font layer width \(font.drawWidthPx(surfaceCellWidthPx: 8))") }
        if font.drawHeightPx(rows: 3, surfaceCellHeightPx: 10) != 40 { fail("font layer height with margin \(font.drawHeightPx(rows: 3, surfaceCellHeightPx: 10))") }
        if font.drawHeightPx(rows: 2, surfaceCellHeightPx: 10) != 24 { fail("font layer partial height \(font.drawHeightPx(rows: 2, surfaceCellHeightPx: 10))") }

        let plain = SurfaceLayer(gridId: 3, anchorGrid: 1, originPx: simd_float2(0, 0),
                                 rows: 3, cols: 13, z: 1, followsScroll: false)
        if plain.rowHeightPx(surfaceCellHeightPx: 10) != 10 || plain.drawWidthPx(surfaceCellWidthPx: 8) != 104
            || plain.drawHeightPx(rows: 3, surfaceCellHeightPx: 10) != 30 {
            fail("plain layer geometry changed")
        }

        let b = SurfaceDamageBands()
        let frame = SurfaceLayerFrame(layer: font, set: nil, state: nil)
        let got = damage(b, [frame])
        if got != [[30, 70]] { fail("font layer placement damaged \(got), expected [[30, 70]]") }

        // A band reaching only the margin strip (30 + 3*12 = 66 .. 70) draws the last row.
        let margin = zonvie_damage_band(top_px: 67, bottom_px: 70)
        let r = SurfaceDamageBands.rows(in: margin, layer: font, originYPx: 30, rowCount: 3, surfaceCellHeightPx: 10)
        if r != 2...2 { fail("margin band rows \(String(describing: r)), expected 2...2") }
        let mid = zonvie_damage_band(top_px: 42, bottom_px: 50)
        let m = SurfaceDamageBands.rows(in: mid, layer: font, originYPx: 30, rowCount: 3, surfaceCellHeightPx: 10)
        if m != 1...1 { fail("mid band rows \(String(describing: m)), expected 1...1") }
    }

    private static func verifyLedgerRequire() {
        let ledger = SurfaceRowCapacityLedger(maxRowBuffers: 8)
        ledger.require(rows: 5, row: 2, vertexCount: 10)
        ledger.require(rows: 3, row: 2, vertexCount: 4)
        if ledger.requiredRows != 5 || ledger.requiredVertexCounts[2] != 10 {
            fail("a smaller requirement lowered rows=\(ledger.requiredRows) vc=\(ledger.requiredVertexCounts[2])")
        }
        ledger.require(rows: 6, row: 5, vertexCount: 7)
        if ledger.requiredRows != 6 || ledger.requiredVertexCounts[5] != 7 {
            fail("a larger requirement was not taken")
        }
        // A failed pass's requirement merged back with what arrived meanwhile.
        ledger.require(rows: 4, vertexCounts: [1, 20, 3, 0])
        if ledger.requiredRows != 6 || ledger.requiredVertexCounts[0..<6] != [1, 20, 10, 0, 0, 7] {
            fail("merge-back gave rows=\(ledger.requiredRows) vc=\(Array(ledger.requiredVertexCounts[0..<6]))")
        }
    }

    static func main() {
        verifyTermsBridge()
        verifyDecisionBridge()
        verifyPlacementDamage()
        verifyFontLayerGeometry()
        verifyLedgerRequire()
        if failures != 0 {
            print("surface frame pure: \(failures) failure(s)")
            exit(1)
        }
        print("surface frame pure: all checks passed")
    }
}
