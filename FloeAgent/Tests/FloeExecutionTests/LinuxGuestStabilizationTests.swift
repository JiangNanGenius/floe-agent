// FloeExecutionTests — Linux stabilization: disk migration, authoritative
// install state, ext4 resize parsing, download coalescing, temp/cache paths.
//
// No network, no guest VM: disk preparation uses real files under a
// temporary directory and an APFS clone where the volume supports it.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - Grow-only 8 GiB disk migration

final class LinuxGuestDiskMigrationTests: XCTestCase {
    private let targetCapacity: Int64 = 8 * 1024 * 1024 * 1024

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBaseImage(root: URL, id: String = "floe-disk-migration", diskBytes: Data) throws -> RuntimeImageFixture {
        try makeRuntimeImageFixture(name: "migration-\(UUID().uuidString)", id: id, diskBytes: diskBytes)
    }

    func testNewDiskIsGrownSparselyToTargetCapacity() throws {
        let fixture = try makeRuntimeImageFixture(name: "new-grow")
        let writable = try makeTemporaryDirectory("layer-new-grow")
        let preparer = LinuxGuestRuntimeImagePreparer()
        let runtime = try preparer.prepare(
            image: fixture.manifest,
            imageDirectory: fixture.imageDirectory,
            environmentID: "env-grow",
            writableDirectory: writable,
            targetCapacityBytes: targetCapacity
        )
        let disk = try XCTUnwrap(runtime.diskPath)
        let size = try URL(fileURLWithPath: disk).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        XCTAssertEqual(Int64(size), targetCapacity, "the raw container must be exactly the target logical size")
        // The base content remains byte-identical at the start (holes after it).
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: disk))
        let head = handle.readData(ofLength: fixture.diskBytes.count)
        try handle.close()
        XCTAssertEqual(head, fixture.diskBytes)
        let origin = try XCTUnwrap(LinuxGuestRuntimeImagePreparer.diskOrigin(
            writableDirectory: writable, environmentID: "env-grow"))
        XCTAssertEqual(origin.version, 2)
        XCTAssertEqual(origin.logicalCapacityBytes, targetCapacity)
        XCTAssertNil(origin.migratedFromCapacityBytes, "a fresh disk carries no migration provenance")
    }

    func testExistingV1DiskIsGrownInPlaceAndKeepsItsData() throws {
        // Establish an environment disk at the compact base size using a
        // small target (this is what a v1-era install looked like).
        let fixture = try makeRuntimeImageFixture(name: "v1-then-grow")
        let writable = try makeTemporaryDirectory("layer-v1")
        let preparer = LinuxGuestRuntimeImagePreparer()
        let small: Int64 = 1024 * 1024
        _ = try preparer.prepare(
            image: fixture.manifest,
            imageDirectory: fixture.imageDirectory,
            environmentID: "env-v1",
            writableDirectory: writable,
            targetCapacityBytes: small
        )
        let disk = runtimeDiskDirectory(writable: writable, environmentID: "env-v1")
            .appendingPathComponent(LinuxGuestRuntimeImagePreparer.diskFileName)
        // Simulate guest package writes past the base content.
        let marker = Data("user-workspace-and-packages".utf8)
        let handle = try FileHandle(forWritingTo: disk)
        handle.seekToEndOfFile()
        handle.write(marker)
        try handle.close()
        // Downgrade the sidecar to schema v1 (no capacity record).
        let originURL = runtimeDiskDirectory(writable: writable, environmentID: "env-v1")
            .appendingPathComponent(LinuxGuestRuntimeImagePreparer.originFileName)
        let v1 = """
        {"version":1,"imageID":"\(fixture.id)","artifactSHA512":"\(fixture.diskDigest)","artifactBytes":\(fixture.diskBytes.count),"createdAt":"2026-09-01T00:00:00Z"}
        """
        try v1.data(using: .utf8)!.write(to: originURL)

        // Second preparation with the production target migrates in place.
        let runtime = try preparer.prepare(
            image: fixture.manifest,
            imageDirectory: fixture.imageDirectory,
            environmentID: "env-v1",
            writableDirectory: writable,
            targetCapacityBytes: targetCapacity
        )
        XCTAssertEqual(runtime.diskPath, disk.path, "migration must never replace the disk file")
        let size = try disk.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        XCTAssertEqual(Int64(size), targetCapacity)
        let migrated = try Data(contentsOf: disk)
        // Original base and appended user state both survive the grow.
        XCTAssertEqual(migrated.prefix(fixture.diskBytes.count), Data(fixture.diskBytes))
        XCTAssertTrue(migrated.range(of: marker) != nil, "guest packages/workspace must survive migration")
        let origin = try XCTUnwrap(LinuxGuestRuntimeImagePreparer.diskOrigin(
            writableDirectory: writable, environmentID: "env-v1"))
        XCTAssertEqual(origin.version, 2)
        XCTAssertEqual(origin.logicalCapacityBytes, targetCapacity)
        // A v1 sidecar records no capacity, so the provenance records the
        // physical size at migration (base + the appended guest marker).
        XCTAssertEqual(origin.migratedFromCapacityBytes, small + Int64(marker.count))
        XCTAssertNotNil(origin.migratedAt)
    }

    func testGrowthIsGrowOnlyAndIdempotent() throws {
        let fixture = try makeRuntimeImageFixture(name: "grow-idempotent")
        let writable = try makeTemporaryDirectory("layer-idempotent")
        let preparer = LinuxGuestRuntimeImagePreparer()
        let first = try preparer.prepare(
            image: fixture.manifest, imageDirectory: fixture.imageDirectory,
            environmentID: "e", writableDirectory: writable, targetCapacityBytes: 2 * 1024 * 1024)
        let firstInode = try FileManager.default.attributesOfItem(atPath: first.diskPath!)[.systemFileNumber] as? Int
        _ = try preparer.prepare(
            image: fixture.manifest, imageDirectory: fixture.imageDirectory,
            environmentID: "e", writableDirectory: writable, targetCapacityBytes: 2 * 1024 * 1024)
        // Asking for a smaller capacity must not shrink the disk.
        let runtime = try preparer.prepare(
            image: fixture.manifest, imageDirectory: fixture.imageDirectory,
            environmentID: "e", writableDirectory: writable, targetCapacityBytes: 1024 * 1024)
        let size = try URL(fileURLWithPath: runtime.diskPath!).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        XCTAssertEqual(Int64(size), 2 * 1024 * 1024, "a disk is never shrunk")
        let inode = try FileManager.default.attributesOfItem(atPath: runtime.diskPath!)[.systemFileNumber] as? Int
        XCTAssertEqual(inode, firstInode, "reuse must keep the same file")
    }

    func testUnrelatedOriginStillConflictsAndPreservesData() throws {
        let fixture = try makeRuntimeImageFixture(name: "migrate-conflict")
        let writable = try makeTemporaryDirectory("layer-migrate-conflict")
        let preparer = LinuxGuestRuntimeImagePreparer()
        _ = try preparer.prepare(
            image: fixture.manifest, imageDirectory: fixture.imageDirectory,
            environmentID: "e", writableDirectory: writable, targetCapacityBytes: 1024 * 1024)
        let disk = runtimeDiskDirectory(writable: writable, environmentID: "e")
            .appendingPathComponent(LinuxGuestRuntimeImagePreparer.diskFileName)
        let marker = Data("never-overwritten".utf8)
        let h = try FileHandle(forWritingTo: disk); h.seekToEndOfFile(); h.write(marker); try h.close()
        // New base bytes under the same id with no compatible origin.
        let updated = Data(repeating: 0xC3, count: 16 * 1024)
        try updated.write(to: fixture.diskURL)
        var manifest = fixture.manifest
        manifest.artifacts = manifest.artifacts?.map {
            guard $0.role == .disk else { return $0 }
            return LinuxGuestImageArtifact(role: .disk, path: $0.path, sha512: FloeDigest.sha512Hex(updated), bytes: Int64(updated.count))
        }
        try JSONEncoder().encode(manifest).write(to: fixture.imageDirectory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try preparer.prepare(
            image: manifest, imageDirectory: fixture.imageDirectory,
            environmentID: "e", writableDirectory: writable, targetCapacityBytes: 8 * 1024
        )) { error in
            guard case LinuxGuestRuntimeImageError.diskOriginConflict = error else { return XCTFail("got \(error)") }
        }
        let preserved = try Data(contentsOf: disk)
        XCTAssertTrue(preserved.range(of: marker) != nil)
    }
}

