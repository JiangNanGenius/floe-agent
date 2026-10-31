// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostOperationOutcome
import com.floe.android.host.HostRevision
import com.floe.android.host.HostScope
import com.floe.android.host.RuntimeHost
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/**
 * Typed result of one schedule command. [code] is the closed native error
 * code (to be localized by the UI); [reason] is bounded diagnostic text and
 * must never be presented as raw detail in ordinary product copy.
 */
internal sealed interface TaskScheduleResult<out T> {
    data class Ok<T>(val value: T) : TaskScheduleResult<T>
    data class Failure(val code: String, val reason: String = "") :
        TaskScheduleResult<Nothing>
}

/**
 * Terminal-once delivery for a host command. A caller timeout/cancellation is
 * an OBSERVATION event and must not consume this; only the real host terminal
 * (or a proven pre-submit refusal) is delivered, exactly once, to both the
 * observer and the late resolver. Thread-safe: the host effect pump and the
 * worker coroutine touch it from different threads.
 */
internal class TaskScheduleTerminalSink<T> {
    private val delivered = java.util.concurrent.atomic.AtomicBoolean(false)
    private val deferred =
        kotlinx.coroutines.CompletableDeferred<TaskScheduleResult<T>>()
    private var observer: ((TaskScheduleResult<T>) -> Unit)? = null

    fun observe(block: (TaskScheduleResult<T>) -> Unit) {
        observer = block
    }

    val settled: kotlinx.coroutines.CompletableDeferred<TaskScheduleResult<T>>
        get() = deferred

    /** Returns true only for the first real terminal. */
    fun deliver(result: TaskScheduleResult<T>): Boolean {
        if (!delivered.compareAndSet(false, true)) return false
        runCatching { observer?.invoke(result) }
        deferred.complete(result)
        return true
    }
}

/**
 * Typed answer from the App-owned environment authority read. A failure is
 * NEVER flattened into an empty list: the UI must show environment selection
 * as unavailable, and an environment-bound schedule must fail closed instead
 * of appearing to have no environments.
 */
sealed interface TaskScheduleEnvironmentResult {
    data class Available(
        val environments: List<TaskScheduleEnvironmentChoice>,
    ) : TaskScheduleEnvironmentResult

    /** [code] is a closed transport/readiness token (componentUnavailable,
     *  componentVersionStale, componentIdentityMismatch, rootfsUnverified,
     *  engineProtocolUnsupported, peerUnverified, runtimeUnavailable,
     *  metadataMalformed, superseded). */
    data class Unavailable(val code: String) : TaskScheduleEnvironmentResult
}

/** Host-bound environment authority list. Absent => environment selection is
 * honestly unavailable and a schedule that already binds an environment
 * fails closed at dispatch instead of substituting another environment. */
interface TaskScheduleEnvironmentProvider {
    suspend fun environments(): TaskScheduleEnvironmentResult
}

/**
 * The ONE App-side command client for the schedule surface. It submits only
 * the closed `schedule.*` commands over the existing v3 command/effect
 * channel; all durable semantics stay in the native service.
 */
internal class TaskScheduleCommands(private val host: RuntimeHost) {

    suspend fun listPage(
        limit: Int = 10,
        offset: Int = 0,
    ): TaskScheduleResult<TaskSchedulePage> =
        execute("schedule.list", buildJsonObject {
            put("limit", limit)
            put("offset", offset)
        }) { value ->
            TaskScheduleWire.objectOrNull(value)?.let {
                TaskScheduleWire.page(it, requestedOffset = offset)
            }
        }

    suspend fun detail(id: String): TaskScheduleResult<TaskScheduleDetail> =
        execute("schedule.get", buildJsonObject {
            put("scheduleID", id)
        }) { value ->
            TaskScheduleWire.objectOrNull(value)?.let(TaskScheduleWire::detail)
        }

