#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// Type-safe bridge between the voice pipeline and the native doudou manager.
/// The voice module knows no Ghostty type and cannot bypass this allow-list.
@MainActor
final class GaiTeddyCompanionRouter: TeddyCompanionRouting {
    private let router: TeddyCompanionToolRouter
    private weak var manager: GaiCompanionManager?

    init(manager: GaiCompanionManager) {
        self.manager = manager
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

    func companionSnapshots() -> [TeddyCompanionSnapshot] {
        guard let manager else { return [] }
        return manager.managedAgentSnapshots().map { agent in
            TeddyCompanionSnapshot(
                id: agent.id,
                name: agent.name,
                provider: agent.provider?.rawValue ?? "terminal",
                phase: teddyPhase(agent.phase),
                directoryPath: agent.directoryPath,
                hasPendingResponse: agent.isResponsePending)
        }
    }

    func submitPrompt(
        _ text: String,
        to companionID: UUID
    ) -> TeddyCompanionControlResult {
        guard let manager else { return .failed(.unavailableTerminal) }
        return teddyControlResult(manager.submitPrompt(text, to: companionID))
    }

    func interruptCompanion(_ companionID: UUID) -> TeddyCompanionControlResult {
        guard let manager else { return .failed(.unavailableTerminal) }
        return teddyControlResult(manager.interruptAgent(id: companionID))
    }

    func createCompanion(
        directoryPath: String,
        cli: String
    ) -> Result<TeddyCompanionSnapshot, TeddyCompanionControlFailure> {
        guard let manager else { return .failure(.creationFailed) }
        let requestedCLI = GaiCompanionCreationCLI(rawValue: cli) ?? .codex
        guard let agent = manager.createCompanion(
            directoryURL: URL(fileURLWithPath: directoryPath),
            cli: requestedCLI)
        else { return .failure(.creationFailed) }
        return .success(
            TeddyCompanionSnapshot(
                id: agent.id,
                name: agent.name,
                provider: agent.provider?.rawValue ?? requestedCLI.rawValue,
                phase: teddyPhase(agent.phase),
                directoryPath: agent.directoryPath,
                hasPendingResponse: agent.isResponsePending))
    }

    func makeInlineTerminalView(for companionID: UUID) -> AnyView? {
        guard let manager,
              let terminal = manager.prepareInlineTerminalContent(id: companionID) else {
            return nil
        }
        return AnyView(
            GaiTeddyInlineTerminalSurface(
                surfaceView: terminal.surfaceView,
                terminalView: terminal.hostView,
                onVisibilityChanged: { [weak manager] visible in
                    manager?.setInlineTerminalVisible(visible, id: companionID)
                }))
    }

    func makeCompanionAvatarView(for companionID: UUID, width: CGFloat) -> AnyView? {
        manager?.makeTeddyCompanionAvatarView(id: companionID, width: width)
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

    private func teddyPhase(_ phase: GaiCompanionPhase) -> TeddyCompanionSnapshot.Phase {
        switch phase {
        case .idle:
            .idle
        case .working:
            .working
        case .awaitingInput:
            .awaitingInput
        case .awaitingApproval:
            .awaitingApproval
        case .completedUnseen:
            .completed
        case .failed:
            .failed
        case .exited:
            .exited
        }
    }

    private func teddyControlResult(
        _ result: GaiCompanionControlReceipt
    ) -> TeddyCompanionControlResult {
        switch result {
        case .submitted:
            return .submitted
        case .interrupted:
            return .interrupted
        case .failed(let failure):
            let mappedFailure: TeddyCompanionControlFailure
            switch failure {
            case .unknownAgent:
                mappedFailure = .unknownCompanion
            case .emptyPrompt:
                mappedFailure = .emptyPrompt
            case .promptTooLarge:
                mappedFailure = .promptTooLarge
            case .unavailableTerminal:
                mappedFailure = .unavailableTerminal
            case .agentBusy:
                mappedFailure = .companionBusy
            }
            return .failed(mappedFailure)
        }
    }
}

/// Minimal host for a doudou's existing Ghostty surface. It deliberately adds
/// no terminal abstraction, buffer or polling layer: keyboard input and output
/// still travel through the original SurfaceView and PTY.
private struct GaiTeddyInlineTerminalSurface: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let terminalView: NSView
    let onVisibilityChanged: (Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            GaiTeddyHostedTerminalRepresentable(
                surfaceView: surfaceView,
                terminalView: terminalView,
                size: geometry.size)
                .focusedValue(\.ghosttySurfacePwd, surfaceView.pwd)
                .focusedValue(\.ghosttySurfaceView, surfaceView)
                .focusedValue(\.ghosttySurfaceCellSize, surfaceView.cellSize)
        }
        .ghosttySurfaceView(surfaceView)
        .background(Color.black)
        .clipped()
        .transaction { transaction in
            transaction.animation = nil
        }
        .onAppear { onVisibilityChanged(true) }
        .onDisappear { onVisibilityChanged(false) }
    }
}

