// SPDX-License-Identifier: MPL-2.0
//
// Durable request identity journal for the Mac self-owned runtime.
//
// This is a primitive, not an entry point. It deliberately has no
// `DatabaseManager`, no actor, no writer and no production call site. Every
// function operates synchronously on a `Database` supplied by the caller, so
// the caller's own GRDB write transaction owns commit and rollback.
//
// PURPOSE
//
// `FloeMacConversation` requires a success receipt to carry the caller's
// `requestID` and a real backend-owned `durableReceiptID`. The existing
// `FloeMacSelfAdmissionStore` only knows conversation/run/epoch, so it cannot
// honestly manufacture that receipt. This journal records one durable row per
// side-effectful request and assigns a stable `journalID` at commit. It is the
// reusable identity primitive a future adapter can map to `durableReceiptID`
// after the transaction commits. It does not itself return a success receipt.
//
// PHASES (stored)
//
//   accepted                the identity was committed; no dispatch intent
//                           was recorded by this primitive yet. This is a
//                           protocol fact, not proof that no provider call
//                           happened outside the protocol.
//   dispatchMayHaveStarted  the dispatch intent was committed. From here the
//                           provider call may have happened even when the
//                           journal has no event or run row. Never terminal.
//   terminalConfirmed       reserved for future request-bound proof; current
//                           reads reject these untrusted historical rows.
//   unknown                 the attempt ended or was recovered without a
//                           strict terminal proof, or is unresolved. It blocks
//                           every automatic re-execution of this request.
//
// The legacy dispatch entry point and terminal recording remain disabled.
// A separate internal start-only primitive can co-commit the admission CAS and
// request row, but cannot prove the request's exact prepared input, host
// authorization or task/workspace ownership. Existing terminalConfirmed rows
// are rejected. No caller may infer permission to dispatch or a proven request
// outcome from this primitive.
//
// IDEMPOTENCY
//
// `requestID` is the primary key and the only idempotency key. Reusing it with
// the same protocol version, operation, principal, task/workspace/conversation/
// run/generation and payload fingerprint returns the already-recorded row. Any
// difference is an explicit conflict. A retry never creates a second row and
// never re-executes the operation.
//
// TRANSACTION CONTRACT
//
// All mutating functions require `db.isInsideTransaction == true` and fail
// closed otherwise. That check is necessary but not sufficient: it proves the
// caller's connection is in a transaction, not that the same transaction
// already wrote the admission row or prepared the run. The journal further
// checks the exact admission row through the *same* `Database` connection for
// acceptance. The internal start-only primitive performs admission and
// journal CAS operations on this connection inside the caller's transaction.
// The current `FloeMacSelfAdmissionStore` still opens its own writer per phase,
// and no production path uses this primitive. Do not claim three-way atomicity
// between admission, journal and `SQLiteRunLaunchStore.prepare`: prepare is
// still a separate transaction and must be reconciled by exact identity and
// durable state.
//
// AUTHORIZATION, UNIQUENESS, PRIVACY
//
// - Authorization remains with the host admission/approval path. This journal
//   has no authorization parameter and no way to authenticate a caller. A
//   journal row is not an authorization token and must never be exposed to
//   model/tool/UI content as permission to execute.
// - Uniqueness is per SQLite file only. A different database, installation or
//   device can reuse the same UUID. Cross-device deduplication remains the
//   responsibility of the trusted transport and the execution head/epoch.
// - No payload, goal, reason, credential, provider body or tool output is
//   stored. Only a bounded fingerprint and byte count are persisted. The
//   fingerprint is a SHA-256 digest, not encryption: a low-entropy payload can
//   be guessed or confirmed offline. It is not privacy protection and must not
//   be published or treated as anonymized content.
//
// INTEGRATION STATUS
//
// `productionWiringAvailable` is false. This type is intentionally internal;
// it is not installed by `FloeMacSelfRuntime.bootstrap`, not called by the
// session/runtime, and not connected to FloeMacConversation, the Mac App, the
// Keychain, any provider, network or user database. The production authority
// gate in `FloeMacSelfAuthorityLock` remains closed. Wiring this primitive
// requires authenticated identity binding, owned authority and a new reviewed batch.

import Foundation
import GRDB
import FloeCore

// MARK: - Vocabulary

/// Side-effectful operations that may own a durable request identity.
///
/// Read-only list/page operations are deliberately excluded: they have no
/// durable side effect to reconcile and must not be recorded as dispatches.
/// The raw values mirror `FloeConversationOperation`; the future adapter maps
/// them explicitly so this package does not import the control package.
enum FloeMacSelfRequestJournalOperation: String, Sendable, Hashable, CaseIterable {
    case startRun = "run.start"
    case cancelRun = "run.cancel"
    case resolveApproval = "approval.resolve"
}

/// Trusted host provenance bound into the request fingerprint.
///
/// This is a record of identity, not a credential and not an authorization
/// decision. The journal cannot authenticate it; the host admission layer is
/// responsible for producing it from its own trusted process identity.
struct FloeMacSelfRequestJournalPrincipal: Sendable, Hashable {
    let hostInstanceID: UUID
    let processIdentifier: Int32

    init(hostInstanceID: UUID, processIdentifier: Int32) {
        self.hostInstanceID = hostInstanceID
        self.processIdentifier = processIdentifier
    }
}

/// Exact logical scope of one request. `runGeneration` is the durable
/// admission epoch for a start request and the expected run generation for
/// cancel/approval. A value below 1 is invalid.
struct FloeMacSelfRequestJournalScope: Sendable, Hashable {
    let taskID: UUID
    let workspaceID: UUID
    let conversationID: UUID
    let runID: UUID
    let runGeneration: Int
    let operation: FloeMacSelfRequestJournalOperation

    init(
        taskID: UUID,
        workspaceID: UUID,
        conversationID: UUID,
        runID: UUID,
        runGeneration: Int,
        operation: FloeMacSelfRequestJournalOperation
    ) {
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.runID = runID
        self.runGeneration = runGeneration
        self.operation = operation
    }
}

