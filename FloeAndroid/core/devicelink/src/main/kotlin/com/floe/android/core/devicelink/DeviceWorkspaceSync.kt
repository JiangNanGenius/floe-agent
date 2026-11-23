// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicelink

import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONArray
import org.json.JSONObject

/** An indexed entry in a prepared workspace. A directory has no digest or size. */
data class DeviceWorkspaceEntry(
    val path: String,
    val kind: Kind,
    val size: Long? = null,
    val digest: String? = null,
) {
    enum class Kind(val wire: String) { FILE("file"), DIRECTORY("directory") }
}

/** The host owns both the permission and the live identity of the managed root. */
interface DeviceWorkspaceSource {
    suspend fun available(peer: String, task: UUID): Boolean
    suspend fun prepare(peer: String, task: UUID): DeviceWorkspaceSnapshot
}

/** One connection-scoped immutable manifest. Bytes must come from this snapshot. */
interface DeviceWorkspaceSnapshot : AutoCloseable {
    val entries: List<DeviceWorkspaceEntry>
    suspend fun checkPermission()
    suspend fun read(index: Int, offset: Long, length: Int): ByteArray
    suspend fun confirm(indexes: List<Int>)
}

fun interface DeviceWorkspaceDownload {
    /** Streams a verified-length file. The caller may use the result after this returns. */
    suspend fun to(write: (ByteArray) -> Unit)
}

interface DeviceWorkspaceReceiver {
    enum class Result { AGREED, CONFLICT, DIRECTORY, RETAINED }

    /** Existing identical files need not invoke [download]. A directory has no download. */
    suspend fun accept(entry: DeviceWorkspaceEntry, download: DeviceWorkspaceDownload?): Result
    suspend fun confirmed(entries: List<DeviceWorkspaceEntry>)
}

data class DeviceWorkspaceReceipt(val files: Int, val directories: Int, val conflicts: Int)

/** Shared limits for the v1 device-link workspace extension. */
object DeviceWorkspaceManifest {
    const val CHUNK_SIZE = 393_216
    const val MAX_ENTRIES = 10_000
    const val MAX_MANIFEST_BYTES = 16 * 1024 * 1024
    const val MAX_FILE_BYTES = 1L shl 30
    const val MAX_TOTAL_BYTES = 8L shl 30
    const val MAX_CONFIRM = 128
    private val sha256 = Regex("[0-9a-f]{64}")
    private val hexDigits = "0123456789abcdef"

    internal fun encode(entries: List<DeviceWorkspaceEntry>): ByteArray {
        validate(entries)
        val rows = entries.map { entry ->
            JSONObject().put("path", entry.path).put("kind", entry.kind.wire).apply {
                entry.size?.let { put("size", it) }
                entry.digest?.let { put("digest", it) }
            }
        }
        return JSONObject().put("entries", JSONArray(rows)).toString().encodeToByteArray().also {
            if (it.size > MAX_MANIFEST_BYTES) fail(DeviceHistorySyncError.TOO_LARGE)
        }
    }

    fun decode(bytes: ByteArray): List<DeviceWorkspaceEntry> {
        try {
            if (bytes.isEmpty() || bytes.size > MAX_MANIFEST_BYTES) fail()
            val manifest = JSONObject(bytes.decodeToString(throwOnInvalidSequence = true))
            val rows = manifest.opt("entries") as? JSONArray ?: fail()
            if (rows.length() > MAX_ENTRIES) fail(DeviceHistorySyncError.TOO_LARGE)
            return List(rows.length()) { index ->
                val row = rows.opt(index) as? JSONObject ?: fail()
                val path = row.opt("path") as? String ?: fail()
                when (row.opt("kind")) {
                    "file" -> {
                        val size = when (val raw = row.opt("size")) {
                            is Int -> raw.toLong()
                            is Long -> raw
                            else -> fail()
                        }
                        DeviceWorkspaceEntry(path, DeviceWorkspaceEntry.Kind.FILE, size, row.opt("digest") as? String ?: fail())
                    }
                    "directory" -> {
                        if (!row.isNull("size") || !row.isNull("digest")) fail()
                        DeviceWorkspaceEntry(path, DeviceWorkspaceEntry.Kind.DIRECTORY)
                    }
                    else -> fail()
                }
            }.also(::validate)
        } catch (failure: DeviceHistorySyncException) {
            throw failure
        } catch (_: Exception) {
            fail()
        }
    }

    fun isDigest(value: String): Boolean = sha256.matches(value)

    internal fun hex(bytes: ByteArray): String = buildString(bytes.size * 2) {
        for (byte in bytes) {
            val value = byte.toInt() and 255
            append(hexDigits[value ushr 4])
            append(hexDigits[value and 15])
        }
    }

