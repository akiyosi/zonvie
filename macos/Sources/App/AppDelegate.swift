import Cocoa
import MetalKit

// Private macOS API for controlling window blur radius
// Used by iTerm2, ghostty, wezterm, etc.
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
private func CGSSetWindowBackgroundBlurRadius(_ connection: UInt, _ windowNumber: Int, _ radius: Int) -> Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    // OS/UI-specific: persist window geometry across launches.
    private let windowFrameAutosaveName = "zonvie.mainWindow.frame"

    // Files to open from Finder (queued until Neovim is ready)
    private var pendingFilesToOpen: [String] = []

    // Tab menu manager (for "menu" tabline style)
    private var tabMenuManager: TabMenuManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ZonvieConfig.shared
        ZonvieCore.appLog("zonvie: applicationDidFinishLaunching")
        ZonvieCore.appLog("zonvie: config loaded - blur=\(config.blurEnabled), opacity=\(config.window.opacity)")

        // Request notification permission for OS notification view type
        ZonvieCore.requestNotificationPermission()

        // Observe Neovim ready notification (fired when first vertices are received)
        NotificationCenter.default.addObserver(
            forName: ZonvieCore.neovimReadyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            ZonvieCore.appLog("zonvie: received neovimReadyNotification")
            // Show window if it was hidden (SSH/devcontainer mode)
            if let win = self?.window, !win.isVisible {
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                ZonvieCore.appLog("zonvie: window shown after auth")
            }
            self?.processPendingFiles()
        }

        NSApp.setActivationPolicy(.regular)

        // Setup application menu (includes Tab menu for "menu" tabline style)
        setupApplicationMenu()

        createAndShowWindow()
    }

    // MARK: - Application Menu

    private func setupApplicationMenu() {
        let mainMenu = NSMenu()

        // App menu (About, Quit)
        let appMenuItem = NSMenuItem(title: "zonvie", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About zonvie", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit zonvie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Tab menu (only for "menu" tabline style)
        if ZonvieConfig.shared.effectiveTablineStyle == .menu {
            let tabMenuItem = NSMenuItem(title: "Tab", action: nil, keyEquivalent: "")
            let tabMenu = NSMenu(title: "Tab")
            tabMenuItem.submenu = tabMenu
            mainMenu.addItem(tabMenuItem)

            // TabMenuManager will populate the menu and observe notifications.
            // It needs ViewController reference, which is set up after createAndShowWindow().
            // Store the menu reference and defer TabMenuManager creation.
            self.deferredTabMenu = tabMenu
        }

        NSApp.mainMenu = mainMenu
    }

    // Deferred tab menu setup (needs ViewController)
    private var deferredTabMenu: NSMenu?

    private func finalizeTabMenuSetup() {
        guard let tabMenu = deferredTabMenu,
              let vc = window?.contentViewController as? ViewController else {
            return
        }
        tabMenuManager = TabMenuManager(menu: tabMenu, viewController: vc)
        deferredTabMenu = nil
    }

    private func createAndShowWindow() {
        ZonvieCore.appLog("zonvie: creating window")

        // Prefer visibleFrame; fall back to a sane default if it looks invalid.
        var screenFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        if screenFrame.width < 200 || screenFrame.height < 200 {
            screenFrame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        }

        // Desired initial size.
        let targetW: CGFloat = 800
        let targetH: CGFloat = 600

        // Clamp to screen (leave a little margin).
        let maxW = max(200, screenFrame.width * 0.95)
        let maxH = max(200, screenFrame.height * 0.95)
        let w = min(targetW, maxW)
        let h = min(targetH, maxH)

        let rect = NSRect(
            x: screenFrame.midX - w / 2,
            y: screenFrame.midY - h / 2,
            width: w,
            height: h
        )

        var style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]

        let tablineStyle = ZonvieConfig.shared.effectiveTablineStyle
        ZonvieCore.appLog("[AppDelegate] effectiveTablineStyle=\(String(describing: tablineStyle)) tabline.style=\(ZonvieConfig.shared.tabline.style)")

        // Only titlebar mode needs fullSizeContentView and TabBarWindow
        if tablineStyle == .titlebar {
            style.insert(.fullSizeContentView)
        }

        let win: NSWindow
        if tablineStyle == .titlebar {
            win = TabBarWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        } else {
            win = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        }
        win.title = "zonvie"
        win.isReleasedWhenClosed = false

        // Configure titlebar for Chrome-style tabs (titlebar mode only)
        if tablineStyle == .titlebar {
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = false
            win.isMovable = false  // Completely disable window dragging - TabBarView handles it manually
        }

        // Make window transparent for blur effect (required for CGSSetWindowBackgroundBlurRadius)
        let config = ZonvieConfig.shared
        // DEBUG: Log blur configuration at window setup
        ZonvieCore.appLog("[DEBUG-WINDOW-SETUP] blurEnabled=\(config.blurEnabled) window.blur=\(config.window.blur) opacity=\(config.window.opacity) blurRadius=\(config.window.blurRadius)")

        if config.blurEnabled {
            win.isOpaque = false
            win.backgroundColor = .clear
            ZonvieCore.appLog("[Window] Set transparent for blur: isOpaque=\(win.isOpaque) backgroundColor=\(String(describing: win.backgroundColor))")
        }

        // Prevent the window from becoming unreasonably small.
        // Add sidebar width to minimum if sidebar mode is active.
        var minWidth: CGFloat = 400
        if tablineStyle == .sidebar {
            minWidth += CGFloat(config.tabline.sidebarWidth)
        }
        win.contentMinSize = NSSize(width: minWidth, height: 300)

        // Persist/restore window geometry (AppKit feature).
        win.setFrameAutosaveName(windowFrameAutosaveName)

        // If there is a saved frame from the last session, use it.
        // Otherwise keep the computed default rect (centered 800x600-ish).
        if win.setFrameUsingName(windowFrameAutosaveName) {
            // Restored from the last session; do not recenter.
        } else {
            win.center()
        }

        let vc = ViewController()
        win.contentViewController = vc

        self.window = win
        win.delegate = self  // Handle window close with unsaved buffer check

        // Finalize tab menu setup now that ViewController exists
        finalizeTabMenuSetup()

        // SSH/devcontainer mode: hide window until auth completes (neovimReadyNotification)
        // Normal mode: show window immediately
        if sshModeEnabled || devcontainerModeEnabled {
            // Don't show window yet - it will be shown when neovimReadyNotification fires
            ZonvieCore.appLog("zonvie: window created but hidden (waiting for auth)")
        } else {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            ZonvieCore.appLog("zonvie: window shown")
        }

        // Apply blur using private API if blur is enabled
        if config.blurEnabled {
            applyWindowBlur(window: win, radius: config.window.blurRadius)
            // Shadow invalidation is now handled in MetalTerminalRenderer after first present
        }
    }

    /// Apply blur effect to window using private macOS API (CGSSetWindowBackgroundBlurRadius)
    /// This provides more control over blur radius than NSVisualEffectView
    private func applyWindowBlur(window: NSWindow, radius: Int) {
        // DEBUG: Log blur application from AppDelegate
        ZonvieCore.appLog("[DEBUG-BLUR-APPDELEGATE] applyWindowBlur: window=\(window.windowNumber) radius=\(radius) isOpaque=\(window.isOpaque)")

        let connection = CGSMainConnectionID()
        let windowNumber = window.windowNumber  // Already Int (NSInteger)

        let result = CGSSetWindowBackgroundBlurRadius(connection, windowNumber, radius)
        if result == 0 {
            ZonvieCore.appLog("[Blur] Applied blur radius=\(radius) to window \(windowNumber)")
        } else {
            ZonvieCore.appLog("[Blur] Failed to apply blur, error=\(result)")
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Intercept window close to check for unsaved buffers
        if let vc = sender.contentViewController as? ViewController,
           let core = vc.core {
            ZonvieCore.appLog("[windowShouldClose] requesting quit via core")
            core.requestQuit()
            return false  // Don't close yet - wait for quit confirmation
        }
        // If no core, allow normal close
        return true
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        // Trigger a full redraw so the window content is up-to-date after restore.
        let win = notification.object as? NSWindow ?? window
        if let vc = win?.contentViewController as? ViewController {
            vc.requestFullRedraw()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Disable IME when app becomes active (switching from another app)
        if ZonvieConfig.shared.ime.disableOnActivate {
            ZonvieCore.setIMEOff()
        }
        if let vc = window?.contentViewController as? ViewController {
            vc.core?.setFocus(true)
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        if let vc = window?.contentViewController as? ViewController {
            vc.core?.setFocus(false)
        }
    }

    // MARK: - Open Files from Finder

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        ZonvieCore.appLog("zonvie: application(_:openFile:) called with: \(filename)")
        openFiles([filename])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        ZonvieCore.appLog("zonvie: application(_:openFiles:) called with \(filenames.count) files")
        openFiles(filenames)
        sender.reply(toOpenOrPrint: .success)
    }

    private func openFiles(_ filenames: [String]) {
        // When launched from terminal, files are passed via command line (nvimExtraArgs).
        // macOS also sends them via openFiles, causing duplicates.
        // Only process openFiles when launched from Finder.
        if !launchedFromFinder {
            ZonvieCore.appLog("zonvie: ignoring openFiles (launched from terminal, use cmdline args)")
            return
        }

        // Filter out files that don't exist
        let validFiles = filenames.filter { filename in
            if !FileManager.default.fileExists(atPath: filename) {
                ZonvieCore.appLog("zonvie: skipping '\(filename)' - file doesn't exist")
                return false
            }
            return true
        }

        guard !validFiles.isEmpty else { return }

        // Queue files for later processing
        pendingFilesToOpen.append(contentsOf: validFiles)
        ZonvieCore.appLog("zonvie: queued \(validFiles.count) files")
    }

    private func processPendingFiles() {
        guard !pendingFilesToOpen.isEmpty else { return }

        // Get core from ViewController
        guard let vc = window?.contentViewController as? ViewController,
              let core = vc.core else {
            ZonvieCore.appLog("zonvie: cannot open files - no core available")
            return
        }

        ZonvieCore.appLog("zonvie: processing \(pendingFilesToOpen.count) pending files")

        // Open each file in Neovim with :tabe
        for filename in pendingFilesToOpen {
            let escapedPath = escapePathForNeovim(filename)
            let input = "\u{1b}:tabe \(escapedPath)\r"
            core.sendInput(input)
            ZonvieCore.appLog("zonvie: sent :tabe \(escapedPath)")
        }

        pendingFilesToOpen = []
    }

}

/// Escape file path for Neovim command line.
/// Shared across AppDelegate (Finder open) and MetalTerminalView (drag & drop).
func escapePathForNeovim(_ path: String) -> String {
    var result = ""
    for char in path {
        switch char {
        case "\\": result += "\\\\"
        case " ": result += "\\ "
        case "%": result += "\\%"
        case "#": result += "\\#"
        case "|": result += "\\|"
        case "\"": result += "\\\""
        case "'": result += "\\'"
        case "[": result += "\\["
        case "]": result += "\\]"
        case "{": result += "\\{"
        case "}": result += "\\}"
        case "$": result += "\\$"
        case "`": result += "\\`"
        default: result.append(char)
        }
    }
    return result
}
