// SPDX-License-Identifier: MPL-2.0
//
// Full-window archive browser (WSF-SAFE-EXTRACT App surface).
//
// Android equivalent of the original iOS `ArchiveBrowserView`
// (FloeAgent/FloeApp/Workspace/ArchiveBrowserView.swift at the fixed iOS
// source): the same bounded entries, directory-first tree, entry preview
// from one hidden staged extraction, confirmed extract/decompress into a
// NEW workspace destination, live progress with real cancel, and the honest
// typed failure surfaces. It renders only the Application-owned
// WorkspaceArchiveHostController state; every byte and every archive effect
// stays behind the `floe.archive/25` bridge on the ORIGINAL G04 workspace
// lease — this file adds no engine, no root and no second authority.
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbarIconButton
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.FloeVerticalDivider
import com.floe.android.host.ArchiveFailure
import com.floe.android.host.ArchiveProgressSnapshot
import com.floe.android.host.ArchiveTreeNode
import com.floe.android.host.Owner
import com.floe.android.host.WorkspaceArchiveHostController
import com.floe.android.host.WorkspaceArchivePreviewState
import com.floe.android.host.WorkspaceArchiveState
import java.util.Locale

/**
 * The one archive document window. [onOpenFolder] reveals the real extracted
 * output in the owning file tree (read-only expansion), exactly like the
 * C04A safe-folder escape.
 */