// MARK: - Authoritative install state

final class LinuxInstallStateDerivationTests: XCTestCase {
    func testRunningGuestCanNeverRenderDownload() {
        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = true
        facts.guestEnvironmentID = "env-1"
        facts.guestRunning = true
        XCTAssertEqual(LinuxGuestInstallStateDerivation.state(from: facts), .running(environmentID: "env-1"))
        // Even an unverified-image glitch must not outrank a running guest.
        facts.imageInstalled = false
        facts.imageVerificationFailure = "digest mismatch"
        facts.downloadRunning = true
        XCTAssertEqual(LinuxGuestInstallStateDerivation.state(from: facts), .running(environmentID: "env-1"))
    }

    func testMissingImageIsNeedsDownloadExactlyOnce() {
        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = false
        facts.imageDistributable = true
        guard case .needsDownload = LinuxGuestInstallStateDerivation.state(from: facts) else {
            return XCTFail("expected needsDownload")
        }
    }

    func testDownloadingShowsProgressAndCancellation() {
        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.downloadRunning = true
        facts.downloadFraction = 0.4
        XCTAssertEqual(LinuxGuestInstallStateDerivation.state(from: facts), .downloading(fraction: 0.4, cancelling: false))
        facts.downloadRunning = false
        facts.downloadCancelling = true
        XCTAssertEqual(LinuxGuestInstallStateDerivation.state(from: facts), .downloading(fraction: 0.4, cancelling: true))
    }

