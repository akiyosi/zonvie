import AppKit
import CoreGraphics

/// Images transmitted by Neovim's experimental ext_images UI extension.
///
/// The store is shared by two threads: `img_data` / `img_set` / `img_del` and
/// the virtual-placement tile rasterization all run on the core thread during
/// redraw and flush, while the direct-placement overlay draws on main. Image
/// data is therefore decoded synchronously in the callback rather than being
/// dispatched to main, so a tile rasterization that follows in the same flush
/// already sees the image (see the async-dispatch note in ZonvieCore).
final class ExtImageStore {
    /// A direct placement: cells on the global layout, drawn by the overlay.
    /// Virtual placements are not kept here — the core renders those from the
    /// grid's placeholder cells.
    struct DirectPlacement {
        var row: Int32
        var col: Int32
        var width: Int32
        var height: Int32
        var zindex: Int32
    }

    private let mu = NSLock()
    private var images: [Int64: CGImage] = [:]
    private var direct: [Int64: DirectPlacement] = [:]
    /// Reused RGBA scratch for tile rasterization. Core-thread only — the
    /// overlay never touches it — so it needs no lock.
    private var tileScratch: [UInt8] = []

    /// One image pre-scaled to its full placement box, so each tile is a
    /// memcpy instead of its own scaled draw of the whole image. Core-thread
    /// only. Holds a single entry: the core requests a placement's tiles in a
    /// row-major burst within one flush, so the last-used image is the next
    /// one asked for.
    private struct ScaledPlacement {
        var image: CGImage
        var tileRows: UInt16
        var tileCols: UInt16
        var pxW: UInt32
        var pxH: UInt32
        var pixels: [UInt8]
        var rowBytes: Int
    }
    private var scaled: ScaledPlacement?
    /// Full-box budget for the pre-scale buffer. A placement above it (the
    /// placeholder scheme allows 297x297 cells) falls back to per-tile draws
    /// rather than holding a huge intermediate.
    private static let scaledBudgetBytes = 64 << 20

    // MARK: - Protocol events

    func setImage(id: Int64, data: Data) {
        guard let decoded = ExtImageStore.decode(data) else {
            // Only img_del and img_set change a placement; a payload we cannot
            // read must not silently unplace an image that is already showing.
            ZonvieCore.appLog("[ExtImageStore] image \(id): undecodable payload (\(data.count) bytes), keeping previous")
            return
        }
        mu.lock()
        images[id] = decoded
        mu.unlock()
        // Core thread — the only `scaled` toucher. Free the pre-scale buffer
        // now that its source may have been replaced; drawTile's identity
        // check would catch the staleness anyway, this just returns the
        // memory immediately.
        scaled = nil
    }

    func setDirectPlacement(id: Int64, row: Int32, col: Int32, width: Int32, height: Int32, zindex: Int32) {
        mu.lock()
        defer { mu.unlock() }
        // "UIs must ignore this event for an unknown id" (:help ui-images), and
        // img_data always precedes the first img_set. Keeping the placement
        // would resurrect it against whatever image later reuses the id.
        guard images[id] != nil else { return }
        direct[id] = DirectPlacement(row: row, col: col, width: width, height: height, zindex: zindex)
    }

    /// Drop a direct placement without dropping the image: the placement either
    /// became virtual or was replaced.
    func clearDirectPlacement(id: Int64) {
        mu.lock()
        defer { mu.unlock() }
        direct.removeValue(forKey: id)
    }

    /// Drop every image and placement. Neovim never retransmits, so a new
    /// session must not inherit the previous one's images.
    func reset() {
        mu.lock()
        images.removeAll()
        direct.removeAll()
        mu.unlock()
        scaled = nil  // core thread; see setImage
    }

    func remove(id: Int64) {
        mu.lock()
        images.removeValue(forKey: id)
        direct.removeValue(forKey: id)
        mu.unlock()
        scaled = nil  // core thread; see setImage
    }

    /// Direct placements paired with their image, ordered bottom-to-top.
    func directPlacementsInDrawOrder() -> [(image: CGImage, placement: DirectPlacement)] {
        mu.lock()
        defer { mu.unlock() }
        return direct
            // Tie-break on id: Dictionary iteration order is unspecified, so
            // sorting on zindex alone lets equal-zindex images swap stacking
            // between frames.
            .sorted { ($0.value.zindex, $0.key) < ($1.value.zindex, $1.key) }
            .compactMap { entry in
                guard let image = images[entry.key] else { return nil }
                return (image, entry.value)
            }
    }

    // MARK: - Virtual placement tiles

