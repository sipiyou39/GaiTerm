#if os(macOS)
import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// Transient UI state for the floating workspaces system.
final class GaiWorkspaceUIModel: ObservableObject {
    /// Whether the drawer is open. Toggled by the pull tab.
    @Published var isExpanded: Bool = false
    /// The workspace selected in the drawer.
    @Published var selectedWorkspaceID: GaiWorkspace.ID?
    /// Current card height (rows + chrome, capped to the screen). Owned by
    /// the manager so the panel frames and the SwiftUI slab always agree.
    @Published var cardHeight: CGFloat = GaiDrawerMetrics.cardHeight(forRows: 1)
    /// The pane session whose name is being edited inline. Lives in the
    /// model — not in any pane view — so no re-render can drop the editing
    /// state mid-flight.
    @Published var renamingSession: GaiTerminalSession?

    /// The workspace currently open in the in-drawer editor (rename / color /
    /// delete), or `nil` when the drawer shows the workspace list. Driving it
    /// from the model lets the manager grow the card and make the panel
    /// keyboard-eligible for the editor's text fields.
    @Published var editingWorkspaceID: GaiWorkspace.ID?

    /// Whether the editor is in the view tree. Flipped on once the card reaches
    /// its open size — its one heavy layout pass is paid here (on a ~still card,
    /// invisible). Kept separate from `editorContentVisible` so the fade can run
    /// on an already-laid-out view (a progressive crossfade, not a snap).
    @Published var editorMounted: Bool = false

    /// The editor's opacity gate, flipped one tick *after* `editorMounted` so the
    /// fade is a pure opacity animation on the already-mounted palette.
    @Published var editorContentVisible: Bool = false

    /// Whether the (future) file-explorer panel is open. Drives a much taller
    /// card expansion than the editor — for testing the larger window size.
    @Published var explorerOpen: Bool = false

    /// Whether the terminal stage is slid out (true) or tucked to its
    /// right-edge pull tab (false). Mirrors `isExpanded` for the drawer.
    @Published var isStageExpanded: Bool = false
    /// Visible width of the terminal card when the stage is out. Owned by the
    /// manager (depends on the screen) so the panel frames and the SwiftUI
    /// slab always agree — same contract as `cardHeight` for the drawer.
    @Published var stageCardWidth: CGFloat = 600

    /// True while the stage slab is mid-slide. Lets each terminal surface drop
    /// its expensive screen-blend compositing while it's moving across the
    /// screen (see `GaiBlendAsserter`) — the per-frame backdrop blend of many
    /// busy panes is what makes the slide stutter. Reference-counted so
    /// overlapping slides (e.g. click-outside folding both panels) don't clear
    /// it early.
    @Published private(set) var isSliding: Bool = false
    private var slideDepth: Int = 0
    func beginSlide() {
        slideDepth += 1
        if !isSliding { isSliding = true }
    }
    func endSlide() {
        slideDepth = max(0, slideDepth - 1)
        if slideDepth == 0, isSliding { isSliding = false }
    }
}

/// `NSHostingView` that accepts the first mouse click, so a single click on
/// the (non-key) floating panel registers immediately.
private class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// Stage hosting view: takes over hit-testing at the root so header controls
/// and terminal surfaces are routed deterministically:
///
/// 1. header controls (a `GaiClickCatcher.CatcherView`, smallest match wins),
/// 2. terminal surfaces, resolved via AppKit's native hit-testing
///    (`super.hitTest`) walked up to the enclosing `SurfaceView` — the same
///    pipeline Ghostty's own terminal windows use, reliable now that each
///    split leaf carries a stable `.id()`,
/// 3. everything else falls back to the normal pipeline.
///
/// One synchronous path, no event monitors, no re-posting.
private final class StageHostingView<Content: View>: FirstMouseHostingView<Content> {
    var surfacesProvider: () -> [Ghostty.SurfaceView] = { [] }

    /// Rendered rect of a header control in this hosting view's coordinate
    /// space, measured through the *layer* tree so it reflects what's drawn.
    private func renderedRect(of view: NSView) -> CGRect? {
        guard let viewLayer = view.layer, let hostLayer = self.layer else { return nil }
        return viewLayer.convert(viewLayer.bounds, to: hostLayer)
    }

