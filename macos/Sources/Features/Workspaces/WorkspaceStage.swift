#if os(macOS)
import Combine
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let gaiPaneID = UTType(exportedAs: "com.sipiyou.gaiterm.pane-id")
}

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
    static let paneHeaderHeight: CGFloat = 30
    /// Clearance between the drawer's pull tab and the stage's pull tab when
    /// both are out.
    static let tabClearance: CGFloat = 22
    /// Keep terminal rendering paused until the fast slide is visually
    /// complete. The focus ring stays in the pane hierarchy and moves with the
    /// slab; only the heavy terminal surfaces wait for this.
    static let slideSettleDelay: TimeInterval = 0.18
}

// MARK: - Animations

extension Animation {
    /// Stage slide-out: short, no overshoot, optimized for daily terminal use.
    static let gaiStageOpen = Animation.easeOut(duration: 0.16)
    /// Stage tuck-in: even shorter because it ends hidden.
    static let gaiStageClose = Animation.easeIn(duration: 0.12)
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
    /// Snaps the panel to its open frame, right before the slide-out spring.
    let onWillExpand: () -> Void
    /// Snaps the panel to its resting tucked frame once the tuck-in settles.
    let onDidCollapse: () -> Void
    /// Reapplies renderer focus/color policy when keyboard focus changes.
    let onFocusChanged: () -> Void
    /// Pauses terminal rendering before live panel resize starts.
    let onResizeBegan: () -> Void
    /// Applies a user-driven stage width.
    let onResizeWidth: (CGFloat) -> Void
    /// Restores terminal rendering after live panel resize ends.
    let onResizeEnded: () -> Void

    /// Slab offset: 0 = out; +stageCardWidth = tucked (panel still at its open
    /// frame). The mirror of the drawer's negative slide.
    @State private var slide: CGFloat = 0
    @State private var panelIsOut = false
    @State private var visualOpen = false
    @State private var generation = 0
    @State private var tabPressed = false
    @State private var stageResizeStartWidth: CGFloat?
    @State private var stageResizeHover = false

    @AppStorage(GaiPreferenceKey.tintGlassWithWorkspaceAccent) private var tintPanels = false

    private typealias D = GaiDrawerMetrics

    private var slabWidth: CGFloat { ui.stageCardWidth + D.tabWidth + D.bleed }
    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear
            // Always show a terminal: the open workspace, or the default scratch
            // terminal when none is open.
            slab(store.stageWorkspace).offset(x: slide)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .environmentObject(ghostty)
        .onReceive(ui.$isStageExpanded.removeDuplicates().dropFirst()) { expanded in
            setExpanded(expanded)
        }
    }

    // MARK: Slab

    /// One piece: a glass pull tab welded to the opaque terminal card. Same
    /// silhouette and tab as the drawer, mirrored to the right edge — the card
    /// covers the card region so only the tab (and its welds) reads as glass.
    private func slab(_ workspace: GaiWorkspace) -> some View {
        ZStack(alignment: .leading) {
            glassBase
            // Terminal content covers the card region only (trailing bleed).
            // The off-screen bleed stays the flat panel gray — so the open
            // spring's overshoot reveals a strip of that same gray, no seam.
            StageCard(
                workspace: workspace,
                ui: ui,
                splits: splits,
                onClose: onClose,
                onFocusChanged: onFocusChanged,
                onToggleNotifications: { surface in
                    store.toggleNotifications(for: surface)
                },
                onToggleAutoFocus: { surface in
                    store.toggleAutoFocusOnNotification(for: surface)
                })
                .clipped()
                .padding(.leading, D.tabWidth)
                .padding(.trailing, D.bleed)
                .id(workspace.id)
        }
        .frame(width: slabWidth)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) { chevron }
        .overlay(alignment: .leading) { tabHitArea }
        .overlay(alignment: .leading) { stageResizeHandle.offset(x: D.tabWidth - 6) }
    }

    /// Flat panel gray instead of Liquid Glass — the glass re-rendered every
    /// frame while the slab moved/resized, which made the animations stutter. A
    /// solid fill (matching the drawer and the pane headers) composites for free.
    private var glassBase: some View {
        let accent = store.stageWorkspace.accentColor
        return GaiStageSlabShape().fill(Color.gaiPanelColor(accent: accent, tinted: tintPanels))
    }

    /// The current stage workspace accent (for tinting headers).
    private var stageAccent: Color {
        store.stageWorkspace.accentColor
    }

    // MARK: Tab

    private var chevron: some View {
        Image(systemName: "chevron.left")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white.opacity(0.95))
            .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
            .rotationEffect(.degrees(visualOpen ? 180 : 0))
            .scaleEffect(tabPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.08), value: tabPressed)
        .frame(width: D.tabWidth, height: D.tabExtent)
    }

    private var tabHitArea: some View {
        GaiStageTabInteraction(
            pressed: $tabPressed,
            onToggle: { ui.isStageExpanded.toggle() },
            onResizeBegan: {
                stageResizeStartWidth = ui.stageCardWidth
                onResizeBegan()
            },
            onResizeChanged: { deltaX in
                let start = stageResizeStartWidth ?? ui.stageCardWidth
                onResizeWidth(start - deltaX)
            },
            onResizeEnded: {
                stageResizeStartWidth = nil
                onResizeEnded()
            })
            .frame(width: D.tabWidth + D.filletRadius, height: D.tabExtent + 8)
            .contentShape(Rectangle())
    }

    private var stageResizeHandle: some View {
        GaiPanelResizeHandle(
            hovering: $stageResizeHover,
            onBegan: {
                stageResizeStartWidth = ui.stageCardWidth
                onResizeBegan()
            },
            onChanged: { deltaX in
                let start = stageResizeStartWidth ?? ui.stageCardWidth
                onResizeWidth(start - deltaX)
            },
            onEnded: {
                stageResizeStartWidth = nil
                onResizeEnded()
            })
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: Slide choreography (mirror of WorkspaceDrawerView)

    private func setExpanded(_ expanded: Bool) {
        generation += 1
        let gen = generation
        if expanded {
            if panelIsOut {
                runSlide(.gaiStageOpen, { slide = 0; visualOpen = true })
            } else {
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { slide = ui.stageCardWidth }
                onWillExpand()
                panelIsOut = true
                DispatchQueue.main.async {
                    guard gen == generation, ui.isStageExpanded else { return }
                    runSlide(.gaiStageOpen, { slide = 0; visualOpen = true })
                }
            }
        } else {
            guard panelIsOut else { return }
            runSlide(.gaiStageClose, { slide = ui.stageCardWidth; visualOpen = false }) {
                finishCollapse(gen)
            }
        }
    }

    /// Runs a slab slide, flagging `isSliding` for its whole duration so the
    /// manager can pause heavy terminal rendering while the panel moves.
    private func runSlide(
        _ animation: Animation,
        _ changes: @escaping () -> Void,
        then completion: @escaping () -> Void = {}
    ) {
        ui.beginSlide()
        withAnimation(animation, changes)
        DispatchQueue.main.asyncAfter(deadline: .now() + GaiStageMetrics.slideSettleDelay) {
            completion()
            ui.endSlide()
        }
    }

    private func finishCollapse(_ gen: Int) {
        guard gen == generation, !ui.isStageExpanded, panelIsOut else { return }
        panelIsOut = false
        onDidCollapse()
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { slide = 0 }
    }
}

