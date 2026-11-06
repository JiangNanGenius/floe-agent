// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore
import SwiftDagre

/// Pure tree measurement follows FloeNotes/MindMapLayout's indexed, measured subtree approach.
/// It adds multiple roots, mixed structures, native containers and isolated Dagre flow layout.
public enum DiagramLayoutEngine {
    private struct ChildPlacement { var id: UUID; var origin: DiagramPoint; var mirrored: Bool }
    private struct Subtree { var bounds: DiagramRect; var size: DiagramSize; var children: [ChildPlacement] }

    public static func measure(_ element: DiagramElement) -> DiagramSize {
        if let frame = element.frame { return frame.size }
        var height = max(56, Double((element.title.count + 13) / 14) * 20 + 28)
        if element.content.contains(where: { if case .image = $0 { return true }; return false }) { height += 96 }
        if element.contentExpanded {
            for block in element.content {
                switch block {
                case .richText(let runs): height += min(140, Double((runs.map(\.text).joined().count + 17) / 18) * 18 + 10)
                case .formula: height += 48
                case .table(let table): height += Double(min(8, table.rows.count)) * 25 + 10
                case .code: height += 70
                case .note(let text): height += min(110, Double((text.count + 17) / 18) * 18 + 10)
                default: break
                }
            }
        }
        return .init(width: element.contentExpanded ? 220 : 160, height: min(520, height))
    }

