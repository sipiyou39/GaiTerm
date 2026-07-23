#if os(macOS)
import Foundation

/// Stable provider identifier carried by structured companion events.
///
/// This is a value type instead of an enum so a newer CLI provider can be
/// decoded without requiring an application update first.
struct GaiCompanionProvider: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let codex = Self(rawValue: "codex")
    static let claude = Self(rawValue: "claude")
    static let agy = Self(rawValue: "agy")
    static let opencode = Self(rawValue: "opencode")
    static let terminal = Self(rawValue: "terminal")
}

private enum GaiCompanionTurnIdentifierScope {
    case turn
    case session
}

private extension GaiCompanionProvider {
    var turnIdentifierScope: GaiCompanionTurnIdentifierScope {
        // Codex exposes a distinct turn_id. The other current adapters expose
        // a session identifier which can legitimately repeat across prompts.
        self == .codex ? .turn : .session
    }
}

private extension GaiCompanionEvent {
    var turnIdentifierScope: GaiCompanionTurnIdentifierScope {
        if turnID?.hasPrefix("turn:") == true { return .turn }
        if turnID?.hasPrefix("session:") == true { return .session }
        return provider.turnIdentifierScope
    }
}

extension GaiCompanionProvider: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Semantic phase projected by the companion UI.
enum GaiCompanionPhase: String, Codable, Hashable, Sendable {
    case idle
    case working
    case awaitingInput
    case awaitingApproval
    case completedUnseen
    case failed
    case exited

    var belongsToActiveGeneration: Bool {
        switch self {
        case .working, .awaitingInput, .awaitingApproval:
            true
        case .idle, .completedUnseen, .failed, .exited:
            false
        }
    }
}

/// Provider-independent lifecycle events accepted by the companion reducer.
enum GaiCompanionEventKind: String, Codable, Hashable, Sendable {
    /// The provider process initialized and is waiting for its first prompt.
    /// This ends the provisional shell-launch animation without pretending a
    /// task completed.
    case ready
    /// A prompt or task began. A distinct event starts a new generation.
    case started
    /// The provider emitted its Stop hook. This is a completed turn, not input.
    case stop
    /// Work resumed after an approval, question, or tool boundary. Provider
    /// progress and local answers to a wait remain in the current generation;
    /// an Enter opens a sequence boundary only for a generic terminal without
    /// authoritative provider activity.
    case resumed
    case awaitingInput
    case awaitingApproval
    /// The user explicitly interrupted the active CLI turn.
    case cancelled
    case failed
    /// The terminal process exited; no later lifecycle event is accepted.
    case exited
}

/// Converts Ghostty's semantic shell boundary into an agent lifecycle event.
/// The established `notify-on-command-finish-after` duration is reused so a
/// quick `ls`, `cd`, or empty shell interaction does not masquerade as an
/// employee completing a task. For a recognized agent CLI this boundary means
/// the CLI process ended, not that an individual response completed.
enum GaiCompanionShellCompletionPolicy {
    static func eventKind(
        provider: GaiCompanionProvider,
        exitCode: Int,
        duration: Duration,
        minimumTerminalTaskDuration: Duration
    ) -> GaiCompanionEventKind {
        if provider != .terminal {
            return exitCode > 0 ? .failed : .cancelled
        }
        if duration < minimumTerminalTaskDuration {
            return .cancelled
        }
        return exitCode > 0 ? .failed : .stop
    }
}

/// Decides whether a local Return key is itself evidence of agent work.
/// Native provider adapters expose prompt-start/busy hooks, so their menus and
/// selectors must not optimistically animate. An unknown terminal has no
/// provider protocol and retains the local fallback. Answering an explicit
/// wait is always immediate.
enum GaiCompanionInputPolicy {
    static func eventKind(
        provider: GaiCompanionProvider,
        phase: GaiCompanionPhase,
        nativeAdapterIsReady: Bool = true
    ) -> GaiCompanionEventKind? {
        switch phase {
        case .awaitingInput, .awaitingApproval:
            return .resumed
        case .working:
            return nil
        case .idle, .completedUnseen, .failed, .exited:
            if provider == .codex
                || provider == .claude
                || provider == .agy
                || provider == .opencode,
               nativeAdapterIsReady {
                return nil
            }
            return .started
        }
    }
}

