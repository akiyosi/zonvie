import Foundation

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
    guard let view = zc.terminalView else { return 0 }
    return view.renderer.rasterizeGlyphOnly(scalar: scalar, styleFlags: styleFlags, corePtr: zc.corePtr, outBitmap: outBitmap) ? 1 : 0
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
    let result = view.renderer.uploadAtlasRegion(destX: destX, destY: destY, width: width, height: height, bitmap: bitmap)
    switch result {
    case .uploaded:
        break
    case .retryAfterReaderDrain:
        // Reader contention is transient and leaves both atlas textures
        // intact. Abort so packAndUploadBitmap does not publish/cache the new
        // UV, but preserve the current atlas generation for the retry instead
        // of recreating MTLTextures on every busy external frame.
        if let corePtr = core.corePtr {
            zonvie_core_abort_flush(corePtr)
        }
    case .requiresRebuild:
        // on_atlas_upload's C ABI is void, so the core otherwise has no way
        // to see this failure -- it unconditionally builds and returns a
        // GlyphEntry with UVs pointing at the just-requested (but
        // never-written) region, then CACHES that entry in
        // glyph_cache_by_id/glyph_cache_non_ascii, which persist across
        // flushes. Without this, "the next cache miss retries" never
        // happens: the bad entry is a permanent cache HIT. Called
        // synchronously from the core/RPC thread (this callback runs
        // inside ensureGlyphPhase2, inside the current onFlush) with
        // grid_mu already held, matching the established
        // frontend-signals-abort-mid-flush pattern (see
        // zonvie_core_abort_flush's doc comment) — neither function locks
        // grid_mu itself.
        if let corePtr = core.corePtr {
            zonvie_core_abort_flush(corePtr)
            zonvie_core_invalidate_glyph_cache(corePtr)
        }
    }
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
    guard !view.renderer.recreateAtlasTexture(width: atlasW, height: atlasH) else { return }
    // Keep the old committed front texture and reject this transaction. The
    // core checks flush_aborted immediately after this void callback, so it
    // cannot compute/cache new UVs or publish the write set against the old
    // texture generation. needsAtlasRebuild remains armed for the retry.
    if let corePtr = core.corePtr {
        zonvie_core_abort_flush(corePtr)
    }
}
