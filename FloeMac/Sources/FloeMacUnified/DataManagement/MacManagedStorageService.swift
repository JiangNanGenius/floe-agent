// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeCore
import Foundation

// FloeMacUnified — Mac data management service.
//
// Bounded scan: the shared `StorageCensus` walks ONLY the injected Floe-owned
// roots (the host's managed directory as the attribution parent plus the
// runtime/caches/WebKit/scratch roots); symlinks and aliases are never
// followed beyond those roots, and every root is re-validated against the
// allowed bases before it enters the walk. The byte totals are
// sparse-aware, identity-deduplicated, host-allocated numbers.
//
// Confirmed cleanup: only the explicitly registered regenerable scratch
// candidate is ever deletable, executed by the FloeCore ownership-aware
// engine — quiescence cutoff, purpose-prefix guard, per-item atomic lease
// claims via the shared lease center, and an injected fail-closed authority.
// Databases, drafts, current work, runtime/rollback artifacts, caches roots
// and WebKit website data are retained rows with their reasons and can only
// be inspected or revealed in Finder.

/// Fail-closed cleanup authority. Owner idleness comes from injected host
/// probes (Primary wires the real service checks); a missing probe means
/// "not idle". Scratch cleanup additionally requires that no live scratch
/// lease exists under the scratch root, and every deletion is claimed
/// atomically from the shared lease center, so an in-use directory can
/// never be removed.
@MainActor
struct MacManagedStorageCleanupAuthority: StorageCleanupAuthority {
    let leaseCenter: StorageCleanupLeaseCenter
    let scratchRoot: URL
    /// Host probes: return true only when the owner is positively idle.
    var idleProbe: (@MainActor (StorageCleanupOwner) async -> Bool)?
    /// Optional per-item retain probe (credentials, job files, …).
    var retainProbe: (@MainActor (URL, String, StorageCleanupOwner) async -> Bool)?

    func isOwnerIdle(_ owner: StorageCleanupOwner) async -> Bool {
        switch owner {
        case .temporary:
            // Owned scratch: blocked while any live lease sits under the
            // dedicated scratch root; the host probe refines further.
            if await leaseCenter.isLeasedUnder(root: scratchRoot) { return false }
            return await idleProbe?(owner) ?? true
        default:
            // No Mac cleanup candidate registers these owners yet; fail
            // closed until the host wires a real probe.
            return await idleProbe?(owner) ?? false
        }
    }

