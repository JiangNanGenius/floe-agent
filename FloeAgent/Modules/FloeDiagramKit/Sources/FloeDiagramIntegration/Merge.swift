// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore

public struct DiagramMergeConflict: Codable, Hashable, Sendable {
    public var entityID: UUID
    public var field: String
    public var base: Data?
    public var local: Data?
    public var incoming: Data?
}
public struct DiagramMergeResult: Sendable {
    public var document: DiagramDocument
    public var conflicts: [DiagramMergeConflict]
    public var incomingRecovery: DiagramDocument?
    public var requiresReview: Bool { !conflicts.isEmpty }
}
public enum DiagramMerge {
    /// Field-aware three-way merge. Concurrent edits to the same field keep local bytes and retain incoming recovery.
    /// This is also the source-refresh primitive: host supplies the last generated base and the refreshed version.
    public static func threeWay(base: DiagramDocument, local: DiagramDocument, incoming: DiagramDocument) throws -> DiagramMergeResult {
        try base.validate(); try local.validate(); try incoming.validate()
        guard base.id == local.id, local.id == incoming.id else { throw DiagramError.invalid("merge ownership") }
        var conflicts: [DiagramMergeConflict] = []
        var result = local
        result.title = try pick(base.title, local.title, incoming.title, id: local.id, field: "title", conflicts: &conflicts)
        result.metadata = try pick(base.metadata, local.metadata, incoming.metadata, id: local.id, field: "metadata", conflicts: &conflicts)
        result.assets = try mergeEntities(base.assets, local.assets, incoming.assets, conflicts: &conflicts)
        result.tasks = try mergeEntities(base.tasks, local.tasks, incoming.tasks, conflicts: &conflicts)
        result.dependencies = try mergeEntities(base.dependencies, local.dependencies, incoming.dependencies, conflicts: &conflicts)
        let oldPages = Dictionary(uniqueKeysWithValues: base.pages.map { ($0.id, $0) })
        let newPages = Dictionary(uniqueKeysWithValues: incoming.pages.map { ($0.id, $0) })
        let ourPages = Dictionary(uniqueKeysWithValues: local.pages.map { ($0.id, $0) })
        let chosenOrder = try pick(base.pages.map(\.id), local.pages.map(\.id), incoming.pages.map(\.id), id: local.id, field: "pageOrder", conflicts: &conflicts)
        let chosenIDs = Set(chosenOrder)
        let pageOrder = chosenOrder + local.pages.map(\.id).filter { !chosenIDs.contains($0) } + incoming.pages.map(\.id).filter { !chosenIDs.contains($0) && ourPages[$0] == nil }
        result.pages = []
        for id in pageOrder {
            guard let b = oldPages[id], let l = ourPages[id], let r = newPages[id] else {
                if let chosen = try mergeEntity(oldPages[id], ourPages[id], newPages[id], id: id, conflicts: &conflicts) { result.pages.append(chosen) }
                continue
            }
            var bh = b, lh = l, rh = r
            bh.elements = []; bh.connections = []; lh.elements = []; lh.connections = []; rh.elements = []; rh.connections = []
            var merged = try mergeEntity(bh, lh, rh, id: id, conflicts: &conflicts)!
            merged.elements = try mergeEntities(b.elements, l.elements, r.elements, conflicts: &conflicts)
            merged.connections = try mergeEntities(b.connections, l.connections, r.connections, conflicts: &conflicts)
            result.pages.append(merged)
        }
        result.revision = local.revision
        do { try result.validate() }
        catch {
            conflicts.append(.init(entityID: local.id, field: "graphConsistency", base: nil, local: try DiagramCodec.encode(local), incoming: try DiagramCodec.encode(incoming)))
            result = local
        }
        var recovery: DiagramDocument? = nil
        if !conflicts.isEmpty {
            var copy = incoming; copy.id = UUID(); copy.revision = 0; copy.title += " · Incoming"
            copy.metadata["recoveryOrigin"] = incoming.id.uuidString; recovery = copy
        }
        return .init(document: result, conflicts: conflicts, incomingRecovery: recovery)
    }
    private static func bytes(_ object: Any?) throws -> Data? {
        guard let object else { return nil }
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }
    private static func optionalBytes<T: Encodable>(_ value: T?) throws -> Data? {
        guard let value else { return nil }; return try DiagramCodec.encode(value)
    }
    private static func pick<T: Codable & Equatable>(_ b: T, _ l: T, _ r: T, id: UUID, field: String,
                                                    conflicts: inout [DiagramMergeConflict]) throws -> T {
        if l == b { return r }; if r == b || l == r { return l }
        conflicts.append(.init(entityID: id, field: field, base: try DiagramCodec.encode(b), local: try DiagramCodec.encode(l), incoming: try DiagramCodec.encode(r)))
        return l
    }
    private static func mergeEntity<T: Codable & Equatable>(_ b: T?, _ l: T?, _ r: T?, id: UUID,
                                                           conflicts: inout [DiagramMergeConflict]) throws -> T? {
        if l == b { return r }; if r == b || l == r { return l }
        guard let b, let l, let r else {
            conflicts.append(.init(entityID: id, field: "existence", base: try optionalBytes(b), local: try optionalBytes(l), incoming: try optionalBytes(r)))
            return l
        }
        let bo = try JSONSerialization.jsonObject(with: DiagramCodec.encode(b)) as! [String: Any]
        let lo = try JSONSerialization.jsonObject(with: DiagramCodec.encode(l)) as! [String: Any]
        let ro = try JSONSerialization.jsonObject(with: DiagramCodec.encode(r)) as! [String: Any]
        var merged = lo
        for key in Set(bo.keys).union(lo.keys).union(ro.keys).sorted() {
            let bv = try bytes(bo[key]), lv = try bytes(lo[key]), rv = try bytes(ro[key])
            if lv == bv { merged[key] = ro[key] }
            else if rv != bv && rv != lv { conflicts.append(.init(entityID: id, field: key, base: bv, local: lv, incoming: rv)) }
        }
        return try DiagramCodec.decode(T.self, from: JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]))
    }
    private static func mergeEntities<T: Codable & Equatable & Identifiable>(_ b: [T], _ l: [T], _ r: [T],
                                                                           conflicts: inout [DiagramMergeConflict]) throws -> [T] where T.ID == UUID {
        let bo = Dictionary(uniqueKeysWithValues: b.map { ($0.id, $0) }), lo = Dictionary(uniqueKeysWithValues: l.map { ($0.id, $0) }), ro = Dictionary(uniqueKeysWithValues: r.map { ($0.id, $0) })
        let ids = l.map(\.id) + r.map(\.id).filter { lo[$0] == nil }
        return try ids.compactMap { try mergeEntity(bo[$0], lo[$0], ro[$0], id: $0, conflicts: &conflicts) }
    }
}