/// A provisional Return may time out only after a strongly identified
/// interactive agent owns the foreground. Generic shell commands retain their
/// work state until Ghostty's real command-finished boundary arrives.
enum GaiCompanionProvisionalExpiryPolicy {
    static func shouldExpire(stronglyInferredProvider provider: GaiCompanionProvider) -> Bool {
        provider != .terminal
    }
}

/// Authority of an activity event. Provider hooks are authoritative; terminal
/// bells/OSC notifications are fallbacks and must never overwrite a newer
/// structured state.
enum GaiCompanionEventSource: String, Codable, Hashable, Sendable {
    case providerHook
    case userInput
    case terminalFallback
    /// Ghostty proved that the foreground process or PTY ended. This is more
    /// authoritative than a provider hook about session liveness, while a
    /// previously recorded provider completion/failure remains more precise.
    case processLifecycle

    fileprivate var authority: Int {
        switch self {
        case .processLifecycle: 4
        case .providerHook: 3
        case .userInput: 2
        case .terminalFallback: 1
        }
    }
}

/// Structured event emitted by a provider adapter or the terminal runtime.
struct GaiCompanionEvent: Codable, Hashable, Identifiable, Sendable {
    let surfaceID: UUID
    let provider: GaiCompanionProvider
    let eventID: String
    let turnID: String?
    let kind: GaiCompanionEventKind
    let source: GaiCompanionEventSource
    let timestamp: Date
    let message: String?

    var id: String { eventID }

    // The event intentionally keeps its transport fields explicit at call sites.
    // swiftlint:disable:next function_parameter_count
    init(
        surfaceID: UUID,
        provider: GaiCompanionProvider,
        eventID: String,
        turnID: String? = nil,
        kind: GaiCompanionEventKind,
        source: GaiCompanionEventSource = .providerHook,
        timestamp: Date = Date(),
        message: String? = nil
    ) {
        self.surfaceID = surfaceID
        self.provider = provider
        self.eventID = eventID
        self.turnID = turnID
        self.kind = kind
        self.source = source
        self.timestamp = timestamp
        self.message = message
    }
}

/// Exact token the UI must return to acknowledge an unseen completion.
///
/// Including the generation prevents a delayed click from acknowledging a more
/// recent completion which happened to reuse the same surface.
struct GaiCompanionAcknowledgement: Codable, Hashable, Sendable {
    let surfaceID: UUID
    let eventID: String
    let generation: UInt64
}

struct GaiCompanionTurnIdentity: Codable, Hashable, Sendable {
    let provider: GaiCompanionProvider
    let turnID: String
    let wasTerminalBeforeSupersession: Bool
}

/// Reducer-owned state for one live terminal surface.
struct GaiCompanionActivityState: Codable, Equatable, Sendable {
    private static let maximumRememberedTurnIDs = 32

    let surfaceID: UUID
    private(set) var phase: GaiCompanionPhase
    private(set) var generation: UInt64
    private(set) var provider: GaiCompanionProvider?
    private(set) var turnID: String?
    private(set) var source: GaiCompanionEventSource?
    private(set) var generationAuthority: GaiCompanionEventSource?
    private(set) var provisionalStartGeneration: UInt64?
    private(set) var lastEventID: String?
    private(set) var lastEventTimestamp: Date?
    private(set) var message: String?
    private(set) var pendingAcknowledgement: GaiCompanionAcknowledgement?
    private(set) var lastCompletedGeneration: UInt64?
    private(set) var lastCancelledGeneration: UInt64?
    private(set) var supersededTurns: [GaiCompanionTurnIdentity]
    private(set) var recentEventIDs: [String]

    init(surfaceID: UUID) {
        self.surfaceID = surfaceID
        self.phase = .idle
        self.generation = 0
        self.provider = nil
        self.turnID = nil
        self.source = nil
        self.generationAuthority = nil
        self.provisionalStartGeneration = nil
        self.lastEventID = nil
        self.lastEventTimestamp = nil
        self.message = nil
        self.pendingAcknowledgement = nil
        self.lastCompletedGeneration = nil
        self.lastCancelledGeneration = nil
        self.supersededTurns = []
        self.recentEventIDs = []
    }

    func hasProcessed(eventID: String) -> Bool {
        recentEventIDs.contains(eventID)
    }

