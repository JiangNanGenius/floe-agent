// FloePersistence — retention for the run-lifecycle tables added in schema v46.
//
// The child transcript, relation and dependency tables deliberately have no
// foreign keys (a delegated child is not an ordinary run, and a deleted
// conversation must not silently strip another conversation's rows through a
// shared-parent cascade). Retention is therefore EXPLICIT and transactional:
// removing a conversation removes exactly the rows the conversation owns —
// after the app has cancelled that conversation's own work — in the same
// writer transaction as the conversation delete. A rollback leaves every row
// (and every spool artifact) intact.
//
// Full-output spool artifacts are Floe-owned bookkeeping under one canonical
// root. They are removed only when they actually live inside that root and
// are named after a job UUID; a recorded `resultPath` (a real user-visible
// result) and any file outside the root are never touched.

import Foundation
import GRDB

/// The single canonical root for spooled job output. The spool writer
/// (`BackgroundJobOutputSpool` in FloeExecution) and retention share this
/// resolver, so a path can never be considered "inside the root" on one side
/// and outside it on the other.
// Android mirror: the accepted Core root binds the shared spool resolver.
// Both the writer and retention use this ONE explicit directory; no global
// Application Support fallback or first database/project selection.
private final class AndroidJobSpoolBinding: @unchecked Sendable {
    let lock = NSLock()
    var epoch: UInt64 = 0
    var root: URL?
}
public enum BackgroundJobOutputSpoolRoot {
    private static let state = AndroidJobSpoolBinding()

    public static func bind(root: URL, epoch: UInt64) -> Bool {
        guard epoch > 0, root.isFileURL, root.path != "/" else { return false }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        state.lock.lock(); defer { state.lock.unlock() }
        if state.epoch != 0 { return state.epoch == epoch && state.root == canonical }
        state.epoch = epoch; state.root = canonical
        return true
    }
    public static func url() -> URL? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.root
    }
    /// Called only after the exact native root's real store close/drain.
    public static func unbind(epoch: UInt64) {
        state.lock.lock(); defer { state.lock.unlock() }
        guard state.epoch == epoch else { return }
        state.root = nil; state.epoch = 0
    }
}

enum RunLifecycleRetention {
    /// Removes the lifecycle rows owned by one conversation and returns the
    /// spool artifact paths that should be removed AFTER the transaction
    /// commits. Called inside the conversation-delete writer.
    static func deleteOwnedRecords(db: Database, conversationID: UUID) throws -> [String] {
        let id = conversationID.uuidString
        // Child transcripts first (entries reference the child header), then
        // the child headers, then the parent/child relation rows.
        try db.execute(sql: """
            DELETE FROM child_run_entries WHERE child_run_id IN (
                SELECT id FROM child_runs WHERE conversation_id = ?
            )
            """, arguments: [id])
        try db.execute(sql: "DELETE FROM child_runs WHERE conversation_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM run_relations WHERE conversation_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM run_dependencies WHERE conversation_id = ?", arguments: [id])
        // Jobs owned by this conversation: collect their spooled output
        // paths, then remove the rows. Other conversations' jobs (including
        // work in a shared Linux guest) are untouched.
        let spoolPaths = try String.fetchAll(db, sql: """
            SELECT output_path FROM background_jobs
            WHERE conversation_id = ? AND output_path IS NOT NULL
            """, arguments: [id])
        try db.execute(sql: "DELETE FROM background_jobs WHERE conversation_id = ?", arguments: [id])
        return spoolPaths
    }

    /// Removes only paths that resolve inside the canonical spool root and
    /// are named `<job-uuid>.txt`. Everything else (including a recorded
    /// `resultPath` or any user export) is left alone. Best effort: a failed
    /// file removal never fails the already-committed conversation delete.
    static func removeSpoolArtifacts(
        _ paths: [String],
        root: URL? = BackgroundJobOutputSpoolRoot.url()
    ) {
        guard let root, !paths.isEmpty else { return }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            guard parent == canonicalRoot,
                  url.pathExtension == "txt",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
