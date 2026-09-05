import Foundation
#if canImport(Network)
import Network
import Testing
@testable import FloeExecution

/// Actual loopback socket tests; no real passwords, messages or user trust-store changes.
private final class MailTestPeer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "floe.mail.test.peer")
    private let lock = NSLock()
    private var received = Data()
    private var connection: NWConnection?
    let rejectTLS: Bool
    init(rejectTLS: Bool) throws { self.rejectTLS = rejectTLS; listener = try NWListener(using: .tcp, on: .any) }
    var commands: String { lock.lock(); defer { lock.unlock() }; return String(decoding: received, as: UTF8.self) }
    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume(returning: Int(listener.port!.rawValue)) }
                if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [self] connection in
                lock.lock(); self.connection = connection; lock.unlock()
                connection.stateUpdateHandler = { [self] state in
                    if case .ready = state, rejectTLS {
                        connection.send(content: Data("* OK test peer\r\n".utf8), completion: .contentProcessed { _ in })
                        read(connection)
                    }
                }
                connection.start(queue: queue)
            }
            listener.start(queue: queue)
        }
    }
    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, done, error in
            if let data {
                lock.lock(); received.append(data); let text = String(decoding: received, as: UTF8.self); lock.unlock()
                if text.contains("F1 STARTTLS\r\n") {
                    connection.send(content: Data("F1 NO TLS unavailable\r\n".utf8), completion: .contentProcessed { _ in })
                }
            }
            if !done, error == nil { read(connection) }
        }
    }
    func stop() { listener.cancel(); lock.lock(); let client = connection; lock.unlock(); client?.cancel() }
}

@Suite("FloeExecution.MailTransport", .serialized)
struct MailTransportTests {
    @Test func actualSocketRefusesTLSBeforeCredentials() async throws {
        let peer = try MailTestPeer(rejectTLS: true); let port = try await peer.start(); defer { peer.stop() }
        await #expect(throws: MailFailure.protocolRejected) {
            try await MailClient().test(server: .init(host: "127.0.0.1", port: port, tls: .startTLS, username: "test-user"), protocolName: "imap", password: "must-not-cross-wire")
        }
        #expect(peer.commands == "F1 STARTTLS\r\n")
        #expect(!peer.commands.contains("test-user"))
    }
    @Test func cancellationInterruptsSilentSocket() async throws {
        let peer = try MailTestPeer(rejectTLS: false); let port = try await peer.start(); defer { peer.stop() }
        let started = ContinuousClock.now
        let task = Task {
            try await MailClient().test(server: .init(host: "127.0.0.1", port: port, tls: .startTLS, username: "test"), protocolName: "imap", password: "test")
        }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        await #expect(throws: MailFailure.cancelled) { try await task.value }
        #expect(started.duration(to: .now) < .seconds(3))
    }
}
#endif
