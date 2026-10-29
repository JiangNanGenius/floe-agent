// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import android.content.Context
import com.floe.android.core.notesmedia.export.NotesExportCapabilities
import com.floe.android.core.notesmedia.export.NotesPdfExportFidelity
import com.floe.android.feature.notes.NotesProtocol
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesAssistantPort
import com.floe.android.feature.notes.ui.api.NotesExchangePort
import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.api.NotesIndexingPort
import com.floe.android.feature.notes.ui.api.NotesMediaPort
import com.floe.android.feature.notes.ui.api.NotesOfficePort
import com.floe.android.feature.notes.ui.api.NotesResourceReader
import com.floe.android.feature.notes.ui.presentation.NotesPresentationStore
import com.floe.android.feature.notes.ui.presentation.NotesRecoveryStore
import com.floe.android.feature.notes.ui.presentation.SharedPreferencesNotesPresentationStore
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * App-owned real Notes platform bundle.
 *
 * It contains ONLY the platform-side effects implemented here:
 * media/PDF/Ink/export/print, Office blank editing/save-back, SAF/share,
 * presentation preferences and durable recovery. The assistant and optional
 * OCR/indexing ports are supplied by their own owner (Main/C5) through
 * [hostPorts]; this factory never constructs an unavailable assistant just to
 * assemble a full bundle.
 *
 * Lifetime: one instance per App process, created off-main, shared by the
 * route. Mount [NotesPlatformEffectHost] once with the same instance. Call
 * [close] only at final owner teardown (not on ordinary root-epoch changes;
 * the durable stores and ports do not depend on the native epoch).
 */
class NotesPlatformHost internal constructor(
    public val media: NotesMediaPort,
    public val office: NotesOfficePort,
    public val exchange: NotesExchangePort,
    public val presentation: NotesPresentationStore,
    public val recovery: NotesRecoveryStore,
    /**
     * Separate durable journal for explicit chat-message copies
     * (`reasonCode = chatMessageSave:*`).
     *
     * It deliberately does NOT share [recovery]'s key space: the editor's
     * recovery is keyed by document id and is removed/discarded by ordinary
     * editor paths. If the two journals were shared, opening and saving the
     * half-created note (or tapping "discard" on an editor recovery row) could
     * silently delete a chat copy's canonical plan. Each journal keeps its own
     * atomic files; the native receipt (document id + request id) remains the
     * single canonical identity for the copy.
     */
    public val chatTransferRecovery: NotesRecoveryStore,
    public val activityBroker: NotesPlatformActivityBroker,
    private val mediaEffects: NotesMediaEffects,
    private val officeEffects: NotesOfficeEffects,
    private val exchangeEffects: NotesExchangeEffects,
    private val recoveryStore: DurableNotesRecoveryStore,
    private val chatRecoveryStore: DurableNotesRecoveryStore,
) : AutoCloseable {

    @Volatile
    private var closed = false

    /**
     * Combines the real platform ports with the real assistant/indexing ports
     * owned by another lane. The assistant is REQUIRED here: this host never
     * substitutes a no-op implementation.
     */
    fun hostPorts(
        assistant: NotesAssistantPort,
        indexing: NotesIndexingPort? = null,
    ): NotesHostPorts = NotesHostPorts(
        media = media,
        office = office,
        assistant = assistant,
        exchange = exchange,
        presentation = presentation,
        recovery = recovery,
        indexing = indexing,
    )

    /**
     * The media module's actual PDF export route. The current writer is a
     * RASTERIZED_COPY (source text/vector content is not preserved). UI copy
     * must say "flattened copy", never "lossless" or "original annotations".
     */
    fun pdfExportFidelity(): NotesPdfExportFidelity = NotesExportCapabilities.pdf().fidelity

    /**
     * Presents the recovery files that could not be decoded (diagnostics only).
     * Both journals are reported: an unreadable chat-copy record is retained
     * and must stay visible, never silently ignored.
     */
    fun unreadableRecovery(): List<NotesRecoveryUnreadable> =
        recoveryStore.unreadable() + chatRecoveryStore.unreadable()

    /**
     * Fences one root-stop/navigation boundary: any picker/viewer still
     * waiting gets a typed cancellation, and its late platform result can no
     * longer touch another session. The broker remains usable afterwards.
     */
    fun cancelPendingLaunches() = activityBroker.cancelPending()

    override fun close() {
        if (closed) return
        closed = true
        runCatching { activityBroker.close() }
        runCatching { mediaEffects.close() }
        runCatching { officeEffects.close() }
        runCatching { exchangeEffects.close() }
        runCatching { recoveryStore.close() }
        runCatching { chatRecoveryStore.close() }
    }
}

/**
 * Creates the real platform host. Always call off the UI thread; initial
 * recovery loading and directory preparation happen on [ioDispatcher].
 *
 * @param activityBroker App-owned broker; pass the SAME instance for the life
 *        of the process so a rotation cannot orphan a pending picker/viewer.
 * @param scope App-owned scope for bounded background completion (Office SAF
 *        copy/print teardown). It must outlive the route.
 */
suspend fun createNotesPlatformHost(
    context: Context,
    service: NotesService,
    scope: CoroutineScope,
    activityBroker: NotesPlatformActivityBroker = NotesPlatformActivityBroker(),
    ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    passwordProvider: NotesPdfPasswordProvider? = null,
): NotesPlatformHost {
    require(context.applicationContext != null)
    val application = context.applicationContext
    val filesRoot = File(application.filesDir, "NotesPlatform")
    val cacheRoot = File(application.cacheDir, "NotesPlatform")
    val recoveryRoot = File(application.filesDir, "NotesRecovery")
    val recovery = withContext(ioDispatcher) {
        DurableNotesRecoveryStore.open(recoveryRoot, ioDispatcher)
    }
    // A sibling root, not a child of [recoveryRoot]: neither journal can list,
    // overwrite or clear the other's records.
    val chatTransferRecovery = withContext(ioDispatcher) {
        DurableNotesRecoveryStore.open(
            File(application.filesDir, "NotesChatRecovery"),
            ioDispatcher,
        )
    }
    val resourceReader = NotesResourceReader { resourceID, offset, maxBytes ->
        val safeMax = maxBytes.coerceIn(1, NotesProtocol.MAX_READ_BYTES)
        service.readResource(resourceID, offset, safeMax).data
    }
    val media = NotesMediaEffects(
        context = application,
        scope = scope,
        ioDispatcher = ioDispatcher,
        stagingRoot = cacheRoot,
        passwordProvider = passwordProvider,
    )
    val office = NotesOfficeEffects(
        context = application,
        broker = activityBroker,
        scope = scope,
        stagingRoot = filesRoot,
        ioDispatcher = ioDispatcher,
        notes = service,
    )
    val exchange = NotesExchangeEffects(
        context = application,
        broker = activityBroker,
        attachmentReader = resourceReader,
        stagingRoot = cacheRoot,
        ioDispatcher = ioDispatcher,
    )
    val presentation = SharedPreferencesNotesPresentationStore(application)
    return NotesPlatformHost(
        media = media,
        office = office,
        exchange = exchange,
        presentation = presentation,
        recovery = recovery,
        chatTransferRecovery = chatTransferRecovery,
        activityBroker = activityBroker,
        mediaEffects = media,
        officeEffects = office,
        exchangeEffects = exchange,
        recoveryStore = recovery,
        chatRecoveryStore = chatTransferRecovery,
    )
}
