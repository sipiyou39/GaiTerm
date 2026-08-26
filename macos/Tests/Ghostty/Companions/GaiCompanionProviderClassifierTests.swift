#if DEBUG
import Foundation
import Testing
@testable import TeddyCLI

struct GaiCompanionProviderClassifierTests {
    @Test func companionCreationUsesOfficialProviderExecutables() {
        #expect(GaiCompanionCreationCLI.terminal.launchCommand == nil)
        #expect(GaiCompanionCreationCLI.codex.launchCommand == "codex")
        #expect(GaiCompanionCreationCLI.claude.launchCommand == "claude")
        #expect(GaiCompanionCreationCLI.grok.launchCommand == "grok")
    }

    @Test func parsesBoundedKernProcargsPayload() {
        let arguments = ["node", "/Users/me/.npm-global/bin/codex", "--full-auto"]
        let payload = makeProcessArgumentsPayload(
            executablePath: "/opt/homebrew/bin/node",
            arguments: arguments)

        #expect(GaiCompanionProcessArguments.parse(payload) == arguments)
        #expect(GaiCompanionProviderClassifier.classify(
            argv: GaiCompanionProcessArguments.parse(payload)) == .codex)
    }

    @Test func rejectsMalformedKernProcargsPayload() {
        #expect(GaiCompanionProcessArguments.parse([UInt8]()) == [])

        var impossibleCount = [UInt8](repeating: 0, count: MemoryLayout<Int32>.size + 8)
        withUnsafeBytes(of: Int32.max) { countBytes in
            impossibleCount.replaceSubrange(0..<countBytes.count, with: countBytes)
        }
        #expect(GaiCompanionProcessArguments.parse(impossibleCount) == [])

        let truncated = makeProcessArgumentsPayload(
            executablePath: "/usr/local/bin/claude",
            arguments: ["claude"])
            .dropLast()
        #expect(GaiCompanionProcessArguments.parse(Array(truncated)) == [])
    }

    @Test func detectsDirectExecutablesAndInstalledNodeShims() {
        #expect(GaiCompanionProviderClassifier.classify(argv: ["codex"]) == .codex)
        #expect(GaiCompanionProviderClassifier.classify(
            argv: ["node", "/Users/me/.npm-global/bin/codex"]) == .codex)
        #expect(GaiCompanionProviderClassifier.classify(
            argv: ["/opt/homebrew/bin/claude", "--resume"]) == .claude)
        #expect(GaiCompanionProviderClassifier.classify(argv: ["grok"]) == .grok)
        #expect(GaiCompanionProviderClassifier.classify(
            argv: ["/Users/me/.grok/bin/xai-grok-pager"]) == .grok)
        #expect(GaiCompanionProviderClassifier.classify(argv: ["agy"]) == .agy)
        #expect(GaiCompanionProviderClassifier.classify(
            argv: ["/usr/local/bin/opencode"]) == .opencode)
    }

    @Test func detectsExactPackageRunnerInvocations() {
        #expect(GaiCompanionProviderClassifier.classify(
            launchCommand: "npx --yes @openai/codex") == .codex)
        #expect(GaiCompanionProviderClassifier.classify(
            launchCommand: "npm exec @anthropic-ai/claude-code") == .claude)
        #expect(GaiCompanionProviderClassifier.classify(
            launchCommand: "npx --yes @xai-official/grok") == .grok)
        #expect(GaiCompanionProviderClassifier.classify(
            launchCommand: "pnpm dlx opencode-ai") == .opencode)
        #expect(GaiCompanionProviderClassifier.classify(
            launchCommand: "env NODE_NO_WARNINGS=1 codex --full-auto") == .codex)
    }

    @Test func distinguishesIdleCodexTUIStartupFromImmediateWork() {
        let idleInvocations = [
            ["codex"],
            ["codex", "--model", "gpt-5.6-terra", "--yolo"],
            ["codex", "--cd=/tmp", "--no-alt-screen"],
            ["node", "/Users/me/.npm-global/bin/codex", "--full-auto"],
            ["npx", "--yes", "@openai/codex"],
            ["codex", "resume"],
            ["codex", "resume", "session-id"],
            ["codex", "resume", "--last"],
            ["codex", "fork", "--all"],
        ]
        for arguments in idleInvocations {
            #expect(GaiCompanionProviderClassifier.isProvenIdleInteractiveLaunch(
                provider: .codex,
                argv: arguments))
        }

        let workingInvocations = [
            ["codex", "corrige ce bug"],
            ["codex", "--", "corrige ce bug"],
            ["codex", "exec", "corrige ce bug"],
            ["codex", "e", "corrige ce bug"],
            ["codex", "review", "--uncommitted"],
            ["codex", "resume", "session-id", "continue"],
            ["codex", "resume", "--last", "continue"],
            ["codex", "--unknown-startup-option"],
        ]
        for arguments in workingInvocations {
            #expect(!GaiCompanionProviderClassifier.isProvenIdleInteractiveLaunch(
                provider: .codex,
                argv: arguments))
        }
    }

    @Test func idleLaunchProofIsProviderExactAndConservativeForOtherCLIs() {
        #expect(GaiCompanionProviderClassifier.isProvenIdleInteractiveLaunch(
            provider: .claude,
            argv: ["claude"]))
        #expect(GaiCompanionProviderClassifier.isProvenIdleInteractiveLaunch(
            provider: .grok,
            argv: ["grok"]))
        #expect(!GaiCompanionProviderClassifier.isProvenIdleInteractiveLaunch(
            provider: .claude,
            argv: ["claude", "--resume"]))
        #expect(!GaiCompanionProviderClassifier.isProvenIdleInteractiveLaunch(
            provider: .grok,
            argv: ["grok", "build this"]))
        #expect(!GaiCompanionProviderClassifier.isProvenIdleInteractiveLaunch(
            provider: .claude,
            argv: ["codex"]))
    }

    @Test func argumentsTakePrecedenceOverWeakerSignals() {
        let provider = GaiCompanionProviderClassifier.classify(
            launchCommand: "claude",
            terminalTitle: "Claude Code",
            argv: ["/usr/local/bin/opencode"])

        #expect(provider == .opencode)
    }

    @Test func acceptsOnlyUnambiguousTerminalTitles() {
        #expect(GaiCompanionProviderClassifier.classify(
            terminalTitle: "Codex — GaiTerm") == .codex)
        #expect(GaiCompanionProviderClassifier.classify(
            terminalTitle: "Claude Code: project") == .claude)
        #expect(GaiCompanionProviderClassifier.classify(
            terminalTitle: "Grok Build — project") == .grok)
        #expect(GaiCompanionProviderClassifier.classify(
            terminalTitle: "OpenCode") == .opencode)
        #expect(GaiCompanionProviderClassifier.classify(
            terminalTitle: "Agy · workspace") == .agy)
    }

    @Test func rejectsIncidentalWordsInArgumentsCommandsAndTitles() {
        #expect(GaiCompanionProviderClassifier.classify(
            argv: ["zsh", "-c", "echo codex"]) == nil)
        #expect(GaiCompanionProviderClassifier.classify(
            argv: ["node", "script.js", "codex"]) == nil)
        #expect(GaiCompanionProviderClassifier.classify(
            launchCommand: "echo codex") == nil)
        #expect(GaiCompanionProviderClassifier.classify(
            launchCommand: "printf hello && codex") == nil)
        #expect(GaiCompanionProviderClassifier.classify(
            terminalTitle: "notes about codex") == nil)
        #expect(GaiCompanionProviderClassifier.classify(
            terminalTitle: "codexical project") == nil)
        #expect(GaiCompanionProviderClassifier.classify(
            terminalTitle: "Claude is installed") == nil)
    }

    @Test func launchCommandLexerHonorsQuotesAndEscapes() {
        #expect(GaiCompanionProviderClassifier.classify(
            launchCommand: "'/opt/local/bin/claude' --resume") == .claude)
        #expect(GaiCompanionProviderClassifier.classify(
            launchCommand: "/opt/my\\ tools/opencode") == .opencode)
    }

    private func makeProcessArgumentsPayload(
        executablePath: String,
        arguments: [String]
    ) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
        bytes.append(contentsOf: executablePath.utf8)
        bytes.append(0)
        bytes.append(0)
        for argument in arguments {
            bytes.append(contentsOf: argument.utf8)
            bytes.append(0)
        }
        return bytes
    }
}

