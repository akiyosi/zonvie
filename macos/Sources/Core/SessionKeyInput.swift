import AppKit
import CoreVideo

/// The session's keyboard input path: the keyDown every grid view runs, and
/// the key-repeat synthesis whose pacing every surface shares.
///
/// It used to live in the main window's view, so an external window's keys
/// reached Neovim through that view. What stays with each view is the view
/// itself, passed in as the owner: its marked text, input context and window
/// decide composition and when a repeat must stop.
final class SessionKeyInput {
    weak var core: ZonvieCore?

    /// Send committed text to Neovim immediately on the keyDown path, and
    /// keep the main surface's draw loop awake so the response is drawn
    /// promptly.
    /// Why: a prior design buffered repeats in a single-slot `pendingInput`
    /// flushed by displayLink. That added 2-8ms of pre-send latency, which
    /// gave Neovim a window to batch consecutive keystroke responses into
    /// one flush (visible as "0-row frame, then 2-row jump" stutter during
    /// held-`j` scrolling), and silently dropped extras when keys arrived
    /// faster than vsync.
    func sendInputKeepingMainAwake(_ text: String) {
        sendInputForHeldKey(text)
        core?.terminalView?.drawLoopIdleCounter.noteActive()
    }

    /// Send committed text and record it for repeat synthesis. An external
    /// window's grid view sends through here so a key held over it is
    /// replayable by the same synthesizer.
    func sendInputForHeldKey(_ text: String) {
        // Record what a fresh keyDown actually sent, so synthesized repeats
        // can replay exactly the same input (see Key Repeat Synthesis below).
        if keyRepeatCaptureActive {
            keyRepeatCapturedText = text
            keyRepeatCapturedCount += 1
        }
        core?.sendInput(text)
    }

    // MARK: - Key Repeat Synthesis
    //
    // macOS key-repeat delivery is not metronomic: the system repeat timer
    // (and especially Karabiner-Elements' virtual-device path) can drift and
    // beat against the 60Hz display, dropping ~1 repeat/sec and producing a
    // visible scroll hitch (see tmp/ scroll-jank investigation, runs 1-8).
    // Instead of trusting the OS cadence, zonvie uses OS events only as
    // edges: the initial keyDown is processed normally and its outgoing
    // input recorded; the FIRST OS auto-repeat proves the key is repeatable
    // (this also keeps press-and-hold/accent-popup behavior intact, since
    // those keys never produce OS repeats) and hands the cadence over to a
    // synthesizer.
    //
    // EXPERIMENT (decoupled-key-repeat, tmp/project_scroll_jank_investigation
    // Run11-12): the synthesizer used to fire from the draw callback (main
    // thread), tying repeat-send timing to render-loop pacing. That couples
    // the two: a compositor-side stall in nextDrawable() (unavoidable, see
    // Run11) delays the next draw(in:) call and, with it, the next repeat
    // send, one-for-one. A dedicated CVDisplayLink (its own thread, per
    // Apple's docs) now drives send timing instead, so a render stall no
    // longer perturbs input cadence — matching how Neovide's OS-driven
    // (non-synthesized) repeats are unaffected by its own render stalls.
    // draw(in:)'s tick is kept only for the IME/focus safety-disarm check,
    // which must run on the main thread (AppKit calls).
    //
    // sendInput/sendKeyEvent's Zig-core path is safe for this concurrent
    // caller: nextMsgId() is atomic and sendRaw() already serializes through
    // write_queue_mu; only the shared key_buf escape scratch buffer needed a
    // new lock (key_buf_mu, core-side).