    fileprivate mutating func remember(eventID: String, maximumCount: Int) {
        recentEventIDs.append(eventID)
        let overflow = recentEventIDs.count - maximumCount
        if overflow > 0 {
            recentEventIDs.removeFirst(overflow)
        }
    }

    fileprivate mutating func acknowledge(_ acknowledgement: GaiCompanionAcknowledgement) {
        pendingAcknowledgement = nil
        if phase == .completedUnseen,
           lastEventID == acknowledgement.eventID {
            phase = .idle
        }
    }

    fileprivate mutating func expireProvisionalStart(generation expected: UInt64) -> Bool {
        guard generation == expected,
              provisionalStartGeneration == expected,
              generationAuthority == .userInput,
              phase == .working else { return false }
        phase = .idle
        provisionalStartGeneration = nil
        pendingAcknowledgement = nil
        message = nil
        return true
    }

    fileprivate func supersededTurn(
        provider: GaiCompanionProvider,
        turnID: String
    ) -> GaiCompanionTurnIdentity? {
        supersededTurns.last {
            $0.provider == provider && $0.turnID == turnID
        }
    }

    fileprivate mutating func rememberSupersededTurn(
        provider: GaiCompanionProvider,
        turnID: String,
        wasTerminalBeforeSupersession: Bool,
        maximumCount: Int
    ) {
        let identity = GaiCompanionTurnIdentity(
            provider: provider,
            turnID: turnID,
            wasTerminalBeforeSupersession: wasTerminalBeforeSupersession)
        supersededTurns.removeAll {
            $0.provider == provider && $0.turnID == turnID
        }
        supersededTurns.append(identity)
        let overflow = supersededTurns.count - maximumCount
        if overflow > 0 {
            supersededTurns.removeFirst(overflow)
        }
    }

    fileprivate mutating func apply(_ event: GaiCompanionEvent) {
        let previousPhase = phase
        let previousProvider = provider
        let previousTurnID = turnID
        let previousGenerationWasTerminal = previousPhase == .completedUnseen
            || previousPhase == .failed
            || lastCompletedGeneration == generation
            || lastCancelledGeneration == generation
        var openedNewGeneration = false
        let localSequenceBoundary = event.source == .userInput
            && (event.kind == .started
                || (event.kind == .resumed
                    && previousPhase == .working
                    && generationAuthority != .providerHook))
        let repeatsActiveProviderStart = event.source == .providerHook
            && event.kind == .started
            && previousPhase.belongsToActiveGeneration
            && previousProvider == event.provider
            && event.turnID != nil
            && previousTurnID == event.turnID

        if event.kind == .ready {
            // Session readiness identifies the provider without manufacturing
            // a work generation. It commonly follows the shell Enter that
            // launched the CLI and settles that provisional animation.
            if let eventTurnID = event.turnID {
                turnID = eventTurnID
            }
        } else if (event.kind == .started || localSequenceBoundary)
            && !repeatsActiveProviderStart {
            // Enter is observed synchronously before a provider hook. When the
            // typed hook arrives, enrich that provisional start with its turn
            // identifier instead of counting the same prompt twice.
            let enrichesProvisionalStart = provisionalStartGeneration == generation
                && event.source == .providerHook
                && previousProvider == event.provider
                && event.turnID != nil
                && (previousTurnID == nil || previousTurnID == event.turnID)
            if !enrichesProvisionalStart {
                generation = Self.nextGeneration(after: generation)
                turnID = event.turnID
                openedNewGeneration = true
            } else if let eventTurnID = event.turnID {
                turnID = eventTurnID
            }
        } else if event.kind != .exited {
            let continuesActiveGeneration = previousPhase.belongsToActiveGeneration
            let refinesKnownTurn = event.turnID != nil && event.turnID == previousTurnID
            if generation == 0 || (!continuesActiveGeneration && !refinesKnownTurn) {
                generation = Self.nextGeneration(after: generation)
                turnID = event.turnID
                openedNewGeneration = true
            } else if let eventTurnID = event.turnID {
                turnID = eventTurnID
            }
        }

        if openedNewGeneration,
           let previousProvider,
           let previousTurnID {
            rememberSupersededTurn(
                provider: previousProvider,
                turnID: previousTurnID,
                wasTerminalBeforeSupersession: previousGenerationWasTerminal,
                maximumCount: Self.maximumRememberedTurnIDs)
        }

        if openedNewGeneration || generationAuthority == nil {
            generationAuthority = event.source
        } else if let authority = generationAuthority,
                  event.source.authority > authority.authority {
            generationAuthority = event.source
        }

        if openedNewGeneration {
            provisionalStartGeneration = localSequenceBoundary
                ? generation
                : nil
        } else if event.source == .providerHook,
                  provisionalStartGeneration == generation {
            let claimsProvisionalSession = event.kind == .started
                || (event.provider == .agy && event.kind == .resumed)
            if claimsProvisionalSession {
                provisionalStartGeneration = nil
            }
        }
        if event.kind == .ready
            || event.kind == .stop
            || event.kind == .cancelled
            || event.kind == .failed
            || event.kind == .exited {
            provisionalStartGeneration = nil
        }

        if event.source == .terminalFallback,
           event.provider == .terminal,
           let previousProvider {
            provider = previousProvider
        } else {
            provider = event.provider
        }
        source = event.source
        lastEventID = event.eventID
        lastEventTimestamp = event.timestamp
        message = event.message

        switch event.kind {
        case .ready:
            phase = .idle
            pendingAcknowledgement = nil
        case .started:
            phase = .working
            pendingAcknowledgement = nil
        case .resumed:
            phase = .working
            pendingAcknowledgement = nil
        case .stop:
            phase = .completedUnseen
            lastCompletedGeneration = generation
            pendingAcknowledgement = GaiCompanionAcknowledgement(
                surfaceID: surfaceID,
                eventID: event.eventID,
                generation: generation)
        case .awaitingInput:
            phase = .awaitingInput
            pendingAcknowledgement = nil
        case .awaitingApproval:
            phase = .awaitingApproval
            pendingAcknowledgement = nil
        case .cancelled:
            phase = .idle
            lastCancelledGeneration = generation
            pendingAcknowledgement = nil
        case .failed:
            phase = .failed
            pendingAcknowledgement = nil
        case .exited:
            phase = .exited
            pendingAcknowledgement = nil
        }
    }

