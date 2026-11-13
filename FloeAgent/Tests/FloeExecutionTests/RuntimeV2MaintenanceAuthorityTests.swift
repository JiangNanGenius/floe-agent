// FloeExecutionTests — fixed legacy-recovery-domain maintenance authority.
//
// Contract cases:
//  * pending start/shared use vs maintenance acquisition (whichever installs
//    first wins; the other fails closed);
//  * durable intent installed BEFORE the evidence await;
//  * a second RuntimeV2Store instance cannot restore/discard/recover past the
//    exclusive claim;
//  * stop capture is deferred without moving/deleting the stopped disk;
//  * a crash/durable intent never expires by TTL and blocks all new access
//    until the trusted recovery handler converges;
//  * stale lease sidecars and unexplained runtime/vm directories deny;
//  * unknown/incomplete owner evidence denies even when flock is free;
//  * quarantined-but-not-closed ownership keeps the claim;
//  * cancellation/dropping a task does not release a strongly-held claim;
//  * a target/lock identity replacement invalidates the claim;
//  * the resident ARM64 machine and production store root are outside the
//    domain and are neither stopped nor blocked.

import Foundation
import Darwin
import XCTest
import FloeCore
@testable import FloeExecution

final class RuntimeV2MaintenanceAuthorityTests: XCTestCase {
    private var root: URL!
    private var domain: RuntimeV2MaintenanceDomain!
    private var stateDirectory: URL!
    private var coordinator: RuntimeV2MaintenanceCoordinator!
    private var evidence: EvidenceBox!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("recovery/quarantine", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("runtime/vm", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("environments", isDirectory: true),
            withIntermediateDirectories: true
        )
        domain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: root)
        stateDirectory = root.deletingLastPathComponent()
            .appendingPathComponent("authority-\(UUID().uuidString)", isDirectory: true)
        let box = EvidenceBox(cleanEvidence())
        evidence = box
        coordinator = try RuntimeV2MaintenanceCoordinator(
            domain: domain,
            stateDirectory: stateDirectory,
            evidenceProvider: { box.value }
        )
        RuntimeV2MaintenanceRegistry.install(coordinator)
    }

    override func tearDown() async throws {
        if let root { RuntimeV2MaintenanceRegistry.unregister(domainRoot: root) }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    func testRenamedPhysicalDomainSelectsOriginalAuthorityAndRecoversHeldIntent() async throws {
        let fm = FileManager.default
        let work = root.appendingPathComponent("relocation-state")
        let oldContainer = work.appendingPathComponent("container-old")
        let newContainer = work.appendingPathComponent("container-new")
        let suffix = "Library/Application Support/Floe/Runtime/v2"
        let oldRoot = oldContainer.appendingPathComponent(suffix)
        try fm.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        let oldDomain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: oldRoot)
        let physical = try RuntimeV2DiskIdentity.read(at: oldDomain.root)
        let oldState = try oldDomain.authorityStateDirectory()
        try fm.createDirectory(at: oldState, withIntermediateDirectories: true)
        let lock = open(oldState.appendingPathComponent("maintenance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { return XCTFail("fixture lock open") }; close(lock)
        let lockBefore = try RuntimeV2DiskIdentity.read(at: oldState.appendingPathComponent("maintenance.lock"))
        let record = RuntimeV2MaintenanceIntentRecord(intentID: UUID().uuidString,
            holdGeneration: 9, phase: .recovering, owner: "test", reason: "rename",
            createdAt: Date(), updatedAt: Date(), domainRoot: oldDomain.root.path,
            domainDevice: physical.device, domainInode: physical.inode)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode(record)
        try original.write(to: oldState.appendingPathComponent("intent.json"))
        try fm.moveItem(at: oldContainer, to: newContainer)
        XCTAssertFalse(fm.fileExists(atPath: oldRoot.path))
        let current = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: newContainer.appendingPathComponent(suffix))
        XCTAssertNotEqual(current.domainKey, oldDomain.domainKey)
        // Reproduce339 bootstrap before this patch: the new path hash already
        // exists as an empty state directory, while old history remains below
        // the old hash. Merely preferring an existing current-key URL is wrong.
        let emptyNewState = current.root.deletingLastPathComponent()
            .appendingPathComponent("MaintenanceAuthority/" + current.domainKey)
        try fm.createDirectory(at: emptyNewState, withIntermediateDirectories: false)
        let emptyIdentity = try RuntimeV2DiskIdentity.read(at: emptyNewState)
        let selected = try current.authorityStateDirectory()
        XCTAssertEqual(selected.lastPathComponent, oldDomain.domainKey)
        XCTAssertNotEqual(selected, emptyNewState)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: emptyNewState.path).isEmpty)
        XCTAssertEqual(try RuntimeV2DiskIdentity.read(at: emptyNewState).inode, emptyIdentity.inode)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("intent.json")), original)
        let lockAfter = try RuntimeV2DiskIdentity.read(at: selected.appendingPathComponent("maintenance.lock"))
        XCTAssertEqual(lockAfter.device, lockBefore.device); XCTAssertEqual(lockAfter.inode, lockBefore.inode)
        let box = evidence!
        let recovered = try RuntimeV2MaintenanceCoordinator(domain: current, stateDirectory: selected,
            evidenceProvider: { box.value })
        await recovered.installRecoveryHandler { intent in
            XCTAssertEqual(intent.domainRoot, record.domainRoot)
            return .resolved
        }
        let result = await recovered.recoverIfNeeded()
        XCTAssertEqual(result.outcome, .resolved)
        // A later current-path intent remains in the same selected state even
        // though its path hash differs from this directory's historical index.
        var later = record; later.domainRoot = current.root.path; later.phase = .resolved
        try encoder.encode(later).write(to: selected.appendingPathComponent("intent.json"))
        XCTAssertEqual(try current.authorityStateDirectory(), selected)
        let admission = open(emptyNewState.appendingPathComponent("admission.lock").path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard admission >= 0 else { return XCTFail("synthetic admission lock open") }; close(admission)
        XCTAssertEqual(try current.authorityStateDirectory(), selected)
        // An unexplained maintenance namespace is NOT empty. Do not ignore
        // its possible live/durable work just because an older key is known.
        let unknownLock = open(emptyNewState.appendingPathComponent("maintenance.lock").path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard unknownLock >= 0 else { return XCTFail("synthetic maintenance lock open") }; close(unknownLock)
        let settledBytes = try Data(contentsOf: selected.appendingPathComponent("intent.json"))
        XCTAssertThrowsError(try current.authorityStateDirectory())
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("intent.json")), settledBytes)
    }

    func testCopiedOrAmbiguousAuthorityHistoryCannotCreateFreshNamespace() throws {
        let fm = FileManager.default
        let work = root.appendingPathComponent("copy-state")
        let oldContainer = work.appendingPathComponent("container-old")
        let newContainer = work.appendingPathComponent("container-new")
        let suffix = "Library/Application Support/Floe/Runtime/v2"
        let oldRoot = oldContainer.appendingPathComponent(suffix)
        try fm.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        let oldDomain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: oldRoot)
        let physical = try RuntimeV2DiskIdentity.read(at: oldDomain.root)
        let state = try oldDomain.authorityStateDirectory()
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        let record = RuntimeV2MaintenanceIntentRecord(intentID: UUID().uuidString,
            holdGeneration: 2, phase: .resolved, owner: "test", reason: "copy",
            createdAt: Date(), updatedAt: Date(), domainRoot: oldDomain.root.path,
            domainDevice: physical.device, domainInode: physical.inode)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode(record)
        try original.write(to: state.appendingPathComponent("intent.json"))
        try fm.copyItem(at: oldContainer, to: newContainer)
        try fm.removeItem(at: oldContainer)
        let copied = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: newContainer.appendingPathComponent(suffix))
        let copiedState = copied.root.deletingLastPathComponent().appendingPathComponent("MaintenanceAuthority/" + oldDomain.domainKey)
        XCTAssertThrowsError(try copied.authorityStateDirectory())
        XCTAssertEqual(try Data(contentsOf: copiedState.appendingPathComponent("intent.json")), original)
        XCTAssertFalse(fm.fileExists(atPath: copied.root.deletingLastPathComponent()
            .appendingPathComponent("MaintenanceAuthority/" + copied.domainKey).path))
        let actual = try RuntimeV2DiskIdentity.read(at: copied.root)
        var same = record; same.domainRoot = copied.root.path; same.domainDevice = actual.device; same.domainInode = actual.inode
        let sameBytes = try encoder.encode(same)
        try sameBytes.write(to: copiedState.appendingPathComponent("intent.json"))
        let duplicate = copiedState.deletingLastPathComponent().appendingPathComponent(String(repeating: "b", count: 64))
        try fm.createDirectory(at: duplicate, withIntermediateDirectories: false)
        try sameBytes.write(to: duplicate.appendingPathComponent("intent.json"))
        XCTAssertThrowsError(try copied.authorityStateDirectory())
        try fm.removeItem(at: duplicate)
        try fm.createSymbolicLink(at: duplicate, withDestinationURL: copiedState)
        XCTAssertThrowsError(try copied.authorityStateDirectory())
    }

    func testUnknownPhysicalIdentityCannotBeClearedByTrustedHandler() async throws {
        let record = RuntimeV2MaintenanceIntentRecord(intentID: UUID().uuidString,
            holdGeneration: 3, phase: .recovering, owner: "test", reason: "missing identity",
            createdAt: Date(), updatedAt: Date(), domainRoot: root.path)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(record)
        try bytes.write(to: stateDirectory.appendingPathComponent("intent.json"))
        let box = evidence!
        let recovered = try RuntimeV2MaintenanceCoordinator(domain: domain, stateDirectory: stateDirectory,
            evidenceProvider: { box.value })
        await recovered.installRecoveryHandler { _ in XCTFail("unknown root must never enter IO handler"); return .resolved }
        let result = await recovered.recoverIfNeeded()
        XCTAssertEqual(result.outcome, .blocked)
        XCTAssertEqual(try Data(contentsOf: stateDirectory.appendingPathComponent("intent.json")), bytes)
    }

    // MARK: - Cases

    func testPendingStartAndMaintenanceCannotBothWin() async throws {
        let startUse = try await coordinator.acquireSharedUse(owner: "guest-start", purpose: "test-start")
        do {
            _ = try await coordinator.acquireExclusiveMaintenance(
                RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
            )
            XCTFail("maintenance must not acquire while a pending start holds shared use")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .maintenanceActive = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        await startUse.release()

        let claim = try await coordinator.acquireExclusiveMaintenance(
            RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
        )
        do {
            _ = try await coordinator.acquireSharedUse(owner: "guest-start", purpose: "test-start")
            XCTFail("a new start must not acquire while maintenance owns the domain")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .maintenanceActive = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }

        // The real integrator resolves the same registered domain per store
        // operation (not at init): its start-side shared use is refused too.
        let store = RuntimeV2Store(layout: RuntimeV2Layout(root: root))
        let integrator = RuntimeV2GuestIntegrator(store: store, build: "test")
        do {
            _ = try await integrator.beginMaintenanceSharedUse(
                environmentID: "env-start", purpose: "guest-start"
            )
            XCTFail("the real integrator must be fenced by the same coordinator")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .maintenanceActive = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        try await claim.abortAndRelease(reason: "test finished")
        let after = try await integrator.beginMaintenanceSharedUse(
            environmentID: "env-start", purpose: "guest-start"
        )
        await after?.release()
    }

    func testDurableIntentIsInstalledBeforeEvidenceAwait() async throws {
        let gate = EvidenceGate()
        let otherState = stateDirectory!
        let localDomain = domain!
        let localEvidence = evidence!
        let otherCoordinator = try RuntimeV2MaintenanceCoordinator(
            domain: localDomain, stateDirectory: otherState,
            evidenceProvider: {
                await gate.wait()
                return localEvidence.value
            }
        )
        RuntimeV2MaintenanceRegistry.install(otherCoordinator)

        let task = Task { try await otherCoordinator.acquireExclusiveMaintenance(
            RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
        ) }
        await gate.waitUntilEntered()
        let state = await otherCoordinator.state()
        XCTAssertEqual(state.phase, .maintenancePending)
        do {
            _ = try await otherCoordinator.acquireSharedUse(owner: "late-start", purpose: "test")
            XCTFail("a shared use must be refused while the intent is being installed")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .maintenanceActive = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        await gate.open()
        let claim = try await task.value
        let after = await otherCoordinator.state()
        XCTAssertEqual(after.phase, .maintenanceActive)
        do {
            _ = try await otherCoordinator.acquireSharedUse(owner: "late-start", purpose: "test")
            XCTFail("a shared use must remain refused after activation")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .maintenanceActive = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        try await claim.abortAndRelease(reason: "test finished")
    }

    func testSecondStoreCannotRestoreOrDiscardUnderExclusiveClaim() async throws {
        let layout = RuntimeV2Layout(root: root)
        let storeA = RuntimeV2Store(layout: layout)
        _ = try await storeA.prepareAndRecover(build: "test")
        let quarantine = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-rt-ghost-test", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 8_192).write(to: quarantine.appendingPathComponent("disk.img"))
        try await storeA.repairHolds.place(
            environmentID: "env-ghost", runtimeID: "rt-ghost",
            reason: "test fixture", preservedPath: "recovery/quarantine/runtime-vm-rt-ghost-test"
        )

        let claim = try await coordinator.acquireExclusiveMaintenance(
            RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
        )
        let storeB = RuntimeV2Store(layout: layout)
        do {
            _ = try await storeB.discardUnverifiableRepairEvidence(
                environmentID: "env-ghost", reason: "test"
            )
            XCTFail("a second store instance must not discard under maintenance")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .maintenanceActive = error else {
                XCTFail("unexpected discard error \(error)")
                return
            }
        }
        do {
            _ = try await storeB.restoreRepair(environmentID: "env-ghost")
            XCTFail("a second store instance must not restore under maintenance")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .maintenanceActive = error else {
                XCTFail("unexpected restore error \(error)")
                return
            }
        }
        // Nothing moved while the exclusive claim was live.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: quarantine.appendingPathComponent("disk.img").path
        ))
        try await claim.abortAndRelease(reason: "test finished")

        let report = try await storeB.discardUnverifiableRepairEvidence(
            environmentID: "env-ghost", reason: "test"
        )
        XCTAssertEqual(report.resolution, "discarded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testStopCaptureIsDeferredWithoutMovingTheStoppedDisk() async throws {
        let layout = RuntimeV2Layout(root: root)
        let store = RuntimeV2Store(layout: layout)
        _ = try await store.prepareAndRecover(build: "test")
        let integrator = RuntimeV2GuestIntegrator(store: store, build: "test")
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-capture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = directory.appendingPathComponent("disk.img")
        try Data(repeating: 0x5A, count: 16_384).write(to: disk)
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-capture", environmentID: "env-capture",
                baseImageID: "img", createdAt: Date()
            ),
            to: directory
        )

        let claim = try await coordinator.acquireExclusiveMaintenance(
            RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
        )
        let outcome = await integrator.completeStopResult(
            environmentID: "env-capture", runtimeID: "rt-capture",
            imageID: "img", clean: true
        )
        guard case .deferredForMaintenance = outcome else {
            XCTFail("capture must defer while maintenance is active, got \(outcome)")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.path))
        let observedDisk = try Data(contentsOf: disk)
        XCTAssertEqual(observedDisk, Data(repeating: 0x5A, count: 16_384))
        try await claim.abortAndRelease(reason: "test finished")
        let quarantine = (try? FileManager.default.contentsOfDirectory(
            atPath: layout.quarantineDirectory.path
        )) ?? []
        XCTAssertTrue(quarantine.isEmpty, "deferred capture must not move the disk")
    }

    func testCrashIntentBlocksUntilRecoveryConvergesAndIgnoresAge() async throws {
        // Write an active intent dated one year ago directly: there is no TTL
        // path that can make this open by elapsing time.
        var record = RuntimeV2MaintenanceIntentRecord(
            intentID: UUID().uuidString, holdGeneration: 7, phase: .active,
            owner: "crashed-helper", reason: "test crash",
            createdAt: Date(timeIntervalSinceNow: -365 * 24 * 3600),
            updatedAt: Date(timeIntervalSinceNow: -365 * 24 * 3600),
            domainRoot: root.path
        )
        let physical = try RuntimeV2DiskIdentity.read(at: root)
        record.domainDevice = physical.device
        record.domainInode = physical.inode
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(
            to: stateDirectory.appendingPathComponent("intent.json")
        )

        let localDomain = domain!
        let box = evidence!
        let recovered = try RuntimeV2MaintenanceCoordinator(
            domain: localDomain, stateDirectory: stateDirectory,
            evidenceProvider: { box.value }
        )
        let report = await recovered.recoverIfNeeded()
        XCTAssertEqual(report.outcome, .blocked)
        do {
            _ = try await recovered.acquireSharedUse(owner: "start", purpose: "test")
            XCTFail("a durable crash intent must close the domain")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .recoveryPending = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        // Installing a handler and converging is the only way forward.
        await recovered.installRecoveryHandler { _ in .resolved }
        let resolved = await recovered.recoverIfNeeded()
        XCTAssertEqual(resolved.outcome, .resolved)
        let use = try await recovered.acquireSharedUse(owner: "start", purpose: "test")
        await use.release()
    }

    func testCorruptIntentStaysClosed() async throws {
        try Data("not an intent".utf8).write(
            to: stateDirectory.appendingPathComponent("intent.json")
        )
        let localDomain = domain!
        let box = evidence!
        let recovered = try RuntimeV2MaintenanceCoordinator(
            domain: localDomain, stateDirectory: stateDirectory,
            evidenceProvider: { box.value }
        )
        await recovered.installRecoveryHandler { _ in .resolved }
        let report = await recovered.recoverIfNeeded()
        XCTAssertEqual(report.outcome, .blocked)
        do {
            _ = try await recovered.acquireSharedUse(owner: "start", purpose: "test")
            XCTFail("a corrupt intent can never be cleared by time or a handler")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .recoveryPending = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
    }

    func testStaleLeaseSidecarAndRuntimeDirectoryDenyEvenThoughFlockIsFree() async throws {
        let environment = root.appendingPathComponent("environments/env-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
        try Data("{\"pid\":4000000,\"renewedAt\":\"2001-01-01T00:00:00Z\",\"ttlSeconds\":30}".utf8)
            .write(to: environment.appendingPathComponent("lease.json"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("runtime/vm/rt-leftover", isDirectory: true),
            withIntermediateDirectories: true
        )

        let localDomain = domain!
        let localRootPath = root.path
        let collector = RuntimeV2MaintenanceEvidenceCollector(
            domain: localDomain,
            sources: .init(
                registry: { .init() },
                integrator: { .init(storeRootPath: localRootPath) },
                references: { .init(isComplete: true, fingerprint: "refs") }
            )
        )
        let collected = await collector.collect()
        XCTAssertTrue(collected.isComplete)
        XCTAssertFalse(collected.isQuiescent(domain: localDomain))
        XCTAssertTrue(collected.quiescenceBlockers(domain: domain).contains("filesystem_lease_trace:env-stale"))
        XCTAssertTrue(collected.quiescenceBlockers(domain: domain).contains("filesystem_runtime_trace:rt-leftover"))

        let gate = try RuntimeV2MaintenanceCoordinator(
            domain: domain, stateDirectory: stateDirectory,
            evidenceProvider: { await collector.collect() }
        )
        do {
            _ = try await gate.acquireExclusiveMaintenance(
                RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
            )
            XCTFail("a stale lease trace is not proof of a closed domain")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .ownerEvidenceIncomplete = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
    }

    func testLegacyRegistryWithoutACoveringIntegratorIsIncomplete() async throws {
        let registryDirectory = root.appendingPathComponent("registry", isDirectory: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        try Data().write(to: registryDirectory.appendingPathComponent("runtime.sqlite"))
        let localDomain = domain!
        let otherRootPath = root.deletingLastPathComponent()
            .appendingPathComponent("other-domain-\(UUID().uuidString)").path

        let uncovered = RuntimeV2MaintenanceEvidenceCollector(
            domain: localDomain,
            sources: .init(
                registry: { .init() },
                integrator: { .init(storeRootPath: otherRootPath) },
                references: { .init(isComplete: true, fingerprint: "refs") }
            )
        )
        let withoutCoverage = await uncovered.collect()
        XCTAssertFalse(withoutCoverage.isComplete)
        XCTAssertTrue(withoutCoverage.blockers.contains("filesystem_lease_registry_unmeasured"))
        XCTAssertTrue(withoutCoverage.quiescenceBlockers(domain: localDomain)
            .contains("filesystem_lease_registry_unmeasured"))

        let covered = RuntimeV2MaintenanceEvidenceCollector(
            domain: localDomain,
            sources: .init(
                registry: { .init() },
                integrator: {
                    .init(storeRootPath: localDomain.root.path,
                          leaseRegistryEnvironments: [])
                },
                references: { .init(isComplete: true, fingerprint: "refs") }
            )
        )
        let withCoverage = await covered.collect()
        XCTAssertTrue(withCoverage.isComplete)
        XCTAssertFalse(withCoverage.blockers.contains("filesystem_lease_registry_unmeasured"))
    }

    func testUnknownOwnerEvidenceDeniesWithAFreeFlock() async throws {
        evidence.value = cleanEvidence().withRegistry(
            .init(unknownOwnerState: true, isComplete: false)
        )
        do {
            _ = try await coordinator.acquireExclusiveMaintenance(
                RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
            )
            XCTFail("incomplete/unknown owner evidence must deny")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .ownerEvidenceIncomplete(let blockers) = error else {
                XCTFail("unexpected error \(error)")
                return
            }
            XCTAssertTrue(blockers.contains("registry_owner_state_unknown"))
        }
    }

    func testIdleUnattributedUnknownDoesNotBlockButLiveUnknownDoes() async throws {
        evidence.value = cleanEvidence().withReferences(
            .init(isComplete: true, unattributedIdleUnknownCount: 3, fingerprint: "refs")
        )
        let claim = try await coordinator.acquireExclusiveMaintenance(
            RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
        )
        try await claim.abortAndRelease(reason: "test finished")

        evidence.value = cleanEvidence().withReferences(
            .init(isComplete: true, unattributedLiveUnknownCount: 1, fingerprint: "refs")
        )
        do {
            _ = try await coordinator.acquireExclusiveMaintenance(
                RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
            )
            XCTFail("a live unattributed unknown must fail closed")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .ownerEvidenceIncomplete(let blockers) = error else {
                XCTFail("unexpected error \(error)")
                return
            }
            XCTAssertTrue(blockers.contains("reference_live_unknown_unattributed:1"))
        }
    }

    func testQuarantinedButNotClosedHoldsTheClaim() async throws {
        let use = try await coordinator.acquireSharedUse(
            owner: "linux-guest-registry", purpose: "quarantined-session"
        )
        do {
            _ = try await coordinator.acquireExclusiveMaintenance(
                RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
            )
            XCTFail("a quarantined-but-not-closed session still owns its disk")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .maintenanceActive = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        await use.release()

        // Even with no counted claim, explicit registry quarantine blocks.
        evidence.value = cleanEvidence().withRegistry(
            .init(quarantinedEnvironments: ["env-quarantined"])
        )
        do {
            _ = try await coordinator.acquireExclusiveMaintenance(
                RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
            )
            XCTFail("registry quarantine must deny exclusive acquisition")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .ownerEvidenceIncomplete(let blockers) = error else {
                XCTFail("unexpected error \(error)")
                return
            }
            XCTAssertTrue(blockers.contains("registry_quarantined:env-quarantined"))
        }
    }

    func testCancellationDoesNotReleaseAStronglyHeldClaim() async throws {
        let box = ClaimBox()
        let workerCoordinator = try XCTUnwrap(coordinator)
        let task = Task { [workerCoordinator, box] in
            let use = try await workerCoordinator.acquireSharedUse(owner: "worker", purpose: "capture")
            box.set(use)
        }
        try await task.value
        task.cancel()
        let state = await coordinator.state()
        XCTAssertEqual(state.sharedUseCount, 1)
        do {
            _ = try await coordinator.acquireExclusiveMaintenance(
                RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
            )
            XCTFail("a cancelled task must not release a claim it still holds")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .maintenanceActive = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        await box.value?.release()
        let claim = try await coordinator.acquireExclusiveMaintenance(
            RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
        )
        try await claim.abortAndRelease(reason: "test finished")
    }

    func testTargetAndLockIdentityReplacementInvalidatesTheClaim() async throws {
        let target = root.appendingPathComponent("recovery/quarantine/runtime-vm-target/disk.img")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x44, count: 4_096).write(to: target)
        let identity = try RuntimeV2DiskIdentity.read(at: target)
        let claim = try await coordinator.acquireExclusiveMaintenance(
            RuntimeV2MaintenanceRequest(
                owner: "test", reason: "test",
                targetRelativePath: "recovery/quarantine/runtime-vm-target/disk.img",
                targetIdentity: identity
            )
        )
        try claim.validateTargetIdentity()

        let replacement = target.deletingLastPathComponent().appendingPathComponent(".replacement")
        try Data(repeating: 0x44, count: 4_096).write(to: replacement)
        XCTAssertEqual(rename(replacement.path, target.path), 0)
        do {
            try claim.validateTargetIdentity()
            XCTFail("a temp+rename target replacement must invalidate the claim")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .targetIdentityMismatch = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }

        let lockURL = stateDirectory.appendingPathComponent("maintenance.lock")
        let moved = stateDirectory.appendingPathComponent("maintenance.lock.moved")
        XCTAssertEqual(rename(lockURL.path, moved.path), 0)
        try Data().write(to: lockURL)
        do {
            try await claim.validate()
            XCTFail("a replaced lock entry must invalidate the claim")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .claimInvalidated = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        try await claim.abortAndRelease(reason: "test finished")
    }

    func testResidentArm64OutsideDomainIsNeitherStoppedNorBlocked() async throws {
        // A production/resident root that is NOT the registered legacy domain.
        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("arm64-resident-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let otherLayout = RuntimeV2Layout(root: otherRoot)
        try otherLayout.prepare(build: "test")

        let collector = RuntimeV2MaintenanceEvidenceCollector(
            domain: domain,
            sources: .init(
                registry: {
                    .init(
                        usesResidentMachine: true,
                        startingEnvironments: ["resident-arm64"],
                        activeSessions: ["resident-arm64"]
                    )
                },
                integrator: {
                    .init(storeRootPath: otherRoot.path,
                          heldLeaseEnvironments: ["resident-arm64"])
                },
                references: { .init(isComplete: true, fingerprint: "refs") }
            )
        )
        let collected = await collector.collect()
        XCTAssertTrue(collected.isComplete)
        XCTAssertTrue(collected.isQuiescent(domain: domain))
        XCTAssertFalse(domain.ownsEnvironmentTrace("resident-arm64"))

        let gate = try RuntimeV2MaintenanceCoordinator(
            domain: domain, stateDirectory: stateDirectory,
            evidenceProvider: { await collector.collect() }
        )
        let claim = try await gate.acquireExclusiveMaintenance(
            RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
        )
        // The other (production/resident) store root is not the registered
        // domain, so its normal work proceeds while legacy maintenance is live.
        let otherStore = RuntimeV2Store(layout: otherLayout)
        _ = try await otherStore.prepareAndRecover(build: "test")
        let residentUse = try await otherStore.acquireMaintenanceSharedUse(
            owner: "resident", purpose: "test"
        )
        XCTAssertNil(residentUse)
        try await claim.abortAndRelease(reason: "test finished")
    }

    func testTargetOutsideTheRecoveryTreeIsRejected() async throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("runtime/vm/rt-target", isDirectory: true),
            withIntermediateDirectories: true
        )
        let disk = root.appendingPathComponent("runtime/vm/rt-target/disk.img")
        try Data(repeating: 0x22, count: 1_024).write(to: disk)
        let identity = try RuntimeV2DiskIdentity.read(at: disk)
        do {
            _ = try await coordinator.acquireExclusiveMaintenance(
                RuntimeV2MaintenanceRequest(
                    owner: "test", reason: "test",
                    targetRelativePath: "runtime/vm/rt-target/disk.img",
                    targetIdentity: identity
                )
            )
            XCTFail("only a target under recovery/ may be admitted")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .invalidTarget = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        // No intent may be left behind by a rejected request.
        let state = await coordinator.state()
        XCTAssertEqual(state.phase, .open)
    }

    func testReferenceFingerprintIsRevalidatedInsideTheBarrier() async throws {
        let claim = try await coordinator.acquireExclusiveMaintenance(
            RuntimeV2MaintenanceRequest(owner: "test", reason: "test")
        )
        try claim.validateReferenceFingerprint("refs")
        do {
            try claim.validateReferenceFingerprint("changed-by-a-new-binding")
            XCTFail("a changed reference projection must invalidate the commit")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .claimInvalidated = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        do {
            try claim.validateReferenceFingerprint("")
            XCTFail("an unavailable projection must never match")
        } catch let error as RuntimeV2MaintenanceError {
            guard case .claimInvalidated = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        try await claim.abortAndRelease(reason: "test finished")
    }

    func testCommitFlowResolvesTheDurableIntent() async throws {
        let target = root.appendingPathComponent("recovery/quarantine/runtime-vm-commit/disk.img")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x11, count: 2_048).write(to: target)
        let identity = try RuntimeV2DiskIdentity.read(at: target)
        let claim = try await coordinator.acquireExclusiveMaintenance(
            RuntimeV2MaintenanceRequest(
                owner: "test", reason: "test",
                targetRelativePath: "recovery/quarantine/runtime-vm-commit/disk.img",
                targetIdentity: identity
            )
        )
        try await claim.markCommitting()
        _ = try await claim.recordTargetIdentityAfterCommit()
        try await claim.commitAndRelease()

        let intentData = try Data(contentsOf: stateDirectory.appendingPathComponent("intent.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let intent = try decoder.decode(RuntimeV2MaintenanceIntentRecord.self, from: intentData)
        XCTAssertEqual(intent.phase, .resolved)
        let use = try await coordinator.acquireSharedUse(owner: "after", purpose: "test")
        await use.release()
    }

    // MARK: - Evidence helpers

    private func cleanEvidence() -> RuntimeV2MaintenanceOwnerEvidence {
        cleanEvidence(for: domain)
    }

    private func cleanEvidence(for domain: RuntimeV2MaintenanceDomain) -> RuntimeV2MaintenanceOwnerEvidence {
        RuntimeV2MaintenanceOwnerEvidence(
            capturedAt: Date(),
            isComplete: true,
            blockers: [],
            registry: .init(),
            integrator: .init(storeRootPath: domain.root.path),
            references: .init(isComplete: true, fingerprint: "refs"),
            filesystem: .init(),
            startupRecoveryActive: false
        )
    }
}

private extension RuntimeV2MaintenanceOwnerEvidence {
    func withRegistry(_ value: Registry) -> RuntimeV2MaintenanceOwnerEvidence {
        var copy = self
        copy.registry = value
        return copy
    }

    func withReferences(_ value: References) -> RuntimeV2MaintenanceOwnerEvidence {
        var copy = self
        copy.references = value
        return copy
    }
}

private final class EvidenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RuntimeV2MaintenanceOwnerEvidence

    init(_ value: RuntimeV2MaintenanceOwnerEvidence) { self.stored = value }

    var value: RuntimeV2MaintenanceOwnerEvidence {
        get {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock(); defer { lock.unlock() }
            stored = newValue
        }
    }
}

private final class ClaimBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RuntimeV2MaintenanceSharedUse?

    func set(_ value: RuntimeV2MaintenanceSharedUse) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }

    var value: RuntimeV2MaintenanceSharedUse? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

private actor EvidenceGate {
    private var entered = false
    private var opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if opened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        opened = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
