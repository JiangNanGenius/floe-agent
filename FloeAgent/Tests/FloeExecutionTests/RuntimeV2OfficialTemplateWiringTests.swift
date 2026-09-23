// FloeExecutionTests — C5 official template distribution → environment pin.
//
// These tests drive the REAL Runtime v2 substrate (SQLite registry,
// content-addressed blob store, block deltas, production integrator) with a
// scripted archive downloader. They pin the contracts that make the
// official-template flow honest:
//
//   - only a cloud-pinned artifact whose archive digest, image manifest
//     template block, recipe digest and disk digest all match can be
//     registered; a tampered archive, an unverified guest block or a recipe
//     mismatch registers nothing and leaves the option unavailable;
//   - a logical (sparse) template disk is staged with holes preserved, so a
//     grown cloud image does not cost its logical size on the device;
//   - the production integrator materializes a pinned environment's working
//     disk as a clone of the immutable template install plus the environment's
//     private delta (the immutable pin reaches the boot disk);
//   - two environments cloned from one template mutate independently and an
//     unpinned (existing) environment stays on its own base image;
//   - pinning refuses a row whose base image is not the template's root base.

import Foundation
import XCTest
import FloeCore
@testable import FloeExecution

final class RuntimeV2OfficialTemplateWiringTests: XCTestCase {
    private var root: URL!
    private var layout: RuntimeV2Layout!
    private var store: RuntimeV2Store!
    private var integrator: RuntimeV2GuestIntegrator!

    private let baseImageID = "base-image"
    private let templateImageID = "base-image-dev-document"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-v2-official-\(UUID().uuidString)", isDirectory: true)
        layout = RuntimeV2Layout(root: root)
        store = RuntimeV2Store(layout: layout)
        integrator = RuntimeV2GuestIntegrator(
            store: store,
            legacyImagesRoot: root.appendingPathComponent("legacy-images", isDirectory: true)
        )
        _ = try await store.prepareAndRecover(build: "official-template-tests")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - fixtures

    private struct StagedImage {
        var directory: URL
        var diskDigest: String
        var diskLogicalBytes: Int
        var zipURL: URL
    }

