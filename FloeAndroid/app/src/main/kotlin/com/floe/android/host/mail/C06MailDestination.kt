// SPDX-License-Identifier: MPL-2.0
//
// App-level binding between the C06 controller and the presentation module.
// The actual TLS lane, credential gateway, journals and SAF streaming live in
// the controller/FloeAndroidCore; this file only maps state and callbacks.

package com.floe.android.host.mail

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.mail.MailAccountDraftUi
import com.floe.android.feature.mail.MailAccountRow
import com.floe.android.feature.mail.MailAttachmentRow
import com.floe.android.feature.mail.MailComposeView
import com.floe.android.feature.mail.MailDestinationUi
import com.floe.android.feature.mail.MailDraftAttachmentRow
import com.floe.android.feature.mail.MailFolderRow
import com.floe.android.feature.mail.MailMessageView
import com.floe.android.feature.mail.MailRow
import com.floe.android.feature.mail.MailScreenState
import com.floe.android.feature.mail.MailSearchDraftUi
import com.floe.android.feature.mail.MailSearchView
import com.floe.android.feature.mail.R
import com.floe.android.host.RuntimeHost

@Composable
internal fun C06MailDestination(
    host: RuntimeHost?,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
) {
    if (host == null) {
        FloeUnavailableView(
            icon = FloeIcons.Bubble,
            title = stringResource(R.string.mail_title),
            description = stringResource(R.string.mail_unavailable),
            modifier = Modifier.fillMaxSize(),
        )
        return
    }
    val controller = host.c06Mail
    val state by controller.state.collectAsState()
    LaunchedEffect(controller) { controller.enter() }
    var pendingAttachment by remember { mutableStateOf<MailAttachmentRow?>(null) }
    val saveLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream")
    ) { uri: Uri? ->
        val attachment = pendingAttachment
        pendingAttachment = null
        if (uri != null && attachment != null) {
            controller.saveAttachmentTo(uri, attachment.toModel())
        }
    }
    val pickLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.GetContent()
    ) { uri: Uri? ->
        if (uri != null) controller.stageAttachment(uri)
    }

    MailDestinationUi(
        state = state.toScreenState(),
        compact = compact,
        showSidebarToggle = showSidebarToggle,
        onExpandSidebar = onExpandSidebar,
        onOpenDrawer = onOpenDrawer,
        onRefresh = controller::refresh,
        onSelectAccount = controller::selectAccount,
        onSelectFolder = controller::selectFolder,
        onLoadMore = controller::loadMore,
        onOpenMessage = { row -> controller.openMessage(row.toModel()) },
        onOpenSearchMessage = { row -> controller.openSearchMessage(row.toModel()) },
        onCloseMessage = controller::closeMessage,
        onLoadMoreBody = controller::loadMoreBody,
        onSearch = { draft -> controller.search(draft.toModel()) },
        onLoadMoreSearch = { draft -> controller.loadMoreSearch(draft.toModel()) },
        onClearSearch = controller::clearSearch,
        onSetRead = { row, read -> controller.setRead(row.toModel(), read) },
        onMove = { row, action, destination -> controller.move(row.toModel(), action, destination) },
        onCompose = controller::beginCompose,
        onUpdateCompose = { recipients, subject, body ->
            controller.updateCompose(recipients, subject, body)
        },
        onSendCompose = controller::sendCompose,
        onDiscardCompose = controller::discardCompose,
        onPickAttachment = { pickLauncher.launch("*/*") },
        onRemoveAttachment = controller::removeAttachment,
        onSaveAttachment = { attachment ->
            pendingAttachment = attachment
            saveLauncher.launch(attachment.filename)
        },
        onSaveAccount = { draft -> controller.saveAccount(draft.toModel()) },
        onDeleteAccount = controller::deleteAccount,
        onTestAccount = { draft -> if (draft != null) controller.testAccount(draft.toModel()) },
        onTestSavedAccount = controller::testSavedAccount,
        onDismissError = controller::dismissError,
        onDismissNotice = controller::dismissNotice,
        onCancel = controller::cancelActive,
    )
}

