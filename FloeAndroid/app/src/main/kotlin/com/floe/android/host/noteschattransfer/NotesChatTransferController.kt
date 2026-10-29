// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.noteschattransfer

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NotesApplyRequest
import com.floe.android.feature.notes.NotesCreateDocument
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.presentation.NotesEditReceipt
import com.floe.android.feature.notes.ui.presentation.NotesIdSource
import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import com.floe.android.feature.notes.ui.presentation.NotesRecoveryStore
import com.floe.android.feature.notes.ui.presentation.planTextInsertion
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One settled-chat-message -> Notes transfer.
 *
 * This is an explicit user action ("Save to Notes" on a settled reply), never
 * a chat side effect and never an assistant write: it creates an INDEPENDENT
 * notebook document under its own stable id and appends the COMPLETE reply as
 * page-aware Markdown text elements in ONE native transaction (one revision,
 * one undo, one receipt). The chat row/history is never mutated and the
 * transfer never navigates.
 *
 * Durability/lifecycle contract:
 *  * admission is fenced by the exact conversation entry owner (conversation
 *    id + session epoch + a non-temporary session + the live native Root
 *    epoch). A temporary chat can NEVER reach this path, even through a forged
 *    UI callback;
 *  * before ANY native create/apply the exact edit plan + stable request id is
 *    committed to the App-owned durable [NotesRecoveryStore]. A root epoch
 *    change/owner stop therefore either drains the committed result or leaves
 *    a durable record that [resume] re-drives with the SAME receipt (the native
 *    store returns the already-committed document, never a duplicate);
 *  * a failed/uncertain save keeps the whole plan; retry reuses the same
 *    document id, plan and receipt, so a retry can never duplicate or truncate;
 *  * text is never written to preferences, logs or a second database, and is
 *    released from RAM as soon as the durable document owns it.
 *
 * The controller owns no UI and no foreground service/timer: state is a plain
 * [StateFlow] the App may render.
 */
