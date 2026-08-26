#if os(macOS)
import Darwin
import Foundation

/// Safely reads the argument vector of a macOS process.
///
/// `KERN_PROCARGS2` can return both a very large buffer and untrusted process
/// data. The reader therefore bounds the kernel allocation, argument count,
/// and individual argument length before exposing strings to the classifier.
enum GaiCompanionProcessArguments {
    static func arguments(forPID pid: Int) -> [String] {
        guard pid > 0, pid <= Int(Int32.max) else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var byteCount = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &byteCount, nil, 0) == 0,
              byteCount >= MemoryLayout<Int32>.size,
              byteCount <= maximumBufferByteCount else {
            return []
        }

        var buffer = [UInt8](repeating: 0, count: byteCount)
        var bytesRead = byteCount
        let status = buffer.withUnsafeMutableBytes { bytes in
            sysctl(
                &mib,
                UInt32(mib.count),
                bytes.baseAddress,
                &bytesRead,
                nil,
                0)
        }
        guard status == 0,
              bytesRead >= MemoryLayout<Int32>.size,
              bytesRead <= buffer.count else {
            return []
        }
        return parse(buffer.prefix(bytesRead))
    }

    static func parse<Bytes: Collection>(_ bytes: Bytes) -> [String]
    where Bytes.Element == UInt8, Bytes.Index == Int {
        guard bytes.count >= MemoryLayout<Int32>.size else { return [] }

        var rawArgumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &rawArgumentCount) { destination in
            for offset in 0..<MemoryLayout<Int32>.size {
                destination[offset] = bytes[bytes.startIndex + offset]
            }
        }
        let argumentCount = Int(rawArgumentCount)
        guard argumentCount > 0, argumentCount <= maximumArgumentCount else { return [] }

        var cursor = bytes.startIndex + MemoryLayout<Int32>.size
        let end = bytes.endIndex

        // The executable path precedes argv and is not counted in argc.
        while cursor < end, bytes[cursor] != 0 {
            cursor += 1
        }
        guard cursor < end else { return [] }
        while cursor < end, bytes[cursor] == 0 {
            cursor += 1
        }

        var result: [String] = []
        result.reserveCapacity(argumentCount)
        for _ in 0..<argumentCount {
            guard cursor < end else { return [] }
            let start = cursor
            while cursor < end, bytes[cursor] != 0 {
                guard cursor - start < maximumArgumentByteCount else { return [] }
                cursor += 1
            }
            guard cursor < end else { return [] }
            guard let argument = String(
                bytes: bytes[start..<cursor],
                encoding: .utf8) else { return [] }
            result.append(argument)
            cursor += 1
        }
        return result
    }

    private static let maximumBufferByteCount = 1_048_576
    private static let maximumArgumentCount = 4_096
    private static let maximumArgumentByteCount = 65_536
}

/// Conservative provider detection for an already-running terminal process.
///
/// Process arguments are the strongest signal, followed by the configured
/// launch command. A terminal title is used only when it begins with an exact,
/// well-known product name followed by a title separator. Ambiguous text
/// deliberately returns `nil` instead of guessing.
enum GaiCompanionProviderClassifier {
    private struct ProviderInvocation {
        let provider: GaiCompanionProvider
        let arguments: [String]
    }

    static func classify(
        launchCommand: String? = nil,
        terminalTitle: String? = nil,
        argv: [String] = []
    ) -> GaiCompanionProvider? {
        if let provider = classify(arguments: argv) {
            return provider
        }
        if let launchCommand,
           let provider = classify(arguments: tokenize(command: launchCommand)) {
            return provider
        }
        return classify(title: terminalTitle)
    }

    /// Returns true only when foreground argv proves that a provider has
    /// opened an interactive UI without starting a prompt. This intentionally
    /// rejects ambiguous invocations: incorrectly keeping a real task active
    /// is recoverable through its Stop hook, while declaring that task idle
    /// would let Teddy submit a second prompt into live work.
    static func isProvenIdleInteractiveLaunch(
        provider: GaiCompanionProvider,
        argv: [String]
    ) -> Bool {
        guard provider != .terminal,
              let invocation = providerInvocation(arguments: argv),
              invocation.provider == provider else { return false }

        switch provider {
        case .codex:
            return codexLaunchesIdleInteractiveSession(
                arguments: invocation.arguments)
        case .claude, .grok, .agy, .opencode:
            // Their bare executables open an interactive session. Until their
            // full flag grammars are modeled, any argument remains ambiguous.
            return invocation.arguments.isEmpty
        default:
            return false
        }
    }

