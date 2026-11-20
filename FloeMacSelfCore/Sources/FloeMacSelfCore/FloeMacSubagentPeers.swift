// SPDX-License-Identifier: MPL-2.0
//
// Mac sibling subagent collaboration surface — the shared iOS child-only
// `delegate.peers` / `delegate.message` tools composed onto the Mac self-core
// runtime with EXACT iPad permissions.
//
// What this file adds — and deliberately what it does not:
//
// - It reuses, unchanged, the real shared tools from FloeAgentRuntime
//   (`DelegatePeersTool`, `DelegateMessageTool`) and the real shared
//   `SubagentPeerBus` they talk through. The Mac runtime's own
//   `AgentRuntime.makeChildHandoff` already mints every delegated child's
//   `PeerCollaborationHandle` from that bus, and the shared `SubagentRunner`
//   already drains queued sibling messages at the child's safe boundary
//   (SubagentRunner.swift). Nothing here re-implements discovery, delivery,
//   identity or bounds.
// - The tools stay `.childOnly`: the main run never sees them in its catalog
//   (the runtime removes childOnly descriptors from the main-run schema set),
//   and a main-run call that hallucinates the name fails closed inside the
//   shared tool itself (`context.childExecution == nil` → validation error),
//   exactly as on iPad.
// - No global registration: instances are private `AnyAgentTool` wrappers,
//   mirroring `FloeMacDelegatingProjectToolExecutor`. Nothing is written into
//   the shared `ToolCatalog`/`ToolRunnerRegistry`, so separate runtimes never
//   overwrite each other's handlers and the Mac keeps its registry private.
// - A message never grants authority, never restarts an ended child and is
//   surfaced to the receiver as untrusted data. The bus enforces the same
//   root task for sender and receiver, bounded mailboxes, idempotent resends
//   and a bounded audit trail — those guarantees are upstream and untouched.
//
// A child can never delegate further: nested delegation stays structurally
// denied (`.mainRunOnly` boundary), and no new spawn authority is introduced.
// Where iPad lets a child ask its parent for a sibling, the Mac keeps the
// same parent-mediated route — an ordinary structured child result the parent
// reads, then a parent-initiated `delegate` call under the usual approval.

import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeAgentRuntime

/// The Mac sibling-collaboration surface for one runtime composition.
public enum FloeMacSubagentPeerSupport {
    /// The exact shared child-only collaboration tool names. These are the
    /// only names this surface exposes; everything else fails closed.
    public static let toolNames: Set<String> = [
        DelegatePeersTool.name,
        DelegateMessageTool.name,
    ]

    /// Whether a session admits the peer tools into its RUNTIME ceiling. This
    /// mirrors the shared runtime's frozen-catalog rule: childOnly names join
    /// the run's catalog identity only for ordinary task access — never for
    /// plan, chat-fast or temporary read-only surfaces. The main run still
    /// never sees them: the runtime removes childOnly descriptors from the
    /// main-run schema set, and the composition keeps them out of the
    /// model-visible capability list (on iPad that filter derives from the
    /// shared registry; the Mac registry is private, so the composition
    /// subtracts them itself — see `FloeMacSelfRuntime.startSession`).
    public static func admitsPeerTools(
        runtimeToolsEnabled: Bool,
        conversationMode: ConversationMode,
        chatFastMode: Bool,
        temporaryReadOnly: Bool
    ) -> Bool {
        runtimeToolsEnabled
            && conversationMode != .plan
            && !chatFastMode
            && !temporaryReadOnly
    }
}

/// Executes exactly the two shared child-only sibling collaboration tools.
///
/// The runner instances are private and stateless; the tools read the child's
/// runtime-issued `PeerCollaborationHandle` from the tool context, so this
/// executor grants no capability by itself — without a canonical child
/// handoff on the context both tools fail closed, exactly like iPad.
public struct FloeMacSubagentPeerExecutor: ToolExecutor {
    private let peersRunner: AnyAgentTool
    private let messageRunner: AnyAgentTool

    public init() {
        self.peersRunner = AnyAgentTool(DelegatePeersTool())
        self.messageRunner = AnyAgentTool(DelegateMessageTool())
    }

