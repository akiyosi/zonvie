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

    // Per-session top-level menu-bar menus (multi-session)
    private var sessionMenuController: SessionMenuController?

    // Notification observer token (stored so it can be removed on deinit)
    private var neovimReadyObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ZonvieConfig.shared
        ZonvieCore.appLog("zonvie: applicationDidFinishLaunching")
        ZonvieCore.appLog("zonvie: config loaded - blur=\(config.blurEnabled), opacity=\(config.window.opacity)")

        // Request notification permission for OS notification view type
        ZonvieCore.requestNotificationPermission()

        // Observe Neovim ready notification (fired when first vertices are received)
        neovimReadyObserver = NotificationCenter.default.addObserver(
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

        // macOS state restoration re-opens windows that were visible at quit.
        // The shared NSFontPanel (font picker for `:set guifont=*`) is one of
        // them, so it would reappear at startup with no trigger. Close any
        // restored font panel and opt it out of future restoration. Deferred
        // so it runs after AppKit's restoration pass.
        DispatchQueue.main.async {
            if let panel = NSFontManager.shared.fontPanel(false) {
                panel.isRestorable = false
                panel.orderOut(nil)
            }
        }

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
        appMenu.addItem(withTitle: "About zonvie", action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        // New Session: opens a fresh session in its own window (shared menu bar).
        let newSessionItem = NSMenuItem(title: "New Session", action: #selector(newSession(_:)), keyEquivalent: "n")
        newSessionItem.target = self
        appMenu.addItem(newSessionItem)
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

        // Per-session top-level menu-bar menus (independent of window/VC).
        sessionMenuController = SessionMenuController(mainMenu: mainMenu)
    }

    // Show the standard About panel, but source the version from the Zig core
    // (git describe) instead of the static Info.plist CFBundleShortVersionString.
    // .version is left empty so the parenthetical build number is suppressed.
    @objc private func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: ZonvieCore.version(),
            .version: "",
        ])
    }

    // Deferred tab menu setup (needs ViewController)
    private var deferredTabMenu: NSMenu?

    private func finalizeTabMenuSetup() {
        guard let vc = window?.contentViewController as? ViewController else { return }

        guard let tabMenu = deferredTabMenu else { return }
        tabMenuManager = TabMenuManager(menu: tabMenu, viewController: vc)
        deferredTabMenu = nil
    }

    /// Create a session window. `forceDialog` makes it a New Session window that
    /// shows the connection dialog on appear (and, on Cancel, closes just this
    /// window). Each window owns its own ViewController + ZonvieCore and is
    /// registered in SessionManager so it appears in the shared menu bar.
    @discardableResult
    private func createAndShowWindow(forceDialog: Bool = false) -> NSWindow {
        ZonvieCore.appLog("zonvie: creating window (forceDialog=\(forceDialog))")

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
            // Use a near-zero-alpha background instead of .clear. A fully clear
            // background makes macOS compute the window's contact shadow against
            // a fully-transparent shape, which bleeds through the translucent
            // content's outermost pixel as a ~1px dark line around the window
            // edge. A 0.001-alpha color gives the window a defined shape so the
            // shadow/border renders correctly while staying visually transparent.
            // Same workaround used by kitty, Ghostty, and Neovide.
            win.backgroundColor = NSColor.white.withAlphaComponent(0.001)
            ZonvieCore.appLog("[Window] Set transparent for blur: isOpaque=\(win.isOpaque) backgroundColor=\(String(describing: win.backgroundColor))")
        }

        // Prevent the window from becoming unreasonably small.
        // Add sidebar width to minimum if sidebar mode is active.
        var minWidth: CGFloat = 400
        if tablineStyle == .sidebar {
            minWidth += CGFloat(config.tabline.sidebarWidth)
        }
        win.contentMinSize = NSSize(width: minWidth, height: 300)

        // Assign the content view controller BEFORE restoring the frame.
        // NSWindow.contentViewController setter resizes the window to match
        // the view controller's view contentSize (~400x300 default), which
        // would otherwise overwrite a restored autosave frame.
        let vc = ViewController()
        vc.forceConnectDialog = forceDialog
        win.contentViewController = vc

        // Persist/restore window geometry (AppKit feature).
        win.setFrameAutosaveName(windowFrameAutosaveName)

        // If there is a saved frame from the last session, use it.
        // Otherwise keep the computed default rect (centered 800x600-ish).
        if !win.setFrameUsingName(windowFrameAutosaveName) {
            win.center()
        }

        self.window = win
        win.delegate = self  // Handle window close with unsaved buffer check

        // Register this session window in the shared registry so it appears as a
        // top-level menu-bar menu. Renamed from its connection on Connect.
        let sessionName = forceDialog ? "New Session" : Self.defaultSessionName()
        SessionManager.shared.register(window: win, viewController: vc, name: sessionName)

        // Finalize tab menu setup now that ViewController exists
        finalizeTabMenuSetup()

        // SSH/devcontainer mode: hide window until auth completes (neovimReadyNotification)
        // Normal mode: show window immediately.
        // A dialog window (`--dialog` startup or New Session) always shows: the
        // connection dialog is a sheet that needs a visible host window, and no
        // nvim spawns until Connect, so there is nothing to hide for.
        if (sshModeEnabled || devcontainerModeEnabled) && !connectDialogEnabled && !forceDialog {
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

        return win
    }

    /// Default menu-bar label for the CLI-launched session window.
    static func defaultSessionName() -> String {
        if sshModeEnabled || ZonvieConfig.shared.neovim.ssh { return "SSH" }
        if devcontainerModeEnabled { return "Devcontainer" }
        return "Local"
    }

    /// App menu "New Session" target: open a fresh session in its own window.
    @objc func newSession(_ sender: Any?) {
        createAndShowWindow(forceDialog: true)
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

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        SessionManager.shared.unregister(window: win)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Track the frontmost session window so single-window-oriented code
        // (and the menu bar's active marking) follows focus across sessions.
        if let win = notification.object as? NSWindow, win.contentViewController is ViewController {
            self.window = win
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        // Stop the msg throttle timer while in the Dock: a timer that fires here
        // would query the Zig core's grid state, which must not happen while the
        // window is minimized.
        let win = notification.object as? NSWindow ?? window
        if let vc = win?.contentViewController as? ViewController {
            vc.core?.terminalView?.cancelMsgTimer()
        }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        // Trigger a full redraw so the window content is up-to-date after restore.
        let win = notification.object as? NSWindow ?? window
        if let vc = win?.contentViewController as? ViewController {
            vc.requestFullRedraw()
            // Re-arm the msg throttle timer explicitly rather than relying on a
            // flush to do it: a pending auto-hide deadline armed before minimize
            // must resume firing on restore.
            vc.core?.terminalView?.scheduleMsgTimer()
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
            // Resume cursor blinking now that we are frontmost.
            vc.core?.resetCursorBlink()
        }
        setCmdlineWindowActiveForAllSessions(true)
    }

    /// The cmdline window no longer hides on deactivate, so its level is what
    /// keeps it from hovering above other apps. That has to be applied to
    /// EVERY session: `self.window` tracks only the last key window, and a
    /// background session's cmdline would otherwise stay at .floating for as
    /// long as it is open.
    private func setCmdlineWindowActiveForAllSessions(_ active: Bool) {
        for session in SessionManager.shared.sessions {
            session.viewController?.core?.setCmdlineWindowActive(active)
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        if let vc = window?.contentViewController as? ViewController {
            vc.core?.setFocus(false)
            // Stop the recursive blink timer while in the background so it does
            // not wake the CPU to redraw a window the user isn't looking at.
            vc.core?.stopCursorBlinking()
        }
        setCmdlineWindowActiveForAllSessions(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let win = notification.object as? NSWindow ?? window
        guard let vc = win?.contentViewController as? ViewController else { return }
        // Pause blinking when the window is fully occluded; resume only when it
        // is visible and the app is frontmost (focus gating handled separately).
        if win?.occlusionState.contains(.visible) == true && NSApp.isActive {
            vc.core?.resetCursorBlink()
        } else {
            vc.core?.stopCursorBlinking()
        }

        // Repaint on the way back, for the same reason windowDidDeminiaturize
        // does: MetalTerminalRenderer.draw skips every frame while the window
        // is invisible (currentDrawable blocks the main thread there), and it
        // still clears redrawPending on the way out. A redraw that arrived
        // while covered is therefore dropped, and with an idle Neovim behind
        // it nothing would repaint the window once it is uncovered.
        if win?.occlusionState.contains(.visible) == true {
            vc.requestFullRedraw()
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

        // Drain now if the core is already running (file opened against an
        // already-running instance via Finder). processPendingFiles() guards on
        // core availability, so before the core is ready it returns early and
        // the queue is drained later by the neovimReadyNotification observer.
        processPendingFiles()
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

        // Choose the open command. A single file honors `[server] open_mode`
        // ("current" replaces the current window via `:drop`, otherwise a new
        // tab via `:tab drop`). Multiple files always open as new tabs. Using
        // `:drop`/`:tab drop` (rather than `:edit`/`:tabe`) jumps to a window
        // already showing the file instead of opening a duplicate.
        let useCurrent = pendingFilesToOpen.count == 1
            && ZonvieConfig.shared.server.openMode == "current"
        let cmd = useCurrent ? "drop" : "tab drop"
        for filename in pendingFilesToOpen {
            let escapedPath = escapePathForNeovim(filename)
            let input = "\u{1b}:\(cmd) \(escapedPath)\r"
            core.sendInput(input)
            ZonvieCore.appLog("zonvie: sent :\(cmd) \(escapedPath)")
        }

        pendingFilesToOpen = []

        // Bring the running instance to the front (file routed from Finder).
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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

/// Drag feedback shared by the terminal view and the external cmdline window.
///
/// The pointer shape during a drag belongs to AppKit and cannot be overridden
/// by a destination, so the two drop targets are distinguished by swapping
/// what is being dragged: over the command line the item becomes the path as
/// text, because that is what the drop inserts; over the buffer it stays the
/// file icon, because that drop opens the file. A destination's
/// change persists for the rest of the session, so each side must set its own
/// representation on entry rather than only overriding once.
enum FileDragFeedback {
    static func showPathText(_ sender: NSDraggingInfo, in view: NSView) {
        forEachFileURL(sender, in: view) { item, url in
            // The chip shows the path, because the path is what the drop
            // inserts. pathTextImage truncates it in the middle so a deep
            // path does not produce a screen-wide image.
            let image = pathTextImage(url.path)
            item.setDraggingFrame(recentred(item.draggingFrame, on: image.size), contents: image)
        }
    }

    static func showFileIcon(_ sender: NSDraggingInfo, in view: NSView) {
        forEachFileURL(sender, in: view) { item, url in
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            item.setDraggingFrame(
                recentred(item.draggingFrame, on: icon.size),
                contents: icon
            )
        }
    }

    /// Keep the replacement image under the pointer. setDraggingFrame takes a
    /// rect whose origin is its bottom-left (these views are unflipped), so
    /// reusing the incoming origin with a different size shifts the image off
    /// the cursor by the whole size difference — a wide text chip would hang
    /// out to the upper right of the pointer.
    private static func recentred(_ frame: NSRect, on size: NSSize) -> NSRect {
        NSRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func forEachFileURL(
        _ sender: NSDraggingInfo,
        in view: NSView,
        _ body: @escaping (NSDraggingItem, URL) -> Void
    ) {
        sender.enumerateDraggingItems(
            options: [],
            for: view,
            classes: [NSURL.self],
            searchOptions: [.urlReadingFileURLsOnly: true]
        ) { item, _, _ in
            guard let url = item.item as? URL else { return }
            body(item, url)
        }
    }

    /// A long name would make the dragged image span the screen, so it is
    /// truncated in the middle where paths and names differ least.
    private static func pathTextImage(_ text: String) -> NSImage {
        let maxChars = 48
        var label = text
        if label.count > maxChars {
            let keep = maxChars / 2 - 1
            label = "\(label.prefix(keep))…\(label.suffix(keep))"
        }

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributed = NSAttributedString(
            string: label,
            attributes: [.font: font, .foregroundColor: NSColor.white]
        )
        let textSize = attributed.size()
        let padX: CGFloat = 10
        let padY: CGFloat = 6
        let size = NSSize(
            width: ceil(textSize.width) + padX * 2,
            height: ceil(textSize.height) + padY * 2
        )

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size),
            xRadius: 5,
            yRadius: 5
        ).fill()
        attributed.draw(at: NSPoint(x: padX, y: padY))
        image.unlockFocus()
        return image
    }
}
