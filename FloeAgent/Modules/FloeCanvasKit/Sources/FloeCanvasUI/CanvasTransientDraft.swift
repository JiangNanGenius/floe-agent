import Foundation
import FloeCanvasCore

/// A recoverable, not-yet-committed edit.
///
/// Per UI_BRIEF and ICH02/ICH11: on a CAS/save failure the pending content
/// stays recoverable and tied to the exact page/node/revision it belonged
/// to — switching pages or dismissing a panel must neither discard it nor
/// apply it to the next page. The banner offers Retry (re-bases onto the
/// current revision and re-commits) or Discard.
public struct CanvasTransientDraft: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// A whole canvas/page edit batch that failed to commit.
        case documentBatch
        /// A page-level (classic) edit batch that failed to commit.
        case pageBatch
        /// Assistant application that failed the trusted-context check.
        case assistantApplication
    }

    public var id: UUID
    public var kind: Kind
    /// The page the draft belongs to. Never applied to any other page.
    public var pageID: UUID
    /// Node identity the draft is tied to (nil for page-wide gestures).
    public var nodeID: UUID?
    /// The document revision the draft was built against (original
    /// expectedRevision for idempotent replay).
    public var baseRevision: Int64
    /// Stable request identity of the failed commit. Retry replays the SAME
    /// request ID with the SAME payload and the SAME expected revision: the
    /// repository answers from its receipt table before CAS, so a lost
    /// acknowledgement (committed, then an I/O throw) cannot produce a
    /// second mutation, revision, or undo unit.
    public var requestID: UUID
    /// When the failure happened.
    public var createdAt: Date
    /// Human-readable summary for the recovery banner.
    public var summary: String
    /// Retry context: the original document batch (whole-document scope so a
    /// retry after unrelated commits still validates).
    public var documentBatch: CanvasDocumentBatch?
    public var pageBatch: CanvasEditBatch?
    /// True when the last failure was a real CAS conflict (retry would just
    /// re-conflict; the user must pick the explicit rebase action).
    public var didConflict: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        pageID: UUID,
        nodeID: UUID? = nil,
        baseRevision: Int64,
        requestID: UUID,
        createdAt: Date = Date(),
        summary: String,
        documentBatch: CanvasDocumentBatch? = nil,
        pageBatch: CanvasEditBatch? = nil,
        didConflict: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.pageID = pageID
        self.nodeID = nodeID
        self.baseRevision = baseRevision
        self.requestID = requestID
        self.createdAt = createdAt
        self.summary = summary
        self.documentBatch = documentBatch
        self.pageBatch = pageBatch
        self.didConflict = didConflict
    }
}
