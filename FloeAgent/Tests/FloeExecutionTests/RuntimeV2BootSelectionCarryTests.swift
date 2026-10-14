// FloeExecutionTests — a Runtime v2 expanded-view rebuild must preserve the
// boot-asset selection (user state), never treat it as rebuildable cache.
//
// The expanded view is derived bytes; the updater's sidecar (an adopted pair,
// an explicit rollback record or a failure record) and the immutable payload
// it names are not. Dropping them silently reverts the boot to the manifest
// default pair, loses an explicit rollback, and re-opens it to automatic
// adoption. These tests drive the REAL `RuntimeV2ImageStore` over a synthetic
// v2 image installed through the production migration path:
//
//  * an adopted selection and its payload survive re-materialization through
//    both public rebuild APIs (`reconstructExpandedImage(force:)` and
//    `ensureExpanded`, the latter entered only after the view is made
//    incomplete);
//  * a rolledBack marker whose payload is gone survives, still resolves the
//    manifest default pair, and still refuses automatic adoption;
//  * a malformed sidecar and a failed payload copy abort the rebuild BEFORE
//    the old expanded tree is moved aside or removed (old bytes intact, no
//    staging left, no quarantine entry) — never a false materialization
//    success;
//  * a source with no sidecar at all still rebuilds normally.
//
// Host FileManager only: every root is created under the system temporary
// directory and removed by this test class.

import Foundation
import XCTest
import Darwin
import FloeCore
@testable import FloeExecution

private struct BootSelectionFixture {
    let legacy: RuntimeImageFixture
    let layout: RuntimeV2Layout
    let store: RuntimeV2Store
    let expanded: URL
    let imageID: String
}

final class RuntimeV2BootSelectionCarryTests: XCTestCase {
    private var ownedRoots: [URL] = []

    override func tearDown() async throws {
        for root in ownedRoots {
            try? FileManager.default.removeItem(at: root)
        }
        ownedRoots = []
    }

    // MARK: - fixtures

    /// A verified Runtime v2 image created by the production legacy migration,
    /// exactly like the App's first install.
    private func makeV2Image(_ name: String) async throws -> BootSelectionFixture {
        let legacy = try makeRuntimeImageFixture(name: name)
        ownedRoots.append(legacy.root)
        let v2Root = try makeTemporaryDirectory("v2-boot-selection-\(name)")
        ownedRoots.append(v2Root)
        let layout = RuntimeV2Layout(root: v2Root)
        let store = RuntimeV2Store(layout: layout)
        // Same contract every Runtime v2 caller honors: open the registry
        // (and run the recovery pass) before any image operation.
        _ = try await store.prepareAndRecover(build: "test")
        _ = try await store.images.migrateLegacyImage(imageID: legacy.id, legacyImagesRoot: legacy.root)
        return BootSelectionFixture(
            legacy: legacy,
            layout: layout,
            store: store,
            expanded: try layout.expandedImageDirectory(imageID: legacy.id),
            imageID: legacy.id
        )
    }

    private func makePair(
        version: String,
        firmware: Data = Data("firmware-\(UUID().uuidString)".utf8),
        kernel: Data = Data("kernel-\(UUID().uuidString)".utf8)
    ) -> LinuxGuestBootAssetPair {
        LinuxGuestBootAssetPair(
            label: "linux-\(version)-opensbi-1.9",
            version: version,
            firmwareFileName: "opensbi_fw_jump.bin",
            kernelFileName: "kernel-\(version)-riscv64.bin",
            firmwareSHA256: FloeDigest.sha256Hex(firmware),
            kernelSHA256: FloeDigest.sha256Hex(kernel),
            firmwareBytes: Int64(firmware.count),
            kernelBytes: Int64(kernel.count)
        )
    }

