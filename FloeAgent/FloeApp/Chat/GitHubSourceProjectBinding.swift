// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloePersistence

/// The central registration supplies this native resolver. It never consults
/// visible/current project selection and never changes a conversation binding.
@MainActor enum GitHubSourceProjectBinding {
    static func projectID(context: ToolContext, environment: AppEnvironment) async throws -> UUID? {
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        guard !context.temporaryReadOnly, let task = context.conversationID,
              let frozenRoot = context.workspaceRootURL,
              let run = try await environment.runStore.run(id: context.runID), run.conversationID == task,
              let conversation = try await environment.conversationStore.conversation(id: task),
              conversation.purpose != .temporary else { return nil }
        let store = SQLiteWorkspaceStore(database: environment.database)
        guard let workspaceID = try await store.workspaceID(conversationID: task),
              let record = try await store.workspace(id: workspaceID), record.kind == .project else { return nil }
        do {
            let lease = try await environment.workspaceCenter.acquireMemorySourceRoot(record)
            let matches = lease.root.standardizedFileURL.resolvingSymlinksInPath()
                == frozenRoot.standardizedFileURL.resolvingSymlinksInPath()
            await lease.release()
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            guard matches, try await store.workspaceID(conversationID: task) == workspaceID else { return nil }
            return workspaceID
        } catch is CancellationError { throw CancellationError() }
        catch {
            // An unavailable bookmark cannot grant provenance, but does not
            // prevent the already-authorized public GitHub read itself.
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            return nil
        }
    }
}
#endif
