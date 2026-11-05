// FloeAgentRuntimeTests — System-prompt layer contract (H1–H3, H7).
// These snapshot the layer set and ordering so prompt regressions are
// deliberate: delivery verification, communication discipline, and the
// harness-message meta-contract all sit between the failure protocol and
// the mode layer, inside the cacheable run-stable prefix.

import Foundation
import Testing
@testable import FloeAgentRuntime

@Suite("Agent prompt layers")
struct AgentPromptLayerTests {
    @Test func cloudLayersCarryDeliveryAndDisciplineContracts() {
        let prompt = AgentPromptComposer.compose(
            mode: .chat,
            runtimeContext: "ctx",
            toolsAvailable: true
        )
        let delivery = prompt.range(of: "# Delivering work")
        let communication = prompt.range(of: "# Communicating with the user")
        let harness = prompt.range(of: "# Harness messages")
        let failure = prompt.range(of: "# Failure and retry protocol")
        let mode = prompt.range(of: "# Chat mode")
        #expect(delivery != nil && communication != nil && harness != nil)
        // Ordering: failure → delivery → communication → harness → mode.
        #expect(failure!.lowerBound < delivery!.lowerBound)
        #expect(delivery!.lowerBound < communication!.lowerBound)
        #expect(communication!.lowerBound < harness!.lowerBound)
        #expect(harness!.lowerBound < mode!.lowerBound)
    }

    @Test func deliveryContractIsOperationalNotAspirational() {
        let prompt = AgentPromptComposer.compose(mode: .chat, runtimeContext: "ctx")
        // The clauses that ended the "schema loaded == fixed" failure mode.
        #expect(prompt.contains("exercise real tool calls against the real feature"))
        #expect(prompt.contains("never present unverified work as done"))
        #expect(prompt.contains("accepting a smaller result is the user's decision"))
        #expect(prompt.contains("re-read the user's latest message"))
    }

    @Test func denialAndReminderDiscipline() {
        let prompt = AgentPromptComposer.compose(mode: .chat, runtimeContext: "ctx")
        #expect(prompt.contains("never retry it unchanged"))
        #expect(prompt.contains("route around a denial"))
        #expect(prompt.contains("`<system-reminder>` tags"))
        #expect(prompt.contains("authoritative directives issued by the Floe runtime"))
    }

    @Test func localLinuxGuidanceUsesActualOwnershipWithoutStaleResourceLimits() {
        let prompt = AgentPromptComposer.compose(mode: .chat, runtimeContext: "ctx", compactForLocal: true)
        #expect(prompt.contains("reuse a running environment"))
        #expect(prompt.contains("conversation.message"))
        #expect(prompt.contains("verify release"))
        #expect(!prompt.contains("guest max 3"))
        #expect(!prompt.contains("then call environment.startLinux"))
        let full = AgentPromptComposer.compose(mode: .chat, runtimeContext: "ctx")
        #expect(full.contains("need not restart for a CPU change"))
        #expect(full.contains("1–4 online CPUs"))
        #expect(!full.contains("at most three per guest"))
        #expect(!full.contains("Changing a running guest requires environment.hardRestartLinux"))
    }

    @Test func localContractCarriesTheSameDisciplineInBrief() {
        let prompt = AgentPromptComposer.compose(
            mode: .chat,
            runtimeContext: "ctx",
            compactForLocal: true
        )
        #expect(prompt.contains("never present unverified work as done"))
        #expect(prompt.contains("<system-reminder>"))
        #expect(prompt.contains("start the next task with a fresh checklist"))
        #expect(prompt.contains("reply in the user's language"))
        // The compact layer must stay compact.
        #expect(prompt.utf8.count < 8_000)
    }
}
