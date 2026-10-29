// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.api

import android.view.View
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePaper
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.NoteSourceReference
import com.floe.android.feature.notes.ui.presentation.NotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.NotesRecoveryStore

/**
 * G06 Notes host ports.
 *
 * The presentation module owns no media renderer, Office engine, model
 * coordinator, SAF picker or process-wide file share. Every such effect is an
 * explicit typed call implemented by the App integration host:
 *
 * * [NotesMediaPort] — implement over `core:notesmedia` (stable
 *   `NotesMedia` factory / `InkCanvasView` / PDF sessions / export engine).
 * * [NotesOfficePort] — implement over the existing `core:officeengine`
 *   viewer launch/save-copy path; never a second Office engine.
 * * [NotesAssistantPort] — implement over the existing conversation/model
 *   coordinator. The UI binds the Notes-local grant through [NotesService]
 *   itself before the first turn.
 * * [NotesExchangePort] — SAF/ActivityResult import, share-sheet stream and
 *   read-only attachment launch. No file path or URI is stored by this module.
 *
 * Every suspend function may be called from the main thread and must not block
 * it. Hosts throw [NotesPortFailureException] for typed failures. A host must not
 * return a successful-looking value when the effect did not happen.
 */
public class NotesPortFailureException(
    public val failure: NotesPortFailure,
) : Exception(failure.detail ?: failure.code)

public data class NotesPortFailure(
    public val code: String,
    public val detail: String? = null,
) {
    public companion object {
        public const val NOT_CONFIGURED: String = "notConfigured"
        public const val UNAVAILABLE: String = "portUnavailable"
        public const val PERMISSION_DENIED: String = "permissionDenied"
        public const val UNSUPPORTED: String = "unsupported"
        public const val NOT_FOUND: String = "notFound"
        public const val BUSY: String = "busy"
        public const val CANCELLED: String = "cancelled"
        public const val FAILED: String = "failed"
    }
}

/* ------------------------------- exchange -------------------------------- */

public enum class NotesImportKind { PDF, IMAGE, TEXT, OFFICE, ENGINEERING, ARCHIVE, FILE }

/**
 * A host-owned readable file. The stream is valid only until [close]; chunked
 * Notes import reads it sequentially and never assumes random access.
 */
public class NotesPickedFile(
    public val fileName: String,
    public val mediaType: String,
    public val byteCount: Long,
    public val read: suspend (offset: Long, maxBytes: Int) -> ByteArray,
    public val close: () -> Unit,
)

public class NotesShareStreamRequest(
    public val fileName: String,
    public val mediaType: String,
    public val totalBytes: Long,
    public val read: suspend (offset: Long, maxBytes: Int) -> ByteArray,
)

public class NotesShareTextRequest(
    public val fileName: String,
    public val mediaType: String,
    public val text: String,
)

public data class NotesShareOutcome(
    public val launched: Boolean,
    /** Redacted label only (for example “Files”); never a filesystem path. */
    public val locationLabel: String? = null,
)

public class NotesOpenAttachmentRequest(
    public val resourceID: String,
    public val fileName: String,
    public val mediaType: String,
)

public sealed interface NotesOpenAttachmentOutcome {
    public data object Opened : NotesOpenAttachmentOutcome
    public data class Unavailable(public val failure: NotesPortFailure) : NotesOpenAttachmentOutcome
    public data class Failed(public val failure: NotesPortFailure) : NotesOpenAttachmentOutcome
}

public interface NotesExchangePort {
    /**
     * Present the platform picker. Returns null only when the user cancels;
     * missing/unavailable system integration throws [NotesPortFailureException].
     */
    public suspend fun pickFile(
        kinds: Set<NotesImportKind>,
        suggestedName: String? = null,
    ): NotesPickedFile?

    /** Stream a prepared export into the platform share/save surface. */
    public suspend fun shareStream(request: NotesShareStreamRequest): NotesShareOutcome

    /** Share a small text artifact (outline/plain text) through the same surface. */
    public suspend fun shareText(request: NotesShareTextRequest): NotesShareOutcome

