// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import com.floe.android.bridge.DeviceHistoryNative
import com.floe.android.core.devicelink.DeviceHistoryPage
import java.util.UUID
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * App-host client for the frozen v2 device-history native surface declared on
 * `DeviceHistoryNative` (coordinator-owned C++/Swift side). This client owns
 * no JNI symbols of its own; it adds the App-side typing, byte paging, and
 * honest capability gating.
 *
 * Capability discipline: a native library that predates the v2 symbols
 * answers the first probe with LinkageError, which maps every call here to
 * [Result.CapabilityMissing] so the sync host keeps the advertisement
 * disabled instead of promising bytes it cannot serve.
 *
 * Version discipline (coordinator-owned rule): [importPage] binds the commit
 * to the requested archive version — version 2 uses the version-bound native
 * commit (`importVersionCommit`), legacy/text-only receives keep the v1
 * commit, so a peer can neither inject a v2 archive on a text-only receive
 * nor downgrade an opted-in typed-history selection.
 */
internal class AndroidHostBridgeClient {
    sealed interface Result<out T> {
        data class Success<T>(val value: T) : Result<T>
        sealed interface Failure : Result<Nothing>

        /** The installed native library predates the v2 device-sync ABI. */
        data object CapabilityMissing : Failure

        /** Typed native refusal; [status] is the frozen lane status. */
        data class Unavailable(val status: Int, val retryable: Boolean = false) : Failure
    }

    data class PendingAttachment(
        val attachmentID: UUID,
        val messageID: UUID,
        val kind: String,
        val displayName: String,
        val byteCount: Int,
        val digest: String,
    )

    private val v2Probe = lazy {
        try {
            // Symbol-presence probe: epoch 0 answers a typed status when the
            // symbol exists; a missing symbol throws LinkageError.
            DeviceHistoryNative.exportVersionOpen(0, "", 0)
            true
        } catch (missing: LinkageError) {
            false
        }
    }

    /** Whether the installed native library serves the v2 history surface. */
    fun historyV2Available(): Boolean = v2Probe.value

    /** Full archive at [version] (1 legacy text-only, 2 attachments + tools). */
    suspend fun exportHistory(epoch: Long, taskID: UUID, version: Int): Result<ByteArray> =
        readTicket { DeviceHistoryNative.exportVersionOpen(epoch, taskID.toString(), version) }

