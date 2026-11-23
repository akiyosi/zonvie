// drag_source — a window that starts a file drag when it is pressed.
//
// A file drop is an AppKit dragging session, and only a real mouseDown can
// begin one; the GUI tests cannot open Finder and aim at one of its icons.
// This is the smallest thing a pointer can pick files up from: the scenario
// presses it, drags to the app under test, and releases.
//
// usage: drag_source <file>...
// Prints "ready" once the window is on screen.

import AppKit

final class SourceView: NSView, NSDraggingSource {
    var urls: [URL] = []

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    // The scenario's first press must start the drag, not just focus the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32),
                                  contents: NSImage(size: NSSize(width: 32, height: 32)))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        dirtyRect.fill()
    }
}

let app = NSApplication.shared
// No Dock icon and no menu bar of its own, but its window can still be pressed.
app.setActivationPolicy(.accessory)

let frame = NSRect(x: 24, y: 24, width: 140, height: 140)
// Normal level: the tests only post events at layer-0 windows.
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
let view = SourceView(frame: NSRect(origin: .zero, size: frame.size))
view.urls = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
window.contentView = view
window.orderFrontRegardless()

print("ready")
fflush(stdout)
app.run()
