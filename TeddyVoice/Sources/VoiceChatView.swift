import AppKit
import SwiftUI

private enum TeddyInspectorSection: String, Equatable {
    case session
    case personality
    case settings

    var title: String {
        switch self {
        case .session: "Session"
        case .personality: "Personnalité"
        case .settings: "Réglages"
        }
    }

    var symbol: String {
        switch self {
        case .session: "circle.grid.2x2"
        case .personality: "theatermasks"
        case .settings: "slider.horizontal.3"
        }
    }
}

private enum VoiceMessageClusterPosition: Equatable {
    case single
    case first
    case middle
    case last
}

private struct VoiceBubbleRadii {
    let topLeading: CGFloat
    let bottomLeading: CGFloat
    let bottomTrailing: CGFloat
    let topTrailing: CGFloat
}

private struct VoiceMessageCluster: Identifiable, Equatable {
    let sender: VoiceMessage.Sender
    var messages: [VoiceMessage]

    var id: UUID { messages[0].id }

    func position(at index: Int) -> VoiceMessageClusterPosition {
        guard messages.count > 1 else { return .single }
        if index == 0 { return .first }
        if index == messages.count - 1 { return .last }
        return .middle
    }
}

/// Keeps each side anchored to its own edge without stretching voice notes
/// across a desktop-sized window. Wider windows reveal breathing room between
/// both speakers instead of inflating the messages.
private struct TeddyConversationLayout {
    let viewportWidth: CGFloat

    var horizontalInset: CGFloat {
        switch viewportWidth {
        case ..<720: 20
        case ..<1_080: 30
        default: min(64, viewportWidth * 0.045)
        }
    }

    var contentWidth: CGFloat {
        max(300, viewportWidth - horizontalInset * 2)
    }

    var messageBubbleWidth: CGFloat {
        let ratio: CGFloat
        switch viewportWidth {
        case ..<640: ratio = 0.90
        case ..<900: ratio = 0.72
        case ..<1_280: ratio = 0.56
        default: ratio = 0.42
        }
        return min(620, max(290, contentWidth * ratio))
    }

    var maximumInteractiveCardWidth: CGFloat { min(540, contentWidth) }

    var topInset: CGFloat { viewportWidth < 720 ? 62 : 70 }
    var bottomInset: CGFloat { viewportWidth < 720 ? 24 : 32 }
}

struct VoiceChatView: View {
    @Bindable var controller: VoiceAgentController
    @AppStorage("TeddyVoiceSidebarWidthV2") private var sidebarWidth = 252.0
    @State private var isSidebarVisible = true
    @State private var isCompanionCreatorPresented = false
    @State private var inspectorSection: TeddyInspectorSection?
    @State private var revealedTranscriptIDs: Set<UUID> = []
    @State private var isStylePickerPresented = false
    @State private var isWorkspaceNameEditorPresented = false
    @State private var workspaceNameDraft = ""

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if isSidebarVisible {
                    ConversationSidebar(
                        controller: controller,
                        onCreateCompanion: presentCompanionCreator,
                        onHide: hideSidebar
                    )
                    .frame(width: resolvedSidebarWidth(in: geometry.size.width))
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(
                            width: $sidebarWidth,
                            maximumWidth: max(248, geometry.size.width - 640))
                            .offset(x: 1)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                detailPane
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.clear)
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .task { await controller.prepare() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if controller.isPushToTalkPressed { controller.releasePushToTalk() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshCompanionConversations()
            controller.warmSession()
        }
        .sheet(isPresented: $isCompanionCreatorPresented) {
            if let creator = controller.companionCreationView() {
                creator
            }
        }
    }

