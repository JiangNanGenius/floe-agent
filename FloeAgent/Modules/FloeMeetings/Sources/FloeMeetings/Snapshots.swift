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

    public init(id: CaptureSessionID = CaptureSessionID(), meetingID: MeetingID, kind: CaptureKind, state: CaptureSessionState = .pending, directory: URL? = nil, sourceFile: String? = nil, durationSeconds: Double? = nil, startedAt: Date? = nil, endedAt: Date? = nil, stopReason: CaptureStopReason? = nil) {
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
    }
}
