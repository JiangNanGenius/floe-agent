// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * G07.3B presentation/wire model for scheduled Agent tasks.
 *
 * The DURABLE authority is the native `SQLiteTaskScheduleStore` occurrence
 * ledger; this file only decodes the bounded command replies and carries UI
 * drafts. No scheduling rule (next fire time, coalescing, claim, recovery) is
 * reimplemented here: the native planner returns every wake time.
 */
enum class TaskScheduleCadence(val wire: String) {
    ONCE("once"),
    DAILY("daily"),
    WEEKLY("weekly"),
    INTERVAL("interval"),
    AFTER_SUCCESS("afterSuccess");

    companion object {
        fun fromWire(value: String?): TaskScheduleCadence? =
            entries.firstOrNull { it.wire == value }
    }
}

data class TaskSchedulePolicyBinding(
    val approvalMode: String = "ask",
    val recoveryPolicy: String = "safePoint",
    val notificationPolicy: String = "stages",
)

data class TaskScheduleOccurrence(
    val id: String,
    val state: String,
    val scheduledForMillis: Long?,
    val startedAtMillis: Long?,
    val finishedAtMillis: Long?,
    val runID: String?,
    val conversationID: String?,
    val summary: String?,
    val errorText: String?,
) {
    val isTerminal: Boolean
        get() = state in setOf("completed", "failed", "cancelled", "skipped", "interrupted")
}

data class TaskScheduleSummary(
    val id: String,
    val title: String,
    val promptPreview: String,
    val cadence: TaskScheduleCadence,
    val enabled: Boolean,
    val scheduledAtMillis: Long?,
    val weekday: Int?,
    val intervalSeconds: Int?,
    val anchorTimezone: String?,
    val nextFireAtMillis: Long?,
    val lastStartedAtMillis: Long?,
    val modelID: String?,
    val modelName: String?,
    val environmentID: String?,
    val environmentName: String?,
    val workspaceID: String?,
    val workspaceName: String?,
    val policy: TaskSchedulePolicyBinding,
    val upstreamRunID: String?,
    val revision: String,
    val lastOccurrence: TaskScheduleOccurrence?,
    val needsAttention: Boolean,
)

data class TaskScheduleDetail(
    val summary: TaskScheduleSummary,
    val prompt: String,
    val createdAtMillis: Long?,
    val updatedAtMillis: Long?,
)

data class TaskScheduleWorkspaceChoice(val id: String, val name: String)
data class TaskScheduleModelChoice(
    val id: String,
    val providerID: String,
    val displayName: String,
    val providerName: String,
)
/**
 * One authority environment row as the host read it from the runtime
 * `environment.list` operation. The native ownership gate re-validates the
 * project owner/state/backend; the UI only shows [name].
 */
data class TaskScheduleEnvironmentChoice(
    val id: String,
    val name: String,
    val kind: String = "project",
    val ownerID: String? = null,
    val state: String = "active",
    val requiresRebuild: Boolean = false,
    val executionBackend: String? = null,
    val parentID: String? = null,
)

data class TaskScheduleOptions(
    val workspaces: List<TaskScheduleWorkspaceChoice> = emptyList(),
    val models: List<TaskScheduleModelChoice> = emptyList(),
    val environments: List<TaskScheduleEnvironmentChoice> = emptyList(),
    /** Real top-level runs the after-success trigger can follow, projected by
     * the native service from the SAME durable run store it already owns.
     * Empty is honest (no live run); the editor never invents a choice. */
    val runChoices: List<TaskScheduleRunChoice> = emptyList(),
    val defaultModelID: String? = null,
    val currentTimezone: String? = null,
    val environmentSelectionAvailable: Boolean = false,
    /** True when the native encoder had to omit whole option rows to keep
     * the reply inside the bounded bridge frame. `counts` stays truthful, so
     * the UI can say that some options are not shown instead of pretending
     * the shortened list is complete. */
    val truncated: Boolean = false,
)

/** One bounded page of the durable schedule list. The UI walks pages until
 * [hasMore] is false so every schedule (not just the first frame) is shown. */
