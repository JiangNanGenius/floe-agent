// FloeExecutionTests — verified Linux boot-asset (firmware + kernel) update
// adoption: closed-by-default offers, quiet-stop gating backed by the real
// start-lease gate, transactional install/rollback with a single sidecar
// commit point, installed-newer boot-path precedence, and persistence
// invariants (base disk + default pair untouched).
//
// No network, no VM: real files under temporary directories.

import Foundation
import XCTest
import FloeCore
@testable import FloeExecution

private func makeQuietReconciliation() -> LinuxGuestStoppedReconciliation {
    LinuxGuestStoppedReconciliation(
        phase: .stopped,
        savedConfig: nil,
        launchGeneration: nil,
        quarantined: false,
        instanceRegistered: false,
        engineRunning: false,
        operationActive: false,
        probeConsistent: true
    )
}

private func makeBundle(
    root: URL,
    version: String = "6.18.56",
    firmware: Data = Data("fw-v2".utf8),
    kernel: Data = Data("kernel-v2".utf8)
) throws -> (bundle: LinuxGuestBootAssetBundle, directory: URL) {
    let dir = root.appendingPathComponent("bundle-\(version)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pair = LinuxGuestBootAssetPair(
        label: "linux-\(version)-opensbi-1.9",
        version: version,
        firmwareFileName: "opensbi_fw_jump.bin",
        kernelFileName: "kernel-\(version)-riscv64.bin",
        firmwareSHA256: FloeDigest.sha256Hex(firmware),
        kernelSHA256: FloeDigest.sha256Hex(kernel),
        firmwareBytes: Int64(firmware.count),
        kernelBytes: Int64(kernel.count)
    )
    let bundle = LinuxGuestBootAssetBundle(
        pair: pair,
        sourceReferences: ["test"],
        licenses: ["GPL-2.0", "BSD-2-Clause"]
    )
    try firmware.write(to: dir.appendingPathComponent(pair.firmwareFileName))
    try kernel.write(to: dir.appendingPathComponent(pair.kernelFileName))
    try JSONEncoder().encode(bundle).write(to: dir.appendingPathComponent("boot-pair-v2.manifest.json"))
    return (bundle, dir)
}

final class LinuxKernelUpgradeTests: XCTestCase {

    // MARK: version precedence

    func testVersionOrderingIsStrictlyNewerOnly() {
        XCTAssertTrue(LinuxGuestBootAssetUpdateService.isVersion("6.18.56", newerThan: "6.12.112"))
        XCTAssertTrue(LinuxGuestBootAssetUpdateService.isVersion("6.18.56", newerThan: "6.18.55"))
        XCTAssertFalse(LinuxGuestBootAssetUpdateService.isVersion("6.18.56", newerThan: "6.18.56"))
        XCTAssertFalse(LinuxGuestBootAssetUpdateService.isVersion("6.12.112", newerThan: "6.18.56"))
        XCTAssertFalse(LinuxGuestBootAssetUpdateService.isVersion("6.18.56", newerThan: "6.19.0"))
    }

    func testUnparseableVersionIsRefusedNotSpeculativelyAccepted() {
        // Closed by default: anything that cannot be ordered is not newer.
        XCTAssertFalse(LinuxGuestBootAssetUpdateService.isVersion("six", newerThan: "6.18.56"))
        XCTAssertFalse(LinuxGuestBootAssetUpdateService.isVersion("6.18.56", newerThan: "six"))
        XCTAssertFalse(LinuxGuestBootAssetUpdateService.isVersion("6..18", newerThan: "6.18.56"))
        XCTAssertFalse(LinuxGuestBootAssetUpdateService.isVersion("", newerThan: "6.18.56"))
    }

    // MARK: happy path

