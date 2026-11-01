// SPDX-License-Identifier: MPL-2.0
//
// App-level binding between the C06 controller and the presentation module.
// CalendarContract, permissions, alarms, notifications and the Swift todo
// store stay in the app-scoped controller; this file only maps state and
// launches the ordinary system permission/date/time surfaces.

package com.floe.android.host.calendar

import android.Manifest
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.calendar.CalendarDestinationUi
import com.floe.android.feature.calendar.R
import com.floe.android.host.RuntimeHost
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

@Composable
internal fun C06CalendarDestination(
    host: RuntimeHost?,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
) {
    if (host == null) {
        FloeUnavailableView(
            icon = FloeIcons.Checklist,
            title = stringResource(R.string.calendar_title),
            description = stringResource(R.string.calendar_unavailable),
            modifier = Modifier.fillMaxSize(),
        )
        return
    }
    val controller = host.c06Calendar
    val rawState by controller.state.collectAsState()
    val permissionRequest by controller.permissionRequests.collectAsState()
    val route by C06CalendarNavigation.pending.collectAsState()
    val context = LocalContext.current
    var pendingWrite by remember { mutableStateOf(false) }
    val state = rawState.copy(
        notice = rawState.notice?.let { noticeKey ->
            noticeText(noticeKey, rawState.todoError)
        },
    )

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { result ->
        val write = pendingWrite
        val granted = if (write) {
            result[Manifest.permission.READ_CALENDAR] == true &&
                result[Manifest.permission.WRITE_CALENDAR] == true
        } else {
            result[Manifest.permission.READ_CALENDAR] == true
        }
        controller.onPermissionResult(write, granted)
    }
    val notificationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        controller.onAppForeground()
        if (!granted) controller.openNotificationSettings()
    }
    LaunchedEffect(controller) { controller.enter() }
    val activity = context as? androidx.activity.ComponentActivity
    DisposableEffect(activity, controller) {
        if (activity == null) return@DisposableEffect onDispose { }
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                controller.onAppForeground()
            }
        }
        activity.lifecycle.addObserver(observer)
        onDispose { activity.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(permissionRequest) {
        val request = permissionRequest ?: return@LaunchedEffect
        pendingWrite = request.write
        val permissions = if (request.write) {
            arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)
        } else {
            arrayOf(Manifest.permission.READ_CALENDAR)
        }
        permissionLauncher.launch(permissions)
    }
    LaunchedEffect(route?.requestID) {
        val request = route ?: return@LaunchedEffect
        if (C06CalendarNavigation.isExpired(request)) {
            C06CalendarNavigation.dismiss(request.requestID)
            return@LaunchedEffect
        }
        controller.openTodoFromRoute(request.todoID)
        C06CalendarNavigation.consume(request.requestID)
    }

    CalendarDestinationUi(
        state = state,
        compact = compact,
        showSidebarToggle = showSidebarToggle,
        onExpandSidebar = onExpandSidebar,
        onOpenDrawer = onOpenDrawer,
        onTabSelect = { tab -> controller.setTab(tab) },
        onRequestRead = { controller.requestPermission(write = false) },
        onRequestWrite = { controller.requestPermission(write = true) },
        onOpenAppSettings = { controller.openAppSettings() },
        onSelectCalendar = { controller.selectCalendar(it) },
        onSelectRange = { controller.selectRange(it) },
        onRetry = { controller.refresh() },
        onLoadMoreEvents = { controller.loadMoreEvents() },
        onNewEvent = { controller.newEvent() },
        onEditEvent = { controller.editEvent(it) },
        onCloseEventEditor = { controller.closeEventEditor() },
        onSaveEvent = { controller.saveEventDraft(it) },
        onEventDraftChange = { controller.updateEventDraft(it) },
        onPickStart = {
            val draft = rawState.eventEditor
            if (draft != null) {
                pickDateTime(
                    context = context,
                    currentMillis = draft.startMillis,
                    allDay = draft.allDay,
                    zoneId = draft.timeZone,
                ) { picked ->
                    controller.updateEventDraft(draft.copy(startMillis = picked))
                }
            }
        },
        onPickEnd = {
            val draft = rawState.eventEditor
            if (draft != null) {
                pickDateTime(
                    context = context,
                    currentMillis = draft.endMillis,
                    allDay = draft.allDay,
                    zoneId = draft.timeZone,
                ) { picked ->
                    controller.updateEventDraft(draft.copy(endMillis = picked))
                }
            }
        },
        onRequestDeleteEvent = { controller.requestDeleteEvent(it) },
        onConfirmDeleteEvent = { controller.confirmDeleteEvent() },
        onDismissDeleteEvent = { controller.dismissDeleteEvent() },
        onNewTodo = { controller.newTodo() },
        onEditTodo = { controller.editTodo(it) },
        onCloseTodoEditor = { controller.closeTodoEditor() },
        onSaveTodo = { controller.saveTodoDraft(it) },
        onTodoDraftChange = { controller.updateTodoDraft(it) },
        onPickTodoDue = {
            val draft = rawState.todoEditor
            if (draft != null) {
                pickDateTime(
                    context = context,
                    currentMillis = draft.dueAtMillis ?: System.currentTimeMillis(),
                    allDay = draft.allDay,
                    zoneId = draft.timeZone,
                ) { picked ->
                    controller.updateTodoDraft(draft.copy(dueAtMillis = picked))
                }
            }
        },
        onToggleTodo = { controller.toggleTodo(it) },
        onDeleteTodo = { controller.requestDeleteTodo(it) },
        onConfirmDeleteTodo = { controller.confirmDeleteTodo() },
        onDismissDeleteTodo = { controller.dismissDeleteTodo() },
        onShowCompleted = { controller.setShowCompleted(it) },
        onLoadMoreTodos = { controller.loadMoreTodos() },
        onOpenNotificationSettings = {
            if (Build.VERSION.SDK_INT >= 33 &&
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                controller.openNotificationSettings()
            }
        },
        onOpenExactAlarmSettings = { controller.openExactAlarmSettings() },
        onDismissNotice = { controller.dismissNotice() },
    )
}

