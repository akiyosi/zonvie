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

    /// The frame carries a cursor move and nothing else.
    var isCursorOnlyFrame = false

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
            + " dirtyBlur=\(canDirtyOnlyWithBlur ? 1 : 0) cursorOnly=\(isCursorOnlyFrame ? 1 : 0)"
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
                || isCursorOnlyFrame
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
/// why, so each surface keeps its own number here and the divergence is at
/// least visible in one place now.
struct DrawLoopIdleCounter {
    /// Consecutive frames that produced nothing.
    private(set) var idleFrames = 0

    /// How many of those are allowed before the loop stops.
    let threshold: Int

    init(threshold: Int) {
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
