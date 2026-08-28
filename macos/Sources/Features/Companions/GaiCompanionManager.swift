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
                + "agent from Teddy CLI. This cannot be undone. To only "
                + "hide it, cancel and use Hide Agents."
        }
        return "This permanently ends every running terminal and removes all "
            + "\(agentIDs.count) agents from Teddy CLI. This cannot be "
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

struct GaiCompanionPreviewGeometry: Equatable {
    let placement: GaiCompanionTerminalPlacement
    let terminalFrame: NSRect
}

/// Resolves one shared compact-terminal bay around an entire constellation.
/// The hovered agent is deliberately absent from the inputs: every doudou on
/// the same grid therefore reveals its CLI at the exact same place.
enum GaiCompanionTerminalBayLayout {
    static func resolve(
        companionFrames: [NSRect],
        anchorCenter: CGPoint,
        cellSize: CGSize,
        terminalSize: CGSize,
        workArea: NSRect,
        gap: CGFloat
    ) -> GaiCompanionPreviewGeometry {
        let frames = companionFrames.isEmpty
            ? [NSRect(origin: anchorCenter, size: .zero)]
            : companionFrames
        let constellationBounds = frames.dropFirst().reduce(frames[0]) {
            $0.union($1)
        }
        let size = CGSize(
            width: min(max(terminalSize.width, 1), workArea.width),
            height: min(max(terminalSize.height, 1), workArea.height))
        let alignedX = alignedCenter(
            nearest: constellationBounds.midX,
            anchor: anchorCenter.x,
            pitch: cellSize.width)
        let alignedY = alignedCenter(
            nearest: constellationBounds.midY,
            anchor: anchorCenter.y,
            pitch: cellSize.height)

        var candidates: [(geometry: GaiCompanionPreviewGeometry, tier: Int)] = [
            (GaiCompanionPreviewGeometry(
                placement: .top,
                terminalFrame: NSRect(
                    x: alignedX - size.width / 2,
                    y: constellationBounds.maxY + gap,
                    width: size.width,
                    height: size.height)), 0),
            (GaiCompanionPreviewGeometry(
                placement: .bottom,
                terminalFrame: NSRect(
                    x: alignedX - size.width / 2,
                    y: constellationBounds.minY - gap - size.height,
                    width: size.width,
                    height: size.height)), 0),
            (GaiCompanionPreviewGeometry(
                placement: .right,
                terminalFrame: NSRect(
                    x: constellationBounds.maxX + gap,
                    y: alignedY - size.height / 2,
                    width: size.width,
                    height: size.height)), 0),
            (GaiCompanionPreviewGeometry(
                placement: .left,
                terminalFrame: NSRect(
                    x: constellationBounds.minX - gap - size.width,
                    y: alignedY - size.height / 2,
                    width: size.width,
                    height: size.height)), 0),
        ]

        // A freeform constellation can span most of a display, leaving no
        // usable outside edge. Sample screen-fitting grid intersections as a
        // deterministic fallback and still prioritise a zero-doudou-overlap
        // cell over an adjacent candidate forced back through the stack.
        let xCenters = fittingCenters(
            minimum: workArea.minX + size.width / 2,
            maximum: workArea.maxX - size.width / 2,
            anchor: anchorCenter.x,
            pitch: cellSize.width)
        let yCenters = fittingCenters(
            minimum: workArea.minY + size.height / 2,
            maximum: workArea.maxY - size.height / 2,
            anchor: anchorCenter.y,
            pitch: cellSize.height)
        for y in yCenters {
            for x in xCenters {
                let frame = NSRect(
                    x: x - size.width / 2,
                    y: y - size.height / 2,
                    width: size.width,
                    height: size.height)
                candidates.append((GaiCompanionPreviewGeometry(
                    placement: placement(of: frame, relativeTo: constellationBounds),
                    terminalFrame: frame), 1))
            }
        }

        let selected = candidates.enumerated().min { lhs, rhs in
            score(
                candidate: lhs.element,
                index: lhs.offset,
                companionFrames: frames,
                constellationBounds: constellationBounds,
                workArea: workArea)
                .isPreferred(to: score(
                    candidate: rhs.element,
                    index: rhs.offset,
                    companionFrames: frames,
                    constellationBounds: constellationBounds,
                    workArea: workArea))
        }?.element.geometry ?? candidates[0].geometry
        return GaiCompanionPreviewGeometry(
            placement: selected.placement,
            terminalFrame: clamped(selected.terminalFrame, to: workArea))
    }

    private struct CandidateScore {
        let companionOverlap: CGFloat
        let overflow: CGFloat
        let constellationOverlap: CGFloat
        let tier: Int
        let distance: CGFloat
        let index: Int

        func isPreferred(to other: Self) -> Bool {
            // Staying attached to the constellation is the primary spatial
            // contract. A candidate may slide along the screen edge, but an
            // arbitrary empty screen cell must never beat an adjacent bay just
            // because the adjacent raw frame needed horizontal clamping.
            let lhs = [companionOverlap, constellationOverlap]
            let rhs = [other.companionOverlap, other.constellationOverlap]
            for (left, right) in zip(lhs, rhs) where abs(left - right) > 0.001 {
                return left < right
            }
            if tier != other.tier { return tier < other.tier }
            if abs(distance - other.distance) > 0.001 {
                return distance < other.distance
            }
            if abs(overflow - other.overflow) > 0.001 {
                return overflow < other.overflow
            }
            return index < other.index
        }
    }

    private static func score(
        candidate: (geometry: GaiCompanionPreviewGeometry, tier: Int),
        index: Int,
        companionFrames: [NSRect],
        constellationBounds: NSRect,
        workArea: NSRect
    ) -> CandidateScore {
        let raw = candidate.geometry.terminalFrame
        let bounded = clamped(raw, to: workArea)
        return CandidateScore(
            companionOverlap: companionFrames.reduce(0) {
                $0 + intersectionArea(bounded, $1)
            },
            overflow: overflowDistance(raw, from: workArea),
            constellationOverlap: intersectionArea(bounded, constellationBounds),
            tier: candidate.tier,
            distance: rectangleDistance(bounded, constellationBounds),
            index: index)
    }

    private static func alignedCenter(
        nearest value: CGFloat,
        anchor: CGFloat,
        pitch: CGFloat
    ) -> CGFloat {
        let safePitch = max(abs(pitch), 1)
        return anchor + ((value - anchor) / safePitch).rounded() * safePitch
    }

    private static func fittingCenters(
        minimum: CGFloat,
        maximum: CGFloat,
        anchor: CGFloat,
        pitch: CGFloat
    ) -> [CGFloat] {
        guard maximum >= minimum else { return [(minimum + maximum) / 2] }
        let safePitch = max(abs(pitch), 1)
        let first = Int(ceil((minimum - anchor) / safePitch))
        let last = Int(floor((maximum - anchor) / safePitch))
        var values = first <= last
            ? (first...last).map { anchor + CGFloat($0) * safePitch }
            : []
        values.append(contentsOf: [minimum, maximum])
        return values.sorted().reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > 0.5 }) ?? true {
                result.append(value)
            }
        }
    }

    private static func placement(
        of frame: NSRect,
        relativeTo bounds: NSRect
    ) -> GaiCompanionTerminalPlacement {
        let dx = frame.midX - bounds.midX
        let dy = frame.midY - bounds.midY
        if abs(dx) > abs(dy) {
            return dx >= 0 ? .right : .left
        }
        return dy >= 0 ? .top : .bottom
    }

    private static func clamped(_ frame: NSRect, to workArea: NSRect) -> NSRect {
        let width = min(frame.width, workArea.width)
        let height = min(frame.height, workArea.height)
        return NSRect(
            x: min(max(frame.minX, workArea.minX), workArea.maxX - width),
            y: min(max(frame.minY, workArea.minY), workArea.maxY - height),
            width: width,
            height: height)
    }

    private static func overflowDistance(_ frame: NSRect, from workArea: NSRect) -> CGFloat {
        max(0, workArea.minX - frame.minX)
            + max(0, frame.maxX - workArea.maxX)
            + max(0, workArea.minY - frame.minY)
            + max(0, frame.maxY - workArea.maxY)
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func rectangleDistance(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let dx = max(rhs.minX - lhs.maxX, lhs.minX - rhs.maxX, 0)
        let dy = max(rhs.minY - lhs.maxY, lhs.minY - rhs.maxY, 0)
        return hypot(dx, dy)
    }
}

private struct GaiCompanionHoverTerminalBayCache {
    let layout: GaiCompanionStackResolvedLayout
    let workArea: NSRect
    let geometry: GaiCompanionPreviewGeometry
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

enum GaiCompanionStackBadgePhase: Equatable {
    case hidden
    case preparing
    case visible
}

/// Runtime-only owner of one companion and its unique Ghostty surface.
/// Persisted configuration stays in `GaiCompanionStore`; the PTY never moves
/// to a second runtime when the panel changes presentation.
final class GaiCompanionRuntime: ObservableObject, Identifiable {
    let id: UUID
    private(set) var eventToken = UUID().uuidString.lowercased()

    @Published private(set) var record: GaiCompanionRecord
    /// Identity of the CLI process currently owning the PTY foreground.
    ///
    /// This is deliberately independent from `activity.provider`: activity is
    /// the immutable provenance of one lifecycle generation, while the live
    /// process may change from a shell to Codex (or back) between generations.
    @Published private(set) var liveProvider: GaiCompanionProvider
    @Published var surfaceView: Ghostty.SurfaceView?
    @Published var presentation: GaiCompanionPresentation = .collapsed
    @Published var terminalPlacement: GaiCompanionTerminalPlacement = .top
    @Published var isTerminalLocked = false
    @Published var isInlineTerminalPresented = false
    @Published var isDesktopSelected = false
    /// Greater than one only for the visible representative of a collapsed
    /// pile. The mascot view uses it to render depth and the member count.
    @Published var collapsedStackDepth = 0
    /// Backdrop materials are deliberately absent while a mascot window moves.
    /// They are mounted invisibly at the destination, then revealed once the
    /// compositor transition has stopped touching window geometry.
    @Published var stackBadgePhase: GaiCompanionStackBadgePhase = .hidden
    @Published private(set) var activity: GaiCompanionActivityState

    init(record: GaiCompanionRecord) {
        id = record.id
        self.record = record
        // A configured command is intent, not proof that the process launched.
        // Foreground argv or an authenticated provider event establishes life.
        liveProvider = .terminal
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
        var next = activity
        let disposition = GaiCompanionActivityReducer.apply(action, to: &next)
        activity = next
        reconcileLiveProvider(for: action, disposition: disposition)
        return disposition
    }

    /// Records a strong foreground-process observation without rewriting the
    /// provider which owns the current activity generation.
    @discardableResult
    func observeLiveProvider(_ provider: GaiCompanionProvider) -> Bool {
        guard provider != .terminal, liveProvider != provider else { return false }
        liveProvider = provider
        return true
    }

    /// Reconciles the shell Enter which launched an interactive CLI with the
    /// provider process observed a few milliseconds later.
    ///
    /// The original Enter is necessarily speculative: before the child process
    /// exists it looks like an ordinary shell command and opens a provisional
    /// terminal generation. Once Codex, Claude or Grok owns the foreground, that
    /// generation represents session startup rather than agent work. Settle only
    /// this exact terminal-owned provisional state; an actual prompt already
    /// owned by a provider must remain working.
    @discardableResult
    func reconcileLaunchedProvider(
        _ provider: GaiCompanionProvider,
        maySettleProvisionalShellLaunch: Bool
    ) -> GaiCompanionProviderLaunchReconciliation {
        guard provider != .terminal else { return .unchanged }
        let providerChanged = observeLiveProvider(provider)
        guard maySettleProvisionalShellLaunch,
              hasProvisionalShellLaunch,
              apply(.expireProvisionalStart(generation: activity.generation))
                  == .expiredProvisionalStart else {
            return providerChanged ? .providerObserved : .unchanged
        }
        return .settledProvisionalShellLaunch
    }

    var hasProvisionalShellLaunch: Bool {
        activity.phase == .working
            && activity.provider == .terminal
            && activity.provisionalStartGeneration == activity.generation
            && activity.generationAuthority == .userInput
    }

    /// Clears only process presence. Completion, failure and acknowledgement
    /// remain owned by the activity reducer.
    @discardableResult
    func clearLiveProvider() -> Bool {
        guard liveProvider != .terminal else { return false }
        liveProvider = .terminal
        return true
    }

    func acknowledgeCompletion() {
        guard let acknowledgement = activity.pendingAcknowledgement else { return }
        _ = apply(.acknowledge(acknowledgement))
    }

    func resetActivity() {
        activity = GaiCompanionActivityState(surfaceID: id)
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
        clearLiveProvider()
    }

    private func reconcileLiveProvider(
        for action: GaiCompanionActivityAction,
        disposition: GaiCompanionReductionDisposition
    ) {
        guard case .event(let event) = action,
              disposition == .appliedEvent || disposition == .duplicateEvent else { return }

        if event.source == .providerHook {
            if event.kind != .cancelled, event.provider != .terminal {
                observeLiveProvider(event.provider)
            }
        } else if event.source == .processLifecycle, event.kind == .exited {
            clearLiveProvider()
        }
    }
}

enum GaiCompanionProviderLaunchReconciliation: Equatable {
    case unchanged
    case providerObserved
    case settledProvisionalShellLaunch

    var changedRuntimeState: Bool { self != .unchanged }
    var settledProvisionalTurn: Bool { self == .settledProvisionalShellLaunch }
}

/// Finite foreground-process sampling used only around a real shell boundary.
/// There is no idle timer and therefore no continuous process polling cost.
enum GaiCompanionProviderProbeSchedule {
    enum Purpose: Equatable {
        case launch
        case shellReturn
    }

