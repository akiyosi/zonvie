import Foundation

/// Whether a surface's draw call has anything to do.
///
/// Both surfaces reached this question independently and each answered it with
/// its own ten-term boolean chain. The chains drifted: one calls its rows
/// `dirtyRows` and the other `submittedDirtyRows`; one carries a dirty RECT the
/// other never had; one latches smooth scrolling off the last DRAW, the other
/// off the last PRESENT; one demands row mode before it will skip and the other
/// settles that in an earlier gate. Reading either one told you nothing about
/// the other, and a term added to one never reached the second.
///
/// Every term below belongs to at least one surface. A surface with no such
/// state leaves it at its default, and every default is the value that cannot
/// block a skip — so a surface never pays for a concept it does not have.
///
/// Deliberately free of Metal, Foundation collections and app types: it is
/// compiled standalone by the `surface-draw-gate-tests` step, whose whole job
/// is to re-state both original expressions and check this one still agrees.
struct SurfaceIdleTerms {
    /// The surface has presented at least one frame. Skipping before that
    /// leaves the window blank, so this is the one term that must be TRUE for
    /// a skip; it defaults false so an uninitialised surface always draws.
    var hasPresentedOnce = false

    /// Row vertices are in use, so the per-row dirty set can be trusted to
    /// describe the whole frame. A surface still on whole-grid buffers has no
    /// such set and must not skip on it. The main surface settles the
    /// whole-grid case in an earlier gate and passes true here.
    var rowModeSatisfied = true

    /// Committed content this draw has not acknowledged (`commitRevision`).
    var hasNewCommit = false

    /// A cursor submit that has not been published yet. Distinct from
    /// `hasNewCommit`: it is set inside the flush bracket, before the commit
    /// that will carry it, and a draw that read and cleared it in between
    /// would otherwise leave the cursor on the old content.
    var hasCursorUpdate = false

    /// Rows this surface's own grid owes.
    var hasDirtyRows = false

    /// A damaged pixel rectangle that no row expresses.
    var hasDirtyRect = false

    /// A layer this surface hosts owes rows, a shift, or a full redraw.
    var hasLayerWork = false

    /// A row scroll staged but not yet consumed.
    var hasStagedScroll = false

    /// The sub-row scroll offset differs from the one the last presented frame
    /// was drawn with, so the same pixels would now land somewhere else.
    var scrollOffsetChanged = false

    /// A scroll offset is active, or was active on the frame before this one —
    /// the extra frame matters because the back buffer still holds pixels
    /// rendered at a non-zero offset.
    var isSmoothScrolling = false

    /// The cursor's blink phase flipped.
    var blinkStateChanged = false

    /// The drawable resized; the old frame would be stretched.
    var drawableSizeChanged = false

    /// A loaded custom shader reads a time-varying uniform, so the frame must
    /// be re-encoded even with nothing else to say.
    var shaderAnimates = false

    /// The cursor rect a custom shader draws against moved.
    ///
    /// It is an input to the FRAGMENT stage over the whole surface, so moving
    /// it changes pixels everywhere the chain runs — and it moves on frames
    /// with no dirty row, no layer work and no blink, because the rect is
    /// published at commit and folded into screen space at pre-draw. Without
    /// this term the gate skipped every frame after such a commit and the
    /// cursor effect stayed where it last happened to be encoded, for as long
    /// as nothing else asked for a frame.
    var shaderCursorMoved = false

    /// The decision and every term behind it, for `ZONVIE_DRAW_TRACE=1`.
    ///
    /// Built here rather than at the two call sites, which is where the field
    /// sets drifted apart: each surface printed only the terms it happened to
    /// have, so a line from one could not be read against a line from the
    /// other. Every term is printed by every surface now, including the ones it
    /// leaves at their defaults — a term that is structurally always 0 is
    /// itself a fact worth seeing in the trace.
    func traceLine(surface: Int64) -> String {
        "surface=\(surface) gate=idle"
            + " presented=\(hasPresentedOnce ? 1 : 0) rowMode=\(rowModeSatisfied ? 1 : 0)"
            + " newCommit=\(hasNewCommit ? 1 : 0) cursor=\(hasCursorUpdate ? 1 : 0)"
            + " dirty=\(hasDirtyRows ? 1 : 0) rect=\(hasDirtyRect ? 1 : 0)"
            + " layerWork=\(hasLayerWork ? 1 : 0) scroll=\(hasStagedScroll ? 1 : 0)"
            + " scrollOff=\(scrollOffsetChanged ? 1 : 0) smooth=\(isSmoothScrolling ? 1 : 0)"
            + " shaderCur=\(shaderCursorMoved ? 1 : 0)"
            + " blink=\(blinkStateChanged ? 1 : 0) sizeChg=\(drawableSizeChanged ? 1 : 0)"
            + " anim=\(shaderAnimates ? 1 : 0)"
            + " -> \(skipsFrame ? "skip" : "draw")"
    }

