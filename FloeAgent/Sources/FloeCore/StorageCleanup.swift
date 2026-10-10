// FloeCore — Ownership-aware safe cleanup engine.
//
// Design constraints (from review):
// 1. No blanket "sweep the whole Caches directory". Candidates are explicitly
//    registered, regenerable, component-owned roots. A directory that merely
//    happens to live under Caches/ is never swept.
// 2. Ownership/activity is re-validated per item, immediately before removal,
//    and cleanup fails closed whenever the owner cannot be probed: unknown or
//    busy owners delete nothing.
// 3. User data that happens to live in Caches (Floe's prompt library) and
//    recovery journals (diagnostics log, PDF operation journal) are registered
//    as *retained* and are never candidates.
// 4. Results never equate summed file sizes with freed volume bytes. The only
//    measured figure is the *observed allocation change* of the scanned roots,
//    labelled as such; a volume-capacity delta may be attached separately.

import Foundation

/// Owners that can lend/deny cleanup permission. Every deletion needs an owner
/// probe that positively proves the owner is idle.
public enum StorageCleanupOwner: String, Sendable, CaseIterable {
    /// Generic one-off app scratch (task transcripts, workspace diff staging).
    case temporary
    /// Floe component cache directories registered as regenerable.
    case floeCache
    /// Notes assistant import/export/preview scratch.
    case notes
    /// Skill update/upgrade staging.
    case skills
    /// Office attachment/conversion staging.
    case office
    /// Media generation staging.
    case media
    /// Environment-owned roots (fallback container root, environment trash).
    case environment
}

/// Live ownership probe. Implementations must fail closed (return false/nil)
/// when they cannot prove the owner is idle. Methods are async so the
/// implementation can query real services (environment registry, model
/// downloads, media jobs, editor/task leases) on every call instead of caching
/// a snapshot.
@MainActor
public protocol StorageCleanupAuthority: Sendable {
    /// True only when the owner is positively idle (no running task, no lease).
    /// Implementations query the real services on every call.
    func isOwnerIdle(_ owner: StorageCleanupOwner) async -> Bool
    /// Per-item retaining probe consulted during classification.
    /// Unregistered/unknown owners must be retained here.
    func shouldRetain(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> Bool
    /// Atomically claims the right to delete one exact item, coordinating with
    /// the owner's live per-path leases so claiming cannot race a component
    /// re-acquiring the same resource (no TOCTOU). Nil means "retain".
    func claimDeletion(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> StorageCleanupDeletionClaim?
    /// Releases a claim after the item was deleted or kept.
    func releaseDeletionClaim(_ claim: StorageCleanupDeletionClaim) async
}

public extension StorageCleanupAuthority {
    /// Default: no atomic claim coordination available — retain (fail closed).
    func claimDeletion(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> StorageCleanupDeletionClaim? {
        nil
    }

    func releaseDeletionClaim(_ claim: StorageCleanupDeletionClaim) async {}
}

/// A registered, regenerable, component-owned cleanup candidate.
public struct StorageCleanupCandidate: Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case staleTemporary
        case regenerableCache
    }

    public let id: String
    public let owner: StorageCleanupOwner
    public let title: String
    public let purpose: String
    public let retentionReason: String
    public let kind: Kind
    public let root: URL
    /// Only items older than this are eligible. Never nil for safety.
    public let olderThan: Date
    /// Names that are always retained even if the owner is idle.
    public let protectedNames: Set<String>
    /// When non-empty, only direct children whose names start with one of these
    /// prefixes are eligible at all. Foreign files inside an owned scratch
    /// directory are retained, never removed.
    public let requiredNamePrefixes: Set<String>

    public init(
        id: String,
        owner: StorageCleanupOwner,
        title: String,
        purpose: String,
        retentionReason: String,
        kind: Kind,
        root: URL,
        olderThan: Date,
        protectedNames: Set<String> = [],
        requiredNamePrefixes: Set<String> = []
    ) {
        self.id = id
        self.owner = owner
        self.title = title
        self.purpose = purpose
        self.retentionReason = retentionReason
        self.kind = kind
        self.root = root.standardizedFileURL
        self.olderThan = olderThan
        self.protectedNames = protectedNames
        self.requiredNamePrefixes = requiredNamePrefixes
    }
}

/// A registered path that is deliberately retained (user data or recovery
/// state) and must remain visible with its reason instead of being swept.
public struct StorageCleanupRetained: Sendable, Identifiable {
    public let id: String
    public let owner: StorageCleanupOwner
    public let title: String
    public let retentionReason: String
    public let root: URL

    public init(id: String, owner: StorageCleanupOwner, title: String, retentionReason: String, root: URL) {
        self.id = id
        self.owner = owner
        self.title = title
        self.retentionReason = retentionReason
        self.root = root.standardizedFileURL
    }
}

public struct StorageCleanupPlan: Sendable {
    public let candidates: [StorageCleanupCandidate]
    public let retained: [StorageCleanupRetained]
    public let generatedAt: Date

