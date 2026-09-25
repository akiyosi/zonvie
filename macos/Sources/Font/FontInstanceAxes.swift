import CoreText
import Foundation

/// Variation coordinates to load a face into FreeType with.
///
/// FreeType opens a variable font file at its default instance. The Bold,
/// Italic and BoldItalic faces are CTFonts CoreText picks by trait, and in a
/// variable font (SF Mono, Cascadia Code, JetBrainsMono[wght]) they are named
/// instances of the same file, so loading the file alone drew them at the
/// default weight. The instance's own coordinates come first; the axes of the
/// user's [font] family entry replace any axis they name.
enum FontInstanceAxes {
    struct Axis: Equatable {
        /// OpenType tag packed big-endian ('wght' = 0x77676874).
        let tag: UInt32
        let value: Double
    }

    /// The design coordinates of the instance `font` is, or none for a
    /// static face.
    static func coordinates(of font: CTFont) -> [Axis] {
        guard let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber] else { return [] }
        return variation
            .map { Axis(tag: $0.key.uint32Value, value: $0.value.doubleValue) }
            .sorted { $0.tag < $1.tag }
    }

    /// `instance`, with every axis `user` names replaced by the user's value,
    /// followed by the user's entries. Non-axis entries (liga, ss01) pass
    /// through; zonvie_ft_hb_font_set_variations ignores tags the font has
    /// no axis for.
    static func merged(instance: [Axis], user: [Axis]) -> [Axis] {
        instance.filter { axis in !user.contains { $0.tag == axis.tag } } + user
    }
}
