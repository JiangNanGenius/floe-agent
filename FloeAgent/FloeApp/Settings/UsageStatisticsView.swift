// FloeApp — Usage statistics page.
//
// Shows token consumption across all runs: total input/output tokens,
// daily breakdown. Uses system Charts (iOS 16+) for visualization.

#if canImport(SwiftUI) && (canImport(UIKit) || FLOE_UNIFIED_MAC)
import SwiftUI
import Charts
import FloeCore
import FloeModels
import FloePersistence

struct UsageStatisticsView: View {
    private enum Dimension: String, CaseIterable, Identifiable {
        case total, model, provider
        var id: String { rawValue }
        var titleKey: LocalizedStringKey {
            switch self {
            case .total: "settings.usage_statistics_view.overview"
            case .model: "providers.models_section"
            case .provider: "settings.diagnostics.providers"
            }
        }
    }

    #if FLOE_UNIFIED_MAC
    let loadStatistics: @MainActor () async throws -> UsageStatistics
    #else
    @EnvironmentObject private var environment: AppEnvironment
    #endif
    @State private var stats: UsageStatistics?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var dimension: Dimension = .total
    @State private var selectedBreakdownID: String?

    var body: some View {
        List {
            if let stats {
                Section("settings.usage_statistics_view.filter") {
                    Picker("settings.usage_statistics_view.statistics_dimensions", selection: $dimension) {
                        ForEach(Dimension.allCases) { item in
                            Text(item.titleKey).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    if dimension != .total {
                        Picker(dimension == .model ? "settings.usage_statistics_view.model" : "settings.diagnostics.providers", selection: $selectedBreakdownID) {
                            Text("settings.usage_statistics_view.all").tag(nil as String?)
                            ForEach(dimensionRows(stats)) { row in
                                Text(row.label).tag(Optional(row.id))
                            }
                        }
                    }
                }
                Section("settings.usage_statistics_view.total") {
                    LabeledContent("settings.usage_statistics_view.input_usage") {
                        Text(TokenUnitFormatter.string(selectedRow(in: stats)?.inputTokens ?? stats.totalInputTokens)).foregroundStyle(.secondary)
                    }
                    LabeledContent("settings.usage_statistics_view.output_usage") {
                        Text(TokenUnitFormatter.string(selectedRow(in: stats)?.outputTokens ?? stats.totalOutputTokens)).foregroundStyle(.secondary)
                    }
                    LabeledContent("settings.usage_statistics_view.total_usage") {
                        Text(TokenUnitFormatter.string(selectedRow(in: stats)?.totalTokens ?? stats.totalTokens)).foregroundStyle(.secondary)
                    }
                    LabeledContent("settings.usage_statistics_view.total_tasks") {
                        Text("\(selectedRow(in: stats)?.runs ?? stats.totalRuns)").foregroundStyle(.secondary)
                    }
                    reportedTokenRow(FloeL10n.l("settings.usage_statistics_view.context_reuse"), value: selectedCacheRead(in: stats))
                    reportedTokenRow(FloeL10n.l("settings.usage_statistics_view.reasoning_usage"), value: selectedReasoning(in: stats))
                    LabeledContent("settings.usage_statistics_view.context_reuse_rate") {
                        Text(cacheHitRate(
                            input: selectedRow(in: stats)?.inputTokens ?? stats.totalInputTokens,
                            read: selectedCacheRead(in: stats)
                        )).foregroundStyle(.secondary)
                    }
                    LabeledContent("settings.usage_statistics_view.average_generation_speed") {
                        Text(speed(selectedSpeed(in: stats))).foregroundStyle(.secondary)
                    }
                    LabeledContent("settings.usage_statistics_view.average_time_to_first_response") {
                        Text(milliseconds(selectedTTFT(in: stats))).foregroundStyle(.secondary)
                    }
                    LabeledContent("settings.usage_statistics_view.average_response_time") {
                        Text(milliseconds(selectedDuration(in: stats))).foregroundStyle(.secondary)
                    }
                }
                Section("settings.usage_statistics_view.last_30_days") {
                    if stats.byDay.isEmpty {
                        ContentUnavailableView("settings.usage_statistics_view.no_tasks_to_count_yet", systemImage: "chart.bar",
                            description: Text("settings.usage_statistics_view.usage_returned_by_the_model_appears"))
                    } else {
                        Chart(stats.byDay) { day in
                            BarMark(
                                x: .value(FloeL10n.l("settings.usage_statistics_view.date"), day.date),
                                y: .value(FloeL10n.l("thread.kind.usage"), day.totalTokens)
                            )
                            .foregroundStyle(FloeTheme.primary)
                        }
                        .frame(height: 200)
                    }
                    ForEach(stats.byDay) { day in
                        LabeledContent(day.date) {
                            Text(runTotal(tokens: day.totalTokens, runs: day.runs))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                usageSection(FloeL10n.l("settings.usage_statistics_view.by_conversation"), rows: stats.byConversation)
                usageSection(FloeL10n.l("settings.usage_statistics_view.by_model"), rows: stats.byModel)
                usageSection(FloeL10n.l("settings.usage_statistics_view.by_provider"), rows: stats.byProvider)
            } else if isLoading {
                ProgressView()
            } else {
                ContentUnavailableView("settings.usage_statistics_view.no_usage_data", systemImage: "chart.bar")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(FloeTheme.destructive)
            }
        }
        .navigationTitle(FloeL10n.l("settings.section.usage"))
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
                Text("settings.usage_statistics_view.no_data")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.label)
                        HStack {
                            Text(FloeL10n.l("settings.usage_statistics_view.input_output", TokenUnitFormatter.string(row.inputTokens), TokenUnitFormatter.string(row.outputTokens)))
                            Spacer()
                            Text(runTotal(tokens: row.totalTokens, runs: row.runs))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(FloeL10n.l("settings.usage_statistics_view.context_reuse_reasoning", reported(row.cacheReadTokens), reported(row.reasoningTokens)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(FloeL10n.l("settings.usage_statistics_view.reuse_time_to_first_response", cacheHitRate(input: row.inputTokens, read: row.cacheReadTokens), speed(row.averageTokensPerSecond), milliseconds(row.averageTimeToFirstTokenMs)))
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
        value.map(TokenUnitFormatter.string) ?? FloeL10n.l("settings.usage_statistics_view.not_reported")
    }

    private func cacheHitRate(input: Int, read: Int?) -> String {
        guard let read else { return FloeL10n.l("settings.usage_statistics_view.not_reported") }
        let cacheable = input + read
        guard cacheable > 0 else { return FloeL10n.l("settings.usage_statistics_view.not_reported") }
        return (Double(read) / Double(cacheable))
            .formatted(.percent.precision(.fractionLength(1)))
    }

    private func runTotal(tokens: Int, runs: Int) -> String {
        let key = runs == 1 ? "settings.usage_statistics_view.tasks.one" : "settings.usage_statistics_view.tasks"
        return FloeL10n.l(key, TokenUnitFormatter.string(tokens), runs.formatted())
    }

    private func speed(_ value: Double?) -> String {
        value.map { speed in
            let key = speed == 1 ? "settings.usage_statistics_view.fragments_sec.one" : "settings.usage_statistics_view.fragments_sec"
            return FloeL10n.l(key, speed.formatted(.number.precision(.fractionLength(1))))
        }
            ?? FloeL10n.l("settings.usage_statistics_view.not_reported")
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { "\(($0 / 1_000).formatted(.number.precision(.fractionLength(2))))s" }
            ?? FloeL10n.l("settings.usage_statistics_view.not_reported")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            #if FLOE_UNIFIED_MAC
            stats = try await loadStatistics()
            #else
            stats = try await environment.runStore.usageStatistics()
            #endif
            errorMessage = nil
        } catch {
            stats = nil
            errorMessage = error.localizedDescription
        }
    }
}

enum TokenUnitFormatter {
    static func string(_ value: Int) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 {
            return scaled(value, divisor: 1_000_000_000, suffix: "B")
        }
        if magnitude >= 1_000_000 {
            return scaled(value, divisor: 1_000_000, suffix: "M")
        }
        if magnitude >= 1_000 {
            return scaled(value, divisor: 1_000, suffix: "K")
        }
        return value.formatted()
    }

    private static func scaled(_ value: Int, divisor: Int, suffix: String) -> String {
        let quotient = Double(value) / Double(divisor)
        let number = quotient.rounded() == quotient
            ? String(Int(quotient))
            : String(format: "%.1f", quotient).replacingOccurrences(of: ".0", with: "")
        return number + suffix
    }
}

#endif
