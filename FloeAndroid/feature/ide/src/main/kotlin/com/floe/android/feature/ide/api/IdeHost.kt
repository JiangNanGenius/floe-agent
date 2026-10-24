// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide.api

/**
 * The host authority implemented by Main's app-host adapter (B3 editor
 * facade) over the Swift FloeWorkspace service. This module NEVER talks to
 * disk, executors or runtimes directly; every effect crosses these calls and
 * every fact comes back through [IdeReceiver].
 *
 * Threading: [submitEdit]/[sendCommand] may be called from the UI thread and
 * must be non-blocking (enqueue into the existing bounded bridge); replies
 * arrive asynchronously through [IdeReceiver] on any thread.
 */
public interface IdeHost {
    /** Exact owning ordinary task; the IDE pane belongs to this task only. */
    public val taskId: String

    /** Workspace this binding is scoped to. */
    public val workspaceId: String

    /** Incremented whenever the owning task/workspace binding changes. */
    public val bindingGeneration: Long

    /** Attach the presentation receiver; returns the detach action. */
    public fun attach(receiver: IdeReceiver): () -> Unit

    /** Versioned edit transaction. Reply arrives via
     * [IdeReceiver.onCommandReply] keyed by [IdeEditTransaction.transactionId]. */
    public fun submitEdit(transaction: IdeEditTransaction)

    /** User command request. Reply arrives via [IdeReceiver.onCommandReply]. */
    public fun sendCommand(command: IdeCommandRequest)
}

/**
 * Push entry from the host. All callbacks must be safe to invoke from any
 * thread; the presenter fences them by owner generation, document lineage,
 * request/query generations and revisions before touching any projection.
 */
public interface IdeReceiver {
    /** Authoritative document snapshot (complete text or streamed body ref). */
    public fun onDocumentSnapshot(snapshot: IdeDocumentSnapshot)

    /** Authoritative tab strip state for the owner. */
    public fun onTabs(tabs: IdeTabsSnapshot)

    /** Reply matching a transactionId/requestId, with owner + document. */
    public fun onCommandReply(reply: IdeCommandReply)

    /** Completion answer for a request identity; stale revisions are rejected. */
    public fun onCompletion(completions: IdeCompletionSnapshot)

    /** Diagnostics answer; stale revisions are rejected. */
    public fun onDiagnostics(diagnostics: IdeDiagnosticSnapshot)

    /** Bounded content-fragment delivery for streamed snapshot bodies. */
    public fun onContentFragment(fragment: IdeContentFragment)
}
