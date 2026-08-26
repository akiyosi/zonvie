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
}
