import AppKit

/// Sidebar view displaying Neovim tabs as a vertical list.
/// Colors are derived from the loaded Neovim colorscheme background.
/// When blur is enabled, the sidebar is transparent to let window blur show through.
final class TabSidebarView: NSView {

    struct Tab {
        let handle: Int64
        let name: String
        var isSelected: Bool
    }

    private var tabs: [Tab] = []
    private var currentTab: Int64 = 0
    private var hoveredTabIndex: Int? = nil
    private var hoveredCloseButton: Int? = nil
    private var hoveredNewTabButton: Bool = false

    // Whether the sidebar is on the right side of the window
    var isRightSide: Bool = false

    // Appearance constants
    private let tabRowHeight: CGFloat = 28
    private let tabPadding: CGFloat = 12
    private let closeButtonSize: CGFloat = 14
    private let newTabButtonHeight: CGFloat = 32
    private let separatorWidth: CGFloat = 1

    // Colorscheme-derived colors (updated via notification)
    private var bgR: CGFloat = 0.145
    private var bgG: CGFloat = 0.149
    private var bgB: CGFloat = 0.161
    private var fgR: CGFloat = 1.0
    private var fgG: CGFloat = 1.0
    private var fgB: CGFloat = 1.0

    // Whether the colorscheme background is dark (computed from luminance)
    private var isDarkBackground: Bool {
        let luminance = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB
        return luminance < 0.5
    }

    // Blur configuration
    private var blurEnabled: Bool { ZonvieConfig.shared.blurEnabled }
    private var bgAlpha: CGFloat { CGFloat(ZonvieConfig.shared.backgroundAlpha) }

    // MARK: - Colorscheme-derived colors

    // When blur is enabled, NSVisualEffectView behind the sidebar provides
    // the blur effect. The sidebar draws a subtle colorscheme tint over it.
    // When blur is disabled, the sidebar draws an opaque colorscheme-based background.

    private var sidebarBackgroundColor: NSColor {
        if blurEnabled {
            // Subtle tint over the blur effect
            return NSColor(red: bgR, green: bgG, blue: bgB, alpha: 0.25)
        }
        if isDarkBackground {
            return NSColor(red: bgR * 0.85, green: bgG * 0.85, blue: bgB * 0.85, alpha: 1.0)
        }
        let lighten: CGFloat = 0.03
        return NSColor(
            red: min(1, bgR + lighten), green: min(1, bgG + lighten), blue: min(1, bgB + lighten), alpha: 1.0
        )
    }

    private var tabSelectedColor: NSColor {
        if blurEnabled {
            return NSColor(red: bgR, green: bgG, blue: bgB, alpha: 0.4)
        }
        if isDarkBackground {
            let brighten: CGFloat = 0.06
            return NSColor(red: bgR + brighten, green: bgG + brighten, blue: bgB + brighten, alpha: 1.0)
        }
        let darken: CGFloat = 0.06
        return NSColor(
            red: max(0, bgR - darken), green: max(0, bgG - darken), blue: max(0, bgB - darken), alpha: 1.0
        )
    }

    private var tabHoverColor: NSColor {
        if blurEnabled {
            return NSColor(red: bgR, green: bgG, blue: bgB, alpha: 0.3)
        }
        if isDarkBackground {
            let brighten: CGFloat = 0.03
            return NSColor(red: bgR + brighten, green: bgG + brighten, blue: bgB + brighten, alpha: 1.0)
        }
        let darken: CGFloat = 0.03
        return NSColor(
            red: max(0, bgR - darken), green: max(0, bgG - darken), blue: max(0, bgB - darken), alpha: 1.0
        )
    }

    private var tabTextColor: NSColor {
        // Dimmed foreground color for unselected tabs
        if isDarkBackground {
            return NSColor(red: fgR * 0.6, green: fgG * 0.6, blue: fgB * 0.6, alpha: 1.0)
        }
        // For light bg, darken the fg slightly
        return NSColor(red: fgR * 0.5, green: fgG * 0.5, blue: fgB * 0.5, alpha: 1.0)
    }

