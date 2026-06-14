#if os(macOS)
import SwiftUI

/// One node of a workspace's file tree. `id` is the absolute path, so it's
/// stable across rescans (expanded folders & selection survive a refresh).
/// Children are NOT stored here — they're loaded lazily, one directory level at
/// a time, by the explorer view (browsing `~` must not scan the whole disk).
struct GaiFileNode: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let depth: Int
}

/// Lazy directory reader: lists one level at a time (so opening a folder is
/// cheap no matter how big the tree below it is) plus a bounded recursive
/// search. Skips noise (.git, build caches, junk), directories sort first.
enum GaiFileTreeScanner {
    /// Immediate children of a directory, sorted (dirs first, natural order).
    static func children(ofPath path: String, depth: Int) async -> [GaiFileNode] {
        await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants])) ?? []
            return sorted(entries).filter { !shouldSkip($0) }.map { child in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return GaiFileNode(
                    id: child.standardizedFileURL.path,
                    name: child.lastPathComponent,
                    path: child.path,
                    isDirectory: isDir,
                    depth: depth)
            }
        }.value
    }

    /// Recursively collect nodes whose name matches `query`, bounded so a search
    /// over a huge tree stays responsive.
    static func search(
        rootPath: String, query: String,
        limit: Int = 300, maxVisited: Int = 25_000
    ) async -> [GaiFileNode] {
        await Task.detached(priority: .userInitiated) {
            let needle = query.lowercased()
            guard !needle.isEmpty else { return [] }
            var results: [GaiFileNode] = []
            var visited = 0
            // DFS via an explicit stack so we never blow the call stack.
            var stack: [(URL, Int)] = [(URL(fileURLWithPath: rootPath), 0)]
            while let (url, depth) = stack.popLast() {
                if results.count >= limit || visited >= maxVisited { break }
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsSubdirectoryDescendants])) ?? []
                for child in entries where !shouldSkip(child) {
                    visited += 1
                    let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if child.lastPathComponent.lowercased().contains(needle) {
                        results.append(GaiFileNode(
                            id: child.standardizedFileURL.path,
                            name: child.lastPathComponent,
                            path: child.path,
                            isDirectory: isDir,
                            depth: depth + 1))
                        if results.count >= limit { break }
                    }
                    if isDir { stack.append((child, depth + 1)) }
                }
            }
            return results.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }.value
    }

    private static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { a, b in
            let ad = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let bd = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if ad != bd { return ad && !bd }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    private static func shouldSkip(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if excluded.contains(name) { return true }
        return name.hasSuffix(".xcuserstate") || name.hasSuffix(".swp") || name.hasSuffix(".tmp")
    }

    private static let excluded: Set<String> = [
        ".DS_Store", ".git", ".svn", ".hg", ".build", ".swiftpm",
        "node_modules", ".next", ".zig-cache", "zig-cache",
        ".venv", "__pycache__", ".idea", ".cache", "DerivedData",
    ]
}

/// SF-Symbol icon + a muted accent color per file type, tuned for the dark
/// `#1C1C1E` panel so the tree reads at a glance without shouting.
enum GaiFileIcon {
    static func symbol(for node: GaiFileNode) -> String {
        if node.isDirectory { return "folder" }
        switch ext(node.name) {
        case "swift": return "swift"
        case "json", "lock": return "curlybraces.square"
        case "md", "markdown", "txt", "rtf": return "doc.text"
        case "yml", "yaml", "toml", "ini", "cfg", "conf", "env": return "gearshape"
        case "js", "mjs", "cjs", "ts", "tsx", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "java", "kt", "zig": return "chevron.left.forwardslash.chevron.right"
        case "html", "htm", "xml", "svg": return "chevron.left.slash.chevron.right"
        case "css", "scss", "sass": return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "sql", "db", "sqlite": return "cylinder"
        case "sh", "bash", "zsh", "fish": return "terminal"
        case "zip", "tar", "gz", "dmg": return "shippingbox"
        case "plist": return "list.bullet.rectangle"
        default: return "doc"
        }
    }

    static func color(for node: GaiFileNode) -> Color {
        if node.isDirectory { return Color(red: 0.52, green: 0.60, blue: 0.72) }
        switch ext(node.name) {
        case "swift": return Color(red: 0.90, green: 0.56, blue: 0.40)
        case "json", "yml", "yaml", "toml", "lock", "ini", "cfg", "conf", "env": return Color(red: 0.83, green: 0.74, blue: 0.45)
        case "md", "markdown", "txt": return Color(red: 0.58, green: 0.67, blue: 0.62)
        case "js", "mjs", "cjs", "jsx": return Color(red: 0.86, green: 0.78, blue: 0.42)
        case "ts", "tsx": return Color(red: 0.45, green: 0.66, blue: 0.82)
        case "py": return Color(red: 0.50, green: 0.68, blue: 0.80)
        case "rs", "go", "c", "h", "cpp", "hpp", "zig": return Color(red: 0.74, green: 0.62, blue: 0.52)
        case "html", "htm", "xml", "svg": return Color(red: 0.80, green: 0.55, blue: 0.48)
        case "css", "scss", "sass": return Color(red: 0.55, green: 0.62, blue: 0.84)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "pdf": return Color(red: 0.71, green: 0.64, blue: 0.85)
        case "sql", "db", "sqlite": return Color(red: 0.58, green: 0.70, blue: 0.64)
        case "sh", "bash", "zsh", "fish": return Color(red: 0.60, green: 0.74, blue: 0.55)
        default: return Color(red: 0.52, green: 0.57, blue: 0.66)
        }
    }

    private static func ext(_ name: String) -> String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }
}
#endif
