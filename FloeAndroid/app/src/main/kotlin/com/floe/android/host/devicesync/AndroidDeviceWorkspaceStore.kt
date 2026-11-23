// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.floe.android.bridge.DeviceWorkspaceNative
import com.floe.android.bridge.DeviceWorkspaceNativeException
import com.floe.android.core.devicelink.DeviceHistorySyncError
import com.floe.android.core.devicelink.DeviceHistorySyncException
import com.floe.android.core.devicelink.DeviceWorkspaceBaseline
import com.floe.android.core.devicelink.DeviceWorkspaceDownload
import com.floe.android.core.devicelink.DeviceWorkspaceEntry
import com.floe.android.core.devicelink.DeviceWorkspaceManifest
import com.floe.android.core.devicelink.DeviceWorkspaceMove
import com.floe.android.core.devicelink.DeviceWorkspacePath
import com.floe.android.core.devicelink.DeviceWorkspaceReceiver
import com.floe.android.core.devicelink.DeviceWorkspaceSnapshot
import com.floe.android.core.devicelink.DeviceWorkspaceSource
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** File bytes stay in the native staging handle until the existing workspace write gate commits them. */
internal class AndroidDeviceWorkspaceStore(context: Context) {
    private val bases = WorkspaceBases(context.applicationContext)

    suspend fun scope(epoch: Long, task: UUID, receive: Boolean = false): String =
        native(if (receive) "targetBinding" else "binding") {
            if (receive) DeviceWorkspaceNative.targetBinding(epoch, task.toString())
            else DeviceWorkspaceNative.binding(epoch, task.toString())
        }.also { check(DeviceHistoryPreferenceStore.validScope(it)) }

    fun source(epoch: Long, grant: (String, UUID) -> String?): DeviceWorkspaceSource =
        object : DeviceWorkspaceSource {
            override suspend fun available(peer: String, task: UUID): Boolean {
                val expected = grant(peer, task) ?: return false
                return try {
                    scope(epoch, task) == expected && grant(peer, task) == expected
                } catch (_: DeviceHistorySyncException) {
                    false
                }
            }

            override suspend fun shareScope(peer: String, task: UUID): String {
                val expected = grant(peer, task) ?: refusal(DeviceHistorySyncError.NOT_SHARED)
                val live = try {
                    scope(epoch, task)
                } catch (failure: DeviceHistorySyncException) {
                    if (failure.error != DeviceHistorySyncError.NOT_SHARED) throw failure
                    refusal(DeviceHistorySyncError.NOT_SHARED)
                }
                if (live != expected || grant(peer, task) != expected) {
                    refusal(DeviceHistorySyncError.NOT_SHARED)
                }
                return live
            }

            override suspend fun prepare(peer: String, task: UUID): DeviceWorkspaceSnapshot =
                withContext(Dispatchers.IO) {
                    val expected = grant(peer, task) ?: refusal(DeviceHistorySyncError.NOT_SHARED)
                    val owner = Owner(peer, task, expected)
                    val opened = native("sourceOpen") { DeviceWorkspaceNative.sourceOpen(epoch, task.toString(), expected) }
                    val ticket = opened.ticket
                    try {
                        val size = opened.manifestSize
                        if (size !in 1..DeviceWorkspaceManifest.MAX_MANIFEST_BYTES) invalid()
                        val manifest = read(ticket, -1, 0, size)
                        val entries = try {
                            DeviceWorkspaceManifest.decode(manifest)
                        } finally {
                            manifest.fill(0)
                        }
                        Outbound(ticket, owner, entries, grant)
                    } catch (failure: Throwable) {
                        close(ticket)
                        throw failure
                    }
                }
        }

    suspend fun receiver(epoch: Long, peer: String, task: UUID): Inbound =
        withContext(Dispatchers.IO) {
            val scope = scope(epoch, task, receive = true)
            val ticket = native("targetOpen") { DeviceWorkspaceNative.targetOpen(epoch, task.toString(), scope) }
            Inbound(ticket, Owner(peer, task, scope))
        }

    fun forget(peer: String, task: UUID? = null) = bases.forget(peer, task)

