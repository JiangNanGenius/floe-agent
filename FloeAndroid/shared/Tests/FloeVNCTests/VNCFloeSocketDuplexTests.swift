// SPDX-License-Identifier: MPL-2.0
//
// Real loopback full-duplex fixtures for the actual BSD
// SocketNetworkConnection (authored, NOT RUN in this lane). On Darwin the
// VNCConnection factory selects Network.framework, so these tests reach the
// internal BSD class directly through @testable RoyalVNCKit instead.
//
// They pin the transport guarantees the Android RFB stack relies on:
//   1. a pending receive cannot block a later client write, the real peer
//      sees the exact request bytes and can complete the response
//      (regression: upstream funneled blocking read and write onto the
//      caller-supplied queue, starving the write behind a blocked recv when
//      the embedding queue is serial and racing the retained buffer when it
//      is concurrent — the NetworkConnection contract never required either);
//   2. cancel() releases a blocked reader without hanging;
//   3. serialized full writes keep submission order and exact bytes.
// All peers are real BSD loopback sockets; no mocks, no buffered replay.

#if canImport(Darwin) || canImport(Glibc) || canImport(Android)
import Dispatch
import Foundation
import Testing
@testable import RoyalVNCKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

private struct TimeoutError: Error {}

/// Lock-protected value box safe to hand across task boundaries.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Value) {
        lock.lock(); storage = newValue; lock.unlock()
    }
}

/// The BSD connection is lock-guarded internally; the fixtures only move it
/// across task boundaries inside this box.
private final class TransportBox: @unchecked Sendable {
    let connection: SocketNetworkConnection

    init(_ connection: SocketNetworkConnection) {
        self.connection = connection
    }
}

/// Purpose-built loopback peer for the duplex fixtures: it accepts one real
/// TCP connection, drains whatever the client sends into `incoming`, and lets
/// each test decide when (and whether) to answer — exactly the server shape
/// that starves a coupled read/write transport.
private final class DuplexLoopbackPeer: @unchecked Sendable {
    enum PeerError: Error {
        case socket
        case bind
    }

    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var incoming: [UInt8] = []
    private var stopped = false
    private var thread: Thread?
    private(set) var port: UInt16 = 0

    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PeerError.socket }
#if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                       socklen_t(MemoryLayout<Int32>.size))
#endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw PeerError.bind
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw PeerError.bind
        }
        listenerFD = fd
        port = UInt16(bigEndian: actual.sin_port)
        let worker = Thread { [weak self] in self?.acceptAndDrain() }
        worker.name = "floe.vnc.duplex.peer"
        thread = worker
        worker.start()
        return port
    }

    /// Poll until at least `count` bytes arrived; returns the first `count`.
    func waitForIncoming(_ count: Int,
                         timeout: Duration) async -> [UInt8]? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now <= deadline {
            let snapshot = lock.withLock { incoming }
            if snapshot.count >= count {
                return Array(snapshot.prefix(count))
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    @discardableResult
    func sendToClient(_ data: Data) -> Bool {
        lock.lock()
        let fd = clientFD
        lock.unlock()
        guard fd >= 0 else { return false }
        var offset = 0
        let bytes = [UInt8](data)
#if canImport(Glibc) || canImport(Android)
        let flags = Int32(MSG_NOSIGNAL)
#else
        let flags: Int32 = 0
#endif
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base.advanced(by: offset), bytes.count - offset, flags)
            }
            if sent <= 0 { return false }
            offset += sent
        }
        return true
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let listener = listenerFD
        let client = clientFD
        listenerFD = -1
        clientFD = -1
        lock.unlock()
        if client >= 0 {
            _ = shutdown(client, Int32(SHUT_RDWR))
            close(client)
        }
        if listener >= 0 {
            _ = shutdown(listener, Int32(SHUT_RDWR))
            close(listener)
        }
    }

    private func acceptAndDrain() {
        let fd = listenerFD
        guard fd >= 0 else { return }
        let accepted = accept(fd, nil, nil)
        guard accepted >= 0 else { return }
        lock.lock()
        if stopped {
            lock.unlock()
            close(accepted)
            return
        }
        clientFD = accepted
        lock.unlock()

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let capacity = buffer.count
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(accepted, base, capacity, 0)
            }
            if count <= 0 { break }
            lock.lock()
            incoming.append(contentsOf: buffer.prefix(count))
            lock.unlock()
        }
    }
}

@Suite("BSD socket transport full-duplex", .serialized)
struct VNCFloeSocketDuplexTests {
    private func makeStartedConnection(
        port: UInt16,
        attributes: DispatchQueue.Attributes
    ) -> (TransportBox, Locked<NetworkConnectionStatus>) {
        let settings = NetworkConnectionSettings(connectionTimeout: 15,
                                                 host: "127.0.0.1",
                                                 port: port)
        let connection = SocketNetworkConnection(settings: settings)
        let status = Locked<NetworkConnectionStatus>(.unknown("None"))
        connection.setStatusUpdateHandler { newStatus in
            status.set(newStatus)
        }
        // Deliberately small, optionally serial caller queue: the
        // NetworkConnection contract says nothing about concurrency, and the
        // upstream defect serialized both blocking lanes on this queue.
        connection.start(queue: DispatchQueue(
            label: "floe.vnc.duplex.caller",
            attributes: attributes
        ))
        return (TransportBox(connection), status)
    }

    private func waitUntil(
        _ timeout: Duration,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TimeoutError()
    }

