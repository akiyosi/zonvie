import Foundation
import AppKit
import Metal
import UserNotifications
import Carbon.HIToolbox

// Private macOS API for controlling window blur radius
// Types based on wezterm implementation: connection=id(pointer), windowId=NSInteger, radius=i64
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
private func CGSSetWindowBackgroundBlurRadius(_ connection: UInt, _ windowNumber: Int, _ radius: Int) -> Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt

final class ZonvieCore {
    private var core: OpaquePointer?
    private var ctxPtr: UnsafeMutableRawPointer?

    // SSH_ASKPASS script path for cleanup
    private var sshAskpassPath: String?

    // Devcontainer progress dialog
    private var progressWindow: NSWindow?
    private var isDevcontainerMode: Bool = false

    // Wire this from ViewController.
    weak var terminalView: MetalTerminalView? {
        didSet {
            if terminalView != nil {
                processPendingExternalWindows()
            }
        }
    }

    static var appLogEnabled = false
    static var appLogFilePath: String? = nil
    private static var logFileHandle: FileHandle? = nil

    // Notification posted when Neovim is ready (first vertices received)
    static let neovimReadyNotification = NSNotification.Name("ZonvieNeovimReady")
    private var hasNotifiedReady = false

    // Notification posted when colorscheme (default bg/fg) changes
    static let colorschemeDidChangeNotification = NSNotification.Name("ZonvieColorschemeDidChange")

    // Timeout for quit request (to handle unresponsive Neovim)
    private var quitTimeoutWorkItem: DispatchWorkItem?
    private var quitTimeoutFired: Bool = false  // Ignore delayed responses after timeout
    private static let quitTimeoutSeconds: Double = 5.0

    static func appLog(_ message: @autoclosure () -> String) {
        if !appLogEnabled { return }
        let line = "[zonvie] \(message())\n"

        if let handle = logFileHandle {
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        } else {
            fputs(line, stderr)
        }
    }

