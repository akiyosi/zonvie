import AppKit

/// Zonvie configuration loaded from config.toml
struct ZonvieConfig {
    var neovim: NeovimConfig = NeovimConfig()
    var font: FontConfig = FontConfig()
    var window: WindowConfig = WindowConfig()
    var scrollbar: ScrollbarConfig = ScrollbarConfig()
    var cmdline: CmdlineConfig = CmdlineConfig()
    var popup: PopupConfig = PopupConfig()
    var messages: MessagesConfig = MessagesConfig()
    var tabline: TablineConfig = TablineConfig()
    var log: LogConfig = LogConfig()
    var performance: PerformanceConfig = PerformanceConfig()
    var ime: IMEConfig = IMEConfig()

    /// Position anchor for message views
    enum MsgPosition: String {
        case display = "display" // Display-based, independent of Neovim window
        case window = "window"   // Neovim window-based (main or external window)
        case grid = "grid"       // Grid-based (current cursor grid)
    }

    struct NeovimConfig {
        var path: String = "/usr/local/bin/nvim"
        var ssh: Bool = false
        var sshHost: String? = nil      // user@host
        var sshPort: Int? = nil         // デフォルト22, nil means default
        var sshIdentity: String? = nil  // 秘密鍵パス
    }

    struct FontConfig {
        var family: String = "Menlo"
        var size: Double = 14.0
        var linespace: Int = 0
    }

    struct WindowConfig {
        var blur: Bool = true
        var opacity: Double = 0.5  // Only used when blur=true
        var blurRadius: Int = 20   // Blur radius (1-100), only used when blur=true
    }

    struct ScrollbarConfig {
        var enabled: Bool = true
        /// Show mode: "always", "hover", "scroll", or combinations like "hover,scroll"
        var showMode: String = "scroll"
        /// Opacity (0.0 - 1.0)
        var opacity: Double = 0.7
        /// Delay in seconds before hiding (for "scroll" mode)
        var delay: Double = 1.0

        /// Check if a specific mode is enabled
        func hasMode(_ mode: String) -> Bool {
            return showMode.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(mode)
        }

        var isAlways: Bool { hasMode("always") }
        var isHover: Bool { hasMode("hover") }
        var isScroll: Bool { hasMode("scroll") }
    }

    struct CmdlineConfig {
        var external: Bool = false
    }

    struct PopupConfig {
        var external: Bool = false
    }

    struct MessagesConfig {
        var external: Bool = false
        /// Position for ext-float and mini views: screen, window, or grid
        var extFloatPos: MsgPosition = .window
        var miniPos: MsgPosition = .grid
    }

    struct TablineConfig {
        var external: Bool = false
    }

    struct LogConfig {
        var enabled: Bool = false
        var path: String? = nil  // If nil, logs to stderr
    }

    struct PerformanceConfig {
        /// Glyph cache size for ASCII characters (0-127) × 4 style combinations
        /// Default: 512 (128 ASCII × 4 styles), Minimum: 128
        var glyphCacheAsciiSize: Int = 512

        /// Glyph cache size for non-ASCII characters (hash table)
        /// Default: 256, Minimum: 64
        var glyphCacheNonAsciiSize: Int = 256

        /// Highlight attribute cache size for flush vertex generation
        /// Default: 512, Range: 64-2048
        var hlCacheSize: Int = 512
    }

    struct IMEConfig {
        /// Disable IME when app becomes active (switching from another app)
        var disableOnActivate: Bool = false

        /// Disable IME on any Vim mode change (insert→normal, normal→visual, etc.)
        var disableOnModechange: Bool = false
    }

    /// Shared instance loaded at app startup
    static var shared: ZonvieConfig = ZonvieConfig.load()

