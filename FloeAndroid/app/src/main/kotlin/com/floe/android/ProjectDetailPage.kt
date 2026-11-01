// SPDX-License-Identifier: MPL-2.0
package com.floe.android

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInfoDialog
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import com.floe.android.host.ProjectDetailUi
import com.floe.android.host.ProjectTaskUi
import com.floe.android.host.RuntimeHost

private enum class ProjectDeleteChoice { NONE, KEEP_FILES, REMOVE_FILES }

/**
 * The real project detail surface. Every datum comes from the native
 * `project.get` projection; rename/delete dispatch the canonical CAS
 * commands and then re-read the durable projection. No local row is
 * optimistically inserted, and a project folder that went missing is
 * reported — never silently recreated.
 */
@Composable
fun ProjectDetailPage(
    projectId: String,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
    runtimeHost: RuntimeHost? = null,
) {
    val colors = Floe.colors
    val state = if (runtimeHost == null) {
        null
    } else {
        val observed by runtimeHost.projects.state.collectAsState()
        observed
    }
    val detail: ProjectDetailUi? = state?.selected?.takeIf { it.project.id == projectId }
    var renaming by remember(projectId) { mutableStateOf(false) }
    var editName by remember(projectId) { mutableStateOf("") }
    var deleteChoice by remember(projectId) { mutableStateOf(ProjectDeleteChoice.NONE) }
    var notice by remember(projectId) { mutableStateOf<String?>(null) }

    LaunchedEffect(projectId, runtimeHost) {
        runtimeHost?.projects?.open(projectId)
    }
    val retainedNotice = stringResource(R.string.project_delete_retained)
    val removedNotice = stringResource(R.string.project_delete_removed)
    val removeFailedNotice = stringResource(R.string.project_root_remove_failed)
    val noticeReceipt = state?.notice
    LaunchedEffect(noticeReceipt) {
        val receipt = noticeReceipt ?: return@LaunchedEffect
        if (receipt.projectId != projectId) return@LaunchedEffect
        notice = when {
            receipt.rootRemoveError != null -> removeFailedNotice
            receipt.rootRetained -> retainedNotice
            else -> removedNotice
        }
    }

    fun openNewTaskForProject() {
        runtimeHost?.home?.selectProject(projectId)
        runtimeHost?.conversations?.navigationRequest?.value =
            SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK)
    }

    fun openTask(task: ProjectTaskUi) {
        runtimeHost?.conversations?.navigationRequest?.value =
            SidebarSelection.Conversation(task.conversationId)
    }

    Column(Modifier.fillMaxSize().background(colors.readingSurface)) {
        FloeToolbar(
            title = detail?.project?.name ?: stringResource(R.string.projects),
            background = colors.readingSurface,
            navigation = if (showSidebarToggle || compact) {
                {
                    if (showSidebarToggle) {
                        FloeCircleButton(
                            FloeIcons.SidebarToggle,
                            stringResource(R.string.expand_task_list),
                            onExpandSidebar,
                        )
                    } else {
                        FloeCircleButton(
                            FloeIcons.SidebarToggle,
                            stringResource(R.string.open_sidebar),
                            onOpenDrawer,
                        )
                    }
                }
            } else null,
        )
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp),
        ) {
            if (detail == null) {
                val error = state?.errorCode
                FloeText(
                    if (error != null && error != "loading") {
                        stringResource(R.string.project_unavailable)
                    } else {
                        stringResource(R.string.project_loading)
                    },
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
                notice?.let {
                    Spacer(Modifier.height(8.dp))
                    FloeText(it, style = Floe.typography.metadata,
                        color = colors.secondaryLabel)
                }
                return@Column
            }
            ProjectHeader(
                detail = detail,
                busy = state?.busyProjectId == projectId,
                renaming = renaming,
                editName = editName,
                onEditName = { editName = it },
                onBeginRename = {
                    editName = detail.project.name
                    renaming = true
                },
                onCancelRename = { renaming = false },
                onCommitRename = {
                    renaming = false
                    runtimeHost?.projects?.rename(projectId, editName.trim())
                },
                onNewTask = ::openNewTaskForProject,
                onDeleteKeepFiles = { deleteChoice = ProjectDeleteChoice.KEEP_FILES },
                onDeleteFiles = { deleteChoice = ProjectDeleteChoice.REMOVE_FILES },
            )
            if (detail.rootState != "available") {
                Spacer(Modifier.height(10.dp))
                FloeText(
                    when (detail.rootState) {
                        "missing" -> stringResource(R.string.project_root_missing)
                        else -> stringResource(R.string.project_root_unsafe)
                    },
                    style = Floe.typography.metadata,
                    color = colors.destructive,
                )
            }
            if (state?.errorCode != null) {
                Spacer(Modifier.height(8.dp))
                FloeText(
                    stringResource(R.string.project_action_failed),
                    style = Floe.typography.metadata,
                    color = colors.destructive,
                )
            }
            notice?.let {
                Spacer(Modifier.height(8.dp))
                FloeText(it, style = Floe.typography.metadata, color = colors.secondaryLabel)
            }
            Spacer(Modifier.height(18.dp))
            FloeText(
                stringResource(R.string.project_tasks_title),
                style = Floe.typography.section,
            )
            Spacer(Modifier.height(6.dp))
            if (detail.tasks.isEmpty()) {
                FloeText(
                    stringResource(R.string.project_tasks_empty),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
            } else {
                detail.tasks.forEach { task ->
                    ProjectTaskRow(task = task, onClick = { openTask(task) })
                }
                if (detail.tasksTruncated) {
                    FloeText(
                        stringResource(R.string.project_tasks_truncated),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                }
            }
        }
    }

    if (deleteChoice != ProjectDeleteChoice.NONE) {
        val removeFiles = deleteChoice == ProjectDeleteChoice.REMOVE_FILES
        FloeConfirmDialog(
            title = stringResource(R.string.project_delete_title),
            message = if (removeFiles) {
                stringResource(R.string.project_delete_remove_message)
            } else {
                stringResource(R.string.project_delete_keep_message)
            },
            confirmLabel = stringResource(R.string.settings_delete),
            dismissLabel = stringResource(R.string.cancel),
            onConfirm = {
                deleteChoice = ProjectDeleteChoice.NONE
                runtimeHost?.projects?.delete(
                    projectId = projectId,
                    deleteRoot = removeFiles,
                    stopActiveTasks = true,
                )
            },
            onDismiss = { deleteChoice = ProjectDeleteChoice.NONE },
        )
    }
}

@Composable
private fun ProjectHeader(
    detail: ProjectDetailUi,
    busy: Boolean,
    renaming: Boolean,
    editName: String,
    onEditName: (String) -> Unit,
    onBeginRename: () -> Unit,
    onCancelRename: () -> Unit,
    onCommitRename: () -> Unit,
    onNewTask: () -> Unit,
    onDeleteKeepFiles: () -> Unit,
    onDeleteFiles: () -> Unit,
) {
    val colors = Floe.colors
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(colors.fillTertiary)
            .padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                detail.project.name,
                style = Floe.typography.title,
                modifier = Modifier.weight(1f),
            )
            FloeCircleButton(
                FloeIcons.Ellipsis,
                stringResource(R.string.project_rename),
                onBeginRename,
                visualSize = 34.dp,
                iconSize = 18.dp,
                background = androidx.compose.ui.graphics.Color.Transparent,
                hairline = false,
                tint = colors.label,
            )
        }
        if (renaming) {
            Spacer(Modifier.height(8.dp))
            FloePlainFormField(
                label = stringResource(R.string.project_name_hint),
                value = editName,
                onValueChange = onEditName,
            )
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeCapsuleButton(
                    label = stringResource(R.string.settings_save),
                    onClick = onCommitRename,
                    enabled = !busy && editName.isNotBlank(),
                    prominent = true,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleButton(
                    label = stringResource(R.string.cancel),
                    onClick = onCancelRename,
                    modifier = Modifier.weight(1f),
                )
            }
        } else {
            Spacer(Modifier.height(6.dp))
            FloeText(
                stringResource(R.string.project_task_count, detail.project.taskCount),
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
            )
            Spacer(Modifier.height(12.dp))
            FloeCapsuleButton(
                label = stringResource(R.string.project_new_task),
                onClick = onNewTask,
                prominent = true,
            )
            Spacer(Modifier.height(10.dp))
            FloeCapsuleButton(
                label = stringResource(R.string.project_delete_keep_action),
                onClick = onDeleteKeepFiles,
                enabled = !busy,
            )
            Spacer(Modifier.height(8.dp))
            FloeCapsuleButton(
                label = stringResource(R.string.project_delete_remove_action),
                onClick = onDeleteFiles,
                enabled = !busy,
            )
        }
    }
}

@Composable
private fun ProjectTaskRow(task: ProjectTaskUi, onClick: () -> Unit) {
    val colors = Floe.colors
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (task.pinned) {
                FloeText("• ", style = Floe.typography.body, color = colors.accent)
            }
            val title = if (task.title.isBlank()) {
                stringResource(R.string.history_untitled)
            } else {
                task.title
            }
            FloeText(
                title,
                style = Floe.typography.body,
                modifier = Modifier.weight(1f),
            )
            if (task.archived) {
                FloeText(
                    stringResource(R.string.project_task_archived),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
            }
        }
        FloeDivider()
    }
}
