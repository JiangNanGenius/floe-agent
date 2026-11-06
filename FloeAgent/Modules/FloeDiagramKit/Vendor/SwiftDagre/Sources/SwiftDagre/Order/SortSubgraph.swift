// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

/// Sorts nodes within a subgraph using barycenter heuristic
public enum SortSubgraph {

    /// Result of subgraph sorting
    public struct Result {
        public var vs: [String]
        public var barycenter: Double?
        public var weight: Int

        public init(vs: [String] = [], barycenter: Double? = nil, weight: Int = 0) {
            self.vs = vs
            self.barycenter = barycenter
            self.weight = weight
        }
    }

    /// Entry after resolve conflicts - has vs array instead of single v
    /// Matches TypeScript return type from resolve-conflicts.js
    struct ResolvedEntry {
        var vs: [String]
        var i: Int
        var barycenter: Double?
        var weight: Int
    }

    /// Sorts a layer graph recursively from the given root node
    /// This version works with layer graphs (BuildLayerGraph.LayerNodeLabel)
    public static func sortLayerGraph(
        _ g: Graph<BuildLayerGraph.LayerNodeLabel, BuildLayerGraph.LayerEdgeLabel>,
        v: String,
        cg: Graph<Void, Void>,
        biasRight: Bool
    ) -> Result {
        // Get movable children (exclude border nodes)
        var movable = g.children(v) ?? []
        let nodeLabel = g.node(v)

        // In layer graphs, borderLeft/borderRight are single node IDs (for this rank)
        let bl = nodeLabel?.borderLeft
        let br = nodeLabel?.borderRight

        if let bl = bl, let br = br {
            movable = movable.filter { $0 != bl && $0 != br }
        }

        // Calculate barycenters for movable nodes (with original indices)
        var entries = calculateLayerBarycenters(g, movable: movable)
        var subgraphs: [String: Result] = [:]

        // Recursively sort child subgraphs
        for i in 0..<entries.count {
            let entryV = entries[i].v
            if let children = g.children(entryV), !children.isEmpty {
                let subgraphResult = sortLayerGraph(g, v: entryV, cg: cg, biasRight: biasRight)
                subgraphs[entryV] = subgraphResult

                if subgraphResult.barycenter != nil {
                    mergeBarycenters(&entries[i], other: subgraphResult)
                }
            }
        }

        // Resolve conflicts using constraint graph
        let resolved = resolveConflicts(entries, cg: cg)

        // Sort entries by barycenter
        let sorted = sortEntries(resolved, biasRight: biasRight)

        // Expand subgraph results
        let expandedVs = sorted.flatMap { v -> [String] in
            if let subResult = subgraphs[v] {
                return subResult.vs
            }
            return [v]
        }

        // Build result with borders
        var result = Result(vs: expandedVs)

        if let bl = bl, let br = br {
            result.vs = [bl] + result.vs + [br]

            // Update barycenter to include border nodes
            if let preds = g.predecessors(bl), !preds.isEmpty,
               let blPred = g.node(preds[0]),
               let brPreds = g.predecessors(br), !brPreds.isEmpty,
               let brPred = g.node(brPreds[0]) {

                if result.barycenter == nil {
                    result.barycenter = 0
                    result.weight = 0
                }

                let bc = result.barycenter ?? 0
                let weight = result.weight
                let blOrder = blPred.order
                let brOrder = brPred.order

                result.barycenter = (bc * Double(weight) + Double(blOrder + brOrder)) / Double(weight + 2)
                result.weight = weight + 2
            }
        }

        // Calculate final barycenter from resolved entries if not set
        if result.barycenter == nil {
            var totalSum: Double = 0
            var totalWeight: Int = 0
            for entry in resolved {
                if let bc = entry.barycenter {
                    totalSum += bc * Double(entry.weight)
                    totalWeight += entry.weight
                }
            }
            if totalWeight > 0 {
                result.barycenter = totalSum / Double(totalWeight)
                result.weight = totalWeight
            }
        }

        return result
    }

    /// Calculates barycenters for nodes in a layer graph
    /// Includes original index (i) for each entry
    private static func calculateLayerBarycenters(
        _ g: Graph<BuildLayerGraph.LayerNodeLabel, BuildLayerGraph.LayerEdgeLabel>,
        movable: [String]
    ) -> [Barycenter.Entry] {
        return movable.enumerated().map { (index, v) in
            guard let inEdges = g.inEdges(v), !inEdges.isEmpty else {
                return Barycenter.Entry(v: v, i: index)
            }

            var sum: Double = 0
            var weight: Int = 0

            for edge in inEdges {
                let neighbor = edge.v
                guard let neighborLabel = g.node(neighbor) else { continue }
                let edgeWeight = g.edge(edge.id)?.weight ?? 1

                sum += Double(edgeWeight * neighborLabel.order)
                weight += edgeWeight
            }

            if weight > 0 {
                return Barycenter.Entry(v: v, barycenter: sum / Double(weight), weight: weight, i: index)
            } else {
                return Barycenter.Entry(v: v, i: index)
            }
        }
    }

