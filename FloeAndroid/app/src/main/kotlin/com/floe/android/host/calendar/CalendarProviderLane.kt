// SPDX-License-Identifier: MPL-2.0
//
// App-owned C06 calendar provider lane. Swift owns the bounded ticket table
// and every model/domain decision; this lane only claims one JSON ticket at a
// time, executes the real CalendarContract operation (or the owned reminder
// AlarmManager action), and completes the ticket exactly once.
//
// There is no model command, no shell, no arbitrary provider URI and no
// second scheduler here. Root retirement parks the lane, joins the poller and
// acknowledges `laneClosed(epoch)` so the old Swift mailbox can drain.

package com.floe.android.host.calendar

import android.util.Log
import com.floe.android.core.calendar.CalendarCreateRequest
import com.floe.android.core.calendar.CalendarDeleteRequest
import com.floe.android.core.calendar.CalendarEventRow
import com.floe.android.core.calendar.CalendarPatch
import com.floe.android.core.calendar.CalendarProviderBackend
import com.floe.android.core.calendar.CalendarProviderFailure
import com.floe.android.core.calendar.CalendarProviderFailureCode
import com.floe.android.core.calendar.CalendarReceiptRow
import com.floe.android.core.calendar.CalendarSnapshotRow
import com.floe.android.core.calendar.CalendarUpdateRequest
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

internal data class TodoReminderArmUi(
    val scheduled: Boolean,
    val state: String,
    val reason: String?,
)

internal interface TodoReminderTransport {
    fun arm(
        todoID: String,
        reminderAtMillis: Long,
        dueAtMillis: Long,
        occurrenceKey: String,
        allDay: Boolean,
        timeZone: String,
    ): TodoReminderArmUi

    fun disarm(todoID: String)
}

