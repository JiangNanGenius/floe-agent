// Focused behavioral regression for complete-schema admission.
//
// Registered in the shared package's FloeAgentRuntimeTests target. Host
// component checks are separate from Android linkage and App acceptance.

import Foundation
import XCTest
import FloeTools
@testable import FloeAgentRuntime

final class ToolSchemaOfferPlannerTests: XCTestCase {
    private func descriptor(_ name: String, padding: Int) -> ToolCatalog.Descriptor {
        let filler = String(repeating: "x", count: max(0, padding))
        let schema = "{\"type\":\"object\",\"properties\":{\"p\":{\"type\":\"string\",\"description\":\"\(filler)\"}},\"additionalProperties\":false}"
        return ToolCatalog.Descriptor(
            name: name,
            toolDescription: "description for \(name)",
            parametersJSON: schema,
            riskLabels: [],
            isSideEffecting: false
        )
    }

    func testAmpleRealWindowAdmitsMoreThan23CompleteSchemas() {
        let descriptors = (0..<30).map {
            descriptor("tool.group\($0)", padding: 3_000)
        }
        let totalCost = descriptors.reduce(0) {
            $0 + ToolSchemaOfferPlanner.tokenCost($1)
        }
        XCTAssertGreaterThan(totalCost, 23_000)
        let plan = ToolSchemaOfferPlanner.plan(
            descriptors: descriptors,
            tokenBudget: totalCost
        )
        XCTAssertEqual(plan.offered.count, 30)
        XCTAssertGreaterThan(plan.estimatedTokens, 23_000)
        XCTAssertTrue(plan.deferred.isEmpty)
        XCTAssertTrue(plan.oversized.isEmpty)
        // Every admitted definition is the COMPLETE original schema.
        for (offered, source) in zip(plan.offered, descriptors) {
            XCTAssertEqual(offered.name, source.name)
            XCTAssertEqual(offered.parametersJSON, source.parametersJSON)
        }
    }

    func testSmallWindowDefersWholeSchemaWithoutSlicing() {
        let small = descriptor("tool.small", padding: 240)
        let large = descriptor("tool.large", padding: 600)
        let smallCost = ToolSchemaOfferPlanner.tokenCost(small)
        let largeCost = ToolSchemaOfferPlanner.tokenCost(large)
        // Enough for small, not enough for both; large still fits alone.
        let budget = max(smallCost, largeCost) + max(1, min(smallCost, largeCost) - 10)
        XCTAssertLessThan(budget, smallCost + largeCost)

        let plan = ToolSchemaOfferPlanner.plan(
            descriptors: [small, large],
            tokenBudget: budget
        )
        XCTAssertEqual(plan.offered.map(\.name), ["tool.small"])
        XCTAssertEqual(plan.offered.first?.parametersJSON, small.parametersJSON)
        XCTAssertEqual(plan.deferred, ["tool.large"])
        XCTAssertTrue(plan.oversized.isEmpty)
    }

    func testDefinitionLargerThanWholeAllowanceIsOversizedNotSliced() {
        let large = descriptor("cad.document", padding: 6_000)
        let cost = ToolSchemaOfferPlanner.tokenCost(large)
        let plan = ToolSchemaOfferPlanner.plan(
            descriptors: [large],
            tokenBudget: cost - 1
        )
        XCTAssertTrue(plan.offered.isEmpty)
        XCTAssertEqual(plan.oversized, ["cad.document"])
        XCTAssertTrue(plan.deferred.isEmpty)
    }

