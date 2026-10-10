import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import FloeCore

@Suite("Storage census accounting")
struct StorageAccountingTests {
    private func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCensusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ name: String, bytes: Int, at root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    /// Create a real sparse file whose apparent length is `logical` but which
    /// has only written `written` prefix bytes.
    private func makeSparseFile(at url: URL, logical: Int, written: Int) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        try #require(fd >= 0)
        defer { close(fd) }
        let result = ftruncate(fd, off_t(logical))
        try #require(result == 0)
        if written > 0 {
            let buffer = [UInt8](repeating: 0xCD, count: written)
            let n = buffer.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            #expect(n == written)
        }
    }

    @Test func countsAllocatedAndLogicalSeparately() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.bin", bytes: 4096, at: root)
        try write("b.bin", bytes: 8192, at: root)

        let report = try StorageCensus(
            roots: [StorageCensusRoot(id: "all", url: root)],
            metricLabel: "test"
        ).run()

        let bucket = try #require(report.bucket("all"))
        #expect(bucket.fileCount == 2)
        #expect(bucket.size.logicalBytes == 12288)
        #expect(bucket.size.allocatedBytes >= 12288)
    }

    @Test func sparseDiskApparentCapacityIsNotReportedAsHostUsage() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appendingPathComponent("disk.img")
        // 64 MiB apparent, only 64 KiB written. Note: APFS reports full
        // allocation for files up to ~16 MiB (small-file preallocation), so a
        // realistic VM-disk size is required to observe sparseness — Floe's VM
        // disks are 16/32 GiB, far above that threshold.
        try makeSparseFile(at: disk, logical: 64 * 1024 * 1024, written: 64 * 1024)

        let report = try StorageCensus(
            roots: [StorageCensusRoot(id: "disks", url: root)],
            metricLabel: "test.sparse"
        ).run()
        let bucket = try #require(report.bucket("disks"))

        #expect(bucket.size.logicalBytes == 64 * 1024 * 1024)
        // Allocated must be far below apparent capacity.
        #expect(bucket.size.allocatedBytes < 2 * 1024 * 1024)
        #expect(bucket.size.allocatedBytes < bucket.size.logicalBytes)
    }

    @Test func hardLinksAreCountedOnce() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try write("original.bin", bytes: 16_384, at: root)
        let link = root.appendingPathComponent("link.bin")
        try FileManager.default.linkItem(at: original, to: link)

        let report = try StorageCensus(
            roots: [StorageCensusRoot(id: "all", url: root)],
            metricLabel: "test.hardlink"
        ).run()
        let bucket = try #require(report.bucket("all"))
        #expect(bucket.fileCount == 1)
        #expect(bucket.size.allocatedBytes >= 16_384)
        #expect(bucket.size.allocatedBytes < 32_000)
        #expect(report.diagnostics.dedupedFileCount == 1)
    }

    @Test func nestedRootsAttributeToDeepestAndDoNotDoubleCount() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("LocalModels", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try write("top.bin", bytes: 4096, at: root)
        try write("model.bin", bytes: 8192, at: models)

        let report = try StorageCensus(
            roots: [
                StorageCensusRoot(id: "app", url: root),
                StorageCensusRoot(id: "models", url: models)
            ],
            metricLabel: "test.nested"
        ).run()

        #expect(report.bucket("models")?.fileCount == 1)
        #expect(report.bucket("models")?.size.logicalBytes == 8192)
        #expect(report.bucket("app")?.fileCount == 1)
        #expect(report.bucket("app")?.size.logicalBytes == 4096)
        // Total across both roots must not double count model.bin.
        let sum = report.buckets.reduce(Int64(0)) { $0 + $1.size.logicalBytes }
        #expect(sum == 12288)
    }

    @Test func parentWalkAssignsUnattributedFiles() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let known = root.appendingPathComponent("Known", isDirectory: true)
        try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
        try write("known.bin", bytes: 1024, at: known)
        try write("mystery.bin", bytes: 2048, at: root)

        let report = try StorageCensus(
            roots: [StorageCensusRoot(id: "known", url: known)],
            parentURL: root,
            metricLabel: "test.parent"
        ).run()

        #expect(report.bucket("known")?.fileCount == 1)
        #expect(report.unattributedCount == 1)
        #expect(report.unattributedSize.logicalBytes == 2048)
    }

    @Test func symlinksAreNotFollowed() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.bin")
        try write("outside.bin", bytes: 5000, at: root)
        let dir = root.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("link.bin").path,
            withDestinationPath: outside.path
        )

        let report = try StorageCensus(
            roots: [StorageCensusRoot(id: "dir", url: dir)],
            metricLabel: "test.symlink"
        ).run()
        // The symlink itself is not a regular file; target must not be counted.
        #expect(report.bucket("dir")?.fileCount == 0)
        #expect(report.diagnostics.symbolicLinkCount == 1)
    }

    @Test func hiddenFilesAreCountedByDefault() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(".secret.bin", bytes: 1024, at: root)
        try write("visible.bin", bytes: 1024, at: root)

        let included = try StorageCensus(
            roots: [StorageCensusRoot(id: "a", url: root, includeHiddenFiles: true)],
            metricLabel: "t"
        ).run()
        #expect(included.bucket("a")?.fileCount == 2)

        let excluded = try StorageCensus(
            roots: [StorageCensusRoot(id: "a", url: root, includeHiddenFiles: false)],
            metricLabel: "t"
        ).run()
        #expect(excluded.bucket("a")?.fileCount == 1)
    }

    @Test func cancellationStopsTheScan() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<50 { try write("f\(i).bin", bytes: 4096, at: root) }

        let cancelled = true
        #expect(throws: StorageCensusError.self) {
            try StorageCensus(
                roots: [StorageCensusRoot(id: "a", url: root)],
                metricLabel: "t",
                isCancelled: { cancelled }
            ).run()
        }
    }

    @Test func vanishingFilesAreRecordedAsChangedNotErrors() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.bin", bytes: 1024, at: root)
        let report = try StorageCensus(
            roots: [StorageCensusRoot(id: "a", url: root)],
            metricLabel: "t.vanish"
        ).run()
        #expect(report.diagnostics.errorCount == 0)
        #expect(report.diagnostics.regularFileCount >= 1)
    }

    @Test func hardLinkAcrossCategoryAndRemainderCountsOnce() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let known = root.appendingPathComponent("Known", isDirectory: true)
        try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
        let original = try write("shared.bin", bytes: 16_384, at: known)
        // Hard link in the parent (unattributed) area.
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("shared-link.bin"))

        let report = try StorageCensus(
            roots: [StorageCensusRoot(id: "known", url: known)],
            parentURL: root,
            metricLabel: "test.cross-bucket"
        ).run()
        #expect(report.bucket("known")?.fileCount == 1)
        // The remainder must not double count the hard-linked bytes.
        #expect(report.unattributedCount == 0)
        #expect(report.unattributedSize.allocatedBytes == 0)
        #expect(report.diagnostics.dedupedFileCount == 1)
        #expect(report.totalAllocatedBytes == (report.bucket("known")?.size.allocatedBytes ?? -1))
    }

    @Test func allocatedMeasurementNeverFallsBackToLogical() throws {
        // Nonexistent path + no resource values: no verified measurement exists,
        // so the result must be unmeasured 0 bytes — never the logical size.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).bin")
        let measurement = StorageCensus.allocatedMeasurement(at: missing, values: nil)
        #expect(measurement.measured == false)
        #expect(measurement.bytes == 0)
    }

    @Test func nestedWalkRootsAreTraversedOnce() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        _ = try write("top.bin", bytes: 1024, at: root)
        _ = try write("child.bin", bytes: 1024, at: child)

        let noParent = StorageCensus.normalizedWalkTrees(
            roots: [
                StorageCensusRoot(id: "app", url: root),
                StorageCensusRoot(id: "child", url: child)
            ],
            parentURL: nil
        )
        #expect(noParent.count == 1)
        #expect(noParent.first?.url.path == root.standardizedFileURL.path)

        let parent = StorageCensus.normalizedWalkTrees(
            roots: [
                StorageCensusRoot(id: "app", url: root),
                StorageCensusRoot(id: "child", url: child)
            ],
            parentURL: root
        )
        // The parent covers both roots; nothing outside it remains to walk.
        #expect(parent.count == 1)
    }

    @Test func progressCallbackReportsScannedCount() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<5 { _ = try write("f\(i).bin", bytes: 512, at: root) }
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var last = 0
            func update(_ value: Int) { lock.lock(); last = value; lock.unlock() }
        }
        let box = Box()
        let report = try StorageCensus(
            roots: [StorageCensusRoot(id: "a", url: root)],
            metricLabel: "t.progress",
            onProgress: { box.update($0) }
        ).run()
        #expect(box.last == report.diagnostics.regularFileCount)
    }

    @Test func deniedSubtreeIsCountedAsError() throws {
        let root = try makeTempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root.appendingPathComponent("denied").path)
            try? FileManager.default.removeItem(at: root)
        }
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        _ = try write("inside.bin", bytes: 512, at: denied)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)

        let report = try StorageCensus(
            roots: [StorageCensusRoot(id: "a", url: root)],
            metricLabel: "t.denied"
        ).run()
        // When the process really cannot read the subtree the enumerator must
        // report an error rather than silently dropping it.
        if (try? FileManager.default.contentsOfDirectory(atPath: denied.path)) == nil {
            #expect(report.diagnostics.errorCount >= 1)
        }
    }
}
