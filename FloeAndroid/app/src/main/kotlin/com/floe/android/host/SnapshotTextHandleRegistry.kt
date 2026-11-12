// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/** Returns only this reader's obsolete immutable text blobs, never another owner's lease. */
internal class SnapshotTextHandleRegistry {
    internal data class Ticket(
        val request: HostCommandRequest,
        val generation: Long,
        val key: String?,
        val returned: Set<String>,
    )

    private var epoch = Long.MIN_VALUE
    private val handles = LinkedHashMap<String, MutableSet<String>>()

    @Synchronized
    fun prepare(request: HostCommandRequest, generation: Long): Ticket {
        if (epoch != generation) {
            handles.clear()
            epoch = generation
        }
        val owner = request.scope as? HostScope.TaskExecution
        if (request.command != "run.snapshot" || owner == null ||
            (request.payload?.get("metadataOnly") as? JsonPrimitive)?.booleanOrNull == true
        ) return Ticket(request, generation, null, emptySet())
        val key = owner.taskID.lowercase() + "/" + owner.runID.lowercase()
        val returned = handles[key]?.take(32)?.toSet().orEmpty()
        val payload = JsonObject(request.payload.orEmpty() + (
            "releaseTextHandles" to JsonArray(returned.map(::JsonPrimitive))
        ))
        return Ticket(request.copy(payload = payload), generation, key, returned)
    }

    @Synchronized
    fun settle(ticket: Ticket, outcome: HostOperationOutcome) {
        if (ticket.generation != epoch || ticket.key == null) return
        val page = (outcome as? HostOperationOutcome.Completed)?.value as? JsonObject ?: return
        val owner = ticket.request.scope as? HostScope.TaskExecution ?: return
        fun text(name: String) = (page[name] as? JsonPrimitive)?.contentOrNull
        if (!owner.taskID.equals(text("conversationID"), ignoreCase = true) ||
            !owner.runID.equals(text("runID"), ignoreCase = true)
        ) return
        val values = handles.getOrPut(ticket.key) { linkedSetOf() }
        values.removeAll(ticket.returned)
        for (name in listOf("answerContinuationHandle", "reasoningContinuationHandle")) {
            text(name)?.takeIf { HANDLE.matches(it) }?.let(values::add)
        }
        if (values.isEmpty()) handles.remove(ticket.key)
        // Native retirement frees finished runs; this contains only opaque
        // acknowledgements, with a bounded cache across long App sessions.
        while (handles.size > 128) handles.remove(handles.keys.first())
    }

    private companion object {
        val HANDLE = Regex("chunk:v1:[0-9a-fA-F]{32}")
    }
}
