// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import com.floe.android.feature.notes.MindMapAttachmentKind
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NoteResourceRecord
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchResource
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchResourceKind

/**
 * One user-selectable resource in the current document. This is UI-only
 * metadata: the exact digest/size/name are re-read from the Notes service at
 * create time and again by the Core receipt. Nothing here is authority.
 */
internal data class NotesTaskLaunchCandidate(
    val resourceID: String,
    val kind: NotesTaskLaunchResourceKind,
)

/**
 * Builds the attachment chooser from the document's REAL referenced
 * resources. Page drawing resources are editor-internal ink state, not user
 * attachments, so they are excluded. The Notes original is never modified.
 */
internal object NotesTaskLaunchSelection {
    const val MAX_CANDIDATES = 64

    fun candidates(document: NoteDocument): List<NotesTaskLaunchCandidate> {
        val byID = LinkedHashMap<String, NotesTaskLaunchResourceKind>()

        fun add(resourceID: String?, kind: NotesTaskLaunchResourceKind) {
            val id = resourceID?.trim().orEmpty()
            if (id.isEmpty()) return
            val current = byID[id]
            if (current == null || rank(kind) < rank(current)) byID[id] = kind
        }

        add(document.officeResourceID, NotesTaskLaunchResourceKind.DOCUMENT)
        add(document.engineeringResourceID, NotesTaskLaunchResourceKind.OTHER)
        add(document.coverResourceID, NotesTaskLaunchResourceKind.IMAGE)

        document.pages.forEach { page ->
            // `drawingResourceID` is the editor's own ink snapshot and is
            // deliberately excluded; it is not a document attachment.
            add(page.backgroundResourceID, NotesTaskLaunchResourceKind.PDF)
            page.elements.forEach { element ->
                if (element.kind == NoteElementKind.IMAGE) {
                    add(element.resourceID, NotesTaskLaunchResourceKind.IMAGE)
                }
            }
        }
        document.nodes.forEach { node ->
            add(node.imageResourceID, NotesTaskLaunchResourceKind.IMAGE)
            node.attachments.orEmpty().forEach { attachment ->
                add(attachment.resourceID, kind(attachment.kind))
            }
        }
        return byID.entries.take(MAX_CANDIDATES).map { (id, kind) ->
            NotesTaskLaunchCandidate(id, kind)
        }
    }

    fun resources(
        candidates: List<NotesTaskLaunchCandidate>,
        metadata: Map<String, NoteResourceRecord>,
    ): List<NotesTaskLaunchResource> = candidates.mapNotNull { candidate ->
        val record = metadata[candidate.resourceID] ?: return@mapNotNull null
        if (record.byteCount <= 0L) return@mapNotNull null
        NotesTaskLaunchResource(
            resourceID = record.id,
            fileName = record.fileName,
            mediaType = record.mediaType,
            byteCount = record.byteCount,
            sha256 = record.hash,
            kind = classify(record.mediaType, candidate.kind),
        )
    }

    fun classify(
        mediaType: String,
        fallback: NotesTaskLaunchResourceKind,
    ): NotesTaskLaunchResourceKind {
        val type = mediaType.substringBefore(';').trim().lowercase()
        return when {
            type == "application/pdf" -> NotesTaskLaunchResourceKind.PDF
            type.startsWith("image/") -> NotesTaskLaunchResourceKind.IMAGE
            type.startsWith("text/") -> NotesTaskLaunchResourceKind.DOCUMENT
            type.contains("word") || type.contains("sheet") || type.contains("presentation") ->
                NotesTaskLaunchResourceKind.DOCUMENT
            type.contains("officedocument") || type == "application/msword" ||
                type == "application/vnd.ms-excel" || type == "application/vnd.ms-powerpoint" ->
                NotesTaskLaunchResourceKind.DOCUMENT
            else -> fallback
        }
    }

    private fun kind(kind: MindMapAttachmentKind): NotesTaskLaunchResourceKind =
        when (kind) {
            MindMapAttachmentKind.IMAGE -> NotesTaskLaunchResourceKind.IMAGE
            MindMapAttachmentKind.DOCUMENT -> NotesTaskLaunchResourceKind.DOCUMENT
            MindMapAttachmentKind.AUDIO,
            MindMapAttachmentKind.VIDEO,
            MindMapAttachmentKind.FILE -> NotesTaskLaunchResourceKind.OTHER
        }

    private fun rank(kind: NotesTaskLaunchResourceKind): Int = when (kind) {
        NotesTaskLaunchResourceKind.PDF -> 0
        NotesTaskLaunchResourceKind.IMAGE -> 1
        NotesTaskLaunchResourceKind.DOCUMENT -> 2
        NotesTaskLaunchResourceKind.OTHER -> 3
    }
}
