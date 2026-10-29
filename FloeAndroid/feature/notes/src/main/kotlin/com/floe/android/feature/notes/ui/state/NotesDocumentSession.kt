// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.state

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.notes.MindMapNode
import com.floe.android.feature.notes.MindMapPoint
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotePaper
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.NoteSourceReference
import com.floe.android.feature.notes.NotesApplyRequest
import com.floe.android.feature.notes.NotesAtomicBatchService
import com.floe.android.feature.notes.NotesCoverRequest
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesProtocol
import com.floe.android.feature.notes.NotesSaveMessage
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.api.NotesInkToolKind
import com.floe.android.feature.notes.ui.api.NotesInkToolSpec
import com.floe.android.feature.notes.ui.api.NotesIndexingRequest
import com.floe.android.feature.notes.ui.api.NotesIndexingResult
import com.floe.android.feature.notes.ui.api.NotesIndexingStatus
import com.floe.android.feature.notes.ui.api.NotesPdfHandle
import com.floe.android.feature.notes.ui.api.NotesPdfOpenOutcome
import com.floe.android.feature.notes.ui.api.NotesPdfOpenRequest
import com.floe.android.feature.notes.ui.api.NotesNormalizedRect
import com.floe.android.feature.notes.ui.api.NotesPdfSearchOutcome
import com.floe.android.feature.notes.ui.presentation.MindMapLayoutDirection
import com.floe.android.feature.notes.ui.presentation.NotesEditConflict
import com.floe.android.feature.notes.ui.presentation.NotesFailure
import com.floe.android.feature.notes.ui.presentation.NotesLoadStatus
import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import com.floe.android.feature.notes.ui.presentation.NotesRequestBudget
import com.floe.android.feature.notes.ui.presentation.NotesSaveStatus
import com.floe.android.feature.notes.ui.presentation.NotesEditorTool
import com.floe.android.feature.notes.ui.presentation.NotesEditReceipt
import com.floe.android.feature.notes.ui.presentation.NotesElementGeometry
import com.floe.android.feature.notes.ui.presentation.NotesIdSource
import com.floe.android.feature.notes.ui.presentation.NotesTextPlan
import com.floe.android.feature.notes.ui.presentation.coalesceEdits
import com.floe.android.feature.notes.ui.presentation.planElementTextReplacement
import com.floe.android.feature.notes.ui.presentation.planTextInsertion
import com.floe.android.feature.notes.ui.presentation.resolveElementText
import com.floe.android.feature.notes.ui.presentation.toNotesFailure
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

public data class NotesPageArtifacts(
    public val pageID: String,
    public val backgroundBytes: ByteArray? = null,
    public val drawingBytes: ByteArray? = null,
    public val elementImages: Map<String, ByteArray> = emptyMap(),
    public val elementImageFailures: Set<String> = emptySet(),
    public val pdfPageIndex: Int? = null,
    public val renderedPdfPage: ByteArray? = null,
    public val pdfFailure: NotesFailure? = null,
    public val loadedAt: Long = 0L,
)

public sealed interface NotesFlushResult {
    public data object NoPending : NotesFlushResult
    public data object Saved : NotesFlushResult
    public data class Failed(public val failure: NotesFailure) : NotesFlushResult
    public data class Conflict(public val conflict: NotesEditConflict) : NotesFlushResult
    public data object Fenced : NotesFlushResult
}

/**
 * One document's complete presentation/editor state. Instances live in the
 * workspace keyed by stable document id, so a late native result can only ever
 * touch the document that issued it. A document switch changes which session
 * is rendered; it never cancels or retargets another session's write.
 */
