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
    /// Lets floating terminal owners suspend click-away dismissal while the
    /// native picker temporarily owns focus. Other call sites use the no-op.
    let onDialogVisibilityChanged: (Bool) -> Void

    init(
        path: String?,
        accent: Color,
        onPick: @escaping (String) -> Void,
        onDialogVisibilityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.path = path
        self.accent = accent
        self.onPick = onPick
        self.onDialogVisibilityChanged = onDialogVisibilityChanged
    }

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
        openPanel.message = "Choose this terminal's folder. Changing it restarts the terminal."

        onDialogVisibilityChanged(true)
        NSApp.activate(ignoringOtherApps: true)
        let restore = GaiFloatingPanels.lower()
        openPanel.begin { response in
            restore()
            // Hand a successful pick to the owner before releasing the picker
            // transient. If changing folders needs a confirmation sheet, the
            // owner can synchronously acquire its own transient first, leaving
            // no one-run-loop gap where click-away could hide the terminal.
            if response == .OK, let url = openPanel.url { onPick(url.path) }
            onDialogVisibilityChanged(false)
        }
    }
}

/// Temporarily drops our always-on-top panels (drawer/stage overlays) so a
/// native modal dialog appears in front, then restores their original levels.
enum GaiFloatingPanels {
    /// High enough to stay usable over another app's fullscreen Space.
    static let overlayLevel: NSWindow.Level = .screenSaver

    /// Lower every visible floating overlay window of this app; returns a
    /// closure that puts them all back.
    static func lower() -> () -> Void {
        let minimum = NSWindow.Level.statusBar.rawValue
        let affected = NSApp.windows.filter { $0.isVisible && $0.level.rawValue >= minimum }
        let saved = affected.map { ($0, $0.level) }
        affected.forEach { $0.level = .normal }
        return {
            // Restoring a parent's level propagates it to every child. Restore
            // roots first and descendants afterwards so companion terminals
            // recover their deliberately distinct z-levels.
            saved.sorted { windowDepth($0.0) < windowDepth($1.0) }
                .forEach { window, level in window.level = level }
        }
    }

    private static func windowDepth(_ window: NSWindow) -> Int {
        var depth = 0
        var parent = window.parent
        while let current = parent {
            depth += 1
            parent = current.parent
        }
        return depth
    }
}
#endif
