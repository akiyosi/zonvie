import Cocoa
import MetalKit

/// Overlay view that displays a tiled grid of workspace thumbnails.
///
/// The drawing model works like a virtual camera zooming out:
/// - At scale=1.0 the active tile fills the entire view (not shown).
/// - As scale decreases toward 0.0 the virtual canvas zooms out, revealing
///   surrounding tile slots from the edges of the window.
/// - The grid is always maxTiles slots (e.g. 3x3) regardless of how many
///   tiles currently have a core attached.
final class WorkspaceOverlayView: NSView {

    weak var workspaceManager: WorkspaceManager?

    /// Callback invoked when a tile is clicked (index passed).
    var onTileSelected: ((Int) -> Void)?

    /// Callback invoked when the "+" button on an empty tile is clicked.
    var onNewTileRequested: ((Int) -> Void)?

    /// Callback invoked when the close button on an occupied tile is clicked.
    var onTileCloseRequested: ((Int) -> Void)?

    /// Callback invoked when Esc is pressed to return to the active session.
    var onEscapePressed: (() -> Void)?

    // MARK: - Layout constants

    private let tileSpacing: CGFloat = 12
    private let tileBorderRadius: CGFloat = 8
    private let activeBorderWidth: CGFloat = 3
    private let closeButtonSize: CGFloat = 20
    private let closeButtonMargin: CGFloat = 6

    // MARK: - Hover state

