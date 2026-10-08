// FloeApp — Unified archive, font, storage and safe-cleanup settings.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloePersistence

struct DataManagementView: View {
    let environment: AppEnvironment
    let conversationCenter: ConversationCenter
    @State private var snapshot: AppStorageSnapshot?
    @State private var isLoading = false
    @State private var isCleaning = false
    @State private var confirmsCleanup = false
    @State private var cleanupResult: Int64?
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
                if let snapshot {
                    StorageUsageRow(
                        title: FloeL10n.l("settings.data_management_view.floe_total_usage"),
                        icon: "internaldrive",
                        bytes: snapshot.combinedBytes,
                        emphasized: true
                    )
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.app_installer"), icon: "shippingbox", bytes: snapshot.bundleBytes)
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.user_data"), icon: "externaldrive", bytes: snapshot.dataBytes)
                    StorageUsageRow(title: FloeL10n.l("settings.data_management_view.safe_to_clean"), icon: "sparkles", bytes: snapshot.safeCleanupBytes)
                } else {
                    HStack {
                        ProgressView()
                        Text("settings.data_management_view.calculating_actual_usage").foregroundStyle(.secondary)
                    }
                }
            }

            if let snapshot {
                Section("settings.data_management_view.data_categories") {
                    ForEach(snapshot.categories) { category in
                        StorageUsageRow(
                            title: category.name,
                            icon: category.systemImage,
                            bytes: category.bytes
                        )
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

            Section("settings.data_management_view.manage") {
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
                if let cleanupResult {
                    Text(FloeL10n.l("settings.data_management_view.last_cleanup_workspaces_documents_models_fonts", ByteCountFormatter.string(fromByteCount: cleanupResult, countStyle: .file)))
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
        guard !isLoading else { return }
        isLoading = true
        snapshot = await AppStorageInspector.snapshot()
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
        isLoading = false
    }

    private func clean() async {
        guard !isCleaning else { return }
        isCleaning = true
        cleanupResult = await AppStorageInspector.cleanSafeCaches()
        snapshot = await AppStorageInspector.snapshot()
        isCleaning = false
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

struct AppStorageCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let systemImage: String
    let bytes: Int64
}

struct AppStorageSnapshot: Sendable {
    let bundleBytes: Int64
    let dataBytes: Int64
    let safeCleanupBytes: Int64
    let categories: [AppStorageCategory]
    var combinedBytes: Int64 { bundleBytes + dataBytes }
}

enum AppStorageInspector {
    static func snapshot() async -> AppStorageSnapshot {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let floe = support?.appendingPathComponent("FloeAgent", isDirectory: true)
            let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first
            let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
            let cache = manager.urls(for: .cachesDirectory, in: .userDomainMask).first
            let temporary = manager.temporaryDirectory
            let named: [(String, String, String, String)] = [
                ("models", FloeL10n.l("localmodels.title"), "cpu", "LocalModels"),
                ("workspaces", FloeL10n.l("settings.data_management_view.private_workspace"), "folder.badge.gearshape", "PrivateTasks"),
                ("fonts", FloeL10n.l("settings.data_management_view.font_resources"), "textformat", "Fonts"),
                ("attachments", FloeL10n.l("settings.data_management_view.attachments"), "paperclip", "Attachments"),
                ("generated", FloeL10n.l("platform.background_run_coordinator.generate_content"), "photo.on.rectangle", "GeneratedImages"),
                ("browser", FloeL10n.l("settings.data_management_view.browser_downloads"), "globe", "BrowserArtifacts"),
                ("checkpoints", FloeL10n.l("settings.data_management_view.task_checkpoint"), "arrow.trianglehead.2.clockwise", "Checkpoints")
            ]
            var categories = named.map { id, name, icon, component in
                AppStorageCategory(
                    id: id,
                    name: name,
                    systemImage: icon,
                    bytes: floe.map { allocatedBytes(at: $0.appendingPathComponent(component)) } ?? 0
                )
            }
            let categorizedSupport = categories.reduce(Int64(0)) { $0 + $1.bytes }
            let supportBytes = floe.map(allocatedBytes(at:)) ?? 0
            categories.append(AppStorageCategory(
                id: "other",
                name: FloeL10n.l("settings.data_management_view.databases_configuration_and_other_data"),
                systemImage: "cylinder",
                bytes: max(0, supportBytes - categorizedSupport)
            ))
            return AppStorageSnapshot(
                bundleBytes: allocatedBytes(at: Bundle.main.bundleURL),
                dataBytes: (library.map(allocatedBytes(at:)) ?? 0)
                    + (documents.map(allocatedBytes(at:)) ?? 0)
                    + allocatedBytes(at: temporary),
                safeCleanupBytes: (cache.map(allocatedBytes(at:)) ?? 0) + allocatedBytes(at: temporary),
                categories: categories
            )
        }.value
    }

    static func cleanSafeCaches() async -> Int64 {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let cache = manager.urls(for: .cachesDirectory, in: .userDomainMask).first
            let temporary = manager.temporaryDirectory
            let before = (cache.map(allocatedBytes(at:)) ?? 0) + allocatedBytes(at: temporary)
            if let cache { removeChildren(of: cache, olderThan: nil) }
            removeChildren(of: temporary, olderThan: Date().addingTimeInterval(-3_600))
            let after = (cache.map(allocatedBytes(at:)) ?? 0) + allocatedBytes(at: temporary)
            return max(0, before - after)
        }.value
    }

    private static func allocatedBytes(at root: URL) -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return 0 }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey
        ]
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            let values = try? root.resourceValues(forKeys: keys)
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private static func removeChildren(of directory: URL, olderThan cutoff: Date?) {
        let manager = FileManager.default
        let children = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { continue }
            if let cutoff, let modified = values?.contentModificationDate, modified >= cutoff { continue }
            try? manager.removeItem(at: child)
        }
    }
}
#endif
