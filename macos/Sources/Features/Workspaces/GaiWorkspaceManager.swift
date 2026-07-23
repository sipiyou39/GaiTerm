#if os(macOS)
import AppKit
import Combine
import CryptoKit
import Darwin
import GhosttyKit
import SwiftUI
import UserNotifications

/// Transient UI state for the floating workspaces system.
final class GaiWorkspaceUIModel: ObservableObject {
    /// Whether the drawer is open. Toggled by the pull tab.
    @Published var isExpanded: Bool = false
    /// The workspace selected in the drawer.
    @Published var selectedWorkspaceID: GaiWorkspace.ID?
    /// Visible width of the drawer card. Persisted because the drawer is also
    /// a file browser; users need the width they chose to stay put.
    @Published var drawerCardWidth: CGFloat = {
        let value = UserDefaults.standard.double(forKey: GaiPreferenceKey.drawerCardWidth)
        return max(value > 0 ? CGFloat(value) : GaiDrawerMetrics.cardWidth, GaiDrawerMetrics.cardWidth)
    }()
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

    /// True when the editor was opened for a *just-created* workspace (via +),
    /// so "Back" discards it (cancel); editing an existing one only closes.
    @Published var editingIsNew: Bool = false

    /// Whether the editor is in the view tree. Flipped on once the card reaches
    /// its open size — its one heavy layout pass is paid here (on a ~still card,
    /// invisible). Kept separate from `editorContentVisible` so the fade can run
    /// on an already-laid-out view (a progressive crossfade, not a snap).
    @Published var editorMounted: Bool = false

    /// The editor's opacity gate, flipped one tick *after* `editorMounted` so the
    /// fade is a pure opacity animation on the already-mounted palette.
    @Published var editorContentVisible: Bool = false

    /// Whether the file-explorer ("File") tab is open. Drives the large card
    /// expansion (same height as the workspace editor).
    @Published var explorerOpen: Bool = false

    /// File-explorer content mount/fade gates — same trick as the editor: mount
    /// only once the card has finished expanding, then fade in, so the files
    /// never appear mid-expansion.
    @Published var explorerMounted: Bool = false
    @Published var explorerContentVisible: Bool = false

    /// Files open in the stage editor, in tab order. Empty = no editor.
    @Published var openFiles: [String] = []

    /// The active editor tab's path.
    @Published var activeFilePath: String?

    /// Whether the stage currently shows the editor (true) or the terminals
    /// (false). The drawer's mode toggle flips this.
    @Published var stageShowsEditor: Bool = false
    /// Immediate focus source for terminal pane tone. This is intentionally
    /// separate from SwiftUI focus values and renderer messages so one pane
    /// turns off in the same UI update where the next one turns on.
    @Published var focusedTerminalSurfaceID: ObjectIdentifier?

    /// The user's saved accent colors ("RRGGBB" hex), built by hand from the
    /// picker — there are no presets. Persisted across launches; shared by every
    /// workspace editor (one personal palette). Clicking a saved color applies
    /// it to the edited workspace.
    @Published private(set) var savedColors: [String] =
        (UserDefaults.standard.array(forKey: GaiWorkspaceUIModel.savedColorsKey) as? [String]) ?? []
    private static let savedColorsKey = "gai.workspace.savedColors"

    func saveColor(_ hex: String) {
        guard !savedColors.contains(hex) else { return }
        savedColors.append(hex)
        UserDefaults.standard.set(savedColors, forKey: Self.savedColorsKey)
    }

    func removeSavedColor(_ hex: String) {
        savedColors.removeAll { $0 == hex }
        UserDefaults.standard.set(savedColors, forKey: Self.savedColorsKey)
    }

    /// Whether the terminal stage is slid out (true) or tucked to its
    /// right-edge pull tab (false). Mirrors `isExpanded` for the drawer.
    @Published var isStageExpanded: Bool = false
    /// Whether terminal surfaces may render. This intentionally lags behind
    /// `isStageExpanded` while the slab is sliding.
    @Published private(set) var terminalRenderingAllowed: Bool = false
    /// Visible width of the terminal card when the stage is out. Owned by the
    /// manager (depends on the screen) so the panel frames and the SwiftUI
    /// slab always agree — same contract as `cardHeight` for the drawer.
    @Published var stageCardWidth: CGFloat = {
        let value = UserDefaults.standard.double(forKey: GaiPreferenceKey.stageCardWidth)
        return value > 0 ? CGFloat(value) : 600
    }()
    /// Whether drawer/stage widths move together, preserving the minimum gap
    /// between them as the user resizes either side.
    @Published var panelWidthsLinked: Bool =
        (UserDefaults.standard.object(forKey: GaiPreferenceKey.linkPanelWidths) as? Bool) ?? true

    /// True while the stage slab is mid-slide. The manager pauses terminal
    /// rendering during slides so the panel movement does not compete with
    /// busy CLI redraws.
    @Published private(set) var isSliding: Bool = false
    @Published private(set) var isPanelResizing: Bool = false
    private var slideDepth: Int = 0
    private var panelResizeDepth: Int = 0
    func beginSlide() {
        slideDepth += 1
        setTerminalRenderingAllowed(false)
        if !isSliding { isSliding = true }
    }
    func endSlide() {
        slideDepth = max(0, slideDepth - 1)
        if slideDepth == 0, isSliding {
            isSliding = false
            setTerminalRenderingAllowed(isStageExpanded)
        }
    }
    func beginPanelResize() {
        panelResizeDepth += 1
        setTerminalRenderingAllowed(false)
        if !isPanelResizing { isPanelResizing = true }
    }
    func endPanelResize() {
        panelResizeDepth = max(0, panelResizeDepth - 1)
        if panelResizeDepth == 0, isPanelResizing {
            isPanelResizing = false
            setTerminalRenderingAllowed(isStageExpanded)
        }
    }
    func setTerminalRenderingAllowed(_ allowed: Bool) {
        if terminalRenderingAllowed != allowed {
            terminalRenderingAllowed = allowed
        }
    }
}

/// `NSHostingView` that accepts the first mouse click, so a single click on
/// the (non-key) floating panel registers immediately.
private class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        if let handle = resizeHandle(at: local) {
            return handle
        }
        return super.hitTest(point)
    }

    private func resizeHandle(at local: NSPoint) -> GaiPanelResizeHandle.HandleView? {
        var best: (view: GaiPanelResizeHandle.HandleView, area: CGFloat)?
        func walk(_ view: NSView) {
            if let handle = view as? GaiPanelResizeHandle.HandleView,
               !handle.isHidden,
               handle.bounds.width <= 48,
               let rect = convertedRect(of: handle),
               rect.contains(local) {
                let area = rect.width * rect.height
                if best == nil || area < best!.area {
                    best = (handle, area)
                }
            }
            view.subviews.forEach(walk)
        }
        walk(self)
        return best?.view
    }

    fileprivate func stageTabInteraction(at local: NSPoint) -> GaiStageTabInteraction.TabView? {
        var best: (view: GaiStageTabInteraction.TabView, area: CGFloat)?
        func walk(_ view: NSView) {
            if let tab = view as? GaiStageTabInteraction.TabView,
               !tab.isHidden,
               tab.bounds.width <= 80,
               let rect = convertedRect(of: tab),
               rect.contains(local) {
                let area = rect.width * rect.height
                if best == nil || area < best!.area {
                    best = (tab, area)
                }
            }
            view.subviews.forEach(walk)
        }
        walk(self)
        return best?.view
    }

    private func convertedRect(of view: NSView) -> CGRect? {
        guard view.window === window else { return nil }
        return view.convert(view.bounds, to: self)
    }

    required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

struct GaiTerminalPaneRGB: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    init(_ color: Color) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB)
            ?? NSColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8(clamping: Int((value * 255).rounded()))
        }
        self.r = byte(nsColor.redComponent)
        self.g = byte(nsColor.greenComponent)
        self.b = byte(nsColor.blueComponent)
    }
}

extension Notification.Name {
    static let gaiSurfaceDidRequestImmediateFocus =
        Notification.Name("com.sipiyou.gaiterm.surfaceDidRequestImmediateFocus")
    static let gaiSurfaceDidReceiveUserInput =
        Notification.Name("com.sipiyou.gaiterm.surfaceDidReceiveUserInput")
    static let gaiSurfaceDidCancelAgentWork =
        Notification.Name("com.sipiyou.gaiterm.surfaceDidCancelAgentWork")
}

/// Stage hosting view: takes over hit-testing at the root so header controls
/// and terminal surfaces are routed deterministically:
///
/// 1. terminal surfaces by their rendered layer rect, avoiding SwiftUI's deep
///    hit-test/hover responder walk on the hot terminal area,
/// 2. header controls (a `GaiClickCatcher.CatcherView`, smallest match wins),
/// 3. everything else falls back to the normal pipeline.
///
/// One synchronous path, no event monitors, no re-posting. The final fallback
/// keeps the native path available if a surface is mid-reparent/layout.
private final class StageHostingView<Content: View>: FirstMouseHostingView<Content> {
    var surfacesProvider: () -> [Ghostty.SurfaceView] = { [] }

    /// Rendered rect of a header control in this hosting view's coordinate
    /// space, measured through the *layer* tree so it reflects what's drawn.
    private func renderedRect(of view: NSView) -> CGRect? {
        guard let viewLayer = view.layer, let hostLayer = self.layer else { return nil }
        return viewLayer.convert(viewLayer.bounds, to: hostLayer)
    }

    /// Fast terminal hit path. Returning the `SurfaceView` directly lets
    /// Ghostty receive mouse events without asking SwiftUI to hit-test every
    /// pane and hover responder on each cursor/tracking update.
    private func renderedSurface(at local: NSPoint) -> Ghostty.SurfaceView? {
        var best: (surface: Ghostty.SurfaceView, area: CGFloat)?
        for surface in surfacesProvider() {
            guard surface.window === window,
                  !surface.isHidden,
                  let rect = renderedRect(of: surface),
                  rect.contains(local)
            else { continue }

            let area = rect.width * rect.height
            if best == nil || area < best!.area {
                best = (surface, area)
            }
        }
        return best?.surface
    }

    private func resizeHandle(at local: NSPoint) -> GaiPanelResizeHandle.HandleView? {
        var best: (view: GaiPanelResizeHandle.HandleView, area: CGFloat)?
        func walk(_ view: NSView) {
            if let handle = view as? GaiPanelResizeHandle.HandleView,
               !handle.isHidden,
               handle.bounds.width <= 48,
               let rect = convertedRect(of: handle),
               rect.contains(local) {
                let area = rect.width * rect.height
                if best == nil || area < best!.area {
                    best = (handle, area)
                }
            }
            view.subviews.forEach(walk)
        }
        walk(self)
        return best?.view
    }

