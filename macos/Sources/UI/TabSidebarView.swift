import AppKit

/// Sidebar view displaying Neovim tabs as a vertical list.
/// Colors are derived from the loaded Neovim colorscheme background.
/// When blur is enabled, the sidebar is transparent to let window blur show through.
/// Window whose band the frontend draws (`TitlebarLayout.drawsBand`: a
/// captionless window, main or external, or the unified title band).
/// AppKit's titlebar swallows mouse-downs across the whole band;
/// here only the sidebar's part and a revealed drag bar move the window, the
/// editor's part reaches the editor, and titlebar controls (traffic lights,
/// sidebar toggle) keep their normal handling.
final class CaptionlessWindow: NSWindow {
    private weak var forwardedView: NSView?

    /// The band is part of the content view: hit tests below assume it.
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        precondition(style.contains(.fullSizeContentView), "CaptionlessWindow needs .fullSizeContentView")
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        placeTrafficLights(leftPt: TitlebarBand.lightsLeftPt, bandHeightPt: TitlebarBand.heightPt)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let target = bandTarget(for: event) {
                if target is TabSidebarView || target is TitlebarDragBar || target is TitleBandView {
                    // The band acts as the titlebar: drag moves, double-click zooms.
                    if event.type == .leftMouseDown {
                        if event.clickCount == 2 { performZoom(nil) } else { performDrag(with: event) }
                    }
                } else {
                    forwardedView = target
                    forward(event, to: target)
                }
                return
            }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if let target = forwardedView { forward(event, to: target); return }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if let target = forwardedView {
                forwardedView = nil
                forward(event, to: target)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// The sidebar or editor view under a mouse-down in the titlebar band;
    /// nil leaves the event to AppKit.
    private func bandTarget(for event: NSEvent) -> NSView? {
        let p = event.locationInWindow
        guard p.y >= frame.height - TitlebarBand.heightPt, let content = contentView, let frameView = content.superview,
              let top = frameView.hitTest(frameView.convert(p, from: nil)) else { return nil }
        if sequence(first: top, next: { $0.superview }).contains(where: { $0 is NSControl }) { return nil }
        guard let hit = content.hitTest(content.convert(p, from: nil)) else { return nil }
        for view in sequence(first: hit, next: { $0.superview }) {
            if view is TabSidebarView || view is TitlebarDragBar || view is TitleBandView { return view }
            if view is MetalTerminalView || view is ExternalGridView { return hit }
        }
        return nil
    }

    private func forward(_ event: NSEvent, to view: NSView) {
        switch event.type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .otherMouseDown: view.otherMouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .rightMouseDragged: view.rightMouseDragged(with: event)
        case .otherMouseDragged: view.otherMouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        case .otherMouseUp: view.otherMouseUp(with: event)
        default: break
        }
    }
}

/// Faint grab bar over the top of the editor: it fades in after the pointer
/// rests in the band and then moves the window (see CaptionlessWindow).
/// Until revealed it is click-through.
final class TitlebarDragBar: NSView {
    private static let revealDelay: TimeInterval = 2
    private var revealWork: DispatchWorkItem?
    private var revealed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.25).cgColor
        alphaValue = 0
        // Not `isHidden`: a hidden view's tracking area never fires.
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { revealed ? super.hitTest(point) : nil }

    override func mouseEntered(with event: NSEvent) {
        revealWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.revealed = true
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; self.animator().alphaValue = 1 }
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDelay, execute: work)
    }

    override func mouseExited(with event: NSEvent) { conceal() }

    private func conceal() {
        revealWork?.cancel()
        revealWork = nil
        guard revealed else { return }
        revealed = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; self.animator().alphaValue = 0 }
    }
}

/// The self-drawn titlebar band (`TitlebarLayout.titleBand`): the
/// editor's default bg and the window title in its fg, centered. It moves
/// the window and zooms on a double-click (see CaptionlessWindow).
final class TitleBandView: NSView {
    private let label = NSTextField(labelWithString: "")

