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
    }
    public var conversationID: UUID
    public var runID: UUID
    public var revision: Int
    public var title: String
    public var steps: [Step]
    public var updatedAt: Date
    public var isFinished: Bool { steps.allSatisfy { $0.status == .completed || $0.status == .cancelled } }
    public var completedCount: Int { steps.filter { $0.status == .completed }.count }
    public var cancelledCount: Int { steps.filter { $0.status == .cancelled }.count }
    /// Never counts cancelled work as completed or invents an active step.
    public var progressSummary: String {
        let cancelled = cancelledCount > 0 ? " · 已取消 \(cancelledCount) 项" : ""
        return "已完成 \(completedCount)/\(steps.count) 项\(cancelled)"
    }
    public var currentStep: Step? { steps.first { $0.status == .inProgress } }

    /// A new run may continue the same task. Late receipts and snapshots from
    /// a different conversation must not roll the shared UI backwards.
    public func canReplace(_ previous: TaskChecklist?, conversationID: UUID?) -> Bool {
        guard self.conversationID == conversationID else { return false }
        guard let previous else { return true }
        return previous.conversationID == self.conversationID && revision > previous.revision
    }

}

public struct TaskChecklistUpdate: Codable, Sendable {
    public var expectedRevision: Int
    public var title: String
    public var steps: [TaskChecklist.Step]
    public var startNew: Bool
    public init(expectedRevision: Int, title: String, steps: [TaskChecklist.Step], startNew: Bool = false) {
        self.expectedRevision = expectedRevision; self.title = title; self.steps = steps; self.startNew = startNew
    }
    public func validate() throws {
        guard expectedRevision >= 0, (1...160).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).count),
              (1...64).contains(steps.count), Set(steps.map(\.id)).count == steps.count,
              steps.filter({ $0.status == .inProgress }).count <= 1 else {
            throw FloeError.validationFailed("Provide a titled checklist of 1–64 unique steps, at most one in progress, and the current revision")
        }
        for step in steps {
            guard (1...80).contains(step.id.count), step.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }),
                  (1...240).contains(step.title.trimmingCharacters(in: .whitespacesAndNewlines).count),
                  step.evidence.count <= 4, step.evidence.allSatisfy({ (1...512).contains($0.trimmingCharacters(in: .whitespacesAndNewlines).count) }),
                  step.status != .completed || !step.evidence.isEmpty else {
                throw FloeError.validationFailed("Step IDs must be stable ASCII identifiers; completed steps need evidence references")
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
        let digest = SHA256.hash(data: try encoder.encode(update)).map { String(format: "%02x", $0) }.joined()
        return try await database.writer { db in
            guard let conversation = try String.fetchOne(db, sql: "SELECT conversation_id FROM runs WHERE id = ?", arguments: [runID.uuidString]),
                  let conversationID = UUID(uuidString: conversation) else { throw FloeError.validationFailed("Run has no owning task") }
            if let existing = try Row.fetchOne(db, sql: "SELECT request_digest, body_json FROM task_checklist_revisions WHERE run_id = ? AND operation_id = ?", arguments: [runID.uuidString, operationID]) {
                guard (existing["request_digest"] as String) == digest else { throw FloeError.validationFailed("Tool call ID was already used for different checklist content") }
                return try JSONDecoder().decode(TaskChecklist.self, from: Data((existing["body_json"] as String).utf8))
            }
            let body = try String.fetchOne(db, sql: "SELECT body_json FROM task_checklist_revisions WHERE conversation_id = ? ORDER BY revision DESC LIMIT 1", arguments: [conversation])
            let previous = try body.map { try JSONDecoder().decode(TaskChecklist.self, from: Data($0.utf8)) }
            guard update.expectedRevision == (previous?.revision ?? 0) else { throw FloeError.validationFailed("Checklist changed; read its current revision before updating") }
            if let previous {
                if update.startNew {
                    guard previous.isFinished else { throw FloeError.validationFailed("Finish or explicitly cancel the existing steps before starting a new checklist") }
                } else {
                    guard Set(previous.steps.map(\.id)).isSubset(of: Set(update.steps.map(\.id))) else {
                        throw FloeError.validationFailed("Keep existing step IDs; mark removed work cancelled instead of deleting its history")
                    }
                }
            }
            let checklist = TaskChecklist(conversationID: conversationID, runID: runID,
                revision: update.expectedRevision + 1, title: update.title, steps: update.steps, updatedAt: Date())
            let encoded = String(decoding: try JSONEncoder().encode(checklist), as: UTF8.self)
            try db.execute(sql: "INSERT INTO task_checklist_revisions (conversation_id, revision, run_id, operation_id, request_digest, body_json) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [conversation, checklist.revision, runID.uuidString, operationID, digest, encoded])
            return checklist
        }
    }
}
