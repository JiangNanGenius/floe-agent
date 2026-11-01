// SPDX-License-Identifier: MPL-2.0
//
// Real loopback RFB 3.8 peer for the authored (NOT RUN) FloeVNC tests.
// It validates actual bytes through RoyalVNCKit: protocol version, security
// type selection, 16-byte VNC challenge, ServerInit, SetPixelFormat,
// FramebufferUpdateRequest, a raw 64x64 frame, pointer events and close.

#if canImport(Darwin) || canImport(Glibc) || canImport(Android)
import Foundation
import Testing
@testable import FloeVNC

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

private final class RFBLoopbackPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var stopped = false
    private var thread: Thread?
    private var pointerLog: [(UInt8, Int, Int)] = []
    private var keyLog: [(UInt32, Bool)] = []
    private(set) var port: UInt16 = 0

    struct PixelFormat {
        var bitsPerPixel: UInt8 = 32
        var depth: UInt8 = 24
        var bigEndian: Bool = false
        var trueColor: Bool = true
        var redMax: UInt16 = 255
        var greenMax: UInt16 = 255
        var blueMax: UInt16 = 255
        var redShift: UInt8 = 16
        var greenShift: UInt8 = 8
        var blueShift: UInt8 = 0
    }

    var pointerEvents: [(UInt8, Int, Int)] {
        lock.lock(); defer { lock.unlock() }; return pointerLog
    }

    var keyEvents: [(UInt32, Bool)] {
        lock.lock(); defer { lock.unlock() }; return keyLog
    }

    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PeerError.socket }
#if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
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
        listener = fd
        port = UInt16(bigEndian: actual.sin_port)
        let worker = Thread { [weak self] in self?.acceptLoop() }
        worker.name = "floe.rfb.test.peer"
        thread = worker
        worker.start()
        return port
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let listenerFD = listener
        let clientFD = client
        listener = -1
        client = -1
        lock.unlock()
        if clientFD >= 0 {
            _ = shutdown(clientFD, Int32(SHUT_RDWR))
            _ = close(clientFD)
        }
        if listenerFD >= 0 {
            _ = shutdown(listenerFD, Int32(SHUT_RDWR))
            _ = close(listenerFD)
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }; return stopped
    }

    private func acceptLoop() {
        let fd = listener
        guard fd >= 0 else { return }
        let accepted = accept(fd, nil, nil)
        guard accepted >= 0 else { return }
        lock.lock()
        if stopped {
            lock.unlock()
            _ = close(accepted)
            return
        }
        client = accepted
        lock.unlock()
        handle(client: accepted)
        _ = close(accepted)
    }

    private func handle(client fd: Int32) {
        guard sendAll(fd, Data("RFB 003.008\n".utf8)),
              readExact(fd, 12) != nil,
              sendAll(fd, Data([1, 1])),
              let chosen = readExact(fd, 1), chosen.first == 1,
              sendAll(fd, Data((0..<16).map { UInt8($0) })),
              readExact(fd, 16) != nil,
              sendAll(fd, Data([0, 0, 0, 0])),
              readExact(fd, 1) != nil else {
            return
        }
        var serverInit = Data([0, 64, 0, 64])
        serverInit.append(contentsOf: [
            32, 24, 0, 1,
            0, 255, 0, 255, 0, 255,
            16, 8, 0,
            0, 0, 0,
            0, 0, 0, 4,
        ])
        serverInit.append(contentsOf: Array("test".utf8))
        guard sendAll(fd, serverInit) else { return }

        var format = PixelFormat()
        var sentFrame = false
        while !isStopped {
            guard let type = readExact(fd, 1)?.first else { return }
            switch type {
            case 0: // SetPixelFormat
                guard let rest = readExact(fd, 19) else { return }
                format = parse(rest)
            case 2: // SetEncodings
                guard let rest = readExact(fd, 3) else { return }
                let count = Int(rest[1]) << 8 | Int(rest[2])
                guard readExact(fd, count * 4) != nil else { return }
            case 3: // FramebufferUpdateRequest
                guard readExact(fd, 9) != nil else { return }
                if !sentFrame {
                    sentFrame = true
                    guard sendFrame(fd, format: format) else { return }
                }
            case 4: // KeyEvent
                guard let rest = readExact(fd, 7) else { return }
                let down = rest[0] != 0
                let keysym = UInt32(rest[3]) << 24 | UInt32(rest[4]) << 16 |
                    UInt32(rest[5]) << 8 | UInt32(rest[6])
                lock.lock(); keyLog.append((keysym, down)); lock.unlock()
            case 5: // PointerEvent
                guard let rest = readExact(fd, 5) else { return }
                let mask = rest[0]
                let x = Int(rest[1]) << 8 | Int(rest[2])
                let y = Int(rest[3]) << 8 | Int(rest[4])
                lock.lock(); pointerLog.append((mask, x, y)); lock.unlock()
            case 6: // ClientCutText
                guard let rest = readExact(fd, 7) else { return }
                let length = Int(rest[3]) << 24 | Int(rest[4]) << 16 |
                    Int(rest[5]) << 8 | Int(rest[6])
                guard readExact(fd, length) != nil else { return }
            default:
                return
            }
        }
    }

    private func parse(_ rest: Data) -> PixelFormat {
        let bytes = [UInt8](rest)
        guard bytes.count == 19 else { return PixelFormat() }
        return PixelFormat(
            bitsPerPixel: bytes[3],
            depth: bytes[4],
            bigEndian: bytes[5] != 0,
            trueColor: bytes[6] != 0,
            redMax: UInt16(bytes[7]) << 8 | UInt16(bytes[8]),
            greenMax: UInt16(bytes[9]) << 8 | UInt16(bytes[10]),
            blueMax: UInt16(bytes[11]) << 8 | UInt16(bytes[12]),
            redShift: bytes[13],
            greenShift: bytes[14],
            blueShift: bytes[15]
        )
    }

    private func sendFrame(_ fd: Int32, format: PixelFormat) -> Bool {
        var frame = Data([
            0, 0, // FramebufferUpdate
            0, 1, // one rectangle
            0, 0, 0, 0, // x,y
            0, 64, 0, 64, // width,height
            0, 0, 0, 0, // Raw encoding
        ])
        frame.reserveCapacity(16 + 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let red = UInt8(min(255, x * 4))
                let green = UInt8(min(255, y * 4))
                let blue = UInt8(max(0, 255 - x * 4))
                appendPixel(&frame, red: red, green: green, blue: blue, format: format)
            }
        }
        return sendAll(fd, frame)
    }

    private func appendPixel(_ data: inout Data, red: UInt8, green: UInt8, blue: UInt8, format: PixelFormat) {
        let value = (scale(red, max: format.redMax) << format.redShift) |
            (scale(green, max: format.greenMax) << format.greenShift) |
            (scale(blue, max: format.blueMax) << format.blueShift)
        switch format.bitsPerPixel {
        case 8:
            data.append(UInt8(truncatingIfNeeded: value))
        case 16:
            let value16 = UInt16(truncatingIfNeeded: value)
            if format.bigEndian {
                data.append(UInt8(value16 >> 8))
                data.append(UInt8(value16 & 0xFF))
            } else {
                data.append(UInt8(value16 & 0xFF))
                data.append(UInt8(value16 >> 8))
            }
        default:
            if format.bigEndian {
                data.append(UInt8((value >> 24) & 0xFF))
                data.append(UInt8((value >> 16) & 0xFF))
                data.append(UInt8((value >> 8) & 0xFF))
                data.append(UInt8(value & 0xFF))
            } else {
                data.append(UInt8(value & 0xFF))
                data.append(UInt8((value >> 8) & 0xFF))
                data.append(UInt8((value >> 16) & 0xFF))
                data.append(UInt8((value >> 24) & 0xFF))
            }
        }
    }

    private func scale(_ value: UInt8, max: UInt16) -> UInt32 {
        (UInt32(value) * UInt32(max) + 127) / 255
    }

    private func readExact(_ fd: Int32, _ count: Int) -> Data? {
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: max(1, count))
        while result.count < count {
            let wanted = count - result.count
            let readCount = buffer.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, wanted, 0)
            }
            if readCount <= 0 { return nil }
            result.append(contentsOf: buffer.prefix(readCount))
        }
        return result
    }

    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
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

    enum PeerError: Error {
        case socket
        case bind
    }
}

