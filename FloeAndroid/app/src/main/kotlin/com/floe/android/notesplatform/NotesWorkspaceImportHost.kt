// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import com.floe.android.bridge.WorkspaceSourceNative
import com.floe.android.feature.notes.NotesProtocol
import com.floe.android.feature.notes.ui.api.NotesPickedFile
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesPortFailureException
import com.floe.android.feature.notes.ui.api.NotesWorkspaceEntry
import com.floe.android.feature.notes.ui.api.NotesWorkspaceImportPort
import com.floe.android.feature.notes.ui.api.NotesWorkspacePage
import com.floe.android.feature.notes.ui.api.NotesWorkspaceScope
import com.floe.android.feature.notes.ui.api.NotesWorkspaceScopePage
import com.floe.android.host.ConversationWire
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostOperationOutcome
import com.floe.android.host.HostScope
import com.floe.android.host.RuntimeHost
import com.floe.android.host.SourceHostReply
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Real Notes workspace-file source over the App's EXISTING private-task
 * workspace authority.
 *
 * There is no new file index, no arbitrary `File(path)` reader and no SAF
 * picker here:
 *
 *  * scopes come from the durable `conversation.list` page (the same task list
 *    the sidebar renders) and use the REAL native keyset cursor for older
 *    tasks; no fabricated refresh/rename workaround;
 *  * a scope's workspace is resolved by the ORIGINAL `conversation.get` +
 *    accepted workspace store through [G04WorkspaceBridgeClient.bindExisting],
 *    which does not create or re-point a workspace;
 *  * directory listing goes through `workspace.read/list` over the original
 *    `WorkspaceFileService` guard;
 *  * file bytes come from the trusted native egress lane
 *    (`WorkspaceSourceNative.egressOpen/Info/Read/Close`), the same lane used
 *    by `WorkspaceOfficeSnapshotStager`. The native coordinator freezes one
 *    exact privateTask working copy under a real conversation-owned lease and
 *    hashes it; Kotlin never reads a filesystem path directly.
 *
 * Root lifecycle: [prepareForRootStop] sets the local RootStopping gate BEFORE
 * the native epoch changes, closes every open read handle and waits for all
 * admitted list/open/read work to drain. [abortRootStop] re-arms the SAME
 * root after a refused stop; [resumeAfterRootChange] admits the new root.
 * This is the existing Notes platform lifecycle, not a parallel permission
 * system.
 *
 * Every call captures the task id, native epoch and host generation. Reads
 * re-check them (and the local stopping gate) before/after each bounded chunk;
 * a retired root or a temporary owner returns typed cancellation and no
 * bytes. The ticket is closed exactly once on every success, cancellation and
 * failure path.
 */
