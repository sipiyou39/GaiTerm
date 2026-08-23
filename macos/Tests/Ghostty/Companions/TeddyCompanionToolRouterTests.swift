#if DEBUG
import Foundation
import Testing
@testable import GaiTerm

struct TeddyCompanionToolRouterTests {
    @Test func resolverAcceptsUUIDAndHumanName() {
        let alpha = snapshot(name: "Alpha")
        let beta = snapshot(name: "Béta")

        #expect(GaiManagedAgentResolver.resolve(
            alpha.id.uuidString,
            in: [alpha, beta]) == .found(alpha))
        #expect(GaiManagedAgentResolver.resolve(
            "beta",
            in: [alpha, beta]) == .found(beta))
    }

    @Test func resolverRefusesAmbiguousPartialNames() {
        let one = snapshot(name: "Codex API")
        let two = snapshot(name: "Codex Audio")

        #expect(GaiManagedAgentResolver.resolve(
            "codex",
            in: [one, two]) == .ambiguous([one, two]))
    }

    @Test func toolSchemasAreValidRootObjects() throws {
        #expect(TeddyCompanionToolRouter.definitions.count == 5)
        for definition in TeddyCompanionToolRouter.definitions {
            let object = try #require(
                JSONSerialization.jsonObject(with: definition.parameters)
                    as? [String: Any])
            #expect(object["type"] as? String == "object")
        }
    }

    private func snapshot(name: String) -> GaiManagedAgentSnapshot {
        GaiManagedAgentSnapshot(
            id: UUID(),
            name: name,
            provider: .codex,
            phase: .idle,
            directoryPath: "/tmp",
            launchCommand: "codex",
            lastResponse: nil,
            isResponsePending: false)
    }
}
#endif
