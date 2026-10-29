// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.state

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NoteSourceSpace
import com.floe.android.feature.notes.NoteSourceReference
import com.floe.android.feature.notes.NotesEventBatch
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.MindMapAttachment
import com.floe.android.feature.notes.MindMapAttachmentKind
import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.api.NotesImportKind
import com.floe.android.feature.notes.ui.api.NotesOfficeIndexOutcome
import com.floe.android.feature.notes.ui.api.NotesOfficeIndexingPort
import com.floe.android.feature.notes.ui.api.NotesPickedFile
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.presentation.NotesFailure
import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import com.floe.android.feature.notes.ui.presentation.toNotesFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

internal data class NotesLinkLocation(
    val documentID: String,
    val pageID: String?,
    val title: String,
)

internal enum class NotesWorkspaceAlert {
    CLOSE_TAB_BLOCKED,
    NOT_FOUND,
    DOCUMENT_DELETED,
}

internal enum class NotesOfficeActionResult { SAVED, NO_CHANGES, UNAVAILABLE, FAILED }

internal enum class NotesAttachmentOpenResult { OPENED, UNAVAILABLE, FAILED }

/**
 * Workspace-level coordination: tab/session ownership, active document,
 * linked-map return stack, native change polling and source navigation.
 * Sessions are keyed by document id; a late native result can only update the
 * session that issued it, never the currently visible document.
 */
