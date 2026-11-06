// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeDiagramCore
@testable import FloeDiagramLayout

@Suite struct LayoutTests {
    @Test func allStructuresProduceFiniteDistinctLayouts() throws {
        let document = DiagramExamples.library()
        var unique: Set<[UUID: DiagramRect]> = []
        for structure in DiagramStructure.allCases {
            var page = document.pages[0]; page.structure = structure
            let result = try DiagramLayoutEngine.layout(page)
            #expect(result.frames.count == page.elements.count)
            #expect(result.frames.values.allSatisfy { $0.isValid })
            unique.insert(result.frames)
        }
        #expect(unique.count >= 6)
    }
    @Test func treeDoesNotOverlapRichMeasuredCards() throws {
        let page = DiagramExamples.large(count: 500, rich: true).pages[0]
        let result = try DiagramLayoutEngine.layout(page)
        let frames = Array(result.frames.values)
        for i in frames.indices {
            for j in frames.indices where j > i { #expect(!frames[i].insetBy(1).intersects(frames[j].insetBy(1))) }
        }
    }
    @Test func automaticBranchesStayVisibleBesideExpandedSiblingCards() throws {
        for structure in [DiagramStructure.balanced,.left,.right,.organization] {
            var page = DiagramExamples.library().pages[0]
            page.structure = structure
            let result = try DiagramLayoutEngine.layout(page)
            for edge in result.edges {
                guard case .branch = edge.id else { continue }
                let points = edge.polyline(steps: 80)
                let blocked = result.frames.filter { id,frame in
                    id != edge.from && id != edge.to && zip(points,points.dropFirst()).contains { !DiagramRouter.clear($0.0,$0.1,obstacles: [frame]) }
                }.keys.compactMap { id in page.elements.first { $0.id == id }?.title }
                #expect(blocked.isEmpty,"Branch \(edge.from) to \(edge.to) must stay visible in \(structure); blockers: \(blocked)")
            }
        }
    }
    @Test func flowCyclesDisconnectedPackingAndPinnedFrames() throws {
        var page = DiagramPage(structure: .flow)
        let a = DiagramElement(kind: .rectangle, title: "a"), b = DiagramElement(kind: .diamond, title: "b"), c = DiagramElement(kind: .ellipse, title: "c")
        page.elements = [a, b, c]; page.connections = [.init(from: a.id, to: b.id, kind: .flow), .init(from: b.id, to: a.id, kind: .flow)]
        let layout = try DiagramLayoutEngine.layout(page)
        #expect(layout.frames.count == 3)
        #expect(!layout.frames[a.id]!.intersects(layout.frames[c.id]!))
        page.elements[0].frame = .init(x: 500, y: 500)
        let pinned = try DiagramLayoutEngine.layout(page)
        #expect(pinned.frames[a.id] == page.elements[0].frame)
    }
    @Test func collapseRetargetsAssociationsWithoutDeletingOriginalEdges() throws {
        var page = DiagramExamples.library().pages[0]
        page.elements[2].collapsed = true
        page.connections.append(.init(from: page.elements[5].id, to: page.elements[3].id, label: "hidden topic"))
        let layout = try DiagramLayoutEngine.layout(page)
        #expect(layout.frames[page.elements[5].id] == nil)
        #expect(layout.edges.last?.from == page.elements[2].id)
        #expect(page.connections.last?.from == page.elements[5].id)
    }
    @Test func orthogonalRoutingAvoidsBlockingShape() throws {
        let a = DiagramElement(kind: .rectangle, title: "a", frame: .init(x: 0, y: 80, width: 100, height: 60))
        let b = DiagramElement(kind: .rectangle, title: "b", frame: .init(x: 500, y: 80, width: 100, height: 60))
        let obstacle = DiagramElement(kind: .rectangle, title: "block", frame: .init(x: 210, y: 35, width: 150, height: 150))
        let edge = DiagramConnection(from: a.id, to: b.id, kind: .flow, route: .orthogonal, endArrow: true)
        let page = DiagramPage(structure: .flow, elements: [a, b, obstacle], connections: [edge])
        let result = try DiagramLayoutEngine.layout(page), line = result.edges[0].polyline(steps: 32)
        #expect(!result.edges[0].routingFailed)
        for (start, end) in zip(line, line.dropFirst()) { #expect(DiagramRouter.clear(start, end, obstacles: [obstacle.frame!.insetBy(-1)])) }
        #expect(result.edges[0].start == .init(x: 100, y: 110))
        #expect(result.edges[0].end == .init(x: 500, y: 110))
    }
    @Test func manualPathsSelfLoopsLabelsAndHitRegions() throws {
        let a = DiagramElement(kind: .rectangle, title: "a", frame: .init(x: 0, y: 0))
        let b = DiagramElement(kind: .rectangle, title: "b", frame: .init(x: 400, y: 0))
        let e = DiagramConnection(from: a.id, to: b.id, route: .orthogonal, waypoints: [.init(x: 200, y: -60), .init(x: 300, y: -60)], label: "manual", labelPosition: 0.3)
        let page = DiagramPage(elements: [a, b], connections: [e, .init(from: a.id, to: a.id)])
        let result = try DiagramLayoutEngine.layout(page)
        #expect(result.edges[0].polyline().contains(.init(x: 200, y: -60)))
        let label = result.edges[0].labelPoint
        #expect(result.hitEdge(at: .init(x: label.x, y: label.y+5), zoom: 1) == .connection(e.id))
        #expect(result.edges[1].start != result.edges[1].end)
    }
    @Test func spatialQueryHandlesHugeContainerWithoutHugeGrid() {
        let huge = UUID(), small = UUID()
        let index = DiagramSpatialIndex(frames: [huge: .init(x: -1e6, y: -1e6, width: 2e6, height: 2e6), small: .init(x: 10, y: 10)])
        #expect(index.query(.init(x: 0, y: 0, width: 200, height: 100)) == [huge, small])
    }
    @Test func selectionArrangeLeavesOtherFramesAndLocksIntact() throws {
        var page = DiagramExamples.library().pages[0]
        let baseline = try DiagramLayoutEngine.layout(page)
        for i in page.elements.indices { page.elements[i].frame = baseline.frames[page.elements[i].id] }
        let selected = page.elements[2].id
        let edits = try DiagramLayoutEngine.arrangeEdits(page: page, selection: [selected])
        let allowed = DiagramPageIndex(page).descendants(of: [selected])
        for edit in edits { if case .upsertElement(_, let e) = edit { #expect(allowed.contains(e.id)) } }
    }
    @Test func tenThousandNodeLayoutAndCulling() throws {
        let page = DiagramExamples.large().pages[0], result = try DiagramLayoutEngine.layout(page)
        #expect(result.frames.count == 10_000 && result.edges.count == 9_999)
        let visible = result.spatialIndex.query(.init(x: result.bounds.center.x, y: result.bounds.center.y, width: 1_024, height: 768))
        #expect(visible.count < 200)
    }
}
