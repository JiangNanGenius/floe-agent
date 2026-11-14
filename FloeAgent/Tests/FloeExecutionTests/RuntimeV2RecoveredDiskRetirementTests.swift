// FloeExecutionTests — direct obsolete-RISC-V runtime disposal.
//
// These tests pin the superseding product instruction: verified old RISC-V
// test disks, their deltas and their discarded evidence are deleted directly
// and losslessly for the retired architecture (no copy/archive/restore/full
// digest), while ARM64/unknown ownership is never touched. Every test uses the
// production RuntimeV2Store entry points and real filesystem objects; the only
// injected behavior is a deterministic interruption seam.

import Foundation
import XCTest
import FloeCore
@testable import FloeExecution

final class RuntimeV2RecoveredDiskRetirementTests: XCTestCase {
    private var root: URL!
    private var layout: RuntimeV2Layout!
    private var store: RuntimeV2Store!
    private var workspaceSentinel: URL!

    private let riscvImageID = "floe-debian13-riscv64-retirement-test-1"
    private let arm64ImageID = "floe-debian13-arm64-retirement-test-1"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-v2-recovered-retirement-\(UUID().uuidString)", isDirectory: true)
        layout = RuntimeV2Layout(root: root)
        store = RuntimeV2Store(layout: layout)
        _ = try await store.prepareAndRecover(build: "test")
        workspaceSentinel = layout.ownedWorkspacesDirectory.appendingPathComponent("sentinel.txt")
        try "workspace".write(to: workspaceSentinel, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        store = nil
        layout = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - exact direct disposal + hold retirement + no disk read

    func testDisposesVerifiedRISCVDiskWithoutReadingItAndRetiresOnlyMatchingHold() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-riscv-disk", imageID: riscvImageID, rootfsDigest: base.digest
        )
        let fixture = try await makeQuarantineEntry(
            environmentID: "env-riscv-disk", runtimeID: "rt-riscv-disk",
            imageID: riscvImageID, bootBaseDigest: base.digest, placeHold: true
        )

