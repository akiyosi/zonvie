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

        // option_as_meta: 0 both, 1 none, 2 only_left, 3 only_right, else both.
        // 0x20 is the left Option bit, 0x40 the right one.
        func expectMeta(_ hasOption: Bool, _ raw: UInt, _ setting: UInt8,
                        _ want: Bool, _ what: String) {
            let got = KeyCharacterSelection.optionActsAsMeta(
                hasOption: hasOption, modifierRawValue: raw, optionAsMeta: setting)
            if got != want {
                failures += 1
                FileHandle.standardError.write(Data("FAIL: \(what): got \(got)\n".utf8))
            }
        }
        expectMeta(false, 0x20, 0, false, "no Option held is never Meta, even in both mode")
        expectMeta(true, 0x20, 0, true, "both mode treats left Option as Meta")
        expectMeta(true, 0x40, 0, true, "both mode treats right Option as Meta")
        expectMeta(true, 0x20, 1, false, "none mode never treats Option as Meta")
        expectMeta(true, 0x20, 2, true, "only_left accepts the left Option bit")
        expectMeta(true, 0x40, 2, false, "only_left rejects the right Option bit")
        expectMeta(true, 0x40, 3, true, "only_right accepts the right Option bit")
        expectMeta(true, 0x20, 3, false, "only_right rejects the left Option bit")
        expectMeta(true, 0x20, 99, true, "an unknown setting falls back to both")

        // Special key codes bypass the input context.
        for code in [UInt16(0x35), 0x7B, 0x7C, 0x7D, 0x7E, 0x24, 0x30, 0x33,
                     0x75, 0x73, 0x77, 0x74, 0x79, 0x7A, 0x6F] {
            if !KeyCharacterSelection.isSpecialKeyCode(code) {
                failures += 1
                FileHandle.standardError.write(
                    Data("FAIL: key code \(String(code, radix: 16)) should be special\n".utf8))
            }
        }
        for code in [UInt16(0x00), 0x03, 0x31, 0x66, 0x68] {
            if KeyCharacterSelection.isSpecialKeyCode(code) {
                failures += 1
                FileHandle.standardError.write(
                    Data("FAIL: key code \(String(code, radix: 16)) should not be special\n".utf8))
            }
        }

        // modifierMask packs exactly the bits it is given, and reports Option
        // as Alt only when it is acting as Meta. Bit values mirror
        // include/zonvie_core.h: ctrl 1, alt 2, shift 4, super 8.
        func expectMask(_ ctrl: Bool, _ meta: Bool, _ shift: Bool, _ cmd: Bool,
                        _ want: UInt32, _ what: String) {
            let got = KeyCharacterSelection.modifierMask(
                control: ctrl, optionIsMeta: meta, shift: shift, command: cmd,
                ctrlBit: 1, altBit: 2, shiftBit: 4, superBit: 8)
            if got != want {
                failures += 1
                FileHandle.standardError.write(Data("FAIL: \(what): got \(got) want \(want)\n".utf8))
            }
        }
        expectMask(false, false, false, false, 0, "no modifiers is zero")
        expectMask(true, false, false, false, 1, "control alone")
        expectMask(false, true, false, false, 2, "Option-as-Meta reports Alt")
        expectMask(false, false, true, false, 4, "shift alone")
        expectMask(false, false, false, true, 8, "command reports Super")
        expectMask(true, true, true, true, 15, "all four combine")
        expectMask(true, false, true, false, 5, "control and shift only")

        if failures == 0 {
            print("KeyCharacterSelectionTests: all checks passed")
        } else {
            FileHandle.standardError.write(Data("KeyCharacterSelectionTests: \(failures) failure(s)\n".utf8))
            exit(1)
        }
    }
}
