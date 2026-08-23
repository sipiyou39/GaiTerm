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

enum GaiCompanionMascotActivation: Equatable, Sendable {
    case singleClick
    case doubleClick

    func targetPresentation(from current: GaiCompanionPresentation) -> GaiCompanionPresentation {
        switch self {
        case .singleClick:
            current == .collapsed ? .compact : .collapsed
        case .doubleClick:
            .maximized
        }
    }
}

/// Reusable window arrangements for the expanded companion terminal.
/// `workArea` is already inset from the menu bar and screen edges.
enum GaiCompanionTerminalLayoutPreset: String, CaseIterable, Equatable, Sendable {
    case fullScreen
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter

    func frame(in workArea: NSRect, gap requestedGap: CGFloat = 8) -> NSRect {
        guard workArea.width > 0, workArea.height > 0 else { return workArea }
        let gap = min(max(requestedGap, 0), min(workArea.width, workArea.height))
        let halfWidth = max((workArea.width - gap) / 2, 0)
        let halfHeight = max((workArea.height - gap) / 2, 0)
        let rightX = workArea.maxX - halfWidth
        let topY = workArea.maxY - halfHeight

        switch self {
        case .fullScreen:
            return workArea
        case .leftHalf:
            return NSRect(
                x: workArea.minX,
                y: workArea.minY,
                width: halfWidth,
                height: workArea.height)
        case .rightHalf:
            return NSRect(
                x: rightX,
                y: workArea.minY,
                width: halfWidth,
                height: workArea.height)
        case .topHalf:
            return NSRect(
                x: workArea.minX,
                y: topY,
                width: workArea.width,
                height: halfHeight)
        case .bottomHalf:
            return NSRect(
                x: workArea.minX,
                y: workArea.minY,
                width: workArea.width,
                height: halfHeight)
        case .topLeftQuarter:
            return NSRect(
                x: workArea.minX,
                y: topY,
                width: halfWidth,
                height: halfHeight)
        case .topRightQuarter:
            return NSRect(
                x: rightX,
                y: topY,
                width: halfWidth,
                height: halfHeight)
        case .bottomLeftQuarter:
            return NSRect(
                x: workArea.minX,
                y: workArea.minY,
                width: halfWidth,
                height: halfHeight)
        case .bottomRightQuarter:
            return NSRect(
                x: rightX,
                y: workArea.minY,
                width: halfWidth,
                height: halfHeight)
        }
    }
}

/// Converts Finder drops into one safe, editable input fragment. Nothing is
/// executed: the text is only sent to the foreground terminal application.
enum GaiCompanionDroppedPathInsertion {
    static func text(for urls: [URL]) -> String {
        text(forPaths: urls.filter(\.isFileURL).map { $0.standardizedFileURL.path })
    }

    static func text(forPaths paths: [String]) -> String {
        let escaped = paths.filter { !$0.isEmpty }.map(shellEscapedPath)
        guard !escaped.isEmpty else { return "" }
        return escaped.joined(separator: " ") + " "
    }

    private static func shellEscapedPath(_ path: String) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "/._-+,:@%="))
        if path.unicodeScalars.allSatisfy(safeCharacters.contains) {
            return path
        }

        if path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            var escaped = ""
            for scalar in path.unicodeScalars {
                switch scalar.value {
                case 0x09: escaped += "\\t"
                case 0x0A: escaped += "\\n"
                case 0x0D: escaped += "\\r"
                case 0x27: escaped += "\\'"
                case 0x5C: escaped += "\\\\"
                case 0x00...0x1F, 0x7F:
                    escaped += String(format: "\\x%02X", scalar.value)
                default:
                    escaped.unicodeScalars.append(scalar)
                }
            }
            return "$'\(escaped)'"
        }

        // Ordinary spaces and punctuation stay readable with POSIX single
        // quotes. Embedded quotes use the standard close/escape/reopen form.
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum GaiCompanionFileDropPayload {
    static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let itemType = NSPasteboard.PasteboardType("public.item")
    static let dataType = NSPasteboard.PasteboardType("public.data")
    static let readableTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .string,
        legacyFilenamesType,
        itemType,
        dataType,
    ] + NSFilePromiseReceiver.readableDraggedTypes.map {
        NSPasteboard.PasteboardType($0)
    }

    static func isAdvertised(on pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return !Set(types).isDisjoint(with: Set(readableTypes))
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var candidates: [URL] = []

        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) {
            candidates.append(contentsOf: objects.compactMap { object in
                guard let url = object as? NSURL, url.isFileURL else { return nil }
                return url as URL
            })
        }

        if let items = pasteboard.pasteboardItems {
            candidates.append(contentsOf: items.compactMap { item in
                guard let value = item.string(forType: .fileURL),
                      let url = URL(string: value),
                      url.isFileURL else { return nil }
                return url
            })
        }

        if let paths = pasteboard.propertyList(forType: legacyFilenamesType) as? [String] {
            candidates.append(contentsOf: paths.map(URL.init(fileURLWithPath:)))
        }

        if candidates.isEmpty,
           let text = pasteboard.string(forType: .string) {
            let paths = text.components(separatedBy: .newlines).filter {
                $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0)
            }
            candidates.append(contentsOf: paths.map(URL.init(fileURLWithPath:)))
        }

        var seenPaths = Set<String>()
        return candidates.compactMap { candidate in
            let url = candidate.standardizedFileURL
            guard seenPaths.insert(url.path).inserted else { return nil }
            return url
        }
    }
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

