// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import java.io.ByteArrayOutputStream
import java.util.UUID
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Typed rejection raised by the device-history JNI adapter. Only the numeric
 * contract status is retained — archive bytes, titles, conversation ids and
 * paths NEVER enter the message.
 *
 * Status space (mirrors `DeviceHistoryBridgeFacade`; additive and disjoint
 * from gateway -1xx, runtime-owner -2xx, attachment -3xx, skills-folder -4xx,
 * source-host -5xx, network-workspace -6xx and run-output -7xx):
 *   0 ok; -105 shape; -106 buffer too small;
 *   -801 notInstalled; -802 generationFenced; -803 sessionUnknown;
 *   -804 stateConflict; -805 conversationUnavailable; -806 conflict;
 *   -807 invalidArchive; -808 tooLarge; -809 identityMismatch; -810 busy;
 *   -811 hopTimeout; -812 storeUnavailable; -813 saturated;
 *   -814 outcomeUnknown (admitted writer unresolved — reconcile by reading,
 *       NEVER auto-retry on this status alone); -899 internal.
 */
class DeviceHistoryNativeException(val status: Int) :
    IllegalStateException("device_history_status_$status")

/**
 * Trusted App entry for the device-history lane: the App lists shareable
 * ordinary conversations (offers), exports the portable v1 bytes of one
 * offered conversation, and explicitly imports verified peer bytes through
 * the SAME native conversation database. Not a V3 command, never
 * model-reachable; the App calls this only from its own settings/host
 * surfaces with the ACCEPTED native root epoch.
 *
 * Byte discipline: archive payloads reach 32 MiB while the generic bridge
 * page is 64 KiB, so bytes cross ONLY as <= 64 KiB chunks over opaque
 * tickets inside [exportHistory]/[importHistory]. Callers never hand paths,
 * URIs, file descriptors or store handles to native; the store is resolved
 * from the live generation's own durable bundle and fenced by [epoch].
 *
 * Cancellation is cooperative: chunk loops check the coroutine between
 * chunks and always release their ticket on exit (export [exportClose] /
 * import [importAbort]).
 */
object DeviceHistoryNative {
    init { System.loadLibrary("floe_jni") }

    // ------------------------------------------------------------------
    // Raw JNI ABI (the ONE binary channel; Kotlin JNI only)
    // ------------------------------------------------------------------

    /** Bounded offer page JSON into [reply]; >=0 copied length, <0 status. */
    external fun offers(epoch: Long, reply: ByteArray): Int

    /** Positive opaque ticket, <0 typed status. */
    external fun exportOpen(epoch: Long, conversationID: String): Long

    /** Copy <= 64 KiB at [offset] into [target]; >=0 copied, 0 EOF, <0 status. */
    external fun exportRead(ticket: Long, offset: Long, target: ByteArray): Int

    /** Idempotent close; MUST be called on every terminal export path. */
    external fun exportClose(ticket: Long): Int

    /** Positive opaque ticket, <0 typed status. */
    external fun importBegin(epoch: Long, expectedConversationID: String): Long

    /** Append one <= 64 KiB chunk; 0 ok, <0 typed status. */
    external fun importWrite(ticket: Long, data: ByteArray, offset: Int, length: Int): Int

    /** Typed receipt JSON into [reply]; >=0 copied length, <0 typed status. */
    external fun importCommit(ticket: Long, reply: ByteArray): Int

    /** Idempotent abort + byte discard; MUST be called when not committing. */
    external fun importAbort(ticket: Long): Int

    /** Typed counters JSON only (no titles, bytes or identities). */
    external fun stats(reply: ByteArray): Int

    // ------------------------------------------------------------------
    // Typed App-facing API (suspend, bounded, cooperative-cancel)
    // ------------------------------------------------------------------

    data class DeviceHistoryOffer(val id: String, val title: String)

    data class DeviceHistoryImportReceipt(
        val conversationID: String,
        val addedMessages: Int,
        val createdConversation: Boolean,
    )

    /**
     * Displayable, data-free result taxonomy. `Unavailable` keeps the typed
     * status and whether an immediate retry is meaningful; it never carries
     * archive data.
     */
    sealed interface DeviceHistoryResult<out T> {
        data class Success<T>(val value: T) : DeviceHistoryResult<T>
        /** Same-id message exists with different content; nothing imported. */
        data object Conflict : DeviceHistoryResult<Nothing>
        /** The conversation has an active durable run; retry later. */
        data object Busy : DeviceHistoryResult<Nothing>
        /**
         * The import was admitted into the durable writer but its outcome
         * did not resolve in time. The writer is UNRESOLVED: reconcile by
         * reading (offers/exports are idempotent; re-import is
         * append-if-absent). NEVER auto-retry on this status alone.
         */
        data object OutcomeUnknown : DeviceHistoryResult<Nothing>
        data class Unavailable(val status: Int, val retryable: Boolean) :
            DeviceHistoryResult<Nothing>
    }

    private const val CHUNK = 64 * 1024
    private const val MAX_ARCHIVE = 32 * 1024 * 1024
    private const val OFFERS_REPLY_BYTES = 256 * 1024

