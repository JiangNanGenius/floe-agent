import Foundation

// FloeCore — Ownership adapters behind typed design targets.
//
// Each adapter owns ONE `DesignTargetKind` and resolves a frozen target
// through an app-supplied port. The ports are the seam to the EXISTING
// services (Canvas service + node content reader, workspace file
// permissions, chat attachment storage, creative creation target): this
// layer never duplicates a store, never accepts an arbitrary absolute path
// as authority, and never invents permission for a source the live services
// would not allow.
//
// Concurrency: adapters are immutable Sendable structs; ports are Sendable
// and expected to be actor-safe in the app. Resolution re-checks
// authorization/containment on EVERY call (a persisted target cannot widen
// access).

// MARK: - Port value types

/// A workspace-permission-resolved file. Produced only by the app port after
/// the live workspace/environment services authorize the reference.
public struct DesignResolvedFile: Sendable, Equatable {
    public let data: Data
    public let format: String
    public let displayName: String
    public let contentSHA256: String
    public let baseRevisionToken: String
    /// Whether the adopted result may replace this source in place. Chat
    /// attachments are always read-only; canvas/creative targets typically
    /// allow it.
    public let allowsInPlaceUpdate: Bool

    public init(
        data: Data,
        format: String,
        displayName: String,
        contentSHA256: String,
        baseRevisionToken: String,
        allowsInPlaceUpdate: Bool
    ) {
        self.data = data
        self.format = format
        self.displayName = displayName
        self.contentSHA256 = contentSHA256
        self.baseRevisionToken = baseRevisionToken
        self.allowsInPlaceUpdate = allowsInPlaceUpdate
    }
}

/// One chat attachment resolved from the ORIGINAL task's storage. The
/// original attachment is never mutated or deleted by the design workflow.
public struct DesignChatAttachment: Sendable, Equatable {
    public let data: Data
    public let format: String
    public let displayName: String
    public let contentSHA256: String
    public let baseRevisionToken: String
    /// The conversation that actually owns the attachment; the adapter
    /// verifies it equals the target's owner.
    public let conversationID: String

    public init(
        data: Data,
        format: String,
        displayName: String,
        contentSHA256: String,
        baseRevisionToken: String,
        conversationID: String
    ) {
        self.data = data
        self.format = format
        self.displayName = displayName
        self.contentSHA256 = contentSHA256
        self.baseRevisionToken = baseRevisionToken
        // Stored verbatim; comparisons normalize (UUID casing only).
        self.conversationID = conversationID
    }
}

// MARK: - Ports (app implements against existing services)

/// Reads the real content of a Canvas node. The app implements this with
/// the same logic `DesignWorkflowActions.useCurrentNode` uses (text body,
/// retained asset bytes through the artifact authority, or the bound
/// CAD/Office workspace document); FloeCore stays UIKit-free.
public protocol DesignCanvasContentPort: Sendable {
    /// Read and verify the node's current content for a design source.
    /// Throws `DesignTargetError.notFound`/`.unverifiable` with a reason.
    func readNode(
        canvasID: UUID,
        nodeID: UUID,
        snapshot: DesignCanvasService.Snapshot
    ) async throws -> DesignResolvedFile
}

/// Resolves workspace-scoped file references using the EXISTING workspace
/// permission services. Implementations must re-derive permission from the
/// live workspace/environment identity on every call.
public protocol DesignWorkspaceFilePort: Sendable {
    func resolve(
        workspaceID: String,
        reference: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile

    /// Containment/permission probe without reading bytes.
    func isAuthorized(
        workspaceID: String,
        reference: String,
        environmentID: String?,
        runID: UUID?
    ) async -> Bool

    func exists(workspaceID: String, reference: String, environmentID: String?) async -> Bool
}

/// Resolves the original attachment of a chat task through the existing
/// conversation/attachment storage.
public protocol DesignChatAttachmentPort: Sendable {
    func resolveAttachment(
        conversationID: String,
        messageID: String,
        attachmentID: String,
        runID: UUID?
    ) async throws -> DesignChatAttachment