    public var allDescriptors: [ToolCatalog.Descriptor] {
        [peersRunner.descriptor, messageRunner.descriptor]
            .sorted { $0.name < $1.name }
    }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        runner(named: name)?.descriptor
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try await execute(call, expectedAuthorizationIdentity: nil, context: context)
    }

    public func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        guard let runner = runner(named: call.toolName) else {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Denied: a delegated Mac child may only use the sibling collaboration tools this surface exposes",
                outputDigest: ""
            )
        }
        if let expectedAuthorizationIdentity,
           runner.descriptor.authorizationIdentity != expectedAuthorizationIdentity {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Tool authority changed after approval; review the updated tool before retrying",
                outputDigest: ""
            )
        }
        do {
            try context.cancellation.throwIfCancelled()
            let output = try await runner.execute(
                argumentsJSON: call.argumentsJSON,
                context: context
            )
            // Mirror the iPad CatalogToolExecutor result mapping: the shared
            // DelegateMessageTool surfaces a rejected send as exitStatus 1 so
            // the child sees a non-success receipt carrying the reason.
            return ToolResult(
                callID: call.id,
                status: context.cancellation.isCancelled
                    ? .cancelled
                    : (output.requiresUserAction ? .needsUser : ((output.exitStatus ?? 0) == 0 ? .ok : .failed)),
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
        } catch let error as ToolExecutionOutcomeUnknownError {
            let summary = "status=outcomeUnknown reference=\(error.reference)\n\(SecretRedactor.redact(error.message))\nReconnect and inspect the existing operation. Do not submit it again."
            return ToolResult(
                callID: call.id,
                status: context.cancellation.isCancelled ? .cancelled : .needsUser,
                outputSummary: summary,
                outputDigest: FloeDigest.sha256Hex(Data(summary.utf8)),
                outcomeUnknown: true
            )
        } catch let error as FloeError where error == .cancelled {
            return ToolResult(callID: call.id, status: .cancelled, outputSummary: "Cancelled", outputDigest: "")
        } catch is CancellationError {
            return ToolResult(callID: call.id, status: .cancelled, outputSummary: "Cancelled", outputDigest: "")
        } catch {
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "Execution error: \(error.localizedDescription)",
                outputDigest: ""
            )
        }
    }

    private func runner(named name: String) -> AnyAgentTool? {
        switch name {
        case DelegatePeersTool.name: return peersRunner
        case DelegateMessageTool.name: return messageRunner
        default: return nil
        }
    }
}

/// Adds the sibling collaboration surface to an existing executor.
///
/// The wrapped executor stays the source of truth: any name it claims —
/// including, defensively, a colliding `delegate.peers`/`delegate.message` —
/// resolves and executes against the base. Only names the base does not
/// claim fall through to the peer surface, and everything else fails closed.
/// This is the single integration point for both Mac surfaces:
///
/// - Parent surface: wrap the delegating project executor so the runtime's
///   canonical child dispatch can resolve the peer descriptors and route
///   their execution (`executor.descriptor(named:)` in
///   `AgentRuntime.dispatchChildTool`).
/// - Child surface: wrap the read-only child ceiling so the subagent runner
///   offers the peer tools to delegated children.
public struct FloeMacPeerAwareToolExecutor: ToolExecutor {
    private let base: any ToolExecutor
    private let peers: FloeMacSubagentPeerExecutor

    public init(wrapping base: any ToolExecutor, peers: FloeMacSubagentPeerExecutor = FloeMacSubagentPeerExecutor()) {
        self.base = base
        self.peers = peers
    }

    /// The exact names added on top of the base surface.
    public var peerToolNames: Set<String> { FloeMacSubagentPeerSupport.toolNames }

    public var allDescriptors: [ToolCatalog.Descriptor] {
        var descriptors = base.allDescriptors
        let claimed = Set(descriptors.map(\.name))
        descriptors.append(contentsOf: peers.allDescriptors.filter { !claimed.contains($0.name) })
        return descriptors.sorted { $0.name < $1.name }
    }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        base.descriptor(named: name) ?? peers.descriptor(named: name)
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try await execute(call, expectedAuthorizationIdentity: nil, context: context)
    }

    public func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        if base.descriptor(named: call.toolName) != nil {
            return try await base.execute(
                call,
                expectedAuthorizationIdentity: expectedAuthorizationIdentity,
                context: context
            )
        }
        guard FloeMacSubagentPeerSupport.toolNames.contains(call.toolName) else {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Denied: '\(call.toolName)' is not part of this Mac task's tool surface",
                outputDigest: ""
            )
        }
        return try await peers.execute(
            call,
            expectedAuthorizationIdentity: expectedAuthorizationIdentity,
            context: context
        )
    }
}
