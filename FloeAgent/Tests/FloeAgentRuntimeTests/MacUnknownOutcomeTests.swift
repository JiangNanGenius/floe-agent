import Foundation
import Testing
@testable import FloeAgentRuntime
import FloeCore
import FloeModels
import FloeTestSupport

@Suite("Mac transport mutation receipts")
struct MacUnknownOutcomeTests {
    @Test("An unknown submitted mutation remains non-replayable after checkpoint encoding")
    func unknownReceiptSurvivesCheckpoint() throws {
        let call = try TestFixtures.toolCall(id: "mac-submit", toolName: "exec.shell",
                                            arguments: #"{"command":"make install"}"#)
        let original = ToolResult(callID: call.id, status: .needsUser,
                                  outputSummary: "Reconnect to inspect the existing Mac job.",
                                  outputDigest: "", outcomeUnknown: true)
        let restored = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(original))
        #expect(restored.outcomeUnknown)
        #expect(restored == original)
        var ledger = HarnessExecutionLedger()
        ledger.record(call: call, result: restored, isSideEffecting: true,
                      outcomeUnknown: restored.outcomeUnknown, outcomeUnknownReason: .unattributed)
        #expect(ledger.suppressedUnknownOutcomeResult(for: call, isSideEffecting: true) != nil)
    }

    @Test("Old result records retain their existing meaning")
    func legacyReceipt() throws {
        let data = Data(#"{"callID":"old","status":"ok","outputSummary":"done","outputDigest":"digest"}"#.utf8)
        let result = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(!result.outcomeUnknown)
        let encoded = try JSONEncoder().encode(result)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("outcomeUnknown"))
    }
}
