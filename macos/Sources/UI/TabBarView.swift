import AppKit

/// Custom window that allows TabBarView to receive mouse events in titlebar area
final class TabBarWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        // For mouse down events in the titlebar area, check if TabBarView should handle it
        if event.type == .leftMouseDown {
            let contentPoint = contentView?.convert(event.locationInWindow, from: nil) ?? .zero

            // Find TabBarView and check if click is in tab area
            if let tabBarView = contentView?.subviews.first(where: { $0 is TabBarView }) as? TabBarView {
                let tabBarPoint = tabBarView.convert(event.locationInWindow, from: nil)
                if tabBarView.bounds.contains(tabBarPoint) {
                    // Check if it's on a tab (not empty area)
                    if tabBarView.isPointOnTab(tabBarPoint) {
                        // Let TabBarView handle it directly
                        tabBarView.mouseDown(with: event)
                        return
                    }
                }
            }
        }
        super.sendEvent(event)
    }
}

/// Chrome-style tab bar that renders in the titlebar area
final class TabBarView: NSView {

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

    // Drag state
    private var draggingTabIndex: Int? = nil
    private var dragStartX: CGFloat = 0
    private var dragOffsetX: CGFloat = 0  // Offset from tab left edge to mouse
    private var dragCurrentX: CGFloat = 0
    private var dropTargetIndex: Int? = nil
    private let dragThreshold: CGFloat = 5

    // External drag state (for tab externalization)
    private var isExternalDrag: Bool = false
    private var dragPreviewWindow: NSWindow? = nil
    private let externalDragThreshold: CGFloat = 50  // pixels outside window to trigger external drag

    // Tab appearance constants
    private let tabHeight: CGFloat = 32
    private let tabMinWidth: CGFloat = 100
    private let tabMaxWidth: CGFloat = 200
    private let tabSpacing: CGFloat = 1
    private let tabCornerRadius: CGFloat = 8
    private let tabCloseButtonSize: CGFloat = 14
    private let tabPadding: CGFloat = 12
    private let windowControlsWidth: CGFloat = 78  // Space for traffic lights

    // Colors - Chrome-style appearance with dark mode support
    private var isDarkMode: Bool {
        if #available(macOS 10.14, *) {
            return effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return false
    }

    // Bar background: slightly blue-tinted gray
    private var barBackgroundColor: NSColor {
        if isDarkMode {
            return NSColor(calibratedRed: 0.176, green: 0.180, blue: 0.192, alpha: 1.0)  // #2D2E31
        }
        return NSColor(calibratedRed: 0.87, green: 0.88, blue: 0.90, alpha: 1.0)  // #DEE1E6
    }

    // Unselected tab: same as bar background (tabs blend in)
    private var tabBackgroundColor: NSColor { barBackgroundColor }

    // Selected tab: white in light mode, darker gray in dark mode
    private var tabSelectedColor: NSColor {
        if isDarkMode {
            return NSColor(calibratedRed: 0.235, green: 0.247, blue: 0.275, alpha: 1.0)  // #3C3F46
        }
        return NSColor.white
    }

    // Hover tab: slightly lighter than bar background
    private var tabHoverColor: NSColor {
        if isDarkMode {
            return NSColor(calibratedRed: 0.251, green: 0.267, blue: 0.282, alpha: 1.0)  // #404448
        }
        return NSColor(calibratedRed: 0.92, green: 0.93, blue: 0.94, alpha: 1.0)  // #EBEDEF
    }

    // Text colors
    private var tabTextColor: NSColor {
        if isDarkMode {
            return NSColor(calibratedRed: 0.91, green: 0.91, blue: 0.922, alpha: 1.0)  // #E8E8EB
        }
        return NSColor(calibratedRed: 0.35, green: 0.37, blue: 0.40, alpha: 1.0)  // #595E66
    }