    private func convertedRect(of view: NSView) -> CGRect? {
        guard view.window === window else { return nil }
        return view.convert(view.bounds, to: self)
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

        // Pane drag/drop needs the pane-local drop target above the terminal
        // surface. During that short interaction, bypass the terminal fast path
        // so AppKit can hit-test the overlay normally.
        if GaiPaneDragCoordinator.isDraggingPane {
            return super.hitTest(point)
        }

        // The stage tab is a special shape welded to the card edge. It wins
        // over the resize strip inside its own height: hover/click acts like a
        // tab, while a real drag from the tab can still resize.
        if let tab = stageTabInteraction(at: local) {
            return tab
        }
        // Panel-width resize handles sit over terminal pixels; they must win
        // before Ghostty's fast terminal hit path, otherwise a drag becomes
        // terminal text selection.
        if let handle = resizeHandle(at: local) {
            return handle
        }

        // 1. Terminal surface hot path: bypass SwiftUI's responder walk for
        // the area users interact with most during multi-pane CLI runs.
        if let surface = renderedSurface(at: local) {
            return surface
        }

        // 2. Header controls: smallest rendered match wins.
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

        // 3. Fallback: defer to AppKit's native hit-testing and resolve the
        // enclosing surface. This handles rare mid-layout/reparent cases where
        // the fast layer rect path does not yet have a settled surface frame.
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
                self?.syncWorkspaceSelection()
            }
        }
        controller.onTopologyDidChange = { [weak self] in
            self?.updateSurfacePerformanceState()
            self?.refreshSurfacePersistenceObservers()
            self?.scheduleWorkspaceSave()
        }
        return controller
    }()
    private var panel: NSPanel?
    private var stagePanel: NSPanel?
    private var screenTabPanels: [CGDirectDisplayID: NSPanel] = [:]
    private var activeScreenID: CGDirectDisplayID?
    private var localModifierMonitor: Any?
    private var globalModifierMonitor: Any?
    private var shortcutOptionIsDown = false
    private var lastOptionTapTime: TimeInterval?
    private let modifierDoubleTapInterval: TimeInterval = 0.28
    /// Height the drawer *window* is sized for. Kept separate from
    /// `ui.cardHeight` (the SwiftUI slab's animated height) so the editor can
    /// resize the transparent window invisibly while the visible glass slab
    /// springs to its new height — see `updateWorkspaceEditor`.
    private var panelContentHeight: CGFloat = GaiDrawerMetrics.cardHeight(forRows: 1)
    private var cancellables: Set<AnyCancellable> = []
    private var surfaceStateCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var pendingWorkspaceSave: DispatchWorkItem?
    private var observersRegistered = false
    private var terminalBackgrounds: [ObjectIdentifier: GaiTerminalPaneRGB] = [:]
    private var pendingGenericExternalNotifications: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var agentResumePromptShown = false

    /// Transparent margins around the slab in the open frame so the glass can
    /// cast its light and shadow without being clipped at the window edge.
    private let openRightMargin: CGFloat = 40
    private let openVerticalMargin: CGFloat = 32
    /// Margin around the tab in the resting closed frame.
    private let closedMargin: CGFloat = 14

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        self.store = GaiWorkspaceStore(ghostty: ghostty)
        NotificationCenter.default.publisher(for: .gaiSurfaceDidRequestImmediateFocus)
            .sink { [weak self] notification in
                guard let surface = notification.object as? Ghostty.SurfaceView else { return }
                self?.applyImmediateFocus(to: surface)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .gaiSurfaceDidReceiveUserInput)
            .sink { [weak self] notification in
                guard let surface = notification.object as? Ghostty.SurfaceView else { return }
                self?.store.markUserReturnedToWork(for: surface)
            }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    /// Bring the drawer forward and slide it open — used when the app is
    /// reopened from the Dock (instead of spawning a terminal window).
    func reveal() {
        setActiveScreenUnderMouseIfAvailable()
        start()
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        // Open the block (stage + drawer via the mirror), like the pull tab does —
        // not just the drawer.
        showStage()
    }

    /// GaiTerm's app-level "new terminal" entry point. Old Ghostty actions such
    /// as "new window" and "new tab" are mapped here: they create or split a
    /// terminal inside the stage instead of spawning a classic terminal window.
    @discardableResult
    func openTerminal(
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        parent: Ghostty.SurfaceView? = nil,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection? = nil
    ) -> Ghostty.SurfaceView? {
        start()
        if ui.stageShowsEditor { ui.stageShowsEditor = false }
        showStage()

        let workspace = parent.flatMap { splits.workspace(containing: $0) } ?? store.stageWorkspace
        if workspace.surfaceTree.isEmpty {
            return splits.openRootSurface(in: workspace, baseConfig: baseConfig)
        }

        let target = parent ?? workspace.surfaceTree.root?.leftmostLeaf()
        return splits.newSplit(
            in: workspace,
            at: target,
            direction: direction ?? .right,
            baseConfig: baseConfig)
    }

    /// Finds a live surface owned by GaiTerm's workspace system.
    func surface(for uuid: UUID) -> Ghostty.SurfaceView? {
        for workspace in allWorkspaces {
            if let view = workspace.surfaceTree.first(where: { $0.id == uuid }) {
                return view
            }
        }
        return nil
    }

    var terminalSurfaces: [Ghostty.SurfaceView] {
        allWorkspaces.flatMap { workspace in Array(workspace.surfaceTree) }
    }

    func focusSurface(_ surface: Ghostty.SurfaceView) {
        let workspace = splits.workspace(containing: surface)
        if let workspace {
            store.openWorkspaceID = workspace.id
            ui.selectedWorkspaceID = workspace.id
        }
        if ui.stageShowsEditor { ui.stageShowsEditor = false }
        showStage()
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let self, let surface else { return }
            Ghostty.moveFocus(to: surface)
            self.applyImmediateFocus(to: surface)
        }
    }

    /// Global/local shortcut: double-tap Option quickly to open or close the
    /// whole GaiTerm block. Option is preferred over Control because Control
    /// may still be tied to Dictation/accessibility shortcuts on some macOS
    /// setups, while Option-alone double tap is normally unused.
    func toggleBlockFromModifierShortcut() {
        if ui.isStageExpanded {
            dismissBlock()
        } else {
            setActiveScreenUnderMouseIfAvailable()
            reveal()
        }
    }

    func focusedSurface() -> Ghostty.SurfaceView? {
        let responders = [stagePanel?.firstResponder, NSApp.keyWindow?.firstResponder]
        for responder in responders {
            if let surface = enclosingSurface(in: responder) {
                return surface
            }
        }

        if let focused = terminalSurfaces.first(where: { $0.focused }) {
            return focused
        }

        return store.stageWorkspace.surfaceTree.root?.leftmostLeaf()
    }

    func closeSurface(_ surface: Ghostty.SurfaceView) {
        guard let workspace = splits.workspace(containing: surface) else { return }
        splits.closePane(in: workspace, surface: surface)
    }

    func closeAllSurfaces() {
        for surface in terminalSurfaces {
            closeSurface(surface)
        }
    }

    @discardableResult
    func recordExternalNotification(
        surfaceID: UUID,
        title: String,
        body: String
    ) -> Bool {
        guard let surface = surface(for: surfaceID) else { return false }
        guard !isSurfaceCurrentlyViewed(surface) else { return true }
        let workspace = splits.workspace(containing: surface)
        let session = workspace?.session(for: surface)
        let notificationTitle = title.isEmpty ? (session?.name ?? "Terminal") : title
        let recorded = store.recordNotification(
            for: surface,
            title: notificationTitle,
            body: body,
            attention: .needsInput)
        handleAutoFocusNotification(surface, workspace: workspace, session: session)
        let notificationsEnabled = session?.notificationsEnabled ?? true
        let shouldDeliverSystemNotification = recorded && notificationsEnabled

        if isGenericTurnComplete(title: notificationTitle, body: body) {
            scheduleGenericNotificationFallback(
                surface,
                workspace: workspace,
                title: notificationTitle,
                body: body,
                shouldPlaySound: notificationsEnabled,
                shouldDeliverSystemNotification: shouldDeliverSystemNotification)
        } else if notificationsEnabled {
            cancelGenericNotificationFallback(for: surface)
            playAgentNotificationSoundIfNeeded(
                surface,
                workspace: workspace,
                title: notificationTitle,
                body: body)
            if shouldDeliverSystemNotification {
                deliverSystemNotification(
                    surface,
                    workspace: workspace,
                    title: notificationTitle,
                    body: body)
            }
        }
        return recorded
    }

    private var allWorkspaces: [GaiWorkspace] {
        store.workspaces + [store.defaultWorkspace]
    }

    private func enclosingSurface(in responder: NSResponder?) -> Ghostty.SurfaceView? {
        var current = responder
        while let item = current {
            if let surface = item as? Ghostty.SurfaceView {
                return surface
            }
            current = item.nextResponder
        }
        return nil
    }

    func start() {
        // Idempotent: launch can reach this from several paths.
        if let panel {
            panel.orderFrontRegardless()
            updateSurfacePerformanceState()
            return
        }

        // Restore saved workspaces by default. GaiTerm is a workspace manager:
        // deleting a workspace is the user's explicit "do not restore" action.
        UserDefaults.standard.set(true, forKey: GaiPreferenceKey.restoreWorkspaces)
        store.loadPersisted()
        // If workspaces exist, one of them is always the active workspace. The
        // default scratch terminal is only for the truly empty-workspace state.
        syncWorkspaceSelection()
        warmFirstSurfaces()
        refreshSurfacePersistenceObservers()
        recomputeCardHeight()
        constrainPanelWidths()
        ensurePanel()
        snapPanel(open: false)
        panel?.orderFrontRegardless()
        (panel as? FloatingPanel)?.latchMaterialActive()
        registerObservers()
        // Always show a terminal: the default scratch terminal until a workspace
        // is opened. The drawer has no pull tab — it mirrors the stage (see
        // `registerObservers`), so opening the stage here opens the drawer too.
        showStage()
        presentAgentResumePromptIfNeeded()

        if ProcessInfo.processInfo.environment["GAI_AUTOEXPAND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.ui.isExpanded = true
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
                    self.updateSurfacePerformanceState()
                }
            }
        }
    }

    /// Every workspace shows at least one terminal *before* it is ever opened.
    /// Creating the pane on click instead makes the stage jump as the terminal
    /// pops in; warming it up (no focus steal) keeps switching instant.
    private func warmFirstSurfaces() {
        for workspace in store.workspaces {
            // Never warm the workspace being created/edited: its CLI config
            // isn't set yet, so a warm plain shell would occupy the tree and
            // block the CLI panes from being built when it opens.
            if workspace.id == ui.editingWorkspaceID { continue }
            splits.ensureFirstSurface(in: workspace, focus: false)
        }
    }

    private func presentAgentResumePromptIfNeeded() {
        guard !agentResumePromptShown else { return }
        agentResumePromptShown = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var candidates = GaiAgentResumeScanner.candidates(for: self.store.workspaces)
            #if DEBUG
            if candidates.isEmpty,
               ProcessInfo.processInfo.environment[GaiAgentResumeScanner.forceEnvironmentKey] != nil {
                candidates = GaiAgentResumeScanner.debugCandidates(for: self.store.workspaces)
            }
            #endif
            guard !candidates.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                GaiAgentResumeWindowController.shared.show(
                    candidates: candidates,
                    screen: self.targetScreen(),
                    resume: { [weak self] candidate in
                        self?.resumeAgentSession(candidate)
                    })
            }
        }
    }

    private func resumeAgentSession(_ candidate: GaiAgentResumeCandidate) {
        guard let workspace = store.workspace(for: candidate.workspaceID) else { return }
        store.openWorkspaceID = workspace.id
        ui.selectedWorkspaceID = workspace.id
        if ui.stageShowsEditor { ui.stageShowsEditor = false }
        showStage()

        let command = candidate.command
        let directory = candidate.directoryPath
        if let paneID = candidate.paneID,
           let session = workspace.sessions.first(where: { $0.id == paneID }) {
            _ = splits.reopenPane(
                in: workspace,
                surface: session.surfaceView,
                directory: directory,
                command: command)
            store.save()
            return
        }

        _ = splits.openAgentResumePane(
            in: workspace,
            command: command,
            directory: directory)
        store.save()
    }

    private func refreshSurfacePersistenceObservers() {
        let liveViews = allWorkspaces.flatMap { Array($0.surfaceTree) }
        let liveIDs = Set(liveViews.map { ObjectIdentifier($0) })
        surfaceStateCancellables = surfaceStateCancellables.filter { liveIDs.contains($0.key) }

        for view in liveViews {
            let id = ObjectIdentifier(view)
            guard surfaceStateCancellables[id] == nil else { continue }
            surfaceStateCancellables[id] = view.$pwd
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.scheduleWorkspaceSave()
                }
        }
    }

    private func scheduleWorkspaceSave() {
        pendingWorkspaceSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.store.save()
        }
        pendingWorkspaceSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    /// Performance policy for Ghostty surfaces. A surface renders only when it
    /// is actually visible in the terminal stage. Everything off-stage, hidden
    /// by the editor, hidden by zoom, or moving during a slide is occluded.
    private func updateSurfacePerformanceState() {
        let canRenderStage =
            stagePanel?.isVisible == true &&
            ui.isStageExpanded &&
            ui.terminalRenderingAllowed &&
            !ui.isSliding &&
            !ui.isPanelResizing &&
            !ui.stageShowsEditor

        let visibleViews: [Ghostty.SurfaceView] = if canRenderStage {
            visibleTerminalSurfaces(in: store.stageWorkspace)
        } else {
            []
        }
        let visibleIDs = Set(visibleViews.map { ObjectIdentifier($0) })
        let focusToneEnabled = visibleViews.count > 1
        let appFocused = enclosingSurface(in: stagePanel?.firstResponder)
        let renderFocused = if let appFocused,
                               visibleIDs.contains(ObjectIdentifier(appFocused)) {
            appFocused
        } else {
            visibleViews.first(where: { $0.focused }) ?? visibleViews.first
        }
        let renderFocusedID = renderFocused.map { ObjectIdentifier($0) }
        if ui.focusedTerminalSurfaceID != renderFocusedID {
            ui.focusedTerminalSurfaceID = renderFocusedID
        }
        let tintPanels = UserDefaults.standard.bool(
            forKey: GaiPreferenceKey.tintGlassWithWorkspaceAccent)
        let accent = store.stageWorkspace.accentColor

        for workspace in allWorkspaces {
            for view in workspace.surfaceTree {
                let isVisible = visibleIDs.contains(ObjectIdentifier(view))
                guard let surface = view.surface else { continue }

                ghostty_surface_set_occlusion(surface, isVisible)

                let isRenderFocused = isVisible && view === renderFocused
                view.focusDidChange(isRenderFocused)
                updateTerminalBackground(
                    for: view,
                    accent: accent,
                    tinted: tintPanels,
                    active: focusToneEnabled && isRenderFocused)
            }
        }
        if let renderFocused, canRenderStage {
            store.markNotificationsRead(for: renderFocused)
        }
        pruneTerminalBackgroundCache()
    }

    private func applyImmediateFocus(to target: Ghostty.SurfaceView) {
        guard splits.workspace(containing: target) != nil else { return }

        let visibleViews = visibleTerminalSurfaces(in: store.stageWorkspace)
        let visibleIDs = Set(visibleViews.map { ObjectIdentifier($0) })
        let focusToneEnabled = visibleViews.count > 1
        let tintPanels = UserDefaults.standard.bool(
            forKey: GaiPreferenceKey.tintGlassWithWorkspaceAccent)
        let accent = store.stageWorkspace.accentColor
        let views = allWorkspaces.flatMap { Array($0.surfaceTree) }
        let isTargetVisible = visibleIDs.contains(ObjectIdentifier(target))

        ui.focusedTerminalSurfaceID = isTargetVisible ? ObjectIdentifier(target) : nil

        for view in views where view !== target {
            view.focusDidChange(false)
            updateTerminalBackground(
                for: view,
                accent: accent,
                tinted: tintPanels,
                active: false)
        }

        target.focusDidChange(isTargetVisible)
        updateTerminalBackground(
            for: target,
            accent: accent,
            tinted: tintPanels,
            active: focusToneEnabled && isTargetVisible)
        if isTargetVisible {
            store.markNotificationsRead(for: target)
        }
    }

    private func updateTerminalBackground(
        for view: Ghostty.SurfaceView,
        accent: Color,
        tinted: Bool,
        active _: Bool
    ) {
        let rgb = GaiTerminalPaneRGB(
            Color.gaiTerminalPaneColor(
                accent: accent,
                tinted: tinted,
                active: false))
        let id = ObjectIdentifier(view)
        guard let surface = view.surface else { return }
        guard terminalBackgrounds[id] != rgb else { return }

        ghostty_surface_set_background_rgb(surface, rgb.r, rgb.g, rgb.b)
        terminalBackgrounds[id] = rgb
    }

    private func pruneTerminalBackgroundCache() {
        let live = Set(terminalSurfaces.map { ObjectIdentifier($0) })
        terminalBackgrounds = terminalBackgrounds.filter { live.contains($0.key) }
    }

    private func visibleTerminalSurfaces(in workspace: GaiWorkspace) -> [Ghostty.SurfaceView] {
        if let zoomed = workspace.surfaceTree.zoomed {
            return Array(zoomed)
        }
        return Array(workspace.surfaceTree)
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
        panel.level = GaiFloatingPanels.overlayLevel
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
            onDidClose: { [weak self] in self?.snapPanel(open: false) },
            onResizeBegan: { [weak self] in self?.beginPanelResize() },
            onResizeWidth: { [weak self] width in self?.setDrawerCardWidth(width) },
            onResizeEnded: { [weak self] in self?.endPanelResize() },
            onToggleWidthLink: { [weak self] in self?.togglePanelWidthLink() })
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

    private final class StageScreenTabPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private func ensureStagePanel() {
        guard stagePanel == nil else { return }
        let panel = StagePanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.level = GaiFloatingPanels.overlayLevel
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
        // Dark rendition always: terminal rendering is optimized for a dark,
        // opaque stage backing.
        panel.appearance = NSAppearance(named: .darkAqua)

        let stage = WorkspaceStageView(
            store: store,
            ui: ui,
            ghostty: ghostty,
            splits: splits,
            onClose: { [weak self] in self?.store.openWorkspaceID = nil },
            onWillExpand: { [weak self] in self?.snapStagePanel(open: true) },
            onDidCollapse: { [weak self] in self?.snapStagePanel(open: false) },
            onFocusChanged: { [weak self] in self?.updateSurfacePerformanceState() },
            onResizeBegan: { [weak self] in self?.beginPanelResize() },
            onResizeWidth: { [weak self] width in self?.setStageCardWidth(width) },
            onResizeEnded: { [weak self] in self?.endPanelResize() })
        let host = StageHostingView(rootView: stage)
        host.surfacesProvider = { [weak self] in
            guard let self else { return [] }
            return self.store.stageWorkspace.sessions.map(\.surfaceView)
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

    private func ensureScreenTabPanels() {
        var liveIDs: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let screenID = displayID(for: screen) else { continue }
            liveIDs.insert(screenID)
            if screenTabPanels[screenID] == nil {
                screenTabPanels[screenID] = makeScreenTabPanel(for: screen, screenID: screenID)
            }
        }

        let staleIDs = screenTabPanels.keys.filter { !liveIDs.contains($0) }
        for screenID in staleIDs {
            screenTabPanels[screenID]?.orderOut(nil)
            screenTabPanels[screenID] = nil
        }
        updateScreenTabPanels()
    }

    private func makeScreenTabPanel(for screen: NSScreen, screenID: CGDirectDisplayID) -> NSPanel {
        let panel = StageScreenTabPanel(
            contentRect: screenTabFrame(on: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = GaiFloatingPanels.overlayLevel
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

        let tab = GaiStageScreenTabProxyView(store: store) { [weak self] in
            self?.openStageFromScreenTab(screenID)
        }
        let host = FirstMouseHostingView(rootView: tab)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func openStageFromScreenTab(_ screenID: CGDirectDisplayID) {
        guard let screen = screen(for: screenID) else { return }
        setActiveScreen(screen)
        showStage()
    }

    private func updateScreenTabPanels() {
        let activeID = targetScreen().flatMap { displayID(for: $0) }
        for screen in NSScreen.screens {
            guard let screenID = displayID(for: screen),
                  let panel = screenTabPanels[screenID]
            else { continue }
            setFrameIfNeeded(panel, screenTabFrame(on: screen))
            if screenID == activeID {
                panel.orderOut(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
    }

    private func showStage() {
        ensureStagePanel()
        ensureScreenTabPanels()
        guard let stagePanel else { return }
        recomputeStageCardWidth()
        let wasVisible = stagePanel.isVisible
        let wasExpanded = ui.isStageExpanded
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
        // Don't spin up terminals (or auto-launch CLIs) when the stage opens
        // straight into the editor from a file click — only when the terminals
        // are what's being shown. `stageWorkspace` is the open workspace, or the
        // default scratch terminal when none is open.
        if !ui.stageShowsEditor {
            let workspace = store.stageWorkspace
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
        if wasExpanded {
            ui.setTerminalRenderingAllowed(true)
        } else {
            ui.setTerminalRenderingAllowed(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                guard self.ui.isStageExpanded, !self.ui.isSliding else { return }
                self.ui.setTerminalRenderingAllowed(true)
            }
        }
        updateSurfacePerformanceState()
        updateScreenTabPanels()
    }

    private func hideStage() {
        guard let stagePanel, stagePanel.isVisible else { return }
        ui.setTerminalRenderingAllowed(false)
        ui.isStageExpanded = false
        stagePanel.orderOut(nil)
        updateScreenTabPanels()
        updateSurfacePerformanceState()
    }

    // MARK: Stage geometry (right-edge drawer, mirror of the left drawer)

    private var stageSlabWidth: CGFloat {
        ui.stageCardWidth + GaiDrawerMetrics.tabWidth + GaiDrawerMetrics.bleed
    }

    private var stageClosedPanelWidth: CGFloat {
        GaiDrawerMetrics.tabWidth
    }

    private var drawerSlabWidth: CGFloat {
        GaiDrawerMetrics.bleed + ui.drawerCardWidth
    }

    private var drawerClosedPanelWidth: CGFloat {
        1
    }

    private var minimumPanelGap: CGFloat {
        GaiDrawerMetrics.tabWidth
            + GaiStageMetrics.tabClearance
            + GaiDrawerMetrics.tabWidth
    }

    private var minDrawerCardWidth: CGFloat { GaiDrawerMetrics.cardWidth }
    private var maxDrawerCardWidth: CGFloat { 560 }
    private var minStageCardWidth: CGFloat { 320 }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    /// Card left edge = past the open drawer's footprint, a gap, then room for
    /// the stage's OWN pull tab (which protrudes to the left of its card). That
    /// last term keeps the stage tab clear of the drawer tab so both are
    /// clickable when the drawer is expanded over the stage.
    private func recomputeStageCardWidth() {
        constrainPanelWidths()
    }

    private func setDrawerCardWidth(_ proposed: CGFloat) {
        updatePanelWidths(proposedDrawer: proposed, proposedStage: nil, persist: false)
    }

    private func setStageCardWidth(_ proposed: CGFloat) {
        updatePanelWidths(proposedDrawer: nil, proposedStage: proposed, persist: false)
    }

    private func beginPanelResize() {
    }

    private func endPanelResize() {
        persistPanelWidths()
        applyPanelWidthGeometry()
    }

    private func togglePanelWidthLink() {
        ui.panelWidthsLinked.toggle()
        UserDefaults.standard.set(ui.panelWidthsLinked, forKey: GaiPreferenceKey.linkPanelWidths)
        updatePanelWidths(proposedDrawer: ui.drawerCardWidth, proposedStage: nil, persist: true)
    }

    private func constrainPanelWidths(persist: Bool = false) {
        updatePanelWidths(
            proposedDrawer: ui.drawerCardWidth,
            proposedStage: ui.stageCardWidth,
            persist: persist)
    }

    private func updatePanelWidths(
        proposedDrawer: CGFloat?,
        proposedStage: CGFloat?,
        persist: Bool
    ) {
        guard let visible = targetScreen()?.visibleFrame else { return }
        let available = visible.width - minimumPanelGap
        guard available > minDrawerCardWidth + minStageCardWidth else { return }

        let drawerMax = Swift.min(maxDrawerCardWidth, available - minStageCardWidth)
        let stageMax = available - minDrawerCardWidth
        var drawer = proposedDrawer ?? ui.drawerCardWidth
        var stage = proposedStage ?? ui.stageCardWidth

        if ui.panelWidthsLinked {
            if proposedStage != nil, proposedDrawer == nil {
                stage = clamp(stage, min: minStageCardWidth, max: stageMax)
                drawer = clamp(available - stage, min: minDrawerCardWidth, max: drawerMax)
                stage = available - drawer
            } else {
                drawer = clamp(drawer, min: minDrawerCardWidth, max: drawerMax)
                stage = available - drawer
            }
        } else {
            drawer = clamp(drawer, min: minDrawerCardWidth, max: drawerMax)
            let stageMaxForDrawer = available - drawer
            stage = clamp(stage, min: minStageCardWidth, max: stageMaxForDrawer)

            if drawer + stage > available {
                if proposedDrawer != nil, proposedStage == nil {
                    drawer = clamp(available - stage, min: minDrawerCardWidth, max: drawerMax)
                } else {
                    stage = clamp(available - drawer, min: minStageCardWidth, max: stageMax)
                }
            }
        }

        let changed =
            abs(ui.drawerCardWidth - drawer) > 0.5
            || abs(ui.stageCardWidth - stage) > 0.5
        if changed {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                ui.drawerCardWidth = drawer
                ui.stageCardWidth = stage
            }
            applyPanelWidthGeometry()
        }
        if persist {
            persistPanelWidths()
        }
    }

    private func persistPanelWidths() {
        UserDefaults.standard.set(Double(ui.drawerCardWidth), forKey: GaiPreferenceKey.drawerCardWidth)
        UserDefaults.standard.set(Double(ui.stageCardWidth), forKey: GaiPreferenceKey.stageCardWidth)
        UserDefaults.standard.set(ui.panelWidthsLinked, forKey: GaiPreferenceKey.linkPanelWidths)
    }

    private func applyPanelWidthGeometry() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            snapPanel(open: ui.isExpanded)
            if stagePanel?.isVisible == true {
                snapStagePanel(open: ui.isStageExpanded)
            }
        }
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

    /// Resting tucked: only the pull tab remains inside the target screen.
    /// Never extend the closed panel past `visible.maxX`: with a display
    /// arranged to the right, that "off-screen" area is a real visible display.
    private func stageClosedFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = stageClosedPanelWidth
        return NSRect(
            x: visible.maxX - width,
            y: visible.minY,
            width: width,
            height: visible.height)
    }

    private func snapStagePanel(open: Bool) {
        guard let stagePanel, let screen = targetScreen() else { return }
        let frame = open ? stageOpenFrame(on: screen) : stageClosedFrame(on: screen)
        setFrameIfNeeded(stagePanel, frame)
    }

    private func screenTabFrame(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let width = stageClosedPanelWidth
        return NSRect(
            x: frame.maxX - width,
            y: frame.minY,
            width: width,
            height: frame.height)
    }

    // MARK: Geometry

    /// The drawer/stage live on the screen that opened them. Collapsed proxy
    /// tabs exist on every display and set this target before opening.
    private func targetScreen() -> NSScreen? {
        if let activeScreenID,
           let screen = screen(for: activeScreenID) {
            return screen
        }
        return NSScreen.screens.first
    }

    private func setActiveScreen(_ screen: NSScreen) {
        guard let screenID = displayID(for: screen) else { return }
        activeScreenID = screenID
        refreshGeometry()
    }

    private func setActiveScreenUnderMouseIfAvailable() {
        guard let screen = screenContainingMouse() else { return }
        setActiveScreen(screen)
    }

    private func screenContainingMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(for: $0) == id }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Open: the slab's bleed hangs off-screen, card flush with the edge,
    /// margins around it for glass shadow spill.
    private func openFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let size = NSSize(
            width: drawerSlabWidth + openRightMargin,
            height: panelContentHeight + 2 * openVerticalMargin)
        return NSRect(
            x: visible.minX - GaiDrawerMetrics.bleed,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }

    /// Resting closed: the drawer has no independent pull tab anymore, so keep
    /// only a transparent in-screen sliver. Never park the off-screen card on an
    /// adjacent display.
    private func closedFrame(on screen: NSScreen) -> NSRect {
        let open = openFrame(on: screen)
        return NSRect(
            x: screen.visibleFrame.minX,
            y: open.minY,
            width: drawerClosedPanelWidth,
            height: open.height)
    }

    private func snapPanel(open: Bool) {
        guard let panel, let screen = targetScreen() else { return }
        setFrameIfNeeded(panel, open ? openFrame(on: screen) : closedFrame(on: screen))
    }

    private func setFrameIfNeeded(_ panel: NSPanel, _ frame: NSRect) {
        let current = panel.frame
        guard abs(current.origin.x - frame.origin.x) > 0.5
            || abs(current.origin.y - frame.origin.y) > 0.5
            || abs(current.size.width - frame.size.width) > 0.5
            || abs(current.size.height - frame.size.height) > 0.5
        else { return }
        panel.setFrame(frame, display: true)
    }

    /// Target slab height: the list, or the single large expansion (used for the
    /// editor, new-workspace creation and the future file explorer alike).
    private func cardHeightTarget() -> CGFloat {
        let cap = (targetScreen()?.visibleFrame.height ?? 800) * 0.82
        let natural = (ui.explorerOpen || ui.editingWorkspaceID != nil)
            ? largeExpansionHeight()
            : listHeight()
        return min(natural, cap)
    }

    /// The one large card height: much taller than the list, but never the full
    /// screen like the terminal stage.
    private func largeExpansionHeight() -> CGFloat {
        (targetScreen()?.visibleFrame.height ?? 800) * 0.78
    }

    /// List card height — adapts to the workspace count, but never shorter than
    /// the 2-row height (below that the pull tab is taller than the card and its
    /// welds break).
    private func listHeight() -> CGFloat {
        // +1 row for the always-present "New workspace" button (when there's at
        // least one workspace); never shorter than 2 rows so the pull tab fits.
        let rows = store.workspaces.isEmpty ? 0 : store.workspaces.count + 1
        return GaiDrawerMetrics.cardHeight(forRows: max(rows, 2))
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
        let cap = (targetScreen()?.visibleFrame.height ?? 800) * 0.82
        return min(max(listHeight(), largeExpansionHeight()), cap)
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
            // Editor closed: persist whatever was renamed / recolored / configured.
            store.save()
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
        // Same choreography as the workspace editor: the card grows empty, then
        // the file tree is mounted (opacity 0) on the settled card and faded in
        // — so files never flash in mid-expansion.
        ui.explorerMounted = false
        ui.explorerContentVisible = false
        if open {
            let mountThenFade = {
                self.ui.explorerMounted = true
                DispatchQueue.main.async { self.ui.explorerContentVisible = true }
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

        // The file tab's search / rename / new-file fields need the keyboard, so
        // the drawer must be key while it's open (it's otherwise never key, to
        // avoid stealing focus from terminals).
        guard let panel = panel as? FloatingPanel else { return }
        panel.allowsKeyForEditing = open
        if open {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            panel.makeKeyAndOrderFront(nil)
        } else if let stagePanel, stagePanel.isVisible {
            stagePanel.makeKeyAndOrderFront(nil)
        }
    }


    // MARK: Dismiss on leaving GaiTerm

    /// Close the block. Called when GaiTerm stops being the active app — i.e. the
    /// user clicked another app or the desktop. We let that click act normally
    /// (which is what switches apps in a single click, the way macOS intends);
    /// here we just fold the panels away. A single click on a folder only selects
    /// it, so nothing destructive is triggered behind.
    private func dismissBlock() {
        if ui.isStageExpanded { ui.isStageExpanded = false }
    }

    // MARK: Observers

    private func registerObservers() {
        guard !observersRegistered else { return }
        observersRegistered = true
        installModifierShortcutMonitors()

        // The drawer has no pull tab: it mirrors the stage. Stage opens → drawer
        // opens; stage closes → drawer closes.
        ui.$isStageExpanded
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] open in
                self?.ui.isExpanded = open
                if !open {
                    self?.ui.setTerminalRenderingAllowed(false)
                }
                self?.updateScreenTabPanels()
                self?.updateSurfacePerformanceState()
            }
            .store(in: &cancellables)

        ui.$terminalRenderingAllowed
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateSurfacePerformanceState() }
            .store(in: &cancellables)

        ui.$stageShowsEditor
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateSurfacePerformanceState() }
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


        ui.$isSliding
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateSurfacePerformanceState() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .gaiTerminalNotificationDidArrive)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleTerminalNotification(notification)
            }
            .store(in: &cancellables)

        store.$unreadNotificationCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.updateDockNotificationBadge(count)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .ghosttyBellDidRing)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let surface = notification.object as? Ghostty.SurfaceView else { return }
                self?.handleTerminalBell(surface)
            }
            .store(in: &cancellables)

        // Resize if the workspace count changes, and give any freshly created
        // workspace its terminal right away (so opening it never jumps).
        store.$workspaces
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncWorkspaceSelection()
                self?.refreshGeometry()
                self?.warmFirstSurfaces()
                self?.refreshSurfacePersistenceObservers()
                self?.updateSurfacePerformanceState()
            }
            .store(in: &cancellables)

        // Opening/closing a workspace swaps the stage's content; the stage always
        // shows *something* (the open workspace, or the default scratch terminal).
        store.$openWorkspaceID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncWorkspaceSelection()
                self?.showStage()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGeometry() }
            .store(in: &cancellables)

        // Clicking another app or the desktop makes GaiTerm resign active — that
        // single click switches apps natively; we just fold the block away.
        NotificationCenter.default
            .publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.dismissBlock() }
            .store(in: &cancellables)
    }

    private func installModifierShortcutMonitors() {
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleModifierShortcut(event)
            return event
        }

        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            DispatchQueue.main.async {
                self?.handleModifierShortcut(event)
            }
        }
    }

    private func handleModifierShortcut(_ event: NSEvent) {
        let leftOptionKey: UInt16 = 0x3A
        let rightOptionKey: UInt16 = 0x3D
        guard event.keyCode == leftOptionKey || event.keyCode == rightOptionKey else { return }

        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let optionIsDown = flags.contains(.option)

        guard optionIsDown else {
            shortcutOptionIsDown = false
            return
        }

        guard !shortcutOptionIsDown else { return }
        shortcutOptionIsDown = true

        // Require Option alone. Option+another modifier is normal shortcut
        // input and should not count toward the double tap.
        guard flags.subtracting(.option).isEmpty else {
            lastOptionTapTime = nil
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastOptionTapTime,
           now - last <= modifierDoubleTapInterval {
            lastOptionTapTime = nil
            toggleBlockFromModifierShortcut()
        } else {
            lastOptionTapTime = now
        }
    }

    private func handleTerminalNotification(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView else { return }
        guard !isSurfaceCurrentlyViewed(surface) else { return }

        let title = notification.userInfo?[Notification.Name.GaiTerminalNotificationTitleKey] as? String
        let body = notification.userInfo?[Notification.Name.GaiTerminalNotificationBodyKey] as? String
        let workspace = splits.workspace(containing: surface)
        let session = workspace?.session(for: surface)
        let notificationTitle = if let title, !title.isEmpty {
            title
        } else {
            session?.name ?? "Terminal"
        }

        let notificationBody = body ?? ""
        let recorded = store.recordNotification(
            for: surface,
            title: notificationTitle,
            body: notificationBody,
            attention: .needsInput)
        handleAutoFocusNotification(surface, workspace: workspace, session: session)
        let notificationsEnabled = session?.notificationsEnabled ?? true
        let shouldDeliverSystemNotification = recorded && notificationsEnabled

        if isGenericTurnComplete(title: notificationTitle, body: notificationBody) {
            scheduleGenericNotificationFallback(
                surface,
                workspace: workspace,
                title: notificationTitle,
                body: notificationBody,
                shouldPlaySound: notificationsEnabled,
                shouldDeliverSystemNotification: shouldDeliverSystemNotification)
            return
        }

        cancelGenericNotificationFallback(for: surface)
        if notificationsEnabled {
            playAgentNotificationSoundIfNeeded(
                surface,
                workspace: workspace,
                title: notificationTitle,
                body: notificationBody)
        }
        if shouldDeliverSystemNotification {
            deliverSystemNotification(
                surface,
                workspace: workspace,
                title: notificationTitle,
                body: notificationBody)
        }
    }

    private func handleTerminalBell(_ surface: Ghostty.SurfaceView) {
        guard !isSurfaceCurrentlyViewed(surface) else { return }
        store.recordBell(for: surface)
    }

    private func isSurfaceCurrentlyViewed(_ surface: Ghostty.SurfaceView) -> Bool {
        guard NSApp.isActive,
              stagePanel?.isVisible == true,
              ui.isStageExpanded,
              ui.terminalRenderingAllowed,
              !ui.isSliding,
              !ui.stageShowsEditor
        else { return false }

        let visibleViews = visibleTerminalSurfaces(in: store.stageWorkspace)
        guard visibleViews.contains(where: { $0 === surface }) else { return false }
        return focusedSurface() === surface
    }

    private func deliverSystemNotification(
        _ surface: Ghostty.SurfaceView,
        workspace: GaiWorkspace?,
        title: String,
        body: String
    ) {
        guard GaiNotificationSoundLibrary.desktopNotificationsEnabled() else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.scheduleSystemNotification(surface, workspace: workspace, title: title, body: body)

            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    if let error {
                        Ghostty.logger.error("Error while requesting notification authorization: \(error, privacy: .public)")
                    }
                    guard granted else { return }
                    self.scheduleSystemNotification(surface, workspace: workspace, title: title, body: body)
                }

            default:
                return
            }
        }
    }

    private func scheduleSystemNotification(
        _ surface: Ghostty.SurfaceView,
        workspace: GaiWorkspace?,
        title: String,
        body: String
    ) {
        let displayTitle = systemNotificationTitle(surface: surface, workspace: workspace, fallbackTitle: title)
        DispatchQueue.main.async {
            surface.showUserNotification(
                title: displayTitle,
                body: body,
                subtitle: "",
                requireFocus: false,
                sound: nil)
        }
    }

    private func scheduleGenericNotificationFallback(
        _ surface: Ghostty.SurfaceView,
        workspace: GaiWorkspace?,
        title: String,
        body: String,
        shouldPlaySound: Bool,
        shouldDeliverSystemNotification: Bool
    ) {
        guard shouldPlaySound || shouldDeliverSystemNotification else {
            cancelGenericNotificationFallback(for: surface)
            return
        }

        let key = ObjectIdentifier(surface)
        pendingGenericExternalNotifications[key]?.cancel()

        let work = DispatchWorkItem { [weak self, weak surface, weak workspace] in
            guard let self, let surface else { return }
            self.pendingGenericExternalNotifications[ObjectIdentifier(surface)] = nil
            if shouldPlaySound {
                self.playAgentNotificationSoundIfNeeded(
                    surface,
                    workspace: workspace,
                    title: title,
                    body: body)
            }
            if shouldDeliverSystemNotification {
                self.deliverSystemNotification(
                    surface,
                    workspace: workspace,
                    title: title,
                    body: body)
            }
        }
        pendingGenericExternalNotifications[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func playAgentNotificationSoundIfNeeded(
        _ surface: Ghostty.SurfaceView,
        workspace: GaiWorkspace?,
        title: String,
        body: String
    ) {
        let currentWorkspace = workspace ?? splits.workspace(containing: surface)
        guard currentWorkspace?.session(for: surface)?.shouldPlayNotificationSound(
            title: title,
            body: body,
            attention: .needsInput) ?? true
        else { return }

        GaiNotificationSoundPlayer.shared.playSelectedNotificationSound()
    }

    private func handleAutoFocusNotification(
        _ surface: Ghostty.SurfaceView,
        workspace: GaiWorkspace?,
        session: GaiTerminalSession?
    ) {
        guard session?.autoFocusOnNotification == true else { return }
        DispatchQueue.main.async { [weak self, weak surface, weak workspace] in
            guard let self, let surface else { return }
            self.focusSurfaceForAutoNotification(surface, workspace: workspace)
        }
    }

    private func focusSurfaceForAutoNotification(
        _ surface: Ghostty.SurfaceView,
        workspace: GaiWorkspace?
    ) {
        start()
        if let workspace {
            store.openWorkspaceID = workspace.id
            ui.selectedWorkspaceID = workspace.id
        }
        if ui.stageShowsEditor { ui.stageShowsEditor = false }
        showStage()
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let self, let surface else { return }
            Ghostty.moveFocus(to: surface)
            self.applyImmediateFocus(to: surface)
        }
    }

    private func cancelGenericNotificationFallback(for surface: Ghostty.SurfaceView) {
        let key = ObjectIdentifier(surface)
        pendingGenericExternalNotifications[key]?.cancel()
        pendingGenericExternalNotifications[key] = nil
    }

    private func isGenericTurnComplete(title: String, body: String) -> Bool {
        normalizedNotificationText(body) == "turn complete"
            || normalizedNotificationText(title) == "turn complete"
    }

    private func normalizedNotificationText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .lowercased()
    }

    private func systemNotificationTitle(
        surface: Ghostty.SurfaceView,
        workspace: GaiWorkspace?,
        fallbackTitle: String
    ) -> String {
        let cleanFallback = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspace else { return cleanFallback.isEmpty ? "DouDou Company" : cleanFallback }
        let workspaceName = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = systemNotificationFolderName(surface: surface, workspace: workspace)

        switch (workspaceName.isEmpty, folderName.isEmpty) {
        case (false, false):
            return "\(workspaceName) - \(folderName)"
        case (false, true):
            return workspaceName
        case (true, false):
            return folderName
        case (true, true):
            return cleanFallback.isEmpty ? "DouDou Company" : cleanFallback
        }
    }

    private func systemNotificationFolderName(
        surface: Ghostty.SurfaceView,
        workspace: GaiWorkspace
    ) -> String {
        let path = surface.pwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? workspace.defaultDirectory?.path
            ?? ""
        guard !path.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func updateDockNotificationBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(min(count, 99))" : nil
        NSApp.dockTile.display()
    }

    private func refreshGeometry() {
        recomputeCardHeight()
        constrainPanelWidths()
        snapPanel(open: ui.isExpanded)
        if stagePanel?.isVisible == true {
            snapStagePanel(open: ui.isStageExpanded)
        }
        ensureScreenTabPanels()
    }

    /// Keep drawer selection and stage workspace coherent. When real
    /// workspaces exist, GaiTerm should never sit on an unselected scratch
    /// workspace; scratch is reserved for an actually empty workspace list.
    @discardableResult
    private func syncWorkspaceSelection() -> GaiWorkspace.ID? {
        guard let first = store.workspaces.first else {
            if store.openWorkspaceID != nil { store.openWorkspaceID = nil }
            if ui.selectedWorkspaceID != nil { ui.selectedWorkspaceID = nil }
            return nil
        }

        let target =
            store.workspace(for: store.openWorkspaceID)?.id
            ?? store.workspace(for: ui.selectedWorkspaceID)?.id
            ?? first.id

        if store.openWorkspaceID != target {
            store.openWorkspaceID = target
        }
        if ui.selectedWorkspaceID != target {
            ui.selectedWorkspaceID = target
        }
        return target
    }
}

