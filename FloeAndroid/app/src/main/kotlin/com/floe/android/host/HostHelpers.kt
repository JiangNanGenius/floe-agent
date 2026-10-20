// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Per editor-identity+epoch monotonic save-failure sequencer. Both the
 * provider editor and the MCP editor use the exact same finalized contract:
 *  * starts at 0 for a newly opened/reseeded identity;
 *  * +1 exactly once per NEW failed save attempt terminal, even when the
 *    message/outcome is identical to the previous failure (a begin+failure
 *    may coalesce into one composition frame — the sequence, not the text,
 *    identifies the new attempt);
 *  * never advances for polls, recompositions, text changes, clocks or
 *    connection/discovery failures (those are not save attempts);
 *  * never decreases per identity+epoch; presentation metadata only.
 */
class SaveFailureSequencer {
    private val sequences = ConcurrentHashMap<Pair<String, Long>, AtomicLong>()

    fun next(identityId: String, epoch: Long): Long =
        sequences.getOrPut(identityId to epoch) { AtomicLong(0) }.incrementAndGet()

    fun current(identityId: String, epoch: Long): Long =
        sequences[identityId to epoch]?.get() ?: 0L

    fun reset(identityId: String, epoch: Long) {
        sequences.remove(identityId to epoch)
    }
}

/**
 * Canonical attachment.stage payload builder (owner0f handoff). The JSON
 * carries metadata + the app-private staging file name only — never binary
 * content, never a source content:// URI, never an absolute arbitrary path.
 */
/** Typed string field read for untrusted JSON payloads (never throws). */
internal fun JsonObject.string(key: String): String? =
    (this[key] as? kotlinx.serialization.json.JsonPrimitive)
        ?.takeIf { it.isString }
        ?.content

object AttachmentWire {
    fun stagePayload(
        attachmentID: String,
        displayName: String,
        mimeType: String,
        kind: String,
        byteCount: Long,
        sha256: String,
        stagingFile: String,
    ): JsonObject = JsonObject(
        mapOf(
            "attachmentID" to JsonPrimitive(attachmentID),
            "displayName" to JsonPrimitive(displayName),
            "mimeType" to JsonPrimitive(mimeType),
            "kind" to JsonPrimitive(kind),
            "byteCount" to JsonPrimitive(byteCount),
            "sha256" to JsonPrimitive(sha256),
            "stagingFile" to JsonPrimitive(stagingFile),
        ),
    )
}
