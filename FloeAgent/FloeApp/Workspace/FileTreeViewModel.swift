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
import FloeTools

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

struct VisibleFileTreeNode: Identifiable, Sendable {
    let node: FileTreeNode
    let depth: Int
    var id: String { node.id }
}

/// Drives the inspector's directory tree: lazy page loading plus a
/// debounced search that switches the tree into a flat hit list.
@MainActor
final class FileTreeViewModel: ObservableObject {

    /// Root-level nodes (loaded on appear / refresh).
    @Published private(set) var rootNodes: [FileTreeNode] = []
    /// Search hits while `query` is non-empty (flat list, not a tree).
    @Published private(set) var searchHits: [SearchHit] = []
    @Published private(set) var searchInProgress = false
    /// Current search text. Empty = tree mode.
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var expandedDirectoryPaths: Set<String> = []

    private let center: WorkspaceCenter
    private var searchTask: Task<Void, Never>?
    deinit { searchTask?.cancel() }

    init(center: WorkspaceCenter) {
        self.center = center
    }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var visibleNodes: [VisibleFileTreeNode] {
        func append(_ nodes: [FileTreeNode], depth: Int, into result: inout [VisibleFileTreeNode]) {
            for node in nodes {
                result.append(VisibleFileTreeNode(node: node, depth: depth))
                if expandedDirectoryPaths.contains(node.relativePath), let children = node.children {
                    append(children, depth: depth + 1, into: &result)
                }
            }
        }
        var result: [VisibleFileTreeNode] = []
        append(rootNodes, depth: 0, into: &result)
        return result
    }

    // MARK: - Loading

    /// Loads (or reloads) the first page of the root directory.
    func loadRoot() async {
        guard center.fileService != nil else {
            rootNodes = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await center.listDirectory(relativePath: ".")
            rootNodes = page.entries.map(Self.node(from:))
            expandedDirectoryPaths = []
            errorMessage = nil
        } catch {
            rootNodes = []
            errorMessage = error.localizedDescription
        }
    }

