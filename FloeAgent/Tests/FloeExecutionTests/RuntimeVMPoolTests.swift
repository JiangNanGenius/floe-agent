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
        seams: RuntimeVMPool.Seams = .unrestricted,
        releasePolicy: GuestReleaseShapePolicy = .production
    ) -> RuntimeVMPool {
        RuntimeVMPool(
            configuration: RuntimeVMPool.Configuration(
                quota: GuestResourceQuota(
                    totalVCPUs: vcpus, totalMemoryMiB: memory, maxVMs: vms
                ),
                releasePolicy: releasePolicy
            ),
            registry: nil,
            seams: seams
        )
    }

    /// Explicit internal test configuration that unlocks the engine's dual
    /// ladder for the SYNTHETIC SMP admission tests; never used by the B4
    /// release-gate tests below.
    private static let syntheticDual = GuestReleaseShapePolicy.internalSyntheticTesting(
        maximumSupportedVCPUs: 2, provenance: "RuntimeVMPoolTests synthetic SMP admission"
    )

    /// A pool whose release policy allows the engine ladder (synthetic SMP
    /// admission tests only; the B4 tests assert against `.production`).
    private func makeSyntheticDualPool(
        quota vcpus: Int = 4,
        memory: Int = 3072,
        vms: Int = 4,
        seams: RuntimeVMPool.Seams = .unrestricted
    ) -> RuntimeVMPool {
        makePool(quota: vcpus, memory: memory, vms: vms, seams: seams, releasePolicy: Self.syntheticDual)
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
        let pool = makeSyntheticDualPool(quota: 4, memory: 2048, vms: 4)
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
        let pool = makeSyntheticDualPool(quota: 4, memory: 2048, vms: 4)
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
        // The pool is GENUINELY exhausted before the queue forms: a dual plus
        // two singles commit all 4 vCPUs and all 2048 MiB, so the queued dual
        // cannot fit until the running dual is released.
        let pool = makeSyntheticDualPool(quota: 4, memory: 2048, vms: 4)
        let dual = GuestResourceRequest(vcpus: .two, memory: .m1024)
        _ = try await pool.acquire(
            environmentID: "dual", runtimeID: "rt-dual",
            request: dual, imageSMPCapable: true
        )
        for index in 0..<2 {
            _ = try await pool.acquire(
                environmentID: "single-\(index)", runtimeID: "rt-single-\(index)",
                request: GuestResourceRequest(vcpus: .one, memory: .m512),
                imageSMPCapable: false
            )
        }
        let full = await pool.status
        XCTAssertEqual(full.usedVCPUs, 4)
        XCTAssertEqual(full.reservedMB, 2048)

        let queuedTask = Task {
            try await pool.acquire(
                environmentID: "dual-1", runtimeID: "rt-dual-1",
                request: dual, imageSMPCapable: true
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        // FIFO witness: a later single-hart request must not jump the queued
        // dual; it queues behind it even though less is asked of the pool.
        let follower = Task {
            try await pool.acquire(
                environmentID: "single-2", runtimeID: "rt-single-2",
                request: Self.single512, imageSMPCapable: false
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = await pool.queuedCount
        XCTAssertEqual(queued, 2)

        await pool.release(runtimeID: "rt-dual")
        // The first waiter (the dual) is promoted; the release returned its
        // exact shape and runtimeID.
        let promoted = try await awaitWithTimeout(queuedTask)
        XCTAssertEqual(promoted.runtimeID, "rt-dual-1")
        XCTAssertEqual(promoted.shape.vcpus, .two)
        XCTAssertEqual(promoted.shape.memory, .m1024)
        let status = await pool.status
        XCTAssertEqual(status.running, 3)
        XCTAssertEqual(status.usedVCPUs, 4)
        XCTAssertEqual(status.reservedMB, 2048)
        XCTAssertEqual(status.queued, 1)
        let promotedLease = await pool.lease(runtimeID: "rt-dual-1")
        let releasedLease = await pool.lease(runtimeID: "rt-dual")
        XCTAssertNotNil(promotedLease)
        XCTAssertNil(releasedLease)
        // The follower is still queued, not silently granted (FIFO, no
        // over-admission of a second guest beyond the released capacity).
        let followerLease = await pool.lease(runtimeID: "rt-single-2")
        XCTAssertNil(followerLease)
        follower.cancel()
        await assertCancellation(follower)
    }

    // MARK: - B4 release gate (single-core release, independent of manifest)

    /// An explicit dual request on a PRODUCTION pool is refused even when
    /// the image claims SMP (`imageSMPCapable: true`) and even though the
    /// quota has room: this release is not qualified for two harts. The
    /// refusal is immediate (nothing queued, nothing reserved).
    func testProductionReleasesStrictDualDespiteSMPCapableClaim() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        do {
            _ = try await pool.acquire(
                environmentID: "dual", runtimeID: "rt-dual",
                request: GuestResourceRequest(vcpus: .two, memory: .m512, origin: .environmentPolicy),
                imageSMPCapable: true,
                downgrade: .strict
            )
            XCTFail("a strict dual request must fail the release gate despite smp=true")
        } catch let error as LinuxGuestError {
            guard case .releaseShapeUnsupported(let requested, let maximum) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(requested, 2)
            XCTAssertEqual(maximum, 1)
        }
        let status = await pool.status
        XCTAssertEqual(status.running, 0)
        XCTAssertEqual(status.usedVCPUs, 0)
        let queuedAfterRefusal = await pool.queuedCount
        XCTAssertEqual(queuedAfterRefusal, 0)
    }

    /// A genuine auto plan (`.recommendation`) that asks two harts may fall
    /// back to one ONLY with an explicit authorized single-core floor, and
    /// the lease records the actual granted shape plus the downgrade reason.
    func testProductionAuthorizedAutoDualFallsBackToRecordedSingle() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        let lease = try await pool.acquire(
            environmentID: "auto", runtimeID: "rt-auto",
            request: GuestResourceRequest(vcpus: .two, memory: .m512, origin: .recommendation),
            imageSMPCapable: true,
            downgrade: .authorized(vcpuFloor: .one, memoryFloor: .m256)
        )
        XCTAssertEqual(lease.shape.vcpus, .one)
        XCTAssertTrue(lease.vcpusDowngraded)
        XCTAssertEqual(lease.vcpusDowngradeReason?.contains("release"), true)
        let status = await pool.status
        XCTAssertEqual(status.usedVCPUs, 1)
    }

    /// An authorized policy whose floor still demands two harts is refused
    /// rather than silently downgraded — the release never grants two.
    func testProductionAuthorizedFloorTwoStillRefused() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        do {
            _ = try await pool.acquire(
                environmentID: "dual", runtimeID: "rt-dual",
                request: GuestResourceRequest(vcpus: .two, memory: .m512),
                imageSMPCapable: true,
                downgrade: .authorized(vcpuFloor: .two, memoryFloor: .m256)
            )
            XCTFail("an authorized two-hart floor must still fail the release gate")
        } catch let error as LinuxGuestError {
            guard case .releaseShapeUnsupported = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// The single-core release still allows the device pool to run several
    /// one-hart VMs concurrently (per-VM count is NOT collapsed to one VM).
    func testProductionAllowsMultipleSingleCoreVMs() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        for index in 0..<4 {
            let lease = try await pool.acquire(
                environmentID: "env-\(index)", runtimeID: "rt-\(index)",
                request: GuestResourceRequest(vcpus: .one, memory: .m512),
                imageSMPCapable: false
            )
            XCTAssertEqual(lease.shape.vcpus, .one)
            XCTAssertFalse(lease.wasDowngraded)
        }
        let status = await pool.status
        XCTAssertEqual(status.running, 4)
        XCTAssertEqual(status.usedVCPUs, 4)
    }

    /// Reshape planning on a production pool refuses a second hart before
    /// any disruption even with a capable image and free quota.
    func testProductionReshapeToDualRefusedBeforeDisruption() async throws {
        let pool = makePool(quota: 4, memory: 2048, vms: 4)
        _ = try await pool.acquire(
            environmentID: "env-0", runtimeID: "rt-0",
            request: GuestResourceRequest(vcpus: .one, memory: .m512),
            imageSMPCapable: false
        )
        do {
            try await pool.validateShapeChange(
                environmentID: "env-0",
                request: GuestResourceRequest(vcpus: .two, memory: .m512),
                imageSMPCapable: true
            )
            XCTFail("a dual reshape must fail the release gate")
        } catch let error as LinuxGuestError {
            guard case .releaseShapeUnsupported = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        // The running lease is untouched.
        let lease = await pool.lease(runtimeID: "rt-0")
        XCTAssertEqual(lease?.shape.vcpus, .one)
    }

    // MARK: - temporary shortage vs permanent image mismatch

    /// Strict dual with one vCPU free: temporary shortage ⇒ queue, never
    /// silently single. Uses the explicit internal synthetic-dual policy:
    /// this tests the quota queue, while the B4 tests below pin the release
    /// gate's refusal on production pools.
    func testStrictDualTemporaryShortageQueues() async throws {
        let pool = makeSyntheticDualPool(quota: 2, memory: 1024, vms: 2)
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
    /// admission: permanent mismatch ⇒ immediate actionable error. The
    /// release gate is bypassed here by the explicit internal synthetic-dual
    /// policy so this tests the IMAGE gate specifically; the B4 tests below
    /// prove the release gate fires first on a production pool even when an
    /// image manifest claims SMP.
    func testStrictDualOnUnsupportedImageErrorsNotQueues() async throws {
        let pool = makeSyntheticDualPool(quota: 4, memory: 2048, vms: 4)
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
    /// Uses the explicit internal synthetic-dual policy so this exercises
    /// the IMAGE gate; on a production pool the release gate fires first
    /// (covered by the B4 tests below).
    func testAuthorizedDualOnUnsupportedImageDowngrades() async throws {
        let pool = makeSyntheticDualPool(quota: 4, memory: 2048, vms: 4)
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

    /// A strict shape that exceeds the pool's TOTAL capacity (even empty)
    /// can never be fulfilled: actionable error now, never an endless queue.
    func testStrictShapeBeyondPoolCapacityFailsFast() async throws {
        // One vCPU / 512 MiB device profile, pool completely empty. The
        // explicit internal synthetic-dual policy keeps the release gate
        // open so this tests the device-PROFILE mismatch specifically.
        let pool = makeSyntheticDualPool(quota: 1, memory: 512, vms: 1)
        do {
            _ = try await pool.acquire(
                environmentID: "dual", runtimeID: "rt-dual",
                request: GuestResourceRequest(vcpus: .two, memory: .m512),
                imageSMPCapable: true,       // image is fine; the PROFILE is not
                downgrade: .strict
            )
            XCTFail("expected shapeExceedsPoolCapacity for a dual on a 1-vCPU pool")
        } catch let error as LinuxGuestError {
            guard case .shapeExceedsPoolCapacity(let detail) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("1 vCPU"), detail)
        }
        do {
            _ = try await pool.acquire(
                environmentID: "big", runtimeID: "rt-big",
                request: GuestResourceRequest(vcpus: .one, memory: .m2048),
                imageSMPCapable: false,
                downgrade: .strict
            )
            XCTFail("expected shapeExceedsPoolCapacity for 2048 MiB on a 512 MiB pool")
        } catch let error as LinuxGuestError {
            guard case .shapeExceedsPoolCapacity = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let queued = await pool.queuedCount
        let status = await pool.status
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(status.running, 0)
    }

    /// The same profile with an explicitly authorized downgrade succeeds:
    /// minimum acceptable shape (floor) does fit the device pool.
    func testAuthorizedShapeBeyondPoolDowngrades() async throws {
        let pool = makeSyntheticDualPool(quota: 1, memory: 512, vms: 1)
        let dual = try await pool.acquire(
            environmentID: "dual", runtimeID: "rt-dual",
            request: GuestResourceRequest(vcpus: .two, memory: .m512),
            imageSMPCapable: true,
            downgrade: .authorized(memoryFloor: .m256)
        )
        XCTAssertEqual(dual.shape.vcpus, .one)
        XCTAssertTrue(dual.vcpusDowngraded)

        // A 2 GiB request authorized down to the 256 MiB floor takes the
        // largest fitting step (512 MiB here).
        await pool.release(runtimeID: "rt-dual")
        let big = try await pool.acquire(
            environmentID: "big", runtimeID: "rt-big",
            request: GuestResourceRequest(vcpus: .one, memory: .m2048),
            imageSMPCapable: false,
            downgrade: .authorized(memoryFloor: .m256)
        )
        XCTAssertEqual(big.shape.memory, .m512)
        XCTAssertTrue(big.memoryDowngraded)
    }

    /// Temporary shortage on an adequately sized device still QUEUES (the
    /// shape fits the pool total, only the pool is currently occupied).
    func testTemporaryOccupiedCapacityStillQueues() async throws {
        let pool = makePool(quota: 2, memory: 1024, vms: 2)
        _ = try await pool.acquire(
            environmentID: "busy", runtimeID: "rt-busy",
            request: GuestResourceRequest(vcpus: .one, memory: .m1024),
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
        // Explicit internal synthetic-dual policy: this tests the image gate
        // and quota validation; the B4 tests below pin the release gate that
        // refuses a dual reshape on a production pool regardless of the image.
        let pool = makeSyntheticDualPool(quota: 4, memory: 3072, vms: 4)
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

    /// The direct machine boundary enforces the production release gate
    /// (B4): a descriptor claiming two harts cannot be constructed even when
    /// the pool is bypassed, regardless of the image manifest. A malformed
    /// count is rejected, never clamped.
    func testMachineProductionPolicyRejectsExplicitDualAndInvalidCounts() throws {
        let image = LinuxGuestImage(id: "img", biosPath: "bbl64.bin", qualified: false)
        let dual = LinuxGuestEnvironmentDescriptor(
            id: "env-1", imageID: "img", ramMB: 1024, vcpus: 2
        )
        XCTAssertThrowsError(
            try TinyEMUGuestMachine(descriptor: dual, image: image, limits: .standard)
        ) { error in
            guard case .unsupportedReleaseVCPUCount(let requested, let maximum) =
                error as? GuestReleaseShapeError else {
                return XCTFail("expected unsupportedReleaseVCPUCount, got \(error)")
            }
            XCTAssertEqual(requested, 2)
            XCTAssertEqual(maximum, 1)
        }
        // A six-core request is malformed relative to the engine ladder, not
        // silently clamped to two.
        let six = LinuxGuestEnvironmentDescriptor(
            id: "env-1", imageID: "img", ramMB: 1024, vcpus: 6
        )
        XCTAssertThrowsError(
            try TinyEMUGuestMachine(descriptor: six, image: image, limits: .standard)
        ) { error in
            guard case .invalidVCPUCount(let requested, _) = error as? GuestReleaseShapeError else {
                return XCTFail("expected invalidVCPUCount, got \(error)")
            }
            XCTAssertEqual(requested, 6)
        }
        let zero = LinuxGuestEnvironmentDescriptor(
            id: "env-1", imageID: "img", ramMB: 1024, vcpus: 0
        )
        XCTAssertThrowsError(
            try TinyEMUGuestMachine(descriptor: zero, image: image, limits: .standard)
        ) { error in
            guard case .invalidVCPUCount = error as? GuestReleaseShapeError else {
                return XCTFail("expected invalidVCPUCount for 0, got \(error)")
            }
        }
    }

    /// Synthetic SMP engine/admission experiments stay possible through the
    /// explicit internal test policy only (code-supplied provenance); the
    /// machine then accepts two harts and its setVCPUs boundary still rejects
    /// malformed counts and never clamps six to two.
    func testMachineSyntheticDualPolicyAcceptsTwoButRejectsSix() throws {
        let image = LinuxGuestImage(id: "img", biosPath: "bbl64.bin", qualified: false)
        let descriptor = LinuxGuestEnvironmentDescriptor(
            id: "env-1", imageID: "img", ramMB: 1024, vcpus: 2
        )
        let policy = GuestReleaseShapePolicy.internalSyntheticTesting(
            maximumSupportedVCPUs: 2, provenance: "RuntimeVMPoolTests direct machine dual"
        )
        let machine = try TinyEMUGuestMachine(
            descriptor: descriptor, image: image, limits: .standard, releasePolicy: policy
        )
        XCTAssertEqual(machine.configuredShape.vcpus, 2)
        XCTAssertEqual(machine.configuredShape.ramMB, 1024)
        try machine.setVCPUs(1)
        XCTAssertEqual(machine.configuredShape.vcpus, 1)
        try machine.setVCPUs(2)
        XCTAssertEqual(machine.configuredShape.vcpus, 2)
        XCTAssertThrowsError(try machine.setVCPUs(6)) { error in
            guard case .invalidVCPUCount = error as? GuestReleaseShapeError else {
                return XCTFail("expected invalidVCPUCount for 6, got \(error)")
            }
        }
        XCTAssertEqual(machine.configuredShape.vcpus, 2, "a refused count must not change the shape")
    }

    /// Pure release-gate contract: loose integer parsing under production
    /// and synthetic policies, with no clamping in any direction.
    func testReleaseShapePolicyResolution() throws {
        let production = GuestReleaseShapePolicy.production
        XCTAssertEqual(try production.resolve(requestedVCPUs: nil), .one)
        XCTAssertEqual(try production.resolve(requestedVCPUs: 1), .one)
        XCTAssertThrowsError(try production.resolve(requestedVCPUs: 2)) {
            guard case .unsupportedReleaseVCPUCount(2, 1) = $0 as? GuestReleaseShapeError else {
                return XCTFail("unexpected \($0)")
            }
        }
        for bad in [0, -1, 3, 6, 64] {
            XCTAssertThrowsError(try production.resolve(requestedVCPUs: bad)) {
                guard case .invalidVCPUCount = $0 as? GuestReleaseShapeError else {
                    return XCTFail("\(bad) must be invalid, not clamped: \($0)")
                }
            }
        }
        let synthetic = GuestReleaseShapePolicy.internalSyntheticTesting(provenance: "unit")
        XCTAssertEqual(try synthetic.resolve(requestedVCPUs: 2), .two)
        XCTAssertThrowsError(try synthetic.resolve(requestedVCPUs: 6)) {
            guard case .invalidVCPUCount = $0 as? GuestReleaseShapeError else {
                return XCTFail("synthetic policy must still reject six: \($0)")
            }
        }
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

    /// History is evidence-bounded: only a FAILED run at (or above) the
    /// planned shape that really reported memory pressure advances the plan,
    /// and then by exactly one declared tier. Successes and stale low-shape
    /// pressure reports never inflate it, and repeating one failure record
    /// does not raise it twice. The outcome shape is the ACTUAL granted shape.
    func testAdvisoryHistoryPressureRaisesToNextTier() async {
        let advisory = GuestResourceAdvisory()
        // A declared JVM command plans 1024 MiB.
        let jvmSignals = WorkloadResourceSignals(
            workloadKey: "w-jvm", declaredCommands: ["java"]
        )
        let planned = await advisory.recommend(jvmSignals)
        XCTAssertEqual(planned.shape.memory, .m1024)

        // A successful run at the planned shape is evidence the plan worked.
        await advisory.recordOutcome(
            WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m1024), succeeded: true),
            for: "w-jvm"
        )
        let afterSuccess = await advisory.recommend(jvmSignals)
        XCTAssertEqual(afterSuccess.shape.memory, .m1024)
        XCTAssertFalse(afterSuccess.evidenceSignals.contains("history:memory-pressure"))

        // A stale pressure report from a smaller shape (the workload really
        // ran at 256 MiB) says nothing about the 1024 MiB plan; repeated
        // low-tier failures must not inflate it.
        for _ in 0..<3 {
            await advisory.recordOutcome(
                WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m256), succeeded: false, memoryPressure: true),
                for: "w-jvm"
            )
        }
        let stale = await advisory.recommend(jvmSignals)
        XCTAssertEqual(stale.shape.memory, .m1024)
        XCTAssertFalse(stale.evidenceSignals.contains("history:memory-pressure"))

        // A real pressure failure at the granted 1024 MiB plan raises exactly
        // one declared step.
        await advisory.recordOutcome(
            WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m1024), succeeded: false, memoryPressure: true),
            for: "w-jvm"
        )
        let raised = await advisory.recommend(jvmSignals)
        XCTAssertEqual(raised.shape.memory, .m1536)
        XCTAssertTrue(raised.evidenceSignals.contains("history:memory-pressure"))

        // Repeating the identical failure record does not raise it again.
        await advisory.recordOutcome(
            WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m1024), succeeded: false, memoryPressure: true),
            for: "w-jvm"
        )
        let repeated = await advisory.recommend(jvmSignals)
        XCTAssertEqual(repeated.shape.memory, .m1536)

        // A real failure at the raised, actually-granted 1536 MiB advances to
        // the declared ceiling 2048 and stops there (even for a failure at
        // 2048 itself).
        await advisory.recordOutcome(
            WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m1536), succeeded: false, memoryPressure: true),
            for: "w-jvm"
        )
        let ceiling = await advisory.recommend(jvmSignals)
        XCTAssertEqual(ceiling.shape.memory, .m2048)
        await advisory.recordOutcome(
            WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m2048), succeeded: false, memoryPressure: true),
            for: "w-jvm"
        )
        let atCeiling = await advisory.recommend(jvmSignals)
        XCTAssertEqual(atCeiling.shape.memory, .m2048)

        // A heavy-ML plan already at 1536 also advances to 2048 on a real
        // 1536 MiB failure...
        let mlSignals = WorkloadResourceSignals(
            workloadKey: "w-ml", declaredImports: ["torch"]
        )
        let mlPlan = await advisory.recommend(mlSignals)
        XCTAssertEqual(mlPlan.shape.memory, .m1536)
        await advisory.recordOutcome(
            WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m1536), succeeded: false, memoryPressure: true),
            for: "w-ml"
        )
        let mlRaised = await advisory.recommend(mlSignals)
        XCTAssertEqual(mlRaised.shape.memory, .m2048)

        // ...while a stale 1024 MiB pressure report leaves the same plan alone.
        let mlStale = GuestResourceAdvisory()
        await mlStale.recordOutcome(
            WorkloadResourceOutcome(shape: .init(vcpus: .one, memory: .m1024), succeeded: false, memoryPressure: true),
            for: "w-ml"
        )
        let mlStillPlanned = await mlStale.recommend(mlSignals)
        XCTAssertEqual(mlStillPlanned.shape.memory, .m1536)
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
