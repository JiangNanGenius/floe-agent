import Foundation

/// Stable, typed identifiers for every entity in a music project.
///
/// IDs are minted once and never recycled; undo/redo and edits preserve the
/// identity of surviving entities. Raw-string inits exist for deterministic
/// fixtures and for the persistence adapter; production callers should use
/// the UUID-based `init()`.

public struct MusicProjectID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: String
    public var id: String { rawValue }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "MusicProjectID rawValue must be non-empty")
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}

public struct MusicTrackID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: String
    public var id: String { rawValue }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "MusicTrackID rawValue must be non-empty")
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}

public struct MusicClipID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: String
    public var id: String { rawValue }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "MusicClipID rawValue must be non-empty")
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}

/// Identity of an immutable, content-addressed source asset (audio file,
/// sample, MIDI file). The asset record itself lives in `MusicAsset`.
public struct MusicAssetID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: String
    public var id: String { rawValue }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "MusicAssetID rawValue must be non-empty")
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}

public struct MusicDJSessionID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: String
    public var id: String { rawValue }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "MusicDJSessionID rawValue must be non-empty")
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}

public struct MusicSessionID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: String
    public var id: String { rawValue }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "MusicSessionID rawValue must be non-empty")
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
}
