// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * OS wake transport. Exact wall-clock triggers use `setExactAndAllowWhileIdle`
 * only when the user granted `SCHEDULE_EXACT_ALARM`; a flexible (explicitly
 * chosen) schedule uses a unique WorkManager job. A denied exact grant with
 * no flexible choice arms NOTHING and surfaces [TaskScheduleWakeDecision.WaitingPermission]
 * to the UI — no silent degradation.
 */
internal class TaskScheduleAlarmScheduler(context: Context) {

    private val appContext = context.applicationContext
    private val alarmManager = appContext.getSystemService(AlarmManager::class.java)
    private val workManager = WorkManager.getInstance(appContext)
    private val choices = TaskScheduleChoiceStore(appContext)

    fun applyPlans(plans: List<TaskScheduleArmPlan>, exactAlarmAllowed: Boolean) {
        val known = plans.map { it.scheduleID }.toSet()
        val stale = choices.knownScheduleIDs() - known
        stale.forEach { scheduleID ->
            cancel(scheduleID)
            choices.setNotice(scheduleID, null)
            TaskScheduleNotifications.cancel(appContext, scheduleID)
        }
        for (plan in plans) {
            val decision = TaskScheduleWakePolicy.decide(
                enabled = plan.enabled,
                nextFireAtMillis = plan.nextFireAtMillis,
                exactAlarmAllowed = exactAlarmAllowed,
                flexibleChosen = choices.flexibleChosen(plan.scheduleID),
            )
            apply(decision, plan.scheduleID)
        }
        choices.setKnownScheduleIDs(known)
    }

    /** Applies one plan after a dispatch without waiting for a full rearm. */
    fun apply(
        decision: TaskScheduleWakeDecision,
        scheduleID: String,
    ) {
        when (decision) {
            is TaskScheduleWakeDecision.Arm -> {
                if (decision.mode == TaskScheduleWakeMode.EXACT) {
                    cancelFlexible(scheduleID)
                    armExact(scheduleID, decision.triggerAtMillis)
                } else {
                    cancelExact(scheduleID)
                    armFlexible(scheduleID, decision.triggerAtMillis)
                }
            }
            TaskScheduleWakeDecision.WaitingPermission -> {
                cancelExact(scheduleID)
                cancelFlexible(scheduleID)
            }
            TaskScheduleWakeDecision.Cancel -> {
                cancelExact(scheduleID)
                cancelFlexible(scheduleID)
            }
        }
    }

    fun cancel(scheduleID: String) {
        cancelExact(scheduleID)
        cancelFlexible(scheduleID)
    }

    fun armExact(scheduleID: String, triggerAtMillis: Long) {
        val manager = alarmManager ?: return
        if (Build.VERSION.SDK_INT >= 31 && !manager.canScheduleExactAlarms()) return
        val pending = exactPendingIntent(scheduleID) ?: return
        try {
            manager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                maxOf(triggerAtMillis, System.currentTimeMillis()),
                pending,
            )
        } catch (_: SecurityException) {
            // The grant changed between check and call: leave nothing armed.
            manager.cancel(pending)
        }
    }

    fun armFlexible(scheduleID: String, triggerAtMillis: Long) {
        val delay = maxOf(0L, triggerAtMillis - System.currentTimeMillis())
        val request = OneTimeWorkRequestBuilder<TaskScheduleDispatchWorker>()
            .setInitialDelay(delay, TimeUnit.MILLISECONDS)
            .setInputData(
                Data.Builder()
                    .putString(TaskScheduleDispatchWorker.KEY_SCHEDULE_ID, scheduleID)
                    .putString(TaskScheduleDispatchWorker.KEY_TRIGGER,
                        TaskScheduleDispatchWorker.TRIGGER_FLEXIBLE)
                    .build(),
            )
            .addTag(TAG_FLEX)
            .build()
        workManager.enqueueUniqueWork(
            flexibleWorkName(scheduleID), ExistingWorkPolicy.REPLACE, request,
        )
    }

    fun cancelExact(scheduleID: String) {
        val manager = alarmManager ?: return
        exactPendingIntent(scheduleID)?.let { manager.cancel(it) }
    }

    fun cancelFlexible(scheduleID: String) {
        workManager.cancelUniqueWork(flexibleWorkName(scheduleID))
    }

    /**
     * Whether the schedule should be presented as waiting for exact-alarm
     * permission: enabled with a clock wake, no exact grant, no explicit
     * flexible choice.
     */
    fun waitingForPermission(plan: TaskScheduleArmPlan, exactAlarmAllowed: Boolean): Boolean =
        plan.enabled && plan.nextFireAtMillis != null &&
            !exactAlarmAllowed && !choices.flexibleChosen(plan.scheduleID)

    private fun exactPendingIntent(scheduleID: String): PendingIntent? {
        val intent = Intent(appContext, TaskScheduleWakeReceiver::class.java)
            .setAction(TaskScheduleWakeReceiver.ACTION_DISPATCH)
            .setData(Uri.parse("floe://schedule/exact/$scheduleID"))
            .putExtra(TaskScheduleWakeReceiver.EXTRA_SCHEDULE_ID, scheduleID)
            .putExtra(TaskScheduleWakeReceiver.EXTRA_TRIGGER,
                TaskScheduleDispatchWorker.TRIGGER_EXACT)
        return PendingIntent.getBroadcast(
            appContext,
            requestCode(scheduleID),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        private const val TAG_FLEX = "floe.schedule.flexible"

        fun exactAlarmAllowed(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < 31) return true
            val manager = context.getSystemService(AlarmManager::class.java) ?: return false
            return manager.canScheduleExactAlarms()
        }

        fun notificationsUsable(context: Context): Boolean =
            androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()

        fun flexibleWorkName(scheduleID: String): String = "floe.schedule.flex.$scheduleID"

        private fun requestCode(scheduleID: String): Int {
            val digest = MessageDigest.getInstance("SHA-256")
                .digest(scheduleID.toByteArray(Charsets.UTF_8))
            var value = 0
            for (index in 0 until 4) {
                value = (value shl 8) or (digest[index].toInt() and 0xFF)
            }
            return value and 0x7FFFFFFF
        }
    }
}
