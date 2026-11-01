// SPDX-License-Identifier: MPL-2.0
//
// Focused JVM tests for the pure CalendarContract semantics. Authored source;
// NOT RUN by this lane. No device, provider row or permission participates.

package com.floe.android.host.calendar

import com.floe.android.core.calendar.CalendarEventRow
import com.floe.android.core.calendar.CalendarProviderFailure
import com.floe.android.core.calendar.CalendarProviderFailureCode
import com.floe.android.core.calendar.CalendarProviderRules
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CalendarProviderRulesTest {
    @Test
    fun allDayRequiresCanonicalUtcMidnight() {
        val midnight = LocalDate.of(2026, 11, 2)
            .atStartOfDay(java.time.ZoneId.of("UTC")).toInstant().toEpochMilli()
        CalendarProviderRules.requireAllDayUtcMidnight(midnight)
        try {
            CalendarProviderRules.requireAllDayUtcMidnight(midnight + 1)
            fail("local-midnight millis must be refused")
        } catch (failure: CalendarProviderFailure) {
            assertEquals(CalendarProviderFailureCode.INVALID_ALL_DAY, failure.code)
        }
        assertEquals("2026-11-02", CalendarProviderRules.formatAllDayDate(midnight, "Australia/Sydney"))
    }

    @Test
    fun occurrenceTokenRoundTripsWholeSeconds() {
        val start = 1_730_000_000_123L
        val token = CalendarProviderRules.occurrenceToken(42, start)
        assertEquals("42@2024-10-27T03:33:20Z", token)
        val parsed = CalendarProviderRules.parseOccurrenceToken(token)
        assertEquals(42L, parsed?.first)
        assertEquals(1_730_000_000_000L, parsed?.second)
        assertNull(CalendarProviderRules.parseOccurrenceToken("42@2024-10-27T03:33:20+11:00"))
        assertNull(CalendarProviderRules.parseOccurrenceToken("0@2024-10-27T03:33:20Z"))
        assertNull(CalendarProviderRules.parseOccurrenceToken("missing"))
    }

    @Test
    fun recurrenceSubsetIsCanonicalAndClosed() {
        assertEquals("FREQ=DAILY", CalendarProviderRules.canonicalRecurrence("rrule:freq=daily"))
        assertEquals(
            "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE",
            CalendarProviderRules.canonicalRecurrence("BYDAY=MO,WE;FREQ=WEEKLY;INTERVAL=2"),
        )
        assertEquals("", CalendarProviderRules.canonicalRecurrence(""))
        assertNull(CalendarProviderRules.canonicalRecurrence(null))
        assertEquals("FREQ=DAILY;UNTIL=20261102T000000Z",
            CalendarProviderRules.rruleWithUntil("FREQ=DAILY", 1_793_577_600_000L))
        listOf(
            "FREQ=DAILY;COUNT=2;UNTIL=20261102T000000Z",
            "FREQ=HOURLY",
            "FREQ=DAILY;BYSETPOS=1",
            "FREQ=DAILY;INTERVAL=0",
            "FREQ=MONTHLY;BYMONTH=13",
        ).forEach { rule ->
            try {
                CalendarProviderRules.canonicalRecurrence(rule)
                fail("rule should be refused: $rule")
            } catch (_: CalendarProviderFailure) {
                // expected
            }
        }
    }

    @Test
    fun writableCalendarRequiresContributorAndAccount() {
        assertTrue(CalendarProviderRules.isWritable(500, "user@example.com"))
        assertTrue(CalendarProviderRules.isWritable(700, "user@example.com"))
        assertTrue(!CalendarProviderRules.isWritable(400, "user@example.com"))
        assertTrue(!CalendarProviderRules.isWritable(700, ""))
        assertTrue(!CalendarProviderRules.isWritable(700, null))
    }

    @Test
    fun readbackRequiresExactProviderFields() {
        val actual = CalendarEventRow(
            eventID = 7,
            calendarID = 3,
            calendarName = "Personal",
            title = "Focus",
            startMillis = 1_730_000_000_000L,
            endMillis = 1_730_003_600_000L,
            allDay = false,
            timeZone = "Australia/Sydney",
            location = null,
            notes = null,
            recurrence = "FREQ=DAILY",
            originalInstanceTimeMillis = null,
            status = 1,
        )
        val fields = CalendarProviderRules.readbackFields(
            expectedEventID = 7,
            expectedCalendarID = 3,
            expectedTitle = "Focus",
            expectedStartMinutes = 1_730_000_000_000L / 60_000L,
            expectedEndMinutes = 1_730_003_600_000L / 60_000L,
            expectedAllDay = false,
            expectedTimeZone = "Australia/Sydney",
            expectedRecurrence = "FREQ=DAILY",
            actual = actual,
        )
        assertTrue(fields != null)
        assertTrue(fields!!.contains("recurrence"))
        assertNull(
            CalendarProviderRules.readbackFields(
                expectedEventID = 7,
                expectedCalendarID = 3,
                expectedTitle = "Different",
                expectedStartMinutes = 1_730_000_000_000L / 60_000L,
                expectedEndMinutes = 1_730_003_600_000L / 60_000L,
                expectedAllDay = false,
                expectedTimeZone = "Australia/Sydney",
                expectedRecurrence = null,
                actual = actual,
            ),
        )
    }

    @Test
    fun recurringDurationAndAllDayBoundary() {
        assertEquals(
            "P3600S",
            CalendarProviderRules.durationForRecurring(1_730_000_000_000L, 1_730_003_600_000L),
        )
        assertEquals(
            "P2D",
            CalendarProviderRules.allDayDurationForRecurring(1_793_577_600_000L, 1_793_750_400_000L),
        )
        try {
            CalendarProviderRules.allDayDurationForRecurring(
                1_793_577_600_000L,
                1_793_577_600_000L + 86_400_000L + 1,
            )
            fail("a partial all-day recurring end must be refused")
        } catch (_: CalendarProviderFailure) {
            // expected
        }
    }

    @Test
    fun spanVocabularyIsClosed() {
        assertEquals("thisEvent", CalendarProviderRules.canonicalSpan(null))
        assertEquals("thisEvent", CalendarProviderRules.canonicalSpan(""))
        assertEquals("futureEvents", CalendarProviderRules.canonicalSpan("futureEvents"))
        try {
            CalendarProviderRules.canonicalSpan("all")
            fail("unknown span must be refused")
        } catch (_: CalendarProviderFailure) {
            // expected
        }
    }
}
