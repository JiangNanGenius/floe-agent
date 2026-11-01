// SPDX-License-Identifier: MPL-2.0
//
// Non-secret C06 mail values parsed from `floe.mail/12`. Password text is
// accepted only from the account editor, is put into the one bridge request
// as base64, and is never stored in a model, log or saved state.

package com.floe.android.host.mail

import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

internal const val C06_MAIL_VERSION = 12

internal data class C06MailOwner(
    val token: String,
    val nativeEpoch: Long,
    val taskID: String? = null,
    val temporary: Boolean = false,
)

internal class C06MailFailure(
    val code: String,
    val reason: String? = null,
    val retryable: Boolean = false,
    val detail: String? = null,
    val stage: String? = null,
) : Exception(code)

internal data class C06MailCapabilitiesUi(
    val coreReady: Boolean,
    val epoch: Long?,
    val credentialGatewayReady: Boolean,
    val schemaReady: Boolean,
    val transportReady: Boolean,
    val accountCount: Int,
    val maximumAccounts: Int,
    val maximumMessageBytes: Int,
    val maximumAttachmentBytes: Int,
    val maximumChunkBytes: Int,
    val modelTools: Boolean,
)

internal data class C06MailServerUi(
    val host: String,
    val port: Int,
    val tls: String,
    val username: String,
)

internal data class C06MailAccountUi(
    val id: String,
    val displayName: String,
    val address: String,
    val incomingProtocol: String,
    val incoming: C06MailServerUi,
    val outgoing: C06MailServerUi,
    val revision: Int,
    val updatedAt: String,
)

internal data class C06MailFolderUi(
    val name: String,
    val attributes: List<String>,
)

internal data class C06MailRowUi(
    val id: String,
    val byteCount: Int,
    val flags: List<String>,
)

internal data class C06MailListingUi(
    val folder: String,
    val mailboxVersion: String?,
    val messages: List<C06MailRowUi>,
    val hasMore: Boolean,
    val nextBeforeMessageID: String?,
)

internal data class C06MailAttachmentUi(
    val index: Int,
    val filename: String,
    val byteCount: Int,
    val sha256: String,
)

internal data class C06MailMessageUi(
    val subject: String,
    val from: String,
    val to: String,
    val date: String,
    val text: String,
    val html: String,
    val sha256: String,
    val attachments: List<C06MailAttachmentUi>,
    val hasMoreText: Boolean,
    val hasMoreHtml: Boolean,
    val nextTextCursor: String?,
    val nextHtmlCursor: String?,
    val truncated: Boolean,
)

internal data class C06MailSearchPageUi(
    val folder: String,
    val mailboxVersion: String,
    val messages: List<C06MailRowUi>,
    val hasMore: Boolean,
    val nextCursor: String?,
    val totalMatched: Int,
    val returned: Int,
    val pageTruncated: Boolean,
)

internal data class C06MailAttachmentHandleUi(
    val handle: String,
    val filename: String,
    val byteCount: Int,
    val sha256: String,
)

internal data class C06MailAttachmentChunk(
    val data: ByteArray,
    val eof: Boolean,
    val byteCount: Int,
)

internal data class C06MailDraftAttachmentUi(
    val handle: String,
    val filename: String,
    val byteCount: Int,
    val sha256: String,
)

internal data class C06MailTestUi(
    val incoming: String,
    val outgoing: String,
)

internal data class C06MailMoveResultUi(
    val status: String,
    val requestID: String,
    val messageID: String,
    val sourceFolder: String,
    val destination: String?,
    val destinationUID: String?,
    val destinationMailboxVersion: String?,
    val expunged: String,
    val destinationVerified: Boolean,
    val replayed: Boolean,
    val reconciled: Boolean,
    val receiptPersisted: Boolean,
    val reason: String?,
    val warning: String?,
)

internal data class C06MailCancelUi(
    val cancelledOperations: Int,
    val complete: Boolean,
)

internal data class C06MailRootStopUi(
    val drained: Boolean,
    val cancelledOperations: Int,
    val removedAttachmentHandles: Int,
    val removedDraftHandles: Int,
)

internal data class C06MailSendResultUi(
    val status: String,
    val requestID: String,
    val replayed: Boolean,
    val receiptPersisted: Boolean,
    val warning: String?,
)

