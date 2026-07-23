#if os(macOS)
import Foundation

/// A visual colorway from the GaiWork companion catalog.
///
/// The colorway is presentation only. A companion's stable identity is its
/// independent `UUID`, so any number of companions may share the same colorway.
enum GaiCompanionColorway: String, Codable, CaseIterable, Sendable {
    case aurore
    case blue
    case purple
    case black
    case yellow
    case orange
    case red
    case gray
    case white

    /// Aurore is the exact green GaiWork asset and is reserved for an unseen
    /// task completion. Persisted agent identities deliberately exclude it so
    /// green always has one unambiguous meaning.
    static let completionColorway: Self = .aurore
    static let selectableColorways = allCases.filter { $0 != completionColorway }
    static let defaultColorway: Self = .purple

    var isSelectable: Bool {
        self != Self.completionColorway
    }

    var normalizedPersistentColorway: Self {
        isSelectable ? self : Self.defaultColorway
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .defaultColorway
    }
}

/// A display-independent point. Both coordinates are persisted in `0...1`
/// relative to the display's usable frame, so placement survives resolution and
/// display-layout changes.
struct GaiCompanionNormalizedPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    static let center = Self(x: 0.5, y: 0.5)

    init(x: Double, y: Double) {
        self.x = Self.normalize(x)
        self.y = Self.normalize(y)
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5,
            y: try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5)
    }

    private static func normalize(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}

/// The companion terminal's remembered compact dimensions, in points.
struct GaiCompanionCompactSize: Codable, Equatable, Sendable {
    var width: Double
    var height: Double

    static let standard = Self(width: 480, height: 300)
    static let minimum = Self(width: 320, height: 200)
    static let maximum = Self(width: 1_600, height: 1_200)

    init(width: Double, height: Double) {
        self.width = Self.normalize(
            width,
            fallback: Self.standardWidth,
            minimum: Self.minimumWidth,
            maximum: Self.maximumWidth)
        self.height = Self.normalize(
            height,
            fallback: Self.standardHeight,
            minimum: Self.minimumHeight,
            maximum: Self.maximumHeight)
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
    }

    private static let standardWidth = 480.0
    private static let standardHeight = 300.0
    private static let minimumWidth = 320.0
    private static let minimumHeight = 200.0
    private static let maximumWidth = 1_600.0
    private static let maximumHeight = 1_200.0

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            width: try container.decodeIfPresent(Double.self, forKey: .width)
                ?? Self.standardWidth,
            height: try container.decodeIfPresent(Double.self, forKey: .height)
                ?? Self.standardHeight)
    }

    private static func normalize(
        _ value: Double,
        fallback: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, minimum), maximum)
    }
}

/// Per-companion desktop scale, matching GaiWork's supported 50...200% range.
struct GaiCompanionScalePercent: Codable, Equatable, Sendable {
    let value: Int

    static let minimum = 50
    static let maximum = 200
    static let standard = Self(100)

    init(_ value: Int) {
        self.value = min(max(value, Self.minimum), Self.maximum)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// One source of truth for the clickable panel and rendered mascot scale.
enum GaiCompanionVisualMetrics {
    static let basePanelWidth = 142.0
    static let basePanelHeight = 158.0
    static let baseSpriteWidth = 112.0

    static func scaleFactor(for scalePercent: GaiCompanionScalePercent) -> Double {
        Double(scalePercent.value) / 100
    }

    static func scaledPanelWidth(for scalePercent: GaiCompanionScalePercent) -> Double {
        (basePanelWidth * scaleFactor(for: scalePercent)).rounded()
    }

    static func scaledPanelHeight(for scalePercent: GaiCompanionScalePercent) -> Double {
        (basePanelHeight * scaleFactor(for: scalePercent)).rounded()
    }

    static func scaledSpriteWidth(for scalePercent: GaiCompanionScalePercent) -> Double {
        (baseSpriteWidth * scaleFactor(for: scalePercent)).rounded()
    }
}

/// Persisted companion configuration. Runtime-only state such as the live PTY,
/// `Ghostty.SurfaceView`, focus and hook activity deliberately lives elsewhere.
struct GaiCompanionRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String?
    var colorway: GaiCompanionColorway
    var directoryPath: String
    var launchCommand: String?
    var normalizedPosition: GaiCompanionNormalizedPosition
    var displayID: String?
    var compactSize: GaiCompanionCompactSize
    var scalePercent: GaiCompanionScalePercent
    var completionSoundEnabled: Bool

    static let defaultName = "Agent"
    static let maximumNameLength = 40

    var displayName: String {
        name ?? Self.defaultName
    }

    static var defaultDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    init(
        id: UUID = UUID(),
        name: String? = nil,
        colorway: GaiCompanionColorway = .defaultColorway,
        directoryPath: String = GaiCompanionRecord.defaultDirectoryPath,
        launchCommand: String? = nil,
        normalizedPosition: GaiCompanionNormalizedPosition = .center,
        displayID: String? = nil,
        compactSize: GaiCompanionCompactSize = .standard,
        scalePercent: GaiCompanionScalePercent = .standard,
        completionSoundEnabled: Bool = true
    ) {
        self.id = id
        self.name = Self.cleanName(name)
        self.colorway = colorway.normalizedPersistentColorway
        self.directoryPath = Self.cleanDirectoryPath(directoryPath)
        self.launchCommand = Self.cleanOptionalText(launchCommand)
        self.normalizedPosition = GaiCompanionNormalizedPosition(
            x: normalizedPosition.x,
            y: normalizedPosition.y)
        self.displayID = Self.cleanOptionalText(displayID)
        self.compactSize = GaiCompanionCompactSize(
            width: compactSize.width,
            height: compactSize.height)
        self.scalePercent = GaiCompanionScalePercent(scalePercent.value)
        self.completionSoundEnabled = completionSoundEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorway
        case directoryPath
        case launchCommand
        case normalizedPosition
        case displayID
        case compactSize
        case scalePercent
        case completionSoundEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            colorway: try container.decodeIfPresent(
                GaiCompanionColorway.self,
                forKey: .colorway) ?? .defaultColorway,
            directoryPath: try container.decodeIfPresent(
                String.self,
                forKey: .directoryPath) ?? Self.defaultDirectoryPath,
            launchCommand: try container.decodeIfPresent(String.self, forKey: .launchCommand),
            normalizedPosition: try container.decodeIfPresent(
                GaiCompanionNormalizedPosition.self,
                forKey: .normalizedPosition) ?? .center,
            displayID: try container.decodeIfPresent(String.self, forKey: .displayID),
            compactSize: try container.decodeIfPresent(
                GaiCompanionCompactSize.self,
                forKey: .compactSize) ?? .standard,
            scalePercent: try container.decodeIfPresent(
                GaiCompanionScalePercent.self,
                forKey: .scalePercent) ?? .standard,
            completionSoundEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .completionSoundEnabled) ?? true)
    }

    /// Re-applies invariants after a caller mutates a record through the store.
    func normalized() -> Self {
        Self(
            id: id,
            name: name,
            colorway: colorway,
            directoryPath: directoryPath,
            launchCommand: launchCommand,
            normalizedPosition: normalizedPosition,
            displayID: displayID,
            compactSize: compactSize,
            scalePercent: scalePercent,
            completionSoundEnabled: completionSoundEnabled)
    }

    private static func cleanName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumNameLength))
    }

    private static func cleanDirectoryPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultDirectoryPath }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func cleanOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
