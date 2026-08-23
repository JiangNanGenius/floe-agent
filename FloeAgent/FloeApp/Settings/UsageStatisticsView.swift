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
    @EnvironmentObject private var environment: AppEnvironment
    @State private var stats: UsageStatistics?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let stats {
                Section("总计") {
                    LabeledContent("总输入 token") {
                        Text("\(stats.totalInputTokens)").foregroundStyle(.secondary)
                    }
                    LabeledContent("总输出 token") {
                        Text("\(stats.totalOutputTokens)").foregroundStyle(.secondary)
                    }
                    LabeledContent("总 token") {
                        Text("\(stats.totalTokens)").foregroundStyle(.secondary)
                    }
                    LabeledContent("总任务数") {
                        Text("\(stats.totalRuns)").foregroundStyle(.secondary)
                    }
                    reportedTokenRow("缓存读取", value: stats.cacheReadTokens)
                    reportedTokenRow("缓存写入", value: stats.cacheWriteTokens)
                    reportedTokenRow("推理 token", value: stats.reasoningTokens)
                    LabeledContent("缓存命中率") {
                        Text(cacheHitRate(
                            input: stats.totalInputTokens,
                            read: stats.cacheReadTokens,
                            write: stats.cacheWriteTokens
                        )).foregroundStyle(.secondary)
                    }
                    LabeledContent("平均生成速度") {
                        Text(speed(stats.averageTokensPerSecond)).foregroundStyle(.secondary)
                    }
                    LabeledContent("平均首 token") {
                        Text(milliseconds(stats.averageTimeToFirstTokenMs)).foregroundStyle(.secondary)
                    }
                    LabeledContent("平均响应耗时") {
                        Text(milliseconds(stats.averageDurationMs)).foregroundStyle(.secondary)
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
