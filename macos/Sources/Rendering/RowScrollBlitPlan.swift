import Foundation
import Metal

/// Where a GPU row-scroll blit reads and writes, in this surface's back
/// texture. Pixel values carry `Px`; everything else is in rows.
///
/// The arithmetic behind it is the core's (`src/core/row_scroll.zig`), so both
/// frontends answer the same geometry the same way; `make` in
/// MetalTerminalRenderer.swift is the bridge. This file is what remains on the
/// Swift side: the shape the draw code reads, and the encoder that spends it.
/// It stays free of ZonvieCore because build.zig hands it to swiftc on its own
/// for RowScrollBlitPlanTests.
struct RowScrollBlitPlan: Equatable {
    var srcYPx: Int
    var dstYPx: Int
    var copyWidthPx: Int
    var copyHeightPx: Int
    /// The band the copy vacated, which the caller clears to the background.
    /// Absolute in the texture, like every other pixel value here; see
    /// `localClearBand()` for the layer-relative form.
    var clearTopPx: Int
    var clearBottomPx: Int
    /// scroll.rowEnd clamped to the texture: where the blit stopped.
    var clampedRowEnd: Int
    /// Rows the caller must redraw: the band vacated by an accumulated delta
    /// D, plus another D for rows an intermediate scroll step copied and a
    /// later one overwrote, which are stale in the back buffer.
    ///
    /// Grid-local rows counted from `rowStart`, the space the scroll region is
    /// reported in; `originYPx` moves the pixels, not the row numbering.
    var dirtyRows: Range<Int>
    /// The scrolled rectangle's left edge, which the encoder copies at.
    var originXPx: Int
    /// The scrolled rectangle's top edge, already folded into every Y value
    /// above; kept so `localClearBand()` can take it back out.
    var originYPx: Int

    /// The vacated band relative to `originYPx`, for callers drawing under a
    /// layer transform, whose pixel space starts at the layer origin.
    func localClearBand() -> (clearTopPx: Int, clearBottomPx: Int) {
        (clearTopPx: clearTopPx - originYPx, clearBottomPx: clearBottomPx - originYPx)
    }
}

/// Encode a plan's two copies: the region into the scratch texture at its
/// own offset, then back into the back texture at the shifted offset. The
/// caller owns the encoder and ends it.
func encodeRowScrollBlit(
    _ blit: MTLBlitCommandEncoder,
    backTexture: MTLTexture,
    scratch: MTLTexture,
    plan: RowScrollBlitPlan
) {
    let origin = MTLOrigin(x: plan.originXPx, y: plan.srcYPx, z: 0)
    let size = MTLSize(width: plan.copyWidthPx, height: plan.copyHeightPx, depth: 1)
    blit.copy(from: backTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
              to: scratch, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
    blit.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
              to: backTexture, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: plan.originXPx, y: plan.dstYPx, z: 0))
}
