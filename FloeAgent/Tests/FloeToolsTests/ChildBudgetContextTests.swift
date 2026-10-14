// FloeToolsTests — child budget context contract for subagent delegation.

import Foundation
import Testing
@testable import FloeTools

@Suite("FloeTools.ChildBudgetContext")
struct ChildBudgetContextTests {

    @Test("the remaining probe is optional and passes through")
    func remainingProbe() async {
        let budget = ChildBudgetContext(
            maximumIterations: 6,
            reserve: { true },
            finish: {},
            remaining: { 4 }
        )
        let remaining = await budget.remaining?()
        #expect(remaining == 4)
    }

    @Test("a budget without a remaining probe reads nil, never an invented value")
    func missingRemainingProbe() {
        let budget = ChildBudgetContext(
            maximumIterations: 6,
            reserve: { true },
            finish: {}
        )
        #expect(budget.remaining == nil)
    }

    @Test("the iteration ceiling is clamped to at least one")
    func ceilingClamped() {
        let budget = ChildBudgetContext(
            maximumIterations: 0,
            reserve: { true },
            finish: {}
        )
        #expect(budget.maximumIterations == 1)
    }
}
