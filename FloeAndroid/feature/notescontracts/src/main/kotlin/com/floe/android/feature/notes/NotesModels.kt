// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes

/**
 * G06 Notes consumer contract, C0/C1.
 *
 * These types mirror the validated `FloeNotes` document model exposed by the
 * native `floe.notes/4` channel. They contain no storage, no JSON transport
 * and no fake in-memory authority: mutation always goes through [NotesService]
 * to the single service-owned NotesStore.
 *
 * Timestamps use the wire representation: milliseconds since 1970 as a
 * `Double` (the native encoder's exact Date strategy). UI code may truncate
 * with `toLong()` when an Instant is needed.
 */

enum class NoteDocumentKind(val wire: String) {
    NOTEBOOK("notebook"), MIND_MAP("mindMap"), OFFICE("office"), ENGINEERING("engineering");
    companion object { fun fromWire(value: String): NoteDocumentKind? = entries.firstOrNull { it.wire == value } }
}

enum class NotePaper(val wire: String) {
    PLAIN("plain"), RULED("ruled"), GRID("grid");
    companion object { fun fromWire(value: String): NotePaper? = entries.firstOrNull { it.wire == value } }
}

enum class NoteSourceSpace(val wire: String) {
    NOTES("notes"), CANVAS("canvas"), WORKSPACE("workspace");
    companion object { fun fromWire(value: String): NoteSourceSpace? = entries.firstOrNull { it.wire == value } }
}

enum class NoteElementKind(val wire: String) {
    TEXT("text"), IMAGE("image"), RECTANGLE("rectangle"), ELLIPSE("ellipse"), LINE("line"), ARROW("arrow");
    companion object { fun fromWire(value: String): NoteElementKind? = entries.firstOrNull { it.wire == value } }
}

enum class MindMapAttachmentKind(val wire: String) {
    IMAGE("image"), DOCUMENT("document"), AUDIO("audio"), VIDEO("video"), FILE("file");
    companion object { fun fromWire(value: String): MindMapAttachmentKind? = entries.firstOrNull { it.wire == value } }
}

enum class NoteCoverMode { AUTOMATIC, CUSTOM }

data class NoteRect(
    val x: Double = 0.0,
    val y: Double = 0.0,
    val width: Double = 240.0,
    val height: Double = 120.0,
) {
    init {
        require(x.isFinite() && y.isFinite() && width.isFinite() && height.isFinite()) { "frame must be finite" }
        require(width > 0.0 && height > 0.0) { "frame must have positive size" }
    }
}

data class NoteTextSlice(val start: Int, val count: Int, val total: Int? = null) {
    init {
        require(start >= 0) { "slice start" }
        require(count > 0) { "slice count" }
        if (total != null) require(start <= total && count <= total - start) { "slice bounds" }
    }
}

data class NoteSourceReference(
    val space: NoteSourceSpace = NoteSourceSpace.NOTES,
    val documentID: String,
    val revision: Int,
    val pageID: String? = null,
    val nodeID: String? = null,
    val region: NoteRect? = null,
    val recordingSeconds: Double? = null,
) {
    init {
        require(documentID.isNotBlank()) { "source document identity" }
        require(revision >= 0) { "source revision" }
    }
}

data class NoteElement(
    val id: String,
    val kind: NoteElementKind = NoteElementKind.TEXT,
    val frame: NoteRect = NoteRect(),
    val text: String = "",
    val resourceID: String? = null,
    val color: String = "#202020",
    val fontSize: Double = 20.0,
    val textFormat: String? = null,
    val textSourceID: String? = null,
    val textSlice: NoteTextSlice? = null,
    val source: NoteSourceReference? = null,
    val isAIGenerated: Boolean = false,
) {
    init {
        require(id.isNotBlank()) { "element id" }
        require(fontSize.isFinite() && fontSize in 1.0..512.0) { "element font size" }
        if (kind == NoteElementKind.IMAGE) require(resourceID != null) { "image element requires a resource" }
        if (textSourceID != null) {
            require(kind == NoteElementKind.TEXT) { "text source belongs to a text element" }
            require(textSlice != null) { "text source requires a slice" }
        }
    }
    val isMarkdown: Boolean get() = textFormat == "markdown"
}