    private static func classify(arguments: [String]) -> GaiCompanionProvider? {
        providerInvocation(arguments: arguments)?.provider
    }

    private static func providerInvocation(
        arguments rawArguments: [String]
    ) -> ProviderInvocation? {
        let arguments = rawArguments.filter { !$0.isEmpty }
        guard let first = arguments.first else { return nil }

        if let provider = provider(forExecutable: first) {
            return ProviderInvocation(
                provider: provider,
                arguments: Array(arguments.dropFirst()))
        }

        let executable = executableName(first)
        switch executable {
        case "env":
            let remaining = Array(arguments.dropFirst().drop {
                $0.hasPrefix("-") || isEnvironmentAssignment($0)
            })
            return providerInvocation(arguments: remaining)

        case "node", "nodejs", "bun", "deno":
            guard let scriptIndex = arguments.indices.dropFirst().first(where: {
                !arguments[$0].hasPrefix("-")
            }) else {
                return nil
            }
            let script = arguments[scriptIndex]
            guard let provider = provider(forExecutable: script)
                    ?? provider(forPackage: script) else { return nil }
            return ProviderInvocation(
                provider: provider,
                arguments: Array(arguments.dropFirst(scriptIndex + 1)))

        case "npx", "bunx":
            guard let packageIndex = arguments.indices.dropFirst().first(where: {
                !arguments[$0].hasPrefix("-")
            }) else {
                return nil
            }
            let package = arguments[packageIndex]
            guard let provider = provider(forPackage: package)
                    ?? provider(forExecutable: package) else { return nil }
            return ProviderInvocation(
                provider: provider,
                arguments: Array(arguments.dropFirst(packageIndex + 1)))

        case "pnpm":
            return packageRunnerInvocation(
                arguments: arguments,
                subcommands: ["dlx", "exec"])

        case "npm":
            return packageRunnerInvocation(
                arguments: arguments,
                subcommands: ["exec", "x"])

        case "yarn":
            return packageRunnerInvocation(
                arguments: arguments,
                subcommands: ["dlx", "exec"])

        default:
            return nil
        }
    }

    private static func packageRunnerInvocation(
        arguments: [String],
        subcommands: Set<String>
    ) -> ProviderInvocation? {
        guard let subcommandIndex = arguments.indices.dropFirst().first(where: {
            subcommands.contains(arguments[$0].lowercased())
        }) else {
            return nil
        }
        guard let packageIndex = arguments.indices.first(where: {
            $0 > subcommandIndex && !arguments[$0].hasPrefix("-")
        }) else {
            return nil
        }
        let package = arguments[packageIndex]
        guard let provider = provider(forPackage: package)
                ?? provider(forExecutable: package) else { return nil }
        return ProviderInvocation(
            provider: provider,
            arguments: Array(arguments.dropFirst(packageIndex + 1)))
    }