    /// Config file path (XDG Base Directory compliant)
    /// Uses $XDG_CONFIG_HOME/zonvie/config.toml, fallback to ~/.config/zonvie/config.toml
    static var configFilePath: URL {
        let configDir: String
        if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
            configDir = xdgConfigHome
        } else {
            configDir = NSHomeDirectory() + "/.config"
        }
        return URL(fileURLWithPath: configDir).appendingPathComponent("zonvie/config.toml")
    }

    /// Load configuration from file, falling back to defaults
    static func load() -> ZonvieConfig {
        var config = ZonvieConfig()

        let configPath = configFilePath
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return config
        }

        guard let content = try? String(contentsOf: configPath, encoding: .utf8) else {
            return config
        }

        config.parse(content)
        return config
    }

    /// Simple TOML parser for key = value format
    mutating func parse(_ content: String) {
        var currentSection = ""
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Section header: [section]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                continue
            }

            // Key = value pair
            guard let eqIndex = trimmed.firstIndex(of: "=") else {
                continue
            }

            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

            // Remove quotes from string values
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            applyValue(section: currentSection, key: key, value: value)
        }
    }

    /// Apply parsed value to configuration
    private mutating func applyValue(section: String, key: String, value: String) {
        switch section {
        case "neovim":
            switch key {
            case "path":
                neovim.path = value
            case "ssh":
                neovim.ssh = (value == "true")
            case "ssh_host":
                neovim.sshHost = value.isEmpty ? nil : value
            case "ssh_port":
                if let port = Int(value), port > 0, port <= 65535 {
                    neovim.sshPort = port
                }
            case "ssh_identity":
                neovim.sshIdentity = value.isEmpty ? nil : value
            default:
                ZonvieCore.appLog("[Config] Unknown key: neovim.\(key)")
            }

        case "font":
            switch key {
            case "family":
                font.family = value
            case "size":
                if let size = Double(value) {
                    font.size = size
                }
            case "linespace":
                if let ls = Int(value) {
                    font.linespace = ls
                }
            default:
                ZonvieCore.appLog("[Config] Unknown key: font.\(key)")
            }

        case "window":
            switch key {
            case "blur":
                window.blur = (value == "true")
            case "opacity":
                if let opacity = Double(value) {
                    window.opacity = max(0.0, min(1.0, opacity))
                }
            case "blur_radius":
                if let radius = Int(value) {
                    window.blurRadius = max(1, min(100, radius))
                }
            default:
                ZonvieCore.appLog("[Config] Unknown key: window.\(key)")
            }

        case "scrollbar":
            switch key {
            case "enabled":
                scrollbar.enabled = (value == "true")
            case "show_mode":
                // Allow single values or combinations like "hover,scroll"
                scrollbar.showMode = value
            case "opacity":
                if let opacity = Double(value) {
                    scrollbar.opacity = max(0.0, min(1.0, opacity))
                }
            case "delay":
                if let d = Double(value) {
                    scrollbar.delay = max(0.1, min(10.0, d))
                }
            default:
                ZonvieCore.appLog("[Config] Unknown key: scrollbar.\(key)")
            }

        case "cmdline":
            switch key {
            case "external":
                cmdline.external = (value == "true")
            default:
                ZonvieCore.appLog("[Config] Unknown key: cmdline.\(key)")
            }

        case "popup":
            switch key {
            case "external":
                popup.external = (value == "true")
            default:
                ZonvieCore.appLog("[Config] Unknown key: popup.\(key)")
            }

        case "messages":
            switch key {
            case "external":
                messages.external = (value == "true")
            case "msg_pos":
                // Parse inline table: { ext-float = "display", mini = "grid" }
                parseInlineMsgPos(value)
            default:
                ZonvieCore.appLog("[Config] Unknown key: messages.\(key)")
            }

        case "tabline":
            switch key {
            case "external":
                tabline.external = (value == "true")
            default:
                ZonvieCore.appLog("[Config] Unknown key: tabline.\(key)")
            }

        case "log":
            switch key {
            case "enabled":
                log.enabled = (value == "true")
            case "path":
                log.path = value.isEmpty ? nil : value
            default:
                ZonvieCore.appLog("[Config] Unknown key: log.\(key)")
            }

        case "performance":
            switch key {
            case "glyph_cache_ascii_size":
                if let size = Int(value), size >= 128 {
                    performance.glyphCacheAsciiSize = size
                }
            case "glyph_cache_non_ascii_size":
                if let size = Int(value), size >= 64 {
                    performance.glyphCacheNonAsciiSize = size
                }
            case "hl_cache_size":
                if let size = Int(value), size >= 64, size <= 2048 {
                    performance.hlCacheSize = size
                }
            default:
                ZonvieCore.appLog("[Config] Unknown key: performance.\(key)")
            }

        case "ime":
            switch key {
            case "disable_on_activate":
                ime.disableOnActivate = (value == "true")
            case "disable_on_modechange":
                ime.disableOnModechange = (value == "true")
            default:
                ZonvieCore.appLog("[Config] Unknown key: ime.\(key)")
            }

        default:
            if !section.isEmpty {
                ZonvieCore.appLog("[Config] Unknown section: [\(section)]")
            }
        }
    }

    /// Parse inline table for msg_pos: { ext-float = "display", mini = "grid" }
    private mutating func parseInlineMsgPos(_ value: String) {
        ZonvieCore.appLog("[Config] parseInlineMsgPos: input='\(value)'")
        // Remove braces and split by comma
        var content = value.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("{") { content = String(content.dropFirst()) }
        if content.hasSuffix("}") { content = String(content.dropLast()) }

        let pairs = content.components(separatedBy: ",")
        for pair in pairs {
            guard let eqIndex = pair.firstIndex(of: "=") else { continue }

            let key = pair[..<eqIndex].trimmingCharacters(in: .whitespaces)
            var val = pair[pair.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

            // Remove quotes
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }

            ZonvieCore.appLog("[Config] parseInlineMsgPos: key='\(key)' val='\(val)'")

            guard let pos = MsgPosition(rawValue: val) else {
                ZonvieCore.appLog("[Config] Invalid msg_pos value for '\(key)': \(val) (expected: display, window, grid)")
                continue
            }

            switch key {
            case "ext-float":
                messages.extFloatPos = pos
                ZonvieCore.appLog("[Config] set extFloatPos=\(pos)")
            case "mini":
                messages.miniPos = pos
                ZonvieCore.appLog("[Config] set miniPos=\(pos)")
            default:
                ZonvieCore.appLog("[Config] Unknown msg_pos key: \(key)")
            }
        }
    }

}

