// SPDX-License-Identifier: MPL-2.0
//
// HostChildSubagentController — the Mac host-facing surface for owned
// background project subagents (shared iOS v1.8.57 delegation on Mac).
//
// The controller is a thin, MainActor-observable wrapper over the real
// `FloeMacChildSubagentRuntime` (FloeMacSelfCore). `HostAgentWorkspace` owns
// one instance and binds one parent run per live project Agent/Goal session —
// the visible task and background tasks bind independently and concurrently;
// selection is presentation only. Children are always read back from the
// durable child store (active and completed alike), never from a live
// in-memory shadow. It grants no tool or permission authority of its own.

import Combine
import FloeAgentRuntime
import FloeMacSelfCore
import FloeModels
import FloePersistence
import FloeTools
import Foundation

/// One child row as the host presents it. Identity and state come from the
/// durable child store; `status` mirrors `ChildRunState` so active and
/// completed children read identically after a relaunch.
struct HostChildSubagentSnapshot: Identifiable, Hashable {
    enum Status: String, Hashable {
        case preparing
        case running
        case completed
        case partial
        case budgetExhausted
        case cancelled
        case providerError
        case toolError
        case interrupted
    }

    let id: UUID
    let parentRunID: UUID
    let conversationID: UUID
    let taskSummary: String
    let status: Status
    let iterationCount: Int
    let startedAt: Date
    let endedAt: Date?
    /// Bounded terminal findings when the durable terminal row committed.
    let findings: String?
    /// Bounded durable failure/unfinished detail for every non-completed
    /// terminal state (the child store's `errorText`). Surfaced on reopened
    /// tasks so a failed child shows its real reason, not only a status word.
    let error: String?

    init(record: ChildRunRecord) {
        self.id = record.id
        self.parentRunID = record.parentRunID
        self.conversationID = record.conversationID
        self.taskSummary = record.taskSummary
        self.iterationCount = record.iterationCount
        self.startedAt = record.startedAt
        self.endedAt = record.endedAt
        self.findings = record.resultSummary
        self.error = record.errorText
        switch record.state {
        case .registered: self.status = .preparing
        case .running: self.status = .running
        case .completed: self.status = .completed
        case .partial: self.status = .partial
        case .budgetExhausted: self.status = .budgetExhausted
        case .cancelled: self.status = .cancelled
        case .providerError: self.status = .providerError
        case .toolError: self.status = .toolError
        case .interrupted: self.status = .interrupted
        }
    }
}

@MainActor
final class HostChildSubagentController: ObservableObject {
    /// Per-parent binding state. Multiple parents (visible task, background
    /// tasks) bind concurrently; nothing here keys off UI selection.
    private struct ParentBinding: Hashable {
        let runID: UUID
        let conversationID: UUID
    }

    /// Children of the currently presented task, durable store order.
    @Published private(set) var presentedChildren: [HostChildSubagentSnapshot] = []
    /// The conversation currently presented (selection is presentation only).
    private(set) var presentedConversationID: UUID?

    private var childRuntime: FloeMacChildSubagentRuntime?
    private var childStore: (any ChildRunStoring)?
    private var bindings: [UUID: ParentBinding] = [:]
    /// In-flight preparation, if any. Concurrent `prepare` calls share one
    /// task instead of racing to construct two runtimes (reentrancy-safe
    /// idempotence: the second caller awaits the first result).
    private var prepareTask: Task<FloeMacChildSubagentRuntime, Error>?
    /// Bumped by every `present`. A refresh that started under an older
    /// generation must never publish, even if it completes after a newer
    /// selection — this closes the bind/state-callback → reselect window the
    /// post-await conversation check alone cannot.
    private var presentationGeneration = 0

    var isPrepared: Bool { childRuntime != nil }
    var boundRunCount: Int { bindings.count }

    /// The child runtime's run-scoped registry, so a session's tool binding
    /// can build its executor with THIS runtime's private delegation tools.
    /// Nil until `prepare` succeeds.
    var childRegistry: SubagentRunnerRegistry? { childRuntime?.registry }

    /// One-time preparation against the durable runtime: builds the shared
    /// child runtime over the runtime's single database writer and installs
    /// the five child lifecycle hooks into the session composition. Safe to
    /// call concurrently and repeatedly: every caller shares one in-flight
    /// task, later calls reuse the prepared runtime, and a failed prepare
    /// leaves no half-installed state (the next call retries cleanly).
    func prepare(runtime: FloeMacSelfRuntime) async throws {
        if let childRuntime {
            await runtime.installChildSubagentRuntime(childRuntime)
            return
        }
        if let prepareTask {
            let prepared = try await prepareTask.value
            await runtime.installChildSubagentRuntime(prepared)
            return
        }
        let task = Task<FloeMacChildSubagentRuntime, Error> {
            let store = try await runtime.childRunStoring()
            return FloeMacChildSubagentRuntime(childStore: store)
        }
        prepareTask = task
        do {
            let prepared = try await task.value
            // Re-check: nothing else could have won (only this task assigns),
            // but keep the invariant explicit and total.
            if childRuntime == nil {
                childRuntime = prepared
                childStore = try? await runtime.childRunStoring()
            }
            prepareTask = nil
            await runtime.installChildSubagentRuntime(prepared)
        } catch {
            prepareTask = nil
            throw error
        }
    }