    suspend fun options(
        environments: List<TaskScheduleEnvironmentChoice>?,
    ): TaskScheduleResult<TaskScheduleOptions> =
        execute("schedule.options", buildJsonObject {
            // null = authority unreadable (omit; the native snapshot keeps
            // its own freshness). An AVAILABLE empty list is registered as
            // an empty authority snapshot so an environment-bound schedule
            // fails closed instead of reusing an older row.
            if (environments != null) {
                put("environments", environmentsJson(environments))
            }
        }) { value ->
            TaskScheduleWire.objectOrNull(value)?.let(TaskScheduleWire::options)
        }

    suspend fun create(draft: TaskScheduleDraft): TaskScheduleResult<TaskScheduleMutation> =
        execute("schedule.create", draftJson(draft), createIntent = true) { value ->
            TaskScheduleWire.objectOrNull(value)?.let(TaskScheduleWire::mutation)
                ?.takeIf { it.summary != null }
        }

    suspend fun update(draft: TaskScheduleDraft): TaskScheduleResult<TaskScheduleMutation> {
        val id = draft.scheduleID ?: return TaskScheduleResult.Failure("invalid_payload")
        val revision = draft.expectedRevision ?: return TaskScheduleResult.Failure("revision_mismatch")
        val payload = draftJson(draft).toMutableMap().apply { put("scheduleID", JsonPrimitive(id)) }
        return execute(
            "schedule.update",
            JsonObject(payload),
            revision = HostRevision("schedule.${id.uppercase()}", revision),
        ) { value ->
            TaskScheduleWire.objectOrNull(value)?.let(TaskScheduleWire::mutation)
                ?.takeIf { it.summary != null }
        }
    }

    suspend fun setEnabled(
        summary: TaskScheduleSummary,
        enabled: Boolean,
    ): TaskScheduleResult<TaskScheduleMutation> = execute(
        if (enabled) "schedule.enable" else "schedule.disable",
        buildJsonObject { put("scheduleID", summary.id) },
        revision = HostRevision("schedule.${summary.id.uppercase()}", summary.revision),
    ) { value ->
        TaskScheduleWire.objectOrNull(value)?.let(TaskScheduleWire::mutation)
    }

    suspend fun delete(summary: TaskScheduleSummary): TaskScheduleResult<Unit> = execute(
        "schedule.delete",
        buildJsonObject { put("scheduleID", summary.id) },
        revision = HostRevision("schedule.${summary.id.uppercase()}", summary.revision),
    ) { value ->
        val obj = TaskScheduleWire.objectOrNull(value)
        if (obj != null && TaskScheduleWire.bool(obj, "accepted") == true) Unit else null
    }

    suspend fun runNow(summary: TaskScheduleSummary): TaskScheduleResult<TaskScheduleDispatch> =
        execute(
            "schedule.runNow",
            buildJsonObject { put("scheduleID", summary.id) },
            revision = HostRevision("schedule.${summary.id.uppercase()}", summary.revision),
        ) { value ->
            TaskScheduleWire.objectOrNull(value)?.let(TaskScheduleWire::dispatch)
                // `runNow` returns a durable QUEUED occurrence; the actual
                // launch belongs to the foreground-admitted dispatch worker.
                ?.takeIf { it.accepted }
        }

    suspend fun historyPage(
        id: String,
        limit: Int = 50,
    ): TaskScheduleResult<TaskScheduleOccurrencePage> = execute(
        "schedule.history",
        buildJsonObject {
            put("scheduleID", id)
            put("limit", limit)
        },
    ) { value ->
        TaskScheduleWire.objectOrNull(value)?.let(TaskScheduleWire::occurrencePage)
    }

