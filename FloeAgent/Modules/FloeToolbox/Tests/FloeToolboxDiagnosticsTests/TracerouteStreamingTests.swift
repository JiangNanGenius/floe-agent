// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeToolboxCore
@testable import FloeToolboxDiagnostics

private final class TraceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
private final class SocketProbeGate: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private let release = DispatchSemaphore(value: 0)
    func open() { release.signal() }
    func probe(_ ttl: Int, _ sequence: UInt16, _ token: CancellationToken) throws -> DeviceICMPTraceroute.ProbeOutcome {
        if ttl == 2 {
            entered.continuation.yield(())
            guard release.wait(timeout: .now() + 5) == .success else { throw DiagnosticError.timedOut }
            try token.throwIfCancelled()
            return .echoReply(rttMs: 4)
        }
        return .timeExceeded(address: "192.0.2.1", rttMs: 1)
    }
}
private actor ObservationLog {
    var values: [TracerouteObservation] = []
    func add(_ value: TracerouteObservation) { values.append(value) }
    var hops: [TraceHop] { values.compactMap { if case .hop(let hop) = $0.value { hop } else { nil } } }
}
private actor HeldTraceProbe {
    private var continuation: CheckedContinuation<ICMPTracerouteReport, any Error>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private var observer: TracerouteObserver?
    private var requestID = UUID()
    private var token: CancellationToken?
    func begin(_ token: CancellationToken, id: UUID, observer: TracerouteObserver?) async throws -> ICMPTracerouteReport {
        self.token = token; self.requestID = id; self.observer = observer
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let ready = started; started = []; ready.forEach { $0.resume() }
        }
    }
    func wait() async { if continuation == nil { await withCheckedContinuation { started.append($0) } } }
    var cancelled: Bool { token?.isCancelled == true }
    func emit(_ ttl: Int) async {
        await observer?(.init(requestID: requestID, value: .hop(.init(ttl: ttl,
            address: "192.0.2.1", milliseconds: [1], status: .intermediate))))
    }
    func finish() {
        continuation?.resume(returning: .init(target: "fixture.example", resolvedAddress: "192.0.2.9", maxHops: 4,
            hops: [.init(ttl: 1, status: .timeExceeded(address: "192.0.2.1", rtts: [1]))]))
        continuation = nil
    }
}
private actor HeldInformation {
    var version = "v1"
    private var held: [String: CheckedContinuation<TracerouteIPInformation?, any Error>] = [:]
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int { held.count }
    func current() -> String { version }
    func changeVersion() { version = "v2" }
    func query(_ address: String, version: String) async throws -> TracerouteIPInformation? {
        try await withCheckedThrowingContinuation { continuation in
            held[address] = continuation
            let ready = waiting.filter { held.count >= $0.0 }
            waiting.removeAll { held.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func wait(_ count: Int) async {
        if held.count < count { await withCheckedContinuation { waiting.append((count, $0)) } }
    }
    func finish() {
        let pending = held; held = [:]
        for (address, continuation) in pending {
            continuation.resume(returning: .init(address: address, region: "Fixture region",
                autonomousSystemNumber: 64500, source: "Synthetic service adapter", datasetVersion: "v1"))
        }
    }
}

@Suite("Native traceroute streaming and resource boundaries", .serialized)
struct TracerouteStreamingTests {
    @Test(.timeLimit(.minutes(1)))
    func actualProducerDeliversHopOneWhileSecondHopIsBlocked() async throws {
        let gate = SocketProbeGate(), id = UUID(), returned = TraceFlag()
        let observations = AsyncStream<TracerouteObservation>.makeStream()
        let run = Task {
            defer { returned.set() }
            return try await DeviceICMPTraceroute.run(target: "127.0.0.1", maxHops: 5, waitSeconds: 1,
                cancellation: CancellationToken(), requestID: id,
                onObservation: { observations.continuation.yield($0) }, probe: gate.probe)
        }
        defer { gate.open(); observations.continuation.finish() }
        var events = observations.stream.makeAsyncIterator()
        #expect(await events.next()?.requestID == id) // real resolver event
        let first = try #require(await events.next())
        guard case .hop(let hop) = first.value else { Issue.record("Expected an actual TTL event"); gate.open(); _ = await run.result; return }
        #expect(hop.ttl == 1 && hop.milliseconds == [1, 1])
        var probe = gate.entered.stream.makeAsyncIterator()
        _ = await probe.next()
        #expect(!returned.isSet) // the exact native socket worker is held at TTL2
        gate.open()
        let report = try await run.value
        #expect(report.hops.count == 2 && report.reachedTarget)
        #expect(report.summaryText().contains("summary hops=2 reached=true"))
    }

    @Test func timeoutAndUnreachableObservationsMatchFinalReportOrder() async throws {
        let log = ObservationLog()
        let report = try await DeviceICMPTraceroute.run(target: "127.0.0.1", maxHops: 6, waitSeconds: 1,
            cancellation: CancellationToken(), onObservation: { await log.add($0) },
            probe: { ttl, _, _ in
                switch ttl { case 1: .timeout; case 2: .timeExceeded(address: "192.0.2.2", rttMs: 2); default: .unreachable(reason: "fixture unreachable") }
            })
        let hops = await log.hops
        #expect(hops.map(\.ttl) == [1, 2, 3])
        #expect(hops.map(\.status) == [.timeout, .intermediate, .unreachable])
        #expect(hops[0].milliseconds.isEmpty && hops[2].reason == "fixture unreachable")
        #expect(report.hops.count == 3 && !report.reachedTarget)
        #expect(report.summaryText().contains("hop ttl=1 status=timeout"))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDoesNotReturnUntilSocketWorkerAcknowledges() async throws {
        let gate = SocketProbeGate(), returned = TraceFlag(), log = ObservationLog()
        let run = Task {
            defer { returned.set() }
            return try await DeviceICMPTraceroute.run(target: "127.0.0.1", maxHops: 5, waitSeconds: 1,
                cancellation: CancellationToken(), onObservation: { await log.add($0) }, probe: gate.probe)
        }
        defer { gate.open() }
        var entered = gate.entered.stream.makeAsyncIterator(); _ = await entered.next()
        run.cancel()
        #expect(!returned.isSet)
        gate.open()
        if case .success = await run.result { Issue.record("Cancelled native producer reported success") }
        #expect(returned.isSet)
        #expect(await log.hops.allSatisfy { $0.ttl == 1 })
        // Actual socket operation after the old worker/descriptor has ended.
        let next = try await ICMPTracerouteProbe.run(target: "127.0.0.1", maximumHops: 2, timeoutSeconds: 1)
        #expect(next.reachedTarget)
    }

    @Test(.timeLimit(.minutes(1)))
    func serviceStopWaitsForWorkerAndRejectsLateHop() async throws {
        let fixture = HeldTraceProbe(), log = ObservationLog(), stopped = TraceFlag()
        let service = DiagnosticService(lease: .init(ownerID: UUID()), authorize: { _, _, _ in true },
            traceProbe: { _, _, _, token, id, observer in try await fixture.begin(token, id: id, observer: observer) })
        let run = Task { try await service.traceroute(target: "fixture.example", maximumHops: 4, timeoutSeconds: 1,
            requestID: UUID(), onObservation: { await log.add($0) }) }
        await fixture.wait(); await fixture.emit(1)
        #expect(await log.hops.count == 1)
        let stop = Task { await service.stop(); stopped.set() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await fixture.cancelled), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await fixture.cancelled)
        #expect(!stopped.isSet)
        await fixture.emit(2)
        #expect(await log.hops.map(\.ttl) == [1])
        await fixture.finish(); await stop.value
        if case .success = await run.result { Issue.record("Stopped service returned a successful trace") }
        #expect(stopped.isSet)
    }

    @Test func actualLoopbackObservationUsesRealSocket() async throws {
        let log = ObservationLog()
        let report = try await ICMPTracerouteProbe.run(target: "127.0.0.1", maximumHops: 3,
            timeoutSeconds: 1, onObservation: { await log.add($0) })
        #expect(report.reachedTarget)
        #expect(await log.hops.map(\.status) == [.reached])
    }

    @Test(.timeLimit(.minutes(1)))
    func changedDatasetCannotPublishAnOlderLookup() async throws {
        let fixture = HeldInformation()
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.current() },
            lookup: { try await fixture.query($0, version: $1) })
        let query = Task { try await provider.information(for: "192.0.2.1") }
        await fixture.wait(1); await fixture.changeVersion(); await fixture.finish()
        #expect(try await query.value == nil)
        let missing = TracerouteIPInformationProvider(currentVersion: { nil }, lookup: { _, _ in Issue.record("Missing database triggered a lookup"); return nil })
        #expect(try await missing.information(for: "192.0.2.2") == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDoesNotReleaseLookupAdmissionBeforeActualReturn() async throws {
        let fixture = HeldInformation()
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.current() },
            lookup: { try await fixture.query($0, version: $1) })
        let tasks = (1...4).map { suffix in Task { try await provider.information(for: "192.0.2.\(suffix)") } }
        await fixture.wait(4)
        tasks.forEach { $0.cancel() }
        let fifth = Task { try await provider.information(for: "192.0.2.5") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while TracerouteIPInformationProvider.informationAdmissionState.waiting == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(TracerouteIPInformationProvider.informationAdmissionState.waiting == 1)
        #expect(await fixture.count == 4)
        await fixture.finish()
        for task in tasks { if case .success = await task.result { Issue.record("Cancelled lookup returned information") } }
        await fixture.wait(1)
        #expect(await fixture.count == 1)
        await fixture.finish()
        #expect(try await fifth.value?.address == "192.0.2.5")
        let missing = TracerouteIPInformationProvider(currentVersion: { nil }, lookup: { _, _ in nil })
        #expect(try await missing.information(for: "192.0.2.6") == nil)
    }
    @Test(.timeLimit(.minutes(1)))
    func cancelledAdmissionWaiterDoesNotConsumeAReleasedPermit() async throws {
        let fixture = HeldInformation()
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.current() },
            lookup: { try await fixture.query($0, version: $1) })
        let active = (1...4).map { suffix in Task { try await provider.information(for: "192.0.2.\(suffix)") } }
        await fixture.wait(4)
        let waiting = Task { try await provider.information(for: "192.0.2.5") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while TracerouteIPInformationProvider.informationAdmissionState.waiting == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(TracerouteIPInformationProvider.informationAdmissionState.waiting == 1)
        waiting.cancel()
        if case .success = await waiting.result { Issue.record("Cancelled waiter was granted a permit") }
        #expect(TracerouteIPInformationProvider.informationAdmissionState.waiting == 0)
        #expect(TracerouteIPInformationProvider.informationAdmissionState.active == 4)
        await fixture.finish()
        for task in active { _ = try await task.value }
        #expect(TracerouteIPInformationProvider.informationAdmissionState.active == 0)
    }

}
