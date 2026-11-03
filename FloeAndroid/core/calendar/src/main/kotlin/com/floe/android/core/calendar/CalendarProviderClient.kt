// SPDX-License-Identifier: MPL-2.0
//
// Real Android CalendarContract access. This is the ONLY code in the App that
// reads or writes the system calendar provider. It never invents a "default"
// calendar: every mutation names an explicit writable calendar chosen by the
// user, and every mutation ends with an actual provider row/instance read-back.
//
// Recurring writes use CalendarProvider's transactional `applyBatch` where a
// split is required, and detached exception rows for a single occurrence.
// Cancelled/deleted occurrences are represented by real STATUS_CANCELED
// exception rows. A provider/Intent response alone is never success.

package com.floe.android.core.calendar

import android.Manifest
import android.content.ContentProviderOperation
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.CalendarContract
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Instances
import java.util.concurrent.atomic.AtomicLong

class AndroidCalendarProvider(
    private val context: Context,
) : CalendarProviderBackend {

    private val resolver = context.contentResolver
    private val revision = AtomicLong(System.currentTimeMillis())

    // MARK: Snapshot / permission

    override fun snapshot(): CalendarSnapshotRow {
        val provider = providerAvailable()
        val read = readGranted()
        val write = writeGranted()
        val calendars = if (provider && read) readCalendars() else emptyList()
        return CalendarSnapshotRow(
            providerAvailable = provider,
            readGranted = read,
            writeGranted = write,
            calendars = calendars,
            revision = nextRevision(),
        )
    }

    fun readGranted(): Boolean =
        context.checkSelfPermission(Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    fun writeGranted(): Boolean =
        context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    fun providerAvailable(): Boolean = try {
        val client = resolver.acquireContentProviderClient(CalendarContract.AUTHORITY)
        if (client == null) {
            false
        } else {
            client.close()
            true
        }
    } catch (_: SecurityException) {
        // The provider exists but this caller cannot reach it.
        true
    } catch (_: RuntimeException) {
        false
    }

    private fun nextRevision(): Long = revision.updateAndGet { previous ->
        maxOf(previous + 1, System.currentTimeMillis())
    }

    private fun readCalendars(): List<CalendarSummaryRow> {
        val projection = arrayOf(
            Calendars._ID,
            Calendars.CALENDAR_DISPLAY_NAME,
            Calendars.ACCOUNT_NAME,
            Calendars.ACCOUNT_TYPE,
            Calendars.OWNER_ACCOUNT,
            Calendars.CALENDAR_TIME_ZONE,
            Calendars.CALENDAR_COLOR,
            Calendars.CALENDAR_ACCESS_LEVEL,
            Calendars.VISIBLE,
            Calendars.IS_PRIMARY,
        )
        val rows = mutableListOf<CalendarSummaryRow>()
        try {
            resolver.query(
                Calendars.CONTENT_URI,
                projection,
                null,
                null,
                "${Calendars.IS_PRIMARY} DESC, ${Calendars.CALENDAR_DISPLAY_NAME}",
            )?.use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow(Calendars._ID)
                val nameIndex = cursor.getColumnIndexOrThrow(Calendars.CALENDAR_DISPLAY_NAME)
                val accountIndex = cursor.getColumnIndexOrThrow(Calendars.ACCOUNT_NAME)
                val typeIndex = cursor.getColumnIndexOrThrow(Calendars.ACCOUNT_TYPE)
                val ownerIndex = cursor.getColumnIndexOrThrow(Calendars.OWNER_ACCOUNT)
                val zoneIndex = cursor.getColumnIndexOrThrow(Calendars.CALENDAR_TIME_ZONE)
                val colorIndex = cursor.getColumnIndexOrThrow(Calendars.CALENDAR_COLOR)
                val accessIndex = cursor.getColumnIndexOrThrow(Calendars.CALENDAR_ACCESS_LEVEL)
                val visibleIndex = cursor.getColumnIndexOrThrow(Calendars.VISIBLE)
                val primaryIndex = cursor.getColumnIndexOrThrow(Calendars.IS_PRIMARY)
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idIndex)
                    if (id <= 0) continue
                    val account = if (cursor.isNull(accountIndex)) "" else cursor.getString(accountIndex)
                    val access = if (cursor.isNull(accessIndex)) 0 else cursor.getInt(accessIndex)
                    rows += CalendarSummaryRow(
                        id = id,
                        displayName = cursor.getString(nameIndex) ?: "",
                        accountName = account ?: "",
                        accountType = if (cursor.isNull(typeIndex)) "" else cursor.getString(typeIndex) ?: "",
                        ownerAccount = if (cursor.isNull(ownerIndex)) "" else cursor.getString(ownerIndex) ?: "",
                        timeZone = if (cursor.isNull(zoneIndex)) "UTC" else cursor.getString(zoneIndex) ?: "UTC",
                        color = if (cursor.isNull(colorIndex)) 0 else cursor.getInt(colorIndex),
                        accessLevel = access,
                        writable = CalendarProviderRules.isWritable(access, account),
                        visible = !cursor.isNull(visibleIndex) && cursor.getInt(visibleIndex) != 0,
                        isPrimary = !cursor.isNull(primaryIndex) && cursor.getInt(primaryIndex) != 0,
                    )
                }
            }
        } catch (security: SecurityException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PERMISSION_DENIED,
                "calendar read permission is not granted",
                detail = security.message,
            )
        } catch (invalid: IllegalArgumentException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PROVIDER_REJECTED,
                "calendar provider rejected the calendar query",
                detail = invalid.message,
            )
        }
        return rows
    }

    // MARK: Read

    override fun instances(
        startMillis: Long,
        endMillis: Long,
        calendarID: Long?,
        query: String?,
        limit: Int,
        offset: Int,
    ): CalendarEventPageRow {
        CalendarProviderRules.requireReadGrant(readGranted())
        validateRange(startMillis, endMillis)
        val boundedLimit = limit.coerceIn(1, 200)
        val boundedOffset = offset.coerceIn(0, 10_000)
        val names = readCalendarNames()
        val builder = Instances.CONTENT_URI.buildUpon()
            .appendPath(startMillis.toString())
            .appendPath(endMillis.toString())
        val uri = builder.build()
        val selection = StringBuilder()
        val arguments = mutableListOf<String>()
        if (calendarID != null) {
            selection.append("${Instances.CALENDAR_ID} = ?")
            arguments += calendarID.toString()
        }
        val trimmedQuery = query?.trim()?.takeIf { it.isNotEmpty() }
        if (trimmedQuery != null) {
            if (selection.isNotEmpty()) selection.append(" AND ")
            selection.append("${Instances.TITLE} LIKE ? ESCAPE '\\'")
            arguments += "%${escapeLike(trimmedQuery.take(256))}%"
        }
        val projection = arrayOf(
            Instances.EVENT_ID,
            Instances.CALENDAR_ID,
            Instances.BEGIN,
            Instances.END,
            Instances.TITLE,
            Instances.ALL_DAY,
            Instances.EVENT_TIMEZONE,
            Instances.RRULE,
            Instances.ORIGINAL_INSTANCE_TIME,
            Instances.STATUS,
        )
        val rows = mutableListOf<CalendarEventRow>()
        var total = 0
        var capped = false
        try {
            resolver.query(
                uri,
                projection,
                selection.toString().ifEmpty { null },
                arguments.toTypedArray().ifEmpty { null },
                "${Instances.BEGIN} ASC, ${Instances._ID} ASC",
            )?.use { cursor ->
                val eventIndex = cursor.getColumnIndexOrThrow(Instances.EVENT_ID)
                val calendarIndex = cursor.getColumnIndexOrThrow(Instances.CALENDAR_ID)
                val beginIndex = cursor.getColumnIndexOrThrow(Instances.BEGIN)
                val endIndex = cursor.getColumnIndexOrThrow(Instances.END)
                val titleIndex = cursor.getColumnIndexOrThrow(Instances.TITLE)
                val allDayIndex = cursor.getColumnIndexOrThrow(Instances.ALL_DAY)
                val zoneIndex = cursor.getColumnIndexOrThrow(Instances.EVENT_TIMEZONE)
                val rruleIndex = cursor.getColumnIndexOrThrow(Instances.RRULE)
                val originalIndex = cursor.getColumnIndexOrThrow(Instances.ORIGINAL_INSTANCE_TIME)
                val statusIndex = cursor.getColumnIndexOrThrow(Instances.STATUS)
                while (cursor.moveToNext()) {
                    val status = if (cursor.isNull(statusIndex)) null else cursor.getInt(statusIndex)
                    if (status == Events.STATUS_CANCELED) continue
                    val eventID = cursor.getLong(eventIndex)
                    val rowCalendarID = cursor.getLong(calendarIndex)
                    if (eventID <= 0) continue
                    total += 1
                    if (total > MAX_SCAN) {
                        capped = true
                        break
                    }
                    if (total <= boundedOffset) continue
                    if (rows.size >= boundedLimit) continue
                    val begin = cursor.getLong(beginIndex)
                    val end = cursor.getLong(endIndex)
                    val allDay = !cursor.isNull(allDayIndex) && cursor.getInt(allDayIndex) != 0
                    rows += CalendarEventRow(
                        eventID = eventID,
                        calendarID = rowCalendarID,
                        calendarName = names[rowCalendarID] ?: "",
                        title = cursor.getString(titleIndex) ?: "",
                        startMillis = begin,
                        endMillis = end,
                        allDay = allDay,
                        timeZone = if (cursor.isNull(zoneIndex)) {
                            if (allDay) "UTC" else java.util.TimeZone.getDefault().id
                        } else {
                            cursor.getString(zoneIndex) ?: "UTC"
                        },
                        location = null,
                        notes = null,
                        recurrence = if (cursor.isNull(rruleIndex)) null else cursor.getString(rruleIndex),
                        originalInstanceTimeMillis = if (cursor.isNull(originalIndex)) null else cursor.getLong(originalIndex),
                        status = status,
                    )
                }
            }
        } catch (security: SecurityException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PERMISSION_DENIED,
                "calendar read permission is not granted",
                detail = security.message,
            )
        } catch (invalid: IllegalArgumentException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PROVIDER_REJECTED,
                "calendar provider rejected the instance query",
                detail = invalid.message,
            )
        }
        val hasMore = capped || total > boundedOffset + rows.size
        val totalCount = if (capped) MAX_SCAN else total
        return CalendarEventPageRow(rows, hasMore, totalCount)
    }

    override fun event(eventID: Long): CalendarEventRow {
        CalendarProviderRules.requireReadGrant(readGranted())
        return readEvent(eventID)
            ?: throw CalendarProviderFailure(
                CalendarProviderFailureCode.EVENT_NOT_FOUND,
                "calendar event no longer exists",
            )
    }

    private fun readEvent(eventID: Long): CalendarEventRow? {
        val names = readCalendarNames()
        val projection = arrayOf(
            Events._ID,
            Events.CALENDAR_ID,
            Events.TITLE,
            Events.DESCRIPTION,
            Events.EVENT_LOCATION,
            Events.DTSTART,
            Events.DTEND,
            Events.DURATION,
            Events.ALL_DAY,
            Events.EVENT_TIMEZONE,
            Events.RRULE,
            Events.ORIGINAL_INSTANCE_TIME,
            Events.STATUS,
            Events.DELETED,
        )
        try {
            resolver.query(
                Events.CONTENT_URI,
                projection,
                "${Events._ID} = ?",
                arrayOf(eventID.toString()),
                null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return null
                val idIndex = cursor.getColumnIndexOrThrow(Events._ID)
                val calendarIndex = cursor.getColumnIndexOrThrow(Events.CALENDAR_ID)
                val titleIndex = cursor.getColumnIndexOrThrow(Events.TITLE)
                val descriptionIndex = cursor.getColumnIndexOrThrow(Events.DESCRIPTION)
                val locationIndex = cursor.getColumnIndexOrThrow(Events.EVENT_LOCATION)
                val startIndex = cursor.getColumnIndexOrThrow(Events.DTSTART)
                val endIndex = cursor.getColumnIndexOrThrow(Events.DTEND)
                val durationIndex = cursor.getColumnIndexOrThrow(Events.DURATION)
                val allDayIndex = cursor.getColumnIndexOrThrow(Events.ALL_DAY)
                val zoneIndex = cursor.getColumnIndexOrThrow(Events.EVENT_TIMEZONE)
                val rruleIndex = cursor.getColumnIndexOrThrow(Events.RRULE)
                val originalIndex = cursor.getColumnIndexOrThrow(Events.ORIGINAL_INSTANCE_TIME)
                val statusIndex = cursor.getColumnIndexOrThrow(Events.STATUS)
                val deletedIndex = cursor.getColumnIndexOrThrow(Events.DELETED)
                val start = if (cursor.isNull(startIndex)) 0L else cursor.getLong(startIndex)
                val allDay = !cursor.isNull(allDayIndex) && cursor.getInt(allDayIndex) != 0
                val duration = if (cursor.isNull(durationIndex)) null else cursor.getString(durationIndex)
                val end = if (!cursor.isNull(endIndex)) {
                    cursor.getLong(endIndex)
                } else {
                    (parseDurationMillis(duration) ?: 3_600_000L) + start
                }
                val calendarID = cursor.getLong(calendarIndex)
                return CalendarEventRow(
                    eventID = cursor.getLong(idIndex),
                    calendarID = calendarID,
                    calendarName = names[calendarID] ?: "",
                    title = cursor.getString(titleIndex) ?: "",
                    startMillis = start,
                    endMillis = end,
                    allDay = allDay,
                    timeZone = if (cursor.isNull(zoneIndex)) {
                        if (allDay) "UTC" else java.util.TimeZone.getDefault().id
                    } else {
                        cursor.getString(zoneIndex) ?: "UTC"
                    },
                    location = if (cursor.isNull(locationIndex)) null else cursor.getString(locationIndex),
                    notes = if (cursor.isNull(descriptionIndex)) null else cursor.getString(descriptionIndex),
                    recurrence = if (cursor.isNull(rruleIndex)) null else cursor.getString(rruleIndex),
                    originalInstanceTimeMillis = if (cursor.isNull(originalIndex)) null else cursor.getLong(originalIndex),
                    status = if (cursor.isNull(statusIndex)) null else cursor.getInt(statusIndex),
                    deleted = !cursor.isNull(deletedIndex) && cursor.getInt(deletedIndex) != 0,
                )
            }
        } catch (security: SecurityException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PERMISSION_DENIED,
                "calendar read permission is not granted",
                detail = security.message,
            )
        } catch (invalid: IllegalArgumentException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PROVIDER_REJECTED,
                "calendar provider rejected the event query",
                detail = invalid.message,
            )
        }
        return null
    }

    // MARK: Write

    override fun create(request: CalendarCreateRequest): CalendarReceiptRow {
        CalendarProviderRules.requireWriteGrant(writeGranted())
        val calendar = writableCalendar(request.calendarID)
        val title = CalendarProviderRules.boundedTitle(request.title)
        if (request.endMillis <= request.startMillis) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_RANGE,
                "calendar end must follow start",
            )
        }
        val allDay = request.allDay
        val zone = effectiveZone(allDay, request.timeZone)
        if (allDay) {
            CalendarProviderRules.requireAllDayUtcMidnight(request.startMillis)
            CalendarProviderRules.requireAllDayUtcMidnight(request.endMillis)
        }
        val recurrence = CalendarProviderRules.canonicalRecurrence(request.recurrence)
            ?.takeIf { it.isNotEmpty() }
        val values = ContentValues().apply {
            put(Events.CALENDAR_ID, calendar.id)
            put(Events.TITLE, title)
            put(Events.ALL_DAY, if (allDay) 1 else 0)
            put(Events.EVENT_TIMEZONE, zone)
            put(Events.EVENT_END_TIMEZONE, zone)
            put(Events.DTSTART, request.startMillis)
            put(Events.DTEND, request.endMillis)
            CalendarProviderRules.boundedText(
                request.notes,
                8_192,
                CalendarProviderFailureCode.INVALID_FIELDS,
                "notes",
            )?.let { put(Events.DESCRIPTION, it) }
            CalendarProviderRules.boundedText(
                request.location,
                512,
                CalendarProviderFailureCode.INVALID_FIELDS,
                "location",
            )?.let { put(Events.EVENT_LOCATION, it) }
            if (recurrence != null) {
                put(Events.RRULE, recurrence)
                put(
                    Events.DURATION,
                    if (allDay) {
                        CalendarProviderRules.allDayDurationForRecurring(
                            request.startMillis,
                            request.endMillis,
                        )
                    } else {
                        CalendarProviderRules.durationForRecurring(
                            request.startMillis,
                            request.endMillis,
                        )
                    },
                )
            }
        }
        val uri = try {
            resolver.insert(Events.CONTENT_URI, values)
        } catch (security: SecurityException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.WRITE_PERMISSION_DENIED,
                "calendar write permission is not granted",
                detail = security.message,
            )
        } catch (invalid: IllegalArgumentException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PROVIDER_REJECTED,
                "calendar provider rejected the event",
                detail = invalid.message,
            )
        } ?: throw CalendarProviderFailure(
            CalendarProviderFailureCode.PROVIDER_REJECTED,
            "calendar provider returned no row for the new event",
        )
        val eventID = ContentUris.parseId(uri)
        val actual = readEvent(eventID)
        val fields = actual?.let {
            CalendarProviderRules.readbackFields(
                expectedEventID = eventID,
                expectedCalendarID = calendar.id,
                expectedTitle = title,
                expectedStartMinutes = request.startMillis / 60_000L,
                expectedEndMinutes = request.endMillis / 60_000L,
                expectedAllDay = allDay,
                expectedTimeZone = zone,
                expectedRecurrence = recurrence,
                actual = it,
            )
        }
        if (fields == null) {
            // The insert is real but unverified. Remove only this newly created
            // row; if even that fails the caller sees an explicit mismatch.
            runCatching {
                resolver.delete(
                    ContentUris.withAppendedId(Events.CONTENT_URI, eventID),
                    null,
                    null,
                )
            }
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.READBACK_MISMATCH,
                "calendar did not return the written event fields",
            )
        }
        verifyOccurrence(eventID, request.startMillis, mustExist = true)
        return CalendarReceiptRow(
            action = "create",
            eventID = eventID,
            calendarID = calendar.id,
            occurrenceStartMillis = request.startMillis,
            deleted = false,
            readbackVerified = true,
            verificationScope = "targetOccurrence",
            verifiedFields = fields,
        )
    }

    override fun update(request: CalendarUpdateRequest): CalendarReceiptRow {
        CalendarProviderRules.requireWriteGrant(writeGranted())
        if (request.patch.isEmpty) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_FIELDS,
                "no event fields were supplied",
            )
        }
        val span = CalendarProviderRules.canonicalSpan(request.span)
        val original = readEvent(request.eventID)
            ?: throw CalendarProviderFailure(
                CalendarProviderFailureCode.EVENT_NOT_FOUND,
                "calendar event no longer exists",
            )
        if (original.deleted) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.EVENT_NOT_FOUND,
                "calendar event is deleted",
            )
        }
        validatePatch(request.patch)
        val occurrence = request.occurrenceStartMillis
        if (original.detached) {
            if (occurrence == null) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.OCCURRENCE_REQUIRED,
                    "a detached event requires the exact occurrence token",
                )
            }
            if (span == "futureEvents") {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.UNSUPPORTED_SPAN,
                    "a detached occurrence has no future series",
                )
            }
            val originalStart = original.originalInstanceTimeMillis ?: original.startMillis
            val matchesOriginal = Math.floorDiv(occurrence, 1_000L) ==
                Math.floorDiv(originalStart, 1_000L)
            val matchesCurrent = Math.floorDiv(occurrence, 1_000L) ==
                Math.floorDiv(original.startMillis, 1_000L)
            if (!matchesOriginal && !matchesCurrent) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.STALE_OCCURRENCE,
                    "the detached occurrence no longer matches",
                )
            }
            // A detached row already represents one occurrence. Update that
            // row directly; creating a nested exception would corrupt the
            // series identity and readback.
            return updateSingle(original, request.patch)
        }
        if (original.recurring) {
            if (occurrence == null) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.OCCURRENCE_REQUIRED,
                    "a recurring event requires the exact occurrence token",
                )
            }
            verifyOccurrence(original.eventID, occurrence, mustExist = true)
            return if (span == "futureEvents") {
                splitFuture(original, occurrence, request.patch)
            } else {
                writeException(original, occurrence, request.patch, cancel = false)
            }
        }
        if (occurrence != null &&
            Math.floorDiv(occurrence, 1_000L) != Math.floorDiv(original.startMillis, 1_000L)
        ) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.STALE_OCCURRENCE,
                "the occurrence start no longer matches this event",
            )
        }
        return updateSingle(original, request.patch)
    }

    override fun delete(request: CalendarDeleteRequest): CalendarReceiptRow {
        CalendarProviderRules.requireWriteGrant(writeGranted())
        val span = CalendarProviderRules.canonicalSpan(request.span)
        val original = readEvent(request.eventID)
            ?: throw CalendarProviderFailure(
                CalendarProviderFailureCode.EVENT_NOT_FOUND,
                "calendar event no longer exists",
            )
        val occurrence = request.occurrenceStartMillis
        if (!original.recurring) {
            deleteRow(original.eventID)
            verifyOccurrence(original.eventID, original.startMillis, mustExist = false)
            if (readEvent(original.eventID) != null) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.READBACK_MISMATCH,
                    "calendar event still exists after delete",
                )
            }
            return CalendarReceiptRow(
                action = "delete",
                eventID = original.eventID,
                calendarID = original.calendarID,
                occurrenceStartMillis = original.startMillis,
                deleted = true,
                readbackVerified = true,
                verificationScope = "targetOccurrence",
                verifiedFields = listOf("id", "deleted"),
            )
        }
        if (original.detached) {
            if (occurrence == null) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.OCCURRENCE_REQUIRED,
                    "a detached occurrence requires the exact occurrence token",
                )
            }
            if (span == "futureEvents") {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.UNSUPPORTED_SPAN,
                    "a detached occurrence has no future series",
                )
            }
            val originalStart = original.originalInstanceTimeMillis ?: original.startMillis
            val matchesOriginal = Math.floorDiv(occurrence, 1_000L) ==
                Math.floorDiv(originalStart, 1_000L)
            val matchesCurrent = Math.floorDiv(occurrence, 1_000L) ==
                Math.floorDiv(original.startMillis, 1_000L)
            if (!matchesOriginal && !matchesCurrent) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.STALE_OCCURRENCE,
                    "the detached occurrence no longer matches",
                )
            }
            updateRow(original.eventID, ContentValues().apply {
                put(Events.STATUS, Events.STATUS_CANCELED)
            })
            val canceled = readEvent(original.eventID)
            if (canceled == null || canceled.status != Events.STATUS_CANCELED) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.READBACK_MISMATCH,
                    "calendar did not keep the canceled detached occurrence",
                )
            }
            verifyOccurrence(original.eventID, original.startMillis, mustExist = false)
            return CalendarReceiptRow(
                action = "delete",
                eventID = original.eventID,
                calendarID = original.calendarID,
                occurrenceStartMillis = originalStart,
                deleted = true,
                readbackVerified = true,
                verificationScope = "targetOccurrence",
                verifiedFields = listOf("id", "status", "occurrence"),
            )
        }
        if (occurrence == null) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.OCCURRENCE_REQUIRED,
                "a recurring event requires the exact occurrence token",
            )
        }
        verifyOccurrence(original.eventID, occurrence, mustExist = true)
        if (span == "futureEvents") {
            if (occurrence <= original.startMillis) {
                deleteRow(original.eventID)
                if (readEvent(original.eventID) != null) {
                    throw CalendarProviderFailure(
                        CalendarProviderFailureCode.READBACK_MISMATCH,
                        "calendar series still exists after delete",
                    )
                }
                return CalendarReceiptRow(
                    action = "delete",
                    eventID = original.eventID,
                    calendarID = original.calendarID,
                    occurrenceStartMillis = occurrence,
                    deleted = true,
                    readbackVerified = true,
                    verificationScope = "futureSeries",
                    verifiedFields = listOf("id", "deleted"),
                )
            }
            val until = occurrence - 1_000L
            val recurrence = CalendarProviderRules.rruleWithUntil(
                original.recurrence ?: "",
                until,
            )
            updateRow(original.eventID, ContentValues().apply {
                put(Events.RRULE, recurrence)
            })
            val actual = readEvent(original.eventID)
                ?: throw CalendarProviderFailure(
                    CalendarProviderFailureCode.READBACK_MISMATCH,
                    "calendar series disappeared after the split",
                )
            if ((actual.recurrence ?: "") != recurrence) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.READBACK_MISMATCH,
                    "calendar series did not keep the bounded RRULE",
                )
            }
            verifyOccurrence(original.eventID, occurrence, mustExist = false)
            return CalendarReceiptRow(
                action = "delete",
                eventID = original.eventID,
                calendarID = original.calendarID,
                occurrenceStartMillis = occurrence,
                deleted = true,
                readbackVerified = true,
                verificationScope = "futureSeries",
                verifiedFields = listOf("id", "recurrence"),
            )
        }
        return writeException(original, occurrence, CalendarPatch(), cancel = true)
    }

    // MARK: Single event

    private fun updateSingle(
        original: CalendarEventRow,
        patch: CalendarPatch,
    ): CalendarReceiptRow {
        val merged = merge(original, patch, forcedStart = null)
        val values = valuesFor(merged)
        updateRow(original.eventID, values)
        val actual = readEvent(original.eventID)
        val fields = actual?.let {
            CalendarProviderRules.readbackFields(
                expectedEventID = original.eventID,
                expectedCalendarID = merged.calendarID,
                expectedTitle = merged.title,
                expectedStartMinutes = merged.startMillis / 60_000L,
                expectedEndMinutes = merged.endMillis / 60_000L,
                expectedAllDay = merged.allDay,
                expectedTimeZone = merged.timeZone,
                expectedRecurrence = merged.recurrence?.takeIf { it.isNotEmpty() },
                actual = it,
            )
        } ?: throw CalendarProviderFailure(
            CalendarProviderFailureCode.READBACK_MISMATCH,
            "calendar did not return the updated event",
        )
        if (!original.detached) {
            // Instances address a series/exception through the provider's
            // computed EVENT_ID. A detached row's own ID is already verified
            // by the row read-back above; re-querying Instances can report the
            // parent series id instead and would be a false negative.
            verifyOccurrence(original.eventID, merged.startMillis, mustExist = true)
        }
        return CalendarReceiptRow(
            action = "update",
            eventID = original.eventID,
            calendarID = merged.calendarID,
            occurrenceStartMillis = merged.startMillis,
            deleted = false,
            readbackVerified = true,
            verificationScope = "targetOccurrence",
            verifiedFields = fields,
        )
    }

    // MARK: Exception (single occurrence)

    private fun writeException(
        original: CalendarEventRow,
        occurrenceStart: Long,
        patch: CalendarPatch,
        cancel: Boolean,
    ): CalendarReceiptRow {
        if (!cancel && patch.recurrence != null) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.UNSUPPORTED_RECURRENCE,
                "changing recurrence for a single occurrence is not supported; use futureEvents",
            )
        }
        val merged = merge(original, patch, forcedStart = occurrenceStart)
        val values = ContentValues().apply {
            put(Events.CALENDAR_ID, original.calendarID)
            put(Events.TITLE, merged.title)
            put(Events.ALL_DAY, if (merged.allDay) 1 else 0)
            put(Events.EVENT_TIMEZONE, merged.timeZone)
            put(Events.EVENT_END_TIMEZONE, merged.timeZone)
            put(Events.DTSTART, merged.startMillis)
            put(Events.DTEND, merged.endMillis)
            put(Events.ORIGINAL_ID, original.eventID.toString())
            put(Events.ORIGINAL_INSTANCE_TIME, occurrenceStart)
            put(Events.STATUS, if (cancel) Events.STATUS_CANCELED else Events.STATUS_CONFIRMED)
            if (merged.notes != null) put(Events.DESCRIPTION, merged.notes)
            if (merged.location != null) put(Events.EVENT_LOCATION, merged.location)
        }
        val existing = readException(original.eventID, occurrenceStart)
        val exceptionID: Long
        if (existing != null) {
            // Repeated edits of the same occurrence must update the ONE
            // detached row, never create a second exception for the same
            // original instance.
            exceptionID = existing.eventID
            updateRow(exceptionID, values)
        } else {
            val uri = insert(values)
            exceptionID = ContentUris.parseId(uri)
        }
        val actual = readException(original.eventID, occurrenceStart)
        val fields = if (actual == null) null else mutableListOf("id", "originalID", "occurrence")
            .apply {
                if (!cancel) {
                    val verified = CalendarProviderRules.readbackFields(
                        expectedEventID = exceptionID,
                        expectedCalendarID = original.calendarID,
                        expectedTitle = merged.title,
                        expectedStartMinutes = merged.startMillis / 60_000L,
                        expectedEndMinutes = merged.endMillis / 60_000L,
                        expectedAllDay = merged.allDay,
                        expectedTimeZone = merged.timeZone,
                        expectedRecurrence = null,
                        actual = actual,
                    )
                    if (verified == null) {
                        // Never delete a pre-existing exception when provider
                        // readback fails after an update. Keep it for review.
                        if (existing == null) runCatching { deleteRow(exceptionID) }
                        throw CalendarProviderFailure(
                            CalendarProviderFailureCode.READBACK_MISMATCH,
                            "calendar did not return the detached occurrence fields",
                        )
                    }
                    addAll(verified)
                } else if (actual.status != Events.STATUS_CANCELED) {
                    throw CalendarProviderFailure(
                        CalendarProviderFailureCode.READBACK_MISMATCH,
                        "calendar did not keep the canceled occurrence",
                    )
                }
            }
        if (fields == null) {
            if (existing == null) runCatching { deleteRow(exceptionID) }
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.READBACK_MISMATCH,
                "calendar did not create the exception row",
            )
        }
        if (cancel) {
            // The old instance must be gone from the computed Instances table.
            verifyOccurrence(original.eventID, occurrenceStart, mustExist = false)
            return CalendarReceiptRow(
                action = "delete",
                eventID = original.eventID,
                calendarID = original.calendarID,
                occurrenceStartMillis = occurrenceStart,
                deleted = true,
                readbackVerified = true,
                verificationScope = "targetOccurrence",
                verifiedFields = fields,
            )
        }
        return CalendarReceiptRow(
            action = "update",
            eventID = exceptionID,
            calendarID = original.calendarID,
            occurrenceStartMillis = merged.startMillis,
            deleted = false,
            readbackVerified = true,
            verificationScope = "targetOccurrence",
            verifiedFields = fields,
        )
    }

    // MARK: Future split

    private fun splitFuture(
        original: CalendarEventRow,
        occurrenceStart: Long,
        patch: CalendarPatch,
    ): CalendarReceiptRow {
        val recurrence = CalendarProviderRules.canonicalRecurrence(original.recurrence)
            ?.takeIf { it.isNotEmpty() }
            ?: throw CalendarProviderFailure(
                CalendarProviderFailureCode.UNSUPPORTED_RECURRENCE,
                "the future split requires a recurring series",
            )
        if (CalendarProviderRules.rruleHasCount(recurrence)) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.UNSUPPORTED_RECURRENCE,
                "splitting a COUNT-bounded recurrence is ambiguous; edit the series instead",
            )
        }
        if (patch.startMillis != null &&
            Math.floorDiv(patch.startMillis, 1_000L) != Math.floorDiv(occurrenceStart, 1_000L)
        ) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_FIELDS,
                "futureEvents cannot move the split boundary",
            )
        }
        // From the first occurrence this is the whole series: no split needed.
        if (occurrenceStart <= original.startMillis) {
            return updateSingle(original, patch)
        }
        val merged = merge(original, patch, forcedStart = occurrenceStart)
        val until = occurrenceStart - 1_000L
        val oldRecurrence = CalendarProviderRules.rruleWithUntil(recurrence, until)
        val newRecurrence = CalendarProviderRules.canonicalRecurrence(
            patch.recurrence ?: recurrence,
        )?.takeIf { it.isNotEmpty() } ?: recurrence
        val newValues = valuesFor(merged, recurrence = newRecurrence, durationRecurring = true).apply {
            put(Events.CALENDAR_ID, merged.calendarID)
        }
        val operations = arrayListOf(
            ContentProviderOperation.newUpdate(Events.CONTENT_URI)
                .withSelection("${Events._ID} = ?", arrayOf(original.eventID.toString()))
                .withValues(ContentValues().apply { put(Events.RRULE, oldRecurrence) })
                .build(),
            ContentProviderOperation.newInsert(Events.CONTENT_URI)
                .withValues(newValues)
                .build(),
        )
        val results = try {
            resolver.applyBatch(CalendarContract.AUTHORITY, operations)
        } catch (security: SecurityException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.WRITE_PERMISSION_DENIED,
                "calendar write permission is not granted",
                detail = security.message,
            )
        } catch (failure: Exception) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PROVIDER_REJECTED,
                "calendar rejected the atomic future split",
                detail = failure.message,
            )
        }
        val newUri = results.getOrNull(1)?.uri
            ?: throw CalendarProviderFailure(
                CalendarProviderFailureCode.PROVIDER_REJECTED,
                "calendar returned no row for the future split",
            )
        val newID = ContentUris.parseId(newUri)
        val oldActual = readEvent(original.eventID)
        val newActual = readEvent(newID)
        val fields = newActual?.let {
            CalendarProviderRules.readbackFields(
                expectedEventID = newID,
                expectedCalendarID = merged.calendarID,
                expectedTitle = merged.title,
                expectedStartMinutes = occurrenceStart / 60_000L,
                expectedEndMinutes = merged.endMillis / 60_000L,
                expectedAllDay = merged.allDay,
                expectedTimeZone = merged.timeZone,
                expectedRecurrence = newRecurrence,
                actual = it,
            )
        }
        if (fields == null || oldActual == null || (oldActual.recurrence ?: "") != oldRecurrence) {
            // The provider already committed BOTH rows atomically. Deleting
            // the future row alone would lose the remaining occurrences while
            // leaving the original series truncated. Preserve both for review.
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.READBACK_MISMATCH,
                "calendar changes were kept but could not be verified; review the series before retrying",
            )
        }
        verifyOccurrence(newID, occurrenceStart, mustExist = true)
        return CalendarReceiptRow(
            action = "update",
            eventID = newID,
            calendarID = merged.calendarID,
            occurrenceStartMillis = occurrenceStart,
            deleted = false,
            readbackVerified = true,
            verificationScope = "futureSeries",
            verifiedFields = fields,
        )
    }

    // MARK: Field helpers

    private fun merge(
        original: CalendarEventRow,
        patch: CalendarPatch,
        forcedStart: Long?,
    ): CalendarEventRow {
        val start = patch.startMillis ?: forcedStart ?: original.startMillis
        val duration = patch.endMillis?.minus(start)
            ?: patch.startMillis?.let { original.endMillis - original.startMillis }
            ?: (original.endMillis - original.startMillis)
        val end = patch.endMillis ?: (start + duration)
        val allDay = patch.allDay ?: original.allDay
        val zone = effectiveZone(allDay, patch.timeZone ?: original.timeZone)
        if (end <= start) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_RANGE,
                "calendar end must follow start",
            )
        }
        if (allDay) {
            CalendarProviderRules.requireAllDayUtcMidnight(start)
            CalendarProviderRules.requireAllDayUtcMidnight(end)
        }
        val title = patch.title?.let(CalendarProviderRules::boundedTitle) ?: original.title
        val notes = if (patch.notes != null) {
            CalendarProviderRules.boundedText(
                patch.notes, 8_192, CalendarProviderFailureCode.INVALID_FIELDS, "notes",
            )
        } else {
            original.notes
        }
        val location = if (patch.location != null) {
            CalendarProviderRules.boundedText(
                patch.location, 512, CalendarProviderFailureCode.INVALID_FIELDS, "location",
            )
        } else {
            original.location
        }
        return original.copy(
            title = title,
            startMillis = start,
            endMillis = end,
            allDay = allDay,
            timeZone = zone,
            notes = notes,
            location = location,
            recurrence = patch.recurrence ?: original.recurrence,
        )
    }

    private fun valuesFor(
        event: CalendarEventRow,
        recurrence: String? = event.recurrence?.takeIf { it.isNotEmpty() },
        durationRecurring: Boolean = false,
    ): ContentValues = ContentValues().apply {
        put(Events.TITLE, event.title)
        put(Events.ALL_DAY, if (event.allDay) 1 else 0)
        put(Events.EVENT_TIMEZONE, event.timeZone)
        put(Events.EVENT_END_TIMEZONE, event.timeZone)
        put(Events.DTSTART, event.startMillis)
        put(Events.DTEND, event.endMillis)
        if (event.notes.isNullOrEmpty()) putNull(Events.DESCRIPTION) else put(Events.DESCRIPTION, event.notes)
        if (event.location.isNullOrEmpty()) putNull(Events.EVENT_LOCATION) else put(Events.EVENT_LOCATION, event.location)
        if (recurrence.isNullOrEmpty()) {
            putNull(Events.RRULE)
            putNull(Events.DURATION)
        } else {
            put(Events.RRULE, recurrence)
            put(
                Events.DURATION,
                if (event.allDay) {
                    CalendarProviderRules.allDayDurationForRecurring(event.startMillis, event.endMillis)
                } else {
                    CalendarProviderRules.durationForRecurring(event.startMillis, event.endMillis)
                },
            )
        }
    }

    private fun validatePatch(patch: CalendarPatch) {
        if (patch.title != null) CalendarProviderRules.boundedTitle(patch.title)
        if (patch.startMillis != null && patch.endMillis != null &&
            patch.endMillis <= patch.startMillis
        ) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_RANGE,
                "calendar end must follow start",
            )
        }
        if (patch.allDay == true) {
            patch.startMillis?.let(CalendarProviderRules::requireAllDayUtcMidnight)
            patch.endMillis?.let(CalendarProviderRules::requireAllDayUtcMidnight)
        }
        patch.timeZone?.let { zone ->
            if (CalendarProviderRules.validTimeZone(zone) == null) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.INVALID_TIMEZONE,
                    "invalid event timezone",
                )
            }
        }
        CalendarProviderRules.canonicalRecurrence(patch.recurrence)
    }

    private fun effectiveZone(allDay: Boolean, requested: String?): String {
        if (allDay) return "UTC"
        return CalendarProviderRules.validTimeZone(requested)
            ?: throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_TIMEZONE,
                "invalid event timezone",
            )
    }

    private fun writableCalendar(calendarID: Long): CalendarSummaryRow {
        if (calendarID <= 0) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.CALENDAR_MISSING,
                "an explicit writable calendar is required",
            )
        }
        val calendar = readCalendars().firstOrNull { it.id == calendarID }
            ?: throw CalendarProviderFailure(
                CalendarProviderFailureCode.CALENDAR_MISSING,
                "the selected calendar no longer exists",
            )
        if (!calendar.writable) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.CALENDAR_NOT_WRITABLE,
                "the selected calendar is read-only; choose another calendar",
            )
        }
        return calendar
    }

    private fun readCalendarNames(): Map<Long, String> =
        try {
            readCalendars().associate { it.id to it.displayName }
        } catch (_: CalendarProviderFailure) {
            emptyMap()
        }

    private fun readException(originalID: Long, occurrenceStart: Long): CalendarEventRow? {
        val projection = arrayOf(
            Events._ID,
            Events.CALENDAR_ID,
            Events.TITLE,
            Events.DESCRIPTION,
            Events.EVENT_LOCATION,
            Events.DTSTART,
            Events.DTEND,
            Events.DURATION,
            Events.ALL_DAY,
            Events.EVENT_TIMEZONE,
            Events.STATUS,
            Events.ORIGINAL_ID,
            Events.ORIGINAL_INSTANCE_TIME,
        )
        resolver.query(
            Events.CONTENT_URI,
            projection,
            "${Events.ORIGINAL_ID} = ? AND ${Events.ORIGINAL_INSTANCE_TIME} = ?",
            arrayOf(originalID.toString(), occurrenceStart.toString()),
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return null
            return readEvent(cursor.getLong(cursor.getColumnIndexOrThrow(Events._ID)))
        }
        return null
    }

    private fun verifyOccurrence(eventID: Long, startMillis: Long, mustExist: Boolean) {
        val begin = startMillis - 2_000L
        val end = startMillis + 2_000L
        val uri = Instances.CONTENT_URI.buildUpon()
            .appendPath(begin.toString())
            .appendPath(end.toString())
            .build()
        val projection = arrayOf(Instances.EVENT_ID, Instances.BEGIN, Instances.STATUS)
        var matched = 0
        try {
            resolver.query(
                uri,
                projection,
                "${Instances.EVENT_ID} = ?",
                arrayOf(eventID.toString()),
                null,
            )?.use { cursor ->
                val beginIndex = cursor.getColumnIndexOrThrow(Instances.BEGIN)
                val statusIndex = cursor.getColumnIndexOrThrow(Instances.STATUS)
                while (cursor.moveToNext()) {
                    val status = if (cursor.isNull(statusIndex)) null else cursor.getInt(statusIndex)
                    if (status == Events.STATUS_CANCELED) continue
                    val cursorBegin = cursor.getLong(beginIndex)
                    if (Math.floorDiv(cursorBegin, 1_000L) == Math.floorDiv(startMillis, 1_000L)) {
                        matched += 1
                    }
                }
            }
        } catch (security: SecurityException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PERMISSION_DENIED,
                "calendar read permission is not granted",
                detail = security.message,
            )
        }
        if (mustExist && matched == 0) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.OCCURRENCE_NOT_FOUND,
                "the selected occurrence no longer exists in the provider",
            )
        }
        if (!mustExist && matched > 0) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.READBACK_MISMATCH,
                "the occurrence is still present after the write",
            )
        }
    }

    private fun insert(values: ContentValues): Uri {
        return try {
            resolver.insert(Events.CONTENT_URI, values)
        } catch (security: SecurityException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.WRITE_PERMISSION_DENIED,
                "calendar write permission is not granted",
                detail = security.message,
            )
        } catch (invalid: IllegalArgumentException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PROVIDER_REJECTED,
                "calendar rejected the event values",
                detail = invalid.message,
            )
        } ?: throw CalendarProviderFailure(
            CalendarProviderFailureCode.PROVIDER_REJECTED,
            "calendar provider returned no row",
        )
    }

    private fun updateRow(eventID: Long, values: ContentValues) {
        try {
            val changed = resolver.update(
                ContentUris.withAppendedId(Events.CONTENT_URI, eventID),
                values,
                null,
                null,
            )
            if (changed != 1) {
                throw CalendarProviderFailure(
                    CalendarProviderFailureCode.PROVIDER_REJECTED,
                    "calendar did not update the event row",
                )
            }
        } catch (security: SecurityException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.WRITE_PERMISSION_DENIED,
                "calendar write permission is not granted",
                detail = security.message,
            )
        } catch (invalid: IllegalArgumentException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PROVIDER_REJECTED,
                "calendar rejected the event update",
                detail = invalid.message,
            )
        }
    }

    private fun deleteRow(eventID: Long) {
        try {
            resolver.delete(
                ContentUris.withAppendedId(Events.CONTENT_URI, eventID),
                null,
                null,
            )
        } catch (security: SecurityException) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.WRITE_PERMISSION_DENIED,
                "calendar write permission is not granted",
                detail = security.message,
            )
        }
    }

    private fun validateRange(startMillis: Long, endMillis: Long) {
        if (endMillis <= startMillis) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_RANGE,
                "calendar range must be positive",
            )
        }
        if (endMillis - startMillis > 366L * 86_400_000L) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_RANGE,
                "calendar range must not exceed 366 days",
            )
        }
    }

    private fun escapeLike(raw: String): String = raw
        .replace("\\", "\\\\")
        .replace("%", "\\%")
        .replace("_", "\\_")

    private fun parseDurationMillis(raw: String?): Long? {
        if (raw == null) return null
        Regex("^P(\\d+)([SDW])$").matchEntire(raw)?.let { match ->
            val value = match.groupValues[1].toLongOrNull() ?: return null
            return when (match.groupValues[2]) {
                "S" -> value * 1_000L
                "D" -> value * 86_400_000L
                "W" -> value * 7L * 86_400_000L
                else -> null
            }
        }
        Regex("^PT(\\d+)([HM])$").matchEntire(raw)?.let { match ->
            val value = match.groupValues[1].toLongOrNull() ?: return null
            return if (match.groupValues[2] == "H") value * 3_600_000L else value * 60_000L
        }
        return null
    }

    private companion object {
        const val MAX_SCAN = 5_000
    }
}
