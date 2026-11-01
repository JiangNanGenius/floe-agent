// SPDX-License-Identifier: MPL-2.0
//
// Pure date/time/recurrence/provider rules. Kept free of Android framework
// calls so the App JVM tests can prove the semantics without a device.

package com.floe.android.core.calendar

import java.time.DateTimeException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

object CalendarProviderRules {
    /** CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR */
    const val CAL_ACCESS_CONTRIBUTOR = 500

    val UTC: ZoneId = ZoneOffset.UTC

    private val UTC_DATE: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyyMMdd", Locale.US)
    private val UTC_INSTANT: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'", Locale.US).withZone(ZoneOffset.UTC)

    fun isWritable(accessLevel: Int, accountName: String?): Boolean =
        accessLevel >= CAL_ACCESS_CONTRIBUTOR && !accountName.isNullOrBlank()

    fun validTimeZone(raw: String?): String? {
        val value = raw?.trim().orEmpty()
        if (value.isEmpty() || value.length > 64) return null
        return try {
            ZoneId.of(value).id
        } catch (_: DateTimeException) {
            null
        }
    }

    /** All-day rows are canonical UTC-midnight instants. A caller that passes
     *  local-midnight milliseconds would silently store the previous/next day,
     *  so this is a typed refusal instead of a guessed conversion. */
    fun requireAllDayUtcMidnight(millis: Long) {
        if (Math.floorMod(millis, 86_400_000L) != 0L) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_ALL_DAY,
                "all-day start/end must be UTC midnight",
            )
        }
    }

    fun localDateToUtcMidnight(date: LocalDate): Long =
        date.atStartOfDay(UTC).toInstant().toEpochMilli()

    fun utcMidnightToLocalDate(millis: Long): LocalDate =
        Instant.ofEpochMilli(millis).atZone(UTC).toLocalDate()

    /** The UI shows an all-day todo/event date in the user's zone; the stored
     *  instant stays UTC midnight. */
    fun formatAllDayDate(millis: Long, zoneId: String): String {
        requireAllDayUtcMidnight(millis)
        return Instant.ofEpochMilli(millis).atZone(UTC).toLocalDate().toString()
    }

    fun localDateTimeToMillis(
        date: LocalDate,
        hour: Int,
        minute: Int,
        zoneId: String,
    ): Long {
        val zone = validTimeZone(zoneId)?.let(ZoneId::of)
            ?: throw CalendarProviderFailure(CalendarProviderFailureCode.INVALID_TIMEZONE, "invalid timezone")
        return ZonedDateTime.of(date, java.time.LocalTime.of(hour, minute), zone)
            .toInstant().toEpochMilli()
    }

    fun occurrenceToken(eventID: Long, startMillis: Long): String {
        require(eventID > 0)
        val seconds = Math.floorDiv(startMillis, 1_000L) * 1_000L
        return "$eventID@${UTC_INSTANT.format(Instant.ofEpochMilli(seconds))}"
    }

    fun parseOccurrenceToken(raw: String): Pair<Long, Long>? {
        if (raw.length > 512) return null
        val separator = raw.lastIndexOf('@')
        if (separator <= 0 || separator == raw.lastIndex) return null
        val id = raw.substring(0, separator).toLongOrNull() ?: return null
        if (id <= 0) return null
        val datePart = raw.substring(separator + 1)
        if (!datePart.endsWith("Z") || datePart.length != 20) return null
        return try {
            val instant = java.time.LocalDateTime.parse(
                datePart,
                DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US),
            ).toInstant(ZoneOffset.UTC)
            id to instant.toEpochMilli()
        } catch (_: DateTimeException) {
            null
        }
    }

    fun canonicalSpan(raw: String?): String {
        val value = raw?.trim().orEmpty()
        return when (value) {
            "", "thisEvent" -> "thisEvent"
            "futureEvents" -> "futureEvents"
            else -> throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_FIELDS,
                "span must be thisEvent or futureEvents",
            )
        }
    }

    /** Bounded RFC-5545 subset shared with the Swift domain. Returns the
     *  canonical uppercase form without the RRULE: label. */
    fun canonicalRecurrence(raw: String?): String? {
        if (raw == null) return null
        var value = raw.trim()
        if (value.isEmpty()) return ""
        if (value.length > 1_024) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_RECURRENCE,
                "recurrence too long",
            )
        }
        if (value.startsWith("RRULE:", ignoreCase = true)) value = value.substring(6)
        val allowed = setOf("FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "WKST")
        val parsed = linkedMapOf<String, String>()
        for (part in value.split(';').filter { it.isNotEmpty() }) {
            val pieces = part.split('=', limit = 2)
            if (pieces.size != 2) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.INVALID_RECURRENCE,
                    "invalid recurrence part",
                )
            }
            val key = pieces[0].uppercase(Locale.US)
            val item = pieces[1].uppercase(Locale.US)
            if (key !in allowed || item.isEmpty() || parsed.containsKey(key)) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.INVALID_RECURRENCE,
                    "unsupported recurrence key",
                )
            }
            parsed[key] = item
        }
        val frequency = parsed["FREQ"]
        if (frequency !in setOf("DAILY", "WEEKLY", "MONTHLY", "YEARLY")) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_RECURRENCE,
                "unsupported frequency",
            )
        }
        if (parsed.containsKey("COUNT") && parsed.containsKey("UNTIL")) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_RECURRENCE,
                "COUNT and UNTIL are mutually exclusive",
            )
        }
        parsed["COUNT"]?.let { raw ->
            val count = raw.toIntOrNull()
            if (count == null || count !in 1..10_000) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.INVALID_RECURRENCE,
                    "invalid COUNT",
                )
            }
        }
        parsed["INTERVAL"]?.let { raw ->
            val interval = raw.toIntOrNull()
            if (interval == null || interval !in 1..366) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.INVALID_RECURRENCE,
                    "invalid INTERVAL",
                )
            }
        }
        parsed["UNTIL"]?.let { until ->
            if (until.length > 32) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.INVALID_RECURRENCE,
                    "invalid UNTIL",
                )
            }
        }
        parsed["BYDAY"]?.split(',')?.forEach { day ->
            if (day.length > 8) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.INVALID_RECURRENCE,
                    "invalid BYDAY",
                )
            }
        }
        parsed["BYMONTHDAY"]?.split(',')?.forEach { day ->
            val value = day.toIntOrNull()
            if (value == null || value == 0 || Math.abs(value) > 31) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.INVALID_RECURRENCE,
                    "invalid BYMONTHDAY",
                )
            }
        }
        parsed["BYMONTH"]?.split(',')?.forEach { month ->
            val value = month.toIntOrNull()
            if (value == null || value !in 1..12) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.INVALID_RECURRENCE,
                    "invalid BYMONTH",
                )
            }
        }
        return listOf("FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "WKST")
            .mapNotNull { key -> parsed[key]?.let { "$key=$it" } }
            .joinToString(";")
    }

    /** RRULE UNTIL is an absolute UTC instant in CalendarContract. */
    fun rruleUntil(millis: Long): String =
        UTC_INSTANT.format(Instant.ofEpochMilli(millis).truncatedTo(ChronoUnit.SECONDS))

    fun rruleWithUntil(recurrence: String, untilMillis: Long): String {
        val canonical = canonicalRecurrence(recurrence) ?: ""
        val parts = canonical.split(';').filter { it.isNotEmpty() }
            .filterNot { it.startsWith("UNTIL=") }
            .toMutableList()
        parts.add("UNTIL=${rruleUntil(untilMillis)}")
        return parts.joinToString(";")
    }

    fun rruleFrequency(recurrence: String): String? =
        canonicalRecurrence(recurrence)?.split(';')
            ?.firstOrNull { it.startsWith("FREQ=") }
            ?.substringAfter("FREQ=")

    fun rruleHasCount(recurrence: String): Boolean =
        canonicalRecurrence(recurrence)?.split(';')?.any { it.startsWith("COUNT=") } == true

    fun durationForRecurring(startMillis: Long, endMillis: Long): String {
        if (endMillis <= startMillis) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_RANGE,
                "end must follow start",
            )
        }
        val seconds = (endMillis - startMillis) / 1_000L
        return "P${seconds}S"
    }

    /** All-day rows use day-granular duration for recurring series. */
    fun allDayDurationForRecurring(startMillis: Long, endMillis: Long): String {
        requireAllDayUtcMidnight(startMillis)
        requireAllDayUtcMidnight(endMillis)
        if (endMillis <= startMillis) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_RANGE,
                "end must follow start",
            )
        }
        val span = endMillis - startMillis
        if (span % 86_400_000L != 0L) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_ALL_DAY,
                "an all-day recurring event must end on a UTC day boundary",
            )
        }
        val days = span / 86_400_000L
        return "P${days}D"
    }

    fun readbackFields(
        expectedEventID: Long,
        expectedCalendarID: Long,
        expectedTitle: String,
        expectedStartMinutes: Long,
        expectedEndMinutes: Long,
        expectedAllDay: Boolean,
        expectedTimeZone: String,
        expectedRecurrence: String?,
        actual: CalendarEventRow,
    ): List<String>? {
        if (actual.eventID != expectedEventID) return null
        if (actual.calendarID != expectedCalendarID) return null
        if (actual.title != expectedTitle) return null
        if (actual.startMillis / 60_000L != expectedStartMinutes) return null
        if (actual.endMillis / 60_000L != expectedEndMinutes) return null
        if (actual.allDay != expectedAllDay) return null
        if (actual.timeZone != expectedTimeZone) return null
        if (expectedRecurrence != null && (actual.recurrence ?: "") != expectedRecurrence) return null
        val fields = mutableListOf("id", "calendarID", "title", "start", "end", "allDay", "timeZone")
        if (expectedRecurrence != null) fields.add("recurrence")
        return fields
    }

    fun requireWriteGrant(granted: Boolean) {
        if (!granted) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.WRITE_PERMISSION_DENIED,
                "calendar write permission is not granted",
            )
        }
    }

    fun requireReadGrant(granted: Boolean) {
        if (!granted) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PERMISSION_DENIED,
                "calendar read permission is not granted",
            )
        }
    }

    fun utf8Length(value: String): Int = value.toByteArray(Charsets.UTF_8).size

    fun boundedTitle(value: String): String {
        val trimmed = value.trim()
        if (trimmed.isEmpty() || utf8Length(trimmed) > 512) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_FIELDS,
                "title is required and must be at most 512 UTF-8 bytes",
            )
        }
        return trimmed
    }

    fun boundedText(value: String?, limit: Int, code: CalendarProviderFailureCode,
                    name: String): String? {
        if (value == null) return null
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return ""
        if (utf8Length(trimmed) > limit) {
            throw CalendarProviderFailure(code, "$name is too long")
        }
        return trimmed
    }

    fun epochDay(millis: Long): Long = Math.floorDiv(millis, 86_400_000L)

    fun formatUtcDate(millis: Long): String =
        UTC_DATE.format(Instant.ofEpochMilli(millis).atZone(UTC).toLocalDate())
}
