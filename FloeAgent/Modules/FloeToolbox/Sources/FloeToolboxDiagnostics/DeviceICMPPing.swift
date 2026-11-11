// Adapted from FloeExecution; kept standalone for bounded component qualification.
// FloeExecution — Device-side ICMP echo (ping).
//
// Uses the Apple SimplePing pattern: socket(AF_INET, SOCK_DGRAM,
// IPPROTO_ICMP) needs no entitlement on iOS — the kernel owns the raw
// socket privileges. All packet build/parse logic is pure and unit-tested
// without touching the network; only `run` opens a real socket.

import Foundation
import Darwin

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

/// Pure ICMP helpers. Darwin can deliver an IPv4 header even for SOCK_DGRAM;
/// Apple SimplePing also removes this header before validating ICMP.
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

    /// Darwin may deliver either a complete IPv4 datagram or only its ICMP
    /// payload. This is the same framing accepted by the toolbox diagnostics.
    static func icmpPayload(_ raw: Data) -> Data? {
        guard let first = raw.first else { return nil }
        if first >> 4 != 4 { return Data(raw) }
        let headerLength = Int(first & 0x0f) * 4
        guard headerLength >= 20, raw.count >= headerLength + 8,
              raw[raw.startIndex + 9] == UInt8(IPPROTO_ICMP) else { return nil }
        return Data(raw.dropFirst(headerLength))
    }

    /// Returns nil unless the ICMP payload is an echo reply with a valid checksum.
    static func parseEchoReply(_ raw: Data) -> EchoReply? {
        guard let data = icmpPayload(raw) else { return nil }
        guard data.count >= 8,
              data[0] == echoReplyType,
              data[1] == 0,
              checksum(data) == 0 else { return nil }
        let identifier = UInt16(data[4]) << 8 | UInt16(data[5])
        let sequence = UInt16(data[6]) << 8 | UInt16(data[7])
        return EchoReply(identifier: identifier, sequence: sequence, payload: data.subdata(in: 8..<data.count))
    }

    static let timeExceededType: UInt8 = 11
    static let destinationUnreachableType: UInt8 = 3

    struct EmbeddedError: Sendable, Equatable {
        var type: UInt8
        var code: UInt8
        var identifier: UInt16
        var sequence: UInt16
        var destination: Data
        var quotedPayload: Data
        func matches(identifier: UInt16, sequence: UInt16, destination: UInt32, token: Data) -> Bool {
            var address = destination
            let target = withUnsafeBytes(of: &address) { Data($0) }
            return self.identifier == identifier && self.sequence == sequence && self.destination == target &&
                quotedPayload.count <= token.count && Data(token.prefix(quotedPayload.count)) == quotedPayload
        }
    }

    /// RFC 792 errors quote the original IPv4 header and at least eight bytes
    /// of its ICMP request. A sequence alone cannot identify a probe from this
    /// unconnected socket: parallel runs start at the same sequence number.
    static func parseEmbeddedError(_ raw: Data) -> EmbeddedError? {
        guard var data = icmpPayload(raw) else { return nil }
        guard data.count >= 8 + 20 + 8,
              data[0] == timeExceededType || data[0] == destinationUnreachableType else { return nil }
        if checksum(data) != 0 {
            // XNU icmp_input validates the wire checksum, then converts the
            // quoted IPv4 ip_len to host order before raw-socket delivery.
            // Restore only that field and still require the full checksum;
            // unrelated damage and foreign probe identities remain rejected.
            data.swapAt(8 + 2, 8 + 3)
            guard checksum(data) == 0 else { return nil }
        }
        let ipStart = 8
        guard data[ipStart] >> 4 == 4 else { return nil }
        let headerLength = Int(data[ipStart] & 0x0F) * 4
        guard headerLength >= 20, data.count >= ipStart + headerLength + 8,
              data[ipStart + 9] == UInt8(IPPROTO_ICMP),
              data[ipStart + 6] & 0x1f == 0, data[ipStart + 7] == 0 else { return nil }
        let icmpStart = ipStart + headerLength
        let originalLength = Int(data[ipStart + 2]) << 8 | Int(data[ipStart + 3])
        guard originalLength >= headerLength + 8,
              data[icmpStart] == echoRequestType, data[icmpStart + 1] == 0 else { return nil }
        let payloadStart = icmpStart + 8
        let payloadEnd = min(data.count, ipStart + originalLength)
        return .init(type:data[0],code:data[1],identifier:UInt16(data[icmpStart + 4]) << 8 | UInt16(data[icmpStart + 5]),
            sequence:UInt16(data[icmpStart + 6]) << 8 | UInt16(data[icmpStart + 7]),
            destination:data.subdata(in:(ipStart + 16)..<(ipStart + 20)),quotedPayload:data.subdata(in:payloadStart..<payloadEnd))
    }
    static func parseErrorEmbeddedSequence(_ raw: Data) -> UInt16? {
        parseEmbeddedError(raw)?.sequence
    }
    static func setReceiveTimeout(fd:Int32,remaining:TimeInterval) throws {
        // A zero timeval disables SO_RCVTIMEO; round a sub-microsecond
        // remainder up so the last receive can never become unbounded.
        var timeout = timeval(tv_sec:0,tv_usec:suseconds_t(max(1,ceil(min(remaining,0.2)*1_000_000))))
        guard setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw DiagnosticError.system("ICMP receive timeout setup failed (errno \(errno))")
        }
    }
}

