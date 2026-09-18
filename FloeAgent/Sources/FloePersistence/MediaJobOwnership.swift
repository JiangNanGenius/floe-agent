import Foundation
import FloeCore

/// Explicit ownership of a durable media job. Canvas jobs keep their canvas
/// and document references; ordinary chat jobs are owned by a conversation and
/// deliberately have no canvas/document. The migration backfills every legacy
/// row as `canvas` so old jobs remain readable.
public enum MediaJobOwnerKind: String, Sendable, Codable, CaseIterable, Hashable {
    case canvas
    case conversation
    case document
}

public struct MediaJobOwner: Sendable, Codable, Hashable {
    public var kind: MediaJobOwnerKind
    public var id: UUID

    public init(kind: MediaJobOwnerKind, id: UUID) {
        self.kind = kind
        self.id = id
    }

    public static func canvas(_ id: UUID) -> MediaJobOwner { .init(kind: .canvas, id: id) }
    public static func conversation(_ id: UUID) -> MediaJobOwner { .init(kind: .conversation, id: id) }
}

/// One durable job plus its explicit ownership. `canvasID`/`documentID` are
/// nil for conversation-owned jobs; callers must branch on `owner.kind` rather
/// than reading the legacy fields on `job` (which are now optional and carry
/// the real, possibly absent, canvas/document identity).
public struct OwnedMediaGenerationJob: Sendable, Hashable, Identifiable {
    public var job: MediaGenerationJob
    public var owner: MediaJobOwner
    public var canvasID: UUID?
    public var documentID: UUID?
    /// Run that submitted the job, when known. Used to deliver completion back
    /// to a live conversation without inventing a new user turn.
    public var originRunID: UUID?
    /// Stable identity of the submitting tool call (`runID:toolCallID`), when
    /// known. Dedupe is keyed on this so a replayed tool call attaches to the
    /// existing job while a distinct later request is never merged into it.
    public var idempotencyKey: String?

    public var id: UUID { job.id }

    public init(
        job: MediaGenerationJob,
        owner: MediaJobOwner,
        canvasID: UUID?,
        documentID: UUID?,
        originRunID: UUID? = nil,
        idempotencyKey: String? = nil
    ) {
        self.job = job
        self.owner = owner
        self.canvasID = canvasID
        self.documentID = documentID
        self.originRunID = originRunID
        self.idempotencyKey = idempotencyKey
    }
}