    private inner class Outbound(
        private val ticket: Long,
        private val owner: Owner,
        override val entries: List<DeviceWorkspaceEntry>,
        private val grant: (String, UUID) -> String?,
    ) : DeviceWorkspaceSnapshot {
        private fun verifyGrant() {
            if (grant(owner.peer, owner.task) != owner.scope) refusal(DeviceHistorySyncError.NOT_SHARED)
        }

        override suspend fun checkPermission() = withContext(Dispatchers.IO) {
            verifyGrant()
            native("check") { DeviceWorkspaceNative.check(ticket) }
            verifyGrant()
        }

        override suspend fun read(index: Int, offset: Long, length: Int): ByteArray =
            withContext(Dispatchers.IO) {
                verifyGrant()
                this@AndroidDeviceWorkspaceStore.read(ticket, index, offset, length).also {
                    verifyGrant()
                }
            }

        /**
         * Records the confirmed baseline and applies the convergence receipt
         * atomically. Receipts only shrink or relocate the confirmed baseline;
         * they can never introduce new bytes beyond the prepared snapshot. A
         * retried identical receipt stays a success: the baseline already
         * carries the destination, which satisfies the recorded-digest check.
         */
        override suspend fun confirm(
            indexes: List<Int>,
            removals: List<String>,
            renames: List<DeviceWorkspaceMove>,
        ) = withContext(Dispatchers.IO) {
            verifyGrant()
            if (indexes.isEmpty() && removals.isEmpty() && renames.isEmpty()) invalid()
            if (indexes.size > DeviceWorkspaceManifest.MAX_CONFIRM ||
                indexes.toSet().size != indexes.size ||
                indexes.any { entries.getOrNull(it)?.kind != DeviceWorkspaceEntry.Kind.FILE }
            ) invalid()
            if (removals.size > MAX_CONVERGENCE_RECEIPT ||
                removals.toSet().size != removals.size ||
                removals.any { it.isEmpty() || it.encodeToByteArray().size > MAX_KEY_BYTES }
            ) invalid()
            if (renames.size > DeviceWorkspaceManifest.MAX_CONFIRM ||
                renames.mapTo(HashSet()) { it.key }.size != renames.size ||
                renames.mapTo(HashSet()) { DeviceWorkspacePath.collisionKey(it.path) }.size != renames.size ||
                renames.any {
                    it.key.isEmpty() || it.key.encodeToByteArray().size > MAX_KEY_BYTES ||
                        DeviceWorkspacePath.collisionKey(it.path) == null ||
                        !DeviceWorkspaceManifest.isDigest(it.digest)
                }
            ) invalid()
            val present = entries.mapTo(HashSet()) { DeviceWorkspacePath.collisionKey(it.path) }
            if (removals.any { it in present } || renames.any { it.key in present || it.key in removals }) {
                invalid()
            }
            // Convergence receipts require the recorded baseline identity.
            val relocated = ArrayList<DeviceWorkspaceEntry>(renames.size)
            if (removals.isNotEmpty() || renames.isNotEmpty()) {
                val baseline = bases.baseline(owner)
                for (move in renames) {
                    val destinationKey = DeviceWorkspacePath.collisionKey(move.path)
                    val recorded = baseline[move.key] ?: baseline[destinationKey] ?: invalid()
                    if (recorded.digest != move.digest) invalid()
                    val index = entries.indexOfFirst {
                        it.kind == DeviceWorkspaceEntry.Kind.FILE &&
                            DeviceWorkspacePath.collisionKey(it.path) == destinationKey &&
                            it.digest == move.digest
                    }
                    if (index < 0) invalid()
                    // The destination must still be the scanned bytes; the
                    // sender retires its old spelling only for a live match.
                    native("sourceVerify") { DeviceWorkspaceNative.sourceVerify(ticket, index) }
                    relocated.add(entries[index])
                }
            }
            for (index in indexes) {
                currentCoroutineContext().ensureActive()
                native("sourceVerify") { DeviceWorkspaceNative.sourceVerify(ticket, index) }
            }
            verifyGrant()
            val confirmed = indexes.map(entries::get) + relocated
            bases.relocate(
                owner,
                insert = confirmed.filter { it.kind == DeviceWorkspaceEntry.Kind.FILE },
                remove = removals + renames.map { it.key },
            )
        }

        override fun close() = close(ticket)
    }

