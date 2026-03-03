import AppKit

/// Shared helper for creating and managing the floating drag preview window
/// used by both TabBarView (titlebar mode) and TabSidebarView (sidebar mode)
/// during external tab drag operations.
final class TabDragPreviewHelper {

    private var previewWindow: NSWindow? = nil

    /// Create and show a floating preview window at the given screen point.
    func create(tabName: String, at screenPoint: NSPoint) {
        destroy()

        let previewWidth: CGFloat = 150
        let previewHeight: CGFloat = 30

        let window = NSWindow(
            contentRect: NSRect(
                x: screenPoint.x - previewWidth / 2,
                y: screenPoint.y - previewHeight / 2,
                width: previewWidth,
                height: previewHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        window.level = .floating
        window.hasShadow = true

        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 8
        window.contentView?.layer?.masksToBounds = true

        let displayName = tabName.isEmpty ? "[No Name]" : (tabName as NSString).lastPathComponent
        let label = NSTextField(labelWithString: displayName)
        label.frame = NSRect(x: 10, y: 5, width: previewWidth - 20, height: 20)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byTruncatingTail
        window.contentView?.addSubview(label)

        window.orderFront(nil)
        previewWindow = window
    }

    /// Update the preview window position to follow the cursor.
    func updatePosition(_ screenPoint: NSPoint) {
        guard let window = previewWindow else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: screenPoint.x - size.width / 2,
            y: screenPoint.y - size.height / 2
        ))
    }

    /// Destroy the preview window.
    func destroy() {
        previewWindow?.orderOut(nil)
        previewWindow = nil
    }

    /// Check if a screen point is outside the given view's bounds (with threshold).
    /// Returns true if the point is outside the expanded bounds.
    static func isOutsideBounds(
        of view: NSView,
        screenPoint: NSPoint,
        threshold: CGFloat
    ) -> Bool {
        guard let window = view.window else { return false }
        let boundsInWindow = view.convert(view.bounds, to: nil)
        let screenRect = window.convertToScreen(boundsInWindow)
        let expandedRect = screenRect.insetBy(dx: -threshold, dy: -threshold)
        return !expandedRect.contains(screenPoint)
    }
}
