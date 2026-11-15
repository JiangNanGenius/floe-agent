// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameEditingCore
@testable import FloeRPGCore

/// End-to-end proof of the real native-editor paths: engine file -> engine
/// binding -> shared DTO -> structural edit -> engine bytes -> repository ->
/// independent engine-codec readback.
@MainActor
final class ParameterDTOEndToEndTests: XCTestCase {
    private func makeProject(root: String, engine: RPGEngine,
                             title: String) async throws -> (FileGameProjectRepository, UUID, GameProjectOwner, GameStoredProject, URL) {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeRPGDTO-" + UUID().uuidString)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let repository = try FileGameProjectRepository(directory: store)
        let project = try await repository.importProject(from: Fixture.url(root), projectID: id,
                                                         owner: owner, title: title,
                                                         engine: engine.gameEngineID)
        return (repository, id, owner, project, store)
    }

    // MARK: Record-aware schemas

    func testBinaryRecordSchemasIdentifyActualRecords() async throws {
        let (repository, id, owner, project, store) = try await makeProject(
            root: "xp-project", engine: .rpgMakerXP, title: "XP")
        defer { try? FileManager.default.removeItem(at: store) }
        let path = try GameRelativePath("Data/Actors.rxdata")
        let adapter = RPGEditingAdapter(engine: .rpgMakerXP)
        let binding = try XCTUnwrap(adapter.parameterBinding(for: path, in: project))
        let bytes = try await repository.read(id, owner: owner, revision: project.revision, path: path)
        let interchange = try binding.decodeDataToJSON(bytes)
        let schemas = try adapter.parameterSchemas(for: path, json: interchange, in: project)
        XCTAssertEqual(schemas.count, 2, "one schema per non-null actor")
        XCTAssertTrue(schemas.allSatisfy { $0.id.hasPrefix("rxdata:Data/Actors.rxdata#id-") })
        XCTAssertTrue(schemas[0].title.en.contains("Kestrel"))
        XCTAssertTrue(schemas[1].title.en.contains("Marlow"))
        // Paths resolve to each record's own values.
        let root = try JSONValue.parse(interchange)
        let firstName = try XCTUnwrap(schemas[0].fields.first(where: { $0.label.en == "Name" }))
        let secondName = try XCTUnwrap(schemas[1].fields.first(where: { $0.label.en == "Name" }))
        XCTAssertEqual(firstName.path.lookup(in: root)?.stringValue, "Kestrel")
        XCTAssertEqual(secondName.path.lookup(in: root)?.stringValue, "Marlow")
        // System yields exactly one schema whose path addresses the object.
        let systemPath = try GameRelativePath("Data/System.rxdata")
        let systemBinding = try XCTUnwrap(adapter.parameterBinding(for: systemPath, in: project))
        let systemBytes = try await repository.read(id, owner: owner, revision: project.revision, path: systemPath)
        let systemJSON = try systemBinding.decodeDataToJSON(systemBytes)
        let systemSchemas = try adapter.parameterSchemas(for: systemPath, json: systemJSON, in: project)
        XCTAssertEqual(systemSchemas.count, 1)
        let titleField = try XCTUnwrap(systemSchemas[0].fields.first(where: { $0.label.en == "Title image" }))
        XCTAssertEqual(titleField.path.lookup(in: try JSONValue.parse(systemJSON))?.stringValue, "title_brackenfell")
    }

