import Foundation
import Metal

/// The arithmetic of the main-grid GPU row-scroll blit, kept apart from the
/// encoder so it can be checked without a device. Pixel values carry `Px`;
/// everything else is in rows.
///
/// The row count the scroll callback reports can outlive the current
/// drawable -- a window shrink is only protected on the first post-shrink
/// frame, because ensureBackBuffer clears hasPresentedOnce -- and a guifont
/// or linespace change grows the cell height before try_resize round-trips.
/// Either way the blit would read past the texture, so rowEnd is clamped to
/// the texture height and the copy, the vacated band, and the caller's dirty
/// expansion all stop at that same clamped row.
struct RowScrollBlitPlan: Equatable {
    var srcYPx: Int
    var dstYPx: Int
    var copyWidthPx: Int
    var copyHeightPx: Int
    /// The band the copy vacated, which the caller clears to the background.
    var clearTopPx: Int
    var clearBottomPx: Int
    /// scroll.rowEnd clamped to the texture: where the blit stopped.
    var clampedRowEnd: Int
    /// Rows the caller must redraw. When multiple flushes accumulate between
    /// draws, the blit shifts by the total accumulated delta D. The vacated
    /// region (D rows) must be redrawn. Additionally, intermediate scroll
    /// steps each shifted the row slot mapping, so rows that were copied by
    /// an intermediate step but then overwritten by a subsequent step have
    /// stale content in the back buffer. Expanding by 2*D covers both.
    var dirtyRows: Range<Int>

    static func make(
        rowStart: Int,
        rowEnd: Int,
        rowsDelta: Int,
        textureWidthPx: Int,
        textureHeightPx: Int,
        drawableWidthPx: Int,
        rowHeightPx: Int
    ) -> RowScrollBlitPlan? {
        let shift = abs(rowsDelta)
        let texMaxRows = rowHeightPx > 0 ? textureHeightPx / rowHeightPx : 0
        let clampedRowEnd = min(rowEnd, texMaxRows)
        let regionHeightRows = clampedRowEnd - rowStart
        guard shift > 0, shift < regionHeightRows else { return nil }
        guard drawableWidthPx > 0, rowHeightPx > 0 else { return nil }

        let copyHeightPx = (regionHeightRows - shift) * rowHeightPx
        guard copyHeightPx > 0 else { return nil }

        let srcYPx = (rowsDelta > 0 ? rowStart + shift : rowStart) * rowHeightPx
        let dstYPx = (rowsDelta > 0 ? rowStart : rowStart + shift) * rowHeightPx

        // Second clamp: the region can start low enough that even a
        // within-bounds row count runs off the end from srcY or dstY.
        let maxCopyHeightPx = textureHeightPx - max(srcYPx, dstYPx)
        let safeCopyHeightPx = min(copyHeightPx, maxCopyHeightPx)
        guard safeCopyHeightPx > 0 else { return nil }

        let clearTopPx: Int
        let clearBottomPx: Int
        let dirtyRows: Range<Int>
        if rowsDelta > 0 {
            // Scroll down: vacated at bottom, intermediate rows above.
            clearTopPx = (clampedRowEnd - shift) * rowHeightPx
            clearBottomPx = clampedRowEnd * rowHeightPx
            dirtyRows = max(rowStart, clampedRowEnd - 2 * shift)..<clampedRowEnd
        } else {
            // Scroll up: vacated at top, intermediate rows below.
            clearTopPx = rowStart * rowHeightPx
            clearBottomPx = (rowStart + shift) * rowHeightPx
            dirtyRows = rowStart..<min(clampedRowEnd, rowStart + 2 * shift)
        }

        return RowScrollBlitPlan(
            srcYPx: srcYPx,
            dstYPx: dstYPx,
            copyWidthPx: min(drawableWidthPx, textureWidthPx),
            copyHeightPx: safeCopyHeightPx,
            clearTopPx: clearTopPx,
            clearBottomPx: clearBottomPx,
            clampedRowEnd: clampedRowEnd,
            dirtyRows: dirtyRows
        )
    }

    /// The rows to redraw when the blit never ran: the back texture's pixels
    /// were never shifted, so every row in the scroll region is stale and the
    /// core will not re-send them (it only marks the vacated band dirty on the
    /// assumption the frontend shifts the rest). The region still stops at
    /// the texture. nil when nothing of it is inside the texture.
    static func dirtyRowsWithoutBlit(
        rowStart: Int,
        rowEnd: Int,
        textureHeightPx: Int,
        rowHeightPx: Int
    ) -> Range<Int>? {
        let texMaxRows = rowHeightPx > 0 ? textureHeightPx / rowHeightPx : 0
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
    let origin = MTLOrigin(x: 0, y: plan.srcYPx, z: 0)
    let size = MTLSize(width: plan.copyWidthPx, height: plan.copyHeightPx, depth: 1)
    blit.copy(from: backTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
              to: scratch, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
    blit.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
              to: backTexture, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: plan.dstYPx, z: 0))
}
