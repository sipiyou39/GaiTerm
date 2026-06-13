#if os(macOS)
import SwiftUI

// MARK: - Metrics

enum GaiStageMetrics {
    /// Corner radius of the stage card.
    static let cardCornerRadius: CGFloat = 18
    /// Transparent margin between the stage content and the panel edges, so
    /// the glass can cast light/shadow without being clipped.
    static let shadowMargin: CGFloat = 20
    /// Gap between the drawer's edge and the stage panel — the two float as
    /// separate layers, never glued together.
    static let drawerGap: CGFloat = 8
    /// Height of each pane's header band.
    static let paneHeaderHeight: CGFloat = 25
}

// MARK: - Stage view

/// The "Scène": one free-floating Liquid Glass card showing the open
/// workspace's terminal. Opening a workspace lands you *directly* in a
/// shell; more terminals come from splitting (⌘D & friends, draggable
/// dividers), exactly like a Ghostty window. Every pane carries its own
/// header: editable codename, git branch of its cwd, and a zoom toggle.
struct WorkspaceStageView: View {
    @ObservedObject var store: GaiWorkspaceStore
    @ObservedObject var ui: GaiWorkspaceUIModel
    let ghostty: Ghostty.App
    let splits: GaiSplitController
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if let workspace = store.workspace(for: store.openWorkspaceID) {
                StageCard(workspace: workspace, ui: ui, splits: splits, onClose: onClose)
                    .id(workspace.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(ghostty)
    }
}

private struct StageCard: View {
    @ObservedObject var workspace: GaiWorkspace
    let ui: GaiWorkspaceUIModel
    let splits: GaiSplitController
    let onClose: () -> Void

    /// Apple's elevated dark surface gray. The surfaces' Metal layers are
    /// screen-blended so their theme background melts into this fill while
    /// the text stays crisp (see `GaiSplitController.applyInteriorBlend`).
    private let interiorGray = Color(red: 0.110, green: 0.110, blue: 0.118)

    /// The pane that currently has keyboard focus, tracked so we can dim the
    /// others and ring the active one.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    private var accent: Color { .gaiAccent(for: workspace.name) }

    /// Flat, BridgeMind-style: the terminals ARE the stage. No surrounding
    /// frame, no per-pane cards — panes meet edge to edge on a 1px divider.
    var body: some View {
        terminalArea
            .background(interiorGray)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(GaiStageMetrics.shadowMargin)
            .onAppear { splits.ensureFirstSurface(in: workspace) }
            .onChange(of: focusedSurface) { newValue in
                if newValue != nil { lastFocusedSurface = .init(newValue) }
            }
    }

    private var terminalArea: some View {
        GaiSplitTreeView(
            workspace: workspace,
            ui: ui,
            accent: accent,
            focusedSurface: focusedSurface,
            splits: splits)
        .ghosttyLastFocusedSurface(lastFocusedSurface)
    }
}

// MARK: - Split tree

/// Renders a workspace's split tree with our own pane chrome (per-pane
/// header). The recursive structure and resize plumbing mirror
/// `TerminalSplitTreeView`; only the leaves differ.
private struct GaiSplitTreeView: View {
    @ObservedObject var workspace: GaiWorkspace
    let ui: GaiWorkspaceUIModel
    let accent: Color
    let focusedSurface: Ghostty.SurfaceView?
    let splits: GaiSplitController