    func testInstallAdoptsPairAndResolutionPrefersIt() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-happy")
        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )

        let state = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })
        guard case .updateInstalled(let sidecar) = state else {
            return XCTFail("expected updateInstalled, got \(state)")
        }
        XCTAssertEqual(sidecar.pair.version, "6.18.56")
        XCTAssertEqual(sidecar.defaultBiosPath, "bbl64.bin")
        XCTAssertTrue(sidecar.storageDirectory.hasPrefix("boot-assets.d/6.18.56-"))

        // Installed-newer precedence: resolution selects the immutable v2
        // storage directory.
        let resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertTrue(resolved.biosPath.contains("boot-assets.d/"), "expected immutable storage dir, got \(resolved.biosPath)")
        XCTAssertTrue(resolved.biosPath.hasSuffix("opensbi_fw_jump.bin"))
        XCTAssertTrue(resolved.kernelPath?.hasSuffix("kernel-6.18.56-riscv64.bin") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.biosPath))

        // The whole start-preparation path resolves the v2 files.
        let writable = try makeTemporaryDirectory("boot-assets-layer")
        let runtime = try LinuxGuestRuntimeImagePreparer().prepare(
            image: fixture.manifest,
            imageDirectory: fixture.imageDirectory,
            environmentID: "env-boot-assets",
            writableDirectory: writable,
            targetCapacityBytes: 64 * 1024 * 1024
        )
        XCTAssertTrue(runtime.biosPath.contains("boot-assets.d/"))
        XCTAssertTrue(runtime.kernelPath?.contains("boot-assets.d/") == true)

        // Default pair files remain byte-identical (rollback availability).
        XCTAssertEqual(try Data(contentsOf: fixture.biosURL), Data("bios-boot-assets-happy".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.kernelURL), Data("kernel-boot-assets-happy".utf8))
    }

    func testRollbackRestoresDefaultPairAndKeepsAdoptedFiles() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-rollback")
        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        _ = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })

        let state = try await service.rollback(imageID: fixture.id, environmentIDs: { _ in [] })
        guard case .rolledBack = state else {
            return XCTFail("expected rolledBack, got \(state)")
        }
        let resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertEqual(resolved.biosPath, "bbl64.bin")
        XCTAssertEqual(resolved.kernelPath, "kernel-riscv64.bin")
        // Adopted immutable files stay on disk so re-adoption is instant.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.imageDirectory.appendingPathComponent("boot-assets.d").path
        ))
    }

    func testRollbackRefusesWhenDefaultPairNoLongerMatchesManifestDigest() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-rb-tamper")
        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        _ = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })

        // Tamper with the default kernel: rollback must refuse (the
        // manifest's sha512 record no longer matches), leaving the
        // adoption selected.
        try Data("TAMPERED-DEFAULT".utf8).write(to: fixture.kernelURL)
        await XCTAssertThrowsErrorAsync({
            try await service.rollback(imageID: fixture.id, environmentIDs: { _ in [] })
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.artifactVerificationFailed(let role) = error else {
                return XCTFail("expected artifactVerificationFailed, got \(error)")
            }
            XCTAssertEqual(role, "default kernel")
        }
        let resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertTrue(resolved.biosPath.contains("boot-assets.d/"), "adoption must survive a refused rollback")
    }

    // MARK: closed-by-default gates

    func testInstallRefusesWhenEnvironmentNotQuietAndTouchesNothing() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-busy")
        let bundle = try makeBundle(root: fixture.root)
        let busy = LinuxGuestStoppedReconciliation(
            phase: .running,
            savedConfig: nil,
            launchGeneration: 2,
            quarantined: false,
            instanceRegistered: true,
            engineRunning: true
        )
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in busy }
        )
        await XCTAssertThrowsErrorAsync({
            try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in ["env-a"] })
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.environmentsNotQuiet(let ids) = error else {
                return XCTFail("expected environmentsNotQuiet, got \(error)")
            }
            XCTAssertEqual(ids, ["env-a"])
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.imageDirectory.appendingPathComponent("boot-assets.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.imageDirectory.appendingPathComponent("boot-assets.d").path
        ))
    }

    func testInstallRefusesOperationInFlightEvenWhenPhaseStopped() async throws {
        // A stopped phase with a lifecycle operation active (start/stop/
        // restart racing) is NOT quiet: the transient no-instance window
        // must never be read as settled.
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-inflight")
        let bundle = try makeBundle(root: fixture.root)
        let starting = LinuxGuestStoppedReconciliation(
            phase: .stopped,
            savedConfig: nil,
            launchGeneration: nil,
            quarantined: false,
            instanceRegistered: false,
            engineRunning: false,
            operationActive: true,
            probeConsistent: true
        )
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in starting }
        )
        await XCTAssertThrowsErrorAsync({
            try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in ["env-a"] })
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.environmentsNotQuiet = error else {
                return XCTFail("expected environmentsNotQuiet, got \(error)")
            }
        }
    }

    func testInstallRefusesWhenSnapshotMissingAndWhenEnumerationImpossible() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-failclosed")
        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in nil }
        )
        // nil snapshot proves nothing -> refuse.
        await XCTAssertThrowsErrorAsync({
            try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in ["env-a"] })
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.environmentsNotQuiet(let ids) = error else {
                return XCTFail("expected environmentsNotQuiet, got \(error)")
            }
            XCTAssertEqual(ids, ["env-a"])
        }
        // nil enumeration -> refuse.
        await XCTAssertThrowsErrorAsync({
            try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in nil })
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.enumerationUnavailable = error else {
                return XCTFail("expected enumerationUnavailable, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.imageDirectory.appendingPathComponent("boot-assets.json").path
        ))
    }

    func testInstallFailsClosedOnBundleHashMismatch() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-tamper")
        let dir = fixture.root.appendingPathComponent("bundle-tampered", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let firmware = Data("fw-v2".utf8)
        let kernel = Data("kernel-v2".utf8)
        let pair = LinuxGuestBootAssetPair(
            label: "tampered", version: "6.18.56",
            firmwareFileName: "opensbi_fw_jump.bin",
            kernelFileName: "kernel-6.18.56-riscv64.bin",
            firmwareSHA256: FloeDigest.sha256Hex(firmware),
            kernelSHA256: FloeDigest.sha256Hex(kernel),
            firmwareBytes: Int64(firmware.count),
            kernelBytes: Int64(kernel.count)
        )
        let bundle = LinuxGuestBootAssetBundle(pair: pair)
        try firmware.write(to: dir.appendingPathComponent("opensbi_fw_jump.bin"))
        try Data("TAMPERED".utf8).write(to: dir.appendingPathComponent("kernel-6.18.56-riscv64.bin"))
        try JSONEncoder().encode(bundle).write(to: dir.appendingPathComponent("boot-pair-v2.manifest.json"))

        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { dir },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        await XCTAssertThrowsErrorAsync({
            try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.artifactVerificationFailed(let role) = error else {
                return XCTFail("expected artifactVerificationFailed, got \(error)")
            }
            XCTAssertEqual(role, "kernel")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.imageDirectory.appendingPathComponent("boot-assets.d").path
        ))
    }

    func testBundleFileNamesCollidingWithDefaultPairAreRejected() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-collision")
        let dir = fixture.root.appendingPathComponent("bundle-collision", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let firmware = Data("fw-v2".utf8)
        let kernel = Data("kernel-v2".utf8)
        // Collision with the manifest default pair name must be refused.
        let pair = LinuxGuestBootAssetPair(
            label: "collision", version: "6.18.56",
            firmwareFileName: "bbl64.bin",
            kernelFileName: "kernel-riscv64.bin",
            firmwareSHA256: FloeDigest.sha256Hex(firmware),
            kernelSHA256: FloeDigest.sha256Hex(kernel),
            firmwareBytes: Int64(firmware.count),
            kernelBytes: Int64(kernel.count)
        )
        let bundle = LinuxGuestBootAssetBundle(pair: pair)
        try firmware.write(to: dir.appendingPathComponent("bbl64.bin"))
        try kernel.write(to: dir.appendingPathComponent("kernel-riscv64.bin"))
        try JSONEncoder().encode(bundle).write(to: dir.appendingPathComponent("boot-pair-v2.manifest.json"))

        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { dir },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        await XCTAssertThrowsErrorAsync({
            try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.bundleMismatch = error else {
                return XCTFail("expected bundleMismatch, got \(error)")
            }
        }
        // The manifest default pair is untouched.
        XCTAssertEqual(try Data(contentsOf: fixture.biosURL), Data("bios-boot-assets-collision".utf8))
    }

    func testOlderBundleIsNotOfferedOverNewerInstalled() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-older")
        let new = try makeBundle(root: fixture.root, version: "6.18.56")
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { new.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        _ = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })

        let older = try makeBundle(root: fixture.root, version: "6.12.112")
        let downgrade = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { older.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        await XCTAssertThrowsErrorAsync({
            try await downgrade.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.notOffered = error else {
                return XCTFail("expected notOffered, got \(error)")
            }
        }
        // The original adoption still governs.
        let resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertTrue(resolved.biosPath.contains("boot-assets.d/"))
    }

    func testUninstalledImageIsRejected() async throws {
        let root = try makeTemporaryDirectory("boot-assets-missing")
        let bundle = try makeBundle(root: root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        await XCTAssertThrowsErrorAsync({
            try await service.installUpdate(imageID: "nope", environmentIDs: { _ in [] })
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.imageNotInstalled = error else {
                return XCTFail("expected imageNotInstalled, got \(error)")
            }
        }
    }

    // MARK: read-time fail-closed + persistence invariants

    func testTamperedAdoptedFilesFallBackToDefaultAtResolution() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-readback")
        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        _ = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })

        // Tamper with the adopted kernel bytes in place.
        let sidecar = try LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.imageDirectory)!
        let kernelURL = fixture.imageDirectory
            .appendingPathComponent(sidecar.storageDirectory, isDirectory: true)
            .appendingPathComponent(sidecar.pair.kernelFileName)
        try Data("CORRUPT".utf8).write(to: kernelURL)

        let resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertEqual(resolved.biosPath, "bbl64.bin", "tampered adopted kernel must fail closed to the default pair")

        let state = await service.state(imageID: fixture.id)
        guard case .installFailed(let failed) = state else {
            return XCTFail("expected installFailed after tamper, got \(state)")
        }
        XCTAssertNotNil(failed.failureReason)
    }

    func testAdoptionLeavesEnvironmentDiskAndOriginUntouched() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-persist")
        let writable = try makeTemporaryDirectory("boot-assets-persist-layer")
        let preparer = LinuxGuestRuntimeImagePreparer()
        let before = try preparer.prepare(
            image: fixture.manifest,
            imageDirectory: fixture.imageDirectory,
            environmentID: "env-persist",
            writableDirectory: writable,
            targetCapacityBytes: 64 * 1024 * 1024
        )
        let diskURL = URL(fileURLWithPath: try XCTUnwrap(before.diskPath))
        let diskDigestBefore = FloeDigest.sha512Hex(try Data(contentsOf: diskURL))
        let originBefore = try Data(contentsOf: LinuxGuestRuntimeImagePreparer
            .environmentDiskDirectory(writableDirectory: writable, environmentID: "env-persist")
            .appendingPathComponent("origin.json"))

        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        _ = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })

        let diskDigestAfter = FloeDigest.sha512Hex(try Data(contentsOf: diskURL))
        let originAfter = try Data(contentsOf: LinuxGuestRuntimeImagePreparer
            .environmentDiskDirectory(writableDirectory: writable, environmentID: "env-persist")
            .appendingPathComponent("origin.json"))
        XCTAssertEqual(diskDigestBefore, diskDigestAfter, "adoption must never touch an environment disk")
        XCTAssertEqual(originBefore, originAfter, "adoption must never touch disk origin provenance")
    }

    // MARK: pre-start auto-adoption hook

    func testPreStartHookFiresWithImageIDBeforeStart() async throws {
        // Light harness: fake environment provider + image resolver; the
        // session factory reply is never reached because start failure is
        // fine — the hook must still have fired with the descriptor's
        // imageID before the lease/start path proceeded.
        let envID = "env-hook"
        let imageID = "img-hook"
        let descriptor = LinuxGuestEnvironmentDescriptor(
            id: envID,
            ownerID: "owner",
            imageID: imageID
        )
        let fired = ProbeGate()
        let observedImageID = OrderRecorder()
        let registry = TinyEMULinuxGuestRegistry(
            environments: HookEnvProvider(descriptor: descriptor),
            images: HookImageResolver(),
            limits: .standard,
            factory: FailingSessionFactory(),
            bootAssetAutoAdoption: { _, imageID in
                await observedImageID.record(imageID)
                await fired.enter()
            }
        )
        _ = try? await registry.start(environmentID: envID, taskID: nil)
        await fired.wait()
        let observed = await observedImageID.values
        XCTAssertEqual(observed, [imageID], "the hook must fire with the descriptor's imageID before the start")
    }

    // MARK: Runtime v2 boot path uses the same verified pair resolution

    func testV2BootImageSelectsAdoptedPairAndRollbackRestoresDefault() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-v2boot")
        let workingDisk = fixture.root.appendingPathComponent("work-disk.img")
        try Data("working".utf8).write(to: workingDisk)

        // Default: manifest pair.
        let defaultBoot = try TinyEMULinuxGuestRegistry.v2BootImage(
            image: fixture.manifest,
            imageDirectory: fixture.imageDirectory,
            workingDisk: workingDisk
        )
        XCTAssertTrue(defaultBoot.biosPath.hasSuffix("bbl64.bin"))
        XCTAssertTrue(defaultBoot.kernelPath?.hasSuffix("kernel-riscv64.bin") == true)
        XCTAssertEqual(defaultBoot.diskPath, workingDisk.path)
        XCTAssertTrue(defaultBoot.diskReadWrite)

        // Adopt: v2 pair selected, working-disk boundary preserved.
        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        _ = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })
        let adoptedBoot = try TinyEMULinuxGuestRegistry.v2BootImage(
            image: fixture.manifest,
            imageDirectory: fixture.imageDirectory,
            workingDisk: workingDisk
        )
        XCTAssertTrue(adoptedBoot.biosPath.contains("boot-assets.d/"))
        XCTAssertTrue(adoptedBoot.kernelPath?.contains("boot-assets.d/") == true)
        XCTAssertEqual(adoptedBoot.diskPath, workingDisk.path, "working disk must never be rebased by a boot-pair adoption")

        // Rollback: default pair again on the v2 path.
        _ = try await service.rollback(imageID: fixture.id, environmentIDs: { _ in [] })
        let rolledBackBoot = try TinyEMULinuxGuestRegistry.v2BootImage(
            image: fixture.manifest,
            imageDirectory: fixture.imageDirectory,
            workingDisk: workingDisk
        )
        XCTAssertTrue(rolledBackBoot.biosPath.hasSuffix("bbl64.bin"))
        XCTAssertTrue(rolledBackBoot.kernelPath?.hasSuffix("kernel-riscv64.bin") == true)
    }

    // MARK: the App seam: the updater targets the directory the boot reads

    /// The App boots Runtime v2, which resolves boot paths against
    /// `images/expanded/<id>` — not the legacy images root the updater would
    /// otherwise write into (the v2 migration even moves that root aside).
    /// With the resolver wired, the sidecar and the adopted bytes must land
    /// in the resolved boot directory and every read must use it too.
    func testInjectedImageDirectoryResolverWritesWhereTheBootReads() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-resolver")
        let bundle = try makeBundle(root: fixture.root)

        // The "boot" directory stands in for Runtime v2's expanded image: a
        // different directory with its own verified manifest copy.
        let bootRoot = try makeTemporaryDirectory("boot-assets-expanded")
        let bootDirectory = bootRoot.appendingPathComponent(fixture.id, isDirectory: true)
        try FileManager.default.createDirectory(at: bootDirectory, withIntermediateDirectories: true)
        for name in ["bbl64.bin", "kernel-riscv64.bin", "initrd.img", "disk.img", "manifest.json"] {
            try FileManager.default.copyItem(
                at: fixture.imageDirectory.appendingPathComponent(name),
                to: bootDirectory.appendingPathComponent(name)
            )
        }

        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() },
            imageDirectoryResolver: { imageID in
                imageID == fixture.id ? bootDirectory : nil
            }
        )

        let state = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })
        guard case .updateInstalled(let sidecar) = state else {
            return XCTFail("expected updateInstalled, got \(state)")
        }
        XCTAssertEqual(sidecar.pair.version, "6.18.56")

        // Both the immutable storage directory and the sidecar land in the
        // resolved boot directory; the legacy root stays free of them.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bootDirectory.appendingPathComponent(sidecar.storageDirectory).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bootDirectory.appendingPathComponent("boot-assets.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.imageDirectory.appendingPathComponent("boot-assets.json").path
        ), "the sidecar must not land in a directory the boot never reads")

        // The boot-path reader in the resolved directory selects the pair.
        let adopted = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: bootDirectory
        )
        XCTAssertTrue(adopted.biosPath.contains("boot-assets.d/"))
        XCTAssertTrue(adopted.kernelPath?.hasSuffix("kernel-6.18.56-riscv64.bin") == true)

        // Reads resolve through the same seam: rollback + state see the
        // record written in the boot directory.
        _ = try await service.rollback(imageID: fixture.id, environmentIDs: { _ in [] })
        guard case .rolledBack = await service.state(imageID: fixture.id) else {
            return XCTFail("expected rolledBack read through the resolver")
        }
        let defaultBoot = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: bootDirectory
        )
        XCTAssertTrue(defaultBoot.biosPath.hasSuffix("bbl64.bin"))
        XCTAssertTrue(defaultBoot.kernelPath?.hasSuffix("kernel-riscv64.bin") == true)

        // Without a resolver the service keeps the historical legacy root:
        // the fixture's legacy directory has no sidecar (the record lives in
        // the resolved boot directory), so it reports the default pair.
        let legacyService = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        guard case .defaultPair = await legacyService.state(imageID: fixture.id) else {
            return XCTFail("expected legacy state read without a resolver")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.imageDirectory.appendingPathComponent("boot-assets.json").path
        ), "the legacy root still holds no sidecar for this fixture")
    }

    // MARK: start/update mutual exclusion (the real gate)

    func testCommitWaitsForOutstandingStartLease() async throws {
        let gate = LinuxGuestBootAssetGate()
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-gate")
        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() },
            gate: gate
        )

        let startHolding = ProbeGate()
        let startRelease = ProbeGate()
        let startDone = ProbeGate()
        // Hold a start lease for the image until the test releases it.
        let leaseTask = Task {
            try await gate.withStartLease(imageID: fixture.id, environmentID: "env-1") {
                await startHolding.enter()
                await startRelease.wait()
                await startDone.enter()
                return true
            }
        }
        await startHolding.wait()

        let commitDone = ProbeGate()
        let commitTask = Task {
            let state = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] })
            await commitDone.enter()
            return state
        }
        // The commit must not complete while the start lease is held.
        let premature = await commitDone.wait(timeoutNanoseconds: 400_000_000)
        XCTAssertFalse(premature, "commit completed while a start lease was outstanding")
        await startRelease.enter()
        _ = try await leaseTask.value
        await startDone.wait()
        let state = try await commitTask.value
        guard case .updateInstalled = state else {
            return XCTFail("expected updateInstalled, got \(state)")
        }
        await commitDone.wait()
    }

    func testStartLeaseWaitsForCommittingPass() async throws {
        let gate = LinuxGuestBootAssetGate()
        let commitHolding = ProbeGate()
        let commitRelease = ProbeGate()
        let startRan = ProbeGate()
        // Hold an exclusive pass directly (same gate the service uses).
        let commitTask = Task {
            try await gate.performExclusive(imageID: "img") {
                await commitHolding.enter()
                await commitRelease.wait()
                return 42
            }
        }
        await commitHolding.wait()
        // A start for the same image must wait until the pass completes.
        let startTask = Task {
            try await gate.withStartLease(imageID: "img", environmentID: "env-2") {
                await startRan.enter()
                return true
            }
        }
        let premature = await startRan.wait(timeoutNanoseconds: 400_000_000)
        XCTAssertFalse(premature, "start ran while a commit pass held the gate")
        await commitRelease.enter()
        let startResult = try await startTask.value
        XCTAssertTrue(startResult)
        _ = try await commitTask.value
        await startRan.wait()
    }

    func testTwoServicesSharingOneGateSerializeCommitsFIFO() async throws {
        let gate = LinuxGuestBootAssetGate()
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-fifo")
        let firstBundle = try makeBundle(root: fixture.root, version: "6.18.56", kernel: Data("kernel-561".utf8))
        let secondBundle = try makeBundle(root: fixture.root, version: "6.19.1", kernel: Data("kernel-691".utf8))
        let order = OrderRecorder()
        let serviceA = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { firstBundle.directory },
            quietProbe: { _ in makeQuietReconciliation() },
            gate: gate
        )
        let serviceB = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { secondBundle.directory },
            quietProbe: { _ in makeQuietReconciliation() },
            gate: gate
        )
        // Hold one pass so both installs queue in a stable, observable FIFO
        // order (A enqueues first, B second).
        let blockerEntered = ProbeGate()
        let blockerRelease = ProbeGate()
        let blocker = Task {
            try await gate.performExclusive(imageID: fixture.id) {
                await blockerEntered.enter()
                await blockerRelease.wait()
                return 0
            }
        }
        await blockerEntered.wait()
        let a = Task {
            _ = try await serviceA.installUpdate(imageID: fixture.id, environmentIDs: { _ in ["env-a"] })
            await order.record("a")
        }
        let aQueued = await waitForQueuedCommits(gate, imageID: fixture.id, atLeast: 2)
        XCTAssertTrue(aQueued, "service A never queued behind the held pass")
        let b = Task {
            _ = try await serviceB.installUpdate(imageID: fixture.id, environmentIDs: { _ in ["env-a"] })
            await order.record("b")
        }
        let bQueued = await waitForQueuedCommits(gate, imageID: fixture.id, atLeast: 3)
        XCTAssertTrue(bQueued, "service B never queued behind service A")
        await blockerRelease.enter()
        _ = try await blocker.value
        _ = try await a.value
        _ = try await b.value
        let observed = await order.values
        XCTAssertEqual(observed, ["a", "b"], "commits sharing one gate must serialize FIFO")
    }

    func testCancelledStartNeverRunsItsOperation() async throws {
        let gate = LinuxGuestBootAssetGate()
        let entered = ProbeGate()
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: makeTemporaryDirectoryForGateTest(),
            bundleProvider: { nil },
            quietProbe: { _ in makeQuietReconciliation() },
            gate: gate
        )
        _ = service
        // Hold an exclusive pass.
        let commitTask = Task {
            try await gate.performExclusive(imageID: "img") {
                await entered.enter()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return 42
            }
        }
        await entered.wait()
        let operationRan = OperationFlag()
        let startTask = Task {
            try await gate.withStartLease(imageID: "img", environmentID: "env") {
                await operationRan.set()
                return true
            }
        }
        // Let the start reach its waiter, then cancel it.
        try await Task.sleep(nanoseconds: 300_000_000)
        startTask.cancel()
        do {
            _ = try await startTask.value
            XCTFail("cancelled start should throw")
        } catch is CancellationError {
            // expected
        }
        let ran = await operationRan.value
        XCTAssertFalse(ran, "a cancelled start must never run its operation")
        _ = try await commitTask.value
        // After the pass completes, a fresh start proceeds normally.
        let after = try await gate.withStartLease(imageID: "img", environmentID: "env2") { true }
        XCTAssertTrue(after)
    }

    func testExclusiveInsideStartLeaseFailsFast() async throws {
        let gate = LinuxGuestBootAssetGate()
        do {
            _ = try await gate.withStartLease(imageID: "img", environmentID: "env") {
                try await gate.performExclusive(imageID: "img") { 1 }
            }
            XCTFail("expected imageBusy reentrancy refusal")
        } catch let error as LinuxGuestBootAssetUpdateError {
            guard case .imageBusy = error else {
                return XCTFail("expected imageBusy, got \(error)")
            }
        }
    }

    func testSecondConcurrentOperationForSameImageIsRefused() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-conc")
        let bundle = try makeBundle(root: fixture.root)
        let gate = ProbeGate()
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in
                await gate.enter()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return makeQuietReconciliation()
            }
        )
        let first = Task {
            try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in ["env-a"] })
        }
        await gate.wait()
        await XCTAssertThrowsErrorAsync({
            try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in ["env-a"] })
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.imageBusy = error else {
                return XCTFail("expected imageBusy, got \(error)")
            }
        }
        _ = try await first.value
    }

    // MARK: automatic policy vs explicit reapply (real pre-start sequence)

    func testAutomaticPreStartAdoptionRespectsExplicitRollbackUntilReapply() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-auto-policy")
        let bundle = try makeBundle(root: fixture.root, version: "6.18.56")
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        let environmentID = "env-auto-policy"
        let descriptor = LinuxGuestEnvironmentDescriptor(
            id: environmentID, ownerID: "owner", imageID: fixture.id
        )
        // The registry hook is the App's real automatic path: it runs at the
        // top of every start on the same verified service with origin
        // `.automatic`.
        let registry = TinyEMULinuxGuestRegistry(
            environments: HookEnvProvider(descriptor: descriptor),
            images: HookImageResolver(),
            limits: .standard,
            factory: FailingSessionFactory(),
            bootAssetAutoAdoption: { _, imageID in
                _ = try? await service.installUpdate(
                    imageID: imageID,
                    environmentIDs: { _ in [environmentID] },
                    origin: .automatic
                )
            }
        )

        // 1. A pre-start automatic pass adopts the verified bundle.
        _ = try? await registry.start(environmentID: environmentID, taskID: nil)
        var resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertTrue(
            resolved.biosPath.contains("boot-assets.d/"),
            "the automatic pre-start pass must adopt the verified pair, got \(resolved.biosPath)"
        )

        // 2. Explicit rollback to the manifest default pair.
        _ = try await service.rollback(imageID: fixture.id, environmentIDs: { _ in [environmentID] })

        // 3. The NEXT start's automatic pass must NOT re-adopt the same
        //    bundle: the explicit rollback sticks.
        _ = try? await registry.start(environmentID: environmentID, taskID: nil)
        resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertEqual(
            resolved.biosPath, "bbl64.bin",
            "automatic pre-start adoption re-opened an explicit rollback"
        )
        XCTAssertEqual(resolved.kernelPath, "kernel-riscv64.bin")
        let afterRollback = await service.state(imageID: fixture.id)
        guard case .rolledBack = afterRollback else {
            return XCTFail("expected the rollback marker to persist, got \(afterRollback)")
        }

        // 4. An EXPLICIT reapply re-adopts the same bundle.
        let reapplied = try await service.installUpdate(
            imageID: fixture.id,
            environmentIDs: { _ in [environmentID] },
            origin: .explicitReapply
        )
        guard case .updateInstalled(let sidecar) = reapplied else {
            return XCTFail("expected updateInstalled after explicit reapply, got \(reapplied)")
        }
        XCTAssertEqual(sidecar.pair.version, "6.18.56")
        resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertTrue(resolved.biosPath.contains("boot-assets.d/"))

        // 5. A further automatic pre-start pass keeps the (now adopted) pair.
        _ = try? await registry.start(environmentID: environmentID, taskID: nil)
        resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertTrue(resolved.biosPath.contains("boot-assets.d/"))
    }

    func testOlderBundleNeverOverwritesNewerRecordForEitherOrigin() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-newer-wins")
        let newer = try makeBundle(root: fixture.root, version: "6.19.1", kernel: Data("kernel-newer".utf8))
        let newerService = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { newer.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        _ = try await newerService.installUpdate(
            imageID: fixture.id, environmentIDs: { _ in [] }, origin: .automatic
        )
        let older = try makeBundle(root: fixture.root, version: "6.18.56", kernel: Data("kernel-older".utf8))
        let olderService = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { older.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )

        // (a) Newer ADOPTED: neither origin may downgrade it.
        for origin in [LinuxGuestBootAssetAdoptionOrigin.automatic, .explicitReapply] {
            await XCTAssertThrowsErrorAsync({
                try await olderService.installUpdate(
                    imageID: fixture.id, environmentIDs: { _ in [] }, origin: origin
                )
            }) { error in
                guard case LinuxGuestBootAssetUpdateError.notOffered = error else {
                    return XCTFail("expected notOffered for \(origin), got \(error)")
                }
            }
        }
        var resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertTrue(resolved.biosPath.contains("boot-assets.d/"))

        // (b) Newer ROLLED BACK: the marker still outranks the older bundle.
        _ = try await newerService.rollback(imageID: fixture.id, environmentIDs: { _ in [] })
        for origin in [LinuxGuestBootAssetAdoptionOrigin.automatic, .explicitReapply] {
            await XCTAssertThrowsErrorAsync({
                try await olderService.installUpdate(
                    imageID: fixture.id, environmentIDs: { _ in [] }, origin: origin
                )
            }) { error in
                guard case LinuxGuestBootAssetUpdateError.notOffered = error else {
                    return XCTFail("expected notOffered over a newer rollback marker for \(origin), got \(error)")
                }
            }
        }
        resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertEqual(resolved.biosPath, "bbl64.bin")
        let sidecar = try XCTUnwrap(
            LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.imageDirectory)
        )
        XCTAssertEqual(sidecar.pair.version, "6.19.1")
        XCTAssertEqual(sidecar.state, .rolledBack)
    }

    // MARK: cross-service TOCTOU (queued older pass must not downgrade)

    func testQueuedOlderServiceCannotDowngradeNewerCommit() async throws {
        let gate = LinuxGuestBootAssetGate()
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-toctou")
        let newer = try makeBundle(root: fixture.root, version: "6.19.1", kernel: Data("kernel-691".utf8))
        let older = try makeBundle(root: fixture.root, version: "6.18.56", kernel: Data("kernel-561".utf8))
        let newerService = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { newer.directory },
            quietProbe: { _ in makeQuietReconciliation() },
            gate: gate
        )
        let olderService = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { older.directory },
            quietProbe: { _ in makeQuietReconciliation() },
            gate: gate
        )
        // Line both installs up deterministically behind a held pass: the
        // FIFO order (newer first, older queued) is proven by the gate's own
        // queue count, never by sleeping.
        let blockerEntered = ProbeGate()
        let blockerRelease = ProbeGate()
        let blocker = Task {
            try await gate.performExclusive(imageID: fixture.id) {
                await blockerEntered.enter()
                await blockerRelease.wait()
                return 0
            }
        }
        await blockerEntered.wait()

        let first = Task {
            try await newerService.installUpdate(imageID: fixture.id, environmentIDs: { _ in ["env-a"] })
        }
        let firstQueued = await waitForQueuedCommits(gate, imageID: fixture.id, atLeast: 2)
        XCTAssertTrue(firstQueued, "the newer install never queued behind the held pass")
        let second = Task {
            try await olderService.installUpdate(imageID: fixture.id, environmentIDs: { _ in ["env-b"] })
        }
        let secondQueued = await waitForQueuedCommits(gate, imageID: fixture.id, atLeast: 3)
        XCTAssertTrue(secondQueued, "the older install never queued behind the newer one")

        await blockerRelease.enter()
        _ = try await blocker.value
        let committed = try await first.value
        guard case .updateInstalled(let sidecar) = committed else {
            return XCTFail("expected the newer install to commit, got \(committed)")
        }
        XCTAssertEqual(sidecar.pair.version, "6.19.1")

        // The queued older pass passed its pre-check before the newer commit
        // landed; its authoritative in-pass recheck must refuse it.
        await XCTAssertThrowsErrorAsync({ try await second.value }) { error in
            guard case LinuxGuestBootAssetUpdateError.notOffered = error else {
                return XCTFail("expected notOffered inside the queued pass, got \(error)")
            }
        }
        let resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertTrue(
            resolved.biosPath.contains(sidecar.storageDirectory),
            "the newer pair must still govern after the queued older pass, got \(resolved.biosPath)"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.imageDirectory
                .appendingPathComponent(
                    LinuxGuestBootAssetUpdateService.storageDirectoryName(for: older.bundle.pair)
                ).path
        ), "the downgraded pair's storage must never be created")
    }

    // MARK: failure atomicity + storage verification

    func testInjectedCommitFailurePreservesPreexistingReferencedPayload() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-atomic")
        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        _ = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] }, origin: .automatic)
        _ = try await service.rollback(imageID: fixture.id, environmentIDs: { _ in [] })
        let before = try XCTUnwrap(
            LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.imageDirectory)
        )
        let storage = fixture.imageDirectory.appendingPathComponent(before.storageDirectory, isDirectory: true)
        let firmwareBefore = try Data(contentsOf: storage.appendingPathComponent(before.pair.firmwareFileName))
        let kernelBefore = try Data(contentsOf: storage.appendingPathComponent(before.pair.kernelFileName))

        // Real I/O failure injected at the single commit point: the sidecar
        // write cannot land.
        await service.setCommitFaultInjector { stage in
            guard stage == .beforeSidecarWrite else { return }
            struct InjectedIOFailure: Error {}
            throw InjectedIOFailure()
        }
        await XCTAssertThrowsErrorAsync({
            try await service.installUpdate(
                imageID: fixture.id,
                environmentIDs: { _ in [] },
                origin: .explicitReapply
            )
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.ioFailure = error else {
                return XCTFail("expected ioFailure at the commit point, got \(error)")
            }
        }
        await service.setCommitFaultInjector(nil)

        // The preexisting verified payload (still referenced by the
        // rolled-back record) and that record are byte-for-byte unchanged.
        XCTAssertEqual(
            try Data(contentsOf: storage.appendingPathComponent(before.pair.firmwareFileName)), firmwareBefore
        )
        XCTAssertEqual(
            try Data(contentsOf: storage.appendingPathComponent(before.pair.kernelFileName)), kernelBefore
        )
        let after = try XCTUnwrap(
            LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.imageDirectory)
        )
        XCTAssertEqual(after.state, .rolledBack)
        XCTAssertEqual(after.pair.version, before.pair.version)
        XCTAssertEqual(after.storageDirectory, before.storageDirectory)

        // The retry without the fault adopts normally.
        let retried = try await service.installUpdate(
            imageID: fixture.id, environmentIDs: { _ in [] }, origin: .explicitReapply
        )
        guard case .updateInstalled = retried else {
            return XCTFail("expected the retry to adopt, got \(retried)")
        }
    }

    func testCorruptExistingStorageIsReplacedByVerifiedBytesOnReapply() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-replace")
        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        _ = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] }, origin: .automatic)
        _ = try await service.rollback(imageID: fixture.id, environmentIDs: { _ in [] })
        let sidecar = try XCTUnwrap(
            LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.imageDirectory)
        )
        let storage = fixture.imageDirectory.appendingPathComponent(sidecar.storageDirectory, isDirectory: true)
        // Corrupt the adopted kernel in place (same content address, wrong
        // bytes): reuse must verify BOTH files, not mere existence.
        try Data("CORRUPT-PAYLOAD".utf8)
            .write(to: storage.appendingPathComponent(sidecar.pair.kernelFileName))
        XCTAssertEqual(
            LinuxGuestBootAssetUpdateService.storageIntegrity(storage, pair: sidecar.pair), false,
            "corrupt storage must be provably invalid"
        )

        let reapplied = try await service.installUpdate(
            imageID: fixture.id, environmentIDs: { _ in [] }, origin: .explicitReapply
        )
        guard case .updateInstalled = reapplied else {
            return XCTFail("expected the reapply to repair and adopt, got \(reapplied)")
        }
        XCTAssertEqual(
            try Data(contentsOf: storage.appendingPathComponent(sidecar.pair.kernelFileName)),
            Data("kernel-v2".utf8),
            "the canonical storage directory must hold the freshly verified bundle bytes"
        )
        XCTAssertEqual(LinuxGuestBootAssetUpdateService.storageIntegrity(storage, pair: sidecar.pair), true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.imageDirectory.path)
            .filter { $0.hasPrefix(".boot-assets-") }
        XCTAssertTrue(leftovers.isEmpty, "unexpected staging/quarantine leftovers: \(leftovers)")
        let resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.manifest, imageDirectory: fixture.imageDirectory
        )
        XCTAssertTrue(resolved.biosPath.contains("boot-assets.d/"))
    }

    func testUnprovableExistingStorageRefusesWithoutTouchingBytes() async throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-unprovable")
        let bundle = try makeBundle(root: fixture.root)
        let service = LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.root,
            bundleProvider: { bundle.directory },
            quietProbe: { _ in makeQuietReconciliation() }
        )
        _ = try await service.installUpdate(imageID: fixture.id, environmentIDs: { _ in [] }, origin: .automatic)
        _ = try await service.rollback(imageID: fixture.id, environmentIDs: { _ in [] })
        let sidecar = try XCTUnwrap(
            LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.imageDirectory)
        )
        let storage = fixture.imageDirectory.appendingPathComponent(sidecar.storageDirectory, isDirectory: true)
        let kernelBefore = try Data(contentsOf: storage.appendingPathComponent(sidecar.pair.kernelFileName))
        // Replace the storage DIRECTORY with a regular file at the same path:
        // the content can neither be reused nor proven, so the install must
        // refuse instead of guessing (and never delete anything).
        let parking = fixture.root.appendingPathComponent("parked-storage", isDirectory: true)
        try FileManager.default.moveItem(at: storage, to: parking)
        try Data("not-a-directory".utf8).write(to: storage)

        await XCTAssertThrowsErrorAsync({
            try await service.installUpdate(
                imageID: fixture.id, environmentIDs: { _ in [] }, origin: .explicitReapply
            )
        }) { error in
            guard case LinuxGuestBootAssetUpdateError.artifactVerificationFailed(let role) = error else {
                return XCTFail("expected artifactVerificationFailed, got \(error)")
            }
            XCTAssertEqual(role, "existing boot-asset storage")
        }
        XCTAssertEqual(try Data(contentsOf: storage), Data("not-a-directory".utf8))
        XCTAssertEqual(
            try Data(contentsOf: parking.appendingPathComponent(sidecar.pair.kernelFileName)), kernelBefore
        )
        let after = try XCTUnwrap(
            LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.imageDirectory)
        )
        XCTAssertEqual(after.state, .rolledBack)
    }

    func testStorageIdentityIncludesBothPairHashes() throws {
        let fixture = try makeRuntimeImageFixture(name: "boot-assets-identity")
        let first = try makeBundle(root: fixture.root, version: "6.18.56", firmware: Data("fw-a".utf8), kernel: Data("kernel-same".utf8))
        let second = try makeBundle(root: fixture.root, version: "6.18.56", firmware: Data("fw-b".utf8), kernel: Data("kernel-same".utf8))
        let firstName = LinuxGuestBootAssetUpdateService.storageDirectoryName(for: first.bundle.pair)
        let secondName = LinuxGuestBootAssetUpdateService.storageDirectoryName(for: second.bundle.pair)
        XCTAssertNotEqual(
            firstName, secondName,
            "same version + same kernel with different firmware must not share one content address"
        )
        XCTAssertTrue(firstName.contains(String(first.bundle.pair.firmwareSHA256.prefix(12))))
        XCTAssertTrue(firstName.contains(String(first.bundle.pair.kernelSHA256.prefix(12))))
    }

    func testVersionEqualityIsStrictAndUnparseableIsNeverEqual() {
        XCTAssertTrue(LinuxGuestBootAssetUpdateService.isVersion("6.18.56", sameAs: "6.18.56.0"))
        XCTAssertFalse(LinuxGuestBootAssetUpdateService.isVersion("6.18.57", sameAs: "6.18.56"))
        XCTAssertFalse(LinuxGuestBootAssetUpdateService.isVersion("six", sameAs: "six"))
        XCTAssertFalse(LinuxGuestBootAssetUpdateService.isVersion("6.18.56", sameAs: "six"))
    }

    // MARK: lifecycle-transaction restart uses the same boot-asset entry

    func testLifecycleTransactionReplacementStartHoldsTheBootAssetLeaseAndRunsTheHook() async throws {
        final class BlockingImageResolver: LinuxGuestImageResolving {
            let entered = ProbeGate()
            let release = ProbeGate()
            func linuxGuestImage(id: String) async -> LinuxGuestImage? {
                await entered.enter()
                await release.wait()
                return nil
            }
            func linuxGuestImageVerificationFailure(id: String) async -> String? { nil }
        }
        struct LifecycleEnvProvider: LinuxGuestEnvironmentProviding {
            let descriptor: LinuxGuestEnvironmentDescriptor
            func linuxGuestEnvironment(id: String) async -> LinuxGuestEnvironmentDescriptor? {
                id == descriptor.id ? descriptor : nil
            }
        }
        // No VM/resolver work: the replacement start blocks inside the image
        // resolver, which runs while (and only while) the start holds its
        // boot-asset lease.
        let imageID = "img-lifecycle"
        let environmentID = "env-lifecycle"
        let descriptor = LinuxGuestEnvironmentDescriptor(
            id: environmentID, ownerID: "owner", imageID: imageID
        )
        let resolver = BlockingImageResolver()
        let gate = LinuxGuestBootAssetGate()
        let hookCalls = OrderRecorder()
        let registry = TinyEMULinuxGuestRegistry(
            environments: LifecycleEnvProvider(descriptor: descriptor),
            images: resolver,
            limits: .standard,
            factory: FailingSessionFactory(),
            bootAssetGate: gate,
            bootAssetAutoAdoption: { _, imageID in
                await hookCalls.record(imageID)
            }
        )
        let token = try await registry.beginLifecycleTransaction(environmentID: environmentID)
        let replacement = Task {
            try await registry.startForLifecycleTransaction(
                environmentID: environmentID, token: token, taskID: nil, shape: nil
            )
        }
        // The replacement reaches the image resolver — i.e. it is inside the
        // start operation, past the hook and the lease acquisition.
        await resolver.entered.wait()
        let observed = await hookCalls.values
        XCTAssertEqual(observed, [imageID], "the lifecycle replacement start must run the boot-asset auto-adoption hook")

        // While the replacement start holds its lease, an exclusive commit
        // pass for the same image must wait: the ACTUAL lifecycle entry (not
        // just the generic gate helper) takes the lease.
        let commitEntered = ProbeGate()
        let commit = Task {
            try await gate.performExclusive(imageID: imageID) {
                await commitEntered.enter()
                return 0
            }
        }
        let premature = await commitEntered.wait(timeoutNanoseconds: 400_000_000)
        XCTAssertFalse(
            premature,
            "a commit pass ran while the lifecycle replacement start held its boot-asset lease"
        )

        // Release the start; its own failure releases the lease and the
        // queued commit proceeds.
        await resolver.release.enter()
        _ = try? await replacement.value
        _ = try await commit.value
        await commitEntered.wait()
        await registry.endLifecycleTransaction(environmentID: environmentID, token: token)
    }
}

