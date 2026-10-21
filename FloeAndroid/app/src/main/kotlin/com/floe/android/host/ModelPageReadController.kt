// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/**
 * R — the REUSABLE App-side full-row reader for the REAL
 * `config.models.list` command (job-7d4d4e41017f4391; transport gap
 * MAIN_MODEL_SINGLE_ROW_READ_BUDGET_GAP_20261021.json).
 * (App source only; NOT compiled/executed by this task — Main batches.)
 *
 * It dispatches through the actual `host.trackOperation` /
 * RuntimeHostCommandClient with the SAME frozen command and scope (no
 * direct JNI echo, no alternate service, no new auth grants) and drives
 * the native bounded chunk protocol internally:
 *  * initial:   payload `{providerID?, cursor?, modelRead:{}}`
 *  * continue:  `{providerID?, cursor:<logical row index>,
 *                modelRead:{id, digest, offset}}`
 * It verifies id / provider / row index / offset contiguity / total /
 * SHA-256 read digest / strict UTF-8 on EVERY fragment, preserves the
 * ORIGINAL numeric page metadata, and delivers through [Completed] ONLY a
 * full original logical page document
 * (`{"rows":[<complete original rows>], "nextCursor":…, "hasMore":…}`) —
 * a chunk marker is never presented to a page consumer, and an oversized
 * row is never silently skipped:
 *  * a normal (non-oversized) page passes the real native value through
 *    unchanged;
 *  * a protocol violation, stale identity/digest, gap/replay/out-of-order
 *    offset, carrier overflow or malformed UTF-8 is a typed `Failed` —
 *    never a partial publish.
 *
 * Freshness: every call captures the command generation + native Root
 * epoch BEFORE dispatch plus the supplied consumer [isCurrent] predicate.
 * Stale is dropped/rejected BEFORE dispatch and AFTER callback: no
 * continuation is ever dispatched on cancel/retire, and a late callback
 * cannot touch a newer call ([readPage] retires the previous call, which
 * destroys ONLY its own partial bytes and releases its terminal exactly
 * once as `Superseded`). At most ONE bounded partial row is retained per
 * reader call; no partial row, cache or cross-session publication
 * survives cancel/error/restart. The reader never mutates consumer state:
 * errors leave the consumer's old accepted projection/draft recoverable.
 * All config read scope + the real operation lifecycle stay authoritative.
 */
