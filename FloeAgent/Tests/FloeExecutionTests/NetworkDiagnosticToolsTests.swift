import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution.NetworkDiagnostics")
struct NetworkDiagnosticToolsTests {

    // MARK: - Remote ping dialect (BSD milliseconds vs iputils seconds)

    @Test("ping -W is seconds on Linux and milliseconds on macOS/BSD targets")
    func pingWaitDialect() {
        #expect(NetworkDiagnosticTiming.pingWaitValue(timeoutSeconds: 3, kind: .linux) == 3)
        #expect(NetworkDiagnosticTiming.pingWaitValue(timeoutSeconds: 3, kind: .openWrt) == 3)
        #expect(NetworkDiagnosticTiming.pingWaitValue(timeoutSeconds: 3, kind: .nas) == 3)
        #expect(NetworkDiagnosticTiming.pingWaitValue(timeoutSeconds: 3, kind: .unknown) == 3)
        #expect(NetworkDiagnosticTiming.pingWaitValue(timeoutSeconds: 3, kind: nil) == 3)
        #expect(NetworkDiagnosticTiming.pingWaitValue(timeoutSeconds: 3, kind: .macOS) == 3000)
        #expect(NetworkDiagnosticTiming.pingWaitValue(timeoutSeconds: 10, kind: .macOS) == 10_000)
        #expect(
            NetworkDiagnosticTiming.pingCommand(target: "192.0.2.1", count: 4, timeoutSeconds: 3, kind: .macOS)
                == "ping -c 4 -W 3000 192.0.2.1"
        )
        #expect(
            NetworkDiagnosticTiming.pingCommand(target: "192.0.2.1", count: 4, timeoutSeconds: 3, kind: .linux)
                == "ping -c 4 -W 3 192.0.2.1"
        )
    }

    @Test("cached target inspection selects the ping dialect")
    func persistedKindLookup() throws {
        let defaults = try #require(UserDefaults(suiteName: "NetworkDiagnosticToolsTests.\(UUID().uuidString)"))
        let hostID = UUID()
        #expect(NetworkDiagnosticTiming.persistedTargetKind(hostID: nil, defaults: defaults) == nil)
        #expect(NetworkDiagnosticTiming.persistedTargetKind(hostID: hostID, defaults: defaults) == nil)
        let inspection = RemoteTargetInspection(
            hostID: hostID, kind: .macOS, vendor: "Apple", operatingSystem: "Darwin",
            containerRuntime: nil, confidence: 0.95, evidence: "Darwin"
        )
        defaults.set(try JSONEncoder().encode(inspection), forKey: SSHCommandService.inspectionCacheKey(hostID: hostID))
        #expect(NetworkDiagnosticTiming.persistedTargetKind(hostID: hostID, defaults: defaults) == .macOS)
    }

    // MARK: - Watchdog budgets

    @Test("ping watchdog covers the send interval plus one final wait")
    func pingWatchdog() {
        #expect(NetworkDiagnosticTiming.pingWatchdogSeconds(count: 4, timeoutSeconds: 3) == 22)
        #expect(NetworkDiagnosticTiming.pingWatchdogSeconds(count: 10, timeoutSeconds: 10) == 35)
        #expect(NetworkDiagnosticTiming.pingWatchdogSeconds(count: 1, timeoutSeconds: 1) == 17)
    }

    @Test("traceroute runs numeric with two probes per hop and a bounded tracepath fallback")
    func tracerouteBudgetAndCommand() {
        #expect(NetworkDiagnosticTiming.tracerouteBudgetSeconds(maxHops: 20, waitSeconds: 2) == 95)
        #expect(NetworkDiagnosticTiming.tracerouteBudgetSeconds(maxHops: 30, waitSeconds: 5) == 315)
        #expect(NetworkDiagnosticTiming.tracerouteBudgetSeconds(maxHops: 1, waitSeconds: 1) == 17)
        let command = NetworkDiagnosticTiming.tracerouteCommand(target: "192.0.2.1", maxHops: 8, waitSeconds: 2)
        #expect(command.contains("traceroute -n -q 2 -m 8 -w 2 192.0.2.1"))
        #expect(command.contains("timeout 47 tracepath -n -m 8 192.0.2.1"))
    }

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

    // MARK: - Tool wiring

    @Test("network.ping runs the injected device pinger without SSH or network")
    func devicePingWiring() async throws {
        let tool = NetworkPingTool(service: nil) { target, count, timeout, _ in
            #expect(target == "example.com")
            #expect(count == 2 && timeout == 1)
            return DevicePingReport(
                target: target, resolvedAddress: "192.0.2.1",
                replies: [
                    .init(sequence: 0, status: .received(rttMs: 12.5)),
                    .init(sequence: 1, status: .timeout)
                ]
            )
        }
        let output = try await tool.execute(
            .init(target: "example.com", hostID: nil, executionTarget: nil, count: 2, timeoutSeconds: 1),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("executionTarget=device"))
        #expect(output.summary.contains("method=icmpPing"))
        #expect(output.summary.contains("rttMs=12.50"))
        #expect(output.summary.contains("lossPercent=50.0"))
    }

    @Test("device ping rejects the device+hostID combination")
    func devicePingValidation() {
        let tool = NetworkPingTool(service: nil)
        #expect(throws: FloeError.self) {
            try tool.validate(.init(target: "example.com", hostID: UUID().uuidString, executionTarget: "device"))
        }
    }

    @Test("device traceroute stays host-only and points at device ping")
    func deviceTracerouteUnavailable() async throws {
        let tool = NetworkTracerouteTool(service: nil)
        do {
            _ = try await tool.execute(
                .init(target: "example.com"),
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
            Issue.record("expected deviceTracerouteUnavailable")
        } catch let FloeError.validationFailed(message) {
            #expect(message.contains("deviceTracerouteUnavailable"))
            #expect(message.contains("network.ping"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
