#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeEnvironments
import FloeExecution

/// Availability is read from the trusted conversation binding. Selecting a
/// backup opens a new task; the old Mac job and its replay fence stay intact.
struct TaskMacBridgeAvailability: View {
    let conversationID: UUID
    let runID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @State private var isMacEnvironment = false
    @State private var showsBackup = false

    var body: some View {
        MacBridgeDisconnectedBanner(isMacEnvironment: isMacEnvironment) {
            showsBackup = true
        }
        .task(id: "\(conversationID.uuidString)-\(runID?.uuidString ?? "none")") {
            guard MacBridgeConnectionCenter.isMac else { return }
            let rows = await environment.environmentRegistry.containersOwned(by: conversationID.uuidString)
            guard !Task.isCancelled else { return }
            isMacEnvironment = rows.contains {
                $0.kind == .session && $0.effectiveExecutionBackend == .macBridge && $0.state != .deleting
            }
        }
        .sheet(isPresented: $showsBackup) {
            MacBackupRuntimeSheet {
                MacBridgeRoutingPreferences.preferMacForNewTasks = false
                showsBackup = false
                router.startNewTask()
            }
        }
    }
}

private struct MacBackupRuntimeSheet: View {
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LinuxImageInstallModel(imageID: LinuxGuestImageDistributionCatalog.defaultImageID)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("mac.bridge.backup.new_task_note")
                    Button("mac.bridge.backup.new_task", action: onUse)
                }
                Section {
                    LinuxImageInstallCard(model: model, allowsManualStart: false)
                }
            }
            .navigationTitle("mac.bridge.use_backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } } }
            .task { await model.refresh() }
        }
    }
}
#endif