@Stable
internal class NotesDocumentSession(
    val documentID: String,
    private val service: NotesService,
    private val ports: NotesHostPorts,
    private val resources: NotesResourceAccess,
    private val scope: CoroutineScope,
    private val generation: () -> Long,
    private val fenced: () -> Boolean,
    private val onLibraryInvalidated: () -> Unit,
) {
    private val preferences = ports.presentation.loadDocument(documentID)

    var document by mutableStateOf<NoteDocument?>(null)
        private set
    var loadStatus by mutableStateOf(NotesLoadStatus.LOADING)
        private set
    var loadFailure by mutableStateOf<NotesFailure?>(null)
        private set

    var saveStatus by mutableStateOf(NotesSaveStatus.SAVED)
        private set
    var saveFailure by mutableStateOf<NotesFailure?>(null)
        private set
    var conflict by mutableStateOf<NotesEditConflict?>(null)
        private set
    var externalRevision by mutableStateOf<Int?>(null)
        private set
    var canUndo by mutableStateOf(false)
        private set
    var canRedo by mutableStateOf(false)
        private set

    var activePageID by mutableStateOf(preferences.pageID)
        private set
    var pageZoom by mutableStateOf(preferences.zoom.coerceIn(0.5f, 3f))
        private set
    var pageScrollFraction by mutableStateOf(preferences.scrollFraction.coerceIn(0f, 1f))
        private set
    var editorTool by mutableStateOf(NotesEditorTool.fromKey(preferences.tool))
        private set
    var inkTool by mutableStateOf(NotesInkToolKind.PEN)
    var inkColor by mutableStateOf(preferences.penColor)
        private set
    var inkWidth by mutableStateOf(preferences.penWidth.coerceIn(0.5f, 32f))
        private set
    var fingerDrawing by mutableStateOf(preferences.fingerDrawing)
        private set
    var inkPenOnly by mutableStateOf(!preferences.fingerDrawing)

    var selectedElementIDs by mutableStateOf<Set<String>>(emptySet())
        private set
    var assistantOpen by mutableStateOf(false)
    var showOutline by mutableStateOf(false)
    var showLinkedMaps by mutableStateOf(false)

    var artifacts by mutableStateOf<NotesPageArtifacts?>(null)
        private set
    var artifactsLoading by mutableStateOf(false)
        private set
    var artifactsFailure by mutableStateOf<NotesFailure?>(null)
        private set

    var pendingInk by mutableStateOf<Map<String, ByteArray>>(emptyMap())
        private set
    var inkSaveStatus by mutableStateOf(NotesSaveStatus.SAVED)
        private set
    var inkSaveFailure by mutableStateOf<NotesFailure?>(null)
        private set
    var inkSelectionCount by mutableStateOf(0)
        private set
    var pdfSearchHighlightPage by mutableStateOf<Int?>(null)
        private set
    var pdfSearchRects by mutableStateOf<List<NotesNormalizedRect>>(emptyList())
        private set

    var pendingEditCount by mutableStateOf(0)
        private set
    var largeEditPending by mutableStateOf(false)
        private set
    var recoveryKept by mutableStateOf(false)
        private set

    val assistant: NotesAssistantController by lazy {
        NotesAssistantController(this, service, ports.assistant, scope)
    }

    private val flushMutex = Mutex()
    private val inkMutex = Mutex()
    private var pendingEdits: List<NotesEdit> = emptyList()
    private var pendingTitle: String = "Notes edit"
    private var pendingRequestID: String? = null
    private var autosaveJob: Job? = null
    private var inkSaveJob: Job? = null
    private var flushing = false
    private var stoppingFlush = false
    private var disposed = false
    private var editGeneration = 0L
    private var loadToken = 0
    private var artifactToken = 0
    private val pdfHandles = mutableMapOf<String, NotesPdfHandle>()
    private val pdfFailures = mutableMapOf<String, NotesFailure>()
    /**
     * OCR-specific: the exact stored document/page an OCR result was
     * recognized for. Insert is an explicit user action and must never
     * retarget recognized text to another page or note.
     */
    private var recognizedPageOrigin: Pair<String, String>? = null

    private val _rootStop = MutableStateFlow<NotesRootStopReport?>(null)
    val lastRootStopReport: StateFlow<NotesRootStopReport?> = _rootStop.asStateFlow()

    val isReadOnly: Boolean
        get() = document?.deletedAt != null

    val currentPage: NotePage?
        get() = document?.pages?.firstOrNull { it.id == activePageID } ?: document?.pages?.firstOrNull()

    val currentPageIndex: Int?
        get() = document?.pages?.indexOfFirst { it.id == currentPage?.id }?.takeIf { it >= 0 }

    val currentRevision: Int
        get() = document?.revision ?: 0

    /* ------------------------------- load --------------------------------- */

    suspend fun load(focusPageID: String? = null): Boolean {
        val token = ++loadToken
        loadStatus = NotesLoadStatus.LOADING
        loadFailure = null
        return try {
            val loaded = service.document(documentID)
            if (token != loadToken || disposed) return false
            if (loaded.id != documentID) {
                loadFailure = NotesFailure("invalidDocument", "identityMismatch")
                loadStatus = NotesLoadStatus.FAILED
                return false
            }
            adoptDocument(loaded, allowOlder = true)
            val target = focusPageID?.takeIf { id -> loaded.pages.any { it.id == id } }
                ?: activePageID?.takeIf { id -> loaded.pages.any { it.id == id } }
                ?: loaded.pages.firstOrNull()?.id
            if (activePageID != target) {
                activePageID = target
                persistPreferences()
            }
            loadStatus = NotesLoadStatus.READY
            // A fresh process/session must surface an existing durable draft
            // instead of presenting it as already saved. A recovery-index read
            // failure must not hide the document itself.
            recoveryKept = runCatching {
                ports.recovery.pending().any { it.documentID == documentID }
            }.getOrDefault(false)
            refreshHistory()
            if (loaded.deletedAt == null) {
                runCatching { service.markOpened(documentID) }
            }
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            if (token == loadToken) {
                loadFailure = error.toNotesFailure()
                loadStatus = NotesLoadStatus.FAILED
            }
            false
        }
    }

    private fun adoptDocument(loaded: NoteDocument, allowOlder: Boolean = false) {
        val current = document
        if (loaded.id != documentID) return
        if (!allowOlder && current != null && loaded.revision < current.revision) return
        document = loaded
        if (activePageID == null || loaded.pages.none { it.id == activePageID }) {
            activePageID = loaded.pages.firstOrNull()?.id
        }
        if (saveStatus == NotesSaveStatus.SAVED && pendingEdits.isEmpty()) {
            saveFailure = null
        }
        assistant.onDocumentReplaced()
    }

    private suspend fun refreshHistory() {
        try {
            val state = service.history(documentID)
            canUndo = state.canUndo
            canRedo = state.canRedo
        } catch (_: Throwable) {
            // History availability is advisory; a failed read must not hide
            // the document or pretend undo is available.
        }
    }

    /* --------------------------- presentation ----------------------------- */

    fun setActivePage(pageID: String) {
        if (document?.pages?.none { it.id == pageID } != false) return
        if (activePageID != pageID) pageScrollFraction = 0f
        activePageID = pageID
        selectedElementIDs = emptySet()
        artifacts = null
        artifactsFailure = null
        clearPdfSearchHighlight()
        persistPreferences()
        assistant.onPageChanged(pageID)
    }

    fun applyPageZoom(value: Float) {
        pageZoom = value.coerceIn(0.5f, 3f)
        persistPreferences()
    }

    fun setPageScroll(pageID: String, fraction: Float) {
        if (pageID != activePageID) return
        pageScrollFraction = fraction.coerceIn(0f, 1f)
        persistPreferences()
    }

    fun selectEditorTool(value: NotesEditorTool) {
        editorTool = value
        persistPreferences()
    }

    fun selectInkTool(value: NotesInkToolKind) {
        inkTool = value
        assistant.inkTool = value
    }

    fun selectInkColor(value: String) {
        inkColor = value
        persistPreferences()
    }

    fun applyInkWidth(value: Float) {
        inkWidth = value.coerceIn(0.5f, 32f)
        persistPreferences()
    }

    fun setFingerDrawingEnabled(value: Boolean) {
        fingerDrawing = value
        inkPenOnly = !value
        persistPreferences()
    }

    fun setPenOnly(value: Boolean) {
        inkPenOnly = value
        fingerDrawing = !value
        persistPreferences()
    }

    fun setSelection(ids: Set<String>) {
        selectedElementIDs = ids
    }

    fun toggleSelection(id: String) {
        selectedElementIDs = if (id in selectedElementIDs) selectedElementIDs - id else selectedElementIDs + id
    }

    fun clearSelection() {
        selectedElementIDs = emptySet()
    }

    fun inkToolSpec(): NotesInkToolSpec = NotesInkToolSpec(
        kind = inkTool,
        colorHex = inkColor,
        width = inkWidth,
        fingerDrawing = fingerDrawing,
        penOnly = inkPenOnly,
    )

    private fun persistPreferences() {
        ports.presentation.saveDocument(
            documentID,
            com.floe.android.feature.notes.ui.presentation.NotesDocumentPreferences(
                pageID = activePageID,
                zoom = pageZoom,
                scrollFraction = pageScrollFraction,
                tool = editorTool.key,
                fingerDrawing = fingerDrawing,
                penColor = inkColor,
                penWidth = inkWidth,
            ),
        )
    }

    /* ------------------------------ edits --------------------------------- */

    /**
     * Queue a user edit. Returns false when the document is read-only or the
     * root is being retired; the caller must keep its local draft and show the
     * truthful blocked/failure state instead of pretending the edit saved.
     */
    fun requestEdits(edits: List<NotesEdit>, title: String): Boolean {
        if (edits.isEmpty()) return true
        if (isReadOnly || (fenced() && !stoppingFlush)) {
            saveStatus = NotesSaveStatus.BLOCKED
            saveFailure = NotesFailure("invalidOperation", if (isReadOnly) "readOnly" else "rootStopping")
            return false
        }
        pendingEdits = if (flushing) {
            pendingEdits + edits
        } else {
            coalesceEdits(pendingEdits + edits)
        }
        pendingTitle = title
        if (pendingRequestID == null) pendingRequestID = UUID.randomUUID().toString()
        pendingEditCount = pendingEdits.size
        largeEditPending = service !is NotesAtomicBatchService &&
            NotesRequestBudget.exceeds(pendingEdits, NotesRequestBudget.MAX_SAFE_BATCH_BYTES)
        if (saveStatus != NotesSaveStatus.CONFLICT) saveStatus = NotesSaveStatus.DIRTY
        scheduleAutosave()
        return true
    }

    private fun scheduleAutosave() {
        autosaveJob?.cancel()
        if (isReadOnly) return
        autosaveJob = scope.launch {
            delay(650)
            flush()
        }
    }

    /**
     * Dispatch the queued batch. A dispatched native command is never faked as
     * cancelled: on failure the exact edits stay queued; on a root-generation
     * change the response is fenced and the batch is retained for recovery.
     */
    suspend fun flush(
        allowWhileFenced: Boolean = false,
        baseRevision: Int? = null,
    ): NotesFlushResult = flushMutex.withLock {
        if (disposed) return NotesFlushResult.Fenced
        if (pendingEdits.isEmpty()) {
            if (saveStatus == NotesSaveStatus.DIRTY) saveStatus = NotesSaveStatus.SAVED
            return NotesFlushResult.NoPending
        }
        if (!allowWhileFenced && fenced()) {
            saveStatus = NotesSaveStatus.BLOCKED
            return NotesFlushResult.Fenced
        }
        val startGeneration = generation()
        val startEditGeneration = editGeneration
        val batch = pendingEdits.toList()
        val title = pendingTitle
        val requestID = pendingRequestID ?: UUID.randomUUID().toString().also { pendingRequestID = it }
        // A service with the native staged edit-batch route commits the whole
        // page-aware plan — including one larger than 64 KiB — as ONE native
        // transaction. A legacy consumer fake (no marker) keeps the old
        // per-chunk path because its backend cannot stage a whole plan.
        val atomic = service is NotesAtomicBatchService
        val chunks = if (atomic) {
            listOf(batch)
        } else {
            NotesRequestBudget.split(batch, NotesRequestBudget.MAX_SAFE_BATCH_BYTES)
        }
        flushing = true
        saveStatus = NotesSaveStatus.SAVING
        saveFailure = null
        var applied = 0
        try {
            for (chunk in chunks) {
                if (generation() != startGeneration) {
                    saveStatus = NotesSaveStatus.BLOCKED
                    rememberRecovery(batch.drop(applied), title, requestID, "staleGeneration")
                    return NotesFlushResult.Fenced
                }
                val current = document ?: run {
                    val loaded = service.document(documentID)
                    adoptDocument(loaded, allowOlder = true)
                    loaded
                }
                // Content-derived SHA-256 identity binds the receipt to the
                // exact edits. For a whole atomic plan it covers every edit
                // and page, so a retry of the same intent reuses the native
                // receipt while a changed plan cannot be mistaken for it; a
                // legacy chunk keeps its per-chunk suffix.
                val receipt = if (atomic) {
                    "$requestID${NotesEditReceipt.suffix(batch)}"
                } else {
                    "$requestID${NotesEditReceipt.suffix(chunk)}"
                }
                val request = NotesApplyRequest(
                    documentID = documentID,
                    expectedRevision = current.revision,
                    title = title,
                    edits = chunk,
                    requestID = receipt,
                    baseRevision = baseRevision,
                )
                val response = if (atomic) {
                    service.applyAtomically(request)
                } else {
                    service.apply(request)
                }
                if (disposed || editGeneration != startEditGeneration) {
                    // A reload/discard or teardown won the race. Never apply an
                    // old response over the newer local baseline. On teardown the
                    // dispatched command may already have committed, so retain
                    // the exact remaining batch for idempotent reconciliation.
                    saveStatus = NotesSaveStatus.BLOCKED
                    if (disposed) {
                        runCatching { rememberRecovery(batch.drop(applied), title, requestID, "disposed") }
                    }
                    return NotesFlushResult.Fenced
                }
                if (response.id != documentID) {
                    saveStatus = NotesSaveStatus.FAILED
                    saveFailure = NotesFailure("invalidDocument", "identityMismatch")
                    rememberRecovery(batch.drop(applied), title, requestID, "identityMismatch")
                    return NotesFlushResult.Failed(saveFailure!!)
                }
                if (generation() != startGeneration) {
                    // The mutation may have committed under the old root. Keep
                    // the queue for an idempotent retry with the same receipt.
                    saveStatus = NotesSaveStatus.BLOCKED
                    rememberRecovery(batch.drop(applied), title, requestID, "staleGeneration")
                    return NotesFlushResult.Fenced
                }
                val before = document?.revision ?: 0
                if (response.revision >= before) {
                    adoptDocument(response)
                } else {
                    // Never regress a newer local read; this is a real conflict.
                    conflict = NotesEditConflict(
                        documentID = documentID,
                        baseRevision = current.revision,
                        currentRevision = before,
                        detail = "staleResponse",
                    )
                    saveStatus = NotesSaveStatus.CONFLICT
                    rememberRecovery(batch.drop(applied), title, requestID, "conflict")
                    return NotesFlushResult.Conflict(conflict!!)
                }
                applied += chunk.size
                pendingEdits = pendingEdits.drop(chunk.size)
                pendingEditCount = pendingEdits.size
                if (pendingEdits.isNotEmpty() && !flushing) pendingEdits = coalesceEdits(pendingEdits)
                largeEditPending = !atomic && NotesRequestBudget.exceeds(
                    pendingEdits,
                    NotesRequestBudget.MAX_SAFE_BATCH_BYTES,
                )
            }
            pendingRequestID = null
            conflict = null
            saveFailure = null
            saveStatus = if (pendingEdits.isEmpty()) NotesSaveStatus.SAVED else NotesSaveStatus.DIRTY
            pendingEditCount = pendingEdits.size
            ports.recovery.remove(documentID)
            recoveryKept = false
            refreshHistory()
            onLibraryInvalidated()
            if (pendingEdits.isNotEmpty()) scheduleAutosave()
            NotesFlushResult.Saved
        } catch (cancelled: CancellationException) {
            // Scope cancellation must not drop edits. The batch stays queued;
            // the caller/parent decides whether to retry or persist recovery.
            saveStatus = NotesSaveStatus.BLOCKED
            rememberRecovery(batch.drop(applied), title, requestID, "cancelled")
            throw cancelled
        } catch (error: Throwable) {
            val failure = error.toNotesFailure()
            saveFailure = failure
            saveStatus = when {
                failure.code == "conflict" -> NotesSaveStatus.CONFLICT
                failure.code == "staleGeneration" || failure.code == "notesNotBound" -> NotesSaveStatus.BLOCKED
                else -> NotesSaveStatus.FAILED
            }
            if (failure.code == "conflict") {
                conflict = NotesEditConflict(
                    documentID = documentID,
                    baseRevision = baseRevision ?: (document?.revision ?: 0),
                    currentRevision = document?.revision,
                    detail = failure.detail,
                )
            }
            rememberRecovery(batch.drop(applied), title, requestID, failure.code)
            NotesFlushResult.Failed(failure)
        } finally {
            flushing = false
            pendingEditCount = pendingEdits.size
            largeEditPending = service !is NotesAtomicBatchService &&
                NotesRequestBudget.exceeds(
                    pendingEdits,
                    NotesRequestBudget.MAX_SAFE_BATCH_BYTES,
                )
            if (saveStatus == NotesSaveStatus.SAVING) {
                saveStatus = if (pendingEdits.isEmpty()) NotesSaveStatus.SAVED else NotesSaveStatus.DIRTY
            }
        }
    }

    private fun rememberRecovery(edits: List<NotesEdit>, title: String, requestID: String?, reason: String) {
        if (edits.isEmpty()) return
        ports.recovery.put(
            NotesPendingRecovery(
                documentID = documentID,
                documentKind = document?.kind?.wire.orEmpty(),
                documentTitle = document?.title ?: documentID,
                baseRevision = document?.revision ?: 0,
                requestTitle = title,
                edits = edits,
                reasonCode = reason,
                createdAt = System.currentTimeMillis(),
                requestID = requestID,
                inkDrafts = pendingInk,
            ),
        )
        recoveryKept = true
    }

    suspend fun retrySave(): NotesFlushResult = flush()

    suspend fun retryWithBase(): NotesFlushResult {
        val base = conflict?.baseRevision ?: return NotesFlushResult.NoPending
        return flush(baseRevision = base)
    }

    suspend fun reloadDiscardingPending(): Boolean {
        editGeneration += 1
        pendingEdits = emptyList()
        pendingRequestID = null
        pendingEditCount = 0
        largeEditPending = false
        conflict = null
        saveFailure = null
        saveStatus = NotesSaveStatus.SAVED
        ports.recovery.remove(documentID)
        _rootStop.value = null
        return load()
    }

    suspend fun undo(redo: Boolean = false): Boolean {
        if (pendingEdits.isNotEmpty()) {
            val result = flush()
            if (result is NotesFlushResult.Failed || result is NotesFlushResult.Conflict ||
                result is NotesFlushResult.Fenced
            ) return false
        }
        return try {
            val current = document ?: return false
            val updated = service.undo(documentID, current.revision, redo)
            adoptDocument(updated)
            refreshHistory()
            onLibraryInvalidated()
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            saveFailure = error.toNotesFailure()
            saveStatus = NotesSaveStatus.FAILED
            false
        }
    }

    fun markExternalRevision(revision: Int) {
        val current = document?.revision ?: return
        if (revision <= current) return
        if (pendingEdits.isEmpty()) {
            externalRevision = revision
        } else {
            // Local unsaved edits must not be silently overwritten.
            externalRevision = revision
            if (saveStatus != NotesSaveStatus.CONFLICT) {
                saveStatus = NotesSaveStatus.CONFLICT
                conflict = NotesEditConflict(
                    documentID = documentID,
                    baseRevision = current,
                    currentRevision = revision,
                    detail = "externalChange",
                )
            }
        }
    }

    suspend fun reloadExternal() {
        externalRevision = null
        if (pendingEdits.isEmpty()) {
            load()
        } else {
            externalRevision = document?.revision?.plus(1)
        }
    }

    suspend fun rename(title: String): Boolean = requestEdits(listOf(NotesEdit.Rename(title)), "Rename note")
    suspend fun setFavorite(value: Boolean): Boolean = requestEdits(listOf(NotesEdit.Favorite(value)), "Favorite")
    suspend fun setTags(tags: List<String>): Boolean = requestEdits(listOf(NotesEdit.Tags(tags)), "Tags")
    suspend fun moveToNotebook(notebookID: String?): Boolean =
        requestEdits(listOf(NotesEdit.MoveToNotebook(notebookID)), "Move note")

    suspend fun setTrashed(trashed: Boolean): Boolean {
        if (pendingEdits.isNotEmpty()) {
            val flushed = flush()
            if (flushed is NotesFlushResult.Failed || flushed is NotesFlushResult.Conflict ||
                flushed is NotesFlushResult.Fenced
            ) return false
        }
        return try {
            val current = document ?: return false
            val updated = service.setTrashed(documentID, current.revision, trashed)
            adoptDocument(updated)
            onLibraryInvalidated()
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            saveFailure = error.toNotesFailure()
            saveStatus = NotesSaveStatus.FAILED
            false
        }
    }

    suspend fun deletePermanently(): Boolean {
        if (pendingEdits.isNotEmpty()) return false
        return try {
            val current = document ?: return false
            service.deletePermanently(documentID, current.revision)
            onLibraryInvalidated()
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            saveFailure = error.toNotesFailure()
            false
        }
    }

    suspend fun applyCover(resourceID: String?, preparedRevision: Int? = null): Boolean {
        if (pendingEdits.isNotEmpty()) flush()
        return try {
            val current = document ?: return false
            val cover = service.cover(documentID)
            val updated = service.applyCover(
                NotesCoverRequest(
                    documentID = documentID,
                    expectedRevision = preparedRevision ?: current.revision,
                    expectedCoverRevision = cover.coverRevision,
                    resourceID = resourceID,
                ),
            )
            adoptDocument(updated)
            onLibraryInvalidated()
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            saveFailure = error.toNotesFailure()
            false
        }
    }

    suspend fun createLinkedMindMap(title: String, pageID: String?): NoteDocument? {
        if (pendingEdits.isNotEmpty()) {
            val result = flush()
            if (result is NotesFlushResult.Failed || result is NotesFlushResult.Conflict ||
                result is NotesFlushResult.Fenced
            ) return null
        }
        return try {
            val current = document ?: return null
            val created = service.createLinkedMindMap(documentID, current.revision, title, pageID)
            onLibraryInvalidated()
            if (created.id == documentID) adoptDocument(created)
            created
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            saveFailure = error.toNotesFailure()
            null
        }
    }

    /* --------------------------- page/element ----------------------------- */

    fun insertTextElement(): NoteElement? {
        val page = currentPage ?: return null
        val frame = NotesElementGeometry.nextInsertionFrame(
            page,
            width = (page.width - 80.0).coerceAtMost(520.0),
            height = 120.0,
        )
        val element = NoteElement(
            id = UUID.randomUUID().toString(),
            kind = NoteElementKind.TEXT,
            frame = frame,
            text = "",
            fontSize = 20.0,
        )
        if (!requestEdits(listOf(NotesEdit.UpsertElement(page.id, element)), "Insert text")) return null
        selectedElementIDs = setOf(element.id)
        return element
    }

    suspend fun retryInk(): Boolean {
        var success = true
        pendingInk.keys.toList().forEach { pageID ->
            if (!commitInk(pageID)) success = false
        }
        return success
    }

    fun addPage(paper: NotePaper = NotePaper.PLAIN): Boolean {
        val doc = document ?: return false
        val page = NotePage(id = UUID.randomUUID().toString(), paper = paper)
        val accepted = requestEdits(
            listOf(NotesEdit.InsertPage(page, doc.pages.size)),
            "Add page",
        )
        if (accepted) activePageID = page.id
        return accepted
    }

    fun duplicatePage(pageID: String): Boolean =
        requestEdits(listOf(NotesEdit.DuplicatePage(pageID)), "Duplicate page")

    fun deletePage(pageID: String): Boolean {
        val doc = document ?: return false
        if (doc.pages.size <= 1) return false
        return requestEdits(listOf(NotesEdit.DeletePage(pageID)), "Delete page")
    }

    fun movePage(pageID: String, index: Int): Boolean =
        requestEdits(listOf(NotesEdit.MovePage(pageID, index)), "Move page")

    fun setPagePaper(pageID: String, paper: NotePaper): Boolean {
        val page = document?.pages?.firstOrNull { it.id == pageID } ?: return false
        return requestEdits(
            listOf(NotesEdit.UpdatePage(page.copy(paper = paper))),
            "Paper",
        )
    }

    fun toggleBookmark(pageID: String): Boolean {
        val page = document?.pages?.firstOrNull { it.id == pageID } ?: return false
        return requestEdits(
            listOf(NotesEdit.UpdatePage(page.copy(isBookmarked = !page.isBookmarked))),
            "Bookmark",
        )
    }

    fun insertElement(kind: NoteElementKind, resourceID: String? = null): Boolean {
        val page = currentPage ?: return false
        if (kind == NoteElementKind.IMAGE && resourceID == null) return false
        val frame = NotesElementGeometry.nextInsertionFrame(
            page,
            width = if (kind == NoteElementKind.TEXT) (page.width - 80.0).coerceAtMost(520.0) else 220.0,
            height = if (kind == NoteElementKind.TEXT) 120.0 else 120.0,
        )
        val element = NoteElement(
            id = UUID.randomUUID().toString(),
            kind = kind,
            frame = frame,
            text = if (kind == NoteElementKind.TEXT) "" else "",
            resourceID = resourceID,
            fontSize = 20.0,
        )
        val accepted = requestEdits(
            listOf(NotesEdit.UpsertElement(page.id, element)),
            "Insert ${kind.wire}",
        )
        if (accepted) selectedElementIDs = setOf(element.id)
        return accepted
    }

    fun updateElement(element: NoteElement): Boolean {
        val page = document?.pages?.firstOrNull { p -> p.elements.any { it.id == element.id } } ?: return false
        return requestEdits(listOf(NotesEdit.UpsertElement(page.id, element)), "Edit content")
    }

    fun updateElements(pageID: String, elements: List<NoteElement>): Boolean {
        if (elements.isEmpty()) return false
        return requestEdits(
            elements.map { NotesEdit.UpsertElement(pageID, it) },
            "Edit content",
        )
    }

    fun deleteSelectedElements(): Boolean {
        val page = currentPage ?: return false
        if (selectedElementIDs.isEmpty()) return false
        val accepted = requestEdits(
            listOf(NotesEdit.DeleteElements(page.id, selectedElementIDs.toList())),
            "Delete content",
        )
        if (accepted) selectedElementIDs = emptySet()
        return accepted
    }

    fun reorderSelected(toFront: Boolean): Boolean {
        val page = currentPage ?: return false
        val updated = NotesElementGeometry.reorder(page, selectedElementIDs, toFront)
        if (updated === page) return false
        return requestEdits(listOf(NotesEdit.UpdatePage(updated)), "Reorder content")
    }

    fun moveSelected(frames: Map<String, NoteRect>): Boolean {
        val page = currentPage ?: return false
        if (frames.isEmpty()) return false
        val elements = page.elements.filter { it.id in frames }.mapNotNull { element ->
            val frame = frames[element.id] ?: return@mapNotNull null
            if (NotesElementGeometry.sameFrame(frame, element.frame)) null
            else element.copy(frame = NotesElementGeometry.snap(frame))
        }
        return updateElements(page.id, elements)
    }

    fun resizeSelected(frame: NoteRect): Boolean {
        val page = currentPage ?: return false
        val id = selectedElementIDs.singleOrNull() ?: return false
        val element = page.elements.firstOrNull { it.id == id } ?: return false
        return updateElement(element.copy(frame = NotesElementGeometry.snap(frame)))
    }

    fun commitElementText(element: NoteElement, text: String, markdown: Boolean): NotesTextPlan? {
        val doc = document ?: return null
        // The App holds the toolbar-inserted element by its locally minted
        // lowercase id, while the native store re-encodes every UUID as
        // Foundation's uppercase `uuidString` in the returned document. A raw
        // string comparison would drop the target and never send the text, so
        // resolve the same UUID value against the stored element, or against
        // the still-queued insert when its response has not been adopted yet.
        val stored = doc.pages.firstNotNullOfOrNull { page ->
            page.elements.firstOrNull { sameNoteIdentity(it.id, element.id) }?.let { page to it }
        }
        val pending = if (stored == null) {
            pendingEdits.asReversed()
                .filterIsInstance<NotesEdit.UpsertElement>()
                .firstOrNull { sameNoteIdentity(it.element.id, element.id) }
        } else {
            null
        }
        val pageID = stored?.first?.id ?: pending?.pageID ?: return null
        val target = stored?.second ?: pending?.element ?: return null
        val plan = planElementTextReplacement(doc, pageID, target, text, markdown, NotesIdSource.random())
        if (plan.edits.isEmpty()) return null
        // A refused queue (read-only/root-stopping) must keep the editor's
        // draft and its truthful failure state instead of dismissing as saved.
        if (!requestEdits(plan.edits, "Edit text")) return null
        return plan
    }

    /** UUID values are case-insensitive; native `UUID.uuidString` is uppercase. */
    private fun sameNoteIdentity(left: String, right: String): Boolean {
        if (left == right) return true
        val leftValue = runCatching { UUID.fromString(left) }.getOrNull() ?: return false
        val rightValue = runCatching { UUID.fromString(right) }.getOrNull() ?: return false
        return leftValue == rightValue
    }

    fun insertText(text: String, markdown: Boolean = false): NotesTextPlan? {
        val doc = document ?: return null
        val plan = planTextInsertion(doc, activePageID, text, markdown, NotesIdSource.random())
        if (plan.edits.isEmpty()) return null
        requestEdits(plan.edits, "Insert text")
        return plan
    }

    /* ------------------------------- mind map ----------------------------- */

    fun addMindMapChild(parentID: String, title: String): Boolean {
        val doc = document ?: return false
        val parent = doc.nodes.firstOrNull { it.id == parentID } ?: return false
        val order = doc.nodes.count { it.parentID == parentID }
        val node = MindMapNode(
            id = UUID.randomUUID().toString(),
            parentID = parent.id,
            title = title,
            order = order,
        )
        return requestEdits(listOf(NotesEdit.UpsertNode(node)), "Add topic")
    }

    fun addMindMapSibling(nodeID: String, title: String): Boolean {
        val doc = document ?: return false
        val node = doc.nodes.firstOrNull { it.id == nodeID } ?: return false
        val parentID = node.parentID ?: return false
        val order = doc.nodes.count { it.parentID == parentID }
        val sibling = MindMapNode(
            id = UUID.randomUUID().toString(),
            parentID = parentID,
            title = title,
            order = order,
        )
        return requestEdits(listOf(NotesEdit.UpsertNode(sibling)), "Add topic")
    }

    fun updateMindMapNode(node: MindMapNode): Boolean =
        requestEdits(listOf(NotesEdit.UpsertNode(node)), "Edit topic")

    fun deleteMindMapBranch(nodeID: String): Boolean {
        val node = document?.nodes?.firstOrNull { it.id == nodeID } ?: return false
        if (node.parentID == null) return false
        return requestEdits(listOf(NotesEdit.DeleteBranch(nodeID)), "Delete branch")
    }

    fun addMindMapRoot(title: String): Boolean {
        val doc = document ?: return false
        if (doc.nodes.any { it.parentID == null }) return false
        val node = MindMapNode(id = UUID.randomUUID().toString(), title = title)
        return requestEdits(listOf(NotesEdit.UpsertNode(node)), "Add central topic")
    }

    fun connectMindMapNodes(fromID: String, toID: String): Boolean {
        val doc = document ?: return false
        if (fromID == toID) return false
        if (doc.nodes.none { it.id == fromID } || doc.nodes.none { it.id == toID }) return false
        val connection = com.floe.android.feature.notes.MindMapConnection(
            id = UUID.randomUUID().toString(),
            from = fromID,
            to = toID,
        )
        return requestEdits(listOf(NotesEdit.UpsertConnection(connection)), "Connect topics")
    }

    fun deleteMindMapConnection(connectionID: String): Boolean =
        requestEdits(listOf(NotesEdit.DeleteConnection(connectionID)), "Delete connection")

    fun setMindMapDirection(direction: MindMapLayoutDirection, summaries: List<com.floe.android.feature.notes.MindMapSummary> = emptyList()): Boolean =
        requestEdits(listOf(NotesEdit.MindMapLayout(direction.wire, summaries)), "Mind map layout")

    fun setMindMapNodePosition(nodeID: String, x: Double, y: Double): Boolean {
        val node = document?.nodes?.firstOrNull { it.id == nodeID } ?: return false
        val moved = node.copy(position = MindMapPoint(x, y))
        return requestEdits(listOf(NotesEdit.UpsertNode(moved)), "Move topic")
    }

    fun resetMindMapPositions(): Boolean {
        val doc = document ?: return false
        val nodes = com.floe.android.feature.notes.ui.presentation.MindMapLayoutEngine.automaticNodes(doc)
        return requestEdits(listOf(NotesEdit.ReplaceMindMap(nodes, doc.connections)), "Auto layout")
    }

    fun updateMindMapNodeImage(nodeID: String, resourceID: String?): Boolean {
        val node = document?.nodes?.firstOrNull { it.id == nodeID } ?: return false
        return requestEdits(listOf(NotesEdit.UpsertNode(node.copy(imageResourceID = resourceID))), "Topic image")
    }

    fun addMindMapAttachment(nodeID: String, attachment: com.floe.android.feature.notes.MindMapAttachment): Boolean {
        val node = document?.nodes?.firstOrNull { it.id == nodeID } ?: return false
        val attachments = (node.attachments ?: emptyList()) + attachment
        return requestEdits(listOf(NotesEdit.UpsertNode(node.copy(attachments = attachments))), "Attach file")
    }

    fun setMindMapNodeSource(nodeID: String, source: NoteSourceReference?): Boolean {
        val node = document?.nodes?.firstOrNull { it.id == nodeID } ?: return false
        return requestEdits(listOf(NotesEdit.UpsertNode(node.copy(source = source))), "Link note")
    }

    fun mindMapDirection(): MindMapLayoutDirection =
        MindMapLayoutDirection.fromWire(document?.mindMapDirection)

    /* ------------------------------- ink ---------------------------------- */

    fun onInkSelectionChanged(count: Int) {
        inkSelectionCount = count.coerceAtLeast(0)
    }

    fun onInkDraft(pageID: String, drawing: ByteArray) {
        if (isReadOnly) return
        pendingInk = pendingInk + (pageID to drawing)
        inkSaveStatus = NotesSaveStatus.DIRTY
        inkSaveFailure = null
        inkSaveJob?.cancel()
        inkSaveJob = scope.launch {
            delay(900)
            commitInk(pageID)
        }
    }

    suspend fun commitInk(pageID: String): Boolean = inkMutex.withLock {
        val drawing = pendingInk[pageID] ?: return true
        if (isReadOnly) return false
        inkSaveStatus = NotesSaveStatus.SAVING
        var imported: com.floe.android.feature.notes.ImportedResource? = null
        try {
            val resourceID: String? = if (drawing.isEmpty()) {
                null
            } else {
                imported = resources.import(
                    fileName = "page-$documentID-$pageID.floink",
                    mediaType = "application/x-floe-ink",
                    byteCount = drawing.size.toLong(),
                ) { offset, maxBytes ->
                    val start = offset.toInt().coerceIn(0, drawing.size)
                    val end = (start + maxBytes).coerceAtMost(drawing.size)
                    drawing.copyOfRange(start, end)
                }
                imported?.resourceID
            }
            val accepted = requestEdits(
                listOf(NotesEdit.Drawing(pageID = pageID, resourceID = resourceID)),
                "Save strokes",
            )
            if (!accepted) {
                inkSaveStatus = NotesSaveStatus.BLOCKED
                inkSaveFailure = NotesFailure("invalidOperation", "readOnly")
                imported?.resourceID?.let { resources.discardUnreferenced(it) }
                return false
            }
            val result = flush(allowWhileFenced = stoppingFlush)
            if (result is NotesFlushResult.Saved || result is NotesFlushResult.NoPending) {
                if (pendingInk[pageID]?.contentEquals(drawing) == true) {
                    pendingInk = pendingInk - pageID
                    inkSaveStatus = NotesSaveStatus.SAVED
                } else {
                    inkSaveStatus = NotesSaveStatus.DIRTY
                }
                inkSaveFailure = null
                true
            } else {
                inkSaveStatus = NotesSaveStatus.FAILED
                inkSaveFailure = (result as? NotesFlushResult.Failed)?.failure
                    ?: NotesFailure("conflict")
                false
            }
        } catch (cancelled: CancellationException) {
            inkSaveStatus = NotesSaveStatus.DIRTY
            throw cancelled
        } catch (error: Throwable) {
            inkSaveStatus = NotesSaveStatus.FAILED
            inkSaveFailure = error.toNotesFailure()
            imported?.resourceID?.let { resources.discardUnreferenced(it) }
            false
        }
    }

    /* ----------------------------- artifacts ------------------------------ */

    fun loadArtifacts(pageID: String, targetWidthPx: Int) {
        val token = ++artifactToken
        val page = document?.pages?.firstOrNull { it.id == pageID } ?: return
        artifactsLoading = true
        artifactsFailure = null
        scope.launch {
            val loaded: NotesPageArtifacts = try {
                val drawing = page.drawingResourceID?.let {
                    resources.readAll(it, maxBytes = 48L * 1024L * 1024L)
                }
                var background: ByteArray? = null
                var renderedPdf: ByteArray? = null
                var pdfFailure: NotesFailure? = null
                val pdfIndex = page.pdfPageIndex
                val pageResourceID = page.backgroundResourceID
                if (pdfIndex != null && pageResourceID != null) {
                    val handle = ensurePdf(pageResourceID)
                    if (handle == null) {
                        pdfFailure = pdfFailures[pageResourceID]
                            ?: NotesFailure("resourceUnavailable", "pdf")
                    } else {
                        renderedPdf = try {
                            handle.renderPage(
                                pdfIndex.coerceIn(0, handle.pageCount - 1),
                                targetWidthPx.coerceIn(320, 4096),
                            )
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (error: Throwable) {
                            // A render failure must be visible as a typed page
                            // error, never a silently blank page.
                            pdfFailure = error.toNotesFailure()
                            null
                        }
                    }
                } else if (pageResourceID != null) {
                    background = resources.readAll(
                        pageResourceID,
                        maxBytes = 24L * 1024L * 1024L,
                    )
                }
                val images = mutableMapOf<String, ByteArray>()
                val failures = mutableSetOf<String>()
                page.elements.filter { it.kind == NoteElementKind.IMAGE }.forEach { element ->
                    val resourceID = element.resourceID ?: return@forEach
                    if (images.containsKey(resourceID) || resourceID in failures) return@forEach
                    try {
                        images[resourceID] = resources.readAll(
                            resourceID,
                            maxBytes = 16L * 1024L * 1024L,
                        )
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Throwable) {
                        failures += resourceID
                    }
                }
                NotesPageArtifacts(
                    pageID = pageID,
                    backgroundBytes = background,
                    drawingBytes = drawing,
                    elementImages = images,
                    elementImageFailures = failures,
                    pdfPageIndex = page.pdfPageIndex,
                    renderedPdfPage = renderedPdf,
                    pdfFailure = pdfFailure,
                    loadedAt = System.currentTimeMillis(),
                )
            } catch (cancelled: CancellationException) {
                if (token == artifactToken && !disposed) artifactsLoading = false
                throw cancelled
            } catch (error: Throwable) {
                if (token == artifactToken && !disposed) {
                    artifactsFailure = error.toNotesFailure()
                    artifactsLoading = false
                }
                return@launch
            }
            if (token != artifactToken || disposed) return@launch
            artifacts = loaded
            artifactsFailure = loaded.pdfFailure
            artifactsLoading = false
        }
    }

    suspend fun ensurePdf(resourceID: String): NotesPdfHandle? {
        pdfHandles[resourceID]?.let { return it }
        pdfFailures[resourceID]?.let { return null }
        val doc = document ?: return null
        return try {
            val record = service.resourceMetadata(resourceID)
            when (val outcome = ports.media.openPdf(
                NotesPdfOpenRequest(
                    documentID = doc.id,
                    resourceID = resourceID,
                    sha256 = record.hash,
                    byteCount = record.byteCount,
                    fileName = record.fileName,
                    mediaType = record.mediaType,
                    read = resources.reader(),
                ),
            )) {
                is NotesPdfOpenOutcome.Opened -> {
                    pdfHandles[resourceID] = outcome.handle
                    outcome.handle
                }
                NotesPdfOpenOutcome.PasswordRequired -> {
                    pdfFailures[resourceID] = NotesFailure("passwordRequired")
                    null
                }
                is NotesPdfOpenOutcome.Unavailable -> {
                    pdfFailures[resourceID] = outcome.failure.toNotesFailure()
                    null
                }
                is NotesPdfOpenOutcome.Failed -> {
                    pdfFailures[resourceID] = outcome.failure.toNotesFailure()
                    null
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            pdfFailures[resourceID] = error.toNotesFailure()
            null
        }
    }

    fun showPdfSearchHighlight(pageIndex: Int, rects: List<NotesNormalizedRect>) {
        pdfSearchHighlightPage = pageIndex
        pdfSearchRects = rects
    }

    fun clearPdfSearchHighlight() {
        pdfSearchHighlightPage = null
        pdfSearchRects = emptyList()
    }

    suspend fun pdfThumbnail(pageID: String, targetWidthPx: Int): ByteArray? {
        val doc = document ?: return null
        val page = doc.pages.firstOrNull { it.id == pageID } ?: return null
        val index = page.pdfPageIndex ?: return null
        val resourceID = page.backgroundResourceID ?: return null
        val handle = ensurePdf(resourceID) ?: return null
        return runCatching {
            handle.renderPage(index.coerceIn(0, handle.pageCount - 1), targetWidthPx.coerceIn(96, 512))
        }.getOrNull()
    }

    suspend fun searchPdf(query: String, matchCase: Boolean): NotesPdfSearchOutcome {
        val page = currentPage ?: return NotesPdfSearchOutcome.NoMatches
        val resourceID = page.backgroundResourceID ?: return NotesPdfSearchOutcome.NoMatches
        if (page.pdfPageIndex == null) return NotesPdfSearchOutcome.NoMatches
        val handle = ensurePdf(resourceID)
            ?: return NotesPdfSearchOutcome.Unavailable(
                pdfFailures[resourceID]?.code ?: "pdfUnavailable",
            )
        return runCatching { handle.search(query, limit = 80, matchCase = matchCase) }.getOrElse {
            if (it is CancellationException) throw it
            NotesPdfSearchOutcome.Unavailable(it.toNotesFailure().code)
        }
    }

    /* ------------------------------ indexing ------------------------------ */

    suspend fun indexingStatus(): NotesIndexingStatus? = ports.indexing?.status()

    suspend fun recognizeCurrentPage(): NotesIndexingResult {
        val port = ports.indexing ?: throw com.floe.android.feature.notes.NotesException(
            "unsupportedAction", "ocrNotConnected",
        )
        val doc = document ?: throw com.floe.android.feature.notes.NotesException("notFound", "document")
        val page = currentPage ?: throw com.floe.android.feature.notes.NotesException("notFound", "page")
        recognizedPageOrigin = null

        // OCR must see the SAVED page: pending strokes are not part of the
        // native page's visual index until commitInk has imported and flushed
        // this exact drawing. A fenced/conflicted/failed flush stops OCR and
        // leaves the user's draft queued/recoverable.
        if (pendingInk.containsKey(page.id)) {
            if (!commitInk(page.id)) {
                val failure = inkSaveFailure
                throw com.floe.android.feature.notes.NotesException(
                    failure?.code ?: "conflict",
                    failure?.detail ?: "ocrInkNotSaved",
                    retryable = false,
                )
            }
        }
        if (pendingEdits.isNotEmpty()) {
            when (val flushed = flush()) {
                is NotesFlushResult.Failed -> throw com.floe.android.feature.notes.NotesException(
                    flushed.failure.code,
                    flushed.failure.detail ?: "ocrFlushFailed",
                    retryable = false,
                )
                is NotesFlushResult.Conflict -> throw com.floe.android.feature.notes.NotesException(
                    "conflict", "ocrFlushConflict", retryable = false,
                )
                NotesFlushResult.Fenced -> throw com.floe.android.feature.notes.NotesException(
                    "staleGeneration", "ocrFlushFenced", retryable = true,
                )
                NotesFlushResult.NoPending, NotesFlushResult.Saved -> Unit
            }
        }
        if (pendingInk.containsKey(page.id)) {
            // A stroke landed while the flush was in flight; do not render an
            // older page. The draft stays pending and the user can retry.
            throw com.floe.android.feature.notes.NotesException(
                "busy", "ocrInkPending", retryable = true,
            )
        }

        // Re-read the exact saved snapshot; the host independently re-reads
        // the same native page/key and renders it.
        val stored = try {
            service.document(doc.id)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            throw error.toNotesFailure().let {
                com.floe.android.feature.notes.NotesException(
                    it.code, it.detail ?: "ocrSnapshot", retryable = true,
                )
            }
        }
        if (stored.id != doc.id) {
            throw com.floe.android.feature.notes.NotesException(
                "invalidDocument", "identityMismatch", retryable = false,
            )
        }
        val storedPage = stored.pages.firstOrNull { it.id == page.id }
            ?: throw com.floe.android.feature.notes.NotesException("notFound", "page")
        if (stored.revision < (document?.revision ?: 0)) {
            throw com.floe.android.feature.notes.NotesException(
                "conflict", "ocrSnapshotOlder", retryable = true,
            )
        }
        adoptDocument(stored)
        val storedIndex = stored.pages.indexOfFirst { it.id == storedPage.id }
        val pageNumber = (storedIndex + 1).takeIf { it in 1..10_000 } ?: 1
        val result = port.recognize(
            NotesIndexingRequest(
                documentID = stored.id,
                pageID = storedPage.id,
                pageNumber = pageNumber,
                pageWidthPt = storedPage.width.toFloat(),
                pageHeightPt = storedPage.height.toFloat(),
                backgroundResourceID = storedPage.backgroundResourceID,
                drawingResourceID = storedPage.drawingResourceID,
                elementTexts = storedPage.elements.map { resolveElementText(stored, it) },
                read = resources.reader(),
            ),
        )
        // The host rendered/recognized this exact SAVED page; remember the
        // origin so a user action cannot silently insert elsewhere.
        recognizedPageOrigin = stored.id to storedPage.id
        return result
    }

    fun insertRecognizedText(text: String): NotesTextPlan? {
        val doc = document ?: return null
        val page = currentPage ?: return null
        val origin = recognizedPageOrigin
        if (origin == null || origin.first != doc.id || origin.second != page.id) {
            // A different page/document is visible: the recognized text has no
            // valid insertion target in this session.
            return null
        }
        val plan = planTextInsertion(doc, page.id, text, markdown = false, ids = NotesIdSource.random())
        if (plan.edits.isEmpty()) return null
        // Annotate the first inserted element with its real page source.
        val annotated = plan.edits.map { edit ->
            if (edit is NotesEdit.UpsertElement) {
                edit.copy(
                    element = edit.element.copy(
                        source = NoteSourceReference(
                            documentID = doc.id,
                            revision = doc.revision,
                            pageID = page.id,
                        ),
                    ),
                )
            } else edit
        }
        recognizedPageOrigin = null
        requestEdits(annotated, "Insert recognized text")
        return plan
    }

    /* ---------------------------- lifecycle ------------------------------- */

    suspend fun prepareForStop(deadlineMillis: Long): NotesStopOutcome {
        autosaveJob?.cancel()
        inkSaveJob?.cancel()
        if (pendingEdits.isEmpty() && pendingInk.isEmpty()) {
            // A fresh session can own no live queue but still have a durable
            // draft. Report it as kept, never as flushed/saved.
            val durable = pendingRecoverySnapshot()
            if (durable != null) return NotesStopOutcome.Kept(durable)
            recoveryKept = false
            return NotesStopOutcome.Flushed(documentID)
        }
        val completed = withTimeoutOrNull(deadlineMillis.coerceAtLeast(250)) {
            // Commit queued ink first; its drawing edit joins the same queue.
            stoppingFlush = true
            try {
                pendingInk.keys.toList().forEach { pageID -> commitInk(pageID) }
                flush(allowWhileFenced = true)
            } finally {
                stoppingFlush = false
            }
        }
        val result = completed
        if ((result is NotesFlushResult.Saved || result is NotesFlushResult.NoPending) &&
            pendingEdits.isEmpty() && pendingInk.isEmpty()
        ) {
            return NotesStopOutcome.Flushed(documentID)
        }
        val reason = when (result) {
            is NotesFlushResult.Failed -> result.failure.code
            is NotesFlushResult.Conflict -> "conflict"
            is NotesFlushResult.Fenced -> "staleGeneration"
            // A user edit arrived after the flush completed but before the
            // session returned; it is pending, not a timeout.
            is NotesFlushResult.Saved, NotesFlushResult.NoPending -> "pendingAfterFlush"
            else -> "timeout"
        }
        // `put` is the durability authority: a throw propagates to the caller so
        // root retirement is refused, and `recoveryKept` must not claim success.
        persistPendingRecovery(reason)
        val record = pendingRecoverySnapshot()
        recoveryKept = record != null
        return NotesStopOutcome.Kept(record)
    }

    /**
     * Replays an exact durable recovery record. It is bound to this document,
     * kind and base revision; a deleted or kind-mismatched source is refused
     * without reviving it, but the draft itself is retained for explicit user
     * review/discard. The same requestID is reused so a partially committed
     * native batch stays idempotent.
     */
    suspend fun restoreRecovery(recovery: NotesPendingRecovery): NotesFlushResult {
        if (recovery.documentID != documentID) {
            return NotesFlushResult.Failed(NotesFailure("invalidDocument", "recoveryIdentity"))
        }
        val current = document ?: run {
            if (!load()) return NotesFlushResult.Failed(NotesFailure("notFound", "document"))
            document
        } ?: return NotesFlushResult.Failed(NotesFailure("notFound", "document"))
        if (current.deletedAt != null) {
            recoveryKept = true
            return NotesFlushResult.Failed(NotesFailure("notFound", "deleted"))
        }
        if (recovery.documentKind.isNotBlank() && recovery.documentKind != current.kind.wire) {
            recoveryKept = true
            return NotesFlushResult.Failed(NotesFailure("invalidDocument", "kindMismatch"))
        }
        // The same session may already hold the queue mirrored by the durable
        // record; exact duplicates are removed before coalescing so a page
        // insert is never applied twice.
        pendingEdits = coalesceEdits((recovery.edits + pendingEdits).distinct())
        pendingTitle = recovery.requestTitle
        pendingRequestID = recovery.requestID
        if (recovery.inkDrafts.isNotEmpty()) {
            // A live newer draft wins over the older durable snapshot.
            pendingInk = recovery.inkDrafts + pendingInk
        }
        pendingEditCount = pendingEdits.size
        saveStatus = NotesSaveStatus.DIRTY
        val result = flush(allowWhileFenced = true, baseRevision = recovery.baseRevision)
        val complete = (result is NotesFlushResult.Saved || result is NotesFlushResult.NoPending) &&
            pendingInk.isEmpty()
        if (complete) {
            ports.recovery.remove(documentID)
            recoveryKept = false
        } else {
            recoveryKept = pendingRecoverySnapshot() != null
        }
        return result
    }

    suspend fun resumeAfterRoot(): NotesFlushResult {
        if (document?.deletedAt != null) {
            // Deleting the source is not an instruction to discard unsaved work.
            // Keep the exact draft for explicit recovery/discard instead of reviving it.
            persistPendingRecovery("deleted")
            recoveryKept = pendingRecoverySnapshot() != null
            return NotesFlushResult.Failed(NotesFailure("notFound", "deleted"))
        }
        val durable = pendingRecoverySnapshot()
        if (durable != null) {
            // A fresh session can hold no live queue but still have a durable
            // draft from a process/root stop; a live queue may also be missing
            // earlier edits. Merge and retry instead of deleting the record.
            return restoreRecovery(durable)
        }
        if (pendingEdits.isEmpty() && pendingInk.isEmpty()) {
            recoveryKept = false
            inkSaveStatus = NotesSaveStatus.SAVED
            return NotesFlushResult.NoPending
        }
        var inkFailed = false
        pendingInk.keys.toList().forEach { pageID ->
            if (!commitInk(pageID)) inkFailed = true
        }
        if (pendingEdits.isEmpty()) {
            if (pendingInk.isEmpty()) {
                ports.recovery.remove(documentID)
                recoveryKept = false
                inkSaveStatus = NotesSaveStatus.SAVED
            }
            return if (inkFailed) NotesFlushResult.Failed(NotesFailure("storageUnavailable", "ink"))
            else NotesFlushResult.NoPending
        }
        val result = flush(allowWhileFenced = true)
        if (result is NotesFlushResult.Saved && pendingInk.isEmpty()) {
            ports.recovery.remove(documentID)
            recoveryKept = false
        }
        return result
    }

    fun noteInkDraft(pageID: String, drawing: ByteArray?) {
        if (drawing == null) {
            pendingInk = pendingInk - pageID
        } else {
            pendingInk = pendingInk + (pageID to drawing)
        }
    }

    fun inkFor(pageID: String): ByteArray? = pendingInk[pageID] ?: artifacts?.drawingBytes

    fun persistPendingRecovery(reason: String) {
        if (pendingEdits.isEmpty() && pendingInk.isEmpty()) return
        // A throwing store must not be reported as kept: set the UI flag only
        // after the durable commit succeeds.
        ports.recovery.put(
            NotesPendingRecovery(
                documentID = documentID,
                documentKind = document?.kind?.wire.orEmpty(),
                documentTitle = document?.title ?: documentID,
                baseRevision = document?.revision ?: 0,
                requestTitle = pendingTitle,
                edits = pendingEdits,
                reasonCode = reason,
                createdAt = System.currentTimeMillis(),
                requestID = pendingRequestID,
                inkDrafts = pendingInk,
            ),
        )
        recoveryKept = true
    }

    /** True when this session still owns edits/ink that are not saved. */
    internal fun hasPendingWork(): Boolean = pendingEdits.isNotEmpty() || pendingInk.isNotEmpty()

    fun pendingRecoverySnapshot(): NotesPendingRecovery? =
        ports.recovery.pending().firstOrNull { it.documentID == documentID }

    fun discardRecovery() {
        ports.recovery.remove(documentID)
        recoveryKept = false
    }

    fun dispose() {
        disposed = true
        editGeneration += 1
        autosaveJob?.cancel()
        inkSaveJob?.cancel()
        pdfHandles.values.forEach { handle -> scope.launch { runCatching { handle.close() } } }
        pdfHandles.clear()
        assistant.dispose()
    }

    /* --------------------------- assistant insert ------------------------- */

    fun insertAssistantText(text: String): Boolean {
        if (text.isBlank()) return false
        val doc = document ?: return false
        return if (doc.kind == NoteDocumentKind.MIND_MAP) {
            val root = doc.nodes.firstOrNull { it.parentID == null }
            if (root == null) {
                addMindMapRoot(text.lineSequence().firstOrNull()?.take(80) ?: text.take(80))
            } else {
                val order = doc.nodes.count { it.parentID == root.id }
                val node = MindMapNode(
                    id = UUID.randomUUID().toString(),
                    parentID = root.id,
                    title = text.lineSequence().firstOrNull()?.take(80)?.ifBlank { "Assistant" } ?: "Assistant",
                    note = text,
                    order = order,
                    source = NoteSourceReference(documentID = doc.id, revision = doc.revision),
                )
                requestEdits(listOf(NotesEdit.UpsertNode(node)), "Insert assistant answer")
            }
        } else {
            insertText(text) != null
        }
    }

    suspend fun saveAssistantAnswerAsNote(text: String, title: String): String? {
        if (text.isBlank()) return null
        if (text.encodeToByteArray().size > 1_048_576) {
            saveFailure = NotesFailure("requestTooLarge", "message")
            return null
        }
        return try {
            val created = service.saveMessage(
                NotesSaveMessage(
                    text = text,
                    title = title.take(200),
                    notebookID = document?.notebookID,
                    documentID = null,
                ),
            )
            onLibraryInvalidated()
            created.id
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            saveFailure = error.toNotesFailure()
            null
        }
    }

    fun assistantContextText(): String? {
        val doc = document ?: return null
        val selected = currentPage?.elements?.filter { it.id in selectedElementIDs }.orEmpty()
        if (selected.isEmpty()) return null
        return selected.joinToString("\n") { resolveElementText(doc, it) }
            .take(12_000)
            .ifBlank { null }
    }

    fun assistantAttachmentIDs(): List<String> =
        currentPage?.elements
            ?.filter { it.id in selectedElementIDs }
            ?.mapNotNull { it.resourceID }
            .orEmpty()

    fun setMindMapSelectionNode(node: MindMapNode?) {
        // Reserved for the canvas selection; node identity itself lives in UI state.
        selectedMindMapNodeID = node?.id
    }

    var selectedMindMapNodeID: String? by mutableStateOf(null)

    fun nodeByID(id: String?): MindMapNode? =
        id?.let { value -> document?.nodes?.firstOrNull { it.id == value } }
}

public sealed interface NotesStopOutcome {
    public data class Flushed(public val documentID: String) : NotesStopOutcome
    public data class Kept(public val recovery: NotesPendingRecovery?) : NotesStopOutcome
}

public data class NotesRootStopReport(
    public val flushedDocumentIDs: List<String>,
    public val kept: List<NotesPendingRecovery>,
    public val timedOut: Boolean,
    /**
     * True only when every live session either flushed or has a durable
     * [kept] record. The caller MUST NOT retire the native root when this is
     * false; call [NotesWorkspaceSession.abortRootStop] instead. A thrown
     * recovery-store write is an even stronger refusal and produces no report.
     * The conservative default keeps an older caller/constructor from
     * accidentally authorizing retirement.
     */
    public val canRetire: Boolean = false,
)

public data class NotesResumeReport(
    public val savedDocumentIDs: List<String>,
    public val remaining: List<NotesPendingRecovery>,
    /** Real restore failures that were not cancellation; never silently dropped. */
    public val failures: List<NotesFailure> = emptyList(),
)
