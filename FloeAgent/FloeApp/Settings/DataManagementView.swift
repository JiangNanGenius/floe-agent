// FloeApp — Unified archive, font, storage and safe-cleanup settings.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloePersistence

struct DataManagementView: View {
    let environment: AppEnvironment
    let conversationCenter: ConversationCenter
    @StateObject private var storage = StorageDiagnosticService()
    @State private var isCleaning = false
    @State private var confirmsCleanup = false
    @State private var cleanupOutcome: StorageCleanupPlanResult?
    @State private var cleanupEstimateBytes: Int64 = 0
    @AppStorage("creative.canvas.sync.enabled") private var canvasSyncEnabled = true
    @State private var creativeStorage: CreativeStorageSummary?
    @State private var isReleasingCloudSpace = false
    @State private var orphanedAssetCount = 0
    @State private var orphanedAssetBytes: Int64 = 0

    private struct CreativeStorageSummary {
        let local: Int64
        let cloud: Int64
        let pendingDownload: Int64
        let pendingRelease: Int64
        let releaseCount: Int
    }

    var body: some View {
        Form {
            Section("settings.data_management_view.space_overview") {
                if let report = storage.report {
                    StorageUsageRow(
                        title: FloeL10n.l("settings.data_management_view.floe_total_usage"),
                        icon: "internaldrive",
                        bytes: report.combinedBytes,
                        emphasized: true
                    )
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.app_installer"), icon: "shippingbox", bytes: report.bundleBytes)
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.user_data"), icon: "externaldrive", bytes: report.totalAllocatedBytes)
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.safe_to_clean"), icon: "sparkles", bytes: cleanupEstimateBytes)
                } else {
                    HStack {
                        ProgressView()
                        if storage.isScanning {
                            Button(role: .destructive) { storage.cancel() } label: {
                                Text("settings.data_management_view.stop_scan")
                            }
                        } else {
                            Text("settings.data_management_view.calculating_actual_usage").foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                if let report = storage.report, report.isSharedAllocationEstimate {
                    Text("settings.data_management_view.shared_allocation_note")
                }
            }

            if let report = storage.report {
                Section("settings.data_management_view.data_categories") {
                    ForEach(report.categories) { category in
                        VStack(alignment: .leading, spacing: 2) {
                            StorageUsageRow(
                                title: category.name,
                                icon: category.systemImage,
                                bytes: category.allocatedBytes
                            )
                            if category.showsLogicalCapacity {
                                Text(FloeL10n.l(
                                    "settings.data_management_view.host_allocated",
                                    ByteCountFormatter.string(fromByteCount: category.allocatedBytes, countStyle: .file)
                                ) + " · " + FloeL10n.l(
                                    "settings.data_management_view.configured_capacity",
                                    ByteCountFormatter.string(fromByteCount: category.logicalBytes, countStyle: .file)
                                ))
                                .font(.caption2).foregroundStyle(.secondary)
                            } else if category.isSharedEstimate {
                                Text("settings.data_management_view.shared_allocation_note")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(FloeL10n.l("settings.data_management_view.files_count", category.fileCount))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    if let other = report.unattributed {
                        StorageUsageRow(title: other.name, icon: other.systemImage, bytes: other.allocatedBytes)
                    }
                }
                if report.scanErrorCount > 0 || report.changedOrVanishedCount > 0 {
                    Section {
                        Text(FloeL10n.l("settings.data_management_view.partial_scan_warning",
                                       report.scanErrorCount, report.changedOrVanishedCount))
                            .font(.caption2).foregroundStyle(.secondary)
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
                NavigationLink {
                    ArchivedConversationsView(
                        center: conversationCenter,
                        showsDoneButton: false
                    )
                } label: {
                    ManagementRow(
                        title: FloeL10n.l("chat.conversation_list_view.archive"),
                        detail: FloeL10n.l("settings.data_management_view.restore_delete_individually_delete_in_bulk"),
                        icon: "archivebox"
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
            }

            Section {
                Button(role: .destructive) { confirmsCleanup = true } label: {
                    HStack {
                        Label("settings.data_management_view.safely_clean_caches_and_temporary_files", systemImage: "trash.slash")
                        Spacer()
                        if isCleaning { ProgressView() }
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
        .refreshable { await reload() }
        .task {
            importCanvasSyncPreferenceFromCloud()
            NSUbiquitousKeyValueStore.default.synchronize()
            await reload()
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

    private func reload() async {
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
        await storage.scan()
        await refreshCleanupEstimate(authority: await makeCleanupAuthority())
    }

    private func clean() async {
        guard !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }

        // Ownership is probed now, immediately before cleaning, and the cleaner
        // re-probes per candidate and per item. Unknown/busy owners delete
        // nothing (fail closed).
        let authority = await makeCleanupAuthority()
        let plan = FloeStorageCleanupRegistry.plan()
        let volumeBefore = Self.availableCapacityBytes()
        let outcome = await Task.detached(priority: .utility) {
            StorageCleanup.execute(plan: plan, authority: authority)
        }.value
        var measured = outcome
        if let volumeBefore, let volumeAfter = Self.availableCapacityBytes() {
            measured.volumeAvailableCapacityChangeBytes = volumeAfter - volumeBefore
        }
        cleanupOutcome = measured
        await refreshCleanupEstimate(authority: authority)
        await storage.scan()
    }

    private func makeCleanupAuthority() async -> AppStorageCleanupAuthority {
        let activeContainers = (try? await environment.environmentRegistry.all()) ?? []
        let environmentActive = activeContainers.contains { $0.state == .active }
        let modelDownloadsActive = await MainActor.run { !environment.localModelsCenter.activeDownloads.isEmpty }
        var mediaActive = true // fail closed when the probe errors
        if let jobs = try? await MediaGenerationJobStore(database: environment.database).allJobs(limit: 200) {
            mediaActive = jobs.contains { !$0.state.isTerminal }
        }
        let idle = !environmentActive && !modelDownloadsActive && !mediaActive
        return AppStorageCleanupAuthority(appIdle: idle)
    }

    private func refreshCleanupEstimate(authority: AppStorageCleanupAuthority) async {
        let plan = FloeStorageCleanupRegistry.plan()
        let estimate = await Task.detached(priority: .utility) {
            StorageCleanup.estimate(plan: plan, authority: authority)
        }.value
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
        await reload()
        isReleasingCloudSpace = false
    }

    private func importCanvasSyncPreferenceFromCloud() {
        let cloud = NSUbiquitousKeyValueStore.default
        guard cloud.object(forKey: "creative.canvas.sync.enabled") != nil else { return }
        let remoteValue = cloud.bool(forKey: "creative.canvas.sync.enabled")
        if canvasSyncEnabled != remoteValue { canvasSyncEnabled = remoteValue }
    }
}

/// Fail-closed ownership probe: only the app's own scratch is owned by this
/// cleaner, and it is idle only when no environment, model download or media
/// job is active. Any owner this authority cannot positively prove idle (or a
/// probe error) results in nothing being deleted.
private struct AppStorageCleanupAuthority: StorageCleanupAuthority {
    let appIdle: Bool

    func isOwnerIdle(_ owner: StorageCleanupOwner) -> Bool {
        switch owner {
        case .temporary, .floeCache:
            return appIdle
        }
    }

    func shouldRetain(itemURL: URL, name: String, owner: StorageCleanupOwner) -> Bool {
        false
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
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ record: ManagedFontRecord) async {
        do {
            try await store.remove(id: record.id)
            successMessage = FloeL10n.l("settings.data_management_view.removed", record.displayName)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
