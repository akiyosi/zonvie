import Foundation

@_cdecl("zonvie_macos_atlas_ensure_glyph")
public func zonvie_macos_atlas_ensure_glyph(
    _ ctx: UnsafeMutableRawPointer?,
    _ scalar: UInt32,
    _ outEntry: UnsafeMutablePointer<zonvie_glyph_entry>?
) -> Int32 {
    // Return non-zero (1) for success, 0 for failure (matching main window convention)
    guard let ctx, let outEntry else { return 0 }
    let core = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
    guard let view = core.terminalView else { return 0 }
    return view.atlasEnsureGlyph(scalar: scalar, out: outEntry) ? 1 : 0
}

@_cdecl("zonvie_macos_atlas_ensure_glyph_styled")
public func zonvie_macos_atlas_ensure_glyph_styled(
    _ ctx: UnsafeMutableRawPointer?,
    _ scalar: UInt32,
    _ styleFlags: UInt32,
    _ outEntry: UnsafeMutablePointer<zonvie_glyph_entry>?
) -> Int32 {
    // Return non-zero (1) for success, 0 for failure (matching main window convention)
    guard let ctx, let outEntry else { return 0 }
    let core = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
    guard let view = core.terminalView else { return 0 }
    return view.atlasEnsureGlyphStyled(scalar: scalar, styleFlags: styleFlags, out: outEntry) ? 1 : 0
}