    /// Cheap ownership/existence probe WITHOUT loading bytes. Used on
    /// every shared-service boundary so task/run revocation is enforced
    /// live. Default implementation resolves bytes; production ports
    /// implement the metadata-only check.
    func attachmentIsAccessible(
        conversationID: String,
        messageID: String,
        attachmentID: String,
        runID: UUID?
    ) async -> Bool
}

public extension DesignChatAttachmentPort {
    func attachmentIsAccessible(
        conversationID: String,
        messageID: String,
        attachmentID: String,
        runID: UUID?
    ) async -> Bool {
        (try? await resolveAttachment(
            conversationID: conversationID,
            messageID: messageID,
            attachmentID: attachmentID,
            runID: runID
        )) != nil
    }
}

/// Authoritative provenance of a creative first-result binding. Produced
/// ONLY by `DesignCreativeDocumentPort.verifyFirstResultBinding` inside the
/// shared bind transaction, after the app port verified the REAL retained
/// asset; no caller-supplied string, boolean or persisted model field can
/// mint it.
public enum DesignCreativeResultProvenance: String, Codable, Sendable, Equatable {
    /// The bound asset is the committed local result of a durable media
    /// generation job submitted by the binding run (or owned by its task).
    case generationJob
    /// An explicit in-app (trusted UI) selection/import of a real retained
    /// asset; no model-authored identity participated.
    case trustedUIManualImport
}

/// Resolves the EXISTING creative-mode creation target. Never creates a
/// canvas, workspace or project: creative starts reuse the creation target
/// the user already began.
public protocol DesignCreativeDocumentPort: Sendable {
    func resolve(
        ownerID: String,
        creationID: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile

    /// Live authorization for a creative START request that has no material
    /// yet (requirements/spec saved, first result not generated). Trusted UI
    /// passes `runID == nil`; agent runs must present an existing grant.
    /// Fail closed by default.
    func requestIsAuthorized(
        ownerID: String,
        requestID: String,
        environmentID: String?,
        runID: UUID?
    ) async -> Bool

    /// The first REAL bound result for a materialized creative request, when
    /// one exists. Reads the shared owner envelope (no parallel store) and
    /// resolves the bound creative asset; nil while awaiting generation.
    /// For a RUN the port must additionally enforce the binding's verified
    /// provenance (trusted-UI selection for the run's own task, or a live
    /// durable job link) — a legacy/model-authored binding is not authority.
    func boundResult(
        targetKey: String,
        ownerID: String,
        requestID: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile?

    /// Pre-effect verification for the shared first-result bind transaction
    /// (`DesignOwnerWorkflow.bindFirstResult`). The port MUST resolve
    /// `boundResultID` to the REAL retained asset (row + contained file,
    /// real on-disk cap and digest verification) and require the proposed
    /// `bytes`/`format` to BE that asset's bytes/format. For a run it MUST
    /// additionally prove an independently trusted link between the asset
    /// and the run's own task through the durable media-generation
    /// job→asset record; a model-authored id, a caller-supplied approval
    /// boolean or a persisted envelope field is never proof. Returns the
    /// provenance the shared transaction records in the SAME envelope CAS.
    /// Throws before any state is written; the default fails closed.
    func verifyFirstResultBinding(
        ownerID: String,
        requestID: String,
        environmentID: String?,
        boundResultID: String,
        bytes: Data,
        format: String,
        runID: UUID?
    ) async throws -> DesignCreativeResultProvenance
}

public extension DesignCreativeDocumentPort {
    func requestIsAuthorized(
        ownerID: String,
        requestID: String,
        environmentID: String?,
        runID: UUID?
    ) async -> Bool {
        false
    }

    func boundResult(
        targetKey: String,
        ownerID: String,
        requestID: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile? {
        nil
    }

    func verifyFirstResultBinding(
        ownerID: String,
        requestID: String,
        environmentID: String?,
        boundResultID: String,
        bytes: Data,
        format: String,
        runID: UUID?
    ) async throws -> DesignCreativeResultProvenance {
        throw DesignTargetError.unavailable(
            "no creative first-result binding verification is connected; refusing to record a result binding")
    }
}

// MARK: - Owner payload + commit ports (app implements on artifact authority)

/// Persists revision bytes for a non-canvas target under the EXISTING
/// artifact authority (app implementation uses
/// `<artifact root>/DesignRevisions/owners/<targetKey>/...`). Immutable,
/// content-verified: staging hashes bytes before they are referenced by a
/// CAS envelope, and reads re-verify the digest.
public protocol DesignOwnerPayloadStore: Sendable {
    /// Stores verified bytes for a candidate/input revision; returns an
    /// opaque relative token recorded on `DesignRevision.payloadRelativePath`.
    func store(
        ownerKey: String,
        revisionID: String,
        bytes: Data,
        expectedContentSHA256: String
    ) throws -> String
    func verifiedBytes(
        ownerKey: String,
        revisionID: String,
        expectedContentSHA256: String
    ) throws -> Data
    func abandon(ownerKey: String, revisionID: String)
}

/// Classification of the ACTUAL owner source against the frozen base and the
/// proposed digest. Produced by `DesignOwnerCommitPort.verify` without
/// writing anything; adoption recovery uses it so a source that already
/// holds the proposed bytes is completed (or a user-edited source is
/// preserved) instead of being cancelled because an operation record is
/// absent.
public enum DesignCommitVerification: Sendable, Equatable {
    /// The source is missing/deleted.
    case missing
    /// The source digest equals the proposed content digest (the write
    /// already landed).
    case matchesProposed
    /// The source digest still equals the frozen base digest (nothing was
    /// written).
    case matchesBase
    /// The source moved to a different digest (e.g. a user edit): never
    /// overwrite it from recovery.
    case diverged(actualSHA256: String)
}

/// Typed source-write failure classification. The distinction matters for
/// crash recovery: `notWritten` proves no bytes were written and a fresh
/// durable intent may be cancelled; any other failure (including a readback
/// mismatch) may have written bytes and MUST keep the durable intent pending
/// for reconcile.
public enum DesignOwnerCommitError: Error, Equatable {
    /// The port proved nothing was written (gate/validation failed before
    /// the write).
    case notWritten(String)
    /// The write may have landed but could not be verified (I/O failure,
    /// readback mismatch). Recoverable state: never cancel the intent.
    case unknown(String)
}

/// Writes an adopted revision back to an in-place owner (a workspace file).
/// Read-only owners (chat attachment, content-addressed creative asset) do
/// NOT implement this; their adopted result is retained in the owner
/// workflow and delivered to the original task instead of overwriting.
public protocol DesignOwnerCommitPort: Sendable {
    func canCommit(_ target: DesignTarget) -> Bool
    /// Commits bytes to the owner source, gated by the frozen base token;
    /// returns the new owner revision token.
    ///
    /// Implementations MUST verify the write by READBACK: the bytes actually
    /// present at the source after the write must hash to the proposed
    /// digest before a new token is returned. A mismatch after a write that
    /// may have landed throws `DesignOwnerCommitError.unknown`; a gate
    /// failure before any write (moved/missing source, missing frozen digest)
    /// throws `.notWritten` — never an untyped error that recovery cannot
    /// classify.
    func commit(
        target: DesignTarget,
        reference: String,
        bytes: Data,
        format: String,
        baseRevisionToken: String
    ) async throws -> String

    /// Reads the CURRENT source (no write) and classifies it against the
    /// proposed digest and the frozen base. Required for adoption recovery:
    /// reconcile must compare the actual source bytes, never merely the
    /// presence of an operation record.
    func verify(
        target: DesignTarget,
        reference: String,
        proposedContentSHA256: String,
        baseRevisionToken: String
    ) async throws -> DesignCommitVerification
}

// MARK: - Adopted-result publication (immutable owners)
//
// Chat attachments and content-addressed creative assets are IMMUTABLE: an
// adoption can never overwrite the original. Retaining the adopted revision
// in the owner envelope is not enough — the user-approved result must be
// RETURNED to its owner destination (a NEW attachment in the originating
// task, or a new revision/asset in the existing `CreativeAssetStore`).
// Core defines the exact binding and the idempotent handoff; the app port
// performs the write through the EXISTING FilesCenter/ConversationStore/
// CreativeAssetStore services. There is no second media store.

/// Exact binding of one adopted result to the verified payload that must be
/// returned to its owner. Every identity needed for a replay-safe
/// publication is carried here: operation, candidate, artifact, revision,
/// digest, destination attribution and owner revision.
public struct DesignResultPublication: Sendable, Equatable {
    /// The frozen owner target (kind/owner/document/source/environment and
    /// originating task). Chat publication goes to `target.ownerID` (the
    /// originating conversation); creative publication to the existing
    /// creation target.
    public let target: DesignTarget
    /// `target.stableKey` at commit time, for durable audit/correlation.
    public let targetStableKey: String
    /// The adopt operation this result belongs to.
    public let operationID: String
    public let candidateID: String
    public let mode: DesignAdoptMode
    public let artifactID: String
    public let revisionID: String
    /// Relative token of the retained immutable payload (same artifact
    /// authority as every other design revision).
    public let payloadRelativePath: String
    public let contentSHA256: String
    public let format: String
    public let displayName: String
    /// The ORIGINATING task attribution: the notice and (for chat) the new
    /// attachment belong to this conversation. Nil stays nil — no invented
    /// task identity.
    public let originConversationID: String?
    /// Owner envelope revision after the applied CAS, for the audit trail.
    public let ownerRevision: Int64
    /// The verified payload bytes (already digest-checked by the workflow).
    public let bytes: Data

    public init(
        target: DesignTarget,
        targetStableKey: String,
        operationID: String,
        candidateID: String,
        mode: DesignAdoptMode,
        artifactID: String,
        revisionID: String,
        payloadRelativePath: String,
        contentSHA256: String,
        format: String,
        displayName: String,
        originConversationID: String?,
        ownerRevision: Int64,
        bytes: Data
    ) {
        self.target = target
        self.targetStableKey = targetStableKey
        self.operationID = operationID
        self.candidateID = candidateID
        self.mode = mode
        self.artifactID = artifactID
        self.revisionID = revisionID
        self.payloadRelativePath = payloadRelativePath
        self.contentSHA256 = contentSHA256
        self.format = format
        self.displayName = displayName
        self.originConversationID = originConversationID
        self.ownerRevision = ownerRevision
        self.bytes = bytes
    }

    /// Idempotency key for the publication handoff: operation identity plus
    /// the EXACT revision bytes. A replay after a crash reuses the same key
    /// and must return the previously published destination identity; a
    /// different payload under the same operation can never alias it.
    public var publicationKey: String {
        "\(operationID)|\(revisionID)|\(contentSHA256)"
    }
}

/// Identity of the published result in the EXISTING destination store
/// (attachment id / creative asset revision id). Opaque to FloeCore.
public struct DesignResultPublicationReceipt: Sendable, Equatable {
    /// Destination-store identity: e.g. the new chat attachment id or the
    /// creative asset/revision id.
    public let identifier: String
    /// Auditable destination identity, e.g. `chat:<conversationID>` or
    /// `creative:<creationID>`.
    public let destination: String
    public let contentSHA256: String

    public init(identifier: String, destination: String, contentSHA256: String) {
        self.identifier = identifier
        self.destination = destination
        self.contentSHA256 = contentSHA256
    }
}

/// Honest outcome of returning an adopted result. `pending` means the
/// result is NOT returned to the owner yet (no port connected or the port
/// failed); it is never reported as published. The durable decision intent
/// stays pending until publication succeeds, so reconcile retries it.
public enum DesignResultPublicationOutcome: Sendable, Equatable {
    /// No separate publication is needed: the owner source itself was
    /// updated in place (verified workspace commit) or the target kind has
    /// no immutable-owner destination.
    case notRequired(String)
    case published(DesignResultPublicationReceipt)
    case pending(String)

    public var isPublished: Bool {
        if case .published = self { return true }
        return false
    }

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    public var errorDescription: String? {
        if case .pending(let reason) = self { return reason }
        return nil
    }
}

/// Publishes an adopted result through the EXISTING owner storage
/// (FilesCenter/ConversationStore for chat, `CreativeAssetStore` for
/// creative). Implementations MUST be idempotent under
/// `publication.publicationKey`: the same key always returns the SAME
/// receipt and never creates a second attachment/asset, so a replay after a
/// crash (or a reconcile) cannot duplicate the user-visible result. A
/// failure throws and leaves nothing half-published that a retry could
/// duplicate.
public protocol DesignResultPublicationPort: Sendable {
    func publish(
        _ publication: DesignResultPublication
    ) async throws -> DesignResultPublicationReceipt
}

// MARK: - Adapter protocol

public protocol DesignOwnerAdapter: Sendable {
    var kind: DesignTargetKind { get }
    func resolve(_ target: DesignTarget, runID: UUID?) async throws -> DesignResolvedSource
    func contains(_ target: DesignTarget, runID: UUID?) async -> Bool
    func exists(_ target: DesignTarget) async -> Bool
    /// Optional capability invoked by the shared creative bind transaction
    /// BEFORE any payload write/CAS: see
    /// `DesignCreativeDocumentPort.verifyFirstResultBinding`. Kinds without a
    /// first-result binding authority fail closed.
    func verifyFirstResultBinding(
        _ target: DesignTarget,
        boundResultID: String,
        bytes: Data,
        format: String,
        runID: UUID?
    ) async throws -> DesignCreativeResultProvenance
}

public extension DesignOwnerAdapter {
    func verifyFirstResultBinding(
        _ target: DesignTarget,
        boundResultID: String,
        bytes: Data,
        format: String,
        runID: UUID?
    ) async throws -> DesignCreativeResultProvenance {
        throw DesignTargetError.unavailable(
            "no first-result binding verification is connected for \(kind.rawValue)")
    }
}

public enum DesignTargetValidation {
    /// A file/attachment reference must be a single owned token or a
    /// slash-separated relative path with no absolute prefix, no traversal
    /// and no empty components. This rejects "../x", "/etc/passwd",
    /// "a//b" and ".". It is NOT itself permission: the port still
    /// re-authorizes through live workspace services.
    public static func relativeReference(_ reference: String) throws -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw DesignTargetError.invalidReference(reference)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw DesignTargetError.invalidReference(reference)
        }
        // Reject Windows drive / scheme forms smuggled as a single token.
        if trimmed.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil
            || trimmed.lowercased().hasPrefix("file:") {
            throw DesignTargetError.invalidReference(reference)
        }
        return trimmed
    }

    public static func uuid(_ value: String, field: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw DesignTargetError.invalidReference("\(field) is not a UUID: \(value)")
        }
        return uuid
    }

