// FloeProvidersTests — SSE parser fragmentation corpus and wire mapping.

import Foundation
import Testing
@testable import FloeProviders
@testable import FloeModels
@testable import FloeCore
import FloeTestSupport

// MARK: - Fragmentation corpus

/// Byte-level fragmentation scenarios. Each case splits the same logical
/// stream differently; the parser must produce identical events for all.
enum SSEFragmentationCorpus: CaseIterable, Sendable {
    case wholeBuffer
    case byteByByte
    case splitMidUTF8
    case splitBetweenCRLF
    case loneCRLineEndings
    case mixedLineEndings
    case leadingBOM
    case commentAndFields
    case multiLineData
    case noTrailingBlankLine

    /// Logical stream used by most cases.
    static let baseStream = "data: 你好世界\n\ndata: second\nevent: named\n\n"

    func chunks() -> [String] {
        switch self {
        case .wholeBuffer:
            return [Self.baseStream]
        case .byteByByte:
            // Fed byte-by-byte at the UTF-8 level in parse().
            return [Self.baseStream]
        case .splitMidUTF8:
            // Fed as raw bytes split inside the 3-byte "你" in parse().
            return ["data: 你好\n\n"]
        case .splitBetweenCRLF:
            return ["data: a\r", "\n\r\n", "data: b\r\n\r\n"]
        case .loneCRLineEndings:
            return ["data: one\r\rdata: two\r\r"]
        case .mixedLineEndings:
            return ["data: m1\ndata: m1b\r\n\r\ndata: m2\r\r\n"]
        case .leadingBOM:
            return ["\u{FEFF}data: bom\n\n"]
        case .commentAndFields:
            return [": heartbeat\nid: 42\nretry: 3000\ndata: payload\n\n"]
        case .multiLineData:
            return ["data: line1\ndata: line2\ndata: line3\n\n"]
        case .noTrailingBlankLine:
            return ["data: unfinished"]
        }
    }

    /// Feed chunks (or raw bytes for the mid-UTF8 case) through a parser.
    func parse() throws -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        switch self {
        case .splitMidUTF8:
            // True byte-level split inside the 3-byte "你" (E4 BD A0 at
            // offsets 6-8).
            let full = Array("data: 你好\n\n".utf8)
            let head = Array(full[0..<8])
            let tail = Array(full[8...])
            events += parser.feed(head)
            events += parser.feed(tail)
        case .byteByByte:
            for byte in Array(Self.baseStream.utf8) {
                events += parser.feed(CollectionOfOne(byte))
            }
        default:
            for chunk in chunks() {
                events += parser.feed(Array(chunk.utf8))
            }
        }
        events += try parser.finish()
        return events
    }
}

@Suite("FloeProviders.SSE")
struct SSEParserTests {

    @Test("Fragmentation scenarios produce expected events", arguments: SSEFragmentationCorpus.allCases)
    func fragmentation(scenario: SSEFragmentationCorpus) throws {
        let events = try scenario.parse()
        switch scenario {
        case .wholeBuffer, .byteByByte:
            #expect(events.count == 2)
            #expect(events[0].data == "你好世界")
            #expect(events[1].data == "second")
            #expect(events[1].event == "named")
        case .splitMidUTF8:
            #expect(events.count == 1)
            #expect(events[0].data == "你好")
        case .splitBetweenCRLF:
            #expect(events.map(\.data) == ["a", "b"])
        case .loneCRLineEndings:
            #expect(events.map(\.data) == ["one", "two"])
        case .mixedLineEndings:
            #expect(events.map(\.data) == ["m1\nm1b", "m2"])
        case .leadingBOM:
            #expect(events.map(\.data) == ["bom"])
        case .commentAndFields:
            #expect(events.count == 1)
            #expect(events[0].data == "payload")
            #expect(events[0].id == "42")
            #expect(events[0].retry == 3000)
        case .multiLineData:
            #expect(events.count == 1)
            #expect(events[0].data == "line1\nline2\nline3")
        case .noTrailingBlankLine:
            #expect(events.count == 1)
            #expect(events[0].data == "unfinished")
        }
    }

