#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeTools

/// Associates the existing shared download with the run that is waiting for
/// it. Entries represent service calls, never a view-owned download or timer.
///
/// Each entry owns one waiter lease: its own derived token can cancel only
/// that wait. The shared job stops when its last waiter leaves; the settings
/// card's explicit cancel is the separate global path.
@MainActor
final class TaskRuntimePreparationCenter: ObservableObject {
    static let shared = TaskRuntimePreparationCenter()

    struct Activity: Identifiable, Sendable {
        let id: UUID
        let runID: UUID
        let imageID: String
        let environmentID: String?
        /// Monotonic per-center generation. A banner for a run always shows
        /// the newest activity and an `end` removes only its exact activity,
        /// so a late callback can never hide a newer one.
        let generation: UInt64
        /// This waiter's own cancellation signal. Cancelling it stops only
        /// this wait; the shared image job stops only if this was its last
        /// waiter. It is never the caller's shared token.
        let waitToken: CancellationToken
        /// The live shared attempt this activity joined, bound by
        /// `EnvironmentPackageJobs` once the attempt exists. The banner shows
        /// job phases/bytes only for this exact attempt, never for a newer one.
        var attemptEpoch: UUID?
    }

    @Published private(set) var activities: [Activity] = []
    /// Activities whose wait token was cancelled and whose lease is unwinding.
    /// The banner shows an honest "cancelling" label instead of leaving an
    /// unexplained spinner; `end` removes the entry.
    @Published private(set) var cancelling: Set<UUID> = []
    private var nextGeneration: UInt64 = 0

    /// Registers one run-owned wait. Returns nil when there is no run to tie
    /// the activity to (settings/card callers have no task banner) or when the
    /// wait token was already cancelled before the activity could appear.
    func begin(
        runID: UUID?,
        imageID: String,
        environmentID: String?,
        waitToken: CancellationToken
    ) -> Activity? {
        guard let runID, !waitToken.isCancelled else { return nil }
        nextGeneration &+= 1
        let activity = Activity(
            id: UUID(),
            runID: runID,
            imageID: imageID,
            environmentID: environmentID,
            generation: nextGeneration,
            waitToken: waitToken,
            attemptEpoch: nil
        )
        activities = activities + [activity]
        return activity
    }

    /// Removes exactly one activity generation. An older callback cannot clear
    /// a newer activity for the same run.
    func end(_ id: UUID?) {
        guard let id else { return }
        activities = activities.filter { $0.id != id }
        if cancelling.contains(id) {
            cancelling = cancelling.subtracting([id])
        }
    }

    /// Binds this activity to the shared attempt every waiter actually joined.
    func bind(_ id: UUID?, attemptEpoch: UUID?) {
        guard let id, let attemptEpoch,
              let index = activities.firstIndex(where: { $0.id == id }) else { return }
        var updated = activities
        updated[index].attemptEpoch = attemptEpoch
        activities = updated
    }

    /// Cancels every wait owned by this task. Only this task's leases are
    /// released; another task waiting on the same image keeps its download.
    func cancelAll(runID: UUID) {
        var next = cancelling
        for activity in activities where activity.runID == runID {
            next.insert(activity.id)
            activity.waitToken.cancel()
        }
        cancelling = next
    }

    func isCancelling(_ id: UUID) -> Bool {
        cancelling.contains(id)
    }
}

struct TaskRuntimePreparationBanner: View {
    let runID: UUID?
    @ObservedObject private var center = TaskRuntimePreparationCenter.shared
    @ObservedObject private var jobs = EnvironmentPackageJobs.shared
    @State private var details: TaskRuntimePreparationCenter.Activity?

