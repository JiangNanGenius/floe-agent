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

    var body: some View {
        Form {
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
                        title: FloeL10n.l("settings.data_management_view.floe_total_usage"),
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

            if let report = storage.report, report.hasSharedEstimates {
                // A dedicated section for Floe's SHARED/cloneable data (VM
                // runtime images, environments, shared project resources),
                // separate from Floe's own usage and the cleanup scope. The
                // ordinary page shows only the plain section name and the
                // measured file capacity of what the census identified as
                // sharing capable: never the whole Floe file total, never the
                // device capacity, and no technical footnotes (the lower-bound
                // and per-root details stay available in the opened details).
                Section {
                    StorageUsageRow(
                        title: FloeL10n.l("settings.data_management_view.shared_file_capacity"),
                        icon: "doc.on.doc",
                        bytes: report.cloneCapableAllocatedBytes
                    )
                } header: {
                    Text("settings.data_management_view.shared_files")
                }
            }

            if let report = storage.report {
                Section {
                    if report.hasSharedEstimates {
                        // The file categories are the same snapshot's measured
                        // per-category capacities; they sum to the App total
                        // shown above (shared/clone-capable data is counted
                        // once there and listed again only as its own
                        // non-additive section). They stay one tap away.
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
    let store: DeviceFontStore
    @State private var records: [ManagedFontRecord] = []
    @State private var remoteURL = ""
    @State private var isWorking = false
    @State private var showsImporter = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var pendingRemoval: ManagedFontRecord?

    var body: some View {
        Form {
            Section("settings.data_management_view.floe_global_fonts") {
                if records.isEmpty {
                    ContentUnavailableView("settings.data_management_view.no_floe_global_fonts_yet",
                        systemImage: "textformat",
                        description: Text("settings.data_management_view.after_importing_or_downloading_once_word")
                    )
                } else {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.displayName)
                            Text(record.familyNames.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                        .swipeActions {
                            Button(role: .destructive) { pendingRemoval = record } label: {
                                Label("workspace.workspace_canvas_view.delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section {
                Button { showsImporter = true } label: {
                    Label("settings.data_management_view.import_from_files", systemImage: "folder.badge.plus")
                }
                TextField("settings.data_management_view.public_https_direct_font_link", text: $remoteURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    Task { await installRemote() }
                } label: {
                    HStack {
                        Label("settings.data_management_view.download_and_add_to_the_global", systemImage: "arrow.down.circle")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(isWorking || remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("settings.data_management_view.add_font")
            } footer: {
                Text("settings.data_management_view.only_public_https_links_and_genuine")
            }

            Section("settings.data_management_view.scope") {
                Text("settings.data_management_view.fonts_installed_here_are_available_globally")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let successMessage {
                Section { Text(successMessage).foregroundStyle(.green) }
            }
        }
        .navigationTitle(FloeL10n.l("settings.data_management_view.font_resources"))
        .task { await reload() }
        .sheet(isPresented: $showsImporter) {
            DocumentPickerView(contentTypes: Self.fontTypes) { url in
                showsImporter = false
                Task { await importFont(url) }
            }
        }
        .alert("settings.data_management_view.could_not_add_the_font", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("workspace.office_document_editor_view.ok") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "common.unknown_error")
        }
        .confirmationDialog("settings.data_management_view.remove_this_font_from_all_floe",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("settings.data_management_view.remove_permanently", role: .destructive) {
                guard let record = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await remove(record) }
            }
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) { pendingRemoval = nil }
        }
    }

    private static var fontTypes: [UTType] {
        ["ttf", "otf", "ttc", "otc"].compactMap { UTType(filenameExtension: $0) }
    }

    private func reload() async {
        records = await store.list()
    }

    private func installRemote() async {
        guard let url = URL(string: remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = FloeL10n.l("settings.data_management_view.invalid_font_url")
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let record = try await store.install(from: url)
            remoteURL = ""
            successMessage = FloeL10n.l("settings.data_management_view.installed_available_in_all_floe_workspaces", record.displayName)
            // Fonts live under a scanned root: the shared snapshot is stale.
            StorageDiagnosticService.shared.invalidate(.other("fontStore"))
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFont(_ url: URL) async {
        isWorking = true
        defer { isWorking = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let record = try await store.importFont(from: url)
            successMessage = FloeL10n.l("settings.data_management_view.imported_available_in_all_floe_workspaces", record.displayName)
            StorageDiagnosticService.shared.invalidate(.other("fontStore"))
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ record: ManagedFontRecord) async {
        do {
            try await store.remove(id: record.id)
            successMessage = FloeL10n.l("settings.data_management_view.removed", record.displayName)
            StorageDiagnosticService.shared.invalidate(.other("fontStore"))
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
