// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct DiagramEditScope: Codable, Hashable, Sendable {
    public var pageID: UUID?
    /// nil is document-wide; an empty set permits no existing elements.
    public var elementIDs: Set<UUID>?
    public var connectionIDs: Set<UUID>
    public var taskIDs: Set<UUID>
    public var includeDescendants: Bool
    /// Allows new independent task roots. Scoped child tasks and permitted new topic references remain scoped.
    public var allowsNewTasks: Bool
    public init(pageID: UUID? = nil, elementIDs: Set<UUID>? = nil, connectionIDs: Set<UUID> = [],
                taskIDs: Set<UUID> = [], includeDescendants: Bool = true, allowsNewTasks: Bool = false) {
        self.pageID = pageID; self.elementIDs = elementIDs; self.connectionIDs = connectionIDs
        self.taskIDs = taskIDs; self.includeDescendants = includeDescendants; self.allowsNewTasks = allowsNewTasks
    }
    public static let document = Self()
}
public struct DiagramEditContext: Sendable {
    public var scope: DiagramEditScope
    /// Only trusted, explicit user actions may unlock. Model-supplied commands cannot grant this.
    public var permitsUnlock: Bool
    public init(scope: DiagramEditScope = .document, permitsUnlock: Bool = false) { self.scope = scope; self.permitsUnlock = permitsUnlock }
}
public enum DiagramEdit: Codable, Hashable, Sendable {
    case rename(String)
    case setMetadata([String: String])
    case setPageMetadata(pageID: UUID, metadata: [String: String])
    case insertPage(DiagramPage, at: Int)
    case updatePage(id: UUID, title: String, structure: DiagramStructure, theme: DiagramTheme)
    case movePage(UUID, to: Int)
    case duplicatePage(UUID)
    case deletePage(UUID)
    case upsertElement(pageID: UUID, element: DiagramElement)
    case deleteElements(pageID: UUID, ids: Set<UUID>, includeDescendants: Bool)
    case moveElements(pageID: UUID, ids: Set<UUID>, delta: DiagramPoint, includeDescendants: Bool)
    case reparent(pageID: UUID, id: UUID, parentID: UUID?, order: Int)
    case setLocked(pageID: UUID, ids: Set<UUID>, locked: Bool)
    case upsertConnection(pageID: UUID, connection: DiagramConnection)
    case deleteConnection(pageID: UUID, id: UUID)
    case setInk(pageID: UUID, data: Data?)
    case upsertTask(DiagramTask)
    case deleteTask(UUID)
    case upsertDependency(DiagramTaskDependency)
    case deleteDependency(UUID)
    case upsertAsset(DiagramAsset)
    case removeAsset(UUID)
}
public struct DiagramEditBatch: Codable, Hashable, Sendable {
    public var documentID: UUID
    public var expectedRevision: Int
    public var requestID: UUID
    public var title: String
    public var edits: [DiagramEdit]
    public init(documentID: UUID, expectedRevision: Int, requestID: UUID = UUID(), title: String = "Edit", edits: [DiagramEdit]) {
        self.documentID = documentID; self.expectedRevision = expectedRevision; self.requestID = requestID; self.title = title; self.edits = edits
    }
}
public enum DiagramEditEngine {
    public static func applying(_ batch: DiagramEditBatch, to before: DiagramDocument,
                                context: DiagramEditContext = .init()) throws -> DiagramDocument {
        guard batch.documentID == before.id else { throw DiagramError.notFound(batch.documentID) }
        guard before.revision == batch.expectedRevision else { throw DiagramError.conflict(expected: batch.expectedRevision, actual: before.revision) }
        guard !batch.edits.isEmpty, batch.edits.count <= 20_000 else { throw DiagramError.invalid("edit batch size") }
        try before.validate()
        var after = before
        for edit in batch.edits { try apply(edit, to: &after, context: context) }
        try protect(before: before, after: after, context: context)
        after.revision += 1
        try after.validate()
        return after
    }