/// Bounded payload fingerprint. Only the digest and byte count are persisted;
/// the payload itself never reaches SQLite, logs or errors.
struct FloeMacSelfRequestJournalPayloadFingerprint: Sendable, Hashable {
    let hex: String
    let byteCount: Int

    fileprivate init(hex: String, byteCount: Int) {
        self.hex = hex
        self.byteCount = byteCount
    }
}

/// Persisted phase. The raw values are part of the durable schema; unknown
/// values fail closed rather than being treated as free.
enum FloeMacSelfRequestJournalPhase: String, Sendable, Hashable, CaseIterable {
    case accepted
    case dispatchMayHaveStarted
    case terminalConfirmed
    case unknown
}

/// Stable, bounded reason for an `unknown` row. The first reason is retained;
/// a later call never overwrites it with a different explanation.
enum FloeMacSelfRequestJournalUnknownReason: String, Sendable, Hashable, CaseIterable {
    /// The attempt/session ended without a strict durable terminal proof.
    case runtimeEndedWithoutProof = "runtime_ended_without_proof"
    /// Dispatch intent is durable but the provider/run outcome is unknown.
    case dispatchOutcomeUnknown = "dispatch_outcome_unknown"
    /// The host released process resources without confirming the terminal.
    case hostClosedUnconfirmed = "host_closed_unconfirmed"
    /// A recovered row needs explicit host reconciliation before any reuse.
    case recoveryReconciliationRequired = "recovery_reconciliation_required"
}

/// Explicit read model that keeps the four facts separate. `unknown` is never
/// collapsed into "not started", and `dispatchMayHaveStarted` is never shown as
/// a terminal outcome.
enum FloeMacSelfRequestJournalState: Sendable, Hashable {
    case accepted
    case dispatchMayHaveStarted
    case terminalConfirmed(
        outcome: FloeMacSelfTerminalOutcome,
        durableRunState: String,
        terminalEventSequence: Int?
    )
    case unknown(reason: FloeMacSelfRequestJournalUnknownReason)
}

/// Read-only projection of one durable journal row. No payload text,
/// credential or authorization token is present.
struct FloeMacSelfRequestJournalRecord: Sendable, Hashable {
    let requestID: UUID
    /// Stable identity assigned only when the row is inserted. This is the
    /// value a future adapter may map to `durableReceiptID`, and only after
    /// the caller's transaction committed.
    let journalID: UUID
    let protocolVersion: Int
    let scope: FloeMacSelfRequestJournalScope
    let principal: FloeMacSelfRequestJournalPrincipal
    let fingerprint: FloeMacSelfRequestJournalPayloadFingerprint
    let phase: FloeMacSelfRequestJournalPhase
    let acceptedAt: Date
    let updatedAt: Date
    let dispatchRecordedAt: Date?
    let terminalRecordedAt: Date?
    let terminalOutcome: FloeMacSelfTerminalOutcome?
    let terminalRunState: String?
    let terminalEventSequence: Int?
    let unknownReason: FloeMacSelfRequestJournalUnknownReason?

    var state: FloeMacSelfRequestJournalState {
        switch phase {
        case .accepted:
            return .accepted
        case .dispatchMayHaveStarted:
            return .dispatchMayHaveStarted
        case .terminalConfirmed:
            guard let terminalOutcome, let terminalRunState else {
                // A corrupted terminal row must not be promoted to success.
                return .unknown(reason: .recoveryReconciliationRequired)
            }
            return .terminalConfirmed(
                outcome: terminalOutcome,
                durableRunState: terminalRunState,
                terminalEventSequence: terminalEventSequence
            )
        case .unknown:
            return .unknown(reason: unknownReason ?? .recoveryReconciliationRequired)
        }
    }

    /// True only when the row was written after a strict durable probe passed.
    var isTerminalProven: Bool {
        phase == .terminalConfirmed
    }

    /// There is no automatic re-execution path for any phase. A retry with the
    /// same request ID replays this row; a new logical operation requires a new
    /// request ID and its own admission decision.
    var mayExecuteAgainAutomatically: Bool {
        false
    }
}

/// Result of `reserve`. `replayed` means the durable row already existed with
/// identical identity and payload; it never means the operation ran again.
struct FloeMacSelfRequestJournalReservation: Sendable, Hashable {
    enum Disposition: String, Sendable, Hashable {
        case recorded
        case replayed
    }

    let disposition: Disposition
    let record: FloeMacSelfRequestJournalRecord
}

/// This result is only an observation inside the current transaction. Even
/// successful return from its enclosing writer is insufficient: a caller can
/// roll back an intermediate savepoint while allowing the writer to succeed.
/// It is not dispatch authorization; never invoke a provider from the write
/// closure, and a replay never grants a second dispatch.
struct FloeMacSelfRequestJournalDispatchReservation: Sendable, Hashable {
    let recorded: Bool
    let record: FloeMacSelfRequestJournalRecord
}

/// Result of `recordTerminal`. `newlyConfirmed` is true only when this call
/// wrote the terminal facts; false means the exact terminal row was already
/// present and was replayed.
struct FloeMacSelfRequestJournalTerminalRecord: Sendable, Hashable {
    let newlyConfirmed: Bool
    let record: FloeMacSelfRequestJournalRecord
}

/// Result of `markUnknown`. The first unknown reason is retained.
struct FloeMacSelfRequestJournalUnknownRecord: Sendable, Hashable {
    let changed: Bool
    let record: FloeMacSelfRequestJournalRecord
}

/// Bounded, stable error codes. None of these carries payload text, a path, a
/// credential or a provider body.
enum FloeMacSelfRequestJournalError: Error, Sendable, Equatable {
    case notInsideTransaction
    case notImplemented(String)
    case invalidProtocolVersion(Int)
    case invalidScope(String)
    case invalidPrincipal(String)
    case payloadTooLarge(Int)
    case capacityExceeded(UUID)
    case missingRecord(UUID)
    case identityConflict(requestID: UUID, field: String)
    case missingAdmission(UUID)
    case admissionScopeMismatch(UUID)
    case admissionPhaseRefused(String)
    case unsupportedOperation(String)
    case illegalTransition(from: String, to: String)
    case terminalNotProven(String)
    case invalidQuery(String)
    case schemaUnsupported(String)
    case corrupted(String)
}

