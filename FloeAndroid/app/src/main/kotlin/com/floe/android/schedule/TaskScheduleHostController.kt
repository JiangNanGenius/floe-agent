// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import com.floe.android.host.RuntimeHost
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Whether the REAL runtime environment authority could be read for this
 *  projection. `NotBound` means no App-owned provider was installed (for
 *  example the Play build has no local runtime); `Unavailable` carries the
 *  closed readiness/transport refusal. Neither is ever treated as an empty
 *  authoritative list. */
sealed interface TaskScheduleEnvironmentAvailability {
    data object NotBound : TaskScheduleEnvironmentAvailability
    data object Available : TaskScheduleEnvironmentAvailability
    data class Unavailable(val code: String) : TaskScheduleEnvironmentAvailability
}

data class TaskScheduleUiState(
    val loading: Boolean = false,
    val schedules: List<TaskScheduleSummary> = emptyList(),
    val options: TaskScheduleOptions = TaskScheduleOptions(),
    val errorCode: String? = null,
    val environmentAvailability: TaskScheduleEnvironmentAvailability =
        TaskScheduleEnvironmentAvailability.NotBound,
    /** TRUE durable total; [schedules] may be shorter only when the bounded
     *  walk could not fit every record. */
    val totalSchedules: Int = 0,
    val truncated: Boolean = false,
) {
    /** Environment selection is offered only while the authority list was
     *  actually readable. Cloud/text scheduling is unaffected. */
    val environmentSelectionAvailable: Boolean
        get() = environmentAvailability is TaskScheduleEnvironmentAvailability.Available
}

/**
 * App-scoped schedule projection. Every action goes through the native
 * service (the durable occurrence ledger); this controller only correlates
 * the bounded command reply and refreshes the projection. It never computes
 * a fire time, claims an occurrence or launches an Agent from the UI process.
 */