    /// Merges barycenter from a subgraph result into an entry
    private static func mergeBarycenters(_ entry: inout Barycenter.Entry, other: Result) {
        if let entryBC = entry.barycenter, let otherBC = other.barycenter {
            entry.barycenter = (entryBC * Double(entry.weight) + otherBC * Double(other.weight)) /
                              Double(entry.weight + other.weight)
            entry.weight += other.weight
        } else if let otherBC = other.barycenter {
            entry.barycenter = otherBC
            entry.weight = other.weight
        }
    }

    // MARK: - Resolve Conflicts (resolve-conflicts.js)

    /// Internal class for resolve conflicts algorithm
    private class MappedEntry {
        var indegree: Int = 0
        var `in`: [MappedEntry] = []
        var out: [MappedEntry] = []
        var vs: [String]
        var i: Int
        var barycenter: Double?
        var weight: Int
        var merged: Bool = false

        init(entry: Barycenter.Entry, index: Int) {
            self.vs = [entry.v]
            self.i = index
            self.barycenter = entry.barycenter
            self.weight = entry.weight
        }
    }

    /// Resolves conflicts using constraint graph
    /// Matches TypeScript resolve-conflicts.js
    ///
    /// Given a list of entries of the form {v, barycenter, weight} and a constraint graph,
    /// this function resolves any conflicts between the constraint graph and the barycenters.
    /// If the barycenters for an entry would violate a constraint in the constraint graph
    /// then we coalesce the nodes in the conflict into a new node that respects the constraint
    /// and aggregates barycenter and weight information.
    ///
    /// Returns a new list of entries of the form {vs, i, barycenter, weight}. The list
    /// `vs` may either be a singleton or it may be an aggregation of nodes ordered such
    /// that they do not violate constraints from the constraint graph.
    private static func resolveConflicts(_ entries: [Barycenter.Entry], cg: Graph<Void, Void>) -> [ResolvedEntry] {
        // Build mapped entries indexed by node ID
        var mappedEntries: [String: MappedEntry] = [:]
        for (i, entry) in entries.enumerated() {
            mappedEntries[entry.v] = MappedEntry(entry: entry, index: i)
        }

        // Build the constraint graph relationships
        for edge in cg.edges() {
            guard let entryV = mappedEntries[edge.v],
                  let entryW = mappedEntries[edge.w] else { continue }

            entryW.indegree += 1
            entryV.out.append(entryW)
        }

        // Find sources (entries with no incoming constraints)
        var sourceSet = Array(mappedEntries.values.filter { $0.indegree == 0 })

        // Process in topological order
        var result: [MappedEntry] = []

        func handleIn(_ vEntry: MappedEntry) -> (MappedEntry) -> Void {
            return { uEntry in
                if uEntry.merged { return }

                // Merge if no barycenter or if constraint is violated (uEntry.bc >= vEntry.bc)
                if uEntry.barycenter == nil || vEntry.barycenter == nil ||
                   uEntry.barycenter! >= vEntry.barycenter! {
                    mergeEntries(target: vEntry, source: uEntry)
                }
            }
        }

        func handleOut(_ vEntry: MappedEntry) -> (MappedEntry) -> Void {
            return { wEntry in
                wEntry.in.append(vEntry)
                wEntry.indegree -= 1
                if wEntry.indegree == 0 {
                    sourceSet.append(wEntry)
                }
            }
        }

        while !sourceSet.isEmpty {
            let entry = sourceSet.removeLast()
            result.append(entry)

            // Process incoming entries (reversed to match TypeScript)
            entry.in.reversed().forEach(handleIn(entry))

            // Process outgoing entries
            entry.out.forEach(handleOut(entry))
        }

        // Filter out merged entries and convert to ResolvedEntry
        return result.filter { !$0.merged }.map { entry in
            ResolvedEntry(vs: entry.vs, i: entry.i, barycenter: entry.barycenter, weight: entry.weight)
        }
    }

    /// Merges source entry into target entry
    /// Matches TypeScript mergeEntries in resolve-conflicts.js
    private static func mergeEntries(target: MappedEntry, source: MappedEntry) {
        var sum: Double = 0
        var weight: Int = 0

        if target.weight > 0, let bc = target.barycenter {
            sum += bc * Double(target.weight)
            weight += target.weight
        }

        if source.weight > 0, let bc = source.barycenter {
            sum += bc * Double(source.weight)
            weight += source.weight
        }

        // source.vs comes first (prepended) - matches TypeScript: target.vs = source.vs.concat(target.vs)
        target.vs = source.vs + target.vs
        target.barycenter = weight > 0 ? sum / Double(weight) : nil
        target.weight = weight
        target.i = min(source.i, target.i)
        source.merged = true
    }

    // MARK: - Sort (sort.js)