    private static func pageIndex(_ id: UUID, in document: DiagramDocument) throws -> Int {
        guard let p = document.pages.firstIndex(where: { $0.id == id }) else { throw DiagramError.notFound(id) }
        return p
    }
    private static func apply(_ edit: DiagramEdit, to doc: inout DiagramDocument, context: DiagramEditContext) throws {
        switch edit {
        case .rename(let title): doc.title = title
        case .setMetadata(let metadata): doc.metadata = metadata
        case .setPageMetadata(let id, let metadata): doc.pages[try pageIndex(id, in: doc)].metadata = metadata
        case .insertPage(let page, let at):
            guard (0...doc.pages.count).contains(at) else { throw DiagramError.invalid("page order") }; doc.pages.insert(page, at: at)
        case .updatePage(let id, let title, let structure, let theme):
            let p = try pageIndex(id, in: doc); doc.pages[p].title = title; doc.pages[p].structure = structure; doc.pages[p].theme = theme
        case .movePage(let id, let at):
            guard doc.pages.indices.contains(at) else { throw DiagramError.invalid("page order") }
            let p = try pageIndex(id, in: doc); doc.pages.insert(doc.pages.remove(at: p), at: at)
        case .duplicatePage(let id): try duplicate(id, in: &doc)
        case .deletePage(let id):
            let p = try pageIndex(id, in: doc); guard doc.pages.count > 1 else { throw DiagramError.invalid("last page") }; doc.pages.remove(at: p)
        case .upsertElement(let id, let element):
            let p = try pageIndex(id, in: doc)
            if let n = doc.pages[p].elements.firstIndex(where: { $0.id == element.id }) {
                if doc.pages[p].elements[n].isLocked && !element.isLocked && !context.permitsUnlock { throw DiagramError.protectedContent(element.id) }
                doc.pages[p].elements[n] = element
            } else { doc.pages[p].elements.append(element) }
        case .deleteElements(let id, let ids, let subtree):
            let p = try pageIndex(id, in: doc), index = DiagramPageIndex(doc.pages[p])
            guard ids.isSubset(of: Set(index.elements.keys)) else { throw DiagramError.invalid("selection") }
            let removed = subtree ? index.descendants(of: ids) : ids
            if !subtree && doc.pages[p].elements.contains(where: { $0.parentID.map(removed.contains) == true && !removed.contains($0.id) }) {
                throw DiagramError.invalid("delete would orphan children")
            }
            doc.pages[p].elements.removeAll { removed.contains($0.id) }
            for n in doc.pages[p].elements.indices { doc.pages[p].elements[n].memberIDs.removeAll { removed.contains($0) } }
            doc.pages[p].connections.removeAll { removed.contains($0.from) || removed.contains($0.to) }
        case .moveElements(let id, let ids, let delta, let subtree):
            guard delta.isFinite else { throw DiagramError.invalid("translation") }
            let p = try pageIndex(id, in: doc), index = DiagramPageIndex(doc.pages[p])
            guard ids.isSubset(of: Set(index.elements.keys)) else { throw DiagramError.invalid("selection") }
            let moved = subtree ? index.descendants(of: ids) : ids
            for n in doc.pages[p].elements.indices where moved.contains(doc.pages[p].elements[n].id) {
                guard let frame = doc.pages[p].elements[n].frame else { throw DiagramError.invalid("materialize layout before dragging") }
                doc.pages[p].elements[n].frame = frame.translated(by: delta)
            }
            // Manual waypoints move only when both endpoints move together.
            for e in doc.pages[p].connections.indices where moved.contains(doc.pages[p].connections[e].from) && moved.contains(doc.pages[p].connections[e].to) {
                doc.pages[p].connections[e].waypoints = doc.pages[p].connections[e].waypoints.map { $0 + delta }
            }
        case .reparent(let id, let nodeID, let parentID, let order):
            let p = try pageIndex(id, in: doc)
            guard let n = doc.pages[p].elements.firstIndex(where: { $0.id == nodeID }) else { throw DiagramError.notFound(nodeID) }
            doc.pages[p].elements[n].parentID = parentID; doc.pages[p].elements[n].order = order
        case .setLocked(let id, let ids, let locked):
            guard locked || context.permitsUnlock else { throw DiagramError.invalid("unlock requires explicit user action") }
            let p = try pageIndex(id, in: doc)
            guard ids.isSubset(of: Set(doc.pages[p].elements.map(\.id))) else { throw DiagramError.invalid("selection") }
            for n in doc.pages[p].elements.indices where ids.contains(doc.pages[p].elements[n].id) { doc.pages[p].elements[n].isLocked = locked }
        case .upsertConnection(let id, let edge):
            let p = try pageIndex(id, in: doc)
            if let e = doc.pages[p].connections.firstIndex(where: { $0.id == edge.id }) { doc.pages[p].connections[e] = edge }
            else { doc.pages[p].connections.append(edge) }
        case .deleteConnection(let id, let edge):
            let p = try pageIndex(id, in: doc)
            guard doc.pages[p].connections.contains(where: { $0.id == edge }) else { throw DiagramError.notFound(edge) }
            doc.pages[p].connections.removeAll { $0.id == edge }
        case .setInk(let id, let data): doc.pages[try pageIndex(id, in: doc)].ink = data
        case .upsertTask(var task):
            if task.status == .done { task.progress = 1 }
            if let t = doc.tasks.firstIndex(where: { $0.id == task.id }) { doc.tasks[t] = task } else { doc.tasks.append(task) }
        case .deleteTask(let id):
            guard doc.tasks.contains(where: { $0.id == id }) else { throw DiagramError.notFound(id) }
            doc.tasks.removeAll { $0.id == id }
            for t in doc.tasks.indices where doc.tasks[t].parentID == id { doc.tasks[t].parentID = nil }
            doc.dependencies.removeAll { $0.predecessorID == id || $0.successorID == id }
            for p in doc.pages.indices { for n in doc.pages[p].elements.indices where doc.pages[p].elements[n].taskID == id { doc.pages[p].elements[n].taskID = nil } }
        case .upsertDependency(let dependency):
            if let e = doc.dependencies.firstIndex(where: { $0.id == dependency.id }) { doc.dependencies[e] = dependency } else { doc.dependencies.append(dependency) }
        case .deleteDependency(let id):
            guard doc.dependencies.contains(where: { $0.id == id }) else { throw DiagramError.notFound(id) }; doc.dependencies.removeAll { $0.id == id }
        case .upsertAsset(let asset):
            if let a = doc.assets.firstIndex(where: { $0.id == asset.id }) { doc.assets[a] = asset } else { doc.assets.append(asset) }
        case .removeAsset(let id): doc.assets.removeAll { $0.id == id }
        }
    }