    internal inner class Inbound(private val ticket: Long, private val owner: Owner) :
        DeviceWorkspaceReceiver, AutoCloseable {

        override suspend fun accept(entry: DeviceWorkspaceEntry, download: DeviceWorkspaceDownload?) =
            withContext(Dispatchers.IO) {
                val local = try {
                    info(entry.path)
                } catch (failure: DeviceHistorySyncException) {
                    if (failure.error != DeviceHistorySyncError.CONFLICT) throw failure
                    LocalEntry("blocked")
                }
                if (entry.kind == DeviceWorkspaceEntry.Kind.DIRECTORY) {
                    return@withContext acceptDirectory(entry.path, local.kind)
                }

                val remoteDigest = checkNotNull(entry.digest)
                val base = bases.digest(owner, entry.path)
                when (mergeWorkspaceFile(local.kind, local.digest, base, remoteDigest)) {
                    WorkspaceFileMerge.AGREED -> DeviceWorkspaceReceiver.Result.AGREED
                    WorkspaceFileMerge.RETAIN -> DeviceWorkspaceReceiver.Result.RETAINED
                    WorkspaceFileMerge.CREATE, WorkspaceFileMerge.REPLACE -> {
                        install(entry, checkNotNull(download), expectedDigest = local.digest)
                        DeviceWorkspaceReceiver.Result.AGREED
                    }
                    WorkspaceFileMerge.CONFLICT -> {
                        val existing = info(entry.path, remoteDigest)
                        if (existing.digest != remoteDigest) {
                            if (existing.kind != "missing") refusal(DeviceHistorySyncError.CONFLICT)
                            install(entry, checkNotNull(download), conflictDigest = remoteDigest)
                        }
                        DeviceWorkspaceReceiver.Result.CONFLICT
                    }
                }
            }

        private suspend fun acceptDirectory(path: String, kind: String): DeviceWorkspaceReceiver.Result {
            if (kind == "directory") return DeviceWorkspaceReceiver.Result.DIRECTORY
            if (kind == "missing") {
                try {
                    native("targetDirectory") { DeviceWorkspaceNative.targetDirectory(ticket, path) }
                    return DeviceWorkspaceReceiver.Result.DIRECTORY
                } catch (failure: DeviceHistorySyncException) {
                    if (failure.error != DeviceHistorySyncError.CONFLICT) throw failure
                }
            }
            val digest = DeviceWorkspacePath.directoryConflictDigest(path)
            native("targetDirectory") { DeviceWorkspaceNative.targetDirectory(ticket, path, digest) }
            return DeviceWorkspaceReceiver.Result.CONFLICT
        }

        override suspend fun confirmed(entries: List<DeviceWorkspaceEntry>) = withContext(Dispatchers.IO) {
            native("check") { DeviceWorkspaceNative.check(ticket) }
            bases.remember(owner, entries)
        }

        override suspend fun baseline(): Map<String, DeviceWorkspaceBaseline> =
            withContext(Dispatchers.IO) { bases.baseline(owner) }

        override suspend fun convergeMove(
            key: String, digest: String, pathHint: String?, destination: String,
        ): Boolean = withContext(Dispatchers.IO) {
            val moved = convergenceOutcome(
                "targetMove",
                convergenceInput(key, digest, pathHint, to = destination),
            )
            if (moved) {
                // The baseline retires the old key and records the confirmed
                // destination (under its own key and spelling) atomically, so
                // a later removal can converge on it.
                bases.relocate(
                    owner,
                    insert = listOf(DeviceWorkspaceEntry(destination, DeviceWorkspaceEntry.Kind.FILE, null, digest)),
                    remove = listOf(key),
                )
            }
            moved
        }

        override suspend fun convergeTrash(key: String, digest: String, pathHint: String?): Boolean =
            withContext(Dispatchers.IO) {
                val removed = convergenceOutcome(
                    "targetTrash",
                    convergenceInput(key, digest, pathHint, to = null),
                )
                if (removed) bases.relocate(owner, insert = emptyList(), remove = listOf(key))
                removed
            }

        private fun convergenceInput(key: String, digest: String, pathHint: String?, to: String?): ByteArray =
            JSONObject()
                .put("ticket", ticket)
                .put("key", key)
                .put("digest", digest)
                .apply {
                    if (pathHint != null) put("pathHint", pathHint)
                    if (to != null) put("to", to)
                }
                .toString()
                .encodeToByteArray()

        /**
         * One convergence command: the native reply is
         * `{"outcome":"moved"|"removed"|"preserved"}`; only moved/removed
         * report success, every other value keeps the local file.
         */
        private suspend fun convergenceOutcome(operation: String, input: ByteArray): Boolean {
            val reply = ByteArray(REPLY_BYTES)
            val copied = try {
                DeviceWorkspaceNative.command(operation, input, reply)
            } catch (failure: DeviceWorkspaceNativeException) {
                refusal(errorFor(failure.status))
            }
            if (copied < 0) refusal(errorFor(copied))
            val root = try {
                JSONObject(reply.decodeToString(endIndex = copied, throwOnInvalidSequence = true))
            } catch (_: Exception) {
                invalid()
            }
            return root.optString("outcome") == "moved" || root.optString("outcome") == "removed"
        }

        private suspend fun info(path: String, conflictDigest: String? = null): LocalEntry {
            val result = native("targetInfo") { DeviceWorkspaceNative.targetInfo(ticket, path, conflictDigest) }
            if ((result.kind == DeviceWorkspaceNative.TargetKind.FILE) != (result.digest != null)) invalid()
            return LocalEntry(result.kind.wire, result.digest)
        }

        private suspend fun install(
            entry: DeviceWorkspaceEntry,
            download: DeviceWorkspaceDownload,
            expectedDigest: String? = null,
            conflictDigest: String? = null,
        ) {
            val stage = native("targetStage") { DeviceWorkspaceNative.targetStage(ticket) }
            try {
                download.to { bytes ->
                    var offset = 0
                    while (offset < bytes.size) {
                        val length = minOf(NATIVE_CHUNK, bytes.size - offset)
                        checkStatus(DeviceWorkspaceNative.write(stage, bytes, offset, length))
                        offset += length
                    }
                }
                currentCoroutineContext().ensureActive()
                native("targetCommit") {
                    DeviceWorkspaceNative.targetCommit(stage, entry.path, checkNotNull(entry.digest),
                        checkNotNull(entry.size), expectedDigest, conflictDigest)
                }
            } finally {
                close(stage)
            }
        }

        override fun close() = close(ticket)
    }

