#if os(macOS)
import CoreGraphics
import Foundation

/// Recognizes a deliberate tap of the physical Right Command key without
/// consuming keyboard input. The tap fires on release; any ordinary key press,
/// Left Command, or additional modifier cancels it so Command-based shortcuts
/// keep behaving normally.
struct GaiAgentVisibilityShortcutRecognizer {
    private enum Phase {
        case idle
        case tracking(startedAt: TimeInterval, keyDownCounter: UInt32)
        case blocked
    }

    private var phase: Phase = .idle
    private var idleKeyDownCounter: UInt32?
    private let minimumDuration: TimeInterval
    private let maximumDuration: TimeInterval

    var needsFastPolling: Bool {
        switch phase {
        case .idle, .blocked:
            return false
        case .tracking:
            return true
        }
    }

    init(
        minimumDuration: TimeInterval = 0.015,
        maximumDuration: TimeInterval = 2.0
    ) {
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
    }

    mutating func prime(
        rightCommandIsDown: Bool,
        leftCommandIsDown: Bool,
        flags: CGEventFlags,
        keyDownCounter: UInt32
    ) {
        idleKeyDownCounter = keyDownCounter
        phase = rightCommandIsDown
            || leftCommandIsDown
            || hasConflictingModifier(flags)
            ? .blocked
            : .idle
    }

    mutating func sample(
        rightCommandIsDown: Bool,
        leftCommandIsDown: Bool,
        flags: CGEventFlags,
        keyDownCounter: UInt32,
        timestamp: TimeInterval
    ) -> Bool {
        let conflictingModifierIsDown = leftCommandIsDown
            || hasConflictingModifier(flags)
        let allShortcutKeysAreUp = !rightCommandIsDown
            && !leftCommandIsDown
            && !hasConflictingModifier(flags)

        switch phase {
        case .idle:
            guard rightCommandIsDown else {
                idleKeyDownCounter = keyDownCounter
                if conflictingModifierIsDown {
                    phase = .blocked
                }
                return false
            }
            guard !conflictingModifierIsDown else {
                phase = .blocked
                return false
            }
            guard let idleKeyDownCounter,
                  keyDownCounter == idleKeyDownCounter
            else {
                phase = .blocked
                return false
            }
            phase = .tracking(
                startedAt: timestamp,
                keyDownCounter: keyDownCounter)
            return false

        case let .tracking(startedAt, initialKeyDownCounter):
            let duration = timestamp - startedAt
            guard !conflictingModifierIsDown,
                  keyDownCounter == initialKeyDownCounter,
                  duration <= maximumDuration
            else {
                phase = allShortcutKeysAreUp ? .idle : .blocked
                if allShortcutKeysAreUp {
                    idleKeyDownCounter = keyDownCounter
                }
                return false
            }
            guard !rightCommandIsDown else { return false }

            let shouldFire = duration >= minimumDuration
            phase = allShortcutKeysAreUp ? .idle : .blocked
            if allShortcutKeysAreUp {
                idleKeyDownCounter = keyDownCounter
            }
            return shouldFire

        case .blocked:
            if allShortcutKeysAreUp {
                phase = .idle
                idleKeyDownCounter = keyDownCounter
            }
            return false
        }
    }

    private func hasConflictingModifier(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskShift)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)
            || flags.contains(.maskSecondaryFn)
    }
}

/// Permission-free, process-wide monitor for a modifier-only shortcut.
///
/// Carbon hot keys require a non-modifier key, while global NSEvent keyboard
/// monitors require Accessibility approval. Reading Quartz's combined session
/// state gives us the actual hardware modifier state without either compromise.
final class GaiAgentVisibilityShortcutMonitor {
    /// Virtual key codes are side-specific even though Quartz's `.maskCommand`
    /// flag intentionally merges both Command keys.
    private static let rightCommandKeyCode = CGKeyCode(0x36)
    private static let leftCommandKeyCode = CGKeyCode(0x37)
    private static let idleInterval = DispatchTimeInterval.milliseconds(33)
    private static let activeInterval = DispatchTimeInterval.milliseconds(8)

    private let queue = DispatchQueue(
        label: "com.sipiyou.teddycli.agent-visibility-shortcut",
        qos: .userInitiated)
    private let action: () -> Void
    private var recognizer = GaiAgentVisibilityShortcutRecognizer()
    private var timer: DispatchSourceTimer?
    private var usesFastPolling = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func start() {
        queue.async { [weak self] in
            guard let self, timer == nil else { return }

            recognizer.prime(
                rightCommandIsDown: Self.rightCommandIsDown,
                leftCommandIsDown: Self.leftCommandIsDown,
                flags: Self.currentFlags,
                keyDownCounter: Self.currentKeyDownCounter)
            usesFastPolling = recognizer.needsFastPolling

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                self?.sample()
            }
            self.timer = timer
            schedule(timer, fast: usesFastPolling)
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            timer?.cancel()
            timer = nil
            recognizer = GaiAgentVisibilityShortcutRecognizer()
            usesFastPolling = false
        }
    }

    private func sample() {
        let shouldFire = recognizer.sample(
            rightCommandIsDown: Self.rightCommandIsDown,
            leftCommandIsDown: Self.leftCommandIsDown,
            flags: Self.currentFlags,
            keyDownCounter: Self.currentKeyDownCounter,
            timestamp: ProcessInfo.processInfo.systemUptime)

        if shouldFire {
            DispatchQueue.main.async { [action] in action() }
        }

        let shouldUseFastPolling = recognizer.needsFastPolling
        guard shouldUseFastPolling != usesFastPolling, let timer else { return }
        usesFastPolling = shouldUseFastPolling
        schedule(timer, fast: shouldUseFastPolling)
    }

    private func schedule(_ timer: DispatchSourceTimer, fast: Bool) {
        timer.schedule(
            deadline: .now(),
            repeating: fast ? Self.activeInterval : Self.idleInterval,
            leeway: fast ? .milliseconds(1) : .milliseconds(3))
    }

    private static var currentFlags: CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
    }

    private static var rightCommandIsDown: Bool {
        CGEventSource.keyState(
            .combinedSessionState,
            key: rightCommandKeyCode)
    }

    private static var leftCommandIsDown: Bool {
        CGEventSource.keyState(
            .combinedSessionState,
            key: leftCommandKeyCode)
    }

    private static var currentKeyDownCounter: UInt32 {
        CGEventSource.counterForEventType(
            .combinedSessionState,
            eventType: .keyDown)
    }
}
#endif