private struct StageCard: View {
    @ObservedObject var workspace: GaiWorkspace
    @ObservedObject var ui: GaiWorkspaceUIModel
    let splits: GaiSplitController
    let onClose: () -> Void
    let onFocusChanged: () -> Void
    let onToggleNotifications: (Ghostty.SurfaceView) -> Void
    let onToggleAutoFocus: (Ghostty.SurfaceView) -> Void

    /// One editor model per open file, so unsaved edits survive tab switches.
    @State private var models: [String: GaiEditorModel] = [:]

    @AppStorage(GaiPreferenceKey.tintGlassWithWorkspaceAccent) private var tintPanels = false

    /// The pane that currently has keyboard focus, tracked so we can dim the
    /// others and ring the active one.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    private var accent: Color { workspace.accentColor }

    /// Flat, BridgeMind-style: the terminals ARE the stage. No surrounding
    /// frame, no per-pane cards — panes meet edge to edge on a 1px divider.
    /// Clipping and tab/bleed insets are handled by the enclosing slab.
    private var showsEditor: Bool { ui.stageShowsEditor && !ui.openFiles.isEmpty }

    var body: some View {
        Group {
            if showsEditor {
                editorView
            } else {
                terminalArea
            }
        }
        .background(stageBackgroundColor)
        .onAppear {
            syncModels()
            if !ui.stageShowsEditor { splits.ensureFirstSurface(in: workspace) }
        }
        .onChange(of: ui.openFiles) { _ in syncModels() }
        .onChange(of: ui.stageShowsEditor) { showsEditor in
            if !showsEditor { splits.ensureFirstSurface(in: workspace) }
        }
        .onChange(of: focusedSurface) { newValue in
            if newValue != nil { lastFocusedSurface = .init(newValue) }
            onFocusChanged()
        }
    }

    private var stageBackgroundColor: Color {
        showsEditor
            ? Color.gaiInteriorColor(accent: accent, tinted: tintPanels)
            : Color.gaiTerminalPaneColor(accent: accent, tinted: tintPanels, active: false)
    }

