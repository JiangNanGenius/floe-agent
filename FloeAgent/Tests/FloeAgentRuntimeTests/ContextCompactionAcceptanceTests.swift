// FloeAgentRuntimeTests — deterministic context-compaction acceptance.
//
// These cases exercise the REAL runtime -> provider-request boundary with a
// scripted adapter, not a reimplementation of the planner. They cover the
// user's explicit 64K/128K requirements:
//
//  * under budget, a settled tool result reaches the next request complete
//    (including a result far above the old fixed 2 KiB replay projection);
//  * offered tool schemas are whole, parseable JSON definitions, never a
//    sliced schema;
//  * a 1 MiB captured result stays byte-exact in the trusted capture store,
//    survives a resume through a fresh store actor, and pages across UTF-8
//    scalar boundaries to recover its tail marker;
//  * over budget, the real context engine compacts with an observed record,
//    keeps the trusted contract separate from historical transcript, retains
//    the current task intent and keeps the pending tool-call/result pairing.
//
// No network, model, App, Simulator or paid request is involved. The summary
// completion is a deterministic fixture that returns a valid continuation
// record; the runtime and request assembly are the production code.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloeTestSupport

/// Optional deterministic request-observation trace. Tests remain side-effect
/// free by default; the qualification run sets FLOE_CONTEXT_TRACE_DIR to
/// export the exact counts/booleans it asserted (never credentials or model
/// calls). This is evidence, not an acceptance input.
private enum AcceptanceTrace {
    static func write(_ name: String, _ fields: [String: Any]) {
        guard let directory = ProcessInfo.processInfo.environment["FLOE_CONTEXT_TRACE_DIR"],
              !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "fields": fields
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
              ) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private final class AcceptanceSink: AgentEventSink, @unchecked Sendable {
    private struct State {
        var transitions: [String] = []
        var compactions: [ContextCompactionRecord] = []
        var compression: [ContextCompressionSnapshot] = []
    }
    private let storage = AsyncLock(State())

    var compactions: [ContextCompactionRecord] { storage.withLock { $0.compactions } }
    var compression: [ContextCompressionSnapshot] { storage.withLock { $0.compression } }

    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {
        storage.withLock { $0.transitions.append(state.name) }
    }

    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {}

    func agentRuntime(_ runtime: FloeAgentRuntime, didCompact record: ContextCompactionRecord) async {
        storage.withLock { $0.compactions.append(record) }
    }

    func agentRuntime(
        _ runtime: FloeAgentRuntime,
        didChangeContextCompression snapshot: ContextCompressionSnapshot
    ) async {
        storage.withLock { $0.compression.append(snapshot) }
    }
}

private final class SummaryRequestProbe: @unchecked Sendable {
    private let storage = AsyncLock<[ContextSummaryRequest]>([])
    var requests: [ContextSummaryRequest] { storage.withLock { $0 } }
    func record(_ request: ContextSummaryRequest) { storage.withLock { $0.append(request) } }
}

@Suite("FloeAgentRuntime.ContextCompactionAcceptance", .serialized)
struct ContextCompactionAcceptanceTests {
    // MARK: Fixtures

    private func windowModel(_ window: Int) -> ModelProfile {
        ModelProfile(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            providerID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            remoteModelID: "test-context-window",
            displayName: "Test Context Window",
            limits: ModelLimits(contextTokens: window, maxOutputTokens: 0),
            capabilities: [.text, .tools],
            isEnabled: true
        )
    }

    private func temporaryCaptureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-context-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A valid large JSON Schema. The runtime must offer the whole definition
    /// (or defer it whole), never a JSON fragment.
    private func largeSchema() -> String {
        let fields = (0..<36).map { index in
            "\"field\(index)\":{\"type\":\"string\",\"description\":\"\(String(repeating: "schema-description-\(index)-", count: 8))\"}"
        }.joined(separator: ",")
        return "{\"type\":\"object\",\"properties\":{\(fields)},\"required\":[\"field0\"],\"additionalProperties\":false}"
    }

    /// A 12 KiB valid JSON tool return with unique head, middle and tail
    /// markers. The old fixed replay projection kept only a 1280-byte head and
    /// a 640-byte tail, so the middle marker proves the complete body arrived.
    private func completeJSONPayload(bytes: Int, tag: String) throws -> String {
        let head = "{\"kind\":\"complete-tool-payload\",\"head\":\"HEAD-MARKER-\(tag)\",\"data\":\""
        let middle = "MIDDLE-MARKER-\(tag)"
        let tail = "\",\"tail\":\"TAIL-MARKER-\(tag)\"}"
        let fill = bytes - head.utf8.count - middle.utf8.count - tail.utf8.count
        #expect(fill > 64, "fixture must leave room for its markers")
        let half = fill / 2
        let payload = head
            + String(repeating: "a", count: half)
            + middle
            + String(repeating: "b", count: fill - half)
            + tail
        #expect(payload.utf8.count == bytes)
        return payload
    }

