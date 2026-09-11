// FloeExecution — Device-side ICMP traceroute.
//
// Uses the same unprivileged datagram ICMP socket as DeviceICMPPing. The
// socket is intentionally NOT connected: on XNU an unconnected ICMP datagram
// socket receives every ICMP message delivered by `rip_input`, including the
// router "time exceeded" errors that carry the intermediate hop address, and
// `icmp_dgram_ctloutput` allows `IP_TTL` per probe. No entitlement is needed.
//
// All packet build/parse logic is pure and unit-tested without networking;
// only `run` opens a real socket.

import Foundation
import Darwin
import FloeCore
import FloeTools

/// Backend signature for device traceroutes. Tests inject a fake.
typealias DeviceTracerouteHandler = @Sendable (String, Int, Int, CancellationToken) async throws -> DeviceTracerouteReport

struct DeviceTracerouteReport: Sendable, Equatable {
    enum HopStatus: Sendable, Equatable {
        case reached(rtts: [Double])
        case timeExceeded(address: String, rtts: [Double])
        case timeout
        case unreachable(String)
    }

    struct Hop: Sendable, Equatable {
        var ttl: Int
        var status: HopStatus
    }

    var target: String
    var resolvedAddress: String
    var maxHops: Int
    var hops: [Hop]

    var reachedTarget: Bool {
        if case .reached = hops.last?.status { return true }
        return false
    }

    func summaryText() -> String {
        var lines = ["method=icmpTraceroute target=\(target) resolved=\(resolvedAddress) maxHops=\(maxHops)"]
        for hop in hops {
            switch hop.status {
            case .reached(let rtts):
                lines.append(String(format: "hop ttl=%d address=%@ rttMs=%@", hop.ttl, resolvedAddress, Self.rttList(rtts)))
            case .timeExceeded(let address, let rtts):
                lines.append(String(format: "hop ttl=%d address=%@ rttMs=%@", hop.ttl, address, Self.rttList(rtts)))
            case .timeout:
                lines.append("hop ttl=\(hop.ttl) status=timeout")
            case .unreachable(let reason):
                lines.append("hop ttl=\(hop.ttl) status=unreachable reason=\(reason)")
            }
        }
        lines.append("summary hops=\(hops.count) reached=\(reachedTarget)")
        return lines.joined(separator: "\n")
    }

    private static func rttList(_ rtts: [Double]) -> String {
        rtts.isEmpty ? "none" : rtts.map { String(format: "%.2f", $0) }.joined(separator: ",")
    }
}

enum DeviceICMPTraceroute {
    static func run(
        target: String,
        maxHops: Int,
        waitSeconds: Int,
        cancellation: CancellationToken
    ) async throws -> DeviceTracerouteReport {
        let addresses = try await NetworkDiagnosticTiming.withDeadline(
            seconds: 10,
            timeoutMessage: "device traceroute DNS resolution timed out after 10s"
        ) {
            try DeviceICMPPing.resolveIPv4(target)
        }
        guard let sAddr = addresses.first else {
            throw FloeError.validationFailed("device traceroute supports IPv4 targets only and \(target) has no A record")
        }
        try cancellation.throwIfCancelled()
        return try await Task.detached(priority: .utility) {
            try blockingSession(
                target: target,
                sAddr: sAddr,
                maxHops: max(1, min(30, maxHops)),
                waitSeconds: max(1, min(5, waitSeconds)),
                cancellation: cancellation
            )
        }.value
    }

    private static func monotonicSeconds() -> TimeInterval {
        var value = timespec()
        clock_gettime(CLOCK_MONOTONIC, &value)
        return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
    }

