// FloeAgentRuntime — complete-schema admission under a real model window.
//
// Tool definitions are JSON Schemas. A schema that is cut to fit a budget is
// not a smaller capability: required fields, nested objects and enum
// constraints can disappear, and a model then emits arguments the executor
// must reject. The only correct response to an over-budget schema set is to
// offer FEWER COMPLETE definitions and let the model activate the rest with
// `tools.search` (the full definition enters the next request).
//
// This planner is deterministic: the runtime-virtual tools (search/list/
// paging) are kept first when they fit, then descriptors in the caller's
// existing priority order. A definition larger than the whole allowance is
// reported as `oversized` for itself and never replaced by a sliced schema.

import Foundation
import FloeTools

public enum ToolSchemaOfferPlanner {
    public struct Plan: Sendable, Equatable {
        public var offered: [ToolCatalog.Descriptor]
        public var deferred: [String]
        /// Definitions that cannot fit even alone. They are not offered by
        /// this request; the model must not be told they are missing, only
        /// that this window cannot carry the definition.
        public var oversized: [String]
        public var estimatedTokens: Int

        /// Descriptors are not Equatable; admission identity is the ordered
        /// set of complete definition names plus the reported counts.
        public static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.offered.map(\.name) == rhs.offered.map(\.name)
                && lhs.deferred == rhs.deferred
                && lhs.oversized == rhs.oversized
                && lhs.estimatedTokens == rhs.estimatedTokens
        }
    }

    /// Heuristic token cost of one rendered definition. Deliberately the same
    /// mixed-script shape as the runtime estimator; this value shapes
    /// admission only and is never presented as billing usage.
    public static func tokenCost(_ descriptor: ToolCatalog.Descriptor) -> Int {
        func estimate(_ text: String) -> Int {
            guard !text.isEmpty else { return 0 }
            return max(1, (text.utf8.count + 2) / 3)
        }
        return estimate(descriptor.name)
            + estimate(descriptor.toolDescription)
            + estimate(descriptor.parametersJSON)
            + 8
    }

    public static func plan(
        descriptors: [ToolCatalog.Descriptor],
        tokenBudget: Int,
        alwaysKeep: Set<String> = []
    ) -> Plan {
        let budget = max(0, tokenBudget)
        var offered: [ToolCatalog.Descriptor] = []
        var deferred: [String] = []
        var oversized: [String] = []
        var used = 0
        var seen = Set<String>()
        func admit(_ descriptor: ToolCatalog.Descriptor) {
            guard seen.insert(descriptor.name).inserted else { return }
            let cost = tokenCost(descriptor)
            if cost > budget {
                oversized.append(descriptor.name)
                return
            }
            guard used + cost <= budget else {
                deferred.append(descriptor.name)
                return
            }
            offered.append(descriptor)
            used += cost
        }
        for descriptor in descriptors where alwaysKeep.contains(descriptor.name) {
            admit(descriptor)
        }
        for descriptor in descriptors where !alwaysKeep.contains(descriptor.name) {
            admit(descriptor)
        }
        return Plan(
            offered: offered,
            deferred: deferred,
            oversized: oversized,
            estimatedTokens: used
        )
    }

    /// Orders the progressive candidate set so an explicitly loaded or
    /// requested definition is admitted before optional core descriptors.
    /// This is the fix for a large CAD schema being silently dropped behind
    /// core tools even when the model window has ample room.
    public static func prioritized(
        _ descriptors: [ToolCatalog.Descriptor],
        priority: [String],
        pinned: Set<String>,
        coreNames: Set<String> = []
    ) -> [ToolCatalog.Descriptor] {
        let ranks = Dictionary(priority.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        func rank(_ descriptor: ToolCatalog.Descriptor) -> Int {
            if pinned.contains(descriptor.name) { return 0 }
            if let value = ranks[descriptor.name] { return 1 + value }
            if coreNames.contains(descriptor.name) { return 100_000 }
            return 200_000
        }
        return descriptors.sorted {
            let left = rank($0), right = rank($1)
            return left == right ? $0.name < $1.name : left < right
        }
    }

    /// The ACTUAL room left for complete tool schemas in this request: the
    /// model window minus output reservation, current messages, images,
    /// replayed pairs and a reserve for the pending tool-result channel.
    /// There is deliberately no fixed 8 KiB/23 KiB ceiling here; a large
    /// window may carry the full activated definition, while a small window
    /// defers it honestly.
    public static func availableTokenBudget(
        contextWindowTokens: Int,
        reservedOutputTokens: Int,
        messageTokens: Int,
        imageTokens: Int,
        replayTokens: Int,
        toolResultReserveTokens: Int
    ) -> Int {
        let window = max(1, contextWindowTokens)
        let fixed = max(0, reservedOutputTokens)
            + max(0, messageTokens)
            + max(0, imageTokens)
            + max(0, replayTokens)
            + max(0, toolResultReserveTokens)
        return max(0, window - fixed)
    }
}