class TaskScheduleHostController internal constructor(
    private val host: RuntimeHost,
    private val environmentProvider: TaskScheduleEnvironmentProvider? = null,
) {
    private val commands = TaskScheduleCommands(host)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mutable = MutableStateFlow(TaskScheduleUiState(loading = true))
    val state: StateFlow<TaskScheduleUiState> = mutable.asStateFlow()

    fun refresh() {
        scope.launch { refreshNow() }
    }

    suspend fun refreshNow() {
        mutable.value = mutable.value.copy(loading = true, errorCode = null)
        val environment = readEnvironments()
        val environments: List<TaskScheduleEnvironmentChoice>? = when (environment) {
            // An AVAILABLE list (even empty) is authoritative and is
            // registered; an unavailable read passes null so no stale row is
            // presented as current.
            is TaskScheduleEnvironmentResult.Available -> environment.environments
            is TaskScheduleEnvironmentResult.Unavailable -> null
            null -> null
        }
        val optionsResult = commands.options(environments)
        // Bounded page walk: each reply is a whole-record page that fits the
        // bridge frame, and the union still shows every durable schedule.
        val loaded = ArrayList<TaskScheduleSummary>()
        var offset = 0
        var pages = 0
        var total = 0
        var truncated = false
        var listFailure: TaskScheduleResult.Failure? = null
        while (pages < MAX_LIST_PAGES) {
            pages += 1
            when (val page = commands.listPage(limit = LIST_PAGE_SIZE, offset = offset)) {
                is TaskScheduleResult.Ok -> {
                    loaded += page.value.schedules
                    total = page.value.totalCount
                    truncated = truncated || page.value.truncated
                    val next = page.value.nextOffset
                    if (!page.value.hasMore || page.value.schedules.isEmpty() ||
                        next <= offset) break
                    offset = next
                }
                is TaskScheduleResult.Failure -> {
                    listFailure = page
                    break
                }
            }
        }
        truncated = truncated || loaded.size < total
        val options = when (optionsResult) {
            is TaskScheduleResult.Ok -> optionsResult.value
            is TaskScheduleResult.Failure -> mutable.value.options
        }
        val availability = when (environment) {
            null -> TaskScheduleEnvironmentAvailability.NotBound
            is TaskScheduleEnvironmentResult.Available ->
                TaskScheduleEnvironmentAvailability.Available
            is TaskScheduleEnvironmentResult.Unavailable ->
                TaskScheduleEnvironmentAvailability.Unavailable(environment.code)
        }
        mutable.value = if (listFailure == null) {
            TaskScheduleUiState(
                loading = false,
                schedules = loaded,
                options = options,
                errorCode = (optionsResult as? TaskScheduleResult.Failure)?.code,
                environmentAvailability = availability,
                totalSchedules = total,
                truncated = truncated,
            )
        } else {
            mutable.value.copy(
                loading = false,
                options = options,
                errorCode = listFailure?.code ?: "malformed",
                environmentAvailability = availability,
                totalSchedules = total,
                truncated = truncated,
            )
        }
    }

    internal suspend fun detail(id: String): TaskScheduleResult<TaskScheduleDetail> =
        commands.detail(id)

    internal suspend fun history(id: String, limit: Int = 50):
        TaskScheduleResult<TaskScheduleOccurrencePage> = commands.historyPage(id, limit)

    internal suspend fun save(draft: TaskScheduleDraft): TaskScheduleResult<TaskScheduleMutation> {
        // An environment binding is validated against the host's FRESH
        // authority snapshot inside the native service. Register the same
        // snapshot immediately before the mutation so a long editor session
        // cannot freeze a binding against stale metadata.
        if (draft.environmentID != null) {
            when (val fresh = refreshEnvironmentSnapshot()) {
                is TaskScheduleResult.Ok -> Unit
                is TaskScheduleResult.Failure -> return fresh
            }
        }
        val result = if (draft.scheduleID == null) {
            commands.create(draft)
        } else {
            commands.update(draft)
        }
        if (result is TaskScheduleResult.Ok) refreshAfterMutation()
        return result
    }

    internal suspend fun setEnabled(
        summary: TaskScheduleSummary,
        enabled: Boolean,
    ): TaskScheduleResult<TaskScheduleMutation> {
        val result = commands.setEnabled(summary, enabled)
        if (result is TaskScheduleResult.Ok) refreshAfterMutation()
        return result
    }

    internal suspend fun delete(summary: TaskScheduleSummary): TaskScheduleResult<Unit> {
        val result = commands.delete(summary)
        if (result is TaskScheduleResult.Ok) refreshAfterMutation()
        return result
    }

    /**
     * Explicit "run now". The native service records a UNIQUE durable pending
     * occurrence and returns `queued`; it never launches the Agent in the UI
     * process. This controller then hands the SAME occurrence to the existing
     * WorkManager dispatch worker, which holds the real foreground binding.
     * The event-driven observer would also pick it up; enqueueing here is an
     * immediate, duplicate-safe nudge (unique work + native claim CAS).
     */
    internal suspend fun runNow(summary: TaskScheduleSummary):
        TaskScheduleResult<TaskScheduleDispatch> {
        if (summary.environmentID != null) {
            when (val fresh = refreshEnvironmentSnapshot()) {
                is TaskScheduleResult.Ok -> Unit
                is TaskScheduleResult.Failure -> return fresh
            }
        }
        val result = commands.runNow(summary)
        if (result is TaskScheduleResult.Ok) {
            TaskSchedulePlatform.enqueuePendingDispatch(summary.id)
            // Non-blocking projection refresh: the queued notice must reach
            // the user immediately; the worker owns the actual dispatch.
            refresh()
        }
        return result
    }

    fun close() {
        scope.cancel()
    }

    /** A durable mutation is not an armed alarm: re-derive the OS wake
     *  transport. The pass is Application-scoped so closing the editor cannot
     *  cancel it, and it never downgrades exact timing. */
    private suspend fun refreshAfterMutation() {
        TaskSchedulePlatform.requestRearm()
        refreshNow()
    }

    /** Re-registers the exact host-read authority listing right before an
     * environment-aware mutation/dispatch. Missing authority is a typed
     * refusal, never an empty successful snapshot. */
    private suspend fun refreshEnvironmentSnapshot(): TaskScheduleResult<Unit> {
        val provider = environmentProvider
            ?: return TaskScheduleResult.Failure("environmentSnapshotMissing")
        val environments = try {
            when (val result = provider.environments()) {
                is TaskScheduleEnvironmentResult.Available -> result.environments
                is TaskScheduleEnvironmentResult.Unavailable ->
                    return TaskScheduleResult.Failure(result.code)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            return TaskScheduleResult.Failure("environmentUnavailable")
        }
        return when (val options = commands.options(environments)) {
            is TaskScheduleResult.Ok -> TaskScheduleResult.Ok(Unit)
            is TaskScheduleResult.Failure -> options
        }
    }

    private companion object {
        /** Whole-summary pages: worst-case escaped labels still fit the
         *  effect frame with a large margin. */
        const val LIST_PAGE_SIZE = 10
        /** The durable schedule list itself is bounded to 50. */
        const val MAX_LIST_PAGES = 5
    }

    private suspend fun readEnvironments(): TaskScheduleEnvironmentResult? {
        val provider = environmentProvider ?: return null
        return try {
            provider.environments()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            TaskScheduleEnvironmentResult.Unavailable("runtimeUnavailable")
        }
    }
}