data class TaskSchedulePage(
    val schedules: List<TaskScheduleSummary>,
    val totalCount: Int,
    val offset: Int,
    val nextOffset: Int,
    val hasMore: Boolean,
    val truncated: Boolean,
)

/** One bounded page of occurrence history. */
data class TaskScheduleOccurrencePage(
    val occurrences: List<TaskScheduleOccurrence>,
    val totalCount: Int,
    val truncated: Boolean,
)

data class TaskScheduleMutation(
    val summary: TaskScheduleSummary?,
    val revision: String?,
)

data class TaskScheduleDispatch(
    val state: String,
    val scheduleID: String,
    val occurrenceID: String?,
    val runID: String?,
    val conversationID: String?,
    val nextFireAtMillis: Long?,
    val code: String?,
    val reason: String?,
) {
    val launched: Boolean get() = state == "launched"

    /** Explicit "run now" stores a durable pending occurrence; only the
     * foreground-admitted dispatch worker claims and launches it. */
    val queued: Boolean get() = state == "queued"

    /** A truthful success of the request (not yet proof of an Agent launch). */
    val accepted: Boolean get() = launched || queued
}

data class TaskScheduleArmPlan(
    val scheduleID: String,
    val nextFireAtMillis: Long?,
    val cadence: TaskScheduleCadence,
    val eventDriven: Boolean,
    val enabled: Boolean,
)

data class TaskScheduleRearm(
    val plans: List<TaskScheduleArmPlan>,
    val pendingScheduleIDs: List<String>,
)

/** A UI draft; the native service validates and resolves every binding. */
data class TaskScheduleDraft(
    val scheduleID: String?,
    val expectedRevision: String?,
    val title: String,
    val prompt: String,
    val cadence: TaskScheduleCadence,
    val scheduledAtMillis: Long,
    val weekday: Int?,
    val intervalMinutes: Int?,
    val anchorTimezone: String?,
    val upstreamRunID: String?,
    val workspaceID: String?,
    val modelID: String?,
    val environmentID: String?,
    val policy: TaskSchedulePolicyBinding,
)

/** Reference to a concrete run for the `.afterSuccess` trigger. The native
 * service projects real top-level runs (with their owning project when it
 * resolves); a UI holder may add visual suggestions, but only the native
 * service decides whether the run exists, is top-level, can still succeed, and
 * belongs to the schedule's bound project. */
data class TaskScheduleRunChoice(
    val runID: String,
    val label: String,
    val conversationID: String? = null,
    val state: String? = null,
    val startedAtMillis: Long? = null,
    val workspaceID: String? = null,
)

internal object TaskScheduleWire {
    fun objectOrNull(element: JsonElement?): JsonObject? = element as? JsonObject

    fun string(obj: JsonObject, key: String): String? =
        (obj[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() }

    fun bool(obj: JsonObject, key: String): Boolean? =
        (obj[key] as? JsonPrimitive)?.booleanOrNull

    fun int(obj: JsonObject, key: String): Int? =
        (obj[key] as? JsonPrimitive)?.longOrNull?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()

    fun array(obj: JsonObject, key: String): JsonArray? = obj[key] as? JsonArray

    fun parseMillis(raw: String?): Long? {
        if (raw.isNullOrEmpty()) return null
        return runCatching { Instant.parse(raw).toEpochMilli() }
            .recoverCatching {
                java.time.OffsetDateTime.parse(raw).toInstant().toEpochMilli()
            }
            .getOrNull()
    }

    fun isoUtc(millis: Long): String =
        DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(millis))

    fun isoLocal(millis: Long, zone: ZoneId = ZoneId.systemDefault()): String =
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
            .withZone(zone)
            .format(Instant.ofEpochMilli(millis))

    fun policy(obj: JsonObject): TaskSchedulePolicyBinding = TaskSchedulePolicyBinding(
        approvalMode = string(obj, "approvalMode") ?: "ask",
        recoveryPolicy = string(obj, "recoveryPolicy") ?: "safePoint",
        notificationPolicy = string(obj, "notificationPolicy") ?: "stages",
    )

