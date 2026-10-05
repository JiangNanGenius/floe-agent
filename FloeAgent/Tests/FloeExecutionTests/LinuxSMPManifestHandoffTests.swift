// FloeExecutionTests — SMP manifest handoff and truthful installation status.
//
// Build 240 device feedback showed the published SMP image running with one
// hart while an explicit two-core start was refused: the receipt named the
// published SMP image (the guest booted its SMP kernel), yet the admission
// gate answered from a different image's manifest. These tests pin the
// repaired contracts with the REAL published component manifest
// (floe-linux-guest-smp-20260928.1, a public release asset):
//
//   - the published manifest's `smp_capable` declaration lifts into the
//     Runtime v2 store and proves SMP at admission (including a stored v2
//     manifest predating the lifted capabilities block, whose verbatim legacy
//     bytes still carry the declaration);
//   - the SMP admission gate evaluates exactly the image the start boots
//     (the descriptor image), never a template pin or registry row that names
//     another image — in both directions;
//   - the verifier's durable success snapshot keeps post-relaunch status
//     reads immediate (no full-disk re-hash) while any size/mtime/content
//     identity change falls through to a real hash;
//   - installation-state derivation never renders "not installed" for a
//     verified image whose guest is running.

import Foundation
import XCTest
import FloeCore
@testable import FloeExecution

final class LinuxSMPManifestHandoffTests: XCTestCase {
    private var root: URL!
    private var layout: RuntimeV2Layout!
    private var store: RuntimeV2Store!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smp-handoff-\(UUID().uuidString)", isDirectory: true)
        layout = RuntimeV2Layout(root: root)
        store = RuntimeV2Store(layout: layout)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: service-owned status snapshot (repeated view creation)

    func testStatusSnapshotCacheContract() async throws {
        // The cache that keeps repeated Settings entries on one completed
        // read: fresh entries are reused WITHOUT invoking the reader, a
        // revision bump re-reads, a failed read is never cached, and an
        // expired entry re-reads. This is the repeated view-creation
        // contract the Settings/terminal/card readers rely on.
        let cache = LinuxImageStatusSnapshotCache<String>()
        var reads = 0

        let first = try await cache.status(id: "img", maxAge: 3) {
            reads += 1
            return "installed"
        }
        XCTAssertEqual(first, "installed")
        XCTAssertEqual(reads, 1)

        // A second read (a re-created view) reuses the completed snapshot.
        let second = try await cache.status(id: "img", maxAge: 3) {
            reads += 1
            return "changed"
        }
        XCTAssertEqual(second, "installed", "a fresh snapshot is served without a new read")
        XCTAssertEqual(reads, 1)

        // A mutation drops the snapshot: the next read re-derives.
        cache.bumpRevision()
        let third = try await cache.status(id: "img", maxAge: 3) {
            reads += 1
            return "repaired"
        }
        XCTAssertEqual(third, "repaired")
        XCTAssertEqual(reads, 2)

        // A FAILED read stores nothing: a later read for the same id runs the
        // reader again instead of replaying a failure (or serving whatever
        // a previous successful read cached).
        struct ReadFailed: Error {}
        do {
            _ = try await cache.status(id: "img-failed", maxAge: 3) { () throws -> String? in
                throw ReadFailed()
            }
            XCTFail("the read error must propagate")
        } catch is ReadFailed {}
        let final = try await cache.status(id: "img-failed", maxAge: 3) {
            reads += 1
            return "final"
        }
        XCTAssertEqual(final, "final")
        XCTAssertEqual(reads, 3, "a failed read was never cached")
    }

    func testStatusSnapshotCacheConcurrentMutationInvalidation() async throws {
        // A read that STARTS before a mutation and COMPLETES after it must
        // not repopulate the cache with pre-mutation truth: the result is
        // still returned to its own caller, but the next read re-derives.
        let cache = LinuxImageStatusSnapshotCache<String>()
        var reads = 0
        let mutationDuringRead = expectation(description: "mutation during read")

        let result = try await cache.status(id: "img", maxAge: 3) { () async -> String? in
            reads += 1
            // The mutation lands while the read is in flight.
            cache.bumpRevision()
            mutationDuringRead.fulfill()
            return "pre-mutation"
        }
        await fulfillment(of: [mutationDuringRead], timeout: 1)
        XCTAssertEqual(result, "pre-mutation", "the in-flight caller keeps its own result")

        let rederived = try await cache.status(id: "img", maxAge: 3) {
            reads += 1
            return "post-mutation"
        }
        XCTAssertEqual(rederived, "post-mutation")
        XCTAssertEqual(reads, 2, "a read racing a mutation was never cached")
    }

