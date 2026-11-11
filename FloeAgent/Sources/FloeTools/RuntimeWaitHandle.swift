import Foundation
import FloeCore

/// Model arguments contain a condition, never a task/run/continuation authority.
public struct RuntimeWaitRequest: Sendable, Codable, Hashable {
    public static let maximumSeconds: TimeInterval = 86_400
    public var seconds: TimeInterval?
    public var alarmID: UUID?

    public init(seconds: TimeInterval? = nil, alarmID: UUID? = nil) {
        self.seconds = seconds
        self.alarmID = alarmID
    }

    public func validate() throws {
        guard (seconds != nil) != (alarmID != nil) else {
            throw FloeError.validationFailed("Choose either seconds or alarmID for task.wait.")
        }
        if let seconds, !seconds.isFinite || seconds < 0 || seconds > Self.maximumSeconds {
            throw FloeError.validationFailed("task.wait seconds must be finite and between 0 and 86400.")
        }
    }
}

/// Minted by the runtime for ONE approved main-run dispatch. Not Codable;
/// decoding model JSON or copying environment labels cannot produce a handle.
public struct RuntimeWaitHandle: Sendable {
    private let suspend: @Sendable (RuntimeWaitRequest) async throws -> ToolExecutionOutput

    public init(suspend: @escaping @Sendable (RuntimeWaitRequest) async throws -> ToolExecutionOutput) {
        self.suspend = suspend
    }

    public func wait(_ request: RuntimeWaitRequest) async throws -> ToolExecutionOutput {
        try request.validate()
        return try await suspend(request)
    }
}
