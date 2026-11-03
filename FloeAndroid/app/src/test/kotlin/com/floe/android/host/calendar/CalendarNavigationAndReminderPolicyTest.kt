// SPDX-License-Identifier: MPL-2.0
//
// Focused JVM tests for the reminder route identity and the exact/inexact
// decision. Authored source; NOT RUN by this lane.

package com.floe.android.host.calendar

import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CalendarNavigationAndReminderPolicyTest {
    private val todoID = "11111111-2222-4333-8444-555555555555"

    @After
    fun clean() {
        C06CalendarNavigation.clearForTesting()
    }

    @Test
    fun explicitSameAppRouteIsAcceptedAndConsumedOnce() {
        val now = 10_000L
        assertTrue(
            C06CalendarNavigation.submitFromIntent(
                action = C06CalendarNavigation.ACTION_OPEN_TODO,
                componentPackage = "com.floe.agent",
                ownPackage = "com.floe.agent",
                todoID = todoID,
                revision = 4,
                nowElapsedMillis = now,
            ),
        )
        val route = C06CalendarNavigation.pending.value
        assertEquals(todoID, route?.todoID)
        assertEquals(4, route?.revision)
        assertFalse(C06CalendarNavigation.isExpired(route!!, now + 1_000L))
        assertEquals(route, C06CalendarNavigation.consume(route.requestID))
        assertNull(C06CalendarNavigation.pending.value)
        assertNull(C06CalendarNavigation.consume(route.requestID))
    }

    @Test
    fun wrongActionOrPackageOrIdentityIsRefused() {
        assertFalse(
            C06CalendarNavigation.submitFromIntent(
                "com.example.OTHER",
                "com.floe.agent",
                "com.floe.agent",
                todoID,
                1,
                0L,
            ),
        )
        assertFalse(
            C06CalendarNavigation.submitFromIntent(
                C06CalendarNavigation.ACTION_OPEN_TODO,
                "com.example.other",
                "com.floe.agent",
                todoID,
                1,
                0L,
            ),
        )
        assertFalse(
            C06CalendarNavigation.submitFromIntent(
                C06CalendarNavigation.ACTION_OPEN_TODO,
                "com.floe.agent",
                "com.floe.agent",
                "not-a-uuid",
                1,
                0L,
            ),
        )
        assertNull(C06CalendarNavigation.pending.value)
    }

    @Test
    fun expiredRouteIsRejectedBeforeSelection() {
        assertTrue(
            C06CalendarNavigation.submitFromIntent(
                C06CalendarNavigation.ACTION_OPEN_TODO,
                "com.floe.agent",
                "com.floe.agent",
                todoID,
                1,
                0L,
            ),
        )
        val route = C06CalendarNavigation.pending.value!!
        assertTrue(C06CalendarNavigation.isExpired(route, 120_001L))
    }

    @Test
    fun reminderDecisionIsHonestAboutPermissionAndExactness() {
        val blocked = TodoReminderPolicy.decide(
            notificationsEnabled = false,
            exactAlarmAllowed = true,
            reminderAtMillis = 5_000L,
            dueAtMillis = 10_000L,
            nowMillis = 1_000L,
        )
        assertEquals(TodoReminderWakeMode.NOTIFICATIONS_BLOCKED, blocked.mode)
        assertEquals("notificationsDisabled", blocked.reason)

        val exact = TodoReminderPolicy.decide(
            notificationsEnabled = true,
            exactAlarmAllowed = true,
            reminderAtMillis = 5_000L,
            dueAtMillis = 10_000L,
            nowMillis = 1_000L,
        )
        assertEquals(TodoReminderWakeMode.EXACT, exact.mode)
        assertEquals(5_000L, exact.triggerAtMillis)
        assertNull(exact.reason)

        val inexact = TodoReminderPolicy.decide(
            notificationsEnabled = true,
            exactAlarmAllowed = false,
            reminderAtMillis = 5_000L,
            dueAtMillis = 10_000L,
            nowMillis = 1_000L,
        )
        assertEquals(TodoReminderWakeMode.INEXACT, inexact.mode)
        assertEquals("exactAlarmPermissionMissing", inexact.reason)

        val late = TodoReminderPolicy.decide(
            notificationsEnabled = true,
            exactAlarmAllowed = true,
            reminderAtMillis = 1L,
            dueAtMillis = 10_000L,
            nowMillis = 5_000L,
        )
        assertEquals(6_000L, late.triggerAtMillis)
    }

    @Test
    fun reminderIdentityIsStableAndDistinct() {
        val id = UUID.fromString(todoID).toString()
        assertEquals(TodoReminderScheduler.requestCode(id), TodoReminderScheduler.requestCode(id))
        assertNotEquals(TodoReminderScheduler.requestCode(id), TodoReminderScheduler.notificationID(id))
        assertNotEquals(
            TodoReminderScheduler.requestCode(id),
            TodoReminderScheduler.requestCode(UUID.randomUUID().toString()),
        )
    }
}