    /// Verifies non-empty bytes and, when the port supplied a digest, that
    /// the actual bytes match it.
    public static func verified(
        _ file: DesignResolvedFile
    ) throws -> DesignResolvedFile {
        guard !file.data.isEmpty else {
            throw DesignTargetError.unverifiable("resolved source is empty")
        }
        let actual = FloeDigest.sha256Hex(file.data)
        guard actual == file.contentSHA256.lowercased() else {
            throw DesignTargetError.unverifiable("source digest mismatch")
        }
        return file
    }

    /// Resolves the real content family from a verified format. An
    /// unrecognized format fails explicitly instead of being treated as a
    /// generic webpage.
    public static func contentType(format: String) throws -> DesignContentType {
        guard let type = DesignContentType.from(format: format) else {
            throw DesignTargetError.unavailable(
                "No design content family is registered for format '\(format)'"
            )
        }
        return type
    }
}

// MARK: - Canvas adapter (retained)

public actor DesignCanvasOwnerAdapter: DesignOwnerAdapter {
    public nonisolated let kind: DesignTargetKind = .canvasNode
    private let service: DesignCanvasService
    private let contentPort: DesignCanvasContentPort

    public init(service: DesignCanvasService, contentPort: DesignCanvasContentPort) {
        self.service = service
        self.contentPort = contentPort
    }

    public func snapshot(
        for target: DesignTarget,
        runID: UUID?
    ) async throws -> (canvasID: UUID, nodeID: UUID, DesignCanvasService.Snapshot) {
        guard target.kind == .canvasNode else {
            throw DesignTargetError.unsupportedKind(target.kind.rawValue)
        }
        let canvasID = try DesignTargetValidation.uuid(target.ownerID, field: "ownerID")
        let nodeID = try DesignTargetValidation.uuid(target.sourceID, field: "sourceID")
        do {
            let snapshot = try await service.snapshot(runID: runID, canvasID: canvasID, nodeID: nodeID)
            return (canvasID, nodeID, snapshot)
        } catch let error as DesignTargetError {
            throw error
        } catch {
            // Missing node/canvas or an authorization failure both fail
            // closed; the message distinguishes for callers.
            let message = String(describing: error)
            if message.contains("not authorized") {
                throw DesignTargetError.notAuthorized(message)
            }
            throw DesignTargetError.notFound(message)
        }
    }

    public func resolve(_ target: DesignTarget, runID: UUID?) async throws -> DesignResolvedSource {
        let (canvasID, nodeID, snapshot) = try await snapshot(for: target, runID: runID)
        let content: DesignResolvedFile
        do {
            content = try await contentPort.readNode(canvasID: canvasID, nodeID: nodeID, snapshot: snapshot)
        } catch let error as DesignTargetError {
            throw error
        } catch {
            throw DesignTargetError.unverifiable(String(describing: error))
        }
        let verified = try DesignTargetValidation.verified(content)
        // The frozen base combines the Canvas CAS revision with the bound
        // artifact's current revision, so a manual node edit (canvas rev
        // moves) and a design revision move are BOTH detected.
        let token = currentToken(snapshot: snapshot, fileToken: verified.baseRevisionToken)
        if let frozen = target.revision, frozen != token {
            throw DesignTargetError.moved(frozen: frozen, actual: token)
        }
        // The bound design subdocument owns the content family for a canvas
        // node (built-in plugin mappings included); fall back to the real
        // format only when no subdocument exists yet.
        let contentType = snapshot.design?.contentType
            ?? DesignContentType.from(format: verified.format)
            ?? DesignContentTypeMapper.effectiveContentType(
                existing: nil, kind: snapshot.nodeKind, metadata: snapshot.nodeMetadata
            )
        return DesignResolvedSource(
            target: target.freezing(revision: token),
            data: verified.data,
            format: verified.format,
            displayName: verified.displayName,
            contentSHA256: verified.contentSHA256,
            baseRevisionToken: token,
            allowsInPlaceUpdate: true,
            originConversationID: target.originConversationID,
            contentType: contentType,
            canvas: .init(
                canvasID: canvasID,
                documentID: snapshot.canvasDocumentID,
                nodeID: nodeID
            )
        )
    }

    public func contains(_ target: DesignTarget, runID: UUID?) async -> Bool {
        (try? await snapshot(for: target, runID: runID)) != nil
    }

    public func exists(_ target: DesignTarget) async -> Bool {
        guard let canvasID = UUID(uuidString: target.ownerID),
              let nodeID = UUID(uuidString: target.sourceID) else { return false }
        return (try? await service.snapshot(canvasID: canvasID, nodeID: nodeID)) != nil
    }

    private func currentToken(
        snapshot: DesignCanvasService.Snapshot,
        fileToken: String
    ) -> String {
        let artifactRevision = snapshot.design?.artifacts
            .first(where: { $0.canvasNodeID == snapshot.nodeID.uuidString.lowercased() })?
            .currentRevisionID ?? "none"
        return "canvas:\(snapshot.canvasRevision):rev:\(artifactRevision):src:\(fileToken)"
    }
}

// MARK: - File adapter

public struct DesignFileOwnerAdapter: DesignOwnerAdapter {
    public let kind: DesignTargetKind = .fileDocument
    private let port: DesignWorkspaceFilePort