data class NotePage(
    val id: String,
    val width: Double = 768.0,
    val height: Double = 1024.0,
    val paper: NotePaper = NotePaper.PLAIN,
    val backgroundResourceID: String? = null,
    val pdfPageIndex: Int? = null,
    val drawingResourceID: String? = null,
    val elements: List<NoteElement> = emptyList(),
    val isBookmarked: Boolean = false,
    val extractedText: String? = null,
    val ocrText: String? = null,
    val ocrSourceKey: String? = null,
    val ocrError: String? = null,
    val textExtractionTruncated: Boolean? = null,
) {
    init {
        require(id.isNotBlank()) { "page id" }
        require(width.isFinite() && height.isFinite() && width > 0.0 && height > 0.0) { "page size" }
        require(width <= 16_384.0 && height <= 16_384.0) { "page size bound" }
        if (pdfPageIndex != null) {
            require(pdfPageIndex >= 0 && backgroundResourceID != null) { "PDF page reference" }
        }
        require(elements.size <= 2_000) { "elements per page" }
        require(elements.map { it.id }.toSet().size == elements.size) { "unique element ids" }
        require(elements.count { it.kind == NoteElementKind.IMAGE } <= 64) { "images per page" }
    }

    // OCR source identity is computed by the native FloeNotes model
    // (SHA-256 over the exact page geometry/elements). This contract does not
    // reimplement that algorithm: `ocrSourceKey` is an opaque native token and
    // consumers must not treat a locally computed key as equivalent. A page
    // read that needs current OCR should ask the native service to validate it.
}

data class MindMapAttachment(
    val id: String,
    val resourceID: String,
    val fileName: String,
    val mediaType: String,
    val kind: MindMapAttachmentKind = MindMapAttachmentKind.FILE,
    val caption: String = "",
    val source: NoteSourceReference? = null,
) {
    init {
        require(id.isNotBlank() && resourceID.isNotBlank()) { "attachment identity" }
        require(fileName.isNotBlank() && fileName != "." && fileName != "..") { "attachment file name" }
        require(!fileName.contains('\\') && !fileName.contains(':')) { "attachment file name" }
        require(fileName.encodeToByteArray().size <= 255 && mediaType.encodeToByteArray().size <= 256 && caption.encodeToByteArray().size <= 65_536) { "attachment bounds" }
    }
}

data class NoteMindMapLink(val id: String, val documentID: String, val pageID: String? = null) {
    init { require(id.isNotBlank() && documentID.isNotBlank()) { "link identity" } }
}

data class MindMapPoint(val x: Double, val y: Double) {
    init { require(x.isFinite() && y.isFinite() && kotlin.math.abs(x) <= 100_000.0 && kotlin.math.abs(y) <= 100_000.0) }
}

data class MindMapNode(
    val id: String,
    val parentID: String? = null,
    val title: String,
    val note: String = "",
    val order: Int = 0,
    val isCollapsed: Boolean = false,
    val color: String? = null,
    val imageResourceID: String? = null,
    val attachments: List<MindMapAttachment>? = null,
    val style: Map<String, String>? = null,
    val tags: List<String>? = null,
    val icons: List<String>? = null,
    val direction: Int? = null,
    val branchColor: String? = null,
    val hyperLink: String? = null,
    val isAIGenerated: Boolean? = null,
    val source: NoteSourceReference? = null,
    val position: MindMapPoint? = null,
) {
    init {
        require(id.isNotBlank()) { "node id" }
        require(order >= 0) { "node order" }
        require(title.encodeToByteArray().size <= 65_536 && note.encodeToByteArray().size <= 65_536) { "node text bound" }
        require(direction == null || direction == 0 || direction == 1) { "node direction" }
        require((tags?.size ?: 0) <= 100 && (icons?.size ?: 0) <= 100) { "node tag bound" }
    }
}

data class MindMapConnectionOffset(val x: Double, val y: Double)

data class MindMapConnection(
    val id: String,
    val from: String,
    val to: String,
    val title: String = "",
    val delta1: MindMapConnectionOffset? = null,
    val delta2: MindMapConnectionOffset? = null,
    val bidirectional: Boolean? = null,
    val style: Map<String, String>? = null,
) {
    init {
        require(id.isNotBlank() && from.isNotBlank() && to.isNotBlank()) { "connection identity" }
        require(from != to) { "connection endpoints" }
        require(title.encodeToByteArray().size <= 65_536) { "connection title" }
    }
}

