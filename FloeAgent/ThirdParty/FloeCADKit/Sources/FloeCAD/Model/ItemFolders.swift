//
//  ItemFolders.swift
//  openshape3d
//
//  Items Manager folders (spec §11): a per-document tree that groups scene
//  items — bodies, sketches, construction planes and axes, inserted images.
//  A folder owns an ordered member list; an item is in at most one folder.
//  Membership lives on the folder, not the item, so no item type's Codable
//  or persistence path changes: the whole tree is one JSON blob on the
//  project (`Project.itemFoldersData`), diffed like any other column.
//
//  Members that no longer exist in the document are simply not listed —
//  they are NOT pruned eagerly, so deleting a body and undoing it puts the
//  body back in its folder.
//

import Foundation

nonisolated struct ItemFolderID: Hashable, Codable, Sendable {
    let raw: UUID
    init(raw: UUID = UUID()) { self.raw = raw }
}

/// A scene item a folder can hold. Symbols are not scene items (no eye, no
/// Zoom to) and stay out, as they do in the Items panel's own sections.
nonisolated enum DocumentItemKey: Hashable, Codable, Sendable {
    case body(BodyID)
    case sketch(SketchID)
    case plane(ConstructionPlaneID)
    case axis(ConstructionAxisID)
    case image(InsertedImageID)
}

nonisolated struct ItemFolder: Identifiable, Codable, Equatable, Sendable {
    let id: ItemFolderID
    var name: String
    /// `nil` = a top-level folder.
    var parentID: ItemFolderID?
    var members: [DocumentItemKey]

    init(id: ItemFolderID = ItemFolderID(), name: String, parentID: ItemFolderID? = nil,
         members: [DocumentItemKey] = []) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.members = members
    }
}

