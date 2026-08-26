#if DEBUG
import AppKit
import Foundation
import Testing
@testable import TeddyCLI

struct GaiCompanionManagerPolicyTests {
    @Test func stackSeedIsCompactUniqueAndConnected() {
        let coordinates = GaiCompanionStackLayout.defaultCoordinates(count: 10)
        #expect(coordinates.count == 10)
        #expect(Set(coordinates).count == 10)
        #expect(GaiCompanionStackLayout.isConnected(Set(coordinates)))
    }

    @Test func dedicatedHubOwnsTheOriginWithoutBreakingTheAgentChain() {
        let agentCoordinates = Array(
            GaiCompanionStackLayout.defaultCoordinates(count: 11).dropFirst())
        #expect(agentCoordinates.count == 10)
        #expect(!agentCoordinates.contains(.origin))
        #expect(GaiCompanionStackLayout.isConnected(
            Set(agentCoordinates).union([.origin])))
    }

    @Test func stackDragCannotSplitTheConstellation() {
        let occupied: Set<GaiCompanionStackCoordinate> = [
            .init(column: 0, row: 0),
            .init(column: 1, row: 0),
            .init(column: 2, row: 0),
        ]
        #expect(!GaiCompanionStackLayout.canMove(
            from: .init(column: 1, row: 0),
            to: .init(column: 1, row: 1),
            occupied: occupied))
        #expect(GaiCompanionStackLayout.canMove(
            from: .init(column: 2, row: 0),
            to: .init(column: 0, row: 1),
            occupied: occupied))
    }

    @Test func stackOrientationBloomsInwardWithoutMovingItsAnchor() throws {
        let ids = (0..<4).map { _ in UUID() }
        let coordinates = Dictionary(uniqueKeysWithValues: zip(
            ids,
            GaiCompanionStackLayout.defaultCoordinates(count: ids.count)))
        let size = NSSize(width: 100, height: 100)
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, size) })
        let anchorFrame = NSRect(x: 850, y: 650, width: 100, height: 100)
        let workArea = NSRect(x: 0, y: 0, width: 1_000, height: 800)

        let layout = GaiCompanionStackLayout.resolve(
            ids: ids,
            coordinates: coordinates,
            sizes: sizes,
            anchorID: ids[0],
            anchorFrame: anchorFrame,
            workArea: workArea)

        #expect(layout.orientation == .rotate180)
        #expect(try #require(layout.frames[ids[0]]) == anchorFrame)
        #expect(layout.frames.values.allSatisfy { workArea.contains($0) })
    }

    @Test func stackLayoutNeverPullsAnEdgeAlignedAnchorBackOntoTheDesktop() throws {
        let ids = (0..<4).map { _ in UUID() }
        let coordinates = Dictionary(uniqueKeysWithValues: zip(
            ids,
            GaiCompanionStackLayout.defaultCoordinates(count: ids.count)))
        let size = NSSize(width: 142, height: 174)
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, size) })
        let anchorFrame = NSRect(x: -42, y: -74, width: 142, height: 174)

        let layout = GaiCompanionStackLayout.resolve(
            ids: ids,
            coordinates: coordinates,
            sizes: sizes,
            anchorID: ids[0],
            anchorFrame: anchorFrame,
            workArea: NSRect(x: 0, y: 0, width: 1_000, height: 800))

        #expect(try #require(layout.frames[ids[0]]) == anchorFrame)
    }

    @Test func organicGridUsesTheMascotFootprintInsteadOfTransparentPanelBounds() {
        let ids = (0..<2).map { _ in UUID() }
        let coordinates = Dictionary(uniqueKeysWithValues: zip(
            ids,
            GaiCompanionStackLayout.defaultCoordinates(count: ids.count)))
        let size = NSSize(width: 142, height: 174)
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, size) })

        let layout = GaiCompanionStackLayout.resolve(
            ids: ids,
            coordinates: coordinates,
            sizes: sizes,
            anchorID: ids[0],
            anchorFrame: NSRect(x: 400, y: 300, width: 142, height: 174),
            workArea: NSRect(x: 0, y: 0, width: 1_000, height: 800))

        #expect(abs(layout.cellSize.width - 122) < 0.001)
        #expect(abs(layout.cellSize.height - 160) < 0.001)
    }

    @Test func everyStackOrientationRoundTripsGridCoordinates() {
        let coordinate = GaiCompanionStackCoordinate(column: 3, row: -2)
        for orientation in GaiCompanionStackOrientation.allCases {
            #expect(orientation.removing(from: orientation.applying(to: coordinate))
                == coordinate)
        }
    }

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
