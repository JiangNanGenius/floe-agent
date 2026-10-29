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
    /// True when this bucket may include blocks shared with APFS clone
    /// siblings (upper estimate). Counted in full, never subtracted.
    public let isCloneCapable: Bool
    /// The bytes to show for this category on the report's active basis:
    /// the owned share of the measured extent union when available, otherwise
    /// ``allocatedBytes``. Never a mix of the two.
    public let basisBytes: Int64

    public init(
        id: String,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        fileCount: Int,
        isCloneCapable: Bool,
        basisBytes: Int64? = nil
    ) {
        self.id = id
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.isCloneCapable = isCloneCapable
        self.basisBytes = max(0, basisBytes ?? allocatedBytes)
    }

    /// Backwards-compatible name for the clone-capable flag.
    public var isSharedEstimate: Bool { isCloneCapable }

    /// True when host-allocated is well below apparent capacity (sparse disk).
    public func showsLogicalCapacity(deltaThreshold: Int64 = 16 * 1024 * 1024) -> Bool {
        logicalBytes > allocatedBytes + deltaThreshold
    }
}

/// Which measurement the report's totals and per-category figures are on.
/// Exactly one basis is active per report; the two are never mixed or
/// subtracted from one another.
public enum StorageTotalBasis: String, Sendable, Equatable, Codable {
    /// Measured physical block union (public `fcntl F_LOG2PHYS_EXT`): clone,
    /// partial-clone and hard-link blocks are counted once and the union is
    /// reconciled against `st_blocks`. Excludes filesystem metadata and
    /// snapshot-only blocks, so it is the measured APP-FILE footprint, not
    /// the number iOS Storage accounts for.
    case measuredExtents
    /// Accepted allocated-size basis (identity dedup + exact full-clone
    /// dedup): an honest upper estimate while any clone sharing remains
    /// unmeasured.
    case allocatedEstimate
}

/// Mutually-exclusive overview totals on ONE basis. On ``measuredExtents``,
/// `bundleBytes` is the installed bundle's owned share of the same union and
/// `bundleBytes + dataBytes == totalBytes`; on ``allocatedEstimate`` the
/// values keep the accepted installer + allocated semantics.
public struct StorageReportTotals: Sendable, Equatable {
    public let basis: StorageTotalBasis
    public let totalBytes: Int64
    public let bundleBytes: Int64
    public let dataBytes: Int64

