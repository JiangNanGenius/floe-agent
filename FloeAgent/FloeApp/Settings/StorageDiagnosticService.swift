// FloeApp — Storage diagnostics and ownership-aware safe-cleanup plans.
//
// All figures come from the identity-deduplicating, sparse-aware
// `StorageCensus` in FloeCore. It keeps logical (apparent / configured VM
// capacity) and host-allocated sizes separate, includes previously unscanned
// Floe roots (Environments, the sibling Floe/Runtime/v2 store, Materials and
// others), and labels clone-backed roots as an upper estimate rather than an
// exact freeable total. The physical-device discrepancy between Floe's numbers
// and iOS Storage is not assumed to have a single proven cause; these metrics
// are honest diagnostics, not a claim that the two must match.
//
// Build 273 follow-up: this service is now a thin MainActor facade over ONE
// shared `StorageSnapshotCenter` in FloeCore. The page renders the last valid
// snapshot immediately (persisted across launches), re-scans only when the
// snapshot is stale/invalidated or the user explicitly refreshes, and never
// clears the last good totals on failure.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// A single categorized bucket for the Data Management UI.
struct StorageCategoryDiagnostic: Identifiable, Sendable {
    let id: String
    let name: String
    let systemImage: String
    /// Host-allocated bytes (sparse-aware) on the report's active basis: the
    /// measured extent union when it was collected, otherwise the allocated
    /// size with identity + full-clone dedup. The two are never mixed.
    let allocatedBytes: Int64
    /// Apparent/logical bytes. For VM disks this is the *configured guest
    /// capacity*, not the host cost.
    let logicalBytes: Int64
    let fileCount: Int
    /// When true, the allocated figure may include APFS clone blocks that are
    /// shared with other data and is therefore an upper estimate.
    let isCloneCapable: Bool

    var showsLogicalCapacity: Bool { logicalBytes > allocatedBytes + Self.capacityDeltaThreshold }
    private static let capacityDeltaThreshold: Int64 = 16 * 1024 * 1024
}

/// Category ids whose apparent size mixes sparse VM disk images with other
/// files. The note under these rows states that the apparent figure is NOT
/// the configured guest capacity (no per-VM capacity metadata exists here)
/// and that guest use is only measurable inside the running guest.
let vmDiskMixedCategoryIDs: Set<String> = ["environments", "linuxDisks"]

/// Full snapshot consumed by Settings → Data Management. Carries only
/// category/count/size/error metrics — never file paths, names or contents.
struct StorageDiagnosticReport: Sendable {
    /// Installer bytes on the report's active basis: the installed bundle's
    /// owned share of the measured union when available, otherwise the raw
    /// allocated bundle size.
    let bundleBytes: Int64
    let categories: [StorageCategoryDiagnostic]
    let unattributed: StorageCategoryDiagnostic?
    /// User-data bytes on the SAME active basis as ``bundleBytes``: the data
    /// side of the union when available, otherwise the allocated total.
    let totalAllocatedBytes: Int64
    let totalLogicalBytes: Int64
    let isSharedAllocationEstimate: Bool
    /// Allocated bytes in clone-capable buckets (counted in full; may share
    /// APFS clone blocks, so an explicit non-additive estimate).
    let cloneCapableAllocatedBytes: Int64
    /// Bytes removed by the exact full-clone-stream dedup (same clone-id,
    /// SHARES_ALL_BLOCKS). Measured, not estimated.
    let dedupedCloneBytes: Int64
    /// Measured lower bound of the physical footprint (sum of APFS private
    /// bytes); nil when the extended query was unavailable or incomplete.
    let measuredExclusiveLowerBoundBytes: Int64?
    /// Whether measured clone attributes were collected in this scan.
    let cloneAttributeSupport: StorageCloneAttributeSupport
    let scanErrorCount: Int
    let changedOrVanishedCount: Int
    let allocatedUnavailableCount: Int
    let identityUnavailableCount: Int
    let scanDuration: TimeInterval
    let metricLabel: String
    /// When the census finished (from the census, not the render pass).
    let generatedAt: Date
    /// Regular files visited (measured progress figure).
    let filesScanned: Int
    /// The active measurement basis for the numeric rows.
    let totalBasis: StorageTotalBasis
    /// Whether the extent probe could be collected (internal diagnostic).
    let extentBasis: StorageExtentBasisState
    /// Aggregate reason when the extent basis was withheld; never a path.
    let extentUnavailableReason: StorageExtentProbeFailure?

