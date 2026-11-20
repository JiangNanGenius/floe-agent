// SPDX-License-Identifier: MPL-2.0
//
// FloeMacSelfQuestionToolExecutor — routes exactly one catalog name,
// `user.ask`, to the existing coordinator-backed `UserAskTool`, and delegates
// every other call to the host executor unchanged.
//
// The wrapper adds `UserAskTool.descriptor` to the visible catalog so the
// runtime can offer the schema, and it never invents a permission decision:
// the task-epoch/stop fence (`FloeMacSelfFencedToolExecutor`) and the
// runtime's own dispatch checks still run because this wrapper sits INSIDE
// the fence — the fence sees the question descriptor and its allowed-name
// set carries `user.ask` only when the runtime installed this wrapper.

import Foundation
import FloeModels
import FloeTools
import FloeAgentRuntime

struct FloeMacSelfQuestionToolExecutor: ToolExecutor {
    private let wrapped: any ToolExecutor
    private let questionTool: AnyAgentTool

    init(wrapping wrapped: any ToolExecutor, coordinator: UserQuestionCoordinator) {
        self.wrapped = wrapped
        self.questionTool = AnyAgentTool(UserAskTool(coordinator: coordinator))
    }

    var allDescriptors: [ToolCatalog.Descriptor] {
        var descriptors = wrapped.allDescriptors
        if !descriptors.contains(where: { $0.name == questionTool.descriptor.name }) {
            descriptors.append(questionTool.descriptor)
            descriptors.sort { $0.name < $1.name }
        }
        return descriptors
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        if name == questionTool.descriptor.name { return questionTool.descriptor }
        return wrapped.descriptor(named: name)
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try await execute(call, expectedAuthorizationIdentity: nil, context: context)
    }

    func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        guard call.toolName == questionTool.descriptor.name else {
            return try await wrapped.execute(
                call,
                expectedAuthorizationIdentity: expectedAuthorizationIdentity,
                context: context
            )
        }
        if let expectedAuthorizationIdentity,
           questionTool.descriptor.authorizationIdentity != expectedAuthorizationIdentity {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Tool authority changed after approval; review the updated tool before retrying",
                outputDigest: ""
            )
        }
        try context.cancellation.throwIfCancelled()
        let output = try await questionTool.execute(argumentsJSON: call.argumentsJSON, context: context)
        // Same bounded-receipt contract CatalogToolExecutor uses for
        // `user.ask`: the JSON receipt must survive checkpoints intact.
        return ToolResult(
            callID: call.id,
            status: context.cancellation.isCancelled ? .cancelled : .ok,
            outputSummary: output.summary,
            outputDigest: output.fullOutputSHA256,
            maximumSummaryCharacters: 262_144
        )
    }
}
