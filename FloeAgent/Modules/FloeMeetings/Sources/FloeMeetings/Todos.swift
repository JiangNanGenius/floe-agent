// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum TodoOrigin: String, Sendable, Codable {
    case user
    case aiProposed
}

public enum TodoStatus: String, Sendable, Codable {
    case open
    case done
    case dismissed
}

/// A to-do extracted from the meeting. Identity is stable; dedup uses the
/// normalized text. Once a user edits a to-do it is protected: later
/// engine/AI proposals with the same normalized text attach to the same item
/// instead of overwriting the user's text or status.
public struct TodoItem: Sendable, Codable, Identifiable, Hashable {
    public let id: TodoItemID
    public let meetingID: MeetingID
    public var text: String
    /// Lowercased, whitespace-collapsed form used for dedup.
    public let normalizedText: String
    public var status: TodoStatus
    public var origin: TodoOrigin
    /// True once the user has edited text/status; protects against overwrites.
    public private(set) var userModified: Bool
    public var source: SourceReference
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: TodoItemID = TodoItemID(), meetingID: MeetingID, text: String, origin: TodoOrigin, source: SourceReference, createdAt: Date = Date()) {
        self.id = id
        self.meetingID = meetingID
        self.text = text
        self.normalizedText = TodoItem.normalized(text)
        self.status = .open
        self.origin = origin
        self.userModified = false
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Engine/AI-side refresh. Cannot change text or status once the user
    /// modified the item; it may only attach an additional source.
    mutating func applyProposal(text proposedText: String, source newSource: SourceReference, at date: Date = Date()) {
        guard !userModified else { return }
        text = proposedText
        source = newSource
        updatedAt = date
    }

    mutating func applyUserEdit(text newText: String?, status newStatus: TodoStatus?, at date: Date = Date()) {
        if let newText { text = newText }
        if let newStatus { status = newStatus }
        userModified = true
        updatedAt = date
    }

    /// Restores persisted state after decoding from storage.
    mutating func setStored(status: TodoStatus, userModified: Bool, updatedAt: Date) {
        self.status = status
        self.userModified = userModified
        self.updatedAt = updatedAt
    }
}

/// A durable conclusion. Decisions live outside the rolling summary window,
/// so "最近5分钟" refreshes never lose earlier conclusions.
public struct MeetingDecision: Sendable, Codable, Identifiable, Hashable {
    public let id: DecisionID
    public let meetingID: MeetingID
    public var text: String
    public var source: SourceReference
    public let createdAt: Date

    public init(id: DecisionID = DecisionID(), meetingID: MeetingID, text: String, source: SourceReference, createdAt: Date = Date()) {
        self.id = id
        self.meetingID = meetingID
        self.text = text
        self.source = source
        self.createdAt = createdAt
    }
}

public enum SummaryKind: String, Sendable, Codable {
    case first
    case rolling
}

/// A stored AI summary record. This module never generates summaries; it only
/// persists what the host's summarizer produces on demand.
public struct SummaryRecord: Sendable, Codable, Identifiable, Hashable {
    public let id: SummaryRecordID
    public let meetingID: MeetingID
    public var kind: SummaryKind
    public var text: String
    /// Rolling summaries record the window they covered.
    public var window: MediaTimeRange?
    public let createdAt: Date

    public init(id: SummaryRecordID = SummaryRecordID(), meetingID: MeetingID, kind: SummaryKind, text: String, window: MediaTimeRange?, createdAt: Date = Date()) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.text = text
        self.window = window
        self.createdAt = createdAt
    }
}
