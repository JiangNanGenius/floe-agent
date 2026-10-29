#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Associates the existing shared download with the run that is waiting for
/// it. Entries represent service calls, never a view-owned download or timer.
@MainActor
final class TaskRuntimePreparationCenter: ObservableObject {
    static let shared = TaskRuntimePreparationCenter()
    struct Activity: Identifiable {
        let id: UUID
        let runID: UUID
        let imageID: String
        let environmentID: String?
    }
    @Published private(set) var activities: [Activity] = []

    func begin(runID: UUID?, imageID: String, environmentID: String?) -> UUID? {
        guard let runID else { return nil }
        let id = UUID()
        activities.append(Activity(id: id, runID: runID, imageID: imageID, environmentID: environmentID))
        return id
    }

    func end(_ id: UUID?) {
        guard let id else { return }
        activities.removeAll { $0.id == id }
    }
}

struct TaskRuntimePreparationBanner: View {
    let runID: UUID?
    @ObservedObject private var center = TaskRuntimePreparationCenter.shared
    @ObservedObject private var jobs = EnvironmentPackageJobs.shared
    @State private var details: TaskRuntimePreparationCenter.Activity?

    var body: some View {
        if let activity = center.activities.first(where: { $0.runID == runID }) {
            let jobID = LinuxImageInstallModel.jobPrefix + activity.imageID
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(jobs.phases[jobID].map(LinuxImageInstallCard.phaseText)
                         ?? String(localized: "runtime.preparation.waiting"))
                        .font(.subheadline)
                    Spacer()
                    Button("action.details") { details = activity }
                        .font(.subheadline)
                    Button("action.cancel") {
                        FloePlatformServices.shared.cancelLinuxImagePreparation(imageID: activity.imageID)
                    }
                    .font(.subheadline)
                }
                if let transfer = jobs.transfers[jobID] {
                    if let total = transfer.totalBytes, total > 0 {
                        ProgressView(value: min(Double(transfer.receivedBytes) / Double(total), 1))
                        Text("\(Int(min(Double(transfer.receivedBytes) / Double(total), 1) * 100))% · \(size(transfer.receivedBytes)) / \(size(total))\(rate(transfer.bytesPerSecond))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(size(transfer.receivedBytes))\(rate(transfer.bytesPerSecond))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.regularMaterial)
            .accessibilityIdentifier("thread.runtime.preparation")
            .sheet(item: $details) { activity in
                RuntimePreparationDetails(activity: activity)
            }
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func rate(_ bytes: Int64) -> String {
        bytes > 0 ? " · \(size(bytes))/s" : ""
    }
}

private struct RuntimePreparationDetails: View {
    let activity: TaskRuntimePreparationCenter.Activity
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: LinuxImageInstallModel

    init(activity: TaskRuntimePreparationCenter.Activity) {
        self.activity = activity
        _model = StateObject(wrappedValue: LinuxImageInstallModel(imageID: activity.imageID))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LinuxImageInstallCard(model: model, allowsManualStart: false).padding()
            }
            .navigationTitle("runtime.preparation.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("action.done") { dismiss() } } }
            .task { await model.refresh(environmentIDHint: activity.environmentID) }
        }
    }
}
#endif
