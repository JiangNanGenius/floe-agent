// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import android.content.Context

/**
 * Small platform preference store for scheduled tasks. It holds ONLY the
 * user's explicit per-schedule flexible-scheduling choice and the known
 * schedule ids/notices used to cancel stale OS wakes. It is not a second
 * scheduler database: the durable schedules and occurrence ledger remain in
 * the native `SQLiteTaskScheduleStore`.
 */
internal class TaskScheduleChoiceStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        FILE_NAME, Context.MODE_PRIVATE,
    )

    fun flexibleChosen(scheduleID: String): Boolean =
        preferences.getStringSet(KEY_FLEXIBLE, emptySet())?.contains(scheduleID) == true

    fun setFlexibleChosen(scheduleID: String, chosen: Boolean) {
        val current = preferences.getStringSet(KEY_FLEXIBLE, emptySet())?.toMutableSet()
            ?: mutableSetOf()
        if (chosen) current += scheduleID else current -= scheduleID
        preferences.edit().putStringSet(KEY_FLEXIBLE, current).apply()
    }

    fun knownScheduleIDs(): Set<String> =
        preferences.getStringSet(KEY_KNOWN, emptySet())?.toSet() ?: emptySet()

    fun setKnownScheduleIDs(ids: Set<String>) {
        preferences.edit().putStringSet(KEY_KNOWN, ids.take(200).toSet()).apply()
    }

    fun notice(scheduleID: String): String? = preferences.getString("$KEY_NOTICE$scheduleID", null)

    fun setNotice(scheduleID: String, notice: String?) {
        val editor = preferences.edit()
        if (notice == null) editor.remove("$KEY_NOTICE$scheduleID")
        else editor.putString("$KEY_NOTICE$scheduleID", notice.take(64))
        editor.apply()
    }

    /** All ids that currently carry a transport/waiting notice. */
    fun noticeIDs(): Set<String> =
        preferences.all.keys
            .filter { it.startsWith(KEY_NOTICE) }
            .map { it.removePrefix(KEY_NOTICE) }
            .toSet()

    fun clear() {
        preferences.edit().clear().apply()
    }

    companion object {
        private const val FILE_NAME = "floe.task_schedule.platform"
        private const val KEY_FLEXIBLE = "flexible_chosen"
        private const val KEY_KNOWN = "known_schedule_ids"
        private const val KEY_NOTICE = "notice."
    }
}
