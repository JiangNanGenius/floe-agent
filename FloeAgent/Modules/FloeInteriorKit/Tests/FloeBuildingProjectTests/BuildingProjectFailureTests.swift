import Foundation
import XCTest
import FloeBuildingProject
import FloeBuildingRecords

final class BuildingProjectFailureTests: XCTestCase {
    func testCorruptedPublishedFileAndExtraFileAreRejected() throws {
        let scenario = try makeFailureScenario("corrupt-published")
        defer { try? FileManager.default.removeItem(at: scenario.spaceURL) }
        let cadFile = scenario.result.generation.cadDirectoryURL.appendingPathComponent("model.json")
        var bytes = try Data(contentsOf: cadFile)
        bytes.append(0)
        try bytes.write(to: cadFile)
        XCTAssertThrowsError(try scenario.repository.currentGeneration()) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .generationCorrupted = buildingError else {
                return XCTFail("expected generationCorrupted, got \(error)")
            }
        }

        let second = try makeFailureScenario("extra-published-file")
        defer { try? FileManager.default.removeItem(at: second.spaceURL) }
        let extra = second.result.generation.cadDirectoryURL.appendingPathComponent("extra.txt")
        try Data("not in Generation.json".utf8).write(to: extra)
        XCTAssertThrowsError(try second.repository.currentGeneration()) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .generationCorrupted = buildingError else {
                return XCTFail("expected generationCorrupted, got \(error)")
            }
        }
    }

    func testGenerationJSONPathEscapeIsRejected() throws {
        let scenario = try makeFailureScenario("path-escape")
        defer { try? FileManager.default.removeItem(at: scenario.spaceURL) }
        let generationURL = scenario.result.generation.directoryURL
            .appendingPathComponent("Generation.json")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: generationURL)) as? [String: Any]
        )
        var files = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertFalse(files.isEmpty)
        files[0]["relativePath"] = "../escaped"
        object["files"] = files
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: generationURL)
        XCTAssertThrowsError(try scenario.repository.currentGeneration()) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .pathEscapesRoot = buildingError else {
                return XCTFail("expected pathEscapesRoot, got \(error)")
            }
        }
    }

    func testCADInputSymlinkAndIdentityMismatchAreRejected() throws {
        let scenario = try makeFailureScenario("input-symlink")
        defer { try? FileManager.default.removeItem(at: scenario.spaceURL) }
        let repository = try BuildingProjectRepository.open(at: scenario.projectURL)
        let workingCopy = try repository.createWorkingCopy(
            from: scenario.result.generation.generationID
        )
        let store = try ProjectRecordsStore.openProject(at: workingCopy.recordsDirectoryURL)
        let snapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: scenario.spaceURL.appendingPathComponent("snapshots/next", isDirectory: true)
        )
        try store.close()
        let cad = scenario.spaceURL.appendingPathComponent("inputs/symlink-cad", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: cad)
        try FileManager.default.createSymbolicLink(
            at: cad.appendingPathComponent("linked.json"),
            withDestinationURL: cad.appendingPathComponent("model.json")
        )
        let commit = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            workingCopy,
            expectedBaseGenerationID: scenario.result.generation.generationID,
            commitID: commit
        )
        XCTAssertThrowsError(try repository.publish(BuildingProjectCommitRequest(
            commitID: commit,
            expectedGeneration: .generation(scenario.result.generation.generationID),
            identity: try ProjectTestSupport.makeIdentity(snapshot: snapshot),
            recordsSnapshot: snapshot,
            cadDirectoryURL: cad
        ))) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .symbolicLinkRejected = buildingError else {
                return XCTFail("expected symbolicLinkRejected, got \(error)")
            }
        }
        XCTAssertEqual(
            try repository.currentGeneration()?.generationID,
            scenario.result.generation.generationID
        )

        let badIdentity = try BuildingStoredIdentity(
            cadRevision: 7,
            cadContentSHA256: ProjectTestSupport.hex("a"),
            cadModelSHA256: ProjectTestSupport.hex("b"),
            recordsProjectID: snapshot.projectID,
            recordsRevision: snapshot.revision + 1
        )
        XCTAssertThrowsError(try repository.publish(BuildingProjectCommitRequest(
            commitID: commit,
            expectedGeneration: .generation(scenario.result.generation.generationID),
            identity: badIdentity,
            recordsSnapshot: snapshot,
            cadDirectoryURL: cad
        ))) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .recordsSnapshotMismatch = buildingError else {
                return XCTFail("expected recordsSnapshotMismatch, got \(error)")
            }
        }
    }

    func testInvalidIdentityIsRejectedAtConstruction() throws {
        XCTAssertThrowsError(try BuildingStoredIdentity(
            cadRevision: 1,
            cadContentSHA256: "not-a-digest",
            cadModelSHA256: ProjectTestSupport.hex("b"),
            recordsProjectID: ProjectID(),
            recordsRevision: 0
        )) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .invalidIdentity = buildingError else {
                return XCTFail("expected invalidIdentity, got \(error)")
            }
        }
    }

    func testRepositoryBudgetAndExistingRootProtection() throws {
        let root = try ProjectTestSupport.makeSpace("repo-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = BuildingProjectConfiguration(
            limits: BuildingProjectLimits(maxFileCount: 1)
        )
        let repositoryRoot = root.appendingPathComponent("project", isDirectory: true)
        let repository = try BuildingProjectRepository.create(
            at: repositoryRoot,
            configuration: configuration
        )
        let workingCopy = try repository.createWorkingCopy(initialProjectName: "Budget project")
        let store = try ProjectRecordsStore.openProject(at: workingCopy.recordsDirectoryURL)
        let fixture = try ProjectTestSupport.populate(store)
        let snapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: root.appendingPathComponent("snapshots/budget", isDirectory: true)
        )
        try store.close()
        let cad = root.appendingPathComponent("inputs/cad", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: cad)
        let commit = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            workingCopy,
            expectedBaseGenerationID: nil,
            commitID: commit
        )
        XCTAssertThrowsError(try repository.publish(BuildingProjectCommitRequest(
            commitID: commit,
            expectedGeneration: .emptyProject,
            identity: try ProjectTestSupport.makeIdentity(snapshot: snapshot),
            recordsSnapshot: snapshot,
            cadDirectoryURL: cad,
            editorState: try ProjectTestSupport.makeEditorState(
                projectID: fixture.projectID,
                roomID: fixture.roomID
            )
        ))) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .budgetExceeded = buildingError else {
                return XCTFail("expected budgetExceeded, got \(error)")
            }
        }
        XCTAssertNil(try repository.loadManifest())
        XCTAssertThrowsError(try BuildingProjectRepository.create(at: repositoryRoot)) { error in
            XCTAssertEqual(error as? BuildingProjectError, .rootAlreadyExists)
        }
    }

    func testCancellationBeforePublishDoesNotTouchManifest() throws {
        let root = try ProjectTestSupport.makeSpace("repo-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try BuildingProjectRepository.create(
            at: root.appendingPathComponent("project", isDirectory: true)
        )
        let workingCopy = try repository.createWorkingCopy(initialProjectName: "Cancel project")
        let store = try ProjectRecordsStore.openProject(at: workingCopy.recordsDirectoryURL)
        let fixture = try ProjectTestSupport.populate(store)
        let snapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: root.appendingPathComponent("snapshots/cancel", isDirectory: true)
        )
        try store.close()
        let cad = root.appendingPathComponent("inputs/cad", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: cad)
        let commit = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            workingCopy,
            expectedBaseGenerationID: nil,
            commitID: commit
        )
        let cancellation = BuildingProjectCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try repository.publish(BuildingProjectCommitRequest(
            commitID: commit,
            expectedGeneration: .emptyProject,
            identity: try ProjectTestSupport.makeIdentity(snapshot: snapshot),
            recordsSnapshot: snapshot,
            cadDirectoryURL: cad,
            editorState: try ProjectTestSupport.makeEditorState(
                projectID: fixture.projectID,
                roomID: fixture.roomID
            )
        ), cancellation: cancellation)) { error in
            XCTAssertEqual(error as? BuildingProjectError, .cancelled)
        }
        XCTAssertNil(try repository.loadManifest())
    }

    func testSnapshotExternalEditIsDetectedBeforePublish() throws {
        let scenario = try makeFailureScenario("snapshot-edit")
        defer { try? FileManager.default.removeItem(at: scenario.spaceURL) }
        let repository = try BuildingProjectRepository.open(at: scenario.projectURL)
        let workingCopy = try repository.createWorkingCopy(
            from: scenario.result.generation.generationID
        )
        let store = try ProjectRecordsStore.openProject(at: workingCopy.recordsDirectoryURL)
        let snapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: scenario.spaceURL.appendingPathComponent("snapshots/external", isDirectory: true)
        )
        try store.close()
        let blobs = snapshot.directoryURL.appendingPathComponent("Building/Sources/blobs")
        let firstBlob = try XCTUnwrap(firstRegularFile(below: blobs))
        var data = try Data(contentsOf: firstBlob)
        data.append(1)
        try data.write(to: firstBlob)
        let cad = scenario.spaceURL.appendingPathComponent("inputs/cad", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: cad)
        let commit = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            workingCopy,
            expectedBaseGenerationID: scenario.result.generation.generationID,
            commitID: commit
        )
        XCTAssertThrowsError(try repository.publish(BuildingProjectCommitRequest(
            commitID: commit,
            expectedGeneration: .generation(scenario.result.generation.generationID),
            identity: try ProjectTestSupport.makeIdentity(snapshot: snapshot),
            recordsSnapshot: snapshot,
            cadDirectoryURL: cad
        ))) { error in
            guard let snapshotError = error as? ProjectRecordsSnapshotError,
                  case .corruptedBlob = snapshotError else {
                return XCTFail("expected corruptedBlob, got \(error)")
            }
        }
        XCTAssertEqual(
            try repository.currentGeneration()?.generationID,
            scenario.result.generation.generationID
        )
    }

    func testManifestCorruptionIsReported() throws {
        let scenario = try makeFailureScenario("manifest-corrupt")
        defer { try? FileManager.default.removeItem(at: scenario.spaceURL) }
        let manifest = scenario.projectURL.appendingPathComponent("Manifest.json")
        try Data("{not json".utf8).write(to: manifest)
        XCTAssertThrowsError(try scenario.repository.loadManifest()) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .manifestCorrupted = buildingError else {
                return XCTFail("expected manifestCorrupted, got \(error)")
            }
        }
    }

    private func makeFailureScenario(_ name: String) throws -> FailureScenario {
        let root = try ProjectTestSupport.makeSpace(name)
        let repository = try BuildingProjectRepository.create(
            at: root.appendingPathComponent("project", isDirectory: true)
        )
        let workingCopy = try repository.createWorkingCopy(initialProjectName: "Failure project")
        let store = try ProjectRecordsStore.openProject(at: workingCopy.recordsDirectoryURL)
        let fixture = try ProjectTestSupport.populate(store)
        let snapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: root.appendingPathComponent("snapshots/base", isDirectory: true)
        )
        try store.close()
        let cad = root.appendingPathComponent("inputs/cad", isDirectory: true)
        let resources = root.appendingPathComponent("inputs/resources", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: cad)
        try ProjectTestSupport.makeAssetResourceDirectory(at: resources)
        let commit = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            workingCopy,
            expectedBaseGenerationID: nil,
            commitID: commit
        )
        let result = try repository.publish(BuildingProjectCommitRequest(
            commitID: commit,
            expectedGeneration: .emptyProject,
            identity: try ProjectTestSupport.makeIdentity(snapshot: snapshot),
            recordsSnapshot: snapshot,
            cadDirectoryURL: cad,
            assetResourcesDirectoryURL: resources,
            editorState: try ProjectTestSupport.makeEditorState(
                projectID: fixture.projectID,
                roomID: fixture.roomID
            )
        ))
        return FailureScenario(spaceURL: root, projectURL: repository.rootURL, repository: repository, result: result)
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

private struct FailureScenario {
    let spaceURL: URL
    let projectURL: URL
    let repository: BuildingProjectRepository
    let result: BuildingProjectCommitResult
}
