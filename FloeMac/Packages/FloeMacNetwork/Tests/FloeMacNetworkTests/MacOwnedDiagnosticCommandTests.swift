// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import Testing
import FloeToolboxCore
@testable import FloeMacNetwork

struct MacOwnedDiagnosticCommandTests {
    @Test func invocationsTreatHostsAsValues() {
        for host in ["-n", "@127.0.0.1", "two names", "host+trace", "https://host", "a\u{0000}b"] {
            #expect(throws: ToolboxError.self) { try MacOwnedDiagnosticCommand.validateHost(host) }
        }
        #expect(throws: Never.self) { try MacOwnedDiagnosticCommand.validateHost("_https._tcp.example.test") }
    }

    @MainActor @Test func manualOwnerUsesRealLoopbackPingAndTrace() async throws {
        let owner = MacManualNetworkOwner()
        #expect(owner.start(.ping("127.0.0.1")))
        try #require(await owner.drain(timeout: 12))
        #expect(owner.result?.contains("4 packets received") == true)
        #expect(owner.start(.traceroute("127.0.0.1")))
        try #require(await owner.drain(timeout: 9))
        #expect(owner.result?.contains("1  127.0.0.1") == true)
    }

    @Test func cancellationReapsActualOwnedProcess() async throws {
        let gate = MacManualNetworkGate(request: .ping("127.0.0.1"), lease: .init(ownerID: UUID()))
        let (started, continuation) = AsyncStream<pid_t>.makeStream()
        let running = Task {
            defer { continuation.finish() }
            return try await MacOwnedDiagnosticCommand.run(.ping,
                arguments: ["-n", "-c", "100", "127.0.0.1"], timeout: .seconds(10), gate: gate,
                onStart: { continuation.yield($0) })
        }
        var iterator = started.makeAsyncIterator()
        let pid = try #require(await iterator.next())
        #expect(kill(pid, 0) == 0)
        gate.close()
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(waitpid(pid, nil, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @MainActor @Test func explicitTCPChecksDistinguishListeningAndRefused() async throws {
        let listening = try LoopbackSocket(type: SOCK_STREAM)
        let refused = try LoopbackSocket(type: SOCK_STREAM)
        #expect(Darwin.listen(listening.descriptor, 1) == 0)
        let owner = MacManualNetworkOwner()
        #expect(owner.start(.ports("127.0.0.1", [listening.port, refused.port]), locale: Locale(identifier: "en")))
        try #require(await owner.drain(timeout: 10))
        #expect(owner.result == "\(listening.port)  Open\n\(refused.port)  Could not connect")
        withExtendedLifetime((listening, refused)) {}
    }

    @Test func dnsReturnsActualTypedAnswerFromLoopback() async throws {
        let fixture = try LoopbackSocket(type: SOCK_DGRAM)
        async let sent = fixture.answerMX()
        let name = "mailbox.fixture.test"
        let gate = MacManualNetworkGate(request: .dns(name, .mx), lease: .init(ownerID: UUID()))
        let result = try await MacOwnedDiagnosticCommand.run(.dns,
            arguments: ["@127.0.0.1", "-p", String(fixture.port), "-q", name, "-t", "MX",
                        "+noall", "+comments", "+answer", "+time=2", "+tries=1"],
            timeout: .seconds(6), gate: gate)
        #expect(await sent)
        #expect(result.succeeded)
        #expect(result.output.contains("10 mail.mailbox.fixture.test."))
    }
}

private final class LoopbackSocket: @unchecked Sendable {
    let descriptor: Int32
    let port: UInt16

    init(type: Int32) throws {
        let fd = Darwin.socket(AF_INET, type, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { endpoint in
                bind(fd, endpoint, length) == 0 && getsockname(fd, endpoint, &length) == 0
            }
        }
        guard bound, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { Darwin.close(descriptor) }

    func answerMX() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.answerOneMXPacket())
            }
        }
    }

    private func answerOneMXPacket() -> Bool {
        var polled = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&polled, 1, 3_000) == 1 else { return false }
        var query = [UInt8](repeating: 0, count: 1_024)
        let capacity = query.count
        var peer = sockaddr_in()
        var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(descriptor, &query, capacity, 0, $0, &peerLength)
            }
        }
        var end = 12
        while end < count && query[end] > 0 && query[end] <= 63 { end += 1 + Int(query[end]) }
        guard end + 5 <= count, query[end] == 0, query[end + 1] == 0, query[end + 2] == 15 else { return false }
        var reply = [query[0], query[1], 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
        reply.append(contentsOf: query[12..<(end + 5)])
        // MX with a 60-second TTL, priority 10, and a hostname compressed
        // against the question name.
        reply.append(contentsOf: [0xc0, 0x0c, 0, 15, 0, 1, 0, 0, 0, 60, 0, 9,
                                  0, 10, 4, 109, 97, 105, 108, 0xc0, 0x0c])
        return withUnsafePointer(to: peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { endpoint in
                sendto(descriptor, reply, reply.count, 0, endpoint, peerLength) == reply.count
            }
        }
    }
}
