// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Fixed operation vocabulary. A transport maps these to a compiled, fixed
/// page script; it never forwards caller-authored JavaScript.
public enum GameDeveloperOperation: String, Codable, Sendable, CaseIterable {
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

public struct GameDeveloperTransportRequest: Sendable, Equatable {
    public let sessionID: UUID
    public let requestID: UUID
    public let operation: GameDeveloperOperation
    public let payload: Data

    public init(sessionID: UUID, requestID: UUID,
                operation: GameDeveloperOperation, payload: Data) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.operation = operation
        self.payload = payload
    }
}

public struct GameDeveloperTransportResponse: Sendable, Equatable {
    public let sessionID: UUID
    public let requestID: UUID
    public let engine: GameEngineID
    public let value: Data

    public init(sessionID: UUID, requestID: UUID,
                engine: GameEngineID, value: Data) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.engine = engine
        self.value = value
    }
}

/// Implemented by the host-owned bridge. It must bind one concrete live player
/// and reject another project's context before forwarding anything.
@MainActor
public protocol GameDeveloperTransport: AnyObject {
    var binding: GameDeveloperSessionBinding { get }
    func attach() async throws -> GameDeveloperAttachReceipt
    func exchange(_ request: GameDeveloperTransportRequest) async throws -> GameDeveloperTransportResponse
    func captureScreenshot() async throws -> Data
    func logs() -> [String]
    func detach()
}
