import Cocoa
import MetalKit

/// Manages multiple ZonvieCore instances as a tiled workspace.
/// Each tile holds an independent nvim process and its rendering state.
final class WorkspaceManager {

    // MARK: - Types

    /// Connection properties for a tile.
    struct ConnectionConfig {
        var name: String = ""
        var nvimPath: String = ""  // empty = use default from config
        // SSH
        var sshHost: String = ""   // empty = local
        var sshPort: String = ""   // empty = default
        var sshIdentity: String = ""
        // Devcontainer
        var devcontainerWorkspace: String = "" // empty = not devcontainer
        var devcontainerConfig: String = ""
        // UI extensions
        var extCmdline: Bool = false
        var extPopupmenu: Bool = false
        var extMessages: Bool = false
        var extTabline: Bool = false
        // Environment variables (KEY=VALUE per line)
        var envVars: String = ""

        /// Display name (falls back to connection type description).
        var displayName: String {
            if !name.isEmpty { return name }
            if !sshHost.isEmpty { return "SSH: \(sshHost)" }
            if !devcontainerWorkspace.isEmpty { return "Dev: \(devcontainerWorkspace)" }
            return "Local"
        }

        /// True if this is an SSH connection.
        var isSSH: Bool { !sshHost.isEmpty }

        /// True if this is a devcontainer connection.
        var isDevcontainer: Bool { !devcontainerWorkspace.isEmpty }
    }

    /// One workspace slot.
    struct Tile {
        var core: ZonvieCore?
        var snapshot: MTLTexture?
        var config: ConnectionConfig = ConnectionConfig()
        var title: String = ""
        var isSuspended: Bool = false

        /// True when this tile has a running core (started, not exited).
        var isOccupied: Bool { core != nil }
    }

    // MARK: - Properties

    private(set) var tiles: [Tile] = []
    private(set) var activeTileIndex: Int = 0
    var maxTiles: Int

    /// Current zoom level (1.0 = fullscreen, <1.0 = zoomed out toward tile grid).
    /// Setting this property posts `workspaceScaleNotification` so all
    /// overlay controllers can synchronize their visibility.
    var scale: CGFloat = 1.0 {
        didSet {
            guard scale != oldValue else { return }
            NotificationCenter.default.post(
                name: ZonvieCore.workspaceScaleNotification,
                object: nil
            )
        }
    }

    /// Scale step used by scaleIn()/scaleOut() commands.
    var scaleStep: CGFloat = 0.2

    /// Weak reference to the view controller that owns this manager.
    weak var viewController: ViewController?

    /// Weak reference to the terminal view used by the active tile.
    weak var terminalView: MetalTerminalView?

    // MARK: - Init

    init(maxTiles: Int = 9) {
        self.maxTiles = maxTiles
        // Create the first tile (will be populated by ViewController on start)
        tiles.append(Tile())
    }

    // MARK: - Active tile helpers

    var activeTile: Tile {
        tiles[activeTileIndex]
    }

    var activeCore: ZonvieCore? {
        tiles[activeTileIndex].core
    }

    // MARK: - Tile lifecycle

    /// Attach an already-created core to the first tile.
    /// Called by ViewController during initial setup.
    func attachCore(_ core: ZonvieCore, at index: Int = 0) {
        guard index < tiles.count else {
            ZonvieCore.appLog("[Workspace] attachCore REJECTED: index=\(index) out of bounds (tiles.count=\(tiles.count))")
            return
        }
        ZonvieCore.appLog("[Workspace] attachCore: core#\(core.instanceId) at index=\(index) (tiles.count=\(tiles.count))")
        tiles[index].core = core
        core.workspaceManager = self
    }

    /// Add a new empty tile. Returns the index, or nil if at max capacity.
    @discardableResult
    func addTile(config: ConnectionConfig = ConnectionConfig()) -> Int? {
        guard tiles.count < maxTiles else {
            ZonvieCore.appLog("[Workspace] addTile REJECTED: at max capacity tiles.count=\(tiles.count) maxTiles=\(maxTiles)")
            return nil
        }
        var tile = Tile()
        tile.config = config
        tiles.append(tile)
        let newIndex = tiles.count - 1
        ZonvieCore.appLog("[Workspace] addTile: index=\(newIndex) displayName=\(config.displayName) isSSH=\(config.isSSH) isDC=\(config.isDevcontainer) (tiles.count=\(tiles.count))")
        return newIndex
    }