    /** Open an imported attachment read-only through an existing platform handler. */
    public suspend fun openAttachment(request: NotesOpenAttachmentRequest): NotesOpenAttachmentOutcome
}

/* --------------------------------- media --------------------------------- */

public data class NotesMediaCapabilities(
    public val pdfRendering: Boolean = false,
    public val pdfThumbnails: Boolean = false,
    public val pdfTextSearch: Boolean = false,
    public val pdfPasswordUnlock: Boolean = false,
    public val inkAuthoring: Boolean = false,
    public val inkEditablePersistence: Boolean = false,
    public val imageExport: Boolean = false,
    public val pdfExport: Boolean = false,
    public val systemPrint: Boolean = false,
)

/** Chunked resource reader backed by the real [com.floe.android.feature.notes.NotesService]. */
public fun interface NotesResourceReader {
    public suspend fun read(resourceID: String, offset: Long, maxBytes: Int): ByteArray
}

public class NotesPdfOpenRequest(
    public val documentID: String,
    public val resourceID: String,
    /** Foundation `NoteResourceRecord.hash`; the host verifies it, never registers it. */
    public val sha256: String,
    public val byteCount: Long,
    public val fileName: String,
    public val mediaType: String,
    public val read: NotesResourceReader,
)

public data class NotesPdfPageSize(
    public val widthPt: Float,
    public val heightPt: Float,
)

public data class NotesNormalizedRect(
    public val left: Float,
    public val top: Float,
    public val right: Float,
    public val bottom: Float,
) {
    init {
        require(left.isFinite() && top.isFinite() && right.isFinite() && bottom.isFinite()) { "search rect" }
    }
}

public data class NotesPdfSearchHit(
    public val pageIndex: Int,
    public val snippet: String,
    public val rects: List<NotesNormalizedRect> = emptyList(),
)

/**
 * Mirrors the media layer's typed outcome. `NeedsOcr` means the platform text
 * transaction is unavailable on this API/engine and the UI must say so rather
 * than show a false empty result; no in-process parser is opened to fake it.
 */
public sealed interface NotesPdfSearchOutcome {
    public data class Matches(
        public val hits: List<NotesPdfSearchHit>,
        public val truncated: Boolean = false,
    ) : NotesPdfSearchOutcome
    public data object NoMatches : NotesPdfSearchOutcome
    public data class NeedsOcr(public val pagesWithoutText: List<Int> = emptyList()) : NotesPdfSearchOutcome
    public data class Unavailable(public val reason: String) : NotesPdfSearchOutcome
    public data object StaleSource : NotesPdfSearchOutcome
}

public sealed interface NotesPdfOpenOutcome {
    public data class Opened(public val handle: NotesPdfHandle) : NotesPdfOpenOutcome
    public data object PasswordRequired : NotesPdfOpenOutcome
    public data class Unavailable(public val failure: NotesPortFailure) : NotesPdfOpenOutcome
    public data class Failed(public val failure: NotesPortFailure) : NotesPdfOpenOutcome
}

/**
 * A host-owned verified PDF session. Rendering returns encoded PNG/JPEG bytes
 * that the UI decodes; this module never parses PDF or owns a renderer.
 */
public interface NotesPdfHandle {
    public val documentID: String
    public val resourceID: String
    public val pageCount: Int
    public fun pageSize(pageIndex: Int): NotesPdfPageSize?
    public suspend fun renderPage(pageIndex: Int, targetWidthPx: Int): ByteArray
    public suspend fun search(query: String, limit: Int, matchCase: Boolean): NotesPdfSearchOutcome
    public suspend fun close()
}

public data class NotesExportElement(
    public val kind: NoteElementKind,
    public val frame: NoteRect,
    public val text: String,
    public val color: String,
    public val fontSize: Double,
    public val isMarkdown: Boolean,
    public val imageResourceID: String? = null,
)

