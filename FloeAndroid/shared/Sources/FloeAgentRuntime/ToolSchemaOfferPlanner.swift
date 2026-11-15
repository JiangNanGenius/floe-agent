// FloeAgentRuntime — complete-schema admission under the real model window.
//
// A tool definition is a JSON Schema. A schema cut to fit a budget is not a
// smaller capability: required fields, nested objects and enum constraints can
// disappear, and the model then emits arguments the executor must reject. The
// only correct response to an over-budget schema set is to offer FEWER
// COMPLETE definitions and keep discovery available for the rest.
//
// This planner replaces the former fixed 23-tool / 23-KB presentation cap.
// The caller measures the actual request allowance (model window minus output
// reservation, conversation, images, replayed evidence and a bounded
// tool-result reserve) and passes it here. Admission is deterministic:
//   * the discovery schema (when requested) is admitted first,
//   * the always-available metadata helpers follow,
//   * explicitly activated / pinned definitions come next,
//   * optional core helpers and the remaining candidates follow.
// A definition that cannot fit even alone is reported as `oversized` for
// itself and is never replaced by a sliced schema.

import Foundation
import FloeTools

enum ToolSchemaOfferPlanner {
    struct Plan: Sendable, Equatable {
        var offered: [ToolCatalog.Descriptor]
        var deferred: [String]
        /// Definitions that cannot fit even alone. They are not offered by
        /// this request; the model must not be told the capability is
        /// missing, only that this window cannot carry the definition.
        var oversized: [String]
        var estimatedTokens: Int

        /// Descriptors are not Equatable; admission identity is the ordered
        /// set of complete definition names plus the reported counts.
        static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.offered.map(\.name) == rhs.offered.map(\.name)
                && lhs.deferred == rhs.deferred
                && lhs.oversized == rhs.oversized
                && lhs.estimatedTokens == rhs.estimatedTokens
        }
    }

    /// Heuristic token cost of one rendered definition. Deliberately the same
    /// mixed-script shape as `ContextTokenEstimator`; this value shapes
    /// admission only and is never presented as billing usage.
    static func tokenCost(
        name: String,
        description: String,
        parametersJSON: String
    ) -> Int {
        func estimate(_ text: String) -> Int {
            guard !text.isEmpty else { return 0 }
            return max(1, (text.utf8.count + 2) / 3)
        }
        return estimate(name) + estimate(description) + estimate(parametersJSON) + 8
    }

    static func tokenCost(_ descriptor: ToolCatalog.Descriptor) -> Int {
        tokenCost(
            name: descriptor.name,
            description: descriptor.toolDescription,
            parametersJSON: descriptor.parametersJSON
        )
    }

    /// Admits complete definitions only. `alwaysKeep` and `discoveryName` are
    /// ordering hints, not a permission or a guarantee: if a definition does
    /// not fit the real allowance it is reported honestly, never sliced.
    static func plan(
        descriptors: [ToolCatalog.Descriptor],
        tokenBudget: Int,
        alwaysKeep: Set<String> = [],
        discoveryName: String? = nil
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

        // One complete, enabled discovery schema must precede even optional
        // metadata helpers. This changes ordering only when explicitly asked.
        if let discoveryName,
           let discovery = descriptors.first(where: { $0.name == discoveryName }) {
            admit(discovery)
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

    /// Orders the progressive candidate set so pinned and explicitly
    /// activated definitions are admitted before optional core helpers. This
    /// is the fix for a large explicitly requested schema being silently
    /// dropped behind small helpful defaults even when the window has room.
    static func prioritized(
        _ descriptors: [ToolCatalog.Descriptor],
        priority: [String],
        pinned: Set<String>,
        coreNames: Set<String> = []
    ) -> [ToolCatalog.Descriptor] {
        let ranks = Dictionary(priority.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: min)
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

    /// Keeps the previous wire order for admitted definitions that survive,
    /// then appends newly admitted definitions in their admission order. A
    /// stable prefix preserves provider prompt-cache reuse across turns;
    /// a newly discovered tool never reorders the already-cached prefix.
    static func retainingOrder<T>(
        _ admitted: [T],
        after previous: [String],
        name: KeyPath<T, String>
    ) -> [T] {
        guard !previous.isEmpty else { return admitted }
        var remaining = Dictionary(admitted.map { ($0[keyPath: name], $0) },
                                   uniquingKeysWith: { first, _ in first })
        let retained = previous.compactMap { remaining.removeValue(forKey: $0) }
        return retained + admitted.compactMap { remaining.removeValue(forKey: $0[keyPath: name]) }
    }

    /// The ACTUAL room left for complete tool schemas in this request: the
    /// model window minus the output reservation, current messages, images,
    /// replayed pairs and a reserve for the pending tool-result channel.
    /// There is deliberately no fixed byte/tool ceiling here; a large window
    /// may carry a full activated definition, while a small window defers it.
    static func availableTokenBudget(
        contextWindowTokens: Int,
        reservedOutputTokens: Int,
        messageTokens: Int,
        imageTokens: Int,
        replayTokens: Int,
        toolResultReserveTokens: Int,
        minimumDiscoveryTokens: Int = 0
    ) -> Int {
        let window = max(1, contextWindowTokens)
        let fixed = max(0, reservedOutputTokens)
            + max(0, messageTokens)
            + max(0, imageTokens)
            + max(0, replayTokens)
        let remaining = max(0, window - fixed)
        // Borrow only from the provisional tool-result reserve. Messages,
        // images, replay and output reservation are never reduced or ignored.
        let resultReserve = min(
            max(0, toolResultReserveTokens),
            max(0, remaining - max(0, minimumDiscoveryTokens))
        )
        return remaining - resultReserve
    }

    /// Definitions the model actually saw on the previous request but that
    /// this request no longer carries. `eligible` restricts the notice to
    /// real executable catalog names, so a resized discovery/list helper is
    /// never reported as a lost capability.
    static func evicted(
        previous: [String],
        current: [String],
        eligible: Set<String>
    ) -> [String] {
        let currentNames = Set(current)
        var seen = Set<String>()
        return previous.filter {
            eligible.contains($0)
                && !currentNames.contains($0)
                && seen.insert($0).inserted
        }
    }
}

/// One dispatch's actual schema exposure. A fresh instance per provider
/// attempt fences late local-adapter callbacks from a newer request or a
/// sibling run: only names inside the catalog intersection are recorded, and
/// a late callback replaces (not merges with) the prepared order.
final class DispatchedToolSchemaState: @unchecked Sendable {
    private let lock = NSLock()
    private let catalogNames: Set<String>
    private var preparedOrder: [String]

    init(catalogNames: [String] = [], offeredNames: [String] = []) {
        let catalog = Set(catalogNames)
        self.catalogNames = catalog
        self.preparedOrder = Self.filtered(offeredNames, catalog: catalog)
    }

    /// Records the exact schemas the adapter actually prepared for the wire.
    /// Unknown names are dropped: discovery state is presentation metadata,
    /// never a way to claim a capability the run does not offer.
    func recordPrepared(_ names: [String]) {
        let filtered = Self.filtered(names, catalog: catalogNames)
        lock.lock()
        defer { lock.unlock() }
        preparedOrder = filtered
    }

    var offeredNames: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(preparedOrder)
    }

    var offeredOrder: [String] {
        lock.lock()
        defer { lock.unlock() }
        return preparedOrder
    }

    private static func filtered(_ names: [String], catalog: Set<String>) -> [String] {
        var seen = Set<String>()
        return names.filter {
            catalog.contains($0) && seen.insert($0).inserted
        }
    }
}
