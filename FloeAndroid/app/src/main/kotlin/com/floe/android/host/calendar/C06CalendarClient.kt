// SPDX-License-Identifier: MPL-2.0
//
// Synchronous trusted-host client for `floe.calendar/13`. Called only from an
// App-owned controller/worker on an IO dispatcher. Calendar provider access
// is NOT here: the reverse mailbox lane owns CalendarContract. This client
// pushes real permission state and reads/writes the original App todo store.

package com.floe.android.host.calendar

import com.floe.android.bridge.SwiftCore
import java.time.Instant
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

internal fun interface C06CalendarTransport {
    fun exchange(request: String): String
}

internal object SwiftC06CalendarTransport : C06CalendarTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal data class C06CalendarOwnerRef(
    val token: String,
    val nativeEpoch: Long,
    val conversationID: String? = null,
    val taskID: String? = null,
    val environmentID: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("token", token)
        put("nativeEpoch", nativeEpoch)
        conversationID?.let { put("conversationID", it) }
        taskID?.let { put("taskID", it) }
        environmentID?.let { put("environmentID", it) }
        put("temporary", false)
    }
}

internal class C06CalendarClientFailure(
    val code: String,
    override val message: String,
    val retryable: Boolean = false,
) : Exception(message)

internal data class CalendarAvailabilityUi(
    val readAvailable: Boolean,
    val writeAvailable: Boolean,
    val providerAvailable: Boolean,
    val readGranted: Boolean,
    val writeGranted: Boolean,
    val calendarCount: Int,
    val writableCalendarCount: Int,
    val revision: Long,
)

internal data class TodoRecordUi(
    val id: String,
    val title: String,
    val notes: String,
    val dueAtMillis: Long?,
    val dueTimeZone: String,
    val allDay: Boolean,
    val recurrence: String,
    val recurrenceInterval: Int,
    val recurrenceUntilMillis: Long?,
    val reminderMinutesBefore: Int?,
    val completed: Boolean,
    val revision: Int,
)

internal data class TodoPlanUi(
    val todoID: String,
    val dueAtMillis: Long,
    val reminderAtMillis: Long,
    val occurrenceKey: String,
    val allDay: Boolean,
    val timeZone: String,
)

internal data class TodoMutationUi(
    val todo: TodoRecordUi,
    val plan: TodoPlanUi?,
    val reminderScheduled: Boolean,
    val reminderState: String,
    val reminderReason: String?,
)

internal data class TodoDueUi(
    val todo: TodoRecordUi,
    val plan: TodoPlanUi,
)

