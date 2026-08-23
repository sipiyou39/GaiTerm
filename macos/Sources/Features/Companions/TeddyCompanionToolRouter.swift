#if os(macOS)
import Foundation

/// JSON-safe custom function definition sent to xAI. Keeping the schema as
/// `Data` avoids leaking `[String: Any]` across concurrency boundaries.
struct TeddyCompanionToolDefinition: Equatable, Sendable {
    let name: String
    let description: String
    let parameters: Data
}

struct TeddyCompanionToolCall: Equatable, Sendable {
    let name: String
    let arguments: Data
}

struct TeddyCompanionToolResult: Equatable, Sendable {
    let output: String
    let didMutateTerminal: Bool
}

enum TeddyCompanionToolFailure: Error, Equatable, Sendable {
    case malformedArguments
    case unknownTool
}

enum GaiManagedAgentResolver {
    enum Result: Equatable {
        case found(GaiManagedAgentSnapshot)
        case ambiguous([GaiManagedAgentSnapshot])
        case notFound
    }

    static func resolve(
        _ reference: String,
        in agents: [GaiManagedAgentSnapshot]
    ) -> Result {
        let normalized = normalize(reference)
        guard !normalized.isEmpty else { return .notFound }

        if let id = UUID(uuidString: reference),
           let agent = agents.first(where: { $0.id == id }) {
            return .found(agent)
        }

        let exact = agents.filter { normalize($0.name) == normalized }
        if exact.count == 1, let agent = exact.first { return .found(agent) }
        if exact.count > 1 { return .ambiguous(exact) }

        let partial = agents.filter { normalize($0.name).contains(normalized) }
        if partial.count == 1, let agent = partial.first { return .found(agent) }
        if partial.count > 1 { return .ambiguous(partial) }
        return .notFound
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Executes only the tiny set of terminal-management operations Teddy owns.
/// It has no shell tool and no path for producing a technical answer itself.
@MainActor
final class TeddyCompanionToolRouter {
    static let maximumResponseCharactersInToolOutput = 12_000

    private weak var manager: GaiCompanionManager?

    init(manager: GaiCompanionManager) {
        self.manager = manager
    }

    static let definitions: [TeddyCompanionToolDefinition] = [
        definition(
            name: "list_agents",
            description: "Liste les doudous avec un nom humain, leur état terminal ou CLI et indique si une dernière réponse est disponible. Ne renvoie aucun identifiant technique.",
            properties: [:],
            required: []),
        definition(
            name: "create_agent",
            description: "Affiche un explorateur compact dans la conversation puis crée un doudou dans le dossier choisi. Démarre Codex par défaut ; utilise terminal seulement si l’utilisateur demande explicitement un shell vide.",
            properties: [
                "cli": enumProperty(
                    "Programme à ouvrir. Omettre pour créer le terminal vide par défaut.",
                    values: GaiCompanionCreationCLI.allCases.map(\.rawValue)),
            ],
            required: []),
        definition(
            name: "get_last_agent_response",
            description: "Lit la dernière réponse déjà terminée d’un doudou. Ne lit jamais sa sortie en continu.",
            properties: [
                "agent": stringProperty(
                    "Nom du doudou terminal."),
            ],
            required: ["agent"]),
        definition(
            name: "send_to_agent",
            description: "Envoie une consigne dans le CLI d’un doudou actif puis appuie sur Entrée. La consigne vient de Teddy.",
            properties: [
                "agent": stringProperty(
                    "Nom du doudou terminal."),
                "instruction": stringProperty(
                    "Consigne complète à transmettre au CLI sans l’altérer."),
            ],
            required: ["agent", "instruction"]),
        definition(
            name: "interrupt_agent",
            description: "Interrompt le travail courant d’un doudou actif avec Ctrl-C sans fermer son terminal.",
            properties: [
                "agent": stringProperty(
                    "Nom du doudou terminal."),
            ],
            required: ["agent"]),
    ]

    /// Small context attached to each Teddy turn. It contains no scrollback and
    /// is bounded independently from the response cache.
    func currentAgentContext() -> String {
        guard let manager else { return "Aucun gestionnaire de doudous disponible." }
        let agents = manager.managedAgentSnapshots()
        guard !agents.isEmpty else { return "Aucun doudou terminal n’existe." }
        return agents.map { agent in
            let provider = agent.provider.map(providerName) ?? "terminal"
            let mode = provider == "terminal" ? "terminal" : "CLI (\(provider))"
            let availability = agent.phase == .working || agent.phase == .exited
                ? "non"
                : "oui"
            let notification = agent.phase == .completedUnseen
                ? "réponse terminée non consultée"
                : "aucune"
            let latest = agent.lastResponse.map {
                "disponible, origine=\($0.origin.rawValue)"
            } ?? "aucune"
            return "- \(agent.name) | type=\(mode) "
                + "| état_exécution=\(executionState(agent.phase)) "
                + "| peut_recevoir_consigne=\(availability) "
                + "| notification=\(notification) | dernière réponse=\(latest)"
        }.joined(separator: "\n")
    }

    func execute(
        _ call: TeddyCompanionToolCall,
        selectDirectory: @escaping TeddyDirectorySelectionPresenter
    ) async throws -> TeddyCompanionToolResult {
        guard let object = try JSONSerialization.jsonObject(with: call.arguments)
                as? [String: Any] else {
            throw TeddyCompanionToolFailure.malformedArguments
        }

        switch call.name {
        case "list_agents":
            return TeddyCompanionToolResult(
                output: listAgentsOutput(),
                didMutateTerminal: false)
        case "create_agent":
            let cli: GaiCompanionCreationCLI
            if let rawCLI = normalizedString(object["cli"]) {
                guard let requestedCLI = GaiCompanionCreationCLI(rawValue: rawCLI)
                else { throw TeddyCompanionToolFailure.malformedArguments }
                cli = requestedCLI
            } else {
                cli = .codex
            }
            return await createAgentOutput(
                cli: cli,
                selectDirectory: selectDirectory)
        case "get_last_agent_response":
            guard let reference = normalizedString(object["agent"]) else {
                throw TeddyCompanionToolFailure.malformedArguments
            }
            return TeddyCompanionToolResult(
                output: lastResponseOutput(agentReference: reference),
                didMutateTerminal: false)
        case "send_to_agent":
            guard let reference = normalizedString(object["agent"]),
                  let instruction = normalizedString(object["instruction"])
            else { throw TeddyCompanionToolFailure.malformedArguments }
            return sendOutput(agentReference: reference, instruction: instruction)
        case "interrupt_agent":
            guard let reference = normalizedString(object["agent"]) else {
                throw TeddyCompanionToolFailure.malformedArguments
            }
            return interruptOutput(agentReference: reference)
        default:
            throw TeddyCompanionToolFailure.unknownTool
        }
    }

    private func listAgentsOutput() -> String {
        guard let manager else { return json(["error": "manager_unavailable"]) }
        let agents = manager.managedAgentSnapshots().map(agentPayload)
        return json(["agents": agents])
    }

    private func createAgentOutput(
        cli: GaiCompanionCreationCLI,
        selectDirectory: @escaping TeddyDirectorySelectionPresenter
    ) async -> TeddyCompanionToolResult {
        guard let manager else {
            return TeddyCompanionToolResult(
                output: json(["error": "manager_unavailable"]),
                didMutateTerminal: false)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let documents = home.appending(path: "Documents", directoryHint: .isDirectory)
        let initialDirectory = FileManager.default.fileExists(atPath: documents.path)
            ? documents
            : home
        guard let selectedPath = await selectDirectory(
            TeddyDirectorySelectionRequest(
                cli: cli.rawValue,
                initialDirectoryPath: initialDirectory.path))
        else {
            return TeddyCompanionToolResult(
                output: json(["ok": false, "cancelled": true]),
                didMutateTerminal: false)
        }
        let directory = URL(fileURLWithPath: selectedPath).standardizedFileURL
        guard let agent = manager.createCompanion(directoryURL: directory, cli: cli) else {
            return TeddyCompanionToolResult(
                output: json(["ok": false, "error": "creation_failed"]),
                didMutateTerminal: false)
        }
        return TeddyCompanionToolResult(
            output: json([
                "ok": true,
                "agent": agent.name,
                "type": cli.rawValue,
                "folder": directory.lastPathComponent,
            ]),
            didMutateTerminal: true)
    }

    private func lastResponseOutput(agentReference: String) -> String {
        guard let manager else { return json(["error": "manager_unavailable"]) }
        switch GaiManagedAgentResolver.resolve(
            agentReference,
            in: manager.managedAgentSnapshots()) {
        case .notFound:
            return json(["error": "agent_not_found", "agent": agentReference])
        case .ambiguous(let candidates):
            return json([
                "error": "agent_ambiguous",
                "candidates": candidates.map(\.name),
            ])
        case .found(let agent):
            if agent.isResponsePending {
                return json([
                    "agent": agent.name,
                    "status": agent.phase.rawValue,
                    "response": NSNull(),
                    "response_state": "pending_current_turn",
                ])
            }
            guard let response = agent.lastResponse else {
                return json([
                    "agent": agent.name,
                    "status": agent.phase.rawValue,
                    "response": NSNull(),
                ])
            }
            return json([
                "agent": agent.name,
                "status": agent.phase.rawValue,
                "origin": response.origin.rawValue,
                "response": bounded(
                    response.text,
                    maximum: Self.maximumResponseCharactersInToolOutput),
                "truncated": response.wasTruncated
                    || response.text.count > Self.maximumResponseCharactersInToolOutput,
            ])
        }
    }

    private func sendOutput(
        agentReference: String,
        instruction: String
    ) -> TeddyCompanionToolResult {
        guard let manager else {
            return TeddyCompanionToolResult(
                output: json(["error": "manager_unavailable"]),
                didMutateTerminal: false)
        }
        switch GaiManagedAgentResolver.resolve(
            agentReference,
            in: manager.managedAgentSnapshots()) {
        case .notFound:
            return TeddyCompanionToolResult(
                output: json(["error": "agent_not_found", "agent": agentReference]),
                didMutateTerminal: false)
        case .ambiguous(let candidates):
            return TeddyCompanionToolResult(
                output: json([
                    "error": "agent_ambiguous",
                    "candidates": candidates.map(\.name),
                ]),
                didMutateTerminal: false)
        case .found(let agent):
            let receipt = manager.submitPrompt(instruction, to: agent.id)
            return TeddyCompanionToolResult(
                output: controlOutput(receipt, agent: agent),
                didMutateTerminal: receipt == .submitted(agentID: agent.id))
        }
    }

    private func interruptOutput(agentReference: String) -> TeddyCompanionToolResult {
        guard let manager else {
            return TeddyCompanionToolResult(
                output: json(["error": "manager_unavailable"]),
                didMutateTerminal: false)
        }
        switch GaiManagedAgentResolver.resolve(
            agentReference,
            in: manager.managedAgentSnapshots()) {
        case .notFound:
            return TeddyCompanionToolResult(
                output: json(["error": "agent_not_found", "agent": agentReference]),
                didMutateTerminal: false)
        case .ambiguous(let candidates):
            return TeddyCompanionToolResult(
                output: json([
                    "error": "agent_ambiguous",
                    "candidates": candidates.map(\.name),
                ]),
                didMutateTerminal: false)
        case .found(let agent):
            let receipt = manager.interruptAgent(id: agent.id)
            return TeddyCompanionToolResult(
                output: controlOutput(receipt, agent: agent),
                didMutateTerminal: receipt == .interrupted(agentID: agent.id))
        }
    }

    private func agentPayload(_ agent: GaiManagedAgentSnapshot) -> [String: Any] {
        let provider = agent.provider.map(providerName) ?? "terminal"
        var payload: [String: Any] = [
            "name": agent.name,
            "type": provider == "terminal" ? "terminal" : "cli",
            "cli": provider == "terminal" ? NSNull() : provider,
            "status": agent.phase.rawValue,
            "can_receive_instruction": agent.phase != .working && agent.phase != .exited,
            "has_unseen_completion": agent.phase == .completedUnseen,
            "response_pending": agent.isResponsePending,
            "folder": URL(fileURLWithPath: agent.directoryPath).lastPathComponent,
        ]
        if let response = agent.lastResponse, !agent.isResponsePending {
            payload["has_last_response"] = true
            payload["last_response_origin"] = response.origin.rawValue
        } else {
            payload["has_last_response"] = false
        }
        return payload
    }

    private func executionState(_ phase: GaiCompanionPhase) -> String {
        switch phase {
        case .idle, .completedUnseen:
            "libre"
        case .working:
            "occupé"
        case .awaitingInput:
            "attend une réponse"
        case .awaitingApproval:
            "attend une autorisation"
        case .failed:
            "en erreur mais disponible"
        case .exited:
            "hors ligne"
        }
    }

    private func controlOutput(
        _ receipt: GaiCompanionControlReceipt,
        agent: GaiManagedAgentSnapshot
    ) -> String {
        switch receipt {
        case .submitted:
            return json(["ok": true, "agent": agent.name, "action": "submitted"])
        case .interrupted:
            return json(["ok": true, "agent": agent.name, "action": "interrupted"])
        case .failed(let failure):
            return json([
                "ok": false,
                "agent": agent.name,
                "error": String(describing: failure),
            ])
        }
    }

    private static func definition(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> TeddyCompanionToolDefinition {
        let schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        ]
        return TeddyCompanionToolDefinition(
            name: name,
            description: description,
            parameters: (try? JSONSerialization.data(withJSONObject: schema)) ?? Data())
    }

    private static func stringProperty(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func enumProperty(
        _ description: String,
        values: [String]
    ) -> [String: Any] {
        ["type": "string", "description": description, "enum": values]
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func providerName(_ provider: GaiCompanionProvider) -> String {
        switch provider {
        case .codex: "codex"
        case .claude: "claude"
        case .agy: "agy"
        case .opencode: "opencode"
        default: "terminal"
        }
    }

    private func bounded(_ value: String, maximum: Int) -> String {
        guard value.count > maximum else { return value }
        return String(value.suffix(maximum))
    }

    private func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8)
        else { return #"{"error":"serialization_failed"}"# }
        return value
    }
}
#endif
