import AppKit
import CoreText
import Metal
import os

// Style flags (must match ZONVIE_STYLE_* in zonvie_core.h)
private let ZONVIE_STYLE_BOLD: UInt32 = 1 << 0
private let ZONVIE_STYLE_ITALIC: UInt32 = 1 << 1

final class GlyphAtlas {
    // Use os_unfair_lock instead of NSLock for better performance
    // os_unfair_lock is a low-level spin lock that's faster for short critical sections
    private var mu = os_unfair_lock()  

    struct Entry {
        let uvMin: SIMD2<Float>
        let uvMax: SIMD2<Float>

        /// Bounding box of the rendered line in CoreText coordinates (pixels, y-up),
        /// relative to the baseline at (0, 0). Does NOT include padding.
        let bboxOriginPx: SIMD2<Float>
        let bboxSizePx: SIMD2<Float>

        /// Padding applied around bbox in the bitmap.
        let padPx: Float

        /// Typographic advance in pixels (best-effort; renderer currently uses cell width).
        let advancePx: Float
    }

    private let device: MTLDevice
    private var font: CTFont
    private var fontName: String
    private var pointSize: CGFloat
    private var backingScale: CGFloat = 1.0

    // OpenType font features (parsed from guifont string).
    private var fontFeatures: [zonvie_font_feature] = []
    private var hasFeatures: Bool { !fontFeatures.isEmpty }

    // Font variants for bold/italic
    private var boldFont: CTFont?
    private var italicFont: CTFont?
    private var boldItalicFont: CTFont?

    /// Current font name (read-only for external use).
    var currentFontName: String { fontName }
    /// Current point size (read-only for external use).
    var currentPointSize: CGFloat { pointSize }

    private(set) var ascentPx: Float = 0
    private(set) var descentPx: Float = 0

    private(set) var texture: MTLTexture?

    // Atlas config (keep simple; can be parameterized later).
    private let atlasW: Int = 2048
    private let atlasH: Int = 2048

    // HarfBuzz+FreeType backend handle (base font).
    private var hbftFont: OpaquePointer?

    // HarfBuzz+FreeType handles for font variants
    private var hbftBold: OpaquePointer?
    private var hbftItalic: OpaquePointer?
    private var hbftBoldItalic: OpaquePointer?

    // --- Fallback font support ---
    // We must avoid collisions: same glyphID can exist across different fonts.
    // Key = (fontKey, glyphID)
    private struct GlyphKey: Hashable {
        let fontKey: UInt64     // stable ID per hbft font handle (pointer address)
        let glyphID: UInt32
    }

    private struct HbFtFace {
        let ctFont: CTFont
        let url: URL
        let hbft: OpaquePointer
        let key: UInt64
    }

    // base face is represented by (font, hbftFont). Fallback faces are cached by URL string.
    private var fallbackFacesByURL: [String: HbFtFace] = [:]

    // Cache for CTFontCreateForString results to avoid expensive per-glyph lookups.
    // Keyed by (base font pointer, scalar) to avoid returning a bold fallback
    // for a non-bold request (or vice versa).
    private struct FallbackCacheKey: Hashable {
        let baseFont: UInt   // pointer address of the base CTFont
        let scalar: UInt32
    }
    private var fallbackFontCache: [FallbackCacheKey: CTFont] = [:]

    // Cache for scalars that failed glyph lookup (to avoid repeated expensive failures).
    // Key: (scalar, styleFlags). Cleared when font settings change.
    private var failedScalarCache: Set<UInt64> = []

    // Cache for scalar → glyphID mapping to avoid CTFontGetGlyphsForCharacters calls.
    // Key: (fontKey << 32) | scalar, Value: glyphID. Cleared when font settings change.
    private var scalarToGlyphIDCache: [UInt64: UInt32] = [:]

    private var nextX: Int = 1
    private var nextY: Int = 1
    private var rowH: Int = 0

    // NOTE: cache entries by (font, glyphID), not glyphID only.
    private var map: [GlyphKey: GlyphAtlas.Entry] = [:]





    private var scratch: [UInt8] = []

    /// Separate scratch buffer for rasterizeOnly (Phase 2).
    /// Must not share with `scratch` which is used by uploadRegion.
    private var rasterizeScratch: [UInt8] = []

    /// Persistent y-advance buffer for shapeTextRun (avoids per-call heap allocation).
    private var shapeYAdvBuf: [Int32] = []

    /// Maximum scratch buffer size (64KB - sufficient for large glyphs/emoji)
    private let maxScratchSize: Int = 64 * 1024

    /// Cell metrics (in drawable pixel coordinates) referenced by the renderer.
    private(set) var cellWidthPx: Float = 9
    private(set) var cellHeightPx: Float = 18

    init(device: MTLDevice, fontName: String = "Menlo", pointSize: CGFloat = 14.0) {
        self.device = device
        self.fontName = fontName
        self.pointSize = pointSize
        self.font = CTFontCreateWithName(fontName as CFString, pointSize, nil) // temporary

        os_unfair_lock_lock(&mu)
        rebuildFont_locked()
        os_unfair_lock_unlock(&mu)
    }
    
    func setFont(name: String, pointSize: CGFloat, features: String = "") {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        self.fontName = name
        self.pointSize = pointSize
        self.fontFeatures = Self.parseFontFeatures(features)
        ZonvieCore.appLog("[GlyphAtlas.setFont] name='\(name)' pt=\(pointSize) features_str='\(features)' parsed_count=\(self.fontFeatures.count) hasFeatures=\(hasFeatures)")
        rebuildFont_locked()
    }