    /// `leadingReservePt`: the traffic lights and the sidebar toggle; the
    /// title keeps the same distance from the right edge so it stays centered.
    init(leadingReservePt: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .titleBarFont(ofSize: 0)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: leadingReservePt),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -leadingReservePt),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The label is an NSControl, which CaptionlessWindow leaves to AppKit:
    // the whole band answers as itself so every part of it moves the window.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    /// The main window's band has no fill: it lies over the editor surface,
    /// which draws the editor's bg under it.
    func setTitleColor(_ color: NSColor) {
        label.textColor = color
    }

    /// An external window's band sits above its grid, so it paints the bg.
    func setColors(background: NSColor, foreground: NSColor) {
        layer?.backgroundColor = background.cgColor
        label.textColor = foreground
    }
}

/// A strip just inside the sidebar's inner edge that resizes the sidebar by
/// drag. It reports the proposed width; the owner clamps and applies it.
final class SidebarResizeHandle: NSView {
    var isRightSide = false
    var currentWidthPt: () -> CGFloat = { 0 }
    var onWidthChange: ((CGFloat) -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        let startX = event.locationInWindow.x
        let startWidthPt = currentWidthPt()
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity,
                            mode: .eventTracking) { [weak self] ev, stop in
            guard let self, let ev else { return }
            if ev.type == .leftMouseUp { stop.pointee = true; return }
            let dx = ev.locationInWindow.x - startX
            self.onWidthChange?(startWidthPt + (self.isRightSide ? -dx : dx))
        }
    }
}

final class TabSidebarView: NSView {

    /// Follows this view's visibility, so a closed sidebar's edge does not
    /// react.
    weak var resizeHandle: NSView?
    override var isHidden: Bool {
        didSet { resizeHandle?.isHidden = isHidden }
    }

    struct Tab {
        let handle: Int64
        let name: String
        var isSelected: Bool
        /// Card lines from 'guitablabel'; empty when the tab draws as a
        /// single-line row (no chunks, or cards off).
        let cardLines: [[TabChunk]]
    }

    private var tabs: [Tab] = []
    /// Top of each row plus the bottom of the last (tabs.count + 1 entries),
    /// recomputed whenever `tabs` changes.
    private var rowOffsets_pt: [CGFloat] = [0]

    private func rowRect(_ index: Int, width: CGFloat) -> NSRect {
        NSRect(x: 0, y: rowOffsets_pt[index], width: width,
               height: rowOffsets_pt[index + 1] - rowOffsets_pt[index])
    }
    private var currentTab: Int64 = 0

    // AI-agent indicator (set via on_agent_status). Shared with TabBarView.
    private let agentIndicator = AgentIndicator()

    func setAgentState(handle: Int64, state: UInt8) {
        agentIndicator.set(handle: handle, state: state) { [weak self] in
            self?.needsDisplay = true
        }
        needsDisplay = true
    }

    private func drawAgentIndicator(forHandle handle: Int64, in rect: NSRect, font: NSFont, color: NSColor) -> CGFloat {
        agentIndicator.draw(forHandle: handle, in: rect, font: font, color: color)
    }

    private var hoveredTabIndex: Int? = nil
    private var hoveredCloseButton: Int? = nil
    private var hoveredNewTabButton: Bool = false

    // Whether the sidebar is on the right side of the window
    var isRightSide: Bool = false

    /// Height left empty above the first tab row (the traffic-light band of a
    /// transparent titlebar). Applied as a negative bounds origin so every
    /// row-space computation keeps y = 0 at the first row.
    var topInset: CGFloat = 0 {
        didSet { setBoundsOrigin(NSPoint(x: 0, y: -topInset)); needsDisplay = true }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setBoundsOrigin(NSPoint(x: 0, y: -topInset))
        // Rows are laid out against the width at draw time.
        needsDisplay = true
    }

    private var transparentTitlebar: Bool { ZonvieConfig.shared.titlebarLayout.editorRunsUnderBand }

    /// The sidebar toggle in the titlebar band; it takes this view's tab
    /// text colour and follows the colorscheme with it.
    weak var toggleButton: NSButton? {
        didSet { toggleButton?.contentTintColor = tabTextSelectedColor }
    }

    // Appearance constants
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

    // MARK: - Colorscheme-derived colors

    // When blur is enabled, NSVisualEffectView behind the sidebar provides
    // the blur effect. The sidebar draws a subtle colorscheme tint over it.
    // When blur is disabled, the sidebar draws an opaque colorscheme-based background.

