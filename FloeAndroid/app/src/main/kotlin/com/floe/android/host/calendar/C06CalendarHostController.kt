// SPDX-License-Identifier: MPL-2.0
//
// Application-owned C06 calendar/todo controller.
//
// Owns the trusted bridge token, the real CalendarContract backend, the
// reverse provider lane and the local reminder transport. It survives
// Activity reconstruction because RuntimeHost is app-scoped: an in-flight
// provider write or reminder rearm never belongs to a view lifetime.
//
// There is no default calendar. A create is refused until the user explicitly
// selects a writable calendar. Permission denial, a missing provider and no
// configured account are surfaced as distinct states.

package com.floe.android.host.calendar

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.app.NotificationManagerCompat
import com.floe.android.core.calendar.AndroidCalendarProvider
import com.floe.android.core.calendar.CalendarCreateRequest
import com.floe.android.core.calendar.CalendarDeleteRequest
import com.floe.android.core.calendar.CalendarEventRow
import com.floe.android.core.calendar.CalendarPatch
import com.floe.android.core.calendar.CalendarProviderBackend
import com.floe.android.core.calendar.CalendarProviderFailure
import com.floe.android.core.calendar.CalendarProviderFailureCode
import com.floe.android.core.calendar.CalendarProviderRules
import com.floe.android.core.calendar.CalendarSnapshotRow
import com.floe.android.core.calendar.CalendarUpdateRequest
import com.floe.android.feature.calendar.CalendarEventDraftUi
import com.floe.android.feature.calendar.CalendarEventRowUi
import com.floe.android.feature.calendar.CalendarPermissionState
import com.floe.android.feature.calendar.CalendarRowUi
import com.floe.android.feature.calendar.CalendarScreenState
import com.floe.android.feature.calendar.TodoDraftUi
import com.floe.android.feature.calendar.TodoRowUi
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

internal data class CalendarPermissionRequest(val write: Boolean)

