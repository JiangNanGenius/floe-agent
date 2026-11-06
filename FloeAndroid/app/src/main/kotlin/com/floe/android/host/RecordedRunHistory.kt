// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.UUID
import kotlinx.serialization.json.*

/** Strict, bounded journal-page carrier. Never an executable/live event stream. */
internal object RecordedRunHistory {
    const val maximumPayloadBytes = 4 * 1024 * 1024 // Existing content-reader materialization ceiling.
    data class PayloadReference(val sequence: Long, val kind: String, val totalBytes: Int, val sha256: String)
    data class Page(val frames: List<HostRunEventFrame>, val hasEarlier: Boolean,
        val payloadReference: PayloadReference? = null)
    data class Slice(val bytes: ByteArray, val nextOffset: Int?)

    private fun sameOwner(root: JsonObject, taskID: String, runID: String): Boolean =
        UUID.fromString(root["taskID"]!!.jsonPrimitive.content) == UUID.fromString(taskID) &&
            UUID.fromString(root["runID"]!!.jsonPrimitive.content) == UUID.fromString(runID)

    fun decode(value: JsonElement?, taskID: String, runID: String, before: Long?): Page? = runCatching {
        val root = value as? JsonObject ?: return null
        if (!sameOwner(root, taskID, runID)) return null
        val events = root["events"] as? JsonArray ?: return null
        if (events.size > 100) return null
        var previous = 0L
        var reference: PayloadReference? = null
        val frames = events.mapNotNull { item ->
            val row = item.jsonObject
            val sequence = row["sequence"]!!.jsonPrimitive.long
            if (sequence <= previous || (before != null && sequence >= before)) return null
            previous = sequence
            val kind = row["kind"]!!.jsonPrimitive.content
            val ref = row["payloadReference"]
            if (ref != null && ref != JsonNull) {
                if (events.size != 1 || row["payload"] != JsonNull) return null
                val fields = ref.jsonObject
                val total = fields["totalBytes"]!!.jsonPrimitive.int
                val digest = fields["sha256"]!!.jsonPrimitive.content
                if (fields["sequence"]!!.jsonPrimitive.long != sequence || total !in 1..maximumPayloadBytes ||
                    !digest.matches(Regex("[a-f0-9]{64}"))) return null
                reference = PayloadReference(sequence, kind, total, digest)
                return@mapNotNull null
            }
            val payload = Json.parseToJsonElement(row["payload"]!!.jsonPrimitive.content) as? JsonObject
                ?: return null
            HostRunEventFrame(runID = runID, sequence = sequence, kind = kind, payload = payload, bytes = item.toString().toByteArray(Charsets.UTF_8).size)
        }
        val earlier = root["hasEarlier"]!!.jsonPrimitive.boolean
        val first = root["firstSequence"]?.jsonPrimitive?.longOrNull
        if (first != (reference?.sequence ?: frames.firstOrNull()?.sequence) || (earlier && events.isEmpty())) return null
        Page(frames, earlier, reference)
    }.getOrNull()

    fun decodeSlice(value: JsonElement?, taskID: String, runID: String,
        reference: PayloadReference, offset: Int): Slice? = runCatching {
        val root = value as? JsonObject ?: return null
        if (!sameOwner(root, taskID, runID)) return null
        val row = root["payloadSlice"]!!.jsonObject
        if (row["sequence"]!!.jsonPrimitive.long != reference.sequence ||
            row["kind"]!!.jsonPrimitive.content != reference.kind ||
            row["sha256"]!!.jsonPrimitive.content != reference.sha256 ||
            row["totalBytes"]!!.jsonPrimitive.int != reference.totalBytes ||
            row["offset"]!!.jsonPrimitive.int != offset || offset !in 0 until reference.totalBytes) return null
        val encoded = row["base64"]!!.jsonPrimitive.content
        if (encoded.length > 43_692) return null
        val data = java.util.Base64.getUrlDecoder().decode(encoded)
        if (data.isEmpty() || data.size > 32_768 || data.size > reference.totalBytes - offset) return null
        val end = offset + data.size
        val next = row["nextOffset"]?.takeIf { it != JsonNull }?.jsonPrimitive?.int
        if (next != (if (end < reference.totalBytes) end else null)) return null
        Slice(data, next)
    }.getOrNull()

    fun materialize(runID: String, reference: PayloadReference, bytes: ByteArray): HostRunEventFrame? = runCatching {
        if (bytes.size != reference.totalBytes || bytes.size > maximumPayloadBytes) return null
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        if (digest != reference.sha256) return null
        val text = Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        val payload = Json.parseToJsonElement(text) as? JsonObject ?: return null
        HostRunEventFrame(runID, reference.sequence, reference.kind, payload, bytes.size)
    }.getOrNull()
}