    var body: some View {
        if let activity = currentActivity {
            let jobID = LinuxImageInstallModel.jobPrefix + activity.imageID
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(center.isCancelling(activity.id)
                         ? String(localized: "envmgr.cancelling")
                         : phaseText(for: activity, jobID: jobID))
                        .font(.subheadline)
                    Spacer()
                    Button("action.details") { details = activity }
                        .font(.subheadline)
                    if !center.isCancelling(activity.id) {
                        Button("action.cancel") {
                            // Task-scoped: releases only this run's waits. The
                            // shared job stops only if this was the last user.
                            center.cancelAll(runID: activity.runID)
                        }
                        .font(.subheadline)
                    }
                }
                if let transfer = liveTransfer(for: activity, jobID: jobID) {
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

    /// The newest activity for this exact run. Activity identity includes the
    /// run id and environment hint; another task's status can never be shown.
    private var currentActivity: TaskRuntimePreparationCenter.Activity? {
        guard let runID else { return nil }
        return center.activities
            .filter { $0.runID == runID }
            .max { $0.generation < $1.generation }
    }

    /// True only while the activity is bound to the attempt the store still
    /// owns. A completed attempt's status is never rendered as a newer one's.
    private func isLiveAttempt(
        _ activity: TaskRuntimePreparationCenter.Activity,
        jobID: String
    ) -> Bool {
        guard let epoch = activity.attemptEpoch else { return false }
        return jobs.attemptEpoch(id: jobID) == epoch
    }

    private func phaseText(
        for activity: TaskRuntimePreparationCenter.Activity,
        jobID: String
    ) -> String {
        guard isLiveAttempt(activity, jobID: jobID),
              let phase = jobs.phases[jobID] else {
            return String(localized: "runtime.preparation.waiting")
        }
        return LinuxImageInstallCard.phaseText(phase)
    }

    private func liveTransfer(
        for activity: TaskRuntimePreparationCenter.Activity,
        jobID: String
    ) -> LinuxImageTransferSnapshot? {
        guard isLiveAttempt(activity, jobID: jobID) else { return nil }
        return jobs.transfers[jobID]
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func rate(_ bytes: Int64) -> String {
        bytes > 0 ? " · \(size(bytes))/s" : ""
    }
}

/// Opened only when the user taps Details. It mirrors the same bound attempt's
/// phase and REAL byte counters; it never starts a second job and offers no
/// second cancel path (the compact banner owns the task-scoped cancel).
private struct RuntimePreparationDetails: View {
    let activity: TaskRuntimePreparationCenter.Activity
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var center = TaskRuntimePreparationCenter.shared
    @ObservedObject private var jobs = EnvironmentPackageJobs.shared

    private var jobID: String { LinuxImageInstallModel.jobPrefix + activity.imageID }

    /// The sheet holds a value snapshot taken at presentation time; the live
    /// center entry is the authority for the attempt binding. Without this a
    /// sheet opened in the pre-attempt "waiting" window would never observe
    /// the epoch written after the shared attempt starts.
    private var isLiveAttempt: Bool {
        guard let epoch = center.activities.first(where: { $0.id == activity.id })?.attemptEpoch else {
            return false
        }
        return jobs.attemptEpoch(id: jobID) == epoch
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(String(localized: "settings.exec.linux.section"), systemImage: "shippingbox")
                        .font(.headline)
                    Text(phaseText)
                        .font(.subheadline)
                    if let transfer = liveTransfer {
                        if let total = transfer.totalBytes, total > 0 {
                            ProgressView(value: min(Double(transfer.receivedBytes) / Double(total), 1))
                            Text("\(Int(min(Double(transfer.receivedBytes) / Double(total), 1) * 100))% · \(size(transfer.receivedBytes)) / \(size(total))\(rate(transfer.bytesPerSecond))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(size(transfer.receivedBytes))\(rate(transfer.bytesPerSecond))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if jobs.failures.contains(jobID), let message = jobs.messages[jobID], !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(FloeTheme.destructive)
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            .navigationTitle("runtime.preparation.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
        }
    }

    private var phaseText: String {
        guard isLiveAttempt, let phase = jobs.phases[jobID] else {
            return String(localized: "runtime.preparation.waiting")
        }
        return LinuxImageInstallCard.phaseText(phase)
    }

    private var liveTransfer: LinuxImageTransferSnapshot? {
        guard isLiveAttempt else { return nil }
        return jobs.transfers[jobID]
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func rate(_ bytes: Int64) -> String {
        bytes > 0 ? " · \(size(bytes))/s" : ""
    }
}
#endif
