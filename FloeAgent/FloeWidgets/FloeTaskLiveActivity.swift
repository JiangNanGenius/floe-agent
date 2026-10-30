// FloeWidgets — Live Activity for ordinary Floe tasks.
//
// SPDX-License-Identifier: MPL-2.0
//
// Renders the snapshot the App produces from tasks that are actually running.
// The view has no data source of its own and starts nothing: it shows the
// bounded title/state/status rows it receives and links each row to its
// canonical exact-task route. The App owns start/update/end and ends the
// activity as soon as the last task stops, so an idle activity never lingers.
//
// Distinct from `FloeSystemAlarmLiveActivityWidget`: that one is the
// AlarmKit-owned alarm/timer surface the system drives itself.

#if os(iOS) && canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import WidgetKit
import SwiftUI
import FloeCore

struct FloeTaskLiveActivityWidget: Widget {
    init() {
        // The extension renders in its own process; resolve the App-mirrored
        // language here too (idempotent), matching the other widgets.
        FloeL10n.bootstrap()
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FloeTaskActivityAttributes.self) { context in
            FloeTaskLiveActivityLockScreenView(context: context)
        } dynamicIsland: { context in
            FloeTaskLiveActivityIsland.make(context: context)
        }
    }
}

// MARK: - Shared presentation

private enum FloeTaskLiveActivityPresentation {
    static func displayTitle(_ row: FloeTaskActivitySnapshot.Row) -> String {
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? FloeL10n.l("widget.untitled_task") : title
    }

    /// Inline bilingual fallback for the planned-wait vocabulary. The widget
    /// extension resolves the App language itself, so this stays aligned with
    /// the App's English/Simplified Chinese copy without a second catalog.
    static func localized(zh: String, en: String) -> String {
        FloeL10n.isChinese ? zh : en
    }

    static func stateLabel(_ state: WidgetTaskState) -> String {
        switch state {
        case .starting: FloeL10n.l("widget.state.starting")
        case .running: FloeL10n.l("widget.state.running")
        case .waiting: FloeL10n.l("widget.state.waiting")
        case .paused: FloeL10n.l("widget.state.paused")
        case .unknown: FloeL10n.l("widget.state.unknown")
        }
    }

    static func stateColor(_ state: WidgetTaskState) -> Color {
        switch state {
        case .starting: .blue
        case .running: .green
        case .waiting: .orange
        case .paused: .secondary
        case .unknown: .secondary
        }
    }

    static func countLabel(_ count: Int) -> String {
        String(format: FloeL10n.l("liveactivity.active_count"), Int64(count))
    }

    /// The header's planned-plan count. It is a total ("3 scheduled"), not a
    /// row list: at most one wait row is shown, so other plans never become
    /// extra activities.
    static func scheduledLabel(_ count: Int) -> String {
        localized(zh: "\(count) 个计划", en: "\(count) scheduled")
    }

    static func startingInLabel() -> String {
        localized(zh: "即将开始", en: "Starts in")
    }

    static func dueLabel() -> String {
        localized(zh: "即将开始", en: "Starting soon")
    }

    /// The displayed rows. The header still reports the full active count,
    /// which can be larger than the Lock Screen list. The snapshot itself caps
    /// rows (three real runs + at most one planned wait).
    static let visibleRowLimit = FloeTaskActivitySnapshot.maximumRows
}

// MARK: - Lock screen / banner

private struct FloeTaskLiveActivityLockScreenView: View {
    let context: ActivityViewContext<FloeTaskActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if context.isStale {
                // The App has not produced a real lifecycle update within the
                // stale window; say so instead of presenting old rows as live.
                Text(FloeL10n.l("widget.stale"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if context.state.rows.isEmpty {
                Text(FloeL10n.l("liveactivity.none"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let shown = Array(context.state.rows.prefix(
                    FloeTaskLiveActivityPresentation.visibleRowLimit))
                ForEach(shown) { row in
                    rowView(row)
                }
                let shownRuns = shown.filter { $0.waitingUntil == nil }.count
                if context.state.activeCount > shownRuns {
                    Text("+\(context.state.activeCount - shownRuns)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(FloeL10n.l("widget.more_tasks")))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Floe Agent")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 8)
            if context.state.activeCount > 0 {
                Text(FloeTaskLiveActivityPresentation.countLabel(context.state.activeCount))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let scheduled = context.state.scheduledCount, scheduled > 0 {
                Text(FloeTaskLiveActivityPresentation.scheduledLabel(scheduled))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if context.state.activeCount > 0 {
                // Elapsed time only for REAL running work. A planned-wait
                // activity has no runtime clock to show.
                Text(context.attributes.startDate, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: FloeTaskActivitySnapshot.Row) -> some View {
        let content = HStack(spacing: 6) {
            Circle()
                .fill(FloeTaskLiveActivityPresentation.stateColor(row.state))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(FloeTaskLiveActivityPresentation.displayTitle(row))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if !row.status.isEmpty {
                    Text(row.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(FloeTaskLiveActivityPresentation.stateLabel(row.state))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let waitingUntil = row.waitingUntil {
                // The SYSTEM advances this text; the App never polls the
                // database or keeps a timer alive for the countdown.
                if waitingUntil > Date() {
                    Text(timerInterval: Date()...waitingUntil, countsDown: true)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)
                        .accessibilityLabel(Text(FloeTaskLiveActivityPresentation.startingInLabel()))
                } else {
                    Text(FloeTaskLiveActivityPresentation.dueLabel())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(row.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(FloeTaskLiveActivityPresentation.displayTitle(row)))
        .accessibilityValue(Text(FloeTaskLiveActivityPresentation.stateLabel(row.state)))

        if let route = row.route {
            Link(destination: route) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - Dynamic Island

private enum FloeTaskLiveActivityIsland {
    static func make(
        context: ActivityViewContext<FloeTaskActivityAttributes>
    ) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DynamicIslandExpandedRegion(.trailing) {
                if context.state.activeCount > 0 {
                    Text(FloeTaskLiveActivityPresentation.countLabel(context.state.activeCount))
                        .font(.caption2.monospacedDigit())
                }
            }
            DynamicIslandExpandedRegion(.center) {
                Text(firstTitle(context))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            DynamicIslandExpandedRegion(.bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(context.state.rows.prefix(2)) { row in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(FloeTaskLiveActivityPresentation.stateColor(row.state))
                                .frame(width: 5, height: 5)
                            Text(FloeTaskLiveActivityPresentation.displayTitle(row))
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(FloeTaskLiveActivityPresentation.stateLabel(row.state))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } compactLeading: {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
        } compactTrailing: {
            Text("\(context.state.activeCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        } minimal: {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
        }
    }

    private static func firstTitle(
        _ context: ActivityViewContext<FloeTaskActivityAttributes>
    ) -> String {
        guard let row = context.state.rows.first else {
            return FloeL10n.l("liveactivity.none")
        }
        return FloeTaskLiveActivityPresentation.displayTitle(row)
    }
}
#endif
