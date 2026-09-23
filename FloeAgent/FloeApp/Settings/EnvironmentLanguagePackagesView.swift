// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeExecution

struct EnvironmentLanguagePackagesView: View {
    let environmentID: String
    let language: EnvironmentLanguagePackageService.Language
    @State private var nodeSelection: EnvironmentLanguagePackageService.NodeManagerSelection?
    @State private var sources = LanguagePackageSources()
    @State private var editingSource = false
    @State private var sourceDraft = ""
    @State private var packages: [EnvironmentLanguagePackageService.Package] = []
    @State private var specification = ""
    @State private var query = ""
    @State private var loading = false
    @State private var error: String?
    /// When the live guest list was last read; nil until the guest answered.
    /// A stopped guest keeps the previous rows, labelled with this time.
    @State private var collectedAt: Date?
    @State private var guestRunning: Bool?
    @State private var pendingRemoval: EnvironmentLanguagePackageService.Package?
    @ObservedObject private var jobs = EnvironmentPackageJobs.shared
    private var running: Bool { jobs.running.contains(environmentID) }

    var body: some View {
        List {
            Section {
                Button {
                    sourceDraft = language == .python ? sources.pythonIndex : sources.nodeRegistry
                    editingSource = true
                } label: {
                    HStack {
                        Label("packages.registry.source", systemImage: "network")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(running || loading)
                Text(language == .python ? sources.pythonIndex : sources.nodeRegistry)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(language == .python
                     ? "安装到此环境私有的受管 venv（/floe/env/python/venv）：此环境的 shell、Python 工具与本页共用同一套包，不同环境彼此隔离。优先安装 riscv64 预构建 wheel；无预构建的源码包需要 guest 内有编译工具链（dev-document 模板已含 build-essential）。镜像系统层的包只在“继承的依赖”中只读展示。"
                     : "安装到此环境私有的 node_modules（/floe/env/usr/lib/node_modules），不同环境彼此隔离。真实 npm/pnpm 会执行安装脚本、安装原生二进制并创建 CLI 符号链接；失败时保留原有依赖。App 自带运行时不在此卸载。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("这里只展示环境中安装的依赖；App 自带运行时不在此卸载。").font(.caption).foregroundStyle(.secondary)
            }
            if language == .node {
                Section("packages.node.manager") {
                    Picker("packages.node.manager", selection: Binding(
                        get: { nodeSelection?.preference ?? .automatic },
                        set: { value in Task { await setNodeManager(value) } }
                    )) {
                        Text("packages.node.auto").tag(NodePackageManagerPreference.automatic)
                        Text("npm").tag(NodePackageManagerPreference.npm)
                        Text("pnpm").tag(NodePackageManagerPreference.pnpm)
                    }.disabled(running || loading)
                    if let selected = nodeSelection?.resolved { LabeledContent("packages.node.effective", value: selected.rawValue) }
                    if let issue = nodeSelection?.issue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(FloeTheme.destructive) }
                    Text("packages.node.policy").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("安装依赖") {
                TextField(language == .python ? "例如 beautifulsoup4 或 requests==2.32.5" : "例如 marked 或 marked@15.0.12", text: $specification)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go)
                    .onSubmit { install() }
                Button("安装", systemImage: "arrow.down.circle") { install() }
                    .disabled(running || loading || (language == .node && nodeSelection?.resolved == nil) || specification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("安装只写入当前选择的环境。离开此页面后任务会继续。").font(.caption).foregroundStyle(.secondary)
            }
            if let message = jobs.messages[environmentID] {
                Section("最近任务") {
                    Text(message).font(.caption.monospaced()).textSelection(.enabled)
                        .foregroundStyle(jobs.failures.contains(environmentID) ? FloeTheme.destructive : .secondary)
                    if running {
                        ProgressView("正在更新依赖…")
                        Button("取消任务", role: .cancel) { jobs.cancel(id: environmentID) }
                    }
                }
            }
            if loading { ProgressView("读取依赖…") }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive)
                    Button("重新读取") { Task { await reload() } }.disabled(running || loading)
                }
            }
            Section {
                HStack(spacing: 6) {
                    Image(systemName: guestRunning == true ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .font(.caption2)
                        .foregroundStyle(guestRunning == true ? FloeTheme.success : .secondary)
                    Text(freshnessLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
            packageSection(writableTitle, writable: true)
            packageSection(inheritedTitle, writable: false)
        }
        .navigationTitle(language.title)
        .searchable(text: $query, prompt: "搜索已安装的依赖")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: jobs.revision) { Task { await reload() } }
        .sheet(isPresented: $editingSource) {
            NavigationStack {
                Form {
                    Section("packages.registry.source") {
                        TextField("https://", text: $sourceDraft).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().keyboardType(.URL)
                        Button("packages.registry.restore") {
                            let defaults = LanguagePackageSources()
                            sourceDraft = language == .python ? defaults.pythonIndex : defaults.nodeRegistry
                        }
                    }
                    Text("packages.registry.policy").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(FloeTheme.destructive) }
                }
                .navigationTitle("packages.registry.source")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editingSource = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { Task { await saveSource() } }.disabled(loading || sourceDraft.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog("卸载本层依赖？", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            if let package = pendingRemoval {
                Button("卸载 \(package.name)", role: .destructive) { change(package.name, remove: true); pendingRemoval = nil }
                Button("取消", role: .cancel) { pendingRemoval = nil }
            }
        } message: { Text("依赖此包的脚本可能无法运行；父环境中的版本会继续保留。") }
    }

    private var writableTitle: String {
        language == .python
            ? String(localized: "此环境 venv 内（Guest 实时查询）")
            : String(localized: "此环境 node_modules（Guest 实时查询）")
    }
    private var inheritedTitle: String {
        language == .python
            ? String(localized: "镜像/父层继承（只读）")
            : String(localized: "镜像/父层继承（只读）")
    }
    /// Honest provenance + freshness line. The Linux guest answers live only
    /// while running; a stopped screen keeps the previous rows but says when
    /// they were last read instead of presenting them as current.
    private var freshnessLine: String {
        let time = collectedAt.map { DateFormatter.listTime.string(from: $0) } ?? "—"
        switch guestRunning {
        case true:
            return String(localized: "正在运行 · Guest 实时清单 · 更新于 \(time)")
        case false:
            return String(localized: "已停止 · 显示上次 Guest 清单 · 更新于 \(time)")
        default:
            return String(localized: "等待 Guest 状态 · 更新于 \(time)")
        }
    }

    private func packageSection(_ title: String, writable: Bool) -> some View {
        Section(title) {
            let matches = packages.filter { $0.writable == writable && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            if matches.isEmpty && !loading && error == nil { Text(query.isEmpty ? "暂无依赖" : "没有匹配的依赖").foregroundStyle(.secondary) }
            ForEach(matches) { package in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(package.name).font(.headline)
                        Text(package.version).font(.caption).foregroundStyle(.secondary)
                        if !writable { Text("来源：\(package.layerID)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if writable {
                        Button("卸载", role: .destructive) { pendingRemoval = package }.buttonStyle(.borderless).disabled(running || loading)
                    } else { Image(systemName: "arrow.down.forward").foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }
        }
    }
    private func install() {
        let value = specification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !running, !loading else { return }
        change(value, remove: false)
    }
    private func change(_ value: String, remove: Bool) {
        let id = environmentID, selectedLanguage = language
        jobs.start(id: id, title: "\(remove ? "卸载" : "安装") \(value)…") {
            let service = try FloePlatformServices.shared.languagePackageService()
            return try await service.change(environmentID: id, language: selectedLanguage, specification: value, remove: remove)
        }
    }
    @MainActor private func setNodeManager(_ value: NodePackageManagerPreference) async {
        guard !loading, !running else { return }
        loading = true
        defer { loading = false }
        do {
            nodeSelection = try await FloePlatformServices.shared.languagePackageService().nodeManagerSelection(environmentID: environmentID, set: value)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func saveSource() async {
        guard !loading, !running else { return }
        loading = true
        defer { loading = false }
        do {
            var next = sources
            if language == .python { next.pythonIndex = sourceDraft } else { next.nodeRegistry = sourceDraft }
            sources = try await FloePlatformServices.shared.languagePackageService().sources(environmentID: environmentID, set: next)
            error = nil; editingSource = false
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func reload() async {
        guard !loading, !running else { return }
        loading = true
        defer { loading = false }
        do {
            let service = try FloePlatformServices.shared.languagePackageService()
            sources = try await service.sources(environmentID: environmentID)
            if language == .node { nodeSelection = try await service.nodeManagerSelection(environmentID: environmentID) }
            // Real Guest identity/state via the same ownership seams the
            // environment manager uses; never inferred from the package rows.
            let owned = await FloePlatformServices.shared.linuxEnvironmentOwned(id: environmentID)
            let running = owned ? await FloePlatformServices.shared.linuxEnvironmentAvailable(id: environmentID) : false
            guestRunning = owned ? running : nil
            packages = try await service.packages(environmentID: environmentID, language: language)
            collectedAt = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension DateFormatter {
    static let listTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
#endif