internal data class C06MailAccountDraft(
    val id: String?,
    val displayName: String,
    val address: String,
    val incomingProtocol: String,
    val incoming: C06MailServerUi,
    val outgoing: C06MailServerUi,
    var incomingSecret: String,
    var outgoingSecret: String,
) {
    fun toJson(): JsonObject = JsonObject(
        buildMap<String, JsonElement> {
            id?.let { put("id", JsonPrimitive(it)) }
            put("displayName", JsonPrimitive(displayName.trim()))
            put("address", JsonPrimitive(address.trim()))
            put("incomingProtocol", JsonPrimitive(incomingProtocol))
            put("incoming", serverJson(incoming))
            put("outgoing", serverJson(outgoing))
            if (incomingSecret.isNotEmpty()) {
                put("incomingSecretBase64", JsonPrimitive(base64(incomingSecret)))
            }
            if (outgoingSecret.isNotEmpty()) {
                put("outgoingSecretBase64", JsonPrimitive(base64(outgoingSecret)))
            }
        }
    )

    private fun serverJson(server: C06MailServerUi): JsonObject = JsonObject(
        mapOf(
            "host" to JsonPrimitive(server.host.trim()),
            "port" to JsonPrimitive(server.port),
            "tls" to JsonPrimitive(server.tls),
            "username" to JsonPrimitive(server.username.trim()),
        )
    )

    private fun base64(value: String): String =
        java.util.Base64.getEncoder().encodeToString(value.toByteArray(Charsets.UTF_8))
}

internal data class C06MailComposeDraft(
    val accountID: String,
    val requestID: String = UUID.randomUUID().toString(),
    val recipients: String,
    val subject: String,
    val body: String,
    val attachments: List<C06MailDraftAttachmentUi> = emptyList(),
) {
    val recipientList: List<String>
        get() = recipients.split(',', ';')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
}

internal data class C06MailSearchDraft(
    val subject: String = "",
    val from: String = "",
    val to: String = "",
    val text: String = "",
    val unseenOnly: Boolean = false,
)

// MARK: - JSON readers

internal fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull

internal fun JsonObject.requiredString(key: String): String =
    string(key) ?: throw C06MailFailure("invalidResponse", "missing_$key")

internal fun JsonObject.int(key: String): Int? =
    (this[key] as? JsonPrimitive)?.intOrNull

internal fun JsonObject.long(key: String): Long? =
    (this[key] as? JsonPrimitive)?.longOrNull

internal fun JsonObject.bool(key: String): Boolean =
    (this[key] as? JsonPrimitive)?.booleanOrNull ?: false

internal fun JsonObject.nullableString(key: String): String? {
    val value = this[key]
    return if (value == null || value is JsonNull) null else (value as? JsonPrimitive)?.contentOrNull
}

internal fun JsonObject.objectValue(key: String): JsonObject? =
    this[key] as? JsonObject

internal fun JsonObject.arrayValue(key: String): List<JsonElement> =
    (this[key] as? JsonArray) ?: emptyList()

internal fun parseCapabilities(object: JsonObject): C06MailCapabilitiesUi =
    C06MailCapabilitiesUi(
        coreReady = object.bool("coreReady"),
        epoch = object.long("epoch"),
        credentialGatewayReady = object.bool("credentialGatewayReady"),
        schemaReady = object.bool("schemaReady"),
        transportReady = object.bool("transportReady"),
        accountCount = object.int("accountCount") ?: 0,
        maximumAccounts = object.int("maximumAccounts") ?: 0,
        maximumMessageBytes = object.int("maximumMessageBytes") ?: 0,
        maximumAttachmentBytes = object.int("maximumAttachmentBytes") ?: 0,
        maximumChunkBytes = object.int("maximumChunkBytes") ?: 0,
        modelTools = object.bool("modelTools"),
    )

internal fun parseServer(object: JsonObject): C06MailServerUi =
    C06MailServerUi(
        host = object.requiredString("host"),
        port = object.int("port") ?: throw C06MailFailure("invalidResponse", "missing_port"),
        tls = object.requiredString("tls"),
        username = object.requiredString("username"),
    )

