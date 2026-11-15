// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeRPGCore
@testable import FloeGameCore
@testable import FloeGameEditingCore

final class AdapterBridgeTests: XCTestCase {
    @MainActor func testCapturedEditorIDsApplyAfterFreshDecodeAndSave() async throws {
        for (engine, fixture, mapName) in [(RPGEngine.rpgMakerXP, "xp-project", "Data/Map001.rxdata"), (.rpgMakerMV, "mv-project", "data/Map001.json")] {
            let (repository, id, owner, project) = try await Self.makeProject(root: Fixture.url(fixture), engine: engine, title: fixture)
            let adapter = RPGEditingAdapter(engine: engine)
            let path = try GameRelativePath(mapName)
            let session = try await GameEditingSession.open(repository: repository, projectID: id, owner: owner, adapter: adapter)
            let original = try await session.documentBytes(at: path)
            let displayedMap = try XCTUnwrap(adapter.tileMapBinding(for: path, in: project)).decode(original)
            let freshMap = try XCTUnwrap(adapter.tileMapBinding(for: path, in: project)).decode(original)
            XCTAssertEqual(displayedMap.layers.map(\.id), freshMap.layers.map(\.id))
            XCTAssertEqual(Set(displayedMap.layers.map(\.id)).count, displayedMap.layers.count)
            let layerID = try XCTUnwrap(displayedMap.layers.first?.id)
            try await session.editTileMapDocument(at: path, binding: adapter.tileMapBinding(for: path, in: project), summary: .init("Paint", "绘制")) { map in
                map.apply(.paint(gid: 745, x: 1, y: 1, layerID: layerID))
            }
            let mapBytes = try await session.documentBytes(at: path)
            XCTAssertEqual(try RPGMapDocument.decode(mapBytes, engine: engine, pathName: mapName).tile(x: 1, y: 1, z: 0), 745)
            let displayedStory = try XCTUnwrap(adapter.narrativeBinding(for: path, in: project)).decode(mapBytes)
            let freshStory = try XCTUnwrap(adapter.narrativeBinding(for: path, in: project)).decode(mapBytes)
            XCTAssertEqual(displayedStory.commands.map(\.id), freshStory.commands.map(\.id))
            XCTAssertEqual(Set(displayedStory.commands.map(\.id)).count, displayedStory.commands.count)
            XCTAssertEqual(displayedStory.labels.map(\.id), freshStory.labels.map(\.id))
            XCTAssertEqual(Set(displayedStory.labels.map(\.id)).count, displayedStory.labels.count)
            let row = try XCTUnwrap(displayedStory.commands.first { $0.code == "401" })
            try await session.editNarrativeDocument(at: path, binding: adapter.narrativeBinding(for: path, in: project), summary: .init("Dialogue", "对白")) { story in
                story = story.updating(id: row.id) { $0.parameters["text"] = .string("Saved after a fresh decode") }
            }
            let saved = try await session.save()
            let reopened = try await repository.read(id, owner: owner, revision: saved.revision, path: path)
            XCTAssertEqual(try RPGMapDocument.decode(reopened, engine: engine, pathName: mapName).tile(x: 1, y: 1, z: 0), 745)
            let reopenedStory = try XCTUnwrap(adapter.narrativeBinding(for: path, in: saved)).decode(reopened)
            XCTAssertEqual(reopenedStory.commands.first { $0.code == "401" }?.parameters["text"]?.stringValue, "Saved after a fresh decode")
            XCTAssertEqual(reopenedStory.commands.count, displayedStory.commands.count)
        }
    }
    func testNarrativeBridgeExposesWritableTextFields() async throws {
        for (engine, fixture, mapName) in [(RPGEngine.rpgMakerXP, "xp-project", "Data/Map001.rxdata"), (.rpgMakerMV, "mv-project", "data/Map001.json")] {
            let (_, _, _, project) = try await Self.makeProject(root: Fixture.url(fixture), engine: engine, title: fixture)
            let binding = try XCTUnwrap(RPGEditingAdapter(engine: engine).narrativeBinding(for: GameRelativePath(mapName), in: project))
            let dialogue = try XCTUnwrap(binding.knownCommands.first { $0.code == "401" })
            XCTAssertEqual(dialogue.fields.count, 1)
            XCTAssertEqual(dialogue.fields.first?.path, JSONFieldPath([.key("text")]))
            XCTAssertEqual(dialogue.fields.first?.kind, .text)
            XCTAssertEqual(binding.knownCommands.first { $0.code == "355" }?.fields.first?.kind, .multiline)
            // The bridge must not expose a form for parameters its codec
            // would ignore on save.
            XCTAssertTrue(try XCTUnwrap(binding.knownCommands.first { $0.code == "121" }).fields.isEmpty)
        }
    }
    private static func makeProject(root: URL, engine: RPGEngine, title: String) async throws -> (FileGameProjectRepository, UUID, GameProjectOwner, GameStoredProject) {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeRPGAdapterTests-" + UUID().uuidString)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let repository = try FileGameProjectRepository(directory: store)
        let project = try await repository.importProject(from: root, projectID: id, owner: owner,
                                                         title: title, engine: engine.gameEngineID)
        return (repository, id, owner, project)
    }

