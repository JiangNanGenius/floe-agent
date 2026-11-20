// SPDX-License-Identifier: MPL-2.0
//
// Mac owned background project subagents — the shared iOS v1.8.57 delegation
// seam composed onto the Mac self-core runtime.
//
// This file adds NO second agent loop, NO second permission policy and NO
// second persistence model. It reuses, unchanged:
// - the real `SubagentRunnerRegistry` / `SubagentRunner` (FloeAgentRuntime),
// - the durable `SQLiteChildRunStore` child identity/transcript/checkpoint
//   store (FloePersistence) over the runtime's single database writer,
// - the session's own selected provider/model/adapter/credentials for every
//   child (a child never picks its own provider),
// - the parent runtime's canonical child dispatch (catalog, ceiling, plan /
//   catastrophic gate, approval policy and grants) for every child call.
//
// Mac-specific policy encoded here:
// - A delegated Mac project child runs under a READ-ONLY project
//   investigation ceiling, enforced two ways: an explicit allowlist of the
//   workspace investigation tool names AND the structural descriptor check
//   (`effect == .readOnly`, no host scope, not main-run-only, not
//   child-only). There is deliberately no shell, no network and no write
//   path for children; peer-collaboration tools and nested delegation stay
//   out of the Mac child universe for this stage.
// - The parent task owns the child lifecycle: one runner is bound per parent
//   run before its session can dispatch and released when that task ends.
//   Concurrent visible/background parents bind independently; selection is
//   presentation only. The runtime's five child lifecycle hooks (settle /
//   mark-delivered / is-background / interrupt-on-stop / cancel) are wired
//   per (run, conversation), so background children settle into the parent's
//   evidence before it finishes and parent stop/cancel reaches exactly its
//   own children.
// - No global handler replacement: the delegation tools are private instances
//   bound to this runtime's own registry. Nothing is written into the shared
//   `ToolCatalog`/`ToolRunnerRegistry`, so separate runtimes never overwrite
//   each other's delegation handlers.

import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeAgentRuntime

// MARK: - Read-only child tool ceiling

/// The child-facing tool surface of one Mac project task.
///
/// It exposes ONLY the intersection of:
/// 1. the explicit investigation tool-name allowlist the host supplies (the
///    actual workspace read tool names), and
/// 2. the read-only descriptors of the wrapped host executor (descriptor
///    `effect == .readOnly`, no host scope, not main-run-only, not
///    child-only).
///
/// Everything else — workspace writes, the delegation envelope itself, peer
/// tools, anything a future catalog adds — is invisible to discovery and
/// denied at the fail-closed execution path. This bounds the child's own
/// catalog; the parent runtime's canonical dispatcher still resolves every
/// child call against the parent task's effective ceiling and approval
/// policy.
public struct FloeMacChildReadOnlyToolExecutor: ToolExecutor {
    private let wrapped: any ToolExecutor
    private let exposedNames: Set<String>

    /// - Parameters:
    ///   - wrapped: The parent task's project executor (or any executor whose
    ///     read-only descriptors are the child's ceiling).
    ///   - allowedNames: Explicit investigation tool-name allowlist (for the
    ///     Mac host, `MacAgentWorkspaceTools.readToolNames`). Only names in
    ///     this set can ever reach the child.
    public init(wrapping wrapped: any ToolExecutor, allowedNames: Set<String>) {
        self.wrapped = wrapped
        self.exposedNames = Set(wrapped.allDescriptors.filter { descriptor in
            allowedNames.contains(descriptor.name) && Self.isReadOnlyInvestigation(descriptor)
        }.map(\.name))
    }

    static func isReadOnlyInvestigation(_ descriptor: ToolCatalog.Descriptor) -> Bool {
        descriptor.effect == .readOnly
            && !descriptor.requiresHostScope
            && descriptor.executionBoundary != .mainRunOnly
            && descriptor.executionBoundary != .childOnly
    }

