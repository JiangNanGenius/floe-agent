// FloeExecutionTests — RuntimeVMPool CPU/RAM/VM admission regression tests.
//
// Pins the resource-pool contract on the user-approved quotas:
//   four singles / two duals / one dual + two singles, over-admission
//   cancellation, exact return on release (and FIFO promotion), strict
//   temporary-shortage queuing (never a silent downgrade), the permanent
//   image/shape error, authorized CPU+RAM downgrades within explicit
//   floors, pressure/headroom gates (with queue wake on recovery), idle
//   reclaim, shape-change validation, the default quota table, and the
//   ACTUAL startup shape handed to TinyEMU (device feedback: the guest
//   still ran at ~182 MiB).

import Foundation
import XCTest
@testable import FloeExecution

final class RuntimeVMPoolTests: XCTestCase {
    /// Static so `Task {}` closures capture the value, never the
    /// non-Sendable XCTestCase instance (Swift 6 region isolation).
    private static let single512 = GuestResourceRequest(vcpus: .one, memory: .m512)

    private func makePool(
        quota vcpus: Int = 4,
        memory: Int = 3072,
        vms: Int = 4,
        seams: RuntimeVMPool.Seams = .unrestricted
    ) -> RuntimeVMPool {
        RuntimeVMPool(
            configuration: RuntimeVMPool.Configuration(
                quota: GuestResourceQuota(
                    totalVCPUs: vcpus, totalMemoryMiB: memory, maxVMs: vms
                )
            ),
            registry: nil,
            seams: seams
        )
    }

    // MARK: - quota combinations

