// FloeExecutionTests — Runtime v2 immutable software templates and private
// environment reuse.
//
// These tests drive the real substrate (SQLite registry, content-addressed
// blob store, block deltas, APFS clone/copy behavior) with a scripted
// installer. They pin the contracts that matter:
//
//   - a template version is a COMPLETE installed disk, content-addressed and
//     immutable; identical software is the same version, changed software is a
//     new version;
//   - the build clones the parent disk first and records clone vs copy
//     honestly, with real logical/allocated/download bytes;
//   - an environment boots exactly its pinned template version (never
//     "latest") plus its own private delta, and an old delta is refused
//     against any other base or template version;
//   - sessions of one environment share that install while one write lease is
//     held; separate environments never share install state;
//   - reference recycling / GC protect environment pins, catalog offers,
//     in-flight builds, recovery points and quarantine;
//   - migration records the actual base without reinstalling or rewriting
//     content;
//   - the two official templates report dependency-missing until the actual
//     image is registered, and no placeholder is ever accepted.

import Foundation
import XCTest
import FloeCore
@testable import FloeExecution

final class RuntimeV2TemplateTests: XCTestCase {
    private var root: URL!
    private var layout: RuntimeV2Layout!
    private var store: RuntimeV2Store!

    private let baseImageID = "base-image"
    private let otherImageID = "base-image-2"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-v2-templates-\(UUID().uuidString)", isDirectory: true)
        layout = RuntimeV2Layout(root: root)
        store = RuntimeV2Store(layout: layout)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - fixtures

