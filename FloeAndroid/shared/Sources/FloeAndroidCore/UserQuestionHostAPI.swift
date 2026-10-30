// SPDX-License-Identifier: MPL-2.0
//
// Android host surface for durable, task-bound user questions.
//
// The runtime tool (`user.ask`), the durable/RAM store, the wait coordinator
// and the answer receipt are the SAME frozen iOS contracts (UserQuestion.swift
// / UserQuestionStore.swift / UserQuestionCoordinator.swift / UserAskTool.swift
// ported as applicable files). This file only adds the Android command
// boundary and the process-wide installation used by tool discovery:
//
//   question.pending  -> bounded pending snapshots for the owning task
//   question.answer   -> exact-once CAS answer (in-app or notification)
//   question.cancel   -> explicit cancel / terminal fence
//
// Rules enforced here (not left to the model or the UI):
//  * the envelope taskID is the conversation owner; a question from another
//    task/run is a typed runMismatch, never settled;
//  * requestDigest + answerNonce + expectedRevision must all match the
//    exact pending question generation the caller was shown;
//  * the answer is ordinary conversation data. It grants no permission and
//    returns the receipt from the store, never a fabricated success;
//  * temporary questions stay RAM-only (`isEphemeral`), are never notified
//    with content and are purged with their run/conversation;
//  * the tool is advertised only while a real coordinator is installed for
//    the current composition epoch. A retired/absent runtime returns a typed
//    unavailable failure instead of a descriptor that cannot execute.
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeAgentRuntime

/// Wire projection for the App's question surface. The wire stays JSON-object
/// based like the other typed App carriers and carries no secret material.
public enum UserQuestionHostWire {
    public static let schema = "floe.question.v1"

    public static func answerNonce(
        requestID: String,
        questionID: String,
        revision: Int,
        requestDigest: String
    ) -> String {
        FloeDigest.sha256Hex(Data(
            "floe.question.answer\u{1f}\(requestID)\u{1f}\(questionID)\u{1f}\(revision)\u{1f}\(requestDigest)"
                .utf8))
    }

    public static func snapshot(_ snapshot: UserQuestionWaitingSnapshot) -> [String: Any] {
        [
            "requestID": snapshot.requestID,
            "requestDigest": snapshot.requestDigest,
            "conversationID": snapshot.conversationID.uuidString,
            "runID": snapshot.runID.uuidString,
            "toolCallID": snapshot.toolCallID,
            "waitPolicy": snapshot.waitPolicy.rawValue,
            "state": snapshot.state.rawValue,
            "isEphemeral": snapshot.isEphemeral,
            "createdAt": ConversationWireDate.encode(snapshot.createdAt),
            "updatedAt": ConversationWireDate.encode(snapshot.updatedAt),
            "currentQuestionID": (snapshot.currentQuestion?.questionID as Any?) ?? NSNull(),
            "questions": snapshot.questions.map(Self.question(_:)),
        ]
    }

    public static func question(_ question: UserQuestion) -> [String: Any] {
        var object: [String: Any] = [
            "questionID": question.questionID,
            "ordinal": question.ordinal,
            "localID": question.localID,
            "text": question.text,
            "options": question.options.map { option in
                [
                    "id": option.id,
                    "label": option.label,
                    "detail": (option.detail as Any?) ?? NSNull(),
                ] as [String: Any]
            },
            "selectionMode": question.selectionMode.rawValue,
            "allowsFreeText": question.allowsFreeText,
            "waitPolicy": question.waitPolicy.rawValue,
            "status": question.status.rawValue,
            "revision": question.revision,
            "createdAt": ConversationWireDate.encode(question.createdAt),
            "updatedAt": ConversationWireDate.encode(question.updatedAt),
        ]
        if let deadline = question.deadlineAt {
            object["deadlineAt"] = ConversationWireDate.encode(deadline)
        } else {
            object["deadlineAt"] = NSNull()
        }
        if let fallback = question.fallback {
            object["fallback"] = [
                "selectedOptionIDs": fallback.selectedOptionIDs,
                "freeText": (fallback.freeText as Any?) ?? NSNull(),
            ]
        } else {
            object["fallback"] = NSNull()
        }
        if let answer = question.answer {
            object["answer"] = [
                "selectedOptionIDs": answer.selectedOptionIDs,
                "freeText": (answer.freeText as Any?) ?? NSNull(),
            ]
        } else {
            object["answer"] = NSNull()
        }
        object["answerSource"] = (question.answerSource?.rawValue as Any?) ?? NSNull()
        object["answeredAt"] = (question.answeredAt.map(ConversationWireDate.encode) as Any?) ?? NSNull()
        return object
    }