    /// Overview total on the ACTIVE basis: the measured extent union when it
    /// was collected, otherwise installer + allocated. Never a mix, and the
    /// category rows sum to `totalAllocatedBytes` on either basis.
    var combinedBytes: Int64 { bundleBytes + totalAllocatedBytes }
    var dataBytes: Int64 { totalAllocatedBytes }
    /// Some measurement was unavailable; the UI must label the figures as
    /// partial instead of presenting them as exact.
    var isPartial: Bool {
        scanErrorCount > 0 || allocatedUnavailableCount > 0 || identityUnavailableCount > 0
    }
    /// True when file figures may share APFS clone blocks and must not be
    /// presented as the app's accounted footprint. On the measured-extent
    /// basis the sharing is already resolved in the totals; the flag stays
    /// true while clone-capable file capacities remain listed separately.
    var hasSharedEstimates: Bool {
        isSharedAllocationEstimate || cloneCapableAllocatedBytes > 0
    }
}

/// Result of one `StorageDiagnosticService.refresh` call, for the view to
/// decide whether dependent estimates (cleanup preview) need recomputing.
enum StorageRefreshRunResult: Equatable {
    case servedFromCache
    case scanned
    case failed
    case cancelled
    case superseded
}

/// Mutation hooks for the shared storage snapshot, callable from any isolation
/// domain (the environment service, model store and workbench are not all
/// MainActor). Hooking the ACTUAL data-changing call sites — not just exposing
/// the enum — is what keeps the cached numbers honest between scans.
enum StorageMutationHooks {
    static func invalidate(_ reason: StorageMutationReason) {
        Task { @MainActor in
            StorageDiagnosticService.shared.invalidate(reason)
        }
    }
}

@MainActor
final class StorageDiagnosticService: ObservableObject {
    /// One shared snapshot/cache for every storage surface. Reusing the same
    /// instance is what makes reopening the page instant and prevents parallel
    /// scanners.
    static let shared = StorageDiagnosticService()

    @Published private(set) var report: StorageDiagnosticReport?
    @Published private(set) var isScanning = false
    /// Measured progress: regular files visited so far by the running census.
    @Published private(set) var filesScanned = 0
    @Published private(set) var wasCancelled = false
    /// True when the last refresh attempt failed for a reason other than
    /// cancellation, so the UI can say so instead of presenting a silent zero
    /// state. A previously valid report is kept either way.
    @Published private(set) var scanFailed = false
    /// True while the rendered report came from the shared cache without a
    /// fresh scan in this appearance.
    @Published private(set) var servedFromCache = false
    /// True when the last refresh kept a cached report after a failure.
    @Published private(set) var lastRefreshFailedWhileShowingCached = false

    private let center: StorageSnapshotCenter
    private var progressTask: Task<Void, Never>?

    convenience init() {
        self.init(center: Self.makeDefaultCenter())
    }

    init(center: StorageSnapshotCenter) {
        self.center = center
        // Show the last valid totals immediately: hydrate the persisted
        // snapshot synchronously (small JSON) before the first render pass.
        center.hydrateIfNeeded()
        if let cached = center.cachedSnapshot() {
            report = Self.makeReport(from: cached)
            filesScanned = cached.census.diagnostics.regularFileCount
            servedFromCache = true
        }
    }

    // MARK: - Refresh