    private var hoveredTileIndex: Int?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }

    // MARK: - Tracking area (mouse hover)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHover = tileIndex(at: point)
        if newHover != hoveredTileIndex {
            hoveredTileIndex = newHover
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredTileIndex != nil {
            hoveredTileIndex = nil
            needsDisplay = true
        }
    }

    // MARK: - Grid geometry

    /// Returns (cols, rows) for the tile grid based on maxTiles.
    private func gridDimensions() -> (cols: Int, rows: Int) {
        guard let wm = workspaceManager else { return (1, 1) }
        let total = wm.maxTiles
        let cols = max(1, Int(ceil(sqrt(Double(total)))))
        let rows = max(1, Int(ceil(Double(total) / Double(cols))))
        return (cols, rows)
    }

    /// Compute tile layout parameters from current state.
    private func tileLayout() -> TileLayout? {
        guard let wm = workspaceManager else { return nil }
        let scale = wm.scale
        let (cols, rows) = gridDimensions()
        let activeIdx = wm.activeTileIndex

        let totalSpacingX = tileSpacing * CGFloat(cols + 1)
        let totalSpacingY = tileSpacing * CGFloat(rows + 1)
        let t = 1.0 - scale
        let gridW_tile = (bounds.width - totalSpacingX) / CGFloat(cols)
        let gridH_tile = (bounds.height - totalSpacingY) / CGFloat(rows)
        let tileW = max(50, bounds.width + (gridW_tile - bounds.width) * t)
        let tileH = max(40, bounds.height + (gridH_tile - bounds.height) * t)

        let gridW = CGFloat(cols) * tileW + totalSpacingX
        let gridH = CGFloat(rows) * tileH + totalSpacingY

        let activeCol = activeIdx % cols
        let activeRow = activeIdx / cols
        let activeCenterX = tileSpacing + CGFloat(activeCol) * (tileW + tileSpacing) + tileW / 2
        let activeCenterY = tileSpacing + CGFloat(activeRow) * (tileH + tileSpacing) + tileH / 2
        let focusX = activeCenterX + (gridW / 2 - activeCenterX) * t
        let focusY = activeCenterY + (gridH / 2 - activeCenterY) * t
        let offsetX = bounds.midX - focusX + panOffset.x
        let offsetY = bounds.midY - focusY + panOffset.y

        return TileLayout(cols: cols, rows: rows, tileW: tileW, tileH: tileH, offsetX: offsetX, offsetY: offsetY)
    }

    private struct TileLayout {
        let cols: Int
        let rows: Int
        let tileW: CGFloat
        let tileH: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat

        func tileRect(for index: Int) -> NSRect {
            let col = index % cols
            let row = index / cols
            let spacing: CGFloat = 12
            let x = offsetX + spacing + CGFloat(col) * (tileW + spacing)
            let y = offsetY + spacing + CGFloat(row) * (tileH + spacing)
            return NSRect(x: x, y: y, width: tileW, height: tileH)
        }
    }

    /// Close button rect for a given tile rect (top-right corner).
    private func closeButtonRect(in tileRect: NSRect) -> NSRect {
        return NSRect(
            x: tileRect.maxX - closeButtonSize - closeButtonMargin,
            y: tileRect.minY + closeButtonMargin,
            width: closeButtonSize,
            height: closeButtonSize
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let wm = workspaceManager else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let layout = tileLayout() else { return }

        let scale = wm.scale
        let activeIdx = wm.activeTileIndex

        // Dark translucent background
        let bgAlpha = min(0.88, (1.0 - scale) * 1.5)
        context.setFillColor(NSColor(white: 0.08, alpha: bgAlpha).cgColor)
        context.fill(bounds)

        // Draw all tile slots
        let totalSlots = layout.cols * layout.rows
        for index in 0..<min(totalSlots, wm.maxTiles) {
            let tileRect = layout.tileRect(for: index)

            // Skip if entirely outside visible bounds (culling)
            if !bounds.intersects(tileRect.insetBy(dx: -20, dy: -20)) {
                continue
            }

            let tile: WorkspaceManager.Tile? = index < wm.tiles.count ? wm.tiles[index] : nil
            let isOccupied = tile?.isOccupied ?? false
            let isSuspended = tile?.isSuspended ?? false

            // Tile background
            let bgColor: NSColor
            if isSuspended {
                bgColor = NSColor(white: 0.15, alpha: 1.0)
            } else if isOccupied {
                bgColor = NSColor(white: 0.18, alpha: 1.0)
            } else {
                bgColor = NSColor(white: 0.10, alpha: 0.7)
            }

            let bgPath = NSBezierPath(roundedRect: tileRect, xRadius: tileBorderRadius, yRadius: tileBorderRadius)
            bgColor.setFill()
            bgPath.fill()

            // Active tile border
            if index == activeIdx {
                NSColor.systemBlue.setStroke()
                bgPath.lineWidth = activeBorderWidth
                bgPath.stroke()
            }

            // Tile content
            if isOccupied, let tile = tile {
                // Use snapshot if available, otherwise try tile renderer's live texture
                let displayTexture: MTLTexture? = tile.snapshot ?? tile.core?.tileRenderer?.texture
                if let tex = displayTexture {
                    drawSnapshotTexture(tex, in: tileRect, context: context)
                } else {
                    // No content yet (connecting or waiting for first frame).
                    let statusText = (index == activeIdx) ? "Active" : "Connecting..."
                    let statusFontSize = max(10, min(16, layout.tileW / 14))
                    let statusAttrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor(white: 0.6, alpha: 1.0),
                        .font: NSFont.systemFont(ofSize: statusFontSize, weight: .regular),
                    ]
                    let statusStr = NSAttributedString(string: statusText, attributes: statusAttrs)
                    let statusSize = statusStr.size()
                    statusStr.draw(in: NSRect(
                        x: tileRect.midX - statusSize.width / 2,
                        y: tileRect.midY - statusSize.height / 2,
                        width: statusSize.width, height: statusSize.height
                    ))
                }

                // Title: prefer tile.title (from nvim set_title), fall back to config name
                let title = tile.title.isEmpty ? tile.config.displayName : tile.title
                let fontSize = max(8, min(13, layout.tileW / 20))
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                ]
                let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
                let titleSize = titleStr.size()
                let titleRect = NSRect(
                    x: tileRect.minX + 6,
                    y: tileRect.maxY - titleSize.height - 4,
                    width: min(titleSize.width, tileRect.width - 12),
                    height: titleSize.height
                )
                titleStr.draw(in: titleRect)

                // Suspend indicator
                if isSuspended {
                    let pauseSize = max(14, layout.tileW / 10)
                    let pauseAttrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.systemYellow,
                        .font: NSFont.systemFont(ofSize: pauseSize),
                    ]
                    let s = NSAttributedString(string: "||", attributes: pauseAttrs)
                    let sz = s.size()
                    s.draw(in: NSRect(
                        x: tileRect.midX - sz.width / 2,
                        y: tileRect.midY - sz.height / 2,
                        width: sz.width, height: sz.height
                    ))
                }

                // Close button (only on hover)
                if hoveredTileIndex == index {
                    drawCloseButton(in: tileRect, context: context)
                }
            } else {
                // Empty slot: "+"
                let plusSize = max(18, min(48, layout.tileW / 6))
                let plusAttrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor(white: 0.45, alpha: 1.0),
                    .font: NSFont.systemFont(ofSize: plusSize, weight: .ultraLight),
                ]
                let s = NSAttributedString(string: "+", attributes: plusAttrs)
                let sz = s.size()
                s.draw(in: NSRect(
                    x: tileRect.midX - sz.width / 2,
                    y: tileRect.midY - sz.height / 2,
                    width: sz.width, height: sz.height
                ))
            }
        }

    }

    /// Draw a close button (circle with X) at the top-right of the tile.
    private func drawCloseButton(in tileRect: NSRect, context: CGContext) {
        let btnRect = closeButtonRect(in: tileRect)

        // Circle background
        context.saveGState()
        let circlePath = CGPath(ellipseIn: btnRect, transform: nil)
        context.addPath(circlePath)
        context.setFillColor(NSColor(white: 0.3, alpha: 0.9).cgColor)
        context.fillPath()

        // X mark
        let inset: CGFloat = 5.5
        let x1 = btnRect.minX + inset
        let y1 = btnRect.minY + inset
        let x2 = btnRect.maxX - inset
        let y2 = btnRect.maxY - inset

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)

        context.move(to: CGPoint(x: x1, y: y1))
        context.addLine(to: CGPoint(x: x2, y: y2))
        context.strokePath()

        context.move(to: CGPoint(x: x2, y: y1))
        context.addLine(to: CGPoint(x: x1, y: y2))
        context.strokePath()

        context.restoreGState()
    }

    /// Draw a Metal texture snapshot into a CGContext rect.
    private func drawSnapshotTexture(_ texture: MTLTexture, in rect: NSRect, context: CGContext) {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        var pixelData = [UInt8](repeating: 0, count: totalBytes)
        texture.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let dataProvider = CGDataProvider(data: Data(pixelData) as CFData) else { return }
        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: dataProvider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        ) else { return }

        let insetRect = rect.insetBy(dx: 4, dy: 16)
        context.saveGState()
        context.translateBy(x: insetRect.minX, y: insetRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: insetRect.width, height: insetRect.height))
        context.restoreGState()
    }

    // MARK: - Keyboard handling

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEscapePressed?()
        }
    }

    // MARK: - Gesture handling

    override func magnify(with event: NSEvent) {
        // Ignore pinch gestures in tile view — user must click a tile to return.
    }

    // Pan offset for two-finger scroll navigation
    var panOffset: CGPoint = .zero

    override func scrollWheel(with event: NSEvent) {
        // Two-finger scroll pans the tile grid
        panOffset.x += event.scrollingDeltaX
        panOffset.y += event.scrollingDeltaY
        needsDisplay = true
    }

    // MARK: - Click & drag handling

    private var dragStart: NSPoint = .zero
    private var panStart: CGPoint = .zero
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        panStart = panOffset
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - dragStart.x
        let dy = current.y - dragStart.y

        // Start dragging after a small threshold to distinguish from clicks
        if !isDragging && (abs(dx) > 3 || abs(dy) > 3) {
            isDragging = true
        }

        if isDragging {
            panOffset = CGPoint(x: panStart.x + dx, y: panStart.y + dy)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            guard let wm = workspaceManager else { return }
            let point = convert(event.locationInWindow, from: nil)
            if let index = tileIndex(at: point) {
                // Check close button hit first (only for occupied tiles on hover)
                if index < wm.tiles.count && wm.tiles[index].isOccupied,
                   hoveredTileIndex == index,
                   let layout = tileLayout() {
                    let tileRect = layout.tileRect(for: index)
                    let btnRect = closeButtonRect(in: tileRect)
                    if btnRect.contains(point) {
                        onTileCloseRequested?(index)
                        return
                    }
                }

                if index < wm.tiles.count && wm.tiles[index].isOccupied {
                    onTileSelected?(index)
                } else {
                    onNewTileRequested?(index)
                }
            }
        }
        isDragging = false
    }

    /// Returns the tile index at the given point, or nil.
    private func tileIndex(at point: NSPoint) -> Int? {
        guard let wm = workspaceManager, let layout = tileLayout() else { return nil }
        let totalSlots = layout.cols * layout.rows
        for index in 0..<min(totalSlots, wm.maxTiles) {
            let tileRect = layout.tileRect(for: index)
            if tileRect.contains(point) {
                return index
            }
        }
        return nil
    }
}