internal class NotesWorkspaceImportHost(
    private val host: RuntimeHost,
) : NotesWorkspaceImportPort {
    private val ioDispatcher: CoroutineDispatcher = host.ioDispatcher
    private val gate = Mutex()
    private val active = AtomicInteger(0)
    private val handles = ConcurrentHashMap.newKeySet<WorkspaceReadHandle>()

    @Volatile
    private var stopping = false

    override suspend fun scopes(pageToken: String?): NotesWorkspaceScopePage = admit {
        withContext(ioDispatcher) {
            val epoch = runtimeEpoch()
            val generation = host.commandClient.generation()
            val outcome = conversationList(pageToken)
            if (stopping || host.nativeRootEpoch() != epoch || host.commandClient.generation() != generation) {
                throw portFailure(NotesPortFailure.CANCELLED, "ownerChanged")
            }
            val value = when (outcome) {
                is HostOperationOutcome.Completed ->
                    outcome.value ?: throw portFailure(NotesPortFailure.FAILED, "invalidWorkspaceList")
                is HostOperationOutcome.Rejected ->
                    throw portFailure(NotesPortFailure.UNAVAILABLE, outcome.code)
                is HostOperationOutcome.Failed ->
                    throw portFailure(NotesPortFailure.FAILED, outcome.detail["wire"] ?: outcome.code)
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded ->
                    throw portFailure(NotesPortFailure.CANCELLED, "superseded")
            }
            val page = ConversationWire.decodeConversationList(value)
                ?: throw portFailure(NotesPortFailure.FAILED, "invalidWorkspaceList")
            val root = value as? JsonObject
            val hasMore = root?.flag("hasMore") ?: false
            val next = if (hasMore) {
                root?.string("nextCursor")?.takeIf { it.isNotBlank() }
            } else {
                null
            }
            NotesWorkspaceScopePage(
                scopes = (page.active + page.archived)
                    .mapNotNull { item ->
                        val id = item.id.trim()
                        if (id.isEmpty() || !canonicalTask(id)) return@mapNotNull null
                        NotesWorkspaceScope(
                            id = id,
                            title = item.title.trim().ifBlank { id },
                            isArchived = item.isArchived,
                        )
                    }
                    .distinctBy { it.id },
                nextPageToken = next,
            )
        }
    }

    override suspend fun list(
        scope: NotesWorkspaceScope,
        relativePath: String,
        pageToken: String?,
    ): NotesWorkspacePage = admit {
        val path = normalizedPath(relativePath)
            ?: throw portFailure(NotesPortFailure.UNSUPPORTED, "invalidPath")
        if (!canonicalTask(scope.id)) throw portFailure(NotesPortFailure.NOT_FOUND, "invalidScope")
        val client = try {
            bind(scope)
        } catch (error: NotesPortFailureException) {
            if (error.failure.detail == "workspaceUnbound") {
                return@admit NotesWorkspacePage(entries = emptyList(), nextPageToken = null, exists = false)
            }
            throw error
        }
        try {
            // LIVE directory page from the same privateTask working copy the
            // existing Workspace Files inspector reads. This is deliberately
            // NOT the snapshot created only by `egressOpen`; a file written in
            // a terminal guest is not claimed here until the existing runtime
            // export/session lifecycle commits it into this working copy.
            val reply = client.request(
                "list",
                buildJsonObject {
                    put("path", path)
                    pageToken?.takeIf { it.isNotBlank() }?.let { put("pageToken", it) }
                },
            )
            if (stopping) throw portFailure(NotesPortFailure.CANCELLED, "rootStopping")
            val entries = (reply["entries"] as? JsonArray).orEmpty().mapNotNull { element ->
                val row = element as? JsonObject ?: return@mapNotNull null
                val relative = row.string("relativePath") ?: return@mapNotNull null
                if (!validRelativePath(relative)) return@mapNotNull null
                val directory = row.flag("isDirectory")
                NotesWorkspaceEntry(
                    name = row.string("name") ?: relative.substringAfterLast('/'),
                    relativePath = relative,
                    isDirectory = directory,
                    byteCount = if (directory) 0L else (row.long("size") ?: 0L).coerceAtLeast(0L),
                )
            }
            NotesWorkspacePage(
                entries = entries,
                nextPageToken = reply.string("nextPageToken")?.takeIf { it.isNotBlank() },
                exists = true,
            )
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (failure: G04WorkspaceBridgeClient.Failure) {
            when (failure.code) {
                "workspaceUnbound" -> NotesWorkspacePage(entries = emptyList(), exists = false)
                "notFound" -> if (path == ".") {
                    NotesWorkspacePage(entries = emptyList(), exists = true)
                } else {
                    throw portFailure(NotesPortFailure.NOT_FOUND, "directoryNotFound")
                }
                "ownerChanged", "ownerUnavailable", "retired", "cancelled", "superseded" ->
                    throw portFailure(NotesPortFailure.CANCELLED, failure.code)
                else -> throw portFailure(NotesPortFailure.FAILED, failure.code)
            }
        }
    }

    override suspend fun open(
        scope: NotesWorkspaceScope,
        relativePath: String,
    ): NotesPickedFile = admit {
        val path = normalizedPath(relativePath)
            ?: throw portFailure(NotesPortFailure.UNSUPPORTED, "invalidPath")
        if (path == ".") throw portFailure(NotesPortFailure.UNSUPPORTED, "directoryNotImportable")
        if (!canonicalTask(scope.id)) throw portFailure(NotesPortFailure.NOT_FOUND, "invalidScope")
        val fileName = path.substringAfterLast('/')
        if (!validFileName(fileName)) throw portFailure(NotesPortFailure.UNSUPPORTED, "invalidFileName")
        val mediaType = NotesPlatformNames.mimeFor(fileName)
        val maxBytes = importCap(fileName)

        // bindExisting resolves the persisted association and never creates a
        // workspace. It also revalidates purpose/owner inside the native lane.
        val workspaceID = bind(scope).workspaceID
        val epoch = runtimeEpoch()
        val generation = host.commandClient.generation()
        val taskID = scope.id
        val ownerCurrent: () -> Boolean = {
            !stopping &&
                host.nativeRootEpoch() == epoch &&
                host.commandClient.generation() == generation &&
                host.readiness.value.storeReady &&
                host.conversations.entryFor(taskID)?.isTemporary != true &&
                host.conversations.entryFor(taskID)?.holder?.retired != true
        }

        withContext(ioDispatcher) {
            currentCoroutineContext().ensureActive()
            if (!ownerCurrent()) throw portFailure(NotesPortFailure.CANCELLED, "ownerChanged")
            val ticket = try {
                WorkspaceSourceNative.egressOpen(epoch, "export", taskID, workspaceID, path, "")
            } catch (_: LinkageError) {
                throw portFailure(NotesPortFailure.NOT_CONFIGURED, "workspaceEgressUnavailable")
            }
            if (ticket <= 0L) throw nativeFailure(ticket)
            var handedOff = false
            try {
                val info = SourceHostReply.call { WorkspaceSourceNative.egressInfo(ticket, it) }
                if (!info.ok) {
                    when (info.status) {
                        -501 -> throw portFailure(NotesPortFailure.NOT_CONFIGURED, "workspaceNotInstalled")
                        -502 -> throw portFailure(NotesPortFailure.CANCELLED, "workspaceRootChanged")
                        else -> throw portFailure(
                            NotesPortFailure.FAILED,
                            info.errorCode.ifBlank { "workspaceSnapshotRefused" },
                        )
                    }
                }
                val bytes = info.number("bytes")
                    ?: throw portFailure(NotesPortFailure.FAILED, "workspaceSizeMissing")
                val sha = info.text("sha256")
                if (info.text("mode") != "export" || info.text("logicalPath") != path) {
                    throw portFailure(NotesPortFailure.FAILED, "invalidWorkspaceSnapshot")
                }
                if (bytes <= 0L || bytes > maxBytes) {
                    throw portFailure(
                        if (bytes > maxBytes) NotesPortFailure.UNSUPPORTED else NotesPortFailure.FAILED,
                        "contentTooLarge",
                    )
                }
                if (!HEX_DIGEST.matches(sha)) {
                    throw portFailure(NotesPortFailure.FAILED, "invalidWorkspaceDigest")
                }
                currentCoroutineContext().ensureActive()
                if (!ownerCurrent()) throw portFailure(NotesPortFailure.CANCELLED, "ownerChanged")
                val handle = WorkspaceReadHandle(
                    ticket = ticket,
                    byteCount = bytes,
                    ownerCurrent = ownerCurrent,
                )
                gate.withLock {
                    if (stopping) {
                        handle.close()
                        throw portFailure(NotesPortFailure.CANCELLED, "rootStopping")
                    }
                    handles.add(handle)
                }
                handedOff = true
                NotesPickedFile(
                    fileName = fileName,
                    mediaType = mediaType,
                    byteCount = bytes,
                    read = { offset, maxBytes -> handle.read(offset, maxBytes) },
                    close = handle::close,
                )
            } finally {
                if (!handedOff) runCatching { WorkspaceSourceNative.egressClose(ticket) }
            }
        }
    }

    override suspend fun prepareForRootStop(epoch: Long): Boolean {
        if (epoch <= 0L) return true
        gate.withLock {
            stopping = true
            handles.toList().forEach { it.close() }
        }
        val deadline = System.nanoTime() + STOP_DRAIN_NANOS
        while (active.get() > 0 && System.nanoTime() < deadline) delay(10)
        return active.get() == 0
    }

    override suspend fun abortRootStop(epoch: Long) {
        gate.withLock {
            if (epoch <= 0L || host.nativeRootEpoch() == epoch) stopping = false
        }
    }

    override suspend fun resumeAfterRootChange(epoch: Long) {
        gate.withLock { stopping = false }
    }

    override fun close() {
        stopping = true
        handles.toList().forEach { it.close() }
    }

    private suspend fun <T> admit(block: suspend () -> T): T {
        gate.withLock {
            if (stopping) throw portFailure(NotesPortFailure.CANCELLED, "rootStopping")
            active.incrementAndGet()
        }
        try {
            return block()
        } finally {
            active.decrementAndGet()
        }
    }

    private fun runtimeEpoch(): Long {
        val epoch = host.nativeRootEpoch()
            ?: throw portFailure(NotesPortFailure.NOT_CONFIGURED, "runtimeUnavailable")
        if (epoch <= 0L || !host.readiness.value.storeReady) {
            throw portFailure(NotesPortFailure.NOT_CONFIGURED, "runtimeUnavailable")
        }
        return epoch
    }

    private suspend fun conversationList(pageToken: String?): HostOperationOutcome {
        val terminal = CompletableDeferred<HostOperationOutcome>()
        try {
            host.trackOperation(
                HostCommandRequest(
                    command = "conversation.list",
                    scope = HostScope.ApplicationConfiguration("conversations"),
                    stateful = false,
                    correlationID = host.commandClient.correlationID("notes-workspace-list"),
                    payload = buildJsonObject {
                        put("includeArchived", true)
                        put("limit", 50)
                        pageToken?.takeIf { it.isNotBlank() }?.let { put("cursor", it) }
                    },
                ),
                onTerminal = { value -> terminal.complete(value) },
            )
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            throw portFailure(NotesPortFailure.UNAVAILABLE, "workspaceListUnavailable")
        }
        return withTimeoutOrNull(LIST_TIMEOUT_MILLIS) { terminal.await() }
            ?: throw portFailure(NotesPortFailure.FAILED, "workspaceListTimeout")
    }

    private suspend fun bind(scope: NotesWorkspaceScope): G04WorkspaceBridgeClient {
        val epoch = runtimeEpoch()
        val generation = host.commandClient.generation()
        val taskID = scope.id
        val current = {
            !stopping &&
                host.nativeRootEpoch() == epoch &&
                host.commandClient.generation() == generation &&
                host.readiness.value.storeReady &&
                host.conversations.entryFor(taskID)?.isTemporary != true &&
                host.conversations.entryFor(taskID)?.holder?.retired != true
        }
        if (!current()) throw portFailure(NotesPortFailure.CANCELLED, "ownerUnavailable")
        return try {
            G04WorkspaceBridgeClient.bindExisting(host, taskID, current)
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (failure: G04WorkspaceBridgeClient.Failure) {
            when (failure.code) {
                "workspaceUnbound" -> throw portFailure(NotesPortFailure.NOT_FOUND, "workspaceUnbound")
                "ownerChanged", "ownerUnavailable", "retired", "cancelled", "superseded" ->
                    throw portFailure(NotesPortFailure.CANCELLED, failure.code)
                "invalidTask", "invalidBinding" -> throw portFailure(NotesPortFailure.NOT_FOUND, failure.code)
                else -> throw portFailure(NotesPortFailure.FAILED, failure.code)
            }
        }
    }

    private fun importCap(fileName: String): Long =
        if (NotesPlatformNames.extensionOf(fileName) == "floenote") {
            minOf(NotesProtocol.MAX_ARCHIVE_BYTES, MAX_EGRESS_BYTES)
        } else {
            NotesProtocol.MAX_RESOURCE_BYTES
        }

    /**
     * One App-owned bounded read handle over a frozen native workspace
     * snapshot. `read` is random-access by offset and never buffers more than
     * one 64 KiB chunk. `close` is idempotent, removes the handle from the
     * root-stop set and releases the native snapshot exactly once.
     */
    private inner class WorkspaceReadHandle(
        private val ticket: Long,
        private val byteCount: Long,
        private val ownerCurrent: () -> Boolean,
    ) {
        private val closed = AtomicBoolean(false)

        suspend fun read(offset: Long, maxBytes: Int): ByteArray = admit {
            withContext(ioDispatcher) {
                if (closed.get()) throw portFailure(NotesPortFailure.CANCELLED, "closed")
                if (offset < 0L || offset > byteCount) {
                    throw portFailure(NotesPortFailure.FAILED, "invalidOffset")
                }
                if (offset == byteCount || maxBytes <= 0) return@withContext ByteArray(0)
                currentCoroutineContext().ensureActive()
                if (!ownerCurrent()) throw portFailure(NotesPortFailure.CANCELLED, "ownerChanged")
                val limit = minOf(maxBytes.toLong(), byteCount - offset, MAX_CHUNK_BYTES.toLong())
                    .toInt()
                    .coerceAtLeast(1)
                val buffer = ByteArray(limit)
                val copied = try {
                    WorkspaceSourceNative.egressRead(ticket, offset, buffer)
                } catch (_: LinkageError) {
                    throw portFailure(NotesPortFailure.NOT_CONFIGURED, "workspaceReadUnavailable")
                }
                if (copied < 0) throw nativeFailure(copied.toLong())
                if (copied == 0) throw portFailure(NotesPortFailure.FAILED, "shortRead")
                if (copied > limit) throw portFailure(NotesPortFailure.FAILED, "invalidChunk")
                if (!ownerCurrent()) throw portFailure(NotesPortFailure.CANCELLED, "ownerChanged")
                buffer.copyOf(copied)
            }
        }

        fun close() {
            if (!closed.compareAndSet(false, true)) return
            handles.remove(this)
            runCatching { WorkspaceSourceNative.egressClose(ticket) }
        }
    }

    private companion object {
        private const val MAX_EGRESS_BYTES: Long = 1L shl 30
        private const val LIST_TIMEOUT_MILLIS: Long = 15_000L
        private const val STOP_DRAIN_NANOS: Long = 5_000_000_000L
        private val HEX_DIGEST = Regex("^[0-9a-f]{64}$")
    }
}

private const val MAX_CHUNK_BYTES: Int = 64 * 1024

private fun normalizedPath(raw: String): String? {
    val trimmed = raw.trim()
    if (trimmed.isEmpty() || trimmed == ".") return "."
    if (trimmed.length > 4096 || trimmed.startsWith("/") || trimmed.startsWith("~") ||
        trimmed.contains('\\')
    ) {
        return null
    }
    val parts = trimmed.split('/')
    if (parts.any { it.isEmpty() || it == "." || it == ".." }) return null
    return parts.joinToString("/")
}

private fun validRelativePath(raw: String): Boolean {
    if (raw.isEmpty() || raw.length > 4096 || raw.startsWith("/") || raw.startsWith("~") ||
        raw.contains('\\')
    ) {
        return false
    }
    return raw.split('/').all { it.isNotEmpty() && it != "." && it != ".." }
}

private fun validFileName(name: String): Boolean =
    name.isNotBlank() && name.length <= 255 && name != "." && name != ".." &&
        !name.contains('/') && !name.contains('\\') && name.none { it.code < 32 }

private fun canonicalTask(value: String): Boolean =
    runCatching { UUID.fromString(value).toString().equals(value, ignoreCase = true) }.getOrDefault(false)

private fun portFailure(code: String, detail: String? = null): NotesPortFailureException =
    NotesPortFailureException(NotesPortFailure(code, detail))

private fun nativeFailure(status: Long): NotesPortFailureException {
    val (code, detail) = when (status) {
        -501L -> NotesPortFailure.NOT_CONFIGURED to "workspaceNotInstalled"
        -502L -> NotesPortFailure.CANCELLED to "workspaceRootChanged"
        -503L -> NotesPortFailure.FAILED to "workspaceSessionUnknown"
        -504L -> NotesPortFailure.FAILED to "workspaceStateConflict"
        -505L -> NotesPortFailure.PERMISSION_DENIED to "workspaceIdentityRefused"
        -506L -> NotesPortFailure.NOT_FOUND to "workspaceFileMissing"
        -507L -> NotesPortFailure.FAILED to "workspaceStaleRevision"
        -508L -> NotesPortFailure.BUSY to "workspaceBusy"
        -509L -> NotesPortFailure.UNSUPPORTED to "contentTooLarge"
        -510L -> NotesPortFailure.UNSUPPORTED to "contentTooLarge"
        -511L -> NotesPortFailure.FAILED to "storageUnavailable"
        -512L -> NotesPortFailure.BUSY to "workspaceBusy"
        -513L -> NotesPortFailure.FAILED to "writeUnavailable"
        -514L -> NotesPortFailure.FAILED to "readFailed"
        -515L -> NotesPortFailure.FAILED to "digestMismatch"
        -516L -> NotesPortFailure.UNAVAILABLE to "workspaceTransportUnavailable"
        -517L -> NotesPortFailure.FAILED to "workspaceProviderFailed"
        -518L -> NotesPortFailure.FAILED to "workspaceTimeout"
        -599L -> NotesPortFailure.FAILED to "workspaceInternal"
        else -> NotesPortFailure.FAILED to "workspaceFailure"
    }
    return portFailure(code, detail)
}

private fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

private fun JsonObject.flag(key: String): Boolean =
    (this[key] as? JsonPrimitive)?.booleanOrNull ?: false

private fun JsonObject.long(key: String): Long? =
    (this[key] as? JsonPrimitive)?.longOrNull