    @Test("finish() throws on truncated UTF-8 tail")
    func truncatedUTF8Throws() {
        var parser = SSEParser()
        _ = parser.feed(Array("data: ".utf8) + [0xE4, 0xBD]) // incomplete 你
        #expect(throws: SSEParserError.self) {
            _ = try parser.finish()
        }
    }

    @Test("Field without colon has empty value")
    func fieldOnlyLine() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("data\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "")
    }

    @Test("Unknown fields are ignored")
    func unknownFieldsIgnored() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("futureField: xyz\ndata: kept\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "kept")
    }

    @Test("Data with leading double space keeps one")
    func dataSpaceStripping() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("data:  two-spaces\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == " two-spaces")
    }

    @Test("An oversized line becomes one bounded provider error event")
    func oversizedLineIsBounded() throws {
        var parser = SSEParser()
        let oversized = Array(("data: " + String(repeating: "x", count: 1_048_641) + "\n\n").utf8)
        var events = parser.feed(oversized)
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].event == "__floe_sse_error__")
        #expect(events[0].data.contains("limit"))
    }
}

// MARK: - Wire translation

@Suite("FloeProviders.WireTranslator")
struct WireTranslatorTests {

    @Test("Responses output_text.delta → textDelta")
    func responsesTextDelta() {
        let events = WireTranslator.translate(ResponsesStreamEvent.outputTextDelta(delta: "hi"))
        #expect(events == [.textDelta(AgentEvent.TextDelta(text: "hi"))])
    }

    @Test("Responses reasoning delta → reasoningSummary")
    func responsesReasoning() {
        let events = WireTranslator.translate(ResponsesStreamEvent.reasoningSummaryTextDelta(delta: "hmm"))
        #expect(events == [.reasoningSummary(AgentEvent.ReasoningSummary(text: "hmm"))])
    }

