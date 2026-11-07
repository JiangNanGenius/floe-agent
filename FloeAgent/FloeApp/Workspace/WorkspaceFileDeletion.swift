// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkspace

enum WorkspaceFileDeletionError: Error, LocalizedError {
    case changed, closeFirst, external
    var errorDescription: String? {
        switch self {
        case .changed: IDELanguageRunText.t("文件或工作区已改变，请重新选择。", "The file or workspace changed. Select it again.")
        case .closeFirst: IDELanguageRunText.t("请先保存并关闭正在使用这个文件的编辑器，再删除。", "Save and close editors using this file before deleting it.")
        case .external: IDELanguageRunText.t("请在文件所在位置管理这个文件，外部原件会保留。", "Manage this file at its original location. The external original is kept.")
        }
    }
}

struct WorkspaceFileActionScope: Equatable, Sendable {
    let workspaceID: UUID
    let root: URL
    @MainActor init(center: WorkspaceCenter) throws {
        guard let id = center.currentWorkspace?.id, let service = center.fileService else { throw WorkspaceFileDeletionError.changed }
        workspaceID = id; root = service.guardResolver.rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }
    @MainActor func validate(_ center: WorkspaceCenter) throws {
        guard try Self(center: center) == self else { throw WorkspaceFileDeletionError.changed }
    }
}

struct WorkspaceFileDeletionRequest: Identifiable, Sendable {
    let id = UUID()
    let scope: WorkspaceFileActionScope
    let relativePath: String
    let metadata: WorkspaceFileMetadata
    let resolvedURL: URL
    var name: String { (relativePath as NSString).lastPathComponent }
    var isDirectory: Bool { metadata.isDirectory }
}

/// UI confirmation owns an exact path/workspace/root and selected disk version.
/// It adds no capability and commits through the existing guarded file service.
@MainActor enum WorkspaceFileDeletion {
    static func prepare(path: String, scope: WorkspaceFileActionScope, center: WorkspaceCenter) async throws -> WorkspaceFileDeletionRequest {
        try scope.validate(center)
        guard let service = center.fileService else { throw WorkspaceFileDeletionError.changed }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !pieces.dropLast().contains(where: { ["floecad", "floeproject"].contains((String($0) as NSString).pathExtension.lowercased()) }),
              !center.isCloudWorkspacePath(path), !center.isNetworkWorkspacePath(path) else { throw WorkspaceFileDeletionError.external }
        let url = try service.guardResolver.resolve(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(scope.root.path + "/") else { throw WorkspaceFileDeletionError.external }
        var raw = scope.root
        for piece in pieces {
            raw.appendPathComponent(String(piece))
            guard try raw.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw WorkspaceFileDeletionError.external }
        }
        let worker = Task.detached(priority: .userInitiated) { try service.deletionMetadata(path) }
        let metadata = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); try scope.validate(center)
        guard !metadata.isSymlink else { throw WorkspaceFileDeletionError.external }
        return .init(scope: scope, relativePath: path, metadata: metadata, resolvedURL: url)
    }

    static func commit(_ request: WorkspaceFileDeletionRequest, center: WorkspaceCenter) throws {
        try Task.checkCancellation(); try request.scope.validate(center)
        guard let service = center.fileService else { throw WorkspaceFileDeletionError.changed }
        guard !center.isCloudWorkspacePath(request.relativePath), !center.isNetworkWorkspacePath(request.relativePath) else { throw WorkspaceFileDeletionError.external }
        let url = try service.guardResolver.resolve(request.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(request.scope.root.path + "/") else { throw WorkspaceFileDeletionError.external }
        guard url == request.resolvedURL.standardizedFileURL else { throw WorkspaceFileDeletionError.changed }
        try OfficeLiveSessionRegistry.shared.requireClosedForFileAction(root: request.scope.root, relativePath: request.relativePath)
        try FloeCAD3DBridge.shared.requireClosedForFileAction(at: url)
        try center.delete(relativePath: request.relativePath, recursive: request.isDirectory, expectedMetadata: request.metadata, expectedResolvedURL: request.resolvedURL)
    }
}
#endif
