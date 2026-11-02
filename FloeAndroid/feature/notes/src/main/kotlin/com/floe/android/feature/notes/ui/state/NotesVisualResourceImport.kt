// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.state

import com.floe.android.feature.notes.*
import com.floe.android.feature.notes.ui.api.*
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Same native PDF/image page import for the library and explicit share intake.
 * Original bytes stay in Notes resources; no path, second store or PDF editor.
 */
public object NotesVisualResourceImport {
    public suspend fun create(
        service: NotesService,
        media: NotesMediaPort,
        resourceID: String,
        fileName: String,
        title: String,
        documentID: String = UUID.randomUUID().toString(),
        notebookID: String? = null,
    ): NoteDocument {
        val record = service.resourceMetadata(resourceID)
        val reader = NotesResourceReader { id, offset, count ->
            service.readResource(id, offset, count.coerceIn(1, NotesProtocol.MAX_READ_BYTES)).data
        }
        fun pageID(index: Int): String = UUID.nameUUIDFromBytes(
            "visual:$documentID:$index".toByteArray(Charsets.UTF_8),
        ).toString()
        val pages = if (record.mediaType == "application/pdf") {
            val handle = when (val result = media.openPdf(NotesPdfOpenRequest(
                documentID, resourceID, record.hash, record.byteCount, fileName, record.mediaType, reader,
            ))) {
                is NotesPdfOpenOutcome.Opened -> result.handle
                NotesPdfOpenOutcome.PasswordRequired -> throw NotesException("passwordRequired", "passwordProtected")
                is NotesPdfOpenOutcome.Unavailable -> throw NotesPortFailureException(result.failure)
                is NotesPdfOpenOutcome.Failed -> throw NotesPortFailureException(result.failure)
            }
            try {
                if (handle.pageCount !in 1..NotesProtocol.MAX_EDITS) {
                    throw NotesException("requestTooLarge", "pdfPageLimit")
                }
                (0 until handle.pageCount).map { index ->
                    currentCoroutineContext().ensureActive()
                    val size = handle.pageSize(index)
                    NotePage(pageID(index),
                        width = (size?.widthPt ?: 612f).toDouble().coerceIn(1.0, 16_384.0),
                        height = (size?.heightPt ?: 792f).toDouble().coerceIn(1.0, 16_384.0),
                        backgroundResourceID = resourceID, pdfPageIndex = index)
                }
            } finally { runCatching { handle.close() } }
        } else if (record.mediaType.startsWith("image/")) {
            val info = media.probeImage(NotesImageProbeRequest(
                fileName, record.mediaType, record.byteCount,
                read = { offset, count -> reader.read(resourceID, offset, count) },
            )) ?: throw NotesException("unsupportedAction", "imageFormat")
            listOf(NotePage(pageID(0), width = 768.0,
                height = (768.0 * info.height / info.width.toDouble().coerceAtLeast(1.0)).coerceIn(1.0, 16_384.0),
                backgroundResourceID = resourceID))
        } else throw NotesException("unsupportedAction", "visualFormat")
        currentCoroutineContext().ensureActive()
        // Native create is idempotent for this stable intake identity. A failed
        // atomic apply can resume its untouched placeholder; never replace edits.
        val document = service.createDocument(NotesCreateDocument(
            NoteDocumentKind.NOTEBOOK, title, notebookID, documentID,
        ))
        if (document.kind != NoteDocumentKind.NOTEBOOK || document.deletedAt != null) {
            throw NotesException("conflict", "visualImportDestination")
        }
        val priorResource = document.pages.firstOrNull()?.backgroundResourceID
        if (priorResource != null && document.pages.size == pages.size &&
            document.pages.zip(pages).all { (actual, expected) ->
                actual.backgroundResourceID.equals(priorResource, ignoreCase = true) &&
                    actual.pdfPageIndex == expected.pdfPageIndex
            } && service.resourceMetadata(priorResource).hash == record.hash
        ) return document // Exact completed intake; retain subsequent user edits.
        val blank = document.pages.singleOrNull()
        if (blank == null || blank.backgroundResourceID != null || blank.drawingResourceID != null ||
            blank.elements.isNotEmpty() || document.revision > 1) {
            throw NotesException("conflict", "visualImportModified")
        }
        return service.applyAtomically(NotesApplyRequest(
            documentID = document.id, expectedRevision = document.revision,
            title = if (record.mediaType == "application/pdf") "Import PDF" else "Import image",
            edits = importedNotebookPageEdits(blank.id, pages),
            requestID = "visual-import:$documentID:${record.hash}",
        ))
    }
}
