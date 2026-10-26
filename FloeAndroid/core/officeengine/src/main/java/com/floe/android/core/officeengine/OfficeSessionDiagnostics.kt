// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/**
 * Bounded, RAM-only, per-session diagnostic history.
 *
 * Why this exists (R1 device truth, Main 2026-10-26): the final C8 phone
 * PPTX run passed render/rotation/close but still logged two non-fatal
 * `onJsError` startup events whose detail was overwritten by later generic
 * notices, so the real startup evidence was lost. This history keeps those
 * facts alive for the lifetime of the mount, SEPARATE from the transient
 * notice row, and is readable only through the viewer's explicit local
 * "Technical details" action.
 *
 * Hard boundaries (task contract):
 *  - RAM only: never logged to logcat, never persisted to disk, never sent
 *    to any process other than the same-UID viewer/host that explicitly
 *    asked, and never embedded in Activity results or receipts.
 *  - Bounded by entry count AND total detail characters; oldest entries are
 *    evicted first, so a chatty page can never grow this without limit.
 *  - Detail text is truncated and control-character scrubbed; entries carry
 *    no credentials and no full document content by construction (callers
 *    record short facts, and oversize JS error text is cut here as well).
 */
class OfficeSessionDiagnostics(
    private val maxEvents: Int = MAX_EVENTS,
    private val maxTotalDetailChars: Int = MAX_TOTAL_DETAIL_CHARS,
    private val maxDetailChars: Int = MAX_DETAIL_CHARS,
) {
    data class Event(
        val elapsedRealtimeMs: Long,
        val kind: String,
        val detail: String,
    )

    companion object {
        const val MAX_EVENTS = 64
        const val MAX_TOTAL_DETAIL_CHARS = 16 * 1024
        const val MAX_DETAIL_CHARS = 240

        /** Well-known kinds (chrome strings map a subset; the rest stay raw). */
        const val KIND_JS_ERROR = "js-error"
        const val KIND_NOTICE = "notice"
        const val KIND_NATIVE_ERROR = "native-error"
        const val KIND_STATE = "state"
        const val KIND_PERMISSION = "permission"
        const val KIND_SAVE = "save"
        const val KIND_TRANSPORT = "transport"
        const val KIND_LIFECYCLE = "lifecycle"
    }

    private val events = ArrayDeque<Event>()
    private var totalDetailChars = 0

    /** Records one bounded fact. Thread-safe; never throws. */
    @Synchronized
    fun record(elapsedRealtimeMs: Long, kind: String, detail: String?) {
        val scrubbed = scrub(detail)
        val boundedKind = scrubKind(kind)
        while (events.size >= maxEvents) evictOldest()
        while (totalDetailChars + scrubbed.length > maxTotalDetailChars && events.isNotEmpty()) evictOldest()
        events.addLast(Event(elapsedRealtimeMs, boundedKind, scrubbed))
        totalDetailChars += scrubbed.length
    }

    /** Snapshot copy, oldest first (display order). */
    @Synchronized
    fun snapshot(): List<Event> = events.toList()

    @Synchronized
    fun size(): Int = events.size

    private fun evictOldest() {
        val oldest = events.removeFirstOrNull() ?: return
        totalDetailChars -= oldest.detail.length
        if (totalDetailChars < 0) totalDetailChars = 0
    }

    private fun scrubKind(kind: String): String =
        kind.filter { it in 'a'..'z' || it in 'A'..'Z' || it == '-' }.take(32).ifEmpty { "event" }

    private fun scrub(detail: String?): String {
        if (detail.isNullOrEmpty()) return ""
        val cleaned = StringBuilder(detail.length.coerceAtMost(maxDetailChars))
        for (ch in detail) {
            if (cleaned.length >= maxDetailChars) break
            // Drop control characters (including newlines) so one entry can
            // never forge additional lines in the details view.
            if (ch.code >= 0x20 && ch.code != 0x7f) cleaned.append(ch)
        }
        return cleaned.toString()
    }
}