/// Runs genuine ICMP echo requests from this device. The blocking socket
/// work runs on a Dispatch worker so the cooperative pool is never parked;
/// cancellation is polled in ≤200 ms receive slices and between probes.
enum DeviceICMPPing {
    static func run(
        target: String,
        count: Int,
        timeoutSeconds: Int,
        cancellation: CancellationToken
    ) async throws -> DevicePingReport {
        try cancellation.throwIfCancelled()
        // Resolution can also block inside getaddrinfo; bound it like
        // dnsLookup. Only s_addr words cross the task boundary (Sendable).
        let addresses = try await NetworkDiagnosticTiming.withDeadline(
            seconds: 10,
            timeoutMessage: "device ping DNS resolution timed out after 10s"
        ) {
            try HostResolver.ipv4Addresses(target)
        }
        guard let sAddr = addresses.first else {
            throw DiagnosticError.invalid("device ping supports IPv4 targets only and \(target) has no A record")
        }
        try cancellation.throwIfCancelled()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.utility).async {
                continuation.resume(with:Result { try blockingSession(target:target,sAddr:sAddr,count:count,
                    timeoutSeconds:timeoutSeconds,cancellation:cancellation) })
            }
        }
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
            throw DiagnosticError.system("device ICMP socket unavailable (errno \(errno))")
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
                    throw DiagnosticError.system("ICMP send failed (errno \(sendError))")
                }
                replies.append(DevicePingReport.Reply(sequence: sequence, status: .unreachable))
                sleepIntervalRemainder(since: sentAt, isLast: sequence == count - 1, cancellation: cancellation)
                continue
            }
            let reply = try receiveReply(
                fd: fd, identifier:identifier,destination:sAddr,sequence: UInt16(sequence), token: token,
                sentAt: sentAt, timeoutSeconds: timeoutSeconds, cancellation: cancellation
            )
            replies.append(reply)
            sleepIntervalRemainder(since: sentAt, isLast: sequence == count - 1, cancellation: cancellation)
        }
        return DevicePingReport(target: target, resolvedAddress: HostResolver.presentation(sAddr), replies: replies)
    }

    /// Waits up to `timeoutSeconds` for the matching echo reply, ignoring
    /// unrelated ICMP traffic. The SO_RCVTIMEO slice stays at or below
    /// 200 ms so cancellation remains responsive.
    private static func receiveReply(
        fd: Int32,
        identifier: UInt16,
        destination: UInt32,
        sequence: UInt16,
        token: Data,
        sentAt: TimeInterval,
        timeoutSeconds: Int,
        cancellation: CancellationToken
    ) throws -> DevicePingReport.Reply {
        let deadline = sentAt + TimeInterval(timeoutSeconds)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            try cancellation.throwIfCancelled()
            let remaining = deadline - monotonicSeconds()
            if remaining <= 0 { return DevicePingReport.Reply(sequence: Int(sequence), status: .timeout) }
            try DeviceICMPPacket.setReceiveTimeout(fd:fd,remaining:remaining)
            let received = recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
            if received > 0 {
                let message = Data(buffer.prefix(received))
                if let reply = DeviceICMPPacket.parseEchoReply(message),
                   reply.sequence == sequence, reply.payload == token {
                    let rttMs = (monotonicSeconds() - sentAt) * 1000
                    return DevicePingReport.Reply(sequence: Int(sequence), status: .received(rttMs: rttMs))
                }
                if let error = DeviceICMPPacket.parseEmbeddedError(message),
                   error.type == DeviceICMPPacket.destinationUnreachableType,
                   error.matches(identifier:identifier,sequence:sequence,destination:destination,token:token) {
                    return DevicePingReport.Reply(sequence:Int(sequence),status:.unreachable)
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
                throw DiagnosticError.system("ICMP receive failed (errno \(errno))")
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