    func testStatusSnapshotCacheHonoursCancellationBeforeCacheHit() async throws {
        // A superseded (cancelled) refresh must keep its contract even when
        // the snapshot would answer instantly: publication is refused.
        let cache = LinuxImageStatusSnapshotCache<String>()
        _ = try await cache.status(id: "img", maxAge: 3) { "installed" }
        var reads = 0
        do {
            _ = try await cache.status(
                id: "img", maxAge: 3,
                isCancelled: { true },
                read: { reads += 1; return "changed" }
            )
            XCTFail("a cancelled refresh must throw even on a cache hit")
        } catch is CancellationError {}
        XCTAssertEqual(reads, 0, "the reader never ran")
    }

    // MARK: published manifest fixture

    /// The verbatim manifest.json of the published SMP component image
    /// (release floe-linux-guest-smp-20260928.1, run 36330566148). Public
    /// release metadata: digests, package listing and the `smp_capable`
    /// declaration the image build emitted.
    private let publishedSMPManifestJSON = """
{
  "id": "floe-debian13-riscv64-202609202607-basic-r572a77382feb-b36330566148-1",
  "biosPath": "bbl64.bin",
  "diskReadWrite": true,
  "qualified": true,
  "kernelPath": "kernel-riscv64.bin",
  "diskPath": "disk.img",
  "cmdline": "console=hvc0 root=/dev/vda rw loglevel=4",
  "qualificationEvidence": "component-image-ci boot A+B: runner PID1 clock from floe.epoch, signed HTTPS apt update/install, Python HTTPS 200, 13 user commands executed. APT/PyPI provisioning ran on the cloud host in a qemu-user riscv64 chroot against the shipped ext4 (signed verification, real dpkg scripts/database; evidence provision-*.txt); boot A re-verified the provisioned state in-Guest (dpkg live + pinned imports), boot B is the full verification. Unpinned boot pair from --boot-dir (locally built kernel/bbl); the 2018-pair capability run and its runtime claim do not apply to this image. This image declares smp_capable: its kernel/firmware are the CONFIG_SMP dual-hart build (SMP-BUILD.txt multi-hart IPI evidence); the app grants a second hart only to an image carrying this declaration.",
  "qualificationRun": "https://github.com/JiangNanGenius/floe-agent/actions/runs/36330566148",
  "artifacts": [
    {
      "role": "bios",
      "path": "bbl64.bin",
      "sha512": "c7f0200ee355fe484e3e3d196799add8ebbc2f9435000509a3f0ab9343976ba6b7b7c7601094629e184f3ddcca70b8f456103438e609bae99d79bc08aa689f6e",
      "bytes": 74258
    },
    {
      "role": "kernel",
      "path": "kernel-riscv64.bin",
      "sha512": "d5c650c9434dbe25fe8d96e59738385a796d446ddd5e00e52b959dfbead38468dd69e9b93322454a3f1b49bda1ad8396d6d842a1d20dec1657589d9887284cf7",
      "bytes": 5121044
    },
    {
      "role": "disk",
      "path": "disk.img",
      "sha512": "1d6be7152f511050a43729c69773e49b5a8e87a44e58dbcd2c24e299559129d3994fa1104a7d476442cc3b864207daa5e4d85b04f44be0172e9e7350e3161c26",
      "bytes": 17179869184
    }
  ],
  "provenance": {
    "sourceURL": "https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-guest-smp-20260928.1",
    "buildConfigurationURL": "https://github.com/JiangNanGenius/floe-agent/tree/floe-linux-guest-smp-20260928.1/FloeAgent/ThirdParty/TinyEMU/guest-image",
    "license": "Floe runner MPL-2.0; guest userland under its own Debian package licenses; kernel GPL-2.0; bbl BSD-3-Clause; static glibc LGPL-2.1",
    "distributionAllowed": true
  },
  "smp_capable": true,
  "template": {
    "id": "basic",
    "recipeSha512": "c66ac0502f050424dee5524698621b936929cc3d09a15c21e103374d5d0c9f460c2d1c72b5464d2a446d49d9b7b1c4c485d9515a05348106b51116284f3216e6",
    "recipePath": "FloeAgent/LinuxGuest/image/templates/basic.json",
    "verified": true,
    "missingPackages": [],
    "belowMinimum": [],
    "pypiFailures": [],
    "packages": [
      {
        "name": "bash",
        "version": "5.2.37-2+b10",
        "arch": "riscv64",
        "source": "bash",
        "installedKb": 7044
      },
      {
        "name": "bzip2",
        "version": "1.0.8-6",
        "arch": "riscv64",
        "source": "bzip2",
        "installedKb": 105
      },
      {
        "name": "ca-certificates",
        "version": "20250419",
        "arch": "all",
        "source": "ca-certificates",
        "installedKb": 390
      },
      {
        "name": "coreutils",
        "version": "9.7-3",
        "arch": "riscv64",
        "source": "coreutils",
        "installedKb": 17337
      },
      {
        "name": "nodejs",
        "version": "20.19.2+dfsg-1+deb13u3",
        "arch": "riscv64",
        "source": "nodejs",
        "installedKb": 2348
      },
      {
        "name": "npm",
        "version": "9.2.0~ds1-3",
        "arch": "all",
        "source": "npm",
        "installedKb": 2940
      },
      {
        "name": "openssh-client",
        "version": "1:10.0p1-7+deb13u4",
        "arch": "riscv64",
        "source": "openssh",
        "installedKb": 4283
      },
      {
        "name": "p7zip-full",
        "version": "16.02+transitional.1",
        "arch": "all",
        "source": "p7zip",
        "installedKb": 12
      },
      {
        "name": "procps",
        "version": "2:4.0.4-9",
        "arch": "riscv64",
        "source": "procps",
        "installedKb": 2287
      },
      {
        "name": "python3",
        "version": "3.13.5-1",
        "arch": "riscv64",
        "source": "python3-defaults",
        "installedKb": 83
      },
      {
        "name": "python3-numpy",
        "version": "1:2.2.4+ds-1",
        "arch": "riscv64",
        "source": "numpy",
        "installedKb": 16979
      },
      {
        "name": "python3-pip",
        "version": "25.1.1+dfsg-1",
        "arch": "all",
        "source": "python-pip",
        "installedKb": 10166
      },
      {
        "name": "python3-venv",
        "version": "3.13.5-1",
        "arch": "riscv64",
        "source": "python3-defaults",
        "installedKb": 6
      },
      {
        "name": "sqlite3",
        "version": "3.46.1-7+deb13u2",
        "arch": "riscv64",
        "source": "sqlite3",
        "installedKb": 543
      },
      {
        "name": "unzip",
        "version": "6.0-29+deb13u1",
        "arch": "riscv64",
        "source": "unzip",
        "installedKb": 347
      },
      {
        "name": "util-linux",
        "version": "2.41.5-0+deb13u1",
        "arch": "riscv64",
        "source": "util-linux",
        "installedKb": 4598
      },
      {
        "name": "xz-utils",
        "version": "5.8.1-1+deb13u1",
        "arch": "riscv64",
        "source": "xz-utils",
        "installedKb": 1404
      },
      {
        "name": "zip",
        "version": "3.0-15+deb13u1",
        "arch": "riscv64",
        "source": "zip",
        "installedKb": 587
      },
      {
        "name": "zsh",
        "version": "5.9-8+b24",
        "arch": "riscv64",
        "source": "zsh",
        "installedKb": 2082
      }
    ],
    "checks": [
      "recipe:sha512",
      "stage1-install:present",
      "apt-missing:0",
      "stage2-verify:present",
      "apt-requirements:verified",
      "pypi-requirements:verified"
    ]
  }
}
"""