    func testInstalledStoppedThenRepairThenUpdate() {
        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = true
        XCTAssertEqual(LinuxGuestInstallStateDerivation.state(from: facts), .installedStopped(environmentID: nil))
        facts.guestEnvironmentID = "env-9"
        XCTAssertEqual(LinuxGuestInstallStateDerivation.state(from: facts), .installedStopped(environmentID: "env-9"))
        facts.guestLastError = "start failed: busy"
        guard case .repairRequired(let env, let message) = LinuxGuestInstallStateDerivation.state(from: facts) else {
            return XCTFail("expected repair")
        }
        XCTAssertEqual(env, "env-9"); XCTAssertTrue(message.contains("busy"))
        facts.guestLastError = nil
        facts.componentUpdateDetail = "runner update available"
        guard case .updateAvailable(let env, _) = LinuxGuestInstallStateDerivation.state(from: facts) else {
            return XCTFail("expected updateAvailable")
        }
        XCTAssertEqual(env, "env-9")
        facts.componentUpdateDetail = nil
        facts.guestDiskResizeFailure = "resize2fs failed"
        guard case .repairRequired = LinuxGuestInstallStateDerivation.state(from: facts) else {
            return XCTFail("resize failure must surface as repair")
        }
    }

    func testStorageUnavailable() {
        XCTAssertEqual(LinuxGuestInstallStateDerivation.state(from: LinuxGuestInstallFacts()), .storageUnavailable)
    }
}

// MARK: - ext4 resize parsing/script

final class LinuxGuestFilesystemResizeTests: XCTestCase {
    func testParsesContainerAndFilesystemGeometry() throws {
        let output = """
        FLOE_CONTAINER_BYTES=8589934592
        FLOE_FS_BLOCK_COUNT=2000
        FLOE_FS_BLOCK_SIZE=4096
        """
        let geometry = try XCTUnwrap(LinuxGuestFilesystemResize.geometry(probeOutput: output))
        XCTAssertEqual(geometry.containerBytes, 8 * 1024 * 1024 * 1024)
        XCTAssertEqual(geometry.filesystemBytes, 2000 * 4096)
        XCTAssertFalse(geometry.isCurrent)
        let current = try XCTUnwrap(LinuxGuestFilesystemResize.geometry(probeOutput: """
        FLOE_CONTAINER_BYTES=10485760
        FLOE_FS_BLOCK_COUNT=2559
        FLOE_FS_BLOCK_SIZE=4096
        """))
        XCTAssertTrue(current.isCurrent, "within 1 MiB counts as current")
    }

    func testRejectsMalformedProbeOutput() {
        XCTAssertNil(LinuxGuestFilesystemResize.geometry(probeOutput: "no labels"))
        XCTAssertNil(LinuxGuestFilesystemResize.geometry(probeOutput: """
        FLOE_CONTAINER_BYTES=abc
        FLOE_FS_BLOCK_COUNT=1
        FLOE_FS_BLOCK_SIZE=1
        """))
    }