    /// True when nothing this surface tracks has changed, so no frame is
    /// encoded or presented.
    var skipsFrame: Bool {
        hasPresentedOnce
            && rowModeSatisfied
            && !hasNewCommit
            && !hasCursorUpdate
            && !hasDirtyRows
            && !hasDirtyRect
            && !hasLayerWork
            && !hasStagedScroll
            && !scrollOffsetChanged
            && !isSmoothScrolling
            && !blinkStateChanged
            && !drawableSizeChanged
            && !shaderAnimates
            && !shaderCursorMoved
    }
}

/// Whether a surface's render pass may `.load` the back texture it drew last
/// frame, or has to `.clear` and draw it all again.
///
/// `resolveSurfaceColorLoadAction` — the final mapping onto `MTLLoadAction` —
/// was already shared. What was not shared is the predicate that feeds it, and
/// that is where the two surfaces had drifted furthest: main computes one
/// expression, external computes four (`cursorOnlyFrame`, `reuseHostedContents`,
/// `reuseRootContents`, `partialHostedContents`) and then a fifth over them.
///
/// Laid side by side they turn out to be the same shape — external's is main's
/// with a prefix of guards main has no state for, and four extra arms. So the
/// union works here exactly as it does for `SurfaceIdleTerms`: every term, and
/// a surface that lacks one leaves it at the value that cannot change its own
/// answer.
///
/// One term needs its role spelled out, because its name would otherwise lie.
/// See `layersOutsideDirtySet`.
struct SurfaceLoadActionTerms {
    // MARK: guards — any one of these refuses reuse outright

    /// Additive bloom accumulates brightness over a loaded texture.
    var glowEnabled = false

    /// The committed rows were generated with the font metrics in force now.
    /// A surface with no font-generation gate has nothing to be stale about
    /// and passes the default.
    var fontIsCurrent = true

    /// The layout moved under this surface, so what the texture holds is in
    /// the wrong place. A surface that does not track layout damage separately
    /// passes the default.
    var hasLayoutDamage = false

    /// ext-cmdline and friends: their viewport origin offset means a partial
    /// redraw's scissor rects do not line up, so they always clear.
    var isDecoratedSurface = false

    /// This surface hosts layers whose contents are **not** represented in its
    /// own dirty-row set, so reuse is safe only if a hosted-specific arm below
    /// approved it.
    ///
    /// Not "this surface hosts layers". The main surface hosts them too, and
    /// folds their pending work into `hasDirtyRowsInRowMode` via `anyLayerWork`
    /// — its layers ARE in the dirty set, so it passes false and its answer is
    /// unchanged. Naming this after the layers rather than after the role is
    /// how a rule gets moved onto a surface where the same word means something
    /// else.
    var layersOutsideDirtySet = false

    // MARK: arms — any one of these permits reuse

    /// Only the cursor's blink phase changed, and the cursor is composited
    /// after the retained texture.
    var canBlinkFastPath = false

    /// The scroll is being served by a GPU blit of the texture being loaded.
    var useGpuScrollCopy = false

    /// Under blur, a dirty-only redraw is still safe because the two-pass
    /// background pass overwrites rather than blends, so alpha cannot build up.
    var canDirtyOnlyWithBlur = false

    /// Hosted layers are unchanged and nothing else moved.
    var reuseHostedContents = false

    /// The same, for a surface with no hosted layers at all.
    var reuseRootContents = false

    /// Hosted layers are unchanged but some rows are dirty, so the frame
    /// recomposes those bands over the loaded texture.
    var partialHostedContents = false

    /// A damaged pixel rectangle that no row expresses.
    var hasDirtyRect = false

    /// Row vertices are in use and something owes rows.
    var hasDirtyRowsInRowMode = false

    /// A scroll offset is active. Reuse of a texture drawn at a different
    /// offset would show the same pixels one row out.
    var isSmoothScrolling = false

