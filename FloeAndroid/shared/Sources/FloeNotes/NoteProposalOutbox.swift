// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A durable decision intent written as a write-ahead record BEFORE the
/// proposal state mutation it describes. A crash after the intent is durable
/// but before the acceptance commit, the delivery enqueue or the transcript
/// append is always recoverable: the intent carries the origin, the exact
/// commit operation id and enough binding (document, base revision, base
/// fingerprint) to finish or invalidate the operation, and its stable id
/// equals the decision event id so replays upsert instead of duplicating.
public struct NoteProposalDecisionIntent: Codable, Hashable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable, Hashable {
        /// Acceptance committed (or is about to commit) the document edit; the
        /// intent must be finalized before it can be delivered.
        case committing
        /// The decision outcome is final and deliverable.
        case recorded
    }

    public var id: UUID
    public var proposalID: UUID
    public var documentID: UUID
    public var conversationID: UUID
    public var environmentID: String?
    public var decision: NoteProposalDecision
    public var baseRevision: Int
    public var baseSHA256: String
    /// Applied revision for `accepted` once the commit is confirmed.
    public var revision: Int?
    /// The exact `store.apply` operation id used for the acceptance commit.
    /// Recovery checks the receipt and re-applies under THIS id, never a
    /// different one. Nil on legacy/terminal intents falls back to the stable
    /// shared id.
    public var operationID: String?
    public var phase: Phase
    public var createdAt: Date
    public var updatedAt: Date
    public var deliveredAt: Date?
    public var lastFailure: String?
    /// Short delivery lease so two concurrent flushes cannot both drive the
    /// same intent. Cleared on delivered/failure.
    public var claimedAt: Date?

    public init(id: UUID, proposalID: UUID, documentID: UUID, conversationID: UUID,
                environmentID: String?, decision: NoteProposalDecision, baseRevision: Int,
                baseSHA256: String, revision: Int?, operationID: String?, phase: Phase,
                createdAt: Date, updatedAt: Date, deliveredAt: Date? = nil,
                lastFailure: String? = nil, claimedAt: Date? = nil) {
        self.id = id
        self.proposalID = proposalID
        self.documentID = documentID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.decision = decision
        self.baseRevision = baseRevision
        self.baseSHA256 = baseSHA256
        self.revision = revision
        self.operationID = operationID
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deliveredAt = deliveredAt
        self.lastFailure = lastFailure
        self.claimedAt = claimedAt
    }

    public init(proposal: NoteProposal, decision: NoteProposalDecision, revision: Int?,
                phase: Phase, operationID: String? = nil, now: Date = Date()) {
        let origin = proposal.origin!
        self.init(
            id: NoteProposalDecisions.eventID(conversationID: origin.conversationID,
                                              proposalID: proposal.id, decision: decision),
            proposalID: proposal.id,
            documentID: proposal.documentID,
            conversationID: origin.conversationID,
            environmentID: origin.environmentID,
            decision: decision,
            baseRevision: proposal.baseRevision,
            baseSHA256: proposal.baseSHA256,
            revision: revision,
            operationID: operationID,
            phase: phase,
            createdAt: now,
            updatedAt: now)
    }

    public var isDelivered: Bool { deliveredAt != nil }

    /// The one operation id that receipt lookup and recovered re-apply agree
    /// on. A commitment stores its exact caller id here; legacy intents use
    /// the stable shared id.
    public var commitOperationID: String {
        operationID ?? NoteProposalService.applyRequestID(proposalID: proposalID)
    }
}

/// Durable intent persistence seam. `NoteProposalOutbox` is the live
/// file-backed implementation; tests wrap it to inject write failures.
public protocol NoteProposalIntentPersisting: Sendable {
    func save(_ intent: NoteProposalDecisionIntent) async throws
    func load(_ id: UUID) async -> NoteProposalDecisionIntent?
    func pendingDecisions() async -> [NoteProposalDecisionIntent]
    /// Returns true when this caller acquired the short delivery lease.
    func claim(_ id: UUID, at date: Date) async -> Bool
    func markDelivered(_ id: UUID, at date: Date) async throws
    func recordFailure(_ id: UUID, reason: String) async throws
    func remove(_ id: UUID) async throws
}