    public static func layout(_ page: DiagramPage, sizes: [UUID: DiagramSize] = [:]) throws -> DiagramLayoutResult {
        try Task.checkCancellation()
        let elementIDs = Set(page.elements.map(\.id))
        guard elementIDs.count == page.elements.count, page.elements.allSatisfy({ $0.frame?.isValid ?? true }),
              page.connections.allSatisfy({ elementIDs.contains($0.from) && elementIDs.contains($0.to) }) else { throw DiagramError.invalid("layout input") }
        try DiagramDocument.ensureAcyclic(ids: elementIDs, edges: page.elements.flatMap { e in [e.parentID, e.containerID].compactMap { $0 }.map { ($0, e.id) } })
        let index = DiagramPageIndex(page), representatives = visibility(page, index: index)
        let visible = page.elements.filter { representatives[$0.id] == $0.id }
        var frames: [UUID: DiagramRect] = [:]
        let measured = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, sizes[$0.id].flatMap { $0.isValid ? $0 : nil } ?? measure($0)) })
        for element in visible { if let frame = element.frame { frames[element.id] = frame } }
        let topics = visible.filter { $0.kind.isTopic }
        let topicIDs = Set(topics.map(\.id))
        let roots = topics.filter { $0.parentID == nil || !topicIDs.contains($0.parentID!) }.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        if page.structure == .flow && visible.contains(where: { !$0.kind.isTopic && !$0.kind.isContainer }) {
            try flowFrames(page, elements: visible.filter { !$0.kind.isContainer && $0.kind != .boundary && $0.kind != .summary }, sizes: measured, frames: &frames)
        }
        var order = roots.map(\.id), cursor = 0
        while cursor < order.count {
            let id = order[cursor]; cursor += 1
            order += (index.children[id] ?? []).filter { representatives[$0] == $0 }
        }
        var subtrees: [UUID: Subtree] = [:]
        for id in order.reversed() {
            try Task.checkCancellation()
            guard let element = index.elements[id] else { continue }
            let size = measured[id] ?? .init()
            let children = (index.children[id] ?? []).filter { subtrees[$0] != nil && representatives[$0] == $0 }
            let structure = element.structure ?? (element.parentID == nil ? page.structure : .right)
            let own = DiagramRect(width: size.width, height: size.height)
            var bounds = own, placements: [ChildPlacement] = []
            if structure == .organization {
                let total = children.reduce(0.0) { $0 + subtrees[$1]!.bounds.width } + Double(max(0, children.count-1))*32
                var x = size.width/2-total/2
                for child in children {
                    let box = subtrees[child]!.bounds
                    let origin = DiagramPoint(x: x-box.x, y: size.height+64-box.y)
                    placements.append(.init(id: child, origin: origin, mirrored: false)); bounds = bounds.union(box.translated(by: origin))
                    x += box.width+32
                }
            } else if structure == .timeline || structure == .fishbone {
                var x = structure == .timeline ? size.width+80 : -80.0
                for (i, child) in children.enumerated() {
                    let box = subtrees[child]!.bounds
                    let left = structure == .timeline ? x : x-box.width
                    let top = i.isMultiple(of: 2) ? -80-box.height : size.height+80
                    let origin = DiagramPoint(x: left-box.x, y: top-box.y)
                    placements.append(.init(id: child, origin: origin, mirrored: false)); bounds = bounds.union(box.translated(by: origin))
                    x += (structure == .timeline ? 1 : -1)*(box.width+64)
                }
            } else {
                var left: [UUID] = [], right: [UUID] = [], lh = 0.0, rh = 0.0
                for child in children {
                    let explicit = index.elements[child]?.structure
                    let useLeft = explicit == .left || (explicit != .right && (structure == .left || (structure == .balanced && lh < rh)))
                    if useLeft { left.append(child); lh += subtrees[child]!.bounds.height+28 }
                    else { right.append(child); rh += subtrees[child]!.bounds.height+28 }
                }
                for (list, mirror) in [(left, true), (right, false)] {
                    let total = list.reduce(0.0) { $0 + subtrees[$1]!.bounds.height } + Double(max(0, list.count-1))*28
                    var y = size.height/2-total/2
                    for child in list {
                        let subtree = subtrees[child]!, box = mirror ? reflected(subtree.bounds, width: subtree.size.width) : subtree.bounds
                        let left = mirror ? -64-box.width : size.width+64
                        let origin = DiagramPoint(x: left-box.x, y: y-box.y)
                        placements.append(.init(id: child, origin: origin, mirrored: mirror)); bounds = bounds.union(box.translated(by: origin))
                        y += box.height+28
                    }
                }
            }
            subtrees[id] = .init(bounds: bounds, size: size, children: placements)
        }
        var packingY = 40.0
        for root in roots {
            guard let subtree = subtrees[root.id] else { continue }
            var origin = DiagramPoint(x: 40-subtree.bounds.x, y: packingY-subtree.bounds.y)
            if let containerID = root.containerID, let container = frames[containerID] { origin = .init(x: container.x+48-subtree.bounds.x, y: container.y+60-subtree.bounds.y) }
            var stack: [(UUID, DiagramPoint, Double)] = [(root.id, origin, 1)]
            while let (id, proposed, sign) = stack.popLast() {
                try Task.checkCancellation()
                guard let tree = subtrees[id] else { continue }
                let pinned = frames[id], own = pinned ?? .init(x: min(proposed.x, proposed.x+sign*tree.size.width), y: proposed.y, width: tree.size.width, height: tree.size.height)
                frames[id] = own
                let actualOrigin = DiagramPoint(x: sign < 0 ? own.maxX : own.x, y: own.y)
                for child in tree.children.reversed() {
                    let width = subtrees[child.id]!.size.width
                    stack.append((child.id, .init(x: actualOrigin.x+sign*(child.origin.x+(child.mirrored ? width : 0)), y: actualOrigin.y+child.origin.y), sign*(child.mirrored ? -1 : 1)))
                }
            }
            packingY += subtree.bounds.height+100
        }
        var gridIndex = 0
        for element in visible where frames[element.id] == nil && !element.kind.isContainer && element.kind != .summary && element.kind != .boundary {
            let size = measured[element.id] ?? .init()
            frames[element.id] = .init(x: 40+Double(gridIndex % 4)*260, y: packingY+Double(gridIndex/4)*200, width: size.width, height: size.height)
            gridIndex += 1
        }
        // Bottom-up container sizing does not move pinned containers or unselected objects.
        for element in page.elements.reversed() where representatives[element.id] == element.id {
            if element.frame != nil { continue }
            let memberIDs = element.kind.isContainer ? index.members[element.id] ?? [] : element.memberIDs
            if element.kind.isContainer || element.kind == .summary || element.kind == .boundary {
                let union = memberIDs.compactMap { frames[$0] }.reduce(nil as DiagramRect?) { $0?.union($1) ?? $1 }
                if element.kind == .summary, let union { frames[element.id] = .init(x: union.maxX+24, y: union.y, width: max(100, Double(element.title.count)*9+20), height: union.height) }
                else { frames[element.id] = union?.insetBy(-24) ?? .init(x: 40, y: packingY, width: 320, height: 200) }
            }
        }
        let edges = try DiagramRouter.edges(page: page, frames: frames, representatives: representatives)
        return .init(frames: frames, edges: edges, visibleRepresentatives: representatives)
    }
    private static func reflected(_ rect: DiagramRect, width: Double) -> DiagramRect { .init(x: width-rect.maxX, y: rect.y, width: rect.width, height: rect.height) }

    private static func visibility(_ page: DiagramPage, index: DiagramPageIndex) -> [UUID: UUID] {
        var degree: [UUID: Int] = [:], owners: [UUID: [UUID]] = [:], children: [UUID: [UUID]] = [:]
        for e in page.elements {
            let parents = Array(Set([e.parentID, e.containerID].compactMap { $0 }))
            owners[e.id] = parents; degree[e.id] = parents.count
            for p in parents { children[p, default: []].append(e.id) }
        }
        var queue = page.elements.filter { degree[$0.id] == 0 }.map(\.id), cursor = 0, result: [UUID: UUID] = [:]
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            result[id] = id
            for p in owners[id] ?? [] {
                if let representative = result[p], representative != p { result[id] = representative; break }
                if index.elements[p]?.collapsed == true { result[id] = p; break }
            }
            for child in children[id] ?? [] { degree[child, default: 0] -= 1; if degree[child] == 0 { queue.append(child) } }
        }
        return result
    }

    private static func flowFrames(_ page: DiagramPage, elements: [DiagramElement], sizes: [UUID: DiagramSize],
                                   frames: inout [UUID: DiagramRect]) throws {
        let ids = Set(elements.map(\.id)), edges = page.connections.filter { ids.contains($0.from) && ids.contains($0.to) }
        var neighbors: [UUID: [UUID]] = [:]
        for edge in edges { neighbors[edge.from, default: []].append(edge.to); neighbors[edge.to, default: []].append(edge.from) }
        var seen: Set<UUID> = [], packingY = 40.0
        for first in elements.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where !seen.contains(first.id) {
            var component = [first.id], cursor = 0; seen.insert(first.id)
            while cursor < component.count {
                let id = component[cursor]; cursor += 1
                for next in neighbors[id] ?? [] where seen.insert(next).inserted { component.append(next) }
            }
            if component.allSatisfy({ frames[$0] != nil }) { continue }
            try Task.checkCancellation()
            let graph = DagreGraph(options: .init(directed: true, multigraph: true, compound: false))
            let options = LayoutOptions()
            switch page.metadata["direction"] {
            case "TD", "TB": options.rankdir = .topBottom
            case "BT": options.rankdir = .bottomTop
            case "RL": options.rankdir = .rightLeft
            default: options.rankdir = .leftRight
            }
            options.nodesep = 32; options.ranksep = 72
            if component.count > 500 { options.ranker = .longestPath }
            let componentIDs = Set(component)
            for id in component.sorted(by: { $0.uuidString < $1.uuidString }) {
                let size = sizes[id] ?? .init(); graph.setNode(id.uuidString, label: .init(width: size.width, height: size.height))
            }
            for edge in edges where componentIDs.contains(edge.from) && componentIDs.contains(edge.to) {
                try graph.setEdge(edge.from.uuidString, edge.to.uuidString, label: DagreEdgeLabel(), name: edge.id.uuidString)
            }
            try SwiftDagreLayout.layout(graph, options: options)
            try Task.checkCancellation()
            var height = 0.0
            for id in component where frames[id] == nil {
                guard let label = graph.node(id.uuidString), label.x.isFinite, label.y.isFinite else { throw DiagramError.invalid("nonfinite Dagre output") }
                let size = sizes[id] ?? .init()
                frames[id] = .init(x: label.x-size.width/2+40, y: label.y-size.height/2+packingY, width: size.width, height: size.height)
                height = max(height, label.y+size.height/2)
            }
            packingY += height+100
        }
    }

    public static func arrangeEdits(page: DiagramPage, selection: Set<UUID>? = nil) throws -> [DiagramEdit] {
        let index = DiagramPageIndex(page)
        let candidates = selection.map { index.descendants(of: $0) } ?? Set(page.elements.map(\.id))
        var carryingLocked = index.effectivelyLockedIDs
        var queue = Array(carryingLocked), cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for parent in [index.elements[id]?.parentID, index.elements[id]?.containerID].compactMap({ $0 }) where carryingLocked.insert(parent).inserted { queue.append(parent) }
        }
        let movable = candidates.subtracting(carryingLocked)
        var copy = page
        for i in copy.elements.indices where movable.contains(copy.elements[i].id) && !copy.elements[i].kind.isContainer { copy.elements[i].frame = nil }
        let result = try layout(copy)
        var delta = DiagramPoint.zero
        if selection != nil {
            let oldBounds = movable.compactMap { index.elements[$0]?.frame }.reduce(nil as DiagramRect?) { $0?.union($1) ?? $1 }
            let newBounds = movable.compactMap { result.frames[$0] }.reduce(nil as DiagramRect?) { $0?.union($1) ?? $1 }
            if let oldBounds, let newBounds { delta = oldBounds.center-newBounds.center }
        }
        return page.elements.compactMap { old in
            guard movable.contains(old.id), let frame = result.frames[old.id], !old.kind.isContainer else { return nil }
            var node = old; node.frame = frame.translated(by: delta); return .upsertElement(pageID: page.id, element: node)
        }
    }
}
