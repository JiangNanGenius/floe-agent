import Foundation
import FloeCore

/// Provenance of one durable Shortcuts draft inbox entry.
///
/// Raw values are persisted in `shortcut_draft_inbox.source`; never rename them.
public enum ShortcutDraftInboxSource: String, Sendable, Codable, CaseIterable, Hashable {
    /// `SendToFloeIntent` (prompt + pasted text composed into one draft).
    case intentSend
    /// `CreateFloeTaskIntent` (task description).
    case intentCreate
    /// One-time migration of the legacy single-slot
    /// `UserDefaults("group.org.floeagent.ios").shortcuts.pendingDraft`.
    case legacyMigration
}

/// Durable delivery state of one inbox entry. There is deliberately no
/// time-based expiry: a `claimed` row stays claimed until its exact claim
/// token is acknowledged (durable destination verified) or released. A dead
/// claimant is detected by its process epoch, not by an arbitrary TTL that
/// could hand the same draft to a second destination.
public enum ShortcutDraftInboxState: String, Sendable, Codable, CaseIterable, Hashable {
    case pending
    case claimed
    /// Terminal tombstone kept ONLY for entries carrying a `migrationKey`.
    /// The legacy single-slot key lives in `UserDefaults`, whose removal is
    /// not crash-synchronous with the durable enqueue; retaining the row
    /// ensures a late retry of the SAME stable identity can never redeliver
    /// an already-consumed legacy draft.
    case delivered
}

/// One FIFO durable Shortcuts draft awaiting delivery to the canonical Home
/// composer. `id` is unique per accepted intent invocation; only entries
/// carrying an explicit `migrationKey` (the legacy single-slot migration)
/// dedupe, so consecutive submissions of identical text never overwrite one
/// another.
public struct ShortcutDraftInboxEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var source: ShortcutDraftInboxSource
    /// Stable migration identity. Non-nil only for the legacy single-slot
    /// draft, so a crash/retry between "durable enqueue" and "legacy key
    /// deletion" re-enqueues the SAME row instead of duplicating it.
    public var migrationKey: String?
    public var state: ShortcutDraftInboxState
    /// Opaque token minted by the store at claim time. Ack/release must
    /// present it; a stale token can never settle another handoff.
    public var claimToken: String?
    /// Process epoch of the claimant. Rows claimed by a different epoch were
    /// left by a dead process and are settled by destination inspection, not
    /// by a lease timeout.
    public var claimEpoch: String?
    /// Durable identity of the intended destination (the canonical Home
    /// launchpad draft slot), used for idempotent crash recovery.
    public var destinationID: String?
    public var createdAt: Date
    public var claimedAt: Date?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        source: ShortcutDraftInboxSource,
        migrationKey: String? = nil,
        state: ShortcutDraftInboxState = .pending,
        claimToken: String? = nil,
        claimEpoch: String? = nil,
        destinationID: String? = nil,
        createdAt: Date = Date(),
        claimedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.migrationKey = migrationKey
        self.state = state
        self.claimToken = claimToken
        self.claimEpoch = claimEpoch
        self.destinationID = destinationID
        self.createdAt = createdAt
        self.claimedAt = claimedAt
        self.updatedAt = updatedAt
    }
}

public extension ShortcutDraftInboxEntry {
    /// Deterministic identity for one migration source. One-way and not
    /// security-sensitive: the same legacy key always addresses the same
    /// inbox row across retries and processes.
    static func stableID(migrationKey: String) -> UUID {
        let hex = Array(FloeDigest.sha256Hex(
            Data("floe.shortcuts.inbox.migration:\(migrationKey)".utf8)
        ).prefix(32))
        guard hex.count == 32 else { return UUID() }
        let text = String(hex)
        let formatted = [
            text.prefix(8),
            text.dropFirst(8).prefix(4),
            text.dropFirst(12).prefix(4),
            text.dropFirst(16).prefix(4),
            text.dropFirst(20).prefix(12),
        ].joined(separator: "-")
        return UUID(uuidString: formatted) ?? UUID()
    }
}