@Stable
internal class NotesWorkspaceController(
    private val service: NotesService,
    val ports: NotesHostPorts,
    private val scope: CoroutineScope,
    private val generation: () -> Long,
    private val fenced: () -> Boolean,
) {
    internal val resources = NotesResourceAccess(service)

    internal val library = NotesLibraryController(
        service = service,
        ports = ports,
        resources = resources,
        scope = scope,
        onOpenDocument = { documentID, pageID -> openDocument(documentID, pageID) },
        persistWorkspace = { persist() },
    )

    var tabs by mutableStateOf<List<String>>(emptyList())
        private set
    var activeDocumentID by mutableStateOf<String?>(null)
        private set
    var navigation by mutableStateOf<List<NotesLinkLocation>>(emptyList())
        private set
    var lastFailure by mutableStateOf<NotesFailure?>(null)
        private set
    var alert by mutableStateOf<NotesWorkspaceAlert?>(null)
        private set

    /**
     * Typed outcome of the LAST Office full-text index attempt (App may mount
     * a concise, truthful notice from it; the editor itself never claims an
     * index it does not have).
     */
    var officeIndexOutcome by mutableStateOf<NotesOfficeIndexOutcome?>(null)
        private set
    var officeIndexBusy by mutableStateOf(false)
        private set

    /**
     * Snapshot-observable: `activeSession` is read by the workspace composable,
     * and inserting a session must invalidate that read even when
     * `activeDocumentID` already equals the opened id (cold reopen restores the
     * last active id before the session exists). A plain map leaves the restored
     * document invisible behind the "Select a Note" placeholder.
     */
    private val sessions = mutableStateMapOf<String, NotesDocumentSession>()
    private val officeIndexJobs = mutableMapOf<String, Job>()
    private var started = false
    private var eventCursor = 0L
    private var eventJob: Job? = null

    val activeSession: NotesDocumentSession?
        get() = activeDocumentID?.let { sessions[it] }

    fun session(documentID: String): NotesDocumentSession? = sessions[documentID]

    fun tabTitle(documentID: String): String =
        sessions[documentID]?.document?.title
            ?: library.documents.firstOrNull { it.id == documentID }?.title
            ?: ""

    fun start() {
        if (started) return
        started = true
        val preferences = ports.presentation.loadWorkspace()
        library.restore(preferences)
        tabs = preferences.openDocumentIDs
        activeDocumentID = preferences.activeDocumentID
        scope.launch {
            library.load(initial = true)
            val available = library.documents.filter { it.deletedAt == null }.map { it.id }.toSet()
            tabs = tabs.filter { it in available }
            val target = activeDocumentID?.takeIf { it in available }
            activeDocumentID = target
            target?.let { openDocument(it, null) }
            persist()
            startEvents()
        }
    }

    fun openDocument(documentID: String, pageID: String? = null) {
        if (library.documents.any { it.id == documentID && it.deletedAt != null }) {
            alert = NotesWorkspaceAlert.DOCUMENT_DELETED
            return
        }
        val session = sessions.getOrPut(documentID) {
            NotesDocumentSession(
                documentID = documentID,
                service = service,
                ports = ports,
                resources = resources,
                scope = scope,
                generation = generation,
                fenced = fenced,
                onLibraryInvalidated = { library.refreshSoon() },
            )
        }
        if (pageID != null) session.setActivePage(pageID)
        if (documentID !in tabs) tabs = tabs + documentID
        activeDocumentID = documentID
        persist()
        if (session.document == null) {
            scope.launch {
                session.load(pageID)
                if (session.loadFailure?.code == "notFound") {
                    alert = NotesWorkspaceAlert.NOT_FOUND
                    removeTabAfterFailure(documentID)
                } else {
                    // Opening an imported Office note is the initial-import
                    // moment: its body text has never been indexed. Only the
                    // actual saved resource is read, and the port is a no-op
                    // when the cache already matches it.
                    scheduleOfficeIndex(session)
                }
                persist()
            }
        } else if (pageID != null) {
            session.setActivePage(pageID)
        }
    }

    fun activateTab(documentID: String) {
        if (sessions[documentID] == null) {
            openDocument(documentID, null)
            return
        }
        activeDocumentID = documentID
        persist()
    }

    /** Returns false when the tab was kept because its pending edits didn't save. */
    suspend fun closeTab(documentID: String): Boolean {
        val session = sessions[documentID] ?: return true
        if (session.assistant.isOpen) session.assistant.close()
        // Closing a tab must also commit queued ink, not only text edits.
        val outcome = session.prepareForStop(6_000L)
        if (outcome is NotesStopOutcome.Kept) {
            lastFailure = NotesFailure(outcome.recovery?.reasonCode ?: "storageUnavailable")
            alert = NotesWorkspaceAlert.CLOSE_TAB_BLOCKED
            return false
        }
        session.dispose()
        sessions.remove(documentID)
        tabs = tabs - documentID
        if (activeDocumentID == documentID) {
            activeDocumentID = tabs.lastOrNull()
        }
        persist()
        return true
    }

    fun clearActiveDocument() {
        activeDocumentID = null
        persist()
    }

    fun canGoBack(): Boolean = activeSession?.assistant?.isOpen == true ||
        navigation.isNotEmpty() ||
        activeDocumentID != null

    fun goBack(): Boolean {
        val session = activeSession
        if (session != null && session.assistant.isOpen) {
            session.assistant.close()
            // Keep the compact assistant sheet's visibility and the toolbar
            // tint on the same state. System Back still only closes the
            // assistant and leaves the SAME editor body mounted (the passed
            // candidate-05 behavior).
            session.assistantOpen = false
            return true
        }
        if (navigation.isNotEmpty()) {
            val target = navigation.last()
            navigation = navigation.dropLast(1)
            openDocument(target.documentID, target.pageID)
            return true
        }
        if (activeDocumentID != null) {
            clearActiveDocument()
            return true
        }
        return false
    }

    fun openLinkedMap(parentDocumentID: String, parentPageID: String?, map: NoteDocument) {
        val parent = sessions[parentDocumentID]?.document
        navigation = navigation + NotesLinkLocation(
            documentID = parentDocumentID,
            pageID = parentPageID,
            title = parent?.title.orEmpty(),
        )
        openDocument(map.id, null)
    }

    /**
     * Suspend through the existing Office viewer/save-copy host. A saved copy
     * is imported as an immutable resource and applied with
     * ReplaceOfficeResource; the preview is cached separately. The resource
     * identity written to the note is the foundation resource UUID, never the
     * CAS hash.
     */
    suspend fun editActiveOfficeDocument(): NotesOfficeActionResult {
        val session = activeSession ?: return NotesOfficeActionResult.FAILED
        val document = session.document ?: return NotesOfficeActionResult.FAILED
        val resourceID = document.officeResourceID ?: return NotesOfficeActionResult.UNAVAILABLE
        var picked: NotesPickedFile? = null
        var preview: com.floe.android.feature.notes.ui.api.NotesExportedStream? = null
        return try {
            val record = service.resourceMetadata(resourceID)
            when (val outcome = ports.office.edit(
                com.floe.android.feature.notes.ui.api.NotesOfficeEditRequest(
                    documentID = document.id,
                    revision = document.revision,
                    resourceID = resourceID,
                    sha256 = record.hash,
                    byteCount = record.byteCount,
                    fileName = document.officeFileName ?: record.fileName,
                    mediaType = record.mediaType,
                    read = resources.reader(),
                ),
            )) {
                is com.floe.android.feature.notes.ui.api.NotesOfficeEditOutcome.Saved -> {
                    preview = outcome.preview
                    val saved = outcome.file
                    if (saved == null) {
                        NotesOfficeActionResult.NO_CHANGES
                    } else {
                        picked = saved
                        val imported = resources.import(
                            fileName = saved.fileName,
                            mediaType = saved.mediaType,
                            byteCount = saved.byteCount,
                            read = saved.read,
                        )
                        val accepted = session.requestEdits(
                            listOf(com.floe.android.feature.notes.NotesEdit.ReplaceOfficeResource(imported.resourceID)),
                            "Replace office file",
                        )
                        val flush = if (accepted) session.flush() else null
                        if (!accepted || (flush != NotesFlushResult.Saved && flush != NotesFlushResult.NoPending)) {
                            NotesOfficeActionResult.FAILED
                        } else {
                            val previewStream = preview
                            if (previewStream != null) {
                                runCatching {
                                    val previewResource = resources.import(
                                        fileName = previewStream.fileName,
                                        mediaType = previewStream.mediaType,
                                        byteCount = previewStream.totalBytes,
                                        read = previewStream.read,
                                    )
                                    service.cacheOfficePreview(
                                        documentID = document.id,
                                        sourceResourceID = imported.resourceID,
                                        previewResourceID = previewResource.resourceID,
                                        expectedRevision = session.currentRevision,
                                    )
                                }
                            }
                            // The note now references NEW bytes: rebuild the
                            // search index for exactly that resource (a real
                            // save is never undone by an index failure).
                            indexOfficeResource(
                                documentID = document.id,
                                sourceResourceID = imported.resourceID,
                                revision = session.currentRevision,
                            )
                            library.refreshSoon()
                            NotesOfficeActionResult.SAVED
                        }
                    }
                }
                com.floe.android.feature.notes.ui.api.NotesOfficeEditOutcome.ClosedWithoutChanges ->
                    NotesOfficeActionResult.NO_CHANGES
                is com.floe.android.feature.notes.ui.api.NotesOfficeEditOutcome.Unavailable -> {
                    lastFailure = outcome.failure.toNotesFailure()
                    NotesOfficeActionResult.UNAVAILABLE
                }
                is com.floe.android.feature.notes.ui.api.NotesOfficeEditOutcome.Failed -> {
                    lastFailure = outcome.failure.toNotesFailure()
                    NotesOfficeActionResult.FAILED
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            NotesOfficeActionResult.FAILED
        } finally {
            picked?.let { runCatching { it.close() } }
            preview?.let { runCatching { it.close() } }
        }
    }

    suspend fun replaceActiveOfficeFile(): Boolean {
        val session = activeSession ?: return false
        val document = session.document ?: return false
        if (document.kind != com.floe.android.feature.notes.NoteDocumentKind.OFFICE) return false
        var picked: NotesPickedFile? = null
        return try {
            val selected = ports.exchange.pickFile(setOf(NotesImportKind.OFFICE, NotesImportKind.FILE))
                ?: return false
            picked = selected
            val imported = resources.import(
                fileName = selected.fileName,
                mediaType = selected.mediaType,
                byteCount = selected.byteCount,
                read = selected.read,
            )
            val accepted = session.requestEdits(
                listOf(
                    com.floe.android.feature.notes.NotesEdit.ReplaceOfficeResource(imported.resourceID),
                ),
                "Replace office file",
            )
            val result = if (accepted) session.flush() else null
            if (!accepted || (result != NotesFlushResult.Saved && result != NotesFlushResult.NoPending)) {
                false
            } else {
                // A replaced file keeps the same immutable-resource model:
                // index only the NEW resource at the revision that actually
                // landed. An index failure cannot undo the user's save.
                indexOfficeResource(
                    documentID = document.id,
                    sourceResourceID = imported.resourceID,
                    revision = session.currentRevision,
                )
                library.refreshSoon()
                true
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            false
        } finally {
            picked?.let { runCatching { it.close() } }
        }
    }

    /* --------------------------- Office full text --------------------------- */

    private fun officeIndexer(): NotesOfficeIndexingPort? =
        ports.office as? NotesOfficeIndexingPort

    /**
     * Schedule a rebuild of the native Office text index for [session]'s
     * ACTUAL current resource. Used on open (initial import); a cache that
     * already matches costs one native state read and no byte extraction.
     */
    private fun scheduleOfficeIndex(session: NotesDocumentSession) {
        val document = session.document ?: return
        if (document.kind != com.floe.android.feature.notes.NoteDocumentKind.OFFICE) return
        val resourceID = document.officeResourceID ?: return
        val indexer = officeIndexer() ?: return
        if (!indexer.supports(document.officeFileName, null)) {
            // Real format we cannot read (legacy binary/encrypted/unknown):
            // report the typed outcome so nothing pretends it is indexed.
            val extension = document.officeFileName
                ?.substringAfterLast('.', "")
                ?.lowercase()
                .orEmpty()
            val legacyBinary = extension in setOf("doc", "dot", "xls", "xlt", "ppt", "pot")
            officeIndexOutcome = NotesOfficeIndexOutcome.Unsupported(
                documentID = document.id,
                sourceResourceID = resourceID,
                reason = if (legacyBinary) "legacyBinaryFormat" else "unsupportedFormat",
            )
            return
        }
        indexOfficeResource(document.id, resourceID, session.currentRevision)
    }

    /**
     * Start (or coalesce) one index attempt for an exact source resource.
     * Late results are fenced by the document still referencing that source;
     * a save is never rolled back because indexing failed.
     */
    internal fun indexOfficeResource(
        documentID: String,
        sourceResourceID: String,
        revision: Int,
    ) {
        val indexer = officeIndexer() ?: return
        if (officeIndexJobs[documentID]?.isActive == true) return
        officeIndexBusy = true
        officeIndexJobs[documentID] = scope.launch {
            try {
                val outcome = indexer.index(documentID, sourceResourceID, revision)
                if (sessions[documentID]?.document?.officeResourceID == sourceResourceID) {
                    officeIndexOutcome = outcome
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (sessions[documentID]?.document?.officeResourceID == sourceResourceID) {
                    officeIndexOutcome = NotesOfficeIndexOutcome.Failed(
                        documentID = documentID,
                        sourceResourceID = sourceResourceID,
                        failure = NotesPortFailure(
                            NotesPortFailure.FAILED,
                            error.toNotesFailure().detail,
                        ),
                        retryable = true,
                    )
                }
            } finally {
                officeIndexJobs.remove(documentID)
                officeIndexBusy = officeIndexJobs.values.any { it.isActive }
            }
        }
    }

    /** Explicit, user-visible retry of a typed indexing failure. */
    suspend fun retryOfficeIndex(): Boolean {
        val session = activeSession ?: return false
        val document = session.document ?: return false
        if (document.kind != com.floe.android.feature.notes.NoteDocumentKind.OFFICE) return false
        val resourceID = document.officeResourceID ?: return false
        val indexer = officeIndexer() ?: return false
        if (!indexer.supports(document.officeFileName, null)) return false
        if (session.pendingEditCount != 0) return false
        val outcome = try {
            indexer.index(document.id, resourceID, session.currentRevision)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            NotesOfficeIndexOutcome.Failed(
                documentID = document.id,
                sourceResourceID = resourceID,
                failure = NotesPortFailure(NotesPortFailure.FAILED, error.toNotesFailure().detail),
                retryable = true,
            )
        }
        if (activeDocumentID == document.id) officeIndexOutcome = outcome
        return outcome.indexed || outcome is NotesOfficeIndexOutcome.UpToDate
    }

    fun clearOfficeIndexOutcome() {
        officeIndexOutcome = null
    }

    suspend fun exportArchive(session: NotesDocumentSession): Boolean {
        if (!ensureSavedForExport(session)) return false
        val document = session.document ?: return false
        val export = try {
            service.beginArchiveExport(document.id, document.revision)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            return false
        }
        return try {
            val outcome = ports.exchange.shareStream(
                com.floe.android.feature.notes.ui.api.NotesShareStreamRequest(
                    fileName = export.fileName,
                    mediaType = "application/zip",
                    totalBytes = export.totalBytes,
                    read = { offset, maxBytes -> export.read(offset, maxBytes).data },
                ),
            )
            outcome.launched
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            false
        } finally {
            runCatching { export.close() }
        }
    }

    suspend fun exportPdf(session: NotesDocumentSession): Boolean {
        val stream = buildPdfStream(session) ?: return false
        return try {
            val outcome = ports.exchange.shareStream(
                com.floe.android.feature.notes.ui.api.NotesShareStreamRequest(
                    fileName = stream.fileName,
                    mediaType = stream.mediaType,
                    totalBytes = stream.totalBytes,
                    read = stream.read,
                ),
            )
            outcome.launched
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            false
        } finally {
            runCatching { stream.close() }
        }
    }

    suspend fun exportCurrentPageImage(session: NotesDocumentSession): Boolean {
        val stream = buildPageImageStream(session) ?: return false
        return try {
            val outcome = ports.exchange.shareStream(
                com.floe.android.feature.notes.ui.api.NotesShareStreamRequest(
                    fileName = stream.fileName,
                    mediaType = stream.mediaType,
                    totalBytes = stream.totalBytes,
                    read = stream.read,
                ),
            )
            outcome.launched
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            false
        } finally {
            runCatching { stream.close() }
        }
    }

    suspend fun exportOutline(session: NotesDocumentSession): Boolean {
        val document = session.document ?: return false
        if (document.kind != com.floe.android.feature.notes.NoteDocumentKind.MIND_MAP) return false
        val outline = com.floe.android.feature.notes.ui.presentation.MindMapLayoutEngine.outline(document)
        val text = buildString {
            append("# ").append(document.title).append('\n')
            outline.forEach { (node, depth) ->
                append("  ".repeat(depth.coerceAtMost(24))).append("- ").append(node.title).append('\n')
                node.note.lineSequence().filter { it.isNotBlank() }.forEach { line ->
                    append("  ".repeat((depth + 1).coerceAtMost(24))).append("  ").append(line).append('\n')
                }
            }
        }
        return try {
            ports.exchange.shareText(
                com.floe.android.feature.notes.ui.api.NotesShareTextRequest(
                    fileName = safeExportName(document.title) + ".md",
                    mediaType = "text/markdown",
                    text = text,
                ),
            ).launched
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            false
        }
    }

    suspend fun exportPlainText(session: NotesDocumentSession): Boolean {
        val document = session.document ?: return false
        val text = buildString {
            document.pages.forEachIndexed { index, page ->
                if (index > 0) append("\n\n")
                append("## ").append(index + 1).append("\n")
                document.pages[index].elements.forEach { element ->
                    val value = com.floe.android.feature.notes.ui.presentation.resolveElementText(document, element)
                    if (value.isNotBlank()) append(value).append('\n')
                }
                page.extractedText?.takeIf { it.isNotBlank() }?.let { append(it).append('\n') }
            }
            if (document.pages.isEmpty()) {
                document.nodes.forEach { append(it.title).append('\n') }
            }
        }
        return try {
            ports.exchange.shareText(
                com.floe.android.feature.notes.ui.api.NotesShareTextRequest(
                    fileName = safeExportName(document.title) + ".txt",
                    mediaType = "text/plain",
                    text = text,
                ),
            ).launched
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            false
        }
    }

    suspend fun printActiveDocument(session: NotesDocumentSession): com.floe.android.feature.notes.ui.api.NotesPrintOutcome {
        val stream = buildPdfStream(session)
            ?: return com.floe.android.feature.notes.ui.api.NotesPrintOutcome.Unavailable(
                com.floe.android.feature.notes.ui.api.NotesPortFailure("portUnavailable"),
            )
        return try {
            ports.media.print(
                com.floe.android.feature.notes.ui.api.NotesPrintRequest(
                    jobName = session.document?.title.orEmpty(),
                    stream = stream,
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            com.floe.android.feature.notes.ui.api.NotesPrintOutcome.Failed(
                com.floe.android.feature.notes.ui.api.NotesPortFailure(
                    com.floe.android.feature.notes.ui.api.NotesPortFailure.FAILED,
                    error.message,
                ),
            )
        } finally {
            runCatching { stream.close() }
        }
    }

    suspend fun openLinkedMap(parentDocumentID: String, parentPageID: String?, mapDocumentID: String): Boolean {
        return try {
            val map = service.document(mapDocumentID)
            if (map.deletedAt != null) return false
            openLinkedMap(parentDocumentID, parentPageID, map)
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            false
        }
    }

    private suspend fun ensureSavedForExport(session: NotesDocumentSession): Boolean {
        if (session.pendingInk.isNotEmpty() && !session.retryInk()) {
            lastFailure = NotesFailure("storageUnavailable", "inkExport")
            return false
        }
        if (session.pendingEditCount == 0) return true
        val result = session.flush()
        if (result is NotesFlushResult.Failed || result is NotesFlushResult.Conflict ||
            result is NotesFlushResult.Fenced
        ) {
            lastFailure = when (result) {
                is NotesFlushResult.Failed -> result.failure
                is NotesFlushResult.Conflict -> NotesFailure("conflict")
                NotesFlushResult.Fenced -> NotesFailure("staleGeneration")
                else -> null
            }
            return false
        }
        return true
    }

    private suspend fun buildPdfStream(
        session: NotesDocumentSession,
    ): com.floe.android.feature.notes.ui.api.NotesExportedStream? {
        if (!ensureSavedForExport(session)) return null
        val document = session.document ?: return null
        val pages = document.pages.map { page ->
            com.floe.android.feature.notes.ui.api.NotesExportPage(
                pageID = page.id,
                widthPt = page.width.toFloat(),
                heightPt = page.height.toFloat(),
                paper = page.paper,
                pdfPageIndex = page.pdfPageIndex,
                pdfResourceID = page.backgroundResourceID.takeIf { page.pdfPageIndex != null },
                drawingResourceID = page.drawingResourceID,
                backgroundResourceID = page.backgroundResourceID,
                elements = page.elements.map { element ->
                    com.floe.android.feature.notes.ui.api.NotesExportElement(
                        kind = element.kind,
                        frame = element.frame,
                        text = com.floe.android.feature.notes.ui.presentation.resolveElementText(document, element),
                        color = element.color,
                        fontSize = element.fontSize,
                        isMarkdown = element.isMarkdown,
                        imageResourceID = element.resourceID,
                    )
                },
            )
        }
        if (pages.isEmpty()) {
            lastFailure = NotesFailure("invalidDocument", "noPages")
            return null
        }
        val pdfResourceID = pages.firstNotNullOfOrNull { it.pdfResourceID }
        val record = pdfResourceID?.let { id ->
            runCatching { service.resourceMetadata(id) }.getOrNull()
        }
        return try {
            ports.media.exportPdf(
                com.floe.android.feature.notes.ui.api.NotesPdfExportRequest(
                    documentID = document.id,
                    title = document.title,
                    pages = pages,
                    pdfResourceID = pdfResourceID,
                    pdfSha256 = record?.hash,
                    pdfByteCount = record?.byteCount,
                    fileName = safeExportName(document.title) + ".pdf",
                    read = resources.reader(),
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            null
        }
    }

    private suspend fun buildPageImageStream(
        session: NotesDocumentSession,
    ): com.floe.android.feature.notes.ui.api.NotesExportedStream? {
        if (!ensureSavedForExport(session)) return null
        val document = session.document ?: return null
        val page = session.currentPage ?: return null
        val spec = com.floe.android.feature.notes.ui.api.NotesExportPage(
            pageID = page.id,
            widthPt = page.width.toFloat(),
            heightPt = page.height.toFloat(),
            paper = page.paper,
            pdfPageIndex = page.pdfPageIndex,
            pdfResourceID = page.backgroundResourceID.takeIf { page.pdfPageIndex != null },
            drawingResourceID = page.drawingResourceID,
            backgroundResourceID = page.backgroundResourceID,
            elements = page.elements.map { element ->
                com.floe.android.feature.notes.ui.api.NotesExportElement(
                    kind = element.kind,
                    frame = element.frame,
                    text = com.floe.android.feature.notes.ui.presentation.resolveElementText(document, element),
                    color = element.color,
                    fontSize = element.fontSize,
                    isMarkdown = element.isMarkdown,
                    imageResourceID = element.resourceID,
                )
            },
        )
        return try {
            ports.media.exportPageImage(
                com.floe.android.feature.notes.ui.api.NotesPageImageExportRequest(
                    documentID = document.id,
                    page = spec,
                    fileName = safeExportName(document.title) + ".png",
                    targetWidthPx = 2048,
                    read = resources.reader(),
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            null
        }
    }

    private fun safeExportName(title: String): String =
        title.trim().replace(Regex("[\\/:*?\"<>|\n\r]"), "_").take(120).ifBlank { "note" }

    suspend fun openActiveEngineeringAttachment(): NotesAttachmentOpenResult {
        val document = activeSession?.document ?: return NotesAttachmentOpenResult.FAILED
        val resourceID = document.engineeringResourceID ?: return NotesAttachmentOpenResult.UNAVAILABLE
        val record = runCatching { service.resourceMetadata(resourceID) }.getOrNull()
            ?: return NotesAttachmentOpenResult.FAILED
        return when (val outcome = ports.exchange.openAttachment(
            com.floe.android.feature.notes.ui.api.NotesOpenAttachmentRequest(
                resourceID = record.id,
                fileName = document.engineeringFileName ?: record.fileName,
                mediaType = record.mediaType,
            ),
        )) {
            com.floe.android.feature.notes.ui.api.NotesOpenAttachmentOutcome.Opened ->
                NotesAttachmentOpenResult.OPENED
            is com.floe.android.feature.notes.ui.api.NotesOpenAttachmentOutcome.Unavailable -> {
                lastFailure = outcome.failure.toNotesFailure()
                NotesAttachmentOpenResult.UNAVAILABLE
            }
            is com.floe.android.feature.notes.ui.api.NotesOpenAttachmentOutcome.Failed -> {
                lastFailure = outcome.failure.toNotesFailure()
                NotesAttachmentOpenResult.FAILED
            }
        }
    }

    suspend fun insertImageIntoActivePage(): Boolean {
        val session = activeSession ?: return false
        var picked: NotesPickedFile? = null
        return try {
            val selected = ports.exchange.pickFile(setOf(NotesImportKind.IMAGE)) ?: return false
            picked = selected
            val imported = resources.import(
                fileName = selected.fileName,
                mediaType = selected.mediaType,
                byteCount = selected.byteCount,
                read = selected.read,
            )
            session.insertElement(NoteElementKind.IMAGE, imported.resourceID)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            false
        } finally {
            picked?.let { runCatching { it.close() } }
        }
    }

    suspend fun setActiveMindMapNodeImage(nodeID: String): Boolean {
        val session = activeSession ?: return false
        var picked: NotesPickedFile? = null
        return try {
            val selected = ports.exchange.pickFile(setOf(NotesImportKind.IMAGE)) ?: return false
            picked = selected
            val imported = resources.import(
                fileName = selected.fileName,
                mediaType = selected.mediaType,
                byteCount = selected.byteCount,
                read = selected.read,
            )
            session.updateMindMapNodeImage(nodeID, imported.resourceID)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            false
        } finally {
            picked?.let { runCatching { it.close() } }
        }
    }

    suspend fun attachFileToActiveMindMapNode(nodeID: String): Boolean {
        val session = activeSession ?: return false
        var picked: NotesPickedFile? = null
        return try {
            val selected = ports.exchange.pickFile(setOf(NotesImportKind.FILE)) ?: return false
            picked = selected
            val imported = resources.import(
                fileName = selected.fileName,
                mediaType = selected.mediaType,
                byteCount = selected.byteCount,
                read = selected.read,
            )
            val kind = when {
                selected.mediaType.startsWith("image/") -> MindMapAttachmentKind.IMAGE
                selected.mediaType.startsWith("audio/") -> MindMapAttachmentKind.AUDIO
                selected.mediaType.startsWith("video/") -> MindMapAttachmentKind.VIDEO
                selected.mediaType == "application/pdf" ||
                    selected.fileName.substringAfterLast('.', "").lowercase() in
                    setOf("doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md") ->
                    MindMapAttachmentKind.DOCUMENT
                else -> MindMapAttachmentKind.FILE
            }
            session.addMindMapAttachment(
                nodeID,
                MindMapAttachment(
                    id = java.util.UUID.randomUUID().toString(),
                    resourceID = imported.resourceID,
                    fileName = selected.fileName,
                    mediaType = selected.mediaType,
                    kind = kind,
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            lastFailure = error.toNotesFailure()
            false
        } finally {
            picked?.let { runCatching { it.close() } }
        }
    }

    fun openLinkedMapsFrom(parentDocumentID: String) {
        val session = sessions[parentDocumentID] ?: return
        // The actual sheet is rendered by the UI from the live document.
        session.showLinkedMaps = true
    }

    fun dismissAlert() {
        alert = null
    }

    fun clearFailure() {
        lastFailure = null
    }

    /** Opens an in-app Notes source; external Canvas/Workspace sources are host callbacks. */
    fun openSource(source: NoteSourceReference): Boolean {
        if (source.space != NoteSourceSpace.NOTES) return false
        val current = activeDocumentID
        if (current != null && current != source.documentID) {
            navigation = navigation + NotesLinkLocation(
                documentID = current,
                pageID = activeSession?.activePageID,
                title = activeSession?.document?.title.orEmpty(),
            )
        }
        openDocument(source.documentID, source.pageID)
        return true
    }

    private fun removeTabAfterFailure(documentID: String) {
        sessions[documentID]?.dispose()
        sessions.remove(documentID)
        tabs = tabs - documentID
        if (activeDocumentID == documentID) activeDocumentID = tabs.lastOrNull()
        persist()
    }

    fun persist() {
        ports.presentation.saveWorkspace(
            com.floe.android.feature.notes.ui.presentation.NotesWorkspacePreferences(
                openDocumentIDs = tabs,
                activeDocumentID = activeDocumentID,
                grid = library.grid,
                filter = library.filter.key,
                sort = library.sort.key,
                selectedNotebookID = library.selectedNotebookID,
            ),
        )
    }

    private fun startEvents() {
        eventJob?.cancel()
        eventJob = scope.launch {
            while (isActive && !fenced()) {
                try {
                    val batch = service.pollEvents(eventCursor, limit = 128)
                    eventCursor = batch.cursor
                    handleEvents(batch)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    // Event polling is advisory; a failure must not close the
                    // editor or fake a saved state. Retry after a bounded pause.
                }
                delay(2_500)
            }
        }
    }

    private fun handleEvents(batch: NotesEventBatch) {
        if (batch.resyncRequired) {
            library.refreshSoon()
            sessions.values.filter { it.document != null }.forEach { session ->
                if (session.pendingEditCount == 0) {
                    scope.launch { session.load() }
                }
            }
            return
        }
        batch.events.forEach { event ->
            val documentID = event.documentID ?: return@forEach
            when {
                event.kind == "document.deleted" -> {
                    library.refreshSoon()
                    if (activeDocumentID == documentID) {
                        alert = NotesWorkspaceAlert.DOCUMENT_DELETED
                        clearActiveDocument()
                    }
                }
                event.kind == "document.trashed" || event.kind == "document.restored" -> {
                    library.refreshSoon()
                    sessions[documentID]?.let { session ->
                        scope.launch { session.load() }
                    }
                }
                event.kind.startsWith("document.") -> {
                    val revision = event.revision ?: return@forEach
                    val session = sessions[documentID] ?: return@forEach
                    if (revision > session.currentRevision) {
                        session.markExternalRevision(revision)
                    }
                }
            }
        }
    }

    suspend fun resumeRecovery(recovery: NotesPendingRecovery): NotesRecoveryResumeResult {
        val loaded = try {
            service.document(recovery.documentID)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            // A failed read is not permission to discard the only durable draft.
            // Keep it even when its source is missing; explicit Discard owns deletion.
            return if (error is NotesException && error.code == "notFound") {
                NotesRecoveryResumeResult.DocumentMissing
            } else {
                NotesRecoveryResumeResult.Failed(error.toNotesFailure())
            }
        }
        if (loaded.deletedAt != null) {
            // Never revive a deleted document automatically; retain the draft separately.
            return NotesRecoveryResumeResult.DocumentDeleted
        }
        if (recovery.documentKind.isNotBlank() && recovery.documentKind != loaded.kind.wire) {
            return NotesRecoveryResumeResult.Failed(NotesFailure("invalidDocument", "kindMismatch"))
        }
        val session = sessions.getOrPut(recovery.documentID) {
            NotesDocumentSession(
                documentID = recovery.documentID,
                service = service,
                ports = ports,
                resources = resources,
                scope = scope,
                generation = generation,
                fenced = fenced,
                onLibraryInvalidated = { library.refreshSoon() },
            )
        }
        if (session.document == null) {
            if (!session.load()) {
                return NotesRecoveryResumeResult.Failed(
                    session.loadFailure ?: NotesFailure("notFound", "document"),
                )
            }
        }
        activeDocumentID = recovery.documentID
        if (recovery.documentID !in tabs) tabs = tabs + recovery.documentID
        val result = session.restoreRecovery(recovery)
        library.refreshSoon()
        persist()
        return when (result) {
            NotesFlushResult.Saved, NotesFlushResult.NoPending -> NotesRecoveryResumeResult.Restored
            is NotesFlushResult.Conflict -> NotesRecoveryResumeResult.Conflict(result.conflict)
            is NotesFlushResult.Failed -> NotesRecoveryResumeResult.Failed(result.failure)
            NotesFlushResult.Fenced -> NotesRecoveryResumeResult.Failed(
                NotesFailure("staleGeneration", "rootFenced"),
            )
        }
    }

    suspend fun prepareForStop(deadlineMillis: Long): NotesRootStopReport {
        eventJob?.cancel()
        val deadline = System.currentTimeMillis() + deadlineMillis.coerceAtLeast(500)
        val flushed = mutableListOf<String>()
        val kept = mutableListOf<NotesPendingRecovery>()
        var timedOut = false
        // False means some live edit/ink has neither flushed nor reached the
        // durable recovery store. The caller must refuse root retirement.
        var canRetire = true
        sessions.values.toList().forEach { session ->
            val remaining = (deadline - System.currentTimeMillis()).coerceAtLeast(250)
            val outcome = withTimeoutOrNull(remaining) {
                session.prepareForStop(remaining)
            }
            if (outcome == null) {
                timedOut = true
                // A throwing durable put propagates: no report can claim that
                // this session is safely retained.
                session.persistPendingRecovery("timeout")
                val record = session.pendingRecoverySnapshot()
                if (record != null) kept += record
                if (record == null && session.hasPendingWork()) canRetire = false
            } else when (outcome) {
                is NotesStopOutcome.Flushed -> {
                    flushed += outcome.documentID
                    // An edit that raced the bounded flush is not saved.
                    if (session.hasPendingWork()) canRetire = false
                }
                is NotesStopOutcome.Kept -> {
                    val record = outcome.recovery
                    if (record != null) kept += record
                    if (record == null && session.hasPendingWork()) canRetire = false
                }
            }
        }
        return NotesRootStopReport(
            flushedDocumentIDs = flushed,
            kept = kept.distinctBy { it.documentID },
            timedOut = timedOut,
            canRetire = canRetire,
        )
    }

    suspend fun resumeAfterRoot(): NotesResumeReport {
        library.refreshSoon()
        val saved = mutableListOf<String>()
        val remaining = mutableListOf<NotesPendingRecovery>()
        val failures = mutableListOf<NotesFailure>()
        sessions.values.toList().forEach { session ->
            // Never let a coroutine cancellation be reported as a completed
            // restore; real failures stay visible in the resume report.
            val result = try {
                session.resumeAfterRoot()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failures += error.toNotesFailure()
                null
            }
            if (result is NotesFlushResult.Saved || result is NotesFlushResult.NoPending) {
                saved += session.documentID
            } else {
                runCatching {
                    ports.recovery.pending().firstOrNull { it.documentID == session.documentID }
                }.getOrNull()?.let { remaining += it }
                when (result) {
                    is NotesFlushResult.Failed -> failures += result.failure
                    is NotesFlushResult.Conflict -> failures += NotesFailure(
                        "conflict",
                        result.conflict.detail,
                    )
                    else -> Unit
                }
            }
        }
        eventCursor = 0
        startEvents()
        return NotesResumeReport(
            savedDocumentIDs = saved,
            remaining = remaining,
            failures = failures.distinctBy { it.code to it.detail },
        )
    }

    fun dispose() {
        eventJob?.cancel()
        officeIndexJobs.values.forEach { it.cancel() }
        officeIndexJobs.clear()
        officeIndexBusy = false
        library.dispose()
        sessions.values.forEach { it.dispose() }
        sessions.clear()
    }
}