    /// Rasterize the (tileRow, tileCol) tile of image `id` at cell resolution.
    /// The image is scaled to the full tileCols x tileRows cell box first, so
    /// adjacent tiles line up exactly like the placeholder cells they fill.
    ///
    /// `outBitmap.pixels` points into the store's scratch buffer and stays valid
    /// until the NEXT call: the core reads it after this returns, uploading the
    /// tile into the atlas before it asks for another. Same contract as
    /// on_rasterize_glyph.
    func rasterizeTile(
        id: Int64,
        tileRow: UInt16,
        tileCol: UInt16,
        tileRows: UInt16,
        tileCols: UInt16,
        pxW: UInt32,
        pxH: UInt32,
        outBitmap: UnsafeMutablePointer<zonvie_glyph_bitmap>
    ) -> Bool {
        guard pxW > 0, pxH > 0, tileRows > 0, tileCols > 0 else { return false }
        guard tileRow < tileRows, tileCol < tileCols else { return false }

        // Take only the image reference under the lock. The scaled draw below
        // is the expensive part, and holding `mu` across it would stall the
        // overlay's main-thread draw behind every first-encounter tile.
        // CGImage is immutable, so drawing it unlocked is safe.
        mu.lock()
        let imageOrNil = images[id]
        mu.unlock()
        guard let image = imageOrNil else { return false }

        let w = Int(pxW)
        let h = Int(pxH)
        let rowBytes = w * 4
        let needed = rowBytes * h
        if tileScratch.count < needed {
            tileScratch = Array(repeating: 0, count: needed)
        }

        let drawn = drawTile(
            image: image, into: &tileScratch,
            tileRow: Int(tileRow), tileCol: Int(tileCol),
            tileRows: Int(tileRows), tileCols: Int(tileCols),
            w: w, h: h, rowBytes: rowBytes, needed: needed
        )
        if !drawn { return false }

        tileScratch.withUnsafeBufferPointer { buf in
            outBitmap.pointee.pixels = buf.baseAddress
        }
        outBitmap.pointee.width = pxW
        outBitmap.pointee.height = pxH
        outBitmap.pointee.pitch = Int32(rowBytes)
        outBitmap.pointee.bearing_x = 0
        outBitmap.pointee.bearing_y = 0
        outBitmap.pointee.advance_26_6 = Int32(w * 64)
        outBitmap.pointee.bytes_per_pixel = 4
        outBitmap.pointee.ascent_px = 0
        outBitmap.pointee.descent_px = 0
        return true
    }

    /// Fill `dst` with one tile, preferring a memcpy out of the pre-scaled
    /// placement buffer. Scaling the image once and copying tiles out replaces
    /// tileRows*tileCols scaled draws of the WHOLE image with a single one —
    /// the difference between one flush and a visible hitch on first display.
    private func drawTile(
        image: CGImage, into dst: inout [UInt8],
        tileRow: Int, tileCol: Int, tileRows: Int, tileCols: Int,
        w: Int, h: Int, rowBytes: Int, needed: Int
    ) -> Bool {
        let fullRowBytes = rowBytes * tileCols
        let fullBytes = fullRowBytes * h * tileRows

        if fullBytes <= ExtImageStore.scaledBudgetBytes {
            if scaled == nil || scaled!.image !== image || scaled!.tileRows != tileRows
                || scaled!.tileCols != tileCols || Int(scaled!.pxW) != w || Int(scaled!.pxH) != h
            {
                var pixels = [UInt8](repeating: 0, count: fullBytes)
                let ok = pixels.withUnsafeMutableBufferPointer { buf -> Bool in
                    guard let base = buf.baseAddress,
                          let ctx = CGContext(
                              data: base,
                              width: w * tileCols,
                              height: h * tileRows,
                              bitsPerComponent: 8,
                              bytesPerRow: fullRowBytes,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue  // RGBA premultiplied
                          )
                    else { return false }
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w * tileCols), height: CGFloat(h * tileRows)))
                    return true
                }
                guard ok else { return false }
                ZonvieCore.appLog("[ExtImageStore] pre-scaled placement \(tileCols)x\(tileRows) tiles (\(fullBytes) bytes)")
                scaled = ScaledPlacement(
                    image: image, tileRows: UInt16(tileRows), tileCols: UInt16(tileCols),
                    pxW: UInt32(w), pxH: UInt32(h), pixels: pixels, rowBytes: fullRowBytes
                )
            }
            let cache = scaled!
            // CGBitmapContext memory is top-scanline-first, same as the tile
            // grid, so the copy is a plain row-major slice.
            cache.pixels.withUnsafeBufferPointer { src in
                dst.withUnsafeMutableBufferPointer { d in
                    guard let sBase = src.baseAddress, let dBase = d.baseAddress else { return }
                    for row in 0..<h {
                        let srcOff = (tileRow * h + row) * cache.rowBytes + tileCol * rowBytes
                        memcpy(dBase.advanced(by: row * rowBytes), sBase.advanced(by: srcOff), rowBytes)
                    }
                }
            }
            return true
        }

        // Oversized placement: per-tile draw of the whole image, offset so the
        // requested tile lands on the context. CoreGraphics is bottom-up while
        // the tile grid counts rows from the top.
        return dst.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            memset(base, 0, needed)
            guard let ctx = CGContext(
                data: base,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue  // RGBA premultiplied
            ) else {
                return false
            }
            ctx.interpolationQuality = .high
            let fullW = CGFloat(tileCols) * CGFloat(w)
            let fullH = CGFloat(tileRows) * CGFloat(h)
            let originX = -CGFloat(tileCol) * CGFloat(w)
            let originY = -CGFloat(tileRows - 1 - tileRow) * CGFloat(h)
            ctx.draw(image, in: CGRect(x: originX, y: originY, width: fullW, height: fullH))
            return true
        }
    }

    // MARK: - Decoding

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Decode now rather than at first draw: this runs once on the core
        // thread, whereas the lazy decode would land inside the first tile
        // rasterization of a flush, on the same thread, mid-frame.
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