    /// Walk up from an AppKit hit to the terminal surface that contains it.
    private func enclosingSurface(of view: NSView?) -> Ghostty.SurfaceView? {
        var cur = view
        while let c = cur {
            if let surface = c as? Ghostty.SurfaceView { return surface }
            cur = c.superview
        }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        // The hit point in our own (flipped) coordinate space — the same
        // space `renderedRect` reports in.
        let local = convert(point, from: superview)

        // 1. Header controls: smallest rendered match wins.
        var bestCatcher: (view: NSView, area: CGFloat)?
        func walk(_ view: NSView) {
            if let catcher = view as? GaiClickCatcher.CatcherView,
               !catcher.isHidden,
               catcher.bounds.width <= 320, catcher.bounds.height <= 48,
               let rect = renderedRect(of: catcher),
               rect.contains(local) {
                let area = rect.width * rect.height
                if bestCatcher == nil || area < bestCatcher!.area {
                    bestCatcher = (catcher, area)
                }
            }
            view.subviews.forEach(walk)
        }
        walk(self)
        if let bestCatcher {
            return bestCatcher.view
        }

        // 2. Terminal surfaces: defer to AppKit's native hit-testing and
        // resolve the enclosing surface. Now that each split leaf carries a
        // stable `.id()`, SwiftUI no longer recycles one pane's platform
        // container for a different surface, so AppKit routes the click to
        // the pane actually under the cursor — the same pipeline Ghostty's
        // own terminal windows rely on. The previous hand-rolled layer-rect
        // math measured rendered frames itself and misrouted clicks across
        // re-renders ("casino" selection).
        let native = super.hitTest(point)
        if let surface = enclosingSurface(of: native) { return surface }
        return native
    }
}

/// Owns the single always-visible floating panel hosting the workspaces
/// drawer: a Liquid Glass slab (card + pull tab in one shape) welded to the
/// left screen edge.
///
/// The panel itself is never animated — window-frame animation is choppy and
/// forces the glass to re-sample its backdrop on every main-thread frame.
/// Instead the slab slides inside the panel with a GPU-composited SwiftUI
/// spring (see `WorkspaceDrawerView`), and the panel just *snaps* between two
/// frames at pixel-identical moments:
///
/// - open frame: the full drawer, card flush with the screen edge;
/// - resting closed frame: shrunk tight around the peeking tab, with the card
///   region off-screen to the left, so the panel never sits as an invisible
///   click-blocking layer over other apps.
final class GaiWorkspaceManager {
    let store: GaiWorkspaceStore
    let ui = GaiWorkspaceUIModel()

    private let ghostty: Ghostty.App
    private(set) lazy var splits: GaiSplitController = {
        let controller = GaiSplitController(store: store, ghostty: ghostty)
        controller.onTreeDidEmpty = { [weak self] workspace in
            if self?.store.openWorkspaceID == workspace.id {
                self?.store.openWorkspaceID = nil
            }
        }
        return controller
    }()
    private var panel: NSPanel?
    private var stagePanel: NSPanel?
    /// Height the drawer *window* is sized for. Kept separate from
    /// `ui.cardHeight` (the SwiftUI slab's animated height) so the editor can
    /// resize the transparent window invisibly while the visible glass slab
    /// springs to its new height — see `updateWorkspaceEditor`.
    private var panelContentHeight: CGFloat = GaiDrawerMetrics.cardHeight(forRows: 1)
    private var cancellables: Set<AnyCancellable> = []
    private var clickOutsideLocal: Any?
    private var clickOutsideGlobal: Any?