    private var tabTextSelectedColor: NSColor {
        return NSColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0)
    }

    private var separatorColor: NSColor {
        if isDarkBackground {
            return NSColor(calibratedWhite: 1.0, alpha: 0.1)
        }
        return NSColor(calibratedWhite: 0.0, alpha: 0.1)
    }

    private var closeButtonColor: NSColor {
        return NSColor(red: fgR * 0.5, green: fgG * 0.5, blue: fgB * 0.5, alpha: 1.0)
    }

    private var closeButtonHighlightColor: NSColor {
        return NSColor(red: fgR * 0.8, green: fgG * 0.8, blue: fgB * 0.8, alpha: 1.0)
    }

    private var newTabTextColor: NSColor {
        return NSColor(red: fgR * 0.5, green: fgG * 0.5, blue: fgB * 0.5, alpha: 1.0)
    }

    // Callbacks
    var onTabSelected: ((Int64) -> Void)?
    var onTabClosed: ((Int64) -> Void)?
    var onNewTabRequested: (() -> Void)?
    var onTabExternalized: ((Int64, NSPoint) -> Void)?

    // Drag state for tab externalization
    private var draggingTabIndex: Int? = nil
    private var dragStartPoint: NSPoint = .zero
    private var isExternalDrag: Bool = false
    private var dragPreviewWindow: NSWindow? = nil
    private let dragThreshold: CGFloat = 5
    private let externalDragThreshold: CGFloat = 50

    // Tracking area for mouse hover
    private var trackingArea: NSTrackingArea?

    // Notification observer
    private var colorschemeObserver: Any?

    override var isFlipped: Bool { true }

    // When blur is enabled, the sidebar must be non-opaque so the
    // window-level CGSSetWindowBackgroundBlurRadius blur shows through
    // (same approach as MetalTerminalView).
    override var isOpaque: Bool { !blurEnabled }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        // Configure layer transparency for blur (same pattern as MetalTerminalView)
        if blurEnabled {
            self.layer?.isOpaque = false
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
        setupTrackingArea()
        observeColorschemeChanges()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-apply layer settings after window attachment
        // (layer may not exist during commonInit)
        if blurEnabled {
            self.layer?.isOpaque = false
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    deinit {
        if let observer = colorschemeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeColorschemeChanges() {
        colorschemeObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.colorschemeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            // 0xFFFFFFFF means "not set" — only update the color that is valid
            if let bgRGB = notification.userInfo?["bgRGB"] as? UInt32, bgRGB != 0xFFFF_FFFF {
                self.bgR = CGFloat((bgRGB >> 16) & 0xFF) / 255.0
                self.bgG = CGFloat((bgRGB >> 8) & 0xFF) / 255.0
                self.bgB = CGFloat(bgRGB & 0xFF) / 255.0
            }
            if let fgRGB = notification.userInfo?["fgRGB"] as? UInt32, fgRGB != 0xFFFF_FFFF {
                self.fgR = CGFloat((fgRGB >> 16) & 0xFF) / 255.0
                self.fgG = CGFloat((fgRGB >> 8) & 0xFF) / 255.0
                self.fgB = CGFloat(fgRGB & 0xFF) / 255.0
            }
            self.needsDisplay = true
        }
    }

    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Background fill.
        // When blur is enabled, use .fill() which writes alpha directly via .copy
        // compositing. The layer is non-opaque (like MetalTerminalView), so
        // Core Animation composites the semi-transparent pixels over the
        // window's CGSSetWindowBackgroundBlurRadius blur.
        sidebarBackgroundColor.setFill()
        bounds.fill()

        // Separator line on the edge adjacent to terminal
        separatorColor.setFill()
        if isRightSide {
            NSRect(x: 0, y: 0, width: separatorWidth, height: bounds.height).fill()
        } else {
            NSRect(x: bounds.maxX - separatorWidth, y: 0, width: separatorWidth, height: bounds.height).fill()
        }

        // Draw tab rows
        var y: CGFloat = 0
        for (index, tab) in tabs.enumerated() {
            let rowRect = NSRect(x: 0, y: y, width: bounds.width - separatorWidth, height: tabRowHeight)
            drawTabRow(tab, in: rowRect, index: index)
            y += tabRowHeight
        }

        // Draw "New Tab" button below tab list
        drawNewTabButton(at: y)
    }

    private func drawTabRow(_ tab: Tab, in rect: NSRect, index: Int) {
        let isSelected = tab.handle == currentTab
        let isHovered = hoveredTabIndex == index

        // Row background
        if isSelected {
            tabSelectedColor.setFill()
            rect.fill()
        } else if isHovered {
            tabHoverColor.setFill()
            rect.fill()
        }

        // Selection indicator (accent-colored bar on leading edge)
        if isSelected {
            NSColor.controlAccentColor.setFill()
            if isRightSide {
                NSRect(x: separatorWidth, y: rect.minY, width: 3, height: rect.height).fill()
            } else {
                NSRect(x: 0, y: rect.minY, width: 3, height: rect.height).fill()
            }
        }

        // Tab name
        let displayName = tab.name.isEmpty ? "[No Name]" : (tab.name as NSString).lastPathComponent
        let textColor = isSelected ? tabTextSelectedColor : tabTextColor
        let font = NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)

        let closeWidth: CGFloat = (isSelected || isHovered) ? closeButtonSize + 8 : 0
        let textX = isSelected ? tabPadding + 3 : tabPadding
        let textRect = NSRect(
            x: textX,
            y: rect.minY + (rect.height - 16) / 2,
            width: rect.width - textX - tabPadding - closeWidth,
            height: 16
        )

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        displayName.draw(in: textRect, withAttributes: attributes)

        // Close button (X) on hover or selected
        if isSelected || isHovered {
            let closeRect = NSRect(
                x: rect.maxX - closeButtonSize - 8,
                y: rect.midY - closeButtonSize / 2,
                width: closeButtonSize,
                height: closeButtonSize
            )
            drawCloseButton(in: closeRect, highlighted: hoveredCloseButton == index)
        }
    }

    private func drawCloseButton(in rect: NSRect, highlighted: Bool) {
        if highlighted {
            closeButtonHighlightColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        (highlighted ? closeButtonHighlightColor : closeButtonColor).setStroke()
        let path = NSBezierPath()
        let inset: CGFloat = 4
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawNewTabButton(at y: CGFloat) {
        let rect = NSRect(x: 0, y: y, width: bounds.width - separatorWidth, height: newTabButtonHeight)

        if hoveredNewTabButton {
            tabHoverColor.setFill()
            rect.fill()
        }

        // "+" icon
        let iconSize: CGFloat = 16
        let iconRect = NSRect(
            x: tabPadding,
            y: y + (newTabButtonHeight - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        newTabTextColor.setStroke()
        let path = NSBezierPath()
        let inset: CGFloat = 3
        path.move(to: NSPoint(x: iconRect.midX, y: iconRect.minY + inset))
        path.line(to: NSPoint(x: iconRect.midX, y: iconRect.maxY - inset))
        path.move(to: NSPoint(x: iconRect.minX + inset, y: iconRect.midY))
        path.line(to: NSPoint(x: iconRect.maxX - inset, y: iconRect.midY))
        path.lineWidth = 1.5
        path.stroke()

        // "New Tab" text
        let textAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: newTabTextColor,
            .font: NSFont.systemFont(ofSize: 11)
        ]
        let textRect = NSRect(
            x: tabPadding + iconSize + 6,
            y: y + (newTabButtonHeight - 14) / 2,
            width: bounds.width - tabPadding * 2 - iconSize - 6,
            height: 14
        )
        "New Tab".draw(in: textRect, withAttributes: textAttributes)
    }

    // MARK: - Hit Testing

    private func tabIndex(at point: NSPoint) -> Int? {
        guard !tabs.isEmpty else { return nil }
        for index in 0..<tabs.count {
            let rowRect = NSRect(x: 0, y: CGFloat(index) * tabRowHeight, width: bounds.width, height: tabRowHeight)
            if rowRect.contains(point) {
                return index
            }
        }
        return nil
    }

    private func isCloseButton(at point: NSPoint, tabIndex: Int) -> Bool {
        guard tabIndex < tabs.count else { return false }
        let rowRect = NSRect(x: 0, y: CGFloat(tabIndex) * tabRowHeight, width: bounds.width - separatorWidth, height: tabRowHeight)
        let closeRect = NSRect(
            x: rowRect.maxX - closeButtonSize - 8,
            y: rowRect.midY - closeButtonSize / 2,
            width: closeButtonSize,
            height: closeButtonSize
        )
        return closeRect.contains(point)
    }

    private func isNewTabButton(at point: NSPoint) -> Bool {
        let y = CGFloat(tabs.count) * tabRowHeight
        let rect = NSRect(x: 0, y: y, width: bounds.width, height: newTabButtonHeight)
        return rect.contains(point)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        if let index = tabIndex(at: location) {
            if isCloseButton(at: location, tabIndex: index) {
                trackCloseButtonClick(initialEvent: event, tabIndex: index)
            } else {
                trackTabDrag(initialEvent: event, tabIndex: index)
            }
        } else if isNewTabButton(at: location) {
            trackNewTabButtonClick(initialEvent: event)
        }
    }

    /// Track tab drag for externalization (drag outside sidebar to create external window)
    private func trackTabDrag(initialEvent: NSEvent, tabIndex: Int) {
        guard let window = self.window else { return }
        guard tabIndex < tabs.count else { return }

        let startLocation = convert(initialEvent.locationInWindow, from: nil)
        dragStartPoint = startLocation
        draggingTabIndex = tabIndex
        isExternalDrag = false
        var isDragging = true
        var hasMoved = false

        while isDragging {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                continue
            }

            let location = convert(event.locationInWindow, from: nil)
            let screenLocation = window.convertPoint(toScreen: event.locationInWindow)

            // Sidebar bounds in screen coordinates
            let sidebarBoundsInWindow = self.convert(self.bounds, to: nil)
            let sidebarScreenRect = window.convertToScreen(sidebarBoundsInWindow)
            let expandedRect = sidebarScreenRect.insetBy(dx: -externalDragThreshold, dy: -externalDragThreshold)
            let isOutsideSidebar = !expandedRect.contains(screenLocation)

            switch event.type {
            case .leftMouseDragged:
                let distance = hypot(location.x - dragStartPoint.x, location.y - dragStartPoint.y)
                if distance > dragThreshold { hasMoved = true }

                if hasMoved && isOutsideSidebar && !isExternalDrag {
                    isExternalDrag = true
                    createDragPreviewWindow(for: tabIndex, at: screenLocation)
                } else if hasMoved && !isOutsideSidebar && isExternalDrag {
                    isExternalDrag = false
                    destroyDragPreviewWindow()
                }

                if isExternalDrag {
                    updateDragPreviewPosition(screenLocation)
                }

            case .leftMouseUp:
                isDragging = false
                if isExternalDrag {
                    destroyDragPreviewWindow()
                    onTabExternalized?(tabs[tabIndex].handle, screenLocation)
                } else if !hasMoved {
                    onTabSelected?(tabs[tabIndex].handle)
                }
                draggingTabIndex = nil
                isExternalDrag = false

            default:
                break
            }
        }
    }

    // MARK: - External Drag Preview Window

    private func createDragPreviewWindow(for tabIndex: Int, at screenPoint: NSPoint) {
        guard tabIndex < tabs.count else { return }
        let tab = tabs[tabIndex]

        let previewWidth: CGFloat = 150
        let previewHeight: CGFloat = 30

        let previewWindow = NSWindow(
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
        previewWindow.isOpaque = false
        previewWindow.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        previewWindow.level = .floating
        previewWindow.hasShadow = true

        previewWindow.contentView?.wantsLayer = true
        previewWindow.contentView?.layer?.cornerRadius = 8
        previewWindow.contentView?.layer?.masksToBounds = true

        let displayName = tab.name.isEmpty ? "[No Name]" : (tab.name as NSString).lastPathComponent
        let label = NSTextField(labelWithString: displayName)
        label.frame = NSRect(x: 10, y: 5, width: previewWidth - 20, height: 20)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byTruncatingTail
        previewWindow.contentView?.addSubview(label)

        previewWindow.orderFront(nil)
        dragPreviewWindow = previewWindow
    }

    private func updateDragPreviewPosition(_ screenPoint: NSPoint) {
        guard let preview = dragPreviewWindow else { return }
        let previewSize = preview.frame.size
        preview.setFrameOrigin(NSPoint(
            x: screenPoint.x - previewSize.width / 2,
            y: screenPoint.y - previewSize.height / 2
        ))
    }

    private func destroyDragPreviewWindow() {
        dragPreviewWindow?.orderOut(nil)
        dragPreviewWindow = nil
    }

    private func trackCloseButtonClick(initialEvent: NSEvent, tabIndex: Int) {
        guard let window = self.window else { return }
        guard tabIndex < tabs.count else { return }

        let tab = tabs[tabIndex]
        var isTracking = true

        hoveredCloseButton = tabIndex
        needsDisplay = true

        while isTracking {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                continue
            }

            let location = convert(event.locationInWindow, from: nil)

            switch event.type {
            case .leftMouseDragged:
                let isStillOverClose = isCloseButton(at: location, tabIndex: tabIndex)
                if isStillOverClose != (hoveredCloseButton == tabIndex) {
                    hoveredCloseButton = isStillOverClose ? tabIndex : nil
                    needsDisplay = true
                }

            case .leftMouseUp:
                isTracking = false
                if isCloseButton(at: location, tabIndex: tabIndex) {
                    onTabClosed?(tab.handle)
                }
                hoveredCloseButton = nil
                needsDisplay = true

            default:
                break
            }
        }
    }

    private func trackNewTabButtonClick(initialEvent: NSEvent) {
        guard let window = self.window else { return }

        var isTracking = true

        while isTracking {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                continue
            }

            let location = convert(event.locationInWindow, from: nil)

            switch event.type {
            case .leftMouseDragged:
                break

            case .leftMouseUp:
                isTracking = false
                if isNewTabButton(at: location) {
                    onNewTabRequested?()
                }

            default:
                break
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        let newHoveredIndex = tabIndex(at: location)
        let newHoveredClose: Int?
        if let index = newHoveredIndex, isCloseButton(at: location, tabIndex: index) {
            newHoveredClose = index
        } else {
            newHoveredClose = nil
        }
        let newHoveredNewTab = isNewTabButton(at: location)

        if newHoveredIndex != hoveredTabIndex || newHoveredClose != hoveredCloseButton || newHoveredNewTab != hoveredNewTabButton {
            hoveredTabIndex = newHoveredIndex
            hoveredCloseButton = newHoveredClose
            hoveredNewTabButton = newHoveredNewTab
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredTabIndex != nil || hoveredCloseButton != nil || hoveredNewTabButton {
            hoveredTabIndex = nil
            hoveredCloseButton = nil
            hoveredNewTabButton = false
            needsDisplay = true
        }
    }

    // MARK: - Public API

    func updateTabs(_ newTabs: [(handle: Int64, name: String)], currentTab: Int64) {
        self.tabs = newTabs.map { Tab(handle: $0.handle, name: $0.name, isSelected: $0.handle == currentTab) }
        self.currentTab = currentTab
        needsDisplay = true
    }
}
