// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import com.floe.android.host.G04TerminalHostController
import kotlinx.coroutines.CancellationException

/** Read-only live guest view. It owns no Core editor/draft/save or export path. */
@Composable
internal fun WorkspaceLiveFilesDialog(controller: G04TerminalHostController, taskID: String, sessionID: String,
    onDismiss: () -> Unit) {
    var directory by remember(taskID, sessionID) { mutableStateOf("") }
    var selected by remember(taskID, sessionID) { mutableStateOf<String?>(null) }
    var revision by remember(taskID, sessionID) { mutableIntStateOf(0) }
    var entries by remember(taskID, sessionID) { mutableStateOf(emptyList<G04TerminalHostController.LiveFileEntry>()) }
    var text by remember(taskID, sessionID) { mutableStateOf<String?>(null) }
    var busy by remember(taskID, sessionID) { mutableStateOf(false) }
    var truncated by remember(taskID, sessionID) { mutableStateOf(false) }
    var failure by remember(taskID, sessionID) { mutableStateOf<String?>(null) }
    LaunchedEffect(controller, taskID, sessionID, directory, selected, revision) {
        busy = true; failure = null; text = null; truncated = false; entries = emptyList()
        try {
            val path = selected
            val reply = if (path == null) controller.readLiveFileTree(taskID, sessionID, directory, 200, 0)
                else controller.readLiveFilePage(taskID, sessionID, path, 0, 24576)
            when (reply) {
                is G04TerminalHostController.LiveFilesReply.Tree -> {
                    entries = reply.tree.entries; truncated = reply.tree.truncated
                }
                is G04TerminalHostController.LiveFilesReply.Page -> {
                    if (reply.page.offset != 0L || reply.page.path != path) failure = "invalid"
                    else when (val decoded = LiveFilePreviewPolicy.decode(reply.page.content, reply.page.digest, reply.page.truncated)) {
                        is LiveFilePreviewPolicy.Result.Text -> { text = decoded.value; truncated = decoded.truncated }
                        LiveFilePreviewPolicy.Result.NotText -> failure = "binary"
                        LiveFilePreviewPolicy.Result.Invalid -> failure = "invalid"
                    }
                }
                is G04TerminalHostController.LiveFilesReply.Failed -> failure = reply.code
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { failure = "unavailable" }
        finally { busy = false }
    }
    val back = {
        if (selected != null) selected = null
        else if (directory.isNotEmpty()) directory = directory.substringBeforeLast('/', "")
        else onDismiss()
    }
    BackHandler(onBack = back)
    val tablet = LocalConfiguration.current.smallestScreenWidthDp >= 600
    FloePageSheet(true, back, widthFraction = if (tablet) .72f else 1f,
        heightFraction = if (tablet) .84f else 1f, placement = FloeSheetPlacement.CENTER) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCircleButton(FloeIcons.ChevronBack, stringResource(R.string.workspace_live_back), back)
                FloeText(stringResource(R.string.workspace_live_title), modifier = Modifier.weight(1f), style = Floe.typography.section)
                FloeCircleButton(FloeIcons.Refresh, stringResource(R.string.workspace_live_refresh), { revision++ }, enabled = !busy)
                FloeCircleButton(FloeIcons.Xmark, stringResource(R.string.workspace_live_close), onDismiss)
            }
            FloeText(stringResource(R.string.workspace_live_readonly), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            FloeText(selected ?: directory.ifEmpty { "/workspace" }, style = Floe.typography.metadata)
            FloeDivider()
            if (busy) FloeText(stringResource(R.string.workspace_live_loading), style = Floe.typography.metadata)
            failure?.let { code ->
                val label = when {
                    code == "binary" -> R.string.workspace_live_binary
                    code.startsWith("retry:") -> R.string.workspace_live_changed
                    code.contains("stale", true) -> R.string.workspace_live_ended
                    code.contains("pathOutOfScope") -> R.string.workspace_live_link
                    else -> R.string.workspace_live_failed
                }
                FloeText(stringResource(label), style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            }
            if (truncated) FloeText(stringResource(if (selected == null) R.string.workspace_live_list_partial
                else R.string.workspace_live_text_partial), style = Floe.typography.metadata)
            val preview = text
            if (preview != null) SelectionContainer(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())) {
                FloeText(preview, style = Floe.typography.body)
            } else if (selected == null) LazyColumn(Modifier.weight(1f)) {
                items(entries, key = { it.path }) { entry ->
                    FloeCapsuleButton(entry.path.substringAfterLast('/'), onClick = {
                        if (entry.kind == "directory") directory = entry.path else selected = entry.path
                    }, enabled = !busy, modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
}
