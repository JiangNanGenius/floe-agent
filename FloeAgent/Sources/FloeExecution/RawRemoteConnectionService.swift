import Foundation
import Network
import FloeCore

public enum RemoteTextConnectionKind: String, Sendable, Codable, CaseIterable {
    case tcp
    case telnet
}

/// Run-scoped raw TCP/Telnet sessions. Nothing here is persisted or synced.
public actor RawRemoteConnectionService {
    public struct SessionSnapshot: Sendable, Codable {
        public let sessionID: UUID
        public let kind: RemoteTextConnectionKind
        public let host: String
        public let port: Int
        public let transportState: String
        public let expiresAt: Date
    }

    private struct Entry {
        var runID: UUID
        var kind: RemoteTextConnectionKind
        var client: RawTCPConnection
        var host: String
        var port: Int
        var expiresAt: Date
    }

    private var sessions: [UUID: Entry] = [:]

    public init() {}

    public func open(
        runID: UUID,
        host: String,
        port: Int,
        kind: RemoteTextConnectionKind,
        timeout: TimeInterval = 15
    ) async throws -> UUID {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65535).contains(port),
              let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw FloeError.validationFailed("A valid host and TCP port are required")
        }
        let client = RawTCPConnection(host: NWEndpoint.Host(host), port: networkPort, telnet: kind == .telnet)
        try await client.connect(timeout: timeout)
        let id = UUID()
        sessions[id] = Entry(runID: runID, kind: kind, client: client,
                             host: host, port: port, expiresAt: Date().addingTimeInterval(30 * 60))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30 * 60))
            await self?.expire(sessionID: id)
        }
        return id
    }

    /// Only sessions owned by this run are visible, even when an exact ID is supplied.
    public func snapshots(runID: UUID, sessionID: UUID? = nil) throws -> [SessionSnapshot] {
        if let sessionID, sessions[sessionID]?.runID != runID {
            throw FloeError.notFound("Temporary connection session")
        }
        return sessions.compactMap { id, entry in
            guard entry.runID == runID, sessionID == nil || sessionID == id else { return nil }
            return SessionSnapshot(sessionID: id, kind: entry.kind, host: entry.host,
                                   port: entry.port, transportState: entry.client.transportState,
                                   expiresAt: entry.expiresAt)
        }.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    public func exchange(
        runID: UUID,
        sessionID: UUID,
        data: Data?,
        wait: TimeInterval,
        maxBytes: Int
    ) async throws -> Data {
        guard let entry = sessions[sessionID], entry.runID == runID else {
            throw FloeError.notFound("Temporary connection session")
        }
        if let data, !data.isEmpty { try await entry.client.send(data) }
        return try await entry.client.receive(timeout: min(max(wait, 0.05), 30), maxBytes: min(max(maxBytes, 1), 262_144))
    }

    public func close(runID: UUID, sessionID: UUID) async {
        guard let entry = sessions[sessionID], entry.runID == runID else { return }
        sessions.removeValue(forKey: sessionID)
        entry.client.close()
    }

    private func expire(sessionID: UUID) {
        guard let entry = sessions.removeValue(forKey: sessionID) else { return }
        entry.client.close()
    }
}

final class RawTCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.floeagent.raw-remote-connection")
    private let telnet: Bool

    var transportState: String {
        switch connection.state {
        case .ready: "connected"
        case .setup, .preparing: "connecting"
        case .waiting: "waiting"
        case .failed: "failed"
        case .cancelled: "closed"
        @unknown default: "unknown"
        }
    }

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, telnet: Bool) {
        self.connection = NWConnection(host: host, port: port, using: .tcp)
        self.telnet = telnet
    }

    func connect(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(returning: ())
                case .failed(let error):
                    gate.resume(throwing: error)
                case .cancelled:
                    gate.resume(throwing: FloeError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + max(1, timeout)) { [connection] in
                if gate.resume(throwing: FloeError.validationFailed("TCP connection timed out")) {
                    connection.cancel()
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            })
        }
    }

    func receive(timeout: TimeInterval, maxBytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = ContinuationGate<Data>(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { [weak self] data, _, _, error in
                guard let self else { return }
                if let error {
                    gate.resume(throwing: error)
                    return
                }
                let received = data ?? Data()
                if telnet {
                    let (clean, response) = Self.consumeTelnetNegotiation(received)
                    if !response.isEmpty {
                        connection.send(content: response, completion: .idempotent)
                    }
                    gate.resume(returning: clean)
                } else {
                    gate.resume(returning: received)
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                _ = gate.resume(returning: Data())
            }
        }
    }

    func close() { connection.cancel() }

    /// Refuses option negotiation while preserving application bytes. This
    /// is sufficient for switch/router CLIs that do not require a custom
    /// terminal type and avoids leaking IAC bytes into model-visible output.
    private static func consumeTelnetNegotiation(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var clean: [UInt8] = []
        var response: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 255 else {
                clean.append(bytes[index]); index += 1; continue
            }
            guard index + 1 < bytes.count else { break }
            let command = bytes[index + 1]
            if command == 255 { clean.append(255); index += 2; continue }
            if [251, 252, 253, 254].contains(command), index + 2 < bytes.count {
                let option = bytes[index + 2]
                response.append(contentsOf: [255, command == 251 || command == 252 ? 254 : 252, option])
                index += 3
                continue
            }
            if command == 250 {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 255 && bytes[index + 1] == 240) { index += 1 }
                index = min(index + 2, bytes.count)
                continue
            }
            index += 2
        }
        return (Data(clean), Data(response))
    }
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    @discardableResult
    func resume(returning value: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(throwing: error)
        return true
    }
}
