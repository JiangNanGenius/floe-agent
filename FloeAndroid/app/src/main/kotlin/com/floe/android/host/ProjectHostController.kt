// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlin.coroutines.resume

/** One real managed project row from the native `project.list/get` wire. */
data class ProjectRowUi(
    val id: String,
    val name: String,
    /** Exact persisted `workspaces.updated_at`; the OUTER project revision. */
    val revision: String,
    val createdAt: String,
    val updatedAt: String,
    val taskCount: Int,
)

data class ProjectTaskUi(
    val conversationId: String,
    val title: String,
    val purpose: String,
    val updatedAt: String,
    val pinned: Boolean,
    val archived: Boolean,
)

data class ProjectDetailUi(
    val project: ProjectRowUi,
    /** available | missing | unsafe — never silently recreated. */
    val rootState: String,
    val rootIssue: String?,
    val tasks: List<ProjectTaskUi>,
    val tasksTruncated: Boolean,
)

data class ProjectReceiptUi(
    val projectId: String,
    val deleted: Boolean,
    val rootRetained: Boolean,
    val retainedRelativeRoot: String?,
    val rootRemoval: String?,
    val rootRemoveError: String?,
    val assigned: Boolean = false,
    val alreadyAssigned: Boolean = false,
)

data class ProjectUiState(
    val loading: Boolean = true,
    val projects: List<ProjectRowUi> = emptyList(),
    val selected: ProjectDetailUi? = null,
    val busyProjectId: String? = null,
    val errorCode: String? = null,
    val notice: ProjectReceiptUi? = null,
)

/**
 * Application-owned presentation/command controller for the real C01 user
 * project library. It owns projections only: the Swift project library is
 * the authority for CRUD, CAS, managed-root checks, assignment fencing and
 * deletion lifecycles. Every reply re-reads the durable projection; there
 * are no optimistic rows and stale generation/epoch replies are dropped.
 */