    func testMVRecordSchemasUseRawArrayPaths() async throws {
        let (repository, id, owner, project, store) = try await makeProject(
            root: "mv-project", engine: .rpgMakerMV, title: "MV")
        defer { try? FileManager.default.removeItem(at: store) }
        let path = try GameRelativePath("data/Actors.json")
        let adapter = RPGEditingAdapter(engine: .rpgMakerMV)
        let bytes = try await repository.read(id, owner: owner, revision: project.revision, path: path)
        XCTAssertNotNil(try JSONValue.parse(bytes).arrayValue, "standard file is a raw array")
        let schemas = try adapter.parameterSchemas(for: path, json: bytes, in: project)
        XCTAssertEqual(schemas.map(\.id), ["json:data/Actors.json#1", "json:data/Actors.json#2"])
        XCTAssertTrue(schemas[1].title.en.contains("Marlow"))
        let root = try JSONValue.parse(bytes)
        let nameField = try XCTUnwrap(schemas[1].fields.first(where: { $0.label.en == "Name" }))
        XCTAssertEqual(nameField.path.lookup(in: root)?.stringValue, "Marlow")
        XCTAssertEqual(nameField.path.components, [.index(2), .key("name")])
        // System is a single object schema with root-level fields.
        let systemPath = try GameRelativePath("data/System.json")
        let systemBytes = try await repository.read(id, owner: owner, revision: project.revision, path: systemPath)
        let systemSchemas = try adapter.parameterSchemas(for: systemPath, json: systemBytes, in: project)
        XCTAssertEqual(systemSchemas.count, 1)
        XCTAssertEqual(systemSchemas[0].fields.first?.path.components, [.key("gameTitle")])
    }

    // MARK: Binary session edit

    func testBinarySecondRecordEditLeavesFirstRecordUntouched() async throws {
        let (repository, id, owner, project, store) = try await makeProject(
            root: "xp-project", engine: .rpgMakerXP, title: "XP")
        defer { try? FileManager.default.removeItem(at: store) }
        let adapter = RPGEditingAdapter(engine: .rpgMakerXP)
        let session = try await GameEditingSession.open(repository: repository, projectID: id,
                                                        owner: owner, adapter: adapter)
        let path = try GameRelativePath("Data/Actors.rxdata")
        let projectNow = try await repository.open(id, owner: owner)
        let binding = try XCTUnwrap(adapter.parameterBinding(for: path, in: projectNow))
        let bytes = try await repository.read(id, owner: owner, revision: projectNow.revision, path: path)
        let interchange = try binding.decodeDataToJSON(bytes)
        let schemas = try adapter.parameterSchemas(for: path, json: interchange, in: projectNow)
        let second = try XCTUnwrap(schemas.first(where: { $0.title.en.contains("Marlow") }))

        let document = try await session.parameterDocument(at: path, binding: binding, schema: second)
        let nameField = try XCTUnwrap(second.fields.first(where: { $0.label.en == "Name" }))
        XCTAssertEqual(document.value(for: nameField).stringValue, "Marlow")
        try await session.editParameterDocument(at: path, binding: binding, schema: second,
                                                summary: GameEditCopy("Rename actor 2", "重命名角色 2")) { doc in
            let field = try XCTUnwrap(doc.schema.fields.first(where: { $0.label.en == "Name" }))
            try doc.set(.string("Marlow the Ferryman"), for: field)
        }
        let saved = try await session.save()

        // Reopen with the engine codec (not the DTO): first record untouched.
        let reopened = try await repository.read(id, owner: owner, revision: saved.revision, path: path)
        let map = try RPGDataDocument.decode(reopened, kind: .actors, engine: .rpgMakerXP)
        let first = try XCTUnwrap(map.binaryRecord(1))
        let secondRecord = try XCTUnwrap(map.binaryRecord(2))
        XCTAssertEqual(first.stringMember("@name"), "Kestrel")
        XCTAssertEqual(first.intMember("@class_id"), 1)
        XCTAssertEqual(secondRecord.stringMember("@name"), "Marlow the Ferryman")
        XCTAssertEqual(secondRecord.intMember("@class_id"), 2)
        // Unknown/table fields of the edited record survive.
        XCTAssertEqual(secondRecord.intMember("@final_level"), 99)
        guard let table = secondRecord[member: "@parameters"]?.value.kind.userDefinedData else {
            return XCTFail("parameter table lost")
        }
        XCTAssertNoThrow(try RPGTable.decode(table.data))
    }

