// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeTools

/// Template prepare/create jobs survive navigation: the service owns the
/// task lifetime, this object only mirrors its progress for the UI.
@MainActor final class EnvironmentTemplateJobs: ObservableObject {
    static let shared = EnvironmentTemplateJobs()
    @Published private(set) var preparing: Set<String> = []
    @Published private(set) var creating: Set<String> = []
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var failures: Set<String> = []
    @Published private(set) var fractions: [String: Double] = [:]
    @Published private(set) var revision = 0
    private var prepareTasks: [String: Task<Void, Never>] = [:]

    func prepare(templateID: String) {
        guard !preparing.contains(templateID) else { return }
        preparing.insert(templateID)
        failures.remove(templateID)
        fractions[templateID] = nil
        messages[templateID] = "正在下载并校验模板镜像… / Downloading and verifying the template image…"
        prepareTasks[templateID] = Task {
            do {
                _ = try await FloePlatformServices.shared.prepareOfficialTemplate(
                    templateID: templateID,
                    onProgress: { phase in
                        guard case .downloading(let received, let expected) = phase, expected > 0 else { return }
                        let fraction = min(1, max(0, Double(received) / Double(expected)))
                        Task { @MainActor in
                            EnvironmentTemplateJobs.shared.fractions[templateID] = fraction
                        }
                    }
                )
                messages[templateID] = "模板已验证并注册 / Template verified and registered"
            } catch {
                messages[templateID] = error.localizedDescription
                failures.insert(templateID)
            }
            preparing.remove(templateID)
            prepareTasks[templateID] = nil
            revision += 1
        }
    }

    func cancelPrepare(templateID: String) {
        messages[templateID] = "正在取消下载… / Cancelling the download…"
        prepareTasks[templateID]?.cancel()
        Task { await FloePlatformServices.shared.cancelPrepareOfficialTemplate(templateID: templateID) }
    }

    func create(templateID: String, workspaceRootURL: URL, name: String?) async throws -> EnvironmentRegistry.PinnedEnvironmentCreation {
        creating.insert(templateID)
        defer { creating.remove(templateID); revision += 1 }
        return try await FloePlatformServices.shared.createPinnedEnvironment(
            templateID: templateID, workspaceRootURL: workspaceRootURL, name: name
        )
    }
}

struct EnvironmentTemplatesView: View {
    @State private var availabilities: [RuntimeV2OfficialTemplateAvailability] = []
    @State private var loading = false
    @State private var error: String?
    @State private var creationTemplate: RuntimeV2OfficialTemplateAvailability?
    @ObservedObject private var jobs = EnvironmentTemplateJobs.shared

