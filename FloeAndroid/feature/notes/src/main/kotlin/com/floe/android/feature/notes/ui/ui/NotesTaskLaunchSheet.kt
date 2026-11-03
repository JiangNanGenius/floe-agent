// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.ui

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchOutcome
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchPolicy
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchPort
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchRequest
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchResource
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * Explicit Notes attachment -> ordinary task chooser.
 *
 * It shows only resources the current document really references (loaded
 * through the existing Notes service). The user's selection is the authority
 * for the App host; the exact revision, digest and size are revalidated by
 * that host and by the Core receipt before any task-workspace write. This
 * sheet does not create a task, run, grant or file itself.
 */
@Composable
internal fun NotesTaskLaunchSheet(
    session: NotesDocumentSession,
    port: NotesTaskLaunchPort?,
    onDismiss: () -> Unit,
    onCreated: (String) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val document = session.document
    val defaultPrompt = stringResource(R.string.notes_task_launch_prompt_default)
    var resources by remember(session.documentID) {
        mutableStateOf<List<NotesTaskLaunchResource>?>(null)
    }
    var selected by remember(session.documentID) { mutableStateOf<Set<String>>(emptySet()) }
    var initialised by remember(session.documentID) { mutableStateOf(false) }
    var prompt by remember(session.documentID) { mutableStateOf(defaultPrompt) }
    var loading by remember(session.documentID) { mutableStateOf(true) }
    var busy by remember(session.documentID) { mutableStateOf(false) }
    var failure by remember(session.documentID) { mutableStateOf<String?>(null) }

    LaunchedEffect(session.documentID, document?.revision) {
        loading = true
        failure = null
        try {
            val loaded = session.taskLaunchResources()
            resources = loaded
            if (!initialised) {
                selected = loaded.map { it.resourceID }.toSet()
                initialised = true
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            resources = emptyList()
            failure = context.getString(R.string.notes_task_launch_failed)
        } finally {
            loading = false
        }
    }

    val available = port?.isAvailable() == true
    val selectedResources = resources.orEmpty().filter { it.resourceID in selected }
    val totalBytes = NotesTaskLaunchPolicy.totalBytes(selectedResources)

    fun create() {
        val targetPort = port ?: return
        val doc = document ?: return
        if (busy || selectedResources.isEmpty()) return
        val validation = NotesTaskLaunchPolicy.validate(selectedResources)
        if (validation != null) {
            failure = when (validation.code) {
                NotesPortFailure.UNSUPPORTED -> context.getString(
                    R.string.notes_task_launch_too_many,
                    NotesTaskLaunchPolicy.MAX_RESOURCES,
                )
                else -> context.getString(R.string.notes_task_launch_failed)
            }
            return
        }
        if (prompt.encodeToByteArray().size > NotesTaskLaunchPolicy.MAX_PROMPT_BYTES) {
            failure = context.getString(R.string.notes_task_launch_too_large)
            return
        }
        failure = null
        busy = true
        scope.launch {
            try {
                when (val outcome = targetPort.createTask(
                    NotesTaskLaunchRequest(
                        documentID = doc.id,
                        documentRevision = doc.revision,
                        documentTitle = doc.title,
                        resources = selectedResources,
                        prompt = prompt,
                    ),
                )) {
                    is NotesTaskLaunchOutcome.Created -> {
                        if (session.documentID == doc.id && session.document?.revision == doc.revision) {
                            onCreated(outcome.conversationID)
                        }
                    }
                    is NotesTaskLaunchOutcome.Failed -> {
                        failure = copyFor(context, outcome.failure)
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                failure = context.getString(R.string.notes_task_launch_failed)
            } finally {
                busy = false
            }
        }
    }

    FloeActionSheet(
        visible = true,
        onDismiss = { if (!busy) onDismiss() },
        maxCardWidth = 640.dp,
        maxCardHeightFraction = 0.9f,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 680.dp)
                .padding(vertical = 10.dp),
        ) {
            FloeText(
                stringResource(R.string.notes_task_launch_title),
                style = Floe.typography.section,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
            )
            FloeText(
                stringResource(R.string.notes_task_launch_body),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 2.dp),
            )
            FloeDivider(Modifier.padding(top = 6.dp))

            when {
                !available -> {
                    FloeUnavailableView(
                        icon = FloeIcons.WarningTriangle,
                        title = stringResource(R.string.notes_task_launch_unavailable),
                        description = stringResource(R.string.notes_task_launch_unavailable_body),
                        modifier = Modifier.fillMaxWidth().height(260.dp),
                    )
                }
                loading -> {
                    Row(
                        modifier = Modifier.fillMaxWidth().height(220.dp),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeActivityIndicator()
                    }
                }
                resources.isNullOrEmpty() -> {
                    FloeUnavailableView(
                        icon = FloeIcons.Folder,
                        title = stringResource(R.string.notes_task_launch_empty),
                        description = stringResource(R.string.notes_task_launch_empty_body),
                        modifier = Modifier.fillMaxWidth().height(260.dp),
                    )
                }
                else -> {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 14.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        FloeText(
                            stringResource(
                                R.string.notes_task_launch_count,
                                selectedResources.size,
                            ) + " · " + Formatter.formatShortFileSize(context, totalBytes),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                            modifier = Modifier.weight(1f),
                        )
                        FloeCapsuleAction(
                            label = stringResource(R.string.notes_task_launch_select_all),
                            onClick = { selected = resources.orEmpty().map { it.resourceID }.toSet() },
                            enabled = !busy,
                        )
                        FloeCapsuleAction(
                            label = stringResource(R.string.notes_task_launch_clear),
                            onClick = { selected = emptySet() },
                            enabled = !busy && selected.isNotEmpty(),
                        )
                    }
                    LazyColumn(Modifier.fillMaxWidth().heightIn(max = 320.dp)) {
                        items(resources.orEmpty(), key = { it.resourceID }) { resource ->
                            FloeCheckboxRow(
                                label = stringResource(
                                    R.string.notes_task_launch_resource_meta,
                                    resource.fileName,
                                    Formatter.formatShortFileSize(context, resource.byteCount),
                                ),
                                checked = resource.resourceID in selected,
                                onCheckedChange = { checked ->
                                    if (!busy) {
                                        selected = if (checked) {
                                            if (selected.size >= NotesTaskLaunchPolicy.MAX_RESOURCES) {
                                                selected
                                            } else {
                                                selected + resource.resourceID
                                            }
                                        } else {
                                            selected - resource.resourceID
                                        }
                                    }
                                },
                            )
                        }
                    }
                }
            }

            if (available && !loading && !resources.isNullOrEmpty()) {
                FloeDivider(Modifier.padding(top = 6.dp))
                Column(Modifier.padding(horizontal = 14.dp, vertical = 6.dp)) {
                    FloePlainFormField(
                        label = stringResource(R.string.notes_task_launch_prompt_label),
                        value = prompt,
                        onValueChange = { if (!busy) prompt = it },
                        enabled = !busy,
                        singleLine = false,
                        minLines = 2,
                        maxLines = 5,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
                    )
                    FloeText(
                        stringResource(R.string.notes_task_launch_scope),
                        style = Floe.typography.metadata,
                        color = Floe.colors.tertiaryLabel,
                        modifier = Modifier.padding(top = 4.dp),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                failure?.let {
                    FloeText(
                        it,
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
                    )
                }
                FloeDivider()
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (busy) {
                        FloeActivityIndicator()
                        FloeText(
                            stringResource(R.string.notes_task_launch_busy),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    FloeCapsuleAction(
                        label = stringResource(R.string.notes_cancel),
                        onClick = onDismiss,
                        enabled = !busy,
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.notes_task_launch_create),
                        onClick = ::create,
                        enabled = !busy && selectedResources.isNotEmpty(),
                    )
                }
            } else {
                FloeDivider()
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.End,
                ) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.notes_dismiss),
                        onClick = onDismiss,
                    )
                }
            }
        }
    }
}

private fun copyFor(
    context: android.content.Context,
    failure: NotesPortFailure,
): String = when {
    failure.detail == "taskCreatedWithoutAttachments" -> context.getString(R.string.notes_task_launch_partial)
    failure.detail == "selectionChanged" -> context.getString(R.string.notes_task_launch_changed)
    else -> when (failure.code) {
    NotesPortFailure.PERMISSION_DENIED ->
        context.getString(R.string.notes_failure_permission)
    NotesPortFailure.CANCELLED -> context.getString(R.string.notes_failure_cancelled)
    NotesPortFailure.NOT_CONFIGURED ->
        context.getString(R.string.notes_task_launch_unavailable)
    NotesPortFailure.UNAVAILABLE ->
        context.getString(R.string.notes_task_launch_not_ready)
    NotesPortFailure.BUSY -> context.getString(R.string.notes_task_launch_busy)
    else -> context.getString(R.string.notes_task_launch_failed)
    }
}