    /// Update the connection config for a tile, deduplicating the display name.
    func setTileConfig(at index: Int, config: ConnectionConfig) {
        guard index >= 0, index < tiles.count else {
            ZonvieCore.appLog("[Workspace] setTileConfig REJECTED: index=\(index) out of bounds (tiles.count=\(tiles.count))")
            return
        }
        var config = config
        config.name = uniqueDisplayName(for: config, excludingIndex: index)
        ZonvieCore.appLog("[Workspace] setTileConfig: index=\(index) name=\(config.name) isSSH=\(config.isSSH) isDC=\(config.isDevcontainer)")
        tiles[index].config = config
    }

    /// Generate a unique display name by appending _1, _2, ... if needed.
    private func uniqueDisplayName(for config: ConnectionConfig, excludingIndex: Int) -> String {
        let baseName = config.displayName
        var existingNames = Set<String>()
        for (i, tile) in tiles.enumerated() {
            if i == excludingIndex { continue }
            existingNames.insert(tile.config.displayName)
        }
        if !existingNames.contains(baseName) { return baseName }
        var n = 1
        while existingNames.contains("\(baseName)_\(n)") { n += 1 }
        return "\(baseName)_\(n)"
    }

    /// Create a new ZonvieCore for the tile at `index`, wire it up, and start it.
    /// Uses the tile's ConnectionConfig for all settings via ZonvieCore.workspaceConfig.
    func startTile(at index: Int) {
        guard index >= 0, index < tiles.count else {
            ZonvieCore.appLog("[Workspace] startTile REJECTED: index=\(index) out of bounds (tiles.count=\(tiles.count))")
            return
        }
        guard tiles[index].core == nil else {
            ZonvieCore.appLog("[Workspace] startTile REJECTED: tile \(index) already running (core#\(tiles[index].core!.instanceId))")
            return
        }

        let tileConfig = tiles[index].config
        let core = ZonvieCore()

        ZonvieCore.appLog("[Workspace] startTile: index=\(index) name=\(tileConfig.displayName) core#\(core.instanceId) activeTileIndex=\(activeTileIndex) isSSH=\(tileConfig.isSSH) isDC=\(tileConfig.isDevcontainer)")

        // Pass connection config to ZonvieCore so start() reads SSH/devcontainer/ext from it
        core.workspaceConfig = tileConfig

        // If this is the active tile, wire it to the terminal view immediately
        if index == activeTileIndex, let tv = terminalView {
            ZonvieCore.appLog("[Workspace] startTile: wiring core#\(core.instanceId) to terminalView (index==activeTileIndex)")
            core.terminalView = tv
            tv.core = core
        }

        tiles[index].core = core
        core.workspaceManager = self

        // Set environment variables before start
        if !tileConfig.envVars.isEmpty {
            for line in tileConfig.envVars.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || !trimmed.contains("=") { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    setenv(String(parts[0]), String(parts[1]), 1)
                }
            }
        }

        // Resolve nvim path from tile config or defaults
        let appConfig = ZonvieConfig.shared
        let nvimPath = tileConfig.nvimPath.isEmpty
            ? (cliNvimPath ?? appConfig.neovim.path)
            : tileConfig.nvimPath

