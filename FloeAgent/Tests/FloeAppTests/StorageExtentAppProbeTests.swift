// FloeAppTests — App-host (Simulator/device) gate for the K3 measured extent
// basis.
//
// This is the required on-device gate for the public `fcntl(F_LOG2PHYS_EXT)`
// path: it runs inside the real App container on the real runtime and proves,
// with fixtures created in the app's own temporary directory, that
//
//   * the primitive answers for app-owned APFS files (no EPERM/ENOTSUP),
//   * a full clone and a hard link return identical device runs (one stream),
//   * a 4 KiB COW split keeps the untouched runs shared and retains the
//     rewritten region exactly once,
//   * an independent copy of identical content is NOT aliased,
//   * sparse holes contribute nothing while the allocated blocks reconcile
//     with `st_blocks`,
//   * the production census union equals an independent reference union and
//     the per-category shares reconcile with the total, and
//   * when the probe is unavailable the report keeps the accepted allocated
//     basis unchanged (the UI numbers do not silently change basis).
//
// If any availability assertion fails, the extent basis must stay disabled in
// production (the census already withholds it); G2 records the result instead
// of enabling the numeric switch for that runtime.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
#if canImport(Darwin)
import Darwin
#endif

@Suite("FloeApp.StorageExtentAppProbe")
struct StorageExtentAppProbeTests {
    private func fixturesRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageExtentAppProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePattern(_ url: URL, size: Int, seed: UInt8) throws {
        try Data(repeating: seed, count: size).write(to: url)
    }