internal class NotesChatTransferController(
    private val scope: CoroutineScope,
    private val targets: suspend () -> NotesChatTransferTargets?,
    private val currentRootEpoch: () -> Long?,
    private val clock: () -> Long = System::currentTimeMillis,
    private val documentIDSource: () -> String = { UUID.randomUUID().toString() },
    private val intentIDSource: () -> String = { UUID.randomUUID().toString() },
    /** Bounded admission: below the native 8 MiB staged-batch bound. */
    private val maxTextBytes: Int = MAX_TEXT_BYTES,
) {

    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>()
    private val statesFlow = MutableStateFlow<List<NotesChatTransferState>>(emptyList())
    private val latestFlow = MutableStateFlow<NotesChatTransferState>(NotesChatTransferState.Idle)
    private val resumeMutex = Mutex()

    @Volatile
    private var closed = false

    @Volatile
    private var stopping = false

    @Volatile
    private var recoveryStore: NotesRecoveryStore? = null

    val states: StateFlow<List<NotesChatTransferState>> = statesFlow.asStateFlow()

    /** Newest state change (Idle until the first real admission). */
    val latest: StateFlow<NotesChatTransferState> = latestFlow.asStateFlow()

    /* ------------------------------- admission ------------------------------ */

    fun admit(owner: NotesChatTransferOwner, text: String): NotesChatTransferAdmission {
        val bytes = text.encodeToByteArray()
        if (closed) return NotesChatTransferAdmission.REJECTED_DISPOSED
        if (owner.temporary) return NotesChatTransferAdmission.REJECTED_TEMPORARY
        if (owner.conversationID.isBlank() || owner.sessionEpoch < 0) {
            return NotesChatTransferAdmission.REJECTED_OWNER
        }
        if (text.isBlank()) return NotesChatTransferAdmission.REJECTED_EMPTY
        if (bytes.size > maxTextBytes) return NotesChatTransferAdmission.REJECTED_TOO_LARGE
        if (stopping) return NotesChatTransferAdmission.REJECTED_ROOT
        val epoch = currentRootEpoch() ?: return NotesChatTransferAdmission.REJECTED_ROOT
        if (epoch != owner.rootEpoch) return NotesChatTransferAdmission.REJECTED_ROOT

        val key = messageKey(owner.conversationID, text)
        synchronized(lock) {
            val existing = entries[key]
            if (existing != null) {
                when (val state = existing.state) {
                    is NotesChatTransferState.Saving -> return NotesChatTransferAdmission.ALREADY_PENDING
                    is NotesChatTransferState.Saved -> return NotesChatTransferAdmission.ALREADY_SAVED
                    is NotesChatTransferState.Failed -> {
                        if (!state.retryable) return NotesChatTransferAdmission.REJECTED_UNAVAILABLE
                        launchLocked(existing)
                        return NotesChatTransferAdmission.STARTED
                    }
                    NotesChatTransferState.Idle -> Unit
                }
            }
            if (entries.size >= MAX_ENTRIES) pruneLocked()
            val intent = intentIDSource()
            val entry = Entry(
                transferID = intent,
                messageKey = key,
                owner = owner,
                documentID = documentIDSource(),
                title = deriveTitle(text),
            )
            entry.text = text
            entries[key] = entry
            launchLocked(entry)
            return NotesChatTransferAdmission.STARTED
        }
    }

    /**
     * True only while [conversationID]/[text] has a live transfer already
     * owned by this controller. The host uses it to reject a forged/mismatched
     * callback without claiming an admission it did not make.
     */
    fun isAdmitted(conversationID: String, text: String): Boolean =
        synchronized(lock) { entries.containsKey(messageKey(conversationID, text)) }

    fun retry(transferID: String): Boolean = synchronized(lock) {
        val entry = entries.values.firstOrNull { it.transferID == transferID } ?: return false
        if (entry.state !is NotesChatTransferState.Failed) return false
        if (entry.text == null && entry.edits == null) return false
        launchLocked(entry)
        true
    }

    /**
     * Cancel one live attempt but KEEP its durable record (if any) so [retry]
     * or [resume] can still deliver the exact plan.
     */
    fun abort(transferID: String): Boolean = synchronized(lock) {
        val entry = entries.values.firstOrNull { it.transferID == transferID } ?: return false
        if (entry.state !is NotesChatTransferState.Saving) return false
        entry.job?.cancel()
        true
    }

    /** Drops only the visible state row; durable content is never deleted here. */
    fun dismiss(transferID: String): Boolean = synchronized(lock) {
        val key = entries.entries.firstOrNull { it.value.transferID == transferID }?.key ?: return false
        val entry = entries[key] ?: return false
        if (entry.state is NotesChatTransferState.Saving) return false
        entries.remove(key)
        publishLocked()
        true
    }

    /* ------------------------------- execution ------------------------------ */

    private fun launchLocked(entry: Entry) {
        val startedAt = clock()
        entry.dispatchStarted = false
        entry.recoveryPersisted = false
        entry.state = NotesChatTransferState.Saving(
            transferID = entry.transferID,
            rootEpoch = entry.owner.rootEpoch,
            startedAt = startedAt,
        )
        publishLocked()
        val job = scope.launch(start = CoroutineStart.LAZY) { runTransfer(entry) }
        entry.job = job
        job.start()
    }

    private suspend fun runTransfer(entry: Entry) {
        try {
            val target = targets() ?: throw TransferFailure("notesPreparing", retryable = true)
            recoveryStore = target.recovery
            ensureFence(entry)
            val service = target.service
            var edits = entry.edits
            var requestID = entry.requestID
            if (edits == null || requestID == null) {
                val text = entry.text ?: throw TransferFailure("emptyMessage", retryable = false)
                // The body is planned BEFORE any native call, against a
                // synthetic EMPTY notebook. The plan is self-contained: it
                // inserts its own pages at index 0, so the identical edits are
                // valid on a not-yet-created document, on the freshly created
                // one (its default page simply follows) and on an existing
                // document restored from a previous attempt.
                val plan = planTextInsertion(
                    document = provisionalNotebook(entry),
                    pageID = null,
                    text = text,
                    markdown = true,
                    ids = DeterministicIds(entry.documentID),
                )
                if (plan.edits.isEmpty()) throw TransferFailure("emptyMessage", retryable = false)
                edits = plan.edits
                // Content-derived receipt: the same intent+plan always maps to
                // the same native receipt, and a different body can never be
                // mistaken for a retry of this one.
                requestID = entry.transferID + NotesEditReceipt.suffix(plan.edits)
                entry.edits = edits
                entry.requestID = requestID
            }
            // Durable BEFORE the FIRST native command (read, create or apply):
            // a cancel/crash after `document.create` can no longer lose the
            // intent or leave an orphan empty note claiming to be the copy.
            target.recovery.put(
                NotesPendingRecovery(
                    documentID = entry.documentID,
                    documentKind = NoteDocumentKind.NOTEBOOK.wire,
                    documentTitle = entry.title,
                    // Provisional creation baseline; resume re-reads the live
                    // document and applies these exact edits + receipt.
                    baseRevision = 0,
                    requestTitle = entry.title,
                    edits = edits,
                    reasonCode = REASON_PREFIX + entry.transferID,
                    createdAt = entry.createdAt,
                    requestID = requestID,
                ),
            )
            entry.recoveryPersisted = true
            ensureFence(entry)
            val document = ensureDocument(service, entry)
            if (document.deletedAt != null) throw TransferFailure("documentDeleted", retryable = false)
            ensureFence(entry)
            entry.dispatchStarted = true
            val result = service.applyAtomically(
                NotesApplyRequest(
                    documentID = entry.documentID,
                    expectedRevision = document.revision,
                    title = entry.title,
                    edits = edits,
                    requestID = requestID,
                ),
            )
            if (result.id != entry.documentID) {
                throw TransferFailure("identityMismatch", retryable = true)
            }
            if (result.deletedAt != null) throw TransferFailure("documentDeleted", retryable = false)
            // The durable document now owns the text; drop the recovery record
            // (a stale record is harmless: the same receipt reconciles it).
            runCatching { target.recovery.remove(entry.documentID) }
            entry.text = null
            entry.state = NotesChatTransferState.Saved(
                transferID = entry.transferID,
                documentID = entry.documentID,
                revision = result.revision,
                pageCount = result.pages.size,
                completedAt = clock(),
            )
            publishLocked()
        } catch (cancelled: CancellationException) {
            // Owner/root stop: keep the durable record (if any) and report a
            // truthful interrupted state. The job itself is already cancelled.
            if (entry.state is NotesChatTransferState.Saving) {
                entry.state = NotesChatTransferState.Failed(
                    transferID = entry.transferID,
                    documentID = entry.documentID,
                    code = "interrupted",
                    retryable = true,
                    keptRecovery = entry.recoveryPersisted,
                )
                publishLocked()
            }
            throw cancelled
        } catch (failure: TransferFailure) {
            entry.state = NotesChatTransferState.Failed(
                transferID = entry.transferID,
                documentID = entry.documentID,
                code = failure.code,
                retryable = failure.retryable,
                keptRecovery = entry.recoveryPersisted,
            )
            publishLocked()
        } catch (error: Throwable) {
            val notes = error as? NotesException
            val code = notes?.code ?: "saveFailed"
            val retryable = notes?.retryable ?: true
            entry.state = NotesChatTransferState.Failed(
                transferID = entry.transferID,
                documentID = entry.documentID,
                code = code,
                retryable = retryable && code != "conflict",
                keptRecovery = entry.recoveryPersisted,
            )
            publishLocked()
        } finally {
            entry.job = null
            entry.dispatchStarted = false
        }
    }

    private suspend fun ensureDocument(service: NotesService, entry: Entry): NoteDocument {
        val existing = try {
            service.document(entry.documentID)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: NotesException) {
            if (error.code != "notFound") throw error
            null
        }
        if (existing != null) {
            if (existing.deletedAt != null) throw TransferFailure("documentDeleted", retryable = false)
            if (existing.kind != NoteDocumentKind.NOTEBOOK) {
                throw TransferFailure("documentKindMismatch", retryable = false)
            }
            return existing
        }
        val created = try {
            service.createDocument(
                NotesCreateDocument(
                    kind = NoteDocumentKind.NOTEBOOK,
                    title = entry.title,
                    notebookID = null,
                    documentID = entry.documentID,
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: NotesException) {
            // A concurrent retry may have created the same id; re-read once
            // so an uncertain create is reconciled instead of re-attempted.
            val reloaded = try {
                service.document(entry.documentID)
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                null
            }
            reloaded ?: throw error
        }
        return created
    }

    /**
     * A synthetic, never-persisted empty notebook used only to plan page-aware
     * text edits before the real document exists. It carries no native state.
     */
    private fun provisionalNotebook(entry: Entry): NoteDocument = NoteDocument(
        id = entry.documentID,
        kind = NoteDocumentKind.NOTEBOOK,
        title = entry.title,
        revision = 0,
        pages = emptyList(),
        createdAt = 0.0,
        updatedAt = 0.0,
    )

    private fun ensureFence(entry: Entry) {
        if (closed) throw TransferFailure("ownerDisposed", retryable = true)
        if (stopping) throw TransferFailure("rootStopping", retryable = true)
        val epoch = currentRootEpoch()
        if (epoch == null || epoch != entry.owner.rootEpoch) {
            throw TransferFailure("rootChanged", retryable = true)
        }
        if (entry.owner.temporary) throw TransferFailure("temporarySession", retryable = false)
    }

    /* ------------------------------ root lifecycle -------------------------- */

    /**
     * Fence a root stop: no new admission/dispatch, in-flight jobs cancelled.
     * Returns a REAL retire decision: false only when a native write may have
     * been dispatched without a durable recovery record.
     */
    suspend fun prepareForRootStop(
        epoch: Long? = null,
        deadlineMillis: Long = 4_000L,
    ): NotesChatTransferRetireReport {
        stopping = true
        val inFlight = synchronized(lock) {
            entries.values.filter { entry ->
                entry.job != null && (epoch == null || entry.owner.rootEpoch == epoch)
            }
        }
        inFlight.forEach { it.job?.cancel() }
        val deadline = clock() + deadlineMillis.coerceAtLeast(200L)
        inFlight.forEach { entry ->
            val remaining = (deadline - clock()).coerceAtLeast(50L)
            val job = entry.job ?: return@forEach
            runCatching { withTimeoutOrNull(remaining) { job.join() } }
        }
        val kept = mutableListOf<String>()
        val saved = mutableListOf<String>()
        var canRetire = true
        val store = recoveryStore
        synchronized(lock) {
            entries.values.forEach { entry ->
                when (val state = entry.state) {
                    is NotesChatTransferState.Saved -> saved += state.documentID
                    is NotesChatTransferState.Failed -> if (state.keptRecovery) kept += entry.documentID
                    is NotesChatTransferState.Saving -> {
                        // A dispatch may have committed; without a durable
                        // record the owner cannot retire safely.
                        if (entry.dispatchStarted && !entry.recoveryPersisted) canRetire = false
                        if (entry.recoveryPersisted) kept += entry.documentID
                    }
                    NotesChatTransferState.Idle -> Unit
                }
            }
        }
        if (store != null) {
            kept += runCatching {
                store.pending()
                    .filter { it.reasonCode.startsWith(REASON_PREFIX) }
                    .map { it.documentID }
            }.getOrDefault(emptyList())
        }
        // The fence stays until resume() runs on the next bound root; a stale
        // admission can never dispatch into a retired epoch.
        return NotesChatTransferRetireReport(
            rootEpoch = epoch,
            canRetire = canRetire,
            keptDocumentIDs = kept.distinct(),
            savedDocumentIDs = saved.distinct(),
        )
    }

    /**
     * Re-open admission when a root drain was ABORTED (another owner refused
     * retirement) while the SAME root is still live.
     *
     * Strictly local and side-effect free: it does NOT resolve the Notes
     * platform, does NOT replay durable records, does NOT recreate documents
     * and does NOT touch any native state. A stale/unknown epoch is refused so
     * a late drain callback cannot re-arm a retired generation.
     *
     * True only when [epoch] is the live accepted Root epoch AND the fence was
     * actually cleared.
     */
    fun abortRootStop(epoch: Long): Boolean {
        if (closed) return false
        val current = currentRootEpoch()
        if (current == null || current != epoch) return false
        stopping = false
        return true
    }

    /**
     * Re-drive durable chat-save records for the newly bound root. Each record
     * keeps its document id, exact plan and receipt, so a commit that actually
     * landed is returned by the native receipt instead of re-applied.
     */
    suspend fun resume(): NotesChatTransferResumeReport = resumeMutex.withLock {
        stopping = false
        val target = targets() ?: return@withLock NotesChatTransferResumeReport(
            resumed = emptyList(), remaining = emptyList(), failures = listOf("notesUnavailable"),
        )
        recoveryStore = target.recovery
        val records = runCatching {
            target.recovery.pending().filter { it.reasonCode.startsWith(REASON_PREFIX) }
        }.getOrElse {
            return@withLock NotesChatTransferResumeReport(
                resumed = emptyList(), remaining = emptyList(), failures = listOf("recoveryUnavailable"),
            )
        }
        val resumed = mutableListOf<String>()
        val remaining = mutableListOf<String>()
        val failures = mutableListOf<String>()
        for (record in records) {
            val result = runCatching { resumeRecord(target.service, target.recovery, record) }
            when {
                result.getOrNull() == true -> resumed += record.documentID
                result.isFailure && result.exceptionOrNull() is CancellationException -> {
                    remaining += record.documentID
                    failures += "cancelled"
                }
                else -> {
                    remaining += record.documentID
                    failures += ((result.exceptionOrNull() as? NotesException)?.code ?: "resumeFailed")
                }
            }
        }
        NotesChatTransferResumeReport(
            resumed = resumed.distinct(),
            remaining = remaining.distinct(),
            failures = failures.distinct(),
        )
    }

    private suspend fun resumeRecord(
        service: NotesService,
        recovery: NotesRecoveryStore,
        record: NotesPendingRecovery,
    ): Boolean {
        val requestID = record.requestID ?: return false
        if (record.edits.isEmpty()) return false
        val existing = try {
            service.document(record.documentID)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: NotesException) {
            if (error.code != "notFound") throw error
            null
        }
        val document = existing ?: try {
            service.createDocument(
                NotesCreateDocument(
                    kind = NoteDocumentKind.NOTEBOOK,
                    title = record.documentTitle,
                    documentID = record.documentID,
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: NotesException) {
            val reloaded = try {
                service.document(record.documentID)
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                null
            }
            reloaded ?: throw error
        }
        if (document.deletedAt != null) {
            // The user deleted the note; the durable draft no longer has a
            // target. Report the record as resolved only by explicit removal
            // (never silently re-create a deleted note).
            return false
        }
        val result = service.applyAtomically(
            NotesApplyRequest(
                documentID = record.documentID,
                expectedRevision = document.revision,
                title = record.requestTitle,
                edits = record.edits,
                requestID = requestID,
            ),
        )
        if (result.id != record.documentID) return false
        runCatching { recovery.remove(record.documentID) }
        return true
    }

    /** App owner teardown: cancel everything; durable records stay on disk. */
    fun close() {
        closed = true
        val jobs = synchronized(lock) { entries.values.mapNotNull { it.job } }
        jobs.forEach { it.cancel() }
        synchronized(lock) { publishLocked() }
    }

    /* -------------------------------- internals ----------------------------- */

    private fun publishLocked() {
        val values = entries.values
            .map { it.state }
            .filter { it !is NotesChatTransferState.Idle }
            .takeLast(MAX_ENTRIES)
        statesFlow.value = values
        values.lastOrNull()?.let { latestFlow.value = it }
    }

    private fun pruneLocked() {
        val removable = entries.entries
            .filter { it.value.state !is NotesChatTransferState.Saving }
            .sortedBy { it.value.createdAt }
        for (candidate in removable) {
            if (entries.size < MAX_ENTRIES) break
            entries.remove(candidate.key)
        }
    }

    private fun messageKey(conversationID: String, text: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray(Charsets.UTF_8))
        val hex = digest.joinToString("") { byte ->
            (byte.toInt() and 0xff).toString(16).padStart(2, '0')
        }
        return "$conversationID:$hex"
    }

    private fun deriveTitle(text: String): String {
        val first = text.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }.orEmpty()
        val stripped = first.trimStart('#', '>', '-', '*', '+', ' ').trim()
        val base = stripped.ifBlank { first }.ifBlank { DEFAULT_TITLE }
        var end = minOf(base.length, MAX_TITLE_CHARS)
        if (end > 0 && end < base.length && Character.isLowSurrogate(base[end]) &&
            Character.isHighSurrogate(base[end - 1])
        ) {
            end -= 1
        }
        return base.substring(0, end).ifBlank { DEFAULT_TITLE }
    }

    /** Deterministic ids so the same document+text plans the same pages/edit ids. */
    private class DeterministicIds(seed: String) : NotesIdSource {
        private val seed = seed
        private var index = 0

        override fun next(): String {
            val value = UUID.nameUUIDFromBytes("$seed/${index++}".toByteArray(Charsets.UTF_8))
            return value.toString()
        }
    }

    private class TransferFailure(val code: String, val retryable: Boolean) : Exception(code)

    private class Entry(
        val transferID: String,
        val messageKey: String,
        val owner: NotesChatTransferOwner,
        val documentID: String,
        val title: String,
        val createdAt: Long = System.currentTimeMillis(),
    ) {
        var text: String? = null
        var edits: List<NotesEdit>? = null
        var requestID: String? = null
        var state: NotesChatTransferState = NotesChatTransferState.Idle
        var job: Job? = null
        var dispatchStarted: Boolean = false
        var recoveryPersisted: Boolean = false
    }

    private companion object {
        const val MAX_TEXT_BYTES = 2_097_152
        const val MAX_ENTRIES = 32
        const val MAX_TITLE_CHARS = 80
        const val DEFAULT_TITLE = "Notes"
        const val REASON_PREFIX = "chatMessageSave:"
    }
}

/** The exact conversation entry that authorized one save. */
internal data class NotesChatTransferOwner(
    val conversationID: String,
    val sessionEpoch: Long,
    val temporary: Boolean,
    val rootEpoch: Long,
)

internal enum class NotesChatTransferAdmission {
    STARTED,
    ALREADY_PENDING,
    ALREADY_SAVED,
    REJECTED_TEMPORARY,
    REJECTED_OWNER,
    REJECTED_EMPTY,
    REJECTED_TOO_LARGE,
    REJECTED_ROOT,
    REJECTED_DISPOSED,
    REJECTED_UNAVAILABLE,
}

internal sealed interface NotesChatTransferState {
    data object Idle : NotesChatTransferState

    /** Admitted and queued/extracting/committing; NOT saved. */
    data class Saving(
        val transferID: String,
        val rootEpoch: Long,
        val startedAt: Long,
    ) : NotesChatTransferState

    /** The durable note owns the complete text at [revision]. */
    data class Saved(
        val transferID: String,
        val documentID: String,
        val revision: Int,
        val pageCount: Int,
        val completedAt: Long,
    ) : NotesChatTransferState

    /**
     * [keptRecovery] means the exact plan is durably retained and [retry] or
     * [NotesChatTransferController.resume] can redeliver it with the same
     * receipt.
     */
    data class Failed(
        val transferID: String,
        val documentID: String?,
        val code: String,
        val retryable: Boolean,
        val keptRecovery: Boolean,
    ) : NotesChatTransferState
}

/** Real targets resolved when the App-owned Notes platform is ready. */
internal class NotesChatTransferTargets(
    val service: NotesService,
    val recovery: NotesRecoveryStore,
)

internal data class NotesChatTransferRetireReport(
    /** The root epoch this report fenced, or null for "whatever is live". */
    val rootEpoch: Long?,
    val canRetire: Boolean,
    val keptDocumentIDs: List<String>,
    val savedDocumentIDs: List<String>,
)

internal data class NotesChatTransferResumeReport(
    val resumed: List<String>,
    val remaining: List<String>,
    val failures: List<String>,
)
