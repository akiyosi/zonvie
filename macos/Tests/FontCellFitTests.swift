import Foundation

@main
private enum FontCellFitTests {
    private static var failures = 0

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            failures += 1
        }
    }

    /// Metrics captured from a running app at 2x backing scale. `fontAscentPx`
    /// and `fontDescentPx` are CoreText's unrounded values; FreeType reports
    /// their ceilings, and `cellHeightPx` is the line height it reports for the
    /// same size.
    private struct Metrics {
        let name: String
        let fontAscentPx: Float
        let fontDescentPx: Float
        let cellHeightPx: Float
    }

    private static let measured: [Metrics] = [
        Metrics(name: "Menlo:h10", fontAscentPx: 18.564453125, fontDescentPx: 4.716796875, cellHeightPx: 23),
        Metrics(name: "Menlo:h11", fontAscentPx: 20.4208984375, fontDescentPx: 5.1884765625, cellHeightPx: 26),
        Metrics(name: "Menlo:h12", fontAscentPx: 22.27734375, fontDescentPx: 5.66015625, cellHeightPx: 28),
        Metrics(name: "Menlo:h13", fontAscentPx: 24.1337890625, fontDescentPx: 6.1318359375, cellHeightPx: 30),
        Metrics(name: "Menlo:h14", fontAscentPx: 25.990234375, fontDescentPx: 6.603515625, cellHeightPx: 33),
        Metrics(name: "Menlo:h15", fontAscentPx: 27.8466796875, fontDescentPx: 7.0751953125, cellHeightPx: 35),
        Metrics(name: "Menlo:h16", fontAscentPx: 29.703125, fontDescentPx: 7.546875, cellHeightPx: 37),
        Metrics(name: "Menlo:h17", fontAscentPx: 31.5595703125, fontDescentPx: 8.0185546875, cellHeightPx: 40),
        Metrics(name: "Menlo:h18", fontAscentPx: 33.416015625, fontDescentPx: 8.490234375, cellHeightPx: 42),
        Metrics(name: "Menlo:h19", fontAscentPx: 35.2724609375, fontDescentPx: 8.9619140625, cellHeightPx: 44),
        Metrics(name: "Menlo:h20", fontAscentPx: 37.12890625, fontDescentPx: 9.43359375, cellHeightPx: 47),
        Metrics(name: "ZundaEmoji:h20", fontAscentPx: 37.109375, fontDescentPx: 9.765625, cellHeightPx: 47),
        Metrics(name: "ZundaEmoji:h11", fontAscentPx: 20.41015625, fontDescentPx: 5.37109375, cellHeightPx: 26),
    ]

    /// How far the ink box reaches past the cell's edges, which is what the
    /// per-row scissor and the neighbouring row's background quad erase.
    private static func worstOverhangPx(_ m: Metrics, baselinePx: Float) -> Float {
        let abovePx = max(0, m.fontAscentPx - baselinePx)
        let belowPx = max(0, baselinePx + m.fontDescentPx - m.cellHeightPx)
        return max(abovePx, belowPx)
    }

    static func main() {
        for m in measured {
            let baselinePx = FontCellFit.baselinePx(
                fontAscentPx: m.fontAscentPx,
                fontDescentPx: m.fontDescentPx,
                cellHeightPx: m.cellHeightPx
            )

            // Fractional baselines blur every glyph in the grid.
            require(baselinePx == baselinePx.rounded(),
                    "\(m.name): baseline \(baselinePx) must land on the pixel grid")
            require(baselinePx >= 0 && baselinePx <= m.cellHeightPx,
                    "\(m.name): baseline \(baselinePx) must stay inside the cell")

            // No integer baseline may leave less ink inside the cell than the
            // one chosen. Anchoring on the ascent — what this replaces — loses
            // this for any font whose grid-fitted metrics overflow the cell.
            let bestPx = stride(from: Float(0), through: m.cellHeightPx, by: 1)
                .map { worstOverhangPx(m, baselinePx: $0) }
                .min() ?? 0
            require(worstOverhangPx(m, baselinePx: baselinePx) <= bestPx,
                    "\(m.name): baseline \(baselinePx) overhangs "
                        + "\(worstOverhangPx(m, baselinePx: baselinePx))px, "
                        + "but \(bestPx)px is reachable")
        }

        // Metrics are zero until a font resolves; leave the baseline alone
        // rather than reporting an offset derived from nothing.
        require(FontCellFit.baselinePx(fontAscentPx: 12, fontDescentPx: 4, cellHeightPx: 0) == 12,
                "unresolved cell height must not move the baseline")

        // A cell too small to hold the font still has to yield a usable offset.
        require(FontCellFit.baselinePx(fontAscentPx: 4, fontDescentPx: 40, cellHeightPx: 8) >= 0,
                "baseline must never sit above the cell's top edge")

        if failures == 0 {
            print("FontCellFitTests: all checks passed")
        } else {
            FileHandle.standardError.write(Data("FontCellFitTests: \(failures) failure(s)\n".utf8))
            exit(1)
        }
    }
}
