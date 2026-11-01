// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 design workflow tests (authored source; run by Main's combined gate).
//
// They exercise the REAL service against temporary explicit roots: owner file
// envelope CAS, immutable payload staging, shared propose/adopt replay, Canvas
// design CAS on the existing repository, real format verification, verified
// preview/export receipts and the Root-stop fence. No device/provider/Git work.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeAndroidWorkbench

final class G09R2DesignWorkflowTests: XCTestCase {
    private var roots: [URL] = []
    private var database: DatabaseManager?
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 9_000

    override func tearDown() async throws {
        if let database { try? await database.close() }
        database = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    private static func nextEpoch() -> UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }
        epochCounter += 1
        return epochCounter
    }

    private struct Fixture {
        let service: G09CreativeDomainService
        let design: G09R2DesignService
        let root: RuntimeStorageRoot
        let rootURL: URL
        let workspaceStore: SQLiteWorkspaceStore
        let conversationStore: SQLiteConversationStore
        let epoch: UInt64
    }

    private func makeFixture() async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-design-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        database = manager
        let workspaceStore = SQLiteWorkspaceStore(database: manager)
        let conversationStore = SQLiteConversationStore(database: manager)
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        let service = G09CreativeDomainService()
        let epoch = Self.nextEpoch()
        _ = try await service.bind(
            epoch: epoch,
            storage: G09CreativeStorageContext(
                root: root, database: manager,
                workspaceStore: workspaceStore,
                conversationStore: conversationStore))
        let designOptional = await service.r2DesignService()
        let design = try XCTUnwrap(designOptional)
        return Fixture(
            service: service, design: design, root: root, rootURL: url,
            workspaceStore: workspaceStore,
            conversationStore: conversationStore, epoch: epoch)
    }

    private func stage(
        _ fixture: Fixture,
        sessionToken: String,
        data: Data,
        format: String = "md"
    ) throws -> G09R2StagedDesignPayloadDTO {
        let directory = fixture.root.artifactStoreURL
            .appendingPathComponent("CreativeIncoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let token = "\(sessionToken).\(UUID().uuidString.lowercased())"
        try data.write(to: directory.appendingPathComponent(token))
        return G09R2StagedDesignPayloadDTO(
            token: token,
            format: format,
            byteCount: Int64(data.count),
            sha256: FloeDigest.sha256Hex(data))
    }

    private func makeWorkspaceFile(
        _ fixture: Fixture,
        content: String = "Original design"
    ) async throws -> (target: DesignTarget, binding: G09R2DesignBindingDTO, fileURL: URL) {
        let workspaceID = UUID()
        let conversationID = UUID()
        let relative = "PrivateTasks/\(conversationID.uuidString)"
        try await fixture.workspaceStore.saveWorkspace(WorkspaceRecord(
            id: workspaceID,
            name: "Design workspace",
            rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath: relative))
        let directory = fixture.rootURL
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("design.md")
        try Data(content.utf8).write(to: fileURL)
        let target = DesignTarget(
            kind: .fileDocument,
            ownerID: workspaceID.uuidString.lowercased(),
            sourceID: "design.md")
        let binding = G09R2DesignBindingDTO(
            target: target,
            storage: G09StorageLayerDTO(
                kind: .workspace, workspaceID: workspaceID),
            sessionToken: "design-session-file")
        return (target, binding, fileURL)
    }

    private func makeCanvasTextNode(
        _ fixture: Fixture
    ) async throws -> (
        target: DesignTarget,
        binding: G09R2DesignBindingDTO,
        repository: G09CanvasProjectRepository,
        canvasID: UUID,
        nodeID: UUID
    ) {
        let repositoryOptional = await fixture.service.r2CanvasRepository()
        let repository = try XCTUnwrap(repositoryOptional)
        let created = try await repository.create(name: "Design Canvas")
        let nodeID = UUID()
        let documentID = try XCTUnwrap(created.project.documents.first?.id)
        let patch = CanvasPatch(
            canvasID: created.project.id,
            documentID: documentID,
            expectedRevision: created.project.revision,
            operations: [CanvasPatchOperation(
                kind: .create,
                nodeID: nodeID,
                nodeKind: .text,
                text: "Original canvas text",
                position: CanvasPoint(x: 20, y: 30),
                size: CanvasSize(width: 320, height: 120))])
        let request = G09CanvasPatchRequest(
            canvasID: created.project.id,
            expectedRevision: created.project.revision,
            sessionToken: "canvas-setup",
            opID: "canvas-setup-node-1",
            patch: patch)
        _ = try await repository.patch(request)
        let target = DesignTarget(
            kind: .canvasNode,
            ownerID: created.project.id.uuidString.lowercased(),
            sourceID: nodeID.uuidString.lowercased())
        let binding = G09R2DesignBindingDTO(
            target: target,
            storage: G09StorageLayerDTO(kind: .appOwned),
            sessionToken: "design-session-canvas")
        return (target, binding, repository, created.project.id, nodeID)
    }

    // MARK: - Owner file lifecycle

    func testOwnerFileBriefFreezeProposeAdoptReplayAndVerifiedReceipts() async throws {
        let fixture = try await makeFixture()
        let setup = try await makeWorkspaceFile(fixture)
        let design = fixture.design

        let bound = try await design.bind(G09R2DesignBindRequest(
            binding: setup.binding,
            expectedRevision: 0,
            opID: "bind-file-1"))
        XCTAssertEqual(bound.envelope.revision, 0)
        XCTAssertEqual(bound.envelope.project.contentType, .notes)

        let briefed = try await design.setBrief(G09R2DesignBriefRequest(
            binding: setup.binding,
            expectedRevision: 0,
            opID: "brief-file-1",
            brief: DesignBrief(goal: "Clarify the design", audience: "Users")))
        XCTAssertEqual(briefed.envelope.revision, 1)
        XCTAssertEqual(briefed.envelope.project.brief?.goal, "Clarify the design")

        let frozen = try await design.freeze(G09R2DesignFreezeRequest(
            binding: setup.binding,
            expectedRevision: 1,
            opID: "freeze-file-1",
            inputRevisionID: nil,
            specSHA256: nil,
            targetRevisionID: nil,
            desiredFormat: "md",
            workMode: .modify,
            preservationDigest: nil))
        XCTAssertFalse(frozen.idempotent)
        XCTAssertEqual(frozen.frozenRun.desiredFormat, "md")
        XCTAssertEqual(frozen.frozenRun.workMode, .modify)

        let afterFreeze = try await design.state(setup.binding)
        XCTAssertGreaterThanOrEqual(afterFreeze.envelope.revision, 2)
        let artifact = try XCTUnwrap(afterFreeze.envelope.project.artifacts.first)
        let base = try XCTUnwrap(artifact.revision(artifact.currentRevisionID ?? ""))
        let changed = Data("Changed design\nSecond line\n".utf8)
        let staged = try stage(fixture, sessionToken: setup.binding.sessionToken, data: changed)

        let proposed = try await design.propose(G09R2DesignProposeRequest(
            binding: setup.binding,
            expectedRevision: afterFreeze.envelope.revision,
            opID: "propose-file-1",
            artifactID: artifact.id,
            baseRevisionID: base.id,
            payload: staged,
            summary: "Rewrite the copy",
            diff: ["Clarify heading"],
            feedbackIDs: [],
            workIntent: nil))
        XCTAssertFalse(proposed.replayed)
        XCTAssertEqual(proposed.candidate.baseRevisionID, base.id)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.artifactStoreURL
                .appendingPathComponent("CreativeIncoming")
                .appendingPathComponent(staged.token).path),
            "successful native proposal owns and consumes the staged token")

        let comparison = try await design.compare(G09R2DesignCompareRequest(
            binding: setup.binding,
            candidateID: proposed.candidate.id))
        XCTAssertTrue(comparison.changed)
        XCTAssertTrue(comparison.diff.contains { $0.contains("Changed design") })

        let afterPropose = try await design.state(setup.binding)
        let adopted = try await design.adopt(G09R2DesignAdoptRequest(
            binding: setup.binding,
            expectedRevision: afterPropose.envelope.revision,
            opID: "adopt-file-1",
            candidateID: proposed.candidate.id,
            mode: .updateOriginal))
        XCTAssertFalse(adopted.idempotent)
        XCTAssertEqual(adopted.publication.state, .notRequired)
        let written = try String(contentsOf: setup.fileURL, encoding: .utf8)
        XCTAssertEqual(written, String(decoding: changed, as: UTF8.self))
        XCTAssertNotNil(adopted.committedRevisionToken)

        // Exact replay of the applied adoption is idempotent and never rewrites.
        let replay = try await design.adopt(G09R2DesignAdoptRequest(
            binding: setup.binding,
            expectedRevision: afterPropose.envelope.revision,
            opID: "adopt-file-1",
            candidateID: proposed.candidate.id,
            mode: .updateOriginal))
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(try String(contentsOf: setup.fileURL, encoding: .utf8), written)

        // Verified original-format preview/export receipts.
        let preview = try await design.preview(G09R2DesignPreviewRequest(
            binding: setup.binding,
            candidateID: nil,
            revisionID: nil,
            maxBytes: G09R2CreativeLimits.designPreviewBytes))
        let previewURL = URL(fileURLWithPath: preview.rootPath, isDirectory: true)
            .appendingPathComponent(preview.relativePath)
        let previewBytes = try Data(contentsOf: previewURL)
        XCTAssertEqual(Int64(previewBytes.count), preview.byteCount)
        XCTAssertEqual(FloeDigest.sha256Hex(previewBytes), preview.sha256)
        XCTAssertEqual(preview.format, "md")

        let exported = try await design.export(G09R2DesignExportRequest(
            binding: setup.binding,
            candidateID: nil,
            revisionID: nil,
            format: "md",
            suggestedFileName: "result.md"))
        let exportedURL = URL(fileURLWithPath: exported.rootPath, isDirectory: true)
            .appendingPathComponent(exported.relativePath)
        XCTAssertEqual(
            FloeDigest.sha256Hex(try Data(contentsOf: exportedURL)),
            exported.sha256)

        // A format conversion that was never performed is refused, not faked.
        do {
            _ = try await design.export(G09R2DesignExportRequest(
                binding: setup.binding,
                candidateID: proposed.candidate.id,
                revisionID: nil,
                format: "png",
                suggestedFileName: nil))
            XCTFail("markdown cannot be exported as png")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "renderUnsupported")
        }

        // Staged size/hash mismatch and unsupported source formats fail before
        // any candidate/CAS is created.
        let mismatch = try stage(
            fixture, sessionToken: setup.binding.sessionToken,
            data: Data("Another change".utf8))
        let current = try await design.state(setup.binding)
        var wrongSize = mismatch
        wrongSize.byteCount += 1
        do {
            _ = try await design.propose(G09R2DesignProposeRequest(
                binding: setup.binding,
                expectedRevision: current.envelope.revision,
                opID: "propose-file-size-mismatch",
                artifactID: artifact.id,
                baseRevisionID: base.id,
                payload: wrongSize,
                summary: "mismatch",
                diff: [],
                feedbackIDs: [],
                workIntent: nil))
            XCTFail("declared size mismatch must be refused")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designPayloadMissing")
        }
        do {
            _ = try await design.propose(G09R2DesignProposeRequest(
                binding: setup.binding,
                expectedRevision: current.envelope.revision,
                opID: "propose-file-unsupported",
                artifactID: artifact.id,
                baseRevisionID: base.id,
                payload: G09R2StagedDesignPayloadDTO(
                    token: mismatch.token, format: "exe",
                    byteCount: mismatch.byteCount, sha256: mismatch.sha256),
                summary: "unsupported",
                diff: [],
                feedbackIDs: [],
                workIntent: nil))
            XCTFail("executable bytes are not a design source")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "renderUnsupported")
        }
        let unchanged = try await design.state(setup.binding)
        XCTAssertEqual(unchanged.envelope.revision, current.envelope.revision)
        XCTAssertEqual(try String(contentsOf: setup.fileURL, encoding: .utf8), written)
    }

    func testOwnerAdoptFailurePreservesEditedOriginal() async throws {
        let fixture = try await makeFixture()
        let setup = try await makeWorkspaceFile(fixture)
        let design = fixture.design
        _ = try await design.bind(G09R2DesignBindRequest(
            binding: setup.binding, expectedRevision: 0, opID: "bind-fail-1"))
        _ = try await design.setBrief(G09R2DesignBriefRequest(
            binding: setup.binding, expectedRevision: 0,
            opID: "brief-fail-1", brief: DesignBrief(goal: "Change")))
        _ = try await design.freeze(G09R2DesignFreezeRequest(
            binding: setup.binding, expectedRevision: 1,
            opID: "freeze-fail-1", inputRevisionID: nil,
            specSHA256: nil, targetRevisionID: nil,
            desiredFormat: "md", workMode: .modify,
            preservationDigest: nil))
        let state = try await design.state(setup.binding)
        let artifact = try XCTUnwrap(state.envelope.project.artifacts.first)
        let base = try XCTUnwrap(
            artifact.revision(artifact.currentRevisionID ?? ""))
        let staged = try stage(
            fixture, sessionToken: setup.binding.sessionToken,
            data: Data("Adopted candidate".utf8))
        let proposed = try await design.propose(G09R2DesignProposeRequest(
            binding: setup.binding,
            expectedRevision: state.envelope.revision,
            opID: "propose-fail-1",
            artifactID: artifact.id,
            baseRevisionID: base.id,
            payload: staged,
            summary: "candidate",
            diff: [],
            feedbackIDs: [],
            workIntent: nil))

        // A concurrent user edit moves the frozen base. Adoption must not
        // overwrite it and must not report success.
        let edited = "User edited this file while the candidate was pending"
        try Data(edited.utf8).write(to: setup.fileURL)
        let pending = try await design.state(setup.binding)
        do {
            _ = try await design.adopt(G09R2DesignAdoptRequest(
                binding: setup.binding,
                expectedRevision: pending.envelope.revision,
                opID: "adopt-fail-1",
                candidateID: proposed.candidate.id,
                mode: .updateOriginal))
            XCTFail("a moved workspace base must not be overwritten")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designConflict")
        }
        XCTAssertEqual(
            try String(contentsOf: setup.fileURL, encoding: .utf8), edited)
    }

    // MARK: - Canvas lifecycle

    func testCanvasFreezeProposeAdoptSnapshotAndRootFence() async throws {
        let fixture = try await makeFixture()
        let setup = try await makeCanvasTextNode(fixture)
        let design = fixture.design
        let binding = setup.binding
        let bound = try await design.bind(G09R2DesignBindRequest(
            binding: binding,
            expectedRevision: 2,
            opID: "canvas-bind-1"))
        XCTAssertEqual(bound.envelope.revision, 2)
        XCTAssertEqual(bound.envelope.project.contentType, .notes)

        let frozen = try await design.freeze(G09R2DesignFreezeRequest(
            binding: binding,
            expectedRevision: 2,
            opID: "canvas-freeze-1",
            inputRevisionID: "canvas-freeze-revision-1",
            specSHA256: nil,
            targetRevisionID: nil,
            desiredFormat: "md",
            workMode: .modify,
            preservationDigest: nil))
        XCTAssertFalse(frozen.idempotent)
        XCTAssertEqual(frozen.frozenRun.inputRevisionID, "canvas-freeze-revision-1")
        XCTAssertEqual(frozen.frozenRun.desiredFormat, "md")

        let afterFreeze = try await design.state(binding)
        XCTAssertEqual(afterFreeze.envelope.revision, 3)
        let artifact = try XCTUnwrap(afterFreeze.envelope.project.artifacts.first)
        let base = try XCTUnwrap(
            artifact.revision(artifact.currentRevisionID ?? ""))
        let changed = Data("Changed canvas text\n".utf8)
        let staged = try stage(
            fixture, sessionToken: binding.sessionToken, data: changed)
        let proposed = try await design.propose(G09R2DesignProposeRequest(
            binding: binding,
            expectedRevision: afterFreeze.envelope.revision,
            opID: "canvas-propose-1",
            artifactID: artifact.id,
            baseRevisionID: base.id,
            payload: staged,
            summary: "Canvas rewrite",
            diff: ["New copy"],
            feedbackIDs: [],
            workIntent: nil))
        XCTAssertFalse(proposed.replayed)
        let comparison = try await design.compare(G09R2DesignCompareRequest(
            binding: binding, candidateID: proposed.candidate.id))
        XCTAssertTrue(comparison.changed)
        XCTAssertTrue(comparison.diff.contains { $0.contains("Changed canvas text") })

        let beforeAdopt = try await design.state(binding)
        let adopted = try await design.adopt(G09R2DesignAdoptRequest(
            binding: binding,
            expectedRevision: beforeAdopt.envelope.revision,
            opID: "canvas-adopt-1",
            candidateID: proposed.candidate.id,
            mode: .updateOriginal))
        XCTAssertFalse(adopted.idempotent)
        XCTAssertEqual(adopted.committedRevisionToken, "canvas:5")
        XCTAssertEqual(adopted.publication.state, .notRequired)

        let committed = try await setup.repository.load(id: setup.canvasID)
        XCTAssertEqual(committed.project.revision, 5)
        let node = try XCTUnwrap(
            committed.project.documents.flatMap(\.nodes)
                .first(where: { $0.id == setup.nodeID }))
        XCTAssertEqual(node.text, String(decoding: changed, as: UTF8.self))
        let rawDesign = try XCTUnwrap(
            node.metadata[DesignCanvasMetadata.key])
        let decodedDesign = try DesignCanvasMetadata.decode(
            rawDesign, nodeID: setup.nodeID.uuidString.lowercased())
        let canvasDesign = try XCTUnwrap(decodedDesign)
        XCTAssertTrue(canvasDesign.hasApplied(operationID: "canvas-adopt-1"))
        XCTAssertEqual(
            canvasDesign.candidate(proposed.candidate.id)?.status,
            DesignCandidateStatus.adopted)

        // Canvas snapshot preview/export is a real JSON document with the
        // actual Canvas identity, never a PNG label over JSON.
        let preview = try await design.preview(G09R2DesignPreviewRequest(
            binding: binding,
            candidateID: nil,
            revisionID: nil,
            maxBytes: G09R2CreativeLimits.designPreviewBytes))
        XCTAssertEqual(preview.format, "canvas.snapshot")
        let previewURL = URL(fileURLWithPath: preview.rootPath, isDirectory: true)
            .appendingPathComponent(preview.relativePath)
        let previewBytes = try Data(contentsOf: previewURL)
        XCTAssertEqual(FloeDigest.sha256Hex(previewBytes), preview.sha256)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: previewBytes) as? [String: Any])
        XCTAssertEqual(
            (object["canvasID"] as? String)?.lowercased(),
            setup.canvasID.uuidString.lowercased())
        let snapshotRevision = (object["canvasRevision"] as? NSNumber)?.int64Value
            ?? (object["canvasRevision"] as? Int64)
            ?? (object["canvasRevision"] as? Int).map(Int64.init)
        XCTAssertEqual(snapshotRevision, Int64(5))

        do {
            _ = try await design.preview(G09R2DesignPreviewRequest(
                binding: binding,
                candidateID: nil,
                revisionID: nil,
                maxBytes: 1))
            XCTFail("an oversized snapshot must be refused, not truncated")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designPreviewTooLarge")
        }

        let snapshotExport = try await design.export(G09R2DesignExportRequest(
            binding: binding,
            candidateID: nil,
            revisionID: nil,
            format: "canvas.snapshot",
            suggestedFileName: "canvas-snapshot.json"))
        XCTAssertEqual(snapshotExport.format, "canvas.snapshot")
        let exportURL = URL(
            fileURLWithPath: snapshotExport.rootPath, isDirectory: true)
            .appendingPathComponent(snapshotExport.relativePath)
        XCTAssertEqual(
            FloeDigest.sha256Hex(try Data(contentsOf: exportURL)),
            snapshotExport.sha256)
        do {
            _ = try await design.export(G09R2DesignExportRequest(
                binding: binding,
                candidateID: nil,
                revisionID: nil,
                format: "png",
                suggestedFileName: nil))
            XCTFail("a JSON canvas snapshot is not a png")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "renderUnsupported")
        }

        // Root stop fences new work; the aggregate close releases only after
        // the design service reports no in-flight operation.
        let drained = await design.requestRootStop(epoch: fixture.epoch)
        XCTAssertTrue(drained)
        do {
            _ = try await design.state(binding)
            XCTFail("stopped design service must fence new reads")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "staleGeneration")
        }
        let closed = await fixture.service.close(epoch: fixture.epoch)
        XCTAssertTrue(closed)
    }
}