    public init(port: DesignWorkspaceFilePort) { self.port = port }

    public func resolve(_ target: DesignTarget, runID: UUID?) async throws -> DesignResolvedSource {
        guard target.kind == .fileDocument else {
            throw DesignTargetError.unsupportedKind(target.kind.rawValue)
        }
        guard !target.ownerID.isEmpty else {
            throw DesignTargetError.invalidReference("workspace owner is required")
        }
        // A relative, non-traversing reference is necessary but not
        // sufficient: the port performs the live permission check.
        let reference = try DesignTargetValidation.relativeReference(target.sourceID)
        guard await port.isAuthorized(
            workspaceID: target.ownerID,
            reference: reference,
            environmentID: target.environmentID,
            runID: runID
        ) else {
            throw DesignTargetError.notAuthorized(
                "the workspace does not authorize '\(reference)' for this caller"
            )
        }
        let resolved: DesignResolvedFile
        do {
            resolved = try await port.resolve(
                workspaceID: target.ownerID,
                reference: reference,
                environmentID: target.environmentID,
                runID: runID
            )
        } catch let error as DesignTargetError {
            throw error
        } catch {
            throw DesignTargetError.notFound(String(describing: error))
        }
        let verified = try DesignTargetValidation.verified(resolved)
        if let frozen = target.revision, frozen != verified.baseRevisionToken {
            throw DesignTargetError.moved(frozen: frozen, actual: verified.baseRevisionToken)
        }
        let contentType = try DesignTargetValidation.contentType(format: verified.format)
        return DesignResolvedSource(
            target: target.freezing(revision: verified.baseRevisionToken),
            data: verified.data,
            format: verified.format,
            displayName: verified.displayName,
            contentSHA256: verified.contentSHA256,
            baseRevisionToken: verified.baseRevisionToken,
            allowsInPlaceUpdate: verified.allowsInPlaceUpdate,
            originConversationID: target.originConversationID,
            contentType: contentType
        )
    }

