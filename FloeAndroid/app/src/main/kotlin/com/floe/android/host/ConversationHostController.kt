// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.host.linux.LinuxTypedDeletionRecord
import com.floe.android.host.linux.LocalRuntimeProofProjection
import com.floe.android.feature.conversation.ApprovalModeUi
import com.floe.android.feature.conversation.GoalDefinitionUi
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
import com.floe.android.feature.conversation.MessageRoleUi
import com.floe.android.feature.conversation.MessageUi
import com.floe.android.feature.conversation.ModelOptionUi
import com.floe.android.feature.conversation.PendingInputBodyStateUi
import com.floe.android.feature.conversation.PendingInputBodyUi
import com.floe.android.feature.conversation.PlanGoalDetailStateUi
import com.floe.android.feature.conversation.PlanRecommendationUi
import com.floe.android.contracts.Revision
import com.floe.android.feature.conversation.RunningInputModeUi
import com.floe.android.feature.conversation.RunningInputRequest
import com.floe.android.feature.conversation.RunLaunchRequest
import com.floe.android.feature.conversation.RunOutputCardUi
import com.floe.android.feature.conversation.StagedAttachmentUi
import com.floe.android.feature.conversation.TaskBulkOperationUi
import com.floe.android.feature.conversation.TemporaryEndTargetUi
import com.floe.android.feature.conversation.TemporaryKeepOutcomeUi
import com.floe.android.feature.conversation.TemporarySessionRef
import com.floe.android.feature.conversation.TerminalHandoffConflictUi
import com.floe.android.feature.conversation.TerminalHandoffConsentUi
import com.floe.android.feature.conversation.ThreadUiState
import com.floe.android.feature.conversation.TimelineRowUi
import com.floe.android.feature.providers.ProviderCredentialStateUi
import com.floe.android.FloeApplication
import com.floe.android.host.output.RunOutputHostService
import com.floe.android.host.output.RunOutputListResult
import com.floe.android.host.output.RunOutputOfficeSnapshotStager
import com.floe.android.host.output.RunOutputSaveOutcome
import com.floe.android.host.output.runOutputPdfOpenAgreement
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
 * The shared reader's aggregate content bound divided by the P0 per-chunk
 * clamp (4 MiB / 32 KiB); one oversized message can never loop past what the
 * reader can legally return.
 */