    /**
     * Platform wake. [onAccepted] fires when the host queue really accepted
     * the envelope (an operation receipt exists); [onSettled] fires EXACTLY
     * once with the terminal mapping, even when the caller's coroutine is
     * cancelled or the request times out. The dispatch worker uses both to
     * distinguish "never submitted" from "submitted, receipt unknown" before
     * it touches the provisional foreground lease.
     */
    suspend fun dispatch(
        scheduleID: String,
        trigger: String,
        exactAlarmAllowed: Boolean,
        flexibleChosen: Boolean,
        environments: List<TaskScheduleEnvironmentChoice>?,
        onAccepted: (() -> Unit)? = null,
        onSettled: ((TaskScheduleResult<TaskScheduleDispatch>) -> Unit)? = null,
    ): TaskScheduleResult<TaskScheduleDispatch> = execute(
        "schedule.dispatch",
        buildJsonObject {
            put("scheduleID", scheduleID)
            put("trigger", trigger)
            put("exactAlarmAllowed", exactAlarmAllowed)
            put("flexibleChosen", flexibleChosen)
            if (environments != null) {
                put("environments", environmentsJson(environments))
            }
        },
        onAccepted = onAccepted,
        onSettled = onSettled,
    ) { value ->
        TaskScheduleWire.objectOrNull(value)?.let(TaskScheduleWire::dispatch)
    }

    /**
     * Pre-submit Stop: durably cancel the intended pending occurrence through
     * the SAME `schedule.dispatch` command (additive payload, no new command
     * name). The schedule row and its future cadence are untouched.
     */
    suspend fun cancelPending(
        scheduleID: String,
        occurrenceID: String? = null,
    ): TaskScheduleResult<TaskScheduleDispatch> = execute(
        "schedule.dispatch",
        buildJsonObject {
            put("scheduleID", scheduleID)
            put("stopPending", true)
            occurrenceID?.let { put("occurrenceID", it) }
        },
    ) { value ->
        TaskScheduleWire.objectOrNull(value)?.let(TaskScheduleWire::dispatch)
    }

    suspend fun rearm(): TaskScheduleResult<TaskScheduleRearm> = execute(
        "schedule.rearm", buildJsonObject { },
    ) { value ->
        TaskScheduleWire.objectOrNull(value)?.let(TaskScheduleWire::rearm)
    }

    suspend fun dispatchPending(limit: Int = 3): TaskScheduleResult<Int> = execute(
        "schedule.dispatchPending",
        buildJsonObject { put("limit", limit) },
    ) { value ->
        val obj = TaskScheduleWire.objectOrNull(value) ?: return@execute null
        TaskScheduleWire.int(obj, "dispatched") ?: 0
    }

    // -------------------------------------------------------------- internals

    private suspend fun <T> execute(
        command: String,
        payload: JsonObject,
        revision: HostRevision? = null,
        createIntent: Boolean = false,
        onAccepted: (() -> Unit)? = null,
        onSettled: ((TaskScheduleResult<T>) -> Unit)? = null,
        decode: (JsonElement?) -> T?,
    ): TaskScheduleResult<T> {
        // onSettled is the REAL host terminal only (or a proven pre-submit
        // refusal). A caller timeout/cancellation is an OBSERVATION event, not
        // a terminal: the host pump still owns the command and its late
        // terminal must reach the resolver exactly once.
        val terminal = TaskScheduleTerminalSink<T>()
        onSettled?.let(terminal::observe)
        if (host.nativeRootEpoch() == null) {
            // Proven pre-submit refusal: no envelope exists, no terminal is
            // coming.
            val refusal = TaskScheduleResult.Failure("runtime_unavailable")
            terminal.deliver(refusal)
            return refusal
        }
        val outcome = withTimeoutOrNull(REQUEST_TIMEOUT_MILLIS) {
            suspendCancellableCoroutine<HostOperationOutcome> { continuation ->
                val resumed = AtomicBoolean(false)
                host.trackOperation(
                    request = HostCommandRequest(
                        command = command,
                        scope = HostScope.ApplicationConfiguration(CONFIGURATION_SCOPE),
                        stateful = revision != null || createIntent,
                        correlationID = host.commandClient.correlationID("sched"),
                        revision = revision,
                        createIntent = createIntent,
                        payload = payload,
                    ),
                    onAccepted = { _ -> onAccepted?.invoke() },
                ) { result ->
                    terminal.deliver(mapOutcome(result, decode))
                    if (resumed.compareAndSet(false, true)) {
                        // Keep the coroutine result as the RAW terminal so the
                        // caller maps it exactly once.
                        continuation.resume(result)
                    }
                }
                continuation.invokeOnCancellation { resumed.set(true) }
            }
        }
        if (outcome == null) {
            // Timeout is only our observation window closing. The command may
            // still be queued/executing; its REAL terminal will invoke
            // onSettled later via the host pump.
            return TaskScheduleResult.Failure("timeout")
        }
        val mapped = mapOutcome(outcome, decode)
        // Normally the callback already delivered it; this is the single
        // terminal-once guard for a callback/coroutine race.
        terminal.deliver(mapped)
        return mapped
    }

