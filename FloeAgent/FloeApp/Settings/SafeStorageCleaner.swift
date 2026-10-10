// FloeApp — Ownership-aware safe cleanup.
//
// The legacy cleaner did a blanket "delete every child of Caches/ and any tmp
// file older than an hour". That ignores active downloads/editors and reports
// summed file sizes as reclaimed space, which is wrong on APFS when files share
// cloned blocks. This cleaner:
//
// 1. Builds explicit *plans* backed by Floe-owned, regenerable locations, each
//    with a purpose, an estimate and the reason it is safe to remove.
// 2. Re-checks references/activity at execution time (active environment,
//    running download/export, recently-modified scratch) and skips busy items.
// 3. Never deletes environment/VM disks, drafts/history, adopted/shared assets,
//    user fonts or downloaded models — those are not regenerable caches.
// 4. Reports per-candidate deleted/skipped/failed counts and measures the actual
//    allocated-byte delta of the cleaned roots (not the summed file sizes).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore

/// A live-activity probe consulted immediately before deleting anything.
public protocol StorageCleanupAuthority: Sendable {
    /// True when a VM/environment is running.
    func isEnvironmentActive() -> Bool
    /// True when a download/import/export/generation is in progress.
    func isTransferOrExportActive() -> Bool
    /// IDs (file/directory names) that must be retained because an editor or
    /// task owns them right now.
    func retainedNames() -> Set<String>
}

/// A no-op authority for tests and for callers that only have filesystem rules.
public struct NullStorageCleanupAuthority: StorageCleanupAuthority {
    public init() {}
    public func isEnvironmentActive() -> Bool { false }
    public func isTransferOrExportActive() -> Bool { false }
    public func retainedNames() -> Set<String> { [] }
}

public enum StorageCleanupCandidateKind: String, Sendable {
    /// Rebuildable on-disk cache directory content (safe to regenerate).
    case cache
    /// Stale scratch in tmp beyond an age cutoff.
    case staleTemporary
}

/// One group of files the cleaner may remove.
public struct StorageCleanupCandidate: Sendable {
    public let id: String
    public let title: String
    public let purpose: String
    public let retentionReason: String
    public let kind: StorageCleanupCandidateKind
    public let root: URL
    /// Only remove children older than this. nil removes regardless of age but
    /// the activity recheck still applies.
    public let olderThan: Date?
    /// Names that are always protected even without the authority probe.
    public let protectedNames: Set<String>

    public init(
        id: String,
        title: String,
        purpose: String,
        retentionReason: String,
        kind: StorageCleanupCandidateKind,
        root: URL,
        olderThan: Date? = nil,
        protectedNames: Set<String> = []
    ) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.retentionReason = retentionReason
        self.kind = kind
        self.root = root.standardizedFileURL
        self.olderThan = olderThan
        self.protectedNames = protectedNames
    }
}

public struct StorageCleanupItemResult: Sendable {
    public var deletedCount = 0
    public var skippedActiveCount = 0
    public var skippedProtectedCount = 0
    public var failedCount = 0
    /// Summed *logical* size of deleted items (an upper estimate, not the
    /// measured volume reclaim — see `measuredReclaimedAllocatedBytes`).
    public var deletedLogicalBytes: Int64 = 0
}

public struct StorageCleanupPlanResult: Sendable {
    public let candidates: [StorageCleanupCandidate]
    public var perCandidate: [String: StorageCleanupItemResult]
    public var wasCancelled: Bool
    /// Allocated-byte delta measured across the cleaned roots before vs after.
    /// This is the honest reclaimed figure on a clone/sparse filesystem.
    public var measuredReclaimedAllocatedBytes: Int64
}

public enum StorageCleanup {
    /// The safe, Floe-owned default plan. Roots are the app sandbox Caches/ and
    /// tmp/ only — never environment disks, assets, canvases, drafts or models.
    public static func defaultPlan(
        caches: URL?,
        temporary: URL,
        now: Date = Date(),
        temporaryAge: TimeInterval = 3_600
    ) -> [StorageCleanupCandidate] {
        var plan: [StorageCleanupCandidate] = []
        if let caches {
            plan.append(
                StorageCleanupCandidate(
                    id: "caches",
                    title: FloeL10n.l("settings.data_management_view.rebuildable_caches"),
                    purpose: FloeL10n.l("settings.data_management_view.caches_regenerated_on_demand"),
                    retentionReason: FloeL10n.l("settings.data_management_view.active_downloads_are_skipped"),
                    kind: .cache,
                    root: caches,
                    olderThan: nil
                )
            )
        }
        plan.append(
            StorageCleanupCandidate(
                id: "staleTemporary",
                title: FloeL10n.l("settings.data_management_view.temporary_files_older_than_one_hour"),
                purpose: FloeL10n.l("settings.data_management_view.finished_scratch_left_in_temporary"),
                retentionReason: FloeL10n.l("settings.data_management_view.recent_and_active_scratch_is_kept"),
                kind: .staleTemporary,
                root: temporary,
                olderThan: now.addingTimeInterval(-temporaryAge)
            )
        )
        return plan
    }