    fun occurrence(obj: JsonObject): TaskScheduleOccurrence? {
        val id = string(obj, "id") ?: return null
        val state = string(obj, "state") ?: return null
        return TaskScheduleOccurrence(
            id = id,
            state = state,
            scheduledForMillis = parseMillis(string(obj, "scheduledFor")),
            startedAtMillis = parseMillis(string(obj, "startedAt")),
            finishedAtMillis = parseMillis(string(obj, "finishedAt")),
            runID = string(obj, "runID"),
            conversationID = string(obj, "conversationID"),
            summary = string(obj, "summary"),
            errorText = string(obj, "errorText"),
        )
    }

    fun summary(obj: JsonObject): TaskScheduleSummary? {
        val id = string(obj, "id") ?: return null
        val cadence = TaskScheduleCadence.fromWire(string(obj, "cadence")) ?: return null
        val policy = policy(obj)
        return TaskScheduleSummary(
            id = id,
            title = string(obj, "title").orEmpty(),
            promptPreview = string(obj, "promptPreview").orEmpty(),
            cadence = cadence,
            enabled = bool(obj, "enabled") ?: false,
            scheduledAtMillis = parseMillis(string(obj, "scheduledAt")),
            weekday = int(obj, "weekday"),
            intervalSeconds = int(obj, "intervalSeconds"),
            anchorTimezone = string(obj, "anchorTimezone"),
            nextFireAtMillis = parseMillis(string(obj, "nextFireAt")),
            lastStartedAtMillis = parseMillis(string(obj, "lastStartedAt")),
            modelID = string(obj, "modelID"),
            modelName = string(obj, "modelName"),
            environmentID = string(obj, "environmentID"),
            environmentName = string(obj, "environmentName"),
            workspaceID = string(obj, "workspaceID"),
            workspaceName = string(obj, "workspaceName"),
            policy = policy,
            upstreamRunID = string(obj, "upstreamRunID"),
            revision = string(obj, "revision").orEmpty(),
            lastOccurrence = objectOrNull(obj["lastOccurrence"])?.let(::occurrence),
            needsAttention = bool(obj, "needsAttention") ?: false,
        )
    }

    fun detail(obj: JsonObject): TaskScheduleDetail? {
        val summaryObject = objectOrNull(obj["summary"]) ?: obj
        val summary = summary(summaryObject) ?: return null
        return TaskScheduleDetail(
            summary = summary,
            prompt = string(obj, "prompt").orEmpty(),
            createdAtMillis = parseMillis(string(obj, "createdAt")),
            updatedAtMillis = parseMillis(string(obj, "updatedAt")),
        )
    }

    fun options(obj: JsonObject): TaskScheduleOptions = TaskScheduleOptions(
        workspaces = array(obj, "workspaces").orEmpty().mapNotNull { element ->
            val item = objectOrNull(element) ?: return@mapNotNull null
            val id = string(item, "id") ?: return@mapNotNull null
            TaskScheduleWorkspaceChoice(id, string(item, "name").orEmpty())
        },
        models = array(obj, "models").orEmpty().mapNotNull { element ->
            val item = objectOrNull(element) ?: return@mapNotNull null
            val id = string(item, "id") ?: return@mapNotNull null
            TaskScheduleModelChoice(
                id = id,
                providerID = string(item, "providerID").orEmpty(),
                displayName = string(item, "displayName").orEmpty(),
                providerName = string(item, "providerName").orEmpty(),
            )
        },
        environments = array(obj, "environments").orEmpty().mapNotNull { element ->
            val item = objectOrNull(element) ?: return@mapNotNull null
            val id = string(item, "id") ?: return@mapNotNull null
            TaskScheduleEnvironmentChoice(
                id = id,
                name = string(item, "name").orEmpty(),
                kind = string(item, "kind") ?: "project",
                ownerID = string(item, "ownerID"),
                state = string(item, "state") ?: "active",
                requiresRebuild = bool(item, "requiresRebuild") ?: false,
                executionBackend = string(item, "executionBackend"),
                parentID = string(item, "parentID"),
            )
        },
        defaultModelID = string(obj, "defaultModelID"),
        currentTimezone = string(obj, "currentTimezone"),
        environmentSelectionAvailable = bool(obj, "environmentSelectionAvailable") ?: false,
        truncated = bool(obj, "truncated") ?: false,
        runChoices = array(obj, "runChoices").orEmpty().mapNotNull { element ->
            val item = objectOrNull(element) ?: return@mapNotNull null
            val runID = string(item, "runID") ?: return@mapNotNull null
            TaskScheduleRunChoice(
                runID = runID,
                label = string(item, "label").orEmpty(),
                conversationID = string(item, "conversationID"),
                state = string(item, "state"),
                startedAtMillis = parseMillis(string(item, "startedAt")),
                workspaceID = string(item, "workspaceID"),
            )
        },
    )

