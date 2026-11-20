// SPDX-License-Identifier: MPL-2.0
//
// MacConversationTools — unified Mac host adapter for the self-core
// conversation capability (conversation.list / .search / .read / .spawn /
// .message).
//
// This file is intentionally thin: the executable tools, spawn policy and
// coordination semantics all live in the shared FloeAgentRuntime and
// FloeMacSelfCore composition; the host only needs a scoped ToolExecutor
// over `capability.tools` so it can compose the capability into a session
// binding exactly like the workspace file capability.
//
// Integration contract for the binding owner (MacAgentWorkspaceTools):
// - Plan/read-only sessions: union `FloeMacConversationTools.readToolNames`
//   into the allowed set (these pass the existing plan ceiling).
// - Agent/Goal sessions: union `FloeMacConversationTools.allToolNames`.
// - Chat sessions: no conversation tools (iPad parity).
// - Wrap or chain the executors; never register these into
//   `ToolRunnerRegistry.shared` — every instance is bound to one runtime's
//   database and live-session map.

import Foundation
import FloeAgentRuntime
import FloeCore
import FloeModels
import FloeTools
import FloeMacSelfCore

/// Scoped, private executor over one runtime's conversation capability.
/// Mirrors the dispatch/result shaping of the workspace executor so tool
/// outcomes stream through the same runtime boundaries.
public struct MacConversationToolExecutor: ToolExecutor {
    private let runnersByName: [String: AnyAgentTool]

    public init(capability: FloeMacConversationToolCapability) {
        self.runnersByName = Dictionary(
            uniqueKeysWithValues: capability.tools.map { ($0.descriptor.name, $0) }
        )
    }

    public var allDescriptors: [ToolCatalog.Descriptor] {
        runnersByName.values.map(\.descriptor).sorted { $0.name < $1.name }
    }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        runnersByName[name]?.descriptor
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        guard let runner = runnersByName[call.toolName] else {
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "No runner registered for tool '\(call.toolName)'",
                outputDigest: ""
            )
        }
        do {
            let output = try await runner.execute(argumentsJSON: call.argumentsJSON, context: context)
            let status: ToolResult.Status = context.cancellation.isCancelled
                ? .cancelled
                : ((output.exitStatus ?? 0) == 0 ? .ok : .failed)
            // The conversation tools bound their envelopes at
            // ConversationEnvelope.maximumEnvelopeCharacters; keep a generous
            // summary cap so quoted pages survive the tool-result boundary.
            return ToolResult(
                callID: call.id,
                status: status,
                outputSummary: output.summary,
                outputDigest: output.fullOutputSHA256,
                exitStatus: output.exitStatus,
                artifacts: output.artifacts,
                outputFiles: output.outputFiles,
                maximumSummaryCharacters: 196_608,
                capturedOutput: output.capturedOutput ?? output.summary,
                capturedOutputTruncated: output.capturedOutput == nil
                    ? output.summaryTruncated : output.capturedOutputTruncated,
                outcomeUnknown: output.outcomeUnknown,
                ephemeralSensitiveOutput: output.ephemeralSensitiveOutput
            )
        } catch is CancellationError {
            return ToolResult(callID: call.id, status: .cancelled,
                              outputSummary: "Cancelled", outputDigest: "")
        } catch {
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "Execution error: \(error.localizedDescription)",
                outputDigest: ""
            )
        }
    }
}

/// Host entry points for the conversation capability.
public enum MacConversationTools {
    /// Names safe to advertise per session mode (see file header).
    public static let readToolNames = FloeMacConversationTools.readToolNames
    public static let stateToolNames = FloeMacConversationTools.stateToolNames
    public static let allToolNames = FloeMacConversationTools.allToolNames

    /// The runtime-bound capability (one per runtime/database).
    public static func capability(
        runtime: FloeMacSelfRuntime
    ) async throws -> FloeMacConversationToolCapability {
        try await runtime.conversationToolCapability()
    }

    public static func executor(
        capability: FloeMacConversationToolCapability
    ) -> MacConversationToolExecutor {
        MacConversationToolExecutor(capability: capability)
    }
}