    public func contains(_ target: DesignTarget, runID: UUID?) async -> Bool {
        guard let reference = try? DesignTargetValidation.relativeReference(target.sourceID) else {
            return false
        }
        return await port.isAuthorized(
            workspaceID: target.ownerID,
            reference: reference,
            environmentID: target.environmentID,
            runID: runID
        )
    }

    public func exists(_ target: DesignTarget) async -> Bool {
        guard let reference = try? DesignTargetValidation.relativeReference(target.sourceID) else {
            return false
        }
        return await port.exists(
            workspaceID: target.ownerID,
            reference: reference,
            environmentID: target.environmentID
        )
    }
}

// MARK: - Chat attachment adapter

public struct DesignChatAttachmentOwnerAdapter: DesignOwnerAdapter {
    public let kind: DesignTargetKind = .chatAttachment
    private let port: DesignChatAttachmentPort

    public init(port: DesignChatAttachmentPort) { self.port = port }

    public func resolve(_ target: DesignTarget, runID: UUID?) async throws -> DesignResolvedSource {
        guard target.kind == .chatAttachment else {
            throw DesignTargetError.unsupportedKind(target.kind.rawValue)
        }
        // Conversation UUIDs serialize either case; keep the target's
        // opaque owner string verbatim for provenance and compare UUID
        // hex case-insensitively.
        let conversationID = target.ownerID
        let attachmentID = try DesignTargetValidation.relativeReference(target.sourceID)
        let attachment: DesignChatAttachment
        do {
            attachment = try await port.resolveAttachment(
                conversationID: conversationID,
                messageID: target.documentID,
                attachmentID: attachmentID,
                runID: runID
            )
        } catch let error as DesignTargetError {
            throw error
        } catch {
            throw DesignTargetError.notFound(String(describing: error))
        }
        // The attachment must belong to the target's ORIGINAL task. UUID
        // strings are compared case-insensitively (UUID hex case is
        // cosmetic); opaque workspace-style ids would never reach here.
        guard attachment.conversationID.caseInsensitiveCompare(conversationID) == .orderedSame else {
            throw DesignTargetError.notAuthorized(
                "attachment belongs to a different task than the target"
            )
        }
        guard !attachment.data.isEmpty,
              FloeDigest.sha256Hex(attachment.data) == attachment.contentSHA256.lowercased() else {
            throw DesignTargetError.unverifiable("attachment digest mismatch")
        }
        if let frozen = target.revision, frozen != attachment.baseRevisionToken {
            throw DesignTargetError.moved(frozen: frozen, actual: attachment.baseRevisionToken)
        }
        let contentType = try DesignTargetValidation.contentType(format: attachment.format)
        return DesignResolvedSource(
            target: target.freezing(revision: attachment.baseRevisionToken),
            data: attachment.data,
            format: attachment.format,
            displayName: attachment.displayName,
            contentSHA256: attachment.contentSHA256,
            baseRevisionToken: attachment.baseRevisionToken,
            // The original attachment is preserved: results never overwrite
            // it in place.
            allowsInPlaceUpdate: false,
            originConversationID: conversationID,
            contentType: contentType
        )
    }