    func shouldRetain(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> Bool {
        if let retainProbe, await retainProbe(itemURL, name, owner) { return true }
        // Defense in depth next to the engine's own symlink skip: never
        // remove through a link or an irregular file.
        let values = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        if values?.isSymbolicLink == true { return true }
        if values?.isRegularFile != true && values?.isDirectory != true { return true }
        return false
    }

    func claimDeletion(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> StorageCleanupDeletionClaim? {
        await leaseCenter.claimForDeletion(path: itemURL.path)
    }

    func releaseDeletionClaim(_ claim: StorageCleanupDeletionClaim) async {
        await leaseCenter.releaseClaim(claim.id)
    }
}

@MainActor
final class MacManagedStorageService: ObservableObject {
    /// Construct-and-pass hooks: the host injects the real storage roots and
    /// the live-service idle probes (task runner, media jobs, environment
    /// registry). A nil probe fails closed — nothing is deleted on a guess.
    struct Hooks {
        var idleProbe: (@MainActor (StorageCleanupOwner) async -> Bool)?
        var retainProbe: (@MainActor (URL, String, StorageCleanupOwner) async -> Bool)?
    }

    nonisolated private static let metricLabel = "mac.data_management.v1"

    @Published private(set) var report: MacManagedStorageScanReport?
    @Published private(set) var isScanning = false
    @Published private(set) var scanFailed = false
    @Published private(set) var estimate: StorageCleanupEstimate?
    @Published private(set) var cleanupResult: StorageCleanupPlanResult?
    @Published private(set) var isCleaning = false

    private let roots: MacManagedStorageRoots
    private let authority: MacManagedStorageCleanupAuthority
    private var refreshGeneration = 0

    init(roots: MacManagedStorageRoots, hooks: Hooks = Hooks(), leaseCenter: StorageCleanupLeaseCenter = .shared) {
        self.roots = roots
        self.authority = MacManagedStorageCleanupAuthority(
            leaseCenter: leaseCenter,
            scratchRoot: FloeScratch.scratchRoot(temporary: roots.temporary),
            idleProbe: hooks.idleProbe,
            retainProbe: hooks.retainProbe
        )
    }

    // MARK: - Scan

    /// Starts one bounded scan. Concurrent calls are joined: the newest
    /// caller's generation wins and stale completions are discarded.
    func refresh() {
        guard !isScanning else { return }
        let request = censusRequest()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isScanning = true
        scanFailed = false
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> Result<StorageCensusReport, Error> in
                do {
                    return .success(try StorageCensus(
                        roots: request.roots,
                        parentURL: request.parentURL,
                        metricLabel: Self.metricLabel
                    ).run())
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            guard generation == self.refreshGeneration else { return }
            self.isScanning = false
            switch outcome {
            case .success(let census):
                self.report = Self.makeReport(census: census, roots: self.roots)
            case .failure:
                self.scanFailed = true
            }
        }
    }

    /// The bounded census request: every descriptor root validated against
    /// the allowed bases, with the managed directory as the attribution
    /// parent (children attributed by deepest match, remainder = other).
    private func censusRequest() -> StorageCensusRequest {
        let descriptors = roots.categoryDescriptors()
            .filter { MacManagedStorageRootPolicy.isAllowed($0.root, bases: roots.allowedBases) }
        let censusRoots: [StorageCensusRoot] = descriptors.compactMap { descriptor in
            descriptor.root.map {
                StorageCensusRoot(id: descriptor.id, url: $0, attribution: .category, includeHiddenFiles: true)
            }
        }
        let parent = MacManagedStorageRootPolicy.isAllowed(roots.managed, bases: roots.allowedBases)
            ? roots.managed
            : nil
        return StorageCensusRequest(
            roots: censusRoots,
            parentURL: parent,
            metricLabel: Self.metricLabel
        )
    }

    /// Builds the display report from one census. The database row is
    /// measured directly (a file, not a walkable root) and subtracted from
    /// the census's unattributed figure so "other" reconciles exactly.
    nonisolated private static func makeReport(
        census: StorageCensusReport,
        roots: MacManagedStorageRoots
    ) -> MacManagedStorageScanReport {
        let descriptors = roots.categoryDescriptors()
            .filter { MacManagedStorageRootPolicy.isAllowed($0.root, bases: roots.allowedBases) }
        let buckets = Dictionary(uniqueKeysWithValues: census.buckets.map { ($0.id, $0) })

        var categories: [MacManagedStorageCategory] = []
        var totalAllocated: Int64 = 0
        var totalLogical: Int64 = 0
        var totalFiles = 0
        for descriptor in descriptors {
            if descriptor.kind == .database {
                let measured = databaseSize(at: descriptor.root)
                categories.append(MacManagedStorageCategory(
                    descriptor: descriptor,
                    exists: measured.fileCount > 0,
                    allocatedBytes: measured.allocatedBytes,
                    logicalBytes: measured.logicalBytes,
                    fileCount: measured.fileCount
                ))
                totalAllocated += measured.allocatedBytes
                totalLogical += measured.logicalBytes
                totalFiles += measured.fileCount
                continue
            }
            let bucket = buckets[descriptor.id]
            let allocated = bucket?.size.allocatedBytes ?? 0
            let logical = bucket?.size.logicalBytes ?? 0
            let count = bucket?.fileCount ?? 0
            categories.append(MacManagedStorageCategory(
                descriptor: descriptor,
                exists: bucket?.exists ?? false,
                allocatedBytes: allocated,
                logicalBytes: logical,
                fileCount: count
            ))
            totalAllocated += allocated
            totalLogical += logical
            totalFiles += count
        }

        // "Other" = what the managed-walk found outside every registered
        // child, minus the database row measured above.
        var otherBytes = census.unattributedSize.allocatedBytes
        var otherLogical = census.unattributedSize.logicalBytes
        var otherCount = census.unattributedCount
        if let database = categories.first(where: { $0.kind == .database }) {
            otherBytes = max(0, otherBytes - database.allocatedBytes)
            otherLogical = max(0, otherLogical - database.logicalBytes)
            otherCount = max(0, otherCount - database.fileCount)
        }
        var other: MacManagedStorageCategory?
        if otherBytes > 0 || otherCount > 0 {
            let descriptor = MacManagedStorageCategoryDescriptor(
                id: "other",
                title: MacManagedStorageText.t("其他应用数据", "Other app data"),
                systemImage: "ellipsis.circle",
                kind: .store,
                root: roots.managed
            )
            other = MacManagedStorageCategory(
                descriptor: descriptor,
                exists: true,
                allocatedBytes: otherBytes,
                logicalBytes: otherLogical,
                fileCount: otherCount
            )
            totalAllocated += otherBytes
            totalLogical += otherLogical
            totalFiles += otherCount
        }

        let diagnostics = census.diagnostics
        let isPartial = diagnostics.errorCount > 0
            || diagnostics.allocatedUnavailableCount > 0
            || diagnostics.identityUnavailableCount > 0
        return MacManagedStorageScanReport(
            categories: categories,
            other: other,
            totalAllocatedBytes: totalAllocated,
            totalLogicalBytes: totalLogical,
            fileCount: totalFiles,
            symbolicLinkCount: diagnostics.symbolicLinkCount,
            scanErrorCount: diagnostics.errorCount,
            isPartial: isPartial,
            generatedAt: diagnostics.completedAt,
            duration: diagnostics.duration
        )
    }

    /// Allocated/logical size of the agent database file (plus its -wal and
    /// -shm companions) without walking a directory.
    nonisolated private static func databaseSize(at url: URL?) -> (allocatedBytes: Int64, logicalBytes: Int64, fileCount: Int) {
        guard let url else { return (0, 0, 0) }
        var allocated: Int64 = 0
        var logical: Int64 = 0
        var count = 0
        let companions = ["-wal", "-shm"].map {
            url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + $0)
        }
        for candidate in [url] + companions {
            guard let values = try? candidate.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
            ]), values.isRegularFile == true else { continue }
            count += 1
            logical += Int64(values.fileSize ?? 0)
            allocated += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return (allocated, logical, count)
    }