@Suite("VNC real RFB loopback", .serialized)
struct VNCFloeRFBIntegrationTests {
    @Test("RFB handshake, raw frame lease, pointer input and close")
    func handshakeFrameInputClose() async throws {
        let peer = RFBLoopbackPeer()
        let port = try peer.start()
        defer { peer.stop() }

        let session = VNCFloeSession(host: "127.0.0.1", port: port, password: "secret")
        session.connect()

        var captured: VNCFloeFrame?
        for _ in 0..<200 {
            if session.currentState.isConnected, let frame = session.currentFrame(), frame.width == 64 {
                captured = frame
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let frame = try #require(captured)
        #expect(frame.width == 64)
        #expect(frame.height == 64)
        #expect(frame.stride == 256)
        #expect(frame.byteCount == 16_384)

        // Pixel (10,20): red 40, green 80, blue 215. A swapped channel would
        // make red 215 here.
        let index = (20 * 64 + 10) * 4
        #expect(frame.data[index] == 40)
        #expect(frame.data[index + 1] == 80)
        #expect(frame.data[index + 2] == 215)
        #expect(frame.data[index + 3] == 255)

        let lease = try session.acquireFrame()
        #expect(lease.frame.byteCount == 16_384)
        session.releaseFrame(lease.id)

        try session.send([
            .pointerMove(x: 20, y: 30),
            .pointerButton(button: .left, down: true, x: 20, y: 30),
            .pointerButton(button: .left, down: false, x: 20, y: 30),
            .key(keysym: 0x0061, down: true),
            .key(keysym: 0x0061, down: false),
        ])
        for _ in 0..<100 {
            if peer.pointerEvents.count >= 3, peer.keyEvents.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(peer.pointerEvents.contains { $0.0 == 1 && $0.1 == 20 && $0.2 == 30 })
        #expect(peer.pointerEvents.last?.0 == 0)
        #expect(peer.keyEvents.contains { $0.0 == 0x0061 && $0.1 })

        let closed = await session.close(timeout: 3)
        #expect(closed)
        #expect(session.currentState == .disconnected)
    }
}
#endif