    public static func receipt(_ receipt: UserQuestionAnswerReceipt) -> [String: Any] {
        [
            "schema": schema,
            "requestID": receipt.target.requestID,
            "questionID": receipt.target.questionID,
            "conversationID": receipt.target.conversationID.uuidString,
            "runID": receipt.target.runID.uuidString,
            "status": receipt.status.rawValue,
            "revision": receipt.revision,
            "accepted": receipt.accepted,
            "alreadySettled": receipt.alreadySettled,
            "requestState": receipt.requestState.rawValue,
            "answer": receipt.answer.map { record in
                [
                    "questionID": record.questionID,
                    "question": record.question,
                    "selectedOptionIDs": record.selectedOptionIDs,
                    "selectedOptionLabels": record.selectedOptionLabels,
                    "freeText": (record.freeText as Any?) ?? NSNull(),
                    "source": record.source.rawValue,
                    "answeredAt": (record.answeredAt.map(ConversationWireDate.encode) as Any?) ?? NSNull(),
                ] as [String: Any]
            } as Any? ?? NSNull(),
        ]
    }

    public static func errorCode(_ error: UserQuestionError) -> String {
        switch error {
        case .missingToolCallID: return "missingToolCallID"
        case .missingConversation: return "missingConversation"
        case .invalidRequest: return "invalidRequest"
        case .requestConflict: return "requestConflict"
        case .notFound: return "notFound"
        case .runMismatch: return "runMismatch"
        case .staleRevision: return "staleRevision"
        case .invalidAnswer: return "invalidAnswer"
        case .requestCancelled: return "requestCancelled"
        }
    }
}

/// Exact-once answer submission payload. Every identity field is required so
/// a notification action, a stale sheet or a different run can never settle a
/// newer generation.
public struct UserQuestionAnswerSubmission: Sendable, Equatable {
    public var requestID: String
    public var requestDigest: String
    public var questionID: String
    public var runID: UUID
    public var expectedRevision: Int
    public var answerNonce: String
    public var source: UserQuestionAnswerSource
    public var answer: UserQuestionAnswer

    public static let maximumFreeTextCharacters = 1_000