data class MindMapSummary(
    val id: String,
    val label: String,
    val parent: String,
    val start: Int,
    val end: Int,
    val style: Map<String, String>? = null,
) {
    init {
        require(id.isNotBlank() && parent.isNotBlank()) { "summary identity" }
        require(start >= 0 && end >= start) { "summary range" }
        require(label.encodeToByteArray().size <= 65_536) { "summary label" }
    }
}

data class Notebook(val id: String, val title: String, val createdAt: Double) {
    init {
        require(id.isNotBlank() && title.isNotBlank()) { "notebook identity" }
    }
}

data class NoteDocument(
    val schemaVersion: Int = 2,
    val id: String,
    val kind: NoteDocumentKind,
    val notebookID: String? = null,
    val title: String,
    val revision: Int,
    val pages: List<NotePage> = emptyList(),
    val textSources: Map<String, String>? = null,
    val nodes: List<MindMapNode> = emptyList(),
    val connections: List<MindMapConnection> = emptyList(),
    val linkedMindMaps: List<NoteMindMapLink>? = null,
    val mindMapDirection: Int? = null,
    val summaries: List<MindMapSummary>? = null,
    val tags: List<String> = emptyList(),
    val isFavorite: Boolean = false,
    val createdAt: Double,
    val updatedAt: Double,
    val deletedAt: Double? = null,
    val officeResourceID: String? = null,
    val officeFileName: String? = null,
    val officeTextResourceID: String? = null,
    val officeExtractedText: String? = null,
    val officeTextError: String? = null,
    val officePreviewSourceID: String? = null,
    val officePreviewResourceID: String? = null,
    val engineeringResourceID: String? = null,
    val engineeringFileName: String? = null,
    val coverResourceID: String? = null,
    val coverRevision: Int? = null,
) {
    init {
        require(id.isNotBlank() && title.isNotBlank()) { "document identity" }
        require(schemaVersion in 1..2) { "schema version" }
        require(revision >= 0) { "document revision" }
        require(coverRevision == null || coverRevision >= 0) { "cover revision" }
        require(pages.size <= 5_000 && connections.size <= 10_000 && (summaries?.size ?: 0) <= 10_000) {
            "document bounds"
        }
    }

    val coverMode: NoteCoverMode get() = if (coverResourceID != null) NoteCoverMode.CUSTOM else NoteCoverMode.AUTOMATIC
    val normalizedCoverRevision: Int get() = coverRevision ?: 0
    val matchingOfficePreviewResourceID: String?
        get() = if (kind == NoteDocumentKind.OFFICE && officePreviewSourceID == officeResourceID) {
            officePreviewResourceID
        } else null

    val resourceIDs: Set<String>
        get() = buildSet {
            pages.forEach { page ->
                page.backgroundResourceID?.let(::add)
                page.drawingResourceID?.let(::add)
                page.elements.forEach { element -> element.resourceID?.let(::add) }
            }
            nodes.forEach { node ->
                node.imageResourceID?.let(::add)
                node.attachments?.forEach { attachment -> add(attachment.resourceID) }
            }
            listOfNotNull(officeResourceID, engineeringResourceID, coverResourceID,
                matchingOfficePreviewResourceID).forEach(::add)
        }
}

data class NoteDocumentSummary(
    val id: String,
    val kind: NoteDocumentKind,
    val notebookID: String? = null,
    val title: String,
    val revision: Int,
    val pageCount: Int = 0,
    val nodeCount: Int = 0,
    val tags: List<String> = emptyList(),
    val isFavorite: Boolean = false,
    val createdAt: Double,
    val updatedAt: Double,
    val deletedAt: Double? = null,
    val coverResourceID: String? = null,
    val coverRevision: Int? = null,
    val officeFileName: String? = null,
    val engineeringFileName: String? = null,
    val preview: String = "",
)

data class NotesDocumentPage(
    val documents: List<NoteDocumentSummary>,
    val truncated: Boolean,
    val total: Int,
)

data class NotesCounts(
    val documents: Int,
    val trashed: Int,
    val favorites: Int,
    val notebooks: Int,
    val mindMaps: Int,
    val office: Int,
    val engineering: Int,
)

data class NotesLibrarySummary(
    val notebooks: List<Notebook>,
    val counts: NotesCounts,
    val recent: List<NoteDocumentSummary>,
)

data class NoteHistoryState(val canUndo: Boolean, val canRedo: Boolean)

data class NoteCoverState(
    val coverMode: NoteCoverMode,
    val coverResourceID: String?,
    val coverRevision: Int,
    val contentRevision: Int,
)

