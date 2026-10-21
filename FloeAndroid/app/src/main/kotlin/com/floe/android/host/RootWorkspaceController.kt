// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.contentOrNull
import kotlinx.coroutines.launch
import com.floe.android.feature.conversation.ApprovalModeUi
import com.floe.android.feature.conversation.AttachmentImportUi
import com.floe.android.feature.conversation.StagedAttachmentUi
import com.floe.android.feature.providers.ReasoningEffortUi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Root/workspace surface owner (App host binding, source stage).
 *
 * Three independently verifiable producers, all over EXISTING stable native
 * APIs — no new wire commands, no parallel config/policy store:
 *
 * 1. HOME DRAFT ATTACHMENTS. A Home pick is staged through the real
 *    `AttachmentImportController` producer on a `conversationId = null`
 *    compose route under a CLIENT RAM draft nonce (⇄ the bridge's documented
 *    new-conversation composer route). NO durable empty conversation is
 *    ever created just to open the picker or stage bytes before C1, and the
 *    temporary ceiling is untouched (a temporary session never stages
 *    attachments). Rows become sendable ONLY after the native
 *    `attachment.stage` terminal accepts; the Home first send hands the
 *    READY rows to the created holder exactly once (one-writer C1 consume +
 *    ownership transfer through the existing atomic launch store), a
 *    create-time failure returns them to the draft, and an ACTUAL
 *    navigation/New Task drains the still-owned staging for real (cancel
 *    live copies, discard staged handles, release grants).
 *    Rotation/background/lock is not navigation: the owner lives on the
 *    Application host and survives.
 *
 * 2. DRAFT-TASK APPROVAL MODE (⇄ DraftTaskPermissionsSheet). Seeded from
 *    the ORIGINAL global default rule: `settings.defaults.defaultAgentMode
 *    == "approvalModel"` seeds AUTOMATIC, otherwise ASK (the native
 *    `run.start` default). A human tap on the Home permissions surface is
 *    the only writer; the value travels as the optional `approvalMode` key
 *    on the FIRST fresh ordinary launch only (persisted atomically by the
 *    native C1) and is never sent for temporary sessions. Recovery and
 *    notification policies keep their existing native defaults (never
 *    invented here).
 *
 * 3. REASONING-EFFORT SHORTCUT (⇄ ThreadComposerView reasoningPicker →
 *    saveModel). Reads the CURRENT full snapshot for the Home-selected
 *    configured model through the SAME provider-filtered
 *    `config.models.list` page (raw row preserved intact — no duplicate
 *    config store, no lost capabilities/ids) and saves it through the
 *    ORIGINAL full-snapshot `config.model.save` CAS with the row's actual
 *    digest revision. No provider LIVE file is edited: this is a producer
 *    over the frozen command grammar. It never mutates an active frozen run
 *    route: the next launch resolves the newly persisted value.
 *
 * This controller owns NO navigation. Every settle callback re-checks the
 * exact draft ownership so a late result can never touch a replacement
 * Home; the serial Home-owned reducer/collector in the Shell remains the
 * only route authority.
 */