/// Recovers an authenticated provider Stop only for the exact Teddy-owned turn
/// which is still active. This path exists for a lost/rejected intermediate
/// start event or a provider Stop whose optional final-message field could not
/// be decoded. Explicit conflicting turn identifiers remain a hard boundary.
enum GaiAuthenticatedStopRecoveryPolicy {
    static func shouldRecover(
        event: GaiCompanionEvent,
        disposition: GaiCompanionReductionDisposition,
        state: GaiCompanionActivityState,
        pendingTurn: GaiCompanionLastResponseStore.PendingTurnContext?
    ) -> Bool {
        switch disposition {
        case .ignoredStaleEvent, .ignoredStaleTurn, .ignoredLowerAuthority:
            break
        case .appliedEvent, .acknowledged, .duplicateEvent,
             .ignoredInvalidEventID, .ignoredWrongSurface, .ignoredAfterExit,
             .ignoredStaleAcknowledgement, .ignoredStaleProvisionalExpiry,
             .expiredProvisionalStart:
            return false
        }

        guard let pendingTurn,
              event.source == .providerHook,
              event.kind == .stop,
              event.timestamp >= pendingTurn.beganAt,
              pendingTurn.origin == .teddy,
              state.phase == .working,
              state.provider == event.provider else {
            return false
        }

        guard let currentTurnID = state.turnID,
              let eventTurnID = event.turnID else {
            // A missing identifier is recoverable because the manager also
            // correlates surface capability, active generation and Teddy's
            // pending response token before this policy is called.
            return true
        }
        return currentTurnID == eventTurnID
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
    @Published var isInlineTerminalPresented = false
    @Published var isDesktopSelected = false
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
           event.kind == .ready || event.kind == .started {
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

/// One bounded settlement probe for one exact response turn. The probe exists
/// only while that turn is active and is invalidated by the PTY incarnation,
/// activity generation and response token together.
private final class GaiCompanionResponseSettlementWatchdog {
    let runtimeID: UUID
    let incarnationToken: String
    let generation: UInt64
    let responseToken: GaiCompanionLastResponseStore.TurnToken
    var observation = GaiResponseSettlementObservation()
    var workItem: DispatchWorkItem?

    init(
        runtimeID: UUID,
        incarnationToken: String,
        generation: UInt64,
        responseToken: GaiCompanionLastResponseStore.TurnToken
    ) {
        self.runtimeID = runtimeID
        self.incarnationToken = incarnationToken
        self.generation = generation
        self.responseToken = responseToken
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

/// Agent-first replacement for `GaiWorkspaceManager`.
///
/// It deliberately mirrors the old manager's public surface API so the rest of
/// Ghostty, App Intents, URL callbacks and menu actions need no Debug forks.
final class GaiCompanionManager: NSObject, ObservableObject {
    @Published private(set) var runtimes: [GaiCompanionRuntime] = []
    @Published private(set) var agentWindowsAreVisible = true
    @Published private(set) var selectedCompanionID: UUID?

    private let ghostty: Ghostty.App
    private let store: GaiCompanionStore
    private let userDefaults: UserDefaults
    private var panelControllers: [UUID: GaiCompanionPanelController] = [:]
    private var managerWindowController: GaiCompanionLibraryWindowController?
    private var expandedTerminalSize: GaiCompanionExpandedTerminalSize?
    private var expandedTerminalPosition: GaiCompanionExpandedTerminalPosition?
    private var started = false
    private var eventSequence: UInt64 = 0
    private var focusGeneration: UInt64 = 0
    /// At most Teddy's selected CLI normally lives here. Keeping the set
    /// explicit lets the renderer distinguish a collapsed desktop panel from
    /// the very same surface being visibly hosted inside Teddy.
    private var inlineTerminalVisibleIDs: Set<UUID> = []
    private var terminalTransientCounts: [UUID: Int] = [:]
    private var activeCloseConfirmationIDs: Set<UUID> = []
    private var closeAllConfirmationIsPresented = false
    private let lastResponseStore = GaiCompanionLastResponseStore()
    private var responseCaptureTasks: [UUID: DispatchWorkItem] = [:]
    private var responseSettlementWatchdogs: [
        UUID: GaiCompanionResponseSettlementWatchdog
    ] = [:]
    private var provisionalExpiryTasks: [
        UUID: (nonce: UUID, workItem: DispatchWorkItem)
    ] = [:]
    private var globalFileDragMonitor: Any?
    private var globalFileDragPollTimer: DispatchSourceTimer?
    private var globalFileDragPollingIsActive = false
    private var globalFileDropTargetID: UUID?
    private var globalFileDropURLs: [URL] = []
    private var activeGlobalFileDragChangeCount: Int?
    private var settledGlobalFileDragChangeCount = 0
    private var mostRecentFileDrop: (
        id: UUID,
        paths: [String],
        timestamp: TimeInterval
    )?
    private var terminalFocusLossProtectionUntil: [UUID: TimeInterval] = [:]
    private var fileDropFocusGeneration: [UUID: UInt64] = [:]
    private static let provisionalStartLifetime: TimeInterval = 3
    /// Provider hooks can arrive just before their final PTY write is rendered.
    /// These bounded retries stop as soon as one complete response is captured.
    private static let responseCaptureSettlementDelays: [TimeInterval] = [
        0.08, 0.18, 0.36, 0.72,
    ]
    /// The native provider Stop remains the fast path. A low-frequency screen
    /// sample runs only while work is active and recovers a lost Stop after a
    /// response has remained byte-identical for several consecutive samples.
    private static let responseSettlementSampleInterval: TimeInterval = 0.5

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        let userDefaults = UserDefaults.ghostty
        self.userDefaults = userDefaults
        store = GaiCompanionStore(userDefaults: userDefaults, loadImmediately: false)
        expandedTerminalSize = GaiCompanionExpandedTerminalSize(
            userDefaults: userDefaults)
        expandedTerminalPosition = GaiCompanionExpandedTerminalPosition(
            userDefaults: userDefaults)
        super.init()
        registerObservers()
    }

    deinit {
        for task in responseCaptureTasks.values {
            task.cancel()
        }
        for watchdog in responseSettlementWatchdogs.values {
            watchdog.cancel()
        }
        for task in provisionalExpiryTasks.values {
            task.workItem.cancel()
        }
        if let globalFileDragMonitor {
            NSEvent.removeMonitor(globalFileDragMonitor)
        }
        globalFileDragPollTimer?.cancel()
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
        installGlobalFileDropFallback()

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
        selectCompanion(id: runtime.id)
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
        guard let keyWindow = NSApp.keyWindow else { return nil }
        if let inlineSurface = keyWindow.firstResponder as? Ghostty.SurfaceView,
           currentRuntime(for: inlineSurface) != nil {
            return inlineSurface
        }
        return runtimes.first(where: {
            panelControllers[$0.id]?.terminalPanel === keyWindow
        })?.surfaceView
    }

    func focusSurface(_ surface: Ghostty.SurfaceView) {
        guard let runtime = currentRuntime(for: surface) else { return }

        // An inline surface already lives inside Teddy's key window. Promoting
        // it to the compact floating presentation here would first detach that
        // same NSView from Teddy, so the terminal appeared to close as soon as
        // the user clicked it or typed. Keep the native surface where it is and
        // only update its real first-responder/rendering state.
        if inlineTerminalVisibleIDs.contains(runtime.id) {
            if let window = surface.window,
               window.firstResponder !== surface {
                window.makeFirstResponder(surface)
            }
            updateSurfacePerformanceState(focused: surface)
            return
        }

        setPresentation(
            runtime.presentation == .maximized ? .maximized : .compact,
            for: runtime,
            animated: true,
            focus: true)
    }

    func closeSurface(_ surface: Ghostty.SurfaceView) {
        guard currentRuntime(for: surface) != nil else { return }
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
        let phaseBeforeEvent = runtime.activity.phase
        let pendingTurn = lastResponseStore.pendingTurn(for: runtime.id)
        if event.kind == .started,
           lastResponseStore.token(for: runtime.id) == nil,
           let surface = runtime.surfaceView {
            beginResponseTurn(for: runtime, surface: surface, origin: .user)
        }
        let disposition = applyLifecycleEvent(
            event,
            to: runtime,
            notificationTitle: providerDisplayName(event.provider),
            notificationBody: event.message ?? notificationBody(for: event.kind))
        if disposition == .appliedEvent {
            if event.kind == .started {
                _ = lastResponseStore.bindTurn(
                    agentID: runtime.id,
                    turnID: event.turnID)
            }
            logAgentEvent(
                event,
                disposition: disposition,
                phaseBefore: phaseBeforeEvent,
                phaseAfter: runtime.activity.phase)
            return .applied
        }

        // A Teddy submission is an app-owned, capability-correlated turn. If
        // Codex returns its authenticated final answer but an intermediate
        // lifecycle event was lost or rejected, recover that exact turn rather
        // than leaving the doudou stuck forever. A conflicting explicit turn
        // identifier is never rewritten.
        if GaiAuthenticatedStopRecoveryPolicy.shouldRecover(
            event: event,
            disposition: disposition,
            state: runtime.activity,
            pendingTurn: pendingTurn
        ) {
            let recovered = GaiCompanionEvent(
                surfaceID: event.surfaceID,
                provider: event.provider,
                eventID: nextEventID(prefix: "recovered-authenticated-stop"),
                turnID: runtime.activity.turnID,
                kind: .stop,
                source: .terminalObservation,
                timestamp: event.timestamp,
                message: event.message,
                responseText: event.responseText)
            let recoveredDisposition = applyLifecycleEvent(
                recovered,
                to: runtime,
                notificationTitle: providerDisplayName(event.provider),
                notificationBody: event.message ?? notificationBody(for: event.kind))
            if recoveredDisposition == .appliedEvent {
                logAgentEvent(
                    event,
                    disposition: recoveredDisposition,
                    phaseBefore: phaseBeforeEvent,
                    phaseAfter: runtime.activity.phase,
                    recovered: true)
                return .applied
            }
            logAgentEvent(
                event,
                disposition: recoveredDisposition,
                phaseBefore: phaseBeforeEvent,
                phaseAfter: runtime.activity.phase,
                recovered: true)
            return .consumedWithoutChange(recoveredDisposition)
        }
        logAgentEvent(
            event,
            disposition: disposition,
            phaseBefore: phaseBeforeEvent,
            phaseAfter: runtime.activity.phase)
        return .consumedWithoutChange(disposition)
    }

    /// Privacy-safe lifecycle trace. It deliberately excludes the surface ID,
    /// capability token, prompt and response contents while retaining enough
    /// information to diagnose a real provider integration failure.
    private func logAgentEvent(
        _ event: GaiCompanionEvent,
        disposition: GaiCompanionReductionDisposition,
        phaseBefore: GaiCompanionPhase,
        phaseAfter: GaiCompanionPhase,
        recovered: Bool = false
    ) {
        let summary = "agent event provider=\(event.provider.rawValue) "
            + "kind=\(event.kind.rawValue) before=\(phaseBefore.rawValue) "
            + "after=\(phaseAfter.rawValue) disposition=\(disposition.rawValue) "
            + "turn=\(event.turnID != nil) response=\(event.responseText != nil) "
            + "recovered=\(recovered)"
        Ghostty.logger.info("\(summary, privacy: .public)")
    }

    /// Returns the sole response retained for this companion. Every later
    /// accepted completion replaces it.
    func lastResponse(for id: UUID) -> GaiCompanionLastResponse? {
        lastResponseStore.lastResponse(for: id)
    }

    /// Lightweight, on-demand state exposed to Teddy. This projection never
    /// reads terminal contents and therefore remains safe to refresh in UI.
    func managedAgentSnapshots() -> [GaiManagedAgentSnapshot] {
        runtimes.map { runtime in
            GaiManagedAgentSnapshot(
                id: runtime.id,
                name: runtime.record.displayName,
                provider: runtime.activity.provider ?? inferredProvider(for: runtime),
                phase: runtime.activity.phase,
                directoryPath: runtime.record.directoryPath,
                launchCommand: runtime.record.launchCommand,
                lastResponse: lastResponseStore.lastResponse(for: runtime.id),
                isResponsePending: lastResponseStore.hasPendingTurn(for: runtime.id))
        }
    }

    /// Submits a prompt to an already-live doudou without revealing, focusing,
    /// or otherwise changing its terminal. User interaction with that same CLI
    /// remains completely normal before and after the submission.
    @MainActor
    func submitPrompt(_ text: String, to id: UUID) -> GaiCompanionControlReceipt {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failed(.emptyPrompt) }
        guard prompt.utf8.count <= GaiCompanionControl.maximumPromptByteCount else {
            return .failed(.promptTooLarge)
        }
        guard let runtime = runtime(id: id) else { return .failed(.unknownAgent) }
        guard runtime.activity.phase != .exited,
              let surfaceView = runtime.surfaceView,
              let surface = surfaceView.surfaceModel else {
            return .failed(.unavailableTerminal)
        }
        guard runtime.activity.phase != .working else {
            return .failed(.agentBusy)
        }

        beginResponseTurn(
            for: runtime,
            surface: surfaceView,
            origin: .teddy,
            submittedText: prompt)
        recordSubmittedInput(for: runtime, submissionIsGuaranteed: true)
        surface.sendText(prompt)
        surface.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
        surface.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .release))
        return .submitted(agentID: id)
    }

    /// Sends the same Ctrl-C a user would type. It does not kill the PTY or
    /// recreate the agent, so conversation state remains owned by the CLI.
    @MainActor
    func interruptAgent(id: UUID) -> GaiCompanionControlReceipt {
        guard let runtime = runtime(id: id) else { return .failed(.unknownAgent) }
        guard runtime.activity.phase != .exited,
              let surface = runtime.surfaceView?.surfaceModel else {
            return .failed(.unavailableTerminal)
        }

        let press = Ghostty.Input.KeyEvent(
            key: .c,
            action: .press,
            text: "c",
            mods: .ctrl,
            unshiftedCodepoint: 0x63)
        let release = Ghostty.Input.KeyEvent(
            key: .c,
            action: .release,
            text: "c",
            mods: .ctrl,
            unshiftedCodepoint: 0x63)
        surface.sendKeyEvent(press)
        surface.sendKeyEvent(release)

        let provider = inferredProvider(for: runtime)
        let event = GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: provider,
            eventID: nextEventID(prefix: "teddy-cancel"),
            kind: .cancelled,
            source: .userInput,
            message: "Work cancelled by Teddy")
        _ = applyLifecycleEvent(
            event,
            to: runtime,
            notificationTitle: providerDisplayName(provider),
            notificationBody: "Work cancelled")
        return .interrupted(agentID: id)
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

    /// Creates one ordinary doudou rooted in an explicitly selected folder.
    /// A CLI launch command is optional: `.terminal` preserves a plain shell,
    /// while `.codex` starts Codex inside that same normal terminal.
    @MainActor
    func createCompanion(
        directoryURL: URL,
        cli: GaiCompanionCreationCLI
    ) -> GaiManagedAgentSnapshot? {
        let directory = directoryURL.standardizedFileURL
        guard directory.isFileURL,
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = directory.path
        config.command = cli.launchCommand
        guard let surface = openTerminal(baseConfig: config) else { return nil }
        return managedAgentSnapshots().first { $0.id == surface.id }
    }

    /// Hands Teddy the existing live terminal surface for inline presentation.
    /// The floating terminal panel is collapsed first so AppKit never mounts
    /// the same NSView in two window hierarchies. The PTY and CLI process are
    /// deliberately left untouched.
    @MainActor
    func prepareInlineTerminalContent(
        id: UUID
    ) -> (surfaceView: Ghostty.SurfaceView, hostView: NSView)? {
        guard let runtime = runtime(id: id), runtime.activity.phase != .exited else {
            return nil
        }
        setPresentation(.collapsed, for: runtime, animated: false, focus: false)
        guard let surface = ensureSurface(for: runtime),
              let controller = panelControllers[id],
              let hostView = controller.detachTerminalContentForInlinePresentation()
        else { return nil }
        surface.focusDidChange(false)
        runtime.isInlineTerminalPresented = true
        inlineTerminalVisibleIDs.insert(id)
        updateSurfacePerformanceState()
        return (surface, hostView)
    }

    /// Reuses the live doudou identity inside Teddy's conversation list. The
    /// sprite is presentation-only: it shares the existing runtime state and
    /// never creates another terminal, process or polling loop.
    @MainActor
    func makeTeddyCompanionAvatarView(id: UUID, width: CGFloat) -> AnyView? {
        guard let runtime = runtime(id: id) else { return nil }
        return AnyView(
            GaiCompanionSpriteView(
                colorway: runtime.renderedColorway,
                animation: runtime.animation,
                size: width))
    }

    /// Mirrors SwiftUI's actual inline lifetime into the Ghostty renderer.
    /// No polling and no extra PTY are involved; this only changes the native
    /// visibility/high-refresh hints for the existing surface.
    @MainActor
    func setInlineTerminalVisible(_ visible: Bool, id: UUID) {
        guard let runtime = runtime(id: id) else {
            inlineTerminalVisibleIDs.remove(id)
            updateSurfacePerformanceState()
            return
        }
        guard runtime.activity.phase != .exited else {
            runtime.isInlineTerminalPresented = false
            inlineTerminalVisibleIDs.remove(id)
            updateSurfacePerformanceState()
            return
        }
        if visible {
            runtime.isInlineTerminalPresented = true
            inlineTerminalVisibleIDs.insert(id)
        } else {
            runtime.isInlineTerminalPresented = false
            inlineTerminalVisibleIDs.remove(id)
            panelControllers[id]?.restoreTerminalContentAfterInlinePresentation()
        }
        updateSurfacePerformanceState()
    }

    /// The inline terminal owns the only visible app header while it is
    /// mounted in Teddy. Its Vocal action comes back through this semantic
    /// event so the voice controller performs the ordinary unmount/restore
    /// path instead of the terminal view mutating two window hierarchies.
    @MainActor
    func requestTeddyVoiceMode(id: UUID) {
        guard let runtime = runtime(id: id), runtime.isInlineTerminalPresented else { return }
        NotificationCenter.default.post(
            name: .gaiCompanionInlineTerminalRequestedVoice,
            object: self,
            userInfo: [GaiCompanionControl.companionIDUserInfoKey: id])
    }

    private func detachInlineTerminalIfNeeded(id: UUID) {
        guard inlineTerminalVisibleIDs.remove(id) != nil else { return }
        runtime(id: id)?.isInlineTerminalPresented = false
        panelControllers[id]?.restoreTerminalContentAfterInlinePresentation()
        NotificationCenter.default.post(
            name: .gaiCompanionInlineTerminalDidDetach,
            object: self,
            userInfo: [GaiCompanionControl.companionIDUserInfoKey: id])
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

    /// Selects the desktop identity without touching its PTY or terminal
    /// presentation. This is the only state Option-right needs to route the
    /// next voice turn to the correct conversation.
    func selectCompanion(id: UUID) {
        guard let runtime = runtime(id: id) else { return }
        runtime.acknowledgeCompletion()
        updateDockBadge()
        guard selectedCompanionID != id else {
            panelControllers[id]?.setDesktopSelected(true)
            return
        }

        if let previousID = selectedCompanionID {
            self.runtime(id: previousID)?.isDesktopSelected = false
            panelControllers[previousID]?.setDesktopSelected(false)
        }
        selectedCompanionID = id
        runtime.isDesktopSelected = true
        panelControllers[id]?.setDesktopSelected(true)
        NotificationCenter.default.post(
            name: .gaiCompanionDesktopSelectionDidChange,
            object: self,
            userInfo: [GaiCompanionControl.companionIDUserInfoKey: id])
    }

    func requestOpenTeddy(
        id: UUID,
        presentation: GaiCompanionTeddyPresentation
    ) {
        guard runtime(id: id) != nil else { return }
        selectCompanion(id: id)
        NotificationCenter.default.post(
            name: .gaiCompanionOpenTeddyRequested,
            object: self,
            userInfo: [
                GaiCompanionControl.companionIDUserInfoKey: id,
                GaiCompanionControl.teddyPresentationUserInfoKey: presentation.rawValue,
            ])
    }

    func requestReplayLatestVoice(id: UUID) {
        guard runtime(id: id) != nil else { return }
        selectCompanion(id: id)
        NotificationCenter.default.post(
            name: .gaiCompanionReplayVoiceRequested,
            object: self,
            userInfo: [GaiCompanionControl.companionIDUserInfoKey: id])
    }

    func toggleTerminal(id: UUID) {
        activateCompanion(id: id, activation: .singleClick)
    }

    func openMaximizedTerminal(id: UUID) {
        activateCompanion(id: id, activation: .doubleClick)
    }

    private func activateCompanion(
        id: UUID,
        activation: GaiCompanionMascotActivation
    ) {
        guard let runtime = runtime(id: id) else { return }
        guard terminalTransientCounts[id, default: 0] == 0 else { return }
        if runtime.activity.phase == .exited {
            restartExitedTerminal(
                runtime,
                presentation: activation.targetPresentation(from: .collapsed))
            return
        }
        // Mascot clicks are explicit acknowledgement actions. Merely focusing
        // a window is not, because macOS can restore focus automatically.
        runtime.acknowledgeCompletion()
        let target = activation.targetPresentation(from: runtime.presentation)
        setPresentation(
            target,
            for: runtime,
            animated: true,
            focus: target != .collapsed)
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

    func applyExpandedTerminalLayout(
        id: UUID,
        preset: GaiCompanionTerminalLayoutPreset
    ) {
        guard let runtime = runtime(id: id),
              terminalTransientCounts[id, default: 0] == 0 else { return }
        ensurePanel(for: runtime)
        guard let controller = panelControllers[id] else { return }

        let fallbackScreen = controller.companionPanel.screen ?? targetScreen(for: runtime)
        let screen = runtime.presentation == .maximized
            ? (controller.terminalPanel.screen ?? fallbackScreen)
            : fallbackScreen
        let workArea = screen.visibleFrame.insetBy(
            dx: Self.expandedTerminalScreenMargin,
            dy: Self.expandedTerminalScreenMargin)
        persistExpandedTerminalGeometry(
            frame: preset.frame(in: workArea),
            screen: screen)
        setPresentation(.maximized, for: runtime, animated: true, focus: true)
    }

    @MainActor
    func insertDroppedFileURLs(_ urls: [URL], into id: UUID) {
        let paths = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }
        let timestamp = Date.timeIntervalSinceReferenceDate
        if let mostRecentFileDrop,
           mostRecentFileDrop.id == id,
           mostRecentFileDrop.paths == paths,
           timestamp - mostRecentFileDrop.timestamp < 0.75 {
            return
        }
        mostRecentFileDrop = (id: id, paths: paths, timestamp: timestamp)

        let insertion = GaiCompanionDroppedPathInsertion.text(for: urls)
        guard !insertion.isEmpty,
              let runtime = runtime(id: id),
              terminalTransientCounts[id, default: 0] == 0 else { return }
        protectTerminalFromFocusLoss(id: id, duration: 1.25)

        if runtime.activity.phase == .exited {
            restartExitedTerminal(runtime)
        } else {
            runtime.acknowledgeCompletion()
            let target = runtime.presentation == .collapsed
                ? GaiCompanionPresentation.compact
                : runtime.presentation
            setPresentation(target, for: runtime, animated: true, focus: true)
        }

        guard let surface = runtime.surfaceView?.surfaceModel else {
            Ghostty.logger.error("companion file drop has no terminal surface")
            return
        }
        surface.sendText(insertion)
        stabilizeTerminalFocusAfterFileDrop(id: id)
    }

    private func installGlobalFileDropFallback() {
        guard globalFileDragMonitor == nil,
              globalFileDragPollTimer == nil else { return }
        settledGlobalFileDragChangeCount = NSPasteboard(name: .drag).changeCount
        globalFileDragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            let eventType = event.type
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in
                self?.handleGlobalFileDragEvent(
                    type: eventType,
                    location: location)
            }
        }

        let pollTimer = DispatchSource.makeTimerSource(queue: .main)
        pollTimer.schedule(
            deadline: .now(),
            repeating: .milliseconds(125),
            leeway: .milliseconds(25))
        pollTimer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.pollGlobalFileDragFallback()
            }
        }
        globalFileDragPollTimer = pollTimer
        pollTimer.resume()
    }

    @MainActor
    private func pollGlobalFileDragFallback() {
        let leftButtonIsPressed = NSEvent.pressedMouseButtons & 1 != 0
        updateGlobalFileDragPolling(active: leftButtonIsPressed)
        if leftButtonIsPressed {
            handleGlobalFileDragEvent(
                type: .leftMouseDragged,
                location: NSEvent.mouseLocation)
        } else if activeGlobalFileDragChangeCount != nil
                    || globalFileDropTargetID != nil {
            handleGlobalFileDragEvent(
                type: .leftMouseUp,
                location: NSEvent.mouseLocation)
        } else {
            // The drag pasteboard can be cleared or rewritten just after mouse
            // release. Keep the idle value as the baseline so a later ordinary
            // click can never reuse stale file data.
            settledGlobalFileDragChangeCount = NSPasteboard(name: .drag).changeCount
        }
    }

    @MainActor
    private func handleGlobalFileDragEvent(
        type: NSEvent.EventType,
        location: NSPoint
    ) {
        updateGlobalFileDragPolling(active: type == .leftMouseDragged)
        switch type {
        case .leftMouseDragged:
            let target = panelControllers.first { _, controller in
                agentWindowsAreVisible
                    && controller.companionPanel.isVisible
                    && controller.companionPanel.frame.contains(location)
            }
            guard let (targetID, controller) = target else {
                clearGlobalFileDropTarget()
                return
            }

            let pasteboard = NSPasteboard(name: .drag)
            let changeCount = pasteboard.changeCount
            guard activeGlobalFileDragChangeCount != nil
                    || changeCount != settledGlobalFileDragChangeCount
            else {
                clearGlobalFileDropTarget()
                return
            }
            let urls = GaiCompanionFileDropPayload.fileURLs(from: pasteboard)
            guard !urls.isEmpty
                    || GaiCompanionFileDropPayload.isAdvertised(on: pasteboard)
            else {
                clearGlobalFileDropTarget()
                return
            }
            activeGlobalFileDragChangeCount = changeCount

            if globalFileDropTargetID != targetID {
                clearGlobalFileDropTarget()
                globalFileDropTargetID = targetID
                controller.setExternalFileDragInterceptionActive(true)
                controller.setFallbackFileDropTargeted(true)
            }
            if !urls.isEmpty {
                globalFileDropURLs = urls
            }

        case .leftMouseUp:
            let pasteboard = NSPasteboard(name: .drag)
            settledGlobalFileDragChangeCount = pasteboard.changeCount
            activeGlobalFileDragChangeCount = nil
            guard let targetID = globalFileDropTargetID,
                  let controller = panelControllers[targetID],
                  controller.companionPanel.frame.contains(location)
            else {
                clearGlobalFileDropTarget()
                return
            }
            let liveURLs = GaiCompanionFileDropPayload.fileURLs(
                from: pasteboard)
            let urls = liveURLs.isEmpty ? globalFileDropURLs : liveURLs
            clearGlobalFileDropTarget()
            guard !urls.isEmpty else { return }
            controller.showFallbackFileDropAccepted(fileCount: urls.count)
            // Finder can briefly reclaim activation while its drag session is
            // unwinding. Open only after that final hand-off has completed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.insertDroppedFileURLs(urls, into: targetID)
            }

        default:
            break
        }
    }

    /// Keep the reliability poll inexpensive while idle, then follow an active
    /// drag at display cadence. The global event monitor remains the immediate
    /// path; this timer only covers Finder/AppKit sessions that skip events.
    private func updateGlobalFileDragPolling(active: Bool) {
        guard globalFileDragPollingIsActive != active,
              let timer = globalFileDragPollTimer else { return }
        globalFileDragPollingIsActive = active
        timer.schedule(
            deadline: .now(),
            repeating: active ? .milliseconds(8) : .milliseconds(125),
            leeway: active ? .milliseconds(1) : .milliseconds(25))
    }

    private func clearGlobalFileDropTarget() {
        if let targetID = globalFileDropTargetID {
            panelControllers[targetID]?.setExternalFileDragInterceptionActive(false)
            panelControllers[targetID]?.setFallbackFileDropTargeted(false)
        }
        globalFileDropTargetID = nil
        globalFileDropURLs = []
    }

    private func protectTerminalFromFocusLoss(
        id: UUID,
        duration: TimeInterval
    ) {
        let deadline = Date.timeIntervalSinceReferenceDate + duration
        terminalFocusLossProtectionUntil[id] = max(
            terminalFocusLossProtectionUntil[id] ?? 0,
            deadline)
    }

    private func terminalIsProtectedFromFocusLoss(id: UUID) -> Bool {
        guard let deadline = terminalFocusLossProtectionUntil[id] else { return false }
        if Date.timeIntervalSinceReferenceDate < deadline {
            return true
        }
        terminalFocusLossProtectionUntil.removeValue(forKey: id)
        return false
    }

    private func stabilizeTerminalFocusAfterFileDrop(id: UUID) {
        let generation = fileDropFocusGeneration[id, default: 0] &+ 1
        fileDropFocusGeneration[id] = generation
        let delays: [TimeInterval] = [0.08, 0.26, 0.52]

        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.fileDropFocusGeneration[id] == generation,
                      let runtime = self.runtime(id: id),
                      runtime.presentation != .collapsed else { return }
                self.refocusTerminalIfVisible(id: id)
                if index == delays.indices.last {
                    self.fileDropFocusGeneration.removeValue(forKey: id)
                }
            }
        }
    }

    private func closeCompanion(id: UUID) {
        guard let index = runtimes.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedCompanionID == id
        focusGeneration &+= 1
        detachInlineTerminalIfNeeded(id: id)
        terminalTransientCounts.removeValue(forKey: id)
        terminalFocusLossProtectionUntil.removeValue(forKey: id)
        fileDropFocusGeneration.removeValue(forKey: id)
        activeCloseConfirmationIDs.remove(id)
        responseCaptureTasks.removeValue(forKey: id)?.cancel()
        responseSettlementWatchdogs.removeValue(forKey: id)?.cancel()
        lastResponseStore.removeAgent(id)
        provisionalExpiryTasks.removeValue(forKey: id)?.workItem.cancel()
        let runtime = runtimes.remove(at: index)
        runtime.surfaceView?.gaiReleaseTerminalSurface()
        runtime.surfaceView = nil
        panelControllers.removeValue(forKey: id)?.close()
        _ = store.remove(id: id)
        if !runtimes.contains(where: { $0.record.completionSoundEnabled }) {
            GaiCompanionCompletionSoundPlayer.shared.stop()
        }
        if wasSelected {
            selectedCompanionID = nil
            if let replacement = runtimes.first {
                selectCompanion(id: replacement.id)
            }
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

    func rememberExpandedTerminalFrame(
        id: UUID,
        frame: NSRect,
        screen: NSScreen?
    ) {
        guard let runtime = runtime(id: id),
              runtime.presentation == .maximized,
              let screen else { return }
        persistExpandedTerminalGeometry(frame: frame, screen: screen)
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
        config.environmentVariables["GAITERM_NOTIFY_APP_PATH"] = Bundle.main.bundlePath
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
        // Persist first: a failed lookup must leave the live terminal untouched.
        guard let record = store.update(id: runtime.id, {
            $0.directoryPath = directory
        }) else { return }

        // Detach the old incarnation before releasing it. Its close callbacks
        // may be delivered synchronously and must not target the replacement
        // which deliberately shares the agent's stable UUID.
        let previousSurface = runtime.surfaceView
        runtime.surfaceView = nil
        runtime.resetActivity()
        runtime.rotateEventToken()
        runtime.replaceRecord(record)
        previousSurface?.gaiReleaseTerminalSurface()

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
        let controller = GaiCompanionPanelController(
            runtime: runtime,
            manager: self)
        panelControllers[runtime.id] = controller
        controller.setDesktopSelected(selectedCompanionID == runtime.id)
    }

    private func setPresentation(
        _ presentation: GaiCompanionPresentation,
        for runtime: GaiCompanionRuntime,
        animated: Bool,
        focus: Bool
    ) {
        ensurePanel(for: runtime)
        if presentation != .collapsed {
            detachInlineTerminalIfNeeded(id: runtime.id)
        }
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
        let companionScreen = controller.companionPanel.isVisible
            ? (controller.companionPanel.screen ?? targetScreen(for: runtime))
            : targetScreen(for: runtime)
        let companionFrame = controller.companionPanel.isVisible
            ? controller.companionPanel.frame
            : companionFrame(for: runtime, screen: companionScreen)
        let screen = presentation == .maximized
            ? expandedTerminalScreen(fallback: companionScreen)
            : companionScreen
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
        if terminalIsProtectedFromFocusLoss(id: id) {
            DispatchQueue.main.async { [weak self] in
                self?.updateSurfacePerformanceState()
            }
            return
        }
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
              !terminalIsProtectedFromFocusLoss(id: id),
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
    }

    private func updateSurfacePerformanceState(focused preferred: Ghostty.SurfaceView? = nil) {
        let focused = preferred ?? focusedSurface()
        for runtime in runtimes {
            guard let view = runtime.surfaceView, let surface = view.surface else { continue }
            let visibleInFloatingPanel = agentWindowsAreVisible
                && runtime.presentation != .collapsed
            let visible = visibleInFloatingPanel
                || inlineTerminalVisibleIDs.contains(runtime.id)
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
              currentRuntime(for: parent) != nil else { return }
        let config = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
            as? Ghostty.SurfaceConfiguration
        _ = openTerminal(baseConfig: config, parent: parent)
    }

    @objc private func didRequestCloseSurface(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              currentRuntime(for: surface) != nil else { return }
        if notification.userInfo?["process_alive"] as? Bool == false {
            handleNaturalTerminalExit(surface)
            return
        }
        closeSurface(surface)
    }

    private func handleNaturalTerminalExit(_ surface: Ghostty.SurfaceView) {
        guard let runtime = currentRuntime(for: surface) else { return }
        detachInlineTerminalIfNeeded(id: runtime.id)

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

    private func restartExitedTerminal(
        _ runtime: GaiCompanionRuntime,
        presentation: GaiCompanionPresentation = .compact
    ) {
        runtime.resetActivity()
        // Natural exit already rotates after releasing the old PTY. Rotating
        // again makes an immediate relaunch safe even if a delayed hook exists.
        runtime.rotateEventToken()
        guard ensureSurface(for: runtime) != nil else { return }
        setPresentation(presentation, for: runtime, animated: true, focus: true)
    }

    @objc private func didRequestToggleMaximize(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              currentRuntime(for: surface) != nil else { return }
        toggleMaximized(id: surface.id)
    }

    @objc private func didReceiveTerminalNotification(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              currentRuntime(for: surface) != nil else { return }
        let title = notification.userInfo?[Notification.Name.GaiTerminalNotificationTitleKey]
            as? String ?? ""
        let body = notification.userInfo?[Notification.Name.GaiTerminalNotificationBodyKey]
            as? String ?? ""
        _ = recordExternalNotification(surfaceID: surface.id, title: title, body: body)
    }

    @objc private func didReceiveBell(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let runtime = currentRuntime(for: surface),
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
            reconcileResponseSettlementWatchdog(for: runtime)
        }
        updateDockBadge()
    }

    @objc private func didFinishShellCommand(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let runtime = currentRuntime(for: surface),
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
              let runtime = currentRuntime(for: surface) else { return }
        beginResponseTurn(for: runtime, surface: surface, origin: .user)
        recordSubmittedInput(for: runtime)
    }

    private func recordSubmittedInput(
        for runtime: GaiCompanionRuntime,
        submissionIsGuaranteed: Bool = false
    ) {
        runtime.acknowledgeCompletion()
        let provider = inferredProvider(for: runtime)
        let kind: GaiCompanionEventKind?
        if submissionIsGuaranteed {
            // The tool router has already validated a live PTY and is about to
            // inject both the prompt and a real Enter. Unlike a speculative
            // physical key press, this is sufficient to open the local turn;
            // the provider start hook subsequently enriches it with turn_id.
            kind = GaiCompanionGuaranteedInputPolicy.eventKind(
                for: runtime.activity.phase)
        } else {
            kind = GaiCompanionInputPolicy.eventKind(
                provider: provider,
                phase: runtime.activity.phase,
                nativeAdapterIsReady: runtime.hasObservedNativeAdapter(for: provider))
        }
        guard let kind else {
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
            reconcileResponseSettlementWatchdog(for: runtime)
        }
        updateDockBadge()
    }

    @objc private func didCancelAgentWork(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let runtime = currentRuntime(for: surface) else { return }
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
              currentRuntime(for: surface) != nil else { return }
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
            reconcileResponseSettlementWatchdog(for: runtime)
        }
        guard disposition == .appliedEvent else { return disposition }

        switch event.kind {
        case .stop, .failed, .awaitingInput, .awaitingApproval:
            scheduleResponseCapture(for: event, runtime: runtime)
        case .cancelled, .exited:
            responseCaptureTasks.removeValue(forKey: runtime.id)?.cancel()
            responseSettlementWatchdogs.removeValue(forKey: runtime.id)?.cancel()
            lastResponseStore.resetTurn(for: runtime.id)
        case .ready, .started, .resumed:
            break
        }

        updateDockBadge()
        NotificationCenter.default.post(
            name: .gaiCompanionStateDidChange,
            object: self)
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

    private func beginResponseTurn(
        for runtime: GaiCompanionRuntime,
        surface: Ghostty.SurfaceView,
        origin: GaiInteractionOrigin,
        submittedText: String? = nil
    ) {
        responseCaptureTasks.removeValue(forKey: runtime.id)?.cancel()
        responseSettlementWatchdogs.removeValue(forKey: runtime.id)?.cancel()
        _ = lastResponseStore.begin(
            agentID: runtime.id,
            origin: origin,
            screenText: surface.gaiResponseCaptureScreenText(),
            submittedText: submittedText)
    }

    private func scheduleResponseCapture(
        for event: GaiCompanionEvent,
        runtime: GaiCompanionRuntime
    ) {
        guard let surface = runtime.surfaceView else { return }
        let token = lastResponseStore.token(for: runtime.id)
            ?? lastResponseStore.begin(
                agentID: runtime.id,
                origin: .user,
                screenText: "")
        responseCaptureTasks.removeValue(forKey: runtime.id)?.cancel()

        if let responseText = event.responseText {
            if let response = lastResponseStore.complete(
                token: token,
                provider: event.provider,
                eventID: event.eventID,
                turnID: event.turnID,
                responseText: responseText
            ) {
                publishLastResponse(response)
            }
            return
        }

        scheduleResponseCaptureAttempt(
            for: event,
            runtime: runtime,
            surface: surface,
            token: token,
            attempt: 0)
    }

    private func scheduleResponseCaptureAttempt(
        for event: GaiCompanionEvent,
        runtime: GaiCompanionRuntime,
        surface: Ghostty.SurfaceView,
        token: GaiCompanionLastResponseStore.TurnToken,
        attempt: Int
    ) {
        guard Self.responseCaptureSettlementDelays.indices.contains(attempt),
              lastResponseStore.token(for: runtime.id) == token else { return }

        let runtimeID = runtime.id
        let workItem = DispatchWorkItem { [weak self, weak runtime, weak surface] in
            guard let self,
                  let runtime,
                  let surface,
                  self.runtime(id: runtimeID) === runtime,
                  runtime.surfaceView === surface,
                  self.lastResponseStore.token(for: runtimeID) == token else { return }
            self.responseCaptureTasks[runtimeID] = nil
            if let response = self.lastResponseStore.complete(
                token: token,
                provider: event.provider,
                eventID: event.eventID,
                turnID: event.turnID,
                screenText: surface.gaiResponseCaptureScreenText()) {
                self.publishLastResponse(response)
                return
            }
            self.scheduleResponseCaptureAttempt(
                for: event,
                runtime: runtime,
                surface: surface,
                token: token,
                attempt: attempt + 1)
        }
        responseCaptureTasks[runtimeID] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.responseCaptureSettlementDelays[attempt],
            execute: workItem)
    }

    private func reconcileResponseSettlementWatchdog(
        for runtime: GaiCompanionRuntime
    ) {
        guard runtime.activity.phase == .working,
              runtime.activity.provider != .terminal,
              runtime.surfaceView != nil,
              let responseToken = lastResponseStore.token(for: runtime.id) else {
            responseSettlementWatchdogs.removeValue(forKey: runtime.id)?.cancel()
            return
        }

        if let current = responseSettlementWatchdogs[runtime.id],
           current.incarnationToken == runtime.eventToken,
           current.generation == runtime.activity.generation,
           current.responseToken == responseToken {
            return
        }

        responseSettlementWatchdogs.removeValue(forKey: runtime.id)?.cancel()
        let watchdog = GaiCompanionResponseSettlementWatchdog(
            runtimeID: runtime.id,
            incarnationToken: runtime.eventToken,
            generation: runtime.activity.generation,
            responseToken: responseToken)
        responseSettlementWatchdogs[runtime.id] = watchdog
        scheduleResponseSettlementSample(watchdog, runtime: runtime)
    }

    private func scheduleResponseSettlementSample(
        _ watchdog: GaiCompanionResponseSettlementWatchdog,
        runtime: GaiCompanionRuntime
    ) {
        let workItem = DispatchWorkItem { [weak self, weak runtime, weak watchdog] in
            guard let self,
                  let runtime,
                  let watchdog,
                  self.responseSettlementWatchdogs[watchdog.runtimeID] === watchdog,
                  self.runtime(id: watchdog.runtimeID) === runtime,
                  runtime.eventToken == watchdog.incarnationToken,
                  runtime.activity.generation == watchdog.generation,
                  runtime.activity.phase == .working,
                  self.lastResponseStore.token(for: watchdog.runtimeID)
                      == watchdog.responseToken,
                  let surface = runtime.surfaceView else {
                watchdog?.cancel()
                return
            }

            watchdog.workItem = nil
            let screenText = surface.gaiResponseCaptureScreenText()
            let candidate = self.lastResponseStore.candidateResponse(
                token: watchdog.responseToken,
                screenText: screenText)
            guard watchdog.observation.observe(
                screenText: screenText,
                candidateResponse: candidate) else {
                self.scheduleResponseSettlementSample(watchdog, runtime: runtime)
                return
            }

            self.responseSettlementWatchdogs.removeValue(
                forKey: watchdog.runtimeID)?.cancel()
            let provider = runtime.activity.provider
                ?? self.inferredProvider(for: runtime)
            let event = GaiCompanionEvent(
                surfaceID: runtime.id,
                provider: provider,
                eventID: self.nextEventID(prefix: "settled-response"),
                turnID: runtime.activity.turnID,
                kind: .stop,
                source: .terminalObservation,
                message: "Response settled")
            _ = self.applyLifecycleEvent(
                event,
                to: runtime,
                notificationTitle: self.providerDisplayName(provider),
                notificationBody: "Work completed")
        }
        watchdog.workItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.responseSettlementSampleInterval,
            execute: workItem)
    }

    private func publishLastResponse(_ response: GaiCompanionLastResponse) {
        NotificationCenter.default.post(
            name: .gaiCompanionLastResponseDidChange,
            object: self,
            userInfo: [GaiCompanionControl.responseUserInfoKey: response])
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
                self.reconcileResponseSettlementWatchdog(for: runtime)
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

    /// Surface UUIDs identify an agent and intentionally survive terminal
    /// restarts. Object identity distinguishes the currently mounted PTY from
    /// delayed notifications emitted by an incarnation which was just replaced.
    private func currentRuntime(
        for surface: Ghostty.SurfaceView
    ) -> GaiCompanionRuntime? {
        guard let runtime = runtime(id: surface.id),
              runtime.surfaceView === surface else { return nil }
        return runtime
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
            terminalFrame = expandedTerminalFrame(for: screen)
        }
        return (preview.placement, terminalFrame)
    }

    private func expandedTerminalFrame(for screen: NSScreen) -> NSRect {
        let workArea = screen.visibleFrame.insetBy(
            dx: Self.expandedTerminalScreenMargin,
            dy: Self.expandedTerminalScreenMargin)
        guard let expandedTerminalSize else { return workArea }

        let width = min(CGFloat(expandedTerminalSize.width), workArea.width)
        let height = min(CGFloat(expandedTerminalSize.height), workArea.height)
        let center = expandedTerminalPosition?.normalizedCenter ?? .center
        let frame = NSRect(
            x: workArea.minX + workArea.width * CGFloat(center.x) - width / 2,
            y: workArea.minY + workArea.height * CGFloat(center.y) - height / 2,
            width: width,
            height: height)
        return clamped(frame, to: workArea)
    }

    private func expandedTerminalScreen(fallback: NSScreen) -> NSScreen {
        guard let displayID = expandedTerminalPosition?.displayID,
              let screen = NSScreen.screens.first(where: {
                  self.displayID(for: $0) == displayID
              }) else { return fallback }
        return screen
    }

    private func persistExpandedTerminalGeometry(
        frame: NSRect,
        screen: NSScreen
    ) {
        let workArea = screen.visibleFrame.insetBy(
            dx: Self.expandedTerminalScreenMargin,
            dy: Self.expandedTerminalScreenMargin)
        let boundedFrame = clamped(frame, to: workArea)
        let rememberedSize = GaiCompanionExpandedTerminalSize(
            width: Double(boundedFrame.width),
            height: Double(boundedFrame.height))
        let rememberedPosition = GaiCompanionExpandedTerminalPosition(
            normalizedCenter: GaiCompanionNormalizedPosition(
                x: Double((boundedFrame.midX - workArea.minX) / max(workArea.width, 1)),
                y: Double((boundedFrame.midY - workArea.minY) / max(workArea.height, 1))),
            displayID: displayID(for: screen))

        if rememberedSize != expandedTerminalSize {
            expandedTerminalSize = rememberedSize
            if !rememberedSize.persist(to: userDefaults) {
                Ghostty.logger.error("could not persist expanded terminal size")
            }
        }
        if rememberedPosition != expandedTerminalPosition {
            expandedTerminalPosition = rememberedPosition
            if !rememberedPosition.persist(to: userDefaults) {
                Ghostty.logger.error("could not persist expanded terminal position")
            }
        }
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

    // swiftlint:disable:next function_parameter_count
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
    private static let expandedTerminalScreenMargin: CGFloat = 10

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