    private static func nextGeneration(after generation: UInt64) -> UInt64 {
        generation == .max ? .max : generation + 1
    }
}

enum GaiCompanionActivityAction: Codable, Hashable, Sendable {
    case event(GaiCompanionEvent)
    case acknowledge(GaiCompanionAcknowledgement)
    case expireProvisionalStart(generation: UInt64)
}

enum GaiCompanionReductionDisposition: String, Codable, Hashable, Sendable {
    case appliedEvent
    case acknowledged
    case duplicateEvent
    case ignoredInvalidEventID
    case ignoredWrongSurface
    case ignoredStaleEvent
    case ignoredStaleTurn
    case ignoredLowerAuthority
    case ignoredAfterExit
    case ignoredStaleAcknowledgement
    case ignoredStaleProvisionalExpiry
    case expiredProvisionalStart
}

struct GaiCompanionReduction: Equatable, Sendable {
    let state: GaiCompanionActivityState
    let disposition: GaiCompanionReductionDisposition
}

/// Pure, deterministic activity reducer designed to be owned by
/// `GaiCompanionManager` on its chosen isolation domain.
enum GaiCompanionActivityReducer {
    static let maximumRememberedEventIDs = 256

    static func reduce(
        _ state: GaiCompanionActivityState,
        action: GaiCompanionActivityAction
    ) -> GaiCompanionReduction {
        switch action {
        case .event(let event):
            reduce(state, event: event)
        case .acknowledge(let acknowledgement):
            acknowledge(state, with: acknowledgement)
        case .expireProvisionalStart(let generation):
            expireProvisionalStart(state, generation: generation)
        }
    }

    /// Mutating convenience for an observable manager which stores one state per
    /// surface. The pure `reduce` overload remains available to tests and stores.
    @discardableResult
    static func apply(
        _ action: GaiCompanionActivityAction,
        to state: inout GaiCompanionActivityState
    ) -> GaiCompanionReductionDisposition {
        let reduction = reduce(state, action: action)
        state = reduction.state
        return reduction.disposition
    }

