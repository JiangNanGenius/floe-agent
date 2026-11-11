import Foundation
import Darwin
import Testing
import FloeCore
import FloeTools
import FloeToolboxDiagnostics
@testable import FloeExecution

private actor NetworkTraceProgressLog: TaskProgressReporting {
    var updates: [TaskProgressUpdate] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func report(_ update: TaskProgressUpdate) {
        updates.append(update)
        let ready = waiters.filter { updates.count >= $0.0 }
        waiters.removeAll { updates.count >= $0.0 }; ready.forEach { $0.1.resume() }
    }
    func wait(_ count: Int) async {
        if updates.count < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }
}
private actor NetworkTraceToolGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var observer: TracerouteObserver?
    private var requestID = UUID()
    func hold(id: UUID, observer: TracerouteObserver?) async {
        self.observer = observer; self.requestID = id
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let ready = waiting; waiting = []; ready.forEach { $0.resume() }
        }
    }
    func wait() async { if continuation == nil { await withCheckedContinuation { waiting.append($0) } } }
    func open() { continuation?.resume(); continuation = nil }
    func late() async {
        await observer?(.init(requestID: requestID, value: .hop(.init(ttl: 9,
            address: "192.0.2.9", milliseconds: [99], status: .reached))))
    }
}

@Suite("FloeExecution.NetworkDiagnostics")
struct NetworkDiagnosticToolsTests {

    // MARK: - Deadline wrapper (device dnsLookup timeout path)

    @Test("withDeadline returns the operation result before the deadline")
    func deadlineSuccess() async throws {
        let value = try await NetworkDiagnosticTiming.withDeadline(seconds: 5, timeoutMessage: "too slow") {
            42
        }
        #expect(value == 42)
    }

