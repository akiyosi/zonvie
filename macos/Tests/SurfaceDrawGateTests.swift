// SurfaceIdleTerms must decide exactly what the two hand-written chains it
// replaced decided. Both originals are transcribed below, and every assignment
// of their terms is enumerated — 512 for the main surface, 1024 for an
// external one. Nothing here samples: if the shared predicate and an original
// disagree anywhere in the space, this fails and names the assignment.
//
// The originals are copies on purpose. They are the specification; if a future
// change to `skipsFrame` is intended, it has to be made twice, here as well,
// and that second edit is where someone notices the surface it would break.

import Foundation

@main
private enum SurfaceDrawGateTests {
    private static var failures = 0
    private static var skipSeen = 0
    private static var drawSeen = 0
    private static var forceSeen = 0
    private static var noForceSeen = 0

    private static func check(_ actual: Bool, _ expected: Bool, _ what: @autoclosure () -> String) {
        if actual { skipSeen += 1 } else { drawSeen += 1 }
        if actual != expected {
            failures += 1
            if failures <= 10 {
                print("FAIL \(what()): shared=\(actual) original=\(expected)")
            }
        }
    }

    private static func checkForce(_ actual: Bool, _ expected: Bool, _ what: @autoclosure () -> String) {
        if actual { forceSeen += 1 } else { noForceSeen += 1 }
        if actual != expected {
            failures += 1
            if failures <= 10 {
                print("FAIL \(what()): shared=\(actual) original=\(expected)")
            }
        }
    }

    /// Bit `i` of `mask`.
    private static func bit(_ mask: Int, _ i: Int) -> Bool { (mask >> i) & 1 == 1 }

    /// GridSurfaceRenderer.draw:
    ///
    ///     let idleGateSkips = hasPresentedOnceSnapshot
    ///         && !hasNewCommit && dirtyRectPxOpt == nil && dirtyRows.isEmpty
    ///         && !anyLayerWork && !smoothScrolling && !blinkStateChanged
    ///         && !drawableSizeChanged && !anyCustomShaderNeedsAnimation
    private static func verifyMainSurface() {
        for mask in 0..<(1 << 9) {
            let presented = bit(mask, 0)
            let newCommit = bit(mask, 1)
            let rect = bit(mask, 2)
            let dirty = bit(mask, 3)
            let layerWork = bit(mask, 4)
            let smooth = bit(mask, 5)
            let blink = bit(mask, 6)
            let sizeChg = bit(mask, 7)
            let anim = bit(mask, 8)

            let original = presented
                && !newCommit && !rect && !dirty
                && !layerWork && !smooth && !blink
                && !sizeChg && !anim

            let shared = SurfaceIdleTerms(
                hasPresentedOnce: presented,
                hasNewCommit: newCommit,
                hasDirtyRows: dirty,
                hasDirtyRect: rect,
                hasLayerWork: layerWork,
                isSmoothScrolling: smooth,
                blinkStateChanged: blink,
                drawableSizeChanged: sizeChg,
                shaderAnimates: anim
            ).skipsFrame

            check(shared, original, "main mask=\(mask)")
        }
    }

