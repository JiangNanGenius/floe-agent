// SPDX-License-Identifier: MPL-2.0
//
// C06 calendar and todo screens. Presentation only: every provider query,
// write, permission, alarm, notification and CAS lives in the App-owned
// `app/host/calendar` controller / original Swift todo store.

package com.floe.android.feature.calendar

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeChoiceMenu
import com.floe.android.design.FloeChoiceOption
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeSectionHeader
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

@Composable
fun CalendarDestinationUi(
    state: CalendarScreenState,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onTabSelect: (Int) -> Unit,
    onRequestRead: () -> Unit,
    onRequestWrite: () -> Unit,
    onOpenAppSettings: () -> Unit,
    onSelectCalendar: (Long?) -> Unit,
    onSelectRange: (Int) -> Unit,
    onRetry: () -> Unit,
    onLoadMoreEvents: () -> Unit,
    onNewEvent: () -> Unit,
    onEditEvent: (CalendarEventRowUi) -> Unit,
    onCloseEventEditor: () -> Unit,
    onSaveEvent: (CalendarEventDraftUi) -> Unit,
    onEventDraftChange: (CalendarEventDraftUi) -> Unit,
    onPickStart: () -> Unit,
    onPickEnd: () -> Unit,
    onRequestDeleteEvent: (CalendarEventDraftUi) -> Unit,
    onConfirmDeleteEvent: () -> Unit,
    onDismissDeleteEvent: () -> Unit,
    onNewTodo: () -> Unit,
    onEditTodo: (TodoRowUi) -> Unit,
    onCloseTodoEditor: () -> Unit,
    onSaveTodo: (TodoDraftUi) -> Unit,
    onTodoDraftChange: (TodoDraftUi) -> Unit,
    onPickTodoDue: () -> Unit,
    onToggleTodo: (TodoRowUi) -> Unit,
    onDeleteTodo: (TodoRowUi) -> Unit,
    onConfirmDeleteTodo: () -> Unit,
    onDismissDeleteTodo: () -> Unit,
    onShowCompleted: (Boolean) -> Unit,
    onLoadMoreTodos: () -> Unit,
    onOpenNotificationSettings: () -> Unit,
    onOpenExactAlarmSettings: () -> Unit,
    onDismissNotice: () -> Unit,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = stringResource(R.string.calendar_title),
            navigation = {
                if (!compact) {
                    if (showSidebarToggle) {
                        FloeCircleButton(
                            icon = FloeIcons.SidebarToggle,
                            contentDescription = stringResource(R.string.calendar_open_sidebar),
                            onClick = onExpandSidebar,
                            visualSize = 36.dp,
                            iconSize = 18.dp,
                        )
                    }
                } else {
                    FloeCircleButton(
                        icon = FloeIcons.SidebarToggle,
                        contentDescription = stringResource(R.string.calendar_title),
                        onClick = onOpenDrawer,
                        visualSize = 36.dp,
                        iconSize = 18.dp,
                    )
                }
            },
            actions = {
                if (state.tab == 0 && state.hasWriteAccess) {
                    FloeCapsuleAction(label = stringResource(R.string.calendar_new_event), onClick = onNewEvent)
                }
                if (state.tab == 1) {
                    FloeCapsuleAction(label = stringResource(R.string.calendar_todo_new), onClick = onNewTodo)
                }
            },
            showHairline = true,
            background = Floe.colors.chromeSurface,
        )

        if (state.loading) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                FloeActivityIndicator()
            }
            return@Column
        }

        FloeSegmented(
            options = listOf(
                stringResource(R.string.calendar_tab_calendar),
                stringResource(R.string.calendar_tab_todos),
            ),
            selectedIndex = state.tab,
            onSelect = onTabSelect,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
        )

        state.notice?.let { notice ->
            NoticeBanner(notice, onDismissNotice)
        }

        if (state.tab == 1) {
            // Todos are independent App-local data. Calendar permission,
            // provider absence and an account being unconfigured are calendar
            // states and must never hide the todo/reminder controls.
            TodoTab(
                state = state,
                onToggleTodo = onToggleTodo,
                onEditTodo = onEditTodo,
                onDeleteTodo = onDeleteTodo,
                onShowCompleted = onShowCompleted,
                onLoadMoreTodos = onLoadMoreTodos,
                onOpenNotificationSettings = onOpenNotificationSettings,
                onOpenExactAlarmSettings = onOpenExactAlarmSettings,
                onRetry = onRetry,
            )
        } else {
            when {
                !state.providerAvailable -> EmptyState(
                    title = stringResource(R.string.calendar_provider_absent_title),
                    body = stringResource(R.string.calendar_provider_absent_body),
                    action = stringResource(R.string.calendar_open_settings),
                    onAction = onOpenAppSettings,
                )
                state.readPermission != CalendarPermissionState.GRANTED -> EmptyState(
                    title = stringResource(R.string.calendar_permission_title),
                    body = stringResource(R.string.calendar_permission_body),
                    action = stringResource(R.string.calendar_allow),
                    onAction = onRequestRead,
                )
                state.calendars.isEmpty() -> EmptyState(
                    title = stringResource(R.string.calendar_no_calendars_title),
                    body = stringResource(R.string.calendar_no_calendars_body),
                    action = stringResource(R.string.calendar_open_settings),
                    onAction = onOpenAppSettings,
                )
                else -> CalendarTab(
                    state = state,
                    onRequestWrite = onRequestWrite,
                    onOpenAppSettings = onOpenAppSettings,
                    onSelectCalendar = onSelectCalendar,
                    onSelectRange = onSelectRange,
                    onLoadMoreEvents = onLoadMoreEvents,
                    onEditEvent = onEditEvent,
                    onNewEvent = onNewEvent,
                )
            }
        }
    }

    state.eventEditor?.let { draft ->
        CalendarEventEditorSheet(
            draft = draft,
            state = state,
            onChange = onEventDraftChange,
            onDismiss = onCloseEventEditor,
            onSave = { onSaveEvent(draft) },
            onDelete = { onRequestDeleteEvent(draft) },
            onPickStart = onPickStart,
            onPickEnd = onPickEnd,
            onRequestWrite = onRequestWrite,
        )
    }

    state.todoEditor?.let { draft ->
        TodoEditorSheet(
            draft = draft,
            onChange = onTodoDraftChange,
            onDismiss = onCloseTodoEditor,
            onSave = { onSaveTodo(draft) },
            onPickDue = onPickTodoDue,
        )
    }

    state.eventDeleteRequest?.let { draft ->
        FloeConfirmDialog(
            title = stringResource(R.string.calendar_delete_event_title),
            message = stringResource(R.string.calendar_delete_event_message),
            confirmLabel = stringResource(
                if (draft.recurring) R.string.calendar_delete_future else R.string.calendar_delete_this,
            ),
            dismissLabel = stringResource(R.string.calendar_cancel),
            onConfirm = onConfirmDeleteEvent,
            onDismiss = onDismissDeleteEvent,
        )
    }

    state.todoDeleteRequest?.let {
        FloeConfirmDialog(
            title = stringResource(R.string.calendar_todo_delete_title),
            message = stringResource(R.string.calendar_todo_delete_message),
            confirmLabel = stringResource(R.string.calendar_todo_delete),
            dismissLabel = stringResource(R.string.calendar_cancel),
            onConfirm = onConfirmDeleteTodo,
            onDismiss = onDismissDeleteTodo,
        )
    }
}