    /// Bind one project Agent/Goal parent run before its session starts. The
    /// child runner inherits the run's exact provider binding and the run's
    /// own project executor — the child's discovery universe is the parent's
    /// effective catalog, and every child call resolves per call through the
    /// parent session runtime's canonical dispatcher (once/deny/full
    /// approval, frozen catalog identity, mutation leases). Without that
    /// handoff the shared runner fails closed to its read-only legacy
    /// ceiling. Concurrent parents bind independently.
    func bind(
        runID: UUID,
        conversationID: UUID,
        provider: FloeMacSelfProviderBinding,
        projectExecutor: (any ToolExecutor)?,
        runtime: FloeMacSelfRuntime
    ) async throws {
        try await prepare(runtime: runtime)
        bindings[runID] = ParentBinding(runID: runID, conversationID: conversationID)
        guard let childRuntime, let projectExecutor else {
            // Tool-free runs cannot delegate; the binding records ownership
            // so release/cancel stay total functions.
            return
        }
        await childRuntime.bindParentRun(
            runID: runID,
            provider: provider.provider,
            model: provider.model,
            adapter: provider.adapter,
            credentials: provider.credentials,
            projectExecutor: projectExecutor,
            onChildStateChange: { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refresh(conversationID: conversationID)
                }
            }
        )
        await refresh(conversationID: conversationID)
    }

    /// Parent-owned lifecycle end for exactly one run: interrupt/join its
    /// children and drop its runner. Every other bound parent — and every
    /// durable child row — is untouched. Idempotent.
    func release(runID: UUID) async {
        bindings.removeValue(forKey: runID)
        await childRuntime?.releaseParentRun(runID)
        if let presentedConversationID {
            await refresh(conversationID: presentedConversationID)
        } else {
            presentedChildren = []
        }
    }

    /// Presentation only: choose which task's children `presentedChildren`
    /// publishes. Never affects binding, execution or cancellation.
    func present(conversationID: UUID?) async {
        presentationGeneration += 1
        presentedConversationID = conversationID
        guard let conversationID else {
            presentedChildren = []
            return
        }
        await refresh(conversationID: conversationID)
    }

    /// Re-read the durable child rows of one task (all of its runs — active
    /// and history). Called on child state changes, run events and UI appear.
    /// Never publishes stale data: a refresh only lands when the conversation
    /// is still presented AND the presentation generation is unchanged.
    func refresh(conversationID: UUID) async {
        let generation = presentationGeneration
        guard let childStore else { return }
        guard let records = try? await childStore.children(conversationID: conversationID) else { return }
        let mapped = records.map { HostChildSubagentSnapshot(record: $0) }
        guard conversationID == presentedConversationID,
              generation == presentationGeneration,
              mapped != presentedChildren else { return }
        presentedChildren = mapped
    }

    /// Durable children of one task right now (for menus/detail views and
    /// for tests); does not depend on presentation or live binding.
    func children(of conversationID: UUID) async -> [HostChildSubagentSnapshot] {
        guard let childStore,
              let records = try? await childStore.children(conversationID: conversationID) else { return [] }
        return records.map { HostChildSubagentSnapshot(record: $0) }
    }

    /// Cancel exactly one background child of one bound parent run. The child
    /// settles durably as terminal `.cancelled`; every sibling and every
    /// child of every other parent keeps running.
    func cancelChild(runID: UUID, conversationID: UUID, childID: UUID) async -> Bool {
        guard let childRuntime, bindings[runID] != nil else { return false }
        do {
            try await childRuntime.cancelChild(
                runID: runID,
                conversationID: conversationID,
                childID: childID
            )
        } catch {
            return false
        }
        await refresh(conversationID: conversationID)
        return true
    }

    /// Non-blocking snapshot of one child (detail views / tests).
    func snapshot(runID: UUID, conversationID: UUID, childID: UUID) async -> BackgroundChildSnapshot? {
        guard let childRuntime else { return nil }
        return try? await childRuntime.backgroundSnapshot(
            runID: runID,
            conversationID: conversationID,
            childID: childID
        )
    }
}
