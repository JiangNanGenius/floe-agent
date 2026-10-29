// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.noteschattransfer

import com.floe.android.feature.notes.*

/**
 * Exhaustive [NotesService] test base: every abstract member answers a typed
 * unsupported failure. A focused test overrides ONLY the operations its
 * subject actually uses, so an unexpected call fails loudly instead of
 * returning a fabricated success.
 *
 * This is a real Kotlin implementation (not a dynamic proxy) so a
 * [NotesException] thrown by an override reaches the production caller with
 * its real checked-exception identity.
 */
internal open class FakeNotesServiceBase : NotesService {
    protected fun unsupported(operation: String): Nothing =
        throw UnsupportedOperationException("FakeNotesService." + operation)
    override suspend fun bind(epoch: Long): NotesBinding = unsupported("bind")
    override suspend fun status(): NotesStatus = unsupported("status")
    override suspend fun library(): NotesLibrarySummary = unsupported("library")
    override suspend fun notebooks(): List<Notebook> = unsupported("notebooks")
    override suspend fun createNotebook(title: String): Notebook = unsupported("createNotebook")
    override suspend fun renameNotebook(notebookID: String, title: String): Unit = unsupported("renameNotebook")
    override suspend fun documents(includeTrash: Boolean, limit: Int): NotesDocumentPage = unsupported("documents")
    override suspend fun recentDocuments(limit: Int): List<NoteDocumentSummary> = unsupported("recentDocuments")
    override suspend fun document(documentID: String): NoteDocument = unsupported("document")
    override suspend fun documentSummary(documentID: String): NoteDocumentSummary = unsupported("documentSummary")
    override suspend fun createDocument(request: NotesCreateDocument): NoteDocument = unsupported("createDocument")
    override suspend fun duplicateDocument(request: NotesDuplicateDocument): NoteDocument = unsupported("duplicateDocument")
    override suspend fun saveMessage(request: NotesSaveMessage): NoteDocument = unsupported("saveMessage")
    override suspend fun createLinkedMindMap(documentID: String, expectedRevision: Int, title: String, pageID: String?): NoteDocument = unsupported("createLinkedMindMap")
    override suspend fun apply(request: NotesApplyRequest): NoteDocument = unsupported("apply")
    override suspend fun undo(documentID: String, expectedRevision: Int, redo: Boolean): NoteDocument = unsupported("undo")
    override suspend fun setTrashed(documentID: String, expectedRevision: Int, trashed: Boolean): NoteDocument = unsupported("setTrashed")
    override suspend fun deletePermanently(documentID: String, expectedRevision: Int): Unit = unsupported("deletePermanently")
    override suspend fun history(documentID: String): NoteHistoryState = unsupported("history")
    override suspend fun markOpened(documentID: String): Unit = unsupported("markOpened")
    override suspend fun setFavorite(documentID: String, expectedRevision: Int, isFavorite: Boolean): NoteDocument = unsupported("setFavorite")
    override suspend fun setTags(documentID: String, expectedRevision: Int, tags: List<String>): NoteDocument = unsupported("setTags")
    override suspend fun cover(documentID: String): NoteCoverState = unsupported("cover")
    override suspend fun applyCover(request: NotesCoverRequest): NoteDocument = unsupported("applyCover")
    override suspend fun cacheOfficePreview(documentID: String, sourceResourceID: String, previewResourceID: String, expectedRevision: Int): NoteDocument = unsupported("cacheOfficePreview")
    override suspend fun editingSnapshot(documentID: String, revision: Int): NoteDocument? = unsupported("editingSnapshot")
    override suspend fun search(query: String, limit: Int): List<NoteDocumentSummary> = unsupported("search")
    override suspend fun beginResourceImport(fileName: String, mediaType: String, byteCount: Long): NotesResourceImport = unsupported("beginResourceImport")
    override suspend fun resourceMetadata(resourceID: String): NoteResourceRecord = unsupported("resourceMetadata")
    override suspend fun readResource(resourceID: String, offset: Long, maxBytes: Int): NoteResourceChunk = unsupported("readResource")
    override suspend fun discardUnreferencedResource(resourceID: String): Boolean = unsupported("discardUnreferencedResource")
    override suspend fun collectDeletedResources(): Int = unsupported("collectDeletedResources")
    override suspend fun grantAccess(conversationID: String, documentID: String, canEdit: Boolean): Unit = unsupported("grantAccess")
    override suspend fun bindAssistant(conversationID: String, documentID: String, canEdit: Boolean): Unit = unsupported("bindAssistant")
    override suspend fun revokeAccess(conversationID: String, documentID: String): Unit = unsupported("revokeAccess")
    override suspend fun grants(conversationID: String): Map<String, Boolean> = unsupported("grants")
    override suspend fun scopedDocuments(conversationID: String): List<NoteDocumentSummary> = unsupported("scopedDocuments")
    override suspend fun setAssistantFocus(conversationID: String, documentID: String, pageID: String?): Unit = unsupported("setAssistantFocus")
    override suspend fun runtimeContext(conversationID: String): String? = unsupported("runtimeContext")
    override suspend fun beginArchiveExport(documentID: String, expectedRevision: Int): NotesArchiveExport = unsupported("beginArchiveExport")
    override suspend fun beginArchiveImport(byteCount: Long): NotesArchiveImport = unsupported("beginArchiveImport")
    override suspend fun pendingProposals(documentID: String?): List<NotesProposalSummary> = unsupported("pendingProposals")
    override suspend fun pollEvents(cursor: Long, limit: Int): NotesEventBatch = unsupported("pollEvents")
    override suspend fun close(): Unit = unsupported("close")
}