class ModelPageReadController internal constructor(
    private val host: RuntimeHost,
) {

    /** The most recent call owns the reader. */
    private var active: Call? = null

    /**
     * Reads one logical `config.models.list` page with full-row fidelity.
     * [providerID] / [cursor] keep their EXISTING meaning (the closed
     * filter + composer row-index cursor); [onOutcome] is invoked exactly
     * once with the typed terminal outcome.
     */
    fun readPage(
        providerID: String?,
        cursor: String?,
        correlationTag: String = "mlist",
        isCurrent: () -> Boolean = { true },
        onOutcome: (HostOperationOutcome) -> Unit,
    ) {
        val call = Call(providerID, cursor, correlationTag, isCurrent, onOutcome)
        val previous: Call?
        synchronized(this) {
            previous = active
            active = call
        }
        // Restart fences the older call: its pending terminal (if any)
        // arrives, sees itself retired, destroys its own partial bytes and
        // releases its terminal exactly once. No callback is ever invoked
        // synchronously under this lock.
        previous?.retire()
        call.start()
    }

    private inner class Call(
        private val providerID: String?,
        private val cursor: String?,
        private val correlationTag: String,
        private val isCurrent: () -> Boolean,
        private val onOutcome: (HostOperationOutcome) -> Unit,
    ) {
        // Captured BEFORE dispatch: the original command generation and
        // native Root epoch this read belongs to (a retired root can never
        // publish through a late callback).
        private val startGeneration: Long = host.commandClient.generation()
        private val startRootEpoch: Long? = host.nativeRootEpoch()

        @Volatile
        private var retired = false

        @Volatile
        private var settled = false

        // Reconstruction state for AT MOST ONE bounded partial row.
        private var partial: ByteArray? = null
        private var partialBytes: Int = 0
        private var expectedID: String? = null
        private var expectedDigest: String? = null
        private var expectedTotal: Long = -1L
        private var nextOffset: Long = -1L
        private var logicalCursor: Long = -1L
        private var chunkDispatches = 0

        fun retire() {
            retired = true
        }

        fun start() {
            if (!fresh()) {
                deliver(HostOperationOutcome.Superseded)
                return
            }
            dispatch(beginPayload())
        }

        private fun fresh(): Boolean =
            !retired &&
                host.commandClient.generation() == startGeneration &&
                host.nativeRootEpoch() == startRootEpoch &&
                isCurrent()

        private fun beginPayload(): JsonObject = JsonObject(
            LinkedHashMap<String, JsonElement>().apply {
                providerID?.let { put("providerID", JsonPrimitive(it)) }
                cursor?.let { put("cursor", JsonPrimitive(it)) }
                put("modelRead", JsonObject(emptyMap()))
            },
        )

        private fun continuationPayload(): JsonObject = JsonObject(
            LinkedHashMap<String, JsonElement>().apply {
                providerID?.let { put("providerID", JsonPrimitive(it)) }
                put("cursor", JsonPrimitive(logicalCursor.toString()))
                put(
                    "modelRead",
                    JsonObject(mapOf(
                        "id" to JsonPrimitive(expectedID),
                        "digest" to JsonPrimitive(expectedDigest),
                        "offset" to JsonPrimitive(nextOffset.toString()),
                    )),
                )
            },
        )

        private fun dispatch(payload: JsonObject) {
            host.trackOperation(
                HostCommandRequest(
                    command = "config.models.list",
                    scope = HostScope.ApplicationConfiguration("models"),
                    stateful = false,
                    correlationID = host.commandClient.correlationID(correlationTag),
                    payload = payload,
                ),
            ) { outcome -> handle(outcome) }
        }

        private fun handle(outcome: HostOperationOutcome) {
            if (settled) return
            if (!fresh()) {
                // Stale AFTER callback: reject the late terminal; the
                // consumer's old accepted projection/draft stays untouched.
                deliver(HostOperationOutcome.Superseded)
                return
            }
            when (outcome) {
                is HostOperationOutcome.Completed -> handleCompleted(outcome)
                // Rejected / Failed / Cancelled / Superseded keep their
                // existing typed meaning; deliver destroys the partial.
                else -> deliver(outcome)
            }
        }

        private fun handleCompleted(outcome: HostOperationOutcome.Completed) {
            val page = outcome.value as? JsonObject
                ?: return failTyped("model_read_page_shape")
            val rows = page["rows"] as? JsonArray
                ?: return failTyped("model_read_page_shape")
            val markers = rows.filter { chunkMarkerOf(it) != null }
            if (markers.isEmpty()) {
                // A chunked read cannot turn into a different ordinary
                // page before its exact row has been reconstructed.
                if (partial != null) return failTyped("model_read_sequence")
                if (rows.any { isChunkRow(it) }) {
                    // A malformed marker row is protocol drift, never a
                    // skippable row.
                    return failTyped("model_read_marker_shape")
                }
                // Ordinary page: ORIGINAL rows + ORIGINAL numeric page
                // metadata pass through unchanged.
                deliver(outcome)
                return
            }
            if (markers.size != 1 || rows.size != 1) {
                return failTyped("model_read_page_shape")
            }
            val marker = chunkMarkerOf(markers[0])
                ?: return failTyped("model_read_marker_shape")
            val id = marker.stringMember("id")
                ?: return failTyped("model_read_marker_shape")
            val digest = marker.stringMember("digest")
                ?.takeIf { DIGEST_PATTERN.matches(it) }
                ?: return failTyped("model_read_marker_shape")
            val offset = marker.decimalMember("offset")
                ?: return failTyped("model_read_marker_shape")
            val total = marker.decimalMember("total")
                ?: return failTyped("model_read_marker_shape")
            val text = marker.stringMember("text")
                ?: return failTyped("model_read_marker_shape")
            val next: Long? = when (val raw = marker["next"]) {
                null, is JsonNull -> null
                else -> raw.stringMemberOrNull()?.let { modelReadDecimal(it) }
                    ?: return failTyped("model_read_marker_shape")
            }
            if (partial == null) {
                startReconstruction(page, id, digest, offset, total, text, next)
            } else {
                continueReconstruction(page, outcome, id, digest, offset, total, text, next)
            }
        }

        private fun startReconstruction(
            page: JsonObject,
            id: String,
            digest: String,
            offset: Long,
            total: Long,
            text: String,
            next: Long?,
        ) {
            if (offset != 0L ||
                total <= 0 ||
                total > MAX_RAW_ROW_BYTES ||
                // The first chunk of an over-page row can NEVER be the
                // final chunk (the raw chunk bound is below the page item
                // bound), so EOF here means protocol corruption.
                next == null ||
                next <= offset ||
                next > total
            ) {
                return failTyped("model_read_marker_bounds")
            }
            // Truthful logical page metadata: while the row is incomplete
            // the numeric cursor stays at the row's own index and hasMore
            // is true.
            val metaCursor = page["nextCursor"]?.stringMemberOrNull()?.let { modelReadDecimal(it) }
            val metaHasMore = (page["hasMore"] as? JsonPrimitive)?.booleanOrNull
            if (metaCursor == null || metaCursor < 0 || metaHasMore != true) {
                return failTyped("model_read_page_meta")
            }
            val bytes = text.toByteArray(StandardCharsets.UTF_8)
            if (bytes.size.toLong() != next - offset || next > MAX_RAW_ROW_BYTES) {
                return failTyped("model_read_sequence")
            }
            expectedID = id
            expectedDigest = digest
            expectedTotal = total
            nextOffset = next
            logicalCursor = metaCursor
            partial = bytes
            partialBytes = bytes.size
            chunkDispatches = 1
            dispatch(continuationPayload())
        }

        private fun continueReconstruction(
            page: JsonObject,
            outcome: HostOperationOutcome.Completed,
            id: String,
            digest: String,
            offset: Long,
            total: Long,
            text: String,
            next: Long?,
        ) {
            val acc = partial ?: return failTyped("model_read_state")
            if (id != expectedID || digest != expectedDigest || total != expectedTotal) {
                // A changed/reordered/foreign row: typed refusal; the
                // partially accumulated bytes are destroyed by deliver().
                return failTyped("model_read_stale")
            }
            if (offset != nextOffset || text.isEmpty()) {
                // gap / replay / out-of-order / zero-progress.
                return failTyped("model_read_sequence")
            }
            if (++chunkDispatches > MAX_CHUNK_DISPATCHES) {
                return failTyped("model_read_chain_bound")
            }
            val bytes = text.toByteArray(StandardCharsets.UTF_8)
            val newBytes = partialBytes + bytes.size
            val expectedEnd = next ?: total
            if (offset + bytes.size.toLong() != expectedEnd ||
                newBytes.toLong() > total ||
                newBytes > MAX_RAW_ROW_BYTES
            ) {
                return failTyped("model_read_sequence")
            }
            val copy = acc.copyOf(newBytes)
            bytes.copyInto(copy, partialBytes, 0, bytes.size)
            partial = copy
            partialBytes = newBytes
            if (next != null) {
                nextOffset = next
                dispatch(continuationPayload())
                return
            }
            finalize(page, outcome)
        }

        private fun finalize(
            page: JsonObject,
            outcome: HostOperationOutcome.Completed,
        ) {
            val bytes = partial ?: return failTyped("model_read_state")
            val total = expectedTotal
            val digest = expectedDigest
            val rowID = expectedID
            if (bytes.size.toLong() != total ||
                digest == null || rowID == null ||
                sha256Hex(bytes) != digest
            ) {
                // EOF must carry the EXACT total bytes under the EXACT
                // digest — anything else is a typed refusal with NO
                // publication.
                return failTyped("model_read_digest_mismatch")
            }
            // Strict UTF-8 (REPORT): never a lossy decode, never U+FFFD.
            val decoded = try {
                StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString()
            } catch (_: Exception) {
                return failTyped("model_read_utf8")
            }
            val row = runCatching { Json.parseToJsonElement(decoded) }.getOrNull() as? JsonObject
                ?: return failTyped("model_read_row_parse")
            // The reconstructed row is the ORIGINAL: identity, provider
            // filter, and the native CAS revision member survived intact.
            if (row.stringOrNull("id") != rowID) return failTyped("model_read_row_identity")
            providerID?.let { filter ->
                if (row.stringOrNull("providerID")?.equals(filter, ignoreCase = true) != true) {
                    return failTyped("model_read_row_provider")
                }
            }
            val revision = row["revision"] as? JsonObject
            if (revision == null ||
                revision.stringOrNull("resourceID").isNullOrEmpty() ||
                revision.stringOrNull("version").isNullOrEmpty()
            ) {
                return failTyped("model_read_row_revision")
            }
            // Truthful logical page metadata from the FINAL chunk: the row
            // cursor advanced past this row only now that it is fully
            // reconstructed.
            val finalCursor = page["nextCursor"]?.stringMemberOrNull()?.let { modelReadDecimal(it) }
            val finalHasMore = (page["hasMore"] as? JsonPrimitive)?.booleanOrNull
                ?: return failTyped("model_read_page_meta")
            if (finalHasMore && (finalCursor == null || finalCursor <= logicalCursor)) {
                return failTyped("model_read_page_meta")
            }
            if (!finalHasMore && finalCursor != null) {
                return failTyped("model_read_page_meta")
            }
            val logical = JsonObject(LinkedHashMap<String, JsonElement>().apply {
                put("rows", JsonArray(listOf(row)))
                finalCursor?.let { put("nextCursor", JsonPrimitive(it.toString())) }
                put("hasMore", JsonPrimitive(finalHasMore))
            })
            deliver(HostOperationOutcome.Completed(logical, outcome.detail))
        }

        private fun failTyped(reason: String) {
            deliver(HostOperationOutcome.Failed(reason, reason))
        }

        private fun deliver(outcome: HostOperationOutcome) {
            if (settled) return
            settled = true
            // Destroy ONLY this call's own partial bytes (also on success —
            // the raw carrier buffer is not retained after construction).
            partial = null
            partialBytes = 0
            expectedID = null
            expectedDigest = null
            synchronized(this@ModelPageReadController) {
                if (active === this) active = null
            }
            onOutcome(outcome)
        }
    }

    companion object {
        /** Mirror of the native read carrier bound
         *  (ConfigModelReadLimits.maximumRawRowBytes). Bounded buffer. */
        internal const val MAX_RAW_ROW_BYTES = 65_536

        /** The native chunk bound guarantees at least ~24 KiB of scalar-
         *  safe raw bytes per chunk for a ≤64 KiB carrier; 8 dispatches
         *  covers the maximum legal chain with headroom and bounds
         *  pathological scripts. NOT a budget raise. */
        internal const val MAX_CHUNK_DISPATCHES = 8

        /** Closed marker key (Swift: ConfigModelReadLimits.markerKey). An
         *  ORIGINAL ModelProfile row never carries this member. */
        internal const val CHUNK_KEY = "modelChunk"

        private val DIGEST_PATTERN = Regex("^[0-9a-f]{64}$")

        private fun sha256Hex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }

        internal fun isChunkRow(element: JsonElement): Boolean =
            (element as? JsonObject)?.containsKey(CHUNK_KEY) == true

        internal fun chunkMarkerOf(element: JsonElement): JsonObject? =
            (element as? JsonObject)?.get(CHUNK_KEY) as? JsonObject
    }
}

// File-local strict accessors (top-level: unambiguous receiver scoping).

private val MODEL_READ_DECIMAL_PATTERN = Regex("^(0|[1-9][0-9]{0,5})$")

private fun modelReadDecimal(raw: String): Long? =
    raw.takeIf { MODEL_READ_DECIMAL_PATTERN.matches(it) }?.toLongOrNull()

private fun JsonObject.stringMember(key: String): String? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    return primitive.contentOrNull.takeIf { primitive.isString }
}

private fun JsonElement.stringMemberOrNull(): String? {
    val primitive = this as? JsonPrimitive ?: return null
    return primitive.contentOrNull.takeIf { primitive.isString }
}

private fun JsonObject.decimalMember(key: String): Long? =
    stringMember(key)?.let { modelReadDecimal(it) }

/** Secret-free strict string accessor for reconstructed ORIGINAL rows
 *  (same closed shape the ordinary page rows already decode). */
internal fun JsonObject.stringOrNull(key: String): String? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    return primitive.contentOrNull.takeIf { primitive.isString }
}
