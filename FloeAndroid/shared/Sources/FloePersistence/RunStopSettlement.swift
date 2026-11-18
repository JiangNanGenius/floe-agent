// SPDX-License-Identifier: MPL-2.0
//
// Typed, durable user-stop settlement for one ORDINARY run.
//
// Why this exists: Android keeps `checkpointed` as the terminal vocabulary for
// a user stop, and the ordinary runtime persists a localized checkpoint
// reason. Neither the state name, a localized string, nor a live-owner
// absence can prove that the user's Stop really settled the run the caller
// meant. This seam adds ONE append-only typed settlement row bound to:
//
//   * the exact run + conversation rows already in `runs`;
//   * the run's durable INCARNATION — the latest native activation
//     (`preparing` status row written by the launch transaction or by
//     `beginUserResume`), identified by the row's event id, activation proof
//     and a native digest;
//   * the native stop cause (`reasonKey`, never localized text);
//   * a self-checking digest over every settlement field.
//
// The settlement row is written INSIDE the same writer transaction as the
// parked-run state CAS, or in a CAS writer transaction that re-proves
// `runs.state == checkpointed` and the same current incarnation for the live
// runtime cancel. A stale stop, a retry that already opened a newer
// incarnation, a legacy run with no provable incarnation, and an unreadable
// store all fail closed: nothing is written and no typed proof is produced.
//
// This file adds no table, column, command or tool. It is a read/write
// capability of the ORIGINAL SQLiteRunStore; EphemeralRunStore does not
// conform, so a temporary RAM run can never mint a durable stop proof.

import Foundation
import GRDB
import FloeCore
import FloeModels

/// Stable machine vocabulary of the stop settlement. The reason key is the
/// same key the ORIGINAL runtime uses for a user stop; it is a localization
/// key, not user-visible text, and is never translated here.
public enum RunStopSettlementVocabulary {
    public static let settlementSchema = "floe.run-stop-settlement/1"
    public static let reasonKey = "runtime.agent_runtime.the_task_was_stopped_by_you"
    public static let activationKind = "userStop"
}

/// Durable incarnation of ONE run activation. Every native activation writes a
/// `status` row with `state = preparing`; a launch row carries
/// `floeActivation` with the trusted activation proof, and a resume row carries
/// the `userResume` marker. The proof below binds the run identity, that exact
/// event and the activation proof, so a later retry produces a different
/// incarnation even though it reuses the same run id.
public struct RunIncarnation: Sendable, Equatable, Hashable {
    public enum Source: String, Sendable, Equatable, Hashable {
        /// The latest `preparing` row carries a valid native activation
        /// marker (`user` / `goalContinuation` / `userResume`).
        case activation
        /// A legacy `preparing` status row without an activation marker. It
        /// is still an exact durable event identity, so the stop can be
        /// bound to it; the proof is derived from that row.
        case launchStatus
    }

    public var runID: UUID
    public var conversationID: UUID
    /// The `run_events.id` of the activation row this incarnation starts at.
    public var eventID: UUID
    /// Its per-run sequence (diagnostic; also part of the settlement digest).
    public var sequence: Int
    public var source: Source
    /// 64-char lowercase SHA-256 over the run identity + event identity +
    /// activation proof (when present).
    public var proof: String
    /// `user` / `goalContinuation` / `userResume` for `.activation`.
    public var activationKind: String?

    public init(runID: UUID, conversationID: UUID, eventID: UUID,
                sequence: Int, source: Source, proof: String,
                activationKind: String? = nil) {
        self.runID = runID
        self.conversationID = conversationID
        self.eventID = eventID
        self.sequence = sequence
        self.source = source
        self.proof = proof
        self.activationKind = activationKind
    }
}

/// One durable, self-checking user-stop settlement. Only a row that decodes
/// with a matching digest and a matching CURRENT incarnation may be presented
/// to the host as `settled`.
public struct RunStopSettlement: Sendable, Equatable, Hashable {
    public enum Path: String, Sendable, Equatable, Hashable {
        /// Explicit Stop of a dependency-parked run (one writer transaction
        /// with the `checkpointed` row CAS).
        case parkedDependency
        /// Ordinary live run closed through `ConversationRunService.cancel`
        /// (the runtime terminal is re-proved before this row is appended).
        case liveCancel
    }