    private static func reduce(
        _ state: GaiCompanionActivityState,
        event: GaiCompanionEvent
    ) -> GaiCompanionReduction {
        guard event.surfaceID == state.surfaceID else {
            return GaiCompanionReduction(state: state, disposition: .ignoredWrongSurface)
        }
        guard !event.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GaiCompanionReduction(state: state, disposition: .ignoredInvalidEventID)
        }
        guard !state.hasProcessed(eventID: event.eventID) else {
            return GaiCompanionReduction(state: state, disposition: .duplicateEvent)
        }
        // A proven PTY exit is an absorbing lifecycle boundary. Provider hooks
        // delivered afterwards belong to the dead process, irrespective of
        // their otherwise-valid authority or timestamp.
        if state.phase == .exited, event.kind != .exited {
            return GaiCompanionReduction(state: state, disposition: .ignoredAfterExit)
        }
        // SessionStart hooks are intentionally presentation-neutral. They may
        // identify a provider while its shell command is still in the local
        // provisional-start state, but a delayed/replayed SessionStart must
        // never erase active work, a failure, or an unseen completion.
        if event.kind == .ready,
           !Self.isPermittedSessionReadiness(event, in: state) {
            return GaiCompanionReduction(state: state, disposition: .ignoredStaleEvent)
        }
        // A process exit is less precise than the provider result which
        // immediately preceded it (for example Codex Stop followed by PTY
        // teardown). Preserve that visible result and its acknowledgement;
        // the manager still releases the dead terminal surface separately.
        if Self.isProvenProcessExit(event),
           state.phase == .completedUnseen || state.phase == .failed {
            return GaiCompanionReduction(state: state, disposition: .duplicateEvent)
        }
        // SessionEnd belongs to the enclosing CLI session, while Stop may be
        // correlated to a narrower turn. Once that turn has completed, the
        // broader session closure is presentation-idempotent: it must not clear
        // the unseen completion or manufacture another generation.
        if Self.isSessionClosureAfterTerminalResult(event, in: state) {
            return GaiCompanionReduction(state: state, disposition: .duplicateEvent)
        }
        if Self.isFromSupersededTurn(event, in: state) {
            return GaiCompanionReduction(state: state, disposition: .ignoredStaleTurn)
        }
        if event.source == .providerHook,
           event.kind != .started,
           state.generationAuthority == .providerHook,
           state.provider != event.provider {
            // Once a structured provider owns the surface, only an explicit
            // start may supersede it. An uncorrelated background hook from
            // another CLI must not steal or finish that provider's state,
            // including while it is idle between turns.
            return GaiCompanionReduction(state: state, disposition: .ignoredStaleTurn)
        }
        // OSC/bell notifications are an optional fallback for a command whose
        // generation GaiTerm actually observed. An unsolicited terminal title
        // or notification must never manufacture work, a wait state, or a
        // completion from idle.
        if event.source == .terminalFallback,
           !Self.isPermittedFallbackTransition(event, in: state) {
            return GaiCompanionReduction(state: state, disposition: .ignoredStaleEvent)
        }
        // Stop hooks may overlap during migration or be retried with a fresh
        // UUID. Completion and cancellation are terminal and idempotent within
        // one generation, including after a UI acknowledgement. In particular,
        // SessionEnd must not erase a Stop which already triggered the jump.
        if Self.isTerminalDuplicate(event, in: state),
           Self.belongsToCurrentTurn(event, in: state) {
            return GaiCompanionReduction(state: state, disposition: .duplicateEvent)
        }
        // A Stop can reach LaunchServices before the corresponding start or
        // waiting event. A cancellation has the same terminal semantics. Never
        // regress either terminal state with a late active event for the same
        // logical turn. A fresh local Enter is the one explicit exception: it
        // opens the next provisional generation.
        if Self.isActiveUpdate(event.kind),
           (state.lastCompletedGeneration == state.generation
               || state.lastCancelledGeneration == state.generation
               || state.phase == .failed),
           !Self.isFreshLocalStart(event, in: state),
           !Self.isSessionScopedProviderStart(event, in: state),
           Self.belongsToCurrentTurn(event, in: state) {
            return GaiCompanionReduction(state: state, disposition: .ignoredStaleTurn)
        }
        // Permission can arrive before UserPromptSubmit through separate hook
        // processes. Only `resumed` may leave a structured waiting state.
        if event.kind == .started,
           (state.phase == .awaitingInput || state.phase == .awaitingApproval),
           !Self.isProviderConfirmationOfProvisionalStart(event, in: state),
           Self.belongsToCurrentTurn(event, in: state) {
            return GaiCompanionReduction(state: state, disposition: .ignoredStaleEvent)
        }
        // Authority is monotonic within a generation. A UI acknowledgement
        // changes presentation only, so it must not let a delayed bell replace
        // a structured provider state. Explicit local transitions may open the
        // next generation or answer a provider wait.
        if let currentSource = state.generationAuthority,
           event.source.authority < currentSource.authority,
           !Self.isProvenProcessExit(event),
           !Self.isPermittedLocalTransition(event, in: state),
           !Self.isPermittedFallbackTransition(event, in: state) {
            return GaiCompanionReduction(state: state, disposition: .ignoredLowerAuthority)
        }