/// Pure operations over `[ItemFolder]`. Every mutation returns the new
/// array, so `SetItemFoldersCommand` can carry before/after for undo and
/// the logic is testable without a document.
nonisolated struct ItemFolderTree: Sendable {
    let folders: [ItemFolder]
    private let byID: [ItemFolderID: ItemFolder]

    init(_ folders: [ItemFolder]) {
        self.folders = folders
        var byID: [ItemFolderID: ItemFolder] = [:]
        for folder in folders { byID[folder.id] = folder }
        self.byID = byID
    }

    var isEmpty: Bool { folders.isEmpty }

    func folder(_ id: ItemFolderID) -> ItemFolder? { byID[id] }

    func exists(_ id: ItemFolderID?) -> Bool {
        guard let id else { return true }
        return byID[id] != nil
    }

    /// The parent a folder is listed under (top level for an orphan or a
    /// self-parent, so damaged data never hides a folder).
    func parent(of id: ItemFolderID) -> ItemFolderID? {
        guard let folder = byID[id], let parent = folder.parentID,
              parent != id, byID[parent] != nil else { return nil }
        return parent
    }

    /// Direct child folders in creation order.
    func children(of parent: ItemFolderID?) -> [ItemFolder] {
        folders.filter { self.parent(of: $0.id) == parent }
    }

    /// Top level → … → `id`; empty for an unknown ID. Cycle-safe.
    func path(to id: ItemFolderID?) -> [ItemFolder] {
        var chain: [ItemFolder] = []
        var seen: Set<ItemFolderID> = []
        var cursor = id
        while let current = cursor, let folder = byID[current], seen.insert(current).inserted {
            chain.append(folder)
            cursor = parent(of: current)
        }
        return chain.reversed()
    }

    /// Every folder below `id`, depth-first. Excludes `id`.
    func descendants(of id: ItemFolderID) -> [ItemFolder] {
        var out: [ItemFolder] = []
        var seen: Set<ItemFolderID> = [id]
        func visit(_ parent: ItemFolderID) {
            for child in children(of: parent) where seen.insert(child.id).inserted {
                out.append(child)
                visit(child.id)
            }
        }
        visit(id)
        return out
    }

    /// Items in `id` and every folder below it, in display order.
    func keys(inSubtree id: ItemFolderID) -> [DocumentItemKey] {
        guard let folder = byID[id] else { return [] }
        return folder.members + descendants(of: id).flatMap(\.members)
    }

    func folder(containing key: DocumentItemKey) -> ItemFolderID? {
        folders.first { $0.members.contains(key) }?.id
    }

    /// Everything that sits in some folder — the Items panel lists the rest
    /// in its type sections.
    var filedKeys: Set<DocumentItemKey> {
        Set(folders.flatMap(\.members))
    }

    /// A folder may move anywhere except into itself or its own subtree.
    func canMove(folder id: ItemFolderID, into destination: ItemFolderID?) -> Bool {
        guard byID[id] != nil, exists(destination) else { return false }
        guard let destination else { return true }
        if destination == id { return false }
        return !path(to: destination).contains { $0.id == id }
    }

    /// Depth-first rows with depth, for menus and pickers.
    func flattened() -> [(folder: ItemFolder, depth: Int)] {
        var rows: [(folder: ItemFolder, depth: Int)] = []
        var seen: Set<ItemFolderID> = []
        func visit(_ parent: ItemFolderID?, depth: Int) {
            for child in children(of: parent) where seen.insert(child.id).inserted {
                rows.append((child, depth))
                visit(child.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return rows
    }

    /// "Folder 1", "Folder 2", … across the whole document (Shapr3D numbers
    /// items globally, like sketches).
    func uniqueName(base: String = "Folder") -> String {
        let existing = Set(folders.map(\.name))
        var n = 1
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Mutations (return the new array)

    /// Add a folder; its members leave whatever folder they were in.
    func adding(_ folder: ItemFolder) -> [ItemFolder] {
        var out = Self.removing(keys: Set(folder.members), from: folders)
        var clean = folder
        clean.parentID = exists(folder.parentID) ? folder.parentID : nil
        clean.members = Self.deduplicated(folder.members)
        out.append(clean)
        return out
    }

    /// Move items into `destination` (`nil` = out of every folder), appended
    /// in the given order; an item already there keeps its place.
    func moving(_ keys: [DocumentItemKey], to destination: ItemFolderID?) -> [ItemFolder] {
        guard exists(destination) else { return folders }
        let wanted = Self.deduplicated(keys)
        guard let destination else {
            return Self.removing(keys: Set(wanted), from: folders)
        }
        var out = folders
        for index in out.indices {
            if out[index].id == destination {
                let present = Set(out[index].members)
                out[index].members.append(contentsOf: wanted.filter { !present.contains($0) })
            } else {
                out[index].members.removeAll { wanted.contains($0) }
            }
        }
        return out
    }

    func reparenting(_ id: ItemFolderID, to parent: ItemFolderID?) -> [ItemFolder] {
        guard canMove(folder: id, into: parent) else { return folders }
        var out = folders
        if let index = out.firstIndex(where: { $0.id == id }) { out[index].parentID = parent }
        return out
    }

    func renaming(_ id: ItemFolderID, to name: String) -> [ItemFolder] {
        var out = folders
        if let index = out.firstIndex(where: { $0.id == id }) { out[index].name = name }
        return out
    }

    /// Remove one folder and keep what it held: its items and child folders
    /// move up to its parent (or the top level).
    func removingKeepingContents(_ id: ItemFolderID) -> [ItemFolder] {
        guard let folder = byID[id] else { return folders }
        let parent = self.parent(of: id)
        var out = folders.filter { $0.id != id }
        for index in out.indices where out[index].parentID == id {
            out[index].parentID = parent
        }
        if let parent, let index = out.firstIndex(where: { $0.id == parent }) {
            let present = Set(out[index].members)
            out[index].members.append(contentsOf: folder.members.filter { !present.contains($0) })
        }
        return out
    }

    /// Remove a folder and its whole subtree (the caller deletes the items).
    func removingSubtree(_ id: ItemFolderID) -> [ItemFolder] {
        let doomed = Set([id] + descendants(of: id).map(\.id))
        return folders.filter { !doomed.contains($0.id) }
    }

    /// Drop members the document no longer holds (used when saving).
    func pruned(to existing: Set<DocumentItemKey>) -> [ItemFolder] {
        folders.map { folder in
            var f = folder
            f.members.removeAll { !existing.contains($0) }
            return f
        }
    }

    private static func removing(keys: Set<DocumentItemKey>, from folders: [ItemFolder]) -> [ItemFolder] {
        folders.map { folder in
            var f = folder
            f.members.removeAll { keys.contains($0) }
            return f
        }
    }

    private static func deduplicated(_ keys: [DocumentItemKey]) -> [DocumentItemKey] {
        var seen: Set<DocumentItemKey> = []
        return keys.filter { seen.insert($0).inserted }
    }
}

/// One undo step over the folder tree: the whole (small) array before and
/// after. Every folder edit — create, rename, move, remove — is one of these.
struct SetItemFoldersCommand: DocumentCommand {
    let title: String
    let before: [ItemFolder]
    let after: [ItemFolder]

    func apply(to document: inout DesignDocument) { document.itemFolders = after }
    func revert(in document: inout DesignDocument) { document.itemFolders = before }
}