    /// A > 1 MiB UTF-8 body with CJK/emoji scalars around its paging offsets
    /// and unique head/middle/tail markers.
    private func utf8BoundaryPayload(
        bytes: Int,
        tag: String
    ) -> (body: String, tailMarker: String, tailOffset: Int) {
        let head = "HEAD-UNIQUE-MARKER-\(tag) "
        let middle = " MIDDLE-UNIQUE-MARKER-\(tag) "
        let tail = " TAIL-UNIQUE-MARKER-\(tag) "
        let unit = "资料🙂abc"
        let overhead = head.utf8.count + middle.utf8.count + tail.utf8.count + 4_096
        let repeats = max(1, (bytes - overhead) / unit.utf8.count)
        let firstHalf = repeats / 2
        var body = head
        body += String(repeating: unit, count: firstHalf)
        body += middle
        body += String(repeating: unit, count: repeats - firstHalf)
        body += tail
        let padding = bytes - body.utf8.count
        #expect(padding >= 0)
        body += String(repeating: "z", count: padding)
        #expect(body.utf8.count == bytes)
        let range = body.range(of: tail)!
        let tailOffset = body.utf8.distance(
            from: body.utf8.startIndex,
            to: range.lowerBound.samePosition(in: body.utf8)!
        )
        return (body, tail, tailOffset)
    }

    private func pagingCall(
        id: String,
        ref: String,
        offset: Int,
        length: Int
    ) throws -> ToolCall {
        let arguments = try JSONSerialization.data(
            withJSONObject: ["ref": ref, "offset": offset, "length": length],
            options: [.sortedKeys]
        )
        return try ToolCall(
            id: id,
            toolName: ToolResultPagingTool.name,
            argumentsJSON: arguments,
            scope: .local
        )
    }

