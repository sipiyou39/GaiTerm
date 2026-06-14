#if os(macOS)
import AppKit
import SwiftUI

/// The file explorer that lives in the drawer's "File" tab. Browses the
/// selected workspace's folder as a lazily-loaded tree — adapted to GaiTerm's
/// dark, flat-gray design language: workspace-accent selection, rounded fields,
/// muted type icons, sized for the narrow drawer.
struct GaiFileExplorerView: View {
    /// Root folder to browse — the selected workspace's directory.
    let rootPath: String?
    /// The workspace accent, used for the selection marker.
    let accent: Color
    /// Open a file (wired to the in-stage code editor).
    let onOpenFile: (GaiFileNode) -> Void

    @State private var root: GaiFileNode?
    @State private var childrenByID: [String: [GaiFileNode]] = [:]
    @State private var loadingIDs: Set<String> = []
    @State private var expandedIDs: Set<String> = []
    @State private var selectedID: String?
    @State private var copiedID: String?
    @State private var searchText = ""
    @State private var searchResults: [GaiFileNode] = []
    @State private var isLoading = false
    @State private var reloadToken = 0

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 6)
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(rootPath ?? "none")#\(reloadToken)") { await loadRoot() }
        .task(id: trimmedSearch) { await runSearch() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent.opacity(0.85))
            Text(rootName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            iconButton("rectangle.compress.vertical", "Collapse all") { collapseAll() }
            iconButton("arrow.clockwise", "Rescan") { reloadToken += 1 }
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            TextField("Search files", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.06)))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !trimmedSearch.isEmpty {
            searchList
        } else if isLoading && root == nil {
            placeholder(loading: true, text: "Scanning…")
        } else if let root, let top = childrenByID[root.id], !top.isEmpty {
            tree(top)
        } else if root != nil {
            placeholder(loading: false, text: "Empty folder")
        } else {
            placeholder(loading: false, text: rootPath == nil ? "No folder" : "Empty folder")
        }
    }

    private func tree(_ top: [GaiFileNode]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(top) { node in
                    GaiFileRow(
                        node: node,
                        accent: accent,
                        selectedID: selectedID,
                        copiedID: copiedID,
                        loadingIDs: loadingIDs,
                        childrenByID: childrenByID,
                        expandedIDs: $expandedIDs,
                        onSelectFile: open,
                        onToggle: toggle,
                        onReveal: reveal,
                        onCopyPath: copyPath)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
    }

    private var searchList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(searchResults) { node in
                    GaiSearchResultRow(
                        node: node,
                        isSelected: selectedID == node.id,
                        rootPath: root?.path ?? rootPath ?? "",
                        onTap: { if !node.isDirectory { open(node) } },
                        onReveal: { reveal(node) },
                        onCopyPath: { copyPath(node) })
                }
                if searchResults.isEmpty {
                    Text("No matches")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
    }

    private func placeholder(loading: Bool, text: String) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.16))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let root, let top = childrenByID[root.id] {
                let folders = top.filter { $0.isDirectory }.count
                Label("\(folders)", systemImage: "folder")
                Label("\(top.count - folders)", systemImage: "doc")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.white.opacity(0.32))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }

    // MARK: Data & actions

    private var rootName: String {
        rootPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
    }

    private func loadRoot() async {
        guard let rootPath else { root = nil; childrenByID = [:]; return }
        isLoading = true
        let id = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let node = GaiFileNode(id: id, name: rootName, path: rootPath, isDirectory: true, depth: 0)
        let kids = await GaiFileTreeScanner.children(ofPath: rootPath, depth: 1)
        root = node
        childrenByID = [id: kids]
        expandedIDs = [id]
        isLoading = false
    }

    private func toggle(_ node: GaiFileNode) {
        if expandedIDs.contains(node.id) {
            expandedIDs.remove(node.id)
        } else {
            expandedIDs.insert(node.id)
            if childrenByID[node.id] == nil { Task { await loadChildren(node) } }
        }
    }

    private func loadChildren(_ node: GaiFileNode) async {
        loadingIDs.insert(node.id)
        let kids = await GaiFileTreeScanner.children(ofPath: node.path, depth: node.depth + 1)
        childrenByID[node.id] = kids
        loadingIDs.remove(node.id)
    }

    private func open(_ node: GaiFileNode) {
        selectedID = node.id
        onOpenFile(node)
    }

    private func collapseAll() {
        expandedIDs = root.map { [$0.id] } ?? []
    }

    private func reveal(_ node: GaiFileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    private func copyPath(_ node: GaiFileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
        copiedID = node.id
        let id = node.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == id { copiedID = nil }
        }
    }

    private func runSearch() async {
        guard !trimmedSearch.isEmpty, let rootPath else { searchResults = []; return }
        searchResults = await GaiFileTreeScanner.search(rootPath: rootPath, query: trimmedSearch)
    }
}

