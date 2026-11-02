// SPDX-License-Identifier: MPL-2.0
//
// Application-owned archive document controller (WSF-SAFE-EXTRACT).
//
// The full-window archive browser is a thin renderer over this controller.
// The controller owns ONLY the trusted `floe.archive/25` bridge calls, the
// long-running extract/decompress job, its real cancellation and progress
// poller, and the typed state the Compose surface renders. Every archive
// effect happens inside the task workspace in the Swift core over the
// ORIGINAL `G04WorkspaceAccessPort` lease: there is no UI-global root, no
// buffered replay and no second engine on this side of the bridge.
//
// Lifecycle: created lazily by RuntimeHost on the first explicit archive
// open (Main's bounded integration patch). Listing/extract jobs outlive the
// Compose view; `prepareForRootStop` drains them before the native root
// retires. A cancelled or failed extract never reports success — the engine
// commits no partial output (staged no-overwrite commit).
package com.floe.android.host

import com.floe.android.bridge.SwiftCore
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** The bounded archive formats the ORIGINAL service browses natively. */
internal enum class WorkspaceArchiveFormatKind { CONTAINER, SINGLE_FILE }

internal object WorkspaceArchiveFormat {
    internal fun formatFor(relativePath: String): String? {
        val lower = relativePath.lowercase()
        if (lower.endsWith(".tar.gz") || lower.endsWith(".tgz")) return "tgz"
        if (lower.endsWith(".tar.bz2") || lower.endsWith(".tbz2")) return "tbz2"
        if (lower.endsWith(".tar.xz") || lower.endsWith(".txz")) return "txz"
        val name = relativePath.substringAfterLast('/')
        val dot = name.lastIndexOf('.')
        if (dot <= 0 || dot == name.length - 1) return null
        return name.substring(dot + 1).lowercase()
    }

    internal fun kind(format: String): WorkspaceArchiveFormatKind? = when (format) {
        "zip", "tar", "tgz", "tbz2", "txz", "7z" -> WorkspaceArchiveFormatKind.CONTAINER
        "gz", "bz2", "xz" -> WorkspaceArchiveFormatKind.SINGLE_FILE
        else -> null
    }

    internal fun kindForPath(relativePath: String): WorkspaceArchiveFormatKind? =
        formatFor(relativePath)?.let(::kind)

    /** Container extraction target, mirroring the original browser:
     *  `<stem>-unpacked` beside the archive. */
    internal fun extractDestinationFor(relativePath: String): String {
        val name = relativePath.substringAfterLast('/')
        val stem = name.substringBeforeLast('.', "")
        return "${if (stem.isEmpty()) "archive" else stem}-unpacked"
    }

    /** Single-file decompression target, mirroring `ArchiveEngine
     * .decompressedName` + the original `.unpacked` fallback. */
    internal fun decompressDestinationFor(relativePath: String): String {
        val name = relativePath.substringAfterLast('/')
        val format = formatFor(relativePath) ?: return "$name.unpacked"
        val suffix = ".$format"
        if (!name.lowercase().endsWith(suffix)) return "$name.unpacked"
        val stem = name.dropLast(suffix.length)
        return if (stem.isEmpty()) "$name.unpacked" else stem
    }
}