// MARK: - Primitive

enum FloeMacSelfRequestJournal {
    static let supportedProtocolVersion = 1
    static let schemaVersion = 1

    /// Matches the control protocol's maximum goal payload. The journal never
    /// stores these bytes; the bound only limits fingerprint work.
    static let maximumPayloadBytes = 1_048_576

    /// Hard per-conversation row bound. Rows are never pruned automatically:
    /// deleting a terminal row would destroy idempotency evidence. Reaching the
    /// bound makes new reservations fail closed until a reviewed retention
    /// policy exists.
    static let maximumRowsPerConversation = 512

    /// Bounded read page. A caller cannot dump an unbounded conversation
    /// history through this primitive.
    static let maximumRecordsPerQuery = 100

    /// False because authenticated ownership, bootstrap installation and a
    /// reviewed runtime call site are still missing. No public API flips it.
    static let productionWiringAvailable = false

    private static let tableName = "floe_mac_self_request_journal"
    private static let metadataTableName = "floe_mac_self_metadata"
    private static let metadataSchemaKey = "request_journal_schema_version"
    private static let metadataSchemaValue = "1"

    // MARK: Schema

    /// Installs the journal table in the caller's existing database. This is
    /// not called by `FloeMacSelfRuntime.bootstrap` in this batch; a future
    /// bootstrap change must add it to the migration/authority step and be
    /// reviewed together with the admission helper.
    // Schema is deliberately exact in this unshipped primitive: accepting a
    // merely column-compatible table can lose PK, UNIQUE or CHECK guarantees.
    // A real migration requires an explicit reviewed schema version.
    private static let metadataSchemaSQL = """
        CREATE TABLE floe_mac_self_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        )
        """
    private static let journalSchemaSQL = """
        CREATE TABLE floe_mac_self_request_journal (
            request_id TEXT PRIMARY KEY NOT NULL,
            journal_id TEXT NOT NULL UNIQUE,
            protocol_version INTEGER NOT NULL,
            operation TEXT NOT NULL,
            task_id TEXT NOT NULL,
            workspace_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            run_generation INTEGER NOT NULL,
            principal_host_id TEXT NOT NULL,
            principal_pid INTEGER NOT NULL,
            payload_fingerprint TEXT NOT NULL,
            payload_byte_count INTEGER NOT NULL,
            phase TEXT NOT NULL CHECK (
                phase IN ('accepted', 'dispatchMayHaveStarted', 'terminalConfirmed', 'unknown')
            ),
            accepted_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            dispatch_recorded_at REAL,
            terminal_recorded_at REAL,
            terminal_outcome TEXT,
            terminal_run_state TEXT,
            terminal_event_sequence INTEGER,
            unknown_reason TEXT
        )
        """
    private static let journalIndexSQL = """
        CREATE INDEX floe_mac_self_request_journal_conversation
        ON floe_mac_self_request_journal (conversation_id, phase)
        """

