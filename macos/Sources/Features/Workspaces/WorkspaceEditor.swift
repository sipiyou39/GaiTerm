#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Color utilities

extension Color {
    /// Build a color from an "RRGGBB" (or "#RRGGBB") hex string.
    init?(gaiHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }

    /// The color as an uppercase "RRGGBB" hex string.
    var gaiHexString: String {
        let ns = (NSColor(self).usingColorSpace(.sRGB)) ?? .white
        return String(
            format: "%02X%02X%02X",
            Int((ns.redComponent * 255).rounded()),
            Int((ns.greenComponent * 255).rounded()),
            Int((ns.blueComponent * 255).rounded()))
    }

    /// Hue / saturation / brightness (each 0...1) of this color.
    var gaiHSB: (h: Double, s: Double, b: Double) {
        let ns = (NSColor(self).usingColorSpace(.sRGB)) ?? .white
        return (Double(ns.hueComponent),
                Double(ns.saturationComponent),
                Double(ns.brightnessComponent))
    }
}

// MARK: - Palette

/// A curated, generous spread of accent colors — vivid but tasteful, in the
/// product's art direction. Used for the swatch grid and to seed new
/// workspaces with a varied default.
enum GaiWorkspacePalette {
    static let swatches: [String] = [
        "FF6B6B", "FF922B", "FFD43B", "51CF66", "20C997", "22B8CF",
        "4DABF7", "339AF0", "4C6EF5", "7950F2", "9775FA", "BE4BDB",
        "F06595", "E64980", "FA5252", "94D82D", "38D9A9", "ADB5BD",
    ]

    /// A default color for the Nth created workspace, cycling the palette so
    /// fresh workspaces don't all look alike.
    static func next(after count: Int) -> String {
        swatches[count % swatches.count]
    }
}

// MARK: - Editor

/// In-drawer workspace editor: rename, recolor (a real picker, not a row of
/// dots), and delete — all inside the glass card, never spilling out of the
/// panel. Edits are live: the row dot and the drawer's glass tint follow the
/// picker as you drag.
struct GaiWorkspaceEditor: View {
    @ObservedObject var workspace: GaiWorkspace
    @ObservedObject var store: GaiWorkspaceStore
    @ObservedObject var ui: GaiWorkspaceUIModel

    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double
    @State private var hexText: String
    @FocusState private var nameFocused: Bool

    init(workspace: GaiWorkspace, store: GaiWorkspaceStore, ui: GaiWorkspaceUIModel) {
        _workspace = ObservedObject(initialValue: workspace)
        _store = ObservedObject(initialValue: store)
        _ui = ObservedObject(initialValue: ui)
        // Seed the picker from the workspace color at construction — doing it in
        // onAppear instead renders one frame at the default (red) and then snaps,
        // a visible blink.
        let hsb = workspace.accentColor.gaiHSB
        _hue = State(initialValue: hsb.h)
        _saturation = State(initialValue: hsb.s)
        _brightness = State(initialValue: hsb.b)
        _hexText = State(initialValue: workspace.accentColor.gaiHexString)
    }

    private var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            nameField
            GaiSVSquare(hue: hue, saturation: $saturation, brightness: $brightness)
                .frame(height: 150)
                .onChange(of: saturation) { _ in applyColor() }
                .onChange(of: brightness) { _ in applyColor() }
            GaiHueSlider(hue: $hue)
                .frame(height: 16)
                .onChange(of: hue) { _ in applyColor() }
            hexRow
            swatches
            Spacer(minLength: 0)
            deleteButton
        }
        // Mounted only once the card has finished opening (see
        // `WorkspaceDrawerView.cardContent`); the picker is seeded in init, so
        // onAppear just claims the keyboard for the name field.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                ui.editingWorkspaceID = nil
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .heavy))
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: color.opacity(0.7), radius: 4)
        }
        .frame(height: GaiDrawerMetrics.headerHeight)
    }

    private var nameField: some View {
        TextField("Workspace name", text: $workspace.name)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .focused($nameFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(color.opacity(nameFocused ? 0.6 : 0.0), lineWidth: 1.5)))
    }

    private var hexRow: some View {
        HStack(spacing: 8) {
            Text("#")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            TextField("RRGGBB", text: $hexText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .autocorrectionDisabled()
                .onSubmit { commitHex() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.07)))
    }

    private var swatches: some View {
        // Resolve the current hex once, not once per swatch (each is an NSColor
        // conversion) — 18× per render and per drag frame was needless churn.
        let currentHex = color.gaiHexString
        let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 6)
        return LazyVGrid(columns: columns, spacing: 7) {
            ForEach(GaiWorkspacePalette.swatches, id: \.self) { hex in
                let swatch = Color(gaiHex: hex) ?? .white
                let isCurrent = hex == currentHex
                Circle()
                    .fill(swatch)
                    .frame(height: 20)
                    .overlay(
                        Circle().strokeBorder(
                            .white.opacity(isCurrent ? 0.95 : 0.0),
                            lineWidth: 2))
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    .scaleEffect(isCurrent ? 1.08 : 1)
                    .contentShape(Circle())
                    .onTapGesture { select(swatch) }
            }
        }
        .animation(.easeOut(duration: 0.12), value: currentHex)
    }

    private var deleteButton: some View {
        Button {
            let id = workspace.id
            ui.editingWorkspaceID = nil
            store.removeWorkspace(id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                Text("Delete workspace")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 1, green: 0.3, blue: 0.3).opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    /// Push the current HSB to the workspace (live) and keep the hex field synced.
    private func applyColor() {
        workspace.colorHex = color.gaiHexString
        hexText = color.gaiHexString
    }

    private func commitHex() {
        guard let parsed = Color(gaiHex: hexText) else {
            hexText = color.gaiHexString
            return
        }
        let hsb = parsed.gaiHSB
        // Keep the existing hue when the typed color is a pure gray (its hue is
        // meaningless), so the picker doesn't snap to red.
        if hsb.s > 0.001 { hue = hsb.h }
        saturation = hsb.s
        brightness = hsb.b
        applyColor()
    }

    private func select(_ swatch: Color) {
        let hsb = swatch.gaiHSB
        if hsb.s > 0.001 { hue = hsb.h }
        saturation = hsb.s
        brightness = hsb.b
        applyColor()
    }
}

// MARK: - Saturation / Brightness square

/// The 2D picker face: horizontal = saturation, vertical = brightness, tinted
/// by the current hue. Drag the ring anywhere on it.
private struct GaiSVSquare: View {
    let hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                // Hue base, then saturation (white → clear) and brightness
                // (clear → black) gradients stacked — the canonical SV field.
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                LinearGradient(
                    colors: [.white, .clear],
                    startPoint: .leading, endPoint: .trailing)
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .top, endPoint: .bottom)

                thumb
                    .position(
                        x: saturation * w,
                        y: (1 - brightness) * h)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        saturation = min(max(value.location.x / w, 0), 1)
                        brightness = 1 - min(max(value.location.y / h, 0), 1)
                    })
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var thumb: some View {
        Circle()
            .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 2)
    }
}

// MARK: - Hue slider

/// The rainbow bar: drag to choose the hue.
private struct GaiHueSlider: View {
    @Binding var hue: Double

    private var spectrum: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
            .map { Color(hue: $0, saturation: 1, brightness: 1) }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                LinearGradient(colors: spectrum, startPoint: .leading, endPoint: .trailing)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                Capsule()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .frame(width: 14, height: 14)
                    .overlay(Capsule().strokeBorder(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: hue * w - 7)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        hue = min(max(value.location.x / w, 0), 1)
                    })
        }
    }
}
#endif
