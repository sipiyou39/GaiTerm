#if DEBUG
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct GaiCompanionStoreTests {
    @Test func greenIsReservedForCompletionAndCannotBePersistedAsAnAgentColor() {
        #expect(GaiCompanionColorway.completionColorway == .aurore)
        #expect(!GaiCompanionColorway.selectableColorways.contains(.aurore))
        #expect(GaiCompanionColorway.selectableColorways.count == 8)
        #expect(GaiCompanionColorway.defaultColorway != .aurore)

        let record = GaiCompanionRecord(colorway: .aurore)
        #expect(record.colorway == .defaultColorway)
        #expect(record.colorway.isSelectable)
    }

    @Test func loadingAnOldGreenAgentMigratesAndPersistsItsNormalColor() throws {
        let context = defaultsContext()
        defer { context.clear() }
        let id = UUID()
        let payload: [[String: Any]] = [[
            "id": id.uuidString,
            "name": "Legacy green agent",
            "colorway": "aurore",
            "directoryPath": "/tmp",
            "normalizedPosition": ["x": 0.5, "y": 0.5],
            "compactSize": ["width": 480, "height": 300],
        ]]
        context.defaults.set(
            try JSONSerialization.data(withJSONObject: payload),
            forKey: GaiCompanionStore.defaultPersistenceKey)

        let store = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)
        #expect(store.load() == .loaded(1))
        #expect(store.companions.first?.colorway == .defaultColorway)

        let persistedData = try #require(
            context.defaults.data(forKey: GaiCompanionStore.defaultPersistenceKey))
        let persistedObject = try #require(
            JSONSerialization.jsonObject(with: persistedData) as? [[String: Any]])
        #expect(persistedObject.first?["colorway"] as? String
            == GaiCompanionColorway.defaultColorway.rawValue)
    }

    @Test func recordRoundTripsAndNormalizesGeometry() throws {
        let id = UUID()
        let record = GaiCompanionRecord(
            id: id,
            name: " Nova ",
            colorway: .purple,
            directoryPath: "~/Project",
            launchCommand: " codex ",
            normalizedPosition: .init(x: -2, y: 4),
            displayID: " display-1 ",
            compactSize: .init(width: 10, height: 9_000),
            scalePercent: .init(275),
            completionSoundEnabled: false)

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(GaiCompanionRecord.self, from: data)

        #expect(decoded.id == id)
        #expect(decoded.name == "Nova")
        #expect(decoded.displayName == "Nova")
        #expect(decoded.colorway == .purple)
        #expect(decoded.directoryPath.hasSuffix("/Project"))
        #expect(decoded.launchCommand == "codex")
        #expect(decoded.normalizedPosition == .init(x: 0, y: 1))
        #expect(decoded.displayID == "display-1")
        #expect(decoded.compactSize == .init(width: 320, height: 1_200))
        #expect(decoded.scalePercent == .init(200))
        #expect(decoded.completionSoundEnabled == false)
    }

    @Test func recordNameNormalizesAndCapsAtFortyCharacters() {
        let longName = String(repeating: "A", count: 45)
        let longRecord = GaiCompanionRecord(name: "  \(longName)  ")
        #expect(longRecord.name == String(repeating: "A", count: 40))
        #expect(longRecord.displayName == String(repeating: "A", count: 40))

        let unnamedRecord = GaiCompanionRecord(name: " \n\t ")
        #expect(unnamedRecord.name == nil)
        #expect(unnamedRecord.displayName == "Agent")

        var mutatedRecord = GaiCompanionRecord(name: "Nova")
        mutatedRecord.name = "  Atlas  "
        #expect(mutatedRecord.normalized().name == "Atlas")
    }

    @Test func scaleClampsToSupportedRange() throws {
        #expect(GaiCompanionScalePercent(49).value == 50)
        #expect(GaiCompanionScalePercent(50).value == 50)
        #expect(GaiCompanionScalePercent(125).value == 125)
        #expect(GaiCompanionScalePercent(200).value == 200)
        #expect(GaiCompanionScalePercent(201).value == 200)

        let decodedBelowRange = try JSONDecoder().decode(
            GaiCompanionScalePercent.self,
            from: Data("-100".utf8))
        let decodedAboveRange = try JSONDecoder().decode(
            GaiCompanionScalePercent.self,
            from: Data("500".utf8))
        #expect(decodedBelowRange.value == 50)
        #expect(decodedAboveRange.value == 200)
        #expect(GaiCompanionVisualMetrics.scaledPanelWidth(for: .init(50)) == 71)
        #expect(GaiCompanionVisualMetrics.scaledPanelHeight(for: .init(100)) == 158)
        #expect(GaiCompanionVisualMetrics.scaledSpriteWidth(for: .init(200)) == 224)
    }

    @Test func decodingPersistedLegacyRecordUsesNewSettingDefaults() throws {
        let id = UUID()
        let payload: [String: Any] = [
            "id": id.uuidString,
            "colorway": "blue",
            "directoryPath": "/tmp/legacy",
            "normalizedPosition": ["x": 0.25, "y": 0.75],
            "compactSize": ["width": 480, "height": 300],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder().decode(GaiCompanionRecord.self, from: data)

        #expect(decoded.id == id)
        #expect(decoded.name == nil)
        #expect(decoded.displayName == "Agent")
        #expect(decoded.scalePercent == .standard)
        #expect(decoded.scalePercent.value == 100)
        #expect(decoded.completionSoundEnabled == true)
    }

    @Test func loadingUnnamedRecordsGeneratesStableCollisionFreeNamesAndPersistsThem() throws {
        let context = defaultsContext()
        defer { context.clear() }
        let records = [
            GaiCompanionRecord(name: "agent 1"),
            GaiCompanionRecord(),
            GaiCompanionRecord(name: "AGENT 3"),
            GaiCompanionRecord(),
        ]
        context.defaults.set(
            try JSONEncoder().encode(records),
            forKey: GaiCompanionStore.defaultPersistenceKey)

        let store = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)
        #expect(store.load() == .loaded(4))
        #expect(store.companions.map(\.displayName) == [
            "agent 1", "Agent 2", "AGENT 3", "Agent 4",
        ])

        let persistedData = try #require(
            context.defaults.data(forKey: GaiCompanionStore.defaultPersistenceKey))
        let persistedObject = try #require(
            JSONSerialization.jsonObject(with: persistedData) as? [[String: Any]])
        #expect(persistedObject.compactMap { $0["name"] as? String } == [
            "agent 1", "Agent 2", "AGENT 3", "Agent 4",
        ])

        let reloaded = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)
        #expect(reloaded.load() == .loaded(4))
        #expect(reloaded.companions.map(\.displayName) == [
            "agent 1", "Agent 2", "AGENT 3", "Agent 4",
        ])
    }

    @Test func createGeneratesTheFirstAvailableNameCaseInsensitively() {
        let context = defaultsContext()
        defer { context.clear() }
        let store = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)

        let first = store.create(name: "AGENT 1")
        let second = store.create()
        let third = store.create(name: "  Nova  ")
        let fourth = store.create(name: "   ")

        #expect(first.name == "AGENT 1")
        #expect(second.name == "Agent 2")
        #expect(third.name == "Nova")
        #expect(fourth.name == "Agent 3")
    }

    @Test func duplicateColorwaysRemainIndependentInstances() {
        let context = defaultsContext()
        defer { context.clear() }
        let store = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)

        let first = store.create(colorway: .blue, directoryPath: "/tmp/one")
        let second = store.create(colorway: .blue, directoryPath: "/tmp/two")

        #expect(first.id != second.id)
        #expect(store.companions.count == 2)
        #expect(store.companions.allSatisfy { $0.colorway == .blue })
    }

    @Test func storeCreatesUpdatesRemovesAndReloads() {
        let context = defaultsContext()
        defer { context.clear() }
        let store = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)
        let created = store.create(
            name: "Nova",
            colorway: .orange,
            directoryPath: "/tmp/old",
            scalePercent: .init(135),
            completionSoundEnabled: false)

        let updated = store.update(id: created.id) { record in
            record.name = "  Atlas  "
            record.directoryPath = "/tmp/new"
            record.normalizedPosition = .init(x: 0.25, y: 0.75)
            record.scalePercent = .init(175)
        }
        #expect(updated?.name == "Atlas")
        #expect(updated?.directoryPath == "/tmp/new")
        #expect(updated?.scalePercent == .init(175))
        #expect(updated?.completionSoundEnabled == false)

        let reloaded = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)
        #expect(reloaded.load() == .loaded(1))
        #expect(reloaded.companions.first?.id == created.id)
        #expect(reloaded.companions.first?.name == "Atlas")
        #expect(reloaded.companions.first?.normalizedPosition == .init(x: 0.25, y: 0.75))
        #expect(reloaded.companions.first?.scalePercent == .init(175))
        #expect(reloaded.companions.first?.completionSoundEnabled == false)

        #expect(reloaded.remove(id: created.id)?.id == created.id)
        #expect(reloaded.companions.isEmpty)
        #expect(reloaded.remove(id: created.id) == nil)
    }

    @Test func duplicateIDRepairPreservesEachRecordName() throws {
        let context = defaultsContext()
        defer { context.clear() }
        let duplicateID = UUID()
        let records = [
            GaiCompanionRecord(id: duplicateID, name: "Nova", colorway: .blue),
            GaiCompanionRecord(id: duplicateID, name: "Atlas", colorway: .red),
        ]
        context.defaults.set(
            try JSONEncoder().encode(records),
            forKey: GaiCompanionStore.defaultPersistenceKey)

        let store = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)
        #expect(store.load() == .loaded(2))
        #expect(Set(store.companions.map(\.id)).count == 2)
        #expect(store.companions.map(\.displayName) == ["Nova", "Atlas"])
    }

    @Test func migratesSplitPanesAndPersistsTheResultOnce() throws {
        let context = defaultsContext()
        defer { context.clear() }
        let firstID = UUID()
        let secondID = UUID()
        let pane: (UUID, String, String, String) -> [String: Any] = {
            id, name, directory, command in
            [
                "type": "pane",
                "pane": [
                    "id": id.uuidString,
                    "name": name,
                    "directoryPath": directory,
                    "command": command,
                    "notificationsEnabled": true,
                    "autoFocusOnNotification": false,
                ],
            ]
        }
        let payload: [[String: Any]] = [[
            "name": "Legacy workspace",
            "colorHex": "D52F3F",
            "directoryPath": "/tmp/fallback",
            "defaultCommand": "claude",
            "cliCounts": [String: Int](),
            "startupCommand": "npm run dev",
            "notifyOnInput": false,
            "openAtLaunch": true,
            "paneLayout": [
                "type": "split",
                "direction": "horizontal",
                "ratio": 0.5,
                "left": pane(firstID, "Nova", "/tmp/one", "codex"),
                "right": pane(secondID, "Atlas", "/tmp/two", "claude"),
            ],
            "perTerminalFolders": false,
            "terminals": [[String: Any]](),
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        context.defaults.set(data, forKey: GaiCompanionStore.defaultLegacyWorkspaceKey)

        let store = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)
        #expect(store.load() == .migrated(2))
        #expect(Set(store.companions.map(\.id)) == [firstID, secondID])
        #expect(store.companions.map(\.displayName) == ["Nova", "Atlas"])
        #expect(store.companions.allSatisfy { $0.colorway == .red })
        #expect(Set(store.companions.map(\.directoryPath)) == ["/tmp/one", "/tmp/two"])
        #expect(Set(store.companions.compactMap(\.launchCommand)) == ["codex", "claude"])
        #expect(store.companions.map(\.scalePercent) == [.standard, .standard])
        #expect(store.companions.map(\.completionSoundEnabled) == [true, true])

        let secondLoad = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)
        #expect(secondLoad.load() == .loaded(2))
        #expect(secondLoad.companions.map(\.displayName) == ["Nova", "Atlas"])
    }

    @Test func migratesPerTerminalFoldersAndPlainShells() throws {
        let context = defaultsContext()
        defer { context.clear() }
        let payload: [[String: Any]] = [[
            "name": "Worktrees",
            "directoryPath": "/tmp/fallback",
            "defaultCommand": "codex",
            "cliCounts": ["codex": 4],
            "notifyOnInput": false,
            "openAtLaunch": false,
            "perTerminalFolders": true,
            "terminals": [
                ["id": UUID().uuidString, "cli": "shell", "directoryPath": "/tmp/shell"],
                ["id": UUID().uuidString, "cli": "claude", "directoryPath": "/tmp/claude"],
            ],
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        context.defaults.set(data, forKey: GaiCompanionStore.defaultLegacyWorkspaceKey)

        let store = GaiCompanionStore(userDefaults: context.defaults, loadImmediately: false)
        #expect(store.load() == .migrated(2))
        #expect(store.companions.map(\.displayName) == ["Agent 1", "Agent 2"])
        #expect(store.companions.first?.launchCommand == nil)
        #expect(store.companions.last?.launchCommand == "claude")
        #expect(store.companions.map(\.scalePercent.value) == [100, 100])
        #expect(store.companions.map(\.completionSoundEnabled) == [true, true])
    }

    private func defaultsContext() -> DefaultsContext {
        let suite = "com.sipiyou.gaiterm.tests.companions.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Unable to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return DefaultsContext(defaults: defaults, suite: suite)
    }
}

private struct DefaultsContext {
    let defaults: UserDefaults
    let suite: String

    func clear() {
        defaults.removePersistentDomain(forName: suite)
    }
}
#endif
