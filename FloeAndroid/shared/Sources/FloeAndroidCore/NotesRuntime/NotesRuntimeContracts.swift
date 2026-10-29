// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes-purpose assistant runtime — bounded contracts.
//
// This namespace is the ASSISTANT RUNTIME side of Notes, not a second Notes
// authority: every document read, proposal create and decision ack goes
// through the existing `floe.notes/4` C5 actions on the one process-wide
// `NotesDomainService`/`NotesEngine`/`NotesStore`. Nothing here opens a store,
// creates a database or re-implements proposal/outbox/OCR state.
//
// Identity: one Notes conversation is a `purpose = 'notes'` conversation row
// created through the SAME `SQLiteConversationStore`, bound to the document
// through the existing `assistant_threads`/`assistant_scopes` tables. It is
// executed by the SAME accepted-epoch `FacadeRunDomain`, provider adapters,
// gates and stores — never a Kotlin agent loop or a shadow provider client.
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools

// MARK: - Closed tool vocabulary

/// The complete Notes tool ceiling. These names are registered ONLY on the
/// isolated per-run registry built for a Notes launch, so ordinary tool
/// discovery never advertises them and an ordinary run can never execute
/// them (the ceiling intersection is empty).
public enum NotesAssistantToolNames {
    public static let read = "notes.read"
    public static let search = "notes.search"
    public static let edit = "notes.edit"

    public static let all: [String] = [read, search, edit]
    public static let closed: Set<String> = Set(all)
}

// MARK: - Typed refusal

/// Closed refusal vocabulary for the Notes assistant runtime. These codes are
/// returned through `floe.notes/4` as `{ok:false,error,reason,retryable}`; they
/// never carry document text, paths or raw exception messages.
public struct NotesAssistantRefusal: Error, Sendable, Equatable {
    public enum Code: String, Sendable, CaseIterable {
        /// No configured provider/model can run the assistant right now. This
        /// NEVER blocks ordinary offline Notes editing.
        case notConfigured
        /// The conversation has no live read (or edit) grant for that note.
        case notAuthorized
        /// The requested document/revision is no longer current.
        case staleRevision
        case documentMissing
        case conversationMissing
        /// The row exists with another purpose (ordinary/temporary). It is
        /// never retagged into a Notes thread.
        case bindingRefused
        /// The assistant runtime is not installed for this accepted epoch.
        case runtimeUnavailable
        case runMissing
        case busy
        case cancelled
        case storageUnavailable
        case invalidPayload
        case unsupported
        /// The underlying C5 authority refused (native code + reason).
        case authority
    }

    public let code: Code
    public let reason: String?
    public let retryable: Bool

    public init(_ code: Code, _ reason: String? = nil, retryable: Bool = false) {
        self.code = code
        self.reason = reason.map { String($0.prefix(120)) }
        self.retryable = retryable
    }

    public var wireCode: String { code.rawValue }

    /// Wire object for one `floe.notes/4` reply. Identifier-only; no content.
    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "ok": false,
            "error": code.rawValue,
            "retryable": retryable,
        ]
        if let reason { object["reason"] = reason }
        return object
    }
}

// MARK: - Run binding

/// Immutable Notes document authority for ONE run. Built from the live native
/// grants immediately before the launch's atomic prepare; the tools re-read
/// the live grants on every call, so a revocation between launch and execution
/// still wins (this record is the launch-time ceiling, not a lease).
public struct NotesRunBinding: Sendable, Equatable {
    public var conversationID: UUID
    /// The document bound to this assistant thread at open time.
    public var documentID: UUID
    /// Every document the conversation currently holds a live read grant for.
    public var readableDocumentIDs: Set<UUID>
    /// Subset of `readableDocumentIDs` with a live EDIT grant.
    public var editableDocumentIDs: Set<UUID>
    /// App-generated Notes navigation context (`assistantRuntimeContext`).
    /// Data + workflow guidance only; it grants nothing.
    public var contextText: String
    /// The page the editor had focused when the turn started, when known.
    public var focusedPageID: UUID?
    /// Validated editor focus (page/selection/node/attachments). Data only:
    /// it is not a grant and the tools still re-read the live authority.
    public var focus: NotesRunFocus?

    public init(conversationID: UUID,
                documentID: UUID,
                readableDocumentIDs: Set<UUID>,
                editableDocumentIDs: Set<UUID>,
                contextText: String,
                focusedPageID: UUID? = nil,
                focus: NotesRunFocus? = nil) {
        self.conversationID = conversationID
        self.documentID = documentID
        self.readableDocumentIDs = readableDocumentIDs
        self.editableDocumentIDs = editableDocumentIDs
        self.contextText = contextText
        self.focusedPageID = focusedPageID
        self.focus = focus
    }

    public func grantsRead(_ documentID: UUID) -> Bool {
        readableDocumentIDs.contains(documentID)
    }

    public func grantsEdit(_ documentID: UUID) -> Bool {
        editableDocumentIDs.contains(documentID)
    }
}