public data class NotesExportPage(
    public val pageID: String,
    public val widthPt: Float,
    public val heightPt: Float,
    public val paper: NotePaper,
    public val pdfPageIndex: Int? = null,
    public val pdfResourceID: String? = null,
    public val drawingResourceID: String? = null,
    public val backgroundResourceID: String? = null,
    public val elements: List<NotesExportElement> = emptyList(),
)

public class NotesPdfExportRequest(
    public val documentID: String,
    public val title: String,
    public val pages: List<NotesExportPage>,
    public val pdfResourceID: String?,
    public val pdfSha256: String? = null,
    public val pdfByteCount: Long? = null,
    public val fileName: String,
    public val read: NotesResourceReader,
)

public class NotesPageImageExportRequest(
    public val documentID: String,
    public val page: NotesExportPage,
    public val fileName: String,
    public val targetWidthPx: Int,
    public val read: NotesResourceReader,
)

public class NotesExportedStream(
    public val fileName: String,
    public val mediaType: String,
    public val totalBytes: Long,
    public val read: suspend (offset: Long, maxBytes: Int) -> ByteArray,
    public val close: () -> Unit,
)

public sealed interface NotesPrintOutcome {
    public data object Launched : NotesPrintOutcome
    public data class Unavailable(public val failure: NotesPortFailure) : NotesPrintOutcome
    public data class Failed(public val failure: NotesPortFailure) : NotesPrintOutcome
}

public class NotesPrintRequest(
    public val jobName: String,
    public val stream: NotesExportedStream,
)

public enum class NotesInkToolKind { PEN, MARKER, ERASER, LASSO }

public data class NotesInkToolSpec(
    public val kind: NotesInkToolKind,
    public val colorHex: String,
    public val width: Float,
    public val fingerDrawing: Boolean,
    public val penOnly: Boolean,
)

/**
 * Create-time binding for one page. [onDrawingChanged] is invoked on the main
 * thread with the complete current drawing after a stroke/erase/clear; the
 * presentation layer imports and applies it, or keeps it for recovery.
 */
public class NotesInkCreateRequest(
    public val documentID: String,
    public val pageID: String,
    public val pageWidthPt: Float,
    public val pageHeightPt: Float,
    public val tool: NotesInkToolSpec,
    public val onDrawingChanged: (ByteArray) -> Unit,
)

/**
 * Host-owned stable `androidx.ink` authoring View for one page. The UI only
 * hosts [view]; all stroke/selection/undo state inside it belongs to the
 * media layer. Returning false from [undo]/[redo]/[deleteSelection] means the
 * operation did not happen.
 */
public interface NotesInkSurface {
    public val view: View
    /**
     * True when the host preserved the existing drawing but cannot author it
     * on this platform (for example Apple PencilKit bytes). The UI must show a
     * preserved/read-only state instead of presenting a blank editable canvas.
     * Default false keeps existing hosts source-compatible.
     */
    public val isReadOnly: Boolean get() = false
    public fun setDrawing(drawing: ByteArray?)
    public fun currentDrawing(): ByteArray?
    public fun setTool(tool: NotesInkToolSpec)
    /** False lets Compose handle element selection while strokes still render. */
    public fun setInteractionEnabled(enabled: Boolean)
    public fun undo(): Boolean
    public fun redo(): Boolean
    public val canUndo: Boolean
    public val canRedo: Boolean
    public fun deleteSelection(): Boolean
    public fun selectionCount(): Int
    /** Live selection updates from the App-owned ink surface. */
    public fun setOnSelectionChanged(listener: ((Int) -> Unit)?) {}
    public suspend fun captureSelectionPng(maxWidthPx: Int = 1024): ByteArray?
    public fun dispose()
}

public class NotesImageProbeRequest(
    public val fileName: String,
    public val mediaType: String,
    public val byteCount: Long,
    public val read: suspend (offset: Long, maxBytes: Int) -> ByteArray,
)

public data class NotesImageInfo(
    public val width: Int,
    public val height: Int,
    public val mediaType: String,
)

