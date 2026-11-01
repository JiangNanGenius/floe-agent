// SPDX-License-Identifier: MPL-2.0
//
// G09-R1 — the single creative domain authority for the host bridge.
//
// It binds to ONE accepted runtime epoch and reuses that generation's root,
// DatabaseManager and workspace store. No second database/root and no
// Kotlin-side business store exist. Editor writes are fenced by an explicit
// session token + project identity + expected revision; a stale epoch or
// stale session never retargets a replacement editor.
import Foundation
import FloeCore
import FloePersistence
import FloeAndroidWorkbench

/// Validated storage context handed to the creative service by
/// `AndroidRuntimeBootstrap.creativeCluster(epoch:)`. It is the SAME owned
/// cluster the rest of the runtime uses.
public struct G09CreativeStorageContext: Sendable {
    public let root: RuntimeStorageRoot
    public let database: DatabaseManager
    public let workspaceStore: SQLiteWorkspaceStore
    public let conversationStore: SQLiteConversationStore

    public init(root: RuntimeStorageRoot, database: DatabaseManager,
                workspaceStore: SQLiteWorkspaceStore,
                conversationStore: SQLiteConversationStore) {
        self.root = root
        self.database = database
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore
    }
}

public actor G09CreativeDomainService {
    private struct Bound: Sendable {
        let epoch: UInt64
        let root: RuntimeStorageRoot
        let assetStore: CreativeAssetStore
        let assets: G09CreativeAssetHost
        let canvas: G09CanvasProjectRepository
        let media: G09MediaProjectHost
        let recovery: G09CreativeRecovery
        let workspaceStore: SQLiteWorkspaceStore
    }

    private struct Session: Sendable {
        let token: String
        let projectID: UUID
        let kind: String
        let registeredAt: Date
    }

    private var bound: Bound?
    private var sessions: [String: Session] = [:]
    private var sessionOrder: [String] = []

    public init() {}

    // MARK: - Binding

    public func bind(epoch: UInt64, storage: G09CreativeStorageContext) throws -> G09CreativeStatusDTO {
        guard epoch > 0 else { throw G09CreativeError.invalidRequest("missingEpoch") }
        if let current = bound, current.epoch == epoch, current.root == storage.root {
            return status()
        }
        let assetStore = CreativeAssetStore(
            database: storage.database,
            reachabilityGuard: nil,
            deferPhysicalReclamation: true)
        bound = Bound(
            epoch: epoch,
            root: storage.root,
            assetStore: assetStore,
            assets: G09CreativeAssetHost(root: storage.root, store: assetStore),
            canvas: G09CanvasProjectRepository(root: storage.root),
            media: G09MediaProjectHost(root: storage.root,
                                       workspaceStore: storage.workspaceStore,
                                       conversationStore: storage.conversationStore),
            recovery: G09CreativeRecovery(root: storage.root),
            workspaceStore: storage.workspaceStore)
        sessions.removeAll()
        sessionOrder.removeAll()
        return status()
    }

    /// Token-scoped editor close. Closing an OLD editor after a replacement
    /// editor opened the same project must not retire the replacement: only
    /// the token that is CURRENT for that exact project is removed.
    public func closeEditor(kind: String, projectID: UUID,
                            token: String) -> (closed: Bool, replaced: Bool) {
        guard G09CreativeWire.validSessionToken(token) else {
            return (false, false)
        }
        let key = sessionKey(kind, projectID)
        guard let session = sessions[key] else { return (false, false) }
        guard session.token == token else { return (false, true) }
        sessions.removeValue(forKey: key)
        sessionOrder.removeAll { $0 == key }
        return (true, false)
    }

    /// Exact-epoch retirement. A stale epoch never unbinds a newer generation.
    public func close(epoch: UInt64) {
        guard let current = bound, current.epoch == epoch else { return }
        bound = nil
        sessions.removeAll()
        sessionOrder.removeAll()
    }

    public func status() -> G09CreativeStatusDTO {
        G09CreativeStatusDTO(
            bound: bound != nil,
            epoch: bound?.epoch,
            rootFingerprint: bound?.root.fingerprint,
            bridgeVersion: G09CreativeActions.version,
            schema: G09CreativeActions.schema,
            actions: G09CreativeActions.all,
            canvasSchemaVersion: CanvasProject.currentSchemaVersion,
            mediaSchemaVersion: MediaProject.currentSchemaVersion,
            requestMaxBytes: G09CreativeLimits.requestBytes,
            responseMaxBytes: G09CreativeLimits.responseBytes,
            canvasProjectMaxBytes: G09CreativeLimits.canvasProjectBytes,
            mediaProjectMaxBytes: G09CreativeLimits.mediaProjectBytes,
            assetMaxBytes: G09CreativeLimits.assetBytes)
    }

    // MARK: - Command dispatch

    /// Executes one closed host action and returns the exact JSON response
    /// bytes. The bridge owns version/requestID stamping and the 16 MiB
    /// response cap; this service never truncates a result.
    public func perform(epoch: UInt64, requestID: String,
                        action: String, payload: G09CreativeJSON?) async throws -> Data {
        guard let current = bound, current.epoch == epoch else {
            throw G09CreativeError.staleGeneration
        }
        guard G09CreativeActions.isCommand(action) else {
            throw G09CreativeError.unsupportedAction(G09CreativeWire.bounded(action, limit: 80))
        }
        _ = requestID
        switch action {
        // Canvas
        case "canvas.library":
            return try success(G09CanvasLibraryResponse(projects: try await current.canvas.list()))
        case "canvas.load":
            let request: G09CanvasLoadRequest = try G09CreativeWire.decode(
                G09CanvasLoadRequest.self, payload: payload)
            let loaded = try await current.canvas.load(id: request.canvasID)
            if let token = request.sessionToken {
                try registerSession(kind: "canvas", projectID: request.canvasID, token: token)
            }
            return try success(canvasEnvelope(loaded, root: current.canvas))
        case "canvas.create":
            let request: G09CanvasCreateRequest = try G09CreativeWire.decode(
                G09CanvasCreateRequest.self, payload: payload)
            guard let name = G09CreativeWire.sanitizedName(request.name) else {
                throw G09CreativeError.invalidPayload("invalidName")
            }
            guard G09CreativeWire.validSessionToken(request.sessionToken) else {
                throw G09CreativeError.invalidPayload("invalidSessionToken")
            }
            let loaded = try await current.canvas.create(
                name: name, workspaceID: request.workspaceID)
            try registerSession(kind: "canvas", projectID: loaded.project.id,
                                token: request.sessionToken)
            return try success(canvasEnvelope(loaded, root: current.canvas))
        case "canvas.createFromStaged":
            let request: G09CanvasSourceCreateRequest = try G09CreativeWire.decode(
                G09CanvasSourceCreateRequest.self, payload: payload)
            guard let name = G09CreativeWire.sanitizedName(request.name) else {
                throw G09CreativeError.invalidPayload("invalidName")
            }
            try G09SourceCreateValidation.requireOperationID(request.opID)
            try G09SourceCreateValidation.requireStagingToken(
                request.token, sessionToken: request.sessionToken)
            try G09SourceCreateValidation.requireByteCount(
                request.byteCount, digest: request.sha256)
            _ = try G09SourceCreateValidation.requireDimensions(
                request.width, request.height)
            let nodeKind = try G09SourceCreateIdentity.canvasNodeKind(
                sourceKind: request.sourceKind, fileName: request.fileName,
                mimeType: request.mimeType)
            guard let staging = current.assets.incomingURL(token: request.token) else {
                throw G09CreativeError.assetStagingInvalid
            }
            let projectID = G09SourceCreateIdentity.projectID(
                domain: "canvas", opID: request.opID)
            let fingerprint = G09SourceCreateIdentity.fingerprint(
                domain: "canvas", opID: request.opID, projectID: projectID,
                fields: [
                    "name": name,
                    "workspaceID": request.workspaceID?.uuidString.lowercased(),
                    "fileName": request.fileName,
                    "mimeType": request.mimeType,
                    "byteCount": String(request.byteCount),
                    "sha256": request.sha256.lowercased(),
                    "sourceKind": nodeKind.rawValue,
                ])
            let displayName = G09CreativeAssetHost.safeDisplayName(request.fileName)
            let outcome = try await current.canvas.createFromSource(
                projectID: projectID, opID: request.opID,
                referenceOpID: "\(request.opID).ref",
                name: name, workspaceID: request.workspaceID,
                sessionToken: request.sessionToken,
                fingerprint: fingerprint, nodeKind: nodeKind,
                displayName: displayName,
                ensureAsset: { recorded in
                    if let recorded,
                       await current.assets.recordHasDigest(
                           id: recorded.id, sha256: request.sha256),
                       let reference = await current.assets.reference(id: recorded.id) {
                        return reference
                    }
                    return try await current.assets.ingestForSourceCreate(
                        staging: staging, fileName: request.fileName,
                        mimeType: request.mimeType,
                        byteCount: request.byteCount, sha256: request.sha256,
                        candidateID: G09SourceCreateIdentity.assetID(
                            domain: "canvas", opID: request.opID))
                },
                applyReference: { assetID, referenceOpID in
                    _ = try await current.recovery.apply(
                        canvasID: projectID,
                        operations: [G09AssetReferenceOperationDTO(
                            opID: referenceOpID, assetID: assetID, delta: 1)],
                        host: current.assets)
                })
            await current.assets.discardIfPresent(token: request.token)
            try registerSession(kind: "canvas", projectID: projectID,
                                token: request.sessionToken)
            return try success(canvasEnvelope(outcome.loaded, root: current.canvas))
        case "canvas.patch":
            let request: G09CanvasPatchRequest = try G09CreativeWire.decode(
                G09CanvasPatchRequest.self, payload: payload)
            try requireSession(kind: "canvas", projectID: request.canvasID,
                               token: request.sessionToken)
            for operation in request.patch.operations {
                if let asset = operation.asset {
                    try await current.assets.validateAssetReference(asset)
                }
            }
            if let receipt = try? await current.canvas.readReceipt(opID: request.opID) {
                guard receipt.canvasID == request.canvasID else {
                    throw G09CreativeError.invalidPayload("receiptCanvasMismatch")
                }
                return try success(G09CanvasOperationReceiptDTO(
                    canvasID: receipt.canvasID, documentID: nil,
                    previousRevision: receipt.expectedRevision,
                    revision: receipt.revision, changedNodeIDs: [],
                    changedConnectionIDs: [], undoToken: nil,
                    opID: receipt.opID, idempotent: true))
            }
            let receipt = try await current.canvas.patch(request)
            return try success(receipt)
        case "canvas.rename":
            let request: G09CanvasRenameRequest = try G09CreativeWire.decode(
                G09CanvasRenameRequest.self, payload: payload)
            try requireSession(kind: "canvas", projectID: request.canvasID,
                               token: request.sessionToken)
            let loaded = try await current.canvas.rename(
                id: request.canvasID, expectedRevision: request.expectedRevision,
                name: request.name)
            return try success(G09CanvasMutationReceiptDTO(
                canvasID: request.canvasID, name: loaded.project.name,
                revision: loaded.project.revision, deleted: false,
                opID: request.opID ?? "rename-\(UUID().uuidString)",
                idempotent: false))
        case "canvas.delete":
            let request: G09CanvasDeleteRequest = try G09CreativeWire.decode(
                G09CanvasDeleteRequest.self, payload: payload)
            try requireSession(kind: "canvas", projectID: request.canvasID,
                               token: request.sessionToken)
            try await current.canvas.delete(
                id: request.canvasID, expectedRevision: request.expectedRevision)
            clearSession(kind: "canvas", projectID: request.canvasID)
            return try success(G09CanvasMutationReceiptDTO(
                canvasID: request.canvasID, name: nil,
                revision: request.expectedRevision, deleted: true,
                opID: request.opID ?? "delete-\(UUID().uuidString)",
                idempotent: false))
        case "canvas.session.close":
            let request: G09CanvasSessionCloseRequest = try G09CreativeWire.decode(
                G09CanvasSessionCloseRequest.self, payload: payload)
            let result = closeEditor(kind: "canvas", projectID: request.canvasID,
                                     token: request.sessionToken)
            return try success(G09CanvasSessionCloseReceiptDTO(
                canvasID: request.canvasID, closed: result.closed,
                replaced: result.replaced))
        case "creative.asset.importStaged":
            let request: G09AssetImportRequest = try G09CreativeWire.decode(
                G09AssetImportRequest.self, payload: payload)
            try requireAnySession(kind: "canvas", token: request.sessionToken)
            guard request.token.hasPrefix(request.sessionToken + ".") else {
                throw G09CreativeError.assetStagingInvalid
            }
            let receipt = try await current.assets.ingest(
                opID: request.opID, token: request.token,
                sessionToken: request.sessionToken, fileName: request.fileName,
                mimeType: request.mimeType, byteCount: request.byteCount,
                sha256: request.sha256)
            return try success(receipt)
        case "creative.asset.discard":
            let request: G09AssetDiscardRequest = try G09CreativeWire.decode(
                G09AssetDiscardRequest.self, payload: payload)
            try await current.assets.discard(token: request.token)
            return try success(G09EmptyResponse())
        case "creative.asset.referenceOp":
            let request: G09AssetReferenceOpRequest = try G09CreativeWire.decode(
                G09AssetReferenceOpRequest.self, payload: payload)
            try requireSession(kind: "canvas", projectID: request.canvasID,
                               token: request.sessionToken)
            _ = try await current.canvas.load(id: request.canvasID)
            let counts = try await current.recovery.apply(
                canvasID: request.canvasID, operations: request.operations,
                host: current.assets)
            return try success(G09AssetReferenceReceiptDTO(
                canvasID: request.canvasID, applied: counts.applied,
                pending: counts.pending))
        case "creative.recovery":
            let request: G09RecoveryRequest = try G09CreativeWire.decode(
                G09RecoveryRequest.self, payload: payload)
            let counts = try await current.recovery.recover(
                canvasID: request.canvasID, host: current.assets)
            return try success(G09RecoveryStateDTO(
                canvasID: request.canvasID,
                pendingOperations: counts.pending,
                appliedOperations: counts.applied,
                warnings: counts.warnings))

        // Media
        case "media.project.library":
            return try success(G09MediaLibraryResponse(projects: try await current.media.library()))
        case "media.project.load":
            let request: G09MediaProjectRequest = try G09CreativeWire.decode(
                G09MediaProjectRequest.self, payload: payload)
            let loaded = try await current.media.load(
                id: request.projectID, requested: request.storage,
                origin: request.origin)
            if let token = request.sessionToken {
                try registerSession(kind: "media", projectID: request.projectID, token: token)
            }
            return try success(mediaEnvelope(loaded))
        case "media.project.create":
            let request: G09MediaCreateRequest = try G09CreativeWire.decode(
                G09MediaCreateRequest.self, payload: payload)
            guard let kind = MediaProjectKind(rawValue: request.kind) else {
                throw G09CreativeError.invalidPayload("invalidProjectKind")
            }
            let loaded = try await current.media.create(
                name: request.name, kind: kind, width: request.width,
                height: request.height, frameRate: request.frameRate,
                storage: request.storage, origin: request.origin)
            try registerSession(kind: "media", projectID: loaded.project.id,
                                token: request.sessionToken)
            return try success(mediaEnvelope(loaded))
        case "media.project.createFromStaged":
            let request: G09MediaSourceCreateRequest = try G09CreativeWire.decode(
                G09MediaSourceCreateRequest.self, payload: payload)
            guard G09CreativeWire.sanitizedName(request.name) != nil else {
                throw G09CreativeError.invalidPayload("invalidName")
            }
            try G09SourceCreateValidation.requireOperationID(request.opID)
            try G09SourceCreateValidation.requireStagingToken(
                request.token, sessionToken: request.sessionToken)
            try G09SourceCreateValidation.requireByteCount(
                request.byteCount, digest: request.sha256)
            guard let staging = current.assets.incomingURL(token: request.token) else {
                throw G09CreativeError.assetStagingInvalid
            }
            let projectID = G09SourceCreateIdentity.projectID(
                domain: "media", opID: request.opID)
            let loaded = try await current.media.createFromSource(
                request, staging: staging, projectID: projectID)
            await current.assets.discardIfPresent(token: request.token)
            try registerSession(kind: "media", projectID: projectID,
                                token: request.sessionToken)
            return try success(mediaEnvelope(loaded))
        case "media.project.apply":
            let request: G09MediaApplyRequest = try G09CreativeWire.decode(
                G09MediaApplyRequest.self, payload: payload)
            try requireSession(kind: "media", projectID: request.projectID,
                               token: request.sessionToken)
            if let receipt = try? await current.media.readReceipt(request.opID) {
                guard receipt.projectID == request.projectID else {
                    throw G09CreativeError.invalidPayload("receiptProjectMismatch")
                }
                return try success(mediaReceipt(receipt, idempotent: true))
            }
            let loaded = try await current.media.apply(request)
            let receipt = G09MediaWriteReceipt(
                opID: request.opID, projectID: loaded.project.id,
                sessionDigest: G09CreativeAssetHost.sessionDigest(request.sessionToken),
                expectedRevision: request.expectedRevision,
                revision: loaded.project.revision,
                canUndo: MediaTransactions.canUndo(loaded.project),
                canRedo: MediaTransactions.canRedo(loaded.project))
            return try success(mediaReceipt(receipt, idempotent: false))
        case "media.project.undo", "media.project.redo":
            let request: G09MediaUndoRedoRequest = try G09CreativeWire.decode(
                G09MediaUndoRedoRequest.self, payload: payload)
            try requireSession(kind: "media", projectID: request.projectID,
                               token: request.sessionToken)
            if let receipt = try? await current.media.readReceipt(request.opID) {
                guard receipt.projectID == request.projectID else {
                    throw G09CreativeError.invalidPayload("receiptProjectMismatch")
                }
                return try success(mediaReceipt(receipt, idempotent: true))
            }
            let loaded = action == "media.project.undo"
                ? try await current.media.undo(request)
                : try await current.media.redo(request)
            let receipt = G09MediaWriteReceipt(
                opID: request.opID, projectID: loaded.project.id,
                sessionDigest: G09CreativeAssetHost.sessionDigest(request.sessionToken),
                expectedRevision: request.expectedRevision,
                revision: loaded.project.revision,
                canUndo: MediaTransactions.canUndo(loaded.project),
                canRedo: MediaTransactions.canRedo(loaded.project))
            return try success(mediaReceipt(receipt, idempotent: false))
        case "media.project.rename":
            let request: G09MediaRenameRequest = try G09CreativeWire.decode(
                G09MediaRenameRequest.self, payload: payload)
            try requireSession(kind: "media", projectID: request.projectID,
                               token: request.sessionToken)
            let loaded = try await current.media.rename(request)
            return try success(G09MediaMutationReceiptDTO(
                projectID: request.projectID, name: loaded.project.name,
                revision: loaded.project.revision, deleted: false,
                canUndo: MediaTransactions.canUndo(loaded.project),
                canRedo: MediaTransactions.canRedo(loaded.project),
                opID: request.opID ?? "rename-\(UUID().uuidString)",
                idempotent: false))
        case "media.project.delete":
            let request: G09MediaDeleteRequest = try G09CreativeWire.decode(
                G09MediaDeleteRequest.self, payload: payload)
            try requireSession(kind: "media", projectID: request.projectID,
                               token: request.sessionToken)
            if let opID = request.opID,
               let receipt = try? await current.media.readReceipt(opID),
               receipt.projectID == request.projectID {
                return try success(G09MediaMutationReceiptDTO(
                    projectID: request.projectID, name: nil,
                    revision: receipt.revision, deleted: true,
                    canUndo: false, canRedo: false, opID: opID,
                    idempotent: true))
            }
            try await current.media.delete(request)
            clearSession(kind: "media", projectID: request.projectID)
            return try success(G09MediaMutationReceiptDTO(
                projectID: request.projectID, name: nil,
                revision: request.expectedRevision, deleted: true,
                canUndo: false, canRedo: false,
                opID: request.opID ?? "delete-\(UUID().uuidString)",
                idempotent: false))
        case "media.session.close":
            let request: G09MediaSessionCloseRequest = try G09CreativeWire.decode(
                G09MediaSessionCloseRequest.self, payload: payload)
            let result = closeEditor(kind: "media", projectID: request.projectID,
                                     token: request.sessionToken)
            return try success(G09MediaSessionCloseReceiptDTO(
                projectID: request.projectID, closed: result.closed,
                replaced: result.replaced))
        case "media.asset.importStaged":
            let request: G09MediaAssetImportRequest = try G09CreativeWire.decode(
                G09MediaAssetImportRequest.self, payload: payload)
            try requireSession(kind: "media", projectID: request.projectID,
                               token: request.sessionToken)
            guard request.token.hasPrefix(request.sessionToken + "."),
                  let staging = current.assets.incomingURL(token: request.token) else {
                throw G09CreativeError.assetStagingInvalid
            }
            let receipt = try await current.media.importAsset(request, staging: staging)
            await current.assets.discardIfPresent(token: request.token)
            return try success(receipt)
        case "media.asset.relink":
            let request: G09MediaRelinkRequest = try G09CreativeWire.decode(
                G09MediaRelinkRequest.self, payload: payload)
            try requireSession(kind: "media", projectID: request.projectID,
                               token: request.sessionToken)
            let loaded = try await current.media.relink(request)
            return try success(G09MediaProjectReceiptDTO(
                projectID: loaded.project.id, revision: loaded.project.revision,
                canUndo: MediaTransactions.canUndo(loaded.project),
                canRedo: MediaTransactions.canRedo(loaded.project),
                opID: request.opID ?? "relink-\(UUID().uuidString)",
                idempotent: false))
        default:
            throw G09CreativeError.unsupportedAction(action)
        }
    }

    // MARK: - Envelopes

    private func canvasEnvelope(_ loaded: G09CanvasProjectRepository.Loaded,
                                root: G09CanvasProjectRepository) -> G09CanvasEnvelopeDTO {
        G09CanvasEnvelopeDTO(
            project: loaded.project,
            assetsBasePath: root.materialsDirectoryPath,
            writable: !loaded.warnings.contains("unsafeAssetReference"),
            recoveryWarnings: loaded.warnings)
    }

    private func mediaEnvelope(_ loaded: G09MediaProjectHost.Loaded) -> G09MediaEnvelopeDTO {
        G09MediaEnvelopeDTO(
            project: loaded.project,
            mediaRootPath: loaded.storage.rootURL.path,
            storage: loaded.storage.storage,
            writable: loaded.writable,
            warnings: loaded.warnings)
    }

    private func mediaReceipt(_ receipt: G09MediaWriteReceipt,
                              idempotent: Bool) -> G09MediaProjectReceiptDTO {
        G09MediaProjectReceiptDTO(
            projectID: receipt.projectID, revision: receipt.revision,
            canUndo: receipt.canUndo, canRedo: receipt.canRedo,
            opID: receipt.opID, idempotent: idempotent)
    }

    // MARK: - Sessions

    private func sessionKey(_ kind: String, _ id: UUID) -> String {
        "\(kind):\(id.uuidString.lowercased())"
    }

    private func registerSession(kind: String, projectID: UUID, token: String) throws {
        guard G09CreativeWire.validSessionToken(token) else {
            throw G09CreativeError.invalidPayload("invalidSessionToken")
        }
        let key = sessionKey(kind, projectID)
        if sessions[key] != nil {
            sessions[key] = Session(token: token, projectID: projectID,
                                    kind: kind, registeredAt: Date())
            return
        }
        if sessions.count >= 16, let oldest = sessionOrder.first {
            sessions.removeValue(forKey: oldest)
            sessionOrder.removeAll { $0 == oldest }
        }
        sessions[key] = Session(token: token, projectID: projectID,
                                kind: kind, registeredAt: Date())
        sessionOrder.append(key)
    }

    private func requireSession(kind: String, projectID: UUID, token: String) throws {
        let key = sessionKey(kind, projectID)
        guard let session = sessions[key] else {
            throw G09CreativeError.sessionRequired
        }
        guard session.kind == kind, session.projectID == projectID,
              session.token == token else {
            throw G09CreativeError.staleSession
        }
    }

    private func requireAnySession(kind: String, token: String) throws {
        guard sessions.values.contains(where: { $0.kind == kind && $0.token == token }) else {
            throw G09CreativeError.staleSession
        }
    }

    private func clearSession(kind: String, projectID: UUID) {
        let key = sessionKey(kind, projectID)
        sessions.removeValue(forKey: key)
        sessionOrder.removeAll { $0 == key }
    }

    // MARK: - Encoding

    private func success<T: Encodable>(_ value: T) throws -> Data {
        var object = try G09CreativeWire.object(value)
        object["ok"] = true
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]) else {
            throw G09CreativeError.storageUnavailable
        }
        return data
    }
}

private struct G09EmptyResponse: Encodable {}

private struct G09CanvasLibraryResponse: Encodable {
    var projects: [G09CanvasSummaryDTO]
}

private struct G09MediaLibraryResponse: Encodable {
    var projects: [G09MediaSummaryDTO]
}
