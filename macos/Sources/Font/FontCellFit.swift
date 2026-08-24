import Foundation

/// Vertical placement of the text baseline inside a cell.
enum FontCellFit {
    /// Baseline offset in pixels from the cell's top edge, given a font's
    /// unrounded ascent and descent.
    ///
    /// FreeType grid-fits both metrics outward, so anchoring the baseline on
    /// its ascender pushes the whole rounding error below the descender and
    /// past the bottom edge of the cell (measured: Menlo 13pt @2x reports
    /// 25 + 7 against a line height of 30, where the true metrics are
    /// 24.13 + 6.13). The per-row scissor and the next row's background quad
    /// erase whatever crosses the edge, so glyphs drawn to join across rows
    /// lose the join and show an undrawn seam on the boundary.
    ///
    /// Centring the ink box in the cell equalizes how far it reaches past the
    /// two edges, which minimizes the worst of the two: the overhang that
    /// remains is a fraction of a pixel and survives as antialiasing. The
    /// result is rounded so glyphs stay aligned to the pixel grid.
    static func baselinePx(fontAscentPx: Float, fontDescentPx: Float, cellHeightPx: Float) -> Float {
        guard cellHeightPx > 0 else { return fontAscentPx }
        let leadingPx = cellHeightPx - (fontAscentPx + fontDescentPx)
        let centeredPx = (fontAscentPx + leadingPx / 2).rounded()
        return min(cellHeightPx, max(0, centeredPx))
    }
}
