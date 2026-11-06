import Foundation

/// Copy/fork identity remapping. Every durable UUID in the copied snapshot
/// gets a fresh stable ID, every internal link (group membership, relation
/// endpoints and flow node wiring) is
/// rewritten to the new IDs, and active run ownership is discarded: a copy
/// never inherits a live run, a provider job, or a task binding.
public enum CanvasIdentityMapper {
    public struct CopyResult: Hashable, Sendable {
        public var snapshot: CanvasSnapshot
        /// Old → new identity for every remapped durable ID.
        public var idMapping: [UUID: UUID]
    }

    /// Copies a snapshot. `newSnapshotID` defaults to a fresh UUID; pass a
    /// stable one when the host needs a deterministic fork (e.g. retry).
    public static func copy(
        _ snapshot: CanvasSnapshot,
        newSnapshotID: UUID = UUID()
    ) -> CopyResult {
        var mapping: [UUID: UUID] = [:]
        func remap(_ id: UUID) -> UUID {
            if let existing = mapping[id] { return existing }
            let fresh = UUID()
            mapping[id] = fresh
            return fresh
        }

        var copy = snapshot
        copy.id = newSnapshotID
        copy.revision = 0
        /// Old flow-graph ID → that graph's internal old→new mapping, kept
        /// across pages so card-binding metadata can be remapped afterwards
        /// (bindings may point across pages).
        var flowMappings: [UUID: [UUID: UUID]] = [:]
        for pageIndex in copy.pages.indices {
            var page = copy.pages[pageIndex]
            page.id = remap(page.id)

            for graphIndex in page.flowGraphs.indices {
                let oldGraphID = page.flowGraphs[graphIndex].id
                let copied = copyFlow(page.flowGraphs[graphIndex])
                page.flowGraphs[graphIndex] = copied.graph
                mapping.merge(copied.idMapping) { current, _ in current }
                flowMappings[oldGraphID] = copied.idMapping
                mapping[oldGraphID] = copied.graph.id
            }

            for nodeIndex in page.nodes.indices {
                var node = page.nodes[nodeIndex]
                let oldID = node.id
                node.id = remap(oldID)
                if let groupID = node.groupID { node.groupID = remap(groupID) }
                if let regionID = node.regionID { node.regionID = remap(regionID) }
                // Sources, immutable assets and editor projects are host identities.
                // Copy annotations owned by the card, keeping source provenance stable.
                if var source = node.source {
                    source.annotations = source.annotations.map { annotation in
                        var copied = annotation
                        copied.id = remap(annotation.id)
                        return copied
                    }
                    node.source = source
                }
                // Active run ownership never crosses a copy boundary.
                node.createdByRunID = nil
                page.nodes[nodeIndex] = node
            }

            for connectionIndex in page.connections.indices {
                var connection = page.connections[connectionIndex]
                connection.id = remap(connection.id)
                connection.sourceNodeID = remap(connection.sourceNodeID)
                connection.destinationNodeID = remap(connection.destinationNodeID)
                page.connections[connectionIndex] = connection
            }

            for groupIndex in page.groups.indices {
                var group = page.groups[groupIndex]
                group.id = remap(group.id)
                group.memberNodeIDs = group.memberNodeIDs.map(remap)
                page.groups[groupIndex] = group
            }

            for regionIndex in page.regions.indices {
                var region = page.regions[regionIndex]
                region.id = remap(region.id)
                page.regions[regionIndex] = region
            }

            for sceneIndex in page.scenes.indices {
                var scene = page.scenes[sceneIndex]
                scene.id = remap(scene.id)
                scene.focusedNodeIDs = scene.focusedNodeIDs.map(remap)
                scene.focusedRegionIDs = scene.focusedRegionIDs.map(remap)
                page.scenes[sceneIndex] = scene
            }

            for strokeIndex in page.strokes.indices {
                var stroke = page.strokes[strokeIndex]
                stroke.id = remap(stroke.id)
                page.strokes[strokeIndex] = stroke
            }
            copy.pages[pageIndex] = page
        }

        // Flow-visual card bindings follow the copied graph and flow-node
        // identities (post-pass: bindings may reference graphs on any page).
        for pageIndex in copy.pages.indices {
            for nodeIndex in copy.pages[pageIndex].nodes.indices {
                var node = copy.pages[pageIndex].nodes[nodeIndex]
                guard let binding = CanvasFlowCardBinding(
                    metadata: node.metadata) else { continue }
                var remapped = binding
                if let newGraphID = mapping[binding.graphID] {
                    remapped.graphID = newGraphID
                }
                if let flowMapping = flowMappings[binding.graphID],
                   let newFlowNodeID = flowMapping[binding.nodeID] {
                    remapped.nodeID = newFlowNodeID
                }
                var metadata = node.metadata
                remapped.applied(to: &metadata)
                node.metadata = metadata
                copy.pages[pageIndex].nodes[nodeIndex] = node
            }
        }

        // Flow-source locators that pointed INTO the copied canvas follow
        // the copy (external canvas locators are left untouched). This runs
        // after every durable ID above has its fresh mapping.
        for pageIndex in copy.pages.indices {
            for graphIndex in copy.pages[pageIndex].flowGraphs.indices {
                for nodeIndex in copy.pages[pageIndex]
                    .flowGraphs[graphIndex].nodes.indices {
                    var flowNode = copy.pages[pageIndex]
                        .flowGraphs[graphIndex].nodes[nodeIndex]
                    guard flowNode.kind == .source else { continue }
                    guard let canvasLiteral = flowNode.parameters[
                        CanvasFlowSourceParameterKey.canvasID]?.stringValue,
                        UUID(uuidString: canvasLiteral) == snapshot.id else {
                        continue
                    }
                    flowNode.parameters[CanvasFlowSourceParameterKey.canvasID] =
                        .string(copy.id.uuidString)
                    if let pageLiteral = flowNode.parameters[
                        CanvasFlowSourceParameterKey.pageID]?.stringValue,
                        let oldPageID = UUID(uuidString: pageLiteral),
                        let newPageID = mapping[oldPageID] {
                        flowNode.parameters[CanvasFlowSourceParameterKey.pageID] =
                            .string(newPageID.uuidString)
                    }
                    if let nodeLiteral = flowNode.parameters[
                        CanvasFlowSourceParameterKey.nodeID]?.stringValue,
                        let oldNodeID = UUID(uuidString: nodeLiteral),
                        let newNodeID = mapping[oldNodeID] {
                        flowNode.parameters[CanvasFlowSourceParameterKey.nodeID] =
                            .string(newNodeID.uuidString)
                    }
                    copy.pages[pageIndex].flowGraphs[graphIndex]
                        .nodes[nodeIndex] = flowNode
                }
            }
        }

        var viewports: [UUID: CanvasViewport] = [:]
        for (pageID, viewport) in copy.viewports {
            viewports[remap(pageID)] = viewport
        }
        copy.viewports = viewports
        copy.selectedPageID = remap(copy.selectedPageID)
        return CopyResult(snapshot: copy, idMapping: mapping)
    }

