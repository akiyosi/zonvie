// Post a genuinely held key into a running app.
//
// run_trace.py drives the scroll from a timer inside nvim, which means the
// app's own key-repeat synthesis never engages and nothing about input timing
// is measurable from it. Holding the key by hand fixes that but needs a
// person. This does it with three events instead:
//
//   1. keyDown                       — the fresh press
//   2. keyDown with autorepeat set   — the app takes over the cadence here
//                                      (MetalTerminalView keys the takeover off
//                                      NSEvent.isARepeat)
//   3. keyUp                         — disarms the synthesis
//
// Everything between 2 and 3 is the app's own repeat synthesis running at its
// production cadence, which is exactly the path the harness could not reach.
//
// Needs Accessibility permission, which macOS attributes to the process
// *responsible* for this one — the GUI app at the top of the process tree, not
// this binary. Without it the events are dropped silently, which looks exactly
// like the app ignoring them, so the check below reports it instead.
//
//   swiftc -O test/perf/holdkey.swift -o tmp/holdkey
//   tmp/holdkey <pid> <keycode> <seconds>     # keycode 38 = 'j'
import Cocoa

let args = CommandLine.arguments
guard args.count >= 4,
      let pid = Int32(args[1]),
      let key = UInt16(args[2]),
      let hold = Double(args[3])
else {
    FileHandle.standardError.write(
        Data("usage: holdkey <pid> <keycode> <seconds>\n".utf8))
    exit(2)
}

func log(_ line: String) {
    FileHandle.standardError.write(Data(("holdkey: " + line + "\n").utf8))
}

// The synthesis disarms itself when the window is not key, so the target has
// to be frontmost for the hold to survive.
if let app = NSRunningApplication(processIdentifier: pid) {
    if #available(macOS 14.0, *) {
        app.activate()
    } else {
        app.activate(options: [.activateIgnoringOtherApps])
    }
} else {
    log("no such process: \(pid)")
    exit(3)
}
Thread.sleep(forTimeInterval: 1.5)

let front = NSWorkspace.shared.frontmostApplication
log("accessibility-trusted=\(AXIsProcessTrusted()) "
  + "frontmost=\(front?.bundleIdentifier ?? front?.localizedName ?? "?") "
  + "pid=\(front?.processIdentifier ?? -1)")
guard AXIsProcessTrusted() else {
    log("no permission — events would be dropped, not posting")
    exit(5)
}

guard let src = CGEventSource(stateID: .hidSystemState) else { exit(4) }

func post(down: Bool, isRepeat: Bool) {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
    else { return }
    e.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
    e.post(tap: .cghidEventTap)
}

post(down: true, isRepeat: false)
// Roughly the system initial delay: the app captures what the first press
// sent and replays that, so the repeat must not arrive before it is recorded.
Thread.sleep(forTimeInterval: 0.35)
post(down: true, isRepeat: true)
Thread.sleep(forTimeInterval: hold)
post(down: false, isRepeat: false)
log("held keycode \(key) on pid \(pid) for \(hold)s")