@Composable
internal fun WorkspaceArchiveDestination(
    controller: WorkspaceArchiveHostController,
    request: WorkspaceDocumentRequest,
    owner: Owner,
    onBackToFiles: () -> Unit,
    onCloseTask: () -> Unit,
    onOpenFolder: ((String) -> Unit)? = null,
) {
    val state by controller.state.collectAsState()
    val preview by controller.preview.collectAsState()
    var confirmExtract by rememberSaveable(request.token) { mutableStateOf(false) }

    LaunchedEffect(request.token, request.path, owner.nativeEpoch, owner.hostGeneration) {
        controller.open(owner, request.path, request.token)
    }
    DisposableEffect(request.token) {
        onDispose { controller.close(request.token) }
    }

    val current = when (val value = state) {
        is WorkspaceArchiveState.Listing -> if (value.token == request.token) value else null
        is WorkspaceArchiveState.Listed -> if (value.token == request.token) value else null
        is WorkspaceArchiveState.ListingFailed -> if (value.token == request.token) value else null
        WorkspaceArchiveState.Idle -> null
    }
    val listed = current as? WorkspaceArchiveState.Listed
    val previewEntry = (preview as? WorkspaceArchivePreviewState.Ready)?.entryPath
        ?: (preview as? WorkspaceArchivePreviewState.Loading)?.entryPath
        ?: (preview as? WorkspaceArchivePreviewState.Unavailable)?.entryPath
        ?: (preview as? WorkspaceArchivePreviewState.Failed)?.entryPath
    var compactPreviewVisible by rememberSaveable(request.token) { mutableStateOf(false) }
    LaunchedEffect(previewEntry) {
        compactPreviewVisible = previewEntry != null
    }

    // Wide windows show list + preview side by side inside the ONE document
    // window; a phone/compact window shows the entry in a sheet instead.
    // This is one surface, never a permanent three-column workspace layout.
    val wide = LocalConfiguration.current.screenWidthDp >= 720

    Column(Modifier.fillMaxSize().testTag("workspace.archiveDestination")) {
        WorkspaceDocumentHeader(
            fileName = request.fileName,
            onBackToFiles = onBackToFiles,
            onCloseTask = onCloseTask,
            onEdit = if (listed != null && listed.extracting == null) {
                ({ confirmExtract = true })
            } else {
                null
            },
            editLabel = when (WorkspaceArchiveFormatKindOf(listed)) {
                WorkspaceArchiveFormatKindView.CONTAINER ->
                    R.string.archive_action_extract
                WorkspaceArchiveFormatKindView.SINGLE_FILE ->
                    R.string.archive_action_decompress
                null -> R.string.archive_action_extract
            },
        )
        FloeDivider()
        when (val value = current) {
            null, is WorkspaceArchiveState.Listing -> ArchiveLoading(
                text = stringResource(R.string.archive_reading),
            )
            is WorkspaceArchiveState.ListingFailed -> ArchiveFailureSurface(
                state = value,
                onRetry = { controller.retry(request.token) },
                onBackToFiles = onBackToFiles,
            )
            is WorkspaceArchiveState.Listed -> Column(Modifier.fillMaxSize()) {
                ArchiveBanner(listed = value, onOpenFolder = onOpenFolder)
                ArchiveProgressBanner(
                    listed = value,
                    onCancel = { controller.cancelExtract(request.token) },
                )
                Row(Modifier.fillMaxSize()) {
                    ArchiveEntryList(
                        listed = value,
                        onSelect = { entry -> if (!entry.isDirectory) controller.previewEntry(entry.path) },
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight(),
                    )
                    if (wide) {
                        FloeVerticalDivider()
                        Box(
                            Modifier
                                .widthIn(min = 260.dp)
                                .fillMaxHeight()
                                .weight(1f),
                        ) {
                            ArchivePreviewPane(
                                preview = preview,
                                onDismiss = { controller.discardPreviewEntry() },
                            )
                        }
                    }
                }
            }
        }
    }

    if (confirmExtract && listed != null) {
        val single = WorkspaceArchiveFormatKindOf(listed) == WorkspaceArchiveFormatKindView.SINGLE_FILE
        val destination = if (single) {
            com.floe.android.host.WorkspaceArchiveFormat.decompressDestinationFor(request.path)
        } else {
            com.floe.android.host.WorkspaceArchiveFormat.extractDestinationFor(request.path)
        }
        ArchiveConfirmExtractDialog(
            singleFile = single,
            destination = destination,
            onConfirm = {
                confirmExtract = false
                controller.extractConfirmed(request.token)
            },
            onDismiss = { confirmExtract = false },
        )
    }
    if (!wide && compactPreviewVisible) {
        FloePageSheet(
            visible = true,
            onDismiss = {
                compactPreviewVisible = false
                controller.discardPreviewEntry()
            },
            widthFraction = 0.94f,
            heightFraction = 0.92f,
            placement = FloeSheetPlacement.CENTER,
        ) {
            Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
                ArchivePreviewPane(
                    preview = preview,
                    onDismiss = {
                        compactPreviewVisible = false
                        controller.discardPreviewEntry()
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
    }
}

private enum class WorkspaceArchiveFormatKindView { CONTAINER, SINGLE_FILE }

private fun WorkspaceArchiveFormatKindOf(listed: WorkspaceArchiveState.Listed?): WorkspaceArchiveFormatKindView? {
    if (listed == null) return null
    return when (com.floe.android.host.WorkspaceArchiveFormat.kind(listed.format)) {
        com.floe.android.host.WorkspaceArchiveFormatKind.CONTAINER -> WorkspaceArchiveFormatKindView.CONTAINER
        com.floe.android.host.WorkspaceArchiveFormatKind.SINGLE_FILE -> WorkspaceArchiveFormatKindView.SINGLE_FILE
        null -> null
    }
}

@Composable
private fun ArchiveLoading(text: String) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        FloeActivityIndicator(description = text)
        FloeText(
            text,
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(top = 10.dp),
        )
    }
}

/** Result/error strip above the entries; never hides the archive and never
 *  claims success without the real engine receipt. */
@Composable
private fun ArchiveBanner(
    listed: WorkspaceArchiveState.Listed,
    onOpenFolder: ((String) -> Unit)?,
) {
    val receipt = listed.extractReceipt
    val failure = listed.extractFailure
    when {
        receipt != null -> {
            val single = com.floe.android.host.WorkspaceArchiveFormat.kind(listed.format) ==
                com.floe.android.host.WorkspaceArchiveFormatKind.SINGLE_FILE
            val message = if (single) {
                stringResource(R.string.archive_decompressed_to, receipt.destination)
            } else {
                stringResource(R.string.archive_extracted_to, receipt.destination)
            }
            FloeStatusLine(
                icon = FloeIcons.Checkmark,
                text = message,
                color = Floe.colors.success,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            )
            // Reveal the REAL output in the owning file tree.
            onOpenFolder?.let { open ->
                Row(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 6.dp)) {
                    FloeCapsuleAction(
                        label = stringResource(
                            if (single) R.string.archive_open_parent_folder else R.string.archive_open_folder),
                        onClick = {
                            val target = if (single) {
                                receipt.destination.substringBeforeLast('/', "")
                            } else {
                                receipt.destination
                            }
                            open(target)
                        },
                        modifier = Modifier.testTag("archive.openResult"),
                    )
                }
            }
        }
        failure != null -> FloeStatusLine(
            icon = FloeIcons.WarningTriangle,
            text = archiveFailureText(failure.failure, failure.detail),
            color = Floe.colors.pending,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun ArchiveProgressBanner(
    listed: WorkspaceArchiveState.Listed,
    onCancel: () -> Unit,
) {
    val progress = listed.extracting ?: return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeActivityIndicator()
        FloeText(
            archiveProgressText(progress),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.weight(1f).padding(horizontal = 10.dp),
        )
        FloeCircleButton(
            icon = FloeIcons.Xmark,
            contentDescription = stringResource(R.string.archive_cancel),
            onClick = onCancel,
            modifier = Modifier.testTag("archive.cancel"),
        )
    }
}

@Composable
private fun ArchiveEntryList(
    listed: WorkspaceArchiveState.Listed,
    onSelect: (ArchiveTreeNode) -> Unit,
    modifier: Modifier = Modifier,
) {
    val rows = remember(listed.entries) {
        ArchiveTreeNode.fromEntries(listed.entries.map { Triple(it.path, it.isDirectory, it.size) })
    }
    LazyColumn(modifier = modifier.testTag("archive.entryList")) {
        item(key = "header") {
            FloeText(
                stringResource(R.string.archive_entry_count, listed.entryCount),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            )
            if (listed.truncated) {
                FloeText(
                    stringResource(R.string.archive_listing_truncated),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
            }
        }
        if (rows.isEmpty()) {
            item(key = "empty") {
                FloeText(
                    stringResource(R.string.archive_empty),
                    style = Floe.typography.body,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
                )
            }
        } else {
            items(rows, key = { it.path }) { node ->
                ArchiveNodeRow(node = node, depth = 0, onSelect = onSelect)
            }
        }
    }
}

@Composable
private fun ArchiveNodeRow(
    node: ArchiveTreeNode,
    depth: Int,
    onSelect: (ArchiveTreeNode) -> Unit,
) {
    var expanded by rememberSaveable(node.path) { mutableStateOf(depth == 0) }
    Column {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = !node.isDirectory) { onSelect(node) }
                .padding(start = (12 + depth * 16).dp, end = 12.dp)
                .height(40.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (node.isDirectory) {
                FloeToolbarIconButton(
                    icon = if (expanded) FloeIcons.ChevronDown else FloeIcons.ChevronForward,
                    contentDescription = node.name,
                    onClick = { expanded = !expanded },
                )
            } else {
                Spacer(Modifier.width(36.dp))
            }
            FloeToolbarIconButton(
                icon = if (node.isDirectory) FloeIcons.Folder else FloeIcons.Document,
                contentDescription = node.name,
                onClick = { if (node.isDirectory) expanded = !expanded else onSelect(node) },
            )
            FloeText(
                node.name,
                style = Floe.typography.body,
                color = Floe.colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (!node.isDirectory) {
                FloeText(
                    archiveByteString(node.size),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
            }
        }
        if (node.isDirectory && expanded) {
            node.children?.forEach { child ->
                ArchiveNodeRow(node = child, depth = depth + 1, onSelect = onSelect)
            }
        }
    }
}

@Composable
private fun ArchivePreviewPane(
    preview: WorkspaceArchivePreviewState,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val title = when (preview) {
                is WorkspaceArchivePreviewState.Loading -> preview.entryPath.substringAfterLast('/')
                is WorkspaceArchivePreviewState.Ready -> preview.entryPath.substringAfterLast('/')
                is WorkspaceArchivePreviewState.Unavailable -> preview.entryPath.substringAfterLast('/')
                is WorkspaceArchivePreviewState.Failed -> preview.entryPath.substringAfterLast('/')
                WorkspaceArchivePreviewState.Idle -> ""
            }
            FloeText(
                title,
                style = Floe.typography.section,
                color = Floe.colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            FloeToolbarIconButton(
                icon = FloeIcons.Xmark,
                contentDescription = stringResource(R.string.archive_close_preview),
                onClick = onDismiss,
            )
        }
        FloeDivider()
        Box(Modifier.fillMaxSize()) {
            when (preview) {
                WorkspaceArchivePreviewState.Idle -> FloeUnavailableView(
                    icon = FloeIcons.SidebarToggle,
                    title = stringResource(R.string.archive_preview_select_title),
                    description = stringResource(R.string.archive_preview_select_message),
                )
                is WorkspaceArchivePreviewState.Loading -> ArchiveLoading(
                    text = stringResource(R.string.archive_preview_loading),
                )
                is WorkspaceArchivePreviewState.Ready -> Column(Modifier.fillMaxSize()) {
                    if (preview.truncated) {
                        FloeText(
                            stringResource(R.string.archive_preview_truncated),
                            style = Floe.typography.metadata,
                            color = Floe.colors.tertiaryLabel,
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                        )
                    }
                    androidx.compose.foundation.text.selection.SelectionContainer {
                        FloeText(
                            preview.text,
                            style = Floe.typography.metadata,
                            color = Floe.colors.label,
                            modifier = Modifier
                                .fillMaxSize()
                                .verticalScroll(rememberScrollState())
                                .padding(12.dp),
                        )
                    }
                }
                is WorkspaceArchivePreviewState.Unavailable -> FloeUnavailableView(
                    icon = FloeIcons.InfoCircle,
                    title = stringResource(R.string.archive_preview_unavailable_title),
                    description = when (preview.message) {
                        "notUTF8" -> stringResource(R.string.archive_preview_not_utf8)
                        else -> stringResource(R.string.archive_preview_unavailable_message)
                    },
                )
                is WorkspaceArchivePreviewState.Failed -> FloeUnavailableView(
                    icon = FloeIcons.WarningTriangle,
                    title = stringResource(R.string.archive_preview_failed_title),
                    description = archiveFailureText(preview.failure, preview.detail),
                )
            }
        }
    }
}

@Composable
private fun ArchiveFailureSurface(
    state: WorkspaceArchiveState.ListingFailed,
    onRetry: () -> Unit,
    onBackToFiles: () -> Unit,
) {
    Box(Modifier.fillMaxSize().padding(24.dp)) {
        FloeUnavailableView(
            icon = FloeIcons.WarningTriangle,
            title = stringResource(R.string.archive_read_failed_title),
            description = archiveFailureText(state.failure, state.detail),
            action = if (state.retryable) {
                {
                    FloeCapsuleAction(
                        label = stringResource(R.string.archive_retry),
                        onClick = onRetry,
                        modifier = Modifier.testTag("archive.retry"),
                    )
                }
            } else {
                null
            },
        )
    }
}

@Composable
private fun ArchiveConfirmExtractDialog(
    singleFile: Boolean,
    destination: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .width(320.dp)
                .background(Floe.colors.readingSurface, androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
                .padding(18.dp),
        ) {
            FloeText(
                stringResource(
                    if (singleFile) R.string.archive_confirm_decompress_title else R.string.archive_confirm_extract_title),
                style = Floe.typography.section,
                color = Floe.colors.label,
            )
            FloeText(
                stringResource(
                    if (singleFile) R.string.archive_confirm_decompress_body else R.string.archive_confirm_extract_body,
                    destination,
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 8.dp),
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.archive_cancel),
                    onClick = onDismiss,
                )
                Spacer(Modifier.width(10.dp))
                FloeCapsuleAction(
                    label = stringResource(
                        if (singleFile) R.string.archive_action_decompress else R.string.archive_action_extract),
                    onClick = onConfirm,
                    modifier = Modifier.testTag("archive.confirmExtract"),
                )
            }
        }
    }
}