internal class C06CalendarClient(
    private val transport: C06CalendarTransport = SwiftC06CalendarTransport,
) {
    fun capabilities(owner: C06CalendarOwnerRef): JSONObject =
        exchange("c06.capabilities", owner) { }

    fun pushAvailability(
        owner: C06CalendarOwnerRef,
        providerAvailable: Boolean,
        readGranted: Boolean,
        writeGranted: Boolean,
        calendarCount: Int,
        writableCalendarCount: Int,
        revision: Long,
    ): CalendarAvailabilityUi {
        val response = exchange("c06.calendar.availability", owner) {
            put("providerAvailable", providerAvailable)
            put("readGranted", readGranted)
            put("writeGranted", writeGranted)
            put("calendarCount", calendarCount)
            put("writableCalendarCount", writableCalendarCount)
            put("revision", revision)
        }
        return CalendarAvailabilityUi(
            readAvailable = response.optBoolean("readAvailable", false),
            writeAvailable = response.optBoolean("writeAvailable", false),
            providerAvailable = providerAvailable,
            readGranted = readGranted,
            writeGranted = writeGranted,
            calendarCount = calendarCount,
            writableCalendarCount = writableCalendarCount,
            revision = revision,
        )
    }

    fun todoList(
        owner: C06CalendarOwnerRef,
        includeCompleted: Boolean,
        limit: Int,
        offset: Int,
    ): Pair<List<TodoRecordUi>, Int> {
        val response = exchange("c06.todo.list", owner) {
            put("includeCompleted", includeCompleted)
            put("limit", limit)
            put("offset", offset)
        }
        val rows = response.optJSONArray("todos") ?: JSONArray()
        val todos = (0 until rows.length()).mapNotNull { index ->
            rows.optJSONObject(index)?.let(::parseTodo)
        }
        return todos to response.optInt("total", todos.size)
    }

    fun todoGet(owner: C06CalendarOwnerRef, id: String): TodoRecordUi {
        val response = exchange("c06.todo.get", owner) { put("id", id) }
        return response.optJSONObject("todo")?.let(::parseTodo)
            ?: throw C06CalendarClientFailure("invalidResponse", "missing_todo")
    }

    fun todoSave(
        owner: C06CalendarOwnerRef,
        action: String,
        id: String?,
        expectedRevision: Int?,
        title: String,
        notes: String,
        dueAtMillis: Long?,
        allDay: Boolean,
        timeZone: String,
        recurrence: String,
        recurrenceInterval: Int,
        recurrenceUntilMillis: Long?,
        reminderMinutesBefore: Int?,
    ): TodoMutationUi {
        val response = exchange("c06.todo.save", owner) {
            put("action", action)
            id?.let { put("id", it) }
            expectedRevision?.let { put("expectedRevision", it) }
            put("title", title)
            put("notes", notes)
            dueAtMillis?.let { put("dueAt", Instant.ofEpochMilli(it).toString()) }
            put("allDay", allDay)
            put("timezone", timeZone)
            put("recurrence", recurrence)
            put("recurrenceInterval", recurrenceInterval)
            recurrenceUntilMillis?.let { put("recurrenceUntil", Instant.ofEpochMilli(it).toString()) }
            reminderMinutesBefore?.let { put("reminderMinutesBefore", it) }
        }
        return parseMutation(response)
    }

    fun todoComplete(
        owner: C06CalendarOwnerRef,
        id: String,
        expectedRevision: Int,
        completed: Boolean,
    ): TodoMutationUi {
        val response = exchange("c06.todo.complete", owner) {
            put("id", id)
            put("expectedRevision", expectedRevision)
            put("completed", completed)
        }
        return parseMutation(response)
    }

    fun todoDelete(owner: C06CalendarOwnerRef, id: String, expectedRevision: Int): Boolean {
        val response = exchange("c06.todo.delete", owner) {
            put("id", id)
            put("expectedRevision", expectedRevision)
        }
        return response.optBoolean("deleted", false)
    }

    fun reminderPlans(owner: C06CalendarOwnerRef): List<TodoPlanUi> {
        val response = exchange("c06.todo.reminderPlans", owner) { }
        val rows = response.optJSONArray("plans") ?: JSONArray()
        return (0 until rows.length()).mapNotNull { index ->
            rows.optJSONObject(index)?.let(::parsePlan)
        }
    }

    fun reminderDue(
        owner: C06CalendarOwnerRef,
        id: String,
        occurrenceKey: String,
    ): TodoDueUi? {
        val response = try {
            exchange("c06.todo.reminderDue", owner) {
                put("id", id)
                put("occurrenceKey", occurrenceKey)
            }
        } catch (failure: C06CalendarClientFailure) {
            if (failure.code == "notFound") return null
            throw failure
        }
        val todo = response.optJSONObject("todo")?.let(::parseTodo) ?: return null
        val plan = response.optJSONObject("plan")?.let(::parsePlan) ?: return null
        return TodoDueUi(todo, plan)
    }

    fun markReminderShown(
        owner: C06CalendarOwnerRef,
        id: String,
        occurrenceKey: String,
    ): Boolean {
        val response = exchange("c06.todo.markReminderShown", owner) {
            put("id", id)
            put("occurrenceKey", occurrenceKey)
        }
        return response.optBoolean("shown", false)
    }

    private fun exchange(
        operation: String,
        owner: C06CalendarOwnerRef,
        build: JSONObject.() -> Unit,
    ): JSONObject {
        val requestID = UUID.randomUUID().toString()
        val request = JSONObject()
            .put("version", 13)
            .put("operation", operation)
            .put("requestID", requestID)
            .put("owner", owner.toJson())
        request.build()
        val raw = try {
            transport.exchange(request.toString())
        } catch (failure: Throwable) {
            throw C06CalendarClientFailure(
                "coreUnavailable",
                "calendar core unavailable: ${failure.javaClass.simpleName}",
            )
        }
        val response = try {
            JSONObject(raw)
        } catch (_: Throwable) {
            throw C06CalendarClientFailure("invalidResponse", "invalid_calendar_reply")
        }
        if (!response.optBoolean("ok", false)) {
            throw C06CalendarClientFailure(
                response.optString("code", "internalFailure"),
                response.optString("reason", "calendar_operation_failed"),
                response.optBoolean("retryable", false),
            )
        }
        return response
    }

    private fun parseMutation(response: JSONObject): TodoMutationUi {
        val todo = response.optJSONObject("todo")?.let(::parseTodo)
            ?: throw C06CalendarClientFailure("invalidResponse", "missing_todo")
        val reminder = response.optJSONObject("reminder")
        return TodoMutationUi(
            todo = todo,
            plan = response.optJSONObject("plan")?.let(::parsePlan),
            reminderScheduled = reminder?.optBoolean("scheduled", false) ?: false,
            reminderState = reminder?.optString("state", "none") ?: "none",
            reminderReason = reminder?.optString("reason")?.takeIf { it.isNotBlank() },
        )
    }

    private fun parseTodo(objectValue: JSONObject): TodoRecordUi = TodoRecordUi(
        id = objectValue.optString("id"),
        title = objectValue.optString("title"),
        notes = objectValue.optString("notes"),
        dueAtMillis = parseInstant(objectValue.optString("dueAt")),
        dueTimeZone = objectValue.optString("dueTimeZone", "UTC"),
        allDay = objectValue.optBoolean("allDay", false),
        recurrence = objectValue.optString("recurrence", "none"),
        recurrenceInterval = objectValue.optInt("recurrenceInterval", 1),
        recurrenceUntilMillis = parseInstant(objectValue.optString("recurrenceUntil")),
        reminderMinutesBefore = if (objectValue.has("reminderMinutesBefore") &&
            !objectValue.isNull("reminderMinutesBefore")
        ) {
            objectValue.optInt("reminderMinutesBefore")
        } else {
            null
        },
        completed = objectValue.optBoolean("completed", false),
        revision = objectValue.optInt("revision", 1),
    )

    private fun parsePlan(objectValue: JSONObject): TodoPlanUi? {
        val todoID = objectValue.optString("todoID")
        val due = parseInstant(objectValue.optString("dueAt")) ?: return null
        val reminder = parseInstant(objectValue.optString("reminderAt")) ?: return null
        val occurrence = objectValue.optString("occurrenceKey")
        if (todoID.isBlank() || occurrence.isBlank()) return null
        return TodoPlanUi(
            todoID = todoID,
            dueAtMillis = due,
            reminderAtMillis = reminder,
            occurrenceKey = occurrence,
            allDay = objectValue.optBoolean("allDay", false),
            timeZone = objectValue.optString("timeZone", "UTC"),
        )
    }

    private fun parseInstant(raw: String): Long? =
        if (raw.isBlank()) null else runCatching { Instant.parse(raw).toEpochMilli() }.getOrNull()
}
