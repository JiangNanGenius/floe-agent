// FloeExecutionTests — Build 238 stop-capture recovery regression.
//
// A stop whose delta capture hits a TYPED, known-transient file access fault
// (the class the errno-12 device hash failure belonged to) is retried a
// bounded number of times before the working disk is quarantined; every
// permanent or untyped failure still fails closed on the first attempt. These
// tests exercise the production stores directly (no scripted proxies):
//   * EBUSY-class faults are absorbed by the bounded retry and the stop
//     captures cleanly — no quarantine, no repairRequired;
// * an unrecoverable transient fault exhausts exactly the bounded attempt
//     count, then preserves the complete disk quarantine and marks the
//     environment repairRequired (the recoverable state the verified
//     `restoreRepair` entry resolves);
//   * a non-transient fault (EACCES) is never retried;
//   * provenance/structural errors are never classified transient.

import Foundation
import XCTest
import Darwin
import FloeCore
@testable import FloeExecution

final class RuntimeV2CaptureRetryTests: XCTestCase {
    private var root: URL!
    private var layout: RuntimeV2Layout!
    private var store: RuntimeV2Store!

    private let baseImageID = "base-image"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-v2-capture-retry-\(UUID().uuidString)", isDirectory: true)
        layout = RuntimeV2Layout(root: root)
        store = RuntimeV2Store(layout: layout)
    }

    override func tearDown() async throws {
        store = nil
        layout = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - fixtures (mirrors RuntimeV2TemplateTests' base-image harness)

    @discardableResult
    private func makeVerifiedBaseImage(
        imageID: String, rootfsSeed: UInt8 = 17, rootfsBytes: Int = 3 << 20
    ) async throws -> RuntimeV2ImageStore.Manifest {
        let legacyRoot = root.appendingPathComponent("legacy-\(imageID)", isDirectory: true)
        let directory = legacyRoot.appendingPathComponent(imageID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bios = Data(count: 4096)
        for index in bios.indices { bios[index] = UInt8((index &* 31) % 251) }
        var rootfs = Data(count: rootfsBytes)
        for index in rootfs.indices { rootfs[index] = UInt8((index &* Int(rootfsSeed)) % 253) }
        try bios.write(to: directory.appendingPathComponent("bios.bin"))
        try rootfs.write(to: directory.appendingPathComponent("rootfs.img"))
        let image = LinuxGuestImage(
            id: imageID,
            biosPath: "bios.bin",
            diskPath: "rootfs.img",
            qualified: true,
            qualificationRun: "runtime-v2-capture-retry-tests",
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: "bios.bin",
                    sha512: FloeDigest.sha512Hex(bios), bytes: Int64(bios.count)
                ),
                LinuxGuestImageArtifact(
                    role: .disk, path: "rootfs.img",
                    sha512: FloeDigest.sha512Hex(rootfs), bytes: Int64(rootfs.count)
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(image).write(to: directory.appendingPathComponent("manifest.json"))
        _ = try await store.images.migrateLegacyImage(imageID: imageID, legacyImagesRoot: legacyRoot)
        guard let manifest = try await store.images.manifest(imageID: imageID) else {
            throw RuntimeV2Error.imageNotFound(imageID)
        }
        return manifest
    }

    private func registerEnvironment(_ id: String, rootfsDigest: String) async throws {
        let now = Date()
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: id, kind: "linuxVM", ownerID: nil, name: id,
                baseImageID: baseImageID, baseRootfsDigest: rootfsDigest,
                state: "stopped", dataPath: "environments/\(id)/data", compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
    }

    /// Boots a base-image environment (no template pin) and writes a private
    /// marker block the capture must preserve.
    private func bootEnvironment(
        environmentID: String, runtimeID: String, markerOffset: Int64, marker: Data
    ) async throws {
        let integrator = RuntimeV2GuestIntegrator(store: store, build: "test")
        _ = try await integrator.acquireSlot(
            environmentID: environmentID, runtimeID: runtimeID, requestedMB: 512
        )
        let work = try await integrator.prepareWorkingDisk(
            environmentID: environmentID, runtimeID: runtimeID, imageID: baseImageID,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        let handle = try FileHandle(forWritingTo: work.diskURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(markerOffset))
        try handle.write(contentsOf: marker)
        try handle.synchronize()
    }

    private func writeProbe(
        faultCount: Int, errno code: Int32
    ) -> (probe: @Sendable (URL) throws -> Void, count: () -> Int, faults: () -> Int) {
        let box = ProbeBox(remaining: faultCount, errno: code)
        return (
            { url in
                try box.throwIfFaulting(url: url)
            },
            { box.count },
            { box.faults }
        )
    }

    /// A transient fault that clears after `faultCount` block reads.
    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private let code: Int32
        private(set) var count = 0
        private(set) var faults = 0

        init(remaining: Int, errno: Int32) {
            self.remaining = remaining
            self.code = errno
        }

        func throwIfFaulting(url: URL) throws {
            lock.lock()
            count += 1
            if remaining > 0 {
                remaining -= 1
                faults += 1
                lock.unlock()
                throw FloeFileIOError(
                    stage: .read,
                    posixErrno: code,
                    detail: String(cString: strerror(code)),
                    domain: NSPOSIXErrorDomain,
                    code: Int(code)
                )
            }
            lock.unlock()
        }
    }

    private func quarantinedEntries(prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix(prefix) }
    }

    // MARK: - classification

    func testTransientCaptureIOClassification() {
        XCTAssertTrue(
            RuntimeV2GuestIntegrator.isTransientCaptureIO(
                FloeFileIOError(stage: .read, posixErrno: EBUSY, detail: "busy")
            )
        )
        XCTAssertTrue(
            RuntimeV2GuestIntegrator.isTransientCaptureIO(
                FloeFileIOError(stage: .open, posixErrno: ENOMEM, detail: "nomem")
            )
        )
        XCTAssertFalse(
            RuntimeV2GuestIntegrator.isTransientCaptureIO(
                FloeFileIOError(stage: .open, posixErrno: EACCES, detail: "denied")
            ),
            "a permanent permission denial must not be retried"
        )
        XCTAssertFalse(
            RuntimeV2GuestIntegrator.isTransientCaptureIO(
                RuntimeV2Error.deltaBaseConflict(environmentID: "e", recorded: "a", verified: "b")
            ),
            "a provenance conflict fails closed on the first attempt"
        )
        XCTAssertFalse(
            RuntimeV2GuestIntegrator.isTransientCaptureIO(
                NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
            ),
            "an untyped error is never retried"
        )
    }

    // MARK: - bounded retry

    /// Two transient faults, then the capture succeeds: the stop is clean, no
    /// quarantine exists, the marker block is in the delta and the lease is
    /// released.
    func testTransientWorkingDiskFaultIsRetriedAndCaptures() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        guard let ref = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"] else {
            throw RuntimeV2Error.imageNotFound(baseImageID)
        }
        try await registerEnvironment("env-retry", rootfsDigest: ref.sha512.lowercased())
        try await bootEnvironment(
            environmentID: "env-retry", runtimeID: "rt-retry",
            markerOffset: 2 << 20, marker: Data(repeating: 0x7B, count: 4096)
        )

        let (probe, count, faults) = writeProbe(faultCount: 2, errno: EBUSY)
        let deltas = await store.deltas
        await deltas.installWorkingDiskReadProbe(probe)
        let integrator = RuntimeV2GuestIntegrator(
            store: store, build: "test",
            seams: RuntimeV2GuestIntegrator.Seams(captureRetryDelay: { _ in })
        )
        let outcome = await integrator.completeStopResult(
            environmentID: "env-retry", runtimeID: "rt-retry", imageID: baseImageID, clean: true
        )
        guard case .captured(let generation) = outcome else {
            XCTFail("transient faults must be absorbed by the bounded retry, got \(outcome)")
            return
        }
        XCTAssertEqual(faults(), 2, "each fault aborted one capture attempt at its first read")
        XCTAssertGreaterThanOrEqual(count(), 3, "the final attempt read every allocated block")
        XCTAssertGreaterThan(generation, 0)
        XCTAssertEqual(try quarantinedEntries(prefix: "runtime-vm-rt-retry").count, 0,
                       "a retried-then-clean capture never quarantines the disk")

        let delta = try await store.deltas.loadDelta(environmentID: "env-retry")
        XCTAssertGreaterThan(delta?.presentBlocks ?? 0, 0)
        let state = try await store.registry.environment(id: "env-retry")?.state
        XCTAssertEqual(state, "stopped")
        let lease = try await store.leases.holder(environmentID: "env-retry")
        XCTAssertNil(lease)
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-retry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        // The captured delta replays the private marker block (materialize
        // against the base and read it back).
        let runtimeID = "rt-retry-replay"
        let replay = RuntimeV2GuestIntegrator(store: store, build: "test")
        _ = try await replay.acquireSlot(
            environmentID: "env-retry", runtimeID: runtimeID, requestedMB: 512
        )
        let work = try await replay.prepareWorkingDisk(
            environmentID: "env-retry", runtimeID: runtimeID, imageID: baseImageID,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        let handle = try FileHandle(forReadingFrom: work.diskURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(2 << 20))
        XCTAssertEqual(try handle.read(upToCount: 4096), Data(repeating: 0x7B, count: 4096))
    }

    /// An unrecoverable transient fault exhausts EXACTLY the bounded attempt
    /// count, then preserves the complete disk and marks repairRequired — the
    /// state the verified repair entry resolves.
    func testPersistentTransientFaultExhaustsBoundedRetriesAndPreserves() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        guard let ref = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"] else {
            throw RuntimeV2Error.imageNotFound(baseImageID)
        }
        try await registerEnvironment("env-stuck", rootfsDigest: ref.sha512.lowercased())
        try await bootEnvironment(
            environmentID: "env-stuck", runtimeID: "rt-stuck",
            markerOffset: 2 << 20, marker: Data(repeating: 0x8C, count: 4096)
        )

        let (probe, count, _) = writeProbe(faultCount: Int.max, errno: EBUSY)
        let deltas = await store.deltas
        await deltas.installWorkingDiskReadProbe(probe)
        let integrator = RuntimeV2GuestIntegrator(
            store: store, build: "test",
            seams: RuntimeV2GuestIntegrator.Seams(captureRetryDelay: { _ in })
        )
        let outcome = await integrator.completeStopResult(
            environmentID: "env-stuck", runtimeID: "rt-stuck", imageID: baseImageID, clean: true
        )
        guard case .retainedForRepair(let reason) = outcome else {
            XCTFail("an unrecoverable fault must retain the disk for repair, got \(outcome)")
            return
        }
        XCTAssertEqual(count(), RuntimeV2GuestIntegrator.captureAttempts,
                       "the retry budget is bounded, never unbounded")
        XCTAssertTrue(reason.contains("preserved"))

        // The complete disk (including the private block) is quarantined.
        let quarantined = try quarantinedEntries(prefix: "runtime-vm-rt-stuck")
        XCTAssertEqual(quarantined.count, 1)
        let preservedDisk = layout.quarantineDirectory
            .appendingPathComponent(quarantined[0], isDirectory: true)
            .appendingPathComponent("disk.img")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedDisk.path))
        let handle = try FileHandle(forReadingFrom: preservedDisk)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(2 << 20))
        XCTAssertEqual(try handle.read(upToCount: 4096), Data(repeating: 0x8C, count: 4096))

        // Durable failure state, then the lease released.
        let state = try await store.registry.environment(id: "env-stuck")?.state
        XCTAssertEqual(state, "repairRequired")
        let shutdown = try await store.deltas.lastShutdown(environmentID: "env-stuck")
        XCTAssertEqual(shutdown?.clean, false)
        XCTAssertTrue(shutdown?.detail?.contains("preserved") == true)
        let lease = try await store.leases.holder(environmentID: "env-stuck")
        XCTAssertNil(lease)

        // The verified repair entry resolves the preserved state: provenance +
        // content verification, capture into the delta, exclusion lifted. The
        // transient condition has cleared, so the fault probe comes out first.
        await deltas.installWorkingDiskReadProbe(nil)
        let repair = try await store.restoreRepair(environmentID: "env-stuck")
        XCTAssertEqual(repair.resolution, "restored")
        XCTAssertEqual(repair.preservedPath, "recovery/quarantine/\(quarantined[0])")
        XCTAssertNotNil(repair.diskDigestSHA512)
        XCTAssertGreaterThan(repair.restoredGeneration ?? 0, 0)
        let repairedState = try await store.registry.environment(id: "env-stuck")?.state
        XCTAssertEqual(repairedState, "stopped")
        let hold = await store.repairHoldStatus(environmentID: "env-stuck")
        XCTAssertNil(hold)
        let repairedDelta = try await store.deltas.loadDelta(environmentID: "env-stuck")
        XCTAssertGreaterThan(repairedDelta?.presentBlocks ?? 0, 0)
    }

    /// A permanent fault is never retried: one attempt, immediate preserve.
    func testNonTransientFaultDoesNotRetry() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        guard let ref = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"] else {
            throw RuntimeV2Error.imageNotFound(baseImageID)
        }
        try await registerEnvironment("env-denied", rootfsDigest: ref.sha512.lowercased())
        try await bootEnvironment(
            environmentID: "env-denied", runtimeID: "rt-denied",
            markerOffset: 1 << 20, marker: Data(repeating: 0x9D, count: 4096)
        )

        let (probe, count, _) = writeProbe(faultCount: Int.max, errno: EACCES)
        let deltas = await store.deltas
        await deltas.installWorkingDiskReadProbe(probe)
        let integrator = RuntimeV2GuestIntegrator(
            store: store, build: "test",
            seams: RuntimeV2GuestIntegrator.Seams(captureRetryDelay: { _ in })
        )
        let outcome = await integrator.completeStopResult(
            environmentID: "env-denied", runtimeID: "rt-denied", imageID: baseImageID, clean: true
        )
        guard case .retainedForRepair = outcome else {
            XCTFail("a permanent fault must retain the disk, got \(outcome)")
            return
        }
        XCTAssertEqual(count(), 1, "a non-transient fault fails closed on the first attempt")
        XCTAssertEqual(try quarantinedEntries(prefix: "runtime-vm-rt-denied").count, 1)
    }
}