    // MARK: capability lift from the real published manifest

    func testPublishedSMPManifestLiftsIntoStoreCapability() throws {
        let data = Data(publishedSMPManifestJSON.utf8)
        let lifted = RuntimeV2ImageStore.declaredCapabilities(legacyManifestData: data)
        XCTAssertEqual(lifted?.smp, true)
        XCTAssertEqual(
            lifted?.declaredBy, "legacy manifest smp_capable",
            "the published declaration travels under the top-level smp_capable key"
        )
        // The manifest remains a qualified image manifest with the bound
        // artifact list the admission path also relies on.
        let image = try JSONDecoder().decode(LinuxGuestImage.self, from: data)
        XCTAssertTrue(image.qualified)
        XCTAssertEqual(image.id, "floe-debian13-riscv64-202609202607-basic-r572a77382feb-b36330566148-1")
        XCTAssertEqual(image.artifacts?.count, 3)
    }

    func testPublishedManifestRoundTripsThroughLegacyInjectionShape() throws {
        // The installer path injects the declaration beside the decoded
        // manifest exactly like the image build writes it; the lift must see
        // it regardless of key order or surrounding keys.
        var object = try JSONSerialization.jsonObject(with: Data(publishedSMPManifestJSON.utf8)) as? [String: Any] ?? [:]
        object["smpCapable"] = object.removeValue(forKey: "smp_capable") as Any
        let alt = try JSONSerialization.data(withJSONObject: object)
        let lifted = RuntimeV2ImageStore.declaredCapabilities(legacyManifestData: alt)
        XCTAssertEqual(lifted?.smp, true)
        XCTAssertEqual(lifted?.declaredBy, "legacy manifest smpCapable")
    }

    // MARK: metadata preservation