    /// The settlement row's own `run_events.id`.
    public var eventID: UUID
    /// The settlement row's per-run sequence.
    public var sequence: Int
    public var settlementID: UUID
    public var runID: UUID
    public var conversationID: UUID
    public var path: Path
    /// Persisted ISO-8601 string; kept verbatim so the digest stays stable.
    public var settledAt: String
    public var reasonKey: String
    public var expectedState: String
    public var incarnation: RunIncarnation
    /// True only when the writer proved no live producer owned the run at
    /// settlement time (parked: no owner; live: this exact runtime cancel).
    public var ownerAbsent: Bool
    /// 64-char lowercase SHA-256 over every persisted field above.
    public var settlementDigest: String

    public init(eventID: UUID, sequence: Int, settlementID: UUID,
                runID: UUID, conversationID: UUID, path: Path,
                settledAt: String, reasonKey: String, expectedState: String,
                incarnation: RunIncarnation, ownerAbsent: Bool,
                settlementDigest: String) {
        self.eventID = eventID
        self.sequence = sequence
        self.settlementID = settlementID
        self.runID = runID
        self.conversationID = conversationID
        self.path = path
        self.settledAt = settledAt
        self.reasonKey = reasonKey
        self.expectedState = expectedState
        self.incarnation = incarnation
        self.ownerAbsent = ownerAbsent
        self.settlementDigest = settlementDigest
    }
}

/// Result of reading the latest settlement row against current durable truth.
/// A caller may claim "stopped" only when `isSettled` is true; `settlement`
/// may exist while `isCurrentIncarnation` is false (the user already retried)
/// and MUST NOT be presented as the current run's stop.
public struct RunStopSettlementReadback: Sendable, Equatable {
    public var settlement: RunStopSettlement?
    public var runState: String
    public var currentIncarnation: RunIncarnation?
    public var isCurrentIncarnation: Bool
    /// False when the newest candidate row failed validation (bad identity,
    /// digest, run/conversation binding). Never treated as settled.
    public var isValid: Bool

    public init(settlement: RunStopSettlement?, runState: String,
                currentIncarnation: RunIncarnation?,
                isCurrentIncarnation: Bool, isValid: Bool) {
        self.settlement = settlement
        self.runState = runState
        self.currentIncarnation = currentIncarnation
        self.isCurrentIncarnation = isCurrentIncarnation
        self.isValid = isValid
    }

    /// The ONE typed truth a host may use as a successful stop proof:
    /// a valid settlement, the run still holding Android's `checkpointed`
    /// stop vocabulary, and the settlement bound to the CURRENT incarnation.
    public var isSettled: Bool {
        settlement != nil && isValid && runState == "checkpointed"
            && isCurrentIncarnation
    }
}

/// Durable identity snapshot used by `run.cancel`/`run.retry` before they
/// mutate anything. State and incarnation are read in ONE reader transaction
/// so the command can never pair a stale state with a newer incarnation.
public struct RunStopIdentitySnapshot: Sendable, Equatable {
    public var runID: UUID
    public var conversationID: UUID
    public var state: String
    public var startedAt: String
    public var incarnation: RunIncarnation?
    /// Sequence of the newest typed settlement row observed in the SAME read.
    /// A retry captures this watermark so only a NEWER Stop (one that lands
    /// during its admission) can invalidate it; a Stop that already existed
    /// before the user pressed Continue is correctly resumable.
    public var latestSettlementSequence: Int?
    /// Latest status at the same read boundary; zero means none exists.
    public var latestStatusSequence: Int

    public init(runID: UUID, conversationID: UUID, state: String,
                startedAt: String, incarnation: RunIncarnation?,
                latestSettlementSequence: Int? = nil,
                latestStatusSequence: Int = 0) {
        self.runID = runID
        self.conversationID = conversationID
        self.state = state
        self.startedAt = startedAt
        self.incarnation = incarnation
        self.latestSettlementSequence = latestSettlementSequence
        self.latestStatusSequence = latestStatusSequence
    }
}