    func testAssetClassification() {
        let adapter = RPGEditingAdapter(engine: .rpgMakerXP)
        let project = GameStoredProject(version: 1, projectID: UUID(), owner: .space(recordID: UUID()),
                                        revision: "r", parent: nil, title: "t", engine: .rpgMakerXP,
                                        directories: [], files: [])
        func kind(_ path: String) -> GameAssetKind? {
            try? adapter.assetKind(for: GameRelativePath(path), in: project)
        }
        XCTAssertEqual(kind("Data/Actors.rxdata"), .data)
        XCTAssertEqual(kind("Data/Map001.rxdata"), .map)
        XCTAssertEqual(kind("Graphics/Characters/hero_1.png"), .image)
        XCTAssertEqual(kind("Audio/BGM/title_theme.ogg"), .audio)
        XCTAssertEqual(kind("Data/Scripts.rxdata"), .data)
    }

    func testParameterSchemasExistForAllEditableFiles() async throws {
        let (repository, id, owner, project) = try await Self.makeProject(
            root: Fixture.url("xp-project"), engine: .rpgMakerXP, title: "XP")
        let adapter = RPGEditingAdapter(engine: .rpgMakerXP)
        // No cross-file schema leakage: the all-files list stays empty and
        // the per-file list returns only that file.
        XCTAssertEqual(adapter.parameterSchemas(in: project), [])
        XCTAssertEqual(adapter.parameterSchemas(for: try GameRelativePath("Data/Actors.rxdata"), in: project).map(\.id),
                       ["rxdata:Data/Actors.rxdata"])
        XCTAssertEqual(adapter.parameterSchemas(for: try GameRelativePath("Data/Items.rxdata"), in: project).map(\.id),
                       ["rxdata:Data/Items.rxdata"])
        // Binary binding roundtrip: bytes -> interchange JSON -> bytes.
        let path = try GameRelativePath("Data/Actors.rxdata")
        let binding = try XCTUnwrap(adapter.parameterBinding(for: path, in: project))
        let original = try await repository.read(id, owner: owner, revision: project.revision, path: path)
        let interchange = try binding.decodeDataToJSON(original)
        let restored = try binding.encodeJSONToData(interchange)
        XCTAssertEqual(restored, original, "parameter codec must be lossless")
        // Schema paths resolve inside the interchange document.
        let schema = try XCTUnwrap(adapter.schema(for: try GameRelativePath("Data/Actors.rxdata"), in: project))
        let root = try JSONValue.parse(interchange)
        let nameField = try XCTUnwrap(schema.fields.first(where: { $0.label.en == "Name" }))
        XCTAssertEqual(nameField.path.lookup(in: root)?.stringValue, "Kestrel")
        _ = repository
    }

    func testMVParameterSchemaPathsResolve() async throws {
        let (_, _, _, project) = try await Self.makeProject(
            root: Fixture.url("mv-project"), engine: .rpgMakerMV, title: "MV")
        let adapter = RPGEditingAdapter(engine: .rpgMakerMV)
        XCTAssertEqual(adapter.parameterSchemas(in: project), [])
        XCTAssertEqual(adapter.parameterSchemas(for: try GameRelativePath("data/Actors.json"), in: project).map(\.id),
                       ["json:data/Actors.json"])
        let actors = try XCTUnwrap(adapter.schema(for: try GameRelativePath("data/Actors.json"), in: project))
        let bytes = try Fixture.data("mv-project/data/Actors.json")
        let root = try JSONValue.parse(bytes)
        let name = try XCTUnwrap(actors.fields.first(where: { $0.label.en == "Name" }))
        XCTAssertEqual(name.path.lookup(in: root)?.stringValue, "Kestrel")
        let level = try XCTUnwrap(actors.fields.first(where: { $0.label.en == "Initial level" }))
        XCTAssertEqual(level.path.lookup(in: root)?.intValue, 1)
    }

