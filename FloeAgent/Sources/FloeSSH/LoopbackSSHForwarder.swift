#if canImport(Network)
import Foundation
import Network

/// Device-local TCP listener that adapts socket-only clients (RoyalVNC) to
/// Citadel direct-tcpip without exposing the forwarded service on Wi-Fi.
public final class LoopbackSSHForwarder: @unchecked Sendable {
    public struct Endpoint: Sendable, Hashable {
        public let host: String
        public let port: UInt16
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.floeagent.ssh.loopback-forwarder")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var channels: [SSHByteChannel] = []

    private init(listener: NWListener) {
        self.listener = listener
    }

    public static func start(
        session: SSHSessionHandle,
        targetHost: String,
        targetPort: Int
    ) async throws -> LoopbackSSHForwarder {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let forwarder = LoopbackSSHForwarder(listener: listener)
        listener.newConnectionHandler = { [weak forwarder] connection in
            forwarder?.accept(
                connection,
                session: session,
                targetHost: targetHost,
                targetPort: targetPort
            )
        }
        try await forwarder.begin()
        return forwarder
    }

    public var endpoint: Endpoint? {
        guard let port = listener.port else { return nil }
        return Endpoint(host: "127.0.0.1", port: port.rawValue)
    }

    public func close() async {
        listener.cancel()
        let snapshot = lock.withLock { () -> ([NWConnection], [SSHByteChannel]) in
            let snapshot = (connections, channels)
            connections.removeAll()
            channels.removeAll()
            return snapshot
        }
        for connection in snapshot.0 { connection.cancel() }
        for channel in snapshot.1 { await channel.close() }
    }

    private func begin() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(
        _ connection: NWConnection,
        session: SSHSessionHandle,
        targetHost: String,
        targetPort: Int
    ) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        Task { [weak self] in
            guard let self else { return }
            do {
                let channel = try await session.openDirectTCPIP(host: targetHost, port: targetPort)
                lock.withLock { channels.append(channel) }
                async let upstream: Void = pumpLocalToSSH(connection: connection, channel: channel)
                async let downstream: Void = pumpSSHToLocal(channel: channel, connection: connection)
                _ = try await (upstream, downstream)
            } catch {
                connection.cancel()
            }
        }
    }

    private func pumpLocalToSSH(connection: NWConnection, channel: SSHByteChannel) async throws {
        while !Task.isCancelled {
            guard let data = try await connection.receiveChunk() else { break }
            if !data.isEmpty { try await channel.write(data) }
        }
        await channel.close()
    }

    private func pumpSSHToLocal(channel: SSHByteChannel, connection: NWConnection) async throws {
        for try await data in channel.inbound {
            try await connection.sendData(data)
        }
        connection.cancel()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func claim() -> Bool {
        lock.withLock {
            guard !value else { return false }
            value = true
            return true
        }
    }
}

private extension NWConnection {
    func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if isComplete && (data?.isEmpty ?? true) { continuation.resume(returning: nil) }
                else { continuation.resume(returning: data) }
            }
        }
    }

    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
#endif