@Composable
private fun CalendarTab(
    state: CalendarScreenState,
    onRequestWrite: () -> Unit,
    onOpenAppSettings: () -> Unit,
    onSelectCalendar: (Long?) -> Unit,
    onSelectRange: (Int) -> Unit,
    onLoadMoreEvents: () -> Unit,
    onEditEvent: (CalendarEventRowUi) -> Unit,
    onNewEvent: () -> Unit,
) {
    var calendarMenu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box {
                FloeCapsuleAction(
                    label = state.selectedCalendar?.displayName
                        ?: stringResource(R.string.calendar_all_calendars),
                    onClick = { calendarMenu = true },
                )
                FloeChoiceMenu(
                    expanded = calendarMenu,
                    onDismissRequest = { calendarMenu = false },
                    options = buildList {
                        add(FloeChoiceOption("all", stringResource(R.string.calendar_all_calendars)))
                        state.calendars.forEach { calendar ->
                            add(FloeChoiceOption(calendar.id.toString(), calendar.displayName))
                        }
                    },
                    selectedKey = state.selectedCalendarID?.toString() ?: "all",
                    onSelect = { key ->
                        calendarMenu = false
                        onSelectCalendar(key.toLongOrNull())
                    },
                )
            }
            FloeCapsuleAction(stringResource(R.string.calendar_range_today), { onSelectRange(0) })
            FloeCapsuleAction(stringResource(R.string.calendar_range_week), { onSelectRange(1) })
            FloeCapsuleAction(stringResource(R.string.calendar_range_month), { onSelectRange(2) })
        }

        if (state.writePermission != CalendarPermissionState.GRANTED) {
            ReminderBanner(
                text = stringResource(R.string.calendar_permission_write_body),
                action = stringResource(R.string.calendar_allow_write),
                onAction = onRequestWrite,
            )
        } else if (state.writableCalendars.isEmpty()) {
            ReminderBanner(
                text = stringResource(R.string.calendar_no_writable_body),
                action = stringResource(R.string.calendar_open_settings),
                onAction = onOpenAppSettings,
            )
        }
        if (state.hasWriteAccess && state.selectedCalendarID == null) {
            ReminderBanner(
                text = stringResource(R.string.calendar_choose_writable),
                action = stringResource(R.string.calendar_new_event),
                onAction = onNewEvent,
            )
        }
        state.calendarError?.let { code ->
            ErrorBanner(calendarErrorText(code), onRetry = onOpenAppSettings)
        }

        if (state.eventLoading && state.events.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { FloeActivityIndicator() }
            return@Column
        }
        if (state.events.isEmpty()) {
            EmptyState(
                title = stringResource(R.string.calendar_no_events_title),
                body = stringResource(R.string.calendar_no_events_body),
                action = null,
                onAction = {},
            )
            return@Column
        }
        LazyColumn(Modifier.fillMaxSize()) {
            var currentDay: String? = null
            state.events.forEach { event ->
                val zone = event.timeZone.ifBlank { ZoneId.systemDefault().id }
                val day = CalendarPresentation.dayKey(event.startMillis, zone)
                if (day != currentDay) {
                    currentDay = day
                    item(key = "day-$day") {
                        FloeSectionHeader(day)
                    }
                }
                item(key = "event-${event.eventID}-${event.occurrence}") {
                    EventRow(event, onClick = { onEditEvent(event) })
                }
            }
            if (state.eventHasMore) {
                item(key = "more") {
                    Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.calendar_load_more),
                            onClick = onLoadMoreEvents,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun EventRow(event: CalendarEventRowUi, onClick: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                FloeText(event.title, style = Floe.typography.bodyEmphasized)
                FloeText(
                    formatEventRange(event),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeText(
                    buildString {
                        append(event.calendarName)
                        if (event.recurring) append(" · ").append(stringResource(R.string.calendar_series_label))
                    },
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
            }
            if (event.recurring) {
                FloeCapsuleAction(label = stringResource(R.string.calendar_occurrence_label), onClick = onClick)
            }
        }
    }
    FloeDivider()
}

@Composable
private fun TodoTab(
    state: CalendarScreenState,
    onToggleTodo: (TodoRowUi) -> Unit,
    onEditTodo: (TodoRowUi) -> Unit,
    onDeleteTodo: (TodoRowUi) -> Unit,
    onShowCompleted: (Boolean) -> Unit,
    onLoadMoreTodos: () -> Unit,
    onOpenNotificationSettings: () -> Unit,
    onOpenExactAlarmSettings: () -> Unit,
    onRetry: () -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        if (!state.notificationsEnabled) {
            ReminderBanner(
                text = stringResource(R.string.calendar_notifications_disabled),
                action = stringResource(R.string.calendar_enable_notifications),
                onAction = onOpenNotificationSettings,
            )
        } else if (!state.exactAlarmAllowed) {
            ReminderBanner(
                text = stringResource(R.string.calendar_exact_disabled),
                action = stringResource(R.string.calendar_allow_exact),
                onAction = onOpenExactAlarmSettings,
            )
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                stringResource(R.string.calendar_todo_show_completed),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.calendar_todo_show_completed),
                onClick = { onShowCompleted(!state.showCompleted) },
                tint = if (state.showCompleted) Floe.colors.accent else null,
            )
        }
        state.todoError?.let { code ->
            ErrorBanner(todoErrorText(code), onRetry = onRetry)
        }
        if (state.todoLoading && state.todos.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { FloeActivityIndicator() }
            return@Column
        }
        if (state.todos.isEmpty()) {
            EmptyState(
                title = stringResource(R.string.calendar_todo_empty_title),
                body = stringResource(R.string.calendar_todo_empty_body),
                action = null,
                onAction = {},
            )
            return@Column
        }
        LazyColumn(Modifier.fillMaxSize()) {
            items(state.todos, key = { it.id }) { todo ->
                TodoRow(
                    todo = todo,
                    selected = todo.id == state.selectedTodoID,
                    onToggle = { onToggleTodo(todo) },
                    onEdit = { onEditTodo(todo) },
                    onDelete = { onDeleteTodo(todo) },
                )
            }
            if (state.todos.size < state.todoTotal) {
                item(key = "todo-more") {
                    Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.calendar_load_more),
                            onClick = onLoadMoreTodos,
                        )
                    }
                }
            }
            item(key = "reminder-note") {
                FloeText(
                    stringResource(R.string.calendar_reminder_note),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                    modifier = Modifier.padding(20.dp),
                )
            }
        }
    }
}

