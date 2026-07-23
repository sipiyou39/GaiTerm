#if DEBUG
import Foundation
import Testing
@testable import Ghostty

struct GaiCompanionActivityReducerTests {
    private let surfaceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let otherSurfaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func stopFromIdleCreatesUnseenCompletion() {
        let event = makeEvent(id: "stop-1", kind: .stop, message: "Turn complete")
        let reduction = GaiCompanionActivityReducer.reduce(
            GaiCompanionActivityState(surfaceID: surfaceID),
            action: .event(event))

        #expect(reduction.disposition == .appliedEvent)
        #expect(reduction.state.phase == .completedUnseen)
        #expect(reduction.state.generation == 1)
        #expect(reduction.state.message == "Turn complete")
        #expect(reduction.state.pendingAcknowledgement?.eventID == event.eventID)
        #expect(reduction.state.pendingAcknowledgement?.generation == 1)
    }

    @Test func startedAndStopShareOneGeneration() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        let started = makeEvent(id: "start-1", turnID: "turn-1", kind: .started)
        let stopped = makeEvent(
            id: "stop-1",
            turnID: "turn-1",
            kind: .stop,
            offset: 1)

        #expect(GaiCompanionActivityReducer.apply(.event(started), to: &state) == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 1)
        #expect(GaiCompanionActivityReducer.apply(.event(stopped), to: &state) == .appliedEvent)
        #expect(state.phase == .completedUnseen)
        #expect(state.generation == 1)
    }

    @Test func sessionScopedProviderStartOpensNextGenerationWithoutLocalGuess() throws {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-ready",
                provider: .claude,
                turnID: "session:session-1",
                kind: .ready)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-start-1",
                provider: .claude,
                turnID: "session:session-1",
                kind: .started,
                offset: 1)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-stop-1",
                provider: .claude,
                turnID: "session:session-1",
                kind: .stop,
                offset: 2)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .acknowledge(try #require(state.pendingAcknowledgement)),
            to: &state)

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-start-2",
                provider: .claude,
                turnID: "session:session-1",
                kind: .started,
                offset: 3)),
            to: &state)

        #expect(disposition == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 2)
        #expect(state.turnID == "session:session-1")
    }

    @Test func turnScopedLateStartAfterStopRemainsStale() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "codex-start",
                provider: .codex,
                turnID: "turn:turn-1",
                kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "codex-stop",
                provider: .codex,
                turnID: "turn:turn-1",
                kind: .stop,
                offset: 1)),
            to: &state)
        let completed = state

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "codex-late-start",
                provider: .codex,
                turnID: "turn:turn-1",
                kind: .started,
                offset: 2)),
            to: &state)

        #expect(disposition == .ignoredStaleTurn)
        #expect(state == completed)
    }

    @Test func delayedReadyCannotEraseCompletionFailureOrActiveWork() {
        var completed = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start", turnID: "turn:turn-1", kind: .started)),
            to: &completed)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "stop",
                turnID: "turn:turn-1",
                kind: .stop,
                offset: 1)),
            to: &completed)

        var failed = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "failed", kind: .failed)),
            to: &failed)

        var working = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "working", turnID: "turn:turn-2", kind: .started)),
            to: &working)

        for (index, original) in [completed, failed, working].enumerated() {
            var state = original
            let disposition = GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "late-ready-\(index)",
                    turnID: "session:session-1",
                    kind: .ready,
                    offset: 5)),
                to: &state)
            #expect(disposition == .ignoredStaleEvent)
            #expect(state == original)
        }
    }

    @Test func duplicateEventIDIsIdempotent() {
        let initial = GaiCompanionActivityState(surfaceID: surfaceID)
        let event = makeEvent(id: "same-event", turnID: "turn-1", kind: .started)
        let first = GaiCompanionActivityReducer.reduce(initial, action: .event(event))
        let duplicate = GaiCompanionActivityReducer.reduce(first.state, action: .event(event))

        #expect(duplicate.disposition == .duplicateEvent)
        #expect(duplicate.state == first.state)
    }

    @Test func overlappingLegacyAndTypedStopsAreSemanticallyIdempotent() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        let typed = makeEvent(
            id: "typed-stop",
            turnID: "turn-1",
            kind: .stop)
        let legacy = makeEvent(
            id: "legacy-stop",
            kind: .stop,
            offset: 0.1)

        #expect(GaiCompanionActivityReducer.apply(.event(typed), to: &state) == .appliedEvent)
        let completedState = state
        #expect(GaiCompanionActivityReducer.apply(.event(legacy), to: &state) == .duplicateEvent)
        #expect(state == completedState)
    }

    @Test func duplicateStopRemainsSuppressedAfterAcknowledgement() throws {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "stop-1", turnID: "turn-1", kind: .stop)),
            to: &state)
        let acknowledgement = try #require(state.pendingAcknowledgement)
        GaiCompanionActivityReducer.apply(.acknowledge(acknowledgement), to: &state)
        let acknowledgedState = state

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "stop-retry",
                turnID: "turn-1",
                kind: .stop,
                offset: 1)),
            to: &state)

        #expect(disposition == .duplicateEvent)
        #expect(state == acknowledgedState)
        #expect(state.phase == .idle)
        #expect(state.generation == 1)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "next-local-start",
                    kind: .started,
                    source: .userInput,
                    offset: 2)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 2)
    }

    @Test func stopBeforeStartCannotRegressBackToWorking() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "stop", turnID: "turn-1", kind: .stop)),
            to: &state)
        let completedState = state

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "late-start",
                turnID: "turn-1",
                kind: .started,
                offset: 1)),
            to: &state)

        #expect(disposition == .ignoredStaleTurn)
        #expect(state == completedState)
        #expect(state.phase == .completedUnseen)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "late-wait",
                    turnID: "turn-1",
                    kind: .awaitingInput,
                    offset: 2)),
                to: &state)
                == .ignoredStaleTurn)
        #expect(state == completedState)
    }

    @Test func waitingBeforeLateStartStaysWaiting() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "approval",
                turnID: "turn-1",
                kind: .awaitingApproval)),
            to: &state)
        let waitingState = state

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "late-start",
                turnID: "turn-1",
                kind: .started,
                offset: 1)),
            to: &state)

        #expect(disposition == .ignoredStaleEvent)
        #expect(state == waitingState)
        #expect(state.phase == .awaitingApproval)
    }

    @Test func typedStartEnrichesLocalProvisionalStartWithoutNewGeneration() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "local-start",
                kind: .started,
                source: .userInput)),
            to: &state)
        #expect(state.generation == 1)
        #expect(state.turnID == nil)
        #expect(state.source == .userInput)

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "typed-start",
                turnID: "turn-1",
                kind: .started,
                source: .providerHook,
                offset: 0.1)),
            to: &state)

        #expect(disposition == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 1)
        #expect(state.turnID == "turn-1")
        #expect(state.source == .providerHook)
    }

    @Test func fallbackCannotOverrideTypedStateButMayRefineLocalWork() {
        var typedState = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "typed-start",
                turnID: "turn-1",
                kind: .started,
                source: .providerHook)),
            to: &typedState)
        let authoritativeState = typedState

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "fallback-wait",
                    provider: .terminal,
                    kind: .awaitingInput,
                    source: .terminalFallback,
                    offset: 1)),
                to: &typedState)
                == .ignoredStaleEvent)
        #expect(typedState == authoritativeState)

        var localState = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "local-start",
                provider: .agy,
                kind: .started,
                source: .userInput)),
            to: &localState)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "fallback-bell",
                    provider: .terminal,
                    kind: .awaitingInput,
                    source: .terminalFallback,
                    offset: 1)),
                to: &localState)
                == .appliedEvent)
        #expect(localState.phase == .awaitingInput)
        #expect(localState.generation == 1)
        #expect(localState.provider == .agy)
        #expect(localState.source == .terminalFallback)
        #expect(localState.generationAuthority == .userInput)
    }

    @Test func unsolicitedTerminalFallbackCannotCreateActivityFromIdle() {
        for (index, kind) in [
            GaiCompanionEventKind.stop,
            .awaitingInput,
            .failed,
        ].enumerated() {
            var state = GaiCompanionActivityState(surfaceID: surfaceID)
            let disposition = GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "unsolicited-fallback-\(index)",
                    provider: .terminal,
                    kind: kind,
                    source: .terminalFallback)),
                to: &state)

            #expect(disposition == .ignoredStaleEvent)
            #expect(state.phase == .idle)
            #expect(state.generation == 0)
        }

        var observedWork = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "observed-input",
                provider: .terminal,
                kind: .started,
                source: .userInput)),
            to: &observedWork)
        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "correlated-fallback",
                    provider: .terminal,
                    kind: .stop,
                    source: .terminalFallback,
                    offset: 1)),
                to: &observedWork)
                == .appliedEvent)
        #expect(observedWork.phase == .completedUnseen)
    }

    @Test func newLocalGenerationResetsOldProviderAuthorityForFallbacks() throws {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start-1", turnID: "turn-1", kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "stop-1",
                turnID: "turn-1",
                kind: .stop,
                offset: 1)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .acknowledge(try #require(state.pendingAcknowledgement)),
            to: &state)

        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "local-start-2",
                provider: .terminal,
                kind: .started,
                source: .userInput,
                offset: 2)),
            to: &state)
        #expect(state.generation == 2)
        #expect(state.generationAuthority == .userInput)

        let fallback = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "fallback-wait",
                provider: .terminal,
                kind: .awaitingInput,
                source: .terminalFallback,
                offset: 3)),
            to: &state)

        #expect(fallback == .appliedEvent)
        #expect(state.phase == .awaitingInput)
        #expect(state.generation == 2)
        #expect(state.provider == .terminal)
        #expect(state.generationAuthority == .userInput)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "fallback-stop",
                    provider: .terminal,
                    kind: .stop,
                    source: .terminalFallback,
                    offset: 4)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .completedUnseen)
        #expect(state.generation == 2)
        #expect(state.generationAuthority == .userInput)
    }

    @Test func explicitTurnPrefixOverridesSessionScopedProviderFallback() throws {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "agy-start-1",
                provider: .agy,
                turnID: "turn:prompt-1",
                kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "agy-stop-1",
                provider: .agy,
                turnID: "turn:prompt-1",
                kind: .stop,
                offset: 1)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .acknowledge(try #require(state.pendingAcknowledgement)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "agy-local-start-2",
                provider: .agy,
                kind: .started,
                source: .userInput,
                offset: 2)),
            to: &state)

        let provisionalState = state
        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "agy-late-stop-1",
                    provider: .agy,
                    turnID: "turn:prompt-1",
                    kind: .stop,
                    offset: 3)),
                to: &state)
                == .ignoredStaleTurn)
        #expect(state == provisionalState)
    }

    @Test func cancelledTurnSuppressesItsLateStop() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start", turnID: "turn-1", kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "cancel",
                turnID: "turn-1",
                kind: .cancelled,
                offset: 1)),
            to: &state)
        let cancelledState = state

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "late-stop",
                turnID: "turn-1",
                kind: .stop,
                offset: 2)),
            to: &state)

        #expect(disposition == .duplicateEvent)
        #expect(state == cancelledState)
        #expect(state.phase == .idle)
        #expect(state.pendingAcknowledgement == nil)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "late-resume",
                    turnID: "turn-1",
                    kind: .resumed,
                    offset: 3)),
                to: &state)
                == .ignoredStaleTurn)
        #expect(state == cancelledState)
    }

    @Test func localCancellationEndsAuthoritativeWorkAndAllowsNextPrompt() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "typed-start",
                turnID: "turn-1",
                kind: .started,
                source: .providerHook)),
            to: &state)

        let cancellation = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "local-cancel",
                kind: .cancelled,
                source: .userInput,
                offset: 1)),
            to: &state)

        #expect(cancellation == .appliedEvent)
        #expect(state.phase == .idle)
        #expect(state.generation == 1)
        #expect(state.turnID == "turn-1")
        #expect(state.source == .userInput)

        let nextPrompt = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "next-local-start",
                kind: .started,
                source: .userInput,
                offset: 2)),
            to: &state)

        #expect(nextPrompt == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 2)
        #expect(state.turnID == nil)
    }

    @Test func sessionEndPreservesCompletionButCancelsActiveWork() {
        var completed = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start", turnID: "turn-1", kind: .started)),
            to: &completed)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "stop", turnID: "turn-1", kind: .stop, offset: 1)),
            to: &completed)
        let unseenCompletion = completed

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "session-end-after-stop",
                    turnID: "turn-1",
                    kind: .cancelled,
                    offset: 2)),
                to: &completed)
                == .duplicateEvent)
        #expect(completed == unseenCompletion)
        #expect(completed.phase == .completedUnseen)

        var working = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "working", turnID: "turn-2", kind: .started)),
            to: &working)
        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "session-end-working",
                    turnID: "turn-2",
                    kind: .cancelled,
                    offset: 1)),
                to: &working)
                == .appliedEvent)
        #expect(working.phase == .idle)

        var waiting = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "waiting",
                turnID: "turn-3",
                kind: .awaitingInput)),
            to: &waiting)
        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "session-end-waiting",
                    turnID: "turn-3",
                    kind: .cancelled,
                    offset: 1)),
                to: &waiting)
                == .appliedEvent)
        #expect(waiting.phase == .idle)
    }

    @Test func sessionEndPreservesNarrowerTurnCompletion() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "turn-start",
                turnID: "turn:turn-1",
                kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "turn-stop",
                turnID: "turn:turn-1",
                kind: .stop,
                offset: 1)),
            to: &state)
        let unseenCompletion = state

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "session-end",
                turnID: "session:session-1",
                kind: .cancelled,
                offset: 2)),
            to: &state)

        #expect(disposition == .duplicateEvent)
        #expect(state == unseenCompletion)
        #expect(state.phase == .completedUnseen)
        #expect(state.generation == 1)
        #expect(state.pendingAcknowledgement?.eventID == "turn-stop")
    }

    @Test func sessionEndPreservesFailureAndNextPromptStillStarts() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-start-1",
                provider: .claude,
                turnID: "session:session-1",
                kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-failure-1",
                provider: .claude,
                turnID: "session:session-1",
                kind: .failed,
                offset: 1)),
            to: &state)
        let visibleFailure = state

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "claude-session-end-1",
                    provider: .claude,
                    turnID: "session:session-1",
                    kind: .cancelled,
                    offset: 2)),
                to: &state)
                == .duplicateEvent)
        #expect(state == visibleFailure)
        #expect(state.phase == .failed)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "claude-start-2",
                    provider: .claude,
                    turnID: "session:session-1",
                    kind: .started,
                    offset: 3)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == visibleFailure.generation + 1)
    }

    @Test func supersededSessionCannotOverwriteANewProvider() throws {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-start",
                provider: .claude,
                turnID: "session:claude-session",
                kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-stop",
                provider: .claude,
                turnID: "session:claude-session",
                kind: .stop,
                offset: 1)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .acknowledge(try #require(state.pendingAcknowledgement)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "launch-opencode",
                provider: .terminal,
                kind: .started,
                source: .userInput,
                offset: 2)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "opencode-ready",
                provider: .opencode,
                turnID: "session:opencode-session",
                kind: .ready,
                offset: 3)),
            to: &state)
        let openCodeState = state

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "late-claude-stop",
                    provider: .claude,
                    turnID: "session:claude-session",
                    kind: .stop,
                    offset: 4)),
                to: &state)
                == .ignoredStaleTurn)
        #expect(state == openCodeState)
        #expect(state.provider == .opencode)
        #expect(state.phase == .idle)
    }

    @Test func firstCorrelatedTerminalResultWins() {
        var failed = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start-failed", turnID: "turn-1", kind: .started)),
            to: &failed)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "failure",
                turnID: "turn-1",
                kind: .failed,
                offset: 1)),
            to: &failed)
        let visibleFailure = failed
        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "late-stop",
                    turnID: "turn-1",
                    kind: .stop,
                    offset: 2)),
                to: &failed)
                == .duplicateEvent)
        #expect(failed == visibleFailure)

        var cancelled = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start-cancelled", turnID: "turn-2", kind: .started)),
            to: &cancelled)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "cancelled",
                turnID: "turn-2",
                kind: .cancelled,
                source: .userInput,
                offset: 1)),
            to: &cancelled)
        let settledCancellation = cancelled
        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "late-failure",
                    turnID: "turn-2",
                    kind: .failed,
                    offset: 2)),
                to: &cancelled)
                == .duplicateEvent)
        #expect(cancelled == settledCancellation)
        #expect(cancelled.phase == .idle)
    }

    @Test func lateActiveUpdatesCannotEraseFailure() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-start",
                provider: .claude,
                turnID: "session:session-1",
                kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-failure",
                provider: .claude,
                turnID: "session:session-1",
                kind: .failed,
                offset: 1)),
            to: &state)
        let visibleFailure = state

        for (index, kind) in [
            GaiCompanionEventKind.resumed,
            .awaitingInput,
            .awaitingApproval,
        ].enumerated() {
            #expect(
                GaiCompanionActivityReducer.apply(
                    .event(makeEvent(
                        id: "late-active-\(index)",
                        provider: .claude,
                        turnID: "session:session-1",
                        kind: kind,
                        offset: TimeInterval(index + 2))),
                    to: &state)
                    == .ignoredStaleTurn)
            #expect(state == visibleFailure)
        }

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "claude-next-start",
                    provider: .claude,
                    turnID: "session:session-1",
                    kind: .started,
                    offset: 5)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == visibleFailure.generation + 1)
    }

    @Test func uncorrelatedProviderCannotClobberActiveProvider() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "codex-start",
                provider: .codex,
                turnID: "turn:turn-1",
                kind: .started)),
            to: &state)
        let codexState = state

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "uncorrelated-claude-stop",
                    provider: .claude,
                    kind: .stop,
                    offset: 1)),
                to: &state)
                == .ignoredStaleTurn)
        #expect(state == codexState)
    }

    @Test func resumedContinuesWaitingGeneration() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start", turnID: "turn-1", kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "approval",
                turnID: "turn-1",
                kind: .awaitingApproval,
                offset: 1)),
            to: &state)

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "resume",
                turnID: "turn-1",
                kind: .resumed,
                offset: 2)),
            to: &state)

        #expect(disposition == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 1)
        #expect(state.turnID == "turn-1")
    }

    @Test func localResumeMayAnswerAuthoritativeWait() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start", turnID: "turn-1", kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "approval",
                turnID: "turn-1",
                kind: .awaitingApproval,
                offset: 1)),
            to: &state)
        #expect(state.source == .providerHook)

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "local-resume",
                kind: .resumed,
                source: .userInput,
                offset: 2)),
            to: &state)

        #expect(disposition == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 1)
        #expect(state.turnID == "turn-1")
        #expect(state.source == .userInput)
    }

    @Test func delayedStopForPreviousTurnCannotFinishNewGeneration() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start-1", turnID: "turn-1", kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start-2", turnID: "turn-2", kind: .started, offset: 1)),
            to: &state)

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "late-stop", turnID: "turn-1", kind: .stop, offset: 2)),
            to: &state)

        #expect(disposition == .ignoredStaleTurn)
        #expect(state.phase == .working)
        #expect(state.generation == 2)
        #expect(state.turnID == "turn-2")
    }

    @Test func provisionalStartRejectsLateEventsFromSupersededTurn() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start-1", turnID: "turn-1", kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "local-start-2",
                kind: .started,
                source: .userInput,
                offset: 1)),
            to: &state)
        let provisionalState = state

        let lateEvents = [
            makeEvent(id: "late-stop-1", turnID: "turn-1", kind: .stop, offset: 2),
            makeEvent(
                id: "late-permission-1",
                turnID: "turn-1",
                kind: .awaitingApproval,
                offset: 3),
            makeEvent(
                id: "late-post-tool-1",
                turnID: "turn-1",
                kind: .resumed,
                offset: 4),
        ]
        for event in lateEvents {
            #expect(GaiCompanionActivityReducer.apply(.event(event), to: &state)
                == .ignoredStaleTurn)
            #expect(state == provisionalState)
        }

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "typed-start-2",
                    turnID: "turn-2",
                    kind: .started,
                    offset: 5)),
                to: &state)
                == .appliedEvent)
        #expect(state.generation == 2)
        #expect(state.turnID == "turn-2")
        #expect(state.source == .providerHook)
    }

    @Test func codexQueueInputKeepsActiveTurnCorrelation() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "start-1",
                turnID: "turn:turn-1",
                kind: .started)),
            to: &state)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "local-enter-2",
                    kind: .resumed,
                    source: .userInput,
                    offset: 1)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 1)
        #expect(state.turnID == "turn:turn-1")
        #expect(state.provisionalStartGeneration == nil)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "queued-prompt-hook",
                    turnID: "turn:turn-1",
                    kind: .started,
                    offset: 2)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 1)
        #expect(state.turnID == "turn:turn-1")

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "stop-1",
                    turnID: "turn:turn-1",
                    kind: .stop,
                    offset: 3)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .completedUnseen)
        #expect(state.generation == 1)
    }

    @Test func opencodeInputWhileBusyKeepsReusableSessionCorrelation() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "busy-1",
                provider: .opencode,
                turnID: "session:session-1",
                kind: .started)),
            to: &state)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "local-enter",
                    provider: .opencode,
                    kind: .resumed,
                    source: .userInput,
                    offset: 1)),
                to: &state)
                == .appliedEvent)
        #expect(state.generation == 1)
        #expect(state.turnID == "session:session-1")

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "busy-2",
                    provider: .opencode,
                    turnID: "session:session-1",
                    kind: .resumed,
                    offset: 2)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 1)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "idle-1",
                    provider: .opencode,
                    turnID: "session:session-1",
                    kind: .stop,
                    offset: 3)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .completedUnseen)
        #expect(state.generation == 1)
    }

    @Test func genericTerminalInputStillCreatesSequenceBoundaryWhileWorking() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "first-input",
                provider: .terminal,
                kind: .started,
                source: .userInput)),
            to: &state)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "second-input",
                    provider: .terminal,
                    kind: .resumed,
                    source: .userInput,
                    offset: 1)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .working)
        #expect(state.generation == 2)
        #expect(state.provisionalStartGeneration == 2)
    }

    @Test func sessionScopedProviderMayReuseIdentifierAfterLocalSequenceBoundary() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "claude-start-1",
                provider: .claude,
                turnID: "session-1",
                kind: .started)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "local-start-2",
                provider: .claude,
                kind: .started,
                source: .userInput,
                offset: 1)),
            to: &state)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "late-stop-1",
                    provider: .claude,
                    turnID: "session-1",
                    kind: .stop,
                    offset: 2)),
                to: &state)
                == .ignoredStaleTurn)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "claude-start-2",
                    provider: .claude,
                    turnID: "session-1",
                    kind: .started,
                    offset: 3)),
                to: &state)
                == .appliedEvent)
        #expect(state.generation == 2)
        #expect(state.turnID == "session-1")

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "claude-stop-2",
                    provider: .claude,
                    turnID: "session-1",
                    kind: .stop,
                    offset: 4)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .completedUnseen)
        #expect(state.generation == 2)
    }

    @Test func agyMayClaimReusedSessionWithProgressOrToolFreeStop() throws {
        var toolUsing = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "agy-start-1",
                provider: .agy,
                turnID: "session-1",
                kind: .started)),
            to: &toolUsing)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "agy-local-start-2",
                provider: .agy,
                kind: .started,
                source: .userInput,
                offset: 1)),
            to: &toolUsing)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "agy-late-stop-1",
                    provider: .agy,
                    turnID: "session-1",
                    kind: .stop,
                    offset: 2)),
                to: &toolUsing)
                == .ignoredStaleTurn)
        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "agy-progress-2",
                    provider: .agy,
                    turnID: "session-1",
                    kind: .resumed,
                    offset: 3)),
                to: &toolUsing)
                == .appliedEvent)
        #expect(toolUsing.generation == 2)
        #expect(toolUsing.turnID == "session-1")
        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "agy-stop-2",
                    provider: .agy,
                    turnID: "session-1",
                    kind: .stop,
                    offset: 4)),
                to: &toolUsing)
                == .appliedEvent)

        var toolFree = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "agy-first-start",
                provider: .agy,
                turnID: "session-2",
                kind: .started)),
            to: &toolFree)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "agy-first-stop",
                provider: .agy,
                turnID: "session-2",
                kind: .stop,
                offset: 1)),
            to: &toolFree)
        GaiCompanionActivityReducer.apply(
            .acknowledge(try #require(toolFree.pendingAcknowledgement)),
            to: &toolFree)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "agy-second-local-start",
                provider: .agy,
                kind: .started,
                source: .userInput,
                offset: 2)),
            to: &toolFree)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "agy-tool-free-stop",
                    provider: .agy,
                    turnID: "session-2",
                    kind: .stop,
                    offset: 3)),
                to: &toolFree)
                == .appliedEvent)
        #expect(toolFree.phase == .completedUnseen)
        #expect(toolFree.generation == 2)
    }

    @Test func olderTimestampIsRejected() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start", turnID: "turn-1", kind: .started, offset: 2)),
            to: &state)

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "old-stop", turnID: "turn-1", kind: .stop, offset: 1)),
            to: &state)

        #expect(disposition == .ignoredStaleEvent)
        #expect(state.phase == .working)
    }

    @Test func exactAcknowledgementReturnsCompletionToIdle() throws {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "stop", turnID: "turn-1", kind: .stop)),
            to: &state)
        let acknowledgement = try #require(state.pendingAcknowledgement)

        let disposition = GaiCompanionActivityReducer.apply(
            .acknowledge(acknowledgement),
            to: &state)

        #expect(disposition == .acknowledged)
        #expect(state.phase == .idle)
        #expect(state.pendingAcknowledgement == nil)
        #expect(
            GaiCompanionActivityReducer.apply(.acknowledge(acknowledgement), to: &state)
                == .ignoredStaleAcknowledgement)
    }

    @Test func staleAcknowledgementCannotClearNewerCompletion() throws {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "stop-1", turnID: "turn-1", kind: .stop)),
            to: &state)
        let oldAcknowledgement = try #require(state.pendingAcknowledgement)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "start-2", turnID: "turn-2", kind: .started, offset: 1)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "stop-2", turnID: "turn-2", kind: .stop, offset: 2)),
            to: &state)
        let currentAcknowledgement = try #require(state.pendingAcknowledgement)

        let disposition = GaiCompanionActivityReducer.apply(
            .acknowledge(oldAcknowledgement),
            to: &state)

        #expect(disposition == .ignoredStaleAcknowledgement)
        #expect(state.phase == .completedUnseen)
        #expect(state.generation == 2)
        #expect(state.pendingAcknowledgement == currentAcknowledgement)
    }

    @Test func typedWaitFailureAndExitEventsMapToTheirPhases() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)

        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "input", kind: .awaitingInput)),
            to: &state)
        #expect(state.phase == .awaitingInput)

        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "approval", kind: .awaitingApproval, offset: 1)),
            to: &state)
        #expect(state.phase == .awaitingApproval)

        GaiCompanionActivityReducer.apply(
            .event(makeEvent(id: "failure", kind: .failed, offset: 2)),
            to: &state)
        #expect(state.phase == .failed)

        var exited = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "exit",
                provider: .terminal,
                kind: .exited,
                source: .processLifecycle,
                offset: 3)),
            to: &exited)
        #expect(exited.phase == .exited)
        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(id: "too-late", kind: .started, offset: 4)),
                to: &exited)
                == .ignoredAfterExit)
        #expect(exited.phase == .exited)
    }

    @Test func provenProcessExitOverridesProviderHookAuthority() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "typed-start",
                turnID: "turn-1",
                kind: .started,
                source: .providerHook)),
            to: &state)
        #expect(state.generationAuthority == .providerHook)

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "pty-exit",
                turnID: nil,
                kind: .exited,
                source: .processLifecycle,
                offset: 1)),
            to: &state)

        #expect(disposition == .appliedEvent)
        #expect(state.phase == .exited)
        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "late-provider-update",
                    turnID: "turn-1",
                    kind: .resumed,
                    source: .providerHook,
                    offset: 2)),
                to: &state)
                == .ignoredAfterExit)
        #expect(state.phase == .exited)
    }

    @Test func provenProcessExitTransitionsIdleStateToExited() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "pty-exit",
                kind: .exited,
                source: .processLifecycle)),
            to: &state)

        #expect(disposition == .appliedEvent)
        #expect(state.phase == .exited)
        #expect(state.generation == 0)
    }

    @Test func provenProcessExitPreservesUnseenProviderCompletion() throws {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "typed-start",
                turnID: "turn-1",
                kind: .started,
                source: .providerHook)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "typed-stop",
                turnID: "turn-1",
                kind: .stop,
                source: .providerHook,
                offset: 1)),
            to: &state)
        _ = try #require(state.pendingAcknowledgement)
        #expect(state.phase == .completedUnseen)
        #expect(state.generationAuthority == .providerHook)
        let providerResult = state

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "pty-exit",
                kind: .exited,
                source: .processLifecycle,
                offset: 2)),
            to: &state)

        #expect(disposition == .duplicateEvent)
        #expect(state == providerResult)
        #expect(state.phase == .completedUnseen)
        #expect(state.pendingAcknowledgement?.eventID == "typed-stop")
    }

    @Test func provenProcessExitPreservesProviderFailure() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "typed-start",
                turnID: "turn-1",
                kind: .started,
                source: .providerHook)),
            to: &state)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "typed-failure",
                turnID: "turn-1",
                kind: .failed,
                source: .providerHook,
                offset: 1)),
            to: &state)
        let providerFailure = state

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "pty-exit",
                kind: .exited,
                source: .processLifecycle,
                offset: 2)),
            to: &state)

        #expect(disposition == .duplicateEvent)
        #expect(state == providerFailure)
        #expect(state.phase == .failed)
    }

    @Test func unprovenExitCannotBypassProviderAuthority() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "typed-start",
                turnID: "turn-1",
                kind: .started,
                source: .providerHook)),
            to: &state)
        let activeProviderState = state

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "unproven-exit",
                    kind: .exited,
                    source: .userInput,
                    offset: 1)),
                to: &state)
                == .ignoredLowerAuthority)
        #expect(state == activeProviderState)
        #expect(state.phase == .working)
    }

    @Test func sessionReadySettlesProvisionalCLIStartupWithoutFakeCompletion() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "shell-launch",
                provider: .terminal,
                kind: .started,
                source: .userInput)),
            to: &state)
        let launchGeneration = state.generation
        #expect(state.phase == .working)

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "codex-ready",
                provider: .codex,
                turnID: "session:session-1",
                kind: .ready,
                source: .providerHook,
                offset: 1)),
            to: &state)

        #expect(disposition == .appliedEvent)
        #expect(state.phase == .idle)
        #expect(state.provider == .codex)
        #expect(state.turnID == "session:session-1")
        #expect(state.generation == launchGeneration)
        #expect(state.pendingAcknowledgement == nil)
    }

    @Test func provisionalInputExpiresWithoutSuppressingALateRealStop() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "optimistic-input",
                provider: .codex,
                kind: .started,
                source: .userInput)),
            to: &state)
        let provisionalGeneration = state.generation
        #expect(state.phase == .working)
        #expect(state.provisionalStartGeneration == provisionalGeneration)

        #expect(
            GaiCompanionActivityReducer.apply(
                .expireProvisionalStart(generation: provisionalGeneration),
                to: &state)
                == .expiredProvisionalStart)
        #expect(state.phase == .idle)
        #expect(state.lastCancelledGeneration == nil)
        #expect(state.pendingAcknowledgement == nil)

        #expect(
            GaiCompanionActivityReducer.apply(
                .event(makeEvent(
                    id: "late-real-stop",
                    provider: .codex,
                    turnID: "turn:turn-1",
                    kind: .stop,
                    offset: 1)),
                to: &state)
                == .appliedEvent)
        #expect(state.phase == .completedUnseen)
        #expect(state.pendingAcknowledgement?.eventID == "late-real-stop")
    }

    @Test func staleProvisionalExpiryCannotAffectANewerGeneration() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "input-1",
                provider: .terminal,
                kind: .started,
                source: .userInput)),
            to: &state)
        let oldGeneration = state.generation
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "input-2",
                provider: .terminal,
                kind: .resumed,
                source: .userInput,
                offset: 1)),
            to: &state)
        let current = state

        #expect(
            GaiCompanionActivityReducer.apply(
                .expireProvisionalStart(generation: oldGeneration),
                to: &state)
                == .ignoredStaleProvisionalExpiry)
        #expect(state == current)
        #expect(state.phase == .working)
    }

    @Test func provenAgentProcessExitClosesActiveTurnWithoutJumping() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "typed-start",
                provider: .codex,
                turnID: "turn:turn-1",
                kind: .started,
                source: .providerHook)),
            to: &state)

        let disposition = GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "cli-process-finished",
                provider: .codex,
                kind: .cancelled,
                source: .processLifecycle,
                offset: 1)),
            to: &state)

        #expect(disposition == .appliedEvent)
        #expect(state.phase == .idle)
        #expect(state.pendingAcknowledgement == nil)
        #expect(state.source == .processLifecycle)
    }

    @Test func eventForAnotherSurfaceIsIgnoredWithoutPollutingDeduplication() {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        let event = GaiCompanionEvent(
            surfaceID: otherSurfaceID,
            provider: .codex,
            eventID: "foreign",
            kind: .started,
            timestamp: baseDate)

        let disposition = GaiCompanionActivityReducer.apply(.event(event), to: &state)

        #expect(disposition == .ignoredWrongSurface)
        #expect(state.phase == .idle)
        #expect(!state.hasProcessed(eventID: event.eventID))
    }

    @Test func activityStateAndEventRoundTripThroughCodable() throws {
        var state = GaiCompanionActivityState(surfaceID: surfaceID)
        GaiCompanionActivityReducer.apply(
            .event(makeEvent(
                id: "observed-input",
                provider: .terminal,
                kind: .started,
                source: .userInput)),
            to: &state)
        let event = makeEvent(
            id: "fallback-wait",
            provider: .terminal,
            kind: .awaitingInput,
            source: .terminalFallback,
            offset: 1)
        GaiCompanionActivityReducer.apply(.event(event), to: &state)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(try decoder.decode(GaiCompanionEvent.self, from: encoder.encode(event)) == event)
        #expect(try decoder.decode(GaiCompanionEvent.self, from: encoder.encode(event)).source
            == .terminalFallback)
        #expect(
            try decoder.decode(GaiCompanionActivityState.self, from: encoder.encode(state))
                == state)
        #expect(try decoder.decode(GaiCompanionActivityState.self, from: encoder.encode(state)).source
            == .terminalFallback)
    }

    private func makeEvent(
        id: String,
        provider: GaiCompanionProvider = .codex,
        turnID: String? = nil,
        kind: GaiCompanionEventKind,
        source: GaiCompanionEventSource = .providerHook,
        offset: TimeInterval = 0,
        message: String? = nil
    ) -> GaiCompanionEvent {
        GaiCompanionEvent(
            surfaceID: surfaceID,
            provider: provider,
            eventID: id,
            turnID: turnID,
            kind: kind,
            source: source,
            timestamp: baseDate.addingTimeInterval(offset),
            message: message)
    }
}