    /** One bounded page of the versioned canonical archive. */
    suspend fun exportPage(
        epoch: Long, taskID: UUID, after: String?, through: Long?, version: Int,
    ): Result<DeviceHistoryPage> = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        val ticket = DeviceHistoryNative.exportPageVersionOpen(
            epoch, taskID.toString(), cursorBytes(after), through ?: -1L, version,
        )
        if (ticket <= 0) return@withContext failure(ticket.toInt())
        try {
            val reply = ByteArray(PAGE_REPLY_BYTES)
            val copied = DeviceHistoryNative.exportPageInfo(ticket, reply)
            if (copied < 0) return@withContext failure(copied)
            val root = try {
                JSONObject(reply.decodeToString(endIndex = copied, throwOnInvalidSequence = true))
            } catch (_: Exception) {
                return@withContext Result.Unavailable(-899)
            }
            if (root.optInt("ok") != 1 || root.optString("schema") != "floe.device-history.page.v1") {
                return@withContext Result.Unavailable(-899)
            }
            val throughValue = when (val value = root.get("through")) {
                is Int -> value.toLong()
                is Long -> value
                else -> return@withContext Result.Unavailable(-899)
            }
            if (throughValue < 0) return@withContext Result.Unavailable(-899)
            val nextCursor = try {
                optionalCursor(root, "nextCursor")
            } catch (_: Exception) {
                return@withContext Result.Unavailable(-899)
            }
            val hasMore = root.optBoolean("hasMore", false)
            when (val archive = readTicketBytes(ticket)) {
                is Result.Success -> Result.Success(
                    DeviceHistoryPage(archive.value, nextCursor, throughValue, hasMore),
                )
                is Result.Failure -> archive
            }
        } finally {
            runCatching { DeviceHistoryNative.exportClose(ticket) }
        }
    }

    /**
     * Opens one verified attachment byte ticket for an authenticated serving
     * session. The caller owns the ticket: exactly one live ticket per
     * session and attachment, closed on epoch switch, revocation, and every
     * terminal path. Reads go through [attachmentRead]/[attachmentClose].
     */
    suspend fun attachmentOpen(epoch: Long, taskID: UUID, attachmentID: UUID): Result<Long> =
        withContext(Dispatchers.IO) {
            coroutineContext.ensureActive()
            val ticket = DeviceHistoryNative.attachmentOpen(epoch, taskID.toString(), attachmentID.toString())
            if (ticket <= 0) failure(ticket.toInt()) else Result.Success(ticket)
        }

    /** Reads exactly [length] bytes at [offset] from an open attachment ticket. */
    suspend fun attachmentRead(ticket: Long, offset: Long, length: Int): Result<ByteArray> {
        if (offset < 0 || length <= 0 || length > MAX_ARCHIVE) {
            return Result.Unavailable(-105)
        }
        val output = ByteArray(length)
        val page = ByteArray(minOf(length, CHUNK))
        var position = 0
        while (position < length) {
            coroutineContext.ensureActive()
            val wanted = minOf(page.size, length - position)
            val buffer = if (wanted == page.size) page else ByteArray(wanted)
            val read = DeviceHistoryNative.exportRead(ticket, offset + position, buffer)
            if (read < 0) return failure(read)
            if (read == 0 || read > wanted) return Result.Unavailable(-899)
            buffer.copyInto(output, destinationOffset = position, endIndex = read)
            position += read
        }
        return Result.Success(output)
    }

    /** Idempotent close for an attachment ticket. */
    fun attachmentClose(ticket: Long) {
        runCatching { DeviceHistoryNative.exportClose(ticket) }
    }

    /** Verified bytes of one offered attachment (bounded at the lane cap). */
    suspend fun attachmentBytes(epoch: Long, taskID: UUID, attachmentID: UUID): Result<ByteArray> =
        readTicket { DeviceHistoryNative.attachmentOpen(epoch, taskID.toString(), attachmentID.toString()) }

    /** Original user attachments whose bytes are still missing after import. */
    suspend fun pendingAttachments(epoch: Long, taskID: UUID): Result<List<PendingAttachment>> =
        withContext(Dispatchers.IO) {
            coroutineContext.ensureActive()
            val reply = ByteArray(PAGE_REPLY_BYTES)
            val copied = DeviceHistoryNative.attachmentsPending(epoch, taskID.toString(), reply)
            if (copied < 0) return@withContext failure(copied)
            try {
                val root = JSONObject(reply.decodeToString(endIndex = copied, throwOnInvalidSequence = true))
                if (root.optInt("ok") != 1 || root.optString("schema") != "floe.device-history.attachments.v1") {
                    return@withContext Result.Unavailable(-899)
                }
                val array = root.optJSONArray("items") ?: return@withContext Result.Success(emptyList())
                val items = ArrayList<PendingAttachment>(array.length())
                for (index in 0 until array.length()) {
                    val item = array.getJSONObject(index)
                    items.add(
                        PendingAttachment(
                            attachmentID = UUID.fromString(item.getString("attachmentID")),
                            messageID = UUID.fromString(item.getString("messageID")),
                            kind = item.getString("kind"),
                            displayName = item.getString("displayName"),
                            byteCount = item.getInt("byteCount"),
                            digest = item.getString("digest"),
                        ),
                    )
                }
                Result.Success(items)
            } catch (_: Exception) {
                Result.Unavailable(-899)
            }
        }

    /**
     * Stores the verified [bytes] of one pending attachment and binds its
     * message part. Idempotent: a duplicate restore after success is a no-op.
     */
    suspend fun restoreAttachment(
        epoch: Long, taskID: UUID, item: PendingAttachment, bytes: ByteArray,
    ): Result<Boolean> = writeTicket(epoch, taskID, bytes) { ticket ->
        val reply = ByteArray(PAGE_REPLY_BYTES)
        val copied = DeviceHistoryNative.attachmentRestoreCommit(
            ticket, item.attachmentID.toString(), item.messageID.toString(), item.digest, reply,
        )
        if (copied < 0) return@writeTicket failure(copied)
        try {
            val root = JSONObject(reply.decodeToString(endIndex = copied, throwOnInvalidSequence = true))
            if (root.optInt("ok") != 1 || root.optString("schema") != "floe.device-history.restore.v1") {
                return@writeTicket Result.Unavailable(-899)
            }
            Result.Success(root.optInt("restored") == 1)
        } catch (_: Exception) {
            Result.Unavailable(-899)
        }
    }

    /**
     * Commits one imported whole archive with the version binding the
     * selection asked for: [version] 2 uses the version-bound native commit,
     * anything else keeps the legacy commit.
     */
    suspend fun importWhole(
        epoch: Long, taskID: UUID, bytes: ByteArray, version: Int,
    ): Result<Int> = writeTicket(epoch, taskID, bytes) { ticket ->
        val reply = ByteArray(PAGE_REPLY_BYTES)
        val copied = if (version == 2) {
            DeviceHistoryNative.importVersionCommit(ticket, 2, reply)
        } else {
            DeviceHistoryNative.importCommit(ticket, reply)
        }
        if (copied < 0) return@writeTicket failure(copied)
        try {
            val root = JSONObject(reply.decodeToString(endIndex = copied, throwOnInvalidSequence = true))
            if (root.optInt("ok") != 1) return@writeTicket Result.Unavailable(-899)
            val conversation = root.getString("conversationID")
            val added = root.getInt("addedMessages")
            if (!conversation.equals(taskID.toString(), ignoreCase = true) || added < 0) {
                return@writeTicket Result.Unavailable(-899)
            }
            Result.Success(added)
        } catch (_: Exception) {
            Result.Unavailable(-899)
        }
    }

    /**
     * Commits one imported page with the version binding the selection asked
     * for: [version] 2 uses the version-bound native commit, anything else
     * keeps the legacy commit.
     */
    suspend fun importPage(
        epoch: Long, sourcePeerID: String, taskID: UUID, bytes: ByteArray,
        nextCursor: String?, version: Int,
    ): Result<Int> = writeTicket(epoch, taskID, bytes, begin = {
        DeviceHistoryNative.importPageBegin(epoch, taskID.toString(), sourcePeerID, cursorBytes(nextCursor))
    }) { ticket ->
        val reply = ByteArray(PAGE_REPLY_BYTES)
        val copied = if (version == 2) {
            DeviceHistoryNative.importVersionCommit(ticket, 2, reply)
        } else {
            DeviceHistoryNative.importCommit(ticket, reply)
        }
        if (copied < 0) return@writeTicket failure(copied)
        try {
            val root = JSONObject(reply.decodeToString(endIndex = copied, throwOnInvalidSequence = true))
            if (root.optInt("ok") != 1) return@writeTicket Result.Unavailable(-899)
            val conversation = root.getString("conversationID")
            val added = root.getInt("addedMessages")
            if (!conversation.equals(taskID.toString(), ignoreCase = true) || added < 0) {
                return@writeTicket Result.Unavailable(-899)
            }
            Result.Success(added)
        } catch (_: Exception) {
            Result.Unavailable(-899)
        }
    }

    // ------------------------------------------------------------------
    // Ticket plumbing (the frozen 64 KiB page byte discipline)
    // ------------------------------------------------------------------

    private suspend fun readTicket(open: () -> Long): Result<ByteArray> = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        val ticket = open()
        if (ticket <= 0) return@withContext failure(ticket.toInt())
        try {
            readTicketBytes(ticket)
        } finally {
            runCatching { DeviceHistoryNative.exportClose(ticket) }
        }
    }

    private suspend fun readTicketBytes(ticket: Long): Result<ByteArray> {
        val out = java.io.ByteArrayOutputStream()
        val page = ByteArray(CHUNK)
        var offset = 0L
        while (true) {
            coroutineContext.ensureActive()
            val read = DeviceHistoryNative.exportRead(ticket, offset, page)
            if (read < 0) return failure(read)
            if (read == 0) break
            out.write(page, 0, read)
            offset += read
            if (out.size() > MAX_ARCHIVE) return Result.Unavailable(-808)
        }
        return Result.Success(out.toByteArray())
    }

    private suspend fun <T> writeTicket(
        epoch: Long,
        taskID: UUID,
        bytes: ByteArray,
        begin: (() -> Long)? = null,
        commit: (Long) -> Result<T>,
    ): Result<T> = withContext(Dispatchers.IO) {
        if (bytes.size > MAX_ARCHIVE) return@withContext Result.Unavailable(-808)
        coroutineContext.ensureActive()
        val ticket = (begin ?: { DeviceHistoryNative.importBegin(epoch, taskID.toString()) })()
        if (ticket <= 0) return@withContext failure(ticket.toInt())
        try {
            var offset = 0
            while (offset < bytes.size) {
                coroutineContext.ensureActive()
                val length = minOf(CHUNK, bytes.size - offset)
                val written = DeviceHistoryNative.importWrite(ticket, bytes, offset, length)
                if (written < 0) return@withContext failure(written)
                offset += length
            }
            coroutineContext.ensureActive()
            commit(ticket)
        } finally {
            // After a successful commit the session is already retired; abort
            // is idempotent for every other terminal path.
            runCatching { DeviceHistoryNative.importAbort(ticket) }
        }
    }

    private fun failure(status: Int): Result.Failure = when (status) {
        0 -> Result.Unavailable(-899)
        else -> Result.Unavailable(
            status,
            retryable = status == -802 || status == -811 || status == -812 || status == -813,
        )
    }

    private fun cursorBytes(value: String?): ByteArray? =
        value?.encodeToByteArray(throwOnInvalidSequence = true)?.also { require(it.size in 1..CURSOR_BYTES) }

    private fun optionalCursor(root: JSONObject, field: String): String? {
        if (root.isNull(field)) return null
        val cursor = root.get(field) as String
        cursorBytes(cursor)
        return cursor
    }

    private companion object {
        const val CHUNK = 64 * 1024
        const val MAX_ARCHIVE = 32 * 1024 * 1024
        const val PAGE_REPLY_BYTES = 256 * 1024
        const val CURSOR_BYTES = 160
    }
}