/// Closed commit outcome. `.settled`/`.alreadySettled` are the only values
/// that carry a typed proof; `.unboundStopped` preserves the ORIGINAL legacy
/// stop write for a run with no provable incarnation, and never claims one.
public enum RunStopSettlementCommitResult: Sendable, Equatable {
    case settled(RunStopSettlement)
    case alreadySettled(RunStopSettlement)
    /// The legacy plain `userStop` row was written, but no typed settlement
    /// (the run has no provable incarnation). Hosts must not claim typed
    /// success from this value.
    case unboundStopped
    /// The caller's incarnation is no longer current (a retry or another
    /// activation won). Nothing was written.
    case staleIncarnation
    /// The run row is not in the expected state. Carries the bounded actual
    /// state name. Nothing was written.
    case notStopped(String)
    /// The store could not complete the transaction. Nothing was written.
    case unreadable
}

// MARK: - Reading / writing capabilities

public protocol RunStopSettlementReading: Sendable {
    /// Run state + latest incarnation in one reader transaction.
    func stopIdentity(runID: UUID, conversationID: UUID) async throws
        -> RunStopIdentitySnapshot?
    /// Latest settlement row plus its relation to the CURRENT incarnation.
    func latestStopSettlement(runID: UUID, conversationID: UUID) async throws
        -> RunStopSettlementReadback?
}

public protocol RunStopSettlementWriting: RunStopSettlementReading {
    /// Atomic explicit Stop of a parked run: the `checkpointed` row CAS and
    /// the typed settlement row commit together. When `expectedIncarnation`
    /// is nil the ORIGINAL plain `userStop` row is written for compatibility
    /// and `.unboundStopped` is returned (no typed proof).
    func commitParkedUserStop(runID: UUID, conversationID: UUID,
                              expectedState: String,
                              expectedIncarnation: RunIncarnation?,
                              expectedStatusSequence: Int?) async throws
        -> RunStopSettlementCommitResult
    /// Typed settlement for a runtime cancel that THIS call proved it
    /// stopped. Re-proves the `checkpointed` row and the same incarnation in
    /// one writer transaction; writes only the settlement status row.
    func commitRuntimeUserStop(runID: UUID, conversationID: UUID,
                               expectedIncarnation: RunIncarnation) async throws
        -> RunStopSettlementCommitResult
}

// MARK: - SQLiteRunStore conformance

