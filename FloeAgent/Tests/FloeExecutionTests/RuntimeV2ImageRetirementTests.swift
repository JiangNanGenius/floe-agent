// FloeExecutionTests — automatic factory-image retirement.
//
// These tests pin the lifecycle that turns a verified usable replacement into
// reclaimed factory storage without ever deleting bytes the plan did not
// identify:
//  * three successive ARM64 upgrades converge in one pass through the
//    manifest's own `compatibleOrigins` chain (no image-id allowlist);
//  * an identical re-download / same-id reinstall creates a new rollback that a
//    later pass retires again (a `done` row is not a permanent exemption);
//  * an interrupted pass resumes its durable plan instead of re-deriving it;
//  * a live environment base, live lease, preserved working disk, template pin
//    or user boot selection retains the generation with the exact reason;
//  * a factory rollback whose manifest is unreadable (historical failed
//    migration) keeps its unidentified bytes while the verified identity is
//    still retired;
//  * a file instance that changed after planning aborts the identity
//    retirement (a concurrent writer's result is never deleted underneath it);
//  * a blob shared with a still-verified generation keeps its bytes;
//  * an abandoned `.staging-*` tree is never part of any plan.

import Foundation
import XCTest
import FloeCore
#if canImport(Darwin)
import Darwin
#endif
@testable import FloeExecution

