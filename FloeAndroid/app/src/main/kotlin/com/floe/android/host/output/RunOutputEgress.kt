// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import com.floe.android.bridge.RunOutputNative
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

/** Typed status constants of the owned run-output lane (the frozen -7xx
 * band documented on `RunOutputNative` / `RuntimeFacadeRunOutputBridge`). */
internal object RunOutputStatus {
    const val OK = 0
    const val INVALID_ARGUMENTS = -105
    const val BUFFER_TOO_SMALL = -106
    const val NOT_INSTALLED = -701
    const val GENERATION_FENCED = -702
    const val SESSION_UNKNOWN = -703
    const val STATE_CONFLICT = -704
    const val NOT_OWNER = -705
    const val RECEIPT_MISSING = -706
    const val FILE_MISSING = -707
    const val FILE_CHANGED = -708
    const val OVERSIZED = -709
    const val REJECTED = -710
    const val SCAN_TRUNCATED = -711
    const val LEASE_REFUSED = -712
    const val SATURATED = -713
    const val HOP_TIMEOUT = -714
    const val STORE_UNAVAILABLE = -715
    const val INTERNAL = -799
}

/** One sealed run-output descriptor as the native owned reader answered it.
 * EVERY field here is derived from the run's OWN durable toolResult record
 * plus the native availability check — never from model text, markdown, or
 * an artifact metadata blob. Display strings are labels only; identity is
 * (runID, outputID) and all byte access re-enters native by that identity. */
internal data class RunOutputDescriptor(
    val conversationID: String,
    val runID: String,
    val outputID: String,
    val producerCallID: String,
    val producerTool: String,
    val slot: String,
    val displayName: String,
    val mimeType: String,
    val byteCount: Long,
    /** Native cheap-namespace availability: "available" | "missing" |
     * "changed" | "oversized" | "rejected". */
    val availabilityRaw: String,
)

internal sealed class RunOutputListResult {
    data class Ok(
        val items: List<RunOutputDescriptor>,
        val scanTruncated: Boolean,
        val truncatedItems: Boolean,
        val rejectedCount: Int,
    ) : RunOutputListResult()

    /** Typed native refusal (or dynamic absence of the lane). The UI shows
     * an honest unavailable state; success is never fabricated. */
    data class Refused(val status: Int) : RunOutputListResult()
}

/** Native-verified facts of one OPENED owned egress session (post full
 * streamed digest verify; the ticket holds the generation lease). */
internal data class RunOutputEgressInfo(
    val conversationID: String,
    val runID: String,
    val outputID: String,
    val producerCallID: String,
    val producerTool: String,
    val slot: String,
    val displayName: String,
    val mimeType: String,
    val byteCount: Long,
    val sha256: String,
    val relativePath: String,
)

/** Bounded channel abstraction so the stagers/services are unit-testable
 * over the REAL reply grammar with a scripted transport, while production
 * drives the actual JNI object. */
internal interface RunOutputEgressChannel {
    fun list(epoch: Long, conversationID: String, runID: String, reply: ByteArray): Int
    fun open(epoch: Long, conversationID: String, runID: String, outputID: String): Long
    fun info(ticket: Long, reply: ByteArray): Int
    fun read(ticket: Long, offset: Long, target: ByteArray): Int
    fun close(ticket: Long): Int
}

internal object NativeRunOutputChannel : RunOutputEgressChannel {
    override fun list(epoch: Long, conversationID: String, runID: String, reply: ByteArray): Int =
        RunOutputNative.list(epoch, conversationID, runID, reply)

    override fun open(epoch: Long, conversationID: String, runID: String, outputID: String): Long =
        RunOutputNative.open(epoch, conversationID, runID, outputID)

    override fun info(ticket: Long, reply: ByteArray): Int = RunOutputNative.info(ticket, reply)

    override fun read(ticket: Long, offset: Long, target: ByteArray): Int =
        RunOutputNative.read(ticket, offset, target)

    override fun close(ticket: Long): Int = RunOutputNative.close(ticket)
}

/** Strict reply envelope for this lane. Mirrors the reviewed SourceHostReply
 * discipline: LinkageError (the lane is absent in the loaded Core) maps to
 * typed [RunOutputStatus.NOT_INSTALLED], never a success or a silent zero. */