private struct GaiStageScreenTabProxyView: View {
    @ObservedObject var store: GaiWorkspaceStore
    let onOpen: () -> Void

    @State private var pressed = false
    @AppStorage(GaiPreferenceKey.tintGlassWithWorkspaceAccent) private var tintPanels = false

    private typealias D = GaiDrawerMetrics
    private var slabWidth: CGFloat { 360 + D.tabWidth + D.bleed }

    var body: some View {
        ZStack(alignment: .leading) {
            GaiStageSlabShape()
                .fill(Color.gaiPanelColor(
                    accent: store.stageWorkspace.accentColor,
                    tinted: tintPanels))
                .frame(width: slabWidth)
                .frame(maxHeight: .infinity)
                .frame(width: D.tabWidth, alignment: .leading)
                .clipped()

            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                .scaleEffect(pressed ? 0.8 : 1)
                .animation(.easeOut(duration: 0.08), value: pressed)
                .frame(width: D.tabWidth, height: D.tabExtent)
        }
        .frame(width: D.tabWidth)
        .frame(maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in
                    pressed = false
                    onOpen()
                })
    }
}

// MARK: - Agent notification hooks

/// Installs provider-native lifecycle hooks for terminals hosted by DouDou
/// Company. Typed events use the identity inherited from each terminal, so the
/// installed Release and a Debug build can coexist without cross-talk.
enum GaiAgentHookInstaller {
    private static let codexHookMarker = "gaiterm-codex-stop-notify"
    private static let claudeHookMarker = "gaiterm-claude-stop-notify"
    private static let agyHookMarker = "gaiterm-agy-stop-notify"
    private static let agentEventHookMarker = "gaiterm-agent-event-v1"
    private static let agyHookGroupName = "gaiterm-agent-lifecycle-v1"

