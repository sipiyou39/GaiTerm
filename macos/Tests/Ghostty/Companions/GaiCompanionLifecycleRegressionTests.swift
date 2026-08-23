#if DEBUG
import Foundation
import Testing
@testable import TeddyCLI

struct GaiCompanionLifecycleRegressionTests {
    private let surfaceID = UUID(uuidString: "F14702E7-12B4-4478-B458-5DC61CEAEABC")!
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func settledTerminalOutputRecoversAMissingProviderStop() {
        let working = GaiCompanionActivityReducer.reduce(
            GaiCompanionActivityState(surfaceID: surfaceID),
            action: .event(event(
                id: "provider-start",
                turnID: "turn:one",
                kind: .started,
                source: .providerHook)))
        let completed = GaiCompanionActivityReducer.reduce(
            working.state,
            action: .event(event(
                id: "settled-output",
                turnID: "turn:one",
                kind: .stop,
                source: .terminalObservation)))

        #expect(working.disposition == .appliedEvent)
        #expect(completed.disposition == .appliedEvent)
        #expect(completed.state.phase == .completedUnseen)
        #expect(completed.state.pendingAcknowledgement?.eventID == "settled-output")
    }

    @Test func settledTerminalOutputCannotFinishAnotherTurnOrAUserWait() {
        let working = GaiCompanionActivityReducer.reduce(
            GaiCompanionActivityState(surfaceID: surfaceID),
            action: .event(event(
                id: "provider-start",
                turnID: "turn:one",
                kind: .started,
                source: .providerHook)))
        let wrongTurn = GaiCompanionActivityReducer.reduce(
            working.state,
            action: .event(event(
                id: "wrong-turn",
                turnID: "turn:two",
                kind: .stop,
                source: .terminalObservation)))
        let waiting = GaiCompanionActivityReducer.reduce(
            working.state,
            action: .event(event(
                id: "needs-user",
                turnID: "turn:one",
                kind: .awaitingInput,
                source: .providerHook)))
        let stopWhileWaiting = GaiCompanionActivityReducer.reduce(
            waiting.state,
            action: .event(event(
                id: "settled-while-waiting",
                turnID: "turn:one",
                kind: .stop,
                source: .terminalObservation)))

        #expect(wrongTurn.disposition == .ignoredStaleEvent)
        #expect(wrongTurn.state.phase == .working)
        #expect(stopWhileWaiting.disposition == .ignoredStaleEvent)
        #expect(stopWhileWaiting.state.phase == .awaitingInput)
    }

    @Test func guaranteedTeddySubmissionAlwaysOpensALocalTurn() {
        #expect(GaiCompanionGuaranteedInputPolicy.eventKind(for: .idle) == .started)
        #expect(GaiCompanionGuaranteedInputPolicy.eventKind(for: .completedUnseen) == .started)
        #expect(GaiCompanionGuaranteedInputPolicy.eventKind(for: .failed) == .started)
        #expect(GaiCompanionGuaranteedInputPolicy.eventKind(for: .awaitingInput) == .resumed)
        #expect(GaiCompanionGuaranteedInputPolicy.eventKind(for: .working) == nil)
        #expect(GaiCompanionGuaranteedInputPolicy.eventKind(for: .exited) == nil)
    }

    @Test func teddyCanStartASecondTurnWhileCompletionIsStillUnseen() {
        let firstStart = GaiCompanionActivityReducer.reduce(
            GaiCompanionActivityState(surfaceID: surfaceID),
            action: .event(event(
                id: "first-start",
                turnID: "turn:first",
                kind: .started,
                source: .providerHook)))
        let firstStop = GaiCompanionActivityReducer.reduce(
            firstStart.state,
            action: .event(event(
                id: "first-stop",
                turnID: "turn:first",
                kind: .stop,
                source: .providerHook)))
        let teddyStart = GaiCompanionActivityReducer.reduce(
            firstStop.state,
            action: .event(event(
                id: "teddy-second-start",
                turnID: nil,
                kind: .started,
                source: .userInput)))
        let providerStart = GaiCompanionActivityReducer.reduce(
            teddyStart.state,
            action: .event(event(
                id: "second-start",
                turnID: "turn:second",
                kind: .started,
                source: .providerHook)))
        let secondStop = GaiCompanionActivityReducer.reduce(
            providerStart.state,
            action: .event(event(
                id: "second-stop",
                turnID: "turn:second",
                kind: .stop,
                source: .providerHook)))

        #expect(firstStop.state.phase == .completedUnseen)
        #expect(teddyStart.disposition == .appliedEvent)
        #expect(teddyStart.state.phase == .working)
        #expect(teddyStart.state.pendingAcknowledgement == nil)
        #expect(providerStart.disposition == .appliedEvent)
        #expect(providerStart.state.generation == teddyStart.state.generation)
        #expect(secondStop.disposition == .appliedEvent)
        #expect(secondStop.state.phase == .completedUnseen)
        #expect(secondStop.state.generation == firstStop.state.generation + 1)
    }