    private func expectWholeSchemas(
        _ request: ProviderStreamRequest,
        expected: [String: String]
    ) throws {
        for (name, parameters) in expected {
            let schema = try #require(
                request.toolSchemas.first { $0.name == name },
                "request must offer \(name)"
            )
            #expect(
                schema.parametersJSON == parameters,
                "\(name) schema must be the complete definition"
            )
            let parsed = try JSONSerialization.jsonObject(
                with: Data(schema.parametersJSON.utf8)
            )
            #expect(parsed is [String: Any], "\(name) schema must stay whole JSON")
        }
    }

    // MARK: 64K/128K under-budget result and schemas

    private func runCompleteUnderBudgetCase(window: Int) async throws {
        let tag = UUID().uuidString
        let payload = try completeJSONPayload(bytes: 12_368, tag: tag)
        let schema = largeSchema()
        let provider = TestFixtures.localhostProvider()
        let model = windowModel(window)
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try ToolCall(
                id: "call_1",
                toolName: "test.echo",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            ))],
            [.toolRequest(try ToolCall(
                id: "call_2",
                toolName: "test.echo",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            ))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo",
            toolDescription: "Return the complete acceptance payload.",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            riskLabels: [],
            isSideEffecting: false
        )
        executor.descriptors["test.large"] = ToolCatalog.Descriptor(
            name: "test.large",
            toolDescription: "A large but complete JSON Schema.",
            parametersJSON: schema,
            riskLabels: [],
            isSideEffecting: false
        )
        executor.results = [
            ToolResult(
                callID: "call_1",
                status: .ok,
                outputSummary: payload,
                outputDigest: "digest-call-1",
                maximumSummaryCharacters: 262_144
            ),
            ToolResult(
                callID: "call_2",
                status: .ok,
                outputSummary: "second-complete-result",
                outputDigest: "digest-call-2",
                maximumSummaryCharacters: 262_144
            )
        ]
        let root = try temporaryCaptureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let sink = AcceptanceSink()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                conversationID: conversationID,
                provider: provider,
                model: model,
                allowedToolNames: ["test.echo", "test.large", ToolResultPagingTool.name],
                toolResultCaptureRoot: root
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            checkpointStore: MockCheckpointStore(),
            sink: sink
        )
        try await runtime.start(goal: "Use test.echo and test.large to verify the complete result and schema.")
        #expect(await runtime.state.name == "completed")

        let requests = adapter.requests
        #expect(requests.count == 3)
        let first = try #require(requests.first)
        try expectWholeSchemas(first, expected: [
            "test.echo": executor.descriptors["test.echo"]!.parametersJSON,
            "test.large": schema
        ])

        let second = try #require(requests.dropFirst().first)
        let pending = try #require(second.toolResults.first { $0.callID == "call_1" })
        #expect(pending.output.contains(payload))
        #expect(pending.output.contains("HEAD-MARKER-\(tag)"))
        #expect(pending.output.contains("MIDDLE-MARKER-\(tag)"))
        #expect(pending.output.contains("TAIL-MARKER-\(tag)"))
        #expect(!pending.output.contains("[tool output truncated for this request"))
        #expect(!pending.output.contains("[middle of tool output compacted]"))

        let third = try #require(requests.dropFirst(2).first)
        let replay = try #require(third.replayedToolPairs.first { $0.call.id == "call_1" })
        // The settled pair is replayed from the trusted capture store. At
        // 64K the complete 12,368-byte JSON body still fits and must appear
        // whole: no fixed 2 KiB projection, no middle omission.
        #expect(replay.result.outputSummary.contains(payload))
        #expect(replay.result.outputSummary.contains("MIDDLE-MARKER-\(tag)"))
        #expect(replay.result.outputSummary.contains("TAIL-MARKER-\(tag)"))
        #expect(!replay.result.outputSummary.contains("[middle of tool output compacted]"))
        #expect(!replay.result.outputSummary.contains("[tool output truncated for this request"))
        let replayBody = replay.result.outputSummary
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .last.map(String.init) ?? replay.result.outputSummary
        let parsed = try JSONSerialization.jsonObject(with: Data(replayBody.utf8))
        let object = try #require(parsed as? [String: Any])
        #expect(object["kind"] as? String == "complete-tool-payload")

        let secondPending = try #require(third.toolResults.first { $0.callID == "call_2" })
        #expect(secondPending.output.contains("second-complete-result"))
        #expect(third.pendingToolCalls.map(\.id) == ["call_2"])

        AcceptanceTrace.write("under-budget-\(window)", [
            "windowTokens": window,
            "requestCount": requests.count,
            "schemaNames": first.toolSchemas.map(\.name).sorted(),
            "schemaBytes": Dictionary(uniqueKeysWithValues: first.toolSchemas.map {
                ($0.name, $0.parametersJSON.utf8.count)
            }),
            "pendingResultBytes": pending.output.utf8.count,
            "pendingContainsCompletePayload": pending.output.contains(payload),
            "replayResultBytes": replay.result.outputSummary.utf8.count,
            "replayContainsMiddleMarker": replay.result.outputSummary.contains("MIDDLE-MARKER-\(tag)"),
            "replayPairing": "\(replay.call.id)==\(replay.result.callID)",
            "compactionEvents": sink.compactions.count
        ])
    }

    @Test("64K: complete settled tool result and whole schemas reach the request")
    func completeUnderBudgetResultAt64K() async throws {
        try await runCompleteUnderBudgetCase(window: 65_536)
    }

    @Test("128K: complete settled tool result and whole schemas reach the request")
    func completeUnderBudgetResultAt128K() async throws {
        try await runCompleteUnderBudgetCase(window: 131_072)
    }

    // MARK: 1 MiB capture, UTF-8 paging, resume

    @Test("128K: 1 MiB result stays byte-exact and pages its tail after resume")
    func capturedResultPagingAndResumeAt128K() async throws {
        let tag = UUID().uuidString
        let targetBytes = 1 << 20
        let fixture = utf8BoundaryPayload(bytes: targetBytes, tag: tag)
        let provider = TestFixtures.localhostProvider()
        let model = windowModel(131_072)
        let conversationID = UUID()
        let runID = UUID()
        let root = try temporaryCaptureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ref = ToolResultCaptureStore.reference(runID: runID, callID: "big_1")
        let adapter = MockAdapter()
        let paging = try pagingCall(
            id: "page_1",
            ref: ref,
            offset: max(0, fixture.tailOffset - 3),
            length: 512
        )
        let headPage = try pagingCall(
            id: "page_2",
            ref: ref,
            offset: 0,
            length: 512
        )
        adapter.script = [
            [.toolRequest(try ToolCall(
                id: "big_1",
                toolName: "test.bigCapture",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            ))],
            [.toolRequest(paging)],
            [.toolRequest(headPage)],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.bigCapture"] = ToolCatalog.Descriptor(
            name: "test.bigCapture",
            toolDescription: "Return a large retained result.",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            riskLabels: [],
            isSideEffecting: false
        )
        executor.descriptors[ToolResultPagingTool.name] = ToolResultPagingTool.descriptor
        executor.results = [
            ToolResult(
                callID: "big_1",
                status: .ok,
                outputSummary: String(fixture.body.prefix(1_200)),
                outputDigest: "digest-big-1",
                maximumSummaryCharacters: 8_192,
                capturedOutput: fixture.body
            )
        ]
        let checkpointStore = MockCheckpointStore()
        let sink = AcceptanceSink()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                conversationID: conversationID,
                provider: provider,
                model: model,
                allowedToolNames: ["test.bigCapture", ToolResultPagingTool.name],
                toolResultCaptureRoot: root
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            checkpointStore: checkpointStore,
            sink: sink,
            runID: runID
        )
        try await runtime.start(goal: "Use test.bigCapture once, then page the retained tail with tools.readResult.")
        #expect(await runtime.state.name == "completed")

        let requests = adapter.requests
        #expect(requests.count == 4)
        let afterBigResult = try #require(requests.dropFirst().first)
        let excerpt = try #require(afterBigResult.toolResults.first { $0.callID == "big_1" })
        // Over budget: an explicit head/tail excerpt with the stable ref, not
        // a silent partial body and not a fabricated complete copy.
        #expect(excerpt.output.contains("[tool output truncated for this request"))
        #expect(excerpt.output.contains("ref=\(ref)"))
        #expect(excerpt.output.contains("TAIL-UNIQUE-MARKER-\(tag)"))
        #expect(!excerpt.output.contains(fixture.body))
        #expect(afterBigResult.replayedToolPairs.isEmpty)

        let afterTailPage = try #require(requests.dropFirst(2).first)
        let tailPage = try #require(afterTailPage.toolResults.first { $0.callID == "page_1" })
        #expect(tailPage.output.contains("TAIL-UNIQUE-MARKER-\(tag)"))
        #expect(tailPage.output.contains("returnedBytes="))
        #expect(tailPage.output.contains("capture=complete"))

        let afterHeadPage = try #require(requests.dropFirst(3).first)
        let head = try #require(afterHeadPage.toolResults.first { $0.callID == "page_2" })
        #expect(head.output.contains("HEAD-UNIQUE-MARKER-\(tag)"))

        // A settled capture larger than the request excerpt is replayed as a
        // bounded pointer/excerpt with its ref, never as 1 MiB of history.
        let replay = try #require(afterHeadPage.replayedToolPairs.first { $0.call.id == "big_1" })
        #expect(replay.result.outputSummary.contains(ref))
        #expect(!replay.result.outputSummary.contains(fixture.body))

        // Byte-exact retention: a fresh actor reading the durable directory
        // (the restart path) reconstructs every byte, and a mid-scalar offset
        // is rounded to the leading byte without corrupting the page.
        let freshStore = ToolResultCaptureStore(durableRoot: root)
        var offset = 0
        var rebuilt = Data()
        while true {
            let read = await freshStore.page(
                conversationID: conversationID,
                runID: runID,
                callID: "big_1",
                offset: offset,
                maxBytes: 32_000
            )
            guard case .page(let page) = read else {
                Issue.record("byte-exact paging failed at offset \(offset): \(read)")
                return
            }
            if offset == 0 {
                #expect(page.totalBytes == targetBytes)
                #expect(page.offset == 0)
            }
            rebuilt.append(Data(page.text.utf8))
            guard let next = page.nextOffset else { break }
            #expect(next > offset)
            offset = next
        }
        #expect(rebuilt == Data(fixture.body.utf8))

        let continuationIndex = try #require(
            fixture.body.utf8.indices.dropFirst().first {
                (fixture.body.utf8[$0] & 0xC0) == 0x80
            }
        )
        let continuationOffset = fixture.body.utf8.distance(
            from: fixture.body.utf8.startIndex,
            to: continuationIndex
        )
        let boundaryRead = await freshStore.page(
            conversationID: conversationID,
            runID: runID,
            callID: "big_1",
            offset: continuationOffset,
            maxBytes: 512
        )
        guard case .page(let boundary) = boundaryRead else {
            Issue.record("mid-scalar paging must resolve to a page, got \(boundaryRead)")
            return
        }
        #expect(boundary.offset < continuationOffset)
        let utf8 = fixture.body.utf8
        let rawStart = utf8.index(utf8.startIndex, offsetBy: boundary.offset)
        let rawEnd = utf8.index(utf8.startIndex, offsetBy: boundary.endOffset)
        #expect(String(decoding: utf8[rawStart..<rawEnd], as: UTF8.self) == boundary.text)

        // The durable dispatch snapshot keeps a bounded projection plus the
        // stable ref, never a second 1 MiB copy in every checkpoint. Resume
        // rehydrates the complete evidence from the trusted store.
        let checkpoint = try #require(checkpointStore.saved.last)
        let snapshotReplay = try #require(
            checkpoint.providerDispatchRequest?.replayedToolPairs?.first { $0.call.id == "big_1" }
        )
        #expect(snapshotReplay.result.outputSummary.hasPrefix(FloeAgentRuntime.replayRecoveryMarker))
        #expect(snapshotReplay.result.outputSummary.contains("ref=\(ref)"))
        #expect(!snapshotReplay.result.outputSummary.contains(fixture.body))
        let resumeAdapter = MockAdapter()
        let resumePage = try pagingCall(
            id: "resume_page",
            ref: ref,
            offset: max(0, fixture.tailOffset - 3),
            length: 512
        )
        resumeAdapter.script = [
            [.toolRequest(resumePage)],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let resumed = FloeAgentRuntime(
            configuration: .init(
                conversationID: conversationID,
                provider: provider,
                model: model,
                allowedToolNames: ["test.bigCapture", ToolResultPagingTool.name],
                toolResultCaptureRoot: root
            ),
            adapter: resumeAdapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            checkpointStore: MockCheckpointStore(),
            runID: runID
        )
        try await resumed.resume(from: checkpoint)
        #expect(await resumed.state.name == "completed")
        let resumedRequests = resumeAdapter.requests
        #expect(resumedRequests.count == 2)
        let restoredReplay = try #require(
            resumedRequests.first?.replayedToolPairs.first { $0.call.id == "big_1" }
        )
        #expect(restoredReplay.result.outputSummary.contains(ref))
        #expect(!restoredReplay.result.outputSummary.contains(fixture.body))
        let resumedPage = try #require(
            resumedRequests.dropFirst().first?.toolResults.first { $0.callID == "resume_page" }
        )
        #expect(resumedPage.output.contains("TAIL-UNIQUE-MARKER-\(tag)"))
        let freshAfterResume = ToolResultCaptureStore(durableRoot: root)
        let finalRead = await freshAfterResume.retainedCapture(
            conversationID: conversationID,
            ref: ref
        )
        #expect(finalRead?.text == fixture.body)
        #expect(finalRead?.retentionTruncated == false)

        AcceptanceTrace.write("over-budget-1mib-131072", [
            "windowTokens": 131_072,
            "capturedBytes": targetBytes,
            "capturedRef": ref,
            "excerptBytes": excerpt.output.utf8.count,
            "excerptContainsTailMarker": excerpt.output.contains("TAIL-UNIQUE-MARKER-\(tag)"),
            "excerptContainsRef": excerpt.output.contains("ref=\(ref)"),
            "checkpointReplayMarkerBytes": snapshotReplay.result.outputSummary.utf8.count,
            "checkpointContainsFullBody": snapshotReplay.result.outputSummary.contains(fixture.body),
            "resumedReplayBytes": restoredReplay.result.outputSummary.utf8.count,
            "resumePageContainsTailMarker": resumedPage.output.contains("TAIL-UNIQUE-MARKER-\(tag)"),
            "rebuiltBytes": rebuilt.count,
            "rebuiltIsByteExact": rebuilt == Data(fixture.body.utf8),
            "midScalarRequestedOffset": continuationOffset,
            "midScalarEffectiveOffset": boundary.offset
        ])
    }

    // MARK: More than forty small settled pairs under the real window

    /// Exercises the actual runtime -> MockAdapter request boundary with 42
    /// small, unique settled tool pairs. The old dispatch view took
    /// `.suffix(40)`, so the two oldest pairs disappeared from the wire even
    /// when the complete evidence fit the 64K/128K window. This case records
    /// the original failure before the policy patch and then proves every
    /// pair, including the oldest, reaches the outgoing request whole.
    private func runManySmallPairsCase(window: Int) async throws {
        let tag = UUID().uuidString
        let pairCount = 42
        let provider = TestFixtures.localhostProvider()
        let model = windowModel(window)
        let adapter = MockAdapter()
        let executor = MockExecutor()
        let echoSchema = #"{"type":"object","properties":{"pair":{"type":"integer"},"tag":{"type":"string"}},"required":["pair","tag"],"additionalProperties":false}"#
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo",
            toolDescription: "Return a unique small evidence body.",
            parametersJSON: echoSchema,
            riskLabels: [],
            isSideEffecting: false
        )
        var script: [[AgentEvent]] = []
        var results: [ToolResult] = []
        var expectedArguments: [String: String] = [:]
        for index in 1...pairCount {
            let arguments = try JSONSerialization.data(
                withJSONObject: ["pair": index, "tag": tag],
                options: [.sortedKeys]
            )
            let call = try ToolCall(
                id: "small-\(index)",
                toolName: "test.echo",
                argumentsJSON: arguments,
                scope: .local
            )
            script.append([.toolRequest(call), .completed(.init(stopReason: .toolUse))])
            let body = "{\"pair\":\(index),\"marker\":\"PAIR-\(tag)-\(index)\",\"status\":\"ok\"}"
            results.append(ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: body,
                outputDigest: "digest-\(tag)-\(index)",
                maximumSummaryCharacters: 262_144
            ))
            expectedArguments[call.id] = String(decoding: arguments, as: UTF8.self)
        }
        script.append([.completed(.init(stopReason: .endTurn))])
        adapter.script = script
        executor.results = results
        let root = try temporaryCaptureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = AcceptanceSink()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                conversationID: UUID(),
                provider: provider,
                model: model,
                allowedToolNames: ["test.echo"],
                toolResultCaptureRoot: root
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            checkpointStore: MockCheckpointStore(),
            sink: sink
        )
        try await runtime.start(goal: "Call test.echo 42 times with distinct evidence, then report every pair.")
        #expect(await runtime.state.name == "completed")

        let requests = adapter.requests
        #expect(requests.count == pairCount + 1)
        let final = try #require(requests.last)
        // The last settled pair rides the pending channel of this request:
        // the outgoing request must carry it there and all 41 earlier settled
        // pairs through replay. The old fixed suffix(40) dropped small-1
        // entirely even though this 64K/128K request had room for it.
        #expect(final.pendingToolCalls.map(\.id) == ["small-\(pairCount)"])
        #expect(final.toolResults.map(\.callID) == ["small-\(pairCount)"])
        let replayed = final.replayedToolPairs
        #expect(
            replayed.count == pairCount - 1,
            "the real window fits every settled small pair; no fixed forty-pair dispatch count may hide the oldest"
        )
        #expect(replayed.map(\.call.id) == (1...(pairCount - 1)).map { "small-\($0)" })
        #expect(replayed.allSatisfy { $0.call.id == $0.result.callID })
        for pair in replayed {
            let indexText = pair.call.id.split(separator: "-").last.map(String.init) ?? ""
            let index = Int(indexText) ?? -1
            #expect(index >= 1 && index <= pairCount)
            #expect(
                String(decoding: pair.call.argumentsJSON, as: UTF8.self)
                    == expectedArguments[pair.call.id],
                "pair \(pair.call.id) must keep its complete argument JSON"
            )
            #expect(pair.result.outputSummary.contains("\"PAIR-\(tag)-\(index)\""))
            #expect(pair.result.outputSummary.contains("\"pair\":\(index)"))
            #expect(!pair.result.outputSummary.contains("[tool output truncated for this request"))
            #expect(!pair.result.outputSummary.contains("[middle of tool output compacted]"))
        }
        // Combined replayed + pending channels cover every settled identity,
        // including the oldest pair the fixed forty-pair dispatch view lost.
        let visibleCallIDs = Set(replayed.map(\.call.id) + final.pendingToolCalls.map(\.id))
        #expect(visibleCallIDs == Set((1...pairCount).map { "small-\($0)" }))
        let pendingItem = try #require(final.toolResults.first { $0.callID == "small-\(pairCount)" })
        #expect(pendingItem.output.contains("\"PAIR-\(tag)-\(pairCount)\""))
        #expect(!pendingItem.output.contains("[tool output truncated for this request"))
        #expect(!pendingItem.output.contains("[middle of tool output compacted]"))
        // All 42 pairs fit the ACTUAL outgoing request: the same sizer the
        // dispatch path uses reports a positive result allowance after the
        // complete replayed channel, messages, schemas and output reservation.
        let size = ProviderRequestSizer.measure(
            messages: final.contentMessages,
            schemas: final.toolSchemas,
            replayedToolPairs: replayed,
            contextWindowTokens: window,
            reservedOutputTokens: min(4_096, max(512, window / 4))
        )
        #expect(size.availableToolResultTokens > 0)
        #expect(size.replayTokens < window)
        try expectWholeSchemas(final, expected: ["test.echo": echoSchema])
        // Nothing was compacted, so no compaction notice may be fabricated.
        #expect(sink.compactions.isEmpty)
        #expect(!final.messages.contains { $0.content.contains("[Context compaction notice]") })

        AcceptanceTrace.write("small-pairs-\(window)", [
            "windowTokens": window,
            "requestCount": requests.count,
            "settledPairCount": pairCount,
            "replayedPairCount": replayed.count,
            "pendingPairCount": final.pendingToolCalls.count,
            "replayedCallIDs": replayed.map(\.call.id),
            "allPairsComplete": replayed.allSatisfy {
                !$0.result.outputSummary.contains("[tool output truncated for this request")
                    && !$0.result.outputSummary.contains("[middle of tool output compacted]")
            },
            "oldestCallVisible": replayed.contains { $0.call.id == "small-1" },
            "oldestBodyVisible": replayed.first {
                $0.call.id == "small-1"
            }?.result.outputSummary.contains("\"PAIR-\(tag)-1\"") ?? false,
            "compactionEvents": sink.compactions.count,
            "replayTokens": size.replayTokens,
            "availableToolResultTokens": size.availableToolResultTokens
        ])
    }

    @Test("64K: forty-two small settled pairs all reach the outgoing request")
    func smallPairWindowAt64K() async throws {
        try await runManySmallPairsCase(window: 65_536)
    }

    @Test("128K: forty-two small settled pairs all reach the outgoing request")
    func smallPairWindowAt128K() async throws {
        try await runManySmallPairsCase(window: 131_072)
    }

    @Test("Replay token estimate counts every retained pair, not the legacy forty")
    func replayTokenEstimateIncludesAllPairs() throws {
        let pairs = try (1...60).map { index in
            ReplayedToolPair(
                call: try TestFixtures.toolCall(
                    id: "estimate-\(index)",
                    arguments: "{\"slot\":\(index),\"pad\":\""
                        + String(repeating: "a", count: 64) + "\"}"
                ),
                result: ToolResult(
                    callID: "estimate-\(index)",
                    status: .ok,
                    outputSummary: String(repeating: "b", count: 256),
                    outputDigest: "estimate-digest-\(index)"
                )
            )
        }
        let all = FloeAgentRuntime.replayEvidenceTokenEstimate(pairs)
        let legacyForty = FloeAgentRuntime.replayEvidenceTokenEstimate(
            Array(pairs.suffix(ToolReplayPlanner.defaultMaxPairs))
        )
        #expect(all > legacyForty)
        #expect(all <= ToolReplayPlanner.defaultMaxResultBytes / 4)
    }

    // MARK: Over-budget compaction at 64K and 128K

    private func seededCheckpoint(
        window: Int,
        conversationID: UUID,
        runID: UUID
    ) throws -> (AgentCheckpoint, String, String, ToolCall, ToolResult) {
        let fact = "EARLY-REF-123e4567-e89b-12d3-a456-426614174000"
        let intent = "CURRENT-INTENT-\(UUID().uuidString): finish the acceptance and report the exact result."
        let messageCount = window <= 65_536 ? 24 : 44
        var messages: [ConversationMessage] = [
            ConversationMessage(
                role: "system",
                content: "# Floe runtime contract\nAnswer using the retained task evidence."
            )
        ]
        for index in 0..<messageCount {
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            var content = "turn-\(index): "
            if index == 2 {
                content += "Historical evidence keeps \(fact). "
            }
            content += String(
                repeating: "verification narrative \(index) ",
                count: 340
            )
            messages.append(ConversationMessage(role: role, content: content))
        }
        messages.append(ConversationMessage(role: "user", content: intent))
        let pendingCall = try ToolCall(
            id: "pending-1",
            toolName: "test.echo",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        let pendingResult = ToolResult(
            callID: "pending-1",
            status: .ok,
            outputSummary: "pending result body must survive compaction",
            outputDigest: "pending-digest",
            maximumSummaryCharacters: 8_192
        )
        let checkpoint = AgentCheckpoint(
            runID: runID,
            conversationID: conversationID,
            state: .checkpointed(AgentState.CheckpointRef(reason: "acceptance seed")),
            messages: messages,
            pendingToolCalls: [pendingCall],
            pendingToolResults: [pendingResult],
            toolLifecycleEntries: [AgentToolLifecycleEntry(
                callID: pendingCall.id,
                toolName: pendingCall.toolName,
                phase: .resultCommitted,
                updatedAt: Date()
            )]
        )
        return (checkpoint, fact, intent, pendingCall, pendingResult)
    }

    @Test("64K and 128K: real compaction retains intent, roles and pending pairing")
    func compactionRetainsIntentRolesAndPairing() async throws {
        for window in [65_536, 131_072] {
            let provider = TestFixtures.localhostProvider()
            let model = windowModel(window)
            let conversationID = UUID()
            let runID = UUID()
            let (checkpoint, fact, intent, pendingCall, pendingResult) = try seededCheckpoint(
                window: window,
                conversationID: conversationID,
                runID: runID
            )
            let probe = SummaryRequestProbe()
            let record = """
            ## Goal
            - Finish the release verification for the acceptance task.
            ## Instructions
            - Keep the historical evidence reference \(fact) exactly and do not invent identifiers.
            ## Progress
            - The earlier verification turns completed and their evidence is recorded.
            ## Remaining work
            - Complete the current request and report the exact result.
            ## Exact references
            - \(fact)
            """
            let summarizer = ModelContextSummarizer.withStructuredRequest(
                complete: { request in
                    probe.record(request)
                    return record
                },
                maximumInputCharacters: 96_000
            )
            let contextEngine = HybridContextEngine(summarizer: summarizer)
            let adapter = MockAdapter()
            adapter.script = [[.completed(.init(stopReason: .endTurn))]]
            let executor = MockExecutor()
            executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
                name: "test.echo",
                toolDescription: "Echo.",
                parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
                riskLabels: [],
                isSideEffecting: false
            )
            let sink = AcceptanceSink()
            let root = try temporaryCaptureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let runtime = FloeAgentRuntime(
                configuration: .init(
                    conversationID: conversationID,
                    provider: provider,
                    model: model,
                    allowedToolNames: ["test.echo"],
                    toolResultCaptureRoot: root
                ),
                adapter: adapter,
                policy: HumanApprovalPolicy(),
                executor: executor,
                checkpointStore: MockCheckpointStore(),
                contextEngine: contextEngine,
                sink: sink,
                runID: runID
            )
            try await runtime.resume(from: checkpoint)
            #expect(await runtime.state.name == "completed")

            let compactions = sink.compactions
            #expect(compactions.count == 1, "window \(window) must produce one observed compaction")
            let compaction = try #require(compactions.first)
            #expect(!compaction.sourceMessageIDs.isEmpty)
            #expect(compaction.beforeEstimatedTokens > compaction.afterEstimatedTokens)

            let request = try #require(adapter.requests.first)
            let compactedSystem = try #require(request.messages.first {
                $0.role == "system" && $0.content.contains("[Context compaction notice]")
            })
            #expect(compactedSystem.content.contains("Historical summary:"))
            #expect(compactedSystem.content.contains("## Goal"))
            #expect(compactedSystem.content.contains("## Instructions"))
            #expect(compactedSystem.content.contains("## Exact references"))
            #expect(compactedSystem.content.contains(fact))
            #expect(request.messages.contains { $0.role == "user" && $0.content.contains(intent) })
            // Pending tool-call/result pairing survives the rewrite unchanged.
            #expect(request.pendingToolCalls.map(\.id) == [pendingCall.id])
            #expect(request.toolResults.contains { $0.callID == pendingResult.callID && $0.output.contains("pending result body must survive compaction") })

            // The trusted contract and historical transcript are separate
            // provider messages; the transcript never becomes the system
            // instruction and the contract never contains transcript facts.
            let summaryRequests = probe.requests
            #expect(summaryRequests.count == 1)
            let summaryRequest = try #require(summaryRequests.first)
            let providerMessages = summaryRequest.providerMessages
            #expect(providerMessages.map(\.role) == ["system", "user"])
            #expect(providerMessages[0].content.contains("record the exact value here"))
            #expect(!providerMessages[0].content.contains(fact))
            #expect(providerMessages[1].content.contains("[user]"))
            #expect(providerMessages[1].content.contains(fact))
            #expect(providerMessages[1].content.contains("<transcript>"))

            AcceptanceTrace.write("compaction-\(window)", [
                "windowTokens": window,
                "compactionEvents": compactions.count,
                "beforeTokens": compaction.beforeEstimatedTokens,
                "afterTokens": compaction.afterEstimatedTokens,
                "sourceMessageCount": compaction.sourceMessageIDs.count,
                "summaryRoles": providerMessages.map(\.role),
                "systemContainsHistoricalFact": providerMessages[0].content.contains(fact),
                "transcriptContainsHistoricalFact": providerMessages[1].content.contains(fact),
                "requestHasCurrentIntent": request.messages.contains {
                    $0.role == "user" && $0.content.contains(intent)
                },
                "requestHasCompactionNotice": compactedSystem.content.contains("[Context compaction notice]"),
                "requestPendingPairing": "\(request.pendingToolCalls.first?.id ?? "")==\(request.toolResults.first?.callID ?? "")",
                "requestReplayPairs": request.replayedToolPairs.count
            ])
        }
    }
}

