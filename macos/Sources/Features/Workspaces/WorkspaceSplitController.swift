#if os(macOS)
import AppKit
import SwiftUI
import GhosttyKit

/// Handles Ghostty's split actions for surfaces living in workspace split
/// trees — GaiTerm's local split handling for surfaces owned by a workspace.
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
    /// Called whenever the set of live/visible panes may have changed.
    var onTopologyDidChange: (() -> Void)?

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

    func persistWorkspaceState() {
        store.save()
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
    func workspace(containing view: Ghostty.SurfaceView) -> GaiWorkspace? {
        (store.workspaces + [store.defaultWorkspace])
            .first { $0.surfaceTree.root?.node(view: view) != nil }
    }

    /// Create a surface for a workspace. Without a base config (the first
    /// pane), it starts in the workspace's default directory/command; splits
    /// pass the config Ghostty derived from the source surface (inherited
    /// pwd etc.).
    private func makeSurface(
        for workspace: GaiWorkspace,
        baseConfig: Ghostty.SurfaceConfiguration?,
        seed: GaiPaneSessionSeed? = nil
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
        config.workingDirectory = seed?.initialDirectoryPath
            ?? config.workingDirectory
            ?? workspace.defaultDirectory?.path
        let surfaceID = UUID()
        config.environmentVariables["GAITERM_WORKSPACE_ID"] = workspace.id.uuidString
        config.environmentVariables["GAITERM_SURFACE_ID"] = surfaceID.uuidString
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sipiyou.gaiterm"
        config.environmentVariables["GAITERM_NOTIFY_BUNDLE_ID"] = bundleIdentifier
        config.environmentVariables["GAITERM_NOTIFY_URL_SCHEME"] =
            bundleIdentifier == "com.sipiyou.gaiterm.debug" ? "gaiterm-debug" : "gaiterm"

        let view = Ghostty.SurfaceView(app, baseConfig: config, uuid: surfaceID)
        store.attachSession(
            for: view,
            in: workspace,
            seed: seed ?? GaiPaneSessionSeed(
                launchCommand: config.command,
                initialDirectoryPath: config.workingDirectory))
        applyPerformanceLayerPolicy(view)
        applyTerminalBackground(view, in: workspace, active: false)
        parkSurface(view)
        return view
    }

    /// Set the engine-rendered terminal background immediately after surface
    /// creation. The SwiftUI backing color alone sits behind Metal; Ghostty's
    /// renderer must receive the same color or the grid stays black.
    private func applyTerminalBackground(
        _ view: Ghostty.SurfaceView,
        in workspace: GaiWorkspace,
        active: Bool
    ) {
        guard let surface = view.surface else { return }
        let tinted = UserDefaults.standard.bool(
            forKey: GaiPreferenceKey.tintGlassWithWorkspaceAccent)
        let rgb = GaiTerminalPaneRGB(
            Color.gaiTerminalPaneColor(
                accent: workspace.accentColor,
                tinted: tinted,
                active: active))
        ghostty_surface_set_background_rgb(surface, rgb.r, rgb.g, rgb.b)
    }

    /// New panes start cheap: no compositing filters, opaque layer hints.
    /// GaiWorkspaceManager later decides which surfaces are actually visible.
    private func applyPerformanceLayerPolicy(_ view: Ghostty.SurfaceView) {
        view.layer?.compositingFilter = nil
        view.layer?.isOpaque = true
        DispatchQueue.main.async {
            view.layer?.compositingFilter = nil
            view.layer?.isOpaque = true
        }
    }

    /// Never let freshly-created or off-stage surfaces render/focus by default.
    private func parkSurface(_ view: Ghostty.SurfaceView) {
        guard let surface = view.surface else { return }
        view.focusDidChange(false)
        ghostty_surface_set_occlusion(surface, false)
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

        if let layout = workspace.restoredPaneLayout {
            if restorePaneLayout(layout, in: workspace, focus: shouldFocus) {
                workspace.restoredPaneLayout = nil
                return
            }
            workspace.restoredPaneLayout = nil
        }

        let plan = workspace.openPlan()
        // Don't warm up workspaces that auto-run a CLI — warming would spawn
        // every workspace's CLIs at launch. A plain-shell plan may still warm.
        let hasCommands = plan.contains { $0.command != nil }
        if hasCommands && !shouldFocus { return }

        openPlannedSurfaces(in: workspace, plan: plan, focus: shouldFocus)
    }

    private func restorePaneLayout(
        _ layout: GaiPaneLayoutData,
        in workspace: GaiWorkspace,
        focus shouldFocus: Bool
    ) -> Bool {
        var launchQueue: [(command: String, view: Ghostty.SurfaceView)] = []
        guard let root = makeNode(from: layout, in: workspace, launchQueue: &launchQueue) else {
            return false
        }
        workspace.surfaceTree = SplitTree(root: root, zoomed: nil)
        onTopologyDidChange?()

        for item in launchQueue {
            runCommand(item.command, in: item.view)
        }
        if shouldFocus, let first = workspace.surfaceTree.root?.leftmostLeaf() {
            focus(first)
        }
        return true
    }

    private func makeNode(
        from layout: GaiPaneLayoutData,
        in workspace: GaiWorkspace,
        launchQueue: inout [(command: String, view: Ghostty.SurfaceView)]
    ) -> SplitTree<Ghostty.SurfaceView>.Node? {
        switch layout {
        case .pane(let pane):
            var cfg = Ghostty.SurfaceConfiguration()
            cfg.workingDirectory = pane.directoryPath ?? workspace.defaultDirectory?.path
            let seed = GaiPaneSessionSeed(
                id: pane.id,
                name: pane.name,
                notificationsEnabled: pane.notificationsEnabled,
                autoFocusOnNotification: pane.autoFocusOnNotification,
                launchCommand: pane.command,
                initialDirectoryPath: cfg.workingDirectory)
            guard let view = makeSurface(for: workspace, baseConfig: cfg, seed: seed) else {
                return nil
            }
            if let command = pane.command,
               !shouldDeferRestoredAgentCommand(command) {
                launchQueue.append((command, view))
            }
            return .leaf(view: view)

        case .split(let direction, let ratio, let leftLayout, let rightLayout):
            guard let left = makeNode(from: leftLayout, in: workspace, launchQueue: &launchQueue),
                  let right = makeNode(from: rightLayout, in: workspace, launchQueue: &launchQueue)
            else { return nil }
            return .split(.init(
                direction: direction.splitDirection,
                ratio: ratio,
                left: left,
                right: right))
        }
    }

    /// Opens the first pane in an empty workspace using an optional inherited
    /// Ghostty surface config. The terminal is rooted in the stage, not in a
    /// classic terminal window.
    @discardableResult
    func openRootSurface(
        in workspace: GaiWorkspace,
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        seed: GaiPaneSessionSeed? = nil,
        focus shouldFocus: Bool = true
    ) -> Ghostty.SurfaceView? {
        guard workspace.surfaceTree.isEmpty else { return workspace.surfaceTree.root?.leftmostLeaf() }
        let resolvedSeed = seed ?? GaiPaneSessionSeed(
            launchCommand: baseConfig?.command,
            initialDirectoryPath: baseConfig?.workingDirectory ?? workspace.defaultDirectory?.path)
        guard let view = makeSurface(for: workspace, baseConfig: baseConfig, seed: resolvedSeed) else { return nil }
        workspace.surfaceTree = SplitTree(view: view)
        onTopologyDidChange?()
        if shouldFocus { focus(view) }
        return view
    }

    /// Open an even grid of panes from an open-plan — each pane in its own
    /// directory, running its command (the way the user would: open a terminal,
    /// type `claude`, ⏎). One pane per plan entry.
    ///
    /// The grid is built column-first: `cols = ⌈√n⌉` equal columns, each filled
    /// with as-even-as-possible rows. `equalized()` then weights every split by
    /// its leaf count, so all panes end up the same size (best effort for odd
    /// counts — the short column just gets fewer rows).
    private func openPlannedSurfaces(
        in workspace: GaiWorkspace,
        plan: [(command: String?, directory: URL?)],
        focus shouldFocus: Bool
    ) {
        let n = plan.count
        guard n > 0 else { return }

        let cols = max(1, Int(Double(n).squareRoot().rounded(.up)))
        var rowsPerColumn = [Int](repeating: n / cols, count: cols)
        for i in 0..<(n % cols) { rowsPerColumn[i] += 1 }

        // The first plan index of each column (its top pane).
        var columnStart = [Int](repeating: 0, count: cols)
        for c in 1..<cols { columnStart[c] = columnStart[c - 1] + rowsPerColumn[c - 1] }

        // A surface config carrying this pane's starting directory, so the shell
        // opens there before we type its command.
        func config(for index: Int) -> Ghostty.SurfaceConfiguration {
            var cfg = Ghostty.SurfaceConfiguration()
            cfg.workingDirectory = (plan[index].directory ?? workspace.defaultDirectory)?.path
            return cfg
        }

        let firstSeed = GaiPaneSessionSeed(
            launchCommand: plan[0].command,
            initialDirectoryPath: (plan[0].directory ?? workspace.defaultDirectory)?.path)
        guard let first = makeSurface(for: workspace, baseConfig: config(for: 0), seed: firstSeed) else { return }
        workspace.surfaceTree = SplitTree(view: first)

        // The top pane of each column (created by splitting the previous top
        // rightward).
        var columnTops = [first]
        for c in 1..<cols {
            guard let top = newSplit(
                in: workspace, at: columnTops[c - 1], direction: .right,
                baseConfig: config(for: columnStart[c]),
                seed: GaiPaneSessionSeed(
                    launchCommand: plan[columnStart[c]].command,
                    initialDirectoryPath: (plan[columnStart[c]].directory ?? workspace.defaultDirectory)?.path)) else { break }
            columnTops.append(top)
        }

        // Fill each column downward, recording each pane at its plan index.
        var views = [Ghostty.SurfaceView?](repeating: nil, count: n)
        for (c, top) in columnTops.enumerated() {
            let start = columnStart[c]
            views[start] = top
            var last = top
            for r in 1..<rowsPerColumn[c] {
                let idx = start + r
                guard let view = newSplit(
                    in: workspace, at: last, direction: .down,
                    baseConfig: config(for: idx),
                    seed: GaiPaneSessionSeed(
                        launchCommand: plan[idx].command,
                        initialDirectoryPath: (plan[idx].directory ?? workspace.defaultDirectory)?.path)) else { break }
                views[idx] = view
                last = view
            }
        }

        workspace.surfaceTree = workspace.surfaceTree.equalized()
        onTopologyDidChange?()

        for (index, view) in views.enumerated() {
            guard let view, let command = plan[index].command else { continue }
            runCommand(command, in: view)
        }
        if shouldFocus { focus(first) }
    }

    /// Run a command in a freshly-opened pane once its shell is up: type the
    /// text, then press a real Return key (not a `\r` in the text, which the
    /// shell's bracketed-paste mode would leave pasted-but-unexecuted).
    private func runCommand(_ command: String, in view: Ghostty.SurfaceView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let surface = view.surfaceModel else { return }
            surface.sendText(command)
            surface.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
            surface.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .release))
        }
    }

    /// Restoring a pane layout should rebuild the user's workspace, not silently
    /// re-enter a previous agent conversation. Codex/Claude resume from the
    /// explicit resume prompt instead.
    private func shouldDeferRestoredAgentCommand(_ command: String) -> Bool {
        GaiAgentKind.fromLaunchCommand(command) != nil
    }

    /// Split the given surface (or the workspace's first pane when nil —
    /// used by the header button) in a direction.
    @discardableResult
    func newSplit(
        in workspace: GaiWorkspace,
        at target: Ghostty.SurfaceView?,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        seed: GaiPaneSessionSeed? = nil
    ) -> Ghostty.SurfaceView? {
        guard let at = target ?? workspace.surfaceTree.root?.leftmostLeaf() else { return nil }
        let resolvedSeed = seed ?? GaiPaneSessionSeed(
            launchCommand: baseConfig?.command,
            initialDirectoryPath: baseConfig?.workingDirectory ?? workspace.defaultDirectory?.path)
        guard let newView = makeSurface(for: workspace, baseConfig: baseConfig, seed: resolvedSeed) else { return nil }
        do {
            workspace.surfaceTree = try workspace.surfaceTree.inserting(
                view: newView, at: at, direction: direction)
            workspace.surfaceTree = workspace.surfaceTree.equalized()
        } catch {
            Ghostty.logger.warning("failed to insert split: \(error, privacy: .public)")
            store.detachSession(for: newView, in: workspace)
            newView.gaiReleaseTerminalSurface()
            return nil
        }
        onTopologyDidChange?()
        focus(newView)
        return newView
    }

    /// Divider drags & drag-and-drop rearranging from the stage split view.
    func performSplitAction(_ workspace: GaiWorkspace, _ action: GaiSplitOperation) {
        switch action {
        case .resize(let resize):
            let resized = resize.node.resizing(to: resize.ratio)
            do {
                workspace.surfaceTree = try workspace.surfaceTree.replacing(
                    node: resize.node, with: resized)
                onTopologyDidChange?()
            } catch {
                Ghostty.logger.warning("failed split resize: \(error, privacy: .public)")
            }

        case .drop(let drop):
            guard let payload = workspace.surfaceTree.first(where: { $0.id == drop.payloadID }) else { return }
            guard payload !== drop.destination else { return }
            if drop.zone == .center {
                swapPanes(in: workspace, source: payload, destination: drop.destination)
                return
            }

            let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch drop.zone {
            case .top: .up
            case .bottom: .down
            case .left: .left
            case .right: .right
            case .center: .right
            }
            // v1: only moves within the same workspace tree.
            guard let sourceNode = workspace.surfaceTree.root?.node(view: payload) else { return }
            let without = workspace.surfaceTree.removing(sourceNode)
            do {
                workspace.surfaceTree = try without.inserting(
                    view: payload, at: drop.destination, direction: direction)
            } catch {
                Ghostty.logger.warning("failed split drop: \(error, privacy: .public)")
                return
            }
            onTopologyDidChange?()
            focus(payload)
        }
    }

    private func swapPanes(
        in workspace: GaiWorkspace,
        source: Ghostty.SurfaceView,
        destination: Ghostty.SurfaceView
    ) {
        guard let root = workspace.surfaceTree.root else { return }
        workspace.surfaceTree = SplitTree(
            root: root.gaiSwappingLeaves(source, destination),
            zoomed: nil)
        onTopologyDidChange?()
        focus(source)
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
        onTopologyDidChange?()
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

    /// Close a pane (header ✗ button). No confirmation, ever: this is a
    /// floating, always-on-top stage, so a modal `NSAlert` would open *behind*
    /// the status-bar-level panel and silently block the close — the pane would
    /// just refuse to die with an invisible dialog waiting offscreen. Clicking
    /// our ✗ closes the terminal, full stop. Ghostty's own confirm-close
    /// machinery is deliberately bypassed.
    func closePane(in workspace: GaiWorkspace, surface: Ghostty.SurfaceView) {
        removePane(in: workspace, surface: surface)
    }

    private func removePane(in workspace: GaiWorkspace, surface: Ghostty.SurfaceView) {
        guard let node = workspace.surfaceTree.root?.node(view: surface) else { return }

        let newTree = workspace.surfaceTree.removing(node)
        workspace.surfaceTree = newTree
        store.detachSession(for: surface, in: workspace)
        surface.gaiReleaseTerminalSurface()
        onTopologyDidChange?()

        if let next = newTree.root?.leftmostLeaf() {
            focus(next)
        } else {
            onTreeDidEmpty?(workspace)
        }
    }

    /// Reopen a pane in a different folder: swap its surface for a fresh one
    /// rooted at `directory`, in place (same split slot & size). Used by the
    /// folder selector in the pane header. The old shell/CLI process is
    /// discarded, but the pane's agent identity is preserved so restart-time
    /// resume can still match Codex/Claude sessions by this pane's new folder.
    @discardableResult
    func reopenPane(
        in workspace: GaiWorkspace,
        surface oldView: Ghostty.SurfaceView,
        directory: String?,
        command: String? = nil
    ) -> Ghostty.SurfaceView? {
        guard let oldNode = workspace.surfaceTree.root?.node(view: oldView) else { return nil }

        var cfg = Ghostty.SurfaceConfiguration()
        cfg.workingDirectory = directory ?? workspace.defaultDirectory?.path
        let oldSession = workspace.session(for: oldView)
        let seed = GaiPaneSessionSeed(
            id: oldSession?.id,
            name: oldSession?.name,
            notificationsEnabled: oldSession?.notificationsEnabled ?? true,
            autoFocusOnNotification: oldSession?.autoFocusOnNotification ?? false,
            launchCommand: command ?? oldSession?.launchCommand,
            initialDirectoryPath: cfg.workingDirectory)
        guard let newView = makeSurface(for: workspace, baseConfig: cfg, seed: seed) else { return nil }

        // Drop a stale zoom on the pane being replaced so the tree stays valid.
        let tree = workspace.surfaceTree.zoomed == oldNode
            ? SplitTree(root: workspace.surfaceTree.root, zoomed: nil)
            : workspace.surfaceTree
        do {
            workspace.surfaceTree = try tree.replacing(node: oldNode, with: .leaf(view: newView))
        } catch {
            Ghostty.logger.warning("failed to reopen pane: \(error, privacy: .public)")
            store.detachSession(for: newView, in: workspace)
            newView.gaiReleaseTerminalSurface()
            return nil
        }
        store.detachSession(for: oldView, in: workspace)
        oldView.gaiReleaseTerminalSurface()
        onTopologyDidChange?()
        if let command {
            runCommand(command, in: newView)
        }
        focus(newView)
        return newView
    }

    @discardableResult
    func openAgentResumePane(
        in workspace: GaiWorkspace,
        command: String,
        directory: String?
    ) -> Ghostty.SurfaceView? {
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.workingDirectory = directory ?? workspace.defaultDirectory?.path
        let seed = GaiPaneSessionSeed(
            launchCommand: command,
            initialDirectoryPath: cfg.workingDirectory)

        let view: Ghostty.SurfaceView?
        if workspace.surfaceTree.isEmpty {
            view = openRootSurface(in: workspace, baseConfig: cfg, seed: seed, focus: true)
        } else {
            view = newSplit(in: workspace, at: nil, direction: .right, baseConfig: cfg, seed: seed)
        }
        if let view {
            runCommand(command, in: view)
        }
        return view
    }

    @objc private func didRequestCloseSurface(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let workspace = workspace(containing: target) else { return }
        removePane(in: workspace, surface: target)
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
        onTopologyDidChange?()
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

private extension SplitTree<Ghostty.SurfaceView>.Node {
    func gaiSwappingLeaves(
        _ source: Ghostty.SurfaceView,
        _ destination: Ghostty.SurfaceView
    ) -> Self {
        switch self {
        case .leaf(let view):
            if view === source { return .leaf(view: destination) }
            if view === destination { return .leaf(view: source) }
            return self

        case .split(let split):
            return .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: split.left.gaiSwappingLeaves(source, destination),
                right: split.right.gaiSwappingLeaves(source, destination)))
        }
    }
}
#endif