    private var detailPane: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    if controller.isInlineTerminalExpanded {
                        terminalStage
                            .transition(.opacity)
                    } else {
                        conversation
                            .transition(.opacity)
                        if let errorMessage = controller.errorMessage {
                            errorBanner(errorMessage)
                        }
                        composer
                    }
                }

                if !controller.isInlineTerminalExpanded {
                    WindowDragRegion()
                        .frame(height: 36)
                        .padding(.trailing, 58)
                }

                if !isSidebarVisible, !controller.isInlineTerminalExpanded {
                    TeddyFloatingSidebarButton(action: showSidebar)
                        .padding(.top, 39)
                        .padding(.leading, 13)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .transition(.scale.combined(with: .opacity))
                }

                workspaceChrome
                    .padding(.top, 8)
                    .padding(.trailing, 14)
                    .zIndex(20)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .background {
                TeddyGlassLayer(depth: .conversation)
            }

            if let inspectorSection {
                TeddyInspectorPanel(
                    controller: controller,
                    section: inspectorSection,
                    onClose: closeInspector)
                    .frame(width: 316)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.24), value: inspectorSection)
        .animation(.easeInOut(duration: 0.18), value: controller.isInlineTerminalExpanded)
    }

    private var terminalStage: some View {
        Group {
            if let terminal = controller.activeInlineTerminalView {
                terminal
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Ouverture de la session…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(TeddyPalette.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(TeddyPalette.terminalCanvas)
    }

    private var workspaceChrome: some View {
        HStack(spacing: 6) {
            if let companion = controller.activeCompanion {
                HStack(spacing: 6) {
                    if let avatar = controller.companionAvatarView(
                        for: companion.id,
                        width: 22
                    ) {
                        avatar
                            .frame(width: 22, height: 25)
                    } else {
                        CompanionAvatar(
                            provider: companion.provider,
                            phase: companion.phase,
                            size: 21)
                    }

                    Button {
                        workspaceNameDraft = companion.name
                        isWorkspaceNameEditorPresented = true
                    } label: {
                        HStack(spacing: 4) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(companion.name)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(TeddyPalette.primaryText)
                                    .lineLimit(1)
                                Text(activeCompanionPhaseLabel)
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(TeddyPalette.tertiaryText)
                                    .lineLimit(1)
                            }
                            Image(systemName: "pencil")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(TeddyPalette.tertiaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 106, alignment: .leading)
                    .popover(isPresented: $isWorkspaceNameEditorPresented, arrowEdge: .top) {
                        workspaceNameEditor(companionName: companion.name)
                    }
                }
                .padding(.leading, 5)
                .padding(.trailing, 4)

                Rectangle()
                    .fill(TeddyPalette.hairline)
                    .frame(width: 1, height: 24)

                Button(action: presentActiveCompanionDirectoryPicker) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                        Text(companion.projectName)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(TeddyPalette.secondaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 104)
                .help("Changer le dossier de \(companion.name)")

                Rectangle()
                    .fill(TeddyPalette.hairline)
                    .frame(width: 1, height: 24)
            }

            Button {
                isStylePickerPresented = false
                closeInspector()
                controller.toggleInlineTerminal()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: controller.isInlineTerminalExpanded
                        ? "waveform"
                        : "terminal")
                        .font(.system(size: 12.5, weight: .bold))
                    Text(controller.isInlineTerminalExpanded ? "Vocal" : "Terminal")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(TeddyPalette.primaryText)
                .padding(.horizontal, 12)
                .frame(minWidth: 94, minHeight: 34)
                .background(
                    Color.white.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 0.75)
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(controller.activeCompanion == nil)
            .opacity(controller.activeCompanion == nil ? 0.34 : 1)
            .help(controller.isInlineTerminalExpanded
                ? "Revenir au chat vocal"
                : "Ouvrir le terminal")

            Menu {
                Button("Session", systemImage: TeddyInspectorSection.session.symbol) {
                    selectInspector(.session)
                }
                Button("Réglages", systemImage: TeddyInspectorSection.settings.symbol) {
                    selectInspector(.settings)
                }
                Button(
                    controller.keepSessionActive ? "Ne plus maintenir actif" : "Rester actif",
                    systemImage: controller.keepSessionActive ? "pin.slash" : "pin"
                ) {
                    controller.toggleKeepSessionActive()
                }
                Divider()
                Button("Effacer le contexte Teddy", systemImage: "eraser") {
                    controller.clearTeddyContext()
                    revealedTranscriptIDs.removeAll()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TeddyPalette.secondaryText)
                    .frame(width: 30, height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .help("Actions de la conversation")
        }
        .padding(4)
        .background {
            TeddyGlassLayer(depth: .rail)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(TeddyPalette.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
        .onChange(of: controller.activeConversationID) { _, _ in
            isWorkspaceNameEditorPresented = false
        }
    }

    private func presentCompanionCreator() {
        guard controller.companionCreationView() != nil else {
            controller.startNewConversation()
            return
        }
        isCompanionCreatorPresented = true
    }

    private func workspaceNameEditor(companionName: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nom du doudou")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(TeddyPalette.primaryText)

            TextField(companionName, text: $workspaceNameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(commitWorkspaceName)

            HStack {
                Spacer()
                Button("Annuler") {
                    isWorkspaceNameEditorPresented = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(TeddyPalette.secondaryText)

                Button("Renommer", action: commitWorkspaceName)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(TeddyPalette.popover)
    }

    private func commitWorkspaceName() {
        let name = workspaceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        controller.renameActiveCompanion(to: name)
        isWorkspaceNameEditorPresented = false
    }

    private func presentActiveCompanionDirectoryPicker() {
        guard let companion = controller.activeCompanion else { return }
        let panel = NSOpenPanel()
        panel.title = "Choisir le dossier de \(companion.name)"
        panel.prompt = "Choisir"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: companion.directoryPath)

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let path = panel.url?.path else { return }
            controller.changeActiveCompanionDirectory(to: path)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private var activeCompanionPhaseLabel: String {
        switch controller.activeCompanion?.phase {
        case .idle: "prêt"
        case .working: "travaille"
        case .awaitingInput: "attend ta réponse"
        case .awaitingApproval: "accord requis"
        case .completed: "terminé"
        case .failed: "erreur"
        case .exited: "fermé"
        case nil: "local"
        }
    }

    private func resolvedSidebarWidth(in totalWidth: CGFloat) -> CGFloat {
        min(max(232, sidebarWidth), max(232, totalWidth - 680))
    }

    private func hideSidebar() {
        withAnimation(.snappy(duration: 0.24)) {
            isSidebarVisible = false
        }
    }

    private func showSidebar() {
        withAnimation(.snappy(duration: 0.24)) {
            isSidebarVisible = true
        }
    }

    private func selectInspector(_ section: TeddyInspectorSection) {
        if controller.isInlineTerminalExpanded {
            controller.collapseInlineTerminal()
        }
        withAnimation(.smooth(duration: 0.24)) {
            inspectorSection = inspectorSection == section ? nil : section
        }
    }

    private func closeInspector() {
        withAnimation(.smooth(duration: 0.24)) {
            inspectorSection = nil
        }
    }

    private var conversation: some View {
        GeometryReader { geometry in
            let layout = TeddyConversationLayout(viewportWidth: geometry.size.width)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 21) {
                        if controller.voiceMessages.isEmpty,
                           !showsPendingTeddy,
                           controller.pendingDirectorySelection == nil {
                            emptyConversation
                        }

                        ForEach(messageClusters) { cluster in
                            LazyVStack(spacing: 4) {
                                ForEach(Array(cluster.messages.enumerated()), id: \.element.id) { index, message in
                                    VoiceMessageRow(
                                        message: message,
                                        clusterPosition: cluster.position(at: index),
                                        bubbleWidth: layout.messageBubbleWidth,
                                        canReplay: controller.canReplayVoiceMessage(message.id),
                                        isPlaying: controller.playingMessageID == message.id,
                                        playbackProgress: controller.playbackProgress(for: message.id),
                                        showsTranscript: revealedTranscriptIDs.contains(message.id),
                                        onTogglePlayback: {
                                            controller.toggleVoiceMessagePlayback(message.id)
                                        },
                                        onToggleTranscript: {
                                            toggleTranscript(message.id)
                                        }
                                    )
                                    .id(message.id)
                                    .transition(messageInsertionTransition(for: message))
                                }
                            }
                        }

                        if let request = controller.pendingDirectorySelection {
                            TeddyDirectoryPickerCard(
                                request: request,
                                maximumWidth: layout.maximumInteractiveCardWidth,
                                onChoose: controller.chooseDirectoryForPendingDoudou,
                                onCancel: controller.cancelPendingDirectorySelection)
                                .id("directory-picker-\(request.id.uuidString)")
                                .transition(
                                    .opacity.combined(with: .scale(
                                        scale: 0.985,
                                        anchor: .leading)))
                        }

                        if showsPendingTeddy {
                            TeddyWaitingRow(
                                label: controller.activeCompanion?.phase == .working
                                    ? "\(controller.activeCompanion?.name ?? "La CLI") travaille"
                                    : "Teddy prépare la réponse")
                                .id("teddy-waiting")
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("conversation-bottom")
                    }
                    .frame(width: layout.contentWidth)
                    .padding(.horizontal, layout.horizontalInset)
                    .padding(.top, layout.topInset)
                    .padding(.bottom, layout.bottomInset)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .background(Color.clear)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.44), Color.black.opacity(0.12), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 42)
                    .allowsHitTesting(false)
                }
                .onChange(of: controller.voiceMessages.count) { _, _ in
                    withAnimation(.smooth(duration: 0.22)) {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: controller.state) { _, _ in
                    withAnimation(.smooth(duration: 0.22)) {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: controller.activeConversationID) { _, _ in
                    revealedTranscriptIDs.removeAll()
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
                .onChange(of: controller.pendingDirectorySelection?.id) { _, _ in
                    withAnimation(.smooth(duration: 0.22)) {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var messageClusters: [VoiceMessageCluster] {
        let maximumGap: TimeInterval = 120
        var clusters: [VoiceMessageCluster] = []

        for message in controller.voiceMessages {
            if let lastCluster = clusters.last,
               lastCluster.sender == message.sender,
               let previousMessage = lastCluster.messages.last {
                let gap = message.createdAt.timeIntervalSince(previousMessage.createdAt)
                if gap >= 0, gap <= maximumGap {
                    clusters[clusters.count - 1].messages.append(message)
                    continue
                }
            }
            clusters.append(VoiceMessageCluster(sender: message.sender, messages: [message]))
        }
        return clusters
    }

    private func messageInsertionTransition(for message: VoiceMessage) -> AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(
                    scale: 0.97,
                    anchor: message.sender == .user ? .trailing : .leading))
                .combined(with: .offset(y: 7)),
            removal: .opacity.combined(with: .scale(scale: 0.985)))
    }

    private var emptyConversation: some View {
        VStack(spacing: 18) {
            activeDoudouHero

            VStack(spacing: 7) {
                Text(controller.activeCompanion.map { "Parle à \($0.name)" }
                    ?? "Crée ton premier doudou")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(TeddyPalette.primaryText)
                Text(controller.activeCompanion == nil
                    ? "Chaque doudou devient une conversation et garde sa propre CLI."
                    : "Teddy te répond tout de suite, puis poursuit avec le résultat réel.")
                    .font(.system(size: 13))
                    .foregroundStyle(TeddyPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            if controller.activeCompanion == nil {
                Button {
                    presentCompanionCreator()
                } label: {
                    Label("Créer un doudou Codex", systemImage: "plus")
                }
                .buttonStyle(TeddyPrimaryActionButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 112)
        .padding(.bottom, 70)
    }

    @ViewBuilder
    private var activeDoudouHero: some View {
        if let companion = controller.activeCompanion,
           let avatar = controller.companionAvatarView(for: companion.id, width: 58) {
            avatar
                .frame(width: 58, height: 63)
        } else {
            CompanionAvatar(
                provider: controller.activeCompanion?.provider,
                phase: controller.activeCompanion?.phase,
                size: 54)
        }
    }

    private var composer: some View {
        composerInputRow
        .background {
            TeddyGlassLayer(depth: .composer)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(TeddyPalette.composerStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
        .frame(maxWidth: 960)
        .padding(.horizontal, 34)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private var composerInputRow: some View {
        HStack(spacing: 10) {
            if controller.isPushToTalkPressed {
                RecordingIndicator(level: controller.microphonePeakLevel)
            } else {
                TeddyStyleSelectorButton(style: controller.personalityStyle) {
                    isStylePickerPresented.toggle()
                }
                .popover(isPresented: $isStylePickerPresented, arrowEdge: .bottom) {
                    TeddyComposerStylePicker(
                        controller: controller,
                        onSelect: { style in
                            controller.selectPersonalityStyle(style)
                            isStylePickerPresented = false
                        },
                        onManage: {
                            isStylePickerPresented = false
                            selectInspector(.personality)
                        })
                }
            }

            if controller.isPushToTalkPressed {
                VoiceWaveformView(
                    samples: controller.recordingWaveform,
                    progress: 1,
                    playedColor: TeddyPalette.recording,
                    unplayedColor: TeddyPalette.recording.opacity(0.30),
                    isLive: true
                )
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                HStack(spacing: 7) {
                    if controller.isInlineTerminalExpanded {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(TeddyPalette.secondaryText)
                    }
                    Text(composerText)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(
                            controller.canPushToTalk
                                ? TeddyPalette.secondaryText
                                : TeddyPalette.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                ShortcutBadge()
            }

            HoldToTalkButton(
                isPressed: controller.isPushToTalkPressed,
                isEnabled: controller.canPushToTalk,
                level: controller.microphonePeakLevel,
                onPress: {
                    isStylePickerPresented = false
                    controller.pressPushToTalk()
                },
                onRelease: controller.releasePushToTalk)
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, minHeight: 49)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(TeddyPalette.warning)
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(TeddyPalette.primaryText)
                .lineLimit(2)
            Spacer()
            if !controller.hasCredential {
                Button("Réessayer") {
                    controller.prepareCredential(forceReload: true)
                    Task { await controller.prepare() }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(TeddyPalette.warning.opacity(0.10))
    }

    private var showsPendingTeddy: Bool {
        guard controller.pendingDirectorySelection == nil else { return false }
        guard controller.isAwaitingResponse else { return false }
        guard let phase = controller.voiceMessages.last?.phase else { return true }
        return phase != .buffering && phase != .playing
    }

    private var composerText: String {
        if controller.pendingDirectorySelection != nil {
            return "Choisis un dossier, ou maintiens pour annuler et reparler"
        }
        if controller.isLoadingConversation { return "Ouverture de la conversation…" }
        if controller.isCompanionMode, controller.activeCompanion == nil {
            return "Crée un doudou pour commencer"
        }
        if let companion = controller.activeCompanion, !companion.isCLIReady {
            return "Cette conversation n’a pas encore de CLI active"
        }
        if controller.activeCompanion?.phase == .working {
            return "\(controller.activeCompanion?.name ?? "La CLI") travaille…"
        }
        if !controller.canPushToTalk { return "Teddy se prépare…" }
        if controller.state == .speaking { return "Maintiens pour interrompre Teddy" }
        if controller.isAwaitingResponse { return "Teddy prépare sa réponse…" }
        if controller.isInlineTerminalExpanded { return "Session ouverte · maintiens pour parler à Teddy" }
        return "Maintiens pour parler, relâche pour envoyer"
    }

    private func toggleTranscript(_ id: UUID) {
        withAnimation(.smooth(duration: 0.22)) {
            if revealedTranscriptIDs.contains(id) {
                revealedTranscriptIDs.remove(id)
            } else {
                revealedTranscriptIDs.insert(id)
            }
        }
    }
}

private struct TeddyDirectoryPickerCard: View {
    let request: TeddyDirectorySelectionRequest
    let maximumWidth: CGFloat
    let onChoose: (String) -> Void
    let onCancel: () -> Void

    @State private var currentPath: String
    @State private var folders: [TeddyDirectoryBrowserItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    init(
        request: TeddyDirectorySelectionRequest,
        maximumWidth: CGFloat,
        onChoose: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.maximumWidth = maximumWidth
        self.onChoose = onChoose
        self.onCancel = onCancel
        _currentPath = State(initialValue: request.initialDirectoryPath)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                pathBar
                folderList
                footer
            }
            .frame(width: max(300, maximumWidth))
            .background(
                LinearGradient(
                    colors: [TeddyPalette.assistantBubbleTop, TeddyPalette.assistantBubbleBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(TeddyPalette.surfaceStroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.20), radius: 14, y: 5)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: currentPath) {
            await loadCurrentDirectory()
        }
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(TeddyPalette.accent.opacity(0.12))
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TeddyPalette.accentLight)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Où est-ce qu’on ouvre ton doudou ?")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(TeddyPalette.primaryText)
                Text(
                    request.cli == "codex"
                        ? "Codex démarrera dans ce dossier."
                        : "Le terminal s’ouvrira dans ce dossier."
                )
                    .font(.system(size: 11.5))
                    .foregroundStyle(TeddyPalette.secondaryText)
            }

            Spacer()

            Text(request.cli == "codex" ? "CODEX" : "TERMINAL")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.55)
                .foregroundStyle(TeddyPalette.accentLight)
                .padding(.horizontal, 8)
                .frame(height: 23)
                .background(TeddyPalette.accent.opacity(0.10), in: Capsule())
                .overlay { Capsule().stroke(TeddyPalette.accent.opacity(0.16), lineWidth: 1) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            directoryNavigationButton(
                icon: "house.fill",
                help: "Dossier personnel",
                isEnabled: currentPath != homePath
            ) {
                currentPath = homePath
            }

            directoryNavigationButton(
                icon: "chevron.left",
                help: "Dossier parent",
                isEnabled: TeddyDirectoryBrowser.parentPath(of: currentPath) != nil
            ) {
                if let parent = TeddyDirectoryBrowser.parentPath(of: currentPath) {
                    currentPath = parent
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(TeddyPalette.accent)
                Text(TeddyDirectoryBrowser.displayPath(currentPath, homePath: homePath))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(TeddyPalette.primaryText.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.white.opacity(0.032), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TeddyPalette.hairline, lineWidth: 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private var folderList: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.18))

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(TeddyPalette.accent)
            } else if let errorMessage {
                VStack(spacing: 7) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(TeddyPalette.tertiaryText)
                    Text(errorMessage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(TeddyPalette.secondaryText)
                }
            } else if folders.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "folder")
                        .foregroundStyle(TeddyPalette.tertiaryText)
                    Text("Aucun sous-dossier")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(TeddyPalette.secondaryText)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(folders) { folder in
                            TeddyDirectoryRow(folder: folder) {
                                currentPath = folder.path
                            }
                        }
                    }
                    .padding(5)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(height: 194)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(TeddyPalette.hairline, lineWidth: 1)
        }
        .padding(.horizontal, 14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Annuler", action: onCancel)
                .buttonStyle(TeddySecondaryActionButtonStyle())

            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(URL(fileURLWithPath: currentPath).lastPathComponent.isEmpty
                    ? "/"
                    : URL(fileURLWithPath: currentPath).lastPathComponent)
                    .lineLimit(1)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(TeddyPalette.tertiaryText)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(TeddyPalette.control, in: Capsule())

            Spacer(minLength: 6)

            Button {
                onChoose(currentPath)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: request.cli == "codex" ? "sparkles" : "terminal")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(request.cli == "codex" ? "Ouvrir Codex ici" : "Ouvrir le terminal ici")
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            .buttonStyle(TeddyPrimaryActionButtonStyle())
            .disabled(errorMessage != nil || isLoading)
        }
        .padding(14)
    }

    private func directoryNavigationButton(
        icon: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(TeddyPalette.secondaryText)
                .frame(width: 30, height: 30)
                .background(TeddyPalette.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(TeddyPalette.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.32)
        .help(help)
    }

    private func loadCurrentDirectory() async {
        isLoading = true
        errorMessage = nil
        let snapshot = await TeddyDirectoryBrowser.snapshot(at: currentPath)
        guard !Task.isCancelled, snapshot.path == URL(
            fileURLWithPath: currentPath).standardizedFileURL.path
        else { return }
        folders = snapshot.folders
        errorMessage = snapshot.errorMessage
        isLoading = false
    }
}

private struct TeddyDirectoryRow: View {
    let folder: TeddyDirectoryBrowserItem
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TeddyPalette.accent.opacity(isHovering ? 0.96 : 0.76))
                    .frame(width: 18)
                Text(folder.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TeddyPalette.primaryText.opacity(isHovering ? 1 : 0.88))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(TeddyPalette.tertiaryText)
                    .offset(x: isHovering ? 1.5 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 35)
            .background(
                Color.white.opacity(isHovering ? 0.065 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.13), value: isHovering)
        .accessibilityLabel("Ouvrir le dossier \(folder.name)")
    }
}

private struct TeddyPrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(TeddyPalette.ink)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(
                LinearGradient(
                    colors: [TeddyPalette.accentLight, TeddyPalette.accentDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.13), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct TeddySecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(TeddyPalette.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(TeddyPalette.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(TeddyPalette.hairline, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
    }
}

private struct ConversationSidebar: View {
    @Bindable var controller: VoiceAgentController
    let onCreateCompanion: () -> Void
    let onHide: () -> Void
    @State private var hoveredConversationID: UUID?
    @State private var searchText = ""

    private var visibleConversations: [VoiceConversationSummary] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return controller.conversationSummaries
        }
        return controller.conversationSummaries.filter {
            $0.title.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarTopBar

            VStack(spacing: 2) {
                SidebarNavigationButton(
                    title: "Nouveau doudou",
                    systemName: "plus"
                ) { onCreateCompanion() }

                SidebarSearchField(text: $searchText)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 13)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text("CONVERSATIONS")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.65)
                        .foregroundStyle(TeddyPalette.tertiaryText)
                        .padding(.horizontal, 9)
                        .padding(.top, 5)
                        .padding(.bottom, 6)

                    ForEach(visibleConversations) { conversation in
                        ConversationSidebarRow(
                            conversation: conversation,
                            companion: controller.companionSnapshot(for: conversation.id),
                            companionAvatar: controller.companionAvatarView(
                                for: conversation.id,
                                width: 29),
                            isSelected: conversation.id
                                == (controller.loadingConversationID ?? controller.activeConversationID),
                            isHovering: hoveredConversationID == conversation.id,
                            isLoading: controller.isLoadingConversation
                                && conversation.id == controller.loadingConversationID,
                            onSelect: { controller.selectConversation(conversation.id) },
                            onDelete: { controller.deleteConversation(conversation.id) }
                        )
                        .onHover { hovering in
                            hoveredConversationID = hovering ? conversation.id : nil
                        }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            sidebarFooter
        }
        .background {
            TeddyGlassLayer(depth: .sidebar)
        }
    }

    private var sidebarTopBar: some View {
        ZStack {
            WindowDragRegion()

            HStack(spacing: 4) {
                Text("Teddy CLI")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TeddyPalette.primaryText)

                Spacer(minLength: 4)

                HeaderActionButton(
                    systemName: "square.and.pencil",
                    help: "Nouveau doudou"
                ) { onCreateCompanion() }

                HeaderActionButton(
                    systemName: "sidebar.left",
                    help: "Masquer la barre latérale",
                    action: onHide
                )
            }
            .padding(.leading, 80)
            .padding(.trailing, 8)
            .padding(.top, 1)
        }
        .frame(height: 52)
        .background(Color.clear)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 9) {
            TeddyAvatar(size: 28, isActive: controller.state == .speaking)

            VStack(alignment: .leading, spacing: 1) {
                Text("Teddy CLI")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TeddyPalette.secondaryText)

                HStack(spacing: 5) {
                    Circle()
                        .fill(controller.canPushToTalk ? TeddyPalette.online : TeddyPalette.tertiaryText)
                        .frame(width: 4.5, height: 4.5)
                    Text(sidebarFooterCaption)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(TeddyPalette.tertiaryText)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 13)
        .frame(height: 52)
        .background(Color.clear)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TeddyPalette.hairline)
                .frame(height: 1)
        }
    }

    private var sidebarFooterCaption: String {
        guard !controller.companions.isEmpty else { return "Aucun doudou" }
        let plural = controller.companions.count > 1 ? "s" : ""
        return "\(controller.companions.count) session\(plural) locale\(plural)"
    }
}

private struct SidebarNavigationButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TeddyPalette.secondaryText)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(TeddyPalette.secondaryText)

                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(
                Color.white.opacity(isHovering ? 0.045 : 0),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(TeddyPalette.tertiaryText)
                .frame(width: 18)

            TextField("Rechercher", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(TeddyPalette.primaryText)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(TeddyPalette.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ConversationSidebarRow: View {
    let conversation: VoiceConversationSummary
    let companion: TeddyCompanionSnapshot?
    let companionAvatar: AnyView?
    let isSelected: Bool
    let isHovering: Bool
    let isLoading: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            ConversationThreadIcon(
                companionAvatar: companionAvatar,
                isSelected: isSelected,
                phase: companion?.phase)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? TeddyPalette.primaryText : TeddyPalette.secondaryText)
                    .lineLimit(1)

                Text(companionSubtitle)
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(TeddyPalette.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 5)

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.72)
            } else if isHovering {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TeddyPalette.tertiaryText)
            } else {
                Circle()
                    .fill(phaseColor)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 48)
        .contentShape(Rectangle())
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Ouvrir", systemImage: "message") { onSelect() }
                .disabled(isSelected)
            Divider()
            Button("Effacer le contexte Teddy", systemImage: "eraser") { onDelete() }
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.white.opacity(0.075) }
        if isHovering { return Color.white.opacity(0.035) }
        return .clear
    }

    private var companionSubtitle: String {
        guard let companion else { return "Conversation locale" }
        let provider = companion.provider == "terminal"
            ? "Session"
            : companion.provider.capitalized
        return "\(provider) · \(companion.projectName) · \(phaseLabel)"
    }

    private var phaseLabel: String {
        switch companion?.phase {
        case .idle: "prêt"
        case .working: "travaille"
        case .awaitingInput: "attend"
        case .awaitingApproval: "accord requis"
        case .completed: "terminé"
        case .failed: "erreur"
        case .exited: "fermé"
        case nil: "local"
        }
    }

    private var phaseColor: Color {
        switch companion?.phase {
        case .idle, .completed: TeddyPalette.online
        case .working: TeddyPalette.warning
        case .awaitingInput, .awaitingApproval: TeddyPalette.accent
        case .failed, .exited: TeddyPalette.recording
        case nil: TeddyPalette.tertiaryText
        }
    }
}

private struct ConversationThreadIcon: View {
    let companionAvatar: AnyView?
    let isSelected: Bool
    let phase: TeddyCompanionSnapshot.Phase?

    var body: some View {
        Group {
            if let companionAvatar {
                companionAvatar
                    .frame(width: 29, height: 32)
            } else {
                Image(systemName: phase == .working ? "ellipsis" : "message.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isSelected ? TeddyPalette.primaryText : TeddyPalette.tertiaryText)
                    .frame(width: 22, height: 26)
                    .background(
                        Color.white.opacity(isSelected ? 0.075 : 0.035),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(width: 31, height: 34)
    }
}

private struct SidebarResizeHandle: View {
    @Binding var width: Double
    let maximumWidth: CGFloat

    @State private var dragOrigin: Double?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color.white.opacity(isHovering ? 0.10 : 0.045))
                .frame(width: 1)
        }
        .frame(width: 3)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = width }
                    let upperBound = min(310, Double(maximumWidth))
                    width = min(max(232, (dragOrigin ?? width) + value.translation.width), upperBound)
                }
                .onEnded { _ in dragOrigin = nil }
        )
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel("Redimensionner la barre latérale")
    }
}

private struct HeaderActionButton: View {
    let systemName: String
    let help: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    init(
        systemName: String,
        help: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isActive ? TeddyPalette.primaryText : TeddyPalette.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    Color.white.opacity(isActive ? 0.10 : (isHovering ? 0.065 : 0)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(help)
    }
}

private struct TeddyFloatingSidebarButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TeddyPalette.secondaryText)
                .frame(width: 32, height: 32)
                .background {
                    TeddyGlassLayer(depth: .rail)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(TeddyPalette.hairline, lineWidth: 1)
                }
                .opacity(isHovering ? 1 : 0.82)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("Afficher les conversations")
    }
}

private struct TeddyStyleSelectorButton: View {
    let style: TeddyPersonalityStyle
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: styleSymbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(style.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(TeddyPalette.tertiaryText)
            }
            .foregroundStyle(TeddyPalette.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                Color.white.opacity(isHovering ? 0.085 : 0.050),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(isHovering ? 0.11 : 0.065), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("Style vocal : \(style.name)")
        .accessibilityLabel("Choisir le style de Teddy")
    }

    private var styleSymbol: String {
        switch style.id {
        case "builtin.complice": "face.smiling"
        case "builtin.direct": "bolt"
        case "builtin.calme": "wind"
        case "builtin.energique": "sparkles"
        case TeddyPersonalityStyle.none.id: "waveform"
        default: "slider.horizontal.2.square"
        }
    }
}

private struct TeddyComposerStylePicker: View {
    @Bindable var controller: VoiceAgentController
    let onSelect: (TeddyPersonalityStyle) -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Style de Teddy")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TeddyPalette.primaryText)
                Text("L’identité de base reste toujours la même.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(TeddyPalette.tertiaryText)
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)
            .padding(.bottom, 9)

            VStack(spacing: 3) {
                ForEach(controller.availablePersonalityStyles) { style in
                    TeddyComposerStyleRow(
                        style: style,
                        isSelected: controller.personalityStyle.id == style.id,
                        onSelect: { onSelect(style) })
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 7)

            Rectangle()
                .fill(TeddyPalette.hairline)
                .frame(height: 1)

            Button(action: onManage) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Créer ou modifier mes styles")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(TeddyPalette.tertiaryText)
                }
                .foregroundStyle(TeddyPalette.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 304)
        .background(TeddyPalette.popover)
        .preferredColorScheme(.dark)
    }
}

private struct TeddyComposerStyleRow: View {
    let style: TeddyPersonalityStyle
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: styleSymbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isSelected ? TeddyPalette.ink : TeddyPalette.secondaryText)
                    .frame(width: 29, height: 29)
                    .background(
                        isSelected
                            ? TeddyPalette.primaryText
                            : Color.white.opacity(isHovering ? 0.085 : 0.045),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(style.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(TeddyPalette.primaryText)
                    Text(style.summary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(TeddyPalette.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(TeddyPalette.primaryText)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 43)
            .background(
                Color.white.opacity(isSelected ? 0.075 : (isHovering ? 0.045 : 0)),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var styleSymbol: String {
        switch style.id {
        case "builtin.complice": "face.smiling"
        case "builtin.direct": "bolt"
        case "builtin.calme": "wind"
        case "builtin.energique": "sparkles"
        case TeddyPersonalityStyle.none.id: "waveform"
        default: "slider.horizontal.2.square"
        }
    }
}

private struct TeddyInspectorPanel: View {
    @Bindable var controller: VoiceAgentController
    let section: TeddyInspectorSection
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TeddyPalette.secondaryText)
                    .frame(width: 26, height: 26)

                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TeddyPalette.primaryText)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(TeddyPalette.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(TeddyPalette.control, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Fermer")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.top, 1)
            .frame(height: 52)

            Rectangle()
                .fill(TeddyPalette.hairline)
                .frame(height: 1)

            Group {
                switch section {
                case .session:
                    TeddySessionInspector(controller: controller)
                case .personality:
                    TeddyPersonalityPanel(controller: controller, displaysHeader: false)
                case .settings:
                    TeddyVoiceSettingsInspector(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background {
            TeddyGlassLayer(depth: .inspector)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(TeddyPalette.hairline)
                .frame(width: 1)
        }
    }
}

private struct TeddySessionInspector: View {
    @Bindable var controller: VoiceAgentController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let companion = controller.activeCompanion {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 11) {
                            if let avatar = controller.companionAvatarView(
                                for: companion.id,
                                width: 38
                            ) {
                                avatar
                                    .frame(width: 38, height: 42)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(companion.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(TeddyPalette.primaryText)
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(phaseColor(companion.phase))
                                        .frame(width: 6, height: 6)
                                    Text(phaseLabel(companion.phase))
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(TeddyPalette.tertiaryText)
                                }
                            }
                        }

                        Text("\(providerName(companion)) · \(companion.projectName)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(TeddyPalette.secondaryText)
                    }

                    InspectorActionRow(
                        title: controller.isInlineTerminalExpanded
                            ? "Revenir au vocal"
                            : "Afficher la session",
                        detail: controller.isInlineTerminalExpanded
                            ? "Retrouver la conversation"
                            : "Prend tout l’espace central",
                        systemName: controller.isInlineTerminalExpanded ? "waveform" : "terminal",
                        action: controller.toggleInlineTerminal)

                    Toggle(isOn: keepActiveBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Maintenir Teddy actif")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(TeddyPalette.primaryText)
                            Text("Évite la mise en veille automatique")
                                .font(.system(size: 10))
                                .foregroundStyle(TeddyPalette.tertiaryText)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(TeddyPalette.primaryText.opacity(0.78))

                    if companion.phase == .working {
                        InspectorActionRow(
                            title: "Interrompre",
                            detail: "Arrête le travail en cours",
                            systemName: "stop.fill",
                            action: controller.interruptActiveCompanion)
                    }

                    InspectorActionRow(
                        title: "Effacer le contexte Teddy",
                        detail: "La session de travail reste intacte",
                        systemName: "eraser",
                        action: { controller.clearTeddyContext() })
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aucune conversation active")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TeddyPalette.primaryText)
                        Text("Crée un doudou depuis la barre latérale pour commencer.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(TeddyPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }

    private var keepActiveBinding: Binding<Bool> {
        Binding(
            get: { controller.keepSessionActive },
            set: { value in
                if value != controller.keepSessionActive {
                    controller.toggleKeepSessionActive()
                }
            })
    }

    private func providerName(_ companion: TeddyCompanionSnapshot) -> String {
        companion.provider == "terminal" ? "Session" : companion.provider.capitalized
    }

    private func phaseLabel(_ phase: TeddyCompanionSnapshot.Phase) -> String {
        switch phase {
        case .idle: "Prêt"
        case .working: "Travail en cours"
        case .awaitingInput: "Attend ta réponse"
        case .awaitingApproval: "Attend ton accord"
        case .completed: "Terminé"
        case .failed: "Une erreur est survenue"
        case .exited: "Session fermée"
        }
    }

    private func phaseColor(_ phase: TeddyCompanionSnapshot.Phase) -> Color {
        switch phase {
        case .idle, .completed: TeddyPalette.online
        case .working: TeddyPalette.warning
        case .awaitingInput, .awaitingApproval: TeddyPalette.accent
        case .failed, .exited: TeddyPalette.recording
        }
    }
}

private struct TeddyVoiceSettingsInspector: View {
    @Bindable var controller: VoiceAgentController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                inspectorSection("VOIX") {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 7
                    ) {
                        ForEach(controller.availableVoices) { voice in
                            Button {
                                controller.selectedVoice = voice.voiceID
                            } label: {
                                Text(voice.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(
                                        controller.selectedVoice == voice.voiceID
                                            ? TeddyPalette.primaryText
                                            : TeddyPalette.secondaryText)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 31)
                                    .background(
                                        Color.white.opacity(
                                            controller.selectedVoice == voice.voiceID ? 0.11 : 0.035),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                inspectorSection("RYTHME") {
                    HStack {
                        Text("Vitesse")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(TeddyPalette.secondaryText)
                        Spacer()
                        Text(String(format: "%.2f×", controller.outputSpeed))
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(TeddyPalette.primaryText)
                    }
                    Slider(value: $controller.outputSpeed, in: 0.7 ... 1.5, step: 0.05)
                        .tint(TeddyPalette.primaryText)
                }

                inspectorSection("LONGUEUR") {
                    Picker("Durée", selection: $controller.responseDurationMode) {
                        ForEach(ResponseDurationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    durationControls

                    let saving = controller.savingsProjection.outputSavingsPercent
                    Text(saving >= 1
                        ? "Environ \(Int(saving.rounded())) % d’audio en moins"
                        : "Réponse naturelle sans économie estimée")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(TeddyPalette.tertiaryText)
                }

                inspectorSection("INTERPRÉTATION") {
                    Picker("Expression", selection: $controller.expressionStyle) {
                        ForEach(VoiceExpressionStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var durationControls: some View {
        switch controller.responseDurationMode {
        case .natural:
            EmptyView()
        case .range:
            durationSlider(
                title: "Minimum",
                value: $controller.minimumResponseSeconds,
                range: 1 ... 30)
            durationSlider(
                title: "Maximum",
                value: $controller.maximumResponseSeconds,
                range: 1 ... 45)
        case .fixed:
            durationSlider(
                title: "Durée",
                value: $controller.fixedResponseSeconds,
                range: 1 ... 30)
        }
    }

    private func durationSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded())) s")
                    .monospacedDigit()
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(TeddyPalette.secondaryText)

            Slider(value: value, in: range, step: 1)
                .tint(TeddyPalette.primaryText)
        }
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.65)
                .foregroundStyle(TeddyPalette.tertiaryText)
            content()
        }
    }
}

private struct InspectorActionRow: View {
    let title: String
    let detail: String
    let systemName: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TeddyPalette.secondaryText)
                    .frame(width: 25, height: 25)
                    .background(TeddyPalette.control, in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(TeddyPalette.primaryText)
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(TeddyPalette.tertiaryText)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(TeddyPalette.tertiaryText)
            }
            .padding(.horizontal, 9)
            .frame(height: 48)
            .background(
                Color.white.opacity(isHovering ? 0.06 : 0.03),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private enum TeddyGlassDepth: Equatable {
    case conversation
    case sidebar
    case inspector
    case rail
    case composer

    var material: NSVisualEffectView.Material {
        switch self {
        case .conversation: .underWindowBackground
        case .sidebar: .sidebar
        case .inspector, .rail, .composer: .hudWindow
        }
    }

    var blendingMode: NSVisualEffectView.BlendingMode {
        switch self {
        case .conversation, .sidebar: .behindWindow
        case .inspector, .rail, .composer: .withinWindow
        }
    }

    var blackTint: Double {
        switch self {
        case .conversation: 0.76
        case .sidebar: 0.63
        case .inspector: 0.76
        case .rail: 0.70
        case .composer: 0.42
        }
    }

    var whiteLift: Double {
        self == .composer ? 0.075 : 0
    }
}

private struct TeddyGlassLayer: View {
    let depth: TeddyGlassDepth

    var body: some View {
        ZStack {
            TeddyVisualEffectView(
                material: depth.material,
                blendingMode: depth.blendingMode)
            Color.black.opacity(depth.blackTint)
            if depth.whiteLift > 0 {
                Color.white.opacity(depth.whiteLift)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TeddyVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
    }
}

private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TeddyWindowDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TeddyWindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private struct VoiceMessageRow: View {
    let message: VoiceMessage
    var clusterPosition: VoiceMessageClusterPosition = .single
    let bubbleWidth: CGFloat
    let canReplay: Bool
    let isPlaying: Bool
    let playbackProgress: Double
    let showsTranscript: Bool
    let onTogglePlayback: () -> Void
    let onToggleTranscript: () -> Void

    @State private var showsActions = false
    @State private var isHovering = false

    private var isUser: Bool { message.sender == .user }
    private var isLive: Bool { message.phase == .buffering || message.phase == .playing }

    var body: some View {
        messageContent
            .overlay(alignment: isUser ? .bottomLeading : .bottomTrailing) {
                messageActionReveal
                    .offset(x: isUser ? -36 : 36)
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.16), value: isHovering)
    }

    private var messageContent: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 0) {
            HStack(spacing: 9) {
                playbackControl

                VoiceWaveformView(
                    samples: message.waveform,
                    progress: effectiveProgress,
                    playedColor: isUser ? .white : TeddyPalette.accent,
                    unplayedColor: isUser
                        ? Color.white.opacity(0.54)
                        : Color.white.opacity(0.34),
                    isLive: isLive
                )
                .frame(maxWidth: .infinity)
                .frame(height: 38)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: bubbleWidth)
            .frame(minHeight: 52)
            .background(bubbleFill, in: bubbleShape)
            .overlay {
                bubbleShape.stroke(bubbleStroke, lineWidth: 0.75)
            }
            .shadow(color: bubbleShadow, radius: isHovering ? 4 : 2, y: isHovering ? 2 : 1)

            if showsTranscript, !message.transcript.isEmpty {
                Text(message.transcript)
                    .font(.system(size: 12.5))
                    .foregroundStyle(TeddyPalette.primaryText.opacity(0.92))
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: min(520, bubbleWidth), alignment: .leading)
                    .background(
                        TeddyPalette.transcript,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(TeddyPalette.hairline, lineWidth: 1)
                    }
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.42) {
            showsActions = true
        }
        .contextMenu { menuActions }
        .popover(isPresented: $showsActions, arrowEdge: isUser ? .trailing : .leading) {
            actionsPopover
        }
    }

    private var messageActionReveal: some View {
        Button {
            showsActions = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(TeddyPalette.secondaryText)
                .frame(width: 27, height: 27)
                .background(TeddyPalette.control, in: Circle())
                .overlay { Circle().stroke(TeddyPalette.hairline, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0)
        .scaleEffect(isHovering ? 1 : 0.88)
        .allowsHitTesting(isHovering)
        .help("Actions du message")
    }

    private var playbackControl: some View {
        Button(action: onTogglePlayback) {
            ZStack {
                Circle()
                    .fill(playButtonFill)
                Circle()
                    .stroke(Color.white.opacity(isUser ? 0.10 : 0.055), lineWidth: 1)

                if message.phase == .buffering {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isUser ? .white : TeddyPalette.accent)
                        .scaleEffect(0.72)
                } else {
                    Image(systemName: playbackIcon)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(isUser ? .white : TeddyPalette.accent)
                        .offset(x: playbackIcon == "play.fill" ? 1 : 0)
                }
            }
            .frame(width: 34, height: 34)
            .scaleEffect(isHovering && canReplay ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!canReplay || isLive)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .accessibilityLabel(isPlaying ? "Arrêter la lecture" : "Lire le message vocal")
    }

    private var effectiveProgress: Double {
        if message.phase == .buffering { return 0 }
        if message.phase == .playing, playbackProgress == 0 { return 0.08 }
        return playbackProgress
    }

    private var playbackIcon: String {
        if isPlaying { return "pause.fill" }
        if message.phase == .playing { return "speaker.wave.2.fill" }
        return "play.fill"
    }

    @ViewBuilder
    private var menuActions: some View {
        Button(isPlaying ? "Arrêter" : "Réécouter", systemImage: isPlaying ? "pause.fill" : "play.fill") {
            onTogglePlayback()
        }
        .disabled(!canReplay || isLive)

        Button(
            showsTranscript ? "Masquer la transcription" : "Afficher la transcription",
            systemImage: showsTranscript ? "text.badge.minus" : "text.badge.plus"
        ) {
            onToggleTranscript()
        }
        .disabled(message.transcript.isEmpty)

        Button("Copier la transcription", systemImage: "doc.on.doc") {
            copyTranscript()
        }
        .disabled(message.transcript.isEmpty)
    }

    private var actionsPopover: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(isUser ? "Ton message vocal" : "Réponse de Teddy")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TeddyPalette.primaryText)
                Spacer()
                Text(formatVoiceDuration(message.durationSeconds))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(TeddyPalette.tertiaryText)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 5)

            MessageActionButton(
                title: isPlaying ? "Arrêter la lecture" : "Réécouter",
                icon: isPlaying ? "pause.fill" : "play.fill",
                isEnabled: canReplay && !isLive
            ) {
                showsActions = false
                onTogglePlayback()
            }

            MessageActionButton(
                title: showsTranscript ? "Masquer le texte" : "Afficher le texte",
                icon: showsTranscript ? "text.badge.minus" : "text.badge.plus",
                isEnabled: !message.transcript.isEmpty
            ) {
                showsActions = false
                onToggleTranscript()
            }

            MessageActionButton(
                title: "Copier le texte",
                icon: "doc.on.doc",
                isEnabled: !message.transcript.isEmpty
            ) {
                showsActions = false
                copyTranscript()
            }
        }
        .padding(8)
        .frame(width: 228)
        .background(TeddyPalette.popover)
    }

    private func copyTranscript() {
        guard !message.transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.transcript, forType: .string)
    }

    private var playButtonFill: LinearGradient {
        let colors = isUser
            ? [Color.white.opacity(0.17), Color.white.opacity(0.11)]
            : [Color.white.opacity(0.095), Color.white.opacity(0.055)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var bubbleFill: LinearGradient {
        LinearGradient(
            colors: isUser
                ? [TeddyPalette.userBubbleTop, TeddyPalette.userBubbleBottom]
                : [TeddyPalette.assistantBubbleTop, TeddyPalette.assistantBubbleBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    private var bubbleStroke: Color {
        if isLive { return TeddyPalette.accent.opacity(0.30) }
        return isUser ? Color.white.opacity(0.075) : TeddyPalette.surfaceStroke
    }

    private var bubbleShadow: Color {
        .black.opacity(isUser ? 0.20 : 0.13)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let radii = bubbleRadii
        return UnevenRoundedRectangle(
            topLeadingRadius: radii.topLeading,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: radii.topTrailing,
            style: .continuous
        )
    }

    private var bubbleRadii: VoiceBubbleRadii {
        switch clusterPosition {
        case .single:
            return isUser
                ? VoiceBubbleRadii(topLeading: 16, bottomLeading: 16, bottomTrailing: 5, topTrailing: 16)
                : VoiceBubbleRadii(topLeading: 16, bottomLeading: 5, bottomTrailing: 16, topTrailing: 16)
        case .first:
            return VoiceBubbleRadii(topLeading: 16, bottomLeading: 7, bottomTrailing: 7, topTrailing: 16)
        case .middle:
            return VoiceBubbleRadii(topLeading: 7, bottomLeading: 7, bottomTrailing: 7, topTrailing: 7)
        case .last:
            return isUser
                ? VoiceBubbleRadii(topLeading: 7, bottomLeading: 16, bottomTrailing: 5, topTrailing: 7)
                : VoiceBubbleRadii(topLeading: 7, bottomLeading: 5, bottomTrailing: 16, topTrailing: 7)
        }
    }
}

private struct VoiceWaveformView: View {
    let samples: [Double]
    let progress: Double
    let playedColor: Color
    let unplayedColor: Color
    var isLive = false

    var body: some View {
        Group {
            if isLive, samples.isEmpty {
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    waveformCanvas(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                waveformCanvas(at: 0)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityHidden(true)
    }

    private func waveformCanvas(at time: TimeInterval) -> some View {
        Canvas(
            opaque: false,
            colorMode: .linear,
            rendersAsynchronously: !isLive
        ) { context, size in
            let count = max(28, min(72, Int(size.width / 5.4)))
            let values = resampled(to: count, at: time)
            let pitch = size.width / CGFloat(count)
            let barWidth = min(2.8, max(1.8, pitch * 0.38))
            let centerY = size.height / 2
            let renderedProgress = progress.teddyClamped(to: 0 ... 1)

            for index in 0 ..< count {
                let source = values[index].teddyClamped(to: 0 ... 1)
                let edgePosition = Double(index) / Double(max(1, count - 1))
                let edgeEnvelope = 0.82 + 0.18 * pow(sin(.pi * edgePosition), 0.62)
                let perceived = pow(source, 0.72) * edgeEnvelope
                let height = max(3, size.height * (0.075 + perceived * 0.78))
                let barOriginX = CGFloat(index) * pitch + (pitch - barWidth) / 2
                let rect = CGRect(
                    x: barOriginX,
                    y: centerY - height / 2,
                    width: barWidth,
                    height: height)
                let threshold = (Double(index) + 0.5) / Double(count)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(renderedProgress >= threshold ? playedColor : unplayedColor))
            }
        }
    }

    private func resampled(to count: Int, at time: TimeInterval) -> [Double] {
        guard !samples.isEmpty else {
            return (0 ..< count).map { index in
                guard isLive else { return 0.06 }
                return 0.12 + 0.22 * abs(sin(time * 3.2 + Double(index) * 0.44))
            }
        }

        let interpolated = (0 ..< count).map { bucket in
            let position = Double(bucket) * Double(max(0, samples.count - 1)) / Double(max(1, count - 1))
            let lower = Int(position.rounded(.down))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = position - Double(lower)
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }

        return interpolated.indices.map { index in
            let previous = interpolated[max(0, index - 1)]
            let current = interpolated[index]
            let next = interpolated[min(interpolated.count - 1, index + 1)]
            return previous * 0.20 + current * 0.60 + next * 0.20
        }
    }
}

private struct TeddyWaitingRow: View {
    let label: String

    var body: some View {
        HStack {
            HStack(spacing: 9) {
                TeddyAvatar(size: 28, isActive: true)
                AnimatedThinkingWaveform()
                    .frame(width: 54, height: 24)
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(TeddyPalette.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .background(TeddyPalette.assistantBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(TeddyPalette.surfaceStroke, lineWidth: 1)
            }

            Spacer(minLength: 96)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TeddyPersonalityPanel: View {
    @Bindable var controller: VoiceAgentController
    let displaysHeader: Bool
    @State private var isCreating = false
    @State private var styleName = ""
    @State private var styleDescription = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if displaysHeader {
                HStack(spacing: 10) {
                    Image(systemName: "theatermasks.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TeddyPalette.primaryText)
                        .frame(width: 30, height: 30)
                        .background(TeddyPalette.control, in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Personnalité")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(TeddyPalette.primaryText)
                        Text("Le socle de Teddy reste toujours intact")
                            .font(.system(size: 10.5))
                            .foregroundStyle(TeddyPalette.tertiaryText)
                    }

                    Spacer()
                }
                .padding(14)

                Rectangle()
                    .fill(TeddyPalette.hairline)
                    .frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    personalitySection(
                        title: "STYLES TEDDY",
                        styles: TeddyPersonalityCatalog.selectableDefaults)

                    if !controller.customPersonalityStyles.isEmpty {
                        personalitySection(
                            title: "MES STYLES",
                            styles: controller.customPersonalityStyles)
                    }

                    if isCreating {
                        creationForm
                    } else {
                        Button {
                            controller.clearPersonalityEditorError()
                            withAnimation(.smooth(duration: 0.2)) { isCreating = true }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("Créer mon style")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("Teddy le structure")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(TeddyPalette.tertiaryText)
                            }
                            .foregroundStyle(TeddyPalette.secondaryText)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(TeddyPalette.control, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: displaysHeader ? 520 : .infinity)
        }
        .frame(width: displaysHeader ? 360 : nil)
        .background(displaysHeader ? TeddyPalette.popover : Color.clear)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func personalitySection(
        title: String,
        styles: [TeddyPersonalityStyle]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.65)
                .foregroundStyle(TeddyPalette.tertiaryText)
                .padding(.horizontal, 7)

            ForEach(styles) { style in
                TeddyPersonalityStyleRow(
                    style: style,
                    isSelected: controller.personalityStyle.id == style.id,
                    onSelect: { controller.selectPersonalityStyle(style) },
                    onDelete: style.origin == .custom
                        ? { controller.deleteCustomPersonalityStyle(style) }
                        : nil)
            }
        }
    }

    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NOUVEAU STYLE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(TeddyPalette.tertiaryText)
                Spacer()
                Button("Annuler") {
                    controller.clearPersonalityEditorError()
                    withAnimation(.smooth(duration: 0.2)) { isCreating = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(TeddyPalette.secondaryText)
            }

            TextField("Nom du style", text: $styleName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(TeddyPalette.control, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(TeddyPalette.hairline, lineWidth: 1)
                }

            ZStack(alignment: .topLeading) {
                if styleDescription.isEmpty {
                    Text("Décris-le avec tes mots : plus cash, plus calme, un humour particulier…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(TeddyPalette.tertiaryText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $styleDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TeddyPalette.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(5)
            }
            .frame(height: 94)
            .background(TeddyPalette.control, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(TeddyPalette.hairline, lineWidth: 1)
            }

            if let error = controller.personalityEditorError {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(TeddyPalette.primaryText.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task {
                    let saved = await controller.structureAndSavePersonality(
                        name: styleName,
                        description: styleDescription)
                    if saved {
                        styleName = ""
                        styleDescription = ""
                        withAnimation(.smooth(duration: 0.2)) { isCreating = false }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if controller.isStructuringPersonality {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    Text(controller.isStructuringPersonality
                        ? "Teddy structure le style…"
                        : "Structurer et activer")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(TeddyPalette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(TeddyPalette.accent, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(
                !controller.canStructurePersonality
                    || styleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || styleDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(controller.canStructurePersonality ? 1 : 0.5)
        }
        .padding(10)
        .background(TeddyPalette.terminalChrome, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(TeddyPalette.surfaceStroke, lineWidth: 1)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct TeddyPersonalityStyleRow: View {
    let style: TeddyPersonalityStyle
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Image(systemName: style.origin == .custom ? "slider.horizontal.3" : "sparkle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected
                        ? TeddyPalette.primaryText
                        : TeddyPalette.tertiaryText)
                    .frame(width: 24, height: 26)
                    .background(
                        Color.white.opacity(isSelected ? 0.08 : 0.035),
                        in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(style.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected
                            ? TeddyPalette.primaryText
                            : TeddyPalette.secondaryText)
                    Text(style.summary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(TeddyPalette.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(TeddyPalette.primaryText)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 42)
            .background(
                Color.white.opacity(isSelected ? 0.07 : (isHovering ? 0.035 : 0)),
                in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            if let onDelete {
                Button("Supprimer le style", systemImage: "trash", role: .destructive) {
                    onDelete()
                }
            }
        }
    }
}

private struct AnimatedThinkingWaveform: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0 ..< 13, id: \.self) { index in
                    let phase = time * 4.6 + Double(index) * 0.62
                    Capsule()
                        .fill(TeddyPalette.accent.opacity(0.42 + 0.22 * abs(sin(phase))))
                        .frame(width: 2.2, height: 5 + 15 * abs(sin(phase)))
                }
            }
        }
        .accessibilityLabel("Teddy prépare sa réponse")
    }
}

private struct RecordingIndicator: View {
    let level: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(TeddyPalette.recording.opacity(0.12 + level * 0.16))
                .frame(width: 22 + level * 6, height: 22 + level * 6)
            Circle()
                .fill(TeddyPalette.recording)
                .frame(width: 8, height: 8)
                .shadow(color: TeddyPalette.recording.opacity(0.55), radius: 4)
        }
        .frame(width: 28, height: 28)
        .animation(.smooth(duration: 0.12), value: level)
        .accessibilityLabel("Enregistrement en cours")
    }
}

private struct HoldToTalkButton: View {
    let isPressed: Bool
    let isEnabled: Bool
    let level: Double
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var gestureIsActive = false
    @State private var isHovering = false

    var body: some View {
        ZStack {
            if isPressed {
                Circle()
                    .stroke(TeddyPalette.recording.opacity(0.16 + level * 0.24), lineWidth: 4)
                    .frame(width: 34 + level * 5, height: 34 + level * 5)
                    .blur(radius: 0.3)
            }

            Circle()
                .fill(buttonFill)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(
                    color: .black.opacity(isHovering ? 0.24 : 0.14),
                    radius: isHovering ? 7 : 4,
                    y: 2
                )

            Image(systemName: isPressed ? "waveform" : "mic.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(TeddyPalette.ink)
                .symbolRenderingMode(.monochrome)
        }
        .frame(width: 36, height: 36)
        .contentShape(Circle())
        .opacity(isEnabled ? 1 : 0.34)
        .scaleEffect(isPressed ? 0.96 : (isHovering ? 1.02 : 1))
        .animation(.smooth(duration: 0.16), value: isPressed)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled, !gestureIsActive else { return }
                    gestureIsActive = true
                    onPress()
                }
                .onEnded { _ in
                    guard gestureIsActive else { return }
                    gestureIsActive = false
                    onRelease()
                }
        )
        .onDisappear {
            if gestureIsActive {
                gestureIsActive = false
                onRelease()
            }
        }
        .accessibilityLabel("Push to talk")
        .accessibilityHint("Maintenir pour parler, relâcher pour envoyer")
    }

    private var buttonFill: LinearGradient {
        let top = isPressed ? TeddyPalette.recordingLight : Color.white.opacity(0.94)
        let bottom = isPressed ? TeddyPalette.recording : Color.white.opacity(0.80)
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct ShortcutBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("⌥")
                .font(.system(size: 11, weight: .semibold))
            Text("droite")
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(TeddyPalette.tertiaryText)
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(TeddyPalette.hairline, lineWidth: 1)
        }
    }
}

private struct LatencyPill: View {
    let milliseconds: Double

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(TeddyPalette.accent)
            Text(formattedLatency)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(TeddyPalette.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(TeddyPalette.control, in: Capsule())
        .overlay { Capsule().stroke(TeddyPalette.hairline, lineWidth: 1) }
    }

    private var formattedLatency: String {
        milliseconds < 1_000
            ? "\(Int(milliseconds.rounded())) ms"
            : String(format: "%.2f s", milliseconds / 1_000)
    }
}

private struct TeddyAvatar: View {
    let size: CGFloat
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [TeddyPalette.avatarTop, TeddyPalette.avatarBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
            TeddyWaveMark(size: size * 0.48, isActive: isActive)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
    }
}

private struct CompanionAvatar: View {
    let provider: String?
    let phase: TeddyCompanionSnapshot.Phase?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [TeddyPalette.avatarTop, TeddyPalette.avatarBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
            Image(systemName: provider == nil ? "waveform" : "terminal.fill")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(TeddyPalette.primaryText)

            if phase != nil {
                Circle()
                    .fill(statusColor)
                    .frame(width: max(6, size * 0.22), height: max(6, size * 0.22))
                    .overlay { Circle().stroke(TeddyPalette.chrome, lineWidth: 1.5) }
                    .offset(x: size * 0.34, y: size * 0.34)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
    }

    private var statusColor: Color {
        switch phase {
        case .idle, .completed: TeddyPalette.online
        case .working: TeddyPalette.warning
        case .awaitingInput, .awaitingApproval: TeddyPalette.accent
        case .failed, .exited: TeddyPalette.recording
        case nil: TeddyPalette.tertiaryText
        }
    }
}

private struct TeddyWaveMark: View {
    let size: CGFloat
    let isActive: Bool

    private let heights: [CGFloat] = [0.42, 0.72, 1, 0.72, 0.42]

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.075) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(TeddyPalette.accentLight)
                    .frame(
                        width: max(1.2, size * 0.09),
                        height: max(2, size * height * (isActive && index.isMultiple(of: 2) ? 1 : 0.82))
                    )
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.18), value: isActive)
        .accessibilityHidden(true)
    }
}

private struct ChromeButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isActive ? TeddyPalette.accent : TeddyPalette.secondaryText)
            .frame(width: 32, height: 32)
            .background(
                isActive ? TeddyPalette.accent.opacity(0.11) : TeddyPalette.control,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isActive ? TeddyPalette.accent.opacity(0.22) : TeddyPalette.hairline, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private struct MessageActionButton: View {
    let title: String
    let icon: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TeddyPalette.accent)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TeddyPalette.primaryText)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(TeddyPalette.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.34)
    }
}

private enum TeddyPalette {
    // Strict black and white. Depth comes from opacity and native materials.
    static let canvas = Color.black.opacity(0.72)
    static let sidebar = Color.black.opacity(0.82)
    static let sidebarRaised = Color.white.opacity(0.035)
    static let chrome = Color.black.opacity(0.54)
    static let composer = Color.white.opacity(0.090)
    static let composerTool = Color.white.opacity(0.040)
    static let composerStroke = Color.white.opacity(0.105)
    static let terminalChrome = Color.black.opacity(0.44)
    static let terminalCanvas = Color.black.opacity(0.86)
    static let popover = Color.black.opacity(0.88)
    static let control = Color.white.opacity(0.045)
    static let selection = Color.white.opacity(0.075)
    static let transcript = Color.white.opacity(0.035)
    static let assistantBubble = Color.white.opacity(0.045)
    static let userBubble = Color.white.opacity(0.14)
    static let assistantBubbleTop = Color.white.opacity(0.055)
    static let assistantBubbleBottom = Color.white.opacity(0.035)
    static let userBubbleTop = Color.white.opacity(0.16)
    static let userBubbleBottom = Color.white.opacity(0.11)
    static let avatarTop = Color.white.opacity(0.16)
    static let avatarBottom = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.07)
    static let surfaceStroke = Color.white.opacity(0.085)
    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)
    static let accent = Color.white.opacity(0.94)
    static let accentLight = Color.white.opacity(0.98)
    static let accentDark = Color.white.opacity(0.72)
    static let ink = Color.black.opacity(0.92)
    static let online = Color.white.opacity(0.86)
    static let recording = Color.white.opacity(0.94)
    static let recordingLight = Color.white
    static let warning = Color.white.opacity(0.70)
}

#if DEBUG
@MainActor
struct VoiceChatDesignPreview: View {
    private let conversations = [
        VoiceConversationSummary(
            id: UUID(),
            title: "Point sur mes agents",
            updatedAt: .now,
            messageCount: 4
        ),
        VoiceConversationSummary(
            id: UUID(),
            title: "Nouvelle personnalité Teddy",
            updatedAt: .now.addingTimeInterval(-3600),
            messageCount: 8
        ),
        VoiceConversationSummary(
            id: UUID(),
            title: "Optimisation de la latence",
            updatedAt: .now.addingTimeInterval(-7200),
            messageCount: 12
        )
    ]

    private let messages = [
        VoiceMessage(
            sender: .user,
            transcript: "Fais-moi un point rapide sur mes agents.",
            durationSeconds: 2.4,
            waveform: VoiceChatDesignPreview.wave(seed: 0.38),
            phase: .sent
        ),
        VoiceMessage(
            sender: .teddy,
            transcript: "Ouais. Deux ont fini, et y en a un qui attend ton retour.",
            durationSeconds: 4.7,
            waveform: VoiceChatDesignPreview.wave(seed: 0.71),
            phase: .ready
        ),
        VoiceMessage(
            sender: .user,
            transcript: "Dis-lui de corriger le dernier souci et de me prévenir.",
            durationSeconds: 3.1,
            waveform: VoiceChatDesignPreview.wave(seed: 1.09),
            phase: .sent
        )
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TeddyAvatar(size: 34, isActive: false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Teddy")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TeddyPalette.primaryText)
                        Text("Assistant vocal")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(TeddyPalette.tertiaryText)
                    }
                    Spacer()
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(TeddyPalette.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(TeddyPalette.control, in: RoundedRectangle(cornerRadius: 9))
                }
                .padding(.horizontal, 12)
                .frame(height: 60)

                VStack(alignment: .leading, spacing: 3) {
                    Text("CONVERSATIONS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(TeddyPalette.tertiaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    ForEach(Array(conversations.enumerated()), id: \.element.id) { index, conversation in
                        ConversationSidebarRow(
                            conversation: conversation,
                            companion: nil,
                            companionAvatar: nil,
                            isSelected: index == 0,
                            isHovering: false,
                            isLoading: false,
                            onSelect: {},
                            onDelete: {}
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)

                HStack(spacing: 7) {
                    Circle().fill(TeddyPalette.online).frame(width: 6, height: 6)
                    Text("Prêt sur ce Mac")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(TeddyPalette.tertiaryText)
                    Spacer()
                }
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(TeddyPalette.sidebarRaised)
            }
            .frame(width: 244)
            .background(TeddyPalette.sidebar)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Point sur mes agents")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TeddyPalette.primaryText)
                        HStack(spacing: 6) {
                            Circle().fill(TeddyPalette.online).frame(width: 6, height: 6)
                            Text("prêt")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(TeddyPalette.secondaryText)
                        }
                    }
                    Spacer()
                    LatencyPill(milliseconds: 482)
                    Image(systemName: "pin")
                    Image(systemName: "slider.horizontal.3")
                    Image(systemName: "ellipsis")
                }
                .foregroundStyle(TeddyPalette.secondaryText)
                .padding(.horizontal, 18)
                .frame(height: 60)
                .background(TeddyPalette.chrome)

                VStack(spacing: 14) {
                    ForEach(messages) { message in
                        VoiceMessageRow(
                            message: message,
                            clusterPosition: .single,
                            bubbleWidth: 540,
                            canReplay: true,
                            isPlaying: false,
                            playbackProgress: 0,
                            showsTranscript: false,
                            onTogglePlayback: {},
                            onToggleTranscript: {}
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .background(TeddyPalette.canvas)

                HStack(spacing: 11) {
                    HStack {
                        Text("Maintiens pour parler, relâche pour envoyer")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TeddyPalette.secondaryText)
                        Spacer()
                        ShortcutBadge()
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 48)
                    .background(TeddyPalette.composer, in: RoundedRectangle(cornerRadius: 16))
                    Circle()
                        .fill(TeddyPalette.accent)
                        .frame(width: 54, height: 54)
                        .overlay {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 13)
                .background(TeddyPalette.chrome)
            }
        }
        .frame(width: 1_060, height: 760)
        .background(TeddyPalette.canvas)
        .preferredColorScheme(.dark)
    }

    private static func wave(seed: Double) -> [Double] {
        (0 ..< VoiceWaveform.maximumVisibleSamples).map { index in
            let primary = abs(sin(Double(index) * 0.31 + seed))
            let secondary = abs(sin(Double(index) * 0.13 + seed * 2.1))
            return 0.06 + primary * secondary * 0.88
        }
    }
}
#endif

private extension Double {
    func teddyClamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private func formatVoiceDuration(_ seconds: Double) -> String {
    let totalSeconds = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}
