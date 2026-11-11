import AppKit

/// One styled run of a tab label from 'guitablabel' (`zonvie_tab_chunk`).
/// A nil colour means the chunk's highlight set none: the view's own applies.
struct TabChunk: Equatable {
    let text: String
    let fg: NSColor?
    let bg: NSColor?
    let bold, italic, underline, strikethrough: Bool
}

/// Multi-line tab label geometry for the sidebar cards and the titlebar tab
/// bar, kept free of view state so it can be tested alone.
enum TabCardLayout {
    static let lineHeight_pt: CGFloat = 16
    static let verticalPadding_pt: CGFloat = 12
    /// Extra breathing room for multi-line cards only, so a one-line row
    /// keeps the single-line row height.
    static let cardExtraPadding_pt: CGFloat = 8

    /// Top plus bottom padding of a row with this many lines.
    static func rowPadding_pt(lineCount: Int) -> CGFloat {
        verticalPadding_pt + (lineCount > 1 ? cardExtraPadding_pt : 0)
    }

    /// Splits the runs at each "\n" into card lines. A run broken by "\n"
    /// keeps its style on both sides; empty pieces are dropped, so a label of
    /// only breaks yields empty lines. Always at least one line.
    static func lines(_ chunks: [TabChunk]) -> [[TabChunk]] {
        var result: [[TabChunk]] = [[]]
        for chunk in chunks {
            let pieces = chunk.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, piece) in pieces.enumerated() {
                if i > 0 { result.append([]) }
                if piece.isEmpty { continue }
                result[result.count - 1].append(TabChunk(
                    text: String(piece), fg: chunk.fg, bg: chunk.bg, bold: chunk.bold,
                    italic: chunk.italic, underline: chunk.underline, strikethrough: chunk.strikethrough))
            }
        }
        return result
    }

    /// The label up to its first "\n": what single-line renderers show.
    static func firstLine(_ name: String) -> String {
        guard let nl = name.firstIndex(of: "\n") else { return name }
        return String(name[..<nl])
    }

    /// One line is the single-line row height; never less than one line.
    static func rowHeight_pt(lineCount: Int) -> CGFloat {
        CGFloat(max(1, lineCount)) * lineHeight_pt + rowPadding_pt(lineCount: lineCount)
    }

    /// Top of each row followed by the bottom of the last: count + 1 entries.
    static func rowOffsets_pt(_ heights_pt: [CGFloat]) -> [CGFloat] {
        var offsets: [CGFloat] = [0]
        offsets.reserveCapacity(heights_pt.count + 1)
        for h in heights_pt { offsets.append(offsets[offsets.count - 1] + h) }
        return offsets
    }

    /// The row containing `y`, top edge inclusive.
    static func rowIndex(atY y: CGFloat, offsets: [CGFloat]) -> Int? {
        for i in 0..<max(0, offsets.count - 1) where y >= offsets[i] && y < offsets[i + 1] {
            return i
        }
        return nil
    }

    /// The first row whose centre is past `y`, or the row count: the same
    /// rule as `zonvie_core_tab_drop_index`, over rows of differing height.
    static func dropIndex(atY y: CGFloat, offsets: [CGFloat]) -> Int {
        let count = max(0, offsets.count - 1)
        for i in 0..<count where y < (offsets[i] + offsets[i + 1]) / 2 {
            return i
        }
        return count
    }

    /// The titlebar bar grows at most this many lines; lines past it are not
    /// drawn, so a runaway label cannot take over the editor.
    static let titlebarMaxLines = 4

    /// The lines a titlebar tab draws: none without chunks (the tab draws its
    /// name as before), otherwise the label's lines up to the cap.
    static func titlebarLines(_ chunks: [TabChunk]) -> [[TabChunk]] {
        chunks.isEmpty ? [] : Array(lines(chunks).prefix(titlebarMaxLines))
    }

    /// The bar's new line count after a tabline update, or nil when it is
    /// unchanged: only a change of the count resizes the bar, never a change
    /// of label content.
    static func titlebarLineCountChange(from current: Int, tabLines: [[[TabChunk]]]) -> Int? {
        let count = titlebarLineCount(tabLines)
        return count == current ? nil : count
    }

    /// The lines the titlebar bar is tall enough for: the most any tab's
    /// label has (empty lines count), capped. A tab without chunks has no
    /// lines and counts one. Every tab counts, so switching tabs never
    /// resizes the bar.
    static func titlebarLineCount(_ tabLines: [[[TabChunk]]]) -> Int {
        min(titlebarMaxLines, tabLines.map { max(1, $0.count) }.max() ?? 1)
    }

    /// The bar at one line is `base_pt`; it grows down by a line height per
    /// extra line, so the band the window buttons sit in keeps its height.
    static func titlebarBarHeight_pt(base_pt: CGFloat, lineCount: Int) -> CGFloat {
        base_pt + CGFloat(max(1, lineCount) - 1) * lineHeight_pt
    }

    /// One label line as runs in their chunk styles. A chunk without fg takes
    /// `defaultColor`. Chunk bg is never painted: Neovim combines every chunk
    /// over TabLine/TabLineSel, so its bg is that base, which would show as a
    /// band over the tab's own background.
    static func attributedLine(_ line: [TabChunk], font: NSFont, defaultColor: NSColor,
                               paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for chunk in line {
            var runFont = font
            var traits: NSFontDescriptor.SymbolicTraits = []
            if chunk.bold { traits.insert(.bold) }
            if chunk.italic { traits.insert(.italic) }
            if !traits.isEmpty {
                let desc = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                runFont = NSFont(descriptor: desc, size: font.pointSize) ?? font
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: chunk.fg ?? defaultColor,
                .paragraphStyle: paragraphStyle,
            ]
            if chunk.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if chunk.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: chunk.text, attributes: attrs))
        }
        return result
    }
}