data class NoteResourceRecord(
    val id: String,
    val hash: String,
    val byteCount: Long,
    val fileName: String,
    val mediaType: String,
) {
    init {
        require(id.isNotBlank() && hash.isNotBlank()) { "resource identity" }
        require(hash.length == 64 && hash.all { it in "0123456789abcdef" }) { "content-addressed hash" }
        require(byteCount >= 0) { "resource size" }
    }
}

data class ImportedResource(
    val resourceID: String,
    val mediaType: String,
    val byteCount: Long,
    val fileName: String,
    val sha256: String,
)

data class NoteResourceChunk(
    val resourceID: String,
    val offset: Long,
    val nextOffset: Long,
    val totalBytes: Long,
    val eof: Boolean,
    val data: ByteArray,
) {
    init {
        require(offset >= 0 && nextOffset >= offset && totalBytes >= 0) { "chunk offsets" }
        require(nextOffset <= totalBytes) { "chunk bounds" }
    }
}

data class NotesArchiveHandle(
    val handle: String,
    val byteCount: Long,
    val fileName: String,
)

data class NotesArchiveChunk(
    val handle: String,
    val offset: Long,
    val nextOffset: Long,
    val totalBytes: Long,
    val eof: Boolean,
    val data: ByteArray,
)

data class NotesEvent(
    val sequence: Long,
    val kind: String,
    val documentID: String? = null,
    val revision: Int? = null,
) {
    init {
        require(sequence > 0) { "event sequence" }
        require(kind.isNotBlank()) { "event kind" }
    }
}

data class NotesEventBatch(
    val sequence: Long,
    val cursor: Long,
    val events: List<NotesEvent>,
    val hasMore: Boolean,
    val resyncRequired: Boolean,
) {
    init {
        require(sequence >= 0 && cursor >= 0) { "event cursor" }
        require(cursor <= sequence) { "cursor cannot lead the service" }
        require(events.map { it.sequence }.toSet().size == events.size) { "unique event sequence" }
    }
}

data class NotesBinding(
    val bound: Boolean,
    val storeOpen: Boolean,
    val fingerprint: String? = null,
)

data class NotesStatus(val bound: Boolean, val storeOpen: Boolean)

data class NotesProposalSummary(
    val id: String,
    val documentID: String,
    val baseRevision: Int,
    val title: String,
    val summary: String,
    val createdAt: Double,
    // Additive G06 C5 fields. Defaults keep C1 consumers source-compatible.
    val baseSHA256: String = "",
    val editCount: Int = 0,
    val status: String = "pending",
    val requiresUserConfirmation: Boolean = true,
    val originConversationID: String? = null,
    val appliedRevision: Int? = null,
    val resolvedDecision: String? = null,
)

enum class NotesTextWriteMode(val wire: String) {
    APPEND_BLOCK("appendBlock"),
    REPLACE_ELEMENT("replaceElement"),
    NEW_DOCUMENT("newDocument"),
}

/**
 * Staged large-text write. The 64 KiB bridge request is only a transport
 * bound; callers stage the exact UTF-8 bytes in chunks and commit one
 * atomic document edit (one undo) or one new document. No truncation.
 */
data class NotesTextWrite(
    val mode: NotesTextWriteMode,
    /** Exact UTF-8 byte count that [NotesTextImport.commit] must receive. */
    val byteCount: Long,
    val documentID: String? = null,
    val pageID: String? = null,
    val elementID: String? = null,
    val expectedRevision: Int? = null,
    /** UI optimistic rebase baseline; not valid for assistant edits. */
    val baseRevision: Int? = null,
    val title: String = "Text",
    val notebookID: String? = null,
    val newDocumentID: String? = null,
    val frame: NoteRect? = null,
    val textFormat: String? = null,
    val fontSize: Double = 16.0,
    /** Stable native edit receipt for the committed batch. */
    val requestID: String? = null,
) {
    init {
        require(byteCount in 1..NotesProtocol.MAX_STAGED_TEXT_BYTES) { "text byte count" }
        require(title.isNotBlank() && title.encodeToByteArray().size <= 512) { "text title" }
        require(fontSize.isFinite() && fontSize in 1.0..512.0) { "text font size" }
        require(textFormat == null || textFormat.encodeToByteArray().size <= 64) { "text format" }
        when (mode) {
            NotesTextWriteMode.APPEND_BLOCK -> {
                require(!documentID.isNullOrBlank() && !pageID.isNullOrBlank() && expectedRevision != null) {
                    "appendBlock identity"
                }
                require(elementID == null && newDocumentID == null) { "appendBlock fields" }
            }
            NotesTextWriteMode.REPLACE_ELEMENT -> {
                require(!documentID.isNullOrBlank() && !pageID.isNullOrBlank() &&
                    !elementID.isNullOrBlank() && expectedRevision != null) { "replaceElement identity" }
                require(newDocumentID == null) { "replaceElement fields" }
            }
            NotesTextWriteMode.NEW_DOCUMENT -> {
                require(documentID == null && pageID == null && elementID == null && expectedRevision == null) {
                    "newDocument fields"
                }
            }
        }
        require(baseRevision == null || baseRevision >= 0) { "rebase baseline" }
        require(expectedRevision == null || expectedRevision >= 0) { "expected revision" }
    }
}

