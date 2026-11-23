// SPDX-License-Identifier: MPL-2.0

import FloeCore
import SwiftUI

// FloeMacUnified — settings surface for Mac data management.
//
// Primary mounts this view from the Mac settings content. It shows the
// bounded, categorized scan of the Floe-owned stores, offers Finder reveal
// per category, and closes the cleanup loop: estimate → confirm → execute →
// honest result (deleted, skipped as in-use/protected/recent, failed, and
// the observed allocated change). Only the registered regenerable scratch
// candidate can ever be deleted here; databases, current work, runtime and
// rollback artifacts, caches roots and website data are retained rows.

struct MacManagedStorageSettingsView: View {
    @ObservedObject var service: MacManagedStorageService

    @State private var confirmsCleanup = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                if service.isScanning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(MacManagedStorageText.t("正在扫描…", "Scanning…"))
                            .foregroundStyle(.secondary)
                    }
                } else if service.scanFailed, service.report == nil {
                    Text(MacManagedStorageText.t(
                        "扫描失败。您的数据不受影响；请稍后重试。",
                        "The scan failed. Your data is unaffected; try again later."
                    ))
                    .foregroundStyle(.secondary)
                } else if let report = service.report {
                    LabeledContent(MacManagedStorageText.t("总计（已分配）", "Total (allocated)")) {
                        Text(Self.bytes(report.totalAllocatedBytes))
                    }
                    LabeledContent(MacManagedStorageText.t("文件", "Files")) {
                        Text("\(report.fileCount)")
                    }
                    LabeledContent(MacManagedStorageText.t("上次扫描", "Last scanned")) {
                        Text(report.generatedAt, style: .time)
                    }
                    if report.isPartial {
                        Text(MacManagedStorageText.t(
                            "部分大小无法测量，以上为估计值。",
                            "Some sizes could not be measured; the figures above are estimates."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(MacManagedStorageText.t("尚未扫描。", "Not scanned yet."))
                        .foregroundStyle(.secondary)
                }
                Button(MacManagedStorageText.t("重新扫描", "Scan again")) {
                    service.refresh()
                }
                .disabled(service.isScanning)
                .accessibilityIdentifier("mac.storage.refresh")
            } header: {
                Text(MacManagedStorageText.t("存储概览", "Storage overview"))
            }

            Section {
                let rows = service.report.map { $0.categories + ($0.other.map { [$0] } ?? []) } ?? []
                if rows.isEmpty {
                    Text(MacManagedStorageText.t("扫描后显示分类。", "Categories appear after a scan."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { category in
                        HStack(alignment: .firstTextBaseline) {
                            Label(category.title, systemImage: category.systemImage)
                                .labelStyle(.iconOnly)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                Text(Self.subtitle(for: category))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if category.isRevealable, category.exists {
                                Button(MacManagedStorageText.t("显示", "Reveal")) {
                                    if service.reveal(categoryID: category.id) {
                                        statusMessage = MacManagedStorageText.t("已在访达中显示", "Revealed in Finder")
                                    }
                                }
                                .accessibilityIdentifier("mac.storage.reveal." + category.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text(MacManagedStorageText.t("分类", "Categories"))
            } footer: {
                Text(MacManagedStorageText.t(
                    "仅扫描此应用拥有的目录；不会跟随符号链接或别名到其他位置。网站数据请通过“网站数据”设置按站点管理。",
                    "Only directories owned by this app are scanned; symlinks and aliases are never followed elsewhere. Manage website data per site from the Website data settings."
                ))
            }

            Section {
                if let estimate = service.estimate {
                    LabeledContent(MacManagedStorageText.t("可清理", "Cleanable")) {
                        Text(Self.bytes(estimate.eligibleAllocatedBytes))
                    }
                    LabeledContent(MacManagedStorageText.t("项目", "Items")) {
                        Text("\(estimate.eligibleItemCount)")
                    }
                    if !estimate.busyCandidateIDs.isEmpty {
                        Text(MacManagedStorageText.t(
                            "部分目录正在使用中，暂不可清理。",
                            "Some directories are in use and cannot be cleaned right now."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Button(MacManagedStorageText.t("清理临时工作目录…", "Clean temporary work directories…")) {
                        confirmsCleanup = true
                    }
                    .disabled(service.isCleaning || estimate.eligibleItemCount == 0)
                    .accessibilityIdentifier("mac.storage.clean")
                } else {
                    Button(MacManagedStorageText.t("计算可清理空间", "Estimate cleanable space")) {
                        Task { await service.estimateCleanup() }
                    }
                    .disabled(service.isCleaning)
                    .accessibilityIdentifier("mac.storage.estimate")
                }
                if service.isCleaning {
                    ProgressView()
                        .controlSize(.small)
                }
                if let result = service.cleanupResult {
                    Text(Self.cleanupSummary(result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mac.storage.cleanupResult")
                }
            } header: {
                Text(MacManagedStorageText.t("清理", "Cleanup"))
            } footer: {
                Text(MacManagedStorageText.t(
                    "只删除已登记的、可再生的临时工作目录：最近一天内使用或仍在使用的目录会被保留。任务数据库、当前工作内容、运行时与回滚数据、凭据和网站数据绝不在此删除。",
                    "Only registered, regenerable temporary work directories are removed: anything used in the last day or still in use is kept. The task database, current work, runtime and rollback data, credentials and website data are never deleted here."
                ))
            }
        }
        .formStyle(.grouped)
        .task { if service.report == nil { service.refresh() } }
        .alert(MacManagedStorageText.t("清理临时工作目录？", "Clean temporary work directories?"), isPresented: $confirmsCleanup) {
            Button(MacManagedStorageText.t("取消", "Cancel"), role: .cancel) {}
            Button(MacManagedStorageText.t("清理", "Clean"), role: .destructive) {
                Task {
                    await service.performCleanup()
                    if let result = service.cleanupResult {
                        statusMessage = Self.cleanupSummary(result)
                    }
                }
            }
        } message: {
            Text(MacManagedStorageText.t(
                "将删除长时间未使用的一次性工作目录。正在使用和最近的内容会被保留。",
                "One-off working directories that have been idle for a while will be removed. In-use and recent content is kept."
            ))
        }
        .overlay(alignment: .bottom) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .padding()
                    .onTapGesture { self.statusMessage = nil }
                    .accessibilityIdentifier("mac.storage.status")
            }
        }
    }

    nonisolated private static func subtitle(for category: MacManagedStorageCategory) -> String {
        guard category.exists else {
            return MacManagedStorageText.t("不存在", "Not present")
        }
        var parts: [String] = []
        switch category.kind {
        case .database:
            parts.append(MacManagedStorageText.t("任务与历史数据", "Tasks and history"))
        case .cache:
            parts.append(MacManagedStorageText.t("可再生缓存", "Rebuildable caches"))
        case .scratch:
            parts.append(MacManagedStorageText.t("可再生临时目录", "Regenerable temporary directories"))
        case .websiteData:
            parts.append(MacManagedStorageText.t("通过网站数据设置管理", "Managed from Website data settings"))
        case .store:
            break
        }
        parts.append(MacManagedStorageText.t("\(category.fileCount) 个文件", "\(category.fileCount) files"))
        return parts.joined(separator: " · ")
    }

    nonisolated private static func cleanupSummary(_ result: StorageCleanupPlanResult) -> String {
        var deleted = 0
        var skippedBusy = 0
        var skippedProtected = 0
        var skippedRecent = 0
        var failed = 0
        for item in result.perCandidate.values {
            deleted += item.deletedCount
            skippedBusy += item.skippedOwnerBusyCount
            skippedProtected += item.skippedProtectedCount
            skippedRecent += item.skippedRecentCount
            failed += item.failedCount
        }
        let freed = Self.bytes(result.observedAllocatedChangeBytes)
        var parts = [MacManagedStorageText.t("已删除 \(deleted) 项，释放约 \(freed)", "Deleted \(deleted) items, freeing about \(freed)")]
        var kept: [String] = []
        if skippedBusy > 0 {
            kept.append(MacManagedStorageText.t("使用中 \(skippedBusy)", "\(skippedBusy) in use"))
        }
        if skippedRecent > 0 {
            kept.append(MacManagedStorageText.t("最近使用 \(skippedRecent)", "\(skippedRecent) recent"))
        }
        if skippedProtected > 0 {
            kept.append(MacManagedStorageText.t("已保护 \(skippedProtected)", "\(skippedProtected) protected"))
        }
        if failed > 0 {
            kept.append(MacManagedStorageText.t("失败 \(failed)", "\(failed) failed"))
        }
        if !kept.isEmpty {
            parts.append(MacManagedStorageText.t("保留：", "Kept: ") + kept.joined(separator: "、"))
        }
        if result.wasCancelled {
            parts.append(MacManagedStorageText.t("已取消", "Cancelled"))
        }
        return parts.joined(separator: " · ")
    }

    nonisolated static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        let formatted = unit == 0 ? "\(Int(amount))" : String(format: "%.1f", amount)
        return "\(formatted) \(units[unit])"
    }
}
