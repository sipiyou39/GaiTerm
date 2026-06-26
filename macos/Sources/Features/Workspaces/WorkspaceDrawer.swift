#if os(macOS)
import SwiftUI

// MARK: - Metrics

/// Shared geometry for the floating workspaces drawer. The manager (panel
/// frames) and the SwiftUI views (slab layout) must agree on these numbers,
/// so they live in one place.
enum GaiDrawerMetrics {
    /// How far the card bleeds past the screen edge (off-screen to the left).
    /// The drawer still keeps a small off-screen bleed so fast slides never
    /// reveal a gap between the card and the edge.
    static let bleed: CGFloat = 40

    /// Visible width of the workspaces card when the drawer is open.
    static let cardWidth: CGFloat = 216

    /// How far the pull tab protrudes past the card's right edge. Must equal
    /// `filletRadius + tabCornerRadius` so the tab outline is one smooth
    /// S-curve from the card edge to the tab face.
    static let tabWidth: CGFloat = 26

    /// Height of the tab face (excluding the concave flares).
    static let tabHeight: CGFloat = 76

    /// Radius of the concave flares welding the tab to the card / screen edge.
    static let filletRadius: CGFloat = 14

    /// Radius of the tab's outer (right) corners.
    static let tabCornerRadius: CGFloat = 12

    /// Radius of the card's right corners. The left side is always flat: it
    /// sits flush against (and bleeds past) the screen edge.
    static let cardCornerRadius: CGFloat = 20

    /// Full slab width: off-screen bleed + card + tab.
    static var slabWidth: CGFloat { bleed + cardWidth + tabWidth }

    /// Vertical extent of the tab including both flares.
    static var tabExtent: CGFloat { tabHeight + 2 * filletRadius }

    // Layout constants the card-height formula depends on. If the SwiftUI
    // layout changes, keep `cardHeight(forRows:)` in sync.
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 2
    static let headerHeight: CGFloat = 32      // the tabs row
    static let headerGap: CGFloat = 16         // breathing room: tabs → rows
    static let verticalPadding: CGFloat = 14   // equal top & bottom padding

    /// Natural card height for a given number of workspace rows.
    static func cardHeight(forRows rows: Int) -> CGFloat {
        let n = CGFloat(max(rows, 1))
        return verticalPadding * 2 + headerHeight + headerGap
            + n * rowHeight + (n - 1) * rowSpacing
    }

    /// Fixed card height while the in-drawer workspace editor is open — tall
    /// enough for the name field, the color picker, the swatch palette and the
    /// delete action, without ever spilling outside the panel.
    static let editorHeight: CGFloat = 476

    /// The editor's content area (inside the card's vertical padding). The editor
    /// is laid out *once* at this fixed height and the growing card clips it into
    /// view, so its GeometryReaders/grid never re-measure mid-animation.
    static var editorContentHeight: CGFloat { editorHeight - 2 * verticalPadding }
}

// MARK: - Animations

extension Animation {
    /// Drawer pull-out: exactly matches the stage slide, no overshoot.
    static let gaiDrawerOpen = Animation.gaiStageOpen
    /// Drawer tuck-in: exactly matches the stage tuck, no overshoot.
    static let gaiDrawerClose = Animation.gaiStageClose
    /// The card breathing taller/shorter for the workspace editor — organic,
    /// a hair of overshoot so it feels alive without jiggling.
    static let gaiCardResize = Animation.spring(response: 0.46, dampingFraction: 0.84)
}

// MARK: - Drawer view

/// The drawer: one Liquid Glass slab — the workspaces card and its pull tab
/// welded into a single shape — that slides out of the screen edge.
///
/// Animation strategy: the panel itself never animates. It only *snaps*
/// between its two frames at moments when the rendered pixels are identical
/// before and after; the visible slide is a GPU-composited SwiftUI offset on
/// the slab's offset. Opening: snap the panel out first, then slide the slab
/// in from the edge. Closing: slide the slab out, then snap the panel back.
struct WorkspaceDrawerView: View {
    @ObservedObject var store: GaiWorkspaceStore
    @ObservedObject var ui: GaiWorkspaceUIModel

