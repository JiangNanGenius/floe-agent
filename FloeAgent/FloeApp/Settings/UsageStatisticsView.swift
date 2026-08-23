// FloeApp — Usage statistics page.
//
// Shows token consumption across all runs: total input/output tokens,
// daily breakdown. Uses system Charts (iOS 16+) for visualization.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Charts
import FloeCore
import FloeModels
import FloePersistence

struct UsageStatisticsView: View {
    private enum Dimension: String, CaseIterable, Identifiable {
        case total = "总览"
        case model = "模型"
        case provider = "供应商"
        var id: String { rawValue }
    }

    @EnvironmentObject private var environment: AppEnvironment
    @State private var stats: UsageStatistics?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var dimension: Dimension = .total
    @State private var selectedBreakdownID: String?

    var body: some View {
        List {
            if let stats {
                Section("筛选") {
                    Picker("统计维度", selection: $dimension) {
                        ForEach(Dimension.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    if dimension != .total {
                        Picker(dimension == .model ? "模型" : "供应商", selection: $selectedBreakdownID) {
                            Text("全部").tag(nil as String?)
                            ForEach(dimensionRows(stats)) { row in
                                Text(row.label).tag(Optional(row.id))
                            }
                        }
                    }
                }
                Section("总计") {
                    LabeledContent("总输入 token") {
                        Text("\(selectedRow(in: stats)?.inputTokens ?? stats.totalInputTokens)").foregroundStyle(.secondary)
                    }
                    LabeledContent("总输出 token") {
                        Text("\(selectedRow(in: stats)?.outputTokens ?? stats.totalOutputTokens)").foregroundStyle(.secondary)
                    }
                    LabeledContent("总 token") {
                        Text("\(selectedRow(in: stats)?.totalTokens ?? stats.totalTokens)").foregroundStyle(.secondary)
                    }
                    LabeledContent("总任务数") {
                        Text("\(selectedRow(in: stats)?.runs ?? stats.totalRuns)").foregroundStyle(.secondary)
                    }
                    reportedTokenRow("缓存读取", value: selectedCacheRead(in: stats))
                    reportedTokenRow("缓存写入", value: selectedCacheWrite(in: stats))
                    reportedTokenRow("推理 token", value: selectedReasoning(in: stats))
                    LabeledContent("缓存命中率") {
                        Text(cacheHitRate(
                            input: selectedRow(in: stats)?.inputTokens ?? stats.totalInputTokens,
                            read: selectedCacheRead(in: stats),
                            write: selectedCacheWrite(in: stats)
                        )).foregroundStyle(.secondary)
                    }
                    LabeledContent("平均生成速度") {
                        Text(speed(selectedSpeed(in: stats))).foregroundStyle(.secondary)
                    }
                    LabeledContent("平均首 token") {
                        Text(milliseconds(selectedTTFT(in: stats))).foregroundStyle(.secondary)
                    }
                    LabeledContent("平均响应耗时") {
                        Text(milliseconds(selectedDuration(in: stats))).foregroundStyle(.secondary)
                    }
                }
                Section("近 30 天") {
                    if stats.byDay.isEmpty {
                        ContentUnavailableView("还没有可统计的任务", systemImage: "chart.bar",
                            description: Text("新任务完成后会在这里显示提供商返回的 token 用量。"))
                    } else {
                        Chart(stats.byDay) { day in
                            BarMark(
                                x: .value("日期", day.date),
                                y: .value("token", day.totalTokens)
                            )
                            .foregroundStyle(FloeTheme.primary)
                        }
                        .frame(height: 200)
                    }
                    ForEach(stats.byDay) { day in
                        LabeledContent(day.date) {
                            Text("\(day.totalTokens) token · \(day.runs) 任务")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                usageSection("按会话", rows: stats.byConversation)
                usageSection("按模型", rows: stats.byModel)
                usageSection("按供应商", rows: stats.byProvider)
            } else if isLoading {
                ProgressView()
            } else {
                ContentUnavailableView("暂无用量数据", systemImage: "chart.bar")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(FloeTheme.destructive)
            }
        }
        .navigationTitle("用量统计")
        .task { await load() }
        .onChange(of: dimension) { _, _ in selectedBreakdownID = nil }
    }

    private func dimensionRows(_ stats: UsageStatistics) -> [UsageBreakdown] {
        dimension == .model ? stats.byModel : stats.byProvider
    }

    private func selectedRow(in stats: UsageStatistics) -> UsageBreakdown? {
        guard dimension != .total, let selectedBreakdownID else { return nil }
        return dimensionRows(stats).first { $0.id == selectedBreakdownID }
    }

    private func selectedCacheRead(in stats: UsageStatistics) -> Int? {
        selectedRow(in: stats).map(\.cacheReadTokens) ?? stats.cacheReadTokens
    }

    private func selectedCacheWrite(in stats: UsageStatistics) -> Int? {
        selectedRow(in: stats).map(\.cacheWriteTokens) ?? stats.cacheWriteTokens
    }

    private func selectedReasoning(in stats: UsageStatistics) -> Int? {
        selectedRow(in: stats).map(\.reasoningTokens) ?? stats.reasoningTokens
    }

    private func selectedSpeed(in stats: UsageStatistics) -> Double? {
        selectedRow(in: stats).map(\.averageTokensPerSecond) ?? stats.averageTokensPerSecond
    }

    private func selectedTTFT(in stats: UsageStatistics) -> Double? {
        selectedRow(in: stats).map(\.averageTimeToFirstTokenMs) ?? stats.averageTimeToFirstTokenMs
    }

    private func selectedDuration(in stats: UsageStatistics) -> Double? {
        selectedRow(in: stats).map(\.averageDurationMs) ?? stats.averageDurationMs
    }

    @ViewBuilder
    private func usageSection(_ title: String, rows: [UsageBreakdown]) -> some View {
        Section(title) {
            if rows.isEmpty {
                Text("暂无数据")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.label)
                        HStack {
                            Text("输入 \(row.inputTokens) · 输出 \(row.outputTokens)")
                            Spacer()
                            Text("\(row.totalTokens) token · \(row.runs) 任务")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text("缓存读取 \(reported(row.cacheReadTokens)) · 缓存写入 \(reported(row.cacheWriteTokens)) · 推理 \(reported(row.reasoningTokens))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("命中率 \(cacheHitRate(input: row.inputTokens, read: row.cacheReadTokens, write: row.cacheWriteTokens)) · \(speed(row.averageTokensPerSecond)) · 首 token \(milliseconds(row.averageTimeToFirstTokenMs))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func reportedTokenRow(_ label: String, value: Int?) -> some View {
        LabeledContent(label) {
            Text(reported(value)).foregroundStyle(.secondary)
        }
    }

    private func reported(_ value: Int?) -> String {
        value.map { "\($0) token" } ?? "未报告"
    }

    private func cacheHitRate(input: Int, read: Int?, write: Int?) -> String {
        guard let read else { return "未报告" }
        let cacheable = input + read + (write ?? 0)
        guard cacheable > 0 else { return "未报告" }
        return (Double(read) / Double(cacheable))
            .formatted(.percent.precision(.fractionLength(1)))
    }

    private func speed(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) token/s" }
            ?? "未报告"
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { "\(($0 / 1_000).formatted(.number.precision(.fractionLength(2))))s" }
            ?? "未报告"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            stats = try await environment.runStore.usageStatistics()
            errorMessage = nil
        } catch {
            stats = nil
            errorMessage = error.localizedDescription
        }
    }
}
#endif