    func testSMPCapabilityFallsBackToEmbeddedLegacyManifest() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedSMPImage()
        // Simulate a v2 manifest written before the lifted capabilities block
        // existed: same verified digests, same embedded legacy bytes, no
        // `capabilities` key. The admission verdict must still come from the
        // installed manifest's declaration.
        var stale = manifest
        stale.capabilities = nil
        try RuntimeV2ImageStore.encoder.encode(stale).write(
            to: layout.imageManifestURL(imageID: manifest.imageID), options: .atomic
        )
        let capable = try await store.images.smpCapability(imageID: manifest.imageID)
        XCTAssertTrue(capable.capable)
        XCTAssertEqual(capable.maximumVCPUs, 2)
        XCTAssertTrue(capable.reason.contains("smp_capable"))

        // An explicit stored withdrawal stays authoritative: the fallback
        // never overrides a present (false) block.
        var withdrawn = manifest
        withdrawn.capabilities = .init(smp: false, declaredBy: "test withdrawal")
        try RuntimeV2ImageStore.encoder.encode(withdrawn).write(
            to: layout.imageManifestURL(imageID: manifest.imageID), options: .atomic
        )
        let refused = try await store.images.smpCapability(imageID: manifest.imageID)
        XCTAssertFalse(refused.capable)
        XCTAssertTrue(refused.reason.contains("smp=false"))
    }

    func testThreeCoreClaimRequiresCoherentEmbeddedManifest() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedImage(
            imageID: "triple-image", smpCapable: true, maxVCPUs: 3
        )
        let proven = try await store.images.smpCapability(imageID: manifest.imageID)
        XCTAssertEqual(proven.maximumVCPUs, 3)

        var tampered = manifest
        tampered.capabilities = .init(smp: true, maxVCPUs: 3, declaredBy: "tampered")
        let legacy = try JSONSerialization.jsonObject(with: manifest.legacyManifestData) as? [String: Any]
        var downgraded = try XCTUnwrap(legacy)
        downgraded.removeValue(forKey: "max_vcpus")
        tampered.legacyManifestData = try JSONSerialization.data(withJSONObject: downgraded)
        try RuntimeV2ImageStore.encoder.encode(tampered).write(
            to: layout.imageManifestURL(imageID: manifest.imageID), options: .atomic
        )
        let refused = try await store.images.smpCapability(imageID: manifest.imageID)
        XCTAssertEqual(refused.maximumVCPUs, 2)
    }

    func testMigrationEarlyReturnRefreshesStaleCapabilities() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedSMPImage()
        // Legacy directory was moved aside by the migration: rerunning the
        // migration takes the idempotent early-return path, which must still
        // heal a missing lifted block from the manifest's own legacy bytes.
        var stale = manifest
        stale.capabilities = nil
        try RuntimeV2ImageStore.encoder.encode(stale).write(
            to: layout.imageManifestURL(imageID: manifest.imageID), options: .atomic
        )
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        _ = try await store.images.migrateLegacyImage(
            imageID: manifest.imageID, legacyImagesRoot: legacyRoot
        )
        let healed = try await store.images.manifest(imageID: manifest.imageID)
        XCTAssertEqual(healed?.capabilities?.smp, true)
        // Artifact digests are untouched by the metadata refresh.
        XCTAssertEqual(healed?.artifacts, manifest.artifacts)
    }

    // MARK: withdrawal semantics (true -> withdrawn / explicit false stays false)

    func testWithdrawnDeclarationSurvivesRepairRefresh() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedSMPImage()
        // A publisher-withdrawn declaration under the same verified artifact
        // digests: the replacement manifest carries NO smp_capable key.
        let replacement = try stageReplacementManifest(
            manifest: manifest, declaration: .absent
        )
        try await store.images.repairImageFromLegacyInstall(
            imageID: manifest.imageID, legacyImagesRoot: replacement
        )
        let verdict = try await store.images.smpCapability(imageID: manifest.imageID)
        XCTAssertFalse(verdict.capable, "a withdrawn declaration must not be resurrected")
        let storedData = try await store.images.manifest(imageID: manifest.imageID)
        let stored = try XCTUnwrap(storedData)
        XCTAssertNil(stored.capabilities?.smp)
        // Both sources stay coherent: the embedded bytes carry no declaration
        // either, so the read fallback cannot revive it.
        let rederived = RuntimeV2ImageStore.declaredCapabilities(
            legacyManifestData: stored.legacyManifestData
        )
        XCTAssertNil(rederived?.smp)
    }

    func testExplicitFalseSurvivesRepairRefresh() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedSMPImage()
        let replacement = try stageReplacementManifest(
            manifest: manifest, declaration: .explicitFalse
        )
        try await store.images.repairImageFromLegacyInstall(
            imageID: manifest.imageID, legacyImagesRoot: replacement
        )
        let verdict = try await store.images.smpCapability(imageID: manifest.imageID)
        XCTAssertFalse(verdict.capable)
        XCTAssertTrue(verdict.reason.contains("smp=false"))
        let storedData = try await store.images.manifest(imageID: manifest.imageID)
        let stored = try XCTUnwrap(storedData)
        XCTAssertEqual(stored.capabilities?.smp, false)
    }

    func testWithdrawnDeclarationSurvivesMigrationRerun() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedSMPImage()
        // Re-stage the legacy directory with a same-digest manifest whose
        // declaration was withdrawn; the migration rerun refreshes both the
        // lifted block and the embedded bytes atomically.
        let legacyRoot = root.appendingPathComponent("legacy-\(manifest.imageID)", isDirectory: true)
        _ = try stageReplacementManifest(manifest: manifest, declaration: .absent, at: legacyRoot)
        _ = try await store.images.migrateLegacyImage(
            imageID: manifest.imageID, legacyImagesRoot: legacyRoot
        )
        let verdict = try await store.images.smpCapability(imageID: manifest.imageID)
        XCTAssertFalse(verdict.capable, "a declaration withdrawn before a migration rerun stays withdrawn")
        let storedData = try await store.images.manifest(imageID: manifest.imageID)
        let stored = try XCTUnwrap(storedData)
        let rederived = RuntimeV2ImageStore.declaredCapabilities(
            legacyManifestData: stored.legacyManifestData
        )
        XCTAssertNil(rederived?.smp)
    }

    func testEmbeddedFallbackRejectsForeignImageIdentity() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedSMPImage()
        // Embedded bytes naming a DIFFERENT image id must not be trusted by the
        // read fallback even though the digests would otherwise match.
        let foreign = LinuxGuestImage(
            id: "foreign-image-id",
            biosPath: "bios.bin",
            diskPath: "rootfs.img",
            qualified: true,
            qualificationRun: "foreign",
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: "bios.bin",
                    sha512: manifest.artifacts["bios"]?.sha512 ?? "", bytes: 4096
                ),
                LinuxGuestImageArtifact(
                    role: .disk, path: "rootfs.img",
                    sha512: manifest.artifacts["rootfs"]?.sha512 ?? "", bytes: 3 << 20
                )
            ]
        )
        var tampered = manifest
        tampered.capabilities = nil
        tampered.legacyManifestData = try JSONEncoder().encode(foreign)
        try RuntimeV2ImageStore.encoder.encode(tampered).write(
            to: layout.imageManifestURL(imageID: manifest.imageID), options: .atomic
        )
        let verdict = try await store.images.smpCapability(imageID: manifest.imageID)
        XCTAssertFalse(verdict.capable, "an incoherent embedded identity is never trusted")
    }

    enum ReplacementDeclaration {
        case absent
        case explicitFalse
    }

    /// Stages a legacy image directory carrying `manifest`'s exact artifact
    /// bytes (identical pinned digests) with the SMP declaration replaced.
    @discardableResult
    private func stageReplacementManifest(
        manifest: RuntimeV2ImageStore.Manifest,
        declaration: ReplacementDeclaration,
        at rootOverride: URL? = nil
    ) throws -> URL {
        let expanded = layout.expandedImagesDirectory.appendingPathComponent(manifest.imageID, isDirectory: true)
        let legacyRoot = rootOverride ?? root.appendingPathComponent("replacement-\(manifest.imageID)", isDirectory: true)
        let directory = legacyRoot.appendingPathComponent(manifest.imageID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (_, ref) in manifest.artifacts {
            let source = expanded.appendingPathComponent(ref.expandedPath)
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(ref.expandedPath))
        }
        var object = try JSONSerialization.jsonObject(with: manifest.legacyManifestData) as? [String: Any] ?? [:]
        switch declaration {
        case .absent:
            object.removeValue(forKey: "smp_capable")
            object.removeValue(forKey: "smpCapable")
            var capabilities = object["capabilities"] as? [String: Any] ?? [:]
            capabilities.removeValue(forKey: "smp")
            object["capabilities"] = capabilities
        case .explicitFalse:
            object["smp_capable"] = false
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        return legacyRoot
    }

    func testMigrationEarlyReturnIgnoresIncoherentLegacyBytes() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedSMPImage()
        // Embedded legacy bytes whose artifact digests do NOT match the
        // verified v2 manifest must not drive a metadata refresh.
        let foreign = LinuxGuestImage(
            id: manifest.imageID,
            biosPath: "bios.bin",
            diskPath: "rootfs.img",
            qualified: true,
            qualificationRun: "foreign",
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: "bios.bin",
                    sha512: String(repeating: "ab", count: 64), bytes: 1
                )
            ]
        )
        let foreignData = try JSONEncoder().encode(foreign)
        var corrupt = manifest
        corrupt.capabilities = nil
        corrupt.legacyManifestData = foreignData
        try RuntimeV2ImageStore.encoder.encode(corrupt).write(
            to: layout.imageManifestURL(imageID: manifest.imageID), options: .atomic
        )
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        _ = try await store.images.migrateLegacyImage(
            imageID: manifest.imageID, legacyImagesRoot: legacyRoot
        )
        let untouched = try await store.images.manifest(imageID: manifest.imageID)
        XCTAssertNil(untouched?.capabilities, "an incoherent manifest must not be lifted")
    }

    // MARK: admission gates on the boot image

    func testFreshInstallOffersPreparationButCorruptLegacyRetainsError() async throws {
        let legacy = root.appendingPathComponent("empty-legacy")
        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacy, build: "fresh")
        do {
            _ = try await integrator.acquireShape(
                environmentID: "fresh", runtimeID: "fresh-run", imageID: smpImageID,
                request: .init(vcpus: .three, memory: .m256, origin: .userSpecified), downgrade: .strict)
            XCTFail("missing image must not acquire a guest")
        } catch LinuxGuestError.imageNotQualified { }
        let corrupt = legacy.appendingPathComponent(smpImageID)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: corrupt.appendingPathComponent("manifest.json"))
        do {
            _ = try await integrator.acquireShape(
                environmentID: "fresh", runtimeID: "fresh-run", imageID: smpImageID,
                request: .init(vcpus: .three, memory: .m256, origin: .userSpecified), downgrade: .strict)
            XCTFail("corrupt image must not be hidden as a missing download")
        } catch RuntimeV2Error.migrationFailed { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.appendingPathComponent("manifest.json").path))
    }

    func testFirstMulticoreAdmissionImportsExistingImageBeforeCapabilityCheck() async throws {
        _ = try await store.prepareAndRecover(build: "old")
        _ = try await makeVerifiedImage(imageID: smpImageID, smpCapable: true, maxVCPUs: 3)
        let expanded = try await store.images.ensureExpanded(imageID: smpImageID)
        let legacy = root.appendingPathComponent("cold-legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: expanded, to: legacy.appendingPathComponent(smpImageID))
        let freshLayout = RuntimeV2Layout(root: root.appendingPathComponent("fresh-runtime"))
        let freshStore = RuntimeV2Store(layout: freshLayout)
        let integrator = RuntimeV2GuestIntegrator(store: freshStore, legacyImagesRoot: legacy, build: "new")
        let admitted = try await integrator.acquireShape(
            environmentID: "cold", runtimeID: "cold-run", imageID: smpImageID,
            request: .init(vcpus: .three, memory: .m256, origin: .userSpecified), downgrade: .strict
        )
        XCTAssertEqual(admitted.vcpus, 3)
        let verified = try await freshStore.images.isImageVerified(imageID: smpImageID)
        XCTAssertTrue(verified)
        // A new App build reuses the same local bytes and their capability.
        _ = try await freshStore.prepareAndRecover(build: "next-app-build")
        let capability = try await freshStore.images.smpCapability(imageID: smpImageID)
        XCTAssertEqual(capability.maximumVCPUs, 3)
    }

    func testAdmissionEvaluatesBootImageNotPinOrRow() async throws {
        let poolConfiguration = RuntimeVMPool.Configuration(
            quota: GuestResourceQuota(totalVCPUs: 4, totalMemoryMiB: 4096, maxVMs: 4),
            releasePolicy: GuestReleaseShapePolicy.internalSyntheticTesting(
                provenance: "LinuxSMPManifestHandoffTests admission gate image truth"
            ),
            queueLimit: 4, queueTimeout: 2, hostOverheadMiB: 0, futureReserveMiB: 0
        )
        store = RuntimeV2Store(layout: layout, poolConfiguration: poolConfiguration)
        _ = try await store.prepareAndRecover(build: "test")
        _ = try await makeVerifiedSMPImage()
        _ = try await makeVerifiedPlainImage()

        // An environment whose DURABLE records name the plain image boots the
        // SMP image (the descriptor carried the SMP image; the working disk
        // materialization is what proves them equal in production — see
        // deltaBase — and this start is exactly that case).
        let now = Date()
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: "env-mixed", kind: "linuxVM", ownerID: nil, name: "env-mixed",
                baseImageID: plainImageID, baseRootfsDigest: nil,
                state: "stopped", dataPath: nil, compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: nil, build: "test")
        let dual = GuestResourceRequest(vcpus: .two, memory: .m512, origin: .environmentPolicy)
        let granted = try await integrator.acquireShape(
            environmentID: "env-mixed", runtimeID: "rt-mixed",
            imageID: smpImageID, request: dual, downgrade: .strict
        )
        XCTAssertEqual(granted.vcpus, 2, "the gate must evaluate the image being booted")

        // The mirror image: durable records name the SMP image while the boot
        // descriptor carries the plain image — the start must be refused.
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: "env-reverse", kind: "linuxVM", ownerID: nil, name: "env-reverse",
                baseImageID: smpImageID, baseRootfsDigest: nil,
                state: "stopped", dataPath: nil, compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
        do {
            _ = try await integrator.acquireShape(
                environmentID: "env-reverse", runtimeID: "rt-reverse",
                imageID: plainImageID, request: dual, downgrade: .strict
            )
            XCTFail("a non-SMP boot image must not be granted two harts")
        } catch LinuxGuestError.smpUnsupportedByImage(let environmentID) {
            XCTAssertEqual(environmentID, "env-reverse")
        }
    }

    func testPlanReshapeEvaluatesBootImage() async throws {
        let poolConfiguration = RuntimeVMPool.Configuration(
            quota: GuestResourceQuota(totalVCPUs: 4, totalMemoryMiB: 4096, maxVMs: 4),
            releasePolicy: GuestReleaseShapePolicy.internalSyntheticTesting(
                provenance: "LinuxSMPManifestHandoffTests planReshape image truth"
            ),
            queueLimit: 4, queueTimeout: 2, hostOverheadMiB: 0, futureReserveMiB: 0
        )
        store = RuntimeV2Store(layout: layout, poolConfiguration: poolConfiguration)
        _ = try await store.prepareAndRecover(build: "test")
        _ = try await makeVerifiedSMPImage()
        _ = try await makeVerifiedPlainImage()
        let now = Date()
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: "env-reshape", kind: "linuxVM", ownerID: nil, name: "env-reshape",
                baseImageID: plainImageID, baseRootfsDigest: nil,
                state: "stopped", dataPath: nil, compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: nil, build: "test")
        let single = GuestResourceRequest(vcpus: .one, memory: .m512, origin: .environmentPolicy)
        _ = try await integrator.acquireShape(
            environmentID: "env-reshape", runtimeID: "rt-reshape",
            imageID: smpImageID, request: single, downgrade: .strict
        )
        // The running guest booted the SMP image (imageID passed here is the
        // descriptor image frozen at boot): planning a second hart is allowed.
        try await integrator.planReshape(
            environmentID: "env-reshape", ramMB: 1024, vcpus: 2, currentVCPUs: 1,
            imageID: smpImageID
        )
    }

    // MARK: verifier durable success snapshot (reopen latency)

    func testVerificationSuccessSurvivesRelaunchWithoutRehash() async throws {
        let directory = root.appendingPathComponent("image", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bios = Data("snapshot-bios".utf8)
        try bios.write(to: directory.appendingPathComponent("bios.bin"))
        var bytes = Data(count: 1 << 20)
        for index in bytes.indices { bytes[index] = UInt8(index % 251) }
        try bytes.write(to: directory.appendingPathComponent("rootfs.img"))
        let image = LinuxGuestImage(
            id: "snapshot-image",
            biosPath: "bios.bin",
            diskPath: "rootfs.img",
            qualified: true,
            qualificationRun: "snapshot-tests",
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: "bios.bin",
                    sha512: FloeDigest.sha512Hex(bios), bytes: Int64(bios.count)
                ),
                LinuxGuestImageArtifact(
                    role: .disk, path: "rootfs.img",
                    sha512: FloeDigest.sha512Hex(bytes), bytes: Int64(bytes.count)
                )
            ]
        )
        // First process: the real hash runs and the success is persisted.
        let first = LinuxGuestImageVerifier()
        let firstIssue = await first.verificationIssue(image: image, imageDirectory: directory)
        XCTAssertNil(firstIssue)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".floe-verified-legacy.json").path
            )
        )
        // Second process (fresh verifier, e.g. after an app relaunch): the
        // snapshot replays the success — this is the immediate settings status.
        let second = LinuxGuestImageVerifier()
        let secondIssue = await second.verificationIssue(image: image, imageDirectory: directory)
        XCTAssertNil(secondIssue)

        // Any byte-identity change (size here) invalidates the snapshot and
        // falls through to a real hash with an honest verdict.
        let grown = directory.appendingPathComponent("rootfs.img")
        let handle = try FileHandle(forWritingTo: grown)
        try handle.truncate(atOffset: UInt64(bytes.count) + 4096)
        try handle.close()
        let third = LinuxGuestImageVerifier()
        let thirdIssue = await third.verificationIssue(image: image, imageDirectory: directory)
        XCTAssertNotNil(thirdIssue)
    }

    func testVerificationFailureIsNeverPersisted() async throws {
        let directory = root.appendingPathComponent("image-fail", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bios = Data("failure-bios".utf8)
        try bios.write(to: directory.appendingPathComponent("bios.bin"))
        var bytes = Data(count: 1024)
        for index in bytes.indices { bytes[index] = UInt8(index % 251) }
        try bytes.write(to: directory.appendingPathComponent("rootfs.img"))
        let image = LinuxGuestImage(
            id: "snapshot-failure-image",
            biosPath: "bios.bin",
            diskPath: "rootfs.img",
            qualified: true,
            qualificationRun: "snapshot-tests",
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: "bios.bin",
                    sha512: FloeDigest.sha512Hex(bios), bytes: Int64(bios.count)
                ),
                LinuxGuestImageArtifact(
                    role: .disk, path: "rootfs.img",
                    sha512: FloeDigest.sha512Hex(Data(count: 1024)), bytes: 1024
                )
            ]
        )
        let first = LinuxGuestImageVerifier()
        let firstIssue = await first.verificationIssue(image: image, imageDirectory: directory)
        XCTAssertNotNil(firstIssue)
        // A fresh launch never replays the failure from a snapshot: with the
        // bytes now matching, the success is derived from real bytes.
        let corrected = LinuxGuestImage(
            id: image.id, biosPath: image.biosPath, diskPath: image.diskPath,
            diskReadWrite: image.diskReadWrite, cmdline: image.cmdline,
            qualified: true, qualificationRun: image.qualificationRun,
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: "bios.bin",
                    sha512: FloeDigest.sha512Hex(bios), bytes: Int64(bios.count)
                ),
                LinuxGuestImageArtifact(
                    role: .disk, path: "rootfs.img",
                    sha512: FloeDigest.sha512Hex(bytes), bytes: 1024
                )
            ]
        )
        let second = LinuxGuestImageVerifier()
        let secondIssue = await second.verificationIssue(image: corrected, imageDirectory: directory)
        XCTAssertNil(secondIssue)
    }

    // MARK: install-state derivation (running vs stopped vs uninstalled)

    func testRunningGuestWithVerifiedImageNeverDerivesNeedsDownload() {
        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = true
        facts.imageDistributable = true
        facts.guestRunning = true
        facts.guestEnvironmentID = "env-1"
        guard case .running(let runningID) = LinuxGuestInstallStateDerivation.state(from: facts) else {
            return XCTFail("a verified installed image with a running guest never renders the download entry")
        }
        XCTAssertEqual(runningID, "env-1")

        var stopped = LinuxGuestInstallFacts()
        stopped.storageAvailable = true
        stopped.imageInstalled = true
        stopped.imageDistributable = true
        stopped.guestRunning = false
        if case .installedStopped = LinuxGuestInstallStateDerivation.state(from: stopped) {} else {
            XCTFail("a verified installed stopped image must derive installedStopped")
        }
    }

    // MARK: fixtures

    private let smpImageID = "smp-boot-image"
    private let plainImageID = "plain-boot-image"

    @discardableResult
    private func makeVerifiedSMPImage() async throws -> RuntimeV2ImageStore.Manifest {
        try await makeVerifiedImage(imageID: smpImageID, smpCapable: true)
    }

    @discardableResult
    private func makeVerifiedPlainImage() async throws -> RuntimeV2ImageStore.Manifest {
        try await makeVerifiedImage(imageID: plainImageID, smpCapable: nil)
    }

    private func makeVerifiedImage(
        imageID: String, smpCapable: Bool?, maxVCPUs: Int? = nil
    ) async throws -> RuntimeV2ImageStore.Manifest {
        let legacyRoot = root.appendingPathComponent("legacy-\(imageID)", isDirectory: true)
        let directory = legacyRoot.appendingPathComponent(imageID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bios = Data(count: 4096)
        for index in bios.indices { bios[index] = UInt8((index &* 31) % 251) }
        var rootfs = Data(count: 3 << 20)
        for index in rootfs.indices { rootfs[index] = UInt8((index &* 17) % 253) }
        try bios.write(to: directory.appendingPathComponent("bios.bin"))
        try rootfs.write(to: directory.appendingPathComponent("rootfs.img"))
        let image = LinuxGuestImage(
            id: imageID,
            biosPath: "bios.bin",
            diskPath: "rootfs.img",
            qualified: true,
            qualificationRun: "smp-handoff-tests",
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
        var manifestData = try encoder.encode(image)
        if let smpCapable {
            var object = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] ?? [:]
            object["smp_capable"] = smpCapable
            if let maxVCPUs { object["max_vcpus"] = maxVCPUs }
            manifestData = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]
            )
        }
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"))
        _ = try await store.images.migrateLegacyImage(
            imageID: imageID, legacyImagesRoot: legacyRoot
        )
        let storedManifest = try await store.images.manifest(imageID: imageID)
        let manifest = try XCTUnwrap(storedManifest)
        return manifest
    }
}
