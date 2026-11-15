// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

final class GameProjectArchiveRoundtripTests: XCTestCase {
    func testZipToRepositoryEditExportAndReimportVerifies() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let exchange = GameArchiveExchange()
        let originalZIP = fixture.root.appendingPathComponent("original.zip")
        _ = try exchange.archive(directory: try fixture.project(), to: originalZIP)

        let storeDirectory = fixture.root.appendingPathComponent("originals")
        let store = try GameArchiveOriginalStore(directory: storeDirectory)
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let roundtrip = GameProjectArchiveRoundtrip(exchange: exchange, originalStore: store)

        let report = try await roundtrip.roundtrip(
            archive: originalZIP, repository: repository, projectID: id, owner: owner,
            title: "Roundtrip", engine: .phaser,
            workspace: fixture.root.appendingPathComponent("workspace")) { repo, imported in
            let original = try await repo.read(id, owner: owner, revision: imported.revision,
                                               path: GameRelativePath("data.json"))
            let patched = try GameJSONPatch.replacing(original, at: [.key("actors"), .index(0), .key("hp")],
                                                      with: Data("250".utf8))
            return try await repo.commit(id, owner: owner, expectedRevision: imported.revision,
                                         changes: [.write(GameRelativePath("data.json"), patched)])
        }

        XCTAssertTrue(report.roundtripVerified, "deltas: \(report.deltas)")
        XCTAssertTrue(report.originalArchivePreserved)
        XCTAssertEqual(report.originalArchiveSHA256, GameDigest.sha256(try Data(contentsOf: originalZIP)))
        XCTAssertNotEqual(report.edited.revision, report.imported.revision)
        // The edited value really is in the exported source ZIP.
        let reextracted = fixture.root.appendingPathComponent("manual-reextract")
        let extraction = try exchange.extract(archive: report.exportedArchive.archiveURL, to: reextracted)
        let data = try Data(contentsOf: reextracted.appendingPathComponent("data.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hero = try XCTUnwrap((object["actors"] as? [Any])?[0] as? [String: Any])
        XCTAssertEqual(hero["hp"] as? Int, 250)
        XCTAssertEqual(Set(extraction.manifest.files.map(\.path)), Set(report.edited.files.map(\.path)))
        // The original archive bytes are durably preserved and read back.
        let preserved = try await store.read(sha256: report.originalArchiveSHA256)
        XCTAssertEqual(preserved, try Data(contentsOf: originalZIP))
        // Re-importing the produced source ZIP into a fresh pre-created project.
        let freshID = UUID()
        let freshCreated = try await repository.createProject(projectID: freshID,
                                                              owner: .space(recordID: freshID),
                                                              title: "Fresh", engine: .phaser)
        let fresh = try await repository.importContents(from: reextracted, into: freshID,
                                                        owner: .space(recordID: freshID),
                                                        expectedRevision: freshCreated.revision)
        let deltas = GameProjectArchiveRoundtrip.deltas(expected: report.edited, actual: fresh)
        XCTAssertTrue(deltas.isEmpty, "fresh deltas: \(deltas)")
    }

    func testRoundtripPreservesExecutableAndEmptyDirectoriesThroughTheRepository() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let exchange = GameArchiveExchange()
        let originalZIP = fixture.root.appendingPathComponent("original.zip")
        _ = try exchange.archive(directory: try fixture.project(), to: originalZIP)
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let store = try GameArchiveOriginalStore(directory: fixture.root.appendingPathComponent("originals"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let report = try await GameProjectArchiveRoundtrip(exchange: exchange, originalStore: store).roundtrip(
            archive: originalZIP, repository: repository, projectID: id, owner: owner,
            title: "Preserve", engine: .godot,
            workspace: fixture.root.appendingPathComponent("workspace")) { _, imported in imported }
        XCTAssertTrue(report.roundtripVerified)
        XCTAssertTrue(report.edited.files.contains(where: { $0.path.value == "tools/run.sh" && $0.executable }))
        XCTAssertTrue(report.edited.directories.contains(try GameRelativePath("Assets/Empty")))
    }
}