    private static func duplicate(_ id: UUID, in doc: inout DiagramDocument) throws {
        let p = try pageIndex(id, in: doc)
        var page = doc.pages[p]; let oldPageID = page.id; page.id = UUID(); page.title += " · Copy"
        let nodeMap = Dictionary(uniqueKeysWithValues: page.elements.map { ($0.id, UUID()) })
        let linkedTasks = Set(page.elements.compactMap(\.taskID))
        let taskMap = Dictionary(uniqueKeysWithValues: doc.tasks.filter { linkedTasks.contains($0.id) }.map { ($0.id, UUID()) })
        for n in page.elements.indices {
            page.elements[n].id = nodeMap[page.elements[n].id]!
            page.elements[n].parentID = page.elements[n].parentID.flatMap { nodeMap[$0] }
            page.elements[n].containerID = page.elements[n].containerID.flatMap { nodeMap[$0] }
            page.elements[n].memberIDs = page.elements[n].memberIDs.compactMap { nodeMap[$0] }
            page.elements[n].taskID = page.elements[n].taskID.flatMap { taskMap[$0] }
            page.elements[n].links = page.elements[n].links.map { old in
                var link = old
                if old.pageID == oldPageID { link.pageID = page.id }
                if let nodeID = old.elementID, let mapped = nodeMap[nodeID] { link.elementID = mapped }
                return link
            }
        }
        for e in page.connections.indices { page.connections[e].id = UUID(); page.connections[e].from = nodeMap[page.connections[e].from]!; page.connections[e].to = nodeMap[page.connections[e].to]! }
        let newTasks = doc.tasks.filter { linkedTasks.contains($0.id) }.map { old in
            var task = old; task.id = taskMap[old.id]!; task.parentID = old.parentID.flatMap { taskMap[$0] }; task.floeTaskID = nil; return task
        }
        let newDependencies = doc.dependencies.filter { taskMap[$0.predecessorID] != nil && taskMap[$0.successorID] != nil }.map { old in
            DiagramTaskDependency(predecessorID: taskMap[old.predecessorID]!, successorID: taskMap[old.successorID]!, lagDays: old.lagDays)
        }
        doc.tasks += newTasks; doc.dependencies += newDependencies; doc.pages.insert(page, at: p + 1)
    }

