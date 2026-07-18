import AppKit

/// App-level registry of session windows. Each session is its own NSWindow with
/// its own ViewController + ZonvieCore; the macOS menu bar is app-shared, so
/// SessionMenuController surfaces every registered session as a top-level menu.
/// Activating a session brings its window to the front; the key window is the
/// "active" session for menu marking.
final class SessionManager {
    static let shared = SessionManager()
    private init() {}

    final class Session {
        weak var window: NSWindow?
        weak var viewController: ViewController?
        var name: String
        init(window: NSWindow, viewController: ViewController, name: String) {
            self.window = window
            self.viewController = viewController
            self.name = name
        }
    }

    private(set) var sessions: [Session] = []

    /// Fired on the main thread after the session list / names / focus change so
    /// SessionMenuController can rebuild.
    var onChange: (() -> Void)?

    @discardableResult
    func register(window: NSWindow, viewController: ViewController, name: String) -> Session {
        let s = Session(window: window, viewController: viewController, name: name)
        sessions.append(s)
        ZonvieCore.appLog("[Session] register: '\(name)' count=\(sessions.count)")
        onChange?()
        return s
    }

    func unregister(window: NSWindow) {
        let before = sessions.count
        sessions.removeAll { $0.window == nil || $0.window === window }
        if sessions.count != before {
            ZonvieCore.appLog("[Session] unregister: count=\(sessions.count)")
            onChange?()
        }
    }

    func rename(_ viewController: ViewController, to name: String) {
        guard let s = sessions.first(where: { $0.viewController === viewController }) else { return }
        s.name = name
        onChange?()
    }

    func activate(_ session: Session) {
        session.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onChange?()
    }

    func close(_ session: Session) {
        session.window?.performClose(nil)
    }

    /// Index of the session whose window is currently key (for menu marking).
    var activeIndex: Int? {
        guard let key = NSApp.keyWindow else { return nil }
        return sessions.firstIndex { $0.window === key }
    }
}