    /// Snaps the panel to its open frame. Called synchronously right before
    /// the fast slide starts.
    let onWillOpen: () -> Void
    /// Snaps the panel to its resting closed frame. Called once the close
    /// slide has settled.
    let onDidClose: () -> Void
    /// Pauses terminal rendering before live panel resize starts.
    let onResizeBegan: () -> Void
    /// Applies a user-driven drawer width.
    let onResizeWidth: (CGFloat) -> Void
    /// Restores terminal rendering after live panel resize ends.
    let onResizeEnded: () -> Void
    /// Toggles whether drawer/stage widths stay linked.
    let onToggleWidthLink: () -> Void

    /// Slab offset: 0 = open appearance; -cardWidth = closed appearance
    /// while the panel is at its open frame.
    @State private var slide: CGFloat = 0
    /// Whether the panel is currently at its open frame.
    @State private var panelIsOut = false
    /// Drives the chevron flip inside the same animations as `slide`.
    @State private var visualOpen = false
    /// Invalidates stale animation-completion callbacks after interruptions.
    @State private var generation = 0
    @State private var tabPressed = false
    @State private var draggingWorkspaceID: GaiWorkspace.ID?
    @State private var workspaceDragStartIndex: Int?
    @State private var workspaceDragTargetIndex: Int?
    @State private var workspaceDragTranslationY: CGFloat = 0
    @State private var drawerResizeStartWidth: CGFloat?
    @State private var drawerResizeHover = false

    /// Settings → Appearance: tint the glass with the selected workspace's
    /// accent color. Live-updates when toggled.
    @AppStorage(GaiPreferenceKey.tintGlassWithWorkspaceAccent)
    private var tintGlass = false

    private typealias M = GaiDrawerMetrics

    var body: some View {
        ZStack(alignment: .leading) {
            // The window is kept tall enough for the editor at all times so
            // entering it never resizes the window. This clear filler must not
            // swallow clicks in that extra transparent area — only the glass
            // slab is interactive.
            Color.clear.allowsHitTesting(false)
            slab.offset(x: slide)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onReceive(ui.$isExpanded.removeDuplicates().dropFirst()) { expanded in
            setExpanded(expanded)
        }
    }

    // MARK: Slide choreography

    private func setExpanded(_ expanded: Bool) {
        generation += 1
        let gen = generation
        if expanded {
            if panelIsOut {
                runSlide(.gaiDrawerOpen, { slide = 0; visualOpen = true })
            } else {
                // At rest. Re-offset the slab first (pixel-identical), move the
                // panel to its open frame, then slide in.
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { slide = -ui.drawerCardWidth }
                onWillOpen()
                panelIsOut = true
                DispatchQueue.main.async {
                    guard gen == generation, ui.isExpanded else { return }
                    runSlide(.gaiDrawerOpen, { slide = 0; visualOpen = true })
                }
            }
        } else {
            guard panelIsOut else { return }
            runSlide(.gaiDrawerClose, { slide = -ui.drawerCardWidth; visualOpen = false }) {
                finishClose(gen)
            }
        }
    }

    private func runSlide(
        _ animation: Animation,
        _ changes: @escaping () -> Void,
        then completion: @escaping () -> Void = {}
    ) {
        withAnimation(animation, changes)
        DispatchQueue.main.asyncAfter(deadline: .now() + GaiStageMetrics.slideSettleDelay) {
            completion()
        }
    }

    private func finishClose(_ gen: Int) {
        guard gen == generation, !ui.isExpanded, panelIsOut else { return }
        panelIsOut = false
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { slide = 0 }
        onDidClose()
    }

    // MARK: Slab

    /// The glass is a standalone leaf layer with the content stacked above
    /// it — the same structure as the dadido mascot, whose glass composites
    /// live. Wrapping the content in `glassEffect` (or a
    /// `GlassEffectContainer`, or putting a `.background` under the effect)
    /// pushes the material onto a snapshotting render path.
    private var slab: some View {
        ZStack {
            glassBase
            cardContent
        }
        // No pull tab anymore — just the card (off-screen bleed + card width).
        .frame(width: M.bleed + ui.drawerCardWidth, height: ui.cardHeight)
        .overlay(alignment: .trailing) { drawerResizeHandle }
    }

    /// Accent of the selected workspace — the glass is tinted with it, so
    /// the whole drawer subtly takes on the color of where you are.
    private var selectedAccent: Color {
        guard let workspace = store.workspace(for: ui.selectedWorkspaceID) else {
            return .white
        }
        return workspace.accentColor
    }

    /// Flat panel gray instead of Liquid Glass — the glass re-rendered every
    /// frame while the card height animated, which is what made the expansion
    /// stutter. A solid fill animates for free.
    private var glassBase: some View {
        // Linked to the stage: same accent as `stageWorkspace` (the open workspace,
        // or the default scratch terminal when none) + the same tint setting, so
        // the drawer and the stage are always the exact same color.
        let accent = store.stageWorkspace.accentColor
        // No tab silhouette now: a plain card, flat on the left (flush with the
        // screen edge), rounded on the right.
        return UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: M.cardCornerRadius,
            topTrailingRadius: M.cardCornerRadius,
            style: .continuous)
            .fill(Color.gaiPanelColor(accent: accent, tinted: tintGlass))
    }

