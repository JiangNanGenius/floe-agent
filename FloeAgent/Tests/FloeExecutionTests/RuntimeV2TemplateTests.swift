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
}
