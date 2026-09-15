// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeEnvironments
import FloePackages

/// Jobs survive navigation and are drained by the environment lifecycle before deletion.
@MainActor final class EnvironmentPackageJobs: ObservableObject {
    static let shared = EnvironmentPackageJobs()
    @Published private(set) var running: Set<String> = []
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var failures: Set<String> = []
    @Published private(set) var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    func start(id: String, title: String, action: FloePlatformServices.PackageAction) {
        start(id: id, title: title) { try await FloePlatformServices.shared.managePackage(id: id, action: action) }
    }

    func start(id: String, title: String, operation: @escaping @Sendable () async throws -> String) {
        guard !running.contains(id) else { return }
        running.insert(id)
        messages[id] = title
        failures.remove(id)
        tasks[id] = Task {
            do { messages[id] = try await operation() }
            catch is CancellationError { messages[id] = "任务已取消；重新读取依赖以确认当前状态" }
            catch { messages[id] = String(describing: error); failures.insert(id) }
            running.remove(id)
            tasks[id] = nil
            revision += 1
        }
    }
    func cancel(id: String) {
        guard let task = tasks[id] else { return }
        messages[id] = "正在取消并等待事务结束…"
        task.cancel()
    }
    func cancelAndWait(id: String) async {
        guard let task = tasks[id] else { return }
        cancel(id: id)
        await task.value
    }
}

struct EnvironmentManagerView: View {
    var ownerTitles: [String: String] = [:]
    @State private var reports: [FloePlatformServices.EnvironmentReport] = []
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @ObservedObject private var jobs = EnvironmentPackageJobs.shared

    var body: some View {
        List {
            Section {
                Text("会话 → 项目 → 共享 → 基础").font(.headline)
                Text("依赖按层查找，安装只写入所选环境。容器用于管理依赖、数据和生命周期。").font(.subheadline).foregroundStyle(.secondary)
            }
            if loading { ProgressView("读取环境与容量…") }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive)
                    Button("重试") { Task { await reload() } }
                }
            }
            ForEach(ContainerKind.allCases, id: \.self) { kind in
                let matches = reports.filter { $0.record.kind == kind && (query.isEmpty || displayName(for: $0).localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)) }
                if !matches.isEmpty {
                    Section(Self.title(kind)) {
                        ForEach(matches) { report in
                            NavigationLink {
                                EnvironmentDetailView(report: report, displayName: displayName(for: report))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: Self.icon(kind)).foregroundStyle(FloeTheme.primary).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(displayName(for: report)).font(.headline)
                                        Text(report.issue == nil ? "\(report.packages.count) 个本层依赖 · \(ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file))" : "读取失败 · 点击查看恢复信息")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(report.record.requiresRebuild ? "需要重建依赖" : Self.state(report.record.state)).font(.caption)
                                    }
                                    if jobs.running.contains(report.id) { Spacer(); ProgressView().accessibilityLabel("软件包任务正在运行") }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            if !loading && reports.isEmpty && error == nil {
                ContentUnavailableView("尚无项目或会话环境", systemImage: "shippingbox", description: Text("打开工作区或在会话中运行本地工具后，对应环境会出现在这里。"))
            }
        }
        .navigationTitle("environment.manager.title")
        .searchable(text: $query, prompt: "搜索环境名称或 ID")
        .refreshable { await reload() }
        .toolbar { Button("刷新", systemImage: "arrow.clockwise") { Task { await reload() } }.disabled(loading) }
        .task { await reload() }
        .onChange(of: jobs.revision) { Task { await reload() } }
    }

    private func displayName(for report: FloePlatformServices.EnvironmentReport) -> String {
        if let name = report.record.name { return name }
        if let owner = report.record.ownerID, let title = ownerTitles[owner] { return title }
        return Self.title(report.record.kind) + " · " + String(report.id.prefix(8))
    }

    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { reports = try await FloePlatformServices.shared.environmentReports(); error = nil }
        catch { self.error = String(describing: error) }
    }
    static func title(_ kind: ContainerKind) -> String {
        switch kind { case .session: "会话"; case .project: "项目"; case .shared: "共享依赖"; case .template: "模板" }
    }
    static func icon(_ kind: ContainerKind) -> String {
        switch kind { case .session: "bubble.left.and.bubble.right"; case .project: "folder"; case .shared: "square.stack.3d.up"; case .template: "doc.on.doc" }
    }
    static func state(_ state: ContainerState) -> String {
        switch state { case .active: "可用"; case .stopped: "已停止"; case .deleting: "正在删除" }
    }
}

