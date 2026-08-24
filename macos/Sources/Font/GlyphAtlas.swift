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
    // Serializes zeroChunk use and texture zero-fill without extending mu
    // across Metal allocation/replace calls.
    private var textureCreateLock = os_unfair_lock()

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

    /// Current font name (read-only for external use). Locked: `fontName` is
    /// mutated on the core thread under `mu` by setFont(); these getters are
    /// read from the main thread (IME preedit, font picker), so an unlocked
    /// read of the Swift String could tear / corrupt its refcount.
    var currentFontName: String {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }
        return fontName
    }
    /// Current point size (read-only for external use).
    var currentPointSize: CGFloat {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }
        return pointSize
    }

    // Double-buffered atlas textures: textures[frontIndex] = draw reads,
    // textures[1 - frontIndex] = flush writes (uploadRegion).
    private var textures: [MTLTexture?] = [nil, nil]
    private var frontIndex: Int = 0          // mu protected
    private var backDirty: Bool = false       // mu protected: front has content not yet synced to back
    private var atlasModified: Bool = false   // mu protected: back content changed during this flush
    private var needsAtlasRebuild: Bool = false // mu protected: setBackingScale applied font+metrics but atlas reset pending
    private var pendingBackSyncWasRecreate: Bool = false // mu protected: recreateTexture occurred before the next front->back sync
    private var pendingBackSyncRect: AtlasDirtyRect? = nil // mu protected: dirty union behind the next front->back sync
    private var flushHadRecreate: Bool = false // mu protected: recreateTexture called during current flush
    private var flushDirtyRect: AtlasDirtyRect? = nil // mu protected: dirty union for uploads during current flush
    /// Full logical atlas image used to batch cold-glyph uploads. Allocated
    /// only at initialization or an atlas resize; uploadRegion writes glyph
    /// pixels into this persistent storage and the flush boundary performs one
    /// texture replace for the staged union.
    private var atlasShadow: [UInt8] = [] // mu protected
    private var stagedUploadRect: AtlasDirtyRect? = nil // mu protected
    // mu protected: set when recreateTexture()'s makeTexture() call fails (e.g. an
    // MTLTexture allocation failure under memory pressure). prepareBackTexture()
    // retries the allocation for this slot on every subsequent beginFlush() until
    // it succeeds, instead of leaving the slot permanently nil -- which would
    // otherwise wedge every future flush once frontIndex swaps onto the nil slot
    // (see prepareBackTexture's front/back guard).
    private var pendingTextureRecreate: (index: Int, width: Int, height: Int)? = nil

    // Atlas dimensions (updated by recreateTexture when core sets atlas_size).
    private var atlasW: Int = 2048
    private var atlasH: Int = 2048

    // HarfBuzz+FreeType backend handle (base font).
    private var hbftFont: OpaquePointer?
    private var hbftFontData: NSData?

    // HarfBuzz+FreeType handles for font variants
    private var hbftBold: OpaquePointer?
    private var hbftItalic: OpaquePointer?
    private var hbftBoldItalic: OpaquePointer?
    private var hbftBoldData: NSData?
    private var hbftItalicData: NSData?
    private var hbftBoldItalicData: NSData?

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
        let fontData: NSData
        let hbft: OpaquePointer
        let key: UInt64
        var accessOrder: UInt64 = 0  // LRU tracking: higher = more recent
    }

    // base face is represented by (font, hbftFont). Fallback faces are cached by URL string.
    private var fallbackFacesByURL: [String: HbFtFace] = [:]
    private var fallbackAccessCounter: UInt64 = 0
    private var fallbackLoadLock = os_unfair_lock()
    private var fontGeneration: UInt64 = 0

    // Maximum number of concurrent fallback font faces held in memory. Four is
    // below normal mixed-script workloads (CJK + symbols + math + icon fonts),
    // causing repeated mmap/HarfBuzz destruction and reload in the glyph hot
    // path. Font data is mmap-backed, so a still-bounded 16-face working set is
    // a better CPU/RSS tradeoff while retaining the LRU escape hatch.
    private let maxFallbackFaces = 16

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

    // Cache key for scalarToGlyphIDCache. A raw UInt64 built as (fontKey << 32 | scalar)
    // would silently truncate the pointer's high 32 bits, risking a collision between
    // two concurrently-live CTFont objects (base/bold/italic/fallback all coexist) whose
    // addresses share the same low 32 bits. A struct with Swift's synthesized Hashable
    // combines both fields without truncation -- same pattern as GlyphKey/FallbackCacheKey above.
    private struct GlyphIDCacheKey: Hashable {
        let fontKey: UInt64   // pointer address of the CTFont (full 64 bits, not truncated)
        let scalar: UInt32
    }

    // Cache for scalar → glyphID mapping to avoid CTFontGetGlyphsForCharacters calls.
    // Key: (fontKey, scalar), Value: glyphID. Cleared when font settings change.
    private var scalarToGlyphIDCache: [GlyphIDCacheKey: UInt32] = [:]

    // Maximum entries for scalar-level caches. When exceeded, the entire cache is
    // cleared to bound memory growth from large Unicode workloads. Entries are small
    // (8-16 bytes each), so 50k entries ≈ 0.4-0.8 MB per cache — acceptable.
    private let maxScalarCacheEntries = 50_000

    /// Insert into failedScalarCache with overflow protection.
    private func insertFailedScalar_locked(_ key: UInt64) {
        if failedScalarCache.count >= maxScalarCacheEntries {
            failedScalarCache.removeAll(keepingCapacity: true)
        }
        failedScalarCache.insert(key)
    }

    private var nextX: Int = 1
    private var nextY: Int = 1
    private var rowH: Int = 0

    // NOTE: cache entries by (font, glyphID), not glyphID only.
    private var map: [GlyphKey: GlyphAtlas.Entry] = [:]





    private var scratch: [UInt8] = []

    private struct AtlasDirtyRect {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        mutating func union(x newX: Int, y newY: Int, width newWidth: Int, height newHeight: Int) {
            let minX = min(x, newX)
            let minY = min(y, newY)
            let maxX = max(x + width, newX + newWidth)
            let maxY = max(y + height, newY + newHeight)
            x = minX
            y = minY
            width = maxX - minX
            height = maxY - minY
        }
    }

    /// Persistent zero-clear buffer for makeTexture (up to zeroClearChunkRows
    /// rows of atlas width; grown lazily, never shrunk).
    private var zeroChunk: [UInt8] = []
    /// Rows zero-cleared per makeTexture replace() call. Chunking (instead of
    /// one call per row, or one call for the whole texture) bounds the
    /// scratch buffer to a fixed handful of MB while cutting the call count
    /// from atlasH to atlasH/zeroClearChunkRows.
    private let zeroClearChunkRows = 128

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

    private(set) var ascentPx: Float = 0
    private(set) var descentPx: Float = 0

    /// Synchronized snapshot of all four font metrics. setFont()/
    /// setBackingScale() write these fields under `mu` from the core/RPC
    /// thread; the render thread must read them together under the same
    /// lock to avoid combining a fresh value in one field with a stale
    /// value in another for one frame.
    func fontMetricsSnapshot() -> (width: Float, height: Float, ascent: Float, descent: Float) {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }
        return (cellWidthPx, cellHeightPx, ascentPx, descentPx)
    }

    // Cross-command-queue read/write synchronization for the shared atlas
    // textures. Each ExternalGridView owns its own MTLCommandQueue (see
    // ExternalGridView.swift), so Metal's automatic hazard tracking — which
    // only orders command buffers within the SAME queue — does not protect
    // this texture from being blitted (prepareBackTexture/encodeBackTextureBlit)
    // or CPU-written (uploadRegion's replace()) while an external queue's
    // render pass is still sampling it.
    //
    // Uses a DispatchGroup (enter/leave pair count), NOT an MTLSharedEvent
    // with per-read sequence numbers: multiple independent ExternalGridView
    // queues signaling one shared event with monotonically-assigned values
    // is unsound, because signaledValue is a cross-queue high-water mark —
    // a LATER-issued value from one queue can be signaled before an
    // EARLIER-issued value from another queue actually completes, so
    // waiting on "signaledValue >= target" can return true while a
    // still-in-flight read (assigned a lower target) hasn't finished.
    // DispatchGroup has no such ordering assumption: wait() only returns
    // once every enter() has a matching leave(), regardless of order.
    //
    // An ExternalGridView calls beginExternalRead() right before encoding a
    // render pass that reads the atlas, and endExternalRead() from that same
    // command buffer's existing completion handler (which must strongly
    // capture whatever it needs to call endExternalRead() — a [weak self]
    // capture of the view would silently drop the matching leave() if the
    // view is deallocated before the GPU completion fires, permanently
    // wedging the group and making every future beginAtlasWrite() time out).
    //
    // A DispatchGroup alone only lets a writer wait for ALREADY-ADMITTED
    // reads to drain — it does not stop a NEW beginExternalRead() from
    // being admitted while that wait is in progress or while the mutation
    // itself is running, which reopens the exact race this exists to close
    // (writer sees count 0 -> new reader enters -> writer mutates while
    // that reader's GPU work samples the texture). `gateLock` closes that
    // window: beginExternalRead() must acquire it (briefly) to enter, and
    // beginAtlasWrite() holds it for the writer's entire critical section
    // (wait-for-drain through the actual mutation), so no new reader can be
    // admitted until the writer calls endAtlasWrite().
    private let gateLock = NSLock()
    // Published before a writer waits for gateLock. Readers check it before
    // and after a non-blocking gate try, so NSLock unfairness cannot let a
    // stream of main-thread readers starve an already-waiting writer.
    private var writerIntentLock = os_unfair_lock()
    private var writerIntentPublished = false
    private let externalReadsGroup = DispatchGroup()
    // gateLock protected. Persists across a failed writer attempt so newly
    // arriving external frames cannot continuously replace the readers that
    // the writer is waiting to drain.
    private var atlasWriterPending = false
    // gateLock protected. A failed writer keeps admission closed until either
    // a later writer succeeds or a successful atlas transaction proves that
    // no mutation is needed for the committed frame. In the latter case this
    // flag lets the last already-admitted reader release the stale intent
    // without reopening admission before that successful transaction exists.
    private var atlasWriterIntentReleaseArmed = false
    // gateLock protected. DispatchGroup notifications cannot be cancelled, so
    // a generation invalidates a queued notification when a real writer starts
    // before it runs. Registration only occurs on the rare recovery path.
    private var atlasWriterIntentNotifyGeneration: UInt64 = 0
    private var atlasWriterIntentNotifyRegistered = false
    // Core-thread only hint. It keeps the ordinary successful-flush path from
    // taking gateLock unless a failed writer actually needs resolution. The
    // asynchronous notification deliberately leaves this conservative; the
    // next core transaction may take one harmless lock and clear the hint.
    private var atlasWriterIntentNeedsTransactionResolution = false

    private func setWriterIntentPublished(_ value: Bool) {
        os_unfair_lock_lock(&writerIntentLock)
        writerIntentPublished = value
        os_unfair_lock_unlock(&writerIntentLock)
    }

    private func writerIntentBlocksReader() -> Bool {
        // Main-thread admission must stay non-blocking even for this tiny
        // intent flag. A contended flag is conservatively treated as intent.
        guard os_unfair_lock_trylock(&writerIntentLock) else { return true }
        let value = writerIntentPublished
        os_unfair_lock_unlock(&writerIntentLock)
        return value
    }

    /// Registers an external read, lets the caller capture a value (e.g. a
    /// texture reference already frozen in a SurfaceBufferSet at commit
    /// time), captures the current blit generation, and encodes a GPU-side
    /// wait for that generation on the reader's own command buffer — all
    /// under one `gateLock` hold, so registration, snapshot, and generation
    /// capture happen as one atomic step relative to any writer.
    ///
    /// A frozen field reference does not remove the race: freezing an
    /// MTLTexture reference doesn't make its CONTENTS immutable, so if the
    /// caller read `committed.atlasTextureSnapshot` before calling this, a
    /// writer's beginAtlasWrite() could see zero admitted reads and start
    /// blitting into that exact texture object (once it cycles back to
    /// being the back buffer on a later flush) before this read is ever
    /// registered.
    ///
    /// Capturing the blit generation as a step SEPARATE from admission has
    /// the same flaw: a writer holds `gateLock` for its entire blit (see
    /// beginAtlasWrite), so once this call has entered the reader group and
    /// captured `blitGeneration` while STILL holding `gateLock`, no writer
    /// can start a new blit (and bump the generation) until this whole
    /// sequence releases the lock — meaning the generation this reader waits
    /// on is guaranteed to cover any blit that could still race its read.
    /// Reading the generation only after releasing the lock (or before
    /// acquiring it) would let a writer's blit land in the gap, leaving the
    /// reader waiting on a stale, already-satisfied value while sampling a
    /// texture a newer, un-waited-for blit is still writing.
    ///
    /// The caller must encode this before creating any render encoder that
    /// samples the atlas (encodeWaitForEvent cannot be issued while an
    /// encoder is open). Admission is non-blocking because this runs on
    /// AppKit's main thread. If `snapshot()` returns nil, no reader is
    /// registered.
    func beginExternalRead<T>(commandBuffer cmd: MTLCommandBuffer, snapshot: () -> T?) -> T? {
        if writerIntentBlocksReader() || !gateLock.try() {
            return nil
        }
        if writerIntentBlocksReader() || atlasWriterPending {
            gateLock.unlock()
            return nil
        }
        guard let value = snapshot() else {
            gateLock.unlock()
            return nil
        }
        externalReadsGroup.enter()
        let gen = blitGeneration
        gateLock.unlock()
        cmd.encodeWaitForEvent(blitCompletionEvent, value: gen)
        return value
    }

    func endExternalRead() {
        externalReadsGroup.leave()
    }

    /// Closes the reader-admission gate (new beginExternalRead() calls are
    /// rejected until the writer completes), then checks whether every
    /// already-admitted read has left without blocking. Call before any atlas
    /// texture mutation (CPU replace() or GPU blit submission); always
    /// pair with endAtlasWrite() (e.g. via defer) so the gate reopens on
    /// every exit path, including early returns.
    ///
    /// Returns false while an admitted read remains undrained. The gate is
    /// still closed in that case (`gateLock` is still held) — callers MUST
    /// treat this as fail-CLOSED: call endAtlasWrite()
    /// and abort/drop the write attempt instead of mutating the texture
    /// anyway. Proceeding on timeout would silently reintroduce the exact
    /// concurrent-read-vs-write race this gate exists to prevent, for the
    /// sake of a rare, already-abnormal (GPU-stalled or leaked) condition —
    /// dropping one upload/blit attempt is far cheaper than a corrupted
    /// frame, and the core's existing retry paths recover it later.
    ///
    /// Must NOT be called while already holding `mu` (does not touch it
    /// directly, but blocks the calling thread, which would stall anything
    /// else waiting on `mu` for the timeout duration).
    func beginAtlasWrite() -> Bool {
        setWriterIntentPublished(true)
        gateLock.lock()
        atlasWriterPending = true
        // An actual writer supersedes cancellation armed by an earlier
        // no-write transaction. If this attempt is still blocked, preserve its
        // intent until another successful writer/transaction resolves it.
        atlasWriterIntentReleaseArmed = false
        invalidateWriterIntentNotificationLocked()
        // The caller holds core grid_mu. Never wait for a GPU/external queue
        // while holding it. Keep writer intent set across the failed attempt:
        // after endAtlasWrite reopens the lock, beginExternalRead rejects new
        // admissions, so the already-admitted group drains and the next flush
        // retry cannot be starved by a continuous stream of external frames.
        if externalReadsGroup.wait(timeout: .now()) == .timedOut {
            atlasWriterIntentNeedsTransactionResolution = true
            ZonvieCore.appLog("[GlyphAtlas] beginAtlasWrite: external reads active — deferring write")
            return false
        }
        atlasWriterPending = false
        atlasWriterIntentNeedsTransactionResolution = false
        return true
    }

    /// Reopens the reader-admission gate closed by beginAtlasWrite().
    func endAtlasWrite() {
        if !atlasWriterPending {
            setWriterIntentPublished(false)
        }
        gateLock.unlock()
    }

    /// Complete a writer intent that was left pending by a failed write attempt
    /// once a brand-new texture has actually become the committed front.
    ///
    /// Existing external readers may still be sampling the old texture object;
    /// that is safe because publishing a fresh object does not mutate their
    /// snapshot. New readers can therefore be admitted immediately. Any later
    /// mutation (including syncing the new front into the old back texture) must
    /// still call beginAtlasWrite(), which closes the gate and drains those
    /// readers again before touching either object.
    ///
    /// Call only after the front-index swap has succeeded, and never while
    /// holding `mu`: the established lock order is gateLock -> mu.
    private func completeWriterIntentAfterFreshTexturePublication() {
        gateLock.lock()
        atlasWriterPending = false
        setWriterIntentPublished(false)
        atlasWriterIntentReleaseArmed = false
        invalidateWriterIntentNotificationLocked()
        atlasWriterIntentNeedsTransactionResolution = false
        gateLock.unlock()
    }

    /// Resolve stale writer intent after a successful transaction that did not
    /// publish a brand-new texture. Unlike the fresh-texture path above, the
    /// old texture objects may still be sampled by admitted readers, so reader
    /// admission remains closed until the DispatchGroup actually drains.
    ///
    /// Must be called after the atlas transaction has committed and without
    /// holding `mu` (lock order remains gateLock -> mu).
    private func completeWriterIntentAfterSuccessfulTransaction() {
        guard atlasWriterIntentNeedsTransactionResolution else { return }
        var notifyGeneration: UInt64? = nil
        gateLock.lock()
        if atlasWriterPending {
            atlasWriterIntentReleaseArmed = true
            if externalReadsGroup.wait(timeout: .now()) == .success {
                atlasWriterPending = false
                setWriterIntentPublished(false)
                atlasWriterIntentReleaseArmed = false
                invalidateWriterIntentNotificationLocked()
            } else if !atlasWriterIntentNotifyRegistered {
                atlasWriterIntentNotifyGeneration &+= 1
                atlasWriterIntentNotifyRegistered = true
                notifyGeneration = atlasWriterIntentNotifyGeneration
            }
        } else {
            setWriterIntentPublished(false)
            atlasWriterIntentReleaseArmed = false
            invalidateWriterIntentNotificationLocked()
        }
        atlasWriterIntentNeedsTransactionResolution = false
        gateLock.unlock()

        if let notifyGeneration {
            registerWriterIntentDrainNotification(generation: notifyGeneration)
        }
    }

    /// gateLock must be held.
    private func invalidateWriterIntentNotificationLocked() {
        guard atlasWriterIntentNotifyRegistered else { return }
        atlasWriterIntentNotifyGeneration &+= 1
        atlasWriterIntentNotifyRegistered = false
    }

    /// Register only after releasing gateLock. If the group drained in the
    /// small gap before registration, DispatchGroup schedules the notification
    /// immediately; the generation check still rejects superseded callbacks.
    private func registerWriterIntentDrainNotification(generation: UInt64) {
        externalReadsGroup.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            self?.handleWriterIntentDrainNotification(generation: generation)
        }
    }

    private func handleWriterIntentDrainNotification(generation: UInt64) {
        var replacementGeneration: UInt64? = nil
        gateLock.lock()
        guard atlasWriterIntentNotifyRegistered,
              atlasWriterIntentNotifyGeneration == generation else {
            gateLock.unlock()
            return
        }

        atlasWriterIntentNotifyRegistered = false
        if atlasWriterPending, atlasWriterIntentReleaseArmed {
            if externalReadsGroup.wait(timeout: .now()) == .success {
                atlasWriterPending = false
                setWriterIntentPublished(false)
                atlasWriterIntentReleaseArmed = false
            } else {
                // Defensive against a future caller admitting a new group
                // epoch between notification scheduling and execution.
                atlasWriterIntentNotifyGeneration &+= 1
                atlasWriterIntentNotifyRegistered = true
                replacementGeneration = atlasWriterIntentNotifyGeneration
            }
        }
        gateLock.unlock()

        if let replacementGeneration {
            registerWriterIntentDrainNotification(generation: replacementGeneration)
        }
    }

    // GPU-side completion sync for the async blit path (encodeBackTextureBlit).
    // beginAtlasWrite/endAtlasWrite close the CPU-side admission window during
    // cmd.commit(), but the blit itself finishes on the GPU strictly AFTER
    // commit() returns — endAtlasWrite() reopening the gate does not mean the
    // texture mutation is done. A reader admitted right after endAtlasWrite()
    // can still get scheduled on the GPU before the blit's writes land, since
    // separate queues have no automatic ordering. Blocking the core thread on
    // waitUntilCompleted() here is not an option (measured regression, see
    // beginFlush's blit path). Instead: single-producer event — only this
    // blit path ever signals it, so (unlike the per-read MTLSharedEvent design
    // rejected earlier for having MULTIPLE producers) there is no cross-queue
    // high-water-mark ambiguity. Every reader encodes a GPU-side wait on its
    // OWN command buffer before touching the atlas texture, which costs no
    // CPU blocking on either side.
    //
    // Uses MTLSharedEvent rather than plain MTLEvent specifically so
    // recoverFailedBlit() below can force-advance the signaled value from
    // the CPU: if the blit command buffer errors out before the GPU reaches
    // encodeSignalEvent, a plain MTLEvent would never reach that generation,
    // permanently hanging any reader already GPU-blocked waiting for it (see
    // recoverFailedBlit's doc comment).
    private let blitCompletionEvent: MTLSharedEvent
    // Protected by gateLock. Readers capture it while admitted under the gate;
    // the sole writer increments it while beginAtlasWrite() holds that gate.
    private var blitGeneration: UInt64 = 0

    /// Called by the writer (MetalTerminalRenderer.beginFlush's blit path)
    /// on the SAME command buffer as encodeBackTextureBlit, right before
    /// cmd.commit(). Must be called while still holding the write critical
    /// section (i.e. before endAtlasWrite()). Returns the generation encoded,
    /// so the caller can pass it to recoverFailedBlit() from that same
    /// command buffer's completion handler if the buffer does not complete
    /// successfully.
    func encodeBlitCompletionSignal(into cmd: MTLCommandBuffer) -> UInt64 {
        blitGeneration += 1
        let gen = blitGeneration
        cmd.encodeSignalEvent(blitCompletionEvent, value: gen)
        return gen
    }

    /// Called from the writer's blit command buffer's own completion handler
    /// when `status != .completed` (GPU error, device loss, etc.). Per
    /// Apple's docs, encodeSignalEvent's value is only applied once the GPU
    /// actually reaches that command — a command buffer that errors out
    /// before then leaves the event at the PREVIOUS generation forever. Any
    /// reader already GPU-blocked in encodeWaitForEvent(value: generation)
    /// would hang permanently: its own completion handler never fires, which
    /// leaks its externalReadsGroup entry and wedges every future
    /// beginAtlasWrite() in a timeout loop — this is strictly worse than the
    /// alternative, since no external window would ever render again.
    ///
    /// Force-advancing the shared event unblocks those readers immediately.
    /// This does not make the sampled atlas region correct — the blit never
    /// finished, so the region may be stale or partially written — but that
    /// is bounded to exactly the frame(s) already in flight when the error
    /// occurred, and setting needsAtlasRebuild here ensures every subsequent
    /// flush discards this atlas and rebuilds from scratch rather than
    /// continuing to read from it. Guarded by signaledValue comparison so a
    /// late-firing completion handler can never move the event BACKWARD past
    /// a generation a later, successful blit already signaled.
    func recoverFailedBlit(generation: UInt64) {
        if blitCompletionEvent.signaledValue < generation {
            blitCompletionEvent.signaledValue = generation
        }
        os_unfair_lock_lock(&mu)
        needsAtlasRebuild = true
        os_unfair_lock_unlock(&mu)
        ZonvieCore.appLog("[GlyphAtlas] WARNING: blit command buffer failed before reaching completion signal (generation=\(generation)) — force-advanced event and scheduled atlas rebuild")
    }

    init?(device: MTLDevice, fontName: String = "Menlo", pointSize: CGFloat = 14.0, atlasSize: Int = 2048) {
        guard let event = device.makeSharedEvent() else {
            ZonvieCore.appLog("[GlyphAtlas] init failed: device.makeSharedEvent() returned nil")
            return nil
        }
        self.device = device
        self.blitCompletionEvent = event
        self.fontName = fontName
        self.pointSize = pointSize
        self.font = CTFontCreateWithName(fontName as CFString, pointSize, nil) // temporary
        // Use the configured atlas size from the start. Otherwise the initial
        // 2048×2048 texture allocated here would be discarded ~150ms later when
        // core.start() calls setAtlasSize() with the configured value, causing
        // an extra Atlas RESET on the startup hot path.
        self.atlasW = atlasSize
        self.atlasH = atlasSize
        self.atlasShadow = Array<UInt8>(repeating: 0, count: atlasSize * atlasSize * 4)

        let initialFront = makeTexture(device: device, w: atlasW, h: atlasH)
        let initialBack = makeTexture(device: device, w: atlasW, h: atlasH)
        guard initialFront != nil, initialBack != nil else { return nil }
        os_unfair_lock_lock(&mu)
        rebuildFont_locked()
        textures[frontIndex] = initialFront
        textures[1 - frontIndex] = initialBack
        pendingTextureRecreate = nil
        needsAtlasRebuild = false
        // Both textures exist, are distinct objects, and are zeroed.
        backDirty = false
        atlasModified = false
        os_unfair_lock_unlock(&mu)
    }
    
    func setFont(name: String, pointSize: CGFloat, features: String = "") {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        // Skip when nothing actually changes. The first guifont event from
        // nvim usually matches the font we already initialized with from
        // ZonvieConfig, so the rebuildFont_locked() → resetAtlas_locked()
        // path otherwise wastes a texture allocation on the startup path
        // (and stalls the first present behind the rebuild).
        let parsedFeatures = Self.parseFontFeatures(features)
        var featuresEqual = parsedFeatures.count == self.fontFeatures.count
        if featuresEqual {
            for i in 0..<parsedFeatures.count {
                if parsedFeatures[i].tag != self.fontFeatures[i].tag ||
                   parsedFeatures[i].value != self.fontFeatures[i].value
                {
                    featuresEqual = false
                    break
                }
            }
        }
        if name == self.fontName, pointSize == self.pointSize, featuresEqual {
            ZonvieCore.appLog("[GlyphAtlas.setFont] no-op (name/size/features unchanged)")
            return
        }

        self.fontName = name
        self.pointSize = pointSize
        self.fontFeatures = parsedFeatures
        ZonvieCore.appLog("[GlyphAtlas.setFont] name='\(name)' pt=\(pointSize) features_str='\(features)' parsed_count=\(self.fontFeatures.count) hasFeatures=\(hasFeatures)")
        rebuildFont_locked()
        atlasModified = true  // atlas generation changed, ensure commit swaps
    }

    func fontGenerationSnapshot() -> UInt64 {
        os_unfair_lock_lock(&mu)
        let generation = fontGeneration
        os_unfair_lock_unlock(&mu)
        return generation
    }

    /// Parse comma-separated feature string: "+liga,-dlig,ss01=2"
    private static func parseFontFeatures(_ s: String) -> [zonvie_font_feature] {
        guard !s.isEmpty else { return [] }
        return s.split(separator: ",").compactMap { token in
            let t = token.trimmingCharacters(in: .whitespaces)
            var tag: String
            var value: Int32

            if t.contains("=") {
                let kv = t.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, kv[0].count == 4, let val = Int32(kv[1]) else { return nil }
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

        if backingScale == ns && !needsAtlasRebuild { return }
        if backingScale == ns { return }
        backingScale = ns

        // Immediate: font rebuild + metrics (needed for layout calculation).
        // cellWidthPx / cellHeightPx are correct after this call.
        rebuildFontAndMetrics_locked()

        // Immediate: clear glyph caches so any in-progress flush does not
        // mix old-scale cache entries with new-scale metrics.
        // clearCaches_locked() is idempotent; prepareBackTexture() may call
        // it again on the next flush — that is harmless.
        clearCaches_locked()

        // Deferred: atlas texture reset applied at prepareBackTexture
        needsAtlasRebuild = true
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
    
            if descPx > 0 { descentPx = Float(ceil(descPx)) }
    
            // Use FT height if valid; fallback to asc+desc.
            let h = (heightPx > 0) ? heightPx : (ascPx + descPx)
            if h > 0 { cellHeightPx = Float(ceil(h)) }
    
            // FreeType reports both metrics already grid-fitted outward, so the
            // baseline is placed from CoreText's unrounded values for the same
            // face instead. Rounding them here would drop the glyph's descender
            // past the bottom of the cell, where it gets clipped away.
            if ascPx > 0 {
                ascentPx = FontCellFit.baselinePx(
                    fontAscentPx: Float(CTFontGetAscent(font)),
                    fontDescentPx: Float(CTFontGetDescent(font)),
                    cellHeightPx: cellHeightPx
                )
            }
    
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

    // NOTE: only call when holding mu. Full rebuild: font + metrics + caches + atlas.
    private func rebuildFont_locked() {
        rebuildFontAndMetrics_locked()
        clearCaches_locked()
        resetAtlas_locked()
    }

    /// Font + metrics rebuild only. Metrics available immediately after return.
    /// Does NOT touch atlas texture or caches.
    // CTFont with kCTFontVariationAttribute applied, used ONLY to obtain the
    // variable font file URL for the base FreeType handle.  nil when no
    // variation axes are requested or the font is not variable.
    private var variableFontHint: CTFont?

    private func rebuildFontAndMetrics_locked() {
        fontGeneration &+= 1
        let size = pointSize * backingScale

        // `font` is always the default-weight CTFont.  It is used for glyph ID
        // lookups (cmap doesn't change with weight) and bold/italic derivation.
        font = CTFontCreateWithName(fontName as CFString, size, nil)
        loadFontVariants_locked(from: font)

        // When variation axes are present, build a hint CTFont that nudges
        // CoreText toward the variable font file.  This is ONLY used as a
        // fallback inside rebuildHbFtFont_locked when the default CTFont
        // resolves to a static weight file (no fvar table).
        let axes = Self.extractVariationAxes(from: fontFeatures)
        variableFontHint = axes.isEmpty ? nil : Self.hintVariableCTFont(font, axes: axes)

        rebuildHbFtFont_locked()
        recomputeMetrics()
    }

    /// Convert ALL feature entries to (tag, value) pairs for the variation
    /// pipeline.  The C-side set_variations matches each tag against the font's
    /// actual fvar axes and silently ignores non-axis tags (e.g. "liga", "ss01").
    /// This avoids hardcoding axis tags and supports custom axes (MONO, CASL, …).
    private static func extractVariationAxes(from features: [zonvie_font_feature]) -> [(tag: UInt32, value: CGFloat)] {
        return features.map { f in
            let tag = UInt32(UInt8(bitPattern: f.tag.0)) << 24
                    | UInt32(UInt8(bitPattern: f.tag.1)) << 16
                    | UInt32(UInt8(bitPattern: f.tag.2)) << 8
                    | UInt32(UInt8(bitPattern: f.tag.3))
            return (tag: tag, value: CGFloat(f.value))
        }
    }

    /// Use kCTFontVariationAttribute to nudge CoreText into selecting the variable
    /// font file.  Always returns the varied CTFont — for static fonts the
    /// variation dictionary is silently ignored and createHbFtFont_locked will
    /// load the same static file (set_variations then becomes a harmless no-op).
    private static func hintVariableCTFont(
        _ baseFont: CTFont,
        axes: [(tag: UInt32, value: CGFloat)]
    ) -> CTFont? {
        var varDict: [NSNumber: NSNumber] = [:]
        for (tag, value) in axes {
            varDict[NSNumber(value: tag)] = NSNumber(value: Double(value))
        }
        let varAttrs: [CFString: Any] = [kCTFontVariationAttribute: varDict]
        let varDesc = CTFontDescriptorCreateWithAttributes(varAttrs as CFDictionary)
        let varFont = CTFontCreateCopyWithAttributes(baseFont, 0, nil, varDesc)

        return varFont
    }

    /// Evict the least recently used fallback font face to free its font_bytes_owned memory.
    /// Already-rasterized glyphs in `map` remain valid; only new rasterizations for the
    /// evicted font will trigger a reload from disk.
    private func evictLRUFallbackFace_locked() {
        guard !fallbackFacesByURL.isEmpty else { return }
        var lruKey: String?
        var lruOrder: UInt64 = .max
        for (urlKey, face) in fallbackFacesByURL {
            if face.accessOrder < lruOrder {
                lruOrder = face.accessOrder
                lruKey = urlKey
            }
        }
        if let evictKey = lruKey, let evicted = fallbackFacesByURL.removeValue(forKey: evictKey) {
            // Remove all map entries referencing the evicted font's key to prevent
            // stale hits if malloc reuses the same pointer address for a new hbft.
            let evictedFontKey = evicted.key
            map = map.filter { $0.key.fontKey != evictedFontKey }
            zonvie_ft_hb_font_destroy(evicted.hbft)
            ZonvieCore.appLog("[Atlas] LRU evict fallback font: \(evicted.url.lastPathComponent) (count=\(fallbackFacesByURL.count))")
        }
    }

    /// Clear all glyph/fallback caches. Must be called before rasterization with new font.
    /// Idempotent: safe to call repeatedly on retry (caches already empty after first call).
    private func clearCaches_locked() {
        for (_, f) in fallbackFacesByURL {
            zonvie_ft_hb_font_destroy(f.hbft)
        }
        fallbackFacesByURL.removeAll()
        failedHbftURLs.removeAll()
        fallbackFontCache.removeAll()
        failedScalarCache.removeAll()
        scalarToGlyphIDCache.removeAll()
    }

    private func loadFontVariants_locked(from baseFont: CTFont) {
        boldFont = CTFontCreateCopyWithSymbolicTraits(
            baseFont, 0, nil, .traitBold, .traitBold)
        italicFont = CTFontCreateCopyWithSymbolicTraits(
            baseFont, 0, nil, .traitItalic, .traitItalic)
        boldItalicFont = CTFontCreateCopyWithSymbolicTraits(
            baseFont, 0, nil, [.traitBold, .traitItalic], [.traitBold, .traitItalic])
    }



    private struct LoadedHbFtFont {
        let handle: OpaquePointer
        let data: NSData
    }

    private func rebuildHbFtFont_locked() {
        let generation = fontGeneration
        let px = UInt32(ceil(pointSize * backingScale))
        let baseFont = font
        let hint = variableFontHint
        let bold = boldFont
        let italic = italicFont
        let boldItalic = boldItalicFont
        let features = fontFeatures
        let logFontName = fontName

        // Full font-file mapping and FreeType/HarfBuzz construction can take
        // tens of milliseconds. Build all four independent handles without
        // holding the atlas mutex; old handles remain valid for readers until
        // the generation-checked publication below.
        os_unfair_lock_unlock(&mu)
        var newBase: LoadedHbFtFont?
        if let hint {
            let baseFaceIdx = ctFontFaceIndex(hint) & 0xFFFF
            newBase = createHbFtFontBorrowed(for: hint, px: px, faceIndex: baseFaceIdx)
        }
        if newBase == nil {
            newBase = createHbFtFontBorrowed(for: baseFont, px: px)
        }
        let newBold = bold.flatMap { createHbFtFontBorrowed(for: $0, px: px) }
        let newItalic = italic.flatMap { createHbFtFontBorrowed(for: $0, px: px) }
        let newBoldItalic = boldItalic.flatMap { createHbFtFontBorrowed(for: $0, px: px) }

        for loaded in [newBase, newBold, newItalic, newBoldItalic] {
            guard let loaded, !features.isEmpty else { continue }
            features.withUnsafeBufferPointer { buf in
                zonvie_ft_hb_font_set_variations(loaded.handle, buf.baseAddress, buf.count)
                zonvie_ft_hb_font_set_features(loaded.handle, buf.baseAddress, buf.count)
            }
        }
        os_unfair_lock_lock(&mu)

        // Another font/scale update won while the mutex was released. Its
        // handles are authoritative; destroy this stale generation only.
        if fontGeneration != generation {
            for loaded in [newBase, newBold, newItalic, newBoldItalic] {
                if let loaded { zonvie_ft_hb_font_destroy(loaded.handle) }
            }
            return
        }

        if let hbftFont { zonvie_ft_hb_font_destroy(hbftFont) }
        if let hbftBold { zonvie_ft_hb_font_destroy(hbftBold) }
        if let hbftItalic { zonvie_ft_hb_font_destroy(hbftItalic) }
        if let hbftBoldItalic { zonvie_ft_hb_font_destroy(hbftBoldItalic) }

        hbftFont = newBase?.handle
        hbftFontData = newBase?.data
        hbftBold = newBold?.handle
        hbftBoldData = newBold?.data
        hbftItalic = newItalic?.handle
        hbftItalicData = newItalic?.data
        hbftBoldItalic = newBoldItalic?.handle
        hbftBoldItalicData = newBoldItalic?.data

        if hbftFont == nil {
            ZonvieCore.appLog("[rebuildHbFtFont] WARNING: hbft create failed for base font '\(logFontName)' px=\(px)")
        }
    }

    private func createHbFtFontBorrowed(for ctFont: CTFont, px: UInt32, faceIndex override: UInt32? = nil) -> LoadedHbFtFont? {
        let ctName = CTFontCopyPostScriptName(ctFont) as String
        let desc = CTFontCopyFontDescriptor(ctFont)
        guard let url = CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute) as? URL else {
            ZonvieCore.appLog("[createHbFtFont] no URL for font '\(ctName)' px=\(px)")
            return nil
        }

        guard let data = try? NSData(contentsOf: url, options: .mappedIfSafe) else {
            ZonvieCore.appLog("[createHbFtFont] failed to read font file '\(url.path)' for '\(ctName)'")
            return nil
        }

        let faceIndex = override ?? ctFontFaceIndex(ctFont)
        guard data.length > 0 else { return nil }
        let created = zonvie_ft_hb_font_create_borrowed(
            data.bytes.assumingMemoryBound(to: UInt8.self),
            data.length,
            px,
            faceIndex
        )

        if created == nil {
            ZonvieCore.appLog("[createHbFtFont] FAILED for '\(ctName)'")
            return nil
        }
        return LoadedHbFtFont(handle: created!, data: data)
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

    /// URL keys that failed hbft creation (e.g., Apple Color Emoji sbix).
    /// Prevents repeated expensive Data(contentsOf:) loads.
    private var failedHbftURLs: Set<String> = []

    private func ensureHbFtFace_locked(for ctFont: CTFont) -> HbFtFace? {
        let desc = CTFontCopyFontDescriptor(ctFont)
        guard let url = CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute) as? URL else {
            return nil
        }

        let faceIndex = ctFontFaceIndex(ctFont)
        let urlKey = "\(url.absoluteString)#\(faceIndex)"

        if var cached = fallbackFacesByURL[urlKey] {
            // LRU: update access order on hit
            fallbackAccessCounter += 1
            cached.accessOrder = fallbackAccessCounter
            fallbackFacesByURL[urlKey] = cached
            return cached
        }

        // Skip URLs that already failed (avoids re-reading 188MB Apple Color Emoji.ttc)
        if failedHbftURLs.contains(urlKey) {
            return nil
        }

        let generation = fontGeneration
        let px = UInt32(ceil(pointSize * backingScale))
        let features = fontFeatures

        // Font files can be hundreds of MiB. Keep mapping and FreeType/HarfBuzz
        // construction outside the atlas mutex so texture upload/readback and
        // cached glyph hits are not blocked by filesystem I/O. Serialize loaders
        // separately to avoid duplicate first-use mappings for the same fallback.
        os_unfair_lock_unlock(&mu)
        os_unfair_lock_lock(&fallbackLoadLock)

        // Another loader may have populated this face while we waited.
        os_unfair_lock_lock(&mu)
        if var cached = fallbackFacesByURL[urlKey] {
            fallbackAccessCounter += 1
            cached.accessOrder = fallbackAccessCounter
            fallbackFacesByURL[urlKey] = cached
            os_unfair_lock_unlock(&fallbackLoadLock)
            return cached
        }
        if failedHbftURLs.contains(urlKey) {
            os_unfair_lock_unlock(&fallbackLoadLock)
            return nil
        }
        if fontGeneration != generation {
            os_unfair_lock_unlock(&fallbackLoadLock)
            return ensureHbFtFace_locked(for: ctFont)
        }
        os_unfair_lock_unlock(&mu)

        let loadStart = CFAbsoluteTimeGetCurrent()
        let data = try? NSData(contentsOf: url, options: .mappedIfSafe)
        let loadEnd = CFAbsoluteTimeGetCurrent()

        // IMPORTANT: make the closure explicitly return OpaquePointer?
        let created: OpaquePointer? = data.flatMap { mapped in
            guard mapped.length > 0 else { return nil }
            return zonvie_ft_hb_font_create_borrowed(
                mapped.bytes.assumingMemoryBound(to: UInt8.self),
                mapped.length,
                px,
                faceIndex
            )
        }
        let createEnd = CFAbsoluteTimeGetCurrent()

        if let hbft = created, !features.isEmpty {
            features.withUnsafeBufferPointer { buf in
                zonvie_ft_hb_font_set_features(hbft, buf.baseAddress, buf.count)
            }
        }

        os_unfair_lock_lock(&mu)
        os_unfair_lock_unlock(&fallbackLoadLock)

        // A concurrent font/scale change invalidates the captured pixel size
        // and features. Destroy the stale handle and retry against the new
        // generation; the function contract still returns with mu held.
        if fontGeneration != generation {
            if let created { zonvie_ft_hb_font_destroy(created) }
            return ensureHbFtFace_locked(for: ctFont)
        }

        guard let hbft = created else {
            ZonvieCore.appLog("[Atlas] hbft create FAILED for \(url.lastPathComponent) (cached as failed)")
            failedHbftURLs.insert(urlKey)
            return nil
        }

        let loadMs = (loadEnd - loadStart) * 1000
        let createMs = (createEnd - loadEnd) * 1000
        ZonvieCore.appLog("[Atlas] NEW fallback font: \(url.lastPathComponent) load=\(String(format: "%.1f", loadMs))ms create=\(String(format: "%.1f", createMs))ms")

        // LRU eviction: if at capacity, destroy the least recently used face
        if fallbackFacesByURL.count >= maxFallbackFaces {
            evictLRUFallbackFace_locked()
        }

        fallbackAccessCounter += 1
        let key = UInt64(UInt(bitPattern: hbft))
        guard let fontData = data else {
            zonvie_ft_hb_font_destroy(hbft)
            failedHbftURLs.insert(urlKey)
            return nil
        }
        let face = HbFtFace(ctFont: ctFont, url: url, fontData: fontData, hbft: hbft, key: key, accessOrder: fallbackAccessCounter)
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

        let scalarChar = ZonvieCore.appLogEnabled ? (UnicodeScalar(scalar).map { String($0) } ?? "?") : ""

        // 1) Try base font first
        if let gid = glyphID(in: font, scalar: scalar) {
            guard let baseHbft = hbftFont else {
                ZonvieCore.appLog("[Atlas] entry(scalar=\(scalar) '\(scalarChar)'): base hbft is nil")
                insertFailedScalar_locked(failKey)
                return nil
            }
            let k = GlyphKey(fontKey: UInt64(UInt(bitPattern: baseHbft)), glyphID: gid)
            let e = entry_forKey_locked(k, hbft: baseHbft, glyphID: gid)
            return e
        }

        // 2) Fallback via CoreText
        guard let fbCT = ctFontForScalarFallback(base: font, scalar: scalar) else {
            ZonvieCore.appLog("[Atlas] entry(scalar=\(scalar) '\(scalarChar)'): no fallback font")
            insertFailedScalar_locked(failKey)
            return nil
        }
        guard let fbGid = glyphID(in: fbCT, scalar: scalar) else {
            ZonvieCore.appLog("[Atlas] entry(scalar=\(scalar) '\(scalarChar)'): fallback font has no glyph")
            insertFailedScalar_locked(failKey)
            return nil
        }
        guard let face = ensureHbFtFace_locked(for: fbCT) else {
            ZonvieCore.appLog("[Atlas] entry(scalar=\(scalar) '\(scalarChar)'): failed to create hbft face")
            insertFailedScalar_locked(failKey)
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
            insertFailedScalar_locked(failKey)
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
            insertFailedScalar_locked(failKey)
            return nil
        }
        guard let fbGid = glyphID(in: fbCT, scalar: scalar) else {
            insertFailedScalar_locked(failKey)
            return nil
        }
        guard let face = ensureHbFtFace_locked(for: fbCT) else {
            insertFailedScalar_locked(failKey)
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
        let cacheKey = GlyphIDCacheKey(fontKey: fontKey, scalar: scalar)

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

        // Cache the result (clear on overflow to bound memory)
        if scalarToGlyphIDCache.count >= maxScalarCacheEntries {
            scalarToGlyphIDCache.removeAll(keepingCapacity: true)
        }
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
        let cfLen = CFStringGetLength(s)
        // Ask CoreText for a font that can render this string.
        let start = CFAbsoluteTimeGetCurrent()
        let fb = CTFontCreateForString(base, s, CFRange(location: 0, length: cfLen))
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if elapsed > 1.0 {
            let scalarChar = String(uni)
            ZonvieCore.appLog("[Atlas] SLOW CTFontCreateForString: scalar=0x\(String(scalar, radix: 16)) '\(scalarChar)' took \(String(format: "%.1f", elapsed))ms")
        }

        // CTFontCreateForString may return LastResort for emoji scalars
        // when the base font is a Nerd Font. Explicitly try Apple Color Emoji.
        var result = fb
        let fbName = CTFontCopyPostScriptName(fb) as String
        if fbName == "LastResort" || fbName == ".LastResort" {
            if let emojiFont = emojiFont(size: CTFontGetSize(base)) {
                // Verify the emoji font actually has this glyph
                if glyphID(in: emojiFont, scalar: scalar) != nil {
                    result = emojiFont
                }
            }
        }

        // Cache the result for future lookups (clear on overflow to bound memory)
        if fallbackFontCache.count >= maxScalarCacheEntries {
            fallbackFontCache.removeAll(keepingCapacity: true)
        }
        fallbackFontCache[cacheKey] = result
        return result
    }

    /// Cached Apple Color Emoji CTFont for emoji fallback.
    private var cachedEmojiFont: CTFont?
    private var cachedEmojiFontSize: CGFloat = 0

    private func emojiFont(size: CGFloat) -> CTFont? {
        if let cached = cachedEmojiFont, cachedEmojiFontSize == size {
            return cached
        }
        let f = CTFontCreateWithName("Apple Color Emoji" as CFString, size, nil)
        cachedEmojiFont = f
        cachedEmojiFontSize = size
        return f
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
        let bi = 1 - frontIndex
        ZonvieCore.appLog("[Atlas] RESET! map.count=\(map.count) nextY=\(nextY)/\(atlasH)")
        map.removeAll(keepingCapacity: true)
        nextX = 1
        nextY = 1
        rowH = 0
        textures[bi] = nil
        pendingTextureRecreate = (index: bi, width: atlasW, height: atlasH)
        needsAtlasRebuild = true
        flushHadRecreate = true
        flushDirtyRect = nil
        stagedUploadRect = nil
        flushUploadTransactionOpen = false
        // NOTE: does NOT set atlasModified.
        // Callers that need swap must set it explicitly:
        //   - setFont: sets atlasModified = true after rebuildFont_locked
        //   - recreateTexture (core callback, incl. scale-change path): sets atlasModified = true
    }

    private func makeTexture(device: MTLDevice, w: Int, h: Int) -> MTLTexture? {
        os_unfair_lock_lock(&textureCreateLock)
        defer { os_unfair_lock_unlock(&textureCreateLock) }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        // .shared (not .managed): avoids Metal internal dirty-region tracking overhead on Apple Silicon.
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            ZonvieCore.appLog("[GlyphAtlas] Failed to create atlas texture (\(w)x\(h))")
            return nil
        }

        // Zero-clear, chunked (was one replace() call per row -- atlasH of
        // them -- with no explanation for the per-row granularity; a single
        // full-texture call would require a w*h*4 scratch allocation on this
        // per-flush-reachable path instead).
        let rowBytes = w * 4
        let chunkRows = min(h, zeroClearChunkRows)
        let chunkBytes = rowBytes * chunkRows
        if zeroChunk.count < chunkBytes { zeroChunk = Array<UInt8>(repeating: 0, count: chunkBytes) }
        zeroChunk.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            var row = 0
            while row < h {
                let rows = min(chunkRows, h - row)
                tex.replace(region: MTLRegionMake2D(0, row, w, rows),
                            mipmapLevel: 0, withBytes: ptr, bytesPerRow: rowBytes)
                row += rows
            }
        }
        return tex
    }

    private func rasterizeAndPack(hbft: OpaquePointer, glyphID: UInt32) -> Entry? {
        guard let tex = textures[1 - frontIndex] else { return nil }

        var bufPtr: UnsafePointer<UInt8>?
        var w: Int32 = 0
        var h: Int32 = 0
        var pitch: Int32 = 0
        var left: Int32 = 0
        var top: Int32 = 0
        var adv26_6: Int32 = 0
        var bpp: Int32 = 1

        let r = zonvie_ft_render_glyph_color(
            hbft,
            glyphID,
            &bufPtr,
            &w,
            &h,
            &pitch,
            &left,
            &top,
            &adv26_6,
            &bpp
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
        let ibpp = Int(bpp)

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

        // Copy FT bitmap into a padded RGBA buffer (top-left origin for texture upload).
        let neededCount = packedW * packedH * 4  // RGBA = 4 bytes per pixel

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

            if ibpp == 4 {
                // BGRA color bitmap (emoji) → convert to RGBA
                for row in 0..<ih {
                    let src = srcBase.advanced(by: row * ipitch)
                    let dstRow = dstBase.advanced(by: (row + pad) * packedW * 4 + pad * 4)
                    for col in 0..<iw {
                        let si = col * 4
                        let di = col * 4
                        dstRow[di + 0] = src[si + 2]  // R ← B
                        dstRow[di + 1] = src[si + 1]  // G ← G
                        dstRow[di + 2] = src[si + 0]  // B ← R
                        dstRow[di + 3] = src[si + 3]  // A ← A
                    }
                }
            } else {
                // Grayscale → expand to RGBA (coverage in all channels)
                for row in 0..<ih {
                    let src = srcBase.advanced(by: row * ipitch)
                    let dstRow = dstBase.advanced(by: (row + pad) * packedW * 4 + pad * 4)
                    for col in 0..<iw {
                        let gray = src[col]
                        let di = col * 4
                        dstRow[di + 0] = gray  // R
                        dstRow[di + 1] = gray  // G
                        dstRow[di + 2] = gray  // B
                        dstRow[di + 3] = gray  // A (coverage)
                    }
                }
            }
        }

        // Upload to RGBA texture.
        scratch.withUnsafeBytes { raw in
            guard let baseAddr = raw.baseAddress else { return }
            let region = MTLRegionMake2D(rectX, rectY, packedW, packedH)
            tex.replace(region: region, mipmapLevel: 0, withBytes: baseAddr, bytesPerRow: packedW * 4)
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

    private func resolveHbftAndGlyph_locked(scalar: UInt32, styleFlags: UInt32) -> (hbft: OpaquePointer?, glyphID: UInt32, ctFont: CTFont)? {
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
            insertFailedScalar_locked(failKey)
            return nil
        }

        // When features are set, use HarfBuzz shaping to get feature-aware glyph ID.
        // Otherwise use CTFont cmap (faster, no shaping overhead).
        if hasFeatures {
            if let gid = glyphIDViaShaping(hbft: hbft, scalar: scalar) {
                return (hbft: hbft, glyphID: gid, ctFont: fontToUse)
            }
        } else {
            if let gid = glyphID(in: fontToUse, scalar: scalar) {
                return (hbft: hbft, glyphID: gid, ctFont: fontToUse)
            }
        }

        // Try base font if styled font didn't have the glyph
        if fontToUse !== font, let baseHbft = hbftFont {
            if hasFeatures {
                if let gid = glyphIDViaShaping(hbft: baseHbft, scalar: scalar) {
                    return (hbft: baseHbft, glyphID: gid, ctFont: font)
                }
            } else {
                if let gid = glyphID(in: font, scalar: scalar) {
                    return (hbft: baseHbft, glyphID: gid, ctFont: font)
                }
            }
        }

        // Fallback font lookup (always uses CTFont to find the right font)
        guard let fbCT = ctFontForScalarFallback(base: fontToUse, scalar: scalar) else {
            insertFailedScalar_locked(failKey)
            return nil
        }

        // Try to create HarfBuzz/FreeType handle for the fallback font.
        // This may fail for bitmap-only fonts (e.g., Apple Color Emoji sbix).
        let face = ensureHbFtFace_locked(for: fbCT)
        let fbHbft: OpaquePointer? = face?.hbft

        if let fbHbft {
            if hasFeatures {
                if let gid = glyphIDViaShaping(hbft: fbHbft, scalar: scalar) {
                    return (hbft: fbHbft, glyphID: gid, ctFont: fbCT)
                }
            } else {
                if let gid = glyphID(in: fbCT, scalar: scalar) {
                    return (hbft: fbHbft, glyphID: gid, ctFont: fbCT)
                }
            }
        }

        // hbft unavailable (bitmap font) — return CTFont-only result for CoreGraphics fallback
        if let gid = glyphID(in: fbCT, scalar: scalar) {
            return (hbft: nil, glyphID: gid, ctFont: fbCT)
        }

        insertFailedScalar_locked(failKey)
        return nil
    }

    /// CoreGraphics fallback for color emoji rendering.
    /// FreeType cannot decode Apple Color Emoji sbix (PNG) tables without libpng.
    /// Uses CTFont + CGContext to render the glyph into an RGBA bitmap.
    /// Must be called with mu locked. Stores pixel data in rasterizeScratch.
    private func renderGlyphWithCoreGraphics_locked(
        ctFont: CTFont, glyphID: UInt32, outBitmap: UnsafeMutablePointer<zonvie_glyph_bitmap>
    ) -> Bool {
        var glyph = CGGlyph(glyphID)

        // Get glyph bounding rect
        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(ctFont, .default, &glyph, &boundingRect, 1)

        // Skip empty glyphs
        if boundingRect.width < 1 || boundingRect.height < 1 {
            return false
        }

        // Get advance
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .default, &glyph, &advance, 1)

        // Compute bitmap dimensions with padding
        let pad: Int = 1
        let bitmapW = Int(ceil(boundingRect.width)) + pad * 2
        let bitmapH = Int(ceil(boundingRect.height)) + pad * 2
        let rowBytes = bitmapW * 4

        // Ensure scratch buffer is large enough
        let needed = rowBytes * bitmapH
        if rasterizeScratch.count < needed {
            rasterizeScratch = Array(repeating: 0, count: needed)
        }

        // Zero the region we'll use
        _ = rasterizeScratch.withUnsafeMutableBufferPointer { buf in
            memset(buf.baseAddress!, 0, needed)
        }

        // Create RGBA CGContext and draw glyph — must happen while pointer is valid
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drawOK = rasterizeScratch.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: bitmapW,
                height: bitmapH,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue  // RGBA premultiplied
            ) else {
                return false
            }

            // Position the glyph: origin accounts for bbox offset + padding
            let originX = CGFloat(pad) - boundingRect.origin.x
            let originY = CGFloat(pad) - boundingRect.origin.y
            var position = CGPoint(x: originX, y: originY)
            var g = glyph

            CTFontDrawGlyphs(ctFont, &g, &position, 1, ctx)
            return true
        }
        if !drawOK { return false }

        // Fill outBitmap
        let bearingX = Int32(floor(boundingRect.origin.x)) - Int32(pad)
        let bearingY = Int32(ceil(boundingRect.origin.y + boundingRect.height)) + Int32(pad)

        rasterizeScratch.withUnsafeBufferPointer { buf in
            outBitmap.pointee.pixels = buf.baseAddress
        }
        outBitmap.pointee.width = UInt32(bitmapW)
        outBitmap.pointee.height = UInt32(bitmapH)
        outBitmap.pointee.pitch = Int32(rowBytes)
        outBitmap.pointee.bearing_x = bearingX
        outBitmap.pointee.bearing_y = bearingY
        outBitmap.pointee.advance_26_6 = Int32(advance.width * 64.0)
        outBitmap.pointee.bytes_per_pixel = 4
        outBitmap.pointee.ascent_px = ascentPx
        outBitmap.pointee.descent_px = descentPx

        return true
    }

    /// Render a multi-codepoint emoji cluster using CoreText line layout.
    /// Handles VS16 emoji, ZWJ sequences, flag sequences, etc.
    /// Must be called with mu locked. Stores pixel data in rasterizeScratch.
    private func renderEmojiClusterWithCoreGraphics_locked(
        scalars: UnsafePointer<UInt32>, count: Int,
        outBitmap: UnsafeMutablePointer<zonvie_glyph_bitmap>
    ) -> Bool {
        // Build a String from the cluster scalars using UnicodeScalarView
        // to preserve the exact sequence (Character append may break ZWJ joining).
        var str = ""
        for i in 0..<count {
            guard let uni = UnicodeScalar(scalars[i]) else { continue }
            str.unicodeScalars.append(uni)
        }
        if str.isEmpty { return false }

        // Use Apple Color Emoji as the primary font
        guard let ef = emojiFont(size: CTFontGetSize(font)) else { return false }

        // Create an attributed string with the emoji font
        let attrStr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attrStr, CFRange(location: 0, length: 0), str as CFString)
        let fullRange = CFRange(location: 0, length: CFAttributedStringGetLength(attrStr))
        CFAttributedStringSetAttribute(attrStr, fullRange, kCTFontAttributeName, ef)

        // Create a CTLine and measure its bounds
        let line = CTLineCreateWithAttributedString(attrStr)
        var lineAscent: CGFloat = 0
        var lineDescent: CGFloat = 0
        var lineLeading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, &lineLeading)

        if lineWidth < 1 || (lineAscent + lineDescent) < 1 { return false }

        let pad: Int = 1
        let bitmapW = Int(ceil(lineWidth)) + pad * 2
        let bitmapH = Int(ceil(lineAscent + lineDescent)) + pad * 2
        let rowBytes = bitmapW * 4

        // Ensure scratch buffer
        let needed = rowBytes * bitmapH
        if rasterizeScratch.count < needed {
            rasterizeScratch = Array(repeating: 0, count: needed)
        }
        _ = rasterizeScratch.withUnsafeMutableBufferPointer { buf in
            memset(buf.baseAddress!, 0, needed)
        }

        // Draw into RGBA context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drawOK = rasterizeScratch.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: bitmapW,
                height: bitmapH,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }

            // Position: baseline at (pad, pad + lineDescent)
            let originX = CGFloat(pad)
            let originY = CGFloat(pad) + lineDescent
            ctx.textPosition = CGPoint(x: originX, y: originY)
            CTLineDraw(line, ctx)
            return true
        }
        if !drawOK { return false }

        // Compute advance from the first scalar
        var firstGlyph = CGGlyph(0)
        if let gid = glyphID(in: ef, scalar: scalars[0]) {
            firstGlyph = CGGlyph(gid)
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ef, .default, &firstGlyph, &advance, 1)

        // Fill outBitmap
        let bearingX = Int32(0) - Int32(pad)
        let bearingY = Int32(ceil(lineAscent)) + Int32(pad)

        rasterizeScratch.withUnsafeBufferPointer { buf in
            outBitmap.pointee.pixels = buf.baseAddress
        }
        outBitmap.pointee.width = UInt32(bitmapW)
        outBitmap.pointee.height = UInt32(bitmapH)
        outBitmap.pointee.pitch = Int32(rowBytes)
        outBitmap.pointee.bearing_x = bearingX
        outBitmap.pointee.bearing_y = bearingY
        outBitmap.pointee.advance_26_6 = Int32(advance.width * 64.0)
        outBitmap.pointee.bytes_per_pixel = 4
        outBitmap.pointee.ascent_px = ascentPx
        outBitmap.pointee.descent_px = descentPx

        return true
    }

    /// Phase 2: Rasterize a glyph without atlas packing.
    /// Fills outBitmap with the FreeType bitmap data.
    /// The pixel pointer is valid until the next rasterize call.
    func rasterizeOnly(scalar: UInt32, styleFlags: UInt32, corePtr: OpaquePointer?, outBitmap: UnsafeMutablePointer<zonvie_glyph_bitmap>) -> Bool {
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        // Check if flush set an emoji cluster context (e.g., base + VS16,
        // ZWJ sequence, flag sequence). Render the full cluster via CTLine
        // so multi-codepoint emoji display correctly — matching Windows which
        // converts the cluster to UTF-16 for DirectWrite.
        var clusterLen: UInt8 = 0
        let clusterPtr = zonvie_core_get_emoji_cluster(corePtr, &clusterLen)
        if clusterLen > 0, let ptr = clusterPtr {
            outBitmap.pointee.ascent_px = ascentPx
            outBitmap.pointee.descent_px = descentPx
            if renderEmojiClusterWithCoreGraphics_locked(
                scalars: ptr, count: Int(clusterLen), outBitmap: outBitmap
            ) {
                return true
            }
            // Fall through to normal path if cluster rendering failed
        }

        guard let resolved = resolveHbftAndGlyph_locked(scalar: scalar, styleFlags: styleFlags) else {
            return false
        }

        // No hbft handle (bitmap-only font like Apple Color Emoji) — go straight to CoreGraphics
        if resolved.hbft == nil {
            outBitmap.pointee.ascent_px = ascentPx
            outBitmap.pointee.descent_px = descentPx
            if renderGlyphWithCoreGraphics_locked(
                ctFont: resolved.ctFont, glyphID: resolved.glyphID, outBitmap: outBitmap
            ) {
                return true
            }
            outBitmap.pointee.pixels = nil
            outBitmap.pointee.width = 0
            outBitmap.pointee.height = 0
            outBitmap.pointee.bytes_per_pixel = 1
            return true
        }

        var bufPtr: UnsafePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0, pitch: Int32 = 0
        var left: Int32 = 0, top: Int32 = 0, adv26_6: Int32 = 0
        var bpp: Int32 = 1

        let r = zonvie_ft_render_glyph_color(
            resolved.hbft, resolved.glyphID,
            &bufPtr, &w, &h, &pitch, &left, &top, &adv26_6, &bpp
        )

        outBitmap.pointee.bearing_x = left
        outBitmap.pointee.bearing_y = top
        outBitmap.pointee.advance_26_6 = adv26_6
        outBitmap.pointee.ascent_px = ascentPx
        outBitmap.pointee.descent_px = descentPx

        // FreeType color rendering failed or produced empty bitmap.
        // Fall back to CoreGraphics for color emoji (sbix/COLR fonts need libpng).
        if r != 0 || w <= 0 || h <= 0 || bufPtr == nil {
            if renderGlyphWithCoreGraphics_locked(
                ctFont: resolved.ctFont, glyphID: resolved.glyphID, outBitmap: outBitmap
            ) {
                return true
            }
            // Also try grayscale FreeType as last resort
            let r2 = zonvie_ft_render_glyph(
                resolved.hbft!, resolved.glyphID,
                &bufPtr, &w, &h, &pitch, &left, &top, &adv26_6
            )
            outBitmap.pointee.bearing_x = left
            outBitmap.pointee.bearing_y = top
            outBitmap.pointee.advance_26_6 = adv26_6
            if r2 != 0 || w <= 0 || h <= 0 || bufPtr == nil {
                // Distinguish a genuine rasterization failure (FreeType/hbft
                // returned a nonzero error code from either attempt above) from a
                // legitimately empty glyph (e.g. real whitespace, which returns
                // r == 0 / r2 == 0 with w == 0 / h == 0). Both are cached
                // identically as a permanently-blank glyph by the core
                // (ensureGlyphPhase2 -> packAndUploadBitmap in nvim_core.zig) --
                // this log does not change that caching behavior, it only makes
                // transient rasterization failures observable for future
                // debugging.
                if r != 0 || r2 != 0 {
                    ZonvieCore.appLog("[Atlas] rasterizeOnly: FreeType/hbft error (color_r=\(r) gray_r=\(r2)) for glyphID=\(resolved.glyphID) scalar=\(scalar) -- caching as permanently blank, no retry")
                }
                outBitmap.pointee.pixels = nil
                outBitmap.pointee.width = 0
                outBitmap.pointee.height = 0
                outBitmap.pointee.bytes_per_pixel = 1
                return true
            }
            bpp = 1
        }

        // Copy bitmap data to stable buffer while under lock.
        // This prevents use-after-free if main thread destroys FreeType font
        // (via setBackingScale/rebuildFont_locked) between rasterizeOnly and uploadRegion.
        let ibpp = Int(bpp)
        let rowBytes = Int(w) * ibpp
        let needed = rowBytes * Int(h)
        if rasterizeScratch.count < needed {
            rasterizeScratch = Array(repeating: 0, count: needed)
        }
        let absPitch = abs(Int(pitch))
        rasterizeScratch.withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else { return }
            for row in 0..<Int(h) {
                let srcRow = pitch >= 0 ? row : (Int(h) - 1 - row)
                let src = bufPtr!.advanced(by: srcRow * absPitch)
                if ibpp == 4 {
                    // BGRA → RGBA conversion
                    let dstRow = base.advanced(by: row * rowBytes)
                    for col in 0..<Int(w) {
                        let si = col * 4
                        let di = col * 4
                        dstRow[di + 0] = src[si + 2]  // R ← B
                        dstRow[di + 1] = src[si + 1]  // G ← G
                        dstRow[di + 2] = src[si + 0]  // B ← R
                        dstRow[di + 3] = src[si + 3]  // A ← A
                    }
                } else {
                    memcpy(base.advanced(by: row * rowBytes), src, rowBytes)
                }
            }
        }
        rasterizeScratch.withUnsafeBufferPointer { buf in
            outBitmap.pointee.pixels = buf.baseAddress
        }
        outBitmap.pointee.width = UInt32(w)
        outBitmap.pointee.height = UInt32(h)
        outBitmap.pointee.pitch = Int32(rowBytes)
        outBitmap.pointee.bytes_per_pixel = UInt32(bpp)

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

    /// Select the appropriate CTFont for the given style flags.
    /// Must be called with mu locked.
    private func selectCtFont_locked(styleFlags: UInt32) -> CTFont {
        let isBold = (styleFlags & ZONVIE_STYLE_BOLD) != 0
        let isItalic = (styleFlags & ZONVIE_STYLE_ITALIC) != 0

        if isBold && isItalic {
            return boldItalicFont ?? boldFont ?? italicFont ?? font
        } else if isBold {
            return boldFont ?? font
        } else if isItalic {
            return italicFont ?? font
        } else {
            return font
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
        var bpp: Int32 = 1

        let r = zonvie_ft_render_glyph_color(
            hbft, glyphID,
            &bufPtr, &w, &h, &pitch, &left, &top, &adv26_6, &bpp
        )

        outBitmap.pointee.bearing_x = left
        outBitmap.pointee.bearing_y = top
        outBitmap.pointee.advance_26_6 = adv26_6
        outBitmap.pointee.ascent_px = ascentPx
        outBitmap.pointee.descent_px = descentPx

        if r != 0 || w <= 0 || h <= 0 || bufPtr == nil {
            // FreeType color failed — try CoreGraphics fallback
            let ctFontToUse = selectCtFont_locked(styleFlags: styleFlags)
            if renderGlyphWithCoreGraphics_locked(
                ctFont: ctFontToUse, glyphID: glyphID, outBitmap: outBitmap
            ) {
                return true
            }
            outBitmap.pointee.pixels = nil
            outBitmap.pointee.width = 0
            outBitmap.pointee.height = 0
            outBitmap.pointee.bytes_per_pixel = 1
        } else {
            // Copy bitmap data to stable buffer (same as rasterizeOnly)
            let ibpp = Int(bpp)
            let rowBytes = Int(w) * ibpp
            let needed = rowBytes * Int(h)
            if rasterizeScratch.count < needed {
                rasterizeScratch = Array(repeating: 0, count: needed)
            }
            let absPitch = abs(Int(pitch))
            rasterizeScratch.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                for row in 0..<Int(h) {
                    let srcRow = pitch >= 0 ? row : (Int(h) - 1 - row)
                    let src = bufPtr!.advanced(by: srcRow * absPitch)
                    if ibpp == 4 {
                        // BGRA → RGBA conversion
                        let dstRow = base.advanced(by: row * rowBytes)
                        for col in 0..<Int(w) {
                            let si = col * 4
                            let di = col * 4
                            dstRow[di + 0] = src[si + 2]  // R ← B
                            dstRow[di + 1] = src[si + 1]  // G ← G
                            dstRow[di + 2] = src[si + 0]  // B ← R
                            dstRow[di + 3] = src[si + 3]  // A ← A
                        }
                    } else {
                        memcpy(base.advanced(by: row * rowBytes), src, rowBytes)
                    }
                }
            }
            rasterizeScratch.withUnsafeBufferPointer { buf in
                outBitmap.pointee.pixels = buf.baseAddress
            }
            outBitmap.pointee.width = UInt32(w)
            outBitmap.pointee.height = UInt32(h)
            outBitmap.pointee.pitch = Int32(rowBytes)
            outBitmap.pointee.bytes_per_pixel = UInt32(bpp)
        }

        return true
    }

    enum UploadResult {
        case uploaded
        /// No texture state is corrupt. Abort the current flush and retry after
        /// already-admitted external readers or an asynchronous back-sync blit
        /// completes; rebuilding the atlas here would create avoidable churn.
        case retryAfterReaderDrain
        /// The back texture or its synchronization failed. The core must abort
        /// this flush and invalidate its glyph cache before retrying.
        case requiresRebuild
    }

    /// Phase 2: Upload glyph bitmap data to atlas texture at the specified
    /// position. Returns a classified failure if the upload did NOT actually
    /// happen (the caller must treat the just-computed GlyphEntry's UVs as invalid —
    /// on_atlas_upload's C ABI is void, so the core has no way to see this
    /// return value directly; the caller is responsible for propagating
    /// failure through zonvie_core_abort_flush(), and invalidate the glyph
    /// cache only for a terminal rebuild failure, since core's
    /// glyph_cache_by_id/glyph_cache_non_ascii are PERSISTENT across
    /// flushes — an uncorrected bad entry would be cached as a permanent
    /// hit, not just missed on "the next cache miss").
    @discardableResult
    func uploadRegion(destX: Int, destY: Int, width: Int, height: Int, bitmap: UnsafePointer<zonvie_glyph_bitmap>) -> UploadResult {
        // Rasterization and CPU-shadow staging do not mutate either Metal
        // texture. Keep them outside the external-reader gate; the short
        // texture replace in endFlushUploadTransaction() is the only upload
        // operation that needs writer admission.
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        let tex = textures[1 - frontIndex]  // always write to back
        guard let tex, let pixels = bitmap.pointee.pixels else { return .requiresRebuild }

        // Defensive: bounds-check the destination region against the actual texture
        // dimensions before touching it, and require strictly positive width/height.
        // Positivity matters: a NEGATIVE width and height pair would slip through
        // the other checks (needed = width * height * 4 is positive when both are
        // negative, and destX + width <= tex.width trivially holds for negative
        // width) and then trap at the `for row in 0..<height`-derived loop below.
        // Unreachable today (the sole caller, packAndUploadBitmap in nvim_core.zig,
        // always passes a region that fits inside the atlas it just packed into),
        // but this is a C ABI boundary and nothing on the Swift side enforces the
        // invariant.
        guard width > 0, height > 0, destX >= 0, destY >= 0, destX + width <= tex.width, destY + height <= tex.height else {
            ZonvieCore.appLog("[GlyphAtlas] uploadRegion: destination region (\(destX),\(destY) \(width)x\(height)) out of bounds for texture \(tex.width)x\(tex.height), skipping upload")
            return .requiresRebuild
        }

        let pitch = Int(bitmap.pointee.pitch)
        let absPitch = abs(pitch)
        let bpp = Int(bitmap.pointee.bytes_per_pixel)
        let shadowRowBytes = atlasW * 4
        guard atlasShadow.count == shadowRowBytes * atlasH else {
            ZonvieCore.appLog("[GlyphAtlas] uploadRegion: CPU shadow size mismatch; forcing rebuild")
            needsAtlasRebuild = true
            return .requiresRebuild
        }

        atlasShadow.withUnsafeMutableBufferPointer { dst in
            guard let shadowBase = dst.baseAddress else { return }
            let srcWidth = min(width, Int(bitmap.pointee.width))
            let srcHeight = min(height, Int(bitmap.pointee.height))
            for row in 0..<height {
                let dstRow = shadowBase.advanced(by: (destY + row) * shadowRowBytes + destX * 4)
                memset(dstRow, 0, width * 4)
            }
            for row in 0..<srcHeight {
                let srcRow = pitch >= 0 ? row : (srcHeight - 1 - row)
                let src = pixels.advanced(by: srcRow * absPitch)
                let dstRow = shadowBase.advanced(by: (destY + row) * shadowRowBytes + destX * 4)
                if bpp >= 4 {
                    // RGBA data (already BGRA→RGBA converted by rasterizeOnly)
                    memcpy(dstRow, src, srcWidth * 4)
                } else {
                    // Grayscale → expand to RGBA
                    for col in 0..<srcWidth {
                        let gray = src[col]
                        let di = col * 4
                        dstRow[di + 0] = gray  // R
                        dstRow[di + 1] = gray  // G
                        dstRow[di + 2] = gray  // B
                        dstRow[di + 3] = gray  // A (coverage)
                    }
                }
            }
        }

        atlasModified = true
        if var rect = stagedUploadRect {
            rect.union(x: destX, y: destY, width: width, height: height)
            stagedUploadRect = rect
        } else {
            stagedUploadRect = AtlasDirtyRect(x: destX, y: destY, width: width, height: height)
        }
        if var rect = flushDirtyRect {
            rect.union(x: destX, y: destY, width: width, height: height)
            flushDirtyRect = rect
        } else {
            flushDirtyRect = AtlasDirtyRect(x: destX, y: destY, width: width, height: height)
        }
        flushUploadTransactionOpen = true
        return .uploaded
    }

    /// Flush all staged glyph pixels with one driver call. Reader admission is
    /// closed only for the actual texture replace, never for rasterization,
    /// fallback font resolution, bitmap copies, or vertex generation.
    ///
    /// Returns false without discarding staged CPU pixels when a prior blit or
    /// external reader is still active. The renderer aborts presentation and a
    /// later retry commits the same staging, preserving core glyph-cache UVs.
    @discardableResult
    func endFlushUploadTransaction() -> Bool {
        guard flushUploadTransactionOpen else { return true }
        switch pollPendingBackBlit() {
        case .ready:
            break
        case .pending:
            return false
        case .failed:
            os_unfair_lock_lock(&mu)
            stagedUploadRect = nil
            flushUploadTransactionOpen = false
            os_unfair_lock_unlock(&mu)
            return false
        }

        guard beginAtlasWrite() else {
            endAtlasWrite()
            return false
        }
        defer { endAtlasWrite() }

        os_unfair_lock_lock(&mu)
        var committed = true
        if let rect = stagedUploadRect,
           let tex = textures[1 - frontIndex] {
            atlasShadow.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let byteOffset = (rect.y * atlasW + rect.x) * 4
                tex.replace(
                    region: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height),
                    mipmapLevel: 0,
                    withBytes: base.advanced(by: byteOffset),
                    bytesPerRow: atlasW * 4
                )
            }
            stagedUploadRect = nil
        } else if stagedUploadRect != nil {
            needsAtlasRebuild = true
            stagedUploadRect = nil
            committed = false
        }
        if committed { flushUploadTransactionOpen = false }
        os_unfair_lock_unlock(&mu)
        return committed
    }

    /// Phase 2: Recreate atlas texture with the given dimensions.
    @discardableResult
    func recreateTexture(width: Int, height: Int) -> Bool {
        let newTex = makeTexture(device: device, w: width, h: height)
        os_unfair_lock_lock(&mu)
        defer { os_unfair_lock_unlock(&mu) }

        let bi = 1 - frontIndex
        guard let newTex else {
            pendingTextureRecreate = (index: bi, width: width, height: height)
            // Route the failure into the existing scale-path
            // abort-until-repaired loop (prepareBackTexture consumes this flag
            // first thing and returns needsCoreInvalidation; ZonvieCore's
            // on_flush_begin then re-runs the invalidation dance and aborts
            // the flush while the flag is still set). This also invalidates
            // the core's cached glyph entries whose UVs were never uploaded
            // (their uploadRegion calls were silently dropped into the nil
            // slot), which a bare allocation retry cannot do.
            needsAtlasRebuild = true
            ZonvieCore.appLog("[GlyphAtlas] recreateTexture: makeTexture failed for slot \(bi), will retry via needsAtlasRebuild + slot repair on next beginFlush")
            return false
        }
        if pendingTextureRecreate?.index == bi { pendingTextureRecreate = nil }
        textures[bi] = newTex
        // Update atlas dimensions to match core-configured size
        atlasW = width
        atlasH = height
        let shadowBytes = width * height * 4
        if atlasShadow.count != shadowBytes {
            atlasShadow = Array<UInt8>(repeating: 0, count: shadowBytes)
        } else {
            atlasShadow.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { memset(base, 0, raw.count) }
            }
        }
        // Reset local packer state (core manages packing in Phase 2)
        nextX = 1
        nextY = 1
        rowH = 0
        map.removeAll(keepingCapacity: true)
        failedScalarCache.removeAll(keepingCapacity: true)
        atlasModified = true
        flushHadRecreate = true
        flushDirtyRect = nil
        stagedUploadRect = nil
        flushUploadTransactionOpen = false
        // The successfully allocated slot completes the rebuild requested by
        // setBackingScale, setFont, or a prior allocation/command failure.
        needsAtlasRebuild = false
        return true
    }

    // MARK: - Double-Buffer Lifecycle

    struct PrepareResult {
        let needsGpuBlit: Bool  // true = caller must create command buffer and call encodeBackTextureBlit
        let didCpuSync: Bool
        let needsCoreInvalidation: Bool
        let shouldAbort: Bool
        let syncedWasRecreate: Bool
    }

    // State captured during prepareBackTexture for deferred GPU blit.
    // Valid only when prepareBackTexture returns needsGpuBlit=true.
    private var pendingBlitFront: MTLTexture?
    private var pendingBlitBack: MTLTexture?
    private var pendingBlitWasRecreate: Bool = false
    private var pendingBlitRect: AtlasDirtyRect?

    // Committed-but-unresolved blit command buffer. A later flush polls it
    // during preflight, while an actual CPU upload or front publication waits
    // for it before touching the back texture.
    private var pendingBlitCmdLock = os_unfair_lock()
    private var pendingBlitCmd: MTLCommandBuffer?

    // Core-thread-only. True while CPU-shadow pixels still need one batched
    // texture replace. It does not imply ownership of the reader/writer gate.
    private var flushUploadTransactionOpen = false

    /// Record the committed (not yet completed) blit command buffer.
    func setPendingBackBlit(_ cmd: MTLCommandBuffer) {
        os_unfair_lock_lock(&pendingBlitCmdLock)
        pendingBlitCmd = cmd
        os_unfair_lock_unlock(&pendingBlitCmdLock)
    }

    enum PendingBlitResolution: Equatable {
        case ready
        case pending
        case failed
    }

    /// Poll a deferred front->back blit and mark the back texture synced once
    /// complete. This never waits: every caller runs while core grid_mu is held,
    /// so in-flight work must abort/retry instead of blocking the redraw thread.
    /// A terminal command failure forces a full rebuild.
    @discardableResult
    func pollPendingBackBlit() -> PendingBlitResolution {
        os_unfair_lock_lock(&pendingBlitCmdLock)
        let cmd = pendingBlitCmd
        pendingBlitCmd = nil
        os_unfair_lock_unlock(&pendingBlitCmdLock)
        guard let cmd else { return .ready }

        if cmd.status == .completed {
            markBackSynced()
            return .ready
        }
        if cmd.status == .notEnqueued || cmd.status == .enqueued ||
           cmd.status == .committed || cmd.status == .scheduled {
            os_unfair_lock_lock(&pendingBlitCmdLock)
            if pendingBlitCmd == nil { pendingBlitCmd = cmd }
            os_unfair_lock_unlock(&pendingBlitCmdLock)
            return .pending
        }
        ZonvieCore.appLog("[WARNING] GlyphAtlas: deferred back blit failed (status=\(cmd.status.rawValue)); forcing atlas rebuild")
        os_unfair_lock_lock(&mu)
        needsAtlasRebuild = true
        os_unfair_lock_unlock(&mu)
        return .failed
    }

    /// Phase 1: Called from beginFlush() on core thread.
    /// Handles atlas rebuild, CPU sync, and no-op cases WITHOUT a command buffer.
    /// If GPU blit is needed, returns needsGpuBlit=true and the caller should
    /// create a command buffer and call encodeBackTextureBlit().
    func prepareBackTexture() -> PrepareResult {
        // Resolve a still-pending blit from the PREVIOUS flush first: the
        // decisions below (backDirty, CPU-sync replace) require its result.
        guard pollPendingBackBlit() == .ready else {
            return PrepareResult(needsGpuBlit: false, didCpuSync: false, needsCoreInvalidation: false, shouldAbort: true, syncedWasRecreate: false)
        }

        // Allocate/zero a missing or wrong-sized slot without holding mu.
        os_unfair_lock_lock(&mu)
        let repair = pendingTextureRecreate
        let repairWillBeRecreatedByInvalidation = needsAtlasRebuild && repair?.index == (1 - frontIndex)
        os_unfair_lock_unlock(&mu)
        // A pending rebuild asks the core invalidation callback to recreate
        // the current back slot. Do not allocate that same slot once here and
        // immediately replace it again in recreateTexture(). A missing front
        // slot still needs this independent repair because recreateTexture()
        // deliberately targets only the back slot.
        if !repairWillBeRecreatedByInvalidation,
           let repair,
           let retryTex = makeTexture(device: device, w: repair.width, h: repair.height) {
            os_unfair_lock_lock(&mu)
            if let current = pendingTextureRecreate,
               current.index == repair.index,
               current.width == repair.width,
               current.height == repair.height {
                textures[repair.index] = retryTex
                pendingTextureRecreate = nil
                ZonvieCore.appLog("[GlyphAtlas] prepareBackTexture: repaired texture slot \(repair.index)")
            }
            os_unfair_lock_unlock(&mu)
        }
        os_unfair_lock_lock(&mu)

        // Repair a previously-failed recreateTexture() allocation FIRST, before
        // either early return below. Placement matters twice over:
        //  - it must run before the `guard backDirty` return: in the
        //    failed-before-any-upload case no swap happened and backDirty stays
        //    false, so a retry placed any later would never be reached and
        //    uploads would keep silently dropping into the nil slot forever;
        //  - it must run before the needsAtlasRebuild consume: after a
        //    mid-flush front-swap the nil slot can be frontIndex, which the
        //    invalidation path's recreateTexture (always targeting
        //    1 - frontIndex) structurally never repairs — this block is the
        //    only thing that can fix that slot.
        // A repaired slot holds a fresh empty texture; the needsAtlasRebuild
        // half of this fix (set alongside pendingTextureRecreate on failure)
        // takes care of invalidating the core's stale cached glyphs.
        // Apply deferred atlas rebuild (from setBackingScale)
        if needsAtlasRebuild {
            clearCaches_locked()
            backDirty = false
            os_unfair_lock_unlock(&mu)
            return PrepareResult(needsGpuBlit: false, didCpuSync: false, needsCoreInvalidation: true, shouldAbort: false, syncedWasRecreate: false)
        }

        guard backDirty else {
            os_unfair_lock_unlock(&mu)
            return PrepareResult(needsGpuBlit: false, didCpuSync: false, needsCoreInvalidation: false, shouldAbort: false, syncedWasRecreate: false)
        }

        let fi = frontIndex
        let bi = 1 - frontIndex
        let syncedWasRecreate = pendingBackSyncWasRecreate
        let syncedRect = pendingBackSyncRect
        guard let front = textures[fi], let back = textures[bi] else {
            os_unfair_lock_unlock(&mu)
            return PrepareResult(needsGpuBlit: false, didCpuSync: false, needsCoreInvalidation: false, shouldAbort: true, syncedWasRecreate: syncedWasRecreate)
        }

        // Defensive: recreate back if size mismatch
        if back.width != front.width || back.height != front.height {
            pendingTextureRecreate = (index: bi, width: front.width, height: front.height)
            os_unfair_lock_unlock(&mu)
            return PrepareResult(needsGpuBlit: false, didCpuSync: false, needsCoreInvalidation: false, shouldAbort: true, syncedWasRecreate: syncedWasRecreate)
        }

        // Front->back sync always goes through a GPU blit. A CPU
        // getBytes/replace fast path used to handle small dirty rects here,
        // but CPU access to a texture that a still-in-flight command buffer
        // (encoded before the last swap, when this back texture was front)
        // may be sampling is unsynchronized per Metal's docs — it was only
        // masked by append-only/byte-identical invariants. A blit command on
        // the same queue is hazard-tracked against those in-flight reads,
        // and completion is polled by a later flush, so the GPU route never
        // blocks the core thread. That automatic
        // ordering is scoped to the main renderer's OWN MTLCommandQueue --
        // it does not cover ExternalGridView's reads, each of which runs on
        // its own separate MTLCommandQueue. The caller (MetalTerminalRenderer's
        // beginFlush, right before committing this blit's command buffer)
        // calls beginAtlasWrite()/endAtlasWrite() to close that gap explicitly instead
        // of relying solely on the append-only/byte-identical/fresh-texture
        // invariants documented in uploadRegion() above.

        // GPU blit needed — save state for encodeBackTextureBlit()
        pendingBlitFront = front
        pendingBlitBack = back
        pendingBlitWasRecreate = syncedWasRecreate
        pendingBlitRect = syncedRect
        // DO NOT set backDirty = false here — caller must call markBackSynced() after blit completes.
        os_unfair_lock_unlock(&mu)
        return PrepareResult(needsGpuBlit: true, didCpuSync: false, needsCoreInvalidation: false, shouldAbort: false, syncedWasRecreate: syncedWasRecreate)
    }

    /// Phase 2: Encode GPU blit into the given command buffer.
    /// Only call this when prepareBackTexture() returned needsGpuBlit=true.
    func cancelPendingBackTextureBlit() {
        pendingBlitFront = nil
        pendingBlitBack = nil
        pendingBlitRect = nil
        pendingBlitWasRecreate = false
    }

    func encodeBackTextureBlit(commandBuffer: MTLCommandBuffer) -> Bool {
        guard let front = pendingBlitFront, let back = pendingBlitBack else { return false }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            cancelPendingBackTextureBlit()
            return false
        }

        let sourceOrigin: MTLOrigin
        let sourceSize: MTLSize
        let destinationOrigin: MTLOrigin
        if pendingBlitWasRecreate || pendingBlitRect == nil {
            sourceOrigin = MTLOrigin(x: 0, y: 0, z: 0)
            sourceSize = MTLSize(width: front.width, height: front.height, depth: 1)
            destinationOrigin = MTLOrigin(x: 0, y: 0, z: 0)
        } else {
            let rect = pendingBlitRect!
            sourceOrigin = MTLOrigin(x: rect.x, y: rect.y, z: 0)
            sourceSize = MTLSize(width: rect.width, height: rect.height, depth: 1)
            destinationOrigin = MTLOrigin(x: rect.x, y: rect.y, z: 0)
        }
        blit.copy(from: front, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: sourceOrigin,
                  sourceSize: sourceSize,
                  to: back, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: destinationOrigin)
        blit.endEncoding()

        cancelPendingBackTextureBlit()
        return true
    }

    /// Called after blit command buffer completes successfully.
    func markBackSynced() {
        os_unfair_lock_lock(&mu)
        backDirty = false
        pendingBackSyncWasRecreate = false
        pendingBackSyncRect = nil
        os_unfair_lock_unlock(&mu)
    }

    /// Returns true if atlas has pending state that requires attention:
    /// - backDirty: front->back blit needed (requires commandBuffer)
    /// - needsAtlasRebuild: scale change pending (requires core invalidation)
    /// - atlasModified: uncommitted atlas changes exist
    func hasAtlasStateRequiringAttention() -> Bool {
        os_unfair_lock_lock(&mu)
        let result = backDirty || needsAtlasRebuild || atlasModified
        os_unfair_lock_unlock(&mu)
        return result
    }

    /// Returns true if needsAtlasRebuild is set (scale change not yet fully applied).
    /// Used specifically to detect recreateTexture failure in the scale-change path.
    var needsAtlasRebuildPending: Bool {
        os_unfair_lock_lock(&mu)
        let result = needsAtlasRebuild
        os_unfair_lock_unlock(&mu)
        return result
    }

    struct CommitResult {
        let texture: MTLTexture?
        let committed: Bool
    }

    /// Called from commitFlush() on core thread.
    /// If atlas was modified during this flush, swaps front/back and returns new front.
    /// If not modified, returns current front without swap.
    func commitAndSnapshotFrontTexture() -> CommitResult {
        // If this flush modified the atlas, a deferred back blit must complete
        // before back becomes front. Poll only: commitFlush runs with grid_mu
        // held and must abort/retry rather than waiting on the GPU.
        os_unfair_lock_lock(&mu)
        let wasModified = atlasModified
        os_unfair_lock_unlock(&mu)
        let blitResolution = wasModified ? pollPendingBackBlit() : .ready
        let blitOk = blitResolution == .ready
        var publishedFreshTexture = false
        os_unfair_lock_lock(&mu)
        if atlasModified {
            if !blitOk {
                // A terminal blit failure keeps both the old front and the
                // uncommitted modification for a later rebuild/retry.
            } else {
                // `resetAtlas_locked()` also sets flushHadRecreate while the
                // replacement slot is still nil. Only reopen readers when a
                // real fresh texture is about to become the committed front.
                publishedFreshTexture = flushHadRecreate && textures[1 - frontIndex] != nil
                pendingBackSyncWasRecreate = flushHadRecreate
                pendingBackSyncRect = flushDirtyRect
                frontIndex = 1 - frontIndex   // swap: back (with new content) becomes front
                backDirty = true              // old front (now back) is behind
                atlasModified = false
                flushHadRecreate = false
                flushDirtyRect = nil
            }
        }
        let tex = textures[frontIndex]
        os_unfair_lock_unlock(&mu)
        if publishedFreshTexture {
            // A failed upload can leave writer intent armed while the retry
            // rebuilds and commits an empty/background-only atlas. With no
            // upload or back-sync in that retry, there would otherwise be no
            // later beginAtlasWrite() call to clear the intent, permanently
            // rejecting every external reader despite the fresh publication.
            completeWriterIntentAfterFreshTexturePublication()
        } else if blitOk {
            // A retry can commit successfully without touching the atlas when
            // the glyph that triggered reader contention disappeared before
            // the retry. Do not treat the existing texture as fresh: keep the
            // gate closed until every reader admitted before the failed writer
            // has actually completed.
            completeWriterIntentAfterSuccessfulTransaction()
        }
        return CommitResult(texture: tex, committed: blitOk)
    }

    /// Returns the committed front texture under lock.
    func snapshotFrontTexture() -> MTLTexture? {
        os_unfair_lock_lock(&mu)
        let tex = textures[frontIndex]
        os_unfair_lock_unlock(&mu)
        return tex
    }

}
