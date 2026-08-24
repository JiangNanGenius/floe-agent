// FloeApp — Unified archive, font, storage and safe-cleanup settings.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore

struct DataManagementView: View {
    let environment: AppEnvironment
    let conversationCenter: ConversationCenter
    @State private var snapshot: AppStorageSnapshot?
    @State private var isLoading = false
    @State private var isCleaning = false
    @State private var confirmsCleanup = false
    @State private var cleanupResult: Int64?

    var body: some View {
        Form {
            Section("空间概览") {
                if let snapshot {
                    StorageUsageRow(
                        title: "Floe 总占用",
                        icon: "internaldrive",
                        bytes: snapshot.combinedBytes,
                        emphasized: true
                    )
                    StorageUsageRow(title: "App 安装包", icon: "shippingbox", bytes: snapshot.bundleBytes)
                    StorageUsageRow(title: "用户数据", icon: "externaldrive", bytes: snapshot.dataBytes)
                    StorageUsageRow(title: "可安全清理", icon: "sparkles", bytes: snapshot.safeCleanupBytes)
                } else {
                    HStack {
                        ProgressView()
                        Text("正在统计实际占用…").foregroundStyle(.secondary)
                    }
                }
            }

            if let snapshot {
                Section("数据分类") {
                    ForEach(snapshot.categories) { category in
                        StorageUsageRow(
                            title: category.name,
                            icon: category.systemImage,
                            bytes: category.bytes
                        )
                    }
                }
            }

            Section("管理") {
                NavigationLink {
                    ArchivedConversationsView(
                        center: conversationCenter,
                        showsDoneButton: false
                    )
                } label: {
                    ManagementRow(
                        title: "归档区",
                        detail: "恢复、单项删除、批量删除或一键清空",
                        icon: "archivebox"
                    )
                }

                NavigationLink {
                    FontManagementView(store: environment.fontStore)
                } label: {
                    ManagementRow(
                        title: "字体资源",
                        detail: "下载一次，所有 Floe 工作区共用",
                        icon: "textformat"
                    )
                }
            }

            Section {
                Button(role: .destructive) { confirmsCleanup = true } label: {
                    HStack {
                        Label("安全清理缓存与临时文件", systemImage: "trash.slash")
                        Spacer()
                        if isCleaning { ProgressView() }
                    }
                }
                .disabled(isCleaning)
            } footer: {
                if let cleanupResult {
                    Text("上次释放 \(ByteCountFormatter.string(fromByteCount: cleanupResult, countStyle: .file))。工作区、文档、模型、字体、附件、数据库和凭据未被删除。")
                } else {
                    Text("只清理 Floe 沙盒中的可重建缓存，以及一小时前遗留的临时文件；不会删除工作区、文档、模型、字体、附件、数据库或凭据。")
                }
            }
        }
        .navigationTitle("数据管理")
        .refreshable { await reload() }
        .task { await reload() }
        .confirmationDialog("执行安全清理？", isPresented: $confirmsCleanup, titleVisibility: .visible) {
            Button("清理", role: .destructive) { Task { await clean() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除可重建缓存和一小时前遗留的临时文件。用户内容不会被删除。")
        }
    }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        snapshot = await AppStorageInspector.snapshot()
        isLoading = false
    }

    private func clean() async {
        guard !isCleaning else { return }
        isCleaning = true
        cleanupResult = await AppStorageInspector.cleanSafeCaches()
        snapshot = await AppStorageInspector.snapshot()
        isCleaning = false
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
            Section("Floe 全局字体") {
                if records.isEmpty {
                    ContentUnavailableView(
                        "还没有 Floe 全局字体",
                        systemImage: "textformat",
                        description: Text("导入或下载一次后，Word、PDF 和所有工作区都可复用。")
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
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section {
                Button { showsImporter = true } label: {
                    Label("从“文件”导入", systemImage: "folder.badge.plus")
                }
                TextField("公开 HTTPS 字体直链", text: $remoteURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    Task { await installRemote() }
                } label: {
                    HStack {
                        Label("下载并加入全局字体库", systemImage: "arrow.down.circle")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(isWorking || remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("添加字体")
            } footer: {
                Text("仅接受公开 HTTPS 地址和真实的 TTF、OTF、TTC、OTC 字体，单文件上限 32 MB；私网地址、凭据 URL 和伪装文件会被拒绝。字体按内容去重，不会因不同工作区重复下载。")
            }

            Section("作用范围") {
                Text("这里安装的字体会全局提供给 Floe 的所有工作区和文档流程。由于 Apple 平台限制，它们不会被静默安装给 Floe 以外的其他 App。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let successMessage {
                Section { Text(successMessage).foregroundStyle(.green) }
            }
        }
        .navigationTitle("字体资源")
        .task { await reload() }
        .sheet(isPresented: $showsImporter) {
            DocumentPickerView(contentTypes: Self.fontTypes) { url in
                showsImporter = false
                Task { await importFont(url) }
            }
        }
        .alert("无法添加字体", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .confirmationDialog(
            "从所有 Floe 工作区移除此字体？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久移除", role: .destructive) {
                guard let record = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await remove(record) }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
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
            errorMessage = "字体地址无效。"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let record = try await store.install(from: url)
            remoteURL = ""
            successMessage = "已安装 \(record.displayName)，所有 Floe 工作区可用。"
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
            successMessage = "已导入 \(record.displayName)，所有 Floe 工作区可用。"
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ record: ManagedFontRecord) async {
        do {
            try await store.remove(id: record.id)
            successMessage = "已移除 \(record.displayName)。"
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
                ("models", "本地模型", "cpu", "LocalModels"),
                ("workspaces", "私有工作区", "folder.badge.gearshape", "PrivateTasks"),
                ("fonts", "字体资源", "textformat", "Fonts"),
                ("attachments", "附件", "paperclip", "Attachments"),
                ("generated", "生成内容", "photo.on.rectangle", "GeneratedImages"),
                ("browser", "浏览器产物", "globe", "BrowserArtifacts"),
                ("checkpoints", "任务检查点", "arrow.trianglehead.2.clockwise", "Checkpoints")
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
                name: "数据库、配置与其他数据",
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