    // Older GaiTerm builds may have written this feature block. Keep its marker
    // constants for compatibility, but never mutate the user's TOML features.
    private static let codexFeatureBegin = "# gaiterm-codex-hooks-feature begin"
    private static let codexFeatureEnd = "# gaiterm-codex-hooks-feature end"
    private static let codexTrustBegin = "# gaiterm-codex-hook-trust begin"
    private static let codexTrustEnd = "# gaiterm-codex-hook-trust end"
    private static let codexTypedTrustBegin = "# gaiterm-codex-agent-event-trust-v1 begin"
    private static let codexTypedTrustEnd = "# gaiterm-codex-agent-event-trust-v1 end"

    private struct HookSpec: Sendable {
        let eventName: String
        let eventLabel: String
        let command: String

        init(
            eventName: String,
            eventLabel: String? = nil,
            provider: String,
            kind: String
        ) {
            self.eventName = eventName
            self.eventLabel = eventLabel ?? eventName
            self.command = GaiAgentHookInstaller.agentEventCommand(
                provider: provider,
                kind: kind)
        }

        init(
            legacyStopProvider provider: String,
            title: String,
            marker: String
        ) {
            self.eventName = "Stop"
            self.eventLabel = "stop"
            self.command = GaiAgentHookInstaller.legacyStopCommand(
                provider: provider,
                title: title,
                marker: marker)
        }
    }

