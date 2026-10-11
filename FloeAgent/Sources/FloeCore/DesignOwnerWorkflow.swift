import Foundation

// FloeCore — Shared design workflow over typed, non-canvas owners.
//
// This is the SAME state machine as the Canvas flow (`DesignWorkflowEngine`
// on a `DesignProject`), driven for file / chat / creative targets through
// the owner-CAS envelope (`DesignOwnerEnvelope` + `DesignOwnerProjectStore`).
// It provides the full proposal/adopt/reject/feedback/restore/export cycle,
// not just target discovery:
//
// - Inputs are frozen: every call carries the target's base revision token;
//   a moved base (concurrent manual edit) is `.moved`, a late candidate that
//   can no longer be adopted is rejected, and a duplicate operation replays
//   the recorded result.
// - Draft/candidate/adopted stay distinct; adoption is explicit.
// - Revision bytes are staged + hash-verified BEFORE the envelope CAS, so a
//   revision never references missing bytes.
// - The original task attachment is never modified; its adopted result is
//   retained here and a durable decision event goes to the ORIGINAL task.
// - In-place owners (workspace files) additionally write the adopted bytes
//   through a `DesignOwnerCommitPort`, gated by the frozen base token.
// - Canvas-node targets are typed-DISCOVERY only here. Every read/mutation
//   fails closed with `canvasRequiresCanvasAuthority`: Canvas has exactly ONE
//   mutable authority (`DesignCanvasService` / `canvas.design` node
//   metadata), and the existing canvas path (`DesignWorkflowActions`) owns
//   it. A generic owner envelope for a node would be a second authority or
//   an "adopted" success that never touched the node.
// - Immutable owners (chat attachment / creative asset) REQUIRE a
//   `DesignResultPublicationPort` before adoption: the user-approved result
//   must be returned as a NEW attachment/asset through the existing
//   FilesCenter/ConversationStore/CreativeAssetStore. A missing port fails
//   closed BEFORE the CAS; a failed publication keeps the durable decision
//   record pending (never a metadata-with-a-notice success).
// - The durable decision outbox is the existing `DesignDecisionOutbox`
//   (target-aware fingerprints), so delivery is crash-safe and deduplicated.

public enum DesignOwnerWorkflowError: Error, Equatable {
    case ownerConflict(expected: Int64, actual: Int64)
    case replayMismatch(String)
    case missingPayload(String)
    case notInPlaceOwner
    case deletedSource
    /// An in-place source write succeeded (or may have landed) but the owner
    /// metadata CAS did not commit. The recoverable state is retained by the
    /// durable decision intent; reconcile resumes it against the ACTUAL
    /// source bytes. NEVER means "nothing changed".
    case adoptionPendingRecovery(operationID: String, reason: String)
    /// A Canvas-node target reached the generic owner workflow. Canvas
    /// design state has ONE authority — the Canvas document CAS
    /// (`DesignCanvasService`, node metadata `canvas.design`) — and the
    /// existing canvas path (`DesignWorkflowActions`) must handle it. The
    /// generic owner envelope/payload stores are for file/chat/creative
    /// targets only; failing closed here prevents BOTH a second Canvas
    /// metadata authority AND a silent "adopted" success that never touched
    /// the node.
    case canvasRequiresCanvasAuthority(String)
    /// An adopted result for an immutable owner (chat attachment / creative
    /// asset) has no configured publication route. The result would remain
    /// only in the owner envelope with a success notice — the exact
    /// metadata-without-result failure this gate forbids. Raised BEFORE any
    /// state change; the caller must wire a `DesignResultPublicationPort`
    /// (T6 integration) or use the existing owner path.
    case resultPublicationUnavailable(String)
}

/// Honest outcome of delivering a target decision to the originating task.
/// `pending` means the durable intent is retained and a later reconcile (or
/// replay) must retry; it is never reported as delivered.
public enum DesignDecisionDelivery: Sendable, Equatable {
    /// No originating task exists: nothing needs to be notified (the
    /// adoption is still legitimate; any crash-recovery record was settled).
    case notRequired
    /// The sink accepted the event and the durable intent was acknowledged.
    case delivered
    /// The event is still pending; the string is the honest reason.
    case pending(String)

    public var isDelivered: Bool { self == .delivered }

    public var errorDescription: String? {
        if case .pending(let reason) = self { return reason }
        return nil
    }
}

/// Decision sink to the original task's durable ingress. Mirrors the Canvas
/// action sink; `ownerRevision` replaces the canvas revision for non-canvas
/// owners. Throwing keeps the decision intent pending for reconcile.
public typealias DesignOwnerDecisionSink =
    @Sendable (_ conversationID: UUID, _ candidateID: UUID, _ decision: String,
               _ ownerRevision: Int64?, _ contentSHA256: String?) async throws -> Void

