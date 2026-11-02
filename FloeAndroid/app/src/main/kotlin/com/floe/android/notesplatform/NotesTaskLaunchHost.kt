// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import com.floe.android.design.SidebarSelection
import com.floe.android.feature.conversation.ComposerDraftSeedUi
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchOutcome
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchPolicy
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchPort
import com.floe.android.feature.notes.ui.api.NotesTaskLaunchRequest
import com.floe.android.host.RuntimeHost
import com.floe.android.host.notes.NotesHostController
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Reuses the ordinary task creator and Notes authority; no inference is needed to prepare a task. */
internal class NotesTaskLaunchHost(
    private val host: RuntimeHost,
    private val notes: NotesHostController,
) : NotesTaskLaunchPort {
    private val creation = Mutex()
    private val ready = ConcurrentHashMap<String, Long>()

    override fun isAvailable(): Boolean = (host.nativeRootEpoch() ?: 0L) > 0L

    override suspend fun createTask(request: NotesTaskLaunchRequest): NotesTaskLaunchOutcome =
        withContext(host.ioDispatcher) {
            val epoch = host.nativeRootEpoch()?.takeIf { it > 0L }
                ?: return@withContext NotesTaskLaunchOutcome.Failed(
                    NotesPortFailure(NotesPortFailure.UNAVAILABLE))
            if (!creation.tryLock()) return@withContext NotesTaskLaunchOutcome.Failed(
                NotesPortFailure(NotesPortFailure.BUSY))
            val receiptID = UUID.randomUUID().toString()
            var conversationID: String? = null
            var granted = false
            var prepared = false
            try {
                checkCurrent(epoch)
                NotesTaskLaunchPolicy.validate(request.resources)?.let {
                    return@withContext NotesTaskLaunchOutcome.Failed(it)
                }
                val document = notes.service.documentSummary(request.documentID)
                if (document.revision != request.documentRevision) throw NotesException("conflict")
                for (resource in request.resources) {
                    val metadata = notes.service.resourceMetadata(resource.resourceID)
                    if (metadata.hash.lowercase() != resource.sha256.lowercase() ||
                        metadata.byteCount != resource.byteCount || metadata.fileName != resource.fileName ||
                        metadata.mediaType != resource.mediaType) throw NotesException("conflict")
                }
                currentCoroutineContext().ensureActive()
                checkCurrent(epoch)
                val taskID = createConversation(request.documentTitle)
                conversationID = taskID
                currentCoroutineContext().ensureActive()
                checkCurrent(epoch)
                notes.service.grantAccess(taskID, request.documentID, canEdit = false)
                granted = true
                val reply = notes.commandObject("taskLaunch.prepare", buildJsonObject {
                    put("receiptID", receiptID)
                    put("notesEpoch", epoch)
                    put("conversationID", taskID)
                    put("documentID", request.documentID)
                    put("documentRevision", request.documentRevision)
                    put("resources", JsonArray(request.resources.map { resource -> buildJsonObject {
                        put("resourceID", resource.resourceID)
                        put("sha256", resource.sha256.lowercase())
                        put("byteCount", resource.byteCount)
                        put("fileName", resource.fileName)
                        put("mediaType", resource.mediaType)
                    } }))
                })
                check(reply["receiptID"]?.jsonPrimitive?.contentOrNull?.equals(receiptID, ignoreCase = true) == true)
                val destinations = reply["destinations"] as? JsonArray ?: error("destinations")
                check(destinations.size == request.resources.size)
                val expectedIDs = request.resources.map { UUID.fromString(it.resourceID).toString() }.toSet()
                val seen = mutableSetOf<String>()
                val prefix = "NotesImports/${UUID.fromString(request.documentID).toString().uppercase()}/"
                val paths = destinations.map { element ->
                    val row = element as? JsonObject ?: error("destination")
                    val id = UUID.fromString(row["resourceID"]?.jsonPrimitive?.contentOrNull).toString()
                    check(id in expectedIDs && seen.add(id))
                    val path = row["relativePath"]?.jsonPrimitive?.contentOrNull ?: error("path")
                    check(path.startsWith(prefix) && path.length <= 1024 &&
                        path.split('/').none { it.isEmpty() || it == "." || it == ".." } &&
                        path.none { it.code < 32 })
                    path
                }
                val manifest = "Attached from Notes (selection $receiptID):\n" +
                    paths.joinToString("\n") { "- $it" }
                val message = listOf(request.prompt.trim(), manifest).filter { it.isNotEmpty() }.joinToString("\n\n")
                currentCoroutineContext().ensureActive()
                checkCurrent(epoch)
                withContext(Dispatchers.Main.immediate) {
                    checkCurrent(epoch)
                    host.conversations.holderFor(taskID, isTemporary = false,
                        incarnationId = null, initialDraft = ComposerDraftSeedUi(
                            text = message, attachments = emptyList(), caretIndex = null, selectionLength = null))
                }
                ready.entries.removeIf { it.value != epoch }
                check(ready.size < 64)
                ready[taskID] = epoch
                prepared = true
                NotesTaskLaunchOutcome.Created(taskID, receiptID)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                NotesTaskLaunchOutcome.Failed(NotesPortFailure(
                    if (error is NotesException && error.code == "conflict") NotesPortFailure.FAILED
                    else NotesPortFailure.UNAVAILABLE,
                    if (conversationID != null) "taskCreatedWithoutAttachments"
                    else if (error is NotesException && error.code == "conflict") "selectionChanged"
                    else "taskPreparationFailed"))
            } finally {
                val orphanID = conversationID
                if (!prepared && orphanID != null && host.nativeRootEpoch() == epoch) {
                    withContext(NonCancellable + host.ioDispatcher) {
                        runCatching { notes.commandObject("taskLaunch.discard", buildJsonObject {
                            put("receiptID", receiptID); put("conversationID", orphanID)
                        }) }
                        if (granted) runCatching { notes.service.revokeAccess(orphanID, request.documentID) }
                    }
                }
                creation.unlock()
            }
        }

    override fun openCreatedTask(conversationID: String): Boolean {
        val epoch = ready.remove(conversationID) ?: return false
        if (epoch != host.nativeRootEpoch()) return false
        host.conversations.navigationRequest.value = SidebarSelection.Conversation(conversationID)
        return true
    }

    private fun checkCurrent(epoch: Long) {
        if (epoch <= 0L || host.nativeRootEpoch() != epoch) throw NotesException("staleGeneration")
    }

    private suspend fun createConversation(title: String): String = withContext(Dispatchers.Main.immediate) {
        suspendCancellableCoroutine { continuation ->
            val accepted = host.conversations.createConversationForLaunch(
                title = title.take(80),
                onCreated = { if (continuation.isActive) continuation.resume(it) },
                onFailure = { if (continuation.isActive) continuation.resumeWith(Result.failure(NotesException(it))) },
            )
            if (!accepted && continuation.isActive) continuation.resumeWith(Result.failure(NotesException("notReady")))
        }
    }
}