    private static func protect(before: DiagramDocument, after: DiagramDocument, context: DiagramEditContext) throws {
        let scope = context.scope
        let limited = scope.elementIDs != nil || scope.pageID != nil
        if limited {
            guard before.title == after.title, before.metadata == after.metadata, before.pages.map(\.id) == after.pages.map(\.id) else { throw DiagramError.outsideSelection(before.id) }
        }
        var permittedTasks = scope.taskIDs
        var lockedTaskOwners: [UUID:UUID] = [:]
        var permittedAssets: Set<UUID> = [], outsideAssets: Set<UUID> = [], lockedAssets: Set<UUID> = []
        for oldPage in before.pages {
            let old = DiagramPageIndex(oldPage), newPage = after.page(oldPage.id), new = newPage.map(DiagramPageIndex.init)
            let onPage = scope.pageID == nil || scope.pageID == oldPage.id
            let allowed: Set<UUID> = onPage ? (scope.elementIDs.map { scope.includeDescendants ? old.descendants(of: $0) : $0 } ?? Set(old.elements.keys)) : []
            permittedTasks.formUnion(oldPage.elements.filter { allowed.contains($0.id) }.compactMap(\.taskID))
            for node in oldPage.elements {
                let assets = node.content.compactMap(\.assetID)
                if allowed.contains(node.id) { permittedAssets.formUnion(assets) } else { outsideAssets.formUnion(assets) }
                if old.isEffectivelyLocked(node.id) { lockedAssets.formUnion(assets) }
                if old.isEffectivelyLocked(node.id), let task = node.taskID { lockedTaskOwners[task] = node.id }
            }
            if scope.elementIDs != nil || !onPage, let newPage {
                guard oldPage.title == newPage.title, oldPage.theme == newPage.theme, oldPage.structure == newPage.structure, oldPage.ink == newPage.ink, oldPage.metadata == newPage.metadata else { throw DiagramError.outsideSelection(oldPage.id) }
            }
            if oldPage.theme != newPage?.theme || oldPage.structure != newPage?.structure || oldPage.ink != newPage?.ink || oldPage.metadata != newPage?.metadata {
                if let protected = oldPage.elements.first(where: { old.isEffectivelyLocked($0.id) }) { throw DiagramError.protectedContent(protected.id) }
            }
            for node in oldPage.elements {
                guard node != new?.elements[node.id] else { continue }
                if !allowed.contains(node.id) { throw DiagramError.outsideSelection(node.id) }
                if old.isEffectivelyLocked(node.id) {
                    var unlockOnly = node
                    unlockOnly.isLocked = false
                    guard context.permitsUnlock, node.isLocked, new?.elements[node.id] == unlockOnly else { throw DiagramError.protectedContent(node.id) }
                }
                if let changed = new?.elements[node.id],
                   node.frame != changed.frame || node.parentID != changed.parentID || node.containerID != changed.containerID {
                    if let protected = old.descendants(of: [node.id]).first(where: { old.isEffectivelyLocked($0) }) { throw DiagramError.protectedContent(protected) }
                }
            }
            if let newPage, let new {
                for added in newPage.elements where old.elements[added.id] == nil {
                    if scope.elementIDs != nil {
                        var candidate = added.parentID, visited: Set<UUID> = []
                        while let p = candidate, !allowed.contains(p), visited.insert(p).inserted { candidate = new.elements[p]?.parentID }
                        guard onPage, candidate.map(allowed.contains) == true else { throw DiagramError.outsideSelection(added.id) }
                    } else if !onPage { throw DiagramError.outsideSelection(added.id) }
                    if let parent = added.parentID, old.isEffectivelyLocked(parent) { throw DiagramError.protectedContent(parent) }
                    if let container = added.containerID, old.isEffectivelyLocked(container) { throw DiagramError.protectedContent(container) }
                    if let task = added.taskID { permittedTasks.insert(task) }
                    permittedAssets.formUnion(added.content.compactMap(\.assetID))
                }
                for changed in newPage.elements where allowed.contains(changed.id) { permittedAssets.formUnion(changed.content.compactMap(\.assetID)) }
            }
            let newEdges = Dictionary((newPage?.connections ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for edge in oldPage.connections where newEdges[edge.id] != edge {
                if edge.isLocked { throw DiagramError.protectedContent(edge.id) }
                let cascadeDelete = newEdges[edge.id] == nil && ((allowed.contains(edge.from) && new?.elements[edge.from] == nil) || (allowed.contains(edge.to) && new?.elements[edge.to] == nil))
                if limited && !scope.connectionIDs.contains(edge.id) && !(allowed.contains(edge.from) && allowed.contains(edge.to)) && !cascadeDelete { throw DiagramError.outsideSelection(edge.id) }
                if old.isEffectivelyLocked(edge.from) || old.isEffectivelyLocked(edge.to) { throw DiagramError.protectedContent(edge.id) }
            }
            let oldEdgeIDs = Set(oldPage.connections.map(\.id))
            for edge in newPage?.connections ?? [] where !oldEdgeIDs.contains(edge.id) {
                if limited && !scope.connectionIDs.contains(edge.id) && !(allowed.contains(edge.from) && allowed.contains(edge.to)) { throw DiagramError.outsideSelection(edge.id) }
                if old.isEffectivelyLocked(edge.from) || old.isEffectivelyLocked(edge.to) { throw DiagramError.protectedContent(edge.id) }
            }
        }
        let oldTasks = Dictionary(before.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newTasks = Dictionary(after.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let created = after.tasks.filter { oldTasks[$0.id] == nil }
        if scope.allowsNewTasks { permittedTasks.formUnion(created.map(\.id)) }
        if scope.includeDescendants {
            let children = Dictionary(grouping: created.filter { $0.parentID != nil },by: { $0.parentID! })
            var queue = Array(permittedTasks), cursor = 0
            while cursor < queue.count { let id = queue[cursor]; cursor += 1; for child in children[id] ?? [] where permittedTasks.insert(child.id).inserted { queue.append(child.id) } }
        }
        for id in Set(oldTasks.keys).union(newTasks.keys) where oldTasks[id] != newTasks[id] {
            if limited && !permittedTasks.contains(id) { throw DiagramError.outsideSelection(id) }
            if let parent = newTasks[id]?.parentID, oldTasks[id]?.parentID != parent {
                if limited && !permittedTasks.contains(parent) { throw DiagramError.outsideSelection(parent) }
                if let owner = lockedTaskOwners[parent] { throw DiagramError.protectedContent(owner) }
            }
            if let owner = lockedTaskOwners[id] { throw DiagramError.protectedContent(owner) }
        }
        let oldAssets = Dictionary(before.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newAssets = Dictionary(after.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in Set(oldAssets.keys).union(newAssets.keys) where oldAssets[id] != newAssets[id] {
            if lockedAssets.contains(id) { throw DiagramError.protectedContent(id) }
            if limited && (outsideAssets.contains(id) || !permittedAssets.contains(id)) { throw DiagramError.outsideSelection(id) }
        }
        let changedDependencies = Set(before.dependencies).symmetricDifference(Set(after.dependencies)), remainingDependencies = Set(after.dependencies.map(\.id))
        for dependency in changedDependencies {
            let endpoints = [dependency.predecessorID,dependency.successorID]
            let cascade = !remainingDependencies.contains(dependency.id) && endpoints.contains { permittedTasks.contains($0) && oldTasks[$0] != nil && newTasks[$0] == nil }
            if limited && !cascade && !endpoints.allSatisfy(permittedTasks.contains) { throw DiagramError.outsideSelection(dependency.id) }
            if let owner = endpoints.compactMap({ lockedTaskOwners[$0] }).first { throw DiagramError.protectedContent(owner) }
        }
    }
}
