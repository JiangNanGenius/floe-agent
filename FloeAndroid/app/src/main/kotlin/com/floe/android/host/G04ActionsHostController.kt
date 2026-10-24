// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.bridge.GitActionsNative
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.util.UUID

/** Application-owned GitHub Actions presentation + command layer for the
 * durable native engine (job-7bb726c11c6449e0, G04-R1).
 *
 * Everything user-facing rides the EXISTING closed `workspace.read` /
 * `workspace.write` grammar through the same [G04WorkspaceBridgeClient] the
 * Changes inspector uses: task and native epoch identity are the outer closed
 * fields, and each Actions verb is a staged full `gitQuery`/`gitMutate` subop
 * whose payload is validated by the native `G04WorkspaceGit.Arguments`
 * grammar BEFORE any side effect. This controller stores only bounded RAM
 * projections of native durable records — never job truth, tokens, headers or
 * response bodies.
 *
 * Command discipline mirrors [G04GitHostController]: one task+epoch/generation
 * bind, an app-owned command coroutine (leaving the pane never cancels an
 * admitted native write or fabricates its completion), the JVM typing fence
 * via `workspaceEditors.withExternalMutation` around the snapshot dispatch,
 * and typed refusal codes the UI localizes. Remote-polling lifecycle uses the
 * ORIGINAL engine scene rules through [GitActionsNative.scene], forwarded by
 * the trusted Activity hooks — pausing stops only the LOCAL refresh loop and
 * never claims the cloud run stopped. */
internal class G04ActionsHostController(private val host: RuntimeHost) {
    data class State(
        val epoch: Long,
        val generation: Long,
        val busy: Boolean = false,
        val account: JsonObject? = null,
        val repositories: List<JsonObject> = emptyList(),
        val workflows: List<JsonObject> = emptyList(),
        val templates: List<JsonObject> = emptyList(),
        /** Last REVIEWED snapshot preview: `directory` + `manifest` (exact
         * included entries + typed exclusions) + the canonical
         * `reviewedSHA256` that dispatch must reproduce. */
        val preview: JsonObject? = null,
        /** Durable engine records for THIS task's workspace, newest first. */
        val records: List<JsonObject> = emptyList(),
        val corruptFiles: List<String> = emptyList(),
        val engineError: String? = null,
        val detail: JsonObject? = null,
        val detailJobs: List<JsonObject> = emptyList(),
        val detailLog: String? = null,
        val error: String? = null,
        val editorRefreshUnavailable: List<String> = emptyList(),
    )

    private val lock = Any()
    private val states = MutableStateFlow<Map<String, State>>(emptyMap())
    val state: StateFlow<Map<String, State>> = states

    private fun current(taskID: String, epoch: Long, generation: Long): Boolean =
        host.nativeRootEpoch() == epoch && host.commandClient.generation() == generation &&
            host.conversations.entryFor(taskID)?.isTemporary == false

    /** Trusted Activity lifecycle forward (Main mounts onStart/onStop). The
     * single app-level scene identity matches the original iOS legacy scene:
     * the first activation starts the engine's bounded poller and the last
     * deactivation pauses it. No payload crosses this seam. */
    fun scene(active: Boolean) {
        val epoch = host.nativeRootEpoch() ?: return
        GitActionsNative.scene(epoch, active, SCENE_ID)
    }

    fun load(taskID: String, connection: Boolean) {
        if (connection) {
            perform(taskID, "account", JsonObject(emptyMap()), storeAccount = true)
            perform(taskID, "repositories", JsonObject(emptyMap()), storeList = StoreSlot.REPOSITORIES)
        }
        perform(taskID, "actions.records", JsonObject(emptyMap()), storeRecords = true)
    }

    fun loadWorkflows(taskID: String, owner: String, repository: String) = perform(
        taskID, "actions.workflows",
        buildJsonObject { put("owner", owner); put("repository", repository) },
        storeList = StoreSlot.WORKFLOWS)

    fun loadTemplates(taskID: String, languageID: String) = perform(
        taskID, "actions.templates",
        buildJsonObject { put("languageID", languageID) }, storeTemplates = true)

    /** The reviewable snapshot the user is about to publish: the exact
     * included list plus typed exclusions. Nothing outside it can be sent. */
    fun previewSnapshot(taskID: String, directory: String) = perform(
        taskID, "actions.snapshotPreview",
        buildJsonObject { if (directory.isNotBlank()) put("directory", directory.trim()) },
        storePreview = true)

    fun installTemplate(taskID: String, owner: String, repository: String, templateID: String) = perform(
        taskID, "actions.installTemplate",
        buildJsonObject { put("owner", owner); put("repository", repository); put("templateID", templateID) })

