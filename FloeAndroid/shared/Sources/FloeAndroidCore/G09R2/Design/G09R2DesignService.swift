// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — the REAL native design service.
//
// It is bound to one accepted creative generation and reuses the shared
// `DesignOwnerWorkflow` (file/chat owners), `DesignCanvasService` (Canvas node
// authority) and `DesignWorkflowEngine` state machine. There is no parallel
// design project store: owner envelopes live in an explicit-root CAS and
// Canvas design state lives in the node's `canvas.design` subdocument.
//
// `design.canvas.*` mutations execute through `G09CanvasProjectRepository`'s
// normal revision CAS; every preview/export is a verified file receipt.
import Foundation
import FloeCore
import FloePersistence
import FloeWorkspace

public actor G09R2DesignService {
    public nonisolated let epoch: UInt64
    public nonisolated let serviceID: UUID
    private let root: RuntimeStorageRoot
    private let canvas: G09R2DesignCanvasDocumentRepository
    private let canvasService: DesignCanvasService
    private let canvasContent: G09R2DesignCanvasContentPort
    private let targets: DesignTargetService
    private let owners: DesignOwnerWorkflow
    private let ownerStore: G09R2DesignOwnerProjectStore
    private let payloads: G09R2DesignOwnerPayloadStore
    private let artifacts: G09R2DesignArtifactStore
    private let assets: G09CreativeAssetHost
    private let conversationStore: SQLiteConversationStore
    /// Durable run→task / job→asset authority for the creative owner. nil when
    /// the Domain owner has not injected the accepted database yet: trusted-UI
    /// creative selection still works, RUN-scoped creative access fails closed.
    private let database: DatabaseManager?
    private let creative: G09R2DesignCreativeDocumentPort
    private let authority: G09R2DesignRestructureAuthorityStore

    private var canvasSessions: [UUID: CanvasSession] = [:]
    private var canvasSessionOrder: [UUID] = []
    /// Exact trusted editor sessions for creative owner targets. Registered by
    /// `bind`; a bridge request without a matching session cannot be treated as
    /// trusted UI. A native model tool must pass its verified runID instead.
    private var creativeSessions: [String: String] = [:]
    private var creativeSessionOrder: [String] = []
    private var stopping = false
    private var activeOperations = 0
    private var busyTargets: Set<String> = []
    private var targetWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private struct CanvasSession {
        let token: String
        let registeredAt: Date
    }

    public init(
        epoch: UInt64,
        root: RuntimeStorageRoot,
        canvasRepository: G09CanvasProjectRepository,
        assets: G09CreativeAssetHost,
        workspaceStore: SQLiteWorkspaceStore,
        conversationStore: SQLiteConversationStore,
        database: DatabaseManager? = nil,
        authorityClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.epoch = epoch
        let serviceID = UUID()
        self.serviceID = serviceID
        self.root = root
        self.database = database
        let canvasAdapterRepository = G09R2DesignCanvasDocumentRepository(
            repository: canvasRepository)
        self.canvas = canvasAdapterRepository
        let designCanvasService = DesignCanvasService(
            repository: canvasAdapterRepository)
        self.canvasService = designCanvasService
        let contentPort = G09R2DesignCanvasContentPort(
            root: root, assets: assets)
        self.canvasContent = contentPort
        let workspacePort = G09R2DesignWorkspaceFilePort(
            root: root, workspaceStore: workspaceStore)
        let chatPort = G09R2DesignChatAttachmentPort(
            root: root, conversationStore: conversationStore)
        let canvasOwnerAdapter = DesignCanvasOwnerAdapter(
            service: designCanvasService, contentPort: contentPort)
        let fileAdapter = DesignFileOwnerAdapter(port: workspacePort)
        let chatAdapter = DesignChatAttachmentOwnerAdapter(port: chatPort)
        let store = G09R2DesignOwnerProjectStore(root: root)
        let runAuthority = database.map {
            G09R2DesignCreativeRunAuthority(database: $0)
        }
        let creativePort = G09R2DesignCreativeDocumentPort(
            assets: assets, envelopes: store, runAuthority: runAuthority)
        self.creative = creativePort
        let creativeAdapter = DesignCreativeOwnerAdapter(port: creativePort)
        let targetService = DesignTargetService(
            adapters: [
                canvasOwnerAdapter, fileAdapter, chatAdapter, creativeAdapter,
            ])
        self.targets = targetService
        let payloadStore = G09R2DesignOwnerPayloadStore(root: root)
        self.ownerStore = store
        self.payloads = payloadStore
        self.artifacts = G09R2DesignArtifactStore(root: root)
        self.assets = assets
        self.conversationStore = conversationStore
        let authority = G09R2DesignRestructureAuthorityStore(
            epoch: epoch, rootFingerprint: root.fingerprint,
            serviceID: serviceID, clock: authorityClock)
        self.authority = authority
        let outbox = DesignDecisionOutbox(
            fileURL: root.artifactStoreURL
                .appendingPathComponent("DesignDecisions", isDirectory: true)
                .appendingPathComponent("decisions.json"))
        let commit = G09R2DesignWorkspaceCommitPort(
            root: root, workspaceStore: workspaceStore)
        let publication = G09R2DesignCompositePublicationPort(
            chat: G09R2DesignChatPublicationPort(
                root: root, conversationStore: conversationStore),
            creative: G09R2DesignCreativePublicationPort(assets: assets))
        self.owners = DesignOwnerWorkflow(
            targets: targetService,
            store: store,
            payloads: payloadStore,
            commitPorts: [.fileDocument: commit],
            outbox: outbox,
            defaultSink: nil,
            defaultPublication: publication)
        G09R2DesignAuthorityRegistry.shared.register(
            epoch: epoch, rootFingerprint: root.fingerprint,
            serviceID: serviceID, store: authority, service: self)
    }

    deinit {
        G09R2DesignAuthorityRegistry.shared.unregister(
            epoch: epoch, serviceID: serviceID)
    }

    // MARK: - Status / root drain

    public func status() -> G09R2DesignStatusDTO {
        let bound = !stopping
        return G09R2DesignStatusDTO(
            bound: bound,
            epoch: bound ? epoch : nil,
            rootFingerprint: bound ? root.fingerprint : nil,
            availableTargetKinds: bound ? Self.availableTargetKinds : [],
            targetKindReasons: Self.targetKindReasons,
            availableActions: bound
                ? G09R2DesignAction.allCases.map(\.rawValue) : [],
            maxProposalBytes: G09R2CreativeLimits.designSourceBytes,
            maxPreviewBytes: G09R2CreativeLimits.designPreviewBytes)
    }

    /// Aggregate Root-stop gate. New design work is fenced immediately and the
    /// result is true only when no design operation is still inside real IO.
    /// The trusted restructure authority is retired with this exact Root: a
    /// prepared/confirmed claim from the old generation can never authorize a
    /// replacement Root, and a late confirm answers notReady/retired.
    public func requestRootStop(epoch: UInt64) -> Bool {
        guard epoch == self.epoch else { return true }
        stopping = true
        authority.retire()
        G09R2DesignAuthorityRegistry.shared.unregister(
            epoch: epoch, serviceID: serviceID)
        return activeOperations == 0
    }

    public func activeOperationCount(epoch: UInt64) -> Int {
        epoch == self.epoch ? activeOperations : 0
    }

    // MARK: - Public workflow

    public func state(
        _ binding: G09R2DesignBindingDTO,
        runID: UUID? = nil
    ) async throws -> G09R2DesignStateDTO {
        try await perform(binding) { target in
            if target.kind == .canvasNode {
                return try await canvasState(target, binding: binding)
            }
            return try await ownerState(
                target, binding: binding, runID: runID)
        }
    }

    public func bind(_ request: G09R2DesignBindRequest) async throws -> G09R2DesignStateDTO {
        try await perform(request.binding) { target in
            if target.kind == .canvasNode {
                let (canvasID, nodeID) = try Self.canvasIdentity(target)
                let snapshot = try await canvasService.snapshot(
                    canvasID: canvasID, nodeID: nodeID)
                if let expected = request.expectedRevision,
                   expected != snapshot.canvasRevision {
                    throw G09R2Error(
                        .designConflict,
                        detail: "canvasRevision \(expected) != \(snapshot.canvasRevision)")
                }
                try requireOperation(request.opID)
                registerCanvasSession(
                    canvasID: canvasID,
                    token: request.binding.sessionToken)
                return try canvasProjection(target, snapshot: snapshot)
            }
            try requireOperation(request.opID)
            if let existing = try await ownerStore.load(targetKey: target.stableKey) {
                if let expected = request.expectedRevision,
                   expected != existing.revision {
                    throw G09R2Error(
                        .designConflict,
                        detail: "ownerRevision \(expected) != \(existing.revision)")
                }
                if target.kind == .creativeDocument {
                    registerCreativeSession(
                        targetKey: target.stableKey,
                        token: request.binding.sessionToken)
                }
                return ownerProjection(target, envelope: existing)
            }
            if let expected = request.expectedRevision, expected != 0 {
                throw G09R2Error(
                    .designConflict, detail: "ownerRevision \(expected) != 0")
            }
            if target.kind == .creativeDocument,
               target.requestedOutputKind != nil {
                // A creative START request persists its explicit requested
                // kind in the SAME owner envelope BEFORE any material exists.
                // No canvas/workspace/project is invented here.
                let result = try await owners.beginCreativeRequest(
                    target: target,
                    operationID: request.opID,
                    expectedOwnerRevision: request.expectedRevision,
                    brief: nil,
                    spec: nil,
                    runID: nil)
                registerCreativeSession(
                    targetKey: target.stableKey,
                    token: request.binding.sessionToken)
                return ownerProjection(target, envelope: result.envelope)
            }
            let resolved = try await targets.resolve(target)
            let project = DesignWorkflowEngine.createProject(
                nodeID: target.stableKey,
                contentType: resolved.contentType)
            let envelope = DesignOwnerEnvelope(
                target: target, project: project, revision: 0)
            let stored = try await ownerStore.createInitial(
                envelope, targetKey: target.stableKey)
            if let expected = request.expectedRevision,
               expected != stored.revision {
                throw G09R2Error(
                    .designConflict,
                    detail: "ownerRevision \(expected) != \(stored.revision)")
            }
            if target.kind == .creativeDocument {
                registerCreativeSession(
                    targetKey: target.stableKey,
                    token: request.binding.sessionToken)
            }
            return ownerProjection(
                target, envelope: stored, warnings: ["unbound"])
        }
    }

    /// Persist a creative START request (requested output kind + brief/spec)
    /// before any material exists. `trustedUI` is accepted only for a target
    /// whose exact editor session was registered by `bind`; a native model
    /// tool must pass its verified `runID` instead (never a model JSON flag).
    public func beginCreativeRequest(
        _ request: G09R2DesignCreativeBeginRequest,
        runID: UUID? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignStateDTO {
        try requireOperation(request.opID)
        return try await perform(request.binding) { target in
            guard target.kind == .creativeDocument else {
                throw G09R2Error(
                    .designTargetUnavailable,
                    detail: "creativeBeginRequiresCreativeTarget")
            }
            try validateCreativeCallOrigin(
                target: target, binding: request.binding,
                runID: runID, trustedUI: trustedUI)
            let result = try await owners.beginCreativeRequest(
                target: target,
                operationID: request.opID,
                expectedOwnerRevision: request.expectedRevision,
                brief: request.brief,
                spec: request.spec,
                runID: runID)
            if runID == nil {
                registerCreativeSession(
                    targetKey: target.stableKey,
                    token: request.binding.sessionToken)
            }
            return ownerProjection(target, envelope: result.envelope)
        }
    }

    /// Bind the FIRST real creative result. The shared transaction verifies
    /// (through `DesignCreativeDocumentPort.verifyFirstResultBinding`) that
    /// the proposed staged bytes ARE the retained asset and, for a run, that
    /// a durable job→asset/task link proves provenance, BEFORE any payload or
    /// envelope revision is written.
    public func bindCreativeFirstResult(
        _ request: G09R2DesignCreativeBindRequest,
        runID: UUID? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignStateDTO {
        try requireOperation(request.opID)
        try requireRevision(request.expectedRevision)
        return try await perform(request.binding) { target in
            guard target.kind == .creativeDocument,
                  target.requestedOutputKind != nil else {
                throw G09R2Error(
                    .designTargetUnavailable,
                    detail: "creativeBindRequiresAwaitingCreativeRequest")
            }
            try validateCreativeCallOrigin(
                target: target, binding: request.binding,
                runID: runID, trustedUI: trustedUI)
            let bytes = try readStagedPayload(
                request.payload, sessionToken: request.binding.sessionToken)
            let displayName: String
            if let explicit = request.displayName,
               !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = explicit
            } else if let assetUUID = UUID(uuidString: request.boundResultID),
                      let record = await assets.record(id: assetUUID),
                      !record.displayName.isEmpty {
                displayName = record.displayName
            } else {
                displayName = "creative-result"
            }
            let outcome = try await owners.bindFirstResult(
                target: target,
                operationID: request.opID,
                expectedOwnerRevision: request.expectedRevision,
                bytes: bytes,
                format: request.payload.format,
                displayName: displayName,
                boundResultID: request.boundResultID,
                runID: runID)
            await discardStagedPayload(request.payload.token)
            return ownerProjection(target, envelope: outcome.envelope)
        }
    }

    /// Direct bind of a REAL retained creative asset. The host supplies only
    /// the asset id; native reads and verifies the contained Materials bytes
    /// through the SAME `G09CreativeAssetHost` (on-disk size cap first, digest
    /// against the canonical row) and then runs the shared first-result
    /// transaction. There is no payload token, no bridge byte body and no
    /// caller-supplied format/path, so an App picker does not duplicate a
    /// 64 MiB asset through SAF or JSON.
    public func bindCreativeRetainedFirstResult(
        _ request: G09R2DesignCreativeRetainedBindRequest,
        runID: UUID? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignStateDTO {
        try requireOperation(request.opID)
        try requireRevision(request.expectedRevision)
        return try await perform(request.binding) { target in
            guard target.kind == .creativeDocument,
                  target.requestedOutputKind != nil else {
                throw G09R2Error(
                    .designTargetUnavailable,
                    detail: "creativeBindRequiresAwaitingCreativeRequest")
            }
            try validateCreativeCallOrigin(
                target: target, binding: request.binding,
                runID: runID, trustedUI: trustedUI)
            guard let assetID = UUID(uuidString: request.boundResultID) else {
                throw G09CreativeError.invalidPayload("invalidBoundResultID")
            }
            let verified = try await assets.verifiedLocalBytes(
                id: assetID,
                maximumBytes: G09R2CreativeLimits.designSourceBytes)
            let explicit = request.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (explicit?.isEmpty == false)
                ? explicit! : verified.displayName
            let outcome = try await owners.bindFirstResult(
                target: target,
                operationID: request.opID,
                expectedOwnerRevision: request.expectedRevision,
                bytes: verified.data,
                format: verified.format,
                displayName: displayName,
                boundResultID: assetID.uuidString.lowercased(),
                runID: runID)
            return ownerProjection(target, envelope: outcome.envelope)
        }
    }

    /// SAF/manual first material: stage once, then import the VERIFIED staged
    /// bytes into the EXISTING creative asset library and bind the resulting
    /// CANONICAL asset through the shared first-result transaction. The staged
    /// token is discarded only after the bind commits; a failure keeps it for a
    /// retry with the same payload.
    public func importCreativeFirstResult(
        _ request: G09R2DesignCreativeImportBindRequest,
        runID: UUID? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignCreativeImportReceiptDTO {
        try requireOperation(request.opID)
        try requireRevision(request.expectedRevision)
        return try await perform(request.binding) { target in
            guard target.kind == .creativeDocument,
                  target.requestedOutputKind != nil else {
                throw G09R2Error(
                    .designTargetUnavailable,
                    detail: "creativeBindRequiresAwaitingCreativeRequest")
            }
            try validateCreativeCallOrigin(
                target: target, binding: request.binding,
                runID: runID, trustedUI: trustedUI)
            // Read/verify the staged bytes BEFORE any Materials write so a
            // malformed token, size or digest has zero side effects.
            _ = try readStagedPayload(
                request.payload, sessionToken: request.binding.sessionToken)
            guard let staging = assets.incomingURL(token: request.payload.token) else {
                throw G09R2Error(
                    .designPayloadMissing, detail: "stagedPayloadMissing")
            }
            let format = Self.normalizedFormat(request.payload.format)
            guard !format.isEmpty else {
                throw G09R2Error(
                    .designPayloadMissing, detail: "stagedFormatMismatch")
            }
            // Refuse an unsupported/mismatched family BEFORE the ingest write:
            // a wrong file must not create an unbound library asset.
            guard let requestedKind = target.requestedOutputKind,
                  let family = DesignContentType.from(format: format),
                  family == requestedKind else {
                throw G09R2Error(
                    .renderUnsupported, detail: "firstResultFormatMismatch")
            }
            let explicit = request.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawName = (explicit?.isEmpty == false)
                ? explicit! : "creative-result"
            let fileName = Self.creativeImportFileName(
                rawName, format: format)
            let ingested = try await assets.ingestForSourceCreateReportingMerge(
                staging: staging,
                fileName: fileName,
                mimeType: G09R2DesignWorkspaceResolver.mimeType(for: format),
                byteCount: request.payload.byteCount,
                sha256: request.payload.sha256,
                candidateID: UUID())
            let verified = try await assets.verifiedLocalBytes(
                id: ingested.reference.id,
                maximumBytes: G09R2CreativeLimits.designSourceBytes)
            let outcome = try await owners.bindFirstResult(
                target: target,
                operationID: request.opID,
                expectedOwnerRevision: request.expectedRevision,
                bytes: verified.data,
                format: verified.format,
                displayName: explicit?.isEmpty == false
                    ? explicit! : verified.displayName,
                boundResultID: verified.assetID.uuidString.lowercased(),
                runID: runID)
            await discardStagedPayload(request.payload.token)
            let record = await assets.record(id: verified.assetID)
            return G09R2DesignCreativeImportReceiptDTO(
                state: ownerProjection(target, envelope: outcome.envelope),
                asset: G09R2DesignCreativeInventory.assetDTO(
                    assetID: verified.assetID,
                    displayName: verified.displayName,
                    kind: G09R2DesignCreativePublicationPort
                        .mediaKind(forFormat: verified.format),
                    format: verified.format,
                    byteCount: verified.byteCount,
                    contentSHA256: verified.contentSHA256,
                    updatedAt: record?.updatedAt ?? Date(),
                    selectable: true),
                imported: !ingested.deduplicated)
        }
    }

    /// Bounded metadata page over the EXISTING creative asset catalog. It
    /// returns ids/names/kinds/formats/sizes/digests only — never bytes or a
    /// path — and is available only through the trusted App bridge while this
    /// service is bound to the current accepted root/epoch. A free-form
    /// filesystem query is impossible: the accepted database is the only
    /// source and the result is capped at 24 rows with a keyset cursor.
    public func creativeAssets(
        limit: Int = 24,
        cursor: String? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignCreativeAssetPageDTO {
        guard trustedUI else { throw G09CreativeError.sessionRequired }
        return try await performRead {
            guard let database = database else {
                throw G09R2Error(
                    .designTargetUnavailable,
                    detail: "creativeAssetInventoryRequiresAcceptedDatabase")
            }
            return try await G09R2DesignCreativeInventory(
                database: database).assets(limit: limit, cursor: cursor)
        }
    }

    /// Bounded reopen list over the SAME owner-envelope store the workflow
    /// writes. Each item carries the exact frozen target identity, owner
    /// revision and typed creative request; there is no second request store.
    public func creativePendingRequests(
        limit: Int = 24,
        cursor: String? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignCreativePendingPageDTO {
        guard trustedUI else { throw G09CreativeError.sessionRequired }
        return try await performRead {
            try await G09R2DesignCreativeInventory(
                ownerStore: ownerStore).pendingRequests(
                    limit: limit, cursor: cursor)
        }
    }

    public func setBrief(
        _ request: G09R2DesignBriefRequest,
        runID: UUID? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignStateDTO {
        try requireOperation(request.opID)
        try requireRevision(request.expectedRevision)
        return try await perform(request.binding) { target in
            if target.kind == .canvasNode {
                let (canvasID, nodeID) = try Self.canvasIdentity(target)
                try requireCanvasSession(
                    canvasID: canvasID, token: request.binding.sessionToken)
                let snapshot = try await canvasService.snapshot(
                    canvasID: canvasID, nodeID: nodeID)
                let contentType = try Self.canvasMutationContentType(
                    snapshot: snapshot, nodeID: nodeID.uuidString.lowercased())
                let updated = try await canvasService.mutate(
                    canvasID: canvasID, nodeID: nodeID,
                    expectedRevision: request.expectedRevision,
                    operationID: request.opID,
                    contentType: contentType
                ) { design in
                    DesignWorkflowEngine.updateBrief(request.brief, in: &design)
                }
                return try canvasProjection(target, snapshot: updated)
            }
            try validateCreativeCallOrigin(
                target: target, binding: request.binding,
                runID: runID, trustedUI: trustedUI)
            let envelope = try await owners.updateBrief(
                target: target,
                operationID: request.opID,
                expectedOwnerRevision: request.expectedRevision,
                brief: request.brief,
                runID: runID)
            return ownerProjection(target, envelope: envelope)
        }
    }

    public func setSpec(
        _ request: G09R2DesignSpecRequest,
        runID: UUID? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignStateDTO {
        try requireOperation(request.opID)
        try requireRevision(request.expectedRevision)
        return try await perform(request.binding) { target in
            if target.kind == .canvasNode {
                let (canvasID, nodeID) = try Self.canvasIdentity(target)
                try requireCanvasSession(
                    canvasID: canvasID, token: request.binding.sessionToken)
                let snapshot = try await canvasService.snapshot(
                    canvasID: canvasID, nodeID: nodeID)
                let contentType = try Self.canvasMutationContentType(
                    snapshot: snapshot, nodeID: nodeID.uuidString.lowercased())
                let updated = try await canvasService.mutate(
                    canvasID: canvasID, nodeID: nodeID,
                    expectedRevision: request.expectedRevision,
                    operationID: request.opID,
                    contentType: contentType
                ) { design in
                    DesignWorkflowEngine.updateSpec(request.spec, in: &design)
                }
                return try canvasProjection(target, snapshot: updated)
            }
            try validateCreativeCallOrigin(
                target: target, binding: request.binding,
                runID: runID, trustedUI: trustedUI)
            let envelope = try await owners.updateSpec(
                target: target,
                operationID: request.opID,
                expectedOwnerRevision: request.expectedRevision,
                spec: request.spec,
                runID: runID)
            return ownerProjection(target, envelope: envelope)
        }
    }

    public func freeze(
        _ request: G09R2DesignFreezeRequest,
        runID: UUID? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignFreezeReceiptDTO {
        try requireOperation(request.opID)
        try requireRevision(request.expectedRevision)
        return try await perform(request.binding) { target in
            try validateCreativeCallOrigin(
                target: target, binding: request.binding,
                runID: runID, trustedUI: trustedUI)
            if target.kind == .canvasNode {
                return try await canvasFreeze(target, request: request)
            }
            return try await ownerFreeze(
                target, request: request, runID: runID)
        }
    }

    public func propose(
        _ request: G09R2DesignProposeRequest,
        runID: UUID? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignProposalResultDTO {
        try requireOperation(request.opID)
        try requireRevision(request.expectedRevision)
        return try await perform(request.binding) { target in
            try validateCreativeCallOrigin(
                target: target, binding: request.binding,
                runID: runID, trustedUI: trustedUI)
            if target.kind == .canvasNode {
                return try await canvasPropose(target, request: request)
            }
            return try await ownerPropose(
                target, request: request, runID: runID)
        }
    }

    public func adopt(
        _ request: G09R2DesignAdoptRequest,
        runID: UUID? = nil,
        trustedUI: Bool = false
    ) async throws -> G09R2DesignDecisionResultDTO {
        try requireOperation(request.opID)
        try requireRevision(request.expectedRevision)
        return try await perform(request.binding) { target in
            try validateCreativeCallOrigin(
                target: target, binding: request.binding,
                runID: runID, trustedUI: trustedUI)
            if target.kind == .canvasNode {
                return try await canvasAdopt(target, request: request)
            }
            return try await ownerAdopt(
                target, request: request, runID: runID)
        }
    }

    public func reject(
        _ request: G09R2DesignRejectRequest,
        runID: UUID? = nil
    ) async throws -> G09R2DesignDecisionReceiptDTO {
        try requireOperation(request.opID)
        try requireRevision(request.expectedRevision)
        return try await perform(request.binding) { target in
            if target.kind == .canvasNode {
                return try await canvasReject(target, request: request)
            }
            let result = try await owners.reject(
                target: target,
                operationID: request.opID,
                expectedOwnerRevision: request.expectedRevision,
                candidateID: request.candidateID,
                runID: runID)
            return G09R2DesignDecisionReceiptDTO(
                state: ownerProjection(target, envelope: result.envelope),
                candidateID: request.candidateID,
                operationID: request.opID,
                idempotent: result.replayed)
        }
    }

    public func compare(
        _ request: G09R2DesignCompareRequest,
        runID: UUID? = nil
    ) async throws -> G09R2DesignComparisonDTO {
        try await perform(request.binding) { target in
            if target.kind == .canvasNode {
                return try await canvasCompare(target, request: request)
            }
            let comparison = try await owners.compare(
                target: target, candidateID: request.candidateID, runID: runID)
            return G09R2DesignComparisonDTO(
                candidateID: comparison.candidateID,
                baseSHA256: comparison.baseSHA256,
                proposedSHA256: comparison.proposedSHA256,
                changed: comparison.changed,
                diff: comparison.diff,
                diffTruncated: comparison.diffTruncated,
                diffNote: comparison.diffNote,
                status: comparison.status)
        }
    }

    public func restore(
        _ request: G09R2DesignRestoreRequest,
        runID: UUID? = nil
    ) async throws -> G09R2DesignStateDTO {
        try requireOperation(request.opID)
        try requireRevision(request.expectedRevision)
        return try await perform(request.binding) { target in
            if target.kind == .canvasNode {
                return try await canvasRestore(target, request: request)
            }
            let envelope = try await owners.state(target, runID: runID)
            guard let envelope,
                  let artifact = envelope.project.artifacts.first(where: {
                      $0.revision(request.revisionID) != nil
                  }) else {
                throw G09R2Error(.designPayloadMissing, detail: "revisionNotFound")
            }
            let restored = try await owners.restore(
                target: target,
                operationID: request.opID,
                expectedOwnerRevision: request.expectedRevision,
                artifactID: artifact.id,
                revisionID: request.revisionID,
                runID: runID)
            return ownerProjection(target, envelope: restored)
        }
    }

    public func preview(
        _ request: G09R2DesignPreviewRequest,
        runID: UUID? = nil
    ) async throws -> G09R2DesignPreviewReceiptDTO {
        let limit = min(
            max(1, request.maxBytes),
            G09R2CreativeLimits.designPreviewBytes)
        return try await perform(request.binding) { target in
            if target.kind == .canvasNode {
                return try await canvasPreview(
                    target, request: request, limit: limit)
            }
            return try await ownerPreview(
                target, request: request, limit: limit, runID: runID)
        }
    }

    public func export(
        _ request: G09R2DesignExportRequest,
        runID: UUID? = nil
    ) async throws -> G09R2DesignExportReceiptDTO {
        let format = Self.normalizedFormat(request.format)
        guard !format.isEmpty else {
            throw G09CreativeError.invalidPayload("missingFormat")
        }
        return try await perform(request.binding) { target in
            if target.kind == .canvasNode {
                return try await canvasExport(
                    target, request: request, format: format)
            }
            return try await ownerExport(
                target, request: request, format: format, runID: runID)
        }
    }

    // MARK: - Canvas reads / projections

    private func canvasState(
        _ target: DesignTarget,
        binding: G09R2DesignBindingDTO
    ) async throws -> G09R2DesignStateDTO {
        let (canvasID, nodeID) = try Self.canvasIdentity(target)
        try requireCanvasSession(
            canvasID: canvasID, token: binding.sessionToken)
        let snapshot = try await canvasService.snapshot(
            canvasID: canvasID, nodeID: nodeID)
        return try canvasProjection(target, snapshot: snapshot)
    }

    private func canvasProjection(
        _ target: DesignTarget,
        snapshot: DesignCanvasService.Snapshot
    ) throws -> G09R2DesignStateDTO {
        let nodeID = snapshot.nodeID.uuidString.lowercased()
        let contentType = Self.canvasContentType(
            snapshot: snapshot, nodeID: nodeID)
        let project = snapshot.design ?? DesignWorkflowEngine.createProject(
            nodeID: nodeID, contentType: contentType)
        let writable = !(snapshot.node?.isLocked ?? false)
            && contentType != .cad
        let actions = writable
            ? Self.canvasActions
            : Self.canvasReadActions
        return G09R2DesignStateDTO(
            envelope: DesignOwnerEnvelope(
                target: target, project: project,
                revision: snapshot.canvasRevision),
            writable: writable,
            warnings: writable ? [] : ["nodeLocked"],
            availableActions: actions)
    }

    private func ownerState(
        _ target: DesignTarget,
        binding: G09R2DesignBindingDTO,
        runID: UUID?
    ) async throws -> G09R2DesignStateDTO {
        _ = binding
        if let envelope = try await owners.state(target, runID: runID) {
            return ownerProjection(target, envelope: envelope)
        }
        let resolved = try await targets.resolve(target, runID: runID)
        let project = DesignWorkflowEngine.createProject(
            nodeID: target.stableKey,
            contentType: resolved.contentType)
        return ownerProjection(
            target,
            envelope: DesignOwnerEnvelope(
                target: target, project: project, revision: 0),
            warnings: ["unbound"])
    }

    private func ownerProjection(
        _ target: DesignTarget,
        envelope: DesignOwnerEnvelope,
        warnings: [String] = []
    ) -> G09R2DesignStateDTO {
        G09R2DesignStateDTO(
            envelope: envelope,
            writable: true,
            warnings: warnings,
            availableActions: Self.ownerActions)
    }

    // MARK: - Canvas freeze / propose

    private func canvasFreeze(
        _ target: DesignTarget,
        request: G09R2DesignFreezeRequest
    ) async throws -> G09R2DesignFreezeReceiptDTO {
        let (canvasID, nodeID) = try Self.canvasIdentity(target)
        try requireCanvasSession(
            canvasID: canvasID, token: request.binding.sessionToken)
        let snapshot = try await canvasService.snapshot(
            canvasID: canvasID, nodeID: nodeID)
        if snapshot.design?.hasApplied(operationID: request.opID) == true {
            guard let frozen = snapshot.design?.frozenRun else {
                throw G09R2Error(.designConflict, detail: "freezeReplayMissingRun")
            }
            return G09R2DesignFreezeReceiptDTO(
                target: target,
                ownerRevision: snapshot.canvasRevision,
                frozenRun: frozen,
                idempotent: true)
        }
        if snapshot.node?.isLocked == true {
            throw G09R2Error(.designConflict, detail: "canvasNodeLocked")
        }
        let resolved = try await canvasContent.readNode(
            canvasID: canvasID, nodeID: nodeID, snapshot: snapshot)
        let contentType = snapshot.design?.contentType
            ?? DesignContentType.from(format: resolved.format)
            ?? DesignContentTypeMapper.effectiveContentType(
                existing: nil,
                kind: snapshot.nodeKind,
                metadata: snapshot.nodeMetadata)
        guard contentType != .cad else {
            throw G09R2Error(
                .designTargetUnavailable, detail: "cadDesignReadOnly")
        }
        let artifactID = snapshot.design?.artifacts.first(where: {
            $0.canvasNodeID == nodeID.uuidString.lowercased()
        })?.id ?? UUID().uuidString.lowercased()
        let targetKey = snapshot.design?.nodeID
            ?? nodeID.uuidString.lowercased()
        var restructureReceipt: DesignRestructureAuthorityReceipt? = nil
        let revisionID: String
        let workIntent: DesignWorkIntent?
        if request.workMode == .restructure {
            guard let confirmed = authority.confirmedRecord(
                targetKey: targetKey, operationID: request.opID,
                operationKind: .freeze) else {
                throw DesignRestructureAuthorityError.claimRequired(
                    "canvas restructure freeze requires a trusted-UI confirmation for operation \(request.opID)")
            }
            if let digest = request.preservationDigest,
               digest.caseInsensitiveCompare(
                confirmed.request.preservationDigest) != .orderedSame {
                throw DesignRestructureAuthorityError.claimMismatch(
                    "the requested preservation digest is not the confirmed restructure digest")
            }
            guard let confirmedBase = confirmed.request.baseRevisionID,
                  let safeBase = try Self.safeRevisionID(confirmedBase),
                  safeBase == confirmedBase else {
                throw DesignRestructureAuthorityError.claimRequired(
                    "canvas restructure freeze requires the confirmed input revision")
            }
            try authority.preflight(
                confirmed.request, operationKind: .freeze)
            revisionID = confirmedBase
            let intent = try DesignWorkIntent(
                mode: .restructure,
                actualDesiredFormat: request.desiredFormat ?? resolved.format,
                preservation: confirmed.constraints,
                frozenRevisionID: confirmedBase,
                originalTaskOwnerID: confirmed.request.originalTaskOwnerID,
                confirmation: DesignPreservationConfirmation(
                    constraints: confirmed.constraints,
                    confirmedAt: confirmed.confirmedAt),
                operationID: request.opID
            ).validated(family: contentType)
            workIntent = intent
            // Burn immediately before the first freeze payload/CAS write.
            restructureReceipt = try await authority.claim(
                confirmed.request, operationKind: .freeze)
        } else {
            revisionID = try Self.safeRevisionID(
                request.inputRevisionID) ?? UUID().uuidString.lowercased()
            workIntent = try Self.freezeIntent(
                request: request, family: contentType,
                format: resolved.format, revisionID: revisionID)
        }
        let relative = try payloads.store(
            ownerKey: target.stableKey,
            revisionID: revisionID,
            bytes: resolved.data,
            expectedContentSHA256: resolved.contentSHA256)
        let frozenReceipt = restructureReceipt
        do {
            let updated = try await canvasService.mutate(
                canvasID: canvasID, nodeID: nodeID,
                expectedRevision: request.expectedRevision,
                operationID: request.opID,
                contentType: contentType
            ) { design in
                if design.artifact(artifactID) == nil {
                    DesignWorkflowEngine.addArtifact(
                        DesignArtifact(
                            id: artifactID,
                            contentType: contentType,
                            canvasNodeID: nodeID.uuidString.lowercased(),
                            identity: DesignArtifactIdentity(
                                name: resolved.displayName,
                                positionX: 0, positionY: 0,
                                width: 0, height: 0)),
                        to: &design)
                }
                _ = try DesignWorkflowEngine.registerRevision(
                    in: &design,
                    artifactID: artifactID,
                    contentSHA256: resolved.contentSHA256,
                    origin: .currentNode,
                    payloadRelativePath: relative,
                    payloadFormat: resolved.format,
                    revisionID: revisionID,
                    ownerBaseToken: resolved.baseRevisionToken)
                if let workIntent {
                    _ = try DesignWorkflowEngine.freezeRun(
                        operationID: request.opID,
                        in: &design,
                        workIntent: workIntent,
                        restructureReceipt: frozenReceipt,
                        inputRevisionID: revisionID,
                        targetRevisionID: request.targetRevisionID ?? revisionID)
                } else {
                    _ = DesignWorkflowEngine.freezeRun(
                        operationID: request.opID,
                        in: &design,
                        inputRevisionID: revisionID,
                        targetRevisionID: request.targetRevisionID ?? revisionID,
                        desiredFormat: request.desiredFormat)
                }
                if let specSHA256 = request.specSHA256 {
                    design.frozenRun?.specSHA256 = specSHA256
                }
                if let preservationDigest = request.preservationDigest {
                    design.frozenRun?.preservationDigest = preservationDigest
                }
            }
            guard let frozen = updated.design?.frozenRun else {
                throw G09R2Error(.designConflict, detail: "freezeMissingRun")
            }
            return G09R2DesignFreezeReceiptDTO(
                target: target,
                ownerRevision: updated.canvasRevision,
                frozenRun: frozen,
                idempotent: false)
        } catch {
            throw error
        }
    }

    private func canvasPropose(
        _ target: DesignTarget,
        request: G09R2DesignProposeRequest
    ) async throws -> G09R2DesignProposalResultDTO {
        let (canvasID, nodeID) = try Self.canvasIdentity(target)
        try requireCanvasSession(
            canvasID: canvasID, token: request.binding.sessionToken)
        let snapshot = try await canvasService.snapshot(
            canvasID: canvasID, nodeID: nodeID)
        guard let design = snapshot.design else {
            throw G09R2Error(
                .designTargetUnavailable, detail: "freezeInputFirst")
        }
        if let recorded = design.candidates.first(where: {
            $0.proposalOperationID == request.opID
        }) {
            guard let artifact = design.artifact(recorded.artifactID),
                  let revision = artifact.revision(recorded.proposedRevisionID),
                  revision.contentSHA256.caseInsensitiveCompare(
                    request.payload.sha256) == .orderedSame,
                  recorded.artifactID == request.artifactID,
                  recorded.summary == request.summary,
                  recorded.diff == request.diff,
                  recorded.feedbackIDs == request.feedbackIDs,
                  request.baseRevisionID.map({ $0 == recorded.baseRevisionID }) ?? true,
                  Self.normalizedFormat(revision.payloadFormat ?? "") ==
                    Self.normalizedFormat(request.payload.format),
                  recorded.proposalFingerprint == Self.canvasProposalFingerprint(
                    artifactID: request.artifactID,
                    baseRevisionID: recorded.baseRevisionID,
                    format: request.payload.format,
                    contentSHA256: request.payload.sha256,
                    summary: request.summary,
                    diff: request.diff,
                    feedbackIDs: request.feedbackIDs,
                    originConversationID: target.originConversationID,
                    originEnvironmentID: target.environmentID,
                    workMode: request.workIntent?.mode,
                    preservationDigest: request.workIntent?.preservation?.canonicalDigest
                        ?? (request.workIntent?.mode == .restructure
                            ? recorded.preservationDigest : nil)) else {
                throw G09R2Error(.designConflict, detail: "proposalReplayMismatch")
            }
            let state = try canvasProjection(target, snapshot: snapshot)
            let relative = revision.payloadRelativePath ?? ""
            await discardStagedPayload(request.payload.token)
            return G09R2DesignProposalResultDTO(
                state: state, candidate: recorded,
                payloadRelativePath: relative, replayed: true)
        }
        guard let artifact = design.artifact(request.artifactID) else {
            throw G09R2Error(.designPayloadMissing, detail: "artifactNotFound")
        }
        let base = request.baseRevisionID ?? artifact.currentRevisionID
        guard let base, artifact.revision(base) != nil else {
            throw G09R2Error(.designPayloadMissing, detail: "baseRevisionNotFound")
        }
        guard artifact.contentType != .cad else {
            throw G09R2Error(
                .designTargetUnavailable, detail: "cadDesignReadOnly")
        }
        let family = try Self.requiredContentType(request.payload.format)
        guard family == artifact.contentType else {
            throw G09R2Error(
                .renderUnsupported,
                detail: "payloadFormatFamilyMismatch")
        }
        let desiredFormat = request.workIntent?.actualDesiredFormat
            ?? request.payload.format
        var workIntent: DesignWorkIntent? = nil
        var restructureRequest: DesignRestructureAuthorityRequest? = nil
        if request.workIntent?.mode == .restructure {
            let trusted = try await trustedRestructureIntent(
                targetKey: design.nodeID,
                operationID: request.opID,
                operationKind: .propose,
                baseRevisionID: base,
                family: artifact.contentType,
                desiredFormat: desiredFormat,
                scope: request.workIntent?.scope)
            // Refuse missing/stale/wrong-target claims before reading or
            // staging any payload bytes. The burn happens immediately before
            // the first write below.
            try authority.preflight(
                trusted.request, operationKind: .propose)
            workIntent = trusted.intent
            restructureRequest = trusted.request
        } else {
            workIntent = try Self.proposalIntent(
                request: request, family: artifact.contentType, base: base)
        }
        let bytes = try readStagedPayload(
            request.payload, sessionToken: request.binding.sessionToken)
        var restructureReceipt: DesignRestructureAuthorityReceipt? = nil
        if let restructureRequest {
            restructureReceipt = try await authority.claim(
                restructureRequest, operationKind: .propose)
        }
        let proposedRevisionID = UUID().uuidString.lowercased()
        let relative = try payloads.store(
            ownerKey: target.stableKey,
            revisionID: proposedRevisionID,
            bytes: bytes,
            expectedContentSHA256: request.payload.sha256)
        let proposalReceipt = restructureReceipt
        let proposalIntent = workIntent
        do {
            let updated = try await canvasService.mutateProject(
                canvasID: canvasID, nodeID: nodeID,
                expectedRevision: request.expectedRevision,
                operationID: request.opID,
                contentType: artifact.contentType
            ) { _, design in
                _ = try DesignWorkflowEngine.proposeCandidate(
                    in: &design,
                    artifactID: request.artifactID,
                    baseRevisionID: base,
                    proposedContentSHA256: request.payload.sha256,
                    summary: request.summary,
                    diff: request.diff,
                    feedbackIDs: request.feedbackIDs,
                    proposedRevisionID: proposedRevisionID,
                    payloadRelativePath: relative,
                    payloadFormat: request.payload.format,
                    originConversationID: target.originConversationID,
                    originEnvironmentID: target.environmentID,
                    workIntent: proposalIntent,
                    restructureReceipt: proposalReceipt)
                // `DesignWorkflowEngine` is the shared pure state machine;
                // its sync propose path does not own the owner replay identity.
                // The Canvas path commits the same identity the owner path
                // does, in the SAME Canvas CAS as the candidate.
                if let index = design.candidates.firstIndex(where: {
                    $0.proposedRevisionID == proposedRevisionID
                }) {
                    design.candidates[index].proposalOperationID = request.opID
                    design.candidates[index].proposalFingerprint =
                        Self.canvasProposalFingerprint(
                            artifactID: request.artifactID,
                            baseRevisionID: base,
                            format: request.payload.format,
                            contentSHA256: request.payload.sha256,
                            summary: request.summary,
                            diff: request.diff,
                            feedbackIDs: request.feedbackIDs,
                            originConversationID: target.originConversationID,
                            originEnvironmentID: target.environmentID,
                            workMode: proposalIntent?.mode,
                            preservationDigest:
                                proposalIntent?.preservation?.canonicalDigest)
                }
            }
            guard let updatedDesign = updated.design,
                  let candidate = updatedDesign.candidates.first(where: {
                      $0.proposalOperationID == request.opID
                  }) else {
                throw G09R2Error(.designConflict, detail: "proposalNotRecorded")
            }
            await discardStagedPayload(request.payload.token)
            return G09R2DesignProposalResultDTO(
                state: try canvasProjection(target, snapshot: updated),
                candidate: candidate,
                payloadRelativePath: relative,
                replayed: false)
        } catch {
            throw error
        }
    }

    // MARK: - Canvas adopt / reject / compare / restore

    private func canvasAdopt(
        _ target: DesignTarget,
        request: G09R2DesignAdoptRequest
    ) async throws -> G09R2DesignDecisionResultDTO {
        let (canvasID, nodeID) = try Self.canvasIdentity(target)
        try requireCanvasSession(
            canvasID: canvasID, token: request.binding.sessionToken)
        let snapshot = try await canvasService.snapshot(
            canvasID: canvasID, nodeID: nodeID)
        guard let design = snapshot.design,
              let candidate = design.candidate(request.candidateID) else {
            throw G09R2Error(.candidateNotFound, detail: "candidateNotFound")
        }
        if design.hasApplied(operationID: request.opID) {
            let expectedVariant = request.mode == .variant
            let recordedVariant = candidate.variantArtifactID != nil
            guard expectedVariant == recordedVariant else {
                throw G09R2Error(
                    .designConflict, detail: "adoptionReplayModeMismatch")
            }
            if candidate.status == .adopted || candidate.status == .rejected {
                return try canvasDecisionResult(
                    target: target,
                    snapshot: snapshot,
                    candidate: candidate,
                    operationID: request.opID,
                    idempotent: true,
                    committedToken: "canvas:\(snapshot.canvasRevision)")
            }
            throw G09R2Error(.designConflict, detail: "adoptionReplayMismatch")
        }
        guard candidate.status == .pending else {
            throw G09R2Error(.designConflict, detail: "candidateNotPending")
        }
        var restructureAuthorityRequest: DesignRestructureAuthorityRequest? = nil
        if candidate.workMode == .restructure {
            guard let digest = candidate.preservationDigest else {
                throw DesignOwnerWorkflowError.restructureRequiresTrustedConfirmation(
                    "the restructure candidate records no preservation digest")
            }
            let authorityRequest = DesignRestructureAuthorityRequest(
                targetKey: design.nodeID,
                operationID: request.opID,
                originalTaskOwnerID: candidate.originConversationID
                    ?? target.originConversationID,
                baseRevisionID: candidate.baseRevisionID,
                preservationDigest: digest)
            // Refuse a stale/wrong/expired claim before the payload read or
            // any asset/CAS write.
            try authority.preflight(
                authorityRequest, operationKind: .adopt)
            restructureAuthorityRequest = authorityRequest
        }
        guard let artifact = design.artifact(candidate.artifactID),
              let proposed = artifact.revision(candidate.proposedRevisionID) else {
            throw G09R2Error(.designPayloadMissing, detail: "proposedRevisionMissing")
        }
        guard artifact.contentType != .cad else {
            throw G09R2Error(
                .designTargetUnavailable, detail: "cadDesignReadOnly")
        }
        if request.mode == .updateOriginal,
           let current = artifact.currentRevisionID,
           current != candidate.baseRevisionID {
            throw G09R2Error(.designConflict, detail: "lateCandidate")
        }
        let bytes = try payloads.verifiedBytes(
            ownerKey: target.stableKey,
            revisionID: proposed.id,
            expectedContentSHA256: proposed.contentSHA256)
        let format = Self.normalizedFormat(proposed.payloadFormat ?? "bin")
        try G09R2DesignFormatVerifier.verify(
            bytes, format: format, contentType: artifact.contentType)
        // Burn the exact trusted-UI claim immediately before the first
        // asset/CAS side effect. Replays returned above never reach here.
        if let restructureAuthorityRequest {
            _ = try await authority.claim(
                restructureAuthorityRequest, operationKind: .adopt)
        }
        let asset: CanvasAssetReference?
        if request.mode == .updateOriginal {
            asset = try await prepareCanvasAsset(
                target: target,
                node: snapshot.node,
                bytes: bytes,
                format: format,
                revisionID: proposed.id,
                sha256: proposed.contentSHA256,
                operationID: request.opID)
        } else {
            asset = nil
        }
        do {
            let updated = try await canvasService.mutateProject(
                canvasID: canvasID, nodeID: nodeID,
                expectedRevision: request.expectedRevision,
                operationID: request.opID,
                contentType: artifact.contentType
            ) { project, design in
                _ = try DesignWorkflowEngine.adoptCandidate(
                    in: &design,
                    candidateID: request.candidateID,
                    mode: request.mode)
                if request.mode == .updateOriginal,
                   let location = Self.nodeLocation(nodeID, in: project) {
                    if Self.canCarryText(
                        project.documents[location.documentIndex]
                            .nodes[location.nodeIndex]) &&
                        Self.isTextFormat(format) {
                        project.documents[location.documentIndex]
                            .nodes[location.nodeIndex].text =
                            String(decoding: bytes, as: UTF8.self)
                    } else if let asset {
                        project.documents[location.documentIndex]
                            .nodes[location.nodeIndex].asset = asset
                        project.documents[location.documentIndex]
                            .nodes[location.nodeIndex]
                            .metadata["placeholder"] = nil
                    }
                }
            }
            guard let updatedDesign = updated.design,
                  let adopted = updatedDesign.candidate(request.candidateID) else {
                throw G09R2Error(.designConflict, detail: "adoptionNotRecorded")
            }
            return try canvasDecisionResult(
                target: target,
                snapshot: updated,
                candidate: adopted,
                operationID: request.opID,
                idempotent: false,
                committedToken: "canvas:\(updated.canvasRevision)")
        } catch {
            throw error
        }
    }

    private func canvasReject(
        _ target: DesignTarget,
        request: G09R2DesignRejectRequest
    ) async throws -> G09R2DesignDecisionReceiptDTO {
        let (canvasID, nodeID) = try Self.canvasIdentity(target)
        try requireCanvasSession(
            canvasID: canvasID, token: request.binding.sessionToken)
        let before = try await canvasService.snapshot(
            canvasID: canvasID, nodeID: nodeID)
        guard before.design?.contentType != .cad else {
            throw G09R2Error(
                .designTargetUnavailable, detail: "cadDesignReadOnly")
        }
        if before.design?.hasApplied(operationID: request.opID) == true,
           let candidate = before.design?.candidate(request.candidateID),
           candidate.status == .rejected {
            return G09R2DesignDecisionReceiptDTO(
                state: try canvasProjection(target, snapshot: before),
                candidateID: request.candidateID,
                operationID: request.opID,
                idempotent: true)
        }
        if let candidate = before.design?.candidate(request.candidateID),
           candidate.status != .pending {
            throw G09R2Error(.designConflict, detail: "candidateNotPending")
        }
        let updated = try await canvasService.mutate(
            canvasID: canvasID, nodeID: nodeID,
            expectedRevision: request.expectedRevision,
            operationID: request.opID,
            contentType: before.design?.contentType
        ) { design in
            try DesignWorkflowEngine.rejectCandidate(
                in: &design, candidateID: request.candidateID)
        }
        return G09R2DesignDecisionReceiptDTO(
            state: try canvasProjection(target, snapshot: updated),
            candidateID: request.candidateID,
            operationID: request.opID,
            idempotent: false)
    }

    private func canvasCompare(
        _ target: DesignTarget,
        request: G09R2DesignCompareRequest
    ) async throws -> G09R2DesignComparisonDTO {
        let (canvasID, nodeID) = try Self.canvasIdentity(target)
        try requireCanvasSession(
            canvasID: canvasID, token: request.binding.sessionToken)
        let snapshot = try await canvasService.snapshot(
            canvasID: canvasID, nodeID: nodeID)
        guard let design = snapshot.design,
              let candidate = design.candidate(request.candidateID),
              let artifact = design.artifact(candidate.artifactID),
              let base = artifact.revision(candidate.baseRevisionID),
              let proposed = artifact.revision(candidate.proposedRevisionID) else {
            throw G09R2Error(.candidateNotFound, detail: "candidateNotFound")
        }
        var diff: [String] = []
        var truncated = false
        var note: String?
        if base.contentSHA256 != proposed.contentSHA256,
           Self.isTextFormat(proposed.payloadFormat ?? "") {
            let baseBytes = try payloads.verifiedBytes(
                ownerKey: target.stableKey,
                revisionID: base.id,
                expectedContentSHA256: base.contentSHA256)
            let proposedBytes = try payloads.verifiedBytes(
                ownerKey: target.stableKey,
                revisionID: proposed.id,
                expectedContentSHA256: proposed.contentSHA256)
            let outcome = G09R2DesignDiff.diff(
                base: baseBytes, proposed: proposedBytes)
            diff = outcome.lines
            truncated = outcome.truncated
            note = outcome.note
        }
        return G09R2DesignComparisonDTO(
            candidateID: request.candidateID,
            baseSHA256: base.contentSHA256,
            proposedSHA256: proposed.contentSHA256,
            changed: base.contentSHA256 != proposed.contentSHA256,
            diff: diff,
            diffTruncated: truncated,
            diffNote: note,
            status: candidate.status)
    }

    private func canvasRestore(
        _ target: DesignTarget,
        request: G09R2DesignRestoreRequest
    ) async throws -> G09R2DesignStateDTO {
        let (canvasID, nodeID) = try Self.canvasIdentity(target)
        try requireCanvasSession(
            canvasID: canvasID, token: request.binding.sessionToken)
        let snapshot = try await canvasService.snapshot(
            canvasID: canvasID, nodeID: nodeID)
        guard let design = snapshot.design,
              let artifact = design.artifacts.first(where: {
                  $0.revision(request.revisionID) != nil
              }),
              let source = artifact.revision(request.revisionID) else {
            throw G09R2Error(.designPayloadMissing, detail: "revisionNotFound")
        }
        guard artifact.contentType != .cad else {
            throw G09R2Error(
                .designTargetUnavailable, detail: "cadDesignReadOnly")
        }
        if design.hasApplied(operationID: request.opID) {
            return try canvasProjection(target, snapshot: snapshot)
        }
        if snapshot.node?.isLocked == true {
            throw G09R2Error(.designConflict, detail: "canvasNodeLocked")
        }
        let bytes = try payloads.verifiedBytes(
            ownerKey: target.stableKey,
            revisionID: source.id,
            expectedContentSHA256: source.contentSHA256)
        let format = Self.normalizedFormat(source.payloadFormat ?? "bin")
        try G09R2DesignFormatVerifier.verify(
            bytes, format: format, contentType: artifact.contentType)
        let updatesNode = artifact.canvasNodeID == nodeID.uuidString.lowercased()
        let asset: CanvasAssetReference?
        if updatesNode {
            asset = try await prepareCanvasAsset(
                target: target,
                node: snapshot.node,
                bytes: bytes,
                format: format,
                revisionID: source.id,
                sha256: source.contentSHA256,
                operationID: request.opID)
        } else {
            asset = nil
        }
        let updated = try await canvasService.mutateProject(
            canvasID: canvasID, nodeID: nodeID,
            expectedRevision: request.expectedRevision,
            operationID: request.opID,
            contentType: artifact.contentType
        ) { project, design in
            _ = try DesignWorkflowEngine.restoreRevision(
                in: &design, artifactID: artifact.id,
                revisionID: request.revisionID)
            if updatesNode, let location = Self.nodeLocation(nodeID, in: project) {
                if Self.canCarryText(
                    project.documents[location.documentIndex]
                        .nodes[location.nodeIndex]) &&
                    Self.isTextFormat(format) {
                    project.documents[location.documentIndex]
                        .nodes[location.nodeIndex].text =
                        String(decoding: bytes, as: UTF8.self)
                } else if let asset {
                    project.documents[location.documentIndex]
                        .nodes[location.nodeIndex].asset = asset
                    project.documents[location.documentIndex]
                        .nodes[location.nodeIndex]
                        .metadata["placeholder"] = nil
                }
            }
        }
        return try canvasProjection(target, snapshot: updated)
    }

    private func canvasDecisionResult(
        target: DesignTarget,
        snapshot: DesignCanvasService.Snapshot,
        candidate: DesignCandidate,
        operationID: String,
        idempotent: Bool,
        committedToken: String?
    ) throws -> G09R2DesignDecisionResultDTO {
        G09R2DesignDecisionResultDTO(
            state: try canvasProjection(target, snapshot: snapshot),
            candidateID: candidate.id,
            operationID: operationID,
            idempotent: idempotent,
            committedRevisionToken: committedToken,
            delivery: target.originConversationID == nil
                ? G09R2DesignDeliveryDTO(state: .notRequired, reason: nil)
                : G09R2DesignDeliveryDTO(
                    state: .pending,
                    reason: "no canvas decision sink is configured"),
            publication: G09R2DesignPublicationDTO(
                state: .notRequired,
                identifier: nil,
                destination: nil,
                contentSHA256: nil,
                reason: nil))
    }

    // MARK: - Trusted restructure authority (host-only JNI / App callback)

    /// Prepare ONE trusted-UI restructure confirmation. This validates the
    /// LIVE target/base/candidate state and binds the user's preservation
    /// constraints to the exact shared-workflow request. It writes no design
    /// state and mints no grant; the App shows the returned display data and
    /// calls confirm only after the user explicitly confirms.
    public func prepareTrustedRestructure(
        _ input: G09R2DesignAuthorityPrepareInput
    ) async throws -> G09R2DesignTrustedConfirmationDTO {
        try requireOperation(input.opID)
        guard G09R2DesignRestructureAuthorityStore.isBounded(input.preservation),
              !input.preservation.isEmpty else {
            throw G09R2DesignAuthorityError.invalidConfirmation(
                "preservation constraints must be bounded and non-empty")
        }
        return try await perform(input.binding) { target in
            let prepared: (
                request: DesignRestructureAuthorityRequest,
                targetKey: String
            )
            switch target.kind {
            case .canvasNode:
                prepared = try await Self.prepareCanvasRestructure(
                    input: input, target: target,
                    canvasService: canvasService)
            case .fileDocument, .chatAttachment, .creativeDocument:
                prepared = try await prepareOwnerRestructure(
                    input: input, target: target)
            }
            let stored = try authority.prepare(
                request: prepared.request, constraints: input.preservation,
                operationKind: input.operationKind)
            return G09R2DesignTrustedConfirmationDTO(
                token: stored.token,
                targetKey: prepared.request.targetKey,
                operationID: prepared.request.operationID,
                originalTaskOwnerID: prepared.request.originalTaskOwnerID,
                baseRevisionID: prepared.request.baseRevisionID,
                preservationDigest: prepared.request.preservationDigest,
                preservation: input.preservation,
                expiresAt: stored.expiresAt)
        }
    }

    /// Test/App confirm entry. The privileged JNI confirm calls the same store
    /// under the live owner proof; this method is the actor-visible equivalent.
    public func confirmTrustedRestructure(token: String) -> Int32 {
        guard !stopping else { return G09R2DesignAuthorityStatus.retired }
        return authority.confirm(token: token)
    }

    @discardableResult
    public func revokeTrustedRestructure(token: String) -> Bool {
        authority.revoke(token: token)
    }

    private func prepareOwnerRestructure(
        input: G09R2DesignAuthorityPrepareInput,
        target: DesignTarget
    ) async throws -> (
        request: DesignRestructureAuthorityRequest, targetKey: String
    ) {
        guard let envelope = try await owners.state(target) else {
            throw G09R2Error(
                .designTargetUnavailable, detail: "designStateMissing")
        }
        let project = envelope.project
        let targetKey = project.nodeID
        let originalTask = envelope.target.originConversationID
            ?? target.originConversationID
        switch input.operationKind {
        case .freeze:
            // Freeze of a restructure intent before generation. Owner freeze
            // stamps the same project node; the shared owner path does not use
            // the authority request itself, so no base revision is implied.
            _ = try await targets.resolve(
                target.freezing(revision: nil))
            let request = DesignRestructureAuthorityRequest(
                targetKey: targetKey,
                operationID: input.opID,
                originalTaskOwnerID: originalTask,
                baseRevisionID: input.baseRevisionID,
                preservationDigest: input.preservation.canonicalDigest)
            return (request, targetKey)
        case .propose:
            guard let artifactID = input.artifactID,
                  let artifact = project.artifact(artifactID) else {
                throw G09R2Error(
                    .designPayloadMissing, detail: "artifactNotFound")
            }
            guard artifact.contentType != .cad else {
                throw G09R2Error(
                    .designTargetUnavailable, detail: "cadDesignReadOnly")
            }
            let base = input.baseRevisionID ?? artifact.currentRevisionID
            guard let base, artifact.revision(base) != nil else {
                throw G09R2Error(
                    .designPayloadMissing, detail: "baseRevisionNotFound")
            }
            let request = DesignRestructureAuthorityRequest(
                targetKey: targetKey,
                operationID: input.opID,
                originalTaskOwnerID: target.originConversationID,
                baseRevisionID: base,
                preservationDigest: input.preservation.canonicalDigest)
            return (request, targetKey)
        case .adopt:
            guard let candidateID = input.candidateID,
                  let candidate = project.candidate(candidateID) else {
                throw G09R2Error(.candidateNotFound, detail: "candidateNotFound")
            }
            guard candidate.status == .pending else {
                throw G09R2Error(.designConflict, detail: "candidateNotPending")
            }
            guard candidate.workMode == .restructure,
                  let digest = candidate.preservationDigest else {
                throw G09R2Error(
                    .designConflict,
                    detail: "restructureRequiresTrustedConfirmation")
            }
            guard digest.caseInsensitiveCompare(
                input.preservation.canonicalDigest) == .orderedSame else {
                throw DesignRestructureAuthorityError.claimMismatch(
                    "the proposed preservation constraints are not the recorded restructure digest")
            }
            let request = DesignRestructureAuthorityRequest(
                targetKey: targetKey,
                operationID: input.opID,
                originalTaskOwnerID: candidate.originConversationID
                    ?? target.originConversationID,
                baseRevisionID: candidate.baseRevisionID,
                preservationDigest: digest)
            return (request, targetKey)
        }
    }

    /// Canvas state lives in the existing Canvas CAS, not in the owner
    /// envelope. The confirmed request uses the Canvas design project node id,
    /// which is the exact `targetKey` the shared engine binds into its request.
    private static func prepareCanvasRestructure(
        input: G09R2DesignAuthorityPrepareInput,
        target: DesignTarget,
        canvasService: DesignCanvasService
    ) async throws -> (
        request: DesignRestructureAuthorityRequest, targetKey: String
    ) {
        let (canvasID, nodeID) = try canvasIdentity(target)
        let snapshot = try await canvasService.snapshot(
            canvasID: canvasID, nodeID: nodeID)
        let targetKey = snapshot.design?.nodeID
            ?? nodeID.uuidString.lowercased()
        switch input.operationKind {
        case .freeze:
            // The shared `freezeRun(workIntent:restructureReceipt:)` binds
            // `inputRevisionID` as the base. The App must pre-allocate and
            // show that exact id, otherwise a receipt can never match.
            guard let inputRevisionID = input.baseRevisionID,
                  G09R2DesignOwnerPayloadStore.isSafeToken(inputRevisionID) else {
                throw DesignRestructureAuthorityError.claimRequired(
                    "canvas restructure freeze requires an explicit inputRevisionID confirmed by the user")
            }
            let request = DesignRestructureAuthorityRequest(
                targetKey: targetKey,
                operationID: input.opID,
                originalTaskOwnerID: target.originConversationID,
                baseRevisionID: inputRevisionID,
                preservationDigest: input.preservation.canonicalDigest)
            return (request, targetKey)
        case .propose:
            guard let design = snapshot.design,
                  let artifactID = input.artifactID,
                  let artifact = design.artifact(artifactID) else {
                throw G09R2Error(
                    .designPayloadMissing, detail: "artifactNotFound")
            }
            guard artifact.contentType != .cad else {
                throw G09R2Error(
                    .designTargetUnavailable, detail: "cadDesignReadOnly")
            }
            let base = input.baseRevisionID ?? artifact.currentRevisionID
            guard let base, artifact.revision(base) != nil else {
                throw G09R2Error(
                    .designPayloadMissing, detail: "baseRevisionNotFound")
            }
            let request = DesignRestructureAuthorityRequest(
                targetKey: targetKey,
                operationID: input.opID,
                originalTaskOwnerID: target.originConversationID,
                baseRevisionID: base,
                preservationDigest: input.preservation.canonicalDigest)
            return (request, targetKey)
        case .adopt:
            guard let design = snapshot.design,
                  let candidateID = input.candidateID,
                  let candidate = design.candidate(candidateID) else {
                throw G09R2Error(.candidateNotFound, detail: "candidateNotFound")
            }
            guard candidate.status == .pending else {
                throw G09R2Error(.designConflict, detail: "candidateNotPending")
            }
            guard candidate.workMode == .restructure,
                  let digest = candidate.preservationDigest else {
                throw G09R2Error(
                    .designConflict,
                    detail: "restructureRequiresTrustedConfirmation")
            }
            guard digest.caseInsensitiveCompare(
                input.preservation.canonicalDigest) == .orderedSame else {
                throw DesignRestructureAuthorityError.claimMismatch(
                    "the proposed preservation constraints are not the recorded restructure digest")
            }
            let request = DesignRestructureAuthorityRequest(
                targetKey: targetKey,
                operationID: input.opID,
                originalTaskOwnerID: candidate.originConversationID
                    ?? target.originConversationID,
                baseRevisionID: candidate.baseRevisionID,
                preservationDigest: digest)
            return (request, targetKey)
        }
    }

    /// Build the typed restructure intent from the USER-confirmed record (not
    /// from bridge JSON). The shared workflow then revalidates the intent and
    /// the non-Codable receipt field-by-field.
    private func trustedRestructureIntent(
        targetKey: String,
        operationID: String,
        operationKind: G09R2DesignAuthorityOperationKind,
        baseRevisionID: String?,
        family: DesignContentType,
        desiredFormat: String,
        scope: DesignWorkScope?
    ) async throws -> (intent: DesignWorkIntent,
                       request: DesignRestructureAuthorityRequest) {
        guard let confirmed = authority.confirmedRecord(
            targetKey: targetKey, operationID: operationID,
            operationKind: operationKind) else {
            throw DesignRestructureAuthorityError.claimRequired(
                "restructure of \(targetKey) requires a trusted-UI confirmation for operation \(operationID)")
        }
        let request = confirmed.request
        guard request.baseRevisionID == baseRevisionID else {
            throw DesignRestructureAuthorityError.claimMismatch(
                "the confirmed base revision \(request.baseRevisionID ?? "nil") does not match the resolved base \(baseRevisionID ?? "nil")")
        }
        let intent = DesignWorkIntent(
            mode: .restructure,
            actualDesiredFormat: desiredFormat,
            scope: scope,
            preservation: confirmed.constraints,
            frozenRevisionID: baseRevisionID,
            originalTaskOwnerID: request.originalTaskOwnerID,
            confirmation: DesignPreservationConfirmation(
                constraints: confirmed.constraints,
                confirmedAt: confirmed.confirmedAt),
            operationID: operationID)
        return (try intent.validated(family: family), request)
    }

    private func claimAuthorization(
        for request: DesignRestructureAuthorityRequest,
        operationKind: G09R2DesignAuthorityOperationKind
    ) -> DesignRestructureAuthorityHandler {
        let store = authority
        return { exact in
            guard exact == request else {
                throw DesignRestructureAuthorityError.claimMismatch(
                    "the effect-time restructure request does not bind the confirmed claim")
            }
            return try await store.claim(
                exact, operationKind: operationKind)
        }
    }

    private func adoptClaimAuthorization(
        for request: DesignRestructureAuthorityRequest
    ) -> @Sendable () async throws -> Void {
        let store = authority
        return {
            _ = try await store.claim(request, operationKind: .adopt)
        }
    }

    // MARK: - Owner freeze / propose / adopt

    private func ownerFreeze(
        _ target: DesignTarget,
        request: G09R2DesignFreezeRequest,
        runID: UUID?
    ) async throws -> G09R2DesignFreezeReceiptDTO {
        let before = try await owners.state(target, runID: runID)
        if before?.project.hasApplied(operationID: request.opID) == true,
           let frozen = before?.project.frozenRun {
            // Exact replay never burns a second trusted claim and never
            // rewrites the frozen run.
            return G09R2DesignFreezeReceiptDTO(
                target: target,
                ownerRevision: before?.revision ?? 0,
                frozenRun: frozen,
                idempotent: true)
        }
        let targetKey = before?.project.nodeID ?? target.stableKey
        var trustedRequest: DesignRestructureAuthorityRequest?
        if request.workMode == .restructure {
            guard let confirmed = authority.confirmedRecord(
                targetKey: targetKey, operationID: request.opID,
                operationKind: .freeze) else {
                throw DesignRestructureAuthorityError.claimRequired(
                    "restructure freeze requires a trusted-UI confirmation for operation \(request.opID)")
            }
            if let digest = request.preservationDigest,
               digest.caseInsensitiveCompare(
                confirmed.request.preservationDigest) != .orderedSame {
                throw DesignRestructureAuthorityError.claimMismatch(
                    "the requested preservation digest is not the confirmed restructure digest")
            }
            try authority.preflight(
                confirmed.request, operationKind: .freeze)
            trustedRequest = confirmed.request
        }
        let resolved = try await targets.resolve(
            target.freezing(revision: nil), runID: runID)
        let workIntent: DesignWorkIntent?
        if let trustedRequest {
            guard let confirmed = authority.confirmedRecord(
                targetKey: targetKey, operationID: request.opID,
                operationKind: .freeze) else {
                throw DesignRestructureAuthorityError.claimRequired(
                    "the trusted-UI restructure confirmation disappeared")
            }
            workIntent = try DesignWorkIntent(
                mode: .restructure,
                actualDesiredFormat: request.desiredFormat ?? resolved.format,
                preservation: confirmed.constraints,
                frozenRevisionID: trustedRequest.baseRevisionID,
                originalTaskOwnerID: trustedRequest.originalTaskOwnerID,
                confirmation: DesignPreservationConfirmation(
                    constraints: confirmed.constraints,
                    confirmedAt: confirmed.confirmedAt),
                operationID: request.opID
            ).validated(family: resolved.contentType)
            // Burn immediately before the first freeze payload/CAS write.
            _ = try await authority.claim(
                trustedRequest, operationKind: .freeze)
        } else {
            workIntent = try Self.freezeIntent(
                request: request, family: resolved.contentType,
                format: resolved.format, revisionID: nil)
        }
        let (envelope, _, _) = try await owners.freezeInput(
            target: target,
            operationID: request.opID,
            expectedOwnerRevision: request.expectedRevision,
            artifactID: nil,
            displayName: nil,
            runID: runID)
        let stamped = try await stampFrozenRun(
            envelope: envelope,
            request: request,
            workIntent: workIntent)
        guard let frozen = stamped.project.frozenRun else {
            throw G09R2Error(.designConflict, detail: "freezeMissingRun")
        }
        return G09R2DesignFreezeReceiptDTO(
            target: target,
            ownerRevision: stamped.revision,
            frozenRun: frozen,
            idempotent: false)
    }

    private func stampFrozenRun(
        envelope: DesignOwnerEnvelope,
        request: G09R2DesignFreezeRequest,
        workIntent: DesignWorkIntent?
    ) async throws -> DesignOwnerEnvelope {
        guard request.desiredFormat != nil ||
                request.workMode != nil ||
                request.preservationDigest != nil ||
                request.specSHA256 != nil else {
            return envelope
        }
        guard var current = try await ownerStore.load(
            targetKey: envelope.target.stableKey),
              current.project.frozenRun != nil else {
            throw G09R2Error(.designConflict, detail: "ownerEnvelopeMissing")
        }
        let desiredFormat = workIntent?.actualDesiredFormat ?? request.desiredFormat
        let preservationDigest = workIntent?.mode == .restructure
            ? workIntent?.preservation?.canonicalDigest
            : request.preservationDigest
        let specMatches = request.specSHA256.map {
            current.project.frozenRun?.specSHA256 == $0
        } ?? true
        if current.project.frozenRun?.desiredFormat == desiredFormat,
           current.project.frozenRun?.workMode == workIntent?.mode,
           specMatches,
           current.project.frozenRun?.preservationDigest == preservationDigest {
            return current
        }
        current.project.frozenRun?.desiredFormat = desiredFormat
        current.project.frozenRun?.workMode = workIntent?.mode
        if let specSHA256 = request.specSHA256 {
            current.project.frozenRun?.specSHA256 = specSHA256
        }
        current.project.frozenRun?.preservationDigest = preservationDigest
        let revision = try await ownerStore.save(
            current,
            targetKey: envelope.target.stableKey,
            expectedRevision: current.revision)
        current.revision = revision
        return current
    }

    private func ownerPropose(
        _ target: DesignTarget,
        request: G09R2DesignProposeRequest,
        runID: UUID?
    ) async throws -> G09R2DesignProposalResultDTO {
        guard let envelope = try await owners.state(target, runID: runID) else {
            throw G09R2Error(.designTargetUnavailable, detail: "freezeInputFirst")
        }
        if let recorded = envelope.project.candidates.first(where: {
            $0.proposalOperationID == request.opID
        }) {
            guard let artifact = envelope.project.artifact(recorded.artifactID),
                  let revision = artifact.revision(recorded.proposedRevisionID),
                  revision.contentSHA256.caseInsensitiveCompare(
                    request.payload.sha256) == .orderedSame,
                  recorded.artifactID == request.artifactID,
                  recorded.summary == request.summary,
                  recorded.diff == request.diff,
                  recorded.feedbackIDs == request.feedbackIDs,
                  recorded.workMode == request.workIntent?.mode,
                  request.baseRevisionID.map({ $0 == recorded.baseRevisionID }) ?? true,
                  revision.payloadFormat.map({
                      Self.normalizedFormat($0) == Self.normalizedFormat(request.payload.format)
                  }) ?? true else {
                throw G09R2Error(.designConflict, detail: "proposalReplayMismatch")
            }
            let relative = revision.payloadRelativePath ?? ""
            await discardStagedPayload(request.payload.token)
            return G09R2DesignProposalResultDTO(
                state: ownerProjection(target, envelope: envelope),
                candidate: recorded,
                payloadRelativePath: relative,
                replayed: true)
        }
        guard let artifact = envelope.project.artifact(request.artifactID) else {
            throw G09R2Error(.designPayloadMissing, detail: "artifactNotFound")
        }
        let base = request.baseRevisionID ?? artifact.currentRevisionID
        guard let base, artifact.revision(base) != nil else {
            throw G09R2Error(.designPayloadMissing, detail: "baseRevisionNotFound")
        }
        guard artifact.contentType != .cad else {
            throw G09R2Error(
                .designTargetUnavailable, detail: "cadDesignReadOnly")
        }
        let family = try Self.requiredContentType(request.payload.format)
        guard family == artifact.contentType else {
            throw G09R2Error(
                .renderUnsupported, detail: "payloadFormatFamilyMismatch")
        }
        let desiredFormat = request.workIntent?.actualDesiredFormat
            ?? request.payload.format
        var workIntent: DesignWorkIntent? = nil
        var restructureAuthority: DesignRestructureAuthorityHandler? = nil
        if request.workIntent?.mode == .restructure {
            let trusted = try await trustedRestructureIntent(
                targetKey: envelope.project.nodeID,
                operationID: request.opID,
                operationKind: .propose,
                baseRevisionID: base,
                family: artifact.contentType,
                desiredFormat: desiredFormat,
                scope: request.workIntent?.scope)
            // Refuse a missing/stale/wrong-target claim BEFORE reading or
            // staging any payload bytes. The handler below burns the exact
            // claim immediately before the shared workflow stages bytes.
            try authority.preflight(
                trusted.request, operationKind: .propose)
            workIntent = trusted.intent
            restructureAuthority = claimAuthorization(
                for: trusted.request, operationKind: .propose)
        } else {
            workIntent = try Self.proposalIntent(
                request: request, family: artifact.contentType, base: base)
        }
        let bytes = try readStagedPayload(
            request.payload, sessionToken: request.binding.sessionToken)
        let proposal = try await owners.propose(
            target: target,
            operationID: request.opID,
            expectedOwnerRevision: request.expectedRevision,
            artifactID: request.artifactID,
            baseRevisionID: base,
            bytes: bytes,
            format: request.payload.format,
            summary: request.summary,
            diff: request.diff,
            feedbackIDs: request.feedbackIDs,
            runID: runID,
            workIntent: workIntent,
            restructureAuthority: restructureAuthority)
        await discardStagedPayload(request.payload.token)
        return G09R2DesignProposalResultDTO(
            state: ownerProjection(target, envelope: proposal.envelope),
            candidate: proposal.candidate,
            payloadRelativePath: proposal.payloadRelativePath,
            replayed: proposal.replayed)
    }

    private func ownerAdopt(
        _ target: DesignTarget,
        request: G09R2DesignAdoptRequest,
        runID: UUID?
    ) async throws -> G09R2DesignDecisionResultDTO {
        let envelope = try await owners.state(target, runID: runID)
        let candidate = envelope?.project.candidate(request.candidateID)
        let replayed = envelope?.project.hasApplied(
            operationID: request.opID) ?? false
        var claimAuthorization: (@Sendable () async throws -> Void)? = nil
        if !replayed, candidate?.workMode == .restructure {
            guard let envelope, let candidate,
                  let digest = candidate.preservationDigest else {
                throw DesignOwnerWorkflowError.restructureRequiresTrustedConfirmation(
                    "the restructure candidate records no preservation digest")
            }
            let authorityRequest = DesignRestructureAuthorityRequest(
                targetKey: envelope.project.nodeID,
                operationID: request.opID,
                originalTaskOwnerID: candidate.originConversationID
                    ?? target.originConversationID,
                baseRevisionID: candidate.baseRevisionID,
                preservationDigest: digest)
            // Refuse a stale/wrong/expired claim before payload read/reopen.
            try authority.preflight(
                authorityRequest, operationKind: .adopt)
            claimAuthorization = adoptClaimAuthorization(
                for: authorityRequest)
        }
        let result = try await owners.adopt(
            target: target,
            operationID: request.opID,
            expectedOwnerRevision: request.expectedRevision,
            candidateID: request.candidateID,
            mode: request.mode,
            runID: runID,
            claimAuthorization: claimAuthorization,
            verifyReopen: { bytes, format, contentType in
                try G09R2DesignFormatVerifier.verify(
                    bytes, format: format, contentType: contentType)
            },
            sink: nil,
            publication: nil)
        return G09R2DesignDecisionResultDTO(
            state: ownerProjection(target, envelope: result.envelope),
            candidateID: request.candidateID,
            operationID: request.opID,
            idempotent: result.replayed,
            committedRevisionToken: result.committedRevisionToken,
            delivery: Self.deliveryDTO(result.delivery),
            publication: Self.publicationDTO(result.publication))
    }

    // MARK: - Preview / export

    private func canvasPreview(
        _ target: DesignTarget,
        request: G09R2DesignPreviewRequest,
        limit: Int
    ) async throws -> G09R2DesignPreviewReceiptDTO {
        let (canvasID, nodeID) = try Self.canvasIdentity(target)
        try requireCanvasSession(
            canvasID: canvasID, token: request.binding.sessionToken)
        let snapshot = try await canvasService.snapshot(
            canvasID: canvasID, nodeID: nodeID)
        if request.candidateID == nil, request.revisionID == nil {
            guard let design = snapshot.design else {
                throw G09R2Error(.designPayloadMissing, detail: "noDesignSnapshot")
            }
            let document = try await canvas.project(canvasID: canvasID)
            let verified = await canvasSnapshotAssets(document: document)
            let bytes = try Self.canvasSnapshotData(
                canvasID: canvasID,
                snapshot: snapshot,
                design: design,
                document: document,
                assets: verified.assets,
                assetsTruncated: verified.truncated,
                maxBytes: min(
                    limit,
                    G09R2DesignCanvasSnapshot.maximumPreviewBytes),
                tooLarge: G09R2Error(
                    .designPreviewTooLarge,
                    detail: "canvasSnapshotTooLarge"))
            let receipt = try artifacts.writePreview(
                targetKey: target.stableKey,
                revisionKey: "canvas-\(snapshot.canvasRevision)",
                bytes: bytes,
                format: "canvas.snapshot",
                maxBytes: limit)
            return G09R2DesignPreviewReceiptDTO(
                target: target,
                ownerRevision: snapshot.canvasRevision,
                candidateID: nil,
                revisionID: nil,
                format: receipt.format,
                rootPath: receipt.rootPath,
                relativePath: receipt.relativePath,
                byteCount: receipt.byteCount,
                sha256: receipt.sha256,
                width: nil,
                height: nil,
                createdAt: Date())
        }
        let selected = try selectedCanvasRevision(
            target: target,
            design: snapshot.design,
            candidateID: request.candidateID,
            revisionID: request.revisionID)
        let format = Self.normalizedFormat(
            selected.revision.payloadFormat ?? "bin")
        try G09R2DesignFormatVerifier.verify(
            selected.bytes, format: format,
            contentType: selected.artifact.contentType)
        guard selected.bytes.count <= limit else {
            throw G09R2Error(.designPreviewTooLarge, detail: "revisionPreviewTooLarge")
        }
        let receipt = try artifacts.writePreview(
            targetKey: target.stableKey,
            revisionKey: selected.revision.id,
            bytes: selected.bytes,
            format: format,
            maxBytes: limit)
        return G09R2DesignPreviewReceiptDTO(
            target: target,
            ownerRevision: snapshot.canvasRevision,
            candidateID: request.candidateID,
            revisionID: selected.revision.id,
            format: receipt.format,
            rootPath: receipt.rootPath,
            relativePath: receipt.relativePath,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            width: nil,
            height: nil,
            createdAt: Date())
    }

    private func canvasExport(
        _ target: DesignTarget,
        request: G09R2DesignExportRequest,
        format: String
    ) async throws -> G09R2DesignExportReceiptDTO {
        let (canvasID, nodeID) = try Self.canvasIdentity(target)
        try requireCanvasSession(
            canvasID: canvasID, token: request.binding.sessionToken)
        let snapshot = try await canvasService.snapshot(
            canvasID: canvasID, nodeID: nodeID)
        if request.candidateID == nil, request.revisionID == nil {
            guard format == "canvas.snapshot" else {
                throw G09R2Error(
                    .renderUnsupported, detail: "only canvas.snapshot is available without a revision")
            }
            guard let design = snapshot.design else {
                throw G09R2Error(.designPayloadMissing, detail: "noDesignSnapshot")
            }
            let document = try await canvas.project(canvasID: canvasID)
            let verified = await canvasSnapshotAssets(document: document)
            let bytes = try Self.canvasSnapshotData(
                canvasID: canvasID, snapshot: snapshot, design: design,
                document: document,
                assets: verified.assets,
                assetsTruncated: verified.truncated,
                maxBytes: Int(G09R2CreativeLimits.canvasProjectBytes),
                tooLarge: G09R2Error(
                    .designPayloadTooLarge,
                    detail: "canvasSnapshotTooLarge"))
            let receipt = try artifacts.writeExport(
                targetKey: target.stableKey,
                revisionKey: "canvas-\(snapshot.canvasRevision)",
                bytes: bytes,
                format: "canvas.snapshot",
                suggestedFileName: request.suggestedFileName)
            return G09R2DesignExportReceiptDTO(
                target: target,
                ownerRevision: snapshot.canvasRevision,
                candidateID: nil,
                revisionID: nil,
                format: receipt.format,
                rootPath: receipt.rootPath,
                relativePath: receipt.relativePath,
                byteCount: receipt.byteCount,
                sha256: receipt.sha256,
                createdAt: Date())
        }
        let selected = try selectedCanvasRevision(
            target: target,
            design: snapshot.design,
            candidateID: request.candidateID,
            revisionID: request.revisionID)
        let actual = Self.normalizedFormat(
            selected.revision.payloadFormat ?? "bin")
        guard Self.formatsEquivalent(format, actual) else {
            throw G09R2Error(
                .renderUnsupported, detail: "requestedFormatDiffersFromSource")
        }
        try G09R2DesignFormatVerifier.verify(
            selected.bytes, format: actual,
            contentType: selected.artifact.contentType)
        let receipt = try artifacts.writeExport(
            targetKey: target.stableKey,
            revisionKey: selected.revision.id,
            bytes: selected.bytes,
            format: actual,
            suggestedFileName: request.suggestedFileName)
        return G09R2DesignExportReceiptDTO(
            target: target,
            ownerRevision: snapshot.canvasRevision,
            candidateID: request.candidateID,
            revisionID: selected.revision.id,
            format: receipt.format,
            rootPath: receipt.rootPath,
            relativePath: receipt.relativePath,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            createdAt: Date())
    }

    private func ownerPreview(
        _ target: DesignTarget,
        request: G09R2DesignPreviewRequest,
        limit: Int,
        runID: UUID?
    ) async throws -> G09R2DesignPreviewReceiptDTO {
        guard let envelope = try await owners.state(target, runID: runID) else {
            throw G09R2Error(.designPayloadMissing, detail: "noDesignState")
        }
        let selected = try selectedOwnerRevision(
            target: target,
            envelope: envelope,
            candidateID: request.candidateID,
            revisionID: request.revisionID)
        let actual = Self.normalizedFormat(
            selected.revision.payloadFormat ?? "bin")
        try G09R2DesignFormatVerifier.verify(
            selected.bytes, format: actual,
            contentType: selected.artifact.contentType)
        guard selected.bytes.count <= limit else {
            throw G09R2Error(.designPreviewTooLarge, detail: "revisionPreviewTooLarge")
        }
        let receipt = try artifacts.writePreview(
            targetKey: target.stableKey,
            revisionKey: selected.revision.id,
            bytes: selected.bytes,
            format: actual,
            maxBytes: limit)
        return G09R2DesignPreviewReceiptDTO(
            target: target,
            ownerRevision: envelope.revision,
            candidateID: request.candidateID,
            revisionID: selected.revision.id,
            format: receipt.format,
            rootPath: receipt.rootPath,
            relativePath: receipt.relativePath,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            width: nil,
            height: nil,
            createdAt: Date())
    }

    private func ownerExport(
        _ target: DesignTarget,
        request: G09R2DesignExportRequest,
        format: String,
        runID: UUID?
    ) async throws -> G09R2DesignExportReceiptDTO {
        guard let envelope = try await owners.state(target, runID: runID) else {
            throw G09R2Error(.designPayloadMissing, detail: "noDesignState")
        }
        let selected = try selectedOwnerRevision(
            target: target,
            envelope: envelope,
            candidateID: request.candidateID,
            revisionID: request.revisionID)
        let actual = Self.normalizedFormat(
            selected.revision.payloadFormat ?? "bin")
        guard Self.formatsEquivalent(format, actual) else {
            throw G09R2Error(
                .renderUnsupported, detail: "requestedFormatDiffersFromSource")
        }
        try G09R2DesignFormatVerifier.verify(
            selected.bytes, format: actual,
            contentType: selected.artifact.contentType)
        let receipt = try artifacts.writeExport(
            targetKey: target.stableKey,
            revisionKey: selected.revision.id,
            bytes: selected.bytes,
            format: actual,
            suggestedFileName: request.suggestedFileName)
        return G09R2DesignExportReceiptDTO(
            target: target,
            ownerRevision: envelope.revision,
            candidateID: request.candidateID,
            revisionID: selected.revision.id,
            format: receipt.format,
            rootPath: receipt.rootPath,
            relativePath: receipt.relativePath,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            createdAt: Date())
    }

    // MARK: - Selection helpers

    private struct SelectedRevision {
        let artifact: DesignArtifact
        let revision: DesignRevision
        let bytes: Data
    }

    private func selectedCanvasRevision(
        target: DesignTarget,
        design: DesignProject?,
        candidateID: String?,
        revisionID: String?
    ) throws -> SelectedRevision {
        guard let design else {
            throw G09R2Error(.designPayloadMissing, detail: "noDesignState")
        }
        let artifact: DesignArtifact
        let revision: DesignRevision
        if let candidateID {
            guard let candidate = design.candidate(candidateID),
                  let value = design.artifact(candidate.artifactID),
                  let proposed = value.revision(candidate.proposedRevisionID) else {
                throw G09R2Error(.candidateNotFound, detail: "candidateNotFound")
            }
            artifact = value
            revision = proposed
        } else if let revisionID {
            guard let value = design.artifacts.first(where: {
                $0.revision(revisionID) != nil
            }), let found = value.revision(revisionID) else {
                throw G09R2Error(.designPayloadMissing, detail: "revisionNotFound")
            }
            artifact = value
            revision = found
        } else {
            guard let value = design.artifacts.first(where: {
                $0.currentRevision != nil
            }), let current = value.currentRevision else {
                throw G09R2Error(.designPayloadMissing, detail: "noCurrentRevision")
            }
            artifact = value
            revision = current
        }
        let bytes = try payloads.verifiedBytes(
            ownerKey: target.stableKey,
            revisionID: revision.id,
            expectedContentSHA256: revision.contentSHA256)
        return SelectedRevision(
            artifact: artifact, revision: revision, bytes: bytes)
    }

    private func selectedOwnerRevision(
        target: DesignTarget,
        envelope: DesignOwnerEnvelope,
        candidateID: String?,
        revisionID: String?
    ) throws -> SelectedRevision {
        let artifact: DesignArtifact
        let revision: DesignRevision
        if let candidateID {
            guard let candidate = envelope.project.candidate(candidateID),
                  let value = envelope.project.artifact(candidate.artifactID),
                  let proposed = value.revision(candidate.proposedRevisionID) else {
                throw G09R2Error(.candidateNotFound, detail: "candidateNotFound")
            }
            artifact = value
            revision = proposed
        } else if let revisionID {
            guard let value = envelope.project.artifacts.first(where: {
                $0.revision(revisionID) != nil
            }), let found = value.revision(revisionID) else {
                throw G09R2Error(.designPayloadMissing, detail: "revisionNotFound")
            }
            artifact = value
            revision = found
        } else {
            guard let value = envelope.project.artifacts.first(where: {
                $0.currentRevision != nil
            }), let current = value.currentRevision else {
                throw G09R2Error(.designPayloadMissing, detail: "noCurrentRevision")
            }
            artifact = value
            revision = current
        }
        let bytes = try payloads.verifiedBytes(
            ownerKey: target.stableKey,
            revisionID: revision.id,
            expectedContentSHA256: revision.contentSHA256)
        return SelectedRevision(
            artifact: artifact, revision: revision, bytes: bytes)
    }

    // MARK: - Staged payload / Canvas asset

    private func readStagedPayload(
        _ payload: G09R2StagedDesignPayloadDTO,
        sessionToken: String
    ) throws -> Data {
        let token = payload.token
        guard token.hasPrefix(sessionToken + "."),
              G09CreativeAssetHost.safeStagingToken(token),
              let url = assets.incomingURL(token: token),
              FileManager.default.fileExists(atPath: url.path) else {
            throw G09R2Error(.designPayloadMissing, detail: "stagedPayloadMissing")
        }
        let data: Data
        do {
            data = try G09R2DesignFileIO.readBounded(
                url, maxBytes: Int(G09R2CreativeLimits.designSourceBytes))
        } catch let storeError as G09R2DesignStoreError {
            if case .tooLarge = storeError {
                throw G09R2Error(
                    .designPayloadTooLarge, detail: "stagedPayloadTooLarge")
            }
            throw G09R2Error(
                .designPayloadMissing, detail: "stagedPayloadUnreadable")
        } catch {
            throw G09R2Error(
                .designPayloadMissing, detail: "stagedPayloadUnreadable")
        }
        guard !data.isEmpty,
              Int64(data.count) <= G09R2CreativeLimits.designSourceBytes else {
            throw G09R2Error(.designPayloadTooLarge, detail: "stagedPayloadTooLarge")
        }
        guard payload.byteCount > 0,
              payload.byteCount == Int64(data.count) else {
            throw G09R2Error(.designPayloadMissing, detail: "stagedSizeMismatch")
        }
        let digest = FloeDigest.sha256Hex(data)
        guard digest.caseInsensitiveCompare(payload.sha256) == .orderedSame else {
            throw G09R2Error(.designPayloadMissing, detail: "stagedHashMismatch")
        }
        guard !Self.normalizedFormat(payload.format).isEmpty else {
            throw G09R2Error(.designPayloadMissing, detail: "stagedFormatMismatch")
        }
        return data
    }

    private func discardStagedPayload(_ token: String) async {
        await assets.discardIfPresent(token: token)
    }

    /// Ingest an adopted/restored Canvas result into the existing
    /// `CreativeAssetStore`, then increment its reference. Over-retaining an
    /// asset when the later Canvas CAS fails is deliberate: deferred physical
    /// reclamation preserves the user's bytes and never under-counts a live
    /// node.
    private func prepareCanvasAsset(
        target: DesignTarget,
        node: CanvasNode?,
        bytes: Data,
        format: String,
        revisionID: String,
        sha256: String,
        operationID: String
    ) async throws -> CanvasAssetReference? {
        guard let node else {
            throw G09R2Error(.designTargetUnavailable, detail: "canvasNodeMissing")
        }
        if Self.canCarryText(node) && Self.isTextFormat(format) {
            return nil
        }
        guard Self.isAssetNode(node), Self.isAssetFormat(format) else {
            throw G09R2Error(
                .renderUnsupported,
                detail: "canvasNodeCannotCarryResultFormat")
        }
        if node.kind == .image, !Self.isImageFormat(format) {
            throw G09R2Error(
                .renderUnsupported,
                detail: "imageNodeRequiresImageFormat")
        }
        guard let staging = payloads.payloadURL(
            ownerKey: target.stableKey, revisionID: revisionID) else {
            throw G09R2Error(.designPayloadMissing, detail: "adoptedPayloadMissing")
        }
        let extensionValue = G09R2DesignArtifactStore.fileExtension(for: format)
        let fileName = "design-\(revisionID).\(extensionValue)"
        let reference = try await assets.ingestForSourceCreate(
            staging: staging,
            fileName: fileName,
            mimeType: G09R2DesignWorkspaceResolver.mimeType(for: format),
            byteCount: Int64(bytes.count),
            sha256: sha256,
            candidateID: UUID())
        try await assets.applyReferenceOp(
            opID: "design-canvas-ref-\(operationID)",
            assetID: reference.id,
            delta: 1)
        return reference
    }

    // MARK: - Operation / validation / sessions

    private func perform<T>(
        _ binding: G09R2DesignBindingDTO,
        _ body: (DesignTarget) async throws -> T
    ) async throws -> T {
        let target: DesignTarget
        do {
            target = try validate(binding)
        } catch {
            throw Self.map(error)
        }
        guard !stopping else {
            throw G09CreativeError.staleGeneration
        }
        activeOperations += 1
        await acquireTarget(target.stableKey)
        defer {
            releaseTarget(target.stableKey)
            activeOperations = max(0, activeOperations - 1)
        }
        guard !stopping else {
            throw G09CreativeError.staleGeneration
        }
        do {
            return try await body(target)
        } catch {
            throw Self.map(error)
        }
    }

    /// Read-only service operation (bounded inventory/pending pages). It is
    /// counted by the SAME Root-stop operation counter, so `requestRootStop`
    /// cannot report drained while a page is still reading. It holds no target
    /// reservation because it never mutates an owner.
    private func performRead<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        guard !stopping else {
            throw G09CreativeError.staleGeneration
        }
        activeOperations += 1
        defer { activeOperations = max(0, activeOperations - 1) }
        guard !stopping else {
            throw G09CreativeError.staleGeneration
        }
        do {
            return try await body()
        } catch {
            throw Self.map(error)
        }
    }

    private func acquireTarget(_ key: String) async {
        while busyTargets.contains(key) {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                targetWaiters[key, default: []].append(continuation)
            }
        }
        busyTargets.insert(key)
    }

    private func releaseTarget(_ key: String) {
        busyTargets.remove(key)
        let waiters = targetWaiters.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func validate(_ binding: G09R2DesignBindingDTO) throws -> DesignTarget {
        guard G09CreativeWire.validSessionToken(binding.sessionToken) else {
            throw G09CreativeError.invalidPayload("invalidSessionToken")
        }
        let target = binding.target
        if target.requestedOutputKind != nil,
           target.kind != .creativeDocument {
            throw G09R2Error(
                .designTargetUnavailable,
                detail: "requestedOutputKindOnlyForCreative")
        }
        switch target.kind {
        case .canvasNode:
            guard binding.storage.kind == .appOwned,
                  binding.storage.workspaceID == nil else {
                throw G09R2Error(
                    .designTargetUnavailable, detail: "canvasStorageMustBeAppOwned")
            }
            _ = try DesignTargetValidation.uuid(target.ownerID, field: "ownerID")
            _ = try DesignTargetValidation.uuid(target.sourceID, field: "sourceID")
            if !target.documentID.isEmpty {
                _ = try DesignTargetValidation.uuid(
                    target.documentID, field: "documentID")
            }
        case .fileDocument:
            guard binding.storage.kind == .workspace,
                  let workspaceID = binding.storage.workspaceID,
                  workspaceID.uuidString.caseInsensitiveCompare(
                    target.ownerID) == .orderedSame else {
                throw G09R2Error(
                    .designTargetUnavailable,
                    detail: "fileStorageMustNameItsExactWorkspace")
            }
            _ = try DesignTargetValidation.relativeReference(target.sourceID)
        case .chatAttachment:
            guard binding.storage.kind == .appOwned,
                  binding.storage.workspaceID == nil else {
                throw G09R2Error(
                    .designTargetUnavailable, detail: "chatStorageMustBeAppOwned")
            }
            _ = try DesignTargetValidation.uuid(target.ownerID, field: "ownerID")
            _ = try DesignTargetValidation.uuid(target.sourceID, field: "sourceID")
            if !target.documentID.isEmpty {
                _ = try DesignTargetValidation.uuid(
                    target.documentID, field: "documentID")
            }
        case .creativeDocument:
            guard binding.storage.kind == .appOwned,
                  binding.storage.workspaceID == nil else {
                throw G09R2Error(
                    .designTargetUnavailable,
                    detail: "creativeStorageMustBeAppOwned")
            }
            // The owner is the stable creative-library surface or the run's
            // own task identity. It is an opaque bounded token, never a path.
            _ = try DesignTargetValidation.relativeReference(target.ownerID)
            guard target.documentID.isEmpty else {
                throw G09R2Error(
                    .designTargetUnavailable,
                    detail: "creativeDocumentHasNoDocumentLayer")
            }
            _ = try DesignTargetValidation.uuid(
                target.sourceID, field: "sourceID")
        }
        return target
    }

    private func requireCanvasSession(canvasID: UUID, token: String) throws {
        guard let session = canvasSessions[canvasID],
              session.token == token else {
            throw G09CreativeError.sessionRequired
        }
    }

    private func registerCanvasSession(canvasID: UUID, token: String) {
        canvasSessions[canvasID] = CanvasSession(
            token: token, registeredAt: Date())
        canvasSessionOrder.removeAll { $0 == canvasID }
        canvasSessionOrder.append(canvasID)
        while canvasSessionOrder.count > 16, let oldest = canvasSessionOrder.first {
            canvasSessions.removeValue(forKey: oldest)
            canvasSessionOrder.removeFirst()
        }
    }

    /// A creative target may only be driven without a run identity by the
    /// EXACT editor session that bound the target. This is the trusted-UI
    /// provenance: a bridge/model request cannot simply omit a runID and be
    /// treated as the in-app user. Native model tools must pass their
    /// verified runID and are authorized by the durable owner port instead.
    private func requireCreativeSession(targetKey: String, token: String) throws {
        guard let registered = creativeSessions[targetKey],
              registered == token else {
            throw G09CreativeError.sessionRequired
        }
    }

    private func registerCreativeSession(targetKey: String, token: String) {
        creativeSessions[targetKey] = token
        creativeSessionOrder.removeAll { $0 == targetKey }
        creativeSessionOrder.append(targetKey)
        while creativeSessionOrder.count > 16,
              let oldest = creativeSessionOrder.first {
            creativeSessions.removeValue(forKey: oldest)
            creativeSessionOrder.removeFirst()
        }
    }

    /// `runID` and `trustedUI` are mutually exclusive. Only the host bridge
    /// passes `trustedUI`, and only after `bind` registered the exact editor
    /// session; the ordinary bridge/model payload never carries this flag.
    private func validateCreativeCallOrigin(
        target: DesignTarget,
        binding: G09R2DesignBindingDTO,
        runID: UUID?,
        trustedUI: Bool
    ) throws {
        guard target.kind == .creativeDocument else { return }
        if runID != nil {
            guard !trustedUI else {
                throw G09CreativeError.invalidPayload(
                    "ambiguousDesignCallOrigin")
            }
            return
        }
        guard trustedUI else {
            throw G09CreativeError.sessionRequired
        }
        try requireCreativeSession(
            targetKey: target.stableKey, token: binding.sessionToken)
    }

    private func requireOperation(_ raw: String) throws {
        guard G09CreativeWire.safeOperationID(raw) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
    }

    private func requireRevision(_ raw: Int64) throws {
        guard raw >= 0 else {
            throw G09CreativeError.invalidPayload("invalidRevision")
        }
    }

    // MARK: - Static helpers

    private static let availableTargetKinds = [
        "canvasNode", "fileDocument", "chatAttachment", "creativeDocument",
    ]

    /// Per-target refusal still exists (CAD read-only, unsupported workspace/
    /// chat shapes, pending creative first result, run-scoped creative access
    /// when the durable run/job authority is not injected). No whole KIND is
    /// globally refused while its real adapter is registered.
    private static let targetKindReasons: [String: String] = [:]

    private static let canvasActions: [String] = G09R2DesignAction.allCases
        .filter { $0.rawValue.hasPrefix("design.canvas.") }
        .map(\.rawValue)

    private static let canvasReadActions: [String] = [
        "design.canvas.snapshot", "design.canvas.compare",
        "design.canvas.export", "design.canvas.preview",
    ]

    private static let ownerActions: [String] = G09R2DesignAction.allCases
        .filter { $0.rawValue.hasPrefix("design.owner.") }
        .map(\.rawValue)

    private static func canvasIdentity(
        _ target: DesignTarget
    ) throws -> (UUID, UUID) {
        guard let canvasID = UUID(uuidString: target.ownerID),
              let nodeID = UUID(uuidString: target.sourceID) else {
            throw G09R2Error(
                .designTargetUnavailable, detail: "invalidCanvasIdentity")
        }
        return (canvasID, nodeID)
    }

    private static func canvasContentType(
        snapshot: DesignCanvasService.Snapshot,
        nodeID: String
    ) -> DesignContentType {
        snapshot.design?.contentType
            ?? DesignContentTypeMapper.effectiveContentType(
                existing: nil,
                kind: snapshot.nodeKind,
                metadata: snapshot.nodeMetadata)
    }

    private static func canvasMutationContentType(
        snapshot: DesignCanvasService.Snapshot,
        nodeID: String
    ) throws -> DesignContentType {
        let contentType = canvasContentType(snapshot: snapshot, nodeID: nodeID)
        guard contentType != .cad else {
            throw G09R2Error(
                .designTargetUnavailable, detail: "cadDesignReadOnly")
        }
        return contentType
    }

    private static func freezeIntent(
        request: G09R2DesignFreezeRequest,
        family: DesignContentType,
        format: String,
        revisionID: String?
    ) throws -> DesignWorkIntent? {
        guard let mode = request.workMode else { return nil }
        if mode == .restructure {
            throw G09R2Error(
                .designConflict,
                detail: "restructureRequiresTrustedConfirmation")
        }
        let desired = request.desiredFormat ?? format
        let intent = DesignWorkIntent(
            mode: mode,
            actualDesiredFormat: desired,
            frozenRevisionID: revisionID,
            operationID: request.opID)
        return try intent.validated(family: family)
    }

    private static func canvasProposalFingerprint(
        artifactID: String,
        baseRevisionID: String,
        format: String,
        contentSHA256: String,
        summary: String,
        diff: [String],
        feedbackIDs: [String],
        originConversationID: String?,
        originEnvironmentID: String?,
        workMode: DesignWorkMode?,
        preservationDigest: String?
    ) -> String {
        func field(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let parts = [
            field(artifactID),
            field(baseRevisionID),
            field(normalizedFormat(format)),
            field(contentSHA256.lowercased()),
            field(summary),
            field(diff.joined(separator: "\u{1E}")),
            field(feedbackIDs.joined(separator: "\u{1E}")),
            field(originConversationID ?? ""),
            field(originEnvironmentID ?? ""),
            field(workMode?.rawValue ?? ""),
            field(preservationDigest ?? ""),
        ]
        return FloeDigest.sha256Hex(
            Data(parts.joined(separator: "\u{1F}").utf8))
    }

    private static func proposalIntent(
        request: G09R2DesignProposeRequest,
        family: DesignContentType,
        base: String?
    ) throws -> DesignWorkIntent? {
        guard let source = request.workIntent else { return nil }
        if source.mode == .restructure {
            throw G09R2Error(
                .designConflict,
                detail: "restructureRequiresTrustedConfirmation")
        }
        let intent = DesignWorkIntent(
            mode: source.mode,
            actualDesiredFormat: source.actualDesiredFormat.isEmpty
                ? request.payload.format : source.actualDesiredFormat,
            scope: source.scope,
            preservation: source.preservation,
            frozenRevisionID: source.frozenRevisionID ?? base,
            originalTaskOwnerID: source.originalTaskOwnerID,
            confirmation: source.confirmation,
            operationID: request.opID)
        return try intent.validated(family: family)
    }

    private static func requiredContentType(
        _ format: String
    ) throws -> DesignContentType {
        guard let family = DesignContentType.from(format: format) else {
            throw G09R2Error(
                .renderUnsupported, detail: "unsupportedSourceFormat")
        }
        return family
    }

    private static func normalizedFormat(_ raw: String) -> String {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "markdown": return "md"
        case "jpeg": return "jpg"
        case "text": return "txt"
        default: return value
        }
    }

    static func formatsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        normalizedFormat(lhs) == normalizedFormat(rhs)
    }

    /// Safe display/file name for a staged first material. The extension is
    /// forced to the VERIFIED payload format so the imported canonical asset's
    /// on-disk path (and therefore its format) cannot disagree with the bytes
    /// the caller staged.
    private static func creativeImportFileName(
        _ raw: String, format: String
    ) -> String {
        G09R2DesignArtifactStore.safeFileName(raw, format: format)
            ?? "creative-result.\(G09R2DesignArtifactStore.fileExtension(for: format))"
    }

    private static func safeRevisionID(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard G09R2DesignOwnerPayloadStore.isSafeToken(raw) else {
            throw G09CreativeError.invalidPayload("invalidRevisionID")
        }
        return raw
    }

    private static func isTextFormat(_ raw: String) -> Bool {
        switch normalizedFormat(raw) {
        case "md", "txt", "html", "htm", "svg", "json":
            return true
        default:
            return false
        }
    }

    private static func isImageFormat(_ raw: String) -> Bool {
        switch normalizedFormat(raw) {
        case "png", "jpg", "gif", "webp", "heic", "heif", "tiff":
            return true
        default:
            return false
        }
    }

    private static func isAssetFormat(_ raw: String) -> Bool {
        switch normalizedFormat(raw) {
        case "png", "jpg", "gif", "webp", "heic", "heif", "tiff", "pdf",
             "docx", "xlsx", "pptx":
            return true
        default:
            return false
        }
    }

    private static func canCarryText(_ node: CanvasNode) -> Bool {
        if let plugin = node.metadata[DesignContentTypeMapper.builtinPluginMetadataKey],
           DesignContentTypeMapper.textBodyBuiltinPlugins.contains(plugin) {
            return true
        }
        return node.kind == .text || node.kind == .stickyNote
    }

    private static func isAssetNode(_ node: CanvasNode) -> Bool {
        node.kind == .image || node.kind == .file
    }

    private struct CanvasNodeLocation {
        let documentIndex: Int
        let nodeIndex: Int
    }

    private static func nodeLocation(
        _ nodeID: UUID,
        in project: CanvasProject
    ) -> CanvasNodeLocation? {
        for documentIndex in project.documents.indices {
            if let nodeIndex = project.documents[documentIndex].nodes.firstIndex(
                where: { $0.id == nodeID }) {
                return CanvasNodeLocation(
                    documentIndex: documentIndex, nodeIndex: nodeIndex)
            }
        }
        return nil
    }

    /// Bounded verified asset summary for the actual Canvas document. Every
    /// node asset reference is resolved through the SAME creative asset store:
    /// a real row with a matching content hash is `verified`; a cloud/opaque
    /// or missing reference is included with `verified == false` so the App can
    /// show an honest placeholder instead of silently dropping scene content.
    /// The App still reads bytes through the native host reader by asset id;
    /// the recorded relative path is descriptive, never authority.
    private func canvasSnapshotAssets(
        document: CanvasProject
    ) async -> (assets: [G09R2DesignCanvasSnapshotAsset], truncated: Bool) {
        var seen: Set<UUID> = []
        var ordered: [CanvasAssetReference] = []
        var truncated = false
        search: for canvasDocument in document.documents {
            for node in canvasDocument.nodes {
                guard let reference = node.asset else { continue }
                guard seen.insert(reference.id).inserted else { continue }
                guard ordered.count
                    < G09R2DesignCanvasSnapshot.maximumAssetReferences else {
                    truncated = true
                    break search
                }
                ordered.append(reference)
            }
        }
        var summaries: [G09R2DesignCanvasSnapshotAsset] = []
        for reference in ordered {
            let record = await assets.record(id: reference.id)
            let verified: Bool
            if let record, let hash = reference.contentHash, !hash.isEmpty {
                verified = record.contentHash.caseInsensitiveCompare(hash)
                    == .orderedSame
            } else {
                verified = false
            }
            summaries.append(G09R2DesignCanvasSnapshotAsset(
                assetID: reference.id,
                contentHash: reference.contentHash,
                kind: record?.kind.rawValue
                    ?? (reference.contentHash == nil ? "opaque" : "missing"),
                mimeType: record?.mimeType ?? reference.mimeType,
                byteCount: record?.byteCount ?? reference.byteCount,
                verified: verified))
        }
        return (summaries, truncated)
    }

    private static func canvasSnapshotData(
        canvasID: UUID,
        snapshot: DesignCanvasService.Snapshot,
        design: DesignProject,
        document: CanvasProject,
        assets: [G09R2DesignCanvasSnapshotAsset],
        assetsTruncated: Bool,
        maxBytes: Int,
        tooLarge: G09R2Error
    ) throws -> Data {
        // The ACTUAL document must be the exact revision the design snapshot
        // was taken from. A concurrent Canvas patch between the two reads is a
        // typed race, never a mixed scene.
        guard document.id == canvasID,
              document.revision == snapshot.canvasRevision else {
            throw G09R2Error(.designConflict, detail: "canvasRevisionRace")
        }
        guard let containing = document.documents.first(where: { candidate in
            candidate.nodes.contains { $0.id == snapshot.nodeID }
        }) else {
            throw G09R2Error(
                .designPayloadMissing, detail: "canvasNodeMissing")
        }
        if let expectedDocumentID = snapshot.canvasDocumentID,
           containing.id != expectedDocumentID {
            throw G09R2Error(
                .designConflict, detail: "canvasDocumentRace")
        }
        let value = G09R2DesignCanvasSnapshot(
            canvasID: canvasID,
            canvasRevision: snapshot.canvasRevision,
            documentID: containing.id,
            nodeID: snapshot.nodeID,
            canvasDocument: document,
            assets: assets,
            assetsTruncated: assetsTruncated,
            project: design)
        let data = try G09CreativeWire.encoder().encode(value)
        guard data.count <= maxBytes else {
            throw tooLarge
        }
        return data
    }

    private static func deliveryDTO(
        _ delivery: DesignDecisionDelivery
    ) -> G09R2DesignDeliveryDTO {
        switch delivery {
        case .notRequired:
            return G09R2DesignDeliveryDTO(state: .notRequired, reason: nil)
        case .delivered:
            return G09R2DesignDeliveryDTO(state: .delivered, reason: nil)
        case .pending(let reason):
            return G09R2DesignDeliveryDTO(state: .pending, reason: reason)
        }
    }

    private static func publicationDTO(
        _ publication: DesignResultPublicationOutcome
    ) -> G09R2DesignPublicationDTO {
        switch publication {
        case .notRequired:
            return G09R2DesignPublicationDTO(
                state: .notRequired,
                identifier: nil,
                destination: nil,
                contentSHA256: nil,
                reason: nil)
        case .published(let receipt):
            return G09R2DesignPublicationDTO(
                state: .published,
                identifier: receipt.identifier,
                destination: receipt.destination,
                contentSHA256: receipt.contentSHA256,
                reason: nil)
        case .pending(let reason):
            return G09R2DesignPublicationDTO(
                state: .pending,
                identifier: nil,
                destination: nil,
                contentSHA256: nil,
                reason: reason)
        }
    }

    // MARK: - Error mapping

    private static func map(_ error: Error) -> Error {
        if let typed = error as? G09R2Error { return typed }
        if let typed = error as? G09CreativeError { return typed }
        if let typed = error as? DesignOwnerWorkflowError {
            switch typed {
            case .ownerConflict:
                return G09R2Error(.designConflict, detail: "ownerConflict")
            case .replayMismatch:
                return G09R2Error(.designConflict, detail: "replayMismatch")
            case .missingPayload:
                return G09R2Error(.designPayloadMissing, detail: "missingPayload")
            case .notInPlaceOwner:
                return G09R2Error(.designTargetUnavailable, detail: "notInPlaceOwner")
            case .deletedSource:
                return G09R2Error(.designTargetUnavailable, detail: "deletedSource")
            case .adoptionPendingRecovery(let operationID, _):
                return G09R2Error(
                    .designConflict,
                    detail: "adoptionPendingRecovery:\(operationID)")
            case .canvasRequiresCanvasAuthority:
                return G09R2Error(
                    .designConflict, detail: "canvasRequiresCanvasAuthority")
            case .resultPublicationUnavailable:
                return G09R2Error(
                    .designPublicationUnavailable,
                    detail: "resultPublicationUnavailable")
            case .restructureRequiresTrustedConfirmation:
                return G09R2Error(
                    .designConflict,
                    detail: "restructureRequiresTrustedConfirmation")
            }
        }
        if let typed = error as? DesignTargetError {
            switch typed {
            case .unsupportedKind(let kind):
                return G09R2Error(
                    .designTargetUnavailable, detail: "unsupportedKind:\(kind)")
            case .notAuthorized:
                return G09R2Error(
                    .designTargetUnavailable, detail: "notAuthorized")
            case .notFound:
                return G09R2Error(.designTargetUnavailable, detail: "notFound")
            case .invalidReference:
                return G09R2Error(
                    .designTargetUnavailable, detail: "invalidReference")
            case .unverifiable:
                return G09R2Error(.designPayloadMissing, detail: "unverifiable")
            case .unavailable(let reason):
                return G09R2Error(
                    .designTargetUnavailable,
                    detail: String(reason.prefix(90)))
            case .moved:
                return G09R2Error(.designConflict, detail: "targetMoved")
            case .pendingFirstResult:
                return G09R2Error(
                    .designTargetUnavailable, detail: "pendingFirstResult")
            case .firstResultAlreadyBound:
                return G09R2Error(
                    .designConflict, detail: "firstResultAlreadyBound")
            }
        }
        if let typed = error as? DesignWorkflowError {
            switch typed {
            case .candidateNotFound:
                return G09R2Error(.candidateNotFound, detail: "candidateNotFound")
            case .revisionNotFound:
                return G09R2Error(.designPayloadMissing, detail: "revisionNotFound")
            case .projectNotFound:
                return G09R2Error(.designTargetUnavailable, detail: "projectNotFound")
            case .artifactNotFound:
                return G09R2Error(.designPayloadMissing, detail: "artifactNotFound")
            case .feedbackNotFound:
                return G09R2Error(.designPayloadMissing, detail: "feedbackNotFound")
            case .noActualChange:
                return G09R2Error(.designConflict, detail: "noActualChange")
            case .revisionConflict:
                return G09R2Error(.designConflict, detail: "revisionConflict")
            case .anchorNotRelocated, .invalidAnchor:
                return G09R2Error(.designConflict, detail: "invalidAnchor")
            case .operationAlreadyApplied:
                return G09R2Error(.designConflict, detail: "operationAlreadyApplied")
            }
        }
        if let typed = error as? DesignOwnerCommitError {
            switch typed {
            case .notWritten:
                return G09R2Error(.designConflict, detail: "commitRefused")
            case .unknown:
                return G09R2Error(.designConflict, detail: "commitOutcomeUnknown")
            }
        }
        if let typed = error as? DesignRestructureAuthorityError {
            switch typed {
            case .claimRequired:
                return G09R2Error(
                    .designConflict,
                    detail: "restructureRequiresTrustedConfirmation")
            case .claimMismatch:
                return G09R2Error(
                    .designConflict, detail: "restructureClaimMismatch")
            }
        }
        if let typed = error as? G09R2DesignAuthorityError {
            switch typed {
            case .invalidConfirmation:
                return G09R2Error(
                    .designConflict,
                    detail: "restructureConfirmationInvalid")
            }
        }
        if let typed = error as? G09R2DesignStoreError {
            switch typed {
            case .invalidKey:
                return G09R2Error(.designTargetUnavailable, detail: "invalidStoreKey")
            case .corrupt:
                return G09R2Error(.designConflict, detail: "designStoreCorrupt")
            case .conflict:
                return G09R2Error(.designConflict, detail: "designStoreConflict")
            case .tooLarge:
                return G09R2Error(.designPayloadTooLarge, detail: "designStoreTooLarge")
            case .writeFailed:
                return G09CreativeError.writeFailed
            }
        }
        if let typed = error as? G09R2DesignCreativeInventoryError {
            switch typed {
            case .invalidCursor:
                return G09CreativeError.invalidPayload("invalidCursor")
            case .unavailable:
                return G09R2Error(
                    .designTargetUnavailable,
                    detail: "creativeAssetInventoryUnavailable")
            }
        }
        if let typed = error as? WorkspaceToolError {
            _ = typed
            return G09CreativeError.workspaceStorageUnavailable
        }
        return G09CreativeError.map(error)
    }
}
