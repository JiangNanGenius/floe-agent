// SPDX-License-Identifier: MPL-2.0
import Foundation
import IrohLib

public struct FloeDeviceLinkPath: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case direct
        case relay
        case unknown
    }

    public let kind: Kind
    public let isSelected: Bool
    public let roundTripMilliseconds: UInt64
    public let bytesSent: UInt64
    public let bytesReceived: UInt64
}

/// An authenticated QUIC connection. Each request and response uses one bidirectional stream.
public final class FloeDeviceLinkConnection: Sendable {
    public static let maximumPayloadBytes = 1_048_576

    public let peerEndpointID: String
    private let connection: Connection

    init(connection: Connection, peerEndpointID: String) {
        self.connection = connection
        self.peerEndpointID = peerEndpointID
    }

    /// Reports live path selection without exposing the peer's network addresses.
    public func paths() -> [FloeDeviceLinkPath] {
        connection.paths().map { path in
            let kind: FloeDeviceLinkPath.Kind
            if path.isRelay {
                kind = .relay
            } else if path.isIp {
                kind = .direct
            } else {
                kind = .unknown
            }
            return FloeDeviceLinkPath(
                kind: kind,
                isSelected: path.isSelected,
                roundTripMilliseconds: path.rttMs,
                bytesSent: path.stats.udpTxBytes,
                bytesReceived: path.stats.udpRxBytes
            )
        }
    }

    public func request(_ payload: Data) async throws -> Data {
        try Self.validatePayload(payload)
        return try await perform {
            let stream = try await connection.openBi()
            do {
                try await Self.write(payload, to: stream.send())
                return try await Self.read(from: stream.recv())
            } catch {
                await Self.discard(stream)
                throw error
            }
        }
    }

    public func receiveRequest() async throws -> FloeDeviceLinkRequest {
        try await perform {
            let stream = try await connection.acceptBi()
            do {
                let payload = try await Self.read(from: stream.recv())
                return FloeDeviceLinkRequest(payload: payload, sender: stream.send(), connection: self)
            } catch {
                await Self.discard(stream)
                throw error
            }
        }
    }

    public func close() throws {
        try connection.close(errorCode: 0, reason: Data())
    }

    /// UniFFI does not cancel a pending Rust read when its Swift task is cancelled.
    /// Close the connection to unblock reads and let the host reconnect and reconcile.
    fileprivate func perform<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            do {
                let result = try await operation()
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            try? self.close()
        }
    }

    fileprivate static func validatePayload(_ payload: Data) throws {
        guard !payload.isEmpty else { throw FloeDeviceLinkError.emptyPayload }
        guard payload.count <= maximumPayloadBytes else { throw FloeDeviceLinkError.payloadTooLarge }
    }

    fileprivate static func write(_ payload: Data, to sender: SendStream) async throws {
        try await sender.writeAll(buf: payload)
        try await sender.finish()
    }

    private static func read(from receiver: RecvStream) async throws -> Data {
        let payload = try await receiver.readToEnd(sizeLimit: UInt32(maximumPayloadBytes))
        try validatePayload(payload)
        return payload
    }

    private static func discard(_ stream: BiStream) async {
        try? await stream.recv().stop(errorCode: 1)
        try? await stream.send().reset(errorCode: 1)
    }
}

public actor FloeDeviceLinkRequest {
    public nonisolated let payload: Data
    private let sender: SendStream
    private let connection: FloeDeviceLinkConnection
    private var responseStarted = false

    fileprivate init(payload: Data, sender: SendStream, connection: FloeDeviceLinkConnection) {
        self.payload = payload
        self.sender = sender
        self.connection = connection
    }

    public func respond(_ payload: Data) async throws {
        guard !responseStarted else { throw FloeDeviceLinkError.responseAlreadyUsed }
        try FloeDeviceLinkConnection.validatePayload(payload)
        responseStarted = true
        // Move the immutable sender out of actor isolation before starting I/O.
        let sender = self.sender
        try await connection.perform {
            do {
                try await FloeDeviceLinkConnection.write(payload, to: sender)
            } catch {
                try? await sender.reset(errorCode: 1)
                throw error
            }
        }
    }
}
