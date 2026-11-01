// SPDX-License-Identifier: MPL-2.0
//
// Application-owned C06 mail controller.
//
// Owns the trusted bridge calls, the platform TLS lane, the compose draft and
// the bounded SAF attachment transfer. It survives Activity reconstruction
// because RuntimeHost is app-scoped; a send or attachment stage therefore
// never belongs to a view lifetime. Every call is fenced by the current Root
// epoch and closed by RuntimeHost before root retirement.
//
// Secrets exist only as the editor's in-memory password strings for one
// account-save/test request and are cleared in `finally`; they are never
// copied into UI state, a log, a saved draft or a report.

package com.floe.android.host.mail

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class PickedMailFile(
    val filename: String,
    val size: Long?,
    val open: () -> InputStream,
)

internal fun interface MailFileSource {
    fun open(uri: Uri): PickedMailFile?
}

internal class AndroidMailFileSource(
    private val resolver: ContentResolver,
) : MailFileSource {
    override fun open(uri: Uri): PickedMailFile? {
        var name = "attachment"
        var size: Long? = null
        resolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0) name = cursor.getString(nameIndex) ?: name
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    val reported = cursor.getLong(sizeIndex)
                    if (reported >= 0) size = reported
                }
            }
        }
        if (resolver.openInputStream(uri) == null) return null
        return PickedMailFile(name, size) {
            resolver.openInputStream(uri) ?: throw IOException("attachment_source_unavailable")
        }
    }
}

internal data class C06MailUiState(
    val loading: Boolean = false,
    val busy: String? = null,
    val coreReady: Boolean = false,
    val schemaReady: Boolean = false,
    val transportReady: Boolean = false,
    val credentialReady: Boolean = false,
    val accounts: List<C06MailAccountUi> = emptyList(),
    val selectedAccountID: String? = null,
    val folders: List<C06MailFolderUi> = emptyList(),
    val selectedFolder: String = "INBOX",
    val listing: C06MailListingUi? = null,
    val search: C06MailSearchPageUi? = null,
    val searchActive: Boolean = false,
    val message: C06MailMessageUi? = null,
    val messageRow: C06MailRowUi? = null,
    val messageFolder: String? = null,
    val messageVersion: String? = null,
    val testResult: C06MailTestUi? = null,
    val compose: C06MailComposeDraft? = null,
    val composeLocked: Boolean = false,
    val composeWarning: String? = null,
    val staging: String? = null,
    val stagingBytes: Long = 0,
    val moveNote: String? = null,
    val notice: String? = null,
    val error: String? = null,
) {
    val selectedAccount: C06MailAccountUi?
        get() = accounts.firstOrNull { it.id == selectedAccountID }

    val canSend: Boolean
        get() = compose != null && !composeLocked && busy == null
}

