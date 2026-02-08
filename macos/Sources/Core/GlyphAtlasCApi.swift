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

// Phase 2: Core-managed atlas callbacks

@_cdecl("zonvie_macos_rasterize_glyph")
public func zonvie_macos_rasterize_glyph(
    _ ctx: UnsafeMutableRawPointer?,
    _ scalar: UInt32,
    _ styleFlags: UInt32,
    _ outBitmap: UnsafeMutablePointer<zonvie_glyph_bitmap>?
) -> Int32 {
    guard let ctx, let outBitmap else { return 0 }
    let core = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
    guard let view = core.terminalView else { return 0 }
    return view.renderer.rasterizeGlyphOnly(scalar: scalar, styleFlags: styleFlags, outBitmap: outBitmap) ? 1 : 0
}

@_cdecl("zonvie_macos_atlas_upload")
public func zonvie_macos_atlas_upload(
    _ ctx: UnsafeMutableRawPointer?,
    _ destX: UInt32,
    _ destY: UInt32,
    _ width: UInt32,
    _ height: UInt32,
    _ bitmap: UnsafePointer<zonvie_glyph_bitmap>?
) {
    guard let ctx, let bitmap else { return }
    let core = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
    guard let view = core.terminalView else { return }
    view.renderer.uploadAtlasRegion(destX: destX, destY: destY, width: width, height: height, bitmap: bitmap)
}

@_cdecl("zonvie_macos_atlas_create")
public func zonvie_macos_atlas_create(
    _ ctx: UnsafeMutableRawPointer?,
    _ atlasW: UInt32,
    _ atlasH: UInt32
) {
    guard let ctx else { return }
    let core = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
    guard let view = core.terminalView else { return }
    view.renderer.recreateAtlasTexture(width: atlasW, height: atlasH)
}