    /// The exact names a child of this executor may see. Host-side tests pin
    /// this set against the explicit workspace read allowlist.
    public var exposedToolNames: Set<String> { exposedNames }

    public var allDescriptors: [ToolCatalog.Descriptor] {
        wrapped.allDescriptors.filter { exposedNames.contains($0.name) }
    }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        guard exposedNames.contains(name) else { return nil }
        return wrapped.descriptor(named: name)
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try await execute(call, expectedAuthorizationIdentity: nil, context: context)
    }

    public func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        guard exposedNames.contains(call.toolName),
              let descriptor = wrapped.descriptor(named: call.toolName) else {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Denied: a delegated Mac project child may only use read-only project investigation tools",
                outputDigest: ""
            )
        }
        if let expectedAuthorizationIdentity,
           descriptor.authorizationIdentity != expectedAuthorizationIdentity {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Tool authority changed after approval; review the updated tool before retrying",
                outputDigest: ""
            )
        }
        try context.cancellation.throwIfCancelled()
        return try await wrapped.execute(
            call,
            expectedAuthorizationIdentity: expectedAuthorizationIdentity,
            context: context
        )
    }
}

// MARK: - Parent session executor with per-runtime delegation

/// The parent task's session executor: the explicit Mac project tool catalog
/// plus THIS runtime's own delegation tools (`delegate`, `delegate.wait`).
///
/// The project executor stays the source of truth for project tools. The
/// delegation tools are private type-erased instances bound to the child
/// runtime's own `SubagentRunnerRegistry` — never registered into, replaced
/// in, or read from the global shared registry — so separate runtimes (and
/// separate unit tests) cannot overwrite each other's delegation handlers.
public struct FloeMacDelegatingProjectToolExecutor: ToolExecutor {
    public static let defaultDelegatingNames: Set<String> = [
        DelegateTool.name,
        DelegateWaitTool.name,
    ]

    private let project: any ToolExecutor
    private let delegatingNames: Set<String>
    private let delegateRunner: AnyAgentTool
    private let delegateWaitRunner: AnyAgentTool

    public init(
        project: any ToolExecutor,
        runners: SubagentRunnerRegistry,
        delegatingNames: Set<String> = Self.defaultDelegatingNames
    ) {
        self.project = project
        self.delegatingNames = delegatingNames
        self.delegateRunner = AnyAgentTool(DelegateTool(runners: runners))
        self.delegateWaitRunner = AnyAgentTool(DelegateWaitTool(runners: runners))
    }

    private func delegatingRunner(named name: String) -> AnyAgentTool? {
        guard delegatingNames.contains(name),
              project.descriptor(named: name) == nil else { return nil }
        switch name {
        case DelegateTool.name: return delegateRunner
        case DelegateWaitTool.name: return delegateWaitRunner
        default: return nil
        }
    }

    public var allDescriptors: [ToolCatalog.Descriptor] {
        project.allDescriptors + delegatingNames.sorted().compactMap { delegatingRunner(named: $0)?.descriptor }
    }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        if let descriptor = project.descriptor(named: name) { return descriptor }
        return delegatingRunner(named: name)?.descriptor
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try await execute(call, expectedAuthorizationIdentity: nil, context: context)
    }

    public func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        guard let tool = delegatingRunner(named: call.toolName) else {
            return try await project.execute(
                call,
                expectedAuthorizationIdentity: expectedAuthorizationIdentity,
                context: context
            )
        }
        if let expectedAuthorizationIdentity,
           tool.descriptor.authorizationIdentity != expectedAuthorizationIdentity {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Tool authority changed after approval; review the updated tool before retrying",
                outputDigest: ""
            )
        }
        do {
            try context.cancellation.throwIfCancelled()
            let output = try await tool.run(call.argumentsJSON, context)
            return ToolResult(
                callID: call.id,
                status: context.cancellation.isCancelled
                    ? .cancelled
                    : ((output.exitStatus ?? 0) == 0 ? .ok : .failed),
                outputSummary: output.summary,
                outputDigest: output.fullOutputSHA256,
                exitStatus: output.exitStatus,
                artifacts: output.artifacts,
                outputFiles: output.outputFiles,
                capturedOutput: output.capturedOutput ?? output.summary,
                capturedOutputTruncated: output.capturedOutput == nil
                    ? output.summaryTruncated
                    : output.capturedOutputTruncated,
                outcomeUnknown: output.outcomeUnknown,
                ephemeralSensitiveOutput: output.ephemeralSensitiveOutput
            )
        } catch is CancellationError {
            return ToolResult(callID: call.id, status: .cancelled,
                              outputSummary: "Cancelled", outputDigest: "")
        }
    }
}

