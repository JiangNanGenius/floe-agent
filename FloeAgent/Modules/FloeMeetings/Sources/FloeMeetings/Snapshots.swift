// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum MeetingStatus: String, Sendable, Codable {
    case draft
    case capturing
    case finished
    case cancelled
}

/// Value snapshot of a persisted meeting.
public struct MeetingSnapshot: Sendable, Codable, Identifiable, Hashable {
    public let id: MeetingID
    public var title: String
    public var status: MeetingStatus
    public var capabilities: MeetingProcessingCapabilities
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: MeetingID = MeetingID(), title: String, status: MeetingStatus = .draft, capabilities: MeetingProcessingCapabilities = .unavailable, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.status = status
        self.capabilities = capabilities
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Value snapshot of a persisted capture/import session.
public struct CaptureSessionSnapshot: Sendable, Codable, Identifiable, Hashable {
    public let id: CaptureSessionID
    public let meetingID: MeetingID
    public var kind: CaptureKind
    public var state: CaptureSessionState
    public var directory: URL?
    public var sourceFile: String?
    public var durationSeconds: Double?
    public var startedAt: Date?
    public var endedAt: Date?
    public var stopReason: CaptureStopReason?
    /// Durable analysis ancestry; never a user-visible separate recording.
    public var originSessionID: CaptureSessionID?
    /// Explicit same-recording membership, independent of ASR ancestry.
    public var recordingID: UUID?
    public var partOrdinal: Int?
    public var displayName: String?

    public init(id: CaptureSessionID = CaptureSessionID(), meetingID: MeetingID, kind: CaptureKind, state: CaptureSessionState = .pending, directory: URL? = nil, sourceFile: String? = nil, durationSeconds: Double? = nil, startedAt: Date? = nil, endedAt: Date? = nil, stopReason: CaptureStopReason? = nil, originSessionID: CaptureSessionID? = nil, recordingID: UUID? = nil, partOrdinal: Int? = nil, displayName: String? = nil) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.state = state
        self.directory = directory
        self.sourceFile = sourceFile
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stopReason = stopReason
        self.originSessionID = originSessionID
        self.recordingID = recordingID
        self.partOrdinal = partOrdinal
        self.displayName = displayName
    }
}

/// A logical recording can contain explicitly paused/resumed physical captures.
/// Its media coordinates are derived from original files, never wall-clock gaps.
public enum MeetingRecordingState: String, Sendable, Codable {
    case recording, paused, finished
}

public struct MeetingRecordingSnapshot: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let meetingID: MeetingID
    public let state: MeetingRecordingState
    public let createdAt: Date
    public let parts: [CaptureSessionSnapshot]
    public init(id: UUID, meetingID: MeetingID, state: MeetingRecordingState,
                createdAt: Date, parts: [CaptureSessionSnapshot]) {
        self.id = id; self.meetingID = meetingID; self.state = state
        self.createdAt = createdAt; self.parts = parts
    }
}