    /// Every guard passes.
    private var guardsAllow: Bool {
        !glowEnabled && fontIsCurrent && !hasLayoutDamage && !isDecoratedSurface
    }

    /// The decision and every term behind it, for `ZONVIE_DRAW_TRACE=1`.
    /// One field set for both surfaces — see `SurfaceIdleTerms.traceLine`.
    func traceLine(surface: Int64) -> String {
        "surface=\(surface) gate=load"
            + " glow=\(glowEnabled ? 1 : 0) fontCurrent=\(fontIsCurrent ? 1 : 0)"
            + " layout=\(hasLayoutDamage ? 1 : 0) decorated=\(isDecoratedSurface ? 1 : 0)"
            + " layersOutside=\(layersOutsideDirtySet ? 1 : 0)"
            + " blinkFast=\(canBlinkFastPath ? 1 : 0) gpuScroll=\(useGpuScrollCopy ? 1 : 0)"
            + " dirtyBlur=\(canDirtyOnlyWithBlur ? 1 : 0)"
            + " reuseHosted=\(reuseHostedContents ? 1 : 0) reuseRoot=\(reuseRootContents ? 1 : 0)"
            + " partialHosted=\(partialHostedContents ? 1 : 0)"
            + " rect=\(hasDirtyRect ? 1 : 0) rowDirty=\(hasDirtyRowsInRowMode ? 1 : 0)"
            + " smooth=\(isSmoothScrolling ? 1 : 0)"
            + " -> reuse=\(reusesPreviousContents ? 1 : 0) force=\(forcesReusePreviousContents ? 1 : 0)"
    }

    /// `shouldReusePreviousContents`: reuse is permitted if blur does not
    /// intervene. `resolveSurfaceColorLoadAction` applies that last condition.
    var reusesPreviousContents: Bool {
        guardsAllow
            && (!layersOutsideDirtySet || reuseHostedContents || partialHostedContents)
            && (canBlinkFastPath
                || useGpuScrollCopy
                || canDirtyOnlyWithBlur
                || reuseHostedContents
                || reuseRootContents
                || partialHostedContents
                || (!isSmoothScrolling && (hasDirtyRect || hasDirtyRowsInRowMode)))
    }

    /// `forceReusePreviousContents`: reuse even under blur. Only the arms whose
    /// own pass overwrites what it loads, or which encode no surface pass at
    /// all, may say this.
    var forcesReusePreviousContents: Bool {
        guardsAllow
            && (canBlinkFastPath
                || useGpuScrollCopy
                || canDirtyOnlyWithBlur
                || reuseHostedContents
                || reuseRootContents)
    }
}

/// A surface's draw-loop idle accounting: how many consecutive frames produced
/// nothing, and when that means the loop should go back to on-demand drawing.
///
/// Both surfaces kept their own copy of this — the counter, the threshold, and
/// the three statements that move them — and one of them had since grown a
/// clause the other never got. The thresholds had drifted too (15 frames on the
/// main surface, 10 on an external one) with nothing on either side recording
/// why. One number now: the main surface's, the longer one, since stopping a
/// loop early mid-scroll stutters and running five frames longer costs a
/// quarter of a vsync-second of idle encoding.
struct DrawLoopIdleCounter {
    /// Consecutive frames that produced nothing.
    private(set) var idleFrames = 0

    /// How many of those are allowed before the loop stops.
    let threshold: Int

    static let surfaceThreshold = 15

    init(threshold: Int = DrawLoopIdleCounter.surfaceThreshold) {
        self.threshold = threshold
    }

    /// A frame rendered.
    mutating func noteActive() {
        idleFrames = 0
    }

    /// A frame produced nothing. Returns true when the draw loop should switch
    /// back to on-demand rendering.
    ///
    /// - Parameter hadRecentCommit: content was committed within the last few
    ///   vsync periods. The idle frame is then most likely a timing race — the
    ///   flush landed between this draw's snapshot and the next vsync — and
    ///   counting it deactivates the loop in the middle of a scroll, which
    ///   stutters.
    /// - Parameter heldActive: something outside this frame needs the loop as
    ///   its clock, such as a synthesized key repeat, so it may never stop on
    ///   frames that happen to have nothing to draw.
    mutating func noteIdle(hadRecentCommit: Bool, heldActive: Bool = false) -> Bool {
        if heldActive || hadRecentCommit {
            idleFrames = 0
            return false
        }
        idleFrames += 1
        return idleFrames > threshold
    }
}

