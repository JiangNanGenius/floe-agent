// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes

/**
 * Closed, value-only edit vocabulary shared by the Android editor and the
 * native Notes authority. Every action maps one-to-one to the original
 * `FloeNotes.NoteEdit` case through the `floe.notes/4` wire schema. No action
 * contains a filesystem path, executable payload or implicit permission.
 */
sealed interface NotesEdit {
    data class Rename(val text: String) : NotesEdit {
        init { require(text.isNotBlank()) { "rename title" } }
    }

    data class MoveToNotebook(val notebookID: String?) : NotesEdit

    data class Favorite(val isFavorite: Boolean) : NotesEdit

    data class Tags(val tags: List<String>) : NotesEdit {
        init { require(tags.size <= 100) { "tag count" } }
    }

    data class TextSource(val id: String, val text: String?) : NotesEdit {
        init { require(id.isNotBlank()) { "text source id" } }
    }

    data class InsertPage(val page: NotePage, val index: Int) : NotesEdit

    data class UpdatePage(val page: NotePage) : NotesEdit

    data class MovePage(val pageID: String, val index: Int) : NotesEdit

    data class DuplicatePage(val pageID: String) : NotesEdit

    data class DeletePage(val pageID: String) : NotesEdit

    data class Drawing(val pageID: String, val resourceID: String?) : NotesEdit

    data class UpsertElement(val pageID: String, val element: NoteElement) : NotesEdit

    data class DeleteElements(val pageID: String, val ids: List<String>) : NotesEdit {
        init { require(ids.isNotEmpty()) { "element ids" } }
    }

    data class UpsertNode(val node: MindMapNode) : NotesEdit

    data class DeleteBranch(val nodeID: String) : NotesEdit

    data class UpsertConnection(val connection: MindMapConnection) : NotesEdit

    data class DeleteConnection(val connectionID: String) : NotesEdit

    data class ReplaceMindMap(
        val nodes: List<MindMapNode>,
        val connections: List<MindMapConnection>,
    ) : NotesEdit {
        init { require(nodes.size <= 10_000 && connections.size <= 10_000) { "mind map bounds" } }
    }

    data class LinkMindMap(val link: NoteMindMapLink) : NotesEdit

    data class UnlinkMindMap(val linkID: String) : NotesEdit

    data class ReplaceOfficeResource(val resourceID: String) : NotesEdit

    data class MindMapLayout(val direction: Int, val summaries: List<MindMapSummary>) : NotesEdit {
        init {
            require(direction in 0..2) { "mind map direction" }
            require(summaries.size <= 10_000) { "summary bounds" }
        }
    }
}

data class NotesApplyRequest(
    val documentID: String,
    val expectedRevision: Int,
    val title: String = "Notes edit",
    val edits: List<NotesEdit>,
    /** Stable retry identity. The native edit receipt makes retries idempotent. */
    val requestID: String? = null,
    /**
     * UI optimistic rebase only: the exact revision the editor read. The
     * native service re-reads that historical snapshot and applies only edits
     * whose touched objects are unchanged; otherwise it returns `conflict`.
     */
    val baseRevision: Int? = null,
    /** Assistant path only; the store re-checks the grant inside its transaction. */
    val conversationID: String? = null,
) {
    init {
        require(documentID.isNotBlank()) { "document id" }
        require(expectedRevision >= 0) { "expected revision" }
        require(edits.isNotEmpty() && edits.size <= NotesProtocol.MAX_EDITS) { "edit count" }
        require(baseRevision == null || conversationID == null) { "assistant edits never use UI rebase" }
    }
}

data class NotesCreateDocument(
    val kind: NoteDocumentKind,
    val title: String,
    val notebookID: String? = null,
    /** Optional stable identity so an App retry returns the same document. */
    val documentID: String? = null,
    val resourceID: String? = null,
    val fileName: String? = null,
) {
    init {
        require(title.isNotBlank()) { "document title" }
        when (kind) {
            NoteDocumentKind.OFFICE, NoteDocumentKind.ENGINEERING -> {
                require(resourceID != null && !fileName.isNullOrBlank()) { "imported document requires a resource and file name" }
            }
            else -> require(resourceID == null && fileName == null) { "plain notes do not carry an imported resource" }
        }
    }
}

data class NotesDuplicateDocument(
    val sourceDocumentID: String,
    val newDocumentID: String? = null,
    val title: String? = null,
    val notebookID: String? = null,
)

data class NotesSaveMessage(
    val text: String,
    val title: String? = null,
    val notebookID: String? = null,
    val documentID: String? = null,
) {
    init { require(text.isNotEmpty() && text.encodeToByteArray().size <= 1_048_576) { "message size" } }
}

data class NotesCoverRequest(
    val documentID: String,
    val expectedRevision: Int,
    val expectedCoverRevision: Int,
    val resourceID: String? = null,
) {
    init {
        require(documentID.isNotBlank()) { "document id" }
        require(expectedRevision >= 0 && expectedCoverRevision >= 0) { "cover baseline" }
    }
    val restoreAutomatic: Boolean get() = resourceID == null
}