@Composable
private fun TodoRow(
    todo: TodoRowUi,
    selected: Boolean,
    onToggle: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(if (selected) Floe.colors.fillTertiary else Floe.colors.readingSurface)
            .clickable(onClick = onEdit)
            .padding(horizontal = 20.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                FloeText(
                    todo.title,
                    style = Floe.typography.bodyEmphasized,
                    color = if (todo.completed) Floe.colors.secondaryLabel else Floe.colors.label,
                )
                val due = todo.dueAtMillis?.let { formatTodoDue(it, todo.allDay, todo.dueTimeZone) }
                if (due != null) {
                    FloeText(due, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
                val detail = buildList {
                    if (todo.recurrence != "none") add(todo.recurrence)
                    todo.reminderMinutesBefore?.let { add(reminderText(it)) }
                    if (todo.completed) add(stringResource(R.string.calendar_todo_completed))
                }.joinToString(" · ")
                if (detail.isNotEmpty()) {
                    FloeText(detail, style = Floe.typography.metadata, color = Floe.colors.tertiaryLabel)
                }
            }
            FloeCapsuleAction(
                label = stringResource(
                    if (todo.completed) R.string.calendar_todo_reopen else R.string.calendar_todo_complete,
                ),
                onClick = onToggle,
            )
            Box(Modifier.width(6.dp))
            FloeCapsuleAction(
                label = stringResource(R.string.calendar_todo_delete),
                onClick = onDelete,
                tint = Floe.colors.destructive,
            )
        }
    }
    FloeDivider()
}