/// Which rows a surface's own pass draws this frame.
///
/// The two ladders that chose this had the same skeleton — blur or not, then
/// the cursor row, a scroll, the dirty rows, or everything — and the same four
/// outcomes, but the conditions had drifted and neither could be read against
/// the other. This is the decision alone; the encoding stays where each surface
/// keeps its row resolution.
enum SurfaceRowPassPlan: Equatable {
    /// One row, scissored: the blink fast path erases and redraws the cursor's
    /// row and nothing else.
    case blinkFastPathRow

    /// The rows the frame marked dirty, each scissored to its own band.
    case dirtyRowsOnly

    /// The rows the frame marked dirty, plus the band a GPU scroll blit
    /// vacated, which holds no valid pixels after the shift.
    case dirtyRowsAfterScrollBlit

    /// Every row, including the ones a smooth scroll retains past the edge.
    case allRowsWithRetained

    /// Every row of the grid, with no retained rows and no scissor.
    case allRows
}

/// What a surface knows when it picks a row-pass plan.
///
/// Like the other two predicates here, a surface that has no such state leaves
/// the term at the value that cannot change its own answer, and two terms are
/// named for their ROLE rather than for the variable that usually fills them —
/// see `rootScrollBlitVacatedBand` and `hasDirtyRows`.
struct SurfaceRowPassTerms {
    /// Blur's two-pass background/glyph path is in use.
    var useTwoPass = false

    /// Only the cursor's blink phase changed and its row can be resolved.
    /// Both surfaces require `use2Pass` to set it, so it is only consulted
    /// inside that branch below — the non-blur ladder never had a blink arm on
    /// either side, and giving it one here would be unreachable code.
    var canBlinkFastPath = false

    /// A GPU blit already shifted **this pass's own target** for a scroll, so
    /// the band it vacated holds no valid pixels and must be repainted while
    /// the rest must not be.
    ///
    /// Not "a scroll blit happened". The main surface blits too, but for its
    /// *layers*, which its layer pass repaints on its own; its root is the
    /// `ext_multigrid` container and never scrolls, so it passes false and its
    /// answer is unchanged. Naming this after `useGpuScrollCopy` would have
    /// moved an external rule onto a root where it means something else.
    var rootScrollBlitVacatedBand = false

    /// A sub-row scroll offset is active, so every row lands somewhere new.
    var isSmoothScrolling = false

    /// Blur is on and a dirty-only redraw is still safe, because the two-pass
    /// background pass overwrites instead of blending.
    var canDirtyOnlyWithBlur = false

    /// The render pass loaded the back texture rather than clearing it. Without
    /// that, every row this frame does not draw would be blank.
    ///
    /// Only external tested this alongside `canDirtyOnlyWithBlur`. Main did
    /// not have to: its `canDirtyOnlyWithBlur` forces reuse, and itself
    /// requires `hasPresentedOnce && !drawableSizeChanged`, which is exactly
    /// what `resolveSurfaceColorLoadAction` needs to answer `.load`. So the
    /// conjunct is a no-op on main rather than a new condition.
    var loadedPreviousContents = false

    /// Something owes rows.
    ///
    /// On the main surface that includes a hosted layer owing work
    /// (`anyLayerWork`), because its layers are drawn from this same pass; an
    /// external surface expresses hosted work through its own dirty rows and
    /// passes just those.
    var hasDirtyRows = false

    /// Additive bloom needs the whole frame composited, so no partial redraw.
    var glowEnabled = false

    /// ext-cmdline and friends: their viewport origin offset means a partial
    /// redraw's scissor rects do not line up, so they redraw whole.
    var isDecoratedSurface = false

    /// The drawable resized; the back texture was cleared to match.
    var drawableSizeChanged = false

    var plan: SurfaceRowPassPlan {
        if useTwoPass {
            if canBlinkFastPath { return .blinkFastPathRow }
            if rootScrollBlitVacatedBand { return .dirtyRowsAfterScrollBlit }
            if canDirtyOnlyWithBlur && loadedPreviousContents { return .dirtyRowsOnly }
            return .allRowsWithRetained
        }
        if isSmoothScrolling { return .allRowsWithRetained }
        if rootScrollBlitVacatedBand { return .dirtyRowsAfterScrollBlit }
        if !isDecoratedSurface && !glowEnabled && hasDirtyRows
            && !drawableSizeChanged && loadedPreviousContents {
            return .dirtyRowsOnly
        }
        return .allRows
    }
}

