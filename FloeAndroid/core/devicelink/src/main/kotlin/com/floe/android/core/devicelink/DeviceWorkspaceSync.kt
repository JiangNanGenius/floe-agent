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

    /**
     * The live scope string for [task]'s currently bound managed root, or a
     * typed [DeviceHistorySyncError.NOT_SHARED] refusal. The frozen v2
     * history and convergence paths re-prove this scope against the durable
     * per-peer share on every segment.
     */
    suspend fun shareScope(peer: String, task: UUID): String

    suspend fun prepare(peer: String, task: UUID): DeviceWorkspaceSnapshot
}

/** One connection-scoped immutable manifest. Bytes must come from this snapshot. */
interface DeviceWorkspaceSnapshot : AutoCloseable {
    val entries: List<DeviceWorkspaceEntry>
    suspend fun checkPermission()
    suspend fun read(index: Int, offset: Long, length: Int): ByteArray

    /**
     * Confirms [indexes] against the prepared snapshot and applies the
     * convergence receipt ([removals] baseline keys dropped, [renames]
     * baseline keys relocated to their confirmed destination) atomically.
     * The sender never applies peer file mutations here; receipts only move
     * or retire the durable sync baseline. An all-empty receipt is invalid;
     * non-empty receipts were already gated behind the v2 wire consent check.
     */
    suspend fun confirm(
        indexes: List<Int>,
        removals: List<String> = emptyList(),
        renames: List<DeviceWorkspaceMove> = emptyList(),
    )
}

fun interface DeviceWorkspaceDownload {
    /** Streams a verified-length file. The caller may use the result after this returns. */
    suspend fun to(write: (ByteArray) -> Unit)
}

/** One confirmed baseline entry: the verified digest plus the exact on-disk
 * spelling recorded when both sides confirmed it (absent for pre-v2 rows,
 * which fall back to a comparison-key tree walk). */
data class DeviceWorkspaceBaseline(val digest: String, val path: String?)

/** A rename the receiver converged locally, reported to the sender so both
 * confirmed baselines keep the same spelling. [key] is the NFC,
 * en_US_POSIX-lowercased comparison key of the retired path; [path] is the
 * destination's exact relative spelling; [digest] is the verified content digest. */
data class DeviceWorkspaceMove(val key: String, val path: String, val digest: String)

/**
 * Baseline entries no longer present in the peer manifest must never be
 * touched by default ([V1], the original keep-local behavior). [V2] is
 * negotiated per peer and converges renames and deletions only when the
 * local copy is still the exactly confirmed shared baseline.
 */
enum class DeviceWorkspaceConvergence {
    V1, V2
}

/** What the receiver converged before content transfer, reported to the sender. */
data class DeviceWorkspaceConvergenceReceipt(
    val removals: List<String> = emptyList(),
    val renames: List<DeviceWorkspaceMove> = emptyList(),
)

interface DeviceWorkspaceReceiver {
    enum class Result { AGREED, CONFLICT, DIRECTORY, RETAINED }

    /** Existing identical files need not invoke [download]. A directory has no download. */
    suspend fun accept(entry: DeviceWorkspaceEntry, download: DeviceWorkspaceDownload?): Result
    suspend fun confirmed(entries: List<DeviceWorkspaceEntry>)

    /**
     * The durable confirmed baseline for this peer/task/scope. Only consulted
     * for [DeviceWorkspaceConvergence.V2] receives; the default keeps the
     * copy-only behavior for hosts without a ledger.
     */
    suspend fun baseline(): Map<String, DeviceWorkspaceBaseline> = emptyMap()

    /**
     * Moves an exact confirmed-baseline file to [destination] without
     * re-transferring bytes. Returns true when the verified file was
     * relocated (or the destination already held the identical confirmed
     * bytes and the source spelling was retired); false keeps everything
     * untouched and counts as preserved.
     */
    suspend fun convergeMove(key: String, digest: String, pathHint: String?, destination: String): Boolean = false

    /**
     * Moves an exact confirmed-baseline file into the workspace-visible
     * recovery folder (`Floe Sync Conflicts/Removed/<id>/<path>`). Returns
     * true when the bytes were recovered; false preserves the local file.
     */
    suspend fun convergeTrash(key: String, digest: String, pathHint: String?): Boolean = false
}

data class DeviceWorkspaceReceipt(
    val files: Int,
    val directories: Int,
    val conflicts: Int,
    /** v2 convergence outcomes for one receive pass. */
    val moved: Int = 0,
    val deleted: Int = 0,
    val preserved: Int = 0,
)