        _ = core.start(nvimPath: nvimPath, rows: 1, cols: 1)
    }

    /// Switch the active tile. Disconnects old core from terminal view,
    /// connects new core. Assigns tile renderers for off-screen rendering.
    func switchToTile(at index: Int) {
        guard index >= 0, index < tiles.count else {
            ZonvieCore.appLog("[Workspace] switchToTile REJECTED: index=\(index) out of bounds (tiles.count=\(tiles.count))")
            return
        }
        guard index != activeTileIndex else {
            ZonvieCore.appLog("[Workspace] switchToTile NOOP: index=\(index) already active")
            return
        }
        guard let tv = terminalView else {
            ZonvieCore.appLog("[Workspace] switchToTile REJECTED: terminalView is nil (requested index=\(index))")
            return
        }

        let oldIndex = activeTileIndex
        let oldCoreDesc = tiles[oldIndex].core.map { "core#\($0.instanceId)" } ?? "none"
        let newCoreDesc = tiles[index].core.map { "core#\($0.instanceId)" } ?? "none"
        ZonvieCore.appLog("[Workspace] switchToTile: \(oldIndex) (\(oldCoreDesc)) -> \(index) (\(newCoreDesc))")

        // Capture snapshot of the current tile before switching
        if tiles[oldIndex].isOccupied {
            setSnapshot(for: oldIndex, texture: tv.captureSnapshot())
        }

        // Disconnect old core from terminal view and give it a tile renderer
        // so it continues rendering off-screen.
        if let oldCore = tiles[oldIndex].core {
            oldCore.terminalView = nil
            ensureTileRenderer(for: oldCore, renderer: tv.renderer)
        }

        activeTileIndex = index

        // Signal the renderer that a new core is taking over.
        // This sets hasPresentedOnce=false (for .clear loadAction) and
        // freshStartCommit (for full dirty on commit). The actual write-set
        // clearing happens in on_flush_begin via needsGlyphInvalidation,
        // which runs on the NEW core's RPC thread (safe from old-core races).
        tv.prepareForNewCore()

        // Connect new core to terminal view (takes over from tile renderer)
        if let newCore = tiles[index].core {
            // CRITICAL: Restore the main atlas font to match this core's font
            // BEFORE clearing tileRenderer. Each core may use a different font
            // (set via guifont in init.lua). Without this, cell metrics
            // (scissor rects, vertex NDC positions) mismatch and rendering
            // is clipped/broken.
            if let tileAtlas = newCore.tileRenderer?.glyphAtlas {
                let name = tileAtlas.currentFontName
                let size = tileAtlas.currentPointSize
                tv.renderer.glyphAtlas.setFont(name: name, pointSize: size, features: tileAtlas.currentFontFeatures)
            }

            newCore.tileRenderer = nil  // no longer off-screen
            newCore.terminalView = tv
            tv.core = newCore
            ZonvieCore.appLog("[Workspace] switchToTile: tv.core = core#\(newCore.instanceId)")

            // Invalidate glyph cache on the core's RPC thread (required by
            // C API contract — must not be called from UI thread).
            // sendCommand triggers an RPC round-trip that runs on the core thread,
            // and invalidate_glyph_cache is called from the resulting flush's
            // on_flush_begin via the needsGlyphInvalidation flag.
            newCore.needsGlyphInvalidation = true

            // Sync core layout with the restored font's cell metrics.
            let cellW = CGFloat(tv.renderer.cellWidthPx)
            let cellH = CGFloat(tv.renderer.cellHeightPx)
            let scale = tv.window?.backingScaleFactor ?? 2.0
            let dw = UInt32(tv.bounds.width * scale)
            let dh = UInt32(tv.bounds.height * scale)
            newCore.updateLayoutPx(
                drawableW: dw, drawableH: dh,
                cellW: UInt32(cellW), cellH: UInt32(cellH))

            // Force full redraw via resize with correct cell metrics.
            let rows = max(1, UInt32(CGFloat(dh) / cellH))
            let cols = max(1, UInt32(CGFloat(dw) / cellW))
            newCore.resize(rows: rows, cols: cols)

            // Unblock the new core's RPC thread waiting in ui_attach_cond.wait().
            // Cores for the first tile are unblocked by MetalTerminalView's
            // initial maybeResizeCoreGrid() call; later tiles need an explicit
            // signal here since the drawable size does not change on switch.
            // notifyLayoutReady is idempotent on the Zig side.
            newCore.notifyInitialLayout(rows: rows, cols: cols)
        } else {
            ZonvieCore.appLog("[Workspace] switchToTile: tile \(index) has no core; clearing tv.core")
            terminalView?.core = nil
        }
    }

    /// Create a TileRenderer for a core if it doesn't have one yet.
    /// Copies the main renderer's current font to the tile atlas so that
    /// font restoration on switchToTile returns the correct font.
    private func ensureTileRenderer(for core: ZonvieCore, renderer: MetalTerminalRenderer?) {
        if core.tileRenderer != nil { return }
        guard let renderer = renderer,
              let device = terminalView?.device else { return }
        let tr = TileRenderer(device: device, mainRenderer: renderer)
        // Copy current font from main atlas so the tileRenderer's atlas
        // matches what this core was using. Without this, the tileRenderer's
        // atlas defaults to Menlo 14pt and font restoration on switchToTile
        // would set the wrong font.
        let mainAtlas = renderer.glyphAtlas
        tr.glyphAtlas.setFont(
            name: mainAtlas.currentFontName,
            pointSize: mainAtlas.currentPointSize,
            features: mainAtlas.currentFontFeatures)
        core.tileRenderer = tr
    }

    /// Remove a tile and stop its core.
    func removeTile(at index: Int) {
        guard index >= 0, index < tiles.count else { return }
        // Don't remove the last tile
        guard tiles.count > 1 else { return }

        if let core = tiles[index].core {
            if index == activeTileIndex {
                core.terminalView = nil
                terminalView?.core = nil
            }
            core.stop()
        }

        // Release snapshot texture
        tiles[index].snapshot = nil
        tiles.remove(at: index)

        // Adjust active index
        if activeTileIndex >= tiles.count {
            activeTileIndex = tiles.count - 1
        }
        if activeTileIndex == index || activeTileIndex >= tiles.count {
            // Re-wire the new active tile
            if let tv = terminalView, let newCore = tiles[activeTileIndex].core {
                newCore.terminalView = tv
                tv.core = newCore
                tv.requestRedraw()
            }
        }
    }

    /// Store a snapshot texture for the tile at the given index.
    func setSnapshot(for index: Int, texture: MTLTexture?) {
        guard index >= 0, index < tiles.count else { return }
        tiles[index].snapshot = texture
    }

    /// Clear a tile's core and snapshot (called when nvim exits).
    /// Disconnects the core from the terminal view. Do NOT call core.stop()
    /// here — ZonvieCore.deinit calls zonvie_core_destroy which stops it.
    func clearTile(for core: ZonvieCore) {
        for index in tiles.indices {
            if tiles[index].core === core {
                ZonvieCore.appLog("[Workspace] clearTile: index=\(index) core#\(core.instanceId) (wasActive=\(index == activeTileIndex))")
                if index == activeTileIndex {
                    core.terminalView = nil
                    terminalView?.core = nil
                }
                tiles[index].core = nil  // ARC will call deinit → destroy → stop
                tiles[index].snapshot = nil
                return
            }
        }
        ZonvieCore.appLog("[Workspace] clearTile: core#\(core.instanceId) NOT FOUND in any tile")
    }

    /// True if any tile has a running core.
    var hasOccupiedTiles: Bool {
        tiles.contains { $0.isOccupied }
    }

    /// Index of the first occupied tile, or nil.
    var firstOccupiedTileIndex: Int? {
        tiles.firstIndex { $0.isOccupied }
    }

    // MARK: - Suspend / Resume

    func suspendTile(at index: Int) {
        guard index >= 0, index < tiles.count else { return }
        guard tiles[index].core != nil, !tiles[index].isSuspended else { return }
        // TODO: Phase 4 - call zonvie_core_suspend() once C API is available
        tiles[index].isSuspended = true
    }

    func resumeTile(at index: Int) {
        guard index >= 0, index < tiles.count else { return }
        guard tiles[index].isSuspended else { return }
        // TODO: Phase 4 - call zonvie_core_resume() once C API is available
        tiles[index].isSuspended = false
    }

    // MARK: - Scale control

    func scaleIn() {
        scale = min(1.0, scale + scaleStep)
    }

    func scaleOut() {
        scale -= scaleStep
    }

    /// True when the workspace overview grid should be displayed.
    var isOverviewVisible: Bool {
        scale <= 0.7
    }
}
