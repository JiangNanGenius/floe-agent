// SPDX-License-Identifier: MPL-2.0
import Foundation

extension DiagramDocument {
    public func validate() throws {
        guard schemaVersion == 1, revision >= 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pages.isEmpty, pages.count <= 1_000, pages.reduce(0, { $0 + $1.elements.count }) <= 200_000,
              tasks.count <= 200_000 else { throw DiagramError.invalid("document limits or schema") }
        var identities: Set<UUID> = [id]
        func unique(_ id: UUID) throws {
            guard identities.insert(id).inserted else { throw DiagramError.invalid("duplicate identity \(id)") }
        }
        let assetIDs = Set(assets.map(\.id)), taskIDs = Set(tasks.map(\.id))
        for asset in assets {
            try unique(asset.id)
            guard !asset.fileName.isEmpty, asset.fileName != ".", asset.fileName != "..", asset.fileName == (asset.fileName as NSString).lastPathComponent,
                  !asset.fileName.contains("\\"), !asset.fileName.contains(":"),
                  asset.byteCount >= 0, asset.fileName.utf8.count <= 255, !asset.fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  asset.sha256.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true
            else { throw DiagramError.invalid("asset descriptor") }
        }
        for page in pages {
            try unique(page.id)
            guard !page.title.isEmpty else { throw DiagramError.invalid("page title") }
            let index = DiagramPageIndex(page)
            for element in page.elements {
                try unique(element.id)
                guard element.frame?.isValid ?? true, element.title.utf8.count <= 1_048_576,
                      element.content.count <= 1_000, element.style.fontSize.isFinite,
                      (8...200).contains(element.style.fontSize), element.style.lineWidth.isFinite,
                      (0...40).contains(element.style.lineWidth), element.style.cornerRadius.isFinite,
                      (0...1_000).contains(element.style.cornerRadius)
                else { throw DiagramError.invalid("element geometry or content") }
                if let parent = element.parentID {
                    guard element.kind.isTopic, index.elements[parent]?.kind.isTopic == true else { throw DiagramError.invalid("topic parent") }
                }
                if let container = element.containerID, index.elements[container]?.kind.isContainer != true { throw DiagramError.invalid("container") }
                if let task = element.taskID, !taskIDs.contains(task) { throw DiagramError.invalid("task reference") }
                guard Set(element.memberIDs).isSubset(of: Set(index.elements.keys)) else { throw DiagramError.invalid("summary members") }
                for block in element.content {
                    if let asset = block.assetID, !assetIDs.contains(asset) { throw DiagramError.invalid("missing asset") }
                    if case .table(let table) = block {
                        let width = table.rows.first?.count ?? 0
                        guard table.rows.count <= 1_000, width <= 100, table.rows.allSatisfy({ $0.count == width }) else { throw DiagramError.invalid("table dimensions") }
                    }
                }
            }
            // Combined ownership graph prevents mixed parent/container loops.
            try Self.ensureAcyclic(ids: Set(index.elements.keys), edges: page.elements.flatMap { e in
                [e.parentID, e.containerID].compactMap { $0 }.map { ($0, e.id) }
            })
            for edge in page.connections {
                try unique(edge.id)
                guard index.elements[edge.from] != nil, index.elements[edge.to] != nil,
                      edge.width.isFinite, (0.5...40).contains(edge.width),
                      edge.labelPosition.isFinite, (0...1).contains(edge.labelPosition),
                      edge.waypoints.count <= 1_000, edge.waypoints.allSatisfy(\.isFinite)
                else { throw DiagramError.invalid("connection") }
            }
        }
        for task in tasks {
            try unique(task.id)
            guard task.progress.isFinite, (0...1).contains(task.progress), (0...5).contains(task.priority),
                  task.parentID.map(taskIDs.contains) ?? true,
                  task.start.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  task.end.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  task.start == nil || task.end == nil || task.start! <= task.end!
            else { throw DiagramError.invalid("task") }
        }
        try Self.ensureAcyclic(ids: taskIDs, edges: tasks.compactMap { t in t.parentID.map { ($0, t.id) } })
        for edge in dependencies {
            try unique(edge.id)
            guard taskIDs.contains(edge.predecessorID), taskIDs.contains(edge.successorID), (-3_660...3_660).contains(edge.lagDays)
            else { throw DiagramError.invalid("dependency") }
        }
        try Self.ensureAcyclic(ids: taskIDs, edges: dependencies.map { ($0.predecessorID, $0.successorID) })
    }

    public static func ensureAcyclic(ids: Set<UUID>, edges: [(UUID, UUID)]) throws {
        var degrees = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) }), children: [UUID: [UUID]] = [:]
        for (a, b) in edges {
            guard ids.contains(a), ids.contains(b), a != b else { throw DiagramError.invalid("invalid hierarchy") }
            degrees[b, default: 0] += 1; children[a, default: []].append(b)
        }
        var queue = ids.filter { degrees[$0] == 0 }.sorted { $0.uuidString < $1.uuidString }, cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for next in children[id] ?? [] { degrees[next, default: 0] -= 1; if degrees[next] == 0 { queue.append(next) } }
        }
        guard cursor == ids.count else { throw DiagramError.invalid("cycle") }
    }
}