    var body: some View {
        let tree = workspace.surfaceTree
        if let node = tree.zoomed ?? tree.root {
            GaiSplitSubtree(
                node: node,
                zoomedNode: tree.zoomed,
                isSplitTree: tree.isSplit,
                ui: ui,
                splits: splits,
                accent: accent,
                focusedSurface: focusedSurface,
                sessionLookup: { [weak workspace] surface in
                    workspace?.session(for: surface)
                },
                action: { [weak workspace] operation in
                    guard let workspace else { return }
                    splits.performSplitAction(workspace, operation)
                },
                onToggleZoom: { [weak workspace] surface in
                    guard let workspace else { return }
                    splits.toggleZoom(in: workspace, surface: surface)
                },
                onSplit: { [weak workspace] surface, direction in
                    guard let workspace else { return }
                    splits.newSplit(in: workspace, at: surface, direction: direction)
                },
                onClosePane: { [weak workspace] surface in
                    guard let workspace else { return }
                    splits.closePane(in: workspace, surface: surface)
                })
            // SwiftUI's implicit structural identity is unreliable for tree
            // structures; see ghostty#7546.
            .id(node.structuralIdentity)
        }
    }
}

private struct GaiSplitSubtree: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<Ghostty.SurfaceView>.Node
    let zoomedNode: SplitTree<Ghostty.SurfaceView>.Node?
    let isSplitTree: Bool
    let ui: GaiWorkspaceUIModel
    let splits: GaiSplitController
    let accent: Color
    let focusedSurface: Ghostty.SurfaceView?
    let sessionLookup: (Ghostty.SurfaceView) -> GaiTerminalSession?
    let action: (TerminalSplitOperation) -> Void
    let onToggleZoom: (Ghostty.SurfaceView) -> Void
    let onSplit: (Ghostty.SurfaceView, SplitTree<Ghostty.SurfaceView>.NewDirection) -> Void
    let onClosePane: (Ghostty.SurfaceView) -> Void

    var body: some View {
        switch node {
        case .leaf(let surfaceView):
            GaiPaneView(
                surfaceView: surfaceView,
                session: sessionLookup(surfaceView),
                ui: ui,
                splits: splits,
                accent: accent,
                isFocused: focusedSurface === surfaceView,
                isSplit: isSplitTree,
                isZoomed: zoomedNode == node,
                onToggleZoom: { onToggleZoom(surfaceView) },
                onSplit: { onSplit(surfaceView, $0) },
                onClose: { onClosePane(surfaceView) })
            // Explicit identity per leaf: without it SwiftUI may reuse one
            // pane's platform container for a *different* surface across
            // tree rebuilds, physically swapping terminals between slots
            // (wrong frames, wrong hit-testing, "casino" focus) — the same
            // structural-identity hazard ghostty#7546 works around at the
            // tree root.
            .id(surfaceView.id)

        case .split(let split):
            let direction: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }
            SplitView(
                direction,
                .init(
                    get: { CGFloat(split.ratio) },
                    set: { action(.resize(.init(node: node, ratio: $0))) }),
                dividerColor: Color.white.opacity(0.12),
                left: {
                    GaiSplitSubtree(
                        node: split.left,
                        zoomedNode: zoomedNode,
                        isSplitTree: isSplitTree,
                        ui: ui,
                        splits: splits,
                        accent: accent,
                        focusedSurface: focusedSurface,
                        sessionLookup: sessionLookup,
                        action: action,
                        onToggleZoom: onToggleZoom,
                        onSplit: onSplit,
                        onClosePane: onClosePane)
                },
                right: {
                    GaiSplitSubtree(
                        node: split.right,
                        zoomedNode: zoomedNode,
                        isSplitTree: isSplitTree,
                        ui: ui,
                        splits: splits,
                        accent: accent,
                        focusedSurface: focusedSurface,
                        sessionLookup: sessionLookup,
                        action: action,
                        onToggleZoom: onToggleZoom,
                        onSplit: onSplit,
                        onClosePane: onClosePane)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                })
        }
    }
}

// MARK: - Pane

