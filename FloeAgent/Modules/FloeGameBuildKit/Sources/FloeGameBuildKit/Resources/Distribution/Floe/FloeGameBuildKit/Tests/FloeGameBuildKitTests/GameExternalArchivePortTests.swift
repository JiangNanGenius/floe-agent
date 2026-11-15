// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

/// Controlled host archive service: no real tar/7z/rar decoding here. It
/// writes a prepared tree (simulating the App's existing ArchiveEngine output)
/// so the component's own validation/import path can be verified.
actor FakeExternalArchiveHost: GameExternalArchiveHostPort {
    private let provided: Set<GameArchiveContainerFormat>
    private let treeBuilder: @Sendable (URL) throws -> Void

    init(provided: Set<GameArchiveContainerFormat>,
         tree: @escaping @Sendable (URL) throws -> Void) {
        self.provided = provided
        self.treeBuilder = tree
    }

    func capabilities() async -> Set<GameArchiveContainerFormat> { provided }

    func extract(_ request: GameExternalArchiveRequest) async throws {
        guard provided.contains(request.format) else {
            throw GameExternalArchiveError.formatUnavailable(request.format, available: provided.sorted { $0.rawValue < $1.rawValue })
        }
        try GameBuildFileSupport.makeDirectory(request.destination)
        try treeBuilder(request.destination)
    }
}