public actor DesignOwnerWorkflow {
    private let targets: DesignTargetService
    private let store: DesignOwnerProjectStore
    private let payloads: DesignOwnerPayloadStore
    private let commitPorts: [DesignTargetKind: any DesignOwnerCommitPort]
    private let outbox: DesignDecisionOutbox
    /// Configured decision sink (the app's existing durable ingress). Used
    /// when a call does not pass its own sink. nil stays nil: the service
    /// NEVER fabricates a success when no sink is configured.
    private let defaultSink: DesignOwnerDecisionSink?
    /// Configured result-publication port (the app's existing
    /// FilesCenter/ConversationStore/CreativeAssetStore write path). nil
    /// stays nil: an immutable-owner adoption fails closed rather than
    /// reporting a success whose result was never returned.
    private let defaultPublication: DesignResultPublicationPort?
    /// Same-target single-flight reservations (see below).
    private var reservedTargets: Set<String> = []
    private var targetReservationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(
        targets: DesignTargetService,
        store: any DesignOwnerProjectStore,
        payloads: any DesignOwnerPayloadStore,
        commitPorts: [DesignTargetKind: any DesignOwnerCommitPort] = [:],
        outbox: DesignDecisionOutbox = .shared,
        defaultSink: DesignOwnerDecisionSink? = nil,
        defaultPublication: DesignResultPublicationPort? = nil
    ) {
        self.targets = targets
        self.store = store
        self.payloads = payloads
        self.commitPorts = commitPorts
        self.outbox = outbox
        self.defaultSink = defaultSink
        self.defaultPublication = defaultPublication
    }

    // MARK: - Same-target single-flight reservation
    //
    // Swift actors are REENTRANT: every `await` inside a mutation (payload
    // store, source commit, envelope CAS, delivery) lets another call
    // interleave. Without a reservation a concurrent brief/edit could move
    // the owner revision between an adoption's pre-flight and its CAS,
    // leaving a committed source file with uncommitted metadata.
    //
    // The reservation serializes MUTATIONS PER TARGET only: two different
    // documents never block each other, and reads (state/compare/export)
    // stay lock-free. `defer` releases on every exit path, including thrown
    // errors; waiters re-check after resume (bounded, no spin).
    private func acquireTargetReservation(_ key: String) async {
        while reservedTargets.contains(key) {
            await withCheckedContinuation { continuation in
                targetReservationWaiters[key, default: []].append(continuation)
            }
        }
        reservedTargets.insert(key)
    }

    private func releaseTargetReservation(_ key: String) {
        reservedTargets.remove(key)
        let waiters = targetReservationWaiters.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter.resume() }
    }

    /// Clean cancel for a freshly prepared intent whose operation provably
    /// never touched the source. `notWritten` commit failures and pre-commit
    /// validation failures are the only callers: anything that may have
    /// written bytes keeps the durable record pending.
    private func cancelFreshIntent(_ intent: DesignDecisionIntent?) async {
        guard let intent, intent.phase == .committing else { return }
        try? await outbox.cancel(id: intent.id)
    }

    private static func isProvenUncommitted(_ error: Error) -> Bool {
        if let commitError = error as? DesignOwnerCommitError {
            if case .notWritten = commitError { return true }
            return false
        }
        return false
    }

    // MARK: - Canvas authority boundary (fail closed)

    /// The generic owner workflow NEVER reads or mutates Canvas design
    /// state. Canvas nodes are typed-discov by `DesignTargetService` (the
    /// retained `DesignCanvasOwnerAdapter`), but every design operation on a
    /// canvas target belongs to the existing Canvas path — `DesignCanvasService`
    /// + `DesignWorkflowActions` — which owns the single authoritative
    /// `canvas.design` node metadata. Reaching a mutation here would create a
    /// SECOND mutable authority (the owner envelope) or report an adoption
    /// whose bytes never touched the node.
    private static func requireNonCanvasOwner(
        _ target: DesignTarget,
        operation: String
    ) throws {
        guard target.kind != .canvasNode else {
            throw DesignOwnerWorkflowError.canvasRequiresCanvasAuthority(
                "\(operation) on a Canvas node must use the existing Canvas path (DesignCanvasService/DesignWorkflowActions); the generic owner workflow owns only file/chat/creative targets, and \(target.displayID) never creates a second Canvas metadata state"
            )
        }
    }

    /// Immutable owners cannot be updated in place: an adopted result MUST be
    /// returned to a new destination (chat attachment → originating task;
    /// creative → existing CreativeAssetStore). File in-place owners publish
    /// by the verified source write itself; a file variant has no separate
    /// destination and is exported through `exportVerified`.
    private static func requiresResultPublication(_ target: DesignTarget) -> Bool {
        switch target.kind {
        case .chatAttachment, .creativeDocument:
            return true
        case .canvasNode, .fileDocument:
            return false
        }
    }

    // MARK: - Boundary authorization

    /// LIVE re-authorization at EVERY public boundary (read and mutation),
    /// independent of the initial freeze. Throws before any envelope is
    /// loaded so a revoked run or a cross-task/cross-environment caller
    /// cannot read or replay design state.
    private func requireAuthorized(_ target: DesignTarget, runID: UUID?) async throws {
        guard await targets.authorize(target, runID: runID) else {
            throw DesignTargetError.notAuthorized(
                "caller is not authorized for \(target.displayID)"
            )
        }
    }

    // MARK: - Envelope CAS

    private struct LoadedEnvelope {
        var envelope: DesignOwnerEnvelope
        let created: Bool
    }

    private func load(
        _ target: DesignTarget,
        createFromSource: Bool,
        runID: UUID?
    ) async throws -> LoadedEnvelope {
        try Self.requireNonCanvasOwner(target, operation: "load owner envelope")
        try await requireAuthorized(target, runID: runID)
        let key = target.stableKey
        if let existing = try await store.load(targetKey: key) {
            // A copied envelope must never retarget: source identity
            // (including environment, excluding originating task) compare.
            guard existing.target.isSameSource(as: target) else {
                throw DesignTargetError.invalidReference("envelope does not belong to this target")
            }
            return .init(envelope: existing, created: false)
        }
        guard createFromSource else {
            throw DesignTargetError.notFound(
                "no design state exists for \(target.displayID); freeze the input first"
            )
        }
        // The content family is taken from the REAL resolved source (its
        // verified format), never a generic webpage fallback. A creative
        // START request already declares its requested kind, so creating
        // its envelope must not require material to exist yet.
        let contentType: DesignContentType
        if let requested = target.requestedOutputKind {
            contentType = requested
        } else {
            let resolved = try await targets.resolve(target, runID: runID)
            contentType = resolved.contentType
        }
        let project = DesignWorkflowEngine.createProject(
            nodeID: key,
            contentType: contentType
        )
        return .init(envelope: .init(target: target, project: project, revision: 0), created: true)
    }

    /// Applies a mutation body and commits through the owner CAS. Split
    /// from the replay check so authorization happens exactly once per
    /// boundary but the body executes only for a genuinely new operation.
    @discardableResult
    private func commit(
        _ loaded0: LoadedEnvelope,
        target: DesignTarget,
        body: (inout DesignProject) throws -> Void
    ) async throws -> DesignOwnerEnvelope {
        var loaded = loaded0
        try body(&loaded.envelope.project)
        loaded.envelope.project.updatedAt = Date()
        let revision = try await store.save(
            loaded.envelope,
            targetKey: target.stableKey,
            expectedRevision: loaded.envelope.revision
        )
        loaded.envelope.revision = revision
        return loaded.envelope
    }

    /// Authorization → replay-first → conflict → body → single CAS, under
    /// this target's single-flight reservation. Callers that already hold
    /// the reservation (adopt/reject transactions) pass `alreadyReserved:
    /// true` to avoid self-deadlock.
    @discardableResult
    private func mutate(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64?,
        runID: UUID?,
        createFromSource: Bool = false,
        alreadyReserved: Bool = false,
        body: (inout DesignProject) throws -> Void
    ) async throws -> (envelope: DesignOwnerEnvelope, replayed: Bool) {
        try Self.requireNonCanvasOwner(target, operation: "mutate owner design state")
        if alreadyReserved {
            return try await mutateLocked(
                target: target, operationID: operationID,
                expectedOwnerRevision: expectedOwnerRevision, runID: runID,
                createFromSource: createFromSource, body: body
            )
        }
        await acquireTargetReservation(target.stableKey)
        defer { releaseTargetReservation(target.stableKey) }
        return try await mutateLocked(
            target: target, operationID: operationID,
            expectedOwnerRevision: expectedOwnerRevision, runID: runID,
            createFromSource: createFromSource, body: body
        )
    }

    @discardableResult
    private func mutateLocked(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64?,
        runID: UUID?,
        createFromSource: Bool,
        body: (inout DesignProject) throws -> Void
    ) async throws -> (envelope: DesignOwnerEnvelope, replayed: Bool) {
        guard !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("operationID is required")
        }
        var loaded = try await load(target, createFromSource: createFromSource, runID: runID)
        if loaded.envelope.project.hasApplied(operationID: operationID) {
            return (loaded.envelope, true)
        }
        if let expectedOwnerRevision, loaded.envelope.revision != expectedOwnerRevision {
            throw DesignOwnerWorkflowError.ownerConflict(
                expected: expectedOwnerRevision, actual: loaded.envelope.revision
            )
        }
        guard DesignWorkflowEngine.recordOperation(operationID, in: &loaded.envelope.project) else {
            return (loaded.envelope, true)
        }
        let saved = try await commit(loaded, target: target, body: body)
        return (saved, false)
    }

    // MARK: - Creative start (pre-material request)

    /// Persists the creative START requirements (requested output kind +
    /// brief/spec) BEFORE any material exists. The shared design state is
    /// the durable home: reopening the target restores the request; no
    /// canvas, workspace or asset is created here.
    public func beginCreativeRequest(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64?,
        brief: DesignBrief? = nil,
        spec: DesignSpec? = nil,
        runID: UUID? = nil
    ) async throws -> (envelope: DesignOwnerEnvelope, request: DesignCreativeRequest) {
        try Self.requireNonCanvasOwner(target, operation: "begin a creative request")
        guard target.kind == .creativeDocument, let requestedKind = target.requestedOutputKind else {
            throw DesignTargetError.invalidReference(
                "beginCreativeRequest requires a creative target with an explicit requested output kind"
            )
        }
        await acquireTargetReservation(target.stableKey)
        defer { releaseTargetReservation(target.stableKey) }
        try await requireAuthorized(target, runID: runID)
        let key = target.stableKey
        var loaded: LoadedEnvelope
        if let existing = try await store.load(targetKey: key) {
            guard existing.target.isSameSource(as: target) else {
                throw DesignTargetError.invalidReference("envelope does not belong to this target")
            }
            loaded = .init(envelope: existing, created: false)
        } else {
            let project = DesignWorkflowEngine.createProject(
                nodeID: key, contentType: requestedKind
            )
            loaded = .init(envelope: .init(target: target, project: project, revision: 0), created: true)
        }
        if loaded.envelope.project.hasApplied(operationID: operationID) {
            guard let recorded = loaded.envelope.project.creativeRequest else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            return (loaded.envelope, recorded)
        }
        if let expectedOwnerRevision, loaded.envelope.revision != expectedOwnerRevision {
            throw DesignOwnerWorkflowError.ownerConflict(
                expected: expectedOwnerRevision, actual: loaded.envelope.revision
            )
        }
        guard DesignWorkflowEngine.recordOperation(operationID, in: &loaded.envelope.project) else {
            guard let recorded = loaded.envelope.project.creativeRequest else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            return (loaded.envelope, recorded)
        }
        if let brief { DesignWorkflowEngine.updateBrief(brief, in: &loaded.envelope.project) }
        if let spec { DesignWorkflowEngine.updateSpec(spec, in: &loaded.envelope.project) }
        let priorCreatedAt = loaded.envelope.project.creativeRequest?.createdAt ?? Date()
        let request = DesignCreativeRequest(
            requestedKind: requestedKind,
            state: .awaitingFirstResult,
            originConversationID: target.originConversationID,
            environmentID: target.environmentID,
            createdAt: priorCreatedAt,
            updatedAt: Date()
        )
        loaded.envelope.project.creativeRequest = request
        let saved = try await commit(loaded, target: target) { project in
            project.updatedAt = Date()
        }
        return (saved, request)
    }

    /// Binds the FIRST real generated result to the SAME target: verified
    /// bytes become the first revision, the run freezes, and the request
    /// state moves to `.firstResultBound`. A second (non-replay) bind is
    /// rejected — later edits go through the ordinary revision/candidate
    /// flow. The original task attribution stays on the request/candidate/
    /// decision records, never on the store identity.
    ///
    /// Authority: the registered creative port MUST verify, before any
    /// payload write/CAS, that `boundResultID` is a REAL retained asset whose
    /// verified bytes/format EQUAL the proposed bytes (so a model cannot pair
    /// its own payload with a foreign asset id) and — for a run — that the
    /// asset is linked to the run's own task by a durable generation job. The
    /// returned provenance is recorded in the same envelope CAS; replay is
    /// idempotent and re-checks live run authorization, while reads of a
    /// bound record re-check the live provenance and digest.
    public func bindFirstResult(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64,
        bytes: Data,
        format: String,
        displayName: String,
        boundResultID: String,
        runID: UUID? = nil
    ) async throws -> (envelope: DesignOwnerEnvelope, revision: DesignRevision) {
        try Self.requireNonCanvasOwner(target, operation: "bind the first creative result")
        guard target.kind == .creativeDocument, let requestedKind = target.requestedOutputKind else {
            throw DesignTargetError.invalidReference(
                "bindFirstResult requires a creative target with an explicit requested output kind"
            )
        }
        await acquireTargetReservation(target.stableKey)
        defer { releaseTargetReservation(target.stableKey) }
        try await requireAuthorized(target, runID: runID)
        let digest = FloeDigest.sha256Hex(bytes)
        var loaded = try await load(target, createFromSource: false, runID: runID)
        let existingRequest = loaded.envelope.project.creativeRequest
        if loaded.envelope.project.hasApplied(operationID: operationID) {
            // Replay: the recorded first revision must match the bytes.
            guard let artifact = loaded.envelope.project.artifacts.first,
                  let current = artifact.currentRevision,
                  current.contentSHA256 == digest else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            return (loaded.envelope, current)
        }
        guard let existingRequest else {
            throw DesignTargetError.invalidReference(
                "no creative request exists for this target; begin it first"
            )
        }
        guard existingRequest.state == .awaitingFirstResult else {
            throw DesignTargetError.firstResultAlreadyBound(
                existingRequest.boundResultID ?? "unknown"
            )
        }
        guard let proposedType = DesignContentType.from(format: format),
              proposedType == requestedKind else {
            throw DesignTargetError.unavailable(
                "First result format '\(format)' does not match the requested \(requestedKind.rawValue) output"
            )
        }
        if loaded.envelope.revision != expectedOwnerRevision {
            throw DesignOwnerWorkflowError.ownerConflict(
                expected: expectedOwnerRevision, actual: loaded.envelope.revision
            )
        }
        // T7C authority boundary: BEFORE the first payload write and the
        // envelope CAS, the registered owner adapter (app port) must prove
        // the bound identity IS the real retained asset — same verified
        // bytes and format — and, for a run, that the asset is linked to the
        // run's own task through an independently trusted record (the
        // durable media-generation job→asset link). Core records only the
        // provenance the port returns; a caller-supplied boolean, a
        // model-authored `boundResultID` or a persisted envelope field is
        // never proof. A refusal here leaves no payload and no envelope
        // change.
        let provenance = try await targets.verifyCreativeFirstResultBinding(
            target,
            boundResultID: boundResultID,
            bytes: bytes,
            format: format,
            runID: runID
        )
        let artifactID = loaded.envelope.project.artifacts.first?.id
            ?? UUID().uuidString.lowercased()
        let revisionID = UUID().uuidString.lowercased()
        let relative = try payloads.store(
            ownerKey: target.stableKey,
            revisionID: revisionID,
            bytes: bytes,
            expectedContentSHA256: digest
        )
        do {
            guard DesignWorkflowEngine.recordOperation(operationID, in: &loaded.envelope.project) else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            if loaded.envelope.project.artifact(artifactID) == nil {
                DesignWorkflowEngine.addArtifact(
                    DesignArtifact(
                        id: artifactID,
                        contentType: requestedKind,
                        canvasNodeID: nil,
                        identity: .init(
                            name: displayName,
                            positionX: 0, positionY: 0, width: 0, height: 0
                        )
                    ),
                    to: &loaded.envelope.project
                )
            }
            let revision = try DesignWorkflowEngine.registerRevision(
                in: &loaded.envelope.project,
                artifactID: artifactID,
                contentSHA256: digest,
                origin: .generate,
                payloadRelativePath: relative,
                payloadFormat: format,
                revisionID: revisionID
            )
            DesignWorkflowEngine.freezeRun(
                operationID: operationID,
                in: &loaded.envelope.project,
                inputRevisionID: revision.id,
                targetRevisionID: revision.id
            )
            loaded.envelope.project.creativeRequest = DesignCreativeRequest(
                requestedKind: requestedKind,
                state: .firstResultBound,
                boundResultID: boundResultID,
                boundFormat: format,
                boundContentSHA256: digest,
                originConversationID: existingRequest.originConversationID,
                environmentID: existingRequest.environmentID,
                createdAt: existingRequest.createdAt,
                updatedAt: Date()
            )
            loaded.envelope.creativeFirstResultProvenance = provenance
            let saved = try await commit(loaded, target: target) { project in
                project.updatedAt = Date()
            }
            return (saved, revision)
        } catch {
            payloads.abandon(ownerKey: target.stableKey, revisionID: revisionID)
            throw error
        }
    }

    // MARK: - Manual edit revision

    /// Registers a manual editor save as a new revision with optimistic
    /// concurrency: `expectedArtifactRevisionID` pins the revision the
    /// editor was working from; a mismatch is a conflict and the owner
    /// source is never silently overwritten. Payload bytes are verified and
    /// stored before the envelope CAS.
    public func registerEdit(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64?,
        artifactID: String,
        bytes: Data,
        format: String,
        origin: DesignRevisionOrigin = .edit,
        expectedArtifactRevisionID: String? = nil,
        runID: UUID? = nil
    ) async throws -> (envelope: DesignOwnerEnvelope, revision: DesignRevision) {
        try Self.requireNonCanvasOwner(target, operation: "register an edit")
        await acquireTargetReservation(target.stableKey)
        defer { releaseTargetReservation(target.stableKey) }
        try await requireAuthorized(target, runID: runID)
        let digest = FloeDigest.sha256Hex(bytes)
        var loaded = try await load(target, createFromSource: false, runID: runID)
        if loaded.envelope.project.hasApplied(operationID: operationID) {
            guard let artifact = loaded.envelope.project.artifact(artifactID),
                  let current = artifact.currentRevision,
                  current.contentSHA256 == digest else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            return (loaded.envelope, current)
        }
        guard let artifact = loaded.envelope.project.artifact(artifactID) else {
            throw DesignWorkflowError.artifactNotFound(artifactID)
        }
        guard let formatFamily = DesignContentType.from(format: format),
              formatFamily == artifact.contentType else {
            throw DesignTargetError.unavailable(
                "Edit format '\(format)' does not match the \(artifact.contentType.rawValue) source"
            )
        }
        if let expectedOwnerRevision, loaded.envelope.revision != expectedOwnerRevision {
            throw DesignOwnerWorkflowError.ownerConflict(
                expected: expectedOwnerRevision, actual: loaded.envelope.revision
            )
        }
        let revisionID = UUID().uuidString.lowercased()
        let relative = try payloads.store(
            ownerKey: target.stableKey,
            revisionID: revisionID,
            bytes: bytes,
            expectedContentSHA256: digest
        )
        do {
            guard DesignWorkflowEngine.recordOperation(operationID, in: &loaded.envelope.project) else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            let revision = try DesignWorkflowEngine.registerRevision(
                in: &loaded.envelope.project,
                artifactID: artifactID,
                contentSHA256: digest,
                origin: origin,
                expectedRevisionID: expectedArtifactRevisionID,
                payloadRelativePath: relative,
                payloadFormat: format,
                revisionID: revisionID
            )
            let saved = try await commit(loaded, target: target) { project in
                project.updatedAt = Date()
            }
            return (saved, revision)
        } catch {
            payloads.abandon(ownerKey: target.stableKey, revisionID: revisionID)
            throw error
        }
    }

    // MARK: - Reads

    public func state(_ target: DesignTarget, runID: UUID? = nil) async throws -> DesignOwnerEnvelope? {
        // Canvas state is read from the Canvas service snapshot, never from
        // this owner envelope (which must not exist for a canvas node).
        try Self.requireNonCanvasOwner(target, operation: "read owner design state")
        try await requireAuthorized(target, runID: runID)
        return try await store.load(targetKey: target.stableKey)
    }

    // MARK: - Brief / spec / template

    public func updateBrief(
        target: DesignTarget, operationID: String, expectedOwnerRevision: Int64?,
        brief: DesignBrief, runID: UUID? = nil
    ) async throws -> DesignOwnerEnvelope {
        try await mutate(
            target: target, operationID: operationID,
            expectedOwnerRevision: expectedOwnerRevision, runID: runID,
            createFromSource: true
        ) { project in
            DesignWorkflowEngine.updateBrief(brief, in: &project)
        }.envelope
    }

    public func updateSpec(
        target: DesignTarget, operationID: String, expectedOwnerRevision: Int64?,
        spec: DesignSpec, runID: UUID? = nil
    ) async throws -> DesignOwnerEnvelope {
        try await mutate(
            target: target, operationID: operationID,
            expectedOwnerRevision: expectedOwnerRevision, runID: runID,
            createFromSource: true
        ) { project in
            DesignWorkflowEngine.updateSpec(spec, in: &project)
        }.envelope
    }

    // MARK: - Freeze input

    /// Freezes the resolved source as the base input revision. The source is
    /// re-resolved through its owner adapter so a deleted attachment or a
    /// concurrently modified file is detected before freeze.
    public func freezeInput(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64?,
        artifactID: String? = nil,
        displayName: String? = nil,
        runID: UUID? = nil
    ) async throws -> (envelope: DesignOwnerEnvelope, revision: DesignRevision, source: DesignResolvedSource) {
        // Fail closed BEFORE resolving bytes: freeze writes the owner
        // envelope, which is never the Canvas authority.
        try Self.requireNonCanvasOwner(target, operation: "freeze the design input")
        await acquireTargetReservation(target.stableKey)
        defer { releaseTargetReservation(target.stableKey) }
        // Re-resolve WITHOUT honoring a stale frozen token; the adapter
        // performs the live task/environment authorization on the bytes.
        let source = try await targets.resolve(target.freezing(revision: nil), runID: runID)
        var loaded = try await load(target, createFromSource: true, runID: runID)
        if loaded.envelope.project.hasApplied(operationID: operationID) {
            // Replay: return the recorded input revision.
            let recorded = Self.recordedInputRevision(in: loaded.envelope.project, digest: source.contentSHA256)
            guard let recorded else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            return (loaded.envelope, recorded, source)
        }
        // A creative request whose first result is already bound already has
        // its frozen input: freezing again with the same content is a replay,
        // not a second input revision.
        if loaded.envelope.project.creativeRequest?.state == .firstResultBound,
           let recorded = Self.recordedInputRevision(
               in: loaded.envelope.project, digest: source.contentSHA256
           ) {
            return (loaded.envelope, recorded, source)
        }
        if let expectedOwnerRevision, loaded.envelope.revision != expectedOwnerRevision {
            throw DesignOwnerWorkflowError.ownerConflict(
                expected: expectedOwnerRevision, actual: loaded.envelope.revision
            )
        }
        let resolvedArtifactID = artifactID
            ?? loaded.envelope.project.artifacts.first?.id
            ?? UUID().uuidString.lowercased()
        let revisionID = UUID().uuidString.lowercased()
        // Payload BEFORE the CAS.
        let relative = try payloads.store(
            ownerKey: target.stableKey,
            revisionID: revisionID,
            bytes: source.data,
            expectedContentSHA256: source.contentSHA256
        )
        guard DesignWorkflowEngine.recordOperation(operationID, in: &loaded.envelope.project) else {
            payloads.abandon(ownerKey: target.stableKey, revisionID: revisionID)
            throw DesignOwnerWorkflowError.replayMismatch(operationID)
        }
        do {
            if loaded.envelope.project.artifact(resolvedArtifactID) == nil {
                DesignWorkflowEngine.addArtifact(
                    DesignArtifact(
                        id: resolvedArtifactID,
                        contentType: source.contentType,
                        canvasNodeID: nil,
                        identity: .init(
                            name: displayName ?? source.displayName,
                            positionX: 0, positionY: 0, width: 0, height: 0
                        )
                    ),
                    to: &loaded.envelope.project
                )
            }
            let revision = try DesignWorkflowEngine.registerRevision(
                in: &loaded.envelope.project,
                artifactID: resolvedArtifactID,
                contentSHA256: source.contentSHA256,
                origin: .importFile,
                payloadRelativePath: relative,
                payloadFormat: source.format,
                revisionID: revisionID
            )
            DesignWorkflowEngine.freezeRun(
                operationID: operationID,
                in: &loaded.envelope.project,
                inputRevisionID: revision.id,
                targetRevisionID: revision.id
            )
            loaded.envelope.project.updatedAt = Date()
            let newRevision = try await store.save(
                loaded.envelope, targetKey: target.stableKey,
                expectedRevision: loaded.envelope.revision
            )
            loaded.envelope.revision = newRevision
            return (loaded.envelope, revision, source)
        } catch {
            payloads.abandon(ownerKey: target.stableKey, revisionID: revisionID)
            throw error
        }
    }

    private static func recordedInputRevision(
        in project: DesignProject, digest: String
    ) -> DesignRevision? {
        for artifact in project.artifacts {
            if let revision = artifact.revisions.first(where: {
                ($0.origin == .importFile || $0.origin == .currentNode || $0.origin == .generate)
                    && $0.contentSHA256 == digest && $0.payloadRelativePath != nil
            }) {
                return revision
            }
        }
        return nil
    }

    // MARK: - Feedback

    public func addFeedback(
        target: DesignTarget, operationID: String, expectedOwnerRevision: Int64?,
        artifactID: String, revisionID: String?,
        anchor: DesignFeedbackAnchor, comment: String, author: DesignFeedbackAuthor,
        runID: UUID? = nil
    ) async throws -> (envelope: DesignOwnerEnvelope, feedback: DesignFeedback) {
        var created: DesignFeedback?
        let envelope = try await mutate(
            target: target, operationID: operationID,
            expectedOwnerRevision: expectedOwnerRevision, runID: runID
        ) { project in
            created = try DesignWorkflowEngine.addFeedback(
                in: &project, artifactID: artifactID, revisionID: revisionID,
                anchor: anchor, comment: comment, author: author
            )
        }.envelope
        guard let created else {
            throw FloeError.storageCorrupted("feedback missing after CAS")
        }
        return (envelope, created)
    }

    /// Relocates a stale anchor after the user confirms the new location.
    public func relocateAnchor(
        target: DesignTarget, operationID: String, expectedOwnerRevision: Int64?,
        feedbackID: String, anchor: DesignFeedbackAnchor, toRevisionID: String? = nil,
        runID: UUID? = nil
    ) async throws -> DesignOwnerEnvelope {
        try await mutate(
            target: target, operationID: operationID,
            expectedOwnerRevision: expectedOwnerRevision, runID: runID
        ) { project in
            try DesignWorkflowEngine.relocateAnchor(
                in: &project, feedbackID: feedbackID,
                anchor: anchor, toRevisionID: toRevisionID
            )
        }.envelope
    }

    /// Feedback completes ONLY against a verified changing revision; model
    /// text can never resolve it.
    public func resolveFeedback(
        target: DesignTarget, operationID: String, expectedOwnerRevision: Int64?,
        feedbackID: String, resolvedByRevisionID: String,
        runID: UUID? = nil
    ) async throws -> DesignOwnerEnvelope {
        try await mutate(
            target: target, operationID: operationID,
            expectedOwnerRevision: expectedOwnerRevision, runID: runID
        ) { project in
            try DesignWorkflowEngine.resolveFeedback(
                in: &project, feedbackID: feedbackID,
                resolvedByRevisionID: resolvedByRevisionID
            )
        }.envelope
    }

    // MARK: - Candidate proposal

    public struct Proposal: Sendable {
        public let envelope: DesignOwnerEnvelope
        public let candidate: DesignCandidate
        public let payloadRelativePath: String
        /// True when this result is the recorded output of an ALREADY
        /// applied operation (exact idempotent replay), never a fresh
        /// candidate.
        public let replayed: Bool
    }

    /// Canonical, length-prefixed fingerprint of one proposal's exact
    /// semantic inputs. Uses the RESOLVED base revision so a replay that
    /// omitted the optional base still matches its recorded candidate.
    private static func proposalFingerprint(
        artifactID: String,
        baseRevisionID: String,
        payloadFormat: String,
        contentSHA256: String,
        summary: String,
        diff: [String],
        feedbackIDs: [String],
        originConversationID: String?,
        originEnvironmentID: String?
    ) -> String {
        func field(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let parts = [
            field(artifactID),
            field(baseRevisionID),
            field(payloadFormat.lowercased()),
            field(contentSHA256.lowercased()),
            field(summary),
            field(diff.joined(separator: "\u{1E}")),
            field(feedbackIDs.joined(separator: "\u{1E}")),
            field(originConversationID ?? ""),
            field(originEnvironmentID ?? "")
        ]
        return FloeDigest.sha256Hex(Data(parts.joined(separator: "\u{1F}").utf8))
    }

    public func propose(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64?,
        artifactID: String,
        baseRevisionID: String?,
        bytes: Data,
        format: String,
        summary: String,
        diff: [String] = [],
        feedbackIDs: [String] = [],
        runID: UUID? = nil
    ) async throws -> Proposal {
        try Self.requireNonCanvasOwner(target, operation: "propose a candidate")
        guard !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("operationID is required")
        }
        await acquireTargetReservation(target.stableKey)
        defer { releaseTargetReservation(target.stableKey) }
        let digest = FloeDigest.sha256Hex(bytes)
        // LIVE boundary authorization (run/task/environment) before any
        // state or bytes — including replay.
        try await requireAuthorized(target, runID: runID)
        let loaded = try await load(target, createFromSource: false, runID: runID)
        // REPLAY FIRST, before any payload staging. The candidate created by
        // this operation is the exact recorded result, looked up by its
        // recorded operation identity (never "last pending candidate with a
        // matching digest"). Every semantic input must match exactly; a
        // changed bytes/format/artifact/base/summary/feedback/origin is a
        // mismatch — no second candidate, no revision, no orphan payload.
        let recordedCandidate = loaded.envelope.project.candidates.first(where: {
            $0.proposalOperationID == operationID
        })
        if loaded.envelope.project.hasApplied(operationID: operationID) || recordedCandidate != nil {
            guard let candidate = recordedCandidate,
                  candidate.artifactID == artifactID else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            let expectedFingerprint = Self.proposalFingerprint(
                artifactID: artifactID,
                baseRevisionID: baseRevisionID ?? candidate.baseRevisionID,
                payloadFormat: format,
                contentSHA256: digest,
                summary: summary,
                diff: diff,
                feedbackIDs: feedbackIDs,
                originConversationID: target.originConversationID,
                originEnvironmentID: target.environmentID
            )
            guard candidate.proposalFingerprint == expectedFingerprint,
                  let recordedArtifact = loaded.envelope.project.artifact(candidate.artifactID),
                  let recordedRevision = recordedArtifact.revision(candidate.proposedRevisionID),
                  let recordedPayload = recordedRevision.payloadRelativePath else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            return Proposal(
                envelope: loaded.envelope, candidate: candidate,
                payloadRelativePath: recordedPayload, replayed: true
            )
        }
        // A creative START request awaiting its first real result cannot
        // propose revisions yet: generation comes first, then edits.
        if let request = loaded.envelope.project.creativeRequest,
           request.state == .awaitingFirstResult {
            throw DesignTargetError.pendingFirstResult(request.requestedKind.rawValue)
        }
        // The source must also still exist — a deleted attachment/node
        // makes the candidate late and unadoptable.
        guard await targets.exists(target) else {
            throw DesignOwnerWorkflowError.deletedSource
        }
        guard let artifact = loaded.envelope.project.artifact(artifactID) else {
            throw DesignWorkflowError.artifactNotFound(artifactID)
        }
        let formatFamily = DesignContentType.from(format: format)
        // A candidate family from extension alone is routing, not format
        // proof: the real reopen verification happens on adoption/export
        // via `verifyReopen`.
        guard let formatFamily, formatFamily == artifact.contentType else {
            throw DesignTargetError.unavailable(
                "Proposal format '\(format)' does not match the \(artifact.contentType.rawValue) source"
            )
        }
        let revisionID = UUID().uuidString.lowercased()
        let relative: String
        do {
            relative = try payloads.store(
                ownerKey: target.stableKey,
                revisionID: revisionID,
                bytes: bytes,
                expectedContentSHA256: digest
            )
        } catch {
            throw error
        }
        do {
            let envelope = try await mutate(
                target: target, operationID: operationID,
                expectedOwnerRevision: expectedOwnerRevision,
                runID: runID, alreadyReserved: true
            ) { project in
                let created = try DesignWorkflowEngine.proposeCandidate(
                    in: &project,
                    artifactID: artifactID,
                    baseRevisionID: baseRevisionID,
                    proposedContentSHA256: digest,
                    summary: summary,
                    diff: diff,
                    feedbackIDs: feedbackIDs,
                    proposedRevisionID: revisionID,
                    payloadRelativePath: relative,
                    payloadFormat: format,
                    originConversationID: target.originConversationID,
                    originEnvironmentID: target.environmentID
                )
                // The operation record is committed in the SAME envelope CAS
                // as the candidate: replay identity can never diverge from
                // the persisted result.
                if let index = project.candidates.firstIndex(where: { $0.id == created.id }) {
                    project.candidates[index].proposalOperationID = operationID
                    project.candidates[index].proposalFingerprint = Self.proposalFingerprint(
                        artifactID: created.artifactID,
                        baseRevisionID: created.baseRevisionID,
                        payloadFormat: format,
                        contentSHA256: digest,
                        summary: summary,
                        diff: diff,
                        feedbackIDs: feedbackIDs,
                        originConversationID: target.originConversationID,
                        originEnvironmentID: target.environmentID
                    )
                }
            }.envelope
            guard let candidate = envelope.project.candidates.first(where: { $0.proposedRevisionID == revisionID }),
                  candidate.proposalOperationID == operationID else {
                throw FloeError.storageCorrupted("candidate missing after CAS")
            }
            return Proposal(
                envelope: envelope, candidate: candidate,
                payloadRelativePath: relative, replayed: false
            )
        } catch {
            payloads.abandon(ownerKey: target.stableKey, revisionID: revisionID)
            throw error
        }
    }

    // MARK: - Compare

    public struct Comparison: Sendable, Equatable {
        public let candidateID: String
        public let baseSHA256: String
        public let proposedSHA256: String
        public let changed: Bool
        /// Unified-style lines: `+ ` added, `- ` removed, `  ` context.
        /// Bounded (see `diffTruncated`); never content proof (hashes are).
        public let diff: [String]
        /// True when the diff does NOT represent the complete comparison:
        /// an input side exceeded the per-side line cap, the emitted output
        /// exceeded the line cap, or the LCS matrix bound forced a bounded
        /// (non-minimal) block diff. Callers must not present a truncated
        /// diff as the full change set.
        public let diffTruncated: Bool
        /// Honest explanation of the bound/fallback, when any.
        public let diffNote: String?
        public let status: DesignCandidateStatus
    }

    /// Pure compare against retained bytes. Text-family formats include a
    /// bounded line diff; binary formats report digest change only.
    public func compare(
        target: DesignTarget, candidateID: String, runID: UUID? = nil
    ) async throws -> Comparison {
        guard let envelope = try await state(target, runID: runID),
              let candidate = envelope.project.candidate(candidateID),
              let artifact = envelope.project.artifact(candidate.artifactID),
              let base = artifact.revision(candidate.baseRevisionID),
              let proposed = artifact.revision(candidate.proposedRevisionID) else {
            throw DesignWorkflowError.candidateNotFound(candidateID)
        }
        let changed = base.contentSHA256 != proposed.contentSHA256
        var outcome = LineDiffOutcome(lines: [], truncated: false, note: nil)
        if changed, Self.textFormats.contains(proposed.payloadFormat ?? "") {
            let baseBytes = try payloads.verifiedBytes(
                ownerKey: target.stableKey, revisionID: base.id,
                expectedContentSHA256: base.contentSHA256
            )
            let proposedBytes = try payloads.verifiedBytes(
                ownerKey: target.stableKey, revisionID: proposed.id,
                expectedContentSHA256: proposed.contentSHA256
            )
            outcome = Self.lineDiff(
                String(decoding: baseBytes, as: UTF8.self),
                String(decoding: proposedBytes, as: UTF8.self)
            )
        }
        return Comparison(
            candidateID: candidateID,
            baseSHA256: base.contentSHA256,
            proposedSHA256: proposed.contentSHA256,
            changed: changed,
            diff: outcome.lines,
            diffTruncated: outcome.truncated,
            diffNote: outcome.note,
            status: candidate.status
        )
    }

    private static let textFormats: Set<String> = [
        "md", "markdown", "txt", "html", "htm", "svg", "json"
    ]

    /// Result of the bounded text diff. `truncated` is explicit so callers
    /// never present a capped/bounded diff as the complete comparison.
    struct LineDiffOutcome: Sendable, Equatable {
        let lines: [String]
        let truncated: Bool
        let note: String?
    }

    /// Per-side input line cap for the textual compare diff.
    static let lineDiffMaxLinesPerSide = 4_000
    /// Upper bound for LCS DP matrix cells, checked BEFORE any allocation
    /// ((m+1)*(n+1) cells × 4 bytes; ~16 MiB at this cap). Inputs beyond it
    /// take the bounded block-diff path instead of allocating ~128 MiB.
    static let lineDiffMaxMatrixCells = 4_000_000
    /// Output-line cap for the textual diff.
    static let lineDiffMaxOutputLines = 2_000

    /// Empty strings have no lines at all (unlike
    /// `components(separatedBy:)`, which returns one empty component).
    private static func splitLines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// Bounded, correct LCS line diff. Every path is allocation- and
    /// trap-safe: empty inputs take a fast path (no `1...0` range), the DP
    /// matrix is bounded BEFORE allocation, unequal cells take
    /// `max(left, up)` (the exact LCS recurrence — only-equal assignment
    /// produced wrong edit order), and every truncation/fallback is
    /// reported explicitly. Output is unified-style: `  ` context keeps
    /// insertions anchored so the emitted script applies deterministically.
    static func lineDiff(_ oldText: String, _ newText: String) -> LineDiffOutcome {
        var oldLines = splitLines(oldText)
        var newLines = splitLines(newText)
        var truncated = false
        var note: String?
        if oldLines.count > lineDiffMaxLinesPerSide {
            oldLines = Array(oldLines.prefix(lineDiffMaxLinesPerSide))
            truncated = true
        }
        if newLines.count > lineDiffMaxLinesPerSide {
            newLines = Array(newLines.prefix(lineDiffMaxLinesPerSide))
            truncated = true
        }
        if truncated {
            note = "input capped at \(lineDiffMaxLinesPerSide) lines per side"
        }
        let m = oldLines.count
        let n = newLines.count
        // Empty fast paths (never reach a closed-range loop).
        if m == 0 && n == 0 {
            return LineDiffOutcome(lines: [], truncated: truncated, note: note)
        }
        if m == 0 {
            let bounded = limitedLines(
                newLines.map { "+ \($0)" },
                truncated: &truncated, note: &note,
                reason: "output capped at \(lineDiffMaxOutputLines) diff lines"
            )
            return LineDiffOutcome(lines: bounded, truncated: truncated, note: note)
        }
        if n == 0 {
            let bounded = limitedLines(
                oldLines.map { "- \($0)" },
                truncated: &truncated, note: &note,
                reason: "output capped at \(lineDiffMaxOutputLines) diff lines"
            )
            return LineDiffOutcome(lines: bounded, truncated: truncated, note: note)
        }
        // Bounded preallocation: check the matrix size BEFORE allocating.
        let cells = (m + 1) * (n + 1)
        guard cells <= lineDiffMaxMatrixCells else {
            return boundedBlockDiff(
                oldLines, newLines,
                inputTruncated: truncated, cells: cells, note: note
            )
        }
        let rowLength = n + 1
        var dp = [UInt32](repeating: 0, count: cells)
        for i in 1...m {
            let row = i * rowLength
            let previous = row - rowLength
            for j in 1...n {
                if oldLines[i - 1] == newLines[j - 1] {
                    dp[row + j] = dp[previous + j - 1] + 1
                } else {
                    // Exact LCS recurrence: a mismatch must take the best
                    // reachable subsequence, not leave the cell at zero.
                    dp[row + j] = max(dp[previous + j], dp[row + j - 1])
                }
            }
        }
        var reversedLines: [String] = []
        reversedLines.reserveCapacity(m + n)
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, oldLines[i - 1] == newLines[j - 1] {
                reversedLines.append("  \(oldLines[i - 1])")
                i -= 1; j -= 1
            } else if j > 0, i == 0 || dp[(i - 1) * rowLength + j] <= dp[i * rowLength + (j - 1)] {
                reversedLines.append("+ \(newLines[j - 1])")
                j -= 1
            } else if i > 0 {
                reversedLines.append("- \(oldLines[i - 1])")
                i -= 1
            }
        }
        var lines = Array(reversedLines.reversed())
        if lines.count > lineDiffMaxOutputLines {
            lines = Array(lines.prefix(lineDiffMaxOutputLines))
            truncated = true
            note = "output capped at \(lineDiffMaxOutputLines) diff lines"
        }
        return LineDiffOutcome(lines: lines, truncated: truncated, note: note)
    }

    private static func limitedLines(
        _ lines: [String],
        truncated: inout Bool,
        note: inout String?,
        reason: String
    ) -> [String] {
        guard lines.count > lineDiffMaxOutputLines else { return lines }
        truncated = true
        note = reason
        return Array(lines.prefix(lineDiffMaxOutputLines))
    }

    /// Fallback for inputs whose LCS matrix would exceed the allocation
    /// bound: trims the common prefix/suffix and emits the remaining middle
    /// as one removal block followed by one addition block. This is a valid
    /// (not minimal) transformation of the whole input, and is explicitly
    /// marked truncated so it is never mistaken for the exact LCS diff.
    private static func boundedBlockDiff(
        _ oldLines: [String],
        _ newLines: [String],
        inputTruncated: Bool,
        cells: Int,
        note: String?
    ) -> LineDiffOutcome {
        let m = oldLines.count, n = newLines.count
        var prefix = 0
        let common = min(m, n)
        while prefix < common, oldLines[prefix] == newLines[prefix] { prefix += 1 }
        if prefix == m, prefix == n {
            // The (possibly input-capped) sides are identical: the diff is
            // empty and exact; only an input cap can make it partial.
            return LineDiffOutcome(lines: [], truncated: inputTruncated, note: note)
        }
        var suffix = 0
        while suffix < (common - prefix),
              oldLines[m - 1 - suffix] == newLines[n - 1 - suffix] { suffix += 1 }
        var lines: [String] = []
        lines.reserveCapacity((m - prefix - suffix) + (n - prefix - suffix))
        if prefix + suffix < m {
            for index in prefix..<(m - suffix) { lines.append("- \(oldLines[index])") }
        }
        if prefix + suffix < n {
            for index in prefix..<(n - suffix) { lines.append("+ \(newLines[index])") }
        }
        var truncated = inputTruncated
        let fallbackNote = "LCS matrix bound exceeded (\(cells) cells > \(lineDiffMaxMatrixCells)); emitted a bounded block diff"
        var finalNote = note.map { "\($0); \(fallbackNote)" } ?? fallbackNote
        if lines.count > lineDiffMaxOutputLines {
            lines = Array(lines.prefix(lineDiffMaxOutputLines))
            truncated = true
            finalNote = "output capped at \(lineDiffMaxOutputLines) diff lines; \(fallbackNote)"
        }
        // The block fallback is never presented as an exact LCS diff.
        truncated = true
        return LineDiffOutcome(lines: lines, truncated: truncated, note: finalNote)
    }

    // MARK: - Decision (adopt / reject)

    public struct DecisionResult: Sendable {
        public let envelope: DesignOwnerEnvelope
        public let replayed: Bool
        /// Honest delivery state. `.pending` keeps the durable intent for
        /// reconcile; it is never reported as delivered.
        public let delivery: DesignDecisionDelivery
        /// Honest result-publication state for immutable owners (chat /
        /// creative): `.pending` means the user-approved result has NOT been
        /// returned to its owner destination yet and the durable decision
        /// record stays open for reconcile. `.notRequired` means the owner
        /// source itself was updated in place (verified commit).
        public let publication: DesignResultPublicationOutcome
        /// New owner revision token after an in-place commit, when any.
        public let committedRevisionToken: String?

        /// Compatibility accessor: non-nil only while delivery is pending.
        public var deliveryError: String? { delivery.errorDescription }

        /// Compatibility accessor: non-nil only while publication is pending.
        public var publicationError: String? { publication.errorDescription }
    }

    /// Looks up (or durably prepares) the intent for one target decision and
    /// attempts delivery, returning the HONEST state. A sink failure or an
    /// acknowledgement failure leaves the record pending; only a successful
    /// idempotent sink call is acknowledged.
    private func resolveTargetDecision(
        target: DesignTarget,
        operationID: String,
        candidateID: String,
        decision: String,
        mode: String?,
        baseRevisionID: String?,
        originRaw: String?,
        origin: UUID?,
        ownerRevision: Int64,
        contentSHA256: String?,
        sink: DesignOwnerDecisionSink?,
        persistIfMissing: Bool,
        settle: Bool = true
    ) async -> DesignDecisionDelivery {
        let desired = DesignDecisionIntent.forTarget(
            target, candidateID: candidateID,
            conversationID: originRaw ?? "",
            decision: decision, operationID: operationID,
            mode: mode, baseRevisionID: baseRevisionID,
            proposedContentSHA256: contentSHA256,
            frozenBaseToken: target.revision
        )
        let intent: DesignDecisionIntent
        if let existing = await outbox.record(fingerprint: desired.fingerprint) {
            intent = existing
        } else if origin == nil {
            // No originating task and no crash-recovery record: nothing to
            // track and nothing to notify.
            return .notRequired
        } else if persistIfMissing {
            do {
                intent = try await outbox.prepare(desired)
            } catch {
                return .pending("the durable decision record could not be persisted: \(error.localizedDescription)")
            }
        } else {
            return .pending("no durable decision record exists for this operation")
        }
        switch intent.phase {
        case .recorded:
            return origin == nil ? .notRequired : .delivered
        case .cancelled:
            return .pending("the durable decision was cancelled and will not be re-delivered")
        case .committing:
            break
        }
        guard let origin, let originRaw, !originRaw.isEmpty else {
            // No originating task: the record exists only so a crash between
            // an in-place source write and the metadata CAS is recoverable.
            // The operation is confirmed applied now, so it settles here —
            // UNLESS result publication is still pending for an immutable
            // owner, in which case the record must stay open for reconcile.
            if settle { try? await outbox.markDelivered(id: intent.id) }
            return .notRequired
        }
        guard let sink else {
            return .pending("no decision sink is configured; the decision stays pending in the durable outbox")
        }
        guard let candidateUUID = UUID(uuidString: candidateID) else {
            return .pending("candidate id '\(candidateID)' is not a deliverable identity")
        }
        do {
            try await sink(origin, candidateUUID, decision, ownerRevision, contentSHA256)
        } catch {
            return .pending("delivery to the original task failed: \(error.localizedDescription)")
        }
        do {
            // The record is acknowledged only when BOTH the notice was
            // accepted and (for immutable owners) the adopted result was
            // actually published; otherwise it stays pending so reconcile
            // retries the publication.
            if settle {
                try await outbox.markDelivered(id: intent.id)
            }
            return .delivered
        } catch {
            // The event was accepted by the idempotent sink but could not be
            // acknowledged; the record stays pending so reconcile retries.
            return .pending("delivered, but the durable acknowledgement failed: \(error.localizedDescription)")
        }
    }

    /// Builds and performs the result publication for one applied adoption.
    /// NEVER throws: a publication failure happens AFTER the owner CAS, so
    /// the applied metadata must survive; the honest `.pending` outcome and
    /// the still-open durable record let reconcile retry the idempotent
    /// handoff.
    private func publishAdoptedResult(
        publisher: DesignResultPublicationPort,
        target: DesignTarget,
        operationID: String,
        candidateID: String,
        artifact: DesignArtifact,
        proposed: DesignRevision,
        mode: DesignAdoptMode,
        originRaw: String?,
        ownerRevision: Int64
    ) async -> DesignResultPublicationOutcome {
        guard let relative = proposed.payloadRelativePath else {
            return .pending("the adopted revision has no retained payload to publish")
        }
        let bytes: Data
        do {
            bytes = try payloads.verifiedBytes(
                ownerKey: target.stableKey,
                revisionID: proposed.id,
                expectedContentSHA256: proposed.contentSHA256
            )
        } catch {
            return .pending(
                "the adopted revision payload could not be read back for publication: \(error.localizedDescription)"
            )
        }
        let publication = DesignResultPublication(
            target: target,
            targetStableKey: target.stableKey,
            operationID: operationID,
            candidateID: candidateID,
            mode: mode,
            artifactID: artifact.id,
            revisionID: proposed.id,
            payloadRelativePath: relative,
            contentSHA256: proposed.contentSHA256,
            format: proposed.payloadFormat ?? "bin",
            displayName: artifact.identity.name,
            originConversationID: originRaw,
            ownerRevision: ownerRevision,
            bytes: bytes
        )
        do {
            let receipt = try await publisher.publish(publication)
            return .published(receipt)
        } catch {
            return .pending("result publication failed: \(error.localizedDescription)")
        }
    }

    /// Publication outcome for an ALREADY APPLIED adoption (replay/reconcile).
    /// An idempotent republish returns the original receipt; a missing port
    /// is reported as outstanding rather than fabricated success.
    private func replayPublicationOutcome(
        target: DesignTarget,
        effectivePublication: DesignResultPublicationPort?,
        operationID: String,
        candidateID: String,
        artifact: DesignArtifact,
        proposed: DesignRevision,
        mode: DesignAdoptMode,
        originRaw: String?,
        ownerRevision: Int64,
        committedInPlace: Bool
    ) async -> DesignResultPublicationOutcome {
        guard Self.requiresResultPublication(target) else {
            return .notRequired(
                Self.publicationNotRequiredReason(
                    target, mode: mode, committedInPlace: committedInPlace
                )
            )
        }
        guard let publisher = effectivePublication else {
            return .pending(
                "no result-publication port is configured; the adopted result has not been returned to its owner destination (T6 integration gate)"
            )
        }
        return await publishAdoptedResult(
            publisher: publisher, target: target, operationID: operationID,
            candidateID: candidateID, artifact: artifact, proposed: proposed,
            mode: mode, originRaw: originRaw, ownerRevision: ownerRevision
        )
    }

    private static func publicationNotRequiredReason(
        _ target: DesignTarget,
        mode: DesignAdoptMode,
        committedInPlace: Bool
    ) -> String {
        if committedInPlace {
            return "the owner source was updated in place (verified commit); the result IS the source"
        }
        if target.kind == .fileDocument {
            return "no separate destination exists for a \(mode.rawValue) file result; export it through exportVerified"
        }
        return "no separate result publication exists for \(target.kind.rawValue)"
    }

    public func adopt(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64,
        candidateID: String,
        mode: DesignAdoptMode = .updateOriginal,
        runID: UUID? = nil,
        claimAuthorization: (@Sendable () async throws -> Void)? = nil,
        verifyReopen: @Sendable (Data, String, DesignContentType) async throws -> Void,
        sink: DesignOwnerDecisionSink? = nil,
        publication: DesignResultPublicationPort? = nil
    ) async throws -> DecisionResult {
        await acquireTargetReservation(target.stableKey)
        defer { releaseTargetReservation(target.stableKey) }
        return try await adoptLocked(
            target: target, operationID: operationID,
            expectedOwnerRevision: expectedOwnerRevision, candidateID: candidateID,
            mode: mode, runID: runID, claimAuthorization: claimAuthorization,
            verifyReopen: verifyReopen, sink: sink,
            publication: publication
        )
    }

    private func adoptLocked(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64,
        candidateID: String,
        mode: DesignAdoptMode,
        runID: UUID?,
        claimAuthorization: (@Sendable () async throws -> Void)?,
        verifyReopen: @Sendable (Data, String, DesignContentType) async throws -> Void,
        sink: DesignOwnerDecisionSink?,
        publication: DesignResultPublicationPort? = nil
    ) async throws -> DecisionResult {
        let key = target.stableKey
        guard let envelope = try await state(target, runID: runID),
              let candidate = envelope.project.candidate(candidateID),
              let artifact = envelope.project.artifact(candidate.artifactID),
              let proposed = artifact.revision(candidate.proposedRevisionID) else {
            throw DesignWorkflowError.candidateNotFound(candidateID)
        }
        let originRaw = candidate.originConversationID ?? target.originConversationID
        let origin: UUID? = originRaw.flatMap { UUID(uuidString: $0) }
        if originRaw != nil, origin == nil {
            throw FloeError.validationFailed("The recorded originating task is not a valid identity")
        }
        let effectiveSink = sink ?? defaultSink
        let effectivePublication = publication ?? defaultPublication
        // Replay first, but a replay of an already-applied decision whose
        // durable intent is still pending RETRIES delivery: it is never
        // silently reported as notified. An immutable-owner result is
        // republished through the idempotent handoff (same receipt, never a
        // second attachment/asset).
        if envelope.project.hasApplied(operationID: operationID) {
            guard candidate.status == .adopted else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            // The adopted mode is part of the operation identity: the same
            // operationID replayed with a different mode is a mismatch, not
            // a second, silent adoption.
            let recordedMode: DesignAdoptMode = candidate.variantArtifactID == nil
                ? .updateOriginal : .variant
            guard recordedMode == mode else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            let publicationOutcome = await replayPublicationOutcome(
                target: target, effectivePublication: effectivePublication,
                operationID: operationID, candidateID: candidateID,
                artifact: artifact, proposed: proposed, mode: mode,
                originRaw: originRaw, ownerRevision: envelope.revision,
                committedInPlace: false
            )
            let delivery = await resolveTargetDecision(
                target: target, operationID: operationID, candidateID: candidateID,
                decision: "adopted", mode: mode.rawValue,
                baseRevisionID: candidate.baseRevisionID,
                originRaw: originRaw, origin: origin,
                ownerRevision: envelope.revision,
                contentSHA256: proposed.contentSHA256,
                sink: effectiveSink, persistIfMissing: true,
                settle: !publicationOutcome.isPending
            )
            return .init(
                envelope: envelope, replayed: true, delivery: delivery,
                publication: publicationOutcome, committedRevisionToken: nil
            )
        }
        guard candidate.status == .pending else {
            throw DesignWorkflowError.operationAlreadyApplied(candidateID)
        }
        // Immutable owners MUST have a publication route BEFORE anything is
        // adopted: a successful CAS whose result is never returned would be
        // exactly the metadata-with-a-notice failure this gate forbids. No
        // state changes have happened at this point.
        let publicationRequired = Self.requiresResultPublication(target)
        if publicationRequired, effectivePublication == nil {
            throw DesignOwnerWorkflowError.resultPublicationUnavailable(
                "adopting a \(target.kind.rawValue) result requires a result-publication port so the new result is returned to its owner destination; none is configured (T6 integration gate)"
            )
        }
        // Pre-flight the owner CAS BEFORE any in-place commit. The
        // same-target reservation makes this a real barrier: no local
        // mutation of this target can move the owner revision between this
        // check and the CAS below (the commit port independently re-gates on
        // the source digest).
        if envelope.revision != expectedOwnerRevision {
            throw DesignOwnerWorkflowError.ownerConflict(
                expected: expectedOwnerRevision, actual: envelope.revision
            )
        }
        // LATE CANDIDATE: a concurrent manual edit moved the artifact past
        // the candidate's base. Adoption update-original must never
        // overwrite the newer edit; the caller compares/rebases or rejects.
        if mode == .updateOriginal,
           let current = artifact.currentRevisionID,
           current != candidate.baseRevisionID {
            throw DesignWorkflowError.revisionConflict(
                expected: candidate.baseRevisionID, actual: current
            )
        }
        // The source must still exist AND remain authorized for this
        // caller for an update-original adoption.
        try await requireAuthorized(target, runID: runID)
        guard await targets.exists(target) else {
            throw DesignOwnerWorkflowError.deletedSource
        }
        // Variant adoption creates a branch artifact without touching the
        // owner source; update-original on a read-only owner retains the
        // revision here and delivers it (never overwrites the original).
        let inPlace = mode == .updateOriginal
            && target.kind != .chatAttachment
            && target.kind != .creativeDocument
            && commitPorts[target.kind]?.canCommit(target) == true
        guard let relative = proposed.payloadRelativePath else {
            throw DesignOwnerWorkflowError.missingPayload(proposed.id)
        }
        let bytes = try payloads.verifiedBytes(
            ownerKey: key, revisionID: proposed.id,
            expectedContentSHA256: proposed.contentSHA256
        )
        // A connected verifier is REQUIRED. Digest equality alone is
        // integrity, not format proof; an unconnected/unsupported format or
        // malformed bytes must abort here with ZERO adopted state. The
        // caller supplies the owner adapter's real reopen parser.
        try await verifyReopen(bytes, proposed.payloadFormat ?? "bin", artifact.contentType)

        // ATOMIC USER-CONFIRMATION CLAIM, exactly here: every pre-flight
        // check (replay, pending status, publication gate, owner revision,
        // late candidate, live authorization, source existence, payload
        // read, format reopen) has passed, and NO side effect has happened
        // yet. The injected claim claims (burns) the single-use confirmation
        // through the existing approval-grant store in ONE actor call before
        // the first durable intent or owner write; a revoked/expired/
        // already-claimed/mismatched grant throws here with zero side
        // effects, and a proven-zero-write failure after this point requires
        // a FRESH confirmation (never a silently re-armed grant). A replay
        // of an applied operation returned above and never reaches this
        // claim.
        if let claimAuthorization {
            try await claimAuthorization()
        }

        // Durable intent BEFORE any source write. An in-place commit persists
        // one even without an originating task (recover the source-written /
        // metadata-pending gap); origin-bearing decisions persist for
        // delivery. Persistence failure aborts before the source is touched.
        let prepared: DesignDecisionIntent?
        if inPlace || origin != nil {
            let intent = DesignDecisionIntent.forTarget(
                target,
                candidateID: candidateID,
                conversationID: originRaw ?? "",
                decision: "adopted",
                operationID: operationID,
                mode: mode.rawValue,
                baseRevisionID: candidate.baseRevisionID,
                proposedContentSHA256: proposed.contentSHA256,
                frozenBaseToken: target.revision
            )
            let result = try await outbox.prepareIfNew(intent)
            if !result.isNew, result.intent.phase == .recorded {
                // A previous attempt completed AND settled; strict replay.
                // Under the settlement invariant an immutable-owner result
                // was published before the record was acknowledged; a
                // configured port reconfirms the SAME destination identity.
                let publicationOutcome = await replayPublicationOutcome(
                    target: target, effectivePublication: effectivePublication,
                    operationID: operationID, candidateID: candidateID,
                    artifact: artifact, proposed: proposed, mode: mode,
                    originRaw: originRaw, ownerRevision: envelope.revision,
                    committedInPlace: false
                )
                return .init(
                    envelope: envelope, replayed: true,
                    delivery: origin == nil ? .notRequired : .delivered,
                    publication: publicationOutcome,
                    committedRevisionToken: nil
                )
            }
            if result.intent.phase == .cancelled {
                // A previous attempt was cancelled as never-committed; this
                // retry is about to commit the same operation, so delivery is
                // owed again (reopened durably BEFORE the source write).
                try await outbox.reopen(id: result.intent.id)
                prepared = await outbox.record(fingerprint: intent.fingerprint)
            } else {
                prepared = result.intent
            }
        } else {
            prepared = nil
        }

        var committedToken: String?
        if inPlace, let commitPort = commitPorts[target.kind] {
            // In-place writes require the FROZEN base token captured at
            // resolve time; without it there is no optimistic gate, so the
            // commit fails closed rather than overwriting.
            guard let baseToken = target.revision, !baseToken.isEmpty else {
                await cancelFreshIntent(prepared)
                throw DesignTargetError.invalidReference(
                    "in-place adoption requires the frozen base revision token"
                )
            }
            do {
                committedToken = try await commitPort.commit(
                    target: target,
                    reference: target.sourceID,
                    bytes: bytes,
                    format: proposed.payloadFormat ?? "bin",
                    baseRevisionToken: baseToken
                )
            } catch {
                if Self.isProvenUncommitted(error) {
                    // The port proved nothing was written: the fresh intent
                    // is a clean cancel (nothing recoverable).
                    await cancelFreshIntent(prepared)
                    throw error
                }
                // The write may have landed: NEVER cancel; the durable
                // intent stays pending for reconcile.
                throw DesignOwnerWorkflowError.adoptionPendingRecovery(
                    operationID: operationID,
                    reason: "the source commit did not report success and may have written bytes: \(error.localizedDescription)"
                )
            }
            // READBACK before the metadata is allowed to mark applied: the
            // bytes actually present at the source must hash to the proposed
            // digest, not merely the bytes we handed to the writer.
            do {
                let verification = try await commitPort.verify(
                    target: target, reference: target.sourceID,
                    proposedContentSHA256: proposed.contentSHA256,
                    baseRevisionToken: baseToken
                )
                guard verification == .matchesProposed else {
                    throw DesignOwnerCommitError.unknown(
                        "source readback did not show the proposed bytes: \(verification)"
                    )
                }
            } catch {
                throw DesignOwnerWorkflowError.adoptionPendingRecovery(
                    operationID: operationID,
                    reason: "the source commit readback could not verify the proposed bytes: \(error.localizedDescription)"
                )
            }
        }

        let updated: DesignOwnerEnvelope
        do {
            updated = try await mutate(
                target: target, operationID: operationID,
                expectedOwnerRevision: expectedOwnerRevision,
                runID: runID, alreadyReserved: true
            ) { project in
                _ = try DesignWorkflowEngine.adoptCandidate(
                    in: &project, candidateID: candidateID, mode: mode
                )
            }.envelope
        } catch {
            if committedToken != nil {
                // Source written, metadata not: retain the durable intent so
                // reconcile can finish against the ACTUAL source bytes.
                throw DesignOwnerWorkflowError.adoptionPendingRecovery(
                    operationID: operationID,
                    reason: "the source commit succeeded but the owner metadata CAS failed: \(error.localizedDescription)"
                )
            }
            // No source write was performed: a fresh intent is a clean
            // cancel (a decision that never committed must not deliver).
            await cancelFreshIntent(prepared)
            throw error
        }
        // The adopted result is RETURNED to its owner destination BEFORE the
        // decision is settled. For immutable owners a pending publication
        // keeps the durable record open (settle == false) so reconcile can
        // retry the idempotent handoff; the notice to the originating task
        // is still attempted (the ingress upserts/dedupes).
        let publicationOutcome: DesignResultPublicationOutcome
        if publicationRequired, let publisher = effectivePublication {
            publicationOutcome = await publishAdoptedResult(
                publisher: publisher, target: target, operationID: operationID,
                candidateID: candidateID, artifact: artifact, proposed: proposed,
                mode: mode, originRaw: originRaw, ownerRevision: updated.revision
            )
        } else {
            publicationOutcome = .notRequired(
                Self.publicationNotRequiredReason(
                    target, mode: mode, committedInPlace: committedToken != nil
                )
            )
        }
        let settle = !publicationOutcome.isPending
        // Durable delivery to the ORIGINAL task; ack only on an actual
        // idempotent sink success. Records that exist only for in-place
        // crash recovery (no originating task) settle here.
        let delivery: DesignDecisionDelivery
        if origin == nil {
            if settle, let prepared { try? await outbox.markDelivered(id: prepared.id) }
            delivery = .notRequired
        } else {
            delivery = await resolveTargetDecision(
                target: target, operationID: operationID, candidateID: candidateID,
                decision: "adopted", mode: mode.rawValue,
                baseRevisionID: candidate.baseRevisionID,
                originRaw: originRaw, origin: origin,
                ownerRevision: updated.revision,
                contentSHA256: proposed.contentSHA256,
                sink: effectiveSink, persistIfMissing: false,
                settle: settle
            )
        }
        return .init(
            envelope: updated, replayed: false,
            delivery: delivery, publication: publicationOutcome,
            committedRevisionToken: committedToken
        )
    }

    public func reject(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64,
        candidateID: String,
        runID: UUID? = nil,
        sink: DesignOwnerDecisionSink? = nil
    ) async throws -> DecisionResult {
        await acquireTargetReservation(target.stableKey)
        defer { releaseTargetReservation(target.stableKey) }
        return try await rejectLocked(
            target: target, operationID: operationID,
            expectedOwnerRevision: expectedOwnerRevision, candidateID: candidateID,
            runID: runID, sink: sink
        )
    }

    private func rejectLocked(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64,
        candidateID: String,
        runID: UUID?,
        sink: DesignOwnerDecisionSink?
    ) async throws -> DecisionResult {
        try await requireAuthorized(target, runID: runID)
        guard let envelope = try await state(target, runID: runID),
              let candidate = envelope.project.candidate(candidateID) else {
            throw DesignWorkflowError.candidateNotFound(candidateID)
        }
        let originRaw = candidate.originConversationID ?? target.originConversationID
        let origin: UUID? = originRaw.flatMap { UUID(uuidString: $0) }
        if originRaw != nil, origin == nil {
            throw FloeError.validationFailed("The recorded originating task is not a valid identity")
        }
        let effectiveSink = sink ?? defaultSink
        let proposedSHA = envelope.project.artifacts
            .flatMap(\.revisions)
            .first { $0.id == candidate.proposedRevisionID }?.contentSHA256
        // Replay first, retrying a still-pending durable delivery instead of
        // claiming it was notified.
        if envelope.project.hasApplied(operationID: operationID) {
            guard envelope.project.candidate(candidateID)?.status == .rejected else {
                throw DesignOwnerWorkflowError.replayMismatch(operationID)
            }
            let delivery = await resolveTargetDecision(
                target: target, operationID: operationID, candidateID: candidateID,
                decision: "rejected", mode: nil,
                baseRevisionID: candidate.baseRevisionID,
                originRaw: originRaw, origin: origin,
                ownerRevision: envelope.revision,
                contentSHA256: proposedSHA,
                sink: effectiveSink, persistIfMissing: true
            )
            return .init(
                envelope: envelope, replayed: true, delivery: delivery,
                publication: .notRequired("a rejection returns no result"),
                committedRevisionToken: nil
            )
        }
        let prepared: DesignDecisionIntent?
        if let originRaw, let origin {
            let intent = DesignDecisionIntent.forTarget(
                target,
                candidateID: candidateID,
                conversationID: originRaw,
                decision: "rejected",
                operationID: operationID,
                baseRevisionID: candidate.baseRevisionID
            )
            let result = try await outbox.prepareIfNew(intent)
            if !result.isNew, result.intent.phase == .recorded {
                return .init(
                    envelope: envelope, replayed: true, delivery: .delivered,
                    publication: .notRequired("a rejection returns no result"),
                    committedRevisionToken: nil
                )
            }
            if result.intent.phase == .cancelled {
                // A retried rejection re-owes delivery after a clean cancel.
                try await outbox.reopen(id: result.intent.id)
                prepared = await outbox.record(fingerprint: intent.fingerprint)
            } else {
                prepared = result.intent
            }
        } else {
            prepared = nil
        }
        let updated: DesignOwnerEnvelope
        do {
            updated = try await mutate(
                target: target, operationID: operationID,
                expectedOwnerRevision: expectedOwnerRevision,
                runID: runID, alreadyReserved: true
            ) { project in
                try DesignWorkflowEngine.rejectCandidate(in: &project, candidateID: candidateID)
            }.envelope
        } catch {
            // A rejection never writes owner bytes: a failed CAS is a clean
            // cancel of the fresh intent.
            await cancelFreshIntent(prepared)
            throw error
        }
        let delivery = await resolveTargetDecision(
            target: target, operationID: operationID, candidateID: candidateID,
            decision: "rejected", mode: nil,
            baseRevisionID: candidate.baseRevisionID,
            originRaw: originRaw, origin: origin,
            ownerRevision: updated.revision,
            contentSHA256: proposedSHA,
            sink: effectiveSink, persistIfMissing: false
        )
        return .init(
            envelope: updated, replayed: false, delivery: delivery,
            publication: .notRequired("a rejection returns no result"),
            committedRevisionToken: nil
        )
    }

    // MARK: - Target decision reconcile (after restart/crash)

    public enum DesignDecisionReconcileOutcome: Sendable, Equatable {
        /// The operation is confirmed applied (possibly resumed now);
        /// `delivery` reports the honest delivery state.
        case completed(DesignDecisionDelivery)
        /// The operation provably never committed and there is no
        /// recoverable source write; the durable intent may be cancelled.
        case notCommitted
        /// Recovery is still needed (source bytes may exist, permission was
        /// revoked, or the metadata conflicts). The durable intent MUST stay
        /// pending; the string is the honest reason.
        case retained(String)
    }

    /// Reconciles ONE pending target decision after a crash/relaunch.
    ///
    /// Unlike the canvas reconcile closure this inspects the ACTUAL owner
    /// source before deciding: a source already carrying the verified
    /// proposed bytes is resumed to completion (CAS + delivery) rather than
    /// cancelled because an operation record is absent; a source the user
    /// edited away is preserved and the decision retained. Authorization is
    /// re-checked live, and a revoked caller never cancels the durable
    /// record. Canvas-owned intents use the canvas reconcile path instead.
    public func reconcilePendingAdoption(
        _ intent: DesignDecisionIntent,
        runID: UUID? = nil,
        verifyReopen: @Sendable (Data, String, DesignContentType) async throws -> Void,
        sink: DesignOwnerDecisionSink? = nil,
        publication: DesignResultPublicationPort? = nil
    ) async throws -> DesignDecisionReconcileOutcome {
        guard let target = intent.target, target.kind != .canvasNode else {
            throw DesignOwnerWorkflowError.canvasRequiresCanvasAuthority(
                "Canvas-owned decisions use the canvas reconcile path; the generic owner workflow never reconciles Canvas metadata"
            )
        }
        switch intent.phase {
        case .recorded:
            return .completed(intent.conversationID.isEmpty ? .notRequired : .delivered)
        case .cancelled:
            // Explicitly cancelled earlier: the operation never committed.
            return .notCommitted
        case .committing:
            break
        }
        await acquireTargetReservation(target.stableKey)
        defer { releaseTargetReservation(target.stableKey) }
        guard await targets.authorize(target, runID: runID) else {
            return .retained("the caller is no longer authorized for \(target.displayID)")
        }
        guard let envelope = try await store.load(targetKey: target.stableKey) else {
            return .retained("the owner envelope is missing; committed source bytes cannot be reconciled")
        }
        if envelope.project.hasApplied(operationID: intent.operationID) {
            let proposedSHA = envelope.project.artifacts
                .flatMap(\.revisions)
                .first { $0.id == envelope.project.candidate(intent.candidateID)?.proposedRevisionID }?
                .contentSHA256
            // Immutable owners: the adopted result must be RETURNED to its
            // destination before the record can settle. The republish is
            // idempotent (same receipt, never a second attachment/asset); a
            // missing port keeps the durable record pending instead of
            // claiming completion.
            if Self.requiresResultPublication(target) {
                guard let candidate = envelope.project.candidate(intent.candidateID),
                      let artifact = envelope.project.artifact(candidate.artifactID),
                      let proposed = artifact.revision(candidate.proposedRevisionID) else {
                    return .retained(
                        "the advertised candidate payload is missing; the result publication cannot be reconfirmed"
                    )
                }
                guard let publisher = publication ?? defaultPublication else {
                    return .retained(
                        "the adopted result has not been returned (no result-publication port is configured); the durable record stays pending"
                    )
                }
                let mode = intent.mode.flatMap(DesignAdoptMode.init(rawValue:)) ?? .updateOriginal
                let outcome = await publishAdoptedResult(
                    publisher: publisher, target: target,
                    operationID: intent.operationID, candidateID: intent.candidateID,
                    artifact: artifact, proposed: proposed, mode: mode,
                    originRaw: intent.conversationID.isEmpty ? nil : intent.conversationID,
                    ownerRevision: envelope.revision
                )
                if case .pending(let reason) = outcome {
                    return .retained("the adopted result is not published: \(reason)")
                }
            }
            let delivery = await resolveTargetDecision(
                target: target, operationID: intent.operationID,
                candidateID: intent.candidateID, decision: intent.decision,
                mode: intent.mode, baseRevisionID: intent.baseRevisionID,
                originRaw: intent.conversationID.isEmpty ? nil : intent.conversationID,
                origin: UUID(uuidString: intent.conversationID),
                ownerRevision: envelope.revision,
                contentSHA256: proposedSHA,
                sink: sink ?? defaultSink,
                persistIfMissing: false
            )
            return .completed(delivery)
        }
        if intent.decision != "adopted" {
            // A rejection never writes owner bytes; without the applied
            // operation record it provably never committed.
            return .notCommitted
        }
        guard let candidate = envelope.project.candidate(intent.candidateID),
              let artifact = envelope.project.artifact(candidate.artifactID),
              let proposed = artifact.revision(candidate.proposedRevisionID) else {
            return .retained("the proposed candidate payload no longer exists")
        }
        let mode = intent.mode.flatMap(DesignAdoptMode.init(rawValue:)) ?? .updateOriginal
        let inPlace = mode == .updateOriginal
            && target.kind != .chatAttachment
            && target.kind != .creativeDocument
            && commitPorts[target.kind]?.canCommit(target) == true
        guard inPlace, let commitPort = commitPorts[target.kind] else {
            // Read-only owners have no source write; an unapplied operation
            // did not commit. Retain so a later retry can settle it.
            return .retained("the adoption is not applied; retry it with the same operationID")
        }
        guard let baseToken = intent.frozenBaseToken ?? target.revision, !baseToken.isEmpty else {
            return .retained("no frozen base token is recorded; the source cannot be reconciled safely")
        }
        let verification: DesignCommitVerification
        do {
            verification = try await commitPort.verify(
                target: target, reference: target.sourceID,
                proposedContentSHA256: proposed.contentSHA256,
                baseRevisionToken: baseToken
            )
        } catch {
            return .retained("the source could not be read for reconcile: \(error.localizedDescription)")
        }
        switch verification {
        case .missing:
            return .retained("the owner source no longer exists; the decision is retained")
        case .diverged(let actual):
            return .retained("the owner source diverged (actual \(actual)); the user edit is preserved")
        case .matchesProposed, .matchesBase:
            break
        }
        // The source either already carries the proposed bytes (the write
        // landed before the crash) or is still untouched at its frozen base.
        // Resume the ordinary adoption: it re-gates the commit on the frozen
        // digest, performs the single metadata CAS, and delivers durably.
        do {
            let result = try await adoptLocked(
                target: target.freezing(revision: baseToken),
                operationID: intent.operationID,
                expectedOwnerRevision: envelope.revision,
                candidateID: intent.candidateID,
                mode: mode,
                runID: runID,
                claimAuthorization: nil,
                verifyReopen: verifyReopen,
                sink: sink,
                publication: publication
            )
            return .completed(result.delivery)
        } catch {
            if let ownerError = error as? DesignOwnerWorkflowError,
               case .adoptionPendingRecovery = ownerError {
                return .retained("recovery did not complete: \(error.localizedDescription)")
            }
            // adoptLocked cancels only proven-uncommitted work; report the
            // durable record's real state instead of guessing.
            if let record = await outbox.record(fingerprint: intent.fingerprint),
               record.phase == .committing {
                return .retained("recovery did not complete: \(error.localizedDescription)")
            }
            return .notCommitted
        }
    }

    // MARK: - Restore / export

    public func restore(
        target: DesignTarget,
        operationID: String,
        expectedOwnerRevision: Int64,
        artifactID: String,
        revisionID: String,
        runID: UUID? = nil
    ) async throws -> DesignOwnerEnvelope {
        try await requireAuthorized(target, runID: runID)
        // The restored bytes must exist and hash-match before the CAS.
        guard let envelope = try await state(target, runID: runID),
              let artifact = envelope.project.artifact(artifactID),
              let source = artifact.revision(revisionID) else {
            throw DesignWorkflowError.revisionNotFound(revisionID)
        }
        _ = try payloads.verifiedBytes(
            ownerKey: target.stableKey, revisionID: source.id,
            expectedContentSHA256: source.contentSHA256
        )
        return try await mutate(
            target: target, operationID: operationID,
            expectedOwnerRevision: expectedOwnerRevision,
            runID: runID
        ) { project in
            _ = try DesignWorkflowEngine.restoreRevision(
                in: &project, artifactID: artifactID, revisionID: revisionID
            )
        }.envelope
    }

    /// Verified export: retained bytes, digest re-check, then the owner's
    /// real reopen verification (app-supplied adapter parser). No format
    /// conversion is performed.
    public func exportVerified(
        target: DesignTarget,
        artifactID: String,
        revisionID: String,
        runID: UUID? = nil,
        verifyReopen: @Sendable (Data, String, DesignContentType) async throws -> Void
    ) async throws -> Data {
        try await requireAuthorized(target, runID: runID)
        guard let envelope = try await state(target, runID: runID),
              let artifact = envelope.project.artifact(artifactID),
              let revision = artifact.revision(revisionID) else {
            throw DesignWorkflowError.revisionNotFound(revisionID)
        }
        let bytes = try payloads.verifiedBytes(
            ownerKey: target.stableKey, revisionID: revisionID,
            expectedContentSHA256: revision.contentSHA256
        )
        try await verifyReopen(bytes, revision.payloadFormat ?? "bin", artifact.contentType)
        return bytes
    }
}
