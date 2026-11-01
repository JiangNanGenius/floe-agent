// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.api

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import java.util.Locale

/**
 * Explicit Ask AI confirmation for the OPEN media project.
 *
 * The user sees exactly which project will be connected to a real task. The
 * action creates a real ordinary task ONLY when the editor was not opened from
 * an existing task; otherwise it uses that task. The project stays manually
 * editable and no task/authority is created by ordinary editing.
 *
 * Copy is inline because the workbench string resources are outside this
 * source lane's write scope; the handoff carries the exact resource patch for
 * Main. Both English and Simplified Chinese remain aligned here.
 */
@Composable
internal fun MediaAgentAskAiSheet(
    projectName: String,
    usesCurrentTask: Boolean,
    busy: Boolean,
    failureCode: String?,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    val zh = Locale.getDefault().language.startsWith("zh", ignoreCase = true)
    var instruction by rememberSaveable { mutableStateOf("") }
    FloeActionSheet(visible = true, onDismiss = { if (!busy) onDismiss() }) {
        Column(
            Modifier.fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(
                    if (zh) "用 AI 编辑" else "Ask AI",
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                if (busy) FloeActivityIndicator()
                FloeCapsuleAction(
                    label = if (zh) "取消" else "Cancel",
                    onClick = { if (!busy) onDismiss() },
                    enabled = !busy,
                )
            }
            FloeText(
                if (usesCurrentTask) {
                    if (zh) {
                        "“$projectName” 会连接到当前任务。AI 只能按该任务的已授权调用修改它；手动编辑不受影响。"
                    } else {
                        "“$projectName” will be connected to the current task. AI can change it only through this task's authorized calls; manual editing is unchanged."
                    }
                } else {
                    if (zh) {
                        "会为“$projectName”创建一个真实任务，并把项目连接到该任务。AI 只能按该任务的已授权调用修改它；手动编辑不受影响。"
                    } else {
                        "A real task will be created for “$projectName” and the project will be connected to it. AI can change it only through that task's authorized calls; manual editing is unchanged."
                    }
                },
                style = Floe.typography.body,
                color = Floe.colors.secondaryLabel,
            )
            FloePlainFormField(
                label = if (zh) "希望 AI 修改什么？" else "What should AI change?",
                value = instruction,
                onValueChange = { instruction = it },
                enabled = !busy,
                maxLines = 4,
                minLines = 2,
            )
            failureCode?.let { code ->
                FloeText(
                    failureCopy(code, zh),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
            }
            FloeDivider()
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, androidx.compose.ui.Alignment.End),
            ) {
                FloeCapsuleAction(
                    label = if (zh) "开始" else "Continue",
                    onClick = { if (!busy) onConfirm(instruction) },
                    enabled = !busy,
                    tint = Floe.colors.accent,
                )
            }
        }
    }
}

private fun failureCopy(code: String, zh: Boolean): String = when (code) {
    "ownerProofUnavailable", "bindingUnavailable" ->
        if (zh) "AI 编辑暂不可用。请重新打开项目后再试。"
        else "AI editing is unavailable right now. Reopen the project and try again."
    "projectAlreadyBound" ->
        if (zh) "此项目已连接到另一个任务。请从那个任务打开后再使用 AI 编辑。"
        else "This project is already connected to another task. Open it from that task to use AI editing."
    "projectNotBindable", "workspaceMismatch", "environmentMismatch" ->
        if (zh) "请从项目的原始任务打开后再使用 AI 编辑。"
        else "Open this project from its original task before using AI editing."
    "projectChanged" ->
        if (zh) "项目已更改。请重新打开后再试。"
        else "The project changed. Reopen it and try again."
    "projectNotReady" ->
        if (zh) "项目仍在保存或需要重新载入。请稍后再试。"
        else "The project is still saving or needs a reload. Try again in a moment."
    "taskCreatedOpenFailed" ->
        if (zh) "任务已创建，但未能自动打开。请从任务列表打开它。"
        else "The task was created but could not be opened automatically. Open it from the task list."
    else ->
        if (zh) "未能把项目连接到任务。请重试。"
        else "The project could not be connected to a task. Try again."
}
