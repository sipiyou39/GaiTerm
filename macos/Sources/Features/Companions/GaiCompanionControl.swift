#if os(macOS)
import Foundation

extension Notification.Name {
    /// Posted only after an accepted lifecycle boundary produced a new bounded
    /// response. Observers receive the response under `responseUserInfoKey`.
    static let gaiCompanionLastResponseDidChange = Notification.Name(
        "com.sipiyou.teddycli.companionLastResponseDidChange")
    /// Lightweight invalidation for consumers such as Teddy's sidebar. It
    /// carries no terminal text and is emitted only on semantic state changes.
    static let gaiCompanionStateDidChange = Notification.Name(
        "com.sipiyou.teddycli.companionStateDidChange")
    /// Requests Teddy to release an inline-hosted terminal before the same
    /// native surface is shown again in its floating doudou window.
    static let gaiCompanionInlineTerminalDidDetach = Notification.Name(
        "com.sipiyou.teddycli.companionInlineTerminalDidDetach")
    /// Emitted by the terminal's unified inline header when the user switches
    /// back to Teddy's vocal presentation. The surface is released by the
    /// voice controller's normal collapse lifecycle, never duplicated.
    static let gaiCompanionInlineTerminalRequestedVoice = Notification.Name(
        "com.sipiyou.teddycli.companionInlineTerminalRequestedVoice")
    /// The desktop mascot and Teddy's sidebar share one lightweight selection.
    static let gaiCompanionDesktopSelectionDidChange = Notification.Name(
        "com.sipiyou.teddycli.companionDesktopSelectionDidChange")
    /// Requests the full Teddy workspace for one doudou and one presentation.
    static let gaiCompanionOpenTeddyRequested = Notification.Name(
        "com.sipiyou.teddycli.companionOpenTeddyRequested")
    /// Requests replay of the latest archived Teddy answer for one doudou.
    static let gaiCompanionReplayVoiceRequested = Notification.Name(
        "com.sipiyou.teddycli.companionReplayVoiceRequested")
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
    static let companionIDUserInfoKey = "companionID"
    static let teddyPresentationUserInfoKey = "teddyPresentation"
}

enum GaiCompanionTeddyPresentation: String, Sendable {
    case vocal
    case terminal
}

enum GaiCompanionCreationCLI: String, CaseIterable, Sendable {
    case terminal
    case codex
    case claude
    case grok

    var launchCommand: String? {
        switch self {
        case .terminal: nil
        case .codex: "codex"
        case .claude: "claude"
        case .grok: "grok"
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
