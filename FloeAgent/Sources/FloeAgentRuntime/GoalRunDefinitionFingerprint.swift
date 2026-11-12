// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Definition identity only. Runtime goal ID/owner is verified separately;
/// changing status, progress, evidence or future budgets cannot rewrite the
/// already-admitted round or manufacture a match for different criteria.
public enum GoalRunDefinitionFingerprint {
    private struct Criterion: Encodable {
        let id: UUID
        let text: String
        let requiresUserConfirmation: Bool
    }
    private struct Step: Encodable {
        let id: UUID
        let title: String
        let detail: String
        let order: Int
    }
    private struct Definition: Encodable {
        let schema: Int
        let sourcePlanID: UUID?
        let sourcePlanDigest: String?
        let objective: String
        let criteria: [Criterion]
        let steps: [Step]
        let blockingConditions: [String]
        let stoppingConditions: [String]
    }
    public static func make(_ goal: ConversationGoal) throws -> String {
        let definition = Definition(schema: 1, sourcePlanID: goal.sourcePlanID,
            sourcePlanDigest: goal.sourcePlanDigest, objective: goal.objective,
            criteria: goal.acceptanceCriteria.map { .init(id: $0.id, text: $0.text, requiresUserConfirmation: $0.requiresUserConfirmation) },
            steps: goal.steps.map { .init(id: $0.id, title: $0.title, detail: $0.detail, order: $0.order) },
            blockingConditions: goal.blockingConditions ?? [], stoppingConditions: goal.stoppingConditions ?? [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return FloeDigest.sha256Hex(try encoder.encode(definition))
    }
}
