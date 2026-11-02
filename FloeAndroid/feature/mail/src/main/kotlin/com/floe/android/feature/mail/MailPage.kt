// SPDX-License-Identifier: MPL-2.0
//
// C06 mail screens: account settings, folder/message list, bounded body,
// attachments and compose. Presentation only: every network, credential,
// journal and SAF effect is owned by the App controller.

package com.floe.android.feature.mail

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import io.github.robinpcrd.cupertino.CupertinoTextField
import io.github.robinpcrd.cupertino.CupertinoTextFieldDefaults

@Composable
fun MailDestinationUi(
    state: MailScreenState,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onRefresh: () -> Unit,
    onSelectAccount: (String) -> Unit,
    onSelectFolder: (String) -> Unit,
    onLoadMore: () -> Unit,
    onOpenMessage: (MailRow) -> Unit,
    onOpenSearchMessage: (MailRow) -> Unit,
    onCloseMessage: () -> Unit,
    onLoadMoreBody: () -> Unit,
    onSearch: (MailSearchDraftUi) -> Unit,
    onLoadMoreSearch: (MailSearchDraftUi) -> Unit,
    onClearSearch: () -> Unit,
    onSetRead: (MailRow, Boolean) -> Unit,
    onMove: (MailRow, String, String?) -> Unit,
    onCompose: () -> Unit,
    onUpdateCompose: (String?, String?, String?) -> Unit,
    onSendCompose: () -> Unit,
    onDiscardCompose: () -> Unit,
    onPickAttachment: () -> Unit,
    onRemoveAttachment: (String) -> Unit,
    onSaveAttachment: (MailAttachmentRow) -> Unit,
    onSaveAccount: (MailAccountDraftUi) -> Unit,
    onDeleteAccount: (String) -> Unit,
    onTestAccount: (MailAccountDraftUi?) -> Unit,
    onTestSavedAccount: (String) -> Unit,
    onDismissError: () -> Unit,
    onDismissNotice: () -> Unit,
    onCancel: () -> Unit,
    sheetNavigation: (@Composable () -> Unit)? = null,
) {
    var editor by remember { mutableStateOf<MailAccountDraftUi?>(null) }
    var accountsOpen by rememberSaveable { mutableStateOf(false) }
    var searchDraft by remember { mutableStateOf(MailSearchDraftUi()) }
    var moveRow by remember { mutableStateOf<MailRow?>(null) }
    var moveDestination by remember { mutableStateOf("") }
    val activeCompose = state.compose
    val activeMessage = state.message

    when {
        activeCompose != null -> MailComposeScreen(
            state = state,
            compose = activeCompose,
            compact = compact,
            onBack = onDiscardCompose,
            onUpdate = onUpdateCompose,
            onSend = onSendCompose,
            onPickAttachment = onPickAttachment,
            onRemoveAttachment = onRemoveAttachment,
        )
        activeMessage != null -> MailMessageScreen(
            state = state,
            message = activeMessage,
            row = state.messageRow,
            compact = compact,
            onBack = onCloseMessage,
            onLoadMore = onLoadMoreBody,
            onSetRead = onSetRead,
            onMove = { row, action, destination -> onMove(row, action, destination) },
            onSaveAttachment = onSaveAttachment,
            onMoveDestination = { row ->
                moveRow = row
                moveDestination = ""
            },
        )
        else -> MailMainScreen(
            sheetNavigation = sheetNavigation,
            state = state,
            compact = compact,
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            onRefresh = onRefresh,
            onSelectAccount = onSelectAccount,
            onSelectFolder = onSelectFolder,
            onLoadMore = onLoadMore,
            onOpenMessage = onOpenMessage,
            onOpenSearchMessage = onOpenSearchMessage,
            searchDraft = searchDraft,
            onSearchDraftChange = { searchDraft = it },
            onSearch = onSearch,
            onLoadMoreSearch = onLoadMoreSearch,
            onClearSearch = onClearSearch,
            onCompose = onCompose,
            onAccounts = { accountsOpen = true },
            onDismissError = onDismissError,
            onDismissNotice = onDismissNotice,
            onCancel = onCancel,
        )
    }

    if (accountsOpen) {
        MailAccountsSheet(
            state = state,
            onDismiss = { accountsOpen = false },
            onAdd = {
                accountsOpen = false
                editor = MailAccountDraftUi(
                    id = null,
                    displayName = "",
                    address = "",
                    incomingProtocol = "imap",
                    incomingHost = "",
                    incomingPort = 993,
                    incomingTls = "implicitTLS",
                    incomingUser = "",
                    incomingSecret = "",
                    outgoingHost = "",
                    outgoingPort = 465,
                    outgoingTls = "implicitTLS",
                    outgoingUser = "",
                    outgoingSecret = "",
                )
            },
            onEdit = { row ->
                accountsOpen = false
                editor = row.toDraft()
            },
            onDelete = onDeleteAccount,
            onTest = onTestSavedAccount,
        )
    }
    val editing = editor
    if (editing != null) {
        MailAccountEditorSheet(
            initial = editing,
            busy = state.busy,
            testResult = state.testResult,
            onDismiss = { editor = null },
            onTest = { draft ->
                onTestAccount(draft)
                draft.copy(incomingSecret = "", outgoingSecret = "")
            },
            onSave = { draft ->
                editor = null
                onSaveAccount(draft.copy(incomingSecret = draft.incomingSecret, outgoingSecret = draft.outgoingSecret))
            },
        )
    }
    val moving = moveRow
    if (moving != null) {
        MoveDestinationSheet(
            row = moving,
            destination = moveDestination,
            onDestinationChange = { moveDestination = it },
            onDismiss = { moveRow = null },
            onMove = {
                moveRow = null
                onMove(moving, "move", moveDestination.trim())
            },
        )
    }
}

