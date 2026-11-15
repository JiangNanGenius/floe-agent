// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Host-owned configuration for the development-only page bridge. The value is
/// set by a compiled host before a run; an imported project cannot enable it.
public struct GameDeveloperBridgeConfiguration: Sendable, Equatable {
    public let engine: GameEngineID
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
    public let includeEngineHook: Bool

    public init(engine: GameEngineID,
                maximumRequestBytes: Int = 262_144,
                maximumResponseBytes: Int = 4_194_304,
                includeEngineHook: Bool = true) throws {
        guard (1_024...1_048_576).contains(maximumRequestBytes),
              (1_024...64 * 1_024 * 1_024).contains(maximumResponseBytes),
              maximumResponseBytes >= maximumRequestBytes else {
            throw GameDeveloperBridgeError.invalidConfiguration
        }
        self.engine = engine
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.includeEngineHook = includeEngineHook
    }
}

public struct GameDeveloperBridgeLease: Sendable, Equatable {
    public let token: UUID
    public let engine: GameEngineID
    /// The player generation that currently owns this lease. The player
    /// refreshes it when a new run starts; callers should read the live lease
    /// from `GameWebPlayer.developerBridgeLease` before every exchange.
    public let generation: Int

    public init(token: UUID, engine: GameEngineID, generation: Int) {
        self.token = token
        self.engine = engine
        self.generation = generation
    }
}

/// Fixed operations. No caller-authored JavaScript, Ruby or shell text is
/// accepted by this bridge.
public enum GameDeveloperBridgeOperation: String, Codable, Sendable, CaseIterable {
    case probe
    case read
    case write
    case invoke
    case snapshot
    case restore
    case reset
    case diagnostics
    case detach
}

public enum GameDeveloperBridgeError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidState(String)
    case notReady
    case bridgeUnavailable(String)
    case staleRun
    case invalidPayload(String)
    case payloadTooLarge(String)
    case unsupportedOperation
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The developer bridge configuration is invalid."
        case .invalidState(let detail): return "The developer bridge is not in a valid state: \(detail)"
        case .notReady: return "The game has not loaded yet."
        case .bridgeUnavailable(let detail): return "The developer bridge is unavailable: \(detail)"
        case .staleRun: return "The game run changed; the development request is stale."
        case .invalidPayload(let detail): return "The developer payload is invalid: \(detail)"
        case .payloadTooLarge(let detail): return "The developer payload is too large: \(detail)"
        case .unsupportedOperation: return "The game did not acknowledge the developer operation."
        case .runtime(let detail): return "The developer bridge failed: \(detail)"
        }
    }
}

/// The fixed page-side endpoint name. The helper is a host resource, not
/// project content; the exchange script only calls its typed operation switch.
enum GameDeveloperBridgePage {
    static let objectName = "FloeDeveloper"
    static let bootstrapName = "FloeDeveloperBootstrap"
    static let helperResource = "FloeDeveloper"
    static let helperDirectory = "Developer"
    static let hookDirectory = "Developer/Hooks"
}
