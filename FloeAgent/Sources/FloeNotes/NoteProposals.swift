// SPDX-License-Identifier: MPL-2.0
import Foundation
import Crypto

/// Stable JSON fingerprint of a decoded document. The Notes store owns the
/// revision counter; this SHA-256 pins a proposal to the exact decoded
/// document JSON (title, text, frames, structure AND the content-addressed
/// resource IDs), so an out-of-band rewrite at the same revision still fails
/// closed. It deliberately does NOT hash the referenced resource bytes; those
/// are pinned separately by their content-addressed CAS IDs. Encoding is
/// canonical (`sortedKeys`) so re-decoding yields the same digest.
public enum NoteDocumentFingerprint {
    public static func sha256(of document: NoteDocument) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(document)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Human-readable difference between the proposal baseline and the validated
/// in-memory result. Pure and deterministic; used by `notes.edit action=propose`
/// previews and by the editor's accept banner.
public enum NoteProposalSummary {
    public static func describe(before: NoteDocument, after: NoteDocument) -> String {
        var lines: [String] = []
        if before.title != after.title { lines.append("标题：“\(before.title)” → “\(after.title)”") }
        if before.isFavorite != after.isFavorite { lines.append(after.isFavorite ? "加入收藏" : "取消收藏") }
        if before.notebookID != after.notebookID { lines.append("移动到其他笔记本") }
        if before.tags != after.tags { lines.append("标签：\(before.tags.joined(separator: "、")) → \(after.tags.joined(separator: "、"))") }
        if before.officeResourceID != after.officeResourceID { lines.append("替换 Office 正文资源") }
        if before.engineeringResourceID != after.engineeringResourceID { lines.append("替换工程图资源") }

        let beforePages = Dictionary(before.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterPages = Dictionary(after.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let addedPages = after.pages.filter { beforePages[$0.id] == nil }.count
        let removedPages = before.pages.filter { afterPages[$0.id] == nil }.count
        if addedPages > 0 || removedPages > 0 { lines.append("页面：新增 \(addedPages)，删除 \(removedPages)") }
        var addedElements = 0, updatedElements = 0, removedElements = 0
        var pageStyleChanges = 0
        for page in after.pages {
            guard let old = beforePages[page.id] else { continue }
            if old.paper != page.paper || old.drawingResourceID != page.drawingResourceID
                || old.backgroundResourceID != page.backgroundResourceID
                || (old.extractedText ?? "") != (page.extractedText ?? "") {
                pageStyleChanges += 1
            }
            let oldElements = Dictionary(old.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newElements = Dictionary(page.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, element) in newElements {
                if let previous = oldElements[id] {
                    if previous != element { updatedElements += 1 }
                } else { addedElements += 1 }
            }
            removedElements += oldElements.keys.filter { newElements[$0] == nil }.count
        }
        if addedElements > 0 || updatedElements > 0 || removedElements > 0 {
            lines.append("文字/元素：新增 \(addedElements)，修改 \(updatedElements)，删除 \(removedElements)")
        }
        if pageStyleChanges > 0 { lines.append("页面属性（纸张/背景/提取文本）：修改 \(pageStyleChanges) 页") }

        let beforeNodes = Dictionary(before.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterNodes = Dictionary(after.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let addedNodes = after.nodes.filter { beforeNodes[$0.id] == nil }.count
        let removedNodes = before.nodes.filter { afterNodes[$0.id] == nil }.count
        var updatedNodes = 0
        for (id, node) in afterNodes where beforeNodes[id] != nil && beforeNodes[id] != node { updatedNodes += 1 }
        if addedNodes > 0 || updatedNodes > 0 || removedNodes > 0 {
            lines.append("主题：新增 \(addedNodes)，修改 \(updatedNodes)，删除 \(removedNodes)")
        }

        let beforeEdges = Dictionary(before.connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterEdges = Dictionary(after.connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let addedEdges = after.connections.filter { beforeEdges[$0.id] == nil }.count
        let removedEdges = before.connections.filter { afterEdges[$0.id] == nil }.count
        var updatedEdges = 0
        for (id, edge) in afterEdges where beforeEdges[id] != nil && beforeEdges[id] != edge { updatedEdges += 1 }
        if addedEdges > 0 || updatedEdges > 0 || removedEdges > 0 {
            lines.append("关联线：新增 \(addedEdges)，修改 \(updatedEdges)，删除 \(removedEdges)")
        }

        let beforeSummaries = Dictionary((before.summaries ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterSummaries = Dictionary((after.summaries ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let addedSummaries = (after.summaries ?? []).filter { beforeSummaries[$0.id] == nil }.count
        let removedSummaries = (before.summaries ?? []).filter { afterSummaries[$0.id] == nil }.count
        var updatedSummaries = 0
        for (id, value) in afterSummaries where beforeSummaries[id] != nil && beforeSummaries[id] != value { updatedSummaries += 1 }
        if addedSummaries > 0 || updatedSummaries > 0 || removedSummaries > 0 {
            lines.append("概要：新增 \(addedSummaries)，修改 \(updatedSummaries)，删除 \(removedSummaries)")
        }
        if before.mindMapDirection != after.mindMapDirection { lines.append("导图方向已修改") }

        let beforeLinks = Dictionary((before.linkedMindMaps ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterLinks = Dictionary((after.linkedMindMaps ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let linkDeltas = Set(beforeLinks.keys).symmetricDifference(Set(afterLinks.keys)).count
            + afterLinks.filter { beforeLinks[$0.key] != $0.value }.count
        if linkDeltas > 0 { lines.append("关联导图已修改") }

        return lines.isEmpty ? "没有可见变化" : lines.joined(separator: "\n")
    }
}

/// The trusted task that created a proposal. Tool-created proposals always
/// carry this; a UI-authored proposal (none exists today) explicitly records
/// nil so the runtime never receives a synthetic decision event for it.
public struct NoteProposalOrigin: Codable, Hashable, Sendable {
    public var conversationID: UUID
    public var environmentID: String?
    public init(conversationID: UUID, environmentID: String? = nil) {
        self.conversationID = conversationID
        self.environmentID = environmentID
    }
}

/// A durable, not-yet-applied edit batch prepared from one exact document
/// revision and fingerprint. Creating it never persists an edit; applying it
/// requires a single-use UI-minted grant.
public struct NoteProposal: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var baseRevision: Int
    /// SHA-256 of the decoded document JSON (title/text/frames/structure and
    /// content-addressed resource IDs). Referenced resource bytes are pinned
    /// separately by their CAS IDs and are not covered by this hash.
    public var baseSHA256: String
    public var title: String
    /// Provenance only: the proposing tool call. It is never reused as the
    /// apply idempotency key.
    public var sourceRequestID: String?
    /// Originating trusted task. Nil is reserved for UI-authored proposals;
    /// tools additionally verify this before preview/apply and never write a
    /// runtime decision event for a nil origin.
    public var origin: NoteProposalOrigin?
    public var edits: [NoteEdit]
    public var summary: String
    public var createdAt: Date
    /// Set only after a successful apply, so a retried apply can return the
    /// receipt instead of re-applying; pending lists hide applied proposals.
    public var appliedAt: Date?
    public var appliedRevision: Int?
    /// Set when the user rejected or the proposal was invalidated. The proposal
    /// file is retained until its durable decision intent is delivered, so a
    /// crash can never lose the origin; the pending UI hides it meanwhile.
    public var resolvedDecision: NoteProposalDecision?
    public var resolvedAt: Date?

    public init(id: UUID = UUID(), documentID: UUID, baseRevision: Int, baseSHA256: String,
                title: String, sourceRequestID: String? = nil, origin: NoteProposalOrigin? = nil,
                edits: [NoteEdit], summary: String,
                createdAt: Date = Date(), appliedAt: Date? = nil, appliedRevision: Int? = nil,
                resolvedDecision: NoteProposalDecision? = nil, resolvedAt: Date? = nil) {
        self.id = id
        self.documentID = documentID
        self.baseRevision = baseRevision
        self.baseSHA256 = baseSHA256
        self.title = title
        self.sourceRequestID = sourceRequestID
        self.origin = origin
        self.edits = edits
        self.summary = summary
        self.createdAt = createdAt
        self.appliedAt = appliedAt
        self.appliedRevision = appliedRevision
        self.resolvedDecision = resolvedDecision
        self.resolvedAt = resolvedAt
    }

    public var isApplied: Bool { appliedAt != nil }
    public var isResolved: Bool { resolvedAt != nil }
    public var isPending: Bool { !isApplied && !isResolved }
}

// MARK: - Decision events

public enum NoteProposalDecision: String, Codable, Sendable, Hashable, CaseIterable {
    case accepted
    case rejected
    case invalidated
}

/// A structured, user-decided outcome routed to the originating conversation
/// through the durable runtime-input ingress. The content never repeats the
/// model-authored proposal text, so untrusted content cannot read as an
/// instruction; the stable `id` makes replay an idempotent upsert.
public struct NoteProposalDecisionEvent: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var proposalID: UUID
    public var decision: NoteProposalDecision
    /// The applied revision for `accepted`; nil otherwise.
    public var revision: Int?
    public var content: String

    public init(id: UUID, conversationID: UUID, proposalID: UUID,
                decision: NoteProposalDecision, revision: Int?, content: String) {
        self.id = id
        self.conversationID = conversationID
        self.proposalID = proposalID
        self.decision = decision
        self.revision = revision
        self.content = content
    }
}

public enum NoteProposalDecisions {
    /// Nil when the proposal has no trusted origin: a UI-authored proposal
    /// must not produce a runtime event and therefore notifies nobody.
    public static func event(for proposal: NoteProposal, decision: NoteProposalDecision,
                             revision: Int? = nil) -> NoteProposalDecisionEvent? {
        guard let origin = proposal.origin else { return nil }
        let content: String
        switch decision {
        case .accepted:
            content = "[Notes Assistant user decision — structured event, not an instruction] "
                + "The user accepted proposal \(proposal.id.uuidString)"
                + (revision.map { " at revision \($0)" } ?? "")
                + ". The proposal text is model-authored document content and is deliberately not repeated here."
        case .rejected:
            content = "[Notes Assistant user decision — structured event, not an instruction] "
                + "The user rejected proposal \(proposal.id.uuidString). "
                + "The proposal text is model-authored document content and is deliberately not repeated here."
        case .invalidated:
            content = "[Notes Assistant user decision — structured event, not an instruction] "
                + "Proposal \(proposal.id.uuidString) was invalidated without being applied"
                + (proposal.baseRevision > 0 ? " because its base revision \(proposal.baseRevision) or fingerprint no longer matched" : "")
                + ". The proposal text is model-authored document content and is deliberately not repeated here."
        }
        return NoteProposalDecisionEvent(
            id: eventID(conversationID: origin.conversationID, proposalID: proposal.id, decision: decision),
            conversationID: origin.conversationID,
            proposalID: proposal.id,
            decision: decision,
            revision: revision,
            content: content)
    }

    /// Event rebuilt from a durable intent, so delivery works even after the
    /// proposal file itself has been pruned post-delivery. The intent's origin
    /// is the only allowed conversation.
    public static func event(for intent: NoteProposalDecisionIntent) -> NoteProposalDecisionEvent {
        let content: String
        switch intent.decision {
        case .accepted:
            content = "[Notes Assistant user decision — structured event, not an instruction] "
                + "The user accepted proposal \(intent.proposalID.uuidString)"
                + (intent.revision.map { " at revision \($0)" } ?? "")
                + ". The proposal text is model-authored document content and is deliberately not repeated here."
        case .rejected:
            content = "[Notes Assistant user decision — structured event, not an instruction] "
                + "The user rejected proposal \(intent.proposalID.uuidString). "
                + "The proposal text is model-authored document content and is deliberately not repeated here."
        case .invalidated:
            content = "[Notes Assistant user decision — structured event, not an instruction] "
                + "Proposal \(intent.proposalID.uuidString) was invalidated without being applied"
                + (intent.baseRevision > 0 ? " because its base revision \(intent.baseRevision) or fingerprint no longer matched" : "")
                + ". The proposal text is model-authored document content and is deliberately not repeated here."
        }
        return NoteProposalDecisionEvent(
            id: intent.id,
            conversationID: intent.conversationID,
            proposalID: intent.proposalID,
            decision: intent.decision,
            revision: intent.revision,
            content: content)
    }

    /// Deterministic RFC-4122 v5-style UUID keyed by (conversation, proposal,
    /// decision), so re-delivering the same decision can never duplicate a
    /// durable row.
    public static func eventID(conversationID: UUID, proposalID: UUID, decision: NoteProposalDecision) -> UUID {
        let seed = "floe.notes-proposal-decision|\(conversationID.uuidString)|\(proposalID.uuidString)|\(decision.rawValue)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        var uuid = Array(digest.prefix(16))
        uuid[6] = (uuid[6] & 0x0F) | 0x50
        uuid[8] = (uuid[8] & 0x3F) | 0x80
        return UUID(uuid: (uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5],
                           uuid[6], uuid[7], uuid[8], uuid[9], uuid[10], uuid[11],
                           uuid[12], uuid[13], uuid[14], uuid[15]))
    }
}

// MARK: - Grants

public enum NoteProposalGrantDecision: Sendable, Equatable {
    case authorized
    case unknownGrant
    case expired
    case documentMismatch
    case alreadyConsumed
    case revisionMismatch(expected: Int, actual: Int)
    case shaMismatch(expected: String, actual: String)
}

public enum NoteProposalGrantReservation: Sendable, Equatable {
    case reserved
    case unknownGrant
    case expired
    case documentMismatch
    case alreadyConsumed
    case alreadyReserved
    case revisionMismatch(expected: Int, actual: Int)
    case shaMismatch(expected: String, actual: String)
}

/// Single-use, expiring, opaque grant store. Only the interactive editor calls
/// `issueGrant` (its accept control); a value arriving in a tool request is not
/// authority. Any revision or fingerprint change invalidates a pending grant.
public actor NoteProposalGrantStore {
    private struct Entry {
        let proposalID: UUID
        let documentID: UUID
        let revision: Int
        let sha256: String
        let expiresAt: Date
        var consumed: Bool
        var reserved: Bool
    }

    private var entries: [String: Entry] = [:]
    private let timeToLive: TimeInterval
    private let idProvider: @Sendable () -> String

    public init(timeToLive: TimeInterval = 300, idProvider: @escaping @Sendable () -> String = {
        (0..<4).map { _ in UUID().uuidString }.joined(separator: "")
    }) {
        self.timeToLive = timeToLive
        self.idProvider = idProvider
    }

    @discardableResult
    public func issueGrant(proposal: NoteProposal, now: Date = Date()) -> String {
        sweep(now: now)
        let id = idProvider()
        entries[id] = Entry(proposalID: proposal.id, documentID: proposal.documentID,
                            revision: proposal.baseRevision, sha256: proposal.baseSHA256,
                            expiresAt: now.addingTimeInterval(timeToLive), consumed: false, reserved: false)
        return id
    }

    public func consume(grantID: String, proposalID: UUID, documentID: UUID, revision: Int,
                        sha256: String, now: Date = Date()) -> NoteProposalGrantDecision {
        guard var entry = entries[grantID] else { return .unknownGrant }
        if entry.expiresAt <= now {
            entries.removeValue(forKey: grantID)
            return .expired
        }
        guard entry.proposalID == proposalID, entry.documentID == documentID else { return .documentMismatch }
        if entry.consumed || entry.reserved { return .alreadyConsumed }
        if entry.revision != revision { return .revisionMismatch(expected: entry.revision, actual: revision) }
        if entry.sha256.lowercased() != sha256.lowercased() {
            return .shaMismatch(expected: entry.sha256, actual: sha256)
        }
        entry.consumed = true
        entries[grantID] = entry
        sweep(now: now)
        return .authorized
    }

    /// Validates and marks the grant reserved without consuming it, so a failed
    /// apply can release it and the user can retry inside the TTL.
    public func reserve(grantID: String, proposalID: UUID, documentID: UUID, revision: Int,
                        sha256: String, now: Date = Date()) -> NoteProposalGrantReservation {
        guard var entry = entries[grantID] else { return .unknownGrant }
        if entry.expiresAt <= now {
            entries.removeValue(forKey: grantID)
            return .expired
        }
        guard entry.proposalID == proposalID, entry.documentID == documentID else { return .documentMismatch }
        if entry.consumed { return .alreadyConsumed }
        if entry.reserved { return .alreadyReserved }
        if entry.revision != revision { return .revisionMismatch(expected: entry.revision, actual: revision) }
        if entry.sha256.lowercased() != sha256.lowercased() {
            return .shaMismatch(expected: entry.sha256, actual: sha256)
        }
        entry.reserved = true
        entries[grantID] = entry
        sweep(now: now)
        return .reserved
    }

    @discardableResult
    public func commitReservation(grantID: String) -> Bool {
        guard var entry = entries[grantID], entry.reserved, !entry.consumed else { return false }
        entry.reserved = false
        entry.consumed = true
        entries[grantID] = entry
        return true
    }

    public func releaseReservation(grantID: String) {
        guard var entry = entries[grantID], entry.reserved, !entry.consumed else { return }
        entry.reserved = false
        entries[grantID] = entry
    }

    public func revoke(grantID: String) { entries.removeValue(forKey: grantID) }

    @discardableResult
    private func sweep(now: Date) -> Int {
        let expired = entries.filter { $0.value.expiresAt <= now }.map(\.key)
        for key in expired { entries.removeValue(forKey: key) }
        return expired.count
    }
}

// MARK: - Durable pending proposals

/// Persistence seam for proposals so failure-injection tests can prove the
/// crash-consistency of the decision outbox. `NoteProposalStore` is the live
/// file-backed implementation.
public protocol NoteProposalPersisting: Sendable {
    func save(_ proposal: NoteProposal) async throws
    func load(_ id: UUID) async -> NoteProposal?
    func remove(_ id: UUID) async throws
    func pending(documentID: UUID) async -> [NoteProposal]
    func all() async -> [NoteProposal]
}

/// File-backed pending proposals under the Notes support directory. Atomic
/// writes; a corrupt or foreign file is ignored instead of hiding the rest.
public actor NoteProposalStore: NoteProposalPersisting {
    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(root: URL) { self.root = root }

    private func file(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).json") }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func save(_ proposal: NoteProposal) throws {
        try prepareRoot()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(proposal).write(to: file(proposal.id), options: .atomic)
    }

    public func load(_ id: UUID) -> NoteProposal? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? decoder.decode(NoteProposal.self, from: data)
    }

    public func remove(_ id: UUID) throws {
        let url = file(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Oldest first. Applied or resolved proposals stay durable (for
    /// idempotent retries and post-crash repair) but are hidden from the
    /// editor's pending list.
    public func pending(documentID: UUID) -> [NoteProposal] {
        all().filter { $0.documentID == documentID && $0.isPending }
    }

    public func all() -> [NoteProposal] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(NoteProposal.self, from: data)
            }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
}

// MARK: - Propose / preview / apply service

public enum NoteProposalService {
    public static func propose(document: NoteDocument, title: String, edits: [NoteEdit],
                               sourceRequestID: String? = nil, origin: NoteProposalOrigin? = nil,
                               store: any NoteProposalPersisting,
                               now: Date = Date()) async throws -> NoteProposal {
        guard !edits.isEmpty else { throw NoteError.invalidOperation("提案不包含任何编辑。") }
        var draft = document
        for edit in edits { try edit.apply(to: &draft) }
        try draft.validate()
        let proposal = NoteProposal(
            documentID: document.id,
            baseRevision: document.revision,
            baseSHA256: NoteDocumentFingerprint.sha256(of: document),
            title: title,
            sourceRequestID: sourceRequestID,
            origin: origin,
            edits: edits,
            summary: NoteProposalSummary.describe(before: document, after: draft),
            createdAt: now)
        try await store.save(proposal)
        return proposal
    }

    /// A proposal is agent-visible only to the exact trusted origin task that
    /// created it: matching conversation AND environment. UI-authored
    /// proposals (origin nil) and proposals from any other task are invisible,
    /// so a same-document read grant can never reveal or apply them.
    public static func toolVisibleProposal(proposalID: UUID, conversationID: UUID,
                                           environmentID: String?,
                                           store: any NoteProposalPersisting) async -> NoteProposal? {
        guard let proposal = await store.load(proposalID),
              let origin = proposal.origin,
              origin.conversationID == conversationID,
              origin.environmentID == environmentID else { return nil }
        return proposal
    }

    /// Deterministic apply key, so a retried apply after a transport failure
    /// returns the receipt from the single committed batch.
    public static func applyRequestID(proposalID: UUID) -> String {
        "notes.proposal.apply.\(proposalID.uuidString)"
    }

    /// Accepts a proposal. The write-ahead decision intent is persisted BEFORE
    /// the document commit, so a crash in any gap is recoverable: recovery sees
    /// the commit receipt and finalizes, re-applies a not-yet-committed
    /// acceptance, or converts a stale acceptance into a durable invalidation.
    /// A UI-authored proposal (origin nil) has no intent and notifies nobody.
    @discardableResult
    public static func apply(proposalID: UUID, grantID: String,
                             requestID: String? = nil,
                             store: NotesStore, proposals: any NoteProposalPersisting,
                             outbox: any NoteProposalIntentPersisting,
                             grants: NoteProposalGrantStore,
                             authorizedConversationID: UUID? = nil,
                             expectedEnvironmentID: String? = nil,
                             now: Date = Date()) async throws -> NoteDocument {
        guard let proposal = await proposals.load(proposalID) else { throw NoteError.notFound }
        // Origin ownership is checked before the idempotency receipt: a foreign
        // task must not even learn that a receipt exists.
        if let conversation = authorizedConversationID {
            guard let origin = proposal.origin,
                  origin.conversationID == conversation,
                  origin.environmentID == expectedEnvironmentID else { throw NoteError.notFound }
            try await store.authorize(conversationID: conversation, documentID: proposal.documentID, editing: true)
        }
        let idempotencyKey = requestID ?? Self.applyRequestID(proposalID: proposalID)
        // A retried apply never re-applies: the store receipt is the outcome.
        // Repair the durable intent/proposal state in case the process died
        // between the commit and the intent finalization. Genuine committed
        // replay is allowed even after the proposal was later resolved.
        if let receipt = try await store.editReceipt(requestID: idempotencyKey, documentID: proposal.documentID) {
            if proposal.origin != nil {
                let intent = NoteProposalDecisionIntent(proposal: proposal, decision: .accepted,
                                                        revision: receipt.revision, phase: .recorded,
                                                        operationID: idempotencyKey, now: now)
                if await outbox.load(intent.id) == nil { try? await outbox.save(intent) }
            }
            var applied = proposal
            applied.appliedAt = applied.appliedAt ?? now
            applied.appliedRevision = receipt.revision
            try? await proposals.save(applied)
            return receipt
        }
        // An applied proposal without a receipt under THIS operation id was
        // committed under another id: never re-apply it or treat it as stale.
        if proposal.isApplied {
            throw NoteError.conflict
        }
        // A resolved proposal (rejected/invalidated) must be refused BEFORE the
        // grant is reserved, even while its file is still on disk.
        if proposal.isResolved {
            throw NoteError.invalidOperation("提案已被拒绝或失效，未应用。")
        }
        let current = try await store.document(proposal.documentID)
        guard current.revision == proposal.baseRevision,
              NoteDocumentFingerprint.sha256(of: current) == proposal.baseSHA256 else {
            // A stale acceptance is a real decision: persist the durable
            // invalidation for the origin before failing.
            try? await supersedeFailedAcceptance(proposal: proposal, committing: nil,
                                                 proposals: proposals, outbox: outbox, now: now)
            throw NoteError.conflict
        }
        switch await grants.reserve(grantID: grantID, proposalID: proposalID, documentID: proposal.documentID,
                                    revision: proposal.baseRevision, sha256: proposal.baseSHA256, now: now) {
        case .reserved:
            break
        case .unknownGrant, .alreadyConsumed, .alreadyReserved, .expired:
            throw NoteError.invalidOperation("提案确认已失效，请在编辑器中重新确认。")
        case .documentMismatch, .revisionMismatch, .shaMismatch:
            throw NoteError.conflict
        }
        // Durable WAL: never commit the document before the decision intent is
        // on disk, or a crash would lose the origin and the user's decision.
        // The intent stores the EXACT operation id so a recovered retry checks
        // the same receipt instead of the stable default.
        var intent: NoteProposalDecisionIntent?
        if proposal.origin != nil {
            let pending = NoteProposalDecisionIntent(proposal: proposal, decision: .accepted,
                                                     revision: nil, phase: .committing,
                                                     operationID: idempotencyKey, now: now)
            do {
                try await outbox.save(pending)
                intent = pending
            } catch {
                await grants.releaseReservation(grantID: grantID)
                throw error
            }
        }
        let batch = NoteEditBatch(documentID: proposal.documentID, expectedRevision: proposal.baseRevision,
                                  title: proposal.title, edits: proposal.edits, requestID: idempotencyKey)
        do {
            let value = try await store.apply(batch, authorizedConversationID: authorizedConversationID)
            await grants.commitReservation(grantID: grantID)
            var applied = proposal
            applied.appliedAt = applied.appliedAt ?? now
            applied.appliedRevision = value.revision
            // Both writes below are repaired by recovery from the store receipt
            // if the process dies here.
            try? await proposals.save(applied)
            if var intent {
                intent.phase = .recorded
                intent.revision = value.revision
                intent.updatedAt = now
                try? await outbox.save(intent)
            }
            return value
        } catch {
            await grants.releaseReservation(grantID: grantID)
            if let intent {
                // The acceptance never committed: persist the durable terminal
                // outcome FIRST, then supersede the old intent. A crash in
                // between leaves a terminal sibling that recovery prefers over
                // replaying the failed acceptance.
                try? await supersedeFailedAcceptance(proposal: proposal, committing: intent,
                                                     proposals: proposals, outbox: outbox, now: now)
            }
            throw error
        }
    }

    /// Persists a durable rejection/invalidation decision. The intent is
    /// written BEFORE the proposal resolution state so a crash cannot lose the
    /// origin; delivery then runs through `NoteProposalDecisionDelivery`. An
    /// origin-less (UI-authored) proposal is resolved without an intent and
    /// notifies nobody. Returns nil when the proposal is already gone.
    @discardableResult
    public static func resolve(proposalID: UUID, decision: NoteProposalDecision,
                               proposals: any NoteProposalPersisting,
                               outbox: any NoteProposalIntentPersisting,
                               now: Date = Date()) async throws -> NoteProposal? {
        guard decision != .accepted else {
            throw NoteError.invalidOperation("接受的提案必须通过 apply 持久化。")
        }
        guard let proposal = await proposals.load(proposalID) else { return nil }
        if proposal.origin != nil {
            let intent = NoteProposalDecisionIntent(proposal: proposal, decision: decision,
                                                    revision: nil, phase: .recorded, now: now)
            if await outbox.load(intent.id) == nil {
                try await outbox.save(intent)
            }
        }
        var resolved = proposal
        resolved.resolvedDecision = decision
        resolved.resolvedAt = now
        try await proposals.save(resolved)
        return resolved
    }

    /// Persists the durable invalidation outcome, then supersedes any failed
    /// acceptance intent. The terminal intent is written before the old intent
    /// is removed, so a crash between the two is recovered by preferring the
    /// terminal sibling over replaying the failed acceptance.
    private static func supersedeFailedAcceptance(proposal: NoteProposal,
                                                  committing: NoteProposalDecisionIntent?,
                                                  proposals: any NoteProposalPersisting,
                                                  outbox: any NoteProposalIntentPersisting,
                                                  now: Date) async throws {
        guard proposal.origin != nil else { return }
        let intent = NoteProposalDecisionIntent(proposal: proposal, decision: .invalidated,
                                                revision: nil, phase: .recorded, now: now)
        try await outbox.save(intent)
        var resolved = proposal
        resolved.resolvedDecision = .invalidated
        resolved.resolvedAt = now
        try await proposals.save(resolved)
        if let committing {
            try await outbox.remove(committing.id)
        }
    }
}
