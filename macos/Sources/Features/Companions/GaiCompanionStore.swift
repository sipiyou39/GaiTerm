#if os(macOS)
import Combine
import Foundation

enum GaiCompanionLoadResult: Equatable {
    case loaded(Int)
    case migrated(Int)
    case empty
    case failed
}

/// Persistence owner for agent records.
///
/// Mutating operations save immediately. `save()` remains public so callers can
/// explicitly retry a failed write or persist after future batched operations.
final class GaiCompanionStore: ObservableObject {
    nonisolated static let defaultPersistenceKey = "gai.companions.v1"
    nonisolated static let defaultLegacyWorkspaceKey = "gai.workspaces.v1"

    @Published private(set) var companions: [GaiCompanionRecord] = []

    private let userDefaults: UserDefaults
    private let persistenceKey: String
    private let legacyWorkspaceKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        persistenceKey: String = GaiCompanionStore.defaultPersistenceKey,
        legacyWorkspaceKey: String = GaiCompanionStore.defaultLegacyWorkspaceKey,
        loadImmediately: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.persistenceKey = persistenceKey
        self.legacyWorkspaceKey = legacyWorkspaceKey
        if loadImmediately {
            _ = load()
        }
    }

    @discardableResult
    func load() -> GaiCompanionLoadResult {
        if let data = userDefaults.data(forKey: persistenceKey) {
            guard let records = try? decoder.decode([GaiCompanionRecord].self, from: data) else {
                return .failed
            }
            let hadReservedPersistedColorway = Self.containsReservedPersistedColorway(
                in: data)
            let normalizedRecords = Self.deduplicatingIDs(
                in: records.map { $0.normalized() })
            let namingMigration = Self.assigningGeneratedNames(in: normalizedRecords)
            companions = namingMigration.records
            let recordsWereNormalized = normalizedRecords != records
            if hadReservedPersistedColorway
                || recordsWereNormalized
                || namingMigration.didChange,
                !save() {
                return .failed
            }
            return .loaded(companions.count)
        }

        guard let legacyData = userDefaults.data(forKey: legacyWorkspaceKey) else {
            companions = []
            return .empty
        }
        guard let workspaces = Self.decodeLegacyWorkspaces(from: legacyData) else {
            return .failed
        }

        let namingMigration = Self.assigningGeneratedNames(
            in: Self.migrate(workspaces))
        companions = namingMigration.records
        guard save() else { return .failed }
        return .migrated(companions.count)
    }

    @discardableResult
    func save() -> Bool {
        guard let data = try? encoder.encode(companions) else { return false }
        userDefaults.set(data, forKey: persistenceKey)
        return true
    }

    @discardableResult
    func create(
        name: String? = nil,
        colorway: GaiCompanionColorway = .defaultColorway,
        directoryPath: String = GaiCompanionRecord.defaultDirectoryPath,
        launchCommand: String? = nil,
        normalizedPosition: GaiCompanionNormalizedPosition = .center,
        displayID: String? = nil,
        compactSize: GaiCompanionCompactSize = .standard,
        scalePercent: GaiCompanionScalePercent = .standard,
        completionSoundEnabled: Bool = true
    ) -> GaiCompanionRecord {
        var record = GaiCompanionRecord(
            name: name,
            colorway: colorway,
            directoryPath: directoryPath,
            launchCommand: launchCommand,
            normalizedPosition: normalizedPosition,
            displayID: displayID,
            compactSize: compactSize,
            scalePercent: scalePercent,
            completionSoundEnabled: completionSoundEnabled)
        if record.name == nil {
            var usedNames = Self.canonicalNames(in: companions)
            record.name = Self.nextGeneratedName(usedNames: &usedNames)
        }
        companions.append(record)
        _ = save()
        return record
    }

    @discardableResult
    func remove(id: GaiCompanionRecord.ID) -> GaiCompanionRecord? {
        guard let index = companions.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = companions.remove(at: index)
        _ = save()
        return removed
    }

    @discardableResult
    func update(
        id: GaiCompanionRecord.ID,
        _ mutation: (inout GaiCompanionRecord) -> Void
    ) -> GaiCompanionRecord? {
        update(ids: [id], mutation).first
    }

    /// Mutates several records as one transaction. The published collection is
    /// replaced once and persistence runs once, regardless of selection size.
    /// A no-op mutation neither publishes nor writes UserDefaults.
    @discardableResult
    func update(
        ids: Set<GaiCompanionRecord.ID>,
        _ mutation: (inout GaiCompanionRecord) -> Void
    ) -> [GaiCompanionRecord] {
        guard !ids.isEmpty else { return [] }

        var updatedCompanions = companions
        var didChange = false
        for index in updatedCompanions.indices
            where ids.contains(updatedCompanions[index].id) {
            var record = updatedCompanions[index]
            mutation(&record)
            record = record.normalized()
            guard record != updatedCompanions[index] else { continue }
            updatedCompanions[index] = record
            didChange = true
        }

        if didChange {
            companions = updatedCompanions
            _ = save()
        }
        return updatedCompanions.filter { ids.contains($0.id) }
    }
}