private func makeTemporaryDirectoryForGateTest() -> URL {
    // Fire-and-forget temp root; tests only need a valid imagesRoot path.
    FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-gate-test-\(UUID().uuidString)", isDirectory: true)
}

/// Bounded wait until the gate reports at least `count` queued exclusive
/// passes for one image. This observes the gate's own FIFO registration
/// (not a sleep), so a test can line two independent services up
/// deterministically.
private func waitForQueuedCommits(
    _ gate: LinuxGuestBootAssetGate,
    imageID: String,
    atLeast count: Int,
    timeoutNanoseconds: UInt64 = 5_000_000_000
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while true {
        if await gate.queuedCommitCount(imageID: imageID) >= count { return true }
        if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

private actor ProbeGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        let resumed = waiters
        waiters.removeAll()
        resumed.forEach { $0.resume() }
    }

    func wait() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Returns true if the gate was entered within the budget (polls;
    /// only used for negative assertions).
    func wait(timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while true {
            if await isEntered { return true }
            if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private var isEntered: Bool { entered }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error but none was thrown", file: file, line: line)
    } catch {
        handler(error)
    }
}


/// Session factory whose every start fails fast; enough for hook tests.
private struct FailingSessionFactory: LinuxGuestSessionCreating {
    func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle {
        struct NotAvailable: Error {}
        throw NotAvailable()
    }
}

/// Fake environment provider for the pre-start hook harness: one descriptor.
private final class HookEnvProvider: LinuxGuestEnvironmentProviding {
    let descriptor: LinuxGuestEnvironmentDescriptor
    init(descriptor: LinuxGuestEnvironmentDescriptor) { self.descriptor = descriptor }
    func linuxGuestEnvironment(id: String) async -> LinuxGuestEnvironmentDescriptor? {
        id == descriptor.id ? descriptor : nil
    }
}

/// Image resolver that never has an image: the session factory reply is
/// never reached, but the boot-path resolution point is.
private struct HookImageResolver: LinuxGuestImageResolving {
    func linuxGuestImage(id: String) async -> LinuxGuestImage? { nil }
    func linuxGuestImageVerificationFailure(id: String) async -> String? { nil }
}

private actor OperationFlag {
    private(set) var value = false
    func set() { value = true }
}

private actor OrderRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
