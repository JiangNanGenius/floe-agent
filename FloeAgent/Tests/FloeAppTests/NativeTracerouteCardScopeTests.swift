// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeTools
@testable import FloeApp

@Suite("Native traceroute card owner identity")
struct NativeTracerouteCardScopeTests {
    @Test func onlyTheExactConversationRunAndCallCanReadTheRows() throws {
        let conversation = UUID(), run = UUID(), request = UUID()
        let hop = try #require(TaskDiagnosticProgress(requestID: request, status: .intermediate,
            ttl: 1, address: "192.0.2.1", milliseconds: [1]))
        let scope = NativeToolDiagnosticViewScope(conversationID: conversation, runID: run,
            observations: ["same-provider-call": [hop]])
        #expect(scope.values(conversationID: conversation, runID: run, callID: "same-provider-call") == [hop])
        #expect(scope.values(conversationID: UUID(), runID: run, callID: "same-provider-call").isEmpty)
        #expect(scope.values(conversationID: conversation, runID: UUID(), callID: "same-provider-call").isEmpty)
        #expect(scope.values(conversationID: nil, runID: run, callID: "same-provider-call").isEmpty)
        #expect(scope.values(conversationID: conversation, runID: run, callID: "another-call").isEmpty)
        #expect(scope.values(conversationID: conversation, runID: run, callID: nil).isEmpty)
    }

    @Test func decodedNativeObservationKeepsTheSameBounds() throws {
        let value = try #require(TaskDiagnosticProgress(requestID: UUID(), status: .timeout, ttl: 2))
        #expect(try JSONDecoder().decode(TaskDiagnosticProgress.self, from: JSONEncoder().encode(value)) == value)
        let bad = Data("{\"requestID\":\"\(UUID().uuidString)\",\"status\":\"timeout\",\"ttl\":999,\"milliseconds\":[]}".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TaskDiagnosticProgress.self, from: bad) }
    }
}