    /// Sorts entries by barycenter with bias for tie-breaking
    /// Matches TypeScript sort.js algorithm with consumeUnsortable pattern
    private static func sortEntries(_ entries: [ResolvedEntry], biasRight: Bool) -> [String] {
        // Partition into those with and without barycenters
        var sortable: [ResolvedEntry] = []
        var unsortable: [ResolvedEntry] = []

        for entry in entries {
            if entry.barycenter != nil {
                sortable.append(entry)
            } else {
                unsortable.append(entry)
            }
        }

        // Sort unsortable by descending original index (b.i - a.i)
        unsortable.sort { $0.i > $1.i }

        // Sort sortable by barycenter with bias tie-breaker
        sortable.sort { a, b in
            let aBC = a.barycenter ?? 0
            let bBC = b.barycenter ?? 0

            if aBC < bBC {
                return true
            } else if aBC > bBC {
                return false
            }
            // Tie-breaker: by original index
            // If !biasRight: a.i - b.i (ascending)
            // If biasRight: b.i - a.i (descending)
            return biasRight ? a.i > b.i : a.i < b.i
        }

        // Merge sortable and unsortable using consumeUnsortable pattern
        var vs: [[String]] = []
        var vsIndex = 0

        // Consume unsortable entries that should come before first sortable
        vsIndex = consumeUnsortable(&vs, &unsortable, vsIndex)

        // Process each sortable entry
        for entry in sortable {
            vsIndex += entry.vs.count
            vs.append(entry.vs)
            vsIndex = consumeUnsortable(&vs, &unsortable, vsIndex)
        }

        // Flatten result
        return vs.flatMap { $0 }
    }

    /// Consumes unsortable entries that should be inserted at the current position
    /// Matches TypeScript consumeUnsortable function in sort.js
    private static func consumeUnsortable(_ vs: inout [[String]], _ unsortable: inout [ResolvedEntry], _ index: Int) -> Int {
        var currentIndex = index
        while let last = unsortable.last, last.i <= currentIndex {
            unsortable.removeLast()
            vs.append(last.vs)
            currentIndex += 1
        }
        return currentIndex
    }

    // MARK: - Original DagreGraph version (kept for compatibility)

    /// Sorts a subgraph and its children recursively
    /// Uses barycenter heuristic with bias to break ties
    public static func sort(
        _ g: DagreGraph,
        v: String,
        biasRight: Bool
    ) -> Result {
        // Get movable children (exclude border nodes)
        var movable = g.children(v) ?? []
        let nodeLabel = g.node(v)

        // Get the last (highest rank) border nodes from the dictionaries
        let borderLeftDict = nodeLabel?.borderLeft ?? [:]
        let borderRightDict = nodeLabel?.borderRight ?? [:]
        let maxRank = borderLeftDict.keys.max()
        let bl = maxRank.flatMap { borderLeftDict[$0] }
        let br = maxRank.flatMap { borderRightDict[$0] }

        if let bl = bl, let br = br {
            movable = movable.filter { $0 != bl && $0 != br }
        }

        // Calculate barycenters (with original indices)
        var entries = Barycenter.calculate(g, movable: movable)
        // Add original indices
        for i in 0..<entries.count {
            entries[i].i = i
        }

        var subgraphs: [String: Result] = [:]

        // Recursively sort child subgraphs
        for i in 0..<entries.count {
            let entryV = entries[i].v
            if let children = g.children(entryV), !children.isEmpty {
                let subgraphResult = sort(g, v: entryV, biasRight: biasRight)
                subgraphs[entryV] = subgraphResult

                if let subBC = subgraphResult.barycenter {
                    Barycenter.merge(&entries[i], with: Barycenter.Entry(
                        v: entryV,
                        barycenter: subBC,
                        weight: subgraphResult.weight
                    ))
                }
            }
        }

        // Resolve conflicts (using empty constraint graph since this is the DagreGraph version)
        let cg = Graph<Void, Void>()
        let resolved = resolveConflicts(entries, cg: cg)

        // Sort entries by barycenter
        let sorted = sortEntries(resolved, biasRight: biasRight)

        // Expand subgraph results
        let expandedVs = sorted.flatMap { v -> [String] in
            if let subResult = subgraphs[v] {
                return subResult.vs
            }
            return [v]
        }

        // Build result with borders
        var result = Result(vs: expandedVs)

        if let bl = bl, let br = br {
            result.vs = [bl] + result.vs + [br]

            // Update barycenter to include border nodes
            if let preds = g.predecessors(bl), !preds.isEmpty,
               let blPred = g.node(preds[0]),
               let brPreds = g.predecessors(br), !brPreds.isEmpty,
               let brPred = g.node(brPreds[0]) {

                let bc = result.barycenter ?? 0
                let weight = result.weight
                let blOrder = blPred.order
                let brOrder = brPred.order

                result.barycenter = (bc * Double(weight) + Double(blOrder + brOrder)) / Double(weight + 2)
                result.weight = weight + 2
            }
        }

        // Calculate final barycenter from entries
        if result.barycenter == nil {
            var totalSum: Double = 0
            var totalWeight: Int = 0
            for entry in resolved {
                if let bc = entry.barycenter {
                    totalSum += bc * Double(entry.weight)
                    totalWeight += entry.weight
                }
            }
            if totalWeight > 0 {
                result.barycenter = totalSum / Double(totalWeight)
                result.weight = totalWeight
            }
        }

        return result
    }
}
