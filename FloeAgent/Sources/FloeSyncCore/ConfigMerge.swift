// FloeSyncCore — Cross-platform sync merge logic.
// Pure functions only; CloudKit specifics live in the iOS-only FloeSync
// target. Conflict resolution: per-field `updatedAt` last-writer-wins with
// tombstone (`deletedAt`) dominating non-deleted fields.

import Foundation
import FloeCore

/// A syncable record's per-field timestamps. Every mutable field carries
/// the wall-clock time of its last local or remote modification.
public struct FieldTimestamps: Sendable, Codable, Hashable {
    /// field name → last modification time (UTC).
    public var fields: [String: Date]

    public init(fields: [String: Date] = [:]) {
        self.fields = fields
    }

    public func timestamp(for field: String) -> Date? {
        fields[field]
    }
}

/// Outcome of merging one field.
public enum FieldMergeDecision: Sendable, Hashable {
    /// Local value wins (local is newer or timestamps tie).
    case keepLocal
    /// Remote value wins (remote is newer).
    case adoptRemote
    /// Both sides equal — no change needed.
    case identical
}

/// Pure per-field last-writer-wins merge.
public enum ConfigMerge {

    /// Decides one field. Ties resolve to local (deterministic).
    public static func decide(
        field: String,
        local: FieldTimestamps,
        remote: FieldTimestamps
    ) -> FieldMergeDecision {
        let localDate = local.timestamp(for: field)
        let remoteDate = remote.timestamp(for: field)
        switch (localDate, remoteDate) {
        case (.none, .none):
            return .identical
        case (.some, .none):
            return .keepLocal
        case (.none, .some):
            return .adoptRemote
        case (.some(let localDate), .some(let remoteDate)):
            if localDate == remoteDate { return .identical }
            return localDate > remoteDate ? .keepLocal : .adoptRemote
        }
    }

    /// Merges a string field.
    public static func merge(
        field: String,
        localValue: String,
        remoteValue: String,
        local: FieldTimestamps,
        remote: FieldTimestamps
    ) -> String {
        if localValue == remoteValue { return localValue }
        let localDate = local.timestamp(for: field)
        let remoteDate = remote.timestamp(for: field)
        switch (localDate, remoteDate) {
        case (.some(let l), .some(let r)) where r > l:
            return remoteValue
        case (.none, .some):
            return remoteValue
        default:
            return localValue
        }
    }

    /// Merges a boolean field.
    public static func merge(
        field: String,
        localValue: Bool,
        remoteValue: Bool,
        local: FieldTimestamps,
        remote: FieldTimestamps
    ) -> Bool {
        if localValue == remoteValue { return localValue }
        let localDate = local.timestamp(for: field)
        let remoteDate = remote.timestamp(for: field)
        switch (localDate, remoteDate) {
        case (.some(let l), .some(let r)) where r > l:
            return remoteValue
        case (.none, .some):
            return remoteValue
        default:
            return localValue
        }
    }

    /// Resolves a record-level conflict with tombstone dominance:
    /// a deleted record wins over a live one regardless of timestamps
    /// (deletion is a deliberate user act).
    public static func resolveRecord(
        localDeletedAt: Date?,
        remoteDeletedAt: Date?,
        localUpdatedAt: Date,
        remoteUpdatedAt: Date
    ) -> RecordResolution {
        switch (localDeletedAt, remoteDeletedAt) {
        case (.some, .some):
            return .bothDeleted
        case (.some(let deleted), .none):
            // Resurrect only when remote was modified after the deletion.
            return remoteUpdatedAt > deleted ? .keepRemote : .keepDeleted
        case (.none, .some(let deleted)):
            return localUpdatedAt > deleted ? .keepLocal : .keepDeleted
        case (.none, .none):
            return remoteUpdatedAt > localUpdatedAt ? .keepRemote : .keepLocal
        }
    }

    public enum RecordResolution: String, Sendable, Hashable {
        case keepLocal
        case keepRemote
        case keepDeleted
        case bothDeleted
    }
}
