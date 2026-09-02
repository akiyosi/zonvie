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
            textureWidthPx: texWidthPx, textureHeightPx: texRows * rowHeightPx,
            drawableWidthPx: texWidthPx, rowHeightPx: rowHeightPx
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
                textureWidthPx: texWidthPx, textureHeightPx: 44 * rowHeightPx,
                drawableWidthPx: 0, rowHeightPx: rowHeightPx
            ) == nil,
            "a zero-width drawable"
        )
        require(
            RowScrollBlitPlan.make(
                rowStart: 0, rowEnd: 44, rowsDelta: 1,
                textureWidthPx: texWidthPx, textureHeightPx: 44 * rowHeightPx,
                drawableWidthPx: texWidthPx, rowHeightPx: 0
            ) == nil,
            "a zero row height"
        )
    }

    /// The width is the drawable's, bounded by the texture.
    private static func verifyCopyWidth() {
        let narrow = RowScrollBlitPlan.make(
            rowStart: 0, rowEnd: 44, rowsDelta: 1,
            textureWidthPx: 500, textureHeightPx: 44 * rowHeightPx,
            drawableWidthPx: 800, rowHeightPx: rowHeightPx
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
            textureWidthPx: widthPx, textureHeightPx: rows * rowPx,
            drawableWidthPx: widthPx, rowHeightPx: rowPx
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

        guard let device = MTLCreateSystemDefaultDevice() else {
            // Headless CI without a GPU: the arithmetic above still ran.
            print("RowScrollBlitPlanTests: OK (no Metal device; blit test skipped)")
            return
        }
        verifyBlitShiftsRows(device: device)
        print("RowScrollBlitPlanTests: OK")
    }
}
