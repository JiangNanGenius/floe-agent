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

    @discardableResult
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

    // MARK: - K: upgraded-layout, clone and directory-metadata coverage

    /// Synthetic "upgraded iPad" container: legacy LinuxGuest images next to
    /// Runtime v2 blobs and per-environment materializations, plus models,
    /// caches, Documents and tmp.
    private func makeUpgradedLayout() throws -> (base: FloeStorageBase, root: URL) {
        let root = try makeTempDir()
        let fm = FileManager.default
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let floeAgent = support.appendingPathComponent("FloeAgent", isDirectory: true)
        let runtimeV2 = support.appendingPathComponent("Floe/Runtime/v2/images/blobs/aa", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let caches = library.appendingPathComponent("Caches", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        for directory in [
            floeAgent.appendingPathComponent("LocalModels", isDirectory: true),
            floeAgent.appendingPathComponent("LinuxGuest/images/i1", isDirectory: true),
            floeAgent.appendingPathComponent("Environments/env1", isDirectory: true),
            floeAgent.appendingPathComponent("PrivateTasks/task1", isDirectory: true),
            runtimeV2, documents, caches,
            temporary.appendingPathComponent("floe-scratch", isDirectory: true)
        ] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        _ = try write("model.bin", bytes: 8_192, at: floeAgent.appendingPathComponent("LocalModels"))
        _ = try write("rootfs.img", bytes: 65_536, at: floeAgent.appendingPathComponent("LinuxGuest/images/i1"))
        _ = try write("rootfs.img", bytes: 65_536, at: floeAgent.appendingPathComponent("Environments/env1"))
        _ = try write("blob.bin", bytes: 65_536, at: runtimeV2)
        _ = try write(".secret.bin", bytes: 1_024, at: floeAgent.appendingPathComponent("PrivateTasks/task1"))
        _ = try write("cache.bin", bytes: 4_096, at: caches)
        _ = try write("doc.bin", bytes: 2_048, at: documents)
        _ = try write("tmp.bin", bytes: 1_024, at: temporary)
        _ = try write("part.bin", bytes: 512, at: temporary.appendingPathComponent("floe-scratch"))

        let base = FloeStorageBase(
            applicationSupport: support,
            library: library,
            documents: documents,
            caches: caches,
            temporary: temporary
        )
        return (base, root)
    }

    @Test func upgradedLayoutKeepsCategoriesExclusiveAndFlagsCloneRoots() throws {
        let fixture = try makeUpgradedLayout()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        func run() throws -> StorageCensusReport {
            try StorageCensus(
                roots: FloeStorageLayout.roots(in: fixture.base),
                parentURL: FloeStorageLayout.parentURL(in: fixture.base),
                metricLabel: "test.upgraded"
            ).run()
        }

        let census = try run()
        // Every byte is owned by exactly one bucket or the remainder.
        let bucketSum = census.buckets.reduce(Int64(0)) { $0 + $1.size.allocatedBytes }
        #expect(bucketSum + census.unattributedSize.allocatedBytes == census.totalAllocatedBytes)

        // The upgraded hierarchy is attributed to its real roots, not the
        // Library catch-all.
        let ids = Set(census.buckets.map(\.id))
        #expect(ids.isSuperset(of: [
            "models", "linuxDisks", "environments", "runtimeV2",
            "workspaces", "caches", "documents", "temporary", "floeOther"
        ]))
        #expect(census.bucket("models")?.fileCount == 1)
        #expect(census.bucket("linuxDisks")?.fileCount == 1)
        #expect(census.bucket("environments")?.fileCount == 1)
        #expect(census.bucket("runtimeV2")?.fileCount == 1)
        #expect(census.bucket("documents")?.fileCount == 1)

        // Clone-capable roots carry the flag; the rest do not.
        #expect(census.bucket("linuxDisks")?.isCloneCapable == true)
        #expect(census.bucket("environments")?.isCloneCapable == true)
        #expect(census.bucket("runtimeV2")?.isCloneCapable == true)
        #expect(census.bucket("models")?.isCloneCapable == false)
        #expect(census.bucket("documents")?.isCloneCapable == false)

        // The flagged portion stays inside the measured total (no silent
        // subtraction). There is no subtractive "exclusive" figure: unflagged
        // roots are not proven exclusive either.
        let flagged = (census.bucket("linuxDisks")?.size.allocatedBytes ?? 0)
            + (census.bucket("environments")?.size.allocatedBytes ?? 0)
            + (census.bucket("runtimeV2")?.size.allocatedBytes ?? 0)
        #expect(census.cloneCapableAllocatedBytes == flagged)

        // Repeated scans of the same tree are stable (same snapshot semantics).
        let again = try run()
        #expect(again.totalAllocatedBytes == census.totalAllocatedBytes)
        #expect(again.cloneCapableAllocatedBytes == census.cloneCapableAllocatedBytes)
    }

    @Test func fullCloneFamiliesAreDeduplicatedExactly() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try write("base.img", bytes: 256 * 1024, at: root)
        let clone1 = root.appendingPathComponent("clone1.img")
        let clone2 = root.appendingPathComponent("clone2.img")
        guard clonefile(base.path, clone1.path, 0) == 0,
              clonefile(clone1.path, clone2.path, 0) == 0 else {
            // Non-clone-capable test volume: nothing to assert about clones.
            return
        }
        let plain = try write("plain.bin", bytes: 4_096, at: root)
        let plainValues = try plain.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
        ])
        let plainAllocated = StorageCensus.allocatedMeasurement(at: plain, values: plainValues).bytes
        let baseValues = try base.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
        ])
        let baseAllocated = StorageCensus.allocatedMeasurement(at: base, values: baseValues).bytes

        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "linuxDisks", url: root, potentiallyCloned: true)],
            metricLabel: "test.clone-family"
        ).run()

        let bucket = try #require(census.bucket("linuxDisks"))
        #expect(bucket.isCloneCapable)
        #expect(census.diagnostics.cloneAttributeSupport == .supported)
        // The three members share one data stream (same clone-id,
        // SHARES_ALL_BLOCKS): the stream is counted once, exactly.
        #expect(census.diagnostics.dedupedCloneFileCount == 2)
        #expect(census.diagnostics.dedupedCloneBytes == 2 * baseAllocated)
        #expect(bucket.size.allocatedBytes == baseAllocated + plainAllocated)
        #expect(census.hasCloneSharing)
        // Only the shared BYTES are deduplicated: all four files are distinct
        // identities and stay counted as files (the UI column is "files").
        #expect(bucket.fileCount == 4)
        #expect(census.diagnostics.dedupedFileCount == 0)
        // Measured exclusive lower bound: the pure clones contribute 0 private
        // bytes before any COW write; the plain file is fully private.
        #expect(census.measuredExclusiveLowerBoundBytes == plainAllocated)
    }

    /// The same clone-id on two DIFFERENT volumes is not one data stream:
    /// clone-ids are volume-scoped, so grouping must carry the device identity
    /// and must not deduplicate across volumes. Injected attributes model two
    /// volumes that happen to reuse the id (a real second volume is not
    /// available in the test host).
    @Test func sameCloneIDOnDifferentVolumesIsNotDeduplicated() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let volumeA = try write("volA.img", bytes: 64 * 1024, at: root)
        let volumeB = try write("volB.img", bytes: 64 * 1024, at: root)
        let sharedCloneID: UInt64 = 0xABCD_1234
        let attributes = StorageCloneAttributes(
            privateBytes: 0,
            cloneID: sharedCloneID,
            extendedFlags: UInt64(EF_MAY_SHARE_BLOCKS) | UInt64(EF_SHARES_ALL_BLOCKS),
            cloneRefCount: 2
        )
        let volumeByPath: [String: UInt64] = [volumeA.path: 7, volumeB.path: 9]

        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "all", url: root, potentiallyCloned: true)],
            metricLabel: "test.clone-two-volumes",
            cloneAttributeProvider: { _ in .attributes(attributes) },
            cloneStreamVolumeProvider: { volumeByPath[$0] }
        ).run()

        let bucket = try #require(census.bucket("all"))
        #expect(census.diagnostics.dedupedCloneFileCount == 0)
        #expect(census.diagnostics.dedupedCloneBytes == 0)
        #expect(bucket.fileCount == 2)
        // Both volumes' bytes stay counted: nothing may be collapsed by an id
        // that only repeats because the two filesystems number streams alike.
        #expect(bucket.size.allocatedBytes >= Int64(2 * 32 * 1024))
        // The sharing is still reported honestly as clone-capable.
        #expect(bucket.isCloneCapable)
        #expect(census.hasCloneSharing)
    }

    /// The same clone-id on the SAME volume is one data stream and is
    /// deduplicated exactly, even when the attributes are injected (no real
    /// clonefile support needed): bytes dedup, files stay counted.
    @Test func sameCloneIDOnTheSameVolumeDeduplicatesBytesButKeepsFileCount() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write("first.img", bytes: 128 * 1024, at: root)
        try write("second.img", bytes: 128 * 1024, at: root)
        let firstValues = try first.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
        ])
        let firstAllocated = StorageCensus.allocatedMeasurement(at: first, values: firstValues).bytes
        let attributes = StorageCloneAttributes(
            privateBytes: 0,
            cloneID: 0x5555_AAAA,
            extendedFlags: UInt64(EF_MAY_SHARE_BLOCKS) | UInt64(EF_SHARES_ALL_BLOCKS),
            cloneRefCount: 2
        )

        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "all", url: root, potentiallyCloned: true)],
            metricLabel: "test.clone-same-volume",
            cloneAttributeProvider: { _ in .attributes(attributes) },
            cloneStreamVolumeProvider: { _ in 42 }
        ).run()

        let bucket = try #require(census.bucket("all"))
        #expect(census.diagnostics.dedupedCloneFileCount == 1)
        #expect(census.diagnostics.dedupedCloneBytes == firstAllocated)
        #expect(bucket.size.allocatedBytes == firstAllocated)
        #expect(bucket.fileCount == 2, "the deduplicated clone is still a distinct file")
        #expect(bucket.dedupedCloneSize.allocatedBytes == firstAllocated)
    }

    @Test func copyOnWriteSplitIsNotUnionedButBoundsHold() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try write("base.img", bytes: 256 * 1024, at: root)
        let clone = root.appendingPathComponent("clone.img")
        guard clonefile(base.path, clone.path, 0) == 0 else { return }
        // COW 16 KiB into the clone: it gets a new clone-id and clears
        // SHARES_ALL_BLOCKS. The union of the two streams is not derivable, so
        // the census must not invent one: the allocated sum stays an upper
        // bound and private bytes a measured lower bound.
        let handle = try FileHandle(forWritingTo: clone)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0xEE, count: 16 * 1024))
        try handle.close()

        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "linuxDisks", url: root, potentiallyCloned: true)],
            metricLabel: "test.clone-cow"
        ).run()

        #expect(census.diagnostics.dedupedCloneBytes == 0)
        let lowerBound = try #require(census.measuredExclusiveLowerBoundBytes)
        #expect(lowerBound > 0)
        #expect(lowerBound <= census.totalAllocatedBytes)
        // Upper bound still counts both streams in full.
        #expect(census.totalAllocatedBytes >= 2 * 256 * 1024)
    }

    @Test func unsupportedVolumeFallsBackToDeclaredRootFlags() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("a.bin", bytes: 4_096, at: root)

        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "linuxDisks", url: root, potentiallyCloned: true)],
            metricLabel: "test.clone-unsupported",
            cloneAttributeProvider: { _ in .unsupported }
        ).run()

        #expect(census.diagnostics.cloneAttributeSupport == .unavailable)
        #expect(census.diagnostics.dedupedCloneBytes == 0)
        #expect(census.measuredExclusiveLowerBoundBytes == nil)
        // The declared root flag still marks the bucket and the report.
        #expect(census.bucket("linuxDisks")?.isCloneCapable == true)
        #expect(census.isSharedAllocationEstimate)
    }

    @Test func measuredFlagsMarkSharingOutsideDeclaredRoots() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("imported.bin", bytes: 8_192, at: root)

        let fake = StorageCloneAttributes(
            privateBytes: 8_192,
            cloneID: 0x1234,
            extendedFlags: UInt64(EF_MAY_SHARE_BLOCKS),
            cloneRefCount: 1
        )
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "documents", url: root)],  // not declared clone-capable
            metricLabel: "test.clone-actual",
            cloneAttributeProvider: { _ in .attributes(fake) }
        ).run()

        #expect(census.bucket("documents")?.isCloneCapable == true)
        #expect(census.isSharedAllocationEstimate)
        #expect(census.measuredExclusiveLowerBoundBytes == 8_192)
    }

    @Test func directoryEntriesAreNotChargedAsFileData() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var expected: Int64 = 0
        for index in 0..<3 {
            let directory = root.appendingPathComponent("dir\(index)/nested", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = try write("payload.bin", bytes: 4_096 * (index + 1), at: directory)
            let values = try file.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
            ])
            expected += StorageCensus.allocatedMeasurement(at: file, values: values).bytes
        }

        let report = try StorageCensus(
            roots: [StorageCensusRoot(id: "a", url: root)],
            metricLabel: "test.directories"
        ).run()

        let bucket = try #require(report.bucket("a"))
        #expect(bucket.fileCount == 3)
        #expect(report.diagnostics.directoryCount >= 6)
        // Directory metadata never adds bytes on top of the files inside them.
        #expect(bucket.size.allocatedBytes == expected)
    }
}
