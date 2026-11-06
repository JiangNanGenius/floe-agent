import XCTest
@testable import FloeCanvasCore

final class IdentityTests: XCTestCase {
    func testCopyRemapsIDsAndInternalLinks() {
        let a = CanvasNodeSnapshot(
            content: .text("a"),
            frame: CanvasGeometry.Frame(center: .zero, size: .init(width: 10, height: 10))
        )
        let b = CanvasNodeSnapshot(
            content: .text("b"),
            frame: CanvasGeometry.Frame(center: .zero, size: .init(width: 10, height: 10)),
            groupID: nil,
            createdByRunID: UUID()
        )
        let group = CanvasGroupRecord(name: "G", memberNodeIDs: [a.id, b.id])
        let connection = CanvasConnectionSnapshot(
            sourceNodeID: a.id, destinationNodeID: b.id, kind: .generatedFrom)
        let scene = CanvasSceneRecord(
            name: "S", focusedNodeIDs: [a.id], focusedRegionIDs: [])
        let region = CanvasRegionRecord(
            name: "R",
            frame: CanvasGeometry.Frame(center: .zero, size: .init(width: 1, height: 1)))
        var page = CanvasPageSnapshot(nodes: [a, b])
        page.groups = [group]
        page.connections = [connection]
        page.scenes = [scene]
        page.regions = [region]
        page.strokes = [CanvasStrokeSnapshot(points: [.zero])]
        let snapshot = CanvasSnapshot(
            name: "Orig", pages: [page],
            viewports: [page.id: CanvasViewport()],
            revision: 9
        )

        let copy = CanvasIdentityMapper.copy(snapshot)

        // Fresh top-level identity and revision reset.
        XCTAssertNotEqual(copy.snapshot.id, snapshot.id)
        XCTAssertEqual(copy.snapshot.revision, 0)

        // All durable IDs remapped, no collisions with originals.
        let originalNodeIDs = Set(page.nodes.map(\.id))
        let copiedNodeIDs = Set(copy.snapshot.pages[0].nodes.map(\.id))
        XCTAssertTrue(originalNodeIDs.intersection(copiedNodeIDs).isEmpty)
        XCTAssertEqual(copiedNodeIDs.count, 2)

        // Internal links follow the remap.
        let copiedA = copy.snapshot.pages[0].nodes.first { $0.id == copy.idMapping[a.id] }
        let copiedB = copy.snapshot.pages[0].nodes.first { $0.id == copy.idMapping[b.id] }
        XCTAssertNotNil(copiedA)
        XCTAssertNotNil(copiedB)
        XCTAssertEqual(copy.snapshot.pages[0].groups[0].memberNodeIDs,
                       [copiedA!.id, copiedB!.id])
        XCTAssertEqual(copy.snapshot.pages[0].connections[0].sourceNodeID, copiedA!.id)
        XCTAssertEqual(copy.snapshot.pages[0].connections[0].destinationNodeID, copiedB!.id)
        XCTAssertEqual(copy.snapshot.pages[0].scenes[0].focusedNodeIDs, [copiedA!.id])
        XCTAssertEqual(copy.snapshot.selectedPageID, copy.idMapping[page.id])

        // Active run ownership is discarded.
        XCTAssertNil(copiedB!.createdByRunID)
    }

