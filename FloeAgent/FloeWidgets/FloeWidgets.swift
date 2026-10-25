// FloeWidgets — Home-screen widget for exact task access.
//
// Reads the bounded snapshot written by the App (WidgetSnapshot/tasks.json in
// the shared App Group) and renders small/medium families. Tapping a task
// navigates to that exact conversation; the plus control starts a new task.
// Links never execute a task or supply prompt/run parameters.
//
// The widget is a read-only consumer: malformed, oversized, symlinked or
// unknown-schema files become a concise unavailable state, and a snapshot
// older than the freshness limit becomes a refresh hint instead of showing
// stale tasks as running.

import WidgetKit
import SwiftUI
import UIKit
import FloeCore

enum FloeWidgetContent {
    case tasks(WidgetTaskSnapshot)
    case empty
    case stale
    case unavailable
}

struct FloeWidgetEntry: TimelineEntry {
    let date: Date
    let content: FloeWidgetContent
}

struct FloeWidgetProvider: TimelineProvider {
    init() {
        // The extension runs in its own process; resolve the language chosen
        // in the main App (mirrored into the App Group).
        FloeL10n.bootstrap()
    }

    func placeholder(in context: Context) -> FloeWidgetEntry {
        FloeWidgetEntry(date: Date(), content: .empty)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (FloeWidgetEntry) -> Void
    ) {
        completion(entry(now: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<FloeWidgetEntry>) -> Void
    ) {
        let now = Date()
        let entry = entry(now: now)
        // WidgetKit owns the fallback cadence. The App never polls; it
        // requests a reload only after a real state change.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: now)
            ?? now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func entry(now: Date) -> FloeWidgetEntry {
        guard let store = WidgetTaskSnapshotStore.appGroup() else {
            return FloeWidgetEntry(date: now, content: .unavailable)
        }
        switch store.load(now: now) {
        case .fresh(let snapshot):
            return FloeWidgetEntry(
                date: now,
                content: snapshot.tasks.isEmpty ? .empty : .tasks(snapshot)
            )
        case .stale:
            return FloeWidgetEntry(date: now, content: .stale)
        case .missing:
            // Expected before the App has ever published a snapshot.
            return FloeWidgetEntry(date: now, content: .empty)
        case .unavailable, .invalid:
            return FloeWidgetEntry(date: now, content: .unavailable)
        }
    }
}

struct FloeWidgetView: View {
    let entry: FloeWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var maximumRows: Int {
        family == .systemSmall ? 2 : 3
    }

    private var widgetDestination: URL? {
        guard family == .systemSmall else { return nil }
        if case .tasks(let snapshot) = entry.content,
           let first = snapshot.tasks.first {
            return first.taskURL
        }
        return WidgetTaskSnapshot.newTaskURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch entry.content {
            case .tasks(let snapshot):
                taskList(snapshot)
            case .empty:
                emptyState
            case .stale:
                messageState(
                    systemImage: "clock.arrow.circlepath",
                    text: FloeL10n.l("widget.stale")
                )
            case .unavailable:
                messageState(
                    systemImage: "exclamationmark.circle",
                    text: FloeL10n.l("widget.unavailable")
                )
            }
            Spacer(minLength: 0)
            if family == .systemMedium {
                newTaskLink
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(uiColor: .secondarySystemBackground),
                    Color(uiColor: .systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .widgetURL(widgetDestination)
        .privacySensitive()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Floe Agent")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func taskList(_ snapshot: WidgetTaskSnapshot) -> some View {
        ForEach(snapshot.tasks.prefix(maximumRows)) { task in
            if family == .systemSmall {
                // A small widget has one interaction target; the whole card
                // uses widgetURL. Row-level Link controls are for medium.
                taskRowContent(task)
            } else {
                Link(destination: task.taskURL) {
                    taskRowContent(task)
                }
                .buttonStyle(.plain)
            }
        }
        let remaining = snapshot.tasks.count - min(snapshot.tasks.count, maximumRows)
        if remaining > 0 {
            Text("+\(remaining)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(FloeL10n.l("widget.more_tasks")))
        }
    }

    private func taskRowContent(_ task: WidgetTaskSnapshot.Item) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor(task.state))
                .frame(width: 7, height: 7)
            Text(displayTitle(task))
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(stateLabel(task.state))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            if family == .systemMedium {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .privacySensitive()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(displayTitle(task)))
        .accessibilityValue(Text(stateLabel(task.state)))
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(FloeL10n.l("widget.empty_active_tasks"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageState(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var newTaskLink: some View {
        Link(destination: WidgetTaskSnapshot.newTaskURL) {
            Label(FloeL10n.l("widget.new_task"), systemImage: "plus.circle.fill")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    private func displayTitle(_ task: WidgetTaskSnapshot.Item) -> String {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? FloeL10n.l("widget.untitled_task") : title
    }

    private func stateLabel(_ state: WidgetTaskState) -> String {
        switch state {
        case .starting: FloeL10n.l("widget.state.starting")
        case .running: FloeL10n.l("widget.state.running")
        case .waiting: FloeL10n.l("widget.state.waiting")
        case .paused: FloeL10n.l("widget.state.paused")
        case .unknown: FloeL10n.l("widget.state.unknown")
        }
    }

    private func stateColor(_ state: WidgetTaskState) -> Color {
        switch state {
        case .starting: .blue
        case .running: .green
        case .waiting: .orange
        case .paused: .secondary
        case .unknown: .secondary
        }
    }
}

struct FloeWidget: Widget {
    let kind = "FloeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FloeWidgetProvider()) { entry in
            FloeWidgetView(entry: entry)
        }
        .configurationDisplayName("Floe Agent")
        .description(Text(FloeL10n.l("widget.description")))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct FloeWidgetBundle: WidgetBundle {
    var body: some Widget {
        FloeWidget()
        FloeSystemAlarmLiveActivityWidget()
        #if os(iOS) && canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        FloeTaskLiveActivityWidget()
        #endif
    }
}
