#if DEBUG
import AppKit
import Foundation
import Testing
@testable import TeddyCLI

struct GaiCompanionManagerPolicyTests {
    @Test func mascotDoubleClickAlwaysOpensTheExpandedTerminal() {
        let doubleClick = GaiCompanionMascotActivation.doubleClick
        #expect(doubleClick.targetPresentation(from: .collapsed) == .maximized)
        #expect(doubleClick.targetPresentation(from: .compact) == .maximized)
        #expect(doubleClick.targetPresentation(from: .maximized) == .maximized)

        let singleClick = GaiCompanionMascotActivation.singleClick
        #expect(singleClick.targetPresentation(from: .collapsed) == .compact)
        #expect(singleClick.targetPresentation(from: .compact) == .collapsed)
        #expect(singleClick.targetPresentation(from: .maximized) == .collapsed)
    }

    @Test func expandedTerminalPresetsTileTheUsableScreenExactly() {
        let workArea = NSRect(x: 10, y: 20, width: 1_000, height: 800)

        #expect(GaiCompanionTerminalLayoutPreset.fullScreen.frame(in: workArea) == workArea)
        #expect(
            GaiCompanionTerminalLayoutPreset.leftHalf.frame(in: workArea)
                == NSRect(x: 10, y: 20, width: 496, height: 800))
        #expect(
            GaiCompanionTerminalLayoutPreset.rightHalf.frame(in: workArea)
                == NSRect(x: 514, y: 20, width: 496, height: 800))
        #expect(
            GaiCompanionTerminalLayoutPreset.topHalf.frame(in: workArea)
                == NSRect(x: 10, y: 424, width: 1_000, height: 396))
        #expect(
            GaiCompanionTerminalLayoutPreset.bottomRightQuarter.frame(in: workArea)
                == NSRect(x: 514, y: 20, width: 496, height: 396))
    }

    @Test func droppedFilesBecomeOneShellSafeEditableInputFragment() {
        let insertion = GaiCompanionDroppedPathInsertion.text(forPaths: [
            "/tmp/readme.md",
            "/tmp/My Photo.png",
            "/tmp/Bob's clip.mov",
        ])
        #expect(
            insertion
                == "/tmp/readme.md '/tmp/My Photo.png' '/tmp/Bob'\\''s clip.mov' ")

        let controlCharacterPath = GaiCompanionDroppedPathInsertion.text(
            forPaths: ["/tmp/line\nbreak"])
        #expect(controlCharacterPath == "$'/tmp/line\\nbreak' ")
    }

    @Test func finderPasteboardsResolveEveryDroppedFileInOrder() {
        let pasteboard = NSPasteboard(
            name: .init("gai.companion.drop-test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(
            pasteboard.writeObjects([
                NSURL(fileURLWithPath: "/tmp/First File.txt"),
                NSURL(fileURLWithPath: "/tmp/second.mov"),
            ]))

        #expect(GaiCompanionFileDropPayload.isAdvertised(on: pasteboard))
        #expect(
            GaiCompanionFileDropPayload.fileURLs(from: pasteboard).map(\.path)
                == ["/tmp/First File.txt", "/tmp/second.mov"])
    }

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
