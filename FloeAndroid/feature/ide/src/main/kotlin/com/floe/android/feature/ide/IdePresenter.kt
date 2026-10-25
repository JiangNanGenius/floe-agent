// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import com.floe.android.feature.ide.api.IdeCloseDecision
import com.floe.android.feature.ide.api.IdeCommandPayload
import com.floe.android.feature.ide.api.IdeCommandReply
import com.floe.android.feature.ide.api.IdeCommandRequest
import com.floe.android.feature.ide.api.IdeCompletionItem
import com.floe.android.feature.ide.api.IdeCompletionSnapshot
import com.floe.android.feature.ide.api.IdeConflictChoice
import com.floe.android.feature.ide.api.IdeConflictPayload
import com.floe.android.feature.ide.api.IdeContentFragment
import com.floe.android.feature.ide.api.IdeContentRef
import com.floe.android.feature.ide.api.IdeDiagnostic
import com.floe.android.feature.ide.api.IdeDiagnosticSnapshot
import com.floe.android.feature.ide.api.IdeDocumentKey
import com.floe.android.feature.ide.api.IdeDocumentSnapshot
import com.floe.android.feature.ide.api.IdeEditOrigin
import com.floe.android.feature.ide.api.IdeEditTransaction
import com.floe.android.feature.ide.api.IdeErrorCode
import com.floe.android.feature.ide.api.IdeFileRow
import com.floe.android.feature.ide.api.IdeFindResult
import com.floe.android.feature.ide.api.IdeHost
import com.floe.android.feature.ide.api.IdeOpenReason
import com.floe.android.feature.ide.api.IdeOwnerScope
import com.floe.android.feature.ide.api.IdeRecoveryProjection
import com.floe.android.feature.ide.api.IdeRecoverySource
import com.floe.android.feature.ide.api.IdeReceiver
import com.floe.android.feature.ide.api.IdeReplaceScope
import com.floe.android.feature.ide.api.IdeReplyOutcome
import com.floe.android.feature.ide.api.IdeSaveReason
import com.floe.android.feature.ide.api.IdeSearchHit
import com.floe.android.feature.ide.api.IdeTabsSnapshot
import com.floe.android.feature.ide.api.IdeTextSelection
import com.floe.android.feature.ide.api.IdeTreeChildrenEvent
import com.floe.android.feature.ide.api.IdeUtf16Range
import com.floe.android.feature.ide.api.NativeRevision
import com.floe.android.feature.ide.internal.IdeDiffModel
import com.floe.android.feature.ide.internal.IdeFileTreeModel
import com.floe.android.feature.ide.internal.IdeTextMath
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID

/** Minimal projection-sync instruction produced for the Sora editor adapter. */
public sealed class IdeSyncPlan {
    public data object Keep : IdeSyncPlan()
    public data class ReplaceRange(public val startUtf16: Int, public val endUtf16: Int, public val replacement: String) : IdeSyncPlan()
    public data class ReplaceFull(public val text: String) : IdeSyncPlan()
}

/**
 * Pure-JVM presentation state machine. The native side (Swift FloeWorkspace)
 * is the only document/revision/undo/draft truth; this class gates versioned
 * transactions, fences late callbacks by owner generation + request/query
 * generations + revision lineage, streams bounded content fragments, and
 * never assumes a rejected or stale write succeeded. Compose renders [state];
 * the presenter performs no disk, executor or timer work.
 */
