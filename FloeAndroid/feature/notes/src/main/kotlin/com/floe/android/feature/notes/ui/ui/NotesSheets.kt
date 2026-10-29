// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.presentation.NotesFailure
import kotlinx.coroutines.launch

internal data class NotesActionItem(
    val label: String,
    val icon: ImageVector,
    val enabled: Boolean = true,
    val destructive: Boolean = false,
    val onClick: () -> Unit,
)

@Composable
internal fun NotesActionSheet(
    visible: Boolean,
    title: String,
    onDismiss: () -> Unit,
    actions: List<NotesActionItem>,
    message: String? = null,
) {
    FloeActionSheet(visible = visible, onDismiss = onDismiss, maxCardWidth = 520.dp) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 620.dp)
                .padding(vertical = 10.dp),
        ) {
            FloeText(
                title,
                style = Floe.typography.section,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
            )
            if (message != null) {
                FloeText(
                    message,
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
                )
            }
            FloeDivider(Modifier.padding(top = 6.dp))
            Column(Modifier.verticalScroll(rememberScrollState())) {
                actions.forEach { item ->
                    NotesActionRow(item = item, onDismiss = onDismiss)
                }
            }
            FloeDivider()
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                FloeCapsuleAction(stringResource(R.string.notes_cancel), onClick = onDismiss)
            }
        }
    }
}

@Composable
internal fun NotesActionRow(item: NotesActionItem, onDismiss: () -> Unit) {
    val tint = if (item.destructive) Floe.colors.destructive else Floe.colors.label
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clickable(
                enabled = item.enabled,
                role = Role.Button,
                onClick = {
                    onDismiss()
                    item.onClick()
                },
            )
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        IconGlyph(item.icon, if (item.enabled) tint else Floe.colors.tertiaryLabel, 21.dp)
        FloeText(
            item.label,
            style = Floe.typography.body,
            color = if (item.enabled) tint else Floe.colors.tertiaryLabel,
            modifier = Modifier.weight(1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
internal fun NotesNameSheet(
    visible: Boolean,
    title: String,
    initial: String,
    label: String,
    onDismiss: () -> Unit,
    onSave: suspend (String) -> Boolean,
) {
    var value by remember(initial, visible) { mutableStateOf(initial) }
    var saving by remember(visible) { mutableStateOf(false) }
    var failure by remember(visible) { mutableStateOf<NotesFailure?>(null) }
    // The sheet owns a small coroutine only for the explicit Save tap.
    val scope = rememberCoroutineScope()
    if (visible) {
        FloeActionSheet(visible = true, onDismiss = { if (!saving) onDismiss() }, maxCardWidth = 520.dp) {
            Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                FloeText(title, style = Floe.typography.title)
                FloePlainFormField(
                    label = label,
                    value = value,
                    onValueChange = { value = it },
                    enabled = !saving,
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                )
                failure?.let {
                    FloeText(NotesFailureText(it), style = Floe.typography.metadata, color = Floe.colors.destructive)
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (saving) FloeActivityIndicator()
                    FloeCapsuleAction(
                        stringResource(R.string.notes_cancel),
                        onClick = { if (!saving) onDismiss() },
                        enabled = !saving,
                    )
                    FloeCapsuleAction(
                        stringResource(R.string.notes_save),
                        onClick = {
                            val trimmed = value.trim()
                            if (trimmed.isNotEmpty() && !saving) {
                                saving = true
                                failure = null
                                scope.launch {
                                    val ok = onSave(trimmed)
                                    saving = false
                                    if (ok) onDismiss()
                                    else failure = NotesFailure(NotesFailure.UNEXPECTED)
                                }
                            }
                        },
                        enabled = value.trim().isNotEmpty() && !saving,
                    )
                }
            }
        }
    }
}

@Composable
internal fun NotesTagsEditorSheet(
    visible: Boolean,
    initialTags: List<String>,
    onSave: suspend (List<String>) -> Boolean,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val scope = rememberCoroutineScope()
    var tags by remember(initialTags, visible) { mutableStateOf(initialTags) }
    var draft by remember(visible) { mutableStateOf("") }
    var saving by remember(visible) { mutableStateOf(false) }
    var failed by remember(visible) { mutableStateOf(false) }
    FloeActionSheet(visible = true, onDismiss = { if (!saving) onDismiss() }, maxCardWidth = 520.dp) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeText(stringResource(R.string.notes_tags_title), style = Floe.typography.title)
            if (tags.isEmpty()) {
                FloeText(
                    stringResource(R.string.notes_tags_empty),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            tags.forEach { tag ->
                Row(
                    modifier = Modifier.fillMaxWidth().heightIn(min = FloeLayout.MinimumTarget),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    NotesPill(tag, Floe.colors.accent)
                    Spacer(Modifier.weight(1f))
                    NotesIconAction(
                        FloeIcons.Xmark,
                        stringResource(R.string.notes_tags_remove, tag),
                        { tags = tags - tag },
                        visualSize = 28.dp,
                    )
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(Modifier.weight(1f)) {
                    FloePlainFormField(
                        label = stringResource(R.string.notes_tags_placeholder),
                        value = draft,
                        onValueChange = { draft = it },
                        enabled = !saving,
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    )
                }
                FloeCapsuleAction(
                    stringResource(R.string.notes_tags_add),
                    onClick = {
                        val value = draft.trim()
                        if (value.isNotEmpty() && value !in tags) tags = tags + value
                        draft = ""
                    },
                    enabled = !saving && draft.trim().isNotEmpty(),
                )
            }
            if (failed) {
                FloeText(
                    stringResource(R.string.notes_save_failed),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
            ) {
                if (saving) FloeActivityIndicator()
                FloeCapsuleAction(
                    stringResource(R.string.notes_cancel),
                    onClick = { if (!saving) onDismiss() },
                    enabled = !saving,
                )
                FloeCapsuleAction(
                    stringResource(R.string.notes_save),
                    onClick = {
                        if (!saving) {
                            saving = true
                            failed = false
                            scope.launch {
                                val ok = onSave(tags)
                                saving = false
                                if (ok) onDismiss() else failed = true
                            }
                        }
                    },
                    enabled = !saving,
                )
            }
        }
    }
}

@Composable
internal fun NotesMoveToNotebookSheet(
    visible: Boolean,
    notebooks: List<com.floe.android.feature.notes.Notebook>,
    onPick: suspend (String?) -> Boolean,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val scope = rememberCoroutineScope()
    val actions = buildList {
        add(
            NotesActionItem(stringResource(R.string.notes_uncategorized), FloeIcons.Folder) {
                scope.launch { if (onPick(null)) onDismiss() }
            },
        )
        notebooks.forEach { notebook ->
            add(
                NotesActionItem(notebook.title, FloeIcons.Folder) {
                    scope.launch { if (onPick(notebook.id)) onDismiss() }
                },
            )
        }
    }
    NotesActionSheet(
        visible = true,
        title = stringResource(R.string.notes_move_to_notebook),
        onDismiss = onDismiss,
        actions = actions,
    )
}

internal fun notesColorFromHex(hex: String, fallback: Color): Color = runCatching {
    Color(android.graphics.Color.parseColor(hex))
}.getOrDefault(fallback)

internal val NotesInkColors: List<String> = listOf(
    "#202020", "#D32F2F", "#1565C0", "#2E7D32", "#7B1FA2", "#E65100",
)
