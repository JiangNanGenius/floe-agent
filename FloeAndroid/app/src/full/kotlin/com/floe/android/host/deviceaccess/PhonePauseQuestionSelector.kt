// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.feature.conversation.UserQuestionPromptUi
import com.floe.android.host.questions.UserQuestionWire
import kotlinx.serialization.json.*

/** Native questionID is request-qualified; localID is only the draft label.
 * Refuse unrelated/model-authored prompts even if their label looks similar.
 * This is deliberately not a general automatic question-answering helper. */
internal object PhonePauseQuestionSelector {
    fun select(value: JsonElement, pause: PhoneAutomationPause.Snapshot): List<UserQuestionPromptUi> {
        val root = value as? JsonObject ?: return emptyList()
        if ((root["schema"] as? JsonPrimitive)?.contentOrNull != "floe.question.v1") return emptyList()
        val requests = root["requests"] as? JsonArray ?: return emptyList()
        val result = ArrayList<UserQuestionPromptUi>()
        for (item in requests) {
            val raw = item as? JsonObject ?: continue
            fun text(key: String) = (raw[key] as? JsonPrimitive)?.contentOrNull
            val callID = text("toolCallID") ?: continue
            if (callID !in pause.toolCallIDs) continue
            val decoded = UserQuestionWire.decodeSnapshot(raw) ?: continue
            if (decoded.isEphemeral || !decoded.conversationId.equals(pause.owner.taskID.toString(), true) ||
                !decoded.runId.equals(pause.owner.runID.toString(), true)) continue
            val questions = raw["questions"] as? JsonArray ?: continue
            for (question in questions) {
                val q = question as? JsonObject ?: continue
                if ((q["localID"] as? JsonPrimitive)?.contentOrNull != "phone-control-paused-${pause.id}") continue
                val actualID = (q["questionID"] as? JsonPrimitive)?.contentOrNull ?: continue
                val prompt = decoded.questions.singleOrNull { it.questionId == actualID && it.isPending } ?: continue
                val chinese = prompt.text == "手机操作已暂停。允许这个任务继续吗？"
                if (!chinese && prompt.text != "Phone control is paused. Allow this task to continue?") continue
                val labels = if (chinese) listOf("继续", "保留我的控制权") else listOf("Continue", "Keep control")
                if (prompt.allowsFreeText || prompt.options.map { it.id } != listOf("allow", "keep-control") ||
                    prompt.options.map { it.label } != labels ||
                    prompt.options.any { it.detail != null } || !prompt.waitPolicy.blocksWork) continue
                result += prompt
            }
        }
        return result
    }
}
