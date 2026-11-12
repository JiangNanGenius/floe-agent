// FloeApp — one-tap entry for the Linux-only cache-cleanup task.
//
// The tap always creates an ordinary visible conversation first. It then
// commits its create-only cleanup purpose and workspace before publication,
// resolves/binds the explicit shared Linux environment, then launches the dedicated
// model task or the bundled native-script fallback. No host path, project,
// temporary directory or catalog-default environment is ever selected.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeEnvironments
import FloeExecution
import FloeTools

@MainActor
enum LinuxCacheCleanupEntryPoint {
    struct StartResult: Sendable {
        var conversationID: UUID
        var runID: UUID?
        var usedFallback: Bool
        var errorMessage: String?
    }

    static func start(
        environment: AppEnvironment,
        conversationCenter: ConversationCenter
    ) async throws -> StartResult {
        let conversation = try await conversationCenter.createConversation(
            title: LinuxCacheCleanupText.title,
            purpose: .ordinary,
            linuxCacheCleanup: true
        )
        let prompt = LinuxCacheCleanupPrompt.initialRequest(chinese: FloeL10n.isChinese)

        do {
            let record = try await resolveSharedEnvironment(environment)
            let profile = try await persistPurpose(
                environment: environment,
                conversationID: conversation.id,
                record: record
            )

            if let pair = usableToolCapableModel(conversationCenter) {
                do {
                    let started = try await conversationCenter.startRun(
                        goal: prompt,
                        in: conversation.id,
                        provider: pair.provider,
                        model: pair.model,
                        executionMode: .agent,
                        executionEnvironmentID: record.id,
                        startOrigin: .explicitUserAction
                    )
                    return StartResult(
                        conversationID: conversation.id,
                        runID: started.runID,
                        usedFallback: false
                    )
                } catch {
                    await recordUnstartable(
                        environment: environment,
                        conversationID: conversation.id,
                        prompt: prompt,
                        error: error
                    )
                    return StartResult(
                        conversationID: conversation.id,
                        runID: nil,
                        usedFallback: false,
                        errorMessage: error.localizedDescription
                    )
                }
            }

            do {
                let runID = try await LinuxCacheCleanupFallbackRunner.shared.start(
                    environment: environment,
                    conversationID: conversation.id,
                    profile: profile,
                    prompt: prompt
                )
                return StartResult(
                    conversationID: conversation.id,
                    runID: runID,
                    usedFallback: true
                )
            } catch {
                await recordUnstartable(
                    environment: environment,
                    conversationID: conversation.id,
                    prompt: prompt,
                    error: error
                )
                return StartResult(
                    conversationID: conversation.id,
                    runID: nil,
                    usedFallback: true,
                    errorMessage: error.localizedDescription
                )
            }
        } catch {
            await recordUnstartable(
                environment: environment,
                conversationID: conversation.id,
                prompt: prompt,
                error: error
            )
            return StartResult(
                conversationID: conversation.id,
                runID: nil,
                usedFallback: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    /// Explicitly the App-wide shared Linux environment. Requiring kind
    /// `.shared` prevents a first-project/session or temporary environment
    /// from becoming the cleanup target by accident.
    private static func resolveSharedEnvironment(_ environment: AppEnvironment) async throws -> ContainerRecord {
        // Cleanup only reads the already-loaded registry. Never initialize,
        // migrate or prepare a missing environment to remove its caches.
        guard let record = await environment.environmentRegistry.record(
            id: EnvironmentRegistry.sharedContainerID
        ) else {
            throw FloeError.notFound("The shared Linux environment")
        }
        guard record.kind == .shared,
              record.effectiveExecutionBackend == .linuxVM,
              record.state == .active,
              !record.requiresRebuild,
              record.pendingRuntimeResetID == nil else {
            throw FloeError.invalidConfiguration(
                LinuxCacheCleanupText.t(
                    "共享 Linux 环境当前不可用于清理。请打开 设置 → 执行环境，检查或修复共享运行时后重试。没有重置磁盘。",
                    "The shared Linux environment is not currently usable for cleanup. Open Settings > Execution Environments, check or repair the shared runtime, then retry. No disk was reset."
                )
            )
        }
        return record
    }

    private static func persistPurpose(
        environment: AppEnvironment,
        conversationID: UUID,
        record: ContainerRecord
    ) async throws -> LinuxCacheCleanupTaskProfile {
        guard let profile = try await LinuxCacheCleanupTaskStore(database: environment.database)
            .profile(conversationID: conversationID),
              profile.isValid, profile.environmentID == record.id,
              profile.conversationID == conversationID else {
            throw FloeError.storageCorrupted("The durable Linux cleanup purpose is unavailable")
        }

        let target = TaskExecutionTarget(
            environmentID: record.id,
            backend: .linuxVM,
            operatingSystem: record.operatingSystem ?? "linux",
            architecture: record.architecture ?? "arm64",
            runtimeGeneration: record.runtimeGeneration
        )
        let saved = try await TaskExecutionBindingStore(database: environment.database)
            .bindInitial(TaskExecutionBinding(conversationID: conversationID, target: target))
        guard saved.target == target else {
            throw FloeError.validationFailed(
                LinuxCacheCleanupText.t(
                    "此任务已绑定到另一个运行环境；请创建一个新的清理任务。",
                    "This task is already bound to another environment; create a new cleanup task."
                )
            )
        }

        try await SQLiteWorkspaceStore(database: environment.database).saveTaskPolicy(
            TaskPolicy(
                conversationID: conversationID,
                approvalMode: TaskApprovalMode.automatic.rawValue,
                allowedToolNames: LinuxCacheCleanupScope.allowedToolNames,
                filePaths: [],
                networkAllowed: false,
                browserControlAllowed: false,
                uploadAllowed: false,
                credentialsAllowed: false,
                remoteExecutionAllowed: false,
                recoveryPolicy: .safePoint,
                notificationPolicy: .terminal
            )
        )
        return profile
    }

    private static func usableToolCapableModel(
        _ center: ConversationCenter
    ) -> (provider: ProviderProfile, model: ModelProfile)? {
        if let pair = center.defaultProviderAndModel(),
           pair.1.capabilities.contains(.tools) {
            return (provider: pair.0, model: pair.1)
        }
        for model in center.availableAgentModels where model.capabilities.contains(.tools) {
            if let pair = center.providerAndModel(modelID: model.id) {
                return (provider: pair.0, model: pair.1)
            }
        }
        return nil
    }

    /// The conversation already exists. This records an honest failed native
    /// run (no provider/model identity) plus actionable text, so the tap still
    /// leaves a real visible task instead of an invisible draft or a fake
    /// model receipt.
    private static func recordUnstartable(
        environment: AppEnvironment,
        conversationID: UUID,
        prompt: String,
        error: Error
    ) async {
        let message = LinuxCacheCleanupText.failureMessage(error)
        let runs = (try? await environment.runStore.runs(conversationID: conversationID)) ?? []
        var runID: UUID?
        if let latest = runs.last {
            runID = latest.id
            if latest.endedAt == nil, !["completed", "failed", "cancelled"].contains(latest.state) {
                try? await environment.runStore.updateRunState(
                    id: latest.id,
                    state: "failed",
                    endedAt: Date()
                )
            }
        } else {
            let id = UUID()
            do {
                _ = try await environment.runLaunchStore.prepare(RunLaunchRequest(
                    conversationID: conversationID,
                    runID: id,
                    goal: prompt,
                    initialState: "failed",
                    conversationMode: "chat",
                    initialPolicy: DraftTaskPolicy(
                        approvalMode: .automatic,
                        recoveryPolicy: .safePoint,
                        notificationPolicy: .terminal
                    ),
                    messageRole: "user"
                ))
                try await environment.runStore.updateRunState(id: id, state: "failed", endedAt: Date())
                runID = id
            } catch {
                runID = nil
            }
        }
        try? await environment.conversationStore.appendMessage(PersistedMessage(
            id: UUID(),
            conversationID: conversationID,
            role: "assistant",
            content: message,
            createdAt: Date(),
            runID: runID
        ))
        await environment.conversationCenter.nativeConversationDidChange(conversationID)
    }
}
#endif