    private fun <T> mapOutcome(
        outcome: HostOperationOutcome,
        decode: (JsonElement?) -> T?,
    ): TaskScheduleResult<T> = when (outcome) {
        is HostOperationOutcome.Completed -> {
            val decoded = try {
                decode(outcome.value)
            } catch (_: Throwable) {
                // A decode failure is an honest "malformed" terminal; it must
                // never propagate out of the host callback thread.
                null
            }
            if (decoded != null) {
                TaskScheduleResult.Ok(decoded)
            } else {
                TaskScheduleResult.Failure("malformed")
            }
        }
        is HostOperationOutcome.Rejected ->
            TaskScheduleResult.Failure(wireCode(outcome.code), outcome.reason)
        is HostOperationOutcome.Failed ->
            TaskScheduleResult.Failure(
                wireCode(outcome.detail["wire"] ?: outcome.code), outcome.reason,
            )
        HostOperationOutcome.Cancelled -> TaskScheduleResult.Failure("cancelled")
        HostOperationOutcome.Superseded -> TaskScheduleResult.Failure("superseded")
    }

    private fun wireCode(raw: String): String = raw.trim()

    private fun draftJson(draft: TaskScheduleDraft): JsonObject = buildJsonObject {
        put("title", draft.title)
        put("prompt", draft.prompt)
        put("cadence", draft.cadence.wire)
        put("scheduledAt", TaskScheduleWire.isoUtc(draft.scheduledAtMillis))
        draft.weekday?.let { put("weekday", it) }
        draft.intervalMinutes?.let { put("intervalSeconds", it * 60) }
        draft.anchorTimezone?.let { put("anchorTimezone", it) }
        draft.upstreamRunID?.let { put("upstreamRunID", it) }
        draft.workspaceID?.let { put("workspaceID", it) }
        draft.modelID?.let { put("modelID", it) }
        draft.environmentID?.let { put("environmentID", it) }
        put("approvalMode", draft.policy.approvalMode)
        put("recoveryPolicy", draft.policy.recoveryPolicy)
        put("notificationPolicy", draft.policy.notificationPolicy)
    }

    private fun environmentsJson(
        environments: List<TaskScheduleEnvironmentChoice>,
    ): JsonArray {
        // Bounded twice: row count AND serialized bytes. The runtime bridge
        // frame budget is 64 KiB for the WHOLE command; staying under 48 KiB
        // for the metadata leaves room for the envelope and never truncates a
        // JSON document mid-row. Callers drop remaining rows (fail closed for
        // those, never coerced).
        val rows = ArrayList<JsonObject>()
        var bytes = 2
        for (environment in environments.take(MAX_ENVIRONMENTS)) {
            val row = buildJsonObject {
                put("id", environment.id)
                put("kind", environment.kind)
                environment.ownerID?.let { put("ownerID", it) }
                put("name", environment.name)
                put("state", environment.state)
                put("requiresRebuild", environment.requiresRebuild)
                environment.executionBackend?.let { put("executionBackend", it) }
                environment.parentID?.let { put("parentID", it) }
            }
            val size = row.toString().toByteArray(Charsets.UTF_8).size + 1
            if (bytes + size > MAX_ENVIRONMENT_PAYLOAD_BYTES) break
            bytes += size
            rows.add(row)
        }
        return JsonArray(rows)
    }

    companion object {
        const val CONFIGURATION_SCOPE = "schedule"
        private const val REQUEST_TIMEOUT_MILLIS = 30_000L
        private const val MAX_ENVIRONMENTS = 100
        private const val MAX_ENVIRONMENT_PAYLOAD_BYTES = 48 * 1024
    }
}
