import MetalKit

/// A surface's MTKView, seen only as something that can switch between the
/// continuous draw loop and on-demand drawing.
///
/// Both surfaces did this identically, and ExternalGridView's copy carried a
/// comment saying so ("as MetalTerminalView does it") — a coupling written
/// down but not enforced, so a change to one would have left the other behind.
protocol SurfaceDrawLoopHost: MTKView {
    /// How many consecutive frames this surface has had nothing to draw.
    /// Owned by the host because the two surfaces run different thresholds.
    var drawLoopIdleCounter: DrawLoopIdleCounter { get set }

    /// Named in the `[drawloop]` trace lines, so a capture says which surface
    /// switched mode.
    var drawLoopTraceName: String { get }
}

extension SurfaceDrawLoopHost {
    /// Put this surface into the continuous draw loop.
    ///
    /// `noteActive()` is OUTSIDE the `isPaused` test on purpose: a surface
    /// calls this every frame while a shader animates, an edge bounce settles
    /// or a scroll eases, and none of those is a commit, so `noteIdle`'s
    /// `hadRecentCommit` clause does not reset the run. Counting them as idle
    /// deactivated the loop every eleventh frame and the next call woke it
    /// again.
    ///
    /// The kick fires only on the paused -> active edge. MTKView's display
    /// link can wait one or two vsyncs after `isPaused` flips, which lets
    /// commits pile up into a multi-row jump on the first frame of a held-key
    /// scroll; calling it for every already-active commit would only enqueue
    /// redundant AppKit invalidations.
    func activateSurfaceDrawLoop() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.drawLoopIdleCounter.noteActive()
            guard self.isPaused else { return }
            ZonvieCore.appLogScrollMode(
                "[drawloop] activate: \(self.drawLoopTraceName) switching to continuous rendering"
            )
            self.isPaused = false
            self.enableSetNeedsDisplay = false
            self.setNeedsDisplay(self.bounds)
        }
    }

    /// Switch back to on-demand rendering (setNeedsDisplay-driven).
    func deactivateSurfaceDrawLoop() {
        guard !isPaused else { return }
        ZonvieCore.appLogScrollMode(
            "[drawloop] deactivate: \(drawLoopTraceName) switching to on-demand rendering"
                + " (idle=\(drawLoopIdleCounter.idleFrames))"
        )
        isPaused = true
        enableSetNeedsDisplay = true
    }
}
