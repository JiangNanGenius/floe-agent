// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

/**
 * G07.3A — validated preparation receipts for the runtime UID.
 *
 * What this owns: a SMALL, bounded, atomic marker per task workspace that
 * records the exact environment + published base revision + canonical guest
 * workspace identity (device/inode/path) of a preparation that actually
 * completed under this runtime PROCESS generation. It is NOT an environment
 * registry, NOT a workspace database and NOT a second authority: the rootfs
 * marker in the writable layer stays the authority for materialization, and
 * the Core workspace grant stays the authority for files.
 *
 * Reuse rule (`reusable`):
 *  * exact projectID / environmentID / baseRevision equality;
 *  * the recorded canonical workspace path is the SAME path this start
 *    resolved (never a guessed one);
 *  * the live workspace root is still the same real directory (device+inode),
 *    so a delete/recreate is detected;
 *  * the receipt was written by THIS runtime boot generation (a new process
 *    must not inherit another process's in-memory qualification);
 *  * `ready == true` and `clean == true` (the recorded preparation ended with
 *    a synced export; a conflict/aborted deferral invalidates).
 *
 * Every write is a temp file in the SAME directory + atomic rename + fsync of
 * the directory, so a crash cannot publish a half record. Records are bounded
 * (<= 4 KiB) and the directory is pruned to the newest 64 entries.
 */
internal class WorkspacePreparationReceipts(private val directory: File) {
    private val lock = Any()

    private fun fileFor(projectID: String): File? {
        if (!projectID.matches(Regex("[A-Za-z0-9_-]{1,64}"))) return null
        val root = directory.canonicalFile
        val file = File(root, "receipt-$projectID.json")
        return file.takeIf { it.canonicalFile == it && it.toPath().startsWith(root.toPath()) }
    }

    /** Records one real, completed preparation. Never throws to the caller. */
    fun record(
        projectID: String,
        environmentID: String,
        baseRevision: String,
        workspaceRoot: File,
        entryCount: Long,
        totalBytes: Long,
        clean: Boolean = true,
    ): Boolean = synchronized(lock) {
        return try {
            val target = fileFor(projectID) ?: return false
            val root = directory.canonicalFile
            if (!root.isDirectory && !root.mkdirs()) return false
            val identity = identityOf(workspaceRoot) ?: return false
            val record = JSONObject()
                .put("version", 1)
                .put("projectID", projectID)
                .put("environmentID", environmentID)
                .put("baseRevision", baseRevision)
                .put("workspacePath", identity.path)
                .put("workspaceDevice", identity.device)
                .put("workspaceInode", identity.inode)
                .put("entryCount", entryCount).put("totalBytes", totalBytes)
                .put("clean", clean).put("ready", true)
                .put("runtimePid", RuntimeProcessIdentity.pid)
                .put("runtimeBootToken", RuntimeProcessIdentity.bootToken)
                .put("recordedAtMillis", System.currentTimeMillis())
            val bytes = record.toString().toByteArray(Charsets.UTF_8)
            if (bytes.size > MAX_RECEIPT_BYTES) return false
            val temp = File(root, ".receipt-${projectID}-${java.util.UUID.randomUUID()}.tmp")
            Files.newOutputStream(temp.toPath(), StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE).use { it.write(bytes) }
            Files.move(temp.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
            runCatching {
                java.nio.channels.FileChannel.open(root.toPath(), StandardOpenOption.READ).use { it.force(true) }
            }
            prune(root)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** True only when EVERY identity clause matches the live facts. */
    fun reusable(
        projectID: String,
        environmentID: String,
        baseRevision: String,
        workspaceRoot: File,
    ): Boolean = synchronized(lock) {
        return try {
            val target = fileFor(projectID) ?: return false
            if (!target.isFile || target.length() !in 1..MAX_RECEIPT_BYTES.toLong()) return false
            val record = JSONObject(String(Files.readAllBytes(target.toPath()), Charsets.UTF_8))
            val identity = identityOf(workspaceRoot) ?: return false
            record.optInt("version") == 1 &&
                record.optBoolean("ready") && record.optBoolean("clean") &&
                record.optString("projectID") == projectID &&
                record.optString("environmentID") == environmentID &&
                record.optString("baseRevision") == baseRevision &&
                record.optString("workspacePath") == identity.path &&
                record.optLong("workspaceDevice") == identity.device &&
                record.optLong("workspaceInode") == identity.inode &&
                record.optInt("runtimePid") == RuntimeProcessIdentity.pid &&
                record.optString("runtimeBootToken") == RuntimeProcessIdentity.bootToken
        } catch (_: Exception) {
            false
        }
    }

    /** A changed/removed workspace or a failed export invalidates reuse. */
    fun invalidate(projectID: String) = synchronized(lock) {
        runCatching { fileFor(projectID)?.delete() }
    }

    private data class Identity(val path: String, val device: Long, val inode: Long)

    private fun identityOf(workspaceRoot: File): Identity? {
        return try {
            val canonical = workspaceRoot.canonicalFile
            if (!canonical.isDirectory) {
                null
            } else {
                val path = canonical.toPath()
                val device = (Files.getAttribute(path, "unix:dev") as? Number)?.toLong()
                val inode = (Files.getAttribute(path, "unix:ino") as? Number)?.toLong()
                if (device == null || inode == null) null
                else Identity(canonical.path, device, inode)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun prune(root: File) {
        val files = root.listFiles { file -> file.isFile && file.name.startsWith("receipt-") }
            ?.sortedByDescending { it.lastModified() } ?: return
        files.drop(MAX_RECEIPTS).forEach { runCatching { it.delete() } }
    }

    companion object {
        private const val MAX_RECEIPT_BYTES = 4_096
        private const val MAX_RECEIPTS = 64
    }
}
