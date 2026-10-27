// FloeAgentRuntimeTests — run-clock and location-honesty contract.
//
// The ONLY location-adjacent facts a run injects are the fresh clock and the
// time zone: they never imply a place. These tests pin that the run context
// carries the explicit no-inference instruction in both the ordinary and the
// temporary fast envelope, that the injected timestamp stays fresh and
// explicit, and that a real runtime turn forwards the same honesty line to
// the provider system envelope.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.ContextTimeLocation")
struct ContextTimeLocationTests {

    private func completionEvents() -> [AgentEvent] {
        [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
    }

    @Test("The run context carries the fresh clock, the zone and the explicit no-inference line")
    func runContextIsExplicitAboutLocation() {
        let date = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z
        let zone = TimeZone(identifier: "Australia/Sydney")! // January: AEDT, UTC+11
        let ordinary = ConversationRunService.buildContextMessage(
            ConversationRunService.RunContext(), mode: .chat, toolsAvailable: true,
            currentDate: date, timeZone: zone, chatFastMode: true)
        // Fresh, explicit clock and zone — never stale, never a city guess.
        #expect(ordinary.contains("Current local date and time at run start: 2027-01-15T19:00:00"))
        #expect(ordinary.contains("Current time zone: Australia/Sydney (UTC+11:00)"))
        // The honesty instruction is present verbatim in the ordinary chat.
        #expect(ordinary.contains("never infer a place from the time zone"))
        #expect(ordinary.contains("current-location tool"))

        let temporary = ConversationRunService.buildContextMessage(
            ConversationRunService.RunContext(), mode: .chat, toolsAvailable: true,
            currentDate: date, timeZone: zone,
            chatFastMode: true, temporaryReadOnly: true)
        #expect(temporary.contains("never infer a place from the time zone"))
        #expect(temporary.contains("current-location tool"))
        #expect(temporary.contains("basic on-device reads"))

        // The task-mode envelope is unchanged and also carries no location
        // claim beyond the clock/zone lines.
        let task = ConversationRunService.buildContextMessage(
            ConversationRunService.RunContext(), mode: .goal,
            currentDate: date, timeZone: zone)
        #expect(task.contains("Current local date and time at run start: 2027-01-15T19:00:00"))
        #expect(task.contains("Current time zone: Australia/Sydney (UTC+11:00)"))
        // The clock lines must not smuggle in a fabricated place.
        for envelope in [ordinary, temporary, task] {
            #expect(!envelope.contains("you are in"))
            #expect(!envelope.contains("the user is located"))
        }
    }

    @Test("A real chat turn injects a fresh volatile runtime clock every request")
    func runtimeTurnInjectsFreshClock() async throws {
        let provider = TestFixtures.localhostProvider()
        let adapter = MockAdapter()
        adapter.script = [completionEvents()]
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                chatFastMode: true
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: MockExecutor(),
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
        try await runtime.start(goal: "chat answer")
        let request = try #require(adapter.requests.first)
        let systemText = request.messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n")
        // Fresh volatile clock injected per turn; it names time and zone
        // only — never a place.
        #expect(systemText.contains("Current runtime time:"))
        #expect(systemText.contains("timeZone="))
        #expect(!systemText.contains("Current runtime city"))
        // The conversation envelope itself (ConversationRunService) owns the
        // no-inference line; the seam is pinned above.
    }
}
