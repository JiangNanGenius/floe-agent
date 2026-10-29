// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.state

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.notes.ImportedResource
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteDocumentSummary
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.Notebook
import com.floe.android.feature.notes.NotesApplyRequest
import com.floe.android.feature.notes.NotesCoverRequest
import com.floe.android.feature.notes.NotesCreateDocument
import com.floe.android.feature.notes.NotesDuplicateDocument
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesProtocol
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesCoverImageRequest
import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.api.NotesImageProbeRequest
import com.floe.android.feature.notes.ui.api.NotesImportKind
import com.floe.android.feature.notes.ui.api.NotesOfficeBlankKind
import com.floe.android.feature.notes.ui.api.NotesOfficeBlankOutcome
import com.floe.android.feature.notes.ui.api.NotesOfficeCreateBlankRequest
import com.floe.android.feature.notes.ui.api.NotesPdfHandle
import com.floe.android.feature.notes.ui.api.NotesPdfOpenOutcome
import com.floe.android.feature.notes.ui.api.NotesPdfOpenRequest
import com.floe.android.feature.notes.ui.api.NotesPickedFile
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesPortFailureException
import com.floe.android.feature.notes.ui.api.NotesWorkspaceScope
import com.floe.android.feature.notes.ui.presentation.NotesFailure
import com.floe.android.feature.notes.ui.presentation.NotesLibraryCounts
import com.floe.android.feature.notes.ui.presentation.NotesEditReceipt
import com.floe.android.feature.notes.ui.presentation.NotesLibraryFilter
import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import com.floe.android.feature.notes.ui.presentation.NotesSortOrder
import com.floe.android.feature.notes.ui.presentation.NotesTextPlan
import com.floe.android.feature.notes.ui.presentation.countsOf
import com.floe.android.feature.notes.ui.presentation.filterAndSortDocuments
import com.floe.android.feature.notes.ui.presentation.planTextInsertion
import com.floe.android.feature.notes.ui.presentation.toNotesFailure
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal enum class NotesLibraryNotice {
    IMPORTED,
    IMPORTED_PDF,
    COVER_UPDATED,
    NOTEBOOK_CREATED,
    TRASH_UPDATED,
}

/**
 * Library projection over the real Notes authority. Every mutation is an
 * explicit service call; the library itself is a persisted native store, not a
 * chat-owned or in-memory collection.
 */
