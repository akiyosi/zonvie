import Foundation

/// The staged atlas upload: glyphs in one shelf share a band, glyphs in
/// distant shelves stay apart, and the band count stays within capacity.
@main
private enum AtlasUploadRectsTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func requireEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
        require(got == want, "\(message) (got \(got), want \(want))")
    }

    private typealias Rect = AtlasUploadRects.Rect

    static func main() {
        sameShelfMerges()
        distantShelvesStaySeparate()
        tallerGlyphInShelfGrowsBand()
        touchingRowsDoNotMerge()
        overflowMergesIntoNearestBand()
        removeAllKeepsCapacity()
        print("atlas-upload-rects-tests: ok")
    }

    /// Two glyphs packed side by side in one shelf become one band.
    private static func sameShelfMerges() {
        var r = AtlasUploadRects()
        r.insert(x: 0, y: 100, width: 30, height: 34)
        r.insert(x: 31, y: 100, width: 30, height: 34)
        requireEqual(r.rects, [Rect(x: 0, y: 100, width: 61, height: 34)], "same shelf")
    }

    /// The case that made one union rect thousands of rows tall: a glyph near
    /// the top and one near the bottom of the atlas.
    private static func distantShelvesStaySeparate() {
        var r = AtlasUploadRects()
        r.insert(x: 0, y: 10, width: 30, height: 34)
        r.insert(x: 500, y: 3800, width: 30, height: 34)
        requireEqual(r.rects, [
            Rect(x: 0, y: 10, width: 30, height: 34),
            Rect(x: 500, y: 3800, width: 30, height: 34),
        ], "distant shelves")
        let rows = r.rects.reduce(0) { $0 + $1.height }
        requireEqual(rows, 68, "rows copied")
    }

    /// A shorter glyph and a taller one in the same shelf share the band.
    private static func tallerGlyphInShelfGrowsBand() {
        var r = AtlasUploadRects()
        r.insert(x: 0, y: 200, width: 20, height: 20)
        r.insert(x: 21, y: 200, width: 20, height: 34)
        requireEqual(r.rects, [Rect(x: 0, y: 200, width: 41, height: 34)], "taller glyph")
    }

    /// Adjacent shelves share no row, so they stay two bands.
    private static func touchingRowsDoNotMerge() {
        var r = AtlasUploadRects()
        r.insert(x: 0, y: 0, width: 10, height: 10)
        r.insert(x: 0, y: 10, width: 10, height: 10)
        requireEqual(r.rects.count, 2, "touching rows")
    }

    /// Past capacity the band count holds and the rect lands in the nearest
    /// band, so every staged pixel is still covered.
    private static func overflowMergesIntoNearestBand() {
        var r = AtlasUploadRects()
        for i in 0..<AtlasUploadRects.capacity {
            r.insert(x: 0, y: i * 100, width: 10, height: 10)
        }
        requireEqual(r.rects.count, AtlasUploadRects.capacity, "filled")
        r.insert(x: 50, y: 3015, width: 10, height: 10)
        requireEqual(r.rects.count, AtlasUploadRects.capacity, "bounded")
        let covering = r.rects.filter { $0.y <= 3015 && $0.y + $0.height >= 3025 && $0.x <= 50 && $0.x + $0.width >= 60 }
        requireEqual(covering, [Rect(x: 0, y: 3000, width: 60, height: 25)], "merged into nearest")
    }

    private static func removeAllKeepsCapacity() {
        var r = AtlasUploadRects()
        r.insert(x: 0, y: 0, width: 10, height: 10)
        r.removeAll()
        require(r.isEmpty, "emptied")
        require(r.rects.capacity >= AtlasUploadRects.capacity, "capacity kept")
    }
}
