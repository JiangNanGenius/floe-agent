// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Explicit bounds for the development bridge. Every count/byte limit is
/// validated before a request is sent and again when a response is decoded.
public struct GameDeveloperLimits: Sendable, Equatable {
    public let maximumFields: Int
    public let maximumActions: Int
    public let maximumActionParameters: Int
    public let maximumChoices: Int
    public let maximumStringBytes: Int
    public let maximumLabelBytes: Int
    public let maximumDetailBytes: Int
    public let maximumChangesPerRequest: Int
    public let maximumValueMagnitude: Double
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
    public let maximumSnapshotBytes: Int
    public let maximumHistoryEntries: Int
    public let maximumCheckpoints: Int
    public let maximumCheckpointBytes: Int
    public let maximumLogEntries: Int
    public let maximumNotices: Int

    public init(maximumFields: Int = 256,
                maximumActions: Int = 128,
                maximumActionParameters: Int = 8,
                maximumChoices: Int = 64,
                maximumStringBytes: Int = 8_192,
                maximumLabelBytes: Int = 256,
                maximumDetailBytes: Int = 1_024,
                maximumChangesPerRequest: Int = 32,
                maximumValueMagnitude: Double = 1_000_000_000_000,
                maximumRequestBytes: Int = 262_144,
                maximumResponseBytes: Int = 4_194_304,
                maximumSnapshotBytes: Int = 4_194_304,
                maximumHistoryEntries: Int = 100,
                maximumCheckpoints: Int = 16,
                maximumCheckpointBytes: Int = 16 * 1_024 * 1_024,
                maximumLogEntries: Int = 200,
                maximumNotices: Int = 16) throws {
        guard (1...1_024).contains(maximumFields),
              (1...1_024).contains(maximumActions),
              (1...32).contains(maximumActionParameters),
              (1...256).contains(maximumChoices),
              (64...65_536).contains(maximumStringBytes),
              (32...4_096).contains(maximumLabelBytes),
              (64...65_536).contains(maximumDetailBytes),
              (1...256).contains(maximumChangesPerRequest),
              maximumValueMagnitude.isFinite, maximumValueMagnitude > 0,
              maximumValueMagnitude <= 9_007_199_254_740_992,
              (1_024...4_194_304).contains(maximumRequestBytes),
              (1_024...64 * 1_024 * 1_024).contains(maximumResponseBytes),
              (1_024...64 * 1_024 * 1_024).contains(maximumSnapshotBytes),
              (1...1_000).contains(maximumHistoryEntries),
              (1...64).contains(maximumCheckpoints),
              (1_024...256 * 1_024 * 1_024).contains(maximumCheckpointBytes),
              (1...10_000).contains(maximumLogEntries),
              (1...64).contains(maximumNotices) else {
            throw GameDeveloperError.invalidConfiguration("limits")
        }
        self.maximumFields = maximumFields
        self.maximumActions = maximumActions
        self.maximumActionParameters = maximumActionParameters
        self.maximumChoices = maximumChoices
        self.maximumStringBytes = maximumStringBytes
        self.maximumLabelBytes = maximumLabelBytes
        self.maximumDetailBytes = maximumDetailBytes
        self.maximumChangesPerRequest = maximumChangesPerRequest
        self.maximumValueMagnitude = maximumValueMagnitude
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.maximumHistoryEntries = maximumHistoryEntries
        self.maximumCheckpoints = maximumCheckpoints
        self.maximumCheckpointBytes = maximumCheckpointBytes
        self.maximumLogEntries = maximumLogEntries
        self.maximumNotices = maximumNotices
    }

    public static let `default` = try! GameDeveloperLimits()
}

public enum GameDeveloperError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case notAttached
    case alreadyAttached
    case staleSession
    case contextMismatch(String)
    case bridgeUnavailable(String)
    case invalidRequest(String)
    case invalidField(String)
    case invalidAction(String)
    case unsupported(String)
    case payloadTooLarge(String)
    case snapshotUnavailable(String)
    case checkpointUnavailable(String)
    case checkpointMissing(UUID)
    case confirmationRequired(String)
    case busy
    case transport(String)
}

extension GameDeveloperError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return "Developer configuration is invalid: \(detail)"
        case .notAttached:
            return "The development menu is not attached to the running game."
        case .alreadyAttached:
            return "The development menu is already attached."
        case .staleSession:
            return "The game run changed. Reopen the development menu for the current run."
        case .contextMismatch(let detail):
            return "The development request belongs to a different project or run: \(detail)"
        case .bridgeUnavailable(let detail):
            return "The development bridge is unavailable: \(detail)"
        case .invalidRequest(let detail):
            return "The development request is invalid: \(detail)"
        case .invalidField(let detail):
            return "That field cannot be changed: \(detail)"
        case .invalidAction(let detail):
            return "That action is not available: \(detail)"
        case .unsupported(let detail):
            return "This engine route does not support the requested control: \(detail)"
        case .payloadTooLarge(let detail):
            return "The development request is too large: \(detail)"
        case .snapshotUnavailable(let detail):
            return "A game debug snapshot is not available for this engine: \(detail)"
        case .checkpointUnavailable(let detail):
            return "A recoverable checkpoint could not be created: \(detail)"
        case .checkpointMissing:
            return "The selected checkpoint no longer exists."
        case .confirmationRequired(let detail):
            return "This action needs explicit confirmation: \(detail)"
        case .busy:
            return "Another development action is still running."
        case .transport(let detail):
            return "The game bridge returned an error: \(detail)"
        }
    }
}

extension GameDeveloperError {
    /// Short, stable code used by logs and tests; never a raw page script.
    public var code: String {
        switch self {
        case .invalidConfiguration: return "invalid-configuration"
        case .notAttached: return "not-attached"
        case .alreadyAttached: return "already-attached"
        case .staleSession: return "stale-session"
        case .contextMismatch: return "context-mismatch"
        case .bridgeUnavailable: return "bridge-unavailable"
        case .invalidRequest: return "invalid-request"
        case .invalidField: return "invalid-field"
        case .invalidAction: return "invalid-action"
        case .unsupported: return "unsupported"
        case .payloadTooLarge: return "payload-too-large"
        case .snapshotUnavailable: return "snapshot-unavailable"
        case .checkpointUnavailable: return "checkpoint-unavailable"
        case .checkpointMissing: return "checkpoint-missing"
        case .confirmationRequired: return "confirmation-required"
        case .busy: return "busy"
        case .transport: return "transport"
        }
    }
}