    /// Parse comma-separated feature string: "+liga,-dlig,ss01=2"
    private static func parseFontFeatures(_ s: String) -> [zonvie_font_feature] {
        guard !s.isEmpty else { return [] }
        return s.split(separator: ",").compactMap { token in
            let t = token.trimmingCharacters(in: .whitespaces)
            var tag: String
            var value: UInt32

            if t.contains("=") {
                let kv = t.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, kv[0].count == 4, let val = UInt32(kv[1]) else { return nil }
                tag = String(kv[0])
                value = val
            } else if t.hasPrefix("+") {
                tag = String(t.dropFirst())
                guard tag.count == 4 else { return nil }
                value = 1
            } else if t.hasPrefix("-") {
                tag = String(t.dropFirst())
                guard tag.count == 4 else { return nil }
                value = 0
            } else {
                guard t.count == 4 else { return nil }
                tag = t
                value = 1
            }

            let bytes = Array(tag.utf8)
            guard bytes.count == 4 else { return nil }
            var feature = zonvie_font_feature()
            feature.tag = (Int8(bitPattern: bytes[0]), Int8(bitPattern: bytes[1]),
                           Int8(bitPattern: bytes[2]), Int8(bitPattern: bytes[3]))
            feature.value = value
            return feature
        }
    }
    
    func setBackingScale(_ s: CGFloat) {
        let ns = max(0.5, min(8.0, s))
    
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        if backingScale == ns { return }
        backingScale = ns
        rebuildFont_locked()
    }

    private func recomputeMetrics() {
        // Prefer FreeType metrics to match the rasterization backend.
        if let hbftFont {
            var asc26_6: Int32 = 0
            var desc26_6: Int32 = 0
            var height26_6: Int32 = 0
    
            // "metrics-only" call: scalar_count=0, out_cap=0
            var dummy: UInt32 = 0
            withUnsafePointer(to: &dummy) { dummyPtr in
                _ = zonvie_hb_shape_utf32(
                    hbftFont,
                    dummyPtr,
                    0,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil,
                    0,
                    &asc26_6,
                    &desc26_6,
                    &height26_6
                )
            }
    
            let ascPx = Float(asc26_6) / 64.0
            let descPx = Float(-desc26_6) / 64.0 // FT descender is typically negative
            let heightPx = Float(height26_6) / 64.0
    
            if ascPx > 0 { ascentPx = Float(ceil(ascPx)) }
            if descPx > 0 { descentPx = Float(ceil(descPx)) }
    
            // Use FT height if valid; fallback to asc+desc.
            let h = (heightPx > 0) ? heightPx : (ascPx + descPx)
            if h > 0 { cellHeightPx = Float(ceil(h)) }
    
            // --- Determine cellWidthPx from FT advance (monospace assumption) ---
            // Prefer space; fallback to 'M' if space has no glyph/advance.
            let scalarSpace: UInt32 = 32
            let scalarM: UInt32 = UInt32(UnicodeScalar("M").value)

            if let gid = glyphID(in: font, scalar: scalarSpace) ?? glyphID(in: font, scalar: scalarM) {
                var bufPtr: UnsafePointer<UInt8>? = nil
                var w: Int32 = 0
                var h: Int32 = 0
                var pitch: Int32 = 0
                var left: Int32 = 0
                var top: Int32 = 0
                var adv26_6: Int32 = 0

                let r = zonvie_ft_render_glyph(
                    hbftFont,
                    gid,
                    &bufPtr,
                    &w,
                    &h,
                    &pitch,
                    &left,
                    &top,
                    &adv26_6
                )

                if r == 0 && adv26_6 > 0 {
                    let advPx = Float(adv26_6) / 64.0
                    cellWidthPx = Float(ceil(advPx))
                } else {
                    // Fallback: CoreText advance (still in pixels for the current CTFont size).
                    var cg = CGGlyph(gid)
                    var adv = CGSize.zero
                    CTFontGetAdvancesForGlyphs(font, .horizontal, &cg, &adv, 1)
                    if adv.width > 0 {
                        cellWidthPx = Float(ceil(adv.width))
                    }
                }
            }
        } else {
            // Fallback: CoreText metrics are in pixels for the current CTFont size (already scaled).
            let ascent = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            ascentPx = Float(ascent)
            descentPx = Float(descent)
            cellHeightPx = Float(ceil(ascent + descent))
        }
    }

    // NOTE: only call when holding mu
    private func rebuildFont_locked() {
        // CTFont also used for CoreText-side references like glyphID(forScalar:)
        font = CTFontCreateWithName(fontName as CFString, pointSize * backingScale, nil)

        // Load font variants (bold, italic, bold+italic)
        loadFontVariants_locked()

        // First rebuild FreeType/HarfBuzz side with 'new size'
        rebuildHbFtFont_locked()

        // Use that hbftFont (new) to finalize metrics
        recomputeMetrics()

        // Drop fallback faces and caches (they depend on pixel size / font settings).
        for (_, f) in fallbackFacesByURL {
            zonvie_ft_hb_font_destroy(f.hbft)
        }
        fallbackFacesByURL.removeAll()
        fallbackFontCache.removeAll()
        failedScalarCache.removeAll()
        scalarToGlyphIDCache.removeAll()

        // After finalizing metrics, rebuild atlas (to match cellWidth/Height)
        resetAtlas_locked()
    }