    private struct CodexTrustEntry: Sendable {
        let key: String
        let trustedHash: String
    }

    private static let codexHookSpecs = [
        HookSpec(
            eventName: "SessionStart",
            eventLabel: "session_start",
            provider: "codex",
            kind: "ready"),
        HookSpec(
            eventName: "UserPromptSubmit",
            eventLabel: "user_prompt_submit",
            provider: "codex",
            kind: "started"),
        HookSpec(
            eventName: "PermissionRequest",
            eventLabel: "permission_request",
            provider: "codex",
            kind: "awaitingApproval"),
        HookSpec(
            eventName: "PostToolUse",
            eventLabel: "post_tool_use",
            provider: "codex",
            kind: "resumed"),
        HookSpec(
            eventName: "Stop",
            eventLabel: "stop",
            provider: "codex",
            kind: "stop"),
        HookSpec(
            eventName: "SessionEnd",
            eventLabel: "session_end",
            provider: "codex",
            kind: "cancelled"),
    ]
    private static let codexLegacyStopSpec = HookSpec(
        legacyStopProvider: "codex",
        title: "Codex",
        marker: codexHookMarker)

    private static let claudeHookSpecs = [
        HookSpec(eventName: "SessionStart", provider: "claude", kind: "ready"),
        HookSpec(eventName: "UserPromptSubmit", provider: "claude", kind: "started"),
        HookSpec(eventName: "PermissionRequest", provider: "claude", kind: "awaitingApproval"),
        HookSpec(eventName: "PostToolUse", provider: "claude", kind: "resumed"),
        HookSpec(eventName: "Stop", provider: "claude", kind: "stop"),
        HookSpec(eventName: "StopFailure", provider: "claude", kind: "failed"),
        HookSpec(eventName: "SessionEnd", provider: "claude", kind: "cancelled"),
    ]
    private static let claudeLegacyStopSpec = HookSpec(
        legacyStopProvider: "claude",
        title: "Claude%20Code",
        marker: claudeHookMarker)

    /// Filtering occurs before both typed and legacy transport decisions so a
    /// child agent can never change the desktop state of its parent terminal.
    /// Claude's `--agent` main process legitimately carries `agent_type`, so it
    /// is identified by `agent_id` or the explicit SubagentStop event instead.
    private static func rootAgentPayloadGuard(provider: String) -> String {
        let agentID =
            "agent_id=$(/usr/bin/printf \"%s\" \"$payload\" | " +
            "/usr/bin/plutil -extract agent_id raw -o - -- - || true); "
        if provider == "claude" {
            return agentID +
                "hook_event=$(/usr/bin/printf \"%s\" \"$payload\" | " +
                "/usr/bin/plutil -extract hook_event_name raw -o - -- - || true); " +
                "if [ -n \"$agent_id\" ] || [ \"$hook_event\" = \"SubagentStop\" ]; " +
                "then exit 0; fi; "
        }
        return agentID +
            "agent_type=$(/usr/bin/printf \"%s\" \"$payload\" | " +
            "/usr/bin/plutil -extract agent_type raw -o - -- - || true); " +
            "if [ -n \"$agent_id\" ] || [ -n \"$agent_type\" ]; then exit 0; fi; "
    }

