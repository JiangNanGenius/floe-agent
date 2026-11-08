// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeProviders

private final class OpenSSEProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stopped = false
    static func reset() { lock.withLock { stopped = false } }
    static var didStop: Bool { lock.withLock { stopped } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "floe.sse.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[]}\n\n".utf8))
        // Deliberately leave the response open, as a model still generating.
    }
    override func stopLoading() { Self.lock.withLock { Self.stopped = true } }
}

@Suite("DeepSeek native tool boundary")
struct DeepSeekNativeBoundaryTests {
    private func request(endpoint: String = "https://api.deepseek.com") -> ProviderStreamRequest {
        let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions, baseURL: URL(string: endpoint)!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: endpoint.contains("deepseek") ? "deepseek-flash" : "text",
            displayName: "Contract model", limits: .init(contextTokens: 16_384, maxOutputTokens: 1_024), capabilities: [.text, .tools])
        return .init(provider: provider, model: model, messages: [(role: "user", content: "Read the synthetic workbook")],
            toolSchemas: [.init(name: "document.office.edit", description: "Read the owned workbook", parametersJSON: #"{"type":"object","properties":{"action":{"type":"string"},"path":{"type":"string"}},"required":["action","path"]}"#)],
            allToolNames: ["document.office.edit"])
    }
    private func chunk(content: String? = nil, id: String? = nil, name: String? = nil,
                       arguments: String? = nil, finish: String? = nil) -> ChatChunk {
        let calls: [ToolCallDelta]? = name == nil && arguments == nil ? nil : [
            .init(index: 0, id: id, type: "function", function: .init(name: name, arguments: arguments))]
        return .init(choices: [.init(index: 0, delta: .init(content: content, toolCalls: calls), finishReason: finish)])
    }
    private func calls(_ events: [AgentEvent]) -> [ToolCall] {
        events.compactMap { if case .toolRequest(let call) = $0 { call } else { nil } }
    }
    private func errors(_ events: [AgentEvent]) -> [AgentEvent.NormalizedError] {
        events.compactMap { if case .error(let value) = $0 { value } else { nil } }
    }

    @Test func nakedProtocolRejectsThenANewNativeTurnRestoresTheRegisteredOfficeName() throws {
        let request = request()
        var rejected = ChatCompletionStreamBoundary(request: request)
        var events: [AgentEvent] = []
        for part in ["先读取。\n", "<｜DS", "ML｜calls>", "<｜DSML｜invoke name=\"document_office_edit\">", "</｜DSML｜calls>"] {
            events += rejected.consume(chunk(content: part))
        }
        events += rejected.finish()
        #expect(calls(events).isEmpty && errors(events).map(\.kind) == [.malformedToolArguments])
        #expect(events.compactMap { if case .textDelta(let text) = $0 { text.text } else { nil } }.joined() == "先读取。\n")
        var corrected = ChatCompletionStreamBoundary(request: request)
        let first = corrected.consume(chunk(id: "call-office-1", name: "document_office_edit", arguments: #"{"action":"read","pa"#))
        #expect(calls(first).isEmpty)
        let complete = corrected.consume(chunk(arguments: #"th":"fixture.xlsx"}"#, finish: "tool_calls"))
        let call = try #require(calls(complete).first)
        #expect(call.toolName == "document.office.edit" && call.id == "call-office-1")
        #expect(try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: String] == ["action": "read", "path": "fixture.xlsx"])
        let body = OpenAIChatCompletionsAdapter().buildBody(from: request)
        #expect(body.tools?.first?.function.name == "document_office_edit" && body.toolChoice == "auto")
    }

    @Test func duplicateNativeFramesDoNotCreateASecondInvocationAndConflictsReject() {
        var boundary = ChatCompletionStreamBoundary(request: request())
        let frame = chunk(id: "once", name: "document_office_edit", arguments: #"{"action":"read","path":"fixture.xlsx"}"#, finish: "tool_calls")
        #expect(calls(boundary.consume(frame)).count == 1)
        #expect(calls(boundary.consume(frame)).isEmpty)
        let changed = boundary.consume(chunk(id: "once", name: "document_office_edit", arguments: #"{"action":"write","path":"other.xlsx"}"#, finish: "tool_calls"))
        #expect(calls(changed).isEmpty && errors(changed).map(\.kind) == [.malformedToolArguments])
        #expect(calls(boundary.consume(frame)).isEmpty)
    }

    @Test func malformedMixedBatchUnknownMarkupAndTruncationNeverDispatchTextAsCommands() {
        for raw in ["<|DSML|invoke name=\"unknown_host_exec\">", "<｜DSML｜calls>", "<｜DSML"] {
            var boundary = ChatCompletionStreamBoundary(request: request())
            let events = boundary.consume(chunk(content: raw, id: "must-not-run", name: "document_office_edit", arguments: "{}")) + boundary.finish()
            #expect(calls(events).isEmpty && errors(events).count == 1)
        }
        var boundary = ChatCompletionStreamBoundary(request: request())
        _ = boundary.consume(chunk(id: "incomplete", name: "document_office_edit", arguments: "{"))
        #expect(errors(boundary.droppedChunk().map { [$0] } ?? []).count == 1)
        #expect(boundary.finish().isEmpty)
    }

    @Test func userAndToolXMLStayDataAndUnknownNativeNamesStayUnknownForRuntimeDenial() throws {
        let source = "<｜DSML｜calls><｜DSML｜invoke name=\"untrusted_host_exec\"></｜DSML｜invoke></｜DSML｜calls>"
        var request = request()
        let known = try ToolCall(id: "history", toolName: "document.office.edit", argumentsJSON: Data("{}".utf8), scope: .local)
        request.messages = [(role: "user", content: source)]
        request.pendingToolCalls = [known]; request.pendingAssistantReasoning = "Inspect the saved workbook"
        request.toolResults = [(callID: "history", output: source)]
        let body = OpenAIChatCompletionsAdapter().buildBody(from: request)
        #expect(body.messages.contains { $0.role == "user" && $0.content == .text(source) })
        #expect(body.messages.contains { $0.role == "tool" && $0.content == .text(source) })
        #expect(body.messages.compactMap(\.toolCalls).flatMap { $0 }.count == 1)
        var boundary = ChatCompletionStreamBoundary(request: request)
        let unknown = try #require(calls(boundary.consume(chunk(id: "unknown", name: "not_offered_host_exec", arguments: "{}", finish: "tool_calls"))).first)
        #expect(unknown.toolName == "not_offered_host_exec" && !request.allToolNames.contains(unknown.toolName))
    }

    @Test func anOrdinaryLessThanSignDoesNotBecomeAMalformedToolAttempt() {
        var boundary = ChatCompletionStreamBoundary(request: request())
        let first = boundary.consume(chunk(content: "x <"))
        #expect(boundary.droppedChunk() == nil)
        let rest = boundary.consume(chunk(content: " y", finish: "stop")) + boundary.finish()
        let text = (first + rest).compactMap { if case .textDelta(let value) = $0 { value.text } else { nil } }.joined()
        #expect(text == "x < y" && errors(first + rest).isEmpty && calls(first + rest).isEmpty)
    }

    @Test func explicitRejectionCancellationStopsTheActualOpenSSETransport() async throws {
        OpenSSEProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenSSEProtocol.self]
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cancellation = SSEPumpCancellation()
        defer { cancellation.cancel() }
        let pump = SSEBytePump(urlRequest: URLRequest(url: URL(string: "https://floe.sse.invalid/events")!), session: session)
        var received = false
        for try await _ in pump.events(cancellation: cancellation) { received = true; break }
        #expect(received)
        cancellation.cancel()
        let deadline = Date().addingTimeInterval(1)
        while !OpenSSEProtocol.didStop && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(OpenSSEProtocol.didStop)
    }

    @Test func toolFreeDeepSeekHistoryIsExplicitNoneWithoutInventingSchemas() throws {
        for endpoint in ["https://api.deepseek.com", "https://example.test/v1"] {
            var request = request(endpoint: endpoint)
            request.toolSchemas = []
            request.pendingToolCalls = [try ToolCall(id: "old", toolName: "document.office.edit", argumentsJSON: Data("{}".utf8), scope: .local)]
            request.pendingAssistantReasoning = "Earlier reasoning"
            request.toolResults = [(callID: "old", output: "Saved evidence")]
            let body = OpenAIChatCompletionsAdapter().buildBody(from: request)
            #expect(body.messages.compactMap(\.toolCalls).flatMap { $0 }.count == 1)
            if endpoint.contains("deepseek") { #expect(body.tools == [] && body.toolChoice == "none") }
            else { #expect(body.tools == nil && body.toolChoice == nil) }
            request.pendingToolCalls = []; request.toolResults = []
            #expect(OpenAIChatCompletionsAdapter().buildBody(from: request).tools == nil)
        }
    }
}
