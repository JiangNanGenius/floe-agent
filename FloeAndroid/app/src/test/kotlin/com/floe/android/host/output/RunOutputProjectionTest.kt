// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.RunOutputCardUi
import com.floe.android.feature.conversation.TimelineRowUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Projection contracts for the D04 owned run-output cards: rows come ONLY
 * from the native owned reader view, empty answers remove cards, non-
 * available states stay visible but non-actionable, transient action states
 * merge across refreshes, and a cold-loaded terminal run (no pumped events)
 * still lands its cards — because the projection iterates the owned reader
 * result map, not just replayed event frames. */
class RunOutputProjectionTest {

    private fun card(run: String, output: String, availability: String = "available",
                     action: String? = null, name: String = "report.docx") =
        RunOutputCardUi(
            runId = run, outputId = output, producerCallId = "call-1",
            displayName = name,
            mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            byteCount = 1024, availabilityRaw = availability, actionStateRaw = action,
        )

    private fun groups(state: com.floe.android.feature.conversation.ThreadUiState) =
        state.rows.filterIsInstance<TimelineRowUi.RunOutputGroup>()

    @Test
    fun emptyApplyRemovesGroupAndUnknownRunNeverAppears() {
        val builder = ThreadProjectionBuilder("11111111-2222-3333-4444-555555555555")
        val run = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        builder.applyRunOutputs(run, listOf(card(run, "c".repeat(64))), scanTruncated = false)
        assertEquals(1, groups(builder.build()).size)
        // Honest "this run sealed no user outputs": the group disappears.
        builder.applyRunOutputs(run, emptyList(), scanTruncated = false)
        assertEquals(0, groups(builder.build()).size)
    }

    @Test
    fun cardsSurviveColdReloadWithoutPumpedEvents() {
        val builder = ThreadProjectionBuilder("11111111-2222-3333-4444-555555555555")
        val run = "77777777-8888-9999-0000-111111111111"
        // Cold load: no event frames were replayed (terminal run has no
        // pump). The owned reader still answers the durable sealed outputs.
        builder.applyRunOutputs(run, listOf(card(run, "a".repeat(64))), scanTruncated = true)
        val emitted = groups(builder.build())
        assertEquals(1, emitted.size)
        assertEquals(run, emitted[0].runId)
        assertTrue(emitted[0].scanTruncated)
    }

    @Test
    fun unavailableStatesAreVisibleNonActionableAndRefreshKeepsActionStates() {
        val builder = ThreadProjectionBuilder("11111111-2222-3333-4444-555555555555")
        val run = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        val output = "c".repeat(64)
        builder.applyRunOutputs(run, listOf(card(run, output, availability = "missing")), false)
        var emitted = groups(builder.build())
        assertEquals("missing", emitted[0].outputs[0].availabilityRaw)
        // The lane goes absent/fenced: existing verified cards flip to the
        // honest unavailable caption, never back to actionable.
        builder.markRunOutputsUnavailable(run)
        emitted = groups(builder.build())
        assertEquals("unavailable", emitted[0].outputs[0].availabilityRaw)
        // A transient action state survives the next availability refresh.
        builder.setRunOutputActionState(run, output, "saving")
        builder.applyRunOutputs(run, listOf(card(run, output, availability = "available")), false)
        emitted = groups(builder.build())
        assertEquals("saving", emitted[0].outputs[0].actionStateRaw)
        builder.setRunOutputActionState(run, output, null)
        emitted = groups(builder.build())
        assertNull(emitted[0].outputs[0].actionStateRaw)
        assertNotNull(builder.cachedRunOutputCard(run, output))
        assertNull(builder.cachedRunOutputCard(run, "d".repeat(64)))
    }

    @Test
    fun groupIsDeduplicatedAgainstPumpedToolActivityOrdering() {
        val builder = ThreadProjectionBuilder("11111111-2222-3333-4444-555555555555")
        val run = "99999999-8888-7777-6666-555555555555"
        // Pump one real toolResult frame (durable event) for the run.
        val payload = Json.parseToJsonElement(
            """{"tool":"workspace.publishOutput","id":"call-1","status":"ok","summary":"s"}""",
        ).jsonObject
        builder.applyRunEvent(
            HostRunEventFrame(runID = run, sequence = 7L, kind = "toolResult",
                              payload = payload, bytes = 64),
        )
        builder.applyRunOutputs(run, listOf(card(run, "b".repeat(64))), false)
        val rows = builder.build().rows
        val stepGroups = rows.filterIsInstance<TimelineRowUi.StepGroup>()
            .count { it.groupId.startsWith("$run:") }
        val groups = groups(builder.build()).filter { it.runId == run }
        assertEquals(1, stepGroups)
        assertEquals("exactly one output group even though both event frames and the reader map own the run",
            1, groups.size)
    }
}