    /// This command is deliberately self-contained: hook processes inherit the
    /// terminal surface environment, consume their complete JSON payload, and
    /// never write to stdout (some providers inject stdout into model context).
    /// Only conservative URL-safe correlation identifiers leave the process.
    private static func agentEventCommand(
        provider: String,
        kind: String
    ) -> String {
        return
            "/bin/sh -c ': \(agentEventHookMarker)-\(provider)-\(kind); " +
            "exec >/dev/null 2>&1; " +
            "payload=$(/bin/cat || true); " +
            rootAgentPayloadGuard(provider: provider) +
            "surface=\"${GAITERM_SURFACE_ID:-}\"; token=\"${GAITERM_EVENT_TOKEN:-}\"; " +
            "case \"$surface\" in \"\"|*[!A-Za-z0-9._:-]*) exit 0 ;; esac; " +
            "case \"$token\" in \"\"|*[!A-Za-z0-9._:-]*) exit 0 ;; esac; " +
            "turn=$(/usr/bin/printf \"%s\" \"$payload\" | " +
            "/usr/bin/plutil -extract turn_id raw -o - -- - || true); " +
            "if [ -n \"$turn\" ]; then turn=\"turn:$turn\"; else " +
            "turn=$(/usr/bin/printf \"%s\" \"$payload\" | " +
            "/usr/bin/plutil -extract prompt_id raw -o - -- - || true); " +
            "if [ -n \"$turn\" ]; then turn=\"turn:$turn\"; else " +
            "turn=$(/usr/bin/printf \"%s\" \"$payload\" | " +
            "/usr/bin/plutil -extract user_prompt_id raw -o - -- - || true); " +
            "if [ -n \"$turn\" ]; then turn=\"turn:$turn\"; else " +
            "turn=$(/usr/bin/printf \"%s\" \"$payload\" | " +
            "/usr/bin/plutil -extract session_id raw -o - -- - || true); " +
            "if [ -n \"$turn\" ]; then turn=\"session:$turn\"; fi; fi; fi; fi; " +
            "case \"$turn\" in *[!A-Za-z0-9._:-]*) turn= ;; esac; " +
            "event=$(/usr/bin/uuidgen | /usr/bin/tr \"[:upper:]\" \"[:lower:]\"); " +
            "scheme=\"${GAITERM_NOTIFY_URL_SCHEME:-gaiterm}\"; " +
            "bundle=\"${GAITERM_NOTIFY_BUNDLE_ID:-com.sipiyou.gaiterm}\"; " +
            "case \"$scheme:$bundle\" in *[!A-Za-z0-9._:+-]*) exit 0 ;; esac; " +
            "url=\"$scheme://agent-event?v=1&surface=$surface&token=$token" +
            "&provider=\(provider)&kind=\(kind)&event=\(provider)-\(kind)-$event\"; " +
            "if [ -n \"$turn\" ]; then url=\"$url&turn=$turn\"; fi; " +
            "socket=\"${GAITERM_EVENT_SOCKET:-}\"; " +
            "case \"$socket\" in /*) " +
            "reply=$(/usr/bin/printf \"%s\\n\" \"$url\" | " +
            "/usr/bin/nc -U -w 2 \"$socket\" || true); " +
            "if [ \"$reply\" = \"OK\" ]; then exit 0; fi ;; esac; " +
            "/usr/bin/open -g -b \"$bundle\" \"$url\" || true; exit 0'"
    }

    /// Compatibility notification kept as a distinct Stop handler. It cannot
    /// emit while an authenticated companion token is present, and carries no
    /// typed-event marker or token in its URL.
    private static func legacyStopCommand(
        provider: String,
        title: String,
        marker: String
    ) -> String {
        "/bin/sh -c ': gaiterm-legacy-stop-\(provider); : \(marker); " +
            "exec >/dev/null 2>&1; " +
            "payload=$(/bin/cat || true); " +
            rootAgentPayloadGuard(provider: provider) +
            "surface=\"${GAITERM_SURFACE_ID:-}\"; token=\"${GAITERM_EVENT_TOKEN:-}\"; " +
            "case \"$surface\" in \"\"|*[!A-Za-z0-9._:-]*) exit 0 ;; esac; " +
            "if [ -n \"$token\" ]; then exit 0; fi; " +
            "scheme=\"${GAITERM_NOTIFY_URL_SCHEME:-gaiterm}\"; " +
            "bundle=\"${GAITERM_NOTIFY_BUNDLE_ID:-com.sipiyou.gaiterm}\"; " +
            "case \"$scheme:$bundle\" in *[!A-Za-z0-9._:+-]*) exit 0 ;; esac; " +
            "url=\"$scheme://notify?surface=$surface&title=\(title)&body=Turn%20complete\"; " +
            "/usr/bin/open -g -b \"$bundle\" \"$url\" || true; exit 0'"
    }

    /// Antigravity uses a named root hook group and camelCase payload fields.
    /// Its invocation and Stop hooks also have an explicit JSON stdout contract,
    /// so this adapter cannot share Claude/Codex's silent command wrapper.
    private static func agyAgentEventCommand(
        kind: String,
        stopCanFail: Bool = false,
        includesLegacyStopFallback: Bool = false
    ) -> String {
        let responseJSON = includesLegacyStopFallback
            ? "{\\\"decision\\\":\\\"\\\"}"
            : "{}"
        let kindResolution: String
        if stopCanFail {
            kindResolution =
                "kind=stop; " +
                "termination=$(/usr/bin/printf \"%s\" \"$payload\" | " +
                "/usr/bin/plutil -extract terminationReason raw -o - -- - 2>/dev/null || true); " +
                "hook_error=$(/usr/bin/printf \"%s\" \"$payload\" | " +
                "/usr/bin/plutil -extract error raw -o - -- - 2>/dev/null || true); " +
                "fully_idle=$(/usr/bin/printf \"%s\" \"$payload\" | " +
                "/usr/bin/plutil -extract fullyIdle raw -o - -- - 2>/dev/null || true); " +
                "if [ \"$fully_idle\" = \"false\" ]; then respond; exit 0; fi; " +
                "if [ -n \"$hook_error\" ] || [ \"$termination\" = \"error\" ]; " +
                "then kind=failed; fi; "
        } else {
            kindResolution = "kind=\(kind); "
        }

        let invalidTokenAction: String
        if includesLegacyStopFallback {
            invalidTokenAction =
                "scheme=\"${GAITERM_NOTIFY_URL_SCHEME:-gaiterm}\"; " +
                "bundle=\"${GAITERM_NOTIFY_BUNDLE_ID:-com.sipiyou.gaiterm}\"; " +
                "case \"$scheme:$bundle\" in *[!A-Za-z0-9._:+-]*) respond; exit 0 ;; esac; " +
                "legacy_url=\"$scheme://notify?surface=$surface&title=Agy&body=Turn%20complete\"; " +
                "/usr/bin/open -g -b \"$bundle\" \"$legacy_url\" >/dev/null 2>&1 || true; " +
                "respond; exit 0; "
        } else {
            invalidTokenAction = "respond; exit 0; "
        }

        let legacyMarker = includesLegacyStopFallback ? "; : \(agyHookMarker)" : ""
        return
            "/bin/sh -c ': \(agentEventHookMarker)-agy-\(kind)\(legacyMarker); " +
            "respond() { /usr/bin/printf \"%s\\n\" \"\(responseJSON)\"; }; " +
            "payload=$(/bin/cat || true); " +
            kindResolution +
            "surface=\"${GAITERM_SURFACE_ID:-}\"; token=\"${GAITERM_EVENT_TOKEN:-}\"; " +
            "case \"$surface\" in \"\"|*[!A-Za-z0-9._:-]*) respond; exit 0 ;; esac; " +
            "case \"$token\" in \"\"|*[!A-Za-z0-9._:-]*) \(invalidTokenAction) ;; esac; " +
            "conversation=$(/usr/bin/printf \"%s\" \"$payload\" | " +
            "/usr/bin/plutil -extract conversationId raw -o - -- - 2>/dev/null || true); " +
            "turn=; if [ -n \"$conversation\" ]; then turn=\"session:$conversation\"; fi; " +
            "case \"$turn\" in *[!A-Za-z0-9._:-]*) turn= ;; esac; " +
            "event=$(/usr/bin/uuidgen | /usr/bin/tr \"[:upper:]\" \"[:lower:]\"); " +
            "scheme=\"${GAITERM_NOTIFY_URL_SCHEME:-gaiterm}\"; " +
            "bundle=\"${GAITERM_NOTIFY_BUNDLE_ID:-com.sipiyou.gaiterm}\"; " +
            "case \"$scheme:$bundle\" in *[!A-Za-z0-9._:+-]*) respond; exit 0 ;; esac; " +
            "url=\"$scheme://agent-event?v=1&surface=$surface&token=$token" +
            "&provider=agy&kind=$kind&event=agy-$kind-$event\"; " +
            "if [ -n \"$turn\" ]; then url=\"$url&turn=$turn\"; fi; " +
            "socket=\"${GAITERM_EVENT_SOCKET:-}\"; " +
            "case \"$socket\" in /*) " +
            "reply=$(/usr/bin/printf \"%s\\n\" \"$url\" | " +
            "/usr/bin/nc -U -w 2 \"$socket\" 2>/dev/null || true); " +
            "if [ \"$reply\" = \"OK\" ]; then respond; exit 0; fi ;; esac; " +
            "/usr/bin/open -g -b \"$bundle\" \"$url\" " +
            ">/dev/null 2>&1 || true; respond; exit 0'"
    }

    /// Provider processes snapshot these files when they launch. Keep this
    /// bounded file-only work synchronous so no agent PTY can beat its adapter.
    static func installBeforeLaunchingCompanionSurfaces() {
        install("Codex") {
            try installCodexHooks()
        }
        install("Claude Code") {
            try installClaudeHooks()
        }
        install("Agy") {
            try installAgyHooks()
        }
        install("OpenCode") {
            try installOpenCodePlugin()
        }
    }

