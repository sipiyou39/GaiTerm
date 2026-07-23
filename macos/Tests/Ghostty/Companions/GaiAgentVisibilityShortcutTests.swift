#if DEBUG
import CoreGraphics
import Testing
@testable import Ghostty

struct GaiAgentVisibilityShortcutTests {
    private let shift: CGEventFlags = [.maskShift]
    private let option: CGEventFlags = [.maskAlternate]
    private let chord: CGEventFlags = [.maskShift, .maskAlternate]

    @Test func cleanChordFiresOnceOnFirstModifierRelease() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 4)

        #expect(!recognizer.sample(flags: shift, keyDownCounter: 4, timestamp: 0))
        #expect(!recognizer.sample(flags: chord, keyDownCounter: 4, timestamp: 0.1))
        #expect(recognizer.sample(flags: option, keyDownCounter: 4, timestamp: 0.2))
        #expect(!recognizer.sample(flags: option, keyDownCounter: 4, timestamp: 0.3))
        #expect(!recognizer.sample(flags: [], keyDownCounter: 4, timestamp: 0.4))
    }

    @Test func eitherPressOrderCanStartTheChord() {
        var shiftFirst = makeRecognizer(initialKeyDownCounter: 1)
        #expect(!shiftFirst.sample(flags: shift, keyDownCounter: 1, timestamp: 0))
        #expect(!shiftFirst.sample(flags: chord, keyDownCounter: 1, timestamp: 0.1))
        #expect(shiftFirst.sample(flags: [], keyDownCounter: 1, timestamp: 0.2))

        var optionFirst = makeRecognizer(initialKeyDownCounter: 2)
        #expect(!optionFirst.sample(flags: option, keyDownCounter: 2, timestamp: 0))
        #expect(!optionFirst.sample(flags: chord, keyDownCounter: 2, timestamp: 0.1))
        #expect(optionFirst.sample(flags: [], keyDownCounter: 2, timestamp: 0.2))
    }

    @Test func ordinaryKeyPressCancelsTheChord() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 10)

        #expect(!recognizer.sample(flags: chord, keyDownCounter: 10, timestamp: 0))
        #expect(!recognizer.sample(flags: chord, keyDownCounter: 11, timestamp: 0.1))
        #expect(!recognizer.sample(flags: [], keyDownCounter: 11, timestamp: 0.2))
    }

    @Test func keyPressBeforeFirstBothModifiersSampleCannotBecomeTheBaseline() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 20)

        #expect(!recognizer.sample(flags: chord, keyDownCounter: 21, timestamp: 0.1))
        #expect(!recognizer.sample(flags: [], keyDownCounter: 21, timestamp: 0.2))
    }

    @Test func keyPressAfterFirstModifierCancelsBeforeChordCompletes() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 30)

        #expect(!recognizer.sample(flags: shift, keyDownCounter: 30, timestamp: 0))
        #expect(!recognizer.sample(flags: chord, keyDownCounter: 31, timestamp: 0.1))
        #expect(!recognizer.sample(flags: [], keyDownCounter: 31, timestamp: 0.2))
    }

    @Test func thirdModifierAndLongHoldAreRejected() {
        var withCommand = makeRecognizer(initialKeyDownCounter: 1)
        #expect(!withCommand.sample(
            flags: [.maskShift, .maskAlternate, .maskCommand],
            keyDownCounter: 1,
            timestamp: 0))
        #expect(!withCommand.sample(flags: [], keyDownCounter: 1, timestamp: 0.2))

        var held = makeRecognizer(initialKeyDownCounter: 1)
        #expect(!held.sample(flags: chord, keyDownCounter: 1, timestamp: 0))
        #expect(!held.sample(flags: chord, keyDownCounter: 1, timestamp: 1.1))
        #expect(!held.sample(flags: [], keyDownCounter: 1, timestamp: 1.2))
    }

    @Test func capsLockDoesNotInvalidateTheChord() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 7)
        let capsChord: CGEventFlags = [.maskShift, .maskAlternate, .maskAlphaShift]

        #expect(!recognizer.sample(flags: capsChord, keyDownCounter: 7, timestamp: 0))
        #expect(recognizer.sample(
            flags: [.maskAlphaShift],
            keyDownCounter: 7,
            timestamp: 0.1))
    }

    @Test func startupWithHeldModifierRequiresAFullReleaseBeforeRearming() {
        var recognizer = makeRecognizer()
        recognizer.prime(flags: option, keyDownCounter: 1)

        #expect(!recognizer.sample(flags: chord, keyDownCounter: 1, timestamp: 0))
        #expect(!recognizer.sample(flags: [], keyDownCounter: 1, timestamp: 0.1))
        #expect(!recognizer.sample(flags: chord, keyDownCounter: 1, timestamp: 0.2))
        #expect(recognizer.sample(flags: [], keyDownCounter: 1, timestamp: 0.3))
    }

    private func makeRecognizer(
        initialKeyDownCounter: UInt32 = 0
    ) -> GaiAgentVisibilityShortcutRecognizer {
        var recognizer = GaiAgentVisibilityShortcutRecognizer(
            minimumDuration: 0,
            maximumDuration: 1)
        recognizer.prime(
            flags: [],
            keyDownCounter: initialKeyDownCounter)
        return recognizer
    }
}
#endif
