import Foundation

/// Fixed-capacity binary ring tracer for frame-timing investigation.
///
/// Every past scroll-jank run was limited by the fact that the measurement
/// itself perturbed the thing being measured: `appLog` formats a String per
/// event and writes it, which costs enough to move frame timings (see the
/// `perf_logging_self_pollution` finding). This tracer records plain POD
/// records into a preallocated ring with no allocation, no string formatting
/// and no I/O on the hot path, so it can stay enabled while the app runs at
/// full speed. The ring is converted to CSV only when explicitly dumped.
///
/// Enable with `ZONVIE_TRACE=1`. Dump with `kill -USR1 <pid>`; the CSV lands
/// at `ZONVIE_TRACE_PATH` (default `zonvie-frametrace.csv` in the cwd).
enum FrameTraceTag: UInt32 {
    case drawBegin = 1
    case drawEnd = 2
    case drawableAcquireBegin = 3
    case drawableAcquireEnd = 4
    case presentCall = 5
    case presented = 6
    case gpuComplete = 7
    case drawSkipSemaphore = 8
    case drawSkipNoDrawable = 9
    case drawSkipRowCapacity = 10
    case commitFlush = 11
    case inputSend = 12
    case encodeEnd = 13
    case gpuSubmit = 14
    /// a = dirty row count for this frame, b = 1 when rendering in row mode.
    /// Separates "one or two rows changed" (buffer j/k with the scroll fast
    /// path) from "the whole screen changed" (a TUI that repaints in full).
    case frameContent = 15
    /// A vsync arrived but the renderer found nothing new to present, so the
    /// frame was dropped. a = reason code (1 no vertices, 2 nothing changed,
    /// 3 row mode with no dirty rows, 4 blink-only with no cursor).
    case drawSkipNoChange = 16
    /// The frame waited for an in-flight commit rather than dropping itself.
    /// a = 1 when the commit arrived in time, 0 when the wait timed out.
    /// b = nanoseconds actually spent waiting.
    case commitGuardBand = 17
    /// How far the content actually moved in this frame. a = rowsDelta as a
    /// two's-complement bit pattern. A steady present cadence still looks
    /// uneven if the per-frame advance is not constant, so this is the
    /// separate question from whether a frame reached the glass at all.
    case scrollAdvance = 18
    /// Sub-row scroll ease applied for this frame. a = |offset| in milli-
    /// pixels, b = row height in milli-pixels. Visual position is
    /// content_rows * h - offset, so scrollAdvance alone stops describing
    /// perceived motion once the ease is on.
    case smoothScrollOffset = 19
    /// One precise (trackpad) scroll event. a = signed deltaY in millipixels,
    /// b = packed: bits 0-7 scrolls sent for it, 8-15 scrolls already pending,
    /// bit 16 edge blocked, bit 17 pushing into that edge. The gesture drives
    /// the offset itself, so neither scrollAdvance nor smoothScrollOffset
    /// describes what the picture did during one.
    case gestureScrollInput = 20
    /// Scroll offset handed to the shader for this frame. a = |offset| in
    /// millipixels (largest across the grids carrying one), b = row height in
    /// millipixels.
    case gestureScrollOffset = 21
    /// A grid_scroll reconciled against the offset. a = signed rows_delta the
    /// core reported, b = scrolls still in flight for that grid. seq = grid id.
    case gestureScrollClear = 22
    /// How a main-grid row scroll was carried. a = |rowsDelta| | path << 8,
    /// where path is 1 GPU copy, 2 CPU shift, 3 refused (not full width),
    /// 4 refused (degenerate range). b = colStart | colEnd << 16 |
    /// totalCols << 32. A grid_scroll with no event here never reached the
    /// row-scroll fast path at all — the core resent the rows instead.
    case mainRowScrollPath = 23
    /// Core flush callback bracket. These run on the core thread and include
    /// frontend admission, vertex generation, atlas work and publication.
    /// coreFlushEnd.a is 1 when the transaction was aborted, 0 when committed.
    case coreFlushBegin = 24
    case coreFlushEnd = 25
    /// Per-flush attribution for the bracket above. a = rasterize calls |
    /// upload calls << 20 | atlas recreations << 40 | main-grid rows submitted
    /// << 48. b = nanoseconds spent inside glyph rasterization. Distinguishes
    /// "the core regenerated the whole viewport" from "the frontend spent the
    /// budget rasterizing glyphs the atlas had thrown away".
    case coreFlushDetail = 26
    /// A frontend rejection that aborts an in-progress flush. a = 1 atlas
    /// upload deferred behind the reader gate, 2 atlas upload needs a rebuild,
    /// 3 atlas texture recreation failed, 4 on_flush_end refused to publish.
    /// Each of these costs a full-viewport resend on the retry, so their rate
    /// matters as much as the cost of the flush they interrupt.
    case flushRejected = 27
}