    /// Writes one qualified legacy image (bios + disk + manifest) and zips it
    /// flat, exactly like the cloud build packages its candidate.
    private func makeLegacyImageZip(
        imageID: String, diskSeed: UInt8, diskLogicalBytes: Int = 2 << 20,
        templateBlock: [String: Any]? = nil
    ) throws -> StagedImage {
        let directory = root.appendingPathComponent("fixture-\(imageID)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bios = Data(count: 4096)
        for index in bios.indices { bios[index] = UInt8((index &* 7) % 251) }
        // A mostly-hole sparse disk: only the first 64 KiB carry data, the
        // rest is a hole — the staging must preserve that.
        var disk = Data(count: 64 << 10)
        for index in disk.indices { disk[index] = UInt8((index &* Int(diskSeed)) % 253) }
        let handle = try FileHandle(forWritingTo: try writeFile(named: "disk.img", in: directory))
        try handle.write(contentsOf: disk)
        try handle.truncate(atOffset: UInt64(diskLogicalBytes))
        try handle.close()
        let diskDigest = try FloeDigest.sha512Hex(ofFileAt: directory.appendingPathComponent("disk.img"))
        try bios.write(to: directory.appendingPathComponent("bios.bin"))
        var manifest: [String: Any] = [
            "id": imageID,
            "biosPath": "bios.bin",
            "diskPath": "disk.img",
            "diskReadWrite": true,
            "qualified": true,
            "qualificationRun": "https://github.com/JiangNanGenius/floe-agent/actions/runs/999",
            "artifacts": [
                ["role": "bios", "path": "bios.bin", "sha512": FloeDigest.sha512Hex(bios), "bytes": bios.count],
                ["role": "disk", "path": "disk.img", "sha512": diskDigest, "bytes": diskLogicalBytes]
            ]
        ]
        if let templateBlock { manifest["template"] = templateBlock }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        let zipURL = root.appendingPathComponent("\(imageID)-\(UUID().uuidString).zip")
        try FileManager.default.zipItem(at: directory, to: zipURL, shouldKeepParent: false)
        return StagedImage(
            directory: directory, diskDigest: diskDigest,
            diskLogicalBytes: diskLogicalBytes, zipURL: zipURL
        )
    }

    private func writeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func recipeBytes(name: String, packages: [String: Any]) throws -> Data {
        let object: [String: Any] = [
            "schema": 1, "name": name,
            "description": "test recipe", "packages": packages
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func pinnedArtifact(
        templateID: String, imageID: String, archiveData: Data, diskDigest: String,
        recipe: Data, qualifications: String = "https://github.com/JiangNanGenius/floe-agent/actions/runs/999"
    ) -> RuntimeV2OfficialTemplateArtifact {
        RuntimeV2OfficialTemplateArtifact(
            templateID: templateID, version: 1, imageID: imageID,
            archiveURL: "https://example.invalid/\(templateID).zip",
            archiveSHA512: FloeDigest.sha512Hex(archiveData),
            archiveBytes: Int64(archiveData.count),
            diskSHA512: diskDigest,
            recipeSHA512: FloeDigest.sha512Hex(recipe),
            recipeBase64: recipe.base64EncodedString(),
            qualificationRunURL: qualifications, sourceRef: "deadbeef"
        )
    }

    /// Archive downloader that writes the scripted payload to the destination.
    private actor ScriptedDownloader: LinuxGuestImageDownloading {
        private let payloads: [String: Data]

        init(payloads: [String: Data]) { self.payloads = payloads }

        func download(
            _ url: URL, to destination: URL, maxBytes: Int64,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void
        ) async throws(LinuxGuestImageTransferError) {
            guard let payload = payloads[url.lastPathComponent] else {
                throw LinuxGuestImageTransferError.networkFailure(detail: "no scripted payload for \(url.lastPathComponent)")
            }
            onProgress(Int64(payload.count), Int64(payload.count))
            do {
                try payload.write(to: destination)
            } catch {
                throw LinuxGuestImageTransferError.localRejection(detail: error.localizedDescription)
            }
        }
    }

    /// Reuse/status seam over a scripted images root.
    private actor ScriptedAvailability: RuntimeV2OfficialTemplateImageAvailability {
        nonisolated let imagesRootDirectory: URL
        private var installed: Set<String>

        init(imagesRootDirectory: URL, installed: Set<String>) {
            self.imagesRootDirectory = imagesRootDirectory
            self.installed = installed
        }

        func installedImageDirectory(imageID: String) async -> URL? {
            guard installed.contains(imageID) else { return nil }
            let directory = imagesRootDirectory.appendingPathComponent(imageID, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
                return nil
            }
            return directory
        }

        func verificationFailure(imageID: String) async -> String? {
            // Absence is not a verification failure (matches the production
            // adapter): only an installed-but-damaged image reports a reason.
            installed.contains(imageID) ? nil : nil
        }

        func removeImage(imageID: String) async throws {
            installed.remove(imageID)
        }
    }

    private struct Environment {
        var service: RuntimeV2OfficialTemplateService
        var artifact: RuntimeV2OfficialTemplateArtifact
        var image: StagedImage
    }

    /// Builds the service over a scripted artifact (default `dev-document`).
    private func makeService(
        templateID: String = "dev-document",
        templateBlockVerified: Bool = true,
        templateBlockReason: String? = nil
    ) async throws -> Environment {
        let recipe = try recipeBytes(
            name: templateID, packages: ["python3": ["min_version": "3.11"], "nodejs": NSNull()]
        )
        var block: [String: Any] = [
            "id": templateID,
            "recipeSha512": FloeDigest.sha512Hex(recipe),
            "recipePath": "FloeAgent/LinuxGuest/image/templates/\(templateID).json",
            "verified": templateBlockVerified,
            "missingPackages": [],
            "belowMinimum": [],
            "pypiFailures": [],
            "packages": [
                ["name": "python3", "version": "3.13.3", "arch": "riscv64", "source": "apt", "installedKb": 100],
                ["name": "nodejs", "version": "20.19.0", "arch": "riscv64", "source": "apt", "installedKb": 200]
            ],
            "checks": ["recipe:sha512", "stage2-verify:present"]
        ]
        if let templateBlockReason { block["reason"] = templateBlockReason }
        let image = try makeLegacyImageZip(
            imageID: templateImageID, diskSeed: 0x33,
            diskLogicalBytes: 1 << 20, templateBlock: block
        )
        let archiveData = try Data(contentsOf: image.zipURL)
        let artifact = pinnedArtifact(
            templateID: templateID, imageID: templateImageID,
            archiveData: archiveData, diskDigest: image.diskDigest, recipe: recipe
        )
        let importerRoot = root.appendingPathComponent("importer-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: importerRoot, withIntermediateDirectories: true)
        let availability = ScriptedAvailability(imagesRootDirectory: importerRoot, installed: [])
        let service = RuntimeV2OfficialTemplateService(
            store: store, importer: availability,
            downloader: ScriptedDownloader(payloads: ["\(templateID).zip": archiveData]),
            artifacts: [artifact]
        )
        return Environment(service: service, artifact: artifact, image: image)
    }

    // MARK: - availability

    func testEmptyDistributionReportsDependencyMissingAndRefusesPrepare() async throws {
        let service = RuntimeV2OfficialTemplateService(
            store: store,
            importer: ScriptedAvailability(imagesRootDirectory: root, installed: []),
            downloader: ScriptedDownloader(payloads: [:]),
            artifacts: []
        )
        let statuses = try await service.availability()
        XCTAssertEqual(statuses.map(\.templateID), ["basic", "dev-document"])
        for status in statuses {
            XCTAssertEqual(status.state, .dependencyMissing)
            XCTAssertNil(status.version)
            XCTAssertNil(status.digest)
        }
        do {
            _ = try await service.prepare(templateID: "basic")
            XCTFail("preparing without a published artifact must fail")
        } catch RuntimeV2OfficialTemplateError.noPublishedArtifact(let templateID) {
            XCTAssertEqual(templateID, "basic")
        }
    }

    func testPrepareStagesSparseZipAndRegistersRealPackages() async throws {
        let environment = try await makeService()
        var statuses = try await environment.service.availability()
        let before = try XCTUnwrap(statuses.first { $0.templateID == "dev-document" })
        XCTAssertEqual(before.state, .available)
        XCTAssertEqual(before.imageID, templateImageID)

        let registration = try await environment.service.prepare(templateID: "dev-document")
        XCTAssertEqual(registration.pin.templateID, "dev-document")
        XCTAssertEqual(registration.pin.version, 1)
        XCTAssertEqual(registration.buildMode, .imported)
        XCTAssertEqual(registration.packages.count, 2)
        XCTAssertEqual(registration.packages.map(\.name).sorted(), ["nodejs", "python3"])
        XCTAssertEqual(registration.diskDigest, environment.image.diskDigest)

        // The staged disk kept its LOGICAL length while only the data blocks
        // were physically written (hole preservation).
        let expanded = try await store.images.ensureExpanded(imageID: templateImageID)
        let diskURL = expanded.appendingPathComponent("disk.img")
        let attributes = try FileManager.default.attributesOfItem(atPath: diskURL.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue ?? 0, environment.image.diskLogicalBytes)

        statuses = try await environment.service.availability()
        let after = try XCTUnwrap(statuses.first { $0.templateID == "dev-document" })
        XCTAssertEqual(after.state, .verified)
        XCTAssertEqual(after.version, 1)
        XCTAssertEqual(after.digest, registration.pin.digest)
        XCTAssertEqual(after.packageCount, 2)
        XCTAssertEqual(after.packageNames, ["nodejs", "python3"])
        XCTAssertEqual(after.qualificationRunURL, "https://github.com/JiangNanGenius/floe-agent/actions/runs/999")
        // Re-registering the same artifact is idempotent.
        let again = try await environment.service.prepare(templateID: "dev-document")
        XCTAssertEqual(again.pin, registration.pin)
    }

    func testTamperedArchiveRegistersNothingAndStaysUnavailable() async throws {
        let environment = try await makeService()
        let mutated = RuntimeV2OfficialTemplateArtifact(
            templateID: environment.artifact.templateID, version: 1,
            imageID: environment.artifact.imageID,
            archiveURL: environment.artifact.archiveURL,
            archiveSHA512: String(repeating: "0", count: 128),
            archiveBytes: environment.artifact.archiveBytes,
            diskSHA512: environment.artifact.diskSHA512,
            recipeSHA512: environment.artifact.recipeSHA512,
            recipeBase64: environment.artifact.recipeBase64,
            qualificationRunURL: environment.artifact.qualificationRunURL,
            sourceRef: environment.artifact.sourceRef
        )
        let service = RuntimeV2OfficialTemplateService(
            store: store,
            importer: ScriptedAvailability(
                imagesRootDirectory: root.appendingPathComponent("tampered-root", isDirectory: true), installed: []
            ),
            downloader: ScriptedDownloader(payloads: ["dev-document.zip": Data("tampered".utf8)]),
            artifacts: [mutated]
        )
        do {
            _ = try await service.prepare(templateID: "dev-document")
            XCTFail("a tampered archive must not register")
        } catch LinuxGuestImageInstallError.archiveDigestMismatch {
            // expected
        }
        let statuses = try await service.availability()
        XCTAssertEqual(statuses.first { $0.templateID == "dev-document" }?.state, .available)
        let versions = try await store.templates.versions(templateID: "dev-document")
        XCTAssertTrue(versions.isEmpty)
    }

    func testUnverifiedTemplateBlockIsRefused() async throws {
        let environment = try await makeService(
            templateBlockVerified: false, templateBlockReason: "stage 2 saw a package below its minimum"
        )
        do {
            _ = try await environment.service.prepare(templateID: "dev-document")
            XCTFail("an unverified guest template block must not register")
        } catch RuntimeV2OfficialTemplateError.templateBlockUnverified(let imageID, let reason) {
            XCTAssertEqual(imageID, templateImageID)
            XCTAssertTrue(reason.contains("below its minimum"))
        }
        let versions = try await store.templates.versions(templateID: "dev-document")
        XCTAssertTrue(versions.isEmpty)
    }

    // MARK: - pin reaches the production boot disk

    func testPinnedEnvironmentBootsTemplateCloneThroughProductionIntegrator() async throws {
        let environment = try await makeService()
        let registration = try await environment.service.prepare(templateID: "dev-document")
        let templateDiskDigest = registration.diskDigest

        let pin = try await integrator.registerPinnedEnvironment(
            environmentID: "env-a", name: "A", templateID: "dev-document", version: 1
        )
        XCTAssertEqual(pin, registration.pin)
        let resolvedBase = await integrator.environmentTemplateBaseImageID(environmentID: "env-a")
        XCTAssertEqual(try XCTUnwrap(resolvedBase), templateImageID)

        let diskA = try await integrator.prepareWorkingDisk(
            environmentID: "env-a", runtimeID: "rt-a", imageID: try XCTUnwrap(resolvedBase),
            legacyWritableDirectory: nil, targetCapacityBytes: 0
        )
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: diskA.diskURL), templateDiskDigest)

        // A's private work: mutate one block, stop cleanly, reboot the same
        // environment. The delta replays ONLY the private change over the
        // immutable install.
        let handle = try FileHandle(forWritingTo: diskA.diskURL)
        try handle.seek(toOffset: 3 << 20)
        try handle.write(contentsOf: Data(repeating: 0xA1, count: 4096))
        try handle.close()
        await integrator.completeStop(
            environmentID: "env-a", runtimeID: "rt-a", imageID: try XCTUnwrap(resolvedBase), clean: true
        )
        let rebooted = try await integrator.prepareWorkingDisk(
            environmentID: "env-a", runtimeID: "rt-b", imageID: try XCTUnwrap(resolvedBase),
            legacyWritableDirectory: nil, targetCapacityBytes: 0
        )
        let rebootedHandle = try FileHandle(forUpdating: rebooted.diskURL)
        try rebootedHandle.seek(toOffset: 3 << 20)
        let mutated = try rebootedHandle.read(upToCount: 4096)
        try rebootedHandle.close()
        XCTAssertEqual(mutated, Data(repeating: 0xA1, count: 4096))
        // The immutable template blob itself was never touched.
        let templateBlob = try await store.blobs.verifiedBlobURL(digest: templateDiskDigest)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: templateBlob), templateDiskDigest)
        await integrator.completeStop(
            environmentID: "env-a", runtimeID: "rt-b", imageID: try XCTUnwrap(resolvedBase), clean: true
        )
    }

