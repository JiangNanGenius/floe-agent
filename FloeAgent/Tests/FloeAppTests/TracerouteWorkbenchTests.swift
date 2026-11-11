// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import Testing
import FloeToolboxCore
import FloeToolboxDiagnostics
import FloeToolboxWorkbenches

private actor HeldWorkbenchTrace: DiagnosticWorkbenchService {
    private var observers: [Int: TracerouteObserver] = [:]
    private var requests: [Int: UUID] = [:]
    private var continuations: [Int: CheckedContinuation<[TraceHop], any Error>] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var hops: [Int: [TraceHop]] = [:]
    private var count = 0
    var invocationCount: Int { count }
    func traceroute(target: String, maximumHops: Int, timeoutSeconds: Int, requestID: UUID,
                    onObservation: TracerouteObserver?) async throws -> [TraceHop] {
        count += 1; let index = count
        requests[index] = requestID; observers[index] = onObservation
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
            for waiter in waiters.removeValue(forKey: index) ?? [] { waiter.resume() }
        }
    }
    func wait(_ index: Int) async {
        if continuations[index] == nil { await withCheckedContinuation { waiters[index, default: []].append($0) } }
    }
    func emit(_ index: Int, ttl: Int, address: String? = "192.0.2.1", status: TraceHop.Status = .intermediate,
              requestID: UUID? = nil) async {
        guard let id = requests[index] else { return }
        let value = TraceHop(ttl: ttl, address: address, milliseconds: status == .timeout ? [] : [1], status: status)
        hops[index, default: []].append(value)
        await observers[index]?(.init(requestID: requestID ?? id, value: .hop(value)))
    }
    func finish(_ index: Int, failure: DiagnosticError? = nil) {
        let continuation = continuations.removeValue(forKey: index)
        if let failure { continuation?.resume(throwing: failure) }
        else { continuation?.resume(returning: hops[index] ?? []) }
    }
    func stop() {
        let pending = continuations; continuations = [:]
        pending.values.forEach { $0.resume(throwing: CancellationError()) }
    }
    func traceroute(target: String, maximumHops: Int, timeoutSeconds: Int) throws -> [TraceHop] { throw DiagnosticError.invalid("final-only backend must not run") }
    func ping(target: String, count: Int, timeoutSeconds: Int) throws -> [PingObservation] { throw DiagnosticError.invalid("unexpected") }
    func dns(name: String, type: DNSRecordType, timeout: Double) throws -> [DNSRecord] { throw DiagnosticError.invalid("unexpected") }
    func ports(target: String, ports: [UInt16], timeout: Double) throws -> [PortObservation] { throw DiagnosticError.invalid("unexpected") }
    func discover(type: String, seconds: Double) throws -> [BonjourService] { throw DiagnosticError.invalid("unexpected") }
}
private actor WorkbenchInformationGate {
    private var continuations: [String: CheckedContinuation<TracerouteIPInformation?, any Error>] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var counts: [String: Int] = [:]
    func query(_ address: String, version: String) async throws -> TracerouteIPInformation? {
        counts[address, default: 0] += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[address] = continuation
            for waiter in waiting.removeValue(forKey: address) ?? [] { waiter.resume() }
        }
    }
    func wait(_ address: String) async {
        if continuations[address] == nil { await withCheckedContinuation { waiting[address, default: []].append($0) } }
    }
    func calls(_ address: String) -> Int { counts[address] ?? 0 }
    func finish(_ address: String) {
        continuations.removeValue(forKey: address)?.resume(returning: .init(address: address,
            region: "Fixture region", autonomousSystemNumber: 64500, organization: "Fixture network",
            source: "Synthetic offline adapter", datasetVersion: "fixture-v1"))
    }
}

