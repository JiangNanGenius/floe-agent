// Standalone, isolated control-socket regression tests. No existing Bridge or
// user state is used. Build together with the protocol/client/server sources.
import Darwin
import Dispatch
import Foundation

private enum TestFailure: Error { case failed(String) }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

private func socketAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return address
}

private func connectRaw(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TestFailure.failed("socket") }
    var address = socketAddress(path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { Darwin.close(fd); throw TestFailure.failed("connect") }
    return fd
}

private final class FakeServer: @unchecked Sendable {
    let path = "/tmp/fipc-\(UUID().uuidString.prefix(12)).sock"
    let fd: Int32
    let done = DispatchGroup()

    init(_ handler: @escaping @Sendable (Int32) -> Void) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestFailure.failed("fake socket") }
        var address = socketAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw TestFailure.failed("fake listen")
        }
        done.enter()
        DispatchQueue.global().async { [self] in
            defer { done.leave() }
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return }
            var noSignal: Int32 = 1
            _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            handler(peer)
            Darwin.close(peer)
        }
    }

    func finish() throws {
        _ = shutdown(fd, SHUT_RDWR)
        guard done.wait(timeout: .now() + 3) == .success else {
            throw TestFailure.failed("fake server did not terminate")
        }
        Darwin.close(fd)
        _ = path.withCString { unlink($0) }
    }
}

@main
private enum BridgeControlIPCTests {
    static func main() async {
        do {
            try testSilentHelloDeadline()
            print("PASS: silent hello")
            try testTrickledHelloDeadline()
            print("PASS: trickled hello")
            try testAuthenticationFailureDoesNotCloseOtherDescriptors()
            print("PASS: authentication cleanup")
            try testServerRejectsSilentHello()
            print("PASS: server handshake deadline")
            try await testCloseUnblocksWriter()
            print("PASS: close unblocks a stalled writer")
            try await testConcurrentCloseAndDescriptorReuse()
            print("PASS: silent/trickled hello deadlines, authentication cleanup, server handshake deadline, concurrent close and descriptor reuse")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testSilentHelloDeadline() throws {
        let gate = DispatchSemaphore(value: 0)
        let server = try FakeServer { _ in _ = gate.wait(timeout: .now() + 2) }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try BridgeControlClient.connect(socketPath: server.path, token: "fixture", timeout: 0.2)
            throw TestFailure.failed("silent hello unexpectedly succeeded")
        } catch BridgeControlFailure.timeout { }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        gate.signal()
        try server.finish()
        try require(elapsed >= 0.15 && elapsed < 1.2, "silent hello deadline was \(elapsed)s")
    }

    private static func testTrickledHelloDeadline() throws {
        let frame = try BridgeControlCodec.encode(BridgeControlMessage(kind: .reply))
        let server = try FakeServer { peer in
            for byte in frame.prefix(8) {
                var value = byte
                if Darwin.send(peer, &value, 1, 0) != 1 { break }
                usleep(70_000)
            }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try BridgeControlClient.connect(socketPath: server.path, token: "fixture", timeout: 0.23)
            throw TestFailure.failed("trickled hello unexpectedly succeeded")
        } catch BridgeControlFailure.timeout { }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        try server.finish()
        try require(elapsed >= 0.18 && elapsed < 1.2, "trickled hello exceeded the total deadline: \(elapsed)s")
    }

    private static func testAuthenticationFailureDoesNotCloseOtherDescriptors() throws {
        let frame = try BridgeControlCodec.encode(BridgeControlMessage(kind: .reply, error: "denied"))
        let server = try FakeServer { peer in
            var helloBytes = [UInt8](repeating: 0, count: 4096)
            _ = recv(peer, &helloBytes, helloBytes.count, 0)
            _ = frame.withUnsafeBytes { Darwin.send(peer, $0.baseAddress!, frame.count, 0) }
        }
        var sentinels: [Int32] = []
        for _ in 0..<32 {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw TestFailure.failed("socketpair") }
            sentinels.append(contentsOf: pair)
        }
        defer { sentinels.forEach { Darwin.close($0) } }
        do {
            _ = try BridgeControlClient.connect(socketPath: server.path, token: "wrong", timeout: 1)
            throw TestFailure.failed("authentication rejection unexpectedly succeeded")
        } catch BridgeControlFailure.authentication { }
        for fd in sentinels { try require(fcntl(fd, F_GETFD) >= 0, "authentication closed unrelated fd") }
        try server.finish()
    }