// MARK: - Child subagent runtime

/// Runtime child-lifecycle wiring consumed by the self-core session
/// composition (`FloeMacSelfRuntime`). Every closure is scoped to one exact
/// (run, conversation) pair and fails closed to a no-op whenever that run is
/// not currently bound, so tool-free or foreign runs never observe a
/// delegation error.
public struct FloeMacChildSessionLifecycle: Sendable {
    public var settle: (@Sendable () async throws -> [BackgroundChildSnapshot])?
    public var markDelivered: (@Sendable ([UUID]) async throws -> Void)?
    public var isBackground: (@Sendable (UUID) async throws -> Bool)?
    public var markInterrupted: (@Sendable () async -> Void)?
    public var cancelAll: (@Sendable () async -> Void)?

    public init(
        settle: (@Sendable () async throws -> [BackgroundChildSnapshot])? = nil,
        markDelivered: (@Sendable ([UUID]) async throws -> Void)? = nil,
        isBackground: (@Sendable (UUID) async throws -> Bool)? = nil,
        markInterrupted: (@Sendable () async -> Void)? = nil,
        cancelAll: (@Sendable () async -> Void)? = nil
    ) {
        self.settle = settle
        self.markDelivered = markDelivered
        self.isBackground = isBackground
        self.markInterrupted = markInterrupted
        self.cancelAll = cancelAll
    }
}