    /// ExternalGridView.draw:
    ///
    ///     let idleGateSkips = rowMode && hasPresentedOnce && !blinkStateChanged
    ///         && !hasDirtyContent && !hasPendingScroll && !drawableSizeChanged
    ///         && !scrollOffsetChanged && !hasCursorUpdate && !smoothScrolling
    ///         && !shaderAnimates
    ///
    /// `hasCursorUpdate` is itself `cursorDirtySnapshot || hasNewCommit`, so it
    /// is enumerated as its two independent sources: `!(a || b) == !a && !b`,
    /// which is the shape the shared predicate takes.
    private static func verifyExternalSurface() {
        for mask in 0..<(1 << 10) {
            let rowMode = bit(mask, 0)
            let presented = bit(mask, 1)
            let blink = bit(mask, 2)
            let dirty = bit(mask, 3)
            let pendingScroll = bit(mask, 4)
            let sizeChg = bit(mask, 5)
            let scrollOff = bit(mask, 6)
            let cursorDirty = bit(mask, 7)
            let newCommit = bit(mask, 8)
            let smooth = bit(mask, 9)

            let hasCursorUpdate = cursorDirty || newCommit
            let original = rowMode && presented && !blink
                && !dirty && !pendingScroll && !sizeChg
                && !scrollOff && !hasCursorUpdate && !smooth

            let shared = SurfaceIdleTerms(
                hasPresentedOnce: presented,
                rowModeSatisfied: rowMode,
                hasNewCommit: newCommit,
                hasCursorUpdate: cursorDirty,
                hasDirtyRows: dirty,
                hasStagedScroll: pendingScroll,
                scrollOffsetChanged: scrollOff,
                isSmoothScrolling: smooth,
                blinkStateChanged: blink,
                drawableSizeChanged: sizeChg
            ).skipsFrame

            check(shared, original, "external mask=\(mask)")
        }
    }

    /// GridSurfaceRenderer.draw:
    ///
    ///     let shouldReusePreviousContents = !glowEnabled
    ///         && (canBlinkFastPath || useGpuScrollCopy || canDirtyOnlyWithBlur
    ///             || (!smoothScrolling && (dirtyRectPxOpt != nil || hasAnyDirtyInRowMode)))
    ///     forceReusePreviousContents: !glowEnabled
    ///         && (canBlinkFastPath || useGpuScrollCopy || canDirtyOnlyWithBlur)
    private static func verifyMainLoadAction() {
        for mask in 0..<(1 << 7) {
            let glow = bit(mask, 0)
            let blinkFast = bit(mask, 1)
            let gpuScroll = bit(mask, 2)
            let dirtyBlur = bit(mask, 3)
            let smooth = bit(mask, 4)
            let rect = bit(mask, 5)
            let rowDirty = bit(mask, 6)

            let originalReuse = !glow
                && (blinkFast || gpuScroll || dirtyBlur
                    || (!smooth && (rect || rowDirty)))
            let originalForce = !glow && (blinkFast || gpuScroll || dirtyBlur)

            let terms = SurfaceLoadActionTerms(
                glowEnabled: glow,
                canBlinkFastPath: blinkFast,
                useGpuScrollCopy: gpuScroll,
                canDirtyOnlyWithBlur: dirtyBlur,
                hasDirtyRect: rect,
                hasDirtyRowsInRowMode: rowDirty,
                isSmoothScrolling: smooth
            )

            check(terms.reusesPreviousContents, originalReuse, "main load mask=\(mask)")
            checkForce(terms.forcesReusePreviousContents, originalForce, "main force mask=\(mask)")
        }
    }

