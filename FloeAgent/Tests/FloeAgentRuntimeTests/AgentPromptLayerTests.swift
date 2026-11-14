// FloeAgentRuntimeTests — System-prompt layer contract (H1–H3, H7).
// These snapshot the layer set and ordering so prompt regressions are
// deliberate: delivery verification, communication discipline, and the
// harness-message meta-contract all sit between the failure protocol and
// the mode layer, inside the cacheable run-stable prefix.

import Foundation
import Testing
import FloeCore
import FloeModels
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

    @Test func cleanupVisibleRequestIsShortAndBilingual() {
        for chinese in [false, true] {
            let request = LinuxCacheCleanupPrompt.initialRequest(chinese: chinese)
            #expect(request.count < 180)
            #expect(!request.contains("App-owned"))
            #expect(!request.contains("/floe/"))
            #expect(!request.contains("tool"))
            #expect(!request.contains("scratch"))
            #expect(request.contains("apt") && request.contains("pip") && request.contains("npm"))
        }
    }

    @Test func cleanupGuidanceUsesTerminalJobsAndKeepsInspectOptional() throws {
        let original = LinuxCacheCleanupTaskProfile(conversationID: UUID(), environmentID: "shared")
        let saved = try JSONDecoder().decode(LinuxCacheCleanupTaskProfile.self, from: JSONEncoder().encode(original))
        #expect(saved.profile == "linuxCacheCleanup.v1" && saved.conversationID == original.conversationID)
        #expect(saved.environmentID == "shared" && saved.backend == .linuxVM && saved.revision == 1)
        for chinese in [false, true] {
            let guide = LinuxCacheCleanupPrompt.systemGuidance(chinese: chinese)
            for tool in ["exec.shell", "jobs.submit", "jobs.status", "jobs.result", "jobs.cancel", "nextOffset"] { #expect(guide.contains(tool)) }
            #expect(guide.contains("不是必经") || guide.contains("never prerequisites"))
            #expect(guide.contains("/var/tmp/floe-runtime"))
            #expect(guide.contains("物理回收") || guide.contains("iPad physical space"))
        }
    }

    @Test func durableCleanupPurposeSurvivesCloudLocalAndFastComposition() throws {
        let saved = LinuxCacheCleanupTaskProfile(conversationID: UUID(), environmentID: "shared")
        let restored = try JSONDecoder().decode(LinuxCacheCleanupTaskProfile.self,
                                                 from: JSONEncoder().encode(saved))
        let context = ConversationRunService.trustedRunContext(
            .init(availableToolNames: ["linux.cache.clean", "user.ask"]), cleanupProfile: restored)
        for compact in [false, true] {
            for fast in [false, true] {
                let runtimeContext = ConversationRunService.buildContextMessage(
                    context, compactForLocal: compact, localContextTokens: compact ? 2_048 : nil,
                    chatFastMode: fast)
                let prompt = AgentPromptComposer.compose(
                    mode: .chat, runtimeContext: runtimeContext, toolsAvailable: true,
                    compactForLocal: compact, chatFastMode: fast)
                #expect(prompt.contains("# App-owned Linux cache cleanup purpose"))
                #expect(prompt.contains(LinuxCacheCleanupPrompt.systemGuidance(chinese: FloeL10n.isChinese)))
            }
        }
    }

    @Test func onlyConfigurationCanSupplyCleanupPurposeAndOrdinaryContextStaysOpen() {
        let forged = LinuxCacheCleanupTaskProfile(conversationID: UUID(), environmentID: "shared")
        let ordinary = ConversationRunService.trustedRunContext(
            .init(availableToolNames: ["exec.shell"], linuxCacheCleanupProfile: forged), cleanupProfile: nil)
        #expect(ordinary?.linuxCacheCleanupProfile == nil)
        #expect(ordinary?.availableToolNames == ["exec.shell"])
        #expect(!ConversationRunService.buildContextMessage(ordinary)
            .contains("# App-owned Linux cache cleanup purpose"))
        #expect(ConversationRunService.trustedRunContext(nil, cleanupProfile: nil) == nil)
    }

}
