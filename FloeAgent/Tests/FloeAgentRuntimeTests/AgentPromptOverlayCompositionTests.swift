// FloeAgentRuntimeTests — signed-content overlay composition.
//
// The overlay may only replace the compiled method/communication/delivery
// layers; permission, approval and tool-protocol layers must always remain.

import Testing
import FloeCore
@testable import FloeAgentRuntime

@Suite("Agent prompt overlay composition")
struct AgentPromptOverlayCompositionTests {

    @Test("Overlay replaces the matching built-in layers and inserts the method layer")
    func overlayReplacesBuiltIns() throws {
        let overlay = try AgentPromptOverlay(sections: [
            .init(id: AgentPromptOverlay.methodSectionID, body: "METHOD_OVERLAY"),
            .init(id: AgentPromptOverlay.communicationSectionID, body: "COMMUNICATION_OVERLAY"),
            .init(id: AgentPromptOverlay.deliverySectionID, body: "DELIVERY_OVERLAY")
        ])
        let prompt = AgentPromptComposer.compose(
            mode: .chat, runtimeContext: "runtime context", overlay: overlay
        )
        #expect(prompt.contains("METHOD_OVERLAY"))
        #expect(prompt.contains("COMMUNICATION_OVERLAY"))
        #expect(prompt.contains("DELIVERY_OVERLAY"))
        // The compiled counterparts are replaced, not duplicated.
        #expect(!prompt.contains("# Communicating with the user"))
        #expect(!prompt.contains("# Delivering work"))
        // Fixed trust layers are untouched.
        #expect(prompt.contains("# Floe runtime contract"))
        #expect(prompt.contains("# Operating protocol"))
        #expect(prompt.contains("# Failure and retry protocol"))
        #expect(prompt.contains("# Chat mode"))
    }

    @Test("An empty overlay keeps every compiled layer")
    func emptyOverlayKeepsBuiltIns() {
        let prompt = AgentPromptComposer.compose(mode: .chat, runtimeContext: "runtime context")
        #expect(prompt.contains("# Communicating with the user"))
        #expect(prompt.contains("# Delivering work"))
    }

    @Test("A partial overlay replaces only the provided layer")
    func partialOverlay() throws {
        let overlay = try AgentPromptOverlay(sections: [
            .init(id: AgentPromptOverlay.deliverySectionID, body: "DELIVERY_ONLY")
        ])
        let prompt = AgentPromptComposer.compose(mode: .goal, runtimeContext: "ctx", overlay: overlay)
        #expect(prompt.contains("DELIVERY_ONLY"))
        #expect(prompt.contains("# Communicating with the user"))
        #expect(prompt.contains("# Goal mode"))
    }
}