// MARK: - Runtime provider port

/// The narrow port the EXISTING run-service assembly consults for a Notes run.
/// It supplies exactly three things the ordinary assembly does not: the closed
/// tool set (on an ISOLATED registry), the Notes document approval policy, and
/// — through the coordinator that built the binding — the app-generated Notes
/// navigation context. It never builds a second run domain, provider client or
/// store.
public protocol NotesRunRuntimeProviding: Sendable {
    /// The complete model-facing tool name set for a Notes run.
    var closedToolNames: Set<String> { get }

    /// Isolated registry for ONE run. Only the closed tools exist here, so
    /// ordinary discovery/execution can never reach them.
    func makeToolRegistry(epoch: UInt64,
                          binding: NotesRunBinding,
                          runID: UUID,
                          environmentID: String?) -> ToolRunnerRegistry

    /// Deterministic document-assistant policy for the closed tools.
    func approvalPolicy(epoch: UInt64,
                        binding: NotesRunBinding,
                        runID: UUID,
                        environmentID: String?) -> any ApprovalPolicy
}

// MARK: - Status

/// One honest status projection. `availability` uses the same three-value
/// vocabulary as the App port: a missing model is `notConfigured` and never
/// blocks ordinary editing; a missing native runtime/Notes binding is
/// `unavailable`.
public struct NotesAssistantStatusSnapshot: Sendable, Equatable {
    public enum Availability: String, Sendable, Equatable {
        case ready
        case notConfigured
        case unavailable
    }

    public var availability: Availability
    /// Bound document (nil before the thread is opened).
    public var documentID: UUID?
    /// Durable `purpose = notes` conversation (nil before open).
    public var conversationID: UUID?
    /// Last real run observed for this conversation (live or durable).
    public var runID: UUID?
    public var runState: String?
    public var modelLabel: String?
    /// Stable reason only (`modelUnavailable`, `runtimeUnavailable`, ...).
    public var reason: String?

    public init(availability: Availability,
                documentID: UUID? = nil,
                conversationID: UUID? = nil,
                runID: UUID? = nil,
                runState: String? = nil,
                modelLabel: String? = nil,
                reason: String? = nil) {
        self.availability = availability
        self.documentID = documentID
        self.conversationID = conversationID
        self.runID = runID
        self.runState = runState
        self.modelLabel = modelLabel
        self.reason = reason
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = ["availability": availability.rawValue]
        object["documentID"] = documentID?.uuidString ?? NSNull()
        object["conversationID"] = conversationID?.uuidString ?? NSNull()
        object["runID"] = runID?.uuidString ?? NSNull()
        object["runState"] = runState ?? NSNull()
        object["modelLabel"] = modelLabel ?? NSNull()
        object["reason"] = reason ?? NSNull()
        return object
    }
}

// MARK: - Durable transcript

/// One durable transcript row of the Notes conversation. `role` is the
/// ORIGINAL persisted vocabulary (`user` | `assistant` | `system`). Model and
/// tool text is data, never authority.
public struct NotesTranscriptEntry: Sendable, Equatable {
    public var id: UUID
    public var role: String
    public var text: String
    public var createdAtMillis: Int64
    public var runID: UUID?
    /// Durable run outcome vocabulary: ACTIVE | COMPLETED | CANCELLED | FAILED |
    /// CHECKPOINTED | INTERRUPTED. nil = genuinely unknown (never guessed).
    public var outcome: String?

    public init(id: UUID, role: String, text: String,
                createdAtMillis: Int64, runID: UUID?,
                outcome: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAtMillis = createdAtMillis
        self.runID = runID
        self.outcome = outcome
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "id": id.uuidString,
            "role": role,
            "text": text,
            "createdAt": createdAtMillis,
        ]
        object["runID"] = runID?.uuidString ?? NSNull()
        object["outcome"] = outcome ?? NSNull()
        return object
    }
}

public struct NotesTranscriptPage: Sendable, Equatable {
    public var entries: [NotesTranscriptEntry]
    /// Opaque cursor for older rows (`millis|uuid`), nil at the beginning.
    public var olderCursor: String?
    public var hasOlder: Bool

    public init(entries: [NotesTranscriptEntry],
                olderCursor: String?,
                hasOlder: Bool) {
        self.entries = entries
        self.olderCursor = olderCursor
        self.hasOlder = hasOlder
    }

    public var wireObject: [String: Any] {
        [
            "entries": entries.map(\.wireObject),
            "olderCursor": olderCursor ?? NSNull(),
            "hasOlder": hasOlder,
        ]
    }

    static func cursor(_ cursor: ConversationMessageCursor) -> String {
        "\(Int64(cursor.createdAt.timeIntervalSince1970 * 1000))|\(cursor.messageID.uuidString)"
    }