@Composable
private fun CalendarEventEditorSheet(
    draft: CalendarEventDraftUi,
    state: CalendarScreenState,
    onChange: (CalendarEventDraftUi) -> Unit,
    onDismiss: () -> Unit,
    onSave: () -> Unit,
    onDelete: () -> Unit,
    onPickStart: () -> Unit,
    onPickEnd: () -> Unit,
    onRequestWrite: () -> Unit,
) {
    var calendarMenu by remember { mutableStateOf(false) }
    var recurrenceMenu by remember { mutableStateOf(false) }
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.92f,
        heightFraction = 0.92f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize().padding(20.dp).verticalScroll(rememberScrollState())) {
            FloeText(
                stringResource(if (draft.mode == "create") R.string.calendar_new_event else R.string.calendar_edit_event),
                style = Floe.typography.toolbarTitle,
            )
            Spacer(Modifier.height(12.dp))
            if (state.writePermission != CalendarPermissionState.GRANTED) {
                FloePrimaryAction(
                    stringResource(R.string.calendar_allow_write),
                    onClick = onRequestWrite,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(12.dp))
            }
            FloePlainFormField(
                label = stringResource(R.string.calendar_title_hint),
                value = draft.title,
                onValueChange = { onChange(draft.copy(title = it)) },
            )
            Spacer(Modifier.height(10.dp))
            if (draft.mode == "create") {
                Box {
                    FloeCapsuleAction(
                        label = draft.calendarID?.let { id ->
                            state.calendars.firstOrNull { it.id == id }?.displayName
                        } ?: stringResource(R.string.calendar_select_calendar),
                        onClick = { calendarMenu = true },
                    )
                    FloeChoiceMenu(
                        expanded = calendarMenu,
                        onDismissRequest = { calendarMenu = false },
                        options = state.writableCalendars.map {
                            FloeChoiceOption(it.id.toString(), it.displayName)
                        },
                        selectedKey = draft.calendarID?.toString(),
                        onSelect = { key ->
                            calendarMenu = false
                            onChange(draft.copy(calendarID = key.toLongOrNull()))
                        },
                    )
                }
                Spacer(Modifier.height(10.dp))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleAction(formatDraftDateTime(draft.startMillis, draft.allDay, draft.timeZone), onPickStart)
                FloeCapsuleAction(formatDraftDateTime(draft.endMillis, draft.allDay, draft.timeZone), onPickEnd)
            }
            Spacer(Modifier.height(10.dp))
            FloeCapsuleAction(
                label = stringResource(R.string.calendar_all_day),
                onClick = { onChange(toggleEventAllDay(draft)) },
                tint = if (draft.allDay) Floe.colors.accent else null,
            )
            if (draft.mode != "create" && draft.recurring) {
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.calendar_span_this),
                        onClick = { onChange(draft.copy(span = "thisEvent")) },
                        tint = if (draft.span == "thisEvent") Floe.colors.accent else null,
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.calendar_span_future),
                        onClick = { onChange(draft.copy(span = "futureEvents")) },
                        tint = if (draft.span == "futureEvents") Floe.colors.accent else null,
                    )
                }
            }
            Spacer(Modifier.height(10.dp))
            Box {
                FloeCapsuleAction(
                    label = recurrenceLabel(draft.recurrence),
                    onClick = { recurrenceMenu = true },
                )
                FloeChoiceMenu(
                    expanded = recurrenceMenu,
                    onDismissRequest = { recurrenceMenu = false },
                    options = listOf("none", "daily", "weekly", "monthly", "yearly").map {
                        FloeChoiceOption(it, recurrenceLabel(it))
                    },
                    selectedKey = draft.recurrence,
                    onSelect = { value ->
                        recurrenceMenu = false
                        onChange(draft.copy(recurrence = value))
                    },
                )
            }
            Spacer(Modifier.height(10.dp))
            FloePlainFormField(
                label = stringResource(R.string.calendar_location_hint),
                value = draft.location,
                onValueChange = { onChange(draft.copy(location = it)) },
            )
            Spacer(Modifier.height(10.dp))
            FloePlainFormField(
                label = stringResource(R.string.calendar_notes_hint),
                value = draft.notes,
                onValueChange = { onChange(draft.copy(notes = it)) },
                singleLine = false,
                minLines = 3,
                maxLines = 6,
            )
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FloePrimaryAction(
                    label = stringResource(R.string.calendar_save),
                    onClick = onSave,
                    enabled = state.busyAction == null,
                    modifier = Modifier.weight(1f),
                )
                if (draft.mode != "create") {
                    FloeCapsuleAction(
                        label = stringResource(R.string.calendar_delete_event),
                        onClick = onDelete,
                        tint = Floe.colors.destructive,
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            FloeText(
                stringResource(R.string.calendar_content_trust),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
        }
    }
}

