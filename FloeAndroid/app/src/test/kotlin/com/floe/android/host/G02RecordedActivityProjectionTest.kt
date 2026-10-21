// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.RunEventKindUi
import com.floe.android.feature.conversation.TimelineRowUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class G02RecordedActivityProjectionTest {
    @Test fun storedFailedToolResultReachesTheActualTimelineWithItsOutput() {
        val builder = ThreadProjectionBuilder("conversation")
        builder.selectedRunId = "run"
        // Literal producer shape from ConversationRunService appendEventReliably.
        listOf(
            "toolRequest" to """{"tool":"checklist.readPlan","id":"call-1","input":"{}","status":"pending"}""",
            "toolResult" to """{"tool":"checklist.readPlan","id":"call-1","status":"failed","summary":"Recorded failure: no plan","durationMs":"1250"}""",
        ).forEachIndexed { i, (kind, raw) ->
            builder.applyRunEvent(HostRunEventFrame("run", i + 1L, kind,
                Json.parseToJsonElement(raw).jsonObject, raw.toByteArray().size))
        }
        val group = builder.build().rows.filterIsInstance<TimelineRowUi.StepGroup>().single()
        val result = group.events.single { it.kind == RunEventKindUi.TOOL_RESULT }.tool!!
        assertEquals("call-1", result.callId)
        assertEquals("failed", result.statusRaw)
        assertEquals("Recorded failure: no plan", result.resultSummary)
        assertEquals(1.25, result.durationSeconds!!, 0.0)
        assertEquals("{}", group.events.first().tool!!.inputSummary)
    }

    @Test fun malformedResultDoesNotBecomeSuccessOrVerifiedArtifactAuthority() {
        assertNull(ConversationWire.decodeToolEvent("toolResult",
            Json.parseToJsonElement("""{"tool":"read","id":"c","summary":"not a status"}""").jsonObject))
        val event = Json.parseToJsonElement("""{"tool":"read","id":"c","status":"ok","summary":"actual record","artifactRefsJSON":"[{\"id\":\"asset\",\"mimeType\":\"text/html\",\"byteCount\":4,\"relativePath\":\"output/a.html\",\"sha256\":\"digest\"}]"}""").jsonObject
        val artifact = ConversationWire.decodeToolEvent("toolResult", event)!!.artifacts.single()
        assertFalse(artifact.hostVerified)
        assertNull(artifact.previewUri)
    }
}