struct FrameTraceEvent {
    var tNs: UInt64
    var a: UInt64
    var b: UInt64
    var tag: UInt32
    var seq: UInt32
}

enum FrameTracer {
    /// 1 << 18 events ≈ 262k records ≈ 6 MB. At ~10 events/frame and 60 Hz
    /// that is roughly 7 minutes of continuous scrolling before wrap-around.
    private static let capacity = 1 << 18
    private static let mask = UInt64(capacity - 1)

    /// Read once at startup so the hot-path check is a plain Bool load.
    static let enabled: Bool = ProcessInfo.processInfo.environment["ZONVIE_TRACE"] == "1"

    private static var buffer: UnsafeMutablePointer<FrameTraceEvent>? = {
        guard enabled else { return nil }
        let p = UnsafeMutablePointer<FrameTraceEvent>.allocate(capacity: capacity)
        p.initialize(repeating: FrameTraceEvent(tNs: 0, a: 0, b: 0, tag: 0, seq: 0), count: capacity)
        return p
    }()

    /// Per-flush attribution accumulators. Written only from the core thread
    /// between one `coreFlushBegin` and its `coreFlushEnd`, and only while
    /// `enabled`, so they need no synchronization of their own.
    static var flushRasterCalls: UInt64 = 0
    static var flushRasterNs: UInt64 = 0
    static var flushUploadCalls: UInt64 = 0
    static var flushAtlasCreates: UInt64 = 0
    static var flushMainRows: UInt64 = 0

    @inline(__always)
    static func resetFlushCounters() {
        guard enabled else { return }
        flushRasterCalls = 0
        flushRasterNs = 0
        flushUploadCalls = 0
        flushAtlasCreates = 0
        flushMainRows = 0
    }

    @inline(__always)
    static func traceFlushCounters() {
        guard enabled else { return }
        let packed = (flushRasterCalls & 0xF_FFFF)
            | ((flushUploadCalls & 0xF_FFFF) << 20)
            | ((flushAtlasCreates & 0xFF) << 40)
            | ((flushMainRows & 0xFFFF) << 48)
        trace(.coreFlushDetail, a: packed, b: flushRasterNs)
    }

    private static var writeIndex: UInt64 = 0
    private static var indexLock = os_unfair_lock()
    private static var signalSource: DispatchSourceSignal?

    /// Monotonic timestamp shared with the rest of the app's perf plumbing
    /// (`CLOCK_UPTIME_RAW`, same base as `ZonvieCore`'s log prefix).
    @inline(__always)
    static func nowNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// Record one event. Safe to call from any thread. Costs an uncontended
    /// `os_unfair_lock` round trip plus a 32-byte store — no allocation, no
    /// formatting, no syscall.
    @inline(__always)
    static func trace(_ tag: FrameTraceTag, a: UInt64 = 0, b: UInt64 = 0, seq: UInt32 = 0, tNs: UInt64 = 0) {
        guard enabled, let buf = buffer else { return }
        let t = tNs != 0 ? tNs : nowNs()
        os_unfair_lock_lock(&indexLock)
        let i = writeIndex
        writeIndex &+= 1
        os_unfair_lock_unlock(&indexLock)
        buf[Int(i & mask)] = FrameTraceEvent(tNs: t, a: a, b: b, tag: tag.rawValue, seq: seq)
    }

    /// Install the SIGUSR1 dump handler. Called once during view setup.
    static func installDumpHandler() {
        guard enabled, signalSource == nil else { return }
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global(qos: .utility))
        src.setEventHandler { dump() }
        src.resume()
        signalSource = src
        NSLog("[frametrace] enabled: kill -USR1 \(ProcessInfo.processInfo.processIdentifier) to dump")
    }

    /// Snapshot the ring and write it out as CSV. Runs off the render path.
    static func dump() {
        guard enabled, let buf = buffer else { return }
        os_unfair_lock_lock(&indexLock)
        let total = writeIndex
        os_unfair_lock_unlock(&indexLock)

        let count = Int(min(total, UInt64(capacity)))
        let start = total > UInt64(capacity) ? total - UInt64(capacity) : 0

        var out = "t_ns,tag,seq,a,b\n"
        out.reserveCapacity(count * 48)
        for k in 0..<count {
            let e = buf[Int((start &+ UInt64(k)) & mask)]
            out += "\(e.tNs),\(e.tag),\(e.seq),\(e.a),\(e.b)\n"
        }

        let path = ProcessInfo.processInfo.environment["ZONVIE_TRACE_PATH"] ?? "zonvie-frametrace.csv"
        do {
            try out.write(toFile: path, atomically: true, encoding: .utf8)
            NSLog("[frametrace] wrote \(count) events to \(path)")
        } catch {
            NSLog("[frametrace] dump failed: \(error)")
        }
    }
}