@Composable
private fun TodoEditorSheet(
    draft: TodoDraftUi,
    onChange: (TodoDraftUi) -> Unit,
    onDismiss: () -> Unit,
    onSave: () -> Unit,
    onPickDue: () -> Unit,
) {
    var reminderMenu by remember { mutableStateOf(false) }
    var recurrenceMenu by remember { mutableStateOf(false) }
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.92f,
        heightFraction = 0.92f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize().padding(20.dp).verticalScroll(rememberScrollState())) {
            FloeText(
                stringResource(if (draft.mode == "create") R.string.calendar_todo_new else R.string.calendar_todo_edit),
                style = Floe.typography.toolbarTitle,
            )
            Spacer(Modifier.height(12.dp))
            FloePlainFormField(
                label = stringResource(R.string.calendar_todo_title_hint),
                value = draft.title,
                onValueChange = { onChange(draft.copy(title = it)) },
            )
            Spacer(Modifier.height(10.dp))
            FloeCapsuleAction(
                label = draft.dueAtMillis?.let {
                    formatDraftDateTime(it, draft.allDay, draft.timeZone)
                } ?: stringResource(R.string.calendar_todo_no_due),
                onClick = onPickDue,
            )
            Spacer(Modifier.height(10.dp))
            FloeCapsuleAction(
                label = stringResource(R.string.calendar_all_day),
                onClick = { onChange(toggleTodoAllDay(draft)) },
                tint = if (draft.allDay) Floe.colors.accent else null,
            )
            Spacer(Modifier.height(10.dp))
            Box {
                FloeCapsuleAction(
                    label = recurrenceLabel(draft.recurrence),
                    onClick = { recurrenceMenu = true },
                )
                FloeChoiceMenu(
                    expanded = recurrenceMenu,
                    onDismissRequest = { recurrenceMenu = false },
                    options = listOf("none", "daily", "weekly", "monthly").map {
                        FloeChoiceOption(it, recurrenceLabel(it))
                    },
                    selectedKey = draft.recurrence,
                    onSelect = { value ->
                        recurrenceMenu = false
                        onChange(draft.copy(recurrence = value))
                    },
                )
            }
            Spacer(Modifier.height(10.dp))
            Box {
                FloeCapsuleAction(
                    label = reminderText(draft.reminderMinutesBefore),
                    onClick = { reminderMenu = true },
                )
                FloeChoiceMenu(
                    expanded = reminderMenu,
                    onDismissRequest = { reminderMenu = false },
                    options = listOf(
                        FloeChoiceOption("none", stringResource(R.string.calendar_todo_reminder_none)),
                        FloeChoiceOption("0", stringResource(R.string.calendar_todo_reminder_at_due)),
                        FloeChoiceOption("5", stringResource(R.string.calendar_todo_reminder_5)),
                        FloeChoiceOption("15", stringResource(R.string.calendar_todo_reminder_15)),
                        FloeChoiceOption("30", stringResource(R.string.calendar_todo_reminder_30)),
                        FloeChoiceOption("60", stringResource(R.string.calendar_todo_reminder_60)),
                        FloeChoiceOption("1440", stringResource(R.string.calendar_todo_reminder_1440)),
                    ),
                    selectedKey = draft.reminderMinutesBefore?.toString() ?: "none",
                    onSelect = { value ->
                        reminderMenu = false
                        onChange(draft.copy(reminderMinutesBefore = value.toIntOrNull()))
                    },
                )
            }
            Spacer(Modifier.height(10.dp))
            FloePlainFormField(
                label = stringResource(R.string.calendar_todo_notes_hint),
                value = draft.notes,
                onValueChange = { onChange(draft.copy(notes = it)) },
                singleLine = false,
                minLines = 3,
                maxLines = 6,
            )
            Spacer(Modifier.height(16.dp))
            FloePrimaryAction(
                label = stringResource(R.string.calendar_save),
                onClick = onSave,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            FloeText(
                stringResource(R.string.calendar_reminder_note),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
        }
    }
}

