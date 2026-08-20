import Foundation

/// Versioned metadata shared by the ReplayKit extension and host app. A frame
/// is usable only while its session is active and its heartbeat is fresh.
public struct ScreenShareSessionState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumFrameAge: TimeInterval = 3

    public var schemaVersion: Int
    public var sessionID: UUID
    public var isActive: Bool
    public var updatedAt: Date

    public init(
        sessionID: UUID,
        isActive: Bool,
        updatedAt: Date = Date(),
        schemaVersion: Int = ScreenShareSessionState.schemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.isActive = isActive
        self.updatedAt = updatedAt
    }

    public func isFresh(at now: Date = Date()) -> Bool {
        schemaVersion == Self.schemaVersion
            && isActive
            && updatedAt <= now.addingTimeInterval(1)
            && now.timeIntervalSince(updatedAt) <= Self.maximumFrameAge
    }
}
