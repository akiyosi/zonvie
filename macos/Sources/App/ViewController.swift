import Cocoa
import MetalKit

final class ViewController: NSViewController {
    private var terminalView: MetalTerminalView!
    private(set) var core: ZonvieCore!
    private var tabBarView: TabBarView?

    // Height of the Chrome-style tab bar
    private let tabBarHeight: CGFloat = 38

    // Notification observers for tabline
    private var tablineUpdateObserver: Any?
    private var tablineHideObserver: Any?

    // Current tab list for lookup
    private var currentTabs: [(handle: Int64, name: String)] = []

    override func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
        if ZonvieConfig.shared.blurEnabled {
            self.view.layer?.isOpaque = false
            self.view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = ZonvieConfig.shared

        // When blur is enabled, we use CGSSetWindowBackgroundBlurRadius (private API)
        // instead of NSVisualEffectView for better control over blur radius.
        // The window must be transparent for blur to show through.

        terminalView = MetalTerminalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        terminalView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(terminalView)

        // Setup Chrome-style tab bar if ext_tabline is enabled (config file OR CLI flag)
        let hasExtTabline = config.tabline.external || CommandLine.arguments.contains("--exttabline")
        if hasExtTabline {
            setupTabBar()
            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: view.topAnchor, constant: tabBarHeight),
                terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        } else {
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
        let nvimPath = config.neovim.path
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // rows/cols initial is decided by Zig core; current bootstrap uses 1x1.
            _ = self.core.start(nvimPath: nvimPath, rows: 1, cols: 1)
        }
    }


    override func viewWillDisappear() {
        super.viewWillDisappear()
        core?.stop()

        // Remove notification observers
        if let observer = tablineUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = tablineHideObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Tab Bar

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

        // Setup notification observers for tabline updates
        tablineUpdateObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.tablineUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let tabs = notification.userInfo?["tabs"] as? [(handle: Int64, name: String)],
                  let currentTab = notification.userInfo?["currentTab"] as? Int64 else {
                return
            }
            self?.updateTabBar(tabs: tabs, currentTab: currentTab)
        }

        tablineHideObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.tablineHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hideTabBar()
        }
    }

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

    private func selectTab(handle: Int64) {
        // Find the tab index (1-based for Neovim)
        guard let index = currentTabs.firstIndex(where: { $0.handle == handle }) else {
            return
        }
        // Use nvim_command API so it works even in terminal mode
        let tabNumber = index + 1
        core?.sendCommand("\(tabNumber)tabnext")
    }

    private func closeTab(handle: Int64) {
        // Find the tab index (1-based for Neovim)
        guard let index = currentTabs.firstIndex(where: { $0.handle == handle }) else {
            return
        }
        // Use nvim_command API so it works even in terminal mode
        let tabNumber = index + 1
        core?.sendCommand("\(tabNumber)tabclose")
    }

    private func createNewTab() {
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
        // This avoids race condition between nvim_input (tab switch) and nvim_command (Lua).
        // The Lua script:
        // 1. Switch to the target tab
        // 2. Check if tab has multiple windows (split) - abort if so
        // 3. Get current window dimensions
        // 4. Create new split with empty buffer (so main window isn't empty)
        // 5. Externalize the original window
        let tabNumber = index + 1
        let luaScript = "lua vim.cmd('\(tabNumber)tabnext'); local tp=vim.api.nvim_get_current_tabpage(); local ws=vim.api.nvim_tabpage_list_wins(tp); if #ws>1 then vim.notify('Cannot externalize: split window',vim.log.levels.WARN); return end; local w=ws[1]; local W=vim.api.nvim_win_get_width(w); local H=vim.api.nvim_win_get_height(w); vim.cmd('vnew'); vim.api.nvim_win_set_config(w,{external=true,width=W,height=H}); vim.api.nvim_set_current_win(w)"
        ZonvieCore.appLog("[EXTERNALIZE] sending Lua script to nvim: \(luaScript)")
        core.sendCommand(luaScript)
    }
}