    /// A minimal qualified legacy image (manifest + two real artifacts with
    /// truthful SHA-512 digests), migrated into the verified content-addressed
    /// store as a bootable base image.
    @discardableResult
    private func makeVerifiedBaseImage(
        imageID: String, rootfsSeed: UInt8 = 17, rootfsBytes: Int = 3 << 20,
        smpCapable: Bool? = nil
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
            qualificationRun: "runtime-v2-template-tests",
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
            // A capability declaration travels in the image manifest; the
            // legacy struct does not model it, so it is injected at the JSON
            // level exactly like an image build would emit it.
            var object = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] ?? [:]
            object["smp_capable"] = smpCapable
            manifestData = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
            )
        }
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"))
        _ = try await store.images.migrateLegacyImage(imageID: imageID, legacyImagesRoot: legacyRoot)
        guard let manifest = try await store.images.manifest(imageID: imageID) else {
            throw RuntimeV2Error.imageNotFound(imageID)
        }
        return manifest
    }

    private func rootfsRef(_ manifest: RuntimeV2ImageStore.Manifest) throws -> RuntimeV2ImageStore.Manifest.ArtifactRef {
        guard let ref = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"] else {
            throw RuntimeV2Error.imageNotFound(manifest.imageID)
        }
        return ref
    }

    private func baseParent(_ ref: RuntimeV2ImageStore.Manifest.ArtifactRef, imageID: String) -> RuntimeV2TemplateStore.ParentSource {
        RuntimeV2TemplateStore.ParentSource(
            kind: .baseImage, id: imageID, version: nil, digest: ref.sha512.lowercased()
        )
    }

    private func recipe(
        name: String = "basic", packages: [String: RuntimeV2TemplateRecipe.Requirement]
    ) -> RuntimeV2TemplateRecipe {
        RuntimeV2TemplateRecipe(name: name, packages: packages)
    }

    private func buildRequest(
        templateID: String = "basic",
        version: Int = 1,
        recipe: RuntimeV2TemplateRecipe,
        parent: RuntimeV2TemplateStore.ParentSource,
        targetCapacityBytes: Int64 = 4 << 20,
        retainCatalogReference: Bool = false
    ) -> RuntimeV2TemplateStore.BuildRequest {
        RuntimeV2TemplateStore.BuildRequest(
            templateID: templateID, version: version, recipe: recipe, parent: parent,
            architecture: "riscv64", targetCapacityBytes: targetCapacityBytes,
            retainCatalogReference: retainCatalogReference
        )
    }

    private func package(_ name: String, _ version: String, source: String = "apt") -> RuntimeV2TemplateStore.InstalledSoftware {
        RuntimeV2TemplateStore.InstalledSoftware(
            name: name, version: version, architecture: "riscv64", source: source,
            installState: "installed"
        )
    }

    /// Probes whether this volume actually supports clonefile, so the mode
    /// assertion is a real observation rather than an assumption.
    private func volumeSupportsClone() -> Bool {
        #if canImport(Darwin)
        let source = root.appendingPathComponent("probe-source-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("probe-dest-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        guard (try? Data(repeating: 1, count: 4096).write(to: source)) != nil else { return false }
        return clonefile(source.path, destination.path, 0) == 0
        #else
        return false
        #endif
    }

    private struct ScriptedInstaller: RuntimeV2TemplateInstaller {
        var markerOffset: Int64 = 2 << 20
        var markerBytes: Data = Data(repeating: 0xAB, count: 4096)
        var packages: [RuntimeV2TemplateStore.InstalledSoftware]
        var downloadBytes: Int64
        var missingPackages: [String] = []
        var verified: Bool = true

        func install(
            build: RuntimeV2TemplateStore.BuildHandle,
            request: RuntimeV2TemplateStore.BuildRequest
        ) async throws -> RuntimeV2TemplateStore.InstallOutcome {
            let handle = try FileHandle(forWritingTo: build.workingDiskURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(markerOffset))
            try handle.write(contentsOf: markerBytes)
            try handle.synchronize()
            return RuntimeV2TemplateStore.InstallOutcome(
                packages: packages, downloadBytes: downloadBytes,
                missingPackages: missingPackages, notes: ["scripted install"],
                verified: verified
            )
        }
    }

    // MARK: - build: clone/copy truth, digests, measured bytes

    func testTemplateBuildRecordsCloneModeAndMeasuredBytes() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let request = buildRequest(
            recipe: recipe(packages: ["python3": .init(minVersion: "3.9"), "nodejs": .init()]),
            parent: baseParent(ref, imageID: baseImageID)
        )
        let installer = ScriptedInstaller(
            packages: [package("python3", "3.11.2"), package("nodejs", "20.11.0")],
            downloadBytes: 123_456
        )
        let registration = try await store.templates.build(using: installer, request: request)

        // The version is real and immutable, with a deterministic content digest.
        XCTAssertEqual(registration.pin.templateID, "basic")
        XCTAssertEqual(registration.pin.version, 1)
        XCTAssertEqual(registration.pin.digest.count, 128)
        XCTAssertEqual(registration.packages.count, 2)
        XCTAssertEqual(registration.downloadBytes, 123_456)
        XCTAssertTrue(registration.privateStateExcluded.contains("home"))
        XCTAssertTrue(registration.privateStateExcluded.contains("credentials"))
        XCTAssertFalse(registration.privateStateExcluded.contains("usr"))

        // The recorded mode is the mode that actually happened on this volume.
        XCTAssertEqual(registration.buildMode, volumeSupportsClone() ? .clone : .copy)

        // Real byte accounting: the disk was grown to the requested logical
        // capacity, allocated bytes are measured (not invented), and the
        // download figure is the installer's own report.
        XCTAssertEqual(registration.logicalBytes, 4 << 20)
        XCTAssertNotNil(registration.allocatedBytes)
        let row = try await store.templates.version(templateID: "basic", version: 1)
        XCTAssertEqual(row?.state, .verified)
        XCTAssertEqual(row?.diskDigest, registration.diskDigest)
        XCTAssertEqual(row?.buildMode, registration.buildMode.rawValue)
        XCTAssertEqual(row?.downloadBytes, 123_456)
        XCTAssertEqual(row?.parentKind, "base-image")
        XCTAssertEqual(row?.parentDigest, ref.sha512.lowercased())

        // The complete disk is one content-addressed blob, referenced once.
        let blob = try await store.registry.blob(digest: registration.diskDigest)
        XCTAssertEqual(blob?.refs, 1)
        XCTAssertEqual(blob?.bytes, registration.logicalBytes)
        let floeAsyncValue1 = try await store.blobs.blobExists(digest: registration.diskDigest)
        XCTAssertTrue(floeAsyncValue1)

        // The package DB listing travels with the immutable version.
        let packages = try await store.templates.packages(templateID: "basic", version: 1)
        XCTAssertEqual(packages.map(\.name), ["nodejs", "python3"])

        // Evidence/recovery point retained; the large staging clone is gone.
        let evidence = layout.recoveryMigrationsDirectory
            .appendingPathComponent("template-basic-v1/template-evidence.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.path))
        let runtimeTmp = try FileManager.default.contentsOfDirectory(atPath: layout.runtimeTmpDirectory.path)
        XCTAssertFalse(runtimeTmp.contains { $0.hasPrefix("template-build-") })
        let references = try await store.templates.references(templateID: "basic", version: 1)
        XCTAssertTrue(references.contains { $0.refKind == "recovery" })
        XCTAssertFalse(references.contains { $0.refKind == "build" })
    }

    func testTemplateBuildCopyFallbackRecordsCopyMode() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let seams = RuntimeV2TemplateStore.Seams(
            cloneFile: { _, _ in false },
            availableBytes: { _ in Int64.max }
        )
        store = RuntimeV2Store(layout: layout, templateSeams: seams)
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let installer = ScriptedInstaller(
            packages: [package("python3", "3.11.2")], downloadBytes: 7
        )
        let registration = try await store.templates.build(
            using: installer,
            request: buildRequest(
                recipe: recipe(packages: ["python3": .init(minVersion: "3.9")]),
                parent: baseParent(ref, imageID: baseImageID)
            )
        )
        XCTAssertEqual(registration.buildMode, .copy)
        XCTAssertEqual(registration.logicalBytes, 4 << 20)
        XCTAssertNotNil(registration.allocatedBytes)
    }

    func testCloneFailureWithoutSpaceFailsBeforeWritingACopy() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let seams = RuntimeV2TemplateStore.Seams(
            cloneFile: { _, _ in false },
            availableBytes: { _ in 1 << 20 }
        )
        store = RuntimeV2Store(layout: layout, templateSeams: seams)
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        do {
            _ = try await store.templates.stageBuild(
                buildRequest(
                    recipe: recipe(packages: ["python3": .init()]),
                    parent: baseParent(ref, imageID: baseImageID)
                )
            )
            XCTFail("a copy that cannot fit must fail before writing")
        } catch RuntimeV2Error.insufficientSpace(let required, let available) {
            XCTAssertGreaterThan(required, available)
            XCTAssertGreaterThanOrEqual(required, ref.bytes)
        }
        // Nothing was registered, and no staging clone survived.
        let floeAsyncValue2 = try await store.templates.version(templateID: "basic", version: 1)
        XCTAssertNil(floeAsyncValue2)
        let tmp = try FileManager.default.contentsOfDirectory(atPath: layout.runtimeTmpDirectory.path)
        XCTAssertFalse(tmp.contains { $0.hasPrefix("template-build-") })
    }

    // MARK: - verification honesty

    func testMissingSoftwareIsExplicitlyOmittedAndNeverVerified() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let request = buildRequest(
            recipe: recipe(packages: ["python3": .init(minVersion: "3.9"), "nodejs": .init()]),
            parent: baseParent(ref, imageID: baseImageID)
        )
        let incomplete = ScriptedInstaller(
            packages: [package("nodejs", "20.11.0")], downloadBytes: 10
        )
        do {
            _ = try await store.templates.build(using: incomplete, request: request)
            XCTFail("a recipe gap must never register a verified template")
        } catch RuntimeV2Error.templateRequirementMissing(_, _, let missing) {
            XCTAssertEqual(missing, ["python3"])
        }
        let failed = try await store.templates.version(templateID: "basic", version: 1)
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertTrue(failed?.reason?.contains("python3") == true)
        XCTAssertNil(failed?.diskDigest)
        // The failed attempt's incomplete install is quarantined, not bootable.
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("template-basic-v1") }
        XCTAssertEqual(quarantined.count, 1)

        // An installer that cannot verify its own work is refused as well.
        let unverified = ScriptedInstaller(
            packages: [package("python3", "3.11.2"), package("nodejs", "20.11.0")],
            downloadBytes: 10, verified: false
        )
        do {
            _ = try await store.templates.build(using: unverified, request: request)
            XCTFail("an unverified install must never be registered")
        } catch RuntimeV2Error.templateInstallerUnverified {
            // expected
        }

        // A failed version can be retried; a verified version cannot be rewritten.
        let complete = ScriptedInstaller(
            packages: [package("python3", "3.11.2"), package("nodejs", "20.11.0")],
            downloadBytes: 10
        )
        let registration = try await store.templates.build(using: complete, request: request)
        XCTAssertEqual(registration.pin.version, 1)
        let versionState = try await store.templates.version(templateID: "basic", version: 1)?.state
        XCTAssertEqual(versionState, .verified)
        do {
            _ = try await store.templates.stageBuild(request)
            XCTFail("a verified version is immutable")
        } catch RuntimeV2Error.templateVersionImmutable {
            // expected
        }
    }

    func testRequirementBelowMinVersionIsUnsatisfied() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let request = buildRequest(
            recipe: recipe(packages: ["python3": .init(minVersion: "3.11")]),
            parent: baseParent(ref, imageID: baseImageID)
        )
        let oldPython = ScriptedInstaller(packages: [package("python3", "3.9.2")], downloadBytes: 1)
        do {
            _ = try await store.templates.build(using: oldPython, request: request)
            XCTFail("the minimum version is enforced against the real package DB")
        } catch RuntimeV2Error.templateRequirementMissing(_, _, let missing) {
            XCTAssertEqual(missing, ["python3 (3.9.2 < 3.11)"])
        }
        let floeAsyncValue3 = try await store.templates.version(templateID: "basic", version: 1)?.state
        XCTAssertEqual(floeAsyncValue3, .failed)
    }

    // MARK: - environment pinning, clone reuse and no illegal rebase

    func testEnvironmentPinsExactTemplateVersionAndOldDeltaIsNeverRebased() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let parent = baseParent(ref, imageID: baseImageID)

        let v1 = try await store.templates.build(
            using: ScriptedInstaller(
                markerBytes: Data(repeating: 0x11, count: 4096),
                packages: [package("python3", "3.11.2")], downloadBytes: 1
            ),
            request: buildRequest(version: 1, recipe: recipe(packages: ["python3": .init()]), parent: parent)
        )
        let v2 = try await store.templates.build(
            using: ScriptedInstaller(
                markerBytes: Data(repeating: 0x22, count: 4096),
                packages: [package("python3", "3.12.0"), package("nodejs", "20.11.0")],
                downloadBytes: 2
            ),
            request: buildRequest(version: 2, recipe: recipe(packages: ["python3": .init()]), parent: parent)
        )
        XCTAssertNotEqual(v1.pin.digest, v2.pin.digest)

        // Environment registered on the base image, then pinned to v1 exactly.
        let now = Date()
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: "env-a", kind: "linuxVM", ownerID: nil, name: "A",
                baseImageID: baseImageID, baseRootfsDigest: ref.sha512.lowercased(),
                state: "stopped", dataPath: "environments/env-a/data", compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
        let pin = try await store.templates.pinEnvironment(
            environmentID: "env-a", templateID: "basic", version: 1
        )
        XCTAssertEqual(pin.digest, v1.pin.digest)
        let v1References = try await store.templates.references(templateID: "basic", version: 1)
        XCTAssertTrue(v1References.contains { $0.refKind == "environment" && $0.refID == "env-a" })
        XCTAssertTrue(v1References.contains { $0.refKind == "recovery" })
        XCTAssertFalse(v1References.contains { $0.refKind == "build" })

        // The pinned boot clones v1's complete disk exactly — not v2's.
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = directory.appendingPathComponent("disk.img")
        let clone = try await store.templates.clonePinnedTemplateDisk(
            environmentID: "env-a", runtimeID: "rt-a", imageID: baseImageID, into: disk
        )
        XCTAssertEqual(clone?.pin, pin)
        XCTAssertEqual(clone?.mode, volumeSupportsClone() ? .clone : .copy)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: disk), v1.diskDigest)

        // A's private work. The capture base is the pinned template's own disk
        // (resolved through the store), so the delta must hold ONLY A's
        // modified block — never a second copy of the shared install.
        let handle = try FileHandle(forWritingTo: disk)
        try handle.seek(toOffset: 3 << 20)
        try handle.write(contentsOf: Data(repeating: 0xA1, count: 4096))
        try handle.close()
        let deltaBase = try await store.templates.deltaBase(
            environmentID: "env-a", imageID: baseImageID,
            baseRootfs: root.appendingPathComponent("unused-rootfs.img"), baseRootfsSHA512: ref.sha512
        )
        XCTAssertEqual(deltaBase.templatePin, pin)
        XCTAssertEqual(deltaBase.digest, v1.diskDigest)
        XCTAssertNotEqual(deltaBase.diskURL, disk)
        let delta = try await store.deltas.capture(
            environmentID: "env-a", workingDisk: disk,
            baseRootfs: deltaBase.diskURL, baseImageID: baseImageID,
            baseRootfsSHA512: deltaBase.digest, templatePin: deltaBase.templatePin
        )
        XCTAssertEqual(delta.presentBlocks, 1)
        XCTAssertEqual(delta.deltaBytes, 1 << 20)

        // (a) The delta is refused against v2's disk: an old delta never
        //     applies to a new template version.
        do {
            _ = try await store.deltas.applyDelta(
                environmentID: "env-a", expectedBaseRootfsSHA512: deltaBase.digest,
                expectedTemplate: v2.pin, into: disk
            )
            XCTFail("applying a v1 delta over v2 must fail")
        } catch RuntimeV2Error.deltaTemplateConflict(_, let recorded, let verified) {
            XCTAssertTrue(recorded.contains("template basic@1"))
            XCTAssertTrue(verified.contains("basic@2"))
        }
        // (b) It is refused over a plain base image boot too (same delta base
        //     identity, but no template pin): a template-captured delta never
        //     folds into a base-image environment.
        do {
            _ = try await store.deltas.applyDelta(
                environmentID: "env-a", expectedBaseRootfsSHA512: deltaBase.digest,
                expectedTemplate: nil, into: disk
            )
            XCTFail("applying a template delta over the base image must fail")
        } catch RuntimeV2Error.deltaTemplateConflict {
            // expected
        }
        // (b2) A different base digest is refused by the base binding.
        do {
            _ = try await store.deltas.applyDelta(
                environmentID: "env-a", expectedBaseRootfsSHA512: ref.sha512,
                expectedTemplate: pin, into: disk
            )
            XCTFail("applying a delta over a different base digest must fail")
        } catch RuntimeV2Error.deltaBaseConflict {
            // expected
        }
        // (c) The exact pin re-applies and reproduces A's bytes.
        _ = try await store.deltas.applyDelta(
            environmentID: "env-a", expectedBaseRootfsSHA512: deltaBase.digest,
            expectedTemplate: pin, into: disk
        )
        let check = try FileHandle(forReadingFrom: disk)
        try check.seek(toOffset: 3 << 20)
        let bytes = try check.read(upToCount: 4096)
        try check.close()
        XCTAssertEqual(bytes, Data(repeating: 0xA1, count: 4096))

        // Pinning a version that does not exist, or one built on another base
        // image, fails closed.
        do {
            _ = try await store.templates.pinEnvironment(
                environmentID: "env-a", templateID: "basic", version: 99
            )
            XCTFail("a missing version must not be pinnable")
        } catch RuntimeV2Error.templateNotFound {
            // expected
        }
        _ = try await makeVerifiedBaseImage(imageID: otherImageID, rootfsSeed: 29)
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: "env-other", kind: "linuxVM", ownerID: nil, name: "Other",
                baseImageID: otherImageID, baseRootfsDigest: nil,
                state: "stopped", dataPath: nil, compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
        do {
            _ = try await store.templates.pinEnvironment(
                environmentID: "env-other", templateID: "basic", version: 1
            )
            XCTFail("a template built on another base image must not be pinnable")
        } catch RuntimeV2Error.templateBaseImageMismatch {
            // expected
        }

        // The environment's reuse summary is honest about what it shares.
        let summary = try await store.templates.environmentReuseSummary(environmentID: "env-a")
        XCTAssertTrue(summary.contains("basic@1"))
        XCTAssertTrue(summary.contains("private delta"))
    }

    func testCloneReuseAndPackageChangeDoesNotAffectOtherEnvironment() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let parent = baseParent(ref, imageID: baseImageID)
        let template = try await store.templates.build(
            using: ScriptedInstaller(
                markerBytes: Data(repeating: 0x33, count: 4096),
                packages: [package("python3", "3.11.2")], downloadBytes: 5
            ),
            request: buildRequest(recipe: recipe(packages: ["python3": .init()]), parent: parent)
        )
        let now = Date()
        for id in ["env-b", "env-c"] {
            try await store.registry.upsertEnvironment(
                RuntimeV2Registry.EnvironmentRow(
                    id: id, kind: "linuxVM", ownerID: nil, name: id,
                    baseImageID: baseImageID, baseRootfsDigest: ref.sha512.lowercased(),
                    state: "stopped", dataPath: "environments/\(id)/data", compatHostFHS: false,
                    repairReason: nil, createdAt: now, lastUsedAt: now
                )
            )
            _ = try await store.templates.pinEnvironment(
                environmentID: id, templateID: "basic", version: 1
            )
        }
        // Both boot disks are clones of the SAME template blob.
        let bDirectory = try layout.runtimeVMDirectory(runtimeID: "rt-b")
        let cDirectory = try layout.runtimeVMDirectory(runtimeID: "rt-c")
        try FileManager.default.createDirectory(at: bDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cDirectory, withIntermediateDirectories: true)
        let bDisk = bDirectory.appendingPathComponent("disk.img")
        let cDisk = cDirectory.appendingPathComponent("disk.img")
        let bClone = try await store.templates.clonePinnedTemplateDisk(
            environmentID: "env-b", runtimeID: "rt-b", imageID: baseImageID, into: bDisk
        )
        let cClone = try await store.templates.clonePinnedTemplateDisk(
            environmentID: "env-c", runtimeID: "rt-c", imageID: baseImageID, into: cDisk
        )
        XCTAssertEqual(bClone?.pin, cClone?.pin)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: bDisk), template.diskDigest)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: cDisk), template.diskDigest)
        // One shared blob, still referenced exactly once.
        let floeAsyncValue5 = try await store.registry.blob(digest: template.diskDigest)?.refs
        XCTAssertEqual(floeAsyncValue5, 1)

        // Environment B installs a package (writes private bytes) and captures
        // against the pinned template disk, so only its own block is recorded.
        let bHandle = try FileHandle(forWritingTo: bDisk)
        try bHandle.seek(toOffset: 1 << 20)
        try bHandle.write(contentsOf: Data(repeating: 0xB7, count: 8192))
        try bHandle.close()
        let pin = try XCTUnwrap(bClone?.pin)
        let bDeltaBase = try await store.templates.deltaBase(
            environmentID: "env-b", imageID: baseImageID,
            baseRootfs: root.appendingPathComponent("unused.img"), baseRootfsSHA512: ref.sha512
        )
        let delta = try await store.deltas.capture(
            environmentID: "env-b", workingDisk: bDisk,
            baseRootfs: bDeltaBase.diskURL,
            baseImageID: baseImageID, baseRootfsSHA512: bDeltaBase.digest, templatePin: pin
        )
        XCTAssertEqual(delta.presentBlocks, 1)

        // Environment C is untouched: its fresh clone carries only the
        // template's bytes, and it has no delta of its own.
        let floeAsyncValue6 = try await store.deltas.loadDelta(environmentID: "env-c")
        XCTAssertNil(floeAsyncValue6)
        let cCheck = try FileHandle(forReadingFrom: cDisk)
        try cCheck.seek(toOffset: 1 << 20)
        let cBytes = try cCheck.read(upToCount: 8192)
        try cCheck.close()
        XCTAssertNotEqual(cBytes, Data(repeating: 0xB7, count: 8192))
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: cDisk), template.diskDigest)

        // B re-materializes with its private delta restored.
        try FileManager.default.removeItem(at: bDisk)
        _ = try await store.templates.clonePinnedTemplateDisk(
            environmentID: "env-b", runtimeID: "rt-b", imageID: baseImageID, into: bDisk
        )
        _ = try await store.deltas.applyDelta(
            environmentID: "env-b", expectedBaseRootfsSHA512: bDeltaBase.digest,
            expectedTemplate: pin, into: bDisk
        )
        let bCheck = try FileHandle(forReadingFrom: bDisk)
        try bCheck.seek(toOffset: 1 << 20)
        let bBytes = try bCheck.read(upToCount: 8192)
        try bCheck.close()
        XCTAssertEqual(bBytes, Data(repeating: 0xB7, count: 8192))
    }

    func testSessionsShareInstallWithOneWriteLease() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let template = try await store.templates.build(
            using: ScriptedInstaller(packages: [package("python3", "3.11.2")], downloadBytes: 1),
            request: buildRequest(
                recipe: recipe(packages: ["python3": .init()]),
                parent: baseParent(ref, imageID: baseImageID)
            )
        )
        let now = Date()
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: "env-share", kind: "linuxVM", ownerID: nil, name: "Share",
                baseImageID: baseImageID, baseRootfsDigest: ref.sha512.lowercased(),
                state: "active", dataPath: nil, compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
        _ = try await store.templates.pinEnvironment(
            environmentID: "env-share", templateID: "basic", version: 1
        )
        XCTAssertEqual(template.pin.version, 1)
        let lease = try await store.leases.acquire(environmentID: "env-share", runtimeID: "rt-1")
        // The second session sees the shared pin and the single writer.
        let sharing = try await store.templates.sessionSharing(environmentID: "env-share")
        XCTAssertEqual(sharing.pin?.version, 1)
        XCTAssertEqual(sharing.writeLeaseRuntimeID, "rt-1")
        // A second concurrent writer is refused while the first holds the lease.
        do {
            _ = try await store.leases.acquire(environmentID: "env-share", runtimeID: "rt-2")
            XCTFail("a second writer must be refused")
        } catch RuntimeV2Error.leaseHeld {
            // expected
        }
        // The pin cannot be switched under a running guest.
        do {
            try await store.templates.unpinEnvironment(environmentID: "env-share")
            XCTFail("unpinning under a live lease must be refused")
        } catch RuntimeV2Error.templateEnvironmentRunning {
            // expected
        }
        await lease.release()
        try await store.templates.unpinEnvironment(environmentID: "env-share")
        let floeAsyncValue7 = try await store.templates.environmentPin(environmentID: "env-share")
        XCTAssertNil(floeAsyncValue7)
    }

    // MARK: - reference recycling and GC

    func testReferenceRecyclingAndGCProtections() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let parent = baseParent(ref, imageID: baseImageID)
        let template = try await store.templates.build(
            using: ScriptedInstaller(packages: [package("python3", "3.11.2")], downloadBytes: 1),
            request: buildRequest(recipe: recipe(packages: ["python3": .init()]), parent: parent)
        )
        // While the recovery point exists, GC must not collect the version.
        var report = try await store.templates.collectGarbage(grace: 0)
        XCTAssertTrue(report.collected.isEmpty)
        let versionState = try await store.templates.version(templateID: "basic", version: 1)?.state
        XCTAssertEqual(versionState, .verified)
        // Finalizing the build releases the recovery reference; now the
        // unreferenced version is collected and its blob reference released.
        let finalized = try await store.templates.finalizeBuilds()
        XCTAssertEqual(finalized, 1)
        let floeAsyncValue8 = try await store.templates.referenceCount(templateID: "basic", version: 1)
        XCTAssertEqual(floeAsyncValue8, 0)
        report = try await store.templates.collectGarbage(grace: 0)
        XCTAssertEqual(report.collected, ["basic@1"])
        XCTAssertEqual(report.releasedBlobDigests, [template.diskDigest])
        XCTAssertGreaterThan(report.reclaimableBytes, 0)
        let floeAsyncValue9 = try await store.registry.blob(digest: template.diskDigest)?.refs
        XCTAssertEqual(floeAsyncValue9, 0)
        let quarantinedState = try await store.templates.version(templateID: "basic", version: 1)?.state
        XCTAssertEqual(quarantinedState, .quarantined)
        // The collected version is quarantined (never hard-deleted) and can
        // never be pinned again.
        let now = Date()
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: "env-gc", kind: "linuxVM", ownerID: nil, name: "GC",
                baseImageID: baseImageID, baseRootfsDigest: ref.sha512.lowercased(),
                state: "stopped", dataPath: nil, compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
        do {
            _ = try await store.templates.pinEnvironment(
                environmentID: "env-gc", templateID: "basic", version: 1
            )
            XCTFail("a collected version must not be pinnable")
        } catch RuntimeV2Error.templateNotVerified(let templateID, let version, let reason) {
            XCTAssertEqual(templateID, "basic")
            XCTAssertEqual(version, 1)
            XCTAssertTrue(reason?.contains("collected") == true)
        }
        let floeAsyncValue10 = try await store.templates.version(templateID: "basic", version: 1)?.state
        XCTAssertEqual(floeAsyncValue10, .quarantined)

        // A pinned version is protected; an environment pin keeps it alive.
        let second = try await store.templates.build(
            using: ScriptedInstaller(
                markerBytes: Data(repeating: 0x44, count: 4096),
                packages: [package("python3", "3.12.0")], downloadBytes: 2
            ),
            request: buildRequest(version: 2, recipe: recipe(packages: ["python3": .init()]), parent: parent)
        )
        _ = try await store.templates.finalizeBuilds()
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: "env-pin", kind: "linuxVM", ownerID: nil, name: "Pin",
                baseImageID: baseImageID, baseRootfsDigest: ref.sha512.lowercased(),
                state: "stopped", dataPath: nil, compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
        _ = try await store.templates.pinEnvironment(
            environmentID: "env-pin", templateID: "basic", version: 2
        )
        report = try await store.templates.collectGarbage(grace: 0)
        XCTAssertFalse(report.collected.contains("basic@2"))
        let pinnedState = try await store.templates.version(templateID: "basic", version: 2)?.state
        XCTAssertEqual(pinnedState, .verified)
        let floeAsyncValue11 = try await store.registry.blob(digest: second.diskDigest)?.refs
        XCTAssertEqual(floeAsyncValue11, 1)
        // Even if the reference ROW is lost, the environment pin itself still
        // protects the version (belt and braces): GC skips it explicitly.
        try await store.registry.removeTemplateReference(
            templateID: "basic", version: 2, kind: "environment", refID: "env-pin"
        )
        report = try await store.templates.collectGarbage(grace: 0)
        XCTAssertTrue(report.skippedPinned.contains("basic@2"))
        XCTAssertFalse(report.collected.contains("basic@2"))
        let stillPinnedState = try await store.templates.version(templateID: "basic", version: 2)?.state
        XCTAssertEqual(stillPinnedState, .verified)

        // Catalog offers (official templates) are protected too.
        let artifact = try await makeOfficialArtifactDisk(
            seed: 0x5A, recipe: recipe(packages: ["python3": .init()])
        )
        let catalog = try await store.templates.registerOfficialTemplate(
            RuntimeV2TemplateStore.OfficialTemplateArtifact(
                templateID: "basic", version: 3, recipe: recipe(packages: ["python3": .init()]),
                parent: parent, architecture: "riscv64", diskURL: artifact.diskURL,
                packages: [package("python3", "3.12.1")], downloadBytes: 3,
                missingPackages: [], installVerified: true, provenance: "ci-run-1"
            )
        )
        _ = try await store.templates.finalizeBuilds()
        report = try await store.templates.collectGarbage(grace: 0)
        XCTAssertFalse(report.collected.contains("basic@3"))
        let catalogRefs = try await store.templates.references(templateID: "basic", version: 3)
        XCTAssertTrue(catalogRefs.contains { $0.refKind == "catalog" })
        let floeAsyncValue12 = try await store.registry.blob(digest: catalog.diskDigest)?.refs
        XCTAssertEqual(floeAsyncValue12, 1)
    }

    // MARK: - interrupted builds

    func testInterruptedBuildRecoveryMarksFailedAndQuarantinesStaging() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let handle = try await store.templates.stageBuild(
            buildRequest(
                recipe: recipe(packages: ["python3": .init()]),
                parent: baseParent(ref, imageID: baseImageID)
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: handle.stagingDirectory.path))
        let floeAsyncValue13 = try await store.templates.version(templateID: "basic", version: 1)?.state
        XCTAssertEqual(floeAsyncValue13, .building)

        // A relaunch recovers: the unverified build is failed, never verified.
        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertGreaterThanOrEqual(report.interruptedTemplateBuilds, 1)
        let row = try await relaunched.templates.version(templateID: "basic", version: 1)
        XCTAssertEqual(row?.state, .failed)
        XCTAssertTrue(row?.reason?.contains("interrupted") == true)
        XCTAssertNil(row?.diskDigest)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("template-basic-v1") }
        XCTAssertEqual(quarantined.count, 1)
        let tmp = try FileManager.default.contentsOfDirectory(atPath: layout.runtimeTmpDirectory.path)
        XCTAssertFalse(tmp.contains { $0.hasPrefix("template-build-") })
    }

    // MARK: - migration of existing environments

    func testMigrationRecordsActualBaseWithoutReinstallOrTemplatePin() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let expanded = try await store.images.ensureExpanded(imageID: baseImageID)
        let baseRootfs = expanded.appendingPathComponent(ref.expandedPath)

        // A legacy environment disk: clone of the verified base with one
        // modified block, plus its origin sidecar.
        let diskDirectory = root.appendingPathComponent("legacy-disks/env-migrated", isDirectory: true)
        try FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        let legacyDisk = diskDirectory.appendingPathComponent("disk.img")
        try FileManager.default.copyItem(at: baseRootfs, to: legacyDisk)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: legacyDisk.path)
        let handle = try FileHandle(forUpdating: legacyDisk)
        try handle.seek(toOffset: 1 << 20)
        try handle.write(contentsOf: Data(repeating: 0x7E, count: 4096))
        try handle.close()
        let origin = LinuxGuestRuntimeDiskOrigin(
            imageID: baseImageID, artifactSHA512: ref.sha512, artifactBytes: ref.bytes
        )
        let originEncoder = JSONEncoder()
        originEncoder.dateEncodingStrategy = .iso8601
        try originEncoder.encode(origin).write(
            to: diskDirectory.appendingPathComponent("origin.json"), options: .atomic
        )

        let migrator = RuntimeV2EnvironmentMigrator(store: store)
        let report = try await migrator.migrateLegacyEnvironment(
            environmentID: "env-migrated", kind: "linuxVM", ownerID: nil, name: nil,
            baseImageID: baseImageID, legacyDiskDirectory: diskDirectory, legacyLayerDirectory: nil
        )
        XCTAssertEqual(report.phase, .cleanupPending)
        let row = try await store.registry.environment(id: "env-migrated")
        XCTAssertEqual(row?.baseImageID, baseImageID)
        XCTAssertEqual(row?.baseRootfsDigest, ref.sha512.lowercased())
        // Existing environments are recorded as base-only: no invented pin.
        XCTAssertNil(row?.templateID)
        XCTAssertNil(row?.templateVersion)
        XCTAssertNil(row?.templateDigest)
        let floeAsyncValue14 = try await store.templates.environmentPin(environmentID: "env-migrated")
        XCTAssertNil(floeAsyncValue14)
        let summary = try await store.templates.environmentReuseSummary(environmentID: "env-migrated")
        XCTAssertTrue(summary.contains("base image"))
        XCTAssertFalse(summary.contains("template"))

        // Content is untouched and the delta reproduces the guest's bytes.
        let working = root.appendingPathComponent("reworks/disk.img")
        _ = try await store.deltas.materializeWorkingDisk(
            environmentID: "env-migrated", baseRootfs: baseRootfs,
            expectedBaseRootfsSHA512: ref.sha512, expectedTemplate: nil, into: working
        )
        let check = try FileHandle(forReadingFrom: working)
        try check.seek(toOffset: 1 << 20)
        XCTAssertEqual(try check.read(upToCount: 4096), Data(repeating: 0x7E, count: 4096))
        try check.close()
        // A second run is idempotent and still records the actual base.
        let second = try await migrator.migrateLegacyEnvironment(
            environmentID: "env-migrated", kind: "linuxVM", ownerID: nil, name: nil,
            baseImageID: baseImageID, legacyDiskDirectory: nil, legacyLayerDirectory: nil
        )
        XCTAssertEqual(second.phase, .cleanupPending)
        let floeAsyncValue15 = try await store.registry.environment(id: "env-migrated")?.baseRootfsDigest
        XCTAssertEqual(floeAsyncValue15, ref.sha512.lowercased())
    }

    // MARK: - official templates

    private func makeOfficialArtifactDisk(
        seed: UInt8, recipe: RuntimeV2TemplateRecipe
    ) async throws -> (diskURL: URL, recipeURL: URL) {
        let disk = root.appendingPathComponent("official-\(UUID().uuidString).img")
        var bytes = Data(count: 3 << 20)
        for index in bytes.indices { bytes[index] = UInt8((index &* Int(seed)) % 251) }
        try bytes.write(to: disk)
        let recipes = root.appendingPathComponent("templates", isDirectory: true)
        try FileManager.default.createDirectory(at: recipes, withIntermediateDirectories: true)
        let recipeURL = RuntimeV2TemplateCatalog.recipeURL(
            templateID: recipe.name, templatesDirectory: recipes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(recipe).write(to: recipeURL)
        return (disk, recipeURL)
    }

    func testOfficialTemplatesReportDependencyMissingUntilActualImage() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        var statuses = try await store.templates.officialTemplateStatus()
        XCTAssertEqual(statuses.map(\.templateID), ["basic", "dev-document"])
        for status in statuses {
            XCTAssertEqual(status.state, .dependencyMissing)
            XCTAssertNil(status.version)
            XCTAssertNil(status.digest)
            XCTAssertTrue(status.reason?.contains("job-6f5ac974858c47c2") == true)
            XCTAssertTrue(status.reason?.contains("templates/") == true)
        }
        // Missing recipe files are an explicit dependency failure naming the
        // owner; no placeholder is invented.
        let emptyTemplates = root.appendingPathComponent("no-templates", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyTemplates, withIntermediateDirectories: true)
        do {
            _ = try RuntimeV2TemplateStore.loadRecipe(templateID: "basic", templatesDirectory: emptyTemplates)
            XCTFail("a missing recipe must not be treated as a placeholder")
        } catch RuntimeV2Error.templateRecipeInvalid(let reason) {
            XCTAssertTrue(reason.contains("missing"))
            XCTAssertTrue(reason.contains("job-6f5ac974858c47c2"))
        }

        // The actual image arrives: a real disk plus the recipe and package
        // listing. Only then does the catalog report verified.
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let parent = baseParent(ref, imageID: baseImageID)
        let basicRecipe = recipe(packages: ["python3": .init(minVersion: "3.11"), "nodejs": .init()])
        let artifact = try await makeOfficialArtifactDisk(seed: 0x5A, recipe: basicRecipe)
        let loadedRecipe = try RuntimeV2TemplateStore.loadRecipe(
            templateID: "basic", templatesDirectory: artifact.recipeURL.deletingLastPathComponent()
        )
        XCTAssertEqual(loadedRecipe.name, "basic")
        let registration = try await store.templates.registerOfficialTemplate(
            RuntimeV2TemplateStore.OfficialTemplateArtifact(
                templateID: "basic", version: 1, recipe: loadedRecipe, parent: parent,
                architecture: "riscv64", diskURL: artifact.diskURL,
                packages: [package("python3", "3.11.9"), package("nodejs", "20.11.0")],
                downloadBytes: 999, missingPackages: [], installVerified: true,
                provenance: "cloud-template-qualification-run-1"
            )
        )
        XCTAssertEqual(registration.buildMode, .imported)
        XCTAssertEqual(registration.downloadBytes, 999)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: artifact.diskURL), registration.diskDigest)

        statuses = try await store.templates.officialTemplateStatus()
        let basic = try XCTUnwrap(statuses.first { $0.templateID == "basic" })
        XCTAssertEqual(basic.state, .verified)
        XCTAssertEqual(basic.version, 1)
        XCTAssertEqual(basic.digest, registration.pin.digest)
        let documentTemplate = try XCTUnwrap(statuses.first { $0.templateID == "dev-document" })
        XCTAssertEqual(documentTemplate.state, .dependencyMissing)

        // Re-registering identical content is idempotent; a different artifact
        // under the same version is refused.
        let again = try await store.templates.registerOfficialTemplate(
            RuntimeV2TemplateStore.OfficialTemplateArtifact(
                templateID: "basic", version: 1, recipe: loadedRecipe, parent: parent,
                architecture: "riscv64", diskURL: artifact.diskURL,
                packages: [package("python3", "3.11.9"), package("nodejs", "20.11.0")],
                downloadBytes: 999, missingPackages: [], installVerified: true,
                provenance: "cloud-template-qualification-run-1"
            )
        )
        XCTAssertEqual(again.pin, registration.pin)
        var tampered = Data(count: 4096)
        for index in tampered.indices { tampered[index] = UInt8(index % 251) }
        let tamperedDisk = root.appendingPathComponent("tampered.img")
        try tampered.write(to: tamperedDisk)
        do {
            _ = try await store.templates.registerOfficialTemplate(
                RuntimeV2TemplateStore.OfficialTemplateArtifact(
                    templateID: "basic", version: 1, recipe: loadedRecipe, parent: parent,
                    architecture: "riscv64", diskURL: tamperedDisk,
                    packages: [package("python3", "3.11.9"), package("nodejs", "20.11.0")],
                    downloadBytes: 1, missingPackages: [], installVerified: true,
                    provenance: "unqualified"
                )
            )
            XCTFail("a different artifact under the same version must be refused")
        } catch RuntimeV2Error.templateVersionImmutable {
            // expected
        }
        // Non-official ids are refused outright.
        do {
            _ = try await store.templates.registerOfficialTemplate(
                RuntimeV2TemplateStore.OfficialTemplateArtifact(
                    templateID: "custom", version: 1, recipe: loadedRecipe, parent: parent,
                    architecture: "riscv64", diskURL: artifact.diskURL,
                    packages: [package("python3", "3.11.9")], downloadBytes: 1,
                    missingPackages: [], installVerified: true, provenance: "x"
                )
            )
            XCTFail("only official template ids can be registered")
        } catch RuntimeV2Error.templateNotOfficial {
            // expected
        }
        // A recipe gap in an artifact is refused, not registered.
        let gap = try await makeOfficialArtifactDisk(seed: 0x6B, recipe: basicRecipe)
        do {
            _ = try await store.templates.registerOfficialTemplate(
                RuntimeV2TemplateStore.OfficialTemplateArtifact(
                    templateID: "dev-document", version: 1, recipe: basicRecipe, parent: parent,
                    architecture: "riscv64", diskURL: gap.diskURL,
                    packages: [package("python3", "3.11.9")], downloadBytes: 1,
                    missingPackages: [], installVerified: true, provenance: "ci"
                )
            )
            XCTFail("an incomplete artifact must not be registered")
        } catch RuntimeV2Error.templateRequirementMissing(_, _, let missing) {
            XCTAssertEqual(missing, ["nodejs"])
        }
    }

    // MARK: - clean rebuild

    func testCleanRebuildReplansFromOriginalParentAndExcludesPrivateState() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let parent = baseParent(ref, imageID: baseImageID)
        let template = try await store.templates.build(
            using: ScriptedInstaller(packages: [package("python3", "3.11.2")], downloadBytes: 1),
            request: buildRequest(recipe: recipe(packages: ["python3": .init()]), parent: parent)
        )
        let plan = try await store.templates.cleanRebuildPlan(
            templateID: "basic", version: 1, newVersion: 2
        )
        XCTAssertEqual(plan.parent.kind, .baseImage)
        XCTAssertEqual(plan.parent.id, baseImageID)
        XCTAssertEqual(plan.parent.digest, ref.sha512.lowercased())
        XCTAssertEqual(plan.recipe.packages.keys.sorted(), ["python3"])
        XCTAssertTrue(plan.excludedPrivateState.contains("home"))
        XCTAssertTrue(plan.excludedPrivateState.contains("workspaces"))
        XCTAssertTrue(plan.excludedPrivateState.contains("credentials"))
        XCTAssertTrue(plan.excludedPrivateState.contains("shell-history"))

        let rebuilt = try await store.templates.rebuild(
            using: ScriptedInstaller(packages: [package("python3", "3.12.0")], downloadBytes: 4),
            templateID: "basic", version: 1, newVersion: 2,
            architecture: "riscv64", targetCapacityBytes: 4 << 20
        )
        XCTAssertEqual(rebuilt.pin.version, 2)
        XCTAssertNotEqual(rebuilt.pin.digest, template.pin.digest)
        // v1 is untouched: a rebuild is a new version, never an overwrite.
        let floeAsyncValue16 = try await store.templates.version(templateID: "basic", version: 1)?.digest
        XCTAssertEqual(floeAsyncValue16, template.pin.digest)
    }

    // MARK: - image capability evidence and shape admission

    func testImageSMPCapabilityIsProvenByManifestNotEngine() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        _ = try await makeVerifiedBaseImage(imageID: baseImageID)
        _ = try await makeVerifiedBaseImage(imageID: "smp-image", rootfsSeed: 31, smpCapable: true)

        // No declaration: false with an honest reason (never inferred from the
        // engine's floe_vm_smp_capable()).
        let absent = try await store.images.smpCapability(imageID: baseImageID)
        XCTAssertFalse(absent.capable)
        XCTAssertTrue(absent.reason.contains("does not declare SMP"))

        let declared = try await store.images.smpCapability(imageID: "smp-image")
        XCTAssertTrue(declared.capable)
        XCTAssertTrue(declared.reason.contains("smp_capable"))

        // An unverified image never answers capable.
        let missing = try await store.images.smpCapability(imageID: "not-installed")
        XCTAssertFalse(missing.capable)

        // A template inherits its root base image's capability: a template on
        // the SMP image is proven, one on the plain image is not.
        let plainManifest = try await makeVerifiedBaseImage(imageID: "base-image-3", rootfsSeed: 41)
        let plainRef = try await rootfsRef(plainManifest)
        _ = try await store.templates.build(
            using: ScriptedInstaller(packages: [package("python3", "3.11.2")], downloadBytes: 1),
            request: buildRequest(
                templateID: "dev-document", version: 1,
                recipe: recipe(name: "dev-document", packages: ["python3": .init()]),
                parent: baseParent(plainRef, imageID: "base-image-3")
            )
        )
        let templateBaseImage = try await store.templates.baseImageID(templateID: "dev-document", version: 1)
        XCTAssertEqual(templateBaseImage, "base-image-3")
    }

    func testShapeAdmissionGrantsProvenSMPAndRefusesUnprovenClaim() async throws {
        let poolConfiguration = RuntimeVMPool.Configuration(
            quota: GuestResourceQuota(totalVCPUs: 4, totalMemoryMiB: 4096, maxVMs: 4),
            queueLimit: 4, queueTimeout: 2, hostOverheadMiB: 0, futureReserveMiB: 0
        )
        store = RuntimeV2Store(layout: layout, poolConfiguration: poolConfiguration)
        _ = try await store.prepareAndRecover(build: "test")
        _ = try await makeVerifiedBaseImage(imageID: baseImageID)
        _ = try await makeVerifiedBaseImage(imageID: "smp-image", rootfsSeed: 31, smpCapable: true)
        let now = Date()
        for (id, image) in [("env-nosmp", baseImageID), ("env-smp", "smp-image")] {
            try await store.registry.upsertEnvironment(
                RuntimeV2Registry.EnvironmentRow(
                    id: id, kind: "linuxVM", ownerID: nil, name: id,
                    baseImageID: image, baseRootfsDigest: nil,
                    state: "stopped", dataPath: nil, compatHostFHS: false,
                    repairReason: nil, createdAt: now, lastUsedAt: now
                )
            )
        }
        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: nil, build: "test")
        let floeAsyncValue17 = await integrator.imageSMPCapable(imageID: baseImageID)
        XCTAssertFalse(floeAsyncValue17)
        let floeAsyncValue18 = await integrator.imageSMPCapable(imageID: "smp-image")
        XCTAssertTrue(floeAsyncValue18)

        let dual = GuestResourceRequest(vcpus: .two, memory: .m512, origin: .environmentPolicy)

        // A caller claim is not evidence: an image that does not prove SMP is
        // never granted two harts under the strict policy.
        do {
            _ = try await integrator.acquireShape(
                environmentID: "env-nosmp", runtimeID: "rt-nosmp",
                request: dual, imageSMPCapable: true, downgrade: .strict
            )
            XCTFail("an unproven SMP claim must not be granted")
        } catch LinuxGuestError.smpUnsupportedByImage(let environmentID) {
            XCTAssertEqual(environmentID, "env-nosmp")
        }

        // A manifest-proven image is granted exactly two harts and the real
        // requested RAM.
        let granted = try await integrator.acquireShape(
            environmentID: "env-smp", runtimeID: "rt-smp",
            request: dual, imageSMPCapable: true, downgrade: .strict
        )
        XCTAssertEqual(granted.vcpus, 2)
        XCTAssertEqual(granted.ramMB, 512)
        XCTAssertFalse(granted.downgraded)
        XCTAssertFalse(granted.vcpusDowngraded)

        // A single-hart lease exists for the non-SMP environment so the shape
        // planner validates against the pool, not against a missing session.
        let single = GuestResourceRequest(vcpus: .one, memory: .m512, origin: .environmentPolicy)
        _ = try await integrator.acquireShape(
            environmentID: "env-nosmp", runtimeID: "rt-nosmp",
            request: single, imageSMPCapable: false, downgrade: .strict
        )
        // Planning a second hart on the unproven image is refused BEFORE any
        // stop/restart runs.
        do {
            try await integrator.planReshape(
                environmentID: "env-nosmp", ramMB: 1024, vcpus: 2, currentVCPUs: 1
            )
            XCTFail("a vCPU change on an unproven image must be refused at plan time")
        } catch LinuxGuestError.invalidConfiguration {
            // expected
        }
        // The proven image may plan the same change.
        try await integrator.planReshape(
            environmentID: "env-smp", ramMB: 1024, vcpus: 2, currentVCPUs: 2
        )
        // Confirming records the shape the restart made true (the lease holds
        // the granted shape, not a tier approximation).
        await integrator.confirmReshape(environmentID: "env-smp", ramMB: 1536, vcpus: 2)
        let confirmedLease = await store.pool.lease(runtimeID: "rt-smp")
        XCTAssertEqual(confirmedLease?.shape.memory.mb, 1536)
        XCTAssertEqual(confirmedLease?.shape.vcpus.count, 2)
        let floeAsyncValue19 = await store.pool.status.usedVCPUs
        XCTAssertEqual(floeAsyncValue19, 3)
    }

    // MARK: - pure contract units

    func testRecipeValidationAndVersionOrder() throws {
        do {
            _ = try RuntimeV2TemplateRecipe(name: "empty", packages: [:]).validate()
            XCTFail("an empty requirement set is not a recipe")
        } catch RuntimeV2Error.templateRecipeInvalid {
            // expected
        }
        let decoded = try JSONDecoder().decode(
            RuntimeV2TemplateRecipe.self,
            from: Data(#"{"schema":1,"name":"basic","description":"x","packages":{"python3":{"min_version":"3.11"},"nodejs":null}}"#.utf8)
        )
        XCTAssertNil(decoded.packages["nodejs"]?.minVersion)
        XCTAssertEqual(decoded.packages["python3"]?.minVersion, "3.11")
        // Round-trip: a null requirement stays an explicit "any version" entry
        // (dropping it would silently weaken the recipe).
        let encoded = try JSONEncoder().encode(decoded)
        let roundTrip = try JSONDecoder().decode(RuntimeV2TemplateRecipe.self, from: encoded)
        XCTAssertEqual(roundTrip, decoded)
        XCTAssertEqual(roundTrip.packages.count, 2)
        XCTAssertNotNil(roundTrip.packages["nodejs"])

        XCTAssertTrue(RuntimeV2VersionOrder.satisfies("3.11.2", atLeast: "3.11"))
        XCTAssertTrue(RuntimeV2VersionOrder.satisfies("3.11", atLeast: "3.11"))
        XCTAssertFalse(RuntimeV2VersionOrder.satisfies("3.9", atLeast: "3.11"))
        XCTAssertTrue(RuntimeV2VersionOrder.satisfies("20.11.0", atLeast: "18"))
        XCTAssertTrue(RuntimeV2VersionOrder.satisfies("1:2.0", atLeast: "2.0"))
        XCTAssertFalse(RuntimeV2VersionOrder.satisfies("2.0", atLeast: "1:2.0"))

        let evaluation = RuntimeV2TemplateStore.evaluate(
            recipe: RuntimeV2TemplateRecipe(
                name: "basic",
                packages: ["python3": .init(minVersion: "3.11"), "nodejs": .init(), "git": .init()]
            ),
            outcome: RuntimeV2TemplateStore.InstallOutcome(
                packages: [
                    RuntimeV2TemplateStore.InstalledSoftware(name: "python3", version: "3.9.2", installState: "installed"),
                    RuntimeV2TemplateStore.InstalledSoftware(name: "nodejs", version: "20.11.0", installState: "installed")
                ],
                downloadBytes: 0, missingPackages: ["git"], notes: [], verified: true
            )
        )
        XCTAssertEqual(evaluation.unsatisfied, ["python3 (3.9.2 < 3.11)"]) // below min_version
        XCTAssertEqual(evaluation.missing, ["git"]) // reported missing, never fabricated
        XCTAssertFalse(evaluation.missing.contains("nodejs"))
    }

    func testContentDigestIsDeterministicAndPackageSensitive() {
        let parent = RuntimeV2TemplateStore.ParentSource(
            kind: .baseImage, id: "base", version: nil, digest: String(repeating: "a", count: 128)
        )
        let recipe = RuntimeV2TemplateRecipe(name: "basic", packages: ["python3": .init(minVersion: "3.9")])
        let packages = [
            RuntimeV2TemplateStore.InstalledSoftware(name: "python3", version: "3.11.2", source: "apt")
        ]
        let first = RuntimeV2TemplateStore.contentDigest(
            parent: parent, architecture: "riscv64", recipe: recipe, packages: packages
        )
        let second = RuntimeV2TemplateStore.contentDigest(
            parent: parent, architecture: "riscv64", recipe: recipe, packages: packages
        )
        XCTAssertEqual(first, second)
        let changed = RuntimeV2TemplateStore.contentDigest(
            parent: parent, architecture: "riscv64", recipe: recipe,
            packages: [RuntimeV2TemplateStore.InstalledSoftware(name: "python3", version: "3.11.3", source: "apt")]
        )
        XCTAssertNotEqual(first, changed)
    }

    // MARK: - boot provenance: durable freeze, stop/salvage against it

    private func registerEnvironment(
        _ id: String, baseImageID: String, rootfsDigest: String?, state: String = "stopped"
    ) async throws {
        let now = Date()
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: id, kind: "linuxVM", ownerID: nil, name: id,
                baseImageID: baseImageID, baseRootfsDigest: rootfsDigest,
                state: state, dataPath: "environments/\(id)/data", compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
    }

    @discardableResult
    private func buildTemplate(
        templateID: String = "basic", version: Int = 1, marker: UInt8,
        packages: [RuntimeV2TemplateStore.InstalledSoftware],
        parent: RuntimeV2TemplateStore.ParentSource
    ) async throws -> RuntimeV2TemplateStore.Registration {
        try await store.templates.build(
            using: ScriptedInstaller(
                markerBytes: Data(repeating: marker, count: 4096),
                packages: packages, downloadBytes: 1
            ),
            request: buildRequest(
                templateID: templateID, version: version,
                recipe: recipe(
                    name: templateID,
                    packages: Dictionary(uniqueKeysWithValues: packages.map { ($0.name, .init()) })
                ),
                parent: parent
            )
        )
    }

    private func writeBytes(_ url: URL, at offset: Int64, _ data: Data) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func readBytes(_ url: URL, at offset: Int64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }

    private func quarantinedEntries(prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix(prefix) }
    }

    private func bootPinnedEnvironment(
        environmentID: String, runtimeID: String, markerOffset: Int64, marker: Data
    ) async throws -> RuntimeV2WorkingDisk {
        let integrator = RuntimeV2GuestIntegrator(store: store, build: "test")
        let admission = try await integrator.acquireSlot(
            environmentID: environmentID, runtimeID: runtimeID, requestedMB: 512
        )
        XCTAssertGreaterThan(admission.ramMB, 0)
        let work = try await integrator.prepareWorkingDisk(
            environmentID: environmentID, runtimeID: runtimeID, imageID: baseImageID,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        try writeBytes(work.diskURL, at: markerOffset, marker)
        return work
    }

    /// The boot base (template id/version/digest + the exact disk digest) is
    /// frozen in the working directory's durable metadata BEFORE any bytes are
    /// cloned, and a confirmed stop captures against that provenance.
    func testPinnedBootFreezesProvenanceAndStopCapturesAgainstIt() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let template = try await buildTemplate(
            marker: 0x51, packages: [package("python3", "3.11.2")],
            parent: baseParent(ref, imageID: baseImageID)
        )
        try await registerEnvironment(
            "env-boot", baseImageID: baseImageID, rootfsDigest: ref.sha512.lowercased()
        )
        let pin = try await store.templates.pinEnvironment(
            environmentID: "env-boot", templateID: "basic", version: 1
        )
        XCTAssertEqual(pin.digest, template.pin.digest)

        _ = try await bootPinnedEnvironment(
            environmentID: "env-boot", runtimeID: "rt-boot",
            markerOffset: 3 << 20, marker: Data(repeating: 0x5A, count: 4096)
        )
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-boot")
        let meta = RuntimeV2WorkingDirectory.readMeta(from: directory)
        XCTAssertEqual(meta?.templateID, "basic")
        XCTAssertEqual(meta?.templateVersion, 1)
        XCTAssertEqual(meta?.templateDigest, template.pin.digest)
        XCTAssertEqual(meta?.bootBaseDiskDigest, template.diskDigest)
        XCTAssertEqual(meta?.baseImageID, baseImageID)

        let integrator = RuntimeV2GuestIntegrator(store: store, build: "test")
        let outcome = await integrator.completeStopResult(
            environmentID: "env-boot", runtimeID: "rt-boot", imageID: baseImageID, clean: true
        )
        guard case .captured(let generation) = outcome else {
            XCTFail("a clean stop with intact provenance must capture, got \(outcome)")
            return
        }
        XCTAssertGreaterThan(generation, 0)
        let delta = try await store.deltas.loadDelta(environmentID: "env-boot")
        XCTAssertEqual(delta?.header.templateID, "basic")
        XCTAssertEqual(delta?.header.templateVersion, 1)
        XCTAssertEqual(delta?.header.templateDigest, template.pin.digest)
        XCTAssertEqual(delta?.header.baseRootfsSHA512, template.diskDigest)
        XCTAssertGreaterThan(delta?.presentBlocks ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let lease = try await store.leases.holder(environmentID: "env-boot")
        XCTAssertNil(lease)
    }

    /// The corruption window the review found: the pin row moves while the guest
    /// runs (an out-of-band writer). The stop must NOT capture the v1 disk
    /// against v2's base — it preserves the complete disk and marks the
    /// environment repairRequired.
    func testStopRefusesCaptureWhenThePinMovedAfterBootAndPreservesDisk() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let parent = baseParent(ref, imageID: baseImageID)
        let v1 = try await buildTemplate(marker: 0x61, packages: [package("python3", "3.11.2")], parent: parent)
        let v2 = try await buildTemplate(version: 2, marker: 0x62, packages: [package("python3", "3.12.0")], parent: parent)
        XCTAssertNotEqual(v1.pin.digest, v2.pin.digest)
        try await registerEnvironment(
            "env-moved", baseImageID: baseImageID, rootfsDigest: ref.sha512.lowercased()
        )
        _ = try await store.templates.pinEnvironment(
            environmentID: "env-moved", templateID: "basic", version: 1
        )
        _ = try await bootPinnedEnvironment(
            environmentID: "env-moved", runtimeID: "rt-moved",
            markerOffset: 3 << 20, marker: Data(repeating: 0x6A, count: 4096)
        )
        // The pin row moves under the live disk (bypassing the lease-guarded pin
        // operation on purpose, exactly like the reported corruption window).
        let pinned = try await store.registry.environment(id: "env-moved")
        var moved = try XCTUnwrap(pinned)
        moved.templateVersion = 2
        moved.templateDigest = v2.pin.digest
        try await store.registry.upsertEnvironment(moved)

        let integrator = RuntimeV2GuestIntegrator(store: store, build: "test")
        let outcome = await integrator.completeStopResult(
            environmentID: "env-moved", runtimeID: "rt-moved", imageID: baseImageID, clean: true
        )
        guard case .retainedForRepair(let reason) = outcome else {
            XCTFail("a moved pin must refuse the capture and retain the disk, got \(outcome)")
            return
        }
        XCTAssertTrue(reason.contains("preserved"))
        // No delta was written across the two identities.
        let delta = try await store.deltas.loadDelta(environmentID: "env-moved")
        XCTAssertNil(delta)
        // The complete disk (including the private block) is preserved.
        let quarantined = try quarantinedEntries(prefix: "runtime-vm-rt-moved")
        XCTAssertEqual(quarantined.count, 1)
        let preservedDisk = layout.quarantineDirectory
            .appendingPathComponent(quarantined[0], isDirectory: true)
            .appendingPathComponent("disk.img")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedDisk.path))
        let privateBlock = try readBytes(preservedDisk, at: 3 << 20, count: 4096)
        XCTAssertEqual(privateBlock, Data(repeating: 0x6A, count: 4096))
        let runtimeDir = try layout.runtimeVMDirectory(runtimeID: "rt-moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeDir.path))
        // Durable error state, then the lease is released.
        let state = try await store.registry.environment(id: "env-moved")?.state
        XCTAssertEqual(state, "repairRequired")
        let shutdown = try await store.deltas.lastShutdown(environmentID: "env-moved")
        XCTAssertEqual(shutdown?.clean, false)
        XCTAssertTrue(shutdown?.detail?.contains("preserved") == true)
        let lease = try await store.leases.holder(environmentID: "env-moved")
        XCTAssertNil(lease)
    }

    /// A capture that fails for any other reason (here: the boot base blob is
    /// damaged) must never delete the stopped working disk. It is quarantined,
    /// the failure is durable, and the environment is repairRequired.
    func testStopCaptureFailurePreservesDiskAndRecordsRepairState() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let template = try await buildTemplate(
            marker: 0x71, packages: [package("python3", "3.11.2")],
            parent: baseParent(ref, imageID: baseImageID)
        )
        try await registerEnvironment(
            "env-fail", baseImageID: baseImageID, rootfsDigest: ref.sha512.lowercased()
        )
        _ = try await store.templates.pinEnvironment(
            environmentID: "env-fail", templateID: "basic", version: 1
        )
        _ = try await bootPinnedEnvironment(
            environmentID: "env-fail", runtimeID: "rt-fail",
            markerOffset: 2 << 20, marker: Data(repeating: 0x7B, count: 4096)
        )
        // The immutable boot base disappears (external damage / IO failure).
        let blobURL = try await store.blobs.verifiedBlobURL(digest: template.diskDigest)
        try FileManager.default.removeItem(at: blobURL)

        let integrator = RuntimeV2GuestIntegrator(store: store, build: "test")
        let outcome = await integrator.completeStopResult(
            environmentID: "env-fail", runtimeID: "rt-fail", imageID: baseImageID, clean: true
        )
        guard case .retainedForRepair = outcome else {
            XCTFail("a failed capture must retain the disk, got \(outcome)")
            return
        }
        let quarantined = try quarantinedEntries(prefix: "runtime-vm-rt-fail")
        XCTAssertEqual(quarantined.count, 1)
        let preservedDisk = layout.quarantineDirectory
            .appendingPathComponent(quarantined[0], isDirectory: true)
            .appendingPathComponent("disk.img")
        let privateBlock = try readBytes(preservedDisk, at: 2 << 20, count: 4096)
        XCTAssertEqual(privateBlock, Data(repeating: 0x7B, count: 4096))
        let failedDelta = try await store.deltas.loadDelta(environmentID: "env-fail")
        XCTAssertNil(failedDelta)
        let state = try await store.registry.environment(id: "env-fail")?.state
        XCTAssertEqual(state, "repairRequired")
        let lease = try await store.leases.holder(environmentID: "env-fail")
        XCTAssertNil(lease)
        let runtimeDir = try layout.runtimeVMDirectory(runtimeID: "rt-fail")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeDir.path))
    }

    /// Crash recovery salvages a leftover working disk against the provenance
    /// frozen at boot — and when that provenance no longer matches the live
    /// registry, the disk is quarantined and the environment repairRequired
    /// instead of being captured against different bytes.
    func testSalvageUsesRecordedProvenanceAndQuarantinesOnMismatch() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let parent = baseParent(ref, imageID: baseImageID)
        let v1 = try await buildTemplate(marker: 0x81, packages: [package("python3", "3.11.2")], parent: parent)
        let v2 = try await buildTemplate(version: 2, marker: 0x82, packages: [package("python3", "3.12.0")], parent: parent)

        // Catch A: pin still v1 — salvage through the recorded provenance.
        try await registerEnvironment("env-salvage", baseImageID: baseImageID, rootfsDigest: ref.sha512.lowercased())
        _ = try await store.templates.pinEnvironment(environmentID: "env-salvage", templateID: "basic", version: 1)
        let directoryA = try layout.runtimeVMDirectory(runtimeID: "rt-salvage")
        try FileManager.default.createDirectory(at: directoryA, withIntermediateDirectories: true)
        let diskA = directoryA.appendingPathComponent("disk.img")
        _ = try await store.blobs.materialize(digest: v1.diskDigest, at: diskA, writable: true)
        try writeBytes(diskA, at: 2 << 20, Data(repeating: 0x8A, count: 4096))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-salvage", environmentID: "env-salvage",
                baseImageID: baseImageID, createdAt: Date(),
                templateID: "basic", templateVersion: 1,
                templateDigest: v1.pin.digest, bootBaseDiskDigest: v1.diskDigest
            ),
            to: directoryA
        )

        // Catch B: the pin moved to v2 before recovery — the recorded v1 disk
        // must not be captured as if it were v2.
        try await registerEnvironment("env-salvage-moved", baseImageID: baseImageID, rootfsDigest: ref.sha512.lowercased())
        let pinnedB = try await store.templates.pinEnvironment(
            environmentID: "env-salvage-moved", templateID: "basic", version: 1
        )
        XCTAssertEqual(pinnedB.version, 1)
        let rowBValue = try await store.registry.environment(id: "env-salvage-moved")
        let rowB = try XCTUnwrap(rowBValue)
        var movedB = rowB
        movedB.templateVersion = 2
        movedB.templateDigest = v2.pin.digest
        try await store.registry.upsertEnvironment(movedB)
        let directoryB = try layout.runtimeVMDirectory(runtimeID: "rt-salvage-moved")
        try FileManager.default.createDirectory(at: directoryB, withIntermediateDirectories: true)
        let diskB = directoryB.appendingPathComponent("disk.img")
        _ = try await store.blobs.materialize(digest: v1.diskDigest, at: diskB, writable: true)
        try writeBytes(diskB, at: 3 << 20, Data(repeating: 0x8B, count: 4096))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-salvage-moved", environmentID: "env-salvage-moved",
                baseImageID: baseImageID, createdAt: Date(),
                templateID: "basic", templateVersion: 1,
                templateDigest: v1.pin.digest, bootBaseDiskDigest: v1.diskDigest
            ),
            to: directoryB
        )

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.salvagedRuntimeDirs.contains("rt-salvage"))
        XCTAssertTrue(report.quarantinedRuntimeDirs.contains("rt-salvage-moved"))

        // A: captured exactly against the v1 template disk.
        let deltaA = try await relaunched.deltas.loadDelta(environmentID: "env-salvage")
        XCTAssertEqual(deltaA?.header.templateID, "basic")
        XCTAssertEqual(deltaA?.header.templateVersion, 1)
        XCTAssertEqual(deltaA?.header.baseRootfsSHA512, v1.diskDigest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryA.path))

        // B: no delta, disk preserved, environment repairRequired.
        let deltaB = try await relaunched.deltas.loadDelta(environmentID: "env-salvage-moved")
        XCTAssertNil(deltaB)
        let stateB = try await relaunched.registry.environment(id: "env-salvage-moved")?.state
        XCTAssertEqual(stateB, "repairRequired")
        let quarantinedB = try FileManager.default
            .contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("runtime-vm-rt-salvage-moved") }
        XCTAssertEqual(quarantinedB.count, 1)
        let preservedB = layout.quarantineDirectory
            .appendingPathComponent(quarantinedB[0], isDirectory: true)
            .appendingPathComponent("disk.img")
        let privateBlockB = try readBytes(preservedB, at: 3 << 20, count: 4096)
        XCTAssertEqual(privateBlockB, Data(repeating: 0x8B, count: 4096))
    }

    // MARK: - pin lifecycle: no silent re-point, atomic reference replacement

    func testRepinRefusesWhileRunningAndReplacesTheOldReferenceAtomically() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let parent = baseParent(ref, imageID: baseImageID)
        let v1 = try await buildTemplate(marker: 0x91, packages: [package("python3", "3.11.2")], parent: parent)
        let v2 = try await buildTemplate(version: 2, marker: 0x92, packages: [package("python3", "3.12.0")], parent: parent)
        try await registerEnvironment("env-repin", baseImageID: baseImageID, rootfsDigest: ref.sha512.lowercased())
        _ = try await store.templates.pinEnvironment(environmentID: "env-repin", templateID: "basic", version: 1)
        let initiallyPinned = try await store.registry.environment(id: "env-repin")?.templateVersion
        XCTAssertEqual(initiallyPinned, 1)

        let lease = try await store.leases.acquire(environmentID: "env-repin", runtimeID: "rt-repin")
        do {
            _ = try await store.templates.pinEnvironment(
                environmentID: "env-repin", templateID: "basic", version: 2
            )
            XCTFail("a repin under a live lease must be refused")
        } catch RuntimeV2Error.templateEnvironmentRunning {
            // expected
        }
        do {
            try await store.templates.unpinEnvironment(environmentID: "env-repin")
            XCTFail("an unpin under a live lease must be refused")
        } catch RuntimeV2Error.templateEnvironmentRunning {
            // expected
        }
        let stillV1 = try await store.registry.environment(id: "env-repin")?.templateVersion
        XCTAssertEqual(stillV1, 1)
        await lease.release()

        let repinned = try await store.templates.pinEnvironment(
            environmentID: "env-repin", templateID: "basic", version: 2
        )
        XCTAssertEqual(repinned.version, 2)
        // Exactly one environment reference exists, on the new version: the old
        // row can never keep the abandoned version alive.
        let v1Refs = try await store.templates.references(templateID: "basic", version: 1)
        XCTAssertFalse(v1Refs.contains { $0.refKind == "environment" && $0.refID == "env-repin" })
        let v2Refs = try await store.templates.references(templateID: "basic", version: 2)
        XCTAssertEqual(v2Refs.filter { $0.refKind == "environment" && $0.refID == "env-repin" }.count, 1)

        // The abandoned v1 is now collectable; v2 stays protected by the pin
        // (and the environment reference row the atomic pin transaction wrote).
        _ = try await store.templates.finalizeBuilds()
        let report = try await store.templates.collectGarbage(grace: 0)
        XCTAssertTrue(report.collected.contains("basic@1"))
        XCTAssertFalse(report.collected.contains("basic@2"))
        let v2State = try await store.templates.version(templateID: "basic", version: 2)?.state
        XCTAssertEqual(v2State, .verified)
        let v1BlobRefs = try await store.registry.blob(digest: v1.diskDigest)?.refs
        XCTAssertEqual(v1BlobRefs, 0)
        let v2BlobRefs = try await store.registry.blob(digest: v2.diskDigest)?.refs
        XCTAssertEqual(v2BlobRefs, 1)
    }

    // MARK: - GC: atomic revalidation inside the collection transaction

    /// The deterministic TOCTOU race: a pin lands after the GC candidate
    /// listing and before the collection. The atomic collection transaction
    /// must see it and skip; the version stays verified and its blob reference
    /// untouched.
    func testGCRaceWithPinInsertedAfterListingIsSkippedAtomically() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let template = try await buildTemplate(
            marker: 0xA1, packages: [package("python3", "3.11.2")],
            parent: baseParent(ref, imageID: baseImageID)
        )
        _ = try await store.templates.finalizeBuilds()
        let registry = await store.registry
        var seams = RuntimeV2TemplateStore.Seams.production
        seams.beforeCollectVersion = { templateID, version in
            // Runs in the window between the listing and the collection.
            let now = Date()
            try? await registry.upsertEnvironment(
                RuntimeV2Registry.EnvironmentRow(
                    id: "env-gc-race", kind: "linuxVM", ownerID: nil, name: "race",
                    baseImageID: "base-image", baseRootfsDigest: nil,
                    state: "stopped", dataPath: nil, compatHostFHS: false,
                    repairReason: nil, createdAt: now, lastUsedAt: now
                )
            )
            if let row = try? await registry.template(templateID: templateID, version: version) {
                _ = try? await registry.pinEnvironmentTemplate(
                    environmentID: "env-gc-race", templateID: templateID,
                    version: version, digest: row.digest
                )
            }
        }
        let raced = RuntimeV2Store(layout: layout, templateSeams: seams)
        _ = try await raced.prepareAndRecover(build: "test")

        let report = try await raced.templates.collectGarbage(grace: 0)
        XCTAssertFalse(report.collected.contains("basic@1"))
        // The pin inserted in the window added its environment reference, which
        // the collection transaction revalidated inside the same commit.
        XCTAssertTrue(
            report.notes.contains { $0.contains("1 template reference(s)") },
            "expected the late reference to be reported, got \(report.notes)"
        )
        let state = try await raced.templates.version(templateID: "basic", version: 1)?.state
        XCTAssertEqual(state, .verified)
        let racedBlob = try await raced.registry.blob(digest: template.diskDigest)
        XCTAssertEqual(racedBlob?.refs, 1)
    }

    /// The registry transaction itself is authoritative: a reference, a pin or
    /// a held lease inserted after any outside pre-check still refuses the
    /// collection, and the successful path releases the blob reference in the
    /// same commit.
    func testAtomicCollectionRevalidatesEveryProtection() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let template = try await buildTemplate(
            marker: 0xB1, packages: [package("python3", "3.11.2")],
            parent: baseParent(ref, imageID: baseImageID)
        )
        _ = try await store.templates.finalizeBuilds()
        try await store.registry.addTemplateReference(
            templateID: "basic", version: 1, kind: "build", refID: "late-build"
        )
        var outcome = try await store.registry.collectTemplateVersionIfUnreferenced(
            templateID: "basic", version: 1, grace: 0, now: Date()
        )
        guard case .skipped(let referenceReason) = outcome else {
            XCTFail("a late reference must refuse the collection")
            return
        }
        XCTAssertEqual(referenceReason, "1 template reference(s)")
        try await store.registry.removeTemplateReference(
            templateID: "basic", version: 1, kind: "build", refID: "late-build"
        )

        try await registerEnvironment("env-atomic", baseImageID: baseImageID, rootfsDigest: nil)
        _ = try await store.registry.pinEnvironmentTemplate(
            environmentID: "env-atomic", templateID: "basic",
            version: 1, digest: template.pin.digest
        )
        // Belt and braces: even if the environment reference ROW is lost, the
        // pin itself refuses the collection inside the transaction.
        try await store.registry.removeTemplateReference(
            templateID: "basic", version: 1, kind: "environment", refID: "env-atomic"
        )
        // A held write lease on the pinned environment refuses even earlier.
        let lease = try await store.leases.acquire(environmentID: "env-atomic", runtimeID: "rt-atomic")
        outcome = try await store.registry.collectTemplateVersionIfUnreferenced(
            templateID: "basic", version: 1, grace: 0, now: Date()
        )
        guard case .skipped(let leaseReason) = outcome, leaseReason == "held write lease" else {
            XCTFail("a held lease must refuse the collection, got \(outcome)")
            return
        }
        await lease.release()
        // With no lease left, the pin itself (reference row lost) still refuses.
        outcome = try await store.registry.collectTemplateVersionIfUnreferenced(
            templateID: "basic", version: 1, grace: 0, now: Date()
        )
        guard case .skipped(let pinReason) = outcome, pinReason == "environment pin" else {
            XCTFail("an environment pin must refuse the collection, got \(outcome)")
            return
        }
        _ = try await store.registry.unpinEnvironmentTemplate(environmentID: "env-atomic")
        let collected = try await store.registry.collectTemplateVersionIfUnreferenced(
            templateID: "basic", version: 1, grace: 0, now: Date()
        )
        guard case .collected(let digest, let bytes, let remaining) = collected else {
            XCTFail("an unprotected version must be collected")
            return
        }
        XCTAssertEqual(digest, template.diskDigest)
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertEqual(remaining, 0)
        let state = try await store.templates.version(templateID: "basic", version: 1)?.state
        XCTAssertEqual(state, .quarantined)
        let collectedBlob = try await store.registry.blob(digest: template.diskDigest)
        XCTAssertEqual(collectedBlob?.refs, 0)
    }

    // MARK: - registration state machine: faults, restart, no orphan refs

    /// A failure while staging the evidence must leave the version failed (never
    /// verified) and must not have placed or referenced any blob.
    func testEvidenceStagingFailureNeverActivatesOrLeaksABlobReference() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let before = try await store.registry.blobStats()
        var seams = RuntimeV2TemplateStore.Seams.production
        seams.evidenceWrite = { _, _ in throw CocoaError(.fileWriteUnknown) }
        store = RuntimeV2Store(layout: layout, templateSeams: seams)
        _ = try await store.prepareAndRecover(build: "test")
        do {
            _ = try await store.templates.build(
                using: ScriptedInstaller(packages: [package("python3", "3.11.2")], downloadBytes: 1),
                request: buildRequest(
                    recipe: recipe(packages: ["python3": .init()]),
                    parent: baseParent(ref, imageID: baseImageID)
                )
            )
            XCTFail("an evidence failure must not register a verified version")
        } catch {
            // expected
        }
        let row = try await store.templates.version(templateID: "basic", version: 1)
        XCTAssertEqual(row?.state, .failed)
        XCTAssertNil(row?.diskDigest)
        XCTAssertTrue(row?.reason?.contains("registration failed before activation") == true)
        let after = try await store.registry.blobStats()
        XCTAssertEqual(after.count, before.count)
        let evidence = layout.recoveryMigrationsDirectory
            .appendingPathComponent("template-basic-v1/template-evidence.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.path))
    }

    /// A failure after the ingest was recorded but before activation (injected
    /// by a concurrent failure at the activation boundary) releases exactly the
    /// one recorded blob reference and marks the version failed.
    func testActivationInterruptionReleasesTheRecordedIngestReferenceExactlyOnce() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let box = TestDigestBox()
        var seams = RuntimeV2TemplateStore.Seams.production
        let registry = await store.registry
        seams.beforeActivation = { templateID, version in
            if let row = try? await registry.template(templateID: templateID, version: version),
               let digest = row.diskDigest {
                await box.set(digest)
            }
            try? await registry.failTemplateVersion(
                templateID: templateID, version: version, reason: "injected concurrent failure"
            )
        }
        store = RuntimeV2Store(layout: layout, templateSeams: seams)
        _ = try await store.prepareAndRecover(build: "test")
        do {
            _ = try await store.templates.build(
                using: ScriptedInstaller(packages: [package("python3", "3.11.2")], downloadBytes: 1),
                request: buildRequest(
                    recipe: recipe(packages: ["python3": .init()]),
                    parent: baseParent(ref, imageID: baseImageID)
                )
            )
            XCTFail("an interrupted activation must not register a verified version")
        } catch {
            // expected
        }
        let digest = await box.get()
        let recordedDigest = try XCTUnwrap(digest)
        let row = try await store.templates.version(templateID: "basic", version: 1)
        XCTAssertEqual(row?.state, .failed)
        XCTAssertNil(row?.diskDigest)
        // The blob file exists but no reference is left behind.
        let blob = try await store.registry.blob(digest: recordedDigest)
        XCTAssertEqual(blob?.refs, 0)
        let exists = try await store.blobs.blobExists(digest: recordedDigest)
        XCTAssertTrue(exists)
        // A second compensation (late error path) must not release again.
        try await store.registry.failTemplateVersion(
            templateID: "basic", version: 1, reason: "late duplicate failure"
        )
        let after = try await store.registry.blob(digest: recordedDigest)
        XCTAssertEqual(after?.refs, 0)
    }

    /// The crash window between recording the ingest and activation: recovery
    /// fails the interrupted build and releases the recorded reference exactly
    /// once, across repeated relaunches.
    func testInterruptedRegistrationRecoveryReleasesTheIngestReferenceExactlyOnce() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let request = buildRequest(
            recipe: recipe(packages: ["python3": .init()]),
            parent: baseParent(ref, imageID: baseImageID)
        )
        let installer = ScriptedInstaller(packages: [package("python3", "3.11.2")], downloadBytes: 1)
        let handle = try await store.templates.stageBuild(request)
        _ = try await installer.install(build: handle, request: request)
        let bytes = RuntimeV2FileBytes.measure(fileAt: handle.workingDiskURL)
        let digest = try FloeDigest.sha512Hex(ofFileAt: handle.workingDiskURL)
        _ = try await store.blobs.stageUnreferenced(
            sourceURL: handle.workingDiskURL, expectedSHA512: digest,
            expectedBytes: bytes.logicalBytes
        )
        let recorded = try await store.registry.recordTemplateIngest(
            templateID: "basic", version: 1, diskDigest: digest, bytes: bytes.logicalBytes
        )
        XCTAssertTrue(recorded)
        let recordedBlob = try await store.registry.blob(digest: digest)
        XCTAssertEqual(recordedBlob?.refs, 1)

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertGreaterThanOrEqual(report.interruptedTemplateBuilds, 1)
        let row = try await relaunched.templates.version(templateID: "basic", version: 1)
        XCTAssertEqual(row?.state, .failed)
        XCTAssertNil(row?.diskDigest)
        let recoveredBlob = try await relaunched.registry.blob(digest: digest)
        XCTAssertEqual(recoveredBlob?.refs, 0)
        // A second relaunch must not release a second time.
        let third = RuntimeV2Store(layout: layout)
        _ = try await third.prepareAndRecover(build: "test")
        let thirdBlob = try await third.registry.blob(digest: digest)
        XCTAssertEqual(thirdBlob?.refs, 0)
    }

    /// Evidence promotion failing after activation must leave the version
    /// verified, the staged evidence intact and a retryable migration state;
    /// `finalizeBuilds` promotes it later without ever losing the evidence.
    func testEvidencePromotionFailureIsRetriedByFinalizeWithoutUnverifying() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        // Occupy the final evidence path with a directory so the atomic rename
        // cannot land (an IO fault the promotion must survive).
        let rollback = layout.recoveryMigrationsDirectory
            .appendingPathComponent("template-basic-v1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rollback.appendingPathComponent("template-evidence.json", isDirectory: true),
            withIntermediateDirectories: true
        )
        let registration = try await store.templates.build(
            using: ScriptedInstaller(packages: [package("python3", "3.11.2")], downloadBytes: 1),
            request: buildRequest(
                recipe: recipe(packages: ["python3": .init()]),
                parent: baseParent(ref, imageID: baseImageID)
            )
        )
        XCTAssertNotNil(registration.diskDigest)
        let state = try await store.templates.version(templateID: "basic", version: 1)?.state
        XCTAssertEqual(state, .verified)
        let staged = rollback.appendingPathComponent(
            RuntimeV2TemplateStore.evidenceStagingFileName
        )
        let final = rollback.appendingPathComponent(RuntimeV2TemplateStore.evidenceFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let migration = try await store.registry.migration(id: "template-basic-v1")
        XCTAssertEqual(migration?.phase, .cleanupPending)
        XCTAssertTrue(migration?.error?.contains("evidence promotion pending") == true)

        // The obstruction is cleared; finalize promotes and completes.
        try FileManager.default.removeItem(at: final)
        let finalized = try await store.templates.finalizeBuilds()
        XCTAssertEqual(finalized, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        // The promoted evidence moved with its rollback directory into trash
        // (still preserved, never a hard delete at finalization).
        let trashed = try FileManager.default.contentsOfDirectory(atPath: layout.trashDirectory.path)
            .filter { $0.hasPrefix("template-basic-v1") }
        XCTAssertEqual(trashed.count, 1)
        let trashedEvidence = layout.trashDirectory
            .appendingPathComponent(trashed[0], isDirectory: true)
            .appendingPathComponent(RuntimeV2TemplateStore.evidenceFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedEvidence.path))
        let done = try await store.registry.migration(id: "template-basic-v1")
        XCTAssertEqual(done?.phase, .done)
    }

    // MARK: - legacy migration: unknown origin fails closed

    func testLegacyDiskWithoutOriginRecordFailsClosedAndPreservesSource() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let expanded = try await store.images.ensureExpanded(imageID: baseImageID)
        let baseRootfs = expanded.appendingPathComponent(ref.expandedPath)

        // A disk that was cloned from the verified base but whose origin
        // sidecar is missing: unknown bytes are never origin proof.
        let unknownDirectory = root.appendingPathComponent("legacy-unknown/env-unknown", isDirectory: true)
        try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: true)
        let unknownDisk = unknownDirectory.appendingPathComponent("disk.img")
        try FileManager.default.copyItem(at: baseRootfs, to: unknownDisk)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unknownDisk.path)
        try writeBytes(unknownDisk, at: 1 << 20, Data(repeating: 0xC7, count: 4096))
        let migrator = RuntimeV2EnvironmentMigrator(store: store)
        do {
            _ = try await migrator.migrateLegacyEnvironment(
                environmentID: "env-unknown", kind: "linuxVM", ownerID: nil, name: nil,
                baseImageID: baseImageID, legacyDiskDirectory: unknownDirectory,
                legacyLayerDirectory: nil
            )
            XCTFail("a disk with no origin record must not be captured against the base")
        } catch RuntimeV2Error.diskOriginUnverifiable(let environmentID, let reason) {
            XCTAssertEqual(environmentID, "env-unknown")
            XCTAssertTrue(reason.contains("origin"))
        }
        let unknownRow = try await store.registry.environment(id: "env-unknown")
        XCTAssertEqual(unknownRow?.state, "repairRequired")
        let unknownDelta = try await store.deltas.loadDelta(environmentID: "env-unknown")
        XCTAssertNil(unknownDelta)
        // The source is preserved (moved to quarantine, bytes intact).
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknownDirectory.path))
        let quarantined = try quarantinedEntries(prefix: "disk-env-unknown")
        XCTAssertEqual(quarantined.count, 1)
        let preserved = layout.quarantineDirectory
            .appendingPathComponent(quarantined[0], isDirectory: true)
            .appendingPathComponent("disk.img")
        let preservedBytes = try readBytes(preserved, at: 1 << 20, count: 4096)
        XCTAssertEqual(preservedBytes, Data(repeating: 0xC7, count: 4096))

        // Control: the same disk with a truthful origin record still migrates.
        let knownDirectory = root.appendingPathComponent("legacy-known/env-known", isDirectory: true)
        try FileManager.default.createDirectory(at: knownDirectory, withIntermediateDirectories: true)
        let knownDisk = knownDirectory.appendingPathComponent("disk.img")
        try FileManager.default.copyItem(at: baseRootfs, to: knownDisk)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: knownDisk.path)
        let origin = LinuxGuestRuntimeDiskOrigin(
            imageID: baseImageID, artifactSHA512: ref.sha512, artifactBytes: ref.bytes
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(origin).write(
            to: knownDirectory.appendingPathComponent("origin.json"), options: .atomic
        )
        let report = try await migrator.migrateLegacyEnvironment(
            environmentID: "env-known", kind: "linuxVM", ownerID: nil, name: nil,
            baseImageID: baseImageID, legacyDiskDirectory: knownDirectory,
            legacyLayerDirectory: nil
        )
        XCTAssertEqual(report.phase, .cleanupPending)
        let knownRow = try await store.registry.environment(id: "env-known")
        XCTAssertEqual(knownRow?.state, "active")
    }

    // MARK: - clone mode is the materialization outcome, never sparse accounting

    func testPinnedCloneModeReportsTheActualMaterializationOutcome() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try await rootfsRef(manifest)
        let parent = baseParent(ref, imageID: baseImageID)
        // Force the byte-copy fallback for BOTH the build clone and the boot
        // clone, on a disk that is genuinely sparse (logical > allocated): the
        // sparse-hole accounting the old heuristic used would have labeled the
        // copy as a clone.
        var templateSeams = RuntimeV2TemplateStore.Seams.production
        templateSeams.cloneFile = { _, _ in false }
        let copyBlobs = RuntimeV2BlobStore.Seams(cloneFile: { _, _ in false })
        store = RuntimeV2Store(layout: layout, templateSeams: templateSeams, blobSeams: copyBlobs)
        _ = try await store.prepareAndRecover(build: "test")
        let template = try await buildTemplate(
            marker: 0xD1, packages: [package("python3", "3.11.2")],
            parent: parent
        )
        let registrationMode = template.buildMode
        XCTAssertEqual(registrationMode, .copy)
        try await registerEnvironment("env-clone-mode", baseImageID: baseImageID, rootfsDigest: ref.sha512.lowercased())
        _ = try await store.templates.pinEnvironment(
            environmentID: "env-clone-mode", templateID: "basic", version: 1
        )
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-clone-mode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = directory.appendingPathComponent("disk.img")
        let clone = try await store.templates.clonePinnedTemplateDisk(
            environmentID: "env-clone-mode", runtimeID: "rt-clone-mode",
            imageID: baseImageID, into: disk
        )
        XCTAssertEqual(clone?.mode, .copy)
        XCTAssertNil(clone?.sharedPhysicalBytes)
        // The copied disk really is sparse: the old sparse-savings heuristic
        // would have reported `.clone` here.
        let bytes = RuntimeV2FileBytes.measure(fileAt: disk)
        XCTAssertNotNil(bytes.allocatedBytes)
        XCTAssertGreaterThan(bytes.logicalBytes, bytes.allocatedBytes ?? bytes.logicalBytes)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: disk), template.diskDigest)

        // And on a clone-capable volume/configuration, an actual clonefile
        // success is recorded as clone.
        let production = RuntimeV2Store(layout: layout)
        _ = try await production.prepareAndRecover(build: "test")
        let secondDirectory = try layout.runtimeVMDirectory(runtimeID: "rt-clone-mode-2")
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let secondDisk = secondDirectory.appendingPathComponent("disk.img")
        let cloned = try await production.templates.clonePinnedTemplateDisk(
            environmentID: "env-clone-mode", runtimeID: "rt-clone-mode-2",
            imageID: baseImageID, into: secondDisk
        )
        XCTAssertEqual(cloned?.mode, volumeSupportsClone() ? .clone : .copy)
        XCTAssertNil(cloned?.sharedPhysicalBytes)
    }

    // MARK: - P0: recovery never touches a disk whose owner is not proven stopped

    /// Deterministic lease-injection fixture: a leftover runtime/vm working
    /// directory with real bytes and a durable ownership record, plus an
    /// optional lease sidecar describing the (possibly live) owner.
    @discardableResult
    private func makeLeftoverWorkingDisk(
        runtimeID: String,
        environmentID: String,
        marker: UInt8 = 0x6A,
        metaRuntimeID: String? = nil,
        lease: RuntimeV2LeaseStore.Lease? = nil
    ) throws -> URL {
        let directory = try layout.runtimeVMDirectory(runtimeID: runtimeID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = directory.appendingPathComponent("disk.img")
        try Data(repeating: marker, count: 8192).write(to: disk)
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: metaRuntimeID ?? runtimeID,
                environmentID: environmentID,
                baseImageID: baseImageID,
                createdAt: Date()
            ),
            to: directory
        )
        if let lease {
            let environmentDir = try layout.environmentDirectory(environmentID: environmentID)
            try FileManager.default.createDirectory(at: environmentDir, withIntermediateDirectories: true)
            try RuntimeV2LeaseStore.encoder.encode(lease).write(
                to: environmentDir.appendingPathComponent("lease.json"), options: .atomic
            )
        }
        return directory
    }

    private func liveLease(
        environmentID: String, runtimeID: String,
        incarnation: String, pid: Int64,
        renewedAt: Date = Date(), ttlSeconds: Int64 = 30
    ) -> RuntimeV2LeaseStore.Lease {
        RuntimeV2LeaseStore.Lease(
            environmentID: environmentID, runtimeID: runtimeID, incarnation: incarnation,
            sessionToken: "token", pid: pid,
            acquiredAt: renewedAt, renewedAt: renewedAt, ttlSeconds: ttlSeconds
        )
    }

    /// A lease held by a LIVE pid (another app instance, or a session of this
    /// one) makes the owner unprovable: recovery must preserve the working
    /// disk byte-for-byte — no capture into the delta, no quarantine move, no
    /// delete — and report it as preserved.
    func testRecoveryPreservesWorkingDiskUnderLivePidLease() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment("env-live", baseImageID: baseImageID, rootfsDigest: nil)
        let directory = try makeLeftoverWorkingDisk(
            runtimeID: "rt-live", environmentID: "env-live",
            lease: liveLease(
                environmentID: "env-live", runtimeID: "rt-live",
                incarnation: "other-incarnation",
                pid: Int64(ProcessInfo.processInfo.processIdentifier)
            )
        )

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.preservedRuntimeDirs.contains("rt-live"))
        XCTAssertFalse(report.salvagedRuntimeDirs.contains("rt-live"))
        XCTAssertFalse(report.quarantinedRuntimeDirs.contains("rt-live"))
        // Every byte is exactly where it was.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let disk = directory.appendingPathComponent("disk.img")
        XCTAssertEqual(try Data(contentsOf: disk), Data(repeating: 0x6A, count: 8192))
        // Nothing was captured into the environment's delta.
        let delta = try await relaunched.deltas.loadDelta(environmentID: "env-live")
        XCTAssertNil(delta)
        // The unresolved lease still marks the environment interrupted, but no
        // repair/quarantine state was invented for a disk we did not touch.
        XCTAssertTrue(
            report.notes.contains { $0.contains("rt-live") && $0.contains("lease") },
            "expected a preservation note, got \(report.notes)"
        )
    }

    /// A dead pid is NOT proof when the TTL has not expired: the owning
    /// thread may still hold an open disk handle. Fail closed: preserve.
    func testRecoveryPreservesWorkingDiskUnderUnexpiredDeadPidLease() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment("env-ttl", baseImageID: baseImageID, rootfsDigest: nil)
        let directory = try makeLeftoverWorkingDisk(
            runtimeID: "rt-ttl", environmentID: "env-ttl",
            lease: liveLease(
                environmentID: "env-ttl", runtimeID: "rt-ttl",
                incarnation: "other-incarnation",
                pid: 4_000_000, // provably dead pid…
                renewedAt: Date(), ttlSeconds: 30 // …but the lease is still inside its TTL
            )
        )

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.preservedRuntimeDirs.contains("rt-ttl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("disk.img")),
            Data(repeating: 0x6A, count: 8192)
        )
        let ttlDelta = try await relaunched.deltas.loadDelta(environmentID: "env-ttl")
        XCTAssertNil(ttlDelta)
    }

    /// Reentrant recovery (a second prepareAndRecover in the SAME process,
    /// e.g. a status read racing app start) must preserve the disk of a VM
    /// whose live session holds this incarnation's lease.
    func testRecoveryPreservesWorkingDiskUnderOwnIncarnationLiveLease() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment("env-own", baseImageID: baseImageID, rootfsDigest: nil)
        // A live session of this very store holds the lease.
        let held = try await store.leases.acquire(environmentID: "env-own", runtimeID: "rt-own")
        let directory = try makeLeftoverWorkingDisk(runtimeID: "rt-own", environmentID: "env-own")

        // Reentrant recovery in the same process must not salvage "our" disk.
        let report = try await store.prepareAndRecover(build: "test")
        XCTAssertTrue(report.preservedRuntimeDirs.contains("rt-own"))
        XCTAssertFalse(report.salvagedRuntimeDirs.contains("rt-own"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("disk.img")),
            Data(repeating: 0x6A, count: 8192)
        )
        _ = held
        await held.release()
    }

    /// The positive control: a dead pid past TTL is provably stale, so the
    /// ordinary verified salvage path runs and the directory is removed.
    func testRecoverySalvagesWorkingDiskWhenLeaseProvenStale() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try rootfsRef(manifest)
        try await registerEnvironment(
            "env-stale", baseImageID: baseImageID, rootfsDigest: ref.sha512.lowercased()
        )
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-stale")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = directory.appendingPathComponent("disk.img")
        _ = try await store.blobs.materialize(
            digest: ref.sha512.lowercased(), at: disk, writable: true
        )
        try writeBytes(disk, at: 2 << 20, Data(repeating: 0x6B, count: 4096))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-stale", environmentID: "env-stale",
                baseImageID: baseImageID, createdAt: Date(),
                bootBaseDiskDigest: ref.sha512.lowercased()
            ),
            to: directory
        )
        let environmentDir = try layout.environmentDirectory(environmentID: "env-stale")
        try FileManager.default.createDirectory(at: environmentDir, withIntermediateDirectories: true)
        try RuntimeV2LeaseStore.encoder.encode(liveLease(
            environmentID: "env-stale", runtimeID: "rt-stale",
            incarnation: "other-incarnation", pid: 4_000_000,
            renewedAt: Date(timeIntervalSinceNow: -600), ttlSeconds: 30
        )).write(to: environmentDir.appendingPathComponent("lease.json"), options: .atomic)

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.salvagedRuntimeDirs.contains("rt-stale"))
        XCTAssertFalse(report.preservedRuntimeDirs.contains("rt-stale"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let delta = try await relaunched.deltas.loadDelta(environmentID: "env-stale")
        XCTAssertGreaterThan(delta?.presentBlocks ?? 0, 0)
    }

    /// An ownership record that names a different runtime than the directory
    /// it sits in is inconsistent: attribution is uncertain, so the disk is
    /// preserved untouched (never captured against the wrong environment).
    func testRecoveryPreservesWorkingDiskWithInconsistentOwnershipRecord() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment("env-mismatch", baseImageID: baseImageID, rootfsDigest: nil)
        let directory = try makeLeftoverWorkingDisk(
            runtimeID: "rt-mismatch", environmentID: "env-mismatch",
            metaRuntimeID: "somebody-else"
        )

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.preservedRuntimeDirs.contains("rt-mismatch"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let mismatchDelta = try await relaunched.deltas.loadDelta(environmentID: "env-mismatch")
        XCTAssertNil(mismatchDelta)
    }

    /// A working disk whose environment the registry does not know is not
    /// adoptable: preserved for inspection, never captured.
    func testRecoveryPreservesWorkingDiskOfUnknownEnvironment() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let directory = try makeLeftoverWorkingDisk(
            runtimeID: "rt-orphan", environmentID: "env-never-registered"
        )

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.preservedRuntimeDirs.contains("rt-orphan"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - P0: blob GC is linearized against stage/ingest via durable claims

    /// The deterministic registration/GC interleaving: blob GC runs in the
    /// window AFTER the disk bytes were staged and BEFORE the ingest
    /// transaction records the owner (injected on the seam). The durable
    /// staging claim — not a post-await refs re-check — must refuse the
    /// collection: the physical bytes stay at the canonical path, and the
    /// registration completes with the bytes present and referenced.
    func testBlobGCSkipsStagedDiskBetweenStageAndRegistration() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try rootfsRef(manifest)
        // Same layout, same database: driving the interleaved GC through the
        // original store's actors exercises exactly the files and rows the
        // raced build is staging.
        let blobs = await store.blobs
        let registry = await store.registry

        var racedSeams = RuntimeV2TemplateStore.Seams.production
        let claimBox = TestDigestBox()
        let canonicalBox = TestDigestBox()
        let reclaimedBox = TestDigestBox()
        racedSeams.beforeRecordIngest = { _, _, digest in
            // 1. The staging claim is durable BEFORE the ingest: GC must see it.
            let claimed = try? await registry.blob(digest: digest)
            await claimBox.set(claimed.map { "\($0.staged)" })
            // 2. Run the "concurrent" collection deterministically inside the
            //    window, with a grace of zero and a future clock so the fresh
            //    row passes the age filter: only the claim may refuse it.
            let reclaimed = (try? await blobs.collectGarbage(
                grace: 0, now: Date().addingTimeInterval(30)
            )) ?? -1
            await reclaimedBox.set("\(reclaimed)")
            // 3. The physical bytes must still be at the canonical path — GC
            //    neither deleted them nor moved them to quarantine.
            let canonical = try? await blobs.verifiedBlobURL(digest: digest)
            await canonicalBox.set(canonical?.path)
        }
        store = RuntimeV2Store(layout: layout, templateSeams: racedSeams)
        _ = try await store.prepareAndRecover(build: "test")
        let template = try await buildTemplate(
            marker: 0xE1, packages: [package("python3", "3.11.2")],
            parent: baseParent(ref, imageID: baseImageID)
        )

        // The claim was observed during the window; the interleaved GC
        // reclaimed NOTHING (the claim refused the collection); the bytes
        // survived at the canonical path; the registration completed and
        // referenced them.
        let observedClaim = await claimBox.get()
        XCTAssertEqual(observedClaim, "1")
        let observedReclaimed = await reclaimedBox.get()
        XCTAssertEqual(observedReclaimed, "0")
        let observedPath = await canonicalBox.get()
        let canonicalPath = try XCTUnwrap(observedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalPath))
        let row = try await store.registry.blob(digest: template.diskDigest)
        XCTAssertEqual(row?.refs, 1)
        XCTAssertEqual(row?.staged, 0)
        let state = try await store.templates.version(templateID: "basic", version: 1)?.state
        XCTAssertEqual(state, .verified)
        XCTAssertEqual(
            try FloeDigest.sha512Hex(ofFileAt: URL(fileURLWithPath: canonicalPath)),
            template.diskDigest
        )
    }

    /// The registry claim is authoritative even when the reference lands
    /// after the candidate listing: the collection transaction itself refuses
    /// the delete, and the physical bytes stay untouched.
    func testBlobGCClaimRefusesDeleteAfterReferenceLands() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try rootfsRef(manifest)
        let digest = ref.sha512.lowercased()
        // Release the base image's reference: an aged, unreferenced row.
        try await store.blobs.release(digest: digest)
        let candidates = try await store.registry.unreferencedBlobs(
            olderThan: Date().addingTimeInterval(30)
        )
        XCTAssertTrue(candidates.contains { $0.digest == digest })

        // The reference lands inside the window (any order the transaction
        // serializes, the claim must refuse the stale view).
        try await store.registry.claimBlobReference(digest: digest, bytes: ref.bytes)
        let collected = try await store.registry.collectBlobIfUnreferenced(digest: digest)
        XCTAssertFalse(collected, "a referenced row must refuse the GC claim")
        let row = try await store.registry.blob(digest: digest)
        XCTAssertEqual(row?.refs, 1)
        let canonical = try await store.blobs.verifiedBlobURL(digest: digest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
    }

    /// A collected blob's bytes are never hard-deleted: GC moves them to the
    /// deterministic quarantine slot, and the first verified read restores
    /// them to the canonical path — no verified reference can ever observe
    /// missing bytes.
    func testBlobGCQuarantinesBytesAndVerifiedReadRestoresThem() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try rootfsRef(manifest)
        let digest = ref.sha512.lowercased()
        try await store.blobs.release(digest: digest)
        let canonical = try await store.blobs.verifiedBlobURL(digest: digest)

        let reclaimed = try await store.blobs.collectGarbage(
            grace: 0, now: Date().addingTimeInterval(30)
        )
        XCTAssertGreaterThan(reclaimed, 0)
        let goneRow = try await store.registry.blob(digest: digest)
        XCTAssertNil(goneRow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
        let quarantine = try layout.blobQuarantineURL(digest: digest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))

        // The first verified reader restores the exact bytes.
        let restored = try await store.blobs.verifiedBlobURL(digest: digest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: restored), digest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))

        // Full re-verification also self-heals a reclaimed blob.
        try await store.blobs.release(digest: digest)
        _ = try await store.blobs.collectGarbage(grace: 0, now: Date().addingTimeInterval(30))
        try await store.blobs.verify(digest: digest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
    }

    /// An ingest that fails before its reference conversion releases its
    /// staging claim, and a process restart resets any claim the dead process
    /// left behind — staged bytes never leak permanent GC protection.
    func testStagingClaimsAreReleasedOnFailureAndResetOnRecovery() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let source = root.appendingPathComponent("claim-source.bin")
        try Data(repeating: 0xC1, count: 4096).write(to: source)
        let digest = try FloeDigest.sha512Hex(ofFileAt: source)

        // A stage that never reaches registration (simulated by failing the
        // placement: size disagreement) must not leave a claim behind.
        do {
            _ = try await store.blobs.stageUnreferenced(
                sourceURL: source, expectedSHA512: digest, expectedBytes: 8192
            )
            XCTFail("a size disagreement must refuse the stage")
        } catch {
            // expected
        }
        var row = try await store.registry.blob(digest: digest)
        XCTAssertTrue(row == nil || row?.staged == 0)

        // A claim taken by a dying process is reset by startup recovery, so
        // the bytes become collectable again instead of leaking protection.
        try await store.registry.takeBlobStagingClaim(digest: digest, bytes: 4096)
        row = try await store.registry.blob(digest: digest)
        XCTAssertEqual(row?.staged, 1)
        let relaunched = RuntimeV2Store(layout: layout)
        _ = try await relaunched.prepareAndRecover(build: "test")
        row = try await relaunched.registry.blob(digest: digest)
        XCTAssertEqual(row?.staged, 0)
    }

    // MARK: - P0: failed-capture persistence is durable before the lease release

    /// Fault at the shutdown-record stage: the disk is quarantined (physical
    /// preservation is independent of persistence), but the lease is KEPT,
    /// the outcome truthfully says the marker could not be persisted, and a
    /// restart of the environment is refused — no `try?` converts the
    /// preservation failure into a releasable success.
    func testFailedCaptureShutdownRecordFaultRetainsLeaseAndRefusesRestart() async throws {
        try await assertFailedCapturePersistenceFault(
            seams: RuntimeV2GuestIntegrator.Seams(
                recordShutdown: { _, _ in throw CocoaError(.fileWriteUnknown) }
            ),
            expectShutdownRecord: false
        )
    }

    /// Fault at the repair-marker stage (the shutdown record DID persist):
    /// the lease is still kept — the durable exclusion must exist before the
    /// release, and half-persisted failure state is not success.
    func testFailedCaptureRepairMarkerFaultRetainsLeaseAndRefusesRestart() async throws {
        try await assertFailedCapturePersistenceFault(
            seams: RuntimeV2GuestIntegrator.Seams(
                markRepairRequired: { _, _ in throw RuntimeV2Error.registryCorrupt("injected") }
            ),
            expectShutdownRecord: true
        )
    }

    private func assertFailedCapturePersistenceFault(
        seams: RuntimeV2GuestIntegrator.Seams,
        expectShutdownRecord: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try rootfsRef(manifest)
        let template = try await buildTemplate(
            marker: 0x7E, packages: [package("python3", "3.11.2")],
            parent: baseParent(ref, imageID: baseImageID)
        )
        try await registerEnvironment(
            "env-fault", baseImageID: baseImageID, rootfsDigest: ref.sha512.lowercased()
        )
        _ = try await store.templates.pinEnvironment(
            environmentID: "env-fault", templateID: "basic", version: 1
        )
        // The production shape: ONE integrator boots the environment and later
        // stops it, so the retained lease after a persistence fault is this
        // very integrator's held lease (the surviving exclusion).
        let integrator = RuntimeV2GuestIntegrator(store: store, build: "test", seams: seams)
        let admission = try await integrator.acquireSlot(
            environmentID: "env-fault", runtimeID: "rt-fault", requestedMB: 512
        )
        XCTAssertGreaterThan(admission.ramMB, 0, file: file, line: line)
        let work = try await integrator.prepareWorkingDisk(
            environmentID: "env-fault", runtimeID: "rt-fault", imageID: baseImageID,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        try writeBytes(work.diskURL, at: 2 << 20, Data(repeating: 0x7F, count: 4096))
        // The immutable boot base disappears: the capture cannot be proven.
        let blobURL = try await store.blobs.verifiedBlobURL(digest: template.diskDigest)
        try FileManager.default.removeItem(at: blobURL)
        let outcome = await integrator.completeStopResult(
            environmentID: "env-fault", runtimeID: "rt-fault", imageID: baseImageID, clean: true
        )
        guard case .retainedForRepair(let reason) = outcome else {
            XCTFail("a failed capture must retain the disk, got \(outcome)", file: file, line: line)
            return
        }
        XCTAssertTrue(reason.contains("could not be persisted"), file: file, line: line)
        XCTAssertTrue(reason.contains("lease was retained"), file: file, line: line)

        // Physical preservation happened regardless of the persistence fault.
        let quarantined = try quarantinedEntries(prefix: "runtime-vm-rt-fault")
        XCTAssertEqual(quarantined.count, 1, file: file, line: line)
        let preservedDisk = layout.quarantineDirectory
            .appendingPathComponent(quarantined[0], isDirectory: true)
            .appendingPathComponent("disk.img")
        XCTAssertEqual(
            try readBytes(preservedDisk, at: 2 << 20, count: 4096),
            Data(repeating: 0x7F, count: 4096),
            file: file, line: line
        )

        // The shutdown record exists only when that stage's write succeeded.
        let shutdown = try await store.deltas.lastShutdown(environmentID: "env-fault")
        if expectShutdownRecord {
            XCTAssertNotNil(shutdown, file: file, line: line)
        } else {
            XCTAssertNil(shutdown, file: file, line: line)
        }

        // The lease was NOT released: the sole exclusion survived, the
        // environment was not marked repairRequired by a failed write, and a
        // restart is refused while the preserved bytes exist.
        let holder = try await store.leases.holder(environmentID: "env-fault")
        XCTAssertEqual(holder?.runtimeID, "rt-fault", file: file, line: line)
        let state = try await store.registry.environment(id: "env-fault")?.state
        XCTAssertNotEqual(state, "repairRequired", file: file, line: line)
        // The durable non-expiring repair hold was placed before the lease
        // retention decision: it is the cross-process exclusion that survives
        // process death + TTL expiry, so a restart is refused even on a fresh
        // integrator that never held the lease.
        let hold = await store.repairHolds.hold(environmentID: "env-fault")
        XCTAssertNotNil(hold, file: file, line: line)
        do {
            _ = try await integrator.prepareWorkingDisk(
                environmentID: "env-fault", runtimeID: "rt-fault-2", imageID: baseImageID,
                legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
            )
            XCTFail("a restart over preserved bytes must be refused while the lease is retained", file: file, line: line)
        } catch RuntimeV2Error.environmentRepairRequired(let heldEnvironment, _) {
            XCTAssertEqual(heldEnvironment, "env-fault", file: file, line: line)
        }
    }

    /// A failed/partial lease release can never clear the sole exclusion
    /// sidecar: when the durable registry release fails (the injected
    /// full-disk/IO/DB fault), the sidecar stays and the holder is still
    /// observed — the exclusion survives for the next launch to re-prove.
    func testLeaseReleaseKeepsSidecarWhenDurableReleaseFails() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let registry = await store.registry
        let faulting = RuntimeV2LeaseStore(
            layout: layout,
            registry: registry,
            incarnation: "fault-incarnation",
            seams: .init(releaseInRegistry: { _, _ in
                throw RuntimeV2Error.registryCorrupt("injected durable-release fault")
            })
        )
        let held = try await faulting.acquire(
            environmentID: "env-keep", runtimeID: "rt-keep"
        )
        await held.release()

        // The sidecar — the surviving exclusion record — was NOT removed.
        let sidecar = try layout.environmentLeaseURL(environmentID: "env-keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let holder = try await faulting.holder(environmentID: "env-keep")
        XCTAssertEqual(holder?.runtimeID, "rt-keep")
    }

    // MARK: - P0: the repair exclusion survives process death + TTL expiry

    /// Cross-process durability of the failed-capture exclusion: the lease
    /// held after a persistence fault is TTL-based, so process death + TTL
    /// expiry used to make LeaseStore reclaim it and let a fresh VM boot over
    /// the orphaned preserved state. The durable non-expiring repair hold
    /// (and, when even it could not be written, the authoritative quarantine
    /// recovery) must now exclude the environment on a BRAND-NEW store/lease
    /// identity, with every preserved byte intact.
    func testFailedCaptureShutdownRecordFaultSurvivesProcessDeathAndTTLExpiry() async throws {
        try await assertFailedCaptureCrossProcessExclusion(
            seams: RuntimeV2GuestIntegrator.Seams(
                recordShutdown: { _, _ in throw CocoaError(.fileWriteUnknown) }
            ),
            expectHoldAtStop: true,
            expectShutdownRecord: false,
            expectLeaseRetainedAtStop: true,
            expectLeaseSidecarAfterRecovery: true
        )
    }

    func testFailedCaptureRepairMarkerFaultSurvivesProcessDeathAndTTLExpiry() async throws {
        try await assertFailedCaptureCrossProcessExclusion(
            seams: RuntimeV2GuestIntegrator.Seams(
                markRepairRequired: { _, _ in throw RuntimeV2Error.registryCorrupt("injected") }
            ),
            expectHoldAtStop: true,
            expectShutdownRecord: true,
            expectLeaseRetainedAtStop: true,
            expectLeaseSidecarAfterRecovery: true
        )
    }

    /// The hardest window: even the repair-hold marker could not be persisted
    /// (full disk / IO fault), so the ONLY in-process exclusion (the lease)
    /// dies with the process and expires. The quarantined bytes themselves
    /// are then the durable evidence: startup recovery must re-derive the
    /// hold + repairRequired state from the orphaned quarantine entry, and
    /// the fresh start must still be refused.
    func testFailedCaptureHoldFaultRecoveredFromQuarantineAfterProcessDeath() async throws {
        try await assertFailedCaptureCrossProcessExclusion(
            seams: RuntimeV2GuestIntegrator.Seams(
                placeRepairHold: { _, _, _, _ in
                    throw RuntimeV2Error.insufficientSpace(required: 4096, available: 0)
                }
            ),
            expectHoldAtStop: false,
            expectShutdownRecord: false,
            expectLeaseRetainedAtStop: true,
            expectHoldWriteFailureNote: true,
            expectLeaseSidecarAfterRecovery: false
        )
    }

    private func assertFailedCaptureCrossProcessExclusion(
        seams: RuntimeV2GuestIntegrator.Seams,
        expectHoldAtStop: Bool,
        expectShutdownRecord: Bool,
        expectLeaseRetainedAtStop: Bool,
        expectHoldWriteFailureNote: Bool = false,
        expectLeaseSidecarAfterRecovery: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let manifest = try await makeVerifiedBaseImage(imageID: baseImageID)
        let ref = try rootfsRef(manifest)
        let template = try await buildTemplate(
            marker: 0x7E, packages: [package("python3", "3.11.2")],
            parent: baseParent(ref, imageID: baseImageID)
        )
        try await registerEnvironment(
            "env-xproc", baseImageID: baseImageID, rootfsDigest: ref.sha512.lowercased()
        )
        _ = try await store.templates.pinEnvironment(
            environmentID: "env-xproc", templateID: "basic", version: 1
        )
        let integrator = RuntimeV2GuestIntegrator(store: store, build: "test", seams: seams)
        let admission = try await integrator.acquireSlot(
            environmentID: "env-xproc", runtimeID: "rt-xproc", requestedMB: 512
        )
        XCTAssertGreaterThan(admission.ramMB, 0, file: file, line: line)
        let work = try await integrator.prepareWorkingDisk(
            environmentID: "env-xproc", runtimeID: "rt-xproc", imageID: baseImageID,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        try writeBytes(work.diskURL, at: 2 << 20, Data(repeating: 0x9E, count: 4096))
        // The immutable boot base disappears: the capture cannot be proven.
        let blobURL = try await store.blobs.verifiedBlobURL(digest: template.diskDigest)
        try FileManager.default.removeItem(at: blobURL)

        let outcome = await integrator.completeStopResult(
            environmentID: "env-xproc", runtimeID: "rt-xproc", imageID: baseImageID, clean: true
        )
        guard case .retainedForRepair(let reason) = outcome else {
            XCTFail("a failed capture must retain the disk, got \(outcome)", file: file, line: line)
            return
        }
        XCTAssertTrue(reason.contains("could not be persisted"), file: file, line: line)
        XCTAssertTrue(reason.contains("lease was retained"), file: file, line: line)
        if expectHoldWriteFailureNote {
            XCTAssertTrue(reason.contains("repair hold could not be persisted"), file: file, line: line)
        }

        // Physical preservation happened regardless of the persistence fault.
        let quarantined = try quarantinedEntries(prefix: "runtime-vm-rt-xproc")
        XCTAssertEqual(quarantined.count, 1, file: file, line: line)
        let preservedDisk = layout.quarantineDirectory
            .appendingPathComponent(quarantined[0], isDirectory: true)
            .appendingPathComponent("disk.img")
        XCTAssertEqual(
            try readBytes(preservedDisk, at: 2 << 20, count: 4096),
            Data(repeating: 0x9E, count: 4096),
            file: file, line: line
        )

        // The hold state right after the stop (before the simulated death).
        let holdAtStop = await store.repairHolds.hold(environmentID: "env-xproc")
        XCTAssertEqual(holdAtStop != nil, expectHoldAtStop, file: file, line: line)
        let shutdownAtStop = try await store.deltas.lastShutdown(environmentID: "env-xproc")
        XCTAssertEqual(shutdownAtStop != nil, expectShutdownRecord, file: file, line: line)
        let holderAtStop = try await store.leases.holder(environmentID: "env-xproc")
        XCTAssertEqual(holderAtStop != nil, expectLeaseRetainedAtStop, file: file, line: line)

        // Simulate PROCESS DEATH followed by TTL EXPIRY: the recorded holder
        // is rewritten as a dead pid long past its TTL — precisely the state a
        // brand-new process incarnation observes.
        let environmentDir = try layout.environmentDirectory(environmentID: "env-xproc")
        let deadLease = RuntimeV2LeaseStore.Lease(
            environmentID: "env-xproc", runtimeID: "rt-xproc", incarnation: "dead-incarnation",
            sessionToken: "dead-token", pid: 4_000_000,
            acquiredAt: Date(timeIntervalSinceNow: -600), renewedAt: Date(timeIntervalSinceNow: -600),
            ttlSeconds: 30
        )
        try RuntimeV2LeaseStore.encoder.encode(deadLease).write(
            to: environmentDir.appendingPathComponent("lease.json"), options: .atomic
        )

        // A brand-new store: new registry handle, new lease incarnation
        // (new process identity), production seams.
        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")

        // The stale-looking lease was never reclaimed while a hold exists; in
        // the hold-fault variant the quarantine recovery re-derived the whole
        // exclusion from the preserved bytes.
        let hold = await relaunched.repairHolds.hold(environmentID: "env-xproc")
        XCTAssertNotNil(hold, "the repair exclusion must survive process death + TTL expiry", file: file, line: line)
        let state = try await relaunched.registry.environment(id: "env-xproc")?.state
        XCTAssertEqual(state, "repairRequired", file: file, line: line)
        if expectHoldAtStop {
            XCTAssertTrue(
                report.unreclaimableLeases.contains("env-xproc"),
                "the lease must stay unreclaimable while the hold exists, got \(report.unreclaimableLeases)",
                file: file, line: line
            )
            let sidecar = environmentDir.appendingPathComponent("lease.json")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: sidecar.path),
                "the lease sidecar must not be reclaimed while the hold exists",
                file: file, line: line
            )
        } else {
            XCTAssertTrue(
                report.repairReapplied.contains("env-xproc"),
                "quarantine recovery must re-derive the repair state, got \(report.repairReapplied)",
                file: file, line: line
            )
            let sidecar = environmentDir.appendingPathComponent("lease.json")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sidecar.path),
                "without a hold the proven-stale lease is reclaimed by the new identity",
                file: file, line: line
            )
        }

        // The preserved bytes are exactly where the stop left them.
        XCTAssertEqual(
            try readBytes(preservedDisk, at: 2 << 20, count: 4096),
            Data(repeating: 0x9E, count: 4096),
            file: file, line: line
        )

        // A fresh start on the new identity is refused BEFORE any lease or
        // disk prepare: no working directory is materialized.
        let freshIntegrator = RuntimeV2GuestIntegrator(store: relaunched, build: "test")
        do {
            _ = try await freshIntegrator.prepareWorkingDisk(
                environmentID: "env-xproc", runtimeID: "rt-xproc-2", imageID: baseImageID,
                legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
            )
            XCTFail("a fresh VM must never boot over the preserved bytes", file: file, line: line)
        } catch RuntimeV2Error.environmentRepairRequired(let heldEnvironment, _) {
            XCTAssertEqual(heldEnvironment, "env-xproc", file: file, line: line)
        }
        let freshRuntimeDir = try layout.runtimeVMDirectory(runtimeID: "rt-xproc-2")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: freshRuntimeDir.path),
            "no fresh working disk may exist after the refused start",
            file: file, line: line
        )
        // The refused start never took a lease: while the hold exists the old
        // sidecar is left untouched as evidence (not reclaimed, not renewed);
        // in the hold-fault variant the proven-stale sidecar was reclaimed.
        let freshLease = try await relaunched.leases.holder(environmentID: "env-xproc")
        if expectLeaseSidecarAfterRecovery {
            XCTAssertEqual(freshLease?.runtimeID, "rt-xproc", file: file, line: line)
            XCTAssertEqual(freshLease?.incarnation, "dead-incarnation", file: file, line: line)
        } else {
            XCTAssertNil(freshLease, "a proven-stale lease is reclaimed once the hold is re-derived", file: file, line: line)
        }
        // The preserved bytes survived the refused start untouched.
        XCTAssertEqual(
            try readBytes(preservedDisk, at: 2 << 20, count: 4096),
            Data(repeating: 0x9E, count: 4096),
            file: file, line: line
        )
    }
}

/// Small Sendable box for capturing a digest from a seam closure.
private actor TestDigestBox {
    private var digest: String?
    func set(_ value: String?) { digest = value }
    func get() -> String? { digest }
}
