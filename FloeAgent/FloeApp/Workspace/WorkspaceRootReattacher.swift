// FloeApp — Workspace root reattachment for code paths without a live run.
//
// Background downloads can settle in a relaunched process where the run's
// task-root lease is gone. This resolves the conversation's workspace record
// (refreshing a stale bookmark in the store, exactly like
// WorkspaceCenter.resolveRoot) and returns the root with security-scoped
// access started for the caller's file operation.

import Foundation
import FloeCore
import FloePersistence

struct WorkspaceRootReattacher: Sendable {
    let store: any WorkspaceStore

    nonisolated init(store: any WorkspaceStore) {
        self.store = store
    }

    /// Resolves the task root for `conversationID`. The returned `release`
    /// must run after the file operation; it is a no-op for private tasks and
    /// when no workspace record exists.
    nonisolated func acquireRoot(conversationID: UUID) async -> (url: URL, release: @Sendable () -> Void)? {
        guard let workspaceID = try? await store.workspaceID(conversationID: conversationID),
              let record = try? await store.workspace(id: workspaceID) else { return nil }

        if record.kind == .privateTask {
            guard let support = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ) else { return nil }
            let relative = record.internalRelativePath ?? "PrivateTasks/\(conversationID.uuidString)"
            let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
                .appendingPathComponent(relative, isDirectory: true)
            return (root, {})
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: record.rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale,
           let refreshed = try? url.bookmarkData(
               options: [],
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            var updated = record
            updated.rootBookmark = refreshed
            updated.updatedAt = Date()
            try? await store.saveWorkspace(updated)
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return (url, { url.stopAccessingSecurityScopedResource() })
    }
}
