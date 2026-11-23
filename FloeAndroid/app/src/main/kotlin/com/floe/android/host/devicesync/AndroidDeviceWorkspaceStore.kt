// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.floe.android.bridge.DeviceWorkspaceNative
import com.floe.android.bridge.DeviceWorkspaceNativeException
import com.floe.android.core.devicelink.DeviceHistorySyncError
import com.floe.android.core.devicelink.DeviceHistorySyncException
import com.floe.android.core.devicelink.DeviceWorkspaceDownload
import com.floe.android.core.devicelink.DeviceWorkspaceEntry
import com.floe.android.core.devicelink.DeviceWorkspaceManifest
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

        override suspend fun confirm(indexes: List<Int>) = withContext(Dispatchers.IO) {
            verifyGrant()
            for (index in indexes) {
                currentCoroutineContext().ensureActive()
                native("sourceVerify") { DeviceWorkspaceNative.sourceVerify(ticket, index) }
            }
            verifyGrant()
            bases.remember(owner, indexes.map(entries::get))
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
                }
        }

        fun digest(owner: Owner, path: String): String? = db.rawQuery(
            "SELECT digest FROM file_base WHERE peer=? AND task=? AND scope=? AND path=?",
            arrayOf(owner.peer, owner.task.toString(), owner.scope, key(path)),
        ).use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

        fun remember(owner: Owner, entries: List<DeviceWorkspaceEntry>) {
            db.beginTransaction()
            try {
                for (entry in entries) {
                    db.execSQL(
                        "INSERT OR REPLACE INTO file_base(peer, task, scope, path, digest) VALUES(?,?,?,?,?)",
                        arrayOf(owner.peer, owner.task.toString(), owner.scope, key(entry.path), checkNotNull(entry.digest)),
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

    private companion object {
        const val NATIVE_CHUNK = 65_536
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
