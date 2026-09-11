// FloeExecution — Device-side ICMP echo (ping).
//
// Uses the Apple SimplePing pattern: socket(AF_INET, SOCK_DGRAM,
// IPPROTO_ICMP) needs no entitlement on iOS — the kernel owns the raw
// socket privileges. All packet build/parse logic is pure and unit-tested
// without touching the network; only `run` opens a real socket.

import Foundation
import Darwin
import FloeCore
import FloeTools

/// Backend signature for device pings. Tests inject a fake so the tool
/// wiring is exercised without real ICMP traffic.
typealias DevicePingHandler = @Sendable (String, Int, Int, CancellationToken) async throws -> DevicePingReport

/// Result of one device-side ICMP echo run.
struct DevicePingReport: Sendable, Equatable {
    enum ReplyStatus: Sendable, Equatable {
        case received(rttMs: Double)
        case timeout
        case unreachable
    }

    struct Reply: Sendable, Equatable {
        var sequence: Int
        var status: ReplyStatus
    }

    var target: String
    var resolvedAddress: String
    var replies: [Reply]

    var receivedRTTs: [Double] {
        replies.compactMap { if case .received(let rtt) = $0.status { return rtt } else { return nil } }
    }

    var lossPercent: Double {
        guard !replies.isEmpty else { return 0 }
        return Double(replies.count - receivedRTTs.count) / Double(replies.count) * 100
    }

    /// Multi-line key=value report, consistent with the other device tools.
    func summaryText() -> String {
        var lines = ["method=icmpPing target=\(target) resolved=\(resolvedAddress)"]
        for reply in replies {
            switch reply.status {
            case .received(let rttMs):
                lines.append(String(format: "reply seq=%d rttMs=%.2f", reply.sequence, rttMs))
            case .timeout:
                lines.append("reply seq=\(reply.sequence) status=timeout")
            case .unreachable:
                lines.append("reply seq=\(reply.sequence) status=unreachable")
            }
        }
        let rtts = receivedRTTs
        var summary = String(format: "summary transmitted=%d received=%d lossPercent=%.1f", replies.count, rtts.count, lossPercent)
        if let minimum = rtts.min(), let maximum = rtts.max() {
            let average = rtts.reduce(0, +) / Double(rtts.count)
            summary += String(format: " rttMs min=%.2f avg=%.2f max=%.2f", minimum, average, maximum)
        }
        lines.append(summary)
        return lines.joined(separator: "\n")
    }
}

/// Pure ICMP echo packet helpers. Received datagram-socket messages start
/// at the ICMP header: the kernel strips the IPv4 header for SOCK_DGRAM.
enum DeviceICMPPacket {
    static let echoRequestType: UInt8 = 8
    static let echoReplyType: UInt8 = 0

    struct EchoReply: Sendable, Equatable {
        var identifier: UInt16
        var sequence: UInt16
        var payload: Data
    }

    /// RFC 1071 one's-complement checksum over big-endian 16-bit words.
    /// The result is in network byte order: store it big-endian. A valid
    /// received packet (checksum field included) checksums to zero.
    static func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = data.startIndex
        while index + 1 < data.endIndex {
            sum += UInt32(data[index]) << 8 | UInt32(data[index + 1])
            sum = (sum & 0xFFFF) + (sum >> 16)
            index += 2
        }
        if index < data.endIndex {
            sum += UInt32(data[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }

    static func buildEchoRequest(identifier: UInt16, sequence: UInt16, payload: Data) -> Data {
        var packet = Data(count: 8 + payload.count)
        packet[0] = echoRequestType
        packet[1] = 0
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xFF)
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)
        packet.replaceSubrange(8..<packet.count, with: payload)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// Returns nil unless `data` is an echo reply with a valid checksum.
    static func parseEchoReply(_ data: Data) -> EchoReply? {
        guard data.count >= 8,
              data[0] == echoReplyType,
              data[1] == 0,
              checksum(data) == 0 else { return nil }
        let identifier = UInt16(data[4]) << 8 | UInt16(data[5])
        let sequence = UInt16(data[6]) << 8 | UInt16(data[7])
        return EchoReply(identifier: identifier, sequence: sequence, payload: data.subdata(in: 8..<data.count))
    }
}

/// Runs genuine ICMP echo requests from this device. The blocking socket
/// work runs on a detached task so the cooperative pool is never parked;
/// cancellation is polled in ≤200 ms receive slices and between probes.
enum DeviceICMPPing {
    static func run(
        target: String,
        count: Int,
        timeoutSeconds: Int,
        cancellation: CancellationToken
    ) async throws -> DevicePingReport {
        // Resolution can also block inside getaddrinfo; bound it like
        // dnsLookup. Only s_addr words cross the task boundary (Sendable).
        let addresses = try await NetworkDiagnosticTiming.withDeadline(
            seconds: 10,
            timeoutMessage: "device ping DNS resolution timed out after 10s"
        ) {
            try resolveIPv4(target)
        }
        guard let sAddr = addresses.first else {
            throw FloeError.validationFailed("device ping supports IPv4 targets only and \(target) has no A record; use executionTarget=host for IPv6")
        }
        try cancellation.throwIfCancelled()
        return try await Task.detached(priority: .utility) {
            try blockingSession(
                target: target,
                sAddr: sAddr,
                count: count,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation
            )
        }.value
    }