    private var terminalArea: some View {
        GaiSplitTreeView(
            workspace: workspace,
            ui: ui,
            accent: accent,
            focusedSurface: focusedSurface ?? lastFocusedSurface?.value,
            splits: splits,
            onToggleNotifications: onToggleNotifications,
            onToggleAutoFocus: onToggleAutoFocus)
        .ghosttyLastFocusedSurface(lastFocusedSurface)
    }

    /// Keep `models` in lockstep with `ui.openFiles`; pick a valid active tab.
    private func syncModels() {
        for path in ui.openFiles where models[path] == nil {
            models[path] = GaiEditorModel(path: path)
        }
        for path in Array(models.keys) where !ui.openFiles.contains(path) {
            models[path] = nil
        }
        if ui.activeFilePath == nil || !ui.openFiles.contains(ui.activeFilePath!) {
            ui.activeFilePath = ui.openFiles.last
        }
    }

    // MARK: Editor — file tabs over the code view (terminals hidden here)

    private var editorView: some View {
        VStack(spacing: 0) {
            editorTabStrip
            Divider().overlay(Color.white.opacity(0.07))
            Group {
                if let path = ui.activeFilePath, let model = models[path] {
                    GaiEditorPaneContent(model: model, accent: accent).id(path)
                } else {
                    Color.clear
                }
            }
            // Clip the editor (text view + ruler) to its own area so the ruler's
            // edge separator can never bleed up into the tab bar / header.
            .clipped()
        }
    }