@Composable
private fun noticeText(key: String, todoError: String?): String = when (key) {
    "created" -> stringResource(R.string.calendar_created)
    "updated" -> stringResource(R.string.calendar_updated)
    "deleted" -> stringResource(R.string.calendar_deleted)
    "todoSaved" -> stringResource(R.string.calendar_todo_saved)
    "todoDeleted" -> stringResource(R.string.calendar_todo_deleted)
    "reminderScheduled" -> stringResource(R.string.calendar_todo_reminder_scheduled)
    "reminderInexact" -> stringResource(R.string.calendar_todo_reminder_inexact)
    "reminderBlocked" -> stringResource(R.string.calendar_todo_reminder_blocked)
    "reminderFailed" -> stringResource(R.string.calendar_todo_reminder_failed)
    "todoMissing" -> stringResource(R.string.calendar_todo_missing)
    "selectionLost" -> stringResource(R.string.calendar_choose_writable)
    "chooseWritableCalendar" -> stringResource(R.string.calendar_choose_writable)
    "writePermissionDenied" -> stringResource(R.string.calendar_error_write_permission)
    else -> todoError ?: key
}

private fun pickDateTime(
    context: android.content.Context,
    currentMillis: Long,
    allDay: Boolean,
    zoneId: String,
    onPicked: (Long) -> Unit,
) {
    val zone = runCatching { ZoneId.of(zoneId) }.getOrElse { ZoneId.systemDefault() }
    val current = Instant.ofEpochMilli(currentMillis).atZone(zone)
    DatePickerDialog(
        context,
        { _, year, month, day ->
            if (allDay) {
                val utc = LocalDate.of(year, month + 1, day)
                    .atStartOfDay(ZoneId.of("UTC")).toInstant().toEpochMilli()
                onPicked(utc)
            } else {
                TimePickerDialog(
                    context,
                    { _, hour, minute ->
                        val value = ZonedDateTime.of(
                            LocalDate.of(year, month + 1, day),
                            LocalTime.of(hour, minute),
                            zone,
                        ).toInstant().toEpochMilli()
                        onPicked(value)
                    },
                    current.hour,
                    current.minute,
                    true,
                ).show()
            }
        },
        current.year,
        current.monthValue - 1,
        current.dayOfMonth,
    ).show()
}
