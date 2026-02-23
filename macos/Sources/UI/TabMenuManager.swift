import AppKit

/// Manages the "Tab" NSMenu for the "menu" tabline style.
/// Observes tabline notifications and updates menu items dynamically.
final class TabMenuManager {
    private let menu: NSMenu
    private weak var viewController: ViewController?

    private var tablineUpdateObserver: Any?
    private var tablineHideObserver: Any?

    private var currentTabs: [(handle: Int64, name: String)] = []
    private var currentTabHandle: Int64 = 0

    // Fixed menu item count before dynamic tab list (New Tab, Close Tab, separator)
    private let fixedItemCount = 3

    init(menu: NSMenu, viewController: ViewController) {
        self.menu = menu
        self.viewController = viewController

        // Build initial fixed items
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(handleNewTab(_:)), keyEquivalent: "t")
        newTabItem.target = self

        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(handleCloseTab(_:)), keyEquivalent: "w")
        closeTabItem.target = self

        menu.removeAllItems()
        menu.addItem(newTabItem)
        menu.addItem(closeTabItem)
        menu.addItem(NSMenuItem.separator())

        // Observe tabline notifications
        tablineUpdateObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.tablineUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.object as? ZonvieCore.TablineUpdateInfo else {
                ZonvieCore.appLog("[Tabline] WARNING: menu notification object cast failed: \(String(describing: notification.object))")
                return
            }
            self?.updateMenu(tabs: info.tabs, currentTab: info.currentTab)
        }

        tablineHideObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.tablineHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearTabItems()
        }
    }

    deinit {
        if let o = tablineUpdateObserver { NotificationCenter.default.removeObserver(o) }
        if let o = tablineHideObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func updateMenu(tabs: [(handle: Int64, name: String)], currentTab: Int64) {
        currentTabs = tabs
        currentTabHandle = currentTab

        // Remove old dynamic tab items (everything after fixed items)
        while menu.items.count > fixedItemCount {
            menu.removeItem(at: fixedItemCount)
        }

        // Add tab items
        for (index, tab) in tabs.enumerated() {
            let displayName = tab.name.isEmpty ? "[No Name]" : (tab.name as NSString).lastPathComponent
            let item = NSMenuItem(title: displayName, action: #selector(handleSelectTab(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = (tab.handle == currentTab) ? .on : .off

            // Keyboard shortcut for first 9 tabs: Cmd+1 through Cmd+9
            if index < 9 {
                item.keyEquivalent = "\(index + 1)"
                item.keyEquivalentModifierMask = .command
            }

            menu.addItem(item)
        }
    }

    private func clearTabItems() {
        while menu.items.count > fixedItemCount {
            menu.removeItem(at: fixedItemCount)
        }
    }

    // MARK: - Actions

    @objc private func handleNewTab(_ sender: NSMenuItem) {
        viewController?.createNewTab()
    }

    @objc private func handleCloseTab(_ sender: NSMenuItem) {
        viewController?.core?.sendCommand("tabclose")
    }

    @objc private func handleSelectTab(_ sender: NSMenuItem) {
        let tabNumber = sender.tag + 1
        viewController?.core?.sendCommand("\(tabNumber)tabnext")
    }
}
