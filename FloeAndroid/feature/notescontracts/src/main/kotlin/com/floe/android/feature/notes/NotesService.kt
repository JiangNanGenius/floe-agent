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

    /**
     * Commit one complete user-intent edit plan as exactly one native
     * transaction: one document revision, one undo group and one durable
     * receipt, even when the serialized plan is larger than the 64 KiB bridge
     * request.
     *
     * The default is the ordinary [apply]. That is a real single batch for a
     * plan that fits the transport, and an honest typed `requestTooLarge` for
     * one that does not — never a silent truncated/partial success. A backend
     * with the native staged edit-batch route implements
     * [NotesAtomicBatchService] and overrides this method; only then may a
     * caller treat a plan above the bridge bound as atomic.
     *
     * Retrying the same request must reuse the same [NotesApplyRequest.requestID]
     * so native receipt de-duplication can reconcile an uncertain dispatch.
     */
    suspend fun applyAtomically(request: NotesApplyRequest): NoteDocument = apply(request)

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

    /**
     * Assistant-owned import stage. The native service requires a live Notes
     * edit grant for [documentID] at begin *and* commit, then records the
     * imported resource as usable by this exact conversation/document. The
     * three-argument [beginResourceImport] above remains the UI/human path.
     */
    suspend fun beginOwnedResourceImport(
        fileName: String,
        mediaType: String,
        byteCount: Long,
        conversationID: String,
        documentID: String,
    ): NotesResourceImport =
        throw NotesException("unsupportedAction", "ownedResourceImportUnavailable", retryable = false)

    suspend fun resourceMetadata(resourceID: String): NoteResourceRecord

    suspend fun readResource(
        resourceID: String,
        offset: Long,
        maxBytes: Int = NotesProtocol.DEFAULT_READ_BYTES,
    ): NoteResourceChunk

    /**
     * Assistant-scoped resource read. Native requires the bytes to be
     * referenced by a document this conversation can read, or imported through
     * this conversation's owned stage. [documentID] narrows the check further
     * (that exact document must reference the resource or own the import).
     * A resource referenced only by another note is denied.
     */
    suspend fun readAssistantResource(
        resourceID: String,
        offset: Long,
        conversationID: String,
        documentID: String? = null,
        maxBytes: Int = NotesProtocol.DEFAULT_READ_BYTES,
    ): NoteResourceChunk =
        throw NotesException("unsupportedAction", "assistantResourceReadUnavailable", retryable = false)

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

    // MARK: - Proposals (G06 C5 native authority)

    suspend fun pendingProposals(documentID: String? = null): List<NotesProposalSummary>

    /**
     * Validate an edit batch against one exact revision without persisting.
     * With a conversation this requires a live Notes read grant; it never
     * creates a proposal and never touches the document.
     */
    suspend fun previewProposal(request: NotesProposalRequest): NotesProposalPreview =
        throw NotesException("unsupportedAction", "proposalPreviewUnavailable", retryable = false)

    /**
     * Persist one durable proposal from validated edits. The native service
     * recomputes the summary/fingerprint and stores the exact `(conversation,
     * environment)` origin; the proposal text is never treated as an edit.
     */
    suspend fun propose(request: NotesProposalRequest): NotesProposal =
        throw NotesException("unsupportedAction", "proposalCreateUnavailable", retryable = false)

    /**
     * Pending proposal projections for the editor or, when [conversationID] is
     * present, only proposals whose exact origin and document grant match.
     */
    suspend fun proposals(
        documentID: String? = null,
        conversationID: String? = null,
        environmentID: String? = null,
        limit: Int = 100,
    ): List<NotesProposalSummary> =
        throw NotesException("unsupportedAction", "proposalListUnavailable", retryable = false)

    /** Read a stored proposal, origin-scoped when [conversationID] is present. */
    suspend fun proposal(
        proposalID: String,
        documentID: String,
        conversationID: String? = null,
        environmentID: String? = null,
    ): NotesProposal =
        throw NotesException("unsupportedAction", "proposalReadUnavailable", retryable = false)

    /**
     * Interactive-editor action: mint the single-use grant for [proposalID].
     * **Never expose this to a model tool.** The editor's accept control owns
     * this call; [applyProposal] consumes the grant.
     */
    suspend fun issueProposalGrant(proposalID: String, documentID: String): NotesProposalGrant =
        throw NotesException("unsupportedAction", "proposalGrantUnavailable", retryable = false)

    /**
     * Apply a stored proposal. Assistant calls carry the originating
     * conversation/environment and need a live edit grant; the native service
     * rechecks the exact document revision/fingerprint and edits its own store.
     */
    suspend fun applyProposal(request: NotesProposalApplyRequest): NotesProposalApplyResult =
        throw NotesException("unsupportedAction", "proposalApplyUnavailable", retryable = false)

    /**
     * Record a rejected/invalidated decision durably (acceptance must commit
     * through [applyProposal]). Origin and Notes grants are rechecked.
     */
    suspend fun resolveProposal(request: NotesProposalResolveRequest): NotesProposal =
        throw NotesException("unsupportedAction", "proposalResolveUnavailable", retryable = false)

    /**
     * Final decision events the runtime may deliver to a conversation. Native
     * crash-repair runs first; `ready == false` decisions must wait. This call
     * does not deliver or mark anything delivered.
     */
    suspend fun decisionOutbox(
        conversationID: String? = null,
        limit: Int = 64,
    ): NotesProposalOutboxPage =
        throw NotesException("unsupportedAction", "proposalOutboxUnavailable", retryable = false)

    /**
     * Acknowledge that the runtime actually delivered this exact event. The
     * event id must match the intent's deterministic decision id; re-acking is
     * idempotent.
     */
    suspend fun acknowledgeDecision(intentID: String, eventID: String): NotesProposalDecisionAck =
        throw NotesException("unsupportedAction", "proposalAckUnavailable", retryable = false)

    // MARK: - Source-bound OCR / Office text cache

    /**
     * Persist one OCR result only under the current native [NotesPageOCRRequest.sourceKey].
     * A stale late result returns `status == STALE` and writes nothing.
     */
    suspend fun cachePageOCR(request: NotesPageOCRRequest): NotesIndexCacheReceipt =
        throw NotesException("unsupportedAction", "pageOCRCacheUnavailable", retryable = false)

    /** Persist Office full text only for the document's exact immutable resource. */
    suspend fun cacheOfficeText(request: NotesOfficeTextRequest): NotesIndexCacheReceipt =
        throw NotesException("unsupportedAction", "officeTextCacheUnavailable", retryable = false)

    suspend fun officeTextState(documentID: String): NotesOfficeTextState =
        throw NotesException("unsupportedAction", "officeTextStateUnavailable", retryable = false)

    // MARK: - Edit-conflict reviews

    /**
     * Review descriptors, newest/oldest store order. With a conversation only
     * reviews whose current and copy documents are both readable are returned.
     */
    suspend fun conflictReviews(
        documentID: String? = null,
        conversationID: String? = null,
        limit: Int = 50,
    ): NotesConflictReviewPage =
        throw NotesException("unsupportedAction", "conflictReviewsUnavailable", retryable = false)

    suspend fun conflictReview(reviewID: String, conversationID: String? = null): NoteEditConflict =
        throw NotesException("unsupportedAction", "conflictReviewUnavailable", retryable = false)

    /**
     * Retain both versions: store the current/copy documents at their exact
     * revisions plus the edits that can replay onto current. Both documents
     * are retained; no overwrite-to-resolve shortcut exists.
     */
    suspend fun saveConflictReview(request: NotesConflictReviewRequest): NotesConflictReviewSummary =
        throw NotesException("unsupportedAction", "conflictReviewSaveUnavailable", retryable = false)

    /** Drop only the review row; both documents and all resources remain. */
    suspend fun keepBothConflictVersions(reviewID: String, conversationID: String? = null): Unit =
        throw NotesException("unsupportedAction", "conflictReviewKeepBothUnavailable", retryable = false)

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

/**
 * Capability marker for a [NotesService] whose [NotesService.applyAtomically]
 * really stages the serialized plan in bounded chunks and commits it as ONE
 * native `document.apply`-equivalent transaction. The editor uses the
 * whole-plan path only for a service with this marker; a legacy consumer fake
 * without it keeps the older per-chunk behaviour instead of being told a
 * chunked save was atomic.
 */
interface NotesAtomicBatchService

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
    /**
     * Serialized `[NoteEdit]` JSON sent inline by `applyAtomically`. The v4
     * request envelope plus all ordinary apply fields stays below the 65,536
     * request bound at this size (the exact serialized plan is measured).
     */
    const val MAX_ATOMIC_INLINE_EDIT_BYTES = 60_000
    /**
     * Native staged edit-batch bound. Above this the service returns typed
     * `requestTooLarge` before creating any stage; it never truncates or
     * commits a prefix as if the plan had been saved.
     */
    const val MAX_STAGED_EDIT_BATCH_BYTES = 8_388_608L
    const val MAX_EDITS = 10_000
}
