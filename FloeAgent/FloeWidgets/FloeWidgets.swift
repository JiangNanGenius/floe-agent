// FloeWidgets — Home screen widget for quick task access.
//
// Shows active tasks and provides a quick way to start a new task from the
// home screen. Reads a snapshot JSON from the shared App Group container
// (written by the main app when run state changes).

import WidgetKit
import SwiftUI
import FloeCore

struct TaskSnapshot: Codable {
    var activeTasks: [ActiveTask]
    var updatedAt: Date

    struct ActiveTask: Codable, Identifiable {
        var id: String
        var title: String
        var state: String
    }
}

struct FloeWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TaskSnapshot?
}

struct FloeWidgetProvider: TimelineProvider {
    private static let appGroupID = "group.org.floeagent.ios"

    init() {
        // Widgets run in their own process; resolve the language
        // chosen in the main app (mirrored into the App Group).
        FloeL10n.bootstrap()
    }

    func placeholder(in context: Context) -> FloeWidgetEntry {
        FloeWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (FloeWidgetEntry) -> Void) {
        completion(FloeWidgetEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FloeWidgetEntry>) -> Void) {
        let entry = FloeWidgetEntry(date: Date(), snapshot: loadSnapshot())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadSnapshot() -> TaskSnapshot? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return nil }
        let url = container.appendingPathComponent("WidgetSnapshot/tasks.json")
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TaskSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }
}

struct FloeWidgetView: View {
    let entry: FloeWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Floe Agent")
                .font(.headline)
            if let snapshot = entry.snapshot, !snapshot.activeTasks.isEmpty {
                ForEach(snapshot.activeTasks.prefix(3)) { task in
                    HStack {
                        Circle()
                            .fill(task.state == "running" ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Text(task.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(FloeL10n.l("widget.empty_active_tasks"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link(destination: URL(string: "floe://new")!) {
                Label("workbench.new_task", systemImage: "plus.circle.fill")
                    .font(.caption)
            }
        }
        .padding()
    }
}

@main
struct FloeWidget: Widget {
    let kind = "FloeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FloeWidgetProvider()) { entry in
            FloeWidgetView(entry: entry)
        }
        .configurationDisplayName("Floe Agent")
        .description(FloeL10n.l("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
