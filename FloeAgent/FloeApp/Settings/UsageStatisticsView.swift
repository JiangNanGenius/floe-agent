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
                }
                Section("近 30 天") {
                    Chart(stats.byDay) { day in
                        BarMark(
                            x: .value("日期", day.date),
                            y: .value("token", day.inputTokens + day.outputTokens)
                        )
                        .foregroundStyle(FloeTheme.primary)
                    }
                    .frame(height: 200)
                    ForEach(stats.byDay) { day in
                        LabeledContent(day.date) {
                            Text("\(day.inputTokens + day.outputTokens) token · \(day.runs) 任务")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if isLoading {
                ProgressView()
            } else {
                ContentUnavailableView("暂无用量数据", systemImage: "chart.bar")
            }
        }
        .navigationTitle("用量统计")
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        stats = try? await environment.runStore.usageStatistics()
    }
}
#endif
