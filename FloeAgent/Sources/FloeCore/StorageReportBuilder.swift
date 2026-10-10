import Foundation

// FloeCore — Storage report transformation.
//
// Pure mapping from a `StorageCensusReport` to the app-facing totals. Kept in
// FloeCore (not the app) so the arithmetic is unit-tested: a bucket must be
// counted exactly once, "shared"/clone-backed buckets are counted in full (only
// flagged), and rebuildable caches/tmp appear in the total but are not listed as
// user-data categories.

public struct StorageReportCategory: Sendable, Equatable, Identifiable {
    public let id: String
    /// Host-allocated bytes (sparse-aware).
    public let allocatedBytes: Int64
    /// Apparent/logical bytes (configured capacity for sparse VM disks).
    public let logicalBytes: Int64
    public let fileCount: Int
    /// True when this bucket may include blocks shared with clone siblings
    /// (upper estimate), never subtracted.
    public let isSharedEstimate: Bool

    public init(id: String, allocatedBytes: Int64, logicalBytes: Int64, fileCount: Int, isSharedEstimate: Bool) {
        self.id = id
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.isSharedEstimate = isSharedEstimate
    }

    /// True when host-allocated is well below apparent capacity (sparse disk).
    public func showsLogicalCapacity(deltaThreshold: Int64 = 16 * 1024 * 1024) -> Bool {
        logicalBytes > allocatedBytes + deltaThreshold
    }
}

public struct StorageReport: Sendable, Equatable {
    public let bundleBytes: Int64
    public let categories: [StorageReportCategory]
    public let unattributed: StorageReportCategory?
    /// Every measured bucket + unattributed, counted exactly once.
    public let totalAllocatedBytes: Int64
    public let totalLogicalBytes: Int64
    /// Buckets that are potentially clone-backed anywhere in the scan.
    public let isSharedAllocationEstimate: Bool
    public let scanErrorCount: Int
    public let changedOrVanishedCount: Int
    public let scanDuration: TimeInterval
    public let metricLabel: String
    /// When the scan finished (measured, not the render time).
    public let generatedAt: Date
    /// Regular files visited by the census (measured progress figure).
    public let filesScanned: Int

    public var combinedBytes: Int64 { bundleBytes + totalAllocatedBytes }
}

public enum StorageReportBuilder {
    public static func build(
        census: StorageCensusReport,
        bundleBytes: Int64,
        categoryIDs: Set<String>? = nil
    ) -> StorageReport {
        let includedIDs = categoryIDs ?? Set(census.buckets.map(\.id))
        // Every measured bucket is listed as its own mutually exclusive category
        // (including caches/tmp) so the displayed categories reconcile with the
        // total. The eligible-cleanup figure is computed separately from the
        // cleanup plan and is a subset of what is shown here.
        var categories: [StorageReportCategory] = []
        for bucket in census.buckets where includedIDs.contains(bucket.id) {
            guard bucket.exists || bucket.size.allocatedBytes > 0 || bucket.size.logicalBytes > 0 else { continue }
            categories.append(
                StorageReportCategory(
                    id: bucket.id,
                    allocatedBytes: bucket.size.allocatedBytes,
                    logicalBytes: bucket.size.logicalBytes,
                    fileCount: bucket.fileCount,
                    isSharedEstimate: bucket.attribution == .shared
                )
            )
        }

        var unattributed: StorageReportCategory?
        if census.unattributedCount > 0 || census.unattributedSize.allocatedBytes > 0 {
            unattributed = StorageReportCategory(
                id: "unattributed",
                allocatedBytes: census.unattributedSize.allocatedBytes,
                logicalBytes: census.unattributedSize.logicalBytes,
                fileCount: census.unattributedCount,
                isSharedEstimate: false
            )
        }

        return StorageReport(
            bundleBytes: bundleBytes,
            categories: categories,
            unattributed: unattributed,
            totalAllocatedBytes: census.totalAllocatedBytes,
            totalLogicalBytes: census.totalLogicalBytes,
            isSharedAllocationEstimate: census.isSharedAllocationEstimate
                || census.buckets.contains { $0.attribution == .shared },
            scanErrorCount: census.diagnostics.errorCount,
            changedOrVanishedCount: census.diagnostics.changedOrVanishedCount,
            scanDuration: census.diagnostics.duration,
            metricLabel: census.diagnostics.metricLabel,
            generatedAt: census.diagnostics.completedAt,
            filesScanned: census.diagnostics.regularFileCount
        )
    }
}
