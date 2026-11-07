// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeTools
@testable import FloeWorkspace

final class WorkspaceDeletionCASTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-delete-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root.resolvingSymlinksInPath()
    }
    func testSelectedVersionCannotDeleteChangedBytesEvenWhenSizeAndDateMatch() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let file = root.appendingPathComponent("sample.txt")
        try Data("old bytes".utf8).write(to: file)
        let frozen = try service.deletionMetadata("sample.txt")
        try Data("new bytes".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: frozen.mtime)], ofItemAtPath: file.path)
        XCTAssertThrowsError(try service.delete("sample.txt", expectedMetadata: frozen, expectedResolvedURL: file)) { error in
            guard case WorkspaceToolError.conflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("new bytes".utf8))
        let fresh = try service.deletionMetadata("sample.txt")
        try service.delete("sample.txt", expectedMetadata: fresh, expectedResolvedURL: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testWrongResolvedLocationCannotDeleteTheSelectedFile() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let file = root.appendingPathComponent("sample.txt")
        try Data("preserved".utf8).write(to: file)
        let frozen = try service.deletionMetadata("sample.txt")
        XCTAssertThrowsError(try service.delete("sample.txt", expectedMetadata: frozen,
            expectedResolvedURL: root.appendingPathComponent("different.txt")))
        XCTAssertEqual(try Data(contentsOf: file), Data("preserved".utf8))
    }
    func testFrozenCanonicalLocationDoesNotFollowAReplacementSymlink() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let selected = root.appendingPathComponent("selected.txt"), other = root.appendingPathComponent("other.txt")
        let bytes = Data("identical saved bytes".utf8)
        try bytes.write(to: selected); try bytes.write(to: other)
        let frozen = try service.deletionMetadata("selected.txt")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: frozen.mtime)], ofItemAtPath: other.path)
        try FileManager.default.removeItem(at: selected)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: other)
        XCTAssertThrowsError(try service.delete("selected.txt", expectedMetadata: frozen, expectedResolvedURL: selected))
        XCTAssertTrue(try selected.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertEqual(try Data(contentsOf: other), bytes)
    }

    func testDeletionUsesStreamingDigestWithoutRelaxingOrdinaryReadBudget() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root, maxReadBytes: 64))
        let file = root.appendingPathComponent("large.bin")
        try Data(repeating: 0x5a, count: 1_048_576).write(to: file)
        XCTAssertThrowsError(try service.metadata("large.bin"))
        let frozen = try service.deletionMetadata("large.bin")
        XCTAssertEqual(frozen.size, 1_048_576)
        XCTAssertEqual(frozen.sha256.count, 64)
        try service.delete("large.bin", expectedMetadata: frozen, expectedResolvedURL: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testCancelledDigestLeavesOriginalIntact() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let file = root.appendingPathComponent("sample.bin")
        let bytes = Data(repeating: 0x7f, count: 1_048_576); try bytes.write(to: file)
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try service.deletionMetadata("sample.bin")
        }
        do { _ = try await worker.value; XCTFail("Cancelled digest completed") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testFolderRejectsAnInPlaceDescendantRewriteWithSameSizeAndModificationDate() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let folder = root.appendingPathComponent("folder"), nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("payload.bin")
        try Data("old bytes".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
        let childBefore = try FileManager.default.attributesOfItem(atPath: file.path)
        let frozen = try service.deletionMetadata("folder")
        XCTAssertEqual(frozen.sha256.count, 64)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("new bytes".utf8)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(childBefore[.modificationDate])], ofItemAtPath: file.path)
        let childAfter = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(childBefore[.systemFileNumber] as? NSNumber, childAfter[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(childBefore[.size] as? NSNumber, childAfter[.size] as? NSNumber)
        XCTAssertEqual(childBefore[.modificationDate] as? Date, childAfter[.modificationDate] as? Date)
        let changed = try service.deletionMetadata("folder")
        XCTAssertEqual(changed.size, frozen.size)
        XCTAssertEqual(changed.mtime, frozen.mtime)
        XCTAssertNotEqual(changed.sha256, frozen.sha256)
        XCTAssertThrowsError(try service.delete("folder", recursive: true, expectedMetadata: frozen, expectedResolvedURL: folder)) { error in
            guard case WorkspaceToolError.conflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("new bytes".utf8))
        try service.delete("folder", recursive: true, expectedMetadata: changed, expectedResolvedURL: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testFolderFingerprintIsStableAndIncludesHiddenFilesAndEmptyDirectories() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let folder = root.appendingPathComponent("folder"), hidden = folder.appendingPathComponent(".kept")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try Data("hidden original".utf8).write(to: hidden.appendingPathComponent("asset.bin"))
        let first = try service.deletionMetadata("folder"), second = try service.deletionMetadata("folder")
        XCTAssertEqual(first, second)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("empty"), to: folder.appendingPathComponent("renamed"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: first.mtime)], ofItemAtPath: folder.path)
        XCTAssertNotEqual(try service.deletionMetadata("folder").sha256, first.sha256)
        XCTAssertThrowsError(try service.delete("folder", recursive: true, expectedMetadata: first, expectedResolvedURL: folder))
        XCTAssertEqual(try Data(contentsOf: hidden.appendingPathComponent("asset.bin")), Data("hidden original".utf8))
    }

    func testFolderContainingALinkIsRejectedWithoutFollowingItsExternalTarget() throws {
        let root = try root(), outside = try self.root()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("external original".utf8).write(to: outside.appendingPathComponent("original.bin"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("external"), withDestinationURL: outside)
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        XCTAssertThrowsError(try service.deletionMetadata("folder")) { error in
            guard case WorkspaceDeletionScanError.symbolicLink = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("original.bin")), Data("external original".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testDeepOrOversizedFolderIsRefusedBeforeADeletionVersionCanBeConfirmed() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        var directory = root.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for _ in 0..<65 {
            directory.appendPathComponent("d")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try service.deletionMetadata("deep")) { error in
            guard case WorkspaceDeletionScanError.limit = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
        }
        let large = root.appendingPathComponent("large")
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: false)
        let sparse = large.appendingPathComponent("sparse.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 256 * 1_024 * 1_024 + 1); try handle.close()
        XCTAssertThrowsError(try service.deletionMetadata("large")) { error in
            guard case WorkspaceDeletionScanError.limit = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sparse.path))
    }

    func testCancelledDirectoryFingerprintKeepsTheSubtree() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("original.bin"), bytes = Data(repeating: 0x5a, count: 1_048_576)
        try bytes.write(to: file)
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try service.deletionMetadata("folder")
        }
        do { _ = try await worker.value; XCTFail("Cancelled directory check completed") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

}
