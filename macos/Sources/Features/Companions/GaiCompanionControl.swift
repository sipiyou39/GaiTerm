#if os(macOS)
import Foundation

extension Notification.Name {
    /// Posted only after an accepted lifecycle boundary produced a new bounded
    /// response. Observers receive the response under `responseUserInfoKey`.
    static let gaiCompanionLastResponseDidChange = Notification.Name(
        "com.sipiyou.gaiterm.companionLastResponseDidChange")
}

/// Small, stable projection exposed to Teddy. It contains no terminal view,
/// scrollback, renderer state or other heavyweight Ghostty object.
struct GaiManagedAgentSnapshot: Equatable, Sendable {
    let id: UUID
    let name: String
    let provider: GaiCompanionProvider?
    let phase: GaiCompanionPhase
    let directoryPath: String
    let launchCommand: String?
    let lastResponse: GaiCompanionLastResponse?
    /// True from local submission until that exact turn has yielded a captured
    /// answer. Teddy must never present an older cached response while this is
    /// true.
    let isResponsePending: Bool
}

enum GaiCompanionControl {
    /// Large enough for rich instructions and file paths, but bounded so a
    /// malformed tool call cannot paste an unbounded payload into a CLI.
    static let maximumPromptByteCount = 32_768
    static let responseUserInfoKey = "response"
}

enum GaiCompanionCreationCLI: String, CaseIterable, Sendable {
    case terminal
    case codex

    var launchCommand: String? {
        switch self {
        case .terminal: nil
        case .codex: "codex"
        }
    }
}

enum GaiCompanionControlFailure: Error, Equatable, Sendable {
    case unknownAgent
    case emptyPrompt
    case promptTooLarge
    case unavailableTerminal
    case agentBusy
}

enum GaiCompanionControlReceipt: Equatable, Sendable {
    case submitted(agentID: UUID)
    case interrupted(agentID: UUID)
    case failed(GaiCompanionControlFailure)
}
#endif