    private suspend fun read(ticket: Long, index: Int, offset: Long, length: Int): ByteArray {
        val complete = ByteArray(length)
        try {
            val scratch = ByteArray(minOf(length, NATIVE_CHUNK))
            try {
                var position = 0
                while (position < length) {
                    currentCoroutineContext().ensureActive()
                    val limit = minOf(scratch.size, length - position)
                    val block = if (limit == scratch.size) scratch else ByteArray(limit)
                    try {
                        val count = checkStatus(DeviceWorkspaceNative.read(ticket, index, offset + position, block))
                        if (count != limit) refusal(DeviceHistorySyncError.CONFLICT)
                        block.copyInto(complete, position)
                        position += count
                    } finally {
                        block.fill(0)
                    }
                }
            } finally {
                scratch.fill(0)
            }
            return complete
        } catch (failure: Throwable) {
            complete.fill(0)
            throw failure
        }
    }

    private fun close(ticket: Long) {
        val input = JSONObject().put("ticket", ticket).toString().encodeToByteArray()
        runCatching { DeviceWorkspaceNative.command("close", input, ByteArray(128)) }
    }

    private suspend fun <T> native(stage: String, operation: suspend () -> T): T = try {
        operation()
    } catch (failure: DeviceWorkspaceNativeException) {
        if (failure.status != -806 || stage != "targetInfo") {
            android.util.Log.w("FloeWorkspaceSync", "stage=$stage nativeStatus=${failure.status}")
        }
        refusal(errorFor(failure.status))
    }

    private fun checkStatus(status: Int): Int {
        if (status >= 0) return status
        refusal(errorFor(status))
    }

    private fun errorFor(status: Int): DeviceHistorySyncError = when (status) {
        -105, -106 -> DeviceHistorySyncError.INVALID_RESPONSE
        -802, -805 -> DeviceHistorySyncError.NOT_SHARED
        -806 -> DeviceHistorySyncError.CONFLICT
        -808 -> DeviceHistorySyncError.TOO_LARGE
        -810 -> DeviceHistorySyncError.BUSY
        else -> DeviceHistorySyncError.UNAVAILABLE
    }

    private fun invalid(): Nothing = refusal(DeviceHistorySyncError.INVALID_RESPONSE)

    private fun refusal(error: DeviceHistorySyncError): Nothing = throw DeviceHistorySyncException(error)

    internal data class Owner(val peer: String, val task: UUID, val scope: String)
    private data class LocalEntry(val kind: String, val digest: String? = null)

