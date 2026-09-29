// FloeExecutionTests — Build 236 first-use Linux storage initialization.
//
// Pins the contracts the "Preparing Linux image storage" card and the first
// exec.shell rely on:
//   * concurrent first uses of the Runtime v2 substrate share ONE startup
//     recovery pass instead of each running the full multi-gigabyte recovery
//     (the repeated-initialization compounding on the first-use path),
//   * a cancelled caller's WAIT finishes immediately even while the shared
//     pass is still running — the pass itself is never cancelled (recovery
//     mutates durable state and must run to completion), and a later caller
//     settles on the completed pass,
//   * the same no-spinner evidence holds for an EXTERNAL cancellation token
//     (the shared-job owner style), not only Swift task cancellation,
//   * a failed preparation stays retryable and the next use settles,
//   * recovery stages are reported in order so the UI can present honest
//     progress instead of a bare indeterminate spinner,
//   * after a stalled first preparation completes, first-use install truth
//     resumes (the shared install path's presence check derives from a real
//     health read again),
//   * a cancelled UI-style status read settles (throws CancellationError,
//     caches no verdict) and a later uncancelled read reports the real bytes.
//
// The card itself (FloeApp target) consumes these through
// `FloePlatformServices.linuxImageStatus(id:isCancelled:)`; the behavior is
// proven here at the service layer the card delegates to.

import Foundation
import Synchronization
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

final class LinuxGuestFirstUsePreparationTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-first-use-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - One recovery pass for concurrent first uses

    /// Two concurrent status reads (the shape the terminal card and the
    /// settings screen produce when they mount together) must run the startup
    /// recovery exactly once: the second caller joins the in-flight pass
    /// instead of starting a second one.
    func testConcurrentFirstUseHealthCallsShareOnePreparation() async throws {
        let store = RuntimeV2Store(layout: RuntimeV2Layout(root: root))
        let gate = PreparationGate(parks: true, failFirst: false)
        let integrator = RuntimeV2GuestIntegrator(
            store: store,
            legacyImagesRoot: nil,
            build: "test",
            seams: .init(prepareAndRecover: { _ in await gate.enterAndWait() })
        )

        let first = Task { await integrator.imageHealth(imageID: "absent-image", isCancelled: nil) }
        // Wait until the first pass is actually in flight (parked), then
        // introduce the concurrent second use.
        await gate.waitUntilEntered(expected: 1)
        let second = Task { await integrator.isImageVerifiedWithoutMigration(imageID: "absent-image") }
        // Give the second caller time to reach the integrator; it must NOT
        // have started a second recovery pass.
        try await Task.sleep(for: .milliseconds(150))
        let entriesBeforeRelease = await gate.entries
        XCTAssertEqual(entriesBeforeRelease, 1,
                       "a concurrent first use must join the in-flight recovery, not duplicate it")

        await gate.releaseAll()
        let firstHealth = await first.value
        let secondVerified = await second.value
        XCTAssertNil(firstHealth, "no image is registered: the honest answer is nil")
        XCTAssertFalse(secondVerified)
        let totalEntries = await gate.entries
        XCTAssertEqual(totalEntries, 1, "exactly one recovery pass may run for concurrent first uses")

        // A later use is already prepared: no new pass at all.
        let laterHealth = await integrator.imageHealth(imageID: "absent-image", isCancelled: nil)
        XCTAssertNil(laterHealth)
        let laterEntries = await gate.entries
        XCTAssertEqual(laterEntries, 1)
    }

    // MARK: - Cancelled waiter finishes BEFORE the parked recovery

    /// The no-spinner cancellation evidence: with the shared pass parked
    /// indefinitely, cancelling the caller must let the caller's wait finish
    /// IMMEDIATELY — before the pass is unblocked. The pass itself must not
    /// be cancelled: after it is released, a later caller settles on its
    /// result and no second pass runs.
    func testCancelledWaiterFinishesBeforeParkedRecoveryCompletes() async throws {
        let store = RuntimeV2Store(layout: RuntimeV2Layout(root: root))
        let gate = PreparationGate(parks: true, failFirst: false)
        let integrator = RuntimeV2GuestIntegrator(
            store: store,
            legacyImagesRoot: nil,
            build: "test",
            seams: .init(prepareAndRecover: { _ in await gate.enterAndWait() })
        )

        let box = ResultBox<LinuxImageHealthCheck>()
        let waiter = Task {
            await box.set(await integrator.imageHealth(imageID: "absent-image", isCancelled: nil))
        }
        await gate.waitUntilEntered(expected: 1)

        // Cancel the caller while the shared pass is still parked.
        waiter.cancel()
        // The wait MUST finish now, without unblocking the recovery. A
        // regression that ties the wait to the pass times out here.
        let finished = await box.waitForValue(timeoutSeconds: 5)
        XCTAssertTrue(finished, "the cancelled wait must finish before the parked recovery is released")
        let outcome = await box.current
        guard case .cancelled? = outcome else {
            return XCTFail("expected .cancelled, got \(String(describing: outcome))")
        }
        // The shared pass is untouched: still the single parked entry.
        let entriesAfterCancel = await gate.entries
        XCTAssertEqual(entriesAfterCancel, 1)
        let stillParked = await gate.isParked
        XCTAssertTrue(stillParked, "the shared recovery must keep running (stay parked)")

        // Unblock: the SAME pass completes; a later caller settles on it and
        // no second pass starts.
        await gate.releaseAll()
        let settledHealth = await integrator.imageHealth(imageID: "absent-image", isCancelled: nil)
        XCTAssertNil(settledHealth)
        let finalEntries = await gate.entries
        XCTAssertEqual(finalEntries, 1)
    }

    /// Same no-spinner evidence for an EXTERNAL cancellation token (the
    /// shared-job owner style, not Swift task cancellation): firing the
    /// token while the pass is parked must resolve the wait immediately,
    /// again before the pass is unblocked and without cancelling the pass.
    func testExternalTokenCancellationFinishesWaiterBeforeParkedRecoveryCompletes() async throws {
        let store = RuntimeV2Store(layout: RuntimeV2Layout(root: root))
        let gate = PreparationGate(parks: true, failFirst: false)
        let integrator = RuntimeV2GuestIntegrator(
            store: store,
            legacyImagesRoot: nil,
            build: "test",
            seams: .init(prepareAndRecover: { _ in await gate.enterAndWait() })
        )

        let token = CancellationToken()
        let box = ResultBox<LinuxImageHealthCheck>()
        let waiter = Task {
            await box.set(await integrator.imageHealth(imageID: "absent-image", isCancelled: { token.isCancelled }))
        }
        await gate.waitUntilEntered(expected: 1)

        token.cancel()
        let finished = await box.waitForValue(timeoutSeconds: 5)
        XCTAssertTrue(finished, "the token-cancelled wait must finish before the parked recovery is released")
        let outcome = await box.current
        guard case .cancelled? = outcome else {
            return XCTFail("expected .cancelled, got \(String(describing: outcome))")
        }
        let entriesAfterCancel = await gate.entries
        XCTAssertEqual(entriesAfterCancel, 1)
        let stillParked = await gate.isParked
        XCTAssertTrue(stillParked, "the shared recovery must keep running (stay parked)")

        await gate.releaseAll()
        let settledHealth = await integrator.imageHealth(imageID: "absent-image", isCancelled: nil)
        XCTAssertNil(settledHealth)
        let finalEntries = await gate.entries
        XCTAssertEqual(finalEntries, 1)
    }

    // MARK: - Failure stays retryable; the next use settles

    /// A failed recovery pass must not wedge the substrate: the next Linux use
    /// starts a fresh pass and settles. (The UI settles to
    /// storage-unavailable/needs-download instead of an indefinite spinner.)
    func testFailedPreparationIsRetriedByTheNextUse() async throws {
        let store = RuntimeV2Store(layout: RuntimeV2Layout(root: root))
        let gate = PreparationGate(parks: false, failFirst: true)
        let integrator = RuntimeV2GuestIntegrator(
            store: store,
            legacyImagesRoot: nil,
            build: "test",
            seams: .init(prepareAndRecover: { _ in
                try await gate.enterAndWaitThrowing()
            })
        )

        // First use: the pass fails; the health read answers nil (the
        // integrator maps an unprepared store to "no verdict"), and crucially
        // RETURNS instead of hanging.
        let failedHealth = await integrator.imageHealth(imageID: "absent-image", isCancelled: nil)
        XCTAssertNil(failedHealth)
        let firstEntries = await gate.entries
        XCTAssertEqual(firstEntries, 1)

        // Second use: a fresh pass runs and succeeds; the read settles.
        let settledHealth = await integrator.imageHealth(imageID: "absent-image", isCancelled: nil)
        XCTAssertNil(settledHealth, "image still absent; the settled honest answer is nil")
        let secondEntries = await gate.entries
        XCTAssertEqual(secondEntries, 2)

        // Success is cached: no third pass.
        let thirdHealth = await integrator.imageHealth(imageID: "absent-image", isCancelled: nil)
        XCTAssertNil(thirdHealth)
        let thirdEntries = await gate.entries
        XCTAssertEqual(thirdEntries, 2)
    }

    // MARK: - Recovery stages are reported in order

    /// The shared pass reports every recovery stage in a stable order, so the
    /// component card can present honest progress (and `preparationStage()`
    /// exposes the latest one to the app wiring).
    func testRecoveryStagesAreReportedInOrder() async throws {
        let store = RuntimeV2Store(layout: RuntimeV2Layout(root: root))
        let recorder = StageRecorder()
        let integrator = RuntimeV2GuestIntegrator(
            store: store,
            legacyImagesRoot: nil,
            build: "test"
        )
        await integrator.setPreparationStageHandler { stage in
            recorder.record(stage)
        }
        let stageBefore = await integrator.preparationStage()
        XCTAssertNil(stageBefore)
        let absentHealth = await integrator.imageHealth(imageID: "absent-image", isCancelled: nil)
        XCTAssertNil(absentHealth)
        let expected: [RuntimeV2Store.RecoveryStage] = [
            .queue, .leases, .runtimeDirectories, .preservedQuarantine,
            .stagedImages, .orphanManifests, .expandedViews, .templates
        ]
        let stages = await recorder.waitForStages(count: expected.count)
        XCTAssertEqual(stages, expected)
        let stageAfter = await integrator.preparationStage()
        XCTAssertEqual(stageAfter, .templates)
    }

    // MARK: - First use with the image absent settles (real store, no seam)

    /// With the real recovery on an empty substrate, a first-use health read
    /// and the verified gate both settle immediately — the condition that kept
    /// the device card on "Preparing Linux image storage" while the shell
    /// never produced a receipt.
    func testFirstUseAbsentImageSettlesOnRealRecovery() async throws {
        let store = RuntimeV2Store(layout: RuntimeV2Layout(root: root))
        let integrator = RuntimeV2GuestIntegrator(
            store: store,
            legacyImagesRoot: nil,
            build: "test"
        )
        let absentHealth = await integrator.imageHealth(imageID: "never-installed", isCancelled: nil)
        XCTAssertNil(absentHealth, "the v2 store does not hold the image: nil, not a spinner")
        let absentVerified = await integrator.isImageVerifiedWithoutMigration(imageID: "never-installed")
        XCTAssertFalse(absentVerified)
        // Repeated reads stay cheap: recovery ran once (idempotent no-op).
        let repeatedHealth = await integrator.imageHealth(imageID: "never-installed", isCancelled: nil)
        XCTAssertNil(repeatedHealth)
    }

    // MARK: - First-use install truth resumes after a stalled preparation

    /// Device-shaped proof: the first caller is cancelled while the shared
    /// pass is stalled; the pass completes; afterwards the verified image's
    /// health read reports the REAL rebuilt state (`.verified`), so the
    /// shared auto-install path's presence check (the first thing exec.shell
    /// preparation does) derives from live truth again instead of a hang.
    func testSharedPreparationResumesFirstUseInstallTruthAfterWaiterCancel() async throws {
        let layout = RuntimeV2Layout(root: root)
        let store = RuntimeV2Store(layout: layout)
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let imageID = "floe-first-use-resume"

        // A verified v2 image whose expanded view was lost (rebuildable from
        // blobs) — exactly what startup recovery rebuilds.
        _ = try layout.prepare(build: "test")
        try await store.registry.open()
        _ = try makeInstalledImage(id: imageID, in: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: imageID, legacyImagesRoot: legacyRoot)
        let expanded = try layout.expandedImageDirectory(imageID: imageID)
        try FileManager.default.removeItem(at: expanded)

        // First caller parks on the shared pass, then abandons its wait.
        let gate = PreparationGate(parks: true, failFirst: false)
        let integrator = RuntimeV2GuestIntegrator(
            store: store,
            legacyImagesRoot: legacyRoot,
            build: "test",
            seams: .init(prepareAndRecover: { build in
                await gate.enterAndWait()
                _ = try await store.prepareAndRecover(build: build)
            })
        )
        let box = ResultBox<LinuxImageHealthCheck>()
        let stalled = Task {
            await box.set(await integrator.imageHealth(imageID: imageID, isCancelled: nil))
        }
        await gate.waitUntilEntered(expected: 1)
        stalled.cancel()
        let stalledFinished = await box.waitForValue(timeoutSeconds: 5)
        XCTAssertTrue(stalledFinished, "the cancelled wait must finish before the parked recovery is released")
        let stalledOutcome = await box.current
        guard case .cancelled? = stalledOutcome else {
            return XCTFail("expected .cancelled, got \(String(describing: stalledOutcome))")
        }
        let entriesAfterCancel = await gate.entries
        XCTAssertEqual(entriesAfterCancel, 1)

        // Release the stalled pass; the same single pass rebuilds the view.
        await gate.releaseAll()
        let resumedHealth = await integrator.imageHealth(imageID: imageID, isCancelled: nil)
        guard case .health(let value)? = resumedHealth else {
            return XCTFail("expected a real health verdict after recovery, got \(String(describing: resumedHealth))")
        }
        XCTAssertEqual(value.readiness, .verified,
                       "recovery rebuilt the expanded view: the install-truth check sees verified bytes")
        let finalEntries = await gate.entries
        XCTAssertEqual(finalEntries, 1, "the resumed pass is still the single shared pass")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expanded.appendingPathComponent("manifest.json").path))
    }

    // MARK: - Cancelled UI status read settles, caches nothing

    /// The card's refresh passes its task cancellation into the status read: a
    /// cancelled read throws CancellationError (settles immediately) and
    /// leaves NO cached verdict behind, so the next uncancelled read reports
    /// the real bytes.
    func testCancelledStatusReadSettlesWithoutCachingAVerdict() async throws {
        let serviceRoot = root.appendingPathComponent("legacy-store", isDirectory: true)
        let service = LinuxGuestImageInstallationService(root: serviceRoot, limits: .standard)
        let imageID = "floe-first-use-cancel"
        let imageDir = try makeInstalledImage(id: imageID, in: service.imagesDirectory)

        // Tamper AFTER the manifest recorded the digest: the real verdict is
        // a digest mismatch.
        let handle = try FileHandle(forUpdating: imageDir.appendingPathComponent("disk.img"))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x5A, count: 128))
        try handle.close()

        // A cancelled read settles by throwing — it never reports the stale
        // or a fabricated state.
        do {
            _ = try await service.status(id: imageID, isCancelled: { true })
            XCTFail("a cancelled status read must throw CancellationError")
        } catch is CancellationError {
            // expected: settled, no verdict cached
        }

        // The next uncancelled read reports the REAL current verdict.
        let status = await service.status(id: imageID)
        XCTAssertEqual(status.verificationIssue, .digestMismatch(role: "disk"),
                       "a cancelled read must cache nothing; the real verdict survives")
    }

    // MARK: - Fixtures

    /// Writes a small, fully-verifiable image into `<imagesRoot>/<id>`:
    /// manifest plus bios/kernel/disk artifacts with matching digest records.
    @discardableResult
    private func makeInstalledImage(id: String, in imagesRoot: URL) throws -> URL {
        let imageDir = imagesRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        let bios = Data("first-use-bbl".utf8)
        let kernel = Data("first-use-kernel".utf8)
        var disk = Data(count: 16 * 1024)
        for index in stride(from: 0, to: 4096, by: 1) { disk[index] = UInt8(index % 199) }

        try bios.write(to: imageDir.appendingPathComponent("bbl64.bin"))
        try kernel.write(to: imageDir.appendingPathComponent("kernel-riscv64.bin"))
        try disk.write(to: imageDir.appendingPathComponent("disk.img"))

        let image = LinuxGuestImage(
            id: id,
            biosPath: "bbl64.bin",
            kernelPath: "kernel-riscv64.bin",
            diskPath: "disk.img",
            diskReadWrite: true,
            cmdline: "console=hvc0",
            qualified: true,
            qualificationEvidence: "first-use fixture",
            qualificationRun: "run-first-use-fixture",
            artifacts: [
                .init(role: .bios, path: "bbl64.bin",
                      sha512: try FloeDigest.sha512Hex(ofFileAt: imageDir.appendingPathComponent("bbl64.bin")),
                      bytes: Int64(bios.count)),
                .init(role: .kernel, path: "kernel-riscv64.bin",
                      sha512: try FloeDigest.sha512Hex(ofFileAt: imageDir.appendingPathComponent("kernel-riscv64.bin")),
                      bytes: Int64(kernel.count)),
                .init(role: .disk, path: "disk.img",
                      sha512: try FloeDigest.sha512Hex(ofFileAt: imageDir.appendingPathComponent("disk.img")),
                      bytes: Int64(disk.count))
            ]
        )
        try JSONEncoder().encode(image).write(
            to: imageDir.appendingPathComponent("manifest.json"), options: .atomic
        )
        return imageDir
    }

    /// Records one async result so a test can assert completion BEFORE
    /// unblocking a parked seam — the no-spinner cancellation evidence.
    /// `didSet` distinguishes "never set" from a legitimately nil result.
    private actor ResultBox<T: Sendable> {
        private var stored: T?
        private var didSet = false

        func set(_ value: T?) {
            stored = value
            didSet = true
        }

        var current: T? { stored }

        func waitForValue(timeoutSeconds: UInt64) async -> Bool {
            let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
            while !didSet {
                if Date() >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }
    }
}