/// Delivery sink for one final decision event. The live app implementation
/// performs the runtime-input enqueue AND the transcript append and only
/// returns success when BOTH succeeded; a partial success throws, so the
/// caller never marks the intent delivered.
public protocol NoteProposalDecisionTransport: Sendable {
    func deliver(_ event: NoteProposalDecisionEvent) async throws
}

/// File-backed decision outbox: one JSON per intent, atomic writes, oldest
/// first. Delivered intents stay on disk as the replay receipt.
public actor NoteProposalOutbox: NoteProposalIntentPersisting {
    public static let claimLease: TimeInterval = 120
    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(root: URL) { self.root = root }

    private func file(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).json") }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func save(_ intent: NoteProposalDecisionIntent) throws {
        try prepareRoot()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(intent).write(to: file(intent.id), options: .atomic)
    }

    public func load(_ id: UUID) -> NoteProposalDecisionIntent? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? decoder.decode(NoteProposalDecisionIntent.self, from: data)
    }

    public func pendingDecisions() -> [NoteProposalDecisionIntent] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(NoteProposalDecisionIntent.self, from: data)
            }
            .filter { !$0.isDelivered }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    public func claim(_ id: UUID, at date: Date) -> Bool {
        guard var intent = load(id), !intent.isDelivered else { return false }
        if let claimedAt = intent.claimedAt, date.timeIntervalSince(claimedAt) < Self.claimLease {
            return false
        }
        intent.claimedAt = date
        intent.updatedAt = date
        guard (try? save(intent)) != nil else { return false }
        return true
    }

    public func markDelivered(_ id: UUID, at date: Date) throws {
        guard var intent = load(id) else { return }
        intent.deliveredAt = date
        intent.updatedAt = date
        intent.lastFailure = nil
        intent.claimedAt = nil
        try save(intent)
    }

    public func recordFailure(_ id: UUID, reason: String) throws {
        guard var intent = load(id) else { return }
        intent.lastFailure = reason
        intent.updatedAt = Date()
        intent.claimedAt = nil
        try save(intent)
    }

    public func remove(_ id: UUID) throws {
        let url = file(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

public struct NoteProposalDeliveryReport: Sendable, Equatable {
    public var delivered: [UUID] = []
    public var pending: [UUID] = []
    public var failures: [UUID: String] = [:]
    public var repaired: [UUID] = []
    public var invalidated: [UUID] = []
    /// Set when the durable proposal storage itself is unavailable; nothing
    /// was read or written and no temporary fallback was used.
    public var storageFailure: String?

    public init() {}
}

/// Recovery + delivery driver. Call it on editor open, after every accept/
/// reject/invalidate and at the start of a Notes tool call. It first makes
/// every pending intent final (finishing a crashed acceptance from the durable
/// store receipt under the intent's exact operation id, re-applying a
/// not-yet-committed acceptance after revalidating origin authorization, or
/// converting a superseded/stale acceptance into a durable invalidation),
/// then delivers recorded intents and marks them delivered only after the
/// transport reports BOTH writes succeeded. A short outbox claim keeps two
/// concurrent flushes from driving the same intent twice.
public enum NoteProposalDecisionDelivery {
    @discardableResult
    public static func deliverPending(transport: any NoteProposalDecisionTransport,
                                      outbox: any NoteProposalIntentPersisting,
                                      proposals: any NoteProposalPersisting,
                                      store: NotesStore? = nil,
                                      now: Date = Date()) async -> NoteProposalDeliveryReport {
        var report = NoteProposalDeliveryReport()
        let intents = await outbox.pendingDecisions()
        for intent in intents {
            // A sibling processed earlier in this pass may already have
            // delivered (or superseded) this intent.
            if await outbox.load(intent.id)?.isDelivered == true { continue }
            guard await outbox.claim(intent.id, at: now) else {
                report.pending.append(intent.id)
                continue
            }
            do {
                var current = intent
                var supersededWithoutEvent = false
                switch (intent.decision, intent.phase) {
                case (.accepted, .committing):
                    guard let store else {
                        report.pending.append(intent.id)
                        continue
                    }
                    if let receipt = try await store.editReceipt(requestID: intent.commitOperationID,
                                                                 documentID: intent.documentID) {
                        current = try await finalizeAccepted(intent, revision: receipt.revision,
                                                             proposals: proposals, outbox: outbox, now: now)
                        report.repaired.append(current.id)
                    } else if let sibling = await supersedingTerminal(for: intent, outbox: outbox) {
                        // A crash between "write terminal outcome" and "supersede
                        // the old intent" (or a rejection that superseded this
                        // acceptance) must never be replayed as a fresh mutation.
                        if var proposal = await proposals.load(intent.proposalID), !proposal.isResolved {
                            proposal.resolvedDecision = sibling.decision
                            proposal.resolvedAt = now
                            try? await proposals.save(proposal)
                        }
                        try await outbox.remove(intent.id)
                        if sibling.isDelivered {
                            supersededWithoutEvent = true
                        } else {
                            current = sibling
                            report.invalidated.append(sibling.id)
                        }
                    } else if let proposal = await proposals.load(intent.proposalID), proposal.isResolved {
                        let terminal = try await supersedeWithTerminal(intent, proposal: proposal,
                                                                       proposals: proposals, outbox: outbox, now: now)
                        if let terminal {
                            current = terminal
                            report.invalidated.append(terminal.id)
                        } else {
                            supersededWithoutEvent = true
                        }
                    } else if let proposal = await proposals.load(intent.proposalID) {
                        do {
                            // Revalidate the originating task's editing grant before
                            // any recovered mutation, exactly like the normal path.
                            try await store.authorize(conversationID: intent.conversationID,
                                                      documentID: intent.documentID, editing: true)
                        } catch {
                            current = try await convertToInvalidated(intent, proposal: proposal,
                                                                     proposals: proposals, outbox: outbox, now: now)
                            report.invalidated.append(current.id)
                        }
                        if current.id == intent.id {
                            let document = try await store.document(intent.documentID)
                            if document.revision == intent.baseRevision,
                               NoteDocumentFingerprint.sha256(of: document) == intent.baseSHA256 {
                                let value = try await store.apply(NoteEditBatch(
                                    documentID: intent.documentID, expectedRevision: intent.baseRevision,
                                    title: proposal.title, edits: proposal.edits,
                                    requestID: intent.commitOperationID))
                                current = try await finalizeAccepted(intent, revision: value.revision,
                                                                     proposals: proposals, outbox: outbox, now: now)
                                report.repaired.append(current.id)
                            } else {
                                current = try await convertToInvalidated(intent, proposal: proposal,
                                                                         proposals: proposals, outbox: outbox, now: now)
                                report.invalidated.append(current.id)
                            }
                        }
                    } else {
                        // The proposal file is gone and there is no receipt: the
                        // acceptance can never be completed. Invalidate it.
                        current = try await convertToInvalidated(intent, proposal: nil,
                                                                 proposals: proposals, outbox: outbox, now: now)
                        report.invalidated.append(current.id)
                    }
                default:
                    // Rejected/invalidated: repair the proposal's resolved state
                    // before delivery; the intent itself is already final.
                    if let proposal = await proposals.load(intent.proposalID), !proposal.isResolved {
                        var repaired = proposal
                        repaired.resolvedDecision = intent.decision
                        repaired.resolvedAt = intent.updatedAt
                        try? await proposals.save(repaired)
                    }
                }
                if supersededWithoutEvent { continue }
                let event = NoteProposalDecisions.event(for: current)
                try await transport.deliver(event)
                try await outbox.markDelivered(current.id, at: now)
                report.delivered.append(current.id)
                if current.decision != .accepted {
                    try? await proposals.remove(current.proposalID)
                }
            } catch {
                try? await outbox.recordFailure(intent.id, reason: error.localizedDescription)
                report.failures[intent.id] = error.localizedDescription
            }
        }
        return report
    }

    /// Finds a durable terminal intent (rejected/invalidated) for the same
    /// proposal, including one that was already delivered.
    private static func supersedingTerminal(for intent: NoteProposalDecisionIntent,
                                            outbox: any NoteProposalIntentPersisting) async -> NoteProposalDecisionIntent? {
        for decision in [NoteProposalDecision.rejected, .invalidated] {
            let id = NoteProposalDecisions.eventID(conversationID: intent.conversationID,
                                                   proposalID: intent.proposalID, decision: decision)
            if let existing = await outbox.load(id) { return existing }
        }
        return nil
    }

    /// A resolved proposal with no sibling intent yet: materialize the terminal
    /// intent from the durable resolution, then supersede the acceptance.
    private static func supersedeWithTerminal(_ intent: NoteProposalDecisionIntent,
                                              proposal: NoteProposal,
                                              proposals: any NoteProposalPersisting,
                                              outbox: any NoteProposalIntentPersisting,
                                              now: Date) async throws -> NoteProposalDecisionIntent? {
        guard let decision = proposal.resolvedDecision, decision != .accepted else {
            try await outbox.remove(intent.id)
            return nil
        }
        let terminalID = NoteProposalDecisions.eventID(conversationID: intent.conversationID,
                                                       proposalID: intent.proposalID, decision: decision)
        let terminal: NoteProposalDecisionIntent
        if let existing = await outbox.load(terminalID) {
            terminal = existing
        } else {
            terminal = NoteProposalDecisionIntent(proposal: proposal, decision: decision,
                                                  revision: nil, phase: .recorded, now: now)
            try await outbox.save(terminal)
        }
        try await outbox.remove(intent.id)
        return terminal
    }

    /// Finalizes a committed acceptance: the intent becomes recorded with its
    /// revision, and the proposal is marked applied. The intent is written
    /// first so a crash here is repaired from the store receipt on the next run.
    private static func finalizeAccepted(_ intent: NoteProposalDecisionIntent, revision: Int,
                                         proposals: any NoteProposalPersisting,
                                         outbox: any NoteProposalIntentPersisting,
                                         now: Date) async throws -> NoteProposalDecisionIntent {
        var recorded = intent
        recorded.phase = .recorded
        recorded.revision = revision
        recorded.updatedAt = now
        try await outbox.save(recorded)
        if var proposal = await proposals.load(intent.proposalID) {
            proposal.appliedAt = proposal.appliedAt ?? now
            proposal.appliedRevision = revision
            try? await proposals.save(proposal)
        }
        return recorded
    }

    /// A committed acceptance whose baseline moved (or whose authorization was
    /// revoked): the durable accepted intent is replaced by a durable
    /// invalidation, and the proposal is resolved so it cannot be applied later
    /// against the wrong revision. The terminal outcome is written before the
    /// superseded intent is removed, so a crash in that window is recoverable.
    private static func convertToInvalidated(_ intent: NoteProposalDecisionIntent,
                                             proposal: NoteProposal?,
                                             proposals: any NoteProposalPersisting,
                                             outbox: any NoteProposalIntentPersisting,
                                             now: Date) async throws -> NoteProposalDecisionIntent {
        let invalidated = NoteProposalDecisionIntent(
            id: NoteProposalDecisions.eventID(conversationID: intent.conversationID,
                                              proposalID: intent.proposalID, decision: .invalidated),
            proposalID: intent.proposalID,
            documentID: intent.documentID,
            conversationID: intent.conversationID,
            environmentID: intent.environmentID,
            decision: .invalidated,
            baseRevision: intent.baseRevision,
            baseSHA256: intent.baseSHA256,
            revision: nil,
            operationID: nil,
            phase: .recorded,
            createdAt: now,
            updatedAt: now)
        try await outbox.save(invalidated)
        if var proposal {
            proposal.resolvedDecision = .invalidated
            proposal.resolvedAt = now
            try? await proposals.save(proposal)
        }
        try await outbox.remove(intent.id)
        return invalidated
    }
}