class ProjectHostController internal constructor(
    private val host: RuntimeHost,
) {
    private val commands = ProjectCommands(host)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mutable = MutableStateFlow(ProjectUiState())
    val state: StateFlow<ProjectUiState> = mutable.asStateFlow()

    private val lock = Any()
    private var refreshJob: Job? = null
    private var refreshGeneration = 0L

    internal fun start() {
        if (admitted()) refresh()
    }

    internal fun stop() {
        synchronized(lock) {
            refreshGeneration += 1
            refreshJob?.cancel()
            refreshJob = null
        }
    }

    private fun admitted(): Boolean =
        host.nativeRootEpoch() != null && host.readiness.value.storeReady

    private fun current(epoch: Long, generation: Long): Boolean =
        host.nativeRootEpoch() == epoch && host.commandClient.generation() == generation

    fun refresh() {
        if (!admitted()) {
            mutable.value = mutable.value.copy(loading = false, errorCode = "runtime_unavailable")
            return
        }
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        mutable.value = mutable.value.copy(loading = true, errorCode = null)
        val token: Long
        synchronized(lock) {
            refreshGeneration += 1
            token = refreshGeneration
            refreshJob?.cancel()
            refreshJob = scope.launch(host.ioDispatcher) {
                val result = commands.list(limit = 100, offset = 0)
                synchronized(lock) {
                    if (token != refreshGeneration) return@launch
                }
                if (!current(epoch, generation)) return@launch
                when (result) {
                    is ProjectResult.Ok -> mutable.value = mutable.value.copy(
                        loading = false, projects = result.value, errorCode = null,
                    )
                    is ProjectResult.Failure -> mutable.value = mutable.value.copy(
                        loading = false, errorCode = result.code,
                    )
                }
            }
        }
    }

    fun open(projectId: String) {
        if (!admitted()) return
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        mutable.value = mutable.value.copy(busyProjectId = projectId, errorCode = null)
        scope.launch(host.ioDispatcher) {
            val result = commands.get(projectId)
            if (!current(epoch, generation)) return@launch
            when (result) {
                is ProjectResult.Ok -> mutable.value = mutable.value.copy(
                    busyProjectId = null, selected = result.value, errorCode = null,
                )
                is ProjectResult.Failure -> mutable.value = mutable.value.copy(
                    busyProjectId = null, selected = null, errorCode = result.code,
                )
            }
        }
    }

    fun clearSelection() {
        mutable.value = mutable.value.copy(selected = null)
    }

    fun create(name: String, onCreated: ((String) -> Unit)? = null) {
        if (!admitted()) return
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        mutable.value = mutable.value.copy(busyProjectId = CREATE, errorCode = null)
        scope.launch(host.ioDispatcher) {
            val result = commands.create(name)
            if (!current(epoch, generation)) return@launch
            when (result) {
                is ProjectResult.Ok -> {
                    mutable.value = mutable.value.copy(
                        busyProjectId = null, errorCode = null,
                    )
                    onCreated?.invoke(result.value.id)
                    refresh()
                }
                is ProjectResult.Failure -> mutable.value = mutable.value.copy(
                    busyProjectId = null, errorCode = result.code,
                )
            }
        }
    }

    fun rename(projectId: String, name: String) {
        if (!admitted()) return
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        val known = mutable.value.projects.firstOrNull { it.id == projectId }
            ?: mutable.value.selected?.project?.takeIf { it.id == projectId }
        mutable.value = mutable.value.copy(busyProjectId = projectId, errorCode = null)
        scope.launch(host.ioDispatcher) {
            val revision = known?.revision ?: run {
                when (val detail = commands.get(projectId)) {
                    is ProjectResult.Ok -> detail.value.project.revision
                    is ProjectResult.Failure -> {
                        if (current(epoch, generation)) {
                            mutable.value = mutable.value.copy(
                                busyProjectId = null, errorCode = detail.code,
                            )
                        }
                        return@launch
                    }
                }
            }
            val result = commands.rename(projectId, name, revision)
            if (!current(epoch, generation)) return@launch
            when (result) {
                is ProjectResult.Ok -> {
                    mutable.value = mutable.value.copy(
                        busyProjectId = null,
                        selected = mutable.value.selected?.copy(project = result.value),
                        errorCode = null,
                    )
                    refresh()
                }
                is ProjectResult.Failure -> {
                    mutable.value = mutable.value.copy(
                        busyProjectId = null, errorCode = result.code,
                    )
                    if (result.code == "staleRevision") refresh()
                }
            }
        }
    }

    fun delete(projectId: String, deleteRoot: Boolean, stopActiveTasks: Boolean) {
        if (!admitted()) return
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        val known = mutable.value.projects.firstOrNull { it.id == projectId }
            ?: mutable.value.selected?.project?.takeIf { it.id == projectId }
        mutable.value = mutable.value.copy(busyProjectId = projectId, errorCode = null)
        scope.launch(host.ioDispatcher) {
            val revision = known?.revision ?: run {
                when (val detail = commands.get(projectId)) {
                    is ProjectResult.Ok -> detail.value.project.revision
                    is ProjectResult.Failure -> {
                        if (current(epoch, generation)) {
                            mutable.value = mutable.value.copy(
                                busyProjectId = null, errorCode = detail.code,
                            )
                        }
                        return@launch
                    }
                }
            }
            val result = commands.delete(projectId, revision, deleteRoot, stopActiveTasks)
            if (!current(epoch, generation)) return@launch
            when (result) {
                is ProjectResult.Ok -> {
                    val selected = mutable.value.selected
                    mutable.value = mutable.value.copy(
                        busyProjectId = null,
                        selected = selected?.takeIf { it.project.id != projectId },
                        projects = mutable.value.projects.filterNot { it.id == projectId },
                        errorCode = null,
                        notice = result.value,
                    )
                    refresh()
                }
                is ProjectResult.Failure -> {
                    mutable.value = mutable.value.copy(
                        busyProjectId = null, errorCode = result.code,
                    )
                    if (result.code == "staleRevision") refresh()
                }
            }
        }
    }

    /**
     * Pre-first-run assignment used by Home. The native project.assign holds
     * the launch fence and refuses any existing/nonempty/bound task. On a
     * DEFINITE refusal [onFailure] carries `canRollback = true`; a
     * timeout/superseded/cancelled result may still be in flight and must
     * never trigger a header deletion.
     */
    fun assignBeforeFirstRun(
        projectId: String,
        conversationId: String,
        expectedRevision: String?,
        onSuccess: () -> Unit,
        onFailure: (code: String, canRollback: Boolean) -> Unit,
    ) {
        if (!admitted()) {
            onFailure("runtime_unavailable", false)
            return
        }
        val epoch = host.nativeRootEpoch() ?: run {
            onFailure("runtime_unavailable", false)
            return
        }
        val generation = host.commandClient.generation()
        scope.launch(host.ioDispatcher) {
            val revision = expectedRevision ?: run {
                when (val detail = commands.get(projectId)) {
                    is ProjectResult.Ok -> detail.value.project.revision
                    is ProjectResult.Failure -> {
                        if (current(epoch, generation)) {
                            onFailure(detail.code, false)
                        }
                        return@launch
                    }
                }
            }
            val result = commands.assign(projectId, conversationId, revision)
            if (!current(epoch, generation)) {
                onFailure("superseded", false)
                return@launch
            }
            when (result) {
                is ProjectResult.Ok -> {
                    if (result.value.assigned) {
                        refresh()
                        onSuccess()
                    } else {
                        onFailure("assign_refused", true)
                    }
                }
                is ProjectResult.Failure -> {
                    val safe = result.code !in setOf(
                        "timeout", "cancelled", "superseded", "runtime_unavailable",
                    )
                    onFailure(result.code, safe)
                }
            }
        }
    }

    /**
     * Safe rollback of a freshly created empty header after a DEFINITE
     * assignment refusal. It re-reads `conversation.get` and deletes only
     * when the durable counts are zero, the purpose is ordinary, and any
     * existing ownership is exactly the project this send tried to assign.
     */
    fun rollbackFreshConversation(
        conversationId: String,
        assignedProjectId: String?,
        onSettled: (deleted: Boolean) -> Unit,
    ) {
        if (!admitted()) {
            onSettled(false)
            return
        }
        val epoch = host.nativeRootEpoch() ?: run {
            onSettled(false)
            return
        }
        val generation = host.commandClient.generation()
        scope.launch(host.ioDispatcher) {
            val read = commands.conversationGet(conversationId)
            if (!current(epoch, generation)) {
                onSettled(false)
                return@launch
            }
            if (read !is ProjectResult.Ok) {
                onSettled(false)
                return@launch
            }
            val snapshot = read.value
            val empty = snapshot.messagesTotalCount == 0 &&
                snapshot.runsTotalCount == 0 &&
                snapshot.pendingInputsTotalCount == 0 &&
                snapshot.purpose == "ordinary"
            val ownershipCompatible = snapshot.workspaceId == null ||
                (assignedProjectId != null && snapshot.workspaceId == assignedProjectId)
            if (!empty || !ownershipCompatible) {
                onSettled(false)
                return@launch
            }
            val deleted = commands.conversationDelete(
                conversationId, snapshot.revision,
            )
            onSettled(deleted is ProjectResult.Ok)
        }
    }

    companion object {
        private const val CREATE = "create"
    }
}

