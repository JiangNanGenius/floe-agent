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
        sharedSize: StorageSize = .zero,
        isCloneCapable: Bool = false
    ) -> StorageCensusBucket {
        StorageCensusBucket(
            id: id,
            attribution: attribution,
            exists: true,
            size: StorageSize(logicalBytes: logical, allocatedBytes: allocated),
            fileCount: files,
            sharedSize: sharedSize,
            isCloneCapable: isCloneCapable
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

        // Categories list every measured bucket exactly once (including
        // caches/tmp), so they reconcile with the total.
        let categoryIDs = report.categories.map(\.id)
        #expect(categoryIDs.contains("caches"))
        #expect(categoryIDs.contains("temporary"))
        #expect(categoryIDs.contains("models"))
        #expect(categoryIDs.contains("runtimeV2"))
        let categoryTotal = report.categories.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        #expect(categoryTotal == 430)
        #expect(categoryTotal + (report.unattributed?.allocatedBytes ?? 0) == report.totalAllocatedBytes)

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

    @Test func cloneCapableBucketsAreReportedNonAdditively() {
        // Clone-capable buckets are counted in full (no silent subtraction)
        // and flagged, so the UI keeps them out of the app-footprint claim.
        let census = StorageCensusReport(
            buckets: [
                bucket("models", logical: 100, allocated: 100),
                bucket("environments", logical: 200, allocated: 200, isCloneCapable: true),
                bucket("runtimeV2", logical: 50, allocated: 50,
                       attribution: .shared, isCloneCapable: true)
            ],
            diagnostics: StorageScanDiagnostics(regularFileCount: 3, metricLabel: "t"),
            unattributedSize: .zero,
            unattributedCount: 0,
            isSharedAllocationEstimate: true
        )

        let report = StorageReportBuilder.build(census: census, bundleBytes: 10)

        #expect(report.totalAllocatedBytes == 350)          // full, additive
        #expect(report.cloneCapableAllocatedBytes == 250)   // flagged portion
        #expect(report.isSharedAllocationEstimate == true)
        #expect(report.hasSharedEstimates == true)
        #expect(report.dedupedCloneBytes == 0)
        // No subtractive "exclusive" figure is derived from the flags.
        #expect(report.measuredExclusiveLowerBoundBytes == nil)
        #expect(report.categories.first { $0.id == "environments" }?.isCloneCapable == true)
        #expect(report.categories.first { $0.id == "runtimeV2" }?.isCloneCapable == true)
        #expect(report.categories.first { $0.id == "models" }?.isCloneCapable == false)
        // The clone-capable flag is not a subtraction: categories still sum to
        // the total exactly.
        let categoryTotal = report.categories.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        #expect(categoryTotal == report.totalAllocatedBytes)
    }

    @Test func measuredCloneFiguresAreExposedWhenSupported() {
        let census = StorageCensusReport(
            buckets: [
                bucket("linuxDisks", logical: 300, allocated: 200, files: 2, isCloneCapable: true)
            ],
            diagnostics: StorageScanDiagnostics(
                regularFileCount: 2,
                dedupedCloneFileCount: 1,
                dedupedCloneBytes: 100,
                cloneAttributeFileCount: 2,
                cloneAttributeSupport: .supported,
                measuredPrivateBytes: 120,
                metricLabel: "t"
            ),
            unattributedSize: .zero,
            unattributedCount: 0,
            isSharedAllocationEstimate: true
        )
        let report = StorageReportBuilder.build(census: census, bundleBytes: 0)
        #expect(report.dedupedCloneBytes == 100)
        #expect(report.measuredExclusiveLowerBoundBytes == 120)
        #expect(report.cloneAttributeSupport == .supported)

        // A partial query failure withholds the bound instead of showing an
        // incomplete sum as one.
        let partial = StorageCensusReport(
            buckets: census.buckets,
            diagnostics: StorageScanDiagnostics(
                regularFileCount: 2,
                cloneAttributeFileCount: 2,
                cloneAttributeFailureCount: 1,
                cloneAttributeSupport: .supported,
                measuredPrivateBytes: 120,
                metricLabel: "t"
            ),
            unattributedSize: .zero,
            unattributedCount: 0,
            isSharedAllocationEstimate: true
        )
        let partialReport = StorageReportBuilder.build(census: partial, bundleBytes: 0)
        #expect(partialReport.measuredExclusiveLowerBoundBytes == nil)
    }

    @Test func partialMeasurementFlagsAreSurfacedNotHidden() {
        let census = StorageCensusReport(
            buckets: [bucket("models", logical: 100, allocated: 100)],
            diagnostics: StorageScanDiagnostics(
                regularFileCount: 1,
                errorCount: 2,
                identityUnavailableCount: 1,
                allocatedUnavailableCount: 3,
                metricLabel: "t"
            ),
            unattributedSize: .zero,
            unattributedCount: 0,
            isSharedAllocationEstimate: false
        )
        let report = StorageReportBuilder.build(census: census, bundleBytes: 0)
        #expect(report.isPartial == true)
        #expect(report.scanErrorCount == 2)
        #expect(report.allocatedUnavailableCount == 3)
        #expect(report.identityUnavailableCount == 1)
        // Totals are still the measured bytes; they are a lower bound, and the
        // UI labels them as partial instead of zero-as-success.
        #expect(report.totalAllocatedBytes == 100)
    }
}
