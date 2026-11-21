/// Atlas regions staged by one flush's glyph uploads, kept as separate row
/// bands so the texture upload copies only the rows glyphs were written to.
///
/// A single union rect spans every shelf a flush touches. Once the atlas is
/// mostly full, new glyphs land in shelves far apart and that union reaches
/// thousands of rows of a 4096-wide RGBA atlas: tens of MB copied by one
/// `replace` while the core holds grid_mu. Glyphs packed into one shelf share
/// its rows, so merging rects whose rows overlap keeps the list near one entry
/// per shelf touched.
///
/// Storage is reserved once at init; `insert` and `removeAll` never allocate.
/// Past `capacity` bands a new rect merges into the band nearest in y, which
/// trades copy size for the fixed bound. Bands may come to overlap after a
/// merge; uploading the shared rows twice copies the same pixels and is safe.
struct AtlasUploadRects {
    struct Rect: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    static let capacity = 64

    private(set) var rects: [Rect]

    init() {
        rects = []
        rects.reserveCapacity(Self.capacity)
    }

    var isEmpty: Bool { rects.isEmpty }

    mutating func insert(x: Int, y: Int, width: Int, height: Int) {
        let new = Rect(x: x, y: y, width: width, height: height)
        for i in rects.indices where Self.rowsOverlap(rects[i], new) {
            rects[i] = Self.union(rects[i], new)
            return
        }
        if rects.count < Self.capacity {
            rects.append(new)
            return
        }
        var nearest = 0
        var nearestGap = Int.max
        for i in rects.indices {
            let gap = Self.rowGap(rects[i], new)
            if gap < nearestGap {
                nearest = i
                nearestGap = gap
            }
        }
        rects[nearest] = Self.union(rects[nearest], new)
    }

    mutating func removeAll() {
        rects.removeAll(keepingCapacity: true)
    }

    private static func rowsOverlap(_ a: Rect, _ b: Rect) -> Bool {
        a.y < b.y + b.height && b.y < a.y + a.height
    }

    private static func rowGap(_ a: Rect, _ b: Rect) -> Int {
        max(0, max(a.y, b.y) - min(a.y + a.height, b.y + b.height))
    }

    private static func union(_ a: Rect, _ b: Rect) -> Rect {
        let minX = min(a.x, b.x)
        let minY = min(a.y, b.y)
        return Rect(
            x: minX,
            y: minY,
            width: max(a.x + a.width, b.x + b.width) - minX,
            height: max(a.y + a.height, b.y + b.height) - minY
        )
    }
}
