// FloeExecutionTests — prepared tests for the REAL ordered Linux guest soft
// restart (code-first delivery; executed in the later unified qualification
// run, not in this lane).
//
// Coverage: the orchestrator's ordered stage sequence and proofs, the durable
// operation record / persistence contract, unknown-outcome reconciliation and
// operation dedup, cancellation at every boundary, and the manager seam
// (transaction ownership, busy refusal, terminal refusal, post-verification,
// distinct-environment isolation). The fakes are lifecycle-manager/transport
// level; no emulator, guest process or real channel is involved.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - fakes

/// Scripted in-memory transport. Every call is recorded in order so tests
/// can assert the exact stage sequence and the absence of calls.
private actor FakeSoftRestartTransport: LinuxGuestSoftRestartTransport {
    struct Call: Equatable {
        var name: String
        var detail: String
    }

    private(set) var calls: [Call] = []

    var probeResult = LinuxGuestSoftRestartBootProbe(running: false)
    var flushResult: Result<LinuxCommandResult, Error> = .success(
        LinuxCommandResult(stdout: "poweroff=/sbin/poweroff", stderr: "", exitCode: 0)
    )
    var poweroffOutcome: LinuxGuestSoftRestartPoweroffOutcome = .poweredOff
    var postBoot = LinuxGuestSoftRestartPostBoot(
        vcpus: 1, ramMB: 256, launchGeneration: 2, imageID: "floe-image"
    )
    /// When set, `readNonce` returns this value (the mismatch case). When
    /// nil, `readNonce` echoes the nonce the flush stage last saw — the
    /// honest guest behavior.
    var nonceScript: String??
    private var seenFlushNonce: String?
    /// Manager tests must advance the controller's authoritative instance,
    /// not only the transport's scripted receipt. Standalone transport tests
    /// keep their explicit postBoot scripts and negative cases unchanged.
    private var lifecycleController: SoftRestartLifecycleFake?
    var startReplacementError: Error?
    var flushError: Error?
    /// Deterministic interleave hook: runs inside the flush stage AFTER the
    /// orchestrator persisted the pending record.
    var flushHook: (@Sendable () async -> Void)?
    /// Deterministic interleave hook: runs INSIDE the poweroff stage, before
    /// the scripted outcome is returned — used to assert the submission was
    /// journaled before the request crossed the boundary.
    var poweroffHook: (@Sendable () async -> Void)?

    func probeBoot(
        _ transaction: LinuxGuestLifecycleTransaction
    ) async -> LinuxGuestSoftRestartBootProbe {
        calls.append(.init(name: "probe", detail: transaction.environmentID))
        return probeResult
    }

    func flushAndRecordNonce(
        _ transaction: LinuxGuestLifecycleTransaction,
        nonce: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        calls.append(.init(name: "flush", detail: nonce))
        seenFlushNonce = nonce
        if let flushHook { await flushHook() }
        if let flushError { throw flushError }
        switch flushResult {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    func requestOrderlyPoweroff(
        _ transaction: LinuxGuestLifecycleTransaction,
        poweroffPath: String,
        deadline: TimeInterval,
        cancellation: CancellationToken?
    ) async -> LinuxGuestSoftRestartPoweroffOutcome {
        calls.append(.init(name: "poweroff", detail: poweroffPath))
        if let poweroffHook { await poweroffHook() }
        return poweroffOutcome
    }

    func captureExitedGuest(_ transaction: LinuxGuestLifecycleTransaction) async {
        calls.append(.init(name: "capture", detail: transaction.environmentID))
        if let lifecycleController {
            await lifecycleController.stopForLifecycleTransaction(transaction)
        }
    }

    func startReplacement(
        _ transaction: LinuxGuestLifecycleTransaction,
        taskID: String?,
        shape: GuestResourceRequest?,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestSoftRestartPostBoot {
        calls.append(.init(
            name: "start",
            detail: "\(shape?.vcpus.count ?? -1)/\(shape?.memory.mb ?? -1)"
        ))
        if let startReplacementError { throw startReplacementError }
        if let lifecycleController {
            guard try await lifecycleController.startForLifecycleTransaction(
                transaction, taskID: taskID, shape: shape
            ) else { throw LinuxGuestError.notOwned(environmentID: transaction.environmentID) }
            let states = await lifecycleController.runtimeStates()
                .filter { $0.environmentID == transaction.environmentID }
            guard states.count == 1, let state = states.first, state.running else {
                throw LinuxGuestError.notRunning(environmentID: transaction.environmentID)
            }
            return LinuxGuestSoftRestartPostBoot(vcpus: state.vcpus, ramMB: state.ramMB,
                launchGeneration: state.identity.launchGeneration, imageID: "floe-image")
        }
        return postBoot
    }

    func readNonce(
        _ transaction: LinuxGuestLifecycleTransaction,
        noncePath: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> String? {
        calls.append(.init(name: "readNonce", detail: noncePath))
        if let nonceScript { return nonceScript }
        return seenFlushNonce
    }

    // test controls
    func setLifecycleController(_ controller: SoftRestartLifecycleFake) { lifecycleController = controller }
    func setProbe(_ probe: LinuxGuestSoftRestartBootProbe) { probeResult = probe }
    func setFlush(_ result: Result<LinuxCommandResult, Error>) { flushResult = result }
    func setPoweroff(_ outcome: LinuxGuestSoftRestartPoweroffOutcome) { poweroffOutcome = outcome }
    func setPostBoot(_ post: LinuxGuestSoftRestartPostBoot) { postBoot = post }
    func setNonce(_ value: String?) { nonceScript = value }
    func setStartError(_ error: Error?) { startReplacementError = error }
    func setFlushError(_ error: Error?) { flushError = error }
    func setFlushHook(_ hook: (@Sendable () async -> Void)?) { flushHook = hook }
    func setPoweroffHook(_ hook: (@Sendable () async -> Void)?) { poweroffHook = hook }
}

/// Rendezvous so a test can park a stage deterministically.
private actor SoftRestartGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivedWaiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private var arrivedOpen = false

    /// Marks arrival, then parks until release.
    func arriveAndPark() async {
        signalArrived()
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrival() async {
        if arrivedOpen { return }
        await withCheckedContinuation { arrivedWaiters.append($0) }
    }

    func release() {
        open = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func signalArrived() {
        arrivedOpen = true
        let pending = arrivedWaiters
        arrivedWaiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// In-memory store conforming to the fail-closed protocol, with scripted
/// failure injection for the persistence-failure tests.
private actor FakeSoftRestartStore: LinuxGuestSoftRestartStore {
    private var operations: [String: LinuxGuestSoftRestartOperation] = [:]
    private var committedReceipts: [String: [LinuxGuestSoftRestartCommittedReceipt]] = [:]
    private(set) var saveCount = 0
    private(set) var removeCount = 0
    private(set) var committedRecordCount = 0
    var loadError: Error?
    var saveError: Error?
    /// When set, the Nth save (1-based) throws — deterministic settlement
    /// failure injection past the journaled saves.
    var saveFailureThreshold: Int?
    var removeError: Error?
    var committedLoadError: Error?
    var committedRecordError: Error?

    func load(environmentID: String) async throws -> LinuxGuestSoftRestartOperation? {
        if let loadError { throw loadError }
        return operations[environmentID]
    }

    func save(_ operation: LinuxGuestSoftRestartOperation) async throws {
        saveCount += 1
        if let saveError { throw saveError }
        if let threshold = saveFailureThreshold, saveCount >= threshold {
            throw LinuxGuestSoftRestartStoreError.io(
                environmentID: operation.environmentID,
                operation: "write",
                detail: "scripted save failure at call \(saveCount)"
            )
        }
        operations[operation.environmentID] = operation
    }

    func remove(environmentID: String) async throws {
        if let removeError { throw removeError }
        removeCount += 1
        operations.removeValue(forKey: environmentID)
    }

    func loadCommittedReceipt(
        environmentID: String, operationKey: String
    ) async throws -> LinuxGuestSoftRestartCommittedReceipt? {
        if let committedLoadError { throw committedLoadError }
        return committedReceipts[environmentID]?.first(where: {
            $0.operationKey == operationKey
        })
    }

    func recordCommittedReceipt(
        _ committed: LinuxGuestSoftRestartCommittedReceipt
    ) async throws {
        if let committedRecordError { throw committedRecordError }
        committedRecordCount += 1
        var list = committedReceipts[committed.environmentID] ?? []
        list.removeAll { $0.operationKey == committed.operationKey }
        list.append(committed)
        committedReceipts[committed.environmentID] = list
    }

    // test controls
    func seed(_ operation: LinuxGuestSoftRestartOperation) {
        operations[operation.environmentID] = operation
    }

    func setLoadError(_ error: Error?) { loadError = error }
    func setSaveError(_ error: Error?) { saveError = error }
    func setSaveFailureThreshold(_ threshold: Int?) { saveFailureThreshold = threshold }
    func setRemoveError(_ error: Error?) { removeError = error }
    func setCommittedLoadError(_ error: Error?) { committedLoadError = error }
    func setCommittedRecordError(_ error: Error?) { committedRecordError = error }
}

/// Minimal lifecycle controller with transaction, stage-command and
/// activity seams for manager-level tests.
private actor SoftRestartLifecycleFake: LinuxGuestControlling {
    struct Guest {
        var vcpus: Int
        var ramMB: Int
        var generation: UInt64
        var terminals: Int
        var services: Int
    }

    private var active: [String: Guest] = [:]
    private var owned: Set<String> = []
    private var nextGeneration: UInt64 = 0
    private var saved: LinuxGuestLifecycleConfig?

    private(set) var transactionBegins = 0
    private(set) var transactionEnds = 0
    private(set) var transactionStops = 0
    private(set) var transactionStarts: [String] = []
    private(set) var stageCommands: [[String]] = []
    var poweroffOutcome: LinuxGuestSoftRestartPoweroffOutcome = .poweredOff
    /// When true the controller reports a granted shape different from what
    /// the transport claims (manager post-verification must catch it).
    var lieAboutGrantedShape = false

    func own(_ environmentID: String, vcpus: Int = 1, ramMB: Int = 256) {
        owned.insert(environmentID)
        nextGeneration += 1
        active[environmentID] = Guest(
            vcpus: vcpus, ramMB: ramMB, generation: nextGeneration,
            terminals: 0, services: 0
        )
        saved = LinuxGuestLifecycleConfig(vcpus: vcpus, memoryMB: ramMB)
    }

    func preferredGuestConfiguration(environmentID: String) async -> LinuxGuestLifecycleConfig? {
        saved
    }

    func startGuest(environmentID: String, taskID: String?) async throws -> Bool { false }
    func startGuest(
        environmentID: String, taskID: String?, shape: GuestResourceRequest?
    ) async throws -> Bool { false }

    func runtimeStates() async -> [LinuxGuestRuntimeState] {
        active.map { entry in
            LinuxGuestRuntimeState(
                environmentID: entry.key,
                identity: LinuxGuestRuntimeIdentity(
                    runtimeID: "rt-\(entry.key)", launchGeneration: entry.value.generation
                ),
                running: true,
                ramMB: lieAboutGrantedShape ? entry.value.ramMB + 256 : entry.value.ramMB,
                vcpus: entry.value.vcpus,
                startedAt: Date(timeIntervalSince1970: 1)
            )
        }
    }

    func stopGuest(environmentID: String) async {
        active.removeValue(forKey: environmentID)
    }
    func resetGuest(environmentID: String) async {}
    func deleteGuest(environmentID: String) async {
        active.removeValue(forKey: environmentID)
        owned.remove(environmentID)
    }
    func guestIsRunning(environmentID: String) async -> Bool {
        active[environmentID] != nil
    }
    func restoreRepair(environmentID: String) async throws -> RuntimeV2Store.RepairResolutionReport {
        throw LinuxGuestError.invalidConfiguration("no repair substrate in the fake")
    }
    func guestStatus(environmentID: String) async -> LinuxGuestStatus {
        LinuxGuestStatus(
            environmentID: environmentID,
            running: active[environmentID] != nil,
            imageID: owned.contains(environmentID) ? "floe-image" : nil,
            ramMB: active[environmentID]?.ramMB
        )
    }
    func stopGuests(taskID: String) async {}
    func environmentsWithGuestActivity() async -> [String] { Array(active.keys) }
    func guestActivityDetails() async -> [LinuxGuestActivityDetail] {
        active.map { entry in
            LinuxGuestActivityDetail(
                environmentID: entry.key,
                ownerRunID: "task-1", // same trusted owner used by the manager fixture
                running: true,
                activeTerminalCount: entry.value.terminals,
                activeServiceCount: entry.value.services
            )
        }
    }
    func releaseTransientGuest(
        environmentID: String, expectedOwnerRunID: String
    ) async -> LinuxGuestTransientReleaseOutcome {
        .refused(reason: "not used")
    }

    func beginLifecycleTransaction(
        environmentID: String
    ) async throws -> LinuxGuestLifecycleTransaction? {
        transactionBegins += 1
        return LinuxGuestLifecycleTransaction(environmentID: environmentID, token: 1)
    }
    func endLifecycleTransaction(_ transaction: LinuxGuestLifecycleTransaction) async {
        transactionEnds += 1
    }
    func stopForLifecycleTransaction(_ transaction: LinuxGuestLifecycleTransaction) async {
        transactionStops += 1
        active.removeValue(forKey: transaction.environmentID)
    }
    func startForLifecycleTransaction(
        _ transaction: LinuxGuestLifecycleTransaction,
        taskID: String?,
        shape: GuestResourceRequest?
    ) async throws -> Bool {
        transactionStarts.append(
            "\(shape?.vcpus.count ?? -1)/\(shape?.memory.mb ?? -1)"
        )
        let vcpus = shape?.vcpus.count ?? 1
        let ramMB = shape?.memory.mb ?? 256
        nextGeneration += 1
        active[transaction.environmentID] = Guest(
            vcpus: vcpus, ramMB: ramMB, generation: nextGeneration,
            terminals: 0, services: 0
        )
        return true
    }
    func runForLifecycleTransaction(
        _ transaction: LinuxGuestLifecycleTransaction,
        argv: [String],
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        stageCommands.append(argv)
        if argv.first == "/bin/cat" {
            return LinuxCommandResult(stdout: "", stderr: "no file", exitCode: 1)
        }
        return LinuxCommandResult(stdout: "poweroff=/sbin/poweroff", stderr: "", exitCode: 0)
    }
    func requestOrderlyPoweroffForLifecycleTransaction(
        _ transaction: LinuxGuestLifecycleTransaction,
        poweroffPath: String,
        deadline: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestSoftRestartPoweroffOutcome {
        poweroffOutcome
    }
    func forwardService(environmentID: String, forward: LinuxGuestServiceForward) async throws {}
    func removeServiceForward(environmentID: String, forward: LinuxGuestServiceForward) async {}
    func openSession(
        environmentID: String, sessionID: String, argv: [String],
        workingDirectory: String?, columns: Int, rows: Int
    ) async throws {}
    func readSession(
        sessionID: String, maxBytes: Int, waitMs: Int
    ) async -> (output: Data, info: LinuxGuestSessionInfo)? { nil }
    func writeSession(sessionID: String, text: String) async throws {}
    func signalSession(sessionID: String, signal: LinuxGuestSessionSignal) async {}
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
    func closeSession(sessionID: String) async {}
    func sessionInfo(sessionID: String) async -> LinuxGuestSessionInfo? { nil }

    // test controls
    func setTerminals(_ environmentID: String, _ count: Int) {
        active[environmentID]?.terminals = count
    }
    func setServices(_ environmentID: String, _ count: Int) {
        active[environmentID]?.services = count
    }
    func setPoweroff(_ outcome: LinuxGuestSoftRestartPoweroffOutcome) {
        poweroffOutcome = outcome
    }
    func setLieAboutGrantedShape(_ value: Bool) { lieAboutGrantedShape = value }
}

// MARK: - helpers

private func makeRequest(
    environmentID: String = "env-soft",
    ownerTaskID: String = "task-1",
    operationKey: String = "call-1",
    config: LinuxGuestLifecycleConfig? = nil,
    shape: GuestResourceRequest? = GuestResourceRequest(vcpus: .one, memory: .m256),
    preBoot: LinuxGuestSoftRestartPreBoot? = LinuxGuestSoftRestartPreBoot(
        vcpus: 1, ramMB: 256, launchGeneration: 1, imageID: "floe-image"
    ),
    cancellation: CancellationToken? = nil
) -> LinuxGuestSoftRestartRequest {
    LinuxGuestSoftRestartRequest(
        environmentID: environmentID,
        ownerTaskID: ownerTaskID,
        operationKey: operationKey,
        config: config,
        shape: shape,
        transaction: LinuxGuestLifecycleTransaction(environmentID: environmentID, token: 1),
        preBoot: preBoot,
        servicesActive: 0,
        cancellation: cancellation
    )
}

private func makeOrchestrator(
    transport: FakeSoftRestartTransport,
    store: FakeSoftRestartStore
) -> LinuxGuestSoftRestartOrchestrator {
    LinuxGuestSoftRestartOrchestrator(
        transport: transport,
        store: store,
        flushTimeout: 0.2,
        poweroffDeadline: 0.2,
        bootTimeout: 0.2
    )
}

// MARK: - orchestrator stage contract

final class LinuxSoftRestartTests: XCTestCase {

    // MARK: ordered stage sequence and proofs

    func testHappyPathExecutesStagesInOrderAndCommits() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        let receipt = try await orchestrator.perform(makeRequest())

        XCTAssertEqual(receipt.phase, .running)
        XCTAssertFalse(receipt.reused)
        XCTAssertEqual(receipt.actualVCPUs, 1)
        XCTAssertEqual(receipt.actualMemoryMB, 256)
        XCTAssertEqual(receipt.launchGeneration, 2)
        XCTAssertNotNil(receipt.operationID)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["flush", "poweroff", "capture", "start", "readNonce"])

        guard let record = try await store.load(environmentID: "env-soft") else {
            return XCTFail("the committed operation record must persist")
        }
        XCTAssertEqual(record.status, .committed)
        XCTAssertEqual(record.progress, .diskCaptureCommitted)
        XCTAssertEqual(record.stageReceipts.map(\.stage), [
            .flush, .rebootRequest, .guestExit, .diskCapture, .newBoot
        ])
        XCTAssertTrue(record.stageReceipts.allSatisfy { $0.outcome == "ok" })
    }

    func testFlushExit127IsAnExplicitUnsupportedCapability() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setFlush(.success(LinuxCommandResult(
            stdout: "", stderr: "no poweroff binary in the guest image", exitCode: 127
        )))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("a missing guest capability must refuse explicitly")
        } catch let error as LinuxGuestLifecycleError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("expected capabilityUnsupported, got \(error)")
            }
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["flush"], "no stage may run after the capability refusal")
        guard let record = try await store.load(environmentID: "env-soft") else {
            return XCTFail("the failed record must persist for audit")
        }
        XCTAssertEqual(record.status, .failed)
    }

    func testFlushNonzeroExitIsAnHonestStageFailure() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setFlush(.success(LinuxCommandResult(
            stdout: "", stderr: "disk error", exitCode: 90
        )))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("a failed flush must not be reported as success")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartStageFailed(_, let stage, _) = error else {
                return XCTFail("expected softRestartStageFailed, got \(error)")
            }
            XCTAssertEqual(stage, LinuxGuestSoftRestartStage.flush.rawValue)
        }
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .failed)
    }

    func testPreSubmissionTransportErrorLeavesNoRecordAndRunsNoStage() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setFlushError(LinuxGuestError.consoleUnavailable("console closed before the flush"))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("the flush error must propagate")
        } catch let error as LinuxGuestError {
            guard case .consoleUnavailable = error else {
                return XCTFail("expected consoleUnavailable, got \(error)")
            }
        }
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertNil(record, "nothing was submitted; no durable record may remain")
    }

    func testPoweroffRefusedIsAKnownStageFailureNotAnUnknown() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setPoweroff(.refused(exitCode: 127, detail: "not found"))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("a refused poweroff must fail")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartStageFailed(_, let stage, _) = error else {
                return XCTFail("expected a known stage failure, got \(error)")
            }
            XCTAssertEqual(stage, LinuxGuestSoftRestartStage.rebootRequest.rawValue)
        }
        let calls = await transport.calls
        XCTAssertFalse(calls.contains(where: { $0.name == "capture" }))
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .failed)
    }

    func testUnconfirmedPoweroffStaysUnknownAndBlocksBlindRepeat() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setPoweroff(.unconfirmed(detail: "the guest stayed alive past the deadline"))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("an unconfirmed poweroff must not be a silent success")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartOutcomeUnknown = error else {
                return XCTFail("expected softRestartOutcomeUnknown, got \(error)")
            }
        }
        // No capture/restart may run while the outcome is unresolved.
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["flush", "poweroff"])
        guard let record = try await store.load(environmentID: "env-soft") else {
            return XCTFail("the unknown record must persist for reconciliation")
        }
        XCTAssertEqual(record.status, .pending)
        // The submission is journaled BEFORE the request crosses the
        // boundary: an unconfirmed outcome leaves a durable SUBMITTED
        // record, never a flush-only one that liveness could misread.
        XCTAssertEqual(record.progress, .poweroffSubmitted)
    }

    func testReplacementWithoutGenerationRotationIsUnproven() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setPostBoot(LinuxGuestSoftRestartPostBoot(
            vcpus: 1, ramMB: 256, launchGeneration: 1, imageID: "floe-image"
        ))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("an unrotated generation must not prove the reboot")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartStageFailed(_, let stage, _) = error else {
                return XCTFail("expected softRestartStageFailed, got \(error)")
            }
            XCTAssertEqual(stage, LinuxGuestSoftRestartStage.newBoot.rawValue)
        }
    }

    func testNonceMismatchFailsDiskContinuity() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setNonce("a-different-nonce")
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("a nonce mismatch must fail honestly")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartStageFailed(_, let stage, _) = error else {
                return XCTFail("expected softRestartStageFailed, got \(error)")
            }
            XCTAssertEqual(stage, LinuxGuestSoftRestartStage.newBoot.rawValue)
        }
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .failed)
    }

    func testReplacementShapeMismatchFails() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setPostBoot(LinuxGuestSoftRestartPostBoot(
            vcpus: 2, ramMB: 512, launchGeneration: 2, imageID: "floe-image"
        ))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("a shape mismatch must fail honestly")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartStageFailed(_, let stage, _) = error else {
                return XCTFail("expected softRestartStageFailed, got \(error)")
            }
            XCTAssertEqual(stage, LinuxGuestSoftRestartStage.newBoot.rawValue)
        }
    }

    func testFreshOperationRequiresTheCapturedRunningGuest() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest(preBoot: nil))
            XCTFail("a soft restart without a running guest must refuse")
        } catch let error as LinuxGuestLifecycleError {
            guard case .guestNotRunning = error else {
                return XCTFail("expected guestNotRunning, got \(error)")
            }
        }
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertNil(record)
    }

    // MARK: cancellation at every boundary

    func testCancellationBeforeAnyStageIsCleanAndLeavesNoRecord() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let token = CancellationToken()
        token.cancel()
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest(cancellation: token))
            XCTFail("a pre-submit cancellation must surface")
        } catch FloeError.cancelled {
            // expected: clean cancellation before any guest action
        }
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertNil(record)
    }

    // MARK: reconciliation / dedup

    private func makePendingOperation(
        environmentID: String = "env-soft",
        operationID: String = "op-1",
        progress: LinuxGuestSoftRestartProgress,
        preGeneration: UInt64 = 1
    ) -> LinuxGuestSoftRestartOperation {
        LinuxGuestSoftRestartOperation(
            operationID: operationID,
            environmentID: environmentID,
            ownerTaskID: "task-1",
            operationKey: "call-1",
            requestedVCPUs: nil,
            requestedMemoryMB: nil,
            resolvedShape: GuestResourceRequest(vcpus: .one, memory: .m256),
            preLaunchGeneration: preGeneration,
            preVCPUs: 1,
            preMemoryMB: 256,
            preImageID: "floe-image",
            progress: progress,
            status: .pending,
            stageReceipts: [],
            failure: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    func testInterruptedOperationConvergesCommittedWithoutRebootingAgain() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.seed(makePendingOperation(
            progress: .poweroffSubmitted, preGeneration: 1
        ))
        // The reboot already happened: rotated generation + nonce readback.
        await transport.setProbe(LinuxGuestSoftRestartBootProbe(
            running: true, vcpus: 1, ramMB: 256,
            launchGeneration: 2, imageID: "floe-image", bootNonce: "op-1"
        ))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        let receipt = try await orchestrator.perform(makeRequest())

        XCTAssertEqual(receipt.phase, .running)
        XCTAssertEqual(receipt.launchGeneration, 2)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["probe"], "a converged operation must not reboot again")
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .committed)
    }

    func testInterruptedFlushConvergesFailedThenAFreshAttemptProceeds() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.seed(makePendingOperation(progress: .flushProven, preGeneration: 1))
        // Same generation, nonce present: the guest never rebooted.
        await transport.setProbe(LinuxGuestSoftRestartBootProbe(
            running: true, vcpus: 1, ramMB: 256,
            launchGeneration: 1, imageID: "floe-image", bootNonce: "op-1"
        ))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        let receipt = try await orchestrator.perform(makeRequest())
        XCTAssertEqual(receipt.phase, .running)
        let calls = await transport.calls
        XCTAssertEqual(
            calls.map(\.name),
            ["probe", "flush", "poweroff", "capture", "start", "readNonce"]
        )
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertNotEqual(record?.operationID, "op-1", "the fresh attempt replaces the settled record")
        XCTAssertEqual(record?.status, .committed)
    }

    func testSubmittedPoweroffAliveAtSameGenerationHoldsUnknownAndBlocksReissue() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.seed(makePendingOperation(progress: .poweroffSubmitted, preGeneration: 1))
        // The machine reports alive at the same generation with the nonce
        // still present. The submission IS durable: liveness is never proof
        // the request failed (a late poweroff can still land), so the outcome
        // must hold unknown and block another reboot instead of settling
        // failed and reissuing.
        await transport.setProbe(LinuxGuestSoftRestartBootProbe(
            running: true, vcpus: 1, ramMB: 256,
            launchGeneration: 1, imageID: "floe-image", bootNonce: "op-1"
        ))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("a submitted-but-unconfirmed poweroff with a live machine must not be reissued")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartOutcomeUnknown = error else {
                return XCTFail("expected softRestartOutcomeUnknown, got \(error)")
            }
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["probe"], "no guest stage may run while the submitted outcome is unresolved")
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .pending, "the submitted record must not be settled from simple liveness")
        XCTAssertEqual(record?.progress, .poweroffSubmitted)
    }

    /// A late poweroff that lands after the submission: the machine goes
    /// down; the retry converges through capture → boot → nonce readback —
    /// WITHOUT re-running the flush or re-submitting the poweroff.
    func testLatePoweroffAfterSubmissionConvergesWithoutResubmission() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.seed(makePendingOperation(progress: .poweroffSubmitted, preGeneration: 1))
        await transport.setProbe(LinuxGuestSoftRestartBootProbe(running: false))
        // This recovery fixture starts after flush: the captured disk must
        // already contain the original operation's nonce, not a fresh flush.
        await transport.setNonce("op-1")
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        let receipt = try await orchestrator.perform(makeRequest(preBoot: nil))
        XCTAssertEqual(receipt.phase, .running)
        let calls = await transport.calls
        XCTAssertEqual(
            calls.map(\.name),
            ["probe", "capture", "start", "readNonce"],
            "a submitted late poweroff resumes from the capture; no flush or poweroff re-submission"
        )
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .committed)
    }

    func testUnresolvedOperationBlocksTheRetryTruthfully() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.seed(makePendingOperation(progress: .poweroffSubmitted, preGeneration: 1))
        // Same generation but the nonce is gone without a reboot: the guest
        // state is inconsistent — the outcome must stay unresolved.
        await transport.setProbe(LinuxGuestSoftRestartBootProbe(
            running: true, vcpus: 1, ramMB: 256,
            launchGeneration: 1, imageID: "floe-image", bootNonce: nil
        ))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("an unresolved outcome must block the blind repeat")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartOutcomeUnknown = error else {
                return XCTFail("expected softRestartOutcomeUnknown, got \(error)")
            }
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["probe"], "no guest stage may run")
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .pending)
    }

    func testInterruptedOperationResumesFromTheCommittedCapture() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.seed(makePendingOperation(progress: .diskCaptureCommitted, preGeneration: 1))
        // The machine is down; the capture is durable. The retry must boot
        // the recorded shape WITHOUT re-running any guest stage.
        await transport.setProbe(LinuxGuestSoftRestartBootProbe(running: false))
        // This recovery fixture starts after flush: the captured disk must
        // already contain the original operation's nonce, not a fresh flush.
        await transport.setNonce("op-1")
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        let receipt = try await orchestrator.perform(makeRequest(preBoot: nil))
        XCTAssertEqual(receipt.phase, .running)
        XCTAssertEqual(receipt.launchGeneration, 2)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["probe", "start", "readNonce"], "no duplicate capture or flush")
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .committed)
    }

    func testInterruptedExitObservationResumesCaptureThenBoot() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.seed(makePendingOperation(progress: .guestExitObserved, preGeneration: 1))
        await transport.setProbe(LinuxGuestSoftRestartBootProbe(running: false))
        // This recovery fixture starts after flush: the captured disk must
        // already contain the original operation's nonce, not a fresh flush.
        await transport.setNonce("op-1")
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        let receipt = try await orchestrator.perform(makeRequest(preBoot: nil))
        XCTAssertEqual(receipt.phase, .running)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["probe", "capture", "start", "readNonce"])
    }

    // MARK: persistence contract

    func testTheDurableRecordExistsBeforeAnyGuestAction() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        // The flush hook runs INSIDE the first guest stage; the record must
        // already be durable at that point.
        final class Box: @unchecked Sendable {
            var seen: LinuxGuestSoftRestartOperation?
        }
        let box = Box()
        await transport.setFlushHook { [box] in
            box.seen = try? await store.load(environmentID: "env-soft")
        }
        let orchestrator = makeOrchestrator(transport: transport, store: store)
        _ = try await orchestrator.perform(makeRequest())
        XCTAssertNotNil(box.seen, "the pending record must exist before the guest action")
        XCTAssertEqual(box.seen?.status, .pending)
    }
}