    @ViewBuilder
    private var cardContent: some View {
        ZStack(alignment: .top) {
            if ui.editingWorkspaceID != nil {
                // The card grows EMPTY (perfectly smooth — verified): the editor
                // is NOT in the view tree during the growth at all (opacity 0
                // still composites every frame — that was the stutter). It is
                // mounted (editorMounted) only once the card reaches its open
                // size, on a still card, then faded in via editorContentVisible
                // one tick later — a progressive crossfade on an already-laid-out
                // view, never anchored to a still-moving edge.
                if ui.editorMounted,
                   let workspace = store.workspace(for: ui.editingWorkspaceID) {
                    GaiWorkspaceEditor(workspace: workspace, store: store, ui: ui)
                        .opacity(ui.editorContentVisible ? 1 : 0)
                        .transition(.identity)
                }
            } else {
                // Tabs header (Workspaces · Folders) on top, then either the
                // workspace rows or the (placeholder) file explorer.
                VStack(alignment: .leading, spacing: M.headerGap) {
                    tabsHeader
                    if ui.explorerOpen {
                        // Mounted only once the card finished expanding, then
                        // faded in — same as the workspace editor.
                        if ui.explorerMounted {
                            fileTab.opacity(ui.explorerContentVisible ? 1 : 0)
                        }
                    } else {
                        rowsList
                    }
                }
                // Fade out fast on the way to the editor, so the card grows
                // empty instead of dragging residual rows through the expansion.
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, M.verticalPadding)
        .padding(.leading, M.bleed + 14)
        .padding(.trailing, 14)   // no tab to clear anymore
        .animation(.easeInOut(duration: 0.28), value: ui.editingWorkspaceID)
        .animation(.easeInOut(duration: 0.35), value: ui.editorContentVisible)
        // Fade the file tree in once mounted (a pure opacity crossfade on a
        // settled card — safe, unlike a geometry animation on explorerOpen).
        .animation(.easeInOut(duration: 0.35), value: ui.explorerContentVisible)
        // NOTE: no `.animation(value: explorerOpen)` here on purpose. The slab
        // frame height is already animated (with `.gaiCardResize`) by the
        // manager; adding a second, differently-timed animation here made the
        // tab header race ahead of the slab background and "float" to its final
        // spot before the card caught up. Letting the content ride the slab's
        // own height animation keeps header and background perfectly in sync.
        .overlay(alignment: .bottomTrailing) {
            widthLinkButton
                .padding(.trailing, 14)
                .padding(.bottom, 10)
        }
    }

    private var drawerResizeHandle: some View {
        GaiPanelResizeHandle(
            hovering: $drawerResizeHover,
            onBegan: {
                drawerResizeStartWidth = ui.drawerCardWidth
                onResizeBegan()
            },
            onChanged: { deltaX in
                let start = drawerResizeStartWidth ?? ui.drawerCardWidth
                onResizeWidth(start + deltaX)
            },
            onEnded: {
                drawerResizeStartWidth = nil
                onResizeEnded()
            })
        .frame(width: 18)
        .frame(height: ui.cardHeight)
        .contentShape(Rectangle())
    }

    private var widthLinkButton: some View {
        Button(action: onToggleWidthLink) {
            Image(systemName: "link")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white.opacity(ui.panelWidthsLinked ? 0.9 : 0.42))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(ui.panelWidthsLinked ? 0.16 : 0.08)))
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(ui.panelWidthsLinked ? 0.18 : 0.08), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(ui.panelWidthsLinked ? "Unlink panel widths" : "Link panel widths")
    }

    // MARK: Tabs header

    private var tabsHeader: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                tabButton("square.grid.2x2", "Space", active: !ui.explorerOpen) { ui.explorerOpen = false }
                    .contextMenu { Button("New workspace", action: createNewWorkspace) }
                tabButton("folder", "File", active: ui.explorerOpen) { ui.explorerOpen = true }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.06)))
            Spacer(minLength: 0)
            // Stage mode toggle: terminal (default) ⇄ editor. Greyed until a
            // file is open (nothing to switch to otherwise).
            stageModeToggle
        }
        .frame(height: 32)
    }

    private var stageModeToggle: some View {
        let hasFile = !ui.openFiles.isEmpty
        return Button {
            if hasFile { ui.stageShowsEditor.toggle() }
        } label: {
            Image(systemName: ui.stageShowsEditor ? "doc.text" : "terminal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(hasFile ? 0.85 : 0.25))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasFile)
        .help(ui.stageShowsEditor ? "Show terminal" : "Show editor")
    }

    private func tabButton(_ icon: String, _ label: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(active ? .white : .white.opacity(0.5))
            // Equal width for every tab (sized for the longest label) so they
            // line up no matter how short the word is.
            .frame(width: 66, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? Color.white.opacity(0.16) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        // No `.animation(value: active)`: tab switching coincides with the card
        // resize, so a tab-local animation would capture the tab's resize-driven
        // position change and run it on its own timeline — making the label race
        // ahead of (or lag behind) the slab background. The highlight just snaps.
    }

    /// Create a workspace and drop straight into the editor (named, colored, ready).
    private func createNewWorkspace() {
        let workspace = store.createWorkspace(
            name: "",
            defaultDirectory: FileManager.default.homeDirectoryForCurrentUser)
        ui.selectedWorkspaceID = workspace.id
        ui.editingIsNew = true
        ui.editingWorkspaceID = workspace.id
    }

    @ViewBuilder
    private var rowsList: some View {
        if store.workspaces.isEmpty {
            emptyWorkspacesPlaceholder
        } else {
            workspaceRows
        }
    }

    private var emptyWorkspacesPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Text("No workspaces")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Button(action: createNewWorkspace) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("New workspace")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceRows: some View {
        let activeWorkspaceID = store.openWorkspaceID ?? ui.selectedWorkspaceID
        return VStack(alignment: .leading, spacing: M.rowSpacing) {
            ForEach(store.workspaces) { workspace in
                GaiWorkspaceRow(
                    workspace: workspace,
                    isSelected: workspace.id == activeWorkspaceID,
                    isDragging: draggingWorkspaceID == workspace.id,
                    onSelect: {
                        ui.selectedWorkspaceID = workspace.id
                        ui.stageShowsEditor = false
                        if store.openWorkspaceID == workspace.id {
                            ui.isStageExpanded = true
                        } else {
                            store.openWorkspaceID = workspace.id
                        }
                    },
                    onEdit: {
                        ui.editingIsNew = false
                        ui.editingWorkspaceID = workspace.id
                    },
                    onDuplicate: { store.duplicateWorkspace(workspace.id) },
                    onDelete: {
                        store.removeWorkspace(workspace.id)
                        let fallback = store.openWorkspaceID ?? store.workspaces.first?.id
                        ui.selectedWorkspaceID = fallback
                        if store.openWorkspaceID == nil {
                            store.openWorkspaceID = fallback
                        }
                    })
                .frame(height: M.rowHeight)
                .zIndex(draggingWorkspaceID == workspace.id ? 2 : 0)
                .offset(y: workspaceDragOffset(for: workspace.id))
                .simultaneousGesture(workspaceDragGesture(for: workspace.id))
            }
            GaiAddWorkspaceRow(action: createNewWorkspace)
                .frame(height: M.rowHeight)
        }
        .animation(.spring(response: 0.23, dampingFraction: 0.9), value: workspaceDragTargetIndex)
    }

    private func workspaceDragGesture(for id: GaiWorkspace.ID) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                updateWorkspaceDrag(id: id, translationY: value.translation.height)
            }
            .onEnded { _ in
                finishWorkspaceDrag()
            }
    }

    private func updateWorkspaceDrag(id: GaiWorkspace.ID, translationY: CGFloat) {
        let stride = M.rowHeight + M.rowSpacing
        if draggingWorkspaceID == nil {
            guard let startIndex = store.workspaces.firstIndex(where: { $0.id == id }) else { return }
            draggingWorkspaceID = id
            workspaceDragStartIndex = startIndex
            workspaceDragTargetIndex = startIndex
            workspaceDragTranslationY = 0
        }

        guard draggingWorkspaceID == id,
              let startIndex = workspaceDragStartIndex
        else { return }

        let minY = CGFloat(-startIndex) * stride
        let maxY = CGFloat(store.workspaces.count - 1 - startIndex) * stride
        let clampedY = min(max(translationY, minY), maxY)
        workspaceDragTranslationY = clampedY

        let rawStep = clampedY / stride
        let nextIndex = min(
            max(0, startIndex + Int(rawStep.rounded(.toNearestOrAwayFromZero))),
            store.workspaces.count - 1)
        guard nextIndex != workspaceDragTargetIndex else { return }
        withAnimation(.spring(response: 0.23, dampingFraction: 0.9)) {
            workspaceDragTargetIndex = nextIndex
        }
    }

    private func finishWorkspaceDrag() {
        let sourceID = draggingWorkspaceID
        let startIndex = workspaceDragStartIndex
        let targetIndex = workspaceDragTargetIndex
        let finalOrder: [GaiWorkspace.ID]? = {
            guard let sourceID,
                  let startIndex,
                  let targetIndex,
                  startIndex != targetIndex
            else { return nil }

            var order = store.workspaces.map(\.id)
            order.removeAll { $0 == sourceID }
            order.insert(sourceID, at: min(targetIndex, order.count))
            return order
        }()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let finalOrder {
                store.reorderWorkspaces(finalOrder)
            }
            draggingWorkspaceID = nil
            workspaceDragStartIndex = nil
            workspaceDragTargetIndex = nil
            workspaceDragTranslationY = 0
        }
    }

    private func workspaceDragOffset(for id: GaiWorkspace.ID) -> CGFloat {
        let stride = M.rowHeight + M.rowSpacing
        guard let draggingWorkspaceID,
              let startIndex = workspaceDragStartIndex,
              let targetIndex = workspaceDragTargetIndex,
              let index = store.workspaces.firstIndex(where: { $0.id == id })
        else { return 0 }

        if id == draggingWorkspaceID {
            return workspaceDragTranslationY
        }
        if targetIndex > startIndex,
           index > startIndex, index <= targetIndex {
            return -stride
        }
        if targetIndex < startIndex,
           index >= targetIndex, index < startIndex {
            return stride
        }
        return 0
    }

    /// The File tab: the selected workspace's folder, browsed as a tree.
    private var fileTab: some View {
        let workspace = store.workspace(for: ui.selectedWorkspaceID)
        return GaiFileExplorerView(
            rootPath: workspace?.defaultDirectory?.path,
            accent: workspace?.accentColor ?? .white,
            onOpenFile: { node in
                // Accumulate the file as a tab and make it active; open the stage
                // for the selected workspace if it isn't already showing.
                if !ui.openFiles.contains(node.path) { ui.openFiles.append(node.path) }
                ui.activeFilePath = node.path
                ui.stageShowsEditor = true
                if store.openWorkspaceID == nil {
                    store.openWorkspaceID = ui.selectedWorkspaceID
                } else {
                    ui.isStageExpanded = true
                }
            })
    }

    // MARK: Tab

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white.opacity(0.95))
            .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
            .rotationEffect(.degrees(visualOpen ? 180 : 0))
            .scaleEffect(tabPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.08), value: tabPressed)
            .frame(width: M.tabWidth)
    }

    private var tabHitArea: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: M.tabWidth + M.filletRadius, height: M.tabExtent + 8)
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
                    .onChanged { _ in tabPressed = true }
                    .onEnded { _ in
                        tabPressed = false
                        ui.isExpanded.toggle()
                    })
    }
}

