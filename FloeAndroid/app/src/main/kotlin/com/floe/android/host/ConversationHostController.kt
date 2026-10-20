// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import com.floe.android.feature.conversation.AgentExecutionModeUi
import com.floe.android.feature.conversation.ApprovalDecisionRequest
import com.floe.android.feature.conversation.ApprovalUserDecisionUi
import com.floe.android.feature.conversation.AttachmentImportUi
import com.floe.android.feature.conversation.AttachmentOpenRequest
import com.floe.android.feature.conversation.BulkItemOutcomeUi
import com.floe.android.feature.conversation.BulkItemResultUi
import com.floe.android.feature.conversation.BulkReceiptUi
import com.floe.android.feature.conversation.ChildRunDetailUi
import com.floe.android.feature.conversation.ComposerDraftSeedUi
import com.floe.android.feature.conversation.ConversationHistoryHolder
import com.floe.android.feature.conversation.ConversationListItemUi
import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.feature.conversation.ConversationUiCallbacks
import com.floe.android.contracts.EventCursor
import com.floe.android.feature.conversation.GoalCreateRequest
import com.floe.android.feature.conversation.HistoryListUiState
import com.floe.android.feature.conversation.InspectorRouteUi
import com.floe.android.feature.conversation.LaunchCorrelation
import com.floe.android.feature.conversation.MarkdownBlockUi
import com.floe.android.feature.conversation.MessagePageCursorUi
import com.floe.android.feature.conversation.ModelOptionUi
import com.floe.android.feature.conversation.PlanRecommendationUi
import com.floe.android.contracts.Revision
import com.floe.android.feature.conversation.RunningInputModeUi
import com.floe.android.feature.conversation.RunningInputRequest
import com.floe.android.feature.conversation.RunLaunchRequest
import com.floe.android.feature.conversation.StagedAttachmentUi
import com.floe.android.feature.conversation.TaskBulkOperationUi
import com.floe.android.feature.conversation.TemporaryEndTargetUi
import com.floe.android.feature.conversation.TemporaryKeepOutcomeUi
import com.floe.android.feature.conversation.TemporarySessionRef
import com.floe.android.feature.conversation.ThreadUiState
import com.floe.android.feature.conversation.TimelineRowUi
import com.floe.android.feature.providers.ProviderCredentialStateUi
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * App-host binding for the conversation feature component: conversation
 * lifecycle, history, run launch/control, approvals, temporary sessions and
 * composer-side callbacks. Implements [ConversationUiCallbacks] exactly and
 * owns the per-conversation [com.floe.android.feature.conversation.ConversationFlowHolder]
 * registry plus the history holder.
 *
 * Correlation truth: a `true` return from [startRun] is owned-prep ADMISSION
 * only; exactly one terminal echo follows — [ConversationFlowHolder.applyLaunchPrepared]
 * with the REAL committed identities, or [ConversationFlowHolder.applyLaunchFailure].
 * No provisional conversation/run IDs are ever minted by the host.
 *
 * Navigation/lifecycle (iOS semantics): view detach, rotation, background and
 * lock retain the session; only an actual route transition or New Task fences
 * a temporary session — through [TemporaryNavigationFence] (identity fence
 * admission first, async drain afterwards, never a whole-run wait).
 */
