// SPDX-License-Identifier: MPL-2.0
//
// Explicit reminder route seam. A notification carries only the opaque local
// todo id and its revision; the Intent is never authorization. The shell
// navigates to the Calendar destination, and that destination re-reads the
// live todo and selects the exact row. A missing/deleted todo opens the
// Calendar root with an honest notice, never another todo or another task.
//
// C07 can reuse this seam for its own local reminders by submitting the same
// bounded request shape.

package com.floe.android.host.calendar

import android.os.SystemClock
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class C06CalendarRoute(
    val requestID: String,
    val todoID: String,
    val revision: Int,
    val submittedAtElapsedMillis: Long,
)

object C06CalendarNavigation {
    const val ACTION_OPEN_TODO = "com.floe.android.calendar.OPEN_TODO"
    const val EXTRA_TODO_ID = "floe.calendar.extra.todoID"
    const val EXTRA_TODO_REVISION = "floe.calendar.extra.todoRevision"
    private const val MAX_AGE_MILLIS = 120_000L

    private val _pending = MutableStateFlow<C06CalendarRoute?>(null)
    val pending: StateFlow<C06CalendarRoute?> = _pending.asStateFlow()

    /** Returns true only for the explicit same-app action and a UUID todo id. */
    fun submitFromIntent(
        action: String?,
        componentPackage: String?,
        ownPackage: String,
        todoID: String?,
        revision: Int?,
        nowElapsedMillis: Long = SystemClock.elapsedRealtime(),
    ): Boolean {
        if (action != ACTION_OPEN_TODO) return false
        if (componentPackage != null && componentPackage != ownPackage) return false
        val id = todoID?.let { raw -> runCatching { UUID.fromString(raw).toString() }.getOrNull() }
            ?: return false
        _pending.value = C06CalendarRoute(
            requestID = UUID.randomUUID().toString(),
            todoID = id,
            revision = revision?.coerceAtLeast(0) ?: 0,
            submittedAtElapsedMillis = nowElapsedMillis,
        )
        return true
    }

    fun isExpired(route: C06CalendarRoute, nowElapsedMillis: Long = SystemClock.elapsedRealtime()): Boolean =
        nowElapsedMillis - route.submittedAtElapsedMillis > MAX_AGE_MILLIS

    /** The destination consumes the exact request id it rendered. */
    fun consume(requestID: String): C06CalendarRoute? {
        val current = _pending.value
        if (current?.requestID != requestID) return null
        _pending.value = null
        return current
    }

    fun dismiss(requestID: String?) {
        val current = _pending.value ?: return
        if (requestID == null || current.requestID == requestID) {
            _pending.value = null
        }
    }

    fun clearForTesting() {
        _pending.value = null
    }
}
