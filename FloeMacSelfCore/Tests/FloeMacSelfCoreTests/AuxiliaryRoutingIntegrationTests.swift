// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeMacSelfCore

@Suite("Auxiliary model routing")
struct AuxiliaryRoutingIntegrationTests {
    private actor Classifier: AutomaticReasoningEffortClassifying {
        private(set) var inputs: [String] = []
        func classify(_ input: String) async throws -> ModelReasoningEffort {
            inputs.append(input)
            return .high
        }
    }

    @Test("The task uses its auxiliary classifier for automatic effort and preserves an explicit manual choice")
    func reasoningRoute() async throws {
        try await withSelfCoreFixture { fixture in
            let primary = fixture.makeProvider(scripts: (0..<2).map { _ in
                [.textDelta(.init(text: "Finished")), .completed(.init(stopReason: .endTurn))]
            }, remoteModelID: "o3")
            let classifier = Classifier()
            let route = FloeMacSelfAuxiliaryRoutes(effortClassifier: classifier)
            for manual in [false, true] {
                var model = primary.binding.model
                model.reasoningEffort = manual ? .low : nil
                let provider = FloeMacSelfProviderBinding(provider: primary.binding.provider, model: model,
                    adapter: primary.adapter, credentials: primary.binding.credentials)
                let handle = try await fixture.runtime.startSession(.init(goal: "Compare project requirements", chatFastMode: false),
                    provider: provider, auxiliary: route)
                #expect(await handle.waitForTerminal(timeout: 15)?.outcome == .completed)
                #expect(primary.adapter.requests.last?.model.reasoningEffort == (manual ? .low : .high))
                _ = try await handle.close()
            }
            let inputs = await classifier.inputs
            #expect(inputs.count == 1)
            #expect(inputs.first?.contains("Compare project requirements") == true)
        }
    }

    @Test("A text model gets the selected helper's description and the original image stays attached to history")
    func visionFallback() async throws {
        try await withSelfCoreFixture { fixture in
            let attachment = try fixture.makeImageAttachment()
            let primary = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Primary answer")), .completed(.init(stopReason: .endTurn))
            ]], remoteModelID: "text-only", capabilities: [.text])
            let helper = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Blue triangle")), .completed(.init(stopReason: .endTurn))
            ]], remoteModelID: "vision-helper", capabilities: [.text, .vision])
            let handle = try await fixture.runtime.startSession(.init(goal: "Read the diagram", mode: .chat, attachments: [attachment]),
                provider: primary.binding, auxiliary: .init(vision: helper.binding))
            let receipt = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(receipt.outcome == .completed)
            let imageRequest = try #require(helper.adapter.requests.first)
            #expect(imageRequest.model.id == helper.binding.model.id)
            #expect(imageRequest.toolSchemas.isEmpty)
            #expect(imageRequest.contentMessages.contains { message in
                message.content.contains { if case .imageData = $0 { return true }; return false }
            })
            let request = try #require(primary.adapter.requests.first)
            #expect(request.model.id == primary.binding.model.id)
            #expect(request.effectiveMessages.contains { message in
                message.role == "user" && message.content.contains {
                    if case .text(let text) = $0 { return text.contains("untrusted reference data") && text.contains("Blue triangle") }
                    return false
                }
            })
            #expect(!request.contentMessages.contains { message in
                message.content.contains { if case .imageData = $0 { return true }; return false }
            })
            let messages = try await fixture.runtime.conversationMessages(conversationID: handle.identity.conversationID)
            #expect(messages.contains { $0.parts.contains { $0.attachmentID == attachment.id } })
            #expect(messages.contains { $0.role == "assistant" && $0.content == "Primary answer" })
            _ = try await handle.close()
        }
    }

    @Test("An image for a text-only model needs an enabled vision route before the task is admitted")
    func unavailableVisionRoute() async throws {
        try await withSelfCoreFixture { fixture in
            let primary = fixture.makeProvider(scripts: [], capabilities: [.text])
            let helper = fixture.makeProvider(scripts: [], capabilities: [.text, .vision])
            var disabled = helper.binding.model
            disabled.isEnabled = false
            let unavailable = FloeMacSelfProviderBinding(provider: helper.binding.provider, model: disabled,
                                                         adapter: helper.adapter, credentials: helper.binding.credentials)
            let image = try fixture.makeImageAttachment()
            for route in [FloeMacSelfAuxiliaryRoutes(), .init(vision: unavailable)] {
                do {
                    _ = try await fixture.runtime.startSession(.init(goal: "Read attachment", attachments: [image]),
                                                               provider: primary.binding, auxiliary: route)
                    Issue.record("Missing vision route unexpectedly admitted the task")
                } catch {
                    #expect(try await fixture.runtime.conversations().isEmpty)
                }
            }
            #expect(primary.adapter.requests.isEmpty)
            #expect(helper.adapter.requests.isEmpty)
        }
    }

    @Test("A vision-capable primary uses its native image input and skips the helper")
    func primaryHasVision() async throws {
        try await withSelfCoreFixture { fixture in
            let image = try fixture.makeImageAttachment()
            let primary = fixture.makeProvider(scripts: [[.textDelta(.init(text: "Read directly")), .completed(.init(stopReason: .endTurn))]],
                                               capabilities: [.text, .vision])
            let helper = fixture.makeProvider(scripts: [], capabilities: [.text, .vision])
            let handle = try await fixture.runtime.startSession(.init(goal: "Read", mode: .chat, attachments: [image]),
                provider: primary.binding, auxiliary: .init(vision: helper.binding))
            let receipt = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(receipt.outcome == .completed)
            #expect(helper.adapter.requests.isEmpty)
            #expect(primary.adapter.requests.first?.contentMessages.contains { message in
                message.content.contains { if case .imageData = $0 { return true }; return false }
            } == true)
            _ = try await handle.close()
        }
    }
}