    /// Renders the shared snapshot and re-scans only when the refresh policy
    /// requires it (no snapshot, stale, invalidated by a mutation, or an
    /// explicit user refresh). Concurrent callers join the single in-flight
    /// scan instead of starting a parallel one.
    @discardableResult
    func refresh(explicit: Bool = false) async -> StorageRefreshRunResult {
        center.hydrateIfNeeded()
        guard center.willScan(explicit: explicit) else {
            if let cached = center.cachedSnapshot() {
                report = Self.makeReport(from: cached)
                servedFromCache = true
            }
            return .servedFromCache
        }

        isScanning = true
        servedFromCache = false
        lastRefreshFailedWhileShowingCached = false
        startProgressPolling()
        defer {
            stopProgressPolling()
            isScanning = false
        }

        let outcome = await center.refresh(explicit: explicit)
        switch outcome {
        case .served(let snapshot, let fromCache):
            report = Self.makeReport(from: snapshot)
            servedFromCache = fromCache
            scanFailed = false
            wasCancelled = false
            lastRefreshFailedWhileShowingCached = false
            filesScanned = snapshot.census.diagnostics.regularFileCount
            return fromCache ? .servedFromCache : .scanned
        case .cancelled(let kept):
            wasCancelled = true
            if let kept { report = Self.makeReport(from: kept) }
            return .cancelled
        case .failed(let kept):
            scanFailed = true
            if let kept {
                report = Self.makeReport(from: kept)
                lastRefreshFailedWhileShowingCached = true
            }
            return .failed
        case .superseded(let kept):
            if let kept { report = Self.makeReport(from: kept) }
            return .superseded
        }
    }

    /// User-visible stop for the in-flight scan. The last valid snapshot is
    /// never cleared.
    func cancel() {
        center.cancelInFlight()
    }

    /// A real mutation happened (cleanup finished, environment/model/media
    /// data changed): mark the snapshot stale so the next automatic refresh
    /// scans once, while still rendering the kept totals immediately.
    func invalidate(_ reason: StorageMutationReason) {
        center.invalidate(reason: reason)
    }

    // MARK: - Progress

    private func startProgressPolling() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let count = self.center.scannedFiles
                if count != self.filesScanned { self.filesScanned = count }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func stopProgressPolling() {
        progressTask?.cancel()
        progressTask = nil
    }

    // MARK: - Composition

    nonisolated static func makeDefaultCenter() -> StorageSnapshotCenter {
        let base = FloeStorageBase.standard
        let storeDirectory = FloeStorageLayout.floeAgentRoot(in: base)?
            .appendingPathComponent("StorageDiagnostics", isDirectory: true)
        let request = FloeStorageLayout.request(
            in: base,
            metricLabel: FloeStorageLayout.dataManagementMetricLabel,
            contextFingerprint: appBuildFingerprint(),
            // The installer and user data are measured into ONE union, so a
            // resource cloned from the bundle into the container is counted
            // once instead of as raw bundle bytes plus union data.
            bundleURL: Bundle.main.bundleURL
        )
        return StorageSnapshotCenter(
            store: storeDirectory.map { StorageSnapshotStore(directory: $0) },
            request: request,
            bundleBytesProvider: { StorageDiagnosticService.bundleAllocatedBytes() }
        )
    }

