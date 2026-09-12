#if DEBUG
import CoreGraphics
import Testing
@testable import TeddyCLI

struct GaiAgentVisibilityShortcutTests {
    private let command: CGEventFlags = [.maskCommand]

    @Test func cleanRightCommandTapFiresOnceOnRelease() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 4)

        expectSample(false, recognizer: &recognizer,
            rightCommandIsDown: true,
            flags: command,
            keyDownCounter: 4,
            timestamp: 0)
        #expect(recognizer.needsFastPolling)
        expectSample(true, recognizer: &recognizer,
            keyDownCounter: 4,
            timestamp: 0.1)
        expectSample(false, recognizer: &recognizer,
            keyDownCounter: 4,
            timestamp: 0.2)
    }

    @Test func leftCommandNeverArmsTheShortcut() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 2)

        expectSample(false, recognizer: &recognizer,
            leftCommandIsDown: true,
            flags: command,
            keyDownCounter: 2,
            timestamp: 0)
        expectSample(false, recognizer: &recognizer,
            keyDownCounter: 2,
            timestamp: 0.1)
    }

    @Test func ordinaryKeyPressCancelsRightCommandTap() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 10)

        expectSample(false, recognizer: &recognizer,
            rightCommandIsDown: true,
            flags: command,
            keyDownCounter: 10,
            timestamp: 0)
        expectSample(false, recognizer: &recognizer,
            rightCommandIsDown: true,
            flags: command,
            keyDownCounter: 11,
            timestamp: 0.1)
        expectSample(false, recognizer: &recognizer,
            keyDownCounter: 11,
            timestamp: 0.2)
    }

    @Test func keyPressBeforeFirstRightCommandSampleCannotBecomeTheBaseline() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 20)

        expectSample(false, recognizer: &recognizer,
            rightCommandIsDown: true,
            flags: command,
            keyDownCounter: 21,
            timestamp: 0.1)
        expectSample(false, recognizer: &recognizer,
            keyDownCounter: 21,
            timestamp: 0.2)
    }

    @Test func anotherModifierAndLongHoldAreRejected() {
        var withShift = makeRecognizer(initialKeyDownCounter: 1)
        expectSample(false, recognizer: &withShift,
            rightCommandIsDown: true,
            flags: [.maskCommand, .maskShift],
            keyDownCounter: 1,
            timestamp: 0)
        expectSample(false, recognizer: &withShift,
            keyDownCounter: 1,
            timestamp: 0.2)

        var held = makeRecognizer(initialKeyDownCounter: 1)
        expectSample(false, recognizer: &held,
            rightCommandIsDown: true,
            flags: command,
            keyDownCounter: 1,
            timestamp: 0)
        expectSample(false, recognizer: &held,
            rightCommandIsDown: true,
            flags: command,
            keyDownCounter: 1,
            timestamp: 1.1)
        expectSample(false, recognizer: &held,
            keyDownCounter: 1,
            timestamp: 1.2)
    }

    @Test func capsLockDoesNotInvalidateRightCommandTap() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 7)

        expectSample(false, recognizer: &recognizer,
            rightCommandIsDown: true,
            flags: [.maskCommand, .maskAlphaShift],
            keyDownCounter: 7,
            timestamp: 0)
        expectSample(true, recognizer: &recognizer,
            flags: [.maskAlphaShift],
            keyDownCounter: 7,
            timestamp: 0.1)
    }

    @Test func pressingBothCommandKeysNeverTogglesVisibility() {
        var recognizer = makeRecognizer(initialKeyDownCounter: 3)

        expectSample(false, recognizer: &recognizer,
            rightCommandIsDown: true,
            leftCommandIsDown: true,
            flags: command,
            keyDownCounter: 3,
            timestamp: 0)
        expectSample(false, recognizer: &recognizer,
            keyDownCounter: 3,
            timestamp: 0.1)
    }

    @Test func startupWithHeldRightCommandRequiresAFullReleaseBeforeRearming() {
        var recognizer = GaiAgentVisibilityShortcutRecognizer(
            minimumDuration: 0,
            maximumDuration: 1)
        recognizer.prime(
            rightCommandIsDown: true,
            leftCommandIsDown: false,
            flags: command,
            keyDownCounter: 1)

        expectSample(false, recognizer: &recognizer,
            keyDownCounter: 1,
            timestamp: 0.1)
        expectSample(false, recognizer: &recognizer,
            rightCommandIsDown: true,
            flags: command,
            keyDownCounter: 1,
            timestamp: 0.2)
        expectSample(true, recognizer: &recognizer,
            keyDownCounter: 1,
            timestamp: 0.3)
    }

    private func expectSample(
        _ expected: Bool,
        recognizer: inout GaiAgentVisibilityShortcutRecognizer,
        rightCommandIsDown: Bool = false,
        leftCommandIsDown: Bool = false,
        flags: CGEventFlags = [],
        keyDownCounter: UInt32,
        timestamp: TimeInterval
    ) {
        let actual = recognizer.sample(
            rightCommandIsDown: rightCommandIsDown,
            leftCommandIsDown: leftCommandIsDown,
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
            rightCommandIsDown: false,
            leftCommandIsDown: false,
            flags: [],
            keyDownCounter: initialKeyDownCounter)
        return recognizer
    }
}
#endif