    /// Blocking getaddrinfo for A records (datagram ICMPv4 socket). Returns
    /// sin_addr values in network byte order.
    static func resolveIPv4(_ target: String) throws -> [UInt32] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(target, nil, &hints, &result) == 0, let first = result else {
            throw FloeError.validationFailed("Device DNS lookup failed for ping target")
        }
        defer { freeaddrinfo(first) }
        var addresses: [UInt32] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            if current.pointee.ai_family == AF_INET,
               current.pointee.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in>.size) {
                let address = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                addresses.append(address.sin_addr.s_addr)
            }
            cursor = current.pointee.ai_next
        }
        return addresses
    }

    static func addressString(sAddr: UInt32) -> String {
        var address = in_addr(s_addr: sAddr)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    private static func monotonicSeconds() -> TimeInterval {
        var value = timespec()
        clock_gettime(CLOCK_MONOTONIC, &value)
        return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
    }

    private static func blockingSession(
        target: String,
        sAddr: UInt32,
        count: Int,
        timeoutSeconds: Int,
        cancellation: CancellationToken
    ) throws -> DevicePingReport {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            throw FloeError.internalError("device ICMP socket unavailable (errno \(errno))")
        }
        defer { close(fd) }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = 0
        destination.sin_addr = in_addr(s_addr: sAddr)

        let identifier = UInt16.random(in: 1...UInt16.max)
        // A random per-run payload token authenticates replies. The kernel
        // may rewrite the identifier on datagram ICMP sockets, so replies
        // are matched on sequence + payload, not on the identifier.
        let token = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var replies: [DevicePingReport.Reply] = []

        for sequence in 0..<count {
            try cancellation.throwIfCancelled()
            let packet = DeviceICMPPacket.buildEchoRequest(
                identifier: identifier, sequence: UInt16(sequence), payload: token
            )
            let sentAt = monotonicSeconds()
            let sendResult = packet.withUnsafeBytes { buffer in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        sendto(fd, buffer.baseAddress, buffer.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sendResult < 0 {
                let sendError = errno
                guard sendError == EHOSTUNREACH || sendError == ENETUNREACH || sendError == EHOSTDOWN else {
                    throw FloeError.internalError("ICMP send failed (errno \(sendError))")
                }
                replies.append(DevicePingReport.Reply(sequence: sequence, status: .unreachable))
                sleepIntervalRemainder(since: sentAt, isLast: sequence == count - 1, cancellation: cancellation)
                continue
            }
            let reply = try receiveReply(
                fd: fd, sequence: UInt16(sequence), token: token,
                sentAt: sentAt, timeoutSeconds: timeoutSeconds, cancellation: cancellation
            )
            replies.append(reply)
            sleepIntervalRemainder(since: sentAt, isLast: sequence == count - 1, cancellation: cancellation)
        }
        return DevicePingReport(target: target, resolvedAddress: addressString(sAddr: sAddr), replies: replies)
    }

    /// Waits up to `timeoutSeconds` for the matching echo reply, ignoring
    /// unrelated ICMP traffic. The SO_RCVTIMEO slice stays at or below
    /// 200 ms so cancellation remains responsive.
    private static func receiveReply(
        fd: Int32,
        sequence: UInt16,
        token: Data,
        sentAt: TimeInterval,
        timeoutSeconds: Int,
        cancellation: CancellationToken
    ) throws -> DevicePingReport.Reply {
        let deadline = sentAt + TimeInterval(timeoutSeconds)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let remaining = deadline - monotonicSeconds()
            if remaining <= 0 { return DevicePingReport.Reply(sequence: Int(sequence), status: .timeout) }
            var slice = timeval(
                tv_sec: Int(min(remaining, 0.2)),
                tv_usec: suseconds_t((min(remaining, 0.2) - TimeInterval(Int(min(remaining, 0.2)))) * 1_000_000)
            )
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &slice, socklen_t(MemoryLayout<timeval>.size))
            let received = recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
            if received > 0 {
                let message = Data(buffer.prefix(received))
                if let reply = DeviceICMPPacket.parseEchoReply(message),
                   reply.sequence == sequence, reply.payload == token {
                    let rttMs = (monotonicSeconds() - sentAt) * 1000
                    return DevicePingReport.Reply(sequence: Int(sequence), status: .received(rttMs: rttMs))
                }
                continue  // stale or foreign ICMP traffic: keep waiting
            }
            switch errno {
            case EAGAIN, EINTR:  // EWOULDBLOCK == EAGAIN on Darwin
                try cancellation.throwIfCancelled()
                continue
            case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN:
                return DevicePingReport.Reply(sequence: Int(sequence), status: .unreachable)
            default:
                return DevicePingReport.Reply(sequence: Int(sequence), status: .timeout)
            }
        }
    }

    /// Probes go out at a fixed 1 s interval; slept in small slices so a
    /// cancellation request is honored between probes.
    private static func sleepIntervalRemainder(since sentAt: TimeInterval, isLast: Bool, cancellation: CancellationToken) {
        guard !isLast else { return }
        while monotonicSeconds() - sentAt < 1.0 {
            if cancellation.isCancelled { return }
            usleep(20_000)
        }
    }
}