@Suite("Real traceroute workbench model", .serialized)
@MainActor struct TracerouteWorkbenchTests {
    @Test(.timeLimit(.minutes(1)))
    func publishedFirstHopIsVisibleBeforeFinalResultAndKeepsItsIdentity() async throws {
        let service = HeldWorkbenchTrace(), model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service)
        var observedCounts: [Int] = []
        let observation = model.$rows.sink { observedCounts.append($0.count) }
        model.target = "fixture.example"
        let run = try #require(model.run()); await service.wait(1)
        await service.emit(1, ttl: 1)
        #expect(model.running && model.rows.count == 1 && observedCounts.contains(1))
        let first = try #require(model.rows.first?.id)
        await service.emit(1, ttl: 2, address: nil, status: .timeout)
        await service.emit(1, ttl: 3, address: "192.0.2.9", status: .reached)
        #expect(model.running && model.rows.count == 3)
        if case .timeout = model.rows[1].status {} else { Issue.record("Timeout row was not explicit") }
        await service.finish(1); await run.value
        #expect(!model.running && !model.failed && model.rows.count == 3)
        #expect(model.rows.first?.id == first)
        observation.cancel(); await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func stopRetainsPartialWaitsForJoinAndOldCallbacksCannotTouchNewRun() async throws {
        let service = HeldWorkbenchTrace(), model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service)
        model.target = "old.example"
        let old = try #require(model.run()); await service.wait(1); await service.emit(1, ttl: 1)
        let first = try #require(model.rows.first?.id)
        model.cancel()
        #expect(model.cancelled && model.stopping && model.rows.first?.id == first)
        #expect(model.run() == nil) // old backend deliberately has not acknowledged
        await service.emit(1, ttl: 2)
        #expect(model.rows.count == 1)
        await service.finish(1); await old.value; await model.waitUntilStopped()
        #expect(!model.stopping)
        model.target = "current.example"
        let current = try #require(model.run()); await service.wait(2)
        await service.emit(1, ttl: 3) // callback from the already returned old backend
        #expect(model.rows.isEmpty)
        await service.emit(2, ttl: 1, address: nil, status: .timeout)
        await service.finish(2); await current.value
        #expect(model.rows.count == 1 && model.rows[0].id != first && !model.cancelled)
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func closeAndProbeFailureRetainObservedRows() async throws {
        let service = HeldWorkbenchTrace(), model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service)
        model.target = "failure.example"
        let run = try #require(model.run()); await service.wait(1); await service.emit(1, ttl: 1)
        await service.finish(1, failure: .system("fixture socket error")); await run.value
        #expect(model.failed && model.rows.count == 1)
        model.target = "close.example"
        let next = try #require(model.run()); await service.wait(2); await service.emit(2, ttl: 1)
        await model.close(); await next.value
        #expect(model.cancelled && !model.stopping && model.rows.count == 1)
        await service.emit(2, ttl: 2)
        #expect(model.rows.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func slowInformationCannotDelayRowsOrCompletionAndDuplicateAddressesShareLookup() async throws {
        let service = HeldWorkbenchTrace(), information = WorkbenchInformationGate()
        let provider = TracerouteIPInformationProvider(currentVersion: { "fixture-v1" },
            lookup: { try await information.query($0, version: $1) })
        let model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: provider)
        model.target = "fixture.example"
        let run = try #require(model.run()); await service.wait(1); await service.emit(1, ttl: 1)
        await information.wait("192.0.2.1")
        await service.emit(1, ttl: 2)
        #expect(model.rows.count == 2 && model.rows.allSatisfy { $0.ipInformation == nil })
        #expect(await information.calls("192.0.2.1") == 1)
        let ids = model.rows.map(\.id)
        await service.finish(1); await run.value
        #expect(!model.running && model.rows.count == 2)
        await information.finish("192.0.2.1")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.rows.first?.ipInformation == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.rows.map(\.id) == ids && model.rows.allSatisfy { $0.ipInformation?.organization == "Fixture network" })
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledInformationAndMalformedOrForeignHopsCannotOverwriteCurrentRows() async throws {
        let service = HeldWorkbenchTrace(), information = WorkbenchInformationGate()
        let provider = TracerouteIPInformationProvider(currentVersion: { "fixture-v1" },
            lookup: { try await information.query($0, version: $1) })
        let model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: provider)
        model.target = "old.example"
        let old = try #require(model.run()); await service.wait(1); await service.emit(1, ttl: 1)
        await information.wait("192.0.2.1")
        model.cancel(); await service.finish(1); await old.value; await model.waitUntilStopped()
        model.target = "new.example"
        let new = try #require(model.run()); await service.wait(2)
        await service.emit(2, ttl: 1, requestID: UUID())
        await service.emit(2, ttl: 2)
        await service.emit(2, ttl: 1, address: "not-an-address")
        #expect(model.rows.isEmpty)
        await service.emit(2, ttl: 1, address: "192.0.2.2")
        await information.wait("192.0.2.2")
        await information.finish("192.0.2.1")
        #expect(model.rows.count == 1 && model.rows.first?.ipInformation == nil)
        await information.finish("192.0.2.2")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.rows.first?.ipInformation == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.rows.first?.ipInformation?.address == "192.0.2.2")
        await service.finish(2); await new.value; await model.close()
    }
    @Test(.timeLimit(.minutes(1)))
    func freshRunRecoversAfterFourCancelledOldLookupsActuallyReturn() async throws {
        let service = HeldWorkbenchTrace(), information = WorkbenchInformationGate()
        let provider = TracerouteIPInformationProvider(currentVersion: { "fixture-v1" },
            lookup: { try await information.query($0, version: $1) })
        let model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: provider)
        model.target = "old.example"
        let old = try #require(model.run()); await service.wait(1)
        for ttl in 1...4 { await service.emit(1, ttl: ttl, address: "192.0.2.\(ttl)") }
        for ttl in 1...4 { await information.wait("192.0.2.\(ttl)") }
        model.cancel(); await service.finish(1); await old.value; await model.waitUntilStopped()
        model.target = "fresh.example"
        let fresh = try #require(model.run()); await service.wait(2)
        await service.emit(2, ttl: 1, address: "192.0.2.5")
        // Actual hop output remains live while its information waits behind
        // four older adapters that deliberately ignore task cancellation.
        #expect(model.running && model.rows.count == 1 && model.rows[0].ipInformation == nil)
        await service.finish(2); await fresh.value
        #expect(!model.running && !model.ipInformationRetryable)
        for ttl in 1...4 { await information.finish("192.0.2.\(ttl)") }
        await information.wait("192.0.2.5")
        #expect(model.rows.count == 1 && model.rows[0].ipInformation == nil)
        await information.finish("192.0.2.5")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.rows.first?.ipInformation == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.rows[0].ipInformation?.address == "192.0.2.5")
        #expect(model.rows[0].title == "1 · 192.0.2.5" && !model.ipInformationRetryable)
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func closedResultsRestoreInAFreshOwnerWithoutStartingAProbe() async throws {
        let oldService = HeldWorkbenchTrace()
        let oldModel = try DiagnosticWorkbenchModel(tool: .traceroute, service: oldService)
        oldModel.target = "old.example"
        let old = try #require(oldModel.run()); await oldService.wait(1); await oldService.emit(1, ttl: 1)
        oldModel.target = "next-draft.example"
        await oldModel.close(); await old.value
        let retained = try #require(oldModel.retainedTraceroute)
        #expect(oldModel.run() == nil)
        let freshService = HeldWorkbenchTrace()
        let fresh = try DiagnosticWorkbenchModel(tool: .traceroute, service: freshService)
        fresh.restoreTraceroute(retained)
        #expect(fresh.rows.map(\.id) == oldModel.rows.map(\.id))
        #expect(fresh.cancelled && !fresh.running && !fresh.stopping)
        #expect(fresh.request?.target == "old.example" && fresh.target == "next-draft.example")
        #expect(await freshService.invocationCount == 0)
        await oldService.emit(1, ttl: 2)
        #expect(fresh.rows.count == 1)
        let run = try #require(fresh.run()); await freshService.wait(1)
        #expect(fresh.rows.isEmpty && fresh.request?.id != retained.request.id)
        await freshService.finish(1); await run.value; await fresh.close()
    }

}
