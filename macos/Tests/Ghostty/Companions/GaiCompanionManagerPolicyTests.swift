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

    @Test func compactStackFillsTheHubNeighboursBeforeGrowingAnOuterArm() {
        let coordinates = GaiCompanionStackLayout.defaultCoordinates(count: 8)
        #expect(coordinates.contains(.init(column: 1, row: 0)))
        #expect(coordinates.contains(.init(column: 0, row: 1)))
        #expect(coordinates.contains(.init(column: 1, row: 1)))
    }

    @Test func newStackCellExtendsTheCompactFootprintInsteadOfBranching() {
        let occupied = Set(GaiCompanionStackLayout.defaultCoordinates(count: 8))
        #expect(GaiCompanionStackLayout.firstAvailableConnectedCoordinate(
            occupied: occupied) == .init(column: 2, row: 2))
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

    @Test func magneticStackKeepsItsShapeUntilAnEdgePushesIt() {
        let ids = (0..<4).map { _ in UUID() }
        let coordinates = Dictionary(uniqueKeysWithValues: zip(
            ids,
            GaiCompanionStackLayout.defaultCoordinates(count: ids.count)))
        let size = NSSize(width: 100, height: 100)
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, size) })
        let workArea = NSRect(x: 0, y: 0, width: 1_000, height: 800)

        let unpressured = GaiCompanionStackLayout.resolveMagnetically(
            ids: ids,
            coordinates: coordinates,
            sizes: sizes,
            anchorID: ids[0],
            anchorFrame: NSRect(x: 400, y: 300, width: 100, height: 100),
            workArea: workArea,
            currentOrientation: .rotate180)
        #expect(unpressured.orientation == .rotate180)

        let edgePressed = GaiCompanionStackLayout.resolveMagnetically(
            ids: ids,
            coordinates: coordinates,
            sizes: sizes,
            anchorID: ids[0],
            anchorFrame: NSRect(x: 850, y: 650, width: 100, height: 100),
            workArea: workArea,
            currentOrientation: .identity)
        #expect(edgePressed.orientation == .rotate180)

        let transposedEdgePressed = GaiCompanionStackLayout.resolveMagnetically(
            ids: ids,
            coordinates: coordinates,
            sizes: sizes,
            anchorID: ids[0],
            anchorFrame: NSRect(x: 850, y: 650, width: 100, height: 100),
            workArea: workArea,
            currentOrientation: .transpose)
        #expect(transposedEdgePressed.orientation.rawValue
            >= GaiCompanionStackOrientation.transpose.rawValue)
    }

    @Test func aPreferredOrientationCannotKeepAnAgentBeyondTheScreenEdge() {
        let ids = (0..<8).map { _ in UUID() }
        let coordinates = Dictionary(uniqueKeysWithValues: zip(
            ids,
            GaiCompanionStackLayout.defaultCoordinates(count: ids.count)))
        let size = NSSize(width: 100, height: 100)
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, size) })
        let workArea = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let anchorFrame = NSRect(x: 850, y: 650, width: 100, height: 100)

        let layout = GaiCompanionStackLayout.resolve(
            ids: ids,
            coordinates: coordinates,
            sizes: sizes,
            anchorID: ids[0],
            anchorFrame: anchorFrame,
            workArea: workArea,
            preferredOrientation: .identity)

        #expect(layout.orientation == .rotate180)
        #expect(layout.frames
            .filter { $0.key != ids[0] }
            .allSatisfy { workArea.contains($0.value) })
    }

    @Test func magneticEdgeResponseDoesNotWaitWhileAnAgentIsClipped() throws {
        let ids = (0..<2).map { _ in UUID() }
        let coordinates = Dictionary(uniqueKeysWithValues: zip(
            ids,
            GaiCompanionStackLayout.defaultCoordinates(count: ids.count)))
        let size = NSSize(width: 100, height: 100)
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, size) })
        let workArea = NSRect(x: 0, y: 0, width: 1_000, height: 800)

        // Identity exceeds the right edge by only two points. The old squared
        // hysteresis kept it clipped because 2² was smaller than 8².
        let layout = GaiCompanionStackLayout.resolveMagnetically(
            ids: ids,
            coordinates: coordinates,
            sizes: sizes,
            anchorID: ids[0],
            anchorFrame: NSRect(x: 816, y: 350, width: 100, height: 100),
            workArea: workArea,
            currentOrientation: .identity)

        #expect(layout.orientation == .mirrorX)
        #expect(workArea.contains(try #require(layout.frames[ids[1]])))
    }

    @Test func magneticSwapFieldBuildsGraduallyAndSettlesExactly() {
        let cellSize = CGSize(width: 120, height: 160)
        let target = CGPoint(x: 500, y: 400)
        let centreDistance = GaiCompanionMagneticSwap.normalizedDistance(
            from: target,
            to: target,
            cellSize: cellSize)
        let midwayDistance = GaiCompanionMagneticSwap.normalizedDistance(
            from: CGPoint(x: 440, y: 400),
            to: target,
            cellSize: cellSize)
        let outsideDistance = GaiCompanionMagneticSwap.normalizedDistance(
            from: CGPoint(x: 300, y: 400),
            to: target,
            cellSize: cellSize)

        #expect(GaiCompanionMagneticSwap.influence(
            normalizedDistance: centreDistance) == 1)
        #expect(GaiCompanionMagneticSwap.influence(
            normalizedDistance: midwayDistance) > 0.5)
        #expect(GaiCompanionMagneticSwap.influence(
            normalizedDistance: outsideDistance) == 0)
        #expect(GaiCompanionMagneticSwap.settlePosition(at: 0) == 0)
        #expect(GaiCompanionMagneticSwap.settlePosition(at: 1) == 1)
    }

    @Test func stackCollapseIsTheExactReverseOfOpening() {
        for sample in 0...100 {
            let progress = CGFloat(sample) / 100
            let reversedProgress = 1 - progress
            let expectedPosition = 1
                - GaiCompanionStackMotion.position(at: reversedProgress)
            let expectedOpacity = 1
                - GaiCompanionStackMotion.opacity(at: reversedProgress)

            #expect(abs(
                GaiCompanionStackMotion.collapsePosition(at: progress)
                    - expectedPosition) < 0.000_001)
            #expect(abs(
                GaiCompanionStackMotion.collapseOpacity(at: progress)
                    - expectedOpacity) < 0.000_001)
        }
        #expect(
            GaiCompanionStackMotion.collapseDuration
                == GaiCompanionStackMotion.expansionDuration)

        let duration = GaiCompanionStackMotion.expansionDuration
        for stagger in stride(from: 0.0, through: 0.032, by: 0.008) {
            for elapsed in stride(from: 0.0, through: duration, by: 0.01) {
                let openingAtReversedTime = GaiCompanionStackMotion.localProgress(
                    elapsed: duration - elapsed,
                    duration: duration,
                    stagger: stagger,
                    reversing: false)
                let closing = GaiCompanionStackMotion.localProgress(
                    elapsed: elapsed,
                    duration: duration,
                    stagger: stagger,
                    reversing: true)
                #expect(abs(openingAtReversedTime - (1 - closing)) < 0.000_001)
            }
        }
    }

    @Test func stackOpeningMovesDirectlyToEveryFinalSlot() {
        let samples = (0...100).map {
            GaiCompanionStackMotion.position(at: CGFloat($0) / 100)
        }
        #expect(samples.first == 0)
        #expect(samples.last == 1)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { pair in
            pair.0 <= pair.1
        })
        #expect(samples.allSatisfy { (0...1).contains($0) })
        #expect(GaiCompanionStackMotion.position(at: 0.5) > 0.9)
        #expect(GaiCompanionStackMotion.expansionDuration <= 0.30)
        #expect(GaiCompanionStackMotion.maximumStagger <= 0.032)
    }

    @Test func collapsedStackPreservesEveryRealWindowSize() {
        let anchor = CGRect(x: 720, y: 430, width: 142, height: 174)
        let contentSize = CGSize(width: 184, height: 226)
        let frame = GaiCompanionStackMotion.collapsedFrame(
            contentSize: contentSize,
            around: anchor)

        #expect(frame.size == contentSize)
        #expect(frame.midX == anchor.midX)
        #expect(frame.midY == anchor.midY)
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

    @Test func sharedTerminalBayIsStableAndNeverUsesTheHoveredDoudouAsItsAnchor() {
        let frames = [
            NSRect(x: 520, y: 360, width: 142, height: 174),
            NSRect(x: 642, y: 360, width: 142, height: 174),
            NSRect(x: 520, y: 520, width: 142, height: 174),
            NSRect(x: 642, y: 520, width: 142, height: 174),
        ]
        let arguments = (
            anchorCenter: CGPoint(x: 591, y: 447),
            cellSize: CGSize(width: 122, height: 160),
            terminalSize: CGSize(width: 480, height: 300),
            workArea: NSRect(x: 0, y: 0, width: 1_600, height: 1_000))

        let forward = GaiCompanionTerminalBayLayout.resolve(
            companionFrames: frames,
            anchorCenter: arguments.anchorCenter,
            cellSize: arguments.cellSize,
            terminalSize: arguments.terminalSize,
            workArea: arguments.workArea,
            gap: 8)
        let reversed = GaiCompanionTerminalBayLayout.resolve(
            companionFrames: Array(frames.reversed()),
            anchorCenter: arguments.anchorCenter,
            cellSize: arguments.cellSize,
            terminalSize: arguments.terminalSize,
            workArea: arguments.workArea,
            gap: 8)

        #expect(forward == reversed)
        #expect(arguments.workArea.contains(forward.terminalFrame))
        #expect(frames.allSatisfy {
            $0.intersection(forward.terminalFrame).isNull
        })
    }

    @Test func sharedTerminalBayFlipsAwayFromAPressedScreenEdge() {
        let frames = [
            NSRect(x: 510, y: 780, width: 142, height: 174),
            NSRect(x: 632, y: 780, width: 142, height: 174),
        ]
        let terminal = GaiCompanionTerminalBayLayout.resolve(
            companionFrames: frames,
            anchorCenter: CGPoint(x: 581, y: 867),
            cellSize: CGSize(width: 122, height: 160),
            terminalSize: CGSize(width: 600, height: 300),
            workArea: NSRect(x: 0, y: 0, width: 1_400, height: 1_000),
            gap: 8)

        #expect(terminal.placement == .bottom)
        #expect(terminal.terminalFrame.maxY <= 772.001)
        #expect(frames.allSatisfy {
            $0.intersection(terminal.terminalFrame).isNull
        })
    }

    @Test func sharedTerminalBaySlidesAlongAnEdgeWithoutLeavingTheConstellation() {
        let frames = [
            NSRect(x: 1_210, y: 120, width: 142, height: 174),
            NSRect(x: 1_332, y: 120, width: 142, height: 174),
            NSRect(x: 1_210, y: 280, width: 142, height: 174),
            NSRect(x: 1_332, y: 280, width: 142, height: 174),
        ]
        let terminal = GaiCompanionTerminalBayLayout.resolve(
            companionFrames: frames,
            anchorCenter: CGPoint(x: 1_281, y: 207),
            cellSize: CGSize(width: 122, height: 160),
            terminalSize: CGSize(width: 720, height: 440),
            workArea: NSRect(x: 12, y: 12, width: 1_512, height: 1_120),
            gap: 8)

        let constellationLeft = frames.map(\.minX).min() ?? 0
        #expect(terminal.placement == .left)
        #expect(abs(terminal.terminalFrame.maxX - (constellationLeft - 8)) < 0.001)
        #expect(terminal.terminalFrame.maxX <= 1_524.001)
        #expect(frames.allSatisfy {
            $0.intersection(terminal.terminalFrame).isNull
        })
    }

    @Test func spriteAlphaMaskRejectsTransparentPanelPixels() throws {
        let pixels: [UInt8] = [
            0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10,
        ]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: 3,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent))
        let mask = try #require(GaiCompanionAlphaMask(image: image))

        #expect(mask.contains(normalizedX: 0.5, normalizedY: 0.25))
        #expect(!mask.contains(normalizedX: 0.1, normalizedY: 0.25))
        #expect(!mask.contains(normalizedX: 0.85, normalizedY: 0.75))
        #expect(mask.contains(
            normalizedX: 0.85,
            normalizedY: 0.75,
            threshold: 5))
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

    @Test func windowSpacePoliciesSeparatePersistentOverlaysFromOnDemandUI() {
        let overlay = GaiCompanionSpacePolicy.floatingOverlay
        #expect(overlay.contains(.canJoinAllSpaces))
        #expect(overlay.contains(.canJoinAllApplications))
        #expect(overlay.contains(.stationary))
        #expect(overlay.contains(.ignoresCycle))
        #expect(overlay.contains(.fullScreenAuxiliary))
        #expect(!overlay.contains(.moveToActiveSpace))

        let applicationWindow = GaiCompanionSpacePolicy.onDemandApplicationWindow
        #expect(applicationWindow.contains(.moveToActiveSpace))
        #expect(applicationWindow.contains(.auxiliary))
        #expect(applicationWindow.contains(.managed))
        #expect(applicationWindow.contains(.fullScreenAuxiliary))
        #expect(!applicationWindow.contains(.canJoinAllSpaces))
    }

    @Test func hoverBridgeKeepsOnlyTheDirectPathToTheTerminalAlive() {
        let mascot = NSRect(x: 100, y: 100, width: 80, height: 80)
        let terminal = NSRect(x: 220, y: 70, width: 480, height: 330)

        #expect(GaiCompanionHoverBridge.contains(
            NSPoint(x: 200, y: 140),
            mascotFrame: mascot,
            terminalFrame: terminal))
        #expect(!GaiCompanionHoverBridge.contains(
            NSPoint(x: 200, y: 175),
            mascotFrame: mascot,
            terminalFrame: terminal))
        #expect(GaiCompanionHoverBridge.isProgressing(
            from: NSPoint(x: 160, y: 140),
            to: NSPoint(x: 190, y: 140),
            terminalFrame: terminal))
        #expect(!GaiCompanionHoverBridge.isProgressing(
            from: NSPoint(x: 190, y: 140),
            to: NSPoint(x: 160, y: 140),
            terminalFrame: terminal))
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