@Composable
private fun archiveFailureText(failure: ArchiveFailure, detail: String?): String = when (failure) {
    ArchiveFailure.CONFLICT -> stringResource(R.string.archive_failed_conflict, detail ?: "")
    ArchiveFailure.FAILED -> stringResource(R.string.archive_failed_generic, detail ?: "")
    else -> stringResource(
        when (failure) {
            ArchiveFailure.OWNER -> R.string.archive_failed_owner
            ArchiveFailure.UNSUPPORTED -> R.string.archive_failed_unsupported
            ArchiveFailure.NOT_FOUND -> R.string.archive_failed_not_found
            ArchiveFailure.TOO_LARGE -> R.string.archive_failed_too_large
            ArchiveFailure.CANCELLED -> R.string.archive_failed_cancelled
            ArchiveFailure.SOURCE -> R.string.archive_failed_source
            ArchiveFailure.TRANSPORT -> R.string.archive_failed_transport
            ArchiveFailure.NEEDS_CORE_UPDATE -> R.string.archive_failed_core_update
            ArchiveFailure.CONFLICT, ArchiveFailure.FAILED -> R.string.archive_failed_generic
        },
    )
}

@Composable
private fun archiveProgressText(progress: ArchiveProgressSnapshot): String {
    val done = archiveByteString(progress.completedBytes)
    val total = progress.totalBytes?.let(::archiveByteString)
    return if (total != null) {
        stringResource(R.string.archive_progress_bytes, done, total)
    } else {
        stringResource(R.string.archive_progress_bytes_unknown, done)
    }
}

private fun archiveByteString(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val units = arrayOf("KB", "MB", "GB")
    var value = bytes.toDouble() / 1024
    var unit = 0
    while (value >= 1024 && unit < units.lastIndex) {
        value /= 1024
        unit++
    }
    return String.format(Locale.ROOT, "%.1f %s", value, units[unit])
}
