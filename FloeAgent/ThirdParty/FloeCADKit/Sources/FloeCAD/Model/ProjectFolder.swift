//
//  ProjectFolder.swift
//  openshape3d
//
//  Project folders (spec §13.1, Shapr3D 5.492 "Folders are here"): the
//  gallery organises designs into nested folders with a sidebar, breadcrumbs,
//  back/forward history and drag-and-drop.
//
//  Membership is by scalar ID on purpose. `Project.folderID` and
//  `ProjectFolder.parentID` are plain defaulted columns, so an existing store
//  migrates lightly (every old project lands in the root), the seventeen unit
//  tests that build a `Schema([Project.self, …])` keep working without
//  listing a new type, and there is no self-referential SwiftData
//  relationship to fight. The cost is that "delete a folder" cascades by
//  hand — `ProjectFolderTree.descendants` is the one place that knows what
//  is inside a folder.
//

import Foundation
import SwiftData

@Model
final class ProjectFolder {
    @Attribute(.unique) var folderID: UUID = UUID()
    var name: String = "Untitled Folder"
    /// `nil` = a top-level folder (directly under "Designs").
    var parentID: UUID? = nil
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init(name: String, parentID: UUID?) {
        self.folderID = UUID()
        self.name = name
        self.parentID = parentID
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}

// MARK: - Pure tree logic (unit-tested without SwiftData)

/// A folder as the tree logic sees it: ID, name, parent. Built from
/// `ProjectFolder` rows by the gallery; built by hand in tests.
nonisolated struct FolderNode: Hashable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var parentID: UUID?

    init(id: UUID, name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

/// Read-only view over a set of folder nodes: children, ancestor paths,
/// descendants, move legality and unique sibling names. Rebuilt from the
/// live query whenever the gallery renders; cheap for any realistic library.
nonisolated struct ProjectFolderTree: Sendable {
    let nodes: [FolderNode]
    private let byID: [UUID: FolderNode]
    private let childrenByParent: [UUID?: [FolderNode]]

    init(_ nodes: [FolderNode]) {
        self.nodes = nodes
        var byID: [UUID: FolderNode] = [:]
        for node in nodes { byID[node.id] = node }
        self.byID = byID
        var grouped: [UUID?: [FolderNode]] = [:]
        for node in nodes {
            // A parent that no longer exists (or a self-parent) reads as root,
            // so a damaged row can never vanish from every listing.
            let parent = (node.parentID.map { byID[$0] != nil } ?? false)
                && node.parentID != node.id ? node.parentID : nil
            grouped[parent, default: []].append(node)
        }
        for key in grouped.keys {
            grouped[key]?.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        self.childrenByParent = grouped
    }

    init() { self.init([]) }

    var isEmpty: Bool { nodes.isEmpty }

    func node(_ id: UUID) -> FolderNode? { byID[id] }

    /// Root (`nil`) always exists; a folder exists when a node carries its ID.
    func exists(_ id: UUID?) -> Bool {
        guard let id else { return true }
        return byID[id] != nil
    }

    /// The parent a folder is listed under (the root for orphans).
    func parent(of id: UUID?) -> UUID? {
        guard let id, let node = byID[id], let parent = node.parentID,
              parent != id, byID[parent] != nil else { return nil }
        return parent
    }

    /// Direct children, sorted by name (Finder-style numeric-aware order).
    func children(of parent: UUID?) -> [FolderNode] {
        childrenByParent[parent] ?? []
    }

    /// Root → … → `id`. Empty for the root or an unknown ID. Guards against
    /// a cycle in damaged data by stopping at the first repeated node.
    func path(to id: UUID?) -> [FolderNode] {
        var chain: [FolderNode] = []
        var seen: Set<UUID> = []
        var cursor = id
        while let current = cursor, let node = byID[current], seen.insert(current).inserted {
            chain.append(node)
            cursor = parent(of: current)
        }
        return chain.reversed()
    }

    /// Everything below `id`, depth-first in display order. Excludes `id`.
    func descendants(of id: UUID) -> [FolderNode] {
        var out: [FolderNode] = []
        var stack = children(of: id).reversed().map { $0 }
        var seen: Set<UUID> = [id]
        while let node = stack.popLast() {
            guard seen.insert(node.id).inserted else { continue }
            out.append(node)
            stack.append(contentsOf: children(of: node.id).reversed())
        }
        return out
    }

    /// True when `candidate` is `ancestor` itself or sits anywhere below it.
    func isSelfOrDescendant(_ candidate: UUID?, of ancestor: UUID) -> Bool {
        guard let candidate else { return false }
        if candidate == ancestor { return true }
        return path(to: candidate).contains { $0.id == ancestor }
    }

    /// A folder may move anywhere except into itself or its own subtree.
    func canMove(folder: UUID, into destination: UUID?) -> Bool {
        guard byID[folder] != nil, exists(destination) else { return false }
        return !isSelfOrDescendant(destination, of: folder)
    }

    /// Depth-first rows with their depth, for the sidebar and the move
    /// picker. With `expanded` given, children of a collapsed folder are
    /// left out (the sidebar); `nil` lists everything (the picker).
    func flattened(expanded: Set<UUID>? = nil) -> [(node: FolderNode, depth: Int)] {
        var rows: [(node: FolderNode, depth: Int)] = []
        var seen: Set<UUID> = []
        func visit(_ parent: UUID?, depth: Int) {
            for child in children(of: parent) where seen.insert(child.id).inserted {
                rows.append((child, depth))
                if expanded == nil || expanded!.contains(child.id) {
                    visit(child.id, depth: depth + 1)
                }
            }
        }
        visit(nil, depth: 0)
        return rows
    }

    /// "Untitled Folder", then "Untitled Folder 2", … among `siblings`.
    static func uniqueName(base: String, among siblings: [String]) -> String {
        let existing = Set(siblings)
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// Browser-style folder history for the gallery: where you are, where Back
/// goes, where Forward goes. `nil` is the root ("Designs").
nonisolated struct FolderNavigationHistory: Equatable, Sendable {
    private(set) var current: UUID? = nil
    private(set) var backStack: [UUID?] = []
    private(set) var forwardStack: [UUID?] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Navigate somewhere new: the old location becomes Back, Forward clears.
    mutating func go(to folder: UUID?) {
        guard folder != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = folder
    }

    mutating func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    mutating func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }

    /// Deleted folders drop out of the history: every reference to one is
    /// replaced by `fallback` (the nearest surviving ancestor), and the runs
    /// of identical entries that produces collapse so Back never lands on
    /// the page you are already on.
    mutating func removing(_ deleted: Set<UUID>, fallback: UUID?) {
        func replace(_ id: UUID?) -> UUID? {
            guard let id, deleted.contains(id) else { return id }
            return fallback
        }
        current = replace(current)
        backStack = Self.collapsingRuns(backStack.map(replace), next: current)
        forwardStack = Self.collapsingRuns(forwardStack.map(replace), next: current)
    }

    /// Drop consecutive duplicates, and a trailing entry equal to `next`
    /// (the entry a pop would move onto).
    private static func collapsingRuns(_ entries: [UUID?], next: UUID?) -> [UUID?] {
        var out: [UUID?] = []
        for entry in entries {
            if let last = out.last, last == entry { continue }
            out.append(entry)
        }
        while let last = out.last, last == next { out.removeLast() }
        return out
    }
}
