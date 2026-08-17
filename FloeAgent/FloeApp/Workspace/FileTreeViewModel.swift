// FloeApp — Lazy file tree view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §4: the directory tree lazily
// loads children through WorkspaceFileService.listDirectory (200-entry
// pages) and filters through WorkspaceFileService.search. Every file
// access goes through WorkspacePathGuard inside the service.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeWorkspace

/// One node in the lazily loaded directory tree.
struct FileTreeNode: Identifiable, Hashable, Sendable {
    /// Workspace-relative path ("" only for the synthetic root).
    let relativePath: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    /// Lazily loaded children; nil = not loaded yet, [] = loaded & empty.
    var children: [FileTreeNode]?

    var id: String { relativePath }
}

/// Drives the inspector's directory tree: lazy page loading plus a
/// debounced search that switches the tree into a flat hit list.
@MainActor
final class FileTreeViewModel: ObservableObject {

    /// Root-level nodes (loaded on appear / refresh).
    @Published private(set) var rootNodes: [FileTreeNode] = []
    /// Search hits while `query` is non-empty (flat list, not a tree).
    @Published private(set) var searchHits: [SearchHit] = []
    /// Current search text. Empty = tree mode.
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let center: WorkspaceCenter
    private var searchTask: Task<Void, Never>?

    init(center: WorkspaceCenter) {
        self.center = center
    }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Loading

    /// Loads (or reloads) the first page of the root directory.
    func loadRoot() async {
        guard let service = center.fileService else {
            rootNodes = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try service.listDirectory(".", pageToken: nil)
            rootNodes = page.entries.map(Self.node(from:))
            errorMessage = nil
        } catch {
            rootNodes = []
            errorMessage = error.localizedDescription
        }
    }

    /// Lazily loads a directory's children on first disclosure.
    func loadChildren(of node: FileTreeNode) async -> [FileTreeNode] {
        guard node.isDirectory, let service = center.fileService else { return [] }
        do {
            let page = try service.listDirectory(node.relativePath, pageToken: nil)
            return page.entries.map(Self.node(from:))
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    private static func node(from node: FileNode) -> FileTreeNode {
        FileTreeNode(
            relativePath: node.relativePath,
            name: node.name,
            isDirectory: node.isDirectory,
            size: node.size,
            children: node.isDirectory ? nil : nil
        )
    }

    // MARK: - Mutations

    /// Creates a directory under `parent` and reloads the tree.
    func createDirectory(parent relativePath: String, name: String) async throws {
        let path = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
        try center.createDirectory(relativePath: path)
        await loadRoot()
    }

    /// Deletes a node and reloads the tree.
    func delete(_ node: FileTreeNode, recursive: Bool = false) async throws {
        try center.delete(relativePath: node.relativePath, recursive: recursive)
        await loadRoot()
    }

    /// Renames a node (a move within its parent directory).
    func rename(_ node: FileTreeNode, to newName: String) async throws {
        let parent = (node.relativePath as NSString).deletingLastPathComponent
        let destination = parent.isEmpty ? newName : "\(parent)/\(newName)"
        try center.move(from: node.relativePath, to: destination)
        await loadRoot()
    }

    // MARK: - Search

    /// Debounced search: waits 300 ms after the last keystroke.
    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            return
        }
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let service = self.center.fileService else { return }
            do {
                self.searchHits = try service.search(query: trimmed, in: "")
                self.errorMessage = nil
            } catch {
                self.searchHits = []
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