// MARK: - Tree row

private struct GaiFileRow: View {
    let node: GaiFileNode
    let accent: Color
    let selectedID: String?
    let copiedID: String?
    let loadingIDs: Set<String>
    let childrenByID: [String: [GaiFileNode]]
    @Binding var expandedIDs: Set<String>
    let onSelectFile: (GaiFileNode) -> Void
    let onToggle: (GaiFileNode) -> Void
    let onReveal: (GaiFileNode) -> Void
    let onCopyPath: (GaiFileNode) -> Void

    @State private var hovering = false

    private var isExpanded: Bool { expandedIDs.contains(node.id) }
    private var isSelected: Bool { selectedID == node.id }
    private var isCopied: Bool { copiedID == node.id }
    private var showsActions: Bool { hovering || isCopied }
    private var children: [GaiFileNode] { childrenByID[node.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if node.isDirectory && isExpanded {
                ForEach(children) { child in
                    GaiFileRow(
                        node: child, accent: accent,
                        selectedID: selectedID, copiedID: copiedID,
                        loadingIDs: loadingIDs, childrenByID: childrenByID,
                        expandedIDs: $expandedIDs,
                        onSelectFile: onSelectFile, onToggle: onToggle,
                        onReveal: onReveal, onCopyPath: onCopyPath)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 3) {
            Color.clear.frame(width: CGFloat(node.depth - 1) * 12)

            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(isSelected || hovering ? 0.7 : 0.4))
                    .frame(width: 14, height: 24)
            } else {
                Color.clear.frame(width: 14)
            }

            Image(systemName: GaiFileIcon.symbol(for: node))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(GaiFileIcon.color(for: node))
                .frame(width: 16)

            Text(node.name)
                .font(.system(size: 12.3, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.74))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            HStack(spacing: 1) {
                rowAction(isCopied ? "checkmark" : "doc.on.doc", isCopied ? Color(red: 0.45, green: 0.8, blue: 0.5) : .white.opacity(0.45)) { onCopyPath(node) }
                rowAction("arrow.up.forward", .white.opacity(0.45)) { onReveal(node) }
            }
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .padding(.trailing, 4)
        }
        .frame(height: 24)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(accent)
                    .frame(width: 2, height: 15)
                    .padding(.leading, max(0, CGFloat(node.depth - 1) * 12))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { node.isDirectory ? onToggle(node) : onSelectFile(node) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: showsActions)
        .contextMenu { rowMenu }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if node.isDirectory {
            Button(isExpanded ? "Collapse" : "Expand") { onToggle(node) }
        } else {
            Button("Open") { onSelectFile(node) }
        }
        Button("Reveal in Finder") { onReveal(node) }
        Divider()
        Button("Copy path") { onCopyPath(node) }
    }

    private func rowAction(_ symbol: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.white.opacity(0.10)
                : hovering ? Color.white.opacity(0.045) : Color.clear)
    }
}

// MARK: - Search result row

private struct GaiSearchResultRow: View {
    let node: GaiFileNode
    let isSelected: Bool
    let rootPath: String
    let onTap: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void

    @State private var hovering = false

    private var relativeDir: String {
        let dir = URL(fileURLWithPath: node.path).deletingLastPathComponent().path
        if dir == rootPath { return "" }
        if dir.hasPrefix(rootPath + "/") { return String(dir.dropFirst(rootPath.count + 1)) }
        return dir
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: GaiFileIcon.symbol(for: node))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(GaiFileIcon.color(for: node))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.name)
                    .font(.system(size: 12.3, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.78))
                    .lineLimit(1)
                if !relativeDir.isEmpty {
                    Text(relativeDir)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: relativeDir.isEmpty ? 26 : 32)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.white.opacity(0.10)
                : hovering ? Color.white.opacity(0.045) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder", action: onReveal)
            Button("Copy path", action: onCopyPath)
        }
    }
}
#endif