// MARK: - manager seam

final class LinuxSoftRestartManagerTests: XCTestCase {

    private func makeManager(
        controller: SoftRestartLifecycleFake,
        transport: FakeSoftRestartTransport,
        store: FakeSoftRestartStore
    ) -> LinuxGuestLifecycleManager {
        let orchestrator = LinuxGuestSoftRestartOrchestrator(
            transport: transport,
            store: store,
            flushTimeout: 0.2,
            poweroffDeadline: 0.2,
            bootTimeout: 0.2
        )
        return LinuxGuestLifecycleManager(
            controller: controller,
            softRestartPerformer: { request in
                await transport.setLifecycleController(controller)
                return try await orchestrator.perform(request)
            },
            stopVerificationTimeout: 0.2
        )
    }

    func testManagerRunsTheOrderedOperationUnderOneTransaction() async throws {
        let controller = SoftRestartLifecycleFake()
        await controller.own("env-mgr", vcpus: 1, ramMB: 256)
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let manager = makeManager(controller: controller, transport: transport, store: store)

        let receipt = try await manager.softRestart(
            environmentID: "env-mgr",
            config: nil,
            ownerTaskID: "task-1",
            operationKey: "call-1"
        )

        XCTAssertEqual(receipt.phase, .running)
        XCTAssertNotNil(receipt.operationID)
        let begins = await controller.transactionBegins
        let ends = await controller.transactionEnds
        XCTAssertEqual(begins, 1, "exactly one shared transaction")
        XCTAssertEqual(ends, 1, "the transaction is released on success")
        let starts = await controller.transactionStarts
        XCTAssertEqual(starts, ["1/256"], "the replacement start carries the preserved shape")
        let calls = await transport.calls
        XCTAssertEqual(
            calls.map(\.name),
            ["flush", "poweroff", "capture", "start", "readNonce"],
            "the ordered stages run in exactly this sequence"
        )
    }