@Stable
internal class NotesLibraryController(
    private val service: NotesService,
    private val ports: NotesHostPorts,
    private val resources: NotesResourceAccess,
    private val scope: CoroutineScope,
    private val onOpenDocument: (documentID: String, pageID: String?) -> Unit,
    private val persistWorkspace: () -> Unit = {},
) {
    var loading by mutableStateOf(true)
        private set
    var refreshing by mutableStateOf(false)
        private set
    var failure by mutableStateOf<NotesFailure?>(null)
        private set
    var notice by mutableStateOf<NotesLibraryNotice?>(null)
        private set
    var busy by mutableStateOf(false)
        private set

    var documents by mutableStateOf<List<NoteDocumentSummary>>(emptyList())
        private set
    var notebooks by mutableStateOf<List<Notebook>>(emptyList())
        private set
    var recentDocumentIDs by mutableStateOf<List<String>>(emptyList())
        private set
    var counts by mutableStateOf(NotesLibraryCounts())
        private set

    var query by mutableStateOf("")
        private set
    var searchResults by mutableStateOf<List<NoteDocumentSummary>?>(null)
        private set
    var searching by mutableStateOf(false)
        private set
    var filter by mutableStateOf(NotesLibraryFilter.RECENT)
        private set
    var sort by mutableStateOf(NotesSortOrder.UPDATED)
        private set
    var grid by mutableStateOf(true)
        private set
    var selectedNotebookID by mutableStateOf<String?>(null)
        private set

    var coverBytes by mutableStateOf<Map<String, ByteArray>>(emptyMap())
        private set
    var coverFailures by mutableStateOf<Set<String>>(emptySet())
        private set

    private var searchJob: Job? = null
    private var coverJob: Job? = null
    private var disposed = false

    fun visibleDocuments(): List<NoteDocumentSummary> = filterAndSortDocuments(
        summaries = documents,
        recentDocumentIDs = recentDocumentIDs,
        filter = filter,
        notebookID = selectedNotebookID,
        sort = sort,
        query = query,
        searchResults = searchResults,
    )

    suspend fun load(initial: Boolean = false) {
        if (disposed) return
        if (initial) loading = true else refreshing = true
        failure = null
        try {
            val summary = service.library()
            val page = service.documents(includeTrash = true, limit = 500)
            val books = service.notebooks()
            documents = page.documents
            notebooks = books
            recentDocumentIDs = summary.recent.map { it.id }
            counts = countsOf(page.documents).copy(notebooks = books.size)
            if (selectedNotebookID != null && books.none { it.id == selectedNotebookID }) {
                selectedNotebookID = null
            }
            runCatching { service.collectDeletedResources() }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
        } finally {
            loading = false
            refreshing = false
        }
    }

    fun refreshSoon() {
        scope.launch { load(initial = false) }
    }

    fun applyFilter(value: NotesLibraryFilter) {
        filter = value
        if (query.isBlank()) searchResults = null
        persistWorkspace()
    }

    fun applySort(value: NotesSortOrder) {
        sort = value
        persistWorkspace()
    }

    fun toggleGrid() {
        grid = !grid
        persistWorkspace()
    }

    fun applyGrid(value: Boolean) {
        grid = value
        persistWorkspace()
    }

    fun selectNotebook(notebookID: String?) {
        selectedNotebookID = notebookID
        persistWorkspace()
    }

    /** Restore the device-local library presentation preferences (not authority). */
    fun restore(preferences: com.floe.android.feature.notes.ui.presentation.NotesWorkspacePreferences) {
        grid = preferences.grid
        filter = NotesLibraryFilter.fromKey(preferences.filter)
        sort = NotesSortOrder.fromKey(preferences.sort)
        selectedNotebookID = preferences.selectedNotebookID
    }

    fun applySearch(value: String) {
        query = value
        searchJob?.cancel()
        if (value.isBlank()) {
            searchResults = null
            searching = false
            return
        }
        searchJob = scope.launch {
            delay(260)
            searching = true
            try {
                searchResults = service.search(value.trim(), limit = 100)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = error.toNotesFailure()
            } finally {
                searching = false
            }
        }
    }

    fun clearNotice() {
        notice = null
    }

    fun clearFailure() {
        failure = null
    }

    /* ------------------------------ create -------------------------------- */

    suspend fun createDocument(
        kind: NoteDocumentKind,
        title: String,
        notebookID: String? = selectedNotebookID,
    ): NoteDocument? = perform {
        val created = service.createDocument(
            NotesCreateDocument(
                kind = kind,
                title = title,
                notebookID = notebookID,
                documentID = UUID.randomUUID().toString(),
            ),
        )
        load(initial = false)
        onOpenDocument(created.id, null)
        created
    }

    suspend fun createNotebook(title: String): Notebook? = perform {
        val created = service.createNotebook(title)
        load(initial = false)
        notice = NotesLibraryNotice.NOTEBOOK_CREATED
        created
    }

    suspend fun renameNotebook(notebookID: String, title: String): Boolean {
        return try {
            service.renameNotebook(notebookID, title)
            load(initial = false)
            true
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            false
        }
    }

    suspend fun createOfficeBlank(kind: NotesOfficeBlankKind, title: String): Boolean {
        busy = true
        failure = null
        var picked: NotesPickedFile? = null
        // Stable phase codes keep the exact failed step observable in the
        // create sheet and its typed UI readback. Only stable failure codes
        // travel in detail; no path, byte, model or note content is added.
        fun phaseFailed(code: String, cause: Throwable? = null, underlying: String? = null) {
            failure = NotesFailure(code, underlying ?: cause?.toNotesFailure()?.code)
        }
        return try {
            val outcome = try {
                ports.office.createBlank(NotesOfficeCreateBlankRequest(title, kind))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                phaseFailed("officeCreatePrepareFailed", cause = error)
                return false
            }
            when (outcome) {
                is NotesOfficeBlankOutcome.Created -> {
                    picked = outcome.file
                    val imported = try {
                        importPickedAsResource(outcome.file)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (error: Throwable) {
                        phaseFailed("officeCreateResourceFailed", cause = error)
                        return false
                    }
                    val created = try {
                        service.createDocument(
                            NotesCreateDocument(
                                kind = NoteDocumentKind.OFFICE,
                                title = title,
                                notebookID = selectedNotebookID,
                                documentID = UUID.randomUUID().toString(),
                                resourceID = imported.resourceID,
                                fileName = outcome.file.fileName,
                            ),
                        )
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (error: Throwable) {
                        phaseFailed("officeCreateDocumentFailed", cause = error)
                        return false
                    }
                    load(initial = false)
                    onOpenDocument(created.id, null)
                    true
                }
                is NotesOfficeBlankOutcome.Unavailable -> {
                    failure = outcome.failure.toNotesFailure()
                    false
                }
                is NotesOfficeBlankOutcome.Failed -> {
                    phaseFailed("officeCreatePrepareFailed", underlying = outcome.failure.code)
                    false
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            false
        } finally {
            picked?.let { runCatching { it.close() } }
            busy = false
        }
    }

    /* ------------------------------ mutate -------------------------------- */

    suspend fun rename(summary: NoteDocumentSummary, title: String): Boolean =
        applySummaryEdit(summary, listOf(NotesEdit.Rename(title)), "Rename note")

    suspend fun setFavorite(summary: NoteDocumentSummary, value: Boolean): Boolean =
        applySummaryEdit(summary, listOf(NotesEdit.Favorite(value)), "Favorite")

    suspend fun setTags(summary: NoteDocumentSummary, tags: List<String>): Boolean =
        applySummaryEdit(summary, listOf(NotesEdit.Tags(tags)), "Tags")

    suspend fun moveToNotebook(summary: NoteDocumentSummary, notebookID: String?): Boolean =
        applySummaryEdit(summary, listOf(NotesEdit.MoveToNotebook(notebookID)), "Move note")

    suspend fun trash(summary: NoteDocumentSummary): Boolean {
        return try {
            service.setTrashed(summary.id, summary.revision, true)
            notice = NotesLibraryNotice.TRASH_UPDATED
            load(initial = false)
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            false
        }
    }

    suspend fun restore(summary: NoteDocumentSummary): Boolean {
        return try {
            service.setTrashed(summary.id, summary.revision, false)
            notice = NotesLibraryNotice.TRASH_UPDATED
            load(initial = false)
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            false
        }
    }

    suspend fun deletePermanently(summary: NoteDocumentSummary): Boolean {
        return try {
            service.deletePermanently(summary.id, summary.revision)
            ports.presentation.forgetDocument(summary.id)
            load(initial = false)
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            false
        }
    }

    suspend fun duplicate(summary: NoteDocumentSummary): NoteDocument? = perform {
        val copy = service.duplicateDocument(
            NotesDuplicateDocument(
                sourceDocumentID = summary.id,
                newDocumentID = UUID.randomUUID().toString(),
                notebookID = summary.notebookID,
            ),
        )
        load(initial = false)
        copy
    }

    private suspend fun applySummaryEdit(
        summary: NoteDocumentSummary,
        edits: List<NotesEdit>,
        title: String,
    ): Boolean {
        return try {
            val updated = service.apply(
                NotesApplyRequest(
                    documentID = summary.id,
                    expectedRevision = summary.revision,
                    title = title,
                    edits = edits,
                    requestID = UUID.randomUUID().toString(),
                ),
            )
            replaceSummary(updated)
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            if (error is NotesException && error.isConflict) {
                scope.launch { load(initial = false) }
            }
            false
        }
    }

    private fun replaceSummary(document: NoteDocument) {
        documents = documents.map { summary ->
            if (summary.id != document.id) summary else summary.copy(
                title = document.title,
                revision = document.revision,
                notebookID = document.notebookID,
                tags = document.tags,
                isFavorite = document.isFavorite,
                updatedAt = document.updatedAt,
                deletedAt = document.deletedAt,
                coverResourceID = document.coverResourceID,
                coverRevision = document.coverRevision,
            )
        }
        counts = countsOf(documents).copy(notebooks = notebooks.size)
    }

    /* ------------------------------- cover -------------------------------- */

    fun ensureCover(summary: NoteDocumentSummary) {
        val resourceID = summary.coverResourceID ?: return
        val key = coverKey(summary, resourceID)
        if (coverBytes.containsKey(key) || key in coverFailures) return
        coverJob = scope.launch {
            try {
                val bytes = resources.readAll(resourceID, maxBytes = 8L * 1024L * 1024L)
                coverBytes = coverBytes + (key to bytes)
                coverFailures = coverFailures - key
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                coverFailures = coverFailures + key
            }
        }
    }

    fun coverFor(summary: NoteDocumentSummary): ByteArray? =
        summary.coverResourceID?.let { coverBytes[coverKey(summary, it)] }

    private fun coverKey(summary: NoteDocumentSummary, resourceID: String): String =
        "${summary.id}:${summary.coverRevision ?: 0}:$resourceID"

    suspend fun setCover(summary: NoteDocumentSummary): Boolean {
        busy = true
        failure = null
        var picked: NotesPickedFile? = null
        return try {
            val selected = ports.exchange.pickFile(setOf(NotesImportKind.IMAGE)) ?: return false
            picked = selected
            val prepared = ports.media.prepareCoverImage(
                NotesCoverImageRequest(
                    fileName = selected.fileName,
                    mediaType = selected.mediaType,
                    read = selected.read,
                ),
            )
            val imported = resources.importBytes(
                fileName = prepared.fileName,
                mediaType = prepared.mediaType,
                bytes = prepared.bytes,
            )
            val fresh = service.documentSummary(summary.id)
            val cover = service.cover(summary.id)
            service.applyCover(
                NotesCoverRequest(
                    documentID = summary.id,
                    expectedRevision = fresh.revision,
                    expectedCoverRevision = cover.coverRevision,
                    resourceID = imported.resourceID,
                ),
            )
            notice = NotesLibraryNotice.COVER_UPDATED
            load(initial = false)
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            false
        } finally {
            picked?.let { runCatching { it.close() } }
            busy = false
        }
    }

    suspend fun restoreAutomaticCover(summary: NoteDocumentSummary): Boolean {
        return try {
            val fresh = service.documentSummary(summary.id)
            val cover = service.cover(summary.id)
            service.applyCover(
                NotesCoverRequest(
                    documentID = summary.id,
                    expectedRevision = fresh.revision,
                    expectedCoverRevision = cover.coverRevision,
                    resourceID = null,
                ),
            )
            load(initial = false)
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            false
        }
    }

    /* -------------------------------- import ------------------------------ */

    suspend fun importAny(notebookID: String? = selectedNotebookID): Boolean {
        var picked: NotesPickedFile? = null
        busy = true
        failure = null
        return try {
            val selected = ports.exchange.pickFile(
                setOf(
                    NotesImportKind.PDF,
                    NotesImportKind.IMAGE,
                    NotesImportKind.TEXT,
                    NotesImportKind.OFFICE,
                    NotesImportKind.ENGINEERING,
                    NotesImportKind.FILE,
                    NotesImportKind.ARCHIVE,
                ),
            ) ?: return false
            picked = selected
            importPicked(selected, notebookID)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            false
        } finally {
            picked?.let { runCatching { it.close() } }
            busy = false
        }
    }

    /**
     * Import one file that the user explicitly chose in the real Floe task
     * workspace chooser.
     *
     * The workspace port owns the read handle (bounded chunks, native owner
     * fence, idempotent close). The SAME [importPicked] pipeline copies the
     * bytes into the independent Notes store; a workspace path or URI never
     * enters Notes. The original workspace file is never modified.
     */
    suspend fun importWorkspaceFile(
        scope: NotesWorkspaceScope,
        relativePath: String,
        notebookID: String? = selectedNotebookID,
    ): Boolean {
        val port = ports.workspaceImport
        if (port == null) {
            failure = NotesFailure(NotesPortFailure.UNAVAILABLE, "workspaceImportUnavailable")
            return false
        }
        var picked: NotesPickedFile? = null
        busy = true
        failure = null
        return try {
            picked = port.open(scope, relativePath)
            importPicked(picked, notebookID)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            false
        } finally {
            picked?.let { runCatching { it.close() } }
            busy = false
        }
    }

    suspend fun importKind(kind: NotesImportKind, notebookID: String? = selectedNotebookID): Boolean {
        var picked: NotesPickedFile? = null
        busy = true
        failure = null
        return try {
            val selected = ports.exchange.pickFile(setOf(kind)) ?: return false
            picked = selected
            importPicked(selected, notebookID, forcedKind = kind)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            false
        } finally {
            picked?.let { runCatching { it.close() } }
            busy = false
        }
    }

    private suspend fun importPicked(
        picked: NotesPickedFile,
        notebookID: String?,
        forcedKind: NotesImportKind? = null,
    ): Boolean {
        if (picked.byteCount <= 0L) throw NotesException("invalidPayload", "emptyFile")
        val kind = forcedKind ?: inferKind(picked)
        val title = picked.fileName.substringBeforeLast('.', picked.fileName).ifBlank { picked.fileName }
        when (kind) {
            NotesImportKind.ARCHIVE -> {
                val session = service.beginArchiveImport(picked.byteCount)
                var committed = false
                try {
                    var offset = 0L
                    while (offset < picked.byteCount) {
                        val request = minOf(session.chunkBytes.toLong(), picked.byteCount - offset)
                            .toInt().coerceAtLeast(1)
                        val bytes = picked.read(offset, request)
                        if (bytes.isEmpty()) throw NotesException("invalidPayload", "shortRead")
                        session.append(bytes)
                        offset += bytes.size
                    }
                    val imported = session.commit(notebookID)
                    committed = true
                    notice = NotesLibraryNotice.IMPORTED
                    load(initial = false)
                    if (imported.size == 1) onOpenDocument(imported.first().id, null)
                    return true
                } finally {
                    if (!committed) runCatching { session.abort() }
                }
            }
            NotesImportKind.PDF -> return importPdf(picked, title, notebookID)
            NotesImportKind.IMAGE -> return importImage(picked, title, notebookID)
            NotesImportKind.TEXT -> return importText(picked, title, notebookID)
            NotesImportKind.OFFICE, NotesImportKind.ENGINEERING, NotesImportKind.FILE -> {
                val imported = importPickedAsResource(picked)
                val documentKind = if (kind == NotesImportKind.OFFICE) {
                    NoteDocumentKind.OFFICE
                } else {
                    NoteDocumentKind.ENGINEERING
                }
                val created = service.createDocument(
                    NotesCreateDocument(
                        kind = documentKind,
                        title = title,
                        notebookID = notebookID,
                        documentID = UUID.randomUUID().toString(),
                        resourceID = imported.resourceID,
                        fileName = picked.fileName,
                    ),
                )
                notice = NotesLibraryNotice.IMPORTED
                load(initial = false)
                onOpenDocument(created.id, null)
                return true
            }
        }
        return false
    }

    private fun inferKind(picked: NotesPickedFile): NotesImportKind {
        val extension = picked.fileName.substringAfterLast('.', "").lowercase()
        val media = picked.mediaType.lowercase()
        return when {
            extension == "floenote" || media.contains("floenote") -> NotesImportKind.ARCHIVE
            media == "application/pdf" || extension == "pdf" -> NotesImportKind.PDF
            media.startsWith("image/") -> NotesImportKind.IMAGE
            extension in setOf("txt", "text", "md", "markdown") || media.startsWith("text/") ->
                NotesImportKind.TEXT
            extension in setOf("doc", "docx", "odt", "rtf", "xls", "xlsx", "ods", "ppt", "pptx", "odp") ->
                NotesImportKind.OFFICE
            else -> NotesImportKind.FILE
        }
    }

    private suspend fun importPickedAsResource(picked: NotesPickedFile): ImportedResource =
        resources.import(
            fileName = picked.fileName,
            mediaType = picked.mediaType.ifBlank { "application/octet-stream" },
            byteCount = picked.byteCount,
            read = picked.read,
        )

    private suspend fun importPdf(
        picked: NotesPickedFile,
        title: String,
        notebookID: String?,
    ): Boolean {
        val resource = importPickedAsResource(picked)
        val record = service.resourceMetadata(resource.resourceID)
        val handle: NotesPdfHandle = when (val outcome = ports.media.openPdf(
            NotesPdfOpenRequest(
                documentID = "",
                resourceID = resource.resourceID,
                sha256 = record.hash,
                byteCount = record.byteCount,
                fileName = picked.fileName,
                mediaType = record.mediaType,
                read = resources.reader(),
            ),
        )) {
            is NotesPdfOpenOutcome.Opened -> outcome.handle
            NotesPdfOpenOutcome.PasswordRequired ->
                throw NotesException("passwordRequired", "passwordProtected")
            is NotesPdfOpenOutcome.Unavailable ->
                throw NotesPortFailureException(outcome.failure)
            is NotesPdfOpenOutcome.Failed ->
                throw NotesPortFailureException(outcome.failure)
        }
        try {
            if (handle.pageCount <= 0) throw NotesException("invalidDocument", "emptyPdf")
            val document = service.createDocument(
                NotesCreateDocument(
                    kind = NoteDocumentKind.NOTEBOOK,
                    title = title,
                    notebookID = notebookID,
                    documentID = UUID.randomUUID().toString(),
                ),
            )
            var revision = document.revision
            var current = document
            val pages = (0 until handle.pageCount).map { index ->
                val size = handle.pageSize(index)
                NotePage(
                    id = UUID.randomUUID().toString(),
                    width = (size?.widthPt ?: 612f).toDouble().coerceIn(1.0, 16_384.0),
                    height = (size?.heightPt ?: 792f).toDouble().coerceIn(1.0, 16_384.0),
                    backgroundResourceID = resource.resourceID,
                    pdfPageIndex = index,
                )
            }
            // A new notebook starts with one native placeholder page. Replace
            // it with the first PDF page; inserting the PDF after it would
            // leave an empty cover and shift every imported page by one.
            importedNotebookPageEdits(
                placeholderPageID = current.pages.firstOrNull()?.id,
                pages = pages,
            ).chunked(40).forEach { edits ->
                current = service.apply(
                    NotesApplyRequest(
                        documentID = document.id,
                        expectedRevision = revision,
                        title = "Import PDF",
                        edits = edits,
                        requestID = UUID.randomUUID().toString(),
                    ),
                )
                revision = current.revision
            }
            notice = NotesLibraryNotice.IMPORTED_PDF
            load(initial = false)
            onOpenDocument(document.id, null)
            return true
        } finally {
            runCatching { handle.close() }
        }
    }

    private suspend fun importImage(
        picked: NotesPickedFile,
        title: String,
        notebookID: String?,
    ): Boolean {
        val info = ports.media.probeImage(
            NotesImageProbeRequest(
                fileName = picked.fileName,
                mediaType = picked.mediaType,
                byteCount = picked.byteCount,
                read = picked.read,
            ),
        ) ?: throw NotesException("unsupportedAction", "imageFormat")
        // Probe consumed no service resource; import the exact original bytes.
        val resource = importPickedAsResource(picked)
        val width = 768.0
        val height = (width * info.height.toDouble() / info.width.toDouble().coerceAtLeast(1.0))
            .coerceIn(1.0, 16_384.0)
        val document = service.createDocument(
            NotesCreateDocument(
                kind = NoteDocumentKind.NOTEBOOK,
                title = title,
                notebookID = notebookID,
                documentID = UUID.randomUUID().toString(),
            ),
        )
        val page = NotePage(
            id = UUID.randomUUID().toString(),
            width = width,
            height = height,
            backgroundResourceID = resource.resourceID,
        )
        val importedDocument = service.apply(
            NotesApplyRequest(
                documentID = document.id,
                expectedRevision = document.revision,
                title = "Import image",
                edits = importedNotebookPageEdits(document.pages.firstOrNull()?.id, listOf(page)),
                requestID = UUID.randomUUID().toString(),
            ),
        )
        notice = NotesLibraryNotice.IMPORTED
        load(initial = false)
        onOpenDocument(document.id, importedDocument.pages.firstOrNull()?.id)
        return true
    }

    /**
     * Import a text file into a new notebook.
     *
     * The page-aware layout plan keeps every element/page and its geometry and
     * is committed by one [com.floe.android.feature.notes.NotesService.applyAtomically]
     * call: one native revision, one undo group and one durable receipt, even
     * when the serialized plan is larger than the 64 KiB bridge request. A
     * failure (including typed `requestTooLarge`) keeps the WHOLE plan in the
     * durable recovery store, never a silently applied prefix; strict UTF-8
     * and short-read refusal above are unchanged.
     */
    private suspend fun importText(
        picked: NotesPickedFile,
        title: String,
        notebookID: String?,
    ): Boolean {
        val bytes = readPicked(picked, maxBytes = 2L * 1024L * 1024L)
        val text = decodeUtf8Strict(bytes)
        if (text.isBlank()) throw NotesException("invalidPayload", "emptyFile")
        val document = service.createDocument(
            NotesCreateDocument(
                kind = NoteDocumentKind.NOTEBOOK,
                title = title,
                notebookID = notebookID,
                documentID = UUID.randomUUID().toString(),
            ),
        )
        val plan: NotesTextPlan = planTextInsertion(
            document = document,
            pageID = document.pages.firstOrNull()?.id,
            text = text,
            markdown = picked.fileName.substringAfterLast('.', "").lowercase() == "md",
        )
        val requestID = UUID.randomUUID().toString()
        // The page-aware plan is multi-element/multi-page; it must commit as
        // ONE native transaction (one revision, one undo). The host adapter
        // stages the exact serialized edit array in bounded chunks when it is
        // larger than the 64 KiB bridge request; an oversize plan fails with
        // typed `requestTooLarge` and keeps the whole plan below, never a
        // silently committed prefix.
        try {
            service.applyAtomically(
                NotesApplyRequest(
                    documentID = document.id,
                    expectedRevision = document.revision,
                    title = "Import text",
                    edits = plan.edits,
                    requestID = "$requestID${NotesEditReceipt.suffix(plan.edits)}",
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val failure = error.toNotesFailure()
            try {
                ports.recovery.put(
                    NotesPendingRecovery(
                        documentID = document.id,
                        documentKind = document.kind.wire,
                        documentTitle = document.title,
                        baseRevision = document.revision,
                        requestTitle = "Import text",
                        edits = plan.edits,
                        reasonCode = failure.code,
                        createdAt = System.currentTimeMillis(),
                        requestID = requestID,
                        inkDrafts = emptyMap(),
                    ),
                )
            } catch (storage: Throwable) {
                // Keep the original apply failure; the storage failure is
                // disclosed as suppressed and the caller sees a real error.
                error.addSuppressed(storage)
            }
            throw error
        }
        ports.recovery.remove(document.id)
        notice = NotesLibraryNotice.IMPORTED
        load(initial = false)
        onOpenDocument(document.id, null)
        return true
    }

    /** Strict UTF-8: malformed input is a typed refusal, never U+FFFD loss. */
    private fun decodeUtf8Strict(bytes: ByteArray): String {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) {
            throw NotesException("invalidPayload", "invalidUtf8")
        }
    }

    private suspend fun readPicked(picked: NotesPickedFile, maxBytes: Long): ByteArray {
        if (picked.byteCount > maxBytes) throw NotesException("requestTooLarge", "importFile")
        val output = java.io.ByteArrayOutputStream()
        var offset = 0L
        val total = picked.byteCount
        while (offset < total) {
            val request = minOf(64 * 1024L, total - offset).toInt().coerceAtLeast(1)
            val bytes = picked.read(offset, request)
            // A short/empty read must never become a silently truncated import.
            if (bytes.isEmpty()) throw NotesException("invalidPayload", "shortRead")
            output.write(bytes)
            offset += bytes.size
        }
        return output.toByteArray()
    }

    private suspend fun <T> perform(block: suspend () -> T?): T? {
        busy = true
        failure = null
        return try {
            block()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            failure = error.toNotesFailure()
            null
        } finally {
            busy = false
        }
    }

    fun dispose() {
        disposed = true
        searchJob?.cancel()
        coverJob?.cancel()
    }
}