@Composable
private fun NoticeBanner(text: String, onDismiss: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel,
            modifier = Modifier.weight(1f))
        TextButton(onClick = onDismiss) { FloeText(stringResource(R.string.calendar_dismiss)) }
    }
}

@Composable
private fun ReminderBanner(text: String, action: String, onAction: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel,
            modifier = Modifier.weight(1f))
        FloeCapsuleAction(label = action, onClick = onAction)
    }
}

@Composable
private fun ErrorBanner(text: String, onRetry: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(text, style = Floe.typography.metadata, color = Floe.colors.destructive,
            modifier = Modifier.weight(1f))
        FloeCapsuleAction(label = stringResource(R.string.calendar_open_settings), onClick = onRetry)
    }
}

@Composable
private fun EmptyState(title: String, body: String, action: String?, onAction: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        FloeUnavailableView(
            icon = FloeIcons.Checklist,
            title = title,
            description = body,
            modifier = Modifier.fillMaxWidth(),
        )
        if (action != null) {
            Spacer(Modifier.height(16.dp))
            FloePrimaryAction(label = action, onClick = onAction)
        }
    }
}

@Composable
private fun recurrenceLabel(value: String): String = when (value) {
    "daily" -> stringResource(R.string.calendar_recurrence_daily)
    "weekly" -> stringResource(R.string.calendar_recurrence_weekly)
    "monthly" -> stringResource(R.string.calendar_recurrence_monthly)
    "yearly" -> stringResource(R.string.calendar_recurrence_yearly)
    else -> stringResource(R.string.calendar_recurrence_none)
}

