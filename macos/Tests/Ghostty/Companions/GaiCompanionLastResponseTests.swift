#if DEBUG
import Foundation
import Testing
@testable import TeddyCLI

struct GaiCompanionLastResponseTests {
    @Test func appendedTerminalOutputBecomesTheLastResponse() {
        let agentID = UUID()
        let store = GaiCompanionLastResponseStore()
        let token = store.begin(
            agentID: agentID,
            origin: .user,
            screenText: "$ codex\n› Corrige le crash")

        let response = store.complete(
            token: token,
            provider: .codex,
            eventID: "stop-1",
            screenText: "$ codex\n› Corrige le crash\nJ’ai corrigé la course critique.")

        #expect(response?.origin == .user)
        #expect(response?.text == "J’ai corrigé la course critique.")
        #expect(store.lastResponse(for: agentID) == response)
    }

    @Test func teddyOriginIsPreservedAndThePreviousResponseIsReplaced() {
        let agentID = UUID()
        let store = GaiCompanionLastResponseStore()
        let first = store.begin(agentID: agentID, origin: .user, screenText: "question")
        _ = store.complete(
            token: first,
            provider: .claude,
            eventID: "first",
            screenText: "question\npremière réponse")

        let second = store.begin(agentID: agentID, origin: .teddy, screenText: "question 2")
        let response = store.complete(
            token: second,
            provider: .claude,
            eventID: "second",
            screenText: "question 2\nseconde réponse")

        #expect(response?.origin == .teddy)
        #expect(response?.text == "seconde réponse")
        #expect(store.lastResponse(for: agentID)?.eventID == "second")
    }

    @Test func teddySubmittedTextIsRemovedFromTheCapturedResponse() {
        let agentID = UUID()
        let store = GaiCompanionLastResponseStore()
        let token = store.begin(
            agentID: agentID,
            origin: .teddy,
            screenText: "Codex ready",
            submittedText: "Vérifie les tests")

        let response = store.complete(
            token: token,
            provider: .codex,
            eventID: "stop",
            screenText: "Codex ready\n› Vérifie les tests\nLes 34 tests passent.")

        #expect(response?.text == "Les 34 tests passent.")
    }

    @Test func providerNativeAnswerBypassesRedrawnTerminalChrome() {
        let agentID = UUID()
        let store = GaiCompanionLastResponseStore()
        let token = store.begin(
            agentID: agentID,
            origin: .user,
            screenText: "Codex redraw in progress")

        let response = store.complete(
            token: token,
            provider: .codex,
            eventID: "stop-native",
            responseText: "  La correction est terminée et les tests passent.\n")

        #expect(response?.origin == .user)
        #expect(response?.text == "La correction est terminée et les tests passent.")
    }

    @Test func earlyEmptyCaptureDoesNotConsumeThePendingTurn() {
        let agentID = UUID()
        let store = GaiCompanionLastResponseStore()
        let token = store.begin(
            agentID: agentID,
            origin: .teddy,
            screenText: "Codex ready",
            submittedText: "Corrige le bug")

        let earlyResponse = store.complete(
            token: token,
            provider: .codex,
            eventID: "too-early",
            screenText: "Codex ready")
        #expect(earlyResponse == nil)
        #expect(store.token(for: agentID) == token)
        let settledResponse = store.complete(
            token: token,
            provider: .codex,
            eventID: "settled",
            screenText: "Codex ready\n› Corrige le bug\nC’est corrigé.")
        #expect(settledResponse?.text == "C’est corrigé.")
    }

    @Test func settlementRequiresARealCandidateAndSeveralIdenticalSamples() {
        var observation = GaiResponseSettlementObservation()
        let candidate = GaiCompanionResponseExtraction.Result(
            text: "C’est terminé.",
            wasTruncated: false)

        let emptyCandidateSettled = observation.observe(
            screenText: "working 1",
            candidateResponse: nil)
        #expect(!emptyCandidateSettled)
        for count in 1..<GaiResponseSettlementObservation.requiredIdenticalSamples {
            let settled = observation.observe(
                screenText: "C’est terminé.",
                candidateResponse: candidate)
            #expect(!settled)
            #expect(observation.identicalSampleCount == count)
        }
        let settled = observation.observe(
            screenText: "C’est terminé.",
            candidateResponse: candidate)
        #expect(settled)

        let changedScreenSettled = observation.observe(
            screenText: "Nouvelle sortie",
            candidateResponse: candidate)
        #expect(!changedScreenSettled)
        #expect(observation.identicalSampleCount == 1)
    }