final class GameExternalArchivePortTests: XCTestCase {
    func testDetectsContainersByMagicBytesNotJustExtension() throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let cases: [(String, [UInt8], GameArchiveContainerFormat)] = [
            ("a.zip", [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00], .zip),
            ("b.tgz", [0x1F, 0x8B, 0x08, 0x00], .tarGzip),
            ("c.bin", [0x42, 0x5A, 0x68, 0x39], .tarBzip2),
            ("d.bin", [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], .tarXz),
            ("e.bin", [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], .sevenZip),
            ("f.bin", [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00], .rar),
        ]
        for (name, bytes, expected) in cases {
            let url = fixture.root.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            XCTAssertEqual(try GameArchiveFormatDetector.detect(at: url), expected, name)
        }
        XCTAssertThrowsError(try GameArchiveFormatDetector.detect(
            at: fixture.root.appendingPathComponent("missing.bin")))
    }

    func testNonZIPImportUsesHostPortAndPreservesTheWholeTree() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        // A gzip-magic fixture: the component never decodes it; the host port
        // supplies the extracted tree exactly as the App's ArchiveEngine would.
        let archive = fixture.root.appendingPathComponent("game.tar.gz")
        try Data([0x1F, 0x8B, 0x08, 0x00, 0x01]).write(to: archive)
        let host = FakeExternalArchiveHost(provided: [.tarGzip, .tar]) { destination in
            try GameBuildFileSupport.makeDirectory(destination.appendingPathComponent("Game/Assets"))
            try Data("[application]".utf8).write(to: destination.appendingPathComponent("Game/project.godot"))
            try Data([0, 1, 2, 250]).write(to: destination.appendingPathComponent("Game/Assets/blob.bin"))
            try Data("outside".utf8).write(to: destination.appendingPathComponent("README.txt"))
        }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let store = try GameArchiveOriginalStore(directory: fixture.root.appendingPathComponent("originals"))
        let importer = GameArchiveProjectImporter(originalStore: store)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner, title: "External")
        let result = try await importer.importExistingProjectArchive(
            archive: archive, repository: repository, projectID: id, owner: owner,
            expectedRevision: created.revision, workspace: fixture.root.appendingPathComponent("workspace"),
            hostPort: host)
        XCTAssertEqual(Set(result.project.files.map(\.path.value)),
                       ["Game/project.godot", "Game/Assets/blob.bin", "README.txt"])
        XCTAssertEqual(result.preview.recognizedEngines, [.godot])
        XCTAssertEqual(result.preview.contentClass, .editorSource)
        XCTAssertEqual(result.originalArchiveSHA256, GameDigest.sha256(try Data(contentsOf: archive)))
        let preserved = try await store.read(sha256: result.originalArchiveSHA256)
        XCTAssertEqual(preserved, try Data(contentsOf: archive))
        let bytes = try await repository.read(id, owner: owner, revision: result.project.revision,
                                              path: GameRelativePath("Game/Assets/blob.bin"))
        XCTAssertEqual(bytes, Data([0, 1, 2, 250]))
    }

    func testMissingHostOrCapabilityReportsExactFormatError() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let archive = fixture.root.appendingPathComponent("packed.rar")
        try Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]).write(to: archive)
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let store = try GameArchiveOriginalStore(directory: fixture.root.appendingPathComponent("originals"))
        let importer = GameArchiveProjectImporter(originalStore: store)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner, title: "Rar")
        do {
            _ = try await importer.importExistingProjectArchive(
                archive: archive, repository: repository, projectID: id, owner: owner,
                expectedRevision: created.revision, workspace: fixture.root.appendingPathComponent("workspace"))
            XCTFail("expected formatUnavailable without a host")
        } catch GameExternalArchiveError.formatUnavailable(let format, let available) {
            XCTAssertEqual(format, .rar)
            XCTAssertTrue(available.isEmpty)
        }
        let host = FakeExternalArchiveHost(provided: [.tar, .sevenZip]) { _ in }
        do {
            _ = try await importer.importExistingProjectArchive(
                archive: archive, repository: repository, projectID: id, owner: owner,
                expectedRevision: created.revision, workspace: fixture.root.appendingPathComponent("workspace2"),
                hostPort: host)
            XCTFail("expected formatUnavailable from the host capability set")
        } catch GameExternalArchiveError.formatUnavailable(let format, let available) {
            XCTAssertEqual(format, .rar)
            XCTAssertEqual(available, [.sevenZip, .tar])
        }
        // Nothing was imported into the pre-created project.
        let reopened = try await repository.open(id, owner: owner)
        XCTAssertEqual(reopened.revision, created.revision)
        XCTAssertTrue(reopened.files.isEmpty)
    }

    func testHostTreeWithSymlinkIsRejectedBeforeAnyProjectWrite() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let archive = fixture.root.appendingPathComponent("evil.tar.xz")
        try Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0x00]).write(to: archive)
        let escapeTarget = fixture.root
        let host = FakeExternalArchiveHost(provided: [.tarXz]) { destination in
            try Data("payload".utf8).write(to: destination.appendingPathComponent("game.txt"))
            try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("escape"),
                                                       withDestinationURL: escapeTarget)
        }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let store = try GameArchiveOriginalStore(directory: fixture.root.appendingPathComponent("originals"))
        let importer = GameArchiveProjectImporter(originalStore: store)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner, title: "Evil")
        do {
            _ = try await importer.importExistingProjectArchive(
                archive: archive, repository: repository, projectID: id, owner: owner,
                expectedRevision: created.revision, workspace: fixture.root.appendingPathComponent("workspace"),
                hostPort: host)
            XCTFail("expected insecureTree")
        } catch GameExternalArchiveError.insecureTree {
        }
        let reopened = try await repository.open(id, owner: owner)
        XCTAssertEqual(reopened.revision, created.revision)
    }

    func testOriginalStoreRejectsNonDigestNamesAndOversizeBytes() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let store = try GameArchiveOriginalStore(directory: fixture.root.appendingPathComponent("originals"),
                                                 maximumOriginalBytes: 16)
        do {
            _ = try await store.preserve(Data(count: 32))
            XCTFail("expected size rejection")
        } catch GameArchiveError.limitExceeded {
        }
        do {
            _ = try await store.read(sha256: "../../escape")
            XCTFail("expected digest rejection")
        } catch GameArchiveError.unsafeEntryPath {
        }
        let containsBad = await store.contains(sha256: "ABC")
        XCTAssertFalse(containsBad)
        let record = try await store.preserve(Data([1, 2, 3]))
        let readBack = try await store.read(sha256: record.sha256)
        XCTAssertEqual(readBack, Data([1, 2, 3]))
    }
}