    func testEnsureScriptIsIdempotentAndTargetsRootDevice() {
        let script = LinuxGuestFilesystemResize.ensureScript()
        XCTAssertTrue(script.contains(LinuxGuestDiskLayout.guestRootDevice))
        XCTAssertTrue(script.contains("resize2fs"))
        XCTAssertTrue(script.contains("floe-resize: current"))
    }
}

// MARK: - No duplicate trusted downloads

final class LinuxGuestImageDownloadCoalescingTests: XCTestCase {
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-coalesce-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testConcurrentCallsShareOneDownload() async throws {
        let service = LinuxGuestImageInstallationService(root: makeRoot())
        let gate = AsyncGatedDownloader()
        let id = LinuxGuestImageDistributionCatalog.defaultImageID
        async let first = service.installTrustedImage(id: id, downloader: gate)
        async let second = service.installTrustedImage(id: id, downloader: gate)
        // Give both tasks time to enter the actor and coalesce.
        try await Task.sleep(for: .milliseconds(100))
        await gate.openGate()
        _ = try? await (first, second)
        let starts = await gate.startCount
        XCTAssertEqual(starts, 1, "two concurrent requests must start exactly one download")
    }

    func testAlreadyInstalledSkipsDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = LinuxGuestImageInstallationService(root: root)
        // Import a valid (but unpinned/local) image directory first.
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-skip-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let contents = Data("bios".utf8)
        try contents.write(to: source.appendingPathComponent("bbl64.bin"))
        let manifest = LinuxGuestImage(
            id: "local-image",
            biosPath: "bbl64.bin",
            qualified: true,
            qualificationEvidence: "skip test",
            qualificationRun: "run-skip",
            artifacts: [.init(role: .bios, path: "bbl64.bin", sha512: FloeDigest.sha512Hex(contents), bytes: Int64(contents.count))]
        )
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        _ = try await service.importDirectory(at: source)
        let downloader = FailingDownloader()
        _ = try await service.installTrustedImage(id: "local-image", downloader: downloader)
        XCTAssertEqual(downloader.invocations, 0, "an already-installed image must not trigger a downloader")
    }
}

private actor AsyncGatedDownloader: LinuxGuestImageDownloading {
    private var started = 0
    var startCount: Int { started }
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func download(_ url: URL, to destination: URL, maxBytes: Int64,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws(LinuxGuestImageTransferError) {
        started += 1
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiters.append(c) }
        // Never completes in this test (both callers await the shared task).
        try? await Task.sleep(for: .seconds(30))
        throw .cancelled
    }

    nonisolated func release() {}
    func openGate() { for w in waiters { w.resume() } }
}

private struct FailingDownloader: LinuxGuestImageDownloading {
    var invocations = 0
    func download(_ url: URL, to destination: URL, maxBytes: Int64,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws(LinuxGuestImageTransferError) {
        XCTFail("downloader must not be invoked for an installed image")
        throw .responseInvalid(detail: "unexpected")
    }
}

// MARK: - Temp/cache paths

final class LinuxGuestWritablePathsTests: XCTestCase {
    func testAllCachesLiveUnderEnvironmentShare() {
        let vars = LinuxGuestWritablePaths.environmentVariables()
        for (key, value) in vars {
            XCTAssertTrue(value.hasPrefix("/floe/env/"), "\(key)=\(value) escapes the environment share")
        }
        XCTAssertEqual(vars["TMPDIR"], "/floe/env/tmp")
        XCTAssertEqual(vars["TMP"], "/floe/env/tmp")
        XCTAssertEqual(vars["TEMP"], "/floe/env/tmp")
        XCTAssertEqual(vars["XDG_CACHE_HOME"], "/floe/env/cache/xdg")
        XCTAssertEqual(vars["PIP_CACHE_DIR"], "/floe/env/cache/pip")
        XCTAssertEqual(vars["npm_config_cache"], "/floe/env/cache/npm")
        // A Pillow source build uses TMPDIR + PIP_CACHE_DIR; both must be
        // outside the compact root partition / RAM-backed /tmp.
        XCTAssertNotEqual(vars["TMPDIR"], "/tmp")
        let modes = Dictionary(uniqueKeysWithValues: LinuxGuestWritablePaths.bootDirectories.map { ($0.path, $0.mode) })
        XCTAssertEqual(modes["/floe/env/tmp"], 0o1777, "tmp is world-writable sticky")
    }
}
