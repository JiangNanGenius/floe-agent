// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.calendar

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters

/**
 * Application-owned reminder owner. Installed by the runtime host only after
 * the original store generation is ready. WorkManager retries while the host
 * is still booting; it never fabricates a "shown" state or launches a task.
 */
internal interface TodoReminderPlatform {
    suspend fun deliverReminder(todoID: String, occurrenceKey: String): Boolean
    suspend fun rearmTodos(): Boolean

    companion object {
        @Volatile
        var current: TodoReminderPlatform? = null
    }
}

class TodoReminderDeliverWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val todoID = inputData.getString(KEY_TODO_ID) ?: return Result.failure()
        val occurrence = inputData.getString(KEY_OCCURRENCE) ?: return Result.failure()
        val platform = TodoReminderPlatform.current ?: return retry()
        return if (platform.deliverReminder(todoID, occurrence)) {
            Result.success()
        } else {
            Result.failure()
        }
    }

    private fun retry(): Result =
        if (runAttemptCount >= MAX_ATTEMPTS) Result.failure() else Result.retry()

    companion object {
        const val KEY_TODO_ID = "floe.todo.worker.todoID"
        const val KEY_OCCURRENCE = "floe.todo.worker.occurrence"
        private const val MAX_ATTEMPTS = 6

        fun enqueue(context: Context, todoID: String, occurrence: String) {
            val request = OneTimeWorkRequestBuilder<TodoReminderDeliverWorker>()
                .setInputData(
                    Data.Builder()
                        .putString(KEY_TODO_ID, todoID)
                        .putString(KEY_OCCURRENCE, occurrence)
                        .build(),
                )
                .addTag("floe.todo.reminder.deliver")
                .build()
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                "floe.todo.reminder.deliver.$todoID",
                ExistingWorkPolicy.REPLACE,
                request,
            )
        }
    }
}

class TodoReminderRearmWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val platform = TodoReminderPlatform.current ?: return retry()
        return if (platform.rearmTodos()) Result.success() else Result.retry()
    }

    private fun retry(): Result =
        if (runAttemptCount >= MAX_ATTEMPTS) Result.failure() else Result.retry()

    companion object {
        private const val MAX_ATTEMPTS = 6

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<TodoReminderRearmWorker>()
                .addTag("floe.todo.reminder.rearm")
                .build()
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                "floe.todo.reminder.rearm",
                ExistingWorkPolicy.REPLACE,
                request,
            )
        }
    }
}
