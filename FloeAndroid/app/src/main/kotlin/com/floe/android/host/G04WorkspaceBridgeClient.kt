// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlin.coroutines.coroutineContext

/** One exact task/workspace/actual native generation, never a fabricated Run.
 * No disk, credential or editor authority lives here. It uses the existing
 * host's mailbox/effect tracking and rejects stale replies before publishing.
 * The native workspace domain must actually bind before this client admits.
 */
internal class G04WorkspaceBridgeClient(
    private val host: RuntimeHost,
    val taskID: String,
    val workspaceID: String,
    private val hostGeneration: Long,
    private val nativeEpoch: Long,
    private val isCurrentOwner: () -> Boolean,
) {
    init {
        require(UUID.fromString(taskID).toString().equals(taskID, ignoreCase = true))
        require(UUID.fromString(workspaceID).toString().equals(workspaceID, ignoreCase = true))
        require(hostGeneration >= 0 && nativeEpoch > 0)
    }

    internal class Failure(val code: String) : Exception(code)

    private fun admitted(): Boolean = isCurrentOwner() && host.readiness.value.storeReady &&
        (host.readiness.value.domains["workspaceDomain"] as? RuntimeHostReadiness.DomainReadiness.Available)
            ?.generation == hostGeneration && host.commandClient.generation() == hostGeneration &&
        host.nativeRootEpoch() == nativeEpoch

    /** Grammar is repeated by the native facade before ANY side effect.
     * Document revisions are opaque payload tokens; outer task identity is
     * the existing conversationLifecycle scope, with no fake execution IDs.
     */
    suspend fun request(operation: String, fields: JsonObject = JsonObject(emptyMap())): JsonObject {
        coroutineContext.ensureActive()
        if (!admitted()) throw Failure("ownerUnavailable")
        if (operation !in READ_OPERATIONS && operation !in WRITE_OPERATIONS) throw Failure("unknownOperation")
        if (fields.keys.any { it == "op" || it == "workspaceID" || it == "nativeEpoch" }) throw Failure("reservedOwnerField")
        val payload = buildJsonObject {
            put("op", operation); put("workspaceID", workspaceID); put("nativeEpoch", nativeEpoch.toString())
            fields.forEach { (key, value) -> put(key, value) }
        }
        val outcome = CompletableDeferred<HostOperationOutcome>()
        host.trackOperation(
            HostCommandRequest(
                command = if (operation in READ_OPERATIONS) "workspace.read" else "workspace.write",
                scope = HostScope.ConversationLifecycle(taskID), stateful = false,
                correlationID = "workspace:${UUID.randomUUID()}", payload = payload,
            ),
            onTerminal = { terminal -> outcome.complete(terminal) },
        )
        // Caller cancellation stops this waiter, not an already admitted
        // native write. Host tracking still settles and closes its receipt.
        val terminal = outcome.await()
        if (!admitted()) throw Failure("ownerChanged")
        val reply = when (terminal) {
            is HostOperationOutcome.Completed -> terminal.value as? JsonObject ?: throw Failure("missingValue")
            is HostOperationOutcome.Rejected -> throw Failure(terminal.code)
            is HostOperationOutcome.Failed -> throw Failure(terminal.detail["wire"] ?: terminal.code)
            HostOperationOutcome.Cancelled -> throw Failure("cancelled")
            HostOperationOutcome.Superseded -> throw Failure("superseded")
        }
        return if (operation in QUERY_OPERATIONS &&
            (reply["staged"] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull == true) {
            val text = readTransfer(reply, "queryContent", "releaseQuery", MAX_QUERY_BYTES)
            try { Json.parseToJsonElement(text) as? JsonObject ?: throw Failure("invalidQueryReply") }
            catch (error: Failure) { throw error }
            catch (_: IllegalArgumentException) { throw Failure("invalidQueryReply") }
        } else reply
    }

    /** Full, digest-verified byte assembly. Intermediate base64 bytes are
     * never decoded as UTF-8 (a Unicode scalar may span transport chunks).
     * No partial text is ever returned or sent back as a successful save.
     */
    suspend fun readContent(documentID: String, revision: String, part: String = "document"): String {
        if (part !in setOf("document", "diff", "conflictBase", "conflictCurrent")) throw Failure("invalidContentPart")
        val header = request("beginContent", buildJsonObject {
            put("documentID", documentID); put("revision", revision); put("part", part)
        })
        return readTransfer(header, "readContent", "releaseContent",
            if (part == "diff") MAX_DIFF_BYTES else MAX_DOCUMENT_BYTES)
    }

    private suspend fun readTransfer(header: JsonObject, readOperation: String,
                                     releaseOperation: String, maximum: Int): String {
        val handle = header.string("handle")
        try {
            val size = header.integer("byteCount")
            if (size !in 0..maximum) throw Failure("contentTooLarge")
            val expected = header.string("sha256")
            if (!validDigest(expected)) throw Failure("invalidDigest")
            val output = ByteArrayOutputStream(minOf(size, CHUNK_BYTES))
            var offset = 0
            do {
                val chunk = request(readOperation, buildJsonObject {
                    put("handle", handle); put("offset", offset); put("limit", CHUNK_BYTES)
                })
                val bytes = try { Base64.getDecoder().decode(chunk.string("bytes")) }
                    catch (_: IllegalArgumentException) { throw Failure("invalidContentChunk") }
                val next = chunk.integer("nextOffset")
                val finished = chunk.flag("finished")
                if (bytes.size > CHUNK_BYTES || bytes.size > size - offset || next != offset + bytes.size ||
                    finished != (next == size) || (!finished && bytes.isEmpty())) throw Failure("invalidContentChunk")
                output.write(bytes); offset = next
                if (finished) break
            } while (true)
            val data = output.toByteArray()
            if (data.size != size || digest(data) != expected) throw Failure("contentDigestMismatch")
            return try {
                Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(data)).toString()
            } catch (_: java.nio.charset.CharacterCodingException) { throw Failure("invalidUTF8") }
        } finally {
            // Detachment never authorizes another owner's command. Native
            // TTL retires any handle whose original owner is no longer live.
            if (admitted()) withContext(NonCancellable) {
                withTimeoutOrNull(5_000) {
                    runCatching { request(releaseOperation, buildJsonObject { put("handle", handle) }) }
                }
            }
        }
    }

    /** Large paste uses bounded upload chunks and one native atomic draft
     * transaction. None of these calls directly write a file to disk.
     */
    suspend fun uploadEdit(documentID: String, revision: String, location: Int, length: Int,
                           replacement: String): JsonObject {
        if (location < 0 || length < 0) throw Failure("invalidRange")
        val bytes = try {
            val encoded = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(replacement))
            ByteArray(encoded.remaining()).also { encoded.get(it) }
        } catch (_: java.nio.charset.CharacterCodingException) { throw Failure("invalidUnicode") }
        if (bytes.size > MAX_DOCUMENT_BYTES) throw Failure("contentTooLarge")
        val begun = request("beginEditUpload", buildJsonObject {
            put("documentID", documentID); put("revision", revision)
            put("location", location); put("length", length)
            put("byteCount", bytes.size); put("sha256", digest(bytes))
        })
        val handle = begun.string("handle")
        var committed = false
        try {
            var offset = 0
            while (offset < bytes.size) {
                val end = minOf(bytes.size, offset + CHUNK_BYTES)
                val chunk = bytes.copyOfRange(offset, end)
                val appended = request("appendEditUpload", buildJsonObject {
                    put("handle", handle); put("offset", offset)
                    put("bytes", Base64.getEncoder().encodeToString(chunk))
                })
                if (appended.integer("nextOffset") != end) throw Failure("invalidUploadOffset")
                offset = end
            }
            val result = request("commitEditUpload", buildJsonObject { put("handle", handle) })
            committed = true
            return result
        } finally {
            if (!committed && admitted()) withContext(NonCancellable) {
                withTimeoutOrNull(5_000) {
                    runCatching { request("cancelEditUpload", buildJsonObject { put("handle", handle) }) }
                }
            }
        }
    }

    /** Complete upload and real disk-hash proof; consumes no editor slot. */
    suspend fun preserveProjection(recoveryID: String, sourcePath: String, text: String): String {
        val data = strictUTF8(text)
        if (data.size > MAX_DOCUMENT_BYTES) throw Failure("contentTooLarge")
        val expected = digest(data)
        val begun = request("beginProjectionRecovery", buildJsonObject {
            put("recoveryID", recoveryID); put("sourcePath", sourcePath)
            put("byteCount", data.size); put("sha256", expected)
        })
        fun verified(value: JsonObject): String {
            if (!value.flag("preserved") || value.integer("byteCount") != data.size || value.string("sha256") != expected)
                throw Failure("recoveryNotVerified")
            val path = value.string("path")
            val prefix = "Recovered Drafts/" + UUID.fromString(recoveryID).toString().uppercase(java.util.Locale.ROOT) + "."
            if (!path.startsWith(prefix) || !path.removePrefix(prefix).matches(Regex("[a-z0-9]{1,16}")))
                throw Failure("recoveryNotVerified")
            return path
        }
        if ((begun["preserved"] as? JsonPrimitive)?.booleanOrNull == true) return verified(begun)
        val handle = begun.string("handle")
        var preserved = false
        try {
            var offset = begun.integer("nextOffset")
            if (offset !in 0..data.size) throw Failure("invalidUploadOffset")
            while (offset < data.size) {
                val end = minOf(data.size, offset + CHUNK_BYTES)
                val value = request("appendProjectionRecovery", buildJsonObject {
                    put("handle", handle); put("offset", offset)
                    put("bytes", Base64.getEncoder().encodeToString(data.copyOfRange(offset, end)))
                })
                if (value.integer("nextOffset") != end) throw Failure("invalidUploadOffset")
                offset = end
            }
            val path = verified(request("commitProjectionRecovery", buildJsonObject { put("handle", handle) }))
            preserved = true
            return path
        } finally {
            if (!preserved && admitted()) withContext(NonCancellable) {
                withTimeoutOrNull(5_000) {
                    runCatching { request("cancelProjectionRecovery", buildJsonObject { put("handle", handle) }) }
                }
            }
        }
    }

    suspend fun forkDraft(documentID: String, revision: String, destination: String? = null,
                          discardAfterCopy: Boolean = false): JsonObject = request("forkDraft", buildJsonObject {
        put("documentID", documentID); put("revision", revision)
        destination?.let { put("destination", it) }
        if (discardAfterCopy) put("discardAfterCopy", true)
    })

    private fun strictUTF8(text: String): ByteArray = try {
        val encoded = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(text))
        ByteArray(encoded.remaining()).also { encoded.get(it) }
    } catch (_: java.nio.charset.CharacterCodingException) { throw Failure("invalidUTF8") }

    private fun JsonObject.string(key: String): String =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull ?: throw Failure("invalidReply")
    private fun JsonObject.integer(key: String): Int =
        (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: throw Failure("invalidReply")
    private fun JsonObject.flag(key: String): Boolean =
        (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: throw Failure("invalidReply")

    companion object {
        /** Resolve the REAL original workspace association already projected
         * by conversation.get. The selected project in a composer is not
         * authority for an existing task. No first-project/default fallback.
         */
        suspend fun bind(host: RuntimeHost, taskID: String,
                         isCurrentOwner: () -> Boolean): G04WorkspaceBridgeClient =
            bindInternal(host, taskID, true, isCurrentOwner)

        suspend fun bindExisting(host: RuntimeHost, taskID: String,
                                 isCurrentOwner: () -> Boolean): G04WorkspaceBridgeClient =
            bindInternal(host, taskID, false, isCurrentOwner)

        private suspend fun bindInternal(host: RuntimeHost, taskID: String, createIfMissing: Boolean,
                                         isCurrentOwner: () -> Boolean): G04WorkspaceBridgeClient {
            val requestedTask = try { UUID.fromString(taskID) }
                catch (_: IllegalArgumentException) { throw Failure("invalidTask") }
            if (!requestedTask.toString().equals(taskID, ignoreCase = true)) throw Failure("invalidTask")
            val generation = host.commandClient.generation()
            val epoch = host.nativeRootEpoch() ?: throw Failure("ownerUnavailable")
            fun current(): Boolean = isCurrentOwner() && host.readiness.value.storeReady &&
                host.commandClient.generation() == generation && host.nativeRootEpoch() == epoch &&
                (host.readiness.value.domains["workspaceDomain"] as? RuntimeHostReadiness.DomainReadiness.Available)
                    ?.generation == generation
            if (!current()) throw Failure("ownerUnavailable")
            coroutineContext.ensureActive()
            fun JsonObject.field(name: String): String = (this[name] as? JsonPrimitive)
                ?.takeIf { it.isString }?.contentOrNull ?: throw Failure("invalidBinding")
            fun decode(outcome: HostOperationOutcome): JsonObject = when (outcome) {
                is HostOperationOutcome.Completed -> outcome.value as? JsonObject ?: throw Failure("invalidBinding")
                is HostOperationOutcome.Rejected -> throw Failure(outcome.code)
                is HostOperationOutcome.Failed -> throw Failure(outcome.detail["wire"] ?: outcome.code)
                HostOperationOutcome.Cancelled -> throw Failure("cancelled")
                HostOperationOutcome.Superseded -> throw Failure("superseded")
            }
            suspend fun readTask(): JsonObject {
                if (!current()) throw Failure("ownerChanged")
                val result = CompletableDeferred<HostOperationOutcome>()
                host.trackOperation(HostCommandRequest(command = "conversation.get",
                    scope = HostScope.ConversationLifecycle(taskID), stateful = false,
                    correlationID = "workspace-bind:${UUID.randomUUID()}"),
                    onTerminal = { result.complete(it) })
                val reply = decode(result.await())
                if (!current()) throw Failure("ownerChanged")
                val actualTask = try { UUID.fromString(reply.field("conversationID")) }
                    catch (_: IllegalArgumentException) { throw Failure("invalidBinding") }
                if (actualTask != requestedTask || reply.field("purpose") != "ordinary") throw Failure("ownerChanged")
                return reply
            }
            var workspace = readTask()["workspace"] as? JsonObject
            if (workspace == null) {
                if (!createIfMissing) throw Failure("workspaceUnbound")
                val activated = CompletableDeferred<HostOperationOutcome>()
                if (!current()) throw Failure("ownerChanged")
                host.trackOperation(HostCommandRequest(command = "workspace.activate",
                    scope = HostScope.ConversationLifecycle(taskID), stateful = false,
                    correlationID = "workspace-activate:${UUID.randomUUID()}",
                    payload = buildJsonObject { put("nativeEpoch", epoch.toString()) }),
                    onTerminal = { activated.complete(it) })
                val activation = decode(activated.await())
                if (!current()) throw Failure("ownerChanged")
                // Confirm the actual persisted association after activation;
                // the route never adopts a response-only local workspace.
                workspace = readTask()["workspace"] as? JsonObject ?: throw Failure("workspaceUnbound")
                if (workspace.field("workspaceID") != activation.field("workspaceID")) throw Failure("ownerChanged")
            }
            val workspaceID = workspace.field("workspaceID")
            val parsedWorkspace = try { UUID.fromString(workspaceID) }
                catch (_: IllegalArgumentException) { throw Failure("invalidBinding") }
            if (!parsedWorkspace.toString().equals(workspaceID, ignoreCase = true)) throw Failure("invalidBinding")
            return G04WorkspaceBridgeClient(host, taskID, workspaceID, generation, epoch, isCurrentOwner)
        }
        const val CHUNK_BYTES = 24 * 1024
        const val MAX_DOCUMENT_BYTES = 4 * 1024 * 1024
        const val MAX_DIFF_BYTES = 17 * 1024 * 1024
        const val MAX_QUERY_BYTES = 4 * 1024 * 1024
        private val QUERY_OPERATIONS = setOf("list", "search", "findFileNames", "tabs", "move", "gitQuery", "gitMutate")
        val READ_OPERATIONS = setOf("list", "search", "findFileNames", "metadata", "tabs", "open",
            "beginContent", "readContent", "releaseContent", "find", "queryContent", "releaseQuery", "gitQuery")
        val WRITE_OPERATIONS = setOf("beginProjectionRecovery", "appendProjectionRecovery", "commitProjectionRecovery", "cancelProjectionRecovery", "createFile", "createDirectory", "move", "copy", "delete", "edit", "selection", "replace",
            "beginEditUpload", "appendEditUpload", "commitEditUpload", "cancelEditUpload", "undo", "redo", "save",
            "resolveConflictUsingDraft", "close", "forkDraft", "gitMutate")
        private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        private fun validDigest(text: String): Boolean = text.length == 64 && text.all { it in '0'..'9' || it in 'a'..'f' }
    }
}