/// One terminal pane: a slim header (editable codename · git branch · zoom)
/// above the surface, ringed with the workspace accent when focused.
private struct GaiPaneView: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let session: GaiTerminalSession?
    let ui: GaiWorkspaceUIModel
    let splits: GaiSplitController
    let accent: Color
    let isFocused: Bool
    let isSplit: Bool
    let isZoomed: Bool
    let onToggleZoom: () -> Void
    let onSplit: (SplitTree<Ghostty.SurfaceView>.NewDirection) -> Void
    let onClose: () -> Void

    @State private var branch: String?

    /// Refreshes the branch even when the pwd doesn't change (checkout,
    /// new repo, worktree switch).
    private let branchRefresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            // Flat pane, no card: the focus ring wraps the terminal zone
            // only (the header is app chrome, outside the focus system).
            Ghostty.SurfaceWrapper(surfaceView: surfaceView, isSplit: isSplit)
                .background(GaiBlendAsserter(surfaceView: surfaceView))
                .overlay(
                    Rectangle().strokeBorder(
                        isFocused && isSplit ? accent.opacity(0.6) : Color.clear,
                        lineWidth: 1.5))
        }
        .onAppear(perform: refreshBranch)
        .onChange(of: surfaceView.pwd) { _ in refreshBranch() }
        .onReceive(branchRefresh) { _ in refreshBranch() }
    }

    private var paneHeader: some View {
        HStack(spacing: 7) {
            GaiPaneTitle(
                surfaceView: surfaceView,
                session: session,
                ui: ui,
                splits: splits)
            Spacer(minLength: 6)
            if let branch {
                HStack(spacing: 3.5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(branch)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.55))
            }
            // Always visible and therefore always hittable: a control that
            // only mounts on hover can miss the very click it exists for.
            GaiPaneIconButton(
                symbol: "rectangle.split.2x1",
                help: "Split right (⌘D)") { onSplit(.right) }
            GaiPaneIconButton(
                symbol: "rectangle.split.1x2",
                help: "Split down (⇧⌘D)") { onSplit(.down) }
            if isSplit {
                GaiPaneIconButton(
                    symbol: isZoomed
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    help: isZoomed ? "Restore size" : "Fill the card",
                    emphasized: isZoomed,
                    action: onToggleZoom)
            }
            GaiPaneIconButton(symbol: "xmark", help: "Close terminal", action: onClose)
        }
        .padding(.horizontal, 9)
        .frame(height: GaiStageMetrics.paneHeaderHeight)
        .background(Color.white.opacity(0.05))
        // Deliberately no tap handling on the header itself: it is app
        // chrome, outside the terminal focus system. Focus moves by
        // clicking inside a terminal.
    }

    private func refreshBranch() {
        let pwd = surfaceView.pwd
        DispatchQueue.global(qos: .utility).async {
            let value = GaiGitInfo.branch(atPath: pwd)
            DispatchQueue.main.async {
                if value != branch { branch = value }
            }
        }
    }
}

/// Keeps the pane's gray interior alive. Two parts, re-asserted on every
/// layout pass (resize, reparent, window change — whenever AppKit can have
/// rebuilt layers):
///
/// 1. The screen-blend compositing filter on the surface's Metal layer.
/// 2. The gray itself, painted on the surface's *direct superlayer*. The
///    blend can only sample content within the surface's own compositing
///    group — once the tree splits, SwiftUI isolates each pane in its own
///    group and a gray painted anywhere else composites as empty (black).
///    The direct superlayer is in the group by construction.
private struct GaiBlendAsserter: NSViewRepresentable {
    /// Apple's elevated dark surface gray — must match `StageCard`'s.
    static let interiorGray = CGColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)

    let surfaceView: Ghostty.SurfaceView

    final class AsserterView: NSView {
        weak var surfaceView: Ghostty.SurfaceView?

        /// Invisible to clicks, always. As a plain NSView this would
        /// otherwise swallow mouse events meant for the terminal whenever
        /// AppKit's sibling order puts it above the surface — which SwiftUI
        /// reshuffles on re-renders, making clicks land erratically.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func assertBlend() {
            guard let layer = surfaceView?.layer else { return }
            layer.compositingFilter = "screenBlendMode"
            layer.superlayer?.backgroundColor = GaiBlendAsserter.interiorGray
        }

        override func layout() {
            super.layout()
            assertBlend()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            assertBlend()
        }
    }

    func makeNSView(context: Context) -> AsserterView {
        let view = AsserterView()
        view.surfaceView = surfaceView
        return view
    }

    func updateNSView(_ view: AsserterView, context: Context) {
        view.surfaceView = surfaceView
        view.assertBlend()
        // The superlayer can be swapped after this update completes (the
        // representable attaches before the surface settles into its new
        // hierarchy) — assert once more on the next turn.
        DispatchQueue.main.async { [weak view] in
            view?.assertBlend()
        }
    }
}

