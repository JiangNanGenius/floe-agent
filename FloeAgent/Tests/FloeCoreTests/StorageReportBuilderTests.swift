import Foundation
import Testing
@testable import FloeCore

@Suite("Storage report builder")
struct StorageReportBuilderTests {
    private func bucket(
        _ id: String,
        logical: Int64,
        allocated: Int64,
        files: Int = 1,
        attribution: StorageCensusRoot.Attribution = .category,
        sharedSize: StorageSize = .zero
    ) -> StorageCensusBucket {
        StorageCensusBucket(
            id: id,
            attribution: attribution,
            exists: true,
            size: StorageSize(logicalBytes: logical, allocatedBytes: allocated),
            fileCount: files,
            sharedSize: sharedSize
        )
    }

    @Test func eachBucketIsCountedExactlyOnceIncludingCaches() {
        let census = StorageCensusReport(
            buckets: [
                bucket("models", logical: 100, allocated: 100),
                bucket("caches", logical: 200, allocated: 200),
                bucket("temporary", logical: 50, allocated: 50),
                bucket("runtimeV2", logical: 80, allocated: 80, attribution: .shared)
            ],
            diagnostics: StorageScanDiagnostics(regularFileCount: 4, duration: 0.1, metricLabel: "t"),
            unattributedSize: StorageSize(logicalBytes: 25, allocatedBytes: 25),
            unattributedCount: 1,
            isSharedAllocationEstimate: true
        )

        let report = StorageReportBuilder.build(census: census, bundleBytes: 10)

        // Total = every bucket once + unattributed. Caches/tmp are included in
        // the total even though they are not listed as categories.
        #expect(report.totalAllocatedBytes == 100 + 200 + 50 + 80 + 25)
        #expect(report.combinedBytes == 10 + report.totalAllocatedBytes)

        // Categories list excludes caches/tmp; they are not double counted.
        let categoryIDs = report.categories.map(\.id)
        #expect(!categoryIDs.contains("caches"))
        #expect(!categoryIDs.contains("temporary"))
        #expect(categoryIDs.contains("models"))
        #expect(categoryIDs.contains("runtimeV2"))
        let categoryTotal = report.categories.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        #expect(categoryTotal == 180)

        // Shared bucket is flagged, not subtracted.
        #expect(report.categories.first { $0.id == "runtimeV2" }?.isSharedEstimate == true)
        #expect(report.isSharedAllocationEstimate == true)
        #expect(report.unattributed?.allocatedBytes == 25)
    }

    @Test func sparseCapacityIsSurfacedPerCategory() {
        let capacity: Int64 = 16 * 1024 * 1024 * 1024
        let allocated: Int64 = 512 * 1024 * 1024
        let census = StorageCensusReport(
            buckets: [bucket("linuxDisks", logical: capacity, allocated: allocated)],
            diagnostics: StorageScanDiagnostics(metricLabel: "t"),
            unattributedSize: .zero,
            unattributedCount: 0,
            isSharedAllocationEstimate: false
        )
        let report = StorageReportBuilder.build(census: census, bundleBytes: 0)
        let category = report.categories.first { $0.id == "linuxDisks" }
        #expect(category?.showsLogicalCapacity() == true)
        #expect(category?.logicalBytes == capacity)
        #expect(category?.allocatedBytes == allocated)
        #expect(report.isSharedAllocationEstimate == false)
    }

    @Test func emptyCensusProducesZeroTotals() {
        let census = StorageCensusReport(
            buckets: [],
            diagnostics: StorageScanDiagnostics(metricLabel: "t"),
            unattributedSize: .zero,
            unattributedCount: 0,
            isSharedAllocationEstimate: false
        )
        let report = StorageReportBuilder.build(census: census, bundleBytes: 42)
        #expect(report.totalAllocatedBytes == 0)
        #expect(report.combinedBytes == 42)
        #expect(report.categories.isEmpty)
        #expect(report.unattributed == nil)
    }
}
