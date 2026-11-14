// FloeApp — Unified archive, font, storage and safe-cleanup settings.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloeEnvironments
import FloePersistence

struct DataManagementView: View {
    let environment: AppEnvironment
    let conversationCenter: ConversationCenter
    // One shared snapshot/cache for the whole app: reopening this page renders
    // the last valid totals immediately instead of re-scanning.
    @ObservedObject private var storage = StorageDiagnosticService.shared
    @State private var isCleaning = false
    @State private var confirmsCleanup = false
    @State private var cleanupOutcome: StorageCleanupPlanResult?
    @State private var cleanupEstimateBytes: Int64 = 0
    @State private var cleanupPerCandidateBytes: [String: Int64] = [:]
    @State private var cleanupBusyCandidateIDs: [String] = []
    @State private var cleanupPlan = FloeStorageCleanupRegistry.plan()
    @State private var cleanupCancellation = CleanupCancellation()
    @AppStorage("creative.canvas.sync.enabled") private var canvasSyncEnabled = true
    @State private var creativeStorage: CreativeStorageSummary?
    @State private var isReleasingCloudSpace = false
    @State private var orphanedAssetCount = 0
    @State private var orphanedAssetBytes: Int64 = 0
    /// File-based capacities are non-additive; keep them expandable.
    @State private var showsFileCapacityDetails = false

    private struct CreativeStorageSummary {
        let local: Int64
        let cloud: Int64
        let pendingDownload: Int64
        let pendingRelease: Int64
        let releaseCount: Int
    }

    private func fileUsageTitle(_ report: StorageDiagnosticReport) -> String {
        if report.isMixedExtentEstimate {
            // Exact for the measured files, plus a bounded allocation
            // allowance for the ones that could not be measured. It is an
            // upper bound, not the exact union and not iOS's app size.
            return FloeL10n.isChinese
                ? "文件占用估算（上限）"
                : "Estimated file usage (upper bound)"
        }
        if report.isPartial || report.changedOrVanishedCount > 0 {
            return FloeL10n.l("settings.data_management_view.partial_file_estimate")
        }
        return FloeL10n.l(report.totalBasis == .measuredExtents
            ? "settings.data_management_view.floe_total_usage"
            : "settings.data_management_view.file_usage_estimate")
    }

    /// Plain-language bound for the mixed extent basis: what was measured
    /// exactly and what is only a conservative allowance. Kept inline (not a
    /// shared-catalog key) because it is specific to this transient state.
    private func mixedExtentNote(_ report: StorageDiagnosticReport) -> String {
        let measured = ByteCountFormatter.string(
            fromByteCount: report.extentMeasuredBytes, countStyle: .file
        )
        let count = report.extentUnmeasuredFileCount
        if FloeL10n.isChinese {
            return "精确实测：\(measured)。另有 \(count) 个文件无法测量，已按分配大小计入（可能包含共享块），因此总计为上限。"
        }
        let files = count == 1 ? "1 file" : "\(count) files"
        return "Measured exactly: \(measured). \(files) couldn't be measured and are counted at allocated size, which may include shared blocks; this total is an upper bound."
    }

    /// Shareable-file figure on the report's active basis. When the physical
    /// extent basis was collected, the overview already resolves shared
    /// blocks, so this is the measured share of clone-capable buckets. On the
    /// allocated estimate basis it stays the accepted raw capacity.
    private func shareableFileBytes(_ report: StorageDiagnosticReport) -> Int64 {
        if report.extentBasis == .available || report.extentBasis == .partial {
            return report.categories
                .filter(\.isCloneCapable)
                .reduce(Int64(0)) { $0 + $1.allocatedBytes }
        }
        return report.cloneCapableAllocatedBytes
    }

