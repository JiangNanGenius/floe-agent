// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.FloeFoundation
import com.floe.android.HomeDraftTransfer
import com.floe.android.design.ComposerAvailability
import com.floe.android.design.SidebarSelection
import com.floe.android.feature.conversation.AgentExecutionModeUi
import com.floe.android.feature.conversation.ComposerDraftSeedUi
import com.floe.android.feature.conversation.ConversationFlowResult
import com.floe.android.feature.conversation.ConversationFlowHolder
import com.floe.android.feature.conversation.ModelOptionUi
import com.floe.android.feature.conversation.TemporarySessionRef
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * New-task launchpad host state: real availability, model/mode selection
 * and the send pipeline (ordinary conversation create + run launch, or
 * temporary session start + run launch). No simulated success: every step
 * is a canonical operation whose failure is surfaced on the surface.
 *
 * Model truth: the SAME real conversation F1 projection the thread composer
 * uses (`config.models.list` × providers × persisted default). There is no
 * parallel cache, no always-configured flag and no reliance on the obsolete
 * settings `selectedModelID` field — the launchpad sees exactly the model
 * the first send will use, reactively, including cold start and provider
 * changes.
 *
 * Concurrency truth (Home temporary entry): the native `temp.start`
 * acknowledgement executes on the IO dispatcher while an actual navigation/
 * New Task executes on the UI thread. Every Home-owned transition —
 * request begin, native admission, invalidation, Home draft transfer and
 * publication of the send's owned route — therefore runs under ONE narrow
 * [stateLock] reducer. No coroutine suspension, native command or network
 * wait happens while the lock is held, and no separate atomic field is the
 * sole authority for an admission/publication decision.
 */
/**
 * Service-owned identity of ONE Home surface/request generation.
 *
 * `homeGeneration` changes ONLY on an ACTUAL navigation/New Task away from
 * the Home (rotation/view reconstruction/background/lock preserve it).
 * `requestGeneration` advances for each admitted Home send. A late native
 * temp.start callback can be checked against this exact token, so text
 * equality alone can never authorize a route steal or a draft clear.
 */
data class HomeSendToken(
    val homeGeneration: Long,
    val requestGeneration: Long,
)

/**
 * One-shot ownership claim for ONE host navigation request.
 *
 * The shell obtains the claim BEFORE it may suspend on a temporary fence and
 * re-commits it AFTER the await. Only a claim that is still the exact owned
 * Home navigation at the final commit may move the route. [Unowned] is every
 * other host/user navigation (New Task, created conversation, Keep→history,
 * TaskCenter reopen); those always commit — an id is never globally denied.
 */
sealed interface HomeNavigationClaim {
    data object Unowned : HomeNavigationClaim

    class Owned internal constructor(
        internal val navigationID: Long,
        internal val token: HomeSendToken,
        val target: SidebarSelection,
    ) : HomeNavigationClaim
}