// ---------------------------------------------------------------- commands

internal sealed interface ProjectResult<out T> {
    data class Ok<T>(val value: T) : ProjectResult<T>
    data class Failure(val code: String, val reason: String = "") : ProjectResult<Nothing>
}

private data class ConversationSnapshot(
    val revision: HostRevision,
    val messagesTotalCount: Int,
    val runsTotalCount: Int,
    val pendingInputsTotalCount: Int,
    val purpose: String,
    val workspaceId: String?,
)

private class ProjectCommands(private val host: RuntimeHost) {
    suspend fun list(limit: Int, offset: Int): ProjectResult<List<ProjectRowUi>> =
        execute(
            command = "project.list",
            payload = ProjectWire.listPayload(limit, offset),
            decode = ProjectWire::decodeList,
        )

    suspend fun get(projectId: String): ProjectResult<ProjectDetailUi> =
        execute(
            command = "project.get",
            payload = buildJsonObject { put("projectID", projectId) },
            decode = ProjectWire::decodeDetail,
        )

    suspend fun create(name: String): ProjectResult<ProjectRowUi> =
        execute(
            command = "project.create",
            payload = buildJsonObject { put("name", name) },
            createIntent = true,
            decode = ProjectWire::decodeCreated,
        )

    suspend fun rename(projectId: String, name: String,
                       revision: String): ProjectResult<ProjectRowUi> =
        execute(
            command = "project.rename",
            payload = buildJsonObject {
                put("projectID", projectId)
                put("name", name)
            },
            revision = ProjectWire.revision(projectId, revision),
            decode = ProjectWire::decodeCreated,
        )