    /// Copies owned graph/node/port/edge/branch/variable identities consistently.
    /// Host template registry identities stay unchanged; forking their definitions
    /// is an explicit host operation, never a random replacement UUID.
    public static func copyFlow(
        _ graph: FlowGraph,
        newGraphID: UUID = UUID()
    ) -> (graph: FlowGraph, idMapping: [UUID: UUID]) {
        var mapping: [UUID: UUID] = [graph.id: newGraphID]
        func allocate(_ id: UUID) {
            if mapping[id] == nil { mapping[id] = UUID() }
        }
        // Allocate before rewriting any forward references.
        for node in graph.nodes {
            allocate(node.id)
            for port in node.ports { allocate(port.id) }
            for branch in node.branches ?? [] { allocate(branch.id) }
        }
        for edge in graph.edges { allocate(edge.id) }
        for variable in graph.variables { allocate(variable.id) }
        func mapped(_ id: UUID) -> UUID { mapping[id] ?? id }
        func operand(_ value: FlowOperand) -> FlowOperand {
            switch value {
            case .nodeOutput(let id, let port): return .nodeOutput(nodeID: mapped(id), portName: port)
            default: return value
            }
        }
        func predicate(_ value: FlowPredicate) -> FlowPredicate {
            switch value {
            case .comparison(let comparator, let lhs, let rhs):
                return .comparison(comparator, lhs: operand(lhs), rhs: operand(rhs))
            case .and(let values): return .and(values.map(predicate))
            case .or(let values): return .or(values.map(predicate))
            case .not(let value): return .not(predicate(value))
            }
        }
        func rewrite<T: Codable>(_ raw: JSONValue, as type: T.Type,
                                  using transform: (T) -> T) -> JSONValue {
            // Malformed future parameters remain recoverable and are diagnosed
            // by the compiler. Never blindly replace UUID-looking user content.
            do {
                let value = try JSONDecoder().decode(T.self, from: JSONFidelity.serialize(raw))
                return try JSONFidelity.parse(JSONEncoder().encode(transform(value)))
            } catch { return raw }
        }
        var copy = graph
        copy.id = newGraphID
        copy.revision = 0
        for index in copy.nodes.indices {
            var node = copy.nodes[index]
            node.id = mapped(node.id)
            node.ports = node.ports.map { port in
                var copied = port
                copied.id = mapped(port.id)
                return copied
            }
            node.bodyNodeIDs = node.bodyNodeIDs?.map(mapped)
            node.branches = node.branches?.map { branch in
                var copied = branch
                copied.id = mapped(branch.id)
                copied.outputPortID = mapped(branch.outputPortID)
                copied.predicate = predicate(branch.predicate)
                return copied
            }
            if var script = node.script {
                script.signature = script.signature.map { port in
                    var copied = port
                    copied.id = mapped(port.id)
                    return copied
                }
                node.script = script
            }
            if let stopWhen = node.parameters["stopWhen"] {
                node.parameters["stopWhen"] = rewrite(stopWhen, as: FlowPredicate.self, using: predicate)
            }
            if let inputs = node.parameters["inputBindings"]?.objectValue {
                node.parameters["inputBindings"] = .object(inputs.mapValues {
                    rewrite($0, as: FlowOperand.self, using: operand)
                })
            }
            // subgraphTemplateID/group describe host registry definitions,
            // not owned instances; preserve both unless the host forks them.
            copy.nodes[index] = node
        }
        for index in copy.edges.indices {
            var edge = copy.edges[index]
            edge.id = mapped(edge.id)
            edge.sourceNodeID = mapped(edge.sourceNodeID)
            edge.sourcePortID = mapped(edge.sourcePortID)
            edge.destinationNodeID = mapped(edge.destinationNodeID)
            edge.destinationPortID = mapped(edge.destinationPortID)
            copy.edges[index] = edge
        }
        for index in copy.variables.indices {
            copy.variables[index].id = mapped(copy.variables[index].id)
            copy.variables[index].ownerNodeID = mapped(copy.variables[index].ownerNodeID)
        }
        return (copy, mapping)
    }
}