    /// Version/build identity: an app update invalidates the persisted
    /// snapshot (same reason an upgraded device must not keep serving numbers
    /// computed by an older build's accounting).
    nonisolated static func appBuildFingerprint() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version).\(build)"
    }

    nonisolated private static func makeReport(from snapshot: StorageSnapshot) -> StorageDiagnosticReport {
        let names: [String: (String, String)] = [
            "models": (FloeL10n.l("localmodels.title"), "cpu"),
            "workspaces": (FloeL10n.l("settings.data_management_view.private_workspace"), "folder.badge.gearshape"),
            "fonts": (FloeL10n.l("settings.data_management_view.font_resources"), "textformat"),
            "attachments": (FloeL10n.l("settings.data_management_view.attachments"), "paperclip"),
            "generated": (FloeL10n.l("platform.background_run_coordinator.generate_content"), "photo.on.rectangle"),
            "browser": (FloeL10n.l("settings.data_management_view.browser_downloads"), "globe"),
            "checkpoints": (FloeL10n.l("settings.data_management_view.task_checkpoint"), "arrow.trianglehead.2.clockwise"),
            "materials": (FloeL10n.l("settings.data_management_view.shared_materials"), "square.stack.3d.up"),
            "canvases": (FloeL10n.l("settings.data_management_view.canvases"), "canvas"),
            "mediaProjects": (FloeL10n.l("settings.data_management_view.media_projects"), "film"),
            "cad": (FloeL10n.l("settings.data_management_view.cad_packages"), "cube.box"),
            "environments": (FloeL10n.l("settings.data_management_view.linux_environments"), "desktopcomputer"),
            "linuxDisks": (FloeL10n.l("settings.data_management_view.virtual_machine_disks"), "internaldrive"),
            "runtimeV2": (FloeL10n.l("settings.data_management_view.runtime_images"), "shippingbox.and.arrow.backward"),
            "floeOther": (FloeL10n.l("settings.data_management_view.databases_configuration_and_other_data"), "cylinder"),
            "caches": (FloeL10n.l("settings.data_management_view.rebuildable_caches"), "internaldrive"),
            "temporary": (FloeL10n.l("settings.data_management_view.temporary_files_older_than_one_hour"), "clock.arrow.circlepath"),
            "library": (FloeL10n.l("settings.data_management_view.system_library_data"), "books.vertical"),
            "documents": (FloeL10n.l("settings.data_management_view.documents"), "doc")
        ]

        // Pure arithmetic lives in FloeCore and is unit-tested; every measured
        // bucket is listed exactly once so categories reconcile with the total.
        let report = StorageReportBuilder.build(
            census: snapshot.census,
            bundleBytes: snapshot.bundleBytes
        )

        let categories = report.categories.map { category in
            let meta = names[category.id] ?? (category.id, "questionmark.folder")
            return StorageCategoryDiagnostic(
                id: category.id,
                name: meta.0,
                systemImage: meta.1,
                allocatedBytes: category.basisBytes,
                logicalBytes: category.logicalBytes,
                fileCount: category.fileCount,
                isCloneCapable: category.isCloneCapable
            )
        }

        let unattributed = report.unattributed.map { other in
            StorageCategoryDiagnostic(
                id: other.id,
                name: FloeL10n.l("settings.data_management_view.other_application_data"),
                systemImage: "ellipsis.circle",
                allocatedBytes: other.basisBytes,
                logicalBytes: other.logicalBytes,
                fileCount: other.fileCount,
                isCloneCapable: false
            )
        }

        return StorageDiagnosticReport(
            bundleBytes: report.totals.bundleBytes,
            categories: categories,
            unattributed: unattributed,
            totalAllocatedBytes: report.totals.dataBytes,
            totalLogicalBytes: report.totalLogicalBytes,
            isSharedAllocationEstimate: report.isSharedAllocationEstimate,
            cloneCapableAllocatedBytes: report.cloneCapableAllocatedBytes,
            dedupedCloneBytes: report.dedupedCloneBytes,
            measuredExclusiveLowerBoundBytes: report.measuredExclusiveLowerBoundBytes,
            cloneAttributeSupport: report.cloneAttributeSupport,
            scanErrorCount: report.scanErrorCount,
            changedOrVanishedCount: report.changedOrVanishedCount,
            allocatedUnavailableCount: report.allocatedUnavailableCount,
            identityUnavailableCount: report.identityUnavailableCount,
            scanDuration: report.scanDuration,
            metricLabel: report.metricLabel,
            generatedAt: report.generatedAt,
            filesScanned: report.filesScanned,
            totalBasis: report.totals.basis,
            extentBasis: snapshot.census.diagnostics.extentBasis,
            extentUnavailableReason: snapshot.census.diagnostics.extentUnavailableReason
        )
    }

    /// Allocated size of the installed app bundle (read-only, shared with the
    /// OS, sparse-aware).
    nonisolated static func bundleAllocatedBytes() -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey
        ]
        let root = Bundle.main.bundleURL
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Registered, explicit cleanup plan. Only Floe-owned regenerable scratch is a
/// candidate; user data and recovery state that live under Caches are
/// registered as *retained* with reasons and are never swept.
enum FloeStorageCleanupRegistry {
    /// Scratch forgotten by one-off components becomes eligible after a day;
    /// anything newer is either still in use or too recent to prove idle.
    static let scratchRetention: TimeInterval = 24 * 60 * 60