    suspend fun assign(projectId: String, conversationId: String,
                       revision: String): ProjectResult<ProjectReceiptUi> =
        execute(
            command = "project.assign",
            payload = buildJsonObject {
                put("projectID", projectId)
                put("conversationID", conversationId)
            },
            revision = ProjectWire.revision(projectId, revision),
            timeoutMillis = 60_000L,
            decode = { value -> ProjectWire.decodeAssignment(value, projectId) },
        )

    suspend fun delete(projectId: String, revision: String,
                       deleteRoot: Boolean, stopActiveTasks: Boolean): ProjectResult<ProjectReceiptUi> =
        execute(
            command = "project.delete",
            payload = buildJsonObject {
                put("projectID", projectId)
                put("deleteRoot", deleteRoot)
                put("stopActiveTasks", stopActiveTasks)
            },
            revision = ProjectWire.revision(projectId, revision),
            timeoutMillis = 120_000L,
            decode = { value -> ProjectWire.decodeDelete(value, projectId) },
        )

    suspend fun conversationGet(conversationId: String): ProjectResult<ConversationSnapshot> =
        execute(
            command = "conversation.get",
            scope = HostScope.ConversationLifecycle(conversationId),
            payload = null,
            decode = { value ->
                val obj = value as? JsonObject ?: return@execute null
                // conversation.get carries the opaque row digest as a
                // top-level `revision` string plus `resourceID` (the same
                // shape ConversationHostController's own resolver reads).
                val revision = ConversationWire.decodeRevision(obj)
                    ?: return@execute null
                val workspace = obj["workspace"] as? JsonObject
                ConversationSnapshot(
                    revision = HostRevision(revision.resourceID, revision.version),
                    messagesTotalCount = int(obj, "messagesTotalCount") ?: 0,
                    runsTotalCount = int(obj, "runsTotalCount") ?: 0,
                    pendingInputsTotalCount = int(obj, "pendingInputsTotalCount") ?: 0,
                    purpose = string(obj, "purpose") ?: "ordinary",
                    workspaceId = workspace?.let { string(it, "workspaceID") },
                )
            },
        )

    suspend fun conversationDelete(conversationId: String,
                                   revision: HostRevision): ProjectResult<Unit> =
        execute(
            command = "conversation.delete",
            scope = HostScope.ConversationLifecycle(conversationId),
            payload = null,
            revision = revision,
            timeoutMillis = 60_000L,
            decode = { value -> if (value is JsonObject) Unit else null },
        )

    private suspend fun <T> execute(
        command: String,
        payload: JsonObject?,
        scope: HostScope = HostScope.ApplicationConfiguration(CONFIGURATION_SCOPE),
        revision: HostRevision? = null,
        createIntent: Boolean = false,
        timeoutMillis: Long = 30_000L,
        decode: (JsonElement?) -> T?,
    ): ProjectResult<T> {
        val epoch = host.nativeRootEpoch()
            ?: return ProjectResult.Failure("runtime_unavailable")
        val outcome = withTimeoutOrNull(timeoutMillis) {
            suspendCancellableCoroutine<HostOperationOutcome> { continuation ->
                val resumed = AtomicBoolean(false)
                host.trackOperation(
                    request = HostCommandRequest(
                        command = command,
                        scope = scope,
                        stateful = revision != null || createIntent,
                        correlationID = host.commandClient.correlationID("prj"),
                        revision = revision,
                        createIntent = createIntent,
                        payload = payload,
                    ),
                ) { result ->
                    if (resumed.compareAndSet(false, true)) {
                        continuation.resume(result)
                    }
                }
                continuation.invokeOnCancellation { resumed.set(true) }
            }
        } ?: return ProjectResult.Failure("timeout")
        if (host.nativeRootEpoch() != epoch) {
            return ProjectResult.Failure("superseded")
        }
        return when (outcome) {
            is HostOperationOutcome.Completed -> {
                val decoded = runCatching { decode(outcome.value) }.getOrNull()
                if (decoded == null) ProjectResult.Failure("malformed")
                else ProjectResult.Ok(decoded)
            }
            is HostOperationOutcome.Rejected ->
                ProjectResult.Failure(outcome.code, outcome.reason)
            is HostOperationOutcome.Failed -> ProjectResult.Failure(
                (outcome.detail["wire"] ?: outcome.code).trim(),
                outcome.reason,
            )
            HostOperationOutcome.Cancelled -> ProjectResult.Failure("cancelled")
            HostOperationOutcome.Superseded -> ProjectResult.Failure("superseded")
        }
    }

