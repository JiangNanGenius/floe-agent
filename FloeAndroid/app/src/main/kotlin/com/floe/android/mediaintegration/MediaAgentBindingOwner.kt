// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import com.floe.android.RuntimeBootstrapCoordinator
import com.floe.android.design.SidebarSelection
import com.floe.android.feature.workbench.ui.api.MediaAgentBindingFailure
import com.floe.android.feature.workbench.ui.api.MediaAgentBindingPort
import com.floe.android.feature.workbench.ui.api.MediaAgentTaskReceipt
import com.floe.android.feature.workbench.ui.api.MediaAgentTaskRequest
import com.floe.android.host.ConversationHostController
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.RuntimeHost
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.coroutines.resume

/**
 * Application owner for the explicit "Ask AI" connection between ONE real
 * task and ONE opened media project.
 *
 * It owns no project store and no approval decision. It uses the EXISTING
 * ordinary task service to create a task only when the editor was opened from
 * the library (no owner task), then asks the privileged native issuer to
 * record the trusted association with the live accepted Root epoch + owner
 * token. The token never enters this class. The user-visible draft names the
 * project and carries the instruction; the exact project identity reaches the
 * model through the durable native task context and the original
 * `media.project` schema. The native side re-reads and validates the
 * task/workspace/project, and the first canonically approved tool call pins
 * the exact environment. Plain manual editing never calls this owner.
 */