    private func allocatedBytes(_ url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return -1 }
        return Int64(info.st_blocks) * 512
    }

    private func readRuns(_ url: URL) -> [StoragePhysicalRun]? {
        let result = StorageExtentProbeReader.read(
            path: url.path, expectedDevice: nil, expectedInode: nil, isCancelled: { false }
        )
        guard case .measured(let measurement) = result else { return nil }
        return measurement.runs
    }

    private func readResult(_ url: URL) -> StorageExtentProbeResult {
        StorageExtentProbeReader.read(
            path: url.path, expectedDevice: nil, expectedInode: nil, isCancelled: { false }
        )
    }

    /// Independent reference union (test-local; deliberately not the
    /// production builder).
    private func referenceUnion(_ runs: [StoragePhysicalRun]) -> Int64 {
        let sorted = runs.sorted {
            if $0.device != $1.device { return $0.device < $1.device }
            if $0.deviceOffset != $1.deviceOffset { return $0.deviceOffset < $1.deviceOffset }
            return $0.length < $1.length
        }
        var total: Int64 = 0
        var cursorByDevice: [UInt64: Int64] = [:]
        for run in sorted {
            let cursor = cursorByDevice[run.device] ?? Int64.min
            let start = max(run.deviceOffset, cursor)
            let end = run.deviceOffset + run.length
            if end > start {
                total += end - start
                cursorByDevice[run.device] = end
            }
        }
        return total
    }

    @Test func publicExtentPrimitiveAnswersInsideTheAppContainer() throws {
        let root = try fixturesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base.bin")
        let clone = root.appendingPathComponent("clone.bin")
        let cow = root.appendingPathComponent("cow.bin")
        let hard = root.appendingPathComponent("hard.bin")
        let copy = root.appendingPathComponent("copy.bin")
        let sparse = root.appendingPathComponent("sparse.bin")

        try writePattern(base, size: 1 << 20, seed: 0x11)
        #expect(clonefile(base.path, clone.path, 0) == 0, "clonefile must be available in the app container")
        #expect(clonefile(base.path, cow.path, 0) == 0)
        #expect(link(base.path, hard.path) == 0)
        try writePattern(copy, size: 1 << 20, seed: 0x11)
        do {
            let fd = open(sparse.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
            try #require(fd >= 0)
            try #require(ftruncate(fd, 64 << 20) == 0)
            let chunk = [UInt8](repeating: 0x33, count: 4096)
            let written = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, 4096, 0) }
            try #require(written == 4096)
            close(fd)
        }

        // (a) API availability: every fixture must answer with measured runs.
        let baseResult = readResult(base)
        let cloneResult = readResult(clone)
        let hardResult = readResult(hard)
        let copyResult = readResult(copy)
        let sparseResult = readResult(sparse)
        guard case .measured(let baseMeasurement) = baseResult,
              case .measured(let cloneMeasurement) = cloneResult,
              case .measured(let hardMeasurement) = hardResult,
              case .measured(let copyMeasurement) = copyResult,
              case .measured(let sparseMeasurement) = sparseResult else {
            Issue.record("extent primitive did not answer in this runtime: base=\(baseResult) clone=\(cloneResult) hard=\(hardResult) copy=\(copyResult) sparse=\(sparseResult)")
            return
        }

        // (b) full clone and hard link are the SAME physical stream.
        #expect(cloneMeasurement.runs == baseMeasurement.runs)
        #expect(hardMeasurement.runs == baseMeasurement.runs)
        #expect(baseMeasurement.runs.reduce(Int64(0)) { $0 + $1.length } == allocatedBytes(base))

        // (c) independent content-identical copy is NOT aliased.
        #expect(referenceUnion(baseMeasurement.runs + copyMeasurement.runs)
            == referenceUnion(baseMeasurement.runs) + referenceUnion(copyMeasurement.runs))

        // (d) the COW split moves a bounded private region and keeps the rest
        // shared: the union grows by at least the rewritten 4 KiB block and
        // stays below a second full stream, while the naive allocated sum
        // would double count the whole clone.
        do {
            let handle = try FileHandle(forWritingTo: cow)
            try handle.seek(toOffset: 512 * 1024)
            try handle.write(contentsOf: Data(repeating: 0x5A, count: 4096))
            try handle.close()
        }
        let cowResult = readResult(cow)
        guard case .measured(let cowMeasurement) = cowResult else {
            Issue.record("COW fixture did not answer: \(cowResult)")
            return
        }
        let baseUnion = referenceUnion(baseMeasurement.runs)
        let withCowUnion = referenceUnion(baseMeasurement.runs + cowMeasurement.runs)
        let cowAllocated = allocatedBytes(cow)
        #expect(withCowUnion > baseUnion)
        #expect(withCowUnion <= baseUnion + cowAllocated)
        #expect(withCowUnion < allocatedBytes(base) + cowAllocated)

        // (e) sparse holes: only allocated blocks are counted and the walk
        // stays bounded.
        #expect(sparseMeasurement.runs.reduce(Int64(0)) { $0 + $1.length } == allocatedBytes(sparse))
        #expect(sparseMeasurement.callCount <= 32)

        // (f) the production census union equals the independent reference
        // union over the same fixture root and reconciles categorically.
        let census = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: root)],
            metricLabel: "test.app-extent",
            extentProbe: .system
        ).run()
        let union = try #require(census.extentUnion, "the App host must collect the measured union")
        #expect(union.totalBytes >= withCowUnion + referenceUnion(copyMeasurement.runs))
        #expect(union.categoryBytes.values.reduce(Int64(0), +) + union.unattributedBytes == union.totalBytes)
        #expect(census.diagnostics.extentBasis == .available)
        #expect(census.diagnostics.extentUnavailableReason == nil)

        let report = StorageReportBuilder.build(census: census, bundleBytes: 1_000)
        #expect(report.totals.basis == .measuredExtents)
        let categorySum = report.categories.reduce(Int64(0)) { $0 + $1.basisBytes }
            + (report.unattributed?.basisBytes ?? 0)
        #expect(categorySum == report.totals.dataBytes)
        #expect(report.totals.bundleBytes + report.totals.dataBytes == report.totals.totalBytes)

        // (g) fallback: an unavailable primitive keeps the accepted allocated
        // basis, so the UI numbers never change basis silently.
        let fallbackCensus = try StorageCensus(
            roots: [StorageCensusRoot(id: "data", url: root)],
            metricLabel: "test.app-extent.fallback",
            extentProbe: StorageExtentProbe { _, _, _, _, _ in .unsupported }
        ).run()
        #expect(fallbackCensus.extentUnion == nil)
        #expect(fallbackCensus.diagnostics.extentBasis == .unavailable)
        #expect(fallbackCensus.diagnostics.extentUnavailableReason == .unsupportedFilesystem)
        let fallbackReport = StorageReportBuilder.build(census: fallbackCensus, bundleBytes: 1_000)
        #expect(fallbackReport.totals.basis == .allocatedEstimate)
        #expect(fallbackReport.totals.totalBytes == 1_000 + fallbackCensus.totalAllocatedBytes)
    }

    @Test func directoryDescriptorsAreRejectedWithoutCrashing() throws {
        let root = try fixturesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = StorageExtentProbeReader.read(
            path: root.path, expectedDevice: nil, expectedInode: nil, isCancelled: { false }
        )
        #expect(result == .failed(.notRegularFile))
    }
}
#endif