// MARK: - Trusted summary contract (language + instruction separation)

@Suite("FloeAgentRuntime.ContextSummaryContract", .serialized)
struct ContextSummaryContractTests {
    private func record(
        goal: String,
        instructions: String,
        progress: String,
        remaining: String,
        references: String = "r3.txt"
    ) -> String {
        """
        ## Goal
        - \(goal)
        ## Instructions
        - \(instructions)
        ## Progress
        - \(progress)
        ## Remaining work
        - \(remaining)
        ## Exact references
        - \(references)
        """
    }

    private var englishTranscript: String {
        let prose = String(
            repeating: "Please keep the release evidence and verify the archive before publishing the reviewed installer. ",
            count: 8
        )
        let reply = String(
            repeating: "The archive was verified and the evidence was retained for the next request. ",
            count: 6
        )
        return "[user] \(prose)\n[assistant] \(reply)"
    }

    private var validEnglishRecord: String {
        record(
            goal: "Ship the reviewed installer and keep the release evidence available.",
            instructions: "Retain the exact file reference r3.txt and do not change the archive.",
            progress: "The archive was verified and the checksum matched the saved record.",
            remaining: "Publish the reviewed artifact and report the final verification."
        )
    }

    @Test("Prompt targets the latest user language and forbids meta-instruction leakage")
    func promptContract() {
        let prompt = ContextSummaryContract.prompt(maximumCharacters: 12_000)
        #expect(prompt.contains("language of the most recent user message"))
        #expect(prompt.contains("instructions below are in English"))
        #expect(prompt.contains("never this summarization task"))
        #expect(prompt.contains("Do not copy or paraphrase these instructions"))
        #expect(prompt.contains("record the exact value here"))
        #expect(prompt.contains("Preserve exactly"))
        #expect(prompt.contains("## Exact references"))
        #expect(prompt.contains("within 12000 characters"))
    }

