import Foundation
import Testing
@testable import FloeAgentRuntime

/// Pins the bounded local runtime envelope (Build229 follow-up): with a
/// realistic workspace state — an ~11 KB project instruction file like the
/// device workspace carried, plus memory, style, profile, links and a
/// listing — the composed system envelope must stay inside the local model
/// window share reserved for runtime instructions, and every section must
/// survive with its head and tail and an explicit omission marker.
@Suite("Local runtime envelope bounds")
struct LocalEnvelopeBoundsTests {
    /// A stand-in for a real project instruction file (FLOE.md/AGENTS.md) of
    /// the size the Build229 device workspace carried (~11 KB).
    private static let largeProjectInstructions: String = {
        let core = String(repeating: """
        ## Repository section
        - Trace the actual UI → service → runtime/storage path before fixing symptoms.
        - Preserve pinned revisions and hashes; check availability against the SDK.
        - Notes storage survives deletion of a chat task; keep iPad-first layouts.

        """, count: 26)
        return "# Workspace instructions (FLOE.md/AGENTS.md)\n" + core
    }()

    private static let listing = """
    FloeAgent/
    FloeAgent/FloeApp
    FloeAgent/Sources
    FloeAgent/Tests
    docs
    Local
    README.md
    AGENTS.md
    """

    private static func makeContext() -> ConversationRunService.RunContext {
        .init(
            workspaceName: "IOS AI AGENT",
            selectedRelativePath: "FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift",
            executionTarget: "local",
            availableToolNames: ["workspace.readFile", "workspace.listDirectory", "tools.list", "tools.search"],
            skillInstructions: "# Workflow guide\nUse the narrowest authoritative read; batch independent calls.",
            memoryContext: String(repeating: "Prior session: verified Build228 two-turn tool receipts on the same workspace. ", count: 8),
            soulContext: String(repeating: "Be concise, warm and precise; answer in the user's language. ", count: 6),
            userProfileContext: String(repeating: "User prefers bilingual concise updates and evidence-backed claims. ", count: 6),
            workspaceAttachmentPaths: [],
            workspaceNotes: ["cloud-link: official-service via verified tunnel"],
            workspaceListing: listing,
            projectInstructions: largeProjectInstructions
        )
    }

    private static func estimateTokens(_ text: String) -> Int {
        ContextTokenEstimator().estimate(text)
    }

    @Test("The unbounded local envelope with a large AGENTS.md reproduces the Build229 device scale")
    func unboundedEnvelopeMatchesDeviceScale() {
        let envelope = ConversationRunService.buildContextMessage(
            Self.makeContext(), mode: .chat, toolsAvailable: true, compactForLocal: true
        )
        let size = envelope.count
        let tokens = Self.estimateTokens(envelope)
        // The Build229 device runtime envelope was 12,284 characters (the
        // adapter then added its own constant protocol text, reaching
        // systemCharacters 15,276 and an estimated 6,196 prompt tokens for a
        // 12-character user message). A realistic workspace state must
        // reproduce at least that scale so the bounded path is exercised
        // against the real failure size.
        #expect(size >= 9_000)
        print("UNBOUNDED-ENVELOPE characters=\(size) heuristicTokens=\(tokens)")
    }

    @Test("A bounded local envelope keeps every section and fits the 8K local window share")
    func boundedEnvelopeFitsLocalWindow() {
        let envelope = ConversationRunService.buildContextMessage(
            Self.makeContext(), mode: .chat, toolsAvailable: true, compactForLocal: true,
            localContextTokens: 8_192
        )
        let tokens = Self.estimateTokens(envelope)
        // The device adapter reserves roughly a quarter of the usable 8K
        // window for runtime instructions; the envelope must leave room for
        // the adapter's own protocol text, the offered-tool index, the
        // transcript and the tool receipts.
        #expect(tokens <= 2_400)
        // No section vanished: the contract, clock, workspace, memory, style
        // and project instructions are all still present.
        #expect(envelope.contains("# Floe local runtime contract"))
        #expect(envelope.contains("Current local date and time"))
        #expect(envelope.contains("IOS AI AGENT"))
        #expect(envelope.contains("FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift"))
        #expect(envelope.contains("# Project instructions (FLOE.md/AGENTS.md)"))
        #expect(envelope.contains("# Remembered context"))
        #expect(envelope.contains("# Interaction style (SOUL.md)"))
        #expect(envelope.contains("# User profile data"))
        #expect(envelope.contains("Workspace top-level entries"))
        #expect(envelope.contains("cloud-link: official-service"))
        #expect(envelope.contains("# Available workflow guides"))
        // Omissions are explicit, never silent, and the oversized project
        // instructions were the clipped one.
        let omittedCount = envelope.components(separatedBy: LocalEnvelopeBounds.omissionMarker).count - 1
        #expect(omittedCount >= 1)
        print("BOUNDED-ENVELOPE characters=\(envelope.count) heuristicTokens=\(tokens) markers=\(omittedCount)")
    }