private fun C06MailUiState.toScreenState(): MailScreenState = MailScreenState(
    loading = loading,
    busy = busy,
    coreReady = coreReady,
    schemaReady = schemaReady,
    transportReady = transportReady,
    credentialReady = credentialReady,
    accounts = accounts.map { it.toRow() },
    selectedAccountID = selectedAccountID,
    folders = folders.map { MailFolderRow(it.name, it.attributes) },
    selectedFolder = selectedFolder,
    rows = listing?.messages?.map { it.toRow() } ?: emptyList(),
    mailboxVersion = listing?.mailboxVersion,
    hasMore = listing?.hasMore ?: false,
    message = message?.toView(),
    messageRow = messageRow?.toRow(),
    search = search?.let {
        MailSearchView(
            folder = it.folder,
            rows = it.messages.map { row -> row.toRow() },
            hasMore = it.hasMore,
            totalMatched = it.totalMatched,
            cursorAvailable = it.nextCursor != null,
        )
    },
    compose = compose?.toView(locked = composeLocked, warning = composeWarning),
    testResult = if (testResult != null) "mail_test_success" else null,
    moveNote = moveNote,
    staging = staging,
    stagingBytes = stagingBytes,
    notice = notice,
    error = error,
)

private fun C06MailAccountUi.toRow(): MailAccountRow = MailAccountRow(
    id = id,
    displayName = displayName,
    address = address,
    incomingProtocol = incomingProtocol,
    incomingHost = incoming.host,
    incomingPort = incoming.port,
    incomingTls = incoming.tls,
    incomingUser = incoming.username,
    outgoingHost = outgoing.host,
    outgoingPort = outgoing.port,
    outgoingTls = outgoing.tls,
    outgoingUser = outgoing.username,
    revision = revision,
)

private fun C06MailRowUi.toRow(): MailRow = MailRow(id = id, byteCount = byteCount, flags = flags)

private fun MailRow.toModel(): C06MailRowUi = C06MailRowUi(id = id, byteCount = byteCount, flags = flags)

internal fun C06MailMessageUi.toView(): MailMessageView = MailMessageView(
    subject = subject,
    from = from,
    to = to,
    date = date,
    text = text,
    html = html,
    sha256 = sha256,
    attachments = attachments.map {
        MailAttachmentRow(
            index = it.index,
            filename = it.filename,
            byteCount = it.byteCount,
            sha256 = it.sha256,
        )
    },
    hasMoreText = hasMoreText,
    hasMoreHtml = hasMoreHtml,
)

private fun C06MailComposeDraft.toView(locked: Boolean, warning: String?): MailComposeView = MailComposeView(
    accountID = accountID,
    recipients = recipients,
    subject = subject,
    body = body,
    attachments = attachments.map {
        MailDraftAttachmentRow(
            handle = it.handle,
            filename = it.filename,
            byteCount = it.byteCount,
            sha256 = it.sha256,
        )
    },
    locked = locked,
    warning = warning,
)

private fun MailAccountDraftUi.toModel(): C06MailAccountDraft = C06MailAccountDraft(
    id = id,
    displayName = displayName,
    address = address,
    incomingProtocol = incomingProtocol,
    incoming = C06MailServerUi(
        host = incomingHost,
        port = incomingPort,
        tls = incomingTls,
        username = incomingUser,
    ),
    outgoing = C06MailServerUi(
        host = outgoingHost,
        port = outgoingPort,
        tls = outgoingTls,
        username = outgoingUser,
    ),
    incomingSecret = incomingSecret,
    outgoingSecret = outgoingSecret,
)

private fun MailSearchDraftUi.toModel(): C06MailSearchDraft = C06MailSearchDraft(
    subject = subject,
    from = from,
    to = to,
    text = text,
    unseenOnly = unseenOnly,
)

private fun MailAttachmentRow.toModel(): C06MailAttachmentUi = C06MailAttachmentUi(
    index = index,
    filename = filename,
    byteCount = byteCount,
    sha256 = sha256,
)
