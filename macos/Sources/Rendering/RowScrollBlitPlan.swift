import Foundation
import Metal

/// The arithmetic of a GPU row-scroll blit, kept apart from the encoder so it
/// can be checked without a device. Pixel values carry `Px`; everything else
/// is in rows.
///
/// The scrolled rectangle is a sub-rectangle of the back texture at
/// (`originXPx`, `originYPx`), `widthPx` wide: origins 0 and the drawable
/// width for a whole surface, the layer's own origin and width for one layer.
///
/// The row count the scroll callback reports can outlive the current
/// drawable -- a window shrink is only protected on the first post-shrink
/// frame, because ensureBackBuffer clears hasPresentedOnce -- and a guifont
/// or linespace change grows the cell height before try_resize round-trips.
/// Either way the blit would read past the texture, so rowEnd is clamped to
/// the rows that fit below the origin and the copy, the vacated band, and the
/// caller's dirty expansion all stop at that same clamped row.
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

    static func make(
        rowStart: Int,
        rowEnd: Int,
        rowsDelta: Int,
        originXPx: Int = 0,
        originYPx: Int = 0,
        widthPx: Int,
        textureWidthPx: Int,
        textureHeightPx: Int,
        rowHeightPx: Int
    ) -> RowScrollBlitPlan? {
        let shift = abs(rowsDelta)
        // Only the rows below the origin are available to this rectangle.
        let texMaxRows = rowHeightPx > 0 ? max(0, (textureHeightPx - originYPx) / rowHeightPx) : 0
        let clampedRowEnd = min(rowEnd, texMaxRows)
        let regionHeightRows = clampedRowEnd - rowStart
        guard shift > 0, shift < regionHeightRows else { return nil }
        guard widthPx > 0, rowHeightPx > 0, originXPx >= 0, originYPx >= 0 else { return nil }

        let copyWidthPx = min(widthPx, textureWidthPx - originXPx)
        guard copyWidthPx > 0 else { return nil }

        let copyHeightPx = (regionHeightRows - shift) * rowHeightPx
        guard copyHeightPx > 0 else { return nil }

        let srcYPx = originYPx + (rowsDelta > 0 ? rowStart + shift : rowStart) * rowHeightPx
        let dstYPx = originYPx + (rowsDelta > 0 ? rowStart : rowStart + shift) * rowHeightPx

        // Second clamp: the region can start low enough that even a
        // within-bounds row count runs off the end from srcY or dstY. The
        // rectangle's own bottom edge binds as well as the texture's.
        let regionBottomPx = originYPx + clampedRowEnd * rowHeightPx
        let maxCopyHeightPx = min(textureHeightPx, regionBottomPx) - max(srcYPx, dstYPx)
        let safeCopyHeightPx = min(copyHeightPx, maxCopyHeightPx)
        guard safeCopyHeightPx > 0 else { return nil }

        let clearTopPx: Int
        let clearBottomPx: Int
        let dirtyRows: Range<Int>
        if rowsDelta > 0 {
            // Scroll down: vacated at bottom, intermediate rows above.
            clearTopPx = originYPx + (clampedRowEnd - shift) * rowHeightPx
            clearBottomPx = originYPx + clampedRowEnd * rowHeightPx
            dirtyRows = max(rowStart, clampedRowEnd - 2 * shift)..<clampedRowEnd
        } else {
            // Scroll up: vacated at top, intermediate rows below.
            clearTopPx = originYPx + rowStart * rowHeightPx
            clearBottomPx = originYPx + (rowStart + shift) * rowHeightPx
            dirtyRows = rowStart..<min(clampedRowEnd, rowStart + 2 * shift)
        }

        return RowScrollBlitPlan(
            srcYPx: srcYPx,
            dstYPx: dstYPx,
            copyWidthPx: copyWidthPx,
            copyHeightPx: safeCopyHeightPx,
            clearTopPx: clearTopPx,
            clearBottomPx: clearBottomPx,
            clampedRowEnd: clampedRowEnd,
            dirtyRows: dirtyRows,
            originXPx: originXPx,
            originYPx: originYPx
        )
    }

    /// The vacated band relative to `originYPx`, for callers drawing under a
    /// layer transform, whose pixel space starts at the layer origin.
    func localClearBand() -> (clearTopPx: Int, clearBottomPx: Int) {
        (clearTopPx: clearTopPx - originYPx, clearBottomPx: clearBottomPx - originYPx)
    }

    /// The rows to redraw when the blit never ran: the back texture's pixels
    /// were never shifted, so every row in the scroll region is stale and the
    /// core will not re-send them (it only marks the vacated band dirty on the
    /// assumption the frontend shifts the rest). The region still stops at the
    /// rows that fit below `originYPx`. nil when nothing of it is inside the
    /// texture. Grid-local rows, like `dirtyRows`.
    static func dirtyRowsWithoutBlit(
        rowStart: Int,
        rowEnd: Int,
        originYPx: Int = 0,
        textureHeightPx: Int,
        rowHeightPx: Int
    ) -> Range<Int>? {
        let texMaxRows = rowHeightPx > 0 ? max(0, (textureHeightPx - originYPx) / rowHeightPx) : 0
        let clampedRowEnd = min(rowEnd, texMaxRows)
        guard clampedRowEnd > rowStart else { return nil }
        return rowStart..<clampedRowEnd
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