    @Test("withDeadline throws the timeout error when the operation overruns")
    func deadlineTimeout() async throws {
        let started = Date()
        await #expect(throws: FloeError.self) {
            _ = try await NetworkDiagnosticTiming.withDeadline(seconds: 0.2, timeoutMessage: "dns timeout") { () throws -> String in
                Thread.sleep(forTimeInterval: 5)
                return "unreachable"
            }
        }
        // The deadline must win promptly; the owned worker exits after its sleep.
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("Concurrent blocking lookups keep their deadlines responsive")
    func concurrentDeadlines() async {
        let started = ContinuousClock.now
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try await NetworkDiagnosticTiming.withDeadline(seconds: 0.1, timeoutMessage: "timeout") {
                            Thread.sleep(forTimeInterval: 2)
                            return 42
                        }
                        return false
                    } catch { return true }
                }
            }
            for await timedOut in group { #expect(timedOut) }
        }
        #expect(started.duration(to: .now) < .seconds(1.5))
    }

    @Test("withDeadline propagates the operation's own error")
    func deadlineOperationError() async {
        do {
            _ = try await NetworkDiagnosticTiming.withDeadline(seconds: 5, timeoutMessage: "unused") { () throws -> String in
                throw FloeError.validationFailed("Device DNS lookup failed")
            }
            Issue.record("expected the operation error to propagate")
        } catch let FloeError.validationFailed(message) {
            #expect(message == "Device DNS lookup failed")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - ICMP packet build / checksum / parse (pure, no network)

    @Test("ICMP checksum matches the reference vector and handles odd lengths")
    func icmpChecksum() {
        // 0x0001 + 0xf203 + 0xf4f5 + 0xf6f7 folds to 0xddf2; complement 0x220d.
        #expect(DeviceICMPPacket.checksum(Data([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7])) == 0x220d)
        #expect(DeviceICMPPacket.checksum(Data([0x01])) == 0xfeff)
        #expect(DeviceICMPPacket.checksum(Data()) == 0xffff)
    }

    @Test("echo request carries identifier/sequence big-endian and checksums to zero")
    func echoRequestBuild() {
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        let packet = DeviceICMPPacket.buildEchoRequest(identifier: 0x1234, sequence: 0x0007, payload: payload)
        #expect(packet.count == 12)
        #expect(packet[0] == 8 && packet[1] == 0)
        #expect(packet[4] == 0x12 && packet[5] == 0x34)
        #expect(packet[6] == 0x00 && packet[7] == 0x07)
        #expect(packet.subdata(in: 8..<12) == payload)
        #expect(DeviceICMPPacket.checksum(packet) == 0)
    }

    @Test("echo reply parsing validates type and checksum")
    func echoReplyParse() {
        var reply = DeviceICMPPacket.buildEchoRequest(identifier: 0x2222, sequence: 3, payload: Data([1, 2, 3, 4]))
        reply[0] = 0  // retype as echo reply, then fix the checksum
        reply[2] = 0
        reply[3] = 0
        let sum = DeviceICMPPacket.checksum(reply)
        reply[2] = UInt8(sum >> 8)
        reply[3] = UInt8(sum & 0xFF)

        let parsed = DeviceICMPPacket.parseEchoReply(reply)
        #expect(parsed?.identifier == 0x2222)
        #expect(parsed?.sequence == 3)
        #expect(parsed?.payload == Data([1, 2, 3, 4]))

        var corrupted = reply
        corrupted[9] ^= 0xFF
        #expect(DeviceICMPPacket.parseEchoReply(corrupted) == nil)

        var request = reply
        request[0] = 8
        request[2] = 0
        request[3] = 0
        let requestSum = DeviceICMPPacket.checksum(request)
        request[2] = UInt8(requestSum >> 8)
        request[3] = UInt8(requestSum & 0xFF)
        #expect(DeviceICMPPacket.parseEchoReply(request) == nil)  // echo requests are rejected
        #expect(DeviceICMPPacket.parseEchoReply(Data([0, 0, 0])) == nil)  // truncated
    }

    @Test("Darwin complete IPv4 replies and stripped ICMP replies preserve the same identity")
    func ipv4FramingPreservesEchoReply() {
        let payload = Data("per-run authentication token".utf8)
        var reply = DeviceICMPPacket.buildEchoRequest(identifier: 83, sequence: 42, payload: payload)
        reply[0] = DeviceICMPPacket.echoReplyType; reply[2] = 0; reply[3] = 0
        let sum = DeviceICMPPacket.checksum(reply)
        reply[2] = UInt8(sum >> 8); reply[3] = UInt8(sum & 255)
        var ip = Data(count: 24) // Include IPv4 options, not a fixed 20-byte assumption.
        ip[0] = 0x46; ip[9] = 1
        #expect(DeviceICMPPacket.parseEchoReply(ip + reply) == DeviceICMPPacket.parseEchoReply(reply))
        #expect(DeviceICMPPacket.parseEchoReply(ip + reply)?.payload == payload)
        ip[9] = 17
        #expect(DeviceICMPPacket.parseEchoReply(ip + reply) == nil)
        #expect(DeviceICMPPacket.parseEchoReply(Data([0x45, 0, 0])) == nil)
    }

    @Test("time-exceeded parsing extracts the embedded echo sequence")
    func timeExceededEmbeddedSequence() {
        // Outer ICMP header (8 bytes) + embedded IPv4 header (20 bytes) +
        // first 8 bytes of the original echo request.
        var packet = Data(count: 8 + 20 + 8)
        packet[0] = DeviceICMPPacket.timeExceededType
        packet[1] = 0
        let ipStart = 8
        packet[ipStart] = 0x45  // IPv4, 5-word header
        packet[ipStart + 3] = 28
        packet[ipStart + 9] = 1
        let icmpStart = ipStart + 20
        packet[icmpStart] = DeviceICMPPacket.echoRequestType
        packet[icmpStart + 6] = 0x00
        packet[icmpStart + 7] = 0x2A
        let sum = DeviceICMPPacket.checksum(packet)
        packet[2] = UInt8(sum >> 8);packet[3] = UInt8(sum & 255)
        #expect(DeviceICMPPacket.parseErrorEmbeddedSequence(packet) == 42)
        var outerIP = Data(count: 20); outerIP[0] = 0x45; outerIP[9] = 1
        #expect(DeviceICMPPacket.parseErrorEmbeddedSequence(outerIP + packet) == 42)
        // Destination unreachable is accepted too.
        packet[0] = DeviceICMPPacket.destinationUnreachableType
        packet[2] = 0;packet[3] = 0
        let unreachableSum = DeviceICMPPacket.checksum(packet)
        packet[2] = UInt8(unreachableSum >> 8);packet[3] = UInt8(unreachableSum & 255)
        #expect(DeviceICMPPacket.parseErrorEmbeddedSequence(packet) == 42)
        #expect(DeviceICMPPacket.parseEmbeddedError(packet)?.type == DeviceICMPPacket.destinationUnreachableType)
        // An echo reply is not an error envelope.
        packet[0] = DeviceICMPPacket.echoReplyType
        #expect(DeviceICMPPacket.parseErrorEmbeddedSequence(packet) == nil)
        // Truncated payloads are rejected.
        #expect(DeviceICMPPacket.parseErrorEmbeddedSequence(Data([11, 0, 0, 0])) == nil)
    }

    @Test("ICMP errors authenticate the quoted probe and accept inner IPv4 options")
    func embeddedErrorsRetainProbeIdentity() throws {
        let token = Data([1,2,3,4,5,6]),identifier:UInt16 = 0x3847,sequence:UInt16 = 42
        let original = DeviceICMPPacket.buildEchoRequest(identifier:identifier,sequence:sequence,payload:token)
        var packet = Data(count:8+24)
        packet[0] = DeviceICMPPacket.timeExceededType
        packet[8] = 0x46;packet[8+3] = UInt8(24+original.count);packet[8+9] = 1
        packet.replaceSubrange((8+16)..<(8+20),with:[127,0,0,1])
        packet += original.prefix(10) // Header plus a partial quoted payload.
        func seal(_ input:Data)->Data {
            var bytes = input;bytes[2] = 0;bytes[3] = 0
            let sum = DeviceICMPPacket.checksum(bytes)
            bytes[2] = UInt8(sum >> 8);bytes[3] = UInt8(sum & 255);return bytes
        }
        packet = seal(packet)
        let parsed = try #require(DeviceICMPPacket.parseEmbeddedError(packet))
        var address:UInt32 = 0
        #expect(inet_pton(AF_INET,"127.0.0.1",&address) == 1)
        #expect(parsed.matches(identifier:identifier,sequence:sequence,destination:address,token:token))
        #expect(!parsed.matches(identifier:identifier+1,sequence:sequence,destination:address,token:token))
        #expect(!parsed.matches(identifier:identifier,sequence:sequence+1,destination:address,token:token))
        #expect(!parsed.matches(identifier:identifier,sequence:sequence,destination:0,token:token))
        #expect(!parsed.matches(identifier:identifier,sequence:sequence,destination:address,token:Data([9,2,3,4,5,6])))
        var damaged = packet;damaged[damaged.count-1] ^= 1
        #expect(DeviceICMPPacket.parseEmbeddedError(damaged) == nil)
        var wrongProtocol = packet;wrongProtocol[8+9] = 17
        #expect(DeviceICMPPacket.parseEmbeddedError(seal(wrongProtocol)) == nil)
        var fragment = packet;fragment[8+7] = 1
        #expect(DeviceICMPPacket.parseEmbeddedError(seal(fragment)) == nil)
        var notRequest = packet;notRequest[8+24] = 0
        #expect(DeviceICMPPacket.parseEmbeddedError(seal(notRequest)) == nil)
    }

    // MARK: - Device ping report formatting

    @Test("device ping report summarizes RTT stats and loss")
    func pingReportSummary() {
        let report = DevicePingReport(
            target: "example.com", resolvedAddress: "192.0.2.1",
            replies: [
                .init(sequence: 0, status: .received(rttMs: 10.0)),
                .init(sequence: 1, status: .received(rttMs: 20.0)),
                .init(sequence: 2, status: .timeout),
                .init(sequence: 3, status: .unreachable)
            ]
        )
        let text = report.summaryText()
        #expect(text.contains("method=icmpPing target=example.com resolved=192.0.2.1"))
        #expect(text.contains("reply seq=0 rttMs=10.00"))
        #expect(text.contains("reply seq=2 status=timeout"))
        #expect(text.contains("reply seq=3 status=unreachable"))
        #expect(text.contains("transmitted=4 received=2 lossPercent=50.0"))
        #expect(text.contains("rttMs min=10.00 avg=15.00 max=20.00"))
    }

    @Test("device traceroute report lists hop addresses and RTTs")
    func tracerouteReportSummary() {
        let report = DeviceTracerouteReport(
            target: "example.com", resolvedAddress: "192.0.2.9", maxHops: 8,
            hops: [
                .init(ttl: 1, status: .timeExceeded(address: "192.168.1.1", rtts: [1.5, 1.7])),
                .init(ttl: 2, status: .timeout),
                .init(ttl: 3, status: .reached(rtts: [12.25]))
            ]
        )
        let text = report.summaryText()
        #expect(text.contains("method=icmpTraceroute target=example.com resolved=192.0.2.9"))
        #expect(text.contains("hop ttl=1 address=192.168.1.1 rttMs=1.50,1.70"))
        #expect(text.contains("hop ttl=2 status=timeout"))
        #expect(text.contains("hop ttl=3 address=192.0.2.9 rttMs=12.25"))
        #expect(text.contains("summary hops=3 reached=true"))
    }

    // MARK: - Tool wiring (no SSH, no real network)

    @Test("network.ping runs the injected device pinger without SSH or network")
    func devicePingWiring() async throws {
        let tool = NetworkPingTool(devicePinger: { target, count, timeout, _ in
            #expect(target == "example.com")
            #expect(count == 2 && timeout == 1)
            return DevicePingReport(
                target: target, resolvedAddress: "192.0.2.1",
                replies: [
                    .init(sequence: 0, status: .received(rttMs: 12.5)),
                    .init(sequence: 1, status: .timeout)
                ]
            )
        })
        let output = try await tool.execute(
            .init(target: "example.com", count: 2, timeoutSeconds: 1),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("executionTarget=device"))
        #expect(output.summary.contains("method=icmpPing"))
        #expect(output.summary.contains("rttMs=12.50"))
        #expect(output.summary.contains("lossPercent=50.0"))
    }

    @Test("network.traceroute runs the injected device tracer without SSH or network")
    func deviceTracerouteWiring() async throws {
        let tool = NetworkTracerouteTool(deviceTracer: { target, maxHops, wait, _ in
            #expect(target == "example.com")
            #expect(maxHops == 8 && wait == 1)
            return DeviceTracerouteReport(
                target: target, resolvedAddress: "192.0.2.9", maxHops: maxHops,
                hops: [
                    .init(ttl: 1, status: .timeExceeded(address: "192.168.1.1", rtts: [2.0])),
                    .init(ttl: 2, status: .reached(rtts: [9.5]))
                ]
            )
        })
        let output = try await tool.execute(
            .init(target: "example.com", maxHops: 8, timeoutSeconds: 1),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("method=icmpTraceroute"))
        #expect(output.summary.contains("hop ttl=1 address=192.168.1.1"))
        #expect(output.summary.contains("reached=true"))
    }

    @Test("network diagnostic tools declare no remote-host dependency")
    func deviceOnlyDescriptors() {
        #expect(!NetworkPingTool.requiresHostScope)
        #expect(!NetworkTracerouteTool.requiresHostScope)
        #expect(!NetworkDNSLookupTool.requiresHostScope)
        #expect(!NetworkTCPProbeTool.requiresHostScope)
        for labels in [NetworkPingTool.riskLabels, NetworkTracerouteTool.riskLabels,
                       NetworkDNSLookupTool.riskLabels, NetworkTCPProbeTool.riskLabels] {
            #expect(labels.contains(.networkAccess))
            #expect(!labels.contains(.executesRemoteCommand))
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func tracerouteReportsActualHopBeforeFinalOutputWithoutInventedFraction() async throws {
        let log = NetworkTraceProgressLog(), gate = NetworkTraceToolGate()
        let tool = NetworkTracerouteTool(observingDeviceTracer: { target, cap, _, token, id, observer in
            await observer?(.init(requestID: id, value: .resolved(address: "192.0.2.9")))
            await observer?(.init(requestID: id, value: .hop(.init(ttl: 1,
                address: "192.0.2.1", milliseconds: [1, 2], status: .intermediate))))
            await gate.hold(id: id, observer: observer)
            try token.throwIfCancelled()
            await observer?(.init(requestID: id, value: .hop(.init(ttl: 2,
                address: nil, milliseconds: [], status: .timeout))))
            return .init(target: target, resolvedAddress: "192.0.2.9", maxHops: cap,
                hops: [.init(ttl: 1, status: .timeExceeded(address: "192.0.2.1", rtts: [1, 2])),
                       .init(ttl: 2, status: .timeout)])
        })
        let args = try JSONDecoder().decode(NetworkTracerouteTool.Arguments.self,
            from: Data(#"{"target":"fixture.example","maxHops":4}"#.utf8))
        let result = Task { try await tool.execute(args,
            context: .init(runID: UUID(), cancellation: CancellationToken(), taskProgress: log)) }
        await gate.wait(); await log.wait(2)
        let first = await log.updates
        #expect(first.count == 2 && first[1].diagnostic?.ttl == 1)
        #expect(first.allSatisfy { $0.totalUnits == nil && $0.fraction == nil && $0.note == nil })
        await gate.open()
        let output = try await result.value
        #expect(output.summary.contains("executionTarget=device\nmethod=icmpTraceroute target=fixture.example"))
        #expect(output.summary.contains("hop ttl=2 status=timeout"))
        #expect(output.summary.contains("summary hops=2 reached=false"))
        #expect(await log.updates.count == 3)
        await gate.late() // the old callback actually executes after tool return
        #expect(await log.updates.count == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledTracerouteDoesNotPublishLateProgressOrSuccess() async throws {
        let log = NetworkTraceProgressLog(), gate = NetworkTraceToolGate(), token = CancellationToken()
        let tool = NetworkTracerouteTool(observingDeviceTracer: { _, _, _, cancellation, id, observer in
            await observer?(.init(requestID: id, value: .resolved(address: "192.0.2.9")))
            await gate.hold(id: id, observer: observer)
            try cancellation.throwIfCancelled()
            return .init(target: "fixture.example", resolvedAddress: "192.0.2.9", maxHops: 4, hops: [])
        })
        let args = try JSONDecoder().decode(NetworkTracerouteTool.Arguments.self, from: Data(#"{"target":"fixture.example"}"#.utf8))
        let result = Task { try await tool.execute(args, context: .init(runID: UUID(), cancellation: token, taskProgress: log)) }
        await gate.wait(); token.cancel(); await gate.late(); await gate.open()
        if case .success = await result.result { Issue.record("Cancelled traceroute returned success") }
        #expect(await log.updates.count == 1)
        #expect(TaskDiagnosticProgress(requestID: UUID(), status: .intermediate, ttl: 0, address: "192.0.2.1") == nil)
        #expect(TaskDiagnosticProgress(requestID: UUID(), status: .intermediate, ttl: 1, milliseconds: [.nan]) == nil)
    }

    @Test func tracerouteDefaultToolUsesActualNativeLoopbackObservations() async throws {
        let log = NetworkTraceProgressLog()
        let arguments = try JSONDecoder().decode(NetworkTracerouteTool.Arguments.self,
            from: Data(#"{"target":"127.0.0.1","maxHops":2,"timeoutSeconds":1}"#.utf8))
        let output = try await NetworkTracerouteTool().execute(arguments,
            context: .init(runID: UUID(), cancellation: CancellationToken(), taskProgress: log))
        #expect(output.exitStatus == 0 && output.summary.contains("reached=true"))
        #expect(await log.updates.compactMap(\.diagnostic?.status) == [.resolved, .reached])
    }

}


@Suite("Darwin ICMP error framing", .serialized)
struct DarwinICMPErrorTests {
    private let identifier: UInt16 = 0x3847
    private let sequence: UInt16 = 42
    private let token = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
    private var destination: UInt32 {
        Data([203, 0, 113, 8]).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
    private func sealed(_ value: Data) -> Data {
        var data = value; data[2] = 0; data[3] = 0
        let sum = DeviceICMPPacket.checksum(data)
        data[2] = UInt8(sum >> 8); data[3] = UInt8(sum & 255)
        return data
    }
    private func wireError(type: UInt8 = 11, headerLength: Int = 24, quoteBytes: Int = 12) -> Data {
        let request = DeviceICMPPacket.buildEchoRequest(identifier: identifier, sequence: sequence, payload: token)
        var data = Data(count: 8 + headerLength)
        data[0] = type; data[8] = 0x40 | UInt8(headerLength / 4)
        data[10] = UInt8((headerLength + request.count) >> 8)
        data[11] = UInt8((headerLength + request.count) & 255)
        data[17] = 1
        data.replaceSubrange(24..<28, with: [203, 0, 113, 8])
        data += request.prefix(quoteBytes)
        return sealed(data)
    }
    private func darwinDelivered(_ wire: Data) -> Data {
        // XNU icmp_input validates the wire checksum, then NTOHS(ip_len)
        // in the quoted IPv4 header before delivering to the raw listener.
        var data = wire; data.swapAt(10, 11); return data
    }

    @Test func hostOrderQuotedLengthRestoresWireChecksumWithoutRelaxingIdentity() throws {
        let wire = wireError(), delivered = darwinDelivered(wire)
        #expect(DeviceICMPPacket.checksum(wire) == 0)
        #expect(DeviceICMPPacket.checksum(delivered) != 0)
        let expected = try #require(DeviceICMPPacket.parseEmbeddedError(wire))
        let parsed = try #require(DeviceICMPPacket.parseEmbeddedError(delivered))
        #expect(parsed == expected)
        #expect(parsed.matches(identifier: identifier, sequence: sequence, destination: destination, token: token))
        #expect(!parsed.matches(identifier: identifier + 1, sequence: sequence, destination: destination, token: token))
        #expect(!parsed.matches(identifier: identifier, sequence: sequence + 1, destination: destination, token: token))
        #expect(!parsed.matches(identifier: identifier, sequence: sequence, destination: 0, token: token))
        #expect(!parsed.matches(identifier: identifier, sequence: sequence, destination: destination, token: Data(repeating: 9, count: 16)))
        var outer = Data(count: 24); outer[0] = 0x46; outer[9] = 1
        #expect(DeviceICMPPacket.parseEmbeddedError(outer + delivered) == expected)
    }

    @Test func minimumQuotedHeadersMatchOnlyTheirExactProbeForBothErrorTypes() throws {
        for type in [DeviceICMPPacket.timeExceededType, DeviceICMPPacket.destinationUnreachableType] {
            let delivered = darwinDelivered(wireError(type: type, headerLength: 20, quoteBytes: 8))
            let parsed = try #require(DeviceICMPPacket.parseEmbeddedError(delivered))
            #expect(parsed.type == type && parsed.quotedPayload.isEmpty)
            #expect(parsed.matches(identifier: identifier, sequence: sequence, destination: destination, token: token))
            #expect(!parsed.matches(identifier: identifier + 1, sequence: sequence, destination: destination, token: token))
        }
    }

    @Test func normalizationStillRejectsCorruptionFragmentsAndForeignPacketShapes() {
        let wire = wireError()
        var damaged = darwinDelivered(wire); damaged[damaged.count - 1] ^= 1
        #expect(DeviceICMPPacket.parseEmbeddedError(damaged) == nil)
        var wrongProtocol = wire; wrongProtocol[17] = 17
        #expect(DeviceICMPPacket.parseEmbeddedError(darwinDelivered(sealed(wrongProtocol))) == nil)
        var fragment = wire; fragment[14] = 1
        #expect(DeviceICMPPacket.parseEmbeddedError(darwinDelivered(sealed(fragment))) == nil)
        var notEcho = wire; notEcho[8 + 24] = DeviceICMPPacket.echoReplyType
        #expect(DeviceICMPPacket.parseEmbeddedError(darwinDelivered(sealed(notEcho))) == nil)
        var badLength = wire; badLength[10] = 0; badLength[11] = 20
        #expect(DeviceICMPPacket.parseEmbeddedError(darwinDelivered(sealed(badLength))) == nil)
        #expect(DeviceICMPPacket.parseEmbeddedError(Data(darwinDelivered(wire).prefix(35))) == nil)
    }
}
