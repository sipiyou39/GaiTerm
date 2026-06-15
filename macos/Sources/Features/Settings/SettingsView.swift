import AppKit
import ServiceManagement
import SwiftUI

/// UserDefaults keys for GaiTerm's GUI settings. Shared between the settings UI
/// and the features that consume them.
enum GaiPreferenceKey {
    /// Tint the workspaces drawer's glass with the selected workspace's accent.
    static let tintGlassWithWorkspaceAccent = "GaiTintGlassWithWorkspaceAccent"
    /// Code editor font size (points).
    static let editorFontSize = "GaiEditorFontSize"
    /// Show line numbers in the code editor.
    static let editorShowLineNumbers = "GaiEditorShowLineNumbers"
    /// Soft-wrap long lines in the code editor.
    static let editorWrapLines = "GaiEditorWrapLines"
    /// Restore saved workspaces on launch (vs. start empty).
    static let restoreWorkspaces = "GaiRestoreWorkspaces"
}

/// Settings design tokens (dark, flat — matches the drawer/stage).
private enum S {
    static let bg = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let sidebar = Color(red: 0.085, green: 0.085, blue: 0.095)
    static let card = Color.white.opacity(0.045)
    static let accent = Color(red: 0.42, green: 0.64, blue: 0.96)
}

// MARK: - Window

/// Presents the settings window (App menu → Settings…). One window for the
/// app's lifetime.
final class GaiSettingsWindowController {
    static let shared = GaiSettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: host)
            window.title = "GaiTerm Settings"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(S.bg)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case editor = "Editor"
    case updates = "Updates"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .updates: return "arrow.down.circle"
        }
    }
}

struct SettingsView: View {
    @State private var category: SettingsCategory = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            ScrollView {
                detail
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 500)
        .background(S.bg)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            brand
                .padding(.horizontal, 14)
                .padding(.top, 30)
                .padding(.bottom, 16)
            ForEach(SettingsCategory.allCases) { item in
                sidebarItem(item)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(S.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image("AppIconImage")
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("GaiTerm")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(appVersion)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func sidebarItem(_ item: SettingsCategory) -> some View {
        let active = category == item
        return Button { category = item } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(item.rawValue)
                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? S.accent.opacity(0.22) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var detail: some View {
        switch category {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .editor: EditorSettings()
        case .updates: UpdatesSettings()
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Version \(v)"
    }
}

// MARK: - Reusable pieces

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.4))
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(S.card))
        }
        .padding(.bottom, 20)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var first: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if !first { Divider().overlay(Color.white.opacity(0.06)) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

private struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    var first: Bool = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, first: first) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(S.accent)
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(GaiPreferenceKey.restoreWorkspaces) private var restore = true
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Startup") {
                SettingsToggle(
                    title: "Launch GaiTerm at login",
                    subtitle: "Open GaiTerm automatically when you log in.",
                    first: true,
                    isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                SettingsToggle(
                    title: "Restore workspaces",
                    subtitle: "Reopen your saved workspaces on launch instead of starting empty.",
                    isOn: $restore)
            }
        }
        .onAppear { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(GaiPreferenceKey.tintGlassWithWorkspaceAccent) private var tintGlass = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Panels") {
                SettingsToggle(
                    title: "Tint panels with workspace color",
                    subtitle: "The pull tab, drawer, stage and pane headers take on a dark tint of the workspace's accent color. Off keeps them neutral gray.",
                    first: true,
                    isOn: $tintGlass)
            }
        }
    }
}

// MARK: - Editor

private struct EditorSettings: View {
    @AppStorage(GaiPreferenceKey.editorFontSize) private var fontSize = 13.0
    @AppStorage(GaiPreferenceKey.editorShowLineNumbers) private var lineNumbers = true
    @AppStorage(GaiPreferenceKey.editorWrapLines) private var wrap = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Code editor") {
                SettingsRow(title: "Font size", subtitle: "Monospaced font size in points.", first: true) {
                    HStack(spacing: 8) {
                        stepper("minus") { fontSize = max(9, fontSize - 1) }
                        Text("\(Int(fontSize))")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 18)
                        stepper("plus") { fontSize = min(24, fontSize + 1) }
                    }
                }
                SettingsToggle(title: "Show line numbers", isOn: $lineNumbers)
                SettingsToggle(title: "Wrap long lines", isOn: $wrap)
            }
        }
    }

    private func stepper(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Updates

private struct UpdatesSettings: View {
    @State private var autoCheck = false

    private var controller: UpdateController? {
        (NSApp.delegate as? AppDelegate)?.updateController
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Software updates") {
                SettingsToggle(
                    title: "Automatically check for updates",
                    subtitle: "Periodically check for new versions of GaiTerm in the background.",
                    first: true,
                    isOn: Binding(get: { autoCheck }, set: { setAuto($0) }))
                SettingsRow(title: "Check now", subtitle: "Look for an update right now.") {
                    Button("Check for Updates") { controller?.checkForUpdates() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(S.accent.opacity(0.85)))
                }
            }
        }
        .onAppear { autoCheck = controller?.updater.automaticallyChecksForUpdates ?? false }
    }

    private func setAuto(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        autoCheck = on
    }
}