@Composable
private fun reminderText(minutes: Int?): String = when (minutes) {
    null -> stringResource(R.string.calendar_todo_reminder_none)
    0 -> stringResource(R.string.calendar_todo_reminder_at_due)
    5 -> stringResource(R.string.calendar_todo_reminder_5)
    15 -> stringResource(R.string.calendar_todo_reminder_15)
    30 -> stringResource(R.string.calendar_todo_reminder_30)
    60 -> stringResource(R.string.calendar_todo_reminder_60)
    1440 -> stringResource(R.string.calendar_todo_reminder_1440)
    else -> "$minutes min"
}

@Composable
private fun todoErrorText(code: String): String = when (code) {
    "mutationUnknown" -> stringResource(R.string.calendar_error_mutation_unknown)
    "revisionConflict" -> stringResource(R.string.calendar_todo_conflict)
    "invalidDue" -> stringResource(R.string.calendar_reminder_requires_due)
    "invalidTitle" -> stringResource(R.string.calendar_todo_title_hint)
    "runtimeNotReady" -> stringResource(R.string.calendar_unavailable)
    else -> stringResource(R.string.calendar_error_unknown)
}

@Composable
private fun calendarErrorText(code: String): String = when (code) {
    "mutationUnknown" -> stringResource(R.string.calendar_error_mutation_unknown)
    "permissionDenied" -> stringResource(R.string.calendar_error_permission)
    "writePermissionDenied" -> stringResource(R.string.calendar_error_write_permission)
    "readbackMismatch" -> stringResource(R.string.calendar_error_readback)
    "staleOccurrence", "occurrenceNotFound" -> stringResource(R.string.calendar_error_stale)
    "calendarMissing", "calendarNotWritable", "noWritableCalendar" ->
        stringResource(R.string.calendar_error_calendar)
    "providerRejected", "providerUnavailable", "providerAbsent" ->
        stringResource(R.string.calendar_error_provider)
    else -> stringResource(R.string.calendar_error_unknown)
}

private fun formatEventRange(event: CalendarEventRowUi): String {
    val zone = runCatching { ZoneId.of(event.timeZone) }.getOrElse { ZoneId.systemDefault() }
    return if (event.allDay) {
        val start = Instant.ofEpochMilli(event.startMillis).atZone(ZoneId.of("UTC")).toLocalDate()
        val end = Instant.ofEpochMilli(event.endMillis).atZone(ZoneId.of("UTC")).toLocalDate()
        if (start == end) start.toString() else "$start – ${end.minusDays(1)}"
    } else {
        val start = Instant.ofEpochMilli(event.startMillis).atZone(zone)
        val end = Instant.ofEpochMilli(event.endMillis).atZone(zone)
        val date = DateTimeFormatter.ofPattern("MMM d", Locale.getDefault()).format(start)
        val time = DateTimeFormatter.ofPattern("HH:mm", Locale.getDefault())
        "$date · ${time.format(start)}–${time.format(end)}"
    }
}