class HomeLaunchpadHost internal constructor(
    private val host: RuntimeHost,
) {
    /** The exact state owned by one temporary send (guarded by stateLock). */
    private class PendingHomeSend(
        val token: HomeSendToken,
        val text: String,
    ) {
        var admittedRef: TemporarySessionRef? = null

        /** True once the draft handoff + owned route publication committed. */
        var published: Boolean = false
    }

    /** The published-but-not-yet-applied route of one admitted Home send. */
    private class OwnedNavigation(
        val navigationID: Long,
        val token: HomeSendToken,
        val target: SidebarSelection,
    )

    /**
     * THE narrow linearization point for Home request ownership. Guarded
     * state is mutated only in short `synchronized` blocks; callbacks, holder
     * construction, native commands and suspension always happen outside it.
     */
    private val stateLock = Any()

    /** Guarded by [stateLock]. */
    private var homeGenerationValue = 0L
    private var requestGeneration = 0L
    private var sendingValue = false
    private var pendingSend: PendingHomeSend? = null
    private var ownedNavigation: OwnedNavigation? = null
    private var nextNavigationID = 0L

    private val availabilityState = MutableStateFlow(
        ComposerAvailability(
            providerConfigured = false,
            voiceAvailable = false,
            temporaryChatAvailable = false,
        ),
    )
    val availability: StateFlow<ComposerAvailability> = availabilityState

    /** Selected model display label; null ⇒ "Set up a model" chip. */
    private val modelLabelState = MutableStateFlow<String?>(null)
    val modelLabel: StateFlow<String?> = modelLabelState

    private val selectedModelIdState = MutableStateFlow<String?>(null)
    val selectedModelId: StateFlow<String?> = selectedModelIdState

    /** The real composer model options (usable rows from the F1 projection). */
    private val modelOptionsState = MutableStateFlow<List<ModelOptionUi>>(emptyList())
    val modelOptions: StateFlow<List<ModelOptionUi>> = modelOptionsState

    private val sendingState = MutableStateFlow(false)
    val sending: StateFlow<Boolean> = sendingState

    /** Service-owned Home identity; preserved across rotation/reconstruction. */
    private val homeGenerationState = MutableStateFlow(0L)
    val homeGeneration: StateFlow<Long> = homeGenerationState.asStateFlow()

    /**
     * Deterministic IO/Main interleaving point for the JVM ownership
     * regression: invoked AFTER the native admission is linearized and the
     * holder exists, immediately BEFORE the atomic draft transfer + owned
     * route publication. Production never sets it (null).
     */
    internal var admissionPublishBarrier: (() -> Unit)? = null

    fun currentHomeGeneration(): Long = synchronized(stateLock) { homeGenerationValue }

    /**
     * True while [token] is still the current Home surface AND the current
     * request. Used by the launchpad's admitted callback/draft handoff.
     */
    fun isCurrentHome(token: HomeSendToken): Boolean =
        synchronized(stateLock) { isCurrentLocked(token) }

    private fun isCurrentLocked(token: HomeSendToken): Boolean =
        homeGenerationValue == token.homeGeneration &&
            requestGeneration == token.requestGeneration

    /**
     * True while the request itself was not invalidated/superseded. This is
     * the ONLY authority for an already-admitted launch: applying the send's
     * own route retires the Home surface but must not abort its launch.
     */
    private fun isCurrentRequestLocked(token: HomeSendToken): Boolean =
        requestGeneration == token.requestGeneration

    /**
     * Invalidate EVERY pending Home send for an ACTUAL navigation/New Task.
     * An already-admitted temporary session created by that send is fenced
     * through the EXISTING `temp.end` lifecycle; the late callback can then
     * only fence/return, never navigate, launch or clear a draft. A canceled
     * PRE-admission temporary attempt consumes its own exact private draft so
     * it can never seed the next ordinary Home. Rotation/view reconstruction/
     * background never call this.
     */
    fun invalidatePendingStart(reason: String) {
        var retireRef: TemporarySessionRef? = null
        synchronized(stateLock) {
            val pending = pendingSend
            pendingSend = null
            val owned = ownedNavigation
            ownedNavigation = null
            if (pending != null) {
                if (!pending.published) {
                    // The draft was NEVER handed off: the prompt belonged to
                    // the canceled temporary attempt, so consume its EXACT
                    // text — a newer Home edit, or the same text re-entered
                    // by a later owner, survives. A start that FAILS in the
                    // same owner never reaches this path and stays
                    // recoverable.
                    HomeDraftTransfer.consumeTransferred(
                        FloeFoundation.draftStore,
                        pending.text,
                        isOriginCurrent = true,
                    )
                }
                // A published-but-not-yet-applied route keeps its admitted
                // native ref here, so canceling during that short window
                // retires the exact session instead of orphaning it.
                retireRef = pending.admittedRef
            }
            if (owned != null &&
                host.conversations.navigationRequest.value == owned.target
            ) {
                // Withdraw an intent that was published but not yet applied.
                host.conversations.navigationRequest.value = null
            }
            requestGeneration += 1
            homeGenerationValue += 1
            homeGenerationState.value = homeGenerationValue
            sendingValue = false
            sendingState.value = false
            // `reason` documents the caller contract (navigation/New Task).
        }
        retireRef?.let { ref ->
            // Exact by-id native temp.end + owned drain; never a fabricated
            // acknowledgement and never a replacement session under another id.
            host.conversations.retireLateTemporarySession(ref)
            host.conversations.releaseHolder(ref.conversationId)
        }
    }

    /**
     * Sidebar/Back route callback for a user or host navigation that is NOT
     * the send's own applied owned route. The send's own route is committed
     * through [applyHostNavigation] and keeps its launch alive.
     */
    fun onNavigation(target: SidebarSelection) {
        val isOwnCurrentRoute = synchronized(stateLock) {
            val owned = ownedNavigation
            owned != null && owned.target == target &&
                isCurrentRequestLocked(owned.token)
        }
        if (isOwnCurrentRoute) return
        invalidatePendingStart("navigation")
    }

    /**
     * Claim the ownership of ONE host navigation request.
     *
     * Returns [HomeNavigationClaim.Owned] only for the exact published route
     * of the current Home request; [HomeNavigationClaim.Unowned] for every
     * other navigation target. A stale owned intent that can no longer commit
     * returns null so it can never move the route.
     */
    fun claimNavigation(target: SidebarSelection): HomeNavigationClaim? =
        synchronized(stateLock) {
            val owned = ownedNavigation ?: return@synchronized HomeNavigationClaim.Unowned
            if (owned.target != target) return@synchronized HomeNavigationClaim.Unowned
            if (!isCurrentRequestLocked(owned.token)) {
                ownedNavigation = null
                return@synchronized null
            }
            HomeNavigationClaim.Owned(owned.navigationID, owned.token, owned.target)
        }

    /**
     * Apply one host navigation request. The claim is obtained before any
     * suspension ([waitForAdmission] is the existing temporary fence flow)
     * and re-validated at the FINAL route commit, so a request invalidated
     * during the wait cannot move the route. Unowned navigations always
     * commit; an owned navigation is consumed exactly once.
     */
    suspend fun applyHostNavigation(
        target: SidebarSelection,
        waitForAdmission: suspend () -> Boolean,
        commit: (SidebarSelection) -> Unit,
    ): Boolean {
        val claim = claimNavigation(target) ?: return false
        if (!waitForAdmission()) {
            if (claim is HomeNavigationClaim.Owned) {
                // The route stays where it is; the exact Home request (and
                // its admitted native ref) is retired through the existing
                // lifecycle rather than leaking an unpublishable intent.
                invalidatePendingStart("navigation_not_admitted")
            }
            return false
        }
        if (!commitNavigation(claim)) return false
        commit(target)
        if (claim is HomeNavigationClaim.Unowned) {
            // Any OTHER host route leaves the Home: pending Home sends are
            // canceled exactly like an ordinary sidebar transition.
            invalidatePendingStart("navigation")
        }
        return true
    }

    /** FINAL commit check + one-shot consumption (no suspension here). */
    private fun commitNavigation(claim: HomeNavigationClaim): Boolean =
        synchronized(stateLock) {
            when (claim) {
                HomeNavigationClaim.Unowned -> true
                is HomeNavigationClaim.Owned -> {
                    val owned = ownedNavigation
                    if (owned == null ||
                        owned.navigationID != claim.navigationID ||
                        !isCurrentRequestLocked(owned.token)
                    ) {
                        false
                    } else {
                        ownedNavigation = null
                        pendingSend = null
                        // The originating Home surface is leaving: a stale
                        // page/queued click from it can never mint another
                        // request. Its already-admitted launch stays valid
                        // because requestGeneration does not move here.
                        if (homeGenerationValue == owned.token.homeGeneration) {
                            homeGenerationValue += 1
                            homeGenerationState.value = homeGenerationValue
                        }
                        true
                    }
                }
            }
        }

    private var projectionJob: Job? = null

    internal fun start() {
        refresh()
        if (projectionJob == null) {
            projectionJob = host.scope.launch(host.ioDispatcher) {
                host.conversations.modelProjectionFlow.collect { projection ->
                    applyProjection(projection.models)
                }
            }
        }
    }

    internal fun stop() {
        projectionJob?.cancel()
        projectionJob = null
    }

    /** Re-reads the real model projection (called on surfacing/refresh). */
    fun refresh() {
        if (host.readiness.value.providerConfigurationAdmitted) {
            host.conversations.refreshModels()
        } else {
            // Keep the honest pre-readiness state visible instead of a stale
            // or fabricated one.
            applyProjection(host.conversations.modelProjectionFlow.value.models)
        }
    }

    private fun applyProjection(models: List<ModelOptionUi>) {
        modelOptionsState.value = models
        val usable = models.filter { it.isUsable }
        val current = selectedModelIdState.value
        // The user's explicit pick survives projection refreshes; a pick that
        // is no longer usable falls back to the durable default (first row).
        val effective = usable.firstOrNull { it.modelId.equals(current, ignoreCase = true) }
            ?: usable.firstOrNull()
        if (effective?.modelId != current) {
            selectedModelIdState.value = effective?.modelId
        }
        modelLabelState.value = effective?.displayName
        availabilityState.value = ComposerAvailability(
            providerConfigured = usable.isNotEmpty(),
            voiceAvailable = false,
            temporaryChatAvailable = host.readiness.value.temporaryDomainAdmitted &&
                usable.isNotEmpty(),
        )
    }

    /**
     * Launchpad model picker selection: becomes the durable default (full
     * preferences CAS through the conversation host) and the reactive label.
     */
    fun selectModel(modelId: String): Boolean {
        val usable = modelOptionsState.value.firstOrNull {
            it.modelId == modelId && it.isUsable
        } ?: return false
        selectedModelIdState.value = usable.modelId
        modelLabelState.value = usable.displayName
        return host.conversations.selectDefaultModel(usable.modelId)
    }

    /**
     * Send from the launchpad. [temporary] starts a real temporary session;
     * otherwise a real ordinary conversation is created first. The launch
     * fires exactly once, only after the created holder actually holds a
     * usable model (the projection load is async); a typed rejection hands
     * the text back through [onFailure] and never auto-retries.
     *
     * [onAdmitted] fires exactly once AFTER the real temporary session was
     * committed (`temp.start` accepted), the exact Home draft was handed off
     * and the send's owned route was published — and BEFORE the shell applies
     * that route. `draftTransferred` is true only when THIS request consumed
     * the exact HOME_DRAFT text. It is the ONLY point where the originating
     * Home may clear its visible field: a failed/never-admitted start leaves
     * the field and HOME_DRAFT intact, and an empty temporary draft is a REAL
     * empty temporary surface (no silent return and no synthetic run launch).
     */
    fun send(
        text: String,
        mode: String,
        temporary: Boolean,
        originHomeGeneration: Long? = null,
        onAdmitted: ((HomeSendToken, draftTransferred: Boolean) -> Unit)? = null,
        onFailure: (String) -> Unit,
    ) {
        // An ordinary send still requires text (unchanged). A temporary
        // header is a real entry point even with an empty draft: it opens
        // the RAM-only session surface without launching a run.
        if (!temporary && text.isBlank()) return
        if (temporary) {
            val origin = originHomeGeneration ?: currentHomeGeneration()
            val token = beginTemporarySend(origin, text)
            if (token == null) {
                // Stale originating page, an already-pending/owned Home
                // request or a second tap: never a duplicate native start.
                return
            }
            sendingState.value = true
            val modelID = selectedModelIdState.value
            val started = host.conversations.startTemporarySession(
                draft = text,
                preferredModelID = modelID,
                onStarted = { ref ->
                    admitTemporaryStart(
                        token = token,
                        ref = ref,
                        text = text,
                        mode = mode,
                        modelID = modelID,
                        onAdmitted = onAdmitted,
                        onFailure = onFailure,
                    )
                },
                onFailure = { reason ->
                    settleTemporaryFailure(token, reason, onFailure)
                },
            )
            if (!started) {
                settleTemporaryFailure(token, "temporary_unavailable", onFailure)
            }
            return
        }
        val beganOrdinary = beginOrdinarySend()
        if (!beganOrdinary) return
        sendingState.value = true
        val modelID = selectedModelIdState.value
        val title = text.lines().firstOrNull()?.take(80) ?: text.take(80)
        val created = host.conversations.createConversationForLaunch(
            title = title,
            onCreated = { conversationID ->
                val holder = host.conversations.holderFor(
                    conversationID,
                    isTemporary = false,
                    incarnationId = null,
                    initialDraft = ComposerDraftSeedUi(
                        text = text,
                        attachments = emptyList(),
                        caretIndex = null,
                        selectionLength = null,
                    ),
                )
                holder.selectAgentMode(parseMode(mode))
                host.conversations.navigationRequest.value =
                    SidebarSelection.Conversation(conversationID)
                launchWhenModelReady(holder, modelID) { reason ->
                    settleOrdinarySend(reason, onFailure)
                }
            },
            onFailure = { reason ->
                settleOrdinarySend(reason, onFailure)
            },
        )
        if (!created) {
            settleOrdinarySend("conversation_unavailable", onFailure)
        }
    }

    private fun beginTemporarySend(originHomeGeneration: Long, text: String): HomeSendToken? =
        synchronized(stateLock) {
            if (originHomeGeneration != homeGenerationValue) return@synchronized null
            if (sendingValue || pendingSend != null || ownedNavigation != null) {
                return@synchronized null
            }
            sendingValue = true
            val token = HomeSendToken(
                homeGeneration = homeGenerationValue,
                requestGeneration = requestGeneration + 1,
            )
            requestGeneration = token.requestGeneration
            pendingSend = PendingHomeSend(token, text)
            token
        }

    private fun beginOrdinarySend(): Boolean = synchronized(stateLock) {
        if (sendingValue || pendingSend != null || ownedNavigation != null) {
            false
        } else {
            sendingValue = true
            true
        }
    }

    /** Pre-admission failure for THIS exact request only. */
    private fun settleTemporaryFailure(
        token: HomeSendToken,
        reason: String,
        onFailure: (String) -> Unit,
    ) {
        val settled = synchronized(stateLock) {
            if (!isCurrentLocked(token) || pendingSend?.token != token) {
                false
            } else {
                pendingSend = null
                sendingValue = false
                true
            }
        }
        if (!settled) return
        sendingState.value = false
        onFailure(reason)
    }

    private fun settleOrdinarySend(reason: String?, onFailure: (String) -> Unit) {
        synchronized(stateLock) { sendingValue = false }
        sendingState.value = false
        if (reason != null) onFailure(reason)
    }

    /**
     * One native `temp.start` acknowledgement. Admission, draft handoff and
     * route publication are linearized against invalidation:
     *  1. the exact ref is recorded for THIS request (or the request is
     *     already fenced and the exact native ref is retired);
     *  2. the holder projection is built WITHOUT the lock;
     *  3. the Home draft is consumed and the owned navigation is published in
     *     ONE critical section that also re-checks the exact request. A
     *     request invalidated during (2) publishes nothing.
     */
    private fun admitTemporaryStart(
        token: HomeSendToken,
        ref: TemporarySessionRef,
        text: String,
        mode: String,
        modelID: String?,
        onAdmitted: ((HomeSendToken, Boolean) -> Unit)?,
        onFailure: (String) -> Unit,
    ) {
        val admitted = synchronized(stateLock) {
            val pending = pendingSend
            if (pending == null || pending.token != token || !isCurrentLocked(token)) {
                false
            } else {
                pending.admittedRef = ref
                true
            }
        }
        if (!admitted) {
            // The request was fenced while the native start was in flight.
            // Retire the exact native ref through the existing temp.end
            // lifecycle; never navigate, launch or touch a draft.
            host.conversations.retireLateTemporarySession(ref)
            host.conversations.releaseHolder(ref.conversationId)
            return
        }
        val holder = host.conversations.holderFor(
            ref.conversationId,
            isTemporary = true,
            incarnationId = ref.incarnationId,
            initialDraft = text.takeIf { it.isNotBlank() }?.let {
                ComposerDraftSeedUi(
                    text = it,
                    attachments = emptyList(),
                    caretIndex = null,
                    selectionLength = null,
                )
            },
            temporaryNativeRootEpoch = ref.nativeRootEpoch,
        )
        holder.selectAgentMode(parseMode(mode))

        admissionPublishBarrier?.invoke()

        var draftTransferred = false
        val published = synchronized(stateLock) {
            val pending = pendingSend
            if (pending == null || pending.token != token || !isCurrentLocked(token)) {
                false
            } else {
                draftTransferred = HomeDraftTransfer.consumeTransferred(
                    FloeFoundation.draftStore,
                    pending.text,
                    isOriginCurrent = true,
                )
                // The record stays pending until the shell's one-shot commit
                // (or an invalidation) so a cancel in that window can retire
                // the exact admitted native session.
                pending.published = true
                val target = SidebarSelection.Conversation(ref.conversationId)
                ownedNavigation = OwnedNavigation(
                    navigationID = nextNavigationID + 1,
                    token = token,
                    target = target,
                )
                nextNavigationID += 1
                // Publication is the SAME critical section as the final
                // ownership proof: an invalidation either happened before
                // (nothing published) or happens after (the shell's final
                // commit re-check refuses the stale intent).
                host.conversations.navigationRequest.value = target
                if (text.isBlank()) {
                    // Empty temporary surface only: no send was admitted, so
                    // there is nothing to launch or await.
                    sendingValue = false
                    sendingState.value = false
                }
                true
            }
        }
        if (!published) {
            // Invalidation already retired the exact admitted ref (it saw
            // admittedRef under the same lock). Only the unused holder is
            // released; nothing was published, launched or cleared.
            host.conversations.releaseHolder(ref.conversationId)
            return
        }
        onAdmitted?.invoke(token, draftTransferred)
        if (text.isNotBlank()) {
            launchWhenModelReady(holder, modelID, token) { reason ->
                settleAdmittedLaunch(token, reason, onFailure)
            }
        }
    }

    /** Settles an already-admitted launch for THIS exact request. */
    private fun settleAdmittedLaunch(
        token: HomeSendToken,
        reason: String?,
        onFailure: (String) -> Unit,
    ) {
        val settled = synchronized(stateLock) {
            if (!isCurrentRequestLocked(token)) {
                false
            } else {
                sendingValue = false
                true
            }
        }
        if (!settled) return
        sendingState.value = false
        if (reason != null) onFailure(reason)
    }

    private fun parseMode(mode: String): AgentExecutionModeUi = when (mode) {
        "chat" -> AgentExecutionModeUi.CHAT
        "plan" -> AgentExecutionModeUi.PLAN
        "goal" -> AgentExecutionModeUi.GOAL
        else -> AgentExecutionModeUi.AGENT
    }

    private fun isCurrentRequest(token: HomeSendToken): Boolean =
        synchronized(stateLock) { isCurrentRequestLocked(token) }

    /**
     * Exactly-one launch after the REAL model snapshot exists in the holder
     * (bounded wait — the projection round-trips through the native read;
     * no fixed sleep, no fake ack). The chosen canonical model is preserved;
     * a typed rejection surfaces through [onSettled] with the draft intact.
     * Applying the send's OWN route never aborts this launch; only a real
     * invalidation/new request does.
     */
    private fun launchWhenModelReady(
        holder: ConversationFlowHolder,
        chosenModelID: String?,
        token: HomeSendToken? = null,
        onSettled: (reason: String?) -> Unit,
    ) {
        host.scope.launch(host.ioDispatcher) {
            if (token != null && !isCurrentRequest(token)) {
                return@launch
            }
            // A freshly created holder has no snapshot until the real thread
            // load lands; drive it (the UI's own loadThread is idempotent).
            if (holder.snapshot.value == null) {
                host.conversations.loadThread(holder.session)
            }
            val deadline = System.nanoTime() + MODEL_PROOF_TIMEOUT_NANOS
            while (System.nanoTime() < deadline &&
                holder.snapshot.value?.models?.any { it.isUsable } != true
            ) {
                if (token != null && !isCurrentRequest(token)) {
                    return@launch
                }
                delay(20)
            }
            if (token != null && !isCurrentRequest(token)) {
                return@launch
            }
            if (holder.snapshot.value?.models?.any { it.isUsable } != true) {
                onSettled("model_unavailable")
                return@launch
            }
            if (chosenModelID != null) {
                holder.selectModel(chosenModelID)
            }
            if (token != null && !isCurrentRequest(token)) {
                return@launch
            }
            when (
                val result = holder.send(
                    onLaunchOutcome = { admitted, reason ->
                        onSettled(if (admitted) null else reason)
                    },
                )
            ) {
                is ConversationFlowResult.Rejected -> onSettled(result.reason.name.lowercase())
                else -> Unit // admitted: onSettled fires from the real outcome
            }
        }
    }

    private companion object {
        /** Bounded wait for the real model projection (5 s ceiling). */
        const val MODEL_PROOF_TIMEOUT_NANOS = 5_000_000_000L
    }
}