    private func loadFontVariants_locked() {
        // Create bold variant
        boldFont = CTFontCreateCopyWithSymbolicTraits(
            font,
            0, // use same size
            nil, // no matrix
            .traitBold,
            .traitBold
        )

        // Create italic variant
        italicFont = CTFontCreateCopyWithSymbolicTraits(
            font,
            0,
            nil,
            .traitItalic,
            .traitItalic
        )

        // Create bold+italic variant
        boldItalicFont = CTFontCreateCopyWithSymbolicTraits(
            font,
            0,
            nil,
            [.traitBold, .traitItalic],
            [.traitBold, .traitItalic]
        )
    }



    private func rebuildHbFtFont_locked() {
        // Clean up existing handles
        if let hbftFont {
            zonvie_ft_hb_font_destroy(hbftFont)
            self.hbftFont = nil
        }
        if let hbftBold {
            zonvie_ft_hb_font_destroy(hbftBold)
            self.hbftBold = nil
        }
        if let hbftItalic {
            zonvie_ft_hb_font_destroy(hbftItalic)
            self.hbftItalic = nil
        }
        if let hbftBoldItalic {
            zonvie_ft_hb_font_destroy(hbftBoldItalic)
            self.hbftBoldItalic = nil
        }

        let px = UInt32(ceil(pointSize * backingScale))

        // Build base font
        self.hbftFont = createHbFtFont_locked(for: font, px: px)
        if self.hbftFont == nil {
            assertionFailure("zonvie_ft_hb_font_create failed for base font")
        }

        // Build bold variant
        if let boldFont {
            self.hbftBold = createHbFtFont_locked(for: boldFont, px: px)
        }

        // Build italic variant
        if let italicFont {
            self.hbftItalic = createHbFtFont_locked(for: italicFont, px: px)
        }

        // Build bold+italic variant
        if let boldItalicFont {
            self.hbftBoldItalic = createHbFtFont_locked(for: boldItalicFont, px: px)
        }

        // Apply OpenType features to all font handles
        applyFeatures_locked(to: self.hbftFont)
        applyFeatures_locked(to: self.hbftBold)
        applyFeatures_locked(to: self.hbftItalic)
        applyFeatures_locked(to: self.hbftBoldItalic)
    }

    /// Apply stored font features to a HarfBuzz font handle.
    private func applyFeatures_locked(to hbft: OpaquePointer?) {
        guard let hbft = hbft, !fontFeatures.isEmpty else { return }
        fontFeatures.withUnsafeBufferPointer { buf in
            zonvie_ft_hb_font_set_features(hbft, buf.baseAddress, buf.count)
        }
    }

    private func createHbFtFont_locked(for ctFont: CTFont, px: UInt32) -> OpaquePointer? {
        let desc = CTFontCopyFontDescriptor(ctFont)
        guard let url = CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute) as? URL else {
            return nil
        }

        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        let faceIndex = ctFontFaceIndex(ctFont)