struct GaiCompanionShellCompletionPolicyTests {
    @Test func shortGenericShellCommandSettlesWithoutCompletion() {
        #expect(
            GaiCompanionShellCompletionPolicy.eventKind(
                provider: .terminal,
                exitCode: 0,
                duration: .milliseconds(250),
                minimumTerminalTaskDuration: .seconds(5))
                == .cancelled)
    }

    @Test func meaningfulGenericShellCommandCompletesOrFails() {
        #expect(
            GaiCompanionShellCompletionPolicy.eventKind(
                provider: .terminal,
                exitCode: 0,
                duration: .seconds(5),
                minimumTerminalTaskDuration: .seconds(5))
                == .stop)
        #expect(
            GaiCompanionShellCompletionPolicy.eventKind(
                provider: .terminal,
                exitCode: 2,
                duration: .seconds(6),
                minimumTerminalTaskDuration: .seconds(5))
                == .failed)
    }

    @Test func recognizedAgentProcessExitIsNotMistakenForTurnCompletion() {
        #expect(
            GaiCompanionShellCompletionPolicy.eventKind(
                provider: .codex,
                exitCode: 0,
                duration: .milliseconds(100),
                minimumTerminalTaskDuration: .seconds(5))
                == .cancelled)
        #expect(
            GaiCompanionShellCompletionPolicy.eventKind(
                provider: .claude,
                exitCode: 2,
                duration: .milliseconds(100),
                minimumTerminalTaskDuration: .seconds(5))
                == .failed)
    }
}

