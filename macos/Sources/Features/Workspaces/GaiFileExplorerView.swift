#if os(macOS)
import AppKit
import SwiftUI

/// A pending inline "new file / new folder" under a parent directory.
private struct GaiPendingCreate: Equatable {
    let parentPath: String
    let isDirectory: Bool
}

/// File-system operations for the explorer (create / rename / trash), with light
/// name validation. All synchronous and small.
enum GaiFileOps {
    @discardableResult
    static func create(in parentPath: String, name: String, isDirectory: Bool) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(trimmed) else { return nil }
        let url = URL(fileURLWithPath: parentPath).appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { return nil }
            }
            return url.path
        } catch { return nil }
    }

    @discardableResult
    static func rename(_ path: String, to name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(trimmed) else { return nil }
        let src = URL(fileURLWithPath: path)
        let dst = src.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard src.path != dst.path else { return path }
        guard !FileManager.default.fileExists(atPath: dst.path) else { return nil }
        do { try FileManager.default.moveItem(at: src, to: dst); return dst.path }
        catch { return nil }
    }

    static func trash(_ path: String) {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    private static func isValid(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }
}

/// The file explorer in the drawer's "File" tab. Lazily browses the selected
/// workspace's folder, in GaiTerm's dark flat-gray design.
struct GaiFileExplorerView: View {
    let rootPath: String?
    let accent: Color
    let onOpenFile: (GaiFileNode) -> Void

    @State private var root: GaiFileNode?
    @State private var childrenByID: [String: [GaiFileNode]] = [:]
    @State private var expandedIDs: Set<String> = []
    @State private var selectedID: String?
    @State private var copiedID: String?
    @State private var searchText = ""
    @State private var searchResults: [GaiFileNode] = []
    @State private var isLoading = false
    @State private var reloadToken = 0
    @State private var creating: GaiPendingCreate?
    @State private var renamingID: String?

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(rootPath ?? "none")#\(reloadToken)") { await loadRoot() }
        .task(id: trimmedSearch) { await runSearch() }
    }

    // MARK: Header / toolbar

    private var header: some View {
        // The button group sizes to its content and is centered by the
        // maxWidth frame — no Spacers (whose surrounding spacing was overflowing
        // the narrow card and spilling past its right edge).
        HStack(spacing: 6) {
            ExplorerToolButton(symbol: "doc.badge.plus", help: "New file") { beginCreate(isDirectory: false) }
            ExplorerToolButton(symbol: "folder.badge.plus", help: "New folder") { beginCreate(isDirectory: true) }
            ExplorerToolButton(symbol: "trash", help: "Move to Trash",
                               tint: Color(red: 1, green: 0.45, blue: 0.45)) { deleteSelected() }
            ExplorerToolButton(symbol: "rectangle.compress.vertical", help: "Collapse all") { collapseAll() }
            ExplorerToolButton(symbol: "arrow.clockwise", help: "Rescan") { reloadToken += 1 }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .padding(.horizontal, 8)
    }

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
        } else if let root, let top = childrenByID[root.id] {
            tree(root, top)
        } else {
            placeholder(loading: false, text: rootPath == nil ? "No folder" : "Empty folder")
        }
    }

    private func tree(_ root: GaiFileNode, _ top: [GaiFileNode]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                // New file/folder at the root.
                if let creating, creating.parentPath == root.path {
                    inlineEditor(depth: 1, isDirectory: creating.isDirectory) { name in
                        commitCreate(name, isDirectory: creating.isDirectory, in: root)
                    }
                }
                ForEach(top) { node in
                    row(node)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
    }

    // Recursive row tree. Returns AnyView because an opaque `some View` can't be
    // defined in terms of itself (the function calls itself for children).
    private func row(_ node: GaiFileNode) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 1) {
            if renamingID == node.id {
                inlineEditor(depth: node.depth, isDirectory: node.isDirectory, initial: node.name) { name in
                    commitRename(node, name)
                }
            } else {
                GaiFileRow(
                    node: node,
                    accent: accent,
                    isSelected: selectedID == node.id,
                    isExpanded: expandedIDs.contains(node.id),
                    isCopied: copiedID == node.id,
                    onPrimary: { node.isDirectory ? tapDirectory(node) : open(node) },
                    onReveal: { reveal(node) },
                    onCopyPath: { copyPath(node) },
                    menu: AnyView(rowMenu(node)))
            }
            if node.isDirectory, expandedIDs.contains(node.id) {
                if let creating, creating.parentPath == node.path {
                    inlineEditor(depth: node.depth + 1, isDirectory: creating.isDirectory) { name in
                        commitCreate(name, isDirectory: creating.isDirectory, in: node)
                    }
                }
                ForEach(childrenByID[node.id] ?? []) { child in
                    row(child)
                }
            }
        })
    }

    @ViewBuilder
    private func rowMenu(_ node: GaiFileNode) -> some View {
        if node.isDirectory {
            Button("New file") { beginCreate(isDirectory: false, in: node) }
            Button("New folder") { beginCreate(isDirectory: true, in: node) }
            Divider()
            Button(expandedIDs.contains(node.id) ? "Collapse" : "Expand") { toggle(node) }
        } else {
            Button("Open") { open(node) }
        }
        Button("Reveal in Finder") { reveal(node) }
        Divider()
        Button("Rename") { renamingID = node.id }
        Button("Copy path") { copyPath(node) }
        Divider()
        Button("Move to Trash", role: .destructive) { delete(node) }
    }

    private func inlineEditor(depth: Int, isDirectory: Bool, initial: String = "",
                             commit: @escaping (String) -> Void) -> some View {
        GaiInlineEditRow(
            depth: depth, isDirectory: isDirectory, initial: initial, accent: accent,
            onCommit: commit, onCancel: { creating = nil; renamingID = nil })
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

    /// Clicking a folder selects it (so New file/folder lands inside it) and
    /// toggles its expansion — like VS Code.
    private func tapDirectory(_ node: GaiFileNode) {
        selectedID = node.id
        toggle(node)
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
        childrenByID[node.id] = await GaiFileTreeScanner.children(ofPath: node.path, depth: node.depth + 1)
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

    private func delete(_ node: GaiFileNode) {
        GaiFileOps.trash(node.path)
        if selectedID == node.id { selectedID = nil }
        reloadParent(of: node)
    }

    /// Trash whatever is selected (toolbar trash button).
    private func deleteSelected() {
        guard let id = selectedID, let node = findNode(id) else { return }
        delete(node)
    }

    private func runSearch() async {
        guard !trimmedSearch.isEmpty, let rootPath else { searchResults = []; return }
        searchResults = await GaiFileTreeScanner.search(rootPath: rootPath, query: trimmedSearch)
    }

    // MARK: Create / rename

    /// Begin an inline new file/folder under `node` (or the selected dir, or root).
    private func beginCreate(isDirectory: Bool, in node: GaiFileNode? = nil) {
        let parent = node ?? selectedParentDirectory()
        guard let parent else { return }
        if parent.id != root?.id { expandedIDs.insert(parent.id) }
        renamingID = nil
        creating = GaiPendingCreate(parentPath: parent.path, isDirectory: isDirectory)
    }

    /// The directory a new item should land in: the selected node if it's a dir,
    /// else the selected file's parent, else the root.
    private func selectedParentDirectory() -> GaiFileNode? {
        if let id = selectedID, let node = findNode(id) {
            return node.isDirectory ? node : findNode(parentID(of: node)) ?? root
        }
        return root
    }

    private func commitCreate(_ name: String, isDirectory: Bool, in parent: GaiFileNode) {
        creating = nil
        guard !name.isEmpty,
              let newPath = GaiFileOps.create(in: parent.path, name: name, isDirectory: isDirectory)
        else { return }
        Task {
            await reloadChildren(of: parent)
            selectedID = newPath
        }
    }

    private func commitRename(_ node: GaiFileNode, _ name: String) {
        renamingID = nil
        guard !name.isEmpty, GaiFileOps.rename(node.path, to: name) != nil else { return }
        reloadParent(of: node)
    }

    private func reloadParent(of node: GaiFileNode) {
        if let pid = parentID(of: node), let parent = findNode(pid) {
            Task { await reloadChildren(of: parent) }
        } else if let root {
            Task { await reloadChildren(of: root) }
        }
    }

    private func reloadChildren(of node: GaiFileNode) async {
        childrenByID[node.id] = await GaiFileTreeScanner.children(ofPath: node.path, depth: node.depth + 1)
    }

    // MARK: Tree lookups

    private func findNode(_ id: String?) -> GaiFileNode? {
        guard let id else { return nil }
        if root?.id == id { return root }
        for kids in childrenByID.values {
            if let n = kids.first(where: { $0.id == id }) { return n }
        }
        return nil
    }

    private func parentID(of node: GaiFileNode) -> String? {
        URL(fileURLWithPath: node.path).deletingLastPathComponent().standardizedFileURL.path
    }
}

// MARK: - Toolbar button

private struct ExplorerToolButton: View {
    let symbol: String
    let help: String
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering ? 0.95 : 0.7))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.10 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Tree row

