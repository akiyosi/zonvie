import Foundation

/// Which of an NSEvent's two character strings a key event should carry.
enum KeyCharacterSelection {
    /// The `characters` value to send for a key that already resolved to a
    /// modifier/special-key event.
    ///
    /// macOS rewrites `characters` when Option is held: Option+f arrives as
    /// `ƒ`, not `f`. When the user has asked for Option to act as Meta, that
    /// rewrite is exactly what they did not want — Neovim should see `<A-f>`.
    /// `charactersIgnoringModifiers` still holds the untransformed key, so it
    /// becomes the primary value in that mode. With Option acting as a normal
    /// macOS modifier the transformed character is the intended one and passes
    /// through unchanged.
    ///
    /// Both the main grid view and the external grid views call this. The rule
    /// used to be written out at each keyDown, and the two copies drifted:
    /// `2e91d87` added it to one of them while its own message claimed to
    /// "apply optionIsMeta logic consistently in both".
    static func primaryCharacters(
        optionIsMeta: Bool,
        characters: String?,
        charactersIgnoringModifiers: String?
    ) -> String? {
        optionIsMeta ? charactersIgnoringModifiers : characters
    }

    /// Whether Option should act as Meta for a key event, given the core's
    /// `option_as_meta` setting (settable at runtime via
    /// `:call rpcnotify(0, 'zonvie_option_as_meta', 'both')`).
    ///
    /// 0 = both, 1 = none, 2 = only_left, 3 = only_right; anything else falls
    /// back to both. The left/right cases read the device-dependent Option
    /// bits out of the raw modifier flags, which is why this takes the raw
    /// value rather than NSEvent.ModifierFlags -- that keeps this file
    /// Foundation-only, as its standalone test build requires.
    ///
    /// The main grid view and the external grid views both call this; they
    /// each used to spell the switch out inline.
    static func optionActsAsMeta(
        hasOption: Bool,
        modifierRawValue: UInt,
        optionAsMeta: UInt8
    ) -> Bool {
        guard hasOption else { return false }
        switch optionAsMeta {
        case 0: return true                              // both
        case 1: return false                             // none
        case 2: return modifierRawValue & 0x20 != 0      // only_left
        case 3: return modifierRawValue & 0x40 != 0      // only_right
        default: return true
        }
    }

    /// Key codes that go straight to Neovim rather than through the input
    /// context: Escape, the arrows, Return, Tab, both deletes, Home/End,
    /// Page Up/Down and F1-F12.
    static func isSpecialKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 0x35: return true  // Escape
        case 0x7B, 0x7C, 0x7D, 0x7E: return true  // Arrow keys (left, right, down, up)
        case 0x24: return true  // Return
        case 0x30: return true  // Tab
        case 0x33: return true  // Delete (Backspace)
        case 0x75: return true  // Forward Delete
        case 0x73, 0x77: return true  // Home, End
        case 0x74, 0x79: return true  // Page Up, Page Down
        case 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64,
             0x65, 0x6D, 0x67, 0x6F: return true  // F1-F12
        default: return false
        }
    }

    /// Pack the four modifier bits Neovim is sent for a key event.
    ///
    /// The bit values are passed in rather than referenced here: this file is
    /// compiled Foundation-only by its standalone test target, which has no
    /// C header, so ZONVIE_MOD_* is not in scope. Callers pass the constants
    /// from include/zonvie_core.h.
    ///
    /// Option is reported as Alt only when it is acting as Meta -- see
    /// optionActsAsMeta. Both key paths composed these bits identically.
    static func modifierMask(
        control: Bool,
        optionIsMeta: Bool,
        shift: Bool,
        command: Bool,
        ctrlBit: UInt32,
        altBit: UInt32,
        shiftBit: UInt32,
        superBit: UInt32
    ) -> UInt32 {
        var mods: UInt32 = 0
        if control { mods |= ctrlBit }
        if optionIsMeta { mods |= altBit }
        if shift { mods |= shiftBit }
        if command { mods |= superBit }
        return mods
    }
}

#if canImport(AppKit)
import AppKit

extension NSTextInputClient where Self: NSView {
    /// Hand a key to the input context while a composition is in flight.
    /// Returns true when the composition took the key and keyDown must stop.
    ///
    /// Escape cancels the composition outright; everything else goes to the
    /// input context first, which is what lets Enter commit and the arrows
    /// navigate the candidate window. A key the context declines still goes
    /// through interpretKeyEvents rather than on to Neovim, so a composition
    /// never leaks raw keystrokes into the buffer.
    ///
    /// The main grid view and the external grid views both compose, and both
    /// spelled this out identically at the top of keyDown.
    func consumeKeyDuringComposition(_ event: NSEvent) -> Bool {
        guard hasMarkedText() else { return false }
        if event.keyCode == 0x35 {  // Escape: cancel composition
            unmarkText()
            inputContext?.discardMarkedText()
            return true
        }
        if let ctx = inputContext, ctx.handleEvent(event) {
            return true
        }
        interpretKeyEvents([event])
        return true
    }
}
#endif