/// Parkable preparation seam: `enterAndWait` records one pass and parks until
/// released (simulating an unbounded multi-gigabyte recovery), so a test can
/// prove a second caller joins instead of duplicating the pass and that a
/// cancelled caller's wait resolves before the pass finishes. `failFirst`
/// makes the first pass throw (retry contract).
private actor PreparationGate {
    private(set) var entries = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private let parks: Bool
    private let failFirst: Bool

    init(parks: Bool, failFirst: Bool) {
        self.parks = parks
        self.failFirst = failFirst
    }

    var isParked: Bool { !released }

    func enterAndWait() async {
        entries += 1
        guard parks, !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func enterAndWaitThrowing() async throws {
        entries += 1
        if parks, !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        if failFirst, entries == 1 {
            throw RuntimeV2Error.imageNotFound("injected first-pass failure")
        }
    }

    func waitUntilEntered(expected: Int) async {
        while entries < expected {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func releaseAll() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Ordered stage recorder for the preparation stage handler. The handler
/// sink is synchronous, so the recorder is lock-based (an actor hop could
/// reorder stage observations). `Mutex` is used because `NSLock`'s manual
/// lock/unlock is unavailable from async contexts.
private final class StageRecorder: Sendable {
    private let lock = Mutex<[RuntimeV2Store.RecoveryStage]>([])

    func record(_ stage: RuntimeV2Store.RecoveryStage) {
        lock.withLock { $0.append(stage) }
    }

    private func snapshot() -> [RuntimeV2Store.RecoveryStage] {
        lock.withLock { $0 }
    }

    /// Stages forward through a Task hop, so wait until every stage (or the
    /// expected count) has been recorded, with a bounded spin.
    func waitForStages(count: Int) async -> [RuntimeV2Store.RecoveryStage] {
        let deadline = Date().addingTimeInterval(5)
        while true {
            let stages = snapshot()
            if stages.count >= count || Date() >= deadline { return stages }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
