// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.UUID
import kotlinx.serialization.json.*

/** Strict, bounded journal-page carrier. Never an executable/live event stream. */
internal object RecordedRunHistory {
    data class Page(val frames: List<HostRunEventFrame>, val hasEarlier: Boolean)

    fun decode(value: JsonElement?, taskID: String, runID: String, before: Long?): Page? = runCatching {
        val root = value as? JsonObject ?: return null
        fun same(key: String, expected: String) =
            UUID.fromString(root[key]!!.jsonPrimitive.content) == UUID.fromString(expected)
        if (!same("taskID", taskID) || !same("runID", runID)) return null
        val events = root["events"] as? JsonArray ?: return null
        if (events.size > 100) return null
        var previous = 0L
        val frames = events.map { item ->
            val row = item.jsonObject
            val sequence = row["sequence"]!!.jsonPrimitive.long
            if (sequence <= previous || (before != null && sequence >= before)) return null
            previous = sequence
            val kind = row["kind"]!!.jsonPrimitive.content
            val payload = Json.parseToJsonElement(row["payload"]!!.jsonPrimitive.content) as? JsonObject
                ?: return null
            HostRunEventFrame(runID = runID, sequence = sequence, kind = kind, payload = payload, bytes = item.toString().toByteArray(Charsets.UTF_8).size)
        }
        val earlier = root["hasEarlier"]!!.jsonPrimitive.boolean
        val first = root["firstSequence"]?.jsonPrimitive?.longOrNull
        if (first != frames.firstOrNull()?.sequence || (earlier && frames.isEmpty())) return null
        Page(frames, earlier)
    }.getOrNull()
}