    /// ExternalGridView.draw:
    ///
    ///     let shouldReusePreviousContents = committedFontIsCurrent
    ///         && !layoutDamageSnapshot
    ///         && (layerDrawSnapshot.isEmpty || reuseHostedContents || partialHostedContents)
    ///         && !isDecoratedSurface
    ///         && !glowEnabled
    ///         && (partialHostedContents || reuseHostedContents || reuseRootContents
    ///             || canBlinkFastPath || useGpuScrollCopy || cursorOnlyFrame
    ///             || canDirtyOnlyWithBlur || (!smoothScrolling && hasAnyDirtyInRowMode))
    ///     forceReusePreviousContents: committedFontIsCurrent && !layoutDamageSnapshot
    ///         && !isDecoratedSurface && !glowEnabled
    ///         && (reuseHostedContents || reuseRootContents || canBlinkFastPath
    ///             || useGpuScrollCopy || canDirtyOnlyWithBlur)
    ///
    /// `layerDrawSnapshot.isEmpty` is enumerated as `layersOutsideDirtySet`,
    /// the role that guard plays: hosted content this surface's dirty rows do
    /// not describe. It is NOT "hosts layers" — the main surface hosts them and
    /// passes false, because its layer work is inside its dirty-row term.
    private static func verifyExternalLoadAction() {
        for mask in 0..<(1 << 14) {
            let glow = bit(mask, 0)
            let fontCurrent = bit(mask, 1)
            let layoutDamage = bit(mask, 2)
            let decorated = bit(mask, 3)
            let hasLayers = bit(mask, 4)
            let blinkFast = bit(mask, 5)
            let gpuScroll = bit(mask, 6)
            let dirtyBlur = bit(mask, 7)
            let cursorOnly = bit(mask, 8)
            let reuseHosted = bit(mask, 9)
            let reuseRoot = bit(mask, 10)
            let partialHosted = bit(mask, 11)
            let smooth = bit(mask, 12)
            let rowDirty = bit(mask, 13)

            let originalReuse = fontCurrent
                && !layoutDamage
                && (!hasLayers || reuseHosted || partialHosted)
                && !decorated
                && !glow
                && (partialHosted || reuseHosted || reuseRoot
                    || blinkFast || gpuScroll || cursorOnly
                    || dirtyBlur || (!smooth && rowDirty))
            let originalForce = fontCurrent && !layoutDamage
                && !decorated && !glow
                && (reuseHosted || reuseRoot || blinkFast || gpuScroll || dirtyBlur)

            let terms = SurfaceLoadActionTerms(
                glowEnabled: glow,
                fontIsCurrent: fontCurrent,
                hasLayoutDamage: layoutDamage,
                isDecoratedSurface: decorated,
                layersOutsideDirtySet: hasLayers,
                canBlinkFastPath: blinkFast,
                useGpuScrollCopy: gpuScroll,
                canDirtyOnlyWithBlur: dirtyBlur,
                isCursorOnlyFrame: cursorOnly,
                reuseHostedContents: reuseHosted,
                reuseRootContents: reuseRoot,
                partialHostedContents: partialHosted,
                hasDirtyRowsInRowMode: rowDirty,
                isSmoothScrolling: smooth
            )

            check(terms.reusesPreviousContents, originalReuse, "external load mask=\(mask)")
            checkForce(terms.forcesReusePreviousContents, originalForce, "external force mask=\(mask)")
        }
    }

    /// The idle counter both surfaces now share. What each surface used to do
    /// inline, restated: a recent commit or a held clock resets the run; every
    /// other empty frame extends it; the loop stops one frame PAST the
    /// threshold, not on it.
    private static func verifyIdleCounter() {
        var c = DrawLoopIdleCounter(threshold: 3)

        // Below and at the threshold the loop keeps running.
        for i in 1...3 {
            if c.noteIdle(hadRecentCommit: false) {
                failures += 1
                print("FAIL: idle counter stopped the loop at frame \(i) of 3")
            }
        }
        // One past it, it stops.
        if !c.noteIdle(hadRecentCommit: false) {
            failures += 1
            print("FAIL: idle counter did not stop the loop past its threshold")
        }

        // A recent commit resets the run rather than extending it: the empty
        // frame is a timing race, and counting it deactivates mid-scroll.
        var r = DrawLoopIdleCounter(threshold: 3)
        _ = r.noteIdle(hadRecentCommit: false)
        _ = r.noteIdle(hadRecentCommit: false)
        _ = r.noteIdle(hadRecentCommit: true)
        if r.idleFrames != 0 {
            failures += 1
            print("FAIL: a recent commit left the run at \(r.idleFrames)")
        }
        for _ in 1...3 {
            if r.noteIdle(hadRecentCommit: false) {
                failures += 1
                print("FAIL: the run was not actually reset by the recent commit")
            }
        }

        // A held clock does the same, and outranks the absence of a commit.
        var h = DrawLoopIdleCounter(threshold: 1)
        _ = h.noteIdle(hadRecentCommit: false)
        if h.noteIdle(hadRecentCommit: false, heldActive: true) {
            failures += 1
            print("FAIL: the loop stopped while something held it active")
        }
        if h.idleFrames != 0 {
            failures += 1
            print("FAIL: a held clock left the run at \(h.idleFrames)")
        }

        // A frame that rendered clears the run too.
        var a = DrawLoopIdleCounter(threshold: 1)
        _ = a.noteIdle(hadRecentCommit: false)
        a.noteActive()
        if a.idleFrames != 0 {
            failures += 1
            print("FAIL: a rendered frame left the run at \(a.idleFrames)")
        }
    }