internal class CalendarProviderLane(
    private val scope: CoroutineScope,
    private val backend: CalendarProviderBackend,
    private val reminders: TodoReminderTransport,
    private val bridge: CalendarHostBridge = PlatformCalendarHostBridge,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val log: (String) -> Unit = { message ->
        Log.println(Log.DEBUG, "FloeC06Calendar", message)
    },
) {
    private val running = AtomicBoolean(false)
    private var pollJob: Job? = null

    @Volatile
    private var epoch: Long = 0L

    val isRunning: Boolean get() = running.get()

    fun start(boundEpoch: Long): Boolean {
        if (boundEpoch <= 0L) return false
        if (!running.compareAndSet(false, true)) return epoch == boundEpoch
        epoch = boundEpoch
        if (bridge.bind(boundEpoch) != 0) {
            running.set(false)
            epoch = 0
            return false
        }
        if (bridge.laneReady(boundEpoch) != 0) {
            running.set(false)
            epoch = 0
            return false
        }
        pollJob = scope.launch(ioDispatcher) { pollLoop(boundEpoch) }
        return true
    }

    /** Returns true only when the poller ended and the mailbox saw the exact
     *  generation acknowledgement. */
    fun stop(timeoutMillis: Int): Boolean {
        val wasRunning = running.getAndSet(false)
        pollJob?.cancel()
        val finished = runBlocking {
            withTimeoutOrNull(timeoutMillis.coerceIn(250, 10_000).toLong()) {
                pollJob?.join()
                true
            } ?: false
        }
        pollJob = null
        val boundEpoch = epoch
        epoch = 0
        if (boundEpoch > 0L) bridge.laneClosed(boundEpoch)
        return finished || !wasRunning
    }

    private suspend fun pollLoop(boundEpoch: Long) {
        try {
            while (running.get() && scope.isActive) {
                val claim = bridge.next(250)
                if (claim == -1L) break
                if (claim <= 0L) continue
                handle(claim, boundEpoch)
            }
        } finally {
            running.set(false)
            bridge.laneClosed(boundEpoch)
        }
    }

    private suspend fun handle(claim: Long, boundEpoch: Long) {
        if (!running.get() || bridge.shouldStop(claim)) {
            bridge.complete(claim, STATUS_CANCELLED, null)
            return
        }
        val text = try {
            bridge.describe(claim)?.let { String(it, Charsets.UTF_8) }
        } catch (_: Throwable) {
            null
        }
        val request = text?.let { runCatching { JSONObject(it) }.getOrNull() }
        if (request == null) {
            completeJson(claim, STATUS_SHAPE, error("invalidRequest", "invalidHostRequest"))
            return
        }
        try {
            val claimEpoch = request.optLong("claimEpoch", -1L)
            if (claimEpoch != boundEpoch || epoch != boundEpoch) {
                completeJson(claim, STATUS_GENERATION, error("staleEpoch", "staleNativeEpoch"))
                return
            }
            val operation = request.optString("operation", "")
            val response = when (operation) {
                "calendars" -> calendars()
                "instances" -> instances(request)
                "event" -> event(request)
                "create" -> create(request)
                "update" -> update(request)
                "delete" -> delete(request)
                "armReminder" -> armReminder(request)
                "disarmReminder" -> disarmReminder(request)
                else -> throw CalendarProviderFailure(
                    CalendarProviderFailureCode.PROVIDER_REJECTED,
                    "unsupported provider operation",
                )
            }
            completeJson(claim, STATUS_OK, response)
        } catch (cancelled: CancellationException) {
            bridge.complete(claim, STATUS_CANCELLED, null)
            throw cancelled
        } catch (failure: CalendarProviderFailure) {
            completeJson(claim, STATUS_OK, failure(failure))
        } catch (throwable: Throwable) {
            log("calendar operation failed: ${throwable.javaClass.simpleName}")
            completeJson(
                claim,
                STATUS_OK,
                error(
                    "internalFailure",
                    "calendarOperationFailed",
                    retryable = false,
                    detail = throwable.message?.take(160),
                ),
            )
        }
    }

    private fun completeJson(claim: Long, status: Int, value: JSONObject) {
        val bytes = value.toString().toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_REPLY_BYTES) {
            bridge.complete(
                claim,
                status,
                error("responseTooLarge", "providerReplyTooLarge").toString().toByteArray(Charsets.UTF_8),
            )
            return
        }
        bridge.complete(claim, status, bytes)
    }

    // MARK: Providers

    private fun calendars(): JSONObject {
        val snapshot = backend.snapshot()
        return snapshotJson(snapshot)
    }

    private fun instances(request: JSONObject): JSONObject {
        val start = requiredLong(request, "startMillis")
        val end = requiredLong(request, "endMillis")
        val limit = request.optInt("limit", 100)
        val offset = request.optInt("offset", 0)
        val calendarID = optionalLong(request, "calendarID")
        val query = request.optString("query", "").takeIf { it.isNotBlank() }
        val page = backend.instances(start, end, calendarID, query, limit, offset)
        val rows = JSONArray()
        var encodedBytes = 0
        var trimmed = false
        for (row in page.rows) {
            val value = eventJson(row)
            val rowBytes = value.toString().toByteArray(Charsets.UTF_8).size
            if (rows.length() > 0 && encodedBytes + rowBytes > REPLY_ROW_BUDGET) {
                // The mailbox reply is bounded. Return a shorter page and
                // report hasMore; the caller's next offset advances by the
                // rows actually returned, so nothing is skipped or reordered.
                trimmed = true
                break
            }
            rows.put(value)
            encodedBytes += rowBytes
        }
        return JSONObject().apply {
            put("ok", true)
            put("schema", HOST_SCHEMA)
            put("rows", rows)
            put("hasMore", page.hasMore || trimmed)
            put("totalCount", page.totalCount)
        }
    }

    private fun event(request: JSONObject): JSONObject {
        val eventID = requiredLong(request, "eventID")
        return JSONObject().apply {
            put("ok", true)
            put("schema", HOST_SCHEMA)
            put("event", eventJson(backend.event(eventID)))
        }
    }

    private fun create(request: JSONObject): JSONObject {
        val receipt = backend.create(
            CalendarCreateRequest(
                calendarID = requiredLong(request, "calendarID"),
                title = requiredString(request, "title"),
                startMillis = requiredLong(request, "startMillis"),
                endMillis = requiredLong(request, "endMillis"),
                allDay = request.optBoolean("allDay", false),
                timeZone = requiredString(request, "timeZone"),
                notes = optionalString(request, "notes"),
                location = optionalString(request, "location"),
                recurrence = optionalString(request, "recurrence"),
            ),
        )
        return receiptJson(receipt)
    }

    private fun update(request: JSONObject): JSONObject {
        val patch = CalendarPatch(
            title = optionalString(request, "title"),
            startMillis = optionalLong(request, "startMillis"),
            endMillis = optionalLong(request, "endMillis"),
            notes = optionalString(request, "notes"),
            location = optionalString(request, "location"),
            allDay = if (request.has("allDay")) request.optBoolean("allDay") else null,
            timeZone = optionalString(request, "timeZone"),
            recurrence = optionalString(request, "recurrence"),
        )
        val receipt = backend.update(
            CalendarUpdateRequest(
                eventID = requiredLong(request, "eventID"),
                occurrenceStartMillis = optionalLong(request, "occurrenceStartMillis"),
                span = request.optString("span", "thisEvent"),
                patch = patch,
            ),
        )
        return receiptJson(receipt)
    }

    private fun delete(request: JSONObject): JSONObject {
        val receipt = backend.delete(
            CalendarDeleteRequest(
                eventID = requiredLong(request, "eventID"),
                occurrenceStartMillis = optionalLong(request, "occurrenceStartMillis"),
                span = request.optString("span", "thisEvent"),
            ),
        )
        return receiptJson(receipt)
    }

    // MARK: Reminders

    private fun armReminder(request: JSONObject): JSONObject {
        val ownerEpoch = requiredLong(request, "ownerEpoch")
        if (ownerEpoch != epoch) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.PROVIDER_UNAVAILABLE,
                "reminder owner epoch is stale",
            )
        }
        val todoID = requiredString(request, "todoID")
        val reminderAt = requiredLong(request, "reminderAtMillis")
        val dueAt = requiredLong(request, "dueAtMillis")
        val occurrence = requiredString(request, "occurrenceKey")
        val allDay = request.optBoolean("allDay", false)
        val zone = request.optString("timeZone", "UTC")
        val result = reminders.arm(todoID, reminderAt, dueAt, occurrence, allDay, zone)
        return JSONObject().apply {
            put("ok", true)
            put("schema", HOST_SCHEMA)
            put("scheduled", result.scheduled)
            put("state", result.state)
            result.reason?.let { put("reason", it) }
        }
    }

    private fun disarmReminder(request: JSONObject): JSONObject {
        val todoID = requiredString(request, "todoID")
        reminders.disarm(todoID)
        return JSONObject().apply {
            put("ok", true)
            put("schema", HOST_SCHEMA)
            put("disarmed", true)
        }
    }

    // MARK: JSON

    private fun snapshotJson(snapshot: CalendarSnapshotRow): JSONObject = JSONObject().apply {
        put("ok", true)
        put("schema", HOST_SCHEMA)
        put("providerAvailable", snapshot.providerAvailable)
        put("readGranted", snapshot.readGranted)
        put("writeGranted", snapshot.writeGranted)
        put("revision", snapshot.revision)
        put(
            "calendars",
            JSONArray(snapshot.calendars.map { calendar ->
                JSONObject().apply {
                    put("id", calendar.id)
                    put("displayName", calendar.displayName)
                    put("accountName", calendar.accountName)
                    put("accountType", calendar.accountType)
                    put("ownerAccount", calendar.ownerAccount)
                    put("timeZone", calendar.timeZone)
                    put("color", calendar.color)
                    put("accessLevel", calendar.accessLevel)
                    put("writable", calendar.writable)
                    put("visible", calendar.visible)
                    put("isPrimary", calendar.isPrimary)
                }
            }),
        )
    }

    private fun eventJson(row: CalendarEventRow): JSONObject = JSONObject().apply {
        put("eventID", row.eventID)
        put("calendarID", row.calendarID)
        put("calendarName", row.calendarName)
        put("title", row.title)
        put("startMillis", row.startMillis)
        put("endMillis", row.endMillis)
        put("allDay", row.allDay)
        put("timeZone", row.timeZone)
        row.location?.let { put("location", it) }
        row.notes?.let { put("notes", it) }
        row.recurrence?.let { put("recurrence", it) }
        row.originalInstanceTimeMillis?.let { put("originalInstanceTimeMillis", it) }
        row.status?.let { put("status", it.toString()) }
        put("deleted", row.deleted)
    }

    private fun receiptJson(receipt: CalendarReceiptRow): JSONObject = JSONObject().apply {
        put("ok", true)
        put("schema", HOST_SCHEMA)
        put(
            "receipt",
            JSONObject().apply {
                put("action", receipt.action)
                put("eventID", receipt.eventID)
                put("calendarID", receipt.calendarID)
                receipt.occurrenceStartMillis?.let { put("occurrenceStartMillis", it) }
                put("deleted", receipt.deleted)
                put("readbackVerified", receipt.readbackVerified)
                put("verificationScope", receipt.verificationScope)
                put("verifiedFields", JSONArray(receipt.verifiedFields))
            },
        )
    }

    private fun failure(failure: CalendarProviderFailure): JSONObject = error(
        code = failure.code.wireCode(),
        reason = failure.message,
        retryable = failure.retryable,
        detail = failure.detail,
    )

    private fun error(
        code: String,
        reason: String,
        retryable: Boolean = false,
        detail: String? = null,
    ): JSONObject = JSONObject().apply {
        put("ok", false)
        put("schema", HOST_SCHEMA)
        put("code", code)
        put("reason", reason.take(120))
        put("retryable", retryable)
        detail?.let { put("detail", it.take(240)) }
    }

    private fun requiredLong(objectValue: JSONObject, key: String): Long {
        if (!objectValue.has(key) || objectValue.isNull(key)) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_FIELDS,
                "missing $key",
            )
        }
        return objectValue.getLong(key)
    }

    private fun optionalLong(objectValue: JSONObject, key: String): Long? =
        if (objectValue.has(key) && !objectValue.isNull(key)) objectValue.getLong(key) else null

    private fun requiredString(objectValue: JSONObject, key: String): String {
        val value = objectValue.optString(key, "")
        if (value.isEmpty()) {
            throw CalendarProviderFailure(
                CalendarProviderFailureCode.INVALID_FIELDS,
                "missing $key",
            )
        }
        return value
    }

    private fun optionalString(objectValue: JSONObject, key: String): String? =
        if (objectValue.has(key) && !objectValue.isNull(key)) objectValue.getString(key) else null

    companion object {
        const val HOST_SCHEMA = "floe.calendar.host/1"
        const val MAX_REPLY_BYTES = 49_152
        const val REPLY_ROW_BUDGET = 32_768
        const val STATUS_OK = 0
        const val STATUS_SHAPE = -105
        const val STATUS_GENERATION = -102
        const val STATUS_CANCELLED = -109
    }
}