/// AppKit-level click interception for header controls. An NSView gets the
/// `mouseDown` straight from hit-testing — before SwiftUI's gesture and
/// focus machinery — so the control fires on the *first* click no matter
/// which pane or window has focus, and (deliberately not calling super)
/// the click never disturbs the terminal's focus: pane headers behave like
/// app chrome, not like terminal content.
struct GaiClickCatcher: NSViewRepresentable {
    let action: () -> Void

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var acceptsFirstResponder: Bool { false }

        // Swallow the down (no super: no focus/dragging side effects);
        // fire on up-inside like a button.
        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) {
                action?()
            }
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }
}

/// A small icon control for pane headers, clickable on the first click via
/// AppKit-level interception (see `GaiClickCatcher`).
private struct GaiPaneIconButton: View {
    let symbol: String
    let help: String
    var emphasized: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.white.opacity(hovering || emphasized ? 0.95 : 0.55))
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0)))
            .onHover { hovering = $0 }
            .overlay(GaiClickCatcher(action: action))
            .help(help)
    }
}

/// The pane's codename, edited *in place*: clicking the name or the pencil
/// swaps the label for a text field right where it sits. No popup.
///
/// Two pillars make the first click reliable from anywhere:
/// - the click is intercepted at the window level and consumed before any
///   view or focus logic (see `GaiSplitController`), with the in-hierarchy
///   `GaiClickCatcher` as fallback;
/// - the editing state lives in the UI model, not in this view, so a tree
///   re-render can't reset it mid-flight.
private struct GaiPaneTitle: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let session: GaiTerminalSession?
    @ObservedObject var ui: GaiWorkspaceUIModel
    let splits: GaiSplitController

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    private var isEditing: Bool {
        session != nil && ui.renamingSession === session
    }

    var body: some View {
        HStack(spacing: 5) {
            if isEditing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.14)))
                    .frame(width: 130)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { ui.renamingSession = nil }
                    .onChange(of: fieldFocused) { focused in
                        if !focused { commit() }
                    }
                    .onAppear {
                        draft = session?.name ?? ""
                        DispatchQueue.main.async { fieldFocused = true }
                    }
            } else {
                GaiSessionNameText(session: session, fallback: surfaceView.title)
                Image(systemName: "pencil")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.55))
                    .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 19)
        .background(
            Capsule().fill(Color.white.opacity(hovering && !isEditing ? 0.12 : 0)))
        .onHover { hovering = $0 }
        .overlay {
            if !isEditing {
                // The window-level monitor finds this catcher's AppKit view
                // geometrically and fires its action — no registration, no
                // view-lifecycle bookkeeping.
                GaiClickCatcher(action: beginRename)
            }
        }
        .help("Rename")
    }

    private func beginRename() {
        guard let session else { return }
        // The inline field needs the keyboard.
        surfaceView.window?.makeKeyAndOrderFront(nil)
        ui.renamingSession = session
    }

    private func commit() {
        defer { ui.renamingSession = nil }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session else { return }
        session.name = trimmed
    }
}

/// Observes the session so renames repaint immediately.
private struct GaiSessionNameText: View {
    let session: GaiTerminalSession?
    let fallback: String

    var body: some View {
        if let session {
            GaiLiveSessionName(session: session)
        } else {
            Text(fallback)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }
}

private struct GaiLiveSessionName: View {
    @ObservedObject var session: GaiTerminalSession

    var body: some View {
        Text(session.name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
    }
}

// MARK: - Shared glass

/// Behind-window frosting, pinned `.active` so it never demotes in a
/// non-key floating panel. Window-server composited: live by construction.
private struct GaiStageBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .active
    }
}

/// One floating glass island. Sandwich: real frosting below, native Liquid
/// Glass for the refraction and edge light, and a wash for legibility and
/// clickability.
private struct GaiGlassIsland<S: Shape>: View {
    let shape: S

    var body: some View {
        ZStack {
            GaiStageBlur().clipShape(shape)
            if #available(macOS 26.0, *) {
                shape.fill(Color.clear)
                    .glassEffect(.regular, in: shape)
            }
            shape.fill(Color.black.opacity(0.08))
        }
    }
}
#endif