class RootWorkspaceController internal constructor(
    private val host: RuntimeHost,
) {
    // ------------------------------------------------- Home draft attachments

    private val attachmentLock = Any()

    /** The current draft ownership record (guarded by [attachmentLock]).
     *  [nonce] is a CLIENT RAM identity (never a persisted task id);
     *  [homeGeneration] mirrors the service-owned Home generation the rows
     *  belong to (the same epoch HomeSendToken/navigation claims use — no
     *  second competing epoch). */
    private class DraftOwnership(
        val nonce: String,
        val homeGeneration: Long,
        val rows: LinkedHashMap<String, StagedAttachmentUi>,
        /** Rows handed to an in-flight first launch (the created holder is
         *  the only writer there; kept here ONLY so a pre-holder create
         *  failure can return them; cleared on success and on any
         *  invalidation). */
        var handedOff: List<StagedAttachmentUi>,
    )

    private var nonceCounter = AtomicLong(0)
    private fun newNonce(): String = SEEDED_PREFIX + nonceCounter.incrementAndGet()

    private var draft: DraftOwnership = DraftOwnership(
        nonce = newNonce(),
        homeGeneration = 0L,
        rows = LinkedHashMap(),
        handedOff = emptyList(),
    )

    /** Draft tray presentation (REAL lifecycle rows only; empty = honest
     * empty). Survives rotation because this owner lives on the host. */
    private val draftAttachmentsState = MutableStateFlow<List<StagedAttachmentUi>>(emptyList())
    val draftAttachments: StateFlow<List<StagedAttachmentUi>> = draftAttachmentsState
    private val draftImportFailedState = MutableStateFlow(false)
    val draftImportFailed: StateFlow<Boolean> = draftImportFailedState

    private fun publishDraftLocked() {
        draftAttachmentsState.value = draft.rows.values.toList()
    }

    /** True while ANY draft row is still copying/staging (honest send
     * gating; never a fake Ready before the native terminal). */
    fun draftHasProcessing(): Boolean =
        draftAttachmentsState.value.any { it.import is AttachmentImportUi.InProgress }

    /** The current draft identity (nonce, service Home generation) for the
     * issued-request capture; the exactness itself is enforced in
     * AttachmentImportController against the still-current request. */
    fun currentDraftOwner(): Pair<String, Long> = synchronized(attachmentLock) {
        draft.nonce to draft.homeGeneration
    }

    /** The Home attach action: ONE explicit user tap. Returns false (and
     * the surface states it honestly) when staging is not admitted or the
     * pick could not start. A temporary session never reaches this path. */
    fun requestHomeAttachments(): Boolean {
        draftImportFailedState.value = false
        val (nonce, generation) = currentDraftOwner()
        return host.attachments.requestDraftPicker(nonce, generation)
    }

    /** Native Ready terminal for a draft-owned row (only after the real
     * `attachment.stage` accept). */
    internal fun onDraftAttachmentStaged(nonce: String, staged: StagedAttachmentUi) {
        synchronized(attachmentLock) {
            if (draft.nonce != nonce) return // a replacement Home owns the surface
            draftImportFailedState.value = false
            draft.rows[staged.id] = staged
            publishDraftLocked()
        }
    }

    internal fun onDraftAttachmentRemoved(nonce: String, stagingId: String) {
        synchronized(attachmentLock) {
            if (draft.nonce != nonce) return
            draft.rows.remove(stagingId)
            publishDraftLocked()
        }
    }

    internal fun onDraftAttachmentFailed(nonce: String) {
        synchronized(attachmentLock) {
            if (draft.nonce == nonce) draftImportFailedState.value = true
        }
    }

    internal fun onDraftAttachmentProgress(nonce: String, stagingId: String, import: AttachmentImportUi) {
        synchronized(attachmentLock) {
            if (draft.nonce != nonce) return
            val existing = draft.rows[stagingId]
                ?: if (import is AttachmentImportUi.Ready) {
                    null
                } else {
                    // A progress event for a row the user already removed
                    // leaves nothing behind (CHA-ATTACH-LIFECYCLE-AND).
                    return
                }
            existing?.let { draft.rows[stagingId] = it.copy(import = import) }
            publishDraftLocked()
        }
    }

    /** Remove one draft row for the user: live copies really cancel
     * (abort + attachment.staging.cancel) and Ready rows really discard
     * (attachment.staging.discard); the presentation row leaves FIRST so a
     * late success cannot resurrect it. */
    fun removeDraftAttachment(stagingId: String): Boolean {
        val (nonce, wasReady) = synchronized(attachmentLock) {
            val row = draft.rows[stagingId] ?: return false
            val ready = row.import is AttachmentImportUi.Ready
            draft.rows.remove(stagingId)
            publishDraftLocked()
            draft.nonce to ready
        }
        // Exactly ONE real action per row state: a live copy cancels
        // (abort + attachment.staging.cancel); a Ready row discards
        // (attachment.staging.discard with its native handle).
        if (wasReady) {
            host.attachments.discardDraft(nonce, stagingId)
        } else {
            host.attachments.cancelDraft(nonce, stagingId)
        }
        return true
    }

    /** Retry a failed draft row under its REAL ownership (the entry keeps
     * the source receipt so bytes stay recoverable on failure). */
    fun retryDraftAttachment(stagingId: String): Boolean {
        val nonce = synchronized(attachmentLock) { draft.nonce }
        return host.attachments.retryDraft(nonce, stagingId)
    }

    /** Cancel a still-running draft copy (presentation row is removed by
     * the caller through [removeDraftAttachment] exactly like the thread
     * tray semantics). */
    fun cancelDraftAttachment(stagingId: String): Boolean {
        val nonce = synchronized(attachmentLock) { draft.nonce }
        return host.attachments.cancelDraft(nonce, stagingId)
    }

    /** ONE-WRITER C1 HANDOFF (HomeLaunchpadHost, ordinary first send):
     * returns the READY rows and clears them from the draft list
     * immediately — the created holder/launch becomes the only writer from
     * here. A create-time failure restores them through [restoreHandedOff];
     * a committed launch consumes them natively. Non-ready rows stay
     * draft-owned (they are honestly visible and never carried). */
    internal fun takeSendableForLaunch(): List<StagedAttachmentUi> =
        synchronized(attachmentLock) {
            val readyIds = draft.rows
                .filterValues { it.import is AttachmentImportUi.Ready }
                .keys
                .toList()
            val sendable = readyIds.mapNotNull { draft.rows[it] }
            if (sendable.isNotEmpty()) {
                readyIds.forEach { draft.rows.remove(it) }
                draft.handedOff = sendable
                publishDraftLocked()
            }
            sendable
        }

    /** The create/launch flow failed BEFORE any holder took ownership:
     * return the handed-off rows to the draft so a retry carries them —
     * the native staged receipts remain valid. A replacement Home instead
     * DRAINS them for real (no leak, no silent drop). */
    internal fun restoreHandedOff(nonce: String) {
        val toDrain: List<String>
        synchronized(attachmentLock) {
            if (draft.nonce != nonce) {
                toDrain = draft.handedOff.map { it.id }
                draft.handedOff = emptyList()
            } else {
                draft.handedOff.forEach { staged ->
                    draft.rows[staged.id] = staged
                }
                draft.handedOff = emptyList()
                publishDraftLocked()
                toDrain = emptyList()
            }
        }
        if (toDrain.isNotEmpty()) {
            host.scope.launch(host.ioDispatcher) {
                toDrain.forEach { host.attachments.discardDraft(nonce, it) }
            }
        }
    }

    /** The created holder accepted the draft handoff. Its session now owns
     * the staged rows; only a later native prepared echo consumes the bytes. */
    internal fun clearHandedOff(nonce: String) {
        synchronized(attachmentLock) {
            if (draft.nonce == nonce) draft.handedOff = emptyList()
        }
    }

    /** ACTUAL navigation / New Task / Home replacement: retire the outgoing
     * draft ownership. In-flight copies are cancelled, staged handles
     * discarded, the pending picker invalidated, and a NEW nonce begins for
     * the replacement Home. Rotation/background/lock never call this.
     * [homeGeneration] is the service-owned value the Home host advanced to. */
    internal fun onHomeReplaced(homeGeneration: Long) {
        val outgoing = synchronized(attachmentLock) {
            val previous = draft
            draftImportFailedState.value = false
            draft = DraftOwnership(
                nonce = newNonce(),
                homeGeneration = homeGeneration,
                rows = LinkedHashMap(),
                handedOff = emptyList(),
            )
            publishDraftLocked()
            previous
        }
        // The replacement Home re-derives its draft policy from the ORIGINAL
        // global default: a departed Home's explicit per-draft selection is
        // not carried over (the durable per-task truth lives on the task).
        seedDraftApprovalFromGlobalDefault()
        // And its reasoning chip reflects the still-selected model's REAL
        // saved row (null when the wire carried no value — never "auto").
        refreshSelectedModelReasoning()
        // Invalidate a still-pending picker for the retired surface FIRST:
        // its late result can then never touch the replacement (exact
        // request equality in AttachmentImportController).
        host.attachments.cancelPicker()
        // Real drain AFTER the new owner is installed: the old nonce can no
        // longer mutate any presentation state, so cancelling/discarding is
        // side-effect-free for the replacement Home. Handed-off rows drain
        // too: the launch was invalidated before it consumed them.
        host.scope.launch(host.ioDispatcher) {
            host.attachments.drainDraft(outgoing.nonce)
            outgoing.handedOff.map { it.id }.forEach {
                host.attachments.discardDraft(outgoing.nonce, it)
            }
        }
    }

    /** Home-generation bookkeeping mirror (the Home host owns the epoch;
     * this keeps the draft record aligned as the Home surface advances). */
    internal fun onHomeGenerationChanged(homeGeneration: Long) {
        synchronized(attachmentLock) {
            if (draft.homeGeneration != homeGeneration) {
                draft = DraftOwnership(
                    nonce = draft.nonce,
                    homeGeneration = homeGeneration,
                    rows = draft.rows,
                    handedOff = draft.handedOff,
                )
            }
        }
    }

    internal fun start() {}

    /** Host teardown only: forget records (the native service owns durable
     * cleanup of any not-yet-drained staging through the existing lease). */
    internal fun stop() {
        synchronized(attachmentLock) {
            draftImportFailedState.value = false
            draft = DraftOwnership(newNonce(), 0L, LinkedHashMap(), emptyList())
            draftAttachmentsState.value = emptyList()
        }
    }

    // -------------------------------------------------- draft task policy

    private val draftApprovalModeState = MutableStateFlow(ApprovalModeUi.ASK)
    val draftApprovalMode: StateFlow<ApprovalModeUi> = draftApprovalModeState

    /** ORIGINAL global-default seeding (⇄ HomeLaunchpadViewModel: default
     * agent mode "approvalModel" seeds automatic; otherwise the ORIGINAL
     * DraftTaskPolicy default is ask). Android is cloud-only, so the iOS
     * local-model fullAccess restriction has no rows here; the native
     * parser's actual raw vocabulary (ask/automatic/fullAccess) is what the
     * producer sends — never a guessed enum string. */
    fun seedDraftApprovalFromGlobalDefault() {
        val defaultsMode = runCatching {
            host.settings.state.value.defaults.defaultAgentMode
        }.getOrNull()
        draftApprovalModeState.value = when (defaultsMode) {
            "approvalModel" -> ApprovalModeUi.AUTOMATIC
            else -> ApprovalModeUi.ASK
        }
    }

    /** Explicit human selection on the Home permissions sheet. Temporary
     * sessions never consume this value (their launches carry no approval
     * key and the native ceiling is frozen). */
    fun selectDraftApprovalMode(mode: ApprovalModeUi) {
        draftApprovalModeState.value = mode
    }

    // ------------------------------------------------ reasoning effort chip

    private val reasoningEffortState = MutableStateFlow<ReasoningEffortUi?>(null)
    /** The SAVED reasoning effort of the currently selected configured model
     * (null = the wire row carried no value — displayed honestly, never a
     * fabricated "auto"). Recomputed by [refreshSelectedModelReasoning]. */
    val reasoningEffort: StateFlow<ReasoningEffortUi?> = reasoningEffortState

    /** Re-reads the selected model's row from the REAL cached provider rows.
     * Called when the model selection changes or after a saved CAS. */
    fun refreshSelectedModelReasoning() {
        val modelId = host.home.selectedModelId.value
        val row = cachedModelRow(modelId)
        reasoningEffortState.value = row?.reasoningEffort?.let { raw ->
            ReasoningEffortUi.entries.firstOrNull { it.swiftRaw == raw }
        }
    }

    private fun cachedModelRow(modelId: String?): ProviderWire.ModelRow? {
        if (modelId.isNullOrBlank()) return null
        val option = host.conversations.modelOptions()
            .firstOrNull { it.modelId.equals(modelId, ignoreCase = true) }
            ?: return null
        return host.conversations.modelRowsForProvider(option.providerId)
            .firstOrNull { it.id.equals(modelId, ignoreCase = true) }
    }

    /** True while a reasoning save owns the surface (one at a time). */
    private val reasoningSaveInFlight = AtomicBoolean(false)

    /**
     * Persist a new reasoning effort for the CURRENTLY selected configured
     * model through the ORIGINAL full-snapshot model CAS
     * (MAIN_MODEL_METADATA_API_20261021). The producer starts from the
     * row's `originalProjection` — the EXACT immutable canonical saved row
     * including the native `revision` member — and replaces ONLY
     * `reasoningEffort`. A null projection means the actual read is
     * REQUIRED: one provider-filtered `config.models.list` page chain re-
     * reads the real row; the App never rebuilds a partial profile from
     * display fields (that path previously erased pricing/useSurfaces/
     * explicit-zero capabilities). A refused or unreadable state NEVER
     * mutates the projection or fakes the chip label; an accepted save
     * re-publishes the shared projection so Home and every thread see the
     * same truth. No active frozen run route is touched: the next launch
     * resolves the newly persisted value.
     */
    fun updateSelectedModelReasoningEffort(
        effort: ReasoningEffortUi,
        onOutcome: ((succeeded: Boolean, reason: String?) -> Unit)? = null,
    ): Boolean {
        if (!host.readiness.value.providerConfigurationAdmitted) {
            onOutcome?.invoke(false, "provider_unconfigured")
            return false
        }
        val modelId = host.home.selectedModelId.value
        val option = modelId?.let { id ->
            host.conversations.modelOptions().firstOrNull {
                it.modelId.equals(id, ignoreCase = true) && it.isUsable
            }
        }
        if (option == null) {
            // No current model: honest refusal. The Home chip routes to
            // provider setup instead of offering this producer.
            onOutcome?.invoke(false, "model_unavailable")
            return false
        }
        if (!reasoningSaveInFlight.compareAndSet(false, true)) {
            onOutcome?.invoke(false, "in_flight")
            return false
        }
        val generation = host.nativeRootEpoch()
        val cached = cachedModelRow(option.modelId)
        val fromSaved = cached?.originalProjection?.let { projection ->
            parseReasoningRow(projection, option.modelId)
        }
        if (fromSaved != null) {
            submitModelSave(fromSaved, effort, generation, onOutcome)
            return true
        }
        // Null saved projection (or a cached row whose projection is
        // absent): the ACTUAL read is required before any CAS.
        readModelRow(
            providerID = option.providerId,
            modelID = option.modelId,
            generation = generation,
            onRow = { row ->
                if (!stillCurrent(generation)) {
                    reasoningSaveInFlight.set(false)
                    onOutcome?.invoke(false, "superseded")
                    return@readModelRow
                }
                if (row == null) {
                    reasoningSaveInFlight.set(false)
                    onOutcome?.invoke(false, "model_row_unreadable")
                    return@readModelRow
                }
                submitModelSave(row, effort, generation, onOutcome)
            },
        )
        return true
    }

    /** Parse the REAL full row (with its native `revision` member) into the
     * save carrier. A missing/foreign revision identity or an over-bound
     * row refuses typed (null); nothing is reconstructed here. */
    private fun parseReasoningRow(match: JsonObject, modelID: String): ReasoningModelRow? {
        val revision = (match["revision"] as? JsonObject)?.let {
            val resourceID = (it["resourceID"] as? JsonPrimitive)?.contentOrNull
            val version = (it["version"] as? JsonPrimitive)?.contentOrNull
            if (resourceID != null && version != null) HostRevision(resourceID, version) else null
        } ?: return null
        if (!revision.resourceID.equals("model.${modelID.uppercase()}", ignoreCase = true)) {
            return null
        }
        val snapshot = JsonObject(match.filterKeys { it != "revision" })
        if (snapshot.toString().toByteArray().size > REASONING_ROW_MAX_BYTES) return null
        return ReasoningModelRow(revision, snapshot)
    }

    private fun stillCurrent(generation: Long?): Boolean =
        generation != null && host.nativeRootEpoch() == generation &&
            host.readiness.value.providerConfigurationAdmitted

    /** Provider-filtered bounded read of the selected row's FULL raw JSON +
     * its CAS revision (the same closed payload shape the provider lane
     * uses; no new command, no global cache copy). */
    private fun readModelRow(
        providerID: String,
        modelID: String,
        generation: Long?,
        cursor: String? = null,
        pages: Int = 0,
        onRow: (ReasoningModelRow?) -> Unit,
    ) {
        host.readModelPage(
            providerID = providerID, cursor = cursor, correlationTag = "mlist-reason",
            isCurrent = { stillCurrent(generation) },
        ) { outcome ->
            if (!stillCurrent(generation)) {
                reasoningSaveInFlight.set(false)
                onRow(null)
                return@readModelPage
            }
            if (outcome !is HostOperationOutcome.Completed) {
                reasoningSaveInFlight.set(false)
                onRow(null)
                return@readModelPage
            }
            val value = outcome.value
            val rows = value?.let { ProviderWire.pageRows(it) }
            if (rows == null) {
                reasoningSaveInFlight.set(false)
                onRow(null)
                return@readModelPage
            }
            val match = rows
                .mapNotNull { it as? JsonObject }
                .firstOrNull { row ->
                    ((row["id"] as? JsonPrimitive)?.contentOrNull)
                        .equals(modelID, ignoreCase = true)
                }
            if (match != null) {
                // The CAS identity must come from the REAL row revision; a
                // missing/foreign/over-bound member refuses typed (null),
                // never a rebuilt partial profile. The latch stays held:
                // a parsed row proceeds straight into submitModelSave (its
                // callback releases), a null release happens downstream.
                onRow(parseReasoningRow(match, modelID))
                return@readModelPage
            }
            val meta = ProviderWire.pageMeta(value)
            if (meta?.hasMore == true) {
                val next = meta.nextCursor
                val nextIndex = next?.toLongOrNull()
                val previousIndex = cursor?.toLongOrNull()
                val progressed = nextIndex != null && nextIndex >= 0 &&
                    (cursor == null || (previousIndex != null && nextIndex > previousIndex))
                if (!progressed || pages + 1 >= REASONING_MAX_PAGES) {
                    reasoningSaveInFlight.set(false)
                    onRow(null)
                    return@readModelPage
                }
                readModelRow(providerID, modelID, generation, next, pages + 1, onRow)
                return@readModelPage
            }
            reasoningSaveInFlight.set(false)
            onRow(null)
        }
    }

    private class ReasoningModelRow(
        val revision: HostRevision,
        val snapshot: JsonObject,
    )

    private fun submitModelSave(
        row: ReasoningModelRow,
        effort: ReasoningEffortUi,
        generation: Long?,
        onOutcome: ((Boolean, String?) -> Unit)?,
    ) {
        val updated = JsonObject(
            LinkedHashMap(row.snapshot).apply {
                put("reasoningEffort", JsonPrimitive(effort.swiftRaw))
            },
        )
        host.trackOperation(
            HostCommandRequest(
                command = "config.model.save",
                scope = HostScope.ApplicationConfiguration("models"),
                stateful = true,
                correlationID = host.commandClient.correlationID("modelreason"),
                revision = row.revision,
                payload = updated,
            ),
        ) { outcome ->
            reasoningSaveInFlight.set(false)
            if (!stillCurrent(generation)) {
                // Root was retired mid-save: the DURABLE save result stands
                // (native owns it) but no stale UI mutation follows.
                onOutcome?.invoke(
                    outcome is HostOperationOutcome.Completed,
                    if (outcome is HostOperationOutcome.Completed) null else "superseded",
                )
                return@trackOperation
            }
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    // Re-publish the SHARED projection from the real rows
                    // (the canonical reply is persisted truth); the chip
                    // reflects the saved value through the same read path,
                    // never a locally assumed new state.
                    host.conversations.refreshModels()
                    // The sweep re-read lands asynchronously; seed the chip
                    // from the saved CAS result too so a single quick read
                    // matches (the republish remains the authority).
                    refreshSelectedModelReasoning()
                    onOutcome?.invoke(true, null)
                }
                is HostOperationOutcome.Rejected -> {
                    // Keep the CURRENT saved value visible (a stale digest
                    // means the row moved: the next explicit action re-reads
                    // the fresh CAS identity; never auto-replayed).
                    refreshSelectedModelReasoning()
                    onOutcome?.invoke(false, outcome.code)
                }
                is HostOperationOutcome.Failed -> {
                    refreshSelectedModelReasoning()
                    onOutcome?.invoke(false, outcome.code)
                }
                HostOperationOutcome.Cancelled -> onOutcome?.invoke(false, "cancelled")
                HostOperationOutcome.Superseded -> onOutcome?.invoke(false, "superseded")
            }
        }
    }

    private companion object {
        const val SEEDED_PREFIX = "home-draft-"
        /** The frozen native single-model payload bound (the proven
         *  config.model.save byte ceiling). */
        const val REASONING_ROW_MAX_BYTES = 61_440
        /** The EQUIVALENT supported model-chain page guard for the fallback
         * read: the native composer caps a page at 49152 item bytes AND 200
         * items, but a page may legally carry ONE ~30KiB row, so a full
         * supported 512-row provider profile can need up to 512 single-row
         * pages. Fixed at the supported per-provider row ceiling (512) —
         * strict cursor progress plus the per-page scan make a longer chain
         * impossible. NOT a native envelope/page/row limit change. */
        const val REASONING_MAX_PAGES = 512
    }
}