    func testManagerRefusesWhileAnotherLifecycleOperationOwnsTheEnvironment() async throws {
        let controller = SoftRestartLifecycleFake()
        await controller.own("env-mgr")
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let manager = makeManager(controller: controller, transport: transport, store: store)
        let id = "env-mgr"

        // Park the first soft restart inside its flush stage (the durable
        // record is already persisted and the manager busy flag is held).
        let gate = SoftRestartGate()
        await transport.setFlushHook { await gate.arriveAndPark() }
        let first = Task {
            try await manager.softRestart(environmentID: id, config: nil)
        }
        await gate.waitForArrival()
        do {
            _ = try await manager.softRestart(environmentID: id, config: nil)
            XCTFail("a concurrent soft restart must be refused while the first owns the environment")
        } catch let error as LinuxGuestLifecycleError {
            guard case .busy = error else {
                return XCTFail("expected busy, got \(error)")
            }
        }
        await gate.release()
        let receipt = try await first.value
        XCTAssertEqual(receipt.phase, .running)
        let begins = await controller.transactionBegins
        XCTAssertEqual(begins, 1)
    }

    func testManagerRefusesOpenInteractiveTerminalsBeforeAnyDisruption() async throws {
        let controller = SoftRestartLifecycleFake()
        await controller.own("env-mgr")
        await controller.setTerminals("env-mgr", 1)
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let manager = makeManager(controller: controller, transport: transport, store: store)

        do {
            _ = try await manager.softRestart(environmentID: "env-mgr", config: nil)
            XCTFail("an open terminal must block the disruptive soft restart")
        } catch let error as LinuxGuestLifecycleError {
            guard case .activeInteractiveTerminal = error else {
                return XCTFail("expected activeInteractiveTerminal, got \(error)")
            }
        }
        let begins = await controller.transactionBegins
        XCTAssertEqual(begins, 0, "no transaction may begin before the refusal")
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testManagerPostVerificationCatchesADishonestReceipt() async throws {
        let controller = SoftRestartLifecycleFake()
        await controller.own("env-mgr", vcpus: 1, ramMB: 256)
        // Keep admission/preBoot truthful. Inject the dishonest performer
        // exactly at the manager seam, AFTER it captured the 1/256 request.
        // Otherwise the orchestrator correctly rejects the already-wrong
        // preBoot shape before the manager post-verification can be tested.
        let manager = LinuxGuestLifecycleManager(controller: controller,
            softRestartPerformer: { request in
                await controller.setLieAboutGrantedShape(true)
                return LinuxGuestLifecycleReceipt(phase: .running,
                    environmentID: request.environmentID, actualVCPUs: 1,
                    actualMemoryMB: 256, reused: false, launchGeneration: 1,
                    capability: "scripted dishonest performer",
                    detail: "deliberately disagrees with the controller's post-operation shape")
            }, stopVerificationTimeout: 0.2)

        do {
            _ = try await manager.softRestart(environmentID: "env-mgr", config: nil)
            XCTFail("a receipt that disagrees with the runtime truth must fail")
        } catch let error as LinuxGuestLifecycleError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("expected capabilityUnsupported, got \(error)")
            }
        }
        let ends = await controller.transactionEnds
        XCTAssertEqual(ends, 1, "the transaction is still released on the verification failure")
    }

    func testManagerPropagatesTheUnknownOutcomeAndKeepsTheTransactionReleased() async throws {
        let controller = SoftRestartLifecycleFake()
        await controller.own("env-mgr")
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setPoweroff(.unconfirmed(detail: "the guest stayed alive past the deadline"))
        let manager = makeManager(controller: controller, transport: transport, store: store)

        do {
            _ = try await manager.softRestart(environmentID: "env-mgr", config: nil)
            XCTFail("the unknown outcome must surface")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartOutcomeUnknown = error else {
                return XCTFail("expected softRestartOutcomeUnknown, got \(error)")
            }
        }
        let ends = await controller.transactionEnds
        XCTAssertEqual(ends, 1)
        let record = try await store.load(environmentID: "env-mgr")
        XCTAssertEqual(record?.status, .pending, "the unknown stays reconcilable")
    }

    func testDistinctEnvironmentsAreIsolated() async throws {
        let controller = SoftRestartLifecycleFake()
        await controller.own("env-a")
        await controller.own("env-b")
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.seed(LinuxGuestSoftRestartOperation(
            operationID: "op-a",
            environmentID: "env-a",
            resolvedShape: GuestResourceRequest(vcpus: .one, memory: .m256),
            preVCPUs: 1, preMemoryMB: 256,
            progress: .poweroffSubmitted, status: .pending
        ))
        let manager = makeManager(controller: controller, transport: transport, store: store)

        // env-b runs fresh and clean even though env-a has an unresolved op.
        let receipt = try await manager.softRestart(environmentID: "env-b", config: nil)
        XCTAssertEqual(receipt.phase, .running)
        let recordA = try await store.load(environmentID: "env-a")
        XCTAssertEqual(recordA?.status, .pending, "env-a's unresolved record is untouched")
        let recordB = try await store.load(environmentID: "env-b")
        XCTAssertEqual(recordB?.status, .committed)
    }

    func testUnresolvedRetryThroughTheManagerConvergesInsteadOfRebooting() async throws {
        let controller = SoftRestartLifecycleFake()
        await controller.own("env-mgr")
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.seed(LinuxGuestSoftRestartOperation(
            operationID: "op-1",
            environmentID: "env-mgr",
            resolvedShape: GuestResourceRequest(vcpus: .one, memory: .m256),
            preLaunchGeneration: 1, preVCPUs: 1, preMemoryMB: 256,
            progress: .poweroffSubmitted, status: .pending
        ))
        // Model the replacement that already booted before this retry.
        await controller.own("env-mgr") // authoritative generation 2
        // The earlier reboot completed: the probe shows the rotated
        // generation and the nonce readback. The retry must return the
        // ORIGINAL operation's receipt without rebooting again.
        await transport.setProbe(LinuxGuestSoftRestartBootProbe(
            running: true, vcpus: 1, ramMB: 256,
            launchGeneration: 2, imageID: "floe-image", bootNonce: "op-1"
        ))
        let manager = makeManager(controller: controller, transport: transport, store: store)

        let receipt = try await manager.softRestart(
            environmentID: "env-mgr", config: nil
        )
        XCTAssertEqual(receipt.phase, .running)
        XCTAssertEqual(receipt.operationID, "op-1", "the retry returns the ORIGINAL operation's receipt")
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["probe"], "no guest stage may re-run")
        let record = try await store.load(environmentID: "env-mgr")
        XCTAssertEqual(record?.status, .committed)
    }
}

