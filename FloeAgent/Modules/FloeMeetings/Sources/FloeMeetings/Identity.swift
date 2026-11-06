// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Stable identity of a meeting. Survives save/reopen and capture sessions.
public struct MeetingID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Identity of one continuous capture or import inside a meeting.
public struct CaptureSessionID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Identity of a transcript segment. Segment identity is stable so that notes,
/// markers, todos and decisions can reference it as a source.
public struct TranscriptSegmentID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Identity of a speaker. Stable across user renames and merges; merges keep
/// this id and record the target instead of rewriting segment sources.
public struct SpeakerID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct NoteEntryID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct TimeMarkerID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct TodoItemID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct DecisionID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct SummaryRecordID: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