    func testTileMapBindingRoundTripForXPAndMV() async throws {
        // XP binary map.
        let (repoXP, idXP, ownerXP, projectXP) = try await Self.makeProject(
            root: Fixture.url("xp-project"), engine: .rpgMakerXP, title: "XP")
        let adapterXP = RPGEditingAdapter(engine: .rpgMakerXP)
        let pathXP = try GameRelativePath("Data/Map001.rxdata")
        let bindingXP = try XCTUnwrap(adapterXP.tileMapBinding(for: pathXP, in: projectXP))
        let originalXP = try await repoXP.read(idXP, owner: ownerXP, revision: projectXP.revision, path: pathXP)
        let tileMapXP = try bindingXP.decode(originalXP)
        XCTAssertEqual(tileMapXP.mapSize.width, 20)
        XCTAssertEqual(tileMapXP.layers.count, 4) // 3 tile layers + events
        XCTAssertEqual(tileMapXP.layers[3].objects.count, 2)
        let paintedXP = tileMapXP.painting(gid: 432, atX: 1, y: 1, layerID: tileMapXP.layers[0].id)
        let reencodedXP = try bindingXP.encode(paintedXP)
        let rereadXP = try RPGMapDocument.decode(reencodedXP, engine: .rpgMakerXP, pathName: "Map001.rxdata")
        XCTAssertEqual(rereadXP.tile(x: 1, y: 1, z: 0), 432)
        XCTAssertEqual(rereadXP.tile(x: 2, y: 2, z: 0), (2 + 2) % 8, "untouched cells unchanged")

        // MV JSON map.
        let (repoMV, idMV, ownerMV, projectMV) = try await Self.makeProject(
            root: Fixture.url("mv-project"), engine: .rpgMakerMV, title: "MV")
        let adapterMV = RPGEditingAdapter(engine: .rpgMakerMV)
        let pathMV = try GameRelativePath("data/Map001.json")
        let bindingMV = try XCTUnwrap(adapterMV.tileMapBinding(for: pathMV, in: projectMV))
        let originalMV = try await repoMV.read(idMV, owner: ownerMV, revision: projectMV.revision, path: pathMV)
        let tileMapMV = try bindingMV.decode(originalMV)
        XCTAssertEqual(tileMapMV.mapSize.width, 6)
        XCTAssertEqual(tileMapMV.layers.count, 5) // 4 tile layers + events
        let moved = tileMapMV.movingObject(id: tileMapMV.layers[4].objects[0].id, toX: 96, y: 96, layerID: tileMapMV.layers[4].id)
        let reencodedMV = try bindingMV.encode(moved)
        let rereadMV = try RPGMapDocument.decode(reencodedMV, engine: .rpgMakerMV, pathName: "Map001.json")
        let rereadEvents = rereadMV.events.first(where: { $0.id == 1 })
        XCTAssertEqual(rereadEvents?.x, 2, "48px grid -> tile 2,2")
        XCTAssertEqual(rereadEvents?.y, 2)
        XCTAssertEqual(rereadMV.json?["note"]?.stringValue, "<mapnote:original>")
    }

    func testNarrativeBindingRoundTripThroughRepository() async throws {
        let (repository, id, owner, project) = try await Self.makeProject(
            root: Fixture.url("xp-project"), engine: .rpgMakerXP, title: "XP")
        let adapter = RPGEditingAdapter(engine: .rpgMakerXP)
        let path = try GameRelativePath("Data/Map001.rxdata")
        let binding = try XCTUnwrap(adapter.narrativeBinding(for: path, in: project))
        let original = try await repository.read(id, owner: owner, revision: project.revision, path: path)
        let document = try binding.decode(original)
        XCTAssertTrue(binding.knownCommands.contains(where: { $0.code == "401" }))
        guard let row = document.commands.first(where: { $0.code == "401" }) else { return XCTFail("no row") }
        let edited = document.updating(id: row.id) { command in
            command.parameters["text"] = .string("Bring lantern and rope.")
        }
        let reencoded = try binding.encode(edited)
        _ = try await repository.commit(id, owner: owner, expectedRevision: project.revision,
                                        changes: [.write(path, reencoded)])
        let reread = try await repository.read(id, owner: owner,
                                               revision: try await repository.open(id, owner: owner).revision,
                                               path: path)
        let redocument = try binding.decode(reread)
        let newRow = try XCTUnwrap(redocument.commands.first(where: { $0.code == "401" }))
        XCTAssertEqual(newRow.parameters["text"]?.stringValue, "Bring lantern and rope.")
        XCTAssertEqual(redocument.commands.count, document.commands.count)
    }
}
