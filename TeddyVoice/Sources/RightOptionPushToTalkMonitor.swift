import AppKit
import CoreGraphics

enum RightOptionKey {
    static let keyCode: UInt16 = 0x3D
    static let deviceMask: UInt = 0x0000_0040

    static func pressedState(keyCode: UInt16, modifierFlagsRaw: UInt) -> Bool? {
        guard keyCode == self.keyCode else { return nil }
        return modifierFlagsRaw & deviceMask != 0
    }
}

@MainActor
final class RightOptionPushToTalkMonitor {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isStarted = false
    private var isPressed = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Returns whether macOS currently allows the shortcut outside Teddy's window.
    @discardableResult
    func start() -> Bool {
        if isStarted { return CGPreflightListenEventAccess() }
        isStarted = true

        let globalAccess = CGPreflightListenEventAccess() || CGRequestListenEventAccess()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let keyCode = event.keyCode
            let rawFlags = event.modifierFlags.rawValue
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, rawFlags: rawFlags)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let keyCode = event.keyCode
            let rawFlags = event.modifierFlags.rawValue
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, rawFlags: rawFlags)
            }
        }
        return globalAccess
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        isStarted = false
        if isPressed {
            isPressed = false
            onRelease()
        }
    }

    private func handle(keyCode: UInt16, rawFlags: UInt) {
        guard let pressed = RightOptionKey.pressedState(
            keyCode: keyCode,
            modifierFlagsRaw: rawFlags
        ), pressed != isPressed
        else { return }

        isPressed = pressed
        if pressed {
            onPress()
        } else {
            onRelease()
        }
    }
}
