// FloeApp — native-script fallback for the one-tap Linux cleanup task.
//
// When no tool-capable model is configured, the same conversation gets a real
// durable run with providerID/modelID/name all nil. The bundled script runs
// through the same service-owned exec.shell/background-job route, and its
// actual progress/result is written into that chat. Nothing is presented as a
// model turn or provider receipt.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeExecution
import FloeTools

@MainActor
final class LinuxCacheCleanupFallbackRunner {
    static let shared = LinuxCacheCleanupFallbackRunner()

    private struct Active {
        var task: Task<Void, Never>
        var cancellation: CancellationToken
        var environment: AppEnvironment
        var conversationID: UUID
        var profile: LinuxCacheCleanupTaskProfile
        var service: LinuxCacheCleanupService
        var lease: WorkspaceCenter.TaskRootLease?
        var jobID: UUID?
    }

    private var active: [UUID: Active] = [:]
    private init() {}

    func owns(_ runID: UUID) -> Bool { active[runID] != nil }

    func start(
        environment: AppEnvironment,
        conversationID: UUID,
        profile: LinuxCacheCleanupTaskProfile,
        prompt: String
    ) async throws -> UUID {
        guard profile.isValid,
              profile.conversationID == conversationID,
              profile.backend == .linuxVM,
              let service = environment.linuxCacheCleanupService else {
            throw FloeError.invalidConfiguration(
                LinuxCacheCleanupText.t(
                    "内置 Linux 清理服务尚未就绪，请稍后重试。",
                    "The bundled Linux cleanup service is not ready yet; try again shortly."
                )
            )
        }

        let runID = UUID()
        let prepared = try await environment.runLaunchStore.prepare(RunLaunchRequest(
            conversationID: conversationID,
            runID: runID,
            goal: prompt,
            initialState: "preparing",
            conversationMode: "chat",
            initialPolicy: DraftTaskPolicy(
                approvalMode: .automatic,
                recoveryPolicy: .safePoint,
                notificationPolicy: .terminal
            ),
            messageRole: "user"
        ))

        let lease: WorkspaceCenter.TaskRootLease
        do {
            lease = try await environment.workspaceCenter.acquireTaskRoot(
                prepared.workspace,
                conversationID: conversationID
            )
        } catch {
            // The entry point records one actionable failure message for the
            // already-prepared run; do not duplicate it here.
            try? await environment.runStore.updateRunState(id: runID, state: "failed", endedAt: Date())
            throw error
        }

        do {
            let store = TaskExecutionBindingStore(database: environment.database)
            guard let binding = try await store.binding(conversationID: conversationID) else {
                throw FloeError.validationFailed("The cleanup task has no explicit Linux binding")
            }
            try await store.pinRun(runID: runID, binding: binding)
        } catch {
            lease.release()
            try? await environment.runStore.updateRunState(id: runID, state: "failed", endedAt: Date())
            throw error
        }

        try await environment.runStore.updateRunState(id: runID, state: "running", endedAt: nil)
        let cancellation = CancellationToken()
        // Publish native ownership BEFORE the first await: a Stop tapped as
        // soon as the chat appears must reach this run and its real job.
        active[runID] = Active(
            task: Task {},
            cancellation: cancellation,
            environment: environment,
            conversationID: conversationID,
            profile: profile,
            service: service,
            lease: lease,
            jobID: nil
        )
        var activeRun = prepared.run
        activeRun.state = "running"
        environment.conversationCenter.registerNativeRun(activeRun)
        try? await environment.conversationStore.appendMessage(PersistedMessage(
            id: UUID(),
            conversationID: conversationID,
            role: "assistant",
            content: LinuxCacheCleanupText.fallbackStarted,
            createdAt: Date(),
            runID: runID
        ))
        await environment.conversationCenter.nativeConversationDidChange(conversationID)

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.execute(runID: runID)
        }
        active[runID]?.task = task
        return runID
    }

    /// Composer Stop reaches this through ConversationCenter.cancel(runID:).
    /// It requests the real job stop and reports only the actual terminal
    /// state; it never starts a second cleanup.
    func cancel(runID: UUID) async {
        guard let entry = active.removeValue(forKey: runID) else { return }
        entry.cancellation.cancel()
        entry.task.cancel()
        let receipt: LinuxCacheCleanupReceipt?
        if let jobID = entry.jobID {
            receipt = try? await entry.service.cancel(
                jobID: jobID,
                conversationID: entry.conversationID,
                environmentID: entry.profile.environmentID
            )
        } else {
            receipt = nil
        }
        try? await entry.environment.runStore.updateRunState(
            id: runID,
            state: "cancelled",
            endedAt: Date()
        )
        entry.environment.conversationCenter.finishNativeRun(
            runID, conversationID: entry.conversationID)
        let message = receipt.map(LinuxCacheCleanupText.fallbackCancelled)
            ?? LinuxCacheCleanupText.t(
                "已请求停止内置 Linux 清理脚本；未开始新的清理。",
                "Stop was requested for the bundled Linux cleanup script; no new cleanup was started."
            )
        try? await entry.environment.conversationStore.appendMessage(PersistedMessage(
            id: UUID(),
            conversationID: entry.conversationID,
            role: "assistant",
            content: message,
            createdAt: Date(),
            runID: runID
        ))
        entry.lease?.release()
        await entry.environment.conversationCenter.nativeConversationDidChange(entry.conversationID)
    }

    private func execute(runID: UUID) async {
        guard let entry = active[runID] else { return }
        let context = LinuxCacheCleanupContext(
            runID: runID,
            conversationID: entry.conversationID,
            environmentID: entry.profile.environmentID,
            workspaceRootURL: entry.lease?.url,
            allowedWorkspacePaths: [],
            cancellation: entry.cancellation
        )
        do {
            let receipt = try await entry.service.clean(
                context: context,
                categories: LinuxCacheCleanupCategory.defaultSafe,
                onJobSubmitted: { [weak self] jobID in
                    await MainActor.run {
                        guard var entry = self?.active[runID] else { return }
                        entry.jobID = jobID
                        self?.active[runID] = entry
                    }
                }
            )
            let message: String
            let state: String
            if receipt.cancelled {
                message = LinuxCacheCleanupText.fallbackCancelled(receipt)
                state = "cancelled"
            } else if receipt.needsInspection {
                message = LinuxCacheCleanupText.fallbackNeedsInspection(receipt)
                state = "failed"
            } else if receipt.reusedElsewhere {
                message = LinuxCacheCleanupText.fallbackReusedElsewhere(receipt)
                state = "completed"
            } else if receipt.state == "failed" || receipt.error != nil {
                message = LinuxCacheCleanupText.fallbackFailed(receipt)
                state = "failed"
            } else {
                message = LinuxCacheCleanupText.fallbackCompleted(receipt)
                state = "completed"
            }
            await finish(runID: runID, state: state, message: message)
        } catch FloeError.cancelled {
            await finishCancelledIfStillOwned(runID: runID)
        } catch is CancellationError {
            await finishCancelledIfStillOwned(runID: runID)
        } catch {
            let receipt = LinuxCacheCleanupReceipt(
                state: "failed",
                mode: "clean",
                categories: LinuxCacheCleanupCategory.defaultSafe.map(\.rawValue),
                error: error.localizedDescription,
                repairGuidance: LinuxCacheCleanupEnvironmentRepair.guidance(for: error)
            )
            await finish(runID: runID, state: "failed", message: LinuxCacheCleanupText.fallbackFailed(receipt))
        }
    }

    private func finishCancelledIfStillOwned(runID: UUID) async {
        guard let entry = active[runID] else { return }
        let receipt = LinuxCacheCleanupReceipt(
            state: "cancelled",
            mode: "clean",
            categories: LinuxCacheCleanupCategory.defaultSafe.map(\.rawValue),
            cancelled: true
        )
        try? await entry.environment.runStore.updateRunState(id: runID, state: "cancelled", endedAt: Date())
        entry.environment.conversationCenter.finishNativeRun(
            runID, conversationID: entry.conversationID)
        try? await entry.environment.conversationStore.appendMessage(PersistedMessage(
            id: UUID(),
            conversationID: entry.conversationID,
            role: "assistant",
            content: LinuxCacheCleanupText.fallbackCancelled(receipt),
            createdAt: Date(),
            runID: runID
        ))
        active.removeValue(forKey: runID)
        entry.lease?.release()
        await entry.environment.conversationCenter.nativeConversationDidChange(entry.conversationID)
    }

    private func finish(runID: UUID, state: String, message: String) async {
        guard let entry = active.removeValue(forKey: runID) else { return }
        try? await entry.environment.runStore.updateRunState(id: runID, state: state, endedAt: Date())
        entry.environment.conversationCenter.finishNativeRun(
            runID, conversationID: entry.conversationID)
        try? await entry.environment.conversationStore.appendMessage(PersistedMessage(
            id: UUID(),
            conversationID: entry.conversationID,
            role: "assistant",
            content: message,
            createdAt: Date(),
            runID: runID
        ))
        entry.lease?.release()
        await entry.environment.conversationCenter.nativeConversationDidChange(entry.conversationID)
    }
}
#endif
