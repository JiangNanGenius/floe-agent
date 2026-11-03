// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.nio.file.Files
import java.util.ArrayDeque
import org.json.JSONObject

/** Non-mutating bounded measurement. Unknown is never represented as zero.
 * Logical bytes and allocated file blocks are separate; one inode is counted
 * once across a caller's categories. No path or file content leaves the owner. */
class StorageUsageMeter(
    private val maxEntries: Int = 50_000,
    private val maxMillis: Long = 1_500,
) {
    data class Usage(
        val logicalBytes: Long?,
        val allocatedBytes: Long?,
        val complete: Boolean,
        val files: Int,
        val sharedFiles: Int,
        val reason: String? = null,
        val retainedSpecialEntries: Int = 0,
    )

    private val counted = HashSet<Pair<Long, Long>>()

    fun measure(root: File, excludedChildren: Set<String> = emptySet()): Usage {
        val admittedRoot = try { root.canonicalFile.toPath() } catch (_: Exception) {
            return Usage(null, null, false, 0, 0, "unreadable")
        }
        val deadline = SystemClock.elapsedRealtime() + maxMillis
        val queue = ArrayDeque<Pair<File, Int>>()
        queue.add(root to 0)
        var logical = 0L
        var allocated = 0L
        var files = 0
        var shared = 0
        var special = 0
        var visited = 0
        var complete = true
        var reason: String? = null
        fun partial(code: String) { complete = false; if (reason == null) reason = code }
        while (queue.isNotEmpty()) {
            if (Thread.currentThread().isInterrupted || visited >= maxEntries ||
                SystemClock.elapsedRealtime() >= deadline) { partial("boundedScan"); break }
            val (file, depth) = queue.removeFirst()
            visited++
            val stat = try { Os.lstat(file.path) } catch (failure: ErrnoException) {
                if (!(depth == 0 && failure.errno == OsConstants.ENOENT)) partial("unreadable")
                continue
            } catch (_: Exception) { partial("unreadable"); continue }
            if (depth > 0 && try { !file.parentFile.canonicalFile.toPath().startsWith(admittedRoot) } catch (_: Exception) { true }) {
                partial("symlinkRetained"); continue
            }
            if (!counted.add(stat.st_dev to stat.st_ino)) { shared++; continue }
            try {
                allocated = Math.addExact(allocated, Math.multiplyExact(stat.st_blocks, 512L))
                if (OsConstants.S_ISLNK(stat.st_mode)) {
                    // Count the link inode itself, never its target. A complete
                    // size inventory does not authorize deleting that link.
                    special++
                    logical = Math.addExact(logical, stat.st_size)
                } else if (OsConstants.S_ISREG(stat.st_mode)) {
                    logical = Math.addExact(logical, stat.st_size)
                    files++
                    if (stat.st_nlink > 1) shared++
                } else if (OsConstants.S_ISDIR(stat.st_mode)) {
                    if (depth >= 64) { partial("boundedDepth"); continue }
                    Files.newDirectoryStream(file.toPath()).use { stream ->
                        for (child in stream) {
                            if (depth == 0 && child.fileName.toString() in excludedChildren) continue
                            if (queue.size + visited >= maxEntries) { partial("boundedScan"); break }
                            queue.add(child.toFile() to depth + 1)
                        }
                    }
                } else special++
            } catch (_: Exception) { partial("unreadable") }
        }
        return Usage(
            logicalBytes = if (complete || files > 0) logical else null,
            allocatedBytes = if (complete || files > 0) allocated else null,
            complete = complete,
            files = files,
            sharedFiles = shared,
            reason = reason,
            retainedSpecialEntries = special,
        )
    }
}

fun storageUsageJSON(id: String, usage: StorageUsageMeter.Usage): JSONObject = JSONObject()
    .put("id", id).put("logicalBytes", usage.logicalBytes ?: JSONObject.NULL)
    .put("allocatedBytes", usage.allocatedBytes ?: JSONObject.NULL)
    .put("complete", usage.complete).put("files", usage.files)
    .put("sharedFiles", usage.sharedFiles).put("reason", usage.reason ?: JSONObject.NULL)
    .put("retainedSpecialEntries", usage.retainedSpecialEntries)
