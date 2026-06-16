#if os(macOS)
import AppKit
import SwiftUI

/// A compact folder chooser: a button showing a folder icon + the current
/// directory's name (`~` for home). Clicking opens the **native macOS folder
/// picker** (`NSOpenPanel`), brought in front of the floating drawer/stage so it
/// is always visible and usable. Reused in the workspace editor (folder per
/// terminal) and in the pane header.
struct GaiDirectoryPicker: View {
    /// Currently selected path; `nil` shows home (`~`).
    let path: String?
    let accent: Color
    /// Called with the absolute path the user picks.
    let onPick: (String) -> Void

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var resolved: String { path ?? Self.home }

    private var label: String {
        let p = resolved
        if p == Self.home { return "~" }
        return URL(fileURLWithPath: p).lastPathComponent
    }

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Open the native folder picker.
    ///
    /// Two things made the old approach freeze:
    ///   • `runModal()` blocks the main thread — the whole app (stage included)
    ///     can't process anything until it returns, which IS the freeze.
    ///   • The drawer is a *non-activating* panel, so clicking this button never
    ///     made the app active; an inactive app's dialog can't come forward, so it
    ///     stayed hidden behind our `.statusBar` panels.
    ///
    /// Fix: activate the app, drop our always-on-top panels below the dialog, and
    /// present it *modelessly* with `begin` (non-blocking) — the main thread keeps
    /// running, so nothing can lock up. The panels are restored when it closes.
    private func choose() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.directoryURL = URL(fileURLWithPath: resolved)
        openPanel.prompt = "Choose"
        openPanel.message = "Choose this workspace's folder"

        NSApp.activate(ignoringOtherApps: true)
        let restore = GaiFloatingPanels.lower()
        openPanel.begin { response in
            restore()
            if response == .OK, let url = openPanel.url { onPick(url.path) }
        }
    }
}

/// Temporarily drops our always-on-top panels (drawer/stage at `.statusBar`) so a
/// native modal dialog appears in front, then restores their original levels.
enum GaiFloatingPanels {
    /// Lower every visible `.statusBar`-level window of this app; returns a
    /// closure that puts them all back.
    static func lower() -> () -> Void {
        let affected = NSApp.windows.filter { $0.isVisible && $0.level == .statusBar }
        let saved = affected.map { ($0, $0.level) }
        affected.forEach { $0.level = .normal }
        return { saved.forEach { window, level in window.level = level } }
    }
}
#endif
