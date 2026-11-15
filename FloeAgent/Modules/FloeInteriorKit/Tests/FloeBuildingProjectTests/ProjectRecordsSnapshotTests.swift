import Foundation
import XCTest
import FloeBuildingProject
import FloeBuildingRecords

final class ProjectRecordsSnapshotTests: XCTestCase {
    func testCaptureIsConsistentAndReopensWithOriginalsObservationsAndBOM() throws {
        let root = try ProjectTestSupport.makeSpace("snapshot-consistent")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectRecordsStore.createProject(
            at: root.appendingPathComponent("records", isDirectory: true),
            name: "Snapshot project"
        )
        let fixture = try ProjectTestSupport.populate(store)
        let destination = root.appendingPathComponent("snapshots/base", isDirectory: true)
        let snapshot = try ProjectTestSupport.captureSnapshot(from: store, to: destination)
        XCTAssertEqual(snapshot.projectID, fixture.projectID)
        XCTAssertEqual(snapshot.revision, fixture.revision)
        XCTAssertEqual(snapshot.blobCount, 3)
        XCTAssertEqual(snapshot.fileCount, 4)
        XCTAssertGreaterThan(snapshot.totalByteCount, 0)
        let databaseURL = destination.appendingPathComponent("Building/Records.sqlite")
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + suffix))
        }
        let capturedBytes = try Data(contentsOf: databaseURL)
        XCTAssertEqual(try snapshot.verifyIntegrity().treeSHA256, snapshot.treeSHA256)
        XCTAssertEqual(try snapshot.verifyIntegrity().treeSHA256, snapshot.treeSHA256)
        XCTAssertEqual(try Data(contentsOf: databaseURL), capturedBytes,
                       "Repeated snapshot verification must not modify the database")

        // The live store may keep changing; the captured revision must not.
        let later = try store.createRoom(
            RoomDraft(name: "Living room", kind: .livingRoom),
            expectedRevision: fixture.revision
        )
        XCTAssertEqual(later.receipt.revision, fixture.revision + 1)
        try store.close()

        XCTAssertEqual(try snapshot.verifyIntegrity().treeSHA256, snapshot.treeSHA256)
        let reopened = try ProjectRecordsStore.openProject(at: snapshot.directoryURL)
        defer { try? reopened.close() }
        XCTAssertEqual(reopened.projectID, fixture.projectID)
        XCTAssertEqual(try reopened.currentRevision(), fixture.revision)
        XCTAssertEqual(try reopened.rooms().count, 1)
        XCTAssertEqual(try reopened.sources().count, 3)
        XCTAssertEqual(try reopened.observations().count, 1)
        XCTAssertEqual(try reopened.observation(fixture.observationID).propertyKey, "room.length_m")
        XCTAssertEqual(try reopened.bomTargets().count, 1)
        XCTAssertEqual(
            try reopened.bomItems(targetID: fixture.targetID, limit: 10).count,
            fixture.adoptedItemCount
        )
        let content = try reopened.sourceVersionContent(fixture.sourceVersionID)
        XCTAssertEqual(content.data, Data("kitchen 3.6 m".utf8))
    }

    func testExpectedRevisionMismatchLeavesNoOutput() throws {
        let root = try ProjectTestSupport.makeSpace("snapshot-revision")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectRecordsStore.createProject(
            at: root.appendingPathComponent("records", isDirectory: true),
            name: "Revision project"
        )
        let fixture = try ProjectTestSupport.populate(store)
        let destination = root.appendingPathComponent("snapshots/revision", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try store.captureSnapshot(to: destination, expectedRevision: 0)
        ) { error in
            XCTAssertEqual(
                error as? ProjectRecordsSnapshotError,
                .revisionMismatch(expected: 0, actual: fixture.revision)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try store.close()
    }

    func testExistingOutputIsNeverOverwritten() throws {
        let root = try ProjectTestSupport.makeSpace("snapshot-existing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectRecordsStore.createProject(
            at: root.appendingPathComponent("records", isDirectory: true),
            name: "Output project"
        )
        let destination = root.appendingPathComponent("snapshots/existing", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("marker.txt")
        try Data("keep me".utf8).write(to: marker)
        XCTAssertThrowsError(try store.captureSnapshot(to: destination)) { error in
            guard let snapshotError = error as? ProjectRecordsSnapshotError,
                  case .outputExists = snapshotError else {
                return XCTFail("expected outputExists, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep me".utf8))
        try store.close()
    }

    func testBudgetIsEnforcedBeforePublishingAnOutput() throws {
        let root = try ProjectTestSupport.makeSpace("snapshot-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectRecordsStore.createProject(
            at: root.appendingPathComponent("records", isDirectory: true),
            name: "Budget project"
        )
        _ = try ProjectTestSupport.populate(store)
        let destination = root.appendingPathComponent("snapshots/budget", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let limits = ProjectRecordsSnapshotLimits(
            maxFileCount: 10,
            maxTotalBytes: 1024,
            maxSingleFileBytes: 1024,
            copyChunkBytes: 65_536
        )
        XCTAssertThrowsError(try store.captureSnapshot(to: destination, limits: limits)) { error in
            guard let snapshotError = error as? ProjectRecordsSnapshotError,
                  case .budgetExceeded = snapshotError else {
                return XCTFail("expected budgetExceeded, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try store.close()
    }

    func testCancellationBeforeAndDuringBlobCopyRemovesPartialOutput() throws {
        let root = try ProjectTestSupport.makeSpace("snapshot-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectRecordsStore.createProject(
            at: root.appendingPathComponent("records", isDirectory: true),
            name: "Cancel project"
        )
        _ = try ProjectTestSupport.populate(store)

        let firstToken = BuildingProjectCancellation()
        firstToken.cancel()
        let firstDestination = root.appendingPathComponent("snapshots/cancel-before", isDirectory: true)
        XCTAssertThrowsError(
            try store.captureSnapshot(
                to: firstDestination,
                isCancelled: { firstToken.isCancelled }
            )
        ) { error in
            XCTAssertEqual(error as? ProjectRecordsSnapshotError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDestination.path))

        let token = BuildingProjectCancellation()
        let secondDestination = root.appendingPathComponent("snapshots/cancel-during", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let progress: @Sendable (ProjectRecordsSnapshotProgress) -> Void = { value in
            if value.phase == .blobs, value.completedFiles >= 1 {
                token.cancel()
            }
        }
        XCTAssertThrowsError(
            try store.captureSnapshot(
                to: secondDestination,
                isCancelled: { token.isCancelled },
                progress: progress
            )
        ) { error in
            XCTAssertEqual(error as? ProjectRecordsSnapshotError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondDestination.path))
        try store.close()
    }

    func testSidecarAndBlobEditAreRejected() throws {
        let root = try ProjectTestSupport.makeSpace("snapshot-integrity")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectRecordsStore.createProject(
            at: root.appendingPathComponent("records", isDirectory: true),
            name: "Integrity project"
        )
        _ = try ProjectTestSupport.populate(store)
        let destination = root.appendingPathComponent("snapshots/integrity", isDirectory: true)
        let snapshot = try ProjectTestSupport.captureSnapshot(from: store, to: destination)
        try store.close()

        for suffix in ["-wal", "-shm"] {
            let sidecar = snapshot.directoryURL
                .appendingPathComponent("Building/Records.sqlite" + suffix, isDirectory: false)
            try Data([0]).write(to: sidecar)
            XCTAssertThrowsError(try ProjectRecordsSnapshot.load(from: snapshot.directoryURL)) { error in
                guard let snapshotError = error as? ProjectRecordsSnapshotError,
                      case .snapshotNotQuiescent = snapshotError else {
                    return XCTFail("expected snapshotNotQuiescent, got \(error)")
                }
            }
            try FileManager.default.removeItem(at: sidecar)
        }

        let blobs = snapshot.directoryURL.appendingPathComponent("Building/Sources/blobs")
        let firstBlob = try XCTUnwrap(firstRegularFile(below: blobs))
        let original = try Data(contentsOf: firstBlob)
        var modified = original
        modified.append(0)
        try modified.write(to: firstBlob)
        XCTAssertThrowsError(try snapshot.verifyIntegrity()) { error in
            guard let snapshotError = error as? ProjectRecordsSnapshotError,
                  case .corruptedBlob = snapshotError else {
                return XCTFail("expected corruptedBlob, got \(error)")
            }
        }
    }

    func testProjectIdentityMismatchAndSourceOverlapAreRejected() throws {
        let root = try ProjectTestSupport.makeSpace("snapshot-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordsRoot = root.appendingPathComponent("records", isDirectory: true)
        let store = try ProjectRecordsStore.createProject(at: recordsRoot, name: "Identity project")
        _ = try ProjectTestSupport.populate(store)
        let destination = root.appendingPathComponent("snapshots/identity", isDirectory: true)
        XCTAssertThrowsError(
            try store.captureSnapshot(to: destination, projectID: ProjectID())
        ) { error in
            XCTAssertEqual(error as? ProjectRecordsSnapshotError, .projectMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let inside = recordsRoot.appendingPathComponent("inside-snapshot", isDirectory: true)
        XCTAssertThrowsError(try store.captureSnapshot(to: inside)) { error in
            XCTAssertEqual(error as? ProjectRecordsSnapshotError, .destinationInsideSource)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path))
        try store.close()
    }

    private func firstRegularFile(below root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return nil }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return url
            }
        }
        return nil
    }
}