    companion object {
        const val CONFIGURATION_SCOPE = "projects"
    }
}

internal object ProjectWire {
    fun revision(projectId: String, version: String): HostRevision =
        HostRevision("project.${projectId.uppercase()}", version)

    fun listPayload(limit: Int, offset: Int): JsonObject = buildJsonObject {
        put("limit", limit)
        put("offset", offset)
    }

    fun decodeList(value: JsonElement?): List<ProjectRowUi>? {
        val obj = value as? JsonObject ?: return null
        val array = obj["projects"] as? JsonArray ?: return null
        return array.mapNotNull { row -> parseProject(row as? JsonObject) }
    }

    fun decodeDetail(value: JsonElement?): ProjectDetailUi? =
        (value as? JsonObject)?.let(::parseDetail)

    fun decodeCreated(value: JsonElement?): ProjectRowUi? {
        val obj = value as? JsonObject ?: return null
        return parseProject(obj["project"] as? JsonObject)
    }

    fun decodeAssignment(value: JsonElement?, fallbackProjectId: String): ProjectReceiptUi? {
        val obj = value as? JsonObject ?: return null
        if (bool(obj, "assigned") != true) return null
        return ProjectReceiptUi(
            projectId = string(obj, "projectID") ?: fallbackProjectId,
            deleted = false,
            rootRetained = true,
            retainedRelativeRoot = null,
            rootRemoval = null,
            rootRemoveError = null,
            assigned = true,
            alreadyAssigned = bool(obj, "alreadyAssigned") ?: false,
        )
    }

    fun decodeDelete(value: JsonElement?, fallbackProjectId: String): ProjectReceiptUi? {
        val obj = value as? JsonObject ?: return null
        if (bool(obj, "deleted") != true) return null
        return ProjectReceiptUi(
            projectId = string(obj, "projectID") ?: fallbackProjectId,
            deleted = true,
            rootRetained = bool(obj, "rootRetained") ?: true,
            retainedRelativeRoot = string(obj, "retainedRelativeRoot"),
            rootRemoval = string(obj, "rootRemoval"),
            rootRemoveError = string(obj, "rootRemoveError"),
        )
    }

    private fun parseProject(obj: JsonObject?): ProjectRowUi? {
        obj ?: return null
        val id = string(obj, "projectID") ?: return null
        val name = string(obj, "name") ?: return null
        val revision = string(obj, "revision") ?: return null
        return ProjectRowUi(
            id = id,
            name = name,
            revision = revision,
            createdAt = string(obj, "createdAt") ?: "",
            updatedAt = string(obj, "updatedAt") ?: revision,
            taskCount = int(obj, "taskCount") ?: 0,
        )
    }

    private fun parseDetail(obj: JsonObject): ProjectDetailUi? {
        val project = parseProject(obj) ?: return null
        val tasks = (obj["tasks"] as? JsonArray).orEmpty().mapNotNull { raw ->
            val row = raw as? JsonObject ?: return@mapNotNull null
            val id = string(row, "conversationID") ?: return@mapNotNull null
            ProjectTaskUi(
                conversationId = id,
                title = string(row, "title") ?: "",
                purpose = string(row, "purpose") ?: "ordinary",
                updatedAt = string(row, "updatedAt") ?: "",
                pinned = bool(row, "pinned") ?: false,
                archived = bool(row, "archived") ?: false,
            )
        }
        return ProjectDetailUi(
            project = project,
            rootState = string(obj, "rootState") ?: "missing",
            rootIssue = string(obj, "rootIssue"),
            tasks = tasks,
            tasksTruncated = bool(obj, "tasksTruncated") ?: false,
        )
    }
}

private fun string(obj: JsonObject, key: String): String? =
    (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

private fun int(obj: JsonObject, key: String): Int? =
    (obj[key] as? JsonPrimitive)?.takeIf { it.isString.not() }?.intOrNull

private fun bool(obj: JsonObject, key: String): Boolean? {
    val primitive = obj[key] as? JsonPrimitive ?: return null
    if (primitive.isString) return null
    return primitive.contentOrNull?.toBooleanStrictOrNull()
}