    public init(
        requestID: String,
        requestDigest: String,
        questionID: String,
        runID: UUID,
        expectedRevision: Int,
        answerNonce: String,
        source: UserQuestionAnswerSource,
        answer: UserQuestionAnswer
    ) {
        self.requestID = requestID
        self.requestDigest = requestDigest
        self.questionID = questionID
        self.runID = runID
        self.expectedRevision = expectedRevision
        self.answerNonce = answerNonce
        self.source = source
        self.answer = answer
    }

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> UserQuestionAnswerSubmission
    {
        guard let payload else {
            throw UserQuestionError.invalidRequest("missingPayload")
        }
        guard case .object(let root) = payload else {
            throw UserQuestionError.invalidRequest("invalidPayload")
        }
        let allowed: Set<String> = [
            "requestID", "requestDigest", "questionID", "runID",
            "expectedRevision", "answerNonce", "source",
            "selectedOptionIDs", "freeText",
        ]
        guard root.keys.allSatisfy(allowed.contains) else {
            throw UserQuestionError.invalidRequest("unknownAnswerField")
        }
        func string(_ key: String) throws -> String {
            guard case .string(let value)? = root[key], !value.isEmpty, value.utf8.count <= 160 else {
                throw UserQuestionError.invalidRequest("invalidPayloadField:\(key)")
            }
            return value
        }
        let requestID = try string("requestID")
        guard requestID.hasPrefix("uq_"), requestID.count == 35 else {
            throw UserQuestionError.invalidRequest("invalidPayloadField:requestID")
        }
        let requestDigest = try string("requestDigest")
        guard requestDigest.count == 64,
              requestDigest.allSatisfy({
                  $0.isHexDigit && (!$0.isLetter || $0.isLowercase)
              }) else {
            throw UserQuestionError.invalidRequest("invalidPayloadField:requestDigest")
        }
        let questionID = try string("questionID")
        guard questionID.hasPrefix(requestID + ".") else {
            throw UserQuestionError.invalidRequest("invalidPayloadField:questionID")
        }
        guard case .string(let runRaw)? = root["runID"], let runID = UUID(uuidString: runRaw) else {
            throw UserQuestionError.invalidRequest("invalidPayloadField:runID")
        }
        guard case .integer(let revisionRaw)? = root["expectedRevision"],
              revisionRaw >= 1, revisionRaw <= Int64(Int.max) else {
            throw UserQuestionError.invalidRequest("invalidPayloadField:expectedRevision")
        }
        guard case .string(let sourceRaw)? = root["source"],
              let source = UserQuestionAnswerSource(rawValue: sourceRaw),
              source == .human else {
            // deadlineDefault/expired/cancelled are produced by the store's
            // own expiry/cancel policy, never by a client answer.
            throw UserQuestionError.invalidRequest("invalidPayloadField:source")
        }
        let nonce = try string("answerNonce")
        var selected: [String] = []
        if let value = root["selectedOptionIDs"] {
            guard case .array(let elements) = value else {
                throw UserQuestionError.invalidRequest("invalidPayloadField:selectedOptionIDs")
            }
            for element in elements {
                guard case .string(let id) = element, !id.isEmpty, id.count <= 40 else {
                    throw UserQuestionError.invalidRequest("invalidPayloadField:selectedOptionIDs")
                }
                selected.append(id)
            }
        }
        var freeText: String?
        if let value = root["freeText"] {
            if case .string(let text) = value {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    guard trimmed.count <= maximumFreeTextCharacters else {
                        throw UserQuestionError.invalidRequest("freeTextTooLong")
                    }
                    freeText = trimmed
                }
            } else if !(value == .null) {
                throw UserQuestionError.invalidRequest("invalidPayloadField:freeText")
            }
        }
        return UserQuestionAnswerSubmission(
            requestID: requestID,
            requestDigest: requestDigest,
            questionID: questionID,
            runID: runID,
            expectedRevision: Int(revisionRaw),
            answerNonce: nonce,
            source: source,
            answer: UserQuestionAnswer(selectedOptionIDs: selected, freeText: freeText))
    }
}

/// Process-wide current installation. Only the accepted composition epoch may
/// publish a coordinator; a retired epoch keeps the tool unavailable rather
/// than letting a stale runner settle a newer store's question.
public final class UserQuestionHostAPI: @unchecked Sendable {
    public static let shared = UserQuestionHostAPI()

    private struct Installed {
        let epoch: UInt64
        let database: DatabaseManager
        let store: UserQuestionStore
        let coordinator: UserQuestionCoordinator
    }

    private let lock = NSLock()
    private var installed: Installed?

    private init() {}

    @discardableResult
    public func install(database: DatabaseManager, epoch: UInt64) -> UserQuestionCoordinator {
        let store = UserQuestionStore(database: database)
        let coordinator = UserQuestionCoordinator(store: store)
        lock.lock()
        installed = Installed(epoch: epoch, database: database, store: store,
                              coordinator: coordinator)
        lock.unlock()
        UserQuestionToolRegistration.registerIfNeeded(api: self)
        return coordinator
    }

    public func current() -> UserQuestionCoordinator? {
        lock.lock()
        defer { lock.unlock() }
        return installed?.coordinator
    }

    /// Generation-exact coordinator for a registered command handler. A stale
    /// generation must never settle a newer root's question.
    public func current(epoch: UInt64) -> UserQuestionCoordinator? {
        lock.lock()
        defer { lock.unlock() }
        guard let installed, installed.epoch == epoch else { return nil }
        return installed.coordinator
    }

