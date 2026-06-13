#if os(macOS)
import SwiftUI

// MARK: - Metrics

/// Shared geometry for the floating workspaces drawer. The manager (panel
/// frames) and the SwiftUI views (slab layout) must agree on these numbers,
/// so they live in one place.
enum GaiDrawerMetrics {
    /// How far the card bleeds past the screen edge (off-screen to the left).
    /// The open spring's overshoot dips into this bleed instead of revealing
    /// a gap between the card and the edge.
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
    static let headerHeight: CGFloat = 24
    static let headerGap: CGFloat = 10
    static let verticalPadding: CGFloat = 14

    /// Natural card height for a given number of workspace rows.
    static func cardHeight(forRows rows: Int) -> CGFloat {
        let n = CGFloat(max(rows, 1))
        return verticalPadding * 2 + headerHeight + headerGap
            + n * rowHeight + (n - 1) * rowSpacing
    }
}

// MARK: - Animations

extension Animation {
    /// Drawer pull-out: a fluid spring with a hint of overshoot (the card's
    /// off-screen bleed absorbs it, so no gap ever opens at the edge).
    static let gaiDrawerOpen = Animation.spring(response: 0.5, dampingFraction: 0.78)
    /// Drawer tuck-in: slightly quicker, settles without bounce.
    static let gaiDrawerClose = Animation.spring(response: 0.4, dampingFraction: 0.9)
}

// MARK: - Drawer view

/// The drawer: one Liquid Glass slab — the workspaces card and its pull tab
/// welded into a single shape — that slides out of the screen edge.
///
/// Animation strategy: the panel itself never animates. It only *snaps*
/// between its two frames at moments when the rendered pixels are identical
/// before and after; the visible slide is a GPU-composited SwiftUI spring on
/// the slab's offset. Opening: snap the panel out first, then spring the slab
/// in from the edge. Closing: spring the slab out, then snap the panel back.
struct WorkspaceDrawerView: View {
    @ObservedObject var store: GaiWorkspaceStore
    @ObservedObject var ui: GaiWorkspaceUIModel

    /// Snaps the panel to its open frame. Called synchronously right before
    /// the open spring starts.
    let onWillOpen: () -> Void
    /// Snaps the panel to its resting closed frame. Called once the close
    /// spring has settled.
    let onDidClose: () -> Void

    /// Slab offset: 0 = open appearance; -cardWidth = closed appearance
    /// while the panel is at its open frame.
    @State private var slide: CGFloat = 0
    /// Whether the panel is currently at its open frame.
    @State private var panelIsOut = false
    /// Drives the chevron flip inside the same springs as `slide`.
    @State private var visualOpen = false
    /// Invalidates stale animation-completion callbacks after interruptions.
    @State private var generation = 0
    @State private var tabPressed = false

    /// Settings → Appearance: tint the glass with the selected workspace's
    /// accent color. Live-updates when toggled.
    @AppStorage(GaiPreferenceKey.tintGlassWithWorkspaceAccent)
    private var tintGlass = false