    /// What the initial keyDown sent to Neovim; replayed verbatim per repeat.
    private enum HeldKeyAction {
        case text(String)
        case keyEvent(mods: UInt32, characters: String?, charactersIgnoringModifiers: String?)
    }
    // Guards the fields below: written from the main thread (keyDown/keyUp,
    // takeOverKeyRepeat, disarmKeyRepeatSynthesis) and read+partially-written
    // (synthNextFire) from the display-link callback thread.
    private var keyRepeatLock = os_unfair_lock()
    private var heldKeyCode: UInt16? = nil
    private var heldKeyAction: HeldKeyAction? = nil
    /// The view the held key was pressed in. The safety net below must ask
    /// THAT window whether it is still the key window: while an external
    /// window holds focus this one is not, and checking itself would disarm
    /// every repeat the external window starts.
    private weak var heldKeyOwner: KeyRepeatOwner? = nil
    private(set) var synthRepeatActive = false
    /// Bumped by disarmKeyRepeatSynthesis. The display-link tick snapshots it
    /// under the lock and replayHeldKeyOffMain re-validates it immediately
    /// before the send, narrowing (not closing) the window in which a keyUp
    /// still lets one extra keystroke through. The send must stay OUTSIDE the
    /// lock: it reaches Core.sendRawClassified, which polls in 50ms steps
    /// while SSH auth is pending, and the main thread takes this same lock
    /// every frame in tickKeyRepeatSynthesis().
    private var keyRepeatGeneration: UInt64 = 0
    /// CLOCK_UPTIME_RAW seconds of the next synthesized fire.
    private var synthNextFire: Double = 0
    private var synthInterval: Double = 1.0 / 60.0
    // Capture window: set for the duration of a fresh keyDown's processing.
    // Main thread only (only ever read/written from the real keyDown path,
    // never from the display-link repeat path — see replayHeldKeyOffMain).
    private var keyRepeatCaptureActive = false
    private var keyRepeatCapturedText: String? = nil
    private var keyRepeatCapturedCount = 0

    private var repeatDisplayLink: CVDisplayLink? = nil
    /// Extra retain on self held while the display link may still fire;
    /// released in stopRepeatDisplayLink(). See startRepeatDisplayLink().
    private var repeatDisplayLinkContext: Unmanaged<SessionKeyInput>? = nil

    private static func uptimeNow() -> Double {
        return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0
    }

    /// Record the held key after a fresh keyDown was processed.
    private func armHeldKey(owner: KeyRepeatOwner, code: UInt16, action: HeldKeyAction) {
        heldKeyOwner = owner
        heldKeyCode = code
        heldKeyAction = action
    }

    func disarmKeyRepeatSynthesis(_ reason: String) {
        os_unfair_lock_lock(&keyRepeatLock)
        let wasActive = synthRepeatActive
        synthRepeatActive = false
        keyRepeatGeneration &+= 1
        heldKeyCode = nil
        heldKeyAction = nil
        heldKeyOwner = nil
        os_unfair_lock_unlock(&keyRepeatLock)
        if wasActive {
            ZonvieCore.appLogScrollMode("[keyRepeat] disarm (\(reason))")
        }
        stopRepeatDisplayLink()
    }

    /// First OS auto-repeat observed for the held key: take over the cadence.
    private func takeOverKeyRepeat(owner: KeyRepeatOwner) {
        // The repeats are arriving at `owner`, which need not be the view the
        // key was pressed in: focus can move during the ~0.5s before the first
        // one (a cmdline window closing on its own last Backspace, say). The
        // safety net has to follow the view actually receiving them, or it
        // reads the departed window's key status and disarms immediately.
        heldKeyOwner = owner
        // NSEvent.keyRepeatInterval mirrors the user's key-repeat setting.
        // Clamp defensively; 0 would spin and >1s is nonsense for repeats.
        let interval = max(1.0 / 120.0, min(1.0, NSEvent.keyRepeatInterval))
        os_unfair_lock_lock(&keyRepeatLock)
        synthInterval = interval
        synthRepeatActive = true
        synthNextFire = Self.uptimeNow() + interval
        let code = heldKeyCode ?? 0
        os_unfair_lock_unlock(&keyRepeatLock)
        ZonvieCore.appLogScrollMode("[keyRepeat] takeover keyCode=0x\(String(code, radix: 16)) interval_ms=\(String(format: "%.2f", interval * 1000.0))")
        // This OS repeat is replaced by an immediate synthesized one, then
        // the display link paces the rest.
        replayHeldKey()
        // The owner's draw loop runs the safety tick; keep it running.
        (owner as? SurfaceDrawLoopHost)?.activateSurfaceDrawLoop()
        startRepeatDisplayLink()
    }

