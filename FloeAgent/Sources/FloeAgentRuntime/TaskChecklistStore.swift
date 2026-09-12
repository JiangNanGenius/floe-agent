import Foundation
import Crypto
import GRDB
import FloeCore
import FloePersistence

/// Ordinary execution progress. This is never authorization to start Goal
/// mode and its completion cannot complete a separately verified Goal.
public struct TaskChecklist: Codable, Sendable, Equatable {
    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public enum Status: String, Codable, Sendable { case pending, inProgress, completed, blocked, cancelled }
        public var id: String
        public var title: String
        public var status: Status
        /// Model-supplied evidence references, not independently verified proof.
        public var evidence: [String]
        public init(id: String, title: String, status: Status = .pending, evidence: [String] = []) {
            self.id = id; self.title = title; self.status = status; self.evidence = evidence
        }
        /// Terminal steps are settled history: they may be omitted from the
        /// next update without losing their record in the revisions table.
        public var isTerminal: Bool { status == .completed || status == .cancelled }
    }
    public var conversationID: UUID
    public var runID: UUID
    public var revision: Int
    public var title: String
    public var steps: [Step]
    public var updatedAt: Date
    public var isFinished: Bool { steps.allSatisfy(\.isTerminal) }
    public var completedCount: Int { steps.filter { $0.status == .completed }.count }
    public var cancelledCount: Int { steps.filter { $0.status == .cancelled }.count }
    /// Never counts cancelled work as completed or invents an active step.
    public var progressSummary: String {
        let cancelled = cancelledCount > 0 ? " · 已取消 \(cancelledCount) 项" : ""
        return "已完成 \(completedCount)/\(steps.count) 项\(cancelled)"
    }
    public var currentStep: Step? { steps.first { $0.status == .inProgress } }
    /// Tells the model exactly what the next updatePlan is allowed to do, so
    /// a finished checklist is closed out instead of appended to forever.
    public var lifecycleHint: String {
        if isFinished {
            return "CHECKLIST FINISHED (\(completedCount)/\(steps.count) completed). Your next checklist.updatePlan with a fresh steps array starts a NEW checklist; do not carry these settled steps. Their history stays in the revisions table."
        }
        let open = steps.filter { !$0.isTerminal }.map(\.id)
        return "Checklist in progress (\(completedCount)/\(steps.count) completed). Updates must carry the unfinished step IDs [\(open.joined(separator: ", "))] (or mark them cancelled); completed/cancelled steps may be omitted. Current revision is \(revision)."
    }

    /// A new run may continue the same task. Late receipts and snapshots from
    /// a different conversation must not roll the shared UI backwards.
    public func canReplace(_ previous: TaskChecklist?, conversationID: UUID?) -> Bool {
        guard self.conversationID == conversationID else { return false }
        guard let previous else { return true }
        return previous.conversationID == self.conversationID && revision > previous.revision
    }

}

public struct TaskChecklistUpdate: Codable, Sendable {
    /// Optional optimistic-concurrency guard. Omit to write over the current
    /// revision; provide it to detect an intervening writer.
    public var expectedRevision: Int?
    public var title: String
    public var steps: [TaskChecklist.Step]
    public var startNew: Bool
    public init(expectedRevision: Int? = nil, title: String, steps: [TaskChecklist.Step], startNew: Bool = false) {
        self.expectedRevision = expectedRevision; self.title = title; self.steps = steps; self.startNew = startNew
    }
    /// One failure, one precise reason: a model reading the error must be
    /// able to fix the call in a single retry without re-reading state.
    public func validate() throws {
        if let expectedRevision {
            guard expectedRevision >= 0 else {
                throw FloeError.validationFailed("expectedRevision must be >= 0 (omit it to skip the revision check)")
            }
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...160).contains(trimmedTitle.count) else {
            throw FloeError.validationFailed("Provide a non-empty title of at most 160 characters (yours: \(trimmedTitle.count))")
        }
        guard (1...64).contains(steps.count) else {
            throw FloeError.validationFailed("Provide 1–64 steps (you submitted \(steps.count)); split larger efforts across sequential checklists")
        }
        var seen = Set<String>()
        var duplicated = [String]()
        for step in steps where !seen.insert(step.id).inserted { duplicated.append(step.id) }
        guard duplicated.isEmpty else {
            throw FloeError.validationFailed("Step IDs must be unique; duplicated: \(duplicated.joined(separator: ", "))")
        }
        let inProgress = steps.filter { $0.status == .inProgress }.map(\.id)
        guard inProgress.count <= 1 else {
            throw FloeError.validationFailed("At most one step may be inProgress; you submitted \(inProgress.count): \(inProgress.joined(separator: ", "))")
        }
        for step in steps {
            guard (1...80).contains(step.id.count),
                  step.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) else {
                throw FloeError.validationFailed("Step id '\(step.id)' is invalid: use 1–80 ASCII letters, numbers, '-' or '_'")
            }
            guard (1...240).contains(step.title.trimmingCharacters(in: .whitespacesAndNewlines).count) else {
                throw FloeError.validationFailed("Step '\(step.id)' needs a non-empty title of at most 240 characters")
            }
            guard step.evidence.count <= 4,
                  step.evidence.allSatisfy({ (1...512).contains($0.trimmingCharacters(in: .whitespacesAndNewlines).count) }) else {
                throw FloeError.validationFailed("Step '\(step.id)' allows at most 4 evidence references of 1–512 characters each")
            }
            guard step.status != .completed || !step.evidence.isEmpty else {
                throw FloeError.validationFailed("Step '\(step.id)' is marked completed but has no evidence references; add what proves it (file path, tool receipt, observed result)")
            }
        }
    }
}