/** One flattened archive row rebuilt into the original directory tree. */
internal data class ArchiveTreeNode(
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    val size: Long,
    val children: List<ArchiveTreeNode>?,
) {
    internal companion object {
        /** Directories first, then localized name order — the exact
         *  presentation rule of the original `ArchiveNode.tree`. Entries
         *  whose path escapes the archive (`.`, `..`, empty parts) never
         *  become rows even though the engine already refused them. */
        internal fun fromEntries(
            entries: List<Triple<String, Boolean, Long>>,
        ): List<ArchiveTreeNode> {
            class Builder(
                val name: String,
                val path: String,
                var isDirectory: Boolean = true,
                var size: Long = 0,
                val children: MutableMap<String, Builder> = LinkedHashMap(),
            )

            val root = Builder(name = "", path = "")
            for ((rawPath, isDirectory, size) in entries) {
                val parts = rawPath
                    .replace('\\', '/')
                    .split('/')
                    .filter { it.isNotEmpty() && it != "." }
                if (parts.isEmpty() || parts.contains("..")) continue
                var cursor = root
                parts.forEachIndexed { index, part ->
                    val leaf = index == parts.lastIndex
                    val childPath = if (cursor.path.isEmpty()) part else "${cursor.path}/$part"
                    val child = cursor.children.getOrPut(part) { Builder(part, childPath) }
                    if (leaf) {
                        child.isDirectory = isDirectory
                        child.size = size
                    }
                    cursor = child
                }
            }

            fun build(builder: Builder): ArchiveTreeNode {
                val ordered = builder.children.values
                    .sortedWith(compareByDescending<Builder> { it.isDirectory }
                        .thenBy { it.name.lowercase() })
                    .map(::build)
                return ArchiveTreeNode(
                    name = builder.name,
                    path = builder.path,
                    isDirectory = builder.isDirectory,
                    size = builder.size,
                    children = ordered.ifEmpty { null },
                )
            }
            return root.children.values
                .sortedWith(compareByDescending<Builder> { it.isDirectory }
                    .thenBy { it.name.lowercase() })
                .map(::build)
        }
    }
}

internal data class ArchiveDocumentEntry(
    val path: String,
    val isDirectory: Boolean,
    val size: Long,
)

internal data class ArchiveDocumentListing(
    val format: String,
    val entries: List<ArchiveDocumentEntry>,
    val truncated: Boolean,
    val entryCount: Int,
    val summary: String,
)

internal data class ArchiveExtractReceipt(
    val destination: String,
    val summary: String,
    val entries: Int,
    val skipped: Int,
    val uncompressedBytes: Long,
)

internal data class ArchiveProgressSnapshot(
    val phase: String,
    val completedBytes: Long,
    val totalBytes: Long?,
    val completedEntries: Int,
    val cancelled: Boolean,
)

internal enum class ArchiveFailure {
    /** The captured task/workspace/epoch/generation retired or the task is
     *  temporary. */
    OWNER,

    /** The format is not one the original service opens (RAR reports its
     *  truthful signed-decoder reason here too). */
    UNSUPPORTED,
    NOT_FOUND,
    TOO_LARGE,
    /** The destination already exists: nothing was overwritten. */
    CONFLICT,
    CANCELLED,
    SOURCE,
    TRANSPORT,
    /** The installed core predates the archive channel. */
    NEEDS_CORE_UPDATE,
    FAILED,
}

internal sealed interface WorkspaceArchivePreviewState {
    data object Idle : WorkspaceArchivePreviewState
    data class Loading(val entryPath: String) : WorkspaceArchivePreviewState
    data class Ready(
        val entryPath: String,
        val text: String,
        val byteCount: Long,
        val truncated: Boolean,
    ) : WorkspaceArchivePreviewState

    /** Honest typed refusal (binary entry, too large to stage, …). */
    data class Unavailable(val entryPath: String, val message: String) : WorkspaceArchivePreviewState
    data class Failed(val entryPath: String, val failure: ArchiveFailure, val detail: String?) :
        WorkspaceArchivePreviewState
}

internal sealed interface WorkspaceArchiveState {
    data object Idle : WorkspaceArchiveState

    data class Listing(val token: Long, val fileName: String) : WorkspaceArchiveState

    /** The list stays visible while an extract runs and after it finishes:
     *  progress, receipt and failure are properties of the listed document,
     *  never a replacement that hides the archive. */
    data class Listed(
        val token: Long,
        val fileName: String,
        val format: String,
        val entries: List<ArchiveDocumentEntry>,
        val truncated: Boolean,
        val entryCount: Int,
        val summary: String,
        val extracting: ArchiveProgressSnapshot? = null,
        val extractReceipt: ArchiveExtractReceipt? = null,
        val extractFailure: ExtractFailure? = null,
    ) : WorkspaceArchiveState