    @Test("Responses function_call done → toolRequest")
    func responsesToolCall() {
        let item = FunctionCallItem(callID: "call_9", name: "test.echo", arguments: #"{"text":"x"}"#)
        let events = WireTranslator.translate(ResponsesStreamEvent.outputItemDoneFunctionCall(item))
        guard case .toolRequest(let call) = events.first else {
            Issue.record("Expected toolRequest, got \(events)")
            return
        }
        #expect(call.id == "call_9")
        #expect(call.toolName == "test.echo")
    }

    @Test("Responses completed emits usage + completed")
    func responsesCompleted() {
        let events = WireTranslator.translate(ResponsesStreamEvent.completed(
            usage: ResponsesStreamEvent.Usage(inputTokens: 5, outputTokens: 7)
        ))
        #expect(events.count == 2)
        guard case .usage(let report) = events[0] else {
            Issue.record("Expected usage first"); return
        }
        #expect(report.inputTokens == 5 && report.outputTokens == 7)
        guard case .completed = events[1] else {
            Issue.record("Expected completed second"); return
        }
    }

    @Test("Provider-specific cache and reasoning usage stays distinguishable")
    func detailedUsageDimensions() throws {
        let responsesData = Data(#"{"type":"response.completed","response":{"usage":{"input_tokens":120,"output_tokens":30,"input_tokens_details":{"cached_tokens":80},"output_tokens_details":{"reasoning_tokens":12}}}}"#.utf8)
        let responses = try JSONDecoder().decode(ResponsesStreamEvent.self, from: responsesData)
        let responseEvents = WireTranslator.translate(responses)
        guard case .usage(let responseUsage) = responseEvents.first else {
            Issue.record("Expected Responses usage"); return
        }
        #expect(responseUsage.cacheReadTokens == 80)
        #expect(responseUsage.inputTokens == 40)
        #expect(responseUsage.cacheWriteTokens == nil)
        #expect(responseUsage.reasoningTokens == 12)

        let chatData = Data(#"{"choices":[],"usage":{"prompt_tokens":90,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":50},"completion_tokens_details":{"reasoning_tokens":7}}}"#.utf8)
        let chat = try JSONDecoder().decode(ChatChunk.self, from: chatData)
        var chatAggregator = ToolCallAggregator()
        let chatEvents = WireTranslator.translate(chat, aggregator: &chatAggregator)
        guard case .usage(let chatUsage) = chatEvents.first else {
            Issue.record("Expected Chat usage"); return
        }
        #expect(chatUsage.cacheReadTokens == 50)
        #expect(chatUsage.inputTokens == 40)
        #expect(chatUsage.reasoningTokens == 7)

        let deepSeekData = Data(#"{"choices":[],"usage":{"prompt_tokens":90,"completion_tokens":20,"prompt_cache_hit_tokens":60,"prompt_cache_miss_tokens":30,"completion_tokens_details":{"reasoning_tokens":7}}}"#.utf8)
        let deepSeek = try JSONDecoder().decode(ChatChunk.self, from: deepSeekData)
        var deepSeekAggregator = ToolCallAggregator()
        let deepSeekEvents = WireTranslator.translate(deepSeek, aggregator: &deepSeekAggregator)
        guard case .usage(let deepSeekUsage) = deepSeekEvents.first else {
            Issue.record("Expected DeepSeek usage"); return
        }
        #expect(deepSeekUsage.inputTokens == 30)
        #expect(deepSeekUsage.cacheReadTokens == 60)
        #expect(deepSeekUsage.reasoningTokens == 7)

        let anthropicData = Data(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":70,"output_tokens":15,"cache_creation_input_tokens":9,"cache_read_input_tokens":40}}"#.utf8)
        let anthropic = try JSONDecoder().decode(AnthropicStreamEvent.self, from: anthropicData)
        var anthropicAggregator = WireTranslator.AnthropicAggregator()
        let anthropicEvents = WireTranslator.translate(anthropic, aggregator: &anthropicAggregator)
        guard case .usage(let anthropicUsage) = anthropicEvents.first else {
            Issue.record("Expected Anthropic usage"); return
        }
        #expect(anthropicUsage.cacheReadTokens == 40)
        #expect(anthropicUsage.cacheWriteTokens == 9)
        #expect(anthropicUsage.reasoningTokens == nil)
    }

    @Test("Unknown Responses event types are ignored")
    func responsesUnknownIgnored() {
        let events = WireTranslator.translate(ResponsesStreamEvent.unknown(type: "response.future_thing"))
        #expect(events.isEmpty)
    }

    @Test("Chat chunk text + finish_reason mapping")
    func chatChunkMapping() {
        var aggregator = ToolCallAggregator()
        let chunk = ChatChunk(
            choices: [ChatChunk.Choice(
                index: 0,
                delta: .init(content: "hello"),
                finishReason: "stop"
            )]
        )
        let events = WireTranslator.translate(chunk, aggregator: &aggregator)
        #expect(events.contains(.textDelta(AgentEvent.TextDelta(text: "hello"))))
        #expect(events.contains(.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))))
    }

    @Test("Chat tool_calls deltas aggregate by index then emit on finish")
    func chatToolCallAggregation() {
        var aggregator = ToolCallAggregator()
        let deltas: [ChatChunk] = [
            ChatChunk(choices: [.init(index: 0, delta: .init(toolCalls: [
                ToolCallDelta(index: 0, id: "call_1", function: .init(name: "test.echo", arguments: #"{"te"#))
            ]))]),
            ChatChunk(choices: [.init(index: 0, delta: .init(toolCalls: [
                ToolCallDelta(index: 0, function: .init(arguments: #"xt":"hi"}"#))
            ]))]),
            ChatChunk(choices: [.init(index: 0, delta: .init(), finishReason: "tool_calls")])
        ]
        var events: [AgentEvent] = []
        for chunk in deltas {
            events += WireTranslator.translate(chunk, aggregator: &aggregator)
        }
        let toolRequests = events.compactMap { event -> ToolCall? in
            if case .toolRequest(let call) = event { return call }
            return nil
        }
        #expect(toolRequests.count == 1)
        #expect(toolRequests[0].id == "call_1")
        #expect(String(decoding: toolRequests[0].argumentsJSON, as: UTF8.self) == #"{"text":"hi"}"#)
        #expect(events.contains(.completed(AgentEvent.CompletionInfo(stopReason: .toolUse))))
    }

    @Test("Anthropic tool_use aggregates input_json_delta across block")
    func anthropicToolUseAggregation() {
        var aggregator = WireTranslator.AnthropicAggregator()
        var events: [AgentEvent] = []
        events += WireTranslator.translate(
            .contentBlockStart(index: 1, blockType: "tool_use", toolID: "toolu_1", toolName: "test.echo"),
            aggregator: &aggregator
        )
        events += WireTranslator.translate(
            .inputJSONDelta(index: 1, partialJSON: #"{"text":""#),
            aggregator: &aggregator
        )
        events += WireTranslator.translate(
            .inputJSONDelta(index: 1, partialJSON: #"abc"}"#),
            aggregator: &aggregator
        )
        events += WireTranslator.translate(.contentBlockStop(index: 1), aggregator: &aggregator)
        let toolRequests = events.compactMap { event -> ToolCall? in
            if case .toolRequest(let call) = event { return call }
            return nil
        }
        #expect(toolRequests.count == 1)
        #expect(toolRequests[0].toolName == "test.echo")
        #expect(String(decoding: toolRequests[0].argumentsJSON, as: UTF8.self) == #"{"text":"abc"}"#)
    }

    @Test("Anthropic text/thinking deltas map to text/reasoning")
    func anthropicDeltas() {
        var aggregator = WireTranslator.AnthropicAggregator()
        let textEvents = WireTranslator.translate(.textDelta(index: 0, text: "hi"), aggregator: &aggregator)
        #expect(textEvents == [.textDelta(AgentEvent.TextDelta(text: "hi", blockID: "0"))])
        let thinkEvents = WireTranslator.translate(.thinkingDelta(index: 0, thinking: "t"), aggregator: &aggregator)
        #expect(thinkEvents == [.reasoningSummary(AgentEvent.ReasoningSummary(text: "t"))])
    }

    @Test("Anthropic rate_limit_error → .rateLimited")
    func anthropicRateLimit() {
        var aggregator = WireTranslator.AnthropicAggregator()
        let events = WireTranslator.translate(
            .error(type: "rate_limit_error", message: "too many"),
            aggregator: &aggregator
        )
        guard case .error(let error) = events.first else {
            Issue.record("Expected error event"); return
        }
        #expect(error.kind == .rateLimited)
    }

    @Test("HTTP 429 maps to .rateLimited with status preserved")
    func http429() {
        let event = WireTranslator.httpError(status: 429, body: "quota exceeded")
        guard case .error(let error) = event else {
            Issue.record("Expected error event"); return
        }
        #expect(error.kind == .rateLimited)
        #expect(error.httpStatus == 429)
    }

    @Test("HTTP 5xx maps to .server, 401 to .auth")
    func httpStatusMapping() {
        guard case .error(let serverError) = WireTranslator.httpError(status: 503, body: "") else {
            Issue.record("Expected error"); return
        }
        #expect(serverError.kind == .server)
        guard case .error(let authError) = WireTranslator.httpError(status: 401, body: "") else {
            Issue.record("Expected error"); return
        }
        #expect(authError.kind == .auth)
    }

    @Test("Wire DTOs decode from real JSON payloads")
    func wireDecoding() throws {
        let responsesJSON = #"{"type":"response.output_text.delta","delta":"abc"}"#
        let decoded = try JSONDecoder().decode(ResponsesStreamEvent.self, from: Data(responsesJSON.utf8))
        #expect(decoded == .outputTextDelta(delta: "abc"))

        let anthropicJSON = #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"xy"}}"#
        let anthropic = try JSONDecoder().decode(AnthropicStreamEvent.self, from: Data(anthropicJSON.utf8))
        #expect(anthropic == .textDelta(index: 2, text: "xy"))

        let chatJSON = #"{"choices":[{"index":0,"delta":{"content":"z"},"finish_reason":null}]}"#
        let chat = try JSONDecoder().decode(ChatChunk.self, from: Data(chatJSON.utf8))
        #expect(chat.choices.first?.delta.content == "z")
    }

    @Test("Stream cancellation terminates iteration promptly")
    func streamCancellation() async {
        let stream = AsyncThrowingStream<AgentEvent, Error> { continuation in
            continuation.yield(.textDelta(AgentEvent.TextDelta(text: "a")))
            // Never finishes — simulates a hung connection.
        }
        let task = Task {
            var count = 0
            for try await _ in stream { count += 1 }
            return count
        }
        task.cancel()
        _ = await task.result
        // No hang: reaching this line proves termination.
        #expect(true)
    }
}