public actor TaskChecklistStore {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    public func latest(runID: UUID) async throws -> TaskChecklist? {
        let owner = try await database.reader { db in
            try String.fetchOne(db, sql: "SELECT conversation_id FROM runs WHERE id = ?", arguments: [runID.uuidString])
        }
        guard let owner, let id = UUID(uuidString: owner) else { throw FloeError.validationFailed("Run has no owning task") }
        return try await latest(conversationID: id)
    }

    public func latest(conversationID: UUID) async throws -> TaskChecklist? {
        try await database.reader { db in
            guard let body = try String.fetchOne(db, sql: "SELECT body_json FROM task_checklist_revisions WHERE conversation_id = ? ORDER BY revision DESC LIMIT 1", arguments: [conversationID.uuidString]) else { return nil }
            return try JSONDecoder().decode(TaskChecklist.self, from: Data(body.utf8))
        }
    }

    /// CAS and provider-call deduplication are one transaction. Relaunch or a
    /// retried delivery returns the original result, never another revision.
    public func update(_ update: TaskChecklistUpdate, runID: UUID, operationID: String) async throws -> TaskChecklist {
        try update.validate()
        guard !operationID.isEmpty, operationID.utf8.count <= 256 else { throw FloeError.validationFailed("A durable tool call ID is required") }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let digest = FloeDigest.sha256Hex(try encoder.encode(update))
        return try await database.writer { db in
            guard let conversation = try String.fetchOne(db, sql: "SELECT conversation_id FROM runs WHERE id = ?", arguments: [runID.uuidString]),
                  let conversationID = UUID(uuidString: conversation) else { throw FloeError.validationFailed("Run has no owning task") }
            if let existing = try Row.fetchOne(db, sql: "SELECT request_digest, body_json FROM task_checklist_revisions WHERE run_id = ? AND operation_id = ?", arguments: [runID.uuidString, operationID]) {
                guard (existing["request_digest"] as String) == digest else { throw FloeError.validationFailed("Tool call ID was already used for different checklist content") }
                return try JSONDecoder().decode(TaskChecklist.self, from: Data((existing["body_json"] as String).utf8))
            }
            let body = try String.fetchOne(db, sql: "SELECT body_json FROM task_checklist_revisions WHERE conversation_id = ? ORDER BY revision DESC LIMIT 1", arguments: [conversation])
            let previous = try body.map { try JSONDecoder().decode(TaskChecklist.self, from: Data($0.utf8)) }
            let currentRevision = previous?.revision ?? 0
            if let expected = update.expectedRevision, expected != currentRevision {
                throw FloeError.validationFailed("Checklist changed: current revision is \(currentRevision). Do not re-read the plan; retry checklist.updatePlan with expectedRevision=\(currentRevision) and the same intended changes, or omit expectedRevision to write over the current revision.")
            }
            if let previous, !previous.isFinished {
                let openIDs = previous.steps.filter { !$0.isTerminal }.map(\.id)
                if update.startNew {
                    throw FloeError.validationFailed("Finish or explicitly cancel these unfinished steps before starting a new checklist: \(openIDs.joined(separator: ", "))")
                }
                let carried = Set(update.steps.map(\.id))
                let missing = openIDs.filter { !carried.contains($0) }
                guard missing.isEmpty else {
                    throw FloeError.validationFailed("These steps are still unfinished and must be carried (or marked cancelled): \(missing.joined(separator: ", ")). Completed/cancelled steps may be omitted; their history stays in the revisions table.")
                }
            }
            let checklist = TaskChecklist(conversationID: conversationID, runID: runID,
                revision: currentRevision + 1, title: update.title, steps: update.steps, updatedAt: Date())
            let encoded = String(decoding: try JSONEncoder().encode(checklist), as: UTF8.self)
            try db.execute(sql: "INSERT INTO task_checklist_revisions (conversation_id, revision, run_id, operation_id, request_digest, body_json) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [conversation, checklist.revision, runID.uuidString, operationID, digest, encoded])
            return checklist
        }
    }
}
