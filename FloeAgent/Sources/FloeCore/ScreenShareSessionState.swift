import Foundation

/// Heartbeat and frame identity are separate: a paused/static broadcast may
/// be alive without delivering a CURRENT frame. Never renew frame consent.
public struct ScreenShareSessionState: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public static let maximumFrameAge: TimeInterval = 3
    public enum Phase: String, Codable, Sendable { case active, paused, stopping, stopped }
    public var schemaVersion: Int
    public var sessionID: UUID
    public var isActive: Bool
    public var updatedAt: Date
    public var phase: Phase?
    public var frameID: UUID?
    public var frameCapturedAt: Date?
    public init(sessionID: UUID, isActive: Bool, updatedAt: Date = Date(),
                schemaVersion: Int = ScreenShareSessionState.schemaVersion, phase: Phase? = nil,
                frameID: UUID? = nil, frameCapturedAt: Date? = nil) {
        self.schemaVersion=schemaVersion; self.sessionID=sessionID; self.isActive=isActive
        self.updatedAt=updatedAt; self.phase=phase; self.frameID=frameID; self.frameCapturedAt=frameCapturedAt
    }
    public var effectivePhase: Phase { phase ?? (isActive ? .active : .stopped) }
    public func hasFreshHeartbeat(at now: Date = Date()) -> Bool {
        schemaVersion == Self.schemaVersion && updatedAt <= now.addingTimeInterval(1)
            && now.timeIntervalSince(updatedAt) <= Self.maximumFrameAge
    }
    public func isFresh(at now: Date = Date()) -> Bool {
        let captured=frameCapturedAt ?? updatedAt
        return hasFreshHeartbeat(at:now) && isActive && effectivePhase == .active
            && captured <= now.addingTimeInterval(1) && now.timeIntervalSince(captured) <= Self.maximumFrameAge
    }
}

public struct ScreenShareStopCommand: Codable, Equatable, Sendable {
    public static let version = 1
    public var version = ScreenShareStopCommand.version
    public var sessionID: UUID
    public var requestID: UUID
    public var issuedAt: Date
    public var expiresAt: Date
    public init(sessionID: UUID, requestID: UUID = UUID(), now: Date = Date()) {
        self.sessionID=sessionID; self.requestID=requestID; issuedAt=now; expiresAt=now.addingTimeInterval(15)
    }
    public func matches(_ state: ScreenShareSessionState, at now: Date = Date()) -> Bool {
        version == Self.version && state.schemaVersion == ScreenShareSessionState.schemaVersion
            && sessionID == state.sessionID && state.isActive
            && issuedAt <= now.addingTimeInterval(1) && now <= expiresAt
            && expiresAt > issuedAt && expiresAt.timeIntervalSince(issuedAt) <= 15
    }
}
public struct ScreenShareStopAcknowledgment: Codable, Equatable, Sendable {
    public enum Phase: Int, Codable, Sendable { case finishInvoked = 1, finished = 2 }
    public var version = 1
    public var sessionID: UUID
    public var requestID: UUID
    public var phase: Phase
    public var updatedAt: Date
    public init(command: ScreenShareStopCommand, phase: Phase, now: Date = Date()) {
        sessionID=command.sessionID; requestID=command.requestID; self.phase=phase; updatedAt=now
    }
    public func matches(_ command: ScreenShareStopCommand) -> Bool {
        version == 1 && sessionID == command.sessionID && requestID == command.requestID
            && updatedAt >= command.issuedAt.addingTimeInterval(-1)
    }
}

/// Used by the real center. Observation cannot grant consent. Only the
/// explicit Analyze action calls begin; the request is valid for one image,
/// session, destination and generation, even after later frames arrive.
public struct ScreenShareAnalysisGate: Sendable {
    public struct Ticket: Equatable, Sendable {
        public var sessionID: UUID
        public var frameID: UUID
        public var providerID: UUID
        public var modelID: UUID
        public var generation: UUID
    }
    public private(set) var sessionID: UUID?
    public private(set) var ticket: Ticket?
    public init() {}
    @discardableResult public mutating func observe(sessionID: UUID?) -> Bool {
        guard self.sessionID != sessionID else { return false }
        self.sessionID=sessionID; ticket=nil; return true
    }
    public mutating func begin(state: ScreenShareSessionState, providerID: UUID, modelID: UUID,
                               now: Date = Date()) -> Ticket? {
        guard state.sessionID == sessionID, state.isFresh(at:now), let frameID=state.frameID else { return nil }
        let next=Ticket(sessionID:state.sessionID,frameID:frameID,providerID:providerID,modelID:modelID,generation:UUID())
        ticket=next; return next
    }
    public mutating func cancel() { ticket=nil }
    public func accepts(_ candidate: Ticket, state: ScreenShareSessionState,
                        providerID: UUID, modelID: UUID, now: Date = Date()) -> Bool {
        ticket == candidate && sessionID == state.sessionID && candidate.sessionID == state.sessionID
            && state.isActive && state.effectivePhase == .active && state.hasFreshHeartbeat(at:now)
            && candidate.providerID == providerID && candidate.modelID == modelID
    }
}