        // A 000-mode disk cannot be opened for reading. Disposal must still
        // work (lstat + rename + unlink only) and must not compute a digest.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: fixture.diskURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fixture.diskURL.path
            )
        }

        let scan = await store.scanObsoleteRISCVRuntime()
        let candidateID = "disk:recovery/quarantine/\(fixture.entry)"
        let candidate = try XCTUnwrap(scan.candidates.first { $0.id == candidateID })
        XCTAssertEqual(candidate.state, .eligible)
        XCTAssertEqual(candidate.kind, .workingDisk)
        XCTAssertEqual(candidate.environmentID, "env-riscv-disk")
        XCTAssertNotNil(candidate.allocatedBytes)

        let result = await store.disposeObsoleteRISCVRuntime(candidateID: candidateID)
        XCTAssertEqual(result.outcome, .disposed)
        XCTAssertEqual(result.environmentID, "env-riscv-disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.diskURL.path))

        let hold = await store.repairHolds.hold(environmentID: "env-riscv-disk")
        XCTAssertNil(hold)
        let state = try await store.registry.environment(id: "env-riscv-disk")?.state
        XCTAssertEqual(state, "stopped")

        let records = await store.obsoleteRISCVRuntimeDisposalRecords()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.phase, .done)
        XCTAssertEqual(record.kind, .workingDisk)
        XCTAssertEqual(record.removedLogicalBytes, 8 << 20)
        XCTAssertEqual(record.resolutionNote, "holdRetired")
        XCTAssertNil(record.deltaFiles)
        // No durable alternative was created for the retired architecture.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.recoveryDirectory.appendingPathComponent("retired-disks").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.recoveryDirectory.appendingPathComponent("retired-chunks").path
        ))
        #if canImport(Darwin)
        // The transient staging target can hold a full disk for a moment; it
        // must never become a cloud-backup copy.
        let stagingRoot = layout.recoveryDirectory
            .appendingPathComponent("obsolete-riscv-staging", isDirectory: true)
        if FileManager.default.fileExists(atPath: stagingRoot.path) {
            let values = try stagingRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
        }
        #endif

        // Host workspace and environment `data/` were never traversed.
        XCTAssertEqual(try String(contentsOf: workspaceSentinel, encoding: .utf8), "workspace")
        let dataFile = try layout.environmentDataDirectory(environmentID: "env-riscv-disk")
            .appendingPathComponent("user.txt")
        XCTAssertEqual(try String(contentsOf: dataFile, encoding: .utf8), "keep")

        // Idempotent repeat: the exact same candidate is not re-read/deleted.
        let second = await store.disposeObsoleteRISCVRuntime(candidateID: candidateID)
        XCTAssertEqual(second.outcome, .alreadyDisposed)
        let recordsAfterSecond = await store.obsoleteRISCVRuntimeDisposalRecords()
        XCTAssertEqual(recordsAfterSecond.count, 1)
    }

    // MARK: - interruption after staging, resume without re-reading

    func testInterruptedAfterStagingResumesAndActuallyUnlinks() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-riscv-resume", imageID: riscvImageID, rootfsDigest: base.digest
        )
        let fixture = try await makeQuarantineEntry(
            environmentID: "env-riscv-resume", runtimeID: "rt-riscv-resume",
            imageID: riscvImageID, bootBaseDigest: base.digest, placeHold: true
        )

        let service = RuntimeV2RecoveredDiskRetirement(
            store: store,
            seams: .init(afterStage: { _ in throw TestFault.interrupted })
        )
        let candidateID = "disk:recovery/quarantine/\(fixture.entry)"
        let first = await service.dispose(candidateID: candidateID)
        XCTAssertEqual(first.outcome, .interrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        let stagingRoot = layout.recoveryDirectory.appendingPathComponent("obsolete-riscv-staging")
        let staged = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
        XCTAssertEqual(staged.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stagingRoot.appendingPathComponent(staged[0]).appendingPathComponent("disk.img").path
        ))
        let interruptedHold = await store.repairHolds.hold(environmentID: "env-riscv-resume")
        XCTAssertNotNil(interruptedHold)
        let interruptedRecords = await store.obsoleteRISCVRuntimeDisposalRecords()
        XCTAssertEqual(interruptedRecords.first?.phase, .staged)

        let resumed = await store.resumeObsoleteRISCVRuntimeDisposals()
        XCTAssertEqual(resumed.disposedCount, 1)
        let stagingAfterResume = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
        XCTAssertTrue(stagingAfterResume.isEmpty)
        let resumedHold = await store.repairHolds.hold(environmentID: "env-riscv-resume")
        XCTAssertNil(resumedHold)
        let doneRecords = await store.obsoleteRISCVRuntimeDisposalRecords()
        XCTAssertEqual(doneRecords.first?.phase, .done)
    }

    // MARK: - active / unknown / ARM64 are never touched

    func testActiveUnknownAndARM64ContentIsNeverDeleted() async throws {
        let riscv = try await makeVerifiedBaseImage(imageID: riscvImageID)
        let arm = try await makeVerifiedBaseImage(imageID: arm64ImageID)

        try await registerEnvironment(
            id: "env-active-riscv", imageID: riscvImageID, rootfsDigest: riscv.digest
        )
        let heldLease = try await store.leases.acquire(
            environmentID: "env-active-riscv", runtimeID: "rt-active-riscv",
            staleProof: { _ in false }
        )
        let activeFixture = try await makeQuarantineEntry(
            environmentID: "env-active-riscv", runtimeID: "rt-active-riscv",
            imageID: riscvImageID, bootBaseDigest: riscv.digest, placeHold: false
        )

        try await registerEnvironment(
            id: "env-unknown", imageID: riscvImageID, rootfsDigest: riscv.digest
        )
        let unknownFixture = try await makeQuarantineEntry(
            environmentID: "env-unknown", runtimeID: "rt-unknown",
            imageID: riscvImageID, bootBaseDigest: riscv.digest, placeHold: false,
            includeRuntimeMetadata: false
        )

        try await registerEnvironment(
            id: "env-arm64", imageID: arm64ImageID, rootfsDigest: arm.digest
        )
        let armFixture = try await makeQuarantineEntry(
            environmentID: "env-arm64", runtimeID: "rt-arm64",
            imageID: arm64ImageID, bootBaseDigest: arm.digest, placeHold: false
        )

        let scan = await store.scanObsoleteRISCVRuntime()
        let activeCandidate = try XCTUnwrap(scan.candidates.first {
            $0.id == "disk:recovery/quarantine/\(activeFixture.entry)"
        })
        XCTAssertEqual(activeCandidate.state, .blocked)
        XCTAssertEqual(activeCandidate.reasonCode, "liveLease")
        let activeResult = await store.disposeObsoleteRISCVRuntime(candidateID: activeCandidate.id)
        XCTAssertEqual(activeResult.outcome, .blocked)
        XCTAssertEqual(activeResult.reasonCode, "liveLease")
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeFixture.diskURL.path))

        let unknownCandidate = try XCTUnwrap(scan.candidates.first {
            $0.id == "disk:recovery/quarantine/\(unknownFixture.entry)"
        })
        XCTAssertEqual(unknownCandidate.state, .blocked)
        XCTAssertEqual(unknownCandidate.reasonCode, "unknownOwnership")
        let unknownResult = await store.disposeObsoleteRISCVRuntime(candidateID: unknownCandidate.id)
        XCTAssertEqual(unknownResult.outcome, .blocked)
        XCTAssertEqual(unknownResult.reasonCode, "unknownOwnership")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownFixture.diskURL.path))

        let armCandidate = try XCTUnwrap(scan.candidates.first {
            $0.id == "disk:recovery/quarantine/\(armFixture.entry)"
        })
        XCTAssertEqual(armCandidate.state, .preservationRequired)
        XCTAssertEqual(armCandidate.reasonCode, "notRiscV")
        let armResult = await store.disposeObsoleteRISCVRuntime(candidateID: armCandidate.id)
        XCTAssertEqual(armResult.outcome, .preservationRequired)
        XCTAssertEqual(armResult.reasonCode, "notRiscV")
        XCTAssertTrue(FileManager.default.fileExists(atPath: armFixture.diskURL.path))
        let armData = try layout.environmentDataDirectory(environmentID: "env-arm64")
            .appendingPathComponent("user.txt")
        XCTAssertEqual(try String(contentsOf: armData, encoding: .utf8), "keep")

        await heldLease.release()
    }

    // MARK: - delta disposal, header-first interruption, data/runner preserved

    func testDisposesRISCVEenvironmentDeltaHeaderFirstAndPreservesDataAndRunner() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-riscv-delta", imageID: riscvImageID, rootfsDigest: base.digest
        )
        try await makeDelta(
            environmentID: "env-riscv-delta", imageID: riscvImageID,
            rootfs: base.rootfs, digest: base.digest
        )
        let system = try layout.environmentSystemDirectory(environmentID: "env-riscv-delta")
        let deltaBefore = try await store.deltas.loadDelta(environmentID: "env-riscv-delta")
        XCTAssertNotNil(deltaBefore)

        let scan = await store.scanObsoleteRISCVRuntime()
        let candidateID = "delta:env-riscv-delta"
        let candidate = try XCTUnwrap(scan.candidates.first { $0.id == candidateID })
        XCTAssertEqual(candidate.state, .eligible)
        XCTAssertEqual(candidate.kind, .environmentDelta)

        let result = await store.disposeObsoleteRISCVRuntime(candidateID: candidateID)
        XCTAssertEqual(result.outcome, .disposed)
        for name in RuntimeV2DeltaStore.obsoleteDisposalFileNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: system.appendingPathComponent(name).path))
        }
        let after = try await store.deltas.loadDelta(environmentID: "env-riscv-delta")
        XCTAssertNil(after)
        XCTAssertEqual(
            try String(contentsOf: system.appendingPathComponent("runner.json"), encoding: .utf8),
            "runner"
        )
        let dataFile = try layout.environmentDataDirectory(environmentID: "env-riscv-delta")
            .appendingPathComponent("user.txt")
        XCTAssertEqual(try String(contentsOf: dataFile, encoding: .utf8), "keep")
        let records = await store.obsoleteRISCVRuntimeDisposalRecords()
        let record = records.first { $0.candidateID == candidateID }
        XCTAssertEqual(record?.phase, .done)
    }

    func testInterruptedDeltaAfterHeaderStageStaysPristineAndResumes() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-riscv-delta-resume", imageID: riscvImageID, rootfsDigest: base.digest
        )
        try await makeDelta(
            environmentID: "env-riscv-delta-resume", imageID: riscvImageID,
            rootfs: base.rootfs, digest: base.digest
        )
        let system = try layout.environmentSystemDirectory(environmentID: "env-riscv-delta-resume")
        let service = RuntimeV2RecoveredDiskRetirement(
            store: store,
            seams: .init(afterDeltaHeaderStage: { _ in throw TestFault.interrupted })
        )
        let candidateID = "delta:env-riscv-delta-resume"
        let first = await service.dispose(candidateID: candidateID)
        XCTAssertEqual(first.outcome, .interrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: system.appendingPathComponent("delta.header").path))
        // No header means the environment is pristine; loadDelta must not
        // quarantine the remaining files or invent a partial delta.
        let partial = try await store.deltas.loadDelta(environmentID: "env-riscv-delta-resume")
        XCTAssertNil(partial)

        let resumed = await store.resumeObsoleteRISCVRuntimeDisposals()
        XCTAssertEqual(resumed.disposedCount, 1)
        for name in RuntimeV2DeltaStore.obsoleteDisposalFileNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: system.appendingPathComponent(name).path))
        }
        XCTAssertEqual(
            try String(contentsOf: system.appendingPathComponent("runner.json"), encoding: .utf8),
            "runner"
        )
    }

    func testARM64DeltaIsPreservedForTheExistingUpgradePath() async throws {
        let base = try await makeVerifiedBaseImage(imageID: arm64ImageID)
        try await registerEnvironment(
            id: "env-arm64-delta", imageID: arm64ImageID, rootfsDigest: base.digest
        )
        try await makeDelta(
            environmentID: "env-arm64-delta", imageID: arm64ImageID,
            rootfs: base.rootfs, digest: base.digest
        )
        let before = try await store.deltas.loadDelta(environmentID: "env-arm64-delta")
        XCTAssertNotNil(before)

        let scan = await store.scanObsoleteRISCVRuntime()
        XCTAssertFalse(scan.candidates.contains { $0.id == "delta:env-arm64-delta" })
        let result = await store.disposeObsoleteRISCVRuntime(candidateID: "delta:env-arm64-delta")
        XCTAssertEqual(result.outcome, .preservationRequired)
        XCTAssertEqual(result.reasonCode, "notRiscV")

        let after = try await store.deltas.loadDelta(environmentID: "env-arm64-delta")
        XCTAssertEqual(after?.header.generation, before?.header.generation)
        XCTAssertEqual(after?.presentBlocks, before?.presentBlocks)
        let dataFile = try layout.environmentDataDirectory(environmentID: "env-arm64-delta")
            .appendingPathComponent("user.txt")
        XCTAssertEqual(try String(contentsOf: dataFile, encoding: .utf8), "keep")
    }

    // MARK: - discarded rollback evidence only for RISC-V metadata

    func testDiscardedEvidenceIsDisposedOnlyForVerifiedRISCVMetadata() async throws {
        let riscv = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-riscv-discarded", imageID: riscvImageID, rootfsDigest: riscv.digest
        )
        let riscvEntry = try await makeDiscardedEntry(
            environmentID: "env-riscv-discarded", runtimeID: "rt-riscv-discarded",
            imageID: riscvImageID, bootBaseDigest: riscv.digest
        )

        let arm = try await makeVerifiedBaseImage(imageID: arm64ImageID)
        try await registerEnvironment(
            id: "env-arm64-discarded", imageID: arm64ImageID, rootfsDigest: arm.digest
        )
        let armEntry = try await makeDiscardedEntry(
            environmentID: "env-arm64-discarded", runtimeID: "rt-arm64-discarded",
            imageID: arm64ImageID, bootBaseDigest: arm.digest
        )

        let scan = await store.scanObsoleteRISCVRuntime()
        let riscvCandidateID = "discarded:recovery/migrations/discarded/\(riscvEntry.entry)"
        XCTAssertTrue(scan.candidates.contains { $0.id == riscvCandidateID && $0.state == .eligible })
        let result = await store.disposeObsoleteRISCVRuntime(candidateID: riscvCandidateID)
        XCTAssertEqual(result.outcome, .disposed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: riscvEntry.directory.path))

        let armCandidateID = "discarded:recovery/migrations/discarded/\(armEntry.entry)"
        let armResult = await store.disposeObsoleteRISCVRuntime(candidateID: armCandidateID)
        XCTAssertEqual(armResult.outcome, .preservationRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: armEntry.directory.path))
    }

    // MARK: - repeated versions use distinct records; cancellation stops first

    func testRepeatedDiskVersionsCreateDistinctDoneRecords() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-riscv-versions", imageID: riscvImageID, rootfsDigest: base.digest
        )
        let first = try await makeQuarantineEntry(
            environmentID: "env-riscv-versions", runtimeID: "rt-riscv-versions",
            imageID: riscvImageID, bootBaseDigest: base.digest, placeHold: false,
            entryName: "runtime-vm-rt-riscv-versions-\(UUID().uuidString.lowercased())"
        )
        let firstID = "disk:recovery/quarantine/\(first.entry)"
        let firstResult = await store.disposeObsoleteRISCVRuntime(candidateID: firstID)
        XCTAssertEqual(firstResult.outcome, .disposed)

        // Recreate the same relative path with different bytes/identity.
        let second = try await makeQuarantineEntry(
            environmentID: "env-riscv-versions", runtimeID: "rt-riscv-versions",
            imageID: riscvImageID, bootBaseDigest: base.digest, placeHold: false,
            entryName: first.entry, markerByte: 0x7E
        )
        let secondResult = await store.disposeObsoleteRISCVRuntime(candidateID: firstID)
        XCTAssertEqual(secondResult.outcome, .disposed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.directory.path))
        let records = await store.obsoleteRISCVRuntimeDisposalRecords()
            .filter { $0.candidateID == firstID }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.phase == .done })
        XCTAssertEqual(Set(records.map(\.recordID)).count, 2)
    }

    func testCancelledCallDoesNotStartASecondDeletion() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-riscv-cancel", imageID: riscvImageID, rootfsDigest: base.digest
        )
        let fixture = try await makeQuarantineEntry(
            environmentID: "env-riscv-cancel", runtimeID: "rt-riscv-cancel",
            imageID: riscvImageID, bootBaseDigest: base.digest, placeHold: false
        )
        let candidateID = "disk:recovery/quarantine/\(fixture.entry)"
        let cancellationStore = store!
        let cancellationCandidateID = candidateID
        let task = Task { () -> RuntimeV2RecoveredDiskRetirement.DisposalResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await cancellationStore.disposeObsoleteRISCVRuntime(
                candidateID: cancellationCandidateID
            )
        }
        let result = await task.value
        XCTAssertEqual(result.outcome, .interrupted)
        XCTAssertEqual(result.reasonCode, "cancelled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    // MARK: - truthful batch states, historical leases, enumeration failure

    func testBatchDistinguishesRISCVDBlockersFromPreservedARM64() async throws {
        let riscv = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-batch-eligible", imageID: riscvImageID, rootfsDigest: riscv.digest
        )
        let eligible = try await makeQuarantineEntry(
            environmentID: "env-batch-eligible", runtimeID: "rt-batch-eligible",
            imageID: riscvImageID, bootBaseDigest: riscv.digest, placeHold: false
        )
        try await registerEnvironment(
            id: "env-batch-unknown", imageID: riscvImageID, rootfsDigest: riscv.digest
        )
        let unknown = try await makeQuarantineEntry(
            environmentID: "env-batch-unknown", runtimeID: "rt-batch-unknown",
            imageID: riscvImageID, bootBaseDigest: riscv.digest, placeHold: false,
            includeRuntimeMetadata: false
        )
        let arm = try await makeVerifiedBaseImage(imageID: arm64ImageID)
        try await registerEnvironment(
            id: "env-batch-arm64", imageID: arm64ImageID, rootfsDigest: arm.digest
        )
        let armFixture = try await makeQuarantineEntry(
            environmentID: "env-batch-arm64", runtimeID: "rt-batch-arm64",
            imageID: arm64ImageID, bootBaseDigest: arm.digest, placeHold: false
        )

        let batch = await store.disposeEligibleObsoleteRISCVRuntime()
        XCTAssertEqual(batch.disposedCount, 1)
        XCTAssertEqual(batch.blockedCount, 1)
        XCTAssertEqual(batch.preservationRequiredCount, 1)
        XCTAssertFalse(batch.isComplete)
        XCTAssertFalse(batch.scanTruncated)
        XCTAssertTrue(batch.scanNotes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eligible.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: armFixture.directory.path))
    }

    func testARM64PreservationAloneDoesNotMakeBatchIncomplete() async throws {
        let arm = try await makeVerifiedBaseImage(imageID: arm64ImageID)
        try await registerEnvironment(
            id: "env-batch-only-arm64", imageID: arm64ImageID, rootfsDigest: arm.digest
        )
        let armFixture = try await makeQuarantineEntry(
            environmentID: "env-batch-only-arm64", runtimeID: "rt-batch-only-arm64",
            imageID: arm64ImageID, bootBaseDigest: arm.digest, placeHold: false
        )
        let batch = await store.disposeEligibleObsoleteRISCVRuntime()
        XCTAssertEqual(batch.disposedCount, 0)
        XCTAssertEqual(batch.blockedCount, 0)
        XCTAssertEqual(batch.preservationRequiredCount, 1)
        XCTAssertTrue(batch.isComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: armFixture.directory.path))
    }

    func testHistoricalExpiredLeaseDoesNotBlockRISCVDiskDisposal() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-historical-lease", imageID: riscvImageID, rootfsDigest: base.digest
        )
        let fixture = try await makeQuarantineEntry(
            environmentID: "env-historical-lease", runtimeID: "rt-historical-lease",
            imageID: riscvImageID, bootBaseDigest: base.digest, placeHold: false
        )
        try await writeHistoricalExpiredLease(
            environmentID: "env-historical-lease", runtimeID: "rt-historical-lease"
        )

        let scan = await store.scanObsoleteRISCVRuntime()
        let candidate = scan.candidates.first { $0.id == "disk:recovery/quarantine/\(fixture.entry)" }
        XCTAssertEqual(candidate?.state, .eligible)
        let batch = await store.disposeEligibleObsoleteRISCVRuntime()
        XCTAssertEqual(batch.disposedCount, 1)
        XCTAssertEqual(batch.blockedCount, 0)
        XCTAssertTrue(batch.isComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    #if canImport(Darwin)
    func testPIDReusedAfterDeviceBootCannotOwnAnExpiredHistoricalLease() {
        let now = Date()
        let old = Date(timeIntervalSince1970: 86400)
        var lease = RuntimeV2LeaseStore.Lease(
            environmentID: "env", runtimeID: "runtime", incarnation: "previous",
            sessionToken: "session", pid: Int64(ProcessInfo.processInfo.processIdentifier),
            acquiredAt: old, renewedAt: old, ttlSeconds: 30
        )
        XCTAssertFalse(RuntimeV2LeaseStore.blocksRetirement(lease, now: now))
        lease.acquiredAt = now
        lease.renewedAt = now
        XCTAssertTrue(RuntimeV2LeaseStore.blocksRetirement(lease, now: now))
        XCTAssertTrue(RuntimeV2LeaseStore.blocksRetirement(lease, now: now.addingTimeInterval(90)))
    }
    #endif

    func testBatchPropagatesDirectoryEnumerationFailureAndIsIncomplete() async throws {
        try FileManager.default.removeItem(at: layout.quarantineDirectory)
        let scan = await store.scanObsoleteRISCVRuntime()
        XCTAssertTrue(scan.notes.contains("quarantineDirectoryUnavailable"))
        XCTAssertTrue(scan.truncated)
        let batch = await store.disposeEligibleObsoleteRISCVRuntime()
        XCTAssertTrue(batch.scanNotes.contains("quarantineDirectoryUnavailable"))
        XCTAssertTrue(batch.scanTruncated)
        XCTAssertFalse(batch.isComplete)
        XCTAssertTrue(batch.results.isEmpty)
    }

    func testCancelledBatchStartsNoDeletion() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-batch-cancel", imageID: riscvImageID, rootfsDigest: base.digest
        )
        let fixture = try await makeQuarantineEntry(
            environmentID: "env-batch-cancel", runtimeID: "rt-batch-cancel",
            imageID: riscvImageID, bootBaseDigest: base.digest, placeHold: false
        )
        let cancellationStore = store!
        let task = Task { () -> RuntimeV2RecoveredDiskRetirement.BatchReport in
            withUnsafeCurrentTask { $0?.cancel() }
            return await cancellationStore.disposeEligibleObsoleteRISCVRuntime()
        }
        let report = await task.value
        XCTAssertEqual(report.disposedCount, 0)
        XCTAssertTrue(report.scanNotes.contains("cancelled") || report.notes.contains("cancelled"))
        XCTAssertFalse(report.isComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    // MARK: - real census shape: historical active rows, expired held leases

    func testCensusShapeRetiresAllRISCVDeltasAndDisksDespiteHistoricalActiveRows() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        // 44 delta sets: 41 historical active, 2 interrupted, 1 repairRequired.
        for index in 0..<44 {
            let id = "env-census-delta-\(index)"
            try await registerEnvironment(id: id, imageID: riscvImageID, rootfsDigest: base.digest)
            try makeObsoleteDeltaFiles(environmentID: id)
            let state = index < 41 ? "active" : (index < 43 ? "interrupted" : "repairRequired")
            try await store.registry.setEnvironmentState(id: id, state: state)
        }
        // Historic queue rows are cancelled/done/interrupted only; none of
        // those is current ownership.
        try await store.registry.recordQueueEntry(
            RuntimeV2Registry.QueueRow(
                id: "queue-census-cancelled", environmentID: "env-census-delta-0",
                requestedMB: 512, state: "cancelled", enqueuedAt: Date(),
                startedAt: nil, finishedAt: Date()
            )
        )
        // 13 recovered disks. Four carry the census's expired held lease rows;
        // those leases are provably stale (September renewal, 30s TTL, dead
        // pid) and must not block direct disposal.
        for index in 0..<13 {
            let id = "env-census-disk-\(index)"
            try await registerEnvironment(id: id, imageID: riscvImageID, rootfsDigest: base.digest)
            _ = try await makeQuarantineEntry(
                environmentID: id, runtimeID: "rt-census-\(index)",
                imageID: riscvImageID, bootBaseDigest: base.digest, placeHold: false
            )
            if index < 4 {
                try await store.registry.setEnvironmentState(id: id, state: "repairRequired")
                try await writeHistoricalExpiredLease(
                    environmentID: id, runtimeID: "rt-census-\(index)"
                )
            }
        }

        let limits = RuntimeV2RecoveredDiskRetirement.Limits(
            maximumCandidates: 128, maximumDirectoryEntries: 1024
        )
        let scan = await store.scanObsoleteRISCVRuntime(limits: limits)
        XCTAssertEqual(scan.candidates.filter { $0.kind == .environmentDelta }.count, 44)
        XCTAssertEqual(scan.candidates.filter { $0.kind == .workingDisk }.count, 13)
        XCTAssertEqual(scan.blockedCount, 0)
        XCTAssertFalse(scan.truncated)

        let batch = await store.disposeEligibleObsoleteRISCVRuntime(limits: limits)
        XCTAssertEqual(batch.disposedCount, 57)
        XCTAssertEqual(batch.blockedCount, 0)
        XCTAssertEqual(batch.preservationRequiredCount, 0)
        XCTAssertEqual(batch.interruptedCount, 0)
        XCTAssertFalse(batch.scanTruncated)
        XCTAssertTrue(batch.isComplete)
        XCTAssertFalse(batch.shouldContinue)
        let dataFile = try layout.environmentDataDirectory(environmentID: "env-census-disk-3")
            .appendingPathComponent("user.txt")
        XCTAssertEqual(try String(contentsOf: dataFile, encoding: .utf8), "keep")
    }

    func testHistoricalActiveStateWithoutCurrentOwnerIsEligibleForDiskDisposal() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        try await registerEnvironment(
            id: "env-historical-active", imageID: riscvImageID, rootfsDigest: base.digest
        )
        try await store.registry.setEnvironmentState(id: "env-historical-active", state: "active")
        let fixture = try await makeQuarantineEntry(
            environmentID: "env-historical-active", runtimeID: "rt-historical-active",
            imageID: riscvImageID, bootBaseDigest: base.digest, placeHold: false
        )
        let scan = await store.scanObsoleteRISCVRuntime()
        let candidate = scan.candidates.first {
            $0.id == "disk:recovery/quarantine/\(fixture.entry)"
        }
        XCTAssertEqual(candidate?.state, .eligible)
        let result = await store.disposeObsoleteRISCVRuntime(candidateID: candidate?.id ?? "")
        XCTAssertEqual(result.outcome, .disposed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testTruncatedCandidateListStillReachesNewEligibleWorkAndStopsWhenBlockedOnly() async throws {
        let base = try await makeVerifiedBaseImage(imageID: riscvImageID)
        for index in 0..<20 {
            _ = try await makeQuarantineEntry(
                environmentID: "env-cap-unknown-\(index)",
                runtimeID: "rt-cap-unknown-\(index)",
                imageID: riscvImageID, bootBaseDigest: base.digest,
                placeHold: false, includeRuntimeMetadata: false
            )
        }
        try await registerEnvironment(
            id: "env-cap-eligible", imageID: riscvImageID, rootfsDigest: base.digest
        )
        let eligible = try await makeQuarantineEntry(
            environmentID: "env-cap-eligible", runtimeID: "rt-cap-eligible",
            imageID: riscvImageID, bootBaseDigest: base.digest, placeHold: false
        )
        let limits = RuntimeV2RecoveredDiskRetirement.Limits(
            maximumCandidates: 8, maximumDirectoryEntries: 1024
        )
        let first = await store.disposeEligibleObsoleteRISCVRuntime(limits: limits)
        XCTAssertEqual(first.disposedCount, 1)
        XCTAssertTrue(first.scanTruncated)
        XCTAssertEqual(first.blockedCount, 20)
        XCTAssertTrue(first.shouldContinue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eligible.directory.path))

        // The next tap has no eligible head: it must report the blocked
        // truth and stop rather than repeatedly yielding the same work.
        let second = await store.disposeEligibleObsoleteRISCVRuntime(limits: limits)
        XCTAssertEqual(second.disposedCount, 0)
        XCTAssertTrue(second.scanTruncated)
        XCTAssertEqual(second.blockedCount, 20)
        XCTAssertFalse(second.shouldContinue)
        XCTAssertFalse(second.isComplete)
    }

    // MARK: - fixtures

    private enum TestFault: Error {
        case interrupted
    }

    private struct BaseFixture {
        var digest: String
        var rootfs: URL
    }

    private struct DiskFixture {
        var entry: String
        var directory: URL
        var diskURL: URL
    }

    private func makeObsoleteDeltaFiles(environmentID: String) throws {
        let system = try layout.environmentSystemDirectory(environmentID: environmentID)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        for (index, name) in RuntimeV2DeltaStore.obsoleteDisposalFileNames.enumerated() {
            try Data(repeating: UInt8(0x40 + index), count: 64)
                .write(to: system.appendingPathComponent(name))
        }
    }

    private func writeHistoricalExpiredLease(
        environmentID: String, runtimeID: String
    ) async throws {
        let now = Date()
        let lease = RuntimeV2LeaseStore.Lease(
            environmentID: environmentID, runtimeID: runtimeID,
            incarnation: "historical-incarnation", sessionToken: "historical-token",
            pid: 4_000_000, acquiredAt: now.addingTimeInterval(-600),
            renewedAt: now.addingTimeInterval(-600), ttlSeconds: 30
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(lease).write(
            to: try layout.environmentLeaseURL(environmentID: environmentID), options: .atomic
        )
        try await store.registry.recordLease(
            RuntimeV2Registry.LeaseRow(
                environmentID: environmentID, runtimeID: runtimeID,
                incarnation: lease.incarnation, sessionToken: lease.sessionToken,
                pid: lease.pid, acquiredAt: lease.acquiredAt, renewedAt: lease.renewedAt,
                ttlSeconds: lease.ttlSeconds, state: "held"
            )
        )
    }

    private func makeVerifiedBaseImage(imageID: String) async throws -> BaseFixture {
        let legacyRoot = root.appendingPathComponent("legacy-\(imageID)", isDirectory: true)
        let directory = legacyRoot.appendingPathComponent(imageID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bios = Data(count: 4096)
        for index in bios.indices { bios[index] = UInt8((index &* 31) % 251) }
        var rootfs = Data(count: 2 << 20)
        for index in rootfs.indices { rootfs[index] = UInt8((index &* 17) % 253) }
        try bios.write(to: directory.appendingPathComponent("bios.bin"))
        try rootfs.write(to: directory.appendingPathComponent("rootfs.img"))
        let image = LinuxGuestImage(
            id: imageID,
            biosPath: "bios.bin",
            diskPath: "rootfs.img",
            qualified: true,
            qualificationRun: "runtime-v2-recovered-retirement-tests",
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
        guard let manifest = try await store.images.manifest(imageID: imageID),
              let digest = manifest.rootfsDigest else {
            throw TestFault.interrupted
        }
        let expanded = try await store.images.ensureExpanded(imageID: imageID)
        return BaseFixture(digest: digest, rootfs: expanded.appendingPathComponent("rootfs.img"))
    }

    private func registerEnvironment(
        id: String, imageID: String, rootfsDigest: String
    ) async throws {
        let now = Date()
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: id, kind: "linuxVM", ownerID: nil, name: id,
                baseImageID: imageID, baseRootfsDigest: rootfsDigest,
                state: "stopped", dataPath: "environments/\(id)/data",
                compatHostFHS: false, repairReason: nil,
                createdAt: now, lastUsedAt: now
            )
        )
        let directory = try layout.environmentDirectory(environmentID: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = RuntimeV2EnvironmentMigrator.EnvironmentMetadata(
            environmentID: id, kind: "linuxVM", ownerID: nil, name: id,
            baseImageID: imageID, baseRootfsSHA512: rootfsDigest,
            compatHostFHS: false, createdAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(
            to: try layout.environmentMetadataURL(environmentID: id), options: .atomic
        )
        let dataDirectory = try layout.environmentDataDirectory(environmentID: id)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try "keep".write(
            to: dataDirectory.appendingPathComponent("user.txt"), atomically: true, encoding: .utf8
        )
        let system = try layout.environmentSystemDirectory(environmentID: id)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try "runner".write(
            to: system.appendingPathComponent("runner.json"), atomically: true, encoding: .utf8
        )
    }

    private func makeQuarantineEntry(
        environmentID: String, runtimeID: String, imageID: String,
        bootBaseDigest: String, placeHold: Bool,
        includeRuntimeMetadata: Bool = true,
        entryName: String? = nil,
        markerByte: UInt8 = 0xA5
    ) async throws -> DiskFixture {
        let entry = entryName ?? "runtime-vm-\(runtimeID)-\(UUID().uuidString.lowercased())"
        let directory = layout.quarantineDirectory.appendingPathComponent(entry, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let diskURL = directory.appendingPathComponent("disk.img")
        try writeSparseDisk(at: diskURL, markerByte: markerByte)
        if includeRuntimeMetadata {
            try RuntimeV2WorkingDirectory.writeMeta(
                RuntimeV2WorkingDirectory.Meta(
                    runtimeID: runtimeID, environmentID: environmentID,
                    baseImageID: imageID, createdAt: Date(),
                    bootBaseDiskDigest: bootBaseDigest
                ),
                to: directory
            )
        }
        if placeHold {
            try await store.repairHolds.place(
                environmentID: environmentID, runtimeID: runtimeID,
                reason: "test preserved obsolete RISC-V disk",
                preservedPath: "recovery/quarantine/\(entry)"
            )
            try await store.registry.setEnvironmentState(
                id: environmentID, state: "repairRequired", repairReason: "test"
            )
        }
        return DiskFixture(entry: entry, directory: directory, diskURL: diskURL)
    }

    private func makeDiscardedEntry(
        environmentID: String, runtimeID: String, imageID: String,
        bootBaseDigest: String
    ) async throws -> DiskFixture {
        let entry = "runtime-vm-\(runtimeID)-\(UUID().uuidString.lowercased())"
        let discarded = layout.recoveryMigrationsDirectory
            .appendingPathComponent("discarded", isDirectory: true)
        try FileManager.default.createDirectory(at: discarded, withIntermediateDirectories: true)
        let directory = discarded.appendingPathComponent(entry, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let diskURL = directory.appendingPathComponent("disk.img")
        try writeSparseDisk(at: diskURL, markerByte: 0xC3)
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: runtimeID, environmentID: environmentID,
                baseImageID: imageID, createdAt: Date(),
                bootBaseDiskDigest: bootBaseDigest
            ),
            to: directory
        )
        return DiskFixture(entry: entry, directory: directory, diskURL: diskURL)
    }

    private func makeDelta(
        environmentID: String, imageID: String, rootfs: URL, digest: String
    ) async throws {
        let work = root.appendingPathComponent("delta-source-\(UUID().uuidString).img")
        try FileManager.default.copyItem(at: rootfs, to: work)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: work.path)
        let handle = try FileHandle(forUpdating: work)
        try handle.seek(toOffset: (1 << 20) + 4096)
        try handle.write(contentsOf: Data(repeating: 0x5A, count: 4096))
        try handle.close()
        _ = try await store.deltas.capture(
            environmentID: environmentID, workingDisk: work,
            baseRootfs: rootfs, baseImageID: imageID,
            baseRootfsSHA512: digest
        )
        try? FileManager.default.removeItem(at: work)
    }

    private func writeSparseDisk(at url: URL, markerByte: UInt8) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TestFault.interrupted
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 1 << 20)
        try handle.write(contentsOf: Data(repeating: markerByte, count: 4096))
        try handle.truncate(atOffset: 8 << 20)
        try handle.close()
    }
}
