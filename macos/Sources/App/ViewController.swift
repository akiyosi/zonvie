import Cocoa
import MetalKit

final class ViewController: NSViewController {
    private var terminalView: MetalTerminalView!
    private(set) var core: ZonvieCore!

    /// Set by AppDelegate when this window hosts a "New Session": show the
    /// connection dialog on appear (regardless of the global `--dialog` flag)
    /// and, on Cancel, close this window rather than quitting the app.
    var forceConnectDialog = false
    private var tabBarView: TabBarView?
    private var sidebarView: TabSidebarView?

    private let titlebarLayout = ZonvieConfig.shared.titlebarLayout
    // The editor surface starts at the window top, under the chrome.
    private var editorRunsUnderBand: Bool { titlebarLayout.editorRunsUnderBand }
    private var sidebarEdgeConstraint: NSLayoutConstraint?
    /// Starts at `[tabline] sidebar_width`; a drag of the sidebar edge
    /// changes it for this session only.
    private var sidebarWidthPt = CGFloat(ZonvieConfig.shared.tabline.sidebarWidth)
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private static let sidebarMinWidthPt: CGFloat = 120
    private static let sidebarResizeHandleWidthPt: CGFloat = 5
    private var dragBar: TitlebarDragBar?
    private var sidebarToggleCenterYConstraint: NSLayoutConstraint?
    private var dragBarHeightConstraint: NSLayoutConstraint?
    private var sidebarCollapsed = false
    private var sidebarSliding = false
    private var tablineShown = false
    private var bandObserver: Any?
    private var titlebarReveal: WindowButtonHoverReveal?
    // A self-drawn band over the editor's side (TitlebarLayout.titleBand).
    private var drawsTitleBand: Bool { titlebarLayout.titleBand }
    private var titleBand: TitleBandView?
    private var titleBandObserver: Any?
    private var titleObservation: NSKeyValueObservation?
    // `titlebar_edge = "border"`: the line along the band's bottom.
    private var edgeHairline: EdgeHairlineView?
    private var edgeHairlineObserver: Any?

    // Height of the Chrome-style tab bar; over the editor it is the shared band.
    private var tabBarHeight: CGFloat { editorRunsUnderBand ? TitlebarBand.heightPt : 36 }

    // Notification observers for tabline
    private var tablineUpdateObserver: Any?
    private var tablineHideObserver: Any?
    private var agentStatusObserver: Any?

    // Current tab list for lookup
    private var currentTabs: [(handle: Int64, name: String, chunks: [TabChunk])] = []

    // `--dialog` startup dialog: deferred to viewDidAppear (needs a window to
    // host the sheet). `pendingConnectDialog` is armed in viewDidLoad when the
    // flag is set; `connectDialogShown` guards against a second presentation on
    // repeated viewDidAppear calls.
    private var pendingConnectDialog = false
    private var connectDialogShown = false

    override func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = ZonvieConfig.shared

        // Configure root view layer for transparency.
        // Must be done here (not in loadView) because the layer may not exist yet.
        if config.blurEnabled {
            view.layer?.isOpaque = false
            view.layer?.backgroundColor = NSColor.clear.cgColor
            ZonvieCore.appLog("[ViewController] root view layer: exists=\(view.layer != nil) isOpaque=\(view.layer?.isOpaque ?? true)")
        }

        terminalView = MetalTerminalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        // A "column" scrollbar keeps its strip from launch, chrome or not;
        // updateGridInsets re-adds it whenever the chrome moves the grid.
        terminalView.gridInsetsPt = (0, ZonvieConfig.shared.scrollbar.columnWidthPt, 0)

        view.addSubview(terminalView)

        ZonvieCore.appLog("[ViewController] terminalView.layer exists=\(terminalView.layer != nil) isOpaque=\(terminalView.layer?.isOpaque ?? true)")

        let tablineStyle = config.effectiveTablineStyle
        ZonvieCore.appLog("[ViewController] effectiveTablineStyle=\(String(describing: tablineStyle)) tabline.external=\(config.tabline.external) tabline.style=\(config.tabline.style)")