    private static func testServerRejectsSilentHello() throws {
        let path = "/tmp/fipc-\(UUID().uuidString.prefix(12)).sock"
        let server = BridgeControlServer(socketPath: path, token: "fixture") { _, _ in
            BridgeControlMessage(kind: .reply)
        }
        try server.start()
        defer { server.stop() }
        let peer = try connectRaw(path)
        defer { Darwin.close(peer) }
        var item = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&item, 1, 6_500)
        try require(ready > 0, "server left unauthenticated hello hanging")
        var byte: UInt8 = 0
        try require(Darwin.recv(peer, &byte, 1, 0) == 0, "server did not close silent peer")
    }

    private static func testConcurrentCloseAndDescriptorReuse() async throws {
        for _ in 0..<12 {
            let path = "/tmp/fipc-\(UUID().uuidString.prefix(12)).sock"
            let server = BridgeControlServer(socketPath: path, token: "fixture") { _, _ in
                try? await Task.sleep(for: .milliseconds(20))
                return BridgeControlMessage(kind: .reply)
            }
            try server.start()
            let client = try BridgeControlClient.connect(socketPath: path, token: "fixture", timeout: 1)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<24 {
                    group.addTask {
                        _ = try? await client.request(BridgeControlMessage(kind: .status), timeout: 0.3)
                    }
                }
                try await Task.sleep(for: .milliseconds(2))
                client.close()
                client.close()
                server.stop()
                var sentinels: [(Int32, Int32)] = []
                for _ in 0..<32 {
                    var pair: [Int32] = [-1, -1]
                    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
                        throw TestFailure.failed("reuse socketpair")
                    }
                    sentinels.append((pair[0], pair[1]))
                }
                defer { for pair in sentinels { Darwin.close(pair.0); Darwin.close(pair.1) } }
                try await group.waitForAll()
                try await Task.sleep(for: .milliseconds(40))
                for pair in sentinels {
                    try require(fcntl(pair.0, F_GETFD) >= 0 && fcntl(pair.1, F_GETFD) >= 0,
                                "concurrent close closed an unrelated reused descriptor")
                    var item = pollfd(fd: pair.1, events: Int16(POLLIN), revents: 0)
                    try require(Darwin.poll(&item, 1, 0) == 0,
                                "concurrent IPC wrote to a reused descriptor")
                }
            }
        }
    }

    private static func testCloseUnblocksWriter() async throws {
        let gate = DispatchSemaphore(value: 0)
        let frame = try BridgeControlCodec.encode(BridgeControlMessage(kind: .reply))
        let server = try FakeServer { peer in
            var helloBytes = [UInt8](repeating: 0, count: 4096)
            _ = recv(peer, &helloBytes, helloBytes.count, 0)
            _ = frame.withUnsafeBytes { Darwin.send(peer, $0.baseAddress!, frame.count, 0) }
            _ = gate.wait(timeout: .now() + 3)
        }
        defer { gate.signal() }
        let client = try BridgeControlClient.connect(socketPath: server.path, token: "fixture", timeout: 1)
        let payload = String(repeating: "x", count: 490_000)
        var closeElapsed: Double = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    _ = try? await client.request(BridgeControlMessage(kind: .status, reason: payload), timeout: 1)
                }
            }
            try await Task.sleep(for: .milliseconds(40))
            let start = DispatchTime.now().uptimeNanoseconds
            client.close()
            try await group.waitForAll()
            closeElapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        }
        gate.signal()
        try server.finish()
        try require(closeElapsed < 1.0, "closing a stalled writer took \(closeElapsed)s")
    }
}