internal fun parseAccount(object: JsonObject): C06MailAccountUi =
    C06MailAccountUi(
        id = object.requiredString("id"),
        displayName = object.requiredString("displayName"),
        address = object.requiredString("address"),
        incomingProtocol = object.requiredString("incomingProtocol"),
        incoming = parseServer(object.objectValue("incoming")
            ?: throw C06MailFailure("invalidResponse", "missing_incoming")),
        outgoing = parseServer(object.objectValue("outgoing")
            ?: throw C06MailFailure("invalidResponse", "missing_outgoing")),
        revision = object.int("revision") ?: 0,
        updatedAt = object.string("updatedAt") ?: "",
    )

internal fun parseRow(object: JsonObject): C06MailRowUi =
    C06MailRowUi(
        id = object.requiredString("id"),
        byteCount = object.int("byteCount") ?: 0,
        flags = object.arrayValue("flags").mapNotNull {
            (it as? JsonPrimitive)?.contentOrNull
        },
    )

internal fun parseListing(object: JsonObject): C06MailListingUi =
    C06MailListingUi(
        folder = object.requiredString("folder"),
        mailboxVersion = object.nullableString("mailboxVersion"),
        messages = object.arrayValue("messages").mapNotNull { (it as? JsonObject)?.let(::parseRow) },
        hasMore = object.bool("hasMore"),
        nextBeforeMessageID = object.nullableString("nextBeforeMessageID"),
    )

internal fun parseMessage(object: JsonObject): C06MailMessageUi =
    C06MailMessageUi(
        subject = object.string("subject") ?: "",
        from = object.string("from") ?: "",
        to = object.string("to") ?: "",
        date = object.string("date") ?: "",
        text = object.string("text") ?: "",
        html = object.string("html") ?: "",
        sha256 = object.string("sha256") ?: "",
        attachments = object.arrayValue("attachments").mapNotNull { element ->
            val attachment = element as? JsonObject ?: return@mapNotNull null
            val index = attachment.int("index") ?: return@mapNotNull null
            C06MailAttachmentUi(
                index = index,
                filename = attachment.string("filename") ?: "attachment",
                byteCount = attachment.int("byteCount") ?: 0,
                sha256 = attachment.string("sha256") ?: "",
            )
        },
        hasMoreText = object.bool("hasMoreText"),
        hasMoreHtml = object.bool("hasMoreHtml"),
        nextTextCursor = object.string("nextTextCursor")?.takeIf { it.isNotEmpty() },
        nextHtmlCursor = object.string("nextHtmlCursor")?.takeIf { it.isNotEmpty() },
        truncated = object.bool("truncated"),
    )

internal fun parseSearchPage(object: JsonObject): C06MailSearchPageUi =
    C06MailSearchPageUi(
        folder = object.requiredString("folder"),
        mailboxVersion = object.string("mailboxVersion") ?: "",
        messages = object.arrayValue("messages").mapNotNull { (it as? JsonObject)?.let(::parseRow) },
        hasMore = object.bool("hasMore"),
        nextCursor = object.string("nextCursor")?.takeIf { it.isNotEmpty() },
        totalMatched = object.int("totalMatched") ?: 0,
        returned = object.int("returned") ?: 0,
        pageTruncated = object.bool("pageTruncated"),
    )

internal fun parseMove(object: JsonObject): C06MailMoveResultUi =
    C06MailMoveResultUi(
        status = object.requiredString("status"),
        requestID = object.requiredString("requestID"),
        messageID = object.string("messageID") ?: "",
        sourceFolder = object.string("sourceFolder") ?: "",
        destination = object.nullableString("destination"),
        destinationUID = object.nullableString("destinationUID"),
        destinationMailboxVersion = object.nullableString("destinationMailboxVersion"),
        expunged = object.string("expunged") ?: "notAttempted",
        destinationVerified = object.bool("destinationVerified"),
        replayed = object.bool("replayed"),
        reconciled = object.bool("reconciled"),
        receiptPersisted = object.bool("receiptPersisted"),
        reason = object.string("reason"),
        warning = object.string("warning"),
    )

internal fun parseSend(object: JsonObject): C06MailSendResultUi =
    C06MailSendResultUi(
        status = object.requiredString("status"),
        requestID = object.requiredString("requestID"),
        replayed = object.bool("replayed"),
        receiptPersisted = object.bool("receiptPersisted"),
        warning = object.string("warning"),
    )