struct GaiCompanionInputPolicyTests {
    @Test func nativeHookProvidersDoNotTreatMenuEnterAsWork() {
        for provider in [
            GaiCompanionProvider.codex,
            .claude,
            .agy,
            .opencode,
        ] {
            #expect(
                GaiCompanionInputPolicy.eventKind(
                    provider: provider,
                    phase: .idle,
                    nativeAdapterIsReady: true) == nil)
        }
    }

    @Test func unconfirmedNativeAdapterKeepsOptimisticInputFallback() {
        for provider in [
            GaiCompanionProvider.codex,
            .claude,
            .agy,
            .opencode,
        ] {
            #expect(
                GaiCompanionInputPolicy.eventKind(
                    provider: provider,
                    phase: .idle,
                    nativeAdapterIsReady: false) == .started)
        }
    }

    @Test func genericTerminalStartsOptimistically() {
        #expect(
            GaiCompanionInputPolicy.eventKind(
                provider: .terminal,
                phase: .idle) == .started)
    }

    @Test func explicitWaitResumesImmediatelyForEveryProvider() {
        #expect(
            GaiCompanionInputPolicy.eventKind(
                provider: .codex,
                phase: .awaitingApproval) == .resumed)
        #expect(
            GaiCompanionInputPolicy.eventKind(
                provider: .claude,
                    phase: .awaitingInput) == .resumed)
    }

    @Test func genericShellWorkNeverUsesTheAgentProvisionalExpiry() {
        #expect(
            !GaiCompanionProvisionalExpiryPolicy.shouldExpire(
                stronglyInferredProvider: .terminal))
        for provider in [
            GaiCompanionProvider.codex,
            .claude,
            .agy,
            .opencode,
        ] {
            #expect(
                GaiCompanionProvisionalExpiryPolicy.shouldExpire(
                    stronglyInferredProvider: provider))
        }
    }
}

