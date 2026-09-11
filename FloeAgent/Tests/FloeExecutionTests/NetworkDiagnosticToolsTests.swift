import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

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
        // The deadline must win promptly; the leaked sleeper is harmless.
        #expect(Date().timeIntervalSince(started) < 3)
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

    @Test("time-exceeded parsing extracts the embedded echo sequence")
    func timeExceededEmbeddedSequence() {
        // Outer ICMP header (8 bytes) + embedded IPv4 header (20 bytes) +
        // first 8 bytes of the original echo request.
        var packet = Data(count: 8 + 20 + 8)
        packet[0] = DeviceICMPPacket.timeExceededType
        packet[1] = 0
        let ipStart = 8
        packet[ipStart] = 0x45  // IPv4, 5-word header
        let icmpStart = ipStart + 20
        packet[icmpStart] = DeviceICMPPacket.echoRequestType
        packet[icmpStart + 6] = 0x00
        packet[icmpStart + 7] = 0x2A
        #expect(DeviceICMPPacket.parseErrorEmbeddedSequence(packet) == 42)
        // Destination unreachable is accepted too.
        packet[0] = DeviceICMPPacket.destinationUnreachableType
        #expect(DeviceICMPPacket.parseErrorEmbeddedSequence(packet) == 42)
        // An echo reply is not an error envelope.
        packet[0] = DeviceICMPPacket.echoReplyType
        #expect(DeviceICMPPacket.parseErrorEmbeddedSequence(packet) == nil)
        // Truncated payloads are rejected.
        #expect(DeviceICMPPacket.parseErrorEmbeddedSequence(Data([11, 0, 0, 0])) == nil)
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
}