    var body: some View {
        Form {
            LinuxCacheCleanupSettingsSection(
                environment: environment,
                conversationCenter: conversationCenter
            )
            // Keep actions above asynchronously populated storage sections so
            // completing a scan cannot move a navigation target under a tap.
            Section {
                // The SAME canonical management surface the Task Center
                // opens — one store, one lifecycle path. The row is titled
                // "Manage tasks", so it starts on the ACTIVE task slice like
                // the Task Center's 管理 entry; the archived slice is one
                // segmented switch away (only an entry titled
                // "Manage archived tasks" defaults to the archive).
                NavigationLink {
                    ConversationBatchManagementView(
                        center: conversationCenter,
                        initialFilter: .active,
                        presentation: .pushed
                    )
                } label: {
                    ManagementRow(
                        title: TaskManagementCopy.manageTasks,
                        detail: TaskManagementCopy.manageTasksDetail,
                        icon: "checklist"
                    )
                }

                NavigationLink {
                    FontManagementView(store: environment.fontStore)
                } label: {
                    ManagementRow(
                        title: FloeL10n.l("settings.data_management_view.font_resources"),
                        detail: FloeL10n.l("settings.data_management_view.download_once_shared_across_all_floe"),
                        icon: "textformat"
                    )
                }
            } header: {
                Text("settings.data_management_view.manage")
            }

            StorageOptimizationSection(service: environment.storageOptimizationService)


            Section {
                if let report = storage.report {
                    // The App total is the SAME snapshot's mutually-exclusive
                    // category sum (installer + Floe-managed file categories),
                    // so the overview number always reconciles with the
                    // expanded details below. Shared/clone-capable data stays a
                    // separate section and is already part of this total once —
                    // it is never added again. Device-wide capacity is not
                    // shown on this page.
                    StorageUsageRow(
                        title: fileUsageTitle(report),
                        icon: "internaldrive",
                        bytes: report.combinedBytes,
                        emphasized: true
                    )
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.app_installer"), icon: "shippingbox", bytes: report.bundleBytes)
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.user_data"), icon: "externaldrive", bytes: report.totalAllocatedBytes)
                    StorageUsageRow(
                        title: FloeL10n.l("settings.data_management_view.cleanup_candidate_capacity"),
                        icon: "sparkles",
                        bytes: cleanupEstimateBytes
                    )
                } else {
                    HStack {
                        ProgressView()
                        if storage.isScanning {
                            Text(FloeL10n.l("settings.data_management_view.scanning_files", storage.filesScanned))
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) { storage.cancel() } label: {
                                Text("settings.data_management_view.stop_scan")
                            }
                        } else if storage.scanFailed {
                            Text("settings.data_management_view.scan_failed").foregroundStyle(.secondary)
                        } else {
                            Text("settings.data_management_view.calculating_actual_usage").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("settings.data_management_view.space_overview")
            } footer: {
                if let report = storage.report {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FloeL10n.l(
                            "settings.data_management_view.updated_at",
                            Self.scanTimestampFormatter.string(from: report.generatedAt)
                        )).font(.caption2).foregroundStyle(.secondary)
                        if report.isMixedExtentEstimate {
                            Text(mixedExtentNote(report))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if storage.isScanning {
                            Text("settings.data_management_view.refreshing")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if storage.lastRefreshFailedWhileShowingCached {
                            Text(FloeL10n.l(
                                "settings.data_management_view.refresh_failed_showing_last",
                                Self.scanTimestampFormatter.string(from: report.generatedAt)
                            )).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let report = storage.report, report.hasSharedEstimates,
               shareableFileBytes(report) > 0 {
                // On a measured (exact or partial) basis the overview already
                // resolves shared blocks, so show the measured share of
                // clone-capable buckets — their raw allocated capacity can
                // exceed the whole total and would read as double counting.
                // On the allocated estimate basis keep that raw capacity: it
                // is the only signal that the estimate is non-additive.
                Section {
                    StorageUsageRow(
                        title: FloeL10n.l("settings.data_management_view.shared_file_capacity"),
                        icon: "doc.on.doc",
                        bytes: shareableFileBytes(report)
                    )
                } header: {
                    Text("settings.data_management_view.shared_files")
                } footer: {
                    switch report.extentBasis {
                    case .available:
                        Text(FloeL10n.isChinese
                            ? "可能包含共享块的文件实测占用；共享块已在上方总计中只计一次。"
                            : "Measured usage of files that may share storage blocks; shared blocks are already counted once in the total above.")
                    case .partial:
                        Text(FloeL10n.isChinese
                            ? "可能包含共享块的文件在同一估算基础上计入；共享块已在上方总计中只计一次。"
                            : "Files that may share storage blocks are included on the same estimated basis; shared blocks are already counted once in the total above.")
                    default:
                        Text("settings.data_management_view.shared_files_included")
                    }
                }
            }

            if let report = storage.report {
                Section {
                    if report.hasSharedEstimates {
                        // The file categories are the same snapshot's
                        // per-category basis; they sum to the App total shown
                        // above. The shareable-files row is a subset of that
                        // total (on the measured basis) or the non-additive
                        // allocated capacity (on the allocated estimate), and
                        // stays one tap away.
                        DisclosureGroup(isExpanded: $showsFileCapacityDetails) {
                            fileCapacityDetails(report, showsTotal: true)
                        } label: {
                            Text("settings.data_management_view.file_capacity_details")
                        }
                    } else {
                        fileCapacityDetails(report, showsTotal: false)
                    }
                } header: {
                    Text("settings.data_management_view.data_categories")
                }
                if report.scanErrorCount > 0 || report.changedOrVanishedCount > 0 || report.isPartial {
                    Section {
                        if report.scanErrorCount > 0 || report.changedOrVanishedCount > 0 {
                            Text(FloeL10n.l("settings.data_management_view.partial_scan_warning",
                                           report.scanErrorCount, report.changedOrVanishedCount))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if report.allocatedUnavailableCount > 0 || report.identityUnavailableCount > 0 {
                            Text("settings.data_management_view.partial_measurement_warning")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Toggle("settings.data_management_view.sync_canvases_across_devices", isOn: $canvasSyncEnabled)
                if let creativeStorage {
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.on_device_assets"), icon: "iphone", bytes: creativeStorage.local)
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.cloud_assets"), icon: "icloud", bytes: creativeStorage.cloud)
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.pending_download"), icon: "arrow.down.circle", bytes: creativeStorage.pendingDownload)
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.pending_release"), icon: "trash.circle", bytes: creativeStorage.pendingRelease)
                    if creativeStorage.releaseCount > 0 {
                        Button {
                            Task { await releaseCloudSpace() }
                        } label: {
                            HStack {
                                Label("settings.data_management_view.retry_freeing_cloud_space_now", systemImage: "icloud.slash")
                                Spacer()
                                if isReleasingCloudSpace { ProgressView() }
                            }
                        }
                        .disabled(isReleasingCloudSpace)
                    }
                    LabeledContent("settings.data_management_view.unreferenced_asset") {
                        Text(FloeL10n.l("settings.data_management_view.items", orphanedAssetCount, ByteCountFormatter.string(fromByteCount: orphanedAssetBytes, countStyle: .file)))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("settings.data_management_view.creative_space")
            } footer: {
                Text("settings.data_management_view.syncs_only_when_both_the_master")
            }


            Section {
                ForEach(cleanupPlan.candidates) { candidate in
                    if cleanupBusyCandidateIDs.contains(candidate.id) {
                        Text("settings.data_management_view.cleanup_owner_busy")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(FloeL10n.l("settings.data_management_view.cleanup_eligible_bytes",
                                        ByteCountFormatter.string(
                                            fromByteCount: cleanupPerCandidateBytes[candidate.id] ?? 0,
                                            countStyle: .file
                                        )))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                // The registered retain list is internal ownership detail: it
                // stays one tap away in the opened details instead of turning
                // the ordinary cleanup surface into a registry dump.
                if !cleanupPlan.retained.isEmpty {
                    DisclosureGroup {
                        ForEach(cleanupPlan.retained) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.retentionReason).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Text("settings.data_management_view.cleanup_retained_details")
                    }
                }
            } header: {
                Text("settings.data_management_view.cleanup_plan_header")
            } footer: {
                Text("settings.data_management_view.cleanup_confirm_detail")
            }

            Section {
                Button(role: .destructive) { confirmsCleanup = true } label: {
                    HStack {
                        Label("settings.data_management_view.safely_clean_caches_and_temporary_files", systemImage: "trash.slash")
                        Spacer()
                        if isCleaning {
                            ProgressView()
                            Button("settings.data_management_view.cleanup_cancel") {
                                cleanupCancellation.cancel()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .disabled(isCleaning)
            } footer: {
                if let outcome = cleanupOutcome {
                    let observed = ByteCountFormatter.string(
                        fromByteCount: outcome.observedAllocatedChangeBytes, countStyle: .file
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(FloeL10n.l("settings.data_management_view.cleanup_observed_allocation", observed))
                        if let volume = outcome.volumeAvailableCapacityChangeBytes {
                            let volumeText = ByteCountFormatter.string(fromByteCount: max(0, volume), countStyle: .file)
                            Text(FloeL10n.l("settings.data_management_view.cleanup_volume_change", volumeText))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        let deleted = outcome.perCandidate.values.reduce(0) { $0 + $1.deletedCount }
                        let skipped = outcome.perCandidate.values.reduce(0) {
                            $0 + $1.skippedOwnerBusyCount + $1.skippedProtectedCount + $1.skippedRecentCount
                        }
                        let failed = outcome.perCandidate.values.reduce(0) { $0 + $1.failedCount }
                        Text(FloeL10n.l("settings.data_management_view.cleanup_deleted_skipped_failed", deleted, skipped, failed))
                            .font(.caption2).foregroundStyle(.secondary)
                        if deleted == 0 {
                            Text("settings.data_management_view.cleanup_nothing_eligible")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("settings.data_management_view.cleanup_estimate_note")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("settings.data_management_view.cleans_only_rebuildable_caches_in_floe")
                }
            }
        }
        .navigationTitle(FloeL10n.l("settings.data_management_view.data_management"))
        .refreshable { await reload(.user) }
        .task {
            importCanvasSyncPreferenceFromCloud()
            NSUbiquitousKeyValueStore.default.synchronize()
            await reload(.appear)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
        )) { _ in
            importCanvasSyncPreferenceFromCloud()
        }
        .onChange(of: canvasSyncEnabled) { _, value in
            NSUbiquitousKeyValueStore.default.set(value, forKey: "creative.canvas.sync.enabled")
            NSUbiquitousKeyValueStore.default.synchronize()
        }
        .confirmationDialog("settings.data_management_view.run_safe_cleanup", isPresented: $confirmsCleanup, titleVisibility: .visible) {
            Button("settings.data_management_view.clean", role: .destructive) { Task { await clean() } }
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) {}
        } message: {
            Text("settings.data_management_view.rebuildable_caches_and_temporary_files_left")
        }
    }

    private enum ReloadTrigger {
        /// Page appearance/tab switch: render the shared snapshot; scan only
        /// when the refresh policy says it is stale or invalidated.
        case appear
        /// Explicit user refresh (pull to refresh): always re-scan.
        case user
    }

    /// File-based capacity rows. The total counts shared APFS clone blocks in
    /// full; it is a file measure shown one tap away in the opened details,
    /// distinct from the app footprint at the top of the page. The scan
    /// timestamp/duration/file-count diagnostics stay in the explicitly
    /// exported diagnostic report, not in this ordinary list.
    @ViewBuilder
    private func fileCapacityDetails(_ report: StorageDiagnosticReport, showsTotal: Bool) -> some View {
        if showsTotal {
            StorageUsageRow(
                title: FloeL10n.l("settings.data_management_view.file_capacity_total"),
                icon: "internaldrive",
                bytes: report.combinedBytes
            )
        }
        ForEach(report.categories) { category in
            VStack(alignment: .leading, spacing: 2) {
                StorageUsageRow(
                    title: category.name,
                    icon: category.systemImage,
                    bytes: category.allocatedBytes
                )
                // Ordinary view: the category name, its measured capacity and
                // the useful item count only. The allocated-vs-apparent
                // comparison and the VM-capacity wording are engineering
                // detail: they stay in the diagnostic export, never here.
                Text(FloeL10n.l("settings.data_management_view.files_count", category.fileCount))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        if let other = report.unattributed {
            StorageUsageRow(title: other.name, icon: other.systemImage, bytes: other.allocatedBytes)
        }
    }

    private func reload(_ trigger: ReloadTrigger) async {
        importCanvasSyncPreferenceFromCloud()
        if let value = try? await environment.creativeAssetStore.storageSummary() {
            creativeStorage = CreativeStorageSummary(
                local: value.local, cloud: value.cloud,
                pendingDownload: value.pendingDownload,
                pendingRelease: value.pendingRelease, releaseCount: value.releaseCount
            )
        }
        if let orphans = try? await environment.creativeAssetStore.orphanedAssets() {
            orphanedAssetCount = orphans.count
            orphanedAssetBytes = orphans.reduce(0) { $0 + $1.byteCount }
        }
        cleanupPlan = FloeStorageCleanupRegistry.plan()
        let result = await storage.refresh(explicit: trigger == .user)
        // The cleanup preview walks scratch roots; only recompute it when the
        // storage pass actually scanned, not on every cache-served reopen.
        if result == .scanned || trigger == .user {
            await refreshCleanupEstimate(authority: AppStorageCleanupAuthority(environment: environment))
        }
    }

    private func clean() async {
        guard !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }

        // Ownership is probed now, immediately before cleaning, and the cleaner
        // re-probes per candidate and per item. Unknown/busy owners delete
        // nothing (fail closed).
        cleanupCancellation = CleanupCancellation()
        let cancellation = cleanupCancellation
        let authority = AppStorageCleanupAuthority(environment: environment)
        let plan = FloeStorageCleanupRegistry.plan()
        cleanupPlan = plan
        let volumeBefore = Self.availableCapacityBytes()
        let outcome = await Task.detached(priority: .utility) {
            await StorageCleanup.execute(
                plan: plan,
                authority: authority,
                isCancelled: { cancellation.isCancelled }
            )
        }.value
        var measured = outcome
        if let volumeBefore, let volumeAfter = Self.availableCapacityBytes() {
            measured.volumeAvailableCapacityChangeBytes = volumeAfter - volumeBefore
        }
        cleanupOutcome = measured
        // Cleanup removed real files: invalidate the shared snapshot and take
        // one explicit refresh so the totals reflect the post-cleanup state.
        storage.invalidate(.cleanupCompleted)
        await storage.refresh(explicit: true)
        await refreshCleanupEstimate(authority: authority)
    }

    private func refreshCleanupEstimate(authority: AppStorageCleanupAuthority) async {
        let plan = FloeStorageCleanupRegistry.plan()
        let estimate = await StorageCleanup.estimate(plan: plan, authority: authority)
        cleanupEstimateBytes = estimate.eligibleAllocatedBytes
    }

    private static func availableCapacityBytes() -> Int64? {
        if let value = try? FloeStorageLayout.documentsRoot()?.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage {
            return value
        }
        return nil
    }

    private func releaseCloudSpace() async {
        guard !isReleasingCloudSpace else { return }
        isReleasingCloudSpace = true
        await environment.canvasCloudAssetService.releasePending()
        // Releasing cloud space removes local assets: mark the snapshot stale
        // so the next pass scans once instead of serving pre-release totals.
        storage.invalidate(.other("canvasCloudRelease"))
        await reload(.appear)
        isReleasingCloudSpace = false
    }

    private static let scanTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private func importCanvasSyncPreferenceFromCloud() {
        let cloud = NSUbiquitousKeyValueStore.default
        guard cloud.object(forKey: "creative.canvas.sync.enabled") != nil else { return }
        let remoteValue = cloud.bool(forKey: "creative.canvas.sync.enabled")
        if canvasSyncEnabled != remoteValue { canvasSyncEnabled = remoteValue }
    }
}

/// Cooperative cancellation box for the in-flight cleanup.
final class CleanupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Live, fail-closed ownership probe. Every call re-queries the real services
/// (environment registry, model downloads, unfinished media jobs) and the live
/// per-resource lease center; any query error, held lease or unknown owner
/// fails closed so nothing is deleted.
@MainActor
private final class AppStorageCleanupAuthority: StorageCleanupAuthority {
    private let environment: AppEnvironment
    private let leases = StorageCleanupLeaseCenter.shared

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func isOwnerIdle(_ owner: StorageCleanupOwner) async -> Bool {
        // Any live scratch lease (exact per-path) makes the owner busy.
        if await leases.isLeasedUnder(root: FloeScratch.scratchRoot()) { return false }
        switch owner {
        case .temporary, .notes, .skills, .office, .media, .floeCache:
            // Shared scratch: idle only while every heavy/shared consumer that
            // writes under Floe-owned directories is provably quiet.
            guard let containers = try? await environment.environmentRegistry.all() else { return false }
            if containers.contains(where: { $0.state == .active }) { return false }
            if !environment.localModelsCenter.activeDownloads.isEmpty { return false }
            guard let unfinished = try? await MediaGenerationJobStore(database: environment.database)
                .hasUnfinishedJobs() else { return false }
            return !unfinished
        case .environment:
            // Environment-owned roots are never deletable candidates today;
            // report idle only when no environment is active at all.
            guard let containers = try? await environment.environmentRegistry.all() else { return false }
            return !containers.contains(where: { $0.state == .active })
        }
    }

    func shouldRetain(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> Bool {
        // Classification-time filter: retain anything that is not positively
        // one of our registered scratch items. Atomic protection for live
        // directories lives in claimDeletion.
        !FloeStorageCleanupRegistry.scratchPurposes.contains { name.hasPrefix("\($0)-") }
    }

    /// Atomic per-item deletion claim coordinated with the live lease center:
    /// granted only while no component holds a lease on this exact path.
    func claimDeletion(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> StorageCleanupDeletionClaim? {
        await leases.claimForDeletion(path: itemURL.path)
    }

    func releaseDeletionClaim(_ claim: StorageCleanupDeletionClaim) async {
        await leases.releaseClaim(claim.id)
    }
}
private struct ManagementRow: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
        .frame(minHeight: FloeTheme.minimumTarget)
    }
}

private struct StorageUsageRow: View {
    let title: String
    let icon: String
    let bytes: Int64
    var emphasized = false

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(emphasized ? .headline : .body)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .foregroundStyle(emphasized ? .primary : .secondary)
                .monospacedDigit()
        }
        .frame(minHeight: FloeTheme.minimumTarget)
    }
}

struct FontManagementView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let store: DeviceFontStore
    @State private var designer = FontDesignCoordinator()
    @State private var records: [ManagedFontRecord] = []
    @State private var bundledFamilies: [BundledFontFamily] = []
    @State private var selection = FontManagementSelection()
    @State private var isSelecting = false
    @State private var pendingDeletion = Set<FontManagementItemID>()
    @State private var remoteURL = ""
    @State private var isWorking = false
    @State private var showsImporter = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var deletableItems: Set<FontManagementItemID> {
        Set(designer.projects.map { .design($0.id) } + records.map { .imported($0.id) })
    }
    private var allSelected: Bool { !deletableItems.isEmpty && selection.items == deletableItems }

    var body: some View {
        Form {
            designSection
            importedSection
            bundledSection
            addSection
            Section("settings.data_management_view.scope") {
                Text("settings.data_management_view.fonts_installed_here_are_available_globally")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message = successMessage ?? designer.installedMessage {
                Section { Text(message).foregroundStyle(.green) }
            }
        }
        .navigationTitle(FloeL10n.l("settings.data_management_view.font_resources"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    Button(FontDesignText.t(allSelected ? "取消全选" : "全选", allSelected ? "Deselect all" : "Select all")) {
                        if allSelected { selection.clear() } else { selection.selectAll(deletableItems) }
                    }.disabled(isWorking || deletableItems.isEmpty).accessibilityIdentifier("fontManagement.selectAll")
                }
                Button(FontDesignText.t(isSelecting ? "完成" : "选择", isSelecting ? "Done" : "Select")) {
                    isSelecting.toggle(); selection.clear()
                }.disabled(isWorking || designer.isOpening || (!isSelecting && deletableItems.isEmpty))
                    .accessibilityIdentifier("fontManagement.select")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                HStack {
                    if isWorking { ProgressView().controlSize(.small) }
                    Text(FontDesignText.t("已选 \(selection.items.count) 项", "\(selection.items.count) selected"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(FontDesignText.t("删除", "Delete"), role: .destructive) { pendingDeletion = selection.items }
                        .disabled(isWorking || selection.items.isEmpty).accessibilityIdentifier("fontManagement.deleteSelected")
                }.padding().background(.bar)
            }
        }
        .task {
            do { try await environment.fontDesignAIHost.resumePendingDeletions() }
            catch { errorMessage = error.localizedDescription }
            await designer.reload(); await reload()
        }
        .fullScreenCover(item: $designer.presented, onDismiss: {
            Task { await designer.reload(); await reload() }
        }) { session in FontDesignEditorView(session: session) }
        .sheet(isPresented: $showsImporter) {
            DocumentPickerView(contentTypes: Self.fontTypes) { url in
                showsImporter = false
                Task { await importFont(url) }
            }
        }
        .alert(FontDesignText.t("未能完成操作", "Unable to complete action"), isPresented: Binding(
            get: { errorMessage != nil || designer.errorMessage != nil },
            set: { if !$0 { errorMessage = nil; designer.errorMessage = nil } }
        )) {
            Button("workspace.office_document_editor_view.ok") { errorMessage = nil; designer.errorMessage = nil }
        } message: { Text(errorMessage ?? designer.errorMessage ?? "") }
        .confirmationDialog(FontDesignText.t("删除所选的 \(pendingDeletion.count) 项？", "Delete \(pendingDeletion.count) selected items?"),
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion.removeAll() } }),
            titleVisibility: .visible
        ) {
            Button(FontDesignText.t("删除", "Delete"), role: .destructive) {
                let requested = pendingDeletion; pendingDeletion.removeAll()
                Task { await remove(requested) }
            }
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) { pendingDeletion.removeAll() }
        } message: {
            Text(FontDesignText.t("删除草稿会一并删除其导出文件和助手会话；已安装的字体会保留，除非也选中了它。内置字体无法删除。",
                "Deleting drafts also removes their exports and assistant conversations. Installed fonts are kept unless selected separately. Included fonts cannot be deleted."))
        }
    }

    private var designSection: some View {
        Section(FontDesignText.t("字体设计", "Font design")) {
            if !isSelecting {
                Button { successMessage = nil; designer.newProject(store: store) } label: {
                    Label(FontDesignText.t("新建字体", "New typeface"), systemImage: "plus")
                }.disabled(isWorking || designer.isOpening).accessibilityIdentifier("fontManagement.newDesign")
            }
            if designer.isOpening { HStack { ProgressView(); Text(FontDesignText.t("正在打开…", "Opening…")) } }
            ForEach(designer.projects) { project in
                HStack {
                    Button {
                        if isSelecting { selection.toggle(.design(project.id)) }
                        else { successMessage = nil; designer.open(project, store: store) }
                    } label: {
                        HStack(spacing: 12) {
                            if isSelecting { selectionMark(.design(project.id)) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.title).foregroundStyle(.primary)
                                Text(project.modifiedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.frame(minHeight: FloeTheme.minimumTarget).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(isWorking || designer.isOpening)
                    if !isSelecting {
                        Menu {
                            Button(FontDesignText.t("打开", "Open"), systemImage: "pencil") { designer.open(project, store: store) }
                            Button(FontDesignText.t("删除", "Delete"), systemImage: "trash", role: .destructive) {
                                pendingDeletion = [.design(project.id)]
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .disabled(isWorking || designer.isOpening)
                            .accessibilityLabel(FontDesignText.t("字体草稿选项", "Typeface draft options"))
                    }
                }
                .swipeActions {
                    if !isSelecting {
                        Button(role: .destructive) { pendingDeletion = [.design(project.id)] } label: {
                            Label(FontDesignText.t("删除", "Delete"), systemImage: "trash")
                        }.disabled(isWorking || designer.isOpening)
                    }
                }
            }
        }
    }

    private var importedSection: some View {
        Section(FontDesignText.t("用户字体", "Your fonts")) {
            if records.isEmpty {
                Text(FontDesignText.t("尚未添加字体", "No added fonts yet")).foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                HStack(spacing: 12) {
                    if isSelecting {
                        Button { selection.toggle(.imported(record.id)) } label: { selectionMark(.imported(record.id)).frame(width: 44, height: 44) }
                            .buttonStyle(.plain).disabled(isWorking)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.displayName)
                        HStack(spacing: 8) {
                            Text(FontDesignText.t("用户字体", "Added"))
                            Text(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))
                        }.font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !isSelecting {
                        Menu {
                            if ["ttf", "otf"].contains(URL(fileURLWithPath: record.fileName).pathExtension.lowercased()) {
                                Button(FontDesignText.t("编辑副本", "Edit a copy"), systemImage: "pencil") {
                                    successMessage = nil; designer.edit(record, store: store)
                                }
                            }
                            Button(FontDesignText.t("删除", "Delete"), systemImage: "trash", role: .destructive) {
                                pendingDeletion = [.imported(record.id)]
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .disabled(isWorking || designer.isOpening)
                            .accessibilityLabel(FontDesignText.t("用户字体选项", "Added font options"))
                    }
                }.frame(minHeight: FloeTheme.minimumTarget)
                    .swipeActions {
                        if !isSelecting {
                            Button(role: .destructive) { pendingDeletion = [.imported(record.id)] } label: {
                                Label(FontDesignText.t("删除", "Delete"), systemImage: "trash")
                            }.disabled(isWorking)
                        }
                    }
            }
        }
    }

    private var bundledSection: some View {
        Section {
            ForEach(bundledFamilies) { family in
                DisclosureGroup {
                    ForEach(family.faces) { face in
                        Text(face.displayName).font(.custom(face.id, size: 17, relativeTo: .body))
                            .frame(minHeight: 32)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(family.displayName)
                        HStack(spacing: 8) {
                            Label(FontDesignText.t("内置", "Included"), systemImage: "lock")
                            Text(FontDesignText.t("\(family.faces.count) 款", "\(family.faces.count) styles"))
                        }.font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: FloeTheme.minimumTarget)
                }
            }
        } header: {
            HStack {
                Text(FontDesignText.t("内置字体", "Included fonts"))
                Spacer()
                Text(String(bundledFamilies.count)).monospacedDigit()
            }
        } footer: {
            Text(FontDesignText.t("内置字体供所有工作区使用，随 App 更新，不能删除。", "Included fonts are available in every workspace and updated with the App. They cannot be deleted."))
        }
    }

    private var addSection: some View {
        Section {
            Button { showsImporter = true } label: {
                Label("settings.data_management_view.import_from_files", systemImage: "folder.badge.plus")
            }.disabled(isWorking || isSelecting)
            TextField("settings.data_management_view.public_https_direct_font_link", text: $remoteURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .disabled(isWorking || isSelecting)
            Button { Task { await installRemote() } } label: {
                HStack {
                    Label("settings.data_management_view.download_and_add_to_the_global", systemImage: "arrow.down.circle")
                    Spacer()
                    if isWorking { ProgressView() }
                }
            }.disabled(isWorking || isSelecting || remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: { Text("settings.data_management_view.add_font") }
          footer: { Text("settings.data_management_view.only_public_https_links_and_genuine") }
    }

    private func selectionMark(_ item: FontManagementItemID) -> some View {
        Image(systemName: selection.items.contains(item) ? "checkmark.circle.fill" : "circle")
            .font(.title3).foregroundStyle(selection.items.contains(item) ? Color.accentColor : Color.secondary)
            .accessibilityLabel(FontDesignText.t(selection.items.contains(item) ? "已选择" : "未选择", selection.items.contains(item) ? "Selected" : "Not selected"))
    }
    private static var fontTypes: [UTType] { ["ttf", "otf", "ttc", "otc"].compactMap { UTType(filenameExtension: $0) } }
    private func reload() async {
        records = await store.list()
        bundledFamilies = await Task.detached(priority: .utility) { BundledFontRegistrar.families(in: Bundle.main.bundleURL) }.value
        selection.retainAvailable(deletableItems)
    }
    private func installRemote() async {
        guard let url = URL(string: remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = FloeL10n.l("settings.data_management_view.invalid_font_url"); return
        }
        isWorking = true; defer { isWorking = false }
        do {
            let record = try await store.install(from: url); remoteURL = ""
            successMessage = FloeL10n.l("settings.data_management_view.installed_available_in_all_floe_workspaces", record.displayName)
            StorageDiagnosticService.shared.invalidate(.other("fontStore")); await reload()
        } catch { errorMessage = error.localizedDescription }
    }
    private func importFont(_ url: URL) async {
        isWorking = true; defer { isWorking = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let record = try await store.importFont(from: url)
            successMessage = FloeL10n.l("settings.data_management_view.imported_available_in_all_floe_workspaces", record.displayName)
            StorageDiagnosticService.shared.invalidate(.other("fontStore")); await reload()
        } catch { errorMessage = error.localizedDescription }
    }
    private func remove(_ requested: Set<FontManagementItemID>) async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        let result = await FontManagementRemovalService.remove(requested, projects: designer.projects,
            fonts: records, store: store, host: environment.fontDesignAIHost)
        StorageDiagnosticService.shared.invalidate(.other("fontStore"))
        await designer.reload(); await reload()
        if !result.removed.isEmpty { successMessage = FontDesignText.t("已删除 \(result.removed.count) 项", "Deleted \(result.removed.count) items") }
        if result.failures.isEmpty { isSelecting = false; selection.clear() }
        else {
            errorMessage = FontDesignText.t("\(result.failures.count) 项未能删除。", "\(result.failures.count) items could not be deleted.")
                + "\n" + result.failures.prefix(3).map { $0.title + "：" + $0.message }.joined(separator: "\n")
        }
    }
}
#endif
