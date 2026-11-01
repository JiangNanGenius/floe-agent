// SPDX-License-Identifier: MPL-2.0
//
// C06 calendar/todo presentation values. No provider row, alarm or database
// object is exposed to Compose; the App host controller owns every effect.

package com.floe.android.feature.calendar

enum class CalendarPermissionState {
    NOT_REQUESTED,
    GRANTED,
    DENIED,
}

data class CalendarRowUi(
    val id: Long,
    val displayName: String,
    val accountName: String,
    val timeZone: String,
    val color: Int,
    val writable: Boolean,
    val visible: Boolean,
    val isPrimary: Boolean,
)

data class CalendarEventRowUi(
    val eventID: Long,
    val calendarID: Long,
    val calendarName: String,
    val title: String,
    val startMillis: Long,
    val endMillis: Long,
    val allDay: Boolean,
    val timeZone: String,
    val recurrence: String?,
    val occurrence: String,
    val recurring: Boolean,
    val detached: Boolean,
)

data class TodoRowUi(
    val id: String,
    val revision: Int,
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
    val reminderState: String?,
)

data class CalendarEventDraftUi(
    val mode: String,
    val eventID: Long?,
    val occurrence: String?,
    val span: String,
    val calendarID: Long?,
    val title: String,
    val startMillis: Long,
    val endMillis: Long,
    val allDay: Boolean,
    val timeZone: String,
    val location: String,
    val notes: String,
    val recurrence: String,
    val recurring: Boolean,
    val writableCalendars: List<CalendarRowUi>,
)

data class TodoDraftUi(
    val mode: String,
    val id: String?,
    val expectedRevision: Int?,
    val title: String,
    val notes: String,
    val dueAtMillis: Long?,
    val allDay: Boolean,
    val timeZone: String,
    val recurrence: String,
    val recurrenceInterval: Int,
    val recurrenceUntilMillis: Long?,
    val reminderMinutesBefore: Int?,
)

data class CalendarScreenState(
    val loading: Boolean = false,
    val busyAction: String? = null,
    val tab: Int = 0,
    val readPermission: CalendarPermissionState = CalendarPermissionState.NOT_REQUESTED,
    val writePermission: CalendarPermissionState = CalendarPermissionState.NOT_REQUESTED,
    val providerAvailable: Boolean = true,
    val calendars: List<CalendarRowUi> = emptyList(),
    val selectedCalendarID: Long? = null,
    val rangeStartMillis: Long = 0L,
    val rangeEndMillis: Long = 0L,
    val events: List<CalendarEventRowUi> = emptyList(),
    val eventHasMore: Boolean = false,
    val eventLoading: Boolean = false,
    val eventEditor: CalendarEventDraftUi? = null,
    val eventDeleteRequest: CalendarEventDraftUi? = null,
    val todos: List<TodoRowUi> = emptyList(),
    val todoTotal: Int = 0,
    val showCompleted: Boolean = false,
    val todoLoading: Boolean = false,
    val todoEditor: TodoDraftUi? = null,
    val todoDeleteRequest: TodoRowUi? = null,
    val selectedTodoID: String? = null,
    val notificationsEnabled: Boolean = true,
    val exactAlarmAllowed: Boolean = true,
    val notificationPermission: CalendarPermissionState = CalendarPermissionState.NOT_REQUESTED,
    val calendarError: String? = null,
    val todoError: String? = null,
    val notice: String? = null,
) {
    val selectedCalendar: CalendarRowUi?
        get() = selectedCalendarID?.let { id -> calendars.firstOrNull { it.id == id } }

    val writableCalendars: List<CalendarRowUi>
        get() = calendars.filter { it.writable }

    val hasReadAccess: Boolean
        get() = providerAvailable && readPermission == CalendarPermissionState.GRANTED

    val hasWriteAccess: Boolean
        get() = hasReadAccess && writePermission == CalendarPermissionState.GRANTED &&
            writableCalendars.isNotEmpty()
}

enum class CalendarRouteState {
    IDLE,
    OPEN_TODO,
    MISSING_TODO,
}

/** Sorting/grouping helper shared by the list UI and tests. */
object CalendarPresentation {
    fun dayKey(millis: Long, timeZone: String): String {
        val zone = runCatching { java.time.ZoneId.of(timeZone) }
            .getOrElse { java.time.ZoneId.systemDefault() }
        return java.time.Instant.ofEpochMilli(millis).atZone(zone).toLocalDate().toString()
    }

    fun sortEvents(rows: List<CalendarEventRowUi>): List<CalendarEventRowUi> =
        rows.sortedWith(
            compareBy<CalendarEventRowUi> { it.startMillis }
                .thenBy { it.endMillis }
                .thenBy { it.eventID }
                .thenBy { it.title },
        )

    fun sortTodos(rows: List<TodoRowUi>): List<TodoRowUi> =
        rows.sortedWith(
            compareBy<TodoRowUi> { it.completed }
                .thenBy { it.dueAtMillis ?: Long.MAX_VALUE }
                .thenBy { it.title },
        )

    fun reminderLabel(minutes: Int?): String? = when (minutes) {
        null -> null
        0 -> "at due time"
        1..59 -> "$minutes min before"
        60 -> "1 hour before"
        else -> if (minutes % 1440 == 0) "${minutes / 1440} day before" else "$minutes min before"
    }
}