    /// Configure logging with file path (called from AppDelegate)
    static func configureLogging(enabled: Bool, filePath: String?) {
        appLogEnabled = enabled
        appLogFilePath = filePath

        // Close existing handle if any
        if let handle = logFileHandle {
            try? handle.close()
            logFileHandle = nil
        }

        // Open log file if path specified
        if enabled, let path = filePath {
            let fileManager = FileManager.default
            let url = URL(fileURLWithPath: path)

            // Create parent directory if needed
            let parentDir = url.deletingLastPathComponent()
            try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // Create file if doesn't exist
            if !fileManager.fileExists(atPath: path) {
                fileManager.createFile(atPath: path, contents: nil)
            }

            // Open for appending
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                logFileHandle = handle
            }
        }
    }

    /// Apply blur effect to window using private macOS API
    static func applyWindowBlur(window: NSWindow, radius: Int) {
        // DEBUG: Track blur application with caller info
        let caller = Thread.callStackSymbols.prefix(5).joined(separator: "\n  ")
        appLog("[DEBUG-BLUR] applyWindowBlur called: window=\(window.windowNumber) radius=\(radius) isOpaque=\(window.isOpaque) backgroundColor=\(String(describing: window.backgroundColor))")
        appLog("[DEBUG-BLUR] callStack:\n  \(caller)")

        let connection = CGSMainConnectionID()
        let windowNumber = window.windowNumber  // Already Int (NSInteger)

        let result = CGSSetWindowBackgroundBlurRadius(connection, windowNumber, radius)
        if result == 0 {
            appLog("[Blur] Applied blur radius=\(radius) to window \(windowNumber)")
        } else {
            appLog("[Blur] Failed to apply blur, error=\(result)")
        }
    }

    private var logEnabled = true

    init() {
        let unmanaged = Unmanaged.passUnretained(self)
        self.ctxPtr = unmanaged.toOpaque()

        var cb = zonvie_callbacks(
            on_vertices: { ctx, mainVerts, mainCount, cursorVerts, cursorCount in
                guard let ctx else { return }

                // INSERT inside on_vertices callback, after `guard let ctx else { return }`
                ZonvieCore.appLog("cb:on_vertices mainCount=\(mainCount) cursorCount=\(cursorCount)")

                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onVertices(
                    mainVerts: mainVerts,
                    mainCount: Int(mainCount),
                    cursorVerts: cursorVerts,
                    cursorCount: Int(cursorCount)
                )

                // Notify that Neovim is ready (first vertices received)
                if !me.hasNotifiedReady {
                    me.hasNotifiedReady = true
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: ZonvieCore.neovimReadyNotification, object: nil)
                    }
                }

                // Close devcontainer progress dialog on first render
                if me.isDevcontainerMode && me.progressWindow != nil {
                    me.hideDevcontainerProgress()
                }
            },

            on_vertices_partial: { ctx, mainVerts, mainCount, cursorVerts, cursorCount, flags in
                guard let ctx else { return }
                let core = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                guard let view = core.terminalView else { return }

                // ★ Added: completely ignore no-update notifications (without this, easily leads to requestRedraw(nil))
                if flags == 0 { return }

                let updateMain = (flags & UInt32(ZONVIE_VERT_UPDATE_MAIN)) != 0
                let updateCursor = (flags & UInt32(ZONVIE_VERT_UPDATE_CURSOR)) != 0

                // Safety: return if neither is updated
                if !updateMain && !updateCursor { return }

                // Update cursor blink timer when cursor is updated
                if updateCursor {
                    DispatchQueue.main.async {
                        core.updateCursorBlinking()
                    }
                }

                view.submitVerticesPartialRaw(
                    mainPtr: updateMain ? mainVerts : nil,
                    mainCount: updateMain ? Int(mainCount) : 0,
                    cursorPtr: updateCursor ? cursorVerts : nil,
                    cursorCount: updateCursor ? Int(cursorCount) : 0,
                    updateMain: updateMain,
                    updateCursor: updateCursor
                )
            },

            on_vertices_row: { ctx, gridId, rowStart, rowCount, verts, vertCount, flags, totalRows, totalCols in
                guard let ctx else { return }

                ZonvieCore.appLog("cb:on_vertices_row gridId=\(gridId) rowStart=\(rowStart) rowCount=\(rowCount) vertCount=\(vertCount) flags=0x\(String(flags, radix: 16)) totalRows=\(totalRows) totalCols=\(totalCols)")

                let core = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()

                // Notify that Neovim is ready (first vertices received)
                if !core.hasNotifiedReady {
                    core.hasNotifiedReady = true
                    ZonvieCore.appLog("zonvie: posting neovimReadyNotification")
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: ZonvieCore.neovimReadyNotification, object: nil)
                        // Close devcontainer progress dialog if shown
                        core.hideDevcontainerProgress()
                    }
                }

                if gridId == 1 {
                    // Main window
                    guard let view = core.terminalView else { return }
                    view.submitVerticesRowRaw(
                        rowStart: Int(rowStart),
                        rowCount: Int(rowCount),
                        ptr: verts,
                        count: Int(vertCount),
                        flags: flags,
                        totalRows: Int(totalRows)
                    )
                } else {
                    // External grid: copy vertex data on RPC thread, then dispatch
                    // all dictionary access and submission to main thread.
                    // This ensures externalGridViews is only accessed from main thread.
                    let vertexArray: [zonvie_vertex]? = if let verts = verts, vertCount > 0 {
                        Array(UnsafeBufferPointer(start: verts, count: Int(vertCount)))
                    } else {
                        nil
                    }
                    let rs = Int(rowStart)
                    let rc = Int(rowCount)
                    let tr = Int(totalRows)
                    let tc = Int(totalCols)

                    DispatchQueue.main.async { [weak core] in
                        guard let core = core else { return }

                        if let gridView = core.externalGridViews[gridId] {
                            if let vertexArray = vertexArray {
                                vertexArray.withUnsafeBufferPointer { buffer in
                                    gridView.submitVerticesRowRaw(
                                        rowStart: rs,
                                        rowCount: rc,
                                        ptr: buffer.baseAddress,
                                        count: buffer.count,
                                        totalRows: tr,
                                        totalCols: tc
                                    )
                                }

                                // On first row, configure background color and window layout
                                if rs == 0 {
                                    vertexArray.withUnsafeBufferPointer { buffer in
                                        if let baseAddr = buffer.baseAddress {
                                            core.configureExternalGridFromRow(
                                                gridId: gridId,
                                                gridView: gridView,
                                                verts: baseAddr,
                                                vertCount: buffer.count,
                                                rows: totalRows,
                                                cols: totalCols
                                            )
                                        }
                                    }
                                }
                            } else {
                                // vertCount==0: submit empty row to clear it
                                gridView.submitVerticesRowRaw(
                                    rowStart: rs,
                                    rowCount: rc,
                                    ptr: nil,
                                    count: 0,
                                    totalRows: tr,
                                    totalCols: tc
                                )
                            }

                            // Request redraw after last row is submitted
                            if rs == tr - 1 {
                                gridView.requestRedraw()
                            }
                        } else if let vertexArray = vertexArray {
                            // GridView not created yet - save vertices for later (per-row, non-empty only)
                            ZonvieCore.appLog("[on_vertices_row] gridId=\(gridId) no gridView yet, saving \(vertexArray.count) vertices for row \(rs)")
                            if var existing = core.pendingExternalVertices[gridId] {
                                existing.rowVertices[rs] = vertexArray
                                core.pendingExternalVertices[gridId] = existing
                            } else {
                                core.pendingExternalVertices[gridId] = (rowVertices: [rs: vertexArray], rows: totalRows, cols: totalCols)
                            }
                        }
                    }
                }
            },

            on_atlas_ensure_glyph: { ctx, scalar, outEntry in
                return zonvie_macos_atlas_ensure_glyph(ctx, scalar, outEntry)
            },

            on_atlas_ensure_glyph_styled: { ctx, scalar, styleFlags, outEntry in
                return zonvie_macos_atlas_ensure_glyph_styled(ctx, scalar, styleFlags, outEntry)
            },

            on_render_plan: nil,
            on_log: { ctx, bytes, len in
                guard let ctx, let bytes else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                if !me.logEnabled { return }
                me.onLog(bytes: bytes, len: Int(len))
            },
            on_guifont: { ctx, bytes, len in
                guard let ctx, let bytes else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onGuiFont(bytes: bytes, len: Int(len))
            },

            on_linespace: { ctx, px in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onLineSpace(px: px)
            },
            on_exit: { ctx, exitCode in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onExitFromNvim(exitCode: exitCode)
            },
            on_set_title: { ctx, title, titleLen in
                guard let ctx, let title else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onSetTitle(title: title, titleLen: Int(titleLen))
            },
            on_external_window: { ctx, gridId, win, rows, cols, startRow, startCol in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onExternalWindow(gridId: gridId, win: win, rows: rows, cols: cols, startRow: startRow, startCol: startCol)
            },
            on_external_window_close: { ctx, gridId in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onExternalWindowClose(gridId: gridId)
            },
            on_external_vertices: { ctx, gridId, verts, vertCount, rows, cols in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onExternalVertices(gridId: gridId, verts: verts, vertCount: vertCount, rows: rows, cols: cols)
            },
            on_cursor_grid_changed: { ctx, gridId in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onCursorGridChanged(gridId: gridId)
            },
            // ext_cmdline callbacks
            on_cmdline_show: { ctx, content, contentCount, pos, firstc, prompt, promptLen, indent, level, promptHlId in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onCmdlineShow(
                    content: content, contentCount: contentCount,
                    pos: pos, firstc: firstc,
                    prompt: prompt, promptLen: promptLen,
                    indent: indent, level: level, promptHlId: promptHlId
                )
            },
            on_cmdline_hide: { ctx, level in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onCmdlineHide(level: level)
            },
            on_cmdline_pos: { ctx, pos, level in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onCmdlinePos(pos: pos, level: level)
            },
            on_cmdline_special_char: { ctx, c, cLen, shift, level in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onCmdlineSpecialChar(c: c, cLen: cLen, shift: shift != 0, level: level)
            },
            on_cmdline_block_show: { ctx, lines, lineCount in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onCmdlineBlockShow(lines: lines, lineCount: lineCount)
            },
            on_cmdline_block_append: { ctx, line, chunkCount in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onCmdlineBlockAppend(line: line, chunkCount: chunkCount)
            },
            on_cmdline_block_hide: { ctx in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onCmdlineBlockHide()
            },
            // ext_popupmenu callbacks
            on_popupmenu_show: { ctx, items, itemCount, selected, row, col, gridId in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onPopupmenuShow(items: items, itemCount: itemCount, selected: selected, row: row, col: col, gridId: gridId)
            },
            on_popupmenu_hide: { ctx in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onPopupmenuHide()
            },
            on_popupmenu_select: { ctx, selected in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onPopupmenuSelect(selected: selected)
            },
            // ext_messages callbacks
            on_msg_show: { ctx, view, kind, kindLen, chunks, chunkCount, replaceLast, history, append, msgId, timeoutMs in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onMsgShow(view: view, kind: kind, kindLen: kindLen, chunks: chunks, chunkCount: chunkCount,
                             replaceLast: replaceLast, history: history, append: append, msgId: msgId, timeoutMs: timeoutMs)
            },
            on_msg_clear: { ctx in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onMsgClear()
            },
            on_msg_showmode: { ctx, view, chunks, chunkCount in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onMsgShowmode(view: view, chunks: chunks, chunkCount: chunkCount)
            },
            on_msg_showcmd: { ctx, view, chunks, chunkCount in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onMsgShowcmd(view: view, chunks: chunks, chunkCount: chunkCount)
            },
            on_msg_ruler: { ctx, view, chunks, chunkCount in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onMsgRuler(view: view, chunks: chunks, chunkCount: chunkCount)
            },
            on_msg_history_show: { ctx, entries, entryCount, prevCmd in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onMsgHistoryShow(entries: entries, entryCount: entryCount, prevCmd: prevCmd)
            },
            // Clipboard callbacks
            on_clipboard_get: { ctx, register, outBuf, outLen, maxLen in
                guard let ctx, let outBuf, let outLen else { return 0 }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                return me.onClipboardGet(register: register, outBuf: outBuf, outLen: outLen, maxLen: maxLen)
            },
            on_clipboard_set: { ctx, register, data, len in
                guard let ctx, let data else { return 0 }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                return me.onClipboardSet(register: register, data: data, len: len)
            },
            on_ssh_auth_prompt: { ctx, prompt, promptLen in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                let promptStr: String
                if let prompt, promptLen > 0 {
                    promptStr = String(bytes: UnsafeBufferPointer(start: prompt, count: Int(promptLen)), encoding: .utf8) ?? "SSH Password:"
                } else {
                    promptStr = "SSH Password:"
                }
                me.onSSHAuthPrompt(prompt: promptStr)
            },
            on_tabline_update: { ctx, curtab, tabs, tabCount, curbuf, buffers, bufferCount in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onTablineUpdate(curtab: curtab, tabs: tabs, tabCount: Int(tabCount),
                                   curbuf: curbuf, buffers: buffers, bufferCount: Int(bufferCount))
            },
            on_tabline_hide: { ctx in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onTablineHide()
            },
            on_grid_scroll: { ctx, gridId in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onGridScroll(gridId: gridId)
            },
            on_ime_off: { ctx in
                guard let ctx else { return }
                // Must call on main thread (Carbon TIS API requirement)
                DispatchQueue.main.async {
                    ZonvieCore.setIMEOff()
                }
            },
            on_quit_requested: { ctx, hasUnsaved in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.onQuitRequested(hasUnsaved: hasUnsaved != 0)
            },

            on_rasterize_glyph: { ctx, scalar, styleFlags, outBitmap in
                return zonvie_macos_rasterize_glyph(ctx, scalar, styleFlags, outBitmap)
            },
            on_atlas_upload: { ctx, destX, destY, width, height, bitmap in
                zonvie_macos_atlas_upload(ctx, destX, destY, width, height, bitmap)
            },
            on_atlas_create: { ctx, atlasW, atlasH in
                zonvie_macos_atlas_create(ctx, atlasW, atlasH)
            },
            on_flush_begin: { ctx in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                me.terminalView?.renderer.beginFlush()
            },
            on_flush_end: { ctx in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                // Read drawable size from core while grid_mu is still held.
                // These values match exactly what the flush used for NDC computation.
                var dw: UInt32 = 0
                var dh: UInt32 = 0
                if let corePtr = me.core {
                    zonvie_core_get_layout(corePtr, &dw, &dh, nil, nil)
                }
                me.terminalView?.renderer.commitFlush(drawableW: dw, drawableH: dh)
                // Pass Neovim default background to renderer for viewport-edge clear color
                if let corePtr = me.core {
                    let bg = zonvie_core_get_default_bg(corePtr)
                    me.terminalView?.renderer.updateDefaultBgColor(bg)
                }
            },

            // Colorscheme change notification (from default_colors_set redraw event).
            // Runs on core thread with grid_mu held — dispatch to main for UI update.
            on_default_colors_set: { ctx, fg, bg in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: ZonvieCore.colorschemeDidChangeNotification,
                        object: nil,
                        userInfo: ["bgRGB": bg, "fgRGB": fg]
                    )
                }
            },

            // ext_windows layout operation callbacks
            on_win_move: { ctx, gridId, win, flags in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                ZonvieCore.appLog("[ext_win] on_win_move: grid=\(gridId) win=\(win) flags=\(flags)")
                DispatchQueue.main.async { me.handleWinMove(gridId: gridId, flags: flags) }
            },
            on_win_exchange: { ctx, gridId, win, count in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                ZonvieCore.appLog("[ext_win] on_win_exchange: grid=\(gridId) win=\(win) count=\(count)")
                DispatchQueue.main.async { me.handleWinExchange(gridId: gridId, count: count) }
            },
            on_win_rotate: { ctx, gridId, win, direction, count in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                ZonvieCore.appLog("[ext_win] on_win_rotate: grid=\(gridId) win=\(win) direction=\(direction) count=\(count)")
                DispatchQueue.main.async { me.handleWinRotate(direction: direction, count: count) }
            },
            on_win_resize_equal: { ctx in
                guard let ctx else { return }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                ZonvieCore.appLog("[ext_win] on_win_resize_equal")
                DispatchQueue.main.async { me.handleWinResizeEqual() }
            },
            on_win_move_cursor: { ctx, direction, count in
                guard let ctx else { return 0 }
                let me = Unmanaged<ZonvieCore>.fromOpaque(ctx).takeUnretainedValue()
                ZonvieCore.appLog("[ext_win] on_win_move_cursor: direction=\(direction) count=\(count)")
                return me.handleWinMoveCursor(direction: direction, count: count)
            }
        )

        self.core = zonvie_core_create(&cb, MemoryLayout<zonvie_callbacks>.size, self.ctxPtr)

        // Setup SSH authentication notification observer
        setupSSHNotificationObserver()
    }

    deinit {
        if let core { zonvie_core_destroy(core) }
        core = nil
        ctxPtr = nil

        // Cleanup SSH_ASKPASS script
        if let path = sshAskpassPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Enable ext_cmdline UI extension. Must be called before start().
    func setExtCmdline(_ enabled: Bool) {
        guard let core else { return }
        zonvie_core_set_ext_cmdline(core, enabled ? 1 : 0)
    }

    /// Enable ext_popupmenu UI extension. Must be called before start().
    func setExtPopupmenu(_ enabled: Bool) {
        guard let core else { return }
        zonvie_core_set_ext_popupmenu(core, enabled ? 1 : 0)
        ZonvieCore.appLog("[ZonvieCore] setExtPopupmenu(\(enabled))")
    }

    /// Enable ext_messages UI extension. Must be called before start().
    func setExtMessages(_ enabled: Bool) {
        guard let core else { return }
        zonvie_core_set_ext_messages(core, enabled ? 1 : 0)
        ZonvieCore.appLog("[ZonvieCore] setExtMessages(\(enabled))")
    }

    /// Enable ext_tabline UI extension. Must be called before start().
    func setExtTabline(_ enabled: Bool) {
        guard let core else { return }
        zonvie_core_set_ext_tabline(core, enabled ? 1 : 0)
        ZonvieCore.appLog("[ZonvieCore] setExtTabline(\(enabled))")
    }

    /// Enable ext_windows UI extension. Must be called before start().
    func setExtWindows(_ enabled: Bool) {
        guard let core else { return }
        zonvie_core_set_ext_windows(core, enabled ? 1 : 0)
        ZonvieCore.appLog("[ZonvieCore] setExtWindows(\(enabled))")
    }

    /// Enable blur transparency for background. Must be called before start().
    func setBlurEnabled(_ enabled: Bool) {
        guard let core else { return }
        zonvie_core_set_blur_enabled(core, enabled ? 1 : 0)
        ZonvieCore.appLog("[ZonvieCore] setBlurEnabled(\(enabled))")
    }

    /// Set inherit_cwd flag. Must be called before start().
    func setInheritCwd(_ enabled: Bool) {
        guard let core else { return }
        zonvie_core_set_inherit_cwd(core, enabled ? 1 : 0)
        ZonvieCore.appLog("[ZonvieCore] setInheritCwd(\(enabled))")
    }

    /// Check if msg_show throttle timeout has expired.
    /// Frontend should call this periodically (e.g., every frame) to ensure
    /// messages are displayed even when Neovim is waiting for user input.
    func tickMsgThrottle() {
        guard let core else { return }
        zonvie_core_tick_msg_throttle(core)
    }

    func start(nvimPath: String, rows: UInt32, cols: UInt32) -> Int32 {
        guard let core else { return -1 }

        // Load config into Zig core for message routing
        let configPath = ZonvieConfig.configFilePath.path
        configPath.withCString { cPath in
            let result = zonvie_core_load_config(core, cPath)
            ZonvieCore.appLog("[start] zonvie_core_load_config(\(configPath)) = \(result)")
        }

        // Check command line arguments and config file for ext_* options
        let args = CommandLine.arguments
        ZonvieCore.appLog("[start] CommandLine.arguments = \(args)")

        // ext_cmdline: CLI flag or config file
        let hasExtCmdline = args.contains("--extcmdline") || ZonvieConfig.shared.cmdline.external
        ZonvieCore.appLog("[start] hasExtCmdline = \(hasExtCmdline) (cli=\(args.contains("--extcmdline")), config=\(ZonvieConfig.shared.cmdline.external))")

        if hasExtCmdline {
            ZonvieCore.appLog("[start] enabling ext_cmdline")
            setExtCmdline(true)
        }

        // ext_popupmenu: CLI flag or config file
        let hasExtPopup = args.contains("--extpopup") || ZonvieConfig.shared.popup.external
        ZonvieCore.appLog("[start] hasExtPopup = \(hasExtPopup) (cli=\(args.contains("--extpopup")), config=\(ZonvieConfig.shared.popup.external))")

        if hasExtPopup {
            ZonvieCore.appLog("[start] enabling ext_popupmenu")
            setExtPopupmenu(true)
        }

        // ext_messages: CLI flag or config file
        let hasExtMessages = args.contains("--extmessages") || ZonvieConfig.shared.messages.external
        ZonvieCore.appLog("[start] hasExtMessages = \(hasExtMessages) (cli=\(args.contains("--extmessages")), config=\(ZonvieConfig.shared.messages.external))")

        if hasExtMessages {
            ZonvieCore.appLog("[start] enabling ext_messages")
            setExtMessages(true)
        }

        // ext_tabline: CLI flag or config file
        let hasExtTabline = args.contains("--exttabline") || ZonvieConfig.shared.tabline.external
        ZonvieCore.appLog("[start] hasExtTabline = \(hasExtTabline) (cli=\(args.contains("--exttabline")), config=\(ZonvieConfig.shared.tabline.external))")

        if hasExtTabline {
            ZonvieCore.appLog("[start] enabling ext_tabline")
            setExtTabline(true)
        }

        // ext_windows: CLI flag or config file
        let hasExtWindows = args.contains("--extwindows") || ZonvieConfig.shared.windows.external
        ZonvieCore.appLog("[start] hasExtWindows = \(hasExtWindows) (cli=\(args.contains("--extwindows")), config=\(ZonvieConfig.shared.windows.external))")

        if hasExtWindows {
            ZonvieCore.appLog("[start] enabling ext_windows")
            setExtWindows(true)
        }

        // Parse SSH arguments from CLI: --ssh=user@host[:port], --ssh-identity=path
        var sshHost: String? = nil
        var sshPort: Int? = nil
        var sshIdentity: String? = nil

        // Parse devcontainer arguments from CLI: --devcontainer=path, --devcontainer-config=path, --devcontainer-rebuild
        var devcontainerWorkspace: String? = nil
        var devcontainerConfig: String? = nil
        var devcontainerRebuild: Bool = false

        for arg in args {
            if arg.hasPrefix("--ssh=") {
                let value = String(arg.dropFirst("--ssh=".count))
                // Parse user@host:port format (port is after last colon, but only if it's numeric)
                if let lastColon = value.lastIndex(of: ":"),
                   let portPart = Int(value[value.index(after: lastColon)...]) {
                    sshHost = String(value[..<lastColon])
                    sshPort = portPart
                } else {
                    sshHost = value
                }
            } else if arg.hasPrefix("--ssh-identity=") {
                sshIdentity = String(arg.dropFirst("--ssh-identity=".count))
            } else if arg.hasPrefix("--devcontainer=") {
                devcontainerWorkspace = String(arg.dropFirst("--devcontainer=".count))
            } else if arg.hasPrefix("--devcontainer-config=") {
                devcontainerConfig = String(arg.dropFirst("--devcontainer-config=".count))
            } else if arg == "--devcontainer-rebuild" {
                devcontainerRebuild = true
            }
        }

        // Fall back to config if not specified via CLI
        let config = ZonvieConfig.shared
        if sshHost == nil && config.neovim.ssh {
            sshHost = config.neovim.sshHost
            sshPort = sshPort ?? config.neovim.sshPort
            sshIdentity = sshIdentity ?? config.neovim.sshIdentity
        }

        ZonvieCore.appLog("[start] SSH config: host=\(sshHost ?? "nil"), port=\(sshPort ?? -1), identity=\(sshIdentity ?? "nil")")

        // Build final command path
        var finalPath = nvimPath
        if let host = sshHost {
            // Create SSH_ASKPASS script that shows dialog on demand
            // This handles both password auth and key passphrase
            let tempDir = FileManager.default.temporaryDirectory
            let askpassPath = tempDir.appendingPathComponent("zonvie_askpass_\(ProcessInfo.processInfo.processIdentifier).sh")
            let logPath = tempDir.appendingPathComponent("zonvie_askpass_\(ProcessInfo.processInfo.processIdentifier).log").path

            // Script uses osascript to show dialog when SSH requests password/passphrase
            let scriptContent = """
                #!/bin/bash
                echo "SSH_ASKPASS called at $(date)" >> "\(logPath)"
                echo "Prompt: $1" >> "\(logPath)"
                PASS=$(osascript -e 'display dialog "'"$1"'" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK"' -e 'text returned of result' 2>/dev/null)
                if [ $? -ne 0 ]; then
                    echo "User cancelled" >> "\(logPath)"
                    exit 1
                fi
                echo "$PASS"
                """
            do {
                try scriptContent.write(to: askpassPath, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpassPath.path)
                setenv("SSH_ASKPASS", askpassPath.path, 1)
                setenv("SSH_ASKPASS_REQUIRE", "force", 1)
                setenv("DISPLAY", ":0", 1)
                ZonvieCore.appLog("[start] SSH_ASKPASS script created: \(askpassPath.path)")
                self.sshAskpassPath = askpassPath.path
            } catch {
                ZonvieCore.appLog("[start] Failed to create SSH_ASKPASS script: \(error)")
            }

            // Build SSH command with ssh-askpass prefix
            // SSH will call SSH_ASKPASS only when it needs password/passphrase
            var sshCmd = "ssh-askpass /usr/bin/ssh"
            if let port = sshPort {
                sshCmd += " -p \(port)"
            }
            if let identity = sshIdentity {
                // Public key auth: use identity file, disable password auth
                ZonvieCore.appLog("[start] SSH mode: public key auth (identity=\(identity))")
                sshCmd += " -i \(identity)"
                sshCmd += " -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no"
            } else {
                ZonvieCore.appLog("[start] SSH mode: password auth")
            }
            sshCmd += " -o StrictHostKeyChecking=accept-new"
            sshCmd += " \(host) '$SHELL --login -c \"nvim --embed\"'"
            finalPath = sshCmd
            ZonvieCore.appLog("[start] SSH mode enabled, command: \(finalPath)")
        } else if let workspace = devcontainerWorkspace {
            // Devcontainer mode
            isDevcontainerMode = true
            let configArg = devcontainerConfig

            if devcontainerRebuild {
                // Rebuild mode: run 'devcontainer up' first, then 'devcontainer exec'
                DispatchQueue.main.async { [weak self] in
                    self?.showDevcontainerProgress()
                    self?.updateProgressLabel("Building devcontainer...")
                    self?.runDevcontainerUp(workspace: workspace, configPath: configArg, rebuild: true, rows: rows, cols: cols)
                }
                // Return early - Zig core will be started after devcontainer up completes
                return 0
            } else {
                // Normal mode: connect directly with 'devcontainer exec'
                DispatchQueue.main.async { [weak self] in
                    self?.showDevcontainerProgress()
                    self?.updateProgressLabel("Connecting...")
                    self?.startDevcontainerExec(workspace: workspace, configPath: configArg, rows: rows, cols: cols)
                }
                return 0
            }
        }

        // Append extra arguments for nvim (collected in main.swift)
        // Only for native mode (not SSH/devcontainer - local file paths don't make sense on remote)
        if sshHost == nil && !isDevcontainerMode && !nvimExtraArgs.isEmpty {
            // Escape arguments with spaces and special characters
            let escapedArgs = nvimExtraArgs.map { arg -> String in
                if arg.contains(" ") || arg.contains("'") || arg.contains("\"") {
                    // Wrap in single quotes, escape existing single quotes
                    return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
                }
                return arg
            }
            finalPath += " " + escapedArgs.joined(separator: " ")
            ZonvieCore.appLog("[start] Added nvim extra args: \(nvimExtraArgs)")
        }

        // Enable blur transparency for macOS (always enabled for blur effect)
        setBlurEnabled(true)

        // Inherit CWD from parent when --nofork mode is active
        setInheritCwd(noforkMode)

        // Set glyph cache sizes from config (for performance tuning)
        let perfConfig = config.performance
        zonvie_core_set_glyph_cache_size(
            core,
            UInt32(perfConfig.glyphCacheAsciiSize),
            UInt32(perfConfig.glyphCacheNonAsciiSize)
        )

        let cstr = (finalPath as NSString).utf8String
        let result = Int32(zonvie_core_start(core, cstr, rows, cols))

        // Enable Zig core logging based on app log setting
        zonvie_core_set_log_enabled(core, ZonvieCore.appLogEnabled ? 1 : 0)

        return result
    }

    func stop() {
        guard let core else { return }
        zonvie_core_stop(core)
    }

    // MARK: - Devcontainer Progress Dialog

    private var progressLabel: NSTextField?
    private var progressSpinner: NSProgressIndicator?

    private func showDevcontainerProgress() {
        guard progressWindow == nil else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Devcontainer"
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))

        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 25, width: 30, height: 30))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        contentView.addSubview(spinner)
        progressSpinner = spinner

        let label = NSTextField(labelWithString: "Building devcontainer...")
        label.frame = NSRect(x: 60, y: 30, width: 220, height: 20)
        label.font = NSFont.systemFont(ofSize: 13)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        contentView.addSubview(label)
        progressLabel = label

        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)

        progressWindow = window
        ZonvieCore.appLog("[devcontainer] Progress dialog shown")
    }

    private func updateProgressLabel(_ text: String) {
        progressLabel?.stringValue = text
    }

    private func hideDevcontainerProgress() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.progressWindow else { return }
            window.close()
            self?.progressWindow = nil
            self?.progressLabel = nil
            self?.progressSpinner = nil
            self?.isDevcontainerMode = false
            ZonvieCore.appLog("[devcontainer] Progress dialog closed")
        }
    }

    /// Check if Docker is running by executing `docker info`
    private func isDockerRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = ["info"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            // Try with /opt/homebrew/bin/docker (Apple Silicon)
            let process2 = Process()
            process2.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/docker")
            process2.arguments = ["info"]
            process2.standardOutput = FileHandle.nullDevice
            process2.standardError = FileHandle.nullDevice
            do {
                try process2.run()
                process2.waitUntilExit()
                return process2.terminationStatus == 0
            } catch {
                return false
            }
        }
    }

    /// Start Docker Desktop and wait until it's ready
    private func ensureDockerRunning(updateLabel: @escaping (String) -> Void) -> Bool {
        if isDockerRunning() {
            ZonvieCore.appLog("[devcontainer] Docker is already running")
            return true
        }

        ZonvieCore.appLog("[devcontainer] Docker not running, starting Docker Desktop...")
        updateLabel("Starting Docker...")

        // Start Docker Desktop
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Docker"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            ZonvieCore.appLog("[devcontainer] Failed to start Docker: \(error.localizedDescription)")
            return false
        }

        // Wait for Docker to be ready (up to 60 seconds)
        let maxWaitSeconds = 60
        for i in 0..<maxWaitSeconds {
            Thread.sleep(forTimeInterval: 1.0)
            if isDockerRunning() {
                ZonvieCore.appLog("[devcontainer] Docker started successfully after \(i+1) seconds")
                return true
            }
            updateLabel("Starting Docker... (\(i+1)s)")
        }

        ZonvieCore.appLog("[devcontainer] Docker failed to start within \(maxWaitSeconds) seconds")
        return false
    }

    private func runDevcontainerUp(workspace: String, configPath: String?, rebuild: Bool, rows: UInt32, cols: UInt32) {
        let neovimFeature = #"{"ghcr.io/duduribeiro/devcontainer-features/neovim:1":{}}"#
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let nvimConfigPath = "\(homeDir)/.config/nvim"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Ensure Docker is running first
            let dockerReady = self.ensureDockerRunning { [weak self] text in
                DispatchQueue.main.async {
                    self?.updateProgressLabel(text)
                }
            }

            if !dockerReady {
                DispatchQueue.main.async { [weak self] in
                    self?.updateProgressLabel("Error: Docker failed to start")
                    self?.progressSpinner?.stopAnimation(nil)
                }
                return
            }

            // Update dialog to show "Building..."
            DispatchQueue.main.async { [weak self] in
                self?.updateProgressLabel("Building devcontainer...")
            }

            // Build devcontainer up arguments
            var args = ["up", "--workspace-folder", workspace]
            if let config = configPath {
                args += ["--config", config]
            }
            args += ["--additional-features", neovimFeature]
            args += ["--mount", "type=bind,source=\(nvimConfigPath),target=/nvim-config/nvim"]
            if rebuild {
                args += ["--remove-existing-container"]
            }

            // Marker files for completion detection
            let tempDir = FileManager.default.temporaryDirectory.path
            let doneFile = "\(tempDir)/devcontainer_done_\(ProcessInfo.processInfo.processIdentifier)"
            let failFile = "\(tempDir)/devcontainer_fail_\(ProcessInfo.processInfo.processIdentifier)"

            // Clean up any previous marker files
            try? FileManager.default.removeItem(atPath: doneFile)
            try? FileManager.default.removeItem(atPath: failFile)

            // Use environment variables to pass arguments (avoids shell escaping issues)
            var env = ProcessInfo.processInfo.environment
            env["DC_WORKSPACE"] = workspace
            env["DC_FEATURES"] = neovimFeature
            env["DC_MOUNT"] = "type=bind,source=\(nvimConfigPath),target=/nvim-config/nvim"
            env["DC_DONE"] = doneFile
            env["DC_FAIL"] = failFile
            if let config = configPath {
                env["DC_CONFIG"] = config
            }

            // Build shell command using env vars
            var shellCmd = "script -q /dev/null sh -c '"
            shellCmd += "devcontainer up --workspace-folder \"$DC_WORKSPACE\" --additional-features \"$DC_FEATURES\" --mount \"$DC_MOUNT\""
            if configPath != nil {
                shellCmd += " --config \"$DC_CONFIG\""
            }
            if rebuild {
                shellCmd += " --remove-existing-container"
            }
            shellCmd += " && touch \"$DC_DONE\" || touch \"$DC_FAIL\"' > /dev/null 2>&1 &"

            ZonvieCore.appLog("[devcontainer] Running: \(shellCmd)")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", shellCmd]
            process.environment = env

            do {
                ZonvieCore.appLog("[devcontainer] Starting background process...")
                try process.run()
                process.waitUntilExit()  // This returns immediately since command ends with &
                ZonvieCore.appLog("[devcontainer] Background process launched")
            } catch {
                ZonvieCore.appLog("[devcontainer] Process error: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.updateProgressLabel("Error: \(error.localizedDescription)")
                    self?.progressSpinner?.stopAnimation(nil)
                }
                return
            }

            // Poll for completion
            ZonvieCore.appLog("[devcontainer] Polling for completion...")
            while true {
                Thread.sleep(forTimeInterval: 1.0)

                if FileManager.default.fileExists(atPath: doneFile) {
                    try? FileManager.default.removeItem(atPath: doneFile)
                    ZonvieCore.appLog("[devcontainer] up completed successfully")

                    DispatchQueue.main.async { [weak self] in
                        self?.updateProgressLabel("Connecting to Neovim...")
                        self?.startDevcontainerExec(workspace: workspace, configPath: configPath, rows: rows, cols: cols)
                    }
                    break
                }

                if FileManager.default.fileExists(atPath: failFile) {
                    try? FileManager.default.removeItem(atPath: failFile)
                    ZonvieCore.appLog("[devcontainer] up failed")

                    DispatchQueue.main.async { [weak self] in
                        self?.updateProgressLabel("devcontainer up failed")
                        self?.progressSpinner?.stopAnimation(nil)
                    }
                    break
                }
            }
        }
    }

    private func startDevcontainerExec(workspace: String, configPath: String?, rows: UInt32, cols: UInt32) {
        guard let core = core else { return }

        // Build devcontainer exec command
        var cmd = "devcontainer exec --workspace-folder \"\(workspace)\""
        if let config = configPath {
            cmd += " --config \"\(config)\""
        }
        cmd += " --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed"

        ZonvieCore.appLog("[devcontainer] Starting exec: \(cmd)")

        let cstr = (cmd as NSString).utf8String
        _ = zonvie_core_start(core, cstr, rows, cols)
        zonvie_core_set_log_enabled(core, ZonvieCore.appLogEnabled ? 1 : 0)

        // Note: Progress dialog will be closed by neovimReadyNotification observer
        // Don't close it here - nvim may not be ready yet
    }

    func sendInput(_ s: String) {
        guard let core else {
            ZonvieCore.appLog("[sendInput] core is nil")
            return
        }
        let data = s.data(using: .utf8) ?? Data()
        ZonvieCore.appLog("[sendInput] sending \"\(s)\" (\(data.count) bytes)")
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                ZonvieCore.appLog("[sendInput] failed to get base address")
                return
            }
            zonvie_core_send_input(core, base, Int32(data.count))
        }
    }

    /// Send a command to Neovim via nvim_command RPC (does not show in cmdline).
    /// Prefer this over sendInput for commands that should not appear in the command line.
    func sendCommand(_ cmd: String) {
        guard let core else {
            ZonvieCore.appLog("[sendCommand] core is nil")
            return
        }
        let data = cmd.data(using: .utf8) ?? Data()
        ZonvieCore.appLog("[sendCommand] sending \"\(cmd)\" (\(data.count) bytes)")
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                ZonvieCore.appLog("[sendCommand] failed to get base address")
                return
            }
            zonvie_core_send_command(core, base, data.count)
        }
    }

    /// Request graceful quit (called by frontend on window close button).
    /// Checks for unsaved buffers and calls on_quit_requested callback with result.
    /// Includes a timeout to handle unresponsive Neovim.
    func requestQuit() {
        guard let core else {
            ZonvieCore.appLog("[requestQuit] core is nil")
            return
        }

        // Cancel any existing timeout and reset state
        quitTimeoutWorkItem?.cancel()
        quitTimeoutFired = false

        // Start timeout timer
        let timeoutWork = DispatchWorkItem { [weak self] in
            ZonvieCore.appLog("[requestQuit] timeout - Neovim not responding")
            self?.quitTimeoutFired = true
            self?.showNotRespondingDialog()
        }
        quitTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ZonvieCore.quitTimeoutSeconds,
            execute: timeoutWork
        )

        ZonvieCore.appLog("[requestQuit] requesting quit (timeout=\(ZonvieCore.quitTimeoutSeconds)s)")
        zonvie_core_request_quit(core)
    }

    /// Confirm quit after user dialog.
    /// force: if true, use :qa! (discard changes), otherwise :qa
    func confirmQuit(force: Bool) {
        guard let core else {
            ZonvieCore.appLog("[confirmQuit] core is nil")
            return
        }
        ZonvieCore.appLog("[confirmQuit] confirming quit (force=\(force))")
        zonvie_core_quit_confirmed(core, force ? 1 : 0)
    }

    /// Called from on_quit_requested callback when quit is requested.
    private func onQuitRequested(hasUnsaved: Bool) {
        ZonvieCore.appLog("[onQuitRequested] hasUnsaved=\(hasUnsaved)")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Ignore delayed response if timeout already fired and user chose to wait
            if self.quitTimeoutFired {
                ZonvieCore.appLog("[onQuitRequested] ignoring - timeout already fired")
                return
            }

            // Cancel timeout - Neovim responded in time
            self.quitTimeoutWorkItem?.cancel()
            self.quitTimeoutWorkItem = nil

            if hasUnsaved {
                self.showUnsavedDialog()
            } else {
                // No unsaved buffers - proceed with :qa
                self.confirmQuit(force: false)
            }
        }
    }

    /// Show native dialog for unsaved buffers confirmation.
    private func showUnsavedDialog() {
        let alert = NSAlert()
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "You have unsaved changes. Do you want to discard them and quit?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            confirmQuit(force: true)
        }
        // Cancel -> do nothing
    }

    /// Show dialog when Neovim is not responding to quit request.
    private func showNotRespondingDialog() {
        let alert = NSAlert()
        alert.messageText = "Neovim Not Responding"
        alert.informativeText = "Neovim is not responding. Do you want to force quit?"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Wait")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Force quit - terminate the app immediately
            ZonvieCore.appLog("[showNotRespondingDialog] user chose Force Quit")
            NSApp.terminate(nil)
        }
        // Wait -> do nothing, user can try closing again later
    }

    /// Set the position for the next external window created via nvim_win_set_config(external=true).
    /// This is used by tab externalization to place the window at the mouse cursor position.
    /// The pending position is automatically cleared after 500ms if not consumed (to prevent stale state).
    func setPendingExternalWindowPosition(_ position: NSPoint) {
        ZonvieCore.appLog("[external_window] setPendingExternalWindowPosition: \(position)")
        pendingExternalWindowPosition = position

        // Clear pending position after timeout to prevent stale state if externalization fails
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.pendingExternalWindowPosition != nil {
                ZonvieCore.appLog("[external_window] clearing stale pendingExternalWindowPosition (timeout)")
                self?.pendingExternalWindowPosition = nil
            }
        }
    }


    func sendKeyEvent(
        keyCode: UInt32,
        mods: UInt32,
        characters: String?,
        charactersIgnoringModifiers: String?
    ) {
        guard let core else { return }

        let charsData = characters?.data(using: .utf8)
        let ignData = charactersIgnoringModifiers?.data(using: .utf8)

        let charsBytes: UnsafePointer<UInt8>? = charsData?.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt8.self).baseAddress
        }
        let ignBytes: UnsafePointer<UInt8>? = ignData?.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt8.self).baseAddress
        }

        // NOTE: We must keep the Data alive across the C call; do nested closures.
        if let charsData, let ignData {
            charsData.withUnsafeBytes { cRaw in
                ignData.withUnsafeBytes { iRaw in
                    let cBase = cRaw.bindMemory(to: UInt8.self).baseAddress
                    let iBase = iRaw.bindMemory(to: UInt8.self).baseAddress
                    zonvie_core_send_key_event(
                        core,
                        keyCode,
                        mods,
                        cBase,
                        Int32(charsData.count),
                        iBase,
                        Int32(ignData.count)
                    )
                }
            }
            return
        }

        if let charsData {
            charsData.withUnsafeBytes { cRaw in
                let cBase = cRaw.bindMemory(to: UInt8.self).baseAddress
                zonvie_core_send_key_event(
                    core,
                    keyCode,
                    mods,
                    cBase,
                    Int32(charsData.count),
                    ignBytes,
                    Int32(ignData?.count ?? 0)
                )
            }
            return
        }

        if let ignData {
            ignData.withUnsafeBytes { iRaw in
                let iBase = iRaw.bindMemory(to: UInt8.self).baseAddress
                zonvie_core_send_key_event(
                    core,
                    keyCode,
                    mods,
                    charsBytes,
                    Int32(charsData?.count ?? 0),
                    iBase,
                    Int32(ignData.count)
                )
            }
            return
        }

        zonvie_core_send_key_event(core, keyCode, mods, nil, 0, nil, 0)
    }

    func resize(rows: UInt32, cols: UInt32) {
        guard let core else { return }
        zonvie_core_resize(core, rows, cols)
    }

    /// Request resize of a specific grid (for external windows).
    func tryResizeGrid(gridId: Int64, rows: UInt32, cols: UInt32) {
        guard let core else { return }
        zonvie_core_try_resize_grid(core, gridId, rows, cols)
    }

    func updateLayoutPx(drawableW: UInt32, drawableH: UInt32, cellW: UInt32, cellH: UInt32) {
        guard let core else { return }
        zonvie_core_update_layout_px(core, drawableW, drawableH, cellW, cellH)
    }

    /// Set screen width in cells (for cmdline max width).
    func setScreenCols(_ cols: UInt32) {
        guard let core else { return }
        zonvie_core_set_screen_cols(core, cols)
    }

    func setLogEnabledViaCore(_ enabled: Bool) {
        guard let core else { return }
        zonvie_core_set_log_enabled(core, enabled ? 1 : 0)
        ZonvieCore.appLogEnabled = enabled
    }

    // MARK: - Smooth Scrolling Support

    /// Grid info for hit-testing (Swift-friendly wrapper)
    struct GridInfo {
        var gridId: Int64
        var zindex: Int64
        var startRow: Int32
        var startCol: Int32
        var rows: Int32
        var cols: Int32
        // Viewport margins (rows/cols NOT part of scrollable area)
        var marginTop: Int32
        var marginBottom: Int32
        var marginLeft: Int32
        var marginRight: Int32
    }

    /// Get visible grids for hit-testing (highest zindex wins)
    func getVisibleGrids() -> [GridInfo] {
        guard let core else { return [] }

        // Allocate buffer for grid info (16 grids should be more than enough)
        var grids = [zonvie_grid_info](repeating: zonvie_grid_info(), count: 16)
        let count = grids.withUnsafeMutableBufferPointer { buffer in
            zonvie_core_get_visible_grids(core, buffer.baseAddress, buffer.count)
        }

        return (0..<count).map { i in
            let g = grids[i]
            return GridInfo(
                gridId: g.grid_id,
                zindex: g.zindex,
                startRow: g.start_row,
                startCol: g.start_col,
                rows: g.rows,
                cols: g.cols,
                marginTop: g.margin_top,
                marginBottom: g.margin_bottom,
                marginLeft: g.margin_left,
                marginRight: g.margin_right
            )
        }
    }

    /// Cached visible grids for non-blocking UI queries (main thread only).
    /// Pre-reserved to 16 elements to avoid reallocation in steady state.
    private var cachedVisibleGrids: [GridInfo] = {
        var arr = [GridInfo]()
        arr.reserveCapacity(16)
        return arr
    }()

    /// Non-blocking version of getVisibleGrids with cache fallback.
    /// Attempts tryLock on grid_mu; on success updates cache in-place.
    /// On failure returns previously cached data to avoid blocking the UI thread.
    /// Allocation-free in steady state (after initial cache population).
    func getVisibleGridsCached() -> [GridInfo] {
        guard let core else { return cachedVisibleGrids }

        // Stack-allocated C buffer via withUnsafeTemporaryAllocation (no heap)
        withUnsafeTemporaryAllocation(of: zonvie_grid_info.self, capacity: 16) { buffer in
            let result = zonvie_core_try_get_visible_grids(core, buffer.baseAddress!, 16)
            guard result >= 0 else { return }

            let count = Int(result)
            // Update cached array in-place (no heap alloc when capacity is sufficient)
            while cachedVisibleGrids.count > count { cachedVisibleGrids.removeLast() }
            for i in 0..<count {
                let g = buffer[i]
                let info = GridInfo(
                    gridId: g.grid_id,
                    zindex: g.zindex,
                    startRow: g.start_row,
                    startCol: g.start_col,
                    rows: g.rows,
                    cols: g.cols,
                    marginTop: g.margin_top,
                    marginBottom: g.margin_bottom,
                    marginLeft: g.margin_left,
                    marginRight: g.margin_right
                )
                if i < cachedVisibleGrids.count {
                    cachedVisibleGrids[i] = info
                } else {
                    cachedVisibleGrids.append(info)
                }
            }
        }

        return cachedVisibleGrids
    }

    /// Viewport info for scrollbar rendering (Swift-friendly wrapper)
    struct ViewportInfo {
        var gridId: Int64
        var topline: Int64     // First visible line (0-based)
        var botline: Int64     // First line below window (exclusive)
        var lineCount: Int64   // Total lines in buffer
        var curline: Int64     // Current cursor line
        var curcol: Int64      // Current cursor column
        var scrollDelta: Int64 // Lines scrolled since last update

        /// Calculate scrollbar thumb position (0.0 to 1.0)
        var scrollPosition: Double {
            guard lineCount > 0 else { return 0 }
            let visibleLines = botline - topline
            let scrollRange = max(1, lineCount - visibleLines)
            return Double(topline) / Double(scrollRange)
        }

        /// Calculate scrollbar thumb proportion (0.0 to 1.0)
        var knobProportion: Double {
            guard lineCount > 0 else { return 1.0 }
            return min(1.0, Double(botline - topline) / Double(lineCount))
        }
    }

    /// Get viewport info for a specific grid (for scrollbar)
    func getViewport(gridId: Int64) -> ViewportInfo? {
        guard let core else {
            ZonvieCore.appLog("[getViewport] core is nil")
            return nil
        }

        var vp = zonvie_viewport_info()
        let found = zonvie_core_get_viewport(core, gridId, &vp)
        if found == 0 {
            // Only log occasionally to avoid spam
            return nil
        }

        ZonvieCore.appLog("[getViewport] grid=\(gridId) found=\(found) topline=\(vp.topline) lineCount=\(vp.line_count)")
        return ViewportInfo(
            gridId: vp.grid_id,
            topline: vp.topline,
            botline: vp.botline,
            lineCount: vp.line_count,
            curline: vp.curline,
            curcol: vp.curcol,
            scrollDelta: vp.scroll_delta
        )
    }

    /// Timer for processing pending message scroll
    private var msgScrollTimer: Timer?

    // MARK: - Cursor Blink

    /// Timer for cursor blinking
    private var cursorBlinkTimer: Timer?
    /// Current cursor blink state (true = visible, false = hidden)
    private(set) var cursorBlinkState: Bool = true
    /// Blink phase: 0 = waiting (blinkwait), 1 = cycling (blinkon/blinkoff)
    private var cursorBlinkPhase: Int = 0
    /// Last known blink parameters (for change detection)
    private var lastBlinkWaitMs: UInt32 = 0
    private var lastBlinkOnMs: UInt32 = 0
    private var lastBlinkOffMs: UInt32 = 0

    /// Get current cursor blink parameters from core
    func getCursorBlink() -> (waitMs: UInt32, onMs: UInt32, offMs: UInt32) {
        guard let core else { return (0, 0, 0) }
        var waitMs: UInt32 = 0
        var onMs: UInt32 = 0
        var offMs: UInt32 = 0
        zonvie_core_get_cursor_blink(core, &waitMs, &onMs, &offMs)
        return (waitMs, onMs, offMs)
    }

    /// Check if cursor blink settings changed and update timer if needed
    func updateCursorBlinking() {
        let (waitMs, onMs, offMs) = getCursorBlink()

        ZonvieCore.appLog("[blink] updateCursorBlinking: wait=\(waitMs) on=\(onMs) off=\(offMs) last=(\(lastBlinkWaitMs),\(lastBlinkOnMs),\(lastBlinkOffMs))")

        // Check if blink parameters changed
        if waitMs == lastBlinkWaitMs && onMs == lastBlinkOnMs && offMs == lastBlinkOffMs {
            return // No change
        }

        ZonvieCore.appLog("[blink] blink params changed, starting blink timer")

        // Update cached values
        lastBlinkWaitMs = waitMs
        lastBlinkOnMs = onMs
        lastBlinkOffMs = offMs

        // Restart blinking with new parameters
        startCursorBlinking(waitMs: waitMs, onMs: onMs, offMs: offMs)
    }

    /// Start cursor blinking with given parameters
    func startCursorBlinking(waitMs: UInt32, onMs: UInt32, offMs: UInt32) {
        ZonvieCore.appLog("[blink] startCursorBlinking: wait=\(waitMs) on=\(onMs) off=\(offMs)")

        // Stop any existing timer
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil

        // Reset state
        cursorBlinkState = true
        cursorBlinkPhase = 0

        // If all blink values are 0, no blinking - cursor always visible
        if waitMs == 0 && onMs == 0 && offMs == 0 {
            ZonvieCore.appLog("[blink] all blink values are 0, no blinking")
            return
        }

        // If blinkon or blinkoff is 0, no blinking
        if onMs == 0 || offMs == 0 {
            ZonvieCore.appLog("[blink] blinkon or blinkoff is 0, no blinking")
            return
        }

        // Start with blinkwait phase
        let waitInterval = TimeInterval(waitMs) / 1000.0
        ZonvieCore.appLog("[blink] scheduling blinkwait timer: \(waitInterval)s")
        if waitInterval > 0 {
            cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: waitInterval, repeats: false) { [weak self] _ in
                self?.enterBlinkCycle()
            }
        } else {
            // No wait, start cycling immediately
            enterBlinkCycle()
        }
    }

    /// Enter the on/off blink cycle
    private func enterBlinkCycle() {
        ZonvieCore.appLog("[blink] enterBlinkCycle")
        cursorBlinkPhase = 1
        cursorBlinkState = true

        // Update blink state for all external grid views
        for (_, gridView) in externalGridViews {
            gridView.cursorBlinkState = true
            gridView.setNeedsDisplay(gridView.bounds)
        }

        requestRedraw()
        scheduleNextBlink(isCurrentlyOn: true)
    }

    /// Schedule the next blink state change
    private func scheduleNextBlink(isCurrentlyOn: Bool) {
        let interval: TimeInterval
        if isCurrentlyOn {
            // Currently on, will turn off after blinkon time
            interval = TimeInterval(lastBlinkOnMs) / 1000.0
        } else {
            // Currently off, will turn on after blinkoff time
            interval = TimeInterval(lastBlinkOffMs) / 1000.0
        }

        if interval <= 0 {
            ZonvieCore.appLog("[blink] interval <= 0, not scheduling")
            return
        }

        ZonvieCore.appLog("[blink] scheduleNextBlink: isOn=\(isCurrentlyOn) interval=\(interval)s")
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.cursorBlinkState.toggle()
            ZonvieCore.appLog("[blink] blink toggled to \(self.cursorBlinkState), calling requestRedraw")

            // Update blink state for all external grid views
            for (_, gridView) in self.externalGridViews {
                gridView.cursorBlinkState = self.cursorBlinkState
                gridView.setNeedsDisplay(gridView.bounds)
            }

            self.requestRedraw()
            ZonvieCore.appLog("[blink] requestRedraw called")
            self.scheduleNextBlink(isCurrentlyOn: self.cursorBlinkState)
        }
    }

    /// Stop cursor blinking (cursor becomes always visible)
    func stopCursorBlinking() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        cursorBlinkState = true
        cursorBlinkPhase = 0

        // Update blink state for all external grid views (cursor visible)
        for (_, gridView) in externalGridViews {
            gridView.cursorBlinkState = true
            gridView.setNeedsDisplay(gridView.bounds)
        }
    }

    /// Reset cursor blink timer (called on user input to restart blink cycle)
    func resetCursorBlink() {
        // Restart blinking from the wait phase
        startCursorBlinking(waitMs: lastBlinkWaitMs, onMs: lastBlinkOnMs, offMs: lastBlinkOffMs)
    }

    /// Request a redraw (to be set by the view)
    var requestRedraw: () -> Void = {}

    /// Send mouse scroll event to Neovim
    func sendMouseScroll(gridId: Int64, row: Int32, col: Int32, direction: String) {
        guard let core else { return }
        direction.withCString { dirCStr in
            zonvie_core_send_mouse_scroll(core, gridId, row, col, dirCStr)
        }

        // For message grid, set timer to process pending scroll after scroll stops
        if gridId == ZonvieCore.messageGridId {
            msgScrollTimer?.invalidate()
            msgScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                self?.processPendingMsgScroll()
            }
        }
    }

    /// Process pending message scroll update
    func processPendingMsgScroll() {
        guard let core else { return }
        zonvie_core_process_pending_msg_scroll(core)
    }

    /// Scroll to specific line (1-based) - used for scrollbar knob drag
    /// If useBottom is true, positions line at screen bottom (zb), otherwise at top (zt).
    func scrollToLine(_ line: Int64, useBottom: Bool = false) {
        guard let core else { return }
        zonvie_core_scroll_to_line(core, line, useBottom)
    }

    /// Scroll a window by one page (Neovim's <C-f>/<C-b>).
    /// gridId: target grid (-1 for cursor grid / current window).
    func pageScroll(gridId: Int64, forward: Bool) {
        guard let core else { return }
        zonvie_core_page_scroll(core, gridId, forward)
    }

    /// Send mouse input event to Neovim (click, drag, release)
    func sendMouseInput(button: String, action: String, modifier: String, gridId: Int64, row: Int32, col: Int32) {
        guard let core else { return }
        button.withCString { btnCStr in
            action.withCString { actCStr in
                modifier.withCString { modCStr in
                    zonvie_core_send_mouse_input(core, btnCStr, actCStr, modCStr, gridId, row, col)
                }
            }
        }
    }

    /// Cursor position info
    struct CursorPosition {
        var gridId: Int64
        var row: Int32
        var col: Int32
    }

    /// Get current cursor position
    func getCursorPosition() -> CursorPosition {
        guard let core else { return CursorPosition(gridId: -1, row: -1, col: -1) }
        var row: Int32 = 0
        var col: Int32 = 0
        let gridId = zonvie_core_get_cursor_position(core, &row, &col)
        return CursorPosition(gridId: gridId, row: row, col: col)
    }

    /// Get current mode name (e.g., "normal", "insert", "terminal")
    func getCurrentMode() -> String {
        guard let core else { return "" }
        guard let cstr = zonvie_core_get_current_mode(core) else { return "" }
        return String(cString: cstr)
    }

    /// Check if cursor is visible (false during busy, true otherwise)
    func isCursorVisible() -> Bool {
        guard let core else { return true }
        return zonvie_core_is_cursor_visible(core)
    }

    private func onVertices(
        mainVerts: UnsafePointer<zonvie_vertex>?,
        mainCount: Int,
        cursorVerts: UnsafePointer<zonvie_vertex>?,
        cursorCount: Int
    ) {
        guard let view = terminalView else { return }
    
        // Safety: ensure Swift Vertex layout matches zonvie_vertex layout.
        // (If this fails, you must do a per-vertex conversion instead.)
        assert(MemoryLayout<Vertex>.stride == MemoryLayout<zonvie_vertex>.stride)
    
        view.submitVerticesRaw(
            mainPtr: mainVerts,
            mainCount: mainCount,
            cursorPtr: cursorVerts,
            cursorCount: cursorCount
        )
    }

    private func onLog(bytes: UnsafePointer<UInt8>, len: Int) {
        // Skip Data allocation if logging is disabled
        guard ZonvieCore.appLogEnabled else { return }
        let data = Data(bytes: bytes, count: max(0, len))
        if let s = String(data: data, encoding: .utf8) {
            ZonvieCore.appLog(s)
        }
    }

    private func onGuiFont(bytes: UnsafePointer<UInt8>, len: Int) {
        guard let view = terminalView else { return }

        let data = Data(bytes: bytes, count: max(0, len))
        guard let s = String(data: data, encoding: .utf8) else { return }

        // Font priority: guifont > config.font.family > OS default (Menlo)
        let configFont = ZonvieConfig.shared.font.family.isEmpty ? "Menlo" : ZonvieConfig.shared.font.family
        let configSize = ZonvieConfig.shared.font.size > 0 ? ZonvieConfig.shared.font.size : 14.0

        // Expect: "<name>\t<size>"
        let parts = s.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            var name = String(parts[0])
            let parsedSize = Double(parts[1]) ?? 0
            // If size is 0 or invalid, use config size
            let size = parsedSize > 0 ? parsedSize : configSize

            // If guifont name is empty, use config font
            if name.isEmpty {
                name = configFont
                Self.appLog("[onGuiFont] guifont empty, using config font '\(configFont)' size=\(size)")
            }

            // Apply font SYNCHRONOUSLY so that rasterizeOnly (called during
            // the same flush's vertex generation) uses the new font immediately.
            // atlas.setFont() is thread-safe (protected by os_unfair_lock).
            view.renderer.glyphAtlas.setFont(name: name, pointSize: CGFloat(size))

            // Notify core of new cell dimensions so vertex positions match
            // the new glyph metrics. updateLayoutPx detects in_handle_redraw
            // and takes the lock-free path (grid_mu already held by flush).
            let cw = max(1, Int(view.renderer.cellWidthPx.rounded(.toNearestOrAwayFromZero)))
            let ch = max(1, Int(view.renderer.cellHeightPx.rounded(.toNearestOrAwayFromZero)))
            let ds = view.currentDrawableSize
            let dw = max(1, Int(ds.width))
            let dh = max(1, Int(ds.height))
            updateLayoutPx(drawableW: UInt32(dw), drawableH: UInt32(dh),
                           cellW: UInt32(cw), cellH: UInt32(ch))

            // GUI-only updates (redraw, external window notify) can be async.
            DispatchQueue.main.async { [weak self] in
                view.requestRedraw()
                self?.externalGridViews.values.forEach {
                    $0.notifyFontChanged()
                    $0.requestRedraw()
                }
            }
            return
        }
    }

    private func onLineSpace(px: Int32) {
        guard let view = terminalView else { return }

        // Apply linespace synchronously so cell height is correct for
        // vertex generation in the current flush.
        view.renderer.setLineSpace(px: px)

        // Notify core of new cell dimensions (cell height includes linespace).
        let cw = max(1, Int(view.renderer.cellWidthPx.rounded(.toNearestOrAwayFromZero)))
        let ch = max(1, Int(view.renderer.cellHeightPx.rounded(.toNearestOrAwayFromZero)))
        let ds = view.currentDrawableSize
        let dw = max(1, Int(ds.width))
        let dh = max(1, Int(ds.height))
        updateLayoutPx(drawableW: UInt32(dw), drawableH: UInt32(dh),
                       cellW: UInt32(cw), cellH: UInt32(ch))

        DispatchQueue.main.async {
            view.requestRedraw(nil)
        }
    }

    private func onSetTitle(title: UnsafePointer<UInt8>, titleLen: Int) {
        let data = Data(bytes: title, count: max(0, titleLen))
        guard let titleStr = String(data: data, encoding: .utf8) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let window = self?.terminalView?.window else { return }
            window.title = titleStr
        }
    }



    // Exit code from Neovim (for propagation to main.swift)
    private static var exitCode: Int32 = 0

    /// Get the exit code set by Neovim (0 = normal, 1+ = error)
    static func getExitCode() -> Int32 {
        return exitCode
    }

    private func onExitFromNvim(exitCode: Int32) {
        ZonvieCore.exitCode = exitCode
        Self.appLog("[ZonvieCore] onExitFromNvim: code=\(exitCode), exiting now")
        // Exit immediately - no async dispatch to avoid race conditions
        Darwin.exit(exitCode)
    }

    // MARK: - External Window Support

    /// Tracks external windows (grid_id -> NSWindow)
    private var externalWindows: [Int64: NSWindow] = [:]
    /// Tracks grid_id -> Neovim window handle for external windows
    private var externalWindowWinIds: [Int64: Int64] = [:]

    /// Pending position for the next regular external window (set by tab externalization)
    /// When set, the next regular external window will be placed at this position, then this is cleared.
    private var pendingExternalWindowPosition: NSPoint? = nil
    /// Saved positions for external windows (grid_id -> origin).
    /// When a window is hidden (e.g. tab switch), its position is saved here.
    /// On recreation, the saved position is used instead of Neovim's coordinates.
    private var savedExternalWindowPositions: [Int64: NSPoint] = [:]
    /// Tracks external grid views (grid_id -> ExternalGridView)
    private var externalGridViews: [Int64: ExternalGridView] = [:]
    /// Tracks external window delegates (grid_id -> ExternalWindowDelegate)
    private var externalWindowDelegates: [Int64: ExternalWindowDelegate] = [:]
    /// Pending background color configuration (applied when window is created)
    private var pendingExternalGridConfig: [Int64: (bgColor: NSColor, rows: UInt32, cols: UInt32)] = [:]
    /// Pending vertices for external grids (applied when gridView is created)
    /// Stores vertices per-row to handle row-based vertex submission
    /// NOTE: All access to externalGridViews, pendingExternalVertices, and
    /// externalWindows is confined to the main thread. The on_vertices_row callback
    /// copies vertex data on the RPC thread and dispatches to main for submission.
    private var pendingExternalVertices: [Int64: (rowVertices: [Int: [zonvie_vertex]], rows: UInt32, cols: UInt32)] = [:]

    /// Pending external window requests (queued when terminalView or pipeline is not ready yet)
    private struct PendingExternalWindowRequest {
        let gridId: Int64
        let win: Int64
        let rows: UInt32
        let cols: UInt32
        let startRow: Int32
        let startCol: Int32
    }
    private var pendingExternalWindowRequests: [PendingExternalWindowRequest] = []

    /// Current cmdline firstc character (':', '/', '?', etc.)
    private var cmdlineFirstc: UInt8 = 0
    /// Cmdline icon view (for search/command icons)
    private var cmdlineIconView: NSImageView?

    /// Delegate for external window resize handling
    private class ExternalWindowDelegate: NSObject, NSWindowDelegate {
        weak var core: ZonvieCore?
        let gridId: Int64
        var cellWidthPx: CGFloat
        var cellHeightPx: CGFloat
        /// When true, suppress tryResizeGrid in windowDidResize (programmatic resize from grid_resize).
        var suppressResizeCallback = false
        /// Last grid rows/cols set by applyExternalGridConfig (for exact change detection).
        var lastGridRows: UInt32 = 0
        var lastGridCols: UInt32 = 0

        init(core: ZonvieCore, gridId: Int64, cellWidthPx: CGFloat, cellHeightPx: CGFloat) {
            self.core = core
            self.gridId = gridId
            self.cellWidthPx = cellWidthPx
            self.cellHeightPx = cellHeightPx
            super.init()
        }

        func windowDidResize(_ notification: Notification) {
            // Skip resize callback when window is being resized programmatically
            // (from Neovim grid_resize). Only report back on user-initiated resizes.
            if suppressResizeCallback { return }

            guard let window = notification.object as? NSWindow,
                  let core = core else { return }

            let scale = window.backingScaleFactor
            let contentSize = window.contentView?.frame.size ?? window.frame.size

            // Calculate rows/cols from window size
            let widthPx = contentSize.width * scale
            let heightPx = contentSize.height * scale

            let cols = UInt32(widthPx / cellWidthPx)
            let rows = UInt32(heightPx / cellHeightPx)

            ZonvieCore.appLog("[external_window] windowDidResize gridId=\(gridId) contentSize=\(contentSize) scale=\(scale) cellH=\(cellHeightPx) cellW=\(cellWidthPx) heightPx=\(heightPx) widthPx=\(widthPx) rows=\(rows) cols=\(cols) lastGridRows=\(lastGridRows) lastGridCols=\(lastGridCols) suppress=\(suppressResizeCallback)")

            // Skip if rows/cols match the last programmatic resize (from grid_resize).
            // windowDidResize can fire asynchronously after suppressResizeCallback
            // is cleared, so this check prevents overriding Neovim's grid dimensions.
            if rows == lastGridRows && cols == lastGridCols { return }

            // Only resize if we have valid dimensions
            if rows > 0 && cols > 0 {
                ZonvieCore.appLog("[external_window] resize gridId=\(gridId) rows=\(rows) cols=\(cols)")
                core.tryResizeGrid(gridId: gridId, rows: rows, cols: cols)
            }
        }

        func windowWillClose(_ notification: Notification) {
            // Let nvim know the window is closing
            ZonvieCore.appLog("[external_window] delegate: windowWillClose gridId=\(gridId)")
        }
    }

    /// Resize external windows when cell metrics change (e.g., guifont change).
    /// This updates window sizes to match new cell dimensions while keeping row/col counts.
    func resizeExternalWindows(cellWidthPx: CGFloat, cellHeightPx: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let mainView = self.terminalView else { return }
            let scale = mainView.window?.backingScaleFactor ?? 1.0

            ZonvieCore.appLog("[resizeExternalWindows] cellW=\(cellWidthPx) cellH=\(cellHeightPx) scale=\(scale)")

            // Iterate through all external windows
            for (gridId, window) in self.externalWindows {
                // Skip special windows (cmdline, popupmenu, msg_show, msg_history)
                // These are handled differently and don't need resize
                if gridId == ZonvieCore.cmdlineGridId ||
                   gridId == ZonvieCore.popupmenuGridId ||
                   gridId == ZonvieCore.messageGridId ||
                   gridId == ZonvieCore.msgHistoryGridId {
                    continue
                }

                // Get the ExternalGridView to get current row/col counts
                guard let gridView = self.externalGridViews[gridId] else { continue }
                let rows = gridView.gridRows
                let cols = gridView.gridCols

                guard rows > 0 && cols > 0 else { continue }

                // Calculate new window size in points
                let newWidth = CGFloat(cols) * cellWidthPx / scale
                let newHeight = CGFloat(rows) * cellHeightPx / scale

                // Preserve window origin, update size
                let currentFrame = window.frame
                let newFrame = NSRect(
                    x: currentFrame.origin.x,
                    y: currentFrame.origin.y + currentFrame.height - newHeight,  // Keep top-left position
                    width: newWidth,
                    height: newHeight
                )
                window.setFrame(newFrame, display: false)

                // Update gridView frame
                gridView.frame = NSRect(x: 0, y: 0, width: newWidth, height: newHeight)

                // Update delegate's cell dimensions
                if let delegate = self.externalWindowDelegates[gridId] {
                    delegate.cellWidthPx = cellWidthPx
                    delegate.cellHeightPx = cellHeightPx
                }

                // Force Neovim to redraw this grid by changing size then restoring
                // Neovim ignores resize requests with same size, so we change it first
                self.tryResizeGrid(gridId: gridId, rows: rows + 1, cols: cols)
                self.tryResizeGrid(gridId: gridId, rows: rows, cols: cols)

                ZonvieCore.appLog("[resizeExternalWindows] gridId=\(gridId) rows=\(rows) cols=\(cols) newSize=\(newWidth)x\(newHeight)")
            }
        }
    }

    /// Custom NSWindow subclass for cmdline window.
    /// - Allows borderless window to become key window for IME input
    /// - Tracks position for persistence across cmdline show/hide cycles
    /// - Disables resize and prevents becoming main window to avoid focus stealing
    private class CmdlineWindow: NSWindow, NSWindowDelegate {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }  // Don't steal main from main window

        /// Saved position for next cmdline show (nil = use default center)
        static var savedOrigin: CGPoint?

        /// Called when window is moved - save position
        func windowDidMove(_ notification: Notification) {
            CmdlineWindow.savedOrigin = frame.origin
            ZonvieCore.appLog("[CmdlineWindow] saved position: \(frame.origin)")
        }
    }

    /// Called when a grid should be displayed in an external window.
    /// Reserved grid ID for cmdline (must match CMDLINE_GRID_ID in grid.zig)
    private static let cmdlineGridId: Int64 = -100
    /// Reserved grid ID for popupmenu (must match POPUPMENU_GRID_ID in grid.zig)
    private static let popupmenuGridId: Int64 = -101
    /// Reserved grid ID for messages (must match MESSAGE_GRID_ID in grid.zig)
    private static let messageGridId: Int64 = -102
    /// Reserved grid ID for message history (must match MSG_HISTORY_GRID_ID in grid.zig)
    private static let msgHistoryGridId: Int64 = -103

    /// Message window for ext_messages (top-right for echo/error/warning)
    private var extFloatWindow: NSWindow?
    /// Message text field for ext_messages
    private var messageTextField: NSTextField?
    /// Message container view for ext_messages
    private var messageContainerView: NSView?
    /// Work item for message auto-hide timer
    private var messageAutoHideWorkItem: DispatchWorkItem?
    /// Message auto-hide timeout in seconds
    private static let messageAutoHideTimeout: Double = 4.0
    /// Pending messages for stack display (echo/error/warning only)
    private var pendingMessages: [(kind: String, content: String, hlId: Int32)] = []

    /// Prompt window for confirm/return_prompt (bottom-center)
    private var promptWindow: NSWindow?
    /// Prompt text field
    private var promptTextField: NSTextField?
    /// Prompt container view
    private var promptContainerView: NSView?
    /// Saved prompt window size for return_prompt (preserve confirm dialog layout)
    private var savedPromptWidth: CGFloat = 0
    private var savedPromptHeight: CGFloat = 0
    /// Track if current prompt is from confirm dialog
    private var promptIsConfirm: Bool = false

    // MARK: - Mini View System (showmode/showcmd/ruler)

    /// Identifies a mini window type for routing
    enum MiniWindowId: String, Hashable, CaseIterable {
        case showmode
        case showcmd
        case ruler
        case custom  // For msg_show routed to mini view
    }

    /// State for a single mini window
    struct MiniWindowState {
        var window: NSWindow?
        var label: NSTextField?
        var content: String = ""
        var isVisible: Bool { !content.isEmpty }
        var hideWorkItem: DispatchWorkItem? = nil
    }

    /// Dictionary of mini windows by type
    private var miniWindows: [MiniWindowId: MiniWindowState] = [:]

    /// Tracks which grid the popupmenu is anchored to (set during popupmenu_show, cleared on hide)
    /// Used to prevent main window activation when popupmenu is on an external window
    private var popupmenuAnchorGrid: Int64? = nil

    /// Pending main window activation work item (can be cancelled by popupmenu_show)
    private var mainWindowActivationWorkItem: DispatchWorkItem? = nil

    /// Flag to cancel main window activation (checked inside workItem)
    private var cancelMainWindowActivation: Bool = false

    /// Track last cursor grid to detect transitions from external windows
    private var lastCursorGrid: Int64 = 1

    /// Timestamp when cursor left an external window (used to suppress main window activation briefly)
    private var lastExternalWindowExitTime: Date? = nil

    private func onExternalWindow(gridId: Int64, win: Int64, rows: UInt32, cols: UInt32, startRow: Int32, startCol: Int32) {
        ZonvieCore.appLog("[external_window] open gridId=\(gridId) win=\(win) rows=\(rows) cols=\(cols) pos=(\(startRow),\(startCol)) blurEnabled=\(ZonvieConfig.shared.blurEnabled)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.externalWindowWinIds[gridId] = win

            // Get cell dimensions and shared resources from the main terminal view
            guard let mainView = self.terminalView else {
                ZonvieCore.appLog("[external_window] no terminalView, queuing request for gridId=\(gridId)")
                self.pendingExternalWindowRequests.append(PendingExternalWindowRequest(
                    gridId: gridId, win: win, rows: rows, cols: cols, startRow: startRow, startCol: startCol
                ))
                return
            }

            let renderer = mainView.renderer!
            let cellW = CGFloat(renderer.cellWidthPx)
            let cellH = CGFloat(renderer.cellHeightPx)
            let scale = mainView.window?.backingScaleFactor ?? 1.0

            var contentWidth = CGFloat(cols) * cellW / scale
            let contentHeight = CGFloat(rows) * cellH / scale

            // Determine if this is a special window (cmdline, popupmenu, msg_show, msg_history)
            let isCmdline = (gridId == ZonvieCore.cmdlineGridId)
            let isPopupmenu = (gridId == ZonvieCore.popupmenuGridId)
            let isMsgShow = (gridId == ZonvieCore.messageGridId)
            let isMsgHistory = (gridId == ZonvieCore.msgHistoryGridId)

            // Check if window already exists - reuse for popupmenu
            if let existingWindow = self.externalWindows[gridId],
               let existingGridView = self.externalGridViews[gridId] {
                if isPopupmenu {
                    // Reuse popupmenu window - just update size and position
                    let windowWidth = contentWidth
                    let windowHeight = contentHeight

                    // Calculate new position
                    var windowRect = existingWindow.frame
                    let isCmdlineCompletion = (startRow == -1)

                    if isCmdlineCompletion {
                        // Position above cmdline window
                        if let cmdlineWindow = self.externalWindows[ZonvieCore.cmdlineGridId] {
                            let cmdlineFrame = cmdlineWindow.frame
                            let x = cmdlineFrame.origin.x + CGFloat(startCol) * cellW / scale
                            let y = cmdlineFrame.origin.y + cmdlineFrame.height + 4.0
                            windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                        }
                    } else if let mainWindow = mainView.window {
                        // Buffer completion: position relative to main window
                        let mainFrame = mainWindow.frame
                        let mainContentFrame = mainWindow.contentLayoutRect
                        let titleBarHeight = mainFrame.height - mainContentFrame.height
                        let mainContentY = mainFrame.origin.y
                        let mainContentTop = mainFrame.origin.y + mainFrame.height - titleBarHeight
                        let pxY = CGFloat(startRow) * cellH / scale

                        let x = mainFrame.origin.x + CGFloat(startCol) * cellW / scale
                        var y = mainContentTop - pxY - windowHeight

                        // If popupmenu would go below main window, position above cursor
                        // Add 2 cell heights: 1 for the cursor row itself, 1 for the cmdline row
                        if y < mainContentY {
                            let cursorRowTopY = mainContentTop - pxY + (cellH / scale * 2)
                            y = cursorRowTopY
                        }

                        windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                    }

                    existingWindow.setFrame(windowRect, display: false)
                    existingGridView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
                    existingWindow.orderFront(nil)
                    return
                } else if isCmdline {
                    // Cmdline window exists - update position if promptWindow (confirm dialog) is visible
                    let promptWinVisible = self.promptWindow?.isVisible == true

                    if promptWinVisible, let promptWin = self.promptWindow, let screen = NSScreen.main, let mainWindow = mainView.window {
                        // Position cmdline below promptWindow (confirm dialog)
                        // X: center of app window, Y: below promptWindow
                        let promptFrame = promptWin.frame
                        let screenFrame = screen.visibleFrame
                        let appFrame = mainWindow.frame
                        let containerWidth = existingWindow.frame.width
                        let containerHeight = existingWindow.frame.height
                        let x = appFrame.midX - containerWidth / 2  // Center on app window
                        // container top = y + containerHeight
                        // We want: container top = promptFrame.origin.y - 4
                        var y = promptFrame.origin.y - 4 - containerHeight
                        y = max(screenFrame.minY, y)

                        existingWindow.setFrame(NSRect(x: x, y: y, width: containerWidth, height: containerHeight), display: false)
                        ZonvieCore.appLog("[external_window] cmdline repositioned below prompt at (\(x), \(y))")
                    }
                    existingWindow.orderFront(nil)
                    return
                } else if isMsgHistory {
                    // Reuse msg_history window - update size and position (top-right)
                    let windowWidth = contentWidth
                    let windowHeight = contentHeight

                    let targetFrame = getExtFloatTargetFrame()
                    let x = targetFrame.maxX - windowWidth - 10
                    let y = targetFrame.maxY - windowHeight - 10
                    let windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                    existingWindow.setFrame(windowRect, display: false)
                    existingGridView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

                    // Reposition msg_show window below msg_history if it exists
                    if let msgShowWindow = self.externalWindows[ZonvieCore.messageGridId],
                       msgShowWindow.isVisible {
                        let msgShowFrame = msgShowWindow.frame
                        let msgShowX = targetFrame.maxX - msgShowFrame.width - 10
                        let msgShowY = y - msgShowFrame.height - 4  // 4px gap below history (y is history's origin.y)
                        msgShowWindow.setFrame(NSRect(x: msgShowX, y: msgShowY, width: msgShowFrame.width, height: msgShowFrame.height), display: false)
                        ZonvieCore.appLog("[external_window] repositioned msg_show below msg_history at (\(msgShowX),\(msgShowY))")
                    }
                    existingWindow.orderFront(nil)
                    return
                } else if isMsgShow {
                    // Reuse msg_show window - position below msg_history if visible, otherwise top-right
                    let windowWidth = contentWidth
                    let windowHeight = contentHeight

                    let targetFrame = getExtFloatTargetFrame()
                    let x = targetFrame.maxX - windowWidth - 10
                    var y = targetFrame.maxY - windowHeight - 10

                    // If msg_history window is visible, position below it
                    if let msgHistoryWindow = self.externalWindows[ZonvieCore.msgHistoryGridId],
                       msgHistoryWindow.isVisible {
                        let historyFrame = msgHistoryWindow.frame
                        y = historyFrame.origin.y - windowHeight - 4  // 4px gap below history
                        ZonvieCore.appLog("[external_window] msg_show positioned below msg_history at (\(x),\(y))")
                    }

                    let windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                    existingWindow.setFrame(windowRect, display: false)
                    existingGridView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
                    existingWindow.orderFront(nil)
                    return
                } else {
                    // For other windows, just return
                    return
                }
            }

            let isSpecialWindow = isCmdline || isPopupmenu || isMsgShow || isMsgHistory

            // Padding for cmdline window (from ZonvieConfig)
            let cmdlinePadding: CGFloat = isCmdline ? ZonvieConfig.cmdlinePadding : 0.0
            // Padding for msg_show/msg_history windows
            let msgPadding: CGFloat = (isMsgShow || isMsgHistory) ? 8.0 : 0.0
            // Shadow margin for cmdline window (allows shadow to extend beyond content)
            let shadowMargin: CGFloat = isCmdline ? 150.0 : 0.0
            // Icon area width for cmdline window
            let cmdlineIconTotalWidth: CGFloat = isCmdline ? ZonvieConfig.cmdlineIconTotalWidth : 0.0

            // Constrain cmdline width to screen width
            if isCmdline, let screen = NSScreen.main {
                let maxContentWidth = screen.visibleFrame.width - (cmdlinePadding * 2) - cmdlineIconTotalWidth - ZonvieConfig.cmdlineScreenMargin
                contentWidth = min(contentWidth, maxContentWidth)
            }

            let containerWidth = contentWidth + (cmdlinePadding * 2) + cmdlineIconTotalWidth + (msgPadding * 2)
            let containerHeight = contentHeight + (cmdlinePadding * 2) + (msgPadding * 2)
            let windowWidth = containerWidth + (shadowMargin * 2)
            let windowHeight = containerHeight + (shadowMargin * 2)

            // Create the external window with appropriate style
            let windowRect: NSRect
            let styleMask: NSWindow.StyleMask

            if isCmdline {
                // Cmdline window: borderless
                styleMask = [.borderless]

                // Check if promptWindow (confirm dialog) is visible
                let promptWinVisible = self.promptWindow?.isVisible == true

                if promptWinVisible, let promptWin = self.promptWindow, let screen = NSScreen.main, let mainWindow = mainView.window {
                    // Position cmdline below promptWindow (confirm dialog)
                    // X: center of app window, Y: below promptWindow
                    let promptFrame = promptWin.frame
                    let screenFrame = screen.visibleFrame
                    let appFrame = mainWindow.frame
                    let x = appFrame.midX - containerWidth / 2  // Center on app window
                    // containerView starts at (0,0) and has size (containerWidth, containerHeight)
                    // container top (in screen coords) = y + containerHeight
                    // We want: container top = promptWindow bottom - 4
                    var y = promptFrame.origin.y - 4 - containerHeight
                    y = max(screenFrame.minY, y)
                    windowRect = NSRect(x: x, y: y, width: containerWidth, height: containerHeight)
                    ZonvieCore.appLog("[cmdline_pos] promptWindow bottom=\(promptFrame.origin.y)")
                    ZonvieCore.appLog("[cmdline_pos] cmdline content top=\(y + containerHeight) (should be \(promptFrame.origin.y - 4))")
                    ZonvieCore.appLog("[external_window] cmdline positioned below prompt at (\(x), \(y))")
                } else if let savedOrigin = CmdlineWindow.savedOrigin, let screen = NSScreen.main {
                    // Use saved position, but ensure window stays on screen
                    let screenFrame = screen.visibleFrame
                    let x = max(screenFrame.minX, min(savedOrigin.x, screenFrame.maxX - containerWidth))
                    let y = max(screenFrame.minY, min(savedOrigin.y, screenFrame.maxY - containerHeight))
                    windowRect = NSRect(x: x, y: y, width: containerWidth, height: containerHeight)
                    ZonvieCore.appLog("[external_window] cmdline using saved position: (\(x), \(y))")
                } else if let screen = NSScreen.main {
                    // Default: center on screen
                    let screenFrame = screen.visibleFrame
                    let x = screenFrame.midX - containerWidth / 2
                    let y = screenFrame.midY - containerHeight / 2
                    windowRect = NSRect(x: x, y: y, width: containerWidth, height: containerHeight)
                } else {
                    windowRect = NSRect(x: 100, y: 100, width: containerWidth, height: containerHeight)
                }
            } else if isPopupmenu {
                // Popupmenu window: borderless, position near cursor
                styleMask = [.borderless]

                // Check if this is cmdline completion (startRow == -1)
                let isCmdlineCompletion = (startRow == -1)

                if isCmdlineCompletion {
                    // Cmdline completion: position above the cmdline window
                    if let cmdlineWindow = self.externalWindows[ZonvieCore.cmdlineGridId] {
                        let cmdlineFrame = cmdlineWindow.frame
                        // Position popupmenu so its bottom is at cmdline top (with small gap)
                        let x = cmdlineFrame.origin.x + CGFloat(startCol) * cellW / scale
                        let y = cmdlineFrame.origin.y + cmdlineFrame.height + 4.0  // 4px gap above cmdline
                        windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                        ZonvieCore.appLog("[external_window] popupmenu positioned above cmdline at (\(x),\(y))")
                    } else {
                        // Fallback: center on screen
                        if let screen = NSScreen.main {
                            let screenFrame = screen.visibleFrame
                            let x = screenFrame.midX - windowWidth / 2
                            let y = screenFrame.midY
                            windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                        } else {
                            windowRect = NSRect(x: 100, y: 100, width: windowWidth, height: windowHeight)
                        }
                    }
                } else if win > 0, let anchorWindow = self.externalWindows[win] {
                    // Completion on external window: position relative to that window
                    let anchorFrame = anchorWindow.frame

                    // Calculate position from cell coordinates (Y is flipped in AppKit)
                    let pxX = CGFloat(startCol) * cellW / scale
                    let pxY = CGFloat(startRow) * cellH / scale

                    // Position below the cursor position within the external window
                    let x = anchorFrame.origin.x + pxX
                    let y = anchorFrame.origin.y + anchorFrame.height - pxY - windowHeight

                    windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                    ZonvieCore.appLog("[external_window] popupmenu positioned at (\(x),\(y)) relative to ext_win=\(win)")
                } else if let mainWindow = mainView.window {
                    // Buffer completion: position relative to main window
                    let mainFrame = mainWindow.frame
                    let mainContentRect = mainWindow.contentRect(forFrameRect: mainFrame)

                    // Calculate position from cell coordinates (Y is flipped in AppKit)
                    let pxX = CGFloat(startCol) * cellW / scale
                    let pxY = CGFloat(startRow) * cellH / scale

                    // Position below the cursor position (AppKit Y is from bottom)
                    let x = mainContentRect.origin.x + pxX
                    var y = mainContentRect.origin.y + mainContentRect.height - pxY - windowHeight

                    // If popupmenu would go below main window (e.g., cmdline completion without ext_cmdline),
                    // position it above the cursor row instead
                    // Add 2 cell heights: 1 for the cursor row itself, 1 for the cmdline row
                    let cursorRowTopY = mainContentRect.origin.y + mainContentRect.height - pxY + (cellH / scale * 2)
                    if y < mainContentRect.origin.y {
                        // Position above the cursor row (and cmdline row)
                        y = cursorRowTopY
                        ZonvieCore.appLog("[external_window] popupmenu flipped to above cursor at y=\(y)")
                    }

                    windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                    ZonvieCore.appLog("[external_window] popupmenu positioned at (\(x),\(y)) from cursor pos (\(startRow),\(startCol))")
                } else {
                    windowRect = NSRect(x: 100, y: 100, width: windowWidth, height: windowHeight)
                }
            } else if isMsgHistory {
                // Message history window: borderless, top-right position based on config
                styleMask = [.borderless]
                let targetFrame = getExtFloatTargetFrame()
                let x = targetFrame.maxX - windowWidth - 10
                let y = targetFrame.maxY - windowHeight - 10
                windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                ZonvieCore.appLog("[external_window] msg_history positioned at (\(x),\(y))")
            } else if isMsgShow {
                // Message show window: borderless, position below msg_history if visible, otherwise top-right
                styleMask = [.borderless]
                let targetFrame = getExtFloatTargetFrame()
                let x = targetFrame.maxX - windowWidth - 10
                var y = targetFrame.maxY - windowHeight - 10

                // If msg_history window is visible, position below it
                if let msgHistoryWindow = self.externalWindows[ZonvieCore.msgHistoryGridId],
                   msgHistoryWindow.isVisible {
                    let historyFrame = msgHistoryWindow.frame
                    y = historyFrame.origin.y - windowHeight - 4  // 4px gap below history
                    ZonvieCore.appLog("[external_window] msg_show positioned below msg_history at (\(x),\(y))")
                } else {
                    ZonvieCore.appLog("[external_window] msg_show positioned at (\(x),\(y))")
                }

                windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
            } else if let savedOrigin = self.savedExternalWindowPositions[gridId] {
                // Restore saved position from previous tab switch
                styleMask = [.titled, .closable, .resizable]
                windowRect = NSRect(x: savedOrigin.x, y: savedOrigin.y, width: windowWidth, height: windowHeight)
                ZonvieCore.appLog("[external_window] restored saved position for gridId=\(gridId) at \(savedOrigin)")
            } else if let pendingPos = self.pendingExternalWindowPosition {
                // Tab externalization: use the pending position (mouse drop point)
                styleMask = [.titled, .closable, .resizable]
                // Position so the mouse is at the center of the title bar
                let titleBarHeight: CGFloat = 28  // Standard macOS title bar height
                let x = pendingPos.x - windowWidth / 2  // Center horizontally
                let y = pendingPos.y - windowHeight - titleBarHeight / 2  // Title bar center at mouse Y
                windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                ZonvieCore.appLog("[external_window] positioned at (\(x),\(y)) from pending position \(pendingPos) (title bar centered)")
                self.pendingExternalWindowPosition = nil  // Clear after use
            } else if startRow >= 0 && startCol >= 0 {
                // Position relative to main window using win_pos
                styleMask = [.titled, .closable, .resizable]
                if let mainWindow = mainView.window {
                    // Get main window content rect in screen coordinates
                    let mainFrame = mainWindow.frame
                    let mainContentRect = mainWindow.contentRect(forFrameRect: mainFrame)

                    // Calculate position from cell coordinates (Y is flipped in AppKit)
                    let pxX = CGFloat(startCol) * cellW / scale
                    let pxY = CGFloat(startRow) * cellH / scale

                    // Position at top-left of the cell position (AppKit Y is from bottom)
                    let x = mainContentRect.origin.x + pxX
                    let y = mainContentRect.origin.y + mainContentRect.height - pxY - windowHeight

                    windowRect = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
                    ZonvieCore.appLog("[external_window] positioned at (\(x),\(y)) from win_pos (\(startRow),\(startCol))")
                } else {
                    windowRect = NSRect(x: 100, y: 100, width: windowWidth, height: windowHeight)
                }
            } else {
                // Regular external window - default position
                styleMask = [.titled, .closable, .resizable]
                windowRect = NSRect(x: 100, y: 100, width: windowWidth, height: windowHeight)
            }

            // Use CmdlineWindow for cmdline to enable key events and IME input
            let window: NSWindow
            if isCmdline {
                let cmdlineWindow = CmdlineWindow(
                    contentRect: windowRect,
                    styleMask: styleMask,
                    backing: .buffered,
                    defer: false
                )
                // Set self as delegate to track window movement
                cmdlineWindow.delegate = cmdlineWindow
                window = cmdlineWindow
            } else {
                window = NSWindow(
                    contentRect: windowRect,
                    styleMask: styleMask,
                    backing: .buffered,
                    defer: false
                )
            }

            if isCmdline {
                // Cmdline-specific window settings
                window.hasShadow = true
                window.level = .floating  // Above other windows
                window.isOpaque = false
                window.backgroundColor = .clear  // Required for window transparency
                window.isMovableByWindowBackground = true  // Allow drag to move
                window.hidesOnDeactivate = true  // Hide when app loses focus
            } else if isPopupmenu {
                // Popupmenu-specific window settings (similar to cmdline)
                window.hasShadow = true
                window.level = .floating  // Above main window
                window.isOpaque = false
                window.backgroundColor = .clear  // Required for window transparency
                window.hidesOnDeactivate = true  // Hide when app loses focus
            } else if isMsgShow || isMsgHistory {
                // Message show/history window settings (similar to cmdline/popupmenu)
                window.hasShadow = true
                window.level = .floating  // Above main window
                window.isOpaque = false
                window.backgroundColor = .clear  // Required for window transparency
                window.hidesOnDeactivate = true  // Hide when app loses focus
            } else {
                window.title = "Window \(win)"
            }
            window.isReleasedWhenClosed = false

            // Create ExternalGridView with shared device, atlas, and pipelines
            // Using shared pipelines avoids shader compilation (10-50ms per window)
            // Ensure pipeline is built before accessing sharedPipeline
            // (pipeline is deferred to first draw to avoid XPC errors on multi-instance startup)
            renderer.ensurePipelineReady(view: mainView)

            guard let sharedPipeline = renderer.sharedPipeline,
                  let sharedSampler = renderer.sharedSampler else {
                ZonvieCore.appLog("[external_window] renderer pipelines not ready, queuing request for gridId=\(gridId)")
                self.pendingExternalWindowRequests.append(PendingExternalWindowRequest(
                    gridId: gridId, win: win, rows: rows, cols: cols, startRow: startRow, startCol: startCol
                ))
                // Retry after a short delay (pipeline may become ready after first draw)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.processPendingExternalWindows()
                }
                return
            }

            // DEBUG: Log blurEnabled value before creating ExternalGridView
            let blurEnabledForGrid = ZonvieConfig.shared.blurEnabled
            ZonvieCore.appLog("[DEBUG-EXTGRID-CREATE] gridId=\(gridId) isSpecialWindow=\(isSpecialWindow) blurEnabled=\(blurEnabledForGrid) backgroundAlpha=\(ZonvieConfig.shared.backgroundAlpha) window.blur=\(ZonvieConfig.shared.window.blur)")

            guard let gridView = ExternalGridView(
                gridId: gridId,
                device: renderer.metalDevice,
                atlas: renderer.glyphAtlas,
                sharedPipeline: sharedPipeline,
                sharedBackgroundPipeline: renderer.sharedBackgroundPipeline,
                sharedGlyphPipeline: renderer.sharedGlyphPipeline,
                sharedSampler: sharedSampler,
                blurEnabled: blurEnabledForGrid,
                isCmdline: isSpecialWindow  // Treat popupmenu same as cmdline for rendering
            ) else {
                ZonvieCore.appLog("[external_window] failed to create ExternalGridView")
                return
            }

            gridView.mainTerminalView = mainView  // Enable key event forwarding

            if isSpecialWindow {
                // Special window (cmdline or popupmenu): minimal styling
                // Create container view (no shadow margin - use window shadow instead)
                let containerView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
                containerView.wantsLayer = true
                containerView.layer?.cornerRadius = 8.0
                containerView.layer?.masksToBounds = true

                // Set semi-transparent background on containerView for margin area
                // gridView will be transparent so this color shows through uniformly
                if ZonvieConfig.shared.blurEnabled {
                    let opacity = ZonvieConfig.shared.backgroundAlpha
                    containerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(opacity)).cgColor
                } else {
                    containerView.layer?.backgroundColor = NSColor.black.cgColor
                }

                // Border using Search highlight color
                let borderColor = self.getSearchHighlightColor()
                containerView.layer?.borderColor = borderColor.cgColor
                containerView.layer?.borderWidth = 1.0

                // Add icon view for cmdline window
                if isCmdline {
                    let iconView = NSImageView(frame: NSRect(
                        x: ZonvieConfig.cmdlineIconMarginLeft,
                        y: (containerHeight - ZonvieConfig.cmdlineIconSize) / 2,
                        width: ZonvieConfig.cmdlineIconSize,
                        height: ZonvieConfig.cmdlineIconSize
                    ))
                    iconView.imageScaling = .scaleProportionallyUpOrDown

                    containerView.addSubview(iconView)
                    self.cmdlineIconView = iconView

                    // Set icon based on current firstc
                    ZonvieCore.appLog("[cmdline] window created, firstc=\(self.cmdlineFirstc), calling updateCmdlineIcon()")
                    self.updateCmdlineIcon()
                }

                // Position gridView with padding inside containerView (offset by icon width for cmdline)
                // For cmdline: offset includes icon area; for msg_show/msg_history: use msgPadding
                let gridViewX = cmdlinePadding + cmdlineIconTotalWidth + msgPadding
                let gridViewY = cmdlinePadding + msgPadding
                gridView.frame = NSRect(x: gridViewX, y: gridViewY, width: contentWidth, height: contentHeight)
                containerView.addSubview(gridView)

                // Resize window to container size
                // For cmdline: use position from windowRect (already calculated above)
                // For popupmenu: keep the position from windowRect (already set near cursor)
                if isCmdline {
                    // windowRect already has the correct position (below promptWindow or saved/centered)
                    // Just resize to container size, keeping the position from windowRect
                    window.setFrame(NSRect(x: windowRect.origin.x, y: windowRect.origin.y, width: containerWidth, height: containerHeight), display: false)
                    ZonvieCore.appLog("[cmdline] final frame: \(window.frame)")
                } else {
                    // Popupmenu: just resize to container size, keep position from windowRect
                    window.setContentSize(NSSize(width: containerWidth, height: containerHeight))
                }

                window.contentView = containerView
                window.backgroundColor = .clear
                window.isOpaque = false
                window.hasShadow = true  // Use window's native shadow

                // Apply CGSSetWindowBackgroundBlurRadius (same as main window)
                if ZonvieConfig.shared.blurEnabled {
                    ZonvieCore.applyWindowBlur(window: window, radius: ZonvieConfig.shared.window.blurRadius)
                }
            } else {
                // Regular external window
                gridView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
                window.contentView = gridView
                if ZonvieConfig.shared.blurEnabled {
                    window.isOpaque = false
                    window.backgroundColor = .clear
                }
            }

            // Set up delegate for resize handling (skip for special windows - non-resizable)
            if !isSpecialWindow {
                let delegate = ExternalWindowDelegate(
                    core: self,
                    gridId: gridId,
                    cellWidthPx: cellW,
                    cellHeightPx: cellH
                )
                window.delegate = delegate
                self.externalWindowDelegates[gridId] = delegate
            }

            // Show the window without stealing key status.
            // Activation is handled by onCursorGridChanged based on cursor position.
            window.orderFront(nil)

            // Apply blur using private API if enabled (but NOT for special windows)
            if ZonvieConfig.shared.blurEnabled && !isSpecialWindow {
                Self.applyWindowBlur(window: window, radius: ZonvieConfig.shared.window.blurRadius)
            }

            self.externalWindows[gridId] = window
            self.externalGridViews[gridId] = gridView
            // Set lastCursorGrid and activate this window
            self.lastCursorGrid = gridId
            window.makeKeyAndOrderFront(nil)
            if let gridView = self.externalGridViews[gridId] {
                window.makeFirstResponder(gridView)
            }
            let windowType = isCmdline ? "cmdline" : (isPopupmenu ? "popupmenu" : "regular")
            ZonvieCore.appLog("[external_window] created \(windowType) window for gridId=\(gridId)")

            // Apply any pending vertices that were saved before gridView was created (per-row)
            let pendingVerts = self.pendingExternalVertices.removeValue(forKey: gridId)
            if let pendingVerts = pendingVerts {
                let totalVertCount = pendingVerts.rowVertices.values.reduce(0) { $0 + $1.count }
                ZonvieCore.appLog("[external_window] applying pending vertices for gridId=\(gridId) rows=\(pendingVerts.rowVertices.count) totalVerts=\(totalVertCount)")

                // Apply each row's vertices
                for (rowStart, vertices) in pendingVerts.rowVertices.sorted(by: { $0.key < $1.key }) {
                    vertices.withUnsafeBufferPointer { buffer in
                        gridView.submitVerticesRowRaw(
                            rowStart: rowStart,
                            rowCount: 1,
                            ptr: buffer.baseAddress,
                            count: buffer.count,
                            totalRows: Int(pendingVerts.rows),
                            totalCols: Int(pendingVerts.cols)
                        )
                    }
                }

                // Also extract and apply background color from first row's vertices
                if let contentView = window.contentView,
                   let firstRowVertices = pendingVerts.rowVertices[0] {
                    for v in firstRowVertices {
                        if v.texCoord.0 < 0 {
                            let bgColor = NSColor(
                                red: CGFloat(v.color.0),
                                green: CGFloat(v.color.1),
                                blue: CGFloat(v.color.2),
                                alpha: CGFloat(v.color.3)
                            )
                            ZonvieCore.appLog("[external_window] applying bg color from pending vertices for gridId=\(gridId)")
                            self.applyExternalGridConfig(
                                gridId: gridId,
                                window: window,
                                containerView: contentView,
                                gridView: gridView,
                                bgColor: bgColor,
                                rows: pendingVerts.rows,
                                cols: pendingVerts.cols
                            )
                            break
                        }
                    }
                }

                gridView.requestRedraw()
            }

            // Apply any pending configuration that was saved before window was created (fallback)
            if let pendingConfig = self.pendingExternalGridConfig.removeValue(forKey: gridId),
               let contentView = window.contentView {
                ZonvieCore.appLog("[external_window] applying pending config for gridId=\(gridId) bgColor=\(pendingConfig.bgColor)")
                self.applyExternalGridConfig(
                    gridId: gridId,
                    window: window,
                    containerView: contentView,
                    gridView: gridView,
                    bgColor: pendingConfig.bgColor,
                    rows: pendingConfig.rows,
                    cols: pendingConfig.cols
                )
            }

            // If msg_history window was just created, reposition msg_show window below it
            if isMsgHistory {
                if let msgShowWindow = self.externalWindows[ZonvieCore.messageGridId],
                   msgShowWindow.isVisible {
                    let targetFrame = getExtFloatTargetFrame()
                    let historyFrame = window.frame
                    let msgShowFrame = msgShowWindow.frame
                    let msgShowX = targetFrame.maxX - msgShowFrame.width - 10
                    let msgShowY = historyFrame.origin.y - msgShowFrame.height - 4  // 4px gap below history
                    msgShowWindow.setFrame(NSRect(x: msgShowX, y: msgShowY, width: msgShowFrame.width, height: msgShowFrame.height), display: false)
                    ZonvieCore.appLog("[external_window] repositioned msg_show below new msg_history at (\(msgShowX),\(msgShowY))")
                }
            }

            // Refresh main window's blur effect after external window is shown
            // DEBUG: This may cause blur to become stronger when external windows are shown
            if ZonvieConfig.shared.blurEnabled, let mainWindow = self.terminalView?.window {
                ZonvieCore.appLog("[DEBUG-BLUR-REFRESH] Re-applying blur to main window after external window shown")
                Self.applyWindowBlur(window: mainWindow, radius: ZonvieConfig.shared.window.blurRadius)
            }
        }
    }

    /// Process any pending external window requests that were queued when
    /// terminalView or pipeline was not ready.
    private func processPendingExternalWindows() {
        guard !pendingExternalWindowRequests.isEmpty else { return }
        let requests = pendingExternalWindowRequests
        pendingExternalWindowRequests.removeAll()
        ZonvieCore.appLog("[external_window] processing \(requests.count) pending request(s)")
        for req in requests {
            onExternalWindow(gridId: req.gridId, win: req.win, rows: req.rows, cols: req.cols, startRow: req.startRow, startCol: req.startCol)
        }
    }

    /// Configure background color and window layout for external grids (called from on_vertices_row).
    /// This extracts the background color from vertices and applies it to containerView and gridView.
    private func configureExternalGridFromRow(
        gridId: Int64,
        gridView: ExternalGridView,
        verts: UnsafePointer<zonvie_vertex>,
        vertCount: Int,
        rows: UInt32,
        cols: UInt32
    ) {
        precondition(Thread.isMainThread, "configureExternalGridFromRow must be called on the main thread")
        ZonvieCore.appLog("[configureExtGridRow] gridId=\(gridId) vertCount=\(vertCount) rows=\(rows) cols=\(cols)")

        // Extract background color from first background vertex
        let isSpecialGrid = (gridId == ZonvieCore.cmdlineGridId || gridId == ZonvieCore.popupmenuGridId ||
                             gridId == ZonvieCore.messageGridId || gridId == ZonvieCore.msgHistoryGridId)

        var bgColor: NSColor? = nil
        var bgVertexIdx = -1
        for i in 0..<vertCount {
            let v = verts[i]
            if v.texCoord.0 < 0 {
                let r = CGFloat(v.color.0)
                let g = CGFloat(v.color.1)
                let b = CGFloat(v.color.2)
                let a = CGFloat(v.color.3)
                bgColor = NSColor(red: r, green: g, blue: b, alpha: a)
                bgVertexIdx = i
                break
            }
        }

        ZonvieCore.appLog("[configureExtGridRow] gridId=\(gridId) bgVertexIdx=\(bgVertexIdx) bgColor=\(bgColor?.description ?? "nil")")

        guard let bgColor = bgColor else {
            ZonvieCore.appLog("[configureExtGridRow] gridId=\(gridId) no bg vertex, skipping")
            return
        }

        // Apply directly - this function is always called from the main thread
        // (via on_vertices_row → DispatchQueue.main.async). Avoiding nested async
        // ensures resize completes before requestRedraw(), keeping drawable size
        // in sync with NDC viewport.
        guard let window = self.externalWindows[gridId],
              let containerView = window.contentView else {
            // Window not created yet - save pending config to apply later
            ZonvieCore.appLog("[configureExtGridRow] gridId=\(gridId) window not found, saving pending config")
            self.pendingExternalGridConfig[gridId] = (bgColor: bgColor, rows: rows, cols: cols)
            return
        }

        ZonvieCore.appLog("[configureExtGridRow] gridId=\(gridId) applying bg color=\(bgColor) isSpecial=\(isSpecialGrid)")

        self.applyExternalGridConfig(
            gridId: gridId,
            window: window,
            containerView: containerView,
            gridView: gridView,
            bgColor: bgColor,
            rows: rows,
            cols: cols
        )
    }

    /// Apply background color and layout configuration to an external grid.
    /// Called from configureExternalGridFromRow (normal path) and onExternalWindow (pending config path).
    private func applyExternalGridConfig(
        gridId: Int64,
        window: NSWindow,
        containerView: NSView,
        gridView: ExternalGridView,
        bgColor: NSColor,
        rows: UInt32,
        cols: UInt32
    ) {
        let isSpecialGrid = (gridId == ZonvieCore.cmdlineGridId || gridId == ZonvieCore.popupmenuGridId ||
                             gridId == ZonvieCore.messageGridId || gridId == ZonvieCore.msgHistoryGridId)

        // Update background color on the containerView and gridClearColor
        if isSpecialGrid {
            let adjustedBg = bgColor.adjustedForCmdlineBackground()

            if ZonvieConfig.shared.blurEnabled {
                gridView.gridClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                let opacity = ZonvieConfig.shared.backgroundAlpha
                containerView.layer?.backgroundColor = adjustedBg.withAlphaComponent(CGFloat(opacity)).cgColor
            } else {
                containerView.layer?.backgroundColor = adjustedBg.withAlphaComponent(1.0).cgColor
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                adjustedBg.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                gridView.gridClearColor = MTLClearColor(red: Double(r), green: Double(g), blue: Double(b), alpha: 1.0)
            }
        } else {
            // Regular ext_windows grid: set clear color from vertex background.
            // For regular grids, window.contentView = gridView (no separate containerView).
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            bgColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
            if ZonvieConfig.shared.blurEnabled {
                let opacity = Double(ZonvieConfig.shared.backgroundAlpha)
                gridView.gridClearColor = MTLClearColor(red: Double(r), green: Double(g), blue: Double(b), alpha: opacity)
            } else {
                gridView.gridClearColor = MTLClearColor(red: Double(r), green: Double(g), blue: Double(b), alpha: 1.0)
            }
        }

        // Resize window based on content dimensions
        guard let mainView = self.terminalView, let renderer = mainView.renderer else { return }
        let cellW = CGFloat(renderer.cellWidthPx)
        let cellH = CGFloat(renderer.cellHeightPx)
        let scale = mainView.window?.backingScaleFactor ?? 1.0

        if gridId == ZonvieCore.cmdlineGridId {
            self.resizeCmdlineWindow(window: window, containerView: containerView, gridView: gridView,
                                     rows: rows, cols: cols, cellW: cellW, cellH: cellH, scale: scale, bgColor: bgColor)
        } else if gridId == ZonvieCore.popupmenuGridId {
            self.resizePopupmenuWindow(window: window, containerView: containerView, gridView: gridView,
                                       rows: rows, cols: cols, cellW: cellW, cellH: cellH, scale: scale)
        } else if gridId == ZonvieCore.messageGridId || gridId == ZonvieCore.msgHistoryGridId {
            self.resizeMessageWindow(window: window, containerView: containerView, gridView: gridView, gridId: gridId,
                                     rows: rows, cols: cols, cellW: cellW, cellH: cellH, scale: scale)
        } else {
            // Regular ext_windows grid: Neovim controls grid dimensions (<C-w>+, :resize, etc.).
            // Resize the OS window to match the grid size.

            let contentWidth = CGFloat(cols) * cellW / scale
            let contentHeight = CGFloat(rows) * cellH / scale

            // Compare using row/col counts stored on the delegate to avoid floating-point drift.
            // The delegate tracks the last-set rows/cols, so this is an exact integer comparison.
            let delegate = window.delegate as? ExternalWindowDelegate
            let lastRows = delegate?.lastGridRows ?? 0
            let lastCols = delegate?.lastGridCols ?? 0
            if rows != lastRows || cols != lastCols {
                // Track the rows/cols we're about to set BEFORE setFrame, because
                // setFrame may trigger windowDidResize synchronously or via RunLoop.
                // The lastGridRows/lastGridCols check in windowDidResize prevents
                // the callback from calling tryResizeGrid with stale window dimensions.
                delegate?.lastGridRows = rows
                delegate?.lastGridCols = cols
                delegate?.suppressResizeCallback = true

                // Keep the top-left corner fixed (macOS coords: origin.y + height = top)
                let oldFrame = window.frame
                let oldTop = oldFrame.origin.y + oldFrame.height

                // Use setContentSize approach: compute new frame from desired content rect
                let contentRect = NSRect(x: oldFrame.origin.x, y: 0,
                                         width: contentWidth, height: contentHeight)
                let frameRect = window.frameRect(forContentRect: contentRect)
                let newFrame = NSRect(x: oldFrame.origin.x, y: oldTop - frameRect.height,
                                      width: frameRect.width, height: frameRect.height)
                window.setFrame(newFrame, display: true)

                // Update gridView frame to fill the new content area
                gridView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

                delegate?.suppressResizeCallback = false

                ZonvieCore.appLog("[ext_windows] resized grid=\(gridId) rows=\(rows) cols=\(cols) content=\(contentWidth)x\(contentHeight)")
            }

            // Set clear color so viewport-edge pixels match the grid background.
            // For blur: use backgroundAlpha so edges match the semi-transparent content.
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            bgColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
            let clearAlpha = ZonvieConfig.shared.blurEnabled ? Double(ZonvieConfig.shared.backgroundAlpha) : 1.0
            gridView.gridClearColor = MTLClearColor(red: Double(r), green: Double(g), blue: Double(b), alpha: clearAlpha)
        }
    }

    /// Resize cmdline window based on content dimensions.
    private func resizeCmdlineWindow(window: NSWindow, containerView: NSView, gridView: ExternalGridView,
                                     rows: UInt32, cols: UInt32, cellW: CGFloat, cellH: CGFloat, scale: CGFloat, bgColor: NSColor) {
        // Update border color from Search highlight
        let borderColor = self.getSearchHighlightColor()
        containerView.layer?.borderColor = borderColor.cgColor
        containerView.layer?.borderWidth = 1.0

        let cmdlinePadding = ZonvieConfig.cmdlinePadding
        let cmdlineIconTotalWidth = ZonvieConfig.cmdlineIconTotalWidth

        var contentWidth = CGFloat(cols) * cellW / scale
        let contentHeight = CGFloat(rows) * cellH / scale

        // TODO: Use window.screen instead of NSScreen.main for multi-display correctness.
        if let screen = NSScreen.main {
            let maxContentWidth = screen.visibleFrame.width - (cmdlinePadding * 2) - cmdlineIconTotalWidth - ZonvieConfig.cmdlineScreenMargin
            contentWidth = min(contentWidth, maxContentWidth)
        }

        let containerWidth = contentWidth + (cmdlinePadding * 2) + cmdlineIconTotalWidth
        let containerHeight = contentHeight + (cmdlinePadding * 2)

        let gridViewX = cmdlinePadding + cmdlineIconTotalWidth
        gridView.frame = NSRect(x: gridViewX, y: cmdlinePadding, width: contentWidth, height: contentHeight)

        if let iconView = self.cmdlineIconView {
            iconView.frame = NSRect(
                x: ZonvieConfig.cmdlineIconMarginLeft,
                y: (containerHeight - ZonvieConfig.cmdlineIconSize) / 2,
                width: ZonvieConfig.cmdlineIconSize,
                height: ZonvieConfig.cmdlineIconSize
            )
        }

        containerView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight)

        let oldFrame = window.frame
        var newX = oldFrame.midX - containerWidth / 2
        var newY = oldFrame.midY - containerHeight / 2

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            if containerWidth >= screenFrame.width * 0.9 {
                newX = screenFrame.minX + (screenFrame.width - containerWidth) / 2
            } else {
                newX = max(screenFrame.minX, min(newX, screenFrame.maxX - containerWidth))
            }
            newY = max(screenFrame.minY, min(newY, screenFrame.maxY - containerHeight))
        }

        window.setFrame(NSRect(x: newX, y: newY, width: containerWidth, height: containerHeight), display: true)
    }

    /// Resize popupmenu window based on content dimensions.
    private func resizePopupmenuWindow(window: NSWindow, containerView: NSView, gridView: ExternalGridView,
                                       rows: UInt32, cols: UInt32, cellW: CGFloat, cellH: CGFloat, scale: CGFloat) {
        let popupmenuPadding: CGFloat = 8.0
        let contentWidth = CGFloat(cols) * cellW / scale
        let contentHeight = CGFloat(rows) * cellH / scale
        let containerWidth = contentWidth + (popupmenuPadding * 2)
        let containerHeight = contentHeight + (popupmenuPadding * 2)

        gridView.frame = NSRect(x: popupmenuPadding, y: popupmenuPadding, width: contentWidth, height: contentHeight)
        containerView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight)

        let oldFrame = window.frame
        window.setFrame(NSRect(x: oldFrame.origin.x, y: oldFrame.origin.y, width: containerWidth, height: containerHeight), display: true)
    }

    /// Resize message window based on content dimensions.
    private func resizeMessageWindow(window: NSWindow, containerView: NSView, gridView: ExternalGridView, gridId: Int64,
                                     rows: UInt32, cols: UInt32, cellW: CGFloat, cellH: CGFloat, scale: CGFloat) {
        let msgPadding: CGFloat = 8.0
        let contentWidth = CGFloat(cols) * cellW / scale
        let contentHeight = CGFloat(rows) * cellH / scale
        let containerWidth = contentWidth + (msgPadding * 2)
        let containerHeight = contentHeight + (msgPadding * 2)

        gridView.frame = NSRect(x: msgPadding, y: msgPadding, width: contentWidth, height: contentHeight)
        containerView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight)

        guard let mainWindow = self.terminalView?.window else { return }
        let targetFrame = mainWindow.frame
        let newX = targetFrame.maxX - containerWidth - 10
        var newY = targetFrame.maxY - containerHeight - 40

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            newY = max(screenFrame.minY, min(newY, screenFrame.maxY - containerHeight))
        }

        window.setFrame(NSRect(x: newX, y: newY, width: containerWidth, height: containerHeight), display: true)

        if gridId == ZonvieCore.msgHistoryGridId {
            if let msgShowWindow = self.externalWindows[ZonvieCore.messageGridId] {
                let msgShowFrame = msgShowWindow.frame
                let msgShowX = targetFrame.maxX - msgShowFrame.width - 10
                let msgShowY = newY - msgShowFrame.height - 4
                msgShowWindow.setFrame(NSRect(x: msgShowX, y: msgShowY, width: msgShowFrame.width, height: msgShowFrame.height), display: true)
            }
        }
    }

    /// Called when an external grid is closed.
    private func onExternalWindowClose(gridId: Int64) {
        ZonvieCore.appLog("[external_window] close gridId=\(gridId)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.externalWindowDelegates.removeValue(forKey: gridId)
            self.externalGridViews.removeValue(forKey: gridId)
            self.externalWindowWinIds.removeValue(forKey: gridId)
            if let window = self.externalWindows.removeValue(forKey: gridId) {
                // Save window position for restoration on tab switch back
                self.savedExternalWindowPositions[gridId] = window.frame.origin
                ZonvieCore.appLog("[external_window] saved position for gridId=\(gridId): \(window.frame.origin)")
                window.delegate = nil
                window.close()
                ZonvieCore.appLog("[external_window] closed window for gridId=\(gridId)")
            }

            // Force redraw of main terminal view to clear any residual artifacts
            // This is needed when blur is enabled because transparent layers may cache
            // content from overlapping windows
            if ZonvieConfig.shared.blurEnabled {
                self.terminalView?.needsDisplay = true
                // Also invalidate the blur layer to refresh
                if let contentView = self.terminalView?.window?.contentView {
                    contentView.needsDisplay = true
                    for subview in contentView.subviews {
                        if subview is NSVisualEffectView {
                            subview.needsDisplay = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - ext_windows Layout Operations

    /// Info about a window (main or external) for layout operations.
    private struct WindowLayoutInfo {
        let gridId: Int64
        let winId: Int64
        let frame: NSRect
        let window: NSWindow
    }

    /// Collect layout info for all visible windows. Must be called on main thread.
    /// `includeMainWindow`: all ext_windows operations pass true. Parameter retained for future use.
    /// Main window is registered as grid 2 (Neovim's default editor grid).
    private func allWindowLayoutInfos(includeMainWindow: Bool = true) -> [WindowLayoutInfo] {
        var result: [WindowLayoutInfo] = []

        // Main window uses grid 2 (the default editor grid), not grid 1 (Neovim's global grid)
        if includeMainWindow, let mainWindow = terminalView?.window {
            let mainWinId: Int64 = (core != nil) ? zonvie_core_get_win_id(core, 2) : 0
            result.append(WindowLayoutInfo(gridId: 2, winId: mainWinId, frame: mainWindow.frame, window: mainWindow))
        }

        // External windows (skip special windows like cmdline/popupmenu/msg and hidden windows)
        for (gridId, window) in externalWindows {
            if gridId < 0 { continue }  // Skip special windows (cmdline=-100, popupmenu=-101, etc.)
            if !window.isVisible { continue }  // Skip hidden windows
            let winId = externalWindowWinIds[gridId] ?? 0
            result.append(WindowLayoutInfo(gridId: gridId, winId: winId, frame: window.frame, window: window))
        }

        return result
    }

    /// Find the nearest window in the given direction from a reference frame.
    /// direction: 0=down, 1=up, 2=right, 3=left
    /// macOS coordinate system: Y increases upward.
    /// Falls back to the nearest window overall when no candidate is found in the strict direction
    /// (e.g. when window centers align on the checked axis).
    private func findWindowInDirection(
        from refFrame: NSRect,
        refGridId: Int64,
        direction: Int32,
        count: Int32,
        infos: [WindowLayoutInfo]
    ) -> WindowLayoutInfo? {
        let refCenterX = refFrame.midX
        let refCenterY = refFrame.midY

        let others = infos.filter { $0.gridId != refGridId }
        if others.isEmpty { return nil }

        // Filter candidates by direction
        let candidates = others.filter { info in
            let cx = info.frame.midX
            let cy = info.frame.midY
            switch direction {
            case 0: return cy < refCenterY  // down (macOS: lower Y)
            case 1: return cy > refCenterY  // up (macOS: higher Y)
            case 2: return cx > refCenterX  // right
            case 3: return cx < refCenterX  // left
            default: return false
            }
        }

        // Use directional candidates if available, otherwise fall back to all other windows
        let pool = candidates.isEmpty ? others : candidates

        // Sort by distance
        let sorted = pool.sorted { a, b in
            let distA = abs(a.frame.midX - refCenterX) + abs(a.frame.midY - refCenterY)
            let distB = abs(b.frame.midX - refCenterX) + abs(b.frame.midY - refCenterY)
            return distA < distB
        }

        let idx = Int(count) - 1
        return (idx >= 0 && idx < sorted.count) ? sorted[idx] : sorted.first
    }

    /// Handle win_move: swap this window's position with the nearest window in direction.
    private func handleWinMove(gridId: Int64, flags: Int32) {
        let infos = allWindowLayoutInfos(includeMainWindow: true)
        ZonvieCore.appLog("[ext_win] handleWinMove: grid=\(gridId) flags=\(flags) infos=\(infos.map { "grid=\($0.gridId) frame=\($0.frame)" })")
        guard let source = infos.first(where: { $0.gridId == gridId }) else {
            ZonvieCore.appLog("[ext_win] handleWinMove: source grid=\(gridId) not found in \(infos.count) windows")
            return
        }
        guard let target = findWindowInDirection(from: source.frame, refGridId: gridId, direction: flags, count: 1, infos: infos) else {
            ZonvieCore.appLog("[ext_win] handleWinMove: no target found for grid=\(gridId) direction=\(flags)")
            return
        }

        // Swap top-left positions (keep each window's size)
        // macOS origin is bottom-left; top-left Y = origin.y + height
        let sourceTopLeftY = source.frame.origin.y + source.frame.height
        let targetTopLeftY = target.frame.origin.y + target.frame.height
        var newSourceFrame = source.frame
        newSourceFrame.origin.x = target.frame.origin.x
        newSourceFrame.origin.y = targetTopLeftY - source.frame.height
        var newTargetFrame = target.frame
        newTargetFrame.origin.x = source.frame.origin.x
        newTargetFrame.origin.y = sourceTopLeftY - target.frame.height
        source.window.setFrame(newSourceFrame, display: true)
        target.window.setFrame(newTargetFrame, display: true)
        ZonvieCore.appLog("[ext_win] handleWinMove: swapped grid=\(gridId) with grid=\(target.gridId)")
    }

    /// Handle win_exchange: swap with the count-th window in spatial order.
    private func handleWinExchange(gridId: Int64, count: Int32) {
        let infos = allWindowLayoutInfos(includeMainWindow: true)
        guard infos.count >= 2 else {
            ZonvieCore.appLog("[ext_win] handleWinExchange: only \(infos.count) windows, need >= 2")
            return
        }

        // Sort by position: top-to-bottom, left-to-right (macOS: high Y first, then low X)
        let sorted = infos.sorted { a, b in
            if abs(a.frame.midY - b.frame.midY) > 20 { return a.frame.midY > b.frame.midY }
            return a.frame.midX < b.frame.midX
        }

        guard let srcIdx = sorted.firstIndex(where: { $0.gridId == gridId }) else {
            ZonvieCore.appLog("[ext_win] handleWinExchange: source grid=\(gridId) not found")
            return
        }

        // count=0 means "next window" (default for <C-w>x without count prefix)
        let effectiveCount = (count == 0) ? 1 : Int(count)
        let dstIdx = (srcIdx + effectiveCount) % sorted.count
        let adjustedDst = dstIdx < 0 ? dstIdx + sorted.count : dstIdx
        guard adjustedDst != srcIdx, adjustedDst >= 0, adjustedDst < sorted.count else { return }

        // Swap top-left positions (keep each window's size)
        // macOS origin is bottom-left; top-left Y = origin.y + height
        let srcTopLeftY = sorted[srcIdx].frame.origin.y + sorted[srcIdx].frame.height
        let dstTopLeftY = sorted[adjustedDst].frame.origin.y + sorted[adjustedDst].frame.height
        var newSrcFrame = sorted[srcIdx].frame
        newSrcFrame.origin.x = sorted[adjustedDst].frame.origin.x
        newSrcFrame.origin.y = dstTopLeftY - sorted[srcIdx].frame.height
        var newDstFrame = sorted[adjustedDst].frame
        newDstFrame.origin.x = sorted[srcIdx].frame.origin.x
        newDstFrame.origin.y = srcTopLeftY - sorted[adjustedDst].frame.height
        sorted[srcIdx].window.setFrame(newSrcFrame, display: true)
        sorted[adjustedDst].window.setFrame(newDstFrame, display: true)
        ZonvieCore.appLog("[ext_win] handleWinExchange: swapped grid=\(gridId) with grid=\(sorted[adjustedDst].gridId)")
    }

    /// Handle win_rotate: cycle all window positions.
    private func handleWinRotate(direction: Int32, count: Int32) {
        let infos = allWindowLayoutInfos(includeMainWindow: true)
        guard infos.count >= 2 else {
            ZonvieCore.appLog("[ext_win] handleWinRotate: only \(infos.count) windows, need >= 2")
            return
        }

        // Sort spatially
        let sorted = infos.sorted { a, b in
            if abs(a.frame.midY - b.frame.midY) > 20 { return a.frame.midY > b.frame.midY }
            return a.frame.midX < b.frame.midX
        }

        // Rotate top-left positions only (keep each window's size)
        // macOS origin is bottom-left; top-left = (origin.x, origin.y + height)
        var topLeftXs = sorted.map { $0.frame.origin.x }
        var topLeftYs = sorted.map { $0.frame.origin.y + $0.frame.height }
        let n = topLeftXs.count

        // count=0 means "rotate once" (default for <C-w>r without count prefix)
        let effectiveCount = (count == 0) ? 1 : Int(count)

        for _ in 0..<effectiveCount {
            if direction == 0 {
                // Downward: each window gets the next window's position
                let lastX = topLeftXs[n - 1]
                let lastY = topLeftYs[n - 1]
                for i in stride(from: n - 1, through: 1, by: -1) {
                    topLeftXs[i] = topLeftXs[i - 1]
                    topLeftYs[i] = topLeftYs[i - 1]
                }
                topLeftXs[0] = lastX
                topLeftYs[0] = lastY
            } else {
                // Upward: each window gets the previous window's position
                let firstX = topLeftXs[0]
                let firstY = topLeftYs[0]
                for i in 0..<(n - 1) {
                    topLeftXs[i] = topLeftXs[i + 1]
                    topLeftYs[i] = topLeftYs[i + 1]
                }
                topLeftXs[n - 1] = firstX
                topLeftYs[n - 1] = firstY
            }
        }

        // Apply: convert top-left back to macOS origin (bottom-left)
        for (i, info) in sorted.enumerated() {
            var newFrame = info.frame
            newFrame.origin.x = topLeftXs[i]
            newFrame.origin.y = topLeftYs[i] - info.frame.height
            info.window.setFrame(newFrame, display: true)
        }
        ZonvieCore.appLog("[ext_win] handleWinRotate: rotated \(sorted.count) windows direction=\(direction) count=\(count)")
    }

    /// Handle win_resize_equal: make all windows equal size (including main window).
    private func handleWinResizeEqual() {
        let infos = allWindowLayoutInfos(includeMainWindow: true)
        guard infos.count >= 2 else { return }

        // Calculate average size
        let totalWidth = infos.reduce(CGFloat(0)) { $0 + $1.frame.width }
        let totalHeight = infos.reduce(CGFloat(0)) { $0 + $1.frame.height }
        let avgWidth = totalWidth / CGFloat(infos.count)
        let avgHeight = totalHeight / CGFloat(infos.count)

        for info in infos {
            var newFrame = info.frame
            newFrame.size = NSSize(width: avgWidth, height: avgHeight)
            info.window.setFrame(newFrame, display: true)
        }
        ZonvieCore.appLog("[ext_win] handleWinResizeEqual: equalized \(infos.count) windows to \(avgWidth)x\(avgHeight)")
    }

    /// Handle win_move_cursor: find window in direction and return its win_id. Synchronous.
    private func handleWinMoveCursor(direction: Int32, count: Int32) -> Int64 {
        var targetWin: Int64 = 0

        let work = { [self] in
            let infos = allWindowLayoutInfos(includeMainWindow: true)

            // Find current cursor grid
            var cursorRow: Int32 = 0
            var cursorCol: Int32 = 0
            let cursorGrid = (core != nil) ? zonvie_core_get_cursor_position(core, &cursorRow, &cursorCol) : Int64(1)

            ZonvieCore.appLog("[ext_win] handleWinMoveCursor: cursorGrid=\(cursorGrid) direction=\(direction) count=\(count) infos=\(infos.map { "grid=\($0.gridId) win=\($0.winId) frame=\($0.frame)" })")

            guard let current = infos.first(where: { $0.gridId == cursorGrid }) else {
                ZonvieCore.appLog("[ext_win] handleWinMoveCursor: cursorGrid=\(cursorGrid) not found in infos, fallback to main")
                // Fallback: use main window (grid 2)
                if let main = infos.first(where: { $0.gridId == 2 }) {
                    if let target = findWindowInDirection(from: main.frame, refGridId: 2, direction: direction, count: count, infos: infos) {
                        targetWin = target.winId
                    }
                }
                return
            }

            if let target = findWindowInDirection(from: current.frame, refGridId: cursorGrid, direction: direction, count: count, infos: infos) {
                targetWin = target.winId
                ZonvieCore.appLog("[ext_win] handleWinMoveCursor: found target grid=\(target.gridId) win=\(target.winId) frame=\(target.frame)")
            } else {
                ZonvieCore.appLog("[ext_win] handleWinMoveCursor: no target found for direction=\(direction)")
            }
        }

        // Avoid deadlock: if already on main thread, execute directly
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync { work() }
        }

        ZonvieCore.appLog("[ext_win] handleWinMoveCursor: direction=\(direction) count=\(count) -> win=\(targetWin)")
        return targetWin
    }

    /// Called to update vertices for an external grid.
    private func onExternalVertices(gridId: Int64, verts: UnsafePointer<zonvie_vertex>?, vertCount: Int, rows: UInt32, cols: UInt32) {
        ZonvieCore.appLog("[external_vertices] gridId=\(gridId) vertCount=\(vertCount) rows=\(rows) cols=\(cols)")

        guard let verts = verts, vertCount > 0 else { return }

        // Debug: Count vertex types (background vs glyph)
        // Background vertices have texCoord.x < 0, glyph vertices have texCoord.x >= 0
        var bgCount = 0
        var glyphCount = 0
        for i in 0..<min(vertCount, 100) { // Sample first 100 vertices
            let v = verts[i]
            if v.texCoord.0 < 0 {
                bgCount += 1
            } else {
                glyphCount += 1
            }
        }
        ZonvieCore.appLog("[external_vertices] sample: bg=\(bgCount) glyph=\(glyphCount) (of \(min(vertCount, 100)) sampled)")

        // Extract background color from first background vertex (for special windows)
        let isSpecialGrid = (gridId == ZonvieCore.cmdlineGridId || gridId == ZonvieCore.popupmenuGridId ||
                             gridId == ZonvieCore.messageGridId || gridId == ZonvieCore.msgHistoryGridId)
        var bgColor: NSColor? = nil
        if isSpecialGrid {
            // Find first background vertex (texCoord.x < 0)
            for i in 0..<vertCount {
                let v = verts[i]
                if v.texCoord.0 < 0 {
                    // Extract color from vertex (RGBA float)
                    let r = CGFloat(v.color.0)
                    let g = CGFloat(v.color.1)
                    let b = CGFloat(v.color.2)
                    let a = CGFloat(v.color.3)
                    bgColor = NSColor(red: r, green: g, blue: b, alpha: a)
                    let gridType: String
                    switch gridId {
                    case ZonvieCore.cmdlineGridId: gridType = "cmdline"
                    case ZonvieCore.popupmenuGridId: gridType = "popupmenu"
                    case ZonvieCore.messageGridId: gridType = "msg_show"
                    case ZonvieCore.msgHistoryGridId: gridType = "msg_history"
                    default: gridType = "unknown"
                    }
                    ZonvieCore.appLog("[external_vertices] \(gridType) bg color: r=\(r) g=\(g) b=\(b) a=\(a)")
                    break
                }
            }
        }

        // Copy vertex data synchronously before dispatching to main thread.
        // The verts pointer is only valid during this callback - Zig may reuse the buffer after we return.
        let byteCount = vertCount * MemoryLayout<zonvie_vertex>.stride
        var vertexDataCopy = Data(bytes: verts, count: byteCount)

        // For special grids (cmdline, popupmenu, msg_show, msg_history), modify background vertex colors to adjusted color
        if isSpecialGrid, let bgColor = bgColor {
            let adjustedBg = bgColor.adjustedForCmdlineBackground()
            var adjR: CGFloat = 0, adjG: CGFloat = 0, adjB: CGFloat = 0, adjA: CGFloat = 0
            adjustedBg.usingColorSpace(.sRGB)?.getRed(&adjR, green: &adjG, blue: &adjB, alpha: &adjA)

            // For special grids: gridView background is transparent (containerView provides the color)
            // This ensures margin and cell areas have the same color
            if ZonvieConfig.shared.blurEnabled {
                adjA = 0.0
            } else {
                adjA = 1.0
            }

            ZonvieCore.appLog("[external_vertices] special grid color adjustment: blurEnabled=\(ZonvieConfig.shared.blurEnabled) adjR=\(adjR) adjG=\(adjG) adjB=\(adjB) adjA=\(adjA)")

            // Get original background color for comparison
            var origR: CGFloat = 0, origG: CGFloat = 0, origB: CGFloat = 0, origA: CGFloat = 0
            bgColor.usingColorSpace(.sRGB)?.getRed(&origR, green: &origG, blue: &origB, alpha: &origA)

            // Modify only vertices that match the original background color (not cursor)
            // Use tight tolerance to avoid accidentally making cursor transparent
            // Also skip vertices marked with DECO_CURSOR flag
            vertexDataCopy.withUnsafeMutableBytes { rawBuffer in
                let vertexPtr = rawBuffer.baseAddress!.bindMemory(to: zonvie_vertex.self, capacity: vertCount)
                for i in 0..<vertCount {
                    // Skip cursor vertices (marked with DECO_CURSOR flag)
                    if (vertexPtr[i].deco_flags & ZONVIE_DECO_CURSOR) != 0 {
                        continue
                    }
                    if vertexPtr[i].texCoord.0 < 0 {
                        // Check if this vertex color matches original bg (with tolerance)
                        let vr = CGFloat(vertexPtr[i].color.0)
                        let vg = CGFloat(vertexPtr[i].color.1)
                        let vb = CGFloat(vertexPtr[i].color.2)
                        let tolerance: CGFloat = 0.005
                        if abs(vr - origR) < tolerance && abs(vg - origG) < tolerance && abs(vb - origB) < tolerance {
                            // This is a background vertex - update its color
                            vertexPtr[i].color.0 = Float(adjR)
                            vertexPtr[i].color.1 = Float(adjG)
                            vertexPtr[i].color.2 = Float(adjB)
                            vertexPtr[i].color.3 = Float(adjA)
                        }
                    }
                }
            }
        }

        // Submit vertices to the external grid view on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let gridView = self.externalGridViews[gridId] else {
                ZonvieCore.appLog("[external_vertices] no grid view for gridId=\(gridId)")
                return
            }

            // Update special window (cmdline, popupmenu, msg_show, msg_history) background color
            let isSpecialGridForBg = (gridId == ZonvieCore.cmdlineGridId || gridId == ZonvieCore.popupmenuGridId ||
                                      gridId == ZonvieCore.messageGridId || gridId == ZonvieCore.msgHistoryGridId)
            if isSpecialGridForBg,
               let window = self.externalWindows[gridId],
               let containerView = window.contentView {

                // Update background color on the containerView (HSV adjusted for visibility)
                if let bgColor = bgColor {
                    let adjustedBg = bgColor.adjustedForCmdlineBackground()

                    if ZonvieConfig.shared.blurEnabled {
                        // For blur mode: gridView is fully transparent
                        // containerView provides the semi-transparent background color
                        // This ensures margin and cell areas have the same color
                        gridView.gridClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

                        // Update containerView background color with adjusted color
                        let opacity = ZonvieConfig.shared.backgroundAlpha
                        containerView.layer?.backgroundColor = adjustedBg.withAlphaComponent(CGFloat(opacity)).cgColor
                    } else {
                        // Force opaque background when blur is disabled
                        containerView.layer?.backgroundColor = adjustedBg.withAlphaComponent(1.0).cgColor
                        let gridType: String
                        switch gridId {
                        case ZonvieCore.cmdlineGridId: gridType = "cmdline"
                        case ZonvieCore.popupmenuGridId: gridType = "popupmenu"
                        case ZonvieCore.messageGridId: gridType = "msg_show"
                        case ZonvieCore.msgHistoryGridId: gridType = "msg_history"
                        default: gridType = "unknown"
                        }
                        ZonvieCore.appLog("[external_vertices] \(gridType) containerView.backgroundColor set to opaque adjustedBg")

                        // Update the Metal gridView's clear color
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        adjustedBg.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                        gridView.gridClearColor = MTLClearColor(red: Double(r), green: Double(g), blue: Double(b), alpha: 1.0)
                    }
                }
            }

            // Update cmdline window: resize and border
            if gridId == ZonvieCore.cmdlineGridId,
               let window = self.externalWindows[gridId],
               let mainView = self.terminalView,
               let containerView = window.contentView {

                // Update border color from Search highlight
                let borderColor = self.getSearchHighlightColor()
                containerView.layer?.borderColor = borderColor.cgColor
                containerView.layer?.borderWidth = 1.0

                // Resize window based on new content dimensions
                let renderer = mainView.renderer!
                let cellW = CGFloat(renderer.cellWidthPx)
                let cellH = CGFloat(renderer.cellHeightPx)
                let scale = mainView.window?.backingScaleFactor ?? 1.0

                let cmdlinePadding = ZonvieConfig.cmdlinePadding
                let cmdlineIconTotalWidth = ZonvieConfig.cmdlineIconTotalWidth

                var contentWidth = CGFloat(cols) * cellW / scale
                let contentHeight = CGFloat(rows) * cellH / scale

                // Constrain width to screen width
                if let screen = NSScreen.main {
                    let maxContentWidth = screen.visibleFrame.width - (cmdlinePadding * 2) - cmdlineIconTotalWidth - ZonvieConfig.cmdlineScreenMargin
                    contentWidth = min(contentWidth, maxContentWidth)
                }

                let containerWidth = contentWidth + (cmdlinePadding * 2) + cmdlineIconTotalWidth
                let containerHeight = contentHeight + (cmdlinePadding * 2)

                // Update gridView frame inside containerView (offset by icon width)
                let gridViewX = cmdlinePadding + cmdlineIconTotalWidth
                if let gridView = self.externalGridViews[gridId] {
                    gridView.frame = NSRect(x: gridViewX, y: cmdlinePadding, width: contentWidth, height: contentHeight)
                }

                // Update icon view position (vertically centered)
                if let iconView = self.cmdlineIconView {
                    iconView.frame = NSRect(
                        x: ZonvieConfig.cmdlineIconMarginLeft,
                        y: (containerHeight - ZonvieConfig.cmdlineIconSize) / 2,
                        width: ZonvieConfig.cmdlineIconSize,
                        height: ZonvieConfig.cmdlineIconSize
                    )
                }

                // Update containerView frame (fills window)
                containerView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight)

                // Update window size while keeping center position, but ensure it stays on screen
                let oldFrame = window.frame
                let oldCenterX = oldFrame.midX
                let oldCenterY = oldFrame.midY
                var newX = oldCenterX - containerWidth / 2
                var newY = oldCenterY - containerHeight / 2

                // Clamp to screen bounds, center horizontally if near full width
                if let screen = NSScreen.main {
                    let screenFrame = screen.visibleFrame
                    // If window is close to screen width, center it horizontally
                    if containerWidth >= screenFrame.width * 0.9 {
                        newX = screenFrame.minX + (screenFrame.width - containerWidth) / 2
                    } else {
                        newX = max(screenFrame.minX, min(newX, screenFrame.maxX - containerWidth))
                    }
                    newY = max(screenFrame.minY, min(newY, screenFrame.maxY - containerHeight))
                }

                window.setFrame(NSRect(x: newX, y: newY, width: containerWidth, height: containerHeight), display: true)
            }

            // Update popupmenu window: resize based on new content dimensions
            if gridId == ZonvieCore.popupmenuGridId,
               let window = self.externalWindows[gridId],
               let mainView = self.terminalView {

                let renderer = mainView.renderer!
                let cellW = CGFloat(renderer.cellWidthPx)
                let cellH = CGFloat(renderer.cellHeightPx)
                let scale = mainView.window?.backingScaleFactor ?? 1.0

                let contentWidth = CGFloat(cols) * cellW / scale
                let contentHeight = CGFloat(rows) * cellH / scale

                // Update gridView frame
                if let gridView = self.externalGridViews[gridId] {
                    gridView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
                }

                // Update window size while keeping top-left position
                // (popupmenu should stay anchored near the cursor)
                let oldFrame = window.frame
                let newX = oldFrame.origin.x
                // Keep top position (macOS coordinate: origin.y + height = top)
                let oldTop = oldFrame.origin.y + oldFrame.height
                let newY = oldTop - contentHeight

                window.setFrame(NSRect(x: newX, y: newY, width: contentWidth, height: contentHeight), display: true)
                ZonvieCore.appLog("[external_vertices] popupmenu resized: width=\(contentWidth) height=\(contentHeight)")
            }

            // Update msg_show/msg_history window: resize based on new content dimensions
            let isMsgWindow = (gridId == ZonvieCore.messageGridId || gridId == ZonvieCore.msgHistoryGridId)
            if isMsgWindow,
               let window = self.externalWindows[gridId],
               let mainView = self.terminalView,
               let containerView = window.contentView {

                let renderer = mainView.renderer!
                let cellW = CGFloat(renderer.cellWidthPx)
                let cellH = CGFloat(renderer.cellHeightPx)
                let scale = mainView.window?.backingScaleFactor ?? 1.0

                let msgPadding: CGFloat = 8.0

                let contentWidth = CGFloat(cols) * cellW / scale
                let contentHeight = CGFloat(rows) * cellH / scale

                let containerWidth = contentWidth + (msgPadding * 2)
                let containerHeight = contentHeight + (msgPadding * 2)

                // Update gridView frame inside containerView (centered with padding)
                if let gridView = self.externalGridViews[gridId] {
                    gridView.frame = NSRect(x: msgPadding, y: msgPadding, width: contentWidth, height: contentHeight)
                }

                // Update containerView frame (fills window)
                containerView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight)

                // Update window size and position
                let targetFrame = self.getExtFloatTargetFrame()
                let newX = targetFrame.maxX - containerWidth - 10
                var newY = targetFrame.maxY - containerHeight - 10

                // If this is msg_show and msg_history exists, position below it
                if gridId == ZonvieCore.messageGridId {
                    if let msgHistoryWindow = self.externalWindows[ZonvieCore.msgHistoryGridId] {
                        let historyFrame = msgHistoryWindow.frame
                        newY = historyFrame.origin.y - containerHeight - 4  // 4px gap below history
                    }
                }

                window.setFrame(NSRect(x: newX, y: newY, width: containerWidth, height: containerHeight), display: true)
                let gridType = gridId == ZonvieCore.messageGridId ? "msg_show" : "msg_history"
                ZonvieCore.appLog("[external_vertices] \(gridType) resized: width=\(containerWidth) height=\(containerHeight) y=\(newY)")

                // If this is msg_history and msg_show exists, reposition msg_show below it
                if gridId == ZonvieCore.msgHistoryGridId {
                    if let msgShowWindow = self.externalWindows[ZonvieCore.messageGridId] {
                        let msgShowFrame = msgShowWindow.frame
                        let msgShowX = targetFrame.maxX - msgShowFrame.width - 10
                        let msgShowY = newY - msgShowFrame.height - 4  // 4px gap below history
                        msgShowWindow.setFrame(NSRect(x: msgShowX, y: msgShowY, width: msgShowFrame.width, height: msgShowFrame.height), display: true)
                        ZonvieCore.appLog("[external_vertices] repositioned msg_show below msg_history: y=\(msgShowY)")
                    }
                }
            }

            vertexDataCopy.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress else { return }
                gridView.submitVertices(
                    ptr: ptr,
                    count: vertCount,
                    rows: rows,
                    cols: cols
                )
            }
            gridView.requestRedraw()
        }
    }

    /// Called when cursor moves to a different grid.
    /// Activates the window containing that grid.
    /// With ext_multigrid, grid_id=1 is just a container - actual content is on sub-grids.
    /// So we check if the grid is in externalWindows; if not, it's in the main window.
    private func onCursorGridChanged(gridId: Int64) {
        ZonvieCore.appLog("[cursor_grid_changed] gridId=\(gridId)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Cancel any pending main window activation
            self.mainWindowActivationWorkItem?.cancel()
            self.mainWindowActivationWorkItem = nil

            // Check if this is actually a grid change
            let lastGrid = self.lastCursorGrid
            let isGridChange = (lastGrid != gridId)

            // Update last cursor grid
            self.lastCursorGrid = gridId

            // Only activate windows on actual grid changes
            if !isGridChange {
                ZonvieCore.appLog("[cursor_grid_changed] cursor stayed on same gridId=\(gridId), no activation change")
                return
            }

            // Check if this grid is an external window
            if let extWindow = self.externalWindows[gridId] {
                // Cursor moved to external grid - activate that window
                extWindow.makeKeyAndOrderFront(nil)
                // Ensure gridView is first responder for key events
                if let gridView = self.externalGridViews[gridId] {
                    extWindow.makeFirstResponder(gridView)
                }
                ZonvieCore.appLog("[cursor_grid_changed] activated external window for gridId=\(gridId)")
            } else {
                // Cursor moved to main grid - activate main window
                if let mainWindow = self.terminalView?.window {
                    mainWindow.makeKeyAndOrderFront(nil)
                    ZonvieCore.appLog("[cursor_grid_changed] activated main window (cursor on gridId=\(gridId))")
                }
            }
        }
    }

    // MARK: - Highlight helpers

    /// Get the Search highlight color (background) for cmdline border.
    private func getSearchHighlightColor() -> NSColor {
        guard let corePtr = self.core else {
            return NSColor.yellow  // Fallback
        }

        var fg: UInt32 = 0
        var bg: UInt32 = 0
        let found = zonvie_core_get_hl_by_name(corePtr, "Search", &fg, &bg)

        if found != 0 {
            // Use background color from Search highlight
            let r = CGFloat((bg >> 16) & 0xFF) / 255.0
            let g = CGFloat((bg >> 8) & 0xFF) / 255.0
            let b = CGFloat(bg & 0xFF) / 255.0
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        } else {
            // Fallback to yellow if Search not defined
            return NSColor.yellow
        }
    }

    /// Get the Normal highlight background color for message window.
    private func getNormalBackgroundColor() -> NSColor {
        guard let corePtr = self.core else {
            return NSColor.black  // Fallback
        }

        var fg: UInt32 = 0
        var bg: UInt32 = 0
        let found = zonvie_core_get_hl_by_name(corePtr, "Normal", &fg, &bg)

        if found != 0 && bg != 0 {
            // Use background color from Normal highlight
            let r = CGFloat((bg >> 16) & 0xFF) / 255.0
            let g = CGFloat((bg >> 8) & 0xFF) / 255.0
            let b = CGFloat(bg & 0xFF) / 255.0
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        } else {
            // Fallback to dark gray if Normal not defined
            return NSColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
        }
    }

    /// Get the Normal highlight foreground color for message text.
    private func getNormalForegroundColor() -> NSColor {
        guard let corePtr = self.core else {
            return NSColor.white  // Fallback
        }

        var fg: UInt32 = 0
        var bg: UInt32 = 0
        let found = zonvie_core_get_hl_by_name(corePtr, "Normal", &fg, &bg)

        if found != 0 && fg != 0 {
            // Use foreground color from Normal highlight
            let r = CGFloat((fg >> 16) & 0xFF) / 255.0
            let g = CGFloat((fg >> 8) & 0xFF) / 255.0
            let b = CGFloat(fg & 0xFF) / 255.0
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        } else {
            // Fallback to white if Normal not defined
            return NSColor.white
        }
    }

    /// Get the Comment highlight color (foreground) for cmdline icon.
    private func getCommentHighlightColor() -> NSColor {
        guard let corePtr = self.core else {
            return NSColor.gray  // Fallback
        }

        var fg: UInt32 = 0
        var bg: UInt32 = 0
        let found = zonvie_core_get_hl_by_name(corePtr, "Comment", &fg, &bg)

        if found != 0 {
            // Use foreground color from Comment highlight
            let r = CGFloat((fg >> 16) & 0xFF) / 255.0
            let g = CGFloat((fg >> 8) & 0xFF) / 255.0
            let b = CGFloat(fg & 0xFF) / 255.0
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        } else {
            // Fallback to gray if Comment not defined
            return NSColor.gray
        }
    }

    // MARK: - ext_cmdline callbacks

    private func onCmdlineShow(
        content: UnsafePointer<zonvie_cmdline_chunk>?,
        contentCount: Int,
        pos: UInt32,
        firstc: UInt8,
        prompt: UnsafePointer<UInt8>?,
        promptLen: Int,
        indent: UInt32,
        level: UInt32,
        promptHlId: UInt32
    ) {
        // Build content string for logging
        var contentStr = ""
        if let content = content, contentCount > 0 {
            for i in 0..<contentCount {
                let chunk = content[i]
                if let textPtr = chunk.text {
                    let text = String(bytes: UnsafeBufferPointer(start: textPtr, count: chunk.text_len), encoding: .utf8) ?? ""
                    contentStr += text
                }
            }
        }

        let promptStr: String
        if let prompt = prompt, promptLen > 0 {
            promptStr = String(bytes: UnsafeBufferPointer(start: prompt, count: promptLen), encoding: .utf8) ?? ""
        } else {
            promptStr = ""
        }

        let firstcChar = firstc > 0 ? String(UnicodeScalar(firstc)) : ""
        ZonvieCore.appLog("[cmdline_show] level=\(level) firstc='\(firstcChar)'(\(firstc)) prompt='\(promptStr)' pos=\(pos) content='\(contentStr)'")

        // Defer cmdlineFirstc write to main thread to avoid data race
        // (this callback runs on the Zig RPC thread).
        let capturedFirstc = firstc
        ZonvieCore.appLog("[cmdline_show] set cmdlineFirstc=\(firstc)")

        // Update icon if window already exists
        DispatchQueue.main.async { [weak self] in
            self?.cmdlineFirstc = capturedFirstc
            self?.updateCmdlineIcon(firstc: capturedFirstc)
        }
    }

    private func onCmdlineHide(level: UInt32) {
        ZonvieCore.appLog("[cmdline_hide] level=\(level)")
        // Defer cmdlineFirstc write to main thread to avoid data race
        // (this callback runs on the Zig RPC thread).
        DispatchQueue.main.async { [weak self] in
            self?.cmdlineFirstc = 0
        }
    }

    /// Updates the cmdline icon based on firstc character
    /// - Parameter firstc: The firstc character (optional, uses self.cmdlineFirstc if nil)
    private func updateCmdlineIcon(firstc: UInt8? = nil) {
        guard let iconView = self.cmdlineIconView else {
            ZonvieCore.appLog("[cmdline_icon] iconView is nil, skipping")
            return
        }

        let fc = firstc ?? self.cmdlineFirstc
        let symbolName: String

        switch fc {
        case UInt8(ascii: "/"), UInt8(ascii: "?"):
            // Search mode: magnifying glass icon
            symbolName = "magnifyingglass"
        case UInt8(ascii: ":"):
            // Command mode: terminal/chevron icon
            symbolName = "chevron.right"
        default:
            // Other modes: default icon
            symbolName = "chevron.right"
        }

        // Use Comment highlight color for all icons
        let tintColor = self.getCommentHighlightColor()

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            // Use hierarchical color configuration for proper tinting
            let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: tintColor)
            let combinedConfig = sizeConfig.applying(colorConfig)
            iconView.image = image.withSymbolConfiguration(combinedConfig)
        }

        ZonvieCore.appLog("[cmdline_icon] updated to '\(symbolName)' for firstc=\(fc)")
    }

    private func onCmdlinePos(pos: UInt32, level: UInt32) {
        ZonvieCore.appLog("[cmdline_pos] pos=\(pos) level=\(level)")
        // TODO: Implement cmdline cursor position update
    }

    private func onCmdlineSpecialChar(c: UnsafePointer<UInt8>?, cLen: Int, shift: Bool, level: UInt32) {
        let charStr: String
        if let c = c, cLen > 0 {
            charStr = String(bytes: UnsafeBufferPointer(start: c, count: cLen), encoding: .utf8) ?? ""
        } else {
            charStr = ""
        }
        ZonvieCore.appLog("[cmdline_special_char] c='\(charStr)' shift=\(shift) level=\(level)")

        // TODO: Handle special char display
    }

    private func onCmdlineBlockShow(lines: UnsafePointer<zonvie_cmdline_block_line>?, lineCount: Int) {
        ZonvieCore.appLog("[cmdline_block_show] lineCount=\(lineCount)")

        // TODO: Implement cmdline block UI
    }

    private func onCmdlineBlockAppend(line: UnsafePointer<zonvie_cmdline_chunk>?, chunkCount: Int) {
        ZonvieCore.appLog("[cmdline_block_append] chunkCount=\(chunkCount)")

        // TODO: Implement cmdline block append
    }

    private func onCmdlineBlockHide() {
        ZonvieCore.appLog("[cmdline_block_hide]")

        // TODO: Hide cmdline block
    }

    // MARK: - ext_popupmenu callbacks

    private func onPopupmenuShow(
        items: UnsafePointer<zonvie_popupmenu_item>?,
        itemCount: Int,
        selected: Int32,
        row: Int32,
        col: Int32,
        gridId: Int64
    ) {
        // Log the event (actual display is handled by Neovim's external float window)
        var itemsStr = ""
        if let items = items, itemCount > 0 {
            let maxItems = min(itemCount, 5)
            for i in 0..<maxItems {
                let item = items[i]
                if let wordPtr = item.word {
                    let word = String(bytes: UnsafeBufferPointer(start: wordPtr, count: item.word_len), encoding: .utf8) ?? ""
                    itemsStr += (i > 0 ? ", " : "") + word
                }
            }
            if itemCount > maxItems {
                itemsStr += "... (\(itemCount) total)"
            }
        }
        ZonvieCore.appLog("[popupmenu_show] items=[\(itemsStr)] selected=\(selected) pos=(\(row),\(col)) grid=\(gridId)")

        // Track anchor grid and cancel pending main window activation on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.popupmenuAnchorGrid = gridId

            // Cancel any pending main window activation if popupmenu is anchored to external window
            if self.externalWindows[gridId] != nil {
                self.cancelMainWindowActivation = true  // Set flag to cancel
                self.mainWindowActivationWorkItem?.cancel()
                self.mainWindowActivationWorkItem = nil
                ZonvieCore.appLog("[popupmenu] cancelled main window activation (anchor on ext grid \(gridId))")
            }
            ZonvieCore.appLog("[popupmenu] anchor_grid set to \(gridId)")
        }
    }

    private func onPopupmenuHide() {
        ZonvieCore.appLog("[popupmenu_hide]")
        DispatchQueue.main.async { [weak self] in
            self?.popupmenuAnchorGrid = nil
            ZonvieCore.appLog("[popupmenu] anchor_grid cleared")
        }
    }

    private func onPopupmenuSelect(selected: Int32) {
        ZonvieCore.appLog("[popupmenu_select] selected=\(selected)")
    }

    // MARK: - OS Notification (UserNotifications)

    /// Shared delegate instance for foreground notification display
    private static let notificationDelegate = NotificationDelegate()

    /// Request notification permission (call on app launch)
    static func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        // Set delegate to allow foreground notification display
        center.delegate = notificationDelegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                ZonvieCore.appLog("[notification] permission error: \(error)")
            } else {
                ZonvieCore.appLog("[notification] permission granted: \(granted)")
            }
        }
    }

    /// Show OS notification
    private func showOSNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Immediate delivery
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                ZonvieCore.appLog("[notification] failed to show: \(error)")
            } else {
                ZonvieCore.appLog("[notification] shown: title='\(title)' body='\(body)'")
            }
        }
    }

    // MARK: - ext_messages callbacks

    private func onMsgShow(
        view: zonvie_msg_view_type,
        kind: UnsafePointer<CChar>?,
        kindLen: Int,
        chunks: UnsafePointer<zonvie_msg_chunk>?,
        chunkCount: Int,
        replaceLast: Int32,
        history: Int32,
        append: Int32,
        msgId: Int64,
        timeoutMs: UInt32
    ) {
        // Build kind string
        let kindStr: String
        if let kind = kind, kindLen > 0 {
            kindStr = String(cString: kind).prefix(kindLen).description
        } else {
            kindStr = ""
        }

        // Build content and extract highlight info from chunks
        var contentStr = ""
        var primaryHlId: Int32 = 0  // Use first chunk's hl_id for color
        if let chunks = chunks, chunkCount > 0 {
            for i in 0..<chunkCount {
                let chunk = chunks[i]
                if i == 0 {
                    primaryHlId = Int32(bitPattern: chunk.hl_id)
                }
                if let textPtr = chunk.text, chunk.text_len > 0 {
                    let text = String(bytes: UnsafeBufferPointer(start: textPtr, count: chunk.text_len), encoding: .utf8) ?? ""
                    contentStr += text
                }
            }
        }

        // Convert timeout from milliseconds to seconds
        let timeoutSec = Double(timeoutMs) / 1000.0

        ZonvieCore.appLog("[msg_show] view=\(view.rawValue) kind='\(kindStr)' content='\(contentStr)' hl_id=\(primaryHlId) replaceLast=\(replaceLast) history=\(history) append=\(append) msgId=\(msgId) timeoutMs=\(timeoutMs)")

        // Use view type passed from Zig (already routed)
        let isConfirmView = view == ZONVIE_MSG_VIEW_CONFIRM
        let isMini = view == ZONVIE_MSG_VIEW_MINI
        let isNone = view == ZONVIE_MSG_VIEW_NONE
        let isNotification = view == ZONVIE_MSG_VIEW_NOTIFICATION

        ZonvieCore.appLog("[msg_show] view check: rawValue=\(view.rawValue) isNotification=\(isNotification) ZONVIE_MSG_VIEW_NOTIFICATION=\(ZONVIE_MSG_VIEW_NOTIFICATION.rawValue)")

        // Create or update message window on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Skip if routed to 'none'
            if isNone {
                return
            }

            if isNotification {
                // OS notification via UserNotifications
                ZonvieCore.appLog("[msg_show] calling showOSNotification")
                self.showOSNotification(title: "Neovim", body: contentStr)
            } else if isConfirmView {
                // Confirm messages go to separate bottom-center window
                let isConfirm = kindStr == "confirm" || kindStr == "confirm_sub"
                let isReturnPrompt = kindStr == "return_prompt"
                self.showPromptWindow(content: contentStr, hlId: primaryHlId, isConfirm: isConfirm, isReturnPrompt: isReturnPrompt)
            } else if isMini {
                // Mini messages go to bottom-right mini popup (use timeout from Zig)
                self.updateMini(.custom, content: contentStr, timeout: timeoutSec)
            } else {
                // Handle message replacement and appending for regular messages (ext_float)
                let shouldReplace = replaceLast != 0
                let shouldAppend = append != 0

                if shouldReplace {
                    // Replace mode: clear all pending and show only current
                    self.pendingMessages.removeAll()
                    self.pendingMessages.append((kind: kindStr, content: contentStr, hlId: primaryHlId))
                } else if shouldAppend && !self.pendingMessages.isEmpty {
                    // Append to last message content
                    let last = self.pendingMessages.removeLast()
                    self.pendingMessages.append((kind: last.kind, content: last.content + contentStr, hlId: last.hlId))
                } else {
                    // New message - add to stack (but limit to reasonable size)
                    self.pendingMessages.append((kind: kindStr, content: contentStr, hlId: primaryHlId))
                    if self.pendingMessages.count > 5 {
                        self.pendingMessages.removeFirst()
                    }
                }

                // Build display content from all pending messages
                let displayContent = self.pendingMessages.map { $0.content }.joined(separator: "\n")
                let displayKind = self.pendingMessages.last?.kind ?? kindStr
                let displayHlId = self.pendingMessages.last?.hlId ?? primaryHlId

                self.showMessageWindow(kind: displayKind, content: displayContent, hlId: displayHlId)
            }
        }
    }

    private func onMsgClear() {
        ZonvieCore.appLog("[msg_clear]")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingMessages.removeAll()
            self.hideMessageWindow()
            self.hidePromptWindow()
        }
    }

    private func onMsgShowmode(
        view: zonvie_msg_view_type,
        chunks: UnsafePointer<zonvie_msg_chunk>?,
        chunkCount: Int
    ) {
        var contentStr = ""
        if let chunks = chunks, chunkCount > 0 {
            for i in 0..<chunkCount {
                let chunk = chunks[i]
                if let textPtr = chunk.text, chunk.text_len > 0 {
                    let text = String(bytes: UnsafeBufferPointer(start: textPtr, count: chunk.text_len), encoding: .utf8) ?? ""
                    contentStr += text
                }
            }
        }

        ZonvieCore.appLog("[msg_showmode] content='\(contentStr)' view=\(view.rawValue)")

        // Check if view is none
        if view == ZONVIE_MSG_VIEW_NONE {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch view {
            case ZONVIE_MSG_VIEW_MINI:
                self.updateMini(.showmode, content: contentStr)
            case ZONVIE_MSG_VIEW_EXT_FLOAT:
                // ext_float for showmode: show in message window
                self.showMessageWindow(kind: "showmode", content: contentStr)
            case ZONVIE_MSG_VIEW_NOTIFICATION:
                // OS notification for showmode
                self.showOSNotification(title: "Neovim", body: contentStr)
            default:
                // Fallback to mini for other views
                self.updateMini(.showmode, content: contentStr)
            }
        }
    }

    private func onMsgShowcmd(
        view: zonvie_msg_view_type,
        chunks: UnsafePointer<zonvie_msg_chunk>?,
        chunkCount: Int
    ) {
        var contentStr = ""
        if let chunks = chunks, chunkCount > 0 {
            for i in 0..<chunkCount {
                let chunk = chunks[i]
                if let textPtr = chunk.text, chunk.text_len > 0 {
                    let text = String(bytes: UnsafeBufferPointer(start: textPtr, count: chunk.text_len), encoding: .utf8) ?? ""
                    contentStr += text
                }
            }
        }

        ZonvieCore.appLog("[msg_showcmd] content='\(contentStr)' view=\(view.rawValue)")

        // Check if view is none
        if view == ZONVIE_MSG_VIEW_NONE {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch view {
            case ZONVIE_MSG_VIEW_MINI:
                self.updateMini(.showcmd, content: contentStr)
            case ZONVIE_MSG_VIEW_EXT_FLOAT:
                // ext_float for showcmd: show in message window
                self.showMessageWindow(kind: "showcmd", content: contentStr)
            case ZONVIE_MSG_VIEW_NOTIFICATION:
                // OS notification for showcmd
                self.showOSNotification(title: "Neovim", body: contentStr)
            default:
                // Fallback to mini for other views
                self.updateMini(.showcmd, content: contentStr)
            }
        }
    }

    private func onMsgRuler(
        view: zonvie_msg_view_type,
        chunks: UnsafePointer<zonvie_msg_chunk>?,
        chunkCount: Int
    ) {
        var contentStr = ""
        if let chunks = chunks, chunkCount > 0 {
            for i in 0..<chunkCount {
                let chunk = chunks[i]
                if let textPtr = chunk.text, chunk.text_len > 0 {
                    let text = String(bytes: UnsafeBufferPointer(start: textPtr, count: chunk.text_len), encoding: .utf8) ?? ""
                    contentStr += text
                }
            }
        }

        ZonvieCore.appLog("[msg_ruler] content='\(contentStr)' view=\(view.rawValue)")

        // Check if view is none
        if view == ZONVIE_MSG_VIEW_NONE {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch view {
            case ZONVIE_MSG_VIEW_MINI:
                self.updateMini(.ruler, content: contentStr)
            case ZONVIE_MSG_VIEW_EXT_FLOAT:
                // ext_float for ruler: show in message window
                self.showMessageWindow(kind: "ruler", content: contentStr)
            case ZONVIE_MSG_VIEW_NOTIFICATION:
                // OS notification for ruler
                self.showOSNotification(title: "Neovim", body: contentStr)
            default:
                // Fallback to mini for other views
                self.updateMini(.ruler, content: contentStr)
            }
        }
    }

    private func onMsgHistoryShow(
        entries: UnsafePointer<zonvie_msg_history_entry>?,
        entryCount: Int,
        prevCmd: Int32
    ) {
        guard let entries = entries, entryCount > 0 else {
            ZonvieCore.appLog("[msg_history_show] empty entries")
            return
        }

        // Build content from all entries
        var fullContent = ""
        for i in 0..<entryCount {
            let entry = entries[i]
            var entryText = ""

            if let chunks = entry.chunks, entry.chunk_count > 0 {
                for j in 0..<Int(entry.chunk_count) {
                    let chunk = chunks[j]
                    if let textPtr = chunk.text, chunk.text_len > 0 {
                        let text = String(bytes: UnsafeBufferPointer(start: textPtr, count: chunk.text_len), encoding: .utf8) ?? ""
                        entryText += text
                    }
                }
            }

            if !entryText.isEmpty {
                if !fullContent.isEmpty {
                    fullContent += "\n"
                }
                fullContent += entryText
            }
        }

        ZonvieCore.appLog("[msg_history_show] entries=\(entryCount) prev_cmd=\(prevCmd) content_len=\(fullContent.count)")

        // Display on main thread using long message split view
        DispatchQueue.main.async { [weak self] in
            self?.showMessageHistoryWindow(content: fullContent, prevCmd: prevCmd != 0)
        }
    }

    private func showMessageHistoryWindow(content: String, prevCmd: Bool) {
        guard let mainView = self.terminalView,
              let renderer = mainView.renderer else {
            return
        }

        let cellH = CGFloat(renderer.cellHeightPx)
        let scale = mainView.window?.backingScaleFactor ?? 1.0
        let fontSize = max(12.0, cellH / scale * 0.8)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        let lineCount = content.components(separatedBy: "\n").count
        let fgColor = self.getNormalForegroundColor()
        let bgColor = self.getNormalBackgroundColor().withAlphaComponent(0.95)
        let borderColor = NSColor.gray.withAlphaComponent(0.5)
        let targetFrame = getExtFloatTargetFrame()
        let padding: CGFloat = 10

        // Reuse long message window for scrollable content
        showLongMessageWindow(
            content: content,
            font: font,
            fgColor: fgColor,
            bgColor: bgColor,
            borderColor: borderColor,
            padding: padding,
            targetFrame: targetFrame,
            lineCount: lineCount
        )
    }

    // MARK: - Mini View Display

    /// Update a mini window with new content
    /// - Parameters:
    ///   - miniId: The mini window identifier
    ///   - content: The content to display
    ///   - timeout: Optional timeout in seconds (nil = use default, 0 = no auto-hide)
    private func updateMini(_ miniId: MiniWindowId, content: String, timeout: Double? = nil) {
        guard let mainWindow = terminalView?.window else { return }

        // Cancel any existing hide timer for this mini window
        miniWindows[miniId]?.hideWorkItem?.cancel()
        miniWindows[miniId]?.hideWorkItem = nil

        if content.isEmpty {
            // Hide and clear this mini
            if let state = miniWindows[miniId] {
                state.window?.orderOut(nil)
            }
            miniWindows[miniId]?.content = ""
            updateMiniPositions()
            return
        }

        let normalFg = getNormalForegroundColor()
        let normalBg = getNormalBackgroundColor()

        if var state = miniWindows[miniId], let window = state.window, let label = state.label {
            // Update existing window
            state.content = content
            label.stringValue = content
            label.textColor = normalFg
            miniWindows[miniId] = state

            // Update background color
            if let containerView = window.contentView {
                if ZonvieConfig.shared.blurEnabled {
                    let opacity = ZonvieConfig.shared.backgroundAlpha
                    containerView.layer?.backgroundColor = normalBg.withAlphaComponent(CGFloat(opacity) * 0.8).cgColor
                } else {
                    containerView.layer?.backgroundColor = normalBg.withAlphaComponent(0.9).cgColor
                }
            }

            // Resize to fit content (max width = parent window width)
            let font = label.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let textWidth = (content as NSString).size(withAttributes: [.font: font]).width + 16
            let maxWidth = mainWindow.frame.width
            var frame = window.frame
            frame.size.width = min(max(textWidth, 50), maxWidth)
            window.setFrame(frame, display: true)

            // Ensure left alignment
            label.alignment = .left
        } else {
            // Create new mini window
            let state = createMiniWindow(for: miniId, content: content, mainWindow: mainWindow, fgColor: normalFg, bgColor: normalBg)
            miniWindows[miniId] = state
        }

        updateMiniPositions()
        miniWindows[miniId]?.window?.orderFront(nil)

        // Set up auto-hide timer if timeout is specified and > 0
        if let timeout = timeout, timeout > 0 {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Hide this mini window
                self.miniWindows[miniId]?.window?.orderOut(nil)
                self.miniWindows[miniId]?.content = ""
                self.miniWindows[miniId]?.hideWorkItem = nil
                self.updateMiniPositions()
            }
            miniWindows[miniId]?.hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
        }
    }

    /// Create a single mini window
    private func createMiniWindow(
        for miniId: MiniWindowId,
        content: String,
        mainWindow: NSWindow,
        fgColor: NSColor,
        bgColor: NSColor
    ) -> MiniWindowState {
        let scale = mainWindow.backingScaleFactor
        let cellHeightPt: CGFloat
        if let renderer = terminalView?.renderer {
            cellHeightPt = CGFloat(renderer.cellHeightPx) / scale
        } else {
            cellHeightPt = 18
        }

        // Font size based on cell height
        let fontSize = max(11, cellHeightPt * 0.75)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Calculate content width (max = parent window width)
        let textWidth = (content as NSString).size(withAttributes: [.font: font]).width + 16
        let maxWidth = mainWindow.frame.width
        let windowWidth = min(max(textWidth, 50), maxWidth)

        // Window height = exactly 1 cell height (no margin)
        let windowRect = NSRect(x: 0, y: 0, width: windowWidth, height: cellHeightPt)

        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.hasShadow = false
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = true
        window.ignoresMouseEvents = true

        // Container with background
        let containerView = NSView(frame: NSRect(origin: .zero, size: windowRect.size))
        containerView.wantsLayer = true

        if ZonvieConfig.shared.blurEnabled {
            let opacity = ZonvieConfig.shared.backgroundAlpha
            containerView.layer?.backgroundColor = bgColor.withAlphaComponent(CGFloat(opacity) * 0.8).cgColor
        } else {
            containerView.layer?.backgroundColor = bgColor.withAlphaComponent(0.9).cgColor
        }

        // Label (left-aligned in window)
        let label = NSTextField(labelWithString: content)
        label.font = font
        label.textColor = fgColor
        label.backgroundColor = .clear
        label.isBordered = false
        label.isEditable = false
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
        ])

        window.contentView = containerView

        var state = MiniWindowState()
        state.window = window
        state.label = label
        state.content = content
        return state
    }

    /// Update positions of all visible mini windows (stacking from bottom to top)
    private func updateMiniPositions() {
        guard let mainWindow = terminalView?.window,
              let renderer = terminalView?.renderer else { return }

        let scale = mainWindow.backingScaleFactor
        let cellHeightPx = CGFloat(renderer.cellHeightPx)
        let cellWidthPx = CGFloat(renderer.cellWidthPx)
        let cellHeightPt = cellHeightPx / scale

        let config = ZonvieConfig.shared
        let positionMode = config.messages.miniPos

        // Calculate anchor point (bottom-right of the target area)
        let anchorX: CGFloat  // Screen X coordinate of right edge
        let anchorY: CGFloat  // Screen Y coordinate of bottom edge

        switch positionMode {
        case .display:
            // Display-based: bottom-right of the current screen
            if let screen = mainWindow.screen ?? NSScreen.main {
                let screenFrame = screen.visibleFrame
                anchorX = screenFrame.maxX
                anchorY = screenFrame.minY
            } else {
                // Fallback to main window
                anchorX = mainWindow.frame.maxX
                anchorY = mainWindow.frame.minY
            }

        case .window:
            // Window-based: bottom-right of the window where cursor is
            let cursorPos = getCursorPosition()
            let targetWindow: NSWindow
            if let extWindow = externalWindows[cursorPos.gridId] {
                // Cursor is in an external window
                targetWindow = extWindow
            } else {
                // Cursor is in main window
                targetWindow = mainWindow
            }
            let targetFrame = targetWindow.frame
            let targetContentRect = targetWindow.contentLayoutRect
            anchorX = targetFrame.origin.x + targetContentRect.width
            let contentOriginY = targetFrame.origin.y + (targetFrame.height - targetContentRect.height - targetContentRect.origin.y)
            anchorY = contentOriginY

        case .grid:
            // Grid-based: bottom-right of the grid where cursor is
            let cursorPos = getCursorPosition()
            let cursorGridId = cursorPos.gridId
            let grids = getVisibleGridsCached()
            var targetGrid: GridInfo?

            for grid in grids {
                if grid.gridId == cursorGridId {
                    targetGrid = grid
                    break
                }
            }

            // Fallback to main grid (id=1) if not found
            if targetGrid == nil {
                targetGrid = grids.first { $0.gridId == 1 }
            }

            let mainFrame = mainWindow.frame
            let mainContentRect = mainWindow.contentLayoutRect

            let gridRightPt: CGFloat
            let gridBottomPt: CGFloat
            if let grid = targetGrid {
                gridRightPt = CGFloat(grid.startCol + grid.cols) * (cellWidthPx / scale)
                gridBottomPt = CGFloat(grid.startRow + grid.rows) * (cellHeightPx / scale)
            } else {
                gridRightPt = mainContentRect.width
                gridBottomPt = mainContentRect.height
            }

            anchorX = mainFrame.origin.x + gridRightPt
            let contentOriginY = mainFrame.origin.y + (mainFrame.height - mainContentRect.height - mainContentRect.origin.y)
            anchorY = contentOriginY + (mainContentRect.height - gridBottomPt)
        }

        // Build list of visible minis in stack order
        let visibleMinis = MiniWindowId.allCases.filter { miniWindows[$0]?.isVisible == true }

        // Position each visible mini at bottom-right, stacking upward
        for (stackIndex, miniId) in visibleMinis.enumerated() {
            guard let window = miniWindows[miniId]?.window else { continue }

            let windowWidth = window.frame.width
            let x = anchorX - windowWidth
            let y = anchorY + (CGFloat(stackIndex) * cellHeightPt)

            let newFrame = NSRect(x: x, y: y, width: windowWidth, height: cellHeightPt)
            window.setFrame(newFrame, display: true)
        }
    }

    /// Hide all mini windows
    private func hideAllMinis() {
        for miniId in MiniWindowId.allCases {
            miniWindows[miniId]?.window?.orderOut(nil)
            miniWindows[miniId]?.content = ""
        }
    }

    /// Creates or updates the ext-float window (msg_show) in the top-right corner of the screen
    // Store scroll view and text view for long messages
    private var messageScrollView: NSScrollView?
    private var messageTextView: NSTextView?

    /// Get color for message kind (error=red, warning=yellow, etc.)
    private func getColorForMessageKind(_ kind: String, hlId: Int32) -> NSColor {
        // Check kind for semantic coloring
        switch kind {
        case "emsg", "echoerr", "lua_error", "rpc_error":
            return NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)  // Red for errors
        case "wmsg":
            return NSColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 1.0) // Yellow for warnings
        case "confirm", "confirm_sub", "return_prompt":
            return NSColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 1.0)  // Light blue for prompts
        case "search_count":
            return NSColor(red: 0.6, green: 1.0, blue: 0.6, alpha: 1.0)  // Light green for search
        default:
            // For other kinds, use normal foreground color
            // Note: hl_id based coloring could be added with zonvie_core_get_hl_by_id API
            return self.getNormalForegroundColor()
        }
    }

    /// Get target frame for ext-float positioning based on config
    private func getExtFloatTargetFrame() -> NSRect {
        guard let mainView = self.terminalView,
              let mainWindow = mainView.window,
              let screen = mainWindow.screen ?? NSScreen.main else {
            return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        }

        let config = ZonvieConfig.shared
        let positionMode = config.messages.extFloatPos

        switch positionMode {
        case .display:
            return screen.visibleFrame

        case .window:
            // Window-based: use the window where cursor is
            let cursorPos = getCursorPosition()
            let targetWindow: NSWindow
            if let extWindow = externalWindows[cursorPos.gridId] {
                // Cursor is in an external window
                targetWindow = extWindow
            } else {
                // Cursor is in main window
                targetWindow = mainWindow
            }
            let targetFrame = targetWindow.frame
            let targetContentRect = targetWindow.contentLayoutRect
            let contentOriginY = targetFrame.origin.y + (targetFrame.height - targetContentRect.height - targetContentRect.origin.y)
            return NSRect(
                x: targetFrame.origin.x,
                y: contentOriginY,
                width: targetContentRect.width,
                height: targetContentRect.height
            )

        case .grid:
            guard let renderer = mainView.renderer else {
                return screen.visibleFrame
            }

            let scale = mainWindow.backingScaleFactor
            let cellWidthPx = CGFloat(renderer.cellWidthPx)
            let cellHeightPx = CGFloat(renderer.cellHeightPx)

            let cursorPos = getCursorPosition()
            let cursorGridId = cursorPos.gridId
            let grids = getVisibleGridsCached()
            var targetGrid: GridInfo?

            for grid in grids {
                if grid.gridId == cursorGridId {
                    targetGrid = grid
                    break
                }
            }

            if targetGrid == nil {
                targetGrid = grids.first { $0.gridId == 1 }
            }

            let mainFrame = mainWindow.frame
            let mainContentRect = mainWindow.contentLayoutRect

            if let grid = targetGrid {
                let gridLeftPt = CGFloat(grid.startCol) * (cellWidthPx / scale)
                let gridTopPt = CGFloat(grid.startRow) * (cellHeightPx / scale)
                let gridWidthPt = CGFloat(grid.cols) * (cellWidthPx / scale)
                let gridHeightPt = CGFloat(grid.rows) * (cellHeightPx / scale)

                let contentOriginY = mainFrame.origin.y + (mainFrame.height - mainContentRect.height - mainContentRect.origin.y)
                return NSRect(
                    x: mainFrame.origin.x + gridLeftPt,
                    y: contentOriginY + (mainContentRect.height - gridTopPt - gridHeightPt),
                    width: gridWidthPt,
                    height: gridHeightPt
                )
            } else {
                return screen.visibleFrame
            }
        }
    }

    private func showMessageWindow(kind: String, content: String, hlId: Int32 = 0) {
        guard let mainView = self.terminalView,
              let renderer = mainView.renderer,
              let screen = NSScreen.main else {
            ZonvieCore.appLog("[msg_window] no terminalView, renderer, or screen")
            return
        }

        // Get font size from cell height (approximate)
        let cellH = CGFloat(renderer.cellHeightPx)
        let scale = mainView.window?.backingScaleFactor ?? 1.0
        let fontSize = max(12, (cellH / scale) * 0.85)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Get colors based on message kind and highlight
        let fgColor = getColorForMessageKind(kind, hlId: hlId)
        let normalBg = self.getNormalBackgroundColor()
        let adjustedBg = normalBg.adjustedForCmdlineBackground()
        let borderColor: NSColor

        // Use different border colors for different kinds
        switch kind {
        case "emsg", "echoerr", "lua_error", "rpc_error":
            borderColor = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
        case "wmsg":
            borderColor = NSColor(red: 1.0, green: 0.8, blue: 0.3, alpha: 1.0)
        case "confirm", "confirm_sub", "return_prompt":
            borderColor = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0)
        default:
            borderColor = self.getSearchHighlightColor()
        }

        let padding: CGFloat = 12.0
        let targetFrame = getExtFloatTargetFrame()
        ZonvieCore.appLog("[ext-float] showMessageWindow: targetFrame=\(targetFrame) extFloatPos=\(ZonvieConfig.shared.messages.extFloatPos)")

        // Check if this is a confirm/prompt kind (needs special handling)
        let isPrompt = ["confirm", "confirm_sub", "return_prompt"].contains(kind)

        // Show message in external window (content is already built from pendingMessages by caller)
        showShortMessageWindow(
            content: content,
            font: font,
            fgColor: fgColor,
            bgColor: adjustedBg,
            borderColor: borderColor,
            padding: padding,
            targetFrame: targetFrame,
            isPrompt: isPrompt
        )

        // Start auto-hide timer for external window (but not for prompts)
        messageAutoHideWorkItem?.cancel()
        if !isPrompt {
            let workItem = DispatchWorkItem { [weak self] in
                self?.hideMessageWindow()
            }
            messageAutoHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.messageAutoHideTimeout, execute: workItem)
        }
    }

    private func showShortMessageWindow(
        content: String,
        font: NSFont,
        fgColor: NSColor,
        bgColor: NSColor,
        borderColor: NSColor,
        padding: CGFloat,
        targetFrame: NSRect,
        isPrompt: Bool = false
    ) {
        // Calculate text size (handle multiline)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor
        ]
        let maxWidth = min(targetFrame.width * 0.8, 600.0)
        let constraintRect = CGSize(width: maxWidth - (padding * 2), height: .greatestFiniteMagnitude)
        let boundingBox = content.boundingRect(
            with: constraintRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes,
            context: nil
        )

        let windowWidth = max(100, min(maxWidth, boundingBox.width + (padding * 2) + 10))
        let windowHeight = max(30, boundingBox.height + (padding * 2) + 4)

        // Position: prompts go to bottom center, regular messages to top-right
        let windowX: CGFloat
        let windowY: CGFloat
        if isPrompt {
            windowX = targetFrame.midX - windowWidth / 2
            windowY = targetFrame.minY + 50  // Near bottom
        } else {
            windowX = targetFrame.maxX - windowWidth - 10
            windowY = targetFrame.maxY - windowHeight - 10
        }

        if let window = self.extFloatWindow,
           let containerView = self.messageContainerView,
           let textField = self.messageTextField {
            // Update existing window - switch to short mode if needed
            if self.messageScrollView != nil {
                // Was in long mode, need to recreate
                self.hideMessageWindow()
                showShortMessageWindow(content: content, font: font, fgColor: fgColor, bgColor: bgColor, borderColor: borderColor, padding: padding, targetFrame: targetFrame, isPrompt: isPrompt)
                return
            }

            textField.stringValue = content
            textField.textColor = fgColor
            containerView.layer?.borderColor = borderColor.cgColor

            // Recalculate size for updated content
            let newBoundingBox = content.boundingRect(
                with: constraintRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: textAttributes,
                context: nil
            )
            let newWindowWidth = max(100, min(maxWidth, newBoundingBox.width + (padding * 2) + 10))
            let newWindowHeight = max(30, newBoundingBox.height + (padding * 2) + 4)

            let newWindowX: CGFloat
            let newWindowY: CGFloat
            if isPrompt {
                newWindowX = targetFrame.midX - newWindowWidth / 2
                newWindowY = targetFrame.minY + 50
            } else {
                newWindowX = targetFrame.maxX - newWindowWidth - 10
                newWindowY = targetFrame.maxY - newWindowHeight - 10
            }

            window.setFrame(NSRect(x: newWindowX, y: newWindowY, width: newWindowWidth, height: newWindowHeight), display: true)
            containerView.frame = NSRect(x: 0, y: 0, width: newWindowWidth, height: newWindowHeight)
            textField.frame = NSRect(x: padding, y: padding, width: newWindowWidth - (padding * 2), height: newWindowHeight - (padding * 2))
            window.orderFront(nil)
            ZonvieCore.appLog("[msg_window] updated: '\(content.prefix(50))...' isPrompt=\(isPrompt)")
        } else {
            // Create new short message window
            let windowRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
            let window = NSWindow(
                contentRect: windowRect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.hasShadow = true
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false

            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
            containerView.wantsLayer = true
            containerView.layer?.cornerRadius = 8.0
            containerView.layer?.masksToBounds = true

            if ZonvieConfig.shared.blurEnabled {
                let opacity = ZonvieConfig.shared.backgroundAlpha
                containerView.layer?.backgroundColor = bgColor.withAlphaComponent(CGFloat(opacity)).cgColor
            } else {
                containerView.layer?.backgroundColor = bgColor.cgColor
            }

            containerView.layer?.borderColor = borderColor.cgColor
            // Thicker border for prompts
            containerView.layer?.borderWidth = isPrompt ? 2.0 : 1.0

            let textField = NSTextField(frame: NSRect(x: padding, y: padding, width: windowWidth - (padding * 2), height: windowHeight - (padding * 2)))
            textField.stringValue = content
            textField.font = font
            textField.textColor = fgColor
            textField.backgroundColor = .clear
            textField.isBordered = false
            textField.isEditable = false
            textField.isSelectable = false
            textField.drawsBackground = false
            textField.alignment = .left
            textField.lineBreakMode = .byWordWrapping
            textField.maximumNumberOfLines = 0  // Allow multiline

            containerView.addSubview(textField)
            window.contentView = containerView

            if ZonvieConfig.shared.blurEnabled {
                ZonvieCore.applyWindowBlur(window: window, radius: ZonvieConfig.shared.window.blurRadius)
            }

            window.orderFront(nil)

            self.extFloatWindow = window
            self.messageTextField = textField
            self.messageContainerView = containerView
            self.messageScrollView = nil
            self.messageTextView = nil

            ZonvieCore.appLog("[msg_window] created: '\(content.prefix(50))...' isPrompt=\(isPrompt)")
        }
    }

    private func showLongMessageWindow(
        content: String,
        font: NSFont,
        fgColor: NSColor,
        bgColor: NSColor,
        borderColor: NSColor,
        padding: CGFloat,
        targetFrame: NSRect,
        lineCount: Int
    ) {
        // Calculate window size based on content
        let maxWidth = min(targetFrame.width * 0.5, 600.0)
        let maxHeight = min(targetFrame.height * 0.4, CGFloat(lineCount) * font.pointSize * 1.4 + padding * 2)
        let windowWidth = maxWidth
        let windowHeight = max(100, maxHeight)

        // Position in top-right corner
        let windowX = targetFrame.maxX - windowWidth - 10
        let windowY = targetFrame.maxY - windowHeight - 10

        if let window = self.extFloatWindow,
           let containerView = self.messageContainerView,
           let scrollView = self.messageScrollView,
           let textView = self.messageTextView {
            // Update existing long message window
            textView.string = content
            textView.font = font
            textView.textColor = fgColor

            // Resize window if needed
            let newHeight = max(100, min(targetFrame.height * 0.4, CGFloat(lineCount) * font.pointSize * 1.4 + padding * 2))
            let newWindowY = targetFrame.maxY - newHeight - 10

            window.setFrame(NSRect(x: windowX, y: newWindowY, width: windowWidth, height: newHeight), display: true)
            containerView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: newHeight)
            scrollView.frame = NSRect(x: padding, y: padding, width: windowWidth - padding * 2, height: newHeight - padding * 2)

            window.orderFront(nil)
            ZonvieCore.appLog("[msg_window] updated long: \(lineCount) lines")
        } else {
            // Need to create or recreate window for long mode
            if self.extFloatWindow != nil {
                self.hideMessageWindow()
            }

            let windowRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
            let window = NSWindow(
                contentRect: windowRect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.hasShadow = true
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false

            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
            containerView.wantsLayer = true
            containerView.layer?.cornerRadius = 8.0
            containerView.layer?.masksToBounds = true

            if ZonvieConfig.shared.blurEnabled {
                let opacity = ZonvieConfig.shared.backgroundAlpha
                containerView.layer?.backgroundColor = bgColor.withAlphaComponent(CGFloat(opacity)).cgColor
            } else {
                containerView.layer?.backgroundColor = bgColor.cgColor
            }

            containerView.layer?.borderColor = borderColor.cgColor
            containerView.layer?.borderWidth = 1.0

            // Create scroll view
            let scrollView = NSScrollView(frame: NSRect(x: padding, y: padding, width: windowWidth - padding * 2, height: windowHeight - padding * 2))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false

            // Create text view
            let textView = NSTextView(frame: scrollView.bounds)
            textView.string = content
            textView.font = font
            textView.textColor = fgColor
            textView.backgroundColor = .clear
            textView.drawsBackground = false
            textView.isEditable = false
            textView.isSelectable = true
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)

            scrollView.documentView = textView
            containerView.addSubview(scrollView)
            window.contentView = containerView

            if ZonvieConfig.shared.blurEnabled {
                ZonvieCore.applyWindowBlur(window: window, radius: ZonvieConfig.shared.window.blurRadius)
            }

            window.orderFront(nil)

            self.extFloatWindow = window
            self.messageContainerView = containerView
            self.messageScrollView = scrollView
            self.messageTextView = textView
            self.messageTextField = nil

            ZonvieCore.appLog("[msg_window] created long: \(lineCount) lines")
        }
    }

    /// Hides and cleans up the ext-float window (both external window and split view)
    private func hideMessageWindow() {
        // Cancel any pending auto-hide timer
        messageAutoHideWorkItem?.cancel()
        messageAutoHideWorkItem = nil

        // Hide external window if shown
        if let window = self.extFloatWindow {
            window.orderOut(nil)
            ZonvieCore.appLog("[msg_window] hidden")
        }

        // Note: Do NOT hide split view on msg_clear.
        // Split view should remain visible until user manually closes it (Esc/q/Enter/Space).
        // This matches noice.nvim's long_message_to_split behavior.
    }

    /// Shows prompt window centered in app window (for confirm/return_prompt)
    private func showPromptWindow(content: String, hlId: Int32, isConfirm: Bool, isReturnPrompt: Bool) {
        guard let mainView = self.terminalView,
              let renderer = mainView.renderer,
              let mainWindow = mainView.window else {
            ZonvieCore.appLog("[prompt_window] no terminalView, renderer, or mainWindow")
            return
        }

        // Get font size from cell height
        let cellH = CGFloat(renderer.cellHeightPx)
        let scale = mainWindow.backingScaleFactor
        let fontSize = max(12, (cellH / scale) * 0.85)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Colors
        let fgColor = getColorForMessageKind("return_prompt", hlId: hlId)
        let normalBg = self.getNormalBackgroundColor()
        let adjustedBg = normalBg.adjustedForCmdlineBackground()
        let borderColor = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0)

        let padding: CGFloat = 12.0
        let appFrame = mainWindow.frame

        // For confirm dialogs, use larger max width
        let maxWidth: CGFloat = isConfirm ? min(appFrame.width - 40, 800.0) : min(appFrame.width * 0.8, 600.0)

        // Calculate text size using the appropriate constraint width
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor
        ]

        // For return_prompt with saved size, use saved width for constraint
        let constraintWidth: CGFloat
        if isReturnPrompt && self.savedPromptWidth > 0 {
            constraintWidth = self.savedPromptWidth - (padding * 2)
        } else {
            constraintWidth = maxWidth - (padding * 2)
        }
        let constraintRect = CGSize(width: constraintWidth, height: .greatestFiniteMagnitude)
        let boundingBox = content.boundingRect(
            with: constraintRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes,
            context: nil
        )

        // Determine window size
        let windowWidth: CGFloat
        let windowHeight: CGFloat
        if isReturnPrompt && self.savedPromptWidth > 0 {
            // Preserve size from confirm dialog
            windowWidth = self.savedPromptWidth
            windowHeight = self.savedPromptHeight
            ZonvieCore.appLog("[prompt_window] return_prompt: preserving layout (saved_width=\(windowWidth))")
        } else {
            windowWidth = max(100, min(maxWidth, boundingBox.width + (padding * 2) + 10))
            windowHeight = isConfirm ?
                max(200, min(boundingBox.height + (padding * 2) + 4, appFrame.height - 100)) :
                max(30, boundingBox.height + (padding * 2) + 4)
        }

        // Position centered in app window
        let windowX = appFrame.midX - windowWidth / 2
        let windowY = appFrame.midY - windowHeight / 2

        if let window = self.promptWindow,
           let containerView = self.promptContainerView,
           let textField = self.promptTextField {
            // Update existing prompt window
            textField.stringValue = content
            textField.textColor = fgColor

            if isReturnPrompt && self.savedPromptWidth > 0 {
                // For return_prompt, just update content without resizing
                window.orderFront(nil)
                ZonvieCore.appLog("[prompt_window] updated (preserved): '\(content.prefix(50))...'")
            } else {
                // Recalculate size for new confirm dialog
                let newBoundingBox = content.boundingRect(
                    with: constraintRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: textAttributes,
                    context: nil
                )
                let newWindowWidth = max(100, min(maxWidth, newBoundingBox.width + (padding * 2) + 10))
                let newWindowHeight = isConfirm ?
                    max(200, min(newBoundingBox.height + (padding * 2) + 4, appFrame.height - 100)) :
                    max(30, newBoundingBox.height + (padding * 2) + 4)
                let newWindowX = appFrame.midX - newWindowWidth / 2
                let newWindowY = appFrame.midY - newWindowHeight / 2

                window.setFrame(NSRect(x: newWindowX, y: newWindowY, width: newWindowWidth, height: newWindowHeight), display: true)
                containerView.frame = NSRect(x: 0, y: 0, width: newWindowWidth, height: newWindowHeight)
                textField.frame = NSRect(x: padding, y: padding, width: newWindowWidth - (padding * 2), height: newWindowHeight - (padding * 2))
                window.orderFront(nil)

                // Save layout if this is a confirm dialog
                if isConfirm {
                    self.savedPromptWidth = newWindowWidth
                    self.savedPromptHeight = newWindowHeight
                    self.promptIsConfirm = true
                }

                ZonvieCore.appLog("[prompt_window] updated: '\(content.prefix(50))...'")
            }
        } else {
            // Create new prompt window
            let windowRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
            let window = NSWindow(
                contentRect: windowRect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.hasShadow = true
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = true  // Hide when app loses focus (like ext-cmdline)

            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
            containerView.wantsLayer = true
            containerView.layer?.cornerRadius = 8.0
            containerView.layer?.masksToBounds = true

            if ZonvieConfig.shared.blurEnabled {
                let opacity = ZonvieConfig.shared.backgroundAlpha
                containerView.layer?.backgroundColor = adjustedBg.withAlphaComponent(CGFloat(opacity)).cgColor
            } else {
                containerView.layer?.backgroundColor = adjustedBg.cgColor
            }

            containerView.layer?.borderColor = borderColor.cgColor
            containerView.layer?.borderWidth = 2.0  // Thicker for prompts

            let textField = NSTextField(frame: NSRect(x: padding, y: padding, width: windowWidth - (padding * 2), height: windowHeight - (padding * 2)))
            textField.stringValue = content
            textField.font = font
            textField.textColor = fgColor
            textField.backgroundColor = .clear
            textField.isBordered = false
            textField.isEditable = false
            textField.isSelectable = false
            textField.drawsBackground = false
            textField.alignment = .left
            textField.lineBreakMode = .byWordWrapping
            textField.maximumNumberOfLines = 0

            containerView.addSubview(textField)
            window.contentView = containerView

            if ZonvieConfig.shared.blurEnabled {
                ZonvieCore.applyWindowBlur(window: window, radius: ZonvieConfig.shared.window.blurRadius)
            }

            window.orderFront(nil)

            self.promptWindow = window
            self.promptTextField = textField
            self.promptContainerView = containerView

            // Save layout if this is a confirm dialog
            if isConfirm {
                self.savedPromptWidth = windowWidth
                self.savedPromptHeight = windowHeight
                self.promptIsConfirm = true
            }

            ZonvieCore.appLog("[prompt_window] created: '\(content.prefix(50))...' frame=\(window.frame)")
        }
    }

    /// Hides the prompt window
    private func hidePromptWindow() {
        if let window = self.promptWindow {
            window.orderOut(nil)
            // Reset saved layout
            self.savedPromptWidth = 0
            self.savedPromptHeight = 0
            self.promptIsConfirm = false
            ZonvieCore.appLog("[prompt_window] hidden")
        }
    }

    // MARK: - Clipboard callbacks

    /// Handle clipboard get request from Neovim via RPC.
    /// Called on background thread from Zig core.
    nonisolated private func onClipboardGet(
        register: UnsafePointer<CChar>?,
        outBuf: UnsafeMutablePointer<UInt8>,
        outLen: UnsafeMutablePointer<Int>,
        maxLen: Int
    ) -> Int32 {
        // NSPasteboard must be accessed from main thread
        var content: String?
        DispatchQueue.main.sync {
            content = NSPasteboard.general.string(forType: .string)
        }

        guard let text = content else {
            outLen.pointee = 0
            return 1  // Success with empty content
        }

        // Convert to UTF-8 bytes
        let utf8Data = text.utf8
        let copyLen = min(utf8Data.count, maxLen)

        if copyLen > 0 {
            var bytes = Array(utf8Data)
            memcpy(outBuf, &bytes, copyLen)
        }

        outLen.pointee = copyLen
        return 1
    }

    /// Handle clipboard set request from Neovim via RPC.
    /// Called on background thread from Zig core.
    nonisolated private func onClipboardSet(
        register: UnsafePointer<CChar>?,
        data: UnsafePointer<UInt8>,
        len: Int
    ) -> Int32 {
        guard len > 0 else { return 1 }

        // Convert UTF-8 bytes to String
        let content = String(decoding: UnsafeBufferPointer(start: data, count: len), as: UTF8.self)

        // NSPasteboard must be accessed from main thread
        DispatchQueue.main.sync {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(content, forType: .string)
        }

        return 1
    }

    /// Handle SSH authentication prompt from Zig core.
    /// Shows a password dialog and sends the password to stdin.
    /// Called on background thread from Zig core.
    nonisolated private func onSSHAuthPrompt(prompt: String) {
        ZonvieCore.appLog("[SSH] Password prompt received: \(prompt)")

        // Post notification - observer on main queue will show dialog
        NotificationCenter.default.post(
            name: ZonvieCore.sshAuthNotification,
            object: nil,
            userInfo: ["prompt": prompt]
        )

        ZonvieCore.appLog("[SSH] Returning from callback (notification posted)")
    }

    // MARK: - ext_tabline callbacks

    nonisolated private func onTablineUpdate(
        curtab: Int64,
        tabs: UnsafePointer<zonvie_tab_entry>?,
        tabCount: Int,
        curbuf: Int64,
        buffers: UnsafePointer<zonvie_buffer_entry>?,
        bufferCount: Int
    ) {
        // Parse tabs
        var parsedTabs: [(handle: Int64, name: String)] = []
        if let tabs {
            for i in 0..<tabCount {
                let tab = tabs[i]
                let name: String
                if let namePtr = tab.name, tab.name_len > 0 {
                    name = String(bytes: UnsafeBufferPointer(start: namePtr, count: Int(tab.name_len)), encoding: .utf8) ?? ""
                } else {
                    name = ""
                }
                parsedTabs.append((handle: tab.tab_handle, name: name))
            }
        }

        ZonvieCore.appLog("[Tabline] update: curtab=\(curtab) tabs=\(parsedTabs.count)")

        // Dispatch to main thread via NotificationCenter
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: ZonvieCore.tablineUpdateNotification,
                object: nil,
                userInfo: ["tabs": parsedTabs, "currentTab": curtab]
            )
        }
    }

    nonisolated private func onTablineHide() {
        ZonvieCore.appLog("[Tabline] hide")
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: ZonvieCore.tablineHideNotification,
                object: nil
            )
        }
    }

    // MARK: - Grid scroll callback

    nonisolated private func onGridScroll(gridId: Int64) {
        // Mark grid for scroll offset clearing (thread-safe).
        // The actual clearing happens in processPendingScrollClears() which is called
        // from MetalTerminalRenderer.onPreDraw before each frame is rendered.
        // This ensures scroll offsets are cleared atomically with vertex rendering,
        // preventing double-shift glitches in split windows.
        ZonvieCore.appLog("[on_grid_scroll] gridId=\(gridId)")
        terminalView?.clearScrollOffsetForGrid(gridId)
    }

    // MARK: - IME Off

    /// Switch IME to ASCII-capable input source (turn off Japanese input, etc.)
    static func setIMEOff() {
        // Filter for ASCII-capable keyboard input sources
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsASCIICapable as String: true
        ]

        guard let listUnmanaged = TISCreateInputSourceList(filter as CFDictionary, false) else {
            ZonvieCore.appLog("[IME] Failed to create input source list")
            return
        }
        let list = listUnmanaged.takeRetainedValue()

        guard CFArrayGetCount(list) > 0 else {
            ZonvieCore.appLog("[IME] No ASCII-capable input source found")
            return
        }

        // Get first ASCII-capable input source and select it
        guard let src = CFArrayGetValueAtIndex(list, 0) else {
            ZonvieCore.appLog("[IME] Failed to get input source")
            return
        }

        let inputSource = Unmanaged<TISInputSource>.fromOpaque(src).takeUnretainedValue()
        let result = TISSelectInputSource(inputSource)
        if result == noErr {
            ZonvieCore.appLog("[IME] Switched to ASCII input source")
        } else {
            ZonvieCore.appLog("[IME] Failed to select input source, error=\(result)")
        }
    }

    /// Notification name for tabline update
    static let tablineUpdateNotification = NSNotification.Name("ZonvieTablineUpdate")

    /// Notification name for tabline hide
    static let tablineHideNotification = NSNotification.Name("ZonvieTablineHide")

    /// Notification name for SSH auth prompt
    static let sshAuthNotification = NSNotification.Name("ZonvieSSHAuthPrompt")

    /// SSH notification observer token
    private var sshNotificationObserver: Any?

    /// Setup SSH notification observer
    func setupSSHNotificationObserver() {
        sshNotificationObserver = NotificationCenter.default.addObserver(
            forName: ZonvieCore.sshAuthNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            ZonvieCore.appLog("[SSH] Notification received on main thread")
            let prompt = notification.userInfo?["prompt"] as? String ?? "SSH Password:"
            self?.showSSHPasswordDialog(prompt: prompt)
        }
        ZonvieCore.appLog("[SSH] Notification observer setup complete")
    }

    /// Show SSH password dialog on main thread
    private func showSSHPasswordDialog(prompt: String) {
        ZonvieCore.appLog("[SSH] showSSHPasswordDialog called")

        // Ensure app is active
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "SSH Authentication"
        alert.informativeText = prompt
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        passwordField.placeholderString = "Password"
        alert.accessoryView = passwordField
        alert.window.initialFirstResponder = passwordField

        ZonvieCore.appLog("[SSH] Showing alert...")
        let response = alert.runModal()
        ZonvieCore.appLog("[SSH] Alert response: \(response)")

        if response == .alertFirstButtonReturn {
            let password = passwordField.stringValue + "\n"
            ZonvieCore.appLog("[SSH] Password entered, sending to stdin...")

            if let data = password.data(using: .utf8), let core = self.core {
                data.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                        ZonvieCore.appLog("[SSH] Failed to get password data base address")
                        return
                    }
                    zonvie_core_send_stdin_data(core, base, Int32(data.count))
                }
            }
        } else {
            ZonvieCore.appLog("[SSH] Password dialog cancelled")
            self.stop()
        }
    }
}

// MARK: - NSColor HSV Extension

extension NSColor {
    /// Adjusts brightness for cmdline background visibility.
    /// Dark colors become lighter, light colors become darker.
    func adjustedForCmdlineBackground() -> NSColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        // Convert to HSB (HSV)
        guard let rgbColor = self.usingColorSpace(.sRGB) else { return self }
        rgbColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Adjust brightness: if dark (b < 0.5), lighten; if light, darken
        let adjustedB: CGFloat
        if b < 0.5 {
            // Dark color: increase brightness slightly
            adjustedB = min(b + 0.05, 1.0)
        } else {
            // Light color: decrease brightness slightly
            adjustedB = max(b - 0.05, 0.0)
        }

        return NSColor(hue: h, saturation: s, brightness: adjustedB, alpha: a)
    }
}

// MARK: - Notification Delegate for foreground display

/// Delegate to allow notifications to be shown when app is in foreground
private class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner and play sound even when app is in foreground
        completionHandler([.banner, .sound])
    }
}
