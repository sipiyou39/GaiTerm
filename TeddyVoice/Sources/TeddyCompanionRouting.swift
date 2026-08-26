import Foundation
import SwiftUI

struct GrokTextToolDefinition: Equatable, Sendable {
    let name: String
    let description: String
    let parameters: Data
}

struct GrokTextToolCall: Equatable, Sendable {
    let name: String
    let arguments: Data
}

struct GrokTextToolResult: Equatable, Sendable {
    let output: String
}

/// A tool-owned request for a directory choice. The voice controller presents
/// it inline in the conversation and resumes the original tool call only after
/// the user chooses or cancels. No second terminal or hidden session is used.
struct TeddyDirectorySelectionRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let cli: String
    let initialDirectoryPath: String

    init(
        id: UUID = UUID(),
        cli: String,
        initialDirectoryPath: String
    ) {
        self.id = id
        self.cli = cli
        self.initialDirectoryPath = initialDirectoryPath
    }
}

typealias TeddyDirectorySelectionPresenter = @MainActor @Sendable (
    TeddyDirectorySelectionRequest
) async -> String?

struct TeddyDirectoryBrowserItem: Identifiable, Equatable, Sendable {
    let name: String
    let path: String

    var id: String { path }
}

struct TeddyDirectoryBrowserSnapshot: Equatable, Sendable {
    let path: String
    let folders: [TeddyDirectoryBrowserItem]
    let errorMessage: String?
}

/// Bounded, asynchronous folder discovery for the inline picker. Files and
/// hidden entries are deliberately omitted because this interaction only
/// selects a working directory.
enum TeddyDirectoryBrowser {
    static func parentPath(of path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path != "/" else { return nil }
        return url.deletingLastPathComponent().path
    }

    static func displayPath(
        _ path: String,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = URL(fileURLWithPath: homePath).standardizedFileURL.path
        if normalized == home { return "~" }
        if normalized.hasPrefix(home + "/") {
            return "~" + String(normalized.dropFirst(home.count))
        }
        return normalized
    }

    static func snapshot(at path: String) async -> TeddyDirectoryBrowserSnapshot {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let url = URL(fileURLWithPath: normalizedPath, isDirectory: true)
            do {
                let contents = try manager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                let folders = contents.compactMap { candidate -> TeddyDirectoryBrowserItem? in
                    guard let values = try? candidate.resourceValues(
                        forKeys: [.isDirectoryKey, .isHiddenKey]),
                        values.isDirectory == true,
                        values.isHidden != true
                    else { return nil }
                    return TeddyDirectoryBrowserItem(
                        name: candidate.lastPathComponent,
                        path: candidate.standardizedFileURL.path)
                }.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return TeddyDirectoryBrowserSnapshot(
                    path: normalizedPath,
                    folders: folders,
                    errorMessage: nil)
            } catch {
                return TeddyDirectoryBrowserSnapshot(
                    path: normalizedPath,
                    folders: [],
                    errorMessage: "Ce dossier n’est pas accessible.")
            }
        }.value
    }
}

/// One semantic lifecycle boundary emitted by a native doudou terminal. The
/// desktop bridge sends the already-captured response; Teddy never scrapes the
/// terminal itself and can therefore report completion without polling.
struct TeddyAgentCompletionReport: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case completed
        case awaitingInput
        case awaitingApproval
        case failed
    }

    let agentID: UUID
    let eventID: String
    let agentName: String
    let kind: Kind
    let response: String
}

/// Lightweight, UI-safe projection of one live doudou. The voice layer never
/// receives the terminal renderer or its scrollback through this value.
struct TeddyCompanionSnapshot: Identifiable, Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case idle
        case working
        case awaitingInput
        case awaitingApproval
        case completed
        case failed
        case exited

        var acceptsPrompt: Bool {
            switch self {
            case .idle, .awaitingInput, .awaitingApproval, .completed, .failed:
                true
            case .working, .exited:
                false
            }
        }
    }

    let id: UUID
    let name: String
    let provider: String
    let phase: Phase
    let directoryPath: String
    let hasPendingResponse: Bool

    var projectName: String {
        URL(fileURLWithPath: directoryPath).lastPathComponent
    }

    var isCLIReady: Bool {
        provider != "terminal" && phase != .exited
    }
}

