#if DEBUG
import Foundation
import Testing
@testable import Ghostty

struct GaiCompanionManagerPolicyTests {
    @Test func libraryRevealPreservesHiddenAgentsWhileTerminalPresentationRevealsThem() {
        #expect(
            GaiCompanionVisibilityAction.revealLibrary
                .resultingAgentVisibility(current: false) == false)
        #expect(
            GaiCompanionVisibilityAction.revealLibrary
                .resultingAgentVisibility(current: true) == true)
        #expect(
            GaiCompanionVisibilityAction.presentAgentTerminal
                .resultingAgentVisibility(current: false) == true)
    }

    @Test func cancellingBulkRemovalProducesNoDestructiveTargets() {
        let firstID = UUID()
        let secondID = UUID()
        let plan = GaiCompanionBulkRemovalPlan(
            agentIDs: [firstID, secondID, firstID])

        #expect(plan.agentIDs == [firstID, secondID])
        #expect(plan.agentIDsToRemove(confirmed: false).isEmpty)
        #expect(plan.agentIDsToRemove(confirmed: true) == [firstID, secondID])
        #expect(plan.title == "Kill all 2 agents and their terminals?")
        #expect(plan.destructiveButtonTitle == "Kill All Agents")
        #expect(plan.explanation.contains("This cannot be undone."))
    }
}
#endif
