// SPDX-License-Identifier: MPL-2.0
//
// RB-6 CAP-SECRET-2 repair — per-server secret lifetime over the ACCEPTED
// model physical-observation API (private reviewed source; host-qualified by
// the capabilities qualifier, NOT a native/product claim).
//
// Main findings repaired here (MAIN_SOURCE_REVIEW_20261019.json):
// * The destructive delete is now performed ONLY while the caller holds the
//   server's shared `.save`/`.delete`/`.cleanup` operation reservation
//   (`ProviderOperationCoordinatorRegistry` → the SAME accepted
//   `ProviderOperationOwning` seam the model domain uses), and only AFTER the
//   NEWEST persisted row/version has been re-read through that held owner.
//   A newer same-account Set therefore cannot be destroyed by a stale
//   cleanup intent (and a concurrent save/remove/drain cannot interleave).
// * An unsettled individual physical lifetime (claimed/queued receipt, or an
//   observing gateway whose queue-accept receipt never arrived) PARKS the
//   exact ticket + retained RB1 owned-work lease + receipt + THE EXACT
//   ORIGINAL WITNESS. Reconciliation reads only that witness — never the
//   current registry — so a removed/re-pointed gateway can never change the
//   truth of an old operation. A missing witness stays honest `notRecorded`
//   (unobserved), never settlement.
// * A pre-ticket `invalidValue`/`invalidReference` rejection (or an observed
//   never-queued attempt) is NOT authoritative proof that the OLD secret is
//   absent. The durable intent is preserved and reported as pending; only an
//   actual committed delete finalizes it.
// * A corrupt durable cleanup ledger is UNKNOWN, not empty: it is preserved,
//   reported as pending, and no destructive effect is attempted until it is
//   repaired.
//
// Namespace/reference identity is untouched: `org.floeagent.ios.mcp` +
// `mcp.<uuid>.<scheme>.<host>.<port>` through the one canonical
// `SecretGatewayNaming.opaqueReference(namespace:account:)` function, and the
// durable ledger keeps the existing one fixed app_settings key
// (`floe.mcp.secretCleanup.v1`, same table, no second database).
import Foundation
import GRDB
import FloeCore
import FloePersistence

// MARK: - Durable cleanup ledger (ONE fixed key; atomic writer RMW)

/// Strict codec + ATOMIC read-modify-write for the MCP cleanup intents.
///
/// The intents live under ONE fixed app_settings key, but operation ownership
/// is PER SERVER: different servers may enqueue/remove concurrently. Every
/// mutation therefore reads (strict decode), dedupes/capacity-checks, edits
/// and writes INSIDE ONE `DatabaseManager.writer` transaction, so a
/// concurrent cross-server enqueue/remove can never overwrite another
/// intent. `absent` and `valid` are distinct from `corrupt`: bytes that
/// exist but cannot be decoded (or exceed the declared bound) are NEVER
/// treated as an empty queue and are preserved untouched.
enum MCPSecretCleanupLedger {
    /// Declared bounded ledger size (unchanged from the parent).
    static let maximumEntries = 256
    /// Bounded decode: 256 intents of ~200 bytes fit well under 128 KiB;
    /// larger bytes are corrupt, never truncated.
    static let maximumLedgerJSONBytes = 131_072

    enum State: Sendable, Equatable {
        case absent
        case entries([MCPSecretCleanupIntent])
        case corrupt
    }

    private static func readRaw(_ db: Database) throws -> String? {
        try String.fetchOne(db,
                            sql: "SELECT value_json FROM app_settings WHERE key = ?",
                            arguments: [MCPDomain.cleanupSettingsKey])
    }

