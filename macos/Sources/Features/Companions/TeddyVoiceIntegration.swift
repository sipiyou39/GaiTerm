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
        return manager.managedAgentSnapshots().map { teddySnapshot($0) }
    }

    func freshCompanionSnapshot(for companionID: UUID) -> TeddyCompanionSnapshot? {
        guard let manager,
              let agent = manager.freshManagedAgentSnapshot(id: companionID)
        else { return nil }
        return teddySnapshot(agent)
    }

    func selectCompanion(_ companionID: UUID) {
        manager?.selectCompanion(id: companionID)
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

    func renameCompanion(_ companionID: UUID, to name: String) {
        manager?.updateName(id: companionID, name: name)
    }

    func changeCompanionDirectory(_ companionID: UUID, to path: String) {
        manager?.chooseDirectory(id: companionID, path: path)
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

    func makeCompanionCreationView() -> AnyView? {
        guard let manager else { return nil }
        return AnyView(GaiCompanionCreationView(manager: manager))
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

    private func teddySnapshot(_ agent: GaiManagedAgentSnapshot) -> TeddyCompanionSnapshot {
        TeddyCompanionSnapshot(
            id: agent.id,
            name: agent.name,
            provider: agent.provider?.rawValue ?? "terminal",
            phase: teddyPhase(agent.phase),
            directoryPath: agent.directoryPath,
            hasPendingResponse: agent.isResponsePending)
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

private final class TeddyApplicationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private enum TeddyRootDestination: Equatable {
    case library
    case settings
}

@MainActor
private final class TeddyRootNavigation: ObservableObject {
    @Published private(set) var destination: TeddyRootDestination = .library

    func showLibrary() {
        destination = .library
    }

    func showSettings() {
        destination = .settings
    }
}

private struct TeddyApplicationRootView: View {
    @ObservedObject var manager: GaiCompanionManager
    let navigation: TeddyRootNavigation
    let destination: TeddyRootDestination

    var body: some View {
        Group {
            switch destination {
            case .library:
                GaiCompanionLibraryView(
                    manager: manager,
                    onOpenSettings: navigation.showSettings,
                    onClose: {
                        NSApp.keyWindow?.performClose(nil)
                    })
            case .settings:
                SettingsView(onDismiss: navigation.showLibrary)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: destination)
    }
}

/// Teddy CLI's only ordinary application window: a compact doudou creator that
/// can expand into settings. Conversations remain exclusively on the desktop
/// doudous and never return to this root window.
@MainActor
final class TeddyApplicationWindowController: NSObject, NSWindowDelegate {
    private static let libraryContentSize = NSSize(width: 600, height: 500)
    private static let settingsContentSize = NSSize(width: 980, height: 680)

    private let manager: GaiCompanionManager
    private let window: TeddyApplicationWindow
    private let rootNavigation: TeddyRootNavigation
    private let hostingView: NSHostingView<TeddyApplicationRootView>
    private var navigationCancellable: AnyCancellable?

    init(manager: GaiCompanionManager) {
        let rootNavigation = TeddyRootNavigation()
        let window = TeddyApplicationWindow(
            contentRect: NSRect(origin: .zero, size: Self.libraryContentSize),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false)
        window.title = "Teddy CLI"
        window.contentMinSize = NSSize(width: 560, height: 450)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.animationBehavior = .documentWindow
        window.collectionBehavior = GaiCompanionSpacePolicy.onDemandApplicationWindow
        window.hasShadow = true
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            window.standardWindowButton(buttonType)?.isHidden = true
        }
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("teddy.application")

        let hostingView = NSHostingView(
            rootView: TeddyApplicationRootView(
                manager: manager,
                navigation: rootNavigation,
                destination: .library))
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = 24
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        window.contentView = hostingView

        self.manager = manager
        self.rootNavigation = rootNavigation
        self.hostingView = hostingView
        self.window = window
        super.init()
        window.delegate = self
        manager.onOpenCompanionCreator = { [weak self] in
            self?.showCreatorAnchoredToHub()
        }
        navigationCancellable = rootNavigation.$destination
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] destination in
                guard let self else { return }
                self.hostingView.rootView = TeddyApplicationRootView(
                    manager: self.manager,
                    navigation: self.rootNavigation,
                    destination: destination)
                self.resize(for: destination)
            }
    }

    func show(activate: Bool) {
        prepareWindowForActiveSpace()
        if window.isMiniaturized { window.deminiaturize(nil) }
        if activate {
            NSApp.unhide(nil)
            // Put a concrete key-window candidate on the current Space before
            // activating Teddy. Otherwise AppKit may activate the same window
            // on its previous Space and Mission Control follows it there.
            window.orderFrontRegardless()
            window.makeKey()
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    func showSettings() {
        rootNavigation.showSettings()
        show(activate: true)
    }

    private func showCreatorAnchoredToHub() {
        prepareWindowForActiveSpace()
        let wasAlreadyLibrary = rootNavigation.destination == .library
        rootNavigation.showLibrary()
        if wasAlreadyLibrary {
            resize(for: .library)
        }
        if let frame = manager.companionCreatorWindowFrame(
            windowSize: window.frame.size) {
            window.setFrame(frame, display: true, animate: window.isVisible)
        }
        show(activate: true)
    }

    private func prepareWindowForActiveSpace() {
        window.collectionBehavior = GaiCompanionSpacePolicy.onDemandApplicationWindow
        if window.isVisible, !window.isOnActiveSpace {
            // Ordering an already-visible window directly is what asks macOS
            // to visit its old Space. Taking it briefly offscreen lets
            // `.moveToActiveSpace` bind the next order-front to this Space.
            window.orderOut(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func resize(for destination: TeddyRootDestination) {
        let contentSize = switch destination {
        case .library: Self.libraryContentSize
        case .settings: Self.settingsContentSize
        }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let isLibrary = destination == .library
        window.contentMinSize = isLibrary
            ? NSSize(width: 560, height: 450)
            : NSSize(width: 820, height: 580)
        window.contentMaxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            window.standardWindowButton(buttonType)?.isHidden = isLibrary
        }
        window.setContentSize(contentSize)
        var frame = window.frame
        frame.origin = NSPoint(
            x: center.x - frame.width / 2,
            y: center.y - frame.height / 2)
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

/// Owns the single voice engine used by the lightweight replay controls in the
/// mascot and terminal chrome. Voice playback never replaces terminal content.
@MainActor
final class TeddyVoicePlaybackController: NSObject {
    private let companionRouter: GaiTeddyCompanionRouter
    private let voiceController: VoiceAgentController
    private weak var manager: GaiCompanionManager?
    private var companionListCancellable: AnyCancellable?

    init(manager: GaiCompanionManager) {
        let companionRouter = GaiTeddyCompanionRouter(manager: manager)
        let voiceController = VoiceAgentController(companionRouter: companionRouter)
        self.companionRouter = companionRouter
        self.voiceController = voiceController
        self.manager = manager
        super.init()
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
            selector: #selector(desktopSelectionDidChange(_:)),
            name: .gaiCompanionDesktopSelectionDidChange,
            object: manager)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(replayVoiceRequested(_:)),
            name: .gaiCompanionReplayVoiceRequested,
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

    func start() {
        Task { await voiceController.prepare() }
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

    @objc private func desktopSelectionDidChange(_ notification: Notification) {
        guard let companionID = companionID(from: notification) else { return }
        selectConversation(companionID)
    }

    @objc private func replayVoiceRequested(_ notification: Notification) {
        guard let companionID = companionID(from: notification) else { return }
        selectConversation(companionID) { [weak self] in
            _ = self?.voiceController.replayLatestTeddyMessage()
        }
    }

    private func selectConversation(
        _ companionID: UUID,
        onReady: @escaping () -> Void = {}
    ) {
        voiceController.refreshCompanionConversations(preferredSelection: companionID)
        voiceController.selectConversation(companionID, onReady: onReady)
    }

    private func companionID(from notification: Notification) -> UUID? {
        guard notification.object as? GaiCompanionManager === manager else { return nil }
        return notification.userInfo?[
            GaiCompanionControl.companionIDUserInfoKey
        ] as? UUID
    }
}
#endif