    public init(candidates: [StorageCleanupCandidate], retained: [StorageCleanupRetained], generatedAt: Date = Date()) {
        self.candidates = candidates
        self.retained = retained
        self.generatedAt = generatedAt
    }

    public var isEmpty: Bool { candidates.isEmpty }
}

public struct StorageCleanupEstimate: Sendable, Equatable {
    public let eligibleAllocatedBytes: Int64
    public let eligibleItemCount: Int
    public let perCandidateBytes: [String: Int64]
    /// Candidate IDs whose owner could not be proven idle (fail closed).
    public let busyCandidateIDs: [String]
}

public struct StorageCleanupCandidateResult: Sendable, Equatable {
    public var deletedCount = 0
    public var skippedOwnerBusyCount = 0
    public var skippedProtectedCount = 0
    public var skippedRecentCount = 0
    public var failedCount = 0
    /// Summed allocated size of deleted items. This is a pre-removal estimate,
    /// not the physical volume reclaim.
    public var summedDeletedAllocatedBytes: Int64 = 0
}

public struct StorageCleanupPlanResult: Sendable, Equatable {
    public let perCandidate: [String: StorageCleanupCandidateResult]
    public let wasCancelled: Bool
    /// Observed change in allocated bytes across the cleaned roots (census
    /// before vs after). On a CoW/sparse volume this is an observation, not an
    /// exact physical reclaim figure.
    public let observedAllocatedChangeBytes: Int64
    /// Owner-busy candidate IDs (nothing deleted for them).
    public let busyCandidateIDs: [String]
    /// Candidates rejected by the sweep-safety guard (misregistered roots).
    public let rejectedCandidateIDs: [String]
    /// Optional volume available-capacity delta measured by the caller.
    public var volumeAvailableCapacityChangeBytes: Int64?
}

public enum StorageCleanupError: Error, Equatable {
    case unsafeCandidateRoot(String)
}

public enum StorageCleanup {
    /// A candidate root must be a dedicated directory, never a system cache
    /// parent (Caches/, Library/Caches/ or the app data container) so a
    /// misregistered plan cannot become a blanket sweep.
    public static func isSweepSafe(_ candidate: StorageCleanupCandidate) -> Bool {
        let name = candidate.root.lastPathComponent
        if name == "Caches" || name == "Library" { return false }
        if candidate.root.path.hasSuffix("/Library/Caches") { return false }
        if candidate.root.path == candidate.root.deletingLastPathComponent().path { return false }
        return true
    }

    struct CandidateScan: Sendable {
        var eligible: [URL]
        var skippedRecent: Int
        var skippedProtected: Int
        var ownerIdle: Bool
    }

