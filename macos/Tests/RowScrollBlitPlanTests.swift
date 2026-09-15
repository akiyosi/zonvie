import Foundation
import Metal

/// RowScrollBlitPlan is the arithmetic behind the main-grid GPU scroll blit:
/// where the copy reads and writes, how far it may go inside the back
/// texture, which band it vacates, and which rows the caller must redraw.
/// Every regression in it so far was found by scrolling on hardware; these
/// are the parts that need not have been.
@main
private enum RowScrollBlitPlanTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func requireEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
        require(got == want, "\(message) (got \(got), want \(want))")
    }

    /// One row height, one texture, so each case reads as rows.
    private static let rowHeightPx = 20
    private static let texRows = 44
    private static let texWidthPx = 800

    private static func plan(
        rowStart: Int, rowEnd: Int, rowsDelta: Int, texRows: Int = texRows
    ) -> RowScrollBlitPlan? {
        RowScrollBlitPlan.make(
            rowStart: rowStart, rowEnd: rowEnd, rowsDelta: rowsDelta,
            widthPx: texWidthPx, textureWidthPx: texWidthPx,
            textureHeightPx: texRows * rowHeightPx, rowHeightPx: rowHeightPx
        )
    }

    /// Scroll down: the copy reads from below and writes above; the vacated
    /// band is at the bottom and the dirty rows reach 2*shift above the end.
    private static func verifyScrollDown() {
        guard let p = plan(rowStart: 0, rowEnd: 44, rowsDelta: 3) else {
            require(false, "a three-row scroll down produced no plan")
            return
        }
        requireEqual(p.srcYPx, 3 * rowHeightPx, "down reads from rowStart + shift")
        requireEqual(p.dstYPx, 0, "down writes to rowStart")
        requireEqual(p.copyHeightPx, 41 * rowHeightPx, "down copies region - shift rows")
        requireEqual(p.copyWidthPx, texWidthPx, "copy spans the drawable")
        requireEqual(p.clearTopPx, 41 * rowHeightPx, "down vacates the bottom shift rows")
        requireEqual(p.clearBottomPx, 44 * rowHeightPx, "down vacated band ends at the region end")
        requireEqual(p.clampedRowEnd, 44, "nothing to clamp when the region fits")
        requireEqual(p.dirtyRows, 38..<44, "down dirties 2*shift rows above the end")
    }

    /// Scroll up: mirror image.
    private static func verifyScrollUp() {
        guard let p = plan(rowStart: 0, rowEnd: 44, rowsDelta: -3) else {
            require(false, "a three-row scroll up produced no plan")
            return
        }
        requireEqual(p.srcYPx, 0, "up reads from rowStart")
        requireEqual(p.dstYPx, 3 * rowHeightPx, "up writes to rowStart + shift")
        requireEqual(p.copyHeightPx, 41 * rowHeightPx, "up copies region - shift rows")
        requireEqual(p.clearTopPx, 0, "up vacates the top")
        requireEqual(p.clearBottomPx, 3 * rowHeightPx, "up vacated band is shift rows tall")
        requireEqual(p.dirtyRows, 0..<6, "up dirties 2*shift rows below the start")
    }

    /// A region that does not start at row 0 (a split below a winbar).
    private static func verifyOffsetRegion() {
        guard let p = plan(rowStart: 10, rowEnd: 30, rowsDelta: 2) else {
            require(false, "an offset region produced no plan")
            return
        }
        requireEqual(p.srcYPx, 12 * rowHeightPx, "offset down reads from rowStart + shift")
        requireEqual(p.dstYPx, 10 * rowHeightPx, "offset down writes to rowStart")
        requireEqual(p.copyHeightPx, 18 * rowHeightPx, "offset down copies region - shift")
        requireEqual(p.dirtyRows, 26..<30, "offset dirty rows stay inside the region")
        // The expansion never reaches above the region start.
        guard let small = plan(rowStart: 10, rowEnd: 13, rowsDelta: 2) else {
            require(false, "a short region produced no plan")
            return
        }
        requireEqual(small.dirtyRows, 10..<13, "expansion clamps to rowStart")
    }

    /// The regression 8a9cba0 fixed: the reported row count outlives the
    /// drawable (45 rows reported, 44 fit), by more than the shift. The blit,
    /// the vacated band, and the dirty expansion must all stop at the same
    /// clamped row, otherwise part of the band the blit cleared is never
    /// redrawn and stays blank until the next full redraw.
    private static func verifyClampStopsEverythingAtTheTexture() {
        guard let p = plan(rowStart: 0, rowEnd: 45, rowsDelta: 1) else {
            require(false, "a clamped scroll produced no plan")
            return
        }
        requireEqual(p.clampedRowEnd, 44, "rowEnd clamps to the texture height")
        requireEqual(p.copyHeightPx, 43 * rowHeightPx, "the copy stays inside the texture")
        requireEqual(p.clearBottomPx, 44 * rowHeightPx, "the vacated band stays inside the texture")
        requireEqual(p.dirtyRows, 42..<44, "the dirty expansion stops at the clamped row")

        // Larger overshoot: rowEnd 50 with a 44-row texture and shift 2.
        guard let far = plan(rowStart: 0, rowEnd: 50, rowsDelta: 2) else {
            require(false, "a far-clamped scroll produced no plan")
            return
        }
        requireEqual(far.dirtyRows, 40..<44, "a far overshoot still ends at the clamped row")
        requireEqual(
            far.clearTopPx, 42 * rowHeightPx,
            "the vacated band starts shift rows above the clamped end"
        )
    }

    /// Cases that must produce no plan; the caller then redraws from scratch.
    private static func verifyNoPlanCases() {
        require(plan(rowStart: 0, rowEnd: 44, rowsDelta: 0) == nil, "no movement, no plan")
        require(
            plan(rowStart: 0, rowEnd: 10, rowsDelta: 10) == nil,
            "a whole-region shift leaves nothing to copy"
        )
        require(
            plan(rowStart: 0, rowEnd: 10, rowsDelta: 12) == nil,
            "a shift past the region leaves nothing to copy"
        )
        require(
            plan(rowStart: 44, rowEnd: 50, rowsDelta: 1) == nil,
            "a region entirely below the texture"
        )
        require(plan(rowStart: 0, rowEnd: 44, rowsDelta: 1, texRows: 0) == nil, "an empty texture")
        require(
            RowScrollBlitPlan.make(
                rowStart: 0, rowEnd: 44, rowsDelta: 1,
                widthPx: 0, textureWidthPx: texWidthPx,
                textureHeightPx: 44 * rowHeightPx, rowHeightPx: rowHeightPx
            ) == nil,
            "a zero-width drawable"
        )
        require(
            RowScrollBlitPlan.make(
                rowStart: 0, rowEnd: 44, rowsDelta: 1,
                widthPx: texWidthPx, textureWidthPx: texWidthPx,
                textureHeightPx: 44 * rowHeightPx, rowHeightPx: 0
            ) == nil,
            "a zero row height"
        )
    }

    /// The width is the drawable's, bounded by the texture.
    private static func verifyCopyWidth() {
        let narrow = RowScrollBlitPlan.make(
            rowStart: 0, rowEnd: 44, rowsDelta: 1,
            widthPx: 800, textureWidthPx: 500,
            textureHeightPx: 44 * rowHeightPx, rowHeightPx: rowHeightPx
        )
        requireEqual(narrow?.copyWidthPx, 500, "a drawable wider than the texture copies the texture width")
    }

    /// The two invariants that hold for every plan, swept over every small
    /// geometry: the copy never leaves the texture, and the vacated band is
    /// always inside the dirty rows.
    private static func verifySweepInvariants() {
        var planned = 0
        for texRows in 0...12 {
            for rowStart in 0...12 {
                for rowEnd in 0...16 {
                    for rowsDelta in -8...8 {
                        guard let p = plan(
                            rowStart: rowStart, rowEnd: rowEnd, rowsDelta: rowsDelta, texRows: texRows
                        ) else {
                            continue
                        }
                        planned += 1
                        let texHeightPx = texRows * rowHeightPx
                        let geometry = "start \(rowStart) end \(rowEnd) delta \(rowsDelta) texRows \(texRows)"
                        require(p.srcYPx >= 0 && p.dstYPx >= 0, "copy offsets are non-negative: \(geometry)")
                        require(p.copyHeightPx > 0, "a plan always copies something: \(geometry)")
                        require(
                            p.srcYPx + p.copyHeightPx <= texHeightPx,
                            "the read stays inside the texture: \(geometry)"
                        )
                        require(
                            p.dstYPx + p.copyHeightPx <= texHeightPx,
                            "the write stays inside the texture: \(geometry)"
                        )
                        require(
                            p.clearBottomPx <= texHeightPx,
                            "the vacated band stays inside the texture: \(geometry)"
                        )
                        require(p.clearTopPx < p.clearBottomPx, "the vacated band is non-empty: \(geometry)")
                        require(
                            p.clampedRowEnd <= texRows && p.clampedRowEnd <= rowEnd,
                            "clampedRowEnd is a clamp: \(geometry)"
                        )
                        let vacated = (p.clearTopPx / rowHeightPx)..<(p.clearBottomPx / rowHeightPx)
                        require(
                            p.dirtyRows.lowerBound <= vacated.lowerBound
                                && vacated.upperBound <= p.dirtyRows.upperBound,
                            "the vacated band \(vacated) is inside the dirty rows \(p.dirtyRows): \(geometry)"
                        )
                        require(
                            p.dirtyRows.lowerBound >= rowStart && p.dirtyRows.upperBound <= p.clampedRowEnd,
                            "dirty rows stay inside the clamped region: \(geometry)"
                        )
                    }
                }
            }
        }
        require(planned > 100, "the sweep must plan many cases, planned \(planned)")
    }

    /// Without a blit nothing was shifted, so the caller redraws the whole
    /// region, still stopping at the texture.
    private static func verifyDirtyRowsWithoutBlit() {
        requireEqual(
            RowScrollBlitPlan.dirtyRowsWithoutBlit(
                rowStart: 0, rowEnd: 45, textureHeightPx: 44 * rowHeightPx, rowHeightPx: rowHeightPx
            ),
            0..<44,
            "the fallback region clamps to the texture"
        )
        requireEqual(
            RowScrollBlitPlan.dirtyRowsWithoutBlit(
                rowStart: 10, rowEnd: 30, textureHeightPx: 44 * rowHeightPx, rowHeightPx: rowHeightPx
            ),
            10..<30,
            "the fallback region is the whole scroll region"
        )
        require(
            RowScrollBlitPlan.dirtyRowsWithoutBlit(
                rowStart: 44, rowEnd: 50, textureHeightPx: 44 * rowHeightPx, rowHeightPx: rowHeightPx
            ) == nil,
            "a region below the texture has nothing to redraw"
        )
        require(
            RowScrollBlitPlan.dirtyRowsWithoutBlit(
                rowStart: 0, rowEnd: 10, textureHeightPx: 44 * rowHeightPx, rowHeightPx: 0
            ) == nil,
            "a zero row height has nothing to redraw"
        )
    }

    /// A layer's rectangle inside the shared back texture: every pixel value
    /// slides down by the layer's origin, the copy starts at its left edge,
    /// and the dirty rows stay grid-local -- they number rows within the
    /// scroll region, not pixels, so the origin must not touch them.
    private static func verifyLayerOrigin() {
        let originYPx = 5 * rowHeightPx
        let originXPx = 400
        guard let base = plan(rowStart: 0, rowEnd: 20, rowsDelta: 3),
              let p = RowScrollBlitPlan.make(
                  rowStart: 0, rowEnd: 20, rowsDelta: 3,
                  originXPx: originXPx, originYPx: originYPx,
                  widthPx: 400, textureWidthPx: texWidthPx,
                  textureHeightPx: texRows * rowHeightPx, rowHeightPx: rowHeightPx
              )
        else {
            require(false, "a layer at an origin produced no plan")
            return
        }
        requireEqual(p.srcYPx, base.srcYPx + originYPx, "the layer origin shifts the read down")
        requireEqual(p.dstYPx, base.dstYPx + originYPx, "the layer origin shifts the write down")
        requireEqual(p.clearTopPx, base.clearTopPx + originYPx, "the vacated band starts at the layer")
        requireEqual(p.clearBottomPx, base.clearBottomPx + originYPx, "the vacated band ends at the layer")
        requireEqual(p.dirtyRows, base.dirtyRows, "dirty rows are grid-local, the origin does not move them")
        requireEqual(p.originXPx, originXPx, "the left edge is carried for the encoder")
        requireEqual(p.copyWidthPx, 400, "the copy spans the layer, not the drawable")
        // Under a layer transform the caller's pixel space starts at the origin.
        requireEqual(
            p.localClearBand().clearTopPx, base.clearTopPx,
            "the local band drops back to the layer's own space"
        )
        requireEqual(
            p.localClearBand().clearBottomPx, base.clearBottomPx,
            "the local band drops back to the layer's own space"
        )
    }

    /// A layer narrower than the texture copies its own width, and one whose
    /// left edge sits inside the texture is clamped by what is left of it.
    private static func verifyNarrowLayer() {
        let inside = RowScrollBlitPlan.make(
            rowStart: 0, rowEnd: 44, rowsDelta: 1,
            widthPx: 300, textureWidthPx: 800,
            textureHeightPx: texRows * rowHeightPx, rowHeightPx: rowHeightPx
        )
        requireEqual(inside?.copyWidthPx, 300, "a narrow layer copies only its own width")
        let offset = RowScrollBlitPlan.make(
            rowStart: 0, rowEnd: 44, rowsDelta: 1,
            originXPx: 600, widthPx: 300, textureWidthPx: 800,
            textureHeightPx: texRows * rowHeightPx, rowHeightPx: rowHeightPx
        )
        requireEqual(offset?.copyWidthPx, 200, "the copy stops at the texture's right edge")
    }

    /// A layer whose origin is past the bottom of the texture has no rows at
    /// all: no blit, and nothing to redraw either.
    private static func verifyLayerFullyOutside() {
        require(
            RowScrollBlitPlan.make(
                rowStart: 0, rowEnd: 20, rowsDelta: 2,
                originYPx: 50 * rowHeightPx, widthPx: texWidthPx, textureWidthPx: texWidthPx,
                textureHeightPx: texRows * rowHeightPx, rowHeightPx: rowHeightPx
            ) == nil,
            "a layer below the texture has nothing to blit"
        )
        require(
            RowScrollBlitPlan.dirtyRowsWithoutBlit(
                rowStart: 0, rowEnd: 20, originYPx: 50 * rowHeightPx,
                textureHeightPx: texRows * rowHeightPx, rowHeightPx: rowHeightPx
            ) == nil,
            "a layer below the texture has nothing to redraw"
        )
    }

    /// A layer low enough that its own rows run off the bottom: only the rows
    /// below the origin exist, so rowEnd clamps to those and the copy, the
    /// dirty rows, and the no-blit fallback all stop at the same row.
    private static func verifyLayerBottomClamp() {
        let originYPx = 30 * rowHeightPx
        let texHeightPx = texRows * rowHeightPx
        guard let p = RowScrollBlitPlan.make(
            rowStart: 0, rowEnd: 20, rowsDelta: 2,
            originYPx: originYPx, widthPx: texWidthPx, textureWidthPx: texWidthPx,
            textureHeightPx: texHeightPx, rowHeightPx: rowHeightPx
        ) else {
            require(false, "a clamped layer produced no plan")
            return
        }
        requireEqual(p.clampedRowEnd, 14, "rowEnd clamps to the rows below the origin")
        requireEqual(p.dirtyRows, 10..<14, "the dirty expansion stops at the clamped row")
        require(
            p.srcYPx + p.copyHeightPx <= texHeightPx,
            "the read stays inside the texture (got \(p.srcYPx + p.copyHeightPx), texture \(texHeightPx))"
        )
        require(
            p.dstYPx + p.copyHeightPx <= texHeightPx,
            "the write stays inside the texture (got \(p.dstYPx + p.copyHeightPx), texture \(texHeightPx))"
        )
        requireEqual(p.clearBottomPx, texHeightPx, "the vacated band ends at the clamped row")
        requireEqual(
            RowScrollBlitPlan.dirtyRowsWithoutBlit(
                rowStart: 0, rowEnd: 20, originYPx: originYPx,
                textureHeightPx: texHeightPx, rowHeightPx: rowHeightPx
            ),
            0..<14,
            "the fallback region clamps to the same row as the blit"
        )
    }

    /// A tiny rgba8 texture, each row filled with its own index, run through
    /// the real blit. After a scroll down by two, rows 0..<6 hold what rows
    /// 2..<8 held, and the vacated bottom two rows are untouched: clearing
    /// them is the caller's job, not the blit's.
    private static func verifyBlitShiftsRows(device: MTLDevice) {
        let rows = 8
        let rowPx = 4
        let widthPx = 4
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: widthPx, height: rows * rowPx, mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .shaderWrite]
        guard let back = device.makeTexture(descriptor: desc),
              let scratch = device.makeTexture(descriptor: desc),
              let queue = device.makeCommandQueue()
        else {
            require(false, "texture or queue creation failed")
            return
        }
        let bytesPerRow = widthPx * 4
        for row in 0..<rows {
            let fill = [UInt8](repeating: UInt8(row + 1), count: bytesPerRow * rowPx)
            back.replace(
                region: MTLRegionMake2D(0, row * rowPx, widthPx, rowPx),
                mipmapLevel: 0, withBytes: fill, bytesPerRow: bytesPerRow
            )
        }

        guard let plan = RowScrollBlitPlan.make(
            rowStart: 0, rowEnd: rows, rowsDelta: 2,
            widthPx: widthPx, textureWidthPx: widthPx,
            textureHeightPx: rows * rowPx, rowHeightPx: rowPx
        ) else {
            require(false, "the device case produced no plan")
            return
        }
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else {
            require(false, "command buffer or blit encoder creation failed")
            return
        }
        encodeRowScrollBlit(blit, backTexture: back, scratch: scratch, plan: plan)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        requireEqual(cmd.status, .completed, "the blit command buffer completed")

        var pixels = [UInt8](repeating: 0, count: bytesPerRow * rows * rowPx)
        pixels.withUnsafeMutableBytes { buf in
            back.getBytes(
                buf.baseAddress!, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, widthPx, rows * rowPx), mipmapLevel: 0
            )
        }
        func rowValue(_ row: Int) -> UInt8 { pixels[row * rowPx * bytesPerRow] }
        for row in 0..<6 {
            requireEqual(rowValue(row), UInt8(row + 3), "row \(row) took the content two rows below")
        }
        requireEqual(rowValue(6), 7, "the vacated band keeps its old pixels for the caller to clear")
        requireEqual(rowValue(7), 8, "the vacated band keeps its old pixels for the caller to clear")
        // Every pixel of a shifted row moved, not only its first byte.
        let lastByteOfRow0 = pixels[(rowPx * bytesPerRow) - 1]
        requireEqual(lastByteOfRow0, 3, "the whole row moved")
    }

    static func main() {
        verifyScrollDown()
        verifyScrollUp()
        verifyOffsetRegion()
        verifyClampStopsEverythingAtTheTexture()
        verifyNoPlanCases()
        verifyCopyWidth()
        verifySweepInvariants()
        verifyDirtyRowsWithoutBlit()
        verifyLayerOrigin()
        verifyNarrowLayer()
        verifyLayerFullyOutside()
        verifyLayerBottomClamp()

        guard let device = MTLCreateSystemDefaultDevice() else {
            // Headless CI without a GPU: the arithmetic above still ran.
            print("RowScrollBlitPlanTests: OK (no Metal device; blit test skipped)")
            return
        }
        verifyBlitShiftsRows(device: device)
        print("RowScrollBlitPlanTests: OK")
    }
}
