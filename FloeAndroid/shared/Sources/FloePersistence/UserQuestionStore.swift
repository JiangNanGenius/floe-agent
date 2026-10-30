// FloePersistence — durable and RAM-only user-question storage.
//
// The store is deliberately the only writer for question state. Every answer
// is accepted with an optimistic-concurrency check inside ONE SQLite
// transaction, so a stale card, a duplicate notification action or two
// simultaneous taps cannot settle the same question twice. Deadline defaults
// and cancellations are persisted with explicit provenance and no answer
// body; they are never exposed as a human answer.
//
// Temporary (ephemeral) conversations use the same API but never touch
// SQLite: `isEphemeral` requests live only in this actor's memory. The
// coordinator passes that flag from the trusted ToolContext, never from model
// arguments.

import Foundation
import GRDB
import FloeCore
import FloeModels

public actor UserQuestionStore {

    // MARK: - Internal representation

    private struct Header: Codable, Sendable {
        var requestID: String
        var requestDigest: String
        var conversationID: UUID
        var runID: UUID
        var toolCallID: String
        var waitPolicy: UserQuestionWaitPolicy
        var state: UserQuestionRequestState
        var createdAt: Date
        var updatedAt: Date
        var isEphemeral: Bool
    }

    private struct StoredRequest: Sendable {
        var header: Header
        var questions: [UserQuestion]
    }

    private let database: DatabaseManager
    private var ephemeral: [String: StoredRequest] = [:]

    public init(database: DatabaseManager) {
        self.database = database
    }

    // MARK: - Registration

    /// Registers a request exactly once. Replaying the same trusted request
    /// id with the same digest is an idempotent read; reusing the run/tool
    /// call for different questions is refused.
    public func register(_ registration: UserQuestionRegistration) async throws -> UserQuestionWaitingSnapshot {
        guard !registration.questions.isEmpty else {
            throw UserQuestionError.invalidRequest("A question request cannot be empty.")
        }
        if registration.isEphemeral {
            if let existing = ephemeral[registration.requestID] {
                guard existing.header.requestDigest == registration.requestDigest else {
                    throw UserQuestionError.requestConflict
                }
                return Self.snapshot(existing)
            }
            if let conflicting = ephemeral.values.first(where: {
                $0.header.runID == registration.runID
                    && $0.header.toolCallID == registration.toolCallID
                    && $0.header.requestID != registration.requestID
            }) {
                _ = conflicting
                throw UserQuestionError.requestConflict
            }
            let header = Header(
                requestID: registration.requestID,
                requestDigest: registration.requestDigest,
                conversationID: registration.conversationID,
                runID: registration.runID,
                toolCallID: registration.toolCallID,
                waitPolicy: registration.waitPolicy,
                state: Self.requestState(registration.questions),
                createdAt: registration.createdAt,
                updatedAt: registration.createdAt,
                isEphemeral: true
            )
            let stored = StoredRequest(header: header, questions: registration.questions)
            ephemeral[registration.requestID] = stored
            return Self.snapshot(stored)
        }

        return try await database.writer { db in
            if let existing = try Self.read(db, requestID: registration.requestID) {
                guard existing.header.requestDigest == registration.requestDigest else {
                    throw UserQuestionError.requestConflict
                }
                return Self.snapshot(existing)
            }
            if let existingID = try String.fetchOne(
                db,
                sql: "SELECT request_id FROM user_question_requests WHERE run_id = ? AND tool_call_id = ? LIMIT 1",
                arguments: [registration.runID.uuidString, registration.toolCallID]
            ), existingID != registration.requestID {
                throw UserQuestionError.requestConflict
            }
            let header = Header(
                requestID: registration.requestID,
                requestDigest: registration.requestDigest,
                conversationID: registration.conversationID,
                runID: registration.runID,
                toolCallID: registration.toolCallID,
                waitPolicy: registration.waitPolicy,
                state: Self.requestState(registration.questions),
                createdAt: registration.createdAt,
                updatedAt: registration.createdAt,
                isEphemeral: false
            )
            let stored = StoredRequest(header: header, questions: registration.questions)
            try Self.insert(db, stored)
            return Self.snapshot(stored)
        }
    }

    // MARK: - Reads

    public func snapshot(requestID: String) async throws -> UserQuestionWaitingSnapshot? {
        if let stored = ephemeral[requestID] { return Self.snapshot(stored) }
        return try await database.reader { db in
            try Self.read(db, requestID: requestID).map(Self.snapshot)
        }
    }

    public func snapshot(runID: UUID, toolCallID: String) async throws -> UserQuestionWaitingSnapshot? {
        if let stored = ephemeral.values.first(where: {
            $0.header.runID == runID && $0.header.toolCallID == toolCallID
        }) {
            return Self.snapshot(stored)
        }
        return try await database.reader { db in
            guard let requestID = try String.fetchOne(
                db,
                sql: "SELECT request_id FROM user_question_requests WHERE run_id = ? AND tool_call_id = ? LIMIT 1",
                arguments: [runID.uuidString, toolCallID]
            ) else { return nil }
            return try Self.read(db, requestID: requestID).map(Self.snapshot)
        }
    }

    /// Most recent request that still has pending work for this conversation.
    public func pendingSnapshot(conversationID: UUID) async throws -> UserQuestionWaitingSnapshot? {
        let snapshots = try await snapshots(conversationID: conversationID, includeSettled: false)
        return snapshots.first { $0.state == .awaitingAnswer }
            ?? snapshots.first { $0.state == .awaitingOptional }
    }

    public func latestPendingSnapshot(runID: UUID) async throws -> UserQuestionWaitingSnapshot? {
        let snapshots = try await snapshots(runID: runID, includeSettled: false)
        return snapshots.first
    }

    public func snapshots(
        conversationID: UUID,
        includeSettled: Bool
    ) async throws -> [UserQuestionWaitingSnapshot] {
        var result: [UserQuestionWaitingSnapshot] = ephemeral.values
            .filter { $0.header.conversationID == conversationID }
            .map(Self.snapshot)
        let durable: [UserQuestionWaitingSnapshot] = try await database.reader { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT request_id FROM user_question_requests
                    WHERE conversation_id = ?
                    ORDER BY created_at DESC, request_id
                    """,
                arguments: [conversationID.uuidString]
            )
            return try rows.compactMap { row -> UserQuestionWaitingSnapshot? in
                guard let id = row["request_id"] as String?,
                      let stored = try Self.read(db, requestID: id) else { return nil }
                return Self.snapshot(stored)
            }
        }
        result.append(contentsOf: durable)
        if !includeSettled {
            result = result.filter { $0.state == .awaitingAnswer || $0.state == .awaitingOptional }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    private func snapshots(
        runID: UUID,
        includeSettled: Bool
    ) async throws -> [UserQuestionWaitingSnapshot] {
        var result: [UserQuestionWaitingSnapshot] = ephemeral.values
            .filter { $0.header.runID == runID }
            .map(Self.snapshot)
        let durable: [UserQuestionWaitingSnapshot] = try await database.reader { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT request_id FROM user_question_requests
                    WHERE run_id = ?
                    ORDER BY created_at DESC, request_id
                    """,
                arguments: [runID.uuidString]
            )
            return try rows.compactMap { row -> UserQuestionWaitingSnapshot? in
                guard let id = row["request_id"] as String?,
                      let stored = try Self.read(db, requestID: id) else { return nil }
                return Self.snapshot(stored)
            }
        }
        result.append(contentsOf: durable)
        if !includeSettled {
            result = result.filter { $0.state == .awaitingAnswer || $0.state == .awaitingOptional }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    /// Request ids that still block or optionally wait, used by the runtime's
    /// checkpoint metadata. Identifiers only; no question text or answers.
    public func waitingRequestIDs(runID: UUID) async throws -> [String] {
        try await snapshots(runID: runID, includeSettled: false).map(\.requestID)
    }

    // MARK: - Answers

    public func submitHumanAnswer(
        target: UserQuestionAnswerTarget,
        answer: UserQuestionAnswer,
        now: Date
    ) async throws -> UserQuestionAnswerReceipt {
        try await settle(
            target: target,
            answer: answer,
            source: .human,
            status: .answered,
            now: now
        )
    }

    /// Saves the card's in-progress selection/notes. It never settles the
    /// question and never changes its answer source.
    public func saveDraft(
        target: UserQuestionAnswerTarget,
        draft: UserQuestionAnswer,
        now: Date
    ) async throws -> UserQuestionDraftReceipt {
        if let stored = ephemeral[target.requestID] {
            var stored = stored
            guard let index = stored.questions.firstIndex(where: { $0.questionID == target.questionID }) else {
                throw UserQuestionError.notFound
            }
            var question = stored.questions[index]
            try Self.requireBound(question, target: target)
            guard question.revision == target.expectedRevision else {
                throw UserQuestionError.staleRevision(current: question.revision)
            }
            guard question.status == .pending else {
                return UserQuestionDraftReceipt(
                    target: target,
                    revision: question.revision,
                    saved: false
                )
            }
            let normalized = try draft.validated(for: question, partial: true)
            // Drafts are UI progress, not settlement: they do not consume the
            // answer CAS revision. The card's final answer stays valid while
            // the person edits notes or moves between questions.
            question.draftAnswer = normalized
            question.updatedAt = now
            stored.questions[index] = question
            stored.header.updatedAt = now
            ephemeral[target.requestID] = stored
            return UserQuestionDraftReceipt(
                target: UserQuestionAnswerTarget(
                    requestID: target.requestID,
                    questionID: target.questionID,
                    conversationID: target.conversationID,
                    runID: target.runID,
                    expectedRevision: question.revision
                ),
                revision: question.revision,
                saved: true
            )
        }

        return try await database.writer { db in
            guard var stored = try Self.read(db, requestID: target.requestID) else {
                throw UserQuestionError.notFound
            }
            guard let index = stored.questions.firstIndex(where: { $0.questionID == target.questionID }) else {
                throw UserQuestionError.notFound
            }
            var question = stored.questions[index]
            try Self.requireBound(question, target: target)
            guard question.revision == target.expectedRevision else {
                throw UserQuestionError.staleRevision(current: question.revision)
            }
            guard question.status == .pending else {
                return UserQuestionDraftReceipt(
                    target: target,
                    revision: question.revision,
                    saved: false
                )
            }
            let normalized = try draft.validated(for: question, partial: true)
            // Drafts never consume the answer CAS revision.
            question.draftAnswer = normalized
            question.updatedAt = now
            stored.questions[index] = question
            stored.header.updatedAt = now
            try Self.write(db, stored)
            return UserQuestionDraftReceipt(
                target: UserQuestionAnswerTarget(
                    requestID: target.requestID,
                    questionID: target.questionID,
                    conversationID: target.conversationID,
                    runID: target.runID,
                    expectedRevision: question.revision
                ),
                revision: question.revision,
                saved: true
            )
        }
    }

    private func settle(
        target: UserQuestionAnswerTarget,
        answer: UserQuestionAnswer?,
        source: UserQuestionAnswerSource,
        status: UserQuestionStatus,
        now: Date
    ) async throws -> UserQuestionAnswerReceipt {
        if let stored = ephemeral[target.requestID] {
            var stored = stored
            guard let index = stored.questions.firstIndex(where: { $0.questionID == target.questionID }) else {
                throw UserQuestionError.notFound
            }
            let receipt = try Self.applySettlement(
                to: &stored,
                index: index,
                target: target,
                answer: answer,
                source: source,
                status: status,
                now: now
            )
            ephemeral[target.requestID] = stored
            return receipt
        }

        return try await database.writer { db in
            guard var stored = try Self.read(db, requestID: target.requestID) else {
                throw UserQuestionError.notFound
            }
            guard let index = stored.questions.firstIndex(where: { $0.questionID == target.questionID }) else {
                throw UserQuestionError.notFound
            }
            let receipt = try Self.applySettlement(
                to: &stored,
                index: index,
                target: target,
                answer: answer,
                source: source,
                status: status,
                now: now
            )
            try Self.write(db, stored)
            return receipt
        }
    }

    // MARK: - Expiry and cancellation

    /// Expires every optionalDeadline question in this request whose explicit
    /// deadline passed. A declared fallback becomes a `deadlineDefault`
    /// answer; otherwise the question is simply `expired` with no answer.
    @discardableResult
    public func expire(requestID: String, now: Date) async throws -> UserQuestionWaitingSnapshot? {
        if let stored = ephemeral[requestID] {
            var stored = stored
            Self.applyExpiry(to: &stored, now: now)
            ephemeral[requestID] = stored
            return Self.snapshot(stored)
        }
        return try await database.writer { db in
            guard var stored = try Self.read(db, requestID: requestID) else { return nil }
            Self.applyExpiry(to: &stored, now: now)
            try Self.write(db, stored)
            return Self.snapshot(stored)
        }
    }

    @discardableResult
    public func cancel(requestID: String, now: Date) async throws -> UserQuestionWaitingSnapshot? {
        if let stored = ephemeral[requestID] {
            var stored = stored
            Self.applyCancellation(to: &stored, now: now)
            ephemeral[requestID] = stored
            return Self.snapshot(stored)
        }
        return try await database.writer { db in
            guard var stored = try Self.read(db, requestID: requestID) else { return nil }
            Self.applyCancellation(to: &stored, now: now)
            try Self.write(db, stored)
            return Self.snapshot(stored)
        }
    }

    /// Terminal fence for a run. Pending questions become cancelled with no
    /// answer; a late answer then receives an `alreadySettled` receipt.
    @discardableResult
    public func cancelPending(runID: UUID, now: Date) async throws -> [UserQuestionWaitingSnapshot] {
        var result: [UserQuestionWaitingSnapshot] = []
        for (requestID, stored) in ephemeral where stored.header.runID == runID {
            guard stored.questions.contains(where: \.isPending) else { continue }
            var stored = stored
            Self.applyCancellation(to: &stored, now: now)
            ephemeral[requestID] = stored
            result.append(Self.snapshot(stored))
        }
        let durable = try await database.writer { db -> [UserQuestionWaitingSnapshot] in
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT request_id FROM user_question_requests
                    WHERE run_id = ? AND state IN ('awaitingAnswer', 'awaitingOptional')
                    """,
                arguments: [runID.uuidString]
            )
            var snapshots: [UserQuestionWaitingSnapshot] = []
            for id in ids {
                guard var stored = try Self.read(db, requestID: id) else { continue }
                Self.applyCancellation(to: &stored, now: now)
                try Self.write(db, stored)
                snapshots.append(Self.snapshot(stored))
            }
            return snapshots
        }
        result.append(contentsOf: durable)
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    /// Task-deletion fence. It is intentionally separate from run
    /// cancellation because deleting a conversation must release every
    /// question owned by it, including a detached older run.
    @discardableResult
    public func cancelPending(conversationID: UUID, now: Date) async throws -> [UserQuestionWaitingSnapshot] {
        var result: [UserQuestionWaitingSnapshot] = []
        for (requestID, stored) in ephemeral where stored.header.conversationID == conversationID {
            guard stored.questions.contains(where: \.isPending) else { continue }
            var stored = stored
            Self.applyCancellation(to: &stored, now: now)
            ephemeral[requestID] = stored
            result.append(Self.snapshot(stored))
        }
        let durable = try await database.writer { db -> [UserQuestionWaitingSnapshot] in
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT request_id FROM user_question_requests
                    WHERE conversation_id = ? AND state IN ('awaitingAnswer', 'awaitingOptional')
                    """,
                arguments: [conversationID.uuidString]
            )
            var snapshots: [UserQuestionWaitingSnapshot] = []
            for id in ids {
                guard var stored = try Self.read(db, requestID: id) else { continue }
                Self.applyCancellation(to: &stored, now: now)
                try Self.write(db, stored)
                snapshots.append(Self.snapshot(stored))
            }
            return snapshots
        }
        result.append(contentsOf: durable)
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    /// Purges ONLY the temporary questions owned by one exact run. A caller
    /// that is discarding an old temporary incarnation must capture its run
    /// ids before awaiting, then call this per id; a conversation-wide purge
    /// could otherwise erase a newly recreated session that reuses the
    /// conversation id.
    public func purgeEphemeral(runID: UUID) {
        ephemeral = ephemeral.filter { $0.value.header.runID != runID }
    }

    /// Removes every temporary question for a conversation. Use only at a
    /// true task-deletion boundary, not for discarding an old incarnation.
    public func purgeEphemeral(conversationID: UUID) {
        ephemeral = ephemeral.filter { $0.value.header.conversationID != conversationID }
    }

    // MARK: - Optional-answer delivery

    /// Human answers to optionalContinue questions whose request no longer has
    /// a blocking question. They are returned once and marked delivered so a
    /// later provider turn cannot quote the same answer twice.
    public func undeliveredAnswers(conversationID: UUID) async throws -> [UserQuestionAnswerDelivery] {
        let snapshots = try await snapshots(conversationID: conversationID, includeSettled: true)
        var deliveries: [UserQuestionAnswerDelivery] = []
        for snapshot in snapshots where !snapshot.hasBlockingPending {
            let answers = snapshot.questions.compactMap { question -> UserQuestionAnswerRecord? in
                // Only optionalContinue answers are next-turn deliveries.
                // Required/deadline answers already traveled in their tool
                // result; delivering them again would duplicate the answer.
                guard question.waitPolicy == .optionalContinue,
                      question.status == .answered,
                      question.answerSource == .human,
                      question.deliveredAt == nil,
                      let record = question.answerRecord() else { return nil }
                return record
            }
            guard !answers.isEmpty else { continue }
            deliveries.append(UserQuestionAnswerDelivery(
                requestID: snapshot.requestID,
                conversationID: snapshot.conversationID,
                runID: snapshot.runID,
                answers: answers,
                createdAt: Date(),
                deliveredAt: nil,
                text: UserQuestionFormatting.deliveryText(request: snapshot, answers: answers)
            ))
        }
        return deliveries
    }

    public func markDelivered(questionIDs: [String], at date: Date) async throws {
        guard !questionIDs.isEmpty else { return }
        let ids = Set(questionIDs)
        for (requestID, stored) in ephemeral {
            var stored = stored
            var changed = false
            for index in stored.questions.indices where ids.contains(stored.questions[index].questionID) {
                if stored.questions[index].deliveredAt == nil {
                    stored.questions[index].deliveredAt = date
                    changed = true
                }
            }
            if changed { ephemeral[requestID] = stored }
        }
        try await database.writer { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT question_id, payload_json FROM user_questions
                    WHERE question_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                    """,
                arguments: StatementArguments(Array(ids))
            )
            for row in rows {
                guard let id = row["question_id"] as String?,
                      let payload = row["payload_json"] as String? else { continue }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                guard var question = try? decoder.decode(UserQuestion.self, from: Data(payload.utf8)) else { continue }
                guard question.deliveredAt == nil else { continue }
                question.deliveredAt = date
                let data = try JSONEncoder.millisecondsSince1970.encode(question)
                try db.execute(
                    sql: "UPDATE user_questions SET payload_json = ?, delivered_at = ? WHERE question_id = ?",
                    arguments: [String(decoding: data, as: UTF8.self), date.timeIntervalSince1970, id]
                )
            }
        }
    }

    // MARK: - Settlement helpers

    private static func applySettlement(
        to stored: inout StoredRequest,
        index: Int,
        target: UserQuestionAnswerTarget,
        answer: UserQuestionAnswer?,
        source: UserQuestionAnswerSource,
        status: UserQuestionStatus,
        now: Date
    ) throws -> UserQuestionAnswerReceipt {
        var question = stored.questions[index]
        try requireBound(question, target: target)
        // A settled question returns its original receipt even for a stale
        // card/duplicate notification action. It must never be overwritten by
        // a later answer. Only a PENDING question applies the CAS revision.
        guard question.status == .pending else {
            return UserQuestionAnswerReceipt(
                target: target,
                status: question.status,
                revision: question.revision,
                accepted: false,
                alreadySettled: true,
                answer: question.answerRecord(),
                requestState: stored.header.state
            )
        }
        guard question.revision == target.expectedRevision else {
            throw UserQuestionError.staleRevision(current: question.revision)
        }
        let normalized: UserQuestionAnswer?
        if let answer {
            normalized = try answer.validated(for: question, partial: false)
        } else {
            normalized = nil
        }
        if status == .answered, normalized == nil {
            throw UserQuestionError.invalidAnswer("An answered question needs a complete answer.")
        }
        question.status = status
        question.answer = normalized
        question.draftAnswer = nil
        question.answerSource = source
        question.answeredAt = normalized == nil ? nil : now
        question.revision += 1
        question.updatedAt = now
        stored.questions[index] = question
        stored.header.updatedAt = now
        stored.header.state = requestState(stored.questions)
        return UserQuestionAnswerReceipt(
            target: UserQuestionAnswerTarget(
                requestID: target.requestID,
                questionID: target.questionID,
                conversationID: target.conversationID,
                runID: target.runID,
                expectedRevision: question.revision
            ),
            status: question.status,
            revision: question.revision,
            accepted: true,
            alreadySettled: false,
            answer: question.answerRecord(),
            requestState: stored.header.state
        )
    }

    private static func applyExpiry(to stored: inout StoredRequest, now: Date) {
        var changed = false
        for index in stored.questions.indices {
            var question = stored.questions[index]
            guard question.status == .pending,
                  question.waitPolicy == .optionalDeadline,
                  let deadline = question.deadlineAt,
                  deadline <= now else { continue }
            question.status = .expired
            question.draftAnswer = nil
            question.updatedAt = now
            if let fallback = question.fallback,
               let fallbackAnswer = try? UserQuestionAnswer(
                   selectedOptionIDs: fallback.selectedOptionIDs,
                   freeText: fallback.freeText
               ).validated(for: question, partial: false) {
                question.answer = fallbackAnswer
                question.answerSource = .deadlineDefault
                question.answeredAt = now
            } else {
                question.answer = nil
                question.answerSource = .expired
                question.answeredAt = nil
            }
            question.revision += 1
            stored.questions[index] = question
            changed = true
        }
        guard changed else { return }
        stored.header.updatedAt = now
        stored.header.state = requestState(stored.questions)
    }

    private static func applyCancellation(to stored: inout StoredRequest, now: Date) {
        var changed = false
        for index in stored.questions.indices {
            var question = stored.questions[index]
            guard question.status == .pending else { continue }
            question.status = .cancelled
            question.answer = nil
            question.draftAnswer = nil
            question.answerSource = .cancelled
            question.answeredAt = nil
            question.revision += 1
            question.updatedAt = now
            stored.questions[index] = question
            changed = true
        }
        guard changed else { return }
        stored.header.updatedAt = now
        stored.header.state = requestState(stored.questions)
    }

    private static func requireBound(_ question: UserQuestion, target: UserQuestionAnswerTarget) throws {
        guard question.requestID == target.requestID,
              question.questionID == target.questionID,
              question.conversationID == target.conversationID,
              question.runID == target.runID else {
            throw UserQuestionError.runMismatch
        }
    }

    private static func requestState(_ questions: [UserQuestion]) -> UserQuestionRequestState {
        if questions.contains(where: \.blocksCurrentWork) { return .awaitingAnswer }
        if questions.contains(where: \.isOptionalPending) { return .awaitingOptional }
        if questions.contains(where: { $0.status == .cancelled }) { return .cancelled }
        return .settled
    }

    private static func snapshot(_ stored: StoredRequest) -> UserQuestionWaitingSnapshot {
        UserQuestionWaitingSnapshot(
            requestID: stored.header.requestID,
            requestDigest: stored.header.requestDigest,
            conversationID: stored.header.conversationID,
            runID: stored.header.runID,
            toolCallID: stored.header.toolCallID,
            waitPolicy: stored.header.waitPolicy,
            state: stored.header.state,
            questions: stored.questions,
            createdAt: stored.header.createdAt,
            updatedAt: stored.header.updatedAt,
            isEphemeral: stored.header.isEphemeral
        )
    }

    // MARK: - SQLite

    private static func insert(_ db: Database, _ stored: StoredRequest) throws {
        let headerData = try JSONEncoder.millisecondsSince1970.encode(stored.header)
        try db.execute(
            sql: """
                INSERT INTO user_question_requests
                    (request_id, conversation_id, run_id, tool_call_id, request_digest,
                     wait_policy, state, created_at, updated_at, request_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                stored.header.requestID,
                stored.header.conversationID.uuidString,
                stored.header.runID.uuidString,
                stored.header.toolCallID,
                stored.header.requestDigest,
                stored.header.waitPolicy.rawValue,
                stored.header.state.rawValue,
                stored.header.createdAt.timeIntervalSince1970,
                stored.header.updatedAt.timeIntervalSince1970,
                String(decoding: headerData, as: UTF8.self),
            ]
        )
        for question in stored.questions {
            let payload = try JSONEncoder.millisecondsSince1970.encode(question)
            try db.execute(
                sql: """
                    INSERT INTO user_questions
                        (question_id, request_id, conversation_id, run_id, ordinal,
                         revision, status, payload_json, updated_at, delivered_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    question.questionID,
                    question.requestID,
                    question.conversationID.uuidString,
                    question.runID.uuidString,
                    question.ordinal,
                    question.revision,
                    question.status.rawValue,
                    String(decoding: payload, as: UTF8.self),
                    question.updatedAt.timeIntervalSince1970,
                    question.deliveredAt?.timeIntervalSince1970,
                ]
            )
        }
    }

    private static func write(_ db: Database, _ stored: StoredRequest) throws {
        let headerData = try JSONEncoder.millisecondsSince1970.encode(stored.header)
        try db.execute(
            sql: """
                UPDATE user_question_requests
                SET request_digest = ?, wait_policy = ?, state = ?, updated_at = ?, request_json = ?
                WHERE request_id = ?
                """,
            arguments: [
                stored.header.requestDigest,
                stored.header.waitPolicy.rawValue,
                stored.header.state.rawValue,
                stored.header.updatedAt.timeIntervalSince1970,
                String(decoding: headerData, as: UTF8.self),
                stored.header.requestID,
            ]
        )
        for question in stored.questions {
            let payload = try JSONEncoder.millisecondsSince1970.encode(question)
            try db.execute(
                sql: """
                    UPDATE user_questions
                    SET revision = ?, status = ?, payload_json = ?, updated_at = ?, delivered_at = ?
                    WHERE question_id = ?
                    """,
                arguments: [
                    question.revision,
                    question.status.rawValue,
                    String(decoding: payload, as: UTF8.self),
                    question.updatedAt.timeIntervalSince1970,
                    question.deliveredAt?.timeIntervalSince1970,
                    question.questionID,
                ]
            )
        }
    }

    private static func read(_ db: Database, requestID: String) throws -> StoredRequest? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT request_json FROM user_question_requests WHERE request_id = ?",
            arguments: [requestID]
        ), let json = row["request_json"] as String? else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let header = try decoder.decode(Header.self, from: Data(json.utf8))
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT payload_json FROM user_questions WHERE request_id = ? ORDER BY ordinal",
            arguments: [requestID]
        )
        let questions = try rows.compactMap { row -> UserQuestion? in
            guard let payload = row["payload_json"] as String? else { return nil }
            return try decoder.decode(UserQuestion.self, from: Data(payload.utf8))
        }
        return StoredRequest(header: header, questions: questions)
    }
}

private extension JSONEncoder {
    static var millisecondsSince1970: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
