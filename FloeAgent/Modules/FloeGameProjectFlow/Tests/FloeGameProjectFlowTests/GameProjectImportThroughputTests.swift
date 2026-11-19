// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameProjectFlow

/// Folder-import coverage for the shared repository service
/// (job-bba224a07d4c4f78): an RPG Maker MV-scale folder (>=1445 files)
/// including large assets must import through the existing service with every
/// file content-verified and the revision advanced atomically. Timing- or
/// scheduler-sensitive concurrent-mutation stress cases stay in private
/// benchmark evidence; deterministic mutation/drift checks live with the
/// repository owner.
final class GameProjectImportThroughputTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeImport373Tests-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSource(_ files: [(String, Int)]) throws -> (URL, Int, Int) {
        let source = scratch.appendingPathComponent("source-" + UUID().uuidString,
                                                    isDirectory: true)
        var totalBytes = 0
        for (relative, bytes) in files {
            let url = source.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: UInt8(bytes & 0xFF), count: bytes).write(to: url, options: [.atomic])
            totalBytes += bytes
        }
        return (source, files.count, totalBytes)
    }

    func testBulkFolderImportVerifiesEveryFileAndAdvancesRevision() async throws {
        var plan: [(String, Int)] = []
        for index in 0..<700 { plan.append(("www/img/tilesets/t\(index).png", 4_096 + index)) }
        for index in 0..<400 { plan.append(("www/data/Map\(index).json", 2_048 + index)) }
        for index in 0..<250 { plan.append(("js/plugins/p\(index).js", 1_024 + index)) }
        for index in 0..<96 { plan.append(("www/audio/bgm/theme\(index).m4a", 131_072 + index * 1_024)) }
        plan.append(("index.html", 512))
        plan.append(("package.json", 256))
        let (source, fileCount, totalBytes) = try makeSource(plan)
        let id = UUID()
        let owner = GameProjectOwner.space(recordID: id)
        let repository = try FileGameProjectRepository(
            directory: scratch.appendingPathComponent("bulk-store", isDirectory: true))
        let empty = try await repository.createProject(projectID: id, owner: owner,
                                                       title: "Bulk Import")
        let imported = try await repository.importContents(
            from: source, into: id, owner: owner, expectedRevision: empty.revision)
        XCTAssertEqual(imported.files.count, fileCount)
        XCTAssertGreaterThanOrEqual(fileCount, 1_445)
        XCTAssertEqual(imported.files.reduce(0) { $0 + $1.bytes }, totalBytes)
        XCTAssertEqual(imported.parent, empty.revision)
        XCTAssertNotEqual(imported.revision, empty.revision)
        // Read back a deterministic sample and compare real bytes.
        let sample = [plan.first!, plan[plan.count / 2], plan[plan.count - 2]]
        for (relative, _) in sample {
            let sourceBytes = try Data(contentsOf: source.appendingPathComponent(relative))
            let stored = try await repository.read(id, owner: owner,
                                                   revision: imported.revision,
                                                   path: GameRelativePath(relative))
            XCTAssertEqual(stored, sourceBytes, "Mismatch for \(relative)")
            XCTAssertEqual(imported.files.first(where: { $0.path.value == relative })?.bytes,
                           sourceBytes.count)
        }
    }

    /// A re-import over existing content still requires the explicit
    /// replacement flag, and replacement retains the earlier revision in
    /// immutable history (the parent chain the throughput path publishes).
    func testReplaceImportKeepsVerifiedHistory() async throws {
        let (first, _, _) = try makeSource([("www/a.json", 512), ("www/b.bin", 1_024)])
        let (second, _, _) = try makeSource([("www/a.json", 512), ("www/c.bin", 2_048)])
        let id = UUID()
        let owner = GameProjectOwner.space(recordID: id)
        let repository = try FileGameProjectRepository(
            directory: scratch.appendingPathComponent("replace-store", isDirectory: true))
        let empty = try await repository.createProject(projectID: id, owner: owner,
                                                       title: "Replace Import")
        let initial = try await repository.importContents(
            from: first, into: id, owner: owner, expectedRevision: empty.revision)
        do {
            _ = try await repository.importContents(
                from: second, into: id, owner: owner, expectedRevision: initial.revision)
            XCTFail("Expected an explicit replacement requirement")
        } catch GameProjectError.importDestinationNotEmpty {
            // expected typed refusal
        }
        let replaced = try await repository.importContents(
            from: second, into: id, owner: owner, expectedRevision: initial.revision,
            replaceExisting: true)
        XCTAssertEqual(replaced.parent, initial.revision)
        XCTAssertEqual(Set(replaced.files.map(\.path)),
                       Set([try GameRelativePath("www/a.json"), try GameRelativePath("www/c.bin")]))
        // The replaced-away file survives through the parent revision.
        let retained = try await repository.readHistorical(
            id, owner: owner, expectedRevision: replaced.revision,
            historicalRevision: initial.revision,
            path: GameRelativePath("www/b.bin"))
        XCTAssertEqual(retained.count, 1_024)
        let history = try await repository.history(id, owner: owner, limit: 8)
        XCTAssertEqual(history.map(\.revision).prefix(2), [replaced.revision, initial.revision])
    }
}