// MARK: - committed receipt dedup

final class LinuxSoftRestartDedupTests: XCTestCase {

    private func makeOrchestrator(
        transport: FakeSoftRestartTransport,
        store: FakeSoftRestartStore
    ) -> LinuxGuestSoftRestartOrchestrator {
        LinuxGuestSoftRestartOrchestrator(
            transport: transport,
            store: store,
            flushTimeout: 0.2,
            poweroffDeadline: 0.2,
            bootTimeout: 0.2
        )
    }

    /// An exact retry of a committed operation returns the ORIGINAL receipt
    /// and runs no guest stage at all.
    func testExactCommittedRetryReturnsTheOriginalReceiptWithoutRebooting() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        let first = try await orchestrator.perform(makeRequest())
        let callsAfterFirst = await transport.calls
        XCTAssertEqual(callsAfterFirst.map(\.name), ["flush", "poweroff", "capture", "start", "readNonce"])

        let retry = try await orchestrator.perform(makeRequest())
        XCTAssertEqual(retry, first, "the exact retry must receive the original receipt verbatim")
        let callsAfterRetry = await transport.calls
        XCTAssertEqual(callsAfterRetry.map(\.name), callsAfterFirst.map(\.name), "no stage may re-run")
        let committedRecords = await store.committedRecordCount
        XCTAssertEqual(committedRecords, 1, "the retry must not record a second committed receipt")
    }

    /// The committed receipt survives a COMPLETED later operation: op A
    /// commits under key K1, op B runs to completion under K2 (overwriting
    /// the latest record), then a retry of A still converges on A's original
    /// receipt — it must not reboot again.
    func testCommittedRetrySurvivesACompletedLaterOperation() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        let receiptA = try await orchestrator.perform(makeRequest(operationKey: "call-A"))
        _ = try await orchestrator.perform(makeRequest(operationKey: "call-B"))
        let callsAfterB = await transport.calls
        XCTAssertEqual(
            callsAfterB.map(\.name),
            ["flush", "poweroff", "capture", "start", "readNonce",
             "flush", "poweroff", "capture", "start", "readNonce"]
        )

        let retryA = try await orchestrator.perform(makeRequest(operationKey: "call-A"))
        XCTAssertEqual(retryA, receiptA, "A's original receipt must be returned, not a reboot")
        XCTAssertEqual(retryA.operationID, receiptA.operationID)
        let callsAfterRetry = await transport.calls
        XCTAssertEqual(callsAfterRetry.map(\.name), callsAfterB.map(\.name), "no stage may re-run")
    }

    /// A same-key call with a CHANGED payload (different requested/resolved
    /// shape) is refused — never silently deduplicated onto a different
    /// request's receipt.
    func testSameOperationKeyWithAChangedPayloadIsRefused() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        _ = try await orchestrator.perform(makeRequest(operationKey: "call-1"))

        let changed = makeRequest(
            operationKey: "call-1",
            config: LinuxGuestLifecycleConfig(vcpus: 2, memoryMB: 512),
            shape: GuestResourceRequest(vcpus: .two, memory: .m512)
        )
        do {
            _ = try await orchestrator.perform(changed)
            XCTFail("a same-key call with a changed payload must refuse")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartIdempotencyConflict = error else {
                return XCTFail("expected softRestartIdempotencyConflict, got \(error)")
            }
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["flush", "poweroff", "capture", "start", "readNonce"], "no stage may run for the refused call")
    }

    /// A same-key call from a DIFFERENT trusted owner is refused: committed
    /// receipts are not shared across logical runs (the existing run-identity
    /// API, not a model-authored label).
    func testSameOperationKeyFromADifferentOwnerIsRefused() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        _ = try await orchestrator.perform(makeRequest(ownerTaskID: "task-1", operationKey: "call-1"))

        do {
            _ = try await orchestrator.perform(makeRequest(ownerTaskID: "task-2", operationKey: "call-1"))
            XCTFail("a same-key call from a different owner must refuse")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartIdempotencyConflict = error else {
                return XCTFail("expected softRestartIdempotencyConflict, got \(error)")
            }
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["flush", "poweroff", "capture", "start", "readNonce"])
    }

    /// Post-submission cancellation never retracts a submitted poweroff:
    /// the stage reports the real outcome (committed), not a clean cancel.
    func testPostSubmissionCancellationStillReportsTheCommittedOutcome() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        let token = CancellationToken()
        // Cancel the caller's token from INSIDE the poweroff stage — after
        // the submission was journaled.
        await transport.setPoweroffHook { token.cancel() }
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        let receipt = try await orchestrator.perform(makeRequest(cancellation: token))
        XCTAssertEqual(receipt.phase, .running, "the committed outcome is reported even though the caller cancelled")
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .committed)
    }

    /// The submission journal is persisted BEFORE the poweroff request
    /// crosses the boundary: inside the poweroff stage the durable record
    /// already reads `.poweroffSubmitted`.
    func testSubmissionIsJournaledBeforeThePoweroffRequest() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        final class Box: @unchecked Sendable {
            var seen: LinuxGuestSoftRestartProgress?
        }
        let box = Box()
        await transport.setPoweroffHook { [box] in
            box.seen = try? await store.load(environmentID: "env-soft")?.progress
        }
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        _ = try await orchestrator.perform(makeRequest())
        XCTAssertEqual(box.seen, .poweroffSubmitted, "the submission must be durable before the request crosses the boundary")
    }

    // MARK: persistence failures are reported truthfully

    func testStoreFailureWhileSettlingARefusedPoweroffIsReported() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setPoweroff(.refused(exitCode: 127, detail: "not found"))
        // Saves 1-3 succeed (record, flushProven, poweroffSubmitted); the
        // failure-settlement save (#4) throws.
        await store.setSaveFailureThreshold(4)
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("a settlement persistence failure must surface")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartPersistenceFailed = error else {
                return XCTFail("expected softRestartPersistenceFailed, got \(error)")
            }
        }
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .pending, "the record was never silently settled")
    }

    func testStoreFailureDuringReconciliationFailsClosedAndRebootsNothing() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.setLoadError(LinuxGuestSoftRestartStoreError.io(
            environmentID: "env-soft", operation: "read", detail: "scripted I/O failure"
        ))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("an unreadable durable record must fail closed")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartPersistenceFailed = error else {
                return XCTFail("expected softRestartPersistenceFailed, got \(error)")
            }
        }
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty, "no guest stage may run while the record is unreadable")
    }

    func testCommittedReceiptLoadFailureFailsClosedAndRebootsNothing() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await store.setCommittedLoadError(LinuxGuestSoftRestartStoreError.io(
            environmentID: "env-soft", operation: "read", detail: "scripted journal failure"
        ))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("an unreadable committed-receipt journal must fail closed")
        } catch let error as LinuxGuestLifecycleError {
            guard case .softRestartPersistenceFailed = error else {
                return XCTFail("expected softRestartPersistenceFailed, got \(error)")
            }
        }
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty, "no guest stage may run while the journal is unreadable")
    }

    /// Pre-submission cancel cleanup: when the record removal itself fails,
    /// the original error still surfaces truthfully and the stale pending
    /// record is left for reconciliation (never silently dropped).
    func testPreSubmissionCancelRemoveFailureKeepsAReconcilableRecord() async throws {
        let transport = FakeSoftRestartTransport()
        let store = FakeSoftRestartStore()
        await transport.setFlushError(LinuxGuestError.consoleUnavailable("console closed before the flush"))
        await store.setRemoveError(LinuxGuestSoftRestartStoreError.io(
            environmentID: "env-soft", operation: "remove", detail: "scripted remove failure"
        ))
        let orchestrator = makeOrchestrator(transport: transport, store: store)

        do {
            _ = try await orchestrator.perform(makeRequest())
            XCTFail("the flush error must propagate")
        } catch let error as LinuxGuestError {
            guard case .consoleUnavailable = error else {
                return XCTFail("expected the original consoleUnavailable, got \(error)")
            }
        }
        let record = try await store.load(environmentID: "env-soft")
        XCTAssertEqual(record?.status, .pending, "the unremovable record stays pending for reconciliation")
        XCTAssertEqual(record?.progress, .recorded)
        let failedAttemptCalls = await transport.calls
        XCTAssertEqual(failedAttemptCalls.map(\.name), ["flush"], "the original failed flush must remain observable")

        // The next call reconciles the stale record (machine alive, never
        // submitted) to failed and proceeds with a fresh attempt.
        await store.setRemoveError(nil)
        await transport.setFlushError(nil)
        await transport.setProbe(LinuxGuestSoftRestartBootProbe(running: true,
            vcpus: 1, ramMB: 256, launchGeneration: 1, imageID: "floe-image"))
        let receipt = try await orchestrator.perform(makeRequest())
        XCTAssertEqual(receipt.phase, .running)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["flush", "probe", "flush", "poweroff", "capture", "start", "readNonce"],
            "preserve the failed attempt, then reconcile before the one fresh ordered operation")
    }
}