// MARK: - Legacy workspace migration

private extension GaiCompanionStore {
    static let legacyCLIOrder = ["claude", "codex", "agy", "opencode"]
    static let maximumMigratedCompanions = 128

    static func assigningGeneratedNames(
        in records: [GaiCompanionRecord]
    ) -> (records: [GaiCompanionRecord], didChange: Bool) {
        var result = records
        var usedNames = canonicalNames(in: result)
        var didChange = false

        for index in result.indices where result[index].name == nil {
            result[index].name = nextGeneratedName(usedNames: &usedNames)
            didChange = true
        }
        return (result, didChange)
    }

    static func canonicalNames(
        in records: [GaiCompanionRecord]
    ) -> Set<String> {
        Set(records.compactMap(\.name).map(canonicalName))
    }

    static func nextGeneratedName(usedNames: inout Set<String>) -> String {
        var suffix = 1
        while true {
            let candidate = "\(GaiCompanionRecord.defaultName) \(suffix)"
            if usedNames.insert(canonicalName(candidate)).inserted {
                return candidate
            }
            suffix += 1
        }
    }

    static func canonicalName(_ name: String) -> String {
        name.lowercased()
    }

    static func containsReservedPersistedColorway(in data: Data) -> Bool {
        guard let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }
        return records.contains {
            $0["colorway"] as? String == GaiCompanionColorway.completionColorway.rawValue
        }
    }

    /// JSONSerialization lets migration skip a malformed workspace while keeping
    /// every valid sibling. Decoding the array directly with Codable would reject
    /// the entire legacy payload because of one bad element.
    static func decodeLegacyWorkspaces(from data: Data) -> [GaiLegacyWorkspaceDTO]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let items = object as? [Any]
        else { return nil }

        return items.compactMap { item in
            guard JSONSerialization.isValidJSONObject(item),
                  let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let workspace = try? JSONDecoder().decode(
                      GaiLegacyWorkspaceDTO.self,
                      from: itemData)
            else { return nil }
            return workspace
        }
    }

    static func migrate(_ workspaces: [GaiLegacyWorkspaceDTO]) -> [GaiCompanionRecord] {
        var records: [GaiCompanionRecord] = []
        var usedIDs: Set<UUID> = []

        func append(
            preferredID: UUID?,
            name: String? = nil,
            colorway: GaiCompanionColorway,
            directoryPath: String?,
            fallbackDirectoryPath: String?,
            launchCommand: String?
        ) {
            guard records.count < maximumMigratedCompanions else { return }
            let id = uniqueID(preferred: preferredID, used: &usedIDs)
            records.append(GaiCompanionRecord(
                id: id,
                name: name,
                colorway: colorway,
                directoryPath: directoryPath
                    ?? fallbackDirectoryPath
                    ?? GaiCompanionRecord.defaultDirectoryPath,
                launchCommand: launchCommand))
        }

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            guard records.count < maximumMigratedCompanions else { break }
            let colorway = migratedColorway(
                from: workspace.colorHex,
                fallbackIndex: workspaceIndex)
            let panes = workspace.paneLayout?.flattenedPanes ?? []

            if !panes.isEmpty {
                for pane in panes {
                    append(
                        preferredID: pane.id,
                        name: pane.name,
                        colorway: colorway,
                        directoryPath: pane.directoryPath,
                        fallbackDirectoryPath: workspace.directoryPath,
                        launchCommand: pane.command)
                }
                continue
            }

            if workspace.perTerminalFolders == true,
               let terminals = workspace.terminals,
               !terminals.isEmpty {
                for terminal in terminals {
                    append(
                        preferredID: terminal.id,
                        colorway: colorway,
                        directoryPath: terminal.directoryPath,
                        fallbackDirectoryPath: workspace.directoryPath,
                        launchCommand: terminal.cli == "shell" ? nil : terminal.cli)
                }
                continue
            }

            let commands = expandedLegacyCommands(workspace.cliCounts ?? [:])
            if commands.isEmpty {
                append(
                    preferredID: nil,
                    colorway: colorway,
                    directoryPath: workspace.directoryPath,
                    fallbackDirectoryPath: nil,
                    launchCommand: workspace.defaultCommand)
            } else {
                for command in commands {
                    append(
                        preferredID: nil,
                        colorway: colorway,
                        directoryPath: workspace.directoryPath,
                        fallbackDirectoryPath: nil,
                        launchCommand: command)
                }
            }
        }

        applyNormalizedGridPositions(to: &records)
        return records
    }

    static func deduplicatingIDs(
        in records: [GaiCompanionRecord]
    ) -> [GaiCompanionRecord] {
        var result: [GaiCompanionRecord] = []
        var usedIDs: Set<UUID> = []
        result.reserveCapacity(records.count)
        for record in records {
            let id = uniqueID(preferred: record.id, used: &usedIDs)
            if id == record.id {
                result.append(record)
            } else {
                result.append(GaiCompanionRecord(
                    id: id,
                    name: record.name,
                    colorway: record.colorway,
                    directoryPath: record.directoryPath,
                    launchCommand: record.launchCommand,
                    normalizedPosition: record.normalizedPosition,
                    displayID: record.displayID,
                    compactSize: record.compactSize,
                    scalePercent: record.scalePercent,
                    completionSoundEnabled: record.completionSoundEnabled))
            }
        }
        return result
    }

    static func uniqueID(preferred: UUID?, used: inout Set<UUID>) -> UUID {
        if let preferred, used.insert(preferred).inserted {
            return preferred
        }
        var generated = UUID()
        while !used.insert(generated).inserted {
            generated = UUID()
        }
        return generated
    }

    static func expandedLegacyCommands(_ counts: [String: Int]) -> [String] {
        let known = Set(legacyCLIOrder)
        let orderedKeys = legacyCLIOrder + counts.keys.filter { !known.contains($0) }.sorted()
        var commands: [String] = []
        for command in orderedKeys {
            let count = min(max(counts[command] ?? 0, 0), maximumMigratedCompanions)
            let remaining = maximumMigratedCompanions - commands.count
            guard remaining > 0 else { break }
            commands.append(contentsOf: repeatElement(command, count: min(count, remaining)))
        }
        return commands
    }

    static func applyNormalizedGridPositions(to records: inout [GaiCompanionRecord]) {
        guard !records.isEmpty else { return }
        let columns = max(1, Int(ceil(sqrt(Double(records.count)))))
        let rows = max(1, Int(ceil(Double(records.count) / Double(columns))))
        for index in records.indices {
            let column = index % columns
            let row = index / columns
            records[index].normalizedPosition = GaiCompanionNormalizedPosition(
                x: (Double(column) + 0.5) / Double(columns),
                y: (Double(row) + 0.5) / Double(rows))
        }
    }

    static func migratedColorway(
        from hex: String?,
        fallbackIndex: Int
    ) -> GaiCompanionColorway {
        guard let rgb = rgbComponents(from: hex) else {
            let colorways = GaiCompanionColorway.selectableColorways
            return colorways[fallbackIndex % colorways.count]
        }

        return GaiCompanionColorway.selectableColorways.min { lhs, rhs in
            colorDistance(rgb, lhs.baseRGB) < colorDistance(rgb, rhs.baseRGB)
        } ?? .defaultColorway
    }

    static func rgbComponents(from hex: String?) -> (Double, Double, Double)? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return (
            Double((number >> 16) & 0xFF),
            Double((number >> 8) & 0xFF),
            Double(number & 0xFF))
    }

    static func colorDistance(
        _ lhs: (Double, Double, Double),
        _ rhs: (Double, Double, Double)
    ) -> Double {
        let red = lhs.0 - rhs.0
        let green = lhs.1 - rhs.1
        let blue = lhs.2 - rhs.2
        return red * red + green * green + blue * blue
    }
}

