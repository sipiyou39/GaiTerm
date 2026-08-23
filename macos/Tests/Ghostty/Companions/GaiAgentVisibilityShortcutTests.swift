#if DEBUG
import CoreGraphics
import Testing
@testable import TeddyCLI

struct GaiAgentVisibilityShortcutTests {
    private let shift: CGEventFlags = [.maskShift]
    private let option: CGEventFlags = [.maskAlternate]
    private let chord: CGEventFlags = [.maskShift, .maskAlternate]

    @Test func cleanChordFiresOnceOnFirstModifierRelease() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 4)

        expectSample(false, recognizer: &recognizer, flags: shift, keyDownCounter: 4, timestamp: 0)
        expectSample(false, recognizer: &recognizer, flags: chord, keyDownCounter: 4, timestamp: 0.1)
        expectSample(true, recognizer: &recognizer, flags: option, keyDownCounter: 4, timestamp: 0.2)
        expectSample(false, recognizer: &recognizer, flags: option, keyDownCounter: 4, timestamp: 0.3)
        expectSample(false, recognizer: &recognizer, flags: [], keyDownCounter: 4, timestamp: 0.4)
    }

    @Test func eitherPressOrderCanStartTheChord() {
        var shiftFirst = makeRecognizer(initialKeyDownCounter: 1)
        expectSample(false, recognizer: &shiftFirst, flags: shift, keyDownCounter: 1, timestamp: 0)
        expectSample(false, recognizer: &shiftFirst, flags: chord, keyDownCounter: 1, timestamp: 0.1)
        expectSample(true, recognizer: &shiftFirst, flags: [], keyDownCounter: 1, timestamp: 0.2)

        var optionFirst = makeRecognizer(initialKeyDownCounter: 2)
        expectSample(false, recognizer: &optionFirst, flags: option, keyDownCounter: 2, timestamp: 0)
        expectSample(false, recognizer: &optionFirst, flags: chord, keyDownCounter: 2, timestamp: 0.1)
        expectSample(true, recognizer: &optionFirst, flags: [], keyDownCounter: 2, timestamp: 0.2)
    }

    @Test func ordinaryKeyPressCancelsTheChord() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 10)

        expectSample(false, recognizer: &recognizer, flags: chord, keyDownCounter: 10, timestamp: 0)
        expectSample(false, recognizer: &recognizer, flags: chord, keyDownCounter: 11, timestamp: 0.1)
        expectSample(false, recognizer: &recognizer, flags: [], keyDownCounter: 11, timestamp: 0.2)
    }

    @Test func keyPressBeforeFirstBothModifiersSampleCannotBecomeTheBaseline() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 20)

        expectSample(false, recognizer: &recognizer, flags: chord, keyDownCounter: 21, timestamp: 0.1)
        expectSample(false, recognizer: &recognizer, flags: [], keyDownCounter: 21, timestamp: 0.2)
    }

    @Test func keyPressAfterFirstModifierCancelsBeforeChordCompletes() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 30)

        expectSample(false, recognizer: &recognizer, flags: shift, keyDownCounter: 30, timestamp: 0)
        expectSample(false, recognizer: &recognizer, flags: chord, keyDownCounter: 31, timestamp: 0.1)
        expectSample(false, recognizer: &recognizer, flags: [], keyDownCounter: 31, timestamp: 0.2)
    }

    @Test func thirdModifierAndLongHoldAreRejected() {
        var withCommand = makeRecognizer(initialKeyDownCounter: 1)
        expectSample(false, recognizer: &withCommand,
            flags: [.maskShift, .maskAlternate, .maskCommand],
            keyDownCounter: 1,
            timestamp: 0)
        expectSample(false, recognizer: &withCommand, flags: [], keyDownCounter: 1, timestamp: 0.2)

        var held = makeRecognizer(initialKeyDownCounter: 1)
        expectSample(false, recognizer: &held, flags: chord, keyDownCounter: 1, timestamp: 0)
        expectSample(false, recognizer: &held, flags: chord, keyDownCounter: 1, timestamp: 1.1)
        expectSample(false, recognizer: &held, flags: [], keyDownCounter: 1, timestamp: 1.2)
    }

    @Test func capsLockDoesNotInvalidateTheChord() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 7)
        let capsChord: CGEventFlags = [.maskShift, .maskAlternate, .maskAlphaShift]

        expectSample(false, recognizer: &recognizer, flags: capsChord, keyDownCounter: 7, timestamp: 0)
        expectSample(true, recognizer: &recognizer,
            flags: [.maskAlphaShift],
            keyDownCounter: 7,
            timestamp: 0.1)
    }

    @Test func startupWithHeldModifierRequiresAFullReleaseBeforeRearming() {
        var recognizer = makeRecognizer()
        recognizer.prime(flags: option, keyDownCounter: 1)

        expectSample(false, recognizer: &recognizer, flags: chord, keyDownCounter: 1, timestamp: 0)
        expectSample(false, recognizer: &recognizer, flags: [], keyDownCounter: 1, timestamp: 0.1)
        expectSample(false, recognizer: &recognizer, flags: chord, keyDownCounter: 1, timestamp: 0.2)
        expectSample(true, recognizer: &recognizer, flags: [], keyDownCounter: 1, timestamp: 0.3)
    }

    private func expectSample(
        _ expected: Bool,
        recognizer: inout GaiAgentVisibilityShortcutRecognizer,
        flags: CGEventFlags,
        keyDownCounter: UInt32,
        timestamp: TimeInterval
    ) {
        let actual = recognizer.sample(
            flags: flags,
            keyDownCounter: keyDownCounter,
            timestamp: timestamp)
        #expect(actual == expected)
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
