import Cocoa
import MetalKit

// MARK: - Protocols

/// Provides a snapshot texture for workspace tile thumbnails.
protocol SnapshotCapturing: AnyObject {
    func captureSnapshot() -> MTLTexture?
}

/// Delegate for workspace overlay actions.
protocol WorkspaceOverlayDelegate: AnyObject {
    /// Called when a tile is clicked in the overlay.
    func overlayDidSelectTile(at index: Int)
    /// Called when the "+" button on an empty tile is clicked.
    func overlayDidRequestNewTile(at index: Int)
    /// Called when the close button on an occupied tile is clicked.
    func overlayDidRequestCloseTile(at index: Int)
    /// Called when Esc is pressed to return to the active session.
    func overlayDidRequestDismiss()
    /// The view that should become first responder when the overlay is dismissed.
    func overlayFirstResponderOnDismiss() -> NSView?
    /// Called when entering tile view (zoom-out begins from fullscreen).
    /// Use this to hide external windows, etc.
    func overlayWillEnterTileView()
    /// Called when tile view is fully dismissed (scale reached 1.0).
    /// Use this to restore external windows, etc.
    func overlayDidExitTileView()
}

// MARK: - WorkspaceOverlayController

/// Manages a `WorkspaceOverlayView` on a host view: pinch gesture,
/// scale animation, and overlay visibility. Shared between the main
/// window and external windows to avoid duplicate logic.
final class WorkspaceOverlayController {

    // MARK: - Properties

    private weak var hostView: NSView?
    private weak var workspaceManager: WorkspaceManager?
    private weak var snapshotSource: (any SnapshotCapturing)?
    private weak var delegate: (any WorkspaceOverlayDelegate)?

    private var overlay: WorkspaceOverlayView?
    private var overlayRedrawTimer: Timer?
    private var pinchGesture: NSMagnificationGestureRecognizer?

    // Animation state — only the controller that initiates animation
    // drives the timer. Others react to workspaceScaleNotification.
    private var scaleAnimationTimer: Timer?
    private var scaleAnimationTarget: CGFloat = 1.0
    private var scaleAnimationCompletion: (() -> Void)?
    private var pinchBaseScale: CGFloat = 1.0
    /// True while the tile view is shown (scale < 1.0).
    /// Used to fire overlayWillEnterTileView/overlayDidExitTileView exactly once.
    private var isTileViewActive: Bool = false

    private var workspaceScaleObserver: Any?

    // MARK: - Init

    init(hostView: NSView,
         workspaceManager: WorkspaceManager,
         snapshotSource: (any SnapshotCapturing)?,
         delegate: (any WorkspaceOverlayDelegate)?) {
        self.hostView = hostView
        self.workspaceManager = workspaceManager
        self.snapshotSource = snapshotSource
        self.delegate = delegate

        setupOverlay()
        installPinchGesture()
        observeScaleChanges()
    }

    // MARK: - Setup

