import Foundation
import Metal

/// The blit encoder, checked against a real texture: a plan says which
/// pixels move where, and this is what proves they do.
///
/// The arithmetic that produces a plan lives in the core now, with its own
/// tests (src/core/row_scroll.zig). The plan below is written out rather than
/// computed so this file keeps compiling on its own, the way build.zig hands
/// it to swiftc.
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

        // What the core answers for rowStart 0, rowEnd 8, rowsDelta 2 at this
        // geometry: read from two rows down, write at the top, six rows tall.
        let plan = RowScrollBlitPlan(
            srcYPx: 2 * rowPx,
            dstYPx: 0,
            copyWidthPx: widthPx,
            copyHeightPx: 6 * rowPx,
            clearTopPx: 6 * rowPx,
            clearBottomPx: 8 * rowPx,
            clampedRowEnd: rows,
            dirtyRows: 4..<8,
            originXPx: 0,
            originYPx: 0
        )
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("RowScrollBlitPlanTests: OK (no Metal device; blit test skipped)")
            return
        }
        verifyBlitShiftsRows(device: device)
        print("RowScrollBlitPlanTests: OK")
    }
}