    data class ExtractFailure(
        val failure: ArchiveFailure,
        val detail: String?,
        val retryable: Boolean,
    )

    data class ListingFailed(
        val token: Long,
        val fileName: String,
        val failure: ArchiveFailure,
        val detail: String?,
        val retryable: Boolean,
        internal val owner: Owner?,
        internal val path: String,
    ) : WorkspaceArchiveState
}

internal fun interface WorkspaceArchiveTransport {
    fun exchange(request: String): String
}

internal object SwiftWorkspaceArchiveTransport : WorkspaceArchiveTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal class WorkspaceArchiveHostFailure(val code: String) : Exception(code)

internal class WorkspaceArchiveHostClient(
    private val transport: WorkspaceArchiveTransport = SwiftWorkspaceArchiveTransport,
) {
    private val json = Json { ignoreUnknownKeys = false }

    fun handshake(): JsonObject = call(
        buildJsonObject {
            put("version", VERSION)
            put("operation", "handshake")
            put("requestID", UUID.randomUUID().toString())
        },
    )

    fun listing(owner: Owner, relativePath: String): ArchiveDocumentListing {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "g04.archive.listing")
                put("requestID", UUID.randomUUID().toString())
                putOwner(owner)
                put("relativePath", relativePath)
            },
        )
        val entries = (response["entries"] as? JsonArray ?: JsonArray(emptyList()))
            .mapNotNull { element ->
                val objectValue = element as? JsonObject ?: return@mapNotNull null
                val path = objectValue.string("path") ?: return@mapNotNull null
                ArchiveDocumentEntry(
                    path = path,
                    isDirectory = objectValue.boolean("isDirectory") == true,
                    size = objectValue.long("size") ?: 0L,
                )
            }
        return ArchiveDocumentListing(
            format = response.string("format") ?: "",
            entries = entries,
            truncated = response.boolean("truncated") == true,
            entryCount = response.int("entryCount") ?: entries.size,
            summary = response.string("summary") ?: "",
        )
    }

    fun extract(
        owner: Owner,
        relativePath: String,
        destinationDir: String,
        operationID: UUID,
    ): ArchiveExtractReceipt = call(
        buildJsonObject {
            put("version", VERSION)
            put("operation", "g04.archive.extract")
            put("requestID", UUID.randomUUID().toString())
            putOwner(owner)
            put("relativePath", relativePath)
            put("destinationDir", destinationDir)
            put("operationID", operationID.toString())
        },
    ).let(::receipt)

    fun decompress(
        owner: Owner,
        relativePath: String,
        destinationFile: String,
        operationID: UUID,
    ): ArchiveExtractReceipt = call(
        buildJsonObject {
            put("version", VERSION)
            put("operation", "g04.archive.decompress")
            put("requestID", UUID.randomUUID().toString())
            putOwner(owner)
            put("relativePath", relativePath)
            put("destinationFile", destinationFile)
            put("operationID", operationID.toString())
        },
    ).let(::receipt)

    fun previewEntry(
        owner: Owner,
        relativePath: String,
        entryPath: String,
        previewID: UUID,
    ): WorkspaceArchivePreviewState {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "g04.archive.previewEntry")
                put("requestID", UUID.randomUUID().toString())
                putOwner(owner)
                put("relativePath", relativePath)
                put("entryPath", entryPath)
                put("previewID", previewID.toString())
            },
        )
        val previewable = response.boolean("previewable") == true
        val byteCount = response.long("byteCount") ?: 0L
        val truncated = response.boolean("truncated") == true
        return if (previewable) {
            WorkspaceArchivePreviewState.Ready(
                entryPath = entryPath,
                text = response.string("text") ?: "",
                byteCount = byteCount,
                truncated = truncated,
            )
        } else {
            WorkspaceArchivePreviewState.Unavailable(entryPath, response.string("message") ?: "unavailable")
        }
    }

    fun previewDiscard(owner: Owner, previewID: UUID) {
        call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "g04.archive.previewDiscard")
                put("requestID", UUID.randomUUID().toString())
                putOwner(owner)
                put("previewID", previewID.toString())
            },
        )
    }

    fun progress(operationID: UUID): ArchiveProgressSnapshot {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "g04.archive.progress")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID.toString())
            },
        )
        return ArchiveProgressSnapshot(
            phase = response.string("phase") ?: "running",
            completedBytes = response.long("completedBytes") ?: 0L,
            totalBytes = response.long("totalBytes"),
            completedEntries = response.int("completedEntries") ?: 0,
            cancelled = response.boolean("cancelled") == true,
        )
    }

    fun cancel(operationID: UUID): Boolean {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "g04.archive.cancel")
                put("requestID", UUID.randomUUID().toString())
                put("operationID", operationID.toString())
            },
        )
        return response.boolean("cancelled") == true
    }

    private fun receipt(response: JsonObject): ArchiveExtractReceipt = ArchiveExtractReceipt(
        destination = response.string("destination") ?: "",
        summary = response.string("summary") ?: "",
        entries = response.int("entries") ?: 0,
        skipped = response.int("skipped") ?: 0,
        uncompressedBytes = response.long("uncompressedBytes") ?: 0L,
    )

    private fun call(request: JsonObject): JsonObject {
        val raw = try {
            transport.exchange(request.toString())
        } catch (error: Throwable) {
            throw WorkspaceArchiveHostFailure(
                if (error is LinkageError || error is UnsatisfiedLinkError) "coreUnavailable" else "transport")
        }
        val response = try {
            json.parseToJsonElement(raw) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw WorkspaceArchiveHostFailure("invalidResponse")
        val ok = (response["ok"] as? JsonPrimitive)?.booleanOrNull == true
        if (!ok) {
            val code = response.string("code") ?: response.string("error") ?: "refused"
            throw WorkspaceArchiveHostFailure(code)
        }
        val version = response.int("version")
        if (version != null && version != VERSION) {
            throw WorkspaceArchiveHostFailure("unsupportedVersion")
        }
        return response
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.intOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull

    private fun JsonObject.boolean(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObjectBuilder.putOwner(owner: Owner) {
        put("owner", buildJsonObject {
            put("taskID", owner.taskID)
            put("workspaceID", owner.workspaceID)
            put("nativeEpoch", owner.nativeEpoch)
            put("hostGeneration", owner.hostGeneration)
        })
    }

    companion object {
        const val VERSION = 25
    }
}

internal class WorkspaceArchiveHostController(
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val currentNativeEpoch: () -> Long?,
    private val currentHostGeneration: () -> Long,
    private val isTemporaryTask: (String) -> Boolean,
    private val client: WorkspaceArchiveHostClient = WorkspaceArchiveHostClient(),
    private val pollIntervalMillis: Long = 250L,
) {
    private val lock = Any()
    private val mutableState = MutableStateFlow<WorkspaceArchiveState>(WorkspaceArchiveState.Idle)
    private val mutablePreview = MutableStateFlow<WorkspaceArchivePreviewState>(WorkspaceArchivePreviewState.Idle)
    private val jobs = ConcurrentHashMap.newKeySet<Job>()
    private var active: ActiveSession? = null
    private var previewID: UUID? = null
    private var inflightOperationID: UUID? = null

    val state: StateFlow<WorkspaceArchiveState> get() = mutableState
    val preview: StateFlow<WorkspaceArchivePreviewState> get() = mutablePreview

    private data class ActiveSession(
        val token: Long,
        val owner: Owner,
        val relativePath: String,
        val format: String,
    )

    fun open(owner: Owner, relativePath: String, token: Long): Boolean {
        val format = WorkspaceArchiveFormat.formatFor(relativePath)
        val kind = format?.let(WorkspaceArchiveFormat::kind)
        if (!ownerCurrent(owner)) {
            publishListingFailure(owner, relativePath, format, ArchiveFailure.OWNER,
                detail = "owner", retryable = false, token = token)
            return false
        }
        if (format == null || kind == null) {
            publishListingFailure(owner, relativePath, format, ArchiveFailure.UNSUPPORTED,
                detail = format ?: "extension", retryable = false, token = token)
            return false
        }
        synchronized(lock) {
            val existing = active
            if (existing != null && existing.token == token &&
                existing.owner == owner && existing.relativePath == relativePath &&
                mutableState.value !is WorkspaceArchiveState.ListingFailed
            ) {
                // Rotation/recomposition reuses the live session; a failed
                // listing never reuses it (retry must re-dispatch).
                return true
            }
            existing?.let { retireLocked(it) }
            discardPreviewStagingLocked()
            val created = ActiveSession(token, owner, relativePath, format)
            active = created
            mutableState.value = WorkspaceArchiveState.Listing(token, fileName(relativePath))
            mutablePreview.value = WorkspaceArchivePreviewState.Idle
            previewID = UUID.randomUUID()
            trackJob(scope.launch(ioDispatcher) { runListing(created) })
        }
        return true
    }

    fun retry(token: Long) {
        val failed = mutableState.value as? WorkspaceArchiveState.ListingFailed ?: return
        if (failed.token != token || !failed.retryable) return
        val owner = failed.owner ?: return
        open(owner, failed.path, token)
    }

    fun close(token: Long) {
        synchronized(lock) {
            val session = active ?: return
            if (session.token != token) return
            // Discard staging while the owner identity is still available.
            discardPreviewStagingLocked()
            active = null
            previewID = null
            inflightOperationID?.let { id -> clientSafe { it.cancel(id) } }
            inflightOperationID = null
            mutableState.value = WorkspaceArchiveState.Idle
            mutablePreview.value = WorkspaceArchivePreviewState.Idle
        }
        jobs.forEach { it.cancel() }
        jobs.clear()
    }

    /** Confirmed extraction into a NEW workspace destination. The exact
     *  destination is derived here (and unit-tested) so the UI cannot pass
     *  an overwrite candidate; the engine still refuses a collision. */
    fun extractConfirmed(token: Long) {
        val session = synchronized(lock) {
            val current = active ?: return
            if (current.token != token) return
            if (mutableState.value !is WorkspaceArchiveState.Listed) return
            current
        }
        val kind = WorkspaceArchiveFormat.kind(session.format) ?: return
        val destination = when (kind) {
            WorkspaceArchiveFormatKind.CONTAINER ->
                WorkspaceArchiveFormat.extractDestinationFor(session.relativePath)
            WorkspaceArchiveFormatKind.SINGLE_FILE ->
                WorkspaceArchiveFormat.decompressDestinationFor(session.relativePath)
        }
        val operationID = UUID.randomUUID()
        synchronized(lock) {
            val listed = mutableState.value as? WorkspaceArchiveState.Listed ?: return
            inflightOperationID = operationID
            mutableState.value = listed.copy(
                extracting = ArchiveProgressSnapshot("running", 0, null, 0, false),
                extractReceipt = null,
                extractFailure = null,
            )
        }
        trackJob(scope.launch(ioDispatcher) {
            runExtract(session, destination, operationID, kind)
        })
    }

    /** Real cancellation: trips the token the engine polls and stops the
     *  local job; the typed failure the UI shows is CANCELLED, never a
     *  hidden success. */
    fun cancelExtract(token: Long) {
        val session = synchronized(lock) { active } ?: return
        if (session.token != token) return
        inflightOperationID?.let { id -> clientSafe { it.cancel(id) } }
        jobs.forEach { it.cancel() }
    }

    fun previewEntry(entryPath: String) {
        val session = synchronized(lock) { active } ?: return
        val preview = previewID ?: return
        mutablePreview.value = WorkspaceArchivePreviewState.Loading(entryPath)
        trackJob(scope.launch(ioDispatcher) {
            try {
                val result = client.previewEntry(session.owner, session.relativePath, entryPath, preview)
                mutablePreview.value = result
            } catch (failure: WorkspaceArchiveHostFailure) {
                mutablePreview.value = WorkspaceArchivePreviewState.Failed(
                    entryPath, mapFailure(failure.code), failure.code)
            }
        })
    }

    /** Closes the preview pane and drops its hidden staging through the
     *  trusted bridge; the next selection stages once more. */
    fun discardPreviewEntry() {
        synchronized(lock) {
            val session = active ?: return
            discardPreviewStagingLocked()
            previewID = UUID.randomUUID()
            mutablePreview.value = WorkspaceArchivePreviewState.Idle
            session
        }
    }

    fun prepareForRootStop(timeoutMillis: Long = 8_000L): Boolean =
        withContext(NonCancellable) {
            synchronized(lock) {
                // Discard staging while the owner identity is still available.
                discardPreviewStagingLocked()
                active = null
                previewID = null
                inflightOperationID?.let { id -> clientSafe { it.cancel(id) } }
                inflightOperationID = null
                mutableState.value = WorkspaceArchiveState.Idle
                mutablePreview.value = WorkspaceArchivePreviewState.Idle
            }
            val pending = synchronized(lock) { jobs.toList() }
            pending.forEach { it.cancel() }
            // Preview staging removal is best effort at the root-stop gate;
            // the Swift registry keeps staging under the hidden
            // `.floe-archive-preview` root and never promotes it.
            try {
                withTimeoutOrNull(timeoutMillis) {
                    pending.forEach { it.join() }
                    true
                }
            } catch (_: CancellationException) {
                false
            } ?: false
        }

    private suspend fun runListing(session: ActiveSession) {
        try {
            val listing = client.listing(session.owner, session.relativePath)
            synchronized(lock) {
                if (active?.token != session.token) return
                mutableState.value = WorkspaceArchiveState.Listed(
                    token = session.token,
                    fileName = fileName(session.relativePath),
                    format = listing.format,
                    entries = listing.entries,
                    truncated = listing.truncated,
                    entryCount = listing.entryCount,
                    summary = listing.summary,
                )
            }
        } catch (failure: WorkspaceArchiveHostFailure) {
            if (failure.code == "cancelled") return
            publishListingFailure(session.owner, session.relativePath, session.format,
                mapFailure(failure.code), detail = failure.code,
                retryable = failure.code == "transport" || failure.code == "failed",
                token = session.token)
        }
    }

    private suspend fun runExtract(
        session: ActiveSession,
        destination: String,
        operationID: UUID,
        kind: WorkspaceArchiveFormatKind,
    ) {
        val poller = scope.launch(ioDispatcher) {
            while (true) {
                delay(pollIntervalMillis)
                val snapshot = runCatching { client.progress(operationID) }.getOrNull() ?: continue
                synchronized(lock) {
                    val listed = mutableState.value as? WorkspaceArchiveState.Listed ?: return@synchronized
                    if (active?.token != session.token) return@synchronized
                    mutableState.value = listed.copy(extracting = snapshot)
                }
            }
        }
        try {
            val receipt = when (kind) {
                WorkspaceArchiveFormatKind.CONTAINER ->
                    client.extract(session.owner, session.relativePath, destination, operationID)
                WorkspaceArchiveFormatKind.SINGLE_FILE ->
                    client.decompress(session.owner, session.relativePath, destination, operationID)
            }
            synchronized(lock) {
                if (active?.token != session.token) return
                val listed = mutableState.value as? WorkspaceArchiveState.Listed ?: return
                inflightOperationID = null
                mutableState.value = listed.copy(
                    extracting = null,
                    extractReceipt = receipt,
                    extractFailure = null,
                )
            }
        } catch (failure: WorkspaceArchiveHostFailure) {
            if (failure.code == "cancelled") {
                publishExtractFailure(session.token, ArchiveFailure.CANCELLED, "cancelled", retryable = false)
            } else {
                publishExtractFailure(session.token, mapFailure(failure.code), failure.code,
                    retryable = failure.code == "transport" || failure.code == "failed")
            }
        } finally {
            poller.cancel()
        }
    }

    private fun publishListingFailure(
        owner: Owner?,
        relativePath: String,
        format: String?,
        failure: ArchiveFailure,
        detail: String?,
        retryable: Boolean,
        token: Long,
    ) {
        synchronized(lock) {
            // A failure published before any session exists (stale owner,
            // unsupported extension) still renders; only a DIFFERENT live
            // session suppresses it.
            if (active != null && active?.token != token) return
            mutableState.value = WorkspaceArchiveState.ListingFailed(
                token = token,
                fileName = fileName(relativePath),
                failure = failure,
                detail = detail,
                retryable = retryable,
                owner = owner,
                path = relativePath,
            )
        }
    }

    private fun publishExtractFailure(token: Long, failure: ArchiveFailure, detail: String?, retryable: Boolean) {
        synchronized(lock) {
            val listed = mutableState.value as? WorkspaceArchiveState.Listed ?: return
            if (active?.token != token) return
            inflightOperationID = null
            mutableState.value = listed.copy(
                extracting = null,
                extractFailure = WorkspaceArchiveState.ExtractFailure(failure, detail, retryable),
            )
        }
    }

    private fun retireLocked(session: ActiveSession) {
        jobs.forEach { it.cancel() }
        jobs.clear()
    }

    /** Best-effort removal of the hidden preview staging through the
     *  trusted bridge; must be called under [lock] with [active] still set
     *  when the owner identity is needed. */
    private fun discardPreviewStagingLocked() {
        val id = previewID ?: return
        val owner = active?.owner ?: return
        clientSafe { it.previewDiscard(owner, id) }
    }

    private fun clientSafe(call: (WorkspaceArchiveHostClient) -> Unit) {
        runCatching { call(client) }
    }

    private fun trackJob(job: Job) {
        jobs.add(job)
        job.invokeOnCompletion { jobs.remove(job) }
    }

    private fun ownerCurrent(owner: Owner): Boolean =
        owner.nativeEpoch == currentNativeEpoch() &&
            owner.hostGeneration == currentHostGeneration() &&
            !isTemporaryTask(owner.taskID)

    private fun fileName(relativePath: String): String = relativePath.substringAfterLast('/')

    internal fun mapFailure(code: String): ArchiveFailure = when (code) {
        "retired", "ownerChanged" -> ArchiveFailure.OWNER
        "unsupportedFormat" -> ArchiveFailure.UNSUPPORTED
        "notFound" -> ArchiveFailure.NOT_FOUND
        "cancelled" -> ArchiveFailure.CANCELLED
        "tooLarge" -> ArchiveFailure.TOO_LARGE
        "conflict", "alreadyExists" -> ArchiveFailure.CONFLICT
        "unsupportedVersion", "needsCoreUpdate", "coreUnavailable", "runtimeUnavailable", "notInstalled" ->
            ArchiveFailure.NEEDS_CORE_UPDATE
        "transport", "invalidResponse" -> ArchiveFailure.TRANSPORT
        else -> ArchiveFailure.FAILED
    }

    internal companion object {
        internal const val SCHEMA = "floe.archive/25"
    }
}