    /// The sidebar sits on the ground of an editor card.
    private var paintsIslandGround: Bool { ZonvieConfig.shared.titlebarLayout.island }

    private var sidebarBackgroundColor: NSColor {
        // The editor surface runs under the sidebar and draws its card's
        // ground there; a second fill here would not match it under blur.
        if paintsIslandGround { return .clear }
        if blurEnabled {
            // Subtle tint over the blur effect
            return NSColor(red: bgR, green: bgG, blue: bgB, alpha: 0.25)
        }
        if transparentTitlebar {
            // An editor-style panel: the bg a small lightness step away,
            // nearly opaque so the shader under it only shows faintly.
            return Self.lightnessShifted(r: bgR, g: bgG, b: bgB, darker: !isDarkBackground)
                .withAlphaComponent(Self.overlayAlpha)
        }
        if isDarkBackground {
            return NSColor(red: bgR * 0.85, green: bgG * 0.85, blue: bgB * 0.85, alpha: 1.0)
        }
        let lighten: CGFloat = 0.03
        return NSColor(
            red: min(1, bgR + lighten), green: min(1, bgG + lighten), blue: min(1, bgB + lighten), alpha: 1.0
        )
    }

    /// OKLab lightness gap between the sidebar and the editor. Dark
    /// backgrounds need a smaller step for the same perceived contrast.
    private static let sidebarLightnessDeltaLight: CGFloat = 0.07
    private static let sidebarLightnessDeltaDark: CGFloat = 0.04
    private static let overlayAlpha: CGFloat = 0.9

    /// `bg` with its OKLab L moved by the sidebar delta, hue and chroma kept.
    static func lightnessShifted(r: CGFloat, g: CGFloat, b: CGFloat, darker: Bool) -> NSColor {
        oklabLightnessShifted(r: r, g: g, b: b) { _ in darker ? -sidebarLightnessDeltaLight : sidebarLightnessDeltaDark }
    }

    /// Below this OKLab L a darker ground would clip to black, so the ground
    /// goes lighter than the card instead.
    private static let islandDarkenMinL: CGFloat = 0.2

    /// The ground the editor card and the sidebar share: the bg a lightness
    /// step darker (lighter for a near-black bg), hue and chroma kept.
    static func islandGroundRGB(bgRGB: UInt32) -> UInt32 {
        let c = oklabLightnessShifted(
            r: CGFloat((bgRGB >> 16) & 0xFF) / 255, g: CGFloat((bgRGB >> 8) & 0xFF) / 255, b: CGFloat(bgRGB & 0xFF) / 255
        ) { L in
            let delta = L >= 0.5 ? sidebarLightnessDeltaLight : sidebarLightnessDeltaDark
            return L >= islandDarkenMinL ? -delta : delta
        }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return (byte(c.redComponent) << 16) | (byte(c.greenComponent) << 8) | byte(c.blueComponent)
    }