    // MARK: - Reveal

    /// Opens the category's folder in Finder. Only existing, revealable
    /// categories whose root passed the policy check are revealed; the
    /// database row reveals its containing directory instead of the file.
    @discardableResult
    func reveal(categoryID: String) -> Bool {
        guard let report else { return false }
        let rows = report.other.map { $0.id == categoryID ? [$0] : [] } ?? []
        let all = report.categories + rows
        guard let category = all.first(where: { $0.id == categoryID }),
              category.isRevealable, category.exists,
              MacManagedStorageRootPolicy.isAllowed(category.root, bases: roots.allowedBases),
              let root = category.root else { return false }
        let target = category.kind == .database ? root.deletingLastPathComponent() : root
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([target])
        return true
    }

    // MARK: - Cleanup

    /// The executable plan: registered candidates narrowed by the root
    /// policy and the engine's sweep-safety check. Retained rows keep their
    /// reasons for display.
    func cleanupPlan(now: Date = Date()) -> StorageCleanupPlan {
        let plan = MacManagedStorageCleanupRegistry.plan(roots: roots, now: now)
        let candidates = plan.candidates.filter {
            MacManagedStorageRootPolicy.isAllowed($0.root, bases: roots.allowedBases)
                && StorageCleanup.isSweepSafe($0)
        }
        return StorageCleanupPlan(candidates: candidates, retained: plan.retained, generatedAt: plan.generatedAt)
    }

    /// Pre-flight estimate of the eligible scratch bytes. Busy or
    /// unprobed owners contribute zero (fail closed), never a whole-root sum.
    func estimateCleanup() async {
        estimate = await StorageCleanup.estimate(plan: cleanupPlan(), authority: authority)
    }

    /// Executes the plan: quiescence cutoff, prefix guard, per-item atomic
    /// lease claims. The result (including skips and observed freed bytes)
    /// is published verbatim; a fresh scan is queued afterwards so the UI
    /// never shows stale totals after a real mutation.
    func performCleanup() async {
        guard !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }
        cleanupResult = await StorageCleanup.execute(plan: cleanupPlan(), authority: authority)
        estimate = nil
        refresh()
    }
}

private extension MacManagedStorageCategory {
    init(
        descriptor: MacManagedStorageCategoryDescriptor,
        exists: Bool,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        fileCount: Int
    ) {
        self.init(
            id: descriptor.id,
            title: descriptor.title,
            systemImage: descriptor.systemImage,
            kind: descriptor.kind,
            root: descriptor.root,
            isRevealable: descriptor.isRevealable,
            exists: exists,
            allocatedBytes: allocatedBytes,
            logicalBytes: logicalBytes,
            fileCount: fileCount
        )
    }
}
