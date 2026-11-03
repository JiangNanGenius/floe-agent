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
        let database: DatabaseManager
        let conversationStore: SQLiteConversationStore
        let taskBindings: G09R2MediaTaskBindingStore
        let design: G09R2DesignService
    }

    private struct Session: Sendable {
        let token: String
        let projectID: UUID
        let kind: String
        let registeredAt: Date
    }

    nonisolated public let generationAvailability = G09R2GenerationAvailability()
    private var bound: Bound? {
        didSet { refreshGenerationAvailability() }
    }
    private func refreshGenerationAvailability() {
        generationAvailability.setAvailable(bound != nil && r2StoppingEpoch != bound?.epoch)
    }
    private var sessions: [String: Session] = [:]
    private var sessionOrder: [String] = []
    /// Exact generation whose Root stop was requested. New mutations and a
    /// same-epoch rebind are refused until a fully drained close unbinds.
    private var r2StoppingEpoch: UInt64? {
        didSet { refreshGenerationAvailability() }
    }

    public init() {}

    // MARK: - Binding

    public func bind(epoch: UInt64, storage: G09CreativeStorageContext) async throws -> G09CreativeStatusDTO {
        guard epoch > 0 else { throw G09CreativeError.invalidRequest("missingEpoch") }
        guard r2StoppingEpoch != epoch else {
            throw G09R2Error(.rendererUnavailable, detail: "rootDrainPending")
        }
        if let current = bound, current.epoch == epoch, current.root == storage.root {
            G09R2MediaToolAvailability.shared.markBound(epoch: epoch)
            return status()
        }
        if let current = bound, current.epoch != epoch {
            // A newer accepted generation may replace the old one only after
            // every owned import/render/snapshot has actually settled.
            guard await r2Drained(epoch: current.epoch) else {
                throw G09R2Error(.rendererUnavailable, detail: "rootDrainPending")
            }
            G09R2SnapshotLeases.shared.retire(epoch: current.epoch)
            G09R2MediaToolAvailability.shared.markUnbound(epoch: current.epoch)
        }
        let assetStore = CreativeAssetStore(
            database: storage.database,
            reachabilityGuard: nil,
            deferPhysicalReclamation: true)
        let assets = G09CreativeAssetHost(root: storage.root, store: assetStore)
        let canvasRepository = G09CanvasProjectRepository(root: storage.root)
        let design = G09R2DesignService(
            epoch: epoch,
            root: storage.root,
            canvasRepository: canvasRepository,
            assets: assets,
            workspaceStore: storage.workspaceStore,
            conversationStore: storage.conversationStore,
            database: storage.database)
        bound = Bound(
            epoch: epoch,
            root: storage.root,
            assetStore: assetStore,
            assets: assets,
            canvas: canvasRepository,
            media: G09MediaProjectHost(root: storage.root,
                                       workspaceStore: storage.workspaceStore,
                                       conversationStore: storage.conversationStore),
            recovery: G09CreativeRecovery(root: storage.root),
            workspaceStore: storage.workspaceStore,
            database: storage.database,
            conversationStore: storage.conversationStore,
            taskBindings: G09R2MediaTaskBindingStore(
                database: storage.database),
            design: design)
        sessions.removeAll()
        sessionOrder.removeAll()
        r2StoppingEpoch = nil
        G09R2MediaToolAvailability.shared.markBound(epoch: epoch)
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
    ///
    /// G09-R2 additive root-drain gate: this exact generation is NOT released
    /// while ANY owned native work remains:
    ///  * the bounded media-render ticket mailbox still owns claimed/queued
    ///    tickets (the platform must cancel real codec/IO and ack each claim);
    ///  * a streamed large-import worker is still copying/hashing/committing;
    ///  * a native-issued snapshot lease is pinned by a live ticket/export.
    /// The bound cluster, Root, DatabaseManager and recoverable project files
    /// stay valid meanwhile, and a later exact-epoch close retries. Returns
    /// TRUE only when the cluster was actually released. R1-only callers see
    /// the original behavior because an unbound/empty foundation drains
    /// immediately.
    @discardableResult
    public func close(epoch: UInt64) async -> Bool {
        guard let current = bound, current.epoch == epoch else { return true }
        r2StoppingEpoch = epoch
        guard await r2Drained(epoch: epoch) else { return false }
        G09R2SnapshotLeases.shared.retire(epoch: epoch)
        bound = nil
        sessions.removeAll()
        sessionOrder.removeAll()
        r2StoppingEpoch = nil
        G09R2MediaToolAvailability.shared.markUnbound(epoch: epoch)
        return true
    }

    /// Phase-1 only: refuse new work for this generation without claiming it
    /// is drained. The owner retries `close(epoch:)` after real settlement.
    public func r2BeginRootStop(epoch: UInt64) async -> Bool {
        guard let current = bound, current.epoch == epoch else { return true }
        r2StoppingEpoch = epoch
        G09R2MediaToolAvailability.shared.markStopping(epoch: epoch)
        _ = G09R2MediaRenderHostMailbox.shared.prepareRootStop(epoch: epoch)
        _ = G09R2LargeImportService.shared.requestRootStop(epoch: epoch)
        _ = G09R2GenerationService.shared.requestRootStop(epoch: epoch)
        _ = G09R2MediaEnhancementService.shared.requestRootStop(epoch: epoch)
        return await r2Drained(epoch: epoch)
    }

    public func r2IsRootStopping(epoch: UInt64) -> Bool {
        r2StoppingEpoch == epoch
    }

    /// Aggregate over every real owned-work source. Each participant reports
    /// actual settlement (or pins), never a cancel flag. The design service is
    /// fenced here too: its in-flight file/payload operations keep Root bound.
    private func r2Drained(epoch: UInt64) async -> Bool {
        // Declared hard pin lifetime is honoured at each drain observation; a
        // leaked direct-operation handle cannot retain a file forever.
        G09R2RenderBindingPins.shared.purgeExpired(epoch: epoch)
        let mailbox = G09R2MediaRenderHostMailbox.shared.prepareRootStop(epoch: epoch)
        let imports = G09R2LargeImportService.shared.requestRootStop(epoch: epoch)
        let generation = G09R2GenerationService.shared.requestRootStop(epoch: epoch)
        let enhancement = G09R2MediaEnhancementService.shared.requestRootStop(epoch: epoch)
        let pins = G09R2SnapshotLeases.shared.pinnedCount(epoch: epoch)
        let designService = bound?.design
        let designDrained: Bool
        if let designService {
            designDrained = await designService.requestRootStop(epoch: epoch)
        } else {
            designDrained = true
        }
        return mailbox && imports && generation && enhancement
            && pins == 0 && designDrained
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
        guard r2StoppingEpoch != epoch else {
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

// MARK: - G09-R2 additive foundation seam (job-b72b2978320e484e)
//
// The R2 video/snapshot/large-import foundation binds to the SAME accepted
// generation as the R1 creative service. These accessors expose the already
// owning media host and asset host (no second store, no second root) plus the
// exact token-scoped editor-session checks. They add no dispatch path and do
// not change any R1 action.

/// The SAME bound cluster the R1 service owns, projected for the additive R2
/// foundation. Values only; no caller path and no storage authority.
public struct G09R2BoundCluster: Sendable {
    public let epoch: UInt64
    public let root: RuntimeStorageRoot
    public let media: G09MediaProjectHost
    public let assets: G09CreativeAssetHost

    public init(epoch: UInt64, root: RuntimeStorageRoot,
                media: G09MediaProjectHost, assets: G09CreativeAssetHost) {
        self.epoch = epoch
        self.root = root
        self.media = media
        self.assets = assets
    }
}

extension G09CreativeDomainService {
    /// The SAME real workspace/conversation stores owned by this accepted
    /// generation. Additive read-only projections for the media tool host's
    /// task/storage resolution; no second store or fallback root exists.
    func r2WorkspaceStore() -> SQLiteWorkspaceStore? {
        bound?.workspaceStore
    }

    func r2ConversationStore() -> SQLiteConversationStore? {
        bound?.conversationStore
    }

    /// The SAME accepted database for the additive task/project association
    /// table. No second database is opened here.
    func r2Database() -> DatabaseManager? {
        bound?.database
    }

    /// The ONE per-generation trusted media task/project association store.
    /// It is released with the bound cluster but its rows live in the same
    /// accepted database and survive a normal process restart.
    func r2TaskBindingStore() -> G09R2MediaTaskBindingStore? {
        bound?.taskBindings
    }

    /// Data-only model context for ONE real task: the ONE media project the
    /// user explicitly selected for it through the trusted Ask AI flow.
    ///
    /// The selection is the durable `selected_at` marker carried by the
    /// explicit association (a same-project reselection refreshes it); it is
    /// never inferred from pin/update timestamps. Exactly one line is returned
    /// so two same-named projects can never be confused in the model context,
    /// and the limit cannot hide an older project that was just reselected.
    ///
    /// This is reference data, never permission: it changes no tool ceiling
    /// and authorizes nothing. Every `media.project` call is still checked by
    /// the original runtime authority plus the exact task/environment/
    /// workspace binding CAS. Bounded and fail-soft — an unbound/stopping
    /// generation, a database that never used the association (no table) or a
    /// store failure yields no note instead of a failed run or an invented
    /// identity.
    func r2MediaTaskContext(taskID: UUID) async -> [String] {
        // Capture the ACTUAL accepted generation this read belongs to. A
        // stopping/unbound generation advertises nothing: its executor is
        // being retired and a replacement run must not inherit its notes.
        guard let bound = self.bound else { return [] }
        let epoch = bound.epoch
        let root = bound.root
        guard r2StoppingEpoch != epoch,
              let store = r2TaskBindingStore() else { return [] }
        let selection: G09R2MediaTaskBindingRecord?
        do {
            selection = try await store.currentSelection(taskID: taskID)
        } catch {
            return []
        }
        // The typed read awaited real IO. Publish only for the SAME still-live
        // accepted generation: a root stop or a same-epoch replacement that
        // landed while the read was in flight must never leak the old root's
        // association into a replacement run's context.
        guard let current = self.bound,
              current.epoch == epoch,
              current.root == root,
              r2StoppingEpoch != epoch else { return [] }
        guard let selection else { return [] }
        return [selection.modelContextLine]
    }

    /// Exact bound generation, or nil. Never opens a fallback root.
    public func r2BoundCluster() -> G09R2BoundCluster? {
        guard let current = bound else { return nil }
        return G09R2BoundCluster(
            epoch: current.epoch, root: current.root,
            media: current.media, assets: current.assets)
    }

    /// Registers the media editor session exactly like `media.project.load`
    /// (additive R2 load uses the same token/CAS rules).
    public func r2RegisterMediaSession(projectID: UUID, token: String) throws {
        try registerSession(kind: "media", projectID: projectID, token: token)
    }

    /// Requires the CURRENT media editor session for this exact project.
    public func r2RequireMediaSession(projectID: UUID, token: String) throws {
        try requireSession(kind: "media", projectID: projectID, token: token)
    }

    /// TRUE only while this exact generation is the bound authority and no
    /// Root stop was requested for it.
    public func r2IsGenerationLive(epoch: UInt64) -> Bool {
        bound?.epoch == epoch && r2StoppingEpoch != epoch
    }

    /// Membership test without throwing, for the bounded render-snapshot lease
    /// owner check (an export lease may outlive the editor session).
    public func r2HasMediaSession(projectID: UUID, token: String) -> Bool {
        let key = sessionKey("media", projectID)
        guard let session = sessions[key] else { return false }
        return session.kind == "media" && session.projectID == projectID &&
            session.token == token
    }
}

// MARK: - G09-R2 Design authority (additive)

extension G09CreativeDomainService {
    /// The exact design service for this generation. A stale/mismatched epoch
    /// never receives the current design authority.
    public func r2DesignService(for epoch: UInt64) -> G09R2DesignService? {
        guard let current = bound,
              current.epoch == epoch,
              r2StoppingEpoch != epoch else {
            return nil
        }
        return current.design
    }

    /// Read-only access for focused tests and host status composition.
    public func r2DesignService() -> G09R2DesignService? {
        bound?.design
    }

    /// Native-computed design availability. When the creative domain is not
    /// bound there is no design authority and no advertised action/kind.
    public func r2DesignStatus() async -> G09R2DesignStatusDTO {
        guard let design = bound?.design else {
            return G09R2DesignStatusDTO(
                bound: false,
                epoch: nil,
                rootFingerprint: nil,
                availableTargetKinds: [],
                targetKindReasons: [
                    "creativeDocument":
                        "No design authority is bound in this generation",
                ],
                availableActions: [],
                maxProposalBytes: G09R2CreativeLimits.designSourceBytes,
                maxPreviewBytes: G09R2CreativeLimits.designPreviewBytes)
        }
        return await design.status()
    }
}

extension G09CreativeDomainService {
    /// Exact bound Canvas repository for focused design tests. Production
    /// callers use the bridge actions, never this read-only handle.
    public func r2CanvasRepository() -> G09CanvasProjectRepository? {
        bound?.canvas
    }
}

/// Synchronous discovery projection updated only by the real creative binding lifecycle.
public final class G09R2GenerationAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var available = false
    public var isAvailable: Bool { lock.withLock { available } }
    fileprivate func setAvailable(_ value: Bool) { lock.withLock { available = value } }
}
