// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes

/**
 * G06 Notes consumer API.
 *
 * Authority and lifetime:
 * * One native `NotesEngine`/`NotesStore` owns the independent library under
 *   `<accepted runtime root>/FloeAgent/Notes`. There is no Kotlin database and
 *   no in-memory production fallback.
 * * [bind] authorizes the current accepted native runtime epoch. The first
 *   data call opens the library lazily; merely binding, showing chat, or
 *   deleting a conversation never creates or deletes notes.
 * * Every mutation carries an explicit document revision (or is an explicit
 *   create). Late results from an older revision fail with [NotesException]
 *   `conflict`; they never overwrite newer content.
 * * Deletion of a chat conversation has no API here and no foreign key into
 *   this store. Assistant grants are Notes-local rows.
 *
 * Concurrency/cancellation:
 * * Methods are `suspend` so callers can run them off the UI thread, but the
 *   native command itself is synchronous. Cancellation before dispatch is
 *   honoured; a dispatched command is not interrupted mid-transaction and its
 *   result must be reconciled. Chunked resource/archive sessions expose
 *   cancellation points between chunks; callers must [NotesResourceImport.abort]
 *   or [NotesArchiveImport.abort] in `finally` when abandoning a session.
 * * [NotesResourceImport.commit] and [NotesArchiveImport.commit] are
 *   idempotent for the same stage only until success; after a transport
 *   failure the staged bytes remain and the same stage may be committed again.
 */
interface NotesService {
    /** Bind to the current accepted runtime epoch; does not open the store. */
    suspend fun bind(epoch: Long): NotesBinding

    suspend fun status(): NotesStatus

    suspend fun library(): NotesLibrarySummary

    suspend fun notebooks(): List<Notebook>

    suspend fun createNotebook(title: String): Notebook

    suspend fun renameNotebook(notebookID: String, title: String)

    /**
     * Deletes only an empty notebook; a populated notebook is refused.
     * Default keeps pre-foundation consumer fakes source-compatible; the real
     * native adapter overrides it.
     */
    suspend fun deleteNotebook(notebookID: String): Unit =
        throw NotesException("unsupportedAction", "notebookDeleteUnavailable", retryable = false)

    suspend fun documents(includeTrash: Boolean = false, limit: Int = 500): NotesDocumentPage

    suspend fun recentDocuments(limit: Int = 50): List<NoteDocumentSummary>

    /** Full validated document JSON (bounded by the native response cap). */
    suspend fun document(documentID: String): NoteDocument

    suspend fun documentSummary(documentID: String): NoteDocumentSummary

    suspend fun createDocument(request: NotesCreateDocument): NoteDocument

    suspend fun duplicateDocument(request: NotesDuplicateDocument): NoteDocument

    /** Explicit user action: creates a new notebook document. Never a chat side effect. */
    suspend fun saveMessage(request: NotesSaveMessage): NoteDocument

    suspend fun createLinkedMindMap(
        documentID: String,
        expectedRevision: Int,
        title: String,
        pageID: String? = null,
    ): NoteDocument

    suspend fun apply(request: NotesApplyRequest): NoteDocument

    suspend fun undo(documentID: String, expectedRevision: Int, redo: Boolean = false): NoteDocument

    suspend fun setTrashed(documentID: String, expectedRevision: Int, trashed: Boolean): NoteDocument

    suspend fun deletePermanently(documentID: String, expectedRevision: Int)

    suspend fun history(documentID: String): NoteHistoryState

    suspend fun markOpened(documentID: String)

    suspend fun setFavorite(documentID: String, expectedRevision: Int, isFavorite: Boolean): NoteDocument

    suspend fun setTags(documentID: String, expectedRevision: Int, tags: List<String>): NoteDocument

    suspend fun cover(documentID: String): NoteCoverState

    /** `resourceID == null` restores the automatic cover. */
    suspend fun applyCover(request: NotesCoverRequest): NoteDocument

    suspend fun cacheOfficePreview(
        documentID: String,
        sourceResourceID: String,
        previewResourceID: String,
        expectedRevision: Int,
    ): NoteDocument

    /** Historical editor baseline, or null when the revision aged out. */
    suspend fun editingSnapshot(documentID: String, revision: Int): NoteDocument?

    suspend fun search(query: String, limit: Int = 50): List<NoteDocumentSummary>

