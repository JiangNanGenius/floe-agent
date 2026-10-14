// FloeApp — Canvas destination opener: loads the canvas workspace record
// and opens the SAME WorkspaceCanvasView surface used everywhere else.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloePersistence

struct CanvasDestinationOpener: View {
    let canvasID: UUID
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: WorkspaceRecord?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let workspace {
                WorkspaceCanvasView(
                    canvasID: canvasID, name: workspace.name, workspace: workspace)
            } else if loadFailed {
                // Honest recovery: a missing/unreadable workspace record is
                // a real error state (retry or close) — never an infinite
                // spinner with a swallowed `try?`.
                ContentUnavailableView {
                    Label("canvas.destination.openFailed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("canvas.destination.openFailed.message")
                } actions: {
                    Button("action.retry") {
                        loadFailed = false
                        Task { await load() }
                    }
                    .accessibilityIdentifier("canvas.destination.retry")
                    Button("common.close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("canvas.destination.close")
                }
                .accessibilityIdentifier("canvas.destination.openFailed")
            } else {
                ProgressView("canvas.destination.opening")
                    .task { await load() }
            }
        }
    }

    private func load() async {
        do {
            let record = try await SQLiteWorkspaceStore(database: environment.database)
                .workspace(id: canvasID)
            if let record {
                workspace = record
            } else {
                // The workspace row is gone: a truthful failure, not a
                // perpetual progress view.
                loadFailed = true
            }
        } catch {
            loadFailed = true
        }
    }
}
#endif