    public init(basis: StorageTotalBasis, totalBytes: Int64, bundleBytes: Int64, dataBytes: Int64) {
        self.basis = basis
        self.totalBytes = max(0, totalBytes)
        self.bundleBytes = max(0, bundleBytes)
        self.dataBytes = max(0, dataBytes)
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
    /// Allocated bytes inside clone-capable buckets. Counted in full in the
    /// total, but they may share APFS clone blocks with other data: an
    /// explicit non-additive estimate, never silently subtracted or re-labelled
    /// as an "exclusive" footprint (unflagged buckets are not proven
    /// exclusive either).
    public let cloneCapableAllocatedBytes: Int64
    /// Allocated bytes removed by the exact full-clone-stream dedup
    /// (same clone-id, SHARES_ALL_BLOCKS): measured, not estimated.
    public let dedupedCloneBytes: Int64
    /// Measured lower bound of the physical footprint (sum of APFS private
    /// bytes, which exclude blocks trapped in clones/snapshots). Nil when the
    /// extended query was unavailable, partially failed, or not requested.
    public let measuredExclusiveLowerBoundBytes: Int64?
    /// Whether measured clone attributes were collected in this scan.
    public let cloneAttributeSupport: StorageCloneAttributeSupport
    public let scanErrorCount: Int
    public let changedOrVanishedCount: Int
    /// Files whose allocated size could not be measured (never substituted
    /// with logical size); the totals are a lower/uncertain bound.
    public let allocatedUnavailableCount: Int
    /// Files whose identity could not be read; they cannot participate in
    /// dedup and are counted with an uncertainty flag.
    public let identityUnavailableCount: Int
    public let scanDuration: TimeInterval
    public let metricLabel: String
    /// When the scan finished (measured, not the render time).
    public let generatedAt: Date
    /// Regular files visited by the census (measured progress figure).
    public let filesScanned: Int
    /// The coherent overview totals on the active basis (measured extents
    /// when available, otherwise the accepted allocated estimate). The
    /// per-category ``StorageReportCategory/basisBytes`` and the unattributed
    /// figure always reconcile with these totals on the same basis.
    public let totals: StorageReportTotals

    /// True when the numeric totals are the measured extent union.
    public var usesMeasuredExtents: Bool { totals.basis == .measuredExtents }

    /// The measured union total when the extent basis was collected; nil when
    /// the snapshot kept the allocated basis.
    public var measuredExtentTotalBytes: Int64? {
        usesMeasuredExtents ? totals.totalBytes : nil
    }

    public var combinedBytes: Int64 { bundleBytes + totalAllocatedBytes }

    /// True when some measurement was unavailable or entries could not be
    /// read: the UI must label the numbers as partial instead of presenting
    /// them as exact.
    public var isPartial: Bool {
        scanErrorCount > 0 || allocatedUnavailableCount > 0 || identityUnavailableCount > 0
    }

    /// True when the measured file totals include data that may share APFS
    /// clone blocks. In this case the sum must NOT be presented as the app's
    /// accounted footprint; the UI leads with the system-accounted value and
    /// keeps these file figures under non-additive capacity details.
    public var hasSharedEstimates: Bool {
        isSharedAllocationEstimate || cloneCapableAllocatedBytes > 0
    }
}

public enum StorageReportBuilder {
    public static func build(
        census: StorageCensusReport,
        bundleBytes: Int64,
        categoryIDs: Set<String>? = nil
    ) -> StorageReport {
        let includedIDs = categoryIDs ?? Set(census.buckets.map(\.id))
        // The measured extent union, when the snapshot collected one, decides
        // the active basis. Its per-bucket ownership shares already reconcile
        // with its total, so categories and totals stay on ONE basis.
        let extentUnion = census.extentUnion
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
                    isCloneCapable: bucket.isCloneCapable || bucket.attribution == .shared,
                    basisBytes: extentUnion.map { $0.categoryBytes[bucket.id] ?? 0 }
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
                isCloneCapable: false,
                basisBytes: extentUnion?.unattributedBytes
            )
        }

        let totals: StorageReportTotals
        if let extentUnion {
            // Same basis everywhere: the installer share and every category
            // are owned slices of ONE measured union, so a cross-root clone
            // between the bundle and user data is counted exactly once.
            let bundleShare = extentUnion.bundleBytes ?? 0
            totals = StorageReportTotals(
                basis: .measuredExtents,
                totalBytes: extentUnion.totalBytes,
                bundleBytes: bundleShare,
                dataBytes: extentUnion.totalBytes - bundleShare
            )
        } else {
            totals = StorageReportTotals(
                basis: .allocatedEstimate,
                totalBytes: bundleBytes + census.totalAllocatedBytes,
                bundleBytes: bundleBytes,
                dataBytes: census.totalAllocatedBytes
            )
        }

        return StorageReport(
            bundleBytes: bundleBytes,
            categories: categories,
            unattributed: unattributed,
            totalAllocatedBytes: census.totalAllocatedBytes,
            totalLogicalBytes: census.totalLogicalBytes,
            isSharedAllocationEstimate: census.isSharedAllocationEstimate
                || census.buckets.contains { $0.isCloneCapable || $0.attribution == .shared },
            cloneCapableAllocatedBytes: census.cloneCapableAllocatedBytes,
            dedupedCloneBytes: census.diagnostics.dedupedCloneBytes,
            measuredExclusiveLowerBoundBytes: census.measuredExclusiveLowerBoundBytes,
            cloneAttributeSupport: census.diagnostics.cloneAttributeSupport,
            scanErrorCount: census.diagnostics.errorCount,
            changedOrVanishedCount: census.diagnostics.changedOrVanishedCount,
            allocatedUnavailableCount: census.diagnostics.allocatedUnavailableCount,
            identityUnavailableCount: census.diagnostics.identityUnavailableCount,
            scanDuration: census.diagnostics.duration,
            metricLabel: census.diagnostics.metricLabel,
            generatedAt: census.diagnostics.completedAt,
            filesScanned: census.diagnostics.regularFileCount,
            totals: totals
        )
    }
}
