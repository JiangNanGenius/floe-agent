// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeRPGCore
@testable import FloeGameCore

final class SessionTests: XCTestCase {
    func testImportEditCommitExportRoundTripThroughGameKitCAS() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeRPGSessionTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let repository = try FileGameProjectRepository(directory: store)
        let imported = try await repository.importProject(from: Fixture.url("xp-project"),
                                                          projectID: id, owner: owner,
                                                          title: "Brackenfell", engine: .rpgMakerXP)
        let session = try await RPGProjectSession(repository: repository, projectID: id,
                                                  owner: owner, engine: .rpgMakerXP)

        // Read + edit actor name through the session.
        var actors = try await session.dataDocument(GameRelativePath("Data/Actors.rxdata"), kind: .actors)
        let record = try XCTUnwrap(actors.binaryRecord(2))
        var view = RPGRecordView(node: record)
        view.setName("Marlow the Ferryman")
        try await session.commit(document: actors, path: GameRelativePath("Data/Actors.rxdata"))

        // Map tile edit through the session.
        var map = try await session.mapDocument(GameRelativePath("Data/Map001.rxdata"))
        try map.setTile(555, x: 5, y: 5, z: 1)
        try await session.commit(map: map, path: GameRelativePath("Data/Map001.rxdata"))

        // Scripts edit.
        var scripts = try await session.scripts()
        scripts[0].source = Data("puts 'Brackenfell boot v2'".utf8)
        try await session.commit(scripts: scripts)

        // Stale revision commit must conflict (CAS proof).
        do {
            _ = try await repository.commit(id, owner: owner, expectedRevision: imported.revision,
                                            changes: [.write(GameRelativePath("stale.txt"), Data("x".utf8))])
            XCTFail("expected stale revision conflict")
        } catch GameProjectError.conflict { /* expected */ }

        // History shows our three commits + import.
        let history = try await repository.history(id, owner: owner)
        XCTAssertEqual(history.count, 4)

        // Export and verify edited + original bytes on disk.
        let export = store.deletingLastPathComponent().appendingPathComponent("FloeRPGSessionExport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: export) }
        let project = try await repository.open(id, owner: owner)
        _ = try await repository.export(id, owner: owner, expectedRevision: project.revision, to: export)
        let exportedActors = try RubyMarshal.parse(Data(contentsOf: export.appendingPathComponent("Data/Actors.rxdata")))
        XCTAssertNil(exportedActors[member: "nope"])
        guard case .array(let records) = exportedActors.value.kind else { return XCTFail("shape") }
        XCTAssertEqual(records[2][member: "@name"].flatMap { $0.value.kind.stringValue?.utf8String }, "Marlow the Ferryman")
        let exportedMap = try RPGMapDocument.decode(Data(contentsOf: export.appendingPathComponent("Data/Map001.rxdata")),
                                                    engine: .rpgMakerXP, pathName: "Map001.rxdata")
        XCTAssertEqual(exportedMap.tile(x: 5, y: 5, z: 1), 555)
        // Original fixture folder untouched (import is a copy).
        let originalActors = try RubyMarshal.parse(Fixture.data("xp-project/Data/Actors.rxdata"))
        guard case .array(let originalRecords) = originalActors.value.kind else { return XCTFail("shape") }
        XCTAssertEqual(originalRecords[2][member: "@name"].flatMap { $0.value.kind.stringValue?.utf8String }, "Marlow")
    }

    func testWrongOwnerRejected() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeRPGSessionOwner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let repository = try FileGameProjectRepository(directory: store)
        try await repository.importProject(from: Fixture.url("mv-project"), projectID: id, owner: owner,
                                           title: "MV", engine: .rpgMakerMV)
        let session = try await RPGProjectSession(repository: repository, projectID: id,
                                                  owner: owner, engine: .rpgMakerMV)
        _ = session
        do {
            _ = try await repository.open(id, owner: .conversation(conversationID: UUID(), workspaceID: UUID()))
            XCTFail("expected ownership rejection")
        } catch GameProjectError.ownershipMismatch { /* expected */ }
    }
}