private struct GaiFileRow: View {
    let node: GaiFileNode
    let accent: Color
    let isSelected: Bool
    let isExpanded: Bool
    let isCopied: Bool
    let onPrimary: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let menu: AnyView

    @State private var hovering = false
    private var showsActions: Bool { hovering || isCopied }

    var body: some View {
        HStack(spacing: 3) {
            Color.clear.frame(width: CGFloat(node.depth - 1) * 12)

            // Primary tap target: chevron + icon + name (one Button, so the
            // action buttons beside it stay independently clickable).
            Button(action: onPrimary) {
                HStack(spacing: 3) {
                    if node.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(isSelected || hovering ? 0.7 : 0.4))
                            .frame(width: 14)
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 1) {
                action(isCopied ? "checkmark" : "doc.on.doc",
                       isCopied ? Color(red: 0.45, green: 0.8, blue: 0.5) : .white.opacity(0.45),
                       "Copy path", onCopyPath)
                action("arrow.up.forward", .white.opacity(0.45), "Reveal in Finder", onReveal)
            }
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .padding(.trailing, 4)
        }
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.white.opacity(0.10)
                : hovering ? Color.white.opacity(0.045) : Color.clear))
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(accent).frame(width: 2, height: 15)
                    .padding(.leading, max(0, CGFloat(node.depth - 1) * 12))
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: showsActions)
        .contextMenu { menu }
    }

    private func action(_ symbol: String, _ color: Color, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Inline new-file / rename editor

private struct GaiInlineEditRow: View {
    let depth: Int
    let isDirectory: Bool
    let initial: String
    let accent: Color
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 3) {
            Color.clear.frame(width: CGFloat(depth - 1) * 12 + 14)
            Image(systemName: isDirectory ? "folder" : "doc")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16)
            TextField(isDirectory ? "folder name" : "file name", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.3))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit { onCommit(text) }
                .onExitCommand { onCancel() }
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(accent.opacity(0.5), lineWidth: 1)))
        .onAppear { text = initial; DispatchQueue.main.async { focused = true } }
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
        Button(action: onTap) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.white.opacity(0.10)
                : hovering ? Color.white.opacity(0.045) : Color.clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder", action: onReveal)
            Button("Copy path", action: onCopyPath)
        }
    }
}
#endif