    /// Transparent margins around the slab in the open frame so the glass can
    /// cast its light and shadow without being clipped at the window edge.
    private let openRightMargin: CGFloat = 40
    private let openVerticalMargin: CGFloat = 32
    /// Margin around the tab in the resting closed frame.
    private let closedMargin: CGFloat = 14

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        self.store = GaiWorkspaceStore(ghostty: ghostty)
    }

    // MARK: Lifecycle

    func start() {
        // Idempotent: launch can reach this from several paths.
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        seedDemoWorkspacesIfNeeded()
        warmFirstSurfaces()
        recomputeCardHeight()
        ensurePanel()
        snapPanel(open: false)
        panel?.orderFrontRegardless()
        (panel as? FloatingPanel)?.latchMaterialActive()
        registerObservers()

        if ProcessInfo.processInfo.environment["GAI_AUTOEXPAND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.ui.isExpanded = true
            }
        }
        // Reproduces the exact reported scenario end to end: focus pane B,
        // synthesize a real mouse click (through NSApp's event queue, local
        // monitors and all) on pane A's rename zone, so the inline editor
        // must appear while B keeps focus.
        if ProcessInfo.processInfo.environment["GAI_CLICKTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.runRenameClickTest()
            }
        }

        if let autostage = ProcessInfo.processInfo.environment["GAI_AUTOSTAGE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let first = self.store.workspaces.first else { return }
                self.ui.selectedWorkspaceID = first.id
                self.store.openWorkspaceID = first.id
                // N panes for testing: the first comes from opening the
                // stage, the rest from alternating splits.
                let extra = max((Int(autostage) ?? 1) - 1, 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    for i in 0..<extra {
                        self.splits.newSplit(
                            in: first,
                            at: nil,
                            direction: i.isMultiple(of: 2) ? .right : .down)
                    }
                }
            }
        }
    }

    private func runRenameClickTest() {
        guard let stagePanel,
              let workspace = store.workspace(for: store.openWorkspaceID),
              workspace.sessions.count >= 2,
              let contentView = stagePanel.contentView
        else {
            NSLog("GAICLICKTEST preconditions failed")
            return
        }
        let renameTarget = workspace.sessions[0]
        let focusTarget = workspace.sessions[1]
        NSLog("GAICLICKTEST focusing %@, will click title of %@",
              focusTarget.name, renameTarget.name)
        Ghostty.moveFocus(to: focusTarget.surfaceView)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            // Pane A is top-left: its title block sits a few points into the
            // header band. (Top-left origin → AppKit bottom-left origin.)
            let topLeftPoint = CGPoint(
                x: GaiStageMetrics.shadowMargin + 35,
                y: GaiStageMetrics.shadowMargin + GaiStageMetrics.paneHeaderHeight / 2)
            let windowPoint = NSPoint(
                x: topLeftPoint.x,
                y: contentView.bounds.height - topLeftPoint.y)
            NSLog("GAICLICKTEST clicking title of %@ at window=%@",
                  renameTarget.name, NSStringFromPoint(windowPoint))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: stagePanel.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let editing = self.ui.renamingSession === renameTarget
                NSLog("GAICLICKTEST test1 (title click opens rename): %@",
                      editing ? "PASS" : "FAIL")
                self.ui.renamingSession = nil
                self.runTerminalClickTest(renameTarget: renameTarget)
            }
        }
    }

    /// Test 3: with 4 panes, a click in each quadrant must focus THAT pane,
    /// deterministically. Also dumps the AppKit frames of every surface and
    /// helper view to expose any overlap.
    private func runQuadrantFocusTest() {
        guard let stagePanel,
              let contentView = stagePanel.contentView,
              let workspace = store.workspace(for: store.openWorkspaceID)
        else { return }

        // Frame dump: who actually covers what, in window coordinates.
        func dump(_ view: NSView) {
            let cls = String(describing: type(of: view))
            if cls.contains("SurfaceView") || cls.contains("AsserterView")
                || cls.contains("CatcherView") {
                NSLog("GAIDUMP %@ frame=%@", cls,
                      NSStringFromRect(view.convert(view.bounds, to: nil)))
            }
            view.subviews.forEach(dump)
        }
        dump(contentView)

        let bounds = contentView.bounds
        let quadrants: [(String, NSPoint)] = [
            ("top-left", NSPoint(x: bounds.width * 0.25, y: bounds.height * 0.70)),
            ("top-right", NSPoint(x: bounds.width * 0.75, y: bounds.height * 0.70)),
            ("bottom-left", NSPoint(x: bounds.width * 0.25, y: bounds.height * 0.30)),
            ("bottom-right", NSPoint(x: bounds.width * 0.75, y: bounds.height * 0.30)),
        ]

        func sessionName(of responder: NSResponder?) -> String {
            for session in workspace.sessions {
                if responder === session.surfaceView { return session.name }
                if let view = responder as? NSView,
                   view.isDescendant(of: session.surfaceView) {
                    return session.name
                }
            }
            return String(describing: type(of: responder as Any))
        }

        func clickQuadrant(_ index: Int) {
            guard index < quadrants.count else {
                self.runTitleClickRetest()
                return
            }
            let (label, point) = quadrants[index]
            // Who would AppKit hit-testing give this click to?
            if let frameView = contentView.superview {
                let hit = frameView.hitTest(contentView.convert(point, to: frameView))
                NSLog("GAICLICKTEST quadrant %@ hitTest -> %@ frame=%@",
                      label,
                      String(describing: type(of: hit as Any)),
                      hit.map { NSStringFromRect($0.convert($0.bounds, to: nil)) } ?? "nil")
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: stagePanel.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSLog("GAICLICKTEST quadrant %@ (%@) -> focused %@",
                      label, NSStringFromPoint(point),
                      sessionName(of: stagePanel.firstResponder))
                clickQuadrant(index + 1)
            }
        }
        clickQuadrant(0)
    }

    /// Test 2: a click INSIDE terminal A must reach A and focus it.
    private func runTerminalClickTest(renameTarget: GaiTerminalSession) {
        guard let stagePanel else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard self != nil else { return }
            // Aim at the actual center of A's surface, wherever the layout
            // put it.
            let frame = renameTarget.surfaceView.convert(
                renameTarget.surfaceView.bounds, to: nil)
            let windowPoint = NSPoint(x: frame.midX, y: frame.midY)
            NSLog("GAICLICKTEST test2: clicking inside terminal A at %@",
                  NSStringFromPoint(windowPoint))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: stagePanel.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                let responder = stagePanel.firstResponder
                let focusedA = (responder as? NSView)?
                    .isDescendant(of: renameTarget.surfaceView) ?? false
                    || responder === renameTarget.surfaceView
                NSLog("GAICLICKTEST test2 (terminal click focuses A): %@",
                      focusedA ? "PASS" : "FAIL")
                self?.runQuadrantFocusTest()
            }
        }
    }

    /// Test 4: probe a matrix of points around the vanishing zone — the
    /// title click at {55, H-32} never reaches the event monitor while
    /// other points do. Map the dead zone.
    private func runTitleClickRetest() {
        guard let stagePanel,
              let contentView = stagePanel.contentView
        else { return }
        let height = contentView.bounds.height
        let probes: [(String, NSPoint)] = [
            ("title-A", NSPoint(x: 55, y: height - 32.5)),
            ("same-y-x100", NSPoint(x: 100, y: height - 32.5)),
            ("same-y-x300", NSPoint(x: 300, y: height - 32.5)),
            ("same-x-lower", NSPoint(x: 55, y: height - 60)),
            ("title-D", NSPoint(x: 410, y: height - 32.5)),
        ]
        func probe(_ index: Int) {
            guard index < probes.count else { return }
            let (label, point) = probes[index]
            NSLog("GAICLICKTEST probe %@ posting at %@", label, NSStringFromPoint(point))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: stagePanel.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.ui.renamingSession = nil
                probe(index + 1)
            }
        }
        probe(0)
    }

    private func seedDemoWorkspacesIfNeeded() {
        guard store.workspaces.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in ["Mapbox", "proj-api", "MCC", "BridgeBoard", "Mux", "Atlas", "Vela"] {
            store.createWorkspace(name: name, defaultDirectory: home)
        }
        ui.selectedWorkspaceID = store.workspaces.first?.id
    }

    /// Every workspace shows at least one terminal *before* it is ever opened.
    /// Creating the pane on click instead makes the stage jump as the terminal
    /// pops in; warming it up (no focus steal) keeps switching instant.
    private func warmFirstSurfaces() {
        for workspace in store.workspaces {
            splits.ensureFirstSurface(in: workspace, focus: false)
        }
    }

    /// Toggle rendering for the open workspace's panes via Ghostty's occlusion
    /// hook (`visible == false` pauses the renderer). Used to freeze the panes
    /// for the duration of a slide so the rasterized slab can glide without any
    /// pane re-baking the bitmap underneath it.
    private func setStageSurfacesVisible(_ visible: Bool) {
        guard let workspace = store.workspace(for: store.openWorkspaceID) else { return }
        for session in workspace.sessions {
            guard let surface = session.surfaceView.surface else { continue }
            ghostty_surface_set_occlusion(surface, visible)
        }
    }

    // MARK: Panel

    /// The material behind SwiftUI's `glassEffect` is *notification-driven*:
    /// it starts in its inactive state — a static behind-window snapshot
    /// instead of live compositing — and is only promoted to the live state
    /// when its window becomes key/main. A non-activating panel that can't
    /// become key is never promoted, so the glass stays frozen forever.
    ///
    /// The fix (drawn from the dadido mascot panel, whose glass is live) is a
    /// one-shot latch: allow promotion, make the panel key+main once right
    /// after ordering it front, then swallow every demotion so the material
    /// never falls back to the frozen snapshot.
    private final class FloatingPanel: NSPanel {
        /// Normally never key: clicking the drawer must not steal keyboard
        /// focus from the user's terminals. The one exception is the workspace
        /// editor, whose name/hex text fields need the keyboard — the manager
        /// flips this on for the editor's lifetime only. The glass material
        /// follows *main* status, not key, so this never affects it.
        var allowsKeyForEditing = false
        override var canBecomeKey: Bool { allowsKeyForEditing }
        override var canBecomeMain: Bool { true }

        /// The material queries this directly on some paths; lie forever.
        override var isMainWindow: Bool { true }

        /// Deliberately not calling super (which posts the resign-main
        /// notification the material listens to — it would demote the glass
        /// back to its frozen snapshot state when the user clicks another
        /// window). `resignKey` is left untouched: the panel is never key,
        /// and swallowing it corrupts AppKit's key-window bookkeeping.
        override func resignMain() {}

        /// Promote once so `didBecomeMain` fires and the glass material
        /// switches to live behind-window compositing; the swallowed
        /// `resignMain` then keeps it there forever.
        func latchMaterialActive() {
            makeMain()
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let drawer = WorkspaceDrawerView(
            store: store,
            ui: ui,
            onWillOpen: { [weak self] in self?.snapPanel(open: true) },
            onDidClose: { [weak self] in self?.snapPanel(open: false) })
        let host = FirstMouseHostingView(rootView: drawer)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
    }

    // MARK: Stage panel

    /// Hosts the terminals of the open workspace. Unlike the drawer it can
    /// become key — the user types into its terminals — so the glass material
    /// promotes itself naturally on the first click; the swallowed
    /// `resignMain` then keeps it live forever (same recipe as the drawer).
    private final class StagePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isMainWindow: Bool { true }
        override func resignMain() {}
    }

    private func ensureStagePanel() {
        guard stagePanel == nil else { return }
        let panel = StagePanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Dark rendition always: the terminals' screen-blended text needs a
        // dark frosted backdrop to stay readable over bright content.
        panel.appearance = NSAppearance(named: .darkAqua)

        let stage = WorkspaceStageView(
            store: store,
            ui: ui,
            ghostty: ghostty,
            splits: splits,
            onClose: { [weak self] in self?.store.openWorkspaceID = nil },
            onWillExpand: { [weak self] in self?.snapStagePanel(open: true) },
            onDidCollapse: { [weak self] in self?.snapStagePanel(open: false) })
        let host = StageHostingView(rootView: stage)
        host.surfacesProvider = { [weak self] in
            guard let self,
                  let workspace = self.store.workspace(for: self.store.openWorkspaceID)
            else { return [] }
            return workspace.sessions.map(\.surfaceView)
        }
        host.autoresizingMask = [.width, .height]
        // Non-flipped container as the panel's contentView. Ghostty's
        // per-surface mouse-down monitor focuses a pane via
        // `window.contentView?.hitTest(location)` where `location` is in the
        // contentView's OWN coordinates — but `NSView.hitTest` expects
        // *superview* coordinates. When the contentView is a flipped
        // `NSHostingView`, the Y axis is inverted, so the monitor focuses the
        // vertically-opposite pane: clicks in top/bottom splits route to the
        // wrong pane (left/right are fine, X isn't flipped). A plain,
        // non-flipped wrapper restores the coordinate match; the flipped
        // SwiftUI host lives inside it and AppKit still recurses into it
        // correctly.
        let wrapper = NSView()
        wrapper.autoresizesSubviews = true
        panel.contentView = wrapper
        host.frame = wrapper.bounds
        wrapper.addSubview(host)
        self.stagePanel = panel
    }

    private func showStage() {
        ensureStagePanel()
        guard let stagePanel else { return }
        recomputeStageCardWidth()
        let wasVisible = stagePanel.isVisible
        if !wasVisible {
            // Start tucked, then let the slide-out choreography snap it open
            // and spring the slab in from the edge.
            snapStagePanel(open: false)
            stagePanel.alphaValue = 1
        }
        stagePanel.orderFrontRegardless()
        // Opening a workspace means "I want to type in a terminal now":
        // bring keyboard focus to the stage so ⌘D & friends work right away.
        stagePanel.makeKeyAndOrderFront(nil)
        stagePanel.makeMain()
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let workspace = store.workspace(for: store.openWorkspaceID) {
            splits.ensureFirstSurface(in: workspace)
            if let leaf = workspace.surfaceTree.root?.leftmostLeaf() {
                DispatchQueue.main.async { Ghostty.moveFocus(to: leaf) }
            }
        }

        if ui.isStageExpanded {
            // Switching workspaces while already out: keep it out, just make
            // sure the panel matches the (possibly new) open frame. No slide,
            // no animation — the content swaps straight to the new workspace.
            snapStagePanel(open: true)
        } else {
            // Slide the stage out from the right edge.
            ui.isStageExpanded = true
        }

        // The drawer stays open: selecting a workspace only ever *shows* it.
        // The only ways to fold the panels are the pull tab or a click
        // outside both panels.
    }

    private func hideStage() {
        guard let stagePanel, stagePanel.isVisible else { return }
        ui.isStageExpanded = false
        stagePanel.orderOut(nil)
    }

    // MARK: Stage geometry (right-edge drawer, mirror of the left drawer)

    private var stageSlabWidth: CGFloat {
        ui.stageCardWidth + GaiDrawerMetrics.tabWidth + GaiDrawerMetrics.bleed
    }

    /// Card left edge = past the open drawer's footprint, a gap, then room for
    /// the stage's OWN pull tab (which protrudes to the left of its card). That
    /// last term keeps the stage tab clear of the drawer tab so both are
    /// clickable when the drawer is expanded over the stage.
    private func recomputeStageCardWidth() {
        guard let visible = targetScreen()?.visibleFrame else { return }
        let left = visible.minX
            + GaiDrawerMetrics.cardWidth      // drawer card
            + GaiDrawerMetrics.tabWidth        // drawer pull tab
            + GaiStageMetrics.tabClearance     // gap that absorbs the overshoot
            + GaiDrawerMetrics.tabWidth        // the stage's own pull tab
        ui.stageCardWidth = max(visible.maxX - left, 320)
    }

    /// Out: card flush with the right edge, bleed hanging off-screen right,
    /// tab on the card's left. Slab is trailing-aligned in the panel.
    private func stageOpenFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = stageSlabWidth + openRightMargin
        return NSRect(
            x: visible.maxX + GaiDrawerMetrics.bleed - width,
            y: visible.minY,
            width: width,
            height: visible.height)
    }

    /// Resting tucked: slid right by the card width so only the tab peeks at
    /// the right edge; trimmed to a thin strip so the panel doesn't hang as an
    /// invisible layer over other apps. Same height/position contract as the
    /// drawer's closed frame — the slab must not move when the panel snaps.
    private func stageClosedFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.maxX - GaiDrawerMetrics.tabWidth - closedMargin,
            y: visible.minY,
            width: stageSlabWidth + closedMargin,
            height: visible.height)
    }

    private func snapStagePanel(open: Bool) {
        guard let stagePanel, let screen = targetScreen() else { return }
        stagePanel.setFrame(
            open ? stageOpenFrame(on: screen) : stageClosedFrame(on: screen),
            display: true)
    }

    // MARK: Geometry

    /// The drawer lives on the primary display (the one with the menu bar).
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first
    }

    /// Open: the slab's bleed hangs off-screen, card flush with the edge,
    /// margins around it for glass shadow spill.
    private func openFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let size = NSSize(
            width: GaiDrawerMetrics.slabWidth + openRightMargin,
            height: panelContentHeight + 2 * openVerticalMargin)
        return NSRect(
            x: visible.minX - GaiDrawerMetrics.bleed,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }

    /// Resting closed: slid left by `cardWidth` so only the tab peeks, and
    /// trimmed to a thin margin past the tab so the panel doesn't hang as an
    /// invisible layer over other apps. Same height and vertical center as
    /// the open frame — the slab must not move by a single pixel when the
    /// panel snaps between the two.
    private func closedFrame(on screen: NSScreen) -> NSRect {
        var frame = openFrame(on: screen).offsetBy(dx: -GaiDrawerMetrics.cardWidth, dy: 0)
        frame.size.width = GaiDrawerMetrics.slabWidth + closedMargin
        return frame
    }

    /// The on-screen part of the open drawer, used for click-outside tests.
    private func visibleDrawerRect(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.minX,
            y: visible.midY - ui.cardHeight / 2,
            width: GaiDrawerMetrics.cardWidth + GaiDrawerMetrics.tabWidth,
            height: ui.cardHeight)
    }

    private func snapPanel(open: Bool) {
        guard let panel, let screen = targetScreen() else { return }
        panel.setFrame(open ? openFrame(on: screen) : closedFrame(on: screen), display: true)
    }

    /// Target slab height for the current mode (explorer > editor > list).
    private func cardHeightTarget() -> CGFloat {
        let cap = (targetScreen()?.visibleFrame.height ?? 800) * 0.82
        let natural: CGFloat
        if ui.explorerOpen {
            natural = explorerNaturalHeight()
        } else if ui.editingWorkspaceID != nil {
            natural = GaiDrawerMetrics.editorHeight
        } else {
            natural = GaiDrawerMetrics.cardHeight(forRows: store.workspaces.count)
        }
        return min(natural, cap)
    }

    /// The file-explorer card height: much taller than the editor, but never the
    /// full screen height like the terminal stage.
    private func explorerNaturalHeight() -> CGFloat {
        (targetScreen()?.visibleFrame.height ?? 800) * 0.78
    }

    private func recomputeCardHeight() {
        // The window stays tall enough for the tallest mode at all times, so
        // opening the editor/explorer never resizes the window (that resize was
        // what made the expansion janky) — only the SwiftUI slab springs. The
        // slab tracks the list height unless a mode is currently driving it.
        panelContentHeight = panelHeightTarget()
        if ui.editingWorkspaceID == nil, !ui.explorerOpen {
            ui.cardHeight = cardHeightTarget()
        }
    }

    /// The window's content height: the largest of the list, the editor and the
    /// explorer, so any of them can grow into it without a window resize.
    private func panelHeightTarget() -> CGFloat {
        let list = GaiDrawerMetrics.cardHeight(forRows: store.workspaces.count)
        let cap = (targetScreen()?.visibleFrame.height ?? 800) * 0.82
        return min(max(max(list, GaiDrawerMetrics.editorHeight), explorerNaturalHeight()), cap)
    }

    /// Enter/leave the workspace editor — the heart of the organic expansion.
    ///
    /// The drawer panel is a *transparent* window; only the glass slab inside is
    /// visible. So resizing the window is invisible — what the eye follows is the
    /// slab's SwiftUI height. We animate `ui.cardHeight` (the slab height) with a
    /// spring, and because the slab is centered around the fixed pull tab it
    /// grows/shrinks from its middle, toward the top *and* the bottom, like one
    /// panel breathing — never a second panel snapping in.
    ///
    /// The window must always be at least as tall as the slab, so:
    /// - growing: enlarge the window first (invisible), then spring the slab up;
    /// - shrinking: spring the slab down first, then shrink the window once it
    ///   settles (mirrors the slide's pixel-identical snap).
    private func updateWorkspaceEditor(editing: Bool) {
        // The window is already tall enough for the editor, so this is a *pure*
        // SwiftUI slab-height spring — no window resize to fight it. Expansion
        // is therefore the exact mirror of the (lovely) retraction: the centered
        // slab springs taller/shorter around the fixed pull tab, toward top and
        // bottom. The editor's content is hidden during the motion and fades in
        // only once the card has finished opening.
        ui.editorMounted = false
        ui.editorContentVisible = false
        if editing {
            // Grow the empty card. The moment it reaches its open size
            // (`.logicallyComplete` — earlier than `.removed`, so the palette
            // doesn't appear late), MOUNT the palette at opacity 0: its one heavy
            // layout pass lands on a now-settled card, invisible. Then, on the
            // NEXT runloop tick, fade it in — a pure opacity crossfade on an
            // already-laid-out view, so it appears progressively, not in one snap.
            let mountThenFade = {
                self.ui.editorMounted = true
                DispatchQueue.main.async { self.ui.editorContentVisible = true }
            }
            if #available(macOS 14.0, *) {
                withAnimation(.gaiCardResize, completionCriteria: .logicallyComplete) {
                    ui.cardHeight = cardHeightTarget()
                } completion: { mountThenFade() }
            } else {
                withAnimation(.gaiCardResize) { ui.cardHeight = cardHeightTarget() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.46, execute: mountThenFade)
            }
        } else {
            withAnimation(.gaiCardResize) { ui.cardHeight = cardHeightTarget() }
        }

        // The editor's text fields need the keyboard; the drawer is otherwise
        // never key (so it can't steal focus from terminals).
        guard let panel = panel as? FloatingPanel else { return }
        panel.allowsKeyForEditing = editing
        if editing {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            panel.makeKeyAndOrderFront(nil)
        } else if let stagePanel, stagePanel.isVisible {
            stagePanel.makeKeyAndOrderFront(nil)
        }
    }

    /// Open/close the (future) file-explorer panel — a much taller expansion of
    /// the same drawer card. Same pure SwiftUI slab-height spring as the editor;
    /// the window is already sized for it (`panelHeightTarget`).
    private func updateExplorer(open: Bool) {
        withAnimation(.gaiCardResize) {
            ui.cardHeight = cardHeightTarget()
        }
    }


    // MARK: Click-outside

    private func installClickOutsideMonitors() {
        guard clickOutsideLocal == nil else { return }
        clickOutsideLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.collapseIfClickOutside()
            return event
        }
        clickOutsideGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.collapseIfClickOutside()
        }
    }

    private func removeClickOutsideMonitors() {
        if let clickOutsideLocal { NSEvent.removeMonitor(clickOutsideLocal) }
        if let clickOutsideGlobal { NSEvent.removeMonitor(clickOutsideGlobal) }
        clickOutsideLocal = nil
        clickOutsideGlobal = nil
    }

    private func updateClickOutsideMonitors() {
        if ui.isExpanded || ui.isStageExpanded {
            installClickOutsideMonitors()
        } else {
            removeClickOutsideMonitors()
        }
    }

    /// Screen-space regions our panels occupy right now — each panel's card
    /// when out, or just its pull tab when tucked. A click landing in none of
    /// them is "outside the panels".
    private func panelRegions(on screen: NSScreen) -> [NSRect] {
        let visible = screen.visibleFrame
        let tabExtent = GaiDrawerMetrics.tabExtent
        var rects: [NSRect] = []

        // Drawer (left edge): card+tab when out, tab only when tucked.
        if ui.isExpanded {
            rects.append(visibleDrawerRect(on: screen))
        } else {
            rects.append(NSRect(
                x: visible.minX, y: visible.midY - tabExtent / 2,
                width: GaiDrawerMetrics.tabWidth, height: tabExtent))
        }

        // Stage (right edge): only while a workspace is on stage.
        if store.openWorkspaceID != nil {
            if ui.isStageExpanded {
                let stageLeft = visible.maxX - ui.stageCardWidth
                rects.append(NSRect(
                    x: stageLeft - GaiDrawerMetrics.tabWidth, y: visible.minY,
                    width: ui.stageCardWidth + GaiDrawerMetrics.tabWidth,
                    height: visible.height))
            } else {
                rects.append(NSRect(
                    x: visible.maxX - GaiDrawerMetrics.tabWidth,
                    y: visible.midY - tabExtent / 2,
                    width: GaiDrawerMetrics.tabWidth, height: tabExtent))
            }
        }
        return rects
    }

    /// A click outside every panel region folds whatever is expanded — both
    /// the drawer and the stage.
    private func collapseIfClickOutside() {
        guard ui.isExpanded || ui.isStageExpanded, let screen = targetScreen() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ui.isExpanded || self.ui.isStageExpanded else { return }
            let point = NSEvent.mouseLocation
            let regions = self.panelRegions(on: screen)
            guard !regions.contains(where: { $0.contains(point) }) else { return }
            if self.ui.isExpanded { self.ui.isExpanded = false }
            if self.ui.isStageExpanded { self.ui.isStageExpanded = false }
        }
    }

    // MARK: Observers

    private func registerObservers() {
        guard cancellables.isEmpty else { return }

        // Watch the click-outside monitors whenever either panel is out.
        ui.$isExpanded
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateClickOutsideMonitors() }
            .store(in: &cancellables)

        ui.$isStageExpanded
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateClickOutsideMonitors() }
            .store(in: &cancellables)

        // Grow the drawer for the editor and make the panel keyboard-eligible
        // (its text fields need key focus), then shrink back when it closes.
        ui.$editingWorkspaceID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] id in self?.updateWorkspaceEditor(editing: id != nil) }
            .store(in: &cancellables)

        // Grow/shrink the drawer for the (taller) file-explorer panel.
        ui.$explorerOpen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] open in self?.updateExplorer(open: open) }
            .store(in: &cancellables)

        // Pause the on-stage terminals' rendering for the duration of a slide.
        // The slab moves as a rasterized bitmap; if a pane keeps repainting it
        // re-bakes that bitmap mid-slide, which is what still made the motion
        // hitch with several busy Claude Code sessions running. Ghostty keeps
        // reading their PTYs while paused, so they catch up instantly when the
        // slide settles and rendering resumes.
        ui.$isSliding
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] sliding in self?.setStageSurfacesVisible(!sliding) }
            .store(in: &cancellables)

        // Resize if the workspace count changes, and give any freshly created
        // workspace its terminal right away (so opening it never jumps).
        store.$workspaces
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshGeometry()
                self?.warmFirstSurfaces()
            }
            .store(in: &cancellables)

        // Show/hide the stage when a workspace is opened/closed.
        store.$openWorkspaceID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] id in
                if id != nil {
                    self?.showStage()
                } else {
                    self?.hideStage()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGeometry() }
            .store(in: &cancellables)
    }

    private func refreshGeometry() {
        recomputeCardHeight()
        snapPanel(open: ui.isExpanded)
        recomputeStageCardWidth()
        if stagePanel?.isVisible == true {
            snapStagePanel(open: ui.isStageExpanded)
        }
    }
}
#endif
