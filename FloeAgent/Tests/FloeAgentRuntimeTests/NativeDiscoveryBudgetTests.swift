// SPDX-License-Identifier: MPL-2.0
import Testing
import FloeTools
import FloeProviders
@testable import FloeAgentRuntime

@Suite("Complete native discovery under context pressure")
struct NativeDiscoveryBudgetTests {
    private func descriptor(_ name: String, size: Int = 0) -> ToolCatalog.Descriptor {
        .init(name: name, toolDescription: String(repeating: "d", count: size),
              parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#,
              riskLabels: [], isSideEffecting: false)
    }

    @Test func onlyResultReserveCanBeBorrowedForOneCompleteSearchDefinition() {
        let search = descriptor("tools.search"), paging = descriptor("tool.result.page", size: 900)
        let office = descriptor("document.office.edit", size: 1_800)
        let cost = ToolSchemaOfferPlanner.tokenCost(search)
        let baseline = ToolSchemaOfferPlanner.availableTokenBudget(contextWindowTokens: 4_096, reservedOutputTokens: 1_024,
            messageTokens: 2_200, imageTokens: 0, replayTokens: 0, toolResultReserveTokens: 1_024)
        #expect(baseline == 0)
        let budget = ToolSchemaOfferPlanner.availableTokenBudget(contextWindowTokens: 4_096, reservedOutputTokens: 1_024,
            messageTokens: 2_200, imageTokens: 0, replayTokens: 0, toolResultReserveTokens: 1_024, minimumDiscoveryTokens: cost)
        #expect(budget == cost && budget <= 4_096 - 1_024 - 2_200)
        let plan = ToolSchemaOfferPlanner.plan(descriptors: [paging, office, search], tokenBudget: budget,
            alwaysKeep: [paging.name, search.name], discoveryName: search.name)
        #expect(plan.offered.map(\.name) == [search.name])
        #expect(plan.offered.first?.parametersJSON == search.parametersJSON)
        #expect(!plan.offered.contains { $0.name == office.name } && plan.estimatedTokens <= budget)
    }

    @Test func actualMessageOutputImageAndReplayLimitsAreNeverOverridden() {
        let search = descriptor("tools.search"), cost = ToolSchemaOfferPlanner.tokenCost(search)
        let budget = ToolSchemaOfferPlanner.availableTokenBudget(contextWindowTokens: 4_096, reservedOutputTokens: 1_024,
            messageTokens: 2_000, imageTokens: 800, replayTokens: 400, toolResultReserveTokens: 1_024, minimumDiscoveryTokens: cost)
        #expect(budget == 0)
        let plan = ToolSchemaOfferPlanner.plan(descriptors: [search], tokenBudget: budget, discoveryName: search.name)
        #expect(plan.offered.isEmpty && plan.oversized == [search.name])
        // Runtime's dispatch guard must surface this case; no fake schema is fabricated.
    }

    @Test func missingDisabledDiscoveryIsNeverInventedAndOrdinaryBudgetsStayTheSame() {
        let office = descriptor("document.office.edit")
        let plan = ToolSchemaOfferPlanner.plan(descriptors: [office], tokenBudget: 500, discoveryName: "tools.search")
        #expect(plan.offered.map(\.name) == [office.name])
        #expect(ToolSchemaOfferPlanner.availableTokenBudget(contextWindowTokens: 16_384, reservedOutputTokens: 1_024,
            messageTokens: 2_000, imageTokens: 800, replayTokens: 400, toolResultReserveTokens: 1_024) == 11_136)
    }

    @Test func lateGuidanceStillChargesTheActualWireRequestAndSafetyMargin() {
        let schema = ToolSchemaDescriptor(name: "tools.search", description: "Search", parametersJSON: "{}")
        let size = ProviderRequestSizer.measure(messages: [.init(role: "system", content: [.text(String(repeating: "x", count: 10_500))])],
            schemas: [schema], contextWindowTokens: 4_096, reservedOutputTokens: 1_024)
        let fixed = size.messageTokens + size.schemaTokens + size.replayTokens + size.reservedOutputTokens + size.safetyMarginTokens
        #expect(fixed > size.contextWindowTokens && size.toolResultBudgetBytes == 0)
        // AgentRuntime's reserve-loan guard checks these assembled-wire fields
        // after late guidance/projection, before creating the dispatch envelope.
    }
}
