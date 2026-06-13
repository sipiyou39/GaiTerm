import AppKit
import SwiftUI

/// UserDefaults keys for GaiTerm's GUI settings. Shared between the settings
/// UI and the features that consume them (e.g. the workspaces drawer).
enum GaiPreferenceKey {
    /// Whether the workspaces drawer's glass is tinted with the selected
    /// workspace's accent color. Off by default: plain glass.
    static let tintGlassWithWorkspaceAccent = "GaiTintGlassWithWorkspaceAccent"
}

// MARK: - Window

/// Presents the settings window (App menu → Settings…). One window for the
/// app's lifetime, recentered on first open only.
final class GaiSettingsWindowController {
    static let shared = GaiSettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: host)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Views

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 460)
        .padding(.top, 4)
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(GaiPreferenceKey.tintGlassWithWorkspaceAccent)
    private var tintGlass = false

    var body: some View {
        Form {
            Section {
                Toggle("Tint drawer with workspace color", isOn: $tintGlass)
                Text("The floating workspaces drawer takes on a subtle tint " +
                     "of the selected workspace's accent color.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