    var body: some View {
        List {
            Section {
                Text("官方软件模板由云端构建并完成 Guest 内安装验证；新环境固定到精确的模板版本与内容摘要，已有环境永不改写。")
                Text("Official templates are built and verified in the guest by the cloud component pipeline; a new environment pins the exact template version and digest, and existing environments are never re-pointed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading && availabilities.isEmpty { ProgressView("读取模板状态… / Loading template status…") }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive)
                    Button("重试 / Retry") { Task { await reload() } }
                }
            }
            ForEach(availabilities, id: \.templateID) { availability in
                Section {
                    templateRow(availability)
                } header: {
                    Text(Self.displayName(availability.templateID))
                } footer: {
                    Text(Self.summary(availability.templateID)).font(.caption)
                }
            }
        }
        .navigationTitle("软件模板 / Software templates")
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: jobs.revision) { Task { await reload() } }
        .sheet(isPresented: Binding(
            get: { creationTemplate != nil },
            set: { if !$0 { creationTemplate = nil } }
        )) {
            if let template = creationTemplate {
                EnvironmentTemplateCreationSheet(template: template) { root, name in
                    try await jobs.create(templateID: template.templateID, workspaceRootURL: root, name: name)
                }
            }
        }
    }

    @ViewBuilder private func templateRow(_ availability: RuntimeV2OfficialTemplateAvailability) -> some View {
        switch availability.state {
        case .verified:
            VStack(alignment: .leading, spacing: 6) {
                Label("已验证可用 / Verified", systemImage: "checkmark.seal.fill").foregroundStyle(FloeTheme.primary)
                if let version = availability.version, let digest = availability.digest {
                    Text("版本 \(version) · \(digest.prefix(16))… / version \(version) · \(digest.prefix(16))…")
                        .font(.caption).monospaced()
                }
                if let count = availability.packageCount {
                    Text("已安装软件 \(count) 项 / \(count) packages installed")
                        .font(.caption)
                    Text(packageSummary(availability))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let run = availability.qualificationRunURL {
                    Text("云端验证: \(run)").font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    creationTemplate = availability
                } label: {
                    Label("用此模板新建环境 / New environment from this template", systemImage: "plus.square.on.square")
                }
                .disabled(jobs.creating.contains(availability.templateID))
            }
        case .available:
            VStack(alignment: .leading, spacing: 6) {
                Label("可下载并注册 / Available to download", systemImage: "arrow.down.circle")
                if let bytes = availability.archiveBytes {
                    Text("镜像归档 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.caption)
                }
                if let run = availability.qualificationRunURL {
                    Text("云端验证: \(run)").font(.caption2).foregroundStyle(.secondary)
                }
                if jobs.preparing.contains(availability.templateID) {
                    if let fraction = jobs.fractions[availability.templateID] {
                        ProgressView(value: fraction) {
                            Text("下载中 \(Int(fraction * 100))% / Downloading")
                        }
                    } else {
                        ProgressView("准备中… / Preparing…")
                    }
                    Button(role: .destructive) {
                        jobs.cancelPrepare(templateID: availability.templateID)
                    } label: {
                        Label("取消 / Cancel", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        jobs.prepare(templateID: availability.templateID)
                    } label: {
                        Label("下载并注册 / Download and register", systemImage: "arrow.down.circle")
                    }
                }
            }
        case .registeredNotVerified:
            VStack(alignment: .leading, spacing: 6) {
                Label("已注册但未验证 / Registered, not verified", systemImage: "exclamationmark.triangle")
                Text(availability.reason ?? "未通过 Guest 内验证 / did not pass in-guest verification")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .dependencyMissing:
            VStack(alignment: .leading, spacing: 6) {
                Label("尚无云端验证的镜像依赖 / Dependency missing", systemImage: "clock.badge.exclamationmark")
                Text(availability.reason ?? "等待云端模板镜像构建 / waiting for the cloud template image")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let message = jobs.messages[availability.templateID], !message.isEmpty {
            Text(message)
                .font(.caption)
                .foregroundStyle(jobs.failures.contains(availability.templateID) ? FloeTheme.destructive : .secondary)
        }
    }

    private func packageSummary(_ availability: RuntimeV2OfficialTemplateAvailability) -> String {
        let names = availability.packageNames
        guard !names.isEmpty else { return "" }
        let shown = names.prefix(12).joined(separator: ", ")
        return names.count > 12 ? "\(shown), …" : shown
    }

    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            availabilities = try await FloePlatformServices.shared.officialTemplateAvailability()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func displayName(_ templateID: String) -> String {
        switch templateID {
        case "basic": return "基础模板 / Basic"
        case "dev-document": return "开发文档模板 / Dev & document"
        default: return templateID
        }
    }

    static func summary(_ templateID: String) -> String {
        switch templateID {
        case "basic":
            return "常用 13 条 Shell 命令 + Python/pip/venv/numpy + Node.js/npm + HTTPS 信任 / the 13 feedback commands plus Python, Node and HTTPS trust"
        case "dev-document":
            return "在基础模板上加入 git、网络诊断、C/C++ 构建链、pandas 与文档 Python 栈（含 python-pptx/pdfplumber 固定 wheel）/ adds git, network diagnostics, the C/C++ toolchain, pandas and the document Python stack"
        default:
            return templateID
        }
    }
}

private struct EnvironmentTemplateCreationSheet: View {
    let template: RuntimeV2OfficialTemplateAvailability
    let create: (URL, String?) async throws -> EnvironmentRegistry.PinnedEnvironmentCreation
    @Environment(\.dismiss) private var dismiss
    @State private var workspaceURL: URL?
    @State private var name = ""
    @State private var pickingDirectory = false
    @State private var busy = false
    @State private var error: String?
    @State private var created: EnvironmentRegistry.PinnedEnvironmentCreation?

    var body: some View {
        NavigationStack {
            Form {
                Section("模板 / Template") {
                    LabeledContent("名称 / Name", value: EnvironmentTemplatesView.displayName(template.templateID))
                    if let version = template.version, let digest = template.digest {
                        LabeledContent("版本 / Version", value: "\(version)")
                        LabeledContent("摘要 / Digest", value: String(digest.prefix(24)) + "…")
                    }
                }
                Section("工作区 / Workspace") {
                    Button {
                        pickingDirectory = true
                    } label: {
                        Label(workspaceURL?.path ?? "选择工作区文件夹 / Choose a workspace folder", systemImage: "folder")
                    }
                    TextField("环境名称（可选）/ Environment name (optional)", text: $name)
                }
                Section {
                    Text("新环境会固定到上述模板版本；若该工作区已有环境，现有环境保持原有版本与数据不变。")
                    Text("The new environment pins the template version above; an existing environment for the workspace keeps its own base and data unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive) }
                }
                if let created {
                    Section("已创建 / Created") {
                        Text("环境 \(created.record.id.prefix(8)) · 版本 \(created.record.templateVersion.map(String.init) ?? "-")")
                            .font(.caption).monospaced()
                        if !created.ownsWorkspaceRoot {
                            Text("该工作区已有环境，此环境为并列环境，现有会话仍使用原环境。 / The workspace already had an environment; this one is parallel and existing conversations keep the original.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if busy { ProgressView() } else { Text("创建环境 / Create environment") }
                    }
                    .disabled(busy || workspaceURL == nil)
                }
            }
            .navigationTitle("新建环境 / New environment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭 / Close") { dismiss() }
                }
            }
            .fileImporter(isPresented: $pickingDirectory, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { workspaceURL = url }
            }
        }
    }

    @MainActor private func submit() async {
        guard let workspaceURL else { return }
        let scoped = workspaceURL.startAccessingSecurityScopedResource()
        defer { if scoped { workspaceURL.stopAccessingSecurityScopedResource() } }
        busy = true
        defer { busy = false }
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            created = try await create(workspaceURL, trimmed.isEmpty ? nil : trimmed)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
