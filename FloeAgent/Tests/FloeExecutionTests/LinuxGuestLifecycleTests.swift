// FloeExecutionTests — Linux lifecycle manager + real tool dispatch.
//
// Covers the safe ownership/restart/error contract and default-vs-explicit
// core behavior against an in-memory controller, plus cross-concurrency with
// a shell-style direct start on the REAL registry, plus JSON → handler
// dispatch through the real tools.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - in-memory controller

private actor FakeLifecycleController: LinuxGuestControlling {
    struct Guest {
        var vcpus: Int
        var ramMB: Int
        var generation: UInt64
        var services: Int
        var terminals: Int
    }

    private var active: [String: Guest] = [:]
    private var ownedImages: [String: String] = [:]
    private var nextGeneration: UInt64 = 0
    private var savedConfiguration: LinuxGuestLifecycleConfig?
    func setSavedConfiguration(_ value: LinuxGuestLifecycleConfig) { savedConfiguration = value }
    func preferredGuestConfiguration(environmentID: String) async -> LinuxGuestLifecycleConfig? { savedConfiguration }
    /// When true a start fails with imageNotQualified (used to test the
    /// prepare-and-retry path).
    var failNextStartUnqualified = false
    var prepareCount = 0
    /// Scripted ineffective stop: the guest survives every stop call.
    var stopIsIneffective = false
    /// When set, a start really boots this RAM instead of the requested shape
    /// (a scripted external preemption / silent downgrade).
    var forcedStartMemoryMB: Int?
    /// Scripted verified-repair outcome (nil = refuse like a substrate-less
    /// backend).
    var scriptedRepair: RuntimeV2Store.RepairResolutionReport?
    private(set) var repairCalls = 0

    func restoreRepair(environmentID: String) async throws -> RuntimeV2Store.RepairResolutionReport {
        repairCalls += 1
        guard let scriptedRepair else {
            throw LinuxGuestError.invalidConfiguration(
                "this Linux guest backend does not support environment disk repair"
            )
        }
        return scriptedRepair
    }

    func own(_ environmentID: String, imageID: String = "floe-image") {
        ownedImages[environmentID] = imageID
    }

    func startGuest(environmentID: String, taskID: String?) async throws -> Bool {
        try start(environmentID, vcpus: 1, ramMB: 256)
    }

    func startGuest(
        environmentID: String,
        taskID: String?,
        shape: GuestResourceRequest?
    ) async throws -> Bool {
        guard let shape else {
            return try await startGuest(environmentID: environmentID, taskID: taskID)
        }
        return try start(
            environmentID,
            vcpus: shape.vcpus.count,
            ramMB: shape.memory.mb
        )
    }

    private func start(_ environmentID: String, vcpus: Int, ramMB: Int) throws -> Bool {
        guard ownedImages[environmentID] != nil else { return false }
        if failNextStartUnqualified {
            failNextStartUnqualified = false
            throw LinuxGuestError.imageNotQualified(
                environmentID: environmentID, reason: "synthetic missing image"
            )
        }
        nextGeneration += 1
        active[environmentID] = Guest(
            vcpus: vcpus,
            ramMB: forcedStartMemoryMB ?? ramMB,
            generation: nextGeneration,
            services: 0,
            terminals: 0
        )
        return true
    }

    func stopGuest(environmentID: String) async {
        // A scripted ineffective stop (the engine never confirmed the guest
        // left) keeps the guest present so the manager must quarantine.
        guard !stopIsIneffective else { return }
        active.removeValue(forKey: environmentID)
    }

    func resetGuest(environmentID: String) async {
        active.removeValue(forKey: environmentID)
    }

    func deleteGuest(environmentID: String) async {
        active.removeValue(forKey: environmentID)
        ownedImages.removeValue(forKey: environmentID)
    }

    func guestIsRunning(environmentID: String) async -> Bool {
        active[environmentID] != nil
    }

    func guestStatus(environmentID: String) async -> LinuxGuestStatus {
        if let guest = active[environmentID] {
            return LinuxGuestStatus(
                environmentID: environmentID, running: true,
                imageID: ownedImages[environmentID], ramMB: guest.ramMB
            )
        }
        return LinuxGuestStatus(
            environmentID: environmentID, running: false,
            imageID: ownedImages[environmentID], ramMB: nil
        )
    }

    func stopGuests(taskID: String) async {}

    func environmentsWithGuestActivity() async -> [String] { Array(active.keys) }

    func guestActivityDetails() async -> [LinuxGuestActivityDetail] {
        active.map { entry in
            LinuxGuestActivityDetail(
                environmentID: entry.key,
                ownerRunID: "run-1",
                running: true,
                activeTerminalCount: entry.value.terminals,
                activeServiceCount: entry.value.services
            )
        }
    }

    func runtimeStates() async -> [LinuxGuestRuntimeState] {
        active.map { entry in
            LinuxGuestRuntimeState(
                environmentID: entry.key,
                identity: LinuxGuestRuntimeIdentity(
                    runtimeID: "rt-\(entry.key)",
                    launchGeneration: entry.value.generation
                ),
                running: true,
                ramMB: entry.value.ramMB,
                vcpus: entry.value.vcpus,
                startedAt: Date(timeIntervalSince1970: 1)
            )
        }
    }

    func releaseTransientGuest(
        environmentID: String, expectedOwnerRunID: String
    ) async -> LinuxGuestTransientReleaseOutcome {
        .refused(reason: "not used")
    }

    func forwardService(environmentID: String, forward: LinuxGuestServiceForward) async throws {}
    func removeServiceForward(environmentID: String, forward: LinuxGuestServiceForward) async {}

    func openSession(
        environmentID: String, sessionID: String, argv: [String], workingDirectory: String?,
        columns: Int, rows: Int
    ) async throws {
        guard var guest = active[environmentID] else { return }
        guest.terminals += 1
        active[environmentID] = guest
    }

    func readSession(
        sessionID: String, maxBytes: Int, waitMs: Int
    ) async -> (output: Data, info: LinuxGuestSessionInfo)? { nil }
    func writeSession(sessionID: String, text: String) async throws {}
    func signalSession(sessionID: String, signal: LinuxGuestSessionSignal) async {}
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
    func closeSession(sessionID: String) async {}
    func sessionInfo(sessionID: String) async -> LinuxGuestSessionInfo? { nil }

    // test controls
    func setScriptedRepair(_ report: RuntimeV2Store.RepairResolutionReport?) {
        scriptedRepair = report
    }
    func setServices(_ environmentID: String, _ count: Int) {
        active[environmentID]?.services = count
    }
    func setTerminals(_ environmentID: String, _ count: Int) {
        active[environmentID]?.terminals = count
    }
    func setUnqualifiedStartFailure() { failNextStartUnqualified = true }
    func makeStopsIneffective() { stopIsIneffective = true }
    func forceStartMemory(_ mb: Int) { forcedStartMemoryMB = mb }
    func recordPrepare() { prepareCount += 1 }
    var preparations: Int { prepareCount }
    func activeGeneration(_ environmentID: String) -> UInt64? {
        active[environmentID]?.generation
    }
    func isActive(_ environmentID: String) -> Bool { active[environmentID] != nil }
}

