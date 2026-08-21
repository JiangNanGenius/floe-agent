// FloeProviders — Pure translation from wire DTOs to AgentEvent.
// See blazing-aurora-darwin.md §8 mapping table. These functions are
// deterministic and side-effect free; adapters own stateful aggregation
// (chat tool-call fragments, Anthropic tool_use input accumulation).

import Foundation
import FloeCore
import FloeModels

/// Maps provider wire events onto the unified `AgentEvent` stream.
public enum WireTranslator {

    /// Creates a `ToolCall` from wire-level parts, enforcing the 64 KiB
    /// argument cap. Malformed or rejected arguments surface as
    /// `.error(.malformed)` instead of a tool request.
    private static func makeToolCall(id: String, name: String, argumentsJSON: String) -> AgentEvent {
        // Anthropic sends zero input_json deltas for `{}` arguments;
        // normalize empty payloads to an empty object.
        let normalized = argumentsJSON.isEmpty ? "{}" : argumentsJSON
        let data = Data(normalized.utf8)
        do {
            let call = try ToolCall(
                id: id,
                toolName: name,
                argumentsJSON: data,
                scope: inferredScope(from: data)
            )
            return .toolRequest(call)
        } catch {
            return .error(AgentEvent.NormalizedError(
                kind: .malformed,
                providerMessage: "Tool call rejected: \(error.localizedDescription)"
            ))
        }
    }

