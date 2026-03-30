import Cocoa
import MetalKit

final class ViewController: NSViewController {
    private var terminalView: MetalTerminalView!
    private(set) var core: ZonvieCore!
    private var tabBarView: TabBarView?
    private var sidebarView: TabSidebarView?

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

        // Create core (init takes no args)
        core = ZonvieCore()

        // Wire both directions
        core.terminalView = terminalView
        terminalView.core = core

        // Enable ext_popupmenu if configured (must be before start())
        if config.popup.external {
            core.setExtPopupmenu(true)
        }

        // Enable ext_messages if configured (must be before start())
        if config.messages.external {
            core.setExtMessages(true)
        }

        // Delay start to ensure RunLoop is running (needed for SSH password dialog)
        let nvimPath = cliNvimPath ?? config.neovim.path
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // rows/cols initial is decided by Zig core; current bootstrap uses 1x1.
            _ = self.core.start(nvimPath: nvimPath, rows: 1, cols: 1)
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