    static func decode(_ raw: String?) -> State {
        guard let raw else { return .absent }
        guard raw.utf8.count <= maximumLedgerJSONBytes,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MCPSecretCleanupIntent].self,
                                                      from: data),
              decoded.count <= maximumEntries else {
            return .corrupt
        }
        return .entries(decoded)
    }

    static func state(_ database: DatabaseManager) async throws -> State {
        try await database.reader { db in decode(try readRaw(db)) }
    }

    /// Read for decision paths: absent == genuinely empty; corrupt is a
    /// typed refusal (never `[]`).
    static func readStrict(_ database: DatabaseManager) async throws
        -> [MCPSecretCleanupIntent]
    {
        switch try await state(database) {
        case .absent: return []
        case .entries(let intents): return intents
        case .corrupt:
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "cleanupLedgerCorrupt")
        }
    }

    private static func write(_ intents: [MCPSecretCleanupIntent],
                              in db: Database) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(intents)
        guard data.count <= maximumLedgerJSONBytes else {
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "cleanupLedgerSaturated")
        }
        try db.execute(
            sql: """
                INSERT INTO app_settings (key, value_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_json = excluded.value_json,
                    updated_at = excluded.updated_at
                """,
            arguments: [MCPDomain.cleanupSettingsKey,
                        String(decoding: data, as: UTF8.self),
                        timestamp(Date())])
    }

    private static func strict(_ state: State) throws -> [MCPSecretCleanupIntent] {
        switch state {
        case .absent: return []
        case .entries(let intents): return intents
        case .corrupt:
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "cleanupLedgerCorrupt")
        }
    }

    /// Enqueue BEFORE the destructive effect. Idempotent for an EXISTING
    /// intent even at full capacity (checked before the bound); a NEW intent
    /// is refused pre-effect when the ledger is full; a corrupt ledger
    /// refuses without overwriting the unknown bytes.
    static func enqueue(_ intent: MCPSecretCleanupIntent,
                        in database: DatabaseManager) async throws {
        try await database.writer { db in
            var intents = try strict(decode(try readRaw(db)))
            if intents.contains(intent) { return }
            guard intents.count < maximumEntries else {
                throw ConfigDomainError(code: .mailboxSaturated,
                                        reason: "cleanupLedgerFull")
            }
            intents.append(intent)
            try write(intents, in: db)
        }
    }

    /// Compare-and-delete finalization of ONE exact intent, atomically.
    static func remove(serverID: UUID, account: String,
                       in database: DatabaseManager) async throws {
        try await database.writer { db in
            var intents = try strict(decode(try readRaw(db)))
            let before = intents.count
            intents.removeAll { $0.serverID == serverID && $0.account == account }
            guard intents.count != before else { return }
            try write(intents, in: db)
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Per-attempt physical observation (write/delete)

/// Receipt capture at queue-accept (fires OUTSIDE the mailbox lock exactly
/// once; metadata only, never bytes).
final class MCPReceiptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PhysicalOperationReceipt?

    func set(_ receipt: PhysicalOperationReceipt) {
        lock.lock()
        if value == nil { value = receipt }
        lock.unlock()
    }

    var receipt: PhysicalOperationReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// ONE observed/unobserved secret attempt with the ACCEPTED per-operation
/// classification. The witness is resolved per attempt (a registry re-pointed
/// mid-lifetime degrades THIS attempt to the conservative path; it never
/// converts a stale capability bit into an observation claim).
struct MCPPhysicalSecretAttempt: Sendable {
    let assessment: SecretEffectAssessment
    let witness: (any PhysicalObservingSecretGateway)?

    var receipt: PhysicalOperationReceipt? { assessment.receipt }
    var requiresOwnerRetention: Bool { assessment.requiresOwnerRetention }

    static func perform(kind: PhysicalOperationKind,
                        reference: String,
                        value: Data?,
                        gateway: any SecretGatewayServicing) async
        -> MCPPhysicalSecretAttempt
    {
        let observed = PhysicalObservationResolver.observer(for: gateway)
        let capture = MCPReceiptCapture()
        do {
            if let observed {
                switch kind {
                case .write:
                    try await observed.writeObserved(reference: reference,
                                                     value: value ?? Data()) { receipt in
                        capture.set(receipt)
                    }
                case .delete:
                    try await observed.deleteObserved(reference: reference) { receipt in
                        capture.set(receipt)
                    }
                case .read:
                    _ = try await observed.readObserved(reference: reference) { receipt in
                        capture.set(receipt)
                    }
                }
                // Success IS the authoritative completion channel (the caller
                // continuation only resumes from the mailbox complete()).
                var settlement: PhysicalSettlement = .executionSettled(
                    status: kind == .write ? 3 : (kind == .delete ? 4 : 1))
                if let receipt = capture.receipt {
                    let snapshot = observed.physicalSnapshot(claim: receipt.claim)
                    if case .settled(let status) = snapshot {
                        settlement = .executionSettled(status: status)
                    }
                    _ = observed.resolvePhysical(claim: receipt.claim)
                } else {
                    settlement = .unobserved
                }
                return MCPPhysicalSecretAttempt(
                    assessment: SecretEffectAssessment(disposition: .committed,
                                                       settlement: settlement,
                                                       receipt: capture.receipt),
                    witness: observed)
            }
            switch kind {
            case .write:
                try await gateway.write(reference: reference, value: value ?? Data())
            case .delete:
                try await gateway.delete(reference: reference)
            case .read:
                _ = try await gateway.read(reference: reference)
            }
            return MCPPhysicalSecretAttempt(
                assessment: SecretEffectAssessment(
                    disposition: .committed,
                    settlement: .executionSettled(
                        status: kind == .write ? 3 : (kind == .delete ? 4 : 1)),
                    receipt: nil),
                witness: nil)
        } catch {
            let snapshot: PhysicalOperationSnapshot
            if let receipt = capture.receipt, let observed {
                snapshot = observed.physicalSnapshot(claim: receipt.claim)
            } else {
                snapshot = .notRecorded
            }
            return MCPPhysicalSecretAttempt(
                assessment: SecretPhysicalAssessor.assess(
                    error: error,
                    receipt: capture.receipt,
                    snapshot: snapshot,
                    supportsObservation: observed != nil),
                witness: observed)
        }
    }
}

// MARK: - Reconciliation outcome

public enum MCPPendingReconciliationOutcome: Sendable, Equatable {
    case nothingPending
    case settledNow(reason: String)
    case stillPending(reason: String)
}

// MARK: - MCP-scoped operation-owner namespace

/// The accepted `ProviderOperationCoordinator` TYPE, in a SEPARATE registry
/// keyed by the ACTUAL `DatabaseManager` instance. Model-provider UUIDs and
/// MCP server UUIDs are independent resource identities and MAY be equal
/// (imports/fixtures); sharing one coordinator slot would let one resource
/// block or reconcile the other's pending owner. All MCP facades over one
/// database resolve the SAME MCP coordinator; entries are pruned by their
/// weak database reference, so a dead context leaves no tombstone.
public final class MCPOperationCoordinatorRegistry: @unchecked Sendable {
    public static let shared = MCPOperationCoordinatorRegistry()

    private final class Entry {
        weak var database: DatabaseManager?
        let coordinator: ProviderOperationCoordinator
        init(database: DatabaseManager, coordinator: ProviderOperationCoordinator) {
            self.database = database
            self.coordinator = coordinator
        }
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    public func coordinator(for database: DatabaseManager) -> ProviderOperationCoordinator {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(database)
        if let entry = entries[key], entry.database === database {
            return entry.coordinator
        }
        if entries[key] != nil {
            // Recycled address of a dead context: drop it and any other dead
            // entries opportunistically (bounded, weak-keyed).
            entries[key] = nil
            for (staleKey, stale) in entries where stale.database == nil {
                entries.removeValue(forKey: staleKey)
            }
        }
        let coordinator = ProviderOperationCoordinator()
        entries[key] = Entry(database: database, coordinator: coordinator)
        return coordinator
    }

    internal func removeAllForTesting() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