    public func contains(_ target: DesignTarget, runID: UUID?) async -> Bool {
        // Metadata/ownership probe without loading (possibly large) bytes.
        guard target.kind == .chatAttachment else { return false }
        let reference = (try? DesignTargetValidation.relativeReference(target.sourceID)) ?? target.sourceID
        return await port.attachmentIsAccessible(
            conversationID: target.ownerID,
            messageID: target.documentID,
            attachmentID: reference,
            runID: runID
        )
    }

    public func exists(_ target: DesignTarget) async -> Bool {
        (try? await resolve(target, runID: nil)) != nil
    }
}

// MARK: - Creative creation-target adapter

public struct DesignCreativeOwnerAdapter: DesignOwnerAdapter {
    public let kind: DesignTargetKind = .creativeDocument
    private let port: DesignCreativeDocumentPort

    public init(port: DesignCreativeDocumentPort) { self.port = port }

    public func resolve(_ target: DesignTarget, runID: UUID?) async throws -> DesignResolvedSource {
        guard target.kind == .creativeDocument else {
            throw DesignTargetError.unsupportedKind(target.kind.rawValue)
        }
        let creationID = try DesignTargetValidation.relativeReference(target.sourceID)
        // A creative START request (explicit requested kind) has no material
        // until its first real result is generated and bound. Resolving
        // before that is a typed pending state — never a fabricated webpage
        // or a hidden canvas.
        if let requestedKind = target.requestedOutputKind {
            guard await port.requestIsAuthorized(
                ownerID: target.ownerID, requestID: creationID,
                environmentID: target.environmentID, runID: runID
            ) else {
                throw DesignTargetError.notAuthorized(
                    "the creative request is not authorized for this caller"
                )
            }
            guard let bound = try await port.boundResult(
                targetKey: target.stableKey,
                ownerID: target.ownerID,
                requestID: creationID,
                environmentID: target.environmentID,
                runID: runID
            ) else {
                throw DesignTargetError.pendingFirstResult(requestedKind.rawValue)
            }
            let verified = try DesignTargetValidation.verified(bound)
            if let frozen = target.revision, frozen != verified.baseRevisionToken {
                throw DesignTargetError.moved(frozen: frozen, actual: verified.baseRevisionToken)
            }
            return DesignResolvedSource(
                target: target.freezing(revision: verified.baseRevisionToken),
                data: verified.data,
                format: verified.format,
                displayName: verified.displayName,
                contentSHA256: verified.contentSHA256,
                baseRevisionToken: verified.baseRevisionToken,
                allowsInPlaceUpdate: verified.allowsInPlaceUpdate,
                originConversationID: target.originConversationID,
                contentType: requestedKind
            )
        }
        let resolved: DesignResolvedFile
        do {
            resolved = try await port.resolve(
                ownerID: target.ownerID,
                creationID: creationID,
                environmentID: target.environmentID,
                runID: runID
            )
        } catch let error as DesignTargetError {
            throw error
        } catch {
            throw DesignTargetError.notFound(String(describing: error))
        }
        let verified = try DesignTargetValidation.verified(resolved)
        if let frozen = target.revision, frozen != verified.baseRevisionToken {
            throw DesignTargetError.moved(frozen: frozen, actual: verified.baseRevisionToken)
        }
        let contentType = try DesignTargetValidation.contentType(format: verified.format)
        return DesignResolvedSource(
            target: target.freezing(revision: verified.baseRevisionToken),
            data: verified.data,
            format: verified.format,
            displayName: verified.displayName,
            contentSHA256: verified.contentSHA256,
            baseRevisionToken: verified.baseRevisionToken,
            allowsInPlaceUpdate: verified.allowsInPlaceUpdate,
            originConversationID: target.originConversationID,
            contentType: contentType
        )
    }

