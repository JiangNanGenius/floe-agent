import Foundation
import XCTest
import FloeBuildingProject
import FloeBuildingRecords

final class BuildingProjectRecoveryTests: XCTestCase {
    func testInterruptedStagingIsNeverVisibleAsPublished() throws {
        for point in [
            BuildingProjectFaultPoint.afterPreparation,
            .afterCADCopy,
            .afterRecordsCopy
        ] {
            let baseline = try makeBaseline("interrupt-\(point.rawValue)")
            let candidate = try makeCandidate(
                baseline: baseline,
                name: point.rawValue,
                fault: point
            )
            XCTAssertThrowsError(try candidate.repository.publish(candidate.request)) { error in
                XCTAssertEqual(error as? BuildingProjectError, .injectedFailure(point))
            }
            let fresh = try BuildingProjectRepository.open(at: baseline.projectURL)
            XCTAssertEqual(
                try fresh.currentGeneration()?.generationID,
                baseline.result.generation.generationID
            )
            let report = try fresh.recover(.reportOnly)
            XCTAssertTrue(report.entries.contains { $0.outcome == .incomplete })
            XCTAssertEqual(report.currentGenerationID, baseline.result.generation.generationID)
            XCTAssertEqual(
                try Data(contentsOf: candidate.inputs.cad.appendingPathComponent("model.json")),
                candidate.cadModelBytes
            )
            let abandoned = try fresh.recover(.abandonUnpublished)
            XCTAssertTrue(abandoned.entries.contains { $0.outcome == .abandoned })
            XCTAssertEqual(
                try fresh.currentGeneration()?.generationID,
                baseline.result.generation.generationID
            )
            try? FileManager.default.removeItem(at: baseline.spaceURL)
        }
    }