public enum DiagramDiff {
    /// Converts a prepared refresh/merge into ordinary edits, retaining the same lock/CAS/undo pipeline.
    public static func edits(from old: DiagramDocument, to new: DiagramDocument) throws -> [DiagramEdit] {
        guard old.id == new.id, old.legacyPayload == new.legacyPayload else { throw DiagramError.unsupported("document ownership or source payload migration") }
        try new.validate()
        var edits: [DiagramEdit] = []
        if old.title != new.title { edits.append(.rename(new.title)) }
        if old.metadata != new.metadata { edits.append(.setMetadata(new.metadata)) }
        for asset in new.assets where !old.assets.contains(asset) { edits.append(.upsertAsset(asset)) }
        for task in new.tasks where !old.tasks.contains(task) { edits.append(.upsertTask(task)) }
        for edge in old.dependencies where !new.dependencies.contains(where: { $0.id == edge.id }) { edits.append(.deleteDependency(edge.id)) }
        for (position, page) in new.pages.enumerated() {
            guard let before = old.page(page.id) else { edits.append(.insertPage(page, at: min(position, old.pages.count))); continue }
            if before.title != page.title || before.structure != page.structure || before.theme != page.theme { edits.append(.updatePage(id: page.id, title: page.title, structure: page.structure, theme: page.theme)) }
            if before.ink != page.ink { edits.append(.setInk(pageID: page.id, data: page.ink)) }
            if before.metadata != page.metadata { edits.append(.setPageMetadata(pageID: page.id, metadata: page.metadata)) }
            for edge in before.connections where !page.connections.contains(where: { $0.id == edge.id }) { edits.append(.deleteConnection(pageID: page.id, id: edge.id)) }
            for element in page.elements where !before.elements.contains(element) { edits.append(.upsertElement(pageID: page.id, element: element)) }
            let removed = Set(before.elements.map(\.id)).subtracting(page.elements.map(\.id))
            if !removed.isEmpty { edits.append(.deleteElements(pageID: page.id, ids: removed, includeDescendants: false)) }
            for edge in page.connections where !before.connections.contains(edge) { edits.append(.upsertConnection(pageID: page.id, connection: edge)) }
        }
        for page in old.pages where new.page(page.id) == nil { edits.append(.deletePage(page.id)) }
        if old.pages.map(\.id) != new.pages.map(\.id) {
            for (position, page) in new.pages.enumerated() { edits.append(.movePage(page.id, to: position)) }
        }
        for task in old.tasks where !new.tasks.contains(where: { $0.id == task.id }) { edits.append(.deleteTask(task.id)) }
        for edge in new.dependencies where !old.dependencies.contains(edge) { edits.append(.upsertDependency(edge)) }
        for asset in old.assets where !new.assets.contains(where: { $0.id == asset.id }) { edits.append(.removeAsset(asset.id)) }
        return edits
    }
}
