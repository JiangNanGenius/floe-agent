// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/**
 * Owns the App's explicit acknowledgement of native snapshot-text
 * continuation handles (native `run.snapshot.releaseTextHandles`).
 *
 * The native builder stages the FULL live answer/reasoning text behind a new
 * `chunk:v1:` handle on every snapshot that exceeds the inline budget. The
 * App must therefore:
 *
 *  * retain ONLY the newest handle per (task, run, kind) — the older handle's
 *    bytes are a strict prefix of the newer one and are superseded;
 *  * send every superseded handle back exactly once as
 *    `releaseTextHandles`, so the reader's 32-handle/4 MiB bound cannot
 *    saturate during a long stream;
 *  * NEVER acknowledge the handle the reader is still paging. A snapshot page
 *    with an unchanged handle keeps it retained; a NEW handle (or inline
 *    complete text/terminal proof) retires the previous one.
 *
 * Only opaque handles ever appear here: no text, path or model-authored
 * identity is stored, and the cache is bounded across long App sessions.
 * A release acknowledgement is cleared only after a Completed snapshot page,
 * so a transport failure re-sends it on the next request instead of silently
 * leaking the native bytes.
 */
internal class SnapshotTextHandleRegistry {
    internal data class Ticket(
        val request: HostCommandRequest,
        val generation: Long,
        val key: String?,
        val returned: Set<String>,
        /** Registry issue order, used only when a page carries no
         * `textRevision` (legacy) to reject an out-of-order late page. */
        val order: Long = 0L,
    )

    private class Lease(
        var answer: String? = null,
        var reasoning: String? = null,
    )

    private var epoch = Long.MIN_VALUE

    /** Newest adopted handle per owner/kind. */
    private val retained = LinkedHashMap<String, Lease>()

    /** Handles proven superseded and awaiting the next snapshot request. */
    private val obsolete = LinkedHashMap<String, MutableSet<String>>()

    /** Newest page generation per owner, so an out-of-order late page can
     * never regress the retained handle or resurrect an acked one. */
    private val appliedOrder = LinkedHashMap<String, Long>()
    private val pageRevision = LinkedHashMap<String, Long>()

    private var nextOrder = 0L

    @Synchronized
    fun prepare(request: HostCommandRequest, generation: Long): Ticket {
        if (epoch != generation) {
            retained.clear()
            obsolete.clear()
            appliedOrder.clear()
            pageRevision.clear()
            nextOrder = 0L
            epoch = generation
        }
        val order = ++nextOrder
        val owner = request.scope as? HostScope.TaskExecution
        if (request.command != "run.snapshot" || owner == null ||
            (request.payload?.get("metadataOnly") as? JsonPrimitive)?.booleanOrNull == true
        ) return Ticket(request, generation, null, emptySet(), order)
        val key = owner.taskID.lowercase() + "/" + owner.runID.lowercase()
        val returned = obsolete[key]?.take(MAXIMUM_RELEASE_HANDLES)?.toSet().orEmpty()
        val payload = JsonObject(request.payload.orEmpty() + (
            "releaseTextHandles" to JsonArray(returned.map(::JsonPrimitive))
        ))
        return Ticket(request.copy(payload = payload), generation, key, returned, order)
    }

