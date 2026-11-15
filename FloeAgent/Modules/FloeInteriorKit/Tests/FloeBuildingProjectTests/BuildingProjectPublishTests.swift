import CryptoKit
import Foundation
import XCTest
import FloeBuildingProject
import FloeBuildingRecords

final class BuildingProjectPublishTests: XCTestCase {
    func testWorkingCopyPublishReopenAndContinuousSave() throws {
        let root = try ProjectTestSupport.makeSpace("publish-lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try BuildingProjectRepository.create(
            at: root.appendingPathComponent("project", isDirectory: true)
        )
        let workingCopy = try repository.createWorkingCopy(initialProjectName: "Interior project")
        let store = try ProjectRecordsStore.openProject(at: workingCopy.recordsDirectoryURL)
        var storeIsOpen = true
        defer { if storeIsOpen { try? store.close() } }
        let fixture = try ProjectTestSupport.populate(store)
        let firstInputs = try makeInputs(root, fixture: fixture, tag: "first")
        let firstSnapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: root.appendingPathComponent("snapshots/first", isDirectory: true)
        )
        let firstCommit = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            workingCopy,
            expectedBaseGenerationID: nil,
            commitID: firstCommit
        )
        let firstResult = try repository.publish(makeRequest(
            commitID: firstCommit,
            expected: .emptyProject,
            snapshot: firstSnapshot,
            inputs: firstInputs
        ))
        XCTAssertFalse(firstResult.wasAlreadyPublished)
        XCTAssertEqual(firstResult.manifest.sequence, 1)
        XCTAssertEqual(firstResult.generation.record.identity.recordsRevision, firstSnapshot.revision)
        XCTAssertEqual(firstResult.generation.record.fileCount, firstResult.generation.record.files.count)

        // The Records connection remains the same object and the working
        // directory is not replaced. Edits made after the snapshot stay in the
        // working copy and are not part of the published snapshot.
        let edited = try store.createRoom(
            RoomDraft(name: "Dining room", kind: .dining),
            expectedRevision: firstSnapshot.revision
        )
        XCTAssertEqual(edited.receipt.revision, firstSnapshot.revision + 1)
        let rebased = try repository.rebaseWorkingCopy(
            workingCopy,
            to: firstResult.generation.generationID,
            expectedBaseGenerationID: nil,
            commitID: firstCommit
        )
        XCTAssertEqual(rebased.metadata.baseGenerationID, firstResult.generation.generationID)
        XCTAssertNil(rebased.metadata.pendingCommitID)
        XCTAssertEqual(rebased.metadata.lastAcknowledgedCommitID, firstCommit)
        XCTAssertEqual(try store.currentRevision(), firstSnapshot.revision + 1)

        let secondSnapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: root.appendingPathComponent("snapshots/second", isDirectory: true)
        )
        XCTAssertEqual(secondSnapshot.revision, firstSnapshot.revision + 1)
        XCTAssertNotEqual(secondSnapshot.treeSHA256, firstSnapshot.treeSHA256)
        let secondCommit = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            rebased,
            expectedBaseGenerationID: firstResult.generation.generationID,
            commitID: secondCommit
        )
        let secondResult = try repository.publish(makeRequest(
            commitID: secondCommit,
            expected: .generation(firstResult.generation.generationID),
            snapshot: secondSnapshot,
            inputs: firstInputs
        ))
        XCTAssertEqual(secondResult.manifest.sequence, 2)
        XCTAssertEqual(secondResult.manifest.previousGenerationID, firstResult.generation.generationID)
        let rebasedAgain = try repository.rebaseWorkingCopy(
            rebased,
            to: secondResult.generation.generationID,
            expectedBaseGenerationID: firstResult.generation.generationID,
            commitID: secondCommit
        )
        XCTAssertEqual(rebasedAgain.metadata.baseGenerationID, secondResult.generation.generationID)
        XCTAssertNil(rebasedAgain.metadata.pendingCommitID)
        try store.close()
        storeIsOpen = false

        let reopened = try BuildingProjectRepository.open(at: repository.rootURL)
        let current = try XCTUnwrap(reopened.currentGeneration())
        XCTAssertEqual(current.generationID, secondResult.generation.generationID)
        XCTAssertEqual(current.record.identity.recordsRevision, secondSnapshot.revision)
        let reopenedWorkingCopy = try reopened.createWorkingCopy(
            from: secondResult.generation.generationID
        )
        XCTAssertEqual(reopenedWorkingCopy.metadata.baseGenerationID, secondResult.generation.generationID)
        let reopenedStore = try ProjectRecordsStore.openProject(at: reopenedWorkingCopy.recordsDirectoryURL)
        defer { try? reopenedStore.close() }
        XCTAssertEqual(try reopenedStore.currentRevision(), secondSnapshot.revision)
        XCTAssertEqual(try reopenedStore.rooms().count, 2)
        XCTAssertEqual(try reopenedStore.sources().count, 3)
        XCTAssertEqual(try reopenedStore.observations().count, 1)
        XCTAssertEqual(
            try reopenedStore.bomItems(targetID: fixture.targetID, limit: 10).count,
            fixture.adoptedItemCount
        )
        XCTAssertEqual(
            try reopenedStore.sourceVersionContent(fixture.sourceVersionID).data,
            Data("kitchen 3.6 m".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: reopenedWorkingCopy.editorStateURL),
            firstInputs.editorState
        )
        XCTAssertEqual(
            try Data(contentsOf: reopenedWorkingCopy.assetResourcesDirectoryURL
                .appendingPathComponent("armchair.obj")),
            try Data(contentsOf: firstInputs.resources.appendingPathComponent("armchair.obj"))
        )
        XCTAssertEqual(
            try Data(contentsOf: reopenedWorkingCopy.cadDirectoryURL
                .appendingPathComponent("geometry/mesh.bin")),
            try Data(contentsOf: firstInputs.cad.appendingPathComponent("geometry/mesh.bin"))
        )
    }

    func testWorkingCopiesCanBeListedAndOpenedBeforeFirstPublication() throws {
        let root = try ProjectTestSupport.makeSpace("working-copy-catalog")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try BuildingProjectRepository.create(
            at: root.appendingPathComponent("project", isDirectory: true)
        )
        let workingCopy = try repository.createWorkingCopy(initialProjectName: "Recoverable project")
        let listed = try repository.workingCopies()
        XCTAssertEqual(listed.map(\.workingCopyID), [workingCopy.workingCopyID])
        let opened = try repository.openWorkingCopy(workingCopy.workingCopyID)
        XCTAssertEqual(
            opened.directoryURL.standardizedFileURL,
            workingCopy.directoryURL.standardizedFileURL
        )
        XCTAssertNil(opened.baseGenerationID)
        let store = try ProjectRecordsStore.openProject(at: opened.recordsDirectoryURL)
        XCTAssertEqual(try store.currentRevision(), 0)
        try store.close()
        try repository.discardWorkingCopy(opened)
        XCTAssertTrue(try repository.workingCopies().isEmpty)
    }

    func testPublishIsIdempotentAndKeepsManifestGeneration() throws {
        let scenario = try PublishedScenario(name: "publish-idempotent")
        let retry = try scenario.repository.publish(scenario.request)
        XCTAssertTrue(retry.wasAlreadyPublished)
        XCTAssertEqual(retry.manifest.sequence, 1)
        XCTAssertEqual(retry.manifest.generationID, scenario.result.manifest.generationID)
        XCTAssertEqual(
            try scenario.repository.currentGeneration()?.generationID,
            scenario.result.generation.generationID
        )
    }

    func testRebaseUpdatesOnlyMetadataAndKeepsWorkingFiles() throws {
        let scenario = try PublishedScenario(name: "publish-rebase-files")
        let workingCopy = try scenario.repository.createWorkingCopy(
            from: scenario.result.generation.generationID
        )
        let cadBefore = try directoryDigest(workingCopy.cadDirectoryURL)
        let resourcesBefore = try directoryDigest(workingCopy.assetResourcesDirectoryURL)
        let editorBefore = try Data(contentsOf: workingCopy.editorStateURL)
        let recordsDatabaseBefore = try Data(contentsOf: workingCopy.recordsDirectoryURL
            .appendingPathComponent("Building/Records.sqlite"))
        let rebased = try scenario.repository.rebaseWorkingCopy(
            workingCopy,
            to: scenario.result.generation.generationID,
            expectedBaseGenerationID: scenario.result.generation.generationID,
            commitID: BuildingCommitID()
        )
        XCTAssertEqual(rebased.metadata.baseGenerationID, scenario.result.generation.generationID)
        XCTAssertEqual(try directoryDigest(workingCopy.cadDirectoryURL), cadBefore)
        XCTAssertEqual(try directoryDigest(workingCopy.assetResourcesDirectoryURL), resourcesBefore)
        XCTAssertEqual(try Data(contentsOf: workingCopy.editorStateURL), editorBefore)
        XCTAssertEqual(
            try Data(contentsOf: workingCopy.recordsDirectoryURL
                .appendingPathComponent("Building/Records.sqlite")),
            recordsDatabaseBefore
        )
    }

    func testEditorStateAndAssetResourceIntegrity() throws {
        let scenario = try PublishedScenario(name: "publish-editor-resources")
        XCTAssertEqual(
            try Data(contentsOf: scenario.result.generation.editorStateURL),
            scenario.inputs.editorState
        )
        XCTAssertEqual(
            try Data(contentsOf: scenario.result.generation.assetResourcesDirectoryURL
                .appendingPathComponent("armchair.mtl")),
            try Data(contentsOf: scenario.inputs.resources.appendingPathComponent("armchair.mtl"))
        )

        let invalidRoot = try ProjectTestSupport.makeSpace("publish-invalid-editor")
        defer { try? FileManager.default.removeItem(at: invalidRoot) }
        let repository = try BuildingProjectRepository.create(
            at: invalidRoot.appendingPathComponent("project", isDirectory: true)
        )
        let workingCopy = try repository.createWorkingCopy(initialProjectName: "Editor state")
        let store = try ProjectRecordsStore.openProject(at: workingCopy.recordsDirectoryURL)
        let fixture = try ProjectTestSupport.populate(store)
        let snapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: invalidRoot.appendingPathComponent("snapshots/editor", isDirectory: true)
        )
        let cad = invalidRoot.appendingPathComponent("inputs/cad", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: cad)
        let identity = try ProjectTestSupport.makeIdentity(snapshot: snapshot)
        let commit = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            workingCopy,
            expectedBaseGenerationID: nil,
            commitID: commit
        )
        let invalidJSON = Data("[1,2,3]".utf8)
        XCTAssertThrowsError(try repository.publish(BuildingProjectCommitRequest(
            commitID: commit,
            expectedGeneration: .emptyProject,
            identity: identity,
            recordsSnapshot: snapshot,
            cadDirectoryURL: cad,
            editorState: invalidJSON
        ))) { error in
            XCTAssertEqual(error as? BuildingProjectError, .editorStateInvalid(
                "the editor state must be a JSON object"
            ))
        }
        let oversized = Data(repeating: 0x20, count: repository.configuration.limits.maxEditorStateBytes + 1)
        XCTAssertThrowsError(try repository.publish(BuildingProjectCommitRequest(
            commitID: commit,
            expectedGeneration: .emptyProject,
            identity: identity,
            recordsSnapshot: snapshot,
            cadDirectoryURL: cad,
            editorState: oversized
        ))) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .budgetExceeded = buildingError else {
                return XCTFail("expected budgetExceeded, got \(error)")
            }
        }
        try store.close()
    }

    func testCorruptAssetResourceIsDetectedOnReopen() throws {
        let scenario = try PublishedScenario(name: "publish-resource-corruption")
        let resource = scenario.result.generation.assetResourcesDirectoryURL
            .appendingPathComponent("textures/armchair.png")
        var data = try Data(contentsOf: resource)
        data.append(0)
        try data.write(to: resource)
        XCTAssertThrowsError(try scenario.repository.currentGeneration()) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .generationCorrupted = buildingError else {
                return XCTFail("expected generationCorrupted, got \(error)")
            }
        }
    }

    private func makeRequest(
        commitID: BuildingCommitID,
        expected: BuildingGenerationExpectation,
        snapshot: ProjectRecordsSnapshot,
        inputs: PublishInputs
    ) throws -> BuildingProjectCommitRequest {
        BuildingProjectCommitRequest(
            commitID: commitID,
            expectedGeneration: expected,
            identity: try ProjectTestSupport.makeIdentity(snapshot: snapshot),
            recordsSnapshot: snapshot,
            cadDirectoryURL: inputs.cad,
            assetResourcesDirectoryURL: inputs.resources,
            editorState: inputs.editorState
        )
    }

    private func makeInputs(
        _ root: URL,
        fixture: ProjectFixture,
        tag: String
    ) throws -> PublishInputs {
        let cad = root.appendingPathComponent("inputs/\(tag)-cad", isDirectory: true)
        let resources = root.appendingPathComponent("inputs/\(tag)-resources", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: cad)
        try ProjectTestSupport.makeAssetResourceDirectory(at: resources)
        let editorState = try ProjectTestSupport.makeEditorState(
            projectID: fixture.projectID,
            roomID: fixture.roomID
        )
        return PublishInputs(cad: cad, resources: resources, editorState: editorState)
    }
}