    public func verifyFirstResultBinding(
        _ target: DesignTarget,
        boundResultID: String,
        bytes: Data,
        format: String,
        runID: UUID?
    ) async throws -> DesignCreativeResultProvenance {
        guard target.kind == .creativeDocument else {
            throw DesignTargetError.unsupportedKind(target.kind.rawValue)
        }
        let requestID = try DesignTargetValidation.relativeReference(target.sourceID)
        return try await port.verifyFirstResultBinding(
            ownerID: target.ownerID,
            requestID: requestID,
            environmentID: target.environmentID,
            boundResultID: boundResultID,
            bytes: bytes,
            format: format,
            runID: runID
        )
    }

    public func contains(_ target: DesignTarget, runID: UUID?) async -> Bool {
        guard target.kind == .creativeDocument else { return false }
        if target.requestedOutputKind != nil {
            // Pending request: live request authorization; a bound result
            // also authorizes through the same port.
            if let creationID = try? DesignTargetValidation.relativeReference(target.sourceID),
               await port.requestIsAuthorized(
                   ownerID: target.ownerID, requestID: creationID,
                   environmentID: target.environmentID, runID: runID
               ) {
                return true
            }
        }
        return (try? await resolve(target, runID: runID)) != nil
    }

    public func exists(_ target: DesignTarget) async -> Bool {
        // Existence means the SOURCE material exists; a pending creative
        // request intentionally reports false.
        (try? await resolve(target, runID: nil)) != nil
    }
}