    /// `bg` with its OKLab L moved by `deltaL(L)`, hue and chroma kept.
    private static func oklabLightnessShifted(r: CGFloat, g: CGFloat, b: CGFloat, deltaL: (CGFloat) -> CGFloat) -> NSColor {
        func toLinear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func toSRGB(_ c: CGFloat) -> CGFloat {
            let v = max(0, min(1, c))
            return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        let lr = toLinear(r), lg = toLinear(g), lb = toLinear(b)
        let l_ = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m_ = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s_ = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        var L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        L = max(0, min(1, L + deltaL(L)))
        let l2 = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m2 = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s2 = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
        return NSColor(
            red: toSRGB(4.0767416621 * l2 - 3.3077115913 * m2 + 0.2309699292 * s2),
            green: toSRGB(-1.2684380046 * l2 + 2.6097574011 * m2 - 0.3413193965 * s2),
            blue: toSRGB(-0.0041960863 * l2 - 0.7034186147 * m2 + 1.7076147010 * s2),
            alpha: 1.0
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
    var onTabMoved: ((Int, Int) -> Void)?

    // Drag state for tab externalization and reordering
    private var draggingTabIndex: Int? = nil
    private var dragStartPoint: NSPoint = .zero
    private var isExternalDrag: Bool = false
    private let dragPreviewHelper = TabDragPreviewHelper()
    private let dragThreshold: CGFloat = 5
    private let externalDragThreshold: CGFloat = 50
    private var dragOffsetY: CGFloat = 0
    private var dragCurrentY: CGFloat = 0
    private var dropTargetIndex: Int? = nil

    // Tracking area for mouse hover
    private var trackingArea: NSTrackingArea?

    // Notification observer
    private var colorschemeObserver: Any?

    override var isFlipped: Bool { true }

    // When blur is enabled, the sidebar must be non-opaque so the
    // window-level CGSSetWindowBackgroundBlurRadius blur shows through
    // (same approach as MetalTerminalView).
    override var isOpaque: Bool { !blurEnabled && !transparentTitlebar }

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
        if blurEnabled || transparentTitlebar {
            self.layer?.isOpaque = false
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
        setupTrackingArea()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-apply layer settings after window attachment
        // (layer may not exist during commonInit)
        if blurEnabled || transparentTitlebar {
            self.layer?.isOpaque = false
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    deinit {
        if let observer = colorschemeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        agentIndicator.stop()
    }

    /// Follow `core`'s colorscheme only: every session posts the same name,
    /// and observing them all recoloured this sidebar from another session.
    func observeColorschemeChanges(of core: ZonvieCore) {
        if let observer = colorschemeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        colorschemeObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.colorschemeDidChangeNotification,
            object: core,
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
            self.toggleButton?.contentTintColor = self.tabTextSelectedColor
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

        // Separator line on the edge adjacent to terminal. A transparent
        // titlebar separates the panes by the lightness gap alone, and an
        // editor card by its ground.
        if !transparentTitlebar && !paintsIslandGround {
            separatorColor.setFill()
            if isRightSide {
                NSRect(x: 0, y: 0, width: separatorWidth, height: bounds.height).fill()
            } else {
                NSRect(x: bounds.maxX - separatorWidth, y: 0, width: separatorWidth, height: bounds.height).fill()
            }
        }

        // Determine if we're in an active internal drag (threshold exceeded)
        let isInternalDrag = draggingTabIndex != nil && dropTargetIndex != nil && !isExternalDrag

        // Draw tab rows
        for (index, tab) in tabs.enumerated() {
            let isBeingDragged = isInternalDrag && index == draggingTabIndex
            drawTabRow(tab, in: rowRect(index, width: bounds.width - separatorWidth), index: index,
                       isBeingDragged: isBeingDragged)
        }

        // Draw "New Tab" button below tab list
        drawNewTabButton(at: rowOffsets_pt[tabs.count])

        // Draw drop indicator and floating tab (after everything else so they're on top)
        // A tabline_update can shrink `tabs` mid-drag (the tracking loop
        // drains the main queue), so both indices are checked against it.
        if isInternalDrag, let dragIdx = draggingTabIndex, let targetIdx = dropTargetIndex,
           dragIdx < tabs.count {
            // A) Drop indicator line
            if targetIdx != dragIdx && targetIdx != dragIdx + 1 {
                let indicatorY = rowOffsets_pt[min(targetIdx, tabs.count)]
                NSColor.controlAccentColor.setFill()
                NSRect(x: 0, y: indicatorY - 1, width: bounds.width - separatorWidth, height: 2).fill()
            }

            // B) Floating tab row, as tall as the dragged row; it shows the
            // first line only.
            let floatY = dragCurrentY - dragOffsetY
            let floatRect = NSRect(x: 2, y: floatY, width: bounds.width - separatorWidth - 4,
                                   height: rowRect(dragIdx, width: 0).height)
            let floatPath = NSBezierPath(roundedRect: floatRect, xRadius: 4, yRadius: 4)

            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            floatPath.fill()
            NSColor.controlAccentColor.setStroke()
            floatPath.lineWidth = 1.0
            floatPath.stroke()

            // Draw tab name in floating row.
            let tab = tabs[dragIdx]
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: tabTextSelectedColor,
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
            let textRect = NSRect(
                x: tabPadding + 2,
                y: floatY + TabCardLayout.verticalPadding_pt / 2,
                width: floatRect.width - tabPadding * 2,
                height: 16
            )
            let indicatorW = drawAgentIndicator(forHandle: tab.handle, in: textRect, font: font, color: tabTextSelectedColor)
            let labelRect = NSRect(x: textRect.minX + indicatorW, y: textRect.minY,
                                   width: textRect.width - indicatorW, height: textRect.height)
            TabBarView.baseLabel(tab.name).draw(in: labelRect, withAttributes: attributes)
        }
    }

    private func drawTabRow(_ tab: Tab, in rect: NSRect, index: Int, isBeingDragged: Bool = false) {
        let isSelected = tab.handle == currentTab
        let isHovered = hoveredTabIndex == index

        // Row background
        if isBeingDragged {
            // Ghost appearance for the original position of the dragged tab
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            rect.fill()
        } else if isSelected {
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
        let textColor = isSelected ? tabTextSelectedColor : tabTextColor
        let font = NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)

        let closeWidth: CGFloat = (isSelected || isHovered) ? closeButtonSize + 8 : 0
        let textX = isSelected ? tabPadding + 3 : tabPadding
        let lineH = TabCardLayout.lineHeight_pt
        let textRect = NSRect(
            x: textX,
            y: rect.minY + TabCardLayout.rowPadding_pt(lineCount: tab.cardLines.count) / 2,
            width: rect.width - textX - tabPadding - closeWidth,
            height: lineH
        )

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        if tab.cardLines.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor,
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
            let indicatorW = drawAgentIndicator(forHandle: tab.handle, in: textRect, font: font, color: textColor)
            let labelRect = NSRect(x: textRect.minX + indicatorW, y: textRect.minY,
                                   width: textRect.width - indicatorW, height: textRect.height)
            TabBarView.baseLabel(tab.name).draw(in: labelRect, withAttributes: attributes)
        } else {
            for (lineIdx, line) in tab.cardLines.enumerated() {
                // Regular base: weight comes only from the chunks' highlight
                // (bold), i.e. from 'guitablabel' and the TabLine groups.
                let lineFont = NSFont.systemFont(ofSize: lineIdx == 0 ? 12 : 11, weight: .regular)
                var lineRect = textRect.offsetBy(dx: 0, dy: CGFloat(lineIdx) * lineH)
                if lineIdx == 0 {
                    let indicatorW = drawAgentIndicator(forHandle: tab.handle, in: lineRect, font: lineFont, color: textColor)
                    lineRect.origin.x += indicatorW
                    lineRect.size.width -= indicatorW
                } else {
                    // The close button sits beside the first line only.
                    lineRect.size.width += closeWidth
                }
                TabCardLayout.attributedLine(line, font: lineFont, defaultColor: textColor, paragraphStyle: paragraphStyle)
                    .draw(with: lineRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }

        // Close button (X) on hover or selected
        if isSelected || isHovered {
            let closeRect = closeButtonRect(in: rect, lineCount: tab.cardLines.count)
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
        guard point.x >= 0, point.x < bounds.width else { return nil }
        return TabCardLayout.rowIndex(atY: point.y, offsets: rowOffsets_pt)
    }

    private func isCloseButton(at point: NSPoint, tabIndex: Int) -> Bool {
        guard tabIndex < tabs.count else { return false }
        let rowRect = rowRect(tabIndex, width: bounds.width - separatorWidth)
        return closeButtonRect(in: rowRect, lineCount: tabs[tabIndex].cardLines.count).contains(point)
    }

    /// Top-right of the row, centred on the first text line (for a one-line
    /// row that is the row's centre).
    private func closeButtonRect(in rowRect: NSRect, lineCount: Int) -> NSRect {
        let firstLineMidY = rowRect.minY + TabCardLayout.rowPadding_pt(lineCount: lineCount) / 2
            + TabCardLayout.lineHeight_pt / 2
        return NSRect(
            x: rowRect.maxX - closeButtonSize - 8,
            y: firstLineMidY - closeButtonSize / 2,
            width: closeButtonSize,
            height: closeButtonSize
        )
    }

    private func isNewTabButton(at point: NSPoint) -> Bool {
        let y = rowOffsets_pt[tabs.count]
        let rect = NSRect(x: 0, y: y, width: bounds.width, height: newTabButtonHeight)
        return rect.contains(point)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        if let index = tabIndex(at: location) {
            // Only where the row shows the X: a selected or hovered tab.
            let closeShown = tabs[index].handle == currentTab || hoveredTabIndex == index
            if closeShown && isCloseButton(at: location, tabIndex: index) {
                trackCloseButtonClick(initialEvent: event, tabIndex: index)
            } else {
                trackTabDrag(initialEvent: event, tabIndex: index)
            }
        } else if isNewTabButton(at: location) {
            trackNewTabButtonClick(initialEvent: event)
        }
    }

    /// Track tab drag for reordering and externalization
    private func trackTabDrag(initialEvent: NSEvent, tabIndex: Int) {
        guard let window = self.window else { return }
        guard tabIndex < tabs.count else { return }

        let startLocation = convert(initialEvent.locationInWindow, from: nil)
        dragStartPoint = startLocation
        draggingTabIndex = tabIndex
        isExternalDrag = false
        dragOffsetY = startLocation.y - rowOffsets_pt[tabIndex]
        dragCurrentY = startLocation.y
        dropTargetIndex = nil
        var isDragging = true
        var hasMoved = false
        // The loop drains the main queue, so a tabline_update can replace
        // `tabs` mid-drag: the dragged tab is followed by its handle.
        let draggedTab = tabs[tabIndex]

        // Select the dragged tab immediately (`:tabmove` moves the current tab)
        onTabSelected?(draggedTab.handle)

        while isDragging {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                continue
            }

            let location = convert(event.locationInWindow, from: nil)
            let screenLocation = window.convertPoint(toScreen: event.locationInWindow)

            let isOutsideSidebar = TabDragPreviewHelper.isOutsideBounds(
                of: self, screenPoint: screenLocation, threshold: externalDragThreshold
            )

            switch event.type {
            case .leftMouseDragged:
                let distance = hypot(location.x - dragStartPoint.x, location.y - dragStartPoint.y)
                if distance > dragThreshold { hasMoved = true }

                if hasMoved && isOutsideSidebar && !isExternalDrag {
                    isExternalDrag = true
                    dropTargetIndex = nil
                    dragPreviewHelper.create(tabName: TabCardLayout.firstLine(draggedTab.name), at: screenLocation)
                } else if hasMoved && !isOutsideSidebar && isExternalDrag {
                    isExternalDrag = false
                    dragPreviewHelper.destroy()
                }

                if isExternalDrag {
                    dragPreviewHelper.updatePosition(screenLocation)
                } else if hasMoved {
                    // Internal reorder drag
                    dragCurrentY = location.y

                    dropTargetIndex = TabCardLayout.dropIndex(atY: location.y, offsets: rowOffsets_pt)
                }
                needsDisplay = true

            case .leftMouseUp:
                isDragging = false

                let currentIndex = tabs.firstIndex { $0.handle == draggedTab.handle }
                if isExternalDrag {
                    dragPreviewHelper.destroy()
                    if currentIndex != nil {
                        onTabExternalized?(draggedTab.handle, screenLocation)
                    }
                } else if !hasMoved {
                    // Click without drag — tab was already selected above
                } else if let currentIndex, let targetIdx = dropTargetIndex.map({ min($0, tabs.count) }) {
                    if targetIdx != currentIndex && targetIdx != currentIndex + 1 {
                        onTabMoved?(currentIndex, targetIdx)
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

    func updateTabs(_ newTabs: [(handle: Int64, name: String, chunks: [TabChunk])], currentTab: Int64) {
        let cards = ZonvieConfig.shared.tabline.cards
        self.tabs = newTabs.map {
            Tab(handle: $0.handle, name: $0.name, isSelected: $0.handle == currentTab,
                cardLines: cards && !$0.chunks.isEmpty ? TabCardLayout.lines($0.chunks) : [])
        }
        rowOffsets_pt = TabCardLayout.rowOffsets_pt(tabs.map {
            TabCardLayout.rowHeight_pt(lineCount: $0.cardLines.count)
        })
        self.currentTab = currentTab
        needsDisplay = true
    }
}