    private var editorTabStrip: some View {
        HStack(spacing: 4) {
            ForEach(ui.openFiles, id: \.self) { path in
                if let model = models[path] {
                    EditorFileTab(
                        model: model, accent: accent,
                        isActive: ui.activeFilePath == path,
                        onSelect: { ui.activeFilePath = path },
                        onClose: { closeFile(path) })
                }
            }
            Spacer(minLength: 0)
            if let path = ui.activeFilePath, let model = models[path] {
                EditorSaveButton(model: model)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(Color.gaiPanelColor(accent: accent, tinted: tintPanels))
    }

    private func closeFile(_ path: String) {
        guard let idx = ui.openFiles.firstIndex(of: path) else { return }
        ui.openFiles.remove(at: idx)
        models[path] = nil
        if ui.activeFilePath == path {
            ui.activeFilePath = ui.openFiles.indices.contains(idx)
                ? ui.openFiles[idx] : ui.openFiles.last
        }
        if ui.openFiles.isEmpty {
            ui.activeFilePath = nil
            ui.stageShowsEditor = false
        }
    }
}

// MARK: - Editor file tab

/// One file tab in the editor's tab strip — observes its own model so the
/// modified dot updates live; ✕ on hover (or when active) closes it.
private struct EditorFileTab: View {
    @ObservedObject var model: GaiEditorModel
    let accent: Color
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var node: GaiFileNode {
        GaiFileNode(id: model.path ?? "", name: model.name,
                    path: model.path ?? "", isDirectory: false, depth: 0)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: GaiFileIcon.symbol(for: node))
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(GaiFileIcon.color(for: node))
            Text(model.name.isEmpty ? "Untitled" : model.name)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .white : .white.opacity(0.6))
                .lineLimit(1)

            // Modified dot, or a close ✕ on hover/active (✕ takes priority).
            ZStack {
                if model.isModified && !(hovering || isActive) {
                    Circle().fill(accent).frame(width: 5, height: 5)
                }
                if hovering || isActive {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isActive ? Color.white.opacity(0.12)
                : hovering ? Color.white.opacity(0.05) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// The active file's Save button — observes the model so it shows only when
/// there are unsaved changes.
private struct EditorSaveButton: View {
    @ObservedObject var model: GaiEditorModel

    var body: some View {
        if model.isModified {
            Button { model.save() } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save (⌘S)")
        }
    }
}

// MARK: - Split tree

/// Renders a workspace's split tree with our own pane chrome (per-pane
/// header). The recursive structure and resize plumbing mirror
/// the original split rendering; only the leaves differ.
private struct GaiSplitTreeView: View {
    @ObservedObject var workspace: GaiWorkspace
    let ui: GaiWorkspaceUIModel
    let accent: Color
    let focusedSurface: Ghostty.SurfaceView?
    let splits: GaiSplitController
    let onToggleNotifications: (Ghostty.SurfaceView) -> Void
    let onToggleAutoFocus: (Ghostty.SurfaceView) -> Void

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
                onToggleNotifications: onToggleNotifications,
                onToggleAutoFocus: onToggleAutoFocus,
                onClosePane: { [weak workspace] surface in
                    guard let workspace else { return }
                    splits.closePane(in: workspace, surface: surface)
                },
                onChangeFolder: { [weak workspace] surface, path in
                    guard let workspace else { return }
                    splits.reopenPane(in: workspace, surface: surface, directory: path)
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
    let action: (GaiSplitOperation) -> Void
    let onToggleZoom: (Ghostty.SurfaceView) -> Void
    let onSplit: (Ghostty.SurfaceView, SplitTree<Ghostty.SurfaceView>.NewDirection) -> Void
    let onToggleNotifications: (Ghostty.SurfaceView) -> Void
    let onToggleAutoFocus: (Ghostty.SurfaceView) -> Void
    let onClosePane: (Ghostty.SurfaceView) -> Void
    let onChangeFolder: (Ghostty.SurfaceView, String) -> Void

    var body: some View {
        switch node {
        case .leaf(let surfaceView):
            GaiPaneView(
                surfaceView: surfaceView,
                session: sessionLookup(surfaceView),
                ui: ui,
                splits: splits,
                accent: accent,
                isSplit: isSplitTree,
                isZoomed: zoomedNode == node,
                onToggleZoom: { onToggleZoom(surfaceView) },
                onSplit: { onSplit(surfaceView, $0) },
                onToggleNotifications: { onToggleNotifications(surfaceView) },
                onToggleAutoFocus: { onToggleAutoFocus(surfaceView) },
                onClose: { onClosePane(surfaceView) },
                onChangeFolder: { onChangeFolder(surfaceView, $0) },
                onDropPane: { action(.drop($0)) })
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
                        onToggleNotifications: onToggleNotifications,
                        onToggleAutoFocus: onToggleAutoFocus,
                        onClosePane: onClosePane,
                        onChangeFolder: onChangeFolder)
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
                        onToggleNotifications: onToggleNotifications,
                        onToggleAutoFocus: onToggleAutoFocus,
                        onClosePane: onClosePane,
                        onChangeFolder: onChangeFolder)
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
/// above the surface. Focus is shown by a pane-local stroke on the terminal
/// region only, so it moves exactly with the stage slab.
private struct GaiPaneView: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let session: GaiTerminalSession?
    @ObservedObject var ui: GaiWorkspaceUIModel
    let splits: GaiSplitController
    let accent: Color
    @AppStorage(GaiPreferenceKey.tintGlassWithWorkspaceAccent) private var tintPanels = false
    let isSplit: Bool
    let isZoomed: Bool
    let onToggleZoom: () -> Void
    let onSplit: (SplitTree<Ghostty.SurfaceView>.NewDirection) -> Void
    let onToggleNotifications: () -> Void
    let onToggleAutoFocus: () -> Void
    let onClose: () -> Void
    let onChangeFolder: (String) -> Void
    let onDropPane: (GaiSplitOperation.Drop) -> Void

    @State private var branch: String?
    @State private var activeDropZone: GaiSplitDropZone?

    var body: some View {
        GeometryReader { _ in
            paneStack
                .overlay { GaiPaneDropGuide(zone: activeDropZone, accent: accent) }
                .overlay {
                    GaiPaneDropTarget(
                        destination: surfaceView,
                        activeZone: $activeDropZone,
                        onDrop: onDropPane)
                }
        }
        .onAppear(perform: refreshBranch)
        .onChange(of: surfaceView.pwd) { _ in refreshBranch() }
    }

    private var paneStack: some View {
        VStack(spacing: 0) {
            paneHeader
            // Flat pane, no card: the terminal keeps the same fill; focus is a
            // stroke drawn inside this pane so it cannot detach from the stage.
            GaiFastSurfaceWrapper(surfaceView: surfaceView)
                .background(paneBaseColor)
                .background(GaiSurfaceLayerAsserter(
                    surfaceView: surfaceView,
                    backdrop: NSColor(paneBaseColor).cgColor))
                // Ghostty's scroll view sets `contentView.clipsToBounds = false`,
                // so on an elastic overscroll the surface can draw past its top
                // edge — up over the fixed header. Clip the terminal to its own
                // frame so the header always stays put.
                .clipped()
                .overlay { paneFocusStroke }
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
    }

    private var paneIsActive: Bool {
        isSplit && ui.focusedTerminalSurfaceID == ObjectIdentifier(surfaceView)
    }

    private var paneBaseColor: Color {
        Color.gaiTerminalPaneColor(
            accent: accent,
            tinted: tintPanels,
            active: false)
    }

    @ViewBuilder
    private var paneFocusStroke: some View {
        if paneIsActive {
            Rectangle()
                .strokeBorder(accent.opacity(0.9), lineWidth: 1)
                .overlay {
                    Rectangle()
                        .inset(by: 1)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
                .allowsHitTesting(false)
        }
    }

    private var paneHeader: some View {
        GeometryReader { geo in
            paneHeaderContent(width: geo.size.width)
                .frame(
                    width: geo.size.width,
                    height: GaiStageMetrics.paneHeaderHeight,
                    alignment: .leading)
        }
        .frame(height: GaiStageMetrics.paneHeaderHeight)
        .background(Color.gaiPanelColor(accent: accent, tinted: tintPanels))
        .clipped()
        // Deliberately no tap handling on the header itself: it is app
        // chrome, outside the terminal focus system. Focus moves by
        // clicking inside a terminal.
    }

    private func paneHeaderContent(width: CGFloat) -> some View {
        let layout = GaiPaneHeaderLayout(width: width)
        return HStack(spacing: layout.spacing) {
            if layout.showsDragHandle {
                GaiPaneDragHandle(size: layout.controlSize)
                    .onDrag {
                        paneDragProvider()
                    }
                    .layoutPriority(30)
            }
            if layout.showsTitle {
                GaiPaneTitle(
                    surfaceView: surfaceView,
                    session: session,
                    ui: ui,
                    splits: splits)
                .frame(maxWidth: layout.titleMaxWidth, alignment: .leading)
                .clipped()
                .layoutPriority(8)
            }
            Spacer(minLength: 0)
            if layout.showsDirectory {
                GaiDirectoryPicker(path: surfaceView.pwd, accent: accent, onPick: onChangeFolder)
                    .frame(maxWidth: layout.directoryMaxWidth, alignment: .leading)
                    .clipped()
                    .layoutPriority(-2)
            }
            if layout.showsBranch, let branch {
                HStack(spacing: 3.5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(branch)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: layout.branchMaxWidth, alignment: .leading)
                .clipped()
                .layoutPriority(-3)
            }
            Spacer(minLength: 0)
            if layout.showsNotificationBadge, let session {
                GaiPaneAttentionBadge(session: session, accent: accent)
                    .layoutPriority(20)
            }
            // Always visible and therefore always hittable: a control that
            // only mounts on hover can miss the very click it exists for.
            HStack(spacing: layout.controlSpacing) {
                if let session {
                    GaiPaneNotificationControls(
                        session: session,
                        size: layout.controlSize,
                        onToggleNotifications: onToggleNotifications,
                        onToggleAutoFocus: onToggleAutoFocus)
                }
                GaiPaneIconButton(
                    symbol: "rectangle.split.2x1",
                    help: "Split right (⌘D)",
                    size: layout.controlSize) { onSplit(.right) }
                GaiPaneIconButton(
                    symbol: "rectangle.split.1x2",
                    help: "Split down (⇧⌘D)",
                    size: layout.controlSize) { onSplit(.down) }
                if isSplit {
                    GaiPaneIconButton(
                        symbol: isZoomed
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right",
                        help: isZoomed ? "Restore size" : "Fill the card",
                        emphasized: isZoomed,
                        size: layout.controlSize,
                        action: onToggleZoom)
                }
                GaiPaneIconButton(
                    symbol: "xmark",
                    help: "Close terminal",
                    size: layout.controlSize,
                    action: onClose)
            }
            .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(100)
        }
        .padding(.leading, layout.edgePadding)
        .padding(.trailing, layout.edgePadding)
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

    private func paneDragProvider() -> NSItemProvider {
        GaiPaneDragCoordinator.begin(surfaceView.id)
        let provider = NSItemProvider()
        let data = Data(surfaceView.id.uuidString.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.gaiPaneID.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

private struct GaiPaneHeaderLayout {
    let width: CGFloat

    var edgePadding: CGFloat {
        if width < 120 { return 2 }
        if width < 150 { return 4 }
        if width < 260 { return 6 }
        return 9
    }

    var spacing: CGFloat {
        width < 260 ? 4 : 7
    }

    var controlSpacing: CGFloat {
        if width < 120 { return 2 }
        if width < 180 { return 3 }
        return 4
    }

    var controlSize: CGFloat {
        if width < 100 { return 13 }
        if width < 140 { return 15 }
        return 18
    }

    var showsTitle: Bool { width >= 118 }
    var showsDragHandle: Bool { width >= 160 }
    var showsNotificationBadge: Bool { width >= 150 }
    var showsDirectory: Bool { width >= 360 }
    var showsBranch: Bool { width >= 520 }

    var titleMaxWidth: CGFloat? {
        let drag = showsDragHandle ? controlSize + spacing : 0
        let reservedControls = controlSize * 6 + controlSpacing * 5 + edgePadding * 2 + drag
        let available = max(0, width - reservedControls - spacing)
        if width < 180 { return available }
        if width < 300 { return min(available, 90) }
        return min(available, 140)
    }

    var directoryMaxWidth: CGFloat {
        width < 380 ? 46 : 96
    }

    var branchMaxWidth: CGFloat {
        width < 540 ? 68 : 120
    }
}

private struct GaiPaneDragHandle: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: max(7, size * 0.46), weight: .bold))
            .foregroundStyle(.white.opacity(0.44))
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .help("Move pane")
    }
}

private struct GaiPaneDropGuide: View {
    let zone: GaiSplitDropZone?
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            if let zone {
                let rect = guideRect(zone: zone, size: geo.size)
                Rectangle()
                    .fill(accent.opacity(0.20))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                accent.opacity(0.95),
                                style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    .overlay {
                        Text(label(for: zone))
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(accent.opacity(0.95)))
                            .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    .allowsHitTesting(false)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .allowsHitTesting(false)
    }

    private func guideRect(zone: GaiSplitDropZone, size: CGSize) -> CGRect {
        switch zone {
        case .left:
            return CGRect(x: 0, y: 0, width: size.width * 0.5, height: size.height)
        case .right:
            let width = size.width * 0.5
            return CGRect(x: size.width - width, y: 0, width: width, height: size.height)
        case .top:
            return CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.5)
        case .bottom:
            let height = size.height * 0.5
            return CGRect(x: 0, y: size.height - height, width: size.width, height: height)
        case .center:
            return CGRect(origin: .zero, size: size)
        }
    }

    private func label(for zone: GaiSplitDropZone) -> String {
        switch zone {
        case .top: return "Split Top"
        case .bottom: return "Split Bottom"
        case .left: return "Split Left"
        case .right: return "Split Right"
        case .center: return "Swap"
        }
    }
}

private struct GaiPaneDropTarget: NSViewRepresentable {
    let destination: Ghostty.SurfaceView
    @Binding var activeZone: GaiSplitDropZone?
    let onDrop: (GaiSplitOperation.Drop) -> Void

    final class TargetView: NSView {
        weak var destination: Ghostty.SurfaceView?
        var setActiveZone: ((GaiSplitDropZone?) -> Void)?
        var onDrop: ((GaiSplitOperation.Drop) -> Void)?
        private let pasteboardType = NSPasteboard.PasteboardType(UTType.gaiPaneID.identifier)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([pasteboardType])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            GaiPaneDragCoordinator.isDraggingPane ? self : nil
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard accepts(sender) else { return [] }
            updateZone(sender)
            return operation(for: sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard accepts(sender) else { return [] }
            GaiPaneDragCoordinator.keepAlive()
            updateZone(sender)
            return operation(for: sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            setActiveZone?(nil)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            accepts(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer {
                setActiveZone?(nil)
                GaiPaneDragCoordinator.end()
            }
            guard let destination,
                  let id = draggedPaneID(sender)
            else { return false }
            let zone = gaiPaneDropZone(for: topLeftPoint(from: sender), size: bounds.size)
            onDrop?(.init(payloadID: id, destination: destination, zone: zone))
            return true
        }

        private func updateZone(_ sender: NSDraggingInfo) {
            guard accepts(sender) else {
                setActiveZone?(nil)
                return
            }
            setActiveZone?(gaiPaneDropZone(for: topLeftPoint(from: sender), size: bounds.size))
        }

        private func accepts(_ sender: NSDraggingInfo) -> Bool {
            draggedPaneID(sender) != nil
        }

        private func draggedPaneID(_ sender: NSDraggingInfo) -> UUID? {
            if let data = sender.draggingPasteboard.data(forType: pasteboardType),
               let raw = String(data: data, encoding: .utf8),
               let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return id
            }
            return GaiPaneDragCoordinator.paneID
        }

        private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
            let mask = sender.draggingSourceOperationMask
            if mask.contains(.move) { return .move }
            if mask.contains(.copy) { return .copy }
            return .generic
        }

        private func topLeftPoint(from sender: NSDraggingInfo) -> CGPoint {
            let point = convert(sender.draggingLocation, from: nil)
            return CGPoint(x: point.x, y: bounds.height - point.y)
        }
    }

    func makeNSView(context: Context) -> TargetView {
        let view = TargetView()
        view.destination = destination
        view.setActiveZone = { activeZone = $0 }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: TargetView, context: Context) {
        view.destination = destination
        view.setActiveZone = { activeZone = $0 }
        view.onDrop = onDrop
    }
}

private func gaiPaneDropZone(for location: CGPoint, size: CGSize) -> GaiSplitDropZone {
        let x = max(0, min(size.width, location.x))
        let y = max(0, min(size.height, location.y))
        let xRatio = size.width <= 0 ? 0.5 : x / size.width
        let yRatio = size.height <= 0 ? 0.5 : y / size.height
        let edge: CGFloat = 0.28
        if xRatio < edge { return .left }
        if xRatio > 1 - edge { return .right }
        if yRatio < edge { return .top }
        if yRatio > 1 - edge { return .bottom }
        return .center
}

private struct GaiPaneAttentionBadge: View {
    @ObservedObject var session: GaiTerminalSession
    let accent: Color

    private var count: Int { session.unreadNotificationCount }
    private var isWaiting: Bool { session.attention == .needsInput }

    private var badgeColor: Color {
        count > 0 ? Color(red: 1, green: 0.27, blue: 0.27) : Color(red: 1, green: 0.68, blue: 0.22)
    }

    private var helpText: String {
        guard let latest = session.latestNotification else { return "Unread notification" }
        if latest.body.isEmpty { return latest.title }
        return "\(latest.title): \(latest.body)"
    }

    var body: some View {
        if count > 0 {
            Text(count > 9 ? "9+" : "\(count)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(badgeColor))
                .shadow(color: badgeColor.opacity(0.35), radius: 2)
                .help(helpText)
                .transaction { transaction in
                    transaction.animation = nil
                }
        } else if isWaiting {
            Image(systemName: "exclamationmark")
                .font(.system(size: 8.5, weight: .black, design: .rounded))
                .foregroundStyle(.black.opacity(0.75))
                .frame(width: 16, height: 16)
                .background(Circle().fill(badgeColor))
                .shadow(color: badgeColor.opacity(0.35), radius: 2)
                .help(helpText)
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
    }
}

private struct GaiPaneNotificationControls: View {
    @ObservedObject var session: GaiTerminalSession
    let size: CGFloat
    let onToggleNotifications: () -> Void
    let onToggleAutoFocus: () -> Void

    private var muteColor: Color { Color(red: 1, green: 0.62, blue: 0.28) }
    private var focusColor: Color { Color(red: 1, green: 0.82, blue: 0.24) }

    var body: some View {
        HStack(spacing: max(2, size * 0.16)) {
            GaiPaneIconButton(
                symbol: session.notificationsEnabled ? "bell" : "bell.slash.fill",
                help: session.notificationsEnabled
                    ? "Mute pane notifications"
                    : "Unmute pane notifications",
                emphasized: !session.notificationsEnabled,
                foreground: session.notificationsEnabled ? .white : muteColor,
                size: size,
                action: onToggleNotifications)
            GaiPaneIconButton(
                symbol: session.autoFocusOnNotification ? "bolt.fill" : "bolt",
                help: session.autoFocusOnNotification
                    ? "Disable auto-focus on completion"
                    : "Auto-focus this pane when it needs input",
                emphasized: session.autoFocusOnNotification,
                foreground: session.autoFocusOnNotification ? focusColor : .white,
                size: size,
                action: onToggleAutoFocus)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Minimal terminal wrapper for GaiTerm's performance path. It keeps the
/// native Ghostty surface and focus values, but skips Ghostty's per-surface
/// SwiftUI overlays.
private struct GaiFastSurfaceWrapper: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @FocusState private var surfaceFocus: Bool

    var body: some View {
        GeometryReader { geo in
            Ghostty.SurfaceRepresentable(view: surfaceView, size: geo.size)
                .focused($surfaceFocus)
                .focusedValue(\.ghosttySurfacePwd, surfaceView.pwd)
                .focusedValue(\.ghosttySurfaceView, surfaceView)
                .focusedValue(\.ghosttySurfaceCellSize, surfaceView.cellSize)
        }
        .ghosttySurfaceView(surfaceView)
    }
}

/// Keeps the pane's opaque backing alive and strips expensive layer effects.
private struct GaiSurfaceLayerAsserter: NSViewRepresentable {
    /// Apple's elevated dark surface gray — must match `StageCard`'s.
    static let interiorGray = CGColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)

    let surfaceView: Ghostty.SurfaceView
    var backdrop: CGColor = GaiSurfaceLayerAsserter.interiorGray

    final class AsserterView: NSView {
        weak var surfaceView: Ghostty.SurfaceView?
        var backdrop: CGColor = GaiSurfaceLayerAsserter.interiorGray

        /// Invisible to clicks, always. As a plain NSView this would
        /// otherwise swallow mouse events meant for the terminal whenever
        /// AppKit's sibling order puts it above the surface — which SwiftUI
        /// reshuffles on re-renders, making clicks land erratically.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func assertLayerPolicy() {
            guard let layer = surfaceView?.layer else { return }
            layer.compositingFilter = nil
            layer.filters = nil
            layer.backgroundFilters = nil
            layer.opacity = 1
            layer.isOpaque = true
            layer.shouldRasterize = false
            layer.drawsAsynchronously = true
            guard let superlayer = layer.superlayer else { return }
            superlayer.backgroundColor = backdrop
            superlayer.compositingFilter = nil
            superlayer.isOpaque = true
            superlayer.shouldRasterize = false
        }

        override func layout() {
            super.layout()
            assertLayerPolicy()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            assertLayerPolicy()
        }
    }

    func makeNSView(context: Context) -> AsserterView {
        let view = AsserterView()
        view.surfaceView = surfaceView
        view.backdrop = backdrop
        return view
    }

    func updateNSView(_ view: AsserterView, context: Context) {
        view.surfaceView = surfaceView
        view.backdrop = backdrop
        view.assertLayerPolicy()
        // The superlayer can be swapped after this update completes (the
        // representable attaches before the surface settles into its new
        // hierarchy) — assert once more on the next turn.
        DispatchQueue.main.async { [weak view] in
            view?.assertLayerPolicy()
        }
    }
}

/// AppKit-level drag interception for panel resize. This sits above Ghostty's
/// terminal hit path, so grabbing the stage edge never turns into text
/// selection inside the terminal.
struct GaiPanelResizeHandle: NSViewRepresentable {
    @Binding var hovering: Bool
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    final class HandleView: NSView {
        var setHover: (Bool) -> Void = { _ in }
        var onBegan: () -> Void = {}
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: () -> Void = {}
        private var trackingAreaRef: NSTrackingArea?
        private var dragStartScreenX: CGFloat?

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func updateTrackingAreas() {
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                owner: self,
                userInfo: nil)
            trackingAreaRef = area
            addTrackingArea(area)
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) {
            setHover(true)
            NSCursor.resizeLeftRight.set()
        }

        override func mouseExited(with event: NSEvent) {
            if dragStartScreenX == nil {
                setHover(false)
                NSCursor.arrow.set()
            }
        }

        override func mouseDown(with event: NSEvent) {
            dragStartScreenX = NSEvent.mouseLocation.x
            setHover(true)
            onBegan()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStartScreenX else { return }
            onChanged(NSEvent.mouseLocation.x - dragStartScreenX)
        }

        override func mouseUp(with event: NSEvent) {
            dragStartScreenX = nil
            setHover(bounds.contains(convert(event.locationInWindow, from: nil)))
            onEnded()
        }
    }

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.setHover = { hovering = $0 }
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

struct GaiStageTabInteraction: NSViewRepresentable {
    @Binding var pressed: Bool
    let onToggle: () -> Void
    let onResizeBegan: () -> Void
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: () -> Void

    final class TabView: NSView {
        var setPressed: (Bool) -> Void = { _ in }
        var onToggle: () -> Void = {}
        var onResizeBegan: () -> Void = {}
        var onResizeChanged: (CGFloat) -> Void = { _ in }
        var onResizeEnded: () -> Void = {}
        private var trackingAreaRef: NSTrackingArea?
        private var dragStartScreenX: CGFloat?
        private var resizing = false
        private let resizeThreshold: CGFloat = 5

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: resizing ? .resizeLeftRight : .pointingHand)
        }

        override func cursorUpdate(with event: NSEvent) {
            (resizing ? NSCursor.resizeLeftRight : NSCursor.pointingHand).set()
        }

        override func updateTrackingAreas() {
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                owner: self,
                userInfo: nil)
            trackingAreaRef = area
            addTrackingArea(area)
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func mouseExited(with event: NSEvent) {
            if dragStartScreenX == nil {
                NSCursor.arrow.set()
            }
        }

        override func mouseDown(with event: NSEvent) {
            dragStartScreenX = NSEvent.mouseLocation.x
            resizing = false
            setPressed(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStartScreenX else { return }
            let deltaX = NSEvent.mouseLocation.x - dragStartScreenX
            if !resizing, abs(deltaX) >= resizeThreshold {
                resizing = true
                onResizeBegan()
                NSCursor.resizeLeftRight.set()
                window?.invalidateCursorRects(for: self)
            }
            if resizing {
                onResizeChanged(deltaX)
            }
        }

        override func mouseUp(with event: NSEvent) {
            let didResize = resizing
            dragStartScreenX = nil
            resizing = false
            setPressed(false)
            if didResize {
                onResizeEnded()
            } else {
                onToggle()
            }
        }
    }

    func makeNSView(context: Context) -> TabView {
        let view = TabView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TabView, context: Context) {
        view.setPressed = { pressed = $0 }
        view.onToggle = onToggle
        view.onResizeBegan = onResizeBegan
        view.onResizeChanged = onResizeChanged
        view.onResizeEnded = onResizeEnded
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
    var foreground: Color = .white
    var size: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: max(7, size * 0.47), weight: .bold))
            .foregroundStyle(foreground.opacity(emphasized ? 0.95 : 0.62))
            .frame(width: size, height: size)
            .background(Circle().fill(foreground.opacity(emphasized ? 0.16 : 0)))
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
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 19)
        .background(Capsule().fill(Color.clear))
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
        splits.persistWorkspaceState()
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

// MARK: - Stage slab shape

/// The stage silhouette: the drawer's card-and-pull-tab slab mirrored to the
/// right edge — flat right edge (flush against, and bleeding past, the screen
/// edge), rounded left corners, and a pull tab protruding from the middle of
/// its left edge. Reuses the drawer's geometry so the tab texture and welds
/// are pixel-identical, just flipped.
struct GaiStageSlabShape: Shape {
    func path(in rect: CGRect) -> Path {
        let mirrored = GaiDrawerSlabShape().path(in: rect)
        // Reflect horizontally about the rect's vertical center line.
        let flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0)
        return mirrored.applying(flip)
    }
}
#endif
