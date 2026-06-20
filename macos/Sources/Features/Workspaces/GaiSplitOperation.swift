#if os(macOS)
import SwiftUI

/// A mutable operation requested by the GaiTerm split view.
enum GaiSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        let payload: Ghostty.SurfaceView
        let destination: Ghostty.SurfaceView
        let zone: GaiSplitDropZone
    }
}

enum GaiSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right
}
#endif