internal class RunOutputReply private constructor(
    val status: Int,
    val body: JsonObject?,
) {
    val ok: Boolean get() = status >= 0 && body?.boolean("ok") == true
    val errorCode: String get() = body?.text("errorCode") ?: ""

    fun text(key: String): String = body?.text(key) ?: ""
    fun number(key: String): Long? = body?.number(key)
    fun boolean(key: String): Boolean? = body?.boolean(key)
    fun rows(key: String): List<JsonObject> = body?.rows(key) ?: emptyList()

    companion object {
        const val REPLY_BYTES = 32 * 1024

        fun call(execute: (ByteArray) -> Int): RunOutputReply {
            val buffer = ByteArray(REPLY_BYTES)
            val status = try { execute(buffer) } catch (_: LinkageError) {
                return RunOutputReply(RunOutputStatus.NOT_INSTALLED, null)
            }
            if (status < 0) return RunOutputReply(status, null)
            val body = runCatching {
                val decoder = Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                val text = decoder.decode(ByteBuffer.wrap(buffer, 0, status)).toString()
                Json.parseToJsonElement(text).jsonObject
            }.getOrNull()
            return if (body == null) RunOutputReply(RunOutputStatus.INTERNAL, null)
            else RunOutputReply(status, body)
        }

        /** Parses one owned-list reply into the typed result; a malformed or
         * shape-violating body is Refused(INTERNAL), never a partial trust. */
        fun list(result: RunOutputReply, expectedConversationID: String,
                 expectedRunID: String): RunOutputListResult {
            if (!result.ok) return RunOutputListResult.Refused(result.status)
            if (result.text("schema") != "floe.run-output.list.v1") {
                return RunOutputListResult.Refused(RunOutputStatus.INTERNAL)
            }
            // The page identity must match what was asked for: a body naming
            // another conversation/run is refused WHOLE (never filtered).
            if (result.text("conversationID") != expectedConversationID ||
                result.text("runID") != expectedRunID) {
                return RunOutputListResult.Refused(RunOutputStatus.INTERNAL)
            }
            val items = result.rows("items").mapNotNull { row ->
                val outputID = row.text("outputID") ?: return@mapNotNull null
                val displayName = row.text("displayName") ?: return@mapNotNull null
                val mimeType = row.text("mimeType") ?: return@mapNotNull null
                val byteCount = row.number("byteCount")?.takeIf { it in 0..MAX_BYTES }
                    ?: return@mapNotNull null
                val availability = row.text("availability") ?: return@mapNotNull null
                if (!HEX64.matches(outputID)) return@mapNotNull null
                RunOutputDescriptor(
                    conversationID = expectedConversationID,
                    runID = expectedRunID,
                    outputID = outputID,
                    producerCallID = row.text("producerCallID").orEmpty(),
                    producerTool = row.text("producerTool").orEmpty(),
                    slot = row.text("slot").orEmpty(),
                    displayName = displayName,
                    mimeType = mimeType,
                    byteCount = byteCount,
                    availabilityRaw = availability,
                )
            }
            return RunOutputListResult.Ok(
                items = items,
                scanTruncated = result.boolean("scanTruncated") == true,
                truncatedItems = result.boolean("truncatedItems") == true,
                rejectedCount = result.number("rejectedCount")?.toInt() ?: 0,
            )
        }

        /** Parses one egress info reply with the FULL canonical identity
         * re-check: every field the consumers trust is validated against
         * the canonical relative-path grammar and the 64-hex digest shape. */
        fun egressInfo(result: RunOutputReply, expectedConversationID: String,
                       expectedRunID: String, expectedOutputID: String): RunOutputEgressInfo? {
            if (!result.ok) return null
            if (result.text("schema") != "floe.run-output.egress.v1") return null
            val info = RunOutputEgressInfo(
                conversationID = result.text("conversationID"),
                runID = result.text("runID"),
                outputID = result.text("outputID"),
                producerCallID = result.text("producerCallID"),
                producerTool = result.text("producerTool"),
                slot = result.text("slot"),
                displayName = result.text("displayName"),
                mimeType = result.text("mimeType"),
                byteCount = result.number("byteCount") ?: -1L,
                sha256 = result.text("sha256"),
                relativePath = result.text("relativePath"),
            )
            if (info.conversationID != expectedConversationID ||
                info.runID != expectedRunID || info.outputID != expectedOutputID) return null
            if (!HEX64.matches(info.sha256) || !HEX64.matches(info.outputID)) return null
            // STRICT trust boundary: the frozen 256MiB per-file egress cap
            // (mirrors Core RunOutputSnapshotStore safeDefault perFileBytes)
            // is enforced HERE — an over-cap claim is NEVER returned as
            // valid/trusted info. Consumers that must answer with a TYPED
            // oversized refusal (the snapshot stager's contentTooLarge) do
            // their own earliest classification on the RAW claim before
            // calling this parser; this gate stays the fail-closed backstop
            // for every other consumer.
            if (info.byteCount !in 1..MAX_BYTES) return null
            // Canonical namespace equality is re-DERIVED here (the same
            // formula the runtime seal uses), never trusted from the reply.
            val canonical = "RunOutputs/${info.runID}/${info.outputID}/${info.displayName}"
            if (info.relativePath != canonical) return null
            if (info.displayName.isEmpty() || info.displayName.startsWith(".") ||
                info.displayName.contains('/') || info.displayName.contains('\\')) return null
            return info
        }

        const val MAX_BYTES = 256L * 1024 * 1024
        private val HEX64 = Regex("[0-9a-f]{64}")
    }
}

private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { !it.isNullOrBlankPrimitive() }?.content
private fun JsonObject.number(key: String): Long? = (this[key] as? JsonPrimitive)?.content?.toLongOrNull()
private fun JsonObject.boolean(key: String): Boolean? = when ((this[key] as? JsonPrimitive)?.content) {
    "true", "1" -> true
    "false", "0" -> false
    else -> null
}
private fun JsonObject.rows(key: String): List<JsonObject> =
    (this[key] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
private fun JsonPrimitive.isNullOrBlankPrimitive(): Boolean = !isString || content.isEmpty()