    @Test("A valid record in the transcript language is accepted")
    func acceptsMatchingLanguage() {
        #expect(ContextSummaryContract.validate(validEnglishRecord, sourceText: englishTranscript))
    }

    @Test("A clear continuation-language drift is rejected")
    func rejectsLanguageDrift() {
        let portuguese = record(
            goal: "Concluir a verificação de lançamento e manter as evidências exatas disponíveis para o usuário.",
            instructions: "Manter a referência exata r3.txt e não alterar o arquivo verificado durante a publicação.",
            progress: "O arquivo foi verificado e a soma de verificação correspondeu ao registro salvo anteriormente.",
            remaining: "Publicar o artefato revisado e relatar o resultado final da verificação ao usuário."
        )
        #expect(!ContextSummaryContract.validate(portuguese, sourceText: englishTranscript))
    }

    @Test("A record that copies the trusted instructions into Goal/Instructions is rejected")
    func rejectsInstructionLeakage() {
        let leaked = record(
            goal: "Ship the reviewed installer and keep the release evidence available.",
            instructions: "The record describes the user's work, never this summarization task. Do not copy or paraphrase these instructions into the Goal or Instructions sections, and never mention the compaction, summary, transcript, template, or these rules in any section.",
            progress: "The archive was verified and the checksum matched the saved record.",
            remaining: "Publish the reviewed artifact and report the final verification."
        )
        #expect(!ContextSummaryContract.validate(leaked, sourceText: englishTranscript))
    }