        var next = state
        next.remember(
            eventID: event.eventID,
            maximumCount: maximumRememberedEventIDs)

        if let lastTimestamp = state.lastEventTimestamp,
           event.timestamp < lastTimestamp {
            return GaiCompanionReduction(state: next, disposition: .ignoredStaleEvent)
        }
        if event.kind != .started,
           state.phase.belongsToActiveGeneration,
           let currentTurnID = state.turnID,
           let eventTurnID = event.turnID,
           currentTurnID != eventTurnID {
            return GaiCompanionReduction(state: next, disposition: .ignoredStaleTurn)
        }

        next.apply(event)
        return GaiCompanionReduction(state: next, disposition: .appliedEvent)
    }

    private static func isActiveUpdate(_ kind: GaiCompanionEventKind) -> Bool {
        switch kind {
        case .started, .resumed, .awaitingInput, .awaitingApproval:
            true
        case .ready, .stop, .cancelled, .failed, .exited:
            false
        }
    }

    private static func isProvenProcessExit(_ event: GaiCompanionEvent) -> Bool {
        event.kind == .exited && event.source == .processLifecycle
    }

    private static func isPermittedSessionReadiness(
        _ event: GaiCompanionEvent,
        in state: GaiCompanionActivityState
    ) -> Bool {
        guard event.source == .providerHook else { return false }
        if state.phase == .idle {
            return true
        }
        return state.phase == .working
            && state.provisionalStartGeneration == state.generation
            && state.generationAuthority == .userInput
    }

    /// Claude, Agy, and OpenCode expose a reusable session identifier rather
    /// than a distinct turn identifier. Their native prompt-start hook is the
    /// authoritative boundary which opens the next generation after the prior
    /// one completed or was cancelled. Codex has a real turn id, so a late
    /// start for the same Codex turn remains stale.
    private static func isSessionScopedProviderStart(
        _ event: GaiCompanionEvent,
        in state: GaiCompanionActivityState
    ) -> Bool {
        event.kind == .started
            && event.source == .providerHook
            && event.turnIdentifierScope == .session
            && state.provider == event.provider
            && !state.phase.belongsToActiveGeneration
            && state.phase != .exited
    }

    private static func isTerminalDuplicate(
        _ event: GaiCompanionEvent,
        in state: GaiCompanionActivityState
    ) -> Bool {
        switch event.kind {
        case .stop, .cancelled, .failed:
            // The first correlated terminal result wins. This prevents a late
            // Stop from turning a visible failure into a success, and prevents
            // an interruption reported later as an error from manufacturing a
            // false failure after the user already cancelled the turn.
            return state.lastCompletedGeneration == state.generation
                || state.lastCancelledGeneration == state.generation
                || state.phase == .failed
        case .ready, .started, .resumed, .awaitingInput, .awaitingApproval, .exited:
            return false
        }
    }

    private static func isSessionClosureAfterTerminalResult(
        _ event: GaiCompanionEvent,
        in state: GaiCompanionActivityState
    ) -> Bool {
        event.kind == .cancelled
            && event.source == .providerHook
            && event.turnIdentifierScope == .session
            && state.provider == event.provider
            && (state.lastCompletedGeneration == state.generation
                || state.lastCancelledGeneration == state.generation
                || state.phase == .failed)
    }

    private static func isFromSupersededTurn(
        _ event: GaiCompanionEvent,
        in state: GaiCompanionActivityState
    ) -> Bool {
        guard let eventTurnID = event.turnID,
              let supersededTurn = state.supersededTurn(
                provider: event.provider,
                turnID: eventTurnID) else {
            return false
        }

        switch event.turnIdentifierScope {
        case .turn:
            return true
        case .session:
            guard state.provisionalStartGeneration == state.generation else {
                // Outside the short local-provisional window, a superseded
                // reusable session is unambiguously stale whenever another
                // provider or session now owns this surface.
                return state.provider != event.provider
                    || state.turnID != event.turnID
            }
            // While a local start is provisional, lifecycle events bearing the
            // previous session belong to the superseded generation. Providers
            // with a start hook claim the reusable session through `started`.
            if event.kind == .started {
                return false
            }
            // Current Agy installs claim a prompt through PreInvocation
            // (`started`). Keep PostToolUse (`resumed`) as a positive claim for
            // an event already in flight from an older hook configuration. For
            // a tool-free prompt, Stop may claim the session only when the prior
            // generation was already terminal before the local sequence
            // boundary; otherwise the two Stops are unknowable and rejecting
            // the ambiguous one avoids a false completion.
            if event.provider == .agy {
                if event.kind == .resumed {
                    return false
                }
                if event.kind == .stop,
                   supersededTurn.wasTerminalBeforeSupersession {
                    return false
                }
            }
            return true
        }
    }

    private static func belongsToCurrentTurn(
        _ event: GaiCompanionEvent,
        in state: GaiCompanionActivityState
    ) -> Bool {
        guard state.provider == event.provider else { return false }
        guard let stateTurnID = state.turnID,
              let eventTurnID = event.turnID else {
            // Missing correlation is conservatively treated as the current
            // turn; a genuine new interactive turn is observed locally first.
            return true
        }
        return stateTurnID == eventTurnID
    }

    private static func isFreshLocalStart(
        _ event: GaiCompanionEvent,
        in state: GaiCompanionActivityState
    ) -> Bool {
        event.kind == .started
            && event.source == .userInput
            && state.phase != .awaitingInput
            && state.phase != .awaitingApproval
            && state.phase != .exited
    }

    private static func isProviderConfirmationOfProvisionalStart(
        _ event: GaiCompanionEvent,
        in state: GaiCompanionActivityState
    ) -> Bool {
        event.kind == .started
            && event.source == .providerHook
            && state.provisionalStartGeneration == state.generation
            && state.provider == event.provider
            && event.turnID != nil
            && (state.turnID == nil || state.turnID == event.turnID)
    }

    private static func isPermittedLocalTransition(
        _ event: GaiCompanionEvent,
        in state: GaiCompanionActivityState
    ) -> Bool {
        if isFreshLocalStart(event, in: state) {
            return true
        }
        guard event.source == .userInput,
              belongsToCurrentTurn(event, in: state) else {
            return false
        }
        if event.kind == .resumed {
            return state.phase == .working
                || state.phase == .awaitingInput
                || state.phase == .awaitingApproval
        }
        return event.kind == .cancelled && state.phase.belongsToActiveGeneration
    }

    private static func isPermittedFallbackTransition(
        _ event: GaiCompanionEvent,
        in state: GaiCompanionActivityState
    ) -> Bool {
        guard event.source == .terminalFallback,
              state.generationAuthority == .userInput,
              state.phase.belongsToActiveGeneration else {
            return false
        }
        switch event.kind {
        case .stop, .awaitingInput, .awaitingApproval, .cancelled, .failed:
            return true
        case .ready, .started, .resumed, .exited:
            return false
        }
    }

    private static func acknowledge(
        _ state: GaiCompanionActivityState,
        with acknowledgement: GaiCompanionAcknowledgement
    ) -> GaiCompanionReduction {
        guard acknowledgement.surfaceID == state.surfaceID else {
            return GaiCompanionReduction(state: state, disposition: .ignoredWrongSurface)
        }
        guard acknowledgement == state.pendingAcknowledgement else {
            return GaiCompanionReduction(
                state: state,
                disposition: .ignoredStaleAcknowledgement)
        }

        var next = state
        next.acknowledge(acknowledgement)
        return GaiCompanionReduction(state: next, disposition: .acknowledged)
    }

    private static func expireProvisionalStart(
        _ state: GaiCompanionActivityState,
        generation: UInt64
    ) -> GaiCompanionReduction {
        var next = state
        guard next.expireProvisionalStart(generation: generation) else {
            return GaiCompanionReduction(
                state: state,
                disposition: .ignoredStaleProvisionalExpiry)
        }
        return GaiCompanionReduction(
            state: next,
            disposition: .expiredProvisionalStart)
    }
}
#endif
