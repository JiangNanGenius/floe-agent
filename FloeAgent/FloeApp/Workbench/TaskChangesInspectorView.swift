// FloeApp — Task-scoped file change evidence.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Crypto
import FloeModels
import FloePersistence
import FloeCore

@MainActor
private final class TaskChangesInspectorModel: ObservableObject {
    typealias Change = FloeTaskActivityChange

    @Published private(set) var changes: [Change] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    func load(conversationID: UUID, runStore: any RunStore) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let runs = try await runStore.runs(conversationID: conversationID)
            var events: [UUID: [RunEventRecord]] = [:]
            for run in runs {
                events[run.id] = try await runStore.events(runID: run.id)
            }
            changes = FloeTaskActivityProjection.changes(runs: runs, events: events)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Diff text only ever comes from the bounded, digest-addressed artifact
    /// receipt verified against the FloeAgent store (see
    /// `FloeVerifiedChangeArtifact`); the workspace itself is never read.
    func verifiedDiff(for change: Change) throws -> String? {
        guard let artifact = change.artifact else { return nil }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
        return try FloeVerifiedChangeArtifact.verifiedDiff(artifact, floeAgentRoot: root)
    }
}

struct TaskChangesInspectorView: View {
    let conversationID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = TaskChangesInspectorModel()
    @State private var selected: TaskChangesInspectorModel.Change?
    @State private var selectedDiff: String?

    var body: some View {
        Group {
            if let selected, let selectedDiff {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            self.selected = nil
                            self.selectedDiff = nil
                        } label: {
                            Label("settings.document_recovery_list_view.back", systemImage: "chevron.left")
                        }
                        Spacer()
                        Text(selected.path).lineLimit(1)
                    }
                    .padding(12)
                    Divider()
                    DiffView(diffText: selectedDiff)
                }
            } else {
                changeList
            }
        }
        .background(FloeTheme.readingSurface)
        .task(id: conversationID) {
            guard let conversationID else { return }
            await model.load(conversationID: conversationID, runStore: environment.runStore)
        }
    }

    private var changeList: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.changes.isEmpty {
                ContentUnavailableView("workbench.task_changes_inspector_view.no_file_changes",
                    systemImage: "plusminus",
                    description: Text("workbench.task_changes_inspector_view.after_the_current_task_modifies_files")
                )
            } else {
                List(model.changes) { change in
                    FloeTaskActivityChangeRow(
                        change: change,
                        isEnabled: change.hasDiffReceipt
                    ) { openDiff(change) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("files.open") { openFile(change.path) }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("chat.thread_detail_view.changes").font(.headline)
                Text(FloeL10n.l("workbench.task_changes_inspector_view.file_operations", model.changes.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { router.hideInspector() } label: {
                Image(systemName: "xmark")
                    .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
            }
            .accessibilityLabel("inspector.close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openDiff(_ change: TaskChangesInspectorModel.Change) {
        do {
            if let diff = try model.verifiedDiff(for: change) {
                selected = change
                selectedDiff = diff
            }
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func openFile(_ path: String) {
        Task {
            var state = environment.workspaceCenter.currentWorkspace?.inspectorState ?? InspectorState()
            state.selectedRelativePath = path
            state.isExpanded = true
            await environment.workspaceCenter.updateInspectorState(state)
            router.showInspector(.workspaceFiles)
        }
    }
}
#endif