    public func isInstalled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return installed != nil
    }

    public func retire(epoch: UInt64) {
        lock.lock()
        let shouldRetire = installed?.epoch == epoch
        if shouldRetire { installed = nil }
        lock.unlock()
        if shouldRetire {
            UserQuestionToolRegistration.unregister()
        }
    }

    // MARK: - Command handlers

    public func pending(
        conversationID: UUID,
        epoch: UInt64,
        payload: SettingsDomainV1.JSONValue?
    ) async throws -> [String: Any] {
        guard let coordinator = current(epoch: epoch) else {
            throw UserQuestionError.notFound
        }
        var requestID: String?
        if let payload {
            guard case .object(let root) = payload else {
                throw UserQuestionError.invalidRequest("invalidPayload")
            }
            guard root.keys.allSatisfy({ $0 == "requestID" }) else {
                throw UserQuestionError.invalidRequest("unknownPendingField")
            }
            if let value = root["requestID"] {
                guard case .string(let raw) = value, !raw.isEmpty else {
                    throw UserQuestionError.invalidRequest("invalidPayloadField:requestID")
                }
                requestID = raw
            }
        }
        let snapshots: [UserQuestionWaitingSnapshot]
        if let requestID {
            guard let snapshot = try await coordinator.snapshot(requestID: requestID),
                  snapshot.conversationID == conversationID else {
                throw UserQuestionError.notFound
            }
            snapshots = [snapshot]
        } else {
            let pending = try await coordinator.snapshots(
                conversationID: conversationID, includeSettled: false)
            var yes: [UserQuestionWaitingSnapshot] = []
            // A pending row with NO parked execution is a process-death
            // leftover. It is not answerable; after a short grace window
            // (protects the register→park handoff) cancel it honestly so the
            // UI never presents a false live wait.
            let staleBefore = Date().addingTimeInterval(-5)
            for snapshot in pending {
                if await coordinator.isActivelyWaiting(requestID: snapshot.requestID) {
                    yes.append(snapshot)
                } else if snapshot.createdAt < staleBefore {
                    try? await coordinator.cancelRequest(requestID: snapshot.requestID)
                }
            }
            snapshots = yes
        }
        var objects: [[String: Any]] = []
        for snapshot in snapshots {
            objects.append(try await Self.snapshotJSON(snapshot))
        }
        return [
            "schema": UserQuestionHostWire.schema,
            "conversationID": conversationID.uuidString,
            "requests": objects,
        ]
    }

    public func answer(
        conversationID: UUID,
        epoch: UInt64,
        payload: SettingsDomainV1.JSONValue?
    ) async throws -> [String: Any] {
        guard let coordinator = current(epoch: epoch) else {
            throw UserQuestionError.notFound
        }
        let submission = try UserQuestionAnswerSubmission.parse(payload)
        guard let snapshot = try await coordinator.snapshot(requestID: submission.requestID),
              snapshot.conversationID == conversationID,
              snapshot.runID == submission.runID,
              snapshot.requestDigest == submission.requestDigest,
              let question = snapshot.questions.first(where: {
                  $0.questionID == submission.questionID
              }) else {
            throw UserQuestionError.runMismatch
        }
        // The nonce binds this answer to the EXACT identity the card was
        // minted for: same request/question/digest and the revision the host
        // stamped on that card. It is validated against the SUBMITTED
        // revision, not the current row revision, because a duplicate reply
        // legitimately carries the pre-settlement card after the row advanced.
        let expectedNonce = UserQuestionHostWire.answerNonce(
            requestID: question.requestID,
            questionID: question.questionID,
            revision: submission.expectedRevision,
            requestDigest: snapshot.requestDigest)
        guard submission.answerNonce == expectedNonce else {
            throw UserQuestionError.staleRevision(current: question.revision)
        }
        // A card can never carry a revision the row has not reached. This
        // also rejects an invented post-settlement revision nonce; a real
        // duplicate card carries the PRE-settlement revision.
        guard submission.expectedRevision <= question.revision else {
            throw UserQuestionError.staleRevision(current: question.revision)
        }
        if question.status == .pending {
            // A first settlement needs a REAL parked execution in this
            // process and the current CAS revision. A durable pending row
            // left by process death is not answerable; its continuation is
            // gone and no settlement may be fabricated.
            guard await coordinator.isActivelyWaiting(requestID: submission.requestID) else {
                throw UserQuestionError.requestCancelled
            }
            guard question.revision == submission.expectedRevision else {
                throw UserQuestionError.staleRevision(current: question.revision)
            }
        }
        // An already-settled exact question goes straight to the ORIGINAL
        // store settlement. It returns its own receipt with
        // accepted=false/alreadySettled=true before any revision CAS, so a
        // duplicate notification/in-app reply gets the first answer's
        // receipt, never a new settlement, signal or continuation. The
        // envelope, question identity and nonce above still had to match.
        let receipt = try await coordinator.submitHumanAnswer(
            target: snapshot.target(for: question),
            answer: submission.answer)
        return UserQuestionHostWire.receipt(receipt)
    }

    public func cancel(
        conversationID: UUID,
        epoch: UInt64,
        payload: SettingsDomainV1.JSONValue?
    ) async throws -> [String: Any] {
        guard let coordinator = current(epoch: epoch) else {
            throw UserQuestionError.notFound
        }
        guard let payload, case .object(let root) = payload,
              root.keys.allSatisfy({ ["requestID", "runID"].contains($0) }),
              case .string(let requestID)? = root["requestID"],
              !requestID.isEmpty else {
            throw UserQuestionError.invalidRequest("invalidPayloadField:requestID")
        }
        guard let snapshot = try await coordinator.snapshot(requestID: requestID),
              snapshot.conversationID == conversationID else {
            throw UserQuestionError.notFound
        }
        if case .string(let runRaw)? = root["runID"] {
            guard let runID = UUID(uuidString: runRaw), snapshot.runID == runID else {
                throw UserQuestionError.runMismatch
            }
        }
        try await coordinator.cancelRequest(requestID: requestID)
        guard let updated = try await coordinator.snapshot(requestID: requestID) else {
            throw UserQuestionError.notFound
        }
        return try await Self.snapshotJSON(updated)
    }

    // MARK: - Async snapshot encoding

    public static func snapshotJSON(
        _ snapshot: UserQuestionWaitingSnapshot
    ) async throws -> [String: Any] {
        var object = UserQuestionHostWire.snapshot(snapshot)
        // The per-question nonce is the exact revision/digest generation. It
        // is computed from the SNAPSHOT (not a stale local cache), so the App
        // can never answer a generation the store no longer holds.
        if var questions = object["questions"] as? [[String: Any]] {
            questions = questions.map { question in
                var question = question
                if let questionID = question["questionID"] as? String,
                   let revisionNumber = question["revision"] as? Int {
                    question["answerNonce"] = UserQuestionHostWire.answerNonce(
                        requestID: snapshot.requestID,
                        questionID: questionID,
                        revision: revisionNumber,
                        requestDigest: snapshot.requestDigest)
                }
                return question
            }
            object["questions"] = questions
        }
        return object
    }
}