public class NotesCoverImageRequest(
    public val fileName: String,
    public val mediaType: String,
    public val read: suspend (offset: Long, maxBytes: Int) -> ByteArray,
    public val maxEdgePx: Int = 2048,
)

public data class NotesPreparedImage(
    public val bytes: ByteArray,
    public val mediaType: String,
    public val fileName: String,
    public val width: Int,
    public val height: Int,
)

public interface NotesMediaPort {
    public fun capabilities(): NotesMediaCapabilities
    /** Bounded image bounds probe; null when the bytes are not a decodable image. */
    public suspend fun probeImage(request: NotesImageProbeRequest): NotesImageInfo?
    /** Re-encode a picked image as PNG/JPEG for `document.coverApply`. */
    public suspend fun prepareCoverImage(request: NotesCoverImageRequest): NotesPreparedImage
    public suspend fun openPdf(request: NotesPdfOpenRequest): NotesPdfOpenOutcome
    public suspend fun exportPdf(request: NotesPdfExportRequest): NotesExportedStream
    public suspend fun exportPageImage(request: NotesPageImageExportRequest): NotesExportedStream
    public suspend fun print(request: NotesPrintRequest): NotesPrintOutcome
    public fun createInk(request: NotesInkCreateRequest): NotesInkSurface
}

/* --------------------------------- office -------------------------------- */

public enum class NotesOfficeBlankKind { WORD, SHEET, SLIDES }

public data class NotesOfficeCreateBlankRequest(
    public val title: String,
    public val kind: NotesOfficeBlankKind,
)

public sealed interface NotesOfficeBlankOutcome {
    public data class Created(public val file: NotesPickedFile) : NotesOfficeBlankOutcome
    public data class Unavailable(public val failure: NotesPortFailure) : NotesOfficeBlankOutcome
    public data class Failed(public val failure: NotesPortFailure) : NotesOfficeBlankOutcome
}

public class NotesOfficeEditRequest(
    public val documentID: String,
    public val revision: Int,
    public val resourceID: String,
    public val sha256: String,
    public val byteCount: Long,
    public val fileName: String,
    public val mediaType: String,
    public val read: NotesResourceReader,
)

public sealed interface NotesOfficeEditOutcome {
    /**
     * [file] is the saved copy returned by the existing Office editor, or null
     * when the editor closed without a saved copy. A returned file is imported
     * as a new immutable resource and applied through ReplaceOfficeResource.
     */
    public data class Saved(
        public val file: NotesPickedFile?,
        public val fileName: String? = null,
        public val mediaType: String? = null,
        public val preview: NotesExportedStream? = null,
    ) : NotesOfficeEditOutcome

    public data object ClosedWithoutChanges : NotesOfficeEditOutcome
    public data class Unavailable(public val failure: NotesPortFailure) : NotesOfficeEditOutcome
    public data class Failed(public val failure: NotesPortFailure) : NotesOfficeEditOutcome
}

public interface NotesOfficePort {
    public suspend fun createBlank(request: NotesOfficeCreateBlankRequest): NotesOfficeBlankOutcome
    public suspend fun edit(request: NotesOfficeEditRequest): NotesOfficeEditOutcome
}

/* ------------------------------- assistant -------------------------------- */

public enum class NotesAssistantAvailability { READY, NOT_CONFIGURED, UNSUPPORTED }

public data class NotesAssistantStatus(
    public val availability: NotesAssistantAvailability,
    public val modelLabel: String? = null,
    public val message: String? = null,
)

public data class NotesAssistantConversationRequest(
    public val documentID: String,
    public val documentTitle: String,
    public val canEdit: Boolean = true,
)

public data class NotesAssistantConversation(public val id: String)

/**
 * Durable transcript vocabulary (G06 runtime). The role is the ORIGINAL
 * persisted conversation role, and the outcome is real durable run evidence —
 * never inferred from an empty reply or from a cancel acknowledgement.
 */
public enum class NotesAssistantTranscriptRole { USER, ASSISTANT, SYSTEM }