internal class C06MailHostController(
    private val scope: CoroutineScope,
    private val contentResolver: ContentResolver,
    private val currentNativeEpoch: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val mainDispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val client: C06MailClient = C06MailClient(),
    private val lanGate: C06MailLanGate? = null,
    private val lane: MailTransportLane = MailTransportLane(scope, lanGate = lanGate),
    private val fileSource: MailFileSource = AndroidMailFileSource(contentResolver),
    private val log: (String) -> Unit = { message ->
        Log.println(Log.DEBUG, "FloeC06Mail", message)
    },
) {
    private val ownerToken = UUID.randomUUID().toString()
    private val _state = MutableStateFlow(C06MailUiState())
    val state: StateFlow<C06MailUiState> = _state.asStateFlow()

    private val started = AtomicBoolean(false)
    private val starting = AtomicBoolean(false)
    private val moveRequests = ConcurrentHashMap<String, String>()
    @Volatile private var lastEpoch: Long = 0

    fun onOwnedStoreReady() {
        val epoch = currentNativeEpoch() ?: return
        if (!starting.compareAndSet(false, true)) return
        lastEpoch = epoch
        scope.launch {
            try {
                val startedLane = runCatching {
                    withContext(ioDispatcher) { lane.start(epoch) }
                }.getOrDefault(false)
                if (!startedLane) {
                    fail(C06MailFailure(
                        "transportUnavailable",
                        "mailTransportUnavailable",
                        retryable = true,
                    ))
                    return@launch
                }
                started.set(true)
                load()
            } finally {
                starting.set(false)
            }
        }
    }

    fun enter() {
        if (!started.get()) {
            onOwnedStoreReady()
        } else if (_state.value.accounts.isEmpty() && _state.value.error == null) {
            load()
        }
    }

    fun load() {
        if (_state.value.busy != null || _state.value.loading) return
        scope.launch {
            _state.update { it.copy(loading = true, error = null) }
            try {
                val capabilities = withContext(ioDispatcher) { client.capabilities() }
                lastEpoch = capabilities.epoch ?: lastEpoch
                if (!capabilities.coreReady || !capabilities.schemaReady) {
                    _state.update {
                        it.copy(
                            loading = false,
                            coreReady = capabilities.coreReady,
                            schemaReady = capabilities.schemaReady,
                            transportReady = capabilities.transportReady,
                            credentialReady = capabilities.credentialGatewayReady,
                        )
                    }
                    return@launch
                }
                val accounts = withContext(ioDispatcher) { client.accountList(owner()) }
                val selected = _state.value.selectedAccountID
                    ?.takeIf { id -> accounts.any { it.id == id } }
                    ?: accounts.firstOrNull()?.id
                _state.update {
                    it.copy(
                        loading = false,
                        coreReady = true,
                        schemaReady = true,
                        transportReady = capabilities.transportReady,
                        credentialReady = capabilities.credentialGatewayReady,
                        accounts = accounts,
                        selectedAccountID = selected,
                    )
                }
                if (selected != null) {
                    loadFolders(selected, resetFolder = _state.value.selectedFolder == "INBOX")
                }
            } catch (failure: C06MailFailure) {
                fail(failure, loading = false)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "loadFailed", detail = error.message), loading = false)
            }
        }
    }

    fun refresh() {
        load()
    }

    fun selectAccount(id: String) {
        if (_state.value.selectedAccountID == id) return
        _state.update {
            it.copy(
                selectedAccountID = id,
                folders = emptyList(),
                selectedFolder = "INBOX",
                listing = null,
                search = null,
                searchActive = false,
                message = null,
                messageRow = null,
                compose = null,
                error = null,
            )
        }
        loadFolders(id, resetFolder = true)
    }

    fun selectFolder(name: String) {
        val accountID = _state.value.selectedAccountID ?: return
        _state.update { it.copy(selectedFolder = name, search = null, searchActive = false, message = null) }
        loadList(accountID, name, reset = true)
    }

    fun loadMore() {
        if (_state.value.busy != null) return
        val accountID = _state.value.selectedAccountID ?: return
        val listing = _state.value.listing ?: return
        val account = _state.value.selectedAccount ?: return
        if (!listing.hasMore || listing.messages.isEmpty()) return
        val last = listing.messages.last()
        if (account.incomingProtocol == "pop3") {
            loadList(accountID, listing.folder, reset = false, beforeMessageID = last.id)
        } else {
            loadList(accountID, listing.folder, reset = false, afterUID = last.id.toLongOrNull() ?: 0)
        }
    }

    fun openMessage(row: C06MailRowUi) {
        val accountID = _state.value.selectedAccountID ?: return
        val listing = _state.value.listing ?: return
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "message", error = null) }
            try {
                val message = withContext(ioDispatcher) {
                    client.message(
                        accountID = accountID,
                        folder = listing.folder,
                        messageID = row.id,
                        mailboxVersion = listing.mailboxVersion,
                        bodyCursor = null,
                        owner = owner(),
                    )
                }
                _state.update {
                    it.copy(
                        busy = null,
                        message = message,
                        messageRow = row,
                        messageFolder = listing.folder,
                        messageVersion = listing.mailboxVersion,
                    )
                }
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "messageFailed", detail = error.message), busy = null)
            }
        }
    }

    fun closeMessage() {
        _state.update {
            it.copy(
                message = null,
                messageRow = null,
                messageFolder = null,
                messageVersion = null,
            )
        }
    }

    fun openSearchMessage(row: C06MailRowUi) {
        val accountID = _state.value.selectedAccountID ?: return
        val page = _state.value.search ?: return
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "message", error = null) }
            try {
                val message = withContext(ioDispatcher) {
                    client.message(
                        accountID = accountID,
                        folder = page.folder,
                        messageID = row.id,
                        mailboxVersion = page.mailboxVersion,
                        bodyCursor = null,
                        owner = owner(),
                    )
                }
                _state.update {
                    it.copy(
                        busy = null,
                        message = message,
                        messageRow = row,
                        messageFolder = page.folder,
                        messageVersion = page.mailboxVersion,
                    )
                }
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "messageFailed", detail = error.message), busy = null)
            }
        }
    }

    fun loadMoreBody() {
        val accountID = _state.value.selectedAccountID ?: return
        val message = _state.value.message ?: return
        val row = _state.value.messageRow ?: return
        val folder = _state.value.messageFolder ?: return
        val version = _state.value.messageVersion
        val cursor = message.nextTextCursor ?: message.nextHtmlCursor ?: return
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "body") }
            try {
                val next = withContext(ioDispatcher) {
                    client.message(
                        accountID = accountID,
                        folder = folder,
                        messageID = row.id,
                        mailboxVersion = version,
                        bodyCursor = cursor,
                        owner = owner(),
                    )
                }
                _state.update {
                    val current = it.message ?: message
                    it.copy(
                        busy = null,
                        message = current.copy(
                            text = current.text + next.text,
                            html = current.html + next.html,
                            hasMoreText = next.hasMoreText,
                            hasMoreHtml = next.hasMoreHtml,
                            nextTextCursor = next.nextTextCursor,
                            nextHtmlCursor = next.nextHtmlCursor,
                        ),
                    )
                }
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "bodyFailed", detail = error.message), busy = null)
            }
        }
    }

    fun search(draft: C06MailSearchDraft) {
        if (_state.value.selectedAccount?.incomingProtocol == "pop3") {
            _state.update { it.copy(error = "unsupportedForPOP3") }
            return
        }
        val accountID = _state.value.selectedAccountID ?: return
        val folder = _state.value.selectedFolder
        if (_state.value.busy != null) return
        if (draft.subject.isBlank() && draft.from.isBlank() && draft.to.isBlank()
            && draft.text.isBlank() && !draft.unseenOnly
        ) {
            _state.update { it.copy(error = "mail_error_searchCriteria") }
            return
        }
        scope.launch {
            _state.update { it.copy(busy = "search", error = null) }
            try {
                val page = withContext(ioDispatcher) {
                    client.search(accountID, folder, draft, null, 20, owner())
                }
                _state.update { it.copy(busy = null, search = page, searchActive = true) }
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "searchFailed", detail = error.message), busy = null)
            }
        }
    }

    fun loadMoreSearch(draft: C06MailSearchDraft) {
        val accountID = _state.value.selectedAccountID ?: return
        val page = _state.value.search ?: return
        val cursor = page.nextCursor ?: return
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "search") }
            try {
                val next = withContext(ioDispatcher) {
                    client.search(accountID, page.folder, draft, cursor, 20, owner())
                }
                _state.update {
                    it.copy(
                        busy = null,
                        search = next.copy(messages = page.messages + next.messages),
                    )
                }
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "searchFailed", detail = error.message), busy = null)
            }
        }
    }

    fun clearSearch() {
        _state.update { it.copy(search = null, searchActive = false) }
    }

    fun setRead(row: C06MailRowUi, read: Boolean) {
        if (_state.value.selectedAccount?.incomingProtocol == "pop3") {
            _state.update { it.copy(error = "unsupportedForPOP3") }
            return
        }
        val accountID = _state.value.selectedAccountID ?: return
        val listing = _state.value.listing ?: return
        val folder = _state.value.messageFolder ?: listing.folder
        val version = _state.value.messageVersion ?: listing.mailboxVersion ?: return
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "readState", error = null) }
            try {
                withContext(ioDispatcher) {
                    client.setRead(accountID, row.id, folder, version, read, owner())
                }
                val updatedFlags = row.flags.filterNot { it.equals("\\Seen", ignoreCase = true) }
                    .let { if (read) it + "\\Seen" else it }
                val updatedRow = row.copy(flags = updatedFlags)
                _state.update { current ->
                    current.copy(
                        busy = null,
                        listing = current.listing?.copy(
                            messages = current.listing.messages.map {
                                if (it.id == row.id) updatedRow else it
                            }
                        ),
                        messageRow = if (current.messageRow?.id == row.id) updatedRow else current.messageRow,
                        search = current.search?.copy(
                            rows = current.search.rows.map {
                                if (it.id == row.id) updatedRow else it
                            }
                        ),
                    )
                }
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "readStateFailed", detail = error.message), busy = null)
            }
        }
    }

    fun move(row: C06MailRowUi, action: String, destination: String?) {
        if (_state.value.selectedAccount?.incomingProtocol == "pop3") {
            _state.update { it.copy(error = "unsupportedForPOP3") }
            return
        }
        val accountID = _state.value.selectedAccountID ?: return
        val listing = _state.value.listing ?: return
        val folder = _state.value.messageFolder ?: listing.folder
        val version = _state.value.messageVersion ?: listing.mailboxVersion ?: return
        if (_state.value.busy != null) return
        val key = "$action|$folder|${row.id}"
        val requestID = moveRequests.getOrPut(key) { UUID.randomUUID().toString() }
        scope.launch {
            _state.update { it.copy(busy = "move", error = null, moveNote = null) }
            try {
                val result = withContext(ioDispatcher) {
                    client.move(
                        accountID = accountID,
                        requestID = requestID,
                        messageID = row.id,
                        folder = folder,
                        mailboxVersion = version,
                        action = action,
                        destination = destination,
                        owner = owner(),
                    )
                }
                when (result.status) {
                    "completed", "notStarted" -> {
                        moveRequests.remove(key)
                        _state.update {
                            it.copy(
                                busy = null,
                                message = null,
                                messageRow = null,
                                moveNote = "mail_move_" + result.status,
                            )
                        }
                        loadList(accountID, folder, reset = true)
                    }
                    "mutationUnknown" -> {
                        _state.update {
                            it.copy(busy = null, moveNote = "mail_move_mutationUnknown")
                        }
                    }
                    "unsupported" -> {
                        moveRequests.remove(key)
                        _state.update {
                            it.copy(busy = null, moveNote = "mail_move_unsupported")
                        }
                    }
                    else -> _state.update { it.copy(busy = null) }
                }
            } catch (failure: C06MailFailure) {
                if (failure.code == "timedOut") {
                    _state.update {
                        it.copy(busy = null, moveNote = "mail_move_mutationUnknown")
                    }
                } else {
                    fail(failure, busy = null)
                }
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "moveFailed", detail = error.message), busy = null)
            }
        }
    }

    fun beginCompose() {
        val accountID = _state.value.selectedAccountID ?: return
        _state.update {
            it.copy(
                compose = C06MailComposeDraft(
                    accountID = accountID,
                    recipients = "",
                    subject = "",
                    body = "",
                ),
                composeLocked = false,
                composeWarning = null,
                error = null,
            )
        }
    }

    fun updateCompose(
        recipients: String? = null,
        subject: String? = null,
        body: String? = null,
    ) {
        _state.update { current ->
            val compose = current.compose ?: return@update current
            val changed = (recipients != null && recipients != compose.recipients)
                || (subject != null && subject != compose.subject)
                || (body != null && body != compose.body)
            current.copy(
                compose = compose.copy(
                    recipients = recipients ?: compose.recipients,
                    subject = subject ?: compose.subject,
                    body = body ?: compose.body,
                    requestID = if (changed && current.composeWarning == "mail_send_notSubmitted") {
                        UUID.randomUUID().toString()
                    } else {
                        compose.requestID
                    },
                ),
                composeWarning = if (changed && current.composeWarning == "mail_send_notSubmitted") {
                    null
                } else {
                    current.composeWarning
                },
            )
        }
    }

    fun stageAttachment(uri: Uri) {
        val accountID = _state.value.selectedAccountID ?: return
        val compose = _state.value.compose ?: return
        if (_state.value.busy != null || _state.value.composeLocked) return
        if (compose.recipientList.size > 50) {
            _state.update { it.copy(error = "mail_error_tooManyRecipients") }
            return
        }
        if (compose.attachments.size >= 10
            || compose.attachments.sumOf { it.byteCount.toLong() } >= 10_000_000L
        ) {
            _state.update { it.copy(error = "mail_error_tooManyAttachments") }
            return
        }
        scope.launch {
            _state.update { it.copy(busy = "stage", staging = "prepare", stagingBytes = 0, error = null) }
            var handle: String? = null
            try {
                val picked = withContext(ioDispatcher) { fileSource.open(uri) }
                    ?: throw C06MailFailure("attachmentNotFound", "attachment_source_unavailable")
                val filename = sanitizeFilename(picked.filename)
                picked.size?.let { size ->
                    if (size <= 0 || size > 10_000_000L) {
                        throw C06MailFailure("attachmentTooLarge", "attachmentTooLarge")
                    }
                }
                val digest = MessageDigest.getInstance("SHA-256")
                var count = 0L
                withContext(ioDispatcher) {
                    picked.open().use { input ->
                        val buffer = ByteArray(24_576)
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            count += read
                            if (count > 10_000_000L) {
                                throw C06MailFailure("attachmentTooLarge", "attachmentTooLarge")
                            }
                            digest.update(buffer, 0, read)
                        }
                    }
                }
                if (count <= 0L) throw C06MailFailure("draftIncomplete", "emptyAttachment")
                val existingBytes = compose.attachments.sumOf { it.byteCount.toLong() }
                if (existingBytes + count > 10_000_000L) {
                    throw C06MailFailure("attachmentTooLarge", "attachmentTooLarge")
                }
                val sha = digest.digest().joinToString("") { "%02x".format(it) }
                val started = withContext(ioDispatcher) {
                    client.draftBegin(accountID, filename, count.toInt(), sha, owner())
                }
                handle = started.handle
                var offset = 0
                withContext(ioDispatcher) {
                    picked.open().use { input ->
                        val buffer = ByteArray(24_576)
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            if (read == 0) continue
                            client.draftWrite(
                                started.handle,
                                offset,
                                buffer.copyOf(read),
                                owner(),
                            )
                            offset += read
                            _state.update { it.copy(stagingBytes = offset.toLong()) }
                        }
                    }
                }
                val finished = withContext(ioDispatcher) {
                    client.draftFinish(started.handle, owner())
                }
                handle = null
                _state.update { current ->
                    val active = current.compose ?: return@update current
                    current.copy(
                        busy = null,
                        staging = null,
                        stagingBytes = 0,
                        compose = active.copy(attachments = active.attachments + finished),
                    )
                }
            } catch (failure: C06MailFailure) {
                handle?.let { stale ->
                    runCatching { withContext(ioDispatcher) { client.draftDiscard(stale, owner()) } }
                }
                fail(failure, busy = null, staging = null, stagingBytes = 0)
            } catch (error: Throwable) {
                handle?.let { stale ->
                    runCatching { withContext(ioDispatcher) { client.draftDiscard(stale, owner()) } }
                }
                fail(C06MailFailure("unknown", "stageFailed", detail = error.message),
                    busy = null, staging = null, stagingBytes = 0)
            }
        }
    }

    fun removeAttachment(handle: String) {
        if (_state.value.busy != null || _state.value.composeLocked) return
        val compose = _state.value.compose ?: return
        scope.launch {
            runCatching { withContext(ioDispatcher) { client.draftDiscard(handle, owner()) } }
            _state.update {
                it.copy(compose = it.compose?.copy(
                    attachments = it.compose.attachments.filterNot { attachment -> attachment.handle == handle }
                ))
            }
        }
    }

    fun sendCompose() {
        val compose = _state.value.compose ?: return
        if (_state.value.busy != null || _state.value.composeLocked) return
        val recipients = compose.recipientList
        if (recipients.isEmpty()) {
            _state.update { it.copy(error = "mail_error_recipientRequired") }
            return
        }
        if (compose.body.toByteArray(Charsets.UTF_8).size > 32_000) {
            _state.update { it.copy(error = "mail_error_bodyTooLarge") }
            return
        }
        if (compose.subject.toByteArray(Charsets.UTF_8).size > 512) {
            _state.update { it.copy(error = "mail_error_subjectTooLong") }
            return
        }
        scope.launch {
            _state.update { it.copy(busy = "send", error = null, composeWarning = null) }
            try {
                val result = withContext(ioDispatcher) {
                    client.send(
                        accountID = compose.accountID,
                        requestID = compose.requestID,
                        recipients = recipients,
                        subject = compose.subject,
                        body = compose.body,
                        draftHandles = compose.attachments.map { it.handle },
                        owner = owner(),
                    )
                }
                when (result.status) {
                    "acceptedByServer" -> {
                        _state.update {
                            it.copy(
                                busy = null,
                                compose = null,
                                composeLocked = false,
                                composeWarning = null,
                                notice = if (result.warning == null) "mail_sent_accepted" else "mail_sent_receiptWarning",
                            )
                        }
                    }
                    "deliveryUnknown", "deliveryUnknownReplay" -> {
                        _state.update {
                            it.copy(
                                busy = null,
                                composeLocked = true,
                                composeWarning = "mail_send_deliveryUnknown",
                            )
                        }
                    }
                    "notSubmitted" -> {
                        _state.update { current ->
                            current.copy(
                                busy = null,
                                composeWarning = "mail_send_notSubmitted",
                                compose = current.compose?.copy(
                                    requestID = UUID.randomUUID().toString()
                                ),
                            )
                        }
                    }
                    else -> _state.update { it.copy(busy = null) }
                }
            } catch (failure: C06MailFailure) {
                if (failure.code == "timedOut") {
                    _state.update {
                        it.copy(
                            busy = null,
                            composeLocked = true,
                            composeWarning = "mail_send_deliveryUnknown",
                        )
                    }
                } else {
                    fail(failure, busy = null)
                }
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "sendFailed", detail = error.message), busy = null)
            }
        }
    }

    fun discardCompose() {
        if (_state.value.busy == "send") return
        val compose = _state.value.compose ?: return
        scope.launch {
            compose.attachments.forEach { attachment ->
                runCatching { withContext(ioDispatcher) { client.draftDiscard(attachment.handle, owner()) } }
            }
            _state.update {
                it.copy(compose = null, composeLocked = false, composeWarning = null)
            }
        }
    }

    fun saveAccount(draft: C06MailAccountDraft) {
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "save", error = null, testResult = null) }
            try {
                val saved = withContext(ioDispatcher) { client.accountSave(draft, owner()) }
                _state.update {
                    it.copy(busy = null, selectedAccountID = saved.id)
                }
                load()
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "saveFailed", detail = error.message), busy = null)
            } finally {
                draft.incomingSecret = ""
                draft.outgoingSecret = ""
            }
        }
    }

    fun deleteAccount(id: String) {
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "delete", error = null) }
            try {
                withContext(ioDispatcher) { client.accountDelete(id, owner()) }
                _state.update {
                    it.copy(
                        busy = null,
                        accounts = it.accounts.filterNot { account -> account.id == id },
                        selectedAccountID = it.selectedAccountID?.takeIf { selected -> selected != id },
                        folders = emptyList(),
                        listing = null,
                        message = null,
                    )
                }
                load()
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "deleteFailed", detail = error.message), busy = null)
            }
        }
    }

    fun testAccount(draft: C06MailAccountDraft) {
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "test", error = null, testResult = null) }
            try {
                val result = withContext(ioDispatcher) { client.accountTest(draft, null, owner()) }
                _state.update { it.copy(busy = null, testResult = result) }
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "testFailed", detail = error.message), busy = null)
            } finally {
                draft.incomingSecret = ""
                draft.outgoingSecret = ""
            }
        }
    }

    fun testSavedAccount(id: String) {
        if (_state.value.busy != null) return
        scope.launch {
            _state.update { it.copy(busy = "test", error = null, testResult = null) }
            try {
                val result = withContext(ioDispatcher) { client.accountTest(null, id, owner()) }
                _state.update { it.copy(busy = null, testResult = result) }
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "testFailed", detail = error.message), busy = null)
            }
        }
    }

    fun saveAttachmentTo(uri: Uri, attachment: C06MailAttachmentUi) {
        if (_state.value.busy != null) return
        val accountID = _state.value.selectedAccountID ?: return
        val message = _state.value.message ?: return
        val folder = _state.value.messageFolder ?: return
        val version = _state.value.messageVersion
        val row = _state.value.messageRow ?: return
        scope.launch {
            _state.update { it.copy(busy = "download", staging = "download", stagingBytes = 0, error = null) }
            var handle: String? = null
            try {
                val opened = withContext(ioDispatcher) {
                    client.attachmentOpen(
                        accountID = accountID,
                        folder = folder,
                        messageID = row.id,
                        mailboxVersion = version,
                        messageSHA256 = message.sha256,
                        attachmentIndex = attachment.index,
                        owner = owner(),
                    )
                }
                handle = opened.handle
                withContext(ioDispatcher) {
                    val output = contentResolver.openOutputStream(uri, "w")
                        ?: throw C06MailFailure(
                            "storageUnavailable",
                            "attachment_destination_unavailable",
                        )
                    output.use { stream ->
                        var offset = 0
                        while (offset < opened.byteCount) {
                            val chunk = client.attachmentRead(
                                opened.handle,
                                offset,
                                24_576,
                                owner(),
                            )
                            if (chunk.data.isEmpty()) {
                                throw C06MailFailure("storageUnavailable", "attachmentReadShort")
                            }
                            stream.write(chunk.data)
                            offset += chunk.data.size
                            _state.update { it.copy(stagingBytes = offset.toLong()) }
                        }
                        if (offset != opened.byteCount) {
                            throw C06MailFailure("storageUnavailable", "attachmentReadShort")
                        }
                        stream.flush()
                    }
                }
                withContext(ioDispatcher) { client.attachmentClose(opened.handle, owner()) }
                handle = null
                _state.update {
                    it.copy(busy = null, staging = null, stagingBytes = 0, notice = "mail_attachment_saved")
                }
            } catch (failure: C06MailFailure) {
                handle?.let { stale ->
                    runCatching { withContext(ioDispatcher) { client.attachmentClose(stale, owner()) } }
                }
                runCatching { withContext(ioDispatcher) { contentResolver.delete(uri, null, null) } }
                fail(failure, busy = null, staging = null, stagingBytes = 0)
            } catch (error: Throwable) {
                handle?.let { stale ->
                    runCatching { withContext(ioDispatcher) { client.attachmentClose(stale, owner()) } }
                }
                fail(C06MailFailure("unknown", "downloadFailed", detail = error.message),
                    busy = null, staging = null, stagingBytes = 0)
            }
        }
    }

    fun cancelActive() {
        scope.launch {
            runCatching { withContext(ioDispatcher) { client.cancel(owner()) } }
        }
    }

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    fun dismissNotice() {
        _state.update {
            it.copy(notice = null, moveNote = null, composeWarning = null, testResult = null)
        }
    }

    /** Called by RuntimeHost before the old Root epoch is retired. */
    suspend fun prepareForRootStop(timeoutMillis: Int): Boolean {
        val epoch = lastEpoch.takeIf { it > 0 } ?: return true
        var drained = true
        // Closing the platform sockets and acknowledging laneClosed unblocks
        // any in-flight bridge call; no separate cancel request is needed and
        // this keeps the root-stop gate inside its bounded window.
        val laneStopped = runCatching {
            withContext(ioDispatcher) { lane.stop(timeoutMillis) }
        }.getOrDefault(false)
        if (!laneStopped) drained = false
        val report = runCatching { withContext(ioDispatcher) { client.rootStop(epoch) } }.getOrNull()
        if (report != null && !report.drained) drained = false
        _state.value = C06MailUiState()
        started.set(false)
        return drained
    }

    fun onRootStopped() {
        // The pre-stop gate already closed and acknowledged the old lane.
        // Do not start another asynchronous stop here: a fast new epoch could
        // otherwise have its mailbox closed by the old generation's callback.
        started.set(false)
        lastEpoch = 0
        _state.value = C06MailUiState()
    }

    private fun loadFolders(accountID: String, resetFolder: Boolean) {
        scope.launch {
            try {
                val folders = withContext(ioDispatcher) { client.folders(accountID, owner()) }
                val selected = if (resetFolder) {
                    folders.firstOrNull { it.name.equals("INBOX", ignoreCase = true) }?.name
                        ?: folders.firstOrNull()?.name
                        ?: "INBOX"
                } else {
                    _state.value.selectedFolder.takeIf { name -> folders.any { it.name == name } }
                        ?: folders.firstOrNull()?.name
                        ?: "INBOX"
                }
                _state.update { it.copy(folders = folders, selectedFolder = selected) }
                loadList(accountID, selected, reset = true)
            } catch (failure: C06MailFailure) {
                fail(failure)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "foldersFailed", detail = error.message))
            }
        }
    }

    private fun loadList(
        accountID: String,
        folder: String,
        reset: Boolean,
        afterUID: Long = 0,
        beforeMessageID: String? = null,
    ) {
        scope.launch {
            _state.update { it.copy(busy = "list", error = null) }
            try {
                val listing = withContext(ioDispatcher) {
                    client.list(
                        accountID = accountID,
                        folder = folder,
                        afterUID = afterUID,
                        limit = 20,
                        beforeMessageID = beforeMessageID,
                        owner = owner(),
                    )
                }
                _state.update { current ->
                    val existing = current.listing
                    current.copy(
                        busy = null,
                        listing = if (!reset && existing != null && existing.folder == folder) {
                            listing.copy(messages = existing.messages + listing.messages)
                        } else {
                            listing
                        },
                    )
                }
            } catch (failure: C06MailFailure) {
                fail(failure, busy = null)
            } catch (error: Throwable) {
                fail(C06MailFailure("unknown", "listFailed", detail = error.message), busy = null)
            }
        }
    }

    private fun owner(): C06MailOwner {
        val epoch = currentNativeEpoch() ?: lastEpoch.takeIf { it > 0 }
            ?: throw C06MailFailure("runtimeNotInstalled", "runtimeNotInstalled", retryable = true)
        return C06MailOwner(token = ownerToken, nativeEpoch = epoch)
    }

    private fun fail(
        failure: C06MailFailure,
        loading: Boolean? = null,
        busy: String? = null,
        staging: String? = null,
        stagingBytes: Long? = null,
    ) {
        _state.update {
            it.copy(
                loading = loading ?: it.loading,
                busy = busy,
                staging = staging ?: it.staging,
                stagingBytes = stagingBytes ?: it.stagingBytes,
                error = failure.code + (failure.reason?.let { reason -> ":" + reason } ?: ""),
            )
        }
    }

    private fun sanitizeFilename(value: String): String {
        val base = value.substringAfterLast('/').substringAfterLast('\\')
            .replace("\u0000", "")
            .replace("\r", "")
            .replace("\n", "")
            .trim()
        val bounded = if (base.isEmpty()) "attachment" else base.take(160)
        return bounded
    }
}