@Composable
private fun MailMainScreen(
    state: MailScreenState,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onRefresh: () -> Unit,
    onSelectAccount: (String) -> Unit,
    onSelectFolder: (String) -> Unit,
    onLoadMore: () -> Unit,
    onOpenMessage: (MailRow) -> Unit,
    onOpenSearchMessage: (MailRow) -> Unit,
    searchDraft: MailSearchDraftUi,
    onSearchDraftChange: (MailSearchDraftUi) -> Unit,
    onSearch: (MailSearchDraftUi) -> Unit,
    onLoadMoreSearch: (MailSearchDraftUi) -> Unit,
    onClearSearch: () -> Unit,
    onCompose: () -> Unit,
    onAccounts: () -> Unit,
    onDismissError: () -> Unit,
    onDismissNotice: () -> Unit,
    onCancel: () -> Unit,
    sheetNavigation: (@Composable () -> Unit)? = null,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = stringResource(R.string.mail_title),
            navigation = {
                if (sheetNavigation != null) {
                    sheetNavigation()
                } else if (compact || showSidebarToggle) {
                    FloeCircleButton(
                        icon = FloeIcons.SidebarToggle,
                        contentDescription = stringResource(R.string.open_sidebar),
                        onClick = if (compact) onOpenDrawer else onExpandSidebar,
                    )
                }
            },
            actions = {
                if (state.busy != null) {
                    FloeActivityIndicator(description = stringResource(R.string.mail_busy))
                    FloeCapsuleAction(stringResource(R.string.mail_cancel), onClick = onCancel)
                    Spacer(Modifier.width(6.dp))
                }
                FloeCircleButton(
                    icon = FloeIcons.NewTask,
                    contentDescription = stringResource(R.string.mail_compose),
                    onClick = onCompose,
                )
                FloeCircleButton(
                    icon = FloeIcons.Gearshape,
                    contentDescription = stringResource(R.string.mail_accounts),
                    onClick = onAccounts,
                )
                FloeCircleButton(
                    icon = FloeIcons.Refresh,
                    contentDescription = stringResource(R.string.mail_refresh),
                    onClick = onRefresh,
                )
            },
            showHairline = true,
        )
        if (state.error != null) {
            MailBanner(text = mailErrorLabel(state.error), destructive = true, onDismiss = onDismissError)
        } else if (state.notice != null || state.moveNote != null || state.testResult != null) {
            MailBanner(
                text = mailNoticeLabel(state.notice ?: state.moveNote ?: state.testResult),
                destructive = false,
                onDismiss = onDismissNotice,
            )
        }
        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                FloeActivityIndicator(description = stringResource(R.string.mail_loading))
            }
            !state.coreReady || !state.schemaReady -> FloeUnavailableView(
                icon = FloeIcons.Bubble,
                title = stringResource(R.string.mail_title),
                description = stringResource(R.string.mail_unavailable),
            )
            state.accounts.isEmpty() -> FloeUnavailableView(
                icon = FloeIcons.Bubble,
                title = stringResource(R.string.mail_empty_title),
                description = stringResource(R.string.mail_empty_hint),
                action = { FloePrimaryAction(stringResource(R.string.mail_add_account), onClick = onAccounts) },
            )
            else -> {
                state.selectedAccount?.let { account ->
                    LazyRow(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        items(state.accounts, key = { it.id }) { row ->
                            MailChip(
                                text = row.displayName.ifBlank { row.address },
                                selected = row.id == state.selectedAccountID,
                                onClick = { onSelectAccount(row.id) },
                            )
                        }
                    }
                    if (state.folders.isNotEmpty()) {
                        LazyRow(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            items(state.folders, key = { it.name }) { folder ->
                                MailChip(
                                    text = folder.name,
                                    selected = folder.name == state.selectedFolder,
                                    onClick = { onSelectFolder(folder.name) },
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    val search = state.search
                    if (search != null) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            FloeText(
                                stringResource(
                                    R.string.mail_search_results,
                                    search.rows.size,
                                    search.totalMatched,
                                ),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                                modifier = Modifier.weight(1f),
                            )
                            FloeCapsuleAction(stringResource(R.string.mail_clear_search), onClick = onClearSearch)
                        }
                        LazyColumn(
                            modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            items(search.rows, key = { "s-${it.id}" }) { row ->
                                MailMessageRow(row = row, onClick = { onOpenSearchMessage(row) })
                            }
                            if (search.hasMore || search.cursorAvailable) {
                                item("more-search") {
                                    LoadMoreButton { onLoadMoreSearch(searchDraft) }
                                }
                            }
                        }
                    } else {
                        MailSearchBar(
                            draft = searchDraft,
                            busy = state.busy != null,
                            onChange = onSearchDraftChange,
                            onSearch = { onSearch(searchDraft) },
                        )
                        FloeDivider()
                        if (state.rows.isEmpty()) {
                            FloeUnavailableView(
                                icon = FloeIcons.Bubble,
                                title = stringResource(R.string.mail_no_messages_title),
                                description = stringResource(R.string.mail_no_messages_hint),
                            )
                        } else {
                            LazyColumn(
                                modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
                                verticalArrangement = Arrangement.spacedBy(2.dp),
                            ) {
                                items(state.rows, key = { it.id }) { row ->
                                    MailMessageRow(row = row, onClick = { onOpenMessage(row) })
                                }
                                if (state.hasMore) {
                                    item("more") { LoadMoreButton(onClick = onLoadMore) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MailSearchBar(
    draft: MailSearchDraftUi,
    busy: Boolean,
    onChange: (MailSearchDraftUi) -> Unit,
    onSearch: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.weight(1f)) {
            FloePlainFormField(
                label = stringResource(R.string.mail_search_hint),
                value = draft.text,
                onValueChange = { onChange(draft.copy(text = it)) },
                enabled = !busy,
            )
        }
        FloeCapsuleAction(stringResource(R.string.mail_search), onClick = onSearch, enabled = !busy)
    }
}

@Composable
private fun MailMessageRow(row: MailRow, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier
                .size(8.dp)
                .clip(RoundedCornerShape(4.dp))
                .background(if (row.seen) Floe.colors.separator else Floe.colors.accent)
        )
        Column(Modifier.weight(1f)) {
            FloeText(
                stringResource(R.string.mail_message_ref, row.id),
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
            FloeText(
                mailByteCount(row.byteCount),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        if (row.flagged) {
            FloeText("★", style = Floe.typography.body, color = Floe.colors.accent)
        }
        FloeText(
            if (row.seen) stringResource(R.string.mail_read) else stringResource(R.string.mail_unread),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
}

@Composable
private fun MailMessageScreen(
    state: MailScreenState,
    message: MailMessageView,
    row: MailRow?,
    compact: Boolean,
    onBack: () -> Unit,
    onLoadMore: () -> Unit,
    onSetRead: (MailRow, Boolean) -> Unit,
    onMove: (MailRow, String, String?) -> Unit,
    onSaveAttachment: (MailAttachmentRow) -> Unit,
    onMoveDestination: (MailRow) -> Unit,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = message.subject.ifBlank { stringResource(R.string.mail_message_title) },
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.mail_back),
                    onClick = onBack,
                )
            },
            actions = {
                if (state.busy != null) FloeActivityIndicator()
            },
            showHairline = true,
        )
        if (state.error != null) {
            MailBanner(text = mailErrorLabel(state.error), destructive = true, onDismiss = {})
        }
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (message.from.isNotBlank()) {
                FloeText(stringResource(R.string.mail_from, message.from), style = Floe.typography.body, color = Floe.colors.label)
            }
            if (message.to.isNotBlank()) {
                FloeText(stringResource(R.string.mail_to, message.to), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            if (message.date.isNotBlank()) {
                FloeText(message.date, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            FloeDivider()
            if (message.text.isNotBlank()) {
                FloeText(message.text, style = Floe.typography.body, color = Floe.colors.label)
            } else if (message.html.isNotBlank()) {
                FloeText(
                    stringResource(R.string.mail_html_plain),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeText(htmlAsPlainText(message.html), style = Floe.typography.body, color = Floe.colors.label)
            } else {
                FloeText(
                    stringResource(R.string.mail_empty_body),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if ((message.hasMoreText || message.hasMoreHtml) && state.busy == null) {
                FloeCapsuleAction(stringResource(R.string.mail_load_more), onClick = onLoadMore)
            }
            if (message.attachments.isNotEmpty()) {
                FloeDivider()
                FloeText(stringResource(R.string.mail_attachments), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                message.attachments.forEach { attachment ->
                    Row(
                        modifier = Modifier.fillMaxWidth().heightIn(min = FloeLayout.MinimumTarget),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Column(Modifier.weight(1f)) {
                            FloeText(attachment.filename, style = Floe.typography.body, color = Floe.colors.label, maxLines = 1)
                            FloeText(mailByteCount(attachment.byteCount), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                        }
                        if (state.busy == null) {
                            FloeCapsuleAction(stringResource(R.string.mail_save), onClick = { onSaveAttachment(attachment) })
                        }
                    }
                }
            }
            if (row != null && state.busy == null) {
                FloeDivider()
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeCapsuleAction(
                        stringResource(if (row.seen) R.string.mail_mark_unread else R.string.mail_mark_read),
                        onClick = { onSetRead(row, !row.seen) },
                    )
                    FloeCapsuleAction(stringResource(R.string.mail_archive), onClick = { onMove(row, "archive", null) })
                    FloeCapsuleAction(stringResource(R.string.mail_trash), onClick = { onMove(row, "trash", null) })
                    FloeCapsuleAction(stringResource(R.string.mail_move), onClick = { onMoveDestination(row) })
                }
            }
            FloeText(
                stringResource(R.string.mail_content_trust),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
        }
    }
}

@Composable
private fun MailComposeScreen(
    state: MailScreenState,
    compose: MailComposeView,
    compact: Boolean,
    onBack: () -> Unit,
    onUpdate: (String?, String?, String?) -> Unit,
    onSend: () -> Unit,
    onPickAttachment: () -> Unit,
    onRemoveAttachment: (String) -> Unit,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = stringResource(R.string.mail_compose_title),
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.mail_close),
                    onClick = onBack,
                )
            },
            actions = {
                if (state.busy == "send") FloeActivityIndicator()
                FloeCapsuleAction(
                    label = stringResource(R.string.mail_send),
                    onClick = onSend,
                    enabled = !compose.locked && state.busy == null,
                )
            },
            showHairline = true,
        )
        if (state.error != null) {
            MailBanner(text = mailErrorLabel(state.error), destructive = true, onDismiss = {})
        }
        if (compose.warning != null) {
            MailBanner(text = mailNoticeLabel(compose.warning), destructive = false, onDismiss = {})
        }
        Column(
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            FloePlainFormField(
                label = stringResource(R.string.mail_to_hint),
                value = compose.recipients,
                onValueChange = { onUpdate(it, null, null) },
                enabled = !compose.locked && state.busy == null,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
            )
            FloePlainFormField(
                label = stringResource(R.string.mail_subject_hint),
                value = compose.subject,
                onValueChange = { onUpdate(null, it, null) },
                enabled = !compose.locked && state.busy == null,
            )
            FloePlainFormField(
                label = stringResource(R.string.mail_body_hint),
                value = compose.body,
                onValueChange = { onUpdate(null, null, it) },
                enabled = !compose.locked && state.busy == null,
                singleLine = false,
                minLines = 8,
                maxLines = 20,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.mail_add_attachment),
                    onClick = onPickAttachment,
                    enabled = !compose.locked && state.busy == null && compose.attachments.size < 10,
                )
                if (state.staging != null) {
                    FloeActivityIndicator()
                    FloeText(
                        "${state.staging} ${mailByteCount(state.stagingBytes.toInt())}",
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
            compose.attachments.forEach { attachment ->
                Row(
                    modifier = Modifier.fillMaxWidth().heightIn(min = FloeLayout.MinimumTarget),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        FloeText(attachment.filename, style = Floe.typography.body, color = Floe.colors.label, maxLines = 1)
                        FloeText(mailByteCount(attachment.byteCount), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    }
                    if (!compose.locked) {
                        FloeCircleButton(
                            icon = FloeIcons.Xmark,
                            contentDescription = stringResource(R.string.mail_remove_attachment),
                            onClick = { onRemoveAttachment(attachment.handle) },
                        )
                    }
                }
            }
            if (compose.locked) {
                FloeText(
                    stringResource(R.string.mail_compose_locked),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
    }
}

@Composable
private fun MailAccountsSheet(
    state: MailScreenState,
    onDismiss: () -> Unit,
    onAdd: () -> Unit,
    onEdit: (MailAccountRow) -> Unit,
    onDelete: (String) -> Unit,
    onTest: (String) -> Unit,
) {
    var pendingDelete by remember { mutableStateOf<MailAccountRow?>(null) }
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = if (state.accounts.size > 3) 0.95f else 0.75f,
        heightFraction = 0.85f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(stringResource(R.string.mail_accounts), style = Floe.typography.section, modifier = Modifier.weight(1f))
                FloeCapsuleAction(stringResource(R.string.mail_add_account), onClick = onAdd)
                Spacer(Modifier.width(6.dp))
                FloeCapsuleAction(stringResource(R.string.mail_close), onClick = onDismiss)
            }
            FloeText(stringResource(R.string.mail_accounts_detail), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            if (state.testResult != null) {
                FloeText(
                    mailNoticeLabel(state.testResult),
                    style = Floe.typography.metadata,
                    color = Floe.colors.accent,
                )
            }
            LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                items(state.accounts, key = { it.id }) { account ->
                    Row(
                        modifier = Modifier.fillMaxWidth().heightIn(min = FloeLayout.MinimumTarget),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            FloeText(account.displayName.ifBlank { account.address }, style = Floe.typography.body, color = Floe.colors.label)
                            FloeText(
                                "${account.incomingProtocol.uppercase()} · ${account.incomingHost}",
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                                maxLines = 1,
                            )
                        }
                        FloeCapsuleAction(stringResource(R.string.mail_edit), onClick = { onEdit(account) })
                        Spacer(Modifier.width(4.dp))
                        FloeCapsuleAction(stringResource(R.string.mail_test), onClick = { onTest(account.id) })
                        Spacer(Modifier.width(4.dp))
                        FloeCapsuleAction(stringResource(R.string.mail_delete), onClick = { pendingDelete = account })
                    }
                }
            }
        }
    }
    val deleting = pendingDelete
    if (deleting != null) {
        FloeConfirmDialog(
            title = stringResource(R.string.mail_delete_title),
            message = stringResource(R.string.mail_delete_message),
            confirmLabel = stringResource(R.string.mail_delete),
            dismissLabel = stringResource(R.string.mail_cancel),
            onConfirm = {
                pendingDelete = null
                onDelete(deleting.id)
            },
            onDismiss = { pendingDelete = null },
        )
    }
}

@Composable
private fun MailAccountEditorSheet(
    initial: MailAccountDraftUi,
    busy: String?,
    testResult: String?,
    onDismiss: () -> Unit,
    onTest: (MailAccountDraftUi) -> Unit,
    onSave: (MailAccountDraftUi) -> Unit,
) {
    var draft by remember { mutableStateOf(initial) }
    var incomingRevealed by remember { mutableStateOf(false) }
    var outgoingRevealed by remember { mutableStateOf(false) }
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.9f,
        heightFraction = 0.95f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(stringResource(R.string.mail_account_title), style = Floe.typography.section, modifier = Modifier.weight(1f))
                FloeCapsuleAction(stringResource(R.string.mail_cancel), onClick = onDismiss)
                Spacer(Modifier.width(6.dp))
                FloeCapsuleAction(
                    stringResource(R.string.mail_save),
                    onClick = { onSave(draft.copy(incomingSecret = draft.incomingSecret, outgoingSecret = draft.outgoingSecret)) },
                    enabled = busy == null,
                )
            }
            FloeDivider()
            Column(
                modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FloePlainFormField(
                    label = stringResource(R.string.mail_display_name_hint),
                    value = draft.displayName,
                    onValueChange = { draft = draft.copy(displayName = it) },
                )
                FloePlainFormField(
                    label = stringResource(R.string.mail_address_hint),
                    value = draft.address,
                    onValueChange = { draft = draft.copy(address = it) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                )
                FloeText(stringResource(R.string.mail_incoming), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                FloeSegmented(
                    options = listOf("IMAP", "POP3"),
                    selectedIndex = if (draft.incomingProtocol == "imap") 0 else 1,
                    onSelect = { index ->
                        draft = draft.copy(
                            incomingProtocol = if (index == 0) "imap" else "pop3",
                            incomingPort = defaultPort(if (index == 0) "imap" else "pop3", draft.incomingTls),
                        )
                    },
                )
                MailServerFields(
                    host = draft.incomingHost,
                    port = draft.incomingPort.toString(),
                    tls = draft.incomingTls,
                    user = draft.incomingUser,
                    secret = draft.incomingSecret,
                    revealed = incomingRevealed,
                    onHost = { draft = draft.copy(incomingHost = it) },
                    onPort = { draft = draft.copy(incomingPort = it.toIntOrNull() ?: draft.incomingPort) },
                    onTls = {
                        draft = draft.copy(
                            incomingTls = it,
                            incomingPort = defaultPort(draft.incomingProtocol, it),
                        )
                    },
                    onUser = { draft = draft.copy(incomingUser = it) },
                    onSecret = { draft = draft.copy(incomingSecret = it) },
                    onReveal = { incomingRevealed = !incomingRevealed },
                )
                FloeText(stringResource(R.string.mail_outgoing), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                MailServerFields(
                    host = draft.outgoingHost,
                    port = draft.outgoingPort.toString(),
                    tls = draft.outgoingTls,
                    user = draft.outgoingUser,
                    secret = draft.outgoingSecret,
                    revealed = outgoingRevealed,
                    onHost = { draft = draft.copy(outgoingHost = it) },
                    onPort = { draft = draft.copy(outgoingPort = it.toIntOrNull() ?: draft.outgoingPort) },
                    onTls = { draft = draft.copy(outgoingTls = it, outgoingPort = if (it == "implicitTLS") 465 else 587) },
                    onUser = { draft = draft.copy(outgoingUser = it) },
                    onSecret = { draft = draft.copy(outgoingSecret = it) },
                    onReveal = { outgoingRevealed = !outgoingRevealed },
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeCapsuleAction(
                        stringResource(R.string.mail_test),
                        onClick = { onTest(draft.copy(incomingSecret = draft.incomingSecret, outgoingSecret = draft.outgoingSecret)) },
                        enabled = busy == null,
                    )
                    if (busy == "test") FloeActivityIndicator()
                    if (testResult != null) {
                        FloeText(
                            mailNoticeLabel(testResult),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }
                FloeText(
                    stringResource(R.string.mail_password_keep_hint),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeText(
                    stringResource(R.string.mail_oauth_note),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
    }
}

@Composable
private fun MailServerFields(
    host: String,
    port: String,
    tls: String,
    user: String,
    secret: String,
    revealed: Boolean,
    onHost: (String) -> Unit,
    onPort: (String) -> Unit,
    onTls: (String) -> Unit,
    onUser: (String) -> Unit,
    onSecret: (String) -> Unit,
    onReveal: () -> Unit,
) {
    FloePlainFormField(
        label = stringResource(R.string.mail_host_hint),
        value = host,
        onValueChange = onHost,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
    )
    FloePlainFormField(
        label = stringResource(R.string.mail_port_hint),
        value = port,
        onValueChange = onPort,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
    )
    FloeSegmented(
        options = listOf("SSL/TLS", "STARTTLS"),
        selectedIndex = if (tls == "implicitTLS") 0 else 1,
        onSelect = { onTls(if (it == 0) "implicitTLS" else "startTLS") },
    )
    FloePlainFormField(
        label = stringResource(R.string.mail_username_hint),
        value = user,
        onValueChange = onUser,
    )
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.weight(1f)) {
            CupertinoTextField(
                value = secret,
                onValueChange = onSecret,
                modifier = Modifier.fillMaxWidth().heightIn(min = FloeLayout.MinimumTarget),
                textStyle = Floe.typography.body,
                placeholder = {
                    FloeText(
                        stringResource(R.string.mail_password_hint),
                        style = Floe.typography.body,
                        color = Floe.colors.placeholderText,
                    )
                },
                visualTransformation = if (revealed) VisualTransformation.None else PasswordVisualTransformation(),
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                colors = CupertinoTextFieldDefaults.colors(),
            )
        }
        FloeCapsuleAction(
            stringResource(if (revealed) R.string.mail_hide else R.string.mail_show),
            onClick = onReveal,
        )
    }
}

@Composable
private fun MoveDestinationSheet(
    row: MailRow,
    destination: String,
    onDestinationChange: (String) -> Unit,
    onDismiss: () -> Unit,
    onMove: () -> Unit,
) {
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.65f,
        heightFraction = 0.45f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(
            Modifier.fillMaxSize().padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            FloeText(stringResource(R.string.mail_move_title), style = Floe.typography.section)
            FloeText(stringResource(R.string.mail_move_message), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            FloePlainFormField(
                label = stringResource(R.string.mail_move_destination_hint),
                value = destination,
                onValueChange = onDestinationChange,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleAction(stringResource(R.string.mail_cancel), onClick = onDismiss)
                FloeCapsuleAction(
                    stringResource(R.string.mail_move),
                    onClick = onMove,
                    enabled = destination.trim().isNotEmpty(),
                )
            }
        }
    }
}

@Composable
private fun MailBanner(text: String, destructive: Boolean, onDismiss: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (destructive) Floe.colors.destructive.copy(alpha = 0.1f) else Floe.colors.fillTertiary)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FloeText(
            text,
            style = Floe.typography.metadata,
            color = if (destructive) Floe.colors.destructive else Floe.colors.secondaryLabel,
            modifier = Modifier.weight(1f),
        )
        FloeCapsuleAction(stringResource(R.string.mail_dismiss), onClick = onDismiss)
    }
}

@Composable
private fun MailChip(text: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(16.dp))
            .background(if (selected) Floe.colors.accent.copy(alpha = 0.14f) else Floe.colors.chromeSurface)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            text,
            style = Floe.typography.metadata,
            color = if (selected) Floe.colors.accent else Floe.colors.label,
            maxLines = 1,
        )
    }
}

@Composable
private fun LoadMoreButton(onClick: () -> Unit) {
    Box(Modifier.fillMaxWidth().padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
        FloeCapsuleAction(stringResource(R.string.mail_load_more), onClick = onClick)
    }
}

@Composable
private fun mailErrorLabel(raw: String?): String {
    val code = raw?.substringBefore(':')?.takeIf { it.isNotBlank() } ?: return stringResource(R.string.mail_error_unknown)
    return when (code) {
        "mail_error_searchCriteria" -> stringResource(R.string.mail_error_searchCriteria)
        "mail_error_tooManyAttachments" -> stringResource(R.string.mail_error_tooManyAttachments)
        "mail_error_recipientRequired" -> stringResource(R.string.mail_error_recipientRequired)
        "mail_error_tooManyRecipients" -> stringResource(R.string.mail_error_tooManyRecipients)
        "mail_error_bodyTooLarge" -> stringResource(R.string.mail_error_bodyTooLarge)
        "mail_error_subjectTooLong" -> stringResource(R.string.mail_error_subjectTooLong)
        "transportUnavailable" -> stringResource(R.string.mail_error_transport)
        "storageUnavailable" -> stringResource(R.string.mail_error_storage)
        "credentialMissing", "credentialInvalid", "gatewayUnavailable" -> stringResource(R.string.mail_error_credentials)
        "authenticationFailed" -> stringResource(R.string.mail_error_auth)
        "tlsFailed" -> stringResource(R.string.mail_error_tls)
        "connectionRefused", "networkUnreachable", "transportFailed", "timedOut" -> stringResource(R.string.mail_error_network)
        "protocolRejected", "responseTooLarge", "responseInvalid" -> stringResource(R.string.mail_error_server)
        "unsupportedForPOP3" -> stringResource(R.string.mail_error_pop3)
        "mailboxChanged", "messageNotFound", "cursorMismatch" -> stringResource(R.string.mail_error_stale)
        "deliveryUnknown" -> stringResource(R.string.mail_error_delivery_unknown)
        "mutationUnknown" -> stringResource(R.string.mail_error_mutation_unknown)
        "attachmentTooLarge", "attachmentNotFound", "draftIncomplete", "draftNotFound" -> stringResource(R.string.mail_error_attachment)
        "accountNotFound", "accountLimit", "invalidAccount" -> stringResource(R.string.mail_error_account)
        "cleanupIncomplete" -> stringResource(R.string.mail_error_cleanup)
        "localNetworkPermissionRequired" -> stringResource(R.string.mail_error_local_network)
        "cancelled" -> stringResource(R.string.mail_error_cancelled)
        "runtimeNotInstalled", "coreUnavailable" -> stringResource(R.string.mail_error_runtime)
        else -> stringResource(R.string.mail_error_unknown)
    }
}

@Composable
private fun mailNoticeLabel(raw: String?): String = when (raw) {
    "mail_sent_accepted" -> stringResource(R.string.mail_sent_accepted)
    "mail_sent_receiptWarning" -> stringResource(R.string.mail_sent_receipt_warning)
    "mail_send_deliveryUnknown" -> stringResource(R.string.mail_send_delivery_unknown)
    "mail_send_notSubmitted" -> stringResource(R.string.mail_send_not_submitted)
    "mail_send_deliveryUnknownReplay" -> stringResource(R.string.mail_send_delivery_unknown)
    "mail_attachment_saved" -> stringResource(R.string.mail_attachment_saved)
    "mail_test_success" -> stringResource(R.string.mail_test_success)
    "mail_move_completed" -> stringResource(R.string.mail_move_completed)
    "mail_move_notStarted" -> stringResource(R.string.mail_move_not_started)
    "mail_move_mutationUnknown" -> stringResource(R.string.mail_move_unknown)
    "mail_move_unsupported" -> stringResource(R.string.mail_move_unsupported)
    else -> raw ?: stringResource(R.string.mail_error_unknown)
}

internal fun defaultPort(protocol: String, tls: String): Int = when (protocol) {
    "pop3" -> if (tls == "implicitTLS") 995 else 110
    else -> if (tls == "implicitTLS") 993 else 143
}

private fun MailAccountRow.toDraft(): MailAccountDraftUi = MailAccountDraftUi(
    id = id,
    displayName = displayName,
    address = address,
    incomingProtocol = incomingProtocol,
    incomingHost = incomingHost,
    incomingPort = incomingPort,
    incomingTls = incomingTls,
    incomingUser = incomingUser,
    incomingSecret = "",
    outgoingHost = outgoingHost,
    outgoingPort = outgoingPort,
    outgoingTls = outgoingTls,
    outgoingUser = outgoingUser,
    outgoingSecret = "",
)

private fun mailByteCount(bytes: Int): String = when {
    bytes >= 1_000_000 -> "${bytes / 1_000_000} MB"
    bytes >= 1_000 -> "${bytes / 1_000} KB"
    else -> "$bytes B"
}

private fun htmlAsPlainText(html: String): String =
    html.replace(Regex("(?is)<(script|style)[^>]*>.*?</\\1>"), " ")
        .replace(Regex("(?s)<[^>]+>"), " ")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace(Regex("\\s+"), " ")
        .trim()