    internal fun digest(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    private fun validate(entries: List<DeviceWorkspaceEntry>) {
        if (entries.size > MAX_ENTRIES) fail(DeviceHistorySyncError.TOO_LARGE)
        var bytes = 0L
        val paths = HashMap<String, DeviceWorkspaceEntry.Kind>(entries.size)
        val spellings = HashMap<String, String>(entries.size)
        for (entry in entries) {
            val path = DeviceWorkspacePath.collisionKey(entry.path) ?: fail()
            if (paths.put(path, entry.kind) != null) fail()
            var key = path
            var spelling = entry.path
            while (key.isNotEmpty()) {
                val previous = spellings.putIfAbsent(key, spelling)
                if (previous != null) {
                    if (previous != spelling) fail()
                    break
                }
                key = key.substringBeforeLast('/', "")
                spelling = spelling.substringBeforeLast('/', "")
            }
            when (entry.kind) {
                DeviceWorkspaceEntry.Kind.DIRECTORY -> if (entry.size != null || entry.digest != null) fail()
                DeviceWorkspaceEntry.Kind.FILE -> {
                    val size = entry.size ?: fail()
                    if (size < 0 || entry.digest?.let(::isDigest) != true) fail()
                    if (size > MAX_FILE_BYTES || bytes + size > MAX_TOTAL_BYTES) fail(DeviceHistorySyncError.TOO_LARGE)
                    bytes += size
                }
            }
        }
        for (path in spellings.keys) {
            val parent = path.substringBeforeLast('/', "")
            if (paths[parent] == DeviceWorkspaceEntry.Kind.FILE) fail()
        }
    }

    private fun fail(error: DeviceHistorySyncError = DeviceHistorySyncError.INVALID_RESPONSE): Nothing =
        throw DeviceHistorySyncException(error)
}

internal class PreparedDeviceWorkspace(
    val task: UUID,
    val snapshot: DeviceWorkspaceSnapshot,
) : AutoCloseable {
    val entries = snapshot.entries.toList()
    val manifest = DeviceWorkspaceManifest.encode(entries)
    val digest = DeviceWorkspaceManifest.digest(manifest)

    override fun close() {
        manifest.fill(0)
        snapshot.close()
    }
}

internal object DeviceWorkspaceTransfer {
    suspend fun receive(
        task: UUID,
        receiver: DeviceWorkspaceReceiver,
        request: suspend (DeviceHistorySync.SyncRequest) -> DeviceHistorySync.SyncReply,
    ): DeviceWorkspaceReceipt {
        val meta = request(DeviceHistorySync.SyncRequest(DeviceHistorySync.Operation.PREPARE_WORKSPACE, task))
        val size = meta.size?.takeIf { it in 1..DeviceWorkspaceManifest.MAX_MANIFEST_BYTES } ?: invalid()
        val expected = meta.digest?.takeIf(DeviceWorkspaceManifest::isDigest) ?: invalid()
        val manifest = ByteArray(size)
        val entries = try {
            stream(DeviceHistorySync.Operation.WORKSPACE_MANIFEST, task, null, size.toLong(), expected, request) { offset, bytes ->
                bytes.copyInto(manifest, offset.toInt())
            }
            DeviceWorkspaceManifest.decode(manifest)
        } finally {
            manifest.fill(0)
        }
        val pending = ArrayList<Int>(DeviceWorkspaceManifest.MAX_CONFIRM)
        var files = 0
        var directories = 0
        var conflicts = 0
        suspend fun confirm() {
            if (pending.isEmpty()) return
            val indexes = pending.toList()
            request(DeviceHistorySync.SyncRequest(DeviceHistorySync.Operation.CONFIRM_WORKSPACE, task, indexes = indexes))
            receiver.confirmed(indexes.map(entries::get))
            pending.clear()
        }
        // Create the parent directories before reading any children even
        // when the sender sorted its manifest using another locale or order.
        val order = entries.indices.sortedWith(compareBy({ entries[it].path.count { ch -> ch == '/' } }, { it }))
        for (index in order) {
            currentCoroutineContext().ensureActive()
            val entry = entries[index]
            val download = if (entry.kind == DeviceWorkspaceEntry.Kind.FILE) DeviceWorkspaceDownload { write ->
                stream(DeviceHistorySync.Operation.WORKSPACE_FILE, task, index, checkNotNull(entry.size),
                    checkNotNull(entry.digest), request) { _, bytes -> write(bytes) }
            } else null
            when (receiver.accept(entry, download)) {
                DeviceWorkspaceReceiver.Result.DIRECTORY -> {
                    if (entry.kind != DeviceWorkspaceEntry.Kind.DIRECTORY) invalid()
                    directories++
                }
                DeviceWorkspaceReceiver.Result.AGREED -> {
                    if (entry.kind != DeviceWorkspaceEntry.Kind.FILE) invalid()
                    files++
                    pending.add(index)
                    if (pending.size == DeviceWorkspaceManifest.MAX_CONFIRM) confirm()
                }
                DeviceWorkspaceReceiver.Result.CONFLICT -> conflicts++
                DeviceWorkspaceReceiver.Result.RETAINED -> Unit
            }
        }
        confirm()
        return DeviceWorkspaceReceipt(files, directories, conflicts)
    }

    private suspend fun stream(
        operation: DeviceHistorySync.Operation,
        task: UUID,
        index: Int?,
        size: Long,
        expected: String,
        request: suspend (DeviceHistorySync.SyncRequest) -> DeviceHistorySync.SyncReply,
        write: (Long, ByteArray) -> Unit,
    ) {
        val digest = MessageDigest.getInstance("SHA-256")
        var offset = 0L
        while (offset < size) {
            currentCoroutineContext().ensureActive()
            val reply = request(DeviceHistorySync.SyncRequest(operation, task, offset, index = index))
            val bytes = reply.bytes ?: invalid()
            try {
                if (bytes.size.toLong() != minOf(size - offset, DeviceWorkspaceManifest.CHUNK_SIZE.toLong())) invalid()
                digest.update(bytes)
                write(offset, bytes)
                offset += bytes.size
            } finally {
                bytes.fill(0)
            }
        }
        if (DeviceWorkspaceManifest.hex(digest.digest()) != expected) invalid()
    }

    private fun invalid(): Nothing = throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
}