    func testFourSinglesAdmitAndFifthQueues() async throws {
        let pool = makePool()
        for index in 0..<4 {
            let lease = try await pool.acquire(
                environmentID: "env-\(index)", runtimeID: "rt-\(index)",
                request: Self.single512, imageSMPCapable: false
            )
            XCTAssertEqual(lease.shape.vcpus, .one)
            XCTAssertEqual(lease.shape.memory, .m512)
            XCTAssertFalse(lease.wasDowngraded)
        }
        let status = await pool.status
        XCTAssertEqual(status.running, 4)
        XCTAssertEqual(status.usedVCPUs, 4)
        XCTAssertEqual(status.reservedMB, 2048)

        let task = Task {
            try await pool.acquire(
                environmentID: "env-5", runtimeID: "rt-5",
                request: Self.single512, imageSMPCapable: false
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        XCTAssertEqual(queued, 1)
        task.cancel()
        await assertCancellation(task)
        let queuedAfterCancel = await pool.queuedCount
        let statusAfterCancel = await pool.status
        XCTAssertEqual(queuedAfterCancel, 0)
        XCTAssertEqual(statusAfterCancel.running, 4)
    }

    func testTwoDualsAdmit() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        let dual = GuestResourceRequest(vcpus: .two, memory: .m1024)
        for index in 0..<2 {
            let lease = try await pool.acquire(
                environmentID: "dual-\(index)", runtimeID: "rt-dual-\(index)",
                request: dual, imageSMPCapable: true
            )
            XCTAssertEqual(lease.shape.vcpus, .two)
            XCTAssertEqual(lease.shape.memory, .m1024)
            XCTAssertFalse(lease.wasDowngraded)
        }
        let status = await pool.status
        XCTAssertEqual(status.usedVCPUs, 4)
        XCTAssertEqual(status.reservedMB, 2048)

        let task = Task {
            try await pool.acquire(
                environmentID: "dual-2", runtimeID: "rt-dual-2",
                request: dual, imageSMPCapable: true
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        XCTAssertEqual(queued, 1)
        task.cancel()
        await assertCancellation(task)
    }

    func testOneDualAndTwoSinglesAdmit() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        _ = try await pool.acquire(
            environmentID: "dual", runtimeID: "rt-dual",
            request: GuestResourceRequest(vcpus: .two, memory: .m1024),
            imageSMPCapable: true
        )
        for index in 0..<2 {
            let lease = try await pool.acquire(
                environmentID: "single-\(index)", runtimeID: "rt-single-\(index)",
                request: GuestResourceRequest(vcpus: .one, memory: .m512),
                imageSMPCapable: false
            )
            XCTAssertEqual(lease.shape.vcpus, .one)
        }
        let status = await pool.status
        XCTAssertEqual(status.running, 3)
        XCTAssertEqual(status.usedVCPUs, 4)

        // VM slot 3/4 exists but no vCPU is free: strict queues.
        let task = Task {
            try await pool.acquire(
                environmentID: "single-2", runtimeID: "rt-single-2",
                request: Self.single512, imageSMPCapable: false
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        XCTAssertEqual(queued, 1)
        task.cancel()
        await assertCancellation(task)
    }

    // MARK: - release + FIFO promotion

    func testReleaseReturnsResourcesAndPromotesWaiter() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        let dual = GuestResourceRequest(vcpus: .two, memory: .m1024)
        _ = try await pool.acquire(
            environmentID: "dual", runtimeID: "rt-dual",
            request: dual, imageSMPCapable: true
        )
        let queuedTask = Task {
            try await pool.acquire(
                environmentID: "dual-1", runtimeID: "rt-dual-1",
                request: dual, imageSMPCapable: true
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        XCTAssertEqual(queued, 1)

        await pool.release(runtimeID: "rt-dual")
        let promoted = try await awaitWithTimeout(queuedTask)
        XCTAssertEqual(promoted.runtimeID, "rt-dual-1")
        XCTAssertEqual(promoted.shape.vcpus, .two)
        XCTAssertEqual(promoted.shape.memory, .m1024)
        let status = await pool.status
        XCTAssertEqual(status.running, 1)
        XCTAssertEqual(status.usedVCPUs, 2)
        XCTAssertEqual(status.queued, 0)
        let promotedLease = await pool.lease(runtimeID: "rt-dual-1")
        let releasedLease = await pool.lease(runtimeID: "rt-dual")
        XCTAssertNotNil(promotedLease)
        XCTAssertNil(releasedLease)
    }

    // MARK: - temporary shortage vs permanent image mismatch

    /// Strict dual with one vCPU free: temporary shortage ⇒ queue, never
    /// silently single.
    func testStrictDualTemporaryShortageQueues() async throws {
        let pool = makePool(quota: 2, memory: 1024, vms: 2)
        _ = try await pool.acquire(
            environmentID: "busy", runtimeID: "rt-busy",
            request: GuestResourceRequest(vcpus: .one, memory: .m512),
            imageSMPCapable: false
        )
        let task = Task {
            try await pool.acquire(
                environmentID: "dual", runtimeID: "rt-dual",
                request: GuestResourceRequest(vcpus: .two, memory: .m512),
                imageSMPCapable: true,
                downgrade: .strict
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        XCTAssertEqual(queued, 1)
        task.cancel()
        await assertCancellation(task)
    }

    /// Dual request against an image without SMP evidence under strict
    /// admission: permanent mismatch ⇒ immediate actionable error.
    func testStrictDualOnUnsupportedImageErrorsNotQueues() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        do {
            _ = try await pool.acquire(
                environmentID: "dual", runtimeID: "rt-dual",
                request: GuestResourceRequest(vcpus: .two, memory: .m1024),
                imageSMPCapable: false,
                downgrade: .strict
            )
            XCTFail("expected smpUnsupportedByImage")
        } catch let error as LinuxGuestError {
            guard case .smpUnsupportedByImage(let id) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(id, "dual")
        }
        // Nothing was reserved.
        let status = await pool.status
        let queued = await pool.queuedCount
        XCTAssertEqual(status.running, 0)
        XCTAssertEqual(queued, 0)
    }

    /// Authorized caller on an unsupported image: single hart with reason.
    func testAuthorizedDualOnUnsupportedImageDowngrades() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        let lease = try await pool.acquire(
            environmentID: "dual", runtimeID: "rt-dual",
            request: GuestResourceRequest(vcpus: .two, memory: .m1024),
            imageSMPCapable: false,
            downgrade: .authorized(memoryFloor: .m256)
        )
        XCTAssertEqual(lease.shape.vcpus, .one)
        XCTAssertTrue(lease.vcpusDowngraded)
        XCTAssertEqual(lease.vcpusDowngradeReason?.contains("SMP"), true)
    }

    // MARK: - RAM: strict queues, authorized downgrades within floors

    func testStrictRAMShortageQueuesWithoutSilentReduction() async throws {
        let pool = makePool(quota: 2, memory: 1024, vms: 2)
        _ = try await pool.acquire(
            environmentID: "busy", runtimeID: "rt-busy",
            request: GuestResourceRequest(vcpus: .one, memory: .m512),
            imageSMPCapable: false
        )
        let task = Task {
            try await pool.acquire(
                environmentID: "big", runtimeID: "rt-big",
                request: GuestResourceRequest(vcpus: .one, memory: .m1024),
                imageSMPCapable: false,
                downgrade: .strict
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        XCTAssertEqual(queued, 1)
        task.cancel()
        await assertCancellation(task)
    }

    func testAuthorizedRAMShortageDowngradesToHighestFittingStep() async throws {
        let pool = makePool(quota: 2, memory: 1024, vms: 2)
        _ = try await pool.acquire(
            environmentID: "busy", runtimeID: "rt-busy",
            request: GuestResourceRequest(vcpus: .one, memory: .m512),
            imageSMPCapable: false
        )
        let lease = try await pool.acquire(
            environmentID: "big", runtimeID: "rt-big",
            request: GuestResourceRequest(vcpus: .one, memory: .m1024),
            imageSMPCapable: false,
            downgrade: .authorized(memoryFloor: .m256)
        )
        XCTAssertEqual(lease.shape.memory, .m512)
        XCTAssertTrue(lease.memoryDowngraded)
        XCTAssertEqual(lease.memoryDowngradeReason?.contains("512"), true)
    }

    /// When the highest fitting step is below the authorized floor, the
    /// request still queues — no unauthorized reduction.
    func testAuthorizedRAMBelowFloorQueues() async throws {
        let pool = makePool(quota: 2, memory: 1024, vms: 2)
        _ = try await pool.acquire(
            environmentID: "busy", runtimeID: "rt-busy",
            request: GuestResourceRequest(vcpus: .one, memory: .m512),
            imageSMPCapable: false
        )
        let task = Task {
            try await pool.acquire(
                environmentID: "big", runtimeID: "rt-big",
                request: GuestResourceRequest(vcpus: .one, memory: .m1024),
                imageSMPCapable: false,
                downgrade: .authorized(memoryFloor: .m768)
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        XCTAssertEqual(queued, 1)
        task.cancel()
        await assertCancellation(task)
    }

    // MARK: - pressure gates and wake on recovery

    func testCriticalPressureBlocksAndClearWakesQueue() async throws {
        let pool = makePool()
        _ = try await pool.acquire(
            environmentID: "env-0", runtimeID: "rt-0",
            request: Self.single512, imageSMPCapable: false
        )
        await pool.reportPressure(.critical)
        let task = Task {
            try await pool.acquire(
                environmentID: "env-1", runtimeID: "rt-1",
                request: Self.single512, imageSMPCapable: false
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        let blockedStatus = await pool.status
        XCTAssertEqual(queued, 1)
        XCTAssertEqual(blockedStatus.running, 1)
        // Recovery without a release event wakes the queue.
        await pool.reportPressure(nil)
        let lease = try await awaitWithTimeout(task)
        XCTAssertEqual(lease.runtimeID, "rt-1")
    }

    // MARK: - process headroom gate

    func testHeadroomShortageQueuesAndHeadroomAdmits() async throws {
        // 512 shape requires 512 + 64 overhead + 256 reserve = 832 MiB.
        let tightSeams = RuntimeVMPool.Seams(
            availableHeadroomBytes: { 100 * 1_048_576 },
            pressure: { .nominal }
        )
        let pool = makePool(seams: tightSeams)
        let task = Task {
            try await pool.acquire(
                environmentID: "env-0", runtimeID: "rt-0",
                request: Self.single512, imageSMPCapable: false
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        XCTAssertEqual(queued, 1)
        task.cancel()
        await assertCancellation(task)

        let roomySeams = RuntimeVMPool.Seams(
            availableHeadroomBytes: { 4 * 1024 * 1_048_576 },
            pressure: { .nominal }
        )
        let roomyPool = makePool(seams: roomySeams)
        let lease = try await roomyPool.acquire(
            environmentID: "env-0", runtimeID: "rt-0",
            request: Self.single512, imageSMPCapable: false
        )
        XCTAssertEqual(lease.shape.memory, .m512)
    }

    /// Live headroom recovery wakes a queued request without a release.
    func testHeadroomRecoveryWakesQueue() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var bytes: Int
            init(_ bytes: Int) { self.bytes = bytes }
            var value: Int { lock.lock(); defer { lock.unlock() }; return bytes }
            func set(_ newValue: Int) { lock.lock(); bytes = newValue; lock.unlock() }
        }
        let box = Box(100 * 1_048_576)
        let seams = RuntimeVMPool.Seams(
            availableHeadroomBytes: { box.value },
            pressure: { .nominal }
        )
        let pool = makePool(seams: seams)
        let task = Task {
            try await pool.acquire(
                environmentID: "env-0", runtimeID: "rt-0",
                request: Self.single512, imageSMPCapable: false
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        XCTAssertEqual(queued, 1)
        box.set(4 * 1024 * 1_048_576)
        await pool.refreshQueuedAdmissions()
        let lease = try await awaitWithTimeout(task)
        XCTAssertEqual(lease.shape.memory, .m512)
    }

    // MARK: - idle reclaim (does not stop active)

    func testIdleReclaimExcludesActive() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        for index in 0..<3 {
            _ = try await pool.acquire(
                environmentID: "env-\(index)", runtimeID: "rt-\(index)",
                request: GuestResourceRequest(vcpus: .one, memory: .m512),
                imageSMPCapable: false
            )
        }
        let candidates = await pool.idleReclaimCandidates(
            activeRuntimeIDs: ["rt-0", "rt-1"], targetMiB: 512
        )
        XCTAssertEqual(candidates, ["rt-2"])
        let none = await pool.idleReclaimCandidates(
            activeRuntimeIDs: ["rt-0", "rt-1", "rt-2"], targetMiB: 512
        )
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - shape change validation + confirmation

    func testValidateAndConfirmShapeChange() async throws {
        let pool = makePool(quota: 4, memory: 3072, vms: 4)
        _ = try await pool.acquire(
            environmentID: "env-0", runtimeID: "rt-0",
            request: GuestResourceRequest(vcpus: .one, memory: .m512),
            imageSMPCapable: false
        )
        do {
            try await pool.validateShapeChange(
                environmentID: "env-0",
                request: GuestResourceRequest(vcpus: .two, memory: .m1024),
                imageSMPCapable: false
            )
            XCTFail("expected a dual-hart refusal without image SMP evidence")
        } catch let error as LinuxGuestError {
            guard case .invalidConfiguration = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        try await pool.validateShapeChange(
            environmentID: "env-0",
            request: GuestResourceRequest(vcpus: .two, memory: .m1024),
            imageSMPCapable: true
        )
        await pool.confirmShape(
            runtimeID: "rt-0",
            shape: GuestResourceRequest(vcpus: .two, memory: .m1024)
        )
        let lease = await pool.lease(runtimeID: "rt-0")
        XCTAssertEqual(lease?.shape.vcpus, .two)
        XCTAssertEqual(lease?.shape.memory, .m1024)
    }

    // MARK: - actual startup configuration

    func testMachineConfiguredShapeFromGrantedDescriptor() throws {
        let image = LinuxGuestImage(id: "img", biosPath: "bbl64.bin", qualified: false)
        let descriptor = LinuxGuestEnvironmentDescriptor(
            id: "env-1", imageID: "img", ramMB: 1024, vcpus: 2
        )
        let machine = try TinyEMUGuestMachine(
            descriptor: descriptor, image: image, limits: .standard
        )
        XCTAssertEqual(machine.configuredShape.vcpus, 2)
        XCTAssertEqual(machine.configuredShape.ramMB, 1024)
        machine.setVCPUs(1)
        XCTAssertEqual(machine.configuredShape.vcpus, 1)
    }

    /// Default for a request without workload evidence: 256 MiB, one hart
    /// (advisor-driven; the historical ~182 MiB guest is not claimed to be
    /// caused or fixed by this value).
    func testMachineDefaultShapeIs256MiBOneHart() throws {
        let image = LinuxGuestImage(id: "img", biosPath: "bbl64.bin", qualified: false)
        let descriptor = LinuxGuestEnvironmentDescriptor(id: "env-1", imageID: "img")
        let machine = try TinyEMUGuestMachine(
            descriptor: descriptor, image: image, limits: .standard
        )
        XCTAssertEqual(machine.configuredShape.vcpus, 1)
        XCTAssertEqual(machine.configuredShape.ramMB, 256)
    }

    // MARK: - default quota table + CPU clamp + performance gating

    func testDefaultQuotaTableAndCPUClamp() {
        let gib = 1024 * 1024 * 1024
        func profile(_ family: HostProductFamily, _ bytesGiB: Int, _ cores: Int) -> HostResourceProfile {
            HostResourceProfile(
                family: family,
                physicalMemoryBytes: UInt64(bytesGiB * gib),
                activeProcessorCount: cores,
                hardwareIdentifier: ""
            )
        }
        // iPad rows (fixtures; policy never matches model identifiers).
        XCTAssertEqual(HostResourceProfile.memoryBucket(physicalMemoryBytes: UInt64(8 * gib)), .around8GB)
        XCTAssertEqual(
            GuestResourceQuota.defaultQuota(for: profile(.pad, 8, 10)),
            GuestResourceQuota(totalVCPUs: 4, totalMemoryMiB: 2048, maxVMs: 4)
        )
        XCTAssertEqual(
            GuestResourceQuota.defaultQuota(for: profile(.pad, 12, 10)),
            GuestResourceQuota(totalVCPUs: 4, totalMemoryMiB: 3072, maxVMs: 4)
        )
        XCTAssertEqual(
            GuestResourceQuota.defaultQuota(for: profile(.pad, 16, 10)),
            GuestResourceQuota(totalVCPUs: 4, totalMemoryMiB: 4096, maxVMs: 4)
        )
        // CPU clamp: a 12 GB iPad the process can only run on 3 cores.
        XCTAssertEqual(
            GuestResourceQuota.defaultQuota(for: profile(.pad, 12, 3)).totalVCPUs, 3
        )
        // iPhone rows.
        XCTAssertEqual(
            GuestResourceQuota.defaultQuota(for: profile(.phone, 4, 6)),
            GuestResourceQuota(totalVCPUs: 1, totalMemoryMiB: 512, maxVMs: 1)
        )
        XCTAssertEqual(
            GuestResourceQuota.defaultQuota(for: profile(.phone, 6, 6)),
            GuestResourceQuota(totalVCPUs: 2, totalMemoryMiB: 1024, maxVMs: 2)
        )
        XCTAssertEqual(
            GuestResourceQuota.defaultQuota(for: profile(.phone, 8, 6)),
            GuestResourceQuota(totalVCPUs: 2, totalMemoryMiB: 1536, maxVMs: 2)
        )
        XCTAssertEqual(
            GuestResourceQuota.defaultQuota(for: profile(.phone, 12, 6)),
            GuestResourceQuota(totalVCPUs: 3, totalMemoryMiB: 2048, maxVMs: 3)
        )
    }

    func testPerformanceQuotaGating() {
        let gib = 1024 * 1024 * 1024
        func evidence(_ id: String) -> GuestResourceQuota.PerformanceTierEvidence {
            GuestResourceQuota.PerformanceTierEvidence(
                verificationRunID: "run-verified-1", verifiedAt: Date(),
                hardwareIdentifier: id
            )
        }
        func profile(_ family: HostProductFamily, _ bytesGiB: Int,
                     _ cores: Int, _ id: String) -> HostResourceProfile {
            HostResourceProfile(
                family: family, physicalMemoryBytes: UInt64(bytesGiB * gib),
                activeProcessorCount: cores, hardwareIdentifier: id
            )
        }
        // 12 GB iPad, matching evidence: six CPUs (core-clamped) but the
        // RAM ceiling stays 3072 MiB.
        XCTAssertEqual(
            GuestResourceQuota.performanceQuota(
                for: profile(.pad, 12, 10, "iPadFixtureA,1"),
                evidence: evidence("iPadFixtureA,1")
            ),
            GuestResourceQuota(totalVCPUs: 6, totalMemoryMiB: 3072, maxVMs: 4, source: .performanceTier)
        )
        XCTAssertEqual(
            GuestResourceQuota.performanceQuota(
                for: profile(.pad, 12, 4, "iPadFixtureA,1"),
                evidence: evidence("iPadFixtureA,1")
            )?.totalVCPUs, 4
        )
        // ≥16 GB iPad may use 4096 MiB, still bound to matching hardware.
        XCTAssertEqual(
            GuestResourceQuota.performanceQuota(
                for: profile(.pad, 16, 10, "iPadFixtureB,1"),
                evidence: evidence("iPadFixtureB,1")
            )?.totalMemoryMiB, 4096
        )
        // Wrong hardware: fail closed even with a real qualification record.
        XCTAssertNil(GuestResourceQuota.performanceQuota(
            for: profile(.pad, 12, 10, "iPadFixtureA,1"),
            evidence: evidence("iPadFixtureC,1")
        ))
        // 8 GB iPad and phones: fail closed regardless of evidence.
        XCTAssertNil(GuestResourceQuota.performanceQuota(
            for: profile(.pad, 8, 10, "iPadFixtureC,1"), evidence: evidence("iPadFixtureC,1")
        ))
        XCTAssertNil(GuestResourceQuota.performanceQuota(
            for: profile(.phone, 12, 6, "iPhoneFixtureA,1"), evidence: evidence("iPhoneFixtureA,1")
        ))
    }

    // MARK: - memory ladder + advisory history

    /// The ladder steps are declarative: 1024 -> 1536 -> 2048, never
    /// rawValue + 256 (which would produce non-existent 1280/1792).
    func testMemoryLadderStepsByDeclaration() {
        XCTAssertEqual(GuestMemoryMiB.m256.raised(), .m512)
        XCTAssertEqual(GuestMemoryMiB.m768.raised(), .m1024)
        XCTAssertEqual(GuestMemoryMiB.m1024.raised(), .m1536)
        XCTAssertEqual(GuestMemoryMiB.m1536.raised(), .m2048)
        XCTAssertNil(GuestMemoryMiB.m2048.raised())
        XCTAssertEqual(GuestMemoryMiB.m1024.lowered(), .m768)
        XCTAssertEqual(GuestMemoryMiB.m2048.lowered(), .m1536)
        XCTAssertEqual(GuestMemoryMiB.largestAtOrBelow(1280), .m1024)
        XCTAssertEqual(GuestMemoryMiB.smallestHolding(1280), .m1536)
    }

    /// History pressure raises to the NEXT declared tier, including across
    /// the 1 GiB boundary, and never past 2048.
    func testAdvisoryHistoryPressureRaisesToNextTier() async {
        let advisory = GuestResourceAdvisory()
        // A declared JVM command plans 1024 MiB.
        let jvmSignals = WorkloadResourceSignals(
            workloadKey: "w-jvm", declaredCommands: ["java"]
        )
        let planned = await advisory.recommend(jvmSignals)
        XCTAssertEqual(planned.shape.memory, .m1024)

        await advisory.recordOutcome(
            WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m256), succeeded: false, memoryPressure: true),
            for: "w-jvm"
        )
        let raised = await advisory.recommend(jvmSignals)
        XCTAssertEqual(raised.shape.memory, .m1536)
        XCTAssertTrue(raised.evidenceSignals.contains("history:memory-pressure"))

        // A second pressure record raises 1536 -> 2048 and stops there.
        await advisory.recordOutcome(
            WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m256), succeeded: false, memoryPressure: true),
            for: "w-jvm"
        )
        let ceiling = await advisory.recommend(jvmSignals)
        XCTAssertEqual(ceiling.shape.memory, .m2048)

        // A heavy-ML plan already at 1536 also advances to 2048.
        let mlSignals = WorkloadResourceSignals(
            workloadKey: "w-ml", declaredImports: ["torch"]
        )
        let mlPlan = await advisory.recommend(mlSignals)
        XCTAssertEqual(mlPlan.shape.memory, .m1536)
        await advisory.recordOutcome(
            WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m256), succeeded: false, memoryPressure: true),
            for: "w-ml"
        )
        let mlRaised = await advisory.recommend(mlSignals)
        XCTAssertEqual(mlRaised.shape.memory, .m2048)
    }

    /// User override beats both the plan and history.
    func testAdvisoryUserOverrideWins() async {
        let advisory = GuestResourceAdvisory()
        let signals = WorkloadResourceSignals(workloadKey: "w-pin", declaredCommands: ["java"])
        await advisory.setUserOverride(
            GuestResourceRequest(vcpus: .two, memory: .m512, origin: .userSpecified),
            for: "w-pin"
        )
        let recommendation = await advisory.recommend(signals)
        XCTAssertTrue(recommendation.userOverride)
        XCTAssertEqual(recommendation.shape.vcpus, .two)
        XCTAssertEqual(recommendation.shape.memory, .m512)
        await advisory.setUserOverride(nil, for: "w-pin")
        let unpinned = await advisory.recommend(signals)
        XCTAssertFalse(unpinned.userOverride)
    }

    // MARK: - helpers

    private func assertCancellation<T>(_ task: Task<T, Error>) async {
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func awaitWithTimeout<T>(_ task: Task<T, Error>, seconds: TimeInterval = 2) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw RuntimeV2Error.queueTimedOut(environmentID: "test", seconds: Int(seconds))
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