private fun formatTodoDue(millis: Long, allDay: Boolean, zoneId: String): String {
    if (allDay) {
        return Instant.ofEpochMilli(millis).atZone(ZoneId.of("UTC")).toLocalDate().toString()
    }
    val zone = runCatching { ZoneId.of(zoneId) }.getOrElse { ZoneId.systemDefault() }
    return DateTimeFormatter.ofPattern("MMM d, HH:mm", Locale.getDefault())
        .format(Instant.ofEpochMilli(millis).atZone(zone))
}

private fun formatDraftDateTime(millis: Long, allDay: Boolean, zoneId: String): String {
    if (allDay) {
        return Instant.ofEpochMilli(millis).atZone(ZoneId.of("UTC")).toLocalDate().toString()
    }
    val zone = runCatching { ZoneId.of(zoneId) }.getOrElse { ZoneId.systemDefault() }
    return DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm", Locale.getDefault())
        .format(Instant.ofEpochMilli(millis).atZone(zone))
}

private fun toggleEventAllDay(draft: CalendarEventDraftUi): CalendarEventDraftUi {
    if (!draft.allDay) {
        val zone = runCatching { ZoneId.of(draft.timeZone) }.getOrElse { ZoneId.systemDefault() }
        val date = Instant.ofEpochMilli(draft.startMillis).atZone(zone).toLocalDate()
        val start = date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
        val end = date.plusDays(1).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
        return draft.copy(allDay = true, startMillis = start, endMillis = end, timeZone = "UTC")
    }
    val date = Instant.ofEpochMilli(draft.startMillis).atZone(ZoneOffset.UTC).toLocalDate()
    val zone = ZoneId.systemDefault()
    val start = date.atTime(9, 0).atZone(zone).toInstant().toEpochMilli()
    return draft.copy(
        allDay = false,
        startMillis = start,
        endMillis = start + 3_600_000L,
        timeZone = zone.id,
    )
}

private fun toggleTodoAllDay(draft: TodoDraftUi): TodoDraftUi {
    val due = draft.dueAtMillis ?: return draft.copy(allDay = !draft.allDay)
    if (!draft.allDay) {
        val zone = runCatching { ZoneId.of(draft.timeZone) }.getOrElse { ZoneId.systemDefault() }
        val date = Instant.ofEpochMilli(due).atZone(zone).toLocalDate()
        return draft.copy(
            allDay = true,
            dueAtMillis = date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
            timeZone = "UTC",
        )
    }
    val date = Instant.ofEpochMilli(due).atZone(ZoneOffset.UTC).toLocalDate()
    val zone = ZoneId.systemDefault()
    return draft.copy(
        allDay = false,
        dueAtMillis = date.atTime(9, 0).atZone(zone).toInstant().toEpochMilli(),
        timeZone = zone.id,
    )
}

/** Shared editor conversions used by the App host and its JVM tests. */
object CalendarDraftRules {
    fun startOfDayMillis(date: LocalDate, zoneId: String): Long {
        val zone = runCatching { ZoneId.of(zoneId) }.getOrElse { ZoneId.systemDefault() }
        return date.atStartOfDay(zone).toInstant().toEpochMilli()
    }

    fun allDayStartMillis(date: LocalDate): Long =
        date.atStartOfDay(ZoneId.of("UTC")).toInstant().toEpochMilli()

    fun combine(date: LocalDate, hour: Int, minute: Int, zoneId: String): Long {
        val zone = runCatching { ZoneId.of(zoneId) }.getOrElse { ZoneId.systemDefault() }
        return ZonedDateTime.of(date, LocalTime.of(hour, minute), zone).toInstant().toEpochMilli()
    }

    fun localDate(millis: Long, zoneId: String): LocalDate {
        val zone = runCatching { ZoneId.of(zoneId) }.getOrElse { ZoneId.systemDefault() }
        return Instant.ofEpochMilli(millis).atZone(zone).toLocalDate()
    }

    fun occurrenceToken(eventID: Long, startMillis: Long): String {
        val seconds = Math.floorDiv(startMillis, 1_000L) * 1_000L
        val iso = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            .withZone(ZoneId.of("UTC"))
            .format(Instant.ofEpochMilli(seconds))
        return "$eventID@$iso"
    }
}