public enum class NotesAssistantRunOutcome {
    ACTIVE, COMPLETED, CANCELLED, FAILED, CHECKPOINTED, INTERRUPTED;

    public companion object {
        public fun fromWire(value: String?): NotesAssistantRunOutcome? =
            entries.firstOrNull { it.name == value }
    }
}

public data class NotesAssistantTranscriptEntry(
    public val id: String,
    public val role: NotesAssistantTranscriptRole,
    public val text: String,
    public val runID: String? = null,
    /** ACTIVE is the only value the UI maps to `streaming`. */
    public val outcome: NotesAssistantRunOutcome? = null,
)

public data class NotesAssistantTranscriptPage(
    public val entries: List<NotesAssistantTranscriptEntry>,
    /** Opaque native cursor for older rows; never parsed by the UI. */
    public val earlierCursor: String? = null,
    public val hasEarlier: Boolean = false,
)

public data class NotesAssistantRestartRequest(
    public val conversationID: String,
    public val documentID: String,
    public val documentTitle: String,
)

/**
 * One live/durable turn projection the UI can re-attach to after a view
 * reconstruction. This is a projection of the host's OWN stream ownership, not
 * a permission or a completed-run claim.
 */
public data class NotesAssistantTurnSnapshot(
    public val conversationID: String,
    public val runID: String?,
    public val text: String,
    public val streaming: Boolean,
    public val cancelled: Boolean = false,
    public val failed: Boolean = false,
)

/** One durable pending/decided proposal the editor's accept control owns. */
public data class NotesAssistantProposal(
    public val proposalID: String,
    public val documentID: String,
    public val baseRevision: Int,
    public val title: String,
    public val summary: String,
    public val editCount: Int,
    public val status: String,
) {
    public val isPending: Boolean get() = status == "pending"
    public val canAccept: Boolean get() = isPending
    public val canReject: Boolean get() = isPending
}

public data class NotesAssistantProposalDecision(
    public val proposalID: String,
    /** applied | rejected | failed */
    public val decision: String,
    public val appliedRevision: Int? = null,
    public val reason: String? = null,
)

public data class NotesAssistantContext(
    public val documentID: String,
    public val revision: Int,
    public val pageID: String? = null,
    public val pageNumber: Int? = null,
    public val nodeID: String? = null,
    public val selectedElementIDs: List<String> = emptyList(),
    public val selectedText: String? = null,
    public val attachmentResourceIDs: List<String> = emptyList(),
)

public class NotesAssistantSendRequest(
    public val conversationID: String,
    public val documentID: String,
    public val revision: Int,
    public val text: String,
    public val context: NotesAssistantContext,
)

public sealed interface NotesAssistantEvent {
    /** An incremental append to the current owned assistant turn. */
    public data class Delta(public val text: String) : NotesAssistantEvent

    /**
     * An AUTHORITATIVE replacement of the current owned assistant turn text.
     *
     * The App host emits this when the canonical `run.snapshot` answer text
     * replaces the already-durable prefix of the same streaming step (a live
     * hint or a durable resync), or when a rollback/superseded tail rebuilds
     * the current turn. The receiver must REPLACE the bubble text, never
     * append it; a snapshot is never turned into a delta.
     */
    public data class Snapshot(public val text: String) : NotesAssistantEvent

    /** The durable terminal was observed; [finalText] is the settled text. */
    public data class Finished(public val finalText: String) : NotesAssistantEvent
    public data class Failed(public val failure: NotesPortFailure) : NotesAssistantEvent
    public data object Cancelled : NotesAssistantEvent
}

public interface NotesAssistantPort {
    public suspend fun status(): NotesAssistantStatus
    public suspend fun createConversation(
        request: NotesAssistantConversationRequest,
    ): NotesAssistantConversation

    /**
     * Stream one reply for one document-bound conversation. Suspends until the
     * turn finishes/cancels/fails. Late callbacks after [cancel] must be
     * dropped by the host; the UI also fences each turn.
     */
    public suspend fun send(
        request: NotesAssistantSendRequest,
        onEvent: (NotesAssistantEvent) -> Unit,
    )