// MARK: - manager behavior tests

final class LinuxGuestLifecycleTests: XCTestCase {
    private let environmentID = "env-life"

    private func makeManager(
        controller: FakeLifecycleController,
        softRestart: LinuxGuestSoftRestartPerformer? = nil,
        releasePolicy: GuestReleaseShapePolicy = .production
    ) -> LinuxGuestLifecycleManager {
        LinuxGuestLifecycleManager(
            controller: controller,
            releasePolicy: releasePolicy,
            softRestartPerformer: softRestart,
            prepareImage: { [weak controller] _, _ in
                await controller?.recordPrepare()
            },
            stopVerificationTimeout: 0.2
        )
    }

    /// Parameterless cold start: default single core, 512 MiB requested tier;
    /// the receipt reports requested/actual honestly and reused=false.
    func testDefaultColdStartIsSingleCore() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)

        let receipt = try await manager.start(
            environmentID: environmentID, config: .init(), ownerTaskID: "run-1"
        )
        XCTAssertEqual(receipt.phase, .running)
        XCTAssertEqual(receipt.actualVCPUs, 1)
        XCTAssertEqual(receipt.actualMemoryMB, 256)
        XCTAssertFalse(receipt.reused)
        XCTAssertNil(receipt.requestedVCPUs)
        XCTAssertEqual(receipt.launchGeneration, 1)
        XCTAssertTrue(receipt.capability.contains("three guest cores"))
        XCTAssertTrue(receipt.capability.contains("performance depends on workload"))
    }

    /// Explicit single-core start is carried to the runtime descriptor.
    func testColdStartRestoresSavedShapeAndExplicitDimensionWins() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        await controller.setSavedConfiguration(.init(vcpus: 3, memoryMB: 768))
        let manager = makeManager(controller: controller)
        let stopped = try await manager.status(environmentID: environmentID)
        XCTAssertEqual(stopped.actualVCPUs, 0)
        XCTAssertTrue(stopped.detail.contains("saved startup configuration: 3 vCPU, 768 MiB"))
        let resumed = try await manager.start(environmentID: environmentID)
        XCTAssertEqual(resumed.actualVCPUs, 3)
        XCTAssertEqual(resumed.actualMemoryMB, 768)
        _ = try await manager.stop(environmentID: environmentID)
        let overridden = try await manager.start(environmentID: environmentID, config: .init(vcpus: 2))
        XCTAssertEqual(overridden.actualVCPUs, 2)
        XCTAssertEqual(overridden.actualMemoryMB, 768)
    }

    func testSavedShapeRoundTripAndCorruptRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = LinuxGuestLifecycleConfig(vcpus: 3, memoryMB: 512)
        try configured.save(to: root)
        XCTAssertEqual(LinuxGuestLifecycleConfig.load(from: root), configured)
        try LinuxGuestLifecycleConfig(vcpus: 4, memoryMB: 512).save(to: root)
        XCTAssertNil(LinuxGuestLifecycleConfig.load(from: root))
    }

    func testExplicitSingleCoreCarriedToRuntime() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)

        let receipt = try await manager.start(
            environmentID: environmentID,
            config: .init(vcpus: 1, memoryMB: 512),
            ownerTaskID: nil
        )
        XCTAssertEqual(receipt.requestedVCPUs, 1)
        XCTAssertEqual(receipt.requestedMemoryMB, 512)
        XCTAssertEqual(receipt.actualVCPUs, 1)
    }

    /// Explicit dual start is carried to the runtime under the production
    /// policy (the second hart is still image-gated inside the registry/pool);
    /// the receipt reports the requested and actual counts honestly.
    func testExplicitDualStartCarriedToRuntimeUnderProduction() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)

        let receipt = try await manager.start(
            environmentID: environmentID,
            config: .init(vcpus: 2, memoryMB: 512),
            ownerTaskID: nil
        )
        XCTAssertEqual(receipt.phase, .running)
        XCTAssertEqual(receipt.requestedVCPUs, 2)
        XCTAssertEqual(receipt.actualVCPUs, 2)
    }

    /// A narrower release ceiling still refuses an explicit dual start with
    /// the typed capability error; nothing boots and no single-core guest is
    /// substituted.
    func testExplicitDualRefusedUnderANarrowerReleaseCeilingNoBoot() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(
            controller: controller,
            releasePolicy: GuestReleaseShapePolicy.internalSyntheticTesting(
                maximumSupportedVCPUs: 1, provenance: "LinuxGuestLifecycleTests narrow ceiling"
            )
        )

        do {
            _ = try await manager.start(
                environmentID: environmentID,
                config: .init(vcpus: 2, memoryMB: 512),
                ownerTaskID: nil
            )
            XCTFail("dual start must be refused by the narrower ceiling")
        } catch let error as LinuxGuestLifecycleError {
            guard case .capabilityUnsupported(let id, let requested, let reason) = error else {
                return XCTFail("expected capabilityUnsupported, got \(error)")
            }
            XCTAssertEqual(id, environmentID)
            XCTAssertEqual(requested, 2)
            XCTAssertTrue(reason.contains("qualified ladder"))
        }
        let isActive = await controller.isActive(environmentID)
        XCTAssertFalse(isActive)
    }

    /// A later start reuses an already-running guest and never resets it.
    func testRunningGuestReusedUntouched() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)

        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)
        let generation = await controller.activeGeneration(environmentID)

        let again = try await manager.start(
            environmentID: environmentID, config: .init(), ownerTaskID: nil
        )
        XCTAssertTrue(again.reused)
        XCTAssertEqual(again.launchGeneration.flatMap(UInt64.init), generation)
        let generationAfterStart = await controller.activeGeneration(environmentID)
        XCTAssertEqual(generationAfterStart, generation)
    }

    /// Explicit dual against a running single guest is refused, not reset.
    func testExplicitDualOnRunningSingleRefused() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)

        do {
            _ = try await manager.start(
                environmentID: environmentID,
                config: .init(vcpus: 2),
                ownerTaskID: nil
            )
            XCTFail("must refuse conflicting running shape")
        } catch let error as LinuxGuestLifecycleError {
            guard case .runningShapeMismatch(let id, let requested, let running) = error else {
                return XCTFail("expected runningShapeMismatch, got \(error)")
            }
            XCTAssertEqual(id, environmentID)
            XCTAssertEqual(requested, 2)
            XCTAssertEqual(running, 1)
        }
        let generationAfterRefusal = await controller.activeGeneration(environmentID)
        XCTAssertEqual(generationAfterRefusal, 1, "guest was reset")
    }

    /// Explicit memory tier that contradicts the running guest's RAM is also
    /// refused (not just vCPU).
    func testExplicitMemoryMismatchOnRunningGuestRefused() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)

        do {
            _ = try await manager.start(
                environmentID: environmentID,
                config: .init(memoryMB: 1024),
                ownerTaskID: nil
            )
            XCTFail("must refuse memory mismatch")
        } catch let error as LinuxGuestLifecycleError {
            guard case .runningMemoryMismatch(let id, let requested, let running) = error else {
                return XCTFail("expected runningMemoryMismatch, got \(error)")
            }
            XCTAssertEqual(id, environmentID)
            XCTAssertEqual(requested, 1024)
            XCTAssertEqual(running, 256)
        }
    }

    /// Matching explicit shape on the running guest reuses it.
    func testMatchingExplicitShapeReusesRunningGuest() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)

        let receipt = try await manager.start(
            environmentID: environmentID,
            config: .init(vcpus: 1, memoryMB: 256),
            ownerTaskID: nil
        )
        XCTAssertTrue(receipt.reused)
    }

    /// Stop terminates the actual guest; an open interactive terminal blocks.
    func testStopRefusedWithActiveTerminal() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)
        await controller.setTerminals(environmentID, 1)

        do {
            _ = try await manager.stop(environmentID: environmentID)
            XCTFail("stop must refuse with a terminal open")
        } catch let error as LinuxGuestLifecycleError {
            guard case .activeInteractiveTerminal(let id, let count) = error else {
                return XCTFail("expected activeInteractiveTerminal, got \(error)")
            }
            XCTAssertEqual(id, environmentID)
            XCTAssertEqual(count, 1)
        }
        let isActive = await controller.isActive(environmentID)
        XCTAssertTrue(isActive)
    }

    /// Stop without a terminal stops the guest and reports terminated services.
    func testStopSucceedsAndCountsServices() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)
        await controller.setServices(environmentID, 2)

        let receipt = try await manager.stop(environmentID: environmentID)
        XCTAssertEqual(receipt.phase, .stopped)
        XCTAssertEqual(receipt.servicesStopped, 2)
        XCTAssertEqual(receipt.actualVCPUs, 0)
        let isActive = await controller.isActive(environmentID)
        XCTAssertFalse(isActive)
    }

    /// Soft restart without a performer is an explicit unsupported error.
    func testSoftRestartUnsupportedByDefault() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)

        do {
            _ = try await manager.softRestart(environmentID: environmentID, config: nil)
            XCTFail("soft restart must be unsupported")
        } catch let error as LinuxGuestLifecycleError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("expected capabilityUnsupported, got \(error)")
            }
        }
    }

    /// Hard restart stops and verifies the old instance, rotates the
    /// generation and boots a fresh instance.
    func testHardRestartRotatesInstance() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)
        let oldGeneration = await controller.activeGeneration(environmentID)

        let receipt = try await manager.hardRestart(
            environmentID: environmentID, config: .init()
        )
        XCTAssertEqual(receipt.phase, .running)
        XCTAssertFalse(receipt.reused)
        let newGeneration = await controller.activeGeneration(environmentID)
        XCTAssertNotEqual(oldGeneration, newGeneration)
        XCTAssertEqual(receipt.launchGeneration.flatMap(UInt64.init), newGeneration)
    }

    /// Hard restart requested dual under production restarts the guest at two
    /// harts (the registry/pool image gate still decides delivery).
    func testHardRestartDualUnderProductionAppliesTwoHarts() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)

        let receipt = try await manager.hardRestart(
            environmentID: environmentID, config: .init(vcpus: 2)
        )
        XCTAssertEqual(receipt.phase, .running)
        XCTAssertEqual(receipt.requestedVCPUs, 2)
        XCTAssertEqual(receipt.actualVCPUs, 2)
        let isActive = await controller.isActive(environmentID)
        XCTAssertTrue(isActive)
        let generationAfterRestart = await controller.activeGeneration(environmentID)
        XCTAssertEqual(generationAfterRestart, 2)
    }

    /// Hard restart requested dual under a narrower release ceiling refuses
    /// BEFORE stopping the running guest.
    func testHardRestartDualRefusedBeforeDisruptionUnderANarrowerCeiling() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(
            controller: controller,
            releasePolicy: GuestReleaseShapePolicy.internalSyntheticTesting(
                maximumSupportedVCPUs: 1, provenance: "LinuxGuestLifecycleTests hard restart narrow ceiling"
            )
        )
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)

        do {
            _ = try await manager.hardRestart(
                environmentID: environmentID, config: .init(vcpus: 2)
            )
            XCTFail("dual hard restart must refuse under the narrower ceiling")
        } catch let error as LinuxGuestLifecycleError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("expected capabilityUnsupported, got \(error)")
            }
        }
        // The original guest keeps running; no disruption happened.
        let isActive = await controller.isActive(environmentID)
        XCTAssertTrue(isActive)
        let generationAfterRestart = await controller.activeGeneration(environmentID)
        XCTAssertEqual(generationAfterRestart, 1)
    }

    /// Cancellation before the operation yields a cancelled result.
    func testCancelledStartPropagatesCancellation() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        let token = CancellationToken()
        token.cancel()

        do {
            _ = try await manager.start(
                environmentID: environmentID, config: .init(),
                ownerTaskID: nil, cancellation: token
            )
            XCTFail("cancelled start must throw")
        } catch FloeError.cancelled {
            // expected
        }
        let isActive = await controller.isActive(environmentID)
        XCTAssertFalse(isActive)
    }

    /// A start whose only failure is an unqualified image prepares the image
    /// (the same preparation the shell path uses) and retries once.
    func testStartPreparesImageThenRetries() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        await controller.setUnqualifiedStartFailure()
        let manager = makeManager(controller: controller)

        let receipt = try await manager.start(
            environmentID: environmentID, config: .init(), ownerTaskID: nil
        )
        XCTAssertEqual(receipt.actualVCPUs, 1)
        let prepareCount = await controller.preparations
        XCTAssertEqual(prepareCount, 1)
    }

    /// Hard restart with no explicit config PRESERVES the running guest's
    /// configured shape instead of silently resetting it to the default.
    func testHardRestartPreservesRunningConfiguration() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(
            environmentID: environmentID,
            config: .init(vcpus: 1, memoryMB: 1024),
            ownerTaskID: nil
        )

        let receipt = try await manager.hardRestart(environmentID: environmentID, config: nil)
        XCTAssertEqual(receipt.requestedVCPUs, 1, "the configured core count was not preserved")
        XCTAssertEqual(receipt.requestedMemoryMB, 1024, "the configured RAM was reset to the default")
        XCTAssertEqual(receipt.actualMemoryMB, 1024)
        XCTAssertFalse(receipt.reused)
    }

    /// A partially specified restart config preserves the other dimension.
    func testHardRestartPartialConfigPreservesOtherDimension() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(
            environmentID: environmentID,
            config: .init(vcpus: 1, memoryMB: 1024),
            ownerTaskID: nil
        )

        let receipt = try await manager.hardRestart(
            environmentID: environmentID, config: .init(vcpus: 1)
        )
        XCTAssertEqual(receipt.requestedMemoryMB, 1024, "unspecified RAM must be preserved")
        XCTAssertEqual(receipt.actualMemoryMB, 1024)
    }

    /// A memory size between ladder steps is rejected server-side, never
    /// silently rounded (600 must not become 768).
    func testInvalidMemoryRejectedWithoutRounding() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)

        do {
            _ = try await manager.start(
                environmentID: environmentID,
                config: .init(memoryMB: 600),
                ownerTaskID: nil
            )
            XCTFail("600 MiB must be rejected")
        } catch let error as LinuxGuestLifecycleError {
            guard case .invalidConfiguration(let id, let detail) = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
            XCTAssertEqual(id, environmentID)
            XCTAssertTrue(detail.contains("never rounded"), detail)
        }
        let isActive = await controller.isActive(environmentID)
        XCTAssertFalse(isActive)
    }

    /// A malformed core count is rejected server-side too.
    func testInvalidVCPUsRejectedServerSide() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)

        do {
            _ = try await manager.start(
                environmentID: environmentID,
                config: .init(vcpus: 4),
                ownerTaskID: nil
            )
            XCTFail("vcpus=4 must be rejected")
        } catch let error as LinuxGuestLifecycleError {
            guard case .invalidConfiguration = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
        }
        let isActive = await controller.isActive(environmentID)
        XCTAssertFalse(isActive)
    }

    /// A stop the engine never confirms leaves the guest treated as
    /// quarantined: no false "stopped" receipt, no disk reuse claim.
    func testStopThatNeverLeavesIsQuarantined() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)
        await controller.makeStopsIneffective()

        do {
            _ = try await manager.stop(environmentID: environmentID)
            XCTFail("an unconfirmed stop must not report success")
        } catch let error as LinuxGuestLifecycleError {
            guard case .stopFailedQuarantined(let id, let detail) = error else {
                return XCTFail("expected stopFailedQuarantined, got \(error)")
            }
            XCTAssertEqual(id, environmentID)
            XCTAssertTrue(detail.contains("not reused"), detail)
        }
        let stillRunning = await controller.isActive(environmentID)
        XCTAssertTrue(stillRunning, "the guest really is still running")
    }

    /// Status reports a running vs stopped guest truthfully.
    func testStatusReportsRunningAndStopped() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)

        let stopped = try await manager.status(environmentID: environmentID)
        XCTAssertEqual(stopped.phase, .stopped)

        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)
        let running = try await manager.status(environmentID: environmentID)
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.actualVCPUs, 1)
    }

    /// A hard restart whose replacement really booted a different RAM than
    /// requested must fail honestly instead of reporting requested/actual
    /// values that disagree (scripted external preemption / silent downgrade).
    func testHardRestartRefusesToReportUngrantedShape() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)

        await controller.forceStartMemory(1024)
        do {
            _ = try await manager.hardRestart(
                environmentID: environmentID, config: .init(memoryMB: 512)
            )
            XCTFail("a restart that booted another shape must not report success")
        } catch let error as LinuxGuestLifecycleError {
            guard case .capabilityUnsupported(let id, _, let reason) = error else {
                return XCTFail("expected capabilityUnsupported, got \(error)")
            }
            XCTAssertEqual(id, environmentID)
            XCTAssertTrue(reason.contains("1024"), reason)
        }
        let isActive = await controller.isActive(environmentID)
        XCTAssertTrue(isActive, "the guest really is running at the other shape")
    }

    /// A cold start whose runtime granted another shape is refused the same
    /// way; the receipt never smooths the mismatch into success.
    func testColdStartRefusesUngrantedShape() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        await controller.forceStartMemory(1024)
        let manager = makeManager(controller: controller)

        do {
            _ = try await manager.start(
                environmentID: environmentID, config: .init(memoryMB: 512), ownerTaskID: nil
            )
            XCTFail("a start that booted another shape must not report success")
        } catch let error as LinuxGuestLifecycleError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("expected capabilityUnsupported, got \(error)")
            }
        }
    }

    /// A hard restart cancelled before it begins refuses without disturbing
    /// the running guest (the existing token check runs before any
    /// transaction or disruption).
    func testCancelledHardRestartPropagatesCancellation() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = makeManager(controller: controller)
        _ = try await manager.start(environmentID: environmentID, config: .init(), ownerTaskID: nil)
        let token = CancellationToken()
        token.cancel()

        do {
            _ = try await manager.hardRestart(
                environmentID: environmentID, config: .init(), cancellation: token
            )
            XCTFail("a cancelled hard restart must throw")
        } catch FloeError.cancelled {
            // expected
        }
        let isActive = await controller.isActive(environmentID)
        XCTAssertTrue(isActive, "a cancelled restart must not disturb the running guest")
        let generation = await controller.activeGeneration(environmentID)
        XCTAssertEqual(generation, 1, "the cancelled restart replaced the instance")
    }
}