    /**
     * Shareable ordinary conversations for the fenced [epoch]. The native
     * call carries its own bounded store deadline and answers the truthful
     * typed status; the coroutine only checks cancellation before calling.
     */
    suspend fun localOffers(
        epoch: Long,
    ): DeviceHistoryResult<List<DeviceHistoryOffer>> = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        val reply = ByteArray(OFFERS_REPLY_BYTES)
        val copied = offers(epoch, reply)
        if (copied < 0) return@withContext mapFailure(copied)
        parseOffers(reply.copyOfRange(0, copied))
    }

    /**
     * Portable v1 archive bytes of one offered conversation. Cancellation is
     * cooperative between chunks; [exportClose] runs on every terminal path.
     */
    suspend fun exportHistory(
        epoch: Long,
        taskID: String,
    ): DeviceHistoryResult<ByteArray> = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        val ticket = exportOpen(epoch, taskID)
        if (ticket < 0) return@withContext mapFailure(ticket.toInt())
        try {
            val out = ByteArrayOutputStream()
            val page = ByteArray(CHUNK)
            var offset = 0L
            while (true) {
                coroutineContext.ensureActive()
                val read = exportRead(ticket, offset, page)
                if (read < 0) return@withContext mapFailure(read)
                if (read == 0) break
                out.write(page, 0, read)
                offset += read
                if (out.size() > MAX_ARCHIVE) {
                    return@withContext DeviceHistoryResult.Unavailable(-808, retryable = false)
                }
            }
            DeviceHistoryResult.Success(out.toByteArray())
        } finally {
            exportClose(ticket)
        }
    }

    /**
     * Explicit import of verified peer bytes for the App-selected
     * conversation. Idempotent append-if-absent: a safe re-import after
     * `OutcomeUnknown` adds nothing. [importCommit] blocks on the native
     * bounded deadline and answers the truthful receipt or -814; an admitted
     * uncertainty is NEVER re-mapped to -811, and cancellation is checked
     * before commit (an already-admitted native commit still completes and
     * its late truth stays recorded natively).
     */
    suspend fun importHistory(
        epoch: Long,
        expectedTaskID: String,
        bytes: ByteArray,
    ): DeviceHistoryResult<DeviceHistoryImportReceipt> = withContext(Dispatchers.IO) {
        if (bytes.size > MAX_ARCHIVE) {
            return@withContext DeviceHistoryResult.Unavailable(-808, retryable = false)
        }
        coroutineContext.ensureActive()
        val ticket = importBegin(epoch, expectedTaskID)
        if (ticket < 0) return@withContext mapFailure(ticket.toInt())
        try {
            var offset = 0
            while (offset < bytes.size) {
                coroutineContext.ensureActive()
                val length = minOf(CHUNK, bytes.size - offset)
                val written = importWrite(ticket, bytes, offset, length)
                if (written < 0) return@withContext mapFailure(written)
                offset += length
            }
            coroutineContext.ensureActive()
            val reply = ByteArray(4096)
            val copied = importCommit(ticket, reply)
            if (copied < 0) return@withContext mapFailure(copied)
            parseReceipt(reply.copyOfRange(0, copied))
        } finally {
            // After a successful commit the session is already retired;
            // abort is idempotent for every other terminal path.
            importAbort(ticket)
        }
    }

    // ------------------------------------------------------------------
    // Mapping helpers (status -> typed result; JSON -> typed values)
    // ------------------------------------------------------------------

    private fun mapFailure(status: Int): DeviceHistoryResult<Nothing> = when (status) {
        -806 -> DeviceHistoryResult.Conflict
        -810 -> DeviceHistoryResult.Busy
        -814 -> DeviceHistoryResult.OutcomeUnknown
        -802, -811, -812, -813 -> DeviceHistoryResult.Unavailable(status, retryable = true)
        else -> DeviceHistoryResult.Unavailable(status, retryable = false)
    }

    private fun parseOffers(body: ByteArray): DeviceHistoryResult<List<DeviceHistoryOffer>> {
        return try {
            val root = JSONObject(String(body, Charsets.UTF_8))
            if (root.optInt("ok") != 1) {
                return DeviceHistoryResult.Unavailable(-899, retryable = false)
            }
            val array = root.optJSONArray("offers") ?: return DeviceHistoryResult.Success(emptyList())
            val offers = ArrayList<DeviceHistoryOffer>(array.length())
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                offers.add(
                    DeviceHistoryOffer(
                        id = item.getString("id"),
                        title = item.getString("title"),
                    )
                )
            }
            DeviceHistoryResult.Success(offers)
        } catch (failure: Exception) {
            DeviceHistoryResult.Unavailable(-899, retryable = false)
        }
    }

    private fun parseReceipt(
        body: ByteArray,
    ): DeviceHistoryResult<DeviceHistoryImportReceipt> {
        return try {
            val root = JSONObject(String(body, Charsets.UTF_8))
            if (root.optInt("ok") != 1) {
                return DeviceHistoryResult.Unavailable(-899, retryable = false)
            }
            DeviceHistoryResult.Success(
                DeviceHistoryImportReceipt(
                    conversationID = root.getString("conversationID"),
                    addedMessages = root.getInt("addedMessages"),
                    createdConversation = root.optInt("createdConversation") == 1,
                )
            )
        } catch (failure: Exception) {
            DeviceHistoryResult.Unavailable(-899, retryable = false)
        }
    }

    /** Lint-friendly reference for hosts that validate ids before calling. */
    fun isCanonicalTaskID(value: String): Boolean =
        try {
            UUID.fromString(value).toString().equals(value, ignoreCase = true)
        } catch (failure: IllegalArgumentException) {
            false
        }
}
