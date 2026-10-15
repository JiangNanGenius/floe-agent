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
        #expect(StorageAccountingVersion.current.contains("v4"))
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
}
