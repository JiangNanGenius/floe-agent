// SPDX-License-Identifier: MPL-2.0

import SwiftUI
import FloePersistence
import FloeSkills

/// EN / zh-CN inline strings for the workbench skills and connector
/// surfaces, following the `MacPermissionsText` convention: the Mac host
/// mirrors the system language without adding catalog keys.
enum MacWorkbenchText {
    static var isChinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }
    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
}

/// Skills workbench for the signed macOS-original catalog: inspect entries,
/// review verified details, add to the shared store, and enable/disable or
/// remove installed skills. All durable effects are owned by
/// `MacWorkbenchSkillsService`; this view only renders its published state
/// and forwards explicit user actions.
public struct MacWorkbenchSkillsView: View {
    private struct Selection: Identifiable {
        let entry: SkillHubCatalogEntry
        var id: String { entry.id }
    }

    @ObservedObject public var service: MacWorkbenchSkillsService
    @State private var inspected: Selection?
    @State private var detail: SkillHubCatalogDetail?
    @State private var loadingDetail = false
    @State private var detailError: String?
    @State private var confirmsRemove: PersistedSkill?
    @State private var actionError: String?

    public init(service: MacWorkbenchSkillsService) {
        self.service = service
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(MacWorkbenchText.t("技能", "Skills")).font(.headline)
                Spacer()
                catalogStateView
                Button(MacWorkbenchText.t("刷新目录", "Refresh Catalog")) {
                    Task { await service.refreshCatalog() }
                }
                .disabled(service.refreshingCatalog)
                .accessibilityIdentifier("workbench.skills.refresh")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            Divider()
            Form {
                installedSection
                catalogSection
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("workbench.skills.view")
        .task { await service.restore() }
        .sheet(item: $inspected) { selection in
            detailSheet(selection.entry)
        }
        .alert(item: $confirmsRemove) { row in
            Alert(
                title: Text(MacWorkbenchText.t("移除技能？", "Remove Skill?")),
                message: Text(MacWorkbenchText.t("将移除“\(row.name)”并保留可恢复的文件副本。", "“\(row.name)” will be removed; a recoverable file copy is kept.")),
                primaryButton: .destructive(Text(MacWorkbenchText.t("移除", "Remove"))) {
                    Task {
                        do { try await service.remove(id: row.id) }
                        catch { actionError = error.localizedDescription }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: Header status

    @ViewBuilder
    private var catalogStateView: some View {
        switch service.catalogState {
        case .empty:
            Text(MacWorkbenchText.t("目录未下载", "Catalog not downloaded"))
                .font(.caption).foregroundStyle(.secondary)
        case .loaded(let commit, let count):
            Text(MacWorkbenchText.t("目录 \(count) 项 · \(commit.prefix(7))", "Catalog \(count) entries · \(commit.prefix(7))"))
                .font(.caption).foregroundStyle(.secondary)
        case .unavailable(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: Installed

    @ViewBuilder
    private var installedSection: some View {
        Section(MacWorkbenchText.t("已安装", "Installed")) {
            if service.installed.isEmpty {
                Text(MacWorkbenchText.t("还没有已安装的技能。", "No skills installed yet."))
                    .foregroundStyle(.secondary)
            }
            ForEach(service.installed) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.body)
                        Text("\(row.id) · \(row.version) · \(row.rewrittenDigest.prefix(12))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(MacWorkbenchText.t("启用", "Enabled"), isOn: enabledBinding(row))
                        .labelsHidden().toggleStyle(.switch)
                    Button(MacWorkbenchText.t("移除", "Remove")) {
                        confirmsRemove = row
                    }
                    .disabled(service.jobs[row.id] != nil)
                    .accessibilityIdentifier("workbench.skills.remove.\(row.id)")
                }
                if let job = service.jobs[row.id] {
                    ProgressView(value: Double(job.completed), total: Double(max(job.total, 1))) {
                        Text(job.stage).font(.caption)
                    }
                }
            }
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func enabledBinding(_ row: PersistedSkill) -> Binding<Bool> {
        Binding(get: { row.status == "enabled" }, set: { enabled in
            Task {
                do { try await service.setEnabled(enabled, id: row.id) }
                catch { actionError = error.localizedDescription }
            }
        })
    }

    // MARK: Catalog

    @ViewBuilder
    private var catalogSection: some View {
        Section(MacWorkbenchText.t("签名目录", "Signed Catalog")) {
            if case .unavailable = service.catalogState, service.entries.isEmpty {
                Text(MacWorkbenchText.t("目录暂不可用；已安装的技能仍可管理。", "The catalog is unavailable; installed skills remain manageable."))
                    .foregroundStyle(.secondary)
            }
            ForEach(service.entries, id: \.id) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name.en).font(.body)
                        Text(entry.description.en)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text("\(entry.id) · \(entry.version)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button(MacWorkbenchText.t("查看", "Inspect")) {
                        inspected = Selection(entry: entry)
                    }
                    .accessibilityIdentifier("workbench.skills.inspect.\(entry.id)")
                    if service.isInstalled(entry.id) {
                        Text(MacWorkbenchText.t("已安装", "Installed"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(MacWorkbenchText.t("安装", "Install")) {
                            Task {
                                do { _ = try await service.install(id: entry.id) }
                                catch { actionError = error.localizedDescription }
                            }
                        }
                        .disabled(service.refreshingCatalog || service.jobs[entry.id] != nil)
                        .accessibilityIdentifier("workbench.skills.install.\(entry.id)")
                    }
                }
            }
        }
    }

    // MARK: Detail sheet

    private func detailSheet(_ entry: SkillHubCatalogEntry) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry.name.en).font(.headline)
                Spacer()
                Button(MacWorkbenchText.t("关闭", "Close")) { inspected = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            Divider()
            Group {
                if loadingDetail {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = detailError {
                    VStack(spacing: 8) {
                        Text(error).foregroundStyle(.red)
                        Button(MacWorkbenchText.t("重试", "Retry")) { loadDetail(entry) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let detail {
                    detailContent(entry, detail)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 560, height: 480)
        .accessibilityIdentifier("workbench.skills.detail")
        .onAppear { loadDetail(entry) }
    }

    private func loadDetail(_ entry: SkillHubCatalogEntry) {
        loadingDetail = true
        detailError = nil
        Task {
            do {
                detail = try await service.detail(id: entry.id)
            } catch {
                detailError = error.localizedDescription
            }
            loadingDetail = false
        }
    }

    private func detailContent(_ entry: SkillHubCatalogEntry, _ detail: SkillHubCatalogDetail) -> some View {
        Form {
            Section(MacWorkbenchText.t("信息", "Info")) {
                LabeledContent(MacWorkbenchText.t("版本", "Version"), value: entry.version)
                LabeledContent(MacWorkbenchText.t("来源", "Source"), value: entry.provenance?.publisher ?? "-")
                LabeledContent(MacWorkbenchText.t("发布提交", "Publication"), value: String((entry.provenance?.publicationCommit ?? "-").prefix(12)))
                LabeledContent(MacWorkbenchText.t("文件", "Files"), value: "\(detail.fileCount ?? 0) · \(formatBytes(detail.totalBytes))")
            }
            Section(MacWorkbenchText.t("说明", "Instructions")) {
                ScrollView {
                    Text(detail.instructions ?? "")
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func formatBytes(_ value: Int?) -> String {
        guard let value, value > 0 else { return "0 B" }
        if value < 1024 { return "\(value) B" }
        if value < 1024 * 1024 { return String(format: "%.1f KB", Double(value) / 1024) }
        return String(format: "%.1f MB", Double(value) / (1024 * 1024))
    }
}