internal class MediaAgentBindingOwner(
    /** Deferred because the Application constructs this host before the
     * coordinator field is assigned; no method reads it until an actual
     * explicit Ask AI action. */
    private val coordinatorProvider: () -> RuntimeBootstrapCoordinator,
    private val hostProvider: () -> RuntimeHost?,
) : MediaAgentBindingPort {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = false
    }

    private data class Selection(val bindingID: String)

    override suspend fun askAi(request: MediaAgentTaskRequest): MediaAgentTaskReceipt {
        validate(request)
        val runtimeHost = hostProvider()
            ?: throw MediaAgentBindingFailure("taskUnavailable")
        val host = runtimeHost.conversations
        val epoch = coordinatorProvider().acceptedStorageRoot()?.epoch
            ?: throw MediaAgentBindingFailure("ownerProofUnavailable")
        val createsTask = request.ownerTaskID == null
        val taskID = request.ownerTaskID ?: createTask(host, request.projectName)
        // Use the EXISTING trusted workspace activation service: it creates
        // the task's REAL private workspace only when no ownership row exists,
        // then returns the persisted association. This is the same service the
        // terminal/files surfaces use; it is never a first-project fallback.
        try {
            G04WorkspaceBridgeClient.bind(runtimeHost, taskID) { true }
        } catch (cancelled: CancellationException) {
            if (createsTask) runCatching { host.deleteConversation(taskID) }
            throw cancelled
        } catch (_: Throwable) {
            if (createsTask) runCatching { host.deleteConversation(taskID) }
            throw MediaAgentBindingFailure("taskUnavailable")
        }
        val selection = try {
            select(epoch, request, taskID)
        } catch (error: Throwable) {
            // The task was created only for this action; a refused association
            // must not leave an unexplained empty task behind.
            if (createsTask) {
                runCatching { host.deleteConversation(taskID) }
            }
            throw error
        }
        try {
            openTask(host, taskID, request)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            // The task and pending association both exist and are usable; the
            // user can open the task from history. Never delete them here.
            throw MediaAgentBindingFailure("taskCreatedOpenFailed")
        }
        return MediaAgentTaskReceipt(taskID = taskID, bindingID = selection.bindingID)
    }

    /**
     * Optional explicit-review path: issue the ORIGINAL single-use proposal
     * grant for the pinned association. The ordinary task-authorized apply
     * does NOT use this method and needs no per-edit prompt.
     */
    suspend fun issueProposalGrant(
        projectID: String,
        proposalID: String,
        revision: Long,
    ): String = withContext(Dispatchers.IO) {
        val epoch = coordinatorProvider().acceptedStorageRoot()?.epoch
            ?: throw MediaAgentBindingFailure("ownerProofUnavailable")
        val payload = buildJsonObject {
            put("projectID", projectID)
            put("proposalID", proposalID)
            put("revision", revision)
        }.toString()
        val reply = coordinatorProvider().issueMediaProjectGrant(epoch, payload)
            ?: throw MediaAgentBindingFailure("ownerProofUnavailable")
        val root = parseReply(reply)
        requireOk(root)
        return@withContext root["grantID"]?.jsonPrimitive?.contentOrNull
            ?.takeIf { it.isNotBlank() }
            ?: throw MediaAgentBindingFailure("grantUnavailable")
    }

    suspend fun revokeBinding(
        projectID: String,
        bindingID: String? = null,
        taskID: String? = null,
    ): Boolean = withContext(Dispatchers.IO) {
        val epoch = coordinatorProvider().acceptedStorageRoot()?.epoch
            ?: throw MediaAgentBindingFailure("ownerProofUnavailable")
        val payload = buildJsonObject {
            put("projectID", projectID)
            if (bindingID != null) put("bindingID", bindingID)
            if (taskID != null) put("taskID", taskID)
        }.toString()
        val reply = coordinatorProvider().revokeMediaTaskBinding(epoch, payload)
            ?: throw MediaAgentBindingFailure("ownerProofUnavailable")
        val root = parseReply(reply)
        root["ok"]?.jsonPrimitive?.booleanOrNull == true
    }

    private suspend fun select(
        epoch: Long,
        request: MediaAgentTaskRequest,
        taskID: String,
    ): Selection = withContext(Dispatchers.IO) {
        val payload = buildJsonObject {
            put("selectionOpID", request.selectionOpID)
            put("projectID", request.projectID)
            put("taskID", taskID)
            put("expectedRevision", request.projectRevision)
            put("replaceExisting", false)
        }.toString()
        val reply = coordinatorProvider().issueMediaTaskBinding(epoch, payload)
            ?: throw MediaAgentBindingFailure("ownerProofUnavailable")
        val root = parseReply(reply)
        requireOk(root)
        val binding = root["binding"]?.jsonObject
            ?: throw MediaAgentBindingFailure("bindingUnavailable")
        val returnedTask = binding["taskID"]?.jsonPrimitive?.contentOrNull
            ?: throw MediaAgentBindingFailure("bindingUnavailable")
        if (!returnedTask.equals(taskID, ignoreCase = true)) {
            throw MediaAgentBindingFailure("bindingUnavailable")
        }
        val bindingID = binding["bindingID"]?.jsonPrimitive?.contentOrNull
            ?.takeIf { it.isNotBlank() }
            ?: throw MediaAgentBindingFailure("bindingUnavailable")
        Selection(bindingID)
    }

    private fun parseReply(reply: String): JsonObject {
        return runCatching { json.parseToJsonElement(reply).jsonObject }
            .getOrElse { throw MediaAgentBindingFailure("bindingUnavailable") }
    }

    private fun requireOk(root: JsonObject) {
        if (root["ok"]?.jsonPrimitive?.booleanOrNull == true) return
        val code = root["error"]?.jsonPrimitive?.contentOrNull ?: "bindingUnavailable"
        throw MediaAgentBindingFailure(normalizeCode(code))
    }

    private fun normalizeCode(code: String): String = when (code) {
        "notReady", "ownerProofInvalid", "databaseUnavailable" ->
            "ownerProofUnavailable"
        "projectAlreadyBound" -> "projectAlreadyBound"
        "projectNotBindable", "storageUnresolved", "workspaceMismatch",
        "environmentMismatch" -> "projectNotBindable"
        "projectChanged" -> "projectChanged"
        "taskUnknown", "taskRequired", "workspaceUnavailable" -> "taskUnavailable"
        "bindingRevoked", "bindingMissing", "bindingPending", "bindingMismatch" ->
            "bindingUnavailable"
        else -> "taskUnavailable"
    }

    private fun validate(request: MediaAgentTaskRequest) {
        fun uuid(value: String): Boolean = runCatching {
            UUID.fromString(value).toString().equals(value, ignoreCase = true)
        }.getOrDefault(false)
        val ownerTaskInvalid = request.ownerTaskID?.let { !uuid(it) } == true
        if (!uuid(request.projectID) ||
            !uuid(request.selectionOpID) ||
            request.projectRevision < 0 ||
            ownerTaskInvalid
        ) {
            throw MediaAgentBindingFailure("projectChanged")
        }
    }

    private suspend fun createTask(
        host: ConversationHostController,
        projectName: String,
    ): String = withContext(Dispatchers.Main.immediate) {
        val taskID = suspendCancellableCoroutine<String?> { continuation ->
            val finished = AtomicBoolean(false)
            fun finish(value: String?) {
                if (!finished.compareAndSet(false, true)) return
                if (continuation.isActive) continuation.resume(value)
            }
            val started = host.createConversationForLaunch(
                title = projectName.trim().take(80).ifBlank { null },
                onCreated = { id -> finish(id) },
                onFailure = { finish(null) },
            )
            if (!started) finish(null)
        }
        taskID ?: throw MediaAgentBindingFailure("taskUnavailable")
    }

    private suspend fun openTask(
        host: ConversationHostController,
        taskID: String,
        request: MediaAgentTaskRequest,
    ) = withContext(Dispatchers.Main.immediate) {
        val prompt = promptText(request)
        val holder = host.holderFor(
            conversationId = taskID,
            isTemporary = false,
            incarnationId = null,
        )
        val current = holder.draft.value.text
        val merged = when {
            current.isBlank() -> prompt
            current.contains(prompt) -> current
            else -> current.trimEnd() + "\n\n" + prompt
        }
        if (merged != current) {
            holder.onDraftChange(TextFieldValue(merged, TextRange(merged.length)))
        }
        host.navigationRequest.value = SidebarSelection.Conversation(taskID)
    }

    private fun promptText(request: MediaAgentTaskRequest): String = mediaAgentDraftText(
        projectName = request.projectName,
        instruction = request.instruction,
        zh = Locale.getDefault().language.startsWith("zh", ignoreCase = true),
    )
}

/**
 * Human-readable draft text for ONE explicit Ask AI action.
 *
 * It names the project and carries the user's instruction only. The exact
 * selected project identity is delivered to the model through the trusted
 * native task context (the durable, user-created project/task association)
 * and the original `media.project` tool schema; it is never pasted as a raw
 * UUID/revision into the user-visible composer or chat body. Metadata is not
 * authority: the native binding still authorizes the first exact call.
 */
internal fun mediaAgentDraftText(
    projectName: String,
    instruction: String,
    zh: Boolean,
): String {
    val fallback = if (zh) "当前媒体项目" else "the open media project"
    val name = projectName.trim().take(120).ifBlank { fallback }
    val base = if (zh) {
        "请编辑媒体项目「$name」。"
    } else {
        "Please edit the media project “$name”."
    }
    val extra = instruction.trim()
    return if (extra.isEmpty()) base else "$base\n$extra"
}