    private static func canonicalSchema(_ sql: String) -> [String] {
        // Compare tokens rather than deleting whitespace: e.g. the legal
        // SQLite type TEXTPRIMARYKEYNOTNULL must not compare equal to four
        // separate TEXT PRIMARY KEY NOT NULL tokens. The expected schema has
        // no quoted identifiers or comments; those remain distinct tokens and
        // are rejected. Preserve string literals, including escaped quotes.
        let characters = Array(sql)
        var tokens: [String] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "'" {
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == "'" {
                        index += 1
                        if index < characters.count && characters[index] == "'" {
                            index += 1
                            continue
                        }
                        break
                    }
                    index += 1
                }
                tokens.append(String(characters[start..<index]))
            } else if character.isLetter || character.isNumber || character == "_" {
                let start = index
                index += 1
                while index < characters.count {
                    let next = characters[index]
                    guard next.isLetter || next.isNumber || next == "_" else { break }
                    index += 1
                }
                tokens.append(String(characters[start..<index]))
            } else {
                tokens.append(String(character))
                index += 1
            }
        }
        return tokens
    }

    private static func schemaSQL(db: Database, type: String, name: String) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT sql FROM main.sqlite_schema WHERE type = ? AND name = ?",
            arguments: [type, name]
        )
    }

    static func installSchema(in db: Database) throws {
        guard db.isInsideTransaction else {
            throw FloeMacSelfRequestJournalError.notInsideTransaction
        }
        let metadataSQL = try schemaSQL(db: db, type: "table", name: metadataTableName)
        let existingJournalSQL = try schemaSQL(db: db, type: "table", name: tableName)
        let existingIndexSQL = try schemaSQL(db: db, type: "index", name: "\(tableName)_conversation")
        var version: String?
        if let metadataSQL {
            guard canonicalSchema(metadataSQL) == canonicalSchema(metadataSchemaSQL) else {
                throw FloeMacSelfRequestJournalError.schemaUnsupported("request_journal_metadata_schema")
            }
            version = try String.fetchOne(
                db,
                sql: "SELECT value FROM main.\(metadataTableName) WHERE key = ?",
                arguments: [metadataSchemaKey]
            )
            // Do this before *any* DDL, including for partial databases.
            if let version, version != metadataSchemaValue {
                throw FloeMacSelfRequestJournalError.schemaUnsupported("request_journal_version")
            }
        }
        // Reject main and temporary triggers before any write. A TEMP trigger
        // can target a main table and is not listed in main.sqlite_schema.
        let triggers = try Int.fetchOne(
            db,
            sql: """
                SELECT
                    (SELECT COUNT(*) FROM main.sqlite_schema WHERE type = 'trigger' AND tbl_name COLLATE NOCASE IN (?, ?)) +
                    (SELECT COUNT(*) FROM temp.sqlite_schema WHERE type = 'trigger' AND tbl_name COLLATE NOCASE IN (?, ?))
                """,
            arguments: [tableName, metadataTableName, tableName, metadataTableName]
        ) ?? 1
        guard triggers == 0 else {
            throw FloeMacSelfRequestJournalError.schemaUnsupported("request_journal_trigger")
        }
        if version == nil {
            // Never adopt an unversioned or partially-created table/index.
            guard existingJournalSQL == nil, existingIndexSQL == nil else {
                throw FloeMacSelfRequestJournalError.schemaUnsupported("request_journal_unversioned")
            }
            if metadataSQL == nil {
                try db.execute(sql: metadataSchemaSQL.replacingOccurrences(of: "CREATE TABLE ", with: "CREATE TABLE main."))
            }
            try db.execute(sql: journalSchemaSQL.replacingOccurrences(of: "CREATE TABLE ", with: "CREATE TABLE main."))
            try db.execute(sql: journalIndexSQL.replacingOccurrences(of: "CREATE INDEX ", with: "CREATE INDEX main."))
            try db.execute(
                sql: "INSERT INTO main.\(metadataTableName) (key, value) VALUES (?, ?)",
                arguments: [metadataSchemaKey, metadataSchemaValue]
            )
        } else {
            guard let existingJournalSQL, let existingIndexSQL,
                  canonicalSchema(existingJournalSQL) == canonicalSchema(journalSchemaSQL),
                  canonicalSchema(existingIndexSQL) == canonicalSchema(journalIndexSQL) else {
                throw FloeMacSelfRequestJournalError.schemaUnsupported("request_journal_schema")
            }
        }
    }

    // MARK: Writes

    /// Records one request identity or replays the exact recorded facts.
    ///
    /// The new-row path checks the exact admission row through this same
    /// `Database` connection. The replay path deliberately does not: the
    /// stored fact must remain readable after the admission row advanced or
    /// was replaced, otherwise a crash recovery could lose idempotency.
    static func reserve(
        db: Database,
        requestID: UUID,
        protocolVersion: Int = supportedProtocolVersion,
        scope: FloeMacSelfRequestJournalScope,
        principal: FloeMacSelfRequestJournalPrincipal,
        payload: Data
    ) throws -> FloeMacSelfRequestJournalReservation {
        guard db.isInsideTransaction else {
            throw FloeMacSelfRequestJournalError.notInsideTransaction
        }
        let fingerprint = try makeFingerprint(
            protocolVersion: protocolVersion,
            scope: scope,
            principal: principal,
            payload: payload
        )
        if let existing = try fetchRecord(db: db, requestID: requestID) {
            try assertSameIdentity(
                record: existing,
                protocolVersion: protocolVersion,
                scope: scope,
                principal: principal,
                fingerprint: fingerprint
            )
            return FloeMacSelfRequestJournalReservation(
                disposition: .replayed,
                record: existing
            )
        }
        try requireAdmissionForAcceptance(db: db, scope: scope)
        let rowCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM main.\(tableName) WHERE conversation_id = ?",
            arguments: [scope.conversationID.uuidString]
        ) ?? Int.max
        guard rowCount < maximumRowsPerConversation else {
            throw FloeMacSelfRequestJournalError.capacityExceeded(scope.conversationID)
        }
        let now = Date().timeIntervalSince1970
        let journalID = UUID()
        try db.execute(
            sql: """
                INSERT INTO main.\(tableName) (
                    request_id, journal_id, protocol_version, operation, task_id,
                    workspace_id, conversation_id, run_id, run_generation,
                    principal_host_id, principal_pid, payload_fingerprint,
                    payload_byte_count, phase, accepted_at, updated_at,
                    dispatch_recorded_at, terminal_recorded_at, terminal_outcome,
                    terminal_run_state, terminal_event_sequence, unknown_reason
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'accepted', ?, ?,
                          NULL, NULL, NULL, NULL, NULL, NULL)
                """,
            arguments: [
                requestID.uuidString,
                journalID.uuidString,
                protocolVersion,
                scope.operation.rawValue,
                scope.taskID.uuidString,
                scope.workspaceID.uuidString,
                scope.conversationID.uuidString,
                scope.runID.uuidString,
                scope.runGeneration,
                principal.hostInstanceID.uuidString,
                Int(principal.processIdentifier),
                fingerprint.hex,
                fingerprint.byteCount,
                now,
                now
            ]
        )
        guard db.changesCount == 1 else {
            throw FloeMacSelfRequestJournalError.corrupted("request_journal_insert")
        }
        guard let created = try fetchRecord(db: db, requestID: requestID) else {
            throw FloeMacSelfRequestJournalError.corrupted("request_journal_missing_after_insert")
        }
        return FloeMacSelfRequestJournalReservation(
            disposition: .recorded,
            record: created
        )
    }

    /// Disabled until a same-transaction admission CAS establishes exclusive
    /// authority for this exact request. A journal row is not execution authority.
    static func recordDispatchIntent(
        db: Database,
        requestID: UUID,
        protocolVersion: Int = supportedProtocolVersion,
        scope: FloeMacSelfRequestJournalScope,
        principal: FloeMacSelfRequestJournalPrincipal,
        fingerprint: FloeMacSelfRequestJournalPayloadFingerprint
    ) throws -> FloeMacSelfRequestJournalDispatchReservation {
        // There is no production admission CAS on this connection yet.
        // A row transition alone is not exclusive authority to call a provider.
        guard db.isInsideTransaction else {
            throw FloeMacSelfRequestJournalError.notInsideTransaction
        }
        throw FloeMacSelfRequestJournalError.notImplemented("atomic_admission_dispatch")
    }

    /// Atomically claims a prepared start admission and its exact request row.
    /// This does not authenticate the principal, establish workspace/task
    /// ownership, bind the prepared input, or grant permission to run. The
    /// caller must establish those separately before any future integration.
    /// Both return values describe only the current transaction. Even a
    /// successful enclosing writer return does not prove these writes survived
    /// an enclosing savepoint rollback. A future trusted integration needs a
    /// sole transaction owner, post-commit identity/phase proof under its
    /// authority, and a stop fence before dispatch. Never execute a provider
    /// inside the transaction. A replay must never trigger execution.
    ///
    /// An inner savepoint also protects against a caller catching an error and
    /// committing its surrounding transaction after only one CAS succeeded.
    static func commitStartDispatch(
        db: Database,
        requestID: UUID,
        protocolVersion: Int = supportedProtocolVersion,
        scope: FloeMacSelfRequestJournalScope,
        principal: FloeMacSelfRequestJournalPrincipal,
        fingerprint: FloeMacSelfRequestJournalPayloadFingerprint
    ) throws -> FloeMacSelfRequestJournalDispatchReservation {
        guard db.isInsideTransaction else {
            throw FloeMacSelfRequestJournalError.notInsideTransaction
        }
        try validate(protocolVersion: protocolVersion, scope: scope, principal: principal)
        guard scope.operation == .startRun else {
            throw FloeMacSelfRequestJournalError.unsupportedOperation(scope.operation.rawValue)
        }
        guard let existing = try fetchRecord(db: db, requestID: requestID) else {
            throw FloeMacSelfRequestJournalError.missingRecord(requestID)
        }
        try assertSameIdentity(record: existing, protocolVersion: protocolVersion,
                               scope: scope, principal: principal, fingerprint: fingerprint)
        if existing.phase == .dispatchMayHaveStarted {
            return FloeMacSelfRequestJournalDispatchReservation(recorded: false, record: existing)
        }
        guard existing.phase == .accepted else {
            throw FloeMacSelfRequestJournalError.illegalTransition(
                from: existing.phase.rawValue,
                to: FloeMacSelfRequestJournalPhase.dispatchMayHaveStarted.rawValue)
        }

        let savepoint = "floe_dispatch_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try db.execute(sql: "SAVEPOINT \(savepoint)")
        do {
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                UPDATE main.floe_mac_self_admission
                SET phase = 'starting', updated_at = ?
                WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                  AND owner_host_id = ? AND owner_pid = ?
                  AND phase = 'prepared' AND stop_requested_at IS NULL
                """, arguments: [now, scope.conversationID.uuidString, scope.runID.uuidString,
                                 scope.runGeneration, principal.hostInstanceID.uuidString,
                                 Int(principal.processIdentifier)])
            guard db.changesCount == 1 else {
                throw FloeMacSelfRequestJournalError.admissionPhaseRefused("dispatch_claim_refused")
            }
            try db.execute(sql: """
                UPDATE main.\(tableName)
                SET phase = 'dispatchMayHaveStarted', updated_at = ?, dispatch_recorded_at = ?
                WHERE request_id = ? AND phase = 'accepted'
                """, arguments: [now, now, requestID.uuidString])
            guard db.changesCount == 1,
                  let updated = try fetchRecord(db: db, requestID: requestID),
                  updated.journalID == existing.journalID,
                  updated.phase == .dispatchMayHaveStarted else {
                throw FloeMacSelfRequestJournalError.corrupted("request_journal_dispatch_transition")
            }
            try assertSameIdentity(record: updated, protocolVersion: protocolVersion,
                                   scope: scope, principal: principal, fingerprint: fingerprint)
            let admissionCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM main.floe_mac_self_admission
                WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                  AND owner_host_id = ? AND owner_pid = ?
                  AND phase = 'starting' AND stop_requested_at IS NULL
                """, arguments: [scope.conversationID.uuidString, scope.runID.uuidString,
                                 scope.runGeneration, principal.hostInstanceID.uuidString,
                                 Int(principal.processIdentifier)])
            guard admissionCount == 1 else {
                throw FloeMacSelfRequestJournalError.corrupted("request_journal_admission_after_dispatch")
            }
            try db.execute(sql: "RELEASE SAVEPOINT \(savepoint)")
            return FloeMacSelfRequestJournalDispatchReservation(recorded: true, record: updated)
        } catch {
            do {
                try db.execute(sql: "ROLLBACK TO SAVEPOINT \(savepoint)")
                try db.execute(sql: "RELEASE SAVEPOINT \(savepoint)")
            } catch {
                throw FloeMacSelfRequestJournalError.corrupted("request_journal_dispatch_rollback")
            }
            throw error
        }
    }

    /// Disabled until a durable request-to-input proof and operation-specific
    /// completion proofs exist. A run terminal alone is insufficient.
    static func recordTerminal(
        db: Database,
        requestID: UUID,
        protocolVersion: Int = supportedProtocolVersion,
        scope: FloeMacSelfRequestJournalScope,
        principal: FloeMacSelfRequestJournalPrincipal,
        fingerprint: FloeMacSelfRequestJournalPayloadFingerprint,
        expectedUserMessageID: UUID?
    ) throws -> FloeMacSelfRequestJournalTerminalRecord {
        // The journal does not yet bind the committed user message and
        // canonical request payload, and a run terminal cannot prove a cancel
        // or approval was performed. Do not manufacture operation completion.
        guard db.isInsideTransaction else {
            throw FloeMacSelfRequestJournalError.notInsideTransaction
        }
        throw FloeMacSelfRequestJournalError.notImplemented("request_terminal_binding")
    }

    /// Marks an unresolved attempt as unknown. This records no terminal claim;
    /// it blocks automatic re-execution and preserves the first reason.
    static func markUnknown(
        db: Database,
        requestID: UUID,
        protocolVersion: Int = supportedProtocolVersion,
        scope: FloeMacSelfRequestJournalScope,
        principal: FloeMacSelfRequestJournalPrincipal,
        fingerprint: FloeMacSelfRequestJournalPayloadFingerprint,
        reason: FloeMacSelfRequestJournalUnknownReason
    ) throws -> FloeMacSelfRequestJournalUnknownRecord {
        guard db.isInsideTransaction else {
            throw FloeMacSelfRequestJournalError.notInsideTransaction
        }
        try validate(protocolVersion: protocolVersion, scope: scope, principal: principal)
        guard let existing = try fetchRecord(db: db, requestID: requestID) else {
            throw FloeMacSelfRequestJournalError.missingRecord(requestID)
        }
        try assertSameIdentity(
            record: existing,
            protocolVersion: protocolVersion,
            scope: scope,
            principal: principal,
            fingerprint: fingerprint
        )
        switch existing.phase {
        case .terminalConfirmed:
            throw FloeMacSelfRequestJournalError.illegalTransition(
                from: existing.phase.rawValue,
                to: FloeMacSelfRequestJournalPhase.unknown.rawValue
            )
        case .unknown:
            // Retain the first reason; an unknown row is already unresolved.
            return FloeMacSelfRequestJournalUnknownRecord(
                changed: false,
                record: existing
            )
        case .accepted, .dispatchMayHaveStarted:
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                    UPDATE main.\(tableName)
                    SET phase = 'unknown', updated_at = ?, unknown_reason = ?
                    WHERE request_id = ?
                      AND phase IN ('accepted', 'dispatchMayHaveStarted')
                    """,
                arguments: [now, reason.rawValue, requestID.uuidString]
            )
            guard db.changesCount == 1,
                  let updated = try fetchRecord(db: db, requestID: requestID) else {
                throw FloeMacSelfRequestJournalError.corrupted(
                    "request_journal_unknown_transition"
                )
            }
            return FloeMacSelfRequestJournalUnknownRecord(
                changed: true,
                record: updated
            )
        }
    }

    // MARK: Reads

    static func record(
        db: Database,
        requestID: UUID
    ) throws -> FloeMacSelfRequestJournalRecord? {
        try fetchRecord(db: db, requestID: requestID)
    }

    static func records(
        db: Database,
        conversationID: UUID,
        limit: Int
    ) throws -> [FloeMacSelfRequestJournalRecord] {
        guard limit >= 1, limit <= maximumRecordsPerQuery else {
            throw FloeMacSelfRequestJournalError.invalidQuery("limit")
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM main.\(tableName)
                WHERE conversation_id = ?
                ORDER BY accepted_at DESC, request_id ASC
                LIMIT ?
                """,
            arguments: [conversationID.uuidString, limit]
        )
        return try rows.map(record(from:))
    }

    // MARK: Fingerprint

    /// The canonical field order is part of the fingerprint contract. Changing
    /// it requires a new protocol version; never reinterpret old bytes.
    static func makeFingerprint(
        protocolVersion: Int,
        scope: FloeMacSelfRequestJournalScope,
        principal: FloeMacSelfRequestJournalPrincipal,
        payload: Data
    ) throws -> FloeMacSelfRequestJournalPayloadFingerprint {
        try validate(
            protocolVersion: protocolVersion,
            scope: scope,
            principal: principal
        )
        guard payload.count <= maximumPayloadBytes else {
            throw FloeMacSelfRequestJournalError.payloadTooLarge(payload.count)
        }
        var writer = RequestJournalCanonicalWriter()
        writer.append("floe.mac.self.request-journal.v1")
        writer.append(protocolVersion)
        writer.append(scope.operation.rawValue)
        writer.append(scope.taskID)
        writer.append(scope.workspaceID)
        writer.append(scope.conversationID)
        writer.append(scope.runID)
        writer.append(scope.runGeneration)
        writer.append(principal.hostInstanceID)
        writer.append(principal.processIdentifier)
        writer.append(payload)
        return FloeMacSelfRequestJournalPayloadFingerprint(
            hex: FloeDigest.sha256Hex(writer.bytes),
            byteCount: payload.count
        )
    }

    // MARK: Helpers

    private static func validate(
        protocolVersion: Int,
        scope: FloeMacSelfRequestJournalScope,
        principal: FloeMacSelfRequestJournalPrincipal
    ) throws {
        guard protocolVersion == supportedProtocolVersion else {
            throw FloeMacSelfRequestJournalError.invalidProtocolVersion(protocolVersion)
        }
        guard scope.runGeneration >= 1 else {
            throw FloeMacSelfRequestJournalError.invalidScope("run_generation")
        }
        guard principal.processIdentifier > 0 else {
            throw FloeMacSelfRequestJournalError.invalidPrincipal("process_identifier")
        }
    }

    private static func assertSameIdentity(
        record: FloeMacSelfRequestJournalRecord,
        protocolVersion: Int,
        scope: FloeMacSelfRequestJournalScope,
        principal: FloeMacSelfRequestJournalPrincipal,
        fingerprint: FloeMacSelfRequestJournalPayloadFingerprint
    ) throws {
        let requestID = record.requestID
        if record.protocolVersion != protocolVersion {
            throw FloeMacSelfRequestJournalError.identityConflict(
                requestID: requestID,
                field: "protocol_version"
            )
        }
        if record.scope.operation != scope.operation {
            throw FloeMacSelfRequestJournalError.identityConflict(
                requestID: requestID,
                field: "operation"
            )
        }
        if record.scope.taskID != scope.taskID {
            throw FloeMacSelfRequestJournalError.identityConflict(
                requestID: requestID,
                field: "task_id"
            )
        }
        if record.scope.workspaceID != scope.workspaceID {
            throw FloeMacSelfRequestJournalError.identityConflict(
                requestID: requestID,
                field: "workspace_id"
            )
        }
        if record.scope.conversationID != scope.conversationID {
            throw FloeMacSelfRequestJournalError.identityConflict(
                requestID: requestID,
                field: "conversation_id"
            )
        }
        if record.scope.runID != scope.runID {
            throw FloeMacSelfRequestJournalError.identityConflict(
                requestID: requestID,
                field: "run_id"
            )
        }
        if record.scope.runGeneration != scope.runGeneration {
            throw FloeMacSelfRequestJournalError.identityConflict(
                requestID: requestID,
                field: "run_generation"
            )
        }
        if record.principal.hostInstanceID != principal.hostInstanceID {
            throw FloeMacSelfRequestJournalError.identityConflict(
                requestID: requestID,
                field: "principal_host_id"
            )
        }
        if record.principal.processIdentifier != principal.processIdentifier {
            throw FloeMacSelfRequestJournalError.identityConflict(
                requestID: requestID,
                field: "principal_pid"
            )
        }
        if record.fingerprint != fingerprint {
            throw FloeMacSelfRequestJournalError.identityConflict(
                requestID: requestID,
                field: "payload"
            )
        }
    }

    /// Acceptance cross-check. The admission row must have been written on
    /// this exact `Database` connection (same file and transaction object) and
    /// must name the exact run/generation. This still cannot prove the row was
    /// written in *this* transaction; only the future same-connection helper
    /// can establish that.
    private static func requireAdmissionForAcceptance(
        db: Database,
        scope: FloeMacSelfRequestJournalScope
    ) throws {
        let allowedPhases: Set<String>
        switch scope.operation {
        case .startRun, .cancelRun:
            allowedPhases = ["admitting", "prepared", "starting"]
        case .resolveApproval:
            allowedPhases = ["starting"]
        }
        let row = try fetchAdmissionRow(db: db, conversationID: scope.conversationID)
        guard let row else {
            throw FloeMacSelfRequestJournalError.missingAdmission(scope.conversationID)
        }
        guard row.runID == scope.runID.uuidString,
              row.epoch == scope.runGeneration else {
            throw FloeMacSelfRequestJournalError.admissionScopeMismatch(
                scope.conversationID
            )
        }
        guard allowedPhases.contains(row.phase) else {
            throw FloeMacSelfRequestJournalError.admissionPhaseRefused(row.phase)
        }
        if scope.operation != .cancelRun, row.stopRequestedAt != nil {
            // A start/approval accepted after a durable stop intent is stale.
            // A cancel request may itself be the reason the stop is durable.
            throw FloeMacSelfRequestJournalError.admissionPhaseRefused(
                "stop_requested"
            )
        }
    }

    /// Dispatch cross-check. The admission must already be prepared/starting
    /// for the exact run and epoch, with no stop intent. The future helper
    /// performs this CAS and the journal transition in one transaction.
    private static func requireAdmissionForDispatch(
        db: Database,
        scope: FloeMacSelfRequestJournalScope
    ) throws {
        guard scope.operation == .startRun else {
            throw FloeMacSelfRequestJournalError.unsupportedOperation(
                scope.operation.rawValue
            )
        }
        let row = try fetchAdmissionRow(db: db, conversationID: scope.conversationID)
        guard let row else {
            throw FloeMacSelfRequestJournalError.missingAdmission(scope.conversationID)
        }
        guard row.runID == scope.runID.uuidString,
              row.epoch == scope.runGeneration else {
            throw FloeMacSelfRequestJournalError.admissionScopeMismatch(
                scope.conversationID
            )
        }
        guard row.phase == "prepared" || row.phase == "starting" else {
            throw FloeMacSelfRequestJournalError.admissionPhaseRefused(row.phase)
        }
        guard row.stopRequestedAt == nil else {
            throw FloeMacSelfRequestJournalError.admissionPhaseRefused(
                "stop_requested"
            )
        }
    }

    private struct AdmissionRow {
        let runID: String
        let epoch: Int
        let phase: String
        let stopRequestedAt: Double?
    }

    private static func fetchAdmissionRow(
        db: Database,
        conversationID: UUID
    ) throws -> AdmissionRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT run_id, epoch, phase, stop_requested_at
                FROM main.floe_mac_self_admission
                WHERE conversation_id = ?
                """,
            arguments: [conversationID.uuidString]
        ) else {
            return nil
        }
        let rawEpoch = try requiredInt64(row, "epoch")
        guard rawEpoch >= 1, rawEpoch <= Int64(Int.max) else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_admission_fields"
            )
        }
        return AdmissionRow(
            runID: try requiredString(row, "run_id"),
            epoch: Int(rawEpoch),
            phase: try requiredString(row, "phase"),
            stopRequestedAt: try optionalDouble(
                row: row,
                "stop_requested_at"
            )
        )
    }

    private static func fetchRecord(
        db: Database,
        requestID: UUID
    ) throws -> FloeMacSelfRequestJournalRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM main.\(tableName) WHERE request_id = ?",
            arguments: [requestID.uuidString]
        ) else {
            return nil
        }
        return try record(from: row)
    }

    private static func record(
        from row: Row
    ) throws -> FloeMacSelfRequestJournalRecord {
        guard let requestID = UUID(uuidString: try requiredString(row, "request_id")),
              let journalID = UUID(uuidString: try requiredString(row, "journal_id")),
              let taskID = UUID(uuidString: try requiredString(row, "task_id")),
              let workspaceID = UUID(uuidString: try requiredString(row, "workspace_id")),
              let conversationID = UUID(uuidString: try requiredString(row, "conversation_id")),
              let runID = UUID(uuidString: try requiredString(row, "run_id")),
              let principalHostID = UUID(
                uuidString: try requiredString(row, "principal_host_id")
              ) else {
            throw FloeMacSelfRequestJournalError.corrupted("request_journal_uuid")
        }
        let rawProtocolVersion = try requiredInt64(row, "protocol_version")
        guard rawProtocolVersion == Int64(supportedProtocolVersion) else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_protocol"
            )
        }
        guard let operation = FloeMacSelfRequestJournalOperation(
            rawValue: try requiredString(row, "operation")
        ) else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_operation"
            )
        }
        let rawGeneration = try requiredInt64(row, "run_generation")
        guard rawGeneration >= 1, rawGeneration <= Int64(Int.max) else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_generation"
            )
        }
        let rawPID = try requiredInt64(row, "principal_pid")
        guard rawPID > 0, rawPID <= Int64(Int32.max) else {
            throw FloeMacSelfRequestJournalError.corrupted("request_journal_pid")
        }
        let fingerprintHex = try requiredString(row, "payload_fingerprint")
        guard isLowercaseHex(fingerprintHex) else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_fingerprint"
            )
        }
        let rawByteCount = try requiredInt64(row, "payload_byte_count")
        guard rawByteCount >= 0,
              rawByteCount <= Int64(maximumPayloadBytes) else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_payload_size"
            )
        }
        guard let phase = FloeMacSelfRequestJournalPhase(
            rawValue: try requiredString(row, "phase")
        ) else {
            throw FloeMacSelfRequestJournalError.corrupted("request_journal_phase")
        }
        let acceptedAt = Date(
            timeIntervalSince1970: try requiredDouble(row, "accepted_at")
        )
        let updatedAt = Date(
            timeIntervalSince1970: try requiredDouble(row, "updated_at")
        )
        let dispatchAt = try optionalDouble(row: row, "dispatch_recorded_at").map {
            Date(timeIntervalSince1970: $0)
        }
        let terminalAt = try optionalDouble(row: row, "terminal_recorded_at").map {
            Date(timeIntervalSince1970: $0)
        }
        let rawOutcome = try optionalString(row: row, "terminal_outcome")
        let terminalOutcome: FloeMacSelfTerminalOutcome?
        if let rawOutcome {
            guard let parsed = FloeMacSelfTerminalOutcome(rawValue: rawOutcome) else {
                throw FloeMacSelfRequestJournalError.corrupted(
                    "request_journal_terminal_outcome"
                )
            }
            terminalOutcome = parsed
        } else {
            terminalOutcome = nil
        }
        let terminalRunState = try optionalString(
            row: row,
            "terminal_run_state"
        )
        let rawTerminalSequence = try optionalInt64(
            row: row,
            "terminal_event_sequence"
        )
        let rawUnknownReason = try optionalString(row: row, "unknown_reason")
        let unknownReason: FloeMacSelfRequestJournalUnknownReason?
        if let rawUnknownReason {
            guard let parsed = FloeMacSelfRequestJournalUnknownReason(
                rawValue: rawUnknownReason
            ) else {
                throw FloeMacSelfRequestJournalError.corrupted(
                    "request_journal_unknown_reason"
                )
            }
            unknownReason = parsed
        } else {
            unknownReason = nil
        }

        switch phase {
        case .terminalConfirmed:
            // Existing terminal rows predate request-to-message proof; even a
            // well-shaped run result is not a proven request result.
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_terminal_unbound"
            )
        case .unknown:
            guard unknownReason != nil,
                  terminalOutcome == nil,
                  terminalRunState == nil,
                  terminalAt == nil,
                  rawTerminalSequence == nil else {
                throw FloeMacSelfRequestJournalError.corrupted(
                    "request_journal_unknown_fields"
                )
            }
        case .accepted:
            guard dispatchAt == nil,
                  terminalOutcome == nil,
                  terminalRunState == nil,
                  terminalAt == nil,
                  rawTerminalSequence == nil,
                  unknownReason == nil else {
                throw FloeMacSelfRequestJournalError.corrupted(
                    "request_journal_premature_terminal"
                )
            }
        case .dispatchMayHaveStarted:
            guard dispatchAt != nil,
                  terminalOutcome == nil,
                  terminalRunState == nil,
                  terminalAt == nil,
                  rawTerminalSequence == nil,
                  unknownReason == nil else {
                throw FloeMacSelfRequestJournalError.corrupted(
                    "request_journal_premature_terminal"
                )
            }
        }

        return FloeMacSelfRequestJournalRecord(
            requestID: requestID,
            journalID: journalID,
            protocolVersion: Int(rawProtocolVersion),
            scope: FloeMacSelfRequestJournalScope(
                taskID: taskID,
                workspaceID: workspaceID,
                conversationID: conversationID,
                runID: runID,
                runGeneration: Int(rawGeneration),
                operation: operation
            ),
            principal: FloeMacSelfRequestJournalPrincipal(
                hostInstanceID: principalHostID,
                processIdentifier: Int32(rawPID)
            ),
            fingerprint: FloeMacSelfRequestJournalPayloadFingerprint(
                hex: fingerprintHex,
                byteCount: Int(rawByteCount)
            ),
            phase: phase,
            acceptedAt: acceptedAt,
            updatedAt: updatedAt,
            dispatchRecordedAt: dispatchAt,
            terminalRecordedAt: terminalAt,
            terminalOutcome: terminalOutcome,
            terminalRunState: terminalRunState,
            terminalEventSequence: rawTerminalSequence.map(Int.init),
            unknownReason: unknownReason
        )
    }

    private static func databaseValue(
        _ row: Row,
        _ column: String
    ) throws -> DatabaseValue? {
        guard row.hasColumn(column) else { return nil }
        let value: DatabaseValue = row[column]
        return value.isNull ? nil : value
    }

    private static func requiredString(_ row: Row, _ column: String) throws -> String {
        guard let raw = try databaseValue(row, column),
              let value = String.fromDatabaseValue(raw) else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_column:\(column)"
            )
        }
        return value
    }

    private static func requiredInt64(_ row: Row, _ column: String) throws -> Int64 {
        guard let raw = try databaseValue(row, column),
              let value = Int64.fromDatabaseValue(raw) else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_column:\(column)"
            )
        }
        return value
    }

    private static func requiredDouble(_ row: Row, _ column: String) throws -> Double {
        guard let raw = try databaseValue(row, column),
              let value = Double.fromDatabaseValue(raw),
              value.isFinite else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_column:\(column)"
            )
        }
        return value
    }

    private static func optionalString(
        row: Row,
        _ column: String
    ) throws -> String? {
        guard let raw = try databaseValue(row, column) else { return nil }
        guard let value = String.fromDatabaseValue(raw) else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_column:\(column)"
            )
        }
        return value
    }

    private static func optionalInt64(
        row: Row,
        _ column: String
    ) throws -> Int64? {
        guard let raw = try databaseValue(row, column) else { return nil }
        guard let value = Int64.fromDatabaseValue(raw) else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_column:\(column)"
            )
        }
        return value
    }

    private static func optionalDouble(
        row: Row,
        _ column: String
    ) throws -> Double? {
        guard let raw = try databaseValue(row, column) else { return nil }
        guard let value = Double.fromDatabaseValue(raw),
              value.isFinite else {
            throw FloeMacSelfRequestJournalError.corrupted(
                "request_journal_column:\(column)"
            )
        }
        return value
    }

    private static func isLowercaseHex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

// MARK: - Canonical encoding

/// Length-prefixed, field-ordered encoding for the payload fingerprint. This
/// is not a serialization format and is never persisted; it only prevents
/// ambiguous concatenation of variable-length identity fields.
private struct RequestJournalCanonicalWriter {
    private(set) var bytes = Data()

    mutating func append(_ value: String) {
        appendField(Data(value.utf8))
    }

    mutating func append(_ value: Int) {
        appendField(Data(String(value).utf8))
    }

    mutating func append(_ value: Int32) {
        appendField(Data(String(value).utf8))
    }

    mutating func append(_ value: UUID) {
        appendField(Data(value.uuidString.lowercased().utf8))
    }

    mutating func append(_ value: Data) {
        appendField(value)
    }

    private mutating func appendField(_ field: Data) {
        bytes.append(Data(String(field.count).utf8))
        bytes.append(0x3A) // ':'
        bytes.append(field)
    }
}