    func testExplicitlyRequestedLargeSchemaPrecedesOptionalCoreHelpers() {
        let discovery = descriptor("tools.search", padding: 40)
        let cad = descriptor("cad.document", padding: 2_000)
        let coreOne = descriptor("skill.search", padding: 40)
        let coreTwo = descriptor("skill.read", padding: 40)
        let ordered = ToolSchemaOfferPlanner.prioritized(
            [discovery, coreOne, cad, coreTwo],
            priority: ["cad.document"],
            pinned: [],
            coreNames: ["skill.search", "skill.read"]
        )
        XCTAssertEqual(ordered.map(\.name), ["cad.document", "skill.read", "skill.search", "tools.search"])
        let budget = ToolSchemaOfferPlanner.tokenCost(discovery)
            + ToolSchemaOfferPlanner.tokenCost(cad)
        let plan = ToolSchemaOfferPlanner.plan(
            descriptors: ordered,
            tokenBudget: budget,
            alwaysKeep: ["tools.search"],
            discoveryName: "tools.search"
        )
        XCTAssertEqual(plan.offered.map(\.name), ["tools.search", "cad.document"])
        XCTAssertTrue(plan.deferred.contains("skill.search"))
        XCTAssertTrue(plan.deferred.contains("skill.read"))
    }

    func testDiscoverySchemaIsAdmittedFirstWhenItFits() {
        let discovery = descriptor("tools.search", padding: 40)
        let other = descriptor("workspace.readFile", padding: 40)
        let plan = ToolSchemaOfferPlanner.plan(
            descriptors: [other, discovery],
            tokenBudget: ToolSchemaOfferPlanner.tokenCost(discovery)
                + ToolSchemaOfferPlanner.tokenCost(other),
            alwaysKeep: ["tools.search"],
            discoveryName: "tools.search"
        )
        XCTAssertEqual(plan.offered.first?.name, "tools.search")
    }

    func testAvailableBudgetKeepsFixedCostsAndOnlyBorrowsResultReserve() {
        let available = ToolSchemaOfferPlanner.availableTokenBudget(
            contextWindowTokens: 10_000,
            reservedOutputTokens: 2_000,
            messageTokens: 3_000,
            imageTokens: 500,
            replayTokens: 500,
            toolResultReserveTokens: 2_000,
            minimumDiscoveryTokens: 500
        )
        // remaining = 4 000; reserve = min(2 000, 3 500) = 2 000.
        XCTAssertEqual(available, 2_000)

        let tight = ToolSchemaOfferPlanner.availableTokenBudget(
            contextWindowTokens: 5_000,
            reservedOutputTokens: 2_000,
            messageTokens: 2_000,
            imageTokens: 0,
            replayTokens: 0,
            toolResultReserveTokens: 2_000,
            minimumDiscoveryTokens: 500
        )
        // remaining = 1 000; reserve borrows down to 500, never below it.
        XCTAssertEqual(tight, 500)
    }

    func testEvictedReportsOnlyPreviouslyOfferedEligibleNames() {
        let evicted = ToolSchemaOfferPlanner.evicted(
            previous: ["tools.search", "a", "b", "c", "a"],
            current: ["c", "a"],
            eligible: ["a", "b", "c"]
        )
        XCTAssertEqual(evicted, ["b"])
    }

    func testRetainingOrderKeepsSurvivorPrefixAndAppendsNewNames() {
        let first = ToolSchemaOfferPlanner.retainingOrder(
            ["a", "b", "c"],
            after: ["c", "a", "removed"],
            name: \.self
        )
        XCTAssertEqual(first, ["c", "a", "b"])
        let retry = ToolSchemaOfferPlanner.retainingOrder(
            ["a", "b", "c"],
            after: first,
            name: \.self
        )
        XCTAssertEqual(retry, first)
    }

    func testAdmissionNeverInventsNamesOutsideTheInputCeiling() {
        let descriptors = [
            descriptor("a", padding: 20),
            descriptor("b", padding: 20)
        ]
        let plan = ToolSchemaOfferPlanner.plan(
            descriptors: descriptors,
            tokenBudget: 10_000,
            alwaysKeep: ["missing.tool"],
            discoveryName: "missing.tool"
        )
        XCTAssertEqual(Set(plan.offered.map(\.name)), Set(["a", "b"]))
        XCTAssertFalse(plan.offered.map(\.name).contains("missing.tool"))
    }
}