    @Test func ambiguousReturnNeedsContinuingOutputBeforeItLooksLikeWork() {
        let observation = GaiResponseActivityObservation(
            baselineScreenText: "Codex ready\nChoose a model\n1. Fast\n2. Smart")
        let menuCandidate = GaiCompanionResponseExtraction.Result(
            text: "Menu closed",
            wasTruncated: false)

        #expect(!observation.observe(
            screenText: "Codex ready\nChoose a model\n1. Fast\n2. Smart",
            candidateResponse: nil))
        #expect(!observation.observe(
            screenText: "Codex ready",
            candidateResponse: menuCandidate))

        let streamingCandidate = GaiCompanionResponseExtraction.Result(
            text: "Analyse en cours…",
            wasTruncated: false)
        #expect(observation.observe(
            screenText: "Codex ready\nAnalyse en cours…",
            candidateResponse: streamingCandidate))
    }

    @Test func completeResponseBeforeFirstProbeIsImmediatePositiveEvidence() {
        let observation = GaiResponseActivityObservation(
            baselineScreenText: "Codex ready\n› Corrige le bug")
        let candidate = GaiCompanionResponseExtraction.Result(
            text: "Le bug est corrigé.",
            wasTruncated: false)

        #expect(observation.observe(
            screenText: "Codex ready\n› Corrige le bug\nLe bug est corrigé.",
            candidateResponse: candidate))
    }

    @Test func completeResponseArrivingAtTheLastProbeIsStillPositiveEvidence() {
        let baseline = "Claude ready\n› Vérifie les tests"
        let observation = GaiResponseActivityObservation(
            baselineScreenText: baseline)

        for _ in 0..<12 {
            #expect(!observation.observe(
                screenText: baseline,
                candidateResponse: nil))
        }
        let candidate = GaiCompanionResponseExtraction.Result(
            text: "Tous les tests passent.",
            wasTruncated: false)
        #expect(observation.observe(
            screenText: "\(baseline)\nTous les tests passent.",
            candidateResponse: candidate))
    }

    @Test func hooklessTurnCanSettleAfterMoreThanTheFormerThreeSecondWindow() {
        var observation = GaiResponseSettlementObservation()
        let candidate = GaiCompanionResponseExtraction.Result(
            text: "Réponse finale après un long calcul.",
            wasTruncated: false)

        for index in 0..<20 {
            let settled = observation.observe(
                screenText: "Calcul en cours \(index)",
                candidateResponse: candidate)
            #expect(!settled)
        }
        for _ in 1..<GaiResponseSettlementObservation.requiredIdenticalSamples {
            let settled = observation.observe(
                screenText: "Réponse finale après un long calcul.",
                candidateResponse: candidate)
            #expect(!settled)
        }
        let settled = observation.observe(
            screenText: "Réponse finale après un long calcul.",
            candidateResponse: candidate)
        #expect(settled)
    }

    @Test func interactiveChromeRedrawUsesABoundedLineAnchor() {
        let baseline = GaiCompanionResponseExtraction.snapshot(
            "Codex\n────────\n› Analyse ce fichier\nworking…")
        let completed = GaiCompanionResponseExtraction.snapshot(
            "Codex · 42% context\n────────\n› Analyse ce fichier\nworking…\nLe problème vient du décodage audio.")

        let response = GaiCompanionResponseExtraction.response(
            baseline: baseline,
            completed: completed)

        #expect(response?.text == "Le problème vient du décodage audio.")
    }

    @Test func staleCompletionCannotConsumeANewerTurn() {
        let agentID = UUID()
        let store = GaiCompanionLastResponseStore()
        let stale = store.begin(agentID: agentID, origin: .user, screenText: "old")
        let current = store.begin(agentID: agentID, origin: .teddy, screenText: "new")

        let staleResponse = store.complete(
            token: stale,
            provider: .codex,
            eventID: "stale",
            screenText: "old\nstale answer")
        let currentResponse = store.complete(
            token: current,
            provider: .codex,
            eventID: "current",
            screenText: "new\ncurrent answer")

        #expect(staleResponse == nil)
        #expect(currentResponse?.text == "current answer")
    }

    @Test func pendingTurnCarriesOriginAndSubmissionBoundary() {
        let agentID = UUID()
        let beganAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = GaiCompanionLastResponseStore()
        let token = store.begin(
            agentID: agentID,
            origin: .teddy,
            screenText: "Codex ready",
            beganAt: beganAt)

        let pending = store.pendingTurn(for: agentID)

        #expect(pending?.token == token)
        #expect(pending?.origin == .teddy)
        #expect(pending?.beganAt == beganAt)
    }

    @Test func providerTurnIdentityRejectsAnotherTurnsCompletion() {
        let agentID = UUID()
        let store = GaiCompanionLastResponseStore()
        let token = store.begin(
            agentID: agentID,
            origin: .teddy,
            screenText: "Codex ready")
        #expect(store.bindTurn(agentID: agentID, turnID: "turn:current") == token)

        let stale = store.complete(
            token: token,
            provider: .codex,
            eventID: "stale-stop",
            turnID: "turn:previous",
            responseText: "ancienne réponse")
        let current = store.complete(
            token: token,
            provider: .codex,
            eventID: "current-stop",
            turnID: "turn:current",
            responseText: "nouvelle réponse")

        #expect(stale == nil)
        #expect(current?.text == "nouvelle réponse")
        #expect(current?.turnID == "turn:current")
    }

    @Test func responseStorageIsStrictlyBounded() {
        let agentID = UUID()
        let store = GaiCompanionLastResponseStore()
        let token = store.begin(agentID: agentID, origin: .user, screenText: "prompt")
        let oversized = String(repeating: "x", count:
            GaiCompanionResponseExtraction.maximumResponseCharacters + 500)

        let response = store.complete(
            token: token,
            provider: .codex,
            eventID: "large",
            screenText: "prompt\n\(oversized)")

        #expect(response?.text.count == GaiCompanionResponseExtraction.maximumResponseCharacters)
        #expect(response?.wasTruncated == true)
    }
}
#endif