    @Test func authenticatedStopRecoversOnlyTheCurrentTeddyTurn() {
        let working = GaiCompanionActivityReducer.reduce(
            GaiCompanionActivityState(surfaceID: surfaceID),
            action: .event(event(
                id: "teddy-local-start",
                turnID: nil,
                kind: .started,
                source: .userInput)))
        let store = GaiCompanionLastResponseStore()
        _ = store.begin(
            agentID: surfaceID,
            origin: .teddy,
            screenText: "Codex ready",
            beganAt: timestamp)
        let pendingTurn = store.pendingTurn(for: surfaceID)
        let stop = event(
            id: "codex-stop",
            turnID: "turn:new",
            kind: .stop,
            source: .providerHook,
            responseText: "La mission est terminée.",
            at: timestamp.addingTimeInterval(1))

        let shouldRecover = GaiAuthenticatedStopRecoveryPolicy.shouldRecover(
            event: stop,
            disposition: .ignoredStaleTurn,
            state: working.state,
            pendingTurn: pendingTurn)

        #expect(shouldRecover)
    }

    @Test func authenticatedStopWithoutEmbeddedAnswerStillRecoversTeddyTurn() {
        let working = GaiCompanionActivityReducer.reduce(
            GaiCompanionActivityState(surfaceID: surfaceID),
            action: .event(event(
                id: "teddy-local-start",
                turnID: nil,
                kind: .started,
                source: .userInput)))
        let store = GaiCompanionLastResponseStore()
        _ = store.begin(
            agentID: surfaceID,
            origin: .teddy,
            screenText: "Codex ready",
            beganAt: timestamp)
        let stop = event(
            id: "codex-stop-without-answer",
            turnID: "turn:new",
            kind: .stop,
            source: .providerHook,
            responseText: nil,
            at: timestamp.addingTimeInterval(1))

        let shouldRecover = GaiAuthenticatedStopRecoveryPolicy.shouldRecover(
            event: stop,
            disposition: .ignoredStaleTurn,
            state: working.state,
            pendingTurn: store.pendingTurn(for: surfaceID))

        #expect(shouldRecover)
    }

    @Test func authenticatedStopNeverRewritesAConflictingTurn() {
        let working = GaiCompanionActivityReducer.reduce(
            GaiCompanionActivityState(surfaceID: surfaceID),
            action: .event(event(
                id: "current-start",
                turnID: "turn:current",
                kind: .started,
                source: .providerHook)))
        let store = GaiCompanionLastResponseStore()
        _ = store.begin(
            agentID: surfaceID,
            origin: .teddy,
            screenText: "Codex working",
            beganAt: timestamp)
        let staleStop = event(
            id: "old-stop",
            turnID: "turn:old",
            kind: .stop,
            source: .providerHook,
            responseText: "Ancienne réponse",
            at: timestamp.addingTimeInterval(1))

        let shouldRecover = GaiAuthenticatedStopRecoveryPolicy.shouldRecover(
            event: staleStop,
            disposition: .ignoredStaleTurn,
            state: working.state,
            pendingTurn: store.pendingTurn(for: surfaceID))

        #expect(!shouldRecover)
    }

    @Test func authenticatedStopNeverClaimsAUserOwnedTurn() {
        let working = GaiCompanionActivityReducer.reduce(
            GaiCompanionActivityState(surfaceID: surfaceID),
            action: .event(event(
                id: "user-start",
                turnID: nil,
                kind: .started,
                source: .userInput)))
        let store = GaiCompanionLastResponseStore()
        _ = store.begin(
            agentID: surfaceID,
            origin: .user,
            screenText: "Codex ready",
            beganAt: timestamp)
        let stop = event(
            id: "codex-stop",
            turnID: "turn:new",
            kind: .stop,
            source: .providerHook,
            responseText: "Réponse utilisateur",
            at: timestamp.addingTimeInterval(1))

        let shouldRecover = GaiAuthenticatedStopRecoveryPolicy.shouldRecover(
            event: stop,
            disposition: .ignoredStaleTurn,
            state: working.state,
            pendingTurn: store.pendingTurn(for: surfaceID))

        #expect(!shouldRecover)
    }

    private func event(
        id: String,
        turnID: String?,
        kind: GaiCompanionEventKind,
        source: GaiCompanionEventSource,
        responseText: String? = nil,
        at eventTimestamp: Date? = nil
    ) -> GaiCompanionEvent {
        GaiCompanionEvent(
            surfaceID: surfaceID,
            provider: .codex,
            eventID: id,
            turnID: turnID,
            kind: kind,
            source: source,
            timestamp: eventTimestamp ?? timestamp,
            responseText: responseText)
    }
}
#endif
