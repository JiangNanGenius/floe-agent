// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxDiagnostics
@testable import FloeMacNetwork

private actor DelayedRunner: MacManualNetworkRunning {
    private var continuation: CheckedContinuation<String, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered = 0
    private(set) var stopCount = 0
    func execute() async throws -> String {
        entered += 1; waiting?.resume(); waiting = nil
        return await withCheckedContinuation { continuation = $0 }
    }
    func stop() async { stopCount += 1 }
    func waitUntilEntered(_ count: Int = 1) async {
        if entered >= count { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finish(_ value: String) { continuation?.resume(returning: value); continuation = nil }
}

private actor StopGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func stop() async {
        calls += 1; entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForStop() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor FakeDiagnosticTransport: MacDiagnosticTransport {
    nonisolated let supportsLANDiscovery = false
    private let gate: StopGate
    private(set) var pingCount = 0
    init(gate: StopGate) { self.gate = gate }
    func ping(target: String, count: Int, timeoutSeconds: Int) async throws -> [MacPingObservation] {
        pingCount += 1; return []
    }
    func traceroute(target: String, maximumHops: Int, timeoutSeconds: Int, requestID: UUID,
                    onObservation: TracerouteObserver?) async throws -> [TraceHop] { [] }
    func dns(name: String, type: DNSRecordType, timeout: Double) async throws -> [DNSRecord] { [] }
    func ports(target: String, ports: [UInt16], timeout: Double) async throws -> [MacPortObservation] { [] }
    func discover(type: String, seconds: Double) async throws -> [MacBonjourService] { [] }
    func lanScan(types: [String], seconds: Double,
                 onEvent: (@Sendable (LANDiscoveryEvent) -> Void)?) async throws -> LANScanReport {
        throw ToolboxError.denied
    }
    func stop() async { await gate.stop() }
}

private actor CompletionFlag {
    private(set) var finished = false
    func mark() { finished = true }
}

private actor PermissionGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<MacWiFiPermissionSnapshot, Never>?
    func permission() async -> MacWiFiPermissionSnapshot {
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        return await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(returning: .unknown); releaseWaiter = nil }
}

@MainActor private final class ReadCounter { var value = 0 }

@Suite("User-owned manual network session")
@MainActor struct MacManualNetworkTests {
    @Test func exactRequestAndLeaseAreRequired() {
        let lease = SessionLease(ownerID: UUID())
        let gate = MacManualNetworkGate(request: .ports("example.test", [443]), lease: lease)
        #expect(gate.allows(lease, "example.test", .ports([443])))
        #expect(!gate.allows(lease, "other.test", .ports([443])))
        #expect(!gate.allows(lease, "example.test", .ports([80])))
        #expect(!gate.allows(SessionLease(ownerID: UUID()), "example.test", .ports([443])))
        gate.close()
        #expect(!gate.allows(lease, "example.test", .ports([443])))
    }

    @Test func unconnectedCommunicationToolsStayUnavailable() {
        for tool in [ToolboxTool.serialAssistant, .http, .webSocket, .mqtt] {
            guard let capability = MacToolboxCapabilityMatrix.capability(for: tool) else {
                Issue.record("Missing capability status")
                continue
            }
            if case .unavailable = capability.availability {} else {
                Issue.record("Unconnected tool was reported available: \(tool.rawValue)")
            }
        }
    }

    @Test func roamingReportsOnlyConsecutiveChangesWithKnownAccessPoints() {
        func accessPoint(_ bssid: String) -> MacWiFiObservation {
            MacWiFiObservation(status: .wifi, ssid: "Fixture", bssid: bssid,
                signalDBM: -64, identityState: .observed, permission: .unknown)
        }
        let unreadable = MacWiFiObservation(status: .wifi, bssid: "not readable",
            identityState: .permissionRequired, permission: .unknown)
        let rows = MacManualNetworkFormatting.roaming([
            (0, accessPoint("00:11:22:33:44:55")),
            (2, unreadable),
            (4, accessPoint("00:11:22:33:44:66")),
            (6, accessPoint("00:11:22:33:44:77")),
        ], locale: Locale(identifier: "en")).split(separator: "\n")
        #expect(!rows[1].contains("not readable"))
        #expect(rows[1].contains("Location permission"))
        #expect(!rows[2].contains("Access point changed"))
        #expect(rows[3].contains("Access point changed"))
    }

    @Test func statusTextIsBilingualAndKeepsUnknownStatesHonest() {
        let zh = Locale(identifier: "zh_Hans"), en = Locale(identifier: "en_US")
        let timedOut = MacPingObservation(sequence: 1, address: "192.0.2.1", status: .timeout)
        #expect(MacManualNetworkFormatting.ping(timedOut, locale: zh).contains("超时"))
        #expect(MacManualNetworkFormatting.ping(timedOut, locale: en).contains("Timed out"))
        let failedPort = MacPortObservation(port: 443, isOpen: false, elapsedMilliseconds: 10)
        #expect(MacManualNetworkFormatting.port(failedPort, locale: zh).contains("未能连接"))
        #expect(MacManualNetworkFormatting.port(failedPort, locale: en).contains("Could not connect"))
        let wifi = MacWiFiObservation(status: .wifi, identityState: .permissionRequired, permission: .unknown)
        #expect(MacManualNetworkFormatting.wifi(wifi, locale: zh).contains("定位权限"))
        #expect(MacManualNetworkFormatting.wifi(wifi, locale: en).contains("Location permission"))
        let report = LANScanReport(services: [], browsedTypes: [], rejectedTypes: [],
            status: .permissionUncertain, notes: [], truncated: false, unresolvedCount: 0, elapsedSeconds: 1)
        #expect(MacManualNetworkFormatting.lan(report, locale: zh).contains("无法确认"))
        #expect(MacManualNetworkFormatting.lan(report, locale: en).contains("could not be confirmed"))
    }

    @Test func quitWaitsForLateWorkAndDiscardsItsResult() async {
        let runner = DelayedRunner()
        let owner = MacManualNetworkOwner(makeRunner: { _, _, _ in runner })
        #expect(owner.startOwnedOperation(.ping("fixture.test")))
        await runner.waitUntilEntered()
        owner.closeAdmissions()
        #expect(!owner.startOwnedOperation(.dns("fixture.test")))
        #expect(!(await owner.drain(timeout: 0.05)))
        await runner.finish("late result")
        #expect(await owner.drain(timeout: 2))
        #expect(owner.result == nil)
        #expect(!owner.running)
        #expect(await runner.stopCount > 0)
        owner.resumeAfterCancelledTermination()
        #expect(owner.startOwnedOperation(.dns("fixture.test")))
        await runner.waitUntilEntered(2)
        await runner.finish("new result")
        #expect(await owner.drain(timeout: 2))
        #expect(owner.result == "new result")
    }

    @Test func lanStaysClosedUntilSystemWorkersAreOwned() {
        let owner = MacManualNetworkOwner()
        #expect(!owner.start(.lan))
        #expect(!owner.running)
    }

    @Test func cancelledPermissionWaitCannotStartWiFiRead() async {
        let lease = SessionLease(ownerID: UUID())
        let gate = MacManualNetworkGate(request: .wifi, lease: lease)
        let permission = PermissionGate(), reads = ReadCounter()
        let pending = Task {
            try await MacWiFiGuardedRead.run(isCurrent: { gate.isOpen() },
                permission: { await permission.permission() },
                read: { value in
                    reads.value += 1
                    return MacWiFiObservation(status: .unavailable, identityState: .unavailable, permission: value)
                })
        }
        await permission.waitUntilEntered()
        gate.close()
        await permission.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(reads.value == 0)
    }

    @Test func revokedGateCannotStartPermissionStatusRead() async {
        let gate = MacManualNetworkGate(request: .wifi, lease: SessionLease(ownerID: UUID()))
        let reads = ReadCounter()
        gate.close()
        await #expect(throws: CancellationError.self) {
            try await MacWiFiPermissionProbe.guardedRead(isCurrent: { gate.isOpen() }, read: {
                reads.value += 1
                return .unknown
            })
        }
        #expect(reads.value == 0)
    }

    @Test func onlyGuardedWiFiIsPubliclyAdmitted() async {
        let runner = DelayedRunner()
        let owner = MacManualNetworkOwner(makeRunner: { _, _, _ in runner })
        #expect(owner.start(.wifi))
        await runner.waitUntilEntered()
        await runner.finish("fixture")
        #expect(await owner.drain(timeout: 2))
        #expect(owner.result == "fixture")
    }

    @Test func deniedDiagnosticDoesNotReachTransport() async {
        let transport = FakeDiagnosticTransport(gate: StopGate())
        let diagnostic = MacToolboxDiagnostics(lease: SessionLease(ownerID: UUID()),
            authorize: { _, _, _ in false }, transport: transport)
        await #expect(throws: ToolboxError.denied) { try await diagnostic.ping(target: "fixture.test") }
        #expect(await transport.pingCount == 0)
    }

    @Test func concurrentStopsWaitForTheSameActualTransportClose() async {
        let gate = StopGate(), transport = FakeDiagnosticTransport(gate: gate)
        let diagnostic = MacToolboxDiagnostics(lease: SessionLease(ownerID: UUID()),
            authorize: { _, _, _ in true }, transport: transport)
        let first = Task { await diagnostic.stop() }
        await gate.waitForStop()
        let secondFinished = CompletionFlag()
        let second = Task { await diagnostic.stop(); await secondFinished.mark() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!(await secondFinished.finished))
        #expect(await gate.calls == 1)
        await gate.release()
        await first.value; await second.value
        #expect(await secondFinished.finished)
    }
}
