// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import android.content.Context
import android.os.Build
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ListenableWorker
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters

/**
 * The real dispatch worker. It never runs an Agent loop in Kotlin: it waits
 * for the Application-owned runtime host, asks the native scheduling service
 * to claim/launch the due occurrence through the ordinary run admission, and
 * keeps the existing foreground binding covering the launched run. Claim
 * dedupe lives in the durable occurrence ledger, so duplicate alarms/workers
 * collapse.
 */
class TaskScheduleDispatchWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val scheduleID = inputData.getString(KEY_SCHEDULE_ID)
            ?: return Result.failure()
        val trigger = inputData.getString(KEY_TRIGGER) ?: TRIGGER_EXACT
        val platform = TaskSchedulePlatform.current ?: return Result.retry()
        return platform.dispatchFromWorker(this, scheduleID, trigger)
    }

    companion object {
        const val KEY_SCHEDULE_ID = "floe.schedule.worker.scheduleID"
        const val KEY_TRIGGER = "floe.schedule.worker.trigger"
        const val TRIGGER_EXACT = "exact"
        const val TRIGGER_FLEXIBLE = "flexible"
        const val TRIGGER_MANUAL = "manual"
        const val TRIGGER_PENDING = "pending"

        fun enqueue(context: Context, scheduleID: String, trigger: String) {
            val builder = OneTimeWorkRequestBuilder<TaskScheduleDispatchWorker>()
                .setInputData(
                    Data.Builder()
                        .putString(KEY_SCHEDULE_ID, scheduleID)
                        .putString(KEY_TRIGGER, trigger)
                        .build(),
                )
                .addTag("floe.schedule.dispatch")
            // Expedited work below API 31 runs through WorkManager's own
            // foreground service (it requires getForegroundInfo) and would
            // duplicate the deliberate, alarm-enqueue-only transport. Use
            // the ordinary immediate path there; the exact alarm already
            // woke the process, and the worker acquires the EXISTING Core
            // agent foreground lease before any native claim.
            if (scheduleDispatchUsesExpedited(Build.VERSION.SDK_INT)) {
                builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            }
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                "floe.schedule.dispatch.$scheduleID.$trigger",
                ExistingWorkPolicy.KEEP,
                builder.build(),
            )
        }
    }
}

/**
 * Bounded re-arm pass used after boot, package replacement, clock/timezone
 * changes and an exact-alarm grant change. It arms OS wakes only; it never
 * starts a foreground service or an Agent run at boot.
 */
class TaskScheduleRearmWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val platform = TaskSchedulePlatform.current ?: return Result.retry()
        return platform.rearmFromWorker(this)
    }

    companion object {
        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<TaskScheduleRearmWorker>()
                .addTag("floe.schedule.rearm")
                .build()
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                "floe.schedule.rearm",
                ExistingWorkPolicy.REPLACE,
                request,
            )
        }
    }
}

internal fun ListenableWorker.retryOrFail(
    context: Context,
    scheduleID: String,
    scheduleTitle: String?,
    notice: String,
): ListenableWorker.Result {
    val store = TaskScheduleChoiceStore(context)
    store.setNotice(scheduleID, notice)
    if (runAttemptCount >= MAX_ATTEMPTS) {
        if (scheduleTitle != null) {
            TaskScheduleNotifications.postTransportPending(context, scheduleID, scheduleTitle)
        }
        return ListenableWorker.Result.failure()
    }
    return ListenableWorker.Result.retry()
}

internal const val MAX_ATTEMPTS = 5

/**
 * WorkManager expo here means an expedited JobScheduler job (no foreground
 * service) on API 31+. Below that, expedited work is implemented with
 * WorkManager's own foreground service, which requires `getForegroundInfo`
 * and would add a second, overlapping keep-alive beside the existing Core
 * agent foreground lease. The scheduled-task transport deliberately uses the
 * ordinary immediate worker there instead.
 */
internal fun scheduleDispatchUsesExpedited(sdkInt: Int): Boolean = sdkInt >= 31