    public suspend fun cancel(conversationID: String)

    /** Detach only: never stops a run, erases mapping or deletes history. */
    public suspend fun close(conversationID: String)

    /**
     * Durable transcript page for one Notes conversation. Restores after a
     * process/view reconstruction; it never invents messages.
     */
    public suspend fun transcript(
        conversationID: String,
        before: String? = null,
        limit: Int = 60,
    ): NotesAssistantTranscriptPage =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE, "transcriptUnavailable"))

    /** Pending/decided proposals for the exact conversation origin. */
    public suspend fun proposals(
        conversationID: String,
        documentID: String,
    ): List<NotesAssistantProposal> =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE, "proposalsUnavailable"))

    /**
     * Interactive-editor accept: mints the single-use grant and applies the
     * stored proposal. Never reachable from a model tool.
     */
    public suspend fun acceptProposal(
        conversationID: String,
        documentID: String,
        proposalID: String,
    ): NotesAssistantProposalDecision =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE, "proposalAcceptUnavailable"))

    /** Interactive-editor reject: records the durable rejection intent. */
    public suspend fun rejectProposal(
        conversationID: String,
        documentID: String,
        proposalID: String,
    ): NotesAssistantProposalDecision =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE, "proposalRejectUnavailable"))

    /**
     * Explicit restart: stop/drain the old run and bind a NEW durable thread.
     * Old messages and runs stay durable; nothing auto-retries.
     */
    public suspend fun restartConversation(
        request: NotesAssistantRestartRequest,
    ): NotesAssistantConversation =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.NOT_CONFIGURED, "restartUnavailable"))

    /** The live turn this host still owns, if any (view re-attach). */
    public fun activeTurn(conversationID: String): NotesAssistantTurnSnapshot? = null
}

/* ------------------------------ lifecycle -------------------------------- */

/** Exact drain report for the root-stop gate. `canRetire` is the ONLY field a
 *  caller may use to allow the accepted root/DB to close. */
public data class NotesAssistantStopReport(
    public val epoch: Long,
    public val cancelRequestedCount: Int,
    public val pendingCount: Int,
    public val canRetire: Boolean,
)

/**
 * Application-owned Notes assistant lifecycle, beside the editor's own
 * `NotesWorkspaceSession.prepareForRootStop`. The editor gate runs first; this
 * one fences assistant admission and waits the REAL native run/tool/child
 * drain. A cancel acknowledgement, a stream end or a timeout never reports a
 * drained root.
 */
public interface NotesAssistantRootLifecycle {
    public suspend fun prepareForRootStop(epoch: Long): NotesAssistantStopReport
    public suspend fun abortRootStop(epoch: Long)
    public suspend fun resumeAfterRootChange(epoch: Long)
}

/* -------------------------------- indexing -------------------------------- */

public enum class NotesIndexingAvailability { READY, NOT_CONFIGURED, UNSUPPORTED }

public data class NotesIndexingStatus(
    public val availability: NotesIndexingAvailability,
    public val providerLabel: String? = null,
    public val message: String? = null,
)

public class NotesIndexingRequest(
    public val documentID: String,
    public val pageID: String,
    public val pageNumber: Int,
    public val pageWidthPt: Float,
    public val pageHeightPt: Float,
    public val backgroundResourceID: String?,
    public val drawingResourceID: String?,
    public val elementTexts: List<String>,
    public val read: NotesResourceReader,
)

public data class NotesIndexingResult(
    public val text: String,
    public val providerLabel: String? = null,
)

/**
 * Optional cloud OCR / visual-index host. The Notes contract exposes
 * `ocrSourceKey` as an opaque native identity, so this UI NEVER writes native
 * OCR columns; recognized text is shown and, on explicit user action, inserted
 * as a normal text element with a source reference.
 */
public interface NotesIndexingPort {
    public suspend fun status(): NotesIndexingStatus
    public suspend fun recognize(request: NotesIndexingRequest): NotesIndexingResult
}

