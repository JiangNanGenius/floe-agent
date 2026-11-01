import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeAndroidWorkbench

/// Focused R04 tests: one non-empty project is published only after the staged
/// source bytes were verified and ingested, a pre-commit failure publishes
/// nothing, and a retry with the same opID never duplicates the project/node.
final class G09SourceCreateTests: XCTestCase {
    private var roots: [URL] = []
    private var database: DatabaseManager?

    override func tearDown() async throws {
        if let database { try? await database.close() }
        database = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeRoot() throws -> RuntimeStorageRoot {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
    }

    private func makeDatabase() async throws -> DatabaseManager {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        database = manager
        return manager
    }

    private func stage(_ root: RuntimeStorageRoot, session: String,
                       bytes: Data) throws -> (token: String, url: URL, digest: String) {
        let token = "\(session).\(UUID().uuidString)"
        let directory = root.artifactStoreURL
            .appendingPathComponent("CreativeIncoming", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(token)
        try bytes.write(to: url)
        return (token, url, FloeDigest.sha256Hex(bytes))
    }

    private func request(_ action: String, payload: String,
                         epoch: UInt64 = 1, id: String = "req-1") -> Data {
        Data("""
        {"version":5,"operation":"command","requestID":"\(id)","epoch":\(epoch),"action":"\(action)","payload":\(payload)}
        """.utf8)
    }

    private func payloadObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    private func canvasPayload(token: String, opID: String, name: String = "Imported Board",
                               session: String = "session-1", fileName: String = "photo.png",
                               mime: String = "image/png", byteCount: Int,
                               digest: String, sourceKind: String = "image",
                               width: Int? = 640, height: Int? = 480) -> String {
        var fields = """
        "token":"\(token)","opID":"\(opID)","name":"\(name)",
        "sessionToken":"\(session)","fileName":"\(fileName)","mimeType":"\(mime)",
        "byteCount":\(byteCount),"sha256":"\(digest)","sourceKind":"\(sourceKind)"
        """
        if let width { fields += ",\"width\":\(width)" }
        if let height { fields += ",\"height\":\(height)" }
        return "{\(fields)}"
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeCanvasHarness() async throws
        -> (G09CanvasProjectRepository, G09CreativeAssetHost, G09CreativeRecovery,
            RuntimeStorageRoot) {
        let root = try makeRoot()
        let manager = try await makeDatabase()
        let store = CreativeAssetStore(
            database: manager, reachabilityGuard: nil, deferPhysicalReclamation: true)
        return (G09CanvasProjectRepository(root: root),
                G09CreativeAssetHost(root: root, store: store),
                G09CreativeRecovery(root: root), root)
    }

    // MARK: - Bridge: atomic Canvas creation

    func testCanvasCreateFromStagedThroughBridgeIsNonEmptyAndIdempotent() async throws {
        let root = try makeRoot()
        let manager = try await makeDatabase()
        let service = G09CreativeDomainService()
        _ = try await service.bind(epoch: 1, storage: G09CreativeStorageContext(
            root: root, database: manager,
            workspaceStore: SQLiteWorkspaceStore(database: manager),
            conversationStore: SQLiteConversationStore(database: manager)))

        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let payload = canvasPayload(
            token: staged.token, opID: "canvas-source-1",
            byteCount: bytes.count, digest: staged.digest)

        let first = BridgeV5.handle(
            requestData: request("canvas.createFromStaged", payload: payload),
            fallbackRequestID: "r1", service: service)
        XCTAssertEqual(first["ok"] as? Bool, true, "\(first)")
        let project = try XCTUnwrap(first["project"] as? [String: Any])
        let canvasID = try XCTUnwrap(project["id"] as? String)
        XCTAssertEqual(project["name"] as? String, "Imported Board")
        XCTAssertEqual(project["revision"] as? Int, 1)
        let documents = try XCTUnwrap(project["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 1)
        let nodes = try XCTUnwrap(documents.first?["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 1, "the initial document must not be empty")
        XCTAssertEqual(nodes.first?["kind"] as? String, "image")
        let asset = try XCTUnwrap(nodes.first?["asset"] as? [String: Any])
        XCTAssertEqual(asset["contentHash"] as? String, staged.digest)
        XCTAssertFalse((asset["localRelativePath"] as? String ?? "").isEmpty)
        XCTAssertEqual(first["assetsBasePath"] as? String,
                       root.artifactStoreURL.appendingPathComponent("Materials").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path),
                       "the staged copy is consumed after a committed create")

        let canvases = root.artifactStoreURL.appendingPathComponent("Canvases")
        let projectURL = canvases.appendingPathComponent("\(canvasID).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        let firstBytes = try Data(contentsOf: projectURL)

        // Retry with the SAME opID: the staged file is gone, so this proves
        // the durable intent/asset identity is the recovery path.
        let retry = BridgeV5.handle(
            requestData: request("canvas.createFromStaged", payload: payload),
            fallbackRequestID: "r2", service: service)
        XCTAssertEqual(retry["ok"] as? Bool, true, "\(retry)")
        let retriedProject = try XCTUnwrap(retry["project"] as? [String: Any])
        XCTAssertEqual(retriedProject["id"] as? String, canvasID)
        XCTAssertEqual(retriedProject["revision"] as? Int, 1)
        XCTAssertEqual(try Data(contentsOf: projectURL), firstBytes)
        let canvasEntries = try FileManager.default.contentsOfDirectory(
            atPath: canvases.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(canvasEntries.count, 1, "a retry must not publish a second canvas")

        let recovery = BridgeV5.handle(
            requestData: request("creative.recovery",
                                 payload: "{\"canvasID\":\"\(canvasID)\"}"),
            fallbackRequestID: "r3", service: service)
        XCTAssertEqual(recovery["ok"] as? Bool, true)
        XCTAssertEqual(recovery["appliedOperations"] as? Int, 1)
        XCTAssertEqual(recovery["pendingOperations"] as? Int, 0)

        // The create action registered the live editor session for the new
        // identity, so an ordinary follows-up mutation is authorized.
        let renamed = BridgeV5.handle(
            requestData: request("canvas.rename", payload: """
                {"canvasID":"\(canvasID)","expectedRevision":1,
                 "name":"Renamed Board","sessionToken":"session-1"}
                """),
            fallbackRequestID: "r4", service: service)
        XCTAssertEqual(renamed["ok"] as? Bool, true, "\(renamed)")
        XCTAssertEqual(renamed["revision"] as? Int, 2)
    }

    func testMediaCreateFromStagedThroughBridgeRegistersLiveSession() async throws {
        let root = try makeRoot()
        let manager = try await makeDatabase()
        let service = G09CreativeDomainService()
        _ = try await service.bind(epoch: 1, storage: G09CreativeStorageContext(
            root: root, database: manager,
            workspaceStore: SQLiteWorkspaceStore(database: manager),
            conversationStore: SQLiteConversationStore(database: manager)))

        let bytes = Data(repeating: 4, count: 1024)
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let payload = """
        {"token":"\(staged.token)","opID":"media-source-bridge","name":"Imported Photo",
         "kind":"image","storage":{"kind":"appOwned"},"sessionToken":"session-1",
         "fileName":"pixel.png","mimeType":"image/png","byteCount":\(bytes.count),
         "sha256":"\(staged.digest)","sourceKind":"image","width":800,"height":600}
        """
        let created = BridgeV5.handle(
            requestData: request("media.project.createFromStaged", payload: payload),
            fallbackRequestID: "m1", service: service)
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let project = try XCTUnwrap(created["project"] as? [String: Any])
        let projectID = try XCTUnwrap(project["id"] as? String)
        XCTAssertEqual(project["kind"] as? String, "image")
        XCTAssertEqual(project["revision"] as? Int, 2)
        XCTAssertEqual((project["assets"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((project["imageLayers"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((created["storage"] as? [String: Any])?["kind"] as? String,
                       "appOwned")
        XCTAssertFalse((created["mediaRootPath"] as? String ?? "").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))

        let renamed = BridgeV5.handle(
            requestData: request("media.project.rename", payload: """
                {"projectID":"\(projectID)","expectedRevision":2,
                 "name":"Renamed Photo","sessionToken":"session-1"}
                """),
            fallbackRequestID: "m2", service: service)
        XCTAssertEqual(renamed["ok"] as? Bool, true, "\(renamed)")
        XCTAssertEqual(renamed["revision"] as? Int, 3)
    }

    func testCanvasCreateFromStagedFailurePublishesNoEmptyProject() async throws {
        let root = try makeRoot()
        let manager = try await makeDatabase()
        let service = G09CreativeDomainService()
        _ = try await service.bind(epoch: 1, storage: G09CreativeStorageContext(
            root: root, database: manager,
            workspaceStore: SQLiteWorkspaceStore(database: manager),
            conversationStore: SQLiteConversationStore(database: manager)))

        let bytes = Data(repeating: 7, count: 1024)
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let wrongDigest = String(repeating: "a", count: 64)
        let failed = BridgeV5.handle(
            requestData: request("canvas.createFromStaged", payload: canvasPayload(
                token: staged.token, opID: "canvas-source-fail",
                byteCount: bytes.count, digest: wrongDigest)),
            fallbackRequestID: "f1", service: service)
        XCTAssertEqual(failed["ok"] as? Bool, false)
        XCTAssertEqual(failed["error"] as? String, "assetDigestMismatch")
        let canvases = root.artifactStoreURL.appendingPathComponent("Canvases")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: canvases.path))?
            .filter { $0.hasSuffix(".json") } ?? []
        XCTAssertTrue(entries.isEmpty, "a failed import must not publish a canvas")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path),
                      "the staged bytes stay untouched for an explicit retry")

        // The untouched staging file now succeeds under the SAME opID.
        let retried = BridgeV5.handle(
            requestData: request("canvas.createFromStaged", payload: canvasPayload(
                token: staged.token, opID: "canvas-source-fail",
                byteCount: bytes.count, digest: staged.digest)),
            fallbackRequestID: "f2", service: service)
        XCTAssertEqual(retried["ok"] as? Bool, true, "\(retried)")
        let after = (try? FileManager.default.contentsOfDirectory(atPath: canvases.path))?
            .filter { $0.hasSuffix(".json") } ?? []
        XCTAssertEqual(after.count, 1)
    }

    func testCanvasCreateFromStagedChangedFingerprintIsRefused() async throws {
        let root = try makeRoot()
        let manager = try await makeDatabase()
        let service = G09CreativeDomainService()
        _ = try await service.bind(epoch: 1, storage: G09CreativeStorageContext(
            root: root, database: manager,
            workspaceStore: SQLiteWorkspaceStore(database: manager),
            conversationStore: SQLiteConversationStore(database: manager)))

        let bytes = Data(repeating: 3, count: 512)
        let firstStage = try stage(root, session: "session-1", bytes: bytes)
        let first = BridgeV5.handle(
            requestData: request("canvas.createFromStaged", payload: canvasPayload(
                token: firstStage.token, opID: "canvas-source-same-op",
                byteCount: bytes.count, digest: firstStage.digest)),
            fallbackRequestID: "c1", service: service)
        XCTAssertEqual(first["ok"] as? Bool, true)
        let canvasID = try XCTUnwrap(
            (first["project"] as? [String: Any])?["id"] as? String)

        let otherBytes = Data(repeating: 9, count: 640)
        let changed = try stage(root, session: "session-1", bytes: otherBytes)
        let refused = BridgeV5.handle(
            requestData: request("canvas.createFromStaged", payload: canvasPayload(
                token: changed.token, opID: "canvas-source-same-op",
                byteCount: otherBytes.count, digest: changed.digest)),
            fallbackRequestID: "c2", service: service)
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "invalidPayload")
        let canvases = root.artifactStoreURL.appendingPathComponent("Canvases")
        let entries = try FileManager.default.contentsOfDirectory(atPath: canvases.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(entries, ["\(canvasID).json"])
    }

    // MARK: - Repository: collision / crash windows

    func testCanvasSourceCollisionWithForeignFileIsRefusedUntouched() async throws {
        let (repository, assets, recovery, root) = try await makeCanvasHarness()
        let projectID = G09SourceCreateIdentity.projectID(
            domain: "canvas", opID: "op-collision")
        let document = CanvasDocument(name: "Foreign")
        let foreign = CanvasProject(
            id: projectID, name: "Foreign", documents: [document],
            selectedDocumentID: document.id, revision: 1)
        let foreignBytes = try G09CreativeWire.encoder().encode(foreign)
        try FileManager.default.createDirectory(
            at: repository.projectURL(id: projectID).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try foreignBytes.write(to: repository.projectURL(id: projectID))

        let bytes = Data(repeating: 1, count: 256)
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let calls = Counter()
        do {
            _ = try await repository.createFromSource(
                projectID: projectID, opID: "op-collision",
                referenceOpID: "op-collision.ref", name: "Mine",
                workspaceID: nil, sessionToken: "session-1",
                fingerprint: "fp", nodeKind: .image, displayName: "photo.png",
                ensureAsset: { recorded in
                    calls.increment()
                    if let recorded { return recorded }
                    return try await assets.ingestForSourceCreate(
                        staging: staged.url, fileName: "photo.png",
                        mimeType: "image/png", byteCount: Int64(bytes.count),
                        sha256: staged.digest,
                        candidateID: G09SourceCreateIdentity.assetID(
                            domain: "canvas", opID: "op-collision"))
                },
                applyReference: { assetID, referenceOpID in
                    _ = try await recovery.apply(
                        canvasID: projectID,
                        operations: [G09AssetReferenceOperationDTO(
                            opID: referenceOpID, assetID: assetID, delta: 1)],
                        host: assets)
                })
            XCTFail("a foreign project at the derived identity must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.reason, "projectIdentityCollision")
        }
        XCTAssertEqual(calls.count, 0, "collision must be refused before ingestion")
        XCTAssertEqual(try Data(contentsOf: repository.projectURL(id: projectID)),
                       foreignBytes)
    }

    func testCanvasSourcePrecommitFaultPublishesNothingAndRetriesOnce() async throws {
        let (repository, assets, recovery, root) = try await makeCanvasHarness()
        let projectID = G09SourceCreateIdentity.projectID(
            domain: "canvas", opID: "op-precommit")
        let bytes = Data((0..<777).map { UInt8($0 % 241) })
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let referenceOpID = "op-precommit.ref"
        let calls = Counter()

        let ensure: @Sendable (CanvasAssetReference?) async throws -> CanvasAssetReference = {
            recorded in
            calls.increment()
            if let recorded { return recorded }
            return try await assets.ingestForSourceCreate(
                staging: staged.url, fileName: "photo.png", mimeType: "image/png",
                byteCount: Int64(bytes.count), sha256: staged.digest,
                candidateID: G09SourceCreateIdentity.assetID(
                    domain: "canvas", opID: "op-precommit"))
        }
        let applyRef: @Sendable (UUID, String) async throws -> Void = { assetID, opID in
            _ = try await recovery.apply(
                canvasID: projectID,
                operations: [G09AssetReferenceOperationDTO(
                    opID: opID, assetID: assetID, delta: 1)],
                host: assets)
        }
        await repository.setFaultBeforePublish { throw G09CreativeError.writeFailed }
        do {
            _ = try await repository.createFromSource(
                projectID: projectID, opID: "op-precommit",
                referenceOpID: referenceOpID, name: "Board", workspaceID: nil,
                sessionToken: "session-1", fingerprint: "fp-precommit",
                nodeKind: .image, displayName: "photo.png",
                ensureAsset: ensure, applyReference: applyRef)
            XCTFail("the injected pre-publish fault must surface")
        } catch {
            // Expected: the project was never published.
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repository.projectURL(id: projectID).path),
            "a pre-commit failure must not leave an empty canvas")
        await repository.setFaultBeforePublish(nil)

        let retried = try await repository.createFromSource(
            projectID: projectID, opID: "op-precommit",
            referenceOpID: referenceOpID, name: "Board", workspaceID: nil,
            sessionToken: "session-1", fingerprint: "fp-precommit",
            nodeKind: .image, displayName: "photo.png",
            ensureAsset: ensure, applyReference: applyRef)
        XCTAssertFalse(retried.idempotent)
        XCTAssertEqual(retried.loaded.project.documents.count, 1)
        XCTAssertEqual(retried.loaded.project.documents.first?.nodes.count, 1)
        XCTAssertEqual(calls.count, 2)
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: repository.projectURL(id: projectID).deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(entries.count, 1)
        let state = try await recovery.recover(canvasID: projectID, host: assets)
        XCTAssertEqual(state.applied, 1, "the reference increment must apply exactly once")
        XCTAssertEqual(state.pending, 0)
    }

    func testCanvasSourcePostCommitFaultReplaysKnownOutcomeWithoutDuplicate() async throws {
        let (repository, assets, recovery, root) = try await makeCanvasHarness()
        let projectID = G09SourceCreateIdentity.projectID(
            domain: "canvas", opID: "op-postcommit")
        let bytes = Data(repeating: 5, count: 900)
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let referenceOpID = "op-postcommit.ref"
        let ensure: @Sendable (CanvasAssetReference?) async throws -> CanvasAssetReference = {
            recorded in
            if let recorded { return recorded }
            return try await assets.ingestForSourceCreate(
                staging: staged.url, fileName: "photo.png", mimeType: "image/png",
                byteCount: Int64(bytes.count), sha256: staged.digest,
                candidateID: G09SourceCreateIdentity.assetID(
                    domain: "canvas", opID: "op-postcommit"))
        }
        let applyRef: @Sendable (UUID, String) async throws -> Void = { assetID, opID in
            _ = try await recovery.apply(
                canvasID: projectID,
                operations: [G09AssetReferenceOperationDTO(
                    opID: opID, assetID: assetID, delta: 1)],
                host: assets)
        }
        await repository.setFaultAfterCommit { throw G09CreativeError.writeFailed }
        do {
            _ = try await repository.createFromSource(
                projectID: projectID, opID: "op-postcommit",
                referenceOpID: referenceOpID, name: "Board", workspaceID: nil,
                sessionToken: "session-1", fingerprint: "fp-postcommit",
                nodeKind: .image, displayName: "photo.png",
                ensureAsset: ensure, applyReference: applyRef)
            XCTFail("the injected post-commit fault must surface")
        } catch {
            // Expected: the file is committed but the reply was interrupted.
        }
        let committedBytes = try Data(contentsOf: repository.projectURL(id: projectID))
        await repository.setFaultAfterCommit(nil)

        let replay = try await repository.createFromSource(
            projectID: projectID, opID: "op-postcommit",
            referenceOpID: referenceOpID, name: "Board", workspaceID: nil,
            sessionToken: "session-1", fingerprint: "fp-postcommit",
            nodeKind: .image, displayName: "photo.png",
            ensureAsset: ensure, applyReference: applyRef)
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(replay.loaded.project.revision, 1)
        XCTAssertEqual(try Data(contentsOf: repository.projectURL(id: projectID)),
                       committedBytes)
        let state = try await recovery.recover(canvasID: projectID, host: assets)
        XCTAssertEqual(state.applied, 1, "replay must not double-increment the reference")
    }

    // MARK: - Media host: atomic image/video creation

    private func makeMediaHost() async throws -> (RuntimeStorageRoot, G09MediaProjectHost,
                                                  SQLiteWorkspaceStore) {
        let root = try makeRoot()
        let manager = try await makeDatabase()
        let workspaceStore = SQLiteWorkspaceStore(database: manager)
        let conversationStore = SQLiteConversationStore(database: manager)
        return (root, G09MediaProjectHost(
                    root: root, workspaceStore: workspaceStore,
                    conversationStore: conversationStore), workspaceStore)
    }

    private func mediaRequest(token: String, opID: String, kind: String,
                              digest: String, bytes: Int, fileName: String,
                              mime: String, width: Int = 640, height: Int = 480,
                              duration: Double? = nil) -> G09MediaSourceCreateRequest {
        G09MediaSourceCreateRequest(
            token: token, opID: opID, name: "Imported \(kind)",
            kind: kind, storage: G09StorageLayerDTO(kind: .appOwned),
            origin: nil, sessionToken: "session-1", fileName: fileName,
            mimeType: mime, byteCount: Int64(bytes), sha256: digest,
            sourceKind: kind, width: width, height: height,
            durationSeconds: duration, frameRate: kind == "video" ? 30 : nil,
            rotationDegrees: nil)
    }

    func testMediaSourceImagePublishesLayerAndReopens() async throws {
        let (root, host, _) = try await makeMediaHost()
        let bytes = Data(repeating: 4, count: 2048)
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let projectID = G09SourceCreateIdentity.projectID(
            domain: "media", opID: "media-source-1")
        let request = mediaRequest(
            token: staged.token, opID: "media-source-1", kind: "image",
            digest: staged.digest, bytes: bytes.count,
            fileName: "pixel.png", mime: "image/png")

        let created = try await host.createFromSource(
            request, staging: staged.url, projectID: projectID)
        XCTAssertEqual(created.project.kind, .image)
        XCTAssertEqual(created.project.revision, 2)
        XCTAssertEqual(created.project.canvas?.width, 640)
        XCTAssertEqual(created.project.canvas?.height, 480)
        XCTAssertEqual(created.project.assets.count, 1)
        XCTAssertEqual(created.project.imageLayers.count, 1)
        XCTAssertEqual(created.project.imageLayers.first?.assetID,
                       created.project.assets.first?.id)
        XCTAssertEqual(created.project.sourceAssetID, created.project.assets.first?.id)
        XCTAssertEqual(created.project.assets.first?.metadata?.width, 640)
        XCTAssertEqual(created.project.assets.first?.metadata?.height, 480)
        XCTAssertEqual(created.storage.storage, G09StorageLayerDTO(kind: .appOwned))
        XCTAssertTrue(created.storage.rootURL.path.hasPrefix(
            root.artifactStoreURL.appendingPathComponent("WorkbenchRoot").path))
        let assetPath = created.storage.rootURL.appendingPathComponent(
            created.project.assets.first?.relativePath ?? "missing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetPath.path))

        // Reopen through the frozen media load action with the explicit
        // storage layer: the asset reference and layer must survive.
        let reopened = try await host.load(
            id: projectID, requested: G09StorageLayerDTO(kind: .appOwned))
        XCTAssertEqual(reopened.project.assets.count, 1)
        XCTAssertEqual(reopened.project.imageLayers.count, 1)
        XCTAssertTrue(reopened.writable)

        // Retry with the same opID and the staged file already consumed.
        let retry = try await host.createFromSource(
            request, staging: nil, projectID: projectID)
        XCTAssertEqual(retry.project.revision, 2)
        XCTAssertEqual(retry.project.assets.count, 1)
        XCTAssertEqual(retry.project.imageLayers.count, 1)
        let projects = try FileManager.default.contentsOfDirectory(
            atPath: host.projectDirectoryPath).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(projects.count, 1)
    }

    func testMediaSourceWorkspaceStorageAndOriginStayExplicit() async throws {
        let (root, host, workspaceStore) = try await makeMediaHost()
        let workspaceID = UUID()
        let relative = "PrivateTasks/\(UUID().uuidString)"
        try await workspaceStore.saveWorkspace(WorkspaceRecord(
            id: workspaceID, name: "Workspace", rootBookmark: Data(),
            kind: .privateTask, internalRelativePath: relative))
        let bytes = Data(repeating: 1, count: 1024)
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let projectID = G09SourceCreateIdentity.projectID(
            domain: "media", opID: "media-source-workspace")
        var request = mediaRequest(
            token: staged.token, opID: "media-source-workspace", kind: "image",
            digest: staged.digest, bytes: bytes.count,
            fileName: "pixel.png", mime: "image/png")
        request.storage = G09StorageLayerDTO(kind: .workspace, workspaceID: workspaceID)
        request.origin = G09CreativeOriginDTO(
            kind: .workspace, ownerID: workspaceID)
        let created = try await host.createFromSource(
            request, staging: staged.url, projectID: projectID)
        XCTAssertEqual(created.project.ownerKind, "workspace")
        XCTAssertEqual(created.project.ownerID, workspaceID)
        XCTAssertEqual(created.storage.storage,
                       G09StorageLayerDTO(kind: .workspace, workspaceID: workspaceID))
        let expected = URL(fileURLWithPath: root.path, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
        XCTAssertEqual(created.storage.rootURL.standardizedFileURL.path,
                       expected.standardizedFileURL.path)
        let assetPath = created.storage.rootURL.appendingPathComponent(
            created.project.assets.first?.relativePath ?? "missing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetPath.path))
        let reopened = try await host.load(
            id: projectID,
            requested: G09StorageLayerDTO(kind: .workspace, workspaceID: workspaceID),
            origin: G09CreativeOriginDTO(kind: .workspace, ownerID: workspaceID))
        XCTAssertTrue(reopened.writable)
        XCTAssertEqual(reopened.project.assets.count, 1)
    }

    func testMediaSourceVideoPublishesClipMetadata() async throws {
        let (root, host, _) = try await makeMediaHost()
        let bytes = Data(repeating: 6, count: 4096)
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let projectID = G09SourceCreateIdentity.projectID(
            domain: "media", opID: "media-source-video")
        let request = mediaRequest(
            token: staged.token, opID: "media-source-video", kind: "video",
            digest: staged.digest, bytes: bytes.count,
            fileName: "clip.mp4", mime: "video/mp4",
            width: 1280, height: 720, duration: 12.5)
        let created = try await host.createFromSource(
            request, staging: staged.url, projectID: projectID)
        XCTAssertEqual(created.project.kind, .video)
        XCTAssertEqual(created.project.canvas?.width, 1280)
        XCTAssertEqual(created.project.canvas?.height, 720)
        XCTAssertEqual(created.project.canvas?.frameRate, 30)
        XCTAssertEqual(created.project.videoTimeline?.clips.count, 1)
        XCTAssertEqual(created.project.videoTimeline?.clips.first?.trimStart, 0)
        XCTAssertEqual(created.project.videoTimeline?.clips.first?.trimEnd, 12.5)
        XCTAssertEqual(created.project.assets.first?.kind, .video)
        XCTAssertEqual(created.project.assets.first?.metadata?.durationSeconds, 12.5)
        XCTAssertEqual(created.project.assets.first?.metadata?.width, 1280)
        XCTAssertEqual(created.project.imageLayers.count, 0)
    }

    func testMediaSourceKindMismatchAndBadDigestPublishNothing() async throws {
        let (root, host, _) = try await makeMediaHost()
        let bytes = Data(repeating: 8, count: 1024)
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let projectID = G09SourceCreateIdentity.projectID(
            domain: "media", opID: "media-source-bad")
        // Declared video for image bytes.
        let mismatch = mediaRequest(
            token: staged.token, opID: "media-source-bad", kind: "video",
            digest: staged.digest, bytes: bytes.count,
            fileName: "pixel.png", mime: "image/png", duration: 5)
        do {
            _ = try await host.createFromSource(
                mismatch, staging: staged.url, projectID: projectID)
            XCTFail("kind mismatch must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.reason, "sourceKindMismatch")
        }
        let projects = (try? FileManager.default.contentsOfDirectory(
            atPath: host.projectDirectoryPath))?.filter { $0.hasSuffix(".json") } ?? []
        XCTAssertTrue(projects.isEmpty, "a refused source must not publish a project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))

        // Correct declaration but a digest that does not match the bytes.
        let badDigest = mediaRequest(
            token: staged.token, opID: "media-source-bad", kind: "image",
            digest: String(repeating: "b", count: 64), bytes: bytes.count,
            fileName: "pixel.png", mime: "image/png")
        do {
            _ = try await host.createFromSource(
                badDigest, staging: staged.url, projectID: projectID)
            XCTFail("a mismatched digest must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "assetDigestMismatch")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: host.projectDirectoryPath, isDirectory: true)
                .appendingPathComponent(
                    MediaProjectStore.projectFileName(id: projectID)).path))
    }

    func testMediaSourcePrecommitFaultPublishesNothingThenSucceeds() async throws {
        let (root, host, _) = try await makeMediaHost()
        let bytes = Data(repeating: 2, count: 1500)
        let staged = try stage(root, session: "session-1", bytes: bytes)
        let projectID = G09SourceCreateIdentity.projectID(
            domain: "media", opID: "media-source-fault")
        let request = mediaRequest(
            token: staged.token, opID: "media-source-fault", kind: "image",
            digest: staged.digest, bytes: bytes.count,
            fileName: "pixel.png", mime: "image/png")
        await host.setFaultBeforePublish { throw G09CreativeError.writeFailed }
        do {
            _ = try await host.createFromSource(
                request, staging: staged.url, projectID: projectID)
            XCTFail("the injected pre-publish fault must surface")
        } catch {
            // Expected.
        }
        let projectURL = URL(fileURLWithPath: host.projectDirectoryPath, isDirectory: true)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: projectID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.path),
                       "a pre-commit failure must not publish a project file")
        await host.setFaultBeforePublish(nil)
        let retried = try await host.createFromSource(
            request, staging: staged.url, projectID: projectID)
        XCTAssertEqual(retried.project.assets.count, 1)
        XCTAssertEqual(retried.project.imageLayers.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
    }

    func testHandshakeAdvertisesSourceCreateActions() throws {
        let actions = BridgeV5.handshake()["actions"] as? [String] ?? []
        XCTAssertTrue(actions.contains("canvas.createFromStaged"))
        XCTAssertTrue(actions.contains("media.project.createFromStaged"))
        XCTAssertTrue(actions.contains("canvas.create"))
        XCTAssertTrue(actions.contains("media.project.create"))
    }
}
