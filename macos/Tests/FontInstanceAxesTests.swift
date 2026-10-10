import CoreText
import Foundation

@main
private enum FontInstanceAxesTests {
    private static var failures = 0

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            failures += 1
        }
    }

    private static func tag(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func value(_ axes: [FontInstanceAxes.Axis], _ t: String) -> Double? {
        axes.first { $0.tag == tag(t) }?.value
    }

    static func main() {
        let wght = tag("wght")
        let wdth = tag("wdth")
        let liga = tag("liga")

        // The user's axis wins over the instance's; the rest of the instance
        // stays, and non-axis entries pass through.
        let merged = FontInstanceAxes.merged(
            instance: [.init(tag: wdth, value: 100), .init(tag: wght, value: 700)],
            user: [.init(tag: wght, value: 300), .init(tag: liga, value: 1)]
        )
        require(merged == [.init(tag: wdth, value: 100), .init(tag: wght, value: 300), .init(tag: liga, value: 1)],
                "user wght=300 must replace the instance's wght=700 and keep wdth: \(merged)")

        // No user axes: the instance loads as CoreText picked it.
        require(FontInstanceAxes.merged(instance: [.init(tag: wght, value: 700)], user: []) == [.init(tag: wght, value: 700)],
                "a bold instance with no user axes must keep wght=700")

        // A static face has no coordinates; only the user's entries remain.
        require(FontInstanceAxes.merged(instance: [], user: [.init(tag: liga, value: 1)]) == [.init(tag: liga, value: 1)],
                "a static face must pass the user's entries through")

        // The premise GlyphAtlas relies on: in a variable font, the Bold face
        // CoreText picks by trait is an instance heavier than the regular
        // one, and its coordinates say so. SF Mono and Skia ship with macOS.
        var checked = 0
        for (name, family) in [("SFMono-Regular", "SF Mono"), ("Skia", "Skia")] {
            let regular = CTFontCreateWithName(name as CFString, 14, nil)
            // CoreText substitutes another family when the font is missing.
            guard (CTFontCopyFamilyName(regular) as String) == family,
                  let axes = CTFontCopyVariationAxes(regular) as? [[CFString: Any]],
                  axes.contains(where: { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value == wght }),
                  let bold = CTFontCreateCopyWithSymbolicTraits(regular, 0, nil, .traitBold, .traitBold)
            else { continue }
            let axisDefault = axes
                .first { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value == wght }?[kCTFontVariationAxisDefaultValueKey] as? NSNumber
            let regularWeight = value(FontInstanceAxes.coordinates(of: regular), "wght") ?? axisDefault?.doubleValue ?? 0
            let boldWeight = value(FontInstanceAxes.coordinates(of: bold), "wght")
            require(boldWeight != nil, "\(name): the Bold face must carry a wght coordinate")
            require((boldWeight ?? 0) > regularWeight,
                    "\(name): Bold wght \(boldWeight ?? 0) must exceed regular \(regularWeight)")
            checked += 1
        }
        if checked == 0 {
            print("FontInstanceAxesTests: no variable font with a wght axis found; CoreText check skipped")
            // Skia ships with macOS; on CI a skip means the check proved nothing.
            require(ProcessInfo.processInfo.environment["ZONVIE_REQUIRE_TEST_FONTS"] == nil,
                    "ZONVIE_REQUIRE_TEST_FONTS is set but no Bold instance of a variable font was found")
        }

        if failures == 0 {
            print("FontInstanceAxesTests: all checks passed")
        } else {
            FileHandle.standardError.write(Data("FontInstanceAxesTests: \(failures) failure(s)\n".utf8))
            exit(1)
        }
    }
}
