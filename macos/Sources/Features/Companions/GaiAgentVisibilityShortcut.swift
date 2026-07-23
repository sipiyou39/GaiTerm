#if os(macOS)
import CoreGraphics
import Foundation

/// Recognizes a deliberate Shift + Option modifier chord without consuming
/// keyboard input. A chord fires only when one of its modifiers is released,
/// and any ordinary key press cancels it so Option-based character entry keeps
/// behaving normally.
struct GaiAgentVisibilityShortcutRecognizer {
    private enum Phase {
        case idle
        case armed(keyDownCounter: UInt32)
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
        case .armed, .tracking:
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

    mutating func prime(flags: CGEventFlags, keyDownCounter: UInt32) {
        idleKeyDownCounter = keyDownCounter
        phase = hasShiftOrOption(flags) ? .blocked : .idle
    }

    mutating func sample(
        flags: CGEventFlags,
        keyDownCounter: UInt32,
        timestamp: TimeInterval
    ) -> Bool {
        let shiftIsDown = flags.contains(.maskShift)
        let optionIsDown = flags.contains(.maskAlternate)
        let eitherIsDown = shiftIsDown || optionIsDown
        let bothAreDown = shiftIsDown && optionIsDown
        let forbiddenModifierIsDown =
            flags.contains(.maskCommand)
            || flags.contains(.maskControl)
            || flags.contains(.maskSecondaryFn)

        switch phase {
        case .idle:
            guard eitherIsDown else {
                idleKeyDownCounter = keyDownCounter
                return false
            }
            guard !forbiddenModifierIsDown else {
                phase = .blocked
                return false
            }
            guard let idleKeyDownCounter,
                  keyDownCounter == idleKeyDownCounter
            else {
                phase = .blocked
                return false
            }
            guard bothAreDown else {
                phase = .armed(keyDownCounter: keyDownCounter)
                return false
            }
            phase = .tracking(
                startedAt: timestamp,
                keyDownCounter: keyDownCounter)
            return false

        case let .armed(initialKeyDownCounter):
            guard !forbiddenModifierIsDown,
                  keyDownCounter == initialKeyDownCounter
            else {
                phase = eitherIsDown ? .blocked : .idle
                if !eitherIsDown {
                    idleKeyDownCounter = keyDownCounter
                }
                return false
            }
            guard eitherIsDown else {
                phase = .idle
                idleKeyDownCounter = keyDownCounter
                return false
            }
            guard bothAreDown else { return false }

            phase = .tracking(
                startedAt: timestamp,
                keyDownCounter: initialKeyDownCounter)
            return false

        case let .tracking(startedAt, initialKeyDownCounter):
            let duration = timestamp - startedAt
            guard !forbiddenModifierIsDown,
                  keyDownCounter == initialKeyDownCounter,
                  duration <= maximumDuration
            else {
                phase = eitherIsDown ? .blocked : .idle
                if !eitherIsDown {
                    idleKeyDownCounter = keyDownCounter
                }
                return false
            }
            guard !bothAreDown else { return false }

            let shouldFire = duration >= minimumDuration
            phase = eitherIsDown ? .blocked : .idle
            if !eitherIsDown {
                idleKeyDownCounter = keyDownCounter
            }
            return shouldFire

        case .blocked:
            if !eitherIsDown {
                phase = .idle
                idleKeyDownCounter = keyDownCounter
            }
            return false
        }
    }

    private func hasShiftOrOption(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskShift) || flags.contains(.maskAlternate)
    }
}

/// Permission-free, process-wide monitor for a modifier-only shortcut.
///
/// Carbon hot keys require a non-modifier key, while global NSEvent keyboard
/// monitors require Accessibility approval. Reading Quartz's combined session
/// state gives us the actual hardware modifier state without either compromise.
final class GaiAgentVisibilityShortcutMonitor {
    private static let idleInterval = DispatchTimeInterval.milliseconds(33)
    private static let activeInterval = DispatchTimeInterval.milliseconds(8)

    private let queue = DispatchQueue(
        label: "com.sipiyou.gaiterm.agent-visibility-shortcut",
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

    private static var currentKeyDownCounter: UInt32 {
        CGEventSource.counterForEventType(
            .combinedSessionState,
            eventType: .keyDown)
    }
}
#endif