/**
 * Native-owned OCR source identity for one page. `visualIndexKey` is the
 * SHA-256 over the exact page geometry/elements; `ocrSourceKey` is the key
 * under which cached OCR was produced. `current` is true only when the native
 * model considers the cached OCR valid for this page. Consumers must not
 * compute or compare a Kotlin equivalent.
 */
data class NotesPageOCRState(
    val documentID: String,
    val pageID: String,
    val visualIndexKey: String,
    val current: Boolean,
    val ocrSourceKey: String? = null,
    val ocrText: String? = null,
    val ocrError: String? = null,
    // Additive C5 fields: native-derived retry metadata only.
    val indexed: Boolean = current,
    val needsVisualIndex: Boolean = false,
    val retryable: Boolean = false,
) {
    init {
        require(documentID.isNotBlank() && pageID.isNotBlank()) { "OCR page identity" }
        require(visualIndexKey.isNotBlank()) { "visual index key" }
    }
}

// MARK: - G06 C5 proposal authority (additive)

/**
 * Full native proposal projection. It deliberately never carries the
 * model-authored proposal text or the raw edit list: [summary] is the
 * deterministic human-visible difference, and application happens natively
 * through a single-use editor grant.
 */
data class NotesProposal(
    val id: String,
    val documentID: String,
    val baseRevision: Int,
    val baseSHA256: String,
    val title: String,
    val summary: String,
    val editCount: Int,
    val createdAt: Double,
    val status: String,
    val requiresUserConfirmation: Boolean,
    val originConversationID: String? = null,
    val environmentID: String? = null,
    val appliedRevision: Int? = null,
    val resolvedDecision: String? = null,
    val resolvedAt: Double? = null,
) {
    init {
        require(id.isNotBlank() && documentID.isNotBlank()) { "proposal identity" }
        require(baseRevision >= 0) { "proposal base revision" }
        require(baseSHA256.length == 64 && baseSHA256.all { it in "0123456789abcdef" }) {
            "proposal fingerprint"
        }
        require(editCount >= 0) { "proposal edit count" }
        require(appliedRevision == null || appliedRevision >= 0) { "applied revision" }
    }

    val isPending: Boolean get() = status == "pending"
}

data class NotesProposalPreview(
    val documentID: String,
    val baseRevision: Int,
    val baseSHA256: String,
    val title: String,
    val summary: String,
    val editCount: Int,
    val requiresUserConfirmation: Boolean = true,
) {
    init {
        require(documentID.isNotBlank()) { "preview document" }
        require(baseRevision >= 0) { "preview revision" }
        require(baseSHA256.length == 64 && baseSHA256.all { it in "0123456789abcdef" }) {
            "preview fingerprint"
        }
        require(editCount >= 0) { "preview edit count" }
    }
}

data class NotesProposalRequest(
    val documentID: String,
    val expectedRevision: Int,
    val title: String,
    val edits: List<NotesEdit>,
    /** Assistant origin. Present means native read-grant and origin checks apply. */
    val conversationID: String? = null,
    val environmentID: String? = null,
    /** Provenance only; never reused as the apply idempotency key. */
    val sourceRequestID: String? = null,
) {
    init {
        require(documentID.isNotBlank()) { "proposal document" }
        require(expectedRevision >= 0) { "proposal revision" }
        require(title.isNotBlank() && title.encodeToByteArray().size <= 512) { "proposal title" }
        require(edits.isNotEmpty() && edits.size <= NotesProtocol.MAX_EDITS) { "proposal edits" }
        require(environmentID == null || conversationID != null) {
            "an environment requires a conversation origin"
        }
        require(sourceRequestID == null ||
            sourceRequestID.encodeToByteArray().size <= 256) { "proposal source request" }
    }
}