    func testCopyFlowRemapsEdgesAndDropsRunWiring() {
        let outPort = FlowPort(
            name: "out", dataType: .string, direction: .output)
        let inPort = FlowPort(
            name: "in", dataType: .string, direction: .input)
        let source = FlowNode(kind: .source, name: "s", ports: [outPort])
        let sink = FlowNode(
            kind: .output, name: "o", ports: [inPort],
            subgraphTemplateID: UUID())
        let edge = FlowEdge(
            sourceNodeID: source.id, sourcePortID: outPort.id,
            destinationNodeID: sink.id, destinationPortID: inPort.id)
        let variable = FlowVariable(
            name: "v", dataType: .string, ownerNodeID: source.id)
        let graph = FlowGraph(nodes: [source, sink], edges: [edge], variables: [variable])

        let copy = CanvasIdentityMapper.copyFlow(graph)
        XCTAssertNotEqual(copy.graph.id, graph.id)
        XCTAssertEqual(copy.graph.edges[0].sourceNodeID, copy.idMapping[source.id])
        XCTAssertEqual(copy.graph.edges[0].destinationNodeID, copy.idMapping[sink.id])
        XCTAssertEqual(copy.graph.edges[0].sourcePortID, copy.idMapping[outPort.id])
        XCTAssertEqual(copy.graph.variables[0].ownerNodeID, copy.idMapping[source.id])
        // External registry definitions are shared until explicitly forked.
        XCTAssertEqual(copy.graph.nodes[1].subgraphTemplateID, sink.subgraphTemplateID)
        XCTAssertEqual(copy.graph.nodes[0].ports[0].id, copy.graph.edges[0].sourcePortID)
        XCTAssertEqual(copy.graph.nodes[1].ports[0].id, copy.graph.edges[0].destinationPortID)
        XCTAssertNotEqual(copy.graph.variables[0].id, variable.id)
        XCTAssertTrue(FlowGraphValidator.validate(copy.graph).filter { $0.severity == .error }.isEmpty)
    }
    func testStructuredCopyRewritesForwardReferencesAndPreservesTemplateRegistry() throws {
        let graphID = UUID(), templateID = UUID()
        let output = FlowPort(name: "out", dataType: .number, direction: .output)
        let source = FlowNode(kind: .source, name: "Source", ports: [output])
        let branchPort = FlowPort(name: "yes", dataType: .number, direction: .output)
        let test = FlowPredicate.comparison(.greaterThan,
            lhs: .nodeOutput(nodeID: source.id, portName: "out"), rhs: .literal(.number(0)))
        let branch = FlowConditionBranch(predicate: test, outputPortID: branchPort.id)
        let condition = FlowNode(kind: .condition, name: "Condition", ports: [branchPort], branches: [branch])
        let stopWhen = try JSONFidelity.parse(JSONEncoder().encode(test))
        let binding = try JSONFidelity.parse(JSONEncoder().encode(FlowOperand.nodeOutput(nodeID: source.id, portName: "out")))
        let child = FlowNode(kind: .subgraph, name: "Reusable",
            parameters: ["inputBindings": .object(["input": binding])], subgraphTemplateID: templateID,
            group: .init(id: templateID, name: "External template"))
        let loop = FlowNode(kind: .loop, name: "Loop", parameters: ["stopWhen": stopWhen], bodyNodeIDs: [child.id])
        let variable = FlowVariable(name: "global", dataType: .number, ownerNodeID: graphID, initial: .number(1))
        let graph = FlowGraph(id: graphID, revision: 12, nodes: [loop, condition, child, source], variables: [variable])
        let result = CanvasIdentityMapper.copyFlow(graph)
        XCTAssertEqual(result.graph.revision, 0)
        XCTAssertEqual(result.idMapping[graphID], result.graph.id)
        let copiedLoop = result.graph.nodes[0], copiedCondition = result.graph.nodes[1], copiedChild = result.graph.nodes[2]
        XCTAssertEqual(copiedLoop.bodyNodeIDs, [result.idMapping[child.id]!])
        XCTAssertEqual(copiedCondition.branches?.first?.id, result.idMapping[branch.id])
        XCTAssertEqual(copiedCondition.branches?.first?.outputPortID, copiedCondition.ports[0].id)
        let expected = FlowPredicate.comparison(.greaterThan,
            lhs: .nodeOutput(nodeID: result.idMapping[source.id]!, portName: "out"), rhs: .literal(.number(0)))
        XCTAssertEqual(copiedCondition.branches?.first?.predicate, expected)
        let copiedStop = try JSONDecoder().decode(FlowPredicate.self,
            from: JSONFidelity.serialize(copiedLoop.parameters["stopWhen"]!))
        XCTAssertEqual(copiedStop, expected)
        let copiedBinding = try JSONDecoder().decode(FlowOperand.self,
            from: JSONFidelity.serialize(copiedChild.parameters["inputBindings"]!.objectValue!["input"]!))
        XCTAssertEqual(copiedBinding, .nodeOutput(nodeID: result.idMapping[source.id]!, portName: "out"))
        XCTAssertEqual(copiedChild.subgraphTemplateID, templateID)
        XCTAssertEqual(copiedChild.group?.id, templateID)
        XCTAssertNil(result.idMapping[templateID])
        XCTAssertEqual(result.graph.variables[0].id, result.idMapping[variable.id])
        XCTAssertEqual(result.graph.variables[0].ownerNodeID, result.graph.id)
    }

    func testCopyKeepsHostSourceIdentityAndCopiesOwnedAnnotations() {
        let sourceID = UUID()
        let annotation = CanvasSourceAnnotation(author: "User", text: "Keep this")
        let node = CanvasNodeSnapshot(id: sourceID, content: .text("Reference"),
            frame: .init(center: .zero, size: .init(width: 100, height: 100)),
            source: .init(sourceID: sourceID, usedRevision: 5, annotations: [annotation]))
        let original = CanvasSnapshot(name: "Source ownership", pages: [CanvasPageSnapshot(nodes: [node])])
        let result = CanvasIdentityMapper.copy(original)
        let copied = result.snapshot.pages[0].nodes[0]
        XCTAssertNotEqual(copied.id, node.id)
        XCTAssertEqual(copied.source?.sourceID, sourceID)
        XCTAssertEqual(copied.source?.usedRevision, 5)
        XCTAssertEqual(copied.source?.annotations[0].text, annotation.text)
        XCTAssertNotEqual(copied.source?.annotations[0].id, annotation.id)
    }

}