struct GaiAgentHookInstallerTests {
    @Test func integrationRequiresEveryHookAndExplicitRepairRestoresPartialSets() throws {
        try expectRepairOfPartialIntegration(
            provider: .codex,
            installed: GaiAgentHookInstaller.codexHooksConfigurationForTesting([:]),
            removedCommandMarker: "gaiterm-codex-stop-notify",
            repair: GaiAgentHookInstaller.codexHooksConfigurationForTesting)
        try expectRepairOfPartialIntegration(
            provider: .claude,
            installed: GaiAgentHookInstaller.claudeHooksConfigurationForTesting([:]),
            removedCommandMarker: "gaiterm-claude-stop-notify",
            repair: GaiAgentHookInstaller.claudeHooksConfigurationForTesting)
        try expectRepairOfPartialIntegration(
            provider: .grok,
            installed: GaiAgentHookInstaller.grokHooksConfigurationForTesting([:]),
            removedCommandMarker: "gaiterm-agent-event-v1-grok-ready",
            repair: GaiAgentHookInstaller.grokHooksConfigurationForTesting)
    }

    @Test func codexHooksAreIdempotentAndNeverForgeInternalTrustState() throws {
        let existing: [String: Any] = [
            "description": "user hooks",
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": "user-stop-hook",
                    ]],
                ]],
            ],
        ]

        let installed = try GaiAgentHookInstaller
            .codexHooksConfigurationForTesting(existing)
        let reinstalled = try GaiAgentHookInstaller
            .codexHooksConfigurationForTesting(installed)

        #expect(try canonicalJSON(installed) == canonicalJSON(reinstalled))
        #expect(installed["description"] as? String == "user hooks")

        let hooks = try #require(installed["hooks"] as? [String: Any])
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        let stopCommands = hookCommands(in: stopGroups)
        #expect(stopCommands.contains("user-stop-hook"))
        #expect(stopCommands.filter {
            $0.contains("gaiterm-agent-event-v1-codex-stop")
        }.count == 1)
        #expect(stopCommands.filter {
            $0.contains("gaiterm-codex-stop-notify")
        }.count == 1)

        let serializedData = try canonicalJSON(installed)
        let serialized = try #require(String(data: serializedData, encoding: .utf8))
        #expect(!serialized.contains("trusted_hash"))
        #expect(!serialized.contains("hooks.state"))
    }

    @Test func generatedProviderHookCommandsAreShellSafe() throws {
        let configurations = try [
            GaiAgentHookInstaller.codexHooksConfigurationForTesting([:]),
            GaiAgentHookInstaller.claudeHooksConfigurationForTesting([:]),
            GaiAgentHookInstaller.grokHooksConfigurationForTesting([:]),
        ]

        for configuration in configurations {
            let hooks = try #require(configuration["hooks"] as? [String: Any])
            let commands = hooks.values.flatMap { value in
                hookCommands(in: value as? [[String: Any]] ?? [])
            }
            #expect(!commands.isEmpty)
            for command in commands {
                let result = try executeHookCommand(
                    command,
                    payload: #"{"session_id":"session-1","turn_id":"turn-1","promptId":"prompt-1","reason":"end_turn","last_assistant_message":"Terminé","lastAssistantMessage":"Terminé"}"#)
                #expect(result.status == 0)
            }
        }
    }

    @Test func generatedProviderHooksUseOneSubsecondSocketAttempt() throws {
        let configurations = try [
            GaiAgentHookInstaller.codexHooksConfigurationForTesting([:]),
            GaiAgentHookInstaller.claudeHooksConfigurationForTesting([:]),
            GaiAgentHookInstaller.grokHooksConfigurationForTesting([:]),
        ]

        for configuration in configurations {
            let hooks = try #require(configuration["hooks"] as? [String: Any])
            let commands = hooks.values.flatMap { value in
                hookCommands(in: value as? [[String: Any]] ?? [])
            }.filter { $0.contains("gaiterm-agent-event-v1-") }
            #expect(!commands.isEmpty)
            for command in commands {
                #expect(command.components(separatedBy: "/usr/bin/nc -U").count == 2)
                #expect(command.contains("/bin/sleep 0.2"))
                #expect(command.contains("/usr/bin/nc -U -w 1"))
                #expect(!command.contains("/usr/bin/nc -U -w 2"))
            }
        }
    }

    @Test func claudeGlobalHooksPreserveUserConfigurationAndAreIdempotent() throws {
        let existing: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "Stop": [[
                    "matcher": "",
                    "hooks": [[
                        "type": "command",
                        "command": "user-stop-hook",
                    ]],
                ]],
            ],
        ]

        #expect(
            GaiAgentHookInstaller.claudeGlobalSettingsFilenameForTesting
                == "settings.json")
        let installed = try GaiAgentHookInstaller
            .claudeHooksConfigurationForTesting(existing)
        let reinstalled = try GaiAgentHookInstaller
            .claudeHooksConfigurationForTesting(installed)

        #expect(try canonicalJSON(installed) == canonicalJSON(reinstalled))
        #expect(installed["theme"] as? String == "dark")

        let hooks = try #require(installed["hooks"] as? [String: Any])
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        let stopCommands = stopGroups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap {
                $0["command"] as? String
            }
        }
        #expect(stopCommands.contains("user-stop-hook"))
        #expect(stopCommands.filter { $0.contains("gaiterm-agent-event-v1-claude-stop") }
            .count == 1)
        #expect(stopCommands.filter { $0.contains("gaiterm-claude-stop-notify") }
            .count == 1)
        #expect(stopCommands.contains { command in
            command.contains("gaiterm-agent-event-v1-claude-stop")
                && command.contains("last_assistant_message")
        })

        let startGroups = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        let startCommands = startGroups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap {
                $0["command"] as? String
            }
        }
        #expect(startCommands.count == 1)
        #expect(startCommands[0].contains("gaiterm-agent-event-v1-claude-started"))
    }

    @Test func agyInstallerUsesNativeSchemaAndIsIdempotent() throws {
        let existing: [String: Any] = [
            "user-linter": [
                "enabled": false,
                "PreInvocation": [[
                    "type": "command",
                    "command": "user-pre-invocation",
                ]],
            ],
            // Shape written by an older GaiTerm Debug build. Its managed
            // handler must migrate away without deleting the user's neighbor.
            "hooks": [
                "PostToolUse": [[
                    "matcher": "",
                    "hooks": [
                        ["type": "command", "command": "user-post-tool"],
                        [
                            "type": "command",
                            "command": ": gaiterm-agent-event-v1-agy-resumed",
                        ],
                    ],
                ]],
                "Stop": [[
                    "matcher": "",
                    "hooks": [[
                        "type": "command",
                        "command": ": gaiterm-agy-stop-notify",
                    ]],
                ]],
            ],
            "unrelated-metadata": "preserved",
        ]

        let installed = try GaiAgentHookInstaller
            .agyHooksConfigurationForTesting(existing)
        let reinstalled = try GaiAgentHookInstaller
            .agyHooksConfigurationForTesting(installed)
        #expect(try canonicalJSON(installed) == canonicalJSON(reinstalled))
        #expect(installed["unrelated-metadata"] as? String == "preserved")

        let userGroup = try #require(installed["user-linter"] as? [String: Any])
        #expect(userGroup["enabled"] as? Bool == false)
        let userInvocations = try #require(
            userGroup["PreInvocation"] as? [[String: Any]])
        #expect(userInvocations.first?["command"] as? String == "user-pre-invocation")

        let migratedGroup = try #require(installed["hooks"] as? [String: Any])
        #expect(migratedGroup["Stop"] == nil)
        let migratedToolGroups = try #require(
            migratedGroup["PostToolUse"] as? [[String: Any]])
        let migratedHandlers = try #require(
            migratedToolGroups.first?["hooks"] as? [[String: Any]])
        #expect(migratedHandlers.count == 1)
        #expect(migratedHandlers.first?["command"] as? String == "user-post-tool")

        let group = try #require(
            installed["gaiterm-agent-lifecycle-v1"] as? [String: Any])
        #expect(group["enabled"] as? Bool == true)
        #expect(group["SessionStart"] == nil)

        let invocationHandlers = try #require(
            group["PreInvocation"] as? [[String: Any]])
        #expect(invocationHandlers.count == 1)
        #expect(invocationHandlers.first?["hooks"] == nil)
        #expect(invocationHandlers.first?["matcher"] == nil)
        let invocationCommand = try #require(
            invocationHandlers.first?["command"] as? String)
        #expect(invocationCommand.contains("kind=started"))
        #expect(invocationCommand.contains("conversationId"))
        #expect(invocationCommand.contains(#""{}""#))

        let toolGroups = try #require(
            group["PostToolUse"] as? [[String: Any]])
        #expect(toolGroups.count == 1)
        #expect(toolGroups.first?["matcher"] as? String == "")
        let toolHandlers = try #require(
            toolGroups.first?["hooks"] as? [[String: Any]])
        #expect(toolHandlers.count == 1)
        let toolCommand = try #require(toolHandlers.first?["command"] as? String)
        #expect(toolCommand.contains("kind=resumed"))

        let stopHandlers = try #require(group["Stop"] as? [[String: Any]])
        #expect(stopHandlers.count == 1)
        #expect(stopHandlers.first?["hooks"] == nil)
        #expect(stopHandlers.first?["matcher"] == nil)
        let stopCommand = try #require(stopHandlers.first?["command"] as? String)
        #expect(stopCommand.contains("terminationReason"))
        #expect(stopCommand.contains("hook_error"))
        #expect(stopCommand.contains("fullyIdle"))
        #expect(stopCommand.contains(#"[ "$fully_idle" = "false" ]"#))
        #expect(stopCommand.contains("then kind=failed"))
        #expect(stopCommand.contains(#"{\"decision\":\"\"}"#))

        let notIdleGuard = try #require(
            stopCommand.range(of: #"if [ "$fully_idle" = "false" ]"#))
        let socketTransport = try #require(
            stopCommand.range(of: #"socket="${GAITERM_EVENT_SOCKET:-}""#))
        let fallbackTransport = try #require(
            stopCommand.range(of: #"/usr/bin/open -g -b "$bundle""#))
        #expect(notIdleGuard.lowerBound < socketTransport.lowerBound)
        #expect(notIdleGuard.lowerBound < fallbackTransport.lowerBound)

        let invocationResult = try executeHookCommand(
            invocationCommand,
            payload: #"{"conversationId":"conversation-1"}"#)
        #expect(invocationResult.status == 0)
        #expect(invocationResult.stdout == "{}\n")

        let toolResult = try executeHookCommand(
            toolCommand,
            payload: #"{"conversationId":"conversation-1","stepIdx":1}"#)
        #expect(toolResult.status == 0)
        #expect(toolResult.stdout == "{}\n")

        let notIdleResult = try executeHookCommand(
            stopCommand,
            payload: #"{"conversationId":"conversation-1","terminationReason":"model_stop","error":"","fullyIdle":false}"#)
        #expect(notIdleResult.status == 0)
        #expect(notIdleResult.stdout == #"{"decision":""}"# + "\n")
    }

    @Test func grokBuildInstallerUsesAlwaysTrustedGlobalHookSchema() throws {
        let existing: [String: Any] = [
            "metadata": "preserved",
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": "user-grok-stop-hook",
                    ]],
                ]],
            ],
        ]

        let installed = try GaiAgentHookInstaller
            .grokHooksConfigurationForTesting(existing)
        let reinstalled = try GaiAgentHookInstaller
            .grokHooksConfigurationForTesting(installed)

        #expect(try canonicalJSON(installed) == canonicalJSON(reinstalled))
        #expect(installed["metadata"] as? String == "preserved")

        let hooks = try #require(installed["hooks"] as? [String: Any])
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 2)
        #expect(stopGroups[1]["matcher"] == nil)
        let stopHandlers = try #require(stopGroups[1]["hooks"] as? [[String: Any]])
        let stop = try #require(stopHandlers.first)
        #expect(stop["timeout"] as? Int == 5)
        let stopCommand = try #require(stop["command"] as? String)
        #expect(stopCommand.contains("gaiterm-agent-event-v1-grok-stop"))
        #expect(stopCommand.contains("lastAssistantMessage"))
        #expect(stopCommand.contains("promptId"))
        #expect(stopCommand.contains("sessionId"))
        #expect(stopCommand.contains("subagentType"))
        #expect(stopCommand.contains(#"[ "$reason" != "end_turn" ]"#))

        let cancelledGroups = try #require(hooks["StopCancelled"] as? [[String: Any]])
        let cancelledHandlers = try #require(
            cancelledGroups.first?["hooks"] as? [[String: Any]])
        let cancelledCommand = try #require(
            cancelledHandlers.first?["command"] as? String)
        #expect(cancelledCommand.contains("gaiterm-agent-event-v1-grok-cancelled"))

        let notificationGroups = try #require(
            hooks["Notification"] as? [[String: Any]])
        #expect(notificationGroups.count == 2)
        let notificationPairs = notificationGroups.compactMap { group -> (String, String)? in
            guard let matcher = group["matcher"] as? String,
                  let handlers = group["hooks"] as? [[String: Any]],
                  let command = handlers.first?["command"] as? String else { return nil }
            return (matcher, command)
        }
        let notifications = Dictionary(uniqueKeysWithValues: notificationPairs)
        #expect(notifications["permission_prompt"]?.contains(
            "gaiterm-agent-event-v1-grok-awaitingApproval") == true)
        #expect(notifications["idle_prompt"]?.contains(
            "gaiterm-agent-event-v1-grok-stop") == true)
    }

    @Test func openCodePluginKeepsJavaScriptNewlineEscapesLiteral() {
        let source = GaiAgentHookInstaller.openCodePluginSourceForTesting

        #expect(source.contains(#"socketChild.stdin.write(`${url}\n`);"#))
        #expect(source.contains(#"reply.endsWith("\r\n")"#))
        #expect(source.contains(#"reply.endsWith("\n")"#))
        #expect(source.contains(#"await send("ready", id);"#))
        #expect(source.contains(#"await send("ready", "");"#))
        #expect(source.contains(#"event?.properties?.info?.id"#))
        #expect(source.contains(#""chat.message": async"#))
        #expect(source.contains("const pendingErrors = new Set();"))
        #expect(source.contains("active.size === 0"))
        #expect(source.contains(#"await finish(id, "cancelled");"#))
        #expect(source.contains(#"errorName === "MessageAbortedError""#))
        #expect(source.contains(#"type === "question.rejected""#))
        #expect(!source.contains(#"await send("failed", id);"#))
        #expect(!source.contains("let selected ="))
        #expect(!source.contains("reply.endsWith(\"\n"))
    }

    private func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func expectRepairOfPartialIntegration(
        provider: GaiAgentHookInstaller.SupportedProvider,
        installed: [String: Any],
        removedCommandMarker: String,
        repair: ([String: Any]) throws -> [String: Any]
    ) throws {
        #expect(GaiAgentHookInstaller.integrationIsCompleteForTesting(
            provider: provider,
            configuration: installed))

        let partial = configuration(
            installed,
            removingCommandContaining: removedCommandMarker)
        #expect(!GaiAgentHookInstaller.integrationIsCompleteForTesting(
            provider: provider,
            configuration: partial))

        let repaired = try repair(partial)
        #expect(GaiAgentHookInstaller.integrationIsCompleteForTesting(
            provider: provider,
            configuration: repaired))
    }

    private func configuration(
        _ configuration: [String: Any],
        removingCommandContaining marker: String
    ) -> [String: Any] {
        var updated = configuration
        guard var hooks = updated["hooks"] as? [String: Any] else { return updated }

        for (eventName, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let retained = groups.compactMap { group -> [String: Any]? in
                var updatedGroup = group
                guard var handlers = group["hooks"] as? [[String: Any]] else {
                    return updatedGroup
                }
                handlers.removeAll { handler in
                    (handler["command"] as? String)?.contains(marker) == true
                }
                guard !handlers.isEmpty else { return nil }
                updatedGroup["hooks"] = handlers
                return updatedGroup
            }
            if retained.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = retained
            }
        }
        updated["hooks"] = hooks
        return updated
    }

    private func hookCommands(in groups: [[String: Any]]) -> [String] {
        groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap {
                $0["command"] as? String
            }
        }
    }

    private func executeHookCommand(
        _ command: String,
        payload: String
    ) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        var environment = ProcessInfo.processInfo.environment
        environment["GAITERM_SURFACE_ID"] = ""
        environment["GAITERM_EVENT_TOKEN"] = ""
        environment["GAITERM_EVENT_SOCKET"] = ""
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        return (
            status: process.terminationStatus,
            stdout: String(data: outputData, encoding: .utf8) ?? "")
    }
}
#endif