    private func duplexRoundTrip(
        peer: DuplexLoopbackPeer,
        box: TransportBox,
        status: Locked<NetworkConnectionStatus>
    ) async throws {
        try await waitUntil(.seconds(5)) {
            if case .ready = status.get() { return true }
            return false
        }

        let request = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let response = Data([0x01, 0x02, 0x03, 0x04])

        // Read first: with no peer data available this blocks in recv().
        let readResult = Locked<Result<Data, Error>?>(nil)
        _ = Task {
            do {
                readResult.set(.success(try await box.connection.read(minimumLength: 4, maximumLength: 4)))
            } catch { readResult.set(.failure(error)) }
        }
        // Give the read time to become genuinely pending before writing.
        try await Task.sleep(nanoseconds: 200_000_000)

        // The regression assertion: this write must complete even though a
        // read is still blocked. On the pre-fix transport with a serial
        // caller queue it never runs (starved behind the blocked recv), so
        // the poll times out and the test fails instead of hanging.
        let writeDone = Locked(false)
        _ = Task {
            _ = try? await box.connection.write(data: request)
            writeDone.set(true)
        }
        do {
            try await waitUntil(.seconds(5)) { writeDone.get() }
        } catch is TimeoutError {
            Issue.record("client write starved behind the pending receive")
            return
        }

        // The real peer must have seen the exact request bytes...
        let incoming = await peer.waitForIncoming(request.count,
                                                  timeout: .seconds(5))
        let received = try #require(incoming)
        #expect(received == [UInt8](request))

        // ...and must be able to complete the response to the pending read.
        #expect(peer.sendToClient(response))
        try await waitUntil(.seconds(5)) { readResult.get() != nil }
        let result = try #require(readResult.get())
        #expect(try result.get() == response)

        // Exact-byte retention: one 6-byte datagram satisfies a 4-byte read
        // and the next read sees the remaining 2 bytes without new I/O.
        #expect(peer.sendToClient(Data([9, 8, 7, 6, 5, 4])))
        let retained = try await box.connection.read(minimumLength: 4,
                                                     maximumLength: 4)
        #expect(retained == Data([9, 8, 7, 6]))
        let remainder = try await box.connection.read(minimumLength: 2,
                                                      maximumLength: 2)
        #expect(remainder == Data([5, 4]))
    }

    @Test("Pending receive cannot block a client write (serial caller queue)")
    func pendingReceiveDoesNotBlockWriteSerialQueue() async throws {
        let peer = DuplexLoopbackPeer()
        let port = try peer.start()
        defer { peer.stop() }
        let (box, status) = makeStartedConnection(port: port, attributes: [])
        defer { box.connection.cancel() }
        try await duplexRoundTrip(peer: peer, box: box, status: status)
    }

    @Test("Pending receive cannot block a client write (concurrent caller queue)")
    func pendingReceiveDoesNotBlockWriteConcurrentQueue() async throws {
        let peer = DuplexLoopbackPeer()
        let port = try peer.start()
        defer { peer.stop() }
        let (box, status) = makeStartedConnection(
            port: port, attributes: .concurrent
        )
        defer { box.connection.cancel() }
        try await duplexRoundTrip(peer: peer, box: box, status: status)
    }

    @Test("Cancel releases a blocked reader without hanging")
    func cancelReleasesBlockedReader() async throws {
        let peer = DuplexLoopbackPeer()
        let port = try peer.start()
        defer { peer.stop() }
        let (box, status) = makeStartedConnection(port: port, attributes: [])
        defer { box.connection.cancel() }

        try await waitUntil(.seconds(5)) {
            if case .ready = status.get() { return true }
            return false
        }

        let readResult = Locked<Result<Data, Error>?>(nil)
        _ = Task {
            do {
                readResult.set(.success(try await box.connection.read(minimumLength: 8, maximumLength: 8)))
            } catch { readResult.set(.failure(error)) }
        }
        // Let the reader block inside recv() before cancelling.
        try await Task.sleep(nanoseconds: 200_000_000)

        box.connection.cancel()

        // shutdown() must interrupt the blocked recv() promptly; anything
        // else (including silently keeping the read pending) is a failure.
        do {
            try await waitUntil(.seconds(5)) { readResult.get() != nil }
        } catch is TimeoutError {
            Issue.record("cancel() did not release the blocked reader")
            return
        }
        let result = try #require(readResult.get())
        do {
            _ = try result.get()
            Issue.record("read must fail after cancel()")
        } catch {
            // Expected: .closed (recv interrupted by shutdown) or .cancelled.
        }
        // The terminal status is posted asynchronously on the caller queue;
        // poll instead of assuming ordering with the read result.
        do {
            try await waitUntil(.seconds(5)) {
                if case .cancelled = status.get() { return true }
                return false
            }
        } catch is TimeoutError {
            Issue.record("terminal status after cancel() must be .cancelled")
        }
    }

    @Test("Serialized full writes keep submission order and exact bytes")
    func serializedWritesPreserveOrderAndBytes() async throws {
        let peer = DuplexLoopbackPeer()
        let port = try peer.start()
        defer { peer.stop() }
        let (box, status) = makeStartedConnection(
            port: port, attributes: .concurrent
        )
        defer { box.connection.cancel() }

        try await waitUntil(.seconds(5)) {
            if case .ready = status.get() { return true }
            return false
        }

        // Larger than the transport chunk and the peer buffer: exercises the
        // partial-send loop against real TCP backpressure.
        let first = Data((0..<128_000).map { UInt8($0 % 251) })
        let second = Data((0..<97_000).map { UInt8(255 - ($0 % 253)) })

        try await box.connection.write(data: first)
        try await box.connection.write(data: second)

        let observed = await peer.waitForIncoming(first.count + second.count,
                                                  timeout: .seconds(10))
        let received = try #require(observed)
        #expect(received == [UInt8](first) + [UInt8](second))
    }
}
#endif
