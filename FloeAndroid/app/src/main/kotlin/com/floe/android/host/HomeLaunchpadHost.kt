// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.design.ComposerAvailability
import com.floe.android.feature.conversation.AgentExecutionModeUi
import com.floe.android.feature.conversation.ComposerDraftSeedUi
import com.floe.android.feature.conversation.ConversationFlowResult
import com.floe.android.feature.conversation.ConversationFlowHolder
import com.floe.android.feature.conversation.ModelOptionUi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
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
 */
class HomeLaunchpadHost internal constructor(
    private val host: RuntimeHost,
) {
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
     */
    fun send(
        text: String,
        mode: String,
        temporary: Boolean,
        onFailure: (String) -> Unit,
    ) {
        if (text.isBlank()) return
        if (sendingState.value) return
        sendingState.value = true
        val modelID = selectedModelIdState.value
        if (temporary) {
            val started = host.conversations.startTemporarySession(
                draft = text,
                preferredModelID = modelID,
                onStarted = { ref ->
                    val holder = host.conversations.holderFor(
                        ref.conversationId,
                        isTemporary = true,
                        incarnationId = ref.incarnationId,
                        initialDraft = ComposerDraftSeedUi(
                            text = text,
                            attachments = emptyList(),
                            caretIndex = null,
                            selectionLength = null,
                        ),
                    )
                    holder.selectAgentMode(parseMode(mode))
                    host.conversations.navigationRequest.value =
                        com.floe.android.design.SidebarSelection.Conversation(ref.conversationId)
                    launchWhenModelReady(holder, modelID) { reason ->
                        sendingState.value = false
                        if (reason != null) onFailure(reason)
                    }
                },
                onFailure = { reason ->
                    sendingState.value = false
                    onFailure(reason)
                },
            )
            if (!started) {
                sendingState.value = false
                onFailure("temporary_unavailable")
            }
            return
        }
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
                    com.floe.android.design.SidebarSelection.Conversation(conversationID)
                launchWhenModelReady(holder, modelID) { reason ->
                    sendingState.value = false
                    if (reason != null) onFailure(reason)
                }
            },
            onFailure = { reason ->
                sendingState.value = false
                onFailure(reason)
            },
        )
        if (!created) {
            sendingState.value = false
            onFailure("conversation_unavailable")
        }
    }

    private fun parseMode(mode: String): AgentExecutionModeUi = when (mode) {
        "chat" -> AgentExecutionModeUi.CHAT
        "plan" -> AgentExecutionModeUi.PLAN
        "goal" -> AgentExecutionModeUi.GOAL
        else -> AgentExecutionModeUi.AGENT
    }

    /**
     * Exactly-one launch after the REAL model snapshot exists in the holder
     * (bounded wait — the projection round-trips through the native read;
     * no fixed sleep, no fake ack). The chosen canonical model is preserved;
     * a typed rejection surfaces through [onSettled] with the draft intact.
     */
    private fun launchWhenModelReady(
        holder: ConversationFlowHolder,
        chosenModelID: String?,
        onSettled: (reason: String?) -> Unit,
    ) {
        host.scope.launch(host.ioDispatcher) {
            // A freshly created holder has no snapshot until the real thread
            // load lands; drive it (the UI's own loadThread is idempotent).
            if (holder.snapshot.value == null) {
                host.conversations.loadThread(holder.session)
            }
            val deadline = System.nanoTime() + MODEL_PROOF_TIMEOUT_NANOS
            while (System.nanoTime() < deadline &&
                holder.snapshot.value?.models?.any { it.isUsable } != true
            ) {
                delay(20)
            }
            if (holder.snapshot.value?.models?.any { it.isUsable } != true) {
                onSettled("model_unavailable")
                return@launch
            }
            if (chosenModelID != null) {
                holder.selectModel(chosenModelID)
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
