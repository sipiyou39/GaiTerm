#if os(macOS)
import AppKit
import SwiftUI

/// Type-safe bridge between the voice pipeline and the native doudou manager.
/// The voice module knows no Ghostty type and cannot bypass this allow-list.
@MainActor
final class GaiTeddyCompanionRouter: TeddyCompanionRouting {
    private let router: TeddyCompanionToolRouter

    init(manager: GaiCompanionManager) {
        router = TeddyCompanionToolRouter(manager: manager)
    }

    var toolDefinitions: [GrokTextToolDefinition] {
        TeddyCompanionToolRouter.definitions.map {
            GrokTextToolDefinition(
                name: $0.name,
                description: $0.description,
                parameters: $0.parameters)
        }
    }

    func currentAgentContext() -> String {
        router.currentAgentContext()
    }

    func execute(
        _ call: GrokTextToolCall,
        selectDirectory: @escaping TeddyDirectorySelectionPresenter
    ) async throws -> GrokTextToolResult {
        let result = try await router.execute(
            TeddyCompanionToolCall(
                name: call.name,
                arguments: call.arguments),
            selectDirectory: selectDirectory)
        return GrokTextToolResult(output: result.output)
    }
}

private final class TeddyVoiceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosts the already-proven Teddy voice UI inside the isolated desktop copy.
/// Closing the window hides it; the doudous and their PTYs are never stopped.
@MainActor
final class TeddyVoiceWindowController: NSObject, NSWindowDelegate {
    private let window: TeddyVoiceWindow
    private let companionRouter: GaiTeddyCompanionRouter
    private let voiceController: VoiceAgentController
    private weak var manager: GaiCompanionManager?

    init(manager: GaiCompanionManager) {
        let companionRouter = GaiTeddyCompanionRouter(manager: manager)
        let voiceController = VoiceAgentController(companionRouter: companionRouter)
        let window = TeddyVoiceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 780),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false)
        window.title = "Teddy"
        window.minSize = NSSize(width: 920, height: 640)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 20 / 255, green: 20 / 255, blue: 21 / 255, alpha: 1)
        window.isMovableByWindowBackground = false
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.hasShadow = true
        if !window.setFrameUsingName("TeddyVoiceWindowFrame") {
            window.center()
        }
        window.setFrameAutosaveName("TeddyVoiceWindowFrame")
        window.identifier = NSUserInterfaceItemIdentifier("teddy.voice")

        let hostingView = NSHostingView(
            rootView: VoiceChatView(controller: voiceController))
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        self.companionRouter = companionRouter
        self.voiceController = voiceController
        self.window = window
        self.manager = manager
        super.init()
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(companionLastResponseDidChange(_:)),
            name: .gaiCompanionLastResponseDidChange,
            object: manager)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(activate: Bool) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if activate {
            NSApp.unhide(nil)
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func companionLastResponseDidChange(_ notification: Notification) {
        guard let manager,
              let response = notification.userInfo?[GaiCompanionControl.responseUserInfoKey]
                as? GaiCompanionLastResponse,
              let agent = manager.managedAgentSnapshots().first(where: {
                  $0.id == response.agentID
              })
        else { return }

        let kind: TeddyAgentCompletionReport.Kind
        switch agent.phase {
        case .awaitingInput:
            kind = .awaitingInput
        case .awaitingApproval:
            kind = .awaitingApproval
        case .failed:
            kind = .failed
        case .idle, .working, .completedUnseen, .exited:
            kind = .completed
        }
        voiceController.enqueueAgentCompletion(
            TeddyAgentCompletionReport(
                agentID: response.agentID,
                eventID: response.eventID,
                agentName: agent.name,
                kind: kind,
                response: response.text))
    }
}
#endif