/// AppKit host for the doudou's complete native terminal hierarchy. Moving the
/// existing host instead of rebuilding a second SurfaceRepresentable preserves
/// the exact Metal renderer, scrollback and controls while keeping hard clip
/// boundaries inside Teddy's central stage.
private struct GaiTeddyHostedTerminalRepresentable: NSViewRepresentable {
    let surfaceView: Ghostty.SurfaceView
    let terminalView: NSView
    let size: CGSize

    func makeNSView(context: Context) -> GaiTeddyTerminalContainerView {
        GaiTeddyTerminalContainerView(
            surfaceView: surfaceView,
            terminalView: terminalView,
            contentSize: size)
    }

    func updateNSView(
        _ nsView: GaiTeddyTerminalContainerView,
        context: Context
    ) {
        nsView.updateContentSize(size)
    }
}

@MainActor
private final class GaiTeddyTerminalContainerView: NSView {
    private weak var surfaceView: Ghostty.SurfaceView?
    private weak var terminalView: NSView?
    private var requestedContentSize: CGSize

    init(
        surfaceView: Ghostty.SurfaceView,
        terminalView: NSView,
        contentSize: CGSize
    ) {
        self.surfaceView = surfaceView
        self.terminalView = terminalView
        requestedContentSize = contentSize
        super.init(frame: NSRect(origin: .zero, size: contentSize))

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor

        terminalView.frame = bounds
        terminalView.autoresizingMask = [.width, .height]
        addSubview(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard let terminalView, terminalView.superview === self else { return }
        terminalView.frame = bounds
        terminalView.needsLayout = true
        terminalView.layoutSubtreeIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }

        // The terminal is a mode, not a transient SwiftUI control. Give the
        // original Ghostty surface keyboard focus once its existing hierarchy
        // has actually been mounted in Teddy. Subsequent clicks go straight to
        // SurfaceView; no SwiftUI tap recognizer competes for the event.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let surfaceView = self.surfaceView,
                  let window = self.window,
                  surfaceView.window === window,
                  window.firstResponder !== surfaceView else { return }
            window.makeFirstResponder(surfaceView)
        }
    }

    func updateContentSize(_ size: CGSize) {
        guard requestedContentSize != size else { return }
        requestedContentSize = size
        needsLayout = true
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
    private var companionListCancellable: AnyCancellable?

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
        window.isOpaque = false
        window.backgroundColor = .clear
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
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(companionStateDidChange(_:)),
            name: .gaiCompanionStateDidChange,
            object: manager)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inlineTerminalDidDetach(_:)),
            name: .gaiCompanionInlineTerminalDidDetach,
            object: manager)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inlineTerminalRequestedVoice(_:)),
            name: .gaiCompanionInlineTerminalRequestedVoice,
            object: manager)
        companionListCancellable = manager.$runtimes
            .receive(on: RunLoop.main)
            .sink { [weak voiceController] _ in
                voiceController?.refreshCompanionConversations()
            }
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
        voiceController.collapseInlineTerminal()
        sender.orderOut(nil)
        return false
    }

    func windowWillMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        voiceController.collapseInlineTerminal()
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

    @objc private func companionStateDidChange(_ notification: Notification) {
        guard notification.object as? GaiCompanionManager === manager else { return }
        voiceController.refreshCompanionConversations()
    }

    @objc private func inlineTerminalDidDetach(_ notification: Notification) {
        guard notification.object as? GaiCompanionManager === manager,
              let companionID = notification.userInfo?[
                  GaiCompanionControl.companionIDUserInfoKey
              ] as? UUID,
              companionID == voiceController.activeConversationID
        else { return }
        voiceController.collapseInlineTerminal()
    }

    @objc private func inlineTerminalRequestedVoice(_ notification: Notification) {
        guard notification.object as? GaiCompanionManager === manager,
              let companionID = notification.userInfo?[
                  GaiCompanionControl.companionIDUserInfoKey
              ] as? UUID,
              companionID == voiceController.activeConversationID
        else { return }
        voiceController.collapseInlineTerminal()
    }
}
#endif