    @Test("Structural and exact-reference integrity still gate the record")
    func rejectsMalformedAndInventedReferences() {
        #expect(!ContextSummaryContract.validate("not a structured record", sourceText: englishTranscript))
        let invented = record(
            goal: "Ship the reviewed installer and keep the release evidence available.",
            instructions: "Retain the exact reference.",
            progress: "The archive was verified.",
            remaining: "Publish the artifact.",
            references: "EARLY-REF-123e4567-e89b-12d3-a456-426614174000"
        )
        #expect(!ContextSummaryContract.validate(invented, sourceText: englishTranscript))
    }

    @Test("A matching Chinese continuation record is accepted")
    func acceptsMatchingChineseLanguage() {
        let transcript = "[user] " + String(
            repeating: "请保留发布证据，并在发布之前验证归档文件的完整性，然后报告最终结果。",
            count: 8
        )
        let chinese = record(
            goal: "完成发布验证并保留所有准确的归档证据，供后续请求继续使用。",
            instructions: "保留准确的引用 r3.txt，并且在发布过程中不要修改已经验证的归档文件内容。",
            progress: "归档文件已经验证，校验和与之前保存的记录完全一致，证据仍然可用。",
            remaining: "发布已经复核的安装包，并报告最终验证结果给用户确认。"
        )
        #expect(ContextSummaryContract.validate(chinese, sourceText: transcript))
    }
}