    /** Durable engine dispatch. `requestID` is the idempotent intent:
     * re-sending the SAME id returns the existing record and NEVER
     * re-dispatches; an explicit retry therefore uses a fresh intent id. */
    fun dispatch(taskID: String, plan: Plan) {
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        if (!current(taskID, epoch, generation)) return
        val reviewed = synchronized(lock) { states.value[taskID]?.preview?.string("reviewedSHA256") }
        if (reviewed == null) {
            update(taskID, epoch, generation) { it.copy(error = "gitActionsReviewStale") }
            return
        }
        val arguments = buildJsonObject {
            put("owner", plan.owner); put("repository", plan.repository)
            put("workflowPath", plan.workflowPath); put("requestID", plan.requestID)
            put("languageID", plan.languageID); put("role", plan.role); put("platform", plan.platform)
            if (plan.targetFile.isNotBlank()) put("targetFile", plan.targetFile)
            put("reviewedManifestSHA", reviewed)
            if (plan.inputs.isNotEmpty()) put("inputs", buildJsonObject {
                plan.inputs.forEach { (key, value) -> put(key, value) }
            })
        }
        perform(taskID, "actions.dispatch", arguments, fence = true, afterDispatch = true)
    }

    data class Plan(
        val owner: String, val repository: String, val workflowPath: String,
        val requestID: String, val languageID: String, val role: String, val platform: String,
        val targetFile: String, val inputs: Map<String, String>,
    )

    fun newRequestID(): String = UUID.randomUUID().toString().take(12).lowercase()

    fun refreshRecord(taskID: String, recordID: String) = perform(
        taskID, "actions.refresh", buildJsonObject { put("recordID", recordID) }, storeRecords = true)

    fun openRecord(taskID: String, recordID: String) = perform(
        taskID, "actions.record", buildJsonObject { put("recordID", recordID) }, storeDetail = true)

    fun loadDetailJobs(taskID: String, record: JsonObject) {
        val runID = record.long("runID") ?: return
        val owner = record.string("owner") ?: return
        val repository = record.string("repository") ?: return
        perform(taskID, "actions.jobs",
            buildJsonObject { put("owner", owner); put("repository", repository); put("runID", runID) },
            storeList = StoreSlot.DETAIL_JOBS)
    }

    fun loadDetailLog(taskID: String, recordID: String, jobID: Long) = perform(
        taskID, "actions.jobLog",
        buildJsonObject { put("recordID", recordID); put("jobID", jobID) }, storeDetailLog = true)

    fun loadArtifacts(taskID: String, recordID: String) = perform(
        taskID, "actions.loadArtifacts", buildJsonObject { put("recordID", recordID) }, storeDetail = true)

    fun downloadArtifact(taskID: String, recordID: String, artifactID: Long, overwrite: Boolean) =
        perform(taskID, "actions.downloadArtifact",
            buildJsonObject {
                put("recordID", recordID); put("artifactID", artifactID); put("overwrite", overwrite)
            }, storeDetail = true)

    /** Durable cancel: the engine persists the intent BEFORE any network
     * request, keeps reconciling until GitHub finalizes, and re-sends a
     * queued cancel once the run id is finally associated. */
    fun cancelRecord(taskID: String, recordID: String) = perform(
        taskID, "actions.cancelJob", buildJsonObject { put("recordID", recordID) }, storeRecords = true)

    fun dismissError(taskID: String) {
        synchronized(lock) {
            val row = states.value[taskID] ?: return
            states.value = states.value + (taskID to row.copy(error = null))
        }
    }

    fun closeDetail(taskID: String) {
        synchronized(lock) {
            val row = states.value[taskID] ?: return
            states.value = states.value + (taskID to row.copy(
                detail = null, detailJobs = emptyList(), detailLog = null))
        }
    }

    private enum class StoreSlot { REPOSITORIES, WORKFLOWS, DETAIL_JOBS }