/// Register the real runner once. `isAvailable` reads the live installation,
/// so discovery and execution agree: a retired composition advertises no
/// `user.ask` and a direct dispatch fails closed instead of silently using a
/// second coordinator.
enum UserQuestionToolRegistration {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered = false

    static func unregister() {
        lock.lock()
        registered = false
        lock.unlock()
        ToolRunnerRegistry.shared.unregister { $0 == UserAskTool.name }
    }

    static func registerIfNeeded(api: UserQuestionHostAPI) {
        lock.lock()
        let already = registered
        registered = true
        lock.unlock()
        ToolCatalog.register(UserAskTool.self)
        guard !already else { return }
        var tool = AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: UserAskTool.name,
                toolDescription: UserAskTool.toolDescription,
                parametersJSON: UserAskTool.parametersJSON,
                riskLabels: [],
                isSideEffecting: false,
                effect: .internalState,
                prerequisites: [],
                executionBoundary: .mainRunOnly,
                supportsConcurrentBatchDispatch: false),
            run: { data, context in
                guard let coordinator = UserQuestionHostAPI.shared.current() else {
                    throw FloeError.validationFailed(
                        "user.ask is unavailable until the task runtime is connected.")
                }
                let arguments = try JSONDecoder().decode(
                    UserQuestionRequest.self, from: data)
                try arguments.validate()
                return try await UserAskTool(coordinator: coordinator)
                    .execute(arguments, context: context)
            },
            validateArguments: { data in
                let arguments = try JSONDecoder().decode(
                    UserQuestionRequest.self, from: data)
                try arguments.validate()
            })
        _ = api
        tool.isAvailable = {
            UserQuestionHostAPI.shared.isInstalled()
        }
        ToolRunnerRegistry.shared.register(tool)
    }
}