// MARK: - Row

/// A subtle "add" row pinned under the workspace list — always available to
/// create a new workspace, aligned with the rows above (dot column → "+").
private struct GaiAddWorkspaceRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.45))
                    .frame(width: 20)
                Text("New workspace")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(hovering ? 0.75 : 0.45))
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.06) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct GaiWorkspaceRow: View {
    @ObservedObject var workspace: GaiWorkspace
    let isSelected: Bool
    let isDragging: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var accent: Color { workspace.accentColor }

    /// Unread CLI notifications in this workspace.
    private var unreadCount: Int {
        workspace.unreadNotificationCount
    }

    /// Panes known to be waiting for user input, even if their notification was
    /// already opened/read or muted.
    private var waitingCount: Int {
        workspace.waitingSessionCount
    }

    var body: some View {
        HStack(spacing: 10) {
            // The color dot IS the settings entry — click it to edit (rename,
            // color, CLIs…). Larger invisible hit area so it's easy to hit.
            Button(action: onEdit) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                    .shadow(color: accent.opacity(isSelected ? 0.8 : 0), radius: 3)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Workspace settings")

            Text(workspace.name.isEmpty ? "Untitled" : workspace.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(workspace.name.isEmpty
                    ? .white.opacity(0.4)
                    : (isSelected ? .white : .white.opacity(0.78)))
                .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                .lineLimit(1)
            Spacer(minLength: 0)

            // The ONLY thing allowed on a row besides its identity: a compact
            // attention badge for CLI notifications / idle agents.
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Color(red: 1, green: 0.27, blue: 0.27)))
            } else if waitingCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                    if waitingCount > 1 {
                        Text("\(waitingCount)")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(.black.opacity(0.75))
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Color(red: 1, green: 0.68, blue: 0.22)))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected
                    ? Color.white.opacity(isDragging ? 0.18 : 0.16)
                    : isDragging ? Color.white.opacity(0.10)
                    : hovering ? Color.white.opacity(0.07) : Color.clear))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isDragging ? Color.white.opacity(0.16) : Color.clear,
                    lineWidth: 1)
        }
        .scaleEffect(isDragging ? 1.015 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 9, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(action: onEdit) { Label("Modifier", systemImage: "slider.horizontal.3") }
            Button(action: onDuplicate) { Label("Dupliquer", systemImage: "plus.square.on.square") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Supprimer", systemImage: "trash") }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.10), value: isDragging)
    }
}