    private static let launchDelays: [TimeInterval] = [
        0.08, 0.16, 0.32, 0.64, 1.0,
    ]
    private static let shellReturnDelays: [TimeInterval] = [
        0.04, 0.12, 0.28,
    ]

    static func delay(for purpose: Purpose, attempt: Int) -> TimeInterval? {
        let delays = switch purpose {
        case .launch: launchDelays
        case .shellReturn: shellReturnDelays
        }
        guard delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }
}

/// A failed process inspection is not equivalent to observing the shell.
/// Keeping this distinction prevents a transient `sysctl` failure from
/// invalidating an otherwise authenticated live CLI identity.
enum GaiForegroundProviderObservation: Equatable {
    case provider(GaiCompanionProvider)
    case shell
    case unavailable

    /// Only an interactive shell is proof that the previous CLI returned.
    /// An unknown foreground executable is commonly a tool spawned by that
    /// CLI, so treating it as a shell would transiently revoke a live agent.
    static func classify(arguments: [String]?) -> Self {
        guard let arguments, let first = arguments.first, !first.isEmpty else {
            return .unavailable
        }
        if let provider = GaiCompanionProviderClassifier.classify(argv: arguments) {
            return .provider(provider)
        }

        var executable = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        if executable.hasPrefix("-") {
            executable.removeFirst()
        }
        guard interactiveShells.contains(executable) else { return .unavailable }

        let shellArguments = arguments.dropFirst()
        let launchesCommandOrScript = shellArguments.contains { argument in
            guard argument.hasPrefix("-") else { return true }
            if argument == "--command" || argument.hasPrefix("--command=") {
                return true
            }
            if argument.hasPrefix("--") { return false }
            return argument.dropFirst().lowercased().contains("c")
        }
        return launchesCommandOrScript ? .unavailable : .shell
    }

    private static let interactiveShells: Set<String> = [
        "bash", "csh", "dash", "fish", "ksh", "nu", "sh", "tcsh", "xonsh", "zsh",
    ]
}

/// The final, synchronous gate applied at the exact terminal-write boundary.
/// A caller may preserve authenticated process knowledge when inspection is
/// temporarily unavailable, but intent (a configured launch command, title or
/// empty shell) can never authorize a prompt.
enum GaiCompanionPromptProviderGate: Equatable {
    case observe(GaiCompanionProvider)
    case preserve(GaiCompanionProvider)
    case rejectAndClear
    case reject

