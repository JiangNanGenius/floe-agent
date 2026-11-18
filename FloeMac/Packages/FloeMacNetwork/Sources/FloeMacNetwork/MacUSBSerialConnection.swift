// SPDX-License-Identifier: MPL-2.0
//
// POSIX termios serial connection for one explicitly selected /dev/cu.* node.
// Settings come from the shared USBSerialSettings grammar; the port grammar
// is validated before open. Close is idempotent and drains the read pump
// before the descriptor is released.

import Darwin
import Foundation
import FloeToolboxCore
import FloeToolboxClients

/// Pure termios mapping, testable on the host without any attached device.
/// macOS termios exposes the standard baud table up to 230400 and only
/// none/even/odd parity; mark/space and higher bauds are reported
/// unsupported instead of being approximated.
enum MacUSBSerialTermios {
    static func baudConstant(_ baud: UInt32) -> speed_t? {
        switch baud {
        case 300: speed_t(B300)
        case 1200: speed_t(B1200)
        case 2400: speed_t(B2400)
        case 4800: speed_t(B4800)
        case 9600: speed_t(B9600)
        case 19200: speed_t(B19200)
        case 38400: speed_t(B38400)
        case 57600: speed_t(B57600)
        case 115200: speed_t(B115200)
        case 230400: speed_t(B230400)
        default: nil
        }
    }

    static func apply(settings s: USBSerialSettings, to t: inout termios) throws {
        guard s.parity == .none || s.parity == .even || s.parity == .odd else {
            throw ClientError.unsupported
        }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE)
        switch s.dataBits {
        case 5: t.c_cflag |= tcflag_t(CS5)
        case 6: t.c_cflag |= tcflag_t(CS6)
        case 7: t.c_cflag |= tcflag_t(CS7)
        default: t.c_cflag |= tcflag_t(CS8)
        }
        if s.stopBits == 2 { t.c_cflag |= tcflag_t(CSTOPB) } else { t.c_cflag &= ~tcflag_t(CSTOPB) }
        switch s.parity {
        case .none:
            t.c_cflag &= ~tcflag_t(PARENB | PARODD)
        case .even:
            t.c_cflag |= tcflag_t(PARENB); t.c_cflag &= ~tcflag_t(PARODD)
        case .odd:
            t.c_cflag |= tcflag_t(PARENB | PARODD)
        case .mark, .space:
            throw ClientError.unsupported
        }
        // Non-blocking reads governed by the pump's poll loop.
        t.c_cc.0 = 0 // VMIN
        t.c_cc.1 = 0 // VTIME
        guard let baud = baudConstant(s.baud) else { throw ClientError.unsupported }
        cfsetispeed(&t, baud)
        cfsetospeed(&t, baud)
    }
}

/// Holds the read pump task so the actor initializer never touches an
/// isolated property; the pump body hops back to the actor via await.
private final class MacUSBReadPump: @unchecked Sendable {
    private var task: Task<Void, Never>?
    func start(_ body: @escaping @Sendable () async -> Void) {
        task = Task { await body() }
    }
    func cancel() {
        task?.cancel()
        task = nil
    }
}

public actor MacUSBSerialConnection: SerialConnection {
    public nonisolated let path: String
    private let pumpBox = MacUSBReadPump()
    private var descriptor: Int32 = -1
    private var closed = false
    private static let bufferLimit = 256 * 1_024
    private var pending = Data()
    private struct ReadWaiter {
        let maximum: Int
        let completion: MacSerialCompletion<Data>
    }
    private var waiters: [ReadWaiter] = []

    /// Opens and configures the selected node. The descriptor is closed again
    /// unless every setup step succeeds.
    public init(path: String, settings: USBSerialSettings) throws {
        let normalized = try MacUSBSerialPortCatalog().validate(path: path)
        let fd = Darwin.open(normalized, O_RDWR | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClientError.networkFailure }
        var node = stat()
        var attributes = termios()
        guard fstat(fd, &node) == 0, node.st_mode & S_IFMT == S_IFCHR,
              tcgetattr(fd, &attributes) == 0 else {
            Darwin.close(fd)
            throw ClientError.networkFailure
        }
        do {
            try MacUSBSerialTermios.apply(settings: settings, to: &attributes)
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard tcsetattr(fd, TCSANOW, &attributes) == 0 else {
            Darwin.close(fd)
            throw ClientError.networkFailure
        }
        self.init(ownedDescriptor: fd, path: normalized)
    }

    init(ownedDescriptor: Int32, path: String) {
        self.path = path
        self.descriptor = ownedDescriptor
        pumpBox.start { [weak self] in
            guard let self else { return }
            await self.pumpLoop()
        }
    }

    public func send(_ bytes: Data) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            guard !closed, descriptor >= 0 else { throw ClientError.closed }
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
            }
            if written > 0 { offset += written; continue }
            if written < 0, errno == EINTR { continue }
            if written == 0 || (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                guard ContinuousClock.now < deadline else { throw ClientError.timedOut }
                try await Task.sleep(for: .milliseconds(15))
                continue
            }
            await close()
            throw ClientError.networkFailure
        }
    }

    public func receive(maximumBytes: Int) async throws -> Data {
        guard !closed else { throw ClientError.closed }
        guard (1...65536).contains(maximumBytes), waiters.count < 16 else { throw ClientError.tooLarge }
        if !pending.isEmpty { return take(maximumBytes) }
        let completion = MacSerialCompletion<Data>()
        waiters.append(ReadWaiter(maximum: maximumBytes, completion: completion))
        defer { waiters.removeAll { $0.completion === completion } }
        return try await completion.wait(seconds: 300)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        pumpBox.cancel()
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        for waiter in waiters { waiter.completion.finish(.failure(ClientError.closed)) }
        waiters.removeAll()
        pending.removeAll()
    }

    private func take(_ maximum: Int) -> Data {
        let count = min(maximum, pending.count)
        let value = pending.prefix(count)
        pending.removeFirst(count)
        return Data(value)
    }

    private func pumpLoop() async {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !closed, !Task.isCancelled, descriptor >= 0 {
            let available = min(buffer.count, Self.bufferLimit - pending.count)
            if available > 0 {
                let count = Darwin.read(descriptor, &buffer, available)
                if count > 0 {
                    pending.append(contentsOf: buffer[0..<count])
                    while let waiter = waiters.first, !pending.isEmpty {
                        waiters.removeFirst()
                        guard waiter.completion.isPending else { continue }
                        waiter.completion.finish(.success(take(waiter.maximum)))
                    }
                    await Task.yield()
                    continue
                }
                if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    await close()
                    return
                }
            }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return }
        }
    }
}