// MARK: - real file store (fail-closed)

final class LinuxSoftRestartFileStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-soft-restart-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> LinuxGuestFileSoftRestartStore {
        LinuxGuestFileSoftRestartStore(directory: directory)
    }

    private func makeOperation(environmentID: String) -> LinuxGuestSoftRestartOperation {
        LinuxGuestSoftRestartOperation(
            operationID: UUID().uuidString,
            environmentID: environmentID,
            resolvedShape: GuestResourceRequest(vcpus: .one, memory: .m256),
            preVCPUs: 1,
            preMemoryMB: 256
        )
    }

    private func makeReceipt(environmentID: String) -> LinuxGuestLifecycleReceipt {
        LinuxGuestLifecycleReceipt(
            phase: .running,
            environmentID: environmentID,
            actualVCPUs: 1,
            actualMemoryMB: 256,
            reused: false,
            launchGeneration: 2,
            operationID: UUID().uuidString,
            capability: "test capability",
            detail: "test receipt"
        )
    }

    private func makeCommitted(
        environmentID: String, key: String, committedAt: Date = Date()
    ) -> LinuxGuestSoftRestartCommittedReceipt {
        LinuxGuestSoftRestartCommittedReceipt(
            environmentID: environmentID,
            operationKey: key,
            ownerTaskID: "task-1",
            resolvedShape: GuestResourceRequest(vcpus: .one, memory: .m256),
            receipt: makeReceipt(environmentID: environmentID),
            committedAt: committedAt
        )
    }

    func testRoundTripAndTrueAbsence() async throws {
        let store = makeStore()
        // A genuinely absent record is the ONLY nil result.
        let missing = try await store.load(environmentID: "env-a")
        XCTAssertNil(missing)

        let operation = makeOperation(environmentID: "env-a")
        try await store.save(operation)
        let loaded = try await store.load(environmentID: "env-a")
        XCTAssertEqual(loaded, operation)

        try await store.remove(environmentID: "env-a")
        let removed = try await store.load(environmentID: "env-a")
        XCTAssertNil(removed)
        // Removing an absent record is success (ENOENT), not an error.
        try await store.remove(environmentID: "env-a")
    }

    func testDistinctEnvironmentsStayIsolatedOnDisk() async throws {
        let store = makeStore()
        let a = makeOperation(environmentID: "env-a")
        let b = makeOperation(environmentID: "env-b")
        try await store.save(a)
        try await store.save(b)
        let awaitedAssertionValue1 = try await store.load(environmentID: "env-a")
        XCTAssertEqual(awaitedAssertionValue1, a)
        let awaitedAssertionValue2 = try await store.load(environmentID: "env-b")
        XCTAssertEqual(awaitedAssertionValue2, b)
        try await store.remove(environmentID: "env-a")
        let awaitedAssertionValue3 = try await store.load(environmentID: "env-a")
        XCTAssertNil(awaitedAssertionValue3)
        let awaitedAssertionValue4 = try await store.load(environmentID: "env-b")
        XCTAssertEqual(awaitedAssertionValue4, b)
    }

    func testCorruptRecordThrowsFailsClosedAndPreservesTheBytes() async throws {
        let store = makeStore()
        let envDirectory = directory.appendingPathComponent("env-a", isDirectory: true)
        try FileManager.default.createDirectory(at: envDirectory, withIntermediateDirectories: true)
        let file = envDirectory.appendingPathComponent("soft-restart-operation.json")
        let garbage = Data("this is not a json record".utf8)
        try garbage.write(to: file)

        do {
            _ = try await store.load(environmentID: "env-a")
            XCTFail("a corrupt record must throw, never read as absent")
        } catch let error as LinuxGuestSoftRestartStoreError {
            guard case .corruptRecord(let id, let preserved) = error else {
                return XCTFail("expected corruptRecord, got \(error)")
            }
            XCTAssertEqual(id, "env-a")
            XCTAssertNotNil(preserved)
        }
        // The original file was quarantined, not deleted; its bytes survive.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: envDirectory.path)
        let preservedFile = siblings.first { $0.hasPrefix("soft-restart-operation.json.corrupt-") }
        let preservedData = preservedFile.map {
            try? Data(contentsOf: envDirectory.appendingPathComponent($0))
        } ?? nil
        XCTAssertEqual(preservedData, garbage)
    }

    func testForeignIdentityRecordThrowsFailsClosed() async throws {
        let store = makeStore()
        try await store.save(makeOperation(environmentID: "env-other"))
        // Move the foreign record into env-a's path: decodable, but the
        // environment identity mismatches — never trusted.
        let otherDirectory = directory.appendingPathComponent("env-other", isDirectory: true)
        let aDirectory = directory.appendingPathComponent("env-a", isDirectory: true)
        try FileManager.default.moveItem(at: otherDirectory, to: aDirectory)

        do {
            _ = try await store.load(environmentID: "env-a")
            XCTFail("a foreign-environment record must throw")
        } catch let error as LinuxGuestSoftRestartStoreError {
            guard case .corruptRecord(let id, _) = error else {
                return XCTFail("expected corruptRecord, got \(error)")
            }
            XCTAssertEqual(id, "env-a")
        }
    }

    func testOversizedRecordThrowsFailsClosed() async throws {
        let store = makeStore()
        let envDirectory = directory.appendingPathComponent("env-a", isDirectory: true)
        try FileManager.default.createDirectory(at: envDirectory, withIntermediateDirectories: true)
        let file = envDirectory.appendingPathComponent("soft-restart-operation.json")
        let huge = Data(repeating: 0, count: Int(LinuxGuestFileSoftRestartStore.maxRecordBytes) + 16)
        try huge.write(to: file)

        do {
            _ = try await store.load(environmentID: "env-a")
            XCTFail("an oversized record must throw, never be decoded")
        } catch let error as LinuxGuestSoftRestartStoreError {
            guard case .oversizedRecord(let id, _, _) = error else {
                return XCTFail("expected oversizedRecord, got \(error)")
            }
            XCTAssertEqual(id, "env-a")
        }
    }

    func testTraversalAndControlCharacterIdsAreRefused() async throws {
        let store = makeStore()
        for hostileID in ["..", "../escape", "a/b", "a\\b", "a\0b", "", String(repeating: "x", count: 200)] {
            do {
                _ = try await store.load(environmentID: hostileID)
                XCTFail("load must refuse the hostile id '\(hostileID)'")
            } catch LinuxGuestSoftRestartStoreError.invalidEnvironmentID {
                // expected
            }
            do {
                try await store.save(makeOperation(environmentID: hostileID))
                XCTFail("save must refuse the hostile id '\(hostileID)'")
            } catch LinuxGuestSoftRestartStoreError.invalidEnvironmentID {
                // expected
            }
            do {
                try await store.remove(environmentID: hostileID)
                XCTFail("remove must refuse the hostile id '\(hostileID)'")
            } catch LinuxGuestSoftRestartStoreError.invalidEnvironmentID {
                // expected
            }
        }
        // Nothing escaped the store root.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testSymlinkedEnvironmentDirectoryIsRefused() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-soft-restart-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let store = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("env-a", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        do {
            _ = try await store.load(environmentID: "env-a")
            XCTFail("a symlinked environment directory must throw")
        } catch let error as LinuxGuestSoftRestartStoreError {
            guard case .unsafeSymbolicLink = error else {
                return XCTFail("expected unsafeSymbolicLink, got \(error)")
            }
        }
        do {
            try await store.save(makeOperation(environmentID: "env-a"))
            XCTFail("a symlinked environment directory must throw on save")
        } catch let error as LinuxGuestSoftRestartStoreError {
            guard case .unsafeSymbolicLink = error else {
                return XCTFail("expected unsafeSymbolicLink, got \(error)")
            }
        }
    }

    func testCommittedReceiptsJournalRoundTripLookupAndIsolation() async throws {
        let store = makeStore()
        let first = makeCommitted(environmentID: "env-a", key: "call-1")
        let second = makeCommitted(environmentID: "env-a", key: "call-2")
        try await store.recordCommittedReceipt(first)
        try await store.recordCommittedReceipt(second)

        let awaitedAssertionValue5 = try await store.loadCommittedReceipt(environmentID: "env-a", operationKey: "call-1")
        XCTAssertEqual(awaitedAssertionValue5,
            first
        )
        let awaitedAssertionValue6 = try await store.loadCommittedReceipt(environmentID: "env-a", operationKey: "call-2")
        XCTAssertEqual(awaitedAssertionValue6,
            second
        )
        let awaitedAssertionValue7 = try await store.loadCommittedReceipt(environmentID: "env-a", operationKey: "call-3")
        XCTAssertNil(awaitedAssertionValue7)
        // Distinct environments never see each other's journal.
        let awaitedAssertionValue8 = try await store.loadCommittedReceipt(environmentID: "env-b", operationKey: "call-1")
        XCTAssertNil(awaitedAssertionValue8)
    }

    func testCommittedReceiptsJournalBoundEvictsOldestCommittedOnly() async throws {
        let store = makeStore()
        let bound = LinuxGuestFileSoftRestartStore.maxCommittedReceipts
        for index in 0..<(bound + 2) {
            try await store.recordCommittedReceipt(makeCommitted(
                environmentID: "env-a",
                key: "call-\(index)",
                committedAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        // The two oldest committed receipts are evicted by the explicit
        // bound; the newest survive.
        for key in ["call-0", "call-1"] {
            do {
                _ = try await store.loadCommittedReceipt(environmentID: "env-a", operationKey: key)
                XCTFail("Eviction must hold an old retry, not classify it as a new operation")
            } catch let error as LinuxGuestSoftRestartStoreError {
                guard case .expiredReceipt = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        // Filter survives reopening the store and cannot be bypassed by
        // attempting to append a different receipt under an evicted key.
        do {
            try await store.recordCommittedReceipt(makeCommitted(environmentID: "env-a", key: "call-0"))
            XCTFail("An evicted key must not be reintroduced as a new operation")
        } catch let error as LinuxGuestSoftRestartStoreError {
            guard case .expiredReceipt = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let awaitedAssertionValue9 = try await store.loadCommittedReceipt(environmentID: "env-a", operationKey: "call-2")
        XCTAssertNotNil(awaitedAssertionValue9)
        let awaitedAssertionValue10 = try await store.loadCommittedReceipt(
            environmentID: "env-a", operationKey: "call-\(bound + 1)"
        )
        XCTAssertNotNil(awaitedAssertionValue10)
    }

    func testCorruptCommittedReceiptsJournalThrowsFailsClosed() async throws {
        let store = makeStore()
        try await store.recordCommittedReceipt(makeCommitted(environmentID: "env-a", key: "call-1"))
        let envDirectory = directory.appendingPathComponent("env-a", isDirectory: true)
        let file = envDirectory.appendingPathComponent("soft-restart-receipts.json")
        try Data("broken".utf8).write(to: file)

        do {
            _ = try await store.loadCommittedReceipt(environmentID: "env-a", operationKey: "call-1")
            XCTFail("a corrupt journal must throw, never read as absent")
        } catch let error as LinuxGuestSoftRestartStoreError {
            guard case .corruptRecord = error else {
                return XCTFail("expected corruptRecord, got \(error)")
            }
        }
    }
}

// MARK: - registry poweroff race (real channel, scripted console)

/// Scripted engine for the raced poweroff tests: starts/stops under a lock
/// and optionally powers down when the next console command is issued (the
/// orderly poweroff landing).
private final class PoweroffRaceEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var powerDownOnNextCommand = false
    private var holdOnNextCommand = false
    private var issuedCount = 0
    enum CommandBehavior { case poweredOff, held, complete }

    func armPowerDown() { lock.withLock { powerDownOnNextCommand = true } }
    func armHold() { lock.withLock { holdOnNextCommand = true } }
    var commandsIssued: Int { lock.withLock { issuedCount } }

    func start() { lock.withLock { running = true } }
    func stop() { lock.withLock { running = false } }
    var isRunning: Bool { lock.withLock { running } }

    /// Called once per inline EXEC or completed chunked RUN. A held
    /// command emits BEGIN but no END until the real channel interrupts it.
    func commandIssued() -> CommandBehavior {
        lock.lock()
        defer { lock.unlock() }
        issuedCount += 1
        if powerDownOnNextCommand {
            powerDownOnNextCommand = false
            running = false
            return .poweredOff
        }
        if holdOnNextCommand {
            holdOnNextCommand = false
            return .held
        }
        return .complete
    }
}

/// Console that speaks just enough of the protocol for the raced poweroff:
/// HELLO is answered with CAPS + END; a command RUN is answered with BEGIN
/// and, unless the command powered the machine down, OUT + END; a SIGNAL is
/// answered with END so the channel's own interrupt machinery completes.
private final class PoweroffRaceConsole: LinuxGuestConsoleTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let engine: PoweroffRaceEngine
    private let continuation: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private var answeredRuns = Set<String>()

    init(engine: PoweroffRaceEngine) {
        self.engine = engine
        var captured: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    func output() async -> AsyncStream<Data> { stream }

    func close() async { continuation.finish() }

    func write(_ bytes: [UInt8]) async throws {
        let text = String(decoding: bytes, as: UTF8.self)
        let responses: [Data] = lock.withLock { () -> [Data] in
            if let token = Self.token(in: text, name: "HELLO") {
                return Self.caps(token) + Self.end(token, exit: 0)
            }
            if let token = Self.token(in: text, name: "SIGNAL") {
                // The interrupted command is reaped: END it so the channel's
                // bounded interrupt machinery completes (no poison).
                return Self.end(token, exit: 130)
            }
            if let token = Self.commandToken(in: text), !answeredRuns.contains(token) {
                answeredRuns.insert(token)
                switch engine.commandIssued() {
                case .poweredOff, .held:
                    // BEGIN then silence: either the machine exited, or it
                    // remains live with a submitted command still in flight.
                    return Self.begin(token)
                case .complete:
                    return Self.begin(token) + Self.out(token, "ok") + Self.end(token, exit: 0)
                }
            }
            return []
        }
        for response in responses { continuation.yield(response) }
    }

    private static func commandToken(in text: String) -> String? {
        if let token = token(in: text, name: "RUN") { return token }
        // Small production commands use the inline EXEC fast path, without
        // a later RUN. A chunked EXEC header must wait for its RUN instead.
        guard let range = text.range(of: "\u{1e}FLOE-EXEC ") else { return nil }
        let fields = text[range.upperBound...].split { character in
            character == " " || character == "\n" || character == "\r" || character == "\u{1e}"
        }
        guard fields.count == 2, Data(base64Encoded: String(fields[1])) != nil else { return nil }
        return String(fields[0])
    }

    private static func token(in text: String, name: String) -> String? {
        guard let range = text.range(of: "\u{1e}FLOE-\(name) ") else { return nil }
        let token = text[range.upperBound...].prefix { character in
            character != " " && character != "\u{1e}" && character != "\n" && character != "\r"
        }
        return token.isEmpty ? nil : String(token)
    }

    private static func caps(_ token: String) -> [Data] {
        [Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4\u{1e}".utf8)]
    }

    private static func begin(_ token: String) -> [Data] {
        [Data("\u{1e}FLOE-BEGIN \(token)\u{1e}".utf8)]
    }

    private static func out(_ token: String, _ text: String) -> [Data] {
        [Data("\u{1e}FLOE-OUT \(token)\u{1e}\(text)".utf8)]
    }

    private static func end(_ token: String, exit: Int32) -> [Data] {
        [Data("\u{1e}FLOE-END \(token) \(exit)\u{1e}".utf8)]
    }
}

private struct PoweroffRaceSessionFactory: LinuxGuestSessionCreating {
    let engine: PoweroffRaceEngine

    func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle {
        let console = PoweroffRaceConsole(engine: engine)
        return LinuxGuestSessionHandle(
            transport: console,
            start: { [engine] in engine.start() },
            stop: { [engine] in engine.stop() },
            close: { [engine] in engine.stop() },
            isRunning: { [engine] in engine.isRunning },
            addForward: { _ in },
            removeForward: { _ in }
        )
    }
}

final class LinuxSoftRestartRegistryRaceTests: XCTestCase {
    private let environmentID = "env-poweroff-race"

    private func makeRegistry(
        engine: PoweroffRaceEngine, environmentID: String
    ) -> TinyEMULinuxGuestRegistry {
        let image = makeQualifiedImage()
        return TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: [
                environmentID: LinuxGuestEnvironmentDescriptor(
                    id: environmentID, ownerID: "owner", imageID: image.id
                )
            ]),
            images: FakeImageResolver(images: [image.id: image]),
            limits: .standard,
            factory: PoweroffRaceSessionFactory(engine: engine)
        )
    }

    private func makeQualifiedImage() -> LinuxGuestImage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-poweroff-race-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bios = directory.appendingPathComponent("bbl64.bin")
        let contents = Data("bios".utf8)
        FileManager.default.createFile(atPath: bios.path, contents: contents)
        return LinuxGuestImage(
            id: "poweroff-race-image",
            biosPath: bios.path,
            qualified: true,
            qualificationEvidence: "poweroff race \(UUID().uuidString)",
            qualificationRun: "poweroff-race-1",
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: bios.path,
                    sha512: FloeDigest.sha512Hex(contents), bytes: Int64(contents.count)
                )
            ]
        )
    }

    /// The poweroff command begins and the machine exits WITHOUT ever
    /// answering END. The raced stage observes the exit and returns
    /// `.poweredOff` — which is only possible when the proven-exited
    /// channel is closed BEFORE the blocked command reader is joined. Under
    /// a structured wait cycle this call would hang past every bound.
    func testPoweroffRaceClosesOnlyTheProvenExitedChannelAndReturns() async throws {
        let environmentID = "env-race-powered-off"
        let engine = PoweroffRaceEngine()
        let registry = makeRegistry(engine: engine, environmentID: environmentID)
        let service = TinyEMULinuxCommandService(registry: registry)
        _ = try await registry.start(environmentID: environmentID, taskID: nil)
        engine.armPowerDown()
        let token = try await registry.beginLifecycleTransaction(environmentID: environmentID)
        func cleanup() async {
            await registry.endLifecycleTransaction(environmentID: environmentID, token: token)
            await registry.stop(environmentID: environmentID)
        }
        do {
            let outcome = try await service.requestOrderlyPoweroffForLifecycleTransaction(
                LinuxGuestLifecycleTransaction(environmentID: environmentID, token: token),
                poweroffPath: "/sbin/poweroff", deadline: 5, cancellation: nil)
            if case .poweredOff = outcome {} else {
                XCTFail("expected .poweredOff, got \(outcome)")
            }
            XCTAssertEqual(engine.commandsIssued, 1, "the real channel must dispatch exactly one command")
            XCTAssertFalse(engine.isRunning)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    /// The machine stays alive and the poweroff command never answers: the
    /// outcome is `.unconfirmed` AND the live channel remains fully usable
    /// for a normal command — the race must never close or reset a live,
    /// unconfirmed machine merely to finish itself.
    func testUnconfirmedPoweroffLeavesTheLiveChannelUsable() async throws {
        let environmentID = "env-race-unconfirmed"
        let engine = PoweroffRaceEngine()
        let registry = makeRegistry(engine: engine, environmentID: environmentID)
        let service = TinyEMULinuxCommandService(registry: registry)
        _ = try await registry.start(environmentID: environmentID, taskID: nil)
        // This case needs a live SUBMITTED command, not an immediate END 0.
        engine.armHold()
        let token = try await registry.beginLifecycleTransaction(environmentID: environmentID)
        let transaction = LinuxGuestLifecycleTransaction(environmentID: environmentID, token: token)
        func cleanup() async {
            await registry.endLifecycleTransaction(environmentID: environmentID, token: token)
            await registry.stop(environmentID: environmentID)
        }
        do {
            let outcome = try await service.requestOrderlyPoweroffForLifecycleTransaction(
                transaction, poweroffPath: "/sbin/poweroff", deadline: 0.3, cancellation: nil)
            if case .unconfirmed = outcome {} else {
                XCTFail("expected .unconfirmed, got \(outcome)")
            }
            XCTAssertEqual(engine.commandsIssued, 1, "unknown requires an actually dispatched command")
            XCTAssertTrue(engine.isRunning, "an unconfirmed outcome must never stop the live machine")
            // Still the same live real channel; no reset, close or poison.
            let result = try await service.runForLifecycleTransaction(transaction,
                argv: ["/bin/echo", "still-alive"], timeout: 5, cancellation: nil)
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.stdout, "ok")
            XCTAssertEqual(engine.commandsIssued, 2)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

}
