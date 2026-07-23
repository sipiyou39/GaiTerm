#if DEBUG
import Foundation
import Testing
@testable import Ghostty

struct GaiCompanionProviderClassifierTests {
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
            launchCommand: "pnpm dlx opencode-ai") == .opencode)
        #expect(GaiCompanionProviderClassifier.classify(
            launchCommand: "env NODE_NO_WARNINGS=1 codex --full-auto") == .codex)
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
    @Test func codexTrustInstallationIsTextuallyIdempotent() {
        let existing = "[model]\nname = \"gpt-5\"\n"
        let installed = GaiAgentHookInstaller.codexTrustContentForTesting(existing)
        let reinstalled = GaiAgentHookInstaller.codexTrustContentForTesting(installed)

        #expect(reinstalled == installed)
        #expect(installed.contains(existing.trimmingCharacters(in: .newlines)))
        #expect(installed.components(separatedBy: "gaiterm-codex-agent-event-trust-v1 begin")
            .count == 2)
        #expect(installed.components(separatedBy: "gaiterm-codex-hook-trust begin")
            .count == 2)
    }

    @Test func claudeDebugAndReleaseHooksShareTheSupportedGlobalScope() throws {
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
        let debugInstalled = try GaiAgentHookInstaller
            .claudeHooksConfigurationForTesting(existing)
        let releaseMaintained = try GaiAgentHookInstaller
            .claudeLegacyHooksConfigurationForTesting(debugInstalled)
        let debugReinstalled = try GaiAgentHookInstaller
            .claudeHooksConfigurationForTesting(releaseMaintained)

        #expect(try canonicalJSON(debugInstalled) == canonicalJSON(releaseMaintained))
        #expect(try canonicalJSON(debugInstalled) == canonicalJSON(debugReinstalled))
        #expect(debugInstalled["theme"] as? String == "dark")

        let hooks = try #require(debugInstalled["hooks"] as? [String: Any])
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

        let invocationResult = try executeAgyHook(
            invocationCommand,
            payload: #"{"conversationId":"conversation-1"}"#)
        #expect(invocationResult.status == 0)
        #expect(invocationResult.stdout == "{}\n")

        let toolResult = try executeAgyHook(
            toolCommand,
            payload: #"{"conversationId":"conversation-1","stepIdx":1}"#)
        #expect(toolResult.status == 0)
        #expect(toolResult.stdout == "{}\n")

        let notIdleResult = try executeAgyHook(
            stopCommand,
            payload: #"{"conversationId":"conversation-1","terminationReason":"model_stop","error":"","fullyIdle":false}"#)
        #expect(notIdleResult.status == 0)
        #expect(notIdleResult.stdout == #"{"decision":""}"# + "\n")
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

    private func executeAgyHook(
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
            stdout: String(decoding: outputData, as: UTF8.self))
    }
}
#endif