internal class C06CalendarHostController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val currentNativeEpoch: () -> Long?,
    private val backend: CalendarProviderBackend = AndroidCalendarProvider(context.applicationContext),
    private val client: C06CalendarClient = C06CalendarClient(),
    private val scheduler: TodoReminderScheduler = TodoReminderScheduler(context.applicationContext),
) : TodoReminderTransport, TodoReminderPlatform {
    private val appContext = context.applicationContext
    private val ownerToken = UUID.randomUUID().toString()
    private val lane = CalendarProviderLane(scope, backend, this, ioDispatcher = ioDispatcher)
    private val preferences = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val _state = MutableStateFlow(CalendarScreenState(rangeStartMillis = todayStart(), rangeEndMillis = todayStart() + DAY))
    val state: StateFlow<CalendarScreenState> = _state.asStateFlow()
    private val _permissionRequests = MutableStateFlow<CalendarPermissionRequest?>(null)
    val permissionRequests: StateFlow<CalendarPermissionRequest?> = _permissionRequests.asStateFlow()

    @Volatile
    private var lastEpoch: Long = 0
    @Volatile
    private var started = false

    // MARK: Lifecycle

    fun onOwnedStoreReady() {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        lastEpoch = epoch
        val laneStarted = lane.isRunning || lane.start(epoch)
        started = laneStarted
        if (laneStarted) TodoReminderPlatform.current = this
        scope.launch {
            if (!laneStarted) {
                _state.update { it.copy(calendarError = "hostUnavailable", loading = false) }
                return@launch
            }
            refreshInternal()
            rearmTodosInternal()
        }
    }

    fun enter() {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
        if (epoch != null && epoch != lastEpoch) {
            lastEpoch = epoch
            val nowRunning = lane.isRunning || lane.start(epoch)
            started = nowRunning
            if (nowRunning) TodoReminderPlatform.current = this
        }
        refresh()
    }

    fun onAppForeground() {
        scope.launch {
            loadNotificationState()
            if (currentNativeEpoch() != null && !lane.isRunning) {
                onOwnedStoreReady()
            }
            rearmTodosInternal()
        }
    }

    suspend fun prepareForRootStop(timeoutMillis: Int): Boolean {
        val drained = withContext(ioDispatcher) { lane.stop(timeoutMillis) }
        if (TodoReminderPlatform.current === this) TodoReminderPlatform.current = null
        started = false
        lastEpoch = 0
        return drained
    }

    fun onRootStopped() {
        if (TodoReminderPlatform.current === this) TodoReminderPlatform.current = null
        started = false
        lastEpoch = 0
        _state.value = CalendarScreenState(
            rangeStartMillis = todayStart(),
            rangeEndMillis = todayStart() + DAY,
        )
    }

    // MARK: Refresh

    fun refresh() {
        scope.launch { refreshInternal() }
    }

    private suspend fun refreshInternal() {
        _state.update { it.copy(loading = true, calendarError = null, todoError = null) }
        withContext(ioDispatcher) {
            try {
                val snapshot = backend.snapshot()
                val availability = pushAvailability(snapshot)
                val selected = selectedCalendarID()
                val calendars = snapshot.calendars.map(::calendarRow)
                val validSelected = selected?.takeIf { id -> calendars.any { it.id == id } }
                if (selected != null && validSelected == null) {
                    saveSelectedCalendarID(null)
                }
                val permission = permissionState(
                    granted = snapshot.readGranted,
                    key = REQUESTED_READ,
                )
                val writePermission = permissionState(
                    granted = snapshot.writeGranted,
                    key = REQUESTED_WRITE,
                )
                _state.update {
                    it.copy(
                        loading = false,
                        providerAvailable = snapshot.providerAvailable,
                        readPermission = permission,
                        writePermission = writePermission,
                        calendars = calendars,
                        selectedCalendarID = validSelected,
                        notificationsEnabled = scheduler.notificationsUsable(),
                        exactAlarmAllowed = scheduler.exactAlarmAllowed(),
                        notificationPermission = notificationPermissionState(),
                        notice = if (selected != null && validSelected == null) {
                            "selectionLost"
                        } else {
                            it.notice
                        },
                        calendarError = when {
                            !snapshot.providerAvailable -> "providerAbsent"
                            !snapshot.readGranted -> "permissionDenied"
                            availability.writeAvailable.not() && snapshot.writeGranted -> null
                            else -> null
                        },
                    )
                }
                if (snapshot.providerAvailable && snapshot.readGranted) {
                    loadEventsInternal(reset = true)
                }
                // Todos are independent App-local data: a calendar permission
                // denial or absent provider never hides or disables them.
                loadTodosInternal(reset = true)
            } catch (failure: CalendarProviderFailure) {
                _state.update {
                    it.copy(
                        loading = false,
                        providerAvailable = failure.code != CalendarProviderFailureCode.PROVIDER_ABSENT,
                        calendarError = failure.wireCode(),
                    )
                }
            } catch (failure: C06CalendarClientFailure) {
                _state.update {
                    it.copy(
                        loading = false,
                        calendarError = failure.code,
                        todoError = failure.code,
                    )
                }
            }
        }
    }

    private suspend fun pushAvailability(snapshot: CalendarSnapshotRow): CalendarAvailabilityUi {
        val owner = owner() ?: throw C06CalendarClientFailure("runtimeNotReady", "runtime_not_ready")
        return client.pushAvailability(
            owner = owner,
            providerAvailable = snapshot.providerAvailable,
            readGranted = snapshot.readGranted,
            writeGranted = snapshot.writeGranted,
            calendarCount = snapshot.calendars.size,
            writableCalendarCount = snapshot.calendars.count { it.writable },
            revision = snapshot.revision,
        )
    }

    // MARK: Permissions

    fun requestPermission(write: Boolean) {
        _permissionRequests.value = CalendarPermissionRequest(write)
    }

    fun onPermissionResult(write: Boolean, granted: Boolean) {
        _permissionRequests.value = null
        preferences.edit().putBoolean(if (write) REQUESTED_WRITE else REQUESTED_READ, true).apply()
        scope.launch {
            withContext(ioDispatcher) {
                try {
                    val snapshot = backend.snapshot()
                    pushAvailability(snapshot)
                    _state.update {
                        it.copy(
                            readPermission = permissionState(snapshot.readGranted, REQUESTED_READ),
                            writePermission = permissionState(snapshot.writeGranted, REQUESTED_WRITE),
                            providerAvailable = snapshot.providerAvailable,
                            calendars = snapshot.calendars.map(::calendarRow),
                        )
                    }
                    if (granted && snapshot.readGranted) {
                        loadEventsInternal(reset = true)
                    }
                    if (!granted) {
                        _state.update { it.copy(calendarError = if (write) "writePermissionDenied" else "permissionDenied") }
                    }
                } catch (failure: CalendarProviderFailure) {
                    _state.update { it.copy(calendarError = failure.wireCode()) }
                }
            }
        }
    }

    fun openAppSettings() {
        val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.parse("package:${appContext.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { appContext.startActivity(intent) }
    }

    fun openNotificationSettings() {
        runCatching {
            appContext.startActivity(TodoReminderScheduler.notificationSettingsIntent(appContext))
        }.onFailure { openAppSettings() }
    }

    fun openExactAlarmSettings() {
        runCatching {
            appContext.startActivity(TodoReminderScheduler.exactAlarmSettingsIntent(appContext))
        }.onFailure { openAppSettings() }
    }

    // MARK: Calendar selection / range

    fun selectCalendar(calendarID: Long?) {
        if (calendarID != null && _state.value.calendars.none { it.id == calendarID }) return
        saveSelectedCalendarID(calendarID)
        _state.update { it.copy(selectedCalendarID = calendarID) }
        scope.launch { withContext(ioDispatcher) { loadEventsInternal(reset = true) } }
    }

    fun setTab(tab: Int) {
        _state.update { it.copy(tab = tab.coerceIn(0, 1)) }
    }

    fun dismissNotice() {
        _state.update { it.copy(notice = null) }
    }

    fun selectRange(index: Int) {
        val start = todayStart()
        val end = when (index) {
            0 -> start + DAY
            1 -> start + 7 * DAY
            else -> start + 30 * DAY
        }
        _state.update { it.copy(rangeStartMillis = start, rangeEndMillis = end) }
        scope.launch { withContext(ioDispatcher) { loadEventsInternal(reset = true) } }
    }

    fun loadMoreEvents() {
        if (!_state.value.eventHasMore || _state.value.eventLoading) return
        scope.launch { withContext(ioDispatcher) { loadEventsInternal(reset = false) } }
    }

    private suspend fun loadEventsInternal(reset: Boolean) {
        val state = _state.value
        if (!state.hasReadAccess) return
        _state.update { it.copy(eventLoading = true) }
        val offset = if (reset) 0 else state.events.size
        try {
            val page = backend.instances(
                startMillis = state.rangeStartMillis,
                endMillis = state.rangeEndMillis,
                calendarID = state.selectedCalendarID,
                query = null,
                limit = PAGE,
                offset = offset,
            )
            val rows = page.rows.map(::eventRow)
            _state.update {
                it.copy(
                    eventLoading = false,
                    events = if (reset) rows else (it.events + rows).distinctBy { row -> "${row.eventID}:${row.occurrence}" },
                    eventHasMore = page.hasMore,
                    calendarError = null,
                )
            }
        } catch (failure: CalendarProviderFailure) {
            _state.update { it.copy(eventLoading = false, calendarError = failure.wireCode()) }
        }
    }

    // MARK: Event editor

    fun newEvent() {
        val state = _state.value
        if (!state.hasWriteAccess) {
            _state.update { it.copy(notice = if (state.writePermission != CalendarPermissionState.GRANTED) {
                "writePermissionDenied"
            } else {
                "chooseWritableCalendar"
            }) }
            return
        }
        val selected = state.selectedCalendar?.takeIf { it.writable }
        val zone = selected?.timeZone ?: ZoneId.systemDefault().id
        val start = nextHourMillis(zone)
        _state.update {
            it.copy(
                eventEditor = CalendarEventDraftUi(
                    mode = "create",
                    eventID = null,
                    occurrence = null,
                    span = "thisEvent",
                    calendarID = selected?.id,
                    title = "",
                    startMillis = start,
                    endMillis = start + 3_600_000L,
                    allDay = false,
                    timeZone = zone,
                    location = "",
                    notes = "",
                    recurrence = "none",
                    recurring = false,
                    writableCalendars = it.writableCalendars,
                ),
            )
        }
    }

    fun editEvent(row: CalendarEventRowUi) {
        scope.launch { withContext(ioDispatcher) {
            try {
                val event = backend.event(row.eventID)
                // A recurring series' Events row carries the series anchor;
                // the selected Instances row carries the exact occurrence
                // start/end. The editor must show the latter, or the write
                // would target the series anchor instead of the listed token.
                val start = if (event.recurring) row.startMillis else event.startMillis
                val end = if (event.recurring) row.endMillis else event.endMillis
                _state.update {
                    it.copy(
                        eventEditor = CalendarEventDraftUi(
                            mode = "update",
                            eventID = event.eventID,
                            occurrence = row.occurrence,
                            span = "thisEvent",
                            calendarID = event.calendarID,
                            title = event.title,
                            startMillis = start,
                            endMillis = end,
                            allDay = event.allDay,
                            timeZone = event.timeZone,
                            location = event.location.orEmpty(),
                            notes = event.notes.orEmpty(),
                            recurrence = recurrenceKind(event.recurrence),
                            recurring = event.recurring,
                            writableCalendars = it.writableCalendars,
                        ),
                    )
                }
            } catch (failure: CalendarProviderFailure) {
                _state.update { it.copy(calendarError = failure.wireCode()) }
            }
        } }
    }

    fun updateEventDraft(draft: CalendarEventDraftUi) {
        _state.update { it.copy(eventEditor = draft) }
    }

    fun closeEventEditor() {
        _state.update { it.copy(eventEditor = null, eventDeleteRequest = null) }
    }

    fun requestDeleteEvent(draft: CalendarEventDraftUi) {
        _state.update { it.copy(eventDeleteRequest = draft) }
    }

    fun dismissDeleteEvent() {
        _state.update { it.copy(eventDeleteRequest = null) }
    }

    fun saveEventDraft(draft: CalendarEventDraftUi) {
        if (draft.title.isBlank()) {
            _state.update { it.copy(calendarError = "invalidFields") }
            return
        }
        if (draft.endMillis <= draft.startMillis) {
            _state.update { it.copy(calendarError = "invalidRange") }
            return
        }
        if (draft.mode == "create" && draft.calendarID == null) {
            _state.update { it.copy(calendarError = "calendarMissing") }
            return
        }
        scope.launch {
            _state.update { it.copy(busyAction = "saveEvent", calendarError = null) }
            withContext(ioDispatcher) {
                try {
                    if (draft.mode == "create") {
                        val receipt = backend.create(
                            CalendarCreateRequest(
                                calendarID = draft.calendarID ?: 0L,
                                title = draft.title,
                                startMillis = draft.startMillis,
                                endMillis = draft.endMillis,
                                allDay = draft.allDay,
                                timeZone = effectiveZone(draft.allDay, draft.timeZone),
                                notes = draft.notes,
                                location = draft.location,
                                recurrence = rrule(draft.recurrence),
                            ),
                        )
                        if (!receipt.readbackVerified) throw C06CalendarClientFailure("readbackMismatch", "unverified")
                        finishEventWrite("created")
                    } else {
                        val occurrence = draft.occurrence?.let(CalendarProviderRules::parseOccurrenceToken)
                        val editedRecurrence = if (draft.recurring && draft.span == "thisEvent") {
                            // A single-occurrence edit never changes the series
                            // rule; the provider refuses that ambiguity.
                            null
                        } else {
                            rrule(draft.recurrence)
                        }
                        val receipt = backend.update(
                            CalendarUpdateRequest(
                                eventID = draft.eventID ?: 0L,
                                occurrenceStartMillis = occurrence?.second,
                                span = draft.span,
                                patch = CalendarPatch(
                                    title = draft.title,
                                    startMillis = draft.startMillis,
                                    endMillis = draft.endMillis,
                                    notes = draft.notes,
                                    location = draft.location,
                                    allDay = draft.allDay,
                                    timeZone = effectiveZone(draft.allDay, draft.timeZone),
                                    recurrence = editedRecurrence,
                                ),
                            ),
                        )
                        if (!receipt.readbackVerified) throw C06CalendarClientFailure("readbackMismatch", "unverified")
                        finishEventWrite("updated")
                    }
                } catch (failure: CalendarProviderFailure) {
                    _state.update { it.copy(busyAction = null, calendarError = failure.wireCode()) }
                } catch (failure: C06CalendarClientFailure) {
                    _state.update { it.copy(busyAction = null, calendarError = failure.code) }
                }
            }
        }
    }

    fun confirmDeleteEvent() {
        val draft = _state.value.eventDeleteRequest ?: return
        scope.launch {
            _state.update { it.copy(busyAction = "deleteEvent", eventDeleteRequest = null) }
            withContext(ioDispatcher) {
                try {
                    val occurrence = draft.occurrence?.let(CalendarProviderRules::parseOccurrenceToken)
                    val receipt = backend.delete(
                        CalendarDeleteRequest(
                            eventID = draft.eventID ?: 0L,
                            occurrenceStartMillis = occurrence?.second,
                            span = if (draft.recurring) draft.span else "thisEvent",
                        ),
                    )
                    if (!receipt.readbackVerified || !receipt.deleted) {
                        throw C06CalendarClientFailure("readbackMismatch", "unverified")
                    }
                    finishEventWrite("deleted")
                } catch (failure: CalendarProviderFailure) {
                    _state.update { it.copy(busyAction = null, calendarError = failure.wireCode()) }
                } catch (failure: C06CalendarClientFailure) {
                    _state.update { it.copy(busyAction = null, calendarError = failure.code) }
                }
            }
        }
    }

    private suspend fun finishEventWrite(notice: String) {
        loadEventsInternal(reset = true)
        _state.update {
            it.copy(busyAction = null, eventEditor = null, eventDeleteRequest = null, notice = notice)
        }
    }

    // MARK: Todos

    fun loadMoreTodos() {
        if (_state.value.todoLoading || _state.value.todos.size >= _state.value.todoTotal) return
        scope.launch { withContext(ioDispatcher) { loadTodosInternal(reset = false) } }
    }

    fun setShowCompleted(value: Boolean) {
        _state.update { it.copy(showCompleted = value) }
        scope.launch { withContext(ioDispatcher) { loadTodosInternal(reset = true) } }
    }

    private suspend fun loadTodosInternal(reset: Boolean) {
        val owner = owner() ?: run {
            _state.update { it.copy(todoError = "runtimeNotReady", todoLoading = false) }
            return
        }
        _state.update { it.copy(todoLoading = true) }
        val offset = if (reset) 0 else _state.value.todos.size
        try {
            val (rows, total) = client.todoList(
                owner = owner,
                includeCompleted = _state.value.showCompleted,
                limit = PAGE,
                offset = offset,
            )
            val mapped = rows.map(::todoRow)
            _state.update {
                it.copy(
                    todoLoading = false,
                    todos = if (reset) mapped else (it.todos + mapped).distinctBy { row -> row.id },
                    todoTotal = total,
                    todoError = null,
                )
            }
        } catch (failure: C06CalendarClientFailure) {
            _state.update { it.copy(todoLoading = false, todoError = failure.code) }
        }
    }

    fun newTodo() {
        _state.update {
            it.copy(
                todoEditor = TodoDraftUi(
                    mode = "create",
                    id = null,
                    expectedRevision = null,
                    title = "",
                    notes = "",
                    dueAtMillis = null,
                    allDay = false,
                    timeZone = ZoneId.systemDefault().id,
                    recurrence = "none",
                    recurrenceInterval = 1,
                    recurrenceUntilMillis = null,
                    reminderMinutesBefore = null,
                ),
            )
        }
    }

    fun editTodo(row: TodoRowUi) {
        val owner = owner() ?: return
        scope.launch {
            withContext(ioDispatcher) {
                try {
                    // The list deliberately omits notes to stay inside the
                    // bridge frame. Re-read the exact current row (including
                    // its latest revision and full notes) before editing.
                    val full = client.todoGet(owner, row.id)
                    _state.update {
                        it.copy(
                            todoEditor = TodoDraftUi(
                                mode = "update",
                                id = full.id,
                                expectedRevision = full.revision,
                                title = full.title,
                                notes = full.notes,
                                dueAtMillis = full.dueAtMillis,
                                allDay = full.allDay,
                                timeZone = full.dueTimeZone,
                                recurrence = full.recurrence,
                                recurrenceInterval = full.recurrenceInterval,
                                recurrenceUntilMillis = full.recurrenceUntilMillis,
                                reminderMinutesBefore = full.reminderMinutesBefore,
                            ),
                        )
                    }
                } catch (failure: C06CalendarClientFailure) {
                    _state.update { it.copy(todoError = failure.code) }
                }
            }
        }
    }

    fun updateTodoDraft(draft: TodoDraftUi) {
        _state.update { it.copy(todoEditor = draft) }
    }

    fun closeTodoEditor() {
        _state.update { it.copy(todoEditor = null, todoDeleteRequest = null) }
    }

    fun requestDeleteTodo(todo: TodoRowUi) {
        _state.update { it.copy(todoDeleteRequest = todo) }
    }

    fun dismissDeleteTodo() {
        _state.update { it.copy(todoDeleteRequest = null) }
    }

    fun saveTodoDraft(draft: TodoDraftUi) {
        val owner = owner() ?: run {
            _state.update { it.copy(todoError = "runtimeNotReady") }
            return
        }
        if (draft.title.isBlank()) {
            _state.update { it.copy(todoError = "invalidTitle") }
            return
        }
        if (draft.reminderMinutesBefore != null && draft.dueAtMillis == null) {
            _state.update { it.copy(todoError = "invalidDue") }
            return
        }
        scope.launch {
            _state.update { it.copy(busyAction = "saveTodo", todoError = null) }
            withContext(ioDispatcher) {
                try {
                    val result = client.todoSave(
                        owner = owner,
                        action = draft.mode,
                        id = draft.id,
                        expectedRevision = draft.expectedRevision,
                        title = draft.title,
                        notes = draft.notes,
                        dueAtMillis = draft.dueAtMillis?.let { normalizeTodoDue(it, draft.allDay, draft.timeZone) },
                        allDay = draft.allDay,
                        timeZone = draft.timeZone,
                        recurrence = draft.recurrence,
                        recurrenceInterval = draft.recurrenceInterval,
                        recurrenceUntilMillis = draft.recurrenceUntilMillis,
                        reminderMinutesBefore = draft.reminderMinutesBefore,
                    )
                    applyTodoMutation(result)
                    _state.update {
                        it.copy(
                            busyAction = null,
                            todoEditor = null,
                            notice = reminderNotice(result.reminderState),
                        )
                    }
                } catch (failure: C06CalendarClientFailure) {
                    _state.update { it.copy(busyAction = null, todoError = failure.code) }
                }
            }
        }
    }

    fun toggleTodo(todo: TodoRowUi) {
        val owner = owner() ?: return
        scope.launch {
            _state.update { it.copy(busyAction = "todo:${todo.id}", todoError = null) }
            withContext(ioDispatcher) {
                try {
                    val result = client.todoComplete(
                        owner = owner,
                        id = todo.id,
                        expectedRevision = todo.revision,
                        completed = !todo.completed,
                    )
                    applyTodoMutation(result)
                    _state.update { it.copy(busyAction = null, notice = reminderNotice(result.reminderState)) }
                } catch (failure: C06CalendarClientFailure) {
                    _state.update {
                        it.copy(
                            busyAction = null,
                            todoError = if (failure.code == "revisionConflict") "revisionConflict" else failure.code,
                        )
                    }
                }
            }
        }
    }

    fun confirmDeleteTodo() {
        val todo = _state.value.todoDeleteRequest ?: return
        val owner = owner() ?: return
        scope.launch {
            _state.update { it.copy(busyAction = "deleteTodo", todoDeleteRequest = null) }
            withContext(ioDispatcher) {
                try {
                    client.todoDelete(owner, todo.id, todo.revision)
                    scheduler.cancel(todo.id)
                    _state.update {
                        it.copy(
                            busyAction = null,
                            todos = it.todos.filterNot { row -> row.id == todo.id },
                            todoTotal = (it.todoTotal - 1).coerceAtLeast(0),
                            notice = "todoDeleted",
                        )
                    }
                } catch (failure: C06CalendarClientFailure) {
                    _state.update { it.copy(busyAction = null, todoError = failure.code) }
                }
            }
        }
    }

    private fun applyTodoMutation(result: TodoMutationUi) {
        val row = TodoRowUi(
            id = result.todo.id,
            revision = result.todo.revision,
            title = result.todo.title,
            notes = result.todo.notes,
            dueAtMillis = result.todo.dueAtMillis,
            dueTimeZone = result.todo.dueTimeZone,
            allDay = result.todo.allDay,
            recurrence = result.todo.recurrence,
            recurrenceInterval = result.todo.recurrenceInterval,
            recurrenceUntilMillis = result.todo.recurrenceUntilMillis,
            reminderMinutesBefore = result.todo.reminderMinutesBefore,
            completed = result.todo.completed,
            reminderState = result.reminderState,
        )
        _state.update { state ->
            val existing = state.todos.indexOfFirst { it.id == row.id }
            val todos = if (existing >= 0) {
                state.todos.toMutableList().also { it[existing] = row }
            } else {
                state.todos + row
            }
            state.copy(
                todos = todos.sortedWith(
                    compareBy<TodoRowUi> { it.completed }.thenBy { it.dueAtMillis ?: Long.MAX_VALUE },
                ),
                todoTotal = maxOf(state.todoTotal, todos.size),
            )
        }
    }

    // MARK: Reminder platform

    override fun arm(
        todoID: String,
        reminderAtMillis: Long,
        dueAtMillis: Long,
        occurrenceKey: String,
        allDay: Boolean,
        timeZone: String,
    ): TodoReminderArmUi {
        val result = scheduler.arm(
            todoID = todoID,
            reminderAtMillis = reminderAtMillis,
            dueAtMillis = dueAtMillis,
            occurrenceKey = occurrenceKey,
            allDay = allDay,
            timeZone = timeZone,
        )
        return result
    }

    override fun disarm(todoID: String) {
        scheduler.cancel(todoID)
    }

    override suspend fun rearmTodos(): Boolean = rearmTodosInternal()

    private suspend fun rearmTodosInternal(): Boolean {
        val owner = owner() ?: return false
        return try {
            val plans = withContext(ioDispatcher) { client.reminderPlans(owner) }
            withContext(ioDispatcher) {
                scheduler.applyPlans(plans.map {
                    TodoReminderPlanUi(
                        todoID = it.todoID,
                        reminderAtMillis = it.reminderAtMillis,
                        dueAtMillis = it.dueAtMillis,
                        occurrenceKey = it.occurrenceKey,
                        allDay = it.allDay,
                        timeZone = it.timeZone,
                    )
                })
            }
            true
        } catch (_: C06CalendarClientFailure) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    override suspend fun deliverReminder(todoID: String, occurrenceKey: String): Boolean {
        val owner = owner() ?: return false
        val due = try {
            withContext(ioDispatcher) {
                client.reminderDue(owner, todoID, occurrenceKey)
            }
        } catch (failure: C06CalendarClientFailure) {
            return false
        } ?: return true
        if (!scheduler.notificationsUsable()) return true
        val posted = withContext(ioDispatcher) {
            scheduler.postNotification(
                todoID = due.todo.id,
                revision = due.todo.revision,
                title = due.todo.title,
                dueAtMillis = due.plan.dueAtMillis,
                allDay = due.plan.allDay,
                timeZone = due.plan.timeZone,
            )
        }
        if (!posted) return false
        withContext(ioDispatcher) {
            runCatching { client.markReminderShown(owner, todoID, occurrenceKey) }
        }
        // A recurring todo owns the NEXT occurrence too. Arm only this todo's
        // next plan; never a full rearm pass here, which would cancel the
        // reminder notification just posted for a one-shot todo.
        runCatching {
            val plans = withContext(ioDispatcher) { client.reminderPlans(owner) }
            plans.firstOrNull { it.todoID.equals(todoID, ignoreCase = true) }?.let { next ->
                withContext(ioDispatcher) {
                    scheduler.arm(
                        todoID = next.todoID,
                        reminderAtMillis = next.reminderAtMillis,
                        dueAtMillis = next.dueAtMillis,
                        occurrenceKey = next.occurrenceKey,
                        allDay = next.allDay,
                        timeZone = next.timeZone,
                    )
                }
            }
        }
        return true
    }

    // MARK: Route

    fun openTodoFromRoute(todoID: String) {
        val existing = _state.value.todos.firstOrNull { it.id == todoID }
        if (existing != null) {
            _state.update { it.copy(selectedTodoID = existing.id, notice = null) }
            return
        }
        val owner = owner() ?: return
        scope.launch {
            withContext(ioDispatcher) {
                try {
                    val todo = client.todoGet(owner, todoID)
                    applyTodoMutation(
                        TodoMutationUi(todo, null, false, "none", null),
                    )
                    _state.update { it.copy(selectedTodoID = todo.id, notice = null) }
                } catch (failure: C06CalendarClientFailure) {
                    _state.update {
                        it.copy(selectedTodoID = null, notice = "todoMissing", todoError = failure.code)
                    }
                }
            }
        }
    }

    fun clearSelectedTodo() {
        _state.update { it.copy(selectedTodoID = null) }
    }

    // MARK: Helpers

    private fun owner(): C06CalendarOwnerRef? {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return null
        return C06CalendarOwnerRef(ownerToken, epoch)
    }

    private fun calendarRow(row: com.floe.android.core.calendar.CalendarSummaryRow): CalendarRowUi =
        CalendarRowUi(
            id = row.id,
            displayName = row.displayName,
            accountName = row.accountName,
            timeZone = row.timeZone,
            color = row.color,
            writable = row.writable,
            visible = row.visible,
            isPrimary = row.isPrimary,
        )

    private fun eventRow(row: CalendarEventRow): CalendarEventRowUi = CalendarEventRowUi(
        eventID = row.eventID,
        calendarID = row.calendarID,
        calendarName = row.calendarName,
        title = row.title,
        startMillis = row.startMillis,
        endMillis = row.endMillis,
        allDay = row.allDay,
        timeZone = row.timeZone,
        recurrence = row.recurrence,
        occurrence = CalendarProviderRules.occurrenceToken(row.eventID, row.startMillis),
        recurring = row.recurring,
        detached = row.detached,
    )

    private fun todoRow(row: TodoRecordUi): TodoRowUi = TodoRowUi(
        id = row.id,
        revision = row.revision,
        title = row.title,
        notes = row.notes,
        dueAtMillis = row.dueAtMillis,
        dueTimeZone = row.dueTimeZone,
        allDay = row.allDay,
        recurrence = row.recurrence,
        recurrenceInterval = row.recurrenceInterval,
        recurrenceUntilMillis = row.recurrenceUntilMillis,
        reminderMinutesBefore = row.reminderMinutesBefore,
        completed = row.completed,
        reminderState = null,
    )

    private fun selectedCalendarID(): Long? {
        val value = preferences.getLong(KEY_SELECTED_CALENDAR, -1L)
        return value.takeIf { it > 0 }
    }

    private fun saveSelectedCalendarID(id: Long?) {
        preferences.edit().apply {
            if (id == null) remove(KEY_SELECTED_CALENDAR) else putLong(KEY_SELECTED_CALENDAR, id)
        }.apply()
    }

    private fun permissionState(granted: Boolean, key: String): CalendarPermissionState =
        if (granted) CalendarPermissionState.GRANTED
        else if (preferences.getBoolean(key, false)) CalendarPermissionState.DENIED
        else CalendarPermissionState.NOT_REQUESTED

    private fun notificationPermissionState(): CalendarPermissionState {
        if (scheduler.notificationsUsable()) return CalendarPermissionState.GRANTED
        return if (android.os.Build.VERSION.SDK_INT >= 33) CalendarPermissionState.DENIED
        else CalendarPermissionState.NOT_REQUESTED
    }

    private fun loadNotificationState() {
        _state.update {
            it.copy(
                notificationsEnabled = scheduler.notificationsUsable(),
                exactAlarmAllowed = scheduler.exactAlarmAllowed(),
                notificationPermission = notificationPermissionState(),
            )
        }
    }

    private fun effectiveZone(allDay: Boolean, requested: String): String =
        if (allDay) "UTC" else CalendarProviderRules.validTimeZone(requested)
            ?: ZoneId.systemDefault().id

    private fun rrule(kind: String): String = when (kind) {
        "daily" -> "FREQ=DAILY"
        "weekly" -> "FREQ=WEEKLY"
        "monthly" -> "FREQ=MONTHLY"
        "yearly" -> "FREQ=YEARLY"
        else -> ""
    }

    private fun recurrenceKind(raw: String?): String {
        val value = raw?.uppercase().orEmpty()
        return when {
            value.contains("FREQ=DAILY") -> "daily"
            value.contains("FREQ=WEEKLY") -> "weekly"
            value.contains("FREQ=MONTHLY") -> "monthly"
            value.contains("FREQ=YEARLY") -> "yearly"
            else -> "none"
        }
    }

    private fun normalizeTodoDue(millis: Long, allDay: Boolean, timeZone: String): Long {
        if (!allDay) return millis
        // The editor's all-day picker already returns UTC midnight for the
        // chosen calendar date. Re-projecting it through the user's zone would
        // shift the date west of UTC; the stored value must stay canonical.
        if (Math.floorMod(millis, 86_400_000L) != 0L) {
            throw C06CalendarClientFailure("invalidDue", "all_day_due_must_be_utc_midnight")
        }
        return millis
    }

    private fun reminderNotice(state: String): String = when (state) {
        "scheduled" -> "reminderScheduled"
        "inexact" -> "reminderInexact"
        "notificationsBlocked" -> "reminderBlocked"
        "armFailed" -> "reminderFailed"
        else -> "todoSaved"
    }

    private fun todayStart(): Long =
        LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()

    private fun nextHourMillis(zoneId: String): Long {
        val zone = runCatching { ZoneId.of(zoneId) }.getOrElse { ZoneId.systemDefault() }
        val now = Instant.now().atZone(zone)
        val next = now.plusHours(1).withMinute(0).withSecond(0).withNano(0)
        return next.toInstant().toEpochMilli()
    }

    private fun CalendarProviderFailure.wireCode(): String = when (code) {
        CalendarProviderFailureCode.PERMISSION_DENIED -> "permissionDenied"
        CalendarProviderFailureCode.WRITE_PERMISSION_DENIED -> "writePermissionDenied"
        CalendarProviderFailureCode.PROVIDER_ABSENT -> "providerAbsent"
        CalendarProviderFailureCode.NO_CALENDARS -> "noCalendars"
        CalendarProviderFailureCode.CALENDAR_MISSING -> "calendarMissing"
        CalendarProviderFailureCode.CALENDAR_NOT_WRITABLE -> "calendarNotWritable"
        CalendarProviderFailureCode.EVENT_NOT_FOUND -> "eventNotFound"
        CalendarProviderFailureCode.OCCURRENCE_NOT_FOUND -> "occurrenceNotFound"
        CalendarProviderFailureCode.STALE_OCCURRENCE -> "staleOccurrence"
        CalendarProviderFailureCode.OCCURRENCE_REQUIRED -> "staleOccurrence"
        CalendarProviderFailureCode.UNSUPPORTED_RECURRENCE -> "unsupportedRecurrence"
        CalendarProviderFailureCode.UNSUPPORTED_SPAN -> "unsupportedSpan"
        CalendarProviderFailureCode.INVALID_RANGE -> "invalidRange"
        CalendarProviderFailureCode.INVALID_TIMEZONE -> "invalidTimezone"
        CalendarProviderFailureCode.INVALID_RECURRENCE -> "invalidRecurrence"
        CalendarProviderFailureCode.INVALID_FIELDS -> "invalidFields"
        CalendarProviderFailureCode.INVALID_ALL_DAY -> "invalidAllDay"
        CalendarProviderFailureCode.READBACK_MISMATCH -> "readbackMismatch"
        CalendarProviderFailureCode.PROVIDER_REJECTED -> "providerRejected"
        CalendarProviderFailureCode.PROVIDER_UNAVAILABLE -> "providerUnavailable"
        else -> "unknown"
    }

    private companion object {
        const val PREFS = "floe.calendar.host"
        const val KEY_SELECTED_CALENDAR = "selectedCalendarID"
        const val REQUESTED_READ = "requestedRead"
        const val REQUESTED_WRITE = "requestedWrite"
        const val PAGE = 100
        const val DAY = 86_400_000L
    }
}