data class NotesProposalApplyRequest(
    val proposalID: String,
    val documentID: String,
    /** Minted by the interactive editor's accept control; never by a model tool. */
    val grantID: String,
    val conversationID: String? = null,
    val environmentID: String? = null,
) {
    init {
        require(proposalID.isNotBlank() && documentID.isNotBlank() && grantID.isNotBlank()) {
            "proposal apply identity"
        }
        require(environmentID == null || conversationID != null) {
            "an environment requires a conversation origin"
        }
    }
}

data class NotesProposalApplyResult(
    val document: NoteDocument,
    val proposalID: String,
    val documentID: String,
    val appliedRevision: Int,
    val replayed: Boolean,
    val status: String,
)

data class NotesProposalGrant(
    val grantID: String,
    val proposalID: String,
    val documentID: String,
    val baseRevision: Int,
    val baseSHA256: String,
    val expiresInSeconds: Long,
) {
    init {
        require(grantID.isNotBlank()) { "grant id" }
        require(expiresInSeconds > 0) { "grant lifetime" }
    }
}

enum class NoteProposalDecision(val wire: String) {
    ACCEPTED("accepted"), REJECTED("rejected"), INVALIDATED("invalidated");

    companion object {
        fun fromWire(value: String): NoteProposalDecision? = entries.firstOrNull { it.wire == value }
    }
}

data class NotesProposalResolveRequest(
    val proposalID: String,
    val decision: NoteProposalDecision,
    val documentID: String? = null,
    val conversationID: String? = null,
    val environmentID: String? = null,
) {
    init {
        require(proposalID.isNotBlank()) { "proposal id" }
        require(decision != NoteProposalDecision.ACCEPTED) {
            "acceptance must commit through applyProposal"
        }
        require(environmentID == null || conversationID != null) {
            "an environment requires a conversation origin"
        }
    }
}

/**
 * One durable decision that the runtime may deliver to [conversationID].
 * `ready == false` means native crash-repair could not finalize it yet; it must
 * not be delivered or acknowledged. [content] is structured user-decision text,
 * never model-authored proposal content.
 */
data class NotesProposalDecisionEnvelope(
    val intentID: String,
    val eventID: String,
    val proposalID: String,
    val documentID: String,
    val conversationID: String,
    val decision: NoteProposalDecision,
    val baseRevision: Int,
    val baseSHA256: String,
    val phase: String,
    val ready: Boolean,
    val content: String,
    val environmentID: String? = null,
    val revision: Int? = null,
    val lastFailure: String? = null,
    val createdAt: Double = 0.0,
    val updatedAt: Double = 0.0,
) {
    init {
        require(intentID.isNotBlank() && eventID.isNotBlank()) { "decision identity" }
        require(proposalID.isNotBlank() && documentID.isNotBlank() && conversationID.isNotBlank()) {
            "decision scope"
        }
    }

    val deliverable: Boolean get() = ready && phase == "recorded"
}

data class NotesProposalOutboxPage(
    val decisions: List<NotesProposalDecisionEnvelope>,
    val total: Int,
    val truncated: Boolean,
)

data class NotesProposalDecisionAck(
    val eventID: String,
    val proposalID: String,
    val decision: NoteProposalDecision,
    val deliveredAt: Double,
    val alreadyDelivered: Boolean,
)

// MARK: - G06 C5 source-bound index cache (additive)

enum class NotesIndexCacheStatus(val wire: String) {
    APPLIED("applied"), UNCHANGED("unchanged"), STALE("stale"), FAILED("failed");