    func testBeforeManifestCandidateCanBeResumed() throws {
        let baseline = try makeBaseline("resume-before-manifest")
        defer { try? FileManager.default.removeItem(at: baseline.spaceURL) }
        let candidate = try makeCandidate(
            baseline: baseline,
            name: "resume",
            fault: .beforeManifestPublish
        )
        XCTAssertThrowsError(try candidate.repository.publish(candidate.request)) { error in
            XCTAssertEqual(error as? BuildingProjectError, .injectedFailure(.beforeManifestPublish))
        }
        let fresh = try BuildingProjectRepository.open(at: baseline.projectURL)
        XCTAssertEqual(
            try fresh.currentGeneration()?.generationID,
            baseline.result.generation.generationID
        )
        let report = try fresh.recover(.reportOnly)
        XCTAssertTrue(report.entries.contains { $0.outcome == .readyToResume })
        XCTAssertEqual(report.currentGenerationID, baseline.result.generation.generationID)

        let resumed = try fresh.recover(.resumeUnpublished)
        XCTAssertTrue(resumed.entries.contains { $0.outcome == .resumed })
        let current = try XCTUnwrap(fresh.currentGeneration())
        XCTAssertEqual(current.record.identity.recordsRevision, candidate.snapshot.revision)
        XCTAssertEqual(current.sequence, 2)
        XCTAssertEqual(resumed.currentGenerationID, current.generationID)
        XCTAssertEqual(
            try Data(contentsOf: current.cadDirectoryURL.appendingPathComponent("model.json")),
            candidate.cadModelBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: current.editorStateURL),
            candidate.request.editorState
        )
    }

    func testManifestPublishedBeforeJournalOrWorkingAckRecovers() throws {
        let baseline = try makeBaseline("resume-after-manifest")
        defer { try? FileManager.default.removeItem(at: baseline.spaceURL) }
        let candidate = try makeCandidate(
            baseline: baseline,
            name: "after-manifest",
            fault: .afterManifestPublish
        )
        XCTAssertThrowsError(try candidate.repository.publish(candidate.request)) { error in
            XCTAssertEqual(error as? BuildingProjectError, .injectedFailure(.afterManifestPublish))
        }
        let fresh = try BuildingProjectRepository.open(at: baseline.projectURL)
        let currentBefore = try XCTUnwrap(fresh.currentGeneration())
        XCTAssertNotEqual(currentBefore.generationID, baseline.result.generation.generationID)
        XCTAssertEqual(currentBefore.record.identity.recordsRevision, candidate.snapshot.revision)

        let report = try fresh.recover(.reportOnly)
        XCTAssertTrue(report.entries.contains { $0.outcome == .completedAfterManifest })
        XCTAssertEqual(report.currentGenerationID, currentBefore.generationID)
        XCTAssertTrue(report.workingCopies.contains {
            $0.workingCopyID == candidate.workingCopy.workingCopyID
                && $0.outcome == .acknowledgedByManifest
        })
        let acknowledged = try XCTUnwrap(report.workingCopies.first {
            $0.workingCopyID == candidate.workingCopy.workingCopyID
        })
        XCTAssertEqual(acknowledged.baseGenerationID, currentBefore.generationID)

        // The same working directory can start another save from the recovered
        // baseline without reloading or losing its Records connection.
        let nextCommit = BuildingCommitID()
        _ = try fresh.beginWorkingCopySave(
            candidate.workingCopy,
            expectedBaseGenerationID: currentBefore.generationID,
            commitID: nextCommit
        )
        _ = try fresh.cancelWorkingCopySave(
            candidate.workingCopy,
            commitID: nextCommit
        )
    }

    func testGenerationCASConflictKeepsTheNewerGeneration() throws {
        let baseline = try makeBaseline("cas-conflict")
        defer { try? FileManager.default.removeItem(at: baseline.spaceURL) }
        let candidateB = try makeCandidate(baseline: baseline, name: "b", fault: nil)
        let candidateC = try makeCandidate(baseline: baseline, name: "c", fault: nil)
        let repositoryB = try BuildingProjectRepository.open(at: baseline.projectURL)
        let resultB = try repositoryB.publish(candidateB.request)
        XCTAssertFalse(resultB.wasAlreadyPublished)

        let repositoryC = try BuildingProjectRepository.open(at: baseline.projectURL)
        XCTAssertThrowsError(try repositoryC.publish(candidateC.request)) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .generationExpectationConflict(let expected, let actual) = buildingError else {
                return XCTFail("expected generationExpectationConflict, got \(error)")
            }
            XCTAssertEqual(expected, baseline.result.generation.generationID)
            XCTAssertEqual(actual, resultB.generation.generationID)
        }
        let fresh = try BuildingProjectRepository.open(at: baseline.projectURL)
        XCTAssertEqual(
            try fresh.currentGeneration()?.generationID,
            resultB.generation.generationID
        )
        let report = try fresh.recover(.reportOnly)
        XCTAssertTrue(report.entries.contains { $0.outcome == .conflict })
        XCTAssertEqual(report.currentGenerationID, resultB.generation.generationID)
        let abandoned = try fresh.recover(.abandonUnpublished)
        XCTAssertTrue(abandoned.entries.contains { $0.outcome == .abandoned })
        XCTAssertEqual(
            try fresh.currentGeneration()?.generationID,
            resultB.generation.generationID
        )
        let abandonedRoot = baseline.projectURL.appendingPathComponent("Abandoned", isDirectory: true)
        let abandonedNames = try FileManager.default.contentsOfDirectory(atPath: abandonedRoot.path)
        XCTAssertFalse(abandonedNames.isEmpty)
    }

    func testWorkingCopyBaseCASAndDiscardLifecycle() throws {
        let baseline = try makeBaseline("working-copy-cas")
        defer { try? FileManager.default.removeItem(at: baseline.spaceURL) }
        let repository = try BuildingProjectRepository.open(at: baseline.projectURL)
        let copy = try repository.createWorkingCopy(from: baseline.result.generation.generationID)
        XCTAssertThrowsError(try repository.beginWorkingCopySave(
            copy,
            expectedBaseGenerationID: nil,
            commitID: BuildingCommitID()
        )) { error in
            guard let buildingError = error as? BuildingProjectError,
                  case .workingCopyBaseConflict = buildingError else {
                return XCTFail("expected workingCopyBaseConflict, got \(error)")
            }
        }
        let first = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            copy,
            expectedBaseGenerationID: baseline.result.generation.generationID,
            commitID: first
        )
        XCTAssertThrowsError(try repository.beginWorkingCopySave(
            copy,
            expectedBaseGenerationID: baseline.result.generation.generationID,
            commitID: BuildingCommitID()
        )) { error in
            XCTAssertEqual(error as? BuildingProjectError, .workingCopySaveInProgress(first))
        }
        XCTAssertThrowsError(try repository.discardWorkingCopy(copy)) { error in
            XCTAssertEqual(error as? BuildingProjectError, .workingCopySaveInProgress(first))
        }
        let cancelled = try repository.cancelWorkingCopySave(copy, commitID: first)
        XCTAssertNil(cancelled.metadata.pendingCommitID)
        let rebased = try repository.rebaseWorkingCopy(
            cancelled,
            to: baseline.result.generation.generationID,
            expectedBaseGenerationID: baseline.result.generation.generationID,
            commitID: BuildingCommitID()
        )
        XCTAssertEqual(
            rebased.metadata.baseGenerationID,
            baseline.result.generation.generationID
        )
        try repository.discardWorkingCopy(rebased)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rebased.directoryURL.path))
    }

    // MARK: - Fixtures

    private func makeBaseline(_ name: String) throws -> RecoveryBaseline {
        let root = try ProjectTestSupport.makeSpace(name)
        let repository = try BuildingProjectRepository.create(
            at: root.appendingPathComponent("project", isDirectory: true)
        )
        let workingCopy = try repository.createWorkingCopy(initialProjectName: "Recovery project")
        let store = try ProjectRecordsStore.openProject(at: workingCopy.recordsDirectoryURL)
        let fixture = try ProjectTestSupport.populate(store)
        let snapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: root.appendingPathComponent("snapshots/baseline", isDirectory: true)
        )
        let cad = root.appendingPathComponent("inputs/baseline-cad", isDirectory: true)
        let resources = root.appendingPathComponent("inputs/baseline-resources", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: cad)
        try ProjectTestSupport.makeAssetResourceDirectory(at: resources)
        let editorState = try ProjectTestSupport.makeEditorState(
            projectID: fixture.projectID,
            roomID: fixture.roomID
        )
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
            editorState: editorState
        ))
        try store.close()
        return RecoveryBaseline(
            spaceURL: root,
            projectURL: repository.rootURL,
            repository: repository,
            workingCopy: workingCopy,
            fixture: fixture,
            result: result,
            resources: resources
        )
    }

    private func makeCandidate(
        baseline: RecoveryBaseline,
        name: String,
        fault: BuildingProjectFaultPoint?
    ) throws -> RecoveryCandidate {
        let configuration = BuildingProjectConfiguration(
            faultHooks: fault.map { point in
                BuildingProjectFaultHooks { received in
                    if received == point {
                        throw TestFault.stop
                    }
                }
            }
        )
        let repository = try BuildingProjectRepository.open(
            at: baseline.projectURL,
            configuration: configuration
        )
        let workingCopy = try repository.createWorkingCopy(
            from: baseline.result.generation.generationID
        )
        let store = try ProjectRecordsStore.openProject(at: workingCopy.recordsDirectoryURL)
        let newRoom = try store.createRoom(
            RoomDraft(name: "Candidate room", kind: .dining),
            expectedRevision: try store.currentRevision()
        )
        let snapshot = try ProjectTestSupport.captureSnapshot(
            from: store,
            to: baseline.spaceURL.appendingPathComponent("snapshots/\(name)", isDirectory: true)
        )
        let editorState = try ProjectTestSupport.makeEditorState(
            projectID: store.projectID,
            roomID: newRoom.value.id
        )
        try store.close()
        let cad = baseline.spaceURL.appendingPathComponent("inputs/\(name)-cad", isDirectory: true)
        try ProjectTestSupport.makeCADDirectory(at: cad)
        let cadModel = Data("{\"format\":\"floecad\",\"revision\":8,\"candidate\":\"\(name)\"}".utf8)
        try cadModel.write(to: cad.appendingPathComponent("model.json"))
        try Data("candidate-marker".utf8).write(to: cad.appendingPathComponent("candidate.txt"))
        let commit = BuildingCommitID()
        _ = try repository.beginWorkingCopySave(
            workingCopy,
            expectedBaseGenerationID: baseline.result.generation.generationID,
            commitID: commit
        )
        let request = BuildingProjectCommitRequest(
            commitID: commit,
            expectedGeneration: .generation(baseline.result.generation.generationID),
            identity: try ProjectTestSupport.makeIdentity(snapshot: snapshot),
            recordsSnapshot: snapshot,
            cadDirectoryURL: cad,
            assetResourcesDirectoryURL: baseline.resources,
            editorState: editorState
        )
        return RecoveryCandidate(
            repository: repository,
            workingCopy: workingCopy,
            snapshot: snapshot,
            request: request,
            commit: commit,
            inputs: RecoveryInputs(cad: cad),
            cadModelBytes: cadModel
        )
    }
}

private enum TestFault: Error {
    case stop
}

private struct RecoveryBaseline {
    let spaceURL: URL
    let projectURL: URL
    let repository: BuildingProjectRepository
    let workingCopy: BuildingProjectWorkingCopy
    let fixture: ProjectFixture
    let result: BuildingProjectCommitResult
    let resources: URL
}

private struct RecoveryInputs {
    let cad: URL
}

private struct RecoveryCandidate {
    let repository: BuildingProjectRepository
    let workingCopy: BuildingProjectWorkingCopy
    let snapshot: ProjectRecordsSnapshot
    let request: BuildingProjectCommitRequest
    let commit: BuildingCommitID
    let inputs: RecoveryInputs
    let cadModelBytes: Data
}
