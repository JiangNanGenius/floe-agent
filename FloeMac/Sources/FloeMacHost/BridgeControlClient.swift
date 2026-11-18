// Floe Mac M00 — authenticated control client owned by the mode host.
//
// SPDX-License-Identifier: MPL-2.0
//
// The host never infers a service's live task state from a stale ready file.
// Status, consent and stop decisions travel over this socket. The client
// verifies the helper via a challenge-response pinned key before it treats the
// service identity as trusted.

import Darwin
import Dispatch
import Foundation

final class BridgeControlClient: @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<BridgeControlMessage, Error>
        let timeout: Task<Void, Never>
    }

    private let lock = NSLock()
    private let writeLock = NSLock()
    private var fd: Int32 = -1
    private var closed = false
    private var pending: [UUID: Pending] = [:]

    let identity = UUID()
    private var onEvent: (@Sendable (BridgeControlEvent) -> Void)?
    private var onDisconnect: (@Sendable (String) -> Void)?

    // Registration and the closed check share the reader's state lock. Once
    // accepted, a later disconnect always captures the installed callback.
    func installCallbacks(
        onEvent: @escaping @Sendable (BridgeControlEvent) -> Void,
        onDisconnect: @escaping @Sendable (String) -> Void
    ) -> Bool {
        lock.withLock {
            guard !closed, fd >= 0, self.onEvent == nil, self.onDisconnect == nil else { return false }
            self.onEvent = onEvent
            self.onDisconnect = onDisconnect
            return true
        }
    }

    var isConnected: Bool { lock.withLock { !closed && fd >= 0 } }

    static func connect(socketPath: String, token: String, timeout: TimeInterval = 5) throws -> BridgeControlClient {
        guard timeout.isFinite, timeout > 0, timeout <= 3_600 else {
            throw BridgeControlFailure.timeout
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeControlFailure.socketUnavailable }
        var ownsDescriptor = true
        defer { if ownsDescriptor { Darwin.close(descriptor) } }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw BridgeControlFailure.socketUnavailable
        }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                       socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity, !bytes.contains(0) else { throw BridgeControlFailure.socketPathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw BridgeControlFailure.socketUnavailable }
            try waitForIO(descriptor, events: Int16(POLLOUT), deadline: deadline)
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else { throw BridgeControlFailure.socketUnavailable }
        }

        let hello = BridgeControlMessage(kind: .hello, token: token)
        let helloFrame = try BridgeControlCodec.encode(hello)
        try writeFrame(descriptor, frame: helloFrame, deadline: deadline)
        guard let reply = try readFrame(descriptor, deadline: deadline) else { throw BridgeControlFailure.notConnected }
        guard reply.error == nil, reply.kind == .reply else { throw BridgeControlFailure.authentication }
        guard fcntl(descriptor, F_SETFL, originalFlags) == 0 else { throw BridgeControlFailure.socketUnavailable }
        let sendMicros = Int64((timeout * 1_000_000).rounded(.up))
        var sendTimeout = timeval(tv_sec: Int(sendMicros / 1_000_000), tv_usec: Int32(sendMicros % 1_000_000))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                       socklen_t(MemoryLayout<timeval>.size))

        let client = BridgeControlClient()
        client.fd = descriptor
        ownsDescriptor = false
        client.startReading()
        return client
    }

    func request(_ message: BridgeControlMessage, timeout: TimeInterval = 5) async throws -> BridgeControlMessage {
        var request = message
        let identifier = UUID()
        request.id = identifier
        let frame = try BridgeControlCodec.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self?.fail(identifier, error: BridgeControlFailure.timeout)
            }
            let shouldSend = lock.withLock { () -> Bool in
                guard !closed, fd >= 0 else { return false }
                pending[identifier] = Pending(continuation: continuation, timeout: timeoutTask)
                return true
            }
            guard shouldSend else {
                timeoutTask.cancel()
                continuation.resume(throwing: BridgeControlFailure.notConnected)
                return
            }
            do {
                try send(frame)
            } catch {
                fail(identifier, error: error)
            }
        }
    }

    func close() {
        let values: [Pending]? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            // Do not close here: the reader may still hold this descriptor and
            // a writer may be in send(). Shutdown wakes both; the reader owns
            // the final close after synchronizing with the writer.
            if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) }
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        guard let values else { return }
        for item in values {
            item.timeout.cancel()
            item.continuation.resume(throwing: BridgeControlFailure.notConnected)
        }
    }

    private func startReading() {
        Thread.detachNewThread { [self] in readLoop() }
    }

    private func readLoop() {
        let descriptor = lock.withLock { fd }
        guard descriptor >= 0 else { return }
        while true {
            guard let message = try? Self.readFrame(descriptor) else { break }
            if message.kind == .event {
                if let event = message.event {
                    let callback = lock.withLock { closed ? nil : onEvent }
                    callback?(event)
                }
                continue
            }
            guard let replyTo = message.replyTo else { continue }
            let item: Pending? = lock.withLock {
                pending.removeValue(forKey: replyTo)
            }
            if let item {
                item.timeout.cancel()
                if let error = message.error {
                    item.continuation.resume(throwing: BridgeControlFailure.remote(error))
                } else {
                    item.continuation.resume(returning: message)
                }
            }
        }
        failAll(reason: "The embedded Bridge control connection closed.")
    }

    private func failAll(reason: String) {
        let result: ([Pending], (@Sendable (String) -> Void)?)? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) }
            let values = Array(pending.values)
            pending.removeAll()
            return (values, onDisconnect)
        }
        for item in result?.0 ?? [] {
            item.timeout.cancel()
            // A broken transport is an uncertain outcome, not a negative
            // response from the service. Callers may need reconciliation.
            item.continuation.resume(throwing: BridgeControlFailure.notConnected)
        }
        result?.1?(reason)
        // No read syscall remains, and the writer lock ensures no send syscall
        // can retain the numeric fd after it is released for OS reuse.
        writeLock.withLock {
            let descriptor = lock.withLock { () -> Int32 in
                let descriptor = fd
                fd = -1
                return descriptor
            }
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
    }

    private func fail(_ identifier: UUID, error: Error) {
        let item: Pending? = lock.withLock {
            pending.removeValue(forKey: identifier)
        }
        guard let item else { return }
        item.timeout.cancel()
        item.continuation.resume(throwing: error)
    }

    private func send(_ frame: Data) throws {
        try writeLock.withLock {
            let descriptor = lock.withLock { closed ? -1 : fd }
            guard descriptor >= 0 else { throw BridgeControlFailure.notConnected }
            try Self.writeFrame(descriptor, frame: frame)
        }
    }

    private static func writeFrame(_ descriptor: Int32, _ message: BridgeControlMessage) throws {
        let frame = try BridgeControlCodec.encode(message)
        try writeFrame(descriptor, frame: frame)
    }

    private static func writeFrame(_ descriptor: Int32, frame: Data, deadline: UInt64? = nil) throws {
        var offset = 0
        while offset < frame.count {
            if let deadline { try waitForIO(descriptor, events: Int16(POLLOUT), deadline: deadline) }
            let written = frame.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.send(descriptor, base.advanced(by: offset), frame.count - offset, 0)
            }
            if written < 0 && (errno == EINTR || (deadline != nil && (errno == EAGAIN || errno == EWOULDBLOCK))) { continue }
            guard written > 0 else { throw BridgeControlFailure.notConnected }
            offset += written
        }
    }

    private static func readFrame(_ descriptor: Int32, deadline: UInt64? = nil) throws -> BridgeControlMessage? {
        guard let header = try readExactly(descriptor, count: BridgeControlCodec.headerBytes, deadline: deadline),
              header.count == BridgeControlCodec.headerBytes,
              let length = BridgeControlCodec.bodyLength(fromHeader: header) else {
            return nil
        }
        guard let body = try readExactly(descriptor, count: length, deadline: deadline), body.count == length else {
            return nil
        }
        return try BridgeControlCodec.decodeBody(body)
    }

    private static func readExactly(_ descriptor: Int32, count: Int, deadline: UInt64?) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            if let deadline { try waitForIO(descriptor, events: Int16(POLLIN), deadline: deadline) }
            let readCount = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(descriptor, base.advanced(by: offset), count - offset)
            }
            if readCount == 0 { return offset == 0 ? nil : Data(data.prefix(offset)) }
            if readCount < 0 {
                if errno == EINTR || (deadline != nil && (errno == EAGAIN || errno == EWOULDBLOCK)) { continue }
                return offset == 0 ? nil : Data(data.prefix(offset))
            }
            offset += readCount
        }
        return data
    }

    private static func waitForIO(_ descriptor: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw BridgeControlFailure.timeout }
            let milliseconds = min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max))
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(milliseconds))
            if result > 0 {
                guard item.revents & Int16(POLLNVAL) == 0 else { throw BridgeControlFailure.notConnected }
                return
            }
            if result == 0 { throw BridgeControlFailure.timeout }
            if errno != EINTR { throw BridgeControlFailure.notConnected }
        }
    }
}
