import Foundation
import XCTest
import FloeBuildingProject
import FloeBuildingRecords

final class BuildingDirectorySnapshotTests: XCTestCase {
    func testCaptureCopiesHashesAndReportsProgress() throws {
        let root = try ProjectTestSupport.makeSpace("directory-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: source)
        try ProjectTestSupport.write("extra", to: source.appendingPathComponent("nested/extra.txt"))
        let destination = root.appendingPathComponent("snapshot", isDirectory: true)
        let progressBox = ProgressBox()
        let snapshot = try BuildingProjectRepository.captureDirectorySnapshot(
            source: source,
            to: destination,
            progress: { value in progressBox.values.append(value) }
        )
        XCTAssertEqual(
            snapshot.directoryURL.standardizedFileURL,
            destination.resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertEqual(snapshot.fileCount, 4)
        XCTAssertGreaterThan(snapshot.totalByteCount, 0)
        XCTAssertEqual(snapshot.files.count, 4)
        XCTAssertEqual(snapshot.treeSHA256, ProjectFileTreeDigest.digest(snapshot.files))
        XCTAssertEqual(progressBox.values.last?.completedFiles, 4)
        XCTAssertEqual(progressBox.values.last?.totalFiles, 4)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("nested/extra.txt")),
            Data("extra".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("geometry/mesh.bin")),
            try Data(contentsOf: source.appendingPathComponent("geometry/mesh.bin"))
        )
    }

    func testExistingDestinationIsNotOverwritten() throws {
        let root = try ProjectTestSupport.makeSpace("directory-existing")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: source)
        let destination = root.appendingPathComponent("snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("marker.txt")
        try Data("keep".utf8).write(to: marker)
        XCTAssertThrowsError(try BuildingProjectRepository.captureDirectorySnapshot(
            source: source,
            to: destination
        )) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .outputExists = buildingError else {
                return XCTFail("expected outputExists, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }

    func testSymlinkIsRejected() throws {
        let root = try ProjectTestSupport.makeSpace("directory-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: source)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("link.json"),
            withDestinationURL: source.appendingPathComponent("model.json")
        )
        let destination = root.appendingPathComponent("snapshot", isDirectory: true)
        XCTAssertThrowsError(try BuildingProjectRepository.captureDirectorySnapshot(
            source: source,
            to: destination
        )) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .symbolicLinkRejected = buildingError else {
                return XCTFail("expected symbolicLinkRejected, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testBudgetOverlapAndCancellation() throws {
        let root = try ProjectTestSupport.makeSpace("directory-limits")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: source)
        try ProjectTestSupport.write("second", to: source.appendingPathComponent("second.txt"))

        let budgetDestination = root.appendingPathComponent("budget", isDirectory: true)
        XCTAssertThrowsError(try BuildingProjectRepository.captureDirectorySnapshot(
            source: source,
            to: budgetDestination,
            limits: BuildingProjectLimits(maxFileCount: 1)
        )) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .budgetExceeded = buildingError else {
                return XCTFail("expected budgetExceeded, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: budgetDestination.path))

        let inside = source.appendingPathComponent("inside", isDirectory: true)
        XCTAssertThrowsError(try BuildingProjectRepository.captureDirectorySnapshot(
            source: source,
            to: inside
        )) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .pathEscapesRoot = buildingError else {
                return XCTFail("expected pathEscapesRoot, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path))

        let cancelledToken = BuildingProjectCancellation()
        cancelledToken.cancel()
        let cancelledDestination = root.appendingPathComponent("cancelled", isDirectory: true)
        XCTAssertThrowsError(try BuildingProjectRepository.captureDirectorySnapshot(
            source: source,
            to: cancelledDestination,
            cancellation: cancelledToken
        )) { error in
            XCTAssertEqual(error as? BuildingProjectError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledDestination.path))

        let token = BuildingProjectCancellation()
        let duringDestination = root.appendingPathComponent("cancelled-during", isDirectory: true)
        XCTAssertThrowsError(try BuildingProjectRepository.captureDirectorySnapshot(
            source: source,
            to: duringDestination,
            cancellation: token,
            progress: { value in
                if value.completedFiles >= 1 {
                    token.cancel()
                }
            }
        )) { error in
            XCTAssertEqual(error as? BuildingProjectError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: duringDestination.path))
    }

    func testEmptyDirectorySnapshot() throws {
        let root = try ProjectTestSupport.makeSpace("directory-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("snapshot", isDirectory: true)
        let snapshot = try BuildingProjectRepository.captureDirectorySnapshot(
            source: source,
            to: destination
        )
        XCTAssertEqual(snapshot.fileCount, 0)
        XCTAssertEqual(snapshot.totalByteCount, 0)
        XCTAssertEqual(snapshot.files, [])
        XCTAssertEqual(snapshot.treeSHA256, ProjectFileTreeDigest.digest([]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }
}

private final class ProgressBox: @unchecked Sendable {
    var values: [BuildingDirectorySnapshotProgress] = []
}
