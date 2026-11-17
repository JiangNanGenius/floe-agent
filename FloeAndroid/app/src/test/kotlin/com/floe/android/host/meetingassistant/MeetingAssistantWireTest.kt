// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingassistant

import com.floe.android.feature.conversation.MessageRoleUi
import com.floe.android.feature.conversation.MessageUi
import com.floe.android.feature.conversation.ModelOptionUi
import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingTranscriptSegment
import com.floe.android.host.meeting.MeetingTranscription
import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure availability/payload/answer policy for the meeting assistant.
 */
class MeetingAssistantWireTest {
    private val modelId = UUID.randomUUID().toString()
    private val providerId = UUID.randomUUID().toString()

    @Test
    fun `runtime and provider facts are separate unavailable states`() {
        assertEquals(
            MeetingAssistantAvailability.Unavailable(
                MeetingAssistantFailureCode.RUNTIME_UNAVAILABLE,
            ),
            availability(runtimeReady = false, providerAdmitted = false),
        )
        assertEquals(
            MeetingAssistantAvailability.Unavailable(
                MeetingAssistantFailureCode.PROVIDERS_NOT_READY,
            ),
            availability(runtimeReady = true, providerAdmitted = false),
        )
    }

    @Test
    fun `an empty unloaded projection is checking but a loaded empty one is not configured`() {
        assertEquals(
            MeetingAssistantAvailability.Checking,
            availability(modelsLoaded = false, models = emptyList()),
        )
        assertEquals(
            MeetingAssistantAvailability.NotConfigured(
                MeetingAssistantFailureCode.NO_TEXT_MODEL,
            ),
            availability(modelsLoaded = true, models = emptyList()),
        )
    }

    @Test
    fun `only usable models are offered and the stored choice wins`() {
        val usable = model(displayName = "Fast", usable = true)
        val other = model(displayName = "Other", usable = true)
        val disabled = model(displayName = "Disabled", usable = false)
        val result = availability(
            modelsLoaded = true,
            models = listOf(disabled, usable, other),
            preferredModelId = other.modelId,
            storedModelId = usable.modelId,
        ) as MeetingAssistantAvailability.Ready

        assertEquals(usable.modelId, result.modelId)
        assertEquals(listOf(usable.modelId, other.modelId), result.models.map { it.modelId })
        assertTrue(result.modelLabel.startsWith("Fast"))
    }

    @Test
    fun `the preferred role model is used when no explicit choice exists`() {
        val first = model(displayName = "First", usable = true)
        val preferred = model(displayName = "Preferred", usable = true)
        val result = availability(
            modelsLoaded = true,
            models = listOf(first, preferred),
            preferredModelId = preferred.modelId,
        ) as MeetingAssistantAvailability.Ready
        assertEquals(preferred.modelId, result.modelId)
    }

    @Test
    fun `create and existing run payloads have the exact frozen keys`() {
        val prompt = MeetingAssistantPrompt(
            goal = "evidence",
            notesRevision = 1L,
            transcriptRevision = 2L,
            transcriptSegmentCount = 3,
            notesIncluded = true,
            transcriptIncluded = true,
            notesTruncated = false,
            transcriptTruncated = false,
        )
        val create = MeetingAssistantWire.runPayload(
            goal = prompt.goal,
            providerId = providerId,
            modelId = modelId,
            title = "Meeting assistant · Sync",
        )
        val existing = MeetingAssistantWire.runPayload(
            goal = prompt.goal,
            providerId = providerId,
            modelId = modelId,
            title = null,
        )

        assertEquals("chat", create["mode"]?.jsonPrimitive?.content)
        assertEquals(providerId, create["providerID"]?.jsonPrimitive?.content)
        assertEquals(modelId, create["modelID"]?.jsonPrimitive?.content)
        assertEquals("Meeting assistant · Sync", create["title"]?.jsonPrimitive?.content)
        assertEquals(0, (create["stagedAttachments"] as JsonArray).size)
        assertEquals(0, (create["toolCeiling"] as JsonArray).size)
        assertNull(existing["title"])
        assertFalse(existing.containsKey("title"))
    }

    @Test
    fun `terminal frames use the durable terminal vocabulary`() {
        assertTrue(MeetingAssistantWire.isTerminalFrame("terminal", null))
        assertTrue(
            MeetingAssistantWire.isTerminalFrame(
                "status",
                kotlinx.serialization.json.buildJsonObject {
                    put("state", JsonPrimitive("completed"))
                },
            ),
        )
        assertTrue(
            MeetingAssistantWire.isTerminalFrame(
                "status",
                kotlinx.serialization.json.buildJsonObject {
                    put("state", JsonPrimitive("cancelled"))
                },
            ),
        )
        assertFalse(
            MeetingAssistantWire.isTerminalFrame(
                "status",
                kotlinx.serialization.json.buildJsonObject {
                    put("state", JsonPrimitive("running"))
                },
            ),
        )
        assertFalse(MeetingAssistantWire.isTerminalFrame("assistantText", null))
    }