    /// Codex documents `PROMPT` as optional for the base command: without it
    /// the TUI is merely ready, while `exec` and `review` are non-interactive
    /// work. `resume` and `fork` also open an interactive UI and may name one
    /// session, so those forms are idle unless extra prompt-like text remains.
    private static func codexLaunchesIdleInteractiveSession(
        arguments: [String]
    ) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                return index + 1 == arguments.count
            }
            if argument.hasPrefix("-") {
                guard consumeCodexOption(arguments, index: &index) else {
                    return false
                }
                continue
            }

            switch argument.lowercased() {
            case "resume", "fork":
                return codexInteractiveSubcommandIsIdle(
                    arguments: Array(arguments.dropFirst(index + 1)))
            default:
                // A base-command positional is either PROMPT or a command such
                // as exec/review; both start work rather than an idle TUI.
                return false
            }
        }
        return true
    }

    private static func codexInteractiveSubcommandIsIdle(
        arguments: [String]
    ) -> Bool {
        var index = 0
        var selectsLastSession = false
        var positionalCount = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                positionalCount += arguments.count - index - 1
                break
            }
            if argument == "--all" || argument == "--include-non-interactive" {
                index += 1
                continue
            }
            if argument == "--last" {
                selectsLastSession = true
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                guard consumeCodexOption(arguments, index: &index) else {
                    return false
                }
                continue
            }
            positionalCount += 1
            index += 1
        }

        // With --last, any positional is prompt-like. Otherwise one
        // positional may be the documented SESSION_ID/session name.
        return selectsLastSession ? positionalCount == 0 : positionalCount <= 1
    }

    private static func consumeCodexOption(
        _ arguments: [String],
        index: inout Int
    ) -> Bool {
        let argument = arguments[index]
        let optionName = argument.split(separator: "=", maxSplits: 1)
            .first.map(String.init) ?? argument

        if codexBooleanOptions.contains(optionName) {
            index += 1
            return true
        }
        if codexValueOptions.contains(optionName) {
            if argument.contains("=") {
                index += 1
                return true
            }
            guard index + 1 < arguments.count else { return false }
            index += 2
            return true
        }
        if codexCompactValueOptionPrefixes.contains(where: {
            argument.hasPrefix($0) && argument.count > $0.count
        }) {
            index += 1
            return true
        }
        return false
    }

    private static let codexBooleanOptions: Set<String> = [
        "--dangerously-bypass-approvals-and-sandbox",
        "--dangerously-bypass-hook-trust",
        "--full-auto",
        "--help",
        "--no-alt-screen",
        "--oss",
        "--search",
        "--strict-config",
        "--version",
        "--yolo",
        "-h",
        "-V",
    ]

    private static let codexValueOptions: Set<String> = [
        "--add-dir",
        "--ask-for-approval",
        "--cd",
        "--config",
        "--disable",
        "--enable",
        "--image",
        "--local-provider",
        "--model",
        "--profile",
        "--remote",
        "--remote-auth-token-env",
        "--sandbox",
        "-C",
        "-a",
        "-c",
        "-i",
        "-m",
        "-p",
        "-s",
    ]

    private static let codexCompactValueOptionPrefixes = [
        "-C", "-a", "-c", "-i", "-m", "-p", "-s",
    ]

    private static func provider(forExecutable value: String) -> GaiCompanionProvider? {
        switch executableName(value) {
        case "codex", "codex-cli":
            return GaiCompanionProvider.codex
        case "claude", "claude-code":
            return GaiCompanionProvider.claude
        case "grok", "xai-grok-pager":
            return GaiCompanionProvider.grok
        case "agy":
            return GaiCompanionProvider.agy
        case "opencode":
            return GaiCompanionProvider.opencode
        default:
            return nil
        }
    }

    private static func provider(forPackage value: String) -> GaiCompanionProvider? {
        let package = value.lowercased()
        switch package {
        case "@openai/codex":
            return GaiCompanionProvider.codex
        case "@anthropic-ai/claude-code":
            return GaiCompanionProvider.claude
        case "@xai-official/grok":
            return GaiCompanionProvider.grok
        case "opencode-ai", "@sst/opencode":
            return GaiCompanionProvider.opencode
        default:
            return provider(forExecutable: value)
        }
    }

    private static func classify(title: String?) -> GaiCompanionProvider? {
        guard let title else { return nil }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates: [(String, GaiCompanionProvider)] = [
            ("claude code", .claude),
            ("grok build", .grok),
            ("opencode", .opencode),
            ("codex", .codex),
            ("grok", .grok),
            ("agy", .agy),
        ]

        for (name, provider) in candidates {
            if normalized == name {
                return provider
            }
            guard normalized.hasPrefix(name) else { continue }
            let suffix = normalized.dropFirst(name.count)
            if Self.titleSeparators.contains(where: { suffix.hasPrefix($0) }) {
                return provider
            }
        }
        return nil
    }

    private static let titleSeparators = [" — ", " – ", " - ", " · ", ": ", " | "]

    private static func executableName(_ value: String) -> String {
        let basename = URL(fileURLWithPath: value).lastPathComponent.lowercased()
        if basename.hasSuffix(".exe") {
            return String(basename.dropLast(4))
        }
        return basename
    }

    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
            return false
        }
        let name = value[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// A deliberately small shell lexer. It understands quoting and escaping,
    /// but stops at the first shell control operator so words in prompts or a
    /// subsequent command cannot masquerade as the launched executable.
    private static func tokenize(command: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        func flush() {
            guard !current.isEmpty else { return }
            result.append(current)
            current = ""
        }

        for character in command {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                flush()
            } else if character == ";" || character == "|" || character == "&" {
                flush()
                break
            } else {
                current.append(character)
            }
        }
        if escaped {
            current.append("\\")
        }
        flush()
        return result
    }
}
#endif