private const val MAXIMUM_CONTENT_CHUNKS = 128


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
    /**
     * The SCOPED same-id Keep promotion-adoption signal (Main's late-Keep
     * ownership decision). `trackOperation` runs on the root-wide command
     * client with no per-holder ownership filtering, so a committed Keep
     * terminal can arrive after the origin holder was released/rebound or
     * the user genuinely navigated away. Instead of a generic
     * navigationRequest (which the serial shell collector could route an
     * old kept id AND fence-end a NEW current temporary), the same-id
     * promotion publishes this exact-identity signal; the shell persists
     * the durable saved selection ONLY while the exact origin surface is
     * still the visible one, and drops it otherwise. A late committed
     * result still refreshes durable history (the genuine rows survive),
     * but never navigates, mutates a replacement holder or ends a new
     * session.
     */
    val keptPromotion = MutableStateFlow<KeptPromotion?>(null)

    /**
     * The EXACT UI-invalidation signal of a durable conversation
     * authoritatively deleted by a privacy history clear. Published ONLY
     * after the typed `notFound` under the SAME root and the EXACT holder
     * entry generation; the release itself (map + pumps) is host resource
     * ownership and happens regardless of UI. The shell — sole route
     * authority — consumes it to retire and genuinely navigate away ONLY
     * the STILL-VISIBLE, exactly-owned durable surface (same id + the exact
     * signaled holder instance + root re-check off-main + visible-origin
     * re-validation after the await). A stale signal never touches a
     * re-opened/rebound same-id holder, a temporary/Notes/survivor surface,
     * or any surface after a root change.
     */
    val privacyClearedConversation =
        MutableStateFlow<PrivacyClearedConversationSignal?>(null)

    // UI binding only: prevents deletions of off-screen cached holders from
    // overwriting the one visible-holder signal in this conflated flow.
    private val privacyVisibleHolder = java.util.concurrent.atomic.AtomicReference<
        com.floe.android.feature.conversation.ConversationFlowHolder?>(null)

    /** Narrow read-only join for the G05-R2 Office AI host lane (Main
     * host20): the EXACT durable conversation id the visible detail surface
     * currently reports through the same privacy-clear ownership binding
     * (null while Home/settings/a transient selection owns the surface, or
     * between a selection commit and the destination's re-report). The AI
     * lane consults it ONLY as the transient current-chat admission before a
     * NEW viewer launch — never as the durable owner fence — so it can
     * neither steal the foreground from another chat/settings/picker nor
     * invalidate an already-owned VIEWING document. */
    internal fun currentVisibleConversationId(): String? =
        privacyVisibleHolder.get()?.session?.conversationId

    internal fun bindPrivacyVisibleHolder(
        holder: com.floe.android.feature.conversation.ConversationFlowHolder?,
    ) {
        privacyVisibleHolder.set(holder)
    }

    /** Narrow read-only join for the owned-Office approval-notice surface
     * (G05-R3 office-approval107, 2026-10-28): the tool name of the FIRST
     * captured pending approval of THIS conversation's selected run —
     * exactly the card the timeline shows — answered ONLY while this
     * conversation is the one the visible detail surface currently reports,
     * so the viewer banner appears precisely when routing back to chat
     * presents this exact approval to review. Host-projected and non-secret
     * (the same string the card already displays). Grants nothing; the
     * banner only navigates, and review still happens on this ordinary card. */
    internal fun approvalNoticeFor(conversationId: String): String? {
        if (currentVisibleConversationId() != conversationId) return null
        val entry = holders[conversationId] ?: return null
        return entry.holder.snapshot.value?.pendingApprovals?.firstOrNull()?.toolName
    }

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

    /** Per-surface unregister hook for the live owned-Linux-engine-slot
     * conflict watch. Registering the watcher is the ONLY view-scoped
     * resource here (the same pane-scoped idiom the terminal pane uses);
     * detaching never touches a session. Keyed by conversation + session
     * epoch so a rebound surface registers its own watch and a stale one is
     * retired with its holder. */
    private val terminalConflictWatches = ConcurrentHashMap<String, () -> Unit>()

    /** At most ONE explicit terminal→model handoff per conversation: a second
     * consent is refused instead of racing the same captured session, and the
     * latch is released exactly when that handoff settles or refuses. */
    private val terminalHandoffInFlight = ConcurrentHashMap<String, Boolean>()

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
     * C09 QREV-02 — causal queue-settle observer, ONE watch per conversation
     * (key = conversationId; the latest terminal arm replaces the predecessor
     * identity-fenced). The watch reads the drain lane's durable `notice` +
     * `queueSettled` fact on the anchor's event stream (facts are the ONLY
     * interest) plus the typed degraded-window resync signal; observation
     * ends ONLY through the close-rule table (contract §6 P5): settle fact +
     * quiescence, an honest chain-closed fact, a typed resync (once per
     * watch), a typed pump failure's reconcile outcome, Superseded /
     * generation bump / navigation / holder retire / stop. NO timers, NO
     * idle-count cutoff (the queue observer opens with MAIN_ADDENDUM B's
     * notAttached opt-out), NO repeated snapshot polling. The late-B
     * discovery arm replaces time-based fallback with CAUSAL inheritance:
     * every settle/resync reconcile with pending rows arms the newest
     * unprocessed terminal run from its own authoritative session page.
     */
    private val queueSettleGate = Any()
    internal val queueSettleWatches = ConcurrentHashMap<String, QueueSettleWatch>()

    /**
     * Per-conversation in-flight coalescing of the authoritative reconcile,
     * scoped by the EXACT operation/entry/session identity (MAIN review H2):
     * the value is the owning [QueueSettleReconcileRun], and release is a
     * value-CAS — a stale completion can only ever release ITS OWN run,
     * never a replacement owner's marker (a conversation-key-only remove
     * let an old completion release a newer holder/watch's in-flight state
     * after retire/new-entry on the same id).
     */
    internal val queueSettleReconcilesInFlight =
        ConcurrentHashMap<String, QueueSettleReconcileRun>()

    /** The blocked trigger's carried CAUSE: one bounded re-run, released
     *  only for the CURRENT owner (identity-checked before consumption). */
    internal val queueSettleRerunRequested =
        ConcurrentHashMap<String, QueueSettleRerun>()

    /**
     * MAIN review H5 — the ACTUAL queue-consumed durable cursor per
     * conversation/run (key = streamKey), advanced only by frames this
     * surface's queue watch really received. A watch NEVER seeds from
     * `runDurableWatermarks`: refreshRunSnapshot writes the page watermark
     * BEFORE the terminal arm, and that watermark can already cover the
     * settle notice no observer consumed — seeding from it would skip the
     * only fact forever. Unconsumed ⇒ conservatively 0 (bounded by the
     * native window/`resyncRequired` semantics; replay of an already
     * consumed fact is the documented idempotent reconcile). The ORDINARY
     * pump cursor is unchanged. Cleaned at holder retire / stop.
     */
    internal val queueSettleConsumedCursors = ConcurrentHashMap<String, Long>()

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
    private val modelRefreshPending = java.util.concurrent.atomic.AtomicBoolean(false)
    private val goalLaunchGenerations = AtomicLong(0)

    /** One in-flight `plan.accept` per conversation (conversationId → true).
     * A second tap while a receipt owns the conversation is refused locally;
     * a lost ack is settled by the native durable (id,revision) proofs, never
     * by an automatic App-side replay. */
    private val planAcceptInFlight = ConcurrentHashMap<String, Boolean>()

    /**
     * Root/workspace surface owner: Home draft attachments (client-ram
     * ownership through the FIRST launch — no durable row exists before
     * C1), the draft-task approval choice seeded from the global default,
     * and the selected model's reasoning-effort producer. Process-scoped
     * like every controller here: rotation/background/recreation reuse it;
     * an actual navigation/New Task invalidates the owned draft.
     */
    val rootWorkspace: RootWorkspaceController by lazy { RootWorkspaceController(host) }

    private var readinessObservation: kotlinx.coroutines.Job? = null
    private var providersObservation: kotlinx.coroutines.Job? = null
    private var lastProviderListSignature: String? = null
    private var modelsReadOnce = false
    private var modelsReadAttempted = false
    @Volatile
    private var modelCacheGeneration = 0L

    /**
     * Identity of the LAST COMPLETE model sweep. The provider editor may seed
     * a destructive draft only from rows that still belong to this exact
     * sweep: a newer attempt (in flight or failed) supersedes it, and a
     * different native root or provider row set makes the cached rows the
     * wrong seed. The composer keeps its own last-real projection separately
     * (`modelProjection`), so a failed refresh never blanks a usable picker.
     */
    @Volatile
    private var modelCacheSweepGeneration = -1L
    @Volatile
    private var modelCacheRootEpoch: Long? = null
    @Volatile
    private var modelCacheProviderIds: Set<String> = emptySet()

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
        // The sidebar/history projection must also arrive when the domain
        // becomes admitted AFTER host start (the first host start can run
        // before the native readiness flips): one monotonic transition
        // triggers exactly one refresh, and no parallel readiness mechanism
        // is introduced.
        if (readinessObservation == null) {
            readinessObservation = host.scope.launch(host.ioDispatcher) {
                var previousConversationAdmitted =
                    host.readiness.value.conversationDomainAdmitted
                host.readiness.collect { readiness ->
                    if (readiness.conversationDomainAdmitted &&
                        !previousConversationAdmitted
                    ) {
                        refreshHistory()
                    }
                    previousConversationAdmitted = readiness.conversationDomainAdmitted
                }
            }
        }
        // Root-owned draft attachments survive view reconstruction because
        // the owner lives on the Application host; stop() drains what the
        // host itself tears down (root retirement).
        rootWorkspace.start()
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
        // C09: root teardown closes every queue-settle watch and drops the
        // coalescing bookkeeping (the watchers are pure observation — no
        // durable state to settle; late callbacks fence on identity anyway).
        queueSettleWatches.values.forEach { watch ->
            if (queueSettleWatches.remove(watch.conversationId, watch)) {
                watch.handleRef.get()?.close()
            }
        }
        queueSettleWatches.clear()
        queueSettleReconcilesInFlight.clear()
        queueSettleRerunRequested.clear()
        queueSettleConsumedCursors.clear()
        liveSnapshotRefreshes.clear()
        runStreamGenerations.clear()
        runDurableWatermarks.clear()
        terminalReconcileInFlight.clear()
        terminalReconciled.clear()
        providersObservation?.cancel()
        providersObservation = null
        readinessObservation?.cancel()
        readinessObservation = null
        // Host teardown: drain any draft-owned native staging before the
        // owner record goes away (root retirement, not navigation).
        rootWorkspace.stop()
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
        /**
         * Monotonic identity of the cached full-row set. A replacement can
         * leave the composer option list byte-identical (for example a
         * disabled/hidden row edit) while still changing the provider row
         * counts, so the provider surface joins on this explicit signal.
         */
        val cacheGeneration: Long = 0,
    )

    /**
     * Reads the ACTUAL model rows (`config.models.list`) and the persisted
     * default agent model (`config.preferences.get`), then republishes the
     * joined composer projection. A failed read keeps the last real
     * projection and never fabricates usability or a zero count.
     */
    internal fun refreshModels() {
        if (!host.readiness.value.providerConfigurationAdmitted) return
        if (!modelRefreshInFlight.compareAndSet(false, true)) {
            // Provider rows may arrive while the first empty sweep still
            // reads preferences. Preserve that real refresh request.
            modelRefreshPending.set(true)
            return
        }
        // Generation/Root fence: a newer refresh (or a root retirement)
        // invalidates every in-flight page of the previous chain; nothing it
        // delivers may publish a partial cache.
        val generation = modelsRefreshGeneration.incrementAndGet()
        val rootEpoch = host.nativeRootEpoch()
        startModelSweep(generation, rootEpoch)
    }

    /**
     * Provider-filtered INCREMENTAL model read (the completed provider-lane
     * pattern Main handed to this scope): instead of one global
     * `config.models.list` chain whose fixed accumulation could reject a
     * supported large profile (512 byte-dense rows per provider), the sweep
     * walks every KNOWN provider one at a time through the ACTUAL
     * provider-filtered continuation (closed payload `{providerID, cursor}`
     * + the composer cursor):
     *  * per provider: the PROVED supported bound (512 rows — the exact
     *    native profile limit; MORE means persisted data outside the
     *    supported contract → typed refusal, never truncation);
     *  * per provider chain: the progress-checked page bound DERIVED from
     *    the supported 512-row ceiling (byte-dense pages may carry a single
     *    legal row, so 8 was too strict and refused supported profiles);
     *  * overall accumulation: a fixed readable ceiling (8 providers' worth
     *    of supported profiles), explicit bound error on overflow — never
     *    unbounded growth, never a partial-cache publication;
     *  * disabled providers ARE read (unlike the role-candidate sweep): the
     *    full canonical rows remain the provider editor's seed data and the
     *    composer join independently filters usability.
     * A mid-chain refusal keeps the LAST REAL projection (and the existing
     * single-flight release) exactly as the previous global chain did.
     */
    private fun startModelSweep(generation: Long, rootEpoch: Long?) {
        val targets = modelSweepTargets()
        if (targets.isEmpty()) {
            // No provider rows yet: publish the honest empty join (the
            // previous global read delivered an empty page here as well).
            finishModelSweep(generation, rootEpoch, targets, ArrayList())
            return
        }
        accumulateModelSweep(generation, rootEpoch, targets, 0, ArrayList())
    }

    /** Every KNOWN provider id (conversation, image and video — disabled
     * rows included) covered by a full-row sweep, in stable order. */
    private fun modelSweepTargets(): List<String> {
        val providerIds = LinkedHashSet<String>()
        host.providers.destination.value.list.let { lists ->
            (lists.conversationProviders + lists.imageProviders + lists.videoProviders)
                .forEach { providerIds.add(it.providerId.uppercase()) }
        }
        return providerIds.sorted()
    }

    private fun accumulateModelSweep(
        generation: Long,
        rootEpoch: Long?,
        targets: List<String>,
        index: Int,
        accumulated: ArrayList<JsonElement>,
    ) {
        if (!modelsSweepCurrent(generation, rootEpoch)) {
            releaseModelRefresh(generation)
            return
        }
        if (index >= targets.size) {
            finishModelSweep(generation, rootEpoch, targets, accumulated)
            return
        }
        if (accumulated.size >= maxModelRows) {
            modelsReadAttempted = true
            releaseModelRefresh(generation)
            return
        }
        fetchProviderModelsPage(
            generation, rootEpoch, targets, index,
            cursor = null, pages = 0, providerRows = 0, accumulated,
        )
    }

    private fun fetchProviderModelsPage(
        generation: Long,
        rootEpoch: Long?,
        targets: List<String>,
        index: Int,
        cursor: String?,
        pages: Int,
        providerRows: Int,
        accumulated: ArrayList<JsonElement>,
    ) {
        host.readModelPage(
            providerID = targets[index], cursor = cursor, correlationTag = "mlist",
            isCurrent = { modelsSweepCurrent(generation, rootEpoch) },
        ) { modelsOutcome ->
            modelsReadAttempted = true
            if (!modelsSweepCurrent(generation, rootEpoch)) {
                releaseModelRefresh(generation)
                return@readModelPage
            }
            if (modelsOutcome !is HostOperationOutcome.Completed) {
                // Typed refusal / failure of ONE provider page: the whole
                // refresh aborts (no partial cache); the last real
                // projection stays published.
                releaseModelRefresh(generation)
                return@readModelPage
            }
            val value = modelsOutcome.value
            val rows = value?.let { ProviderWire.pageRows(it) }
            if (rows == null) {
                releaseModelRefresh(generation)
                return@readModelPage
            }
            if (providerRows + rows.size > maxProviderModelRows) {
                // Persisted rows beyond the supported per-provider profile
                // bound: honest refusal, never truncation to fit.
                releaseModelRefresh(generation)
                return@readModelPage
            }
            accumulated.addAll(rows)
            val meta = ProviderWire.pageMeta(value)
            if (meta?.hasMore == true) {
                val next = meta.nextCursor
                val nextIndex = next?.toLongOrNull()
                val previousIndex = cursor?.toLongOrNull()
                val progressed = nextIndex != null && nextIndex >= 0 &&
                    (cursor == null || (previousIndex != null && nextIndex > previousIndex))
                if (!progressed || pages + 1 >= maxModelPages ||
                    accumulated.size >= maxModelRows
                ) {
                    releaseModelRefresh(generation)
                    return@readModelPage
                }
                fetchProviderModelsPage(
                    generation, rootEpoch, targets, index,
                    next, pages + 1, providerRows + rows.size, accumulated,
                )
                return@readModelPage
            }
            accumulateModelSweep(generation, rootEpoch, targets, index + 1, accumulated)
        }
    }

    /** True while THIS sweep still owns the read: same generation, same
     * native root, and the provider row set has not been wholesale-replaced
     * mid-chain (a provider added/removed during the sweep retries through
     * the providers-observation collector afterwards). */
    private fun modelsSweepCurrent(generation: Long, rootEpoch: Long?): Boolean =
        modelsRefreshGeneration.get() == generation &&
            host.nativeRootEpoch() == rootEpoch &&
            host.readiness.value.providerConfigurationAdmitted

    private fun finishModelSweep(
        generation: Long,
        rootEpoch: Long?,
        targets: List<String>,
        accumulated: ArrayList<JsonElement>,
    ) {
        if (!modelsSweepCurrent(generation, rootEpoch)) {
            releaseModelRefresh(generation)
            return
        }
        val decoded = ProviderWire.decodeModelRows(
            JsonObject(mapOf("rows" to JsonArray(accumulated.toList()))))
        if (decoded == null) {
            releaseModelRefresh(generation)
            return
        }
        cachedModelRows = decoded
        modelsReadOnce = true
        modelCacheGeneration += 1
        modelCacheSweepGeneration = generation
        modelCacheRootEpoch = rootEpoch
        modelCacheProviderIds = targets.toSet()
        publishModelProjection()
        host.trackOperation(
            HostCommandRequest(
                command = "config.preferences.get",
                scope = HostScope.ApplicationConfiguration("preferences"),
                stateful = false,
                correlationID = client().correlationID("prefget"),
            ),
        ) { prefOutcome ->
            if (!modelsSweepCurrent(generation, rootEpoch)) {
                releaseModelRefresh(generation)
                return@trackOperation
            }
            if (prefOutcome is HostOperationOutcome.Completed) {
                ProviderWire.decodeDefaultAgentModel(prefOutcome.value)?.let {
                    defaultAgentModelId = it
                }
            }
            if (modelsSweepCurrent(generation, rootEpoch)) {
                publishModelProjection()
            }
            releaseModelRefresh(generation)
        }
    }

    private fun releaseModelRefresh(generation: Long) {
        if (modelsRefreshGeneration.get() != generation) return
        modelRefreshInFlight.set(false)
        if (modelRefreshPending.getAndSet(false) &&
            host.readiness.value.providerConfigurationAdmitted) {
            refreshModels()
        }
    }

    private val modelsRefreshGeneration = AtomicLong(0)

    /** The PROVED native per-provider profile bound (a supported profile may
     * carry at most this many model rows; more is outside the contract). */
    private val maxProviderModelRows = 512

    /** The model-chain page guard DERIVED from the supported row ceiling.
     * The native composer caps a page at BOTH 49152 item bytes AND 200
     * items, but 200 is an UPPER bound, not a guaranteed page size: one
     * legal ~30KiB row fills a page by itself. A full supported 512-row
     * profile can therefore legitimately need up to 512 single-row pages,
     * so the guard equals the supported per-provider row ceiling. Strict
     * numeric cursor progress, the per-provider row bound and the fixed
     * 4096-row overall accumulator (all-or-nothing publication) stay
     * unchanged and make any longer chain impossible. This raises NO
     * native envelope/page/row limit — it only stops refusing legal
     * byte-dense supported profiles at the eighth page. */
    private val maxModelPages = maxProviderModelRows
    private val maxModelRows = 4_096

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
            cacheGeneration = modelCacheGeneration,
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

    /**
     * True only when the cached full-row set belongs to the LATEST COMPLETE
     * sweep for the CURRENT native root and provider row set. A last-good
     * cache is deliberately NOT enough: after "read A → save profile B →
     * the next sweep fails", the old A rows still look loaded, but seeding a
     * provider editor from them and saving that draft would legitimately
     * erase B's models. The composer keeps using the last-real projection
     * (separate state); only this destructive-draft admission refuses until a
     * later successful sweep replaces the cache.
     */
    internal fun modelsProjectionReadyForEditing(): Boolean {
        if (!modelsReadOnce) return false
        if (modelRefreshInFlight.get() || modelRefreshPending.get()) return false
        // A newer attempt — still running, failed, or merely requested —
        // has already superseded the cached rows.
        if (modelCacheSweepGeneration != modelsRefreshGeneration.get()) return false
        if (host.nativeRootEpoch() != modelCacheRootEpoch) return false
        return modelCacheProviderIds == modelSweepTargets().toSet()
    }

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
        temporaryNativeRootEpoch: Long = -1L,
    ): com.floe.android.feature.conversation.ConversationFlowHolder {
        val existing = holders[conversationId]
        if (existing != null && existing.holder.session.conversationId == conversationId) {
            // The temporary identity is part of the presentation projection:
            // Keep/End gates and the text-only composer read
            // state.isTemporary/temporaryIncarnationId. A view reconstruction
            // must re-assert the SAME identity (a genuinely ended session is
            // no longer in activeTemporary and this surface is retired by
            // the navigation fence, never silently re-labelled ordinary).
            existing.builder.isTemporary = isTemporary
            existing.builder.temporaryIncarnationId = incarnationId
            if (temporaryNativeRootEpoch >= 0L) {
                existing.holder.temporaryNativeRootEpoch = temporaryNativeRootEpoch
            }
            // Idempotent: a re-resolved surface keeps its existing watch, and a
            // rebound session (new epoch) registers its own.
            ensureTerminalConflictWatch(existing)
            return existing.holder
        }
        val epoch = sessionEpochs.incrementAndGet()
        val holder = com.floe.android.feature.conversation.ConversationFlowHolder(
            this,
            conversationId,
            initialDraft,
            initialSessionEpoch = epoch,
        )
        if (temporaryNativeRootEpoch >= 0L) {
            holder.temporaryNativeRootEpoch = temporaryNativeRootEpoch
        }
        val builder = ThreadProjectionBuilder(conversationId).also {
            it.session = holder.session
            val projection = currentModels()
            it.applyModels(projection.models, projection.needsProvider)
            // A RAM-only temporary session is a REAL conversation identity:
            // its builder must carry the exact hosted incarnation from the
            // first frame so the composer ceiling, Keep and End all observe
            // temporary truth (previously left at the ordinary defaults).
            it.isTemporary = isTemporary
            it.temporaryIncarnationId = incarnationId
        }
        val created = ConversationFlowHolderEntry(
            holder = holder,
            sessionEpoch = epoch,
            isTemporary = isTemporary,
            incarnationId = incarnationId,
            builder = builder,
        )
        holders[conversationId] = created
        // The live owned-slot conflict is HOST truth (the terminal owner's own
        // predicate), not a field on a native run page, so this surface observes
        // it directly and an approval card can offer the explicit decision.
        ensureTerminalConflictWatch(created)
        // First-provider/model configuration must not depend on opening the
        // thread first: an admitted configuration surface refreshes the real
        // projection so the composer can send on the very first open.
        if (host.readiness.value.providerConfigurationAdmitted) refreshModels()
        return holder
    }

    fun entryFor(conversationId: String): ConversationFlowHolderEntry? = holders[conversationId]

    fun releaseHolder(conversationId: String) {
        // Ownership transfer happens BEFORE the map removal: every in-flight
        // detail chain for this conversation is fenced off first, so a late
        // native callback can never publish into another owner's surface.
        invalidatePlanGoalDetails(conversationId)
        invalidatePendingInputBodies(conversationId)
        holders.remove(conversationId)?.let { entry ->
            retireHolderResources(conversationId, entry)
        }
    }

    private fun retireHolderResources(
        conversationId: String,
        entry: ConversationFlowHolderEntry,
    ) {
        val retiredSession = entry.holder.session
        host.scope.launch(host.ioDispatcher) { host.attachments.drainSession(retiredSession) }
        eventPumps.values.filter { it.runID in entry.builder.runIds() }
            .forEach { it.close() }
        // C09: holder retire ends observation for exactly this conversation
        // (identity-CAS: a replacement surface's watch is never touched).
        closeQueueSettleWatchesFor(conversationId)
        // Same discipline for the owned-slot conflict watch: detaching is host
        // resource ownership and never stops or closes a terminal session.
        releaseTerminalConflictWatches(conversationId)
        queueSettleReconcilesInFlight.remove(conversationId)
        queueSettleRerunRequested.remove(conversationId)
        queueSettleConsumedCursors.keys.filter { it.startsWith("$conversationId/") }
            .forEach { queueSettleConsumedCursors.remove(it) }
        entry.builder.runIds().forEach { runID ->
            liveSnapshotRefreshes.remove(runID)
            runStreamGenerations.remove(streamKey(conversationId, runID))
            runDurableWatermarks.remove(streamKey(conversationId, runID))
        }
    }

    /** The currently active temporary session ref, if any. */
    fun activeTemporarySession(): TemporarySessionRef? =
        activeTemporary.values.firstOrNull()

    /**
     * Retire a NATIVE temporary ref that became stale because its owning Home
     * request was invalidated by an actual navigation/New Task. This is NOT
     * a route transition of the CURRENT UI fence: it removes only the exact
     * stale ref and sends the EXISTING `temp.end` command, whose synchronous
     * binder admission fences the exact live tuple (a replacement session
     * under another id is never touched). No fake success and no new command.
     */
    fun retireLateTemporarySession(ref: TemporarySessionRef): Boolean {
        // Exactly-once: only the call that actually RETIRED the exact live
        // tuple submits `temp.end`. An already-retired ref (fence admission
        // or a previous late callback) emits nothing; a replacement session
        // under another id is never touched.
        val retired = activeTemporary.remove(ref.conversationId, ref)
        if (retired) sendLateTemporaryEnd(ref)
        return retired
    }

    /** Exact by-id variant for a pending Home send whose ref is still in the
     * controller map but may not be the first active value. */
    fun retireLateTemporarySession(conversationID: String): Boolean {
        val ref = activeTemporary.remove(conversationID) ?: return false
        sendLateTemporaryEnd(ref)
        return true
    }

    private fun sendLateTemporaryEnd(ref: TemporarySessionRef) {
        host.trackOperation(
            HostCommandRequest(
                command = "temp.end",
                scope = HostScope.ConversationLifecycle(ref.conversationId),
                stateful = true,
                correlationID = client().correlationID("tend-late"),
                revision = HostRevision(
                    "session.${ref.conversationId}", ref.incarnationId),
            ),
        ) { /* native admission/cleanup owns the result; no UI route change */ }
    }

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
                        // D04: cards survive App reload from REAL stored
                        // records — re-read the native owned reader for the
                        // conversation's recent runs (bounded), independent
                        // of whether an event pump replays them.
                        refreshRunOutputCards(entry, session.conversationId,
                            session.sessionEpoch,
                            reply.runs.takeLast(runOutputRefreshMaxRuns).map { it.runID })
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
    ) = refreshRunSnapshotGuarded(entry, runID, reconcileTerminal,
        streamGeneration, null, onApplied)

    private fun refreshRunSnapshotGuarded(
        entry: ConversationFlowHolderEntry,
        runID: String,
        reconcileTerminal: Boolean = false,
        streamGeneration: Long? = null,
        queueOwner: QueueSettleReconcileRun? = null,
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
                    val applyPage = {
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
                        applied = queueOwner == null || page.pendingInputsTruncated == false
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
                            // C09 arm site 2 (contract §6 P3): a terminal LEARNED
                            // FROM THE SNAPSHOT (its pump died before any durable
                            // terminal frame) is exactly the shape where the drain
                            // lane's fact already landed on this run's journal.
                            // Fires for the selected AND non-selected terminal run
                            // — the watch gate (real projected pending rows) is the
                            // single decision point. Latest terminal arm wins.
                            maybeArmQueueSettleWatch(entry, runID, generation)
                        }
                    }
                    if (queueOwner == null) applyPage()
                    else synchronized(queueSettleGate) {
                        if (isCurrentQueueRead(queueOwner) &&
                            currentRunStreamGeneration(ownerConversation, runID) == generation) applyPage()
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
        // A run that just closed displayed a live assistant tail means the
        // native service committed its final assistant message BEFORE the
        // terminal marker (the original ordering rule). A committed page that
        // lacks that row is therefore a lagging read, not the truth.
        val expectedAssistantRow =
            entry.holder.snapshot.value?.liveAssistantText?.isNotEmpty() == true
        entry.builder.closeLiveTail(runID)
        entry.holder.applyHostSnapshot(entry.builder.build())
        settleCommittedRows(
            entry = entry,
            runID = runID,
            expectAssistantRow = expectedAssistantRow,
            attempt = 0,
            onSettled = onSettled,
        )
    }

    /**
     * Bounded settlement of ONE committed turn against the ORIGINAL page
     * authority. The close boundary is a real durable commit, so an EMPTY
     * page (or a transient read failure) there is provably not the settled
     * truth: the very first turn of a brand-new conversation reproduced the
     * exact failure where that read raced the native commit, was accepted as
     * final, and the thread stayed at the pre-launch empty page until
     * navigation re-read it. Each retry is re-fenced AFTER the await on the
     * holder identity, the session epoch, the selected run and the trusted
     * stream generation, so a retired holder, a rebound thread or a newer
     * selected run never receives a late page. The attempt budget is finite
     * and no assistant text is ever fabricated: only real page rows publish.
     */
    private fun settleCommittedRows(
        entry: ConversationFlowHolderEntry,
        runID: String,
        expectAssistantRow: Boolean,
        attempt: Int,
        onSettled: (Boolean) -> Unit,
    ) {
        val conversationId = entry.holder.session.conversationId
        val sessionEpoch = entry.holder.session.sessionEpoch
        val generation = currentRunStreamGeneration(conversationId, runID)
        if (!settlementOwned(entry, conversationId, sessionEpoch, runID, generation)) {
            onSettled(false)
            return
        }
        loadMessagePage(
            entry.holder.session,
            entry,
            requireRun = CommittedPageFence(runID, generation),
        ) { applied, rows ->
            val owned = settlementOwned(
                entry, conversationId, sessionEpoch, runID, generation,
            )
            val assistantPresent = !expectAssistantRow ||
                rows.any { it.role == MessageRoleUi.ASSISTANT && it.runId == runID }
            if (applied && rows.isNotEmpty() && assistantPresent && owned) {
                onSettled(true)
                return@loadMessagePage
            }
            val nextAttempt = attempt + 1
            if (!owned || nextAttempt >= COMMITTED_ROW_SETTLEMENT_ATTEMPTS) {
                // Unsettled: the terminal key is NOT marked reconciled, so a
                // later legitimate terminal/explicit read may settle it.
                onSettled(false)
                return@loadMessagePage
            }
            host.scope.launch(host.ioDispatcher) {
                delay(COMMITTED_ROW_SETTLEMENT_BASE_MILLIS * nextAttempt)
                if (!settlementOwned(
                        entry, conversationId, sessionEpoch, runID, generation,
                    )
                ) {
                    onSettled(false)
                    return@launch
                }
                settleCommittedRows(
                    entry = entry,
                    runID = runID,
                    expectAssistantRow = expectAssistantRow,
                    attempt = nextAttempt,
                    onSettled = onSettled,
                )
            }
        }
    }

    /** True while this exact surface still owns [runID] at [sessionEpoch]. */
    private fun settlementOwned(
        entry: ConversationFlowHolderEntry,
        conversationId: String,
        sessionEpoch: Long,
        runID: String,
        streamGeneration: Long,
    ): Boolean =
        conversationAdmitted() &&
            !entry.holder.retired &&
            ownCurrentEntry(entry, conversationId, sessionEpoch) &&
            entry.builder.selectedRunId == runID &&
            currentRunStreamGeneration(conversationId, runID) == streamGeneration

    /**
     * The REAL launch commit (`prepared`) is a durable boundary: the launch
     * transaction wrote the user turn (and may already have committed the
     * assistant turn on a fast run). Reading the committed page ONCE here is a
     * page read from the original authority — never an optimistic local row —
     * so the first turn of a brand-new conversation appears immediately while
     * the run is still streaming. A failure is harmless: the terminal close
     * settlement above remains the durable authority.
     */
    private fun refreshCommittedRowsAfterLaunch(
        entry: ConversationFlowHolderEntry,
        runID: String,
    ) {
        if (!conversationAdmitted() || entry.holder.retired) return
        val conversationId = entry.holder.session.conversationId
        val sessionEpoch = entry.holder.session.sessionEpoch
        if (!ownCurrentEntry(entry, conversationId, sessionEpoch)) return
        if (entry.builder.selectedRunId != runID) return
        loadMessagePage(
            entry.holder.session,
            entry,
            requireRun = CommittedPageFence(
                runID = runID,
                streamGeneration = currentRunStreamGeneration(conversationId, runID),
            ),
        )
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
        requireRun: CommittedPageFence? = null,
        onSettled: ((applied: Boolean, rows: List<MessageUi>) -> Unit)? = null,
    ) = loadMessagePageGuarded(session, entry, before, requireRun, null, onSettled)

    private fun loadMessagePageGuarded(
        session: ConversationSessionToken,
        entry: ConversationFlowHolderEntry,
        before: MessagePageCursorUi? = null,
        requireRun: CommittedPageFence? = null,
        queueOwner: QueueSettleReconcileRun? = null,
        onSettled: ((applied: Boolean, rows: List<MessageUi>) -> Unit)? = null,
    ) {
        // Latest-window reads carry a monotonic request identity so an older
        // response that completes late is dropped WHOLE. Earlier-history
        // pages are append continuations and keep their own semantics.
        val latest = before == null
        val issuedSeq = if (latest) entry.nextLatestPageReadSeq() else 0L
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
                onSettled?.invoke(false, emptyList())
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
            var rows: List<MessageUi> = emptyList()
            if (outcome is HostOperationOutcome.Completed) {
                val page = outcome.value?.let { ConversationWire.decodeMessagePage(it) }
                if (page != null) {
                    // EVERY mutation (rows, earlier cursor, published state,
                    // content-handle fetch) happens only after admission:
                    // holder/session ownership, the exact closed run + stream
                    // incarnation for a settlement read, and newest-issued
                    // ordering for a latest-window read. Nothing is touched
                    // by a stale/foreign reply.
                    val admitPage = { entry.withAdmittedMessagePage(
                        latest = latest,
                        issuedSeq = issuedSeq,
                        check = {
                            (queueOwner == null || isCurrentQueueRead(queueOwner)) &&
                                !entry.holder.retired &&
                                ownCurrentEntry(
                                    entry, session.conversationId, session.sessionEpoch,
                                ) &&
                                (requireRun == null ||
                                    (entry.builder.selectedRunId == requireRun.runID &&
                                        currentRunStreamGeneration(
                                            session.conversationId, requireRun.runID,
                                        ) == requireRun.streamGeneration))
                        },
                    ) {
                        entry.builder.applyMessagePage(page, earlier = before != null)
                        entry.builder.earlierCursor = page.earlierCursor
                        entry.builder.hasEarlierMessages = page.hasEarlier
                        entry.holder.applyHostSnapshot(entry.builder.build())
                    }
                    }
                    val admitted = if (queueOwner == null) admitPage()
                        else synchronized(queueSettleGate) { admitPage() }
                    if (admitted) {
                        applied = true
                        rows = page.rows.filter {
                            it.role == MessageRoleUi.USER ||
                                it.role == MessageRoleUi.ASSISTANT
                        }
                        // Oversize rows carry an owned handle instead of an
                        // incomplete inline prefix. Fetch the FULL content
                        // through the SAME content.read contract (temporary
                        // handles are re-authorized by the session incarnation
                        // core-side); never guess or truncate locally.
                        fetchOversizeContent(outcome.value, entry, session)
                    }
                }
            }
            onSettled?.invoke(applied, rows)
        }
    }

    /**
     * Bounded full-content fetch for message rows that arrived as owned
     * handles. The reader returns <=32 KiB chunks (the P0 chunk clamp) and
     * an explicit done/nextOffset; the loop stops at the reader's own
     * 4 MiB aggregate bound. Every reply is fenced on the ORIGINAL
     * holder/session identity, so a late chunk can never touch a rebound
     * thread or a replaced temporary incarnation.
     */
    private fun fetchOversizeContent(
        value: kotlinx.serialization.json.JsonElement?,
        entry: ConversationFlowHolderEntry,
        session: ConversationSessionToken,
    ) {
        for ((messageID, handle) in ConversationWire.contentHandles(value)) {
            fetchContentSlice(
                entry = entry,
                session = session,
                messageID = messageID,
                handle = handle,
                offset = 0,
                depth = 0,
            )
        }
    }

    private fun fetchContentSlice(
        entry: ConversationFlowHolderEntry,
        session: ConversationSessionToken,
        messageID: String,
        handle: String,
        offset: Int,
        depth: Int,
    ) {
        if (depth > MAXIMUM_CONTENT_CHUNKS) return
        if (!ownCurrentEntry(entry, session.conversationId, session.sessionEpoch)) return
        host.trackOperation(
            HostCommandRequest(
                command = "content.read",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = false,
                correlationID = client().correlationID("cread"),
                payload = JsonObject(
                    mapOf(
                        "handle" to JsonPrimitive(handle),
                        "offset" to JsonPrimitive(offset),
                        "maxBytes" to JsonPrimitive(32_768),
                    ),
                ),
            ),
        ) { outcome ->
            if (!ownCurrentEntry(entry, session.conversationId, session.sessionEpoch)) {
                return@trackOperation
            }
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val slice = ConversationWire.decodeContentSlice(outcome.value)
                        ?: return@trackOperation
                    entry.builder.appendMessageContent(messageID, slice.chunk)
                    entry.holder.applyHostSnapshot(entry.builder.build())
                    if (!slice.done) {
                        val next = slice.nextOffset
                        if (next != null && next > offset) {
                            fetchContentSlice(
                                entry = entry,
                                session = session,
                                messageID = messageID,
                                handle = handle,
                                offset = next,
                                depth = depth + 1,
                            )
                        }
                    }
                }
                is HostOperationOutcome.Rejected -> {
                    entry.builder.actionError(outcome.code)
                    entry.holder.applyHostSnapshot(entry.builder.build())
                }
                is HostOperationOutcome.Failed -> {
                    entry.builder.actionError(outcome.code)
                    entry.holder.applyHostSnapshot(entry.builder.build())
                }
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> Unit
            }
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
            // THE single run.start LAN producer seam (thread composer send,
            // the Home first send and the structured goal launch all travel
            // here). The broker dispatches public/API<=36 endpoints
            // synchronously with no prompt; an explicit local hop settles
            // THIS correlation through onDenied (the held launch commit
            // restores the draft and staged attachments exactly like any
            // typed pre-admission refusal) and the durable run.start is
            // never created behind a denied grant.
            val providerId = request.providerId?.takeIf { it.isNotBlank() }
            val revision = current.builder.conversationRevision?.let {
                HostRevision(it.resourceID, it.version)
            }
            fun dispatch() = launchRun(request, current, correlation, revision)
            if (providerId == null) {
                // Without a real provider identity launchRun refuses typed
                // (model_unavailable); there is nothing to gate.
                dispatch()
                return@trackOperation
            }
            val started = host.providers.withLocalNetworkForProvider(
                providerID = providerId,
                isCurrent = {
                    holders[request.conversationId] === current &&
                        current.holder.session.sessionEpoch == request.sessionEpoch &&
                        !current.holder.retired
                },
                onDenied = { code ->
                    settleLaunchFailure(
                        current, correlation,
                        host.providers.localNetworkDeniedCopy(code),
                    )
                },
            ) { dispatch() }
            if (!started) {
                // The helper could not start the action (row vanished /
                // superseded): settle as a typed pre-admission failure.
                settleLaunchFailure(current, correlation, "provider_unavailable")
            }
        }
    }

    private class ForegroundLaunch {
        val operationID = java.util.UUID.randomUUID().toString()
        val stop = java.util.concurrent.atomic.AtomicBoolean()
        val runID = java.util.concurrent.atomic.AtomicReference<String?>()
    }

    /** Keep the explicit user-launch start window across native admission. */
    private fun withLaunchProtection(
        conversationID: String,
        isCurrent: () -> Boolean,
        abandoned: () -> Unit,
        dispatch: (ForegroundLaunch) -> Unit,
    ) {
        val launch = ForegroundLaunch()
        val foreground = host.runForeground
        if (foreground == null) { dispatch(launch); return }
        host.scope.launch(host.ioDispatcher) {
            try {
                foreground.agentLaunchProvisional(launch.operationID,
                    com.floe.android.runlifecycle.RunStopHandler {
                        launch.stop.set(true)
                        launch.runID.get()?.let { runID ->
                            host.scope.launch(host.ioDispatcher) { cancelRunFromNotification(conversationID, runID) }
                        }
                    })
            } catch (failure: kotlinx.coroutines.CancellationException) {
                abandoned()
                throw failure
            }
            if (launch.stop.get() || !isCurrent()) {
                foreground.agentLaunchDefinitelyNotAdmitted(launch.operationID)
                abandoned()
            } else dispatch(launch)
        }
    }

    private fun admitForegroundLaunch(launch: ForegroundLaunch, conversationID: String, runID: String) {
        launch.runID.set(runID)
        host.scope.launch(host.ioDispatcher) {
            host.runForeground?.agentLaunchAdmitted(launch.operationID, conversationID, runID)
            if (launch.stop.get()) cancelRunFromNotification(conversationID, runID)
            host.runForeground?.reconcileAgentRuns()
        }
    }

    private fun launchRun(
        request: RunLaunchRequest,
        entry: ConversationFlowHolderEntry,
        correlation: LaunchCorrelation,
        revision: HostRevision?,
        foregroundLaunch: ForegroundLaunch? = null,
    ) {
        if (revision == null) {
            foregroundLaunch?.let { host.runForeground?.agentLaunchDefinitelyNotAdmitted(it.operationID) }
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
            foregroundLaunch?.let { host.runForeground?.agentLaunchDefinitelyNotAdmitted(it.operationID) }
            settleLaunchFailure(entry, correlation, "model_unavailable")
            return
        }
        val stagedHandles = host.attachments.launchHandles(
            ConversationSessionToken(request.conversationId, request.sessionEpoch), request.attachments)
        if (stagedHandles == null) {
            foregroundLaunch?.let { host.runForeground?.agentLaunchDefinitelyNotAdmitted(it.operationID) }
            settleLaunchFailure(entry, correlation, host.attachments.failureMessage("stage_refused"))
            return
        }
        val foreground = host.runForeground
        if (foreground != null && foregroundLaunch == null) {
            val launch = ForegroundLaunch()
            host.scope.launch(host.ioDispatcher) {
                try {
                    foreground.agentLaunchProvisional(launch.operationID,
                        com.floe.android.runlifecycle.RunStopHandler {
                            launch.stop.set(true)
                            launch.runID.get()?.let { runID ->
                                host.scope.launch(host.ioDispatcher) { cancelRunFromNotification(request.conversationId, runID) }
                            }
                        })
                } catch (failure: kotlinx.coroutines.CancellationException) {
                    settleLaunchFailure(entry, correlation, "cancelled")
                    throw failure
                }
                if (launch.stop.get() || !ownCurrentEntry(entry, request.conversationId, request.sessionEpoch)) {
                    foreground.agentLaunchDefinitelyNotAdmitted(launch.operationID)
                    settleLaunchFailure(entry, correlation, "cancelled")
                } else launchRun(request, entry, correlation, revision, launch)
            }
            return
        }
        // The frozen run.start terminal is an identifier-only `accepted`; the
        // minted conversation/run identities exist ONLY in the non-terminal
        // `prepared` effect emitted after the atomic launch commit. Consume
        // exactly one prepared echo, then hand the run to its event pump.
        val preparedRunID = java.util.concurrent.atomic.AtomicReference<String?>(null)
        fun acceptPrepared(prepared: ConversationWire.Prepared) {
            if (!preparedRunID.compareAndSet(null, prepared.runID)) return
            foregroundLaunch?.let { launch ->
                launch.runID.set(prepared.runID)
                host.scope.launch(host.ioDispatcher) {
                    foreground?.agentLaunchAdmitted(launch.operationID, request.conversationId, prepared.runID)
                    if (launch.stop.get()) cancelRunFromNotification(request.conversationId, prepared.runID)
                    foreground?.reconcileAgentRuns() // a short run may already have settled
                }
            }
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
            // The SAME atomic launch transaction committed the real user turn
            // (and, on a fast run, possibly the assistant turn). Reading the
            // committed page here is the original authority — never an
            // optimistic local row — and it is what makes the first turn of a
            // BRAND-NEW conversation visible immediately instead of waiting
            // for the close boundary to settle.
            refreshCommittedRowsAfterLaunch(entry, prepared.runID)
        }
        host.trackOperation(
            request = HostCommandRequest(
                command = "run.start",
                scope = HostScope.LaunchExisting(request.conversationId),
                stateful = true,
                correlationID = client().correlationID("rstart"),
                revision = revision,
                payload = ConversationWire.runStartPayload(request, stagedHandles),
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
                    if (preparedRunID.get() == null) foregroundLaunch?.let {
                        foreground?.agentLaunchDefinitelyNotAdmitted(it.operationID)
                    }
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
        if (ConversationWire.isTerminalFrame(frame)) host.runForeground?.agentRunSettled(runID)
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
            // D04: the completion-critical toolResult records (with sealed
            // output receipts) are durable at this boundary — refresh this
            // run's owned-output cards from the native reader.
            refreshRunOutputCards(entry, conversationId, sessionEpoch, listOf(runID))
            reconcileTerminalCommitted(entry, runID, streamGeneration)
            refreshRunSnapshot(
                entry, runID, streamGeneration = streamGeneration,
            )
            // C09 arm site 1 (contract §6 P3): this run's REAL terminal
            // closed its pump — the drain lane the native just dispatched
            // publishes its settle fact on THIS run's journal. Arm the
            // per-conversation watch HERE (identity-first, Addendum A) so
            // the fact's reader exists before any of its IO can deliver.
            maybeArmQueueSettleWatch(entry, runID, streamGeneration)
        } else if (frame.kind == "approval") {
            // A live approval request needs its requestedAt CAS version, which
            // only the authoritative snapshot carries; the card itself is
            // already projected from the durable event.
            refreshRunSnapshot(
                entry, runID, streamGeneration = streamGeneration,
            )
        }
    }

    // -------------------------------------------------- C09 queue-settle watch

    /**
     * Identity-first arm (MAIN_ADDENDUM A). Opening the event stream launches
     * IO IMMEDIATELY: a current durable fact or a degraded resync delivered
     * BEFORE the watcher state exists would be discarded by the identity
     * fence while its cursor advanced forever. So: install the watch
     * identity first, identity-close the previous watcher, THEN open IO.
     * After the handle is stored, the post-open recheck disposes a
     * late-created handle if a fast callback already removed/replaced the
     * watcher state; a callback whose close decision ran with `handleRef`
     * still null only removed state (closeQueueSettleWatch below).
     *
     * `openStream` is the Addendum-A regression seam (synchronous/immediate
     * callbacks deterministically BEFORE `open` returns); the production
     * default opens the real client stream through the SAME code path.
     */
    internal fun maybeArmQueueSettleWatch(
        entry: ConversationFlowHolderEntry,
        runID: String,
        streamGeneration: Long,
        openStream: (QueueSettleWatch) -> EventPumpHandle? = { watch ->
            openQueueSettleStream(entry, runID, streamGeneration, watch)
        },
    ) {
        if (!conversationAdmitted()) return
        // A temporary surface's queue belongs to its RAM-only run lifecycle;
        // the native drain gate never dispatches for a temporary identity.
        if (entry.builder.isTemporary) return
        val conversationId = entry.holder.session.conversationId
        val sessionEpoch = entry.holder.session.sessionEpoch
        if (!ownCurrentEntry(entry, conversationId, sessionEpoch)) return
        // Only REAL projected pending work gives the terminal drain something
        // to act on; an empty queue keeps no stream warm (no forever-hot watch).
        val drainable = entry.holder.snapshot.value?.pendingInputs
            ?.any { it.status.isPending } == true
        if (!drainable) return
        val existing = queueSettleWatches[conversationId]
        if (existing != null && existing.anchorRunID == runID &&
            existing.streamGeneration == streamGeneration
        ) {
            return // idempotent re-arm
        }
        val watch = QueueSettleWatch(
            conversationId = conversationId,
            anchorRunID = runID,
            streamGeneration = streamGeneration,
            sessionEpoch = sessionEpoch,
        )
        // [1] Register identity BEFORE any IO; identity-close the predecessor
        // (its handle is closed exactly; a retired predecessor callback can
        // never close or mutate this replacement — map identity fences first).
        watch.failureToken = entry.holder.queueRefreshFailureToken
        val replaced = synchronized(queueSettleGate) {
            queueSettleWatches.put(conversationId, watch)
        }
        if (replaced != null && replaced !== watch) {
            closeQueueSettleWatchHandle(replaced)
        }
        // [2] Open IO only now.
        val handle = openStream(watch)
        watch.handleRef.set(handle)
        // [3] Post-open recheck — MAIN review H1: fence LOST OWNERSHIP only
        // (identity / entry / generation). A pump job that already finished
        // is NOT a finished recovery: an immediate typed failure or resync
        // delivered before `open` returned has legitimately started the async
        // authoritative reconcile, and unregistering the watcher here would
        // discard that pending read once callback identity fences apply.
        val current = queueSettleWatches[conversationId]
        if (current !== watch) {
            // Replaced or already closed by its own fenced callback: dispose
            // ONLY the late-created handle; never touch the replacement.
            handle?.close()
            return
        }
        if (!ownCurrentEntry(entry, conversationId, sessionEpoch) ||
            currentRunStreamGeneration(conversationId, runID) != streamGeneration
        ) {
            // The registration window is lost: identity-remove, then close.
            if (queueSettleWatches.remove(conversationId, watch)) {
                handle?.close()
            }
            return
        }
        if (handle == null) {
            // Null-handle test seam: no IO exists to dispose, and an already
            // delivered fact/resync recovery through this watcher must run to
            // its own fenced close. Never cancel it here.
            return
        }

    }

    /** The production opener: the SAME client API every ordinary pump uses —
     *  with the typed durable-resync consumer, which is ALSO what marks this
     *  stream as a queue observer (MAIN_ADDENDUM B: no notAttached COUNT
     *  cutoff for this stream; lifecycle and typed failures still exit). */
    private fun openQueueSettleStream(
        entry: ConversationFlowHolderEntry,
        runID: String,
        streamGeneration: Long,
        watch: QueueSettleWatch,
    ): EventPumpHandle {
        val conversationId = watch.conversationId
        val sessionEpoch = watch.sessionEpoch
        return client().openRunEventStream(
            taskID = conversationId,
            runID = runID,
            environmentID = null,
            jobID = null,
            onEvent = { frame ->
                onQueueSettleFrame(entry, watch, frame, conversationId, sessionEpoch)
            },
            onLiveHint = { /* durable facts and the typed resync signal only */ },
            onFailure = { failure ->
                onQueueSettleWatchFailure(entry, watch, failure, conversationId, sessionEpoch)
            },
            // MAIN review H5: the ACTUAL queue-consumed cursor (never the
            // snapshot watermark, which can already cover an unconsumed
            // notice). An already-appended fact then arrives on the FIRST
            // real binder poll at ANY attach timing (append-only sequence).
            startSequence = queueSettleConsumedCursors[
                streamKey(conversationId, runID)] ?: 0L,
            onDurableResync = {
                onQueueSettleResync(entry, watch, conversationId, sessionEpoch)
            },
        )
    }

    private fun isCurrentQueueSettleWatch(watch: QueueSettleWatch): Boolean =
        queueSettleWatches[watch.conversationId] === watch

    private fun queueTriggerCurrent(
        entry: ConversationFlowHolderEntry,
        conversationId: String,
        sessionEpoch: Long,
        watch: QueueSettleWatch?,
        failureToken: String? = null,
    ): Boolean = conversationAdmitted() &&
        ownCurrentEntry(entry, conversationId, sessionEpoch) &&
        (watch == null || (isCurrentQueueSettleWatch(watch) &&
            currentRunStreamGeneration(conversationId, watch.anchorRunID) ==
                watch.streamGeneration)) &&
        (failureToken == null || entry.holder.queueRefreshFailureToken == failureToken)

    private fun isCurrentQueueRead(run: QueueSettleReconcileRun): Boolean =
        !run.completed.get() &&
            queueSettleReconcilesInFlight[run.conversationId] === run &&
            queueTriggerCurrent(run.entry, run.conversationId, run.sessionEpoch,
                run.watch, run.failureToken)

    internal fun onQueueSettleFrame(
        entry: ConversationFlowHolderEntry,
        watch: QueueSettleWatch,
        frame: HostRunEventFrame,
        conversationId: String,
        sessionEpoch: Long,
    ) {
        if (!isQueueSettleFrame(frame) || frame.runID != watch.anchorRunID) return
        val accepted = synchronized(queueSettleGate) {
            if (!queueTriggerCurrent(entry, conversationId, sessionEpoch, watch)) false
            else {
                val key = streamKey(conversationId, watch.anchorRunID)
                val previous = queueSettleConsumedCursors[key] ?: 0L
                if (frame.sequence <= previous) false else {
                    queueSettleConsumedCursors[key] = frame.sequence
                    true
                }
            }
        }
        if (!accepted) return
        reconcileQueueAfterDrainSettle(entry, conversationId, sessionEpoch,
            watch, decodeQueueSettleFact(frame), false)
    }

    internal fun onQueueSettleResync(
        entry: ConversationFlowHolderEntry,
        watch: QueueSettleWatch,
        conversationId: String,
        sessionEpoch: Long,
    ) {
        if (!queueTriggerCurrent(entry, conversationId, sessionEpoch, watch)) return
        if (!watch.resyncConsumed.compareAndSet(false, true)) return
        reconcileQueueAfterDrainSettle(entry, conversationId, sessionEpoch,
            watch, null, true)
    }

    internal fun onQueueSettleWatchFailure(
        entry: ConversationFlowHolderEntry,
        watch: QueueSettleWatch,
        failure: HostPumpFailure,
        conversationId: String,
        sessionEpoch: Long,
    ) {
        if (!isCurrentQueueSettleWatch(watch)) return
        if (failure is HostPumpFailure.Superseded ||
            (failure is HostPumpFailure.Recoverable && failure.code == "runGone")
        ) {
            closeQueueSettleWatch(watch)
            return
        }
        if (!queueTriggerCurrent(entry, conversationId, sessionEpoch, watch)) {
            closeQueueSettleWatch(watch)
            return
        }
        if (!watch.failureConsumed.compareAndSet(false, true)) return
        reconcileQueueAfterDrainSettle(entry, conversationId, sessionEpoch,
            watch, null, true)
    }

    internal fun reconcileQueueAfterDrainSettle(
        entry: ConversationFlowHolderEntry,
        conversationId: String,
        sessionEpoch: Long,
        watch: QueueSettleWatch?,
        fact: QueueSettleFact?,
        resync: Boolean,
    ) {
        beginQueueRead(entry, conversationId, sessionEpoch, watch, fact, resync, null)
    }

    /** Claim an exact read owner before any callback can arrive. Replacement
     * and coalescing share the same lock, so no completion can release a newer
     * owner's marker or lose a signal arriving at the release boundary. */
    private fun beginQueueRead(
        entry: ConversationFlowHolderEntry,
        conversationId: String,
        sessionEpoch: Long,
        watch: QueueSettleWatch?,
        fact: QueueSettleFact?,
        resync: Boolean,
        failureToken: String?,
    ): Boolean {
        val run = synchronized(queueSettleGate) {
            if (!queueTriggerCurrent(entry, conversationId, sessionEpoch,
                    watch, failureToken)) return false
            val previous = queueSettleReconcilesInFlight[conversationId]
            if (previous != null && isCurrentQueueRead(previous)) {
                if (failureToken == null) {
                    queueSettleRerunRequested[conversationId] = QueueSettleRerun(
                        previous, entry, sessionEpoch, watch, fact, resync)
                }
                return false
            }
            val next = QueueSettleReconcileRun(entry, conversationId,
                sessionEpoch, watch, fact, resync, failureToken)
            queueSettleReconcilesInFlight[conversationId] = next
            // This new valid trigger subsumes the invalid predecessor's
            // carried cause; stale completions cannot consume this slot.
            queueSettleRerunRequested[conversationId]?.let { carried ->
                if (carried.blockedBy === previous) {
                    queueSettleRerunRequested.remove(conversationId, carried)
                }
            }
            next
        }
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(conversationId),
                stateful = false,
                correlationID = client().correlationID(
                    if (failureToken == null) "cget-qstl" else "cget-qrr"),
            ),
        ) { outcome ->
            val reply = (outcome as? HostOperationOutcome.Completed)?.value
                ?.let { ConversationWire.decodeSessionReply(it) }
            val applied = synchronized(queueSettleGate) {
                if (reply == null || !isCurrentQueueRead(run)) false else {
                    run.reply = reply
                    entry.builder.applySession(reply)
                    val models = currentModels()
                    entry.builder.applyModels(models.models, models.needsProvider)
                    entry.holder.applyHostSnapshot(entry.builder.build())
                    true
                }
            }
            if (!applied) {
                finishQueueRead(run, false)
                return@trackOperation
            }
            if (!isCurrentQueueRead(run)) {
                finishQueueRead(run, false)
                return@trackOperation
            }
            resumeLiveRuns(entry.holder.session, entry, reply!!)
            val selected = entry.builder.selectedRunId ?: watch?.anchorRunID
                ?: reply.runs.firstOrNull()?.runID
            if (selected == null) {
                // No run exists to snapshot: only an explicitly complete,
                // empty queue can prove this disappearance. Never pretend a
                // snapshot was applied when it was not issued.
                val emptyAuthority = reply.pendingInputsTruncated == false &&
                    reply.runs.isEmpty() && entry.holder.snapshot.value
                        ?.pendingInputs?.none { it.status.isPending } == true
                readQueueMessages(run, emptyAuthority)
            } else {
                refreshRunSnapshotGuarded(entry, selected, queueOwner = run) { snapshotComplete ->
                    if (!snapshotComplete) finishQueueRead(run, false)
                    else readQueueMessages(run, reply.pendingInputsTruncated == false)
                }
            }
        }
        return true
    }

    private fun readQueueMessages(run: QueueSettleReconcileRun, queueComplete: Boolean) {
        if (!isCurrentQueueRead(run)) {
            finishQueueRead(run, false)
            return
        }
        loadMessagePageGuarded(run.entry.holder.session, run.entry,
            queueOwner = run) { applied, _ -> finishQueueRead(run, queueComplete && applied) }
    }

    private fun finishQueueRead(run: QueueSettleReconcileRun, readComplete: Boolean) {
        var owned = false
        var close = false
        var discover = false
        var carried: QueueSettleRerun? = null
        synchronized(queueSettleGate) {
            if (!run.completed.compareAndSet(false, true)) return
            if (queueSettleReconcilesInFlight[run.conversationId] === run) {
                owned = queueTriggerCurrent(run.entry, run.conversationId,
                    run.sessionEpoch, run.watch, run.failureToken)
                if (owned) {
                    if (readComplete) {
                        val token = run.failureToken ?: run.watch?.failureToken
                        if (token != null) run.entry.holder.clearQueueRefreshFailure(token)
                    } else if (run.failureToken == null) {
                        surfaceQueueRefreshFailure(run.entry, run.watch)
                    }
                    val pending = run.entry.holder.snapshot.value?.pendingInputs
                        ?.any { it.status.isPending } == true
                    discover = pending && run.reply != null
                    close = !readComplete || !pending || run.resync ||
                        run.fact == null || !run.fact.chainOpen
                }
                queueSettleReconcilesInFlight.remove(run.conversationId, run)
            }
            val blocked = queueSettleRerunRequested[run.conversationId]
            if (blocked?.blockedBy === run &&
                queueSettleRerunRequested.remove(run.conversationId, blocked)
            ) {
                carried = blocked
                // A later real signal must not be dropped by an earlier
                // chain-closed result on the very same watch.
                if (blocked.watch === run.watch && queueTriggerCurrent(
                        blocked.entry, run.conversationId, blocked.sessionEpoch,
                        blocked.watch)) close = false
            }
        }
        if (owned && discover) {
            maybeArmDiscoveredQueueSettleTerminal(run.entry, run.reply!!,
                run.conversationId, run.watch)
        }
        if (close || !owned) run.watch?.let { closeQueueSettleWatch(it) }
        carried?.let { next ->
            if (queueTriggerCurrent(next.entry, run.conversationId,
                    next.sessionEpoch, next.watch)) {
                beginQueueRead(next.entry, run.conversationId, next.sessionEpoch,
                    next.watch, next.fact, next.resync, null)
            }
        }
    }

    /** Discover the newest terminal FIRST; excluding the current anchor
     * before ordering could bounce between equal-timestamp historical runs.
     * Generic committed-row reconciliation is not queue acknowledgement. */
    private fun maybeArmDiscoveredQueueSettleTerminal(
        entry: ConversationFlowHolderEntry,
        reply: ConversationWire.SessionReply,
        conversationId: String,
        watch: QueueSettleWatch?,
    ) {
        if (entry.builder.isTemporary || !queueTriggerCurrent(entry,
                conversationId, entry.holder.session.sessionEpoch, watch)) return
        if (entry.holder.snapshot.value?.pendingInputs
                ?.any { it.status.isPending } != true) return
        val candidate = reply.runs.filter {
            it.state in ThreadProjectionBuilder.TERMINAL_STATES
        }.maxByOrNull { it.startedAt } ?: return
        if (candidate.runID == watch?.anchorRunID) return
        val anchor = reply.runs.firstOrNull { it.runID == watch?.anchorRunID }
        if (anchor != null && candidate.startedAt < anchor.startedAt) return
        if (eventPumps.containsKey(candidate.runID)) return
        maybeArmQueueSettleWatch(entry, candidate.runID,
            currentRunStreamGeneration(conversationId, candidate.runID))
    }

    private fun closeQueueSettleWatch(watch: QueueSettleWatch) {
        val removed = synchronized(queueSettleGate) {
            queueSettleWatches.remove(watch.conversationId, watch)
        }
        if (removed) watch.handleRef.get()?.close()
    }

    private fun closeQueueSettleWatchHandle(watch: QueueSettleWatch) {
        watch.handleRef.get()?.close()
    }

    private fun closeQueueSettleWatchesFor(conversationId: String) {
        val watch = synchronized(queueSettleGate) {
            queueSettleWatches.remove(conversationId)
        }
        watch?.handleRef?.get()?.close()
    }

    private fun surfaceQueueRefreshFailure(
        entry: ConversationFlowHolderEntry,
        watch: QueueSettleWatch?,
    ) {
        if (entry.holder.retired) return
        val token = watch?.failureToken?.takeIf {
            it == entry.holder.queueRefreshFailureToken
        } ?: entry.holder.queueRefreshFailureToken ?: java.util.UUID.randomUUID().toString()
        entry.holder.noteQueueRefreshFailure(token)
        if (watch != null) watch.failureToken = token
    }

    override fun refreshQueuedInputProjection(
        session: ConversationSessionToken,
        expectedFailureToken: String,
    ): Boolean {
        val entry = holders[session.conversationId] ?: return false
        if (entry.holder.session != session || entry.builder.isTemporary) return false
        return beginQueueRead(entry, session.conversationId, session.sessionEpoch,
            null, null, true, expectedFailureToken)
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
        val stagedHandles = host.attachments.launchHandles(
            ConversationSessionToken(request.conversationId, request.sessionEpoch), request.attachments)
            ?: return false
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
                    payload = ConversationWire.runningInputPayload(request, stagedHandles),
                ),
            ) { outcome ->
                when (outcome) {
                    is HostOperationOutcome.Completed -> {
                        // Queue accepted ≠ approval resolved ≠ run started; the
                        // durable row identity is the real receipt.
                        outcome.detail["inputID"]?.let {
                            host.attachments.consumeSessionRows(
                                ConversationSessionToken(request.conversationId, request.sessionEpoch),
                                request.attachments.map { it.id })
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
        val stagedHandles = host.attachments.launchHandles(
            ConversationSessionToken(request.conversationId, request.sessionEpoch), request.attachments)
            ?: return false
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
                            // G04R2 queue-input repair: the durable row
                            // owns the composer's REAL execution mode
                            // (iOS parity; the terminal drain launches
                            // exactly the queued mode).
                            put("executionMode", JsonPrimitive(request.executionMode.swiftRaw))
                            request.modelId?.let { put("selectedModelID", JsonPrimitive(it)) }
                            if (stagedHandles.isNotEmpty()) put("stagedAttachments",
                                JsonArray(stagedHandles.map { JsonPrimitive(it) }))
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
                host.attachments.consumeSessionRows(
                    ConversationSessionToken(request.conversationId, request.sessionEpoch),
                    request.attachments.map { it.id })
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
        onDefinitelyNotAdmitted: () -> Unit = { },
        mayDispatch: () -> Boolean = { true },
    ) {
        fun submit(state: String, revision: Revision, isRetry: Boolean) {
            if (!mayDispatch()) { onDefinitelyNotAdmitted(); return }
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
                                    onDefinitelyNotAdmitted()
                                    surfaceError(entry, outcome.code)
                                }
                            }
                        } else {
                            onDefinitelyNotAdmitted()
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
                onDefinitelyNotAdmitted()
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

    /** Notification ownership is independent of the currently visible holder. */
    internal fun cancelRunFromNotification(conversationID: String, runID: String): Boolean {
        val ownerEpoch = host.nativeRootEpoch() ?: return false
        if (!admitted()) return false
        fun readAndCancel(retried: Boolean) {
            if (host.nativeRootEpoch() != ownerEpoch) return
            host.trackOperation(HostCommandRequest(
                command = "run.snapshot", scope = HostScope.TaskExecution(conversationID, runID),
                stateful = false, correlationID = client().correlationID("notify-snapshot"),
            )) { outcome ->
                if (host.nativeRootEpoch() != ownerEpoch || outcome !is HostOperationOutcome.Completed) return@trackOperation
                val page = ConversationWire.decodeSnapshotPage(outcome.value) ?: return@trackOperation
                if (page.runID != runID) return@trackOperation
                if (page.isTerminal) {
                    host.runForeground?.agentRunSettled(runID)
                    return@trackOperation
                }
                host.trackOperation(HostCommandRequest(
                    command = "run.cancel", scope = HostScope.TaskExecution(conversationID, runID),
                    stateful = true, correlationID = client().correlationID("notify-cancel"),
                    revision = HostRevision(page.revision.resourceID, page.revision.version),
                    payload = JsonObject(mapOf("expectedState" to JsonPrimitive(page.durableState))),
                )) { cancelled ->
                    if (!retried && cancelled is HostOperationOutcome.Rejected && host.nativeRootEpoch() == ownerEpoch) readAndCancel(true)
                }
            }
        }
        readAndCancel(false)
        return true // actual request only; terminal proof settles the lease
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
        withLaunchProtection(session.conversationId,
            isCurrent = { ownCurrentEntry(entry, session.conversationId, session.sessionEpoch) },
            abandoned = { surfaceError(entry, "cancelled") },
        ) { foregroundLaunch ->
        dispatchRunStateControl(
            entry = entry,
            runID = runId,
            command = "run.retry",
            correlationPrefix = "rretry",
            payloadFor = { state ->
                JsonObject(mapOf("expectedState" to JsonPrimitive(state)))
            },
            onDefinitelyNotAdmitted = {
                host.runForeground?.agentLaunchDefinitelyNotAdmitted(foregroundLaunch.operationID)
            },
            mayDispatch = { !foregroundLaunch.stop.get() && ownCurrentEntry(entry, session.conversationId, session.sessionEpoch) },
            onCompleted = {
                admitForegroundLaunch(foregroundLaunch, session.conversationId, runId)
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
        }
        return true
    }

    /**
     * Advances the trusted local stream generation for one accepted retry of
     * the SAME run id and re-binds the presentation tail. Durable messages,
     * run rows, CAS revisions and checkpoint/queue state are untouched.
     */
    internal fun rearmRunStreamAfterRetry(
        entry: ConversationFlowHolderEntry,
        runID: String,
    ): Long {
        val conversationId = entry.holder.session.conversationId
        val key = streamKey(conversationId, runID)
        val generation = (runStreamGenerations[key] ?: 0L) + 1L
        synchronized(queueSettleGate) { runStreamGenerations[key] = generation }
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
        // Safe complete-content editing (G04R2): `run.input.edit` REPLACES
        // the durable row. It may only carry text the App has PROVEN to be
        // the whole original — a hydrated full body from the digest-verified
        // detail read, or a row the native snapshot proved short
        // (`previewComplete`). An unread or preview-bound row refuses here
        // (and again against a fresh CAS below); blank/preview NEVER
        // overwrites the original.
        val provenBodyVersion = entry.builder.provenBodyVersion(inputId)
        if (provenBodyVersion == null) {
            surfaceError(entry, "queue_body_not_loaded")
            return false
        }
        dispatchPendingInputMutation(
            entry = entry,
            session = session,
            inputId = inputId,
            command = "run.input.edit",
            correlationPrefix = "red",
            expectedBodyVersion = provenBodyVersion,
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
     * `run.input.edit`/`run.input.remove`: a DURABLE row's envelope CAS is
     * the pending-input row revision `pendingInput.<UPPER uuid>/<input
     * version>` — the EXACT pair the native `mutateInput` proves against the
     * re-read durable row and the detail read publishes (queue-content
     * contract). The payload repeats `expectedInputVersion`. A LIVE
     * TEMPORARY session keeps its ORIGINAL session-revision envelope (the
     * native temporary lane CAS-matches the session revision and the row CAS
     * stays the payload version). Both inputs are re-read at action time
     * (fresh conversation page + fresh `run.snapshot` row version), never
     * guessed. [expectedBodyVersion] (edit only) re-proves against the FRESH
     * snapshot that the proven-complete editor body still describes the
     * current row: a row that moved since the body read refuses with a typed
     * error instead of letting old text replace a newer original.
     *
     * G04R2 queue-input repair: the durable dispatch previously carried the
     * CONVERSATION-row revision, which the native pending-input envelope CAS
     * can never match — every durable edit/remove was rejected
     * (staleRevision/revisionMismatch) AFTER the editor sheet had already
     * closed optimistically, and the typed refusal only reached the
     * continuation detail of a retryable run: an invisible no-op that kept
     * the original row. The envelope now carries the row CAS the native lane
     * actually proves, and every refusal additionally surfaces on the
     * holder's error banner.
     */
    private fun dispatchPendingInputMutation(
        entry: ConversationFlowHolderEntry,
        session: ConversationSessionToken,
        inputId: String,
        command: String,
        correlationPrefix: String,
        expectedBodyVersion: String? = null,
        payloadFor: (inputVersion: String) -> JsonObject,
    ) {
        withFreshConversationRevision(entry) { conversationRevision ->
            if (conversationRevision == null) {
                surfaceQueueMutationError(entry, "revision_unavailable")
                return@withFreshConversationRevision
            }
            entry.builder.selectedRunId?.let { runID ->
                refreshRunSnapshot(entry, runID) { applied ->
                    val inputVersion = entry.builder.inputVersion(inputId)
                    if (!applied || inputVersion == null) {
                        surfaceQueueMutationError(entry, "input_version_unavailable")
                        return@refreshRunSnapshot
                    }
                    if (expectedBodyVersion != null && expectedBodyVersion != inputVersion) {
                        surfaceQueueMutationError(entry, "queue_row_changed")
                        return@refreshRunSnapshot
                    }
                    val runIDForScope = entry.builder.selectedRunId
                    if (runIDForScope == null) {
                        surfaceQueueMutationError(entry, "run_unavailable")
                        return@refreshRunSnapshot
                    }
                    host.trackOperation(
                        HostCommandRequest(
                            command = command,
                            scope = HostScope.TaskExecution(session.conversationId, runIDForScope),
                            stateful = true,
                            correlationID = client().correlationID(correlationPrefix),
                            // Durable rows CAS on their OWN revision identity
                            // (native `mutateInput`); a live temporary session
                            // keeps the session-revision envelope grammar.
                            revision = if (entry.builder.isTemporary) {
                                conversationRevision
                            } else {
                                HostRevision(
                                    ConversationWire.pendingInputResourceID(inputId),
                                    inputVersion,
                                )
                            },
                            payload = payloadFor(inputVersion),
                        ),
                    ) { outcome ->
                        when (outcome) {
                            is HostOperationOutcome.Completed ->
                                refreshRunSnapshot(entry, runIDForScope)
                            is HostOperationOutcome.Rejected ->
                                surfaceQueueMutationError(entry, outcome.code)
                            is HostOperationOutcome.Failed ->
                                surfaceQueueMutationError(entry, outcome.code)
                            else -> Unit
                        }
                    }
                }
            } ?: surfaceQueueMutationError(entry, "run_unavailable")
        }
    }

    /**
     * Queue-mutation failures are USER-VISIBLE. The editor sheet closes
     * optimistically when the dispatch is queued, so an honest refusal must
     * reach the thread error banner (`ThreadErrorBanner` reads
     * `holder.actionError`) in addition to the continuation detail — the
     * durable row keeps its original body on every refusal.
     */
    private fun surfaceQueueMutationError(entry: ConversationFlowHolderEntry, code: String) {
        surfaceError(entry, code)
        entry.holder.noteHostActionError(code)
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
        // The ONE dispatch entry shared by both paths. It is reached at most
        // once per accepted request, and only after every pre-dispatch fence
        // held, so the already-proposed command is never dispatched twice and
        // a failed command is never replayed.
        fun beginDispatch() {
            val known = entry.builder.approvalVersion(request.approvalId)
            if (known != null) {
                dispatch(known)
                return
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
        }

        val consent = request.terminalHandoff
        if (consent == null || decision != "allow") {
            // Ordinary approval-without-conflict: unchanged. A consent can only
            // ride an allow, so a denial never ends a terminal.
            beginDispatch()
            return true
        }
        return beginTerminalHandoffThenDispatch(entry, request, consent) { beginDispatch() }
    }

    /**
     * The explicit human handoff from THIS conversation's own interactive
     * terminal to the already-proposed model command (Main ruling 2026-10-28).
     *
     * It runs BEFORE the existing native approve is called once, so the
     * ordinary dispatcher never sees an occupied engine slot and nothing has to
     * be replayed. Authority is reused, never duplicated: the terminal host
     * closes exactly the captured session and proves the REAL engine-slot
     * release (lease release through the existing trusted-host drain, not an
     * accepted stop and not elapsed time), and the approval itself still leaves
     * through the same `run.approval.resolve` revision/CAS route as an ordinary
     * allow.
     *
     * Every refusal path dispatches NOTHING and publishes one typed code, so the
     * card stays actionable and the user can decide again explicitly. A session
     * that replaced the captured one is a DIFFERENT terminal and is never
     * stopped; another conversation's or another task's work is unreachable
     * here; a retired/navigated surface is told nothing.
     *
     * @return true only when the handoff actually started (the presentation may
     * latch); false when nothing began.
     */
    private fun beginTerminalHandoffThenDispatch(
        entry: ConversationFlowHolderEntry,
        request: ApprovalDecisionRequest,
        consent: TerminalHandoffConsentUi,
        dispatchOnce: () -> Unit,
    ): Boolean {
        val session = ConversationSessionToken(request.conversationId, request.sessionEpoch)
        val approvalKey = "${request.runId}/${request.approvalId}"
        fun refuse(code: String): Boolean {
            // Nothing was dispatched, so the once-only latch must not be taken:
            // publish the typed refusal and report "not started".
            entry.holder.applyTerminalHandoffRefusal(session, approvalKey, code)
            return false
        }
        val terminal = host.workspaceTerminal ?: return refuse("hostUnavailable")
        if (!admitted()) return refuse("notAdmitted")
        // The capture must still BE the session the user was shown and
        // consented to. `liveInteractiveTerminal` answers only for a live Root
        // generation, this host's own handle and an authoritative LIVE
        // interactive status — so a terminal that already ended, a language/run
        // session, a replacement token and a foreign conversation all refuse
        // here without anything being stopped.
        val capture = terminal.liveInteractiveTerminal(request.conversationId)
        if (capture == null ||
            capture.sessionToken != consent.sessionToken ||
            capture.nativeEpoch != consent.nativeEpoch
        ) {
            return refuse("staleCapture")
        }
        if (terminalHandoffInFlight.putIfAbsent(request.conversationId, true) != null) {
            return refuse("handoffAlreadyInFlight")
        }
        val ownerConversation = entry.holder.session.conversationId
        val ownerEpoch = entry.holder.session.sessionEpoch
        host.scope.launch(host.ioDispatcher) {
            try {
                val result = terminal.endCapturedTerminalForHandoff(capture)
                // Ownership is re-proven AFTER the await: only the surface that
                // asked is told the outcome, and the approval is dispatched only
                // while this entry still owns the conversation and the run
                // domain is still admitted. A late result can never touch a
                // replacement surface or dispatch into a retired generation.
                if (!ownCurrentEntry(entry, ownerConversation, ownerEpoch)) return@launch
                if (result is TerminalHandoffResult.Released && admitted()) {
                    dispatchOnce()
                } else {
                    val code = (result as? TerminalHandoffResult.Refused)?.code ?: "notAdmitted"
                    entry.holder.applyTerminalHandoffRefusal(session, approvalKey, code)
                }
            } finally {
                terminalHandoffInFlight.remove(request.conversationId, true)
            }
        }
        return true
    }

    /**
     * Publishes the live owned-slot conflict fact into one surface so its
     * approval cards can offer the explicit end-and-run decision. Registration
     * is the only view-scoped resource; detaching (holder retirement) never
     * touches a session. A surface without a terminal host simply never sees a
     * conflict, so its cards stay exactly as before.
     */
    private fun ensureTerminalConflictWatch(entry: ConversationFlowHolderEntry) {
        val terminal = host.workspaceTerminal ?: return
        val surfaceSession = entry.holder.session
        val conversationId = surfaceSession.conversationId
        val key = "$conversationId@${surfaceSession.sessionEpoch}"
        if (terminalConflictWatches.containsKey(key)) return
        val detach = terminal.watchSessions(conversationId) {
            // The snapshot is only a change signal: the AUTHORITATIVE answer
            // comes from the terminal host's own predicate (live generation,
            // own captured handle, LIVE interactive status, same session), so
            // this never projects a `.run` session or a settled phase as a
            // manual terminal.
            entry.holder.applyTerminalHandoffConflict(
                surfaceSession,
                terminal.liveInteractiveTerminal(conversationId)?.let {
                    TerminalHandoffConflictUi(it.sessionToken, it.nativeEpoch)
                },
            )
        }
        val previous = terminalConflictWatches.put(key, detach)
        previous?.invoke()
    }

    /** Detaches exactly this conversation's conflict watches. Identity-CAS on
     * the stored hook, so a replacement surface's watch is never removed. */
    private fun releaseTerminalConflictWatches(conversationId: String) {
        terminalConflictWatches.keys
            .filter { it == conversationId || it.startsWith("$conversationId@") }
            .forEach { key ->
                terminalConflictWatches.remove(key)?.let { detach ->
                    runCatching { detach() }
                }
            }
    }

    /**
     * `plan.accept` (approved goal-core-code-batch-20261021 contract): ONE
     * user action over the EXISTING command matrix — scope launch, owning
     * conversation taskID, NO runID, NO createIntent, conversation-row
     * digest CAS identical to `run.start` (fresh read at action time,
     * owner/epoch fenced across the await). The accept IS the one launch:
     * the SAME prepared/started/terminal receipt flow is consumed here and
     * the App never dispatches a second run.start behind it. Duplicate
     * clicks, lost acks and retries are settled by the native durable
     * proofs; the App keeps one in-flight accept per conversation.
     */
    override fun acceptPlan(
        session: ConversationSessionToken,
        planId: String,
        planRevision: Int,
        planDigest: String,
        execution: PlanRecommendationUi?,
        modelId: String?,
        providerId: String?,
    ): Boolean {
        if (!admitted()) return false
        val entry = holders[session.conversationId] ?: return false
        if (planId.isBlank() || planDigest.isBlank() || planRevision < 1 ||
            modelId.isNullOrBlank() || providerId.isNullOrBlank()
        ) {
            return false
        }
        if (planAcceptInFlight.putIfAbsent(session.conversationId, true) != null) {
            return false // one accept at a time per conversation (UI latch mirrors this)
        }
        // LAN boundary (Main's LIVE producer helper — the permission logic
        // stays in the broker): a public/local-out-of-scope endpoint
        // dispatches synchronously with no prompt; an explicit local hop on
        // API 37 settles the accept through onDenied WITHOUT ever creating
        // the durable launch effect. The helper fences its own callback on
        // the caller `isCurrent` (holder ownership + session epoch), which
        // survives rotation/background/lock and fails on real retirement or
        // replacement; a second call can never double-dispatch the accept.
        val started = host.providers.withLocalNetworkForProvider(
            providerID = providerId,
            isCurrent = {
                ownCurrentEntry(entry, session.conversationId, session.sessionEpoch)
            },
            onDenied = { code ->
                settlePlanAccept(
                    entry, session, accepted = false,
                    code = host.providers.localNetworkDeniedCopy(code),
                )
            },
        ) {
            acceptPlanWithFreshRevision(
                entry, session, planId, planRevision, planDigest, execution, modelId, providerId,
            )
        }
        if (!started) {
            // Refused to start (no row / already superseded): release the
            // latch and return false; nothing was dispatched.
            planAcceptInFlight.remove(session.conversationId)
        }
        return started
    }

    private fun acceptPlanWithFreshRevision(
        entry: ConversationFlowHolderEntry,
        session: ConversationSessionToken,
        planId: String,
        planRevision: Int,
        planDigest: String,
        execution: PlanRecommendationUi?,
        modelId: String,
        providerId: String,
        foregroundLaunch: ForegroundLaunch? = null,
    ) {
        if (foregroundLaunch == null) {
            withLaunchProtection(session.conversationId,
                isCurrent = { ownCurrentEntry(entry, session.conversationId, session.sessionEpoch) },
                abandoned = { settlePlanAccept(entry, session, accepted = false, code = "cancelled") },
            ) { launch -> acceptPlanWithFreshRevision(entry, session, planId, planRevision,
                planDigest, execution, modelId, providerId, launch) }
            return
        }
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = false,
                correlationID = client().correlationID("cget-plan"),
            ),
        ) { outcome ->
            if (outcome !is HostOperationOutcome.Completed) {
                host.runForeground?.agentLaunchDefinitelyNotAdmitted(foregroundLaunch.operationID)
                settlePlanAccept(entry, session, accepted = false, code = "revision_unavailable")
                return@trackOperation
            }
            val reply = outcome.value?.let { ConversationWire.decodeSessionReply(it) }
            val row = reply?.revision
            val current = holders[session.conversationId]
            if (row == null || current == null || current !== entry ||
                current.holder.session.conversationId != session.conversationId ||
                current.holder.session.sessionEpoch != session.sessionEpoch ||
                current.holder.retired
            ) {
                host.runForeground?.agentLaunchDefinitelyNotAdmitted(foregroundLaunch.operationID)
                settlePlanAccept(entry, session, accepted = false, code = "revision_unavailable")
                return@trackOperation
            }
            if (foregroundLaunch.stop.get()) {
                host.runForeground?.agentLaunchDefinitelyNotAdmitted(foregroundLaunch.operationID)
                settlePlanAccept(entry, session, accepted = false, code = "cancelled")
                return@trackOperation
            }
            current.builder.applySession(reply)
            current.holder.applyHostSnapshot(current.builder.build())
            val members = mutableMapOf<String, JsonElement>(
                "planID" to JsonPrimitive(planId),
                "planRevision" to JsonPrimitive(planRevision),
                "planDigest" to JsonPrimitive(planDigest),
                "providerID" to JsonPrimitive(providerId),
                "modelID" to JsonPrimitive(modelId),
            )
            // Absent key = the plan's OWN durable execution recommendation
            // (never a locally materialized default).
            execution?.let { members["execution"] = JsonPrimitive(it.swiftRaw) }
            val acceptedRunID = java.util.concurrent.atomic.AtomicReference<String?>(null)
            host.trackOperation(
                request = HostCommandRequest(
                    command = "plan.accept",
                    scope = HostScope.LaunchExisting(session.conversationId),
                    stateful = true,
                    correlationID = client().correlationID("planaccept"),
                    revision = HostRevision(row.resourceID, row.version),
                    payload = JsonObject(members),
                ),
                onFrame = { frame ->
                    // The accept's launch travels the SAME prepared/started
                    // effect receipt as run.start (never a second launch).
                    if (frame.kind == "prepared") {
                        ConversationWire.preparedFromEffect(frame.detail)?.let { prepared ->
                            if (acceptedRunID.compareAndSet(null, prepared.runID)) {
                                admitForegroundLaunch(foregroundLaunch, session.conversationId, prepared.runID)
                                applyPlanAcceptPrepared(current, prepared)
                            }
                        }
                    }
                },
            ) { outcome2 ->
                when (outcome2) {
                    is HostOperationOutcome.Completed -> {
                        val page = outcome2.value as? JsonObject
                        val accepted = (page?.get("accepted") as? JsonPrimitive)?.booleanOrNull
                        val runID = (page?.get("runID") as? JsonPrimitive)?.contentOrNull
                        if (accepted == true && runID != null &&
                            acceptedRunID.compareAndSet(null, runID)
                        ) {
                            admitForegroundLaunch(foregroundLaunch, session.conversationId, runID)
                            // Forward-compatible value reply (the actual
                            // producer carries identities in the effect).
                            applyPlanAcceptPrepared(
                                current,
                                ConversationWire.Prepared(
                                    conversationID = session.conversationId,
                                    runID = runID,
                                    resourceID = ConversationWire.runResourceID(runID),
                                    version = "",
                                ),
                            )
                        }
                        settlePlanAccept(
                            entry = current,
                            session = session,
                            accepted = acceptedRunID.get() != null,
                            code = if (acceptedRunID.get() == null) "reply_malformed" else null,
                        )
                    }
                    is HostOperationOutcome.Rejected -> {
                        if (acceptedRunID.get() == null) host.runForeground?.agentLaunchDefinitelyNotAdmitted(foregroundLaunch.operationID)
                        settlePlanAccept(entry, session, accepted = false, code = outcome2.code)
                    }
                    is HostOperationOutcome.Failed ->
                        settlePlanAccept(entry, session, accepted = false, code = outcome2.code)
                    HostOperationOutcome.Cancelled ->
                        settlePlanAccept(entry, session, accepted = false, code = "cancelled")
                    HostOperationOutcome.Superseded ->
                        settlePlanAccept(entry, session, accepted = false, code = "superseded")
                }
            }
        }
    }

    /** Apply the plan accept's prepared identity: the new run joins THIS
     * conversation's thread exactly like an ordinary launch (open pump,
     * refresh history). The composer draft is NOT touched — the accept's
     * prompt is composed host-side from the durable accepted row. */
    private fun applyPlanAcceptPrepared(
        entry: ConversationFlowHolderEntry,
        prepared: ConversationWire.Prepared,
    ) {
        entry.builder.applyPrepared(prepared)
        entry.holder.applyHostSnapshot(entry.builder.build())
        openRunEventStream(entry.holder.session, entry, prepared.runID)
        refreshHistorySoon()
        refreshRunSnapshot(entry, prepared.runID)
    }

    /** One settled accept (accepted OR typed refusal): release the latch,
     * re-read the durable plan/thread, and surface refusals without ever
     * auto-replaying the unknown outcome. */
    private fun settlePlanAccept(
        entry: ConversationFlowHolderEntry,
        session: ConversationSessionToken,
        accepted: Boolean,
        code: String?,
    ) {
        planAcceptInFlight.remove(session.conversationId)
        // Ownership fence: a late settlement for a replaced holder touches
        // nothing beyond the durable re-read (the row is real either way).
        val current = holders[session.conversationId]
        if (current != null && current === entry && !entry.holder.retired &&
            current.holder.session.sessionEpoch == session.sessionEpoch
        ) {
            // The UI in-flight latch is released on the REAL settlement only
            // for the still-owned holder; a replaced holder's card follows
            // its own fresh projection.
            entry.holder.applyPlanAcceptSettled()
            if (!accepted && code != null) {
                // Callers pass either a stable machine code (surfaced in the
                // thread's typed error channel) or an already-localized
                // producer sentence (LAN denial copy from the broker helper).
                surfaceError(entry, code)
            }
            loadThreadInternal(current.holder.session)
        }
        refreshHistorySoon()
    }

    /**
     * Structured goal creation over the EXISTING ordinary `run.start`
     * (approved additive `goalDefinition` key): the objective stays the run's
     * own goal text (never flattened with criteria), and the separate
     * objective/criteria/blocking/stopping fields travel as closed nested
     * members. The native C1 writes the durable ConversationGoal atomically
     * with the launch (ORIGINAL GoalCriterion defaults are Swift-side; the
     * App never writes a goal row directly and never composes the default
     * criterion). The model is the thread's ACTUAL selected configured
     * provider/model — the old first-usable substitution is removed.
     */
    override fun createGoal(request: GoalCreateRequest): Boolean {
        if (!admitted()) return false
        val entry = holders[request.conversationId] ?: return false
        val objective = request.objective.trim()
        if (objective.isEmpty()) return false
        val modelId = request.modelId?.takeIf { it.isNotBlank() } ?: return false
        val providerId = request.providerId?.takeIf { it.isNotBlank() } ?: return false
        // The projection remains the usability authority (enabled row +
        // enabled configured provider): a goal launch never bypasses it.
        val selected = currentModels().models.firstOrNull {
            it.modelId.equals(modelId, ignoreCase = true) && it.isUsable
        } ?: return false
        val definition = GoalDefinitionUi(
            objective = objective,
            criteria = request.criteria,
            blockingConditions = request.blockingConditions,
            stoppingConditions = request.stoppingConditions,
        )
        val session = ConversationSessionToken(
            request.conversationId, entry.holder.session.sessionEpoch)
        val correlation = LaunchCorrelation(
            conversationId = request.conversationId,
            sessionEpoch = session.sessionEpoch,
            launchGeneration = goalLaunchGenerations.incrementAndGet(),
            temporaryIncarnationId = null,
        )
        if (definition.exceedsNativeBounds()) {
            // Typed refusal BEFORE any durable effect: over-budget producer
            // fields are never truncated on the way to the bridge.
            surfaceError(entry, "goalDefinitionTooLarge")
            return false
        }
        launchCorrelations[correlation.launchGeneration.toString()] = correlation
        val launch = RunLaunchRequest(
            conversationId = request.conversationId,
            sessionEpoch = session.sessionEpoch,
            goalText = objective,
            attachments = emptyList(),
            executionMode = AgentExecutionModeUi.GOAL,
            modelId = selected.modelId,
            workspaceId = null,
            temporaryIncarnationId = null,
            launchGeneration = correlation.launchGeneration,
            providerId = selected.providerId,
            goalDefinition = definition,
        )
        // The LAN boundary for every actual run.start (including this goal
        // launch) is the ONE producer wrap inside
        // [launchWithFreshConversationRevision]; wrapping the create/C1 flow
        // twice would double-own one human gesture, so the goal path relies
        // on that single seam.
        // Same action-time fresh row read as the ordinary send path: the
        // goal launch reuses the SAME `run.start` conversationProof CAS.
        launchWithFreshConversationRevision(launch, entry, correlation)
        return true
    }

    /**
     * `goal.confirm` (approved contract): scope conversationLifecycle, the
     * OWNING conversation, no runID (works after terminal — the original
     * confirm semantics), envelope revision `goal.<goalID>` /
     * `revisionVersion` VERBATIM from the durable projection and the payload
     * `expectedGoalRevision` equal to it. The trusted command itself is the
     * explicit human action — no model/inferred approval boolean exists.
     * A blocked result persists NOTHING (real blockers surfaced localized);
     * a stale refusal re-reads the durable truth and never auto-replays.
     */
    override fun confirmGoalCompletion(
        session: ConversationSessionToken,
        goalId: String,
        expectedRevision: Int,
        revisionResourceID: String,
        revisionVersion: String,
    ): Boolean {
        if (!conversationAdmitted()) return false
        val entry = holders[session.conversationId] ?: return false
        if (goalId.isBlank() || expectedRevision < 1 ||
            revisionResourceID.isBlank() || revisionVersion.isBlank()
        ) {
            return false
        }
        host.trackOperation(
            HostCommandRequest(
                command = "goal.confirm",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = true,
                correlationID = client().correlationID("gconfirm"),
                revision = HostRevision(revisionResourceID, revisionVersion),
                payload = JsonObject(
                    mapOf(
                        "goalID" to JsonPrimitive(goalId),
                        "expectedGoalRevision" to JsonPrimitive(expectedRevision),
                    ),
                ),
            ),
        ) { outcome ->
            // Ownership fence across the await: a late settlement may only
            // mutate THIS exact holder; the durable row is real either way.
            val current = holders[session.conversationId]
            val owned = current != null && current === entry &&
                !entry.holder.retired &&
                entry.holder.session.sessionEpoch == session.sessionEpoch
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val page = outcome.value as? JsonObject
                    val confirmed = (page?.get("confirmed") as? JsonPrimitive)?.booleanOrNull
                    if (owned) {
                        if (confirmed == false) {
                            val codes = (page?.get("blockers") as? JsonArray).orEmpty()
                                .mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                            entry.holder.applyGoalConfirmBlocked(
                                codes.map { localizeGoalBlocker(it) },
                            )
                        } else {
                            // confirmed:true (or a shape without the member —
                            // then the durable re-read is the authority): a
                            // newer settlement owns a fresh surface.
                            entry.holder.clearGoalConfirmBlockers()
                        }
                        loadThreadInternal(entry.holder.session)
                    }
                }
                is HostOperationOutcome.Rejected -> {
                    if (owned) {
                        surfaceError(entry, "goalConfirm_${outcome.code}")
                        // Stale/non-verifying: re-read the durable truth so
                        // the next explicit attempt binds the CURRENT revision.
                        loadThreadInternal(entry.holder.session)
                    }
                }
                is HostOperationOutcome.Failed -> {
                    if (owned) surfaceError(entry, "goalConfirm_${outcome.code}")
                }
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    /** Localize one native blocker machine code into a natural human line;
     * the raw code (and its id suffix) stays only in diagnostic detail. */
    private fun localizeGoalBlocker(code: String): String {
        val family = code.substringBefore(':')
        val res = when (family) {
            "wrongGoal" -> com.floe.android.R.string.goal_blocker_wrong_goal
            "goalAlreadyTerminal" -> com.floe.android.R.string.goal_blocker_already_terminal
            "incompleteStep" -> com.floe.android.R.string.goal_blocker_incomplete_step
            "unsatisfiedCriterion" -> com.floe.android.R.string.goal_blocker_unsatisfied_criterion
            "missingEvidence", "unknownEvidence" ->
                com.floe.android.R.string.goal_blocker_missing_evidence
            "userConfirmationRequired" ->
                com.floe.android.R.string.goal_blocker_user_confirmation
            "reviewRejected" -> com.floe.android.R.string.goal_blocker_review_rejected
            "failedChecks", "unresolvedErrors" ->
                com.floe.android.R.string.goal_blocker_failed_checks
            else -> com.floe.android.R.string.goal_blocker_generic
        }
        return runCatching { host.appContext.getString(res) }
            .getOrElse { code } // host-unit fallback: honest raw, never empty
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
        if (!attachmentSessionIsCurrent(session)) return false
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
        if (!conversationAdmitted() || !attachmentSessionIsCurrent(session) ||
            request.conversationId != session.conversationId) return false
        host.attachments.open(request)
        return true
    }

    internal fun onAttachmentStaged(
        session: ConversationSessionToken,
        staged: StagedAttachmentUi,
    ) {
        val entry = holders[session.conversationId] ?: return
        if (!attachmentSessionIsCurrent(session)) return
        entry.builder.stageAttachment(staged)
        entry.holder.stagedAttachments.value =
            entry.holder.stagedAttachments.value.filterNot { it.id == staged.id } + staged
        entry.holder.applyHostSnapshot(entry.builder.build())
    }

    internal fun onAttachmentProgress(
        session: ConversationSessionToken,
        attachmentId: String,
        import: AttachmentImportUi,
    ) {
        if (!attachmentSessionIsCurrent(session)) return
        holders[session.conversationId]?.holder?.applyAttachmentOutcome(attachmentId, import)
    }

    internal fun attachmentSessionIsCurrent(session: ConversationSessionToken): Boolean {
        val entry = holders[session.conversationId] ?: return false
        return entry.holder.session == session && !entry.holder.retired && !entry.builder.isTemporary
    }

    internal fun onAttachmentRemoved(session: ConversationSessionToken, attachmentId: String) {
        if (!attachmentSessionIsCurrent(session)) return
        val entry = holders[session.conversationId] ?: return
        entry.builder.unstageAttachment(attachmentId)
        entry.holder.stagedAttachments.value = entry.holder.stagedAttachments.value.filterNot { it.id == attachmentId }
    }

    internal fun onAttachmentImportFailed(session: ConversationSessionToken, reason: String) {
        if (attachmentSessionIsCurrent(session)) holders[session.conversationId]?.let {
            surfaceError(it, host.attachments.failureMessage(reason))
        }
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
        host.attachments.consumeSessionRows(session, sentAttachmentIds)
    }

    /**
     * `conversation.compact` (approved contract): scope conversationLifecycle,
     * the durable OWNING conversation, NO runID/createIntent/revision (the
     * core owns the single shared per-conversation reservation and every
     * real launch admission participates in it — the App never bypasses or
     * re-implements that guard, and a live-run conversation answers with the
     * REAL typed refusal). [modelId] is the thread's actual selected model or
     * null (native persisted default; never first-usable). The reply is the
     * REAL compacted/noHistory/shortHistory outcome; the App composes the
     * localized status line from its actual members — no localized strings
     * cross the bridge and truthful no-ops preserve full history.
     */
    override fun requestManualCompaction(
        session: ConversationSessionToken,
        modelId: String?,
    ): Boolean {
        if (!conversationAdmitted()) return false
        val entry = holders[session.conversationId] ?: return false
        if (entry.holder.retired || entry.holder.session != session) return false
        if (entry.builder.isTemporary) return false // honest: temp compacts nothing
        val payload = modelId?.takeIf { it.isNotBlank() }?.let {
            JsonObject(mapOf("modelID" to JsonPrimitive(it)))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.compact",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = false,
                correlationID = client().correlationID("ccompact"),
                payload = payload,
            ),
        ) { outcome ->
            val current = holders[session.conversationId]
            val owned = current != null && current === entry &&
                !entry.holder.retired &&
                entry.holder.session.sessionEpoch == session.sessionEpoch
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    if (owned) {
                        val page = outcome.value as? JsonObject
                        entry.builder.applyCompactionStatus(
                            composeCompactionStatus(page) ?: entry.builder.compactionStatus,
                        )
                        entry.holder.applyCompactionSettled()
                        entry.holder.applyHostSnapshot(entry.builder.build())
                        // The durable history changed (or a truthful no-op
                        // proved it did not): re-read the rows either way.
                        loadThreadInternal(entry.holder.session)
                    }
                }
                is HostOperationOutcome.Rejected -> {
                    if (owned) {
                        entry.holder.applyCompactionSettled()
                        surfaceError(entry, "compact_${outcome.code}")
                    }
                }
                is HostOperationOutcome.Failed -> {
                    if (owned) {
                        entry.holder.applyCompactionSettled()
                        surfaceError(entry, "compact_${outcome.code}")
                    }
                }
                HostOperationOutcome.Cancelled -> {
                    if (owned) entry.holder.applyCompactionSettled()
                }
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    /** The localized status line for one settled compact (REAL members
     * only): compacted → token delta with the actual counts; noHistory /
     * shortHistory → the truthful no-op line (nothing was written). */
    private fun composeCompactionStatus(page: JsonObject?): String? {
        val compacted = (page?.get("compacted") as? JsonPrimitive)?.booleanOrNull ?: return null
        val reason = (page["reason"] as? JsonPrimitive)?.contentOrNull
        val res = if (compacted) {
            com.floe.android.R.string.compaction_did_compact
        } else when (reason) {
            "shortHistory" -> com.floe.android.R.string.compaction_short_history
            else -> com.floe.android.R.string.compaction_no_history
        }
        val base = runCatching { host.appContext.getString(res) }.getOrNull() ?: return null
        if (!compacted) return base
        val before = (page["beforeTokens"] as? JsonPrimitive)?.longOrNull
        val after = (page["afterTokens"] as? JsonPrimitive)?.longOrNull
        return if (before != null && after != null) {
            runCatching {
                host.appContext.getString(
                    com.floe.android.R.string.compaction_did_compact_tokens,
                    before, after,
                )
            }.getOrDefault(base)
        } else {
            base
        }
    }

    /**
     * The live-run permissions affordance producer (⇄ ConversationCenter
     * taskPolicy + `run.policy.update`): updates the persisted TaskPolicy
     * row under its REAL CAS version (the snapshot `policyRevision`, never
     * a timestamp guess or locally bumped value) and echoes the actual
     * `appliedToLiveRun` result. Only a human action on the permissions
     * surface reaches this; imported/model content has no route. One
     * human gesture composes AT MOST ONE mutation — a stale or unknown
     * result is surfaced with its typed code and never auto-replayed.
     *
     * Fences: the gesture freezes its mode, session and current run at tap
     * time, and the per-holder intent sequence makes the LATEST human
     * intent supersede older queued/in-flight work: a retired, navigated,
     * epoch-changed, run-changed or superseded settlement can never adopt
     * a policy mode or invalidate the CAS state that now belongs to
     * another intent. The latest-intent admission and the projection
     * mutation execute under ONE monitor, so a newer tap that lands
     * between the admission test and the mutation still supersedes the
     * settlement (RuntimeHost settles on ioDispatcher while taps arrive
     * concurrently). The durable repair for missing policy rows is
     * native (launch-time materialization + the v48 convergence
     * migration); this producer only sends revisions the snapshot proved —
     * never fabricated versions.
     */
    fun updateTaskApprovalMode(
        session: ConversationSessionToken,
        mode: ApprovalModeUi,
        onSettled: ((accepted: Boolean, code: String?, appliedToLiveRun: Boolean) -> Unit)? = null,
    ): Boolean {
        if (!admitted()) return false
        val entry = holders[session.conversationId] ?: return false
        if (entry.builder.isTemporary) {
            // A RAM-only temporary session owns NO durable policy row; the
            // snapshot reports an honest null revision and there is nothing
            // to update (never a durable fallback read for a temp id).
            onSettled?.invoke(false, "temporaryPolicyNotDurable", false)
            return false
        }
        val runID = entry.builder.selectedRunId
        val revision = entry.builder.policyRevision
        if (revision == null || runID == null) {
            // No proven CAS identity: refuse and re-read the authoritative
            // snapshot instead of sending a fabricated version.
            if (runID != null) refreshRunSnapshot(entry, runID)
            onSettled?.invoke(false, "policyRevisionUnavailable", false)
            return false
        }
        // Freeze the human intent (mode/session/run captured above); the
        // sequence makes this gesture the latest intent and lets a newer
        // tap supersede its queued and in-flight settlement.
        val intentSeq = entry.nextPolicyGestureIntent()
        host.trackOperation(
            HostCommandRequest(
                command = "run.policy.update",
                scope = HostScope.TaskExecution(session.conversationId, runID),
                stateful = true,
                correlationID = client().correlationID("rpolupd"),
                revision = HostRevision(revision.resourceID, revision.version),
                payload = JsonObject(
                    mapOf(
                        // ORIGINAL closed vocabulary from the actual parser
                        // (ask/automatic/fullAccess) — never raw guesses.
                        "approvalMode" to JsonPrimitive(mode.swiftRaw),
                        "expectedPolicyVersion" to JsonPrimitive(revision.version),
                        // NO ceiling/flag members are composed here: the
                        // existing TaskPolicy ceilings stay untouched (a
                        // missing optional member keeps the persisted value).
                    ),
                ),
            ),
        ) { outcome ->
            // Settlement fences: the ownership/session-epoch check, the
            // unchanged-run check and the latest-intent admission execute
            // under ONE monitor together with the projection mutation.
            // RuntimeHost settles operations on ioDispatcher while a human
            // tap can concurrently bump the gesture sequence on the UI
            // thread; a separate locked boolean read would let a newer tap
            // slip between the read and the mutation and STILL be projected.
            // Host I/O (snapshot refresh) and the caller callback stay
            // OUTSIDE the monitor.
            val fenceCheck = {
                ownCurrentEntry(entry, session.conversationId, session.sessionEpoch) &&
                    entry.builder.selectedRunId == runID
            }
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val applied = outcome.detail["appliedToLiveRun"] == "true"
                    val newVersion = outcome.detail["policyVersion"]
                    val admitted = entry.withLatestPolicyGestureIntent(
                        intentSeq = intentSeq,
                        check = fenceCheck,
                    ) {
                        entry.builder.applyPolicyUpdateSettled(mode, newVersion)
                        entry.holder.applyHostSnapshot(entry.builder.build())
                    }
                    if (admitted) {
                        // Re-read the authoritative snapshot so subsequent
                        // CAS uses the durable truth (the reply's version is
                        // already adopted; this proves, it does not assume).
                        refreshRunSnapshot(entry, runID)
                    }
                    onSettled?.invoke(true, null, applied)
                }
                is HostOperationOutcome.Rejected -> {
                    val admitted = entry.withLatestPolicyGestureIntent(
                        intentSeq = intentSeq,
                        check = fenceCheck,
                    ) {
                        entry.builder.invalidatePolicyRevision()
                        surfaceError(entry, "policy_${outcome.code}")
                    }
                    if (admitted) {
                        // The designed recovery for the still-latest intent:
                        // invalidate + ONE authoritative re-read, never an
                        // automatic replay of the rejected gesture.
                        refreshRunSnapshot(entry, runID)
                    }
                    // A stale refusal is surfaced with its typed code, never
                    // silently replayed and never applied to another intent.
                    onSettled?.invoke(false, outcome.code, false)
                }
                is HostOperationOutcome.Failed -> {
                    entry.withLatestPolicyGestureIntent(
                        intentSeq = intentSeq,
                        check = fenceCheck,
                    ) {
                        surfaceError(entry, "policy_${outcome.code}")
                    }
                    onSettled?.invoke(false, outcome.code, false)
                }
                HostOperationOutcome.Cancelled -> onSettled?.invoke(false, "cancelled", false)
                HostOperationOutcome.Superseded -> onSettled?.invoke(false, "superseded", false)
            }
        }
        return true
    }

    /** Refresh the durable child graph for the CURRENTLY selected run
     * (inspector entry point; reuses the existing `child.list` producer). */
    fun refreshChildGraph(session: ConversationSessionToken) {
        val entry = holders[session.conversationId] ?: return
        val runID = entry.builder.selectedRunId ?: return
        loadChildRuns(entry, runID)
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
        if (entry.holder.retired || entry.holder.session != session) return false
        val child = entry.holder.snapshot.value?.childRuns?.firstOrNull { it.id == childRunId }
            ?: return false
        if (child.parentRunId.isBlank()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "child.entries",
                scope = HostScope.TaskExecution(session.conversationId, child.parentRunId),
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
            if (outcome is HostOperationOutcome.Completed && outcome.value != null &&
                holders[session.conversationId] === entry &&
                !entry.holder.retired && entry.holder.session == session) {
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
                    // Exact-VALUE retirement (never bare-id): a stale or
                    // late terminal for a replaced tuple cannot evict the
                    // replacement's registration.
                    // A malformed committed receipt must remain retryable:
                    // retain this exact registration until a real durable
                    // identity arrives. Removing it now would make the next
                    // alreadyCommitted receipt fail the ownership fence.
                    val stillMine = if (conversationID == null) {
                        activeTemporary[ref.conversationId] == ref
                    } else {
                        activeTemporary.remove(ref.conversationId, ref)
                    }
                    // UI ownership fence: this closure runs on the
                    // root-wide command client, so projection adoption,
                    // refresh, failure surfacing and any route effect are
                    // honored ONLY for the EXACT origin holder/ref that
                    // issued this Keep. A late committed result still
                    // refreshes durable history (the genuine rows survive);
                    // it never mutates a replacement holder, navigates an
                    // old id or lets the shell fence-end a new session.
                    val originOwned = holder != null && stillMine &&
                        holder.session.conversationId == ref.conversationId &&
                        holder.session.sessionEpoch == ref.sessionEpoch
                    if (conversationID == null) {
                        if (originOwned) {
                            // The receipt certifies a committed Keep but
                            // carries no durable identity to adopt — a
                            // wire-contract violation, never a promotion
                            // the App may assume. Surface an honest typed
                            // failure (a retry reaches the real
                            // alreadyCommitted receipt) instead of leaving
                            // the bound Keep waiting forever in Saving.
                            holder?.applyTemporaryKeepOutcome(
                                ref, TemporaryKeepOutcomeUi.Failed("keepIdentityMissing"))
                        }
                    } else if (originOwned && entry != null &&
                        conversationID == ref.conversationId
                    ) {
                        // Same-id atomic promotion (the REAL Core
                        // committed/alreadyCommitted receipt shape): adopt
                        // the ordinary durable projection for THIS exact
                        // bound kept identity BEFORE acknowledging UI
                        // promotion. The holder's promoted guard observes
                        // the projection — previously no path ever flipped
                        // it, so a durably committed Keep looked like a
                        // silent no-op with a stale Temporary header.
                        entry.builder.isTemporary = false
                        entry.builder.temporaryIncarnationId = null
                        entry.builder.promotedConversationId = conversationID
                        entry.holder.applyHostSnapshot(entry.builder.build())
                        entry.holder.applyTemporaryKeepOutcome(
                            ref, TemporaryKeepOutcomeUi.Promoted)
                        // Refresh the thread from the durable row the
                        // commit just created (real title/runs/rows via
                        // the same ordinary load path a history reopen
                        // uses). A read failure stays honest: the
                        // projection keeps the receipt-adopted truth and
                        // a later reload reconciles.
                        loadThreadInternal(entry.holder.session)
                        // Scoped adoption signal INSTEAD of generic
                        // navigation: persisting the durable saved
                        // selection is the shell's decision, only while
                        // this exact origin surface is still current.
                        keptPromotion.value = KeptPromotion(
                            originRef = ref,
                            durableConversationId = conversationID,
                        )
                    } else if (originOwned) {
                        // Different-id remap receipt (not the current
                        // native shape): the generic navigation stays,
                        // but only for this exact still-live origin.
                        holder?.applyTemporaryKeepOutcome(
                            ref, TemporaryKeepOutcomeUi.Promoted)
                        navigationRequest.value = SidebarSelection.Conversation(conversationID)
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
                            temporaryNativeRootEpoch = nativeRootEpoch,
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

    // --------------------------------------- bounded plan/goal detail read

    /** The closed detail chunk preference (the native default; the FINAL
     * serialized page still fits the frozen 49152 page inside the 65536
     * frame by native measured shrinkage — nothing here widens any budget). */
    private val detailMaxChunkBytes = 32_768

    /** Fixed accumulation ceiling for the canonical durable row. A row
     * beyond this is honestly refused (typed) — never a partial publish,
     * never an endless follow. */
    private val detailMaxTotalBytes = 1_048_576L

    private val detailStates =
        ConcurrentHashMap<String, MutableStateFlow<PlanGoalDetailStateUi>>()
    private val detailGenerations = ConcurrentHashMap<String, AtomicLong>()

    /** The detail-read state for one conversation row kind ("goal"/"plan").
     * Reads are EXPLICIT (task inspection opening / user retry): no timers,
     * no background resurrection, all-or-nothing publication. */
    fun planGoalDetailState(conversationId: String, kind: String): StateFlow<PlanGoalDetailStateUi> =
        detailStates.getOrPut("$conversationId:$kind") {
            MutableStateFlow(PlanGoalDetailStateUi.Idle)
        }

    /** Start ONE bounded `conversation.get.detail` canonical-row read over
     * the EXISTING command (closed additive member; a reply without the
     * member is the SAME honest absence). The first page resolves the
     * CURRENT durable plan / latest goal (terminal fallback carries its
     * real status label) or the LATEST original checklist row over the
     * shared store (ordinary only — temporary has no checklist producer).
     * Continuations follow ONLY native `nextOffset` with the exact id +
     * previous-page digest, prove byte-boundary continuity client-side,
     * and assemble raw UTF-8 until the full row is proven complete; a
     * mid-chain refusal keeps the last state and reports the typed code —
     * a trimmed summary is never republished as a full row. */
    fun requestPlanGoalDetail(session: ConversationSessionToken, kind: String): Boolean {
        if (!conversationAdmitted()) return false
        if (kind != "goal" && kind != "plan" && kind != "checklist") return false
        val entry = holders[session.conversationId] ?: return false
        if (entry.isTemporary) return false // a RAM-only session has no durable row
        val flow = detailStates.getOrPut("${session.conversationId}:$kind") {
            MutableStateFlow(PlanGoalDetailStateUi.Idle)
        }
        val generation = detailGenerations
            .getOrPut("${session.conversationId}:$kind") { AtomicLong(0) }.incrementAndGet()
        flow.value = PlanGoalDetailStateUi.Loading
        readDetailPage(
            conversationId = session.conversationId,
            entry = entry,
            kind = kind,
            generation = generation,
            rootEpoch = host.nativeRootEpoch(),
            flow = flow,
            id = null,
            offset = 0L,
            digest = null,
            assembled = ConversationDetailAssembler(kind, detailMaxTotalBytes),
        )
        return true
    }

    /** Ownership fence: a releasing/retired conversation invalidates every
     * in-flight detail chain; a late callback can then never publish into
     * another owner's surface. */
    internal fun invalidatePlanGoalDetails(conversationId: String) {
        detailGenerations["$conversationId:goal"]?.incrementAndGet()
        detailGenerations["$conversationId:plan"]?.incrementAndGet()
        detailGenerations["$conversationId:checklist"]?.incrementAndGet()
    }

    private fun readDetailPage(
        conversationId: String,
        entry: ConversationFlowHolderEntry,
        kind: String,
        generation: Long,
        rootEpoch: Long?,
        flow: MutableStateFlow<PlanGoalDetailStateUi>,
        id: String?,
        offset: Long,
        digest: String?,
        assembled: ConversationDetailAssembler,
    ) {
        fun current(): Boolean =
            detailGenerations["$conversationId:$kind"]?.get() == generation &&
                holders[conversationId] === entry &&
                host.nativeRootEpoch() == rootEpoch
        val detailMembers = buildMap<String, JsonElement> {
            put("kind", JsonPrimitive(kind))
            if (offset > 0L) {
                id?.let { put("id", JsonPrimitive(it)) }
                put("offset", JsonPrimitive(offset))
                digest?.let { put("digest", JsonPrimitive(it)) }
            }
            put("maxBytes", JsonPrimitive(detailMaxChunkBytes))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(conversationId),
                stateful = false,
                correlationID = client().correlationID("cgetdetail"),
                payload = JsonObject(mapOf("detail" to JsonObject(detailMembers))),
            ),
        ) { outcome ->
            if (!current()) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val page = outcome.value?.let { ConversationWire.decodeDetailPage(it) }
                    if (page == null) {
                        val value = outcome.value as? JsonObject
                        flow.value = if (value != null && !value.containsKey("detail")) {
                            PlanGoalDetailStateUi.Absent
                        } else {
                            PlanGoalDetailStateUi.Failed("detailRowUnreadable")
                        }
                        return@trackOperation
                    }
                    when (val result = assembled.accept(page)) {
                        is ConversationDetailAssembler.Result.Failed -> {
                            flow.value = PlanGoalDetailStateUi.Failed(result.code)
                        }
                        is ConversationDetailAssembler.Result.Complete -> {
                            publishAssembledDetail(flow, page, result.content)
                        }
                        ConversationDetailAssembler.Result.Continue -> {
                            readDetailPage(
                                conversationId = conversationId,
                                entry = entry,
                                kind = kind,
                                generation = generation,
                                rootEpoch = rootEpoch,
                                flow = flow,
                                id = page.id,
                                offset = page.nextOffset,
                                digest = page.digest,
                                assembled = assembled,
                            )
                        }
                    }
                }
                // The checklist answers a foreign/missing run or an absent
                // store with the typed `notFound` REFUSAL (its documented
                // absence form); goal/plan answer with a reply WITHOUT the
                // member. Both are honest ABSENCE — never an error state —
                // while any other typed code (staleRevision, envelope
                // refusals) stays a real failure with the code surfaced.
                is HostOperationOutcome.Rejected -> flow.value =
                    if (outcome.code == "notFound" && kind == "checklist") {
                        PlanGoalDetailStateUi.Absent
                    } else {
                        PlanGoalDetailStateUi.Failed(outcome.code)
                    }
                is HostOperationOutcome.Failed ->
                    flow.value = PlanGoalDetailStateUi.Failed(outcome.code)
                HostOperationOutcome.Cancelled, HostOperationOutcome.Superseded -> Unit
            }
        }
    }

    private fun publishAssembledDetail(
        flow: MutableStateFlow<PlanGoalDetailStateUi>,
        finalPage: ConversationWire.DetailPage,
        assembled: String,
    ) {
        val root = runCatching {
            kotlinx.serialization.json.Json.parseToJsonElement(assembled.toString()) as? JsonObject
        }.getOrNull()
        if (root == null || (finalPage.kind != "checklist" &&
                (root["id"] as? JsonPrimitive)?.contentOrNull != finalPage.id)) {
            flow.value = PlanGoalDetailStateUi.Failed("detailRowUnreadable")
            return
        }
        flow.value = when (finalPage.kind) {
            "goal" -> ConversationWire.decodeGoalDetailRow(root)
                ?.let(PlanGoalDetailStateUi::GoalReady)
                ?: PlanGoalDetailStateUi.Failed("detailRowUnreadable")
            "plan" -> ConversationWire.decodePlanDetailRow(root)
                ?.let(PlanGoalDetailStateUi::PlanReady)
                ?: PlanGoalDetailStateUi.Failed("detailRowUnreadable")
            else -> ConversationWire.decodeChecklistDetailRow(
                root,
                pageRunID = finalPage.id,
                pageRevision = finalPage.revision,
                pageStatusRaw = finalPage.statusRaw,
            )?.let(PlanGoalDetailStateUi::ChecklistReady)
                ?: PlanGoalDetailStateUi.Failed("detailRowUnreadable")
        }
    }

    // ------------------------------ bounded pending-input body read (G04R2)

    /** Generation fence per (conversation, input id): re-opening another row
     * (or the same row again) cancels the previous chain, and a late chunk
     * callback can never publish into a newer read. */
    private val pendingBodyGenerations = ConcurrentHashMap<String, AtomicLong>()

    private fun pendingBodyKey(conversationId: String, inputId: String) =
        "$conversationId/$inputId"

    /** Ownership fence: releasing/retiring a conversation cancels every
     * in-flight queue-body read for it (same rule as the plan/goal chain). */
    internal fun invalidatePendingInputBodies(conversationId: String) {
        pendingBodyGenerations.keys
            .filter { it.startsWith("$conversationId/") }
            .forEach { pendingBodyGenerations[it]?.incrementAndGet() }
    }

    /**
     * Start ONE bounded `conversation.get.detail{kind:"pendingInput",id}`
     * read for the EXACT durable queue row — the queue editor's full-body
     * hydration authority. This REUSES the existing digest-verified
     * byte-exact assembly lane (closed additive kind, same as plan/goal/
     * checklist): no parallel queue database, no plaintext cache, no
     * fabricated text, no widened budget. Success publishes
     * `Ready(text, native CAS version)`; every typed refusal publishes
     * `Failed(code)` and the editor stays edit-locked — an unread original
     * is never replaced by blank or preview text.
     */
    override fun requestPendingInputBody(
        session: ConversationSessionToken,
        inputId: String,
    ): Boolean {
        val entry = holders[session.conversationId] ?: return false
        // Typed-refusal publication (C04 cold-load repair): every refusal
        // with a live surface moves the editor slot to an honest actionable
        // failure — the sheet must never render an endless "Loading" promise
        // for a read that was never started. Re-opening the editor
        // re-requests (the row is still unproven), so a transient refusal
        // self-heals on the user's next attempt.
        if (!conversationAdmitted()) {
            publishPendingInputBodyFailure(entry, inputId, "hostUnavailable")
            return false
        }
        if (entry.isTemporary) {
            // A RAM-only session has no durable queue row.
            publishPendingInputBodyFailure(entry, inputId, "temporarySession")
            return false
        }
        val row = entry.builder.pendingInputRow(inputId) ?: return false
        // Already proven complete (hydrated body or a native-proven short
        // row): the editor binds the projection; no redundant read.
        if (entry.builder.provenBodyVersion(inputId) != null) return true
        val key = pendingBodyKey(session.conversationId, inputId)
        val generation = pendingBodyGenerations
            .getOrPut(key) { AtomicLong(0) }.incrementAndGet()
        entry.builder.setPendingInputBody(inputId, PendingInputBodyUi.Loading)
        entry.holder.applyHostSnapshot(entry.builder.build())
        readPendingInputBodyPage(
            conversationId = session.conversationId,
            entry = entry,
            inputId = inputId,
            generation = generation,
            rootEpoch = host.nativeRootEpoch(),
            id = inputId,
            offset = 0L,
            digest = null,
            assembled = ConversationDetailAssembler("pendingInput", detailMaxTotalBytes),
        )
        return true
    }

    /** Publish one typed editor-slot refusal for a still-live surface. The
     * slot never stays a silent null/Loading after a guard refused the
     * read; the sheet renders the honest unread notice and a re-open
     * re-dispatches. */
    private fun publishPendingInputBodyFailure(
        entry: ConversationFlowHolderEntry,
        inputId: String,
        code: String,
    ) {
        entry.builder.setPendingInputBody(inputId, PendingInputBodyUi.Failed(code))
        entry.holder.applyHostSnapshot(entry.builder.build())
    }

    private fun readPendingInputBodyPage(
        conversationId: String,
        entry: ConversationFlowHolderEntry,
        inputId: String,
        generation: Long,
        rootEpoch: Long?,
        id: String,
        offset: Long,
        digest: String?,
        assembled: ConversationDetailAssembler,
        epochReissued: Boolean = false,
    ) {
        // Slot OWNERSHIP vs PUBLISH SAFETY are separate fences (C04
        // cold-load repair). Ownership: this is still the newest request for
        // the row — a re-request, a release or an invalidation bumped the
        // generation, and only the newest chain may touch the slot. Publish
        // safety additionally requires the SAME holder entry and the SAME
        // admitted native root epoch, so a full body can never publish from
        // a moved world. The old single all-or-nothing fence silently
        // dropped EVERY terminal — including typed refusals — whenever any
        // component moved between capture and callback, stranding the owned
        // Loading slot with no retry and no failure. That stranding is the
        // device-proven C04 cold defect; its exact live sub-case (an
        // epoch/readback race, an admission flicker or a mailbox
        // replacement) is INFERRED from the closed silent-hole set, not
        // traced — the release build exposes no epoch telemetry.
        val key = pendingBodyKey(conversationId, inputId)
        fun ownsSlot(): Boolean = pendingBodyGenerations[key]?.get() == generation
        fun entryCurrent(): Boolean = holders[conversationId] === entry
        fun publishSafe(): Boolean = ownsSlot() && entryCurrent() &&
            host.nativeRootEpoch() == rootEpoch
        fun fail(code: String) {
            // FAILURE publication keeps the explicit holder-entry fence
            // too: a replaced/released owner may not publish to its old
            // surface. Release/replace paths already bump the generation
            // (invalidatePendingInputBodies), so the entry guard is
            // defensive — kept explicit for clarity and regression.
            if (!ownsSlot()) return
            if (!entryCurrent()) return
            entry.builder.setPendingInputBody(inputId, PendingInputBodyUi.Failed(code))
            entry.holder.applyHostSnapshot(entry.builder.build())
        }
        val detailMembers = buildMap<String, JsonElement> {
            put("kind", JsonPrimitive("pendingInput"))
            // The pendingInput kind REQUIRES the exact row identity on EVERY
            // page (first included): there is no id-less "latest row"
            // resolution for queue content and never will be.
            put("id", JsonPrimitive(id))
            if (offset > 0L) {
                put("offset", JsonPrimitive(offset))
                digest?.let { put("digest", JsonPrimitive(it)) }
            }
            put("maxBytes", JsonPrimitive(detailMaxChunkBytes))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(conversationId),
                stateful = false,
                correlationID = client().correlationID("cgetbody"),
                payload = JsonObject(mapOf("detail" to JsonObject(detailMembers))),
            ),
        ) { outcome ->
            // A newer request (or a release/invalidation) owns the slot now:
            // this chain's terminal must not touch it.
            if (!ownsSlot()) return@trackOperation
            if (!publishSafe()) {
                // The holder entry or the native root generation moved while
                // this owned read was in flight (inferred cold-start race:
                // the epoch readback is nil while the mailbox is
                // admission-fenced and flips when the root re-admits, so the
                // value captured at dispatch can be nil/stale against the
                // terminal's world). NEVER publish a body across that move —
                // but the owned slot must not strand either: re-issue this
                // row's read exactly ONCE, only for the EXACT same holder
                // entry, against the current root; a second move surfaces
                // the typed actionable failure (re-open retries).
                if (entryCurrent() && !epochReissued) {
                    readPendingInputBodyPage(
                        conversationId = conversationId,
                        entry = entry,
                        inputId = inputId,
                        generation = generation,
                        rootEpoch = host.nativeRootEpoch(),
                        id = inputId,
                        offset = 0L,
                        digest = null,
                        assembled = ConversationDetailAssembler(
                            "pendingInput", detailMaxTotalBytes),
                        epochReissued = true,
                    )
                } else if (entryCurrent()) {
                    fail("hostGenerationChanged")
                }
                // A replaced/released holder entry publishes NOTHING to its
                // old surface (fail() carries the same explicit entry
                // fence); the new surface re-hydrates fresh on its open.
                return@trackOperation
            }
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val page = outcome.value?.let { ConversationWire.decodeDetailPage(it) }
                    if (page == null) {
                        fail("detailRowUnreadable")
                        return@trackOperation
                    }
                    when (val result = assembled.accept(page)) {
                        is ConversationDetailAssembler.Result.Failed -> fail(result.code)
                        is ConversationDetailAssembler.Result.Complete -> {
                            val root = runCatching {
                                kotlinx.serialization.json.Json
                                    .parseToJsonElement(result.content) as? JsonObject
                            }.getOrNull()
                            val decoded = root?.let {
                                ConversationWire.decodePendingInputBodyRow(
                                    it, page.id, page.revisionResourceID, page.revisionVersion,
                                )
                            }
                            if (decoded == null) {
                                fail("detailRowUnreadable")
                                return@trackOperation
                            }
                            // Publish ONLY a still-pending durable row: a
                            // row consumed/cancelled during the read is a
                            // typed refusal, never an editable body.
                            if (decoded.statusRaw != "queued" &&
                                decoded.statusRaw != "promoting" &&
                                decoded.statusRaw != "steerPending"
                            ) {
                                fail("pendingInputRowResolved")
                                return@trackOperation
                            }
                            if (!entry.builder.applyPendingInputBody(
                                    inputId, decoded.content, decoded.inputVersion,
                                )
                            ) {
                                // The projection retired or moved this row
                                // mid-read: never publish a body whose CAS
                                // no longer describes the current row.
                                fail("pendingInputRowStale")
                                return@trackOperation
                            }
                            entry.holder.applyHostSnapshot(entry.builder.build())
                        }
                        ConversationDetailAssembler.Result.Continue -> readPendingInputBodyPage(
                            conversationId = conversationId,
                            entry = entry,
                            inputId = inputId,
                            generation = generation,
                            rootEpoch = rootEpoch,
                            id = page.id,
                            offset = page.nextOffset,
                            digest = page.digest,
                            assembled = assembled,
                            epochReissued = epochReissued,
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> fail(outcome.code)
                is HostOperationOutcome.Failed -> fail(outcome.code)
                // The mailbox retired/replaced under this read (host
                // generation bump, mailbox close): the owned slot must land
                // on a typed actionable failure, never a silent endless
                // Loading. A re-open re-dispatches against the live root.
                HostOperationOutcome.Cancelled, HostOperationOutcome.Superseded ->
                    fail("operationSuperseded")
            }
        }
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

    /**
     * R2-A privacy history-clear consumer refresh (Main direction
     * 2026-10-21): after a SAME-root completed clear — INCLUDING a partial
     * one — re-read the REAL history list and reconcile the retained
     * per-conversation holders against the same root. Holder survival is
     * decided ONLY by an authoritative per-row `conversation.get` under the
     * current root and the EXACT holder-entry identity (the entry's
     * globally-unique [ConversationFlowHolderEntry.sessionEpoch]); a row
     * that answers the typed `notFound` refusal is released through the
     * existing [releaseHolder] lifecycle so its closed pumps can never
     * resurrect cleared history. Absence from the first history page is NOT
     * proof of deletion — survivors, unrelated state and any newer
     * holder/root are preserved, and RAM-only temporary sessions (never in
     * the durable store) are never existence-checked at all.
     *
     * The identity token is the ENTRY's unique session epoch, NOT
     * `holder.session.sessionEpoch`: a fresh holder always starts its UI
     * session epoch at 0, so after a release + re-open the new holder would
     * collide with the old capture (ABA) and a late `notFound` could release
     * the WRONG holder. The entry epoch is minted once from the global
     * counter and never reused, so it names exactly one holder instance.
     */
    internal fun refreshAfterPrivacyHistoryClear() {
        if (!conversationAdmitted()) return
        val rootEpoch = host.nativeRootEpoch()
        refreshHistory()
        if (rootEpoch == null) return
        val retained = holders.entries.map { entry ->
            Triple(entry.key, entry.value.sessionEpoch, entry.value.isTemporary)
        }
        for ((conversationId, entryEpoch, isTemporary) in retained) {
            if (isTemporary) continue
            checkHolderSurvivalAfterPrivacyClear(conversationId, entryEpoch, rootEpoch)
        }
    }

    /**
     * ONE authoritative existence read for a retained holder. Only the typed
     * `notFound` refusal under the SAME root and the SAME holder-entry
     * generation releases the surface; every other outcome (including a
     * newer root, a replaced/reopened holder or a fenced session) keeps it.
     */
    private fun checkHolderSurvivalAfterPrivacyClear(
        conversationId: String,
        entryEpoch: Long,
        rootEpoch: Long,
    ) {
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(conversationId),
                stateful = false,
                correlationID = client().correlationID("cget-prv"),
            ),
        ) { outcome ->
            if (outcome is HostOperationOutcome.Rejected &&
                outcome.code == "notFound" &&
                host.nativeRootEpoch() == rootEpoch &&
                holders[conversationId]?.sessionEpoch == entryEpoch
            ) {
                // Atomic expected-entry retirement: an ABA replacement
                // cannot slip between the identity check and map removal.
                var released: ConversationFlowHolderEntry? = null
                holders.computeIfPresent(conversationId) { _, entry ->
                    if (entry.sessionEpoch != entryEpoch || entry.isTemporary) {
                        entry
                    } else {
                        invalidatePlanGoalDetails(conversationId)
                        invalidatePendingInputBodies(conversationId)
                        retireHolderResources(conversationId, entry)
                        released = entry
                        null
                    }
                }
                released?.let { entry ->
                    if (privacyVisibleHolder.get() === entry.holder) {
                        privacyClearedConversation.value = PrivacyClearedConversationSignal(
                            conversationId = conversationId,
                            entryEpoch = entryEpoch,
                            rootEpoch = rootEpoch,
                            holder = entry.holder,
                        )
                    }
                }
            }
        }
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
     *
     * The real revision MUST be re-read with one `conversation.get` at action
     * time (the frozen CAS source), never from the holder cache. A holder
     * cache only proves the digest at the moment it was last applied; the
     * durable run/message commit advances the row digest on every accepted
     * launch, so reusing the cached value for a LATER `conversation.delete`
     * is exactly the stale-revision defect already fixed for the second
     * `run.start` (ConversationSecondSendRevisionTest): the native deletion
     * CAS `digest == revision.version` then refuses with the typed
     * `staleRevision`, the row is untouched, and — because the single-row
     * completion observer only records the Completed path — no typed deletion
     * is ever captured. This mirrors the fresh-read contract the existing
     * `withFreshConversationRevision` comment states verbatim ("the
     * conversation row's digest advances on every real launch/message commit,
     * so a cached revision cannot be reused for a later … CAS") and keeps
     * an unreadable row surfacing a typed failure — never a fabricated
     * version and never a silent stale success.
     */
    private fun resolveConversationRevision(
        conversationId: String,
        onReady: (HostRevision?) -> Unit,
    ) {
        // NO cached fast path: always read the CURRENT row revision here.
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
                    // Re-publish the fresh revision into the holder so the
                    // thread view and any following action see the SAME digest
                    // this delete was admitted under (an authoritative echo,
                    // never the CAS source for a later action).
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
            // Dispatch-time ACTUAL native Root epoch, read BEFORE the
            // operation is handed to the command client. A completion-time
            // read could label an OLD terminal under a NEWER root, so the
            // value captured here is the one carried through the callback;
            // a null read stays honestly `unavailable` downstream.
            val dispatchEpoch = host.nativeRootEpoch()
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
                            // Bounded READ-ONLY projection of the ORIGINAL
                            // typed deletion reply into the existing
                            // diagnostics surface (the all-zero lane counts
                            // are missing proof, not a cause). Only the
                            // closed wire tokens already in the reply are
                            // kept — no new reader, retry, control or
                            // authority path is added here. The epoch is
                            // the dispatch-time value captured above.
                            LinuxTypedDeletionRecord.observe(
                                LinuxTypedDeletionRecord.Entry(
                                    epoch = dispatchEpoch,
                                    projected = LocalRuntimeProofProjection.projectTypedDeletion(
                                        reply = outcome.value as? JsonObject,
                                        operationConversationID = conversationId,
                                        dispatchEpoch = dispatchEpoch,
                                    ),
                                ),
                            )
                             val deletedOwner = (outcome.value as? JsonObject)?.string("conversationID")
                             if (dispatchEpoch != null && deletedOwner.equals(conversationId, ignoreCase = true)) {
                                 host.scope.launch(host.ioDispatcher) {
                                     host.workspaceEditors.discardDeletedTask(conversationId, dispatchEpoch)
                                 }
                             }
                             releaseHolder(conversationId)
                         }
                         // A fresh single-row success replaces the last real
                         // settlement failure on this surface (the bulk lane
                         // reports per-item truth through the receipt).
                         if (correlationPrefix != "blk") {
                             historyHolder.dismissActionError()
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

    override fun renameConversation(conversationId: String, title: String, requestToken: Long): Boolean {
        if (!conversationAdmitted() || title.isBlank()) return false
        mutateConversation(
            conversationId = conversationId,
            command = "conversation.rename",
            payload = JsonObject(mapOf("title" to JsonPrimitive(title))),
            correlationPrefix = "crename",
        ) { accepted, _ -> historyHolder.applyRenameOutcome(conversationId, requestToken, accepted) }
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

    /* ---------------------------- D04 owned run outputs ------------------------ */

    /** Bounded cold-load / terminal refresh window for owned-output cards. */
    private val runOutputRefreshMaxRuns = 24

    private fun isCanonicalUuid(raw: String): Boolean = runCatching {
        java.util.UUID.fromString(raw).toString().equals(raw, ignoreCase = true)
    }.getOrDefault(false)

    private fun isCanonicalOutputId(raw: String): Boolean = raw.matches(Regex("[0-9a-f]{64}"))

    /** Re-reads the native OWNED reader for the given runs and republishes
     * the card rows. Ordinary conversations only: a temporary session never
     * reaches native (no durable rows, no cards, no backdoor). Refusals
     * degrade to the honest non-actionable "unavailable" state on existing
     * verified cards — success is never fabricated. */
    private fun refreshRunOutputCards(
        entry: ConversationFlowHolderEntry,
        conversationId: String,
        sessionEpoch: Long,
        runIDs: List<String>,
    ) {
        val service: RunOutputHostService = host.runOutputs ?: return
        if (entry.builder.isTemporary) return
        val capped = runIDs.filter { isCanonicalUuid(it) }.distinct().take(runOutputRefreshMaxRuns)
        if (capped.isEmpty()) return
        if (!ownCurrentEntry(entry, conversationId, sessionEpoch)) return
        host.scope.launch(host.ioDispatcher) {
            for (runID in capped) {
                if (!ownCurrentEntry(entry, conversationId, sessionEpoch)) return@launch
                val result = service.receipts(conversationId, runID)
                if (!ownCurrentEntry(entry, conversationId, sessionEpoch)) return@launch
                when (result) {
                    is RunOutputListResult.Ok -> entry.builder.applyRunOutputs(
                        runID,
                        result.items.map { descriptor ->
                            RunOutputCardUi(
                                runId = descriptor.runID,
                                outputId = descriptor.outputID,
                                producerCallId = descriptor.producerCallID,
                                displayName = descriptor.displayName,
                                mimeType = descriptor.mimeType,
                                byteCount = descriptor.byteCount,
                                availabilityRaw = descriptor.availabilityRaw,
                            )
                        },
                        scanTruncated = result.scanTruncated || result.truncatedItems,
                    )
                    is RunOutputListResult.Refused ->
                        entry.builder.markRunOutputsUnavailable(runID)
                }
            }
            if (ownCurrentEntry(entry, conversationId, sessionEpoch)) {
                entry.holder.applyHostSnapshot(entry.builder.build())
            }
        }
    }

    override fun saveRunOutputCopy(
        session: ConversationSessionToken,
        runId: String,
        outputId: String,
    ): Boolean {
        val entry = holders[session.conversationId] ?: return false
        if (entry.holder.session != session || entry.builder.isTemporary) return false
        val service = host.runOutputs ?: return false
        val card = entry.builder.cachedRunOutputCard(runId, outputId) ?: return false
        if (card.availabilityRaw != "available") return false
        if (!isCanonicalUuid(session.conversationId) || !isCanonicalUuid(runId) ||
            !isCanonicalOutputId(outputId)) return false
        val conversationId = session.conversationId
        val sessionEpoch = session.sessionEpoch
        entry.builder.setRunOutputActionState(runId, outputId, "saving")
        entry.holder.applyHostSnapshot(entry.builder.build())
        host.scope.launch(host.ioDispatcher) {
            // Native open re-derives the exact owned durable record and runs
            // the FULL streamed digest verification before the destination
            // pick is even requested; a refusal there never claims progress.
            val started = service.requestSaveCopy(conversationId, runId, outputId) { outcome ->
                host.scope.launch(host.ioDispatcher) {
                    if (!ownCurrentEntry(entry, conversationId, sessionEpoch)) return@launch
                    val state = when (outcome) {
                        is RunOutputSaveOutcome.Saved -> "saved"
                        is RunOutputSaveOutcome.Cancelled -> "cancelled"
                        is RunOutputSaveOutcome.Failed -> "failed"
                    }
                    entry.builder.setRunOutputActionState(runId, outputId, state)
                    entry.holder.applyHostSnapshot(entry.builder.build())
                    refreshRunOutputCards(entry, conversationId, sessionEpoch, listOf(runId))
                }
            }
            if (!started) {
                if (ownCurrentEntry(entry, conversationId, sessionEpoch)) {
                    entry.builder.setRunOutputActionState(runId, outputId, null)
                    entry.holder.applyHostSnapshot(entry.builder.build())
                }
            }
        }
        return true
    }

    override fun openRunOutputFile(
        session: ConversationSessionToken,
        runId: String,
        outputId: String,
    ): Boolean {
        val entry = holders[session.conversationId] ?: return false
        if (entry.holder.session != session || entry.builder.isTemporary) return false
        val card = entry.builder.cachedRunOutputCard(runId, outputId) ?: return false
        if (card.availabilityRaw != "available") return false
        if (!isCanonicalUuid(session.conversationId) || !isCanonicalUuid(runId) ||
            !isCanonicalOutputId(outputId)) return false
        val epoch = host.nativeRootEpoch() ?: return false
        val generation = host.commandClient.generation()
        val conversationId = session.conversationId
        val sessionEpoch = session.sessionEpoch
        // The EXACT ordinary-conversation owner fence both routes re-check
        // through staging AND launch: entry identity + session epoch + the
        // captured native root epoch + App command generation. Temporary chat
        // returned above; Notes/Canvas never reach this file's callbacks.
        val ownerCurrent = {
            ownCurrentEntry(entry, conversationId, sessionEpoch) &&
                !entry.builder.isTemporary &&
                host.nativeRootEpoch() == epoch &&
                host.commandClient.generation() == generation
        }
        // Lane 17: a durable PDF run output opens IN-APP through the App's
        // own preview consumer (verified staged bytes -> the SAME isolated
        // renderer + real system Print). The route requires the verified
        // sealed MIME to MATCH the `.pdf` extension (agreement, never either
        // alone); any other host-refused type still gets no fake affordance.
        if (runOutputPdfOpenAgreement(card.mimeType, card.displayName)) {
            val pdf = (host.appContext as? FloeApplication)?.runOutputPdf ?: return false
            return pdf.openRunOutputPdf(
                RunOutputOfficeSnapshotStager.Owner(conversationId, runId, outputId, epoch, generation),
                ownerCurrent,
            )
        }
        // EXISTING in-app Office path (DOCX/XLSX/PPTX). No external intent
        // fallback, no local preview invention.
        if (!OfficePreviewController.supports(card.displayName)) return false
        val office = (host.appContext as? FloeApplication)?.officePreviews ?: return false
        if (office.isBusy) {
            // Honest VISIBLE refusal: the single Office viewer slot is held
            // by another owned operation (for example the task's still-open
            // viewer). The guard stays — this route never retargets or
            // replaces the live viewer — but a busy refusal must not be a
            // silent no-op the discarded Rejected result leaves invisible.
            // The note is advisory App state (feature-presentation literal
            // "open-blocked"), cleared by the next admitted attempt; the
            // authoritative admission check stays inside admit().
            entry.builder.setRunOutputActionState(runId, outputId, "open-blocked")
            entry.holder.applyHostSnapshot(entry.builder.build())
            return false
        }
        // An admitted retry must not keep a stale refusal caption.
        if (entry.builder.cachedRunOutputCard(runId, outputId)?.actionStateRaw
                == "open-blocked") {
            entry.builder.setRunOutputActionState(runId, outputId, null)
            entry.holder.applyHostSnapshot(entry.builder.build())
        }
        office.openRunOutput(
            RunOutputOfficeSnapshotStager.Owner(conversationId, runId, outputId, epoch, generation),
            ownerCurrent,
        )
        return true
    }

    override fun cancelRunOutputSave(
        session: ConversationSessionToken,
        runId: String,
        outputId: String,
    ): Boolean {
        val entry = holders[session.conversationId] ?: return false
        if (entry.holder.session != session) return false
        return host.runOutputs?.cancelActiveSave("user cancelled", runId, outputId) == true
    }

    override fun refreshRunOutputs(
        session: ConversationSessionToken,
        runId: String,
    ): Boolean {
        val entry = holders[session.conversationId] ?: return false
        if (entry.holder.session != session || entry.builder.isTemporary) return false
        if (host.runOutputs == null) return false
        refreshRunOutputCards(entry, session.conversationId, session.sessionEpoch, listOf(runId))
        return true
    }

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

/**
 * The exact-identity payload of a same-id committed Keep (see
 * [ConversationHostController.keptPromotion]). The shell consumes it to
 * persist the durable saved selection ONLY while the origin surface is
 * still current; anything else is dropped (never routed).
 */
data class KeptPromotion(
    val originRef: TemporarySessionRef,
    val durableConversationId: String,
)

/**
 * The exact-identity payload of a privacy-cleared durable conversation (see
 * [ConversationHostController.privacyClearedConversation]). [entryEpoch] is
 * the holder ENTRY's globally-unique session epoch (never the UI session
 * epoch, which restarts at 0 for every fresh holder); [holder] is the exact
 * released instance so the shell can prove visible ownership by identity
 * (a re-created same-id holder is a different instance and is never
 * invalidated by a stale signal). [rootEpoch] is the ACTUAL native epoch
 * the authoritative `notFound` was verified under.
 */
data class PrivacyClearedConversationSignal(
    val conversationId: String,
    val entryEpoch: Long,
    val rootEpoch: Long,
    val holder: com.floe.android.feature.conversation.ConversationFlowHolder,
)

/** Holder + projection bookkeeping for one conversation surface. */
/**
 * The exact closed-run identity a COMMITTED-ROW settlement page must still
 * own at admission time: the same run is selected and its trusted local
 * stream incarnation is unchanged. A page received for any other state is
 * dropped before it can touch rows, the earlier cursor or the published
 * state.
 */
internal data class CommittedPageFence(
    val runID: String,
    val streamGeneration: Long,
)

class ConversationFlowHolderEntry internal constructor(
    val holder: com.floe.android.feature.conversation.ConversationFlowHolder,
    val sessionEpoch: Long,
    val isTemporary: Boolean,
    val incarnationId: String?,
    val builder: ThreadProjectionBuilder,
) {
    /**
     * Monotonic identity of LATEST-WINDOW (`before == null`) message-page
     * reads issued for this surface, and the newest one actually applied.
     * A response may mutate the builder ONLY when it still owns this
     * entry/session AND it is the newest latest-window read issued for it;
     * an older request that completes late (for example the initial
     * activate read that captured the pre-launch empty page and returns
     * after the launch/terminal page already settled) is dropped WHOLE —
     * no rows, no cursor, no content-handle fetch. Earlier-history
     * (`before != null`) pages keep their own append semantics.
     */
    private var latestPageReadSeq: Long = 0L
    private var latestPageAppliedSeq: Long = 0L
    private val pageAdmissionLock = Any()

    fun nextLatestPageReadSeq(): Long = synchronized(pageAdmissionLock) {
        latestPageReadSeq += 1
        latestPageReadSeq
    }

    /**
     * Runs [apply] ONLY when [check] (owner/run/stream fences) holds and, for
     * a latest-window page, [issuedSeq] is newer than every latest page
     * already applied. The check, the freshness reservation and the
     * projection mutation happen under ONE lock, so an older request that
     * completes late can never publish before/after a newer page
     * out of order.
     */
    fun withAdmittedMessagePage(
        latest: Boolean,
        issuedSeq: Long,
        check: () -> Boolean,
        apply: () -> Unit,
    ): Boolean = synchronized(pageAdmissionLock) {
        if (!check()) return false
        if (latest) {
            if (issuedSeq <= latestPageAppliedSeq) return false
            latestPageAppliedSeq = issuedSeq
        }
        apply()
        true
    }

    /**
     * Monotonic identity of the LATEST explicit human permission gesture on
     * this holder. A gesture's settlement may mutate the shared projection
     * ONLY while it is still the latest intent: a newer tap supersedes
     * older queued and in-flight work, so a stale FullAccess decision can
     * never adopt or invalidate another gesture's CAS state, a replaced
     * run, or a retired/navigated surface.
     */
    private val policyGestureLock = Any()
    private var policyGestureSeq = 0L

    fun nextPolicyGestureIntent(): Long = synchronized(policyGestureLock) {
        policyGestureSeq += 1
        policyGestureSeq
    }

    /**
     * Atomically admits ONE settlement-time projection mutation: [apply]
     * runs ONLY while [intentSeq] is still the latest gesture intent AND
     * [check] (the ownership/session/run fences) holds — the intent test,
     * the fence re-check and the mutation happen under ONE monitor, in the
     * local `withAdmittedMessagePage` pattern. A separate locked boolean
     * read cannot promise that: RuntimeHost settles operations on
     * ioDispatcher while a human tap can bump the intent sequence exactly
     * between the read and the mutation. Host I/O and caller callbacks
     * stay OUTSIDE this monitor (no holder/state callback re-enters it).
     */
    fun withLatestPolicyGestureIntent(
        intentSeq: Long,
        check: () -> Boolean,
        apply: () -> Unit,
    ): Boolean = synchronized(policyGestureLock) {
        if (policyGestureSeq != intentSeq) return false
        if (!check()) return false
        apply()
        true
    }
}

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

/**
 * Committed-row settlement budget per terminal boundary. The first read is
 * immediate; the remaining attempts back off linearly (120/240/360 ms) so a
 * page that raced the native commit (or a transient read failure) still
 * settles on the SAME screen. Finite by design — no polling loop, and an
 * unsettled boundary is left unmarked so a later explicit read can settle it.
 */
private const val COMMITTED_ROW_SETTLEMENT_ATTEMPTS = 4
private const val COMMITTED_ROW_SETTLEMENT_BASE_MILLIS = 120L

// ---------------------------------------------------------------------------
// C09 queue-settle observer vocabulary (contract §6 P1–P4, MAIN_ADDENDUM A–F;
// fact kind FIXED to the existing `notice` vocabulary by Main's actual
// native regression 2026-10-25 — the queueSettled fact is a NOTICE frame,
// NEVER a trailing stateless `status`, which broke the original durable
// last-status terminal truth in the unchanged RunControl suite).

/** The stateless invalidation word. MUST stay byte-equal to the native
 *  `FacadeRunDomain.queueSettledReason`. */
internal const val QUEUE_SETTLE_REASON = "queueSettled"

/** The ONLY frame kind the settle vocabulary uses (existing RunEventRecord
 *  non-fatal info kind; renders nothing on its own once the internal notice
 *  suppression lands — see the UI owner's ConversationTimelineRows scope). */
internal const val QUEUE_SETTLE_FRAME_KIND = "notice"

/** The queue watch's ONLY frame interest: a `notice` frame carrying the
 *  stateless `queueSettled` reason and deliberately NO `state` member (it
 *  is never a run-state transition; a frame with a `state` member is not
 *  this fact). Queue authority remains the authoritative pages. */
internal fun isQueueSettleFrame(frame: HostRunEventFrame): Boolean {
    if (frame.kind != QUEUE_SETTLE_FRAME_KIND) return false
    val payload = frame.payload ?: return false
    if (payload.containsKey("state")) return false
    val reason = (payload["reason"] as? JsonPrimitive)
        ?.takeIf { it.isString }?.contentOrNull
    return reason == QUEUE_SETTLE_REASON
}

/** Narrow lifecycle metadata decoded from the durable fact itself: `lane`
 *  classifies WHY the lane exited, `chain` says whether ANOTHER fact is
 *  guaranteed later. Absent/unknown decodes CONSERVATIVELY open (keep
 *  observing); absent lane reads as the ordinary consumed exit. */
internal data class QueueSettleFact(val lane: String, val chainOpen: Boolean)

internal fun decodeQueueSettleFact(frame: HostRunEventFrame): QueueSettleFact {
    val payload = frame.payload
    val lane = (payload?.get("lane") as? JsonPrimitive)
        ?.takeIf { it.isString }?.contentOrNull
    val chain = (payload?.get("chain") as? JsonPrimitive)
        ?.takeIf { it.isString }?.contentOrNull
    return QueueSettleFact(
        lane = lane ?: "consumed",
        chainOpen = chain != "closed",
    )
}

/** ONE identity-fenced watch per conversation (latest terminal arm wins).
 *  `handleRef` starts NULL: the map identity is installed BEFORE any IO
 *  (MAIN_ADDENDUM A), a fast callback's close decision removes only state,
 *  and the arm's post-open recheck disposes a late-created handle. */
internal class QueueSettleWatch(
    val conversationId: String,
    val anchorRunID: String,
    val streamGeneration: Long,
    val sessionEpoch: Long,
) {
    val handleRef = java.util.concurrent.atomic.AtomicReference<EventPumpHandle?>(null)

    /** Once-per-watch bounds keep degraded-resync and typed-failure reads
     *  finite (never a polling loop). */
    val resyncConsumed = java.util.concurrent.atomic.AtomicBoolean(false)
    val failureConsumed = java.util.concurrent.atomic.AtomicBoolean(false)

    /** The exact token THIS watch currently owns on the holder surface, if
     *  any — never another watch's or the generic error surface's. */
    @Volatile
    var failureToken: String? = null
}

/** One owned bounded read cohort. Completion is idempotent and observable
 * in gated tests; it never permits a stale owner to release its replacement. */
internal class QueueSettleReconcileRun(
    val entry: ConversationFlowHolderEntry,
    val conversationId: String,
    val sessionEpoch: Long,
    val watch: QueueSettleWatch?,
    val fact: QueueSettleFact?,
    val resync: Boolean,
    val failureToken: String?,
) {
    val completed = java.util.concurrent.atomic.AtomicBoolean(false)
    @Volatile var reply: ConversationWire.SessionReply? = null
}

internal class QueueSettleRerun(
    val blockedBy: QueueSettleReconcileRun,
    val entry: ConversationFlowHolderEntry,
    val sessionEpoch: Long,
    val watch: QueueSettleWatch?,
    val fact: QueueSettleFact?,
    val resync: Boolean,
)
