#if DEBUG
import Foundation
import SwiftUI
import Testing
@testable import TeddyCLI

struct TeddyCompanionReadinessGateTests {
    @Test func staleTerminalCacheIsReplacedByFreshCLIProof() throws {
        let companionID = UUID()
        let cached = Self.snapshot(
            id: companionID,
            provider: "terminal",
            phase: .idle)
        let fresh = Self.snapshot(
            id: companionID,
            provider: "codex",
            phase: .idle)

        let resolved = try #require(
            TeddyCompanionReadinessGate.revalidatedSnapshot(cached) { id in
                #expect(id == companionID)
                return fresh
            })

        #expect(resolved == fresh)
        #expect(
            TeddyCompanionReadinessGate.permitsPrompt(
                resolved,
                hasPendingPrompt: false))
    }

    @Test func freshShellReturnInvalidatesStaleCLICache() throws {
        let companionID = UUID()
        let cached = Self.snapshot(
            id: companionID,
            provider: "codex",
            phase: .completed)
        let freshShell = Self.snapshot(
            id: companionID,
            provider: "terminal",
            phase: .completed)

        let resolved = try #require(
            TeddyCompanionReadinessGate.revalidatedSnapshot(cached) { _ in
                freshShell
            })

        #expect(!resolved.isCLIReady)
        #expect(
            !TeddyCompanionReadinessGate.permitsPrompt(
                resolved,
                hasPendingPrompt: false))
    }

    @Test func exitedCLIAlwaysBlocksPromptEvenWithProviderCache() throws {
        let exited = Self.snapshot(
            id: UUID(),
            provider: "codex",
            phase: .exited)
        let resolved = try #require(
            TeddyCompanionReadinessGate.revalidatedSnapshot(exited) { _ in exited })

        #expect(!resolved.isCLIReady)
        #expect(
            !TeddyCompanionReadinessGate.permitsPrompt(
                resolved,
                hasPendingPrompt: false))
    }

    @Test func missingFreshCompanionCannotAuthorizeStaleCache() {
        let cached = Self.snapshot(
            id: UUID(),
            provider: "codex",
            phase: .idle)
        let resolved = TeddyCompanionReadinessGate.revalidatedSnapshot(cached) { _ in nil }

        #expect(resolved == nil)
    }

    @MainActor
    @Test func conversationRefreshUsesCacheAndExplicitBoundaryRevalidatesOnce() throws {
        let router = CountingCompanionRouter()
        let controller = VoiceAgentController(companionRouter: router)
        let companionID = controller.activeConversationID
        let cached = Self.snapshot(
            id: companionID,
            provider: "terminal",
            phase: .idle)
        let fresh = Self.snapshot(
            id: companionID,
            provider: "codex",
            phase: .idle)
        router.cached = cached
        router.fresh = fresh

        controller.refreshCompanionConversations(preferredSelection: companionID)

        #expect(router.snapshotReads == 1)
        #expect(router.freshSnapshotReads == 0)
        #expect(controller.companionSnapshot(for: companionID) == cached)

        controller.refreshActiveCompanionReadiness()

        #expect(router.freshSnapshotReads == 1)
        #expect(controller.companionSnapshot(for: companionID) == fresh)
    }

    private static func snapshot(
        id: UUID,
        provider: String,
        phase: TeddyCompanionSnapshot.Phase
    ) -> TeddyCompanionSnapshot {
        TeddyCompanionSnapshot(
            id: id,
            name: "Agent",
            provider: provider,
            phase: phase,
            directoryPath: "/tmp/project",
            hasPendingResponse: false)
    }
}

@MainActor
private final class CountingCompanionRouter: TeddyCompanionRouting {
    let toolDefinitions: [GrokTextToolDefinition] = []
    var cached: TeddyCompanionSnapshot?
    var fresh: TeddyCompanionSnapshot?
    private(set) var snapshotReads = 0
    private(set) var freshSnapshotReads = 0

    func currentAgentContext() -> String { "" }

    func companionSnapshots() -> [TeddyCompanionSnapshot] {
        snapshotReads += 1
        return cached.map { [$0] } ?? []
    }

    func freshCompanionSnapshot(for companionID: UUID) -> TeddyCompanionSnapshot? {
        freshSnapshotReads += 1
        guard fresh?.id == companionID else { return nil }
        return fresh
    }

    func selectCompanion(_: UUID) {}

    func submitPrompt(_: String, to _: UUID) -> TeddyCompanionControlResult {
        .submitted
    }

    func interruptCompanion(_: UUID) -> TeddyCompanionControlResult {
        .interrupted
    }

    func createCompanion(
        directoryPath _: String,
        cli _: String
    ) -> Result<TeddyCompanionSnapshot, TeddyCompanionControlFailure> {
        .failure(.creationFailed)
    }

    func renameCompanion(_: UUID, to _: String) {}
    func changeCompanionDirectory(_: UUID, to _: String) {}
    func makeInlineTerminalView(for _: UUID) -> AnyView? { nil }
    func makeCompanionAvatarView(for _: UUID, width _: CGFloat) -> AnyView? { nil }
    func makeCompanionCreationView() -> AnyView? { nil }

    func execute(
        _: GrokTextToolCall,
        selectDirectory _: @escaping TeddyDirectorySelectionPresenter
    ) async throws -> GrokTextToolResult {
        GrokTextToolResult(output: "")
    }
}
#endif