    private static var planSeen: Set<String> = []
    private static var planChecks = 0

    private static func checkPlan(
        _ actual: SurfaceRowPassPlan,
        _ expected: SurfaceRowPassPlan,
        _ what: @autoclosure () -> String
    ) {
        planSeen.insert("\(actual)")
        planChecks += 1
        if actual != expected {
            failures += 1
            if failures <= 10 {
                print("FAIL \(what()): shared=\(actual) original=\(expected)")
            }
        }
    }

    /// GridSurfaceRenderer.draw's row ladder:
    ///
    ///     if use2Pass {
    ///         if canBlinkFastPath            -> the cursor's row, scissored
    ///         else if canDirtyOnlyWithBlur   -> dirty rows, banded, 2-pass
    ///         else                           -> smoothRowRange, 2-pass
    ///     } else if smoothScrolling          -> smoothRowRange, 1-pass
    ///     else if !glowEnabled && (!dirtyRows.isEmpty || anyLayerWork)
    ///             && !drawableSizeChanged && loadAction == .load
    ///                                        -> dirty rows, scissored
    ///     else                               -> 0..<safeRowCount
    ///
    /// The main surface has no root scroll blit — grid 1 is the ext_multigrid
    /// container — so that term is false throughout, and `canBlinkFastPath`
    /// itself requires `use2Pass`, so it is enumerated only where it can occur.
    private static func verifyMainRowPass() {
        for mask in 0..<(1 << 8) {
            let use2Pass = bit(mask, 0)
            let blinkFast = bit(mask, 1) && use2Pass
            let dirtyBlur = bit(mask, 2)
            let smooth = bit(mask, 3)
            let glow = bit(mask, 4)
            let rowDirty = bit(mask, 5)
            let sizeChg = bit(mask, 6)
            let loaded = bit(mask, 7)

            let original: SurfaceRowPassPlan
            if use2Pass {
                if blinkFast {
                    original = .blinkFastPathRow
                } else if dirtyBlur && loaded {
                    // On this surface canDirtyOnlyWithBlur implies .load; the
                    // conjunct is stated so the two ladders read alike.
                    original = .dirtyRowsOnly
                } else {
                    original = .allRowsWithRetained
                }
            } else if smooth {
                original = .allRowsWithRetained
            } else if !glow && rowDirty && !sizeChg && loaded {
                original = .dirtyRowsOnly
            } else {
                original = .allRows
            }

            let shared = SurfaceRowPassTerms(
                useTwoPass: use2Pass,
                canBlinkFastPath: blinkFast,
                isSmoothScrolling: smooth,
                canDirtyOnlyWithBlur: dirtyBlur,
                loadedPreviousContents: loaded,
                hasDirtyRows: rowDirty,
                glowEnabled: glow,
                drawableSizeChanged: sizeChg
            ).plan

            checkPlan(shared, original, "main row pass mask=\(mask)")
        }
    }