/// The shared Mac child-subagent runtime. One instance per
/// `FloeMacSelfRuntime` database owner; it owns the real
/// `SubagentRunnerRegistry`, binds one `SubagentRunner` per live parent run
/// (same selected provider, durable child persistence, read-only child
/// ceiling, background delegation enabled) and releases it when that parent
/// task ends. Concurrent parents bind independently; there is no global
/// handler state.
public actor FloeMacChildSubagentRuntime {
    public nonisolated let registry: SubagentRunnerRegistry
    private let childStore: any ChildRunStoring
    private var boundRuns: Set<UUID> = Set()

    public init(
        childStore: any ChildRunStoring,
        registry: SubagentRunnerRegistry = SubagentRunnerRegistry()
    ) {
        self.childStore = childStore
        self.registry = registry
    }

    public func isBound(_ runID: UUID) -> Bool { boundRuns.contains(runID) }

    /// Bind one live parent run before its session can dispatch. The child
    /// runner receives the session's own provider/model/adapter/credentials
    /// verbatim and the read-only projection of the session's project
    /// executor, itself intersected with the explicit investigation tool-name
    /// allowlist. Durable child identity/transcript/checkpoint storage is the
    /// existing `SQLiteChildRunStore` over the runtime's single writer.
    public func bindParentRun(
        runID: UUID,
        provider: ProviderProfile,
        model: ModelProfile,
        adapter: any ProviderAdapter,
        credentials: ProviderCredentials,
        projectExecutor: any ToolExecutor,
        childToolAllowlist: Set<String>,
        onChildStateChange: (@Sendable (ChildRunSnapshot) async -> Void)? = nil
    ) async {
        let runner = SubagentRunner(
            provider: provider,
            model: model,
            adapter: adapter,
            credentials: credentials,
            executor: FloeMacChildReadOnlyToolExecutor(
                wrapping: projectExecutor,
                allowedNames: childToolAllowlist
            ),
            childRunStore: childStore,
            checkpointStore: childStore as? any ChildRunCheckpointStoring,
            onChildStateChange: onChildStateChange
        )
        await registry.register(runner, for: runID)
        await registry.enableBackground(for: runID)
        boundRuns.insert(runID)
    }

    /// Parent-owned lifecycle end for exactly one run: interrupt and join
    /// every background child of this run, then drop its runner. Children
    /// already settled durably keep their terminal rows; a still-running
    /// child becomes the resumable `.interrupted` state, never a fabricated
    /// success. Other bound runs are untouched.
    public func releaseParentRun(_ runID: UUID) async {
        guard boundRuns.contains(runID) else { return }
        boundRuns.remove(runID)
        await registry.remove(runID: runID)
    }

    /// Durable, authoritative child listing for one parent run (active and
    /// completed children alike; survives UI close and relaunch).
    public func durableChildren(parentRunID: UUID) async throws -> [ChildRunRecord] {
        try await childStore.children(parentRunID: parentRunID)
    }

    /// Durable child listing across every run of one task (history view):
    /// completed children of earlier runs remain listed after their parent
    /// released its runner.
    public func durableChildren(conversationID: UUID) async throws -> [ChildRunRecord] {
        try await childStore.children(conversationID: conversationID)
    }

    /// Live snapshot of one background child (state + structured outcome when
    /// the durable terminal row committed).
    public func backgroundSnapshot(
        runID: UUID,
        conversationID: UUID,
        childID: UUID
    ) async throws -> BackgroundChildSnapshot {
        try await registry.backgroundSnapshot(runID: runID, conversationID: conversationID, childID: childID)
    }

    /// Cancels exactly ONE background child of exactly one bound run. Every
    /// sibling — and every child of every other run — is untouched; the child
    /// settles durably as terminal `.cancelled` with a real outcome.
    public func cancelChild(
        runID: UUID,
        conversationID: UUID,
        childID: UUID
    ) async throws {
        try await registry.cancelBackgroundChild(
            runID: runID,
            conversationID: conversationID,
            childID: childID
        )
    }

    /// Settles every undelivered background child of the bound run. Used by
    /// the session composition at parent completion so background results
    /// become parent evidence before the task finishes.
    public func settle(runID: UUID, conversationID: UUID) async throws -> [BackgroundChildSnapshot] {
        try await registry.settleBackground(runID: runID, conversationID: conversationID)
    }

    /// The five child lifecycle closures the self-core session composition
    /// installs on the runtime configuration. All no-op (never throw) for a
    /// run this runtime does not own.
    public func sessionLifecycle(for runID: UUID, conversationID: UUID) -> FloeMacChildSessionLifecycle {
        FloeMacChildSessionLifecycle(
            settle: { [registry, self] in
                guard await self.isBound(runID) else { return [] }
                return try await registry.settleBackground(runID: runID, conversationID: conversationID)
            },
            markDelivered: { [registry, self] childIDs in
                guard await self.isBound(runID) else { return }
                try await registry.markBackgroundDelivered(
                    runID: runID,
                    conversationID: conversationID,
                    childIDs: childIDs
                )
            },
            isBackground: { [registry, self] childID in
                guard await self.isBound(runID) else { return false }
                return try await registry.isBackgroundChild(
                    runID: runID,
                    conversationID: conversationID,
                    childID: childID
                )
            },
            markInterrupted: { [registry, self] in
                guard await self.isBound(runID) else { return }
                await registry.markBackgroundInterrupted(runID: runID)
            },
            cancelAll: { [registry, self] in
                guard await self.isBound(runID) else { return }
                await registry.cancelBackground(runID: runID)
            }
        )
    }
}