// MARK: - real tool dispatch from JSON

final class LinuxLifecycleToolDispatchTests: XCTestCase {
    private let environmentID = "env-tool"

    private func context() -> ToolContext {
        ToolContext(
            runID: UUID(),
            cancellation: CancellationToken(),
            environmentID: environmentID
        )
    }

    func testStartToolDispatchesThroughManager() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = LinuxGuestLifecycleManager(controller: controller)
        let tool = AnyAgentTool(StartLinuxGuestLifecycleTool(lifecycle: manager))

        let output = try await tool.run(Data("{}".utf8), context())
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("actualVCPUs=1"))
        XCTAssertTrue(output.summary.contains("phase=running"))
    }

    func testDualStartToolUnderANarrowerCeilingReturnsUnsupportedReceipt() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = LinuxGuestLifecycleManager(
            controller: controller,
            releasePolicy: GuestReleaseShapePolicy.internalSyntheticTesting(
                maximumSupportedVCPUs: 1, provenance: "LinuxLifecycleToolDispatchTests narrow ceiling"
            )
        )
        let tool = AnyAgentTool(StartLinuxGuestLifecycleTool(lifecycle: manager))

        let output = try await tool.run(Data(#"{"vcpus":2}"#.utf8), context())
        XCTAssertEqual(output.exitStatus, 125)
        XCTAssertTrue(output.summary.contains("status=unsupported"))
        let isActive = await controller.isActive(environmentID)
        XCTAssertFalse(isActive)
    }

    /// Normal model access: the same JSON under the production policy reaches
    /// the runtime and reports the actual two-hart shape — no feature flag or
    /// manual unlock is required (the registry/pool image gate still decides
    /// whether the second hart is delivered to a real guest).
    func testDualStartToolDispatchesTwoHartsUnderProduction() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = LinuxGuestLifecycleManager(controller: controller)
        let tool = AnyAgentTool(StartLinuxGuestLifecycleTool(lifecycle: manager))

        let output = try await tool.run(Data(#"{"vcpus":2,"memoryMB":512}"#.utf8), context())
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("requestedVCPUs=2"))
        XCTAssertTrue(output.summary.contains("actualVCPUs=2"))
        let isActive = await controller.isActive(environmentID)
        XCTAssertTrue(isActive)
    }

    func testStatusAndStopToolRoundTrip() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = LinuxGuestLifecycleManager(controller: controller)

        let start = AnyAgentTool(StartLinuxGuestLifecycleTool(lifecycle: manager))
        _ = try await start.run(Data("{}".utf8), context())

        let status = AnyAgentTool(LinuxGuestStatusLifecycleTool(lifecycle: manager))
        let statusOutput = try await status.run(Data("{}".utf8), context())
        XCTAssertEqual(statusOutput.exitStatus, 0)
        XCTAssertTrue(statusOutput.summary.contains("phase=running"))

        let stop = AnyAgentTool(StopLinuxGuestLifecycleTool(lifecycle: manager))
        let stopOutput = try await stop.run(Data("{}".utf8), context())
        XCTAssertEqual(stopOutput.exitStatus, 0)
        XCTAssertTrue(stopOutput.summary.contains("phase=stopped"))
    }

    func testHardRestartToolRotatesGeneration() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = LinuxGuestLifecycleManager(controller: controller)
        let start = AnyAgentTool(StartLinuxGuestLifecycleTool(lifecycle: manager))
        _ = try await start.run(Data("{}".utf8), context())

        let restart = AnyAgentTool(HardRestartLinuxGuestLifecycleTool(lifecycle: manager))
        let output = try await restart.run(Data("{}".utf8), context())
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("phase=running"))
    }

    func testNoEnvironmentInScopeReturnsNotOwned() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = LinuxGuestLifecycleManager(controller: controller)
        let tool = StartLinuxGuestLifecycleTool(lifecycle: manager)

        let noEnvContext = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let output = try await tool.execute(.init(), context: noEnvContext)
        XCTAssertEqual(output.exitStatus, 127)
    }

    /// An out-of-ladder memory request is refused server-side and surfaces as
    /// an invalid-argument receipt, never a rounded boot.
    func testInvalidMemoryToolReceipt() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        let manager = LinuxGuestLifecycleManager(controller: controller)
        let tool = AnyAgentTool(StartLinuxGuestLifecycleTool(lifecycle: manager))

        let output = try await tool.run(Data(#"{"memoryMB":600}"#.utf8), context())
        XCTAssertEqual(output.exitStatus, 2)
        XCTAssertTrue(output.summary.contains("status=invalidArgument"))
        let isActive = await controller.isActive(environmentID)
        XCTAssertFalse(isActive)
    }

    // MARK: - verified disk repair

    /// The repair renders the verified restore outcome, and a substrate-less
    /// backend refuses honestly instead of pretending.
    func testRepairToolReceiptOnVerifiedRestore() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        await controller.setScriptedRepair(RuntimeV2Store.RepairResolutionReport(
            resolution: "restored",
            preservedPath: "recovery/quarantine/runtime-vm-rt-x",
            diskDigestSHA512: String(repeating: "b", count: 128),
            restoredGeneration: 4
        ))
        let manager = LinuxGuestLifecycleManager(controller: controller)
        let tool = RepairLinuxGuestLifecycleTool(lifecycle: manager)

        let output = try await tool.execute(.init(), context: context())
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("resolution=restored"))
        XCTAssertTrue(output.summary.contains("preservedPath=recovery/quarantine/runtime-vm-rt-x"))
        XCTAssertTrue(output.summary.contains("restoredGeneration=4"))
        XCTAssertTrue(output.summary.contains("diskSHA512="))
        let repairCalls = await controller.repairCalls
        XCTAssertEqual(repairCalls, 1)
    }

    /// Repair refuses while a guest instance is running: the verification
    /// must see a quiet disk.
    func testRepairRefusedWhileGuestRunning() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        await controller.setScriptedRepair(RuntimeV2Store.RepairResolutionReport(
            resolution: "restored"
        ))
        let manager = LinuxGuestLifecycleManager(controller: controller)
        _ = try await manager.start(
            environmentID: environmentID, config: .init(), ownerTaskID: "run-1"
        )

        do {
            _ = try await manager.repair(environmentID: environmentID, cancellation: nil)
            XCTFail("repair must refuse while a guest is running")
        } catch let error as LinuxGuestLifecycleError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("expected capabilityUnsupported, got \(error)")
            }
        }
        let repairCalls = await controller.repairCalls
        XCTAssertEqual(repairCalls, 0, "no restore ran against a live guest")
    }

    /// The model tool surfaces the running-guest refusal as a repairRefused
    /// nonzero receipt, never a thrown pipeline error.
    func testRepairToolRefusalReceiptWhileRunning() async throws {
        let controller = FakeLifecycleController()
        await controller.own(environmentID)
        await controller.setScriptedRepair(RuntimeV2Store.RepairResolutionReport(
            resolution: "restored"
        ))
        let manager = LinuxGuestLifecycleManager(controller: controller)
        _ = try await manager.start(
            environmentID: environmentID, config: .init(), ownerTaskID: "run-1"
        )
        let tool = AnyAgentTool(RepairLinuxGuestLifecycleTool(lifecycle: manager))

        let output = try await tool.run(Data("{}".utf8), context())
        XCTAssertEqual(output.exitStatus, 125)
        XCTAssertTrue(output.summary.contains("status=repairRefused"))
    }
}