    @Test("A short first chat with a real-sized workspace produces a small bounded envelope")
    func shortFirstChatEnvelopeIsSmall() {
        // A real AGENTS.md (this repository's own file is ~11 KB) with no
        // memory/style/profile state: an ordinary 12-character greeting must
        // not inherit a multi-thousand-token envelope.
        let context = ConversationRunService.RunContext(
            workspaceName: "IOS AI AGENT",
            executionTarget: "local",
            projectInstructions: Self.largeProjectInstructions
        )
        let envelope = ConversationRunService.buildContextMessage(
            context, mode: .chat, toolsAvailable: true, compactForLocal: true,
            localContextTokens: 8_192
        )
        let tokens = Self.estimateTokens(envelope)
        #expect(tokens <= 1_500)
        #expect(envelope.contains("# Project instructions (FLOE.md/AGENTS.md)"))
        #expect(envelope.contains(LocalEnvelopeBounds.omissionMarker))
        print("SHORT-CHAT-ENVELOPE characters=\(envelope.count) heuristicTokens=\(tokens)")
    }

    @Test("The bounded envelope without optional state stays near the essential floor")
    func boundedEnvelopeWithoutOptionalStateStaysSmall() {
        let minimal = ConversationRunService.buildContextMessage(
            .init(workspaceName: "Demo", executionTarget: "local"),
            mode: .chat, toolsAvailable: true, compactForLocal: true,
            localContextTokens: 8_192
        )
        let tokens = Self.estimateTokens(minimal)
        // Contract + mode + run context only: a small floor, not the
        // multi-thousand-token Build229 envelope.
        #expect(tokens <= 1_100)
        #expect(minimal.contains("# Floe local runtime contract"))
        #expect(minimal.contains("Demo"))
        #expect(!minimal.contains(LocalEnvelopeBounds.omissionMarker))
        print("MINIMAL-ENVELOPE characters=\(minimal.count) heuristicTokens=\(tokens)")
    }

    @Test("Cloud envelopes are untouched by the local bound")
    func cloudEnvelopeStaysVerbatim() {
        let cloud = ConversationRunService.buildContextMessage(
            Self.makeContext(), mode: .chat, toolsAvailable: true, compactForLocal: false
        )
        #expect(cloud.contains(LocalEnvelopeBoundsTests.largeProjectInstructions))
        #expect(!cloud.contains(LocalEnvelopeBounds.omissionMarker))
    }

    @Test("Multi-turn state (plan and goal) survives bounding with their key facts")
    func multiTurnStateSurvivesBounding() {
        let plan = PlanDraft(
            conversationID: UUID(),
            title: "Ship 1.7",
            summary: "Finish the local model memory repair and qualify it.",
            sections: [
                .init(title: "Diagnose", body: "Find the prompt bloat source.", order: 0),
                .init(title: "Repair", body: "Bound the local envelope at its source.", order: 1),
            ],
            acceptanceCriteria: [
                .init(text: "Two-turn tool run passes on real weights", verification: "cloud qualification")
            ]
        )
        let goal = ConversationGoal(
            conversationID: UUID(),
            objective: "Local chat fits the iPad memory budget",
            acceptanceCriteria: [],
            steps: []
        )
        var context = Self.makeContext()
        context.activePlan = plan
        context.activeGoal = goal
        let bounded = ConversationRunService.buildContextMessage(
            context, mode: .goal, toolsAvailable: true, compactForLocal: true,
            localContextTokens: 8_192
        )
        #expect(bounded.contains("Ship 1.7"))
        #expect(bounded.contains("Local chat fits the iPad memory budget"))
        #expect(bounded.contains("# Durable goal state"))
        #expect(Self.estimateTokens(bounded) <= 2_600)
    }

