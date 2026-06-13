#if os(macOS)
import AppKit
import Combine
import SwiftUI
import GhosttyKit

// MARK: - Attention

/// Attention state of a single terminal session. Drives the glanceable
/// indicators on workspace handles, session cards, and the Aperçu list.
///
/// The `rawValue` ascends with urgency so a workspace can aggregate its
/// sessions by taking the maximum.
enum GaiAttention: Int, Comparable, Codable {
    /// Sitting at a prompt, nothing notable.
    case idle = 0
    /// A command / agent is actively producing output.
    case running = 1
    /// A command finished (informational) — shown as a static dot.
    case finished = 2
    /// Waiting on the user (bell, or a CLI asking a question) — pulses.
    case needsInput = 3

    static func < (lhs: GaiAttention, rhs: GaiAttention) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether this state should pulse rather than show a static indicator.
    var pulses: Bool { self == .needsInput }
}

// MARK: - Session

/// A single terminal inside a workspace.
///
/// A session wraps a live Ghostty surface directly — there is no `NSWindow`.
/// Sessions are hosted inside the floating panel and reparented onto the Scène
/// when staged. The surface stays alive for the life of the session even when
/// off-stage; its rendering is paused via occlusion (see the performance pass).
final class GaiTerminalSession: ObservableObject, Identifiable {
    let id = UUID()

    /// Display name (auto-generated codename, user-editable).
    @Published var name: String

    /// The live terminal surface.
    let surfaceView: Ghostty.SurfaceView

    /// Current attention state, maintained by the attention engine.
    @Published var attention: GaiAttention = .idle

    /// Most recent moment this session was staged / interacted with, used for
    /// MRU ordering (filmstrip, Aperçu, auto-stage-on-exit).
    var lastActiveAt: Date

    init(name: String, surfaceView: Ghostty.SurfaceView) {
        self.name = name
        self.surfaceView = surfaceView
        self.lastActiveAt = Date()
    }

    /// Mark this session as just-used (bumps it to the front of MRU ordering).
    func touch() {
        lastActiveAt = Date()
    }
}

// MARK: - Workspace

/// A named workspace: a logical group of terminal sessions with a default
/// directory.
///
/// The default directory is only the *starting point* for new sessions — a
/// session is free to `cd` elsewhere and remains in this workspace. Creating a
/// workspace does not create a folder.
final class GaiWorkspace: ObservableObject, Identifiable {
    let id = UUID()

    /// Display name (e.g. "Mapbox", "proj-api").
    @Published var name: String

    /// Where new sessions in this workspace start. `nil` means the user's home.
    @Published var defaultDirectory: URL?

    /// Optional command auto-launched in new sessions (e.g. `claude`, `codex`),
    /// supporting the AI-CLI workflow. `nil` = a plain shell.
    @Published var defaultCommand: String?

    /// Ordered sessions in this workspace.
    @Published var sessions: [GaiTerminalSession] = []

    /// The workspace's terminal area: one Ghostty split tree. The Scène
    /// renders it with the native split machinery — ⌘D & friends split it,
    /// dividers resize it — exactly like a Ghostty window.
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init()

    init(name: String, defaultDirectory: URL? = nil, defaultCommand: String? = nil) {
        self.name = name
        self.defaultDirectory = defaultDirectory
        self.defaultCommand = defaultCommand
    }

    /// The session wrapping the given pane's surface, if any.
    func session(for view: Ghostty.SurfaceView) -> GaiTerminalSession? {
        sessions.first { $0.surfaceView === view }
    }

    /// Aggregate attention to show on the handle.
    ///
    /// The session currently on stage *and seen by the user* is excluded so we
    /// never nag about something already in front of them.
    func aggregateAttention(excluding viewedSessionID: GaiTerminalSession.ID?) -> GaiAttention {
        sessions
            .lazy
            .filter { $0.id != viewedSessionID }
            .map(\.attention)
            .max() ?? .idle
    }
}

extension SplitTree.Node {
    /// Number of terminal panes under this node.
    var gaiPaneCount: Int {
        switch self {
        case .leaf: return 1
        case .split(let split):
            return split.left.gaiPaneCount + split.right.gaiPaneCount
        }
    }
}

