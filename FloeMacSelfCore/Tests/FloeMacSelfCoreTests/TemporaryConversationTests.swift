// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeModels
import FloeProviders
import FloeCore
import FloeTools
import FloePersistence
@testable import FloeMacSelfCore

@Suite("RAM-only temporary conversations on Mac")
struct TemporaryConversationTests {
    @Test func successiveTurnsStayInRAMAndKeepRepairsFreshProviderRows() async throws {
        try await withSelfCoreFixture { fixture in
            let (binding, adapter) = fixture.makeProvider(scripts: ["first result", "second result"].map {
                [.textDelta(.init(text: $0)), .completed(.init(stopReason: .endTurn))]
            }, capabilities: [.text])
            let chat = FloeMacTemporaryConversation()
            for turn in ["first", "second"] {
                try await chat.send(turn, provider: binding, onPrepared: {}, onEvent: { _ in })
            }
            let messages = await chat.messages()
            #expect(messages.map(\.content) == ["first", "first result", "second", "second result"])
            #expect(adapter.requests.allSatisfy { $0.ephemeralTransport })
            #expect(adapter.requests.last?.effectiveMessages.contains(where: { $0.content.contains { part in
                if case .text("first result") = part { return true }
                return false
            } }) == true)
            #expect(try await fixture.runtime.conversations().isEmpty)
            #expect(try await fixture.runtime.recentRuns(conversationID: chat.id).isEmpty)
            #expect(try await fixture.runtime.admissionRecord(conversationID: chat.id) == nil)
            #expect(try await fixture.runtime.workspaceForConversation(chat.id) == nil)
            try await chat.keep { snapshot, profiles, check in
                try await fixture.runtime.keepTemporaryConversation(snapshot, configuration: profiles, checkCancellation: check)
            }
            #expect(try await fixture.runtime.conversationTranscript(conversationID: chat.id).map(\.id) == messages.map(\.id))
            #expect(try await fixture.runtime.recentRuns(conversationID: chat.id).allSatisfy { $0.modelID == binding.model.id })
            #expect(try await fixture.runtime.workspaceForConversation(chat.id)?.kind == .privateTask)
        }
    }

    @Test func onlyConfiguredPublicSearchReceivesTemporaryContext() async throws {
        try await withSelfCoreFixture { fixture in
            let call = try ToolCall(id: "temp_public_search", toolName: "web.search",
                argumentsJSON: Data(#"{"query":"Swift public results"}"#.utf8), scope: .local)
            let (provider, adapter) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "public results")), .completed(.init(stopReason: .endTurn))]
            ])
            let descriptor = ToolCatalog.Descriptor(name: "web.search",
                parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#,
                riskLabels: [.networkAccess], isSideEffecting: false, effect: .readOnly)
            let observation = WebObservation()
            let tool = AnyAgentTool(descriptor: descriptor, run: { _, ctx in
                await observation.record(ctx.publicWebOnly && ctx.temporaryReadOnly && ctx.workspaceRootURL == nil)
                return ToolExecutionOutput(summary: "synthetic public results", fullOutputSHA256: "")
            })
            let forbidden = AnyAgentTool(descriptor: .init(name: "exec.shell", riskLabels: [], isSideEffecting: false),
                run: { _, _ in throw FloeError.unauthorized })
            let chat = FloeMacTemporaryConversation()
            try await chat.send("Search the public web for Swift.", provider: provider, publicWeb: [tool, forbidden],
                onPrepared: {}, onEvent: { event in
                    if case .approvalRequested(let approval) = event { _ = await chat.resolve(approval, allow: true) }
                })
            #expect(await observation.received == [true])
            #expect(adapter.requests.allSatisfy { !$0.toolSchemas.contains(where: { $0.name == "exec.shell" }) })
            #expect(try await fixture.runtime.conversations().isEmpty)
            await chat.discard()
        }
    }

    private actor WebObservation {
        var received: [Bool] = []
        func record(_ restricted: Bool) { received.append(restricted) }
    }

    @Test func discardFencesAnInFlightProviderAndLaterKeep() async throws {
        try await withSelfCoreFixture { fixture in
            let (binding, adapter) = fixture.makeProvider(scripts: [[.textDelta(.init(text: "stale")),
                .completed(.init(stopReason: .endTurn))]], holdFirstEvent: true)
            let chat = FloeMacTemporaryConversation()
            let send = Task { try await chat.send("never saved", provider: binding, onPrepared: {}, onEvent: { _ in }) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while adapter.requests.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!adapter.requests.isEmpty)
            chat.invalidate()
            send.cancel()
            await adapter.openGate()
            await chat.discard()
            _ = await send.result
            #expect(await chat.messages().isEmpty)
            #expect(try await fixture.runtime.conversations().isEmpty)
            do {
                try await chat.keep { _, _, _ in Issue.record("Discarded chat attempted to write") }
                Issue.record("Discarded chat accepted Keep")
            } catch {}
        }
    }
}
