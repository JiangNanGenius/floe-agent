import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import FloeCore

// K3 — measured physical-extent accounting (public fcntl F_LOG2PHYS_EXT).
//
// These tests cover the union arithmetic with injected intervals AND the real
// public-API probe on APFS fixtures: full clones, partial COW, hard links,
// independent copies, sparse files, unaligned tails, the bundle/data
// reconciliation and every fail-closed fallback class. Assertions compare
// against independently measured `st_blocks`, never against guessed round
// units.

@Suite("Storage extent accounting")
struct StorageExtentAccountingTests {
    private func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageExtentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ name: String, bytes: Int, at root: URL, seed: UInt8 = 0xAB) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: seed, count: bytes).write(to: url)
        return url
    }

    private func allocatedBlockBytes(_ url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return -1 }
        return Int64(info.st_blocks) * 512
    }

    private func measuredRuns(_ url: URL) -> StorageExtentMeasurement? {
        let result = StorageExtentProbeReader.read(
            path: url.path, expectedDevice: nil, expectedInode: nil, isCancelled: { false }
        )
        guard case .measured(let measurement) = result else { return nil }
        return measurement
    }

    // MARK: - real public-API probe (APFS fixtures)

    @Test func unalignedFileSizesReconcileWithAllocatedBlocks() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for size in [1, 100, 4095, 4096, 4097, 65_537, 1_048_577] {
            let url = try write("unaligned-\(size).bin", bytes: size, at: root)
            let measurement = try #require(measuredRuns(url), "size \(size) measured")
            let runBytes = measurement.runs.reduce(Int64(0)) { $0 + $1.length }
            // The block-rounded tail must be included: an unaligned or tiny
            // file is never counted as 0 or as its logical length.
            #expect(runBytes == allocatedBlockBytes(url), "size \(size): runs \(runBytes)")
            #expect(runBytes > 0, "size \(size) counts its allocated block")
        }
    }

    @Test func fullCloneAndHardLinkCountOneStream() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try write("base.bin", bytes: 8_192, at: root)
        let clone = root.appendingPathComponent("clone.bin")
        #expect(clonefile(base.path, clone.path, 0) == 0)
        let hard = root.appendingPathComponent("hard.bin")
        #expect(link(base.path, hard.path) == 0)

        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: root)],
            metricLabel: "test.extent.clone",
            extentProbe: .system
        ).run()
        let union = try #require(census.extentUnion)
        #expect(union.totalBytes == allocatedBlockBytes(base))
        // The hard link is identity-deduplicated and the pure full clone is
        // deduplicated by clone-id BEFORE probing (its runs are identical to
        // the stream already measured), so exactly one file was measured.
        #expect(union.measuredFileCount == 1)
        #expect(union.bundleBytes == nil)
        #expect(census.diagnostics.extentBasis == .available)
    }

    @Test func cowSplitKeepsUntouchedBlocksShared() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try write("base.bin", bytes: 1 << 20, at: root)
        let clone = root.appendingPathComponent("clone.bin")
        #expect(clonefile(base.path, clone.path, 0) == 0)
        let cow = root.appendingPathComponent("cow.bin")
        #expect(clonefile(base.path, cow.path, 0) == 0)
        // One 4 KiB block overwritten in the middle: APFS moves a bounded
        // private region and keeps the rest shared.
        guard let handle = try? FileHandle(forWritingTo: cow) else {
            Issue.record("cannot open cow fixture"); return
        }
        try handle.seek(toOffset: 512 * 1024)
        try handle.write(contentsOf: Data(repeating: 0x5A, count: 4096))
        try handle.close()

        let baseBlocks = allocatedBlockBytes(base)
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: root)],
            metricLabel: "test.extent.cow",
            extentProbe: .system
        ).run()
        let union = try #require(census.extentUnion)
        // The partial clone is deduplicated on the shared blocks instead of
        // summed three times; the private COW region is retained.
        #expect(union.totalBytes >= baseBlocks)
        #expect(union.totalBytes <= baseBlocks * 2)
        #expect(union.totalBytes < allocatedBlockBytes(base) * 3)
    }

    @Test func independentCopiesAreNotDeduplicatedByContent() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write("first.bin", bytes: 4096, at: root, seed: 0x11)
        let second = try write("second.bin", bytes: 4096, at: root, seed: 0x11)
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: root)],
            metricLabel: "test.extent.dup",
            extentProbe: .system
        ).run()
        let union = try #require(census.extentUnion)
        #expect(union.totalBytes == allocatedBlockBytes(first) + allocatedBlockBytes(second))
    }

    @Test func sparseFileContributesOnlyAllocatedBlocksWithBoundedCalls() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sparse = root.appendingPathComponent("sparse.bin")
        do {
            let fd = open(sparse.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
            try #require(fd >= 0)
            try #require(ftruncate(fd, 1 << 30) == 0)
            let chunk = [UInt8](repeating: 0x33, count: 4096)
            let written = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, 4096, 0) }
            try #require(written == 4096)
            // Close before measuring: APFS commits the block accounting on
            // close, and the census only ever sees settled files.
            close(fd)
        }

        let measurement = try #require(measuredRuns(sparse))
        let runBytes = measurement.runs.reduce(Int64(0)) { $0 + $1.length }
        #expect(runBytes == allocatedBlockBytes(sparse))
        // The public SEEK_DATA/SEEK_HOLE fast path must not walk a 1 GiB hole
        // range call by call.
        #expect(measurement.callCount <= 8)
    }

    // MARK: - injected interval arithmetic

    private func censusWithInjectedRuns(
        rootA: URL,
        rootB: URL,
        runs: [String: [StoragePhysicalRun]],
        bundleURL: URL? = nil
    ) throws -> StorageCensusReport {
        let probe = StorageExtentProbe { path, _, _, _, _ in
            if let runs = runs[path] {
                return .measured(StorageExtentMeasurement(runs: runs, callCount: 1))
            }
            return .measured(StorageExtentMeasurement(runs: [], callCount: 0))
        }
        return try StorageCensus(
            roots: [
                StorageCensusRoot(id: "a", url: rootA),
                StorageCensusRoot(id: "b", url: rootB)
            ],
            metricLabel: "test.extent.injected",
            extentProbe: probe,
            bundleMeasurementURL: bundleURL
        ).run()
    }

    @Test func injectedIntervalsDeduplicateExactlyAndReconcile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootA = root.appendingPathComponent("a", isDirectory: true)
        let rootB = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let fullA = try write("full-a.bin", bytes: 32, at: rootA)
        let fullB = try write("full-b.bin", bytes: 32, at: rootB)
        let partialA = try write("partial-a.bin", bytes: 32, at: rootA)
        let partialB = try write("partial-b.bin", bytes: 32, at: rootB)
        let otherDevice = try write("device.bin", bytes: 32, at: rootA)
        let independentA = try write("ind-a.bin", bytes: 32, at: rootA)
        let independentB = try write("ind-b.bin", bytes: 32, at: rootB)

        let runs: [String: [StoragePhysicalRun]] = [
            fullA.path: [.init(device: 7, deviceOffset: 0, length: 1 << 20)],
            fullB.path: [.init(device: 7, deviceOffset: 0, length: 1 << 20)],
            partialA.path: [.init(device: 8, deviceOffset: 0, length: 100)],
            partialB.path: [.init(device: 8, deviceOffset: 50, length: 100)],
            otherDevice.path: [.init(device: 9, deviceOffset: 0, length: 4096)],
            independentA.path: [.init(device: 10, deviceOffset: 1 << 24, length: 4096)],
            independentB.path: [.init(device: 10, deviceOffset: 2 << 24, length: 4096)]
        ]
        let census = try censusWithInjectedRuns(rootA: rootA, rootB: rootB, runs: runs)
        let union = try #require(census.extentUnion)
        let expected: Int64 = (1 << 20) + 150 + 4096 + 8192
        #expect(union.totalBytes == expected)
        #expect(union.categoryBytes["a", default: 0]
            + union.categoryBytes["b", default: 0]
            + union.unattributedBytes == union.totalBytes)
        // Deterministic ownership: the whole full-clone stream and [0,100) of
        // the partial belong to the first-sorted owner; b owns only the
        // non-overlapped tail (100,150) plus its independent copy.
        #expect((union.categoryBytes["a"] ?? -1) == Int64((1 << 20) + 100 + 4096 + 4096))
        #expect((union.categoryBytes["b"] ?? -1) == Int64(50 + 4096))
    }

    @Test func deviceOffsetZeroIsAValidRunStart() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootA = root.appendingPathComponent("a", isDirectory: true)
        let rootB = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let fileA = try write("zero-offset-a.bin", bytes: 32, at: rootA)
        let fileB = try write("zero-offset-b.bin", bytes: 32, at: rootB)
        let runs: [String: [StoragePhysicalRun]] = [
            fileA.path: [.init(device: 3, deviceOffset: 0, length: 4096)],
            // Same stream from a clone of A in another bucket: one physical run.
            fileB.path: [.init(device: 3, deviceOffset: 0, length: 4096)]
        ]
        let census = try censusWithInjectedRuns(rootA: rootA, rootB: rootB, runs: runs)
        let union = try #require(census.extentUnion)
        #expect(union.totalBytes == 4096)
    }

    @Test func bundleAndDataClonesAreCountedOnce() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("App.bundle", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let bundleFile = try write("resource.bin", bytes: 64, at: bundle)
        let docsFile = try write("cloned-resource.bin", bytes: 64, at: docs)
        let runs: [String: [StoragePhysicalRun]] = [
            bundleFile.path: [.init(device: 9, deviceOffset: 4096, length: 8192)],
            docsFile.path: [.init(device: 9, deviceOffset: 4096, length: 8192)]
        ]
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "docs", url: docs)],
            metricLabel: "test.extent.bundle",
            extentProbe: StorageExtentProbe { path, _, _, _, _ in
                .measured(StorageExtentMeasurement(runs: runs[path] ?? [], callCount: 1))
            },
            bundleMeasurementURL: bundle
        ).run()
        let union = try #require(census.extentUnion)
        // The installer row and the data row are owned slices of ONE union:
        // the clone adds no new blocks and is not counted twice.
        #expect(union.totalBytes == 8192)
        #expect(union.bundleBytes == 8192)
        #expect(union.categoryBytes["docs", default: 0] == 0)
    }

    // MARK: - fail-closed behaviour

    @Test(arguments: [
        StorageExtentProbeResult.failed(.compressedMapping),
        .failed(.allocationMismatch),
        .failed(.changedWhileWalking),
        .failed(.zeroProgress),
        .failed(.offsetOverflow),
        .failed(.seekFailed),
        .unsupported
    ])
    func failuresKeepTheAcceptedAllocatedBasis(result: StorageExtentProbeResult) throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("data.bin", bytes: 4096, at: root)
        _ = file
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: root)],
            metricLabel: "test.extent.failure",
            extentProbe: StorageExtentProbe { _, _, _, _, _ in result }
        ).run()
        #expect(census.extentUnion == nil)
        #expect(census.diagnostics.extentBasis == .unavailable)
        #expect(census.diagnostics.extentUnavailableReason != nil)

        let report = StorageReportBuilder.build(census: census, bundleBytes: 77)
        #expect(report.totals.basis == .allocatedEstimate)
        #expect(report.totals.totalBytes == 77 + census.totalAllocatedBytes)
        #expect(report.totals.bundleBytes == 77)
        #expect(report.categories.allSatisfy { $0.basisBytes == $0.allocatedBytes })
    }

    @Test func budgetOverflowWithholdsTheUnion() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.bin", bytes: 4096, at: root)
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: root)],
            metricLabel: "test.extent.budget",
            extentProbe: StorageExtentProbe { _, _, _, _, _ in
                .measured(StorageExtentMeasurement(
                    runs: [
                        .init(device: 1, deviceOffset: 0, length: 4096),
                        .init(device: 1, deviceOffset: 8192, length: 4096),
                        .init(device: 1, deviceOffset: 16384, length: 4096)
                    ],
                    callCount: 3
                ))
            },
            extentBudget: StorageExtentBudget(maxTotalCalls: 100, maxIntervals: 2, maxDuration: 60)
        ).run()
        #expect(census.extentUnion == nil)
        #expect(census.diagnostics.extentUnavailableReason == .budgetExceeded)
    }

    @Test func cancellationThrowsInsteadOfPublishingAPartialUnion() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.bin", bytes: 4096, at: root)
        #expect(throws: StorageCensusError.cancelled) {
            _ = try StorageCensus(
                roots: [StorageCensusRoot(id: "data", url: root)],
                metricLabel: "test.extent.cancel",
                extentProbe: StorageExtentProbe { _, _, _, _, _ in .failed(.cancelled) }
            ).run()
        }
    }

    @Test func probeRejectsDirectoriesAndMissingFiles() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let directoryResult = StorageExtentProbeReader.read(
            path: root.path, expectedDevice: nil, expectedInode: nil, isCancelled: { false }
        )
        #expect(directoryResult == .failed(.notRegularFile))
        let missingResult = StorageExtentProbeReader.read(
            path: root.appendingPathComponent("missing.bin").path,
            expectedDevice: nil, expectedInode: nil, isCancelled: { false }
        )
        #expect(missingResult == .failed(.changedWhileWalking))
    }

    // MARK: - report basis and snapshot upgrades

    @Test func reportTotalsReconcileOnTheMeasuredBasis() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootA = root.appendingPathComponent("a", isDirectory: true)
        let rootB = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let fileA = try write("a.bin", bytes: 32, at: rootA)
        let fileB = try write("b.bin", bytes: 32, at: rootB)
        let runs: [String: [StoragePhysicalRun]] = [
            fileA.path: [.init(device: 5, deviceOffset: 0, length: 8192)],
            fileB.path: [.init(device: 5, deviceOffset: 4096, length: 8192)]
        ]
        let census = try censusWithInjectedRuns(rootA: rootA, rootB: rootB, runs: runs)
        let report = StorageReportBuilder.build(census: census, bundleBytes: 1_000)
        #expect(report.totals.basis == .measuredExtents)
        let unionTotal = try #require(census.extentUnion?.totalBytes)
        #expect(report.totals.totalBytes == unionTotal)
        #expect(report.totals.bundleBytes == 0)
        #expect(report.totals.dataBytes == unionTotal)
        let categorySum = report.categories.reduce(Int64(0)) { $0 + $1.basisBytes }
            + (report.unattributed?.basisBytes ?? 0)
        #expect(categorySum == report.totals.dataBytes)
        // The legacy raw fields keep the accepted allocated semantics so
        // callers that never use the probe are unchanged.
        #expect(report.combinedBytes == report.bundleBytes + report.totalAllocatedBytes)
    }

    @Test func previousAccountingVersionIsRejectedOnce() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = StorageSnapshotStore(directory: storeDirectory)
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let request = StorageCensusRequest(
            roots: [StorageCensusRoot(id: "data", url: dataRoot)],
            parentURL: nil,
            metricLabel: "test.extent.snapshot",
            contextFingerprint: "1.0.0(1)"
        )
        let census = try StorageCensus(
            roots: request.roots,
            metricLabel: request.metricLabel,
            extentProbe: StorageExtentProbe { _, _, _, _, _ in
                .measured(StorageExtentMeasurement(
                    runs: [.init(device: 2, deviceOffset: 0, length: 4096)], callCount: 1
                ))
            }
        ).run()
        let stale = StorageSnapshot(
            schemaVersion: 1,
            accountingVersion: "2026-10-16.clone-measured.v3",
            rootsFingerprint: request.key.rootsFingerprint,
            contextFingerprint: request.contextFingerprint,
            metricLabel: request.metricLabel,
            generatedAt: Date(),
            bundleBytes: 1,
            census: census,
            scanTrigger: "test"
        )
        try store.save(stale)
        #expect(store.load(key: request.key) == nil)
        let current = StorageSnapshot(
            rootsFingerprint: request.key.rootsFingerprint,
            contextFingerprint: request.contextFingerprint,
            metricLabel: request.metricLabel,
            generatedAt: Date(),
            bundleBytes: 1,
            census: census,
            scanTrigger: "test"
        )
        try store.save(current)
        let loaded = try #require(store.load(key: request.key))
        #expect(loaded.census.extentUnion == census.extentUnion)
        #expect(loaded.census.diagnostics.extentBasis == .available)
    }

    @Test func bundleURLParticipatesInTheSnapshotKey() {
        let root = URL(fileURLWithPath: "/tmp/k3-fingerprint-root")
        let base = StorageCensusRequest(
            roots: [StorageCensusRoot(id: "data", url: root)],
            parentURL: nil,
            metricLabel: "m",
            contextFingerprint: "1"
        )
        let withBundle = StorageCensusRequest(
            roots: [StorageCensusRoot(id: "data", url: root)],
            parentURL: nil,
            metricLabel: "m",
            contextFingerprint: "1",
            bundleURL: URL(fileURLWithPath: "/tmp/k3-fingerprint-bundle")
        )
        #expect(base.key.rootsFingerprint != withBundle.key.rootsFingerprint)
        #expect(base.key.accountingVersion == StorageAccountingVersion.current)
        #expect(StorageAccountingVersion.current.contains("v5"))
    }

    // MARK: - zero-length inodes and in-loop bounds

    @Test func zeroLengthFileWithoutBlocksIsMeasuredAsEmpty() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty.bin")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let measurement = try #require(measuredRuns(empty))
        #expect(measurement.runs.isEmpty)
        #expect(measurement.callCount == 0)
        // A plain empty file must not withhold the basis for the whole scan.
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: root)],
            metricLabel: "test.extent.empty",
            extentProbe: .system
        ).run()
        #expect(census.diagnostics.extentBasis == .available)
        #expect(census.extentUnion?.totalBytes == 0)
    }

    @Test func zeroLengthFileWithAllocatedBlocksFailsClosed() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rsrc = root.appendingPathComponent("zero-length-rsrc.bin")
        FileManager.default.createFile(atPath: rsrc.path, contents: Data())
        let payload = Data(repeating: 0x42, count: 100 * 1024)
        let rc = payload.withUnsafeBytes { raw -> Int32 in
            setxattr(rsrc.path, "com.apple.ResourceFork", raw.baseAddress, raw.count, 0, 0)
        }
        try #require(rc == 0)
        var info = stat()
        try #require(lstat(rsrc.path, &info) == 0)
        // The inode holds real blocks that the data-fork walk cannot reach.
        try #require(info.st_blocks > 0)
        let result = StorageExtentProbeReader.read(
            path: rsrc.path, expectedDevice: nil, expectedInode: nil, isCancelled: { false }
        )
        #expect(result == .failed(.allocationMismatch))

        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: root)],
            metricLabel: "test.extent.zero-rsrc",
            extentProbe: .system
        ).run()
        // Never a published 0: the accepted allocated basis is kept.
        #expect(census.extentUnion == nil)
        #expect(census.diagnostics.extentUnavailableReason == .allocationMismatch)
    }

    @Test func readerEnforcesSnapshotBoundsPerCall() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("bounded.bin", bytes: 1 << 20, at: root)
        let noCalls = StorageExtentProbeReader.read(
            path: file.path, expectedDevice: nil, expectedInode: nil,
            remaining: StorageExtentRemainingBudget(maxCalls: 0, deadline: .distantFuture),
            isCancelled: { false }
        )
        #expect(noCalls == .failed(.budgetExceeded))
        let expired = StorageExtentProbeReader.read(
            path: file.path, expectedDevice: nil, expectedInode: nil,
            remaining: StorageExtentRemainingBudget(maxCalls: 1_000_000, deadline: Date(timeIntervalSinceNow: -1)),
            isCancelled: { false }
        )
        #expect(expired == .failed(.budgetExceeded))
        let cancelled = StorageExtentProbeReader.read(
            path: file.path, expectedDevice: nil, expectedInode: nil,
            remaining: .unbounded,
            isCancelled: { true }
        )
        #expect(cancelled == .failed(.cancelled))
        // A sufficient budget still measures the file.
        let ok = StorageExtentProbeReader.read(
            path: file.path, expectedDevice: nil, expectedInode: nil,
            remaining: StorageExtentRemainingBudget(maxCalls: 8, deadline: Date(timeIntervalSinceNow: 60)),
            isCancelled: { false }
        )
        if case .measured = ok { } else {
            Issue.record("bounded reader should measure within budget, got \(ok)")
        }
    }

    // MARK: - mixed compressed + measured coverage

    private final class ExtentProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ path: String) {
            lock.lock(); paths.append(path); lock.unlock()
        }

        func count(suffix: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return paths.filter { $0.hasSuffix(suffix) }.count
        }

        func contains(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return paths.contains(path)
        }
    }

    /// The Build 347 device case: a migrated iPad has huge runtime/VM images
    /// that share most of their blocks, but one unrelated compressed file made
    /// the all-or-nothing union disappear, so the UI fell back to the raw
    /// allocated sum. The compressed file must now stay a tiny bounded
    /// residual while the large overlapping streams remain exactly deduped.
    @Test func compressedFileKeepsMeasuredPartialCloneUnionBounded() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let linux = root.appendingPathComponent("linux", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let misc = root.appendingPathComponent("misc", isDirectory: true)
        for directory in [linux, runtime, misc] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let disk = try write("disk.img", bytes: 1 << 20, at: linux, seed: 0x11)
        let hard = linux.appendingPathComponent("hard.img")
        #expect(link(disk.path, hard.path) == 0)
        let clone = linux.appendingPathComponent("clone.img")
        guard clonefile(disk.path, clone.path, 0) == 0 else {
            Issue.record("clonefile is required to model a full-clone family")
            return
        }
        // Independent file in another bucket whose runs overlap the disk by
        // half. Its allocated bytes are counted in full by the allocated
        // basis; only the measured union resolves the sharing.
        let view = try write("view.img", bytes: 1 << 20, at: runtime, seed: 0x22)
        let compressed = try write("tiny.plist", bytes: 8_192, at: misc, seed: 0x01)
        let compressedAllocated = allocatedBlockBytes(compressed)
        let diskAllocated = allocatedBlockBytes(disk)
        let viewAllocated = allocatedBlockBytes(view)

        let diskStream: [StoragePhysicalRun] = [
            .init(device: 41, deviceOffset: 1 << 30, length: 1 << 20)
        ]
        let viewStream: [StoragePhysicalRun] = [
            .init(device: 41, deviceOffset: (1 << 30) + 512 * 1024, length: 1 << 20)
        ]
        let log = ExtentProbeLog()
        let probe = StorageExtentProbe { path, _, _, _, _ in
            log.record(path)
            if path.hasSuffix("tiny.plist") { return .failed(.compressedMapping) }
            if path.hasSuffix("view.img") {
                return .measured(StorageExtentMeasurement(runs: viewStream, callCount: 1))
            }
            return .measured(StorageExtentMeasurement(runs: diskStream, callCount: 1))
        }
        let census = try StorageCensus(
            roots: [
                StorageCensusRoot(id: "linuxDisks", url: linux, potentiallyCloned: true),
                StorageCensusRoot(id: "runtimeV2", url: runtime, potentiallyCloned: true),
                StorageCensusRoot(id: "misc", url: misc)
            ],
            metricLabel: "test.extent.mixed",
            extentProbe: probe
        ).run()

        let union = try #require(census.extentUnion)
        #expect(census.diagnostics.extentBasis == .partial)
        #expect(census.diagnostics.extentUnavailableReason == nil)
        #expect(union.isComplete == false)
        // One full 1 MiB stream for the disk family plus the 512 KiB of the
        // independent view that is not physically shared. The hard link and
        // the full clone add no bytes, and the compressed file is only its
        // own allocation.
        #expect(union.measuredBytes == Int64((1 << 20) + 512 * 1024))
        #expect(union.residualBytes == compressedAllocated)
        #expect(union.unmeasuredFileCount == 1)
        #expect(union.firstUnmeasuredReason == .compressedMapping)
        #expect(union.totalBytes == Int64((1 << 20) + 512 * 1024) + compressedAllocated)
        #expect(union.totalBytes < census.totalAllocatedBytes)
        // Identity dedup (hard link) and the exact full-clone family (clone-id
        // SHARES_ALL_BLOCKS) still contribute exactly one measured file. The
        // compressed file is not measured and never becomes a second member.
        #expect(census.diagnostics.dedupedFileCount == 1)
        #expect(census.diagnostics.dedupedCloneFileCount == 1)
        #expect(union.measuredFileCount == 2)
        #expect(log.count(suffix: "tiny.plist") == 1)

        // Category shares on the mixed basis reconcile with the total, and the
        // raw allocated total stays available unchanged.
        #expect(union.categoryBytes.values.reduce(Int64(0), +) + union.unattributedBytes == union.totalBytes)
        let linuxShare = (union.categoryBytes["linuxDisks"] ?? 0)
        let runtimeShare = (union.categoryBytes["runtimeV2"] ?? 0)
        #expect(linuxShare + runtimeShare == Int64((1 << 20) + 512 * 1024))
        #expect(union.categoryBytes["misc"] == compressedAllocated)
        #expect(census.totalAllocatedBytes == diskAllocated + viewAllocated + compressedAllocated)
        #expect(census.totalAllocatedBytes == Int64((2 << 20) + 8_192))

        let report = StorageReportBuilder.build(census: census, bundleBytes: 0)
        #expect(report.totals.basis == .measuredExtents)
        #expect(report.totals.totalBytes == union.totalBytes)
        #expect(report.totals.dataBytes == union.totalBytes)
        let categorySum = report.categories.reduce(Int64(0)) { $0 + $1.basisBytes }
            + (report.unattributed?.basisBytes ?? 0)
        #expect(categorySum == report.totals.dataBytes)
        #expect(report.totalAllocatedBytes == census.totalAllocatedBytes)
    }

    @Test func compressedBundleFileKeepsDataUnionAndBoundsInstallerShare() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data", isDirectory: true)
        let bundle = root.appendingPathComponent("App.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let disk = try write("disk.img", bytes: 1 << 20, at: data)
        let info = try write("Info.plist", bytes: 4_096, at: bundle)
        let infoAllocated = allocatedBlockBytes(info)
        let diskAllocated = allocatedBlockBytes(disk)
        let diskStream: [StoragePhysicalRun] = [
            .init(device: 12, deviceOffset: 8_192, length: 1 << 20)
        ]
        let probe = StorageExtentProbe { path, _, _, _, _ in
            if path.hasSuffix("Info.plist") { return .failed(.compressedMapping) }
            return .measured(StorageExtentMeasurement(runs: diskStream, callCount: 1))
        }
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "documents", url: data)],
            metricLabel: "test.extent.bundle-mixed",
            extentProbe: probe,
            bundleMeasurementURL: bundle
        ).run()

        let union = try #require(census.extentUnion)
        #expect(census.diagnostics.extentBasis == .partial)
        #expect(census.diagnostics.extentUnavailableReason == nil)
        #expect(union.measuredBytes == diskAllocated)
        #expect(union.residualBytes == infoAllocated)
        // The installer share is the measured bundle share (zero new blocks)
        // plus its own bounded residual — never the raw bundle size.
        #expect(union.bundleBytes == infoAllocated)
        #expect(union.totalBytes == diskAllocated + infoAllocated)

        let report = StorageReportBuilder.build(census: census, bundleBytes: 999_999)
        #expect(report.totals.basis == .measuredExtents)
        #expect(report.totals.totalBytes == union.totalBytes)
        #expect(report.totals.bundleBytes == infoAllocated)
        #expect(report.totals.dataBytes == diskAllocated)
        #expect(report.totals.bundleBytes + report.totals.dataBytes == report.totals.totalBytes)
        let categorySum = report.categories.reduce(Int64(0)) { $0 + $1.basisBytes }
            + (report.unattributed?.basisBytes ?? 0)
        #expect(categorySum == report.totals.dataBytes)
    }

    /// A cross-root full clone (bundle resource cloned into user data) is one
    /// physical stream. The bundle pass must not add a second candidate or a
    /// residual for a stream the data walk already counted.
    @Test func bundleCloneOfMeasuredDataFileCountsOneStream() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data", isDirectory: true)
        let bundle = root.appendingPathComponent("App.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let disk = try write("disk.img", bytes: 1 << 20, at: data, seed: 0x66)
        let clone = bundle.appendingPathComponent("disk-clone.img")
        guard clonefile(disk.path, clone.path, 0) == 0 else {
            Issue.record("clonefile is required to model a bundle clone")
            return
        }
        let diskAllocated = allocatedBlockBytes(disk)
        let diskStream: [StoragePhysicalRun] = [
            .init(device: 23, deviceOffset: 1 << 20, length: diskAllocated)
        ]
        let probe = StorageExtentProbe { _, _, _, _, _ in
            .measured(StorageExtentMeasurement(runs: diskStream, callCount: 1))
        }
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: data)],
            metricLabel: "test.extent.bundle-clone",
            extentProbe: probe,
            bundleMeasurementURL: bundle
        ).run()
        let union = try #require(census.extentUnion)
        #expect(census.diagnostics.extentBasis == .available)
        #expect(union.measuredBytes == diskAllocated)
        #expect(union.residualBytes == 0)
        #expect(union.totalBytes == diskAllocated)
        // Whichever owner the union sweep assigns the shared stream to, the
        // total is one stream: never the data file plus the bundle clone.
        #expect((union.bundleBytes ?? 0) + (union.categoryBytes["data"] ?? 0) == diskAllocated)
    }

    /// The size-ordered pass keeps the costly disk measured when the snapshot
    /// budget cannot cover every unrelated small file. Small files that do not
    /// fit become a labelled residual; they never displace the disk.
    @Test func extentPassPrioritizesLargeDisksOverTinyFilesWithinBudget() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let large = root.appendingPathComponent("large", isDirectory: true)
        let small = root.appendingPathComponent("small", isDirectory: true)
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        // Larger than the 8 MiB priority threshold; deliberately deferred.
        let disk = try write("disk.img", bytes: 9 << 20, at: large, seed: 0x33)
        let diskAllocated = allocatedBlockBytes(disk)
        var smallPaths: [String] = []
        for index in 0..<10 {
            let url = try write("tiny-\(index).bin", bytes: 4_096, at: small, seed: 0x44)
            smallPaths.append(url.path)
        }
        let smallAllocated = smallPaths.reduce(Int64(0)) { total, path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return total }
            return total + Int64(info.st_blocks) * 512
        }

        let log = ExtentProbeLog()
        let probe = StorageExtentProbe { path, _, _, _, _ in
            log.record(path)
            let length: Int64 = path.hasSuffix("disk.img") ? Int64(9 << 20) : 4_096
            return .measured(StorageExtentMeasurement(
                runs: [.init(device: 77, deviceOffset: path.hasSuffix("disk.img") ? 0 : 1 << 40,
                             length: length)],
                callCount: 1
            ))
        }
        let census = try StorageCensus(
            roots: [
                StorageCensusRoot(id: "large", url: large, potentiallyCloned: true),
                StorageCensusRoot(id: "small", url: small)
            ],
            metricLabel: "test.extent.priority",
            extentProbe: probe,
            extentBudget: StorageExtentBudget(maxTotalCalls: 4, maxIntervals: 1_000_000, maxDuration: 60)
        ).run()

        let union = try #require(census.extentUnion)
        #expect(census.diagnostics.extentBasis == .partial)
        #expect(log.count(suffix: "disk.img") == 1, "the large disk must be measured")
        #expect(union.categoryBytes["large"] == diskAllocated)
        // At most two inline probes are allowed before the deferred large-file
        // pass (half of the 4-call budget is reserved).
        #expect(smallPaths.filter { log.contains($0) }.count <= 2)
        #expect(union.measuredBytes >= diskAllocated)
        #expect(union.residualBytes > 0)
        #expect(union.unmeasuredFileCount > 0)
        #expect(union.totalBytes == union.measuredBytes + union.residualBytes)
        #expect(union.categoryBytes.values.reduce(Int64(0), +) + union.unattributedBytes == union.totalBytes)
        // The small category is a mixed estimate: a few exact probes plus the
        // bounded residual of the rest.
        #expect((union.categoryBytes["small"] ?? 0) > 0)
        #expect(union.totalBytes <= census.totalAllocatedBytes)
        #expect(union.totalBytes <= diskAllocated + smallAllocated)
    }

    @Test func partialBasisRequiresAtLeastOneMeasuredFile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("only.bin", bytes: 4_096, at: root)
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: root)],
            metricLabel: "test.extent.nothing-measured",
            extentProbe: StorageExtentProbe { _, _, _, _, _ in .failed(.compressedMapping) }
        ).run()
        // Nothing was measured: the accepted allocated basis is kept instead
        // of publishing a "union" that is only an allocation residual.
        #expect(census.extentUnion == nil)
        #expect(census.diagnostics.extentBasis == .unavailable)
        #expect(census.diagnostics.extentUnavailableReason == .compressedMapping)
        let report = StorageReportBuilder.build(census: census, bundleBytes: 5)
        #expect(report.totals.basis == .allocatedEstimate)
        #expect(report.totals.totalBytes == 5 + census.totalAllocatedBytes)
    }

    /// If the FIRST member of a full-clone family is unmeasurable, the later
    /// measured member is still the same stream and must not add its allocated
    /// bytes again. With nothing measurable the snapshot keeps the allocated
    /// fallback, which already deduplicated the family once.
    @Test func unmeasurableFirstCloneMemberDoesNotDoubleSumTheFamily() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let base = try write("base.img", bytes: 256 * 1024, at: first, seed: 0x55)
        let clone = second.appendingPathComponent("clone.img")
        guard clonefile(base.path, clone.path, 0) == 0 else {
            Issue.record("clonefile is required to model a full-clone family")
            return
        }
        let baseAllocated = allocatedBlockBytes(base)
        let probe = StorageExtentProbe { path, _, _, _, _ in
            if path.hasSuffix("base.img") { return .failed(.compressedMapping) }
            return .measured(StorageExtentMeasurement(
                runs: [.init(device: 5, deviceOffset: 4_096, length: baseAllocated)],
                callCount: 1
            ))
        }
        let census = try StorageCensus(
            roots: [
                StorageCensusRoot(id: "first", url: first, potentiallyCloned: true),
                StorageCensusRoot(id: "second", url: second, potentiallyCloned: true)
            ],
            metricLabel: "test.extent.clone-unmeasurable-first",
            extentProbe: probe
        ).run()
        // The later clone is skipped as the same clone stream, so its bytes
        // are not added to the residual either. Nothing was measured, so the
        // allocated fallback is kept and already counts the family once.
        #expect(census.diagnostics.dedupedCloneFileCount == 1)
        #expect(census.diagnostics.dedupedCloneBytes == baseAllocated)
        #expect(census.extentUnion == nil)
        #expect(census.diagnostics.extentBasis == .unavailable)
        #expect(census.diagnostics.extentUnavailableReason == .compressedMapping)
        #expect(census.totalAllocatedBytes == baseAllocated)
    }

    @Test func cancellationDuringTheDeferredLargeFilePassThrows() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Above the priority threshold: measured in the deferred pass.
        try write("disk.img", bytes: 9 << 20, at: root)
        #expect(throws: StorageCensusError.cancelled) {
            _ = try StorageCensus(
                roots: [StorageCensusRoot(id: "data", url: root)],
                metricLabel: "test.extent.priority-cancel",
                extentProbe: StorageExtentProbe { _, _, _, _, _ in .failed(.cancelled) }
            ).run()
        }
    }
}