// MARK: - Store

/// Owns all workspaces and is the single source of truth for the floating
/// terminal system. Spawns sessions by creating Ghostty surfaces.
final class GaiWorkspaceStore: ObservableObject {
    /// All workspaces, in handle order (top → bottom on the edge).
    @Published var workspaces: [GaiWorkspace] = []

    /// The workspace whose Scène is currently open, if any. `nil` = at rest.
    @Published var openWorkspaceID: GaiWorkspace.ID?

    /// The Ghostty app used to spawn surfaces. Owned by the AppDelegate.
    private let ghostty: Ghostty.App

    /// Friendly auto-generated session names, cycled with a numeric suffix.
    private static let codenames = [
        "Gia", "Roan", "Max", "Beau", "Wynn", "Juno", "Levi", "Finn",
        "Mara", "Cleo", "Otis", "Nova", "Reed", "Sage", "Toby", "Vera",
    ]
    private var sessionCounter = 0

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
    }

    // MARK: Workspace lifecycle

    @discardableResult
    func createWorkspace(
        name: String,
        defaultDirectory: URL? = nil,
        defaultCommand: String? = nil
    ) -> GaiWorkspace {
        let workspace = GaiWorkspace(
            name: name,
            defaultDirectory: defaultDirectory,
            defaultCommand: defaultCommand)
        workspaces.append(workspace)
        return workspace
    }

    func removeWorkspace(_ id: GaiWorkspace.ID) {
        workspaces.removeAll { $0.id == id }
        if openWorkspaceID == id { openWorkspaceID = nil }
    }

    func workspace(for id: GaiWorkspace.ID?) -> GaiWorkspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    // MARK: Session bookkeeping

    /// Wrap a freshly created pane surface in a session, giving it its
    /// codename. The split controller calls this for every pane it creates.
    @discardableResult
    func attachSession(
        for view: Ghostty.SurfaceView,
        in workspace: GaiWorkspace
    ) -> GaiTerminalSession {
        let session = GaiTerminalSession(name: nextCodename(), surfaceView: view)
        workspace.sessions.append(session)
        return session
    }

    /// Drop the session bookkeeping for a closed pane.
    func detachSession(for view: Ghostty.SurfaceView, in workspace: GaiWorkspace) {
        workspace.sessions.removeAll { $0.surfaceView === view }
    }

    // MARK: Naming

    private func nextCodename() -> String {
        defer { sessionCounter += 1 }
        let pool = Self.codenames
        let base = pool[sessionCounter % pool.count]
        let cycle = sessionCounter / pool.count
        return cycle == 0 ? base : "\(base) \(cycle + 1)"
    }
}

// MARK: - Git info

/// Lightweight git lookup for the pane headers: resolves the current branch
/// (or worktree branch, or detached short-SHA) for a directory by reading
/// `.git/HEAD` directly — no subprocess.
enum GaiGitInfo {
    static func branch(atPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var dir = URL(fileURLWithPath: path)
        for _ in 0..<32 {
            let gitURL = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDir) {
                let headURL: URL?
                if isDir.boolValue {
                    headURL = gitURL.appendingPathComponent("HEAD")
                } else {
                    // A worktree: `.git` is a file containing "gitdir: <path>".
                    headURL = (try? String(contentsOf: gitURL, encoding: .utf8))
                        .flatMap { content -> URL? in
                            guard let raw = content.split(separator: ":", maxSplits: 1).last else {
                                return nil
                            }
                            let gitdir = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                            return URL(
                                fileURLWithPath: gitdir,
                                relativeTo: dir
                            ).appendingPathComponent("HEAD")
                        }
                }
                guard let headURL,
                      let head = (try? String(contentsOf: headURL, encoding: .utf8))?
                          .trimmingCharacters(in: .whitespacesAndNewlines)
                else { return nil }
                let refPrefix = "ref: refs/heads/"
                if head.hasPrefix(refPrefix) {
                    return String(head.dropFirst(refPrefix.count))
                }
                // Detached HEAD: show a short SHA.
                return String(head.prefix(7))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }
}
#endif
