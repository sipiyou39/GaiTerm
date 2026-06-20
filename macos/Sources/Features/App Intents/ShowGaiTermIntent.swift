import AppKit
import AppIntents

struct ShowGaiTermIntent: AppIntent {
    static var title: LocalizedStringResource = "Show GaiTerm"
    static var description = IntentDescription("Show the GaiTerm stage and drawer.")

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .background
#endif

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TerminalEntity]> {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }

        guard let delegate = NSApp.delegate as? AppDelegate else {
            throw GhosttyIntentError.appUnavailable
        }

        delegate.gaiWorkspaceManager.reveal()
        let terminals = delegate.gaiWorkspaceManager.terminalSurfaces.map {
            TerminalEntity($0)
        }

        return .result(value: terminals)
    }
}