    /// Scope is derived from the same validated argument object that the
    /// executor receives. This prevents a remote call from being approved as
    /// a local action merely because provider wire formats have no scope field.
    private static func inferredScope(from data: Data) -> ToolScope {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .local
        }
        let hostKeys = ["hostID", "hostId", "host_id"]
        let hostID = hostKeys
            .compactMap { object[$0] as? String }
            .compactMap(UUID.init(uuidString:))
            .first
        guard let hostID else { return .local }
        let pathKeys = ["path", "remotePath", "remote_path"]
        if let path = pathKeys.compactMap({ object[$0] as? String }).first, !path.isEmpty {
            return .hostPath(hostID: hostID, path: path)
        }
        return .host(hostID)
    }

    static func normalizeStopReason(_ wireReason: String?) -> AgentEvent.StopReason {
        switch wireReason {
        case "stop", "end_turn":
            return .endTurn
        case "tool_calls", "tool_use":
            return .toolUse
        case "length", "max_tokens":
            return .maxTokens
        case "stop_sequence", "content_filter":
            return .stopSequence
        default:
            return .endTurn
        }
    }

    // MARK: - OpenAI Responses

    public static func translate(_ event: OpenAIResponsesStreamEvent) -> [AgentEvent] {
        switch event {
        case .outputTextDelta(let delta):
            return [.textDelta(AgentEvent.TextDelta(text: delta))]
        case .reasoningSummaryTextDelta(let delta):
            return [.reasoningSummary(AgentEvent.ReasoningSummary(text: delta))]
        case .outputItemDoneFunctionCall(let item):
            return [makeToolCall(id: item.callID, name: item.name, argumentsJSON: item.arguments)]
        case .completed(let usage):
            var events: [AgentEvent] = []
            if let usage {
                events.append(.usage(AgentEvent.UsageReport(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    cacheReadTokens: usage.inputTokenDetails?.cachedTokens,
                    reasoningTokens: usage.outputTokenDetails?.reasoningTokens
                )))
            }
            events.append(.completed(AgentEvent.CompletionInfo(stopReason: .endTurn)))
            return events
        case .incomplete:
            return [.completed(AgentEvent.CompletionInfo(stopReason: .maxTokens))]
        case .failed(let message):
            return [.error(AgentEvent.NormalizedError(
                kind: .server,
                providerMessage: message ?? "response.failed"
            ))]
        case .error(let message, let code):
            return [.error(AgentEvent.NormalizedError(
                kind: code == "rate_limit_exceeded" ? .rateLimited : .server,
                providerMessage: message ?? code ?? "unknown error"
            ))]
        case .unknown(let type):
            FloeLogger(category: .providers).debug("Ignoring unknown Responses event: \(type)")
            return []
        }
    }

    // MARK: - OpenAI Chat Completions

    /// Translates one chat chunk. Tool-call fragments are accumulated in
    /// `aggregator`; complete calls are emitted when the finish reason
    /// `tool_calls` arrives.
    public static func translate(
        _ chunk: ChatChunk,
        aggregator: inout ToolCallAggregator
    ) -> [AgentEvent] {
        var events: [AgentEvent] = []

        for choice in chunk.choices {
            if let content = choice.delta.content, !content.isEmpty {
                events.append(.textDelta(AgentEvent.TextDelta(text: content)))
            }
            if let reasoning = choice.delta.reasoningContent, !reasoning.isEmpty {
                events.append(.reasoningSummary(AgentEvent.ReasoningSummary(text: reasoning)))
            }
            for toolDelta in choice.delta.toolCalls ?? [] {
                aggregator.consume(toolDelta)
            }
            if let finishReason = choice.finishReason {
                if finishReason == "tool_calls" {
                    for call in aggregator.aggregatedCalls() {
                        events.append(makeToolCall(
                            id: call.id,
                            name: call.name,
                            argumentsJSON: call.argumentsJSON
                        ))
                    }
                    aggregator.reset()
                }
                events.append(.completed(AgentEvent.CompletionInfo(
                    stopReason: normalizeStopReason(finishReason)
                )))
            }
        }

        if let usage = chunk.usage {
            events.append(.usage(AgentEvent.UsageReport(
                inputTokens: usage.promptTokens,
                outputTokens: usage.completionTokens,
                cacheReadTokens: usage.promptTokenDetails?.cachedTokens,
                reasoningTokens: usage.completionTokenDetails?.reasoningTokens
            )))
        }

        return events
    }

    // MARK: - Anthropic Messages

    /// Stateful aggregator for Anthropic tool_use blocks, whose `input`
    /// JSON arrives as `input_json_delta` fragments between
    /// `content_block_start` and `content_block_stop`.
    public struct AnthropicAggregator: Sendable {
        private struct PartialBlock: Sendable {
            var toolID: String = ""
            var toolName: String = ""
            var inputJSON: String = ""
        }

        private var blocks: [Int: PartialBlock] = [:]

        public init() {}

        public mutating func startBlock(index: Int, toolID: String?, toolName: String?) {
            var block = PartialBlock()
            block.toolID = toolID ?? ""
            block.toolName = toolName ?? ""
            blocks[index] = block
        }

        public mutating func appendInputJSON(index: Int, fragment: String) {
            blocks[index]?.inputJSON += fragment
        }

        /// Finalizes the block at `index`; nil when it was not a tool_use.
        public mutating func finishBlock(index: Int) -> (id: String, name: String, inputJSON: String)? {
            guard let block = blocks.removeValue(forKey: index), !block.toolName.isEmpty else {
                return nil
            }
            return (block.toolID, block.toolName, block.inputJSON)
        }

        public mutating func reset() {
            blocks.removeAll(keepingCapacity: true)
        }
    }

    public static func translate(
        _ event: AnthropicStreamEvent,
        aggregator: inout AnthropicAggregator
    ) -> [AgentEvent] {
        switch event {
        case .messageStart:
            return []
        case .contentBlockStart(let index, let blockType, let toolID, let toolName):
            if blockType == "tool_use" {
                aggregator.startBlock(index: index, toolID: toolID, toolName: toolName)
            }
            return []
        case .textDelta(let index, let text):
            return [.textDelta(AgentEvent.TextDelta(text: text, blockID: String(index)))]
        case .thinkingDelta(_, let thinking):
            return [.reasoningSummary(AgentEvent.ReasoningSummary(text: thinking))]
        case .inputJSONDelta(let index, let partialJSON):
            aggregator.appendInputJSON(index: index, fragment: partialJSON)
            return []
        case .contentBlockStop(let index):
            if let call = aggregator.finishBlock(index: index) {
                return [makeToolCall(id: call.id, name: call.name, argumentsJSON: call.inputJSON)]
            }
            return []
        case .messageDelta(let stopReason, let usage):
            var events: [AgentEvent] = []
            if let usage {
                events.append(.usage(AgentEvent.UsageReport(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    cacheReadTokens: usage.cacheReadInputTokens,
                    cacheWriteTokens: usage.cacheCreationInputTokens
                )))
            }
            if let stopReason {
                events.append(.completed(AgentEvent.CompletionInfo(
                    stopReason: normalizeStopReason(stopReason)
                )))
            }
            return events
        case .messageStop:
            return []
        case .ping:
            return []
        case .error(let type, let message):
            let kind: AgentEvent.NormalizedError.Kind
            switch type {
            case "rate_limit_error": kind = .rateLimited
            case "authentication_error", "permission_error": kind = .auth
            case "invalid_request_error": kind = .malformed
            case "overloaded_error", "api_error": kind = .server
            default: kind = .server
            }
            return [.error(AgentEvent.NormalizedError(kind: kind, providerMessage: message))]
        case .unknown(let type):
            FloeLogger(category: .providers).debug("Ignoring unknown Anthropic event: \(type)")
            return []
        }
    }

    // MARK: - HTTP status normalization

    /// Maps a non-2xx HTTP status onto a normalized error event.
    /// Auth failures (401/403) surface the provider's original message so the
    /// user sees "api key invalid" instead of a bare HTTP status.
    public static func httpError(status: Int, body: String) -> AgentEvent {
        let kind: AgentEvent.NormalizedError.Kind
        switch status {
        case 401, 403:
            kind = .auth
        case 429:
            kind = .rateLimited
        case 400, 404, 422:
            kind = .malformed
        default:
            kind = status >= 500 ? .server : .malformed
        }
        let rawBody = String(body.prefix(512))
        // For auth failures, surface the provider's message directly (e.g.
        // "Authentication Fails, Your api key: ****xxxx is invalid") so the
        // user knows to regenerate the key. Redact only actual key material.
        let message: String
        if status == 401 || status == 403 {
            message = rawBody.isEmpty ? "API key 无效或已过期" : rawBody
        } else {
            message = SecretRedactor.redact(rawBody)
        }
        return .error(AgentEvent.NormalizedError(
            kind: kind,
            providerMessage: message.isEmpty ? "HTTP \(status)" : message,
            httpStatus: status
        ))
    }
}
