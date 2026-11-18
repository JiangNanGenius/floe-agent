import Foundation

/// Phantom tags keep product identities in separate Swift types while all of
/// them share the same canonical UUID wire form.
public protocol SyncIDTag: Sendable {}

public enum DeviceTag: SyncIDTag {}
public enum TaskTag: SyncIDTag {}
public enum RunTag: SyncIDTag {}
public enum WorkspaceTag: SyncIDTag {}
public enum CommandTag: SyncIDTag {}
public enum SnapshotTag: SyncIDTag {}
public enum EntityTag: SyncIDTag {}
public enum ChildRunTag: SyncIDTag {}
public enum CheckpointTag: SyncIDTag {}
public enum ScheduleTag: SyncIDTag {}
public enum OccurrenceTag: SyncIDTag {}
public enum ArtifactTag: SyncIDTag {}
public enum ConflictTag: SyncIDTag {}

/// A stable Floe identity. The canonical form is a lowercase hyphenated UUID.
///
/// The initializer deliberately rejects arbitrary strings: derivers that only
/// produced values from a local path (the existing same-machine Bridge did
/// this) must be registered through `LegacyBridgeIdentifier` instead. A path
/// derivative is device-local and must never become a cross-device identity.
public struct StableIdentifier<Tag: SyncIDTag>: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let canonical: String

    public init(validating value: String) throws {
        guard !value.contains(where: { $0.isWhitespace }),
              let uuid = UUID(uuidString: value) else {
            throw SyncStoreError.invalidIdentifier(value)
        }
        canonical = uuid.uuidString.lowercased()
    }

    public init(_ uuid: UUID) {
        canonical = uuid.uuidString.lowercased()
    }

    /// Generates a new random identity. This is convenience, not a claim that
    /// the identity came from the iPad's existing task store.
    public init() {
        self.init(UUID())
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.canonical < rhs.canonical
    }

    public var description: String { canonical }
}

public typealias DeviceID = StableIdentifier<DeviceTag>
public typealias TaskID = StableIdentifier<TaskTag>
public typealias RunID = StableIdentifier<RunTag>
public typealias WorkspaceID = StableIdentifier<WorkspaceTag>
public typealias CommandID = StableIdentifier<CommandTag>
public typealias SnapshotID = StableIdentifier<SnapshotTag>
public typealias EntityID = StableIdentifier<EntityTag>
public typealias ChildRunID = StableIdentifier<ChildRunTag>
public typealias CheckpointID = StableIdentifier<CheckpointTag>
public typealias ScheduleID = StableIdentifier<ScheduleTag>
public typealias OccurrenceID = StableIdentifier<OccurrenceTag>
public typealias ArtifactID = StableIdentifier<ArtifactTag>
public typealias ConflictID = StableIdentifier<ConflictTag>

/// A positive per-entity revision. Zero and negative revisions are rejected so
/// an empty row can never be mistaken for a real baseline.
public struct Revision: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws {
        guard rawValue > 0 else { throw SyncStoreError.invalidRevision(rawValue) }
        self.rawValue = rawValue
    }

    public init(decimalString: String) throws {
        guard let value = Int64(decimalString), value > 0 else {
            throw SyncStoreError.invalidRevisionString(decimalString)
        }
        rawValue = value
    }

    public var decimalString: String { String(rawValue) }
    public var description: String { decimalString }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Durable position in a store's append-only change log. Zero means "before
/// the first change"; a cursor is not a wall clock and not a global clock.
public struct ChangeCursor: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int64

    public static let zero = ChangeCursor(unchecked: 0)

    public init(_ rawValue: Int64) throws {
        guard rawValue >= 0 else { throw SyncStoreError.invalidCursor(rawValue) }
        self.rawValue = rawValue
    }

    public init(decimalString: String) throws {
        guard let value = Int64(decimalString), value >= 0 else {
            throw SyncStoreError.invalidCursorString(decimalString)
        }
        self.rawValue = value
    }

    init(unchecked rawValue: Int64) {
        self.rawValue = rawValue
    }

    public var decimalString: String { String(rawValue) }
    public var description: String { decimalString }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Monotonic execution generation for one active run branch. A new handoff
/// installs a higher epoch; commands stamped with an older epoch are refused
/// even when the same task is still visible on both devices.
public struct ExecutionEpoch: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws {
        guard rawValue > 0 else { throw SyncStoreError.invalidEpoch(rawValue) }
        self.rawValue = rawValue
    }

    public init(decimalString: String) throws {
        guard let value = Int64(decimalString), value > 0 else {
            throw SyncStoreError.invalidEpochString(decimalString)
        }
        rawValue = value
    }

    public var decimalString: String { String(rawValue) }
    public var description: String { decimalString }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A same-machine Bridge identifier that was derived from a local path (or
/// another device-local value). It is intentionally not a `StableIdentifier`:
/// it can differ per device and must be mapped explicitly.
public struct LegacyBridgeIdentifier: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(validating value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.contains("\0") else {
            throw SyncStoreError.invalidLegacyIdentifier(value)
        }
        rawValue = value
    }

    public var description: String { rawValue }
}
