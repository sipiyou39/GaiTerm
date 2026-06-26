#if os(macOS)
import SwiftUI

enum GaiPaneDragCoordinator {
    private static var activeUntil: TimeInterval = 0
    private static var activePaneID: UUID?

    static var isDraggingPane: Bool {
        ProcessInfo.processInfo.systemUptime < activeUntil
    }

    static var paneID: UUID? {
        isDraggingPane ? activePaneID : nil
    }

    static func begin(_ id: UUID) {
        activePaneID = id
        activeUntil = ProcessInfo.processInfo.systemUptime + 8
    }

    static func keepAlive() {
        activeUntil = ProcessInfo.processInfo.systemUptime + 2
    }

    static func end() {
        activeUntil = 0
        activePaneID = nil
    }
}

/// A mutable operation requested by the GaiTerm split view.
enum GaiSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        let payloadID: UUID
        let destination: Ghostty.SurfaceView
        let zone: GaiSplitDropZone
    }
}

enum GaiSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right
    case center
}
#endif
