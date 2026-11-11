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
    func finish(_ address: String, version: String = "fixture-v1") {
        continuations.removeValue(forKey: address)?.resume(returning: .init(address: address,
            region: "Fixture region", autonomousSystemNumber: 64500, organization: "Fixture network",
            source: "Synthetic offline adapter", datasetVersion: version))
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
    func missingDatabaseAndLocalAddressesHaveDifferentExplicitStates() async throws {
        let service = HeldWorkbenchTrace(), fixture = TracerouteIPProviderFixture(version: nil)
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.currentVersion() },
            isPublicInternetAddress: { $0 != "10.0.0.1" }, lookup: { try await fixture.query($0, version: $1) })
        let model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: provider)
        model.target = "fixture.example"
        let run = try #require(model.run()); await service.wait(1)
        await service.emit(1, ttl: 1, address: "192.0.2.1")
        await service.emit(1, ttl: 2, address: "10.0.0.1")
        guard await waitForIP({ model.rows.count == 2 && model.rows[0].ipInformationStatus == .databaseUnavailable
            && model.rows[1].ipInformationStatus == .localOrSpecialUse }) else { await model.close(); return }
        #expect(model.ipInformationDatabaseUnavailable && !model.ipInformationRetryable)
        #expect(await fixture.lookupCount == 0)
        await service.finish(1); await run.value; await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func noMatchIsExplicitAndIsReusedForALaterDuplicateHop() async throws {
        let service = HeldWorkbenchTrace(), fixture = TracerouteIPProviderFixture(matches: false)
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.currentVersion() },
            lookup: { try await fixture.query($0, version: $1) })
        let model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: provider)
        model.target = "fixture.example"
        let run = try #require(model.run()); await service.wait(1); await service.emit(1, ttl: 1)
        guard await waitForIP({ model.rows.first?.ipInformationStatus == .notFound }) else { await model.close(); return }
        await service.emit(1, ttl: 2)
        #expect(model.rows.allSatisfy { $0.ipInformationStatus == .notFound && $0.ipInformation == nil })
        #expect(await fixture.lookupCount == 1)
        #expect(!model.ipInformationRetryable && !model.ipInformationDatabaseUnavailable)
        await service.finish(1); await run.value; await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func lookupFailureIsVisibleAndManualRetryPreservesTheActualHop() async throws {
        let service = HeldWorkbenchTrace(), fixture = TracerouteIPProviderFixture(failLookup: true)
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.currentVersion() },
            lookup: { try await fixture.query($0, version: $1) })
        let model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: provider)
        model.target = "fixture.example"
        let run = try #require(model.run()); await service.wait(1); await service.emit(1, ttl: 1)
        guard await waitForIP({ model.ipInformationRetryable }) else { await model.close(); return }
        let first = try #require(model.rows.first)
        if case .failed(let detail)? = first.ipInformationStatus { #expect(detail.contains("synthetic read failure")) }
        else { Issue.record("A non-busy adapter failure must remain explicit") }
        await service.finish(1); await run.value
        await fixture.setLookupFailure(false)
        model.completeIPInformation()
        guard await waitForIP({ model.rows.first?.ipInformationStatus == .available }) else { await model.close(); return }
        #expect(model.rows[0].id == first.id && model.rows[0].title == first.title && model.rows[0].value == first.value)
        #expect(model.rows[0].ipInformation?.latitude == 51.5 && model.rows[0].ipInformation?.longitude == -0.1)
        #expect(model.rows[0].ipInformation?.accuracyRadiusKilometers == 25)
        #expect(await service.invocationCount == 1)
        #expect(await fixture.lookupCount == 2)
        #expect(!model.ipInformationRetryable)
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aCompletedLookupIsAlsoAppliedToLaterDuplicateHops() async throws {
        let service = HeldWorkbenchTrace(), information = WorkbenchInformationGate()
        let provider = TracerouteIPInformationProvider(currentVersion: { "fixture-v1" },
            lookup: { try await information.query($0, version: $1) })
        let model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: provider)
        model.target = "fixture.example"
        let run = try #require(model.run()); await service.wait(1); await service.emit(1, ttl: 1)
        await information.wait("192.0.2.1"); await information.finish("192.0.2.1")
        guard await waitForIP({ model.rows.first?.ipInformationStatus == .available }) else { await model.close(); return }
        await service.emit(1, ttl: 2)
        #expect(model.rows.count == 2 && model.rows.allSatisfy { $0.ipInformation?.organization == "Fixture network" })
        #expect(model.rows.allSatisfy { $0.ipInformationStatus == .available })
        #expect(await information.calls("192.0.2.1") == 1)
        await service.finish(1); await run.value; await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func restoredStoppedResultsOnlyEnrichAfterAnExplicitAction() async throws {
        let oldService = HeldWorkbenchTrace()
        let old = try DiagnosticWorkbenchModel(tool: .traceroute, service: oldService)
        old.target = "fixture.example"
        let run = try #require(old.run()); await oldService.wait(1); await oldService.emit(1, ttl: 1)
        await old.close(); await run.value
        let retained = try #require(old.retainedTraceroute)
        let service = HeldWorkbenchTrace(), fixture = TracerouteIPProviderFixture()
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.currentVersion() },
            lookup: { try await fixture.query($0, version: $1) })
        let fresh = try DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: provider)
        fresh.restoreTraceroute(retained)
        fresh.refreshIPInformation() // A database-change notification is not a user action.
        #expect(await fixture.lookupCount == 0)
        #expect(await service.invocationCount == 0)
        #expect(fresh.rows[0].ipInformationStatus == .notRequested && fresh.cancelled)
        fresh.completeIPInformation()
        guard await waitForIP({ fresh.rows.first?.ipInformationStatus == .available }) else { await fresh.close(); return }
        #expect(fresh.rows.map(\.id) == retained.rows.map(\.id))
        #expect(fresh.cancelled && !fresh.running)
        #expect(await fixture.lookupCount == 1)
        #expect(await service.invocationCount == 0)
        await fresh.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aChangedDatasetRejectsTheLateValueAndAllowsManualRefresh() async throws {
        let service = HeldWorkbenchTrace(), information = WorkbenchInformationGate(), fixture = TracerouteIPProviderFixture()
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.currentVersion() },
            lookup: { try await information.query($0, version: $1) })
        let model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: provider)
        model.target = "fixture.example"
        let run = try #require(model.run()); await service.wait(1); await service.emit(1, ttl: 1)
        await information.wait("192.0.2.1")
        let id = try #require(model.rows.first?.id)
        await fixture.setVersion("fixture-v2"); await information.finish("192.0.2.1")
        guard await waitForIP({ model.rows.first?.ipInformationStatus == .databaseChanged }) else { await model.close(); return }
        #expect(model.rows[0].ipInformation == nil && model.ipInformationRetryable)
        await service.finish(1); await run.value
        model.completeIPInformation()
        await information.wait("192.0.2.1"); await information.finish("192.0.2.1", version: "fixture-v2")
        guard await waitForIP({ model.rows.first?.ipInformationStatus == .available }) else { await model.close(); return }
        #expect(model.rows[0].id == id && model.rows[0].ipInformation?.datasetVersion == "fixture-v2")
        #expect(await service.invocationCount == 1)
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedDatabaseReadinessIsNotMisreportedAsAnEmptyDatabase() async throws {
        let service = HeldWorkbenchTrace(), fixture = TracerouteIPProviderFixture(failPreparation: true)
        let provider = TracerouteIPInformationProvider(currentVersion: { nil }, isPublicInternetAddress: { _ in true },
            prepareLookup: { try await fixture.prepare() }, lookup: { try await fixture.query($0, version: $1) })
        let model = try DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: provider)
        guard await waitForIP({ model.ipInformationDatabaseFailure != nil }) else { await model.close(); return }
        #expect(!model.ipInformationDatabaseUnavailable && model.ipInformationRetryable)
        #expect(model.ipInformationDatabaseFailure?.contains("synthetic load failure") == true)
        #expect(await fixture.lookupCount == 0)
        await model.close()
    }

    private func waitForIP(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        let completed = condition()
        #expect(completed, "The real workbench did not reach the expected IP-information state before the timeout")
        return completed
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

// Pure provider/value regressions also run without SwiftUI or an ICMP backend.
private actor TracerouteIPProviderFixture {
    private var version: String?
    private let matches: Bool
    private let failPreparation: Bool
    private var failLookup: Bool
    private let changeVersionOnLookup: Bool
    private(set) var prepareCount = 0
    private(set) var lookupCount = 0
    init(version: String? = "fixture-v1", matches: Bool = true, failPreparation: Bool = false,
         failLookup: Bool = false, changeVersionOnLookup: Bool = false) {
        self.version = version; self.matches = matches; self.failPreparation = failPreparation
        self.failLookup = failLookup; self.changeVersionOnLookup = changeVersionOnLookup
    }
    func currentVersion() -> String? { version }
    func setVersion(_ value: String?) { version = value }
    func setLookupFailure(_ value: Bool) { failLookup = value }
    func prepare() throws {
        prepareCount += 1
        if failPreparation { throw DiagnosticError.system("synthetic load failure") }
    }
    func query(_ address: String, version: String) throws -> TracerouteIPInformation? {
        lookupCount += 1
        if failLookup { throw DiagnosticError.system("synthetic read failure") }
        if changeVersionOnLookup { self.version = "fixture-v2" }
        guard matches else { return nil }
        return .init(address: address, region: "Synthetic region", autonomousSystemNumber: 64500,
            organization: "Synthetic network", source: "Synthetic fixture", datasetVersion: version,
            latitude: 51.5, longitude: -0.1, accuracyRadiusKilometers: 25)
    }
}

@Suite("Traceroute IP information values and provider", .serialized)
struct TracerouteIPProviderTests {
    @Test func coordinatesRequireACompleteFinitePairAndDoNotInventAccuracy() {
        let invalid: [(Double?, Double?)] = [(nil, 1), (1, nil), (.nan, 0), (0, .infinity), (91, 0), (0, -181)]
        for (latitude, longitude) in invalid {
            let value = TracerouteIPInformation(address: "192.0.2.1", region: "Synthetic region",
                source: "Synthetic fixture", datasetVersion: "v1", latitude: latitude, longitude: longitude,
                accuracyRadiusKilometers: 10)
            #expect(value.latitude == nil && value.longitude == nil && value.accuracyRadiusKilometers == nil)
            #expect(value.region == "Synthetic region")
        }
        let zero = TracerouteIPInformation(address: "192.0.2.1", source: "Synthetic fixture", datasetVersion: "v1",
            latitude: 0, longitude: 0)
        #expect(zero.latitude == 0 && zero.longitude == 0 && zero.accuracyRadiusKilometers == nil)
        for radius in [-1.0, .nan, .infinity] {
            let value = TracerouteIPInformation(address: "192.0.2.1", source: "Synthetic fixture", datasetVersion: "v1",
                latitude: 51.5, longitude: -0.1, accuracyRadiusKilometers: radius)
            #expect(value.latitude == 51.5 && value.longitude == -0.1 && value.accuracyRadiusKilometers == nil)
        }
    }

    @Test func localClassificationPrecedesDatabasePreparation() async throws {
        let fixture = TracerouteIPProviderFixture(version: nil, failPreparation: true)
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.currentVersion() },
            isPublicInternetAddress: { _ in false }, prepareLookup: { try await fixture.prepare() },
            lookup: { try await fixture.query($0, version: $1) })
        #expect(try await provider.lookupResult(for: "10.0.0.1") == .localOrSpecialUse)
        #expect(try await provider.information(for: "10.0.0.1") == nil)
        #expect(await fixture.prepareCount == 0)
        #expect(await fixture.lookupCount == 0)
    }

    @Test func emptyDatabaseAndNoMatchRemainDistinct() async throws {
        let missing = TracerouteIPProviderFixture(version: nil)
        let missingProvider = TracerouteIPInformationProvider(currentVersion: { await missing.currentVersion() },
            lookup: { try await missing.query($0, version: $1) })
        #expect(try await missingProvider.lookupResult(for: "192.0.2.1") == .databaseUnavailable)
        #expect(await missing.lookupCount == 0)
        let unmatched = TracerouteIPProviderFixture(matches: false)
        let unmatchedProvider = TracerouteIPInformationProvider(currentVersion: { await unmatched.currentVersion() },
            lookup: { try await unmatched.query($0, version: $1) })
        #expect(try await unmatchedProvider.lookupResult(for: "192.0.2.1") == .notFound)
        #expect(await unmatched.lookupCount == 1)
    }

    @Test func databaseReadinessFailurePropagatesAsAnError() async {
        let fixture = TracerouteIPProviderFixture(version: nil, failPreparation: true)
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.currentVersion() },
            isPublicInternetAddress: { _ in true }, prepareLookup: { try await fixture.prepare() },
            lookup: { try await fixture.query($0, version: $1) })
        do {
            _ = try await provider.lookupResult(for: "192.0.2.1")
            Issue.record("A failed database load must not become databaseUnavailable")
        } catch { #expect(error as? DiagnosticError == .system("synthetic load failure")) }
        #expect(await fixture.lookupCount == 0)
    }

    @Test func datasetFenceRejectsAValueFromThePreviousVersion() async throws {
        let fixture = TracerouteIPProviderFixture(changeVersionOnLookup: true)
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.currentVersion() },
            lookup: { try await fixture.query($0, version: $1) })
        #expect(try await provider.lookupResult(for: "192.0.2.1") == .databaseChanged)
    }

    @Test func legacyInitializerAndOptionalResultRetainRealLocationFields() async throws {
        let fixture = TracerouteIPProviderFixture()
        let provider = TracerouteIPInformationProvider(currentVersion: { await fixture.currentVersion() }) {
            try await fixture.query($0, version: $1)
        }
        let value = try #require(try await provider.information(for: "192.0.2.1"))
        #expect(value.latitude == 51.5 && value.longitude == -0.1 && value.accuracyRadiusKilometers == 25)
        #expect(value.autonomousSystemNumber == 64500 && value.organization == "Synthetic network")
    }
}