/// Whether a surface is showing a sub-row scroll offset, and whether it was
/// showing one on the frame before.
///
/// Both surfaces tracked exactly this, as two Bools each under their own names
/// — `hasActiveScrollOffset`/`lastDrawnHadActiveScrollOffset` on one,
/// `scrollOffsetActive`/`lastPresentedScrollOffsetActive` on the other — and
/// each derived "smooth scrolling" from its own pair. Holding the concept once
/// is what makes the remaining difference legible: they latch at different
/// moments, which is a real question and is now asked in one place.
///
/// A struct of two Bools, stored inline. No allocation, no reference counting,
/// nothing added to a per-frame path.
struct SurfaceScrollOffsetLatch {
    /// An offset applies to the frame being built now.
    private(set) var isActive = false

    /// The frame this surface last committed to was drawn with one.
    private(set) var previousFrameWasActive = false

    mutating func setActive(_ active: Bool) {
        isActive = active
    }

    /// True for one frame past the offset reaching zero: the back buffer still
    /// holds pixels rendered at a non-zero offset, and blitting those again is
    /// a one-row jitter.
    var isSmoothScrolling: Bool {
        isActive || previousFrameWasActive
    }

    /// Record `activeThisFrame` as what the previous frame carried, returning
    /// what the latch held so a frame later abandoned can put it back.
    ///
    /// The caller passes the value rather than the latch reading `isActive`
    /// itself, because the two surfaces latch at different moments: one when a
    /// frame is committed to being drawn, the other when it is presented.
    @discardableResult
    mutating func latch(_ activeThisFrame: Bool) -> Bool {
        let previous = previousFrameWasActive
        previousFrameWasActive = activeThisFrame
        return previous
    }

    /// Undo a latch whose frame never reached the screen.
    mutating func restore(previousFrameWasActive previous: Bool) {
        previousFrameWasActive = previous
    }
}


/// Which grid this surface's one cursor belongs to, staged inside a flush
/// bracket and published by that bracket's commit.
///
/// A surface draws one cursor but many grids can own it, and a cursor CLEAR
/// arrives for whichever grid lost it rather than only for the one holding it —
/// so taking a clear from a grid that does not own the cursor erases one that is
/// still on screen. Both surfaces carried that guard, and both carried the same
/// bracket protocol around it: stage into pending, publish on commit, put
/// pending back from committed when a bracket is abandoned.
///
/// What each surface calls "no particular layer" differs and stays theirs. The
/// main surface's root IS grid 1, so it starts at 1 and never holds nil; an
/// external surface starts at nil, meaning nothing has been staged yet, which
/// is why `owns` compares the stored value rather than resolving a root — a nil
/// owner owns nothing, and on the main surface there is no nil to resolve.
///
/// The root row the core named for the cursor travels with the owner: -1
/// whenever a layer owns it, because a layer's cursor is in that grid's rows,
/// not the root's. Published with the owner so a frame's blink scissor names
/// the cursor it draws, not the one the next flush will. Both surfaces kept
/// this row beside the owner as two fields with the same bracket; one of them
/// forgot the -1 when the cursor entered a layer.
struct SurfaceCursorOwner {
    private(set) var staged: Int64?
    private(set) var committed: Int64?
    private(set) var stagedRootRow: Int = -1
    private(set) var committedRootRow: Int = -1

    init(initial: Int64?) {
        staged = initial
        committed = initial
    }

    /// Does the grid being submitted own the cursor this bracket has staged?
    func owns(_ gridId: Int64) -> Bool {
        staged == gridId
    }

    /// `rootRow` is the row a ROOT cursor sits on; a layer's cursor passes
    /// none.
    mutating func stage(_ gridId: Int64?, rootRow: Int = -1) {
        staged = gridId
        stagedRootRow = rootRow
    }

    /// Publish what the bracket staged.
    mutating func commit() {
        committed = staged
        committedRootRow = stagedRootRow
    }

    /// Put the staged owner back to what is on screen. A bracket that is
    /// abandoned must not leave a half-moved cursor staged, or the next
    /// bracket's clear from the true owner is dropped as coming from a
    /// non-owner and a cursor stays drawn where it no longer is.
    mutating func restoreStagedFromCommitted() {
        staged = committed
        stagedRootRow = committedRootRow
    }
}