    static func parseCursor(_ raw: String?) throws -> ConversationMessageCursor? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let millis = Int64(parts[0]),
              let messageID = UUID(uuidString: String(parts[1])) else {
            throw NotesAssistantRefusal(.invalidPayload, "cursorInvalid")
        }
        return ConversationMessageCursor(
            createdAt: Date(timeIntervalSince1970: Double(millis) / 1000),
            messageID: messageID)
    }
}

// MARK: - Lifecycle

/// Result of `assistant.prepareRootStop`. `canRetire` is the ONLY field a
/// caller may use to allow the root to retire: it becomes true exactly when
/// this domain fenced Notes admission AND every owned Notes run/child/tool
/// token it knows about really detached. A timeout or a cancel ACK is never
/// reported as drained.
public struct NotesStopReport: Sendable, Equatable {
    public var canRetire: Bool
    public var fenced: Bool
    /// Exact run ids still attached after the bounded wait (identifier only).
    public var pendingRunIDs: [UUID]
    /// Stable reason (`drained` | `pendingWork` | `runtimeUnavailable` |
    /// `notFenced`).
    public var reason: String

    public init(canRetire: Bool, fenced: Bool,
                pendingRunIDs: [UUID], reason: String) {
        self.canRetire = canRetire
        self.fenced = fenced
        self.pendingRunIDs = pendingRunIDs
        self.reason = reason
    }

    public var wireObject: [String: Any] {
        [
            "canRetire": canRetire,
            "fenced": fenced,
            "pendingRunIDs": pendingRunIDs.map(\.uuidString),
            "reason": reason,
        ]
    }

    public static let runtimeUnavailable = NotesStopReport(
        canRetire: false, fenced: false, pendingRunIDs: [],
        reason: "runtimeUnavailable")
}

// MARK: - Proposal decisions

/// One delivered proposal decision event (already appended to the durable
/// transcript and enqueued as the conversation's pending input).
public struct NotesDecisionDelivery: Sendable, Equatable {
    public var eventID: UUID
    public var proposalID: UUID
    public var documentID: UUID
    public var decision: String
    public var revision: Int?

    public init(eventID: UUID, proposalID: UUID, documentID: UUID,
                decision: String, revision: Int?) {
        self.eventID = eventID
        self.proposalID = proposalID
        self.documentID = documentID
        self.decision = decision
        self.revision = revision
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "eventID": eventID.uuidString,
            "proposalID": proposalID.uuidString,
            "documentID": documentID.uuidString,
            "decision": decision,
        ]
        object["revision"] = revision ?? NSNull()
        return object
    }
}

// MARK: - Review report

/// Sendable result of the trusted review/commit step. Only identifier/scalar
/// values cross the actor boundary; the tool converts it to its JSON output.
public struct NotesReviewReport: Sendable, Equatable {
    /// `applied` | `pendingUserDecision` | `conflict`
    public var status: String
    public var applied: Bool
    public var appliedRevision: Int?
    public var replayed: Bool
    /// Stable reason code when not applied.
    public var reason: String?

    public init(status: String, applied: Bool, appliedRevision: Int? = nil,
                replayed: Bool = false, reason: String? = nil) {
        self.status = status
        self.applied = applied
        self.appliedRevision = appliedRevision
        self.replayed = replayed
        self.reason = reason
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "status": status,
            "applied": applied,
            "replayed": replayed,
        ]
        object["appliedRevision"] = appliedRevision ?? NSNull()
        object["reason"] = reason ?? NSNull()
        return object
    }
}

// MARK: - Action vocabulary

/// Closed additive actions on the EXISTING `floe.notes/4` channel. No new
/// bridge version, C ABI entry or JNI file is introduced; Main registers this
/// list in `NotesDomainService.actions` and routes it to
/// `NotesAssistantDomain.shared`.
public enum NotesAssistantActions {
    public static let status = "assistant.status"
    public static let open = "assistant.open"
    public static let start = "assistant.start"
    public static let transcript = "assistant.transcript"
    public static let cancel = "assistant.cancel"
    public static let stopForRestart = "assistant.stopForRestart"
    public static let prepareRootStop = "assistant.prepareRootStop"
    public static let abortRootStop = "assistant.abortRootStop"
    public static let drainDecisions = "assistant.drainDecisions"
    /// Trusted review/commit step for ONE just-created proposal. Never a model
    /// tool action: the assistant domain calls it after `notes.edit` produced a
    /// durable proposal, and it revalidates ownership, provenance, review policy
    /// and the exact revision/fingerprint before minting the internal grant.
    public static let reviewCommit = "assistant.reviewCommit"
    /// Explicit restart: stop/drain the old Notes run, then bind a NEW durable
    /// thread for the document (the native bind transaction revokes the old
    /// scope; old messages/runs stay durable). Never an automatic retry.
    public static let restart = "assistant.restart"

    public static let all: [String] = [
        status, open, start, transcript, cancel, stopForRestart,
        prepareRootStop, abortRootStop, drainDecisions, reviewCommit, restart,
    ]

    public static func handles(_ action: String) -> Bool {
        all.contains(action)
    }
}
