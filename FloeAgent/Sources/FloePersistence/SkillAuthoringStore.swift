import Foundation
import GRDB

/// One durable foreground slot, independent records, and atomic visibility
/// conversion on the existing database. No view lifetime, timer, network,
/// interpreter or model service is owned by this persistence component.
public actor SQLiteSkillAuthoringStore {
    static let recordPrefix = "skills.authoring.record."
    static let activeKey = "skills.authoring.active"
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    /// Opening another entry returns the same unfinished operation and does
    /// not create an orphan conversation. The new owner/record/slot commit in
    /// one GRDB writer transaction. ComposerDraftStore uses record.id as key.
    public func begin(kind: SkillAuthoringKind, title: String, id: UUID = UUID(),
                      now: Date = Date()) async throws -> SkillAuthoringBeginResult {
        guard title.utf8.count <= 4096 else { throw SkillAuthoringStoreError.invalidMetadata }
        return try await database.writer { db in
            if let activeID = try Self.activeID(db) {
                let existing = try Self.required(activeID, db: db)
                guard existing.occupiesForegroundSlot else { throw SkillAuthoringStoreError.corruptState }
                try Self.verifyOwner(existing, db: db)
                return SkillAuthoringBeginResult(record: existing, created: false)
            }
            guard try Self.read(id, db: db) == nil,
                  try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE id = ?", arguments: [id.uuidString]) == nil else {
                throw SkillAuthoringStoreError.ownerMismatch
            }
            let record = SkillAuthoringRecord(id: id, kind: kind, now: now)
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at, purpose, visibility)
                VALUES (?, ?, ?, ?, 'ordinary', 'skillAuthoring')
                """, arguments: [id.uuidString, title, PersistenceCodec.encode(now), PersistenceCodec.encode(now)])
            try Self.write(record, db: db)
            try Self.claimSlot(id, db: db)
            return SkillAuthoringBeginResult(record: record, created: true)
        }
    }

    public func record(id: UUID) async throws -> SkillAuthoringRecord? {
        try await database.reader { db in
            guard let record = try Self.read(id, db: db) else { return nil }
            try Self.verifyOwner(record, db: db)
            return record
        }
    }

    /// Both unfinished and settled records can be projected in Task Center.
    /// Ordinary chat history still uses ConversationStore's normal visibility.
    public func all(includeAcknowledged: Bool = true) async throws -> [SkillAuthoringRecord] {
        try await database.reader { db in
            try Self.allRecords(db).filter { includeAcknowledged || !$0.acknowledged || $0.occupiesForegroundSlot }
                .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
        }
    }

    public func active() async throws -> SkillAuthoringRecord? {
        try await database.reader { db in
            guard let id = try Self.activeID(db) else { return nil }
            let record = try Self.required(id, db: db)
            guard record.occupiesForegroundSlot else { throw SkillAuthoringStoreError.corruptState }
            try Self.verifyOwner(record, db: db)
            return record
        }
    }

    /// Closing/reopening needs only active()/record(); it never releases a
    /// slot. Draft bodies stay in the existing ComposerDraftStore. The exact
    /// saved revision and owned snapshot references are persisted before start.
    @discardableResult
    public func saveDraftReferences(id: UUID, expectedRevision: Int64, inputRevision: Int,
                                    attachmentIDs: [UUID], snapshotIDs: [UUID],
                                    now: Date = Date()) async throws -> SkillAuthoringRecord {
        guard inputRevision >= 0, Self.validIDs(attachmentIDs), Self.validIDs(snapshotIDs) else {
            throw SkillAuthoringStoreError.invalidMetadata
        }
        return try await database.writer { db in
            var record = try Self.checked(id, revision: expectedRevision, db: db)
            guard [.draft, .failed, .interrupted, .stopped].contains(record.phase), !record.isPromoted,
                  inputRevision >= record.inputRevision else { throw SkillAuthoringStoreError.invalidTransition }
            try Self.claimSlot(id, db: db)
            record.inputRevision = inputRevision; record.sourceAttachmentIDs = attachmentIDs
            record.sourceSnapshotIDs = snapshotIDs; record.phase = .draft
            record.attempt = nil; record.failureMessage = nil; record.acknowledged = false
            return try Self.commit(record, now: now, db: db)
        }
    }

    /// An explicit adaptation or answer to a COMPLETED run's clarification
    /// starts a new input revision on the SAME owner. This is deliberately
    /// separate from autosave or resuming a live approval wait. Installed and
    /// promoted work cannot be rewritten; original outputs remain recoverable.
    @discardableResult
    public func beginRevision(id: UUID, expectedRevision: Int64, inputRevision: Int,
                              attachmentIDs: [UUID], sourceSnapshotIDs: [UUID],
                              now: Date = Date()) async throws -> SkillAuthoringRecord {
        guard inputRevision >= 0, Self.validIDs(attachmentIDs), Self.validIDs(sourceSnapshotIDs) else {
            throw SkillAuthoringStoreError.invalidMetadata
        }
        return try await database.writer { db in
            var record = try Self.checked(id, revision: expectedRevision, db: db)
            guard [.ready, .needsUser].contains(record.phase), !record.isPromoted, record.installationReceipt == nil,
                  inputRevision > record.inputRevision else { throw SkillAuthoringStoreError.invalidTransition }
            if record.phase == .needsUser {
                // A question in the final response is different from a live
                // runtime waiting on approval/user input. Only the joined,
                // actually completed owner run can be continued as a revision.
                guard let attempt = record.attempt, let runID = attempt.binding.runID else {
                    throw SkillAuthoringStoreError.invalidTransition
                }
                try Self.verifyRun(attempt.binding, conversationID: id, required: true, db: db)
                guard let row = try Row.fetchOne(db, sql: "SELECT state, ended_at FROM runs WHERE id = ?", arguments: [runID.uuidString]),
                      row["state"] as String? == "completed", row["ended_at"] as String? != nil else {
                    throw SkillAuthoringStoreError.invalidTransition
                }
            }
            let existingSnapshots = Set(record.sourceSnapshotIDs)
            let snapshots = record.sourceSnapshotIDs + sourceSnapshotIDs.filter { !existingSnapshots.contains($0) }
            guard Self.validIDs(snapshots) else { throw SkillAuthoringStoreError.invalidMetadata }
            try Self.claimSlot(id, db: db)
            record.inputRevision = inputRevision
            record.sourceAttachmentIDs = attachmentIDs
            record.sourceSnapshotIDs = snapshots
            record.preparedSkill = nil; record.installationReceipt = nil; record.attempt = nil
            record.phase = .draft; record.failureMessage = nil; record.acknowledged = false
            // Keep original generatedArtifactIDs, accumulated active time and
            // the user's once-per-operation advisory decision unchanged.
            return try Self.commit(record, now: now, db: db)
        }
    }

    /// Reserve BEFORE submitting the model/launch. This persists the frozen
    /// owner and intended run IDs without fabricating a row in RunStore. An
    /// already-existing row must match; an absent row is verified on activation.
    @discardableResult
    public func reserveAttempt(id: UUID, expectedRevision: Int64, inputRevision: Int,
                               binding: SkillAuthoringBinding, attemptID: UUID = UUID(),
                               now: Date = Date()) async throws -> SkillAuthoringRecord {
        try await createAttempt(id: id, expectedRevision: expectedRevision, inputRevision: inputRevision,
                                binding: binding, attemptID: attemptID, phase: .preparing,
                                requireExistingRun: false, now: now)
    }

    /// Strict existing-run convenience for operations whose real owner is
    /// already persisted. UI launch bridges should use reserveAttempt first.
    @discardableResult
    public func startProcessing(id: UUID, expectedRevision: Int64, inputRevision: Int,
                                binding: SkillAuthoringBinding, attemptID: UUID = UUID(),
                                now: Date = Date()) async throws -> SkillAuthoringRecord {
        try await createAttempt(id: id, expectedRevision: expectedRevision, inputRevision: inputRevision,
                                binding: binding, attemptID: attemptID, phase: .running,
                                requireExistingRun: true, now: now)
    }

    private func createAttempt(id: UUID, expectedRevision: Int64, inputRevision: Int,
                               binding: SkillAuthoringBinding, attemptID: UUID,
                               phase: SkillAuthoringPhase, requireExistingRun: Bool,
                               now: Date) async throws -> SkillAuthoringRecord {
        try Self.validate(binding)
        return try await database.writer { db in
            var record = try Self.checked(id, revision: expectedRevision, db: db)
            guard [.draft, .failed, .interrupted, .stopped].contains(record.phase), !record.isPromoted,
                  inputRevision == record.inputRevision else { throw SkillAuthoringStoreError.invalidTransition }
            guard record.attempt?.token.attemptID != attemptID else { throw SkillAuthoringStoreError.staleAttempt }
            try Self.claimSlot(id, db: db)
            try Self.verifyRun(binding, conversationID: id, required: requireExistingRun, db: db)
            let token = SkillAuthoringAttemptToken(conversationID: id, inputRevision: inputRevision,
                                                  attemptID: attemptID, generation: record.revision + 1,
                                                  runID: binding.runID)
            record.attempt = SkillAuthoringAttempt(token: token, binding: binding,
                                                  startedAt: now, activeProcessingMilliseconds: 0)
            record.phase = phase; record.failureMessage = nil; record.acknowledged = false
            record.preparedSkill = nil; record.installationReceipt = nil
            return try Self.commit(record, now: now, db: db)
        }
    }

    /// Reconcile the actual launch receipt. A late activation never revives
    /// cancelled/terminal work, but still checks the real run identity. The
    /// caller retains ownership and joins any launched task before settling it.
    @discardableResult
    public func activateAttempt(_ token: SkillAuthoringAttemptToken,
                                now: Date = Date()) async throws -> SkillAuthoringRecord {
        try await database.writer { db in
            var record = try Self.checked(token, db: db)
            guard let attempt = record.attempt else { throw SkillAuthoringStoreError.staleAttempt }
            try Self.verifyRun(attempt.binding, conversationID: record.id, required: true, db: db)
            guard record.phase == .preparing else { return record }
            record.phase = .running
            return try Self.commit(record, now: now, db: db)
        }
    }

    /// A cumulative per-attempt ACTIVE duration makes callback replay
    /// idempotent. The trusted coordinator excludes user/system waits; no
    /// wall-clock elapsed time or relaunch time is inferred by this store.
    @discardableResult
    public func recordActiveProcessing(_ token: SkillAuthoringAttemptToken,
                                       attemptTotalMilliseconds: UInt64,
                                       now: Date = Date()) async throws -> SkillAuthoringRecord {
        try await database.writer { db in
            var record = try Self.checked(token, db: db)
            guard record.phase == .running, var attempt = record.attempt else {
                throw SkillAuthoringStoreError.invalidTransition
            }
            guard attemptTotalMilliseconds >= attempt.activeProcessingMilliseconds else {
                throw SkillAuthoringStoreError.staleAttempt
            }
            let delta = attemptTotalMilliseconds - attempt.activeProcessingMilliseconds
            guard delta > 0 else { return record }
            let (total, overflow) = record.activeProcessingMilliseconds.addingReportingOverflow(delta)
            guard !overflow else { throw SkillAuthoringStoreError.invalidMetadata }
            attempt.activeProcessingMilliseconds = attemptTotalMilliseconds
            record.attempt = attempt; record.activeProcessingMilliseconds = total
            return try Self.commit(record, now: now, db: db)
        }
    }

    @discardableResult
    public func setProcessingPhase(_ token: SkillAuthoringAttemptToken, phase: SkillAuthoringPhase,
                                   now: Date = Date()) async throws -> SkillAuthoringRecord {
        guard [.running, .needsUser, .paused].contains(phase) else { throw SkillAuthoringStoreError.invalidTransition }
        return try await database.writer { db in
            var record = try Self.checked(token, db: db)
            guard [.running, .needsUser, .paused].contains(record.phase) else { throw SkillAuthoringStoreError.invalidTransition }
            record.phase = phase
            return try Self.commit(record, now: now, db: db)
        }
    }

    @discardableResult
    public func attachJob(_ token: SkillAuthoringAttemptToken, jobID: UUID,
                          now: Date = Date()) async throws -> SkillAuthoringRecord {
        try await database.writer { db in
            var record = try Self.checked(token, db: db)
            guard [.preparing, .running, .needsUser, .paused].contains(record.phase),
                  let row = try Row.fetchOne(db, sql: "SELECT conversation_id, run_id FROM background_jobs WHERE id = ?", arguments: [jobID.uuidString]),
                  row["conversation_id"] as String? == record.id.uuidString,
                  token.runID == nil || row["run_id"] as String? == token.runID?.uuidString else {
                throw SkillAuthoringStoreError.ownerMismatch
            }
            if record.jobIDs.contains(jobID) { return record }
            guard record.jobIDs.count < 128 else { throw SkillAuthoringStoreError.invalidMetadata }
            record.jobIDs.append(jobID)
            return try Self.commit(record, now: now, db: db)
        }
    }

    @discardableResult
    public func chooseAdvisory(id: UUID, expectedRevision: Int64, choice: SkillAuthoringAdvisoryChoice,
                               now: Date = Date()) async throws -> SkillAuthoringRecord {
        try await database.writer { db in
            var record = try Self.checked(id, revision: expectedRevision, db: db)
            guard record.isAdvisoryEligible else { throw SkillAuthoringStoreError.invalidTransition }
            record.advisoryDecision = choice == .keepWaiting ? .keepWaiting : .convertRequested
            return try Self.commit(record, now: now, db: db)
        }
    }

    /// Explicitly chosen conversion, never a timer action. Visibility,
    /// metadata and foreground-slot release either ALL commit or ALL roll
    /// back. An already-committed conversion is idempotent even after a crash.
    @discardableResult
    public func commitPromotion(id: UUID, expectedRevision: Int64,
                                now: Date = Date()) async throws -> SkillAuthoringRecord {
        try await database.writer { db in
            var record = try Self.required(id, db: db)
            try Self.verifyOwner(record, db: db)
            if record.isPromoted { return record }
            guard record.revision == expectedRevision else { throw SkillAuthoringStoreError.staleRevision }
            guard record.advisoryDecision == .convertRequested,
                  [.running, .needsUser, .paused].contains(record.phase) else {
                throw SkillAuthoringStoreError.invalidTransition
            }
            guard try Self.activeID(db) == id else { throw SkillAuthoringStoreError.ownerMismatch }
            try db.execute(sql: """
                UPDATE conversations SET visibility = 'normal', updated_at = ?
                WHERE id = ? AND purpose = 'ordinary' AND visibility = 'skillAuthoring'
                """, arguments: [PersistenceCodec.encode(now), id.uuidString])
            guard db.changesCount == 1 else { throw SkillAuthoringStoreError.ownerMismatch }
            record.promotedAt = now; record.advisoryDecision = .converted
            return try Self.commit(record, now: now, db: db)
        }
    }

    @discardableResult
    public func requestCancellation(id: UUID, expectedRevision: Int64,
                                    now: Date = Date()) async throws -> SkillAuthoringRecord {
        try await database.writer { db in
            var record = try Self.checked(id, revision: expectedRevision, db: db)
            guard !record.phase.isSettled else { throw SkillAuthoringStoreError.invalidTransition }
            if record.phase == .cancelling { return record }
            // An unsubmitted draft owns no active attempt to join.
            record.phase = record.phase == .draft ? .stopped : .cancelling
            return try Self.commit(record, now: now, db: db)
        }
    }

    /// Call only AFTER the existing run/job owner has actually joined. No
    /// mere sheet dismissal or cancellation request can release its slot.
    @discardableResult
    public func settleCancellation(_ token: SkillAuthoringAttemptToken,
                                   artifactIDs: [UUID] = [],
                                   now: Date = Date()) async throws -> SkillAuthoringRecord {
        guard Self.validIDs(artifactIDs) else { throw SkillAuthoringStoreError.invalidMetadata }
        return try await database.writer { db in
            var record = try Self.checked(token, db: db)
            guard [.cancelling, .stopped].contains(record.phase) else {
                throw SkillAuthoringStoreError.invalidTransition
            }
            // The trusted coordinator joins its producers and verifies each
            // owned snapshot before supplying these references. A cancelled
            // finishReady must not make already-committed bytes unreachable.
            let merged = record.generatedArtifactIDs + artifactIDs.filter {
                !record.generatedArtifactIDs.contains($0)
            }
            guard Self.validIDs(merged) else { throw SkillAuthoringStoreError.invalidMetadata }
            if record.phase == .stopped, record.generatedArtifactIDs == merged { return record }
            record.generatedArtifactIDs = merged
            record.phase = .stopped
            return try Self.commit(record, now: now, db: db)
        }
    }

    @discardableResult
    public func finishReady(_ token: SkillAuthoringAttemptToken, skill: SkillAuthoringPreparedSkill,
                            artifactIDs: [UUID], now: Date = Date()) async throws -> SkillAuthoringRecord {
        guard Self.validSkill(skill), Self.validIDs(artifactIDs) else { throw SkillAuthoringStoreError.invalidMetadata }
        return try await database.writer { db in
            var record = try Self.checked(token, db: db)
            if [.ready, .installed].contains(record.phase), record.preparedSkill == skill,
               record.generatedArtifactIDs == artifactIDs { return record }
            guard [.preparing, .running, .needsUser, .paused].contains(record.phase) else { throw SkillAuthoringStoreError.invalidTransition }
            if let attempt = record.attempt {
                try Self.verifyRun(attempt.binding, conversationID: record.id, required: true, db: db)
            }
            record.phase = .ready; record.preparedSkill = skill; record.generatedArtifactIDs = artifactIDs
            record.failureMessage = nil
            return try Self.commit(record, now: now, db: db)
        }
    }

    @discardableResult
    public func finishFailed(_ token: SkillAuthoringAttemptToken, message: String,
                             now: Date = Date()) async throws -> SkillAuthoringRecord {
        guard message.utf8.count <= 4096 else { throw SkillAuthoringStoreError.invalidMetadata }
        return try await database.writer { db in
            var record = try Self.checked(token, db: db)
            if record.phase == .failed, record.failureMessage == message { return record }
            guard [.preparing, .running, .needsUser, .paused].contains(record.phase) else { throw SkillAuthoringStoreError.invalidTransition }
            record.phase = .failed; record.failureMessage = message
            return try Self.commit(record, now: now, db: db)
        }
    }

    /// Only an actual matching row in the canonical skill store can produce
    /// Installed. Generation, a success-looking model message or an unrelated
    /// installation cannot substitute for the expected package identity.
    @discardableResult
    public func confirmInstalled(id: UUID, expectedRevision: Int64,
                                 now: Date = Date()) async throws -> SkillAuthoringRecord {
        try await database.writer { db in
            var record = try Self.required(id, db: db)
            try Self.verifyOwner(record, db: db)
            guard [.ready, .installed].contains(record.phase), let skill = record.preparedSkill,
                  let row = try Row.fetchOne(db, sql: "SELECT version, rewritten_digest FROM skills WHERE id = ?", arguments: [skill.skillID]),
                  row["version"] as String? == skill.version,
                  row["rewritten_digest"] as String? == skill.digest else { throw SkillAuthoringStoreError.installationMismatch }
            if record.phase == .installed { return record }
            guard record.revision == expectedRevision else { throw SkillAuthoringStoreError.staleRevision }
            record.phase = .installed
            record.installationReceipt = SkillAuthoringInstallationReceipt(skill: skill, verifiedAt: now)
            return try Self.commit(record, now: now, db: db)
        }
    }

    /// The caller supplies the process cutoff and genuinely live run set from
    /// existing launch recovery. This never starts/replays a model request or
    /// counts time while the process was dead. Current-process attempts and
    /// known live runs are left untouched.
    public func reconcileLostAttempts(startedBefore cutoff: Date, liveRunIDs: Set<UUID>,
                                      now: Date = Date()) async throws -> [SkillAuthoringRecord] {
        try await database.writer { db in
            var changed: [SkillAuthoringRecord] = []
            for var record in try Self.allRecords(db) {
                guard [.preparing, .running, .needsUser, .paused, .cancelling].contains(record.phase),
                      let attempt = record.attempt, attempt.startedAt < cutoff,
                      attempt.binding.runID.map({ !liveRunIDs.contains($0) }) ?? true else { continue }
                record.phase = .interrupted
                changed.append(try Self.commit(record, now: now, db: db))
            }
            return changed
        }
    }

    @discardableResult
    public func acknowledge(id: UUID, expectedRevision: Int64,
                            now: Date = Date()) async throws -> SkillAuthoringRecord {
        try await database.writer { db in
            var record = try Self.checked(id, revision: expectedRevision, db: db)
            guard record.phase.isSettled || record.isPromoted else { throw SkillAuthoringStoreError.invalidTransition }
            record.acknowledged = true
            return try Self.commit(record, now: now, db: db)
        }
    }

    // MARK: One-transaction metadata implementation

    static func hasRecord(for id: UUID, db: Database) throws -> Bool {
        try String.fetchOne(db, sql: "SELECT key FROM app_settings WHERE key = ?",
                            arguments: [recordPrefix + id.uuidString]) != nil
    }

    static func removeMetadataForDeletedConversation(_ id: UUID, db: Database) throws {
        guard try hasRecord(for: id, db: db) else { return }
        try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [recordPrefix + id.uuidString])
        if try activeID(db) == id {
            try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [activeKey])
        }
    }

    private static func activeID(_ db: Database) throws -> UUID? {
        guard let json = try String.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?", arguments: [activeKey]) else { return nil }
        do { return try JSONDecoder().decode(UUID.self, from: Data(json.utf8)) }
        catch { throw SkillAuthoringStoreError.corruptState }
    }

    private static func read(_ id: UUID, db: Database) throws -> SkillAuthoringRecord? {
        guard let json = try String.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?", arguments: [recordPrefix + id.uuidString]) else { return nil }
        guard json.utf8.count <= 65_536 else { throw SkillAuthoringStoreError.corruptState }
        do {
            let record = try JSONDecoder().decode(SkillAuthoringRecord.self, from: Data(json.utf8))
            guard record.id == id, record.revision >= 0, record.revision < Int64.max - 1,
                  record.inputRevision >= 0, validIDs(record.sourceAttachmentIDs),
                  validIDs(record.sourceSnapshotIDs), validIDs(record.generatedArtifactIDs),
                  validIDs(record.jobIDs) else { throw SkillAuthoringStoreError.corruptState }
            if let attempt = record.attempt {
                guard attempt.token.conversationID == id, attempt.token.inputRevision == record.inputRevision,
                      attempt.token.generation > 0, attempt.token.generation <= record.revision,
                      attempt.token.runID == attempt.binding.runID,
                      attempt.activeProcessingMilliseconds <= record.activeProcessingMilliseconds else {
                    throw SkillAuthoringStoreError.corruptState
                }
                try validate(attempt.binding)
            }
            guard (record.promotedAt != nil) == (record.advisoryDecision == .converted),
                  record.phase != .installed || record.installationReceipt?.skill == record.preparedSkill,
                  record.phase != .installed || record.installationReceipt != nil else {
                throw SkillAuthoringStoreError.corruptState
            }
            return record
        } catch { throw SkillAuthoringStoreError.corruptState }
    }

    private static func required(_ id: UUID, db: Database) throws -> SkillAuthoringRecord {
        guard let record = try read(id, db: db) else { throw SkillAuthoringStoreError.missing }
        return record
    }

    private static func allRecords(_ db: Database) throws -> [SkillAuthoringRecord] {
        let keys = try String.fetchAll(db, sql: "SELECT key FROM app_settings WHERE key LIKE ?", arguments: [recordPrefix + "%"])
        return try keys.map { key in
            guard let id = UUID(uuidString: String(key.dropFirst(recordPrefix.count))) else { throw SkillAuthoringStoreError.corruptState }
            let record = try required(id, db: db)
            try verifyOwner(record, db: db)
            return record
        }
    }

    private static func checked(_ id: UUID, revision: Int64, db: Database) throws -> SkillAuthoringRecord {
        let record = try required(id, db: db)
        try verifyOwner(record, db: db)
        guard record.revision == revision else { throw SkillAuthoringStoreError.staleRevision }
        return record
    }

    private static func checked(_ token: SkillAuthoringAttemptToken, db: Database) throws -> SkillAuthoringRecord {
        let record = try required(token.conversationID, db: db)
        try verifyOwner(record, db: db)
        guard record.inputRevision == token.inputRevision, record.attempt?.token == token else {
            throw SkillAuthoringStoreError.staleAttempt
        }
        return record
    }

    private static func verifyOwner(_ record: SkillAuthoringRecord, db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT purpose, visibility FROM conversations WHERE id = ?", arguments: [record.id.uuidString]) else {
            throw SkillAuthoringStoreError.ownerMissing
        }
        guard row["purpose"] as String? == ConversationPurpose.ordinary.rawValue,
              row["visibility"] as String? == (record.isPromoted ? ConversationVisibility.normal : .skillAuthoring).rawValue else {
            throw SkillAuthoringStoreError.ownerMismatch
        }
    }

    private static func claimSlot(_ id: UUID, db: Database) throws {
        if let existing = try activeID(db), existing != id { throw SkillAuthoringStoreError.foregroundOccupied(existing) }
        try setSetting(activeKey, value: JSONEncoder().encode(id), now: Date(), db: db)
    }

    private static func commit(_ input: SkillAuthoringRecord, now: Date, db: Database) throws -> SkillAuthoringRecord {
        var record = input
        let (revision, overflow) = record.revision.addingReportingOverflow(1)
        guard !overflow else { throw SkillAuthoringStoreError.corruptState }
        record.revision = revision; record.updatedAt = now
        try write(record, db: db)
        if record.occupiesForegroundSlot {
            guard try activeID(db) == record.id else { throw SkillAuthoringStoreError.ownerMismatch }
        } else if try activeID(db) == record.id {
            try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [activeKey])
        }
        return record
    }

    private static func write(_ record: SkillAuthoringRecord, db: Database) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 65_536 else { throw SkillAuthoringStoreError.invalidMetadata }
        try setSetting(recordPrefix + record.id.uuidString, value: data, now: record.updatedAt, db: db)
    }

    private static func setSetting(_ key: String, value: Data, now: Date, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO app_settings (key, value_json, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at
            """, arguments: [key, String(decoding: value, as: UTF8.self), PersistenceCodec.encode(now)])
    }

    private static func validIDs(_ ids: [UUID]) -> Bool { ids.count <= 128 && Set(ids).count == ids.count }
    private static func validSkill(_ skill: SkillAuthoringPreparedSkill) -> Bool {
        !skill.skillID.isEmpty && skill.skillID.utf8.count <= 256 && !skill.version.isEmpty
            && skill.version.utf8.count <= 128 && skill.digest.count == 64
            && skill.digest.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private static func validate(_ binding: SkillAuthoringBinding) throws {
        guard (binding.providerID == nil) == (binding.modelID == nil),
              binding.providerID == nil || binding.runID != nil else { throw SkillAuthoringStoreError.invalidBinding }
        if binding.requiresExecution {
            guard binding.workspaceID != nil, let environment = binding.environmentID, !environment.isEmpty,
                  let layer = binding.workspaceWriteLayer, !layer.isEmpty else { throw SkillAuthoringStoreError.invalidBinding }
        }
        guard (binding.environmentID?.utf8.count ?? 0) <= 256,
              (binding.workspaceWriteLayer?.utf8.count ?? 0) <= 64 else { throw SkillAuthoringStoreError.invalidBinding }
    }
    private static func verifyRun(_ binding: SkillAuthoringBinding, conversationID: UUID,
                                  required: Bool, db: Database) throws {
        guard let runID = binding.runID else { return }
        guard let row = try Row.fetchOne(db, sql: "SELECT conversation_id, provider_id, model_id FROM runs WHERE id = ?", arguments: [runID.uuidString]) else {
            if required { throw SkillAuthoringStoreError.ownerMissing }
            return
        }
        guard row["conversation_id"] as String? == conversationID.uuidString,
              row["provider_id"] as String? == binding.providerID?.uuidString,
              row["model_id"] as String? == binding.modelID?.uuidString else { throw SkillAuthoringStoreError.ownerMismatch }
    }
}
