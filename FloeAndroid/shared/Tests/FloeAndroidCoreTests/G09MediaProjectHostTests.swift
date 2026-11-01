import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeAndroidWorkbench

final class G09MediaProjectHostTests: XCTestCase {
    private var roots: [URL] = []
    private var database: DatabaseManager?

    override func tearDown() async throws {
        if let database { try? await database.close() }
        database = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    private func makeHost() async throws -> (RuntimeStorageRoot, G09MediaProjectHost,
                                              SQLiteWorkspaceStore) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        database = manager
        let workspaceStore = SQLiteWorkspaceStore(database: manager)
        let conversationStore = SQLiteConversationStore(database: manager)
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        return (root, G09MediaProjectHost(
                    root: root, workspaceStore: workspaceStore,
                    conversationStore: conversationStore),
                workspaceStore)
    }

    private func makeWorkspace(_ store: SQLiteWorkspaceStore,
                               relative: String? = nil) async throws -> UUID {
        let id = UUID()
        let record = WorkspaceRecord(
            id: id, name: "Workspace", rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath: relative ?? "PrivateTasks/\(UUID().uuidString)")
        try await store.saveWorkspace(record)
        return id
    }

    func testAppOwnedCreateApplyUndoRedoReopen() async throws {
        let (_, host, _) = try await makeHost()
        let created = try await host.create(
            name: "Poster", kind: .image, width: 1080, height: 1350,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        XCTAssertEqual(created.project.revision, 0)
        XCTAssertTrue(created.writable)

        var layer = ImageLayer(kind: .text, name: "Title")
        layer.text = ImageTextContent(text: "Hello")
        let apply = G09MediaApplyRequest(
            projectID: created.project.id, expectedRevision: 0,
            sessionToken: "session-1", storage: G09StorageLayerDTO(kind: .appOwned),
            opID: "apply-1", commands: [.addImageLayer(layer)])
        let applied = try await host.apply(apply)
        XCTAssertEqual(applied.project.revision, 1)
        XCTAssertEqual(applied.project.imageLayers.count, 1)

        let retry = try await host.apply(apply)
        XCTAssertEqual(retry.project.revision, 1)
        XCTAssertEqual(retry.project.imageLayers.count, 1)

        let undo = try await host.undo(G09MediaUndoRedoRequest(
            projectID: created.project.id, expectedRevision: 1,
            sessionToken: "session-1", storage: G09StorageLayerDTO(kind: .appOwned),
            opID: "undo-1"))
        XCTAssertEqual(undo.project.revision, 2)
        XCTAssertTrue(undo.project.imageLayers.isEmpty)

        let redo = try await host.redo(G09MediaUndoRedoRequest(
            projectID: created.project.id, expectedRevision: 2,
            sessionToken: "session-1", storage: G09StorageLayerDTO(kind: .appOwned),
            opID: "redo-1"))
        XCTAssertEqual(redo.project.revision, 3)
        XCTAssertEqual(redo.project.imageLayers.count, 1)

        let reopened = try await host.load(
            id: created.project.id, requested: G09StorageLayerDTO(kind: .appOwned))
        XCTAssertEqual(reopened.project.revision, 3)
        XCTAssertEqual(reopened.project.imageLayers.count, 1)
    }

    func testForgedRecordedRootIsIgnoredAndPreservedReadOnly() async throws {
        let (root, host, _) = try await makeHost()
        let created = try await host.create(
            name: "Poster", kind: .image, width: 640, height: 480,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let projectURL = URL(fileURLWithPath: host.projectDirectoryPath,
                             isDirectory: true)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: created.project.id))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: projectURL)) as? [String: Any])
        object["taskWorkspacePath"] = "/tmp/forged-outside-root"
        let forgedBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try forgedBytes.write(to: projectURL)

        let loaded = try await host.load(
            id: created.project.id, requested: G09StorageLayerDTO(kind: .appOwned))
        XCTAssertFalse(loaded.writable)
        XCTAssertTrue(loaded.warnings.contains("storageProvenanceMismatch"))
        XCTAssertEqual(try Data(contentsOf: projectURL), forgedBytes)

        do {
            _ = try await host.rename(G09MediaRenameRequest(
                projectID: created.project.id, expectedRevision: created.project.revision,
                name: "Hijacked", sessionToken: "session-1",
                storage: G09StorageLayerDTO(kind: .appOwned), opID: "rename-1"))
            XCTFail("a provenance-mismatched project must not be written")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "provenanceMismatch")
        }
        XCTAssertEqual(try Data(contentsOf: projectURL), forgedBytes)
        _ = root
    }

    func testCrossOwnerAndWorkspacePathEscapeAreRefused() async throws {
        let (_, host, workspaceStore) = try await makeHost()
        let first = try await makeWorkspace(workspaceStore)
        let second = try await makeWorkspace(workspaceStore)
        let created = try await host.create(
            name: "Workspace Poster", kind: .image, width: 800, height: 600,
            frameRate: nil,
            storage: G09StorageLayerDTO(kind: .workspace, workspaceID: first),
            origin: G09CreativeOriginDTO(kind: .workspace, ownerID: first))
        do {
            _ = try await host.load(
                id: created.project.id,
                requested: G09StorageLayerDTO(kind: .workspace, workspaceID: second),
                origin: G09CreativeOriginDTO(
                    kind: .workspace, ownerID: second))
            XCTFail("cross-owner origin must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "crossOwnerRefused")
        }
        // Decoupled: a real workspace-owned project may use an explicit
        // app-owned working copy, but only with the SAME origin context.
        let workingCopy = try await host.load(
            id: created.project.id,
            requested: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .workspace, ownerID: first))
        // Storage is decoupled from origin, but switching the recorded
        // storage root is a provenance change and is therefore read-only
        // until an explicit repair; the original file is untouched.
        XCTAssertFalse(workingCopy.writable)
        XCTAssertTrue(workingCopy.warnings.contains("storageProvenanceMismatch"))
        do {
            _ = try await host.load(
                id: created.project.id,
                requested: G09StorageLayerDTO(kind: .appOwned),
                origin: G09CreativeOriginDTO(kind: .standalone))
            XCTFail("a workspace origin must not open as standalone")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "crossOwnerRefused")
        }

        let escaped = try await makeWorkspace(
            workspaceStore, relative: "PrivateTasks/../../outside")
        do {
            _ = try await host.create(
                name: "Escape", kind: .image, width: 100, height: 100,
                frameRate: nil,
                storage: G09StorageLayerDTO(kind: .workspace, workspaceID: escaped),
                origin: G09CreativeOriginDTO(
                    kind: .workspace, ownerID: escaped))
            XCTFail("an escaped workspace path must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "workspaceStorageUnavailable")
        }
    }


    func testWorkspaceOriginWithExplicitAppOwnedWorkingCopyPersistsActualOwner() async throws {
        let (_, host, workspaceStore) = try await makeHost()
        let workspace = try await makeWorkspace(workspaceStore)
        let origin = G09CreativeOriginDTO(
            kind: .workspace, ownerID: workspace, environmentID: "env-42")
        let created = try await host.create(
            name: "Working Copy", kind: .image, width: 640, height: 480,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: origin)
        XCTAssertEqual(created.project.ownerKind, "workspace")
        XCTAssertEqual(created.project.ownerID, workspace)
        XCTAssertEqual(created.project.environmentID, "env-42")

        let reopened = try await host.load(
            id: created.project.id,
            requested: G09StorageLayerDTO(kind: .appOwned),
            origin: origin)
        XCTAssertTrue(reopened.writable)
        XCTAssertEqual(reopened.project.ownerKind, "workspace")
        XCTAssertEqual(reopened.project.ownerID, workspace)
        XCTAssertEqual(reopened.project.environmentID, "env-42")

        do {
            _ = try await host.load(
                id: created.project.id,
                requested: G09StorageLayerDTO(kind: .appOwned),
                origin: G09CreativeOriginDTO(kind: .workspace, ownerID: workspace,
                                             environmentID: "other-env"))
            XCTFail("environment drift is a cross-owner refusal")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "crossOwnerRefused")
        }
    }

    func testFilesOriginIsPersistedWithoutInventingATask() async throws {
        let (_, host, _) = try await makeHost()
        let origin = G09CreativeOriginDTO(
            kind: .files, ownerID: nil, environmentID: "env-files")
        let created = try await host.create(
            name: "Imported Image", kind: .image, width: 300, height: 200,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: origin)
        XCTAssertEqual(created.project.ownerKind, "files")
        XCTAssertEqual(created.project.environmentID, "env-files")
        XCTAssertNil(created.project.ownerID)
        let reopened = try await host.load(
            id: created.project.id,
            requested: G09StorageLayerDTO(kind: .appOwned), origin: origin)
        XCTAssertTrue(reopened.writable)
        XCTAssertEqual(reopened.project.ownerKind, "files")
    }

    func testFaultAfterProjectCommitRecoversWithoutDuplicateMutation() async throws {
        let (storageRoot, host, workspaceStore) = try await makeHost()
        let created = try await host.create(
            name: "Poster", kind: .image, width: 400, height: 300,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        var layer = ImageLayer(kind: .text, name: "Title")
        layer.text = ImageTextContent(text: "Hello")
        let request = G09MediaApplyRequest(
            projectID: created.project.id, expectedRevision: 0,
            sessionToken: "session-1", storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone),
            opID: "fault-apply", commands: [.addImageLayer(layer)])
        struct Crash: Error {}
        await host.setFaultAfterCommit { throw Crash() }
        do {
            _ = try await host.apply(request)
            XCTFail("injected crash must surface")
        } catch {
            // Expected: the project file committed, the intent did not.
        }
        await host.setFaultAfterCommit(nil)
        // A fresh host actor simulates restart: the durable intent is the
        // only state used to classify the committed outcome.
        let restarted = G09MediaProjectHost(
            root: storageRoot, workspaceStore: workspaceStore,
            conversationStore: SQLiteConversationStore(
                database: try XCTUnwrap(database)))
        let recovered = try await restarted.apply(request)
        XCTAssertEqual(recovered.project.revision, 1)
        XCTAssertEqual(recovered.project.imageLayers.count, 1)
    }


    func testFaultAfterImportCommitRecoversTheSameAssetWithoutDuplicate() async throws {
        let (_, host, _) = try await makeHost()
        let created = try await host.create(
            name: "Poster", kind: .image, width: 320, height: 240,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let session = "session-1"
        let token = "\(session).\(UUID().uuidString)"
        let incoming = URL(fileURLWithPath: host.projectDirectoryPath, isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent("CreativeIncoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let stage = incoming.appendingPathComponent(token)
        let bytes = Data("import-fault-bytes".utf8)
        try bytes.write(to: stage)
        let digest = FloeDigest.sha256Hex(bytes)
        let request = G09MediaAssetImportRequest(
            token: token, opID: "import-fault", projectID: created.project.id,
            expectedRevision: 0, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone),
            sessionToken: session, fileName: "photo.png", mimeType: "image/png",
            byteCount: Int64(bytes.count), sha256: digest)
        struct Crash: Error {}
        await host.setFaultAfterCommit { throw Crash() }
        do {
            _ = try await host.importAsset(request, staging: stage)
            XCTFail("injected crash must surface")
        } catch {
            // Expected: project committed, asset intent not marked.
        }
        await host.setFaultAfterCommit(nil)
        let recovered = try await host.importAsset(request, staging: stage)
        XCTAssertTrue(recovered.idempotent)
        XCTAssertEqual(recovered.revision, 1)
        let loaded = try await host.load(
            id: created.project.id,
            requested: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        XCTAssertEqual(loaded.project.assets.count, 1)
        XCTAssertEqual(loaded.project.assets[0].id, recovered.asset.id)
    }

    func testMediaAssetImportAndRelinkEscape() async throws {
        let (_, host, _) = try await makeHost()
        let created = try await host.create(
            name: "Poster", kind: .image, width: 400, height: 300,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let session = "session-1"
        let token = "\(session).\(UUID().uuidString)"
        let incoming = URL(fileURLWithPath: host.projectDirectoryPath, isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent("CreativeIncoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let stage = incoming.appendingPathComponent(token)
        let bytes = Data("image-bytes".utf8)
        try bytes.write(to: stage)
        let digest = FloeDigest.sha256Hex(bytes)

        let imported = try await host.importAsset(G09MediaAssetImportRequest(
            token: token, opID: "import-1", projectID: created.project.id,
            expectedRevision: 0, storage: G09StorageLayerDTO(kind: .appOwned),
            sessionToken: session, fileName: "photo.png", mimeType: "image/png",
            byteCount: Int64(bytes.count), sha256: digest), staging: stage)
        XCTAssertEqual(imported.revision, 1)
        XCTAssertEqual(imported.asset.contentHash, digest)
        let assetURL = URL(fileURLWithPath: created.storage.rootURL.path, isDirectory: true)
            .appendingPathComponent(imported.asset.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))

        let retried = try await host.importAsset(G09MediaAssetImportRequest(
            token: token, opID: "import-1", projectID: created.project.id,
            expectedRevision: 0, storage: G09StorageLayerDTO(kind: .appOwned),
            sessionToken: session, fileName: "photo.png", mimeType: "image/png",
            byteCount: Int64(bytes.count), sha256: digest), staging: stage)
        XCTAssertTrue(retried.idempotent)
        XCTAssertEqual(retried.revision, 1)

        do {
            _ = try await host.relink(G09MediaRelinkRequest(
                projectID: created.project.id, expectedRevision: 1,
                storage: G09StorageLayerDTO(kind: .appOwned), sessionToken: session,
                assetID: imported.asset.id, relativePath: "../../escape.png",
                opID: "relink-escape"))
            XCTFail("relink outside the trusted media root must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "assetReferenceInvalid")
        }
    }

    func testForgedTaskOwnerKindIsPreservedButRefused() async throws {
        let (_, host, _) = try await makeHost()
        let created = try await host.create(
            name: "Poster", kind: .image, width: 200, height: 200,
            frameRate: nil, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let projectURL = URL(fileURLWithPath: host.projectDirectoryPath,
                             isDirectory: true)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: created.project.id))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: projectURL)) as? [String: Any])
        object["ownerKind"] = "chat"
        let forged = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try forged.write(to: projectURL)
        do {
            _ = try await host.load(id: created.project.id, requested: nil)
            XCTFail("a forged task-owned project must require real origin context")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "invalidOrigin")
        }
        XCTAssertEqual(try Data(contentsOf: projectURL), forged)
    }
}
