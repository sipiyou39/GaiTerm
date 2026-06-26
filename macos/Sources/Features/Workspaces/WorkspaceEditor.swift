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
        VStack(alignment: .leading, spacing: 10) {
            header
            nameField
            // The settings scroll inside the (large) card; the header stays put.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    folderModeSection
                    startupSection
                    toggleSection
                    colorSection
                    bottomBar
                        .padding(.top, 2)
                }
                .padding(.bottom, 4)
                .onChange(of: workspace.perTerminalFolders) { on in
                    seedTerminalsIfNeeded(on)
                }
            }
        }
        // Mounted only once the card has finished opening (see
        // `WorkspaceDrawerView.cardContent`); the picker is seeded in init, so
        // onAppear just claims the keyboard for the name field.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true }
        }
    }

    // MARK: Setting sections

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.45))
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07))
    }

    /// The CLI/folder area, switched by the "Folder per terminal" toggle:
    /// off → one shared folder + CLI counts (simple, original); on → an explicit
    /// list of terminals, each with its own CLI and folder (worktree workflow).
    private var folderModeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                toggleRow("Folder per terminal", $workspace.perTerminalFolders)
            }
            .background(fieldBackground)

            if workspace.perTerminalFolders {
                terminalsSection
            } else {
                folderSection
                cliSection
            }
        }
    }

    /// One row per terminal: CLI menu + its folder + remove. Plus an add button.
    private var terminalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Terminals")
                Spacer(minLength: 0)
                if !workspace.terminals.isEmpty {
                    Text("\(workspace.terminals.count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(workspace.terminals.enumerated()), id: \.element.id) { index, spec in
                    if index > 0 {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                    terminalRow(spec)
                }
                if workspace.terminals.isEmpty {
                    Text("No terminals — add one below.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                }
            }
            .background(fieldBackground)

            Button(action: addTerminal) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Add terminal")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func terminalRow(_ spec: GaiTerminalSpec) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Self.cliChoices, id: \.self) { choice in
                    Button(choice) { updateTerminal(spec.id) { $0.cli = choice } }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(spec.cli)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Text("·").foregroundStyle(.white.opacity(0.2))

            GaiDirectoryPicker(path: spec.directoryPath, accent: color) { picked in
                updateTerminal(spec.id) { $0.directoryPath = picked }
            }

            Spacer(minLength: 0)

            Button { removeTerminal(spec.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove terminal")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    /// One row per CLI — check it on the left, set how many panes on the right.
    /// Several CLIs can be mixed; the grand total is capped at 16.
    private var cliSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("CLI on open")
                Spacer(minLength: 0)
                if totalPanes > 0 {
                    Text("\(totalPanes)/16")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(Self.cliTools.enumerated()), id: \.element) { index, cli in
                    if index > 0 {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                    cliRow(cli)
                }
            }
            .background(fieldBackground)
        }
    }

    private func cliRow(_ cli: String) -> some View {
        let count = workspace.cliCounts[cli] ?? 0
        let on = count > 0
        return HStack(spacing: 9) {
            Button { setCLICount(cli, on ? 0 : 1) } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(on ? color : .white.opacity(0.3))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Text(cli)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(on ? .white : .white.opacity(0.6))

            Spacer(minLength: 0)

            HStack(spacing: 9) {
                stepButton("minus") { setCLICount(cli, count - 1) }
                    .opacity(count == 0 ? 0.25 : 1)
                Text("\(count)")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(on ? .white : .white.opacity(0.35))
                    .frame(minWidth: 12)
                stepButton("plus") { setCLICount(cli, count + 1) }
                    .opacity(totalPanes >= 16 ? 0.25 : 1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Folder the workspace opens in.
    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("Folder")
            Button(action: chooseFolder) {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(folderName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(fieldBackground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// One-off command run when the workspace opens.
    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("Startup command")
            TextField("e.g. npm run dev", text: startupBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(fieldBackground)
        }
    }

    private var toggleSection: some View {
        VStack(spacing: 0) {
            toggleRow("Notifications", $workspace.notifyOnInput)
        }
        .background(fieldBackground)
    }

    /// Uniform row: label left, switch pinned right — so every switch lines up.
    private func toggleRow(_ label: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(color)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    /// The color picker, moved below the other settings — compact.
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("Color")
            GaiSVSquare(hue: hue, saturation: $saturation, brightness: $brightness)
                .frame(height: 104)
                .onChange(of: saturation) { _ in applyColor() }
                .onChange(of: brightness) { _ in applyColor() }
            GaiHueSlider(hue: $hue)
                .frame(height: 16)
                .onChange(of: hue) { _ in applyColor() }
            hexRow
            swatches
        }
    }

    // MARK: Helpers

    static let cliTools = GaiWorkspace.cliOrder

    /// CLI options offered per terminal in the per-folder mode (plus a plain shell).
    static let cliChoices: [String] = GaiWorkspace.cliOrder + [GaiTerminalSpec.shell]

    private var totalPanes: Int { workspace.cliCounts.values.reduce(0, +) }

    // MARK: Per-terminal list editing

    private func updateTerminal(_ id: UUID, _ mutate: (inout GaiTerminalSpec) -> Void) {
        guard let i = workspace.terminals.firstIndex(where: { $0.id == id }) else { return }
        var spec = workspace.terminals[i]
        mutate(&spec)
        workspace.terminals[i] = spec
    }

    /// "+ Add terminal" duplicates the last row (fast for several alike), else a
    /// claude in the workspace's default folder.
    private func addTerminal() {
        let last = workspace.terminals.last
        workspace.terminals.append(GaiTerminalSpec(
            cli: last?.cli ?? "claude",
            directoryPath: last?.directoryPath ?? workspace.defaultDirectory?.path))
    }

    private func removeTerminal(_ id: UUID) {
        workspace.terminals.removeAll { $0.id == id }
    }

    /// First time the mode is switched on, pre-fill the list from the current CLI
    /// counts (all in the default folder) so the user starts from what they had.
    private func seedTerminalsIfNeeded(_ on: Bool) {
        guard on, workspace.terminals.isEmpty else { return }
        let dir = workspace.defaultDirectory?.path
        let cmds = workspace.cliCommandList()
        if cmds.isEmpty {
            workspace.terminals = [GaiTerminalSpec(cli: "claude", directoryPath: dir)]
        } else {
            workspace.terminals = cmds.map { GaiTerminalSpec(cli: $0, directoryPath: dir) }
        }
    }

    /// Set a CLI's pane count, clamped to ≥ 0 and to a grand total of 16.
    private func setCLICount(_ cli: String, _ value: Int) {
        let others = totalPanes - (workspace.cliCounts[cli] ?? 0)
        let allowed = min(max(0, value), 16 - others)
        if allowed <= 0 {
            workspace.cliCounts[cli] = nil
        } else {
            workspace.cliCounts[cli] = allowed
        }
    }

    private var folderName: String {
        workspace.defaultDirectory?.lastPathComponent ?? "Home"
    }

    private var startupBinding: Binding<String> {
        Binding(
            get: { workspace.startupCommand ?? "" },
            set: { workspace.startupCommand = $0.isEmpty ? nil : $0 })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = workspace.defaultDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser

        // The drawer/stage float at `.statusBar`. A blocking `runModal()` froze the
        // whole app (main run loop stuck) and the dialog opened *behind* those
        // panels (invisible). Fix: activate (only if needed), drop our panels below
        // the dialog, lift the dialog, and present it non-blocking with `begin`.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        let restore = GaiFloatingPanels.lower()
        panel.level = .modalPanel
        panel.begin { response in
            restore()
            if response == .OK, let url = panel.url {
                workspace.defaultDirectory = url
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: cancel) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .heavy))
                    Text("Back")
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

    /// The personal palette: no presets. The dashed "+" saves the color you
    /// dialed in the picker; tapping a saved swatch applies it to the workspace;
    /// right-click removes it.
    private var swatches: some View {
        let currentHex = color.gaiHexString
        let alreadySaved = ui.savedColors.contains(currentHex)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 6)
        return LazyVGrid(columns: columns, spacing: 7) {
            Button { ui.saveColor(currentHex) } label: {
                ZStack {
                    Circle().strokeBorder(
                        .white.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [2.5]))
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(alreadySaved ? 0.22 : 0.85))
                }
                .frame(width: 20, height: 20)
                .frame(maxWidth: .infinity)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(alreadySaved)
            .help("Add this color to your palette")

            ForEach(ui.savedColors, id: \.self) { hex in
                let swatch = Color(gaiHex: hex) ?? .white
                let isCurrent = hex == currentHex
                Circle()
                    .fill(swatch)
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        Circle().strokeBorder(
                            .white.opacity(isCurrent ? 0.95 : 0.0),
                            lineWidth: 2)
                            .frame(width: 20, height: 20))
                    .scaleEffect(isCurrent ? 1.1 : 1)
                    .contentShape(Circle())
                    .onTapGesture { select(swatch) }
                    .contextMenu {
                        Button(role: .destructive) {
                            ui.removeSavedColor(hex)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
            }
        }
        .animation(.easeOut(duration: 0.16), value: ui.savedColors)
        .animation(.easeOut(duration: 0.12), value: currentHex)
    }

    /// Split footer: trash (delete) on the left, checkmark (validate) on the right.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button(action: delete) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(red: 1, green: 0.3, blue: 0.3).opacity(0.13)))
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Delete workspace")

            Button(action: validate) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(color.opacity(0.9)))
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Done")
        }
    }

    // MARK: Actions

    /// Back: cancel. Discards a just-created workspace; otherwise just closes.
    /// After discarding a draft, fall back to the workspace that's actually on
    /// stage so the drawer comes back to it instead of a dangling selection.
    private func cancel() {
        let id = workspace.id
        let wasNew = ui.editingIsNew
        ui.editingIsNew = false
        ui.editingWorkspaceID = nil
        if wasNew {
            store.removeWorkspace(id)
            ui.selectedWorkspaceID = store.openWorkspaceID
        }
    }

    /// Checkmark: keep the workspace, committing the picked color. For a
    /// just-created workspace, open it right away so its CLI panes are built and
    /// launched without a second click.
    private func validate() {
        applyColor()
        let wasNew = ui.editingIsNew
        if wasNew {
            store.discardLiveTerminalSurfaces(in: workspace)
        }
        ui.editingIsNew = false
        ui.editingWorkspaceID = nil
        if wasNew {
            ui.selectedWorkspaceID = workspace.id
            store.openWorkspaceID = workspace.id
        }
        store.save()
    }

    private func delete() {
        let id = workspace.id
        ui.editingIsNew = false
        ui.editingWorkspaceID = nil
        store.removeWorkspace(id)
    }

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
            // High priority so dragging the picker dials the color instead of
            // scrolling the settings list it now lives in.
            .highPriorityGesture(
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
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        hue = min(max(value.location.x / w, 0), 1)
                    })
        }
    }
}
#endif