private fun CalendarProviderFailureCode.wireCode(): String = when (this) {
    CalendarProviderFailureCode.PERMISSION_DENIED -> "permissionDenied"
    CalendarProviderFailureCode.WRITE_PERMISSION_DENIED -> "writePermissionDenied"
    CalendarProviderFailureCode.PROVIDER_ABSENT -> "providerAbsent"
    CalendarProviderFailureCode.NO_CALENDARS -> "noCalendars"
    CalendarProviderFailureCode.NO_WRITABLE_CALENDAR -> "noWritableCalendar"
    CalendarProviderFailureCode.CALENDAR_MISSING -> "calendarMissing"
    CalendarProviderFailureCode.CALENDAR_NOT_WRITABLE -> "calendarNotWritable"
    CalendarProviderFailureCode.EVENT_NOT_FOUND -> "eventNotFound"
    CalendarProviderFailureCode.OCCURRENCE_NOT_FOUND -> "occurrenceNotFound"
    CalendarProviderFailureCode.OCCURRENCE_AMBIGUOUS -> "occurrenceAmbiguous"
    CalendarProviderFailureCode.STALE_OCCURRENCE -> "staleOccurrence"
    CalendarProviderFailureCode.OCCURRENCE_REQUIRED -> "staleOccurrence"
    CalendarProviderFailureCode.UNSUPPORTED_RECURRENCE -> "unsupportedRecurrence"
    CalendarProviderFailureCode.UNSUPPORTED_SPAN -> "unsupportedSpan"
    CalendarProviderFailureCode.INVALID_RANGE -> "invalidRange"
    CalendarProviderFailureCode.INVALID_DATE -> "invalidDate"
    CalendarProviderFailureCode.INVALID_TIMEZONE -> "invalidTimezone"
    CalendarProviderFailureCode.INVALID_RECURRENCE -> "invalidRecurrence"
    CalendarProviderFailureCode.INVALID_FIELDS -> "invalidFields"
    CalendarProviderFailureCode.INVALID_ALL_DAY -> "invalidAllDay"
    CalendarProviderFailureCode.READBACK_MISMATCH -> "readbackMismatch"
    CalendarProviderFailureCode.MUTATION_UNKNOWN -> "mutationUnknown"
    CalendarProviderFailureCode.PROVIDER_REJECTED -> "providerRejected"
    CalendarProviderFailureCode.PROVIDER_UNAVAILABLE -> "providerUnavailable"
    CalendarProviderFailureCode.BUSY -> "busy"
    CalendarProviderFailureCode.INTERNAL_FAILURE -> "internalFailure"
}
