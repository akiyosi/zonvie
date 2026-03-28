import Cocoa
import MetalKit

final class ViewController: NSViewController {
    private var terminalView: MetalTerminalView!
    private(set) var workspaceManager: WorkspaceManager!

    /// Active core convenience accessor (delegates to workspace manager).
    var core: ZonvieCore? {
        workspaceManager?.activeCore
    }

    private var tabBarView: TabBarView?
    private var sidebarView: TabSidebarView?
    private(set) var overlayController: WorkspaceOverlayController?
    private var nvimExitObserver: Any?
    private var nvimReadyObserver: Any?
    private var enterTileViewObserver: Any?
    private var magnifyEventMonitor: Any?

    /// When set, the tile at this index is waiting for nvim to become ready
    /// (SSH/devcontainer connecting). animateToFullscreen on neovimReady.
    private var pendingFullscreenTileIndex: Int?


    // Height of the Chrome-style tab bar
    private let tabBarHeight: CGFloat = 36

    // Notification observers for tabline
    private var tablineUpdateObserver: Any?
    private var tablineHideObserver: Any?

    // Current tab list for lookup
    private var currentTabs: [(handle: Int64, name: String)] = []

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
                terminalView.topAnchor.constraint(equalTo: view.topAnchor, constant: tabBarHeight),
                terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])

        case .sidebar:
            setupSidebar()
            // Constraints are set up inside setupSidebar()

        case .menu:
            // Menu mode: no tab UI in the window, full-size terminal.
            // Notification observers are set up for currentTabs tracking.
            setupTablineNotificationObservers()
            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: view.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])

        case nil:
            // No ext_tabline: full-size terminal
            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: view.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        // Create workspace manager with first tile
        workspaceManager = WorkspaceManager()
        workspaceManager.viewController = self
        workspaceManager.terminalView = terminalView

        // Create core for tile 0 and wire it up
        let initialCore = ZonvieCore()
        workspaceManager.attachCore(initialCore, at: 0)

        initialCore.terminalView = terminalView
        terminalView.core = initialCore

        // Enable ext_popupmenu if configured (must be before start())
        if config.popup.external {
            initialCore.setExtPopupmenu(true)
        }

        // Enable ext_messages if configured (must be before start())
        if config.messages.external {
            initialCore.setExtMessages(true)
        }

        // Set up workspace overlay controller (handles pinch, animation, visibility)
        overlayController = WorkspaceOverlayController(
            hostView: view,
            workspaceManager: workspaceManager,
            snapshotSource: terminalView,
            delegate: self
        )

        // Observe nvim process exits — show tile view or terminate app
        nvimExitObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.nvimExitedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let info = notification.object as? ZonvieCore.NvimExitInfo else { return }
            self.handleNvimExited(info: info)
        }

        // Observe neovimReady — for SSH/devcontainer tiles waiting to go fullscreen
        nvimReadyObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.neovimReadyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            guard let pendingIndex = self.pendingFullscreenTileIndex else {
                ZonvieCore.appLog("[Workspace] neovimReady received but pendingFullscreenTileIndex is nil — skipping")
                return
            }
            ZonvieCore.appLog("[Workspace] neovimReady: pendingIndex=\(pendingIndex) activeTileIndex=\(self.workspaceManager.activeTileIndex)")
            // The pending tile's nvim is now ready — go fullscreen
            self.pendingFullscreenTileIndex = nil
            if self.workspaceManager.activeTileIndex == pendingIndex {
                self.overlayController?.resetPanOffset()
                self.overlayController?.animateToFullscreen()
                ZonvieCore.appLog("[Workspace] animateToFullscreen triggered for tile \(pendingIndex)")
            }
        }

        // Observe tile view requests from external windows (pinch gesture on ExternalGridView)
        enterTileViewObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.enterTileViewNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Only enter tile view if currently fullscreen
            if self.workspaceManager.scale >= 1.0 {
                self.overlayController?.animateToTileGrid()
                // Bring main window to front so user can interact with tile view
                self.view.window?.makeKeyAndOrderFront(nil)
            }
        }

        // Monitor magnify events app-wide so pinch-out on the main window
        // triggers tile view even when an external window has focus.
        // NSMagnificationGestureRecognizer does not fire on a non-key window,
        // so we intercept the raw magnify event here instead.
        magnifyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self = self else { return event }
            // Only handle events targeting the main window
            guard event.window === self.view.window else { return event }
            // Only trigger when the main window is NOT key (gesture recognizer handles the key case)
            guard self.view.window?.isKeyWindow == false else { return event }
            // Only enter tile view from fullscreen on pinch-out
            if self.workspaceManager.scale >= 1.0 && event.magnification < -0.02 {
                self.view.window?.makeKeyAndOrderFront(nil)
                self.overlayController?.animateToTileGrid()
                return nil // consume the event
            }
            return event
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
        // rows/cols here are placeholders (1×1). The RPC thread blocks in
        // waitForLayoutReady() until MetalTerminalView signals
        // notifyInitialLayout() with the actual rows/cols computed from
        // the post-layout drawable size, so nvim_ui_attach is sent with the
        // correct dimensions on the first try.
        let nvimPath = cliNvimPath ?? config.neovim.path
        let sshEnabled = sshModeEnabled || config.neovim.ssh
        if sshEnabled || devcontainerModeEnabled {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                _ = self.workspaceManager.activeCore?.start(nvimPath: nvimPath, rows: 1, cols: 1)
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                _ = self.workspaceManager.activeCore?.start(nvimPath: nvimPath, rows: 1, cols: 1)
            }
        }
    }

    // MARK: - Nvim Exit Handling

    private func handleNvimExited(info: ZonvieCore.NvimExitInfo) {
        let exitedCore = info.core
        let exitCode = info.exitCode

        // Show error alert for non-zero exit (connection failure, crash, etc.)
        if exitCode != 0 {
            ZonvieCore.appLog("[Workspace] showing error alert: \(info.connectionName) code=\(exitCode)")

            // Ensure window is visible (SSH mode hides it until ready)
            if let window = view.window, !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }

            let alert = NSAlert()
            if exitCode == 255 && info.core.workspaceConfig?.isSSH == true {
                alert.messageText = "SSH Connection Failed"
                let host = info.core.workspaceConfig?.sshHost ?? "unknown"
                alert.informativeText = "Could not connect to \(host).\nConnection timed out or host is unreachable."
            } else {
                alert.messageText = "Session ended unexpectedly"
                alert.informativeText = "\"\(info.connectionName)\" exited with code \(exitCode)."
            }
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }

        // Clear the tile that held this core
        workspaceManager.clearTile(for: exitedCore)

        if workspaceManager.hasOccupiedTiles {
            // Other sessions still running — show tile view
            ZonvieCore.appLog("[Workspace] nvim exited (code=\(exitCode)), other sessions remain — showing tile view")
            if workspaceManager.scale >= 1.0 {
                if let nextIndex = workspaceManager.firstOccupiedTileIndex {
                    workspaceManager.switchToTile(at: nextIndex)
                }
            }
            overlayController?.animateToTileGrid()
        } else if exitCode != 0 {
            // Error exit, no other sessions — show tile view so user can retry
            ZonvieCore.appLog("[Workspace] nvim exited with error (code=\(exitCode)), no sessions — showing tile view")
            overlayController?.animateToTileGrid()
        } else {
            // Normal exit, no sessions left — terminate app
            ZonvieCore.appLog("[Workspace] nvim exited normally, no sessions remain — terminating")
            ZonvieCore.terminateApp()
        }
    }

    // MARK: - Connection Menu

    private func showConnectionMenu(for tileIndex: Int) {
        ZonvieCore.appLog("[Workspace] showConnectionMenu: tileIndex=\(tileIndex) currentTiles=\(workspaceManager.tiles.count)")
        let menu = ConnectionMenuViewController()
        menu.onConnect = { [weak self] config in
            guard let self = self else { return }
            ZonvieCore.appLog("[Workspace] onConnect: tileIndex=\(tileIndex) name=\(config.name) isSSH=\(config.isSSH) isDC=\(config.isDevcontainer)")
            // Add tiles up to the requested index
            while tileIndex >= self.workspaceManager.tiles.count {
                self.workspaceManager.addTile(config: config)
            }
            // Update config if tile already exists
            self.workspaceManager.setTileConfig(at: tileIndex, config: config)
            self.workspaceManager.startTile(at: tileIndex)

            if config.isSSH || config.isDevcontainer {
                // SSH/devcontainer: stay in tile view until nvim is ready.
                // neovimReadyNotification will trigger animateToFullscreen.
                self.workspaceManager.switchToTile(at: tileIndex)
                self.overlayController?.setNeedsDisplay()
                self.pendingFullscreenTileIndex = tileIndex
                ZonvieCore.appLog("[Workspace] SSH/devcontainer tile \(tileIndex) started, pendingFullscreenTileIndex set")
            } else {
                // Local: switch and go fullscreen immediately
                ZonvieCore.appLog("[Workspace] onConnect: local tile \(tileIndex), switching and animating to fullscreen")
                self.workspaceManager.switchToTile(at: tileIndex)
                self.overlayController?.resetPanOffset()
                self.overlayController?.animateToFullscreen()
            }
        }
        presentAsSheet(menu)
    }

    /// Request closing a tile's nvim session via the workspace overlay close button.
    /// Uses the same quit flow as the window close button: checks for unsaved
    /// buffers and shows a confirmation dialog if needed.
    private func requestCloseTile(at index: Int) {
        guard index >= 0, index < workspaceManager.tiles.count else { return }
        guard let core = workspaceManager.tiles[index].core else { return }
        ZonvieCore.appLog("[Workspace] requestCloseTile index=\(index)")
        core.requestQuit()
    }

    /// Called from Workspaces menu "New Session..." item.
    /// Opens the connection menu for the first empty tile slot.
    func showNewSessionFromMenu() {
        // Find the first empty slot
        var targetIndex = workspaceManager.tiles.count
        for (i, tile) in workspaceManager.tiles.enumerated() {
            if !tile.isOccupied {
                targetIndex = i
                break
            }
        }
        // Show tile grid, then open the connection menu
        if workspaceManager.scale >= 1.0 {
            overlayController?.animateToTileGrid()
        }
        showConnectionMenu(for: targetIndex)
    }

    /// Called from Workspaces menu to switch to an active session.
    func selectSessionFromMenu(at index: Int) {
        guard index >= 0, index < workspaceManager.tiles.count else { return }
        guard workspaceManager.tiles[index].isOccupied else { return }
        workspaceManager.switchToTile(at: index)
        overlayController?.resetPanOffset()
        overlayController?.animateToFullscreen()
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
        //   - Timeout: showNotRespondingDialog → confirmQuit → Darwin.exit().
        //   - No core: windowShouldClose returns true, nothing to stop.
        //
        // ASSUMPTION: The current UI uses a single main window with one
        // ViewController. The view is never removed from its window except
        // at app termination. If a future design introduces multiple windows,
        // tab-based ViewController swapping, or view detachment, a new
        // explicit stop point (e.g. windowWillClose or a dedicated cleanup
        // method) must be added for the detached ViewController's core.

        // Remove notification observers and nil tokens so viewDidAppear can re-register
        if let observer = tablineUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
            tablineUpdateObserver = nil
        }
        if let observer = tablineHideObserver {
            NotificationCenter.default.removeObserver(observer)
            tablineHideObserver = nil
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Re-register observers that were removed in viewWillDisappear (e.g., after minimize/restore)
        if tablineUpdateObserver == nil {
            setupTablineNotificationObservers()
        }
        overlayController?.invalidateAnimation()
    }

    // MARK: - Tabline Notification Observers (shared across modes)

    private func setupTablineNotificationObservers() {
        tablineUpdateObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.tablineUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.object as? ZonvieCore.TablineUpdateInfo else {
                ZonvieCore.appLog("[Tabline] WARNING: notification object cast failed: \(String(describing: notification.object))")
                return
            }
            self?.handleTablineUpdate(tabs: info.tabs, currentTab: info.currentTab)
        }

        tablineHideObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.tablineHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleTablineHide()
        }
    }

    private func handleTablineUpdate(tabs: [(handle: Int64, name: String)], currentTab: Int64) {
        self.currentTabs = tabs
        tabBarView?.isHidden = false
        sidebarView?.isHidden = false
        tabBarView?.updateTabs(tabs, currentTab: currentTab)
        sidebarView?.updateTabs(tabs, currentTab: currentTab)
    }

    private func handleTablineHide() {
        tabBarView?.isHidden = true
        sidebarView?.isHidden = true
    }

    // MARK: - Tab Bar (titlebar mode)

    private func setupTabBar() {
        let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: tabBarHeight))
        tabBar.translatesAutoresizingMaskIntoConstraints = false
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

        setupTablineNotificationObservers()
    }

    // MARK: - Sidebar (sidebar mode)

    private func setupSidebar() {
        let config = ZonvieConfig.shared
        let sidebarWidth = CGFloat(config.tabline.sidebarWidth)
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

        if isRight {
            NSLayoutConstraint.activate([
                sidebar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                sidebar.topAnchor.constraint(equalTo: view.topAnchor),
                sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth),

                terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                terminalView.topAnchor.constraint(equalTo: view.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                sidebar.topAnchor.constraint(equalTo: view.topAnchor),
                sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth),

                terminalView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: view.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        setupTablineNotificationObservers()
    }

    // MARK: - Public Tab Bar Control

    /// Update tab bar with new tab list
    func updateTabBar(tabs: [(handle: Int64, name: String)], currentTab: Int64) {
        self.currentTabs = tabs
        tabBarView?.updateTabs(tabs, currentTab: currentTab)
    }

    /// Hide the tab bar (when ext_tabline is disabled or showtabline=0)
    func hideTabBar() {
        tabBarView?.isHidden = true
    }

    /// Show the tab bar
    func showTabBar() {
        tabBarView?.isHidden = false
    }

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

    private func moveTab(from fromIndex: Int, to toIndex: Int) {
        // Neovim :tabmove uses 0-based position
        // :tabmove 0 moves to first position
        // :tabmove N moves after tab N
        var newPos: Int
        if toIndex == 0 {
            newPos = 0
        } else if toIndex >= currentTabs.count {
            newPos = currentTabs.count
        } else {
            if toIndex > fromIndex {
                newPos = toIndex - 1
            } else {
                newPos = toIndex - 1
            }
        }
        // Use nvim_command API so it works even in terminal mode
        core?.sendCommand("tabmove \(newPos)")
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

        // Execute single Lua script that does both tab switch and externalization atomically.
        // Uses nvim_open_win to create a new external window instead of vnew + nvim_win_set_config.
        // In ext_windows mode, vnew would trigger win_split which creates another external window.
        // The Lua script:
        // 1. Switch to the target tab
        // 2. Check if tab has multiple windows (split) - abort if so
        // 3. Get the window's buffer, cursor position, and dimensions
        // 4. Create a new external window with nvim_open_win showing the same buffer
        // 5. Replace the original window's buffer with a scratch buffer
        let tabNumber = index + 1
        let luaScript = "lua vim.cmd('\(tabNumber)tabnext'); local tp=vim.api.nvim_get_current_tabpage(); local ws=vim.api.nvim_tabpage_list_wins(tp); if #ws>1 then vim.notify('Cannot externalize: split window',vim.log.levels.WARN); return end; local w=ws[1]; local buf=vim.api.nvim_win_get_buf(w); local cur=vim.api.nvim_win_get_cursor(w); local W=vim.api.nvim_win_get_width(w); local H=vim.api.nvim_win_get_height(w); local ew=vim.api.nvim_open_win(buf,true,{external=true,width=W,height=H}); vim.api.nvim_win_set_cursor(ew,cur); vim.api.nvim_win_set_buf(w,vim.api.nvim_create_buf(true,true))"
        ZonvieCore.appLog("[EXTERNALIZE] sending Lua script to nvim: \(luaScript)")
        core.sendCommand(luaScript)
    }
}

// MARK: - WorkspaceOverlayDelegate

extension ViewController: WorkspaceOverlayDelegate {
    func overlayDidSelectTile(at index: Int) {
        ZonvieCore.appLog("[Workspace] overlayDidSelectTile: index=\(index)")
        workspaceManager.switchToTile(at: index)
        overlayController?.resetPanOffset()
        overlayController?.animateToFullscreen()
    }

    func overlayDidRequestNewTile(at index: Int) {
        ZonvieCore.appLog("[Workspace] overlayDidRequestNewTile: index=\(index)")
        showConnectionMenu(for: index)
    }

    func overlayDidRequestCloseTile(at index: Int) {
        ZonvieCore.appLog("[Workspace] overlayDidRequestCloseTile: index=\(index)")
        requestCloseTile(at: index)
    }

    func overlayDidRequestDismiss() {
        ZonvieCore.appLog("[Workspace] overlayDidRequestDismiss: activeTile occupied=\(workspaceManager.activeTile.isOccupied)")
        guard workspaceManager.activeTile.isOccupied else { return }
        overlayController?.resetPanOffset()
        overlayController?.animateToFullscreen()
    }

    func overlayFirstResponderOnDismiss() -> NSView? {
        return terminalView
    }

    func overlayWillEnterTileView() {
        // Make main window key BEFORE hiding external windows.
        // If the focused external window is hidden first, macOS may activate
        // another app's window instead of the main Zonvie window.
        view.window?.makeKeyAndOrderFront(nil)
        core?.hideNormalExternalWindows()
    }

    func overlayDidExitTileView() {
        // Restore external windows for the newly active core
        core?.showNormalExternalWindows()
    }
}
