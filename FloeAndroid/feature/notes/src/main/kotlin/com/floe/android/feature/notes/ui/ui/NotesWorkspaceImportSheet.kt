// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.ui

import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph
import com.floe.android.feature.notes.ui.NotesIcons
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.api.NotesWorkspaceEntry
import com.floe.android.feature.notes.ui.api.NotesWorkspaceImportPort
import com.floe.android.feature.notes.ui.api.NotesWorkspaceScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * Real task-workspace chooser for Notes import.
 *
 * It renders only data the App's existing workspace authority returns through
 * [NotesWorkspaceImportPort]; it never reads a path, grants a permission or
 * invents a workspace. The sheet itself is shared by phone and tablet: the
 * FloeActionSheet picks a bottom sheet on compact widths and a centered card
 * on wide widths.
 */
@Composable
internal fun NotesWorkspaceImportSheet(
    port: NotesWorkspaceImportPort,
    onDismiss: () -> Unit,
    onPick: (NotesWorkspaceScope, String) -> Unit,
) {
    var scopes by remember(port) { mutableStateOf<List<NotesWorkspaceScope>?>(null) }
    var scopeNextToken by remember(port) { mutableStateOf<String?>(null) }
    var scopesError by remember(port) { mutableStateOf(false) }
    var scopePageError by remember(port) { mutableStateOf(false) }
    var reload by remember(port) { mutableIntStateOf(0) }
    var scope by remember(port) { mutableStateOf<NotesWorkspaceScope?>(null) }
    var path by remember(port) { mutableStateOf(".") }
    var entries by remember(port) { mutableStateOf<List<NotesWorkspaceEntry>>(emptyList()) }
    var nextToken by remember(port) { mutableStateOf<String?>(null) }
    var loading by remember(port) { mutableStateOf(false) }
    var error by remember(port) { mutableStateOf(false) }
    var exists by remember(port) { mutableStateOf(true) }
    val coroutine = rememberCoroutineScope()

    LaunchedEffect(port, reload, scope, path) {
        loading = true
        error = false
        try {
            val selected = scope
            if (selected == null) {
                val page = port.scopes()
                scopes = page.scopes
                scopeNextToken = page.nextPageToken
                scopesError = false
                scopePageError = false
            } else {
                val page = port.list(selected, path, null)
                entries = page.entries
                nextToken = page.nextPageToken
                exists = page.exists
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            if (scope == null) scopesError = true else error = true
        } finally {
            loading = false
        }
    }

    fun back() {
        val selected = scope ?: return
        if (path == ".") {
            scope = null
            entries = emptyList()
            nextToken = null
            exists = true
        } else {
            path = path.substringBeforeLast('/', ".")
        }
    }

    fun loadMoreScopes() {
        val token = scopeNextToken ?: return
        coroutine.launch {
            loading = true
            scopePageError = false
            try {
                val page = port.scopes(token)
                scopes = ((scopes ?: emptyList()) + page.scopes).distinctBy { it.id }
                scopeNextToken = page.nextPageToken
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                scopePageError = true
            } finally {
                loading = false
            }
        }
    }

    FloeActionSheet(
        visible = true,
        onDismiss = onDismiss,
        maxCardWidth = 680.dp,
        maxCardHeightFraction = 0.88f,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 640.dp)
                .padding(vertical = 10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (scope != null) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.notes_back),
                        onClick = { back() },
                    )
                }
                FloeText(
                    text = scope?.title ?: stringResource(R.string.notes_import_workspace_title),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f).padding(horizontal = 4.dp),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.notes_workspace_refresh),
                    onClick = { reload++ },
                    enabled = !loading,
                )
            }
            if (scope == null) {
                FloeText(
                    text = stringResource(R.string.notes_workspace_choose_file),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
                )
            } else {
                FloeText(
                    text = if (path == ".") stringResource(R.string.notes_workspace_root) else path,
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            FloeDivider(Modifier.padding(top = 6.dp))

            when {
                loading && ((scope == null && scopes.isNullOrEmpty()) || (scope != null && entries.isEmpty())) -> {
                    Row(
                        modifier = Modifier.fillMaxWidth().height(280.dp),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) { FloeActivityIndicator() }
                }
                scope == null && scopesError && scopes.isNullOrEmpty() -> {
                    FloeUnavailableView(
                        icon = FloeIcons.WarningTriangle,
                        title = stringResource(R.string.notes_workspace_unavailable),
                        description = stringResource(R.string.notes_workspace_retry_body),
                        modifier = Modifier.fillMaxWidth().height(280.dp),
                        action = {
                            FloeCapsuleAction(
                                label = stringResource(R.string.notes_retry),
                                onClick = { reload++ },
                            )
                        },
                    )
                }
                scope == null && scopes.isNullOrEmpty() -> {
                    FloeUnavailableView(
                        icon = FloeIcons.Folder,
                        title = stringResource(R.string.notes_workspace_no_workspaces),
                        description = stringResource(R.string.notes_workspace_no_workspaces_body),
                        modifier = Modifier.fillMaxWidth().height(300.dp),
                        action = {
                            FloeCapsuleAction(
                                label = stringResource(R.string.notes_retry),
                                onClick = { reload++ },
                            )
                        },
                    )
                }
                scope == null -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxWidth().heightIn(max = 420.dp),
                    ) {
                        items(scopes.orEmpty(), key = { it.id }) { item ->
                            WorkspaceScopeRow(item) {
                                scope = item
                                path = "."
                                entries = emptyList()
                                nextToken = null
                                exists = true
                            }
                        }
                        if (scopePageError) {
                            item(key = "scope-page-error") {
                                Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp)) {
                                    FloeText(
                                        text = stringResource(R.string.notes_workspace_unavailable),
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.destructive,
                                    )
                                    FloeCapsuleAction(
                                        label = stringResource(R.string.notes_retry),
                                        onClick = { loadMoreScopes() },
                                    )
                                }
                            }
                        } else if (scopeNextToken != null && !loading) {
                            item(key = "load-more-scopes") {
                                FloeCapsuleAction(
                                    label = stringResource(R.string.notes_workspace_load_more_scopes),
                                    onClick = { loadMoreScopes() },
                                )
                            }
                        }
                    }
                }
                error -> {
                    FloeUnavailableView(
                        icon = FloeIcons.WarningTriangle,
                        title = stringResource(R.string.notes_workspace_unavailable),
                        description = stringResource(R.string.notes_workspace_retry_body),
                        modifier = Modifier.fillMaxWidth().height(260.dp),
                        action = {
                            FloeCapsuleAction(
                                label = stringResource(R.string.notes_retry),
                                onClick = { reload++ },
                            )
                        },
                    )
                }
                !exists -> {
                    FloeUnavailableView(
                        icon = FloeIcons.Folder,
                        title = stringResource(R.string.notes_workspace_empty),
                        description = stringResource(R.string.notes_workspace_empty_body),
                        modifier = Modifier.fillMaxWidth().height(300.dp),
                        action = {
                            FloeCapsuleAction(
                                label = stringResource(R.string.notes_retry),
                                onClick = { reload++ },
                            )
                        },
                    )
                }
                entries.isEmpty() -> {
                    FloeUnavailableView(
                        icon = FloeIcons.Folder,
                        title = stringResource(R.string.notes_workspace_empty),
                        description = stringResource(R.string.notes_workspace_empty_body),
                        modifier = Modifier.fillMaxWidth().height(300.dp),
                        action = {
                            FloeCapsuleAction(
                                label = stringResource(R.string.notes_retry),
                                onClick = { reload++ },
                            )
                        },
                    )
                }
                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxWidth().heightIn(max = 430.dp),
                    ) {
                        items(entries, key = { it.relativePath }) { item ->
                            WorkspaceEntryRow(item, onClick = rowClick@{
                                val selected = scope ?: return@rowClick
                                if (item.isDirectory) {
                                    path = item.relativePath
                                    entries = emptyList()
                                    nextToken = null
                                } else {
                                    onPick(selected, item.relativePath)
                                }
                            })
                        }
                        if (nextToken != null && !loading) {
                            item(key = "load-more") {
                                FloeCapsuleAction(
                                    label = stringResource(R.string.notes_workspace_load_more),
                                    onClick = loadMore@{
                                        val selected = scope ?: return@loadMore
                                        val token = nextToken ?: return@loadMore
                                        coroutine.launch {
                                            loading = true
                                            try {
                                                val page = port.list(selected, path, token)
                                                entries = (entries + page.entries)
                                                    .distinctBy { it.relativePath }
                                                nextToken = page.nextPageToken
                                            } catch (cancelled: CancellationException) {
                                                throw cancelled
                                            } catch (_: Throwable) {
                                                error = true
                                            } finally {
                                                loading = false
                                            }
                                        }
                                    },
                                )
                            }
                        }
                    }
                }
            }
            FloeDivider()
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.notes_cancel),
                    onClick = onDismiss,
                )
            }
        }
    }
}

@Composable
private fun WorkspaceScopeRow(scope: NotesWorkspaceScope, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(FloeIcons.Bubble, Floe.colors.secondaryLabel, 22.dp)
        Column(Modifier.weight(1f)) {
            FloeText(
                scope.title,
                style = Floe.typography.body,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val kindText = stringResource(R.string.notes_workspace_task)
            val archivedText = stringResource(R.string.notes_workspace_archived)
            FloeText(
                text = if (scope.isArchived) "$kindText · $archivedText" else kindText,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 16.dp)
    }
}

@Composable
private fun WorkspaceEntryRow(entry: NotesWorkspaceEntry, onClick: () -> Unit) {
    val context = LocalContext.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(
            if (entry.isDirectory) FloeIcons.Folder else NotesIcons.Document,
            Floe.colors.secondaryLabel,
            22.dp,
        )
        Column(Modifier.weight(1f)) {
            FloeText(
                entry.name,
                style = Floe.typography.body,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (!entry.isDirectory) {
                FloeText(
                    text = Formatter.formatShortFileSize(context, entry.byteCount),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        if (entry.isDirectory) {
            IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 16.dp)
        }
    }
}