    /// Whether `view` holds the running synthesized repeat. Its draw loop is
    /// the repeat's safety clock then and must not park. Main thread only.
    func synthesisHeld(by view: NSView) -> Bool {
        os_unfair_lock_lock(&keyRepeatLock)
        defer { os_unfair_lock_unlock(&keyRepeatLock) }
        return synthRepeatActive && heldKeyOwner === view
    }

    /// Disarm when `view`, leaving its window, holds the key: it can no longer
    /// deliver the keyUp that would end the repeat.
    func disarmIfHeld(by view: NSView, reason: String) {
        guard heldKeyOwner === view else { return }
        disarmKeyRepeatSynthesis(reason)
    }

    /// Replay on the main thread (initial takeover, and the safety path).
    private func replayHeldKey() {
        guard let code = heldKeyCode, let action = heldKeyAction else {
            disarmKeyRepeatSynthesis("no held action")
            return
        }
        switch action {
        case .text(let t):
            sendInputKeepingMainAwake(t)
        case .keyEvent(let mods, let chars, let charsIg):
            core?.sendKeyEvent(
                keyCode: UInt32(code),
                mods: mods,
                characters: chars,
                charactersIgnoringModifiers: charsIg
            )
        }
    }

    /// Replay from the display-link callback thread. Must not touch
    /// keyRepeatCaptureActive/keyRepeatCapturedText (main-thread only; a
    /// synthesized repeat is never captured) or read AppKit state directly.
    private func replayHeldKeyOffMain(code: UInt16, action: HeldKeyAction, generation: UInt64) {
        // Last check before the send, and it must be the LAST statement before
        // it: a keyUp running disarmKeyRepeatSynthesis on the main thread any
        // time up to this point must suppress the repeat, or the user sees one
        // extra character. Checking earlier (e.g. straight after the tick's own
        // critical section) is worthless -- nothing runs in between, so it only
        // re-observes state the tick already held the lock for.
        //
        // This narrows the race to the few instructions between the unlock and
        // the send; it does not eliminate it. Closing it completely would mean
        // holding keyRepeatLock across the send, which is not acceptable: the
        // send reaches Core.sendRawClassified, which sleeps in 50ms steps while
        // SSH auth is pending (bounded only by the 60s auth timeout), and the
        // main thread takes this same lock every frame from draw(in:) via
        // tickKeyRepeatSynthesis().
        os_unfair_lock_lock(&keyRepeatLock)
        let stillArmed = synthRepeatActive && keyRepeatGeneration == generation
        os_unfair_lock_unlock(&keyRepeatLock)
        guard stillArmed else { return }
        FrameTracer.trace(.inputSend, a: UInt64(code))
        switch action {
        case .text(let t):
            core?.sendInput(t)
        case .keyEvent(let mods, let chars, let charsIg):
            core?.sendKeyEvent(
                keyCode: UInt32(code),
                mods: mods,
                characters: chars,
                charactersIgnoringModifiers: charsIg
            )
        }
        // No activeDrawIdleFrames reset here: notifyDrawIdle() already resets
        // it every frame while synthRepeatActive is set (checked on the main
        // thread from the draw loop itself), so a cross-thread async dispatch
        // from this callback would be redundant. A prior version dispatched
        // one here per repeat tick (~60/s while held).
    }