    companion object {
        fun fromWire(value: String): NotesIndexCacheStatus? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * Typed result of one OCR / Office-text cache write. A stale result is a
 * successful action result (not a transport error) and never modified the
 * document or search index; [retryable] is true for a stored provider error
 * and false for a stale source identity.
 */
data class NotesIndexCacheReceipt(
    val status: NotesIndexCacheStatus,
    val documentID: String,
    val documentRevision: Int,
    val sourceKey: String,
    val indexed: Boolean,
    val retryable: Boolean,
    val currentKey: String? = null,
    val storedKey: String? = null,
    val textLength: Int? = null,
    val error: String? = null,
    val reason: String? = null,
) {
    init {
        require(documentID.isNotBlank() && sourceKey.isNotBlank()) { "cache identity" }
        require(documentRevision >= 0) { "cache revision" }
        require(textLength == null || textLength >= 0) { "cache text length" }
    }

    val applied: Boolean get() = status == NotesIndexCacheStatus.APPLIED
    val stale: Boolean get() = status == NotesIndexCacheStatus.STALE
}

data class NotesPageOCRRequest(
    val documentID: String,
    val pageID: String,
    /** Opaque value returned by [NotesService.pageOCRState]; never computed locally. */
    val sourceKey: String,
    val text: String? = null,
    val error: String? = null,
    val expectedRevision: Int? = null,
    /** Assistant origin; native requires a live read grant when present. */
    val conversationID: String? = null,
) {
    init {
        require(documentID.isNotBlank() && pageID.isNotBlank()) { "OCR cache page identity" }
        require(sourceKey.isNotBlank()) { "OCR source key" }
        require(expectedRevision == null || expectedRevision >= 0) { "OCR revision fence" }
    }
}

data class NotesOfficeTextRequest(
    val documentID: String,
    val sourceResourceID: String,
    val text: String? = null,
    val error: String? = null,
    val expectedRevision: Int? = null,
    /** Assistant origin; native requires a live read grant when present. */
    val conversationID: String? = null,
) {
    init {
        require(documentID.isNotBlank() && sourceResourceID.isNotBlank()) {
            "Office cache identity"
        }
        require(expectedRevision == null || expectedRevision >= 0) { "Office revision fence" }
    }
}

data class NotesOfficeTextState(
    val documentID: String,
    val revision: Int,
    val current: Boolean,
    val retryable: Boolean,
    val sourceResourceID: String? = null,
    val sourceKey: String? = null,
    val cachedResourceID: String? = null,
    val textLength: Int? = null,
    val error: String? = null,
)

// MARK: - G06 C5 conflict reviews (additive)

data class NotesConflictReviewSummary(
    val id: String,
    val documentID: String,
    val currentRevision: Int,
    val currentTitle: String,
    val copyDocumentID: String,
    val copyRevision: Int,
    val copyTitle: String,
    val title: String,
    val editCount: Int,
) {
    init {
        require(id.isNotBlank() && documentID.isNotBlank() && copyDocumentID.isNotBlank()) {
            "conflict review identity"
        }
        require(documentID != copyDocumentID) { "a review needs two independent documents" }
        require(currentRevision >= 0 && copyRevision >= 0) { "conflict review revisions" }
        require(editCount >= 0) { "conflict review edit count" }
    }
}

data class NotesConflictReviewPage(
    val reviews: List<NotesConflictReviewSummary>,
    val total: Int,
    val truncated: Boolean,
)

/** Full prior-edit review; replacement/keep-both always retains [copy]. */
data class NoteEditConflict(
    val id: String,
    val current: NoteDocument,
    val copy: NoteDocument,
    val edits: List<NotesEdit>,
    val title: String,
) {
    init {
        require(id.isNotBlank()) { "conflict review id" }
        require(current.id != copy.id) { "a review needs two independent documents" }
        require(edits.isNotEmpty() && edits.size <= NotesProtocol.MAX_EDITS) {
            "conflict review edits"
        }
    }
}

data class NotesConflictReviewRequest(
    val documentID: String,
    val expectedRevision: Int,
    val copyDocumentID: String,
    val expectedCopyRevision: Int,
    val title: String,
    val edits: List<NotesEdit>,
    val reviewID: String? = null,
    /** Assistant origin; native requires a live read grant on both documents. */
    val conversationID: String? = null,
) {
    init {
        require(documentID.isNotBlank() && copyDocumentID.isNotBlank()) {
            "conflict review identity"
        }
        require(documentID != copyDocumentID) { "a review needs two independent documents" }
        require(expectedRevision >= 0 && expectedCopyRevision >= 0) { "conflict review revisions" }
        require(title.isNotBlank() && title.encodeToByteArray().size <= 512) {
            "conflict review title"
        }
        require(edits.isNotEmpty() && edits.size <= NotesProtocol.MAX_EDITS) {
            "conflict review edits"
        }
        require(reviewID == null || reviewID.isNotBlank()) { "conflict review id" }
    }
}