    private func setupOverlay() {
        guard let hostView = hostView else { return }

        let overlay = WorkspaceOverlayView(frame: hostView.bounds)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.workspaceManager = workspaceManager
        overlay.isHidden = true
        overlay.alphaValue = 0

        overlay.onTileSelected = { [weak self] index in
            self?.delegate?.overlayDidSelectTile(at: index)
        }

        overlay.onNewTileRequested = { [weak self] index in
            self?.delegate?.overlayDidRequestNewTile(at: index)
        }

        overlay.onTileCloseRequested = { [weak self] index in
            self?.delegate?.overlayDidRequestCloseTile(at: index)
        }

        overlay.onEscapePressed = { [weak self] in
            self?.delegate?.overlayDidRequestDismiss()
        }

        hostView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: hostView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])

        self.overlay = overlay
    }

    private func installPinchGesture() {
        guard let hostView = hostView else { return }
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        hostView.addGestureRecognizer(pinch)
        self.pinchGesture = pinch
    }

    private func observeScaleChanges() {
        workspaceScaleObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.workspaceScaleNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateOverlay()
        }
    }

    // MARK: - Public API

    /// Animate from tile grid view to fullscreen for the active tile.
    func animateToFullscreen() {
        startScaleAnimation(target: 1.0)
    }

    /// Animate from fullscreen to tile grid view.
    func animateToTileGrid() {
        guard let wm = workspaceManager else { return }
        // Capture snapshot only if the active tile still has a running core
        if wm.activeTile.isOccupied {
            captureCurrentSnapshot()
        }
        startScaleAnimation(target: 0.0)
    }

    /// Reset the overlay pan offset (e.g. before animating to fullscreen).
    func resetPanOffset() {
        overlay?.panOffset = .zero
    }

    /// Mark the overlay as needing redisplay.
    func setNeedsDisplay() {
        overlay?.needsDisplay = true
    }

    /// Clean up timers, observers, and views.
    func teardown() {
        scaleAnimationTimer?.invalidate()
        scaleAnimationTimer = nil
        overlayRedrawTimer?.invalidate()
        overlayRedrawTimer = nil

        if let observer = workspaceScaleObserver {
            NotificationCenter.default.removeObserver(observer)
            workspaceScaleObserver = nil
        }

        if let gesture = pinchGesture, let host = hostView {
            host.removeGestureRecognizer(gesture)
        }
        pinchGesture = nil

        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// Stop animation timer (e.g. on viewDidAppear restore).
    func invalidateAnimation() {
        scaleAnimationTimer?.invalidate()
        scaleAnimationTimer = nil
    }

    deinit {
        teardown()
    }

    // MARK: - Pinch Gesture

    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        guard let wm = workspaceManager else { return }

        switch gesture.state {
        case .began:
            ZonvieCore.appLog("[Workspace] handlePinch began: baseScale=\(wm.scale) activeIndex=\(wm.activeTileIndex) activeOccupied=\(wm.activeTile.isOccupied)")
            // Stop any running animation
            scaleAnimationTimer?.invalidate()
            scaleAnimationTimer = nil
            pinchBaseScale = wm.scale
            // Capture snapshot on first zoom-out from fullscreen (only if core is running)
            if pinchBaseScale >= 1.0 && wm.activeTile.isOccupied {
                captureCurrentSnapshot()
            }

        case .changed:
            let newScale = pinchBaseScale + gesture.magnification * 1.5

            if pinchBaseScale >= 1.0 {
                // From fullscreen: only allow zoom-out (entering tile view)
                wm.scale = min(pinchBaseScale, newScale)
            } else {
                // Already in tile view: free zoom in/out, but cap below 1.0
                // so user can't pinch back to fullscreen (must click a tile)
                wm.scale = min(0.95, newScale)
            }
            updateOverlay()

        case .ended, .cancelled:
            ZonvieCore.appLog("[Workspace] handlePinch ended: finalScale=\(wm.scale) baseScale=\(pinchBaseScale)")
            if pinchBaseScale >= 1.0 && wm.scale >= 0.95 {
                // Was at fullscreen and barely moved — snap back
                startScaleAnimation(target: 1.0)
            }
            // Otherwise keep the current scale (user stays in tile view)

        default:
            break
        }
    }

    // MARK: - Overlay Visibility

    /// Update overlay visibility and opacity based on current scale.
    private func updateOverlay() {
        guard let overlay = overlay, let wm = workspaceManager else { return }
        let scale = wm.scale

        if scale >= 1.0 {
            // Fullscreen — hide overlay, stop redraw timer
            if !overlay.isHidden {
                ZonvieCore.appLog("[Workspace] updateOverlay: transition to fullscreen (hiding overlay)")
                overlay.isHidden = true
                overlay.alphaValue = 0
                overlayRedrawTimer?.invalidate()
                overlayRedrawTimer = nil
                // Return focus to the delegate-specified view
                if let responder = delegate?.overlayFirstResponderOnDismiss() {
                    ZonvieCore.appLog("[Workspace] updateOverlay: makeFirstResponder(\(type(of: responder)))")
                    hostView?.window?.makeFirstResponder(responder)
                }
            }
            // Notify delegate exactly once on transition back to fullscreen
            if isTileViewActive {
                isTileViewActive = false
                delegate?.overlayDidExitTileView()
            }
            return
        }

        // Notify delegate exactly once on transition from fullscreen to tile view
        if !isTileViewActive {
            ZonvieCore.appLog("[Workspace] updateOverlay: transition to tile view (scale=\(scale))")
            isTileViewActive = true
            delegate?.overlayWillEnterTileView()
        }

        // Show overlay with opacity proportional to zoom-out amount.
        let fadeRange: CGFloat = 0.25
        let overlayAlpha = min(1.0, (1.0 - scale) / fadeRange)

        // Start periodic overlay redraw for live tile renderer textures
        if overlayRedrawTimer == nil {
            overlayRedrawTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.overlay?.needsDisplay = true
            }
        }

        overlay.isHidden = false
        overlay.alphaValue = overlayAlpha
        overlay.needsDisplay = true

        // Make overlay first responder so it receives key events (Esc)
        if hostView?.window?.firstResponder !== overlay {
            hostView?.window?.makeFirstResponder(overlay)
        }
    }

    // MARK: - Scale Animation

    private func startScaleAnimation(target: CGFloat, completion: (() -> Void)? = nil) {
        let currentScale = workspaceManager?.scale ?? -1
        ZonvieCore.appLog("[Workspace] startScaleAnimation: \(currentScale) -> \(target)")
        scaleAnimationTimer?.invalidate()
        scaleAnimationTarget = target
        scaleAnimationCompletion = completion
        // ~60fps timer for smooth animation
        scaleAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self, let wm = self.workspaceManager else { timer.invalidate(); return }

            let speed: CGFloat = 4.0 // scale units per second
            let step = speed / 60.0

            if self.scaleAnimationTarget > wm.scale {
                wm.scale = min(self.scaleAnimationTarget, wm.scale + step)
            } else {
                wm.scale = max(self.scaleAnimationTarget, wm.scale - step)
            }
            self.updateOverlay()

            if abs(wm.scale - self.scaleAnimationTarget) < 0.01 {
                wm.scale = self.scaleAnimationTarget
                self.updateOverlay()
                timer.invalidate()
                self.scaleAnimationTimer = nil
                self.scaleAnimationCompletion?()
                self.scaleAnimationCompletion = nil
            }
        }
    }

    // MARK: - Snapshot

    private func captureCurrentSnapshot() {
        guard let wm = workspaceManager else { return }
        let texture = snapshotSource?.captureSnapshot()
        wm.setSnapshot(for: wm.activeTileIndex, texture: texture)
    }
}