    private fun perform(
        taskID: String, action: String, arguments: JsonObject,
        storeAccount: Boolean = false, storeList: StoreSlot? = null, storeTemplates: Boolean = false,
        storePreview: Boolean = false, storeRecords: Boolean = false, storeDetail: Boolean = false,
        storeDetailLog: Boolean = false, fence: Boolean = false, afterDispatch: Boolean = false,
    ) {
        if (action !in READS && action !in WRITES) return
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        if (!current(taskID, epoch, generation)) return
        synchronized(lock) {
            val old = states.value[taskID]?.takeIf { it.epoch == epoch && it.generation == generation }
            if (old?.busy == true) return
            val rows = states.value.toMutableMap()
            if (taskID !in rows && rows.size >= 8) {
                val removable = rows.entries.firstOrNull { !it.value.busy }?.key ?: return
                rows.remove(removable)
            }
            rows[taskID] = (old ?: State(epoch, generation)).copy(busy = true, error = null)
            states.value = rows
        }
        host.scope.launch(host.ioDispatcher) {
            val isRead = action in READS
            try {
                val client = G04WorkspaceBridgeClient.bind(host, taskID) { current(taskID, epoch, generation) }
                suspend fun execute(): JsonObject = client.request(
                    if (isRead) "gitQuery" else "gitMutate", buildJsonObject {
                        put("action", action); put("arguments", arguments)
                    })
                val result = if (fence) host.workspaceEditors.withExternalMutation(taskID) { execute() }
                    else execute()
                val missing = (result["editorRefreshUnavailable"] as? JsonArray)?.mapNotNull {
                    (it as? JsonPrimitive)?.takeIf { path -> path.isString }?.contentOrNull
                }.orEmpty()
                // Native envelopes every action as
                // {action, value, editorRefreshUnavailable}; `value` is the
                // account/repository/run objects (or arrays) for the mirrored
                // raw queries and the typed engine payloads for durable
                // Actions verbs. Nothing is guessed or defaulted on.
                val inner = result["value"]
                val objectValue = inner as? JsonObject
                val arrayValue = inner as? JsonArray
                if (!storeAccount && storeList == null && objectValue == null && arrayValue == null) {
                    throw G04WorkspaceBridgeClient.Failure("invalidReply")
                }
                update(taskID, epoch, generation) { state ->
                    var next = state.copy(busy = false, error = null, editorRefreshUnavailable = missing)
                    if (storeAccount) next = next.copy(account = objectValue)
                    when (storeList) {
                        StoreSlot.REPOSITORIES -> next = next.copy(repositories = objectArray(arrayValue))
                        StoreSlot.WORKFLOWS -> next = next.copy(workflows = objectArray(arrayValue))
                        StoreSlot.DETAIL_JOBS -> next = next.copy(detailJobs = objectArray(arrayValue))
                        null -> Unit
                    }
                    if (storeTemplates) next = next.copy(templates = objectArray(objectValue?.arrayOf("templates")))
                    if (storePreview) next = next.copy(preview = objectValue)
                    if (storeRecords) next = next.copy(
                        records = objectArray(objectValue?.arrayOf("records")),
                        corruptFiles = objectValue?.arrayOf("corruptFiles")?.mapNotNull {
                            (it as? JsonPrimitive)?.contentOrNull
                        } ?: emptyList(),
                        engineError = objectValue?.string("engineError"),
                    )
                    if (storeDetail) next = next.copy(detail = objectValue)
                    if (storeDetailLog) next = next.copy(detailLog = objectValue?.string("text"))
                    if (afterDispatch) next = next.copy(preview = null)
                    next
                }
                if (afterDispatch) load(taskID, connection = false)
            } catch (error: Exception) {
                val code = if (error is CancellationException) "cancelled"
                    else (error as? G04WorkspaceBridgeClient.Failure)?.code ?: "internalError"
                update(taskID, epoch, generation) { it.copy(busy = false, error = code) }
                if (error is CancellationException) throw error
            }
        }
    }

    private fun update(taskID: String, epoch: Long, generation: Long, transform: (State) -> State) {
        synchronized(lock) {
            if (!current(taskID, epoch, generation)) {
                val old = states.value[taskID]
                if (old?.epoch == epoch && old.generation == generation) states.value -= taskID
                return
            }
            val row = states.value[taskID] ?: return
            if (row.epoch == epoch && row.generation == generation) states.value += taskID to transform(row)
        }
    }

    companion object {
        /** The trusted app-level scene identity forwarded by the Activity
         * hooks, matching the original iOS legacy single-scene ("app") rule. */
        const val SCENE_ID = "floe-app"

        private val READS = setOf(
            "account", "repositories", "actions.workflows", "actions.templates",
            "actions.snapshotPreview", "actions.records", "actions.record", "actions.refresh",
            "actions.jobLog", "actions.loadArtifacts", "actions.jobs",
        )
        private val WRITES = setOf(
            "actions.dispatch", "actions.installTemplate", "actions.cancelJob", "actions.downloadArtifact",
        )

        private fun objectArray(value: JsonArray?): List<JsonObject> =
            value?.mapNotNull { it as? JsonObject } ?: emptyList()
    }
}

// JsonObject.string(...) comes from the ONE shared HostHelpers extension;
// a second file-local copy here conflicted with it (overload ambiguity).
private fun JsonObject.long(name: String): Long? =
    (this[name] as? JsonPrimitive)?.longOrNull

private fun JsonObject.arrayOf(name: String): JsonArray? =
    this[name] as? JsonArray