        switch tablineStyle {
        case .titlebar:
            setupTabBar()
            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: view.topAnchor, constant: editorRunsUnderBand ? 0 : tabBarHeight),
                terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])

        case .sidebar:
            setupSidebar()
            // Constraints are set up inside setupSidebar()

        case .menu, nil:
            // A menu or no ext_tabline: no tab UI in the window. Notification
            // observers (set up below, once the core exists) keep currentTabs
            // tracking in menu mode.
            if drawsTitleBand { installTitleBand(beside: nil) }
            // The surface reaches the top; a title band's height comes off
            // the grid (titleBandInsetPt), not the view.
            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: view.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        // Create core (init takes no args)
        core = ZonvieCore()

        // Observers filter on this session's core, so they register only
        // once it exists: registered earlier, `object: core` was nil and
        // every session's tabline reached this window.
        if tablineStyle != nil {
            setupTablineNotificationObservers()
        }
        sidebarView?.observeColorschemeChanges(of: core)
        // A title band paints itself (titleBandObserver below).
        if editorRunsUnderBand && !config.blurEnabled {
            // Under the band: chrome gaps show the root view, in the editor bg.
            bandObserver = NotificationCenter.default.addObserver(
                forName: ZonvieCore.colorschemeDidChangeNotification, object: core, queue: .main
            ) { [weak self] note in
                guard let self, let rgb = note.userInfo?["bgRGB"] as? UInt32, rgb != 0xFFFF_FFFF else { return }
                self.view.layer?.backgroundColor = Self.rgbColor(rgb).cgColor
            }
        }

        if let band = titleBand {
            // The band is clear over the editor surface; only the title takes
            // the editor's fg.
            titleBandObserver = NotificationCenter.default.addObserver(
                forName: ZonvieCore.colorschemeDidChangeNotification, object: core, queue: .main
            ) { [weak band] note in
                guard let band else { return }
                let fg = note.userInfo?["fgRGB"] as? UInt32 ?? 0xFFFF_FFFF
                band.setTitleColor(fg == 0xFFFF_FFFF ? .labelColor : Self.rgbColor(fg))
            }
        }

        // Wire both directions
        core.terminalView = terminalView
        terminalView.core = core

        // `--dialog` (startup) or a New Session window: defer nvim launch until
        // the user chooses a connection in the dialog (presented from
        // viewDidAppear). Skip the config-driven ext pre-apply and start below —
        // the chosen ConnectionConfig drives ext_* and the connection mode.
        if connectDialogEnabled || forceConnectDialog {
            pendingConnectDialog = true
            ZonvieCore.appLog("[ViewController] dialog: deferring start until connection dialog is dismissed")
            return
        }

        // Enable ext_popupmenu if configured (must be before start())
        if config.popup.external {
            core.setExtPopupmenu(true)
        }

        // Enable ext_messages if configured (must be before start())
        if config.messages.external {
            core.setExtMessages(true)
        }

        // Dispatch core.start() off the main thread so viewDidLoad can return
        // immediately and AppDelegate.makeKeyAndOrderFront runs without
        // waiting for nvim spawn / Zig core init. nvim startup proceeds in
        // parallel with the AppKit window-shown work on main, shaving ~80ms
        // off perceived window-appear latency.
        //
        // SSH/devcontainer modes still use main.async because their auth
        // dialogs require a running main RunLoop and they perform AppKit
        // work (NSWindow, osascript) inside start(). SSH detection mirrors
        // ZonvieCore.start()'s combined CLI flag / config.toml check.
        //
        // rows/cols here are placeholders (1×1). The RPC thread blocks on the
        // core's layout-ready wait (ui_attach_cond in rpc_session.zig) until
        // MetalTerminalView signals
        // notifyInitialLayout() with the actual rows/cols computed from
        // the post-layout drawable size, so nvim_ui_attach is sent with the
        // correct dimensions on the first try.
        let nvimPath = cliNvimPath ?? config.neovim.path
        let remote = sshModeEnabled || config.neovim.ssh || devcontainerModeEnabled
        dispatchStart(nvimPath: nvimPath, remote: remote, context: remote ? "ssh/devcontainer" : "native")
    }

    /// Start the core: a remote session on main (its auth dialogs need the
    /// RunLoop), a local one off it.
    private func dispatchStart(nvimPath: String, remote: Bool, context: String) {
        core.startRequested = true
        let queue = remote ? DispatchQueue.main : DispatchQueue.global(qos: .userInitiated)
        queue.async { [weak self] in
            guard let self = self else { return }
            // A closed session's ViewController and core must deinit on main.
            defer { DispatchQueue.main.async { withExtendedLifetime(self) {} } }
            guard !self.core.startCancelled else { return }
            let rc = self.core.start(nvimPath: nvimPath, rows: 1, cols: 1)
            if rc != 0 { self.handleCoreStartFailure(rc: rc, context: context) }
        }
    }

    /// Present the interactive connection chooser (`--dialog`). On Connect the
    /// chosen ConnectionConfig drives `core.start()`; on Cancel the session
    /// ends (the app quits if it was the last one).
    private func presentConnectionDialog() {
        let menu = ConnectionMenuViewController()
        // `--ssh --dialog` / `--devcontainer --dialog`: seed the CLI startup
        // dialog. New Session windows (forceConnectDialog) start blank/local.
        if !forceConnectDialog {
            menu.initialTab = dialogInitialTab
            menu.seedConfig = dialogSeedConfig
        }
        menu.onConnect = { [weak self] cfg in
            self?.startWithConnection(cfg)
        }
        menu.onCancel = { [weak self] in
            // Other sessions may have started meanwhile (Cmd+N is not blocked
            // by the sheet): end only this one unless it is the last.
            ZonvieCore.appLog("[ViewController] connection dialog cancelled: ending session")
            self?.core.endSession()
        }
        presentAsSheet(menu)
    }

    /// Launch nvim for the tile's current window using an explicit
    /// ConnectionConfig chosen in the `--dialog` dialog. Mirrors viewDidLoad's
    /// start dispatch, but feeds the connection through `core.connectionConfig`
    /// (which takes priority over CLI flags / config.toml inside start()).
    private func startWithConnection(_ dialogCfg: ConnectionConfig) {
        var cfg = dialogCfg
        // The spawn command's quoting cannot carry a quote inside a path (the
        // --nvim rule in main.swift, and the Windows dialog): one pair around
        // the whole path is dropped, and a path still holding one is ignored.
        var path = cfg.nvimPath
        if path.count >= 2, let first = path.first, first == "\"" || first == "'", path.last == first {
            path = String(path.dropFirst().dropLast())
        }
        if path.contains("'") || path.contains("\"") {
            ZonvieCore.appLog("[ViewController] --dialog: nvim path contains quote characters; ignoring it")
            if let window = view.window {
                let alert = NSAlert()
                alert.messageText = "The Neovim path contains a quote character and was ignored."
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
            path = ""
        }
        cfg.nvimPath = path

        // Apply per-connection environment variables (KEY=VALUE per line) before
        // the core spawns nvim, so the child inherits them.
        for line in cfg.envVars.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !trimmed.contains("=") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                setenv(String(parts[0]), String(parts[1]), 1)
            }
        }

        core.connectionConfig = cfg

        // Label this session window from the chosen connection (menu-bar title).
        SessionManager.shared.rename(self, to: Self.sessionName(for: cfg))

        let nvimPath = cfg.nvimPath.isEmpty
            ? (cliNvimPath ?? ZonvieConfig.shared.neovim.path)
            : cfg.nvimPath

        ZonvieCore.appLog("[ViewController] --dialog: starting core name=\(cfg.name) isSSH=\(cfg.isSSH) isDevcontainer=\(cfg.isDevcontainer)")

        let remote = cfg.isSSH || cfg.isDevcontainer
        dispatchStart(nvimPath: nvimPath, remote: remote,
                      context: remote ? "connect-dialog ssh/devcontainer" : "connect-dialog native")
    }

    /// Menu-bar label for a session's connection config.
    static func sessionName(for cfg: ConnectionConfig) -> String {
        if !cfg.name.isEmpty { return cfg.name }
        if cfg.isSSH { return cfg.sshHost.isEmpty ? "SSH" : "SSH: \(cfg.sshHost)" }
        if cfg.isDevcontainer { return "Devcontainer" }
        return "Local"
    }

    /// Surface a synchronous start() / start_connect() failure to the user
    /// and end the session (exit(1) if it is the only one). The C ABI returns
    /// 0 on success, -1 invalid handle, -2 thread spawn failed,
    /// -3 invalid/unsupported listen address. In
    /// every failure case the core thread did NOT start and on_exit will
    /// not fire, so without explicit handling the window would remain
    /// open with no backing nvim — the user sees an empty zombie window.
    private func handleCoreStartFailure(rc: Int32, context: String) {
        ZonvieCore.appLog("[start] core start failed rc=\(rc) context=\(context)")
        DispatchQueue.main.async {
            let lastSession = SessionManager.shared.sessions.count <= 1
            let alert = NSAlert()
            alert.messageText = "Zonvie failed to start"
            let reason: String
            switch rc {
            case -1: reason = "Invalid core handle (rc=-1)."
            case -2: reason = "Could not spawn the RPC run-loop thread (rc=-2)."
            case -3: reason = "Invalid or unsupported listen address (rc=-3). For --connect-nvim, use a TCP \"host:port\" or absolute Unix-socket path on macOS."
            default: reason = "Unknown error (rc=\(rc))."
            }
            alert.informativeText = "\(reason)\nContext: \(context)."
            alert.alertStyle = .critical
            alert.addButton(withTitle: lastSession ? "Quit" : "Close")
            _ = alert.runModal()
            self.core.endFailedStart()
        }
    }


    /// Trigger a full redraw of the terminal view (e.g. after deminiaturize).
    func requestFullRedraw() {
        terminalView?.requestRedraw(nil)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()

        // Do NOT call core.stop() here.
        //
        // On macOS 15+, viewWillDisappear is called during window minimize
        // (before isMiniaturized becomes true). Calling core.stop() frees
        // Grid HashMaps (viewport, viewport_margins) while the display link
        // and MTKView draw callbacks still reference them → use-after-free.
        //
        // core.stop() is unnecessary for all termination paths:
        //   - Normal close: windowShouldClose → requestQuit → Neovim exits
        //     → onExitFromNvim → Darwin.exit() (process terminates).
        //   - Timeout: showNotRespondingDialog → Force Quit ends this session.
        //   - No core: windowShouldClose returns true, nothing to stop.
        //
        // ASSUMPTION: The current UI uses a single main window with one
        // ViewController. The view is never removed from its window except
        // at app termination. If a future design introduces multiple windows,
        // tab-based ViewController swapping, or view detachment, a new
        // explicit stop point (e.g. windowWillClose or a dedicated cleanup
        // method) must be added for the detached ViewController's core.
        //
        // Observers stay registered: this also runs on minimize, and the
        // tabline and agent notifications are sent only on change, so one
        // posted while minimized was lost for good.
    }

    deinit {
        for observer in [tablineUpdateObserver, tablineHideObserver, agentStatusObserver, bandObserver, titleBandObserver, edgeHairlineObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Present the `--dialog` dialog once, after the window exists so it can
        // host the sheet.
        if pendingConnectDialog && !connectDialogShown {
            connectDialogShown = true
            presentConnectionDialog()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Before the window shows, so the first layout already has the
        // toolbar's titlebar height.
        installTitlebarChromeIfNeeded()
        if let band = titleBand, titleObservation == nil, let window = view.window {
            titleObservation = window.observe(\.title, options: [.initial, .new]) { [weak band] window, _ in
                band?.title = window.title
            }
        }
        if titlebarLayout.captionless, titlebarReveal == nil, let window = view.window {
            titlebarReveal = WindowButtonHoverReveal(window: window, companion: sidebarView?.toggleButton)
            updateTitlebarRevealPin()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateTitlebarLayout()
        updateTitlebarEdge()
    }

    // MARK: - Titlebar edge

    /// Where window separators meet the band (`[window] titlebar_edge`).
    private func updateTitlebarEdge() {
        let band = titlebarBandHeight
        let scale = terminalView.backingScale
        guard band > 0, let renderer = terminalView.renderer else {
            terminalView.renderer?.separatorFadePx = 0
            edgeHairline?.isHidden = true
            return
        }
        // Only the part of the band that lies over the grid hides separators;
        // under titlebar tabs or a self-drawn title band the grid already
        // starts below the band.
        let gridTopPt = view.bounds.height - terminalView.frame.maxY + terminalView.gridInsetsPt.top
        let coveredPt = max(0, band - gridTopPt)
        // A captionless window shows no band, so there is no edge to border:
        // its separators fade under the hidden caption instead.
        let configured = ZonvieConfig.shared.window.titlebarEdge
        let edge = configured == .border && titlebarLayout.captionless ? .fade : configured
        if edge != .border { edgeHairline?.isHidden = true }
        switch edge {
        case .fade:
            renderer.separatorHardEdge = false
            renderer.separatorFadePx = Float(coveredPt * scale)
        case .none:
            renderer.separatorFadePx = 0
        case .border:
            renderer.separatorHardEdge = true
            renderer.separatorFadePx = Float((coveredPt * scale).rounded())
            let hairline = edgeHairline ?? installEdgeHairline()
            let insets = terminalView.gridInsetsPt
            let thicknessPt = 1 / scale
            hairline.frame = NSRect(x: terminalView.frame.minX + insets.left,
                                    y: view.bounds.height - band - thicknessPt,
                                    width: max(0, terminalView.frame.width - insets.left - insets.right),
                                    height: thicknessPt)
            hairline.isHidden = false
        }
    }

    private func installEdgeHairline() -> EdgeHairlineView {
        let hairline = EdgeHairlineView(frame: .zero)
        hairline.color = core.separatorColor()
        view.addSubview(hairline, positioned: .above, relativeTo: terminalView)
        edgeHairline = hairline
        edgeHairlineObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.colorschemeDidChangeNotification, object: core, queue: .main
        ) { [weak self, weak hairline] _ in
            guard let self, let hairline else { return }
            hairline.color = self.core.separatorColor()
        }
        return hairline
    }

    // MARK: - Transparent titlebar

    /// Height of the chrome band at the window top: the tab row under
    /// titlebar tabs, else the band the frontend draws.
    private var titlebarBandHeight: CGFloat {
        guard editorRunsUnderBand || drawsTitleBand, view.window != nil else { return 0 }
        switch titlebarLayout.windowKind {
        case .tabBar: return tabBarHeight
        case .captionless: return TitlebarBand.heightPt
        case .standard: preconditionFailure("a standard window has no band under the editor")
        }
    }

    private func updateTitlebarLayout() {
        // A title band also lies over the editor surface: its height comes
        // off the grid (titleBandInsetPt), whatever the tabline.
        guard editorRunsUnderBand || drawsTitleBand else { return }
        let band = titlebarBandHeight
        sidebarView?.topInset = band
        if dragBarHeightConstraint?.constant != band { dragBarHeightConstraint?.constant = band }
        if sidebarToggleCenterYConstraint?.constant != band / 2 { sidebarToggleCenterYConstraint?.constant = band / 2 }
        updateGridInsets()
    }

    /// A title band is transparent over the editor surface, so the band shows
    /// the very bg Metal draws (blur included); the grid starts below it.
    private var titleBandInsetPt: CGFloat { drawsTitleBand ? TitlebarBand.heightPt : 0 }

    /// The editor spans the window under a translucent sidebar; its grid
    /// starts beside the sidebar's visible part, which follows the slide.
    private func updateGridInsets() {
        // The edge's covered height depends on the grid top this sets.
        defer { updateTitlebarEdge() }
        // The "column" scrollbar's strip sits at the right edge of whatever
        // the chrome leaves, left of a right sidebar.
        let column = ZonvieConfig.shared.scrollbar.columnWidthPt
        if tabBarView != nil, editorRunsUnderBand {
            // Titlebar tabs float over the editor surface; the grid starts below them.
            terminalView.gridInsetsPt = (0, column, tabBarHeight)
            return
        }
        guard let sidebar = sidebarView else {
            // Native titlebar tabs, a menu or no tabline: the grid starts at
            // the editor top, under a captionless band.
            terminalView.gridInsetsPt = (0, column, titleBandInsetPt)
            return
        }
        guard editorRunsUnderBand else {
            // The editor sits beside the sidebar (its constraints), not under
            // it: only the column strip comes off the grid.
            terminalView.scrollbarInsetRightPt = 0
            terminalView.gridInsetsPt = (0, column, titleBandInsetPt)
            return
        }
        // Under a transparent titlebar the editor spans the window under the sidebar.
        // From the laid-out frame, hidden or not: the sidebar's room is held
        // from launch (as the side-by-side layout did), so the grid never
        // starts full width and the window snap never records that width.
        let covered = view.bounds.intersection(sidebar.frame).width
        terminalView.scrollbarInsetRightPt = sidebar.isRightSide ? covered : 0
        if sidebarSliding {
            // Mid-slide the grid keeps the open-sidebar width and only moves,
            // so Neovim is resized once (before opening, after closing) and
            // opening and closing are mirror images.
            let width = sidebarWidthPt
            terminalView.gridInsetsPt = sidebar.isRightSide ? (0, width + column, titleBandInsetPt) : (covered, width - covered + column, titleBandInsetPt)
        } else {
            terminalView.gridInsetsPt = sidebar.isRightSide ? (0, covered + column, titleBandInsetPt) : (covered, column, titleBandInsetPt)
        }
    }

    private var titlebarChromeInstalled = false
    /// Where the toggle sits: past the traffic lights for a left sidebar, or
    /// as far in from the right edge as the lights are from the left.
    private static let sidebarToggleLeftMarginPt: CGFloat = TitlebarBand.controlsWidthPt
    private static let sidebarToggleRightMarginPt: CGFloat = TitlebarBand.lightsLeftPt
    private static let sidebarToggleSizePt: CGFloat = 22

    /// The drag bar over a captionless window's band (titlebar tabs drag
    /// the window themselves), and the sidebar toggle when there is a sidebar.
    private func installTitlebarChromeIfNeeded() {
        guard titlebarLayout.drawsBand, !titlebarChromeInstalled, view.window != nil else { return }
        titlebarChromeInstalled = true
        if titlebarLayout.captionless { installDragBar() }
        if let sidebar = sidebarView { installSidebarToggle(sidebar) }
    }

    private func installDragBar() {
        let bar = TitlebarDragBar(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar, positioned: .above, relativeTo: terminalView)
        let height = bar.heightAnchor.constraint(equalToConstant: titlebarBandHeight)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            height,
        ])
        dragBar = bar
        dragBarHeightConstraint = height
    }

    /// No NSToolbar: on Tahoe a toolbar window gets the larger corner radius
    /// and the band grows. A plain button in the band keeps the window frame
    /// as it is.
    private func installSidebarToggle(_ sidebar: TabSidebarView) {
        let symbol = sidebar.isRightSide ? "sidebar.right" : "sidebar.left"
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle Sidebar")!,
                              target: self, action: #selector(toggleSidebar(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        // Topmost: the sidebar slides under it.
        view.addSubview(button, positioned: .above, relativeTo: nil)
        sidebar.toggleButton = button
        let side = sidebar.isRightSide
            ? button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.sidebarToggleRightMarginPt)
            : button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.sidebarToggleLeftMarginPt)
        let centerY = button.centerYAnchor.constraint(equalTo: view.topAnchor, constant: titlebarBandHeight / 2)
        NSLayoutConstraint.activate([
            side, centerY,
            button.widthAnchor.constraint(equalToConstant: Self.sidebarToggleSizePt),
            button.heightAnchor.constraint(equalToConstant: Self.sidebarToggleSizePt),
        ])
        sidebarToggleCenterYConstraint = centerY
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        guard let sidebar = sidebarView, let window = view.window else { return }
        sidebarCollapsed.toggle()
        let width = sidebarWidthPt
        var minSize = window.contentMinSize
        minSize.width += sidebarCollapsed ? -width : width
        window.contentMinSize = minSize
        // Visible for the whole slide; hidden once it has fully closed.
        if !sidebarCollapsed { sidebar.isHidden = !tablineShown }
        updateTitlebarRevealPin()
        let collapsing = sidebarCollapsed
        sidebarSliding = true
        updateGridInsets()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            let offset: CGFloat = collapsing ? width : 0
            sidebarEdgeConstraint?.animator().constant = sidebar.isRightSide ? offset : -offset
            view.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, self.sidebarCollapsed == collapsing else { return }
            if collapsing { sidebar.isHidden = true }
            self.sidebarSliding = false
            self.updateGridInsets()
        })
    }

    // MARK: - Tabline Notification Observers (shared across modes)

    private func setupTablineNotificationObservers() {
        // Only this session's core: every session posts the same names.
        tablineUpdateObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.tablineUpdateNotification,
            object: core,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo?[ZonvieCore.notificationInfoKey] as? ZonvieCore.TablineUpdateInfo else {
                ZonvieCore.appLog("[Tabline] WARNING: notification payload cast failed: \(String(describing: notification.userInfo))")
                return
            }
            self?.handleTablineUpdate(tabs: info.tabs, currentTab: info.currentTab)
        }

        tablineHideObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.tablineHideNotification,
            object: core,
            queue: .main
        ) { [weak self] _ in
            self?.handleTablineHide()
        }

        agentStatusObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.agentStatusNotification,
            object: core,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo?[ZonvieCore.notificationInfoKey] as? ZonvieCore.AgentStatusInfo else { return }
            self?.tabBarView?.setAgentState(handle: info.tabHandle, state: info.state)
            self?.sidebarView?.setAgentState(handle: info.tabHandle, state: info.state)
        }
    }

    private func handleTablineUpdate(tabs: [(handle: Int64, name: String, chunks: [TabChunk])], currentTab: Int64) {
        self.currentTabs = tabs
        tabBarView?.isHidden = false
        sidebarView?.isHidden = sidebarCollapsed
        tablineShown = true
        updateTitlebarRevealPin()
        updateGridInsets()
        tabBarView?.updateTabs(tabs.map { (handle: $0.handle, name: $0.name) }, currentTab: currentTab)
        sidebarView?.updateTabs(tabs, currentTab: currentTab)
    }

    private func handleTablineHide() {
        tabBarView?.isHidden = true
        sidebarView?.isHidden = true
        tablineShown = false
        updateTitlebarRevealPin()
        updateGridInsets()
    }

    /// An open left sidebar sits under the traffic lights, so they and the
    /// toggle stay shown; otherwise both show on hover.
    private func updateTitlebarRevealPin() {
        guard let sidebar = sidebarView else { return }
        titlebarReveal?.pinned = !sidebar.isRightSide && tablineShown && !sidebarCollapsed
    }

    // MARK: - Tab Bar (titlebar mode)

    private func setupTabBar() {
        // The grid starts below the tabs: by the view's top constraint, or by
        // its inset when the surface runs under them (updateGridInsets).
        precondition(titlebarLayout.editorBelowBand, "titlebar tabs without editorBelowBand")
        let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: tabBarHeight))
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.transparentBackground = editorRunsUnderBand
        view.addSubview(tabBar)

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: tabBarHeight),
        ])

        // Wire up callbacks
        tabBar.onTabSelected = { [weak self] handle in
            self?.selectTab(handle: handle)
        }

        tabBar.onTabClosed = { [weak self] handle in
            self?.closeTab(handle: handle)
        }

        tabBar.onNewTabRequested = { [weak self] in
            self?.createNewTab()
        }

        tabBar.onTabMoved = { [weak self] (fromIndex: Int, toIndex: Int) in
            self?.moveTab(from: fromIndex, to: toIndex)
        }

        tabBar.onTabExternalized = { [weak self] handle, dropPoint in
            self?.externalizeTab(handle: handle, dropPoint: dropPoint)
        }

        self.tabBarView = tabBar
    }

    // MARK: - Sidebar (sidebar mode)

    private func setupSidebar() {
        let config = ZonvieConfig.shared
        let isRight = config.tabline.sidebarPosition == "right"

        let sidebar = TabSidebarView(frame: .zero)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.isRightSide = isRight
        view.addSubview(sidebar)

        // Debug: log layer transparency chain
        ZonvieCore.appLog("[Sidebar] blur=\(config.blurEnabled) sidebar.layer exists=\(sidebar.layer != nil) sidebar.layer.isOpaque=\(sidebar.layer?.isOpaque ?? true) sidebar.isOpaque=\(sidebar.isOpaque) view.layer.isOpaque=\(view.layer?.isOpaque ?? true)")

        // Wire callbacks
        sidebar.onTabSelected = { [weak self] handle in self?.selectTab(handle: handle) }
        sidebar.onTabClosed = { [weak self] handle in self?.closeTab(handle: handle) }
        sidebar.onNewTabRequested = { [weak self] in self?.createNewTab() }
        sidebar.onTabExternalized = { [weak self] handle, dropPoint in
            self?.externalizeTab(handle: handle, dropPoint: dropPoint)
        }
        sidebar.onTabMoved = { [weak self] (fromIndex: Int, toIndex: Int) in
            self?.moveTab(from: fromIndex, to: toIndex)
        }

        self.sidebarView = sidebar

        // A self-drawn band lies clear over the top of the editor's side (its
        // height comes off the grid, titleBandInsetPt); the sidebar still
        // reaches the window top, its list below the same band height.
        if drawsTitleBand {
            installTitleBand(beside: sidebar)
            sidebar.topInset = TitlebarBand.heightPt
        }
        let topConstraint = terminalView.topAnchor.constraint(equalTo: view.topAnchor)
        // Collapsing slides the sidebar off its window edge at full width.
        let edgeConstraint = isRight
            ? sidebar.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            : sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        sidebarEdgeConstraint = edgeConstraint
        let widthConstraint = sidebar.widthAnchor.constraint(equalToConstant: sidebarWidthPt)
        sidebarWidthConstraint = widthConstraint

        if isRight {
            NSLayoutConstraint.activate([
                edgeConstraint,
                sidebar.topAnchor.constraint(equalTo: view.topAnchor),
                sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                widthConstraint,

                terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: editorRunsUnderBand ? view.trailingAnchor : sidebar.leadingAnchor),
                topConstraint,
                terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                edgeConstraint,
                sidebar.topAnchor.constraint(equalTo: view.topAnchor),
                sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                widthConstraint,

                terminalView.leadingAnchor.constraint(equalTo: editorRunsUnderBand ? view.leadingAnchor : sidebar.trailingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                topConstraint,
                terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        installSidebarResizeHandle(sidebar)
    }

    /// Inside the sidebar's inner edge, so it never covers the editor or
    /// its scrollbar.
    private func installSidebarResizeHandle(_ sidebar: TabSidebarView) {
        let handle = SidebarResizeHandle(frame: .zero)
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.isRightSide = sidebar.isRightSide
        handle.currentWidthPt = { [weak self] in self?.sidebarWidthPt ?? 0 }
        handle.onWidthChange = { [weak self] in self?.setSidebarWidth($0) }
        view.addSubview(handle, positioned: .above, relativeTo: sidebar)
        sidebar.resizeHandle = handle
        handle.isHidden = sidebar.isHidden
        let edge = sidebar.isRightSide
            ? handle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor)
            : handle.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        NSLayoutConstraint.activate([
            edge,
            handle.widthAnchor.constraint(equalToConstant: Self.sidebarResizeHandleWidthPt),
            handle.topAnchor.constraint(equalTo: sidebar.topAnchor),
            handle.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])
    }

    /// Clamped to [120pt, half the window]; the window's minimum width
    /// tracks the sidebar so the editor keeps its own minimum.
    private func setSidebarWidth(_ proposedPt: CGFloat) {
        guard let window = view.window, !sidebarCollapsed, !sidebarSliding else { return }
        let maxPt = max(Self.sidebarMinWidthPt, (view.bounds.width / 2).rounded(.down))
        let widthPt = min(max(proposedPt.rounded(), Self.sidebarMinWidthPt), maxPt)
        guard widthPt != sidebarWidthPt else { return }
        var minSize = window.contentMinSize
        minSize.width += widthPt - sidebarWidthPt
        window.contentMinSize = minSize
        sidebarWidthPt = widthPt
        sidebarWidthConstraint?.constant = widthPt
        view.layoutSubtreeIfNeeded()
        updateGridInsets()
    }

    /// The band spans the editor's side, following the sidebar's slide; a
    /// closed sidebar, or none, leaves it the full width, under the lights
    /// (and toggle).
    private func installTitleBand(beside sidebar: TabSidebarView?) {
        let reservePt = sidebar == nil
            ? TitlebarBand.controlsWidthPt
            : Self.sidebarToggleLeftMarginPt + Self.sidebarToggleSizePt + 8
        let band = TitleBandView(leadingReservePt: reservePt)
        band.translatesAutoresizingMaskIntoConstraints = false
        band.setTitleColor(.labelColor)
        view.addSubview(band)
        var leading = view.leadingAnchor
        var trailing = view.trailingAnchor
        if let sidebar {
            if sidebar.isRightSide { trailing = sidebar.leadingAnchor } else { leading = sidebar.trailingAnchor }
        }
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: leading),
            band.trailingAnchor.constraint(equalTo: trailing),
            band.topAnchor.constraint(equalTo: view.topAnchor),
            band.heightAnchor.constraint(equalToConstant: TitlebarBand.heightPt),
        ])
        titleBand = band
    }

    private static func rgbColor(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    // MARK: - Public Tab Bar Control




    // MARK: - Tab Actions

    func selectTab(handle: Int64) {
        // Find the tab index (1-based for Neovim)
        guard let index = currentTabs.firstIndex(where: { $0.handle == handle }) else {
            return
        }
        // Use nvim_command API so it works even in terminal mode
        let tabNumber = index + 1
        core?.sendCommand("\(tabNumber)tabnext")
    }

    func closeTab(handle: Int64) {
        // Find the tab index (1-based for Neovim)
        guard let index = currentTabs.firstIndex(where: { $0.handle == handle }) else {
            return
        }
        // Use nvim_command API so it works even in terminal mode
        let tabNumber = index + 1
        core?.sendCommand("\(tabNumber)tabclose")
    }

    func createNewTab() {
        // Use nvim_command API so it works even in terminal mode
        core?.sendCommand("tabnew")
    }

    /// `toIndex` is the drop insertion index in the pre-move tab list. The
    /// command is the core's, shared with Windows.
    private func moveTab(from fromIndex: Int, to toIndex: Int) {
        core?.moveTab(from: fromIndex, toDropIndex: toIndex, tabCount: currentTabs.count)
    }

    private func externalizeTab(handle: Int64, dropPoint: NSPoint) {
        ZonvieCore.appLog("[EXTERNALIZE] externalizeTab called handle=\(handle) dropPoint=\(dropPoint)")
        guard let core = core else {
            ZonvieCore.appLog("[EXTERNALIZE] core is nil, aborting")
            return
        }

        // Find the tab index
        guard let index = currentTabs.firstIndex(where: { $0.handle == handle }) else {
            ZonvieCore.appLog("[EXTERNALIZE] tab handle \(handle) not found in currentTabs")
            return
        }

        // Set the pending external window position so it appears at the drop point
        core.setPendingExternalWindowPosition(dropPoint)

        // The core's command, shared with Windows: it switches to the tab and
        // opens its only window externally in one go.
        core.externalizeTab(index: index)
    }
}

/// One-pixel line along the titlebar band's bottom; clicks pass through to
/// the editor and drag bar under it.
final class EdgeHairlineView: NSView {
    var color: NSColor = .separatorColor {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
