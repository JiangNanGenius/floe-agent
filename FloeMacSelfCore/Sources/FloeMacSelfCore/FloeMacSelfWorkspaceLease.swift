// SPDX-License-Identifier: MPL-2.0
//
// Bookmark-bound workspace ownership for tool-enabled sessions. A matching
// workspace UUID alone never grants a directory: the host-declared boundary
// root must equal the exact root persisted with the durable workspace row.
// Project rows carry their root as a security-scoped bookmark; private-task
// rows carry an empty bookmark by design and resolve under the
// host-configured private task root base. The lease is verified at
// admission against the row read by the launch transaction and re-verified
// from durable storage immediately before dispatch.

import Foundation
import FloeCore
import FloeModels

enum FloeMacSelfWorkspaceLease {
    static func recoveryIdentity(for root: URL?) -> String? {
        guard let root else { return "unbound" }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return FloeDigest.sha256Hex(Data("\(resolved.path)\n\(device)\n\(inode)".utf8))
    }

    /// Resolves the exact root the durable workspace row authorizes and
    /// proves it equals the host-verified boundary root. Returns the verified
    /// resolved root on success; throws `invalidTaskBoundary` on any mismatch,
    /// stale bookmark or missing directory.
    static func verifiedRoot(
        workspace: WorkspaceRecord,
        boundaryRoot: URL,
        privateTaskRootBase: URL?
    ) throws -> URL {
        let resolvedBoundary = boundaryRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let persistedRoot = try resolveRoot(workspace: workspace, privateTaskRootBase: privateTaskRootBase)
        guard persistedRoot == resolvedBoundary else {
            throw FloeMacSelfCoreError.invalidTaskBoundary(
                "the boundary root does not match the persisted workspace root"
            )
        }
        return persistedRoot
    }

    static func resolveRoot(workspace: WorkspaceRecord, privateTaskRootBase: URL?) throws -> URL {
        let persistedRoot: URL
        switch workspace.kind {
        case .project:
            var stale = false
            guard !workspace.rootBookmark.isEmpty,
                  let resolved = try? URL(
                    resolvingBookmarkData: workspace.rootBookmark,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                  ),
                  !stale else {
                throw FloeMacSelfCoreError.invalidTaskBoundary(
                    "the project workspace bookmark cannot be resolved"
                )
            }
            persistedRoot = resolved
                .resolvingSymlinksInPath()
                .standardizedFileURL
        case .privateTask:
            guard let base = privateTaskRootBase else {
                throw FloeMacSelfCoreError.invalidTaskBoundary(
                    "a private-task workspace lease requires the host-configured private task root"
                )
            }
            guard let relative = workspace.internalRelativePath,
                  Self.isSafeRelativePath(relative) else {
                throw FloeMacSelfCoreError.invalidTaskBoundary(
                    "the private-task workspace relative path is invalid"
                )
            }
            persistedRoot = base
                .appendingPathComponent(relative, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: persistedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FloeMacSelfCoreError.invalidTaskBoundary(
                "the persisted workspace root is not an existing directory"
            )
        }
        return persistedRoot
    }

    private static func isSafeRelativePath(_ relative: String) -> Bool {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.utf8.contains(0) else {
            return false
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }
}
