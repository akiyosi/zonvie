import Foundation

/// C-callable logging function for HBFTBridge.c and other C code.
/// Routes through the same appLog system as all Swift-side logging.
@_cdecl("zonvie_macos_log")
public func zonvie_macos_log(_ msg: UnsafePointer<CChar>?) {
    guard let msg else { return }
    ZonvieCore.appLog(String(cString: msg))
}

@_cdecl("zonvie_macos_atlas_ensure_glyph")
public func zonvie_macos_atlas_ensure_glyph(
    _ ctx: UnsafeMutableRawPointer?,
    _ scalar: UInt32,
    _ outEntry: UnsafeMutablePointer<zonvie_glyph_entry>?
) -> Int32 {
    guard let ctx, let outEntry else { return 0 }
    let core = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
    // Phase 1 legacy atlas (not used with tile renderer — core-managed atlas handles it)
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
    let zc = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
    if let view = zc.terminalView {
        return view.renderer.rasterizeGlyphOnly(scalar: scalar, styleFlags: styleFlags, corePtr: zc.corePtr, outBitmap: outBitmap) ? 1 : 0
    }
    // TileRenderer: rasterize through the shared atlas (same as main renderer).
    // This populates the atlas back texture. The glyph will be visible after
    // the main renderer's next commitAndSnapshotFrontTexture swaps.
    if let atlas = zc.tileRenderer?.glyphAtlas {
        return atlas.rasterizeOnly(scalar: scalar, styleFlags: styleFlags, corePtr: zc.corePtr, outBitmap: outBitmap) ? 1 : 0
    }
    return 0
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
    if let view = core.terminalView {
        view.renderer.uploadAtlasRegion(destX: destX, destY: destY, width: width, height: height, bitmap: bitmap)
        return
    }
    // TileRenderer: upload to shared atlas back texture (same atlas object).
    core.tileRenderer?.glyphAtlas.uploadRegion(destX: Int(destX), destY: Int(destY), width: Int(width), height: Int(height), bitmap: bitmap)
}

@_cdecl("zonvie_macos_atlas_create")
public func zonvie_macos_atlas_create(
    _ ctx: UnsafeMutableRawPointer?,
    _ atlasW: UInt32,
    _ atlasH: UInt32
) {
    guard let ctx else { return }
    let core = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
    if let view = core.terminalView {
        view.renderer.recreateAtlasTexture(width: atlasW, height: atlasH)
        return
    }
    // TileRenderer: recreate the shared atlas. This is necessary when the
    // atlas fills up. Both cores share the same atlas so this affects both.
    core.tileRenderer?.glyphAtlas.recreateTexture(width: Int(atlasW), height: Int(atlasH))
}
