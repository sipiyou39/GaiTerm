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
            result.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
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

    private static func classify(arguments: [String]) -> GaiCompanionProvider? {
        let arguments = arguments.filter { !$0.isEmpty }
        guard let first = arguments.first else { return nil }

        if let provider = provider(forExecutable: first) {
            return provider
        }

        let executable = executableName(first)
        switch executable {
        case "env":
            let remaining = Array(arguments.dropFirst().drop {
                $0.hasPrefix("-") || isEnvironmentAssignment($0)
            })
            return classify(arguments: remaining)

        case "node", "nodejs", "bun", "deno":
            guard let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
                return nil
            }
            return provider(forExecutable: script) ?? provider(forPackage: script)

        case "npx", "bunx":
            guard let package = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
                return nil
            }
            return provider(forPackage: package) ?? provider(forExecutable: package)

        case "pnpm":
            return classifyPackageRunner(arguments: arguments, subcommands: ["dlx", "exec"])

        case "npm":
            return classifyPackageRunner(arguments: arguments, subcommands: ["exec", "x"])

        case "yarn":
            return classifyPackageRunner(arguments: arguments, subcommands: ["dlx", "exec"])

        default:
            return nil
        }
    }

    private static func classifyPackageRunner(
        arguments: [String],
        subcommands: Set<String>
    ) -> GaiCompanionProvider? {
        let remainder = Array(arguments.dropFirst())
        guard let subcommandIndex = remainder.firstIndex(where: {
            subcommands.contains($0.lowercased())
        }) else {
            return nil
        }
        guard let package = remainder.dropFirst(subcommandIndex + 1).first(where: {
            !$0.hasPrefix("-")
        }) else {
            return nil
        }
        return provider(forPackage: package) ?? provider(forExecutable: package)
    }

    private static func provider(forExecutable value: String) -> GaiCompanionProvider? {
        switch executableName(value) {
        case "codex", "codex-cli":
            return GaiCompanionProvider.codex
        case "claude", "claude-code":
            return GaiCompanionProvider.claude
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
            ("opencode", .opencode),
            ("codex", .codex),
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