    static func decision(
        observation: GaiForegroundProviderObservation,
        liveProvider: GaiCompanionProvider
    ) -> Self {
        switch observation {
        case .provider(let provider):
            return .observe(provider)
        case .shell:
            return liveProvider == .terminal ? .reject : .rejectAndClear
        case .unavailable:
            return liveProvider == .terminal ? .reject : .preserve(liveProvider)
        }
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

/// One finite probe created by one ambiguous manual Return. It never exists at
/// rest and cannot open a turn until the terminal has produced a response line
/// absent from its pre-Return baseline, keeping empty Return and static menu
/// confirmations presentation-neutral when a native start hook is absent.
private final class GaiCompanionResponseActivationProbe {
    let runtimeID: UUID
    let incarnationToken: String
    let responseToken: GaiCompanionLastResponseStore.TurnToken
    let provider: GaiCompanionProvider
    let observation: GaiResponseActivityObservation
    var workItem: DispatchWorkItem?

    init(
        runtimeID: UUID,
        incarnationToken: String,
        responseToken: GaiCompanionLastResponseStore.TurnToken,
        provider: GaiCompanionProvider,
        baselineScreenText: String
    ) {
        self.runtimeID = runtimeID
        self.incarnationToken = incarnationToken
        self.responseToken = responseToken
        self.provider = provider
        observation = GaiResponseActivityObservation(
            baselineScreenText: baselineScreenText)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

private struct GaiCompanionStackTransitionItem {
    let id: UUID
    let fromFrame: NSRect
    let toFrame: NSRect
    let delay: CFTimeInterval
    let bend: CGFloat
    let fromAlpha: CGFloat
    let toAlpha: CGFloat
    let fromScale: CGFloat
    let toScale: CGFloat
}

private struct GaiCompanionStackTransition {
    let expanding: Bool
    let isReflow: Bool
    let anchorID: UUID
    let startedAt: CFTimeInterval
    let duration: CFTimeInterval
    let items: [GaiCompanionStackTransitionItem]
    let finalLayout: GaiCompanionStackResolvedLayout
}

private struct GaiCompanionHubDragItem {
    var offset: CGPoint
    var velocity: CGVector
    var targetOffset: CGPoint
    let size: CGSize
}

private struct GaiCompanionHubDragMotion {
    var orientation: GaiCompanionStackOrientation
    var cellSize: CGSize
    var items: [UUID: GaiCompanionHubDragItem]
    var lastTimestamp: CFTimeInterval
    var pointerIsDown: Bool
}

private struct GaiCompanionSwapItem {
    var progress: CGFloat
    var velocity: CGFloat
    var targetProgress: CGFloat
}

private struct GaiCompanionSwapMotion {
    let movingID: UUID
    var activeTargetID: UUID?
    var hapticTargetID: UUID?
    var items: [UUID: GaiCompanionSwapItem]
    var lift: CGFloat
    var liftVelocity: CGFloat
    var targetLift: CGFloat
    var lastTimestamp: CFTimeInterval
}

/// Short, direct stack motion tuned for desktop productivity. The quartic
/// ease-out has immediate intent, reaches the readable area quickly and remains
/// strictly monotone: no overshoot and no long focus-like settling tail.
enum GaiCompanionStackMotion {
    static let expansionDuration: CFTimeInterval = 0.30
    static let collapseDuration = expansionDuration
    static let reflowDuration: CFTimeInterval = 0.26
    static let maximumStagger: CFTimeInterval = 0.032

    static func position(at progress: CGFloat) -> CGFloat {
        let t = min(max(progress, 0), 1)
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        let remaining = 1 - t
        return 1 - remaining * remaining * remaining * remaining
    }

    static func opacity(at progress: CGFloat) -> CGFloat {
        let t = min(max(progress / 0.34, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Exact time reversal of `position(at:)`. Because closing interpolates
    /// from the expanded frame back to the hub, reversing the opening film is
    /// `1 - opening(1 - t)` rather than simply reusing the ease-out curve.
    static func collapsePosition(at progress: CGFloat) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return 1 - position(at: 1 - t)
    }

    /// Exact time reversal of the opening fade. A closing item's interpolation
    /// runs from alpha one to zero, hence the complementary progress value.
    static func collapseOpacity(at progress: CGFloat) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return 1 - opacity(at: 1 - t)
    }

    static func localProgress(
        elapsed: CFTimeInterval,
        duration: CFTimeInterval,
        stagger: CFTimeInterval,
        reversing: Bool
    ) -> CGFloat {
        let availableDuration = max(duration - stagger, 0.001)
        let localElapsed = reversing ? elapsed : elapsed - stagger
        return CGFloat(min(max(localElapsed / availableDuration, 0), 1))
    }

    static func collapsedFrame(
        contentSize: CGSize,
        around anchorFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: anchorFrame.midX - contentSize.width / 2,
            y: anchorFrame.midY - contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height)
    }

}

/// Agent-first replacement for `GaiWorkspaceManager`.
///
/// It deliberately mirrors the old manager's public surface API so the rest of
/// Ghostty, App Intents, URL callbacks and menu actions need no Debug forks.
final class GaiCompanionManager: NSObject, ObservableObject {
    @Published private(set) var runtimes: [GaiCompanionRuntime] = []
    @Published private(set) var agentWindowsAreVisible = true
    /// Sticky desktop selection created only by an explicit mascot click.
    /// It owns the visible waveform action; hover routing must never mutate it.
    @Published private(set) var explicitlySelectedCompanionID: UUID?
    /// Current conversational input target. Hover may change this temporarily
    /// so Right Option talks to the doudou beneath the pointer.
    @Published private(set) var selectedCompanionID: UUID?
    @Published private(set) var companionStackIsExpanded = false

    private let ghostty: Ghostty.App
    private let store: GaiCompanionStore
    private let userDefaults: UserDefaults
    private var panelControllers: [UUID: GaiCompanionPanelController] = [:]
    private let companionHubID = UUID()
    private let companionHubState = GaiCompanionHubState()
    private var companionHubController: GaiCompanionHubPanelController?
    private var companionHubPlacement: GaiCompanionHubPlacement?
    private var companionHubScalePercent = GaiCompanionScalePercent.standard
    private var companionHubCreatorPlacement: GaiCompanionTerminalPlacement = .top
    private var activeCompanionStackLayout: GaiCompanionStackResolvedLayout?
    private var companionHoverTerminalBays: [String: GaiCompanionHoverTerminalBayCache] = [:]
    private var companionStackTransition: GaiCompanionStackTransition?
    private var hiddenCompanionStackTransitionIDs: Set<UUID> = []
    private var companionStackMode: GaiCompanionStackMode
    private var companionStackSwapMotion: GaiCompanionSwapMotion?
    private var companionHubDragMotion: GaiCompanionHubDragMotion?
    var onOpenCompanionCreator: (() -> Void)?
    private var expandedTerminalSize: GaiCompanionExpandedTerminalSize?
    private var expandedTerminalPosition: GaiCompanionExpandedTerminalPosition?
    private var started = false
    private var eventSequence: UInt64 = 0
    private var focusGeneration: UInt64 = 0
    private var activeSpaceRefreshGeneration: UInt64 = 0
    private var transientHoverInputTargetID: UUID?
    private var hoverFocusReturnApplication: NSRunningApplication?
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
    private var responseActivationProbes: [
        UUID: GaiCompanionResponseActivationProbe
    ] = [:]
    private var foregroundProviderProbeTasks: [
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
    private lazy var companionStackDisplayLink = GaiCompanionDisplayLink { [weak self] timestamp in
        self?.advanceCompanionStackTransition(at: timestamp)
    }
    private lazy var companionHubDragDisplayLink = GaiCompanionDisplayLink { [weak self] timestamp in
        self?.advanceCompanionHubDragMotion(at: timestamp)
    }
    private lazy var companionStackSwapDisplayLink = GaiCompanionDisplayLink { [weak self] timestamp in
        self?.advanceOrganicCompanionSwapMotion(at: timestamp)
    }
    /// Provider hooks can arrive just before their final PTY write is rendered.
    /// These bounded retries stop as soon as one complete response is captured.
    private static let responseCaptureSettlementDelays: [TimeInterval] = [
        0.08, 0.18, 0.36, 0.72,
    ]
    /// The native provider Stop remains the fast path. A low-frequency screen
    /// sample runs only while work is active and recovers a lost Stop after a
    /// response has remained byte-identical for several consecutive samples.
    private static let responseSettlementSampleInterval: TimeInterval = 0.5
    /// Cumulative duration is about 35 seconds, but only thirteen snapshots
    /// are read and only after a real Return. This covers slow first-token
    /// providers without introducing any idle polling.
    private static let responseActivationProbeDelays: [TimeInterval] = [
        0.05, 0.10, 0.15, 0.25, 0.40, 0.60, 1.00,
        1.50, 2.00, 3.00, 5.00, 8.00, 12.00,
    ]

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        let userDefaults = UserDefaults.ghostty
        self.userDefaults = userDefaults
        companionStackMode = GaiCompanionStackMode.current(in: userDefaults)
        companionHubPlacement = GaiCompanionHubPlacement(userDefaults: userDefaults)
        companionHubScalePercent = companionHubPlacement?.scalePercent ?? .standard
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
        for probe in responseActivationProbes.values {
            probe.cancel()
        }
        for task in foregroundProviderProbeTasks.values {
            task.workItem.cancel()
        }
        if let globalFileDragMonitor {
            NSEvent.removeMonitor(globalFileDragMonitor)
        }
        globalFileDragPollTimer?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Public API shared with GaiWorkspaceManager

    func start() {
        guard !started else { return }
        started = true

        let loadResult = store.load()
        if loadResult == .failed {
            Ghostty.logger.error("could not load persisted agents")
        }

        runtimes = store.companions.map(GaiCompanionRuntime.init)
        if companionHubPlacement == nil {
            let seed = runtimes.first?.record
            companionHubScalePercent = seed?.scalePercent ?? .standard
            let placement = GaiCompanionHubPlacement(
                normalizedPosition: seed?.normalizedPosition ?? .center,
                displayID: seed?.displayID,
                scalePercent: companionHubScalePercent)
            companionHubPlacement = placement
            if !placement.persist(to: userDefaults) {
                Ghostty.logger.error("could not persist companion hub placement")
            }
        } else if companionHubPlacement?.scalePercent == nil {
            companionHubScalePercent = runtimes.first?.record.scalePercent ?? .standard
            persistCompanionHubScale()
        }
        companionHubState.scalePercent = companionHubScalePercent
        reconcileCompanionStackCoordinates()
        ensureCompanionHubPanel()
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
        settleCompanionStackVisibility()
        installGlobalFileDropFallback()

        updateSurfacePerformanceState()
    }

    func reveal() {
        start()
        applyVisibilityPolicy(.revealLibrary)
    }

    /// Shows or hides only the desktop agent layer. Runtime presentation and
    /// every Ghostty surface remain untouched, so a second toggle restores the
    /// exact compact/maximized state without restarting a PTY.
    func toggleAgentVisibility() {
        setAgentWindowsVisible(!agentWindowsAreVisible)
    }

    private func setAgentWindowsVisible(_ visible: Bool) {
        guard agentWindowsAreVisible != visible else { return }
        cancelCompanionHubDragMotion()
        stopOrganicCompanionSwapMotion(preservingFrames: false)

        // Publish the gate before ordering windows out. The resulting
        // resign-key callback must not interpret this intentional hide as an
        // outside click and collapse the preserved terminal presentation.
        agentWindowsAreVisible = visible
        if !visible {
            focusGeneration &+= 1
        }
        for controller in panelControllers.values {
            controller.setAgentWindowsVisible(
                visible,
                companionIsVisible: visible && companionStackIsExpanded)
        }
        companionHubController?.setVisible(visible)
        if visible {
            settleCompanionStackVisibility()
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
        let stackCoordinate = GaiCompanionStackLayout.firstAvailableConnectedCoordinate(
            occupied: Set(runtimes.compactMap(\.record.stackCoordinate)).union([.origin]))
        let record = store.create(
            colorway: colorway,
            directoryPath: directory,
            launchCommand: baseConfig?.command,
            normalizedPosition: suggestedPosition(for: runtimes.count),
            displayID: displayID(for: screen),
            scalePercent: companionScalePercent,
            completionSoundEnabled: companionCompletionSoundEnabled,
            stackCoordinate: stackCoordinate)
        let runtime = GaiCompanionRuntime(record: record)
        runtimes.append(runtime)
        _ = previewCompanionHubScale(companionScalePercent)
        persistCompanionHubScale()
        if record.completionSoundEnabled {
            GaiCompanionCompletionSoundPlayer.shared.preload()
        }
        ensurePanel(for: runtime)
        if !companionStackIsExpanded {
            expandCompanionStack()
        } else if companionStackIsExpanded {
            reflowExpandedCompanionStack(animated: true)
        }

        guard let surface = ensureSurface(for: runtime, baseConfig: baseConfig) else {
            closeCompanion(id: runtime.id)
            return nil
        }
        selectCompanion(id: runtime.id)
        setPresentation(.compact, for: runtime, animated: true, focus: true)
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
    /// reads terminal contents or process state and therefore remains safe to
    /// refresh from SwiftUI. Exact process reconciliation belongs exclusively
    /// to explicit interaction boundaries such as `freshManagedAgentSnapshot`
    /// and `submitPrompt`.
    func managedAgentSnapshots() -> [GaiManagedAgentSnapshot] {
        runtimes.map(managedAgentSnapshot)
    }

    /// Synchronously revalidates one hard-gated interaction against foreground
    /// argv. Unlike the broad UI projection, this narrow API reconciles both
    /// directions so a cached CLI can never authorize PTT after returning to a
    /// shell, and a just-launched CLI needs no hook before it can be addressed.
    func freshManagedAgentSnapshot(id: UUID) -> GaiManagedAgentSnapshot? {
        guard let runtime = runtime(id: id) else { return nil }
        let liveProviderChanged: Bool
        switch foregroundProviderObservation(for: runtime) {
        case .provider(let provider):
            liveProviderChanged = runtime.observeLiveProvider(provider)
        case .shell:
            liveProviderChanged = runtime.clearLiveProvider()
        case .unavailable:
            liveProviderChanged = false
        }
        if liveProviderChanged {
            publishCompanionStateChange()
        }
        return managedAgentSnapshot(for: runtime)
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

        // Revalidate at the write boundary as well as in Teddy's PTT router.
        // This protects text tools and every future caller from submitting to
        // a plain shell after the CLI has exited. An unavailable proc lookup
        // may use only previously proven live-process identity.
        let providerDecision = GaiCompanionPromptProviderGate.decision(
            observation: foregroundProviderObservation(for: runtime),
            liveProvider: runtime.liveProvider)
        let validatedProvider: GaiCompanionProvider
        switch providerDecision {
        case .observe(let provider):
            validatedProvider = provider
            if runtime.observeLiveProvider(provider) {
                publishCompanionStateChange()
            }
        case .preserve(let provider):
            validatedProvider = provider
        case .rejectAndClear:
            if runtime.clearLiveProvider() {
                publishCompanionStateChange()
            }
            return .failed(.unavailableTerminal)
        case .reject:
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
        recordSubmittedInput(
            for: runtime,
            submissionIsGuaranteed: true,
            validatedProvider: validatedProvider)
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
        guard selectedCompanionID != id else { return }
        selectedCompanionID = id
        NotificationCenter.default.post(
            name: .gaiCompanionDesktopSelectionDidChange,
            object: self,
            userInfo: [GaiCompanionControl.companionIDUserInfoKey: id])
    }

    private func explicitlySelectCompanion(id: UUID) {
        guard let runtime = runtime(id: id) else { return }
        guard explicitlySelectedCompanionID != id else {
            panelControllers[id]?.setDesktopSelected(true)
            return
        }
        if let previousID = explicitlySelectedCompanionID {
            self.runtime(id: previousID)?.isDesktopSelected = false
            panelControllers[previousID]?.setDesktopSelected(false)
        }
        explicitlySelectedCompanionID = id
        runtime.isDesktopSelected = true
        panelControllers[id]?.setDesktopSelected(true)
    }

    /// Hover is an ephemeral input route: Right Option and the keyboard follow
    /// the doudou under the pointer, while the visible waveform remains on the
    /// last explicitly clicked doudou.
    private func beginTransientHoverInputTarget(id: UUID) {
        if transientHoverInputTargetID == nil,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            hoverFocusReturnApplication = frontmost
        }
        transientHoverInputTargetID = id
        selectCompanion(id: id)
    }

    private func endTransientHoverInputTarget(
        id: UUID,
        restorePreviousApplication: Bool,
        restoreExplicitInputTarget: Bool = true
    ) {
        guard transientHoverInputTargetID == id else { return }
        transientHoverInputTargetID = nil
        if restoreExplicitInputTarget,
           let explicitID = explicitlySelectedCompanionID,
           explicitID != selectedCompanionID {
            selectCompanion(id: explicitID)
        }
        let application = hoverFocusReturnApplication
        hoverFocusReturnApplication = nil
        guard restorePreviousApplication,
              NSApp.isActive,
              let application,
              !application.isTerminated else { return }
        DispatchQueue.main.async {
            application.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func terminalPeekDidBecomeInteractive(id: UUID) {
        endTransientHoverInputTarget(
            id: id,
            restorePreviousApplication: false,
            restoreExplicitInputTarget: false)
    }

    /// Real agents are purely conversational. Stack expansion belongs to the
    /// dedicated hub, which deliberately has no PTY and no selected-agent role.
    func companionWasClicked(id: UUID) {
        guard runtime(id: id) != nil else { return }
        explicitlySelectCompanion(id: id)
        selectCompanion(id: id)
        pinCompactTerminalForCompanionClick(id: id)
    }

    private func pinCompactTerminalForCompanionClick(id: UUID) {
        guard let runtime = runtime(id: id),
              terminalTransientCounts[id, default: 0] == 0 else { return }
        if runtime.activity.phase == .exited {
            restartExitedTerminal(runtime, presentation: .compact)
        } else if runtime.presentation != .compact
                    || panelControllers[id]?.terminalPanel.isVisible != true {
            setPresentation(
                .compact,
                for: runtime,
                animated: true,
                focus: true,
                usesSharedHoverBay: true)
        }
        guard runtime.presentation == .compact,
              let controller = panelControllers[id],
              controller.terminalPanel.isVisible else { return }
        controller.pinCompactTerminalUntilOutsideClick()
        if let surface = runtime.surfaceView {
            requestTerminalFocus(for: runtime, surface: surface)
        }
    }

    func dismissPinnedTerminalFromOutsideClick(
        id: UUID,
        activating application: NSRunningApplication?
    ) {
        guard let runtime = runtime(id: id),
              runtime.presentation == .compact else { return }
        setPresentation(.collapsed, for: runtime, animated: true, focus: false)
        if let explicitID = explicitlySelectedCompanionID,
           explicitID != selectedCompanionID {
            selectCompanion(id: explicitID)
        }
        guard let application, !application.isTerminated else { return }
        DispatchQueue.main.async {
            application.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func companionHubWasClicked() {
        guard !runtimes.isEmpty,
              companionHubDragMotion == nil else { return }
        if companionStackIsExpanded {
            collapseCompanionStack()
        } else {
            expandCompanionStack()
        }
    }

    func requestOpenCompanionCreator() {
        onOpenCompanionCreator?()
    }

    func requestReplayLatestVoice(id: UUID) {
        guard runtime(id: id) != nil else { return }
        selectCompanion(id: id)
        NotificationCenter.default.post(
            name: .gaiCompanionReplayVoiceRequested,
            object: self,
            userInfo: [GaiCompanionControl.companionIDUserInfoKey: id])
    }

    /// Opens the real compact terminal and immediately routes both keyboard
    /// and global push-to-talk input to the hovered doudou. If the pointer
    /// leaves without an explicit interaction, the previously active app is
    /// restored automatically.
    @discardableResult
    func presentTerminalPeek(id: UUID) -> Bool {
        guard agentWindowsAreVisible,
              companionStackIsExpanded,
              companionStackTransition == nil,
              terminalTransientCounts[id, default: 0] == 0,
              let runtime = runtime(id: id),
              runtime.presentation == .collapsed else { return false }
        let hasInteractiveTerminal = runtimes.contains { other in
            guard other.id != id,
                  other.presentation != .collapsed,
                  let controller = panelControllers[other.id],
                  controller.terminalPanel.isVisible else { return false }
            return !controller.isHoverPeekPresented
        }
        guard !hasInteractiveTerminal else { return false }
        ensurePanel(for: runtime)
        guard let controller = panelControllers[id] else { return false }

        beginTransientHoverInputTarget(id: id)
        setPresentation(
            .compact,
            for: runtime,
            animated: true,
            focus: true,
            usesSharedHoverBay: true)
        let presented = runtime.presentation == .compact
            && controller.isHoverPeekPresented
            && controller.terminalPanel.isVisible
        if !presented {
            endTransientHoverInputTarget(
                id: id,
                restorePreviousApplication: true)
        }
        return presented
    }

    /// Called only by the bounded pointer-presence session owned by a panel
    /// controller. Genuine terminal interaction always wins by ending that
    /// session before this method can run.
    func dismissTerminalPeek(id: UUID) {
        guard let runtime = runtime(id: id),
              runtime.presentation == .compact,
              let controller = panelControllers[id],
              controller.isHoverPeekPresented else { return }
        setPresentation(.collapsed, for: runtime, animated: true, focus: false)
        endTransientHoverInputTarget(
            id: id,
            restorePreviousApplication: true)
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

    func companionHubDragDidBegin() {
        guard companionStackIsExpanded,
              companionStackMode == .organicGrid,
              companionStackTransition == nil else { return }
        beginCompanionHubDragMotionIfNeeded()
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
                    && companionStackIsExpanded
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
        let wasExplicitlySelected = explicitlySelectedCompanionID == id
        focusGeneration &+= 1
        detachInlineTerminalIfNeeded(id: id)
        terminalTransientCounts.removeValue(forKey: id)
        terminalFocusLossProtectionUntil.removeValue(forKey: id)
        fileDropFocusGeneration.removeValue(forKey: id)
        activeCloseConfirmationIDs.remove(id)
        responseCaptureTasks.removeValue(forKey: id)?.cancel()
        responseSettlementWatchdogs.removeValue(forKey: id)?.cancel()
        responseActivationProbes.removeValue(forKey: id)?.cancel()
        lastResponseStore.removeAgent(id)
        cancelForegroundProviderProbe(for: id)
        let runtime = runtimes.remove(at: index)
        if wasExplicitlySelected {
            explicitlySelectedCompanionID = nil
            runtime.isDesktopSelected = false
        }
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
        reconcileCompanionStackCoordinates()
        if runtimes.isEmpty {
            companionStackIsExpanded = false
            activeCompanionStackLayout = nil
            companionStackTransition = nil
            hiddenCompanionStackTransitionIDs.removeAll()
            companionStackDisplayLink.stop()
            settleCompanionStackVisibility()
        } else if companionStackIsExpanded {
            reflowExpandedCompanionStack(animated: true)
        } else {
            settleCompanionStackVisibility()
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
            + "and removes the agent from Teddy CLI. To only hide the "
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
        var didChange = false
        for runtime in runtimes where ids.contains(runtime.id) {
            didChange = previewScale(runtime, scalePercent: scalePercent)
                || didChange
        }
        didChange = previewCompanionHubScale(scalePercent) || didChange
        if didChange, companionStackIsExpanded {
            reflowExpandedCompanionStack(animated: true)
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
        persistCompanionHubScale()
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
        let fallbackBundleIdentifier = "com.sipiyou.teddycli.debug"
        #else
        let fallbackBundleIdentifier = "com.sipiyou.teddycli"
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
        if config.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            // A configured CLI starts as part of surface creation and therefore
            // produces no manual-Enter notification. Reconcile it with the same
            // finite, event-driven probe used for a user-launched CLI so the UI
            // becomes ready without introducing an idle poll.
            scheduleForegroundProviderLaunchProbe(
                for: runtime,
                surface: surface)
        }
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
        cancelForegroundProviderProbe(for: runtime.id)
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

    // MARK: Companion stack

    private func reconcileCompanionStackCoordinates() {
        guard !runtimes.isEmpty else { return }
        let defaults = Array(
            GaiCompanionStackLayout.defaultCoordinates(count: runtimes.count + 1)
                .dropFirst())
        let validCoordinates = Set(defaults)
        var claimedCoordinates: Set<GaiCompanionStackCoordinate> = []
        var displacedRuntimes: [GaiCompanionRuntime] = []

        // Preserve every existing interchange that already occupies the
        // compact footprint. Only missing, duplicate, or outlying cells move,
        // which repairs old branched constellations without shuffling the
        // user's whole arrangement.
        for runtime in runtimes {
            guard let coordinate = runtime.record.stackCoordinate,
                  validCoordinates.contains(coordinate),
                  claimedCoordinates.insert(coordinate).inserted else {
                displacedRuntimes.append(runtime)
                continue
            }
        }

        let availableCoordinates = defaults.filter {
            !claimedCoordinates.contains($0)
        }
        let assignments = Dictionary(uniqueKeysWithValues: zip(
            displacedRuntimes.map(\.id),
            availableCoordinates))
        guard !assignments.isEmpty else { return }

        let records = store.update(ids: Set(assignments.keys)) { record in
            if let coordinate = assignments[record.id] {
                record.stackCoordinate = coordinate
            }
        }
        for record in records {
            runtime(id: record.id)?.replaceRecord(record)
        }
    }

    private var companionStackElementIDs: [UUID] {
        [companionHubID] + runtimes.map(\.id)
    }

    private func companionStackCoordinate(for id: UUID) -> GaiCompanionStackCoordinate {
        id == companionHubID
            ? .origin
            : runtime(id: id)?.record.stackCoordinate ?? .origin
    }

    private func expandCompanionStack() {
        guard !runtimes.isEmpty,
              let hubController = companionHubController else { return }
        cancelCompanionHubDragMotion()
        collapseEveryCompanionTerminalForStackMotion()

        let screen = hubController.companionPanel.screen ?? targetScreenForCompanionHub()
        let anchorFrame = hubController.companionPanel.frame
        let layout = resolvedCompanionStackLayout(
            anchorFrame: anchorFrame,
            screen: screen)
        let fromFrames = companionStackTransition == nil
            ? collapsedCompanionFrames(around: anchorFrame)
            : currentCompanionFrames()
        beginCompanionStackTransition(
            expanding: true,
            isReflow: false,
            fromFrames: fromFrames,
            layout: layout,
            duration: GaiCompanionStackMotion.expansionDuration)
    }

    private func collapseCompanionStack() {
        guard companionStackIsExpanded,
              let hubController = companionHubController else { return }
        cancelCompanionHubDragMotion()
        collapseEveryCompanionTerminalForStackMotion()
        let screen = hubController.companionPanel.screen ?? targetScreenForCompanionHub()
        let anchorFrame = hubController.companionPanel.frame
        persistCompanionHubFrame(anchorFrame, screen: screen)
        let currentLayout = activeCompanionStackLayout
            ?? resolvedCompanionStackLayout(
                anchorFrame: anchorFrame,
                screen: screen)
        let collapsedFrames = collapsedCompanionFrames(around: anchorFrame)
        let collapsedLayout = GaiCompanionStackResolvedLayout(
            orientation: currentLayout.orientation,
            anchorCenter: CGPoint(x: anchorFrame.midX, y: anchorFrame.midY),
            cellSize: currentLayout.cellSize,
            frames: collapsedFrames)
        beginCompanionStackTransition(
            expanding: false,
            isReflow: false,
            fromFrames: currentCompanionFrames(),
            layout: collapsedLayout,
            duration: GaiCompanionStackMotion.collapseDuration)
    }

    private func reflowExpandedCompanionStack(animated: Bool) {
        guard companionStackIsExpanded,
              let hubController = companionHubController else { return }
        let screen = hubController.companionPanel.screen ?? targetScreenForCompanionHub()
        let layout = resolvedCompanionStackLayout(
            anchorFrame: hubController.companionPanel.frame,
            screen: screen,
            preferredOrientation: activeCompanionStackLayout?.orientation)
        guard animated else {
            activeCompanionStackLayout = layout
            settleCompanionStackVisibility()
            return
        }
        beginCompanionStackTransition(
            expanding: true,
            isReflow: true,
            fromFrames: currentCompanionFrames(),
            layout: layout,
            duration: GaiCompanionStackMotion.reflowDuration)
    }

    private func beginCompanionStackTransition(
        expanding: Bool,
        isReflow: Bool,
        fromFrames: [UUID: NSRect],
        layout: GaiCompanionStackResolvedLayout,
        duration: CFTimeInterval
    ) {
        let reversesActiveTransition = companionStackTransition != nil
        companionStackDisplayLink.stop()
        hiddenCompanionStackTransitionIDs.removeAll()
        stopOrganicCompanionSwapMotion(preservingFrames: true)
        let elementIDs = companionStackElementIDs
        let distances = elementIDs.map { id -> Int in
            let coordinate = companionStackCoordinate(for: id)
            return abs(coordinate.column) + abs(coordinate.row)
        }
        let items = elementIDs.enumerated().compactMap { index, id -> GaiCompanionStackTransitionItem? in
            guard let fromFrame = fromFrames[id],
                  let toFrame = layout.frames[id] else { return nil }
            let distance = distances[index]
            // Keep the opening delay even when closing. The frame loop uses it
            // as trailing time on collapse, producing the exact reversed wave:
            // the mascot that appeared last is the first one fully home.
            let waveDistance = distance
            let delay: CFTimeInterval = isReflow
                ? 0
                : min(
                    Double(waveDistance) * 0.007 + Double(index) * 0.0015,
                    GaiCompanionStackMotion.maximumStagger)
            let isAnchor = id == companionHubID
            let fromAlpha: CGFloat = if reversesActiveTransition {
                stackTransitionAlpha(for: id)
            } else if expanding && !isReflow && !isAnchor {
                0
            } else {
                1
            }
            let toAlpha: CGFloat = isAnchor || isReflow || expanding ? 1 : 0
            let collapsedScale = collapsedCompanionScale(for: id)
            let fromScale: CGFloat = if reversesActiveTransition || isReflow {
                stackTransitionScale(for: id)
            } else if isReflow || isAnchor || !expanding {
                1
            } else {
                collapsedScale
            }
            return GaiCompanionStackTransitionItem(
                id: id,
                fromFrame: fromFrame,
                toFrame: toFrame,
                delay: delay,
                bend: 0,
                fromAlpha: fromAlpha,
                toAlpha: toAlpha,
                fromScale: fromScale,
                toScale: isReflow || isAnchor || expanding
                    ? 1
                    : collapsedScale)
        }
        guard !items.isEmpty else { return }

        hideCompanionStackBadges()
        detachCompanionPileWindows()
        companionStackIsExpanded = expanding
        activeCompanionStackLayout = expanding ? layout : nil
        if expanding {
            updateCompanionStackDepths()
        } else {
            companionHubState.companionCount = runtimes.count
            companionHubState.isExpanded = false
        }
        if let hubItem = items.first(where: { $0.id == companionHubID }) {
            companionHubController?.prepareStackTransition(
                maximumScale: max(hubItem.fromScale, hubItem.toScale))
        }
        for item in items where item.id != companionHubID {
            panelControllers[item.id]?.prepareStackTransition(
                maximumScale: max(item.fromScale, item.toScale))
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            companionStackTransition = nil
            hiddenCompanionStackTransitionIDs.removeAll()
            for item in items {
                settleCompanionStackElement(
                    id: item.id,
                    frame: item.toFrame,
                    visible: agentWindowsAreVisible
                        && (expanding || item.id == companionHubID))
            }
            settleCompanionStackVisibility()
            return
        }
        let transitionStart = CACurrentMediaTime()
        companionStackTransition = GaiCompanionStackTransition(
            expanding: expanding,
            isReflow: isReflow,
            anchorID: companionHubID,
            startedAt: transitionStart,
            duration: duration,
            items: items,
            finalLayout: layout)

        let depthOrderedItems = Array(
            items.filter { $0.id != companionHubID }.reversed())
            + items.filter { $0.id == companionHubID }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in depthOrderedItems where agentWindowsAreVisible {
            applyCompanionStackElement(
                id: item.id,
                item.fromFrame,
                alpha: item.fromAlpha,
                scale: item.fromScale,
                orderFront: true)
        }
        CATransaction.commit()
        companionStackDisplayLink.start(
            synchronizedTo: companionHubController?.companionPanel.contentView)
    }

    private func advanceCompanionStackTransition(at timestamp: CFTimeInterval) {
        guard let transition = companionStackTransition else {
            companionStackDisplayLink.stop()
            return
        }
        let elapsed = max(0, timestamp - transition.startedAt)
        var finished = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in transition.items {
            let linear = GaiCompanionStackMotion.localProgress(
                elapsed: elapsed,
                duration: transition.duration,
                stagger: item.delay,
                reversing: !transition.expanding && !transition.isReflow)
            if linear < 1 { finished = false }
            if hiddenCompanionStackTransitionIDs.contains(item.id) {
                continue
            }
            let position: CGFloat = if transition.isReflow {
                GaiCompanionMagneticSwap.settlePosition(at: linear)
            } else if transition.expanding {
                GaiCompanionStackMotion.position(at: linear)
            } else {
                GaiCompanionStackMotion.collapsePosition(at: linear)
            }
            let opacityProgress = if transition.expanding || transition.isReflow {
                GaiCompanionStackMotion.opacity(at: linear)
            } else {
                GaiCompanionStackMotion.collapseOpacity(at: linear)
            }
            let bend: CGFloat = if transition.isReflow {
                0
            } else if transition.expanding {
                item.bend
            } else {
                item.bend * 0.55 * (1 - opacityProgress)
            }
            let frame = companionStackFrame(
                from: item.fromFrame,
                to: item.toFrame,
                position: position,
                linearProgress: linear,
                bend: bend)
            let alpha = item.fromAlpha
                + (item.toAlpha - item.fromAlpha) * opacityProgress
            let scaleProgress = min(max(position, 0), 1.035)
            let scale = item.fromScale
                + (item.toScale - item.fromScale) * scaleProgress
            applyCompanionStackElement(
                id: item.id,
                frame,
                alpha: alpha,
                scale: scale,
                orderFront: false)
            if !transition.expanding,
               item.id != transition.anchorID,
               alpha <= 0.002 {
                suspendCompanionStackElement(id: item.id)
                hiddenCompanionStackTransitionIDs.insert(item.id)
            }
        }
        CATransaction.commit()
        guard finished else { return }

        companionStackDisplayLink.stop()
        companionStackTransition = nil
        hiddenCompanionStackTransitionIDs.removeAll()
        activeCompanionStackLayout = transition.expanding
            ? transition.finalLayout
            : nil
        settleCompanionStackVisibility()
    }

    private func companionStackFrame(
        from: NSRect,
        to: NSRect,
        position: CGFloat,
        linearProgress: CGFloat,
        bend: CGFloat
    ) -> NSRect {
        let start = CGPoint(x: from.midX, y: from.midY)
        let end = CGPoint(x: to.midX, y: to.midY)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = max(hypot(dx, dy), 1)
        let arc = sin(.pi * min(max(linearProgress, 0), 1)) * bend
        let center = CGPoint(
            x: start.x + dx * position - dy / distance * arc,
            y: start.y + dy * position + dx / distance * arc)
        let width = from.width + (to.width - from.width) * position
        let height = from.height + (to.height - from.height) * position
        return NSRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height)
    }

    private func resolvedCompanionStackLayout(
        anchorFrame: NSRect,
        screen: NSScreen,
        preferredOrientation: GaiCompanionStackOrientation? = nil
    ) -> GaiCompanionStackResolvedLayout {
        if companionStackMode == .freeform {
            return freeformCompanionStackLayout(
                anchorFrame: anchorFrame)
        }
        let ids = companionStackElementIDs
        var coordinates = Dictionary(uniqueKeysWithValues: runtimes.map {
            ($0.id, $0.record.stackCoordinate ?? .origin)
        })
        coordinates[companionHubID] = .origin
        var sizes = Dictionary(uniqueKeysWithValues: runtimes.map {
            ($0.id, companionPanelSize(scalePercent: $0.record.scalePercent))
        })
        sizes[companionHubID] = companionPanelSize(
            scalePercent: companionHubScalePercent)
        return GaiCompanionStackLayout.resolve(
            ids: ids,
            coordinates: coordinates,
            sizes: sizes,
            anchorID: companionHubID,
            anchorFrame: anchorFrame,
            workArea: screen.visibleFrame.insetBy(dx: 18, dy: 18),
            preferredOrientation: preferredOrientation)
    }

    private func magneticCompanionStackLayout(
        anchorFrame: NSRect,
        screen: NSScreen,
        currentOrientation: GaiCompanionStackOrientation
    ) -> GaiCompanionStackResolvedLayout {
        let ids = companionStackElementIDs
        var coordinates = Dictionary(uniqueKeysWithValues: runtimes.map {
            ($0.id, $0.record.stackCoordinate ?? .origin)
        })
        coordinates[companionHubID] = .origin
        var sizes = Dictionary(uniqueKeysWithValues: runtimes.map {
            ($0.id, companionPanelSize(scalePercent: $0.record.scalePercent))
        })
        sizes[companionHubID] = companionPanelSize(
            scalePercent: companionHubScalePercent)
        return GaiCompanionStackLayout.resolveMagnetically(
            ids: ids,
            coordinates: coordinates,
            sizes: sizes,
            anchorID: companionHubID,
            anchorFrame: anchorFrame,
            workArea: screen.visibleFrame.insetBy(dx: 18, dy: 18),
            currentOrientation: currentOrientation)
    }

    private func freeformCompanionStackLayout(
        anchorFrame: NSRect
    ) -> GaiCompanionStackResolvedLayout {
        var frames = Dictionary(uniqueKeysWithValues: runtimes.map { runtime in
            let screen = targetScreen(for: runtime)
            return (runtime.id, persistedFreeformCompanionFrame(
                for: runtime,
                screen: screen))
        })
        frames[companionHubID] = anchorFrame
        return GaiCompanionStackResolvedLayout(
            orientation: .identity,
            anchorCenter: CGPoint(x: anchorFrame.midX, y: anchorFrame.midY),
            cellSize: anchorFrame.size,
            frames: frames)
    }

    private func persistedFreeformCompanionFrame(
        for runtime: GaiCompanionRuntime,
        screen: NSScreen
    ) -> NSRect {
        let visible = screen.visibleFrame
        let size = companionPanelSize(scalePercent: runtime.record.scalePercent)
        let center = CGPoint(
            x: visible.minX + visible.width * CGFloat(runtime.record.normalizedPosition.x),
            y: visible.minY + visible.height * CGFloat(runtime.record.normalizedPosition.y))
        return NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height)
    }

    private func collapsedCompanionFrames(around anchorFrame: NSRect) -> [UUID: NSRect] {
        var frames = Dictionary(uniqueKeysWithValues: runtimes.map { runtime in
            // Keep the real agent window at its final size throughout motion.
            // Only its centre moves; the compositor transform makes the hidden
            // starting image match the hub. Interpolating the NSWindow size
            // here would force a full SwiftUI layout on every display refresh.
            let size = companionPanelSize(scalePercent: runtime.record.scalePercent)
            return (runtime.id, GaiCompanionStackMotion.collapsedFrame(
                contentSize: size,
                around: anchorFrame))
        })
        frames[companionHubID] = anchorFrame
        return frames
    }

    private func currentCompanionFrames() -> [UUID: NSRect] {
        var frames = Dictionary(uniqueKeysWithValues: runtimes.compactMap { runtime in
            panelControllers[runtime.id].map { (runtime.id, $0.companionPanel.frame) }
        })
        if let hubController = companionHubController {
            frames[companionHubID] = hubController.companionPanel.frame
        }
        return frames
    }

    private func collapseEveryCompanionTerminalForStackMotion() {
        for runtime in runtimes where runtime.presentation != .collapsed {
            setPresentation(.collapsed, for: runtime, animated: false, focus: false)
        }
    }

    private func settleCompanionStackVisibility() {
        updateCompanionStackDepths()
        guard agentWindowsAreVisible,
              let hubController = companionHubController else { return }
        if companionStackIsExpanded {
            detachCompanionPileWindows()
            if activeCompanionStackLayout == nil {
                let screen = hubController.companionPanel.screen
                    ?? targetScreenForCompanionHub()
                activeCompanionStackLayout = resolvedCompanionStackLayout(
                    anchorFrame: hubController.companionPanel.frame,
                    screen: screen)
            }
            guard let layout = activeCompanionStackLayout else { return }
            for runtime in runtimes {
                guard let frame = layout.frames[runtime.id] else { continue }
                panelControllers[runtime.id]?.settleStackTransition(
                    frame: frame,
                    visible: true)
            }
            if let frame = layout.frames[companionHubID] {
                hubController.settleStackTransition(frame: frame, visible: true)
            }
        } else {
            let hubFrame = hubController.companionPanel.frame
            let collapsedFrames = collapsedCompanionFrames(around: hubFrame)
            for runtime in runtimes.reversed() {
                guard let frame = collapsedFrames[runtime.id] else { continue }
                panelControllers[runtime.id]?.settleStackTransition(
                    frame: frame,
                    visible: false)
            }
            hubController.settleStackTransition(frame: hubFrame, visible: true)
            // A collapsed stack is a single visual object. Keep every agent
            // fully ordered out instead of attaching hidden child windows:
            // AppKit may otherwise reorder a child with its visible parent,
            // leaking animation pixels and mouse tracking around the hub.
            detachCompanionPileWindows()
        }
        companionHubController?.finishStackTransition()
        for runtime in runtimes {
            panelControllers[runtime.id]?.finishStackTransition(
                interactive: companionStackIsExpanded,
                selected: explicitlySelectedCompanionID == runtime.id,
                restingScale: 1)
        }
        if companionStackIsExpanded {
            prepareCompanionStackBadgeReveal()
        } else {
            hideCompanionStackBadges()
        }
    }

    private func collapsedCompanionScale(for id: UUID) -> CGFloat {
        guard id != companionHubID,
              let runtime = runtime(id: id) else { return 1 }
        let companionScale = CGFloat(
            GaiCompanionVisualMetrics.scaleFactor(for: runtime.record.scalePercent))
        let hubScale = CGFloat(
            GaiCompanionVisualMetrics.scaleFactor(for: companionHubScalePercent))
        return hubScale / max(companionScale, 0.01)
    }

    private func detachCompanionPileWindows() {
        guard let hubWindow = companionHubController?.companionPanel else { return }
        for controller in panelControllers.values
            where controller.companionPanel.parent === hubWindow {
            hubWindow.removeChildWindow(controller.companionPanel)
        }
    }

    private func attachCompanionWindows(to hubWindow: NSWindow) {
        detachCompanionPileWindows()
        for runtime in runtimes.reversed() {
            guard let window = panelControllers[runtime.id]?.companionPanel else { continue }
            hubWindow.addChildWindow(window, ordered: .below)
        }
    }

    private func updateCompanionStackDepths() {
        for runtime in runtimes {
            // Agent panels are completely ordered out behind the white hub.
            // Keep their expanded hierarchy stable while hidden so opening the
            // pile never reconstructs or resizes SwiftUI content mid-flight.
            runtime.collapsedStackDepth = 0
        }
        companionHubState.companionCount = runtimes.count
        companionHubState.isExpanded = companionStackIsExpanded
    }

    private func hideCompanionStackBadges() {
        for runtime in runtimes where runtime.stackBadgePhase != .hidden {
            runtime.stackBadgePhase = .hidden
        }
    }

    private func prepareCompanionStackBadgeReveal() {
        guard companionStackIsExpanded,
              companionStackTransition == nil else { return }
        for runtime in runtimes {
            runtime.stackBadgePhase = .preparing
        }
        for controller in panelControllers.values {
            controller.prepareStackBadgeReveal()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.companionStackIsExpanded,
                  self.companionStackTransition == nil else { return }
            for runtime in self.runtimes {
                runtime.stackBadgePhase = .visible
            }
        }
    }

    private func stackTransitionAlpha(for id: UUID) -> CGFloat {
        id == companionHubID
            ? companionHubController?.transitionAlpha ?? 1
            : panelControllers[id]?.companionTransitionAlpha ?? 1
    }

    private func stackTransitionScale(for id: UUID) -> CGFloat {
        id == companionHubID
            ? companionHubController?.transitionScale ?? 1
            : panelControllers[id]?.companionTransitionScale ?? 1
    }

    private func applyCompanionStackElement(
        id: UUID,
        _ frame: NSRect,
        alpha: CGFloat,
        scale: CGFloat,
        orderFront: Bool
    ) {
        if id == companionHubID {
            companionHubController?.applyStackTransitionFrame(
                frame,
                alpha: alpha,
                scale: scale,
                orderFront: orderFront)
        } else {
            panelControllers[id]?.applyStackTransitionFrame(
                frame,
                alpha: alpha,
                scale: scale,
                orderFront: orderFront)
        }
    }

    private func settleCompanionStackElement(
        id: UUID,
        frame: NSRect,
        visible: Bool
    ) {
        if id == companionHubID {
            companionHubController?.settleStackTransition(frame: frame, visible: visible)
        } else {
            panelControllers[id]?.settleStackTransition(frame: frame, visible: visible)
        }
    }

    private func suspendCompanionStackElement(id: UUID) {
        guard id != companionHubID else { return }
        panelControllers[id]?.suspendStackTransitionRendering()
    }

    private func ensureCompanionHubPanel() {
        guard companionHubController == nil else { return }
        let controller = GaiCompanionHubPanelController(
            hubID: companionHubID,
            state: companionHubState,
            manager: self)
        companionHubController = controller
        let screen = targetScreenForCompanionHub()
        controller.show(
            frame: companionHubFrame(screen: screen),
            visible: agentWindowsAreVisible)
        updateCompanionStackDepths()
    }

    private func targetScreenForCompanionHub() -> NSScreen {
        if let displayID = companionHubPlacement?.displayID,
           let screen = NSScreen.screens.first(where: {
               self.displayID(for: $0) == displayID
           }) {
            return screen
        }
        return screenUnderMouse()
    }

    private func companionHubFrame(screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let size = companionPanelSize(scalePercent: companionHubScalePercent)
        let position = companionHubPlacement?.normalizedPosition ?? .center
        let center = CGPoint(
            x: visible.minX + visible.width * CGFloat(position.x),
            y: visible.minY + visible.height * CGFloat(position.y))
        return NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height)
    }

    private func persistCompanionHubFrame(_ frame: NSRect, screen: NSScreen) {
        let visible = screen.visibleFrame
        let placement = GaiCompanionHubPlacement(
            normalizedPosition: GaiCompanionNormalizedPosition(
                x: Double((frame.midX - visible.minX) / max(visible.width, 1)),
                y: Double((frame.midY - visible.minY) / max(visible.height, 1))),
            displayID: displayID(for: screen),
            scalePercent: companionHubScalePercent)
        companionHubPlacement = placement
        if !placement.persist(to: userDefaults) {
            Ghostty.logger.error("could not persist companion hub placement")
        }
    }

    private func persistCompanionAnchorFrame(
        _ frame: NSRect,
        runtime: GaiCompanionRuntime,
        screen: NSScreen
    ) {
        let visible = screen.visibleFrame
        let x = Double((frame.midX - visible.minX) / max(visible.width, 1))
        let y = Double((frame.midY - visible.minY) / max(visible.height, 1))
        guard let record = store.update(id: runtime.id, {
            $0.normalizedPosition = GaiCompanionNormalizedPosition(x: x, y: y)
            $0.displayID = displayID(for: screen)
        }) else { return }
        runtime.replaceRecord(record)
    }

    // MARK: Presentation and windows

    private func ensurePanel(for runtime: GaiCompanionRuntime) {
        guard panelControllers[runtime.id] == nil else { return }
        let controller = GaiCompanionPanelController(
            runtime: runtime,
            manager: self)
        panelControllers[runtime.id] = controller
        controller.setDesktopSelected(explicitlySelectedCompanionID == runtime.id)
    }

    private func setPresentation(
        _ presentation: GaiCompanionPresentation,
        for runtime: GaiCompanionRuntime,
        animated: Bool,
        focus: Bool,
        usesSharedHoverBay: Bool = false
    ) {
        ensurePanel(for: runtime)
        if presentation == .collapsed {
            endTransientHoverInputTarget(
                id: runtime.id,
                restorePreviousApplication: true)
        }
        if presentation != .collapsed,
           focus,
           !runtimes.isEmpty,
           !companionStackIsExpanded {
            expandCompanionStack()
        }
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
        let compactGeometry = usesSharedHoverBay
            ? sharedHoverTerminalGeometry(
                for: runtime,
                screen: screen,
                companionFrame: companionFrame)
            : nil
        let geometry = panelGeometry(
            for: runtime,
            presentation: presentation,
            screen: screen,
            companionFrame: companionFrame,
            compactGeometry: compactGeometry)
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
            agentWindowsAreVisible: agentWindowsAreVisible,
            companionIsVisible: agentWindowsAreVisible && companionStackIsExpanded)
        let shouldFocusTerminal = shouldFocus
        updateSurfacePerformanceState(
            focused: shouldFocusTerminal ? runtime.surfaceView : nil)
        if shouldFocusTerminal, let surface = runtime.surfaceView {
            requestTerminalFocus(for: runtime, surface: surface)
        }
        updateDockBadge()
    }

    func panelDidBecomeKey(for id: UUID) {
        guard let runtime = runtime(id: id),
              runtime.presentation != .collapsed,
              let controller = panelControllers[id],
              controller.terminalPanel.isKeyWindow else { return }
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

        controller.focusTerminalOnActiveSpace(makeMain: true)

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
        if companionStackIsExpanded {
            if companionStackMode == .freeform {
                updateFreeformCompanionFrame(id: id, frame: frame)
                return
            }
            previewOrganicCompanionSwapIfNeeded(
                movingID: id,
                frame: frame)
            return
        }
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
        if companionStackIsExpanded {
            if companionStackMode == .freeform {
                persistFreeformCompanionFrame(
                    runtime: runtime,
                    frame: frame,
                    screen: screen)
                return
            }
            settleExpandedCompanionDrag(
                runtime: runtime,
                frame: frame,
                screen: screen)
            return
        }
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

    func companionHubIsMoving(frame: NSRect, screen: NSScreen?) {
        guard let screen else { return }
        guard companionStackIsExpanded else { return }
        if companionStackMode == .freeform {
            updateFreeformCompanionFrame(id: companionHubID, frame: frame)
        } else {
            guard companionHubDragMotion != nil else { return }
            updateCompanionHubDragTarget(frame: frame, screen: screen)
        }
    }

    func companionHubDidMove(frame: NSRect, screen: NSScreen?) {
        guard let screen else { return }
        persistCompanionHubFrame(frame, screen: screen)
        guard companionStackIsExpanded else { return }
        if companionStackMode == .freeform {
            updateFreeformCompanionFrame(id: companionHubID, frame: frame)
            return
        }
        finishCompanionHubDragMotion(frame: frame, screen: screen)
    }

    private func beginCompanionHubDragMotionIfNeeded() {
        guard companionHubDragMotion == nil,
              let hubWindow = companionHubController?.companionPanel else { return }
        let layout = activeCompanionStackLayout
            ?? resolvedCompanionStackLayout(
                anchorFrame: hubWindow.frame,
                screen: hubWindow.screen ?? targetScreenForCompanionHub())
        var items: [UUID: GaiCompanionHubDragItem] = [:]
        for runtime in runtimes {
            guard let frame = panelControllers[runtime.id]?.companionPanel.frame,
                  let targetFrame = layout.frames[runtime.id] else { continue }
            items[runtime.id] = GaiCompanionHubDragItem(
                offset: CGPoint(
                    x: frame.minX - hubWindow.frame.minX,
                    y: frame.minY - hubWindow.frame.minY),
                velocity: .zero,
                targetOffset: CGPoint(
                    x: targetFrame.minX - (layout.frames[companionHubID]?.minX
                        ?? hubWindow.frame.minX),
                    y: targetFrame.minY - (layout.frames[companionHubID]?.minY
                        ?? hubWindow.frame.minY)),
                size: frame.size)
        }
        companionHubDragMotion = GaiCompanionHubDragMotion(
            orientation: layout.orientation,
            cellSize: layout.cellSize,
            items: items,
            lastTimestamp: CACurrentMediaTime(),
            pointerIsDown: true)
        attachCompanionWindows(to: hubWindow)
        companionHubController?.prepareStackTransition()
        for controller in panelControllers.values {
            controller.prepareStackTransition()
        }
    }

    private func updateCompanionHubDragTarget(
        frame: NSRect,
        screen: NSScreen
    ) {
        guard var motion = companionHubDragMotion else { return }
        let target = magneticCompanionStackLayout(
            anchorFrame: frame,
            screen: screen,
            currentOrientation: motion.orientation)
        let targetAnchor = target.frames[companionHubID] ?? frame
        var needsFrames = false
        for runtime in runtimes {
            guard var item = motion.items[runtime.id],
                  let targetFrame = target.frames[runtime.id] else { continue }
            let targetOffset = CGPoint(
                x: targetFrame.minX - targetAnchor.minX,
                y: targetFrame.minY - targetAnchor.minY)
            if hypot(
                targetOffset.x - item.targetOffset.x,
                targetOffset.y - item.targetOffset.y) > 0.01 {
                item.targetOffset = targetOffset
                motion.items[runtime.id] = item
            }
            if hypot(
                targetOffset.x - item.offset.x,
                targetOffset.y - item.offset.y) > 0.05 {
                needsFrames = true
            }
        }
        motion.orientation = target.orientation
        motion.cellSize = target.cellSize
        companionHubDragMotion = motion
        if needsFrames {
            companionHubDragDisplayLink.start(
                synchronizedTo: companionHubController?.companionPanel.contentView)
        } else {
            updateActiveCompanionLayoutFromHubDrag(
                hubFrame: frame,
                motion: motion)
        }
    }

    private func finishCompanionHubDragMotion(
        frame: NSRect,
        screen: NSScreen
    ) {
        guard var motion = companionHubDragMotion else {
            reflowExpandedCompanionStack(animated: false)
            return
        }
        motion.pointerIsDown = false
        companionHubDragMotion = motion
        updateCompanionHubDragTarget(frame: frame, screen: screen)
        companionHubDragDisplayLink.start(
            synchronizedTo: companionHubController?.companionPanel.contentView)
    }

    private func advanceCompanionHubDragMotion(at timestamp: CFTimeInterval) {
        guard var motion = companionHubDragMotion,
              let hubFrame = companionHubController?.companionPanel.frame else {
            companionHubDragDisplayLink.stop()
            return
        }
        let deltaTime = min(max(timestamp - motion.lastTimestamp, 1.0 / 240.0), 1.0 / 15.0)
        motion.lastTimestamp = timestamp
        let angularFrequency = CGFloat(18)
        let decay = exp(-angularFrequency * CGFloat(deltaTime))
        var settled = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for runtime in runtimes {
            guard var item = motion.items[runtime.id] else { continue }
            let x = criticallyDampedStep(
                value: item.offset.x,
                velocity: item.velocity.dx,
                target: item.targetOffset.x,
                deltaTime: CGFloat(deltaTime),
                angularFrequency: angularFrequency,
                decay: decay)
            let y = criticallyDampedStep(
                value: item.offset.y,
                velocity: item.velocity.dy,
                target: item.targetOffset.y,
                deltaTime: CGFloat(deltaTime),
                angularFrequency: angularFrequency,
                decay: decay)
            item.offset = CGPoint(x: x.value, y: y.value)
            item.velocity = CGVector(dx: x.velocity, dy: y.velocity)
            motion.items[runtime.id] = item
            if hypot(
                item.offset.x - item.targetOffset.x,
                item.offset.y - item.targetOffset.y) > 0.08
                || hypot(item.velocity.dx, item.velocity.dy) > 0.8 {
                settled = false
            }
            panelControllers[runtime.id]?.applyHubDragFrame(NSRect(
                x: hubFrame.minX + item.offset.x,
                y: hubFrame.minY + item.offset.y,
                width: item.size.width,
                height: item.size.height))
        }
        CATransaction.commit()
        companionHubDragMotion = motion
        updateActiveCompanionLayoutFromHubDrag(
            hubFrame: hubFrame,
            motion: motion)

        guard settled else { return }
        companionHubDragDisplayLink.stop()
        guard !motion.pointerIsDown else { return }
        settleCompanionHubDragMotion(hubFrame: hubFrame, motion: motion)
    }

    private func settleCompanionHubDragMotion(
        hubFrame: NSRect,
        motion: GaiCompanionHubDragMotion
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for runtime in runtimes {
            guard let item = motion.items[runtime.id] else { continue }
            panelControllers[runtime.id]?.applyHubDragFrame(NSRect(
                x: hubFrame.minX + item.targetOffset.x,
                y: hubFrame.minY + item.targetOffset.y,
                width: item.size.width,
                height: item.size.height))
        }
        CATransaction.commit()
        var settledMotion = motion
        for id in Array(settledMotion.items.keys) {
            guard var item = settledMotion.items[id] else { continue }
            item.offset = item.targetOffset
            item.velocity = .zero
            settledMotion.items[id] = item
        }
        updateActiveCompanionLayoutFromHubDrag(
            hubFrame: hubFrame,
            motion: settledMotion)
        companionHubDragMotion = nil
        detachCompanionPileWindows()
        finishCompanionHubDragRendering()
    }

    private func updateActiveCompanionLayoutFromHubDrag(
        hubFrame: NSRect,
        motion: GaiCompanionHubDragMotion
    ) {
        var frames = Dictionary(uniqueKeysWithValues: motion.items.map { id, item in
            (id, NSRect(
                x: hubFrame.minX + item.offset.x,
                y: hubFrame.minY + item.offset.y,
                width: item.size.width,
                height: item.size.height))
        })
        frames[companionHubID] = hubFrame
        activeCompanionStackLayout = GaiCompanionStackResolvedLayout(
            orientation: motion.orientation,
            anchorCenter: CGPoint(x: hubFrame.midX, y: hubFrame.midY),
            cellSize: motion.cellSize,
            frames: frames)
    }

    private func criticallyDampedStep(
        value: CGFloat,
        velocity: CGFloat,
        target: CGFloat,
        deltaTime: CGFloat,
        angularFrequency: CGFloat,
        decay: CGFloat
    ) -> (value: CGFloat, velocity: CGFloat) {
        let displacement = value - target
        let coefficient = velocity + angularFrequency * displacement
        return (
            target + (displacement + coefficient * deltaTime) * decay,
            (velocity - angularFrequency * coefficient * deltaTime) * decay)
    }

    private func cancelCompanionHubDragMotion() {
        guard companionHubDragMotion != nil else { return }
        companionHubDragDisplayLink.stop()
        companionHubDragMotion = nil
        detachCompanionPileWindows()
        finishCompanionHubDragRendering()
    }

    private func finishCompanionHubDragRendering() {
        companionHubController?.finishStackTransition()
        for runtime in runtimes {
            panelControllers[runtime.id]?.finishStackTransition(
                interactive: companionStackIsExpanded,
                selected: explicitlySelectedCompanionID == runtime.id,
                restingScale: 1)
        }
    }

    private func updateFreeformCompanionFrame(id: UUID, frame: NSRect) {
        guard let layout = activeCompanionStackLayout else { return }
        var frames = layout.frames
        frames[id] = frame
        activeCompanionStackLayout = GaiCompanionStackResolvedLayout(
            orientation: layout.orientation,
            anchorCenter: id == companionHubID
                ? CGPoint(x: frame.midX, y: frame.midY)
                : layout.anchorCenter,
            cellSize: layout.cellSize,
            frames: frames)
    }

    private func persistFreeformCompanionFrame(
        runtime: GaiCompanionRuntime,
        frame: NSRect,
        screen: NSScreen
    ) {
        updateFreeformCompanionFrame(id: runtime.id, frame: frame)
        persistCompanionAnchorFrame(frame, runtime: runtime, screen: screen)
    }

    /// The occupied cell yields through a continuous magnetic field. Pointer
    /// distance chooses the desired attraction, while a display-synchronised
    /// spring supplies weight and continuity between irregular AppKit drag
    /// events. Target hysteresis keeps the field latched near cell boundaries.
    private func previewOrganicCompanionSwapIfNeeded(
        movingID: UUID,
        frame: NSRect
    ) {
        guard let layout = activeCompanionStackLayout,
              layout.frames[movingID] != nil else {
            stopOrganicCompanionSwapMotion(preservingFrames: false)
            return
        }

        if companionStackSwapMotion?.movingID != movingID {
            stopOrganicCompanionSwapMotion(preservingFrames: false)
            companionStackSwapMotion = GaiCompanionSwapMotion(
                movingID: movingID,
                activeTargetID: nil,
                hapticTargetID: nil,
                items: [:],
                lift: 0,
                liftVelocity: 0,
                targetLift: 0.28,
                lastTimestamp: CACurrentMediaTime())
        }
        guard var motion = companionStackSwapMotion else { return }

        let pointer = CGPoint(x: frame.midX, y: frame.midY)
        let candidates = runtimes.compactMap { runtime
            -> (id: UUID, distance: CGFloat)? in
            guard runtime.id != movingID,
                  let targetFrame = layout.frames[runtime.id] else { return nil }
            return (
                runtime.id,
                GaiCompanionMagneticSwap.normalizedDistance(
                    from: pointer,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY),
                    cellSize: layout.cellSize))
        }
        let nearest = candidates.min { $0.distance < $1.distance }
        let latched = motion.activeTargetID.flatMap { activeID in
            candidates.first(where: { $0.id == activeID })
        }
        let target = if let latched,
                        latched.distance <= GaiCompanionMagneticSwap.attractionRadius,
                        latched.distance <= (nearest?.distance ?? .greatestFiniteMagnitude)
                            + GaiCompanionMagneticSwap.targetHysteresis {
            latched
        } else {
            nearest
        }

        for id in Array(motion.items.keys) {
            motion.items[id]?.targetProgress = 0
        }

        var influence = CGFloat.zero
        if let target,
           target.distance < GaiCompanionMagneticSwap.attractionRadius {
            influence = GaiCompanionMagneticSwap.influence(
                normalizedDistance: target.distance)
            var item = motion.items[target.id] ?? GaiCompanionSwapItem(
                progress: 0,
                velocity: 0,
                targetProgress: 0)
            item.targetProgress = influence
            motion.items[target.id] = item
            motion.activeTargetID = target.id

            if influence >= GaiCompanionMagneticSwap.lockThreshold,
               motion.hapticTargetID != target.id {
                NSHapticFeedbackManager.defaultPerformer.perform(
                    .alignment,
                    performanceTime: .now)
                motion.hapticTargetID = target.id
            } else if influence < 0.42,
                      motion.hapticTargetID == target.id {
                motion.hapticTargetID = nil
            }
        } else {
            motion.activeTargetID = nil
            motion.hapticTargetID = nil
        }

        // A small constant lift separates the carried mascot from the grid;
        // the field adds the remaining lift as it locks onto a neighbour.
        motion.targetLift = 0.24 + influence * 0.76
        companionStackSwapMotion = motion
        companionStackSwapDisplayLink.start(
            synchronizedTo: companionHubController?.companionPanel.contentView)
    }

    private func advanceOrganicCompanionSwapMotion(at timestamp: CFTimeInterval) {
        guard var motion = companionStackSwapMotion,
              let layout = activeCompanionStackLayout,
              let sourceFrame = layout.frames[motion.movingID] else {
            companionStackSwapDisplayLink.stop()
            return
        }

        let deltaTime = min(
            max(timestamp - motion.lastTimestamp, 1.0 / 240.0),
            1.0 / 20.0)
        motion.lastTimestamp = timestamp
        let angularFrequency = CGFloat(9.8)
        let decay = exp(-angularFrequency * CGFloat(deltaTime))
        var settled = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in Array(motion.items.keys) {
            guard var item = motion.items[id],
                  let targetFrame = layout.frames[id] else {
                motion.items.removeValue(forKey: id)
                continue
            }
            let step = criticallyDampedStep(
                value: item.progress,
                velocity: item.velocity,
                target: item.targetProgress,
                deltaTime: CGFloat(deltaTime),
                angularFrequency: angularFrequency,
                decay: decay)
            item.progress = min(max(step.value, 0), 1)
            item.velocity = step.velocity

            let bendSeed = id.uuidString.utf8.reduce(0) {
                ($0 &* 31 &+ Int($1)) & 0x7fff
            }
            let bend: CGFloat = bendSeed.isMultiple(of: 2) ? 10 : -10
            let previewFrame = companionStackFrame(
                from: targetFrame,
                to: sourceFrame,
                position: item.progress,
                linearProgress: item.progress,
                bend: bend)
            panelControllers[id]?.applyStackTransitionFrame(
                previewFrame,
                alpha: 1,
                scale: 1 - 0.032 * sin(.pi * item.progress),
                orderFront: false)

            let itemSettled = abs(item.progress - item.targetProgress) <= 0.001
                && abs(item.velocity) <= 0.01
            if itemSettled, item.targetProgress == 0 {
                panelControllers[id]?.applyStackTransitionFrame(
                    targetFrame,
                    alpha: 1,
                    scale: 1,
                    orderFront: false)
                motion.items.removeValue(forKey: id)
            } else {
                motion.items[id] = item
                if !itemSettled { settled = false }
            }
        }

        let liftStep = criticallyDampedStep(
            value: motion.lift,
            velocity: motion.liftVelocity,
            target: motion.targetLift,
            deltaTime: CGFloat(deltaTime),
            angularFrequency: angularFrequency,
            decay: decay)
        motion.lift = min(max(liftStep.value, 0), 1)
        motion.liftVelocity = liftStep.velocity
        let liftSettled = abs(motion.lift - motion.targetLift) <= 0.001
            && abs(motion.liftVelocity) <= 0.01
        if !liftSettled { settled = false }
        panelControllers[motion.movingID]?.applyMagneticDragScale(
            1 + 0.035 * motion.lift)
        CATransaction.commit()

        companionStackSwapMotion = motion
        if settled {
            companionStackSwapDisplayLink.stop()
        }
    }

    private func stopOrganicCompanionSwapMotion(preservingFrames: Bool) {
        companionStackSwapDisplayLink.stop()
        guard let motion = companionStackSwapMotion else { return }
        defer { companionStackSwapMotion = nil }
        guard !preservingFrames,
              let layout = activeCompanionStackLayout else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in motion.items.keys {
            guard let targetFrame = layout.frames[id] else { continue }
            panelControllers[id]?.applyStackTransitionFrame(
                targetFrame,
                alpha: 1,
                scale: 1,
                orderFront: false)
        }
        panelControllers[motion.movingID]?.applyMagneticDragScale(1)
        CATransaction.commit()
    }

    private func settleExpandedCompanionDrag(
        runtime: GaiCompanionRuntime,
        frame: NSRect,
        screen: NSScreen
    ) {
        _ = screen
        guard let layout = activeCompanionStackLayout else {
            stopOrganicCompanionSwapMotion(preservingFrames: false)
            return
        }

        let source = runtime.record.stackCoordinate ?? .origin
        var magneticDestination: GaiCompanionStackCoordinate?
        if let motion = companionStackSwapMotion,
           motion.movingID == runtime.id,
           let targetID = motion.activeTargetID,
           let item = motion.items[targetID],
           item.targetProgress >= GaiCompanionMagneticSwap.lockThreshold
                || item.progress >= GaiCompanionMagneticSwap.lockThreshold,
           let targetRuntime = self.runtime(id: targetID) {
            magneticDestination = targetRuntime.record.stackCoordinate
        }
        // Organic mode owns a dense footprint: dragging changes which mascot
        // occupies a slot, never the footprint itself. Free placement remains
        // available through the dedicated freeform mode.
        let destination = magneticDestination ?? source
        if destination == source {
            reflowExpandedCompanionStack(animated: true)
            return
        }
        if let target = runtimes.first(where: {
            $0.id != runtime.id && $0.record.stackCoordinate == destination
        }) {
            let records = store.update(ids: [runtime.id, target.id]) { record in
                if record.id == runtime.id {
                    record.stackCoordinate = destination
                } else if record.id == target.id {
                    record.stackCoordinate = source
                }
            }
            for record in records {
                self.runtime(id: record.id)?.replaceRecord(record)
            }
            reflowExpandedCompanionStack(animated: true)
            return
        }

        reflowExpandedCompanionStack(animated: true)
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
        center.addObserver(
            self, selector: #selector(companionPreferencesDidChange(_:)),
            name: UserDefaults.didChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil)
    }

    @objc private func activeSpaceDidChange(_ notification: Notification) {
        _ = notification
        activeSpaceRefreshGeneration &+= 1
        let generation = activeSpaceRefreshGeneration
        restoreFloatingWindowsOnActiveSpace()

        // Mission Control posts at the boundary of its compositor animation.
        // Reassert once on the following settled frame so a fast trackpad
        // swipe cannot leave an overlay associated only with the prior Space.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.activeSpaceRefreshGeneration == generation else { return }
            self.restoreFloatingWindowsOnActiveSpace()
        }
    }

    private func restoreFloatingWindowsOnActiveSpace() {
        guard agentWindowsAreVisible else { return }
        for controller in panelControllers.values {
            controller.restoreVisibilityOnActiveSpace(
                agentWindowsVisible: true,
                companionIsVisible: companionStackIsExpanded)
        }
        companionHubController?.restoreVisibilityOnActiveSpace(true)
    }

    @objc private func companionPreferencesDidChange(_ notification: Notification) {
        _ = notification
        let mode = GaiCompanionStackMode.current(in: userDefaults)
        guard mode != companionStackMode else { return }
        cancelCompanionHubDragMotion()
        stopOrganicCompanionSwapMotion(preservingFrames: false)
        companionStackMode = mode
        if mode == .organicGrid {
            reconcileCompanionStackCoordinates()
        }
        guard companionStackIsExpanded else {
            settleCompanionStackVisibility()
            return
        }
        activeCompanionStackLayout = nil
        reflowExpandedCompanionStack(animated: true)
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
        cancelForegroundProviderProbe(for: runtime.id)

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
            reconcileResponseActivationProbe(for: runtime)
            reconcileResponseSettlementWatchdog(for: runtime)
        }
        updateDockBadge()
    }

    @objc private func didFinishShellCommand(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let runtime = currentRuntime(for: surface) else { return }

        cancelForegroundProviderProbe(for: runtime.id)
        let mayHaveLiveCLI = runtime.liveProvider != .terminal
            || runtime.activity.provider.map { $0 != .terminal } == true
        if mayHaveLiveCLI {
            scheduleForegroundProviderShellReturnProbe(
                for: runtime,
                surface: surface)
        }

        guard runtime.activity.phase.belongsToActiveGeneration else { return }

        let exitCode = notification.userInfo?[Notification.Name.GaiSurfaceCommandExitCodeKey]
            as? Int ?? -1
        let durationNanoseconds = (notification.userInfo?[
            Notification.Name.GaiSurfaceCommandDurationNanosecondsKey
        ] as? NSNumber)?.uint64Value ?? 0
        let provider = runtime.liveProvider != .terminal
            ? runtime.liveProvider
            : runtime.activity.provider ?? inferredProvider(for: runtime)
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
        // A Return used inside an already active TUI must not replace the
        // response token or cancel its settlement watchdog.
        if runtime.activity.phase != .working {
            beginResponseTurn(for: runtime, surface: surface, origin: .user)
        }
        recordSubmittedInput(for: runtime)
        reconcileResponseActivationProbe(for: runtime, surface: surface)
        // AppKit posts this semantic boundary immediately before forwarding
        // Enter to Ghostty. The first delayed sample therefore observes the
        // process which the shell actually launched, not the previous shell.
        scheduleForegroundProviderLaunchProbe(
            for: runtime,
            surface: surface)
    }

    private func recordSubmittedInput(
        for runtime: GaiCompanionRuntime,
        submissionIsGuaranteed: Bool = false,
        validatedProvider: GaiCompanionProvider? = nil
    ) {
        runtime.acknowledgeCompletion()
        let provider: GaiCompanionProvider
        let liveProviderChanged: Bool
        if let validatedProvider {
            // `submitPrompt` performed the exact process gate immediately
            // before this call. Reuse that proof rather than issuing another
            // pair of sysctl reads on the same main-thread interaction.
            provider = validatedProvider
            liveProviderChanged = false
        } else {
            switch foregroundProviderObservation(for: runtime) {
            case .provider(let observedProvider):
                provider = observedProvider
                liveProviderChanged = runtime.observeLiveProvider(observedProvider)
            case .shell:
                provider = .terminal
                liveProviderChanged = runtime.clearLiveProvider()
            case .unavailable:
                // Keep authenticated/process-observed knowledge when proc_pidinfo
                // is transiently unavailable. A configured launch command or a
                // terminal title is only intent and must never manufacture a live
                // CLI identity after a failed launch.
                provider = runtime.liveProvider
                liveProviderChanged = false
            }
        }
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
                phase: runtime.activity.phase)
        }
        guard let kind else {
            updateDockBadge()
            if liveProviderChanged {
                publishCompanionStateChange()
            }
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
            reconcileResponseSettlementWatchdog(for: runtime)
        }
        updateDockBadge()
        if disposition == .appliedEvent || liveProviderChanged {
            publishCompanionStateChange()
        }
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
        cancelCompanionHubDragMotion()
        stopOrganicCompanionSwapMotion(preservingFrames: false)
        detachCompanionPileWindows()
        ensureCompanionHubPanel()
        let hubScreen = targetScreenForCompanionHub()
        companionHubController?.show(
            frame: companionHubFrame(screen: hubScreen),
            visible: agentWindowsAreVisible)
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
                agentWindowsAreVisible: agentWindowsAreVisible,
                companionIsVisible: agentWindowsAreVisible && companionStackIsExpanded)
        }
        if companionStackIsExpanded {
            reflowExpandedCompanionStack(animated: false)
        } else {
            settleCompanionStackVisibility()
        }
    }

    @discardableResult
    private func applyLifecycleEvent(
        _ event: GaiCompanionEvent,
        to runtime: GaiCompanionRuntime,
        notificationTitle: String,
        notificationBody: String
    ) -> GaiCompanionReductionDisposition {
        let wasProvisionalShellLaunch = event.kind == .ready
            && runtime.hasProvisionalShellLaunch
        let previousLiveProvider = runtime.liveProvider
        let disposition = runtime.apply(.event(event))
        let liveProviderChanged = runtime.liveProvider != previousLiveProvider
        let readinessSettledShellLaunch = wasProvisionalShellLaunch
            && disposition == .appliedEvent
            && runtime.activity.phase == .idle
        if readinessSettledShellLaunch {
            cancelForegroundProviderProbe(for: runtime.id)
            discardProvisionalShellResponseTurn(for: runtime.id)
        }
        if disposition == .appliedEvent {
            reconcileResponseActivationProbe(for: runtime)
            reconcileResponseSettlementWatchdog(for: runtime)
        }
        guard disposition == .appliedEvent else {
            if liveProviderChanged {
                publishCompanionStateChange()
            }
            return disposition
        }

        switch event.kind {
        case .stop, .failed, .awaitingInput, .awaitingApproval:
            scheduleResponseCapture(for: event, runtime: runtime)
        case .cancelled, .exited:
            responseCaptureTasks.removeValue(forKey: runtime.id)?.cancel()
            responseSettlementWatchdogs.removeValue(forKey: runtime.id)?.cancel()
            responseActivationProbes.removeValue(forKey: runtime.id)?.cancel()
            lastResponseStore.resetTurn(for: runtime.id)
        case .ready, .started, .resumed:
            break
        }

        updateDockBadge()
        publishCompanionStateChange()
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
        responseActivationProbes.removeValue(forKey: runtime.id)?.cancel()
        _ = lastResponseStore.begin(
            agentID: runtime.id,
            origin: origin,
            screenText: surface.gaiResponseCaptureScreenText(),
            submittedText: submittedText)
    }

    private func discardProvisionalShellResponseTurn(for runtimeID: UUID) {
        responseCaptureTasks.removeValue(forKey: runtimeID)?.cancel()
        responseSettlementWatchdogs.removeValue(forKey: runtimeID)?.cancel()
        responseActivationProbes.removeValue(forKey: runtimeID)?.cancel()
        lastResponseStore.resetTurn(for: runtimeID)
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

    /// Starts or reconciles the finite fallback attached to one ambiguous
    /// physical Return. Calls without a surface only cancel a probe after an
    /// authoritative lifecycle transition; they never create background work.
    private func reconcileResponseActivationProbe(
        for runtime: GaiCompanionRuntime,
        surface: Ghostty.SurfaceView? = nil
    ) {
        guard runtime.activity.phase == .idle,
              let responseToken = lastResponseStore.token(for: runtime.id) else {
            responseActivationProbes.removeValue(forKey: runtime.id)?.cancel()
            return
        }
        guard let surface else { return }
        let provider = runtime.liveProvider
        guard provider != .terminal else {
            responseActivationProbes.removeValue(forKey: runtime.id)?.cancel()
            return
        }

        if let current = responseActivationProbes[runtime.id],
           current.incarnationToken == runtime.eventToken,
           current.responseToken == responseToken,
           current.provider == provider {
            return
        }

        responseActivationProbes.removeValue(forKey: runtime.id)?.cancel()
        guard let baselineScreenText = lastResponseStore.baselineScreenText(
            for: responseToken) else { return }
        let probe = GaiCompanionResponseActivationProbe(
            runtimeID: runtime.id,
            incarnationToken: runtime.eventToken,
            responseToken: responseToken,
            provider: provider,
            baselineScreenText: baselineScreenText)
        responseActivationProbes[runtime.id] = probe
        scheduleResponseActivationSample(
            probe,
            runtime: runtime,
            surface: surface,
            attempt: 0)
    }

    private func scheduleResponseActivationSample(
        _ probe: GaiCompanionResponseActivationProbe,
        runtime: GaiCompanionRuntime,
        surface: Ghostty.SurfaceView,
        attempt: Int
    ) {
        guard Self.responseActivationProbeDelays.indices.contains(attempt) else {
            finishResponseActivationProbe(probe, resetPendingTurn: true)
            return
        }
        let delay = Self.responseActivationProbeDelays[attempt]
        let workItem = DispatchWorkItem { [weak self, weak runtime, weak surface, weak probe] in
            guard let self,
                  let runtime,
                  let surface,
                  let probe,
                  self.responseActivationProbes[probe.runtimeID] === probe,
                  self.runtime(id: probe.runtimeID) === runtime,
                  runtime.surfaceView === surface,
                  runtime.eventToken == probe.incarnationToken,
                  runtime.activity.phase == .idle,
                  self.lastResponseStore.token(for: probe.runtimeID)
                      == probe.responseToken else {
                probe?.cancel()
                return
            }
            probe.workItem = nil

            switch self.foregroundProviderObservation(for: runtime) {
            case .provider(let provider) where provider == probe.provider:
                _ = runtime.observeLiveProvider(provider)
            case .unavailable:
                // A transient proc lookup may preserve the provider identity
                // already proven at the Return boundary.
                break
            case .provider, .shell:
                if runtime.clearLiveProvider() {
                    self.publishCompanionStateChange()
                }
                self.finishResponseActivationProbe(probe, resetPendingTurn: true)
                return
            }

            let screenText = surface.gaiResponseCaptureScreenText()
            let candidate = self.lastResponseStore.candidateResponse(
                token: probe.responseToken,
                screenText: screenText)
            guard probe.observation.observe(
                screenText: screenText,
                candidateResponse: candidate) else {
                self.scheduleResponseActivationSample(
                    probe,
                    runtime: runtime,
                    surface: surface,
                    attempt: attempt + 1)
                return
            }

            self.finishResponseActivationProbe(probe, resetPendingTurn: false)
            let event = GaiCompanionEvent(
                surfaceID: runtime.id,
                provider: probe.provider,
                eventID: self.nextEventID(prefix: "observed-input-activity"),
                kind: .started,
                source: .userInput,
                message: "Prompt activity observed")
            _ = self.applyLifecycleEvent(
                event,
                to: runtime,
                notificationTitle: self.providerDisplayName(probe.provider),
                notificationBody: "Work started")
        }
        probe.workItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem)
    }

    private func finishResponseActivationProbe(
        _ probe: GaiCompanionResponseActivationProbe,
        resetPendingTurn: Bool
    ) {
        guard responseActivationProbes[probe.runtimeID] === probe else { return }
        responseActivationProbes.removeValue(forKey: probe.runtimeID)?.cancel()
        guard resetPendingTurn,
              lastResponseStore.token(for: probe.runtimeID) == probe.responseToken else { return }
        lastResponseStore.resetTurn(for: probe.runtimeID)
        publishCompanionStateChange()
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

    private func publishCompanionStateChange() {
        NotificationCenter.default.post(
            name: .gaiCompanionStateDidChange,
            object: self)
    }

    private func cancelForegroundProviderProbe(for runtimeID: UUID) {
        foregroundProviderProbeTasks.removeValue(forKey: runtimeID)?.workItem.cancel()
    }

    private func scheduleForegroundProviderLaunchProbe(
        for runtime: GaiCompanionRuntime,
        surface: Ghostty.SurfaceView
    ) {
        startForegroundProviderProbe(
            for: runtime,
            surface: surface,
            purpose: .launch)
    }

    private func scheduleForegroundProviderShellReturnProbe(
        for runtime: GaiCompanionRuntime,
        surface: Ghostty.SurfaceView
    ) {
        startForegroundProviderProbe(
            for: runtime,
            surface: surface,
            purpose: .shellReturn)
    }

    private func startForegroundProviderProbe(
        for runtime: GaiCompanionRuntime,
        surface: Ghostty.SurfaceView,
        purpose: GaiCompanionProviderProbeSchedule.Purpose
    ) {
        cancelForegroundProviderProbe(for: runtime.id)
        scheduleForegroundProviderProbeAttempt(
            for: runtime,
            surface: surface,
            incarnationToken: runtime.eventToken,
            purpose: purpose,
            attempt: 0,
            nonce: UUID())
    }

    private func scheduleForegroundProviderProbeAttempt(
        for runtime: GaiCompanionRuntime,
        surface: Ghostty.SurfaceView,
        incarnationToken: String,
        purpose: GaiCompanionProviderProbeSchedule.Purpose,
        attempt: Int,
        nonce: UUID
    ) {
        guard let delay = GaiCompanionProviderProbeSchedule.delay(
            for: purpose,
            attempt: attempt) else {
            finishForegroundProviderProbe(for: runtime.id, nonce: nonce)
            return
        }

        let runtimeID = runtime.id
        let workItem = DispatchWorkItem { [weak self, weak runtime, weak surface] in
            guard let self,
                  self.foregroundProviderProbeTasks[runtimeID]?.nonce == nonce else { return }
            guard let runtime,
                  let surface,
                  self.runtime(id: runtimeID) === runtime,
                  runtime.surfaceView === surface,
                  runtime.eventToken == incarnationToken else {
                self.finishForegroundProviderProbe(for: runtimeID, nonce: nonce)
                return
            }

            if purpose == .shellReturn, runtime.liveProvider == .terminal {
                self.finishForegroundProviderProbe(for: runtimeID, nonce: nonce)
                return
            }

            let foregroundArguments = self.foregroundProcessArguments(for: runtime)
            let observation = GaiForegroundProviderObservation.classify(
                arguments: foregroundArguments)
            switch (purpose, observation) {
            case (.launch, .provider(let provider)):
                let isIdleInteractiveLaunch = foregroundArguments.map {
                    GaiCompanionProviderClassifier.isProvenIdleInteractiveLaunch(
                        provider: provider,
                        argv: $0)
                } ?? false
                let reconciliation = runtime.reconcileLaunchedProvider(
                    provider,
                    maySettleProvisionalShellLaunch: isIdleInteractiveLaunch)
                self.finishForegroundProviderProbe(for: runtimeID, nonce: nonce)
                if reconciliation.settledProvisionalTurn {
                    self.discardProvisionalShellResponseTurn(for: runtimeID)
                }
                if reconciliation.changedRuntimeState {
                    self.updateDockBadge()
                    self.publishCompanionStateChange()
                }

            case (.launch, .shell):
                let changed = runtime.clearLiveProvider()
                if changed {
                    self.publishCompanionStateChange()
                }
                self.scheduleForegroundProviderProbeAttempt(
                    for: runtime,
                    surface: surface,
                    incarnationToken: incarnationToken,
                    purpose: purpose,
                    attempt: attempt + 1,
                    nonce: nonce)

            case (.shellReturn, .shell):
                let changed = runtime.clearLiveProvider()
                self.finishForegroundProviderProbe(for: runtimeID, nonce: nonce)
                if changed {
                    self.publishCompanionStateChange()
                }

            default:
                self.scheduleForegroundProviderProbeAttempt(
                    for: runtime,
                    surface: surface,
                    incarnationToken: incarnationToken,
                    purpose: purpose,
                    attempt: attempt + 1,
                    nonce: nonce)
            }
        }
        foregroundProviderProbeTasks[runtimeID] = (nonce, workItem)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem)
    }

    private func finishForegroundProviderProbe(for runtimeID: UUID, nonce: UUID) {
        guard foregroundProviderProbeTasks[runtimeID]?.nonce == nonce else { return }
        foregroundProviderProbeTasks.removeValue(forKey: runtimeID)?.workItem.cancel()
    }

    // MARK: Helpers

    private func managedAgentSnapshot(
        for runtime: GaiCompanionRuntime
    ) -> GaiManagedAgentSnapshot {
        GaiManagedAgentSnapshot(
            id: runtime.id,
            name: runtime.record.displayName,
            provider: runtime.liveProvider,
            phase: runtime.activity.phase,
            directoryPath: runtime.record.directoryPath,
            launchCommand: runtime.record.launchCommand,
            lastResponse: lastResponseStore.lastResponse(for: runtime.id),
            isResponsePending: lastResponseStore.hasPendingTurn(for: runtime.id))
    }

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
        if provider == .grok { return "Grok Build" }
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
        allowTitleFallback: Bool = true,
        allowLaunchCommandFallback: Bool = true
    ) -> GaiCompanionProvider {
        let arguments = foregroundProcessArguments(for: runtime) ?? []
        return GaiCompanionProviderClassifier.classify(
            launchCommand: allowLaunchCommandFallback
                ? runtime.record.launchCommand
                : nil,
            terminalTitle: allowTitleFallback ? runtime.surfaceView?.title : nil,
            argv: arguments) ?? .terminal
    }

    private func foregroundProviderObservation(
        for runtime: GaiCompanionRuntime
    ) -> GaiForegroundProviderObservation {
        GaiForegroundProviderObservation.classify(
            arguments: foregroundProcessArguments(for: runtime))
    }

    private func foregroundProcessArguments(
        for runtime: GaiCompanionRuntime
    ) -> [String]? {
        guard let rawSurface = runtime.surfaceView?.surface else { return nil }
        let rawPID = ghostty_surface_foreground_pid(rawSurface)
        guard rawPID != 0, let foregroundPID = Int(exactly: rawPID) else { return nil }
        let arguments = GaiCompanionProcessArguments.arguments(forPID: foregroundPID)
        return arguments.isEmpty ? nil : arguments
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
        return fallback.isEmpty ? "Teddy CLI" : fallback
    }

    private func suggestedPosition(for index: Int) -> GaiCompanionNormalizedPosition {
        let column = index % 4
        let row = (index / 4) % 3
        return GaiCompanionNormalizedPosition(
            x: 0.18 + Double(column) * 0.2,
            y: 0.2 + Double(row) * 0.26)
    }

    @discardableResult
    private func previewScale(
        _ runtime: GaiCompanionRuntime,
        scalePercent: GaiCompanionScalePercent
    ) -> Bool {
        guard runtime.record.scalePercent != scalePercent else { return false }
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
        return true
    }

    @discardableResult
    private func previewCompanionHubScale(
        _ scalePercent: GaiCompanionScalePercent
    ) -> Bool {
        guard companionHubScalePercent != scalePercent else { return false }
        companionHubScalePercent = scalePercent
        companionHubState.scalePercent = scalePercent

        guard let controller = companionHubController else { return true }
        let frame = controller.companionPanel.frame
        let size = companionPanelSize(scalePercent: scalePercent)
        controller.resize(frame: NSRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height))
        return true
    }

    private func persistCompanionHubScale() {
        guard var placement = companionHubPlacement else { return }
        placement.scalePercent = companionHubScalePercent
        companionHubPlacement = placement
        if !placement.persist(to: userDefaults) {
            Ghostty.logger.error("could not persist companion hub scale")
        }
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
        companionFrame: NSRect,
        compactGeometry: GaiCompanionPreviewGeometry? = nil
    ) -> (
        placement: GaiCompanionTerminalPlacement,
        terminalFrame: NSRect?
    ) {
        let preview = compactGeometry ?? compactPreviewGeometry(
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

    /// One cached grid bay is shared by every hover preview on this display.
    private func sharedHoverTerminalGeometry(
        for runtime: GaiCompanionRuntime,
        screen: NSScreen,
        companionFrame: NSRect
    ) -> GaiCompanionPreviewGeometry {
        guard companionStackIsExpanded,
              let layout = activeCompanionStackLayout else {
            return compactPreviewGeometry(
                for: runtime,
                screen: screen,
                companionFrame: companionFrame)
        }

        let workArea = screen.visibleFrame.insetBy(
            dx: Self.screenMargin,
            dy: Self.screenMargin)
        let screenKey = displayID(for: screen) ?? NSStringFromRect(screen.frame)
        if let cached = companionHoverTerminalBays[screenKey],
           cached.layout == layout,
           cached.workArea == workArea {
            return cached.geometry
        }

        var visibleFrames = layout.frames.values.filter {
            !$0.intersection(screen.frame).isNull
        }
        if visibleFrames.isEmpty {
            visibleFrames = [companionFrame]
        }
        let frameBounds = visibleFrames.dropFirst().reduce(visibleFrames[0]) {
            $0.union($1)
        }
        let anchorCenter = screen.frame.contains(layout.anchorCenter)
            ? layout.anchorCenter
            : CGPoint(x: frameBounds.midX, y: frameBounds.midY)
        let terminalSize = NSSize(
            width: min(
                max(CGFloat(runtime.record.compactSize.width), 220),
                workArea.width),
            height: min(
                CGFloat(runtime.record.compactSize.height)
                    + GaiStageMetrics.paneHeaderHeight,
                workArea.height))
        let geometry = GaiCompanionTerminalBayLayout.resolve(
            companionFrames: visibleFrames,
            anchorCenter: anchorCenter,
            cellSize: layout.cellSize,
            terminalSize: terminalSize,
            workArea: workArea,
            gap: Self.terminalGap)
        companionHoverTerminalBays[screenKey] = GaiCompanionHoverTerminalBayCache(
            layout: layout,
            workArea: workArea,
            geometry: geometry)
        return geometry
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

    /// Places the creator with the exact same four-side scorer as a compact
    /// terminal, while keeping its independent AppKit window size and lifecycle.
    func companionCreatorWindowFrame(windowSize: NSSize) -> NSRect? {
        start()
        guard let hubController = companionHubController else { return nil }
        let screen = hubController.companionPanel.screen ?? targetScreenForCompanionHub()
        let workArea = screen.visibleFrame.insetBy(
            dx: Self.screenMargin,
            dy: Self.screenMargin)
        let size = NSSize(
            width: min(windowSize.width, workArea.width),
            height: min(windowSize.height, workArea.height))
        let hubFrame = hubController.companionPanel.frame
        let rawCandidates = rawPreviewCandidates(
            companionFrame: hubFrame,
            terminalSize: size)
        let obstacles = panelControllers.values.flatMap { controller -> [NSRect] in
            var frames: [NSRect] = []
            if controller.companionPanel.isVisible {
                frames.append(controller.companionPanel.frame)
            }
            if controller.terminalPanel.isVisible {
                frames.append(controller.terminalPanel.frame)
            }
            return frames
        }
        guard let selected = rawCandidates.enumerated().min(by: { lhs, rhs in
            let left = constrained(lhs.element, to: workArea)
            let right = constrained(rhs.element, to: workArea)
            return placementScore(
                raw: lhs.element,
                constrained: left,
                preferenceIndex: lhs.offset,
                previousPlacement: companionHubCreatorPlacement,
                companionFrame: hubFrame,
                obstacles: obstacles,
                workArea: workArea)
                < placementScore(
                    raw: rhs.element,
                    constrained: right,
                    preferenceIndex: rhs.offset,
                    previousPlacement: companionHubCreatorPlacement,
                    companionFrame: hubFrame,
                    obstacles: obstacles,
                    workArea: workArea)
        })?.element else { return nil }
        companionHubCreatorPlacement = selected.placement
        return constrained(selected, to: workArea).terminalFrame
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