private extension GaiCompanionColorway {
    var baseRGB: (Double, Double, Double) {
        switch self {
        case .aurore: return (0x83, 0xCF, 0x8C)
        case .blue: return (0x52, 0x77, 0xEC)
        case .purple: return (0x94, 0x60, 0xE2)
        case .black: return (0x20, 0x26, 0x31)
        case .yellow: return (0xE8, 0xB8, 0x17)
        case .orange: return (0xF2, 0x7B, 0x25)
        case .red: return (0xD5, 0x2F, 0x3F)
        case .gray: return (0x64, 0x70, 0x8B)
        case .white: return (0xDD, 0xE4, 0xEF)
        }
    }
}

private struct GaiLegacyWorkspaceDTO: Decodable {
    let colorHex: String?
    let directoryPath: String?
    let defaultCommand: String?
    let cliCounts: [String: Int]?
    let paneLayout: GaiLegacyPaneLayoutDTO?
    let perTerminalFolders: Bool?
    let terminals: [GaiLegacyTerminalSpecDTO]?
}

private struct GaiLegacyTerminalSpecDTO: Decodable {
    let id: UUID?
    let cli: String
    let directoryPath: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case cli
        case directoryPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lossyUUID(forKey: .id)
        cli = (try? container.decode(String.self, forKey: .cli)) ?? "shell"
        directoryPath = try? container.decodeIfPresent(String.self, forKey: .directoryPath)
    }
}