    @Test("An over-budget plan keeps every section and acceptance check identity")
    func overBudgetPlanKeepsEveryItemIdentity() {
        // 24 sections + 12 criteria with generous bodies far exceed the
        // per-section share; the projection must still list every item so
        // the model cannot treat a middle requirement as nonexistent.
        var plan = PlanDraft(
            conversationID: UUID(),
            title: "Wide plan",
            summary: "Many tracked requirements.",
            sections: (0..<24).map {
                .init(
                    title: "SECTION-TITLE-\($0)",
                    body: String(repeating: "section body \($0) ", count: 20),
                    order: $0
                )
            },
            acceptanceCriteria: (0..<12).map {
                .init(
                    text: "CRITERION-\($0) " + String(repeating: "criterion text ", count: 10),
                    verification: "VERIFY-\($0)"
                )
            }
        )
        plan.assumptions = [.init(text: "ASSUMPTION-0 " + String(repeating: "assumption body ", count: 10))]
        plan.risks = [.init(text: "RISK-0 " + String(repeating: "risk body ", count: 10), mitigation: "MITIGATE-0", severity: .high)]
        plan.status = .accepted

        let full = ConversationRunService.buildContextMessage(
            .init(activePlan: plan), mode: .plan, toolsAvailable: true, compactForLocal: true
        )
        let bounded = ConversationRunService.buildContextMessage(
            .init(activePlan: plan), mode: .plan, toolsAvailable: true, compactForLocal: true,
            localContextTokens: 8_192
        )
        // The bounded layer must fit the per-section share while the
        // unbounded layer demonstrably exceeds it.
        let fullPlan = full.components(separatedBy: "# Accepted plan state").last ?? ""
        let boundedPlan = bounded.components(separatedBy: "# Accepted plan state").last ?? ""
        #expect(Self.estimateTokens(fullPlan) > 640)
        print("OVER-BUDGET-PLAN full=\(Self.estimateTokens(fullPlan)) bounded=\(Self.estimateTokens(boundedPlan))")
        // The identity floor (24 characters per text item) allows a small,
        // bounded overshoot above the nominal 640-token share; the layer is
        // still ~4.5x smaller than the unbounded render and the adapter's
        // prepared-token guard remains the final admission decision.
        #expect(Self.estimateTokens(boundedPlan) <= 900)
        // Every identity survives: all 24 section titles, all 12 criterion
        // identifiers, the assumption and the risk.
        for index in 0..<24 {
            #expect(bounded.contains("SECTION-TITLE-\(index)"), "lost section \(index)")
        }
        for index in 0..<12 {
            #expect(bounded.contains("CRITERION-\(index)"), "lost criterion \(index)")
        }
        #expect(bounded.contains("ASSUMPTION-0"))
        #expect(bounded.contains("RISK-0"))
        // Explicit omission marker plus the full-content read path.
        #expect(bounded.contains(LocalEnvelopeBounds.omissionMarker))
        #expect(bounded.contains("the full revision 1 draft remains stored in the app"))
        // The verification half of a criterion is auxiliary prose: when the
        // per-item budget cannot cover it, the criterion identity (text
        // prefix) still survives, which is the pinned contract.
        #expect(bounded.contains("CRITERION-0"))
    }

    @Test("An over-budget goal keeps every step and criterion identity")
    func overBudgetGoalKeepsEveryItemIdentity() {
        let goal = ConversationGoal(
            conversationID: UUID(),
            objective: "Wide goal",
            blockingConditions: ["BLOCKER-0 " + String(repeating: "blocker body ", count: 12)],
            stoppingConditions: ["STOP-0 " + String(repeating: "stop body ", count: 12)],
            acceptanceCriteria: (0..<10).map {
                .init(text: "GOAL-CRITERION-\($0) " + String(repeating: "criterion body ", count: 12))
            },
            steps: (0..<15).map {
                .init(
                    title: "STEP-TITLE-\($0)",
                    detail: String(repeating: "step detail \($0) ", count: 20),
                    order: $0
                )
            },
            status: .active
        )
        let full = ConversationRunService.buildContextMessage(
            .init(activeGoal: goal), mode: .goal, toolsAvailable: true, compactForLocal: true
        )
        let bounded = ConversationRunService.buildContextMessage(
            .init(activeGoal: goal), mode: .goal, toolsAvailable: true, compactForLocal: true,
            localContextTokens: 8_192
        )
        let fullGoal = full.components(separatedBy: "# Durable goal state").last ?? ""
        let boundedGoal = bounded.components(separatedBy: "# Durable goal state").last ?? ""
        #expect(Self.estimateTokens(fullGoal) > 640)
        #expect(Self.estimateTokens(boundedGoal) <= 720)
        // The projection shows at most the first 12 unfinished steps (the
        // layer's own documented cap) — and every shown step keeps its
        // title; all criteria/blockers/stops are short enough to stay whole.
        for index in 0..<12 {
            #expect(bounded.contains("STEP-TITLE-\(index)"), "lost step \(index)")
        }
        for index in 0..<10 {
            #expect(bounded.contains("GOAL-CRITERION-\(index)"), "lost goal criterion \(index)")
        }
        #expect(bounded.contains("BLOCKER-0"))
        #expect(bounded.contains("STOP-0"))
        #expect(bounded.contains(LocalEnvelopeBounds.omissionMarker))
        #expect(bounded.contains("the full goal remains stored in the app"))
    }
}
