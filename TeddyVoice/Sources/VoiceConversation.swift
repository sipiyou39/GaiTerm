import Foundation

struct VoiceConversationSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let messageCount: Int

    var isEmpty: Bool { messageCount == 0 }
}

struct VoiceConversation: Identifiable, Codable, Sendable, Equatable {
    static let untitledName = "Nouvelle conversation"

    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [VoiceMessage]
    var history: [GrokTextMessage]
    var inputTokenCount: Int
    var outputTokenCount: Int
    var ttsCharacterCount: Int

    init(
        id: UUID = UUID(),
        title: String = Self.untitledName,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messages: [VoiceMessage] = [],
        history: [GrokTextMessage] = [],
        inputTokenCount: Int = 0,
        outputTokenCount: Int = 0,
        ttsCharacterCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.history = history
        self.inputTokenCount = inputTokenCount
        self.outputTokenCount = outputTokenCount
        self.ttsCharacterCount = ttsCharacterCount
    }

    var summary: VoiceConversationSummary {
        VoiceConversationSummary(
            id: id,
            title: title,
            updatedAt: updatedAt,
            messageCount: messages.count
        )
    }

    static func suggestedTitle(from transcript: String) -> String {
        let words = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
        guard !words.isEmpty else { return untitledName }

        var title = words.prefix(7).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = title.last, ".,;:!?…".contains(last) {
            title.removeLast()
        }
        if title.count > 48 {
            let boundary = title.index(title.startIndex, offsetBy: 48)
            title = String(title[..<boundary]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title.isEmpty ? untitledName : title
    }
}

struct LoadedVoiceConversation: Sendable {
    let conversation: VoiceConversation
    let audioArchive: [UUID: Data]
}

struct VoiceConversationStore: Sendable {
    private static let metadataFilename = "conversation.json"
    private static let audioDirectoryName = "Audio"
    private let rootURL: URL

    init(rootURL: URL = Self.defaultRootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TeddyCLI", directoryHint: .isDirectory)
            .appending(path: "Conversations", directoryHint: .isDirectory)
    }

    func loadConversations() throws -> [VoiceConversation] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return directories.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            let metadataURL = directory.appending(path: Self.metadataFilename)
            guard let data = try? Data(contentsOf: metadataURL),
                  let conversation = try? decoder.decode(VoiceConversation.self, from: data)
            else { return nil }
            return conversation
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ conversation: VoiceConversation) -> LoadedVoiceConversation {
        let audioDirectory = directory(for: conversation.id)
            .appending(path: Self.audioDirectoryName, directoryHint: .isDirectory)
        var archive: [UUID: Data] = [:]
        for message in conversation.messages {
            let audioURL = audioDirectory.appending(path: "\(message.id.uuidString).pcm")
            if let data = try? Data(contentsOf: audioURL), !data.isEmpty {
                archive[message.id] = data
            }
        }
        return LoadedVoiceConversation(conversation: conversation, audioArchive: archive)
    }

    func save(_ conversation: VoiceConversation, audioArchive: [UUID: Data]) throws {
        let fileManager = FileManager.default
        let conversationDirectory = directory(for: conversation.id)
        let audioDirectory = conversationDirectory
            .appending(path: Self.audioDirectoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let metadata = try encoder.encode(conversation)
        try metadata.write(
            to: conversationDirectory.appending(path: Self.metadataFilename),
            options: .atomic
        )

        for (messageID, audio) in audioArchive where !audio.isEmpty {
            let audioURL = audioDirectory.appending(path: "\(messageID.uuidString).pcm")
            let existingSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            guard existingSize != audio.count else { continue }
            try audio.write(to: audioURL, options: .atomic)
        }
    }

    func delete(_ conversationID: UUID) throws {
        let target = directory(for: conversationID).standardizedFileURL
        guard target.deletingLastPathComponent() == rootURL else { return }
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    private func directory(for conversationID: UUID) -> URL {
        rootURL.appending(path: conversationID.uuidString, directoryHint: .isDirectory)
    }
}

actor VoiceConversationRepository {
    private let store: VoiceConversationStore
    private let isEnabled: Bool

    init(
        store: VoiceConversationStore = VoiceConversationStore(),
        isEnabled: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    ) {
        self.store = store
        self.isEnabled = isEnabled
    }

    func loadConversations() -> [VoiceConversation] {
        guard isEnabled else { return [] }
        return (try? store.loadConversations()) ?? []
    }

    func load(_ conversation: VoiceConversation) -> LoadedVoiceConversation {
        guard isEnabled else {
            return LoadedVoiceConversation(conversation: conversation, audioArchive: [:])
        }
        return store.load(conversation)
    }

    func save(_ conversation: VoiceConversation, audioArchive: [UUID: Data]) {
        guard isEnabled else { return }
        try? store.save(conversation, audioArchive: audioArchive)
    }

    func delete(_ conversationID: UUID) {
        guard isEnabled else { return }
        try? store.delete(conversationID)
    }
}
