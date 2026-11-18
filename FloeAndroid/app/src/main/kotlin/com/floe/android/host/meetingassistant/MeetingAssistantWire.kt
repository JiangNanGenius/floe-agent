// SPDX-License-Identifier: MPL-2.0
//
// Pure wire/policy helpers for the meeting assistant.
//
// These functions never call a provider, a store or a task service. They make
// the exact frozen v3 payload shape, decide whether the assistant route is
// actually usable, and read ONLY a durable assistant message that belongs to
// the requested run. A missing value always stays honest absence.
package com.floe.android.host.meetingassistant

import com.floe.android.feature.conversation.MessageRoleUi
import com.floe.android.feature.conversation.MessageUi
import com.floe.android.feature.conversation.ModelOptionUi
import com.floe.android.host.meeting.MeetingDetail
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal object MeetingAssistantWire {
    /** The complete terminal vocabulary the run stream/snapshot may report. */
    private val TERMINAL_STATES = setOf(
        "completed", "failed", "checkpointed", "idle", "cancelled", "canceled",
    )

    /**
     * Resolves the entry state from the REAL model projection only.
     *
     * A provider surface that is not admitted, a model list that never loaded
     * and an empty usable list are three different facts. None of them is
     * presented as a working assistant.
     */
    fun resolveAvailability(
        runtimeReady: Boolean,
        providerAdmitted: Boolean,
        modelsLoaded: Boolean,
        models: List<ModelOptionUi>,
        preferredModelId: String?,
        storedModelId: String?,
    ): MeetingAssistantAvailability {
        if (!runtimeReady) {
            return MeetingAssistantAvailability.Unavailable(
                MeetingAssistantFailureCode.RUNTIME_UNAVAILABLE,
            )
        }
        if (!providerAdmitted) {
            return MeetingAssistantAvailability.Unavailable(
                MeetingAssistantFailureCode.PROVIDERS_NOT_READY,
            )
        }
        val usable = models.filter { it.isUsable }
        if (usable.isEmpty()) {
            return if (modelsLoaded) {
                MeetingAssistantAvailability.NotConfigured(
                    MeetingAssistantFailureCode.NO_TEXT_MODEL,
                )
            } else {
                MeetingAssistantAvailability.Checking
            }
        }
        val chosen = storedModelId
            ?.let { id -> usable.firstOrNull { it.modelId == id } }
            ?: preferredModelId
                ?.let { id -> usable.firstOrNull { it.modelId == id } }
            ?: usable.first()
        val options = usable.map { it.toMeetingAssistantModelOption() }
        return MeetingAssistantAvailability.Ready(
            modelId = chosen.modelId,
            modelLabel = options.first { it.modelId == chosen.modelId }.label,
            models = options,
        )
    }

    /**
     * The EXACT frozen `run.start`/`run.startTask` payload.
     *
     * `title` is present only for the create-intent `run.startTask`; the
     * existing-conversation `run.start` grammar has no `title` key. The empty
     * tool ceiling is the product CHAT ceiling: this assistant turn cannot
     * touch files, the shell, the network tools or another meeting.
     */
    fun runPayload(
        goal: String,
        providerId: String,
        modelId: String,
        title: String?,
    ): JsonObject = buildJsonObject {
        put("goal", goal)
        put("mode", "chat")
        put("providerID", providerId)
        put("modelID", modelId)
        put("stagedAttachments", JsonArray(emptyList()))
        put("toolCeiling", JsonArray(emptyList()))
        title?.let { put("title", it) }
    }

    fun isTerminalFrame(kind: String, payload: JsonObject?): Boolean {
        if (kind == "terminal") return true
        if (kind != "status") return false
        val state = (payload?.get("state") as? JsonPrimitive)
            ?.takeIf { it.isString }
            ?.content
        return state != null && state in TERMINAL_STATES
    }

    /**
     * The canonical durable assistant answer for ONE run. User rows, rows from
     * another run and blank rows are never candidates.
     */
    fun selectAnswer(rows: List<MessageUi>, runId: String): MessageUi? =
        rows.lastOrNull { row ->
            row.runId == runId &&
                row.role == MessageRoleUi.ASSISTANT &&
                row.text.isNotBlank()
        }

    fun classifyOutcome(
        durableState: String?,
        answer: String?,
    ): MeetingAssistantEntryStatus {
        val hasAnswer = !answer.isNullOrBlank()
        return when {
            hasAnswer && durableState == "completed" -> MeetingAssistantEntryStatus.ANSWERED
            hasAnswer -> MeetingAssistantEntryStatus.PARTIAL
            durableState == "failed" -> MeetingAssistantEntryStatus.FAILED
            durableState == "cancelled" || durableState == "canceled" ->
                MeetingAssistantEntryStatus.CANCELLED
            else -> MeetingAssistantEntryStatus.UNRESOLVED
        }
    }

    fun contextReady(detail: MeetingDetail): Boolean =
        detail.notes.isNotBlank() ||
            detail.transcription.segments.any { it.text.isNotBlank() }

    fun normalizeQuestion(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.toByteArray(Charsets.UTF_8).size >
            MeetingAssistantPromptBuilder.MAX_QUESTION_BYTES
        ) {
            return null
        }
        return trimmed
    }

    /** Bounded diagnostic text: no control characters, no raw provider body. */
    fun boundedDetail(raw: String?): String? {
        val cleaned = raw
            ?.map { if (it.isISOControl()) ' ' else it }
            ?.joinToString("")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return null
        return boundedUtf8(cleaned, 120)
    }

    fun failureForLaunch(code: String?, reason: String?): MeetingAssistantFailure {
        val normalized = code.orEmpty().lowercase()
        val mapped = when {
            normalized.contains("model") -> MeetingAssistantFailureCode.MODEL_UNAVAILABLE
            normalized.contains("provider") || normalized.contains("credential") ->
                MeetingAssistantFailureCode.PROVIDERS_NOT_READY
            normalized.contains("network") -> MeetingAssistantFailureCode.LAUNCH_FAILED
            else -> MeetingAssistantFailureCode.LAUNCH_REFUSED
        }
        return MeetingAssistantFailure(mapped, boundedDetail(reason ?: code))
    }
}