private struct PublishInputs {
    let cad: URL
    let resources: URL
    let editorState: Data
}

private final class PublishedScenario {
    let root: URL
    let repository: BuildingProjectRepository
    let result: BuildingProjectCommitResult
    let request: BuildingProjectCommitRequest
    let inputs: PublishInputs

    init(name: String) throws {
        let root = try ProjectTestSupport.makeSpace(name)
        self.root = root
        let repository = try BuildingProjectRepository.create(
            at: root.appendingPathComponent("project", isDirectory: true)
        )
        self.repository = repository
        let workingCopy = try repository.createWorkingCopy(initialProjectName: "Scenario project")
        let store = try ProjectRecordsStore.openProject(at: workingCopy.recordsDirectoryURL)
        let fixture = try ProjectTestSupport.populate(store)
        let snapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: root.appendingPathComponent("snapshots/scenario", isDirectory: true)
        )
        let inputs = PublishInputs(
            cad: root.appendingPathComponent("inputs/cad", isDirectory: true),
            resources: root.appendingPathComponent("inputs/resources", isDirectory: true),
            editorState: try ProjectTestSupport.makeEditorState(
                projectID: fixture.projectID,
                roomID: fixture.roomID
            )
        )
        try ProjectTestSupport.makeCADDirectory(at: inputs.cad)
        try ProjectTestSupport.makeAssetResourceDirectory(at: inputs.resources)
        let commit = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            workingCopy,
            expectedBaseGenerationID: nil,
            commitID: commit
        )
        let request = BuildingProjectCommitRequest(
            commitID: commit,
            expectedGeneration: .emptyProject,
            identity: try ProjectTestSupport.makeIdentity(snapshot: snapshot),
            recordsSnapshot: snapshot,
            cadDirectoryURL: inputs.cad,
            assetResourcesDirectoryURL: inputs.resources,
            editorState: inputs.editorState
        )
        self.inputs = inputs
        self.request = request
        self.result = try repository.publish(request)
        try store.close()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private func directoryDigest(_ root: URL) throws -> String {
    var files: [ProjectFileDigest] = []
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: []
    ) else {
        return ProjectFileTreeDigest.digest(files)
    }
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else { continue }
        let data = try Data(contentsOf: url)
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        files.append(ProjectFileDigest(relativePath: relative, byteCount: size, sha256: digest))
    }
    return ProjectFileTreeDigest.digest(files)
}