    @Test
    fun `only the durable assistant row of this exact run is an answer`() {
        val runId = UUID.randomUUID().toString()
        val conversationId = UUID.randomUUID().toString()
        val wrongRun = message(conversationId, UUID.randomUUID().toString(), MessageRoleUi.ASSISTANT, "Other")
        val user = message(conversationId, runId, MessageRoleUi.USER, "Question")
        val first = message(conversationId, runId, MessageRoleUi.ASSISTANT, "Partial")
        val last = message(conversationId, runId, MessageRoleUi.ASSISTANT, "Final")
        val blank = message(conversationId, runId, MessageRoleUi.ASSISTANT, "   ")

        val picked = MeetingAssistantWire.selectAnswer(
            listOf(wrongRun, user, first, last, blank),
            runId,
        )
        assertNotNull(picked)
        assertEquals("Final", picked?.text)
        assertNull(
            MeetingAssistantWire.selectAnswer(listOf(wrongRun, user), runId),
        )
    }

    @Test
    fun `outcome classification never turns failure into success`() {
        assertEquals(
            MeetingAssistantEntryStatus.ANSWERED,
            MeetingAssistantWire.classifyOutcome("completed", "Answer"),
        )
        assertEquals(
            MeetingAssistantEntryStatus.PARTIAL,
            MeetingAssistantWire.classifyOutcome("checkpointed", "Partial answer"),
        )
        assertEquals(
            MeetingAssistantEntryStatus.FAILED,
            MeetingAssistantWire.classifyOutcome("failed", null),
        )
        assertEquals(
            MeetingAssistantEntryStatus.CANCELLED,
            MeetingAssistantWire.classifyOutcome("cancelled", null),
        )
        assertEquals(
            MeetingAssistantEntryStatus.UNRESOLVED,
            MeetingAssistantWire.classifyOutcome("completed", null),
        )
        assertEquals(
            MeetingAssistantEntryStatus.UNRESOLVED,
            MeetingAssistantWire.classifyOutcome(null, null),
        )
    }

    @Test
    fun `context readiness needs real notes or transcript text`() {
        assertFalse(MeetingAssistantWire.contextReady(detail(notes = "", segments = emptyList())))
        assertTrue(MeetingAssistantWire.contextReady(detail(notes = "Notes", segments = emptyList())))
        assertTrue(
            MeetingAssistantWire.contextReady(
                detail(
                    notes = "",
                    segments = listOf(segment("Transcript")),
                ),
            ),
        )
        assertFalse(
            MeetingAssistantWire.contextReady(
                detail(notes = "", segments = listOf(segment("   "))),
            ),
        )
    }

    @Test
    fun `question normalization keeps real text and refuses blanks or oversized input`() {
        assertEquals("What happened?", MeetingAssistantWire.normalizeQuestion("  What happened?  "))
        assertNull(MeetingAssistantWire.normalizeQuestion("   "))
        assertNull(
            MeetingAssistantWire.normalizeQuestion(
                "x".repeat(MeetingAssistantPromptBuilder.MAX_QUESTION_BYTES + 1),
            ),
        )
    }

    @Test
    fun `diagnostic detail is bounded and has no control characters`() {
        val bounded = MeetingAssistantWire.boundedDetail("model\nconfiguration\u0000failed" + "x".repeat(300))
        assertNotNull(bounded)
        val detail = bounded!!
        assertFalse(detail.contains('\n'))
        assertFalse(detail.contains('\u0000'))
        assertTrue(detail.toByteArray(Charsets.UTF_8).size <= 120)
        assertNull(MeetingAssistantWire.boundedDetail("   "))
    }

    private fun availability(
        runtimeReady: Boolean = true,
        providerAdmitted: Boolean = true,
        modelsLoaded: Boolean = true,
        models: List<ModelOptionUi> = emptyList(),
        preferredModelId: String? = null,
        storedModelId: String? = null,
    ): MeetingAssistantAvailability = MeetingAssistantWire.resolveAvailability(
        runtimeReady = runtimeReady,
        providerAdmitted = providerAdmitted,
        modelsLoaded = modelsLoaded,
        models = models,
        preferredModelId = preferredModelId,
        storedModelId = storedModelId,
    )

    private fun model(displayName: String, usable: Boolean): ModelOptionUi = ModelOptionUi(
        modelId = UUID.randomUUID().toString(),
        remoteModelId = displayName.lowercase(),
        displayName = displayName,
        providerId = providerId,
        providerName = "Provider",
        isUsable = usable,
    )

    private fun message(
        conversationId: String,
        runId: String,
        role: MessageRoleUi,
        text: String,
    ): MessageUi = MessageUi(
        id = UUID.randomUUID().toString(),
        conversationId = conversationId,
        runId = runId,
        role = role,
        text = text,
        timeLabel = "",
    )

    private fun detail(
        notes: String,
        segments: List<MeetingTranscriptSegment>,
    ): MeetingDetail = MeetingDetail(
        id = UUID.randomUUID().toString(),
        title = "Sync",
        createdAtMillis = 1_700_000_000_000L,
        updatedAtMillis = 1_700_000_100_000L,
        notes = notes,
        notesRevision = 1L,
        revision = 1L,
        transcription = MeetingTranscription(revision = 1L, segments = segments),
        materials = emptyList(),
        recordings = emptyList(),
        imports = emptyList(),
    )

    private fun segment(text: String) = MeetingTranscriptSegment(
        id = UUID.randomUUID().toString(),
        startMillis = 0L,
        endMillis = 1_000L,
        text = text,
        speaker = "Alpha",
    )
}