class ConversationHostController internal constructor(
    private val host: RuntimeHost,
) : ConversationUiCallbacks {

    /** History surface holder (Task Center / archive / management). */
    val historyHolder = ConversationHistoryHolder(this)

    /** Shell navigation requests (host → shell, observed by composition). */
    val navigationRequest = MutableStateFlow<SidebarSelection?>(null)

    /** Inspector presentation requests (host → shell). */
    val inspectorRequest = MutableStateFlow<Pair<InspectorRouteUi, String>?>(null)

    /** Permissions-inspector requests for a conversation. */
    val permissionsRequest = MutableStateFlow<String?>(null)

    /** Temporary navigation fence (TMP-NAV-2). */
    val tempFence = TemporaryNavigationFence(host)

    private val holders = ConcurrentHashMap<String, ConversationFlowHolderEntry>()
    private val sessionEpochs = AtomicLong(0)
    private val launchCorrelations = ConcurrentHashMap<String, LaunchCorrelation>()
    private val launchOutcomeListeners =
        ConcurrentHashMap<Long, (admitted: Boolean, reason: String?) -> Unit>()
    private val eventPumps = ConcurrentHashMap<String, EventPumpHandle>()

    /**
     * Per-run live-hint coalescing for the canonical `run.snapshot` refresh:
     * at most ONE refresh in flight per run, dirty hints coalesce into a
     * single bounded follow-up, and the cadence never exceeds the existing
     * poll interval. Live frames are hints only; the snapshot page is truth.
     */
    private val liveSnapshotRefreshes = ConcurrentHashMap<String, LiveSnapshotRefreshState>()

    /**
     * Trusted LOCAL stream-incarnation generation per conversation/run. It
     * exists only to fence callbacks and snapshot replies from a PREVIOUS
     * incarnation of the same durable run id (the real `run.retry` resumes
     * the same run id). The generation advances ONLY on a genuinely accepted
     * `run.retry`; snapshots, live hints, cold reads and retry failures never
     * touch it. No wire/Core epoch is invented.
     */
    private val runStreamGenerations = ConcurrentHashMap<String, Long>()

    /**
     * Last durable event sequence observed for a run. A resumed incarnation
     * starts its event pump AFTER this watermark so the previous incarnation's
     * durable events (including an old terminal) are never replayed into the
     * resumed tail. Native `durableWatermark` already carries this; no wire
     * field is added.
     */
    private val runDurableWatermarks = ConcurrentHashMap<String, Long>()

    /** One committed-row reconciliation per terminal stream generation. */
    private val terminalReconciled = BoundedKeySet(TERMINAL_RECONCILE_CAPACITY)
    private val terminalReconcileInFlight = ConcurrentHashMap.newKeySet<String>()

    /**
     * The REAL composer model projection: `config.models.list` rows joined
     * with the configured providers and the persisted default-agent model
     * preference. Exactly one projection exists per host; it is republished
     * on provider/model/root readiness changes (never a second catalog read).
     */
    private val modelProjection = MutableStateFlow(ModelProjection())

    /** Cached model rows from the last real `config.models.list` page. */
    private var cachedModelRows: List<ProviderWire.ModelRow> = emptyList()

    /** Persisted default agent model id from `config.preferences.get`. */
    private var defaultAgentModelId: String? = null

    private val modelRefreshInFlight = java.util.concurrent.atomic.AtomicBoolean(false)
    private val goalLaunchGenerations = AtomicLong(0)
    private var providersObservation: kotlinx.coroutines.Job? = null
    private var lastProviderListSignature: String? = null
    private var modelsReadOnce = false
    private var modelsReadAttempted = false

    /** Active temporary session (conversationId + incarnation), if any. */
    private val activeTemporary = ConcurrentHashMap<String, TemporarySessionRef>()

    init {
        // Explicit End gets ONE short admission echo into the exact holder;
        // shell route transitions pass notifyOutcome=false and keep their
        // selected target (the drain terminal never overrides it).
        tempFence.endOutcomeListener = { ref, target ->
            holders[ref.conversationId]?.holder?.applyTemporaryEndOutcome(ref, target)
        }
    }

    internal val markdownParser = com.floe.android.feature.conversation.MarkdownParseService()

    internal fun start() {
        if (host.readiness.value.conversationDomainAdmitted) {
            refreshHistory()
        }
        // Provider list → model projection, in both directions: the rows are
        // the join's provider side, and any real save/delete/disable refreshes
        // the models page too (the user's newly saved model must appear).
        if (providersObservation == null) {
            providersObservation = host.scope.launch(host.ioDispatcher) {
                host.providers.destination.collect { state ->
                    val rows = state.list.conversationProviders
                    val signature = rows.joinToString("|") {
                        "${it.providerId}:${it.enabled}:${it.credentialState}"
                    }
                    if (signature != lastProviderListSignature) {
                        lastProviderListSignature = signature
                        publishModelProjection()
                        if (host.readiness.value.providerConfigurationAdmitted &&
                            (modelsReadOnce || rows.isNotEmpty())
                        ) {
                            refreshModels()
                        }
                    }
                }
            }
        }
        if (host.readiness.value.providerConfigurationAdmitted) {
            refreshModels()
        }
    }

    internal fun stop() {
        eventPumps.values.forEach { it.close() }
        eventPumps.clear()
        liveSnapshotRefreshes.clear()
        runStreamGenerations.clear()
        runDurableWatermarks.clear()
        terminalReconcileInFlight.clear()
        terminalReconciled.clear()
        providersObservation?.cancel()
        providersObservation = null
    }

    private fun client() = host.commandClient
    private fun admitted(): Boolean = host.readiness.value.runDomainAdmitted
    private fun conversationAdmitted(): Boolean =
        host.readiness.value.conversationDomainAdmitted

    // -------------------------------------------------------- model projection

    internal data class ModelProjection(
        val models: List<ModelOptionUi> = emptyList(),
        val needsProvider: Boolean = false,
        val loaded: Boolean = false,
    )

    /**
     * Reads the ACTUAL model rows (`config.models.list`) and the persisted
     * default agent model (`config.preferences.get`), then republishes the
     * joined composer projection. A failed read keeps the last real
     * projection and never fabricates usability or a zero count.
     */
    internal fun refreshModels() {
        if (!host.readiness.value.providerConfigurationAdmitted) return
        if (!modelRefreshInFlight.compareAndSet(false, true)) return
        host.trackOperation(
            HostCommandRequest(
                command = "config.models.list",
                scope = HostScope.ApplicationConfiguration("models"),
                stateful = false,
                correlationID = client().correlationID("mlist"),
            ),
        ) { modelsOutcome ->
            modelsReadAttempted = true
            if (modelsOutcome !is HostOperationOutcome.Completed) {
                modelRefreshInFlight.set(false)
                publishModelProjection()
                return@trackOperation
            }
            val rows = modelsOutcome.value?.let { ProviderWire.decodeModelRows(it) }
            if (rows == null) {
                modelRefreshInFlight.set(false)
                return@trackOperation
            }
            cachedModelRows = rows
            modelsReadOnce = true
            publishModelProjection()
            host.trackOperation(
                HostCommandRequest(
                    command = "config.preferences.get",
                    scope = HostScope.ApplicationConfiguration("preferences"),
                    stateful = false,
                    correlationID = client().correlationID("prefget"),
                ),
            ) { prefOutcome ->
                if (prefOutcome is HostOperationOutcome.Completed) {
                    ProviderWire.decodeDefaultAgentModel(prefOutcome.value)?.let {
                        defaultAgentModelId = it
                    }
                }
                publishModelProjection()
                modelRefreshInFlight.set(false)
            }
        }
    }

    /**
     * Joins the real model rows, the configured provider rows and the saved
     * default model. Usability is exactly the native rule this projection can
     * prove: the model row is enabled + visible in the primary picker, its
     * owning provider is enabled AND has a configured credential. Presence of
     * a row alone never means usable.
     */
    private fun publishModelProjection() {
        val providerRows = host.providers.destination.value.list.conversationProviders
            .associateBy { it.providerId.uppercase() }
        val options = cachedModelRows.mapNotNull { row ->
            val provider = providerRows[row.providerId.uppercase()] ?: return@mapNotNull null
            if (!row.isEnabled || row.isHiddenFromPrimaryPicker) return@mapNotNull null
            if (!row.supportsText) return@mapNotNull null
            ModelOptionUi(
                modelId = row.id,
                remoteModelId = row.remoteModelId,
                displayName = row.displayName,
                providerId = row.providerId,
                providerName = provider.displayName,
                isUsable = provider.enabled &&
                    provider.credentialState == ProviderCredentialStateUi.CONFIGURED,
            )
        }
        // iOS default-selection semantics: the saved default agent model (when
        // usable) leads the picker; the rest keep the durable page order.
        val ordered = if (defaultAgentModelId == null) {
            options
        } else {
            val defaultKey = defaultAgentModelId!!.uppercase()
            val preferred = options.filter { it.modelId.uppercase() == defaultKey }
            preferred + options.filterNot { it.modelId.uppercase() == defaultKey }
        }
        val usable = ordered.any { it.isUsable }
        val projection = ModelProjection(
            models = ordered,
            // Honest "configure a provider": a completed read attempt proves
            // there is no usable model (a failed read is surfaced the same
            // way instead of pretending the composer can send).
            needsProvider = modelsReadAttempted && !usable,
            loaded = modelsReadOnce,
        )
        modelProjection.value = projection
        // Republish every live thread so its composer sees the real options.
        for (entry in holders.values) {
            entry.builder.applyModels(projection.models, projection.needsProvider)
            entry.holder.applyHostSnapshot(entry.builder.build())
        }
    }

    private fun currentModels(): ModelProjection = modelProjection.value

    /** Observable real projection (the provider surface joins its row counts). */
    internal val modelProjectionFlow: kotlinx.coroutines.flow.StateFlow<ModelProjection> =
        modelProjection

    /** Re-joins the cached model rows with the CURRENT provider projection. */
    internal fun republishModelProjection() = publishModelProjection()

    /** All real model rows of one provider (including disabled/hidden ones). */
    internal fun modelRowsForProvider(providerId: String): List<ProviderWire.ModelRow> =
        cachedModelRows.filter { it.providerId.equals(providerId, ignoreCase = true) }

    /** Real per-provider model counts from the `config.models.list` page. */
    internal fun modelCountsByProvider(): Map<String, Int> =
        cachedModelRows.groupingBy { it.providerId.uppercase() }.eachCount()

    /** The saved default agent model, when it belongs to [providerId]. */
    internal fun defaultAgentModelIdFor(providerId: String): String? =
        defaultAgentModelId?.takeIf { id ->
            cachedModelRows.any {
                it.id.equals(id, ignoreCase = true) &&
                    it.providerId.equals(providerId, ignoreCase = true)
            }
        }

    // ------------------------------------------------------------ holder API

    /** Resolve (or create) the holder for a conversation surface. */
    fun holderFor(
        conversationId: String,
        isTemporary: Boolean,
        incarnationId: String?,
        initialDraft: ComposerDraftSeedUi? = null,
    ): com.floe.android.feature.conversation.ConversationFlowHolder {
        val existing = holders[conversationId]
        if (existing != null && existing.holder.session.conversationId == conversationId) {
            return existing.holder
        }
        val epoch = sessionEpochs.incrementAndGet()
        val holder = com.floe.android.feature.conversation.ConversationFlowHolder(
            this,
            conversationId,
            initialDraft,
        )
        val builder = ThreadProjectionBuilder(conversationId).also {
            val projection = currentModels()
            it.applyModels(projection.models, projection.needsProvider)
        }
        holders[conversationId] = ConversationFlowHolderEntry(
            holder = holder,
            sessionEpoch = epoch,
            isTemporary = isTemporary,
            incarnationId = incarnationId,
            builder = builder,
        )
        // First-provider/model configuration must not depend on opening the
        // thread first: an admitted configuration surface refreshes the real
        // projection so the composer can send on the very first open.
        if (host.readiness.value.providerConfigurationAdmitted) refreshModels()
        return holder
    }

    fun entryFor(conversationId: String): ConversationFlowHolderEntry? = holders[conversationId]

    fun releaseHolder(conversationId: String) {
        holders.remove(conversationId)?.let { entry ->
            eventPumps.values.filter { it.runID in entry.builder.runIds() }
                .forEach { it.close() }
            entry.builder.runIds().forEach { runID ->
                liveSnapshotRefreshes.remove(runID)
                runStreamGenerations.remove(streamKey(conversationId, runID))
                runDurableWatermarks.remove(streamKey(conversationId, runID))
            }
        }
    }

    /** The currently active temporary session ref, if any. */
    fun activeTemporarySession(): TemporarySessionRef? =
        activeTemporary.values.firstOrNull()

    /**
     * The exact native incarnation fence has linearized for [ref]. Retire
     * only that identity; a stale/late callback for another incarnation can
     * never remove a later temporary session.
     */
    internal fun onTemporaryFenceAdmitted(ref: TemporarySessionRef) {
        activeTemporary.remove(ref.conversationId, ref)
    }

    /** Readiness-aware model options for composers (real projection above). */
    fun modelOptions(): List<ModelOptionUi> = currentModels().models

    // ---------------------------------------------------- conversation loads

    internal fun loadThreadInternal(session: ConversationSessionToken) {
        if (!conversationAdmitted()) return
        val entry = holders[session.conversationId] ?: return
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = false,
                correlationID = client().correlationID("cget"),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val reply = outcome.value?.let { ConversationWire.decodeSessionReply(it) }
                    if (reply != null) {
                        entry.builder.applySession(reply)
                        val projection = currentModels()
                        entry.builder.applyModels(projection.models, projection.needsProvider)
                        entry.holder.applyHostSnapshot(entry.builder.build())
                        loadMessagePage(session, entry)
                        resumeLiveRuns(session, entry, reply)
                        // The authoritative CAS snapshot (run revision,
                        // approval requestedAt, pending-input versions and
                        // queue order) for the selected run.
                        entry.builder.selectedRunId?.let { runID ->
                            refreshRunSnapshot(entry, runID)
                        }
                        if (reply.runs.isNotEmpty()) {
                            loadChildRuns(entry, entry.builder.selectedRunId
                                ?: reply.runs.last().runID)
                        }
                    }
                }
                is HostOperationOutcome.Rejected ->
                    entry.builder.markMissing(outcome.code)
                is HostOperationOutcome.Failed ->
                    entry.builder.markMissing(outcome.code)
                HostOperationOutcome.Cancelled, HostOperationOutcome.Superseded -> Unit
            }
        }
    }

    /**
     * Reads the ACTUAL typed `run.snapshot` page (F7 carrier) and applies its
     * authoritative revisions. This is the only CAS source for cancel/steer/
     * retry/queue-order/approval resolve; when the read fails the caller
     * refuses the command honestly instead of sending a fabricated version.
     *
     * The page is ALSO the only authoritative source of the live answer /
     * reasoning text (the durable event pages flush only at segment
     * boundaries). Its text is projected by replacement for the selected,
     * still-owned active run only — fenced on holder identity, session epoch,
     * stream incarnation and current run AFTER the await, so a late reply for
     * a replaced holder, a retired session, a previous retry incarnation or a
     * re-selected run can never mutate the tail. A terminal page for a run
     * that is NOT the current selection may update that old run's durable
     * state, but it never clears/closes the selected run's live tail.
     * With [reconcileTerminal], an authoritative terminal page for the
     * SELECTED run also performs the one bounded committed-row reconciliation
     * (the pump may have died before any durable terminal frame arrived).
     */
    private fun refreshRunSnapshot(
        entry: ConversationFlowHolderEntry,
        runID: String,
        reconcileTerminal: Boolean = false,
        streamGeneration: Long? = null,
        onApplied: ((Boolean) -> Unit)? = null,
    ) {
        val ownerConversation = entry.holder.session.conversationId
        val sessionEpoch = entry.holder.session.sessionEpoch
        val generation = streamGeneration
            ?: currentRunStreamGeneration(ownerConversation, runID)
        host.trackOperation(
            HostCommandRequest(
                command = "run.snapshot",
                scope = HostScope.TaskExecution(ownerConversation, runID),
                stateful = false,
                correlationID = client().correlationID("rsnap"),
            ),
        ) { outcome ->
            var applied = false
            if (outcome is HostOperationOutcome.Completed) {
                val page = ConversationWire.decodeSnapshotPage(outcome.value)
                val owned = ownCurrentEntry(entry, ownerConversation, sessionEpoch)
                val sameIncarnation =
                    currentRunStreamGeneration(ownerConversation, runID) == generation
                if (page != null && owned && sameIncarnation) {
                    entry.builder.applySnapshot(page)
                    val watermarkKey = streamKey(ownerConversation, runID)
                    if (page.durableWatermark >
                        (runDurableWatermarks[watermarkKey] ?: 0L)
                    ) {
                        runDurableWatermarks[watermarkKey] = page.durableWatermark
                    }
                    val selectedHere = entry.builder.selectedRunId == runID
                    if (selectedHere) entry.builder.applySnapshotLiveText(page)
                    entry.holder.applyHostSnapshot(entry.builder.build())
                    applied = true
                    if (reconcileTerminal && page.isTerminal) {
                        // A terminal page is the durable close boundary for
                        // ITS OWN run. Close that run's pump; only the SELECTED
                        // run may clear the displayed tail and reload rows.
                        eventPumps.remove(runID)?.close()
                        if (selectedHere) {
                            reconcileTerminalCommitted(entry, runID, generation)
                        } else {
                            refreshHistorySoon()
                        }
                    }
                }
            }
            onApplied?.invoke(applied)
        }
    }

    /** True while [entry] still owns [conversationId] at [sessionEpoch]. */
    private fun ownCurrentEntry(
        entry: ConversationFlowHolderEntry,
        conversationId: String,
        sessionEpoch: Long,
    ): Boolean {
        val current = holders[conversationId]
        return current === entry &&
            !entry.holder.retired &&
            entry.holder.session.conversationId == conversationId &&
            entry.holder.session.sessionEpoch == sessionEpoch
    }

    private fun streamKey(conversationId: String, runID: String): String =
        "$conversationId/$runID"

    private fun currentRunStreamGeneration(conversationId: String, runID: String): Long =
        runStreamGenerations[streamKey(conversationId, runID)] ?: 0L

    // ------------------------------------------- live streaming reconciliation

    /**
     * One live poll carried live frames (or an explicit resync) for the
     * selected active run. The signal is a DIRTY HINT only: it never carries
     * text and never advances the durable cursor. Coalesce it into one
     * canonical `run.snapshot` refresh per bounded window.
     */
    private fun onLiveDirtyHint(
        entry: ConversationFlowHolderEntry,
        runID: String,
        conversationId: String,
        sessionEpoch: Long,
        streamGeneration: Long,
    ) {
        if (!admitted()) return
        if (!ownCurrentEntry(entry, conversationId, sessionEpoch)) return
        if (currentRunStreamGeneration(conversationId, runID) != streamGeneration) return
        if (entry.builder.selectedRunId != runID) return
        val existing = liveSnapshotRefreshes[runID]
        val state = if (existing == null || existing.generation != streamGeneration) {
            LiveSnapshotRefreshState(streamGeneration).also {
                liveSnapshotRefreshes[runID] = it
            }
        } else {
            existing
        }
        state.dirty.set(true)
        maybeStartLiveSnapshotRefresh(entry, runID, state)
    }

    /**
     * Starts the single in-flight canonical refresh for [runID] when due.
     * Hints that arrive during an in-flight read stay dirty and produce ONE
     * follow-up after it settles (never a per-frame/per-token snapshot storm).
     * A failed read keeps the hint dirty but never auto-launches a retry: the
     * next REAL hint or an explicit read may start the bounded refresh.
     */
    private fun maybeStartLiveSnapshotRefresh(
        entry: ConversationFlowHolderEntry,
        runID: String,
        state: LiveSnapshotRefreshState,
    ) {
        if (!admitted() || entry.holder.retired) return
        val conversationId = entry.holder.session.conversationId
        if (state.generation != currentRunStreamGeneration(conversationId, runID)) {
            state.dirty.set(false)
            state.inFlight.set(false)
            return
        }
        if (!ownCurrentEntry(entry, conversationId, entry.holder.session.sessionEpoch)) return
        if (entry.builder.selectedRunId != runID) {
            state.dirty.set(false)
            return
        }
        if (state.inFlight.get()) return
        val interval = client().budgets.effectPollIntervalMillis
        val now = System.currentTimeMillis()
        val elapsed = now - state.lastStartedAtMillis
        if (elapsed in 0L until interval) {
            scheduleLiveSnapshotFollowUp(entry, runID, state, interval - elapsed)
            return
        }
        if (!state.dirty.compareAndSet(true, false)) return
        if (!state.inFlight.compareAndSet(false, true)) {
            state.dirty.set(true)
            return
        }
        state.lastStartedAtMillis = now
        val sessionEpoch = entry.holder.session.sessionEpoch
        refreshRunSnapshot(
            entry,
            runID,
            reconcileTerminal = true,
            streamGeneration = state.generation,
        ) { applied ->
            state.inFlight.set(false)
            val sameIncarnation =
                state.generation == currentRunStreamGeneration(conversationId, runID)
            val stillOwned = sameIncarnation &&
                ownCurrentEntry(entry, conversationId, sessionEpoch) &&
                entry.builder.selectedRunId == runID
            if (!stillOwned) {
                state.dirty.set(false)
            } else if (!applied) {
                // The tail is untouched; keep the hint dirty for a LATER real
                // hint / explicit read. Do not start an automatic retry here.
                state.dirty.set(true)
            } else if (state.dirty.get()) {
                maybeStartLiveSnapshotRefresh(entry, runID, state)
            }
        }
    }

    /** One bounded delayed follow-up per run; never a polling loop. */
    private fun scheduleLiveSnapshotFollowUp(
        entry: ConversationFlowHolderEntry,
        runID: String,
        state: LiveSnapshotRefreshState,
        waitMillis: Long,
    ) {
        if (!state.followUpScheduled.compareAndSet(false, true)) return
        host.scope.launch(host.ioDispatcher) {
            try {
                delay(waitMillis.coerceAtLeast(1L))
            } finally {
                state.followUpScheduled.set(false)
            }
            val conversationId = entry.holder.session.conversationId
            if (state.generation == currentRunStreamGeneration(conversationId, runID) &&
                !entry.holder.retired && holders[conversationId] === entry
            ) {
                maybeStartLiveSnapshotRefresh(entry, runID, state)
            }
        }
    }

    /**
     * Bounded, idempotent committed-row reconciliation for a run whose
     * terminal was learned from the AUTHORITATIVE snapshot (the event pump
     * may have died on `notAttached`/`runGone` before any durable terminal
     * frame — the observed same-screen second-send UI gap).
     *
     * Only the SELECTED run may reconcile here: a late terminal snapshot or
     * durable terminal callback for an OLD run must not clear/close the live
     * tail of the newer selected run. The cache key includes the trusted
     * local stream generation, so a previous retry incarnation can never
     * suppress the resumed incarnation's terminal reload, and a failed
     * committed-page read is retried by the next legitimate terminal/explicit
     * recovery instead of being marked done.
     */
    private fun reconcileTerminalCommitted(
        entry: ConversationFlowHolderEntry,
        runID: String,
        streamGeneration: Long = currentRunStreamGeneration(
            entry.holder.session.conversationId, runID),
    ) {
        if (!conversationAdmitted()) return
        val conversationId = entry.holder.session.conversationId
        val sessionEpoch = entry.holder.session.sessionEpoch
        if (entry.builder.selectedRunId != runID) return
        if (!ownCurrentEntry(entry, conversationId, sessionEpoch)) return
        if (currentRunStreamGeneration(conversationId, runID) != streamGeneration) return
        val key = terminalKey(conversationId, runID, streamGeneration)
        if (terminalReconciled.contains(key)) return
        if (!terminalReconcileInFlight.add(key)) return
        if (terminalReconciled.contains(key) ||
            entry.builder.selectedRunId != runID ||
            !ownCurrentEntry(entry, conversationId, sessionEpoch) ||
            currentRunStreamGeneration(conversationId, runID) != streamGeneration
        ) {
            terminalReconcileInFlight.remove(key)
            return
        }
        reconcileCommittedRows(entry, runID) { applied ->
            terminalReconcileInFlight.remove(key)
            if (applied) terminalReconciled.add(key)
        }
    }

    /**
     * The durable close boundary: stop the run's pump, drop the live tail so
     * the same text is never rendered twice, and re-read the committed
     * user/assistant rows (the live tail alone never showed the user's own
     * message). Only the selected run's tail is cleared; a late old-run
     * terminal keeps the newer run's live answer intact. Bounded: one
     * successful invocation per terminal run/generation.
     */
    private fun reconcileCommittedRows(
        entry: ConversationFlowHolderEntry,
        runID: String,
        onSettled: (Boolean) -> Unit,
    ) {
        eventPumps.remove(runID)?.close()
        refreshHistorySoon()
        val conversationId = entry.holder.session.conversationId
        if (!ownCurrentEntry(
                entry, conversationId, entry.holder.session.sessionEpoch,
            )
        ) {
            onSettled(false)
            return
        }
        if (entry.builder.selectedRunId != runID) {
            onSettled(false)
            return
        }
        entry.builder.closeLiveTail(runID)
        entry.holder.applyHostSnapshot(entry.builder.build())
        if (!conversationAdmitted()) {
            onSettled(false)
            return
        }
        loadMessagePage(entry.holder.session, entry, onSettled = onSettled)
    }

    private fun terminalKey(
        conversationId: String,
        runID: String,
        streamGeneration: Long,
    ): String = "$conversationId:$runID:$streamGeneration"

    /**
     * Loads the durable child graph (`child.list`) for one parent run and
     * projects the real rows (no UI-emulated children).
     */
    private fun loadChildRuns(entry: ConversationFlowHolderEntry, parentRunID: String) {
        if (!admitted()) return
        host.trackOperation(
            HostCommandRequest(
                command = "child.list",
                scope = HostScope.TaskExecution(entry.holder.session.conversationId, parentRunID),
                stateful = false,
                correlationID = client().correlationID("cchildlist"),
            ),
        ) { outcome ->
            if (outcome is HostOperationOutcome.Completed) {
                val rows = ConversationWire.decodeChildList(outcome.value) {
                    childStateTitle(it)
                }
                if (rows.isNotEmpty() || outcome.value != null) {
                    entry.builder.applyChildRuns(rows)
                    entry.holder.applyHostSnapshot(entry.builder.build())
                }
            }
        }
    }

    /**
     * Host-localized child state title (never a raw machine name). The
     * English fallback exists only for host-unit environments with no
     * Application context; production always resolves the resource.
     */
    private fun childStateTitle(state: String): String {
        val res = when (state) {
            "completed" -> com.floe.android.R.string.run_state_completed
            "failed" -> com.floe.android.R.string.run_state_failed
            "checkpointed" -> com.floe.android.R.string.run_state_checkpointed
            "interrupted" -> com.floe.android.R.string.run_state_interrupted
            "cancelling" -> com.floe.android.R.string.run_state_cancelling
            "idle", "" -> com.floe.android.R.string.run_state_idle
            else -> com.floe.android.R.string.run_state_running
        }
        return runCatching { host.appContext.getString(res) }.getOrElse {
            when (state) {
                "completed" -> "Completed"
                "failed" -> "Failed"
                "checkpointed" -> "Paused"
                "interrupted" -> "Interrupted"
                "cancelling" -> "Cancelling"
                "idle", "" -> "Idle"
                else -> "Running"
            }
        }
    }

    private fun loadMessagePage(
        session: ConversationSessionToken,
        entry: ConversationFlowHolderEntry,
        before: MessagePageCursorUi? = null,
        onSettled: ((Boolean) -> Unit)? = null,
    ) {
        val members = mutableMapOf<String, JsonElement>(
            "limit" to JsonPrimitive(20),
        )
        if (before != null) {
            // The native cursor is the opaque `k1.` keyset string, never a
            // synthetic {createdAt,id} object. A cursor that cannot be
            // re-encoded refuses the request instead of silently paging from
            // the wrong position.
            val opaque = ConversationWire.encodeOpaqueMessageCursor(before)
            if (opaque == null) {
                onSettled?.invoke(false)
                return
            }
            members["before"] = JsonPrimitive(opaque)
        }
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.messagePage",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = false,
                correlationID = client().correlationID("cpage"),
                payload = JsonObject(members),
            ),
        ) { outcome ->
            var applied = false
            if (outcome is HostOperationOutcome.Completed) {
                val page = outcome.value?.let { ConversationWire.decodeMessagePage(it) }
                if (page != null &&
                    ownCurrentEntry(entry, session.conversationId, session.sessionEpoch)
                ) {
                    entry.builder.applyMessagePage(page, earlier = before != null)
                    entry.builder.earlierCursor = page.earlierCursor
                    entry.builder.hasEarlierMessages = page.hasEarlier
                    entry.holder.applyHostSnapshot(entry.builder.build())
                    applied = true
                }
            }
            onSettled?.invoke(applied)
        }
    }

    private fun resumeLiveRuns(
        session: ConversationSessionToken,
        entry: ConversationFlowHolderEntry,
        reply: ConversationWire.SessionReply,
    ) {
        for (run in reply.runs) {
            // Only a genuinely live native window is pumped. Terminal rows
            // (completed/failed/checkpointed/idle) and the parked
            // `interrupted` dead-generation marker have no window: opening a
            // pump there would poll `notAttached` forever.
            if (ConversationWire.isActiveState(run.state)) {
                openRunEventStream(session, entry, run.runID)
            }
        }
    }

    override fun loadThread(session: ConversationSessionToken) {
        loadThreadInternal(session)
    }

    override fun threadViewDetached(session: ConversationSessionToken) {
        // View detach is NOT navigation: the session and its pumps survive.
    }

    override fun requestOpenConversation(
        sourceSession: ConversationSessionToken?,
        conversationId: String,
    ): Boolean {
        if (!conversationAdmitted()) return false
        // Host-side route revalidation before any navigation.
        navigationRequest.value = SidebarSelection.Conversation(conversationId)
        return true
    }

    override fun requestNewTask(sourceSession: ConversationSessionToken?): Boolean {
        // The shell owns the route; fencing of a temp origin (if any) happens
        // in the shell via [tempFence] before the transition completes.
        navigationRequest.value = SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK)
        return true
    }

    // -------------------------------------------------------------- run launch

    override fun startRun(
        request: RunLaunchRequest,
        onOutcome: ((admitted: Boolean, reason: String?) -> Unit)?,
    ): Boolean = startRunWithOutcome(request, onOutcome)

    /**
     * Launch with an optional admission-outcome listener: invoked exactly
     * once with (admitted=true) after the real prepared handoff, or
     * (admitted=false, typedReason) when the launch failed before execution.
     * Surfaces (e.g. the Home launchpad) keep their send ownership until
     * this settles instead of guessing from the synchronous boolean.
     */
    internal fun startRunWithOutcome(
        request: RunLaunchRequest,
        onOutcome: ((admitted: Boolean, reason: String?) -> Unit)?,
    ): Boolean {
        if (!admitted()) {
            onOutcome?.invoke(false, "runtime_unavailable")
            return false
        }
        val entry = holders[request.conversationId] ?: run {
            onOutcome?.invoke(false, "session_unavailable")
            return false
        }
        val correlation = request.correlation()
        launchCorrelations[correlation.launchGeneration.toString()] = correlation
        if (onOutcome != null) {
            launchOutcomeListeners[correlation.launchGeneration] = onOutcome
        }
        // The conversation-row digest advances on EVERY durable launch/message
        // commit, so the cached builder revision from an earlier send is stale
        // by the time a LATER send on the same screen launches: reusing it is
        // the exact second-send `run.start` `conversationProof`
        // revisionMismatch observed on the real cloud path. ALWAYS read the
        // current row at action time — the same source of truth the steer and
        // queue CAS paths already use — fenced on owner/epoch across the await.
        launchWithFreshConversationRevision(request, entry, correlation)
        return true
    }

    /**
     * Reads the CURRENT conversation-row revision (`conversation.get`) at
     * launch time and continues into [launchRun] only when the requesting
     * session still owns the current holder: the registry entry is unchanged,
     * the conversation selection is the same and the session epoch matches
     * (retirement/rebind bump the epoch; a replaced holder owns a new one).
     * A late reply therefore never launches into a different conversation or
     * session. Any failure or fencing settles the launch failure on [entry]
     * so the retained send commit restores its draft exactly once through the
     * correlation echo; the run.start CAS itself stays strict (a genuinely
     * concurrent edit still returns the typed revisionMismatch).
     */
    private fun launchWithFreshConversationRevision(
        request: RunLaunchRequest,
        entry: ConversationFlowHolderEntry,
        correlation: LaunchCorrelation,
    ) {
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(request.conversationId),
                stateful = false,
                correlationID = client().correlationID("cget-pre"),
            ),
        ) { outcome ->
            if (outcome !is HostOperationOutcome.Completed) {
                settleLaunchFailure(entry, correlation, "revision_unavailable")
                return@trackOperation
            }
            val reply = outcome.value?.let { ConversationWire.decodeSessionReply(it) }
            val current = holders[request.conversationId]
            if (reply == null || current == null || current !== entry ||
                current.holder.session.conversationId != request.conversationId ||
                current.holder.session.sessionEpoch != request.sessionEpoch ||
                current.holder.retired
            ) {
                settleLaunchFailure(entry, correlation, "revision_unavailable")
                return@trackOperation
            }
            current.builder.applySession(reply)
            current.holder.applyHostSnapshot(current.builder.build())
            launchRun(
                request, current, correlation,
                current.builder.conversationRevision?.let {
                    HostRevision(it.resourceID, it.version)
                },
            )
        }
    }

    private fun launchRun(
        request: RunLaunchRequest,
        entry: ConversationFlowHolderEntry,
        correlation: LaunchCorrelation,
        revision: HostRevision?,
    ) {
        if (revision == null) {
            settleLaunchFailure(entry, correlation, "revision_unavailable")
            return
        }
        // The frozen `run.start` grammar REQUIRES providerID + modelID as
        // non-nil UUIDs; a launch without the real selected identities is
        // refused here (typed, reversible) instead of sending an invalid
        // envelope the domain would reject with payloadInvalid.
        val providerId = request.providerId?.takeIf { it.isNotBlank() }
        val modelId = request.modelId?.takeIf { it.isNotBlank() }
        if (providerId == null || modelId == null) {
            settleLaunchFailure(entry, correlation, "model_unavailable")
            return
        }
        // The frozen run.start terminal is an identifier-only `accepted`; the
        // minted conversation/run identities exist ONLY in the non-terminal
        // `prepared` effect emitted after the atomic launch commit. Consume
        // exactly one prepared echo, then hand the run to its event pump.
        val preparedRunID = java.util.concurrent.atomic.AtomicReference<String?>(null)
        fun acceptPrepared(prepared: ConversationWire.Prepared) {
            if (!preparedRunID.compareAndSet(null, prepared.runID)) return
            launchOutcomeListeners.remove(correlation.launchGeneration)?.invoke(true, null)
            entry.builder.applyPrepared(prepared)
            entry.holder.applyLaunchPrepared(correlation)
            clearDraftAfterSend(
                ConversationSessionToken(request.conversationId, request.sessionEpoch),
                request.goalText,
                request.attachments.map { it.id })
            openRunEventStream(
                ConversationSessionToken(request.conversationId, request.sessionEpoch),
                entry,
                prepared.runID,
            )
            refreshHistorySoon()
            // Launch committed a real run row: refresh its authoritative CAS
            // snapshot so cancel/steer are immediately available.
            refreshRunSnapshot(entry, prepared.runID)
        }
        host.trackOperation(
            request = HostCommandRequest(
                command = "run.start",
                scope = HostScope.LaunchExisting(request.conversationId),
                stateful = true,
                correlationID = client().correlationID("rstart"),
                revision = revision,
                payload = ConversationWire.runStartPayload(request),
            ),
            onFrame = { frame ->
                if (frame.kind == "prepared") {
                    ConversationWire.preparedFromEffect(frame.detail)?.let(::acceptPrepared)
                }
            },
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    // A typed value reply is accepted for forward compatibility;
                    // the actual producer delivers `prepared` as an effect frame.
                    val prepared = outcome.value?.let { ConversationWire.decodePrepared(it) }
                    if (prepared != null) {
                        acceptPrepared(prepared)
                    } else if (preparedRunID.get() == null) {
                        launchCorrelations.remove(correlation.launchGeneration.toString())
                        entry.holder.applyLaunchFailure(correlation, "launch_malformed")
                        launchOutcomeListeners.remove(correlation.launchGeneration)
                            ?.invoke(false, "launch_malformed")
                    }
                }
                is HostOperationOutcome.Rejected -> {
                    launchCorrelations.remove(correlation.launchGeneration.toString())
                    preparedRunID.get()?.let { eventPumps.remove(it)?.close() }
                    entry.holder.applyLaunchFailure(correlation, outcome.code)
                    launchOutcomeListeners.remove(correlation.launchGeneration)
                        ?.invoke(false, outcome.code)
                }
                is HostOperationOutcome.Failed -> {
                    launchCorrelations.remove(correlation.launchGeneration.toString())
                    preparedRunID.get()?.let { eventPumps.remove(it)?.close() }
                    entry.holder.applyLaunchFailure(correlation, outcome.code)
                    launchOutcomeListeners.remove(correlation.launchGeneration)
                        ?.invoke(false, outcome.code)
                }
                HostOperationOutcome.Cancelled -> {
                    launchCorrelations.remove(correlation.launchGeneration.toString())
                    preparedRunID.get()?.let { eventPumps.remove(it)?.close() }
                    entry.holder.applyLaunchFailure(correlation, "cancelled")
                    launchOutcomeListeners.remove(correlation.launchGeneration)
                        ?.invoke(false, "cancelled")
                }
                HostOperationOutcome.Superseded ->
                    launchOutcomeListeners.remove(correlation.launchGeneration)
                        ?.invoke(false, "superseded")
            }
        }
    }

    private fun settleLaunchFailure(
        entry: ConversationFlowHolderEntry,
        correlation: LaunchCorrelation,
        reason: String,
    ) {
        launchCorrelations.remove(correlation.launchGeneration.toString())
        // Settle the holder projection FIRST: the outcome listener is the
        // caller-visible completion signal, so the restored draft and the
        // typed action error must already be consistent when it fires. The
        // reverse order let a fast listener observe outcome=false while
        // holder.actionError was still null (the exact old-BBB focused JVM
        // failure); a late/stale failure still touches nothing because the
        // holder fences the correlation itself.
        entry.holder.applyLaunchFailure(correlation, reason)
        launchOutcomeListeners.remove(correlation.launchGeneration)?.invoke(false, reason)
    }

    /** Create a real ordinary conversation (New Task send path). */
    fun createConversationForLaunch(
        title: String?,
        onCreated: (String) -> Unit,
        onFailure: (String) -> Unit,
    ): Boolean {
        if (!conversationAdmitted()) return false
        val payload = title?.takeIf { it.isNotBlank() }?.let {
            JsonObject(mapOf("title" to JsonPrimitive(it.take(120))))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.create",
                scope = HostScope.LaunchNewIdentity,
                stateful = true,
                correlationID = client().correlationID("ccreate"),
                createIntent = true,
                payload = payload,
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val id = (outcome.value as? JsonObject)
                        ?.let { (it["conversationID"] as? JsonPrimitive)?.contentOrNull }
                    if (id != null) {
                        refreshHistorySoon()
                        onCreated(id)
                    } else {
                        onFailure("create_malformed")
                    }
                }
                is HostOperationOutcome.Rejected -> onFailure(outcome.code)
                is HostOperationOutcome.Failed -> onFailure(outcome.code)
                HostOperationOutcome.Cancelled -> onFailure("cancelled")
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    private fun refreshHistorySoon() {
        refreshHistory()
    }

    private fun openRunEventStream(
        session: ConversationSessionToken,
        entry: ConversationFlowHolderEntry,
        runID: String,
        streamGeneration: Long = currentRunStreamGeneration(
            session.conversationId, runID),
        afterSequence: Long = 0L,
    ) {
        if (eventPumps.containsKey(runID)) return
        val conversationId = session.conversationId
        val sessionEpoch = session.sessionEpoch
        val handle = client().openRunEventStream(
            taskID = conversationId,
            runID = runID,
            environmentID = null,
            jobID = null,
            onEvent = { frame ->
                onRunEvent(
                    entry, runID, frame, conversationId, sessionEpoch, streamGeneration,
                )
            },
            onLiveHint = {
                onLiveDirtyHint(
                    entry, runID, conversationId, sessionEpoch, streamGeneration,
                )
            },
            startSequence = afterSequence,
            onFailure = { failure ->
                // A stale pump incarnation (the same run id was retried) must
                // not close the NEW pump or reconcile the resumed prefix.
                if (!ownCurrentEntry(entry, conversationId, sessionEpoch)) {
                    return@openRunEventStream
                }
                if (currentRunStreamGeneration(conversationId, runID) != streamGeneration) {
                    return@openRunEventStream
                }
                // A pump death is NEVER swallowed: the typed failure becomes a
                // visible banner and the run is reconciled against the real
                // durable snapshot instead of polling forever. That snapshot
                // is authoritative: when it reports the terminal state the
                // committed rows are reloaded exactly once — a fast run whose
                // window detached before any durable terminal frame must
                // still land its messages on the same screen.
                eventPumps.remove(runID)?.close()
                val code = when (failure) {
                    is HostPumpFailure.Recoverable -> failure.code
                    HostPumpFailure.Superseded -> return@openRunEventStream
                }
                entry.builder.eventStreamFailure(runID, code)
                entry.holder.applyHostSnapshot(entry.builder.build())
                refreshRunSnapshot(
                    entry,
                    runID,
                    reconcileTerminal = true,
                    streamGeneration = streamGeneration,
                )
            },
        )
        eventPumps[runID] = handle
    }

    private fun onRunEvent(
        entry: ConversationFlowHolderEntry,
        runID: String,
        frame: HostRunEventFrame,
        conversationId: String,
        sessionEpoch: Long,
        streamGeneration: Long,
    ) {
        // A callback from a previous incarnation (same retried run id) or a
        // rebound/retired holder can never mutate the resumed projection.
        if (!ownCurrentEntry(entry, conversationId, sessionEpoch)) return
        if (currentRunStreamGeneration(conversationId, runID) != streamGeneration) return
        entry.builder.applyRunEvent(frame)
        entry.holder.applyHostSnapshot(entry.builder.build())
        if (ConversationWire.isTerminalFrame(frame)) {
            // Durable close boundary: stop THIS run's pump and re-read the
            // committed user/assistant rows plus the authoritative snapshot.
            // A terminal for a run that is no longer selected updates that
            // old run's state/history only; reconcileTerminalCommitted fences
            // the selected run's live tail so B keeps streaming.
            eventPumps.remove(runID)?.close()
            if (entry.builder.selectedRunId != runID) refreshHistorySoon()
            reconcileTerminalCommitted(entry, runID, streamGeneration)
            refreshRunSnapshot(
                entry, runID, streamGeneration = streamGeneration,
            )
        } else if (frame.kind == "approval") {
            // A live approval request needs its requestedAt CAS version, which
            // only the authoritative snapshot carries; the card itself is
            // already projected from the durable event.
            refreshRunSnapshot(
                entry, runID, streamGeneration = streamGeneration,
            )
        }
    }

    // ----------------------------------------------------------- run control

    /**
     * Mid-run input. Both branches use the EXACT frozen grammar:
     *
     * * queue → `run.queue {content,mode:"queue",selectedModelID?,stagedAttachments?}`
     *   under the CURRENT conversation-row revision (the row advances on every
     *   launch/message commit, so it is re-read at action time).
     * * steer → the durable row first exists (`run.queue`), then
     *   `run.steer {inputID:<durable row uuid>, expectedState}` under the run's
     *   `run.<uuid>/<state>` revision. A steer can never bypass the durable
     *   exactly-once row the native store owns.
     */
    override fun submitRunningInput(request: RunningInputRequest): Boolean {
        if (!admitted()) return false
        val entry = holders[request.conversationId] ?: return false
        if (request.mode == RunningInputModeUi.STEER) {
            return submitSteer(request, entry)
        }
        withFreshConversationRevision(entry) { conversationRevision ->
            if (conversationRevision == null) {
                surfaceError(entry, "revision_unavailable")
                return@withFreshConversationRevision
            }
            host.trackOperation(
                HostCommandRequest(
                    command = "run.queue",
                    scope = HostScope.TaskExecution(
                        request.conversationId, request.expectedRunId),
                    stateful = true,
                    correlationID = client().correlationID("rqueue"),
                    revision = conversationRevision,
                    payload = ConversationWire.runningInputPayload(request),
                ),
            ) { outcome ->
                when (outcome) {
                    is HostOperationOutcome.Completed -> {
                        // Queue accepted ≠ approval resolved ≠ run started; the
                        // durable row identity is the real receipt.
                        outcome.detail["inputID"]?.let {
                            entry.builder.clearActionError()
                            entry.holder.applyHostSnapshot(entry.builder.build())
                            entry.builder.selectedRunId?.let { runID ->
                                refreshRunSnapshot(entry, runID)
                            }
                        }
                    }
                    is HostOperationOutcome.Rejected -> surfaceError(entry, outcome.code)
                    is HostOperationOutcome.Failed -> surfaceError(entry, outcome.code)
                    else -> Unit
                }
            }
        }
        return true
    }

    private fun submitSteer(request: RunningInputRequest, entry: ConversationFlowHolderEntry): Boolean {
        withFreshConversationRevision(entry) { conversationRevision ->
            if (conversationRevision == null) {
                surfaceError(entry, "revision_unavailable")
                return@withFreshConversationRevision
            }
            // Step 1: the durable queue row (real store identity + receipt).
            host.trackOperation(
                HostCommandRequest(
                    command = "run.queue",
                    scope = HostScope.TaskExecution(
                        request.conversationId, request.expectedRunId),
                    stateful = true,
                    correlationID = client().correlationID("rqsteer"),
                    revision = conversationRevision,
                    payload = JsonObject(
                        buildMap {
                            put("content", JsonPrimitive(request.content))
                            put("mode", JsonPrimitive(RunningInputModeUi.QUEUE.swiftRaw))
                            request.modelId?.let { put("selectedModelID", JsonPrimitive(it)) }
                            val handles = request.attachments.filter { it.isReady }
                                .map { JsonPrimitive(it.id) }
                            if (handles.isNotEmpty()) put("stagedAttachments", JsonArray(handles))
                        },
                    ),
                ),
            ) { outcome ->
                val inputID = (outcome as? HostOperationOutcome.Completed)?.detail?.get("inputID")
                if (outcome !is HostOperationOutcome.Completed || inputID == null) {
                    if (outcome is HostOperationOutcome.Rejected) {
                        surfaceError(entry, outcome.code)
                    } else if (outcome is HostOperationOutcome.Failed) {
                        surfaceError(entry, outcome.code)
                    }
                    return@trackOperation
                }
                // Step 2: promote the durable row through the run revision.
                dispatchRunStateControl(
                    entry = entry,
                    runID = request.expectedRunId,
                    command = "run.steer",
                    correlationPrefix = "rsteer",
                    payloadFor = { state ->
                        ConversationWire.steerPayload(inputID, state)
                    },
                    onCompleted = { completed ->
                        val detail = completed.detail
                        if (detail["promoted"] == "false") {
                            // Native steerTargetEndedQueued: the row stays
                            // queued. Surface it; never claim a promotion.
                            surfaceError(entry, "steer_target_ended_queued")
                        }
                        entry.builder.clearActionError()
                        entry.holder.applyHostSnapshot(entry.builder.build())
                        entry.builder.selectedRunId?.let { refreshRunSnapshot(entry, it) }
                    },
                )
            }
        }
        return true
    }

    /**
     * Reads the CURRENT conversation-row revision (`conversation.get`) at
     * action time. The conversation row's digest advances on every real
     * launch/message commit, so a cached revision cannot be reused for a
     * later `run.queue`/`run.input.*` CAS.
     */
    private fun withFreshConversationRevision(
        entry: ConversationFlowHolderEntry,
        onReady: (HostRevision?) -> Unit,
    ) {
        val conversationID = entry.holder.session.conversationId
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(conversationID),
                stateful = false,
                correlationID = client().correlationID("cget-cas"),
            ),
        ) { outcome ->
            if (outcome is HostOperationOutcome.Completed) {
                val reply = outcome.value?.let { ConversationWire.decodeSessionReply(it) }
                if (reply != null) {
                    entry.builder.applySession(reply)
                    onReady(reply.revision?.let { HostRevision(it.resourceID, it.version) })
                    return@trackOperation
                }
            }
            onReady(null)
        }
    }

    /**
     * Dispatches a run-state CAS command (`run.cancel`/`run.retry`/
     * `run.steer`) under the tracked `run.<uuid>/<durable state>` revision,
     * reading the authoritative snapshot first when the projection has no
     * revision yet. One bounded stale retry after a fresh snapshot keeps a
     * fast state transition from surfacing as a spurious failure; no "any"
     * sentinel and no repeated blind retry ever leave the App.
     */
    private fun dispatchRunStateControl(
        entry: ConversationFlowHolderEntry,
        runID: String,
        command: String,
        correlationPrefix: String,
        payloadFor: (state: String) -> JsonObject,
        onCompleted: (HostOperationOutcome.Completed) -> Unit = { },
    ) {
        fun submit(state: String, revision: Revision, isRetry: Boolean) {
            host.trackOperation(
                HostCommandRequest(
                    command = command,
                    scope = HostScope.TaskExecution(
                        entry.holder.session.conversationId, runID),
                    stateful = true,
                    correlationID = client().correlationID(correlationPrefix),
                    revision = HostRevision(revision.resourceID, revision.version),
                    payload = payloadFor(state),
                ),
            ) { outcome ->
                when (outcome) {
                    is HostOperationOutcome.Completed -> onCompleted(outcome)
                    is HostOperationOutcome.Rejected -> {
                        if (!isRetry) {
                            refreshRunSnapshot(entry, runID) { applied ->
                                val freshState = entry.builder.runStateName(runID)
                                val freshRevision = entry.builder.runRevision(runID)
                                if (applied && freshState != null &&
                                    freshRevision != null && freshState != state
                                ) {
                                    submit(freshState, freshRevision, true)
                                } else {
                                    surfaceError(entry, outcome.code)
                                }
                            }
                        } else {
                            surfaceError(entry, outcome.code)
                        }
                    }
                    is HostOperationOutcome.Failed -> surfaceError(entry, outcome.code)
                    else -> Unit
                }
            }
        }
        val state = entry.builder.runStateName(runID)
        val revision = entry.builder.runRevision(runID)
        if (state != null && revision != null) {
            submit(state, revision, false)
            return
        }
        refreshRunSnapshot(entry, runID) { applied ->
            val freshState = entry.builder.runStateName(runID)
            val freshRevision = entry.builder.runRevision(runID)
            if (applied && freshState != null && freshRevision != null) {
                submit(freshState, freshRevision, false)
            } else {
                surfaceError(entry, "snapshot_unavailable")
            }
        }
    }

    private fun surfaceError(entry: ConversationFlowHolderEntry, code: String) {
        entry.builder.actionError(code)
        entry.holder.applyHostSnapshot(entry.builder.build())
    }

    override fun cancelRun(session: ConversationSessionToken, runId: String): Boolean {
        if (!admitted()) return false
        val entry = holders[session.conversationId] ?: return false
        // `run.cancel` requires revision run.<runID>/<state> AND
        // expectedState == the durable record state (any "any" sentinel is a
        // guaranteed staleRevision).
        dispatchRunStateControl(
            entry = entry,
            runID = runId,
            command = "run.cancel",
            correlationPrefix = "rcancel",
            payloadFor = { state ->
                JsonObject(mapOf("expectedState" to JsonPrimitive(state)))
            },
        )
        return true
    }

    override fun retryRun(session: ConversationSessionToken, runId: String): Boolean {
        if (!admitted()) return false
        val entry = holders[session.conversationId] ?: return false
        if (entry.holder.retired ||
            entry.holder.session.conversationId != session.conversationId ||
            entry.holder.session.sessionEpoch != session.sessionEpoch
        ) {
            return false
        }
        dispatchRunStateControl(
            entry = entry,
            runID = runId,
            command = "run.retry",
            correlationPrefix = "rretry",
            payloadFor = { state ->
                JsonObject(mapOf("expectedState" to JsonPrimitive(state)))
            },
            onCompleted = {
                // A REAL accepted run.retry re-opens the SAME durable run id
                // as a NEW stream incarnation. Only here may the closed-tail
                // guard be lifted; the generation fences every callback or
                // snapshot reply that belonged to the previous incarnation.
                val conversationId = entry.holder.session.conversationId
                val sessionEpoch = entry.holder.session.sessionEpoch
                if (ownCurrentEntry(entry, conversationId, sessionEpoch) &&
                    entry.builder.selectedRunId == runId
                ) {
                    val generation = rearmRunStreamAfterRetry(entry, runId)
                    // Replace (never duplicate) the pump: the old generation
                    // may still be polling a window that belonged to the
                    // paused run. The resume read settles first so the new
                    // pump starts after the native durableWatermark and
                    // cannot replay the previous incarnation's old terminal.
                    eventPumps.remove(runId)?.close()
                    refreshRunSnapshot(
                        entry,
                        runId,
                        // The resume refresh is a state/CAS read only.
                        // Terminal reconciliation stays with the new pump's
                        // durable/live close boundary, so a momentarily-stale
                        // terminal page cannot immediately re-close the
                        // just-resumed tail.
                        streamGeneration = generation,
                    ) {
                        val ownerConversation = entry.holder.session.conversationId
                        val ownerEpoch = entry.holder.session.sessionEpoch
                        if (ownCurrentEntry(entry, ownerConversation, ownerEpoch) &&
                            entry.builder.selectedRunId == runId &&
                            currentRunStreamGeneration(ownerConversation, runId) == generation
                        ) {
                            val after = runDurableWatermarks[
                                streamKey(ownerConversation, runId)
                            ] ?: 0L
                            openRunEventStream(
                                entry.holder.session,
                                entry,
                                runId,
                                generation,
                                afterSequence = after,
                            )
                        }
                    }
                }
            },
        )
        return true
    }

    /**
     * Advances the trusted local stream generation for one accepted retry of
     * the SAME run id and re-binds the presentation tail. Durable messages,
     * run rows, CAS revisions and checkpoint/queue state are untouched.
     */
    private fun rearmRunStreamAfterRetry(
        entry: ConversationFlowHolderEntry,
        runID: String,
    ): Long {
        val conversationId = entry.holder.session.conversationId
        val key = streamKey(conversationId, runID)
        val generation = (runStreamGenerations[key] ?: 0L) + 1L
        runStreamGenerations[key] = generation
        liveSnapshotRefreshes.remove(runID)
        entry.builder.rearmLiveTailForRetry(runID)
        entry.holder.applyHostSnapshot(entry.builder.build())
        return generation
    }

    override fun promotePendingInput(
        session: ConversationSessionToken,
        inputId: String,
        expectedRunId: String,
    ): Boolean = steerPromote(session, inputId, expectedRunId)

    override fun editPendingInput(
        session: ConversationSessionToken,
        inputId: String,
        content: String,
    ): Boolean {
        if (!admitted()) return false
        val entry = holders[session.conversationId] ?: return false
        dispatchPendingInputMutation(
            entry = entry,
            session = session,
            inputId = inputId,
            command = "run.input.edit",
            correlationPrefix = "red",
            payloadFor = { inputVersion ->
                JsonObject(
                    mapOf(
                        "inputID" to JsonPrimitive(inputId),
                        "content" to JsonPrimitive(content),
                        "expectedInputVersion" to JsonPrimitive(inputVersion),
                    ),
                )
            },
        )
        return true
    }

    override fun removePendingInput(
        session: ConversationSessionToken,
        inputId: String,
    ): Boolean {
        if (!admitted()) return false
        val entry = holders[session.conversationId] ?: return false
        dispatchPendingInputMutation(
            entry = entry,
            session = session,
            inputId = inputId,
            command = "run.input.remove",
            correlationPrefix = "rrem",
            payloadFor = { inputVersion ->
                JsonObject(
                    mapOf(
                        "inputID" to JsonPrimitive(inputId),
                        "expectedInputVersion" to JsonPrimitive(inputVersion),
                    ),
                )
            },
        )
        return true
    }

    /**
     * `run.input.edit`/`run.input.remove`: the envelope CAS is the CURRENT
     * conversation row revision AND the payload proves
     * `pendingInput.<uuid>/<inputVersion>`. Both are re-read at action time
     * (row digest + durable pending-row version), never guessed.
     */
    private fun dispatchPendingInputMutation(
        entry: ConversationFlowHolderEntry,
        session: ConversationSessionToken,
        inputId: String,
        command: String,
        correlationPrefix: String,
        payloadFor: (inputVersion: String) -> JsonObject,
    ) {
        withFreshConversationRevision(entry) { conversationRevision ->
            if (conversationRevision == null) {
                surfaceError(entry, "revision_unavailable")
                return@withFreshConversationRevision
            }
            entry.builder.selectedRunId?.let { runID ->
                refreshRunSnapshot(entry, runID) { applied ->
                    val inputVersion = entry.builder.inputVersion(inputId)
                    if (!applied || inputVersion == null) {
                        surfaceError(entry, "input_version_unavailable")
                        return@refreshRunSnapshot
                    }
                    val runIDForScope = entry.builder.selectedRunId ?: return@refreshRunSnapshot
                    host.trackOperation(
                        HostCommandRequest(
                            command = command,
                            scope = HostScope.TaskExecution(session.conversationId, runIDForScope),
                            stateful = true,
                            correlationID = client().correlationID(correlationPrefix),
                            revision = conversationRevision,
                            payload = payloadFor(inputVersion),
                        ),
                    ) { outcome ->
                        when (outcome) {
                            is HostOperationOutcome.Completed ->
                                refreshRunSnapshot(entry, runIDForScope)
                            is HostOperationOutcome.Rejected -> surfaceError(entry, outcome.code)
                            is HostOperationOutcome.Failed -> surfaceError(entry, outcome.code)
                            else -> Unit
                        }
                    }
                }
            } ?: surfaceError(entry, "run_unavailable")
        }
    }

    override fun reorderPendingInputs(
        session: ConversationSessionToken,
        orderedInputIds: List<String>,
    ): Boolean {
        if (!admitted()) return false
        val entry = holders[session.conversationId] ?: return false
        val runID = entry.builder.selectedRunId ?: return false
        refreshRunSnapshot(entry, runID) { applied ->
            val queueRevision = entry.builder.queueRevision
            if (!applied || queueRevision == null) {
                surfaceError(entry, "queue_version_unavailable")
                return@refreshRunSnapshot
            }
            host.trackOperation(
                HostCommandRequest(
                    command = "run.input.reorder",
                    scope = HostScope.TaskExecution(session.conversationId, runID),
                    stateful = true,
                    correlationID = client().correlationID("rreo"),
                    revision = HostRevision(queueRevision.resourceID, queueRevision.version),
                    payload = JsonObject(
                        mapOf(
                            "orderedIDs" to JsonArray(orderedInputIds.map { JsonPrimitive(it) }),
                            "expectedQueueVersion" to JsonPrimitive(queueRevision.version),
                        ),
                    ),
                ),
            ) { outcome ->
                when (outcome) {
                    is HostOperationOutcome.Completed -> refreshRunSnapshot(entry, runID)
                    is HostOperationOutcome.Rejected -> surfaceError(entry, outcome.code)
                    is HostOperationOutcome.Failed -> surfaceError(entry, outcome.code)
                    else -> Unit
                }
            }
        }
        return true
    }

    private fun steerPromote(
        session: ConversationSessionToken,
        inputId: String,
        expectedRunId: String,
    ): Boolean {
        if (!admitted()) return false
        val entry = holders[session.conversationId] ?: return false
        dispatchRunStateControl(
            entry = entry,
            runID = expectedRunId,
            command = "run.steer",
            correlationPrefix = "rsteer",
            payloadFor = { state -> ConversationWire.steerPayload(inputId, state) },
            onCompleted = { completed ->
                if (completed.detail["promoted"] == "false") {
                    surfaceError(entry, "steer_target_ended_queued")
                }
                refreshRunSnapshot(entry, expectedRunId)
            },
        )
        return true
    }

    private fun currentRunId(session: ConversationSessionToken): String? =
        holders[session.conversationId]?.builder?.selectedRunId

    /**
     * `run.approval.resolve`: revision `approval.<callID>/<requestedAt>` and
     * payload `{callID,decision,reason?,expectedApprovalVersion}`. The grant
     * scope is NEVER chosen by the payload — native re-derives it from the
     * live call-bound request (a human tap only picks allow/deny).
     */
    override fun resolveApproval(request: ApprovalDecisionRequest): Boolean {
        if (!admitted()) return false
        val entry = holders[request.conversationId] ?: return false
        val decision = when (request.decision) {
            is ApprovalUserDecisionUi.Allow -> "allow"
            ApprovalUserDecisionUi.Deny -> "deny"
        }
        fun dispatch(approvalVersion: String) {
            host.trackOperation(
                HostCommandRequest(
                    command = "run.approval.resolve",
                    scope = HostScope.TaskExecution(request.conversationId, request.runId),
                    stateful = true,
                    correlationID = client().correlationID("rappr"),
                    revision = HostRevision(
                        ConversationWire.approvalResourceID(request.approvalId),
                        approvalVersion,
                    ),
                    payload = JsonObject(
                        buildMap {
                            put("callID", JsonPrimitive(request.approvalId))
                            put("decision", JsonPrimitive(decision))
                            put("expectedApprovalVersion", JsonPrimitive(approvalVersion))
                            if (decision == "deny") {
                                put(
                                    "reason",
                                    JsonPrimitive(request.reason ?: "User denied the action"),
                                )
                            }
                        },
                    ),
                ),
            ) { outcome ->
                when (outcome) {
                    is HostOperationOutcome.Completed -> Unit
                    is HostOperationOutcome.Rejected -> surfaceError(entry, outcome.code)
                    is HostOperationOutcome.Failed -> surfaceError(entry, outcome.code)
                    else -> Unit
                }
            }
        }
        val known = entry.builder.approvalVersion(request.approvalId)
        if (known != null) {
            dispatch(known)
            return true
        }
        // The requestedAt version exists only on the authoritative snapshot.
        refreshRunSnapshot(entry, request.runId) { applied ->
            val version = entry.builder.approvalVersion(request.approvalId)
            if (applied && version != null) {
                dispatch(version)
            } else {
                surfaceError(entry, "approval_version_unavailable")
            }
        }
        return true
    }

    override fun acceptPlan(
        session: ConversationSessionToken,
        planId: String,
        revision: Revision,
        execution: PlanRecommendationUi,
    ): Boolean {
        // The frozen v3 matrix has no plan-accept command; plan-mode runs
        // launch with mode=plan and the recommendation is part of the run
        // policy. Honest unavailability — never a fabricated command.
        return false
    }

    /**
     * Goal creation is a REAL goal-mode launch on the conversation
     * (`run.start` with `mode:"goal"`): the objective and the evidence-backed
     * criteria travel in the goal text, and the native goal writer/verifier
     * path owns the durable goal record. Never a silent no-op.
     */
    override fun createGoal(request: GoalCreateRequest): Boolean {
        if (!admitted()) return false
        val entry = holders[request.conversationId] ?: return false
        val goalText = buildString {
            append(request.objective.trim())
            fun section(title: String, items: List<String>) {
                val values = items.map { it.trim() }.filter { it.isNotEmpty() }
                if (values.isEmpty()) return
                append("\n\n").append(title).append("\n")
                values.forEach { append("- ").append(it).append("\n") }
            }
            section("Criteria", request.criteria)
            section("Blocking conditions", request.blockingConditions)
            section("Stopping conditions", request.stoppingConditions)
        }
        if (goalText.isBlank()) return false
        val model = currentModels().models.firstOrNull { it.isUsable } ?: return false
        val session = ConversationSessionToken(
            request.conversationId, entry.holder.session.sessionEpoch)
        val correlation = LaunchCorrelation(
            conversationId = request.conversationId,
            sessionEpoch = session.sessionEpoch,
            launchGeneration = goalLaunchGenerations.incrementAndGet(),
            temporaryIncarnationId = null,
        )
        launchCorrelations[correlation.launchGeneration.toString()] = correlation
        val launch = RunLaunchRequest(
            conversationId = request.conversationId,
            sessionEpoch = session.sessionEpoch,
            goalText = goalText,
            attachments = emptyList(),
            executionMode = AgentExecutionModeUi.GOAL,
            modelId = model.modelId,
            workspaceId = null,
            temporaryIncarnationId = null,
            launchGeneration = correlation.launchGeneration,
            providerId = model.providerId,
        )
        // Same action-time fresh row read as the ordinary send path: the goal
        // launch reuses the SAME `run.start` conversationProof CAS, so a cached
        // conversation revision would be equally stale after any prior commit.
        launchWithFreshConversationRevision(launch, entry, correlation)
        return true
    }

    override fun confirmGoalCompletion(
        session: ConversationSessionToken,
        goalId: String,
    ): Boolean {
        // No dedicated wire command in the frozen matrix; honest false.
        return false
    }

    // -------------------------------------------------------------- paging

    override fun loadEarlierMessages(session: ConversationSessionToken): Boolean {
        val entry = holders[session.conversationId] ?: return false
        val cursor = entry.builder.earlierCursor ?: return false
        loadMessagePage(session, entry, cursor)
        return true
    }

    override fun loadEarlierEvents(session: ConversationSessionToken, cursor: EventCursor): Boolean {
        // The durable event pump replays the run's append-only thread from
        // sequence 0 and pages forward automatically; there is no separate
        // "older events" command in the frozen matrix. Honest: an event page
        // is already being delivered by the live pump, so only claim the
        // action when a pump really owns this run.
        val entry = holders[session.conversationId] ?: return false
        val runID = currentRunId(session) ?: return false
        if (eventPumps.containsKey(runID)) return true
        // No live pump (e.g. a terminal run): open the durable stream so the
        // stored history is actually re-read instead of pretending.
        if (!ConversationWire.isActiveState(entry.builder.runStateName(runID) ?: "")) {
            openRunEventStream(session, entry, runID)
            return true
        }
        return false
    }

    // ----------------------------------------------------------- attachments

    override fun requestAttachmentImport(session: ConversationSessionToken): Boolean {
        if (!host.readiness.value.attachmentStagingAdmitted) return false
        host.attachments.requestPicker(session)
        return true
    }

    override fun retryAttachmentImport(
        session: ConversationSessionToken,
        attachmentId: String,
    ): Boolean = host.attachments.retry(session, attachmentId)

    override fun cancelAttachmentImport(
        session: ConversationSessionToken,
        attachmentId: String,
    ): Boolean = host.attachments.cancel(session, attachmentId)

    override fun discardStagedAttachment(
        session: ConversationSessionToken,
        attachmentId: String,
    ) {
        host.attachments.discard(session, attachmentId)
    }

    override fun openMessageAttachment(
        session: ConversationSessionToken,
        request: AttachmentOpenRequest,
    ): Boolean {
        if (!conversationAdmitted()) return false
        host.attachments.open(request)
        return true
    }

    internal fun onAttachmentStaged(
        session: ConversationSessionToken,
        staged: StagedAttachmentUi,
    ) {
        val entry = holders[session.conversationId] ?: return
        entry.builder.stageAttachment(staged)
        entry.holder.applyAttachmentOutcome(staged.id, AttachmentImportUi.Ready)
        entry.holder.applyHostSnapshot(entry.builder.build())
    }

    internal fun onAttachmentProgress(
        session: ConversationSessionToken,
        attachmentId: String,
        import: AttachmentImportUi,
    ) {
        holders[session.conversationId]?.holder?.applyAttachmentOutcome(attachmentId, import)
    }

    // --------------------------------------------------------- plan / goal UI

    /**
     * Launchpad-level default-model persistence: the New Task surface has no
     * thread holder yet, but the user's picker choice must still become the
     * durable default (same full-document preferences CAS as [selectModel]).
     */
    fun selectDefaultModel(modelId: String): Boolean {
        if (!host.readiness.value.providerConfigurationAdmitted) return false
        persistDefaultAgentModel(modelId, onSaved = { publishModelProjection() }, onError = { })
        return true
    }

    private fun persistDefaultAgentModel(
        modelId: String,
        onSaved: () -> Unit,
        onError: (String) -> Unit,
    ) {
        host.trackOperation(
            HostCommandRequest(
                command = "config.preferences.get",
                scope = HostScope.ApplicationConfiguration("preferences"),
                stateful = false,
                correlationID = client().correlationID("prefsel"),
            ),
        ) { outcome ->
            if (outcome !is HostOperationOutcome.Completed) {
                onError("preferences_unavailable")
                return@trackOperation
            }
            val root = outcome.value as? JsonObject
            val revision = (root?.get("revision") as? JsonObject)?.let {
                val version = (it["version"] as? JsonPrimitive)?.contentOrNull
                val resourceID = (it["resourceID"] as? JsonPrimitive)?.contentOrNull
                if (resourceID != null && version != null) HostRevision(resourceID, version) else null
            }
            val preferences = root?.get("preferences") as? JsonObject
            if (revision == null || preferences == null ||
                revision.resourceID != "preferences"
            ) {
                onError("preferences_unavailable")
                return@trackOperation
            }
            val payload = JsonObject(
                LinkedHashMap(preferences).apply {
                    put("defaultAgentModelID", JsonPrimitive(modelId))
                    // The writer requires the payload to carry the SAME
                    // revision it read (full-snapshot CAS); it then bumps.
                    (revision.version.toLongOrNull())?.let {
                        put("syncRevision", JsonPrimitive(it))
                    }
                },
            )
            host.trackOperation(
                HostCommandRequest(
                    command = "config.preferences.save",
                    scope = HostScope.ApplicationConfiguration("preferences"),
                    stateful = true,
                    correlationID = client().correlationID("prefsave"),
                    revision = revision,
                    payload = payload,
                ),
            ) { saved ->
                when (saved) {
                    is HostOperationOutcome.Completed -> {
                        defaultAgentModelId = modelId
                        onSaved()
                    }
                    is HostOperationOutcome.Rejected -> onError(saved.code)
                    is HostOperationOutcome.Failed -> onError(saved.code)
                    else -> Unit
                }
            }
        }
    }

    /**
     * Composer model selection persists the ORIGINAL `ModelSelectionPreferences`
     * document under its real CAS: `config.preferences.get` supplies the full
     * document + `preferences/<syncRevision>`, the App changes ONLY
     * `defaultAgentModelID`, and the save echoes the document with the exact
     * revision. The native writer owns the syncRevision increment and the
     * stale-CAS refusal. A partial `{selectedModelID}` stub would be refused
     * (and previously silently did nothing).
     */
    override fun selectModel(session: ConversationSessionToken, modelId: String): Boolean {
        if (!host.readiness.value.providerConfigurationAdmitted) return false
        val entry = holders[session.conversationId]
        persistDefaultAgentModel(
            modelId = modelId,
            onSaved = {
                publishModelProjection()
                entry?.builder?.clearActionError()
                entry?.holder?.applyHostSnapshot(entry.builder.build())
            },
            onError = { entry?.let { surfaceError(it, "model_persistence_failed") } },
        )
        return true
    }

    override fun setRunningInputMode(
        session: ConversationSessionToken,
        mode: RunningInputModeUi,
    ): Boolean {
        if (!host.readiness.value.settingsDomainsAdmitted.contains("settings.defaults")) {
            return false
        }
        host.settings.saveDefaults(
            runningInputMode = mode.name.lowercase(),
        ) { }
        return true
    }

    override fun saveDraft(
        session: ConversationSessionToken,
        text: String,
        attachmentIds: List<String>,
        caretIndex: Int?,
        selectionLength: Int?,
    ) {
        // Draft/caret/undo are holder-owned RAM state; the host keeps no
        // second business persistence for composer drafts in G02.
    }

    override fun clearDraftAfterSend(
        session: ConversationSessionToken,
        sentText: String,
        sentAttachmentIds: List<String>,
    ) {
        // Holder-invoked only from a matching applyLaunchPrepared echo.
    }

    override fun requestManualCompaction(session: ConversationSessionToken): Boolean {
        // No compaction command exists in the frozen matrix; honest false.
        return false
    }

    // ------------------------------------------------------------ thread menu

    override fun exportStructuredConversation(session: ConversationSessionToken): Boolean {
        val entry = holders[session.conversationId] ?: return false
        host.shareText(ConversationWire.exportMarkdown(entry.builder), "text/markdown")
        entry.holder.applyExportSettled(null)
        return true
    }

    override fun shareConversationText(
        session: ConversationSessionToken,
        asMarkdown: Boolean,
    ): Boolean {
        val entry = holders[session.conversationId] ?: return false
        val text = if (asMarkdown) {
            ConversationWire.exportMarkdown(entry.builder)
        } else {
            ConversationWire.exportPlainText(entry.builder)
        }
        host.shareText(text, "text/plain")
        return true
    }

    override fun refreshMediaJobs(session: ConversationSessionToken): Boolean {
        // Media jobs refresh is not part of the G02 wire surface; honest false.
        return false
    }

    override fun openTaskPermissions(session: ConversationSessionToken): Boolean {
        permissionsRequest.value = session.conversationId
        return true
    }

    override fun openWorkspaceFile(
        session: ConversationSessionToken,
        relativePath: String,
    ): Boolean {
        // Workspace file surfacing arrives with the workspace goal; no
        // fabricated authority over host files in G02.
        return false
    }

    override fun showInspector(content: InspectorRouteUi, conversationId: String) {
        inspectorRequest.value = content to conversationId
    }

    override fun loadChildRunDetail(
        session: ConversationSessionToken,
        childRunId: String,
    ): Boolean {
        if (!admitted()) return false
        val entry = holders[session.conversationId] ?: return false
        host.trackOperation(
            HostCommandRequest(
                command = "child.entries",
                scope = HostScope.TaskExecution(session.conversationId, childRunId),
                stateful = false,
                correlationID = client().correlationID("cchild"),
                payload = JsonObject(
                    mapOf(
                        "childRunID" to JsonPrimitive(childRunId),
                        "afterSequence" to JsonPrimitive(0),
                        "limit" to JsonPrimitive(200),
                    ),
                ),
            ),
        ) { outcome ->
            if (outcome is HostOperationOutcome.Completed && outcome.value != null) {
                val detail = ConversationWire.decodeChildDetail(childRunId, outcome.value)
                entry.builder.childDetails[childRunId] = detail
                entry.holder.applyHostSnapshot(entry.builder.build())
            }
        }
        return true
    }

    // -------------------------------------------------------------- temporary

    override fun keepTemporaryChat(ref: TemporarySessionRef): Boolean {
        if (!host.readiness.value.temporaryDomainAdmitted) return false
        val revision = HostRevision("session.${ref.conversationId}", ref.incarnationId)
        host.trackOperation(
            HostCommandRequest(
                command = "temp.keep",
                scope = HostScope.ConversationLifecycle(ref.conversationId),
                stateful = true,
                correlationID = client().correlationID("tkeep"),
                revision = revision,
            ),
        ) { outcome ->
            val entry = holders[ref.conversationId]
            val holder = entry?.holder
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val conversationID = (outcome.value as? JsonObject)
                        ?.let { (it["conversationID"] as? JsonPrimitive)?.contentOrNull }
                    activeTemporary.remove(ref.conversationId)
                    holder?.applyTemporaryKeepOutcome(ref, TemporaryKeepOutcomeUi.Promoted)
                    conversationID?.let { newID ->
                        // Atomic Keep remaps only the returned real identity.
                        navigationRequest.value = SidebarSelection.Conversation(newID)
                    }
                    refreshHistorySoon()
                }
                is HostOperationOutcome.Rejected ->
                    holder?.applyTemporaryKeepOutcome(
                        ref, TemporaryKeepOutcomeUi.Failed(outcome.code))
                is HostOperationOutcome.Failed ->
                    holder?.applyTemporaryKeepOutcome(
                        ref, TemporaryKeepOutcomeUi.Failed(outcome.code))
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    override fun endTemporaryChat(ref: TemporarySessionRef): Boolean {
        if (!host.readiness.value.temporaryDomainAdmitted) return false
        return tempFence.beginEnd(ref, notifyOutcome = true)
    }

    /** Start a real temporary session (New Task → temporary chat). */
    fun startTemporarySession(
        draft: String,
        preferredModelID: String?,
        onStarted: (TemporarySessionRef) -> Unit,
        onFailure: (String) -> Unit,
    ): Boolean {
        if (!host.readiness.value.temporaryDomainAdmitted) return false
        val payload = JsonObject(
            buildMap {
                put("draft", JsonPrimitive(draft))
                preferredModelID?.let { put("preferredModelID", JsonPrimitive(it)) }
            },
        )
        host.trackOperation(
            HostCommandRequest(
                command = "temp.start",
                scope = HostScope.LaunchNewIdentity,
                stateful = true,
                correlationID = client().correlationID("tstart"),
                createIntent = true,
                payload = payload,
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    val conversationID = root?.let {
                        (it["conversationID"] as? JsonPrimitive)?.contentOrNull
                    }
                    val incarnation = root?.let {
                        (it["incarnation"] as? JsonPrimitive)?.contentOrNull
                    }
                    // G02: bind the ACTUAL trusted native root epoch from the
                    // authoritative temp.start value (MAIN_TEMP_ACK_NATIVE_
                    // EPOCH_DECISION). Absent/invalid -> fail closed: the
                    // session is not fenced, never bound to 0 or the UI
                    // counter.
                    val nativeRootEpoch = root?.let {
                        (it["rootEpoch"] as? JsonPrimitive)?.contentOrNull
                    }?.toLongOrNull() ?: -1L
                    if (conversationID != null && incarnation != null &&
                        nativeRootEpoch > 0
                    ) {
                        // Bind the REAL App-side session epoch for this
                        // temporary surface; the native fence ack must echo
                        // this exact epoch (never a fabricated zero).
                        val tempHolder = holderFor(
                            conversationId = conversationID,
                            isTemporary = true,
                            incarnationId = incarnation,
                            initialDraft = if (draft.isNotBlank()) {
                                ComposerDraftSeedUi(
                                    text = draft,
                                    attachments = emptyList(),
                                    caretIndex = null,
                                    selectionLength = null,
                                )
                            } else {
                                null
                            },
                        )
                        // The holder's own session epoch is the exact App-side
                        // identity used by Keep/End callbacks; never a
                        // different registry counter or a fabricated zero.
                        val epoch = tempHolder.session.sessionEpoch
                        val ref = TemporarySessionRef(
                            conversationID, epoch, incarnation,
                            nativeRootEpoch = nativeRootEpoch,
                        )
                        activeTemporary[conversationID] = ref
                        onStarted(ref)
                    } else {
                        onFailure("temp_malformed")
                    }
                }
                is HostOperationOutcome.Rejected -> onFailure(outcome.code)
                is HostOperationOutcome.Failed -> onFailure(outcome.code)
                HostOperationOutcome.Cancelled -> onFailure("cancelled")
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    // ---------------------------------------------------------------- history

    override fun reloadHistory() = refreshHistory()

    internal fun refreshHistory() {
        if (!conversationAdmitted()) return
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.list",
                scope = HostScope.ApplicationConfiguration("conversations"),
                stateful = false,
                correlationID = client().correlationID("hlist"),
                payload = JsonObject(mapOf("includeArchived" to JsonPrimitive(true), "limit" to JsonPrimitive(50))),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val page = outcome.value?.let { ConversationWire.decodeConversationList(it) }
                    if (page != null) {
                        historyHolder.applyHostState(
                            HistoryListUiState(
                                isLoading = false,
                                items = page.active,
                                archivedItems = page.archived,
                                contentSnippets = emptyMap(),
                                searchEpoch = historyHolder.state.value?.searchEpoch ?: 0,
                                isSearching = false,
                                needsProvider = !host.readiness.value.providerConfigurationAdmitted,
                                runningConversationIds = runningConversationIds(),
                                bulkProgress = null,
                                networkActionsAvailable = conversationAdmitted(),
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Rejected ->
                    historyHolder.applyHostState(
                        HistoryListUiState(
                            isLoading = false,
                            items = emptyList(),
                            archivedItems = emptyList(),
                            contentSnippets = emptyMap(),
                            searchEpoch = 0,
                            isSearching = false,
                            needsProvider = !host.readiness.value.providerConfigurationAdmitted,
                            runningConversationIds = emptySet(),
                            bulkProgress = null,
                            networkActionsAvailable = conversationAdmitted(),
                        ),
                    )
                else -> Unit
            }
        }
    }

    private fun runningConversationIds(): Set<String> =
        eventPumps.keys.toSet().let { runIDs ->
            holders.values.filter { entry ->
                entry.builder.runIds().any { it in runIDs }
            }.map { it.holder.session.conversationId }.toSet()
        }

    override fun createConversation(): Boolean {
        var started = false
        createConversationForLaunch(
            title = null,
            onCreated = { id ->
                navigationRequest.value = SidebarSelection.Conversation(id)
            },
            onFailure = { },
        ).also { started = it }
        return started
    }

    /**
     * Resolves the CURRENT conversation-row revision for a history mutation.
     * A row the user never opened has no holder, so the previous code refused
     * it outright; the real revision is instead read with one
     * `conversation.get` at action time (the frozen CAS source). An unreadable
     * row surfaces a typed failure — never a fabricated version and never a
     * silent stale success.
     */
    private fun resolveConversationRevision(
        conversationId: String,
        onReady: (HostRevision?) -> Unit,
    ) {
        val known = holders[conversationId]?.builder?.conversationRevision
        if (known != null) {
            onReady(HostRevision(known.resourceID, known.version))
            return
        }
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(conversationId),
                stateful = false,
                correlationID = client().correlationID("cget-hist"),
            ),
        ) { outcome ->
            if (outcome is HostOperationOutcome.Completed) {
                val reply = outcome.value?.let { ConversationWire.decodeSessionReply(it) }
                val revision = reply?.revision
                if (reply != null && revision != null) {
                    // Keep the real revision so a following action can reuse it.
                    holders[conversationId]?.builder?.conversationRevision = revision
                    onReady(HostRevision(revision.resourceID, revision.version))
                    return@trackOperation
                }
            }
            onReady(null)
        }
    }

    /**
     * One frozen conversation mutation (archive/restore/delete) with the real
     * CAS revision and a visible typed outcome. Used by the single-row actions
     * AND by bulk so the aggregate receipt reflects real settlements.
     */
    private fun mutateConversation(
        conversationId: String,
        command: String,
        payload: JsonObject?,
        correlationPrefix: String,
        onSettled: (Boolean, String?) -> Unit = { _, _ -> },
    ) {
        if (!conversationAdmitted()) {
            onSettled(false, "runtime_unavailable")
            return
        }
        resolveConversationRevision(conversationId) { revision ->
            if (revision == null) {
                historyHolder.applyActionError("revision_unavailable")
                onSettled(false, "revision_unavailable")
                return@resolveConversationRevision
            }
            host.trackOperation(
                HostCommandRequest(
                    command = command,
                    scope = HostScope.ConversationLifecycle(conversationId),
                    stateful = true,
                    correlationID = client().correlationID(correlationPrefix),
                    revision = revision,
                    payload = payload,
                ),
            ) { outcome ->
                when (outcome) {
                    is HostOperationOutcome.Completed -> {
                        if (command == "conversation.delete") {
                            releaseHolder(conversationId)
                        }
                        refreshHistory()
                        onSettled(true, null)
                    }
                    is HostOperationOutcome.Rejected -> {
                        // A stale revision means the row advanced after the
                        // read: forget the cached identity so a retry re-reads.
                        holders[conversationId]?.builder?.conversationRevision = null
                        historyHolder.applyActionError(outcome.code)
                        refreshHistory()
                        onSettled(false, outcome.code)
                    }
                    is HostOperationOutcome.Failed -> {
                        historyHolder.applyActionError(outcome.code)
                        onSettled(false, outcome.code)
                    }
                    HostOperationOutcome.Cancelled ->
                        onSettled(false, "cancelled")
                    HostOperationOutcome.Superseded -> Unit
                }
            }
        }
    }

    override fun archiveConversation(conversationId: String): Boolean {
        if (!conversationAdmitted()) return false
        mutateConversation(
            conversationId,
            command = "conversation.archive",
            payload = JsonObject(mapOf("archived" to JsonPrimitive(true))),
            correlationPrefix = "carch",
        )
        return true
    }

    override fun restoreConversation(conversationId: String): Boolean {
        if (!conversationAdmitted()) return false
        mutateConversation(
            conversationId,
            command = "conversation.archive",
            payload = JsonObject(mapOf("archived" to JsonPrimitive(false))),
            correlationPrefix = "crest",
        )
        return true
    }

    override fun deleteConversation(conversationId: String): Boolean {
        if (!conversationAdmitted()) return false
        mutateConversation(
            conversationId,
            command = "conversation.delete",
            payload = null,
            correlationPrefix = "cdel",
        )
        return true
    }

    override fun requestContentSearch(query: String, epoch: Long): Boolean {
        if (!conversationAdmitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.search",
                scope = HostScope.ApplicationConfiguration("conversations"),
                stateful = false,
                correlationID = client().correlationID("hsearch"),
                payload = JsonObject(
                    mapOf(
                        "query" to JsonPrimitive(query),
                        "limit" to JsonPrimitive(20),
                    ),
                ),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val results = outcome.value?.let { ConversationWire.decodeSearch(it) }
                        ?: emptyList()
                    historyHolder.applyHostState(
                        HistoryListUiState(
                            isLoading = false,
                            items = results,
                            archivedItems = emptyList(),
                            contentSnippets = emptyMap(),
                            searchEpoch = epoch,
                            isSearching = false,
                            needsProvider = false,
                            runningConversationIds = emptySet(),
                            bulkProgress = null,
                            networkActionsAvailable = conversationAdmitted(),
                        ),
                    )
                }
                else -> Unit
            }
        }
        return true
    }

    /** Active bulk settlement batch (token → outstanding item count). */
    private class BulkRun(
        val operation: TaskBulkOperationUi,
        val results: java.util.concurrent.atomic.AtomicInteger,
        val cancelled: java.util.concurrent.atomic.AtomicBoolean = java.util.concurrent.atomic.AtomicBoolean(false),
    )

    private val bulkRuns = ConcurrentHashMap<Long, BulkRun>()

    override fun requestBulk(
        operation: TaskBulkOperationUi,
        conversationIds: List<String>,
        token: Long,
    ): Boolean {
        if (!conversationAdmitted()) return false
        if (conversationIds.isEmpty()) return false
        // Per-item canonical operations; the aggregate receipt is assembled
        // from each REAL typed outcome (never a fabricated success count).
        val titles = historyHolder.state.value?.let { state ->
            (state.items + state.archivedItems).associate { it.id to it.title }
        } ?: emptyMap()
        val settled = java.util.concurrent.ConcurrentHashMap<String, BulkItemOutcomeUi>()
        val run = BulkRun(operation, java.util.concurrent.atomic.AtomicInteger(conversationIds.size))
        bulkRuns[token] = run
        val command = when (operation) {
            TaskBulkOperationUi.ARCHIVE -> "conversation.archive"
            TaskBulkOperationUi.RESTORE -> "conversation.archive"
            TaskBulkOperationUi.DELETE -> "conversation.delete"
        }
        val payload = when (operation) {
            TaskBulkOperationUi.ARCHIVE ->
                JsonObject(mapOf("archived" to JsonPrimitive(true)))
            TaskBulkOperationUi.RESTORE ->
                JsonObject(mapOf("archived" to JsonPrimitive(false)))
            TaskBulkOperationUi.DELETE -> null
        }
        for (id in conversationIds) {
            if (run.cancelled.get()) {
                settled[id] = BulkItemOutcomeUi.Failed("cancelled")
                if (run.results.decrementAndGet() == 0) finishBulk(token, run, settled, titles)
                continue
            }
            mutateConversation(
                conversationId = id,
                command = command,
                payload = payload,
                correlationPrefix = "blk",
            ) { ok, code ->
                settled[id] = if (ok) {
                    when (operation) {
                        TaskBulkOperationUi.ARCHIVE -> BulkItemOutcomeUi.Archived
                        TaskBulkOperationUi.RESTORE -> BulkItemOutcomeUi.Restored
                        TaskBulkOperationUi.DELETE -> BulkItemOutcomeUi.Deleted
                    }
                } else {
                    BulkItemOutcomeUi.Failed(code ?: "failed")
                }
                if (run.results.decrementAndGet() == 0) {
                    finishBulk(token, run, settled, titles)
                }
            }
        }
        return true
    }

    private fun finishBulk(
        token: Long,
        run: BulkRun,
        settled: Map<String, BulkItemOutcomeUi>,
        titles: Map<String, String>,
    ) {
        bulkRuns.remove(token)
        val results = settled.map { (id, outcome) ->
            BulkItemResultUi(
                conversationId = id,
                title = titles[id] ?: id,
                outcome = outcome,
            )
        }
        historyHolder.applyBulkReceipt(
            BulkReceiptUi(
                operation = run.operation,
                results = results,
                wasCancelled = run.cancelled.get(),
            ),
        )
    }

    override fun cancelBulk(token: Long) {
        bulkRuns[token]?.cancelled?.set(true)
    }

    // ------------------------------------------------------- content actions

    override fun requestMarkdownParse(
        session: ConversationSessionToken,
        source: String,
        generation: Long,
    ): Boolean = markdownParser.schedule(source, generation) { echoSource, echoGeneration, blocks ->
        holders[session.conversationId]?.holder?.applyMarkdownParseResult(
            session, echoSource, echoGeneration, blocks,
        )
    }

    override fun openMessageLink(session: ConversationSessionToken, urlString: String): Boolean =
        host.openWebUrl(urlString)

    override fun openRichArtifactPreview(
        session: ConversationSessionToken,
        artifactId: String,
    ): Boolean = false

    override fun copyMessageText(
        session: ConversationSessionToken,
        text: String,
    ): Boolean = host.copyToClipboard(text)

    override fun speakMessageText(
        session: ConversationSessionToken,
        text: String,
    ): Boolean = false

    override fun stopSpeaking(session: ConversationSessionToken) {
        // No TTS backend in G02.
    }

    override fun saveMessageToNotes(
        session: ConversationSessionToken,
        text: String,
    ): Boolean = false
}

