// FloeCoreTests — validated prompt overlay contract.

import Foundation
import Testing
@testable import FloeCore

@Suite("Agent prompt overlay")
struct AgentPromptOverlayTests {

    @Test("Only the three replaceable sections can be constructed")
    func allowedSections() throws {
        let overlay = try AgentPromptOverlay(sections: [
            .init(id: AgentPromptOverlay.methodSectionID, body: "Do the smallest thing."),
            .init(id: AgentPromptOverlay.communicationSectionID, body: "Be brief."),
            .init(id: AgentPromptOverlay.deliverySectionID, body: "Verify before claiming.")
        ])
        #expect(overlay.method == "Do the smallest thing.")
        #expect(overlay.communication == "Be brief.")
        #expect(overlay.delivery == "Verify before claiming.")

        // Tool discipline, permissions and protocol IDs are not replaceable.
        for forbidden in [
            "floe.prompts.core.tool-discipline",
            "floe.prompts.core.permissions",
            "floe.prompts.core.operating-protocol",
            "floe.prompts.core.anything"
        ] {
            #expect(throws: AgentPromptOverlayError.unknownSectionID(forbidden)) {
                try AgentPromptOverlay(sections: [.init(id: forbidden, body: "override")])
            }
        }
    }

    @Test("Duplicate, empty and oversized sections are rejected, never truncated")
    func boundsAreExplicit() {
        #expect(throws: AgentPromptOverlayError.duplicateSectionID(AgentPromptOverlay.methodSectionID)) {
            try AgentPromptOverlay(sections: [
                .init(id: AgentPromptOverlay.methodSectionID, body: "a"),
                .init(id: AgentPromptOverlay.methodSectionID, body: "b")
            ])
        }
        #expect(throws: AgentPromptOverlayError.emptyBody(AgentPromptOverlay.methodSectionID)) {
            try AgentPromptOverlay(sections: [
                .init(id: AgentPromptOverlay.methodSectionID, body: "   \n")
            ])
        }
        let big = String(repeating: "x", count: AgentPromptOverlay.maximumSectionBytes + 1)
        #expect(throws: AgentPromptOverlayError.sectionTooLarge(
            id: AgentPromptOverlay.methodSectionID, limit: AgentPromptOverlay.maximumSectionBytes
        )) {
            try AgentPromptOverlay(sections: [.init(id: AgentPromptOverlay.methodSectionID, body: big)])
        }
        // Each section is individually valid but the total overflows.
        let chunk = String(repeating: "y", count: AgentPromptOverlay.maximumSectionBytes)
        #expect(throws: AgentPromptOverlayError.totalTooLarge(limit: AgentPromptOverlay.maximumTotalBytes)) {
            try AgentPromptOverlay(sections: [
                .init(id: AgentPromptOverlay.methodSectionID, body: chunk),
                .init(id: AgentPromptOverlay.communicationSectionID, body: chunk),
                .init(id: AgentPromptOverlay.deliverySectionID, body: chunk)
            ])
        }
    }

    @Test("Variables are an allow-list and expressions are rejected")
    func variablesAndExpressions() throws {
        let resolved = try AgentPromptOverlay(sections: [
            .init(
                id: AgentPromptOverlay.deliverySectionID,
                body: "Deliver inside {app.name} on {platform.name}."
            )
        ])
        #expect(resolved.resolved(
            resolved.delivery ?? "", appName: "Floe", platformName: "iPad"
        ) == "Deliver inside Floe on iPad.")

        #expect(throws: AgentPromptOverlayError.unknownVariable("secret.key")) {
            try AgentPromptOverlay(sections: [
                .init(id: AgentPromptOverlay.methodSectionID, body: "Use {secret.key}.")
            ])
        }
        for expression in ["{{ config.value }}", "run ${PATH}", "${SECRET}"] {
            #expect(throws: AgentPromptOverlayError.expressionNotAllowed(AgentPromptOverlay.methodSectionID)) {
                try AgentPromptOverlay(sections: [.init(id: AgentPromptOverlay.methodSectionID, body: expression)])
            }
        }
    }
}
