// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeMacSelfCore

@Suite("Conversation reasoning on Mac")
struct ChatReasoningIntegrationTests {
    @Test("Chat freezes the requested effort and remembers it only for that conversation")
    func chatRoundUsesSavedReasoning() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, adapter) = fixture.makeProvider(
                scripts: (0..<3).map { _ in [.textDelta(.init(text: "OK")), .completed(.init(stopReason: .endTurn))] },
                remoteModelID: "o3"
            )
            let first = try await fixture.runtime.startSession(
                .init(conversationTitle: "Local chat preference", goal: "First", chatReasoningPreference: .high),
                provider: provider
            )
            #expect(await first.waitForTerminal(timeout: 15)?.confirmed == true)
            let id = first.identity.conversationID
            let firstEvents = try await first.durableEvents(limit: 100)
            #expect(ChatReasoningSupport.findDecision(in: firstEvents)?.preference == .high)
            #expect(try await fixture.runtime.chatReasoning(conversationID: id) == .high)
            _ = try await first.close()

            try await fixture.runtime.setChatReasoning(.low, conversationID: id)
            let next = try await fixture.runtime.startSession(.init(conversationID: id, goal: "Next"), provider: provider)
            #expect(await next.waitForTerminal(timeout: 15)?.confirmed == true)
            let nextEvents = try await next.durableEvents(limit: 100)
            #expect(ChatReasoningSupport.findDecision(in: nextEvents)?.preference == .low)
            _ = try await next.close()

            let fresh = try await fixture.runtime.startSession(.init(goal: "Fresh chat"), provider: provider)
            #expect(await fresh.waitForTerminal(timeout: 15)?.confirmed == true)
            #expect(try await fixture.runtime.chatReasoning(conversationID: fresh.identity.conversationID) == .fast)
            _ = try await fresh.close()
            #expect(adapter.requests.count == 3)
            #expect(provider.model.reasoningEffort == nil)
        }
    }
}