    /// ExternalGridView.draw's row ladder:
    ///
    ///     if use2Pass {
    ///         if canBlinkFastPath                          -> the cursor's row
    ///         else if useGpuScrollCopy                     -> vacated band + dirty
    ///         else if canDirtyOnlyWithBlur && load == .load -> dirty rows
    ///         else                                         -> smoothRowRange
    ///     } else if smoothScrolling                        -> smoothRowRange
    ///     else if useGpuScrollCopy                         -> vacated band + dirty
    ///     else if !isDecoratedSurface && !glowEnabled && !dirtyRows.isEmpty
    ///             && !drawableSizeChanged && load == .load -> dirty rows
    ///     else                                             -> 0..<safeRowCount
    private static func verifyExternalRowPass() {
        for mask in 0..<(1 << 9) {
            let use2Pass = bit(mask, 0)
            let blinkFast = bit(mask, 1) && use2Pass
            let gpuScroll = bit(mask, 2)
            let dirtyBlur = bit(mask, 3)
            let smooth = bit(mask, 4)
            let glow = bit(mask, 5)
            let rowDirty = bit(mask, 6)
            let sizeChg = bit(mask, 7)
            let loaded = bit(mask, 8)
            // Decorated surfaces always clear, so `loaded` is false for them;
            // enumerating the pair independently would assert on states that
            // cannot occur. Both are enumerated, tied the way the surface ties
            // them.
            let decorated = !loaded && bit(mask, 2)

            let original: SurfaceRowPassPlan
            if use2Pass {
                if blinkFast {
                    original = .blinkFastPathRow
                } else if gpuScroll {
                    original = .dirtyRowsAfterScrollBlit
                } else if dirtyBlur && loaded {
                    original = .dirtyRowsOnly
                } else {
                    original = .allRowsWithRetained
                }
            } else if smooth {
                original = .allRowsWithRetained
            } else if gpuScroll {
                original = .dirtyRowsAfterScrollBlit
            } else if !decorated && !glow && rowDirty && !sizeChg && loaded {
                original = .dirtyRowsOnly
            } else {
                original = .allRows
            }

            let shared = SurfaceRowPassTerms(
                useTwoPass: use2Pass,
                canBlinkFastPath: blinkFast,
                rootScrollBlitVacatedBand: gpuScroll,
                isSmoothScrolling: smooth,
                canDirtyOnlyWithBlur: dirtyBlur,
                loadedPreviousContents: loaded,
                hasDirtyRows: rowDirty,
                glowEnabled: glow,
                isDecoratedSurface: decorated,
                drawableSizeChanged: sizeChg
            ).plan

            checkPlan(shared, original, "external row pass mask=\(mask)")
        }
    }

    /// The scroll-offset latch both surfaces now share, against the two pairs
    /// of Bools it replaced.
    ///
    ///     main     smoothScrolling = hasActiveScrollOffset
    ///                                  || lastDrawnHadActiveScrollOffset
    ///     external smoothScrolling = scrollOffsetActive
    ///                                  || lastPresentedScrollOffsetActive
    ///
    /// The same expression under two sets of names, so one enumeration covers
    /// both: every assignment of (active now, active on the previous frame),
    /// and every latch-then-restore round trip — what a frame that is encoded
    /// and then abandoned does.
    private static func verifyScrollOffsetLatch() {
        for activeNow in [false, true] {
            for previous in [false, true] {
                var latch = SurfaceScrollOffsetLatch()
                latch.setActive(previous)
                latch.latch(previous)
                latch.setActive(activeNow)

                check(latch.isSmoothScrolling, activeNow || previous,
                      "latch smooth active=\(activeNow) previous=\(previous)")

                // A latch hands back what it displaced, and restoring it puts
                // the pair back exactly: an abandoned frame must leave no
                // trace, or the next one reads the wrong previous frame.
                var abandoned = latch
                let displaced = abandoned.latch(activeNow)
                if displaced != previous {
                    failures += 1
                    print("FAIL: latch returned \(displaced), expected \(previous)")
                }
                abandoned.restore(previousFrameWasActive: displaced)
                if abandoned.previousFrameWasActive != latch.previousFrameWasActive
                    || abandoned.isActive != latch.isActive
                {
                    failures += 1
                    print("FAIL: restore did not undo the latch")
                }

                // A latch that is kept moves the pair forward instead.
                var kept = latch
                kept.latch(activeNow)
                if kept.previousFrameWasActive != activeNow {
                    failures += 1
                    print("FAIL: a kept latch did not record this frame")
                }
            }
        }
    }

