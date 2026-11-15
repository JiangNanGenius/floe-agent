// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameWebKit
import FloeGameDeveloperCore

/// Concrete development transport over the host-owned `GameWebPlayer` bridge.
/// It adds no second WebKit view and forwards only the fixed operation enum.
@MainActor
public final class GameWebPlayerDeveloperTransport: GameDeveloperTransport {
    public let binding: GameDeveloperSessionBinding
    public let player: GameWebPlayer
    public let configuration: GameDeveloperBridgeConfiguration

    public init(player: GameWebPlayer,
                projectID: UUID,
                owner: GameProjectOwner,
                savedRevision: String,
                runID: UUID) throws {
        let engine = player.package.prepared.engine
        self.player = player
        self.binding = GameDeveloperSessionBinding(
            projectID: projectID, owner: owner, savedRevision: savedRevision,
            runID: runID, engine: engine)
        self.configuration = try GameDeveloperBridgeConfiguration(engine: engine)
    }

    public func attach() async throws -> GameDeveloperAttachReceipt {
        // The controller normally enables the bridge before start(). If the
        // host created the transport after load, this is the supported
        // late-attach path (project boot registrations are not replayed).
        let lease = try await player.enableDeveloperBridge(configuration)
        for _ in 0..<100 {
            if player.loaded { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard player.loaded else {
            throw GameDeveloperError.bridgeUnavailable("the game has not finished loading")
        }
        let value: Data
        do {
            value = try await player.developerExchange(.probe,
                payload: GameDeveloperWire.emptyPayload(), lease: lease)
        } catch let error as GameDeveloperBridgeError {
            throw map(error)
        } catch {
            throw GameDeveloperError.transport(String(describing: error))
        }
        let capabilities: GameDeveloperCapabilities
        do {
            capabilities = try GameDeveloperWire.decodeCapabilities(
                value, expectedEngine: binding.engine, limits: .default)
        } catch let error as GameDeveloperError {
            throw error
        } catch {
            throw GameDeveloperError.transport(String(describing: error))
        }
        return GameDeveloperAttachReceipt(
            binding: binding, bridgeToken: lease.token,
            protocolVersion: capabilities.protocolVersion,
            runtime: capabilities.runtime)
    }

    public func exchange(_ request: GameDeveloperTransportRequest) async throws -> GameDeveloperTransportResponse {
        guard let lease = player.developerBridgeLease,
              lease.engine == binding.engine else {
            throw GameDeveloperError.notAttached
        }
        let operation: GameDeveloperBridgeOperation
        switch request.operation {
        case .probe: operation = .probe
        case .read: operation = .read
        case .write: operation = .write
        case .invoke: operation = .invoke
        case .snapshot: operation = .snapshot
        case .restore: operation = .restore
        case .reset: operation = .reset
        case .diagnostics: operation = .diagnostics
        case .detach: operation = .detach
        }
        do {
            let value = try await player.developerExchange(
                operation, payload: request.payload, lease: lease)
            return GameDeveloperTransportResponse(
                sessionID: request.sessionID, requestID: request.requestID,
                engine: binding.engine, value: value)
        } catch let error as GameDeveloperBridgeError {
            throw map(error)
        } catch {
            throw GameDeveloperError.transport(String(describing: error))
        }
    }

    public func captureScreenshot() async throws -> Data {
        do { return try await player.capturePNG() }
        catch { throw GameDeveloperError.transport(String(describing: error)) }
    }

    public func logs() -> [String] { player.logs }

    public func detach() {
        player.disableDeveloperBridge()
    }

    private func map(_ error: GameDeveloperBridgeError) -> GameDeveloperError {
        switch error {
        case .invalidConfiguration:
            return .invalidConfiguration("web bridge")
        case .invalidState(let detail):
            return .bridgeUnavailable(detail)
        case .notReady:
            return .notAttached
        case .bridgeUnavailable(let detail):
            return .bridgeUnavailable(detail)
        case .staleRun:
            return .staleSession
        case .invalidPayload(let detail):
            return .invalidRequest(detail)
        case .payloadTooLarge(let detail):
            return .payloadTooLarge(detail)
        case .unsupportedOperation:
            return .unsupported("the page did not acknowledge the operation")
        case .runtime(let detail):
            return .transport(detail)
        }
    }
}