        let created: OpaquePointer? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OpaquePointer? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return zonvie_ft_hb_font_create(base, raw.count, px, faceIndex)
        }

        return created
    }

    private func ctFontFaceIndex(_ ctFont: CTFont) -> UInt32 {
        // kCTFontIndexAttribute may not be visible in SDK, so reference it via CoreText attribute name string.
        // CTFontDescriptor's index attribute is "NSCTFontIndexAttribute".
        let kCTFontIndexAttributeKey: CFString = "NSCTFontIndexAttribute" as CFString
    
        let desc = CTFontCopyFontDescriptor(ctFont)
        if let n = CTFontDescriptorCopyAttribute(desc, kCTFontIndexAttributeKey) as? NSNumber {
            let v = n.intValue
            return v >= 0 ? UInt32(v) : 0
        }
        return 0
    }

    private func ensureHbFtFace_locked(for ctFont: CTFont) -> HbFtFace? {
        let desc = CTFontCopyFontDescriptor(ctFont)
        guard let url = CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute) as? URL else {
            return nil
        }
    
        let faceIndex = ctFontFaceIndex(ctFont)
        let urlKey = "\(url.absoluteString)#\(faceIndex)"
    
        if let cached = fallbackFacesByURL[urlKey] {
            return cached
        }

        let loadStart = CFAbsoluteTimeGetCurrent()
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let loadEnd = CFAbsoluteTimeGetCurrent()

        let px = UInt32(ceil(pointSize * backingScale))

        // IMPORTANT: make the closure explicitly return OpaquePointer?
        let created: OpaquePointer? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OpaquePointer? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return zonvie_ft_hb_font_create(base, raw.count, px, faceIndex)
        }
        let createEnd = CFAbsoluteTimeGetCurrent()

        guard let hbft = created else { return nil }

        // Apply OpenType features to fallback font handle too
        applyFeatures_locked(to: hbft)

        let loadMs = (loadEnd - loadStart) * 1000
        let createMs = (createEnd - loadEnd) * 1000
        ZonvieCore.appLog("[Atlas] NEW fallback font: \(url.lastPathComponent) load=\(String(format: "%.1f", loadMs))ms create=\(String(format: "%.1f", createMs))ms")

        let key = UInt64(UInt(bitPattern: hbft))
        let face = HbFtFace(ctFont: ctFont, url: url, hbft: hbft, key: key)
        fallbackFacesByURL[urlKey] = face
        return face
    }

    func entry(for scalar: UInt32) -> GlyphAtlas.Entry? {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        // Check if this scalar already failed (avoid repeated expensive lookups)
        let failKey = UInt64(scalar) // styleFlags=0 for base entry
        if failedScalarCache.contains(failKey) {
            return nil
        }

        let scalarChar = UnicodeScalar(scalar).map { String($0) } ?? "?"

        // 1) Try base font first
        if let gid = glyphID(in: font, scalar: scalar) {
            guard let baseHbft = hbftFont else {
                ZonvieCore.appLog("[Atlas] entry(scalar=\(scalar) '\(scalarChar)'): base hbft is nil")
                failedScalarCache.insert(failKey)
                return nil
            }
            let k = GlyphKey(fontKey: UInt64(UInt(bitPattern: baseHbft)), glyphID: gid)
            let e = entry_forKey_locked(k, hbft: baseHbft, glyphID: gid)
            return e
        }

        // 2) Fallback via CoreText
        guard let fbCT = ctFontForScalarFallback(base: font, scalar: scalar) else {
            ZonvieCore.appLog("[Atlas] entry(scalar=\(scalar) '\(scalarChar)'): no fallback font")
            failedScalarCache.insert(failKey)
            return nil
        }
        guard let fbGid = glyphID(in: fbCT, scalar: scalar) else {
            ZonvieCore.appLog("[Atlas] entry(scalar=\(scalar) '\(scalarChar)'): fallback font has no glyph")
            failedScalarCache.insert(failKey)
            return nil
        }
        guard let face = ensureHbFtFace_locked(for: fbCT) else {
            ZonvieCore.appLog("[Atlas] entry(scalar=\(scalar) '\(scalarChar)'): failed to create hbft face")
            failedScalarCache.insert(failKey)
            return nil
        }

        let k = GlyphKey(fontKey: face.key, glyphID: fbGid)
        let e = entry_forKey_locked(k, hbft: face.hbft, glyphID: fbGid)
        return e
    }

    /// Get glyph entry with style flags (bold/italic).
    /// styleFlags: ZONVIE_STYLE_BOLD (1 << 0), ZONVIE_STYLE_ITALIC (1 << 1)
    func entry(for scalar: UInt32, styleFlags: UInt32) -> GlyphAtlas.Entry? {
        // If no style flags, use base font
        if styleFlags == 0 {
            return entry(for: scalar)
        }

        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        // Check if this scalar+style already failed (avoid repeated expensive lookups)
        let failKey = (UInt64(styleFlags) << 32) | UInt64(scalar)
        if failedScalarCache.contains(failKey) {
            return nil
        }

        let isBold = (styleFlags & ZONVIE_STYLE_BOLD) != 0
        let isItalic = (styleFlags & ZONVIE_STYLE_ITALIC) != 0

        // Select appropriate font variant and hbft handle
        let (selectedFont, selectedHbft): (CTFont?, OpaquePointer?) = {
            if isBold && isItalic {
                return (boldItalicFont ?? boldFont ?? italicFont, hbftBoldItalic ?? hbftBold ?? hbftItalic)
            } else if isBold {
                return (boldFont, hbftBold)
            } else if isItalic {
                return (italicFont, hbftItalic)
            } else {
                return (font, hbftFont)
            }
        }()

        // Fall back to base font if variant is not available
        let fontToUse = selectedFont ?? font
        let hbftToUse = selectedHbft ?? hbftFont

        guard let hbft = hbftToUse else {
            failedScalarCache.insert(failKey)
            return nil
        }

        // Try to get glyph from selected font
        if let gid = glyphID(in: fontToUse, scalar: scalar) {
            let k = GlyphKey(fontKey: UInt64(UInt(bitPattern: hbft)), glyphID: gid)
            return entry_forKey_locked(k, hbft: hbft, glyphID: gid)
        }

        // Fall back to base font if glyph not found in variant
        if fontToUse !== font, let baseHbft = hbftFont, let gid = glyphID(in: font, scalar: scalar) {
            let k = GlyphKey(fontKey: UInt64(UInt(bitPattern: baseHbft)), glyphID: gid)
            return entry_forKey_locked(k, hbft: baseHbft, glyphID: gid)
        }

        // Try fallback fonts
        guard let fbCT = ctFontForScalarFallback(base: fontToUse, scalar: scalar) else {
            failedScalarCache.insert(failKey)
            return nil
        }
        guard let fbGid = glyphID(in: fbCT, scalar: scalar) else {
            failedScalarCache.insert(failKey)
            return nil
        }
        guard let face = ensureHbFtFace_locked(for: fbCT) else {
            failedScalarCache.insert(failKey)
            return nil
        }

        let k = GlyphKey(fontKey: face.key, glyphID: fbGid)
        return entry_forKey_locked(k, hbft: face.hbft, glyphID: fbGid)
    }

    func entry(forGlyphID glyphID: UInt32) -> GlyphAtlas.Entry? {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }
    
        guard let baseHbft = hbftFont else { return nil }
        let k = GlyphKey(fontKey: UInt64(UInt(bitPattern: baseHbft)), glyphID: glyphID)
        return entry_forKey_locked(k, hbft: baseHbft, glyphID: glyphID)
    }
    
    private func entry_forKey_locked(_ key: GlyphKey, hbft: OpaquePointer, glyphID: UInt32) -> GlyphAtlas.Entry? {
        if let e = map[key] { return e }
        guard let e = rasterizeAndPack(hbft: hbft, glyphID: glyphID) else { return nil }
        map[key] = e
        return e
    }

    // Convert a Unicode scalar to UTF-16 code units (1 or 2 units).
    private func utf16Units(for scalar: UInt32) -> [UniChar]? {
        if scalar > 0x10FFFF { return nil }
        if scalar <= 0xFFFF {
            return [UniChar(scalar)]
        }
        // surrogate pair
        let v = scalar - 0x10000
        let hi = UniChar(0xD800 + ((v >> 10) & 0x3FF))
        let lo = UniChar(0xDC00 + (v & 0x3FF))
        return [hi, lo]
    }

    private func glyphID(in ctFont: CTFont, scalar: UInt32) -> UInt32? {
        // Build cache key from font pointer and scalar
        let fontKey = UInt64(UInt(bitPattern: Unmanaged.passUnretained(ctFont as AnyObject).toOpaque()))
        let cacheKey = (fontKey << 32) | UInt64(scalar)

        // Check cache first
        if let cached = scalarToGlyphIDCache[cacheKey] {
            return cached
        }

        guard let u16 = utf16Units(for: scalar) else { return nil }
        var chars = u16
        var glyphs = Array<CGGlyph>(repeating: 0, count: chars.count)
        let ok = CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, chars.count)
        if !ok { return nil }
        // If scalar is represented by surrogate pair, CoreText returns 2 glyphs sometimes.
        // For our current "cell-per-scalar" model, prefer the first glyph.
        let gid = UInt32(glyphs[0])

        // Cache the result
        scalarToGlyphIDCache[cacheKey] = gid
        return gid
    }

    private func ctFontForScalarFallback(base: CTFont, scalar: UInt32) -> CTFont? {
        let cacheKey = FallbackCacheKey(
            baseFont: UInt(bitPattern: Unmanaged.passUnretained(base as AnyObject).toOpaque()),
            scalar: scalar
        )

        // Check cache first to avoid expensive CTFontCreateForString calls
        if let cached = fallbackFontCache[cacheKey] {
            return cached
        }

        guard let uni = UnicodeScalar(scalar) else { return nil }
        let s = String(uni) as CFString
        // Ask CoreText for a font that can render this string.
        // Range is the whole string.
        let start = CFAbsoluteTimeGetCurrent()
        let fb = CTFontCreateForString(base, s, CFRange(location: 0, length: 1))
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if elapsed > 1.0 {
            let scalarChar = String(uni)
            ZonvieCore.appLog("[Atlas] SLOW CTFontCreateForString: scalar=0x\(String(scalar, radix: 16)) '\(scalarChar)' took \(String(format: "%.1f", elapsed))ms")
        }

        // Cache the result for future lookups
        fallbackFontCache[cacheKey] = fb
        return fb
    }

    deinit {
        if let hbftFont {
            zonvie_ft_hb_font_destroy(hbftFont)
        }
        if let hbftBold {
            zonvie_ft_hb_font_destroy(hbftBold)
        }
        if let hbftItalic {
            zonvie_ft_hb_font_destroy(hbftItalic)
        }
        if let hbftBoldItalic {
            zonvie_ft_hb_font_destroy(hbftBoldItalic)
        }
        for (_, f) in fallbackFacesByURL {
            zonvie_ft_hb_font_destroy(f.hbft)
        }
        fallbackFacesByURL.removeAll()
    }

    private func resetAtlas_locked() {
        // Skip if atlas is already empty and texture exists (no work to do)
        if map.isEmpty && nextY == 1 && nextX == 1 && texture != nil {
            return
        }
        ZonvieCore.appLog("[Atlas] RESET! map.count=\(map.count) nextY=\(nextY)/\(atlasH)")
        map.removeAll(keepingCapacity: true)
        nextX = 1
        nextY = 1
        rowH = 0
        texture = makeTexture(device: device, w: atlasW, h: atlasH)
    }

    private func makeTexture(device: MTLDevice, w: Int, h: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else {
            ZonvieCore.appLog("[GlyphAtlas] Failed to create atlas texture (\(w)x\(h))")
            return nil
        }
        return tex
    }

    private func rasterizeAndPack(hbft: OpaquePointer, glyphID: UInt32) -> Entry? {
        guard let tex = texture else { return nil }
    
        var bufPtr: UnsafePointer<UInt8>?
        var w: Int32 = 0
        var h: Int32 = 0
        var pitch: Int32 = 0
        var left: Int32 = 0
        var top: Int32 = 0
        var adv26_6: Int32 = 0
    
        let r = zonvie_ft_render_glyph(
            hbft,
            glyphID,
            &bufPtr,
            &w,
            &h,
            &pitch,
            &left,
            &top,
            &adv26_6
        )
    
        let advancePx = Float(adv26_6) / 64.0
    
        // Whitespace etc: nothing to pack/upload.
        if r != 0 || w <= 0 || h <= 0 || bufPtr == nil {
            return Entry(
                uvMin: .zero,
                uvMax: .zero,
                bboxOriginPx: SIMD2<Float>(Float(left), Float(top - h)),
                bboxSizePx: SIMD2<Float>(Float(max(Int32(0), w)), Float(max(Int32(0), h))),
                padPx: 0,
                advancePx: advancePx
            )
        }
    
        let pad: Int = 1
        let iw = Int(w)
        let ih = Int(h)
        let ipitch = Int(pitch)
    
        let packedW = iw + pad * 2
        let packedH = ih + pad * 2
    
        // Allocate atlas rect (simple shelf packer).
        if nextX + packedW > atlasW {
            nextX = 1
            nextY += rowH
            rowH = 0
        }
        if nextY + packedH > atlasH {
            // Atlas full: reset once and continue packing into a fresh atlas.
            resetAtlas_locked()
        }
    
        let rectX = nextX
        let rectY = nextY
        nextX += packedW
        rowH = max(rowH, packedH)
    
        // Copy FT bitmap into a padded buffer (top-left origin for texture upload).
        let neededCount = packedW * packedH

        // Guard against extremely large glyphs that would exhaust memory
        if neededCount > maxScratchSize {
            ZonvieCore.appLog("[GlyphAtlas] Glyph too large: \(packedW)x\(packedH) = \(neededCount) bytes (max \(maxScratchSize))")
            return nil
        }

        // Shrink buffer if it's grown too large (> 4x needed and > half max)
        let shouldShrink = scratch.count > neededCount * 4 && scratch.count > maxScratchSize / 2
        if scratch.count < neededCount || shouldShrink {
            scratch = Array<UInt8>(repeating: 0, count: neededCount)
        } else {
            scratch.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                memset(base, 0, neededCount)
            }
        }
    
        scratch.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            guard let srcBase = bufPtr else { return }  // Safe unwrap

            for row in 0..<ih {
                let src = srcBase.advanced(by: row * ipitch)
                let dstIndex = (row + pad) * packedW + pad
                memcpy(dstBase.advanced(by: dstIndex), src, iw)
            }
        }
    
        // Upload to texture.
        scratch.withUnsafeBytes { raw in
            guard let baseAddr = raw.baseAddress else { return }  // Safe unwrap
            let region = MTLRegionMake2D(rectX, rectY, packedW, packedH)
            tex.replace(region: region, mipmapLevel: 0, withBytes: baseAddr, bytesPerRow: packedW)
        }
    
        // UV excludes padding.
        let u0 = Float(rectX + pad) / Float(atlasW)
        let v0 = Float(rectY + pad) / Float(atlasH)
        let u1 = Float(rectX + pad + iw) / Float(atlasW)
        let v1 = Float(rectY + pad + ih) / Float(atlasH)
    
        // bbox in CoreText coords (pixels, y-up) relative to baseline at (0,0)
        let bboxOrigin = SIMD2<Float>(Float(left), Float(top - h))
        let bboxSize = SIMD2<Float>(Float(w), Float(h))
    
        return Entry(
            uvMin: SIMD2<Float>(u0, v0),
            uvMax: SIMD2<Float>(u1, v1),
            bboxOriginPx: bboxOrigin,
            bboxSizePx: bboxSize,
            padPx: Float(pad),
            advancePx: advancePx
        )
    }

    // MARK: - Phase 2: Core-managed atlas

    /// Resolve font and glyph ID for a given scalar + style.
    /// Must be called with mu locked.
    /// Get glyph ID by shaping a single scalar with HarfBuzz (applies OpenType features).
    /// Returns nil if the font doesn't contain the scalar (glyph_id == 0 = .notdef).
    private func glyphIDViaShaping(hbft: OpaquePointer, scalar: UInt32) -> UInt32? {
        var scalars: [UInt32] = [scalar]
        var glyphId: UInt32 = 0
        var xAdv: Int32 = 0, yAdv: Int32 = 0, xOff: Int32 = 0, yOff: Int32 = 0

        let count = zonvie_hb_shape_utf32(
            hbft,
            &scalars, 1,
            &glyphId, nil,
            &xAdv, &yAdv, &xOff, &yOff,
            1,
            nil, nil, nil
        )

        // glyph_id 0 = .notdef = font doesn't have this scalar
        if count >= 1 && glyphId != 0 { return glyphId }
        return nil
    }

    private func resolveHbftAndGlyph_locked(scalar: UInt32, styleFlags: UInt32) -> (hbft: OpaquePointer, glyphID: UInt32)? {
        let failKey = (UInt64(styleFlags) << 32) | UInt64(scalar)
        if failedScalarCache.contains(failKey) {
            return nil
        }

        let isBold = (styleFlags & ZONVIE_STYLE_BOLD) != 0
        let isItalic = (styleFlags & ZONVIE_STYLE_ITALIC) != 0

        let (selectedFont, selectedHbft): (CTFont?, OpaquePointer?) = {
            if styleFlags == 0 {
                return (font, hbftFont)
            } else if isBold && isItalic {
                return (boldItalicFont ?? boldFont ?? italicFont, hbftBoldItalic ?? hbftBold ?? hbftItalic)
            } else if isBold {
                return (boldFont, hbftBold)
            } else if isItalic {
                return (italicFont, hbftItalic)
            } else {
                return (font, hbftFont)
            }
        }()

        let fontToUse = selectedFont ?? font
        let hbftToUse = selectedHbft ?? hbftFont

        guard let hbft = hbftToUse else {
            failedScalarCache.insert(failKey)
            return nil
        }

        // When features are set, use HarfBuzz shaping to get feature-aware glyph ID.
        // Otherwise use CTFont cmap (faster, no shaping overhead).
        if hasFeatures {
            if let gid = glyphIDViaShaping(hbft: hbft, scalar: scalar) {
                return (hbft: hbft, glyphID: gid)
            }
        } else {
            if let gid = glyphID(in: fontToUse, scalar: scalar) {
                return (hbft: hbft, glyphID: gid)
            }
        }

        // Try base font if styled font didn't have the glyph
        if fontToUse !== font, let baseHbft = hbftFont {
            if hasFeatures {
                if let gid = glyphIDViaShaping(hbft: baseHbft, scalar: scalar) {
                    return (hbft: baseHbft, glyphID: gid)
                }
            } else {
                if let gid = glyphID(in: font, scalar: scalar) {
                    return (hbft: baseHbft, glyphID: gid)
                }
            }
        }

        // Fallback font lookup (always uses CTFont to find the right font)
        guard let fbCT = ctFontForScalarFallback(base: fontToUse, scalar: scalar) else {
            failedScalarCache.insert(failKey)
            return nil
        }
        guard let face = ensureHbFtFace_locked(for: fbCT) else {
            failedScalarCache.insert(failKey)
            return nil
        }

        if hasFeatures {
            if let gid = glyphIDViaShaping(hbft: face.hbft, scalar: scalar) {
                return (hbft: face.hbft, glyphID: gid)
            }
        } else {
            if let gid = glyphID(in: fbCT, scalar: scalar) {
                return (hbft: face.hbft, glyphID: gid)
            }
        }

        failedScalarCache.insert(failKey)
        return nil
    }

    /// Phase 2: Rasterize a glyph without atlas packing.
    /// Fills outBitmap with the FreeType bitmap data.
    /// The pixel pointer is valid until the next rasterize call.
    func rasterizeOnly(scalar: UInt32, styleFlags: UInt32, outBitmap: UnsafeMutablePointer<zonvie_glyph_bitmap>) -> Bool {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        guard let resolved = resolveHbftAndGlyph_locked(scalar: scalar, styleFlags: styleFlags) else {
            return false
        }

        var bufPtr: UnsafePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0, pitch: Int32 = 0
        var left: Int32 = 0, top: Int32 = 0, adv26_6: Int32 = 0

        let r = zonvie_ft_render_glyph(
            resolved.hbft, resolved.glyphID,
            &bufPtr, &w, &h, &pitch, &left, &top, &adv26_6
        )

        outBitmap.pointee.bearing_x = left
        outBitmap.pointee.bearing_y = top
        outBitmap.pointee.advance_26_6 = adv26_6
        outBitmap.pointee.ascent_px = ascentPx
        outBitmap.pointee.descent_px = descentPx
        outBitmap.pointee.bytes_per_pixel = 1 // grayscale

        if r != 0 || w <= 0 || h <= 0 || bufPtr == nil {
            outBitmap.pointee.pixels = nil
            outBitmap.pointee.width = 0
            outBitmap.pointee.height = 0
        } else {
            // Copy bitmap data to stable buffer while under lock.
            // This prevents use-after-free if main thread destroys FreeType font
            // (via setBackingScale/rebuildFont_locked) between rasterizeOnly and uploadRegion.
            let needed = Int(w) * Int(h)
            if rasterizeScratch.count < needed {
                rasterizeScratch = Array(repeating: 0, count: needed)
            }
            let absPitch = abs(Int(pitch))
            rasterizeScratch.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                for row in 0..<Int(h) {
                    let srcRow = pitch >= 0 ? row : (Int(h) - 1 - row)
                    let src = bufPtr!.advanced(by: srcRow * absPitch)
                    memcpy(base.advanced(by: row * Int(w)), src, Int(w))
                }
            }
            rasterizeScratch.withUnsafeBufferPointer { buf in
                outBitmap.pointee.pixels = buf.baseAddress
            }
            outBitmap.pointee.width = UInt32(w)
            outBitmap.pointee.height = UInt32(h)
            outBitmap.pointee.pitch = Int32(w)  // contiguous: pitch = width
        }

        return true
    }

    /// Select the appropriate HBFT font handle for the given style flags.
    /// Must be called with mu locked.
    private func selectHbft_locked(styleFlags: UInt32) -> OpaquePointer? {
        let isBold = (styleFlags & ZONVIE_STYLE_BOLD) != 0
        let isItalic = (styleFlags & ZONVIE_STYLE_ITALIC) != 0

        if isBold && isItalic {
            return hbftBoldItalic ?? hbftBold ?? hbftItalic ?? hbftFont
        } else if isBold {
            return hbftBold ?? hbftFont
        } else if isItalic {
            return hbftItalic ?? hbftFont
        } else {
            return hbftFont
        }
    }

    /// Phase B: Shape a text run using HarfBuzz.
    /// Returns the actual glyph count. If > outCap, caller should retry with larger buffers.
    func shapeTextRun(
        scalars: UnsafePointer<UInt32>, scalarCount: Int,
        styleFlags: UInt32,
        outGlyphIDs: UnsafeMutablePointer<UInt32>,
        outClusters: UnsafeMutablePointer<UInt32>,
        outXAdvance: UnsafeMutablePointer<Int32>,
        outXOffset: UnsafeMutablePointer<Int32>,
        outYOffset: UnsafeMutablePointer<Int32>,
        outCap: Int
    ) -> Int {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        guard let hbft = selectHbft_locked(styleFlags: styleFlags) else { return 0 }

        // zonvie_hb_shape_utf32 outputs y_advance too, but our callback doesn't need it.
        // Use persistent buffer to avoid per-call heap allocation.
        if shapeYAdvBuf.count < outCap {
            shapeYAdvBuf = [Int32](repeating: 0, count: max(outCap, 256))
        }

        let count = zonvie_hb_shape_utf32(
            hbft,
            scalars, scalarCount,
            outGlyphIDs, outClusters,
            outXAdvance, &shapeYAdvBuf,
            outXOffset, outYOffset,
            outCap,
            nil, nil, nil
        )

        return count
    }

    /// ASCII fast path: fill pre-computed tables for the given style variant.
    /// Called lazily by core on first shaping attempt after font change.
    func getAsciiTable(
        styleFlags: UInt32,
        outGlyphIDs: UnsafeMutablePointer<UInt32>,
        outXAdvances: UnsafeMutablePointer<Int32>,
        outLigTriggers: UnsafeMutablePointer<UInt8>
    ) -> Int32 {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        guard let hbft = selectHbft_locked(styleFlags: styleFlags) else { return 0 }

        let ok1 = zonvie_ft_hb_get_ascii_glyph_ids(hbft, outGlyphIDs)
        let ok2 = zonvie_ft_hb_get_ascii_x_advances(hbft, outXAdvances)
        let ok3 = zonvie_ft_hb_get_ascii_lig_triggers(hbft, outLigTriggers)

        return (ok1 != 0 && ok2 != 0 && ok3 != 0) ? 1 : 0
    }

    /// Phase B: Rasterize a glyph by its glyph ID (post-shaping, skips scalar→glyph_id lookup).
    func rasterizeByGlyphID(glyphID: UInt32, styleFlags: UInt32, outBitmap: UnsafeMutablePointer<zonvie_glyph_bitmap>) -> Bool {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        guard let hbft = selectHbft_locked(styleFlags: styleFlags) else { return false }

        var bufPtr: UnsafePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0, pitch: Int32 = 0
        var left: Int32 = 0, top: Int32 = 0, adv26_6: Int32 = 0

        let r = zonvie_ft_render_glyph(
            hbft, glyphID,
            &bufPtr, &w, &h, &pitch, &left, &top, &adv26_6
        )

        outBitmap.pointee.bearing_x = left
        outBitmap.pointee.bearing_y = top
        outBitmap.pointee.advance_26_6 = adv26_6
        outBitmap.pointee.ascent_px = ascentPx
        outBitmap.pointee.descent_px = descentPx
        outBitmap.pointee.bytes_per_pixel = 1 // grayscale

        if r != 0 || w <= 0 || h <= 0 || bufPtr == nil {
            outBitmap.pointee.pixels = nil
            outBitmap.pointee.width = 0
            outBitmap.pointee.height = 0
        } else {
            // Copy bitmap data to stable buffer (same as rasterizeOnly)
            let needed = Int(w) * Int(h)
            if rasterizeScratch.count < needed {
                rasterizeScratch = Array(repeating: 0, count: needed)
            }
            let absPitch = abs(Int(pitch))
            rasterizeScratch.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                for row in 0..<Int(h) {
                    let srcRow = pitch >= 0 ? row : (Int(h) - 1 - row)
                    let src = bufPtr!.advanced(by: srcRow * absPitch)
                    memcpy(base.advanced(by: row * Int(w)), src, Int(w))
                }
            }
            rasterizeScratch.withUnsafeBufferPointer { buf in
                outBitmap.pointee.pixels = buf.baseAddress
            }
            outBitmap.pointee.width = UInt32(w)
            outBitmap.pointee.height = UInt32(h)
            outBitmap.pointee.pitch = Int32(w)
        }

        return true
    }

    /// Phase 2: Upload glyph bitmap data to atlas texture at the specified position.
    func uploadRegion(destX: Int, destY: Int, width: Int, height: Int, bitmap: UnsafePointer<zonvie_glyph_bitmap>) {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        guard let tex = texture, let pixels = bitmap.pointee.pixels else { return }
        let pitch = Int(bitmap.pointee.pitch)
        let absPitch = abs(pitch)
        let needed = width * height
        if needed <= 0 { return }

        if scratch.count < needed {
            scratch = Array<UInt8>(repeating: 0, count: needed)
        } else {
            scratch.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                memset(base, 0, needed)
            }
        }

        scratch.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            for row in 0..<height {
                let srcRow = pitch >= 0 ? row : (height - 1 - row)
                let src = pixels.advanced(by: srcRow * absPitch)
                memcpy(dstBase.advanced(by: row * width), src, min(width, Int(bitmap.pointee.width)))
            }
        }

        scratch.withUnsafeBytes { raw in
            guard let baseAddr = raw.baseAddress else { return }
            let region = MTLRegionMake2D(destX, destY, width, height)
            tex.replace(region: region, mipmapLevel: 0, withBytes: baseAddr, bytesPerRow: width)
        }
    }

    /// Phase 2: Recreate atlas texture with the given dimensions.
    func recreateTexture(width: Int, height: Int) {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        texture = makeTexture(device: device, w: width, h: height)
        // Reset local packer state (core manages packing in Phase 2)
        nextX = 1
        nextY = 1
        rowH = 0
        map.removeAll(keepingCapacity: true)
        failedScalarCache.removeAll(keepingCapacity: true)
    }

}