@MainActor
struct GaiCompanionAgentEventReceiptTests {
    @Test func onlyAuthenticationRejectionSuppressesAcknowledgement() {
        #expect(!GaiCompanionAgentEventReceipt.rejected.shouldAcknowledge)
        #expect(GaiCompanionAgentEventReceipt.applied.shouldAcknowledge)
        #expect(
            GaiCompanionAgentEventReceipt.consumedWithoutChange(
                .duplicateEvent).shouldAcknowledge)
    }
}

@MainActor
struct GaiCompanionRuntimeProjectionTests {
    @Test func completionJumpsUntilAnExplicitAcknowledgement() throws {
        let runtime = GaiCompanionRuntime(record: GaiCompanionRecord(
            name: "Nova",
            colorway: .red))
        let stop = GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: .codex,
            eventID: "stop-1",
            turnID: "turn-1",
            kind: .stop)

        #expect(runtime.apply(.event(stop)) == .appliedEvent)
        #expect(runtime.activity.phase == .completedUnseen)
        #expect(runtime.animation.rawValue == GaiCompanionAnimation.jumping.rawValue)
        #expect(runtime.record.colorway == .red)
        #expect(runtime.renderedColorway == .completionColorway)

        runtime.acknowledgeCompletion()
        #expect(runtime.activity.phase == .idle)
        #expect(runtime.animation.rawValue == GaiCompanionAnimation.idle.rawValue)
        #expect(runtime.record.colorway == .red)
        #expect(runtime.renderedColorway == .red)
    }

    @Test func replacingAPTYRotatesItsCapabilityToken() {
        let runtime = GaiCompanionRuntime(record: GaiCompanionRecord(name: "Nova"))
        let firstToken = runtime.eventToken

        runtime.rotateEventToken()

        #expect(!firstToken.isEmpty)
        #expect(runtime.eventToken != firstToken)
    }

    @Test func nativeAdapterHandshakeIsScopedToOnePTYIncarnation() {
        let runtime = GaiCompanionRuntime(record: GaiCompanionRecord(name: "Nova"))
        #expect(!runtime.hasObservedNativeAdapter(for: .claude))

        _ = runtime.apply(.event(GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: .claude,
            eventID: "claude-ready",
            turnID: "session:session-1",
            kind: .ready)))
        #expect(runtime.hasObservedNativeAdapter(for: .claude))

        runtime.rotateEventToken()
        #expect(!runtime.hasObservedNativeAdapter(for: .claude))

        _ = runtime.apply(.event(GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: .agy,
            eventID: "legacy-post-tool",
            turnID: "session:session-2",
            kind: .resumed)))
        #expect(!runtime.hasObservedNativeAdapter(for: .agy))

        _ = runtime.apply(.event(GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: .agy,
            eventID: "agy-pre-invocation",
            turnID: "session:session-2",
            kind: .started)))
        #expect(runtime.hasObservedNativeAdapter(for: .agy))
    }

    @Test func newPTYIncarnationCannotInheritOfflineFailure() {
        let runtime = GaiCompanionRuntime(record: GaiCompanionRecord(name: "Nova"))
        let oldToken = runtime.eventToken
        _ = runtime.apply(.event(GaiCompanionEvent(
            surfaceID: runtime.id,
            provider: .claude,
            eventID: "failed-old-pty",
            turnID: "session:old",
            kind: .failed)))
        #expect(runtime.surfaceView == nil)
        #expect(runtime.activity.phase == .failed)

        runtime.prepareForNewSurfaceIncarnation()

        #expect(runtime.activity.phase == .idle)
        #expect(runtime.activity.generation == 0)
        #expect(runtime.eventToken != oldToken)
    }
}
#endif
