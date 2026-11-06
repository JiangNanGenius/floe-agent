// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum NoteAuthor: String, Sendable, Codable {
    case user
    /// Imported from an AI summary; marked so user edits stay protected.
    case aiImported
}

/// A manual note in the main notes area. `expectedRevision` guards concurrent
/// edits: a stale write fails instead of silently clobbering.
public struct NoteEntry: Sendable, Codable, Identifiable, Hashable {
    public let id: NoteEntryID
    public let meetingID: MeetingID
    public var body: String
    public var author: NoteAuthor
    public var source: SourceReference
    public private(set) var revision: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: NoteEntryID = NoteEntryID(), meetingID: MeetingID, body: String, author: NoteAuthor, source: SourceReference, createdAt: Date = Date()) {
        self.id = id
        self.meetingID = meetingID
        self.body = body
        self.author = author
        self.source = source
        self.revision = 0
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    mutating func applyEdit(_ newBody: String, at date: Date = Date()) {
        body = newBody
        revision += 1
        updatedAt = date
    }

    /// Restores persisted revision state after decoding from storage.
    mutating func setStored(revision: Int, updatedAt: Date) {
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

/// A lightweight "重点" marker pinned to a media position or segment.
public struct TimeMarker: Sendable, Codable, Identifiable, Hashable {
    public let id: TimeMarkerID
    public let meetingID: MeetingID
    public var label: String?
    public var source: SourceReference
    public let createdAt: Date

    public init(id: TimeMarkerID = TimeMarkerID(), meetingID: MeetingID, label: String?, source: SourceReference, createdAt: Date = Date()) {
        self.id = id
        self.meetingID = meetingID
        self.label = label
        self.source = source
        self.createdAt = createdAt
    }
}
