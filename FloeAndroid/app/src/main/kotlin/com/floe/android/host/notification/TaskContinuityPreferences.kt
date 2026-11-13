// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notification

import android.content.Context
import java.util.UUID

/**
 * App-private durable presentation facts for the conversation composer.
 *
 * These are PREFERENCES, never authority: the mode only selects the next
 * ordinary send path (the native launch still validates task/provider/tool
 * policy), and the plan acknowledgement only records that the exact
 * `planID:revision` card was already presented. It is not an accept, a Goal
 * grant or a tool permission.
 *
 * A small SharedPreferences record is used because the native bridge exposes
 * no per-conversation composer-preference command and the existing SQLite
 * `app_settings` table is not reachable from the Android host without a new
 * wire command. Both values are written in one editor commit; the record is
 * bounded so historical conversations cannot grow it without limit.
 */
internal data class StoredTaskContinuityPreference(
    val modeRaw: String?,
    val lastPresentedPlanRevision: String?,
)

internal class TaskContinuityPreferences(
    context: Context,
    name: String = "floe.task_continuity.v1",
) {
    private val prefs = context.applicationContext
        .getSharedPreferences(name, Context.MODE_PRIVATE)
    private val lock = Any()

    private fun canonicalConversationID(conversationID: String): String =
        runCatching { UUID.fromString(conversationID).toString() }.getOrDefault(conversationID)

    private fun canonicalRunID(runID: String): String? =
        runCatching { UUID.fromString(runID).toString() }.getOrNull()

    private fun modeKey(id: String) = "mode.$id"
    private fun ackKey(id: String) = "planAck.$id"
    private fun noticeKey(id: String) = "lastNotice.$id"

    fun read(conversationID: String): StoredTaskContinuityPreference {
        val id = canonicalConversationID(conversationID)
        return synchronized(lock) {
            val mode = prefs.getString(modeKey(id), null)
                ?.takeIf { it in VALID_MODES }
            val ack = prefs.getString(ackKey(id), null)
                ?.takeIf(::isValidPlanMarker)
            StoredTaskContinuityPreference(mode, ack)
        }
    }

    /** Atomic mode + acknowledgement write. A failure returns false and the
     * RAM selection stays visible for this session; the next snapshot keeps
     * the same value and retries through the ordinary save path. */
    fun write(
        conversationID: String,
        modeRaw: String,
        lastPresentedPlanRevision: String?,
    ): Boolean {
        if (modeRaw !in VALID_MODES) return false
        val ack = lastPresentedPlanRevision?.takeIf(::isValidPlanMarker)
        val id = canonicalConversationID(conversationID)
        synchronized(lock) {
            pruneLocked()
            val editor = prefs.edit().putString(modeKey(id), modeRaw)
            if (ack == null) editor.remove(ackKey(id)) else editor.putString(ackKey(id), ack)
            return runCatching { editor.commit() }.getOrDefault(false)
        }
    }

    /** The last RESULT notice (failure, suspension, waiting or completion)
     * this task displayed. Used only to withdraw a superseded notice when the
     * same run resumes or a new invocation starts; never an ownership fact. */
    fun lastNotifiedRun(conversationID: String): String? = synchronized(lock) {
        prefs.getString(noticeKey(canonicalConversationID(conversationID)), null)
            ?.let(::canonicalRunID)
    }

    fun recordNotifiedRun(conversationID: String, runID: String) {
        val canonicalRun = canonicalRunID(runID) ?: return
        val id = canonicalConversationID(conversationID)
        synchronized(lock) {
            pruneLocked()
            prefs.edit().putString(noticeKey(id), canonicalRun).commit()
        }
    }

    fun clearNotifiedRun(conversationID: String, runID: String) {
        val canonicalRun = canonicalRunID(runID) ?: return
        val id = canonicalConversationID(conversationID)
        synchronized(lock) {
            if (prefs.getString(noticeKey(id), null) == canonicalRun) {
                prefs.edit().remove(noticeKey(id)).commit()
            }
        }
    }

    /** Bounded bookkeeping: at most 512 conversations retain a preference
     * row. When the bound is exceeded, arbitrary excess keys are dropped
     * (the legacy Agent default is the safe fallback); unbounded growth is
     * never allowed. */
    private fun pruneLocked() {
        val keys = prefs.all.keys
        val ids = keys.mapNotNull { key ->
            val dot = key.indexOf('.')
            if (dot <= 0) null else key.substring(dot + 1)
        }.toSet()
        if (ids.size <= MAX_CONVERSATIONS) return
        val editor = prefs.edit()
        val drop = ids.size - MAX_CONVERSATIONS
        var removed = 0
        for (id in ids) {
            if (removed >= drop) break
            editor.remove(modeKey(id))
            editor.remove(ackKey(id))
            editor.remove(noticeKey(id))
            removed++
        }
        editor.commit()
    }

    private fun isValidPlanMarker(value: String): Boolean {
        val separator = value.lastIndexOf(':')
        if (separator <= 0 || separator == value.lastIndex) return false
        val id = value.substring(0, separator)
        val revision = value.substring(separator + 1).toIntOrNull() ?: return false
        if (revision < 1) return false
        return runCatching { UUID.fromString(id) }.isSuccess
    }

    companion object {
        private val VALID_MODES = setOf("agent", "chat", "plan", "goal")
        private const val MAX_CONVERSATIONS = 512
    }
}
