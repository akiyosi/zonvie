import AppKit

/// Sidebar card layout: where a label's line breaks fall, how tall a card
/// is, and which row a point in the sidebar lands on. Titlebar bar: its
/// line count and height.
@main
private enum TabCardLayoutTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func requireEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
        require(got == want, "\(message) (got \(got), want \(want))")
    }

    private static func chunk(_ text: String, _ fg: NSColor?) -> TabChunk {
        TabChunk(text: text, fg: fg, bg: nil, bold: false, italic: false, underline: false, strikethrough: false)
    }

    /// A break inside one chunk splits it; both halves keep its colours.
    private static func verifyBreakInsideChunk() {
        let red = NSColor.red, blue = NSColor.blue
        let got = TabCardLayout.lines([chunk("a\nb", red), chunk("c", blue)])
        requireEqual(got, [[chunk("a", red)], [chunk("b", red), chunk("c", blue)]], "break inside a chunk")
    }

    /// Only breaks: one empty line per break plus one, and a card never
    /// collapses to zero height.
    private static func verifyBreaksOnly() {
        let got = TabCardLayout.lines([chunk("\n\n", nil)])
        requireEqual(got.count, 3, "line count of a breaks-only label")
        require(got.allSatisfy { $0.isEmpty }, "breaks-only lines are empty")
        requireEqual(TabCardLayout.lines([]).count, 1, "no chunks is one empty line")
        let h1 = TabCardLayout.rowHeight_pt(lineCount: 1)
        let h3 = TabCardLayout.rowHeight_pt(lineCount: 3)
        require(h1 > 0, "one-line height is positive")
        require(h3 > h1, "three lines are taller than one")
        requireEqual(TabCardLayout.rowHeight_pt(lineCount: 0), h1, "zero lines clamps to one")
        requireEqual(h1, 28, "one-line card keeps the single-line row height")
        requireEqual(h3, 3 * 16 + 12 + 8, "multi-line card gets the extra card padding")
    }

    private static func verifyFirstLine() {
        requireEqual(TabCardLayout.firstLine("x\ny"), "x", "firstLine cuts at the first break")
        requireEqual(TabCardLayout.firstLine("x"), "x", "firstLine without a break")
        requireEqual(TabCardLayout.firstLine(""), "", "firstLine of empty")
    }

    /// Rows of 28, 60, 28: offsets 0, 28, 88, 116.
    private static func verifyOffsetsAndHitTest() {
        let offsets = TabCardLayout.rowOffsets_pt([28, 60, 28])
        requireEqual(offsets, [0, 28, 88, 116], "cumulative offsets")
        requireEqual(TabCardLayout.rowIndex(atY: 58, offsets: offsets), 1, "middle of row 2")
        requireEqual(TabCardLayout.rowIndex(atY: 88, offsets: offsets), 2, "top edge of row 3")
        requireEqual(TabCardLayout.rowIndex(atY: 116, offsets: offsets), nil, "below the last row")
        requireEqual(TabCardLayout.rowIndex(atY: -1, offsets: offsets), nil, "above the first row")
        requireEqual(TabCardLayout.rowIndex(atY: 0, offsets: [0]), nil, "no rows")
        // Drop index: first row whose centre (14, 58, 102) is past the pointer.
        requireEqual(TabCardLayout.dropIndex(atY: 13, offsets: offsets), 0, "drop before row 1")
        requireEqual(TabCardLayout.dropIndex(atY: 14, offsets: offsets), 1, "drop at row 1 centre")
        requireEqual(TabCardLayout.dropIndex(atY: 101, offsets: offsets), 2, "drop before row 3")
        requireEqual(TabCardLayout.dropIndex(atY: 500, offsets: offsets), 3, "drop after the last row")
    }

    /// The titlebar bar's line count: the most lines of any tab, empty lines
    /// and a trailing break included, a tab without chunks counting one,
    /// capped at four.
    private static func verifyTitlebarLineCount() {
        let lines = { (s: String) in TabCardLayout.lines([chunk(s, nil)]) }
        requireEqual(TabCardLayout.titlebarLineCount([]), 1, "no tabs")
        requireEqual(TabCardLayout.titlebarLineCount([[], []]), 1, "tabs without chunks")
        requireEqual(TabCardLayout.titlebarLineCount([lines("a")]), 1, "one-line label")
        requireEqual(TabCardLayout.titlebarLineCount([lines("a\nb\n")]), 3, "trailing break counts")
        requireEqual(TabCardLayout.titlebarLineCount([lines("a\n\nc")]), 3, "empty middle line counts")
        // A background tab with three lines sizes the bar for every tab.
        requireEqual(TabCardLayout.titlebarLineCount([lines("x"), [], lines("a\nb\nc")]), 3, "max over tabs")
        requireEqual(TabCardLayout.titlebarLineCount([lines("1\n2\n3\n4\n5\n6")]), 4, "capped at four")
    }

    /// What a titlebar tab draws: nothing extra without chunks, at most four
    /// lines with them.
    private static func verifyTitlebarLines() {
        requireEqual(TabCardLayout.titlebarLines([]), [], "no chunks draws the name as before")
        requireEqual(TabCardLayout.titlebarLines([chunk("a", nil)]).count, 1, "one-line label")
        requireEqual(TabCardLayout.titlebarLines([chunk("1\n2\n3\n4\n5\n6", nil)]).count, 4, "lines past four are not drawn")
    }

    /// The bar resizes only when the line count changes, never on content.
    private static func verifyTitlebarLineCountChange() {
        let lines = { (s: String) in TabCardLayout.titlebarLines([chunk(s, nil)]) }
        requireEqual(TabCardLayout.titlebarLineCountChange(from: 3, tabLines: [lines("a\nb\nc")]), nil, "same count")
        requireEqual(TabCardLayout.titlebarLineCountChange(from: 3, tabLines: [lines("x\n● done\nz")]), nil, "content change at equal count")
        requireEqual(TabCardLayout.titlebarLineCountChange(from: 1, tabLines: [lines("a\nb\nc")]), 3, "grows")
        requireEqual(TabCardLayout.titlebarLineCountChange(from: 3, tabLines: [lines("a")]), 1, "shrinks")
        requireEqual(TabCardLayout.titlebarLineCountChange(from: 1, tabLines: [[], []]), nil, "tabs without chunks keep one line")
    }

    /// One line keeps today's bar heights; each extra line adds 16pt.
    private static func verifyTitlebarBarHeight() {
        requireEqual(TabCardLayout.titlebarBarHeight_pt(base_pt: 44, lineCount: 1), 44, "transparent/unified, one line")
        requireEqual(TabCardLayout.titlebarBarHeight_pt(base_pt: 36, lineCount: 1), 36, "native, one line")
        requireEqual(TabCardLayout.titlebarBarHeight_pt(base_pt: 44, lineCount: 3), 44 + 2 * 16, "three lines")
        requireEqual(TabCardLayout.titlebarBarHeight_pt(base_pt: 36, lineCount: 0), 36, "zero lines clamps to one")
    }

    static func main() {
        verifyBreakInsideChunk()
        verifyBreaksOnly()
        verifyFirstLine()
        verifyOffsetsAndHitTest()
        verifyTitlebarLineCount()
        verifyTitlebarBarHeight()
        verifyTitlebarLines()
        verifyTitlebarLineCountChange()
        print("TabCardLayoutTests: ok")
    }
}
