#if os(macOS)
import AppKit
import SwiftUI
import GhosttyKit

/// Handles Ghostty's split actions for surfaces living in workspace split
/// trees — a slim mirror of `BaseTerminalController`'s split handling, but
/// the tree belongs to a `GaiWorkspace` instead of a window controller.
///
/// All Ghostty split notifications are global; like every other handler we
/// guard by membership: we only act when the target surface lives in one of
/// our workspaces' trees, so regular terminal windows are never affected
/// (and vice versa).
final class GaiSplitController {
    private let store: GaiWorkspaceStore
    private let ghostty: Ghostty.App

    /// Called when a workspace's tree becomes empty (its last pane closed),
    /// so the owner can dismiss the stage.
    var onTreeDidEmpty: ((GaiWorkspace) -> Void)?

    init(store: GaiWorkspaceStore, ghostty: Ghostty.App) {
        self.store = store
        self.ghostty = ghostty

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(didRequestNewSplit(_:)),
            name: Ghostty.Notification.ghosttyNewSplit, object: nil)
        center.addObserver(
            self, selector: #selector(didRequestCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
        center.addObserver(
            self, selector: #selector(didRequestEqualize(_:)),
            name: Ghostty.Notification.didEqualizeSplits, object: nil)
        center.addObserver(
            self, selector: #selector(didRequestFocusSplit(_:)),
            name: Ghostty.Notification.ghosttyFocusSplit, object: nil)
        center.addObserver(
            self, selector: #selector(didRequestResizeSplit(_:)),
            name: Ghostty.Notification.didResizeSplit, object: nil)
        center.addObserver(
            self, selector: #selector(didRequestToggleZoom(_:)),
            name: Ghostty.Notification.didToggleSplitZoom, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Header click resolution

    /// All header controls whose AppKit frame contains the click (window
    /// coordinates, bottom-left origin on both sides). Frames bigger than
    /// any plausible header control are ignored as stale.
    static func catcherViews(
        at windowPoint: NSPoint,
        in root: NSView
    ) -> [GaiClickCatcher.CatcherView] {
        var found: [GaiClickCatcher.CatcherView] = []
        func walk(_ view: NSView) {
            if let catcher = view as? GaiClickCatcher.CatcherView,
               !catcher.isHidden,
               catcher.bounds.width <= 320, catcher.bounds.height <= 48,
               catcher.convert(catcher.bounds, to: nil).contains(windowPoint) {
                found.append(catcher)
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(root)
        return found
    }

    // MARK: Surfaces

    /// The workspace whose tree contains the given surface, if any.
    private func workspace(containing view: Ghostty.SurfaceView) -> GaiWorkspace? {
        store.workspaces.first { $0.surfaceTree.root?.node(view: view) != nil }
    }

    /// Create a surface for a workspace. Without a base config (the first
    /// pane), it starts in the workspace's default directory/command; splits
    /// pass the config Ghostty derived from the source surface (inherited
    /// pwd etc.).
    private func makeSurface(
        for workspace: GaiWorkspace,
        baseConfig: Ghostty.SurfaceConfiguration?
    ) -> Ghostty.SurfaceView? {
        guard let app = ghostty.app else {
            Ghostty.logger.warning("cannot create surface: ghostty app not loaded")
            return nil
        }
        var config = baseConfig ?? {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = workspace.defaultDirectory?.path
            config.command = workspace.defaultCommand
            return config
        }()
        if config.workingDirectory == nil {
            config.workingDirectory = workspace.defaultDirectory?.path
        }
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        store.attachSession(for: view, in: workspace)
        applyInteriorBlend(view)
        return view
    }

    /// Screen-blend the surface's Metal layer so its theme background melts
    /// into the stage's gray fill beneath (see `WorkspaceStage`). Asserted
    /// now and on the next runloop turn in case the layer attaches late.
    private func applyInteriorBlend(_ view: Ghostty.SurfaceView) {
        view.layer?.compositingFilter = "screenBlendMode"
        DispatchQueue.main.async {
            view.layer?.compositingFilter = "screenBlendMode"
        }
    }

    // MARK: Tree operations

    /// Make sure the workspace shows a terminal: called when the Scène
    /// opens a workspace. Creates the first pane if the tree is empty.
    ///
    /// Warm-up (`focus: false`) pre-creates the pane the moment a workspace
    /// exists, so opening or switching to it never has to spawn one on the
    /// fly — that lazy spawn made the stage visibly jump as the pane popped
    /// in. Warm-up must not steal focus from the user's current terminal.
    func ensureFirstSurface(in workspace: GaiWorkspace, focus shouldFocus: Bool = true) {
        guard workspace.surfaceTree.isEmpty else { return }
        guard let view = makeSurface(for: workspace, baseConfig: nil) else { return }
        workspace.surfaceTree = SplitTree(view: view)
        if shouldFocus { focus(view) }
    }

    /// Split the given surface (or the workspace's first pane when nil —
    /// used by the header button) in a direction.
    @discardableResult
    func newSplit(
        in workspace: GaiWorkspace,
        at target: Ghostty.SurfaceView?,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        guard let at = target ?? workspace.surfaceTree.root?.leftmostLeaf() else { return nil }
        guard let newView = makeSurface(for: workspace, baseConfig: baseConfig) else { return nil }
        do {
            workspace.surfaceTree = try workspace.surfaceTree.inserting(
                view: newView, at: at, direction: direction)
        } catch {
            Ghostty.logger.warning("failed to insert split: \(error, privacy: .public)")
            return nil
        }
        focus(newView)
        return newView
    }

    /// Divider drags & drag-and-drop rearranging from `TerminalSplitTreeView`.
    func performSplitAction(_ workspace: GaiWorkspace, _ action: TerminalSplitOperation) {
        switch action {
        case .resize(let resize):
            let resized = resize.node.resizing(to: resize.ratio)
            do {
                workspace.surfaceTree = try workspace.surfaceTree.replacing(
                    node: resize.node, with: resized)
            } catch {
                Ghostty.logger.warning("failed split resize: \(error, privacy: .public)")
            }

        case .drop(let drop):
            let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch drop.zone {
            case .top: .up
            case .bottom: .down
            case .left: .left
            case .right: .right
            }
            // v1: only moves within the same workspace tree.
            guard let sourceNode = workspace.surfaceTree.root?.node(view: drop.payload) else { return }
            let without = workspace.surfaceTree.removing(sourceNode)
            do {
                workspace.surfaceTree = try without.inserting(
                    view: drop.payload, at: drop.destination, direction: direction)
            } catch {
                Ghostty.logger.warning("failed split drop: \(error, privacy: .public)")
                return
            }
            focus(drop.payload)
        }
    }

    /// Zoom a pane to fill the whole card (or restore it). Mirrors Ghostty's
    /// native split zoom, so ⇧⌘↩ and the header button share the state.
    func toggleZoom(in workspace: GaiWorkspace, surface: Ghostty.SurfaceView) {
        let tree = workspace.surfaceTree
        guard let node = tree.root?.node(view: surface) else { return }
        if tree.zoomed == node {
            workspace.surfaceTree = SplitTree(root: tree.root, zoomed: nil)
        } else {
            guard tree.isSplit else { return }
            workspace.surfaceTree = SplitTree(root: tree.root, zoomed: node)
        }
        focus(surface)
    }

    private func focus(_ view: Ghostty.SurfaceView) {
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: view)
        }
    }

    // MARK: Notifications

    @objc private func didRequestNewSplit(_ notification: Notification) {
        guard let oldView = notification.object as? Ghostty.SurfaceView else { return }
        guard let workspace = workspace(containing: oldView) else { return }

        let config = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
            as? Ghostty.SurfaceConfiguration

        guard let directionAny = notification.userInfo?["direction"],
              let direction = directionAny as? ghostty_action_split_direction_e else { return }
        let splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: splitDirection = .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: splitDirection = .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: splitDirection = .down
        case GHOSTTY_SPLIT_DIRECTION_UP: splitDirection = .up
        default: return
        }

        newSplit(in: workspace, at: oldView, direction: splitDirection, baseConfig: config)
    }

    /// Close a pane (header ✗ button), confirming when the surface says its
    /// process needs it.
    func closePane(in workspace: GaiWorkspace, surface: Ghostty.SurfaceView) {
        removePane(in: workspace, surface: surface, needsConfirm: surface.needsConfirmQuit)
    }

    private func removePane(
        in workspace: GaiWorkspace,
        surface: Ghostty.SurfaceView,
        needsConfirm: Bool
    ) {
        guard let node = workspace.surfaceTree.root?.node(view: surface) else { return }

        if needsConfirm {
            let alert = NSAlert()
            alert.messageText = "Close terminal?"
            alert.informativeText =
                "The terminal still has a running process. " +
                "If you close it, the process will be killed."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let newTree = workspace.surfaceTree.removing(node)
        workspace.surfaceTree = newTree
        store.detachSession(for: surface, in: workspace)

        if let next = newTree.root?.leftmostLeaf() {
            focus(next)
        } else {
            onTreeDidEmpty?(workspace)
        }
    }

    @objc private func didRequestCloseSurface(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let workspace = workspace(containing: target) else { return }
        removePane(
            in: workspace,
            surface: target,
            needsConfirm: (notification.userInfo?["process_alive"] as? Bool) ?? false)
    }

    @objc private func didRequestToggleZoom(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let workspace = workspace(containing: target) else { return }
        toggleZoom(in: workspace, surface: target)
    }

    @objc private func didRequestEqualize(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let workspace = workspace(containing: target) else { return }
        workspace.surfaceTree = workspace.surfaceTree.equalized()
    }

    @objc private func didRequestFocusSplit(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let workspace = workspace(containing: target) else { return }
        guard let targetNode = workspace.surfaceTree.root?.node(view: target) else { return }

        guard let directionAny = notification.userInfo?[Ghostty.Notification.SplitDirectionKey],
              let direction = directionAny as? Ghostty.SplitFocusDirection else { return }

        guard let next = workspace.surfaceTree.focusTarget(
            for: direction.toSplitTreeFocusDirection(),
            from: targetNode) else { return }

        DispatchQueue.main.async {
            Ghostty.moveFocus(to: next, from: target)
        }
    }

    @objc private func didRequestResizeSplit(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let workspace = workspace(containing: target) else { return }
        guard let targetNode = workspace.surfaceTree.root?.node(view: target) else { return }

        guard let directionAny = notification.userInfo?[Ghostty.Notification.ResizeSplitDirectionKey],
              let direction = directionAny as? Ghostty.SplitResizeDirection else { return }
        guard let amountAny = notification.userInfo?[Ghostty.Notification.ResizeSplitAmountKey],
              let amount = amountAny as? UInt16 else { return }

        let spatialDirection: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
        switch direction {
        case .up: spatialDirection = .up
        case .down: spatialDirection = .down
        case .left: spatialDirection = .left
        case .right: spatialDirection = .right
        }

        let bounds = CGRect(origin: .zero, size: workspace.surfaceTree.viewBounds())
        do {
            workspace.surfaceTree = try workspace.surfaceTree.resizing(
                node: targetNode, by: amount, in: spatialDirection, with: bounds)
        } catch {
            Ghostty.logger.warning("failed split keyboard resize: \(error, privacy: .public)")
        }
    }
}
#endif
