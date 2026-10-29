// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.api

/**
 * Optional real bridge to files that already exist in a Floe task workspace.
 *
 * This is deliberately NOT a second file index and NOT a SAF URL picker:
 *
 *  * [scopes] returns the user-visible workspace roots the App already owns
 *    (the durable task workspaces). The presentation layer never guesses a
 *    project, a first workspace or a temporary directory.
 *  * [list] walks one directory through the App's existing workspace
 *    authority. Relative paths are validated by that authority (root
 *    containment, secret-file refusal and symlink escape checks stay there).
 *  * [open] returns a host-owned [NotesPickedFile] read handle. The Notes
 *    importer reads it in bounded chunks and copies the bytes into its own
 *    independent resource store; the workspace file is never modified and no
 *    workspace path or URI is persisted in Notes.
 *
 * Hosts must throw [NotesPortFailureException] for typed failures. A port must
 * never return a successful-looking empty file for an unavailable workspace.
 * An existing but empty workspace is [NotesWorkspacePage.exists] true with no
 * entries; a missing workspace row is [NotesWorkspacePage.exists] false.
 */
public enum class NotesWorkspaceScopeKind { TASK }

/**
 * One explicit workspace scope. [id] is the durable App task identity, never
 * a filesystem path. [title] is the user-facing task title.
 */
public data class NotesWorkspaceScope(
    public val id: String,
    public val title: String,
    public val isArchived: Boolean = false,
    public val kind: NotesWorkspaceScopeKind = NotesWorkspaceScopeKind.TASK,
)

/** One directory entry. [relativePath] is relative to the workspace root. */
public data class NotesWorkspaceEntry(
    public val name: String,
    public val relativePath: String,
    public val isDirectory: Boolean,
    public val byteCount: Long = 0L,
)

/**
 * One directory page. [exists] false means the selected task has no workspace
 * row yet (a real empty state, not a fabricated empty folder). A missing
 * directory inside an existing workspace is reported as a typed notFound
 * failure instead.
 */
public data class NotesWorkspacePage(
    public val entries: List<NotesWorkspaceEntry>,
    public val nextPageToken: String? = null,
    public val exists: Boolean = true,
)

/**
 * One page of user-visible workspace roots. [nextPageToken] is the REAL
 * `conversation.list` cursor, only present while `hasMore` is true; the UI
 * loads the next page through the same existing command, never a new index.
 */
public data class NotesWorkspaceScopePage(
    public val scopes: List<NotesWorkspaceScope>,
    public val nextPageToken: String? = null,
)

public interface NotesWorkspaceImportPort : AutoCloseable {
    /** User-visible workspace roots, current-first. [pageToken] is opaque. */
    public suspend fun scopes(pageToken: String? = null): NotesWorkspaceScopePage

    /**
     * One directory page below [scope]. [relativePath] "." is the workspace
     * root. [pageToken] is opaque and only ever comes from a previous page.
     */
    public suspend fun list(
        scope: NotesWorkspaceScope,
        relativePath: String = ".",
        pageToken: String? = null,
    ): NotesWorkspacePage

    /**
     * Open one regular workspace file as a bounded read handle. The caller
     * MUST close the returned file on every path, including cancellation and
     * failure. The host revalidates the original task/workspace/root epoch
     * around reads; a retired root answers typed cancellation and returns no
     * bytes.
     */
    public suspend fun open(
        scope: NotesWorkspaceScope,
        relativePath: String,
    ): NotesPickedFile

    /**
     * Existing Notes root-stop gate. Set `RootStopping` before the native root
     * epoch changes, close every open read handle, and return true only when
     * all admitted workspace work has drained. A refused gate is re-armed by
     * [abortRootStop]; a newer root is admitted by [resumeAfterRootChange].
     * Defaults keep a test/simple port source-compatible.
     */
    public suspend fun prepareForRootStop(epoch: Long): Boolean = true
    public suspend fun abortRootStop(epoch: Long): Unit = Unit
    public suspend fun resumeAfterRootChange(epoch: Long): Unit = Unit
    /** Final owner teardown; close any read handle still owned by this port. */
    override fun close(): Unit = Unit
}