    private static func blockingSession(
        target: String,
        sAddr: UInt32,
        maxHops: Int,
        waitSeconds: Int,
        cancellation: CancellationToken
    ) throws -> DeviceTracerouteReport {
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
        let token = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var hops: [DeviceTracerouteReport.Hop] = []
        var nextSequence: UInt16 = 0
        let probesPerHop = 2

        for ttl in 1...maxHops {
            try cancellation.throwIfCancelled()
            var ttlValue = Int32(ttl)
            setsockopt(fd, IPPROTO_IP, IP_TTL, &ttlValue, socklen_t(MemoryLayout<Int32>.size))

            var rtts: [Double] = []
            var hopStatus: DeviceTracerouteReport.HopStatus?
            for _ in 0..<probesPerHop {
                try cancellation.throwIfCancelled()
                let sequence = nextSequence
                nextSequence &+= 1
                let packet = DeviceICMPPacket.buildEchoRequest(
                    identifier: identifier, sequence: sequence, payload: token
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
                        throw FloeError.internalError("ICMP traceroute send failed (errno \(sendError))")
                    }
                    hopStatus = .unreachable("sendErrno=\(sendError)")
                    continue
                }
                let outcome = try receiveProbe(
                    fd: fd,
                    sequence: sequence,
                    token: token,
                    sentAt: sentAt,
                    timeoutSeconds: waitSeconds,
                    cancellation: cancellation
                )
                switch outcome {
                case .echoReply(let rttMs):
                    rtts.append(rttMs)
                    hopStatus = .reached(rtts: rtts)
                case .timeExceeded(let address, let rttMs):
                    rtts.append(rttMs)
                    if case .reached = hopStatus {} else {
                        hopStatus = .timeExceeded(address: address, rtts: rtts)
                    }
                case .timeout:
                    if hopStatus == nil { hopStatus = .timeout }
                }
                if case .reached = hopStatus { break }
            }
            hops.append(.init(ttl: ttl, status: hopStatus ?? .timeout))
            if case .reached = hopStatus { break }
        }
        return DeviceTracerouteReport(
            target: target,
            resolvedAddress: DeviceICMPPing.addressString(sAddr: sAddr),
            maxHops: maxHops,
            hops: hops
        )
    }

    private enum ProbeOutcome {
        case echoReply(rttMs: Double)
        case timeExceeded(address: String, rttMs: Double)
        case timeout
    }

    /// Waits up to `timeoutSeconds` for a reply to this probe, ignoring
    /// unrelated ICMP traffic. The receive slice stays ≤200 ms so
    /// cancellation remains responsive.
    private static func receiveProbe(
        fd: Int32,
        sequence: UInt16,
        token: Data,
        sentAt: TimeInterval,
        timeoutSeconds: Int,
        cancellation: CancellationToken
    ) throws -> ProbeOutcome {
        let deadline = sentAt + TimeInterval(timeoutSeconds)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let remaining = deadline - monotonicSeconds()
            if remaining <= 0 { return .timeout }
            let slice = min(remaining, 0.2)
            var timeout = timeval(
                tv_sec: Int(slice),
                tv_usec: suseconds_t((slice - TimeInterval(Int(slice))) * 1_000_000)
            )
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(fd, &buffer, buffer.count, 0, sockaddrPointer, &sourceLength)
                }
            }
            if received > 0 {
                let message = Data(buffer.prefix(received))
                if let reply = DeviceICMPPacket.parseEchoReply(message),
                   reply.sequence == sequence, reply.payload == token {
                    return .echoReply(rttMs: (monotonicSeconds() - sentAt) * 1000)
                }
                if let embedded = DeviceICMPPacket.parseErrorEmbeddedSequence(message),
                   embedded == sequence {
                    let address = source.sin_addr
                    var addressValue = in_addr(s_addr: address.s_addr)
                    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addressValue, &text, socklen_t(INET_ADDRSTRLEN))
                    return .timeExceeded(
                        address: String(cString: text),
                        rttMs: (monotonicSeconds() - sentAt) * 1000
                    )
                }
                continue
            }
            switch errno {
            case EAGAIN, EINTR:
                try cancellation.throwIfCancelled()
                continue
            case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN:
                return .timeout
            default:
                return .timeout
            }
        }
    }
}
