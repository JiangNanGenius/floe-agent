import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore

final class G09CanvasProjectRepositoryTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func makeRoot() throws -> (URL, RuntimeStorageRoot) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-canvas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        return (url, root)
    }

    private func patch(_ project: CanvasProject, opID: String = "op-1",
                       expected: Int64? = nil) -> G09CanvasPatchRequest {
        let nodeID = UUID()
        let operation = CanvasPatchOperation(
            kind: .create, nodeID: nodeID, nodeKind: .text, text: "Hello",
            position: CanvasPoint(x: 120, y: 80), size: CanvasSize(width: 240, height: 80))
        return G09CanvasPatchRequest(
            canvasID: project.id,
            expectedRevision: expected ?? project.revision,
            sessionToken: "session-1",
            opID: opID,
            patch: CanvasPatch(
                canvasID: project.id, documentID: project.selectedDocumentID,
                expectedRevision: expected ?? project.revision,
                operations: [operation]))
    }

    func testCreatePatchUuidDictionaryWireAndIdempotentReceipt() async throws {
        let (directory, root) = try makeRoot()
        let repository = G09CanvasProjectRepository(root: root)
        let created = try await repository.create(name: "Board")
        XCTAssertEqual(created.project.schemaVersion, CanvasProject.currentSchemaVersion)
        XCTAssertEqual(created.project.revision, 1)
        XCTAssertEqual(created.project.documents.count, 1)

        let receipt = try await repository.patch(patch(created.project))
        XCTAssertEqual(receipt.previousRevision, 1)
        XCTAssertEqual(receipt.revision, 2)
        XCTAssertEqual(receipt.changedNodeIDs.count, 1)

        let firstBytes = try Data(contentsOf: repository.projectURL(id: created.project.id))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstBytes) as? [String: Any])
        // Swift JSONEncoder emits UUID-keyed dictionaries as alternating
        // unkeyed arrays. Kotlin MUST decode that exact shape.
        XCTAssertTrue(object["viewports"] is [Any])
        XCTAssertTrue(object["agentConversationIDsByDocument"] is [Any])

        let retry = try await repository.patch(patch(created.project))
        XCTAssertTrue(retry.idempotent)
        XCTAssertEqual(retry.revision, 2)
        let retryBytes = try Data(contentsOf: repository.projectURL(id: created.project.id))
        XCTAssertEqual(firstBytes, retryBytes)
    }

    func testStaleRevisionAndCorruptFutureFilesAreNeverOverwritten() async throws {
        let (_, root) = try makeRoot()
        let repository = G09CanvasProjectRepository(root: root)
        let created = try await repository.create(name: "Board")
        do {
            _ = try await repository.patch(patch(created.project, expected: 99))
            XCTFail("stale revision must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "revisionConflict")
        }

        let corruptURL = repository.projectURL(id: UUID())
        let corruptBytes = Data("{not-json".utf8)
        try corruptBytes.write(to: corruptURL)
        do {
            _ = try await repository.load(id: UUID(uuidString: corruptURL.deletingPathExtension().lastPathComponent)!)
            XCTFail("corrupt project must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "corruptProject")
        }
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)

        let futureURL = repository.projectURL(id: UUID())
        var future = created.project
        future.id = UUID(uuidString: futureURL.deletingPathExtension().lastPathComponent)!
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try G09CreativeWire.encoder().encode(future)) as? [String: Any])
        object["schemaVersion"] = 99
        let futureBytes = try JSONSerialization.data(withJSONObject: object)
        try futureBytes.write(to: futureURL)
        do {
            _ = try await repository.load(id: future.id)
            XCTFail("future schema must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "unsupportedSchema")
        }
        XCTAssertEqual(try Data(contentsOf: futureURL), futureBytes)
    }


    func testCADBoundNodeStaysReadOnlyForR1Patches() async throws {
        let (_, root) = try makeRoot()
        let repository = G09CanvasProjectRepository(root: root)
        let created = try await repository.create(name: "Board")
        let nodeID = UUID()
        let asset = CanvasAssetReference(
            id: UUID(), contentHash: String(repeating: "a", count: 64),
            localRelativePath: "drawing.floecad", mimeType: "application/floecad",
            byteCount: 10)
        let create = G09CanvasPatchRequest(
            canvasID: created.project.id,
            expectedRevision: created.project.revision,
            sessionToken: "session-1",
            opID: "cad-create",
            patch: CanvasPatch(
                canvasID: created.project.id,
                documentID: created.project.selectedDocumentID,
                expectedRevision: created.project.revision,
                operations: [CanvasPatchOperation(
                    kind: .create, nodeID: nodeID, nodeKind: .file,
                    position: CanvasPoint(x: 0, y: 0),
                    size: CanvasSize(width: 100, height: 100),
                    asset: asset,
                    metadata: [CADCanvasNodePlanner.MetadataKeys.sourcePath: "drawing.floecad"])]))
        let afterCreate = try await repository.patch(create)
        let before = try Data(contentsOf: repository.projectURL(id: created.project.id))
        let mutate = G09CanvasPatchRequest(
            canvasID: created.project.id,
            expectedRevision: afterCreate.revision,
            sessionToken: "session-1",
            opID: "cad-mutate",
            patch: CanvasPatch(
                canvasID: created.project.id,
                documentID: created.project.selectedDocumentID,
                expectedRevision: afterCreate.revision,
                operations: [CanvasPatchOperation(
                    kind: .update, nodeID: nodeID, text: "Edited")]))
        do {
            _ = try await repository.patch(mutate)
            XCTFail("CAD-bound nodes are read-only in R1")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "invalidPayload")
        }
        XCTAssertEqual(try Data(contentsOf: repository.projectURL(id: created.project.id)), before)
    }


    func testFaultAfterCanvasCommitRecoversWithoutDuplicatePatch() async throws {
        let (_, root) = try makeRoot()
        let repository = G09CanvasProjectRepository(root: root)
        let created = try await repository.create(name: "Board")
        let request = patch(created.project, opID: "canvas-fault")
        struct Crash: Error {}
        await repository.setFaultAfterCommit { throw Crash() }
        do {
            _ = try await repository.patch(request)
            XCTFail("injected crash must surface")
        } catch {
            // Expected: file committed, intent not marked.
        }
        await repository.setFaultAfterCommit(nil)
        let recovered = try await repository.patch(request)
        XCTAssertTrue(recovered.idempotent)
        XCTAssertEqual(recovered.revision, 2)
        let loaded = try await repository.load(id: created.project.id)
        XCTAssertEqual(loaded.project.revision, 2)
        XCTAssertEqual(loaded.project.documents.first?.nodes.count, 1)
    }

    func testDeleteMovesFileIntoRecovery() async throws {
        let (_, root) = try makeRoot()
        let repository = G09CanvasProjectRepository(root: root)
        let created = try await repository.create(name: "Board")
        try await repository.delete(id: created.project.id,
                                    expectedRevision: created.project.revision)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repository.projectURL(id: created.project.id).path))
        let deleted = URL(fileURLWithPath: repository.recoveryDirectoryPath,
                          isDirectory: true).appendingPathComponent("Deleted")
        let entries = try FileManager.default.contentsOfDirectory(atPath: deleted.path)
        XCTAssertEqual(entries.count, 1)
    }
}