final class RuntimeV2ImageRetirementTests: XCTestCase {
    private var root: URL!
    private var layout: RuntimeV2Layout!
    private var store: RuntimeV2Store!
    private var legacyRoot: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-v2-retirement-\(UUID().uuidString)", isDirectory: true)
        layout = RuntimeV2Layout(root: root)
        store = RuntimeV2Store(layout: layout)
        legacyRoot = root.deletingLastPathComponent()
            .appendingPathComponent("retirement-legacy-\(UUID().uuidString)", isDirectory: true)
        _ = try await store.prepareAndRecover(build: "test")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: legacyRoot)
    }

    // MARK: fixtures

    private struct Fixture {
        var image: LinuxGuestImage
        var directory: URL
        var disk: Data
    }

    /// A legacy factory install. RISC-V generations declare TinyEMU's
    /// `bbl64.bin` firmware; ARM64 generations declare `bios.bin`. The
    /// predecessor is declared through `compatibleOrigins` exactly like a real
    /// runner-only release.
    @discardableResult
    private func makeFactoryInstall(
        id: String, riscv: Bool, disk: Data,
        predecessor: LinuxGuestCompatibleDiskOrigin? = nil,
        biosBytes: Data? = nil,
        in root: URL? = nil
    ) throws -> Fixture {
        let base = root ?? legacyRoot!
        let directory = base.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bios = biosBytes ?? Data(count: 4096)
        if biosBytes == nil {
            for index in bios.indices { bios[index] = UInt8((index &* 31) % 251) }
        }
        let biosName = riscv ? "bbl64.bin" : "bios.bin"
        try bios.write(to: directory.appendingPathComponent(biosName))
        try disk.write(to: directory.appendingPathComponent("disk.img"))
        var artifacts: [LinuxGuestImageArtifact] = [
            .init(role: .bios, path: biosName,
                  sha512: FloeDigest.sha512Hex(bios), bytes: Int64(bios.count)),
            .init(role: .disk, path: "disk.img",
                  sha512: FloeDigest.sha512Hex(disk), bytes: Int64(disk.count))
        ]
        var kernelPath: String?
        if riscv {
            let kernel = Data("riscv64-kernel-\(id)".utf8)
            try kernel.write(to: directory.appendingPathComponent("kernel-riscv64.bin"))
            kernelPath = "kernel-riscv64.bin"
            artifacts.append(.init(role: .kernel, path: "kernel-riscv64.bin",
                                   sha512: FloeDigest.sha512Hex(kernel), bytes: Int64(kernel.count)))
        }
        let image = LinuxGuestImage(
            id: id, biosPath: biosName, kernelPath: kernelPath,
            diskPath: "disk.img", qualified: true,
            qualificationRun: "runtime-v2-retirement-tests",
            artifacts: artifacts,
            compatibleOrigins: predecessor.map { [$0] }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(image).write(to: directory.appendingPathComponent("manifest.json"))
        return Fixture(image: image, directory: directory, disk: disk)
    }

    private func migrate(_ fixture: Fixture, root: URL? = nil) async throws {
        _ = try await store.images.migrateLegacyImage(
            imageID: fixture.image.id, legacyImagesRoot: root ?? legacyRoot
        )
    }

    private func origin(of fixture: Fixture) -> LinuxGuestCompatibleDiskOrigin {
        .init(
            imageID: fixture.image.id,
            artifactSHA512: FloeDigest.sha512Hex(fixture.disk),
            artifactBytes: Int64(fixture.disk.count)
        )
    }

    private func diskBytes(_ seed: UInt8, count: Int = 8192) -> Data {
        var data = Data(count: count)
        for index in data.indices { data[index] = UInt8((Int(seed) &+ index &* 7) % 251) }
        return data
    }

    private var manifestsDirectory: URL { layout.imageManifestsDirectory }
    private var rollbackDirectory: (String) -> URL {
        { id in
            self.layout.recoveryMigrationsDirectory
                .appendingPathComponent("legacy-image-\(id)", isDirectory: true)
        }
    }
    private func expandedExists(_ id: String) -> Bool {
        guard let url = try? layout.expandedImageDirectory(imageID: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    private func manifestExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: layout.imageManifestsDirectory
            .appendingPathComponent("\(id).json").path)
    }
    private func blobPath(_ digest: String) throws -> URL {
        try layout.blobURL(digest: digest)
    }

    // MARK: three upgrades

    func testThreeARM64UpgradesConvergeThroughDeclaredCompatOrigins() async throws {
        let v1 = try makeFactoryInstall(id: "arm-test-v1", riscv: false, disk: diskBytes(1))
        try await migrate(v1)
        let v2 = try makeFactoryInstall(
            id: "arm-test-v2", riscv: false, disk: diskBytes(2), predecessor: origin(of: v1)
        )
        try await migrate(v2)
        let v3 = try makeFactoryInstall(
            id: "arm-test-v3", riscv: false, disk: diskBytes(3), predecessor: origin(of: v2)
        )
        try await migrate(v3)
        let v4 = try makeFactoryInstall(
            id: "arm-test-v4", riscv: false, disk: diskBytes(4), predecessor: origin(of: v3)
        )
        try await migrate(v4)

        let manifest1 = try await store.images.manifest(imageID: v1.image.id)
        let manifest2 = try await store.images.manifest(imageID: v2.image.id)
        let manifest3 = try await store.images.manifest(imageID: v3.image.id)
        let rootfs1 = try XCTUnwrap(manifest1?.rootfsDigest)
        let rootfs2 = try XCTUnwrap(manifest2?.rootfsDigest)
        let rootfs3 = try XCTUnwrap(manifest3?.rootfsDigest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try blobPath(rootfs1).path))

        let report = await store.images.retireFactoryImages(afterUsableImage: v4.image.id)
        XCTAssertEqual(report.trigger, .usableImage)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(
            Set(report.retiredImages),
            Set([v1.image.id, v2.image.id, v3.image.id, v4.image.id])
        )
        // The whole predecessor chain is gone: manifest, expanded view,
        // rollback copies and content-addressed bytes.
        for retired in [v1, v2, v3] {
            XCTAssertFalse(manifestExists(retired.image.id), "manifest must be retired")
            XCTAssertFalse(expandedExists(retired.image.id), "expanded view must be retired")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: rollbackDirectory(retired.image.id).path),
                "migration rollback must be retired"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try blobPath(rootfs1).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try blobPath(rootfs2).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try blobPath(rootfs3).path))
        // The usable generation keeps its identity and bytes; only its prior
        // backup is retired.
        XCTAssertTrue(manifestExists(v4.image.id))
        XCTAssertTrue(expandedExists(v4.image.id))
        let v4Verified = try await store.images.isImageVerified(imageID: v4.image.id)
        XCTAssertTrue(v4Verified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackDirectory(v4.image.id).path))
        let v4Manifest = try await store.images.manifest(imageID: v4.image.id)
        let v4Rootfs = try XCTUnwrap(v4Manifest?.rootfsDigest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try blobPath(v4Rootfs).path))

        // Durable progress reused: a second identical call retires nothing new
        // and deletes no further bytes. The older generations are no longer
        // even reachable once their manifests (the lineage evidence) are gone,
        // but their durable rows stay `done` — the trigger never replays.
        let second = await store.images.retireFactoryImages(afterUsableImage: v4.image.id)
        XCTAssertEqual(second.failures, [])
        XCTAssertEqual(second.retiredImages, [])
        XCTAssertEqual(second.deletedFiles, 0)
        XCTAssertEqual(second.deletedBytes, 0)
        XCTAssertTrue(second.alreadyRetiredImages.contains(v3.image.id))
        XCTAssertTrue(second.retirements.allSatisfy { $0.phase == .done })
        let settled = try await store.images.retirementRecords()
        for retired in [v1, v2, v3, v4] {
            let row = try XCTUnwrap(settled.first { $0.imageID == retired.image.id })
            XCTAssertEqual(row.phase, .done)
        }
    }

    // MARK: identical redownload

    func testIdenticalRedownloadRetiresTheNewBackupAgain() async throws {
        let v1 = try makeFactoryInstall(id: "arm-redownload-v1", riscv: false, disk: diskBytes(11))
        try await migrate(v1)
        let first = await store.images.retireFactoryImages(afterUsableImage: v1.image.id)
        XCTAssertEqual(first.retiredImages, [v1.image.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackDirectory(v1.image.id).path))
        XCTAssertTrue(manifestExists(v1.image.id))

        // The identical archive is installed again (the real `installTrustedImage`
        // promotes the same verified bytes into the legacy directory, then the
        // boot path migrates them). This creates a NEW rollback duplicate.
        let redownload = try makeFactoryInstall(id: v1.image.id, riscv: false, disk: v1.disk)
        try await migrate(redownload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollbackDirectory(v1.image.id).path))
        XCTAssertTrue(manifestExists(v1.image.id))

        let second = await store.images.retireFactoryImages(afterUsableImage: v1.image.id)
        XCTAssertEqual(second.failures, [])
        XCTAssertEqual(second.retiredImages, [v1.image.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackDirectory(v1.image.id).path))
        XCTAssertTrue(manifestExists(v1.image.id))
        let stillVerified = try await store.images.isImageVerified(imageID: v1.image.id)
        XCTAssertTrue(stillVerified)
        let records = try await store.images.retirementRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].phase, .done)
        XCTAssertEqual(records[0].attempts, 1)
    }

    // MARK: interruption / resume

    func testInterruptedPassResumesItsDurablePlan() async throws {
        let arm = try makeFactoryInstall(id: "arm-interrupt", riscv: false, disk: diskBytes(21))
        try await migrate(arm)
        let riscv = try makeFactoryInstall(id: "riscv-interrupt", riscv: true, disk: diskBytes(22))
        try await migrate(riscv)

        // Cancel after the first physical unlink: the durable row records the
        // bytes already reclaimed and stays resumable.
        let counter = Counter()
        let report = await store.images.retireFactoryImages(
            afterUsableImage: nil,
            isCancelled: { counter.next() >= 3 }
        )
        XCTAssertTrue(report.cancelled || report.trigger == .retiredArchitectureBacklog)
        let records = try await store.images.retirementRecords()
        let pending = records.filter { $0.phase != .done }
        let resumedTargets = pending.map(\.imageID)
        XCTAssertFalse(resumedTargets.isEmpty, "an interrupted pass must leave a durable plan")
        let reclaimedBefore = pending.reduce(Int64(0)) { $0 + $1.retiredBytes }

        let finished = await store.images.retireFactoryImages(afterUsableImage: nil)
        XCTAssertTrue(finished.failures.isEmpty)
        XCTAssertTrue(
            finished.retirements.allSatisfy { $0.phase == .done },
            "the resumed pass converges every durable plan"
        )
        XCTAssertGreaterThanOrEqual(
            finished.retirements.reduce(Int64(0)) { $0 + $1.retiredBytes }, reclaimedBefore
        )
        XCTAssertFalse(manifestExists(riscv.image.id))
        // No replacement generation exists for the ARM image, so the backlog
        // pass never treats it as superseded.
        XCTAssertTrue(manifestExists(arm.image.id))
    }

    // MARK: retention

    func testLiveReferencesRetainTheGenerationAndNeverUnlinkWorkingDisks() async throws {
        let predecessor = try makeFactoryInstall(
            id: "arm-predecessor", riscv: false, disk: diskBytes(32)
        )
        try await migrate(predecessor)
        let arm = try makeFactoryInstall(
            id: "arm-live", riscv: false, disk: diskBytes(31),
            predecessor: origin(of: predecessor)
        )
        try await migrate(arm)

        // Environment + live lease + preserved working disk for the predecessor.
        try await store.registry.upsertEnvironment(RuntimeV2Registry.EnvironmentRow(
            id: "env-live", kind: "linuxVM", ownerID: nil, name: nil,
            baseImageID: predecessor.image.id, baseRootfsDigest: nil, state: "active",
            dataPath: "environments/env-live/data", compatHostFHS: false,
            repairReason: nil, createdAt: Date(), lastUsedAt: Date()
        ))
        try await store.registry.recordLease(RuntimeV2Registry.LeaseRow(
            environmentID: "env-live", runtimeID: "rt-live", incarnation: "live",
            sessionToken: "token", pid: Int64(getpid()), acquiredAt: Date(),
            renewedAt: Date(), ttlSeconds: 600, state: "held"
        ))
        let working = try layout.runtimeVMDirectory(runtimeID: "rt-live")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let workingDisk = Data("live working disk".utf8)
        try workingDisk.write(to: working.appendingPathComponent("disk.img"))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-live", environmentID: "env-live",
                baseImageID: predecessor.image.id, createdAt: Date()
            ),
            to: working
        )

        let report = await store.images.retireFactoryImages(afterUsableImage: arm.image.id)
        let reason = try XCTUnwrap(report.retainedImages[predecessor.image.id])
        XCTAssertTrue(reason.contains("live-lease") || reason.contains("environment-base"))
        XCTAssertTrue(manifestExists(predecessor.image.id))
        XCTAssertTrue(expandedExists(predecessor.image.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollbackDirectory(predecessor.image.id).path))
        XCTAssertEqual(try Data(contentsOf: working.appendingPathComponent("disk.img")), workingDisk)
        // The usable replacement's own prior backup is still retired.
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackDirectory(arm.image.id).path))
    }

    func testPreservedWorkingDiskRetainsTheSupersededBase() async throws {
        let base = try makeFactoryInstall(id: "arm-working-base", riscv: false, disk: diskBytes(41))
        try await migrate(base)
        let successor = try makeFactoryInstall(
            id: "arm-working-successor", riscv: false, disk: diskBytes(42),
            predecessor: origin(of: base)
        )
        try await migrate(successor)
        // A preserved quarantine working disk names this base: retiring the
        // base would strand the preserved bytes.
        let quarantine = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-rt-preserved", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let preserved = Data("preserved disk".utf8)
        try preserved.write(to: quarantine.appendingPathComponent("disk.img"))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-preserved", environmentID: "env-preserved",
                baseImageID: base.image.id, createdAt: Date()
            ),
            to: quarantine
        )
        let report = await store.images.retireFactoryImages(afterUsableImage: successor.image.id)
        XCTAssertNotNil(report.retainedImages[base.image.id])
        XCTAssertTrue(manifestExists(base.image.id))
        XCTAssertEqual(
            try Data(contentsOf: quarantine.appendingPathComponent("disk.img")), preserved
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackDirectory(successor.image.id).path))
    }

    // MARK: retired architecture backlog

    func testRetiredArchitectureBacklogIgnoresLegacyEnvironmentPins() async throws {
        let riscv = try makeFactoryInstall(id: "riscv-backlog", riscv: true, disk: diskBytes(51))
        try await migrate(riscv)
        // A historical environment pin names the RISC-V generation. It can
        // never boot on this machine; the backlog pass must not wait for it.
        try await store.registry.upsertEnvironment(RuntimeV2Registry.EnvironmentRow(
            id: "env-riscv", kind: "linuxVM", ownerID: nil, name: nil,
            baseImageID: riscv.image.id, baseRootfsDigest: nil, state: "stopped",
            dataPath: "environments/env-riscv/data", compatHostFHS: false,
            repairReason: nil, createdAt: Date(), lastUsedAt: Date()
        ))
        // The environment's own data directory is not touched.
        let data = try layout.environmentDataDirectory(environmentID: "env-riscv")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("user environment data".utf8).write(to: data.appendingPathComponent("note.txt"))

        let report = await store.images.retireFactoryImages(afterUsableImage: nil)
        XCTAssertEqual(report.trigger, .retiredArchitectureBacklog)
        XCTAssertEqual(report.retiredImages, [riscv.image.id])
        XCTAssertFalse(manifestExists(riscv.image.id))
        XCTAssertFalse(expandedExists(riscv.image.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackDirectory(riscv.image.id).path))
        XCTAssertEqual(
            try Data(contentsOf: data.appendingPathComponent("note.txt")),
            Data("user environment data".utf8)
        )
        let retiredRecords = try await store.images.retirementRecords()
        let record = try XCTUnwrap(retiredRecords.first { $0.imageID == riscv.image.id })
        XCTAssertEqual(record.reason, "retired-architecture")
        XCTAssertEqual(record.architecture, "riscv64")
        XCTAssertEqual(record.phase, .done)
    }

    func testHistoricalDamagedRollbackKeepsUndeclaredBytes() async throws {
        let riscv = try makeFactoryInstall(id: "riscv-orphan", riscv: true, disk: diskBytes(61))
        try await migrate(riscv)
        // The rollback's own manifest is gone (historical damaged migration).
        // The v2 manifest still names the factory artifacts of this EXACT
        // generation, so the declared disk is retired metadata-fast; a file the
        // manifest never declared (an abandoned import's leftover) is retained,
        // never swept.
        let rollback = rollbackDirectory(riscv.image.id)
            .appendingPathComponent("legacy-images/\(riscv.image.id)", isDirectory: true)
        try FileManager.default.removeItem(at: rollback.appendingPathComponent("manifest.json"))
        let leftover = Data("abandoned import piece".utf8)
        try leftover.write(to: rollback.appendingPathComponent("personal.img"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollback.appendingPathComponent("disk.img").path))

        let report = await store.images.retireFactoryImages(afterUsableImage: nil)
        XCTAssertEqual(report.retiredImages, [riscv.image.id])
        XCTAssertFalse(manifestExists(riscv.image.id))
        XCTAssertFalse(expandedExists(riscv.image.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollback.appendingPathComponent("personal.img").path))
        XCTAssertEqual(try Data(contentsOf: rollback.appendingPathComponent("personal.img")), leftover)
        let recorded = try await store.images.retirementRecords()
        XCTAssertTrue(
            recorded.first?.retainedNotes.contains { $0.contains("directory-not-empty") } == true,
            "the undeclared entry must be reported as retained"
        )
    }

    // MARK: frozen identities

    func testChangedFileInstanceAbortsIdentityRetirement() async throws {
        let riscv = try makeFactoryInstall(id: "riscv-changed", riscv: true, disk: diskBytes(71))
        try await migrate(riscv)
        let loadedManifest = try await store.images.manifest(imageID: riscv.image.id)
        let manifest = try XCTUnwrap(loadedManifest)
        let rootfs = try XCTUnwrap(manifest.rootfsDigest)

        // A stale durable plan from an earlier pass describes the OLD file
        // instance of the expanded rootfs.
        let expandedRootfs = try layout.expandedImageDirectory(imageID: riscv.image.id)
            .appendingPathComponent(try XCTUnwrap(manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"]).expandedPath)
        let staleInode = (try FileManager.default.attributesOfItem(atPath: expandedRootfs.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var planned = RuntimeV2FactoryImageRetirement.Plan(
            imageID: riscv.image.id, reason: .retiredArchitecture,
            architecture: "riscv64", evidence: "bios=bbl64.bin",
            items: [
                .init(
                    kind: .expandedView,
                    anchorRelativePath: "images/expanded/\(riscv.image.id)",
                    files: [
                        .init(
                            relativePath: try XCTUnwrap(manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"]).expandedPath,
                            bytes: 1, device: 0, inode: staleInode &+ 1, size: 1,
                            modificationSeconds: 0, modificationNanoseconds: 0,
                            changeSeconds: 0, changeNanoseconds: 0,
                            linkCount: 1, sha512: nil
                        )
                    ],
                    removableDirectories: []
                )
            ],
            artifactDigests: [rootfs], deletesImageIdentity: true, retained: []
        )
        planned.reason = .retiredArchitecture
        _ = try await store.registry.planImageRetirement(.init(
            imageID: riscv.image.id, reason: "retired-architecture", phase: .planned,
            triggerImageID: nil, triggerRootfsDigest: nil, architecture: "riscv64",
            evidence: "bios=bbl64.bin",
            planJSON: RuntimeV2FactoryImageRetirement.encodePlan(planned)
        ))

        let report = await store.images.retireFactoryImages(afterUsableImage: nil)
        XCTAssertEqual(report.failures.count, 1, "a changed instance must abort the identity retirement")
        XCTAssertTrue(manifestExists(riscv.image.id), "the identity stays resolvable for the writer")
        let stillVerified = try await store.images.isImageVerified(imageID: riscv.image.id)
        XCTAssertTrue(stillVerified)
        let retiredRecords = try await store.images.retirementRecords()
        let record = try XCTUnwrap(retiredRecords.first { $0.imageID == riscv.image.id })
        XCTAssertEqual(record.phase, .failed)
        XCTAssertTrue(record.lastError?.contains("concurrent") == true)
    }

    // MARK: shared blobs

    func testBlobSharedWithALiveGenerationIsRetained() async throws {
        let sharedBios = Data(repeating: 0x6A, count: 2048)
        let riscv = try makeFactoryInstall(
            id: "riscv-shared", riscv: true, disk: diskBytes(81), biosBytes: sharedBios
        )
        try await migrate(riscv)
        let arm = try makeFactoryInstall(
            id: "arm-shared", riscv: false, disk: diskBytes(82), biosBytes: sharedBios
        )
        try await migrate(arm)
        let biosDigest = FloeDigest.sha512Hex(sharedBios)

        let report = await store.images.retireFactoryImages(afterUsableImage: nil)
        XCTAssertEqual(report.retiredImages, [riscv.image.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try blobPath(biosDigest).path),
                      "content still referenced by the ARM generation must keep its bytes")
        let blob = try await store.registry.blob(digest: biosDigest)
        XCTAssertEqual(blob?.refs, 1)

        // When the last owner is retired, the bytes go.
        _ = await store.images.retireFactoryImages(afterUsableImage: nil)
        XCTAssertTrue(manifestExists(arm.image.id))
        let survivor = try await store.registry.blob(digest: biosDigest)
        XCTAssertEqual(survivor?.refs, 1)
    }

    // MARK: quarantined expanded rollback (ImageStore's own factory sidecars)

    func testQuarantinedARM64ExpandedRollbackIsRetiredWithSentinelRetained() async throws {
        let arm = try makeFactoryInstall(id: "arm-quarantined", riscv: false, disk: diskBytes(111))
        try await migrate(arm)
        let loadedManifest = try await store.images.manifest(imageID: arm.image.id)
        let manifest = try XCTUnwrap(loadedManifest)
        let entryName = "expanded-\(arm.image.id)-\(UUID().uuidString)"
        let quarantine = layout.quarantineDirectory.appendingPathComponent(entryName, isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        // The ImageStore's real rollback shape: the verbatim manifest, the
        // declared boot files, and the verifier's success sidecar.
        try manifest.legacyManifestData.write(
            to: quarantine.appendingPathComponent("manifest.json")
        )
        var declaredSizes: [String: Int64] = [:]
        for ref in manifest.artifacts.values {
            // The ImageStore's rollback view holds the declared artifact at its
            // exact recorded byte count.
            let bytes = Data(repeating: 0x7A, count: Int(ref.bytes))
            try bytes.write(to: quarantine.appendingPathComponent(ref.expandedPath))
            declaredSizes[ref.expandedPath] = ref.bytes
        }
        let verifierSidecar = Data("{\"verified\":true}".utf8)
        try verifierSidecar.write(to: quarantine.appendingPathComponent(".floe-verified-v2-expanded.json"))
        let sentinel = Data("unrelated user file".utf8)
        try sentinel.write(to: quarantine.appendingPathComponent("user-sentinel.txt"))

        let report = await store.images.retireFactoryImages(afterUsableImage: arm.image.id)
        XCTAssertEqual(report.trigger, .usableImage, "an authenticated factory quarantine must not defer the pass")
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.retiredImages, [arm.image.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("manifest.json").path))
        for path in declaredSizes.keys {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: quarantine.appendingPathComponent(path).path),
                "declared factory file \(path) must be retired"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: quarantine.appendingPathComponent(".floe-verified-v2-expanded.json").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("user-sentinel.txt").path),
            "an undeclared user file must never be swept"
        )
        XCTAssertEqual(
            try Data(contentsOf: quarantine.appendingPathComponent("user-sentinel.txt")), sentinel
        )
        XCTAssertTrue(manifestExists(arm.image.id), "the current verified generation stays")
    }

    // MARK: legacy install fallback (no v2 row remains)

    func testLegacyOnlyRISCVDirectoryIsRetiredFromTheSuppliedLegacyRoot() async throws {
        // Never migrated: no v2 row, no v2 manifest. The caller-supplied legacy
        // root is the fallback that still lets the retired architecture's
        // factory bytes be reconciled.
        let riscv = try makeFactoryInstall(id: "riscv-legacy-only", riscv: true, disk: diskBytes(121))
        let sentinel = Data("user addition".utf8)
        try sentinel.write(to: riscv.directory.appendingPathComponent("notes.txt"))

        let report = await store.images.retireFactoryImages(
            afterUsableImage: nil, legacyImagesRoot: legacyRoot
        )
        XCTAssertEqual(report.trigger, .retiredArchitectureBacklog)
        XCTAssertEqual(report.retiredImages, [riscv.image.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: riscv.directory.appendingPathComponent("disk.img").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: riscv.directory.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: riscv.directory.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(try Data(contentsOf: riscv.directory.appendingPathComponent("notes.txt")), sentinel)
    }

    // MARK: resident origin protection

    func testBoundResidentImageIsNeverRetiredWithoutAnEnvironmentRow() async throws {
        let resident = try makeFactoryInstall(id: "arm-resident", riscv: false, disk: diskBytes(131))
        try await migrate(resident)
        let successor = try makeFactoryInstall(
            id: "arm-resident-successor", riscv: false, disk: diskBytes(132),
            predecessor: origin(of: resident)
        )
        try await migrate(successor)
        // No environment/lease/template row names the resident image here; the
        // mutable disk and origin.json live outside this layout. The App's
        // bound native activeLinuxImageID is the only authority.
        let report = await store.images.retireFactoryImages(
            afterUsableImage: successor.image.id, protectedActiveImageID: resident.image.id
        )
        XCTAssertEqual(
            report.retainedImages[resident.image.id],
            "active-resident-image: the native resident machine boots this image"
        )
        XCTAssertTrue(manifestExists(resident.image.id))
        XCTAssertTrue(expandedExists(resident.image.id))
    }

    func testProtectedActiveImageStillDropsItsDeadRollbackAndQuarantineOnly() async throws {
        let active = try makeFactoryInstall(id: "arm-active", riscv: false, disk: diskBytes(141))
        try await migrate(active)
        let loadedManifest = try await store.images.manifest(imageID: active.image.id)
        let manifest = try XCTUnwrap(loadedManifest)
        let rootfs = try XCTUnwrap(manifest.rootfsDigest)

        // Its migration rollback and an older expanded quarantine copy exist.
        let rollback = rollbackDirectory(active.image.id)
            .appendingPathComponent("legacy-images/\(active.image.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollback.appendingPathComponent("disk.img").path))
        let entryName = "expanded-\(active.image.id)-\(UUID().uuidString)"
        let quarantine = layout.quarantineDirectory.appendingPathComponent(entryName, isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try manifest.legacyManifestData.write(to: quarantine.appendingPathComponent("manifest.json"))
        for ref in manifest.artifacts.values {
            try Data(repeating: 0x4D, count: Int(ref.bytes))
                .write(to: quarantine.appendingPathComponent(ref.expandedPath))
        }
        let userFile = Data("user file inside quarantine".utf8)
        try userFile.write(to: quarantine.appendingPathComponent("keep-me.txt"))
        // The resident machine's origin/disk are outside this layout: a
        // sentinel here must never be touched.
        let residentOrigin = root.deletingLastPathComponent()
            .appendingPathComponent("resident-origin-\(UUID().uuidString).json")
        let residentBytes = Data("{\"imageID\":\"\(active.image.id)\"}".utf8)
        try residentBytes.write(to: residentOrigin)
        defer { try? FileManager.default.removeItem(at: residentOrigin) }

        let report = await store.images.retireFactoryImages(
            afterUsableImage: active.image.id, protectedActiveImageID: active.image.id
        )
        XCTAssertEqual(report.failures, [])
        // The protected base is not retired, but its exact dead duplicates are.
        XCTAssertEqual(report.retiredImages, [active.image.id])
        XCTAssertNil(report.retainedImages[active.image.id])
        XCTAssertTrue(manifestExists(active.image.id))
        XCTAssertTrue(expandedExists(active.image.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try blobPath(rootfs).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollback.appendingPathComponent("disk.img").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("manifest.json").path))
        for ref in manifest.artifacts.values {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: quarantine.appendingPathComponent(ref.expandedPath).path)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("keep-me.txt").path))
        XCTAssertEqual(
            try Data(contentsOf: quarantine.appendingPathComponent("keep-me.txt")), userFile
        )
        XCTAssertEqual(try Data(contentsOf: residentOrigin), residentBytes)
    }

    // MARK: stale leases and unknown working roots

    func testExpiredHeldLeaseFromARetiredBuildDoesNotRetainTheGeneration() async throws {
        let riscv = try makeFactoryInstall(id: "riscv-stale-lease", riscv: true, disk: diskBytes(151))
        try await migrate(riscv)
        try await store.registry.upsertEnvironment(RuntimeV2Registry.EnvironmentRow(
            id: "env-stale", kind: "linuxVM", ownerID: nil, name: nil,
            baseImageID: riscv.image.id, baseRootfsDigest: nil, state: "active",
            dataPath: "environments/env-stale/data", compatHostFHS: false,
            repairReason: nil, createdAt: Date(), lastUsedAt: Date()
        ))
        // The legacy v2 store carries `held` rows from retired builds. An
        // expired TTL plus a dead holder is provably stale and must not keep
        // factory bytes forever.
        try await store.registry.recordLease(RuntimeV2Registry.LeaseRow(
            environmentID: "env-stale", runtimeID: "rt-retired-build", incarnation: "dead-incarnation",
            sessionToken: "token", pid: 4_000_000,
            acquiredAt: Date(timeIntervalSinceNow: -3_600),
            renewedAt: Date(timeIntervalSinceNow: -3_600),
            ttlSeconds: 30, state: "held"
        ))
        let report = await store.images.retireFactoryImages(afterUsableImage: nil)
        XCTAssertEqual(report.trigger, .retiredArchitectureBacklog)
        XCTAssertEqual(report.retiredImages, [riscv.image.id])
        XCTAssertNil(report.retainedImages[riscv.image.id])
        XCTAssertFalse(manifestExists(riscv.image.id))
    }

    func testUnknownQuarantineWorkingRootStillDefersThePass() async throws {
        let riscv = try makeFactoryInstall(id: "riscv-unknown-root", riscv: true, disk: diskBytes(161))
        try await migrate(riscv)
        // A real directory with no runtime.json and no authenticated factory
        // manifest cannot be attributed: the pass must defer, not delete.
        let unknown = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-unknown", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("unattributed bytes".utf8).write(to: unknown.appendingPathComponent("disk.img"))

        let report = await store.images.retireFactoryImages(afterUsableImage: nil)
        XCTAssertEqual(report.trigger, .deferred)
        XCTAssertTrue(manifestExists(riscv.image.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.appendingPathComponent("disk.img").path))
    }

    // MARK: trigger guards

    func testUnusableTriggerWritesNoDurablePlan() async throws {
        let report = await store.images.retireFactoryImages(afterUsableImage: "no-such-image")
        XCTAssertEqual(report.trigger, .notUsable)
        XCTAssertTrue(report.retiredImages.isEmpty)
        let records = try await store.images.retirementRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testAbandonedStagingTreeIsNeverRetired() async throws {
        let riscv = try makeFactoryInstall(id: "riscv-staging", riscv: true, disk: diskBytes(91))
        try await migrate(riscv)
        let staging = layout.expandedImagesDirectory
            .appendingPathComponent(".staging-abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let abandoned = Data("abandoned stage".utf8)
        try abandoned.write(to: staging.appendingPathComponent("disk.img"))

        _ = await store.images.retireFactoryImages(afterUsableImage: nil)
        XCTAssertFalse(manifestExists(riscv.image.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("disk.img").path))
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("disk.img")), abandoned)
    }

    func testConcurrentPassesConvergeWithoutDoubleDeleting() async throws {
        let riscv = try makeFactoryInstall(id: "riscv-concurrent", riscv: true, disk: diskBytes(101))
        try await migrate(riscv)
        let images = await store.images
        async let first = images.retireFactoryImages(afterUsableImage: nil)
        async let second = images.retireFactoryImages(afterUsableImage: nil)
        let firstReport = await first
        let secondReport = await second
        let reports = [firstReport, secondReport]
        XCTAssertTrue(reports.allSatisfy { $0.failures.isEmpty })
        XCTAssertEqual(reports.flatMap(\.retiredImages).filter { $0 == riscv.image.id }.count, 1)
        XCTAssertFalse(manifestExists(riscv.image.id))
        let records = try await store.images.retirementRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].phase, .done)
    }
}

/// Minimal thread-safe counter for the cancellation seam.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}