    /// Called from the display-link callback (its own thread, per Apple's
    /// CVDisplayLink docs — not main). Determines whether a repeat is due
    /// and, if so, sends it directly: this is the whole point of the
    /// experiment — a main-thread render stall (nextDrawable under
    /// compositor backpressure) must not delay this send.
    private func tickKeyRepeatSynthesisOffMain() {
        os_unfair_lock_lock(&keyRepeatLock)
        guard synthRepeatActive, let code = heldKeyCode, let action = heldKeyAction else {
            os_unfair_lock_unlock(&keyRepeatLock)
            return
        }
        let now = Self.uptimeNow()
        let interval = synthInterval
        // Mirrors the main-thread tick's half-tick tolerance, but there is no
        // single well-defined "tick period" off the render clock, so use half
        // the repeat interval itself as the tolerance window.
        guard now >= synthNextFire - interval * 0.5 else {
            os_unfair_lock_unlock(&keyRepeatLock)
            return
        }
        synthNextFire += interval
        if synthNextFire < now {
            synthNextFire = now + interval
        }
        let generation = keyRepeatGeneration
        os_unfair_lock_unlock(&keyRepeatLock)
        // replayHeldKeyOffMain re-validates `generation` immediately before the
        // send; see its comment for why the check lives there and not here, and
        // why the send stays outside the lock.
        replayHeldKeyOffMain(code: code, action: action, generation: generation)
    }