/** Holder + projection bookkeeping for one conversation surface. */
class ConversationFlowHolderEntry internal constructor(
    val holder: com.floe.android.feature.conversation.ConversationFlowHolder,
    val sessionEpoch: Long,
    val isTemporary: Boolean,
    val incarnationId: String?,
    val builder: ThreadProjectionBuilder,
)

/**
 * Per-run live-hint coalescing state: at most one authoritative
 * `run.snapshot` refresh in flight, dirty hints collapse into one bounded
 * follow-up, and the cadence never exceeds the existing poll interval.
 */
private class LiveSnapshotRefreshState(val generation: Long) {
    val dirty = AtomicBoolean(false)
    val inFlight = AtomicBoolean(false)
    val followUpScheduled = AtomicBoolean(false)

    @Volatile
    var lastStartedAtMillis: Long = 0L
}

/** Bounded FIFO key set for idempotent terminal reconciliations. */
private class BoundedKeySet(private val capacity: Int) {
    private val order = ArrayDeque<String>()
    private val keys = HashSet<String>()

    @Synchronized
    fun add(key: String): Boolean {
        if (!keys.add(key)) return false
        order.addLast(key)
        while (order.size > capacity) keys.remove(order.removeFirst())
        return true
    }

    @Synchronized
    fun contains(key: String): Boolean = key in keys

    @Synchronized
    fun clear() {
        order.clear()
        keys.clear()
    }
}

/** Terminal-reconciliation identity window (bounded, evicted FIFO). */
private const val TERMINAL_RECONCILE_CAPACITY = 256
