// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

/** Application-owned Git presentation. The existing native workspace
 * service resolves every path and holds the real operation receipt. Leaving
 * an inspector never cancels an admitted write or fabricates its completion.
 * This bounded RAM cache stores projections, not repositories or job truth. */
internal class G04GitHostController(private val host: RuntimeHost) {
    data class State(
        val epoch: Long, val generation: Long,
        val busy: Boolean = false,
        val snapshot: JsonObject? = null,
        val diff: String? = null,
        val error: String? = null,
        val editorRefreshUnavailable: List<String> = emptyList(),
    )

    private val lock = Any()
    private val states = MutableStateFlow<Map<String, State>>(emptyMap())
    val state: StateFlow<Map<String, State>> = states

    private fun current(taskID: String, epoch: Long, generation: Long): Boolean =
        host.nativeRootEpoch() == epoch && host.commandClient.generation() == generation &&
            host.conversations.entryFor(taskID)?.isTemporary == false

    fun refresh(taskID: String) = perform(taskID, "snapshot")

    fun perform(taskID: String, action: String, arguments: JsonObject = JsonObject(emptyMap())) {
        if (action !in READS && action !in WRITES) return
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        if (!current(taskID, epoch, generation)) return
        synchronized(lock) {
            val old = states.value[taskID]?.takeIf { it.epoch == epoch && it.generation == generation }
            if (old?.busy == true) return
            val rows = states.value.toMutableMap()
            if (taskID !in rows && rows.size >= 16) {
                val removable = rows.entries.firstOrNull { !it.value.busy }?.key ?: return
                rows.remove(removable)
            }
            rows[taskID] = (old ?: State(epoch, generation)).copy(busy = true, error = null)
            states.value = rows
        }
        host.scope.launch(host.ioDispatcher) {
            try {
                val client = G04WorkspaceBridgeClient.bind(host, taskID) { current(taskID, epoch, generation) }
                if (action in REMOTE_ACTIONS && host.workspaceGitTrust?.ensureBound(epoch) != true)
                    throw G04WorkspaceBridgeClient.Failure("gitTrustUnavailable")
                suspend fun execute(): JsonObject = client.request(
                    if (action in READS) "gitQuery" else "gitMutate", buildJsonObject {
                        put("action", action); put("arguments", arguments)
                    })
                val result = if (action in WORKING_TREE_WRITES)
                    host.workspaceEditors.withExternalMutation(taskID) { execute() } else execute()
                val missing = (result["editorRefreshUnavailable"] as? JsonArray)?.mapNotNull {
                    (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.contentOrNull
                }.orEmpty()
                val value = result["value"] as? JsonObject
                if (action == "snapshot" || action == "initialize") {
                    update(taskID, epoch, generation) { it.copy(snapshot = value, busy = false, editorRefreshUnavailable = missing) }
                } else if (action == "diff" || action == "diffStaged") {
                    val text = (value?.get("text") as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
                        ?: throw G04WorkspaceBridgeClient.Failure("invalidReply")
                    update(taskID, epoch, generation) { it.copy(diff = text, busy = false) }
                } else {
                    // Re-read native state after mutations, including actual
                    // merge outcomes. No optimistic staged/branch status.
                    val fresh = client.request("gitQuery", buildJsonObject {
                        put("action", "snapshot"); put("arguments", JsonObject(emptyMap()))
                    })["value"] as? JsonObject ?: throw G04WorkspaceBridgeClient.Failure("invalidReply")
                    update(taskID, epoch, generation) { it.copy(snapshot = fresh, busy = false, editorRefreshUnavailable = missing) }
                }
            } catch (error: Exception) {
                val code = if (error is CancellationException) "cancelled"
                    else (error as? G04WorkspaceBridgeClient.Failure)?.code ?: "internalError"
                update(taskID, epoch, generation) { it.copy(busy = false, error = code) }
                if (error is CancellationException) throw error
            }
        }
    }

    fun dismissDiff(taskID: String) {
        synchronized(lock) {
            val row = states.value[taskID] ?: return
            states.value = states.value + (taskID to row.copy(diff = null))
        }
    }

    private fun update(taskID: String, epoch: Long, generation: Long, transform: (State) -> State) {
        synchronized(lock) {
            if (!current(taskID, epoch, generation)) {
                // Retire only the exact old projection; a newer generation
                // may already be showing the same conversation.
                val old = states.value[taskID]
                if (old?.epoch == epoch && old.generation == generation) states.value -= taskID
                return
            }
            val row = states.value[taskID] ?: return
            if (row.epoch == epoch && row.generation == generation) states.value += taskID to transform(row)
        }
    }

    companion object {
        private val READS = setOf("snapshot", "diff", "diffStaged")
        private val WRITES = setOf("initialize", "stage", "unstage", "discard", "commit", "createBranch",
            "switchBranch", "merge", "abortMerge", "fetch", "push", "pull", "pullMerge", "clone")
        private val REMOTE_ACTIONS = setOf("clone", "fetch", "pull", "pullMerge", "push")
        private val WORKING_TREE_WRITES = setOf("switchBranch", "merge", "abortMerge", "discard", "pull", "pullMerge")
    }
}