private struct GaiLegacyPaneDTO: Decodable {
    let id: UUID?
    let name: String?
    let directoryPath: String?
    let command: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case directoryPath
        case command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lossyUUID(forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        directoryPath = try? container.decodeIfPresent(String.self, forKey: .directoryPath)
        command = try? container.decodeIfPresent(String.self, forKey: .command)
    }
}

private indirect enum GaiLegacyPaneLayoutDTO: Decodable {
    case pane(GaiLegacyPaneDTO)
    case split(GaiLegacyPaneLayoutDTO?, GaiLegacyPaneLayoutDTO?)
    case empty

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case left
        case right
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try? container.decode(String.self, forKey: .type)
        if type == "pane", let pane = try? container.decode(GaiLegacyPaneDTO.self, forKey: .pane) {
            self = .pane(pane)
            return
        }
        if type == "split" || container.contains(.left) || container.contains(.right) {
            self = .split(
                try? container.decode(GaiLegacyPaneLayoutDTO.self, forKey: .left),
                try? container.decode(GaiLegacyPaneLayoutDTO.self, forKey: .right))
            return
        }
        if let pane = try? container.decode(GaiLegacyPaneDTO.self, forKey: .pane) {
            self = .pane(pane)
        } else {
            self = .empty
        }
    }

    var flattenedPanes: [GaiLegacyPaneDTO] {
        switch self {
        case .pane(let pane): return [pane]
        case .split(let left, let right):
            return (left?.flattenedPanes ?? []) + (right?.flattenedPanes ?? [])
        case .empty: return []
        }
    }
}

private extension KeyedDecodingContainer {
    func lossyUUID(forKey key: Key) -> UUID? {
        if let value = try? decode(UUID.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return UUID(uuidString: value) }
        return nil
    }
}
#endif
