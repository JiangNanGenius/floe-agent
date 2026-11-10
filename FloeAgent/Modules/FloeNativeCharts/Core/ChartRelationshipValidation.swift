// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartValidationContext {
    mutating func validateRelationships(_ d: ChartDocument, path: String, facets: [String]) throws -> Int {
        let p = path + ".data.records"
        switch d.data {
        case .hierarchy(let nodes):
            try chartCheck(!nodes.isEmpty && nodes.count <= ChartLimits.graphNodes,p,"needs 1...256 hierarchy nodes")
            try consume(nodes.count,at:p); try identify(nodes.map(\.id),collection:"nodes",path:p,facets:facets)
            let lookup = Dictionary(uniqueKeysWithValues:nodes.map { ($0.id,$0) })
            for node in nodes {
                try chartText(node.label,p + ".label")
                if let value = node.value { try chartCheck(value.isFinite && value >= 0,p + ".value","hierarchy weights must be finite and nonnegative") }
                if let parent = node.parentID { try chartCheck(parent != node.id && lookup[parent] != nil,p + ".parentID","parent must name another existing node") }
                var seen: Set<String> = [node.id]; var cursor = node.parentID
                while let id = cursor {
                    try chartCheck(seen.insert(id).inserted,p + ".parentID","hierarchy cycle")
                    try chartCheck(seen.count <= ChartLimits.hierarchyDepth,p,"hierarchy depth exceeds 32")
                    cursor = lookup[id]?.parentID
                }
            }
            if d.type != .tree {
                let children = Dictionary(grouping:nodes.filter { $0.parentID != nil },by:{$0.parentID!})
                func total(_ node: HierarchyNode) throws -> Double {
                    if let descendants = children[node.id], !descendants.isEmpty {
                        let result = try descendants.reduce(0.0) { try $0 + total($1) }
                        try chartCheck(result.isFinite,p + ".value","hierarchy total overflow")
                        if let value = node.value { try chartCheck(chartNearlyEqual(value,result),p + ".value","parent value must equal descendants; it is not an extra leaf weight") }
                        return result
                    }
                    guard let value = node.value else { throw ChartIssue(path:p + ".value",problem:"weighted hierarchy leaves need explicit values") }
                    return value
                }
                let sum = try nodes.filter { $0.parentID == nil }.reduce(0.0) { try $0 + total($1) }
                try chartCheck(sum.isFinite && sum > 0,p,"weighted hierarchy needs positive finite leaf total")
            }
            return 1
        case .graph(let graph):
            let nodeIDs = try validateNodes(graph.nodes,path:p,facets:facets)
            try chartCheck(graph.edges.count <= ChartLimits.graphEdges,p + ".edges","at most 1024 edges")
            try consume(graph.edges.count,at:p)
            try identify(graph.edges.map(\.id),collection:"edges",path:p,facets:facets)
            for edge in graph.edges {
                try chartCheck(nodeIDs.contains(edge.source) && nodeIDs.contains(edge.target),p + ".edges","edge references a missing node")
                if let weight = edge.weight { try chartFinite(weight,p + ".edges.weight") }
            }
            // Signed relationships, cycles and isolated nodes are valid here.
            return 1
        case .flow(let flow):
            let nodeIDs = try validateNodes(flow.nodes,path:p,facets:facets)
            try chartCheck(!flow.links.isEmpty && flow.links.count <= ChartLimits.graphEdges,p + ".links","needs 1...1024 flows")
            try consume(flow.links.count,at:p); try identify(flow.links.map(\.id),collection:"links",path:p,facets:facets)
            var input: [String:Double] = [:], output: [String:Double] = [:]
            for link in flow.links {
                try chartCheck(nodeIDs.contains(link.source) && nodeIDs.contains(link.target) && link.source != link.target,p + ".links","flow endpoints must name distinct existing nodes")
                try chartCheck(link.value.isFinite && link.value >= 0,p + ".links.value","flow must be finite and nonnegative")
                input[link.target,default:0] += link.value; output[link.source,default:0] += link.value
            }
            try chartCheck(input.values.allSatisfy(\.isFinite) && output.values.allSatisfy(\.isFinite),p,"flow totals overflow")
            let total = flow.links.reduce(0.0) { $0 + $1.value }
            try chartCheck(total.isFinite && total > 0,p,"flow total must be finite and positive")
            try chartDAG(nodeIDs,links:flow.links.map { ($0.source,$0.target) },path:p)
            for id in nodeIDs where input[id] != nil && output[id] != nil {
                if !chartNearlyEqual(input[id]!,output[id]!) {
                    warnings.append(.init(path:p + ".nodes." + id,problem:"incoming and outgoing flow differ; retain magnitudes instead of fabricating balance"))
                }
            }
            return 1
        case .flowMatrix(let matrix):
            _ = try validateNodes(matrix.nodes,path:p,facets:facets)
            let n = matrix.nodes.count
            try chartCheck(matrix.values.count == n && matrix.values.allSatisfy { $0.count == n },p + ".values","chord matrix must be square and match nodes")
            try consume(n*n,at:p)
            var total = 0.0
            for i in 0..<n { for j in 0..<n {
                let value = matrix.values[i][j]
                try chartCheck(value.isFinite && value >= 0,p + ".values","chord weights must be finite and nonnegative")
                if !matrix.directed { try chartCheck(chartNearlyEqual(value,matrix.values[j][i]),p + ".values","undirected chord matrix must be symmetric") }
                total += value
            } }
            try chartCheck(total.isFinite && total > 0,p,"chord matrix needs positive finite weight")
            return 1
        case .waterfall(let steps):
            try chartCheck(!steps.isEmpty,p,"needs waterfall steps"); try consume(steps.count,at:p)
            try identify(steps.map(\.id),path:p,facets:facets)
            var running = d.options.baseline ?? 0
            for step in steps {
                try chartText(step.label,p + ".label"); try chartFinite(step.value,p + ".value")
                switch step.kind {
                case .delta: running += step.value; try chartFinite(running,p + ".value")
                case .subtotal,.total: try chartCheck(chartNearlyEqual(step.value,running),p + ".value","total must equal preceding deltas and does not add another delta")
                }
            }
            return 1
        case .stages(let stages):
            try chartCheck(!stages.isEmpty,p,"needs funnel stages"); try consume(stages.count,at:p)
            try identify(stages.map(\.id),path:p,facets:facets)
            for stage in stages { try chartText(stage.label,p + ".label"); try chartCheck(stage.value.isFinite && stage.value >= 0,p + ".value","stage values must be finite and nonnegative") }
            try chartCheck(stages.contains { $0.value > 0 },p,"funnel needs positive total")
            return 1
        default: throw ChartIssue(path:p,problem:"not a relationship payload")
        }
    }
    mutating func validateNodes(_ nodes: [ChartNode], path: String, facets: [String]) throws -> Set<String> {
        try chartCheck(!nodes.isEmpty && nodes.count <= ChartLimits.graphNodes,path + ".nodes","needs 1...256 nodes")
        try consume(nodes.count,at:path)
        try identify(nodes.map(\.id),collection:"nodes",path:path,facets:facets)
        for node in nodes { try chartText(node.label,path + ".nodes.label") }
        return Set(nodes.map(\.id))
    }
}

func chartDAG(_ ids: Set<String>, links: [(String,String)], path: String) throws {
    var degrees = Dictionary(uniqueKeysWithValues:ids.map { ($0,0) })
    var targets: [String:[String]] = [:]
    for (from,to) in links { degrees[to,default:0] += 1; targets[from,default:[]].append(to) }
    var queue = ids.filter { degrees[$0] == 0 }.sorted(); var position = 0
    while position < queue.count {
        let node = queue[position]; position += 1
        for target in targets[node] ?? [] {
            degrees[target,default:0] -= 1
            if degrees[target] == 0 { queue.append(target) }
        }
    }
    try chartCheck(position == ids.count,path,"directed cycle is not supported for Sankey/dependencies; no substitute chart is produced")
}
