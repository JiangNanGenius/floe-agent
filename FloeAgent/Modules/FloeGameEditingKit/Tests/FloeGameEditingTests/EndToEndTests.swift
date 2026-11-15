// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameEditingCore

/// A minimal real adapter: asset kinds + parameter schema + tile/narrative
/// codecs bound to the editor staging formats. Mirrors what an engine owner
/// (e.g. FloeRPGProjectKit) provides for its native formats.
private struct DemoAdapter: GameEditingAdapter {
    let engine: GameEngineID = .phaser
    func assetKind(for path: GameRelativePath, in project: GameStoredProject) -> GameAssetKind? {
        if path.value.hasSuffix(".png") { return .image }
        if path.value.hasSuffix(".floetilemap.json") { return .map }
        if path.value.hasSuffix(".lua") { return .script }
        if path.value.hasSuffix(".json") { return .data }
        return nil
    }
    func parameterSchemas(in project: GameStoredProject) -> [GameParameterSchema] {
        [TestSupport.sampleSchema()]
    }
    func tileMapBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameTileMapBinding? {
        guard path.value.hasSuffix(".floetilemap.json") else { return nil }
        return GameTileMapBinding(decode: { try EditableTileMap.decode($0) },
                                  encode: { try $0.encode() })
    }
    func narrativeBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameNarrativeBinding? {
        guard path.value.hasSuffix(".json"), path.value.contains("events") else { return nil }
        return GameNarrativeBinding(
            knownCommands: [GameNarrativeCommandSpec(code: "dialog", title: GameEditCopy("Dialog", "对话"), fields: [])],
            decode: { try NarrativeDocument.decode($0) },
            encode: { try $0.encode() })
    }
}

@Suite("End-to-end editing across all four families")
struct EndToEndTests {
    @Test("Adapter registry rejects duplicates and resolves adapters")
    @MainActor
    func registry() async throws {
        var registry = GameEditingAdapterRegistry()
        try registry.register(DemoAdapter())
        #expect(registry.adapter(for: .phaser) != nil)
        do {
            try registry.register(DemoAdapter())
            Issue.record("Duplicate adapter registration must fail")
        } catch GameProjectError.duplicateAdapter(let engine) {
            #expect(engine == .phaser)
        }
    }

    @Test("All four editor families edit one shared repository revision")
    @MainActor
    func fullRoundTrip() async throws {
        let (_, repository) = try TestSupport.makeRepository(name: "e2e")
        let projectRoot = try TestSupport.makeTemporaryDirectory("e2e-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample", engine: .phaser)
        let session = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: DemoAdapter())

        // 1. Asset family: import + rename with reference updates.
        _ = try await session.importAssets([(name: "coin.png", bytes: TestSupport.pngData(side: 4, rgb: (250, 210, 60)))],
                                           into: "assets")
        let renamePlan = try await session.renameAsset(at: try GameRelativePath("assets/coin.png"), newName: "gold.png")
        #expect(renamePlan.to.value == "assets/gold.png")

        // 2. Parameter family: schema-bound edit on characters.json.
        let charactersPath = try GameRelativePath("data/characters.json")
        try await session.editDocument(at: charactersPath,
            summary: GameEditCopy("Set level", "设置等级")) { bytes in
            var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
            try document.set(.number(7), for: document.schema.fields[1])
            return try document.serialized()
        }

        // 3. Tile family: paint + fill + object via the adapter binding.
        let mapPath = try GameRelativePath("maps/home.floetilemap.json")
        try await session.editDocument(at: mapPath, summary: GameEditCopy("Paint map", "绘制地图")) { bytes in
            guard let binding = session.adapter.tileMapBinding(for: mapPath, in: session.baseProject) else {
                throw GameProjectError.unsupportedRoute(.phaser)
            }
            var map = try binding.decode(bytes)
            let ground = map.layers[0].id
            map = map.paintingStroke(gid: 1, from: (0, 0), to: (4, 4), layerID: ground)
            map = map.filling(gid: 2, fromX: 7, y: 5, layerID: ground)
            map = map.placingObject(.init(name: "chest", x: 32, y: 32, width: 16, height: 16),
                                    layerID: map.layers[1].id)
            return try binding.encode(map)
        }

        // 4. Narrative family: reorder + insert + branch link.
        let narrativePath = try GameRelativePath("events/intro.json")
        try await session.editDocument(at: narrativePath, summary: GameEditCopy("Edit events", "编辑事件")) { bytes in
            guard let binding = session.adapter.narrativeBinding(for: narrativePath, in: session.baseProject) else {
                throw GameProjectError.unsupportedRoute(.phaser)
            }
            var narrative = try binding.decode(bytes)
            let label = narrative.addingLabel(name: "second")
            narrative = label
            if let labelID = narrative.labels.first(where: { $0.name == "second" })?.id {
                narrative = narrative.inserting(.init(code: "branch", branchRole: .open, labelID: labelID),
                                                at: narrative.commands.count)
                narrative = narrative.inserting(.init(code: "branchEnd", branchRole: .close),
                                                at: narrative.commands.count)
            }
            return try binding.encode(narrative)
        }

        #expect(session.history.count >= 4)
        let saved = try await session.save()
        #expect(!session.isDirty)

        // Reopen from the repository and verify every family persisted.
        let reopened = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: DemoAdapter())
        #expect(reopened.expectedRevision == saved.revision)

        let characterBytes = try await reopened.documentBytes(at: charactersPath)
        let character = try ParameterDocument(bytes: characterBytes, schema: TestSupport.sampleSchema())
        #expect(character.value(for: character.schema.fields[1]) == .number(7))

        let mapBytes = try await reopened.documentBytes(at: mapPath)
        let map = try EditableTileMap.decode(mapBytes)
        #expect(map.layers[0].tileAt(x: 0, y: 0) == 1)
        #expect(map.layers[0].tileAt(x: 7, y: 5) == 2)
        #expect(map.layers[1].objects.contains { $0.name == "chest" })

        let narrativeBytes = try await reopened.documentBytes(at: narrativePath)
        let narrative = try NarrativeDocument.decode(narrativeBytes)
        #expect(narrative.labels.contains { $0.name == "second" })
        // Branch/link validation is clean; the preserved unsupported plugin
        // command intentionally remains as an informational issue.
        let issues = narrative.validationIssues()
        #expect(!issues.contains { $0.kind == .unbalancedOpen || $0.kind == .unbalancedClose
            || $0.kind == .danglingBranchLink || $0.kind == .duplicateLabelName })
        #expect(issues.contains { $0.kind == .unsupportedCommandPresent })

        #expect(reopened.documentExists(at: try GameRelativePath("assets/gold.png")))
        #expect(reopened.documentExists(at: try GameRelativePath("assets/coin.png")) == false)
    }
}