    /// Classify one candidate's direct children. Owner idleness is probed once
    /// here; execution re-probes per item immediately before deletion. Nothing
    /// is deleted by this function.
    static func scan(
        candidate: StorageCleanupCandidate,
        authority: StorageCleanupAuthority
    ) async -> CandidateScan {
        guard await authority.isOwnerIdle(candidate.owner) else {
            return CandidateScan(eligible: [], skippedRecent: 0, skippedProtected: 0, ownerIdle: false)
        }
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(
            at: candidate.root,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isSymbolicLinkKey,
                .isDirectoryKey
            ],
            options: [.skipsHiddenFiles]
        )) ?? []
        var scan = CandidateScan(eligible: [], skippedRecent: 0, skippedProtected: 0, ownerIdle: true)
        for item in contents {
            let name = item.lastPathComponent
            if candidate.protectedNames.contains(name) {
                scan.skippedProtected += 1
                continue
            }
            if !candidate.requiredNamePrefixes.isEmpty,
               !candidate.requiredNamePrefixes.contains(where: { name.hasPrefix($0) }) {
                // A foreign file inside an owned scratch directory is retained.
                scan.skippedProtected += 1
                continue
            }
            let values = try? item.resourceValues(forKeys: [
                .contentModificationDateKey, .isSymbolicLinkKey, .isDirectoryKey
            ])
            if values?.isSymbolicLink == true {
                // Never follow/remove through a symlink.
                scan.skippedProtected += 1
                continue
            }
            if let modified = values?.contentModificationDate, modified >= candidate.olderThan {
                scan.skippedRecent += 1
                continue
            }
            // A directory can look old while a child is actively being written
            // (e.g. an active download writing into an old parent). Only treat a
            // directory as eligible when every child is older than the cutoff.
            if values?.isDirectory == true,
               !directoryIsQuiescent(item, before: candidate.olderThan) {
                scan.skippedRecent += 1
                continue
            }
            if await authority.shouldRetain(itemURL: item, name: name, owner: candidate.owner) {
                scan.skippedProtected += 1
                continue
            }
            scan.eligible.append(item)
        }
        return scan
    }

    /// Bounded scan proving no descendant file was modified at/after `cutoff`.
    private static func directoryIsQuiescent(_ url: URL, before cutoff: Date, limit: Int = 5_000) -> Bool {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited > limit { return false }
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if let modified = values?.contentModificationDate, modified >= cutoff { return false }
        }
        return true
    }

    private static func allocatedBytes(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
        ]) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    /// Pre-flight estimate of *eligible* bytes. Requires an authority; busy or
    /// unknown owners contribute zero (fail closed), not a whole-directory sum.
    public static func estimate(
        plan: StorageCleanupPlan,
        authority: StorageCleanupAuthority
    ) async -> StorageCleanupEstimate {
        var total: Int64 = 0
        var count = 0
        var perCandidate: [String: Int64] = [:]
        var busy: [String] = []
        for candidate in plan.candidates {
            guard isSweepSafe(candidate) else { continue }
            let scan = await scan(candidate: candidate, authority: authority)
            guard scan.ownerIdle else {
                busy.append(candidate.id)
                perCandidate[candidate.id] = 0
                continue
            }
            let bytes = scan.eligible.reduce(Int64(0)) { $0 + Self.allocatedBytes(of: $1) }
            perCandidate[candidate.id] = bytes
            total += bytes
            count += scan.eligible.count
        }
        return StorageCleanupEstimate(
            eligibleAllocatedBytes: total,
            eligibleItemCount: count,
            perCandidateBytes: perCandidate,
            busyCandidateIDs: busy
        )
    }

    /// Execute the plan. Owner idleness is re-probed per candidate and per item,
    /// immediately before removal. No default authority: callers must supply a
    /// real probe, and a missing/failing probe means nothing is deleted.
    public static func execute(
        plan: StorageCleanupPlan,
        authority: StorageCleanupAuthority,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> StorageCleanupPlanResult {
        let manager = FileManager.default
        let roots = plan.candidates.map { StorageCensusRoot(id: $0.id, url: $0.root) }
        let beforeReport = try? StorageCensus(roots: roots, metricLabel: "storage.cleanup.before").run()
        let before = (beforeReport?.buckets ?? []).reduce(into: [String: Int64]()) { partial, bucket in
            partial[bucket.id] = bucket.size.allocatedBytes
        }

        var perCandidate: [String: StorageCleanupCandidateResult] = [:]
        var busy: [String] = []
        var rejected: [String] = []
        var cancelled = false

        for candidate in plan.candidates {
            if isCancelled() { cancelled = true; break }
            var result = StorageCleanupCandidateResult()
            defer { perCandidate[candidate.id] = result }

            guard isSweepSafe(candidate) else {
                rejected.append(candidate.id)
                continue
            }
            // Re-probe the owner for this candidate (never reuse a snapshot).
            let scan = await scan(candidate: candidate, authority: authority)
            guard scan.ownerIdle else {
                busy.append(candidate.id)
                continue
            }
            result.skippedRecentCount += scan.skippedRecent
            result.skippedProtectedCount += scan.skippedProtected

            for item in scan.eligible {
                if isCancelled() { cancelled = true; break }
                // Atomic revalidation immediately before deletion: the owner
                // must still be idle AND the per-item claim must be granted
                // atomically with respect to the owner's live leases.
                guard await authority.isOwnerIdle(candidate.owner) else {
                    result.skippedOwnerBusyCount += 1
                    continue
                }
                if await authority.shouldRetain(itemURL: item, name: item.lastPathComponent, owner: candidate.owner) {
                    result.skippedProtectedCount += 1
                    continue
                }
                guard let claim = await authority.claimDeletion(
                    itemURL: item, name: item.lastPathComponent, owner: candidate.owner
                ) else {
                    result.skippedOwnerBusyCount += 1
                    continue
                }
                let bytes = allocatedBytes(of: item)
                do {
                    try manager.removeItem(at: item)
                    result.deletedCount += 1
                    result.summedDeletedAllocatedBytes += bytes
                } catch {
                    result.failedCount += 1
                }
                await authority.releaseDeletionClaim(claim)
            }
            if cancelled { break }
        }

        let afterReport = try? StorageCensus(roots: roots, metricLabel: "storage.cleanup.after").run()
        let after = (afterReport?.buckets ?? []).reduce(into: [String: Int64]()) { partial, bucket in
            partial[bucket.id] = bucket.size.allocatedBytes
        }
        var observed: Int64 = 0
        for (id, beforeBytes) in before {
            observed += max(0, beforeBytes - (after[id] ?? 0))
        }

        return StorageCleanupPlanResult(
            perCandidate: perCandidate,
            wasCancelled: cancelled,
            observedAllocatedChangeBytes: observed,
            busyCandidateIDs: busy,
            rejectedCandidateIDs: rejected
        )
    }
}
