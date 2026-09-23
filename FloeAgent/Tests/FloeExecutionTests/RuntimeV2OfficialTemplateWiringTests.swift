// FloeExecutionTests — C5 official template distribution → environment pin.
//
// These tests drive the REAL Runtime v2 substrate (SQLite registry,
// content-addressed blob store, block deltas, production integrator) with a
// scripted archive downloader and a scripted verified-image importer. They
// pin the contracts that make the official-template flow honest:
//
//   - only a cloud-pinned artifact whose archive digest, image manifest
//     template block, recipe digest and disk digest all match can be
//     registered; a tampered archive, an unverified guest block or a recipe
//     mismatch registers nothing and leaves the option unavailable;
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

    /// Writes one qualified legacy image (bios + disk + manifest) under its
    /// own legacy root and returns the directory plus the disk digest.
    /// `templateBlock` is injected at the JSON level exactly like the image
    /// build writes it.
    private func writeLegacyImage(
        imageID: String, diskSeed: UInt8, diskBytes: Int = 2 << 20,
        templateBlock: [String: Any]? = nil
    ) throws -> (directory: URL, legacyRoot: URL, diskDigest: String) {
        let legacyRoot = root.appendingPathComponent("legacy-\(imageID)-\(UUID().uuidString)", isDirectory: true)
        let directory = legacyRoot.appendingPathComponent(imageID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bios = Data(count: 4096)
        for index in bios.indices { bios[index] = UInt8((index &* 7) % 251) }
        var disk = Data(count: diskBytes)
        for index in disk.indices { disk[index] = UInt8((index &* Int(diskSeed)) % 253) }
        try bios.write(to: directory.appendingPathComponent("bios.bin"))
        try disk.write(to: directory.appendingPathComponent("disk.img"))
        let diskDigest = FloeDigest.sha512Hex(disk)
        var manifest: [String: Any] = [
            "id": imageID,
            "biosPath": "bios.bin",
            "diskPath": "disk.img",
            "diskReadWrite": true,
            "qualified": true,
            "qualificationRun": "https://github.com/JiangNanGenius/floe-agent/actions/runs/999",
            "artifacts": [
                ["role": "bios", "path": "bios.bin", "sha512": FloeDigest.sha512Hex(bios), "bytes": bios.count],
                ["role": "disk", "path": "disk.img", "sha512": diskDigest, "bytes": disk.count]
            ]
        ]
        if let templateBlock { manifest["template"] = templateBlock }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        return (directory, legacyRoot, diskDigest)
    }

    private func recipeBytes(name: String, packages: [String: Any]) throws -> Data {
        let object: [String: Any] = [
            "schema": 1, "name": name,
            "description": "test recipe", "packages": packages
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func pinnedArtifact(
        templateID: String, imageID: String, archiveBytes: Data, diskDigest: String,
        recipe: Data, qualifications: String = "https://github.com/JiangNanGenius/floe-agent/actions/runs/999"
    ) -> RuntimeV2OfficialTemplateArtifact {
        RuntimeV2OfficialTemplateArtifact(
            templateID: templateID, version: 1, imageID: imageID,
            archiveURL: "https://example.invalid/\(templateID).zip",
            archiveSHA512: FloeDigest.sha512Hex(archiveBytes),
            archiveBytes: Int64(archiveBytes.count),
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

    /// Verified-image importer seam over a scripted legacy root. When not
    /// installed it copies the scripted source image into the images root,
    /// exactly like the real importer materializes a verified image, so the
    /// download → import → register path is exercised end to end.
    private actor ScriptedImporter: RuntimeV2OfficialTemplateImageImporting {
        nonisolated let imagesRootDirectory: URL
        private let sourceDirectory: URL
        private let imageID: String
        private var installed: Bool

        init(imagesRootDirectory: URL, sourceDirectory: URL, imageID: String, installed: Bool) {
            self.imagesRootDirectory = imagesRootDirectory
            self.sourceDirectory = sourceDirectory
            self.imageID = imageID
            self.installed = installed
        }

        func installedImageDirectory(imageID: String) async -> URL? {
            guard installed, imageID == self.imageID else { return nil }
            let directory = imagesRootDirectory.appendingPathComponent(imageID, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
                return nil
            }
            return directory
        }

        func verificationFailure(imageID: String) async -> String? {
            installed && imageID == self.imageID ? nil : nil
        }

        func removeImage(imageID: String) async throws {
            installed = false
        }

        func importArchive(at archiveURL: URL, expectedSHA512: String) async throws -> LinuxGuestImage {
            let payload = try Data(contentsOf: archiveURL)
            guard FloeDigest.sha512Hex(payload) == expectedSHA512.lowercased() else {
                throw LinuxGuestImageInstallError.archiveDigestMismatch(
                    expected: expectedSHA512, actual: "scripted mismatch"
                )
            }
            let destination = imagesRootDirectory.appendingPathComponent(imageID, isDirectory: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: imagesRootDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceDirectory, to: destination)
            installed = true
            let data = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let image = try? decoder.decode(LinuxGuestImage.self, from: data) else {
                throw LinuxGuestImageInstallError.manifestMissing(destination.path)
            }
            return image
        }
    }

    private struct Environment {
        var service: RuntimeV2OfficialTemplateService
        var artifact: RuntimeV2OfficialTemplateArtifact
        var importer: ScriptedImporter
        var legacyRoot: URL
    }

    /// Builds the service over a scripted artifact (default `dev-document`).
    private func makeService(
        templateID: String = "dev-document",
        templateBlockVerified: Bool = true,
        templateBlockReason: String? = nil,
        imageInstalled: Bool = true
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
        let generated = try writeLegacyImage(
            imageID: templateImageID, diskSeed: 0x33, templateBlock: block
        )
        let archivePayload = Data("archive-\(templateID)".utf8)
        let artifact = pinnedArtifact(
            templateID: templateID, imageID: templateImageID,
            archiveBytes: archivePayload, diskDigest: generated.diskDigest, recipe: recipe
        )
        let importerRoot = root.appendingPathComponent("importer-images-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: importerRoot, withIntermediateDirectories: true)
        if imageInstalled {
            try FileManager.default.copyItem(
                at: generated.directory,
                to: importerRoot.appendingPathComponent(templateImageID, isDirectory: true)
            )
        }
        let importer = ScriptedImporter(
            imagesRootDirectory: importerRoot,
            sourceDirectory: generated.directory,
            imageID: templateImageID,
            installed: imageInstalled
        )
        let service = RuntimeV2OfficialTemplateService(
            store: store, importer: importer,
            downloader: ScriptedDownloader(payloads: ["\(templateID).zip": archivePayload]),
            artifacts: [artifact]
        )
        return Environment(
            service: service, artifact: artifact, importer: importer, legacyRoot: generated.legacyRoot
        )
    }

    // MARK: - availability

    func testEmptyDistributionReportsDependencyMissingAndRefusesPrepare() async throws {
        let service = RuntimeV2OfficialTemplateService(
            store: store,
            importer: ScriptedImporter(
                imagesRootDirectory: root, sourceDirectory: root,
                imageID: "none", installed: false
            ),
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

    func testPrepareRegistersPinnedArtifactAndAvailabilityListsRealPackages() async throws {
        let environment = try await makeService(imageInstalled: false)
        var statuses = try await environment.service.availability()
        let before = try XCTUnwrap(statuses.first { $0.templateID == "dev-document" })
        XCTAssertEqual(before.state, .available)
        XCTAssertEqual(before.imageID, templateImageID)

        // Download → verify → import → migrate → register.
        let registration = try await environment.service.prepare(templateID: "dev-document")
        XCTAssertEqual(registration.pin.templateID, "dev-document")
        XCTAssertEqual(registration.pin.version, 1)
        XCTAssertEqual(registration.buildMode, .imported)
        XCTAssertEqual(registration.packages.count, 2)
        XCTAssertEqual(registration.packages.map(\.name).sorted(), ["nodejs", "python3"])

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
        let environment = try await makeService(imageInstalled: false)
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
            store: store, importer: environment.importer,
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
        let environment = try await makeService(imageInstalled: false)
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
        let environment = try await makeService(imageInstalled: false)
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
        let base = try writeLegacyImage(imageID: baseImageID, diskSeed: 0x11)
        _ = try await store.images.migrateLegacyImage(
            imageID: baseImageID, legacyImagesRoot: base.legacyRoot
        )
        let environment = try await makeService(imageInstalled: false)
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
        let base = try writeLegacyImage(imageID: baseImageID, diskSeed: 0x22)
        _ = try await store.images.migrateLegacyImage(
            imageID: baseImageID, legacyImagesRoot: base.legacyRoot
        )
        let environment = try await makeService(imageInstalled: false)
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