    private func startRepeatDisplayLink() {
        guard repeatDisplayLink == nil else { return }
        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard status == kCVReturnSuccess, let link else {
            ZonvieCore.appLogScrollMode("[keyRepeat] CVDisplayLinkCreateWithActiveCGDisplays failed status=\(status)")
            return
        }
        // Retained (not passUnretained): the display link's callback runs on
        // its own thread and may fire at any point until CVDisplayLinkStop
        // takes effect. An unretained context would dangle if this object were
        // deallocated (e.g. its session closed) while a repeat was still
        // armed — there is no deinit calling stopRepeatDisplayLink(), so the
        // link could keep running past its lifetime. The extra retain here
        // keeps self alive until stopRepeatDisplayLink() releases it below.
        let retained = Unmanaged.passRetained(self)
        repeatDisplayLinkContext = retained
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            let input = Unmanaged<SessionKeyInput>.fromOpaque(ctx).takeUnretainedValue()
            input.tickKeyRepeatSynthesisOffMain()
            return kCVReturnSuccess
        }, retained.toOpaque())
        CVDisplayLinkStart(link)
        repeatDisplayLink = link
    }

    private func stopRepeatDisplayLink() {
        guard let link = repeatDisplayLink else { return }
        CVDisplayLinkStop(link)
        repeatDisplayLink = nil
        repeatDisplayLinkContext?.release()
        repeatDisplayLinkContext = nil
    }

    /// Called from the renderer's draw entry every frame (main thread).
    /// No-op unless a synthesized repeat is armed. Only the safety-disarm
    /// check remains here; send timing is driven by the display link.
    func tickKeyRepeatSynthesis() {
        os_unfair_lock_lock(&keyRepeatLock)
        let active = synthRepeatActive
        os_unfair_lock_unlock(&keyRepeatLock)
        guard active else { return }
        // Safety net: lost keyUps (Cmd-Tab etc.) and IME activation must
        // never leave a key repeating forever. Asked of the view holding the
        // key, which is an external window's whenever one started the repeat.
        // An owner that has gone away cannot deliver the keyUp that would end
        // this, so its disappearance is itself a reason to stop; every arm
        // records an owner, so nil here means deallocated, not unset.
        guard let owner = heldKeyOwner else {
            disarmKeyRepeatSynthesis("owner gone")
            return
        }
        if owner.hasMarkedText() || owner.window?.isKeyWindow != true {
            disarmKeyRepeatSynthesis("safety")
        }
    }

    /// The repeat gate every grid view's keyDown runs first. True means
    /// synthesis owns this key's cadence and the caller must drop the event.
    ///
    /// External windows come through here too. Their keyDowns reach Neovim
    /// via this view's core, so without the gate a key held over one runs on
    /// the OS repeat timer and beats against the display: measured 2.2
    /// stalled frames/s, against 0.33/s for the same grid driven by
    /// synthesis.
    func keyRepeatSwallowsOSRepeat(_ event: NSEvent, owner: KeyRepeatOwner) -> Bool {
        if event.isARepeat {
            if synthRepeatActive && event.keyCode == heldKeyCode {
                return true  // synthesis owns this key's cadence; swallow OS repeats
            }
            if !synthRepeatActive, event.keyCode == heldKeyCode,
               heldKeyAction != nil, !owner.hasMarkedText()
            {
                takeOverKeyRepeat(owner: owner)
                return true
            }
            // Unknown repeat state: stay transparent, process normally.
            return false
        }
        // Fresh press (also rollover to another key): previous synthesis
        // no longer matches reality.
        disarmKeyRepeatSynthesis("new keyDown")
        return false
    }

    /// Record a held key an external grid view sent with sendKeyEvent.
    func armHeldKeyEvent(
        owner: KeyRepeatOwner,
        code: UInt16,
        mods: UInt32,
        characters: String?,
        charactersIgnoringModifiers: String?
    ) {
        armHeldKey(owner: owner, code: code, action: .keyEvent(
            mods: mods,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        ))
    }

    /// Open the capture window around an external grid view's keyDown so the
    /// text it ends up sending through sendInputForHeldKey is recorded.
    func beginHeldKeyCapture(isRepeat: Bool) {
        keyRepeatCaptureActive = !isRepeat
        keyRepeatCapturedText = nil
        keyRepeatCapturedCount = 0
    }

    /// Close it, arming the key only for a clean single-send press.
    func endHeldKeyCapture(owner: KeyRepeatOwner, code: UInt16) {
        guard keyRepeatCaptureActive else { return }
        keyRepeatCaptureActive = false
        guard keyRepeatCapturedCount == 1, let t = keyRepeatCapturedText,
              !owner.hasMarkedText() else { return }
        armHeldKey(owner: owner, code: code, action: .text(t))
    }

    /// Disarm from an external grid view's keyUp or flagsChanged. A nil `code`
    /// means "whatever is held": any modifier change invalidates the recorded
    /// input (e.g. j -> C-j).
    func disarmKeyRepeat(ifHeld code: UInt16?, reason: String) {
        guard let held = heldKeyCode else { return }
        if let code, code != held { return }
        disarmKeyRepeatSynthesis(reason)
    }

    /// One keyDown for every grid view. `owner` is the view the event reached:
    /// its marked text, input context and window decide composition and when a
    /// repeat must stop. This object supplies the core and the repeat
    /// synthesis, whose pacing every surface shares — an external view's keys
    /// left on the OS repeat timer beat against the display and stalled a
    /// frame at a time. The two views spelled this body out separately.
    func handleGridKeyDown(_ event: NSEvent, owner: KeyRepeatOwner, traceSurface: Int64) {
        guard let core else { return }

        let m = event.modifierFlags
        let ownerIsMain = owner === core.terminalView

        // Check if Option key should be treated as Meta (Alt) based on config.
        // Left Option raw flag: 0x20, Right Option raw flag: 0x40.
        let optionIsMeta = KeyCharacterSelection.optionActsAsMeta(
            hasOption: m.contains(.option),
            modifierRawValue: m.rawValue,
            optionAsMeta: core.getOptionAsMeta()
        )
        let hasControlOrCommand = m.contains(.control) || m.contains(.command) || optionIsMeta

        // evt_ts: NSEvent.timestamp (kernel event time, seconds since boot) in ms.
        // Comparing evt_ts deltas against handler-entry deltas separates the
        // repeat generator's cadence from main-runloop delivery quantization.
        ZonvieCore.appLogScrollMode("[keyDown] surface=\(traceSurface) keyCode=0x\(String(event.keyCode, radix: 16)) chars=\(event.characters ?? "") hasMarked=\(owner.hasMarkedText()) ctrl/cmd=\(hasControlOrCommand) isRepeat=\(event.isARepeat) evt_ts=\(String(format: "%.3f", event.timestamp * 1000.0))")

        // --- Key repeat synthesis (see MARK above) ---
        let swallowed = keyRepeatSwallowsOSRepeat(event, owner: owner)
        // External views only: this surface records its sends where the
        // synthesis sends them, and test/perf/analyze.py counts every tag-12
        // row as a send.
        if FrameTracer.enabled, !ownerIsMain {
            FrameTracer.trace(
                .inputSend,
                a: UInt64(event.keyCode),
                b: (event.isARepeat ? 1 : 0) | (swallowed ? 2 : 0),
                seq: UInt32(truncatingIfNeeded: traceSurface)
            )
        }
        if swallowed { return }

        // If IME is composing (has marked text), let IME handle all keys
        // except Escape which cancels composition.
        if owner.consumeKeyDuringComposition(event) { return }

        // No marked text: special keys or Ctrl/Cmd go directly to Neovim.
        let isSpecialKey = KeyCharacterSelection.isSpecialKeyCode(event.keyCode)

        if hasControlOrCommand || isSpecialKey {
            let mods = KeyCharacterSelection.modifierMask(
                control: m.contains(.control),
                optionIsMeta: optionIsMeta,
                shift: m.contains(.shift),
                command: m.contains(.command),
                ctrlBit: UInt32(ZONVIE_MOD_CTRL),
                altBit: UInt32(ZONVIE_MOD_ALT),
                shiftBit: UInt32(ZONVIE_MOD_SHIFT),
                superBit: UInt32(ZONVIE_MOD_SUPER)
            )

            let chars = KeyCharacterSelection.primaryCharacters(
                optionIsMeta: optionIsMeta,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )

            ZonvieCore.appLogScrollMode("[keyDown] -> sendKeyEvent (special/mod) optMeta=\(optionIsMeta) chars=\(chars ?? "nil")")
            core.sendKeyEvent(
                keyCode: UInt32(event.keyCode),
                mods: mods,
                characters: chars,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
            // Cmd shortcuts must not synthesize repeats; everything else
            // (arrows, Ctrl-d, ...) is a replayable held-key candidate.
            if !event.isARepeat && !m.contains(.command) {
                armHeldKeyEvent(
                    owner: owner,
                    code: event.keyCode,
                    mods: mods,
                    characters: chars,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers
                )
            }
            return
        }

        // `:` <-> `;` swap (config-gated). Handle it here, on the keyDown path
        // for a single keypress, rather than in the send: paste also flows
        // through it, and swapping there would corrupt pasted text
        // containing `:`/`;`. These two ASCII chars never start IME
        // composition, so bypassing IME for them is safe. The held action
        // stores the swapped char so synthesized repeats replay it verbatim.
        // `endHeldKeyCapture` also refuses to arm while text is marked, which
        // cannot happen here: the guard already required none.
        if ZonvieConfig.shared.input.swapColonSemicolon, !owner.hasMarkedText(),
           let ch = event.characters, let swapped = ZonvieConfig.swapColonSemicolon(ch)
        {
            beginHeldKeyCapture(isRepeat: event.isARepeat)
            // Only this surface's own draw loop is kept awake for the reply.
            if ownerIsMain { sendInputKeepingMainAwake(swapped) } else { sendInputForHeldKey(swapped) }
            endHeldKeyCapture(owner: owner, code: event.keyCode)
            return
        }

        // Plain key: capture what this keyDown sends (via IME insertText) so
        // repeats can replay it. Only a clean single-send keyDown is a
        // synthesis candidate.
        beginHeldKeyCapture(isRepeat: event.isARepeat)
        defer { endHeldKeyCapture(owner: owner, code: event.keyCode) }

        // Let the system handle IME input.
        if let ctx = owner.inputContext, ctx.handleEvent(event) {
            ZonvieCore.appLogScrollMode("[keyDown] -> inputContext.handleEvent returned true")
            return
        }
        ZonvieCore.appLogScrollMode("[keyDown] -> interpretKeyEvents fallback")
        // Fallback: interpret key events directly.
        owner.interpretKeyEvents([event])
    }
}
