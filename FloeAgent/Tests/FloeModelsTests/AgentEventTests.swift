// FloeModelsTests — ToolCall limits and AgentEvent Codable round-trips.

import Foundation
import Testing
@testable import FloeModels
@testable import FloeCore
import FloeTestSupport

@Suite("FloeModels.ToolCall")
struct ToolCallTests {

    @Test("Arguments at exactly 64 KiB are accepted")
    func maxArgumentsAccepted() throws {
        let payload = String(repeating: "a", count: toolArgumentsMaxBytes - 8)
        let args = Data(#"{"x":"\#(payload)"}"#.utf8)
        let call = try ToolCall(id: "c1", toolName: "t", argumentsJSON: args, scope: .local)
        #expect(call.argumentsJSON.count == toolArgumentsMaxBytes)
    }

    @Test("Invalid JSON and non-object arguments are rejected")
    func invalidArgumentsRejected() {
        for args in [Data("not-json".utf8), Data("[]".utf8), Data("null".utf8)] {
            #expect(throws: FloeError.self) {
                _ = try ToolCall(id: "c1", toolName: "t", argumentsJSON: args, scope: .local)
            }
        }
    }

    @Test("Arguments above 64 KiB are rejected")
    func oversizedArgumentsRejected() {
        let args = Data(repeating: UInt8(ascii: "a"), count: toolArgumentsMaxBytes + 1)
        #expect(throws: FloeError.self) {
            _ = try ToolCall(id: "c1", toolName: "t", argumentsJSON: args, scope: .local)
        }
    }

    @Test("Idempotency key is stable for runID + callID")
    func idempotencyDeterministic() throws {
        let runID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let call = try TestFixtures.toolCall()
        let a = call.withIDContext(runID: runID)
        let b = call.withIDContext(runID: runID)
        #expect(a.idempotencyKey == b.idempotencyKey)
        #expect(a.idempotencyKey.count == 64) // SHA256 hex
        let other = call.withIDContext(runID: UUID())
        #expect(other.idempotencyKey != a.idempotencyKey)
    }

    @Test("ToolScope Codable round-trip for all cases")
    func toolScopeRoundTrip() throws {
        let hostID = UUID()
        let scopes: [ToolScope] = [.local, .host(hostID), .hostPath(hostID: hostID, path: "/var/log")]
        for scope in scopes {
            let data = try JSONEncoder().encode(scope)
            let decoded = try JSONDecoder().decode(ToolScope.self, from: data)
            #expect(decoded == scope)
        }
    }

    @Test("ToolResult summary truncates to 4 KiB")
    func resultSummaryTruncated() {
        let long = String(repeating: "x", count: 10_000)
        let result = ToolResult(callID: "c", status: .ok, outputSummary: long, outputDigest: "")
        #expect(result.outputSummary.count == 4096)
    }

    @Test("Tool artifact references round-trip and old results default to none")
    func toolArtifactRoundTrip() throws {
        let artifact = ToolArtifactReference(
            id: UUID(), relativePath: "BrowserArtifacts/view.jpg",
            mimeType: "image/jpeg", byteCount: 123, sha256: "abc"
        )
        let result = ToolResult(
            callID: "shot", status: .ok, outputSummary: "viewport",
            outputDigest: "abc", artifacts: [artifact],
            provenance: ToolResultProvenance(
                sourceID: "trusted-source", toolName: "browser.observe",
                runID: UUID(), taskID: UUID(),
                resourceBindings: [.init(name: "browser.tabID", value: UUID().uuidString)]
            )
        )
        let decoded = try JSONDecoder().decode(
            ToolResult.self, from: JSONEncoder().encode(result)
        )
        #expect(decoded == result)

        let legacy = #"{"callID":"old","status":"ok","outputSummary":"ok","outputDigest":""}"#
        let legacyResult = try JSONDecoder().decode(ToolResult.self, from: Data(legacy.utf8))
        #expect(legacyResult.artifacts.isEmpty)
        #expect(legacyResult.provenance == nil)
    }
}

@Suite("FloeModels.AgentEvent")
struct AgentEventTests {

    static var allCases: [AgentEvent] {
        [
            .textDelta(AgentEvent.TextDelta(text: "hello", blockID: "0")),
            .textDelta(AgentEvent.TextDelta(text: "no-block")),
            .reasoningSummary(AgentEvent.ReasoningSummary(text: "thinking")),
            .toolRequest(try! TestFixtures.toolCall()),
            .toolResult(ToolResult(callID: "c1", status: .ok, outputSummary: "done", outputDigest: "ab", exitStatus: 0)),
            .usage(AgentEvent.UsageReport(inputTokens: 10, outputTokens: 20, costEstimate: Decimal(string: "0.001"))),
            .error(AgentEvent.NormalizedError(kind: .rateLimited, providerMessage: "slow down", httpStatus: 429)),
            .error(AgentEvent.NormalizedError(kind: .cancelled, providerMessage: "user")),
            .completed(AgentEvent.CompletionInfo(stopReason: .endTurn)),
            .completed(AgentEvent.CompletionInfo(stopReason: .toolUse)),
            .completed(AgentEvent.CompletionInfo(stopReason: .maxTokens)),
            .completed(AgentEvent.CompletionInfo(stopReason: .stopSequence)),
            .completed(AgentEvent.CompletionInfo(stopReason: .cancelled))
        ]
    }

    @Test("AgentEvent Codable round-trip", arguments: allCases)
    func roundTrip(event: AgentEvent) throws {
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test("NormalizedError.Kind Codable round-trip", arguments: [
        AgentEvent.NormalizedError.Kind.rateLimited, .auth, .contextOverflow,
        .network, .malformed, .server, .cancelled
    ])
    func errorKindRoundTrip(kind: AgentEvent.NormalizedError.Kind) throws {
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(AgentEvent.NormalizedError.Kind.self, from: data)
        #expect(decoded == kind)
    }
}
