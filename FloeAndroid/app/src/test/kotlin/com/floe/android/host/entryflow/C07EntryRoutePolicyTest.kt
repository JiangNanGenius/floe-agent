// SPDX-License-Identifier: MPL-2.0
//
// C07 App-entry route/notification regressions. Pure JVM: no App, DB, Intent,
// grant, device or network participates. AUTHORED, NOT RUN by this lane.
package com.floe.android.host.entryflow

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C07EntryRoutePolicyTest {
    private val task = UUID.fromString("2a9bb479-f614-473c-b8e4-008e2dfe8222").toString()
    private val schedule = UUID.fromString("6c3a1e44-3b8d-4ad1-9a1b-7a2f0d5e8c11").toString()

    @Test
    fun validRoutesKeepTheirExactTarget() {
        assertEquals(
            C07RouteParse.Parsed(C07EntryRoute.NewTask),
            C07EntryRouteParser.parse("floe://new"),
        )
        assertEquals(
            C07RouteParse.Parsed(C07EntryRoute.Task(task)),
            C07EntryRouteParser.parse("FLOE://TASK/${task.uppercase()}"),
        )
        assertEquals(
            C07RouteParse.Parsed(C07EntryRoute.Schedule(schedule)),
            C07EntryRouteParser.parse("floe://schedule/$schedule"),
        )
        assertEquals(
            C07RouteParse.Parsed(C07EntryRoute.Share(null)),
            C07EntryRouteParser.parse("floe://share"),
        )
        assertEquals(
            C07RouteParse.Parsed(C07EntryRoute.Share(task)),
            C07EntryRouteParser.parse("floe://share?intake=$task"),
        )
    }

    @Test
    fun hostileLinksCannotBecomeExecutionOrPermission() {
        val hostile = listOf(
            "floe://run",
            "floe://execute",
            "floe://new?prompt=run&autoSend=true",
            "floe://new?permission=all",
            "floe://task/$task?run=true",
            "floe://task/$task?approve=true",
            "floe://share?intake=$task&intake=$task",
            "floe://share?intake=$task&run=true",
            "floe://user:password@new",
            "floe://new:123",
            "floe://new#run",
            "https://example.invalid/floe/new",
            "javascript:runTask()",
            "floe://task",
            "floe://task/not-a-uuid",
            "floe://task/../new",
            "floe://task/%2F$task",
            "floe://task/$task/other",
            "floe://share?intake",
            "floe://share?intake=",
            "floe://share?task=all",
            "floe://schedule/$schedule?approve=true",
            "floe://task/$task\\n",
        )
        for (input in hostile) {
            val result = C07EntryRouteParser.parse(input)
            assertTrue("hostile link accepted: $input", result is C07RouteParse.Refused)
        }
    }

    @Test
    fun oversizedLinksDoNotReachRouting() {
        val input = "floe://share?intake=" + "a".repeat(ENTRY_MAX_URL_BYTES)
        val result = C07EntryRouteParser.parse(input)
        assertEquals(C07RouteParse.Refused("tooLong"), result)
    }

    @Test
    fun notificationPayloadsAreIdentifierOnlyAndBounded() {
        assertEquals(task, C07EntryIds.canonicalUuid(task.uppercase()))
        assertNull(C07EntryIds.canonicalUuid(""))
        assertNull(C07EntryIds.canonicalUuid("not-a-uuid"))
        assertNull(C07EntryIds.canonicalUuid("2a9bb479-f614-473c-b8e4-008e2dfe822z"))
        assertNotNull(C07EntryNotification.validQuestionId("q-1"))
        assertNull(C07EntryNotification.validQuestionId(""))
        assertNull(C07EntryNotification.validQuestionId("q".repeat(129)))
        assertNull(C07EntryNotification.validQuestionId("bad id"))
        assertNull(C07EntryNotification.validQuestionTextId("q".repeat(161)))
    }
}
