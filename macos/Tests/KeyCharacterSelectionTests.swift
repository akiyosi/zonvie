import Foundation

@main
private enum KeyCharacterSelectionTests {
    private static var failures = 0

    private static func expect(
        optionIsMeta: Bool,
        characters: String?,
        ignoringModifiers: String?,
        equals expected: String?,
        _ message: String
    ) {
        let got = KeyCharacterSelection.primaryCharacters(
            optionIsMeta: optionIsMeta,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers
        )
        if got != expected {
            let shown = got ?? "nil"
            let want = expected ?? "nil"
            FileHandle.standardError.write(
                Data(("FAIL: " + message + " (got \(shown), want \(want))\n").utf8))
            failures += 1
        }
    }

    static func main() {
        // Option acting as Meta: macOS has already rewritten `characters` into
        // the composed character, so the untransformed key has to win or Neovim
        // receives <A-ƒ> instead of <A-f>.
        expect(
            optionIsMeta: true, characters: "ƒ", ignoringModifiers: "f",
            equals: "f", "Option-as-Meta takes the untransformed key")

        // Option acting as a normal macOS modifier: the composed character is
        // what the user asked to type, so it must survive untouched.
        expect(
            optionIsMeta: false, characters: "ƒ", ignoringModifiers: "f",
            equals: "ƒ", "plain Option keeps the composed character")

        // Modifiers that do not rewrite `characters` are unaffected either way.
        expect(
            optionIsMeta: false, characters: "d", ignoringModifiers: "d",
            equals: "d", "Ctrl-style keys pass through with Option off")
        expect(
            optionIsMeta: true, characters: "d", ignoringModifiers: "d",
            equals: "d", "Ctrl-style keys pass through with Option on")

        // Degenerate events. AppKit can hand back nil for either string; the
        // selection must stay a straight pick rather than inventing a value,
        // because the core treats an empty result as "send nothing".
        expect(
            optionIsMeta: true, characters: "ƒ", ignoringModifiers: nil,
            equals: nil, "Meta mode does not fall back to the composed character")
        expect(
            optionIsMeta: false, characters: nil, ignoringModifiers: "f",
            equals: nil, "plain mode does not fall back to the untransformed key")
        expect(
            optionIsMeta: true, characters: nil, ignoringModifiers: nil,
            equals: nil, "both nil stays nil")

        // An empty string is distinct from nil and must not be coerced.
        expect(
            optionIsMeta: true, characters: "ƒ", ignoringModifiers: "",
            equals: "", "an empty untransformed key is still the chosen value")

        if failures == 0 {
            print("KeyCharacterSelectionTests: all checks passed")
        } else {
            FileHandle.standardError.write(Data("KeyCharacterSelectionTests: \(failures) failure(s)\n".utf8))
            exit(1)
        }
    }
}
