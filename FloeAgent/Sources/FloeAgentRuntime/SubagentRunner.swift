// FloeAgentRuntime — focused subagent runner.
//
// A Supervisor-Worker primitive: the parent run delegates one subtask to a
// subagent that gets a clean context and returns a concise summary. The child
// is always read-only and inherits the parent's tool and workspace ceilings.

import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools

/// One delegated subtask.
public struct SubagentRequest: Sendable, Hashable {
    public var task: String
    public var context: String?
    public var maxIterations: Int
    public var runID: UUID

    public init(
        task: String,
        context: String? = nil,
        maxIterations: Int = 6,
        runID: UUID
    ) {
        self.task = task
        self.context = context
        self.maxIterations = maxIterations
        self.runID = runID
    }
}

/// Runs a bounded subagent loop and returns its final text.
public actor SubagentRunner {
    private let provider: ProviderProfile
    private let model: ModelProfile
    private let adapter: any ProviderAdapter
    private let credentials: ProviderCredentials
    private let executor: any ToolExecutor

    public init(
        provider: ProviderProfile,
        model: ModelProfile,
        adapter: any ProviderAdapter,
        credentials: ProviderCredentials,
        executor: any ToolExecutor
    ) {
        self.provider = provider
        self.model = model
        self.adapter = adapter
        self.credentials = credentials
        self.executor = executor
    }

    public func run(
        _ request: SubagentRequest,
        context: ToolContext
    ) async throws -> String {
        guard let childBudget = context.childBudget else {
            throw FloeError.validationFailed("Subagent budget is unavailable")
        }
        do {
            let summary = try await runLoop(
                request, context: context, childBudget: childBudget
            )
            await childBudget.finish()
            return summary
        } catch {
            await childBudget.finish()
            throw error
        }
    }

    /// The wrapper above owns exact-once child-slot release; this helper owns
    /// only the bounded provider/tool loop.
    private func runLoop(
        _ request: SubagentRequest,
        context: ToolContext,
        childBudget: ChildBudgetContext
    ) async throws -> String {
        let iterationCeiling = min(request.maxIterations, childBudget.maximumIterations)

        var messages: [(role: String, content: String)] = [
            (role: "system", content: Self.systemPrompt(context: request.context)),
            (role: "user", content: request.task)
        ]
        let schemas = Self.schemas(allowedToolNames: context.allowedToolNames)
        var pendingToolCalls: [ToolCall] = []
        var pendingToolResults: [(callID: String, output: String)] = []

        for _ in 0..<max(1, min(iterationCeiling, 20)) {
            if context.cancellation.isCancelled { throw FloeError.cancelled }
            if await !childBudget.reserve() {
                return "Subagent iteration budget exhausted; summarizing available findings."
            }
            let streamRequest = ProviderStreamRequest(
                provider: provider,
                model: model,
                messages: messages,
                toolResults: pendingToolResults,
                pendingToolCalls: pendingToolCalls,
                toolSchemas: schemas
            )
            pendingToolResults = []
            pendingToolCalls = []

            var text = ""
            var calls: [ToolCall] = []
            for try await event in adapter.stream(request: streamRequest, credentials: credentials) {
                switch event {
                case .textDelta(let delta):
                    guard text.utf8.count + delta.text.utf8.count <= 64 * 1024 else {
                        throw FloeError.validationFailed("Subagent response exceeds 64 KiB")
                    }
                    text += delta.text
                case .toolRequest(let call):
                    guard calls.count < 16 else {
                        throw FloeError.validationFailed("Subagent requested too many tools in one turn")
                    }
                    calls.append(call)
                case .error(let error):
                    throw FloeError.internalError("Subagent stream failed: \(error.providerMessage)")
                default:
                    break
                }
            }

            if !calls.isEmpty {
                if !text.isEmpty {
                    messages.append((role: "assistant", content: text))
                }
                pendingToolCalls = calls
                pendingToolResults = await executeInParallel(
                    calls, request: request, parentContext: context
                )
                continue
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Subagent reached its iteration limit without a final answer."
    }

    // MARK: - Execution

    private func executeInParallel(
        _ calls: [ToolCall],
        request: SubagentRequest,
        parentContext: ToolContext
    ) async -> [(callID: String, output: String)] {
        let executor = self.executor
        let runID = request.runID
        let token = parentContext.cancellation
        let collected = await withTaskGroup(
            of: (String, ToolResult).self,
            returning: [(String, ToolResult)].self
        ) { group in
            for call in calls {
                group.addTask {
                    let result: ToolResult
                    do {
                        guard let descriptor = executor.descriptor(named: call.toolName),
                              descriptor.effect == .readOnly,
                              !descriptor.requiresHostScope,
                              call.toolName != DelegateTool.name,
                              parentContext.allowedToolNames?.contains(call.toolName) ?? true else {
                            return (call.id, ToolResult(
                                callID: call.id, status: .denied,
                                outputSummary: "Denied: tool is outside the read-only child ceiling",
                                outputDigest: ""
                            ))
                        }
                        result = try await executor.execute(call, context: ToolContext(
                            runID: runID,
                            scope: call.scope,
                            activeSkillIDs: parentContext.activeSkillIDs,
                            allowedToolNames: parentContext.allowedToolNames,
                            workspaceRootURL: parentContext.workspaceRootURL,
                            allowedWorkspacePaths: parentContext.allowedWorkspacePaths,
                            cancellation: token
                        ))
                    } catch {
                        result = ToolResult(
                            callID: call.id,
                            status: .failed,
                            outputSummary: error.localizedDescription,
                            outputDigest: ""
                        )
                    }
                    return (call.id, result)
                }
            }
            var items: [(String, ToolResult)] = []
            for await item in group { items.append(item) }
            return items
        }
        return collected.map { (callID: $0.0, output: $0.1.outputSummary) }
    }

    // MARK: - Schema / prompt

    private static func schemas(allowedToolNames: Set<String>?) -> [ToolSchemaDescriptor] {
        ToolCatalog.allDescriptors
            .filter {
                $0.effect == .readOnly
                    && $0.name != DelegateTool.name
                    && !$0.requiresHostScope
                    && (allowedToolNames?.contains($0.name) ?? true)
            }
            .map {
                ToolSchemaDescriptor(
                    name: $0.name,
                    description: $0.toolDescription,
                    parametersJSON: $0.parametersJSON
                )
            }
    }

    private static func systemPrompt(context: String?) -> String {
        var base = "You are a focused subagent delegated one subtask. Work independently and return a concise, self-contained summary of your findings or result."
        base += " You may use only the read-only tools supplied to you. Never modify state, execute code, control a GUI, or delegate another agent."
        if let context, !context.isEmpty {
            base += "\nContext: \(context)"
        }
        return base
    }
}