    /** One bounded schedule list page. [requestedOffset] is the caller's
     *  offset used when the reply omits an explicit next cursor. */
    fun page(obj: JsonObject, requestedOffset: Int): TaskSchedulePage {
        val items = array(obj, "schedules").orEmpty()
        val schedules = items.mapNotNull { element ->
            objectOrNull(element)?.let(::summary)
        }
        val returned = int(obj, "count") ?: schedules.size
        val total = int(obj, "totalCount") ?: returned
        val next = int(obj, "nextOffset") ?: (requestedOffset + schedules.size)
        return TaskSchedulePage(
            schedules = schedules,
            totalCount = total,
            offset = requestedOffset,
            nextOffset = next,
            hasMore = bool(obj, "hasMore") ?: (next < total),
            truncated = bool(obj, "truncated") ?: false,
        )
    }

    fun occurrencePage(obj: JsonObject): TaskScheduleOccurrencePage {
        val items = array(obj, "occurrences").orEmpty()
        val occurrences = items.mapNotNull { element ->
            objectOrNull(element)?.let(::occurrence)
        }
        return TaskScheduleOccurrencePage(
            occurrences = occurrences,
            totalCount = int(obj, "totalCount") ?: occurrences.size,
            truncated = bool(obj, "truncated") ?: false,
        )
    }

    fun mutation(obj: JsonObject): TaskScheduleMutation {
        val schedule = objectOrNull(obj["schedule"])?.let {
            // `schedule` is a detail document (summary + prompt); the summary
            // decoder accepts the nested summary or the flat shape.
            if (it["summary"] != null) detail(it)?.summary else summary(it)
        }
        return TaskScheduleMutation(
            summary = schedule,
            revision = string(obj, "revision"),
        )
    }

    fun dispatch(obj: JsonObject): TaskScheduleDispatch? {
        val state = string(obj, "state") ?: return null
        val scheduleID = string(obj, "scheduleID") ?: return null
        return TaskScheduleDispatch(
            state = state,
            scheduleID = scheduleID,
            occurrenceID = string(obj, "occurrenceID"),
            runID = string(obj, "runID"),
            conversationID = string(obj, "conversationID"),
            nextFireAtMillis = parseMillis(string(obj, "nextFireAt")),
            code = string(obj, "code"),
            reason = string(obj, "reason"),
        )
    }

    fun rearm(obj: JsonObject): TaskScheduleRearm {
        val plans = array(obj, "plans").orEmpty().mapNotNull { element ->
            objectOrNull(element)?.let(::armPlan)
        }
        val pending = array(obj, "pendingScheduleIDs").orEmpty().mapNotNull { element ->
            (element as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() }
        }
        return TaskScheduleRearm(plans = plans, pendingScheduleIDs = pending)
    }

    fun armPlan(obj: JsonObject): TaskScheduleArmPlan? {
        val scheduleID = string(obj, "scheduleID") ?: return null
        val cadence = TaskScheduleCadence.fromWire(string(obj, "cadence")) ?: return null
        return TaskScheduleArmPlan(
            scheduleID = scheduleID,
            nextFireAtMillis = parseMillis(string(obj, "nextFireAt")),
            cadence = cadence,
            eventDriven = bool(obj, "eventDriven") ?: false,
            enabled = bool(obj, "enabled") ?: false,
        )
    }
}
