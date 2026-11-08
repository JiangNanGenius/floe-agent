// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels

/// Per-HTTP-response native Chat boundary. No text is promoted to a tool call.
/// Runtime still owns catalog/permission/approval and invocation admission.
struct ChatCompletionStreamBoundary: Sendable {
    private let request: ProviderStreamRequest
    private var textGuard: DeepSeekAssistantProtocolGuard
    private var aggregator = ToolCallAggregator()
    private var emittedCalls: [String: ToolCall] = [:]
    private(set) var isRejected = false

    init(request: ProviderStreamRequest) {
        self.request = request
        textGuard = .init(enabled: request.provider.traits(model: request.model).isDeepSeek)
    }

    mutating func consume(_ chunk: ChatChunk) -> [AgentEvent] {
        var safe = chunk
        var pendingError: AgentEvent?
        for index in safe.choices.indices {
            if let content = safe.choices[index].delta.content {
                let filtered = textGuard.consume(content)
                safe.choices[index].delta.content = filtered.text
                if filtered.rejected {
                    pendingError = reject(FloeL10n.isChinese ? "模型未能正确调用工具。" : "The model returned an invalid tool-call format.")
                }
            }
            if isRejected { safe.choices[index].delta.toolCalls = nil }
        }
        var result: [AgentEvent] = []
        for event in WireTranslator.translate(safe, aggregator: &aggregator) {
            switch event {
            case .toolRequest(var call):
                guard !isRejected else { continue }
                call.toolName = CompatToolNames.canonicalName(call.toolName, request: request)
                if let previous = emittedCalls[call.id] {
                    if previous != call {
                        if let error = reject(FloeL10n.isChinese ? "模型重复使用了工具调用编号，操作已停止。" : "The provider reused a tool-call identifier for a different action.") { result.append(error) }
                    }
                    // A repeated complete frame cannot create another call.
                    continue
                }
                emittedCalls[call.id] = call
                result.append(.toolRequest(call))
            case .completed:
                if let error = pendingError { result.append(error); pendingError = nil }
                result.append(event)
            case .error(let error) where error.kind == .malformedToolArguments:
                if let rejection = reject(error.providerMessage) { result.append(rejection) }
            default:
                result.append(event)
            }
        }
        if let error = pendingError { result.append(error) }
        return result
    }

    /// A partial native call or held machine prefix cannot survive a dropped
    /// JSON frame and be concatenated with unrelated later text/arguments.
    mutating func droppedChunk() -> AgentEvent? {
        guard aggregator.hasCalls || textGuard.hasHeldProtocolPrefix else { return nil }
        return reject(FloeL10n.isChinese ? "模型的工具调用未完整返回。" : "The provider returned an incomplete tool call.")
    }

    mutating func finish() -> [AgentEvent] {
        guard !isRejected else { return [] }
        let tail = textGuard.finish()
        if tail.rejected || aggregator.hasCalls {
            return reject(FloeL10n.isChinese ? "模型的工具调用未完整返回。" : "The provider returned an incomplete tool call.").map { [$0] } ?? []
        }
        return tail.text.isEmpty ? [] : [.textDelta(.init(text: tail.text))]
    }

    private mutating func reject(_ message: String) -> AgentEvent? {
        guard !isRejected else { return nil }
        isRejected = true
        aggregator.reset()
        return .error(.init(kind: .malformedToolArguments, providerMessage: message))
    }
}