    /// The cursor owner both surfaces now share, against the bracket protocol
    /// each of them wrote out.
    ///
    ///     stage      pendingCursorGridId = id
    ///     commit     committedCursorGridId = pendingCursorGridId
    ///     abandon    pendingCursorGridId = committedCursorGridId
    ///     guard      count != 0 || pendingCursorGridId == id
    ///
    /// The guard is what this is really protecting: a cursor CLEAR arrives for
    /// whichever grid lost the cursor, so accepting one from a grid that does
    /// not own it erases a cursor still on screen. Every ordering of stage,
    /// commit and abandon over a set of owners is enumerated, including the two
    /// roots the surfaces start from — 1 for main, nil for external.
    private static func verifyCursorOwner() {
        let owners: [Int64?] = [nil, 1, 4, 7]
        for initial in owners {
            for first in owners {
                for second in owners {
                    // Stage, then commit: both halves become the staged owner
                    // and only that owner may clear.
                    var committing = SurfaceCursorOwner(initial: initial)
                    committing.stage(first)
                    committing.commit()
                    committing.stage(second)
                    for probe in owners {
                        guard let probe else { continue }
                        check(committing.owns(probe), second == probe,
                              "owns after stage init=\(String(describing: initial))"
                                + " staged=\(String(describing: second)) probe=\(probe)")
                    }

                    // Stage, then abandon: the staged owner goes back to what
                    // is on screen, which is the committed one.
                    var abandoning = SurfaceCursorOwner(initial: initial)
                    abandoning.stage(first)
                    abandoning.commit()
                    abandoning.stage(second)
                    abandoning.restoreStagedFromCommitted()
                    if abandoning.staged != first {
                        failures += 1
                        print("FAIL: an abandoned bracket left"
                            + " \(String(describing: abandoning.staged)) staged,"
                            + " expected \(String(describing: first))")
                    }
                    if abandoning.committed != first {
                        failures += 1
                        print("FAIL: abandoning moved what is on screen")
                    }
                }
            }
        }

        // A nil start owns nothing at all — the case that drops a clear
        // arriving before any cursor has been staged.
        let fresh = SurfaceCursorOwner(initial: nil)
        for probe in Int64(0)...Int64(8) where fresh.owns(probe) {
            failures += 1
            print("FAIL: a nil owner claimed grid \(probe)")
        }
        let rooted = SurfaceCursorOwner(initial: 1)
        if !rooted.owns(1) || rooted.owns(2) {
            failures += 1
            print("FAIL: a rooted owner does not own exactly its root")
        }
    }

    static func main() {
        verifyMainSurface()
        verifyCursorOwner()
        verifyScrollOffsetLatch()
        verifyExternalSurface()
        verifyMainLoadAction()
        verifyExternalLoadAction()
        verifyIdleCounter()
        verifyMainRowPass()
        verifyExternalRowPass()

        // A term a surface does not have must never block its skip. The main
        // surface has no staged scroll, no scroll-offset latch and no cursor
        // flag; an external one has no dirty rect and no per-layer work.
        // Leaving those at their defaults has to read as "nothing pending", or
        // a surface would pay for a concept it does not implement.
        if !SurfaceIdleTerms(hasPresentedOnce: true).skipsFrame {
            failures += 1
            print("FAIL: a surface with nothing but a presented frame does not skip")
        }

        // Both outcomes must actually occur, or the loops assert nothing.
        // Every plan the enum can name must actually be produced, or an arm
        // above is unreachable and asserts nothing.
        if planSeen.count != 5 {
            failures += 1
            print("FAIL: only \(planSeen.count) of 5 row-pass plans occurred: \(planSeen.sorted())")
        }
        if skipSeen == 0 || drawSeen == 0 || forceSeen == 0 || noForceSeen == 0 {
            failures += 1
            print("FAIL: the enumeration produced skip=\(skipSeen) draw=\(drawSeen)"
                + " force=\(forceSeen) noForce=\(noForceSeen)")
        }

        if failures != 0 {
            print("surface draw gate: \(failures) failure(s)")
            exit(1)
        }
        print("surface draw gate: \(skipSeen + drawSeen) idle+reuse, \(forceSeen + noForceSeen)"
            + " force and \(planChecks) row-pass assignments agree"
            + " (all \(planSeen.count) plans produced)")
    }
}