/* --------------------------------- bundle --------------------------------- */

public class NotesHostPorts(
    public val media: NotesMediaPort,
    public val office: NotesOfficePort,
    public val assistant: NotesAssistantPort,
    public val exchange: NotesExchangePort,
    /** REQUIRED persistent device store: tabs, filter/sort, last page and scroll. */
    public val presentation: NotesPresentationStore,
    /**
     * REQUIRED unsaved-edit recovery store. Production must be App-private,
     * atomic and durable; the in-memory implementation exists only for tests.
     */
    public val recovery: NotesRecoveryStore,
    public val indexing: NotesIndexingPort? = null,
)

public enum class NotesSettingsTarget { MODELS, GENERAL }

public data class NotesWorkspaceCallbacks(
    public val onRequestSidebar: (() -> Unit)? = null,
    public val onOpenSettings: ((NotesSettingsTarget) -> Unit)? = null,
    public val onOpenExternalSource: ((NoteSourceReference) -> Unit)? = null,
)

/**
 * Honest shell-only bundle: the library/editor/mind-map work against the real
 * [com.floe.android.feature.notes.NotesService], while every unconnected host
 * effect reports a typed unavailability instead of pretending to succeed.
 * Main replaces each member with the real adapter as integration lands.
 */
public fun unavailableNotesHostPorts(
    presentation: NotesPresentationStore,
    recovery: NotesRecoveryStore,
): NotesHostPorts = NotesHostPorts(
    media = UnavailableNotesMedia,
    office = UnavailableNotesOffice,
    assistant = UnavailableNotesAssistant,
    exchange = UnavailableNotesExchange,
    presentation = presentation,
    recovery = recovery,
)

private object UnavailableNotesMedia : NotesMediaPort {
    override fun capabilities(): NotesMediaCapabilities = NotesMediaCapabilities()
    override suspend fun probeImage(request: NotesImageProbeRequest): NotesImageInfo? =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun prepareCoverImage(request: NotesCoverImageRequest): NotesPreparedImage =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun openPdf(request: NotesPdfOpenRequest): NotesPdfOpenOutcome =
        NotesPdfOpenOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun exportPdf(request: NotesPdfExportRequest): NotesExportedStream =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun exportPageImage(request: NotesPageImageExportRequest): NotesExportedStream =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun print(request: NotesPrintRequest): NotesPrintOutcome =
        NotesPrintOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override fun createInk(request: NotesInkCreateRequest): NotesInkSurface =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
}

private object UnavailableNotesOffice : NotesOfficePort {
    override suspend fun createBlank(request: NotesOfficeCreateBlankRequest): NotesOfficeBlankOutcome =
        NotesOfficeBlankOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun edit(request: NotesOfficeEditRequest): NotesOfficeEditOutcome =
        NotesOfficeEditOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
}

private object UnavailableNotesAssistant : NotesAssistantPort {
    override suspend fun status(): NotesAssistantStatus =
        NotesAssistantStatus(NotesAssistantAvailability.UNSUPPORTED)
    override suspend fun createConversation(
        request: NotesAssistantConversationRequest,
    ): NotesAssistantConversation =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun send(
        request: NotesAssistantSendRequest,
        onEvent: (NotesAssistantEvent) -> Unit,
    ): Unit = throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun cancel(conversationID: String) = Unit
    override suspend fun close(conversationID: String) = Unit
}

private object UnavailableNotesExchange : NotesExchangePort {
    override suspend fun pickFile(
        kinds: Set<NotesImportKind>,
        suggestedName: String?,
    ): NotesPickedFile? = throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun shareStream(request: NotesShareStreamRequest): NotesShareOutcome =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun shareText(request: NotesShareTextRequest): NotesShareOutcome =
        throw NotesPortFailureException(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
    override suspend fun openAttachment(
        request: NotesOpenAttachmentRequest,
    ): NotesOpenAttachmentOutcome =
        NotesOpenAttachmentOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNAVAILABLE))
}