public class IdePresenter(
    private val host: IdeHost,
) : IdeReceiver {

    private class Doc(val key: IdeDocumentKey) {
        var snapshot: IdeDocumentSnapshot? = null
        val mirror: StringBuilder = StringBuilder()
        var mirrorReady: Boolean = false
        val pending: LinkedHashMap<String, IdeEditTransaction> = LinkedHashMap()
        // Complete projection after the one dispatched edit; unsent ranges
        // are based on this body, not the last native snapshot's old text.
        var headProjection: String? = null
        val deferredCommands = ArrayDeque<IdeCommandRequest>()
        var pendingAdoption: IdeDocumentSnapshot? = null
        // Whether the deferred adoption snapshot carries a caret-authoritative
        // native selection (see [adoptLocked]); a stale-flush echo does not.
        var pendingAdoptionAuthoritative = true
        var composing: Boolean = false
        var assembly: Assembly? = null
        var rejectedText: String? = null
        var recoveryId: String? = null
        var rejectedRecoveryId: String? = null
        // A second failed branch must not overwrite the first. Once an
        // older branch exists, input is fenced until explicit recovery.
        val olderRejected: LinkedHashMap<String, String> = LinkedHashMap()
        var completionRequestId: String? = null
        var completion: IdeCompletionSnapshot? = null
        var lastSentSelection: IdeTextSelection? = null
        // Ordering stamps for selection ownership: the latest local caret
        // report wins over older native selection echoes unless a
        // caret-authoritative adoption happened after it (see
        // [restoreSelectionFor]).
        var lastReportStamp = 0L
        var lastCaretAdoptStamp = 0L
        var lastVisibleLine: Int = -1
        var lastSyncWasFull: Boolean = true
        var diagnostics: List<IdeDiagnostic> = emptyList()
    }

    private class Assembly(
        val ref: IdeContentRef,
        val buffer: StringBuilder = StringBuilder(),
        var inFlight: Boolean = false,
    )

    private enum class CmdKind { SAVE, UNDO, REDO, FIND, REPLACE_CURRENT, REPLACE_ALL, DIFF, RUN, PREVIEW, CLOSE, ACTIVATE, OPEN, RESOLVE_CONFLICT, SEARCH, TREE, SELECTION, COMPLETION }

    private val lock = Any()
    private var released = false
    private var inputAdmissionOpen = true
    private var attached = false

    private val docs = LinkedHashMap<String, Doc>()
    private var tabsSnapshot: IdeTabsSnapshot? = null
    private var activeDocumentId: String? = null

    private var rootChildren: List<IdeFileRow>? = null
    private val childrenByPath = HashMap<String, List<IdeFileRow>>()
    private val expandedPaths = LinkedHashSet<String>()
    private val loadingPaths = LinkedHashSet<String>()
    private var rootLoading = false
    private var treeError: String? = null

    private var searchQuery = ""
    private var searchGenRequested = 0L
    private var searchGenApplied = -1L
    private var searchInProgress = false
    private var searchHits: List<IdeSearchHit> = emptyList()
    private var searchError: String? = null

    private var findOpen = false
    private var findQuery = ""
    private var findReplacement = ""
    private var findCaseSensitive = false
    private var findWholeWord = false
    private var findResult: IdeFindResult? = null
    private var findIndex = -1
    private var findInFlight = false
    private var findError: String? = null
    private var findStaleRetried = false

    private var diffState: IdeDiffState? = null
    private var conflictState: IdeConflictPayload? = null
    private var saveInFlight = false
    private var syncErrorMessage: String? = null
    private var closeRequestState: IdeCloseRequest? = null
    private var bottomPaneOpen = false
    private var caretLine = 0
    private var caretColumn = 0
    private var selectionLength = 0
    private var editorSelectionRequest: IdeUtf16Range? = null
    private var editorSelectionVersion = 0
    private var editorResetVersion = 0
    private var diagnosticsVersion = 0
    private var completionVersion = 0
    private var generationCounter = 0L
    // Single monotonic source ordering local selection reports against
    // caret-authoritative native adoptions (never exposed; ordering only).
    private var selectionStamp = 0L
    private var detachReceiver: (() -> Unit)? = null

    private val commandKinds = HashMap<String, CmdKind>()
    private val commandDocs = HashMap<String, String>()
    // The exact conflict captured when the user accepted a resolution. A
    // resolve reply may clear or adopt only while its captured conflict is
    // still the current one: a newer SAVE conflict on the SAME document, a
    // re-click or an explicit dismissal invalidates the old intent
    // (device-proven 2026-10-25 CAS2: the same docID alone is not a
    // conflict identity).
    private val conflictResolutions = HashMap<String, IdeConflictPayload>()

    private val _state: MutableStateFlow<IdeViewState>
    public val state: StateFlow<IdeViewState>

    init {
        _state = MutableStateFlow(buildState())
        state = _state
    }

    // ------------------------------------------------------------------ host

    /** Attach as the host receiver and load the workspace root. */
    public fun start() {
        synchronized(lock) {
            if (released || attached) return
            attached = true
            _state.value = buildState()
        }
        val detach = host.attach(this)
        synchronized(lock) { if (released) detach() else detachReceiver = detach }
        sendTree(null)
    }

    /** All documents, including background tabs, participate in release
     * admission; an active-tab-only projection is insufficient. */
    public fun hasUnsettledEdits(): Boolean = synchronized(lock) {
        docs.values.any { it.pending.isNotEmpty() || it.rejectedText != null || it.olderRejected.isNotEmpty() || it.pendingAdoption != null || it.composing }
    }

    /** Complete unconfirmed projections, including background documents.
     * IDs remain stable until typing changes, allowing lost-response retry. */
    public fun recoveryProjections(): List<IdeRecoveryProjection> = synchronized(lock) {
        buildList {
            for (doc in docs.values) {
                val snapshot = doc.snapshot ?: continue
                doc.olderRejected.forEach { (id, text) ->
                    add(IdeRecoveryProjection(id, doc.key, snapshot.relativePath, snapshot.revision, text, false, IdeRecoverySource.REJECTED))
                }
                doc.rejectedText?.let { text ->
                    val id = doc.rejectedRecoveryId ?: UUID.randomUUID().toString().also { doc.rejectedRecoveryId = it }
                    add(IdeRecoveryProjection(id, doc.key, snapshot.relativePath, snapshot.revision, text, false, IdeRecoverySource.REJECTED))
                }
                if ((doc.pending.isNotEmpty() || doc.pendingAdoption != null || doc.composing) && doc.mirrorReady) {
                    val id = doc.recoveryId ?: UUID.randomUUID().toString().also { doc.recoveryId = it }
                    add(IdeRecoveryProjection(id, doc.key, snapshot.relativePath, snapshot.revision,
                        doc.mirror.toString(), doc.composing, IdeRecoverySource.PENDING))
                }
            }
        }
    }

    /** Caller must have drained its actual adapter and verified the native
     * recovery's exact byte count + digest. A changed projection refuses. */
    public fun acknowledgeRecoveredProjection(projection: IdeRecoveryProjection): Boolean =
        settleRecoveryProjection(projection, discard = false)

    /** Explicit user choice to discard only these unconfirmed edits. */
    public fun discardRecoveryProjection(projection: IdeRecoveryProjection): Boolean =
        settleRecoveryProjection(projection, discard = true)

    private fun settleRecoveryProjection(projection: IdeRecoveryProjection, discard: Boolean): Boolean = synchronized(lock) {
        val doc = docs[projection.key.documentId] ?: return@synchronized false
        if (doc.key != projection.key) return@synchronized false
        when (projection.source) {
            IdeRecoverySource.REJECTED -> {
                if (doc.olderRejected[projection.recoveryId] == projection.text) {
                    doc.olderRejected.remove(projection.recoveryId)
                } else {
                    if (doc.rejectedRecoveryId != projection.recoveryId || doc.rejectedText != projection.text) return@synchronized false
                    doc.rejectedText = null; doc.rejectedRecoveryId = null
                }
                if (doc.pending.isEmpty() && !doc.composing && doc.pendingAdoption == null) doc.snapshot?.let { adoptLocked(doc, it) }
            }
            IdeRecoverySource.PENDING -> {
                if (doc.recoveryId != projection.recoveryId || !doc.mirrorReady || doc.mirror.toString() != projection.text ||
                    (!discard && doc.composing)) return@synchronized false
                flushPendingLocked(doc)
                doc.recoveryId = null; doc.composing = false; doc.pendingAdoption = null
                doc.snapshot?.let { adoptLocked(doc, it) }
            }
        }
        editorResetVersion++
        _state.value = buildState()
        true
    }

    /** Owner shutdown fences new UI input while existing native ACKs and
     * complete content/recovery reads keep settling. No callback is detached. */
    public fun setInputAdmission(open: Boolean) = synchronized(lock) {
        inputAdmissionOpen = open
        editorResetVersion++
        _state.value = buildState()
    }

    /** Fence: drops every later host callback for this binding. */
    public fun release() {
        synchronized(lock) {
            released = true
            conflictResolutions.clear()
            detachReceiver?.invoke(); detachReceiver = null
        }
    }

    /** Only one native edit per document is in flight. Commands using its
     * ranges/body wait for the chain to settle instead of saving a prefix. */
    private fun dispatchCommand(command: IdeCommandRequest, maintenance: Boolean = false) {
        synchronized(lock) {
            if (released) return
            if (!inputAdmissionOpen && !maintenance) {
                val kind = commandKinds.remove(command.requestId)
                commandDocs.remove(command.requestId)
                conflictResolutions.remove(command.requestId)
                if (kind == CmdKind.SAVE) saveInFlight = false
                if (kind in setOf(CmdKind.FIND, CmdKind.REPLACE_CURRENT, CmdKind.REPLACE_ALL)) findInFlight = false
                _state.value = buildState()
                return
            }
            val id = command.documentKey?.documentId
                ?: (command as? IdeCommandRequest.CloseDocument)?.documentId
            val doc = id?.let { docs[it] }
            if (!maintenance && doc?.olderRejected?.isNotEmpty() == true && commandKinds[command.requestId] !in
                setOf(CmdKind.FIND, CmdKind.DIFF, CmdKind.SELECTION, CmdKind.COMPLETION, CmdKind.ACTIVATE)) {
                val kind = commandKinds.remove(command.requestId)
                commandDocs.remove(command.requestId)
                conflictResolutions.remove(command.requestId)
                if (kind == CmdKind.SAVE) saveInFlight = false
                _state.value = buildState()
                return
            }
            if (doc != null && doc.pending.isNotEmpty()) {
                val kind = commandKinds[command.requestId]
                if (kind in setOf(CmdKind.SELECTION, CmdKind.COMPLETION, CmdKind.SAVE, CmdKind.FIND, CmdKind.DIFF)) {
                    // These are latest-state requests, so a newer request
                    // supersedes the unsent one without changing user text.
                    val obsolete = doc.deferredCommands.filter { commandKinds[it.requestId] == kind }
                    for (previous in obsolete) {
                        doc.deferredCommands.remove(previous)
                        commandKinds.remove(previous.requestId)
                        commandDocs.remove(previous.requestId)
                        conflictResolutions.remove(previous.requestId)
                    }
                }
                if (doc.deferredCommands.size >= 64) {
                    val failure = IdeReplyOutcome.Failed(IdeErrorCode.HOST_UNAVAILABLE,
                        "Too many pending editor actions. Wait for edits to finish.")
                    onFailedLocked(IdeCommandReply(command.requestId, hostOwner(), doc.key, failure), failure)
                    syncErrorMessage = failure.message
                    _state.value = buildState()
                    return
                }
                doc.deferredCommands.addLast(command)
            } else host.sendCommand(command)
        }
    }

    private fun hostOwner(): IdeOwnerScope =
        IdeOwnerScope(host.taskId, host.workspaceId, host.bindingGeneration)

    private fun accept(owner: IdeOwnerScope): Boolean =
        !released && attached &&
            owner.taskId == host.taskId &&
            owner.workspaceId == host.workspaceId &&
            owner.bindingGeneration == host.bindingGeneration

    private fun accept(key: IdeDocumentKey): Boolean =
        !released && attached &&
            key.taskId == host.taskId &&
            key.workspaceId == host.workspaceId

    // ------------------------------------------------------------- IdeReceiver

    override fun onDocumentSnapshot(snapshot: IdeDocumentSnapshot) {
        synchronized(lock) {
            if (!accept(snapshot.key)) return
            val doc = docs.getOrPut(snapshot.key.documentId) { Doc(snapshot.key) }
            if (doc.pending.isNotEmpty()) {
                // An unchanged native baseline must not erase a projection
                // containing in-flight keystrokes. A new native lineage
                // invalidates their ranges and preserves the local tail.
                if (doc.snapshot?.revision == snapshot.revision &&
                    doc.snapshot?.generation == snapshot.generation) return
                // A background reload may publish a new lineage before the
                // in-flight edit answers. Keep the projection when its base
                // body is unchanged; only the actual head reply may retry it.
                // Retrying on a snapshot alone could duplicate an edit whose
                // native application is still in flight.
                if (snapshot.text != null && snapshot.text == doc.snapshot?.text) return
                flushPendingLocked(doc)
                saveRejectedTailLocked(doc, snapshot)
            }
            if (doc.composing && doc.key.documentId == activeDocumentId) {
                doc.pendingAdoption = snapshot
                doc.pendingAdoptionAuthoritative = true
            } else {
                adoptLocked(doc, snapshot)
                if (doc.key.documentId == activeDocumentId) editorResetVersion++
            }
            _state.value = buildState()
        }
    }

    override fun onTabs(tabs: IdeTabsSnapshot) {
        synchronized(lock) {
            if (!accept(tabs.owner)) return
            tabsSnapshot = tabs
            val newActive = tabs.activeDocumentId
            if (newActive != activeDocumentId) {
                activeDocumentId = newActive
                editorResetVersion++
                if (findOpen && findQuery.isNotEmpty()) {
                    findResult = null
                    findIndex = -1
                }
            }
            // Drop document states no longer in tabs (closed/evicted) so late
            // replies cannot pin them.
            val live = tabs.tabs.mapTo(HashSet(tabs.tabs.size)) { it.documentId }
            val stale = docs.keys.filterNot { it in live }
            stale.forEach { docs.remove(it) }
            _state.value = buildState()
        }
    }

    override fun onCommandReply(reply: IdeCommandReply) {
        synchronized(lock) {
            if (!accept(reply.owner)) return
            when (val outcome = reply.outcome) {
                is IdeReplyOutcome.Acknowledged -> onTxnAckLocked(reply, outcome)
                is IdeReplyOutcome.StaleRevision -> onTxnStaleLocked(reply, outcome)
                is IdeReplyOutcome.Executed -> onExecutedLocked(reply, outcome.payload)
                is IdeReplyOutcome.Failed -> onFailedLocked(reply, outcome)
            }
            _state.value = buildState()
        }
    }

    override fun onCompletion(completions: IdeCompletionSnapshot) {
        synchronized(lock) {
            if (!accept(completions.documentKey)) return
            val doc = docs[completions.documentKey.documentId] ?: return
            // Reject stale revision and non-current request identity.
            if (completions.revision != doc.snapshot?.revision) return
            if (completions.requestId != doc.completionRequestId) return
            doc.completion = completions
            // Fresh host (LSP) items arrived asynchronously AFTER Sora's own
            // insert-triggered completion pass: bump the version so the view
            // can re-run it and the late answer becomes visible.
            completionVersion++
            _state.value = buildState()
        }
    }

    override fun onDiagnostics(diagnostics: IdeDiagnosticSnapshot) {
        synchronized(lock) {
            if (!accept(diagnostics.documentKey)) return
            val doc = docs[diagnostics.documentKey.documentId] ?: return
            // Stale revisions for the same document are rejected outright.
            if (diagnostics.revision != doc.snapshot?.revision) return
            doc.diagnostics = diagnostics.items
            diagnosticsVersion++
            _state.value = buildState()
        }
    }

    override fun onContentFragment(fragment: IdeContentFragment) {
        synchronized(lock) {
            if (!accept(fragment.ref.documentKey)) return
            val doc = docs[fragment.ref.documentKey.documentId] ?: return
            val assembly = doc.assembly ?: return
            if (fragment.ref.handleId != assembly.ref.handleId || fragment.ref.revision != assembly.ref.revision) return
            if (fragment.startUtf16 != assembly.buffer.length) {
                // Out-of-order: re-request from the true next offset.
                assembly.inFlight = false
                requestFragmentLocked(doc, assembly)
                _state.value = buildState()
                return
            }
            assembly.buffer.append(fragment.text)
            assembly.inFlight = false
            val done = fragment.isLast || assembly.buffer.length.toLong() >= assembly.ref.totalUtf16
            if (done) {
                val assembled = doc.snapshot?.copy(text = assembly.buffer.toString(), contentRef = null)
                doc.assembly = null
                if (assembled != null) {
                    adoptLocked(doc, assembled)
                    if (doc.key.documentId == activeDocumentId) editorResetVersion++
                }
            } else {
                requestFragmentLocked(doc, assembly)
            }
            _state.value = buildState()
        }
    }

    // -------------------------------------------------------- tree + search

    private fun sendTree(parent: String?) {
        val request = newRequest("tree")
        val gen = nextGeneration()
        synchronized(lock) {
            if (released) return
            commandKinds[request] = CmdKind.TREE
            commandDocs[request] = parent ?: "" 
            if (parent == null) {
                rootLoading = true
                treeError = null
            } else {
                loadingPaths.add(parent)
            }
            _state.value = buildState()
        }
        dispatchCommand(IdeCommandRequest.ExpandTree(request, hostOwner(), parent, gen))
    }

    public fun loadTreeRoot() {
        sendTree(null)
    }

    /**
     * Full tree re-read after a REAL workspace CRUD (create/rename/move/copy/
     * delete, and the panel's Refresh control). Reloading only the root left
     * cached children of EXPANDED folders stale — a moved file stayed visible
     * under its old folder until a process restart (device evidence 2026-10-25:
     * g04-ops/copy.py → moved.py succeeded natively, the expanded folder still
     * listed copy.py even after Refresh). This re-reads the root AND every
     * currently expanded directory, keeping the expansion state; a directory
     * whose re-read fails converges honestly through the existing per-parent
     * error path (child cache + expansion dropped). The re-read is a bounded
     * host query per visible expanded path — never a full recursive walk.
     */
    public fun refreshTreeKeepingExpansion() {
        val expanded: List<String> = synchronized(lock) {
            if (released) return
            expandedPaths.toList()
        }
        sendTree(null)
        expanded.forEach { parent -> sendTree(parent) }
    }

    public fun toggleTreeExpansion(relativePath: String) {
        val collapse = synchronized(lock) {
            if (released) return
            if (relativePath in expandedPaths) {
                expandedPaths.remove(relativePath)
                true
            } else {
                expandedPaths.add(relativePath)
                childrenByPath.containsKey(relativePath) || relativePath in loadingPaths
            }
        }
        if (!collapse && !released) sendTree(relativePath)
        publish()
    }

    public fun setTreeSearchQuery(query: String) {
        val request: String?
        val gen: Long
        synchronized(lock) {
            if (released) return
            searchQuery = query
            if (query.isEmpty()) {
                searchHits = emptyList()
                searchInProgress = false
                searchError = null
                searchGenApplied = -1L
                request = null
                gen = 0L
            } else {
                searchInProgress = true
                searchError = null
                gen = nextGeneration()
                searchGenRequested = gen
                request = newRequest("search")
                commandKinds[request] = CmdKind.SEARCH
                _state.value = buildState()
            }
        }
        if (request != null) {
            dispatchCommand(IdeCommandRequest.RequestWorkspaceSearch(request, hostOwner(), query, gen))
        } else {
            publish()
        }
    }

    public fun openFile(relativePath: String, reason: IdeOpenReason = IdeOpenReason.TREE) {
        if (released) return
        val request = newRequest("open")
        synchronized(lock) {
            commandKinds[request] = CmdKind.OPEN
        }
        dispatchCommand(IdeCommandRequest.OpenFile(request, hostOwner(), relativePath, reason))
    }

    // ------------------------------------------------------------------ tabs

    public fun activateTab(documentId: String) {
        synchronized(lock) {
            if (released) return
            val changed = documentId != activeDocumentId
            activeDocumentId = documentId
            if (changed) {
                editorResetVersion++
                if (findOpen && findQuery.isNotEmpty()) {
                    findResult = null
                    findIndex = -1
                }
            }
            _state.value = buildState()
        }
        val request = newRequest("activate")
        synchronized(lock) {
            commandKinds[request] = CmdKind.ACTIVATE
            commandDocs[request] = documentId
        }
        // ReopenDocument is idempotent on the host: it guarantees the tab's
        // draft is materialized and pushes tabs/snapshot for this document.
        dispatchCommand(IdeCommandRequest.ReopenDocument(request, hostOwner(), documentId))
    }

    public fun requestCloseTab(documentId: String) {
        val sendNow = synchronized(lock) {
            if (released) return
            val tab = tabsSnapshot?.tabs?.firstOrNull { it.documentId == documentId }
            val dirty = tab?.dirty == true || docs[documentId]?.pending?.isNotEmpty() == true
            if (dirty) {
                closeRequestState = IdeCloseRequest(documentId, tab?.fileName ?: documentId, true)
                _state.value = buildState()
                false
            } else {
                closeRequestState = null
                _state.value = buildState()
                true
            }
        }
        if (sendNow && !released) {
            val request = newRequest("close")
            synchronized(lock) {
                commandKinds[request] = CmdKind.CLOSE
                commandDocs[request] = documentId
            }
            dispatchCommand(IdeCommandRequest.CloseDocument(request, hostOwner(), documentId, IdeCloseDecision.DISCARD))
        }
    }

    public fun resolveCloseRequest(decision: IdeCloseDecision) {
        val docId = synchronized(lock) {
            val id = closeRequestState?.documentId
            closeRequestState = null
            _state.value = buildState()
            id
        } ?: return
        val request = newRequest("close")
        synchronized(lock) {
            commandKinds[request] = CmdKind.CLOSE
            commandDocs[request] = docId
        }
        dispatchCommand(IdeCommandRequest.CloseDocument(request, hostOwner(), docId, decision))
    }

    public fun dismissCloseRequest() {
        synchronized(lock) {
            closeRequestState = null
            _state.value = buildState()
        }
    }

    // -------------------------------------------------------------- editor

    /**
     * Called by the Sora adapter for every real (non-programmatic, committed)
     * text change. Updates the RAM mirror and emits one versioned transaction.
     */
    public fun applyProjectionEdit(
        documentKey: IdeDocumentKey,
        range: IdeUtf16Range,
        replacement: String,
        origin: IdeEditOrigin,
    ) {
        val transaction = synchronized(lock) {
            if (released) return
            if (!inputAdmissionOpen) {
                editorResetVersion++
                _state.value = buildState()
                return
            }
            val doc = docs[documentKey.documentId] ?: return
            val snapshot = doc.snapshot ?: return
            if (!doc.mirrorReady) return
            if (doc.olderRejected.isNotEmpty()) {
                editorResetVersion++
                _state.value = buildState()
                return
            }
            val start = range.startUtf16.coerceIn(0, doc.mirror.length)
            val end = range.endUtf16.coerceIn(start, doc.mirror.length)
            if (IdeTextMath.insideSurrogatePair(doc.mirror, start) ||
                IdeTextMath.insideSurrogatePair(doc.mirror, end)
            ) {
                return
            }
            doc.recoveryId = null
            doc.mirror.replace(start, end, replacement)
            var txn = IdeEditTransaction(
                owner = hostOwner(),
                documentKey = doc.key,
                transactionId = newRequest("txn"),
                expectedRevision = snapshot.revision,
                generation = snapshot.generation,
                range = IdeUtf16Range(start, end),
                replacement = replacement,
                origin = origin,
            )
            if (doc.pending.isEmpty()) {
                doc.headProjection = doc.mirror.toString()
            } else if (doc.pending.size >= 32 ||
                doc.pending.values.drop(1).sumOf { it.replacement.length.toLong() } + replacement.length > 2 * 1024 * 1024L
            ) {
                // Preserve the dispatched head and every local keystroke,
                // compacting only UNSENT edits to a single full replacement
                // of the body's exact post-head length. No native revision,
                // undo entry or acknowledged edit is fabricated here.
                val afterHead = doc.headProjection ?: return
                val tailIDs = doc.pending.keys.drop(1)
                tailIDs.forEach { doc.pending.remove(it) }
                txn = txn.copy(range = IdeUtf16Range(0, afterHead.length),
                    replacement = doc.mirror.toString())
            }
            doc.pending[txn.transactionId] = txn
            // Host hit lists are stale against the changed projection.
            if (findOpen) findResult = null
            doc.completion = null
            caretLineColumnLocked(doc, doc.lastSentSelection?.startUtf16 ?: 0)
            _state.value = buildState()
            if (doc.pending.size == 1) txn else null
        }
        transaction?.let { host.submitEdit(it) }
    }

    /** The adapter reports the IME composition window; adoption defers. */
    public fun setComposing(documentId: String, composing: Boolean) {
        synchronized(lock) {
            val doc = docs[documentId] ?: return
            doc.composing = composing
            if (!composing) {
                doc.pendingAdoption?.let {
                    doc.pendingAdoption = null
                    adoptLocked(doc, it, authoritativeCaret = doc.pendingAdoptionAuthoritative)
                    doc.pendingAdoptionAuthoritative = true
                    if (doc.key.documentId == activeDocumentId) editorResetVersion++
                }
            }
            _state.value = buildState()
        }
    }

    /**
     * The adapter asks before writing into Sora; [composingNow] must be the
     * editor's live hasComposingText(). Never resets when already in sync.
     */
    public fun syncPlanFor(documentId: String?, editorText: String, composingNow: Boolean): IdeSyncPlan {
        synchronized(lock) {
            if (released || documentId == null) return IdeSyncPlan.Keep
            val doc = docs[documentId] ?: return IdeSyncPlan.Keep
            if (!doc.mirrorReady) return IdeSyncPlan.Keep
            if (composingNow) return IdeSyncPlan.Keep
            val desired = doc.mirror.toString()
            if (editorText == desired) {
                doc.lastSyncWasFull = false
                return IdeSyncPlan.Keep
            }
            if (doc.lastSyncWasFull || editorText.isEmpty()) {
                doc.lastSyncWasFull = true
                return IdeSyncPlan.ReplaceFull(desired)
            }
            val op = IdeTextMath.minimalReplacement(editorText, desired) ?: return IdeSyncPlan.Keep
            return IdeSyncPlan.ReplaceRange(op.startUtf16, op.endUtf16, op.replacement)
        }
    }

    /** Reports the caret/selection; sends host UpdateSelection on change. */
    public fun reportEditorSelection(
        documentId: String,
        selection: IdeTextSelection,
        firstVisibleLine: Int,
    ) {
        val key: IdeDocumentKey?
        val changed: Boolean
        synchronized(lock) {
            if (released) return
            val doc = docs[documentId] ?: return
            changed = doc.lastSentSelection != selection || doc.lastVisibleLine != firstVisibleLine
            doc.lastSentSelection = selection
            doc.lastReportStamp = ++selectionStamp
            doc.lastVisibleLine = firstVisibleLine
            key = doc.key
            caretLineColumnLocked(doc, selection.startUtf16)
            _state.value = buildState()
        }
        if (changed && key != null) {
            val request = newRequest("sel")
            synchronized(lock) { commandKinds[request] = CmdKind.SELECTION }
            dispatchCommand(IdeCommandRequest.UpdateSelection(request, hostOwner(), key, selection, firstVisibleLine))
            if (selection.startUtf16 == selection.endUtf16) {
                requestCompletionIfNeeded(key, selection)
            }
        }
    }

    private fun requestCompletionIfNeeded(key: IdeDocumentKey, selection: IdeTextSelection) {
        val doc: Doc = synchronized(lock) { docs[key.documentId] ?: return }
        if (doc.snapshot?.capabilities?.completion != true) return
        val id = newRequest("completion")
        synchronized(lock) {
            doc.completionRequestId = id
            doc.completion = null
            commandKinds[id] = CmdKind.COMPLETION
            commandDocs[id] = key.documentId
        }
        dispatchCommand(IdeCommandRequest.RequestCompletion(id, hostOwner(), key, selection))
    }

    /** Host completion items for the current caret only when fresh. */
    public fun hostCompletionItems(documentId: String, revision: NativeRevision, caretUtf16: Int): List<IdeCompletionItem> {
        val c = synchronized(lock) { docs[documentId]?.completion } ?: return emptyList()
        if (c.revision != revision) return emptyList()
        if (c.selection.startUtf16 != caretUtf16 || c.selection.endUtf16 != caretUtf16) return emptyList()
        return c.items
    }

    public fun snapshotFor(documentId: String): IdeDocumentSnapshot? =
        synchronized(lock) { docs[documentId]?.snapshot }

    /** Current mirror length only when the full projection is assembled. */
    public fun mirrorLengthFor(documentId: String): Int? =
        synchronized(lock) { docs[documentId]?.takeIf { it.mirrorReady }?.mirror?.length }

    /**
     * Selection to restore after a full editor resync. The snapshot's
     * selection is a native echo that can lag arbitrarily behind the
     * renderer's own last report (edit acknowledgements copy the snapshot
     * and preserve the old field; selection acknowledgements never refresh
     * it). Re-asserting that stale echo over the live caret re-selected a
     * rolled-back range whose next keystroke silently replaced whole
     * adopted bodies, and resurfaced as a stale "N selected" header on
     * every view reconstruction. The latest local report therefore wins
     * unless a caret-authoritative native adoption (open/reopen/undo/
     * replace/resolve/external push) happened AFTER it. Result is clamped
     * to the current projection; null means "leave the caret alone".
     */
    public fun restoreSelectionFor(documentId: String): IdeTextSelection? = synchronized(lock) {
        if (released || !attached || documentId != activeDocumentId) return@synchronized null
        val doc = docs[documentId] ?: return@synchronized null
        val snapshot = doc.snapshot ?: return@synchronized null
        val limit = when {
            doc.mirrorReady -> doc.mirror.length
            snapshot.text != null -> snapshot.text.length
            else -> return@synchronized null
        }
        val local = doc.lastSentSelection?.takeIf { doc.lastReportStamp > doc.lastCaretAdoptStamp }
        val chosen = local ?: snapshot.selection
            ?: snapshot.caretUtf16?.let { IdeTextSelection(it, it) }
            ?: return@synchronized null
        val start = chosen.startUtf16.coerceIn(0, limit)
        val end = chosen.endUtf16.coerceIn(start, limit)
        IdeTextSelection(start, end)
    }

    public fun activeDocumentKey(): IdeDocumentKey? = synchronized(lock) { docs[activeDocumentId]?.key }

    // ----------------------------------------------------------- commands

    public fun requestSave(reason: IdeSaveReason = IdeSaveReason.USER) {
        val key = activeKey() ?: return
        val request = newRequest("save")
        synchronized(lock) {
            commandKinds[request] = CmdKind.SAVE
            commandDocs[request] = key.documentId
            saveInFlight = true
            syncErrorMessage = null
            _state.value = buildState()
        }
        dispatchCommand(IdeCommandRequest.Save(request, hostOwner(), key, reason))
    }

    public fun requestUndo() {
        val key = activeKey() ?: return
        if (snapshotFor(key.documentId)?.capabilities?.undo != true) return
        val request = newRequest("undo")
        synchronized(lock) {
            commandKinds[request] = CmdKind.UNDO
            commandDocs[request] = key.documentId
        }
        dispatchCommand(IdeCommandRequest.Undo(request, hostOwner(), key))
    }

    public fun requestRedo() {
        val key = activeKey() ?: return
        if (snapshotFor(key.documentId)?.capabilities?.redo != true) return
        val request = newRequest("redo")
        synchronized(lock) {
            commandKinds[request] = CmdKind.REDO
            commandDocs[request] = key.documentId
        }
        dispatchCommand(IdeCommandRequest.Redo(request, hostOwner(), key))
    }

    public fun requestRun() {
        val key = activeKey() ?: return
        if (snapshotFor(key.documentId)?.capabilities?.run != true) return
        val request = newRequest("run")
        synchronized(lock) {
            commandKinds[request] = CmdKind.RUN
            commandDocs[request] = key.documentId
        }
        dispatchCommand(IdeCommandRequest.Run(request, hostOwner(), key))
    }

    public fun requestOpenPreview() {
        val key = activeKey() ?: return
        if (snapshotFor(key.documentId)?.capabilities?.openPreview != true) return
        val request = newRequest("preview")
        synchronized(lock) {
            commandKinds[request] = CmdKind.PREVIEW
            commandDocs[request] = key.documentId
        }
        dispatchCommand(IdeCommandRequest.OpenPreview(request, hostOwner(), key))
    }

    public fun requestLoadDiff() {
        val key = activeKey() ?: return
        if (snapshotFor(key.documentId)?.capabilities?.diff != true) return
        val request = newRequest("diff")
        synchronized(lock) {
            commandKinds[request] = CmdKind.DIFF
            commandDocs[request] = key.documentId
            _state.value = buildState()
        }
        dispatchCommand(IdeCommandRequest.LoadDiff(request, hostOwner(), key))
    }

    public fun dismissDiff() {
        synchronized(lock) {
            diffState = null
            _state.value = buildState()
        }
    }

    public fun toggleBottomPane(opened: Boolean? = null) {
        synchronized(lock) {
            bottomPaneOpen = opened ?: !bottomPaneOpen
            _state.value = buildState()
        }
    }

    // ---------------------------------------------------------- find bar

    public fun showFind(show: Boolean) {
        synchronized(lock) {
            findOpen = show
            if (!show) {
                findResult = null
                findIndex = -1
                findError = null
                findInFlight = false
                findStaleRetried = false
            }
            _state.value = buildState()
        }
        if (show && findQuery.isNotEmpty()) requestFindLocked(backwards = false)
    }

    public fun updateFindQuery(query: String) {
        synchronized(lock) {
            findQuery = query
            findResult = null
            findIndex = -1
            findError = null
            findStaleRetried = false
            _state.value = buildState()
        }
        if (query.isNotEmpty()) requestFindLocked(backwards = false)
    }

    public fun updateFindReplacement(text: String) {
        synchronized(lock) {
            findReplacement = text
            _state.value = buildState()
        }
    }

    public fun setFindCaseSensitive(value: Boolean) {
        synchronized(lock) {
            findCaseSensitive = value
            findResult = null
            findIndex = -1
            findStaleRetried = false
            _state.value = buildState()
        }
        if (findQuery.isNotEmpty()) requestFindLocked(backwards = false)
    }

    public fun setFindWholeWord(value: Boolean) {
        synchronized(lock) {
            findWholeWord = value
            findResult = null
            findIndex = -1
            findStaleRetried = false
            _state.value = buildState()
        }
        if (findQuery.isNotEmpty()) requestFindLocked(backwards = false)
    }

    public fun findNext() = stepFindLocked(delta = 1)
    public fun findPrevious() = stepFindLocked(delta = -1)

    private fun stepFindLocked(delta: Int) {
        synchronized(lock) {
            val result = findResult
            if (result == null || result.hits.isEmpty()) {
                if (findQuery.isNotEmpty() && !findInFlight) {
                    requestFindLocked(backwards = delta < 0)
                }
                return
            }
            findIndex = if (delta > 0) {
                (findIndex + 1) % result.hits.size
            } else {
                (findIndex - 1 + result.hits.size) % result.hits.size
            }
            val hit = result.hits[findIndex]
            editorSelectionRequest = hit
            editorSelectionVersion++
            _state.value = buildState()
        }
    }

    private fun requestFindLocked(backwards: Boolean) {
        val doc = docs[activeDocumentId] ?: return
        val snapshot = doc.snapshot ?: return
        if (findQuery.isEmpty()) return
        findInFlight = true
        findError = null
        val from = doc.lastSentSelection?.endUtf16?.coerceIn(0, doc.mirror.length)
        val request = IdeCommandRequest.Find(
            newRequest("find"), hostOwner(), doc.key,
            findQuery, findCaseSensitive, findWholeWord, backwards, from,
        )
        synchronized(lock) {
            commandKinds[request.requestId] = CmdKind.FIND
            commandDocs[request.requestId] = doc.key.documentId
            _state.value = buildState()
        }
        dispatchCommand(request)
    }

    public fun replaceCurrent() {
        val request = synchronized(lock) {
            val doc = docs[activeDocumentId] ?: return
            val snapshot = doc.snapshot ?: return
            val result = findResult ?: return
            if (findIndex < 0 || findIndex >= result.hits.size) return
            val r = IdeCommandRequest.Replace(
                newRequest("replace"), hostOwner(), doc.key,
                findQuery, findReplacement, findCaseSensitive, IdeReplaceScope.CURRENT, snapshot.revision, findWholeWord,
            )
            commandKinds[r.requestId] = CmdKind.REPLACE_CURRENT
            commandDocs[r.requestId] = doc.key.documentId
            r
        }
        dispatchCommand(request)
    }

    public fun replaceAll() {
        val request = synchronized(lock) {
            val doc = docs[activeDocumentId] ?: return
            val snapshot = doc.snapshot ?: return
            if (findQuery.isEmpty() || snapshot.capabilities.replace != true) return
            val r = IdeCommandRequest.Replace(
                newRequest("replace-all"), hostOwner(), doc.key,
                findQuery, findReplacement, findCaseSensitive, IdeReplaceScope.ALL, snapshot.revision, findWholeWord,
            )
            commandKinds[r.requestId] = CmdKind.REPLACE_ALL
            commandDocs[r.requestId] = doc.key.documentId
            r
        }
        dispatchCommand(request)
    }

    // ---------------------------------------------------------- conflict

    public fun resolveConflict(choice: IdeConflictChoice, text: String?) {
        val payload = synchronized(lock) { conflictState } ?: return
        val request = newRequest("conflict")
        synchronized(lock) {
            if (conflictState !== payload) return
            conflictResolutions.clear() // Only the latest user choice may adopt a reply.
            commandKinds[request] = CmdKind.RESOLVE_CONFLICT
            commandDocs[request] = payload.documentKey.documentId
            conflictResolutions[request] = payload
        }
        dispatchCommand(
            IdeCommandRequest.ResolveConflict(
                request, hostOwner(), payload.documentKey, text ?: payload.localDraftText, choice,
            ),
        )
    }

    public fun dismissConflict() {
        synchronized(lock) {
            conflictResolutions.clear()
            conflictState = null
            _state.value = buildState()
        }
    }

    public fun dismissSyncError() {
        synchronized(lock) {
            syncErrorMessage = null
            _state.value = buildState()
        }
    }

    /** Restore the complete rejected projection against the CURRENT native
     * body. Offsets saved before checkout/resync are never replayed against
     * a different base. Streamed native bodies must finish before restore. */
    public fun restoreRejectedEdits() {
        synchronized(lock) {
            if (released || !attached || !inputAdmissionOpen) return
            val doc = docs[activeDocumentId] ?: return
            if (!doc.mirrorReady || doc.composing || doc.pending.isNotEmpty() || doc.pendingAdoption != null) return
            val snapshot = doc.snapshot ?: return
            if (snapshot.readOnly) return
            val confirmed = snapshot.text ?: return
            if (doc.olderRejected.isNotEmpty()) return // Recover both branches before replaying either.
            val saved = doc.rejectedText ?: return
            val op = IdeTextMath.minimalReplacement(confirmed, saved)
            doc.mirror.setLength(0)
            doc.mirror.append(confirmed)
            doc.rejectedText = null
            editorResetVersion++
            if (op != null) {
                // Reentrant lock keeps selection/task changes from moving
                // restoration into a different active document.
                applyProjectionEdit(doc.key, IdeUtf16Range(op.startUtf16, op.endUtf16), op.replacement, IdeEditOrigin.USER_PASTE)
            }
            _state.value = buildState()
        }
    }

    // ---------------------------------------------------------- internals

    private fun activeKey(): IdeDocumentKey? = synchronized(lock) { docs[activeDocumentId]?.key }

    private fun publish() {
        synchronized(lock) { _state.value = buildState() }
    }

    private fun caretLineColumnLocked(doc: Doc, caret: Int) {
        val (line, column) = IdeTextMath.lineColumnAt(doc.mirror, caret.coerceIn(0, doc.mirror.length))
        caretLine = line
        caretColumn = column
        selectionLength = (doc.lastSentSelection?.let { it.endUtf16 - it.startUtf16 } ?: 0).coerceAtLeast(0)
    }

    private fun nextGeneration(): Long {
        generationCounter += 1
        return generationCounter
    }

    private fun newRequest(prefix: String): String = "$prefix-${UUID.randomUUID()}"

    private fun onTxnAckLocked(reply: IdeCommandReply, outcome: IdeReplyOutcome.Acknowledged) {
        val id = reply.requestId ?: return
        val doc = docs.values.firstOrNull { id in it.pending }
        if (doc == null) {
            // Selection and other non-edit ACKs have no transaction queue.
            // Retire their request bookkeeping instead of retaining every
            // caret movement for the lifetime of the editor.
            val kind = commandKinds.remove(id)
            commandDocs.remove(id)
            conflictResolutions.remove(id)
            if (kind == CmdKind.SAVE) saveInFlight = false
            return
        }
        val head = doc.pending.entries.firstOrNull() ?: return
        if (head.key != id) return // out-of-order ack: authoritative snapshot wins later
        val txn = head.value
        if (reply.documentKey != null && reply.documentKey != doc.key) return
        if (txn.generation != doc.snapshot?.generation) {
            doc.pending.remove(id)
            return
        }
        doc.pending.remove(id)
        val snapshot = doc.snapshot ?: return
        val acceptedText = doc.headProjection ?: snapshot.text
        doc.snapshot = snapshot.copy(revision = outcome.newRevision, text = acceptedText,
            capabilities = outcome.capabilities ?: snapshot.capabilities,
            contentRef = if (acceptedText == null) snapshot.contentRef else null,
            sizeBytes = acceptedText?.toByteArray(Charsets.UTF_8)?.size?.toLong() ?: snapshot.sizeBytes)
        val next = doc.pending.entries.firstOrNull()
        if (next != null) {
            // Its range was computed on the projection after the preceding
            // edit, but its native revision was unknown until this ACK.
            val chained = next.value.copy(expectedRevision = outcome.newRevision)
            doc.pending[next.key] = chained
            if (acceptedText != null) {
                doc.headProjection = acceptedText.replaceRange(chained.range.startUtf16,
                    chained.range.endUtf16, chained.replacement)
            }
            host.submitEdit(chained)
        } else {
            doc.headProjection = null
            while (doc.deferredCommands.isNotEmpty()) {
                val command = doc.deferredCommands.removeFirst()
                val current = if (command is IdeCommandRequest.Replace)
                    command.copy(expectedRevision = outcome.newRevision) else command
                host.sendCommand(current)
            }
        }
    }

    private fun onTxnStaleLocked(reply: IdeCommandReply, outcome: IdeReplyOutcome.StaleRevision) {
        val id = reply.requestId ?: return
        val replyKey = reply.documentKey ?: return
        val doc = docs[replyKey.documentId] ?: return
        if (replyKey != doc.key || outcome.current.key != doc.key) return
        if (outcome.current.generation < (doc.snapshot?.generation ?: return)) return
        val head = doc.pending.entries.firstOrNull()
        if (head?.key == id) {
            // A stale answer can retry only the exact current edit attempt.
            // Old attempts, foreign snapshots and replies from a superseded
            // document generation never acquire a new edit owner.
            val txn = head.value
            if (txn.owner != reply.owner || txn.documentKey != doc.key ||
                txn.generation != doc.snapshot?.generation) return
            if (rebaseIdenticalBodyLocked(doc, outcome.current)) return
        } else {
            // A command already in flight may answer while the user starts
            // typing. Settle that command's bookkeeping, but never use its
            // stale reply as permission to resubmit an unrelated edit head.
            val kind = commandKinds[id] ?: return
            if (commandDocs[id] != doc.key.documentId) return
            commandKinds.remove(id)
            commandDocs.remove(id)
            conflictResolutions.remove(id)
            if (kind == CmdKind.SAVE) saveInFlight = false
            if (kind in setOf(CmdKind.FIND, CmdKind.REPLACE_CURRENT, CmdKind.REPLACE_ALL)) findInFlight = false
            if (head != null && outcome.current.text != null &&
                outcome.current.text == doc.snapshot?.text) return
        }
        flushPendingLocked(doc)
        saveRejectedTailLocked(doc, outcome.current)
        if (doc.composing && doc.key.documentId == activeDocumentId) {
            doc.pendingAdoption = outcome.current
            doc.pendingAdoptionAuthoritative = false
        } else {
            adoptLocked(doc, outcome.current, authoritativeCaret = false)
            if (doc.key.documentId == activeDocumentId) editorResetVersion++
        }
    }

    /**
     * A stale reply can carry a native body BYTE-IDENTICAL to the base the
     * in-flight chain was built on: the opaque revision/generation lineage
     * moved (header-only resync, out-of-band revision mint, reload-minted
     * generation) while the document content did not. Nothing diverged, so
     * rolling back live keystrokes and rewinding the editor would destroy
     * real user input for a phantom conflict. Re-stamp the user's own
     * unacknowledged edits onto the fresh lineage and resubmit the head
     * instead. Native still CAS-gates every application and a genuinely
     * changed (or still-streamed, incomparable) body keeps the full
     * flush/reject/recoverable-tail path. No acknowledgement is fabricated
     * here: the same user edit is submitted as a new request attempt and
     * must earn a real Acknowledged reply on the new lineage.
     */
    private fun rebaseIdenticalBodyLocked(doc: Doc, current: IdeDocumentSnapshot): Boolean {
        if (doc.pending.isEmpty() || !doc.mirrorReady || current.readOnly) return false
        val base = doc.snapshot?.text ?: return false
        val fresh = current.text ?: return false
        if (fresh != base) return false
        val head = doc.pending.values.first()
        if (head.range.startUtf16 < 0 || head.range.endUtf16 > fresh.length) return false
        if (current.revision == head.expectedRevision && current.generation == head.generation) return false
        // A rejected request was not acknowledged. Give its retry a fresh
        // attempt ID so a duplicated old stale/ack cannot settle this attempt.
        val reHead = head.copy(transactionId = newRequest("rebase"),
            generation = current.generation, expectedRevision = current.revision)
        val restamped = LinkedHashMap<String, IdeEditTransaction>(doc.pending.size)
        for ((index, entry) in doc.pending.entries.withIndex()) {
            val txn = if (index == 0) reHead else entry.value.copy(generation = current.generation)
            restamped[txn.transactionId] = txn
        }
        doc.snapshot = current
        doc.pending.clear()
        doc.pending.putAll(restamped)
        // Restore the head invariant: the complete projection after the one
        // dispatched edit, computed against the byte-identical fresh base.
        doc.headProjection = fresh.replaceRange(
            reHead.range.startUtf16, reHead.range.endUtf16, reHead.replacement)
        host.submitEdit(reHead)
        return true
    }

    private fun onFailedLocked(reply: IdeCommandReply, outcome: IdeReplyOutcome.Failed) {
        val id = reply.requestId ?: return
        val kind = commandKinds.remove(id)
        val docId = commandDocs.remove(id)
        // Retire only THIS request's resolution record: a late failed reply
        // never clears the current conflict or a newer intent.
        conflictResolutions.remove(id)
        val doc = reply.documentKey?.let { docs[it.documentId] } ?: docId?.let { docs[it] }
        if (id in docs.values.flatMap { it.pending.keys }) {
            // Rejected transaction: every later queued range was computed on
            // top of it and can no longer align against the native draft.
            val owner = docs.values.firstOrNull { id in it.pending } ?: return
            flushPendingLocked(owner)
            saveRejectedTailLocked(owner, owner.snapshot)
            syncErrorMessage = failureText(outcome.code, outcome.message)
            val snapshot = owner.snapshot
            if (snapshot != null && !released) {
                val request = newRequest("resync")
                synchronized(lock) { commandKinds[request] = CmdKind.OPEN }
                dispatchCommand(IdeCommandRequest.OpenFile(request, hostOwner(), snapshot.relativePath, IdeOpenReason.TAB_RESTORE), maintenance = true)
            }
            return
        }
        when (kind) {
            CmdKind.SAVE -> {
                saveInFlight = false
                if (outcome.code == IdeErrorCode.CONFLICT && doc != null) {
                    // The host signals conflict with the authoritative
                    // snapshot; request the current state so both versions
                    // can be shown (the OpenFile reply carries remote text).
                    syncErrorMessage = failureText(outcome.code, outcome.message)
                    val snapshot = doc.snapshot
                    if (snapshot != null) {
                        val request = newRequest("resync-conflict")
                        commandKinds[request] = CmdKind.OPEN
                        dispatchCommand(IdeCommandRequest.OpenFile(request, hostOwner(), snapshot.relativePath, IdeOpenReason.TAB_RESTORE), maintenance = true)
                    }
                } else {
                    syncErrorMessage = failureText(outcome.code, outcome.message)
                }
            }
            CmdKind.FIND -> {
                findInFlight = false
                findError = failureText(outcome.code, outcome.message)
            }
            CmdKind.REPLACE_CURRENT, CmdKind.REPLACE_ALL -> {
                findInFlight = false
                syncErrorMessage = failureText(outcome.code, outcome.message)
            }
            CmdKind.RESOLVE_CONFLICT -> syncErrorMessage = failureText(outcome.code, outcome.message)
            CmdKind.TREE -> {
                val parent = docId
                if (parent.isNullOrEmpty()) {
                    rootLoading = false
                } else {
                    loadingPaths.remove(parent)
                }
                treeError = outcome.message
            }
            CmdKind.SEARCH -> {
                searchInProgress = false
                searchError = failureText(outcome.code, outcome.message)
            }
            CmdKind.OPEN -> {
                val failedDoc = docId?.let { docs[it] }
                if (failedDoc != null && failedDoc.pending.isEmpty()) {
                    docs.remove(failedDoc.key.documentId)
                }
                syncErrorMessage = failureText(outcome.code, outcome.message)
            }
            CmdKind.DIFF -> syncErrorMessage = failureText(outcome.code, outcome.message)
            CmdKind.RUN, CmdKind.PREVIEW, CmdKind.CLOSE, CmdKind.ACTIVATE, CmdKind.UNDO,
            CmdKind.REDO, CmdKind.SELECTION, CmdKind.COMPLETION,
            -> {
                // A refused RUN is a user-visible truth (the single Linux
                // slot can be honestly occupied by a language server or the
                // terminal): never a silent no-op (device-proven 2026-10-25).
                if (kind == CmdKind.UNDO || kind == CmdKind.REDO || kind == CmdKind.RUN) {
                    syncErrorMessage = failureText(outcome.code, outcome.message)
                }
            }
            null -> Unit
        }
    }

    private var lastSyncErrorCode: IdeErrorCode? = null

    /** Last sync failure code for the host-facing diagnostics surface. */
    public fun lastSyncErrorCode(): IdeErrorCode? = synchronized(lock) { lastSyncErrorCode }

    private fun failureText(code: IdeErrorCode, message: String): String {
        lastSyncErrorCode = code
        return message
    }

    private fun flushPendingLocked(doc: Doc) {
        doc.pending.clear()
        doc.headProjection = null
        // A failed chain cannot authorize a deferred save/run/close on only
        // its accepted prefix. The rejected tail remains explicitly restorable.
        for (command in doc.deferredCommands) {
            if (commandKinds.remove(command.requestId) == CmdKind.SAVE) saveInFlight = false
            commandDocs.remove(command.requestId)
            conflictResolutions.remove(command.requestId)
        }
        doc.deferredCommands.clear()
        findInFlight = false
    }

    private fun saveRejectedTailLocked(doc: Doc, authoritative: IdeDocumentSnapshot?) {
        if (!doc.mirrorReady) return // Never erase a retained tail with a partial streamed body.
        val desired = doc.mirror.toString()
        if (authoritative?.text == desired || doc.rejectedText == desired) return
        doc.rejectedText?.let { previous ->
            val id = doc.rejectedRecoveryId ?: UUID.randomUUID().toString()
            doc.olderRejected[id] = previous
        }
        doc.rejectedRecoveryId = null
        doc.rejectedText = desired
    }

    /**
     * Adopt native snapshot truth into the projection. [authoritativeCaret]
     * marks whether the snapshot's selection describes a caret the NATIVE
     * side moved on purpose (open/reopen/undo/replace/resolve/external
     * push). A stale-flush adoption's selection is only native's memory of
     * this renderer's own older report, so it must not outrank the latest
     * local caret (see [restoreSelectionFor]).
     */
    private fun adoptLocked(doc: Doc, snapshot: IdeDocumentSnapshot, authoritativeCaret: Boolean = true) {
        doc.snapshot = snapshot
        if (authoritativeCaret) doc.lastCaretAdoptStamp = ++selectionStamp
        if (snapshot.text != null) {
            doc.mirror.setLength(0)
            doc.mirror.append(snapshot.text)
            doc.mirrorReady = true
            doc.assembly = null
            doc.lastSyncWasFull = true
        } else if (snapshot.contentRef != null) {
            doc.assembly = Assembly(snapshot.contentRef)
            doc.mirrorReady = false
            requestFragmentLocked(doc, doc.assembly!!)
        }
        if (doc.key.documentId == activeDocumentId) {
            caretLineColumnLocked(doc, doc.lastSentSelection?.startUtf16 ?: 0)
        }
        if (findResult != null && findResult?.revision != snapshot.revision) {
            findResult = null
            findIndex = -1
        }
        doc.completion = null
    }

    private fun requestFragmentLocked(doc: Doc, assembly: Assembly) {
        if (assembly.inFlight) return
        if (released || !attached) return
        assembly.inFlight = true
        val start = assembly.buffer.length
        dispatchCommand(
            IdeCommandRequest.RequestContentFragment(
                newRequest("fragment"), hostOwner(), assembly.ref, start, assembly.ref.fragmentUtf16,
            ),
        )
    }

    private fun onExecutedLocked(reply: IdeCommandReply, payload: IdeCommandPayload) {
        val id = reply.requestId
        val kind = id?.let { commandKinds.remove(it) }
        val docId = id?.let { commandDocs.remove(it) }
        val doc = reply.documentKey?.documentId?.let { docs[it] } ?: docId?.let { docs[it] }
        when (payload.kind) {
            IdeCommandPayload.Kind.NONE -> Unit
            IdeCommandPayload.Kind.SAVE -> {
                val save = payload.save ?: return
                saveInFlight = false
                if (save.conflict != null) {
                    conflictResolutions.clear() // A new occurrence invalidates even an equal payload.
                    conflictState = save.conflict
                } else {
                    syncErrorMessage = null
                    doc?.let { it.snapshot = it.snapshot?.copy(revision = save.revision) }
                }
            }
            IdeCommandPayload.Kind.SNAPSHOT -> {
                val s = payload.snapshot ?: return
                if (!accept(s.key)) return
                if (kind == CmdKind.RESOLVE_CONFLICT) {
                    val resolution = id?.let { conflictResolutions.remove(it) }
                    if (resolution == null || conflictState != resolution) {
                        // A reply for an intent the UI already replaced (newer
                        // SAVE conflict on this document, re-click or explicit
                        // dismissal): it must neither dismiss the current
                        // modal nor adopt its stale body over the current
                        // draft. A native fork minted under a DIFFERENT
                        // document is real inventory regardless, so the
                        // bounded tree refresh stays valid — it touches no
                        // modal and no draft.
                        if (s.key.documentId != docId) refreshTreeKeepingExpansion()
                        return
                    }
                    // THIS resolve's own accepted snapshot: the request still
                    // describes the CURRENT conflict, so the modal it
                    // represented truly settled (native fork minted a new
                    // docID / USE_REMOTE re-opened a fresh document /
                    // KEEP_LOCAL re-adopted the reviewed draft). Failed and
                    // stale outcomes never reach this branch, and the
                    // captured-payload fence keeps a late same-document reply
                    // from clearing another conflict (device-proven
                    // 2026-10-25: a successful fork left the old modal up;
                    // the same docID alone left a NEW modal dismissable).
                    conflictState = null
                    if (s.key.documentId != docId) {
                        // Inventory changed (the fork's new copy exists):
                        // refresh the cached tree through the EXISTING
                        // bounded path so the new file appears without a
                        // manual refresh; sendTree keeps its own fences.
                        refreshTreeKeepingExpansion()
                    }
                }
                val target = docs.getOrPut(s.key.documentId) { Doc(s.key) }
                if (target.pending.isNotEmpty()) {
                    if (kind == CmdKind.OPEN && s.text != null && s.text == target.snapshot?.text) return
                    // An explicit native action (undo/replace/resolve) owns
                    // its result, while edits typed during that action remain
                    // recoverable rather than disappearing on adoption.
                    flushPendingLocked(target)
                    saveRejectedTailLocked(target, s)
                }
                if (target.composing && s.key.documentId == activeDocumentId) {
                    target.pendingAdoption = s
                    target.pendingAdoptionAuthoritative = true
                } else {
                    adoptLocked(target, s)
                    if (s.key.documentId == activeDocumentId) editorResetVersion++
                }
            }
            IdeCommandPayload.Kind.TREE_CHILDREN -> {
                val event = payload.treeChildren ?: return
                applyTreeLocked(event)
            }
            IdeCommandPayload.Kind.WORKSPACE_SEARCH -> {
                val result = payload.search ?: return
                if (!accept(result.owner)) return
                if (result.query != searchQuery) return
                if (result.queryGeneration < searchGenApplied || result.queryGeneration > searchGenRequested) return
                searchGenApplied = result.queryGeneration
                searchInProgress = false
                searchError = result.error
                searchHits = result.hits
            }
            IdeCommandPayload.Kind.FIND -> {
                val result = payload.find ?: return
                applyFindLocked(result)
            }
            IdeCommandPayload.Kind.DIFF -> {
                val d = payload.diff ?: return
                if (doc != null && d.revision != doc.snapshot?.revision) return
                val classified = IdeDiffModel.classify(d.unifiedDiff)
                diffState = IdeDiffState(
                    documentId = d.documentKey.documentId,
                    revision = d.revision,
                    lines = classified.lines,
                    additions = classified.additions,
                    removals = classified.removals,
                    error = d.error,
                )
            }
            IdeCommandPayload.Kind.DIAGNOSTICS -> {
                val d = payload.diagnostics ?: return
                val target = docs[d.documentKey.documentId] ?: return
                if (d.revision != target.snapshot?.revision) return
                target.diagnostics = d.items
                diagnosticsVersion++
            }
            IdeCommandPayload.Kind.REPLACE -> {
                val r = payload.replace ?: return
                val target = doc ?: return
                saveRejectedTailLocked(target, r.snapshot)
                adoptLocked(target, r.snapshot)
                if (target.key.documentId == activeDocumentId) editorResetVersion++
                findStaleRetried = false
                if (findOpen && findQuery.isNotEmpty()) requestFindLocked(backwards = false)
            }
            IdeCommandPayload.Kind.CLOSED -> {
                val closed = payload.closedDocumentId ?: return
                docs.remove(closed)
                if (closed == activeDocumentId) {
                    activeDocumentId = tabsSnapshot?.activeDocumentId
                    editorResetVersion++
                }
            }
            IdeCommandPayload.Kind.CONTENT_FRAGMENT -> {
                payload.fragment?.let { onContentFragment(it) }
            }
        }
        // Save success may also arrive as an ack-shaped Executed(NONE).
        if (kind == CmdKind.SAVE && payload.kind == IdeCommandPayload.Kind.NONE) {
            saveInFlight = false
            syncErrorMessage = null
        }
    }

    private fun applyTreeLocked(event: IdeTreeChildrenEvent) {
        if (!accept(event.owner)) return
        val parent = event.parentRelativePath
        if (parent == null) {
            if (event.requestGeneration < rootGenApplied) return
            rootGenApplied = event.requestGeneration
            rootLoading = false
            if (event.error != null) {
                treeError = event.error
            } else {
                treeError = null
                rootChildren = event.children
            }
        } else {
            val applied = appliedTreeGen[parent]
            if (applied != null && event.requestGeneration < applied) return
            appliedTreeGen[parent] = event.requestGeneration
            loadingPaths.remove(parent)
            if (event.error != null) {
                childrenByPath.remove(parent)
                expandedPaths.remove(parent)
            } else {
                childrenByPath[parent] = event.children
            }
        }
    }

    private var rootGenApplied = -1L
    private val appliedTreeGen = HashMap<String, Long>()

    private fun applyFindLocked(result: IdeFindResult) {
        val doc = docs[result.documentKey.documentId] ?: return
        findInFlight = false
        if (result.documentKey.documentId != activeDocumentId) return
        if (result.revision != doc.snapshot?.revision) {
            if (!findStaleRetried && findQuery == result.query) {
                findStaleRetried = true
                requestFindLocked(backwards = false)
            } else {
                findError = "stale"
                findResult = null
                findIndex = -1
            }
            return
        }
        findStaleRetried = false
        findError = result.error
        findResult = result
        findIndex = if (result.hits.isEmpty()) -1 else 0
        if (result.hits.isNotEmpty()) {
            editorSelectionRequest = result.hits[0]
            editorSelectionVersion++
        }
    }

    private fun buildState(): IdeViewState {
        val activeDoc = activeDocumentId?.let { docs[it] }
        val snapshot = activeDoc?.snapshot
        val tabDescriptors = tabsSnapshot?.tabs ?: emptyList()
        val tabs = tabDescriptors.map { desc ->
            IdeTabItem(
                descriptor = desc,
                active = desc.documentId == activeDocumentId,
                localPending = docs[desc.documentId]?.pending?.isNotEmpty() == true,
            )
        }
        val dirtyLocal = activeDoc != null &&
            (activeDoc.pending.isNotEmpty() ||
                tabDescriptors.firstOrNull { it.documentId == activeDocumentId }?.dirty == true)
        val treeRows = if (searchQuery.isEmpty()) {
            IdeFileTreeModel.flatten(rootChildren, childrenByPath, expandedPaths, loadingPaths)
        } else {
            emptyList()
        }
        val loading = activeDoc?.assembly != null || (activeDoc != null && !activeDoc.mirrorReady && activeDoc.snapshot?.text == null)
        return IdeViewState(
            bindingGeneration = host.bindingGeneration,
            attached = attached,
            inputAdmissionOpen = inputAdmissionOpen && activeDoc?.olderRejected?.isNotEmpty() != true,
            bootLoading = rootLoading,
            activeDocumentKey = activeDoc?.key,
            snapshot = snapshot,
            mirrorText = activeDoc?.mirror?.toString()?.takeIf { activeDoc.mirrorReady },
            documentLoading = loading,
            documentLoadingMessage = null,
            dirtyLocal = dirtyLocal,
            pendingTransactionCount = activeDoc?.pending?.size ?: 0,
            saveInFlight = saveInFlight,
            syncError = syncErrorMessage,
            hasRejectedEdits = activeDoc?.rejectedText != null || activeDoc?.olderRejected?.isNotEmpty() == true,
            conflict = conflictState,
            find = IdeFindBarState(
                open = findOpen,
                query = findQuery,
                replacement = findReplacement,
                caseSensitive = findCaseSensitive,
                wholeWord = findWholeWord,
                hitCount = findResult?.hits?.size,
                currentHitIndex = findIndex,
                inFlight = findInFlight,
                error = findError,
            ),
            diff = diffState,
            diagnostics = activeDoc?.diagnostics ?: emptyList(),
            diagnosticsVersion = diagnosticsVersion,
            completionVersion = completionVersion,
            tree = IdeTreeState(
                rows = treeRows,
                searchQuery = searchQuery,
                searchInProgress = searchInProgress,
                searchHits = searchHits,
                searchError = searchError,
                rootLoading = rootLoading,
                rootError = treeError,
            ),
            tabs = tabs,
            closeRequest = closeRequestState,
            bottomPaneOpen = bottomPaneOpen,
            caretLine = caretLine,
            caretColumn = caretColumn,
            selectionLengthUtf16 = selectionLength,
            editorSelectionRequestVersion = editorSelectionVersion,
            editorSelectionRequest = editorSelectionRequest,
            editorResetVersion = editorResetVersion,
        )
    }
}