    /// Lazily loads a directory's children on first disclosure.
    func loadChildren(of node: FileTreeNode) async -> [FileTreeNode] {
        guard node.isDirectory, center.fileService != nil else { return [] }
        do {
            let page = try await center.listDirectory(relativePath: node.relativePath)
            return page.entries.map(Self.node(from:))
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func toggleDirectory(_ node: FileTreeNode) async {
        guard node.isDirectory else { return }
        if expandedDirectoryPaths.contains(node.relativePath) {
            expandedDirectoryPaths.remove(node.relativePath)
            return
        }
        if node.children == nil {
            let children = await loadChildren(of: node)
            replaceNode(at: node.relativePath) { value in value.children = children }
        }
        expandedDirectoryPaths.insert(node.relativePath)
    }

    private func replaceNode(
        at path: String,
        transform: (inout FileTreeNode) -> Void
    ) {
        func replace(in nodes: inout [FileTreeNode]) -> Bool {
            for index in nodes.indices {
                if nodes[index].relativePath == path {
                    transform(&nodes[index])
                    return true
                }
                if var children = nodes[index].children,
                   replace(in: &children) {
                    nodes[index].children = children
                    return true
                }
            }
            return false
        }
        _ = replace(in: &rootNodes)
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

    func move(_ node: FileTreeNode, to path: String) async throws {
        guard !center.isCloudWorkspacePath(node.relativePath), !center.isNetworkWorkspacePath(node.relativePath),
              !center.isCloudWorkspacePath(path), !center.isNetworkWorkspacePath(path) else {
            throw CocoaError(.featureUnsupported)
        }
        try center.move(from: node.relativePath, to: path)
        await loadRoot()
    }

    func exportURL(_ node: FileTreeNode) throws -> URL {
        guard !node.isDirectory, !center.isCloudWorkspacePath(node.relativePath),
              !center.isNetworkWorkspacePath(node.relativePath), let service = center.fileService else {
            throw CocoaError(.featureUnsupported)
        }
        let url = try service.guardResolver.resolve(node.relativePath)
        try service.guardResolver.assertReadableSize(url)
        return url
    }

    // MARK: - Compression (multi-select Compress)

    /// Root of the current task workspace; nil before a workspace is open.
    var workspaceRootURL: URL? {
        center.fileService?.guardResolver.rootURL ?? center.currentRootURL
    }

    /// Host URL for one tree node — files and directories alike — inside the
    /// current task workspace. Cloud/network paths keep refusing, exactly like
    /// every other local tree mutation.
    func workspaceURL(_ node: FileTreeNode) throws -> URL {
        guard !center.isCloudWorkspacePath(node.relativePath),
              !center.isNetworkWorkspacePath(node.relativePath),
              let service = center.fileService else {
            throw CocoaError(.featureUnsupported)
        }
        return try service.guardResolver.resolve(node.relativePath)
    }

    /// Whether a workspace-relative path already exists (archive destination
    /// conflict probe). Cloud/network paths answer true so a local archive can
    /// never overwrite a linked workspace entry.
    func pathExists(_ relativePath: String) -> Bool {
        guard !center.isCloudWorkspacePath(relativePath),
              !center.isNetworkWorkspacePath(relativePath),
              let root = workspaceRootURL else { return true }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    /// Collapses a selection to its top-most paths: a selected folder already
    /// includes its selected descendants, and the engine would otherwise
    /// refuse the duplicate entry names.
    static func selectionRoots(_ paths: Set<String>) -> [String] {
        paths.filter { path in !paths.contains { other in path.hasPrefix(other + "/") } }.sorted()
    }

    /// Progress of the in-flight Compress action, driven by the engine's own
    /// bounded scan/write callbacks.
    @Published private(set) var compressProgress: ArchiveProgress?

    /// Compresses the selected workspace items into one new archive at the
    /// workspace root through the shared `ArchiveBrowserService` — the same
    /// native engine every other archive operation uses, no second service.
    /// The destination must already be conflict-free (the surface resolves it
    /// with `WorkspaceArchiveCompression.uniqueName`); the tree is reloaded
    /// after a successful create.
    func compress(
        paths: Set<String>,
        destinationName: String,
        format: String,
        cancellation: CancellationToken
    ) async throws -> String {
        let roots = Self.selectionRoots(paths)
        guard !roots.isEmpty else {
            throw ArchiveBrowseError.failed("Select at least one item to compress.")
        }
        guard let root = workspaceRootURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        for path in roots where center.isCloudWorkspacePath(path) || center.isNetworkWorkspacePath(path) {
            throw CocoaError(.featureUnsupported)
        }
        compressProgress = nil
        let service = ArchiveBrowserService(rootProvider: { root })
        do {
            let summary = try await service.createArchive(
                sources: roots,
                destinationFile: destinationName,
                format: format,
                rootURL: root,
                cancellation: cancellation,
                progress: { [weak self] value in
                    Task { @MainActor in
                        self?.compressProgress = value
                    }
                }
            )
            compressProgress = nil
            await loadRoot()
            return summary
        } catch {
            compressProgress = nil
            throw error
        }
    }

    func deleteBatch(_ paths: Set<String>) async -> [String: String] {
        // Selecting a folder already includes its descendants. Avoid reporting
        // their successful recursive removal as separate missing-file errors.
        let roots = paths.filter { path in !paths.contains { other in path.hasPrefix(other + "/") } }.sorted()
        var failures: [String: String] = [:]
        for path in roots {
            do {
                guard !center.isCloudWorkspacePath(path), !center.isNetworkWorkspacePath(path) else {
                    throw CocoaError(.featureUnsupported)
                }
                try center.delete(relativePath: path, recursive: true)
            } catch { failures[path] = error.localizedDescription }
        }
        await loadRoot()
        return failures
    }

    // MARK: - Search

    /// Debounced search: waits 300 ms after the last keystroke.
    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            searchInProgress = false
            errorMessage = nil
            return
        }
        searchInProgress = true
        searchHits = []
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            defer { if !Task.isCancelled { self.searchInProgress = false } }
            guard let service = self.center.fileService else { return }
            let workspaceID = self.center.currentWorkspace?.id
            let cancellation = CancellationToken()
            do {
                let hits = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) {
                        var hits = try service.search(query: trimmed, in: "", cancellation: cancellation)
                        let matched = Set(hits.map(\.relativePath))
                        let names = try service.searchFileNames(query: trimmed, cancellation: cancellation)
                        for name in names where !name.hasSuffix("/") && !matched.contains(name) {
                            hits.append(SearchHit(relativePath: name, lineNumber: 0, context: (name as NSString).lastPathComponent))
                        }
                        return Array(hits.prefix(WorkspaceFileService.maxSearchHits))
                    }.value
                } onCancel: { cancellation.cancel() }
                guard !Task.isCancelled, self.center.currentWorkspace?.id == workspaceID else { return }
                self.searchHits = hits
                self.errorMessage = nil
            } catch {
                guard !Task.isCancelled, self.center.currentWorkspace?.id == workspaceID else { return }
                self.searchHits = []
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