private struct EnvironmentDetailView: View {
    let report: FloePlatformServices.EnvironmentReport
    let displayName: String
    @State private var addingSource = false
    @State private var editingSource: AptSource?
    @State private var sourceURL = ""
    @State private var sourceSuite = "stable"
    @State private var sourceComponent = "main"
    @State private var sourceKey = ""
    @State private var trustUnsignedSource = false
    @State private var current: FloePlatformServices.EnvironmentReport?
    @State private var packages: FloePlatformServices.PackageReport?
    @State private var error: String?
    @State private var busy = false
    @State private var templateName = ""
    @State private var pendingRemoval: String?
    @State private var confirmDelete = false
    @State private var query = ""
    @ObservedObject private var jobs = EnvironmentPackageJobs.shared
    @Environment(\.dismiss) private var dismiss
    private var record: ContainerRecord { (current ?? report).record }
    private var writable: Bool { record.kind.isWritableLayer && record.state == .active && !record.requiresRebuild && !busy && !jobs.running.contains(report.id) }

    var body: some View {
        List {
            Section("environment.manager.selected") {
                LabeledContent("类型", value: EnvironmentManagerView.title(record.kind))
                LabeledContent("状态", value: EnvironmentManagerView.state(record.state))
                if let issue = (current ?? report).issue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive) }
                LabeledContent((current ?? report).issue == nil ? "本层容量" : "上次记录的容量", value: ByteCountFormatter.string(fromByteCount: (current ?? report).bytes, countStyle: .file))
                if record.requiresRebuild { Label(record.rebuildReason ?? "依赖需要重建；数据已保留", systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.pending) }
                DisclosureGroup("环境标识与归属") {
                    Text(record.id).textSelection(.enabled)
                    if let owner = record.ownerID { LabeledContent("所属项目或会话", value: owner) }
                    if let parent = record.parentID { LabeledContent("父环境", value: parent) }
                    LabeledContent("基础层版本", value: record.baseRevision)
                }.font(.caption)
            }
            if busy { ProgressView("正在处理…") }
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive); Button("action.reload") { Task { await reload() } } } }
            if let message = jobs.messages[report.id] {
                Section("environment.packages.tasks") {
                    Text(message).font(.subheadline).textSelection(.enabled)
                        .foregroundStyle(jobs.failures.contains(report.id) ? FloeTheme.destructive : .primary)
                    if jobs.running.contains(report.id) {
                        ProgressView("正在处理所选环境")
                        Button("action.cancel_task", role: .cancel) { jobs.cancel(id: report.id) }
                    }
                }
            }
            Section {
                NavigationLink {
                    LocalServicesView(environmentID: report.id)
                } label: {
                    Label("services.title", systemImage: "server.rack")
                }
            }
            Section("语言依赖") {
                ForEach(EnvironmentLanguagePackageService.Language.allCases) { language in
                    NavigationLink {
                        EnvironmentLanguagePackagesView(environmentID: report.id, language: language)
                    } label: {
                        Label(language.title, systemImage: language == .python ? "terminal" : "curlybraces")
                    }
                }
                Text("从 PyPI 或 npm 安装到所选环境，自动继承父层依赖。无需配置 apt 软件源。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("environment.packages.installed") {
                if let packages {
                    if packages.installed.isEmpty { Text("此层尚未安装软件包").foregroundStyle(.secondary) }
                    ForEach(packages.installed.filter { matches($0.name) }, id: \.name) { package in
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent(package.name, value: package.version)
                            if let summary = package.summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Button(LocalizedStringKey(packages.held.contains(package.name) ? "environment.packages.unhold" : "environment.packages.hold")) {
                                    start(packages.held.contains(package.name) ? .unhold(package.name) : .hold(package.name), "更新版本固定状态…")
                                }.buttonStyle(.borderless)
                                Spacer()
                                Button("action.uninstall", role: .destructive) { pendingRemoval = package.name }.buttonStyle(.borderless)
                            }.font(.subheadline).disabled(!writable)
                        }.padding(.vertical, 4)
                    }
                } else { Text("正在读取依赖…").foregroundStyle(.secondary) }
            }
            if let packages, !packages.inherited.isEmpty {
                Section("environment.packages.inherited") {
                    ForEach(packages.inherited.filter { matches($0.name) }, id: \.name) { package in
                        LabeledContent { Text("\(package.version) · \(package.layer.rawValue)").foregroundStyle(.secondary) } label: { Label(package.name, systemImage: "arrow.down.forward") }
                    }
                }
            }
            Section("environment.packages.available") {
                Button("添加软件源", systemImage: "plus") { editSource(nil) }.disabled(!writable)
                Button("environment.packages.refresh", systemImage: "arrow.clockwise") { start(.refresh, "正在下载并验证软件源…") }.disabled(!writable)
                if let packages {
                    if packages.available.isEmpty { Text("尚无经过验证的软件包索引。刷新成功后，可在此选择安装。").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(Array(packages.available.filter { matches($0.name) }.enumerated()), id: \.offset) { _, package in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) { Text(package.name); Text(package.version).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("environment.packages.install") { start(.install(package.name + "=" + package.version), "正在安装 \(package.name)…") }.buttonStyle(.bordered).disabled(!writable)
                        }
                    }
                    DisclosureGroup("软件源（\(packages.sources.count)）") {
                        if packages.sources.isEmpty { Text("尚未配置已签名的软件源") }
                        ForEach(packages.sources) { source in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(source.uri).textSelection(.enabled)
                                Text("\(source.suite) · \(source.enabled ? "启用" : "停用")").foregroundStyle(.secondary)
                                HStack {
                                    Button("编辑") { editSource(source) }
                                    Button(source.enabled ? "停用" : "启用") { start(.setSourceEnabled(source.id, !source.enabled), "正在更新软件源…") }
                                    Spacer()
                                    Button("移除", role: .destructive) { start(.deleteSource(source.id), "正在移除软件源…") }
                                }.buttonStyle(.borderless).disabled(!writable)
                            }.padding(.vertical, 4)
                        }
                    }.font(.caption)
                }
            }
            if record.kind.isWritableLayer {
                Section("environment.lifecycle.title") {
                    Button(record.state == .stopped ? "恢复环境" : "停止此环境的任务", systemImage: record.state == .stopped ? "play" : "stop") {
                        perform {
                            if record.state == .stopped { try await FloePlatformServices.shared.resumeEnvironment(id: report.id) }
                            else { try await FloePlatformServices.shared.stopEnvironment(id: report.id) }
                        }
                    }.disabled(busy || record.state == .deleting)
                    TextField("environment.template.name", text: $templateName)
                    Button("environment.template.save", systemImage: "doc.on.doc") {
                        perform { try await FloePlatformServices.shared.saveEnvironmentTemplate(id: report.id, name: templateName); templateName = "" }
                    }.disabled(busy || jobs.running.contains(report.id) || record.state != .stopped || record.requiresRebuild || templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("先停止环境，再保存模板，确保依赖副本一致。").font(.caption).foregroundStyle(.secondary)
                    Button("environment.delete.action", role: .destructive) { confirmDelete = true }.disabled(busy)
                }
            }
        }
        .navigationTitle(record.name ?? displayName)
        .searchable(text: $query, prompt: "搜索软件包")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: jobs.revision) { Task { await reload() } }
        .sheet(isPresented: $addingSource) {
            NavigationStack {
                Form {
                    Section("软件源") {
                        TextField("HTTPS 地址", text: $sourceURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("发行版", text: $sourceSuite).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("组件", text: $sourceComponent).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section("packages.source.trust") {
                        Toggle("packages.source.unsigned", isOn: $trustUnsignedSource)
                        Text("packages.source.unsigned.help").font(.footnote).foregroundStyle(.secondary)
                    }
                    if !trustUnsignedSource {
                        Section("OpenPGP 签名公钥") {
                            TextEditor(text: $sourceKey).font(.caption.monospaced()).frame(minHeight: 160)
                            Text("从软件源发布者获取公钥。下载的软件包索引必须通过此公钥验证。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if editingSource != nil { Text("留空保留已保存的签名公钥。").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
                .navigationTitle(editingSource == nil ? "添加软件源" : "编辑软件源")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { addingSource = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            start(.saveSource(AptSource(uri: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                suite: sourceSuite, components: sourceComponent.split(separator: " ").map(String.init),
                                trusted: trustUnsignedSource, enabled: editingSource?.enabled ?? true), sourceKey, replacingID: editingSource?.id), "正在保存软件源…")
                            addingSource = false
                        }.disabled(sourceURL.isEmpty || sourceSuite.isEmpty || (!trustUnsignedSource && sourceKey.isEmpty && editingSource?.signedBy == nil))
                    }
                }
            }
        }
        .confirmationDialog("卸载 \(pendingRemoval ?? "")？", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("卸载本层软件包", role: .destructive) { if let name = pendingRemoval { start(.remove(name), "正在卸载 \(name)…") }; pendingRemoval = nil }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: { Text("仅修改当前环境。若其他软件包依赖它，卸载会被拒绝。") }
        .confirmationDialog("删除此容器？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("environment.delete.stop_and_delete", role: .destructive) {
                perform { try await FloePlatformServices.shared.deleteEnvironment(id: report.id); dismiss() }
            }
        } message: { Text("将停止此环境的任务并删除其依赖和容器数据。有子会话的项目须先清理子会话；停止失败时保留数据。") }
    }
    private func matches(_ name: String) -> Bool { query.isEmpty || name.localizedCaseInsensitiveContains(query) }
    private func editSource(_ source: AptSource?) {
        editingSource = source
        sourceURL = source?.uri ?? ""
        sourceSuite = source?.suite ?? "stable"
        sourceComponent = source?.components.joined(separator: " ") ?? "main"
        sourceKey = ""
        trustUnsignedSource = source?.trusted ?? false
        addingSource = true
    }
    private func start(_ action: FloePlatformServices.PackageAction, _ title: String) { jobs.start(id: report.id, title: title, action: action) }
    @MainActor private func reload() async {
        do {
            packages = try await FloePlatformServices.shared.packageReport(id: report.id)
            current = try await FloePlatformServices.shared.environmentReports().first { $0.id == report.id }
            error = nil
        } catch { self.error = String(describing: error) }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await operation(); await reload() } catch { self.error = String(describing: error) }
        }
    }
}
#endif