    private companion object {
        const val NATIVE_CHUNK = 65_536
        /** One confirm receipt carries at most this many baseline removals. */
        const val MAX_CONVERGENCE_RECEIPT = 1_024
        /** Baseline comparison keys are bounded exactly like wire paths. */
        const val MAX_KEY_BYTES = 1_024
        const val REPLY_BYTES = 4_096
    }

    /** Durable confirmed-baseline ledger for one peer/task/scope. */
    private class WorkspaceBases(context: Context) {
        private val db by lazy {
            SQLiteDatabase.openOrCreateDatabase(File(context.noBackupFilesDir, "device-workspace-bases.sqlite"), null)
                .apply {
                    execSQL("""
                        CREATE TABLE IF NOT EXISTS file_base(
                            peer TEXT NOT NULL, task TEXT NOT NULL, scope TEXT NOT NULL,
                            path TEXT NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(peer, task, scope, path)
                        ) WITHOUT ROWID
                    """.trimIndent())
                    // v2 convergence: the exact on-disk spelling recorded at
                    // confirmation time (NULL for rows written by older
                    // builds, which fall back to a comparison-key lookup).
                    val columns = rawQuery("PRAGMA table_info(file_base)", null).use { cursor ->
                        buildSet { while (cursor.moveToNext()) add(cursor.getString(1)) }
                    }
                    if ("spelling" !in columns) {
                        execSQL("ALTER TABLE file_base ADD COLUMN spelling TEXT")
                    }
                }
        }

        fun digest(owner: Owner, path: String): String? = db.rawQuery(
            "SELECT digest FROM file_base WHERE peer=? AND task=? AND scope=? AND path=?",
            arrayOf(owner.peer, owner.task.toString(), owner.scope, key(path)),
        ).use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

        /** The whole confirmed baseline for this peer/task/scope. */
        fun baseline(owner: Owner): Map<String, DeviceWorkspaceBaseline> = db.rawQuery(
            "SELECT path, digest, spelling FROM file_base WHERE peer=? AND task=? AND scope=?",
            arrayOf(owner.peer, owner.task.toString(), owner.scope),
        ).use { cursor ->
            buildMap {
                while (cursor.moveToNext()) {
                    put(cursor.getString(0), DeviceWorkspaceBaseline(cursor.getString(1), cursor.getString(2)))
                }
            }
        }

        fun remember(owner: Owner, entries: List<DeviceWorkspaceEntry>) = relocate(owner, entries, emptyList())

        /**
         * Atomic baseline update: [remove] keys retire first, then [insert]
         * entries are recorded under their comparison key with the exact
         * spelling. A retried rename receipt therefore converges on the
         * destination the first receipt recorded.
         */
        fun relocate(owner: Owner, insert: List<DeviceWorkspaceEntry>, remove: List<String>) {
            db.beginTransaction()
            try {
                for (entry in remove) {
                    db.execSQL(
                        "DELETE FROM file_base WHERE peer=? AND task=? AND scope=? AND path=?",
                        arrayOf(owner.peer, owner.task.toString(), owner.scope, entry),
                    )
                }
                for (entry in insert) {
                    db.execSQL(
                        "INSERT OR REPLACE INTO file_base(peer, task, scope, path, digest, spelling) VALUES(?,?,?,?,?,?)",
                        arrayOf(
                            owner.peer, owner.task.toString(), owner.scope, key(entry.path),
                            checkNotNull(entry.digest), entry.path,
                        ),
                    )
                }
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
        }

        fun forget(peer: String, task: UUID?) {
            if (task == null) db.delete("file_base", "peer=?", arrayOf(peer))
            else db.delete("file_base", "peer=? AND task=?", arrayOf(peer, task.toString()))
        }

        private fun key(path: String) = checkNotNull(DeviceWorkspacePath.collisionKey(path))
    }
}

internal enum class WorkspaceFileMerge { AGREED, RETAIN, CREATE, REPLACE, CONFLICT }

internal fun mergeWorkspaceFile(kind: String, local: String?, base: String?, remote: String): WorkspaceFileMerge =
    when {
        kind == "file" && local == remote -> WorkspaceFileMerge.AGREED
        base == remote -> WorkspaceFileMerge.RETAIN
        kind == "missing" && base == null -> WorkspaceFileMerge.CREATE
        kind == "file" && base != null && local == base -> WorkspaceFileMerge.REPLACE
        else -> WorkspaceFileMerge.CONFLICT
    }