    func testTwoEnvironmentsCloneTheSameInstallAndMutateIndependently() async throws {
        let environment = try await makeService()
        let registration = try await environment.service.prepare(templateID: "dev-document")
        let templateDiskDigest = registration.diskDigest
        for id in ["env-a", "env-b"] {
            _ = try await integrator.registerPinnedEnvironment(
                environmentID: id, name: id, templateID: "dev-document", version: 1
            )
        }
        let diskA = try await integrator.prepareWorkingDisk(
            environmentID: "env-a", runtimeID: "rt-a", imageID: templateImageID,
            legacyWritableDirectory: nil, targetCapacityBytes: 0
        )
        let diskB = try await integrator.prepareWorkingDisk(
            environmentID: "env-b", runtimeID: "rt-b", imageID: templateImageID,
            legacyWritableDirectory: nil, targetCapacityBytes: 0
        )
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: diskA.diskURL), templateDiskDigest)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: diskB.diskURL), templateDiskDigest)

        // A mutates; B must still be the pristine install.
        let handle = try FileHandle(forWritingTo: diskA.diskURL)
        try handle.seek(toOffset: 5 << 20)
        try handle.write(contentsOf: Data(repeating: 0xB2, count: 4096))
        try handle.close()
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: diskB.diskURL), templateDiskDigest)

        await integrator.completeStop(
            environmentID: "env-a", runtimeID: "rt-a", imageID: templateImageID, clean: true
        )
        // B keeps its own pristine clone and can be stopped independently.
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: diskB.diskURL), templateDiskDigest)
        await integrator.completeStop(
            environmentID: "env-b", runtimeID: "rt-b", imageID: templateImageID, clean: true
        )
    }

    func testUnpinnedEnvironmentStaysOnItsBaseImage() async throws {
        // A plain base image and a separate template image.
        let base = try makeLegacyImageZip(imageID: baseImageID, diskSeed: 0x11)
        let baseLegacyRoot = root.appendingPathComponent("base-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseLegacyRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: base.directory, to: baseLegacyRoot.appendingPathComponent(baseImageID, isDirectory: true)
        )
        _ = try await store.images.migrateLegacyImage(
            imageID: baseImageID, legacyImagesRoot: baseLegacyRoot
        )
        let environment = try await makeService()
        _ = try await environment.service.prepare(templateID: "dev-document")

        let now = Date()
        try await store.registry.upsertEnvironment(RuntimeV2Registry.EnvironmentRow(
            id: "env-existing", kind: "linuxVM", ownerID: nil, name: "existing",
            baseImageID: baseImageID, baseRootfsDigest: base.diskDigest.lowercased(),
            state: "stopped", dataPath: "environments/env-existing/data",
            compatHostFHS: false, repairReason: nil, createdAt: now, lastUsedAt: now
        ))
        let disk = try await integrator.prepareWorkingDisk(
            environmentID: "env-existing", runtimeID: "rt-existing", imageID: baseImageID,
            legacyWritableDirectory: nil, targetCapacityBytes: 0
        )
        // The existing (unpinned) environment boots its own base image even
        // though a template is registered.
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: disk.diskURL), base.diskDigest)
        let pin = await integrator.environmentTemplatePin(environmentID: "env-existing")
        XCTAssertNil(pin)
        await integrator.completeStop(
            environmentID: "env-existing", runtimeID: "rt-existing", imageID: baseImageID, clean: true
        )
    }

    func testRegisterPinnedEnvironmentRefusesForeignBaseImage() async throws {
        let base = try makeLegacyImageZip(imageID: baseImageID, diskSeed: 0x22)
        let baseLegacyRoot = root.appendingPathComponent("base-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseLegacyRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: base.directory, to: baseLegacyRoot.appendingPathComponent(baseImageID, isDirectory: true)
        )
        _ = try await store.images.migrateLegacyImage(
            imageID: baseImageID, legacyImagesRoot: baseLegacyRoot
        )
        let environment = try await makeService()
        _ = try await environment.service.prepare(templateID: "dev-document")
        let now = Date()
        try await store.registry.upsertEnvironment(RuntimeV2Registry.EnvironmentRow(
            id: "env-foreign", kind: "linuxVM", ownerID: nil, name: "foreign",
            baseImageID: baseImageID, baseRootfsDigest: base.diskDigest.lowercased(),
            state: "stopped", dataPath: "environments/env-foreign/data",
            compatHostFHS: false, repairReason: nil, createdAt: now, lastUsedAt: now
        ))
        do {
            _ = try await integrator.registerPinnedEnvironment(
                environmentID: "env-foreign", name: "foreign", templateID: "dev-document", version: 1
            )
            XCTFail("a row on another base image must not be pinned")
        } catch RuntimeV2Error.templateBaseImageMismatch {
            // expected
        }
        let pin = await integrator.environmentTemplatePin(environmentID: "env-foreign")
        XCTAssertNil(pin)
    }
}