    /// Owned scratch directory. Only what Floe itself creates under this
    /// directory (through `FloeScratch.makeDirectory`) is a candidate;
    /// arbitrary tmp content has unknown owners and is never classified as
    /// owned regenerable scratch.
    static func ownedScratchRoot(temporary: URL = FloeStorageLayout.temporaryRoot) -> URL {
        FloeScratch.scratchRoot(temporary: temporary)
    }

    static func plan(
        caches: URL? = FloeStorageLayout.cachesRoot(),
        temporary: URL = FloeStorageLayout.temporaryRoot,
        now: Date = Date()
    ) -> StorageCleanupPlan {
        let cutoff = now.addingTimeInterval(-scratchRetention)
        // One deletable candidate: the dedicated scratch directory that every
        // component's one-off working directories are created in. The whole
        // tmp root is never a candidate; foreign files inside the scratch
        // directory are retained by the name-prefix guard.
        let scratchCandidate = StorageCleanupCandidate(
            id: "floe.scratch",
            owner: .temporary,
            title: FloeL10n.l("settings.data_management_view.cleanup_scratch_title"),
            purpose: FloeL10n.l("settings.data_management_view.cleanup_scratch_purpose"),
            retentionReason: FloeL10n.l("settings.data_management_view.cleanup_scratch_retention"),
            kind: .staleTemporary,
            root: FloeScratch.scratchRoot(temporary: temporary),
            olderThan: cutoff,
            requiredNamePrefixes: Set(Self.scratchPurposes)
        )
        // Real user state that lives in tmp/caches-adjacent places, registered
        // so the plan shows it with its reason instead of ever sweeping it.
        var retained: [StorageCleanupRetained] = [
            StorageCleanupRetained(
                id: "floe.environmentFallbackRoot",
                owner: .environment,
                title: FloeL10n.l("settings.data_management_view.cleanup_environment_fallback"),
                retentionReason: FloeL10n.l("settings.data_management_view.cleanup_environment_fallback_reason"),
                root: FloeScratch.root(temporary: temporary)
            ),
            StorageCleanupRetained(
                id: "floe.checkpoints",
                owner: .temporary,
                title: FloeL10n.l("settings.data_management_view.cleanup_checkpoints"),
                retentionReason: FloeL10n.l("settings.data_management_view.cleanup_checkpoints_reason"),
                root: temporary.appendingPathComponent("FloeAgent-Checkpoints", isDirectory: true)
            )
        ]
        if let caches {
            retained.append(StorageCleanupRetained(
                id: "floe.cacheContainers",
                owner: .floeCache,
                title: FloeL10n.l("settings.data_management_view.cleanup_cache_containers"),
                retentionReason: FloeL10n.l("settings.data_management_view.cleanup_cache_containers_reason"),
                root: caches
            ))
        }
        return StorageCleanupPlan(
            candidates: [scratchCandidate],
            retained: retained,
            generatedAt: now
        )
    }

    /// Purposes whose scratch directories may be reclaimed. A scratch item
    /// with any other prefix is foreign and retained. Must stay in sync with
    /// the `purpose` argument of every `FloeScratch.makeDirectory` call site.
    static let scratchPurposes: [String] = [
        "task", "workspace", "skills", "conversion", "office", "notes", "media", "misc"
    ]
}
#endif