    private typealias M = GaiDrawerMetrics

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
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
                // Interrupting a close mid-flight: retarget the spring; it
                // keeps its velocity.
                withAnimation(.gaiDrawerOpen) {
                    slide = 0
                    visualOpen = true
                }
            } else {
                // At rest. Move the panel to its open frame while re-offsetting
                // the slab by the same amount (pixel-identical), then spring in.
                onWillOpen()
                panelIsOut = true
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { slide = -M.cardWidth }
                DispatchQueue.main.async {
                    guard gen == generation, ui.isExpanded else { return }
                    withAnimation(.gaiDrawerOpen) {
                        slide = 0
                        visualOpen = true
                    }
                }
            }
        } else {
            guard panelIsOut else { return }
            if #available(macOS 14.0, *) {
                withAnimation(.gaiDrawerClose, completionCriteria: .logicallyComplete) {
                    slide = -M.cardWidth
                    visualOpen = false
                } completion: {
                    finishClose(gen)
                }
            } else {
                withAnimation(.gaiDrawerClose) {
                    slide = -M.cardWidth
                    visualOpen = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    finishClose(gen)
                }
            }
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
            // Above the glass (it must not touch the material's live render
            // path), this wash does double duty: it keeps white text legible
            // on the very transparent `.clear` glass, and it guarantees the
            // window surface has enough alpha to be *clickable* — the window
            // server routes clicks through pixels it considers transparent,
            // so bare clear glass would let clicks fall to the window below.
            GaiDrawerSlabShape().fill(Color.black.opacity(0.08))
            cardContent
        }
        .frame(width: M.slabWidth, height: ui.cardHeight)
        .overlay(alignment: .trailing) { chevron }
        .overlay(alignment: .trailing) { tabHitArea }
    }

    /// Accent of the selected workspace — the glass is tinted with it, so
    /// the whole drawer subtly takes on the color of where you are.
    private var selectedAccent: Color {
        guard let workspace = store.workspace(for: ui.selectedWorkspaceID) else {
            return .white
        }
        return .gaiAccent(for: workspace.name)
    }

    @ViewBuilder
    private var glassBase: some View {
        let shape = GaiDrawerSlabShape()
        if #available(macOS 26.0, *) {
            shape.fill(Color.clear)
                .glassEffect(
                    tintGlass ? .regular.tint(selectedAccent.opacity(0.15)) : .regular,
                    in: shape)
                .animation(.easeInOut(duration: 0.3), value: ui.selectedWorkspaceID)
                .animation(.easeInOut(duration: 0.3), value: tintGlass)
                // Clip to the silhouette so the glass's own drop shadow (which
                // spills outside the shape) is trimmed — no dark halo around
                // the tab. Same fix as the stage tab.
                .clipShape(shape)
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: M.headerGap) {
            header
            VStack(alignment: .leading, spacing: M.rowSpacing) {
                ForEach(store.workspaces) { workspace in
                    GaiWorkspaceRow(
                        workspace: workspace,
                        isSelected: workspace.id == ui.selectedWorkspaceID,
                        onSelect: {
                            // Selecting a workspace always shows it — it never
                            // tucks it away (the right-edge tab does that).
                            // Re-selecting the one already on stage just
                            // re-expands it if it was tucked behind its tab.
                            ui.selectedWorkspaceID = workspace.id
                            if store.openWorkspaceID == workspace.id {
                                ui.isStageExpanded = true
                            } else {
                                store.openWorkspaceID = workspace.id
                            }
                        })
                    .frame(height: M.rowHeight)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, M.verticalPadding)
        .padding(.leading, M.bleed + 14)
        .padding(.trailing, M.tabWidth + 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("WORKSPACES")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.6))
                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            Spacer(minLength: 0)
            Button {
                let workspace = store.createWorkspace(
                    name: "Workspace \(store.workspaces.count + 1)",
                    defaultDirectory: FileManager.default.homeDirectoryForCurrentUser)
                ui.selectedWorkspaceID = workspace.id
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(.white.opacity(0.13)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: M.headerHeight)
    }

    // MARK: Tab

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white.opacity(0.95))
            .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
            .rotationEffect(.degrees(visualOpen ? 180 : 0))
            .scaleEffect(tabPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: tabPressed)
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

private struct GaiWorkspaceRow: View {
    @ObservedObject var workspace: GaiWorkspace
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    private var accent: Color { .gaiAccent(for: workspace.name) }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
                .shadow(color: accent.opacity(isSelected ? 0.8 : 0), radius: 3)
            Text(workspace.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.78))
                .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let paneCount = workspace.surfaceTree.root?.gaiPaneCount, paneCount > 0 {
                Text("\(paneCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected
                    ? Color.white.opacity(0.16)
                    : hovering ? Color.white.opacity(0.07) : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .animation(.easeOut(duration: 0.12), value: hovering)
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
    /// Deterministic accent color derived from a workspace name.
    static func gaiAccent(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.66, brightness: 0.95)
    }
}
#endif