    // MARK: MV standard JSON session edit

    func testMVStandardJSONSecondRecordEditPreservesShapeAndFirstRecord() async throws {
        let (repository, id, owner, project, store) = try await makeProject(
            root: "mv-project", engine: .rpgMakerMV, title: "MV")
        defer { try? FileManager.default.removeItem(at: store) }
        let adapter = RPGEditingAdapter(engine: .rpgMakerMV)
        let session = try await GameEditingSession.open(repository: repository, projectID: id,
                                                        owner: owner, adapter: adapter)
        let path = try GameRelativePath("data/Items.json")
        let projectNow = try await repository.open(id, owner: owner)
        let bytes = try await repository.read(id, owner: owner, revision: projectNow.revision, path: path)
        let schemas = try adapter.parameterSchemas(for: path, json: bytes, in: projectNow)
        XCTAssertEqual(schemas.count, 2)
        let second = try XCTUnwrap(schemas.first(where: { $0.title.en.contains("Lantern") }))
        // No engine binary binding: raw JSON is the document.
        XCTAssertNil(adapter.parameterBinding(for: path, in: projectNow))

        let document = try await session.parameterDocument(at: path, binding: nil, schema: second)
        let priceField = try XCTUnwrap(second.fields.first(where: { $0.label.en == "Price" }))
        XCTAssertEqual(document.value(for: priceField).intValue, 8)
        try await session.editParameterDocument(at: path, binding: nil, schema: second,
                                                summary: GameEditCopy("Reprice item 2", "调整物品 2 价格")) { doc in
            let field = try XCTUnwrap(doc.schema.fields.first(where: { $0.label.en == "Price" }))
            try doc.set(.number(21), for: field)
        }
        let saved = try await session.save()
        let reopened = try await repository.read(id, owner: owner, revision: saved.revision, path: path)
        let root = try JSONValue.parse(reopened)
        guard let records = root.arrayValue else { return XCTFail("raw array shape lost") }
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records[0].isNull)
        XCTAssertEqual(records[1]["name"]?.stringValue, "Rope Coil")
        XCTAssertEqual(records[1]["price"]?.intValue, 12, "first record untouched")
        XCTAssertEqual(records[2]["price"]?.intValue, 21)
        XCTAssertEqual(records[2]["note"]?.stringValue, "<plugin:keep>", "unknown field preserved")
    }

    func testMVSystemEditPreservesUnknownKeys() async throws {
        let (repository, id, owner, _, store) = try await makeProject(
            root: "mz-project", engine: .rpgMakerMZ, title: "MZ")
        defer { try? FileManager.default.removeItem(at: store) }
        let adapter = RPGEditingAdapter(engine: .rpgMakerMZ)
        let session = try await GameEditingSession.open(repository: repository, projectID: id,
                                                        owner: owner, adapter: adapter)
        let path = try GameRelativePath("data/System.json")
        let projectNow = try await repository.open(id, owner: owner)
        let bytes = try await repository.read(id, owner: owner, revision: projectNow.revision, path: path)
        let schemas = try adapter.parameterSchemas(for: path, json: bytes, in: projectNow)
        XCTAssertEqual(schemas.count, 1)
        try await session.editParameterDocument(at: path, binding: nil, schema: schemas[0],
                                                summary: GameEditCopy("Retitle", "修改标题")) { doc in
            let field = try XCTUnwrap(doc.schema.fields.first(where: { $0.label.en == "Game title" }))
            try doc.set(.string("Brackenfell Reforged"), for: field)
        }
        let saved = try await session.save()
        let reopened = try await repository.read(id, owner: owner, revision: saved.revision, path: path)
        let root = try JSONValue.parse(reopened)
        XCTAssertEqual(root["gameTitle"]?.stringValue, "Brackenfell Reforged")
        XCTAssertEqual(root["advanced"]?["gameId"]?.intValue, 812_001, "unknown MZ block preserved")
        XCTAssertEqual(root["currencyUnit"]?.stringValue, "G")
    }

    // MARK: Session tile map / narrative paths

    func testSessionTileMapEditThroughBindingThenReopenWithEngineCodec() async throws {
        let (repository, id, owner, _, store) = try await makeProject(
            root: "mv-project", engine: .rpgMakerMV, title: "MV Map")
        defer { try? FileManager.default.removeItem(at: store) }
        let adapter = RPGEditingAdapter(engine: .rpgMakerMV)
        let session = try await GameEditingSession.open(repository: repository, projectID: id,
                                                        owner: owner, adapter: adapter)
        let path = try GameRelativePath("data/Map001.json")
        let projectNow = try await repository.open(id, owner: owner)
        let binding = try XCTUnwrap(adapter.tileMapBinding(for: path, in: projectNow))
        try await session.editTileMapDocument(at: path, binding: binding,
                                              summary: GameEditCopy("Paint tile", "绘制图块")) { map in
            guard let layer = map.layers.first(where: { $0.kind == .tile }) else { return }
            map = map.painting(gid: 123, atX: 1, y: 2, layerID: layer.id)
        }
        let saved = try await session.save()
        let reopened = try await repository.read(id, owner: owner, revision: saved.revision, path: path)
        let engineMap = try RPGMapDocument.decode(reopened, engine: .rpgMakerMV, pathName: "Map001.json")
        XCTAssertEqual(engineMap.tile(x: 1, y: 2, z: 0), 123)
        XCTAssertEqual(engineMap.tile(x: 2, y: 1, z: 0), (2 + 1 * 2) % 9, "other cells unchanged")
        XCTAssertEqual(engineMap.json?["note"]?.stringValue, "<mapnote:original>", "unknown map fields preserved")
        XCTAssertEqual(engineMap.events.count, 2)
        XCTAssertEqual(engineMap.eventCommands(eventID: 1, pageIndex: 0).first?.code, 101)
    }

    func testSessionNarrativeEditThroughBindingThenReopenWithEngineCodec() async throws {
        let (repository, id, owner, _, store) = try await makeProject(
            root: "xp-project", engine: .rpgMakerXP, title: "XP Narrative")
        defer { try? FileManager.default.removeItem(at: store) }
        let adapter = RPGEditingAdapter(engine: .rpgMakerXP)
        let session = try await GameEditingSession.open(repository: repository, projectID: id,
                                                        owner: owner, adapter: adapter)
        let path = try GameRelativePath("Data/Map001.rxdata")
        let projectNow = try await repository.open(id, owner: owner)
        let binding = try XCTUnwrap(adapter.narrativeBinding(for: path, in: projectNow))
        try await session.editNarrativeDocument(at: path, binding: binding,
                                                summary: GameEditCopy("Edit line", "编辑文本")) { document in
            guard let row = document.commands.first(where: { $0.code == "401" }) else { return }
            document = document.updating(id: row.id) { command in
                command.parameters["text"] = .string("Bring lantern and rope.")
            }
        }
        let saved = try await session.save()
        let reopened = try await repository.read(id, owner: owner, revision: saved.revision, path: path)
        let engineMap = try RPGMapDocument.decode(reopened, engine: .rpgMakerXP, pathName: "Map001.rxdata")
        let commands = engineMap.eventCommands(eventID: 1, pageIndex: 0)
        XCTAssertEqual(commands.count, 5)
        XCTAssertEqual(commands[1].parameters.first, .string("Bring lantern and rope."))
        XCTAssertEqual(commands[3].code, 999, "unknown command preserved")
        XCTAssertEqual(commands[3].parameters.first, .string("custom-plugin-payload"))
        XCTAssertEqual(engineMap.width, 20, "map metadata preserved")
        XCTAssertEqual(engineMap.tile(x: 3, y: 4, z: 0), (3 + 4) % 8, "tiles untouched")
    }
}