    /// Estimate the allocated bytes a plan *could* reclaim (pre-flight; does not
    /// delete). Busy/protected items are included in the raw walk but callers
    /// should label this as an upper estimate.
    public static func estimateAllocatedBytes(_ plan: [StorageCleanupCandidate]) -> Int64 {
        let census = StorageCensus(
            roots: plan.map { StorageCensusRoot(id: $0.id, url: $0.root) },
            metricLabel: "storage.cleanup.estimate"
        )
        guard let report = try? census.run() else { return 0 }
        return report.buckets.reduce(Int64(0)) { $0 + $1.size.allocatedBytes }
    }

    /// Execute the plan, rechecking ownership/activity immediately before each
    /// removal. Cancellation is honoured between items.
    public static func execute(
        plan: [StorageCleanupCandidate],
        authority: StorageCleanupAuthority = NullStorageCleanupAuthority(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> StorageCleanupPlanResult {
        let manager = FileManager.default
        let roots = plan.map { StorageCensusRoot(id: $0.id, url: $0.root) }
        let before = (try? StorageCensus(roots: roots, metricLabel: "storage.cleanup.before").run())
            .buckets.reduce(into: [String: Int64]()) { $0[$1.id] = $1.size.allocatedBytes } ?? [:]

        let environmentActive = authority.isEnvironmentActive()
        let transferActive = authority.isTransferOrExportActive()
        let retained = authority.retainedNames()

        var perCandidate: [String: StorageCleanupItemResult] = [:]
        var cancelled = false

        for candidate in plan {
            if isCancelled() { cancelled = true; break }
            var result = StorageCleanupItemResult()
            defer { perCandidate[candidate.id] = result }

            let contents = (try? manager.contentsOfDirectory(
                at: candidate.root,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .isSymbolicLinkKey,
                    .isRegularFileKey,
                    .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey
                ],
                options: [.skipsHiddenFiles]
            )) ?? []

            for item in contents {
                if isCancelled() { cancelled = true; break }
                let name = item.lastPathComponent

                if candidate.protectedNames.contains(name) || retained.contains(name) {
                    result.skippedProtectedCount += 1
                    continue
                }

                let values = try? item.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey
                ])
                if values?.isSymbolicLink == true {
                    // Never remove a symlink target; the link itself is harmless.
                    result.skippedProtectedCount += 1
                    continue
                }

                // Age cutoff for scratch (and always protect very recent cache
                // items while a transfer/export is active).
                if let cutoff = candidate.olderThan,
                   let modified = values?.contentModificationDate,
                   modified >= cutoff {
                    result.skippedActiveCount += 1
                    continue
                }
                if candidate.kind == .cache && transferActive {
                    // Keep anything touched in the last 60s while a job runs.
                    if let modified = values?.contentModificationDate,
                       modified > Date().addingTimeInterval(-60) {
                        result.skippedActiveCount += 1
                        continue
                    }
                }
                if environmentActive && name.contains("LinuxGuest") {
                    result.skippedActiveCount += 1
                    continue
                }

                let logical = allocatedOrLogicalSize(values)
                do {
                    try manager.removeItem(at: item)
                    result.deletedCount += 1
                    result.deletedLogicalBytes += logical
                } catch {
                    result.failedCount += 1
                }
            }
            if cancelled { break }
        }

        let after = (try? StorageCensus(roots: roots, metricLabel: "storage.cleanup.after").run())
            .buckets.reduce(into: [String: Int64]()) { $0[$1.id] = $1.size.allocatedBytes } ?? [:]
        var measuredDelta: Int64 = 0
        for (id, beforeBytes) in before {
            measuredDelta += max(0, beforeBytes - (after[id] ?? 0))
        }

        return StorageCleanupPlanResult(
            candidates: plan,
            perCandidate: perCandidate,
            wasCancelled: cancelled,
            measuredReclaimedAllocatedBytes: measuredDelta
        )
    }

    private static func allocatedOrLogicalSize(_ values: URLResourceValues?) -> Int64 {
        guard let values else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
#endif