extension SQLiteRunStore: RunStopSettlementReading, RunStopSettlementWriting {
    public func stopIdentity(runID: UUID, conversationID: UUID) async throws
        -> RunStopIdentitySnapshot? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, started_at FROM runs WHERE id = ? AND conversation_id = ?",
                arguments: [runID.uuidString, conversationID.uuidString])
            else { return nil }
            let state: String = row["state"]
            let startedAt: String = row["started_at"]
            let incarnation = try RunStopSettlementStoreCore.latestIncarnation(
                db: db, runID: runID, conversationID: conversationID,
                startedAt: startedAt)
            let settlementSequence =
                try RunStopSettlementStoreCore.latestSettlementSequence(
                    db: db, runID: runID, conversationID: conversationID)
            let statusSequence = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sequence), 0) FROM run_events
                WHERE run_id = ? AND kind = 'status'
                """, arguments: [runID.uuidString]) ?? 0
            return RunStopIdentitySnapshot(
                runID: runID, conversationID: conversationID, state: state,
                startedAt: startedAt, incarnation: incarnation,
                latestSettlementSequence: settlementSequence,
                latestStatusSequence: statusSequence)
        }
    }

    public func latestStopSettlement(runID: UUID, conversationID: UUID) async throws
        -> RunStopSettlementReadback? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, started_at FROM runs WHERE id = ? AND conversation_id = ?",
                arguments: [runID.uuidString, conversationID.uuidString])
            else { return nil }
            let state: String = row["state"]
            let startedAt: String = row["started_at"]
            let current = try RunStopSettlementStoreCore.latestIncarnation(
                db: db, runID: runID, conversationID: conversationID,
                startedAt: startedAt)
            let read = try RunStopSettlementStoreCore.latestSettlement(
                db: db, runID: runID, conversationID: conversationID)
            switch read {
            case .none:
                return RunStopSettlementReadback(
                    settlement: nil, runState: state,
                    currentIncarnation: current,
                    isCurrentIncarnation: false, isValid: true)
            case .invalid:
                return RunStopSettlementReadback(
                    settlement: nil, runState: state,
                    currentIncarnation: current,
                    isCurrentIncarnation: false, isValid: false)
            case .valid(let settlement, _, _):
                let isCurrent = current.map {
                    $0.proof == settlement.incarnation.proof
                } ?? false
                return RunStopSettlementReadback(
                    settlement: settlement, runState: state,
                    currentIncarnation: current,
                    isCurrentIncarnation: isCurrent, isValid: true)
            }
        }
    }

    public func commitParkedUserStop(runID: UUID, conversationID: UUID,
                                     expectedState: String,
                                     expectedIncarnation: RunIncarnation?,
                                     expectedStatusSequence: Int? = nil) async throws
        -> RunStopSettlementCommitResult {
        try await database.writer { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, started_at FROM runs WHERE id = ? AND conversation_id = ?",
                arguments: [runID.uuidString, conversationID.uuidString])
            else { return .notStopped("missing") }
            let state: String = row["state"]
            guard state == expectedState else {
                return .notStopped(RunStopSettlementStoreCore
                    .boundedState(state))
            }
            let startedAt: String = row["started_at"]
            let current = try RunStopSettlementStoreCore.latestIncarnation(
                db: db, runID: runID, conversationID: conversationID,
                startedAt: startedAt)
            guard let expectedIncarnation else {
                // An absent incarnation is only safe when the captured status
                // watermark still matches and the complete history proves no
                // activation. This prevents an old Stop hitting a new resume.
                guard let expectedStatusSequence else { return .staleIncarnation }
                let latestStatus = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(MAX(sequence), 0) FROM run_events
                    WHERE run_id = ? AND kind = 'status'
                    """, arguments: [runID.uuidString]) ?? 0
                guard latestStatus == expectedStatusSequence, current == nil else {
                    return .staleIncarnation
                }
                // nil also covers malformed activation markers. Examine the
                // complete history so that corruption can never masquerade as
                // an old, genuinely unbound run.
                let statuses = try String.fetchCursor(db, sql: """
                    SELECT payload_json FROM run_events
                    WHERE run_id = ? AND kind = 'status' ORDER BY sequence
                    """, arguments: [runID.uuidString])
                while let payload = try statuses.next() {
                    guard let object = RunStopSettlementStoreCore.jsonObject(payload),
                          (object["state"] as? String) != "preparing",
                          object["floeLegacyBootstrap"] == nil else {
                        return .staleIncarnation
                    }
                }
                try db.execute(
                    sql: """
                        UPDATE runs SET state = 'checkpointed', ended_at = ?
                        WHERE id = ? AND conversation_id = ? AND state = ?
                        """,
                    arguments: [PersistenceCodec.encode(Date()),
                                runID.uuidString, conversationID.uuidString,
                                expectedState])
                guard db.changesCount == 1 else {
                    let actual = try String.fetchOne(
                        db, sql: "SELECT state FROM runs WHERE id = ?",
                        arguments: [runID.uuidString]) ?? "unknown"
                    return .notStopped(RunStopSettlementStoreCore
                        .boundedState(actual))
                }
                let payload = try JSONSerialization.data(withJSONObject: [
                    "state": "checkpointed",
                    "reason": RunStopSettlementVocabulary.reasonKey,
                    "floeActivation": [
                        "version": 1,
                        "kind": RunStopSettlementVocabulary.activationKind,
                    ],
                ], options: [.sortedKeys])
                _ = try RunStopSettlementStoreCore.appendStatus(
                    db: db, runID: runID,
                    payload: String(decoding: payload, as: UTF8.self))
                return .unboundStopped
            }
            guard let current,
                  current.proof == expectedIncarnation.proof else {
                return .staleIncarnation
            }
            // Only AFTER the caller's exact incarnation is proven may an
            // existing settlement for THAT incarnation answer idempotently.
            // An old Stop aimed at a superseded incarnation is stale even if
            // the newer incarnation already has its own settlement.
            if let existing = try RunStopSettlementStoreCore
                .currentSettlement(db: db, runID: runID,
                                   conversationID: conversationID,
                                   current: current) {
                return .alreadySettled(existing)
            }
            try db.execute(
                sql: """
                    UPDATE runs SET state = 'checkpointed', ended_at = ?
                    WHERE id = ? AND conversation_id = ? AND state = ?
                    """,
                arguments: [PersistenceCodec.encode(Date()),
                            runID.uuidString, conversationID.uuidString,
                            expectedState])
            guard db.changesCount == 1 else {
                let actual = try String.fetchOne(
                    db, sql: "SELECT state FROM runs WHERE id = ?",
                    arguments: [runID.uuidString]) ?? "unknown"
                return .notStopped(RunStopSettlementStoreCore
                    .boundedState(actual))
            }
            let settlement = try RunStopSettlementStoreCore.appendSettlement(
                db: db, runID: runID, conversationID: conversationID,
                path: .parkedDependency, expectedState: expectedState,
                incarnation: current, ownerAbsent: true)
            return .settled(settlement)
        }
    }

    public func commitRuntimeUserStop(runID: UUID, conversationID: UUID,
                                      expectedIncarnation: RunIncarnation) async throws
        -> RunStopSettlementCommitResult {
        try await database.writer { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT state, started_at FROM runs WHERE id = ? AND conversation_id = ?",
                arguments: [runID.uuidString, conversationID.uuidString])
            else { return .notStopped("missing") }
            let state: String = row["state"]
            guard state == "checkpointed" else {
                return .notStopped(RunStopSettlementStoreCore
                    .boundedState(state))
            }
            let startedAt: String = row["started_at"]
            let current = try RunStopSettlementStoreCore.latestIncarnation(
                db: db, runID: runID, conversationID: conversationID,
                startedAt: startedAt)
            guard let current,
                  current.proof == expectedIncarnation.proof else {
                return .staleIncarnation
            }
            if let existing = try RunStopSettlementStoreCore
                .currentSettlement(db: db, runID: runID,
                                   conversationID: conversationID,
                                   current: current) {
                return .alreadySettled(existing)
            }
            let settlement = try RunStopSettlementStoreCore.appendSettlement(
                db: db, runID: runID, conversationID: conversationID,
                path: .liveCancel, expectedState: "checkpointed",
                incarnation: current, ownerAbsent: true)
            return .settled(settlement)
        }
    }
}