// MARK: - Slab shape

/// The drawer silhouette: a card with a flat left edge (flush against — and
/// bleeding past — the screen edge), rounded right corners, and a pull tab
/// protruding from the middle of its right edge. Concave fillets weld the tab
/// to the card so the whole thing reads as one piece of glass; when only the
/// tab peeks out of the screen edge, those same fillets flare into the edge.
struct GaiDrawerSlabShape: Shape {
    func path(in rect: CGRect) -> Path {
        typealias M = GaiDrawerMetrics
        let cardRight = rect.maxX - M.tabWidth
        let cornerR = min(M.cardCornerRadius, rect.height / 2)
        let tabTop = rect.midY - M.tabHeight / 2
        let tabBottom = rect.midY + M.tabHeight / 2

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top edge, then the card's top-right corner.
        path.addLine(to: CGPoint(x: cardRight - cornerR, y: rect.minY))
        path.addArc(
            center: CGPoint(x: cardRight - cornerR, y: rect.minY + cornerR),
            radius: cornerR,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)

        // Down the card edge to the tab's top flare.
        path.addLine(to: CGPoint(x: cardRight, y: tabTop - M.filletRadius))

        // Concave flare out to the tab, then the tab's top-right corner.
        // Because tabWidth == filletRadius + tabCornerRadius, the two arcs
        // join tangentially into one S-curve.
        path.addArc(
            center: CGPoint(x: cardRight + M.filletRadius, y: tabTop - M.filletRadius),
            radius: M.filletRadius,
            startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addArc(
            center: CGPoint(x: rect.maxX - M.tabCornerRadius, y: tabTop + M.tabCornerRadius),
            radius: M.tabCornerRadius,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)

        // The tab face.
        path.addLine(to: CGPoint(x: rect.maxX, y: tabBottom - M.tabCornerRadius))

        // The tab's bottom-right corner, then the concave flare back in.
        path.addArc(
            center: CGPoint(x: rect.maxX - M.tabCornerRadius, y: tabBottom - M.tabCornerRadius),
            radius: M.tabCornerRadius,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addArc(
            center: CGPoint(x: cardRight + M.filletRadius, y: tabBottom + M.filletRadius),
            radius: M.filletRadius,
            startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)

        // Down the card edge, the card's bottom-right corner, and home along
        // the flat left edge.
        path.addLine(to: CGPoint(x: cardRight, y: rect.maxY - cornerR))
        path.addArc(
            center: CGPoint(x: cardRight - cornerR, y: rect.maxY - cornerR),
            radius: cornerR,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Color

extension Color {
    /// Flat panel gray, used in place of Liquid Glass for the drawer and stage
    /// (the live glass re-rendered every frame as a card resized, which made the
    /// expansion stutter). #1C1C1E — the exact gray of the dadido control panel
    /// (its `backgroundDark`), and the same as the terminal interior, so the
    /// whole UI reads as one consistent gray.
    static let gaiPanelGray = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)

    /// The panel surface color: the flat dark gray, or — when the "tint panels
    /// with workspace color" setting is on — that gray blended with the
    /// workspace accent (a dark, colored gray, never the loud raw accent).
    static func gaiPanelColor(accent: Color, tinted: Bool) -> Color {
        guard tinted else { return gaiPanelGray }
        let a = NSColor(accent).usingColorSpace(.sRGB) ?? .gray
        let f: CGFloat = 0.22
        func mix(_ base: CGFloat, _ c: CGFloat) -> CGFloat { base * (1 - f) + c * f }
        return Color(red: mix(28 / 255, a.redComponent),
                     green: mix(28 / 255, a.greenComponent),
                     blue: mix(30 / 255, a.blueComponent))
    }

    /// Content interior fill. It deliberately does not use workspace tint:
    /// the tint belongs to drawer/header chrome, not terminal/editor surfaces.
    static func gaiInteriorColor(accent _: Color, tinted _: Bool) -> Color {
        let base = (r: 0.110, g: 0.110, b: 0.118)
        return Color(red: base.r, green: base.g, blue: base.b)
    }

    /// Terminal pane color. Panes match the header exactly; focus is shown by
    /// a stroke in `GaiPaneView`, never by changing terminal luminance.
    static func gaiTerminalPaneColor(
        accent: Color,
        tinted: Bool,
        active _: Bool
    ) -> Color {
        gaiInteriorColor(accent: accent, tinted: tinted)
    }

    /// Deterministic accent color derived from a workspace name.
    static func gaiAccent(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.66, brightness: 0.95)
    }
}
#endif
