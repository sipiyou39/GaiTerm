import Foundation

struct VoiceOption: Codable, Identifiable, Hashable, Sendable {
    let voiceID: String
    let name: String
    let language: String?
    let gender: String?

    var id: String { voiceID }

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
        case language
        case gender
    }
}

enum VoiceCatalog {
    static let defaultVoiceID = "altair"
    static let supported: [VoiceOption] = [
        option("altair", "male"),
        option("ara", "female"),
        option("liora", "female"),
        option("lumen", "male"),
    ]

    static func normalizedSelection(_ voiceID: String?) -> String {
        guard let voiceID,
              supported.contains(where: { $0.voiceID == voiceID })
        else { return defaultVoiceID }
        return voiceID
    }

    private static func option(_ id: String, _ gender: String) -> VoiceOption {
        VoiceOption(
            voiceID: id,
            name: id.prefix(1).uppercased() + id.dropFirst(),
            language: "multilingual",
            gender: gender
        )
    }
}