/// The dimensions the committed vertices were baked for.
///
/// A surface's viewport has to match what the core generated NDC against, or
/// every row lands at the wrong height. Both surfaces published that pair at
/// commit and read it back at draw with a fallback to the live value — one in
/// drawable pixels, the other in grid rows and columns, which is why the fields
/// here are named for their role rather than their unit and each surface says
/// which it means at its own declaration.
///
/// The pair is published together, so it is all-or-nothing: a surface has
/// either committed both or neither. One surface tested both and the other
/// tested each separately, which is the same answer under that invariant —
/// stated once here, and the safer of the two if it were ever broken, because
/// a committed width beside a live height describes no frame that existed.
struct SurfaceCommittedExtent {
    private(set) var width: UInt32 = 0
    private(set) var height: UInt32 = 0

    mutating func commit(width: UInt32, height: UInt32) {
        self.width = width
        self.height = height
    }

    /// The committed pair, or the live one when nothing has been committed.
    func resolved(liveWidth: UInt32, liveHeight: UInt32) -> (width: UInt32, height: UInt32) {
        guard width > 0, height > 0 else { return (liveWidth, liveHeight) }
        return (width, height)
    }
}

/// The finger travel of one scroll event, in points, above which a precise
/// gesture is handed to discrete wheel scrolling.
///
/// Discrete scrolling books nothing and drops the sub-row compensation, so
/// every row it lands is a whole-row jump of the content — and of the cursor
/// with it, which a cursor shader draws as a trail. It exists so a gesture
/// faster than the lookahead can ask for rows does not run the picture past
/// what has arrived. The old cut-over was ONE row of travel per event, which
/// an ordinary flick crosses on most of its events: a real trackpad log
/// switched fifteen times in one session at 22 to 29 points. The bound the
/// lookahead actually has is what it may request per input — up to
/// `maxEventsPerInput` wheel events, each 'mousescroll' rows — so that is the
/// cut-over now. 'mousescroll' ver:0 disables mouse scrolling and never
/// reaches this; it still answers one row rather than zero.
func fastScrollThresholdPt(
    rowHeightPx: Double,
    rowsPerWheelEvent: Int,
    maxEventsPerInput: Int,
    scale: Double
) -> Double {
    let rows = max(1, rowsPerWheelEvent * maxEventsPerInput)
    return rowHeightPx * Double(rows) / scale
}

/// Settle a surface's frame-side scroll state against ITS OWN commit, and
/// take the hold its committed snapshot is read under. Returns with `lock`
/// held.
///
/// Three things describe one cursor on the glass — the committed rows, the
/// cursor rect the shader is handed, and the displacement that cancels a row
/// that just landed — and a frame must take all three from one commit. The
/// main surface serviced its scroll state in a hook just before its hold and
/// the external surface at the top of its draw; both left a window in which a
/// commit could land after the service and before the hold, so the frame drew
/// the new rows against the old displacement, one row step off. The external
/// surface's window was wider, and it also evaluated the shader rect late in
/// the frame, so that is where the step was seen. One rule now: service,
/// take the hold, and if the commit revision moved in between, service again.
/// Bounded so a commit storm cannot keep a frame from ever snapshotting.
func settleSurfaceAgainstOwnCommit(
    lock: NSLock,
    commitRevision: () -> UInt64,
    service: () -> Void,
    maxAttempts: Int = 3
) {
    var attempts = 0
    while true {
        lock.lock()
        let settled = commitRevision()
        lock.unlock()
        service()
        lock.lock()
        attempts += 1
        if commitRevision() == settled || attempts >= maxAttempts { return }
        lock.unlock()
    }
}

/// A surface's cursor blink phase, and what its last frame drew with.
///
/// Both surfaces kept the same two fields and the same lock-guarded accessor,
/// twelve identical lines each. The lock is passed in rather than owned: the
/// draw reads `visible` inside the same critical section as the rest of its
/// snapshot, and giving this its own lock would split that atomicity.
struct SurfaceBlinkState {
    /// Visible now — false while the blink hides the cursor. Written by the
    /// blink timer, read by the draw, both under the surface's lock.
    private var visible = true

    /// What the last frame this surface drew showed. Draw thread only.
    var lastRendered = true

    /// For a caller that already holds the lock.
    var visibleLocked: Bool {
        get { visible }
        set { visible = newValue }
    }

    func isVisible(lock: NSLock) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return visible
    }

    mutating func setVisible(_ newValue: Bool, lock: NSLock) {
        lock.lock()
        visible = newValue
        lock.unlock()
    }
}
