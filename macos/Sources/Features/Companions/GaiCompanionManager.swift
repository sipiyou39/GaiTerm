#if os(macOS)
import AppKit
import Combine
import GhosttyKit
import SwiftUI
import UserNotifications

enum GaiCompanionPresentation: Equatable {
    case collapsed
    case compact
    case maximized
}

/// Keeps opening the company library independent from the user's explicit
/// desktop-agent visibility choice. Presenting a terminal is different: that
/// action promises visible, focused output and therefore lifts the global gate.
enum GaiCompanionVisibilityAction: Equatable, Sendable {
    case revealLibrary
    case presentAgentTerminal

    func resultingAgentVisibility(current: Bool) -> Bool {
        switch self {
        case .revealLibrary:
            current
        case .presentAgentTerminal:
            true
        }
    }
}

/// Immutable snapshot behind the destructive bulk-removal confirmation.
/// Agents hired while the alert is open are deliberately not included.
struct GaiCompanionBulkRemovalPlan: Equatable, Sendable {
    let agentIDs: [UUID]

    init(agentIDs: [UUID]) {
        var seen: Set<UUID> = []
        self.agentIDs = agentIDs.filter { seen.insert($0).inserted }
    }

    var title: String {
        if agentIDs.count == 1 {
            return "Kill this agent and its terminal?"
        }
        return "Kill all \(agentIDs.count) agents and their terminals?"
    }

    var explanation: String {
        if agentIDs.count == 1 {
            return "This permanently ends the running terminal and removes the "
                + "agent from DouDou Company. This cannot be undone. To only "
                + "hide it, cancel and use Hide Agents."
        }
        return "This permanently ends every running terminal and removes all "
            + "\(agentIDs.count) agents from DouDou Company. This cannot be "
            + "undone. To only hide them, cancel and use Hide Agents."
    }

    var destructiveButtonTitle: String {
        agentIDs.count == 1 ? "Kill Agent" : "Kill All Agents"
    }

    func agentIDsToRemove(confirmed: Bool) -> [UUID] {
        confirmed ? agentIDs : []
    }
}

/// Result at the authenticated provider-event boundary.
///
/// A valid duplicate or stale event is still consumed: provider hooks must not
/// retry it through LaunchServices. Only an unknown surface or invalid
/// capability token is rejected. UI side effects remain exclusive to
/// `applied`, so an idempotent retry cannot replay a sound or notification.
enum GaiCompanionAgentEventReceipt: Equatable {
    case rejected
    case applied
    case consumedWithoutChange(GaiCompanionReductionDisposition)

    var shouldAcknowledge: Bool {
        switch self {
        case .rejected:
            false
        case .applied, .consumedWithoutChange:
            true
        }
    }
}

enum GaiCompanionTerminalPlacement: CaseIterable, Equatable {
    case top
    case bottom
    case right
    case left
}

private struct GaiCompanionPreviewGeometry {
    let placement: GaiCompanionTerminalPlacement
    let terminalFrame: NSRect
}

/// Native port of GaiWork's queued completion sound player. One bundled sound
/// is reused and completion events are serialized instead of overlapping.
private final class GaiCompanionCompletionSoundPlayer: NSObject, NSSoundDelegate {
    static let shared = GaiCompanionCompletionSoundPlayer()

    private var sound: NSSound?
    private var queuedPlaybackCount = 0
    private var isPlaying = false
    private let maximumQueuedPlaybackCount = 8

    func preload() {
        DispatchQueue.main.async { [weak self] in
            _ = self?.preparedSound()
        }
    }

    func play() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queuedPlaybackCount = min(
                maximumQueuedPlaybackCount,
                queuedPlaybackCount + 1)
            drainQueue()
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queuedPlaybackCount = 0
            isPlaying = false
            sound?.stop()
            sound?.currentTime = 0
        }
    }

    private func preparedSound() -> NSSound? {
        if let sound { return sound }
        guard let url = Bundle.main.url(
            forResource: "completion",
            withExtension: "mp3",
            subdirectory: "Companions/sounds"),
            let loadedSound = NSSound(contentsOf: url, byReference: false)
        else { return nil }
        loadedSound.delegate = self
        sound = loadedSound
        return loadedSound
    }

    private func drainQueue() {
        guard !isPlaying, queuedPlaybackCount > 0 else { return }
        guard let sound = preparedSound() else {
            queuedPlaybackCount = 0
            return
        }
        queuedPlaybackCount -= 1
        sound.currentTime = 0
        isPlaying = true
        if !sound.play() {
            isPlaying = false
            queuedPlaybackCount = 0
        }
    }

    func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        guard sound === self.sound else { return }
        _ = finishedPlaying
        isPlaying = false
        drainQueue()
    }
}

/// Runtime-only owner of one companion and its unique Ghostty surface.
/// Persisted configuration stays in `GaiCompanionStore`; the PTY never moves
/// to a second runtime when the panel changes presentation.
final class GaiCompanionRuntime: ObservableObject, Identifiable {
    let id: UUID
    private(set) var eventToken = UUID().uuidString.lowercased()
    private var observedNativeAdapters: Set<GaiCompanionProvider> = []

    @Published private(set) var record: GaiCompanionRecord
    @Published var surfaceView: Ghostty.SurfaceView?
    @Published var presentation: GaiCompanionPresentation = .collapsed
    @Published var terminalPlacement: GaiCompanionTerminalPlacement = .top
    @Published var isTerminalLocked = false
    @Published private(set) var activity: GaiCompanionActivityState

    init(record: GaiCompanionRecord) {
        id = record.id
        self.record = record
        activity = GaiCompanionActivityState(surfaceID: record.id)
    }

    var animation: GaiCompanionAnimation {
        switch activity.phase {
        case .idle: .idle
        case .working: .working
        case .awaitingInput, .awaitingApproval: .thinking
        case .completedUnseen: .jumping
        case .failed, .exited: .failed
        }
    }

    /// The persisted color is the agent's identity. Green is a transient,
    /// state-derived notification skin that lasts until the completion is
    /// explicitly acknowledged.
    var renderedColorway: GaiCompanionColorway {
        activity.phase == .completedUnseen
            ? .completionColorway
            : record.colorway
    }

    var phaseLabel: String {
        switch activity.phase {
        case .idle: "Ready"
        case .working: "At work"
        case .awaitingInput: "Needs your input"
        case .awaitingApproval: "Needs approval"
        case .completedUnseen: "Task complete"
        case .failed: "Needs attention"
        case .exited: "Offline"
        }
    }

    func replaceRecord(_ record: GaiCompanionRecord) {
        guard record.id == id else { return }
        self.record = record
    }

    @discardableResult
    func apply(_ action: GaiCompanionActivityAction) -> GaiCompanionReductionDisposition {
        if case .event(let event) = action,
           event.surfaceID == id,
           event.source == .providerHook,
           (event.kind == .ready || event.kind == .started) {
            // A delivered authenticated hook is the runtime handshake. Until
            // this proof exists, Return remains an optimistic fallback so an
            // old/missing adapter cannot leave a visibly working CLI idle.
            observedNativeAdapters.insert(event.provider)
        }
        var next = activity
        let disposition = GaiCompanionActivityReducer.apply(action, to: &next)
        activity = next
        return disposition
    }

    func acknowledgeCompletion() {
        guard let acknowledgement = activity.pendingAcknowledgement else { return }
        _ = apply(.acknowledge(acknowledgement))
    }

    func resetActivity() {
        activity = GaiCompanionActivityState(surfaceID: id)
    }

    func hasObservedNativeAdapter(for provider: GaiCompanionProvider) -> Bool {
        observedNativeAdapters.contains(provider)
    }

    /// A detached PTY is a hard incarnation boundary. Completion/failure may
    /// remain visible while the employee is offline, but explicitly creating
    /// its next terminal must not carry that old state or capability token into
    /// the new process.
    func prepareForNewSurfaceIncarnation() {
        guard surfaceView == nil,
              activity.generation > 0 || activity.phase != .idle else { return }
        resetActivity()
        rotateEventToken()
    }

    /// Invalidates delayed events from a terminal process which has just been
    /// replaced while keeping the companion's stable identity.
    func rotateEventToken() {
        eventToken = UUID().uuidString.lowercased()
        observedNativeAdapters.removeAll()
    }
}