    private var tabTextSelectedColor: NSColor {
        if isDarkMode {
            return NSColor.white
        }
        return NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.14, alpha: 1.0)  // #1F2124
    }

    // Callbacks
    var onTabSelected: ((Int64) -> Void)?
    var onTabClosed: ((Int64) -> Void)?
    var onNewTabRequested: (() -> Void)?
    var onTabMoved: ((Int, Int) -> Void)?  // (fromIndex, toIndex)
    var onTabExternalized: ((Int64, NSPoint) -> Void)?  // (tabHandle, dropScreenPoint)

    // Tracking area for mouse hover
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackingArea()
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

    // Redraw when system appearance changes (light/dark mode)
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    // Prevent window dragging when clicking on tabs
    override var mouseDownCanMoveWindow: Bool { false }

    // Accept first mouse click even if window is not focused
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Override hit test to ensure this view receives mouse events in titlebar area
    override func hitTest(_ point: NSPoint) -> NSView? {
        // If point is within our bounds, we handle it
        if bounds.contains(convert(point, from: superview)) {
            return self
        }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw bar background
        barBackgroundColor.setFill()
        bounds.fill()

        guard !tabs.isEmpty else { return }

        // Calculate tab width
        let availableWidth = bounds.width - windowControlsWidth - 40  // 40 for new tab button
        let tabCount = CGFloat(tabs.count)
        let idealTabWidth = (availableWidth - tabSpacing * (tabCount - 1)) / tabCount
        let tabWidth = min(tabMaxWidth, max(tabMinWidth, idealTabWidth))

        let isDragging = draggingTabIndex != nil
        var x = windowControlsWidth

        for (index, tab) in tabs.enumerated() {
            let isSelected = tab.handle == currentTab
            let isHovered = hoveredTabIndex == index && !isSelected
            let isBeingDragged = isDragging && draggingTabIndex == index

            let tabRect = NSRect(x: x, y: 4, width: tabWidth, height: tabHeight - 4)
            drawTab(tab, in: tabRect, isSelected: isSelected, isHovered: isHovered, isBeingDragged: isBeingDragged, index: index)

            x += tabWidth + tabSpacing
        }

        // Draw new tab button (+)
        drawNewTabButton(at: NSPoint(x: x + 8, y: 8))

        // Draw drop indicator when dragging
        if isDragging, let targetIdx = dropTargetIndex, let dragIdx = draggingTabIndex {
            // Only show indicator if target is different from current position
            if targetIdx != dragIdx && targetIdx != dragIdx + 1 {
                let indicatorX = windowControlsWidth + CGFloat(targetIdx) * (tabWidth + tabSpacing)
                NSColor.controlAccentColor.setFill()
                NSRect(x: indicatorX - 1, y: 2, width: 2, height: tabHeight - 4).fill()
            }

            // Draw floating tab at cursor position
            let tab = tabs[dragIdx]
            let floatX = dragCurrentX - dragOffsetX
            let floatRect = NSRect(x: floatX, y: 4, width: tabWidth, height: tabHeight - 4)
            let floatPath = NSBezierPath(roundedRect: floatRect, xRadius: tabCornerRadius, yRadius: tabCornerRadius)

            // Light blue background with border
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            floatPath.fill()
            NSColor.controlAccentColor.setStroke()
            floatPath.lineWidth = 1.0
            floatPath.stroke()

            // Draw tab name
            let displayName = tab.name.isEmpty ? "[No Name]" : (tab.name as NSString).lastPathComponent
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.labelColor,
                .font: font
            ]
            let textRect = NSRect(
                x: floatX + tabPadding,
                y: 4 + (tabHeight - 4 - 16) / 2,
                width: tabWidth - tabPadding * 2,
                height: 16
            )
            displayName.draw(in: textRect, withAttributes: attributes)
        }
    }

    // Tab border color for subtle shadow effect
    private var tabBorderColor: NSColor {
        if isDarkMode {
            return NSColor(calibratedWhite: 0.0, alpha: 0.15)  // Dark shadow in dark mode
        }
        return NSColor(calibratedWhite: 0.0, alpha: 0.05)  // Light shadow in light mode
    }

    private func drawTab(_ tab: Tab, in rect: NSRect, isSelected: Bool, isHovered: Bool, isBeingDragged: Bool, index: Int) {
        let path = NSBezierPath(roundedRect: rect, xRadius: tabCornerRadius, yRadius: tabCornerRadius)

        // Background
        if isBeingDragged {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        } else if isSelected {
            tabSelectedColor.setFill()
        } else if isHovered {
            tabHoverColor.setFill()
        } else {
            tabBackgroundColor.setFill()
        }
        path.fill()

        // 1px border/shadow for better tab visibility
        if isSelected || isHovered {
            tabBorderColor.setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }

        // Tab title
        let textColor = isSelected ? tabTextSelectedColor : tabTextColor
        let font = NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)

        let closeButtonWidth: CGFloat = isSelected || isHovered ? tabCloseButtonSize + 8 : 0
        let titleRect = NSRect(
            x: rect.minX + tabPadding,
            y: rect.minY + (rect.height - 16) / 2,
            width: rect.width - tabPadding * 2 - closeButtonWidth,
            height: 16
        )

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: font,
            .paragraphStyle: paragraphStyle
        ]

        let displayName = tab.name.isEmpty ? "[No Name]" : (tab.name as NSString).lastPathComponent
        displayName.draw(in: titleRect, withAttributes: attributes)

        // Close button (X) - show on selected or hovered tabs
        if isSelected || isHovered {
            let closeRect = NSRect(
                x: rect.maxX - tabCloseButtonSize - 8,
                y: rect.midY - tabCloseButtonSize / 2,
                width: tabCloseButtonSize,
                height: tabCloseButtonSize
            )
            drawCloseButton(in: closeRect, highlighted: hoveredCloseButton == index)
        }
    }

    private func drawCloseButton(in rect: NSRect, highlighted: Bool) {
        if highlighted {
            NSColor.secondaryLabelColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        (highlighted ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
        let path = NSBezierPath()
        let inset: CGFloat = 4
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawNewTabButton(at origin: NSPoint) {
        let size: CGFloat = 20
        let rect = NSRect(x: origin.x, y: origin.y, width: size, height: size)

        // Background on hover (circular, like close button)
        if hoveredNewTabButton {
            NSColor.secondaryLabelColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath()
        let inset: CGFloat = 5
        path.move(to: NSPoint(x: rect.midX, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY - inset))
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.midY))
        path.lineWidth = 1.5
        path.stroke()
    }

    // MARK: - Hit Testing

    private func tabIndex(at point: NSPoint) -> Int? {
        guard !tabs.isEmpty else { return nil }

        let availableWidth = bounds.width - windowControlsWidth - 40
        let tabCount = CGFloat(tabs.count)
        let idealTabWidth = (availableWidth - tabSpacing * (tabCount - 1)) / tabCount
        let tabWidth = min(tabMaxWidth, max(tabMinWidth, idealTabWidth))

        var x = windowControlsWidth

        for index in 0..<tabs.count {
            let tabRect = NSRect(x: x, y: 4, width: tabWidth, height: tabHeight - 4)
            if tabRect.contains(point) {
                return index
            }
            x += tabWidth + tabSpacing
        }

        return nil
    }

    /// Public method for TabBarWindow to check if point is on a tab
    func isPointOnTab(_ point: NSPoint) -> Bool {
        return tabIndex(at: point) != nil
    }

    private func isCloseButton(at point: NSPoint, tabIndex: Int) -> Bool {
        guard tabIndex < tabs.count else { return false }

        let availableWidth = bounds.width - windowControlsWidth - 40
        let tabCount = CGFloat(tabs.count)
        let idealTabWidth = (availableWidth - tabSpacing * (tabCount - 1)) / tabCount
        let tabWidth = min(tabMaxWidth, max(tabMinWidth, idealTabWidth))

        let tabX = windowControlsWidth + CGFloat(tabIndex) * (tabWidth + tabSpacing)
        let tabRect = NSRect(x: tabX, y: 4, width: tabWidth, height: tabHeight - 4)

        let closeRect = NSRect(
            x: tabRect.maxX - tabCloseButtonSize - 8,
            y: tabRect.midY - tabCloseButtonSize / 2,
            width: tabCloseButtonSize,
            height: tabCloseButtonSize
        )

        return closeRect.contains(point)
    }

    private func isNewTabButton(at point: NSPoint) -> Bool {
        let availableWidth = bounds.width - windowControlsWidth - 40
        let tabCount = CGFloat(tabs.count)
        let idealTabWidth = (availableWidth - tabSpacing * (tabCount - 1)) / tabCount
        let tabWidth = min(tabMaxWidth, max(tabMinWidth, idealTabWidth))

        let x = windowControlsWidth + CGFloat(tabs.count) * (tabWidth + tabSpacing) + 8
        let rect = NSRect(x: x, y: 8, width: 20, height: 20)

        return rect.contains(point)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        if let index = tabIndex(at: location) {
            if isCloseButton(at: location, tabIndex: index) {
                // Close button pressed - track until mouse up
                trackCloseButtonClick(initialEvent: event, tabIndex: index)
            } else {
                // Start tab drag - use event tracking loop to prevent window drag
                let availableWidth = bounds.width - windowControlsWidth - 40
                let tabCountF = CGFloat(tabs.count)
                let idealTabWidth = (availableWidth - tabSpacing * (tabCountF - 1)) / tabCountF
                let tabWidth = min(tabMaxWidth, max(tabMinWidth, idealTabWidth))
                let tabX = windowControlsWidth + CGFloat(index) * (tabWidth + tabSpacing)

                draggingTabIndex = index
                dragStartX = location.x
                dragOffsetX = location.x - tabX
                dragCurrentX = location.x
                dropTargetIndex = index

                // Event tracking loop - handle drag ourselves
                trackTabDrag(initialEvent: event, tabIndex: index, tabWidth: tabWidth)
            }
        } else if isNewTabButton(at: location) {
            // New tab button pressed - track until mouse up
            trackNewTabButtonClick(initialEvent: event)
        } else {
            // Empty area in titlebar
            if event.clickCount == 2 {
                // Double-click: zoom (maximize/restore) window
                // This follows macOS system behavior for titlebar double-click
                window?.zoom(nil)
            } else {
                // Single click: allow window dragging
                window?.performDrag(with: event)
            }
        }
    }

    /// Track tab drag using event loop to prevent window dragging
    private func trackTabDrag(initialEvent: NSEvent, tabIndex: Int, tabWidth: CGFloat) {
        ZonvieCore.appLog("[TAB-DRAG] trackTabDrag started for tab \(tabIndex)")
        guard let window = self.window else {
            ZonvieCore.appLog("[TAB-DRAG] window is nil, aborting")
            return
        }

        var isDragging = true
        isExternalDrag = false

        while isDragging {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                continue
            }

            let location = convert(event.locationInWindow, from: nil)
            let screenLocation = window.convertPoint(toScreen: event.locationInWindow)
            let windowFrame = window.frame

            // Check if mouse is outside window bounds (with threshold)
            let expandedFrame = windowFrame.insetBy(dx: -externalDragThreshold, dy: -externalDragThreshold)
            let isOutsideWindow = !expandedFrame.contains(screenLocation)

            switch event.type {
            case .leftMouseDragged:
                // DEBUG: Log drag position
                if isOutsideWindow {
                    ZonvieCore.appLog("[TAB-DRAG] screenLocation=\(screenLocation) windowFrame=\(windowFrame) expandedFrame=\(expandedFrame) isOutside=\(isOutsideWindow)")
                }

                if isOutsideWindow && !isExternalDrag {
                    // Entering external drag mode
                    isExternalDrag = true
                    ZonvieCore.appLog("[TAB-DRAG] Entering external drag mode for tab \(tabIndex)")
                    createDragPreviewWindow(for: tabIndex, at: screenLocation)
                } else if !isOutsideWindow && isExternalDrag {
                    // Returning to normal drag mode
                    isExternalDrag = false
                    ZonvieCore.appLog("[TAB-DRAG] Returning to normal drag mode")
                    destroyDragPreviewWindow()
                }

                if isExternalDrag {
                    // Update preview window position
                    updateDragPreviewPosition(screenLocation)
                } else {
                    // Normal in-window drag
                    dragCurrentX = location.x

                    // Calculate drop target
                    var targetIdx = 0
                    var tabX = windowControlsWidth
                    for i in 0..<tabs.count {
                        let tabCenter = tabX + tabWidth / 2
                        if location.x < tabCenter {
                            targetIdx = i
                            break
                        }
                        targetIdx = i + 1
                        tabX += tabWidth + tabSpacing
                    }
                    dropTargetIndex = min(targetIdx, tabs.count)
                }
                needsDisplay = true

            case .leftMouseUp:
                isDragging = false
                ZonvieCore.appLog("[TAB-DRAG] mouseUp isExternalDrag=\(isExternalDrag) screenLocation=\(screenLocation)")

                if isExternalDrag {
                    // Externalize the tab
                    let tab = tabs[tabIndex]
                    ZonvieCore.appLog("[TAB-DRAG] Externalizing tab handle=\(tab.handle) name=\(tab.name)")
                    destroyDragPreviewWindow()
                    onTabExternalized?(tab.handle, screenLocation)
                } else {
                    let movedDistance = abs(location.x - dragStartX)

                    if movedDistance < dragThreshold {
                        // Didn't move enough - treat as click (select tab)
                        let tab = tabs[tabIndex]
                        onTabSelected?(tab.handle)
                    } else if let targetIdx = dropTargetIndex {
                        // Actually moved - reorder tab
                        if targetIdx != tabIndex && targetIdx != tabIndex + 1 {
                            onTabMoved?(tabIndex, targetIdx)
                        }
                    }
                }

                // Reset drag state
                draggingTabIndex = nil
                dropTargetIndex = nil
                isExternalDrag = false
                needsDisplay = true

            default:
                break
            }
        }
    }

    /// Track close button click until mouse up - only close if still over button
    private func trackCloseButtonClick(initialEvent: NSEvent, tabIndex: Int) {
        guard let window = self.window else { return }
        guard tabIndex < tabs.count else { return }

        let tab = tabs[tabIndex]
        var isTracking = true

        // Visual feedback - highlight close button as pressed
        hoveredCloseButton = tabIndex
        needsDisplay = true

        while isTracking {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                continue
            }

            let location = convert(event.locationInWindow, from: nil)

            switch event.type {
            case .leftMouseDragged:
                // Update hover state based on whether mouse is still over close button
                let isStillOverClose = isCloseButton(at: location, tabIndex: tabIndex)
                if isStillOverClose != (hoveredCloseButton == tabIndex) {
                    hoveredCloseButton = isStillOverClose ? tabIndex : nil
                    needsDisplay = true
                }

            case .leftMouseUp:
                isTracking = false
                // Only close if mouse is still over the close button
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

    /// Track new tab button click until mouse up - only create tab if still over button
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
                // Could add visual feedback here if needed
                break

            case .leftMouseUp:
                isTracking = false
                // Only create new tab if mouse is still over the button
                if isNewTabButton(at: location) {
                    onNewTabRequested?()
                }

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

        // Round corners
        previewWindow.contentView?.wantsLayer = true
        previewWindow.contentView?.layer?.cornerRadius = 8
        previewWindow.contentView?.layer?.masksToBounds = true

        // Add tab name label
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

    override func mouseDragged(with event: NSEvent) {
        // Tab dragging is handled by trackTabDrag event loop
        // This method is kept for potential future use
    }

    override func mouseUp(with event: NSEvent) {
        // Tab dragging is handled by trackTabDrag event loop
        // This method is kept for potential future use
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        let newHoveredIndex = tabIndex(at: location)
        let newHoveredClose: Int? = if let index = newHoveredIndex, isCloseButton(at: location, tabIndex: index) {
            index
        } else {
            nil
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

    var tabCount: Int {
        tabs.count
    }
}
