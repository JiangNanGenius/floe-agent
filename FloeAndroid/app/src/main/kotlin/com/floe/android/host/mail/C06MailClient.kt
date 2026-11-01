// SPDX-License-Identifier: MPL-2.0
//
// Synchronous trusted-host client for `floe.mail/12`. Every call is made from
// an App-owned controller on an IO dispatcher, never from the main thread.
// Password text is placed into one account-save/test request as base64 and
// immediately dropped; no response ever echoes it.

package com.floe.android.host.mail

import com.floe.android.bridge.SwiftCore
import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

internal fun interface C06MailTransport {
    fun exchange(request: String): String
}

internal object SwiftC06MailTransport : C06MailTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal class C06MailClient(
    private val transport: C06MailTransport = SwiftC06MailTransport,
) {
    fun capabilities(): C06MailCapabilitiesUi =
        parseCapabilities(exchange("c06.capabilities"))

    fun accountList(owner: C06MailOwner): List<C06MailAccountUi> =
        exchange("c06.account.list", owner) { }
            .arrayValue("accounts")
            .mapNotNull { (it as? JsonObject)?.let(::parseAccount) }

    fun accountGet(id: String, owner: C06MailOwner): C06MailAccountUi =
        parseAccount(
            exchange("c06.account.get", owner) { put("accountID", id) }
                .objectValue("account")
                ?: throw C06MailFailure("invalidResponse", "missing_account")
        )

    fun accountSave(draft: C06MailAccountDraft, owner: C06MailOwner): C06MailAccountUi =
        parseAccount(
            exchange("c06.account.save", owner) { put("account", draft.toJson()) }
                .objectValue("account")
                ?: throw C06MailFailure("invalidResponse", "missing_account")
        )

    fun accountDelete(id: String, owner: C06MailOwner): Boolean =
        exchange("c06.account.delete", owner) { put("accountID", id) }.bool("deleted")

    fun accountTest(
        draft: C06MailAccountDraft?,
        accountID: String?,
        owner: C06MailOwner,
    ): C06MailTestUi {
        val response = exchange("c06.account.test", owner) {
            if (draft != null) {
                put("account", draft.toJson())
            } else {
                put("accountID", accountID ?: throw C06MailFailure("invalidRequest", "missing_account"))
            }
        }
        return C06MailTestUi(
            incoming = response.string("incoming") ?: "unknown",
            outgoing = response.string("outgoing") ?: "unknown",
        )
    }

    fun folders(accountID: String, owner: C06MailOwner): List<C06MailFolderUi> =
        exchange("c06.folders", owner) { put("accountID", accountID) }
            .arrayValue("folders")
            .mapNotNull { element ->
                val folder = element as? JsonObject ?: return@mapNotNull null
                C06MailFolderUi(
                    name = folder.string("name") ?: return@mapNotNull null,
                    attributes = folder.arrayValue("attributes").mapNotNull {
                        (it as? JsonPrimitive)?.content
                    },
                )
            }

    fun list(
        accountID: String,
        folder: String,
        afterUID: Long,
        limit: Int,
        beforeMessageID: String?,
        owner: C06MailOwner,
    ): C06MailListingUi =
        parseListing(
            exchange("c06.list", owner) {
                put("accountID", accountID)
                put("folder", folder)
                put("afterUID", afterUID.coerceAtLeast(0))
                put("limit", limit.coerceIn(1, 50))
                beforeMessageID?.let { put("beforeMessageID", it) }
            }
        )

    fun search(
        accountID: String,
        folder: String,
        draft: C06MailSearchDraft,
        cursor: String?,
        limit: Int,
        owner: C06MailOwner,
    ): C06MailSearchPageUi {
        val response = exchange("c06.search", owner) {
            put("accountID", accountID)
            put("folder", folder)
            put("limit", limit.coerceIn(1, 50))
            cursor?.let { put("cursor", it) }
            draft.subject.trim().takeIf { it.isNotEmpty() }?.let { put("subject", it) }
            draft.from.trim().takeIf { it.isNotEmpty() }?.let { put("from", it) }
            draft.to.trim().takeIf { it.isNotEmpty() }?.let { put("to", it) }
            draft.text.trim().takeIf { it.isNotEmpty() }?.let { put("text", it) }
            if (draft.unseenOnly) put("seen", false)
        }
        return parseSearchPage(
            response.objectValue("page")
                ?: throw C06MailFailure("invalidResponse", "missing_page")
        )
    }

    fun message(
        accountID: String,
        folder: String,
        messageID: String,
        mailboxVersion: String?,
        bodyCursor: String?,
        owner: C06MailOwner,
    ): C06MailMessageUi {
        val response = exchange("c06.message", owner) {
            put("accountID", accountID)
            put("folder", folder)
            put("messageID", messageID)
            mailboxVersion?.let { put("mailboxVersion", it) }
            bodyCursor?.let { put("bodyCursor", it) }
        }
        return parseMessage(
            response.objectValue("message")
                ?: throw C06MailFailure("invalidResponse", "missing_message")
        )
    }

    fun attachmentOpen(
        accountID: String,
        folder: String,
        messageID: String,
        mailboxVersion: String?,
        messageSHA256: String,
        attachmentIndex: Int,
        owner: C06MailOwner,
    ): C06MailAttachmentHandleUi {
        val response = exchange("c06.attachment.open", owner) {
            put("accountID", accountID)
            put("folder", folder)
            put("messageID", messageID)
            mailboxVersion?.let { put("mailboxVersion", it) }
            put("messageSHA256", messageSHA256)
            put("attachmentIndex", attachmentIndex)
        }
        return C06MailAttachmentHandleUi(
            handle = response.requiredString("handle"),
            filename = response.string("filename") ?: "attachment",
            byteCount = response.int("byteCount") ?: 0,
            sha256 = response.string("sha256") ?: "",
        )
    }

    fun attachmentRead(
        handle: String,
        offset: Int,
        length: Int,
        owner: C06MailOwner,
    ): C06MailAttachmentChunk {
        val response = exchange("c06.attachment.read", owner) {
            put("handle", handle)
            put("offset", offset)
            put("length", length.coerceIn(1, 24_576))
        }
        val encoded = response.requiredString("dataBase64")
        val data = Base64.getDecoder().decode(encoded)
        return C06MailAttachmentChunk(
            data = data,
            eof = response.bool("eof"),
            byteCount = response.int("byteCount") ?: 0,
        )
    }

    fun attachmentClose(handle: String, owner: C06MailOwner) {
        exchange("c06.attachment.close", owner) { put("handle", handle) }
    }

    fun draftBegin(
        accountID: String,
        filename: String,
        byteCount: Int,
        sha256: String,
        owner: C06MailOwner,
    ): C06MailDraftAttachmentUi {
        val response = exchange("c06.draft.begin", owner) {
            put("accountID", accountID)
            put("filename", filename)
            put("byteCount", byteCount)
            put("sha256", sha256)
        }
        return C06MailDraftAttachmentUi(
            handle = response.requiredString("handle"),
            filename = response.string("filename") ?: filename,
            byteCount = response.int("byteCount") ?: 0,
            sha256 = response.string("sha256") ?: "",
        )
    }

    fun draftWrite(handle: String, offset: Int, data: ByteArray, owner: C06MailOwner) {
        val encoded = Base64.getEncoder().encodeToString(data)
        exchange("c06.draft.write", owner) {
            put("handle", handle)
            put("offset", offset)
            put("dataBase64", encoded)
        }
    }

    fun draftFinish(handle: String, owner: C06MailOwner): C06MailDraftAttachmentUi {
        val response = exchange("c06.draft.finish", owner) { put("handle", handle) }
        return C06MailDraftAttachmentUi(
            handle = response.requiredString("handle"),
            filename = response.string("filename") ?: "attachment",
            byteCount = response.int("byteCount") ?: 0,
            sha256 = response.string("sha256") ?: "",
        )
    }

    fun draftDiscard(handle: String, owner: C06MailOwner) {
        exchange("c06.draft.discard", owner) { put("handle", handle) }
    }

    fun setRead(
        accountID: String,
        messageID: String,
        folder: String,
        mailboxVersion: String,
        read: Boolean,
        owner: C06MailOwner,
    ) {
        exchange("c06.setRead", owner) {
            put("accountID", accountID)
            put("messageID", messageID)
            put("folder", folder)
            put("mailboxVersion", mailboxVersion)
            put("read", read)
        }
    }

    fun move(
        accountID: String,
        requestID: String,
        messageID: String,
        folder: String,
        mailboxVersion: String,
        action: String,
        destination: String?,
        owner: C06MailOwner,
    ): C06MailMoveResultUi =
        parseMove(
            exchange("c06.move", owner) {
                put("accountID", accountID)
                put("requestID", requestID)
                put("messageID", messageID)
                put("folder", folder)
                put("mailboxVersion", mailboxVersion)
                put("action", action)
                destination?.let { put("destination", it) }
            }
        )

    fun send(
        accountID: String,
        requestID: String,
        recipients: List<String>,
        subject: String,
        body: String,
        draftHandles: List<String>,
        owner: C06MailOwner,
    ): C06MailSendResultUi =
        parseSend(
            exchange("c06.send", owner) {
                put("accountID", accountID)
                put("requestID", requestID)
                put("to", buildJsonArray { recipients.forEach { add(JsonPrimitive(it)) } })
                put("subject", subject)
                put("body", body)
                if (draftHandles.isNotEmpty()) {
                    put("draftHandles", buildJsonArray { draftHandles.forEach { add(JsonPrimitive(it)) } })
                }
            }
        )

    fun cancel(owner: C06MailOwner): C06MailCancelUi {
        val response = exchange("c06.cancel", owner) { }
        return C06MailCancelUi(
            cancelledOperations = response.int("cancelledOperations") ?: 0,
            complete = response.bool("complete"),
        )
    }

    fun rootStop(epoch: Long): C06MailRootStopUi {
        val response = exchange("c06.rootStop", null) { put("epoch", epoch) }
        return C06MailRootStopUi(
            drained = response.bool("drained"),
            cancelledOperations = response.int("cancelledOperations") ?: 0,
            removedAttachmentHandles = response.int("removedAttachmentHandles") ?: 0,
            removedDraftHandles = response.int("removedDraftHandles") ?: 0,
        )
    }

    private fun exchange(
        operation: String,
        owner: C06MailOwner? = null,
        body: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {},
    ): JsonObject {
        val request = buildJsonObject {
            put("version", C06_MAIL_VERSION)
            put("operation", operation)
            put("requestID", UUID.randomUUID().toString())
            if (owner != null) {
                put("owner", buildJsonObject {
                    put("token", owner.token)
                    put("nativeEpoch", owner.nativeEpoch)
                    owner.taskID?.let { put("taskID", it) }
                    put("temporary", owner.temporary)
                })
            }
            body()
        }
        val raw = transport.exchange(request.toString())
        val response = try {
            Json.parseToJsonElement(raw).jsonObject
        } catch (_: Throwable) {
            throw C06MailFailure("invalidResponse", "invalid_json")
        }
        if (response["ok"]?.jsonPrimitive?.booleanOrNull != true) {
            throw C06MailFailure(
                code = response.string("code") ?: "unknown",
                reason = response.string("reason"),
                retryable = response.bool("retryable"),
                detail = response.string("detail"),
                stage = response.string("stage"),
            )
        }
        return response
    }
}