/** Shared limits for the v1 device-link workspace extension. */
object DeviceWorkspaceManifest {
    const val CHUNK_SIZE = 393_216
    const val MAX_ENTRIES = 10_000
    const val MAX_MANIFEST_BYTES = 16 * 1024 * 1024
    const val MAX_FILE_BYTES = 1L shl 30
    const val MAX_TOTAL_BYTES = 8L shl 30
    const val MAX_CONFIRM = 128
    /** One confirm receipt carries at most this many baseline removals. */
    const val MAX_CONVERGENCE_RECEIPT = 1_024
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
    /** The workspace revision this transfer was prepared at; every segment re-fences. */
    val revision: Long,
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
        convergence: DeviceWorkspaceConvergence,
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
        // v2 convergence runs before any content transfer so a peer rename
        // reuses the already-confirmed local bytes instead of downloading
        // them again. Every decision requires the exact confirmed baseline
        // identity; anything else is kept locally and reported preserved.
        var receipt = DeviceWorkspaceConvergenceReceipt()
        var moved = 0
        var deleted = 0
        var preserved = 0
        if (convergence == DeviceWorkspaceConvergence.V2) {
            val report = converge(receiver, entries)
            receipt = DeviceWorkspaceConvergenceReceipt(report.removals, report.renames)
            moved = report.moved
            deleted = report.deleted
            preserved = report.preserved
        }
        val pending = ArrayList<Int>(DeviceWorkspaceManifest.MAX_CONFIRM)
        var files = 0
        var directories = 0
        var conflicts = 0
        var receiptSent = false
        suspend fun confirm() {
            // Never send an all-empty confirmation: it is only meaningful when
            // something was accepted or a convergence receipt is owed.
            if (pending.isEmpty() &&
                (receiptSent || (receipt.removals.isEmpty() && receipt.renames.isEmpty()))
            ) {
                return
            }
            val indexes = pending.toList()
            request(
                DeviceHistorySync.SyncRequest(
                    DeviceHistorySync.Operation.CONFIRM_WORKSPACE,
                    task,
                    indexes = indexes,
                    removals = receipt.removals.takeIf { !receiptSent }?.takeIf { it.isNotEmpty() },
                    renames = receipt.renames.takeIf { !receiptSent }?.takeIf { it.isNotEmpty() },
                ),
            )
            if (indexes.isNotEmpty()) receiver.confirmed(indexes.map(entries::get))
            pending.clear()
            receiptSent = true
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
        return DeviceWorkspaceReceipt(files, directories, conflicts, moved, deleted, preserved)
    }

    private data class ConvergenceReport(
        val removals: List<String> = emptyList(),
        val renames: List<DeviceWorkspaceMove> = emptyList(),
        val moved: Int = 0,
        val deleted: Int = 0,
        val preserved: Int = 0,
    )

    /**
     * Manifest-absent baseline entries converge locally: a baseline path that
     * disappeared while a new manifest path carries the identical confirmed
     * digest is renamed in place; anything else with exact baseline identity
     * is recovered into the workspace-visible Removed folder; everything else
     * is preserved and counted. Mirrors the frozen Apple host's `converge`.
     */
    private suspend fun converge(
        receiver: DeviceWorkspaceReceiver,
        entries: List<DeviceWorkspaceEntry>,
    ): ConvergenceReport {
        val baseline = receiver.baseline()
        if (baseline.isEmpty()) return ConvergenceReport()
        val manifestKeys = entries.filter { it.kind == DeviceWorkspaceEntry.Kind.FILE }
            .mapTo(HashSet()) { DeviceWorkspacePath.collisionKey(it.path) ?: invalid() }
        val removedKeys = baseline.keys.filter { it !in manifestKeys }.sorted()
        if (removedKeys.isEmpty()) return ConvergenceReport()
        // A rename shows up as a baseline path disappearing while a new
        // manifest path carries the identical confirmed digest. Only paths
        // that are themselves new can be rename destinations.
        val candidates = HashMap<String, MutableList<DeviceWorkspaceEntry>>()
        for (entry in entries) {
            if (entry.kind != DeviceWorkspaceEntry.Kind.FILE) continue
            val key = DeviceWorkspacePath.collisionKey(entry.path) ?: invalid()
            if (key in baseline) continue
            val digest = entry.digest ?: continue
            candidates.getOrPut(digest) { mutableListOf() }.add(entry)
        }
        for (list in candidates.values) {
            list.sortWith { first, second -> compareUtf8(first.path, second.path) }
        }
        val consumed = HashSet<String>()
        val removals = ArrayList<String>()
        val renames = ArrayList<DeviceWorkspaceMove>()
        var moved = 0
        var deleted = 0
        var preserved = 0
        for ((offset, key) in removedKeys.withIndex()) {
            if (renames.size == DeviceWorkspaceManifest.MAX_CONFIRM ||
                removals.size == DeviceWorkspaceManifest.MAX_CONVERGENCE_RECEIPT
            ) {
                preserved += removedKeys.size - offset
                break
            }
            currentCoroutineContext().ensureActive()
            val recorded = baseline[key] ?: continue
            val destination = candidates[recorded.digest]
                ?.firstOrNull { DeviceWorkspacePath.collisionKey(it.path) !in consumed }
            if (destination != null) {
                val destinationKey = DeviceWorkspacePath.collisionKey(destination.path) ?: invalid()
                if (receiver.convergeMove(key, recorded.digest, recorded.path, destination.path)) {
                    consumed.add(destinationKey)
                    renames.add(DeviceWorkspaceMove(key, destination.path, recorded.digest))
                    moved++
                } else {
                    preserved++
                }
            } else if (receiver.convergeTrash(key, recorded.digest, recorded.path)) {
                removals.add(key)
                deleted++
            } else {
                preserved++
            }
        }
        return ConvergenceReport(removals, renames, moved, deleted, preserved)
    }

    /** UTF-8 lexicographic order, matching the frozen Apple manifest sort. */
    private fun compareUtf8(first: String, second: String): Int {
        val left = first.encodeToByteArray()
        val right = second.encodeToByteArray()
        val length = minOf(left.size, right.size)
        for (index in 0 until length) {
            val difference = (left[index].toInt() and 255) - (right[index].toInt() and 255)
            if (difference != 0) return difference
        }
        return left.size - right.size
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