    @Synchronized
    fun settle(ticket: Ticket, outcome: HostOperationOutcome) {
        if (ticket.generation != epoch) return
        val key = ticket.key ?: return
        val page = (outcome as? HostOperationOutcome.Completed)?.value as? JsonObject ?: return
        val owner = ticket.request.scope as? HostScope.TaskExecution ?: return
        fun text(name: String) = (page[name] as? JsonPrimitive)?.contentOrNull
        if (!owner.taskID.equals(text("conversationID"), ignoreCase = true) ||
            !owner.runID.equals(text("runID"), ignoreCase = true)
        ) return
        // The native builder accepted (or ignored already-released) handles.
        // Clear only exactly what this request acknowledged, even when the
        // PAGE itself is a late/out-of-order read and is discarded below.
        val pending = obsolete[key]
        if (pending != null) {
            pending.removeAll(ticket.returned)
            if (pending.isEmpty()) obsolete.remove(key)
        }
        val revision = (page["textRevision"] as? JsonPrimitive)?.contentOrNull?.toLongOrNull()
        val knownRevision = pageRevision[key]
        val knownOrder = appliedOrder[key]
        val staleByRevision = knownRevision != null && revision != null &&
            revision < knownRevision
        val staleByOrder = knownOrder != null && ticket.order < knownOrder &&
            (revision == null || knownRevision == null || revision <= knownRevision)
        if (staleByRevision || staleByOrder) {
            // A late page can never replace the newest retained handle, but
            // its native blob still exists: acknowledge it when it is not the
            // handle the reader is using (the newest page supersedes it).
            retireStalePage(
                key = key,
                answer = text("answerContinuationHandle"),
                reasoning = text("reasoningContinuationHandle"),
            )
            return
        }
        if (revision != null) {
            pageRevision[key] = maxOf(knownRevision ?: revision, revision)
        }
        if (knownOrder == null || ticket.order > knownOrder) appliedOrder[key] = ticket.order
        val lease = retained.getOrPut(key) { Lease() }
        val terminal = (page["isTerminal"] as? JsonPrimitive)?.booleanOrNull == true
        adopt(
            lease = lease,
            key = key,
            kind = Kind.ANSWER,
            handle = text("answerContinuationHandle"),
            inlinePresent = text("answerText") != null,
            complete = (page["answerComplete"] as? JsonPrimitive)?.booleanOrNull == true,
            terminal = terminal,
        )
        adopt(
            lease = lease,
            key = key,
            kind = Kind.REASONING,
            handle = text("reasoningContinuationHandle"),
            inlinePresent = text("reasoningText") != null,
            complete = (page["reasoningComplete"] as? JsonPrimitive)?.booleanOrNull == true,
            terminal = terminal,
        )
        if (lease.answer == null && lease.reasoning == null) retained.remove(key)
        while (retained.size > MAXIMUM_OWNER_ENTRIES) {
            val oldest = retained.keys.first()
            retained.remove(oldest)
            obsolete.remove(oldest)
            appliedOrder.remove(oldest)
            pageRevision.remove(oldest)
        }
        while (obsolete.size > MAXIMUM_OWNER_ENTRIES) {
            obsolete.remove(obsolete.keys.first())
        }
        while (appliedOrder.size > MAXIMUM_OWNER_ENTRIES) {
            appliedOrder.remove(appliedOrder.keys.first())
        }
        while (pageRevision.size > MAXIMUM_OWNER_ENTRIES) {
            pageRevision.remove(pageRevision.keys.first())
        }
    }

    private fun retireStalePage(key: String, answer: String?, reasoning: String?) {
        val lease = retained[key]
        val answerValid = answer?.takeIf { HANDLE.matches(it) }
        val reasoningValid = reasoning?.takeIf { HANDLE.matches(it) }
        if (answerValid != null && answerValid != lease?.answer) {
            addObsolete(key, answerValid)
        }
        if (reasoningValid != null && reasoningValid != lease?.reasoning) {
            addObsolete(key, reasoningValid)
        }
    }

    private fun addObsolete(key: String, handle: String) {
        val set = obsolete.getOrPut(key) { linkedSetOf() }
        if (set.size >= MAXIMUM_RELEASE_HANDLES) {
            // A single snapshot request acknowledges at most this many. Keep
            // the newest; anything older is left to native run retirement.
            set.remove(set.first())
        }
        set.add(handle)
    }

    private enum class Kind { ANSWER, REASONING }

    private fun adopt(
        lease: Lease,
        key: String,
        kind: Kind,
        handle: String?,
        inlinePresent: Boolean,
        complete: Boolean,
        terminal: Boolean,
    ) {
        val current = if (kind == Kind.ANSWER) lease.answer else lease.reasoning
        val valid = handle?.takeIf { HANDLE.matches(it) }
        when {
            valid != null -> {
                if (current != null && current != valid) markObsolete(key, current, lease, kind)
                if (kind == Kind.ANSWER) lease.answer = valid else lease.reasoning = valid
            }
            // An inline non-null text without a handle is the WHOLE current
            // step (native only stages a handle when the text exceeds the
            // inline budget), so a previously retained handle is stale.
            // Explicit completion/terminal proof retires it too.
            (inlinePresent || complete || terminal) && current != null -> {
                markObsolete(key, current, lease, kind)
            }
            else -> Unit
        }
    }

    private fun markObsolete(key: String, handle: String, lease: Lease, kind: Kind) {
        addObsolete(key, handle)
        if (kind == Kind.ANSWER) {
            if (lease.answer == handle) lease.answer = null
        } else if (lease.reasoning == handle) {
            lease.reasoning = null
        }
    }

    private companion object {
        val HANDLE = Regex("chunk:v1:[0-9a-fA-F]{32}")
        const val MAXIMUM_RELEASE_HANDLES = 32
        const val MAXIMUM_OWNER_ENTRIES = 128
    }
}
