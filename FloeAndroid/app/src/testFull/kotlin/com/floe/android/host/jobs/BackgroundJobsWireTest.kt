// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.jobs

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Boundary contract between the native durable projection and the App. */
class BackgroundJobsWireTest {
    private val conversation = "00000000-0000-0000-0000-000000000001"
    private val run = "00000000-0000-0000-0000-000000000002"
    private val job = "00000000-0000-0000-0000-000000000003"

    private fun row(state: String = "running", terminal: Boolean = false) =
        buildJsonObject {
            put("jobID", job); put("runID", run); put("target", "shell")
            put("state", state); put("terminal", terminal)
            put("cancellationRequested", true); put("resultAvailable", false)
            put("progress", buildJsonObject { put("completedUnits", 2); put("totalUnits", 8) })
            put("dependency", buildJsonObject { put("kind", "job"); put("state", "pending") })
        }

    private fun reply(rows: List<JsonObject>, truncated: Boolean = false): String =
        buildJsonObject {
            put("ok", true); put("schema", "floe.taskjobs/30")
            put("count", rows.size); put("truncated", truncated)
            put("jobs", buildJsonArray { rows.forEach { add(it) } })
        }.toString()

    @Test fun nativeRunningCancellationRemainsNonterminal() {
        val result = BackgroundJobsWire.parse(reply(listOf(row())))
        assertEquals(null, result.error)
        val item = result.jobs.single()
        assertEquals(job, item.jobId); assertEquals(run, item.runId)
        assertEquals("running", item.stateName); assertFalse(item.terminal)
        assertTrue(item.cancellationRequested); assertFalse(item.resultAvailable)
        assertEquals(2, item.completedUnits); assertEquals(8, item.totalUnits)
        assertEquals("pending", item.dependencyState)
    }

    @Test fun contradictoryTerminalFlagCannotBecomeAnExecutionReceipt() {
        for (bad in listOf(row("running", true), row("completed", false))) {
            val result = BackgroundJobsWire.parse(reply(listOf(bad)))
            assertEquals("invalidResponse", result.error)
            assertTrue(result.jobs.isEmpty())
        }
    }

    @Test fun malformedIdentityAndUnknownStateRejectTheWholeSnapshot() {
        val invalidId = JsonObject(row() + ("jobID" to JsonPrimitive("not-an-owned-job-id")))
        for (bad in listOf(invalidId, row("imaginarySuccess", true))) {
            val result = BackgroundJobsWire.parse(reply(listOf(row(), bad)))
            assertEquals("invalidResponse", result.error)
            assertTrue(result.jobs.isEmpty())
        }
    }

    @Test fun malformedEnvelopeTypesReturnTypedFailure() {
        for (raw in listOf("not-json", "[]", "{\"ok\":{}}", "{\"ok\":false,\"error\":[]}")) {
            val result = BackgroundJobsWire.parse(raw)
            assertTrue(result.error != null)
            assertTrue(result.jobs.isEmpty())
        }
    }

    @Test fun nativeErrorAndSchemaVersionNeverProduceRows() {
        assertEquals("staleEpoch", BackgroundJobsWire.parse(
            "{\"ok\":false,\"error\":\"staleEpoch\"}").error)
        val wrongSchema = reply(listOf(row())).replace("floe.taskjobs/30", "floe.taskjobs/31")
        assertEquals("invalidResponse", BackgroundJobsWire.parse(wrongSchema).error)
    }

    @Test fun nativeBoundsAndTruncationRemainVisible() {
        assertEquals("invalidResponse", BackgroundJobsWire.parse(
            reply(List(BackgroundJobsWire.MAX_JOBS + 1) { row() })).error)
        val truncated = BackgroundJobsWire.parse(reply(listOf(row()), truncated = true))
        assertEquals(null, truncated.error); assertTrue(truncated.truncated)
    }

    @Test fun cancelRequestCarriesExactTaskRunAndJob() {
        val request = Json.parseToJsonElement(BackgroundJobsWire.cancelRequest(
            "cancel-1", 7, conversation, run, job)).jsonObject
        assertEquals("jobs.cancel", request["action"]?.jsonPrimitive?.content)
        assertEquals("7", request["epoch"]?.jsonPrimitive?.content)
        val payload = request.getValue("payload").jsonObject
        assertEquals(conversation, payload["conversationID"]?.jsonPrimitive?.content)
        assertEquals(run, payload["runID"]?.jsonPrimitive?.content)
        assertEquals(job, payload["jobID"]?.jsonPrimitive?.content)
    }
}
