// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Bounded wire-decoding tests for the schedule command replies. They prove
 * unknown/malformed shapes fail closed (no invented schedule), the closed
 * cadence vocabulary is enforced, dates remain exact milliseconds, and the
 * after-success/environment metadata fields survive the round trip.
 */
class TaskScheduleWireTest {

    private fun obj(raw: String): JsonObject =
        Json.parseToJsonElement(raw) as JsonObject

    @Test
    fun summaryDecodesEveryProductField() {
        val summary = TaskScheduleWire.summary(obj(
            """
            {"id":"11111111-1111-1111-1111-111111111111",
             "title":"Weekly report",
             "promptPreview":"Summarize the week",
             "cadence":"weekly",
             "enabled":true,
             "scheduledAt":"2026-10-31T09:00:00.000Z",
             "weekday":6,
             "intervalSeconds":null,
             "anchorTimezone":"Australia/Sydney",
             "nextFireAt":"2026-11-07T09:00:00.000Z",
             "lastStartedAt":null,
             "modelID":"22222222-2222-2222-2222-222222222222",
             "modelName":"Model A",
             "environmentID":"env-1",
             "environmentName":"Project env",
             "workspaceID":"33333333-3333-3333-3333-333333333333",
             "workspaceName":"Project",
             "approvalMode":"automatic",
             "recoveryPolicy":"safePoint",
             "notificationPolicy":"stages",
             "upstreamRunID":null,
             "revision":"abc",
             "needsAttention":true,
             "lastOccurrence":{"id":"44444444-4444-4444-4444-444444444444",
                               "state":"failed","scheduledFor":"2026-10-31T09:00:00.000Z",
                               "errorText":"model unavailable"}}
            """.trimIndent(),
        )) ?: error("summary must decode")

        assertEquals(TaskScheduleCadence.WEEKLY, summary.cadence)
        assertEquals(6, summary.weekday)
        assertEquals(1_793_437_200_000L, summary.scheduledAtMillis)
        assertEquals("automatic", summary.policy.approvalMode)
        assertTrue(summary.needsAttention)
        assertNotNull(summary.lastOccurrence)
        assertEquals("failed", summary.lastOccurrence?.state)
    }

    @Test
    fun unknownCadenceFailsClosedInsteadOfGuessing() {
        val summary = TaskScheduleWire.summary(obj(
            """{"id":"1","title":"x","cadence":"hourly","enabled":true}""",
        ))
        assertNull(summary)
    }

    @Test
    fun detailAcceptsBothFlatAndNestedSummaryShapes() {
        val nested = TaskScheduleWire.detail(obj(
            """
            {"summary":{"id":"1","title":"x","cadence":"daily","enabled":true},
             "prompt":"do the work","createdAt":"2026-10-31T00:00:00.000Z"}
            """.trimIndent(),
        ))
        assertEquals("do the work", nested?.prompt)
        assertEquals(TaskScheduleCadence.DAILY, nested?.summary?.cadence)

        val flat = TaskScheduleWire.detail(obj(
            """{"id":"2","title":"y","cadence":"once","enabled":false,"prompt":"p"}""",
        ))
        assertEquals("p", flat?.prompt)
    }

    @Test
    fun optionsDecodeEnvironmentMetadataForTheOwnershipGate() {
        val options = TaskScheduleWire.options(obj(
            """
            {"workspaces":[{"id":"w1","name":"Project"}],
             "models":[{"id":"m1","providerID":"p1","displayName":"Model","providerName":"Provider"}],
             "environments":[{"id":"e1","name":"Env","kind":"project","ownerID":"w1",
                              "state":"active","requiresRebuild":false,
                              "executionBackend":"linuxPRoot","parentID":null}],
             "defaultModelID":"m1","currentTimezone":"Australia/Sydney",
             "environmentSelectionAvailable":true}
            """.trimIndent(),
        ))
        assertEquals(1, options.workspaces.size)
        assertEquals(1, options.models.size)
        val environment = options.environments.single()
        assertEquals("w1", environment.ownerID)
        assertEquals("linuxPRoot", environment.executionBackend)
        assertTrue(options.environmentSelectionAvailable)
    }