/// Agent-first replacement for `GaiWorkspaceManager`.
///
/// It deliberately mirrors the old manager's public surface API so the rest of
/// Ghostty, App Intents, URL callbacks and menu actions need no Debug forks.
final class GaiCompanionManager: NSObject, ObservableObject {
    @Published private(set) var runtimes: [GaiCompanionRuntime] = []
    @Published private(set) var agentWindowsAreVisible = true

    private let ghostty: Ghostty.App
    private let store: GaiCompanionStore
    private var panelControllers: [UUID: GaiCompanionPanelController] = [:]
    private var managerWindowController: GaiCompanionLibraryWindowController?
    private var started = false
    private var eventSequence: UInt64 = 0
    private var focusGeneration: UInt64 = 0
    private var terminalTransientCounts: [UUID: Int] = [:]
    private var activeCloseConfirmationIDs: Set<UUID> = []
    private var closeAllConfirmationIsPresented = false
    private var provisionalExpiryTasks: [
        UUID: (nonce: UUID, workItem: DispatchWorkItem)
    ] = [:]
    private static let provisionalStartLifetime: TimeInterval = 3

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        store = GaiCompanionStore(userDefaults: .ghostty, loadImmediately: false)
        super.init()
        registerObservers()
    }

    deinit {
        for task in provisionalExpiryTasks.values {
            task.workItem.cancel()
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Public API shared with GaiWorkspaceManager

    func start() {
        guard !started else { return }
        started = true

        let loadResult = store.load()
        let createdFreshCompanion: Bool
        if loadResult == .empty {
            _ = store.create()
            createdFreshCompanion = true
        } else {
            createdFreshCompanion = false
            if loadResult == .failed {
                Ghostty.logger.error("could not load persisted agents")
            }
        }

        runtimes = store.companions.map(GaiCompanionRuntime.init)
        if runtimes.contains(where: { $0.record.completionSoundEnabled }) {
            GaiCompanionCompletionSoundPlayer.shared.preload()
        }
        for runtime in runtimes {
            if runtime.record.displayID == nil {
                let screen = targetScreen(for: runtime)
                if let record = store.update(id: runtime.id, {
                    $0.displayID = displayID(for: screen)
                }) {
                    runtime.replaceRecord(record)
                }
            }
            ensurePanel(for: runtime)
            setPresentation(.collapsed, for: runtime, animated: false, focus: false)
        }

        // A fresh installation opens its first live terminal immediately. A
        // migrated/restored set stays mascot-only until explicitly opened, so
        // launching Debug never starts dozens of old CLI commands at once.
        if createdFreshCompanion,
           let first = runtimes.first {
            setPresentation(.compact, for: first, animated: false, focus: true)
        }

        showLibrary(activate: NSApp.isActive)
        updateSurfacePerformanceState()
    }

    func reveal() {
        start()
        applyVisibilityPolicy(.revealLibrary)
        showLibrary(activate: true)
    }

    /// Shows or hides only the desktop agent layer. Runtime presentation and
    /// every Ghostty surface remain untouched, so a second toggle restores the
    /// exact compact/maximized state without restarting a PTY.
    func toggleAgentVisibility() {
        setAgentWindowsVisible(!agentWindowsAreVisible)
    }

    private func setAgentWindowsVisible(_ visible: Bool) {
        guard agentWindowsAreVisible != visible else { return }

        // Publish the gate before ordering windows out. The resulting
        // resign-key callback must not interpret this intentional hide as an
        // outside click and collapse the preserved terminal presentation.
        agentWindowsAreVisible = visible
        if !visible {
            focusGeneration &+= 1
        }
        for controller in panelControllers.values {
            controller.setAgentWindowsVisible(visible)
        }
        updateSurfacePerformanceState()
        updateDockBadge()
    }

    private func applyVisibilityPolicy(_ action: GaiCompanionVisibilityAction) {
        setAgentWindowsVisible(
            action.resultingAgentVisibility(current: agentWindowsAreVisible))
    }

    @discardableResult
    func openTerminal(
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        parent: Ghostty.SurfaceView? = nil,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection? = nil,
        companionColorway: GaiCompanionColorway? = nil,
        companionScalePercent: GaiCompanionScalePercent = .standard,
        companionCompletionSoundEnabled: Bool = true
    ) -> Ghostty.SurfaceView? {
        _ = parent
        _ = direction
        start()

        let colorways = GaiCompanionColorway.selectableColorways
        let colorway = companionColorway ?? colorways[runtimes.count % colorways.count]
        let directory = baseConfig?.workingDirectory ?? GaiCompanionRecord.defaultDirectoryPath
        let screen = screenUnderMouse()
        let record = store.create(
            colorway: colorway,
            directoryPath: directory,
            launchCommand: baseConfig?.command,
            normalizedPosition: suggestedPosition(for: runtimes.count),
            displayID: displayID(for: screen),
            scalePercent: companionScalePercent,
            completionSoundEnabled: companionCompletionSoundEnabled)
        let runtime = GaiCompanionRuntime(record: record)
        runtimes.append(runtime)
        if record.completionSoundEnabled {
            GaiCompanionCompletionSoundPlayer.shared.preload()
        }
        ensurePanel(for: runtime)

        guard let surface = ensureSurface(for: runtime, baseConfig: baseConfig) else {
            closeCompanion(id: runtime.id)
            return nil
        }
        setPresentation(.compact, for: runtime, animated: true, focus: true)
        showLibrary(activate: false)
        return surface
    }

    func surface(for uuid: UUID) -> Ghostty.SurfaceView? {
        runtime(id: uuid)?.surfaceView
    }

    var terminalSurfaces: [Ghostty.SurfaceView] {
        runtimes.compactMap(\.surfaceView)
    }

    func focusedSurface() -> Ghostty.SurfaceView? {
        guard let keyWindow = NSApp.keyWindow,
              let runtime = runtimes.first(where: {
                  panelControllers[$0.id]?.terminalPanel === keyWindow
              })
        else { return nil }
        return runtime.surfaceView
    }

    func focusSurface(_ surface: Ghostty.SurfaceView) {
        guard let runtime = runtime(id: surface.id) else { return }
        setPresentation(
            runtime.presentation == .maximized ? .maximized : .compact,
            for: runtime,
            animated: true,
            focus: true)
    }

    func closeSurface(_ surface: Ghostty.SurfaceView) {
        requestCloseCompanion(id: surface.id)
    }

    func closeAllSurfaces() {
        let plan = GaiCompanionBulkRemovalPlan(agentIDs: runtimes.map(\.id))
        guard !plan.agentIDs.isEmpty,
              !closeAllConfirmationIsPresented,
              activeCloseConfirmationIDs.isEmpty else { return }

        closeAllConfirmationIsPresented = true
        for id in plan.agentIDs {
            beginTerminalTransient(id: id)
        }

        let focusedTerminalID = runtimes.first {
            panelControllers[$0.id]?.terminalPanel.isKeyWindow == true
        }?.id
        let focusedTerminalPanel = focusedTerminalID.flatMap {
            panelControllers[$0]?.terminalPanel
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = plan.title
        alert.informativeText = plan.explanation
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: plan.destructiveButtonTitle)
        alert.buttons.last?.hasDestructiveAction = true

        let restoreLevels = GaiFloatingPanels.lower()
        if let hostWindow = focusedTerminalPanel ?? NSApp.keyWindow {
            alert.beginSheetModal(for: hostWindow) { [weak self] response in
                restoreLevels()
                self?.resolveCloseAllConfirmation(
                    plan,
                    confirmed: response == .alertSecondButtonReturn,
                    focusedTerminalID: focusedTerminalID)
            }
            return
        }

        let response = alert.runModal()
        restoreLevels()
        resolveCloseAllConfirmation(
            plan,
            confirmed: response == .alertSecondButtonReturn,
            focusedTerminalID: focusedTerminalID)
    }

    @discardableResult
    func recordExternalNotification(
        surfaceID: UUID,
        title: String,
        body: String
    ) -> Bool {
        guard let runtime = runtime(id: surfaceID) else { return false }
        let timestamp = Date()
        let kind = eventKind(title: title, body: body)
        let provider = provider(title: title, runtime: runtime)
        let normalizedText = "\(title)\n\(body)".lowercased()
        let bucket = Int(timestamp.timeIntervalSince1970)
        let event = GaiCompanionEvent(
            surfaceID: surfaceID,
            provider: provider,
            eventID: "legacy-\(kind.rawValue)-\(bucket)-\(normalizedText.hashValue)",
            kind: kind,
            source: .terminalFallback,
            timestamp: timestamp,
            message: body.isEmpty ? title : body)
        return applyLifecycleEvent(
            event,
            to: runtime,
            notificationTitle: notificationTitle(for: runtime, fallback: title),
            notificationBody: body) == .appliedEvent
    }

    /// Entry point for provider adapters. A per-runtime capability token keeps
    /// another terminal, an old PTY incarnation, or an unrelated URL opener
    /// from mutating this agent's state.
    @discardableResult
    func recordAgentEvent(
        _ event: GaiCompanionEvent,
        token: String
    ) -> GaiCompanionAgentEventReceipt {
        guard let runtime = runtime(id: event.surfaceID),
              token == runtime.eventToken else { return .rejected }
        let disposition = applyLifecycleEvent(
            event,
            to: runtime,
            notificationTitle: providerDisplayName(event.provider),
            notificationBody: event.message ?? notificationBody(for: event.kind))
        if disposition == .appliedEvent {
            return .applied
        }
        return .consumedWithoutChange(disposition)
    }

    // MARK: Library actions

    func createCompanion() {
        _ = openTerminal()
    }

    func createCompanion(
        colorway: GaiCompanionColorway,
        scalePercent: GaiCompanionScalePercent,
        completionSoundEnabled: Bool
    ) {
        _ = openTerminal(
            companionColorway: colorway,
            companionScalePercent: scalePercent,
            companionCompletionSoundEnabled: completionSoundEnabled)
    }

    var suggestedCompanionColorway: GaiCompanionColorway {
        let colorways = GaiCompanionColorway.selectableColorways
        return colorways[runtimes.count % colorways.count]
    }

    func showCompanion(id: UUID) {
        guard let runtime = runtime(id: id) else { return }
        let target: GaiCompanionPresentation = runtime.presentation == .collapsed ? .compact : runtime.presentation
        setPresentation(target, for: runtime, animated: true, focus: true)
    }

    func toggleTerminal(id: UUID) {
        guard let runtime = runtime(id: id) else { return }
        guard terminalTransientCounts[id, default: 0] == 0 else { return }
        if runtime.activity.phase == .exited {
            restartExitedTerminal(runtime)
            return
        }
        // Mascot clicks are explicit acknowledgement actions. Merely focusing
        // a window is not, because macOS can restore focus automatically.
        runtime.acknowledgeCompletion()
        switch runtime.presentation {
        case .collapsed:
            setPresentation(.compact, for: runtime, animated: true, focus: true)
        case .compact, .maximized:
            setPresentation(.collapsed, for: runtime, animated: true, focus: false)
        }
    }

    /// A real mascot drag always dismisses its terminal. The drag recognizer
    /// calls this only after crossing its movement threshold, so a short click
    /// keeps its existing toggle behavior. This deliberately avoids the general
    /// presentation/layout path: the mascot frame, order and focus stay intact,
    /// and nothing reopens the terminal when the pointer is released.
    func companionDragDidBegin(id: UUID) {
        guard let runtime = runtime(id: id),
              terminalTransientCounts[id, default: 0] == 0,
              runtime.presentation != .collapsed else { return }
        focusGeneration &+= 1
        runtime.presentation = .collapsed
        panelControllers[id]?.hideTerminalForCompanionDrag()
        updateSurfacePerformanceState()
        updateDockBadge()
    }

    func toggleMaximized(id: UUID) {
        guard let runtime = runtime(id: id) else { return }
        let target: GaiCompanionPresentation = runtime.presentation == .maximized ? .compact : .maximized
        setPresentation(target, for: runtime, animated: true, focus: true)
    }

    private func closeCompanion(id: UUID) {
        guard let index = runtimes.firstIndex(where: { $0.id == id }) else { return }
        focusGeneration &+= 1
        terminalTransientCounts.removeValue(forKey: id)
        activeCloseConfirmationIDs.remove(id)
        provisionalExpiryTasks.removeValue(forKey: id)?.workItem.cancel()
        let runtime = runtimes.remove(at: index)
        runtime.surfaceView?.gaiReleaseTerminalSurface()
        runtime.surfaceView = nil
        panelControllers.removeValue(forKey: id)?.close()
        _ = store.remove(id: id)
        if !runtimes.contains(where: { $0.record.completionSoundEnabled }) {
            GaiCompanionCompletionSoundPlayer.shared.stop()
        }
        updateDockBadge()
    }

    func updateColorway(id: UUID, colorway: GaiCompanionColorway) {
        guard let runtime = runtime(id: id),
              let record = store.update(id: id, { $0.colorway = colorway })
        else { return }
        runtime.replaceRecord(record)
    }

    func updateName(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedName = String(trimmed.prefix(40))
        guard let runtime = runtime(id: id),
              let record = store.update(id: id, { $0.name = normalizedName })
        else { return }
        runtime.replaceRecord(record)
    }

    func toggleTerminalLock(id: UUID) {
        guard let runtime = runtime(id: id) else { return }
        runtime.isTerminalLocked.toggle()
    }

    func setTerminalDialogPresented(id: UUID, isPresented: Bool) {
        guard runtime(id: id) != nil else { return }
        if isPresented {
            beginTerminalTransient(id: id)
            return
        }

        if finishTerminalTransient(id: id) {
            refocusTerminalIfVisible(id: id)
        }
    }

    func requestCloseCompanion(id: UUID) {
        guard let runtime = runtime(id: id) else { return }
        guard !closeAllConfirmationIsPresented else { return }
        guard activeCloseConfirmationIDs.insert(id).inserted else { return }
        beginTerminalTransient(id: id)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Kill \(runtime.record.displayName) and its terminal?"
        alert.informativeText = "This permanently ends the running terminal "
            + "and removes the agent from DouDou Company. To only hide the "
            + "terminal, cancel and click the agent on your desktop."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Kill Agent")
        alert.buttons.last?.hasDestructiveAction = true

        let terminalPanel = panelControllers[id]?.terminalPanel
        let terminalWasVisible = terminalPanel?.isVisible == true
        let alertHostedByTerminal = terminalPanel?.isKeyWindow == true
        guard let hostWindow = alertHostedByTerminal ? terminalPanel : NSApp.keyWindow else {
            let restoreLevels = GaiFloatingPanels.lower()
            let response = alert.runModal()
            restoreLevels()
            activeCloseConfirmationIDs.remove(id)
            if response == .alertSecondButtonReturn {
                closeCompanion(id: id)
            } else if finishTerminalTransient(id: id), terminalWasVisible {
                refocusTerminalIfVisible(id: id)
            }
            return
        }

        let restoreLevels = GaiFloatingPanels.lower()
        alert.beginSheetModal(for: hostWindow) { [weak self] response in
            restoreLevels()
            guard let self else { return }
            self.activeCloseConfirmationIDs.remove(id)
            if response == .alertSecondButtonReturn {
                self.closeCompanion(id: id)
                return
            }
            if self.finishTerminalTransient(id: id),
               terminalWasVisible,
               alertHostedByTerminal {
                self.refocusTerminalIfVisible(id: id)
            }
        }
    }

    private func resolveCloseAllConfirmation(
        _ plan: GaiCompanionBulkRemovalPlan,
        confirmed: Bool,
        focusedTerminalID: UUID?
    ) {
        guard closeAllConfirmationIsPresented else { return }
        closeAllConfirmationIsPresented = false

        let idsToRemove = plan.agentIDsToRemove(confirmed: confirmed)
        if !idsToRemove.isEmpty {
            for id in idsToRemove {
                closeCompanion(id: id)
            }
            return
        }

        for id in plan.agentIDs {
            _ = finishTerminalTransient(id: id)
        }
        if let focusedTerminalID {
            refocusTerminalIfVisible(id: focusedTerminalID)
        }
    }

    /// Live group resize used while a size control is moving. Runtime records
    /// and native panels update immediately; persisted records stay untouched.
    func previewScales(
        ids: Set<UUID>,
        scalePercent: GaiCompanionScalePercent
    ) {
        guard !ids.isEmpty else { return }
        for runtime in runtimes where ids.contains(runtime.id) {
            previewScale(runtime, scalePercent: scalePercent)
        }
    }

    /// Commits the exact clamped frames produced by the live preview. The
    /// store publishes and saves the whole selection as one transaction.
    func commitScales(
        ids: Set<UUID>,
        scalePercent: GaiCompanionScalePercent
    ) {
        guard !ids.isEmpty else { return }
        previewScales(ids: ids, scalePercent: scalePercent)

        let previewedRecords = Dictionary(
            uniqueKeysWithValues: runtimes.lazy
                .filter { ids.contains($0.id) }
                .map { ($0.id, $0.record) })
        guard !previewedRecords.isEmpty else { return }

        let committedRecords = store.update(ids: Set(previewedRecords.keys)) { record in
            guard let previewed = previewedRecords[record.id] else { return }
            record.scalePercent = previewed.scalePercent
            record.normalizedPosition = previewed.normalizedPosition
            record.displayID = previewed.displayID
        }
        for record in committedRecords {
            guard let runtime = runtime(id: record.id), runtime.record != record else { continue }
            runtime.replaceRecord(record)
        }
    }

    func updateScale(id: UUID, scalePercent: GaiCompanionScalePercent) {
        let ids: Set<UUID> = [id]
        previewScales(ids: ids, scalePercent: scalePercent)
        commitScales(ids: ids, scalePercent: scalePercent)
    }

    func updateCompletionSound(id: UUID, enabled: Bool) {
        guard let runtime = runtime(id: id),
              let record = store.update(id: id, {
                  $0.completionSoundEnabled = enabled
              })
        else { return }
        runtime.replaceRecord(record)
        if enabled {
            GaiCompanionCompletionSoundPlayer.shared.preload()
        } else if !runtimes.contains(where: { $0.record.completionSoundEnabled }) {
            GaiCompanionCompletionSoundPlayer.shared.stop()
        }
    }

    func previewCompletionSound() {
        GaiCompanionCompletionSoundPlayer.shared.play()
    }

    func chooseDirectory(id: UUID, path: String) {
        guard let runtime = runtime(id: id) else { return }
        let needsConfirmation: Bool = switch runtime.activity.phase {
        case .working, .awaitingInput, .awaitingApproval: true
        default: false
        }
        guard needsConfirmation else {
            reopenTerminal(runtime, directory: path)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restart this terminal?"
        alert.informativeText = "Changing folders closes the current shell or agent and creates a new terminal in the selected folder."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        beginTerminalTransient(id: id)
        let restoreLevels = GaiFloatingPanels.lower()
        if let panel = panelControllers[id]?.terminalPanel {
            alert.beginSheetModal(for: panel) { [weak self] response in
                restoreLevels()
                guard let self else { return }
                if response == .alertFirstButtonReturn {
                    self.reopenTerminal(runtime, directory: path)
                    _ = self.finishTerminalTransient(id: id)
                } else if self.finishTerminalTransient(id: id) {
                    self.refocusTerminalIfVisible(id: id)
                }
            }
        } else {
            let response = alert.runModal()
            restoreLevels()
            if response == .alertFirstButtonReturn {
                reopenTerminal(runtime, directory: path)
                _ = finishTerminalTransient(id: id)
            } else {
                _ = finishTerminalTransient(id: id)
            }
        }
    }

    // MARK: Surface lifecycle

    private func ensureSurface(
        for runtime: GaiCompanionRuntime,
        baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        if let surface = runtime.surfaceView { return surface }
        guard let app = ghostty.app else {
            Ghostty.logger.warning("cannot create companion surface: ghostty app not loaded")
            return nil
        }

        runtime.prepareForNewSurfaceIncarnation()

        var config = baseConfig ?? Ghostty.SurfaceConfiguration()
        config.workingDirectory = config.workingDirectory ?? runtime.record.directoryPath
        config.command = config.command ?? runtime.record.launchCommand
        config.environmentVariables["GAITERM_COMPANION_ID"] = runtime.id.uuidString
        config.environmentVariables["GAITERM_SURFACE_ID"] = runtime.id.uuidString
        config.environmentVariables["GAITERM_EVENT_TOKEN"] = runtime.eventToken
        if let socketPath = (NSApp.delegate as? AppDelegate)?.gaiAgentEventSocketPath {
            config.environmentVariables["GAITERM_EVENT_SOCKET"] = socketPath
        }
        #if DEBUG
        let fallbackBundleIdentifier = "com.sipiyou.gaiterm.debug"
        #else
        let fallbackBundleIdentifier = "com.sipiyou.gaiterm"
        #endif
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
        config.environmentVariables["GAITERM_NOTIFY_BUNDLE_ID"] = bundleIdentifier
        config.environmentVariables["GAITERM_NOTIFY_URL_SCHEME"] =
            GaiCompanionEventEnvelope.scheme

        let surface = Ghostty.SurfaceView(app, baseConfig: config, uuid: runtime.id)
        surface.layer?.compositingFilter = nil
        surface.layer?.isOpaque = true
        if let rawSurface = surface.surface {
            ghostty_surface_set_background_rgb(rawSurface, 28, 28, 30)
            ghostty_surface_set_occlusion(rawSurface, false)
        }
        surface.focusDidChange(false)
        runtime.surfaceView = surface
        return surface
    }

    private func reopenTerminal(_ runtime: GaiCompanionRuntime, directory: String) {
        runtime.surfaceView?.gaiReleaseTerminalSurface()
        runtime.surfaceView = nil
        runtime.resetActivity()
        runtime.rotateEventToken()
        guard let record = store.update(id: runtime.id, {
            $0.directoryPath = directory
        }) else { return }
        runtime.replaceRecord(record)

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = record.directoryPath
        guard ensureSurface(for: runtime, baseConfig: config) != nil else { return }
        setPresentation(
            runtime.presentation == .collapsed ? .compact : runtime.presentation,
            for: runtime,
            animated: false,
            focus: true)
    }

    // MARK: Presentation and windows

    private func ensurePanel(for runtime: GaiCompanionRuntime) {
        guard panelControllers[runtime.id] == nil else { return }
        panelControllers[runtime.id] = GaiCompanionPanelController(
            runtime: runtime,
            manager: self)
    }

    private func setPresentation(
        _ presentation: GaiCompanionPresentation,
        for runtime: GaiCompanionRuntime,
        animated: Bool,
        focus: Bool
    ) {
        ensurePanel(for: runtime)
        if presentation != .collapsed,
           ensureSurface(for: runtime) == nil {
            return
        }
        let requestsFocus = focus && presentation != .collapsed

        if presentation != .collapsed {
            for other in runtimes where other.id != runtime.id {
                let terminalIsVisible = panelControllers[other.id]?.terminalPanel.isVisible == true
                guard other.presentation != .collapsed || terminalIsVisible else { continue }
                // Exclusivity is immediate: never leave two terminal panels
                // visible together during overlapping fade animations.
                setPresentation(.collapsed, for: other, animated: false, focus: false)
            }
        }

        // Resolve exclusivity while the layer is still hidden, then reveal only
        // the requested terminal. This avoids flashing the previously preserved
        // terminal for one compositor frame. The gate still lifts before the
        // completion acknowledgement and before the target is shown/focused.
        if requestsFocus {
            applyVisibilityPolicy(.presentAgentTerminal)
        }

        if presentation == .collapsed {
            // Invalidate any delayed first-responder attempt owned by the
            // terminal that is being hidden.
            focusGeneration &+= 1
        }
        runtime.presentation = presentation
        if requestsFocus {
            runtime.acknowledgeCompletion()
        }
        guard let controller = panelControllers[runtime.id] else { return }
        let screen = controller.companionPanel.isVisible
            ? (controller.companionPanel.screen ?? targetScreen(for: runtime))
            : targetScreen(for: runtime)
        let companionFrame = controller.companionPanel.isVisible
            ? controller.companionPanel.frame
            : companionFrame(for: runtime, screen: screen)
        let geometry = panelGeometry(
            for: runtime,
            presentation: presentation,
            screen: screen,
            companionFrame: companionFrame)
        runtime.terminalPlacement = geometry.placement
        let shouldFocus = requestsFocus && agentWindowsAreVisible
        controller.show(
            companionFrame: companionFrame,
            terminalFrame: geometry.terminalFrame,
            placement: geometry.placement,
            screen: screen,
            presentation: presentation,
            animated: animated,
            focus: shouldFocus,
            agentWindowsAreVisible: agentWindowsAreVisible)
        updateSurfacePerformanceState(focused: shouldFocus ? runtime.surfaceView : nil)
        if shouldFocus, let surface = runtime.surfaceView {
            requestTerminalFocus(for: runtime, surface: surface)
        }
        updateDockBadge()
    }

    private func showLibrary(activate: Bool) {
        if managerWindowController == nil {
            managerWindowController = GaiCompanionLibraryWindowController(manager: self)
        }
        managerWindowController?.show(activate: activate)
    }

    func panelDidBecomeKey(for id: UUID) {
        guard let runtime = runtime(id: id),
              runtime.presentation != .collapsed,
              panelControllers[id]?.terminalPanel.isKeyWindow == true else { return }
        guard let surface = ensureSurface(for: runtime) else { return }
        updateSurfacePerformanceState(focused: surface)
        requestTerminalFocus(for: runtime, surface: surface)
        updateDockBadge()
    }

    func panelDidResignKey(for id: UUID) {
        guard agentWindowsAreVisible, runtime(id: id) != nil else { return }
        focusGeneration &+= 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateSurfacePerformanceState()
            self.collapseTerminalAfterFocusLossIfNeeded(id: id)
        }
    }

    private func collapseTerminalAfterFocusLossIfNeeded(id: UUID) {
        guard let runtime = runtime(id: id),
              agentWindowsAreVisible,
              runtime.presentation != .collapsed,
              !runtime.isTerminalLocked,
              terminalTransientCounts[id, default: 0] == 0,
              let terminalPanel = panelControllers[id]?.terminalPanel,
              terminalPanel.isVisible,
              !terminalPanel.isKeyWindow,
              !keyWindowBelongs(to: terminalPanel)
        else { return }

        setPresentation(.collapsed, for: runtime, animated: true, focus: false)
    }

    private func keyWindowBelongs(to terminalPanel: NSWindow) -> Bool {
        guard var window = NSApp.keyWindow else { return false }
        while true {
            if window === terminalPanel { return true }
            guard let owner = window.sheetParent ?? window.parent else { return false }
            window = owner
        }
    }

    private func beginTerminalTransient(id: UUID) {
        guard runtime(id: id) != nil else { return }
        terminalTransientCounts[id, default: 0] += 1
    }

    @discardableResult
    private func finishTerminalTransient(id: UUID) -> Bool {
        guard let count = terminalTransientCounts[id], count > 0 else { return false }
        let remaining = count - 1
        if remaining == 0 {
            terminalTransientCounts.removeValue(forKey: id)
        } else {
            terminalTransientCounts[id] = remaining
        }
        return remaining == 0
    }

    private func refocusTerminalIfVisible(id: UUID) {
        guard let runtime = runtime(id: id),
              runtime.presentation != .collapsed,
              let surface = runtime.surfaceView,
              panelControllers[id]?.terminalPanel.isVisible == true
        else { return }
        requestTerminalFocus(for: runtime, surface: surface)
    }

    /// Makes the newly opened CLI ready for typing, including the first frame
    /// where SwiftUI may not have attached the existing SurfaceView yet. The
    /// generation prevents a late retry from an old companion stealing focus.
    private func requestTerminalFocus(
        for runtime: GaiCompanionRuntime,
        surface: Ghostty.SurfaceView
    ) {
        focusGeneration &+= 1
        applyTerminalFocus(
            for: runtime,
            surface: surface,
            generation: focusGeneration,
            attempt: 0)
    }

    private func applyTerminalFocus(
        for runtime: GaiCompanionRuntime,
        surface: Ghostty.SurfaceView,
        generation: UInt64,
        attempt: Int
    ) {
        guard generation == focusGeneration,
              self.runtime(id: runtime.id) === runtime,
              runtime.presentation != .collapsed,
              runtime.surfaceView === surface,
              let controller = panelControllers[runtime.id],
              controller.terminalPanel.isVisible else { return }

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.terminalPanel.makeKeyAndOrderFront(nil)
        controller.terminalPanel.makeMain()

        if surface.window === controller.terminalPanel,
           controller.terminalPanel.makeFirstResponder(surface) {
            updateSurfacePerformanceState(focused: surface)
            return
        }

        guard attempt < 5 else { return }
        let delay = 0.016 * pow(2, Double(attempt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak runtime, weak surface] in
            guard let self, let runtime, let surface else { return }
            self.applyTerminalFocus(
                for: runtime,
                surface: surface,
                generation: generation,
                attempt: attempt + 1)
        }
    }

    /// Lightweight drag path. Native child-window attachment owns normal drag
    /// motion; Swift only intervenes when the preview actually changes side.
    /// Persistence and record publication stay in `panelDidMove` after mouse-up.
    func panelIsMoving(for id: UUID, frame: NSRect, screen: NSScreen?) {
        guard let runtime = runtime(id: id), let screen else { return }
        let preview = compactPreviewGeometry(
            for: runtime,
            screen: screen,
            companionFrame: frame)
        if preview.placement != runtime.terminalPlacement {
            runtime.terminalPlacement = preview.placement
        }
        panelControllers[id]?.animateLivePlacement(
            terminalFrame: runtime.presentation == .compact ? preview.terminalFrame : nil,
            placement: preview.placement,
            screen: screen)
    }

    func panelDidMove(for id: UUID, frame: NSRect, screen: NSScreen?) {
        guard let runtime = runtime(id: id), let screen else { return }
        let visible = screen.visibleFrame
        let x = Double((frame.midX - visible.minX) / max(visible.width, 1))
        let y = Double((frame.midY - visible.minY) / max(visible.height, 1))
        guard let record = store.update(id: id, {
            $0.normalizedPosition = GaiCompanionNormalizedPosition(x: x, y: y)
            $0.displayID = displayID(for: screen)
        }) else { return }
        runtime.replaceRecord(record)

        let geometry = panelGeometry(
            for: runtime,
            presentation: runtime.presentation,
            screen: screen,
            companionFrame: frame)
        if geometry.placement != runtime.terminalPlacement {
            runtime.terminalPlacement = geometry.placement
        }
        // Do not apply a final clamped frame at mouse-up. The attached windows
        // are already in their live position; snapping them here reads as lag.
        // A last-moment side change still uses the same bounded FLIP as drag.
        panelControllers[id]?.animateLivePlacement(
            terminalFrame: runtime.presentation == .compact ? geometry.terminalFrame : nil,
            placement: geometry.placement,
            screen: screen)
        if runtime.presentation == .maximized,
           let terminalFrame = geometry.terminalFrame {
            panelControllers[id]?.moveMaximizedTerminal(to: terminalFrame)
        }
    }

    private func updateSurfacePerformanceState(focused preferred: Ghostty.SurfaceView? = nil) {
        let focused = preferred ?? focusedSurface()
        for runtime in runtimes {
            guard let view = runtime.surfaceView, let surface = view.surface else { continue }
            let visible = agentWindowsAreVisible
                && runtime.presentation != .collapsed
                && panelControllers[runtime.id]?.terminalPanel.isVisible == true
            ghostty_surface_set_occlusion(surface, visible)
            ghostty_surface_set_high_refresh(surface, visible)
            view.focusDidChange(visible && view === focused)
        }
    }

    // MARK: Events

    private func registerObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(didRequestNewSplit(_:)),
            name: Ghostty.Notification.ghosttyNewSplit, object: nil)
        center.addObserver(
            self, selector: #selector(didRequestCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
        center.addObserver(
            self, selector: #selector(didRequestToggleMaximize(_:)),
            name: .ghosttyMaximizeDidToggle, object: nil)
        center.addObserver(
            self, selector: #selector(didRequestToggleMaximize(_:)),
            name: Ghostty.Notification.didToggleSplitZoom, object: nil)
        center.addObserver(
            self, selector: #selector(didReceiveTerminalNotification(_:)),
            name: .gaiTerminalNotificationDidArrive, object: nil)
        center.addObserver(
            self, selector: #selector(didReceiveBell(_:)),
            name: .ghosttyBellDidRing, object: nil)
        center.addObserver(
            self, selector: #selector(didFinishShellCommand(_:)),
            name: .gaiSurfaceCommandDidFinish, object: nil)
        center.addObserver(
            self, selector: #selector(didReceiveUserInput(_:)),
            name: .gaiSurfaceDidReceiveUserInput, object: nil)
        center.addObserver(
            self, selector: #selector(didCancelAgentWork(_:)),
            name: .gaiSurfaceDidCancelAgentWork, object: nil)
        center.addObserver(
            self, selector: #selector(didRequestImmediateFocus(_:)),
            name: .gaiSurfaceDidRequestImmediateFocus, object: nil)
        center.addObserver(
            self, selector: #selector(screensDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func didRequestNewSplit(_ notification: Notification) {
        guard let parent = notification.object as? Ghostty.SurfaceView,
              runtime(id: parent.id) != nil else { return }
        let config = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
            as? Ghostty.SurfaceConfiguration
        _ = openTerminal(baseConfig: config, parent: parent)
    }

    @objc private func didRequestCloseSurface(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              runtime(id: surface.id) != nil else { return }
        if notification.userInfo?["process_alive"] as? Bool == false {
            handleNaturalTerminalExit(surface)
            return
        }
        closeSurface(surface)
    }

    private func handleNaturalTerminalExit(_ surface: Ghostty.SurfaceView) {
        guard let runtime = runtime(id: surface.id),
              runtime.surfaceView === surface else { return }

        let provider = inferredProvider(for: runtime)
        let event = GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: provider,
            eventID: nextEventID(prefix: "process-exit"),
            kind: .exited,
            source: .processLifecycle,
            message: "Terminal process exited")
        _ = applyLifecycleEvent(
            event,
            to: runtime,
            notificationTitle: providerDisplayName(provider),
            notificationBody: "Terminal exited")

        setPresentation(.collapsed, for: runtime, animated: true, focus: false)
        // Detach the dead PTY incarnation synchronously. A mascot click which
        // lands before the next run-loop turn must never recover this closing
        // surface and install it as the new terminal.
        runtime.surfaceView = nil
        runtime.rotateEventToken()
        updateSurfacePerformanceState()
        updateDockBadge()
        // The callback originates inside libghostty's close path. Release the
        // wrapper on the next main-loop turn to avoid freeing the surface while
        // that callback is still unwinding.
        DispatchQueue.main.async { [surface] in
            surface.gaiReleaseTerminalSurface()
        }
    }

    private func restartExitedTerminal(_ runtime: GaiCompanionRuntime) {
        runtime.resetActivity()
        // Natural exit already rotates after releasing the old PTY. Rotating
        // again makes an immediate relaunch safe even if a delayed hook exists.
        runtime.rotateEventToken()
        guard ensureSurface(for: runtime) != nil else { return }
        setPresentation(.compact, for: runtime, animated: true, focus: true)
    }

    @objc private func didRequestToggleMaximize(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              runtime(id: surface.id) != nil else { return }
        toggleMaximized(id: surface.id)
    }

    @objc private func didReceiveTerminalNotification(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              runtime(id: surface.id) != nil else { return }
        let title = notification.userInfo?[Notification.Name.GaiTerminalNotificationTitleKey]
            as? String ?? ""
        let body = notification.userInfo?[Notification.Name.GaiTerminalNotificationBodyKey]
            as? String ?? ""
        _ = recordExternalNotification(surfaceID: surface.id, title: title, body: body)
    }

    @objc private func didReceiveBell(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let runtime = runtime(id: surface.id),
              !isCurrentlyViewed(runtime) else { return }
        let event = GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: .terminal,
            eventID: nextEventID(prefix: "bell"),
            kind: .awaitingInput,
            source: .terminalFallback,
            message: "Terminal is waiting for input")
        let disposition = runtime.apply(.event(event))
        if disposition == .appliedEvent {
            reconcileProvisionalExpiry(for: runtime)
        }
        updateDockBadge()
    }

    @objc private func didFinishShellCommand(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let runtime = runtime(id: surface.id),
              runtime.activity.phase.belongsToActiveGeneration else { return }

        let exitCode = notification.userInfo?[Notification.Name.GaiSurfaceCommandExitCodeKey]
            as? Int ?? -1
        let durationNanoseconds = (notification.userInfo?[
            Notification.Name.GaiSurfaceCommandDurationNanosecondsKey
        ] as? NSNumber)?.uint64Value ?? 0
        let provider = runtime.activity.provider ?? inferredProvider(for: runtime)
        let kind = GaiCompanionShellCompletionPolicy.eventKind(
            provider: provider,
            exitCode: exitCode,
            duration: .nanoseconds(durationNanoseconds),
            minimumTerminalTaskDuration: ghostty.config.notifyOnCommandFinishAfter)
        let event = GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: provider,
            eventID: nextEventID(prefix: "command-finished"),
            kind: kind,
            source: .processLifecycle,
            message: shellCompletionMessage(
                kind: kind,
                exitCode: exitCode))
        _ = applyLifecycleEvent(
            event,
            to: runtime,
            notificationTitle: providerDisplayName(provider),
            notificationBody: kind == .failed ? "Work failed" : "Work completed")
    }

    @objc private func didReceiveUserInput(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let runtime = runtime(id: surface.id) else { return }
        runtime.acknowledgeCompletion()
        let provider = inferredProvider(for: runtime)
        guard let kind = GaiCompanionInputPolicy.eventKind(
            provider: provider,
            phase: runtime.activity.phase,
            nativeAdapterIsReady: runtime.hasObservedNativeAdapter(for: provider))
        else {
            updateDockBadge()
            return
        }
        let event = GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: provider,
            eventID: nextEventID(prefix: "input"),
            kind: kind,
            source: .userInput,
            message: "Prompt submitted")
        let disposition = runtime.apply(.event(event))
        if disposition == .appliedEvent {
            reconcileProvisionalExpiry(for: runtime)
        }
        updateDockBadge()
    }

    @objc private func didCancelAgentWork(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let runtime = runtime(id: surface.id) else { return }
        switch runtime.activity.phase {
        case .working, .awaitingInput, .awaitingApproval:
            break
        default:
            return
        }
        let provider = inferredProvider(for: runtime)
        let event = GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: provider,
            eventID: nextEventID(prefix: "cancel"),
            kind: .cancelled,
            source: .userInput,
            message: "Work cancelled")
        _ = applyLifecycleEvent(
            event,
            to: runtime,
            notificationTitle: providerDisplayName(provider),
            notificationBody: "Work cancelled")
    }

    @objc private func didRequestImmediateFocus(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              runtime(id: surface.id) != nil else { return }
        focusSurface(surface)
    }

    @objc private func screensDidChange(_ notification: Notification) {
        _ = notification
        for runtime in runtimes {
            let screen = targetScreen(for: runtime)
            let companionFrame = companionFrame(for: runtime, screen: screen)
            let geometry = panelGeometry(
                for: runtime,
                presentation: runtime.presentation,
                screen: screen,
                companionFrame: companionFrame)
            runtime.terminalPlacement = geometry.placement
            panelControllers[runtime.id]?.show(
                companionFrame: companionFrame,
                terminalFrame: geometry.terminalFrame,
                placement: geometry.placement,
                screen: screen,
                presentation: runtime.presentation,
                animated: false,
                focus: false,
                agentWindowsAreVisible: agentWindowsAreVisible)
        }
    }

    @discardableResult
    private func applyLifecycleEvent(
        _ event: GaiCompanionEvent,
        to runtime: GaiCompanionRuntime,
        notificationTitle: String,
        notificationBody: String
    ) -> GaiCompanionReductionDisposition {
        let disposition = runtime.apply(.event(event))
        if disposition == .appliedEvent {
            reconcileProvisionalExpiry(for: runtime)
        }
        guard disposition == .appliedEvent else { return disposition }

        updateDockBadge()
        if event.kind == .stop, runtime.record.completionSoundEnabled {
            // Playback happens only after the reducer accepts this exact event,
            // so duplicate Stop hooks cannot replay the completion sound.
            GaiCompanionCompletionSoundPlayer.shared.play()
        }

        let shouldNotify: Bool
        switch event.kind {
        case .stop, .failed, .awaitingInput, .awaitingApproval:
            shouldNotify = true
        case .ready, .started, .resumed, .cancelled, .exited:
            shouldNotify = false
        }
        if shouldNotify, !isCurrentlyViewed(runtime) {
            deliverSystemNotification(
                for: runtime,
                title: self.notificationTitle(
                    for: runtime,
                    fallback: notificationTitle),
                body: notificationBody)
        }
        return disposition
    }

    private func reconcileProvisionalExpiry(for runtime: GaiCompanionRuntime) {
        provisionalExpiryTasks.removeValue(forKey: runtime.id)?.workItem.cancel()
        guard runtime.activity.phase == .working,
              let generation = runtime.activity.provisionalStartGeneration else { return }

        let runtimeID = runtime.id
        let token = runtime.eventToken
        let nonce = UUID()
        let workItem = DispatchWorkItem { [weak self, weak runtime] in
            guard let self,
                  let runtime,
                  self.provisionalExpiryTasks[runtimeID]?.nonce == nonce else { return }
            self.provisionalExpiryTasks.removeValue(forKey: runtimeID)
            guard self.runtime(id: runtimeID) === runtime,
                  runtime.eventToken == token else { return }
            let provider = self.inferredProvider(
                for: runtime,
                allowTitleFallback: false)
            guard GaiCompanionProvisionalExpiryPolicy.shouldExpire(
                stronglyInferredProvider: provider),
                  !runtime.hasObservedNativeAdapter(for: provider) else { return }
            let disposition = runtime.apply(
                .expireProvisionalStart(generation: generation))
            if disposition == .expiredProvisionalStart {
                self.updateDockBadge()
            }
        }
        provisionalExpiryTasks[runtimeID] = (nonce, workItem)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.provisionalStartLifetime,
            execute: workItem)
    }

    // MARK: Helpers

    private func runtime(id: UUID) -> GaiCompanionRuntime? {
        runtimes.first { $0.id == id }
    }

    private func isCurrentlyViewed(_ runtime: GaiCompanionRuntime) -> Bool {
        NSApp.isActive
            && runtime.presentation != .collapsed
            && panelControllers[runtime.id]?.terminalPanel.isKeyWindow == true
    }

    private func updateDockBadge() {
        let count = runtimes.reduce(into: 0) { total, runtime in
            switch runtime.activity.phase {
            case .completedUnseen, .awaitingInput, .awaitingApproval, .failed:
                total += 1
            default:
                break
            }
        }
        NSApp.dockTile.badgeLabel = count == 0 ? nil : "\(min(count, 99))"
        NSApp.dockTile.display()
    }

    private func eventKind(title: String, body: String) -> GaiCompanionEventKind {
        let value = "\(title) \(body)".lowercased()
        if value.contains("failed") || value.contains("error") { return .failed }
        if value.contains("turn complete")
            || value.contains("command finished")
            || value.contains("command succeeded")
            || value.contains("completed")
            || value.contains("finished") {
            return .stop
        }
        if value.contains("permission") || value.contains("approval") { return .awaitingApproval }
        if value.contains("input") || value.contains("question") { return .awaitingInput }
        return .awaitingInput
    }

    private func provider(title: String, runtime: GaiCompanionRuntime) -> GaiCompanionProvider {
        if let provider = GaiCompanionProviderClassifier.classify(terminalTitle: title) {
            return provider
        }
        return inferredProvider(for: runtime)
    }

    private func providerDisplayName(_ provider: GaiCompanionProvider) -> String {
        if provider == .codex { return "Codex" }
        if provider == .claude { return "Claude Code" }
        if provider == .agy { return "Agy" }
        if provider == .opencode { return "OpenCode" }
        return "Terminal"
    }

    private func notificationBody(for kind: GaiCompanionEventKind) -> String {
        switch kind {
        case .ready: "Ready"
        case .started: "Work started"
        case .resumed: "Work resumed"
        case .stop: "Task complete"
        case .awaitingInput: "Waiting for your input"
        case .awaitingApproval: "Waiting for approval"
        case .cancelled: "Work cancelled"
        case .failed: "The agent needs attention"
        case .exited: "Terminal exited"
        }
    }

    private func shellCompletionMessage(
        kind: GaiCompanionEventKind,
        exitCode: Int
    ) -> String {
        switch kind {
        case .stop:
            return "Foreground command finished"
        case .failed:
            return "Foreground command failed with exit code \(exitCode)"
        case .cancelled:
            return "Short shell command settled"
        default:
            return "Foreground command state changed"
        }
    }

    private func inferredProvider(
        for runtime: GaiCompanionRuntime,
        allowTitleFallback: Bool = true
    ) -> GaiCompanionProvider {
        let surface = runtime.surfaceView
        let foregroundPID = surface.flatMap { surface -> Int? in
            guard let rawSurface = surface.surface else { return nil }
            let pid = ghostty_surface_foreground_pid(rawSurface)
            guard pid != 0 else { return nil }
            return Int(exactly: pid)
        }
        let arguments = foregroundPID.map(
            GaiCompanionProcessArguments.arguments(forPID:)) ?? []
        return GaiCompanionProviderClassifier.classify(
            launchCommand: runtime.record.launchCommand,
            terminalTitle: allowTitleFallback ? surface?.title : nil,
            argv: arguments) ?? .terminal
    }

    private func nextEventID(prefix: String) -> String {
        eventSequence &+= 1
        return "\(prefix)-\(eventSequence)-\(UUID().uuidString)"
    }

    private func deliverSystemNotification(
        for runtime: GaiCompanionRuntime,
        title: String,
        body: String
    ) {
        guard GaiNotificationSoundLibrary.desktopNotificationsEnabled(),
              let surface = runtime.surfaceView
        else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.scheduleSystemNotification(surface, title: title, body: body)

            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    if let error {
                        Ghostty.logger.error(
                            "could not request companion notification authorization: \(error, privacy: .public)")
                    }
                    guard granted else { return }
                    self.scheduleSystemNotification(surface, title: title, body: body)
                }

            default:
                return
            }
        }
    }

    private func scheduleSystemNotification(
        _ surface: Ghostty.SurfaceView,
        title: String,
        body: String
    ) {
        DispatchQueue.main.async { [weak surface] in
            surface?.showUserNotification(
                title: title,
                body: body,
                subtitle: "",
                requireFocus: false,
                sound: nil)
        }
    }

    private func notificationTitle(for runtime: GaiCompanionRuntime, fallback: String) -> String {
        let name = runtime.record.displayName
        if !name.isEmpty { return name }
        return fallback.isEmpty ? "DouDou Company" : fallback
    }

    private func suggestedPosition(for index: Int) -> GaiCompanionNormalizedPosition {
        let column = index % 4
        let row = (index / 4) % 3
        return GaiCompanionNormalizedPosition(
            x: 0.18 + Double(column) * 0.2,
            y: 0.2 + Double(row) * 0.26)
    }

    private func previewScale(
        _ runtime: GaiCompanionRuntime,
        scalePercent: GaiCompanionScalePercent
    ) {
        guard runtime.record.scalePercent != scalePercent else { return }
        let controller = panelControllers[runtime.id]
        let screen = controller?.companionPanel.screen ?? targetScreen(for: runtime)
        let currentFrame: NSRect
        if let controller, controller.companionPanel.isVisible {
            currentFrame = controller.companionPanel.frame
        } else {
            currentFrame = companionFrame(for: runtime, screen: screen)
        }

        let size = companionPanelSize(scalePercent: scalePercent)
        let workArea = screen.visibleFrame.insetBy(
            dx: Self.screenMargin,
            dy: Self.screenMargin)
        let resizedFrame = clamped(
            NSRect(
                x: currentFrame.midX - size.width / 2,
                y: currentFrame.midY - size.height / 2,
                width: size.width,
                height: size.height),
            to: workArea)
        let visible = screen.visibleFrame
        let normalizedPosition = GaiCompanionNormalizedPosition(
            x: Double((resizedFrame.midX - visible.minX) / max(visible.width, 1)),
            y: Double((resizedFrame.midY - visible.minY) / max(visible.height, 1)))

        var previewedRecord = runtime.record
        previewedRecord.scalePercent = scalePercent
        previewedRecord.normalizedPosition = normalizedPosition
        previewedRecord.displayID = displayID(for: screen)
        runtime.replaceRecord(previewedRecord.normalized())

        let geometry = panelGeometry(
            for: runtime,
            presentation: runtime.presentation,
            screen: screen,
            companionFrame: resizedFrame)
        runtime.terminalPlacement = geometry.placement
        controller?.resizeCompanion(
            companionFrame: resizedFrame,
            terminalFrame: runtime.presentation == .compact
                ? geometry.terminalFrame
                : nil,
            placement: geometry.placement,
            screen: screen)
    }

    private func companionFrame(for runtime: GaiCompanionRuntime, screen: NSScreen) -> NSRect {
        let workArea = screen.visibleFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        let size = companionPanelSize(scalePercent: runtime.record.scalePercent)
        let centerX = screen.visibleFrame.minX
            + screen.visibleFrame.width * CGFloat(runtime.record.normalizedPosition.x)
        let centerY = screen.visibleFrame.minY
            + screen.visibleFrame.height * CGFloat(runtime.record.normalizedPosition.y)
        let raw = NSRect(
            x: centerX - size.width / 2,
            y: centerY - size.height / 2,
            width: size.width,
            height: size.height)
        return clamped(raw, to: workArea)
    }

    private func companionPanelSize(
        scalePercent: GaiCompanionScalePercent
    ) -> NSSize {
        return NSSize(
            width: CGFloat(GaiCompanionVisualMetrics.scaledPanelWidth(for: scalePercent)),
            height: CGFloat(GaiCompanionVisualMetrics.scaledPanelHeight(for: scalePercent)))
    }

    private func panelGeometry(
        for runtime: GaiCompanionRuntime,
        presentation: GaiCompanionPresentation,
        screen: NSScreen,
        companionFrame: NSRect
    ) -> (
        placement: GaiCompanionTerminalPlacement,
        terminalFrame: NSRect?
    ) {
        let preview = compactPreviewGeometry(
            for: runtime,
            screen: screen,
            companionFrame: companionFrame)
        let terminalFrame: NSRect?
        switch presentation {
        case .collapsed:
            terminalFrame = nil
        case .compact:
            terminalFrame = preview.terminalFrame
        case .maximized:
            terminalFrame = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        }
        return (preview.placement, terminalFrame)
    }

    /// Native/AppKit port of GaiWork's `chooseCompanionPreviewGeometry`.
    /// The terminal is scored on all four sides while the companion frame
    /// remains the immutable anchor.
    private func compactPreviewGeometry(
        for runtime: GaiCompanionRuntime,
        screen: NSScreen,
        companionFrame: NSRect
    ) -> GaiCompanionPreviewGeometry {
        let workArea = screen.visibleFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        let size = NSSize(
            width: min(max(CGFloat(runtime.record.compactSize.width), 220), workArea.width),
            height: min(
                CGFloat(runtime.record.compactSize.height) + GaiStageMetrics.paneHeaderHeight,
                workArea.height))
        let rawCandidates = rawPreviewCandidates(
            companionFrame: companionFrame,
            terminalSize: size)
        let obstacles = panelControllers.compactMap { id, controller -> [NSRect]? in
            guard id != runtime.id else { return nil }
            var frames: [NSRect] = []
            if controller.companionPanel.isVisible {
                frames.append(controller.companionPanel.frame)
            }
            if controller.terminalPanel.isVisible {
                frames.append(controller.terminalPanel.frame)
            }
            return frames
        }.flatMap { $0 }

        let selected = rawCandidates.enumerated().min { lhs, rhs in
            let left = constrained(lhs.element, to: workArea)
            let right = constrained(rhs.element, to: workArea)
            return placementScore(
                raw: lhs.element,
                constrained: left,
                preferenceIndex: lhs.offset,
                previousPlacement: runtime.terminalPlacement,
                companionFrame: companionFrame,
                obstacles: obstacles,
                workArea: workArea)
                < placementScore(
                    raw: rhs.element,
                    constrained: right,
                    preferenceIndex: rhs.offset,
                    previousPlacement: runtime.terminalPlacement,
                    companionFrame: companionFrame,
                    obstacles: obstacles,
                    workArea: workArea)
        }?.element ?? rawCandidates[0]
        return constrained(selected, to: workArea)
    }

    private func rawPreviewCandidates(
        companionFrame: NSRect,
        terminalSize: NSSize
    ) -> [GaiCompanionPreviewGeometry] {
        return [
            GaiCompanionPreviewGeometry(
                placement: .top,
                terminalFrame: NSRect(
                    x: companionFrame.midX - terminalSize.width / 2,
                    y: companionFrame.maxY + Self.terminalGap,
                    width: terminalSize.width,
                    height: terminalSize.height)),
            GaiCompanionPreviewGeometry(
                placement: .bottom,
                terminalFrame: NSRect(
                    x: companionFrame.midX - terminalSize.width / 2,
                    y: companionFrame.minY - Self.terminalGap - terminalSize.height,
                    width: terminalSize.width,
                    height: terminalSize.height)),
            GaiCompanionPreviewGeometry(
                placement: .right,
                terminalFrame: NSRect(
                    x: companionFrame.maxX + Self.terminalGap,
                    y: companionFrame.midY - terminalSize.height / 2,
                    width: terminalSize.width,
                    height: terminalSize.height)),
            GaiCompanionPreviewGeometry(
                placement: .left,
                terminalFrame: NSRect(
                    x: companionFrame.minX - Self.terminalGap - terminalSize.width,
                    y: companionFrame.midY - terminalSize.height / 2,
                    width: terminalSize.width,
                    height: terminalSize.height)),
        ]
    }

    private func constrained(
        _ geometry: GaiCompanionPreviewGeometry,
        to workArea: NSRect
    ) -> GaiCompanionPreviewGeometry {
        GaiCompanionPreviewGeometry(
            placement: geometry.placement,
            terminalFrame: clamped(geometry.terminalFrame, to: workArea))
    }

    private func placementScore(
        raw: GaiCompanionPreviewGeometry,
        constrained: GaiCompanionPreviewGeometry,
        preferenceIndex: Int,
        previousPlacement: GaiCompanionTerminalPlacement,
        companionFrame: NSRect,
        obstacles: [NSRect],
        workArea: NSRect
    ) -> CGFloat {
        let overflow = overflowDistance(raw.terminalFrame, from: workArea)
        let obstaclePenalty = obstacles.reduce(CGFloat.zero) {
            $0 + intersectionArea(constrained.terminalFrame, $1) * 1_000
        }
        let companionArea = intersectionArea(constrained.terminalFrame, companionFrame)
        let hysteresis: CGFloat = raw.placement == previousPlacement ? -2_400_000 : 0
        return overflow * 100_000
            + obstaclePenalty
            + companionArea * 1_000_000
            + CGFloat(preferenceIndex) * 1_000
            + hysteresis
    }

    private func overflowDistance(_ frame: NSRect, from workArea: NSRect) -> CGFloat {
        max(0, workArea.minX - frame.minX)
            + max(0, frame.maxX - workArea.maxX)
            + max(0, workArea.minY - frame.minY)
            + max(0, frame.maxY - workArea.maxY)
    }

    private func clamped(_ frame: NSRect, to workArea: NSRect) -> NSRect {
        let width = min(frame.width, workArea.width)
        let height = min(frame.height, workArea.height)
        let x = min(max(frame.minX, workArea.minX), workArea.maxX - width)
        let y = min(max(frame.minY, workArea.minY), workArea.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static let screenMargin: CGFloat = 12
    private static let terminalGap: CGFloat = 8

    private func targetScreen(for runtime: GaiCompanionRuntime) -> NSScreen {
        if let displayID = runtime.record.displayID,
           let screen = NSScreen.screens.first(where: { self.displayID(for: $0) == displayID }) {
            return screen
        }
        return screenUnderMouse()
    }

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func displayID(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.stringValue
    }
}
#endif