// MARK: - Store-internal helpers (shared with RunStore.beginUserResume)

enum RunStopSettlementStoreCore {
    enum SettlementRead {
        case none
        case valid(RunStopSettlement, sequence: Int, eventID: UUID)
        case invalid
    }

    static func boundedState(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 32,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "_") })
        else { return "unknown" }
        return value
    }

    static func isHex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func jsonObject(_ payload: String) -> [String: Any]? {
        guard payload.utf8.count <= 65_536,
              let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any]
    }

    static func jsonInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double,
              double >= 0, double <= 9_007_199_254_740_991 else { return nil }
        return number.intValue
    }

    /// Newest preparing activation row, read in bounded status-row pages
    /// (never an arbitrary "last 12 events" window). A malformed activation
    /// marker fails closed (nil) instead of silently binding an older row.
    static func latestIncarnation(db: Database, runID: UUID,
                                  conversationID: UUID,
                                  startedAt: String) throws
        -> RunIncarnation? {
        var before: Int?
        while true {
            let rows: [Row]
            if let before {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, sequence, payload_json FROM run_events
                    WHERE run_id = ? AND kind = 'status' AND sequence < ?
                    ORDER BY sequence DESC LIMIT 64
                    """, arguments: [runID.uuidString, before])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, sequence, payload_json FROM run_events
                    WHERE run_id = ? AND kind = 'status'
                    ORDER BY sequence DESC LIMIT 64
                    """, arguments: [runID.uuidString])
            }
            if rows.isEmpty { return nil }
            for row in rows {
                let payload: String = row["payload_json"]
                guard let object = jsonObject(payload) else {
                    throw FloeError.storageCorrupted("Unreadable run status")
                }
                if object["floeLegacyBootstrap"] != nil {
                    guard let bootstrap = object["floeLegacyBootstrap"] as? [String: Any],
                          jsonInt(bootstrap["version"]) == 1,
                          let eventID = UUID(uuidString: row["id"]) else { return nil }
                    return makeIncarnation(
                        runID: runID, conversationID: conversationID,
                        eventID: eventID, sequence: row["sequence"],
                        source: .launchStatus, activationKind: nil,
                        activationProof: nil, startedAt: startedAt)
                }
                guard (object["state"] as? String) == "preparing" else { continue }
                guard let eventID = UUID(uuidString: row["id"]) else {
                    return nil
                }
                let sequence: Int = row["sequence"]
                if object["floeActivation"] != nil {
                    guard let activation = object["floeActivation"]
                            as? [String: Any],
                          jsonInt(activation["version"]) == 1,
                          let kind = activation["kind"] as? String,
                          ["user", "goalContinuation", "userResume"]
                            .contains(kind),
                          let proof = activation["proof"] as? String,
                          isHex64(proof) else {
                        return nil
                    }
                    return makeIncarnation(
                        runID: runID, conversationID: conversationID,
                        eventID: eventID, sequence: sequence,
                        source: .activation, activationKind: kind,
                        activationProof: proof, startedAt: startedAt)
                }
                return makeIncarnation(
                    runID: runID, conversationID: conversationID,
                    eventID: eventID, sequence: sequence,
                    source: .launchStatus, activationKind: nil,
                    activationProof: nil, startedAt: startedAt)
            }
            if rows.count < 64 { return nil }
            before = rows.last?["sequence"]
        }
    }

    static func makeIncarnation(runID: UUID, conversationID: UUID,
                                eventID: UUID, sequence: Int,
                                source: RunIncarnation.Source,
                                activationKind: String?,
                                activationProof: String?,
                                startedAt: String) -> RunIncarnation {
        var basis = "floe.run.incarnation.v1"
            + "|" + runID.uuidString
            + "|" + conversationID.uuidString
            + "|" + eventID.uuidString
            + "|" + String(sequence)
            + "|" + startedAt
            + "|" + source.rawValue
        if let activationKind, let activationProof {
            basis += "|" + activationKind + "|" + activationProof
        }
        return RunIncarnation(
            runID: runID, conversationID: conversationID,
            eventID: eventID, sequence: sequence, source: source,
            proof: FloeDigest.sha256Hex(Data(basis.utf8)),
            activationKind: activationKind)
    }

    /// Newest status row carrying a `floeStopSettlement` object. Only the
    /// newest candidate decides: a malformed newest row is invalid, never
    /// bypassed for an older valid row.
    static func latestSettlement(db: Database, runID: UUID,
                                 conversationID: UUID) throws
        -> SettlementRead {
        var before: Int?
        while true {
            let rows: [Row]
            if let before {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, sequence, payload_json FROM run_events
                    WHERE run_id = ? AND kind = 'status' AND sequence < ?
                    ORDER BY sequence DESC LIMIT 64
                    """, arguments: [runID.uuidString, before])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, sequence, payload_json FROM run_events
                    WHERE run_id = ? AND kind = 'status'
                    ORDER BY sequence DESC LIMIT 64
                    """, arguments: [runID.uuidString])
            }
            if rows.isEmpty { return .none }
            for row in rows {
                let payload: String = row["payload_json"]
                guard let object = jsonObject(payload) else { return .invalid }
                guard object["floeStopSettlement"] != nil else { continue }
                guard let eventID = UUID(uuidString: row["id"]),
                      let settlement = parseSettlement(
                        object: object, eventID: eventID,
                        sequence: row["sequence"], runID: runID,
                        conversationID: conversationID) else {
                    return .invalid
                }
                return .valid(settlement, sequence: settlement.sequence,
                              eventID: settlement.eventID)
            }
            if rows.count < 64 { return .none }
            before = rows.last?["sequence"]
        }
    }

    static func latestSettlementSequence(db: Database, runID: UUID,
                                         conversationID: UUID) throws
        -> Int? {
        switch try latestSettlement(db: db, runID: runID,
                                    conversationID: conversationID) {
        case .valid(_, let sequence, _): return sequence
        case .none: return nil
        case .invalid:
            throw FloeError.storageCorrupted("Invalid run stop settlement")
        }
    }

    static func parseSettlement(object: [String: Any], eventID: UUID,
                                sequence: Int, runID: UUID,
                                conversationID: UUID) -> RunStopSettlement? {
        guard (object["state"] as? String) == "checkpointed",
              let raw = object["floeStopSettlement"] as? [String: Any],
              jsonInt(raw["version"]) == 1,
              let settlementIDRaw = raw["settlementID"] as? String,
              let settlementID = UUID(uuidString: settlementIDRaw),
              let runIDRaw = raw["runID"] as? String,
              let conversationIDRaw = raw["conversationID"] as? String,
              runIDRaw == runID.uuidString,
              conversationIDRaw == conversationID.uuidString,
              let pathRaw = raw["path"] as? String,
              let path = RunStopSettlement.Path(rawValue: pathRaw),
              let settledAt = raw["settledAt"] as? String,
              !settledAt.isEmpty, settledAt.utf8.count <= 64,
              let reasonKey = raw["reasonKey"] as? String,
              reasonKey == RunStopSettlementVocabulary.reasonKey,
              let expectedState = raw["expectedState"] as? String,
              !expectedState.isEmpty, expectedState.utf8.count <= 32,
              let incarnationRaw = raw["incarnation"] as? [String: Any],
              let incarnationProof = incarnationRaw["proof"] as? String,
              isHex64(incarnationProof),
              let incarnationSourceRaw = incarnationRaw["source"] as? String,
              let incarnationSource = RunIncarnation.Source(
                rawValue: incarnationSourceRaw),
              let incarnationEventRaw = incarnationRaw["eventID"] as? String,
              let incarnationEventID = UUID(uuidString: incarnationEventRaw),
              let incarnationSequence = jsonInt(incarnationRaw["sequence"]),
              incarnationSequence >= 0,
              let ownerAbsent = raw["ownerAbsent"] as? Bool,
              ownerAbsent,
              let digest = raw["settlementDigest"] as? String,
              isHex64(digest) else {
            return nil
        }
        let activationKind = incarnationRaw["activationKind"] as? String
        let incarnation = RunIncarnation(
            runID: runID, conversationID: conversationID,
            eventID: incarnationEventID, sequence: incarnationSequence,
            source: incarnationSource, proof: incarnationProof,
            activationKind: activationKind)
        let computed = digestFor(
            settlementID: settlementID, runID: runID,
            conversationID: conversationID, path: path,
            settledAt: settledAt, reasonKey: reasonKey,
            expectedState: expectedState, incarnation: incarnation,
            ownerAbsent: ownerAbsent)
        guard computed == digest else { return nil }
        return RunStopSettlement(
            eventID: eventID, sequence: sequence,
            settlementID: settlementID, runID: runID,
            conversationID: conversationID, path: path,
            settledAt: settledAt, reasonKey: reasonKey,
            expectedState: expectedState, incarnation: incarnation,
            ownerAbsent: ownerAbsent, settlementDigest: digest)
    }

    static func digestFor(settlementID: UUID, runID: UUID,
                          conversationID: UUID,
                          path: RunStopSettlement.Path,
                          settledAt: String, reasonKey: String,
                          expectedState: String,
                          incarnation: RunIncarnation,
                          ownerAbsent: Bool) -> String {
        let basis = [
            "floe.run.stop-settlement.v1",
            settlementID.uuidString,
            runID.uuidString,
            conversationID.uuidString,
            path.rawValue,
            settledAt,
            reasonKey,
            expectedState,
            incarnation.proof,
            incarnation.source.rawValue,
            incarnation.eventID.uuidString,
            String(incarnation.sequence),
            ownerAbsent ? "1" : "0",
        ].joined(separator: "|")
        return FloeDigest.sha256Hex(Data(basis.utf8))
    }

    static func appendSettlement(db: Database, runID: UUID,
                                 conversationID: UUID,
                                 path: RunStopSettlement.Path,
                                 expectedState: String,
                                 incarnation: RunIncarnation,
                                 ownerAbsent: Bool) throws
        -> RunStopSettlement {
        let settlementID = UUID()
        let settledAt = PersistenceCodec.encode(Date())
        let digest = digestFor(
            settlementID: settlementID, runID: runID,
            conversationID: conversationID, path: path,
            settledAt: settledAt,
            reasonKey: RunStopSettlementVocabulary.reasonKey,
            expectedState: expectedState, incarnation: incarnation,
            ownerAbsent: ownerAbsent)
        var incarnationObject: [String: Any] = [
            "eventID": incarnation.eventID.uuidString,
            "sequence": incarnation.sequence,
            "source": incarnation.source.rawValue,
            "proof": incarnation.proof,
        ]
        if let activationKind = incarnation.activationKind {
            incarnationObject["activationKind"] = activationKind
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "state": "checkpointed",
            "reason": RunStopSettlementVocabulary.reasonKey,
            "floeActivation": [
                "version": 1,
                "kind": RunStopSettlementVocabulary.activationKind,
            ],
            "floeStopSettlement": [
                "version": 1,
                "settlementID": settlementID.uuidString,
                "runID": runID.uuidString,
                "conversationID": conversationID.uuidString,
                "path": path.rawValue,
                "settledAt": settledAt,
                "reasonKey": RunStopSettlementVocabulary.reasonKey,
                "expectedState": expectedState,
                "incarnation": incarnationObject,
                "ownerAbsent": ownerAbsent,
                "settlementDigest": digest,
            ],
        ], options: [.sortedKeys])
        let event = try appendStatus(
            db: db, runID: runID,
            payload: String(decoding: payload, as: UTF8.self))
        return RunStopSettlement(
            eventID: event.eventID, sequence: event.sequence,
            settlementID: settlementID, runID: runID,
            conversationID: conversationID, path: path,
            settledAt: settledAt,
            reasonKey: RunStopSettlementVocabulary.reasonKey,
            expectedState: expectedState, incarnation: incarnation,
            ownerAbsent: ownerAbsent, settlementDigest: digest)
    }

    static func appendStatus(db: Database, runID: UUID,
                             payload: String) throws
        -> (eventID: UUID, sequence: Int) {
        let sequence = try Int.fetchOne(
            db,
            sql: """
                SELECT COALESCE(MAX(sequence), 0) + 1
                FROM run_events WHERE run_id = ?
                """,
            arguments: [runID.uuidString]) ?? 1
        let eventID = UUID()
        try db.execute(
            sql: """
                INSERT INTO run_events
                    (id, run_id, sequence, kind, payload_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                eventID.uuidString, runID.uuidString, sequence,
                RunEventRecord.Kind.status.rawValue, payload,
                PersistenceCodec.encode(Date()),
            ])
        return (eventID, sequence)
    }

    static func currentSettlement(db: Database, runID: UUID,
                                  conversationID: UUID,
                                  current: RunIncarnation?) throws
        -> RunStopSettlement? {
        guard let current else { return nil }
        switch try latestSettlement(db: db, runID: runID,
                                    conversationID: conversationID) {
        case .valid(let settlement, _, _):
            return settlement.incarnation.proof == current.proof
                ? settlement : nil
        case .none, .invalid:
            return nil
        }
    }

}