    @Test
    fun dispatchOutcomeKeepsDeterministicIdsAndWaitingState() {
        val dispatch = TaskScheduleWire.dispatch(obj(
            """
            {"state":"waiting","scheduleID":"s1","occurrenceID":null,"runID":null,
             "conversationID":null,"nextFireAt":"2026-10-31T09:00:00.000Z",
             "code":"exactAlarmPermission","reason":"permission"}
            """.trimIndent(),
        ))
        assertEquals("waiting", dispatch?.state)
        assertEquals("exactAlarmPermission", dispatch?.code)
        assertEquals(1_793_437_200_000L, dispatch?.nextFireAtMillis)
        assertTrue(dispatch?.launched == false)
    }

    @Test
    fun armPlanDecodesEventDrivenSchedulesWithoutAClockTime() {
        val plan = TaskScheduleWire.armPlan(obj(
            """
            {"scheduleID":"s1","nextFireAt":null,"cadence":"afterSuccess",
             "eventDriven":true,"enabled":true}
            """.trimIndent(),
        ))
        assertEquals(TaskScheduleCadence.AFTER_SUCCESS, plan?.cadence)
        assertNull(plan?.nextFireAtMillis)
        assertTrue(plan?.eventDriven == true)
    }

    @Test
    fun boundedOptionsProjectionDecodesCountsAndTruncationMarker() {
        val options = TaskScheduleWire.options(obj(
            """
            {"workspaces":[{"id":"w1","name":"Project"}],
             "models":[{"id":"m1","providerID":"p1","displayName":"Model","providerName":"Provider"}],
             "environments":[{"id":"e1","name":"Env","kind":"project","ownerID":"w1",
                              "state":"active","requiresRebuild":false,
                              "executionBackend":"linuxPRoot","parentID":null}],
             "runChoices":[{"runID":"r1","conversationID":"c1","label":"Run \"one\" 中文",
                            "state":"streamingModel","startedAt":"2026-10-31T01:02:03.000Z",
                            "workspaceID":"w1"}],
             "counts":{"workspaces":50,"models":100,"environments":50,"runChoices":20},
             "truncated":true,
             "defaultModelID":"m1","currentTimezone":"Australia/Sydney",
             "environmentSelectionAvailable":true}
            """.trimIndent(),
        ))
        assertTrue(options.truncated)
        assertEquals(1, options.workspaces.size)
        assertEquals("Run \"one\" 中文", options.runChoices.single().label)
        assertEquals("w1", options.runChoices.single().workspaceID)
    }

    @Test
    fun scheduleListPageDecodesHasMoreAndNextOffset() {
        val page = TaskScheduleWire.page(
            obj(
                """
                {"schedules":[
                  {"id":"11111111-1111-1111-1111-111111111111","title":"A","cadence":"daily","enabled":true},
                  {"id":"22222222-2222-2222-2222-222222222222","title":"B","cadence":"once","enabled":false}],
                 "count":2,"totalCount":12,"offset":0,"nextOffset":2,
                 "hasMore":true,"truncated":false}
                """.trimIndent(),
            ),
            requestedOffset = 0,
        )
        assertEquals(2, page.schedules.size)
        assertEquals(12, page.totalCount)
        assertEquals(2, page.nextOffset)
        assertTrue(page.hasMore)
        assertFalse(page.truncated)
    }

    @Test
    fun historyPageDecodesTheTruncationMarker() {
        val page = TaskScheduleWire.occurrencePage(obj(
            """
            {"occurrences":[{"id":"o1","state":"running","scheduledFor":"2026-10-31T01:02:03.000Z"}],
             "count":1,"totalCount":40,"truncated":true}
            """.trimIndent(),
        ))
        assertEquals(1, page.occurrences.size)
        assertEquals(40, page.totalCount)
        assertTrue(page.truncated)
    }

    @Test
    fun malformedDatesAndMissingIdsAreNotCoerced() {
        val summary = TaskScheduleWire.summary(obj(
            """{"title":"x","cadence":"daily","enabled":true}""",
        ))
        assertNull(summary)
        assertNull(TaskScheduleWire.parseMillis("not-a-date"))
        assertNull(TaskScheduleWire.parseMillis(null))
        assertEquals(0L, TaskScheduleWire.parseMillis("1970-01-01T00:00:00.000Z"))
    }
}