// MARK: - Convenience accessors for backward compatibility with BlurConfig

extension ZonvieConfig {
    /// Blur enabled (replaces BlurConfig.blurEnabled)
    var blurEnabled: Bool { window.blur }

    /// Main window material - .hudWindow provides dark, highly transparent blur
    var mainWindowMaterial: NSVisualEffectView.Material { .hudWindow }

    /// Float window material - .hudWindow provides dark, highly transparent blur
    var floatWindowMaterial: NSVisualEffectView.Material { .hudWindow }

    /// Cmdline window material - .hudWindow provides dark, highly transparent blur
    var cmdlineWindowMaterial: NSVisualEffectView.Material { .hudWindow }

    /// Background alpha - only applies opacity when blur is enabled
    var backgroundAlpha: Float { window.blur ? Float(window.opacity) : 1.0 }

    /// Blending mode (fixed value)
    var blendingMode: NSVisualEffectView.BlendingMode { .behindWindow }
}

// MARK: - Cmdline layout constants

extension ZonvieConfig {
    /// Cmdline inner padding (constant regardless of blur setting).
    static let cmdlinePadding: CGFloat = 12.0

    /// Cmdline icon size in points.
    static let cmdlineIconSize: CGFloat = 18.0
    /// Cmdline icon left margin in points.
    static let cmdlineIconMarginLeft: CGFloat = 12.0
    /// Cmdline icon right margin in points.
    static let cmdlineIconMarginRight: CGFloat = 2.0
    /// Total width occupied by the cmdline icon area.
    static let cmdlineIconTotalWidth: CGFloat = cmdlineIconMarginLeft + cmdlineIconSize + cmdlineIconMarginRight
    /// Extra margin around the cmdline window for screen-width constraint.
    static let cmdlineScreenMargin: CGFloat = 40.0
}
