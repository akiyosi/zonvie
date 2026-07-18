import AppKit

/// Maintains one top-level menu-bar menu per session window (the session name is
/// the menu title). Rebuilt whenever the session list, names, or key window
/// change. Each session's submenu activates (brings its window front) or closes
/// it; the session whose window is key is marked.
///
/// (Phase 3 will populate each submenu with that session's nvim tabpages.)
final class SessionMenuController {
    private weak var mainMenu: NSMenu?

    /// Top-level items this controller owns (appended after the app's fixed
    /// menus). Tracked so a rebuild removes exactly its own items.
    private var sessionItems: [NSMenuItem] = []
    private var keyObserver: Any?
    private var resignObserver: Any?
    private var rebuildScheduled = false

    init(mainMenu: NSMenu) {
        self.mainMenu = mainMenu

        SessionManager.shared.onChange = { [weak self] in self?.scheduleRebuild() }

        // Key-window changes flip which session is marked active.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRebuild() }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRebuild() }

        rebuild()
    }

    deinit {
        if let o = keyObserver { NotificationCenter.default.removeObserver(o) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Coalesce rebuilds onto the next runloop tick. Key-window notifications
    /// fire *synchronously* inside AppKit's window-activation machinery (e.g.
    /// resignKeyWindow during makeKeyAndOrderFront); mutating the menu there
    /// throws ("Item to be removed is not in the menu"). Deferring avoids
    /// touching the menu mid-transition and collapses bursts into one rebuild.
    private func scheduleRebuild() {
        if rebuildScheduled { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rebuildScheduled = false
            self.rebuild()
        }
    }

    private func rebuild() {
        guard let mainMenu = mainMenu else { return }

        // Guard each removal: an item may already be detached if the menu was
        // rebuilt out from under us.
        for item in sessionItems where item.menu === mainMenu {
            mainMenu.removeItem(item)
        }
        sessionItems.removeAll()

        let sm = SessionManager.shared
        let activeIdx = sm.activeIndex
        for (index, session) in sm.sessions.enumerated() {
            let isActive = (index == activeIdx)
            let title = (isActive ? "● " : "") + session.name
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")

            let submenu = NSMenu(title: session.name)

            // Ctrl+Cmd+<n> activates session n (first 9).
            let activate = NSMenuItem(
                title: "Activate",
                action: #selector(handleActivate(_:)),
                keyEquivalent: index < 9 ? "\(index + 1)" : ""
            )
            if index < 9 { activate.keyEquivalentModifierMask = [.command, .control] }
            activate.target = self
            activate.tag = index
            activate.state = isActive ? .on : .off
            submenu.addItem(activate)

            let close = NSMenuItem(title: "Close Session", action: #selector(handleClose(_:)), keyEquivalent: "")
            close.target = self
            close.tag = index
            submenu.addItem(close)

            item.submenu = submenu
            mainMenu.addItem(item)
            sessionItems.append(item)
        }
    }

    @objc private func handleActivate(_ sender: NSMenuItem) {
        let sm = SessionManager.shared
        guard sm.sessions.indices.contains(sender.tag) else { return }
        sm.activate(sm.sessions[sender.tag])
    }

    @objc private func handleClose(_ sender: NSMenuItem) {
        let sm = SessionManager.shared
        guard sm.sessions.indices.contains(sender.tag) else { return }
        sm.close(sm.sessions[sender.tag])
    }
}
