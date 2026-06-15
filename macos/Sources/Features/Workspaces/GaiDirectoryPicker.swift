#if os(macOS)
import AppKit
import SwiftUI

/// A compact folder chooser: a button showing a folder icon + the current
/// directory's name (`~` for home). Clicking opens a small browser popover with
/// a search field, a parent-directory row, and the current folder's
/// subdirectories — navigate in, then pick. Reused in the workspace editor
/// (folder per terminal) and in the pane header.
struct GaiDirectoryPicker: View {
    /// Currently selected path; `nil` shows home (`~`).
    let path: String?
    let accent: Color
    /// Called with the absolute path the user picks.
    let onPick: (String) -> Void

    @State private var showing = false

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var resolved: String { path ?? Self.home }

    private var label: String {
        let p = resolved
        if p == Self.home { return "~" }
        return URL(fileURLWithPath: p).lastPathComponent
    }

    var body: some View {
        Button { showing = true } label: {
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
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            GaiDirectoryBrowser(start: resolved, accent: accent) { picked in
                onPick(picked)
                showing = false
            }
            .frame(width: 300, height: 340)
        }
    }
}

// MARK: - Browser

private struct GaiDirectoryBrowser: View {
    let start: String
    let accent: Color
    let onChoose: (String) -> Void

    @State private var current: String
    @State private var query = ""
    @State private var dirs: [GaiFileNode] = []
    @State private var results: [GaiFileNode] = []

    init(start: String, accent: Color, onChoose: @escaping (String) -> Void) {
        self.start = start
        self.accent = accent
        self.onChoose = onChoose
        _current = State(initialValue: start)
    }

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var displayPath: String {
        current == Self.home ? "~" : current.replacingOccurrences(
            of: Self.home, with: "~", range: current.range(of: Self.home))
    }
    private var canGoUp: Bool { current != "/" }

    var body: some View {
        VStack(spacing: 0) {
            currentBar
            Divider().overlay(Color.white.opacity(0.08))
            searchField
            Divider().overlay(Color.white.opacity(0.08))
            list
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .task(id: current) { await loadChildren() }
        .task(id: query) { await runSearch() }
    }

    /// Current folder + a button to choose it as-is.
    private var currentBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(accent)
            Text(displayPath)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            Button { onChoose(current) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text("Use")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(accent.opacity(0.9)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Use this folder")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            TextField("Search directories…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                if query.isEmpty {
                    if canGoUp {
                        browserRow(icon: "arrow.up", tint: .white.opacity(0.5),
                                   name: ".. (Parent Directory)", subtitle: nil) {
                            navigate(URL(fileURLWithPath: current).deletingLastPathComponent().path)
                        }
                    }
                    ForEach(dirs) { node in
                        browserRow(icon: "folder", tint: GaiFileIcon.color(for: node),
                                   name: node.name, subtitle: nil) { navigate(node.path) }
                    }
                    if dirs.isEmpty && !canGoUp {
                        emptyHint("No subfolders")
                    } else if dirs.isEmpty {
                        emptyHint("No subfolders here")
                    }
                } else {
                    ForEach(results) { node in
                        browserRow(icon: "folder", tint: GaiFileIcon.color(for: node),
                                   name: node.name,
                                   subtitle: shortParent(of: node.path)) { navigate(node.path) }
                    }
                    if results.isEmpty {
                        emptyHint("No match")
                    }
                }
            }
        }
    }

    private func browserRow(
        icon: String, tint: Color, name: String, subtitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: subtitle == nil ? 30 : 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(GaiBrowserRowStyle())
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    // MARK: Navigation / loading

    private func navigate(_ path: String) {
        query = ""
        current = path
    }

    private func loadChildren() async {
        let all = await GaiFileTreeScanner.children(ofPath: current, depth: 0)
        dirs = all.filter(\.isDirectory)
    }

    private func runSearch() async {
        let q = query
        guard !q.isEmpty else { results = []; return }
        // Light debounce: a newer keystroke cancels this task.
        try? await Task.sleep(nanoseconds: 180_000_000)
        if Task.isCancelled { return }
        let found = await GaiFileTreeScanner.search(rootPath: current, query: q)
        guard !Task.isCancelled else { return }
        results = found.filter(\.isDirectory)
    }

    private func shortParent(of path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent == Self.home ? "~" : parent.replacingOccurrences(
            of: Self.home, with: "~", range: parent.range(of: Self.home))
    }
}

/// Row hover/press feedback for the browser list.
private struct GaiBrowserRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.white.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)))
            .onHover { hovering = $0 }
    }
}
#endif