    private static func install(_ name: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            Ghostty.logger.error("Failed to install \(name, privacy: .public) notification hook: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func installCodexHooks() throws {
        let home = codexHome()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let hooksURL = home.appendingPathComponent("hooks.json", isDirectory: false)
        var root = try readJSONObject(at: hooksURL)
        let existingHooks = root["hooks"]
        guard existingHooks == nil || existingHooks is [String: Any] else {
            throw HookInstallError.invalidHooksObject(provider: "Codex")
        }
        var hooks = existingHooks as? [String: Any] ?? [:]
        removeManagedHooks(from: &hooks)

        var typedTrustEntries: [CodexTrustEntry] = []
        for spec in codexHookSpecs {
            typedTrustEntries.append(try appendCodexHook(spec, to: &hooks, at: hooksURL))
        }
        let legacyTrustEntry = try appendCodexHook(
            codexLegacyStopSpec,
            to: &hooks,
            at: hooksURL)
        root["hooks"] = hooks
        try writeJSONObjectIfChanged(root, to: hooksURL)

        try installCodexTrust(
            in: home.appendingPathComponent("config.toml", isDirectory: false),
            typedEntries: typedTrustEntries,
            legacyEntries: [legacyTrustEntry])
    }

    /// Retained for migration tests and older compatibility maintenance.
    private static func installCodexLegacyStopHook() throws {
        let home = codexHome()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let hooksURL = home.appendingPathComponent("hooks.json", isDirectory: false)
        var root = try readJSONObject(at: hooksURL)
        let existingHooks = root["hooks"]
        guard existingHooks == nil || existingHooks is [String: Any] else {
            throw HookInstallError.invalidHooksObject(provider: "Codex")
        }
        var hooks = existingHooks as? [String: Any] ?? [:]
        var groups = try hookGroups(for: "Stop", in: hooks, provider: "Codex")
        groups = removingHookMarker(codexHookMarker, from: groups)
        groups.append([
            "hooks": [[
                "type": "command",
                "command": codexLegacyStopSpec.command,
                "timeout": 5,
            ]],
        ])
        hooks["Stop"] = groups
        root["hooks"] = hooks
        try writeJSONObjectIfChanged(root, to: hooksURL)

        let hookIndex = max(groups.count - 1, 0)
        let key = "\(normalizedHookSourcePath(hooksURL.path)):stop:\(hookIndex):0"
        let hash = codexCommandHookHash(
            eventLabel: "stop",
            matcher: nil,
            command: codexLegacyStopSpec.command,
            timeout: 5,
            statusMessage: nil)
        try installCodexLegacyTrust(
            in: home.appendingPathComponent("config.toml", isDirectory: false),
            entry: CodexTrustEntry(key: key, trustedHash: hash))
    }

    private static func appendCodexHook(
        _ spec: HookSpec,
        to hooks: inout [String: Any],
        at hooksURL: URL
    ) throws -> CodexTrustEntry {
        var groups = try hookGroups(for: spec.eventName, in: hooks, provider: "Codex")
        groups.append([
            "hooks": [[
                "type": "command",
                "command": spec.command,
                "timeout": 5,
            ]],
        ])
        hooks[spec.eventName] = groups

        let hookIndex = max(groups.count - 1, 0)
        let trustKey =
            "\(normalizedHookSourcePath(hooksURL.path)):\(spec.eventLabel):\(hookIndex):0"
        let trustedHash = codexCommandHookHash(
            eventLabel: spec.eventLabel,
            matcher: nil,
            command: spec.command,
            timeout: 5,
            statusMessage: nil)
        return CodexTrustEntry(key: trustKey, trustedHash: trustedHash)
    }

    private static func installClaudeHooks() throws {
        let home = claudeConfigDirectory()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // Claude's user-wide configuration is settings.json. Keep both the
        // authenticated adapter and the token-gated legacy compatibility
        // handler in that one supported scope so either build may run without
        // disabling the other.
        try installJSONHooks(
            claudeHookSpecs + [claudeLegacyStopSpec],
            at: claudeGlobalSettingsURL(in: home),
            providerName: "Claude Code",
            includeMatcher: true)
    }

    private static func installClaudeLegacyStopHook() throws {
        let home = claudeConfigDirectory()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settingsURL = claudeGlobalSettingsURL(in: home)
        var root = try readJSONObject(at: settingsURL)
        root = try claudeLegacyHooksConfiguration(from: root)
        try writeJSONObjectIfChanged(root, to: settingsURL)
    }

    /// Compatibility-only updater retained for older configuration migrations.
    /// Typed handlers and every user hook remain represented in the JSON model.
    private static func claudeLegacyHooksConfiguration(
        from existing: [String: Any]
    ) throws -> [String: Any] {
        var root = existing
        let existingHooks = root["hooks"]
        guard existingHooks == nil || existingHooks is [String: Any] else {
            throw HookInstallError.invalidHooksObject(provider: "Claude Code")
        }
        var hooks = existingHooks as? [String: Any] ?? [:]
        var groups = try hookGroups(for: "Stop", in: hooks, provider: "Claude Code")
        groups = removingHookMarker(claudeHookMarker, from: groups)
        groups.append([
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": claudeLegacyStopSpec.command,
            ]],
        ])
        hooks["Stop"] = groups
        root["hooks"] = hooks
        return root
    }

    private static func installAgyHooks() throws {
        let hooksURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/config/hooks.json", isDirectory: false)
        let existing = try readJSONObject(at: hooksURL)
        let updated = try agyHooksConfiguration(from: existing)
        try writeJSONObjectIfChanged(updated, to: hooksURL)
    }

    /// Antigravity's root is a dictionary of independently named hook groups,
    /// not the Claude/Codex `{ "hooks": { event: ... } }` envelope. Migrate any
    /// older GaiTerm handlers wherever they were written, retain every user
    /// group/handler, then own one versioned group with the provider's native
    /// direct-vs-matcher event shapes.
    private static func agyHooksConfiguration(
        from existing: [String: Any]
    ) throws -> [String: Any] {
        var root = existing
        removeManagedAgyHooks(from: &root)

        let existingGroup = root[agyHookGroupName]
        guard existingGroup == nil || existingGroup is [String: Any] else {
            throw HookInstallError.invalidHooksObject(provider: "Agy GaiTerm group")
        }
        var group = existingGroup as? [String: Any] ?? [:]
        group["enabled"] = true

        var invocationHandlers = try directHookHandlers(
            for: "PreInvocation",
            in: group,
            provider: "Agy")
        invocationHandlers.append([
            "type": "command",
            "command": agyAgentEventCommand(kind: "started"),
            "timeout": 5,
        ])
        group["PreInvocation"] = invocationHandlers

        var toolGroups = try hookGroups(
            for: "PostToolUse",
            in: group,
            provider: "Agy")
        toolGroups.append([
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": agyAgentEventCommand(kind: "resumed"),
                "timeout": 5,
            ]],
        ])
        group["PostToolUse"] = toolGroups

        var stopHandlers = try directHookHandlers(
            for: "Stop",
            in: group,
            provider: "Agy")
        stopHandlers.append([
            "type": "command",
            "command": agyAgentEventCommand(
                kind: "stop",
                stopCanFail: true,
                includesLegacyStopFallback: true),
            "timeout": 5,
        ])
        group["Stop"] = stopHandlers
        root[agyHookGroupName] = group
        return root
    }

    private static func directHookHandlers(
        for eventName: String,
        in group: [String: Any],
        provider: String
    ) throws -> [[String: Any]] {
        guard let value = group[eventName] else { return [] }
        guard let handlers = value as? [[String: Any]] else {
            throw HookInstallError.invalidEventHooks(provider: provider, event: eventName)
        }
        return handlers
    }

    /// Remove only commands carrying a GaiTerm marker. This handles both the
    /// official direct handler arrays and the matcher-group shape emitted by an
    /// older Debug build without normalizing unrelated user JSON.
    private static func removeManagedAgyHooks(from root: inout [String: Any]) {
        for groupName in Array(root.keys) {
            guard var group = root[groupName] as? [String: Any] else { continue }
            for eventName in Array(group.keys) {
                guard let entries = group[eventName] as? [[String: Any]] else { continue }
                let retained = entries.compactMap { entry -> [String: Any]? in
                    if let command = entry["command"] as? String,
                       isManagedHookCommand(command) {
                        return nil
                    }

                    var updated = entry
                    guard var handlers = updated["hooks"] as? [[String: Any]] else {
                        return updated
                    }
                    handlers.removeAll { handler in
                        guard let command = handler["command"] as? String else { return false }
                        return isManagedHookCommand(command)
                    }
                    guard !handlers.isEmpty else { return nil }
                    updated["hooks"] = handlers
                    return updated
                }

                if retained.isEmpty {
                    group.removeValue(forKey: eventName)
                } else {
                    group[eventName] = retained
                }
            }

            if group.isEmpty {
                root.removeValue(forKey: groupName)
            } else {
                root[groupName] = group
            }
        }
    }

    private static func installJSONHooks(
        _ specs: [HookSpec],
        at url: URL,
        providerName: String,
        includeMatcher: Bool
    ) throws {
        let existing = try readJSONObject(at: url)
        let updated = try jsonHooksConfiguration(
            specs,
            from: existing,
            providerName: providerName,
            includeMatcher: includeMatcher)
        try writeJSONObjectIfChanged(updated, to: url)
    }

    private static func jsonHooksConfiguration(
        _ specs: [HookSpec],
        from existing: [String: Any],
        providerName: String,
        includeMatcher: Bool
    ) throws -> [String: Any] {
        var root = existing
        let existingHooks = root["hooks"]
        guard existingHooks == nil || existingHooks is [String: Any] else {
            throw HookInstallError.invalidHooksObject(provider: providerName)
        }
        var hooks = existingHooks as? [String: Any] ?? [:]
        removeManagedHooks(from: &hooks)

        for spec in specs {
            var groups = try hookGroups(for: spec.eventName, in: hooks, provider: providerName)
            var group: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": spec.command,
                ]],
            ]
            if includeMatcher { group["matcher"] = "" }
            groups.append(group)
            hooks[spec.eventName] = groups
        }

        root["hooks"] = hooks
        return root
    }

    private static func hookGroups(
        for eventName: String,
        in hooks: [String: Any],
        provider: String
    ) throws -> [[String: Any]] {
        guard let value = hooks[eventName] else { return [] }
        guard let groups = value as? [[String: Any]] else {
            throw HookInstallError.invalidEventHooks(provider: provider, event: eventName)
        }
        return groups
    }

    private static func removeManagedHooks(from hooks: inout [String: Any]) {
        for (eventName, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            hooks[eventName] = removingManagedHooks(from: groups)
        }
    }

    private static func removingManagedHooks(
        from groups: [[String: Any]]
    ) -> [[String: Any]] {
        groups.compactMap { group in
            var updated = group
            guard var hookList = updated["hooks"] as? [[String: Any]] else { return updated }
            hookList.removeAll { hook in
                guard let command = hook["command"] as? String else { return false }
                return isManagedHookCommand(command)
            }
            guard !hookList.isEmpty else { return nil }
            updated["hooks"] = hookList
            return updated
        }
    }

    private static func removingHookMarker(
        _ marker: String,
        from groups: [[String: Any]]
    ) -> [[String: Any]] {
        groups.compactMap { group in
            var updated = group
            guard var hookList = updated["hooks"] as? [[String: Any]] else { return updated }
            hookList.removeAll { hook in
                (hook["command"] as? String)?.contains(marker) == true
            }
            guard !hookList.isEmpty else { return nil }
            updated["hooks"] = hookList
            return updated
        }
    }

    private static func isManagedHookCommand(_ command: String) -> Bool {
        command.contains(agentEventHookMarker)
            || command.contains(codexHookMarker)
            || command.contains(claudeHookMarker)
            || command.contains(agyHookMarker)
    }

    private static func installOpenCodePlugin() throws {
        let pluginURL = openCodeConfigDirectory()
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("gaiterm-agent-events.js", isDirectory: false)
        try writeDataIfChanged(Data(openCodePluginSource.utf8), to: pluginURL)
    }

    /// OpenCode exposes lifecycle state directly rather than through command
    /// hooks. One terminal represents one employee, so aggregate every root
    /// session in that process into a single work cycle. Child sessions never
    /// affect desktop state, and the employee completes only when the final
    /// active root session becomes idle.
    // Keep JavaScript escape sequences literal. A normal Swift multiline string
    // would turn `\n` and `\r\n` into real line breaks inside JavaScript string
    // literals, producing a plugin which OpenCode cannot parse.
    private static let openCodePluginSource = #"""
    // Installed by GaiTerm. Marker: gaiterm-agent-event-v1-opencode
    export const GaiTermAgentEventsPlugin = async () => {
      const surface = process.env.GAITERM_SURFACE_ID ?? "";
      const token = process.env.GAITERM_EVENT_TOKEN ?? "";
      const socket = process.env.GAITERM_EVENT_SOCKET ?? "";
      const scheme = process.env.GAITERM_NOTIFY_URL_SCHEME ?? "gaiterm";
      const bundle = process.env.GAITERM_NOTIFY_BUNDLE_ID ?? "com.sipiyou.gaiterm";
      const safe = /^[A-Za-z0-9._:-]{1,256}$/;
      const routeSafe = /^[A-Za-z0-9._:+-]{1,256}$/;
      if (!safe.test(surface)
        || !safe.test(token)
        || !routeSafe.test(scheme)
        || !routeSafe.test(bundle)) return {};

      const active = new Set();
      const children = new Set();
      const pendingErrors = new Set();
      let cycleTurn = "";
      let cycleFailed = false;
      let deliveryQueue = Promise.resolve();

      const sessionID = (event) =>
        event?.properties?.sessionID ?? event?.properties?.info?.id ?? "";
      const tracked = (id) => safe.test(id) && !children.has(id);

      const send = (kind, turn) => {
        deliveryQueue = deliveryQueue.then(async () => {
          try {
            const query = new URLSearchParams({
              v: "1",
              surface,
              token,
              provider: "opencode",
              kind,
              event: `opencode-${kind}-${crypto.randomUUID()}`,
            });
            if (safe.test(turn)) query.set("turn", `session:${turn}`);
            const url = `${scheme}://agent-event?${query}`;
            if (socket.startsWith("/") && socket.length <= 1024) {
              try {
                const socketChild = Bun.spawn(
                  ["/usr/bin/nc", "-U", "-w", "2", socket],
                  { stdin: "pipe", stdout: "pipe", stderr: "ignore" },
                );
                socketChild.stdin.write(`${url}\n`);
                socketChild.stdin.end();
                const [reply, exitCode] = await Promise.all([
                  new Response(socketChild.stdout).text(),
                  socketChild.exited,
                ]);
                const acknowledgement = reply.endsWith("\r\n")
                  ? reply.slice(0, -2)
                  : reply.endsWith("\n") ? reply.slice(0, -1) : reply;
                if (exitCode === 0 && acknowledgement === "OK") return;
              } catch {}
            }
            const openChild = Bun.spawn(
              [
                "/usr/bin/open",
                "-g",
                "-b",
                bundle,
                url,
              ],
              { stdin: "ignore", stdout: "ignore", stderr: "ignore" },
            );
            await openChild.exited;
          } catch {}
        });
        return deliveryQueue;
      };

      const begin = async (id) => {
        if (!tracked(id)) return;
        pendingErrors.delete(id);
        const startsCycle = active.size === 0;
        active.add(id);
        if (!startsCycle) return;
        cycleTurn = id;
        cycleFailed = false;
        await send("started", cycleTurn);
      };

      const finish = async (id, outcome = "stop") => {
        if (!active.delete(id)) {
          pendingErrors.delete(id);
          return;
        }
        if (pendingErrors.delete(id) || outcome === "failed") cycleFailed = true;
        if (active.size > 0) return;

        const turn = cycleTurn || id;
        const kind = cycleFailed ? "failed" : outcome;
        cycleTurn = "";
        cycleFailed = false;
        pendingErrors.clear();
        await send(kind, turn);
      };

      // Loading the plugin itself is the adapter handshake. It also settles
      // the shell Enter which launched OpenCode before a session exists.
      await send("ready", "");

      return {
        "chat.message": async ({ sessionID: id }) => {
          try {
            await begin(id);
          } catch {}
        },
        event: async ({ event }) => {
          try {
            const type = event?.type ?? "";
            const id = sessionID(event);

            if (type === "session.created" || type === "session.updated") {
              if (event?.properties?.info?.parentID) {
                children.add(id);
                pendingErrors.delete(id);
                await finish(id, "cancelled");
              } else {
                children.delete(id);
                if (type === "session.created") await send("ready", id);
              }
              return;
            }
            if (type === "session.deleted") {
              pendingErrors.delete(id);
              await finish(id, "cancelled");
              children.delete(id);
              return;
            }

            if (type === "session.status") {
              const status = event?.properties?.status?.type ?? "";
              if (!tracked(id)) return;
              if (status === "busy") await begin(id);
              if (status === "idle") await finish(id);
              return;
            }
            if (type === "session.idle") {
              if (tracked(id)) await finish(id);
              return;
            }
            if (type === "session.error") {
              if (!tracked(id) || !active.has(id)) return;
              const errorName = event?.properties?.error?.name
                ?? event?.properties?.error?.data?.name
                ?? "";
              if (errorName === "MessageAbortedError") {
                pendingErrors.delete(id);
                await finish(id, "cancelled");
              } else {
                // OpenCode may recover and become busy again after an error
                // (for example after compaction). Commit failure only if the
                // authoritative idle boundary arrives without new busy work.
                pendingErrors.add(id);
              }
              return;
            }
            if (!tracked(id) || !active.has(id)) return;
            if (type === "permission.asked") {
              await send("awaitingApproval", cycleTurn || id);
              return;
            }
            if (type === "question.asked") {
              await send("awaitingInput", cycleTurn || id);
              return;
            }
            if (type === "permission.replied"
              || type === "question.replied"
              || type === "question.rejected") {
              await send("resumed", cycleTurn || id);
            }
          } catch {}
        },
      };
    };
    """#

    #if DEBUG
    static func codexTrustContentForTesting(_ existing: String) -> String {
        codexTrustContent(
            existing: existing,
            typedEntries: [CodexTrustEntry(
                key: "/tmp/hooks.json:stop:0:0",
                trustedHash: "sha256:typed")],
            legacyEntries: [CodexTrustEntry(
                key: "/tmp/hooks.json:stop:1:0",
                trustedHash: "sha256:legacy")])
    }

    static func claudeHooksConfigurationForTesting(
        _ existing: [String: Any]
    ) throws -> [String: Any] {
        try jsonHooksConfiguration(
            claudeHookSpecs + [claudeLegacyStopSpec],
            from: existing,
            providerName: "Claude Code",
            includeMatcher: true)
    }

    static func claudeLegacyHooksConfigurationForTesting(
        _ existing: [String: Any]
    ) throws -> [String: Any] {
        try claudeLegacyHooksConfiguration(from: existing)
    }

    static var claudeGlobalSettingsFilenameForTesting: String {
        claudeGlobalSettingsURL(in: claudeConfigDirectory()).lastPathComponent
    }

    static func agyHooksConfigurationForTesting(
        _ existing: [String: Any]
    ) throws -> [String: Any] {
        try agyHooksConfiguration(from: existing)
    }

    static var openCodePluginSourceForTesting: String {
        openCodePluginSource
    }
    #endif

    private enum HookInstallError: LocalizedError {
        case invalidRootObject(path: String)
        case invalidHooksObject(provider: String)
        case invalidEventHooks(provider: String, event: String)

        var errorDescription: String? {
            switch self {
            case .invalidRootObject(let path):
                "The JSON root at \(path) is not an object; leaving it untouched."
            case .invalidHooksObject(let provider):
                "\(provider) has a non-object hooks value; leaving it untouched."
            case .invalidEventHooks(let provider, let event):
                "\(provider) has an unsupported \(event) hook shape; leaving it untouched."
            }
        }
    }

    private static func codexHome() -> URL {
        environmentDirectory(named: "CODEX_HOME")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
    }

    private static func claudeConfigDirectory() -> URL {
        environmentDirectory(named: "CLAUDE_CONFIG_DIR")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
    }

    private static func claudeGlobalSettingsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("settings.json", isDirectory: false)
    }

    private static func openCodeConfigDirectory() -> URL {
        let configHome = environmentDirectory(named: "XDG_CONFIG_HOME")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        return configHome.appendingPathComponent("opencode", isDirectory: true)
    }

    /// GUI apps do not source shell startup files. Honor only values actually
    /// inherited by this process; guessing a user's shell configuration would
    /// make installation non-deterministic and could target the wrong profile.
    private static func environmentDirectory(named name: String) -> URL? {
        guard let rawValue = ProcessInfo.processInfo.environment[name] else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(
            fileURLWithPath: (value as NSString).expandingTildeInPath,
            isDirectory: true)
    }

    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw HookInstallError.invalidRootObject(path: url.path)
        }
        return dictionary
    }

    private static func writeJSONObjectIfChanged(_ object: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try writeDataIfChanged(data, to: url)
    }

    private static func installCodexTrust(
        in url: URL,
        typedEntries: [CodexTrustEntry],
        legacyEntries: [CodexTrustEntry]
    ) throws {
        let existing: String
        if FileManager.default.fileExists(atPath: url.path) {
            existing = try String(contentsOf: url, encoding: .utf8)
        } else {
            existing = ""
        }

        let content = codexTrustContent(
            existing: existing,
            typedEntries: typedEntries,
            legacyEntries: legacyEntries)
        try writeDataIfChanged(Data(content.utf8), to: url)
    }

    private static func codexTrustContent(
        existing: String,
        typedEntries: [CodexTrustEntry],
        legacyEntries: [CodexTrustEntry]
    ) -> String {
        var lines = tomlLines(existing)
        removeMarkedBlock(begin: codexTypedTrustBegin, end: codexTypedTrustEnd, from: &lines)
        removeMarkedBlock(begin: codexTrustBegin, end: codexTrustEnd, from: &lines)
        for entry in typedEntries + legacyEntries {
            removeCodexTrustTable(
                forEscapedKey: tomlBasicStringContent(entry.key),
                from: &lines)
        }
        appendCodexTrustBlock(
            begin: codexTypedTrustBegin,
            end: codexTypedTrustEnd,
            entries: typedEntries,
            to: &lines)
        appendCodexTrustBlock(
            begin: codexTrustBegin,
            end: codexTrustEnd,
            entries: legacyEntries,
            to: &lines)
        return tomlContent(lines)
    }

    private static func installCodexLegacyTrust(
        in url: URL,
        entry: CodexTrustEntry
    ) throws {
        let existing: String
        if FileManager.default.fileExists(atPath: url.path) {
            existing = try String(contentsOf: url, encoding: .utf8)
        } else {
            existing = ""
        }

        var lines = tomlLines(existing)
        removeMarkedBlock(begin: codexTrustBegin, end: codexTrustEnd, from: &lines)
        removeCodexTrustTable(
            forEscapedKey: tomlBasicStringContent(entry.key),
            from: &lines)
        appendCodexTrustBlock(
            begin: codexTrustBegin,
            end: codexTrustEnd,
            entries: [entry],
            to: &lines)

        let content = tomlContent(lines)
        try writeDataIfChanged(Data(content.utf8), to: url)
    }

    private static func appendCodexTrustBlock(
        begin: String,
        end: String,
        entries: [CodexTrustEntry],
        to lines: inout [String]
    ) {
        guard !entries.isEmpty else { return }
        if !lines.isEmpty, lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append(begin)
        for entry in entries {
            lines.append("[hooks.state.\"\(tomlBasicStringContent(entry.key))\"]")
            lines.append("trusted_hash = \"\(tomlBasicStringContent(entry.trustedHash))\"")
        }
        lines.append(end)
    }

    private static func removeMarkedBlock(begin: String, end: String, from lines: inout [String]) {
        while let start = lines.firstIndex(of: begin) {
            guard let stop = lines[start...].firstIndex(of: end) else {
                lines.remove(at: start)
                collapseEmptyLines(at: start, in: &lines)
                continue
            }
            lines.removeSubrange(start...stop)
            collapseEmptyLines(at: start, in: &lines)
        }
    }

    /// Removing a managed block must not leave one additional blank line on
    /// every launch. Limit cleanup to the block boundary so user formatting
    /// elsewhere in the TOML remains untouched.
    private static func collapseEmptyLines(at boundary: Int, in lines: inout [String]) {
        guard lines.count > 1 else { return }
        var index = min(max(boundary, 1), lines.count - 1)
        while index < lines.count,
              lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.remove(at: index)
            guard lines.count > 1 else { break }
            if index >= lines.count { index = lines.count - 1 }
            guard index > 0 else { break }
        }
    }

    private static func removeCodexTrustTable(forEscapedKey escapedKey: String, from lines: inout [String]) {
        let header = "[hooks.state.\"\(escapedKey)\"]"
        var index = 0
        while index < lines.count {
            guard lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == header else {
                index += 1
                continue
            }
            let tableEnd = tomlTableEndIndex(in: lines, after: index)
            lines.removeSubrange(index..<tableEnd)
        }
    }

    private static func tomlLines(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func tomlContent(_ lines: [String]) -> String {
        var content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") { content.append("\n") }
        return content
    }

    private static func tomlTableEndIndex(in lines: [String], after start: Int) -> Int {
        guard start + 1 < lines.count else { return lines.count }
        for index in (start + 1)..<lines.count where tomlLineStartsTable(lines[index]) {
            return index
        }
        return lines.count
    }

    private static func tomlLineStartsTable(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[") && !trimmed.hasPrefix("#")
    }

    private static func tomlLineIsTable(_ table: String, line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "[\(table)]"
    }

    private static func tomlLineDefinesKey(_ key: String, line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("#") else { return false }
        let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawKey = parts.first else { return false }
        return rawKey.trimmingCharacters(in: .whitespacesAndNewlines) == key
    }

    private static func codexCommandHookHash(
        eventLabel: String,
        matcher: String?,
        command: String,
        timeout: Int,
        statusMessage: String?
    ) -> String {
        var handler: [String: Any] = [
            "async": false,
            "command": command,
            "timeout": max(timeout, 1),
            "type": "command",
        ]
        if let statusMessage {
            handler["statusMessage"] = statusMessage
        }
        var identity: [String: Any] = [
            "event_name": eventLabel,
            "hooks": [handler],
        ]
        if let matcher {
            identity["matcher"] = matcher
        }

        let data = (try? JSONSerialization.data(
            withJSONObject: identity,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func normalizedHookSourcePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let resolved = realPath(url.path) { return resolved }

        let parent = url.deletingLastPathComponent()
        if let resolvedParent = realPath(parent.path) {
            return URL(fileURLWithPath: resolvedParent, isDirectory: true)
                .appendingPathComponent(url.lastPathComponent)
                .path
        }
        return url.path
    }

    private static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return path.withCString { pointer in
            guard realpath(pointer, &buffer) != nil else { return nil }
            return String(cString: buffer)
        }
    }

    private static func tomlBasicStringContent(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                escaped += "\\b"
            case 0x09:
                escaped += "\\t"
            case 0x0A:
                escaped += "\\n"
            case 0x0C:
                escaped += "\\f"
            case 0x0D:
                escaped += "\\r"
            case 0x22:
                escaped += "\\\""
            case 0x5C:
                escaped += "\\\\"
            case 0x00...0x1F, 0x7F...0x9F:
                if scalar.value <= 0xFFFF {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped += String(format: "\\U%08X", scalar.value)
                }
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }

        return escaped
    }

    private static func writeDataIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try backupIfExists(url)
        try data.write(to: url, options: .atomic)
    }

    private static func backupIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).gaiterm-backup-\(timestamp)", isDirectory: false)
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
    }
}
#endif