/// Single gate shared by the composer and the actual push-to-talk action.
/// The cached sidebar projection keeps rendering cheap; the action boundary
/// replaces it with the router's synchronous source-of-truth. The native
/// router already preserves a previously proven CLI when macOS process
/// inspection is transiently unavailable; a `nil` router result therefore
/// means the companion no longer exists and must never authorize a stale PTT.
enum TeddyCompanionReadinessGate {
    static func revalidatedSnapshot(
        _ cachedSnapshot: TeddyCompanionSnapshot?,
        readFreshSnapshot: (UUID) -> TeddyCompanionSnapshot?
    ) -> TeddyCompanionSnapshot? {
        guard let cachedSnapshot else { return nil }
        return readFreshSnapshot(cachedSnapshot.id)
    }

    static func permitsPrompt(
        _ snapshot: TeddyCompanionSnapshot,
        hasPendingPrompt: Bool
    ) -> Bool {
        snapshot.isCLIReady
            && snapshot.phase.acceptsPrompt
            && !hasPendingPrompt
    }
}

enum TeddyCompanionControlFailure: String, Error, Equatable, Sendable {
    case unknownCompanion
    case emptyPrompt
    case promptTooLarge
    case unavailableTerminal
    case companionBusy
    case creationFailed
}

enum TeddyCompanionControlResult: Equatable, Sendable {
    case submitted
    case interrupted
    case failed(TeddyCompanionControlFailure)
}

/// Optional bridge supplied by the combined Teddy desktop application.
/// Standalone Teddy Voice keeps working without it.
@MainActor
protocol TeddyCompanionRouting: AnyObject {
    var toolDefinitions: [GrokTextToolDefinition] { get }
    func currentAgentContext() -> String
    func companionSnapshots() -> [TeddyCompanionSnapshot]
    /// Re-reads the selected terminal's live process state before an action
    /// whose safety depends on CLI availability. Unlike `companionSnapshots`,
    /// this method must consult the live source first, falling back to hook
    /// state only when the operating system cannot inspect that source.
    func freshCompanionSnapshot(for companionID: UUID) -> TeddyCompanionSnapshot?
    /// Mirrors Teddy's active conversation onto the desktop presentation.
    /// Selecting a representation must never create, focus or restart a PTY.
    func selectCompanion(_ companionID: UUID)
    func submitPrompt(_ text: String, to companionID: UUID) -> TeddyCompanionControlResult
    func interruptCompanion(_ companionID: UUID) -> TeddyCompanionControlResult
    func createCompanion(
        directoryPath: String,
        cli: String
    ) -> Result<TeddyCompanionSnapshot, TeddyCompanionControlFailure>
    func renameCompanion(_ companionID: UUID, to name: String)
    func changeCompanionDirectory(_ companionID: UUID, to path: String)
    /// Returns a type-erased SwiftUI host for the existing live Ghostty
    /// surface. Implementations must reuse the existing PTY, never create one.
    func makeInlineTerminalView(for companionID: UUID) -> AnyView?
    /// Returns the live doudou's visual identity for Teddy's internal UI.
    /// Implementations must reuse presentation state and create no new worker.
    func makeCompanionAvatarView(for companionID: UUID, width: CGFloat) -> AnyView?
    /// Returns the canonical doudou creator for presentation inside the main
    /// Teddy CLI window. This must never open a second application window.
    func makeCompanionCreationView() -> AnyView?
    func execute(
        _ call: GrokTextToolCall,
        selectDirectory: @escaping TeddyDirectorySelectionPresenter
    ) async throws -> GrokTextToolResult
}
