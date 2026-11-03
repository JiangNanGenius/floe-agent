// SPDX-License-Identifier: MPL-2.0
//
// C06 mail presentation values. These carry no credential bodies: the account
// editor keeps passwords only in local state for the single save/test call.

package com.floe.android.feature.mail

data class MailAccountRow(
    val id: String,
    val displayName: String,
    val address: String,
    val incomingProtocol: String,
    val incomingHost: String,
    val incomingPort: Int,
    val incomingTls: String,
    val incomingUser: String,
    val outgoingHost: String,
    val outgoingPort: Int,
    val outgoingTls: String,
    val outgoingUser: String,
    val revision: Int,
)

data class MailFolderRow(
    val name: String,
    val attributes: List<String>,
) {
    fun specialLabel(): String? {
        val upper = attributes.map { it.uppercase() }
        return when {
            upper.any { it == "\\ARCHIVE" } -> "Archive"
            upper.any { it == "\\TRASH" } -> "Trash"
            upper.any { it == "\\SENT" } -> "Sent"
            upper.any { it == "\\DRAFTS" } -> "Drafts"
            upper.any { it == "\\JUNK" } -> "Junk"
            else -> null
        }
    }
}

data class MailRow(
    val id: String,
    val byteCount: Int,
    val flags: List<String>,
) {
    val seen: Boolean get() = flags.any { it.equals("\\Seen", ignoreCase = true) }
    val flagged: Boolean get() = flags.any { it.equals("\\Flagged", ignoreCase = true) }
}

data class MailAttachmentRow(
    val index: Int,
    val filename: String,
    val byteCount: Int,
    val sha256: String,
)

data class MailMessageView(
    val subject: String,
    val from: String,
    val to: String,
    val date: String,
    val text: String,
    val html: String,
    val sha256: String,
    val attachments: List<MailAttachmentRow>,
    val hasMoreText: Boolean,
    val hasMoreHtml: Boolean,
)

data class MailDraftAttachmentRow(
    val handle: String,
    val filename: String,
    val byteCount: Int,
    val sha256: String,
)

data class MailComposeView(
    val accountID: String,
    val recipients: String,
    val subject: String,
    val body: String,
    val attachments: List<MailDraftAttachmentRow>,
    val locked: Boolean,
    val warning: String?,
)

data class MailSearchView(
    val folder: String,
    val rows: List<MailRow>,
    val hasMore: Boolean,
    val totalMatched: Int,
    val cursorAvailable: Boolean,
)

data class MailScreenState(
    val loading: Boolean = false,
    val busy: String? = null,
    val coreReady: Boolean = true,
    val schemaReady: Boolean = true,
    val transportReady: Boolean = true,
    val credentialReady: Boolean = true,
    val accounts: List<MailAccountRow> = emptyList(),
    val selectedAccountID: String? = null,
    val folders: List<MailFolderRow> = emptyList(),
    val selectedFolder: String = "INBOX",
    val rows: List<MailRow> = emptyList(),
    val mailboxVersion: String? = null,
    val hasMore: Boolean = false,
    val message: MailMessageView? = null,
    val messageRow: MailRow? = null,
    val search: MailSearchView? = null,
    val compose: MailComposeView? = null,
    val testResult: String? = null,
    val moveNote: String? = null,
    val staging: String? = null,
    val stagingBytes: Long = 0,
    val notice: String? = null,
    val error: String? = null,
) {
    val selectedAccount: MailAccountRow?
        get() = accounts.firstOrNull { it.id == selectedAccountID }
}

data class MailAccountDraftUi(
    val id: String?,
    val displayName: String,
    val address: String,
    val incomingProtocol: String,
    val incomingHost: String,
    val incomingPort: Int,
    val incomingTls: String,
    val incomingUser: String,
    val incomingSecret: String,
    val outgoingHost: String,
    val outgoingPort: Int,
    val outgoingTls: String,
    val outgoingUser: String,
    val outgoingSecret: String,
)

data class MailSearchDraftUi(
    val subject: String = "",
    val from: String = "",
    val to: String = "",
    val text: String = "",
    val unseenOnly: Boolean = false,
)