    /** Native-owned visual index identity; default keeps old consumer fakes compiling. */
    suspend fun pageOCRState(documentID: String, pageID: String): NotesPageOCRState =
        throw NotesException("unsupportedAction", "ocrStateUnavailable", retryable = false)

    /**
     * Large paste / text import. Default implementations from an older
     * backend get a typed refusal, never a truncated success; the current
     * native service overrides this with a real staged transaction.
     */
    suspend fun beginTextWrite(request: NotesTextWrite): NotesTextImport =
        throw NotesException("unsupportedAction", "textStagingUnavailable", retryable = false)

    // MARK: - Immutable resources

    suspend fun beginResourceImport(fileName: String, mediaType: String, byteCount: Long): NotesResourceImport

    suspend fun resourceMetadata(resourceID: String): NoteResourceRecord

    suspend fun readResource(
        resourceID: String,
        offset: Long,
        maxBytes: Int = NotesProtocol.DEFAULT_READ_BYTES,
    ): NoteResourceChunk

    suspend fun discardUnreferencedResource(resourceID: String): Boolean

    suspend fun collectDeletedResources(): Int

    // MARK: - Notes-local assistant grants

    suspend fun grantAccess(conversationID: String, documentID: String, canEdit: Boolean)

    suspend fun bindAssistant(conversationID: String, documentID: String, canEdit: Boolean)

    suspend fun revokeAccess(conversationID: String, documentID: String)

    suspend fun grants(conversationID: String): Map<String, Boolean>

    suspend fun scopedDocuments(conversationID: String): List<NoteDocumentSummary>

    suspend fun setAssistantFocus(conversationID: String, documentID: String, pageID: String? = null)

    suspend fun runtimeContext(conversationID: String): String?

    // MARK: - Portable archive

    suspend fun beginArchiveExport(documentID: String, expectedRevision: Int): NotesArchiveExport

    suspend fun beginArchiveImport(byteCount: Long): NotesArchiveImport

    // MARK: - Proposals (read now; apply/preview is the assistant UI lane)

    suspend fun pendingProposals(documentID: String? = null): List<NotesProposalSummary>

    // MARK: - Events

    suspend fun pollEvents(cursor: Long, limit: Int = 128): NotesEventBatch

    /** Drops the host's service binding; native retirement also does this. */
    suspend fun close()
}

interface NotesTextImport {
    val stageID: String
    val chunkBytes: Int
    val totalBytes: Long

    suspend fun append(chunk: ByteArray): Long

    /** One atomic document edit (one undo) or one new document. */
    suspend fun commit(): NoteDocument

    suspend fun abort()
}

interface NotesResourceImport {
    val stageID: String
    val chunkBytes: Int
    val totalBytes: Long

    /** Returns the number of bytes received so far. */
    suspend fun append(chunk: ByteArray): Long

    suspend fun commit(): ImportedResource

    /** Best effort: releases the native staging file. Never mutates a document. */
    suspend fun abort()
}

interface NotesArchiveImport {
    val stageID: String
    val chunkBytes: Int
    val totalBytes: Long

    suspend fun append(chunk: ByteArray): Long

    suspend fun commit(notebookID: String? = null): List<NoteDocumentSummary>

    suspend fun abort()
}

interface NotesArchiveExport {
    val handle: String
    val totalBytes: Long
    val fileName: String

    suspend fun read(offset: Long, maxBytes: Int = NotesProtocol.DEFAULT_READ_BYTES): NotesArchiveChunk

    suspend fun close()
}

class NotesException(
    val code: String,
    val reason: String? = null,
    val retryable: Boolean = false,
) : Exception(reason?.let { "$code: $it" } ?: code) {
    val isConflict: Boolean get() = code == "conflict"
    val needsRebind: Boolean get() = code == "staleGeneration" || code == "notesNotBound"
}

object NotesProtocol {
    const val VERSION = 4
    const val SCHEMA = "floe.notes/4"
    const val MAX_REQUEST_BYTES = 65_536
    const val MAX_RESPONSE_BYTES = 16_777_216
    const val CHUNK_BYTES = 44_000
    const val DEFAULT_READ_BYTES = 262_144
    const val MAX_READ_BYTES = 1_048_576
    const val MAX_RESOURCE_BYTES = 536_870_912L
    const val MAX_ARCHIVE_BYTES = 2_147_483_648L
    const val MAX_STAGED_TEXT_BYTES = 2_097_152L
    const val MAX_EDITS = 10_000
}
