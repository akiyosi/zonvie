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
    var windows: WindowsConfig = WindowsConfig()
    var log: LogConfig = LogConfig()
    var performance: PerformanceConfig = PerformanceConfig()
    var ime: IMEConfig = IMEConfig()

    /// Tabline display style
    enum TablineStyle: String {
        case titlebar = "titlebar"   // Chrome-style tabs in titlebar
        case menu = "menu"           // NSMenu dropdown in macOS menu bar
        case sidebar = "sidebar"     // Sidebar panel with tab list
    }

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
        /// True when the user explicitly set [font] family / size in config.toml.
        /// When true, onGuiFont prefers config over nvim's default guifont list.
        var familyExplicit: Bool = false
        var sizeExplicit: Bool = false
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
        var style: String = "titlebar"       // "titlebar", "menu", "sidebar"
        var sidebarPosition: String = "left" // "left" or "right"
        var sidebarWidth: Int = 200          // 100-500 pixels
    }

    struct WindowsConfig {
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

        /// Shape cache size for HarfBuzz text-run shaping results (2-way set associative)
        /// Default: 4096, Range: 512-65536
        var shapeCacheSize: Int = 4096

        /// Glyph atlas texture size (square, both width and height)
        /// Default: 2048, Range: 1024-4096
        var atlasSize: Int = 2048
    }

    enum OptionAsMeta: UInt8 {
        case both = 0       // Both Option keys → Meta
        case none = 1       // Both Option keys → macOS special characters
        case onlyLeft = 2   // Left Option → Meta, Right Option → macOS
        case onlyRight = 3  // Right Option → Meta, Left Option → macOS
    }

    struct IMEConfig {
        /// Disable IME when app becomes active (switching from another app)
        var disableOnActivate: Bool = false

        /// Disable IME on any Vim mode change (insert→normal, normal→visual, etc.)
        var disableOnModechange: Bool = false

        /// How Option keys are handled: as Meta (Alt) for Neovim, or as macOS special character input
        var optionAsMeta: OptionAsMeta = .both
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

        let configPath = configFilePath.path

        // Use Zig core TOML parser via C API
        let handle: OpaquePointer? = configPath.withCString { cPath in
            return zonvie_config_load(cPath)
        }

        guard let handle = handle else {
            return config
        }

        let v = zonvie_config_get_values(handle)

        // Font
        if let s = v.font_family { config.font.family = String(cString: s) }
        config.font.size = Double(v.font_size)
        config.font.linespace = Int(v.font_linespace)
        config.font.familyExplicit = v.font_family_explicit
        config.font.sizeExplicit = v.font_size_explicit

        // Window
        config.window.blur = v.window_blur
        config.window.opacity = Double(v.window_opacity)
        config.window.blurRadius = Int(v.window_blur_radius)

        // Scrollbar
        config.scrollbar.enabled = v.scrollbar_enabled
        if let s = v.scrollbar_show_mode { config.scrollbar.showMode = String(cString: s) }
        config.scrollbar.opacity = Double(v.scrollbar_opacity)
        config.scrollbar.delay = Double(v.scrollbar_delay)

        // Ext features
        config.cmdline.external = v.cmdline_external
        config.popup.external = v.popup_external
        config.messages.external = v.messages_external
        config.messages.extFloatPos = MsgPosition.from(int: v.messages_ext_float_pos)
        config.messages.miniPos = MsgPosition.from(int: v.messages_mini_pos)
        config.tabline.external = v.tabline_external
        if let s = v.tabline_style { config.tabline.style = String(cString: s) }
        if let s = v.tabline_sidebar_position { config.tabline.sidebarPosition = String(cString: s) }
        config.tabline.sidebarWidth = Int(v.tabline_sidebar_width)
        config.windows.external = v.windows_external

        // Neovim
        if let s = v.neovim_path { config.neovim.path = String(cString: s) }
        config.neovim.ssh = v.neovim_ssh
        if let s = v.neovim_ssh_host { config.neovim.sshHost = String(cString: s) }
        config.neovim.sshPort = v.neovim_ssh_port > 0 ? Int(v.neovim_ssh_port) : nil
        if let s = v.neovim_ssh_identity { config.neovim.sshIdentity = String(cString: s) }

        // Log
        config.log.enabled = v.log_enabled
        if let s = v.log_path { config.log.path = String(cString: s) }

        // Performance
        config.performance.glyphCacheAsciiSize = Int(v.perf_glyph_cache_ascii)
        config.performance.glyphCacheNonAsciiSize = Int(v.perf_glyph_cache_non_ascii)
        config.performance.hlCacheSize = Int(v.perf_hl_cache_size)
        config.performance.shapeCacheSize = Int(v.perf_shape_cache_size)
        config.performance.atlasSize = Int(v.perf_atlas_size)

        // IME
        config.ime.disableOnActivate = v.ime_disable_on_activate
        config.ime.disableOnModechange = v.ime_disable_on_modechange
        config.ime.optionAsMeta = OptionAsMeta(rawValue: v.ime_option_as_meta) ?? .both

        zonvie_config_destroy(handle)

        return config
    }

}

// MARK: - MsgPosition C API helper

extension ZonvieConfig.MsgPosition {
    /// Convert C API int value to MsgPosition enum
    static func from(int value: Int32) -> ZonvieConfig.MsgPosition {
        switch value {
        case 0: return .window
        case 1: return .grid
        case 2: return .display
        default: return .window
        }
    }
}

// MARK: - Tabline style accessor

extension ZonvieConfig {
    /// Resolved tabline style. Returns nil if ext_tabline is not enabled.
    var effectiveTablineStyle: TablineStyle? {
        guard tabline.external || CommandLine.arguments.contains("--exttabline") else {
            return nil
        }
        return TablineStyle(rawValue: tabline.style) ?? .titlebar
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