    /// Writes the updater's real sidecar — and, when a payload is given, the
    /// immutable storage directory it names — into the expanded image
    /// directory, exactly where the boot reads them.
    @discardableResult
    private func writeSelection(
        into fixture: BootSelectionFixture,
        state: LinuxGuestBootAssetSidecar.State,
        pair: LinuxGuestBootAssetPair,
        firmware: Data? = nil,
        kernel: Data? = nil,
        storageDirectory: String? = nil
    ) throws -> LinuxGuestBootAssetSidecar {
        let relative = storageDirectory ?? LinuxGuestBootAssetUpdateService.storageDirectoryName(for: pair)
        if let firmware, let kernel {
            let storage = fixture.expanded.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try firmware.write(to: storage.appendingPathComponent(pair.firmwareFileName))
            try kernel.write(to: storage.appendingPathComponent(pair.kernelFileName))
        }
        let sidecar = LinuxGuestBootAssetSidecar(
            state: state,
            pair: pair,
            storageDirectory: relative,
            defaultBiosPath: fixture.legacy.manifest.biosPath,
            defaultKernelPath: fixture.legacy.manifest.kernelPath,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try LinuxGuestBootAssetUpdateService.saveSidecar(sidecar, imageDirectory: fixture.expanded)
        return sidecar
    }

    private func makeUpdater(
        for fixture: BootSelectionFixture,
        bundleDirectory: URL? = nil
    ) -> LinuxGuestBootAssetUpdateService {
        let expanded = fixture.expanded
        return LinuxGuestBootAssetUpdateService(
            imagesRoot: fixture.legacy.root,
            bundleProvider: { bundleDirectory },
            quietProbe: nil,
            imageDirectoryResolver: { _ in expanded }
        )
    }

    private func writeBundle(
        root: URL, pair: LinuxGuestBootAssetPair, firmware: Data, kernel: Data
    ) throws -> URL {
        let directory = root.appendingPathComponent("bundle-\(pair.version)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundle = LinuxGuestBootAssetBundle(pair: pair, sourceReferences: ["test"], licenses: ["GPL-2.0"])
        try firmware.write(to: directory.appendingPathComponent(pair.firmwareFileName))
        try kernel.write(to: directory.appendingPathComponent(pair.kernelFileName))
        try JSONEncoder().encode(bundle).write(to: directory.appendingPathComponent("boot-pair-v2.manifest.json"))
        return directory
    }

    // MARK: - observations

    private func directoryEntries(_ directory: URL, prefix: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    /// Deterministic fingerprint of an expanded tree: every entry's relative
    /// path, size, permission bits and (when readable) content hash.
    /// Unreadable entries are fingerprinted by metadata so an injected
    /// permission fault cannot hide a mutation.
    private func treeFingerprint(_ root: URL) throws -> String {
        let fileManager = FileManager.default
        var lines: [String] = []
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return "" }
        for case let url as URL in enumerator {
            let relative = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.path
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                lines.append("d \(relative)")
                continue
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? Int64) ?? -1
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let content = (try? Data(contentsOf: url)).map { FloeDigest.sha256Hex($0) } ?? "unreadable"
            lines.append("f \(relative) \(size) \(mode) \(content)")
        }
        return lines.sorted().joined(separator: "\n")
    }

    // MARK: - adopted selection

    func testReconstructAndEnsureExpandedCarryTheAdoptedSelection() async throws {
        let fixture = try await makeV2Image("adopted-selection")
        let firmware = Data("opensbi-adopted".utf8)
        let kernel = Data("kernel-adopted".utf8)
        let pair = makePair(version: "6.18.56", firmware: firmware, kernel: kernel)
        let sidecar = try writeSelection(
            into: fixture, state: .adopted, pair: pair, firmware: firmware, kernel: kernel
        )
        let sentinel = fixture.expanded.appendingPathComponent(".carry-sentinel")
        try Data("old-view".utf8).write(to: sentinel)

        // API path 1: an explicit rebuild must carry the selection.
        _ = try await fixture.store.images.reconstructExpandedImage(imageID: fixture.imageID, force: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sentinel.path),
            "force rebuild did not replace the expanded view"
        )
        let carried = try LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.expanded)
        XCTAssertEqual(carried, sidecar, "the adopted selection must survive a rebuild")
        let storage = fixture.expanded.appendingPathComponent(sidecar.storageDirectory, isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: storage.appendingPathComponent(pair.firmwareFileName)), firmware)
        XCTAssertEqual(try Data(contentsOf: storage.appendingPathComponent(pair.kernelFileName)), kernel)

        // The boot path resolves the adopted pair from the rebuilt view.
        let updater = makeUpdater(for: fixture)
        let state = await updater.state(imageID: fixture.imageID)
        XCTAssertEqual(state, .updateInstalled(sidecar))
        let resolved = LinuxGuestBootAssetUpdateService.resolvedBootPaths(
            manifest: fixture.legacy.manifest, imageDirectory: fixture.expanded
        )
        XCTAssertEqual(resolved.biosPath, storage.appendingPathComponent(pair.firmwareFileName).path)
        XCTAssertEqual(resolved.kernelPath, storage.appendingPathComponent(pair.kernelFileName).path)

        // API path 2: an incomplete view re-materializes through ensureExpanded
        // (which removes the old tree rather than moving it aside) — the
        // selection must be carried again.
        let biosArtifact = fixture.expanded.appendingPathComponent(fixture.legacy.manifest.biosPath)
        try FileManager.default.removeItem(at: biosArtifact)
        _ = try await fixture.store.images.ensureExpanded(imageID: fixture.imageID)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: biosArtifact.path),
            "ensureExpanded must restore a complete view"
        )
        XCTAssertEqual(
            try LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.expanded),
            sidecar
        )
        XCTAssertEqual(try Data(contentsOf: storage.appendingPathComponent(pair.kernelFileName)), kernel)
        XCTAssertEqual(
            LinuxGuestBootAssetUpdateService.resolvedBootPaths(
                manifest: fixture.legacy.manifest, imageDirectory: fixture.expanded
            ).biosPath,
            storage.appendingPathComponent(pair.firmwareFileName).path
        )
    }

    func testRebuildWithoutAnySelectionStillSucceeds() async throws {
        let fixture = try await makeV2Image("no-selection")
        _ = try await fixture.store.images.reconstructExpandedImage(imageID: fixture.imageID, force: true)
        XCTAssertNil(
            try LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.expanded),
            "no sidecar was expected for a source with no selection"
        )
        XCTAssertEqual(
            LinuxGuestBootAssetUpdateService.resolvedBootPaths(
                manifest: fixture.legacy.manifest, imageDirectory: fixture.expanded
            ).biosPath,
            fixture.legacy.manifest.biosPath
        )
    }

    // MARK: - explicit rollback record

    func testRolledBackMarkerSurvivesMissingPayloadAndKeepsBlockingAutoAdoption() async throws {
        let fixture = try await makeV2Image("rolled-back-marker")
        // The record of an explicit rollback whose payload is gone: the record
        // itself is the user's choice and must survive the rebuild.
        let rolledBackPair = makePair(version: "6.12.112")
        let sidecar = try writeSelection(
            into: fixture, state: .rolledBack, pair: rolledBackPair,
            storageDirectory: LinuxGuestBootAssetUpdateService.storageDirectoryName(for: rolledBackPair)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.expanded.appendingPathComponent(sidecar.storageDirectory).path
            ),
            "the rolled-back payload is deliberately absent"
        )

        _ = try await fixture.store.images.reconstructExpandedImage(imageID: fixture.imageID, force: true)
        XCTAssertEqual(
            try LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.expanded),
            sidecar,
            "the explicit rollback record must survive re-materialization"
        )
        XCTAssertEqual(
            LinuxGuestBootAssetUpdateService.resolvedBootPaths(
                manifest: fixture.legacy.manifest, imageDirectory: fixture.expanded
            ).biosPath,
            fixture.legacy.manifest.biosPath,
            "a rolled-back image must keep resolving the manifest default pair"
        )
        let updater = makeUpdater(for: fixture)
        let state = await updater.state(imageID: fixture.imageID)
        XCTAssertEqual(state, .rolledBack(sidecar))

        // Automatic adoption of the newer bundled pair stays refused.
        let newerFirmware = Data("opensbi-newer".utf8)
        let newerKernel = Data("kernel-newer".utf8)
        let newer = makePair(version: "6.18.56", firmware: newerFirmware, kernel: newerKernel)
        let bundleDirectory = try writeBundle(
            root: fixture.legacy.root, pair: newer, firmware: newerFirmware, kernel: newerKernel
        )
        let automatic = makeUpdater(for: fixture, bundleDirectory: bundleDirectory)
        do {
            _ = try await automatic.installUpdate(
                imageID: fixture.imageID, environmentIDs: { _ in [String]() }, origin: .automatic
            )
            XCTFail("automatic adoption overrode the explicit rollback marker")
        } catch let error as LinuxGuestBootAssetUpdateError {
            guard case .notOffered = error else { return XCTFail("expected notOffered, got \(error)") }
        }
        // The refusal touched nothing.
        XCTAssertEqual(
            try LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.expanded),
            sidecar
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.expanded
                    .appendingPathComponent(LinuxGuestBootAssetUpdateService.storageDirectoryName(for: newer))
                    .path
            )
        )
    }

    // MARK: - corrupt / failed preservation must not destroy the old state

    func testMalformedSidecarAbortsRebuildAndKeepsTheOldExpandedTree() async throws {
        let fixture = try await makeV2Image("malformed-sidecar")
        let sidecarURL = LinuxGuestBootAssetUpdateService.sidecarURL(imageDirectory: fixture.expanded)
        let malformed = Data("not json at all".utf8)
        try malformed.write(to: sidecarURL)
        let sentinel = fixture.expanded.appendingPathComponent(".carry-sentinel")
        try Data("old-view".utf8).write(to: sentinel)
        let before = try treeFingerprint(fixture.expanded)

        do {
            _ = try await fixture.store.images.reconstructExpandedImage(imageID: fixture.imageID, force: true)
            XCTFail("a malformed sidecar must fail the rebuild, not silently drop the record")
        } catch let error as LinuxGuestBootAssetUpdateError {
            guard case .ioFailure = error else { return XCTFail("expected ioFailure, got \(error)") }
        } catch let error {
            return XCTFail("expected a typed boot-asset failure, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.expanded.path))
        XCTAssertEqual(
            try treeFingerprint(fixture.expanded), before,
            "the old expanded tree must be byte-identical after a failed rebuild"
        )
        XCTAssertEqual(try Data(contentsOf: sidecarURL), malformed)
        XCTAssertEqual(
            try directoryEntries(fixture.layout.quarantineDirectory, prefix: "expanded-\(fixture.imageID)-"),
            [],
            "the old view must not have been moved aside"
        )
        XCTAssertEqual(
            try directoryEntries(fixture.layout.expandedImagesDirectory, prefix: ".staging-"), [],
            "staging must be cleaned up"
        )
    }

    func testEscapingStoragePathCarriesTheRecordButNeverThePayload() async throws {
        let fixture = try await makeV2Image("escaping-path")
        let pair = makePair(version: "6.18.56")
        // Hostile/corrupt record: the path must never be followed out of the
        // image directory, and the only thing that may be carried is the
        // record itself (the boot then fails closed to the manifest pair).
        let sidecar = try writeSelection(
            into: fixture, state: .adopted, pair: pair,
            storageDirectory: "../escaped-payload"
        )
        let escaped = fixture.layout.expandedImagesDirectory.appendingPathComponent("escaped-payload")

        _ = try await fixture.store.images.reconstructExpandedImage(imageID: fixture.imageID, force: true)

        XCTAssertEqual(
            try LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.expanded),
            sidecar
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: escaped.path),
            "an escaping storage path must never be materialized outside the image directory"
        )
        XCTAssertEqual(
            LinuxGuestBootAssetUpdateService.resolvedBootPaths(
                manifest: fixture.legacy.manifest, imageDirectory: fixture.expanded
            ).biosPath,
            fixture.legacy.manifest.biosPath,
            "an unverifiable adopted record must fail closed to the manifest pair"
        )
    }

    func testFailedRequiredCopyAbortsEnsureExpandedBeforeTheOldViewIsRemoved() async throws {
        let fixture = try await makeV2Image("copy-failure")
        // Root can read a mode-000 payload, so the injected fault needs a
        // non-root test process (the normal runner).
        try XCTSkipIf(geteuid() == 0, "a mode-000 payload is readable by root")

        let firmware = Data("opensbi-copy-failure".utf8)
        let kernel = Data("kernel-copy-failure".utf8)
        let pair = makePair(version: "6.18.56", firmware: firmware, kernel: kernel)
        let sidecar = try writeSelection(
            into: fixture, state: .adopted, pair: pair, firmware: firmware, kernel: kernel
        )
        let storage = fixture.expanded.appendingPathComponent(sidecar.storageDirectory, isDirectory: true)
        let kernelFile = storage.appendingPathComponent(pair.kernelFileName)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: kernelFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kernelFile.path)
        }
        let sentinel = fixture.expanded.appendingPathComponent(".carry-sentinel")
        try Data("old-view".utf8).write(to: sentinel)
        // An incomplete view is the state that takes ensureExpanded down the
        // rebuild path (which REMOVES the old tree after a successful carry).
        let biosArtifact = fixture.expanded.appendingPathComponent(fixture.legacy.manifest.biosPath)
        try FileManager.default.removeItem(at: biosArtifact)
        let before = try treeFingerprint(fixture.expanded)

        do {
            _ = try await fixture.store.images.ensureExpanded(imageID: fixture.imageID)
            XCTFail("a failed required copy must fail the rebuild")
        } catch let error as LinuxGuestBootAssetUpdateError {
            guard case .ioFailure = error else { return XCTFail("expected ioFailure, got \(error)") }
        } catch let error {
            return XCTFail("expected a typed boot-asset failure, got \(error)")
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.expanded.path),
            "a failed carry must abort before the old expanded tree is removed"
        )
        XCTAssertEqual(
            try treeFingerprint(fixture.expanded), before,
            "the old expanded bytes and selection must be untouched"
        )
        XCTAssertEqual(
            try LinuxGuestBootAssetUpdateService.loadSidecar(imageDirectory: fixture.expanded),
            sidecar
        )
        XCTAssertEqual(
            try directoryEntries(fixture.layout.expandedImagesDirectory, prefix: ".staging-"), [],
            "staging must be cleaned up"
        )
    }
}
