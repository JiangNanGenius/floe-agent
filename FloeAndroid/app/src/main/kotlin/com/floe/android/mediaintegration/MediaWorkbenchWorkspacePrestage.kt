// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import android.net.Uri
import android.webkit.MimeTypeMap
import com.floe.android.CreativeDocumentSourceStaging
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import java.io.File
import java.util.Locale
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Application-owned workspace prestage operation.
 *
 * The composable only OBSERVES this operation; it never owns the staging
 * lifetime. A rotation/background that drops the caller cannot cancel the
 * real worker: the exact deferred remains owned by the process scope and a
 * later composition with the same owner/path reattaches to the same result.
 * Root stop fences new work, cancels/adopts the exact workers and reports
 * FALSE until every native egress ticket has closed.
 *
 * A committed snapshot is registered with [CreativeDocumentSourceStaging] so
 * the existing import completion path can delete only this owned copy. The
 * original workspace file is never written or removed.
 */
internal class MediaWorkbenchWorkspacePrestage(
    root: File,
    private val scope: CoroutineScope,
    private val stager: MediaWorkspaceStager = MediaWorkspaceStager(root),
) {
    companion object {
        private const val MAX_JOBS = 8
        private const val STAGE_TTL_MILLIS = 10L * 60 * 1000
        private const val PROGRESS_STEP_BYTES = 4L * 1024 * 1024
    }

    data class Progress(val stagedBytes: Long, val totalBytes: Long)

    private data class Key(
        val taskID: String,
        val workspaceID: String,
        val nativeEpoch: Long,
        val hostGeneration: Long,
        val relativePath: String,
        val kind: String,
    )

    private class Job(
        val key: Key,
        val deferred: Deferred<MediaPickedSource>,
        val completed: AtomicReference<MediaPickedSource?>,
    ) {
        @Volatile var directory: File? = null
        @Volatile var failure: Throwable? = null
        @Volatile var claimed: Boolean = false
        @Volatile var lastUsedAt: Long = System.currentTimeMillis()

        fun completedResult(): MediaPickedSource? = completed.get()
    }

    private val lock = Any()
    private val jobs = LinkedHashMap<Key, Job>()

    private val mutableProgress = MutableStateFlow<Progress?>(null)
    val progress: StateFlow<Progress?> = mutableProgress

    @Volatile
    private var stopping = false

    /**
     * Returns a committed [MediaPickedSource] only after the full snapshot is
     * hashed, fsynced and atomically renamed. The job itself runs on the
     * Application scope; caller cancellation only abandons this await.
     */
    suspend fun stage(
        owner: MediaWorkspaceOwner,
        relativePath: String,
        kind: String,
        isCurrent: () -> Boolean,
    ): MediaPickedSource {
        val key = Key(
            taskID = owner.taskID,
            workspaceID = owner.workspaceID,
            nativeEpoch = owner.nativeEpoch,
            hostGeneration = owner.hostGeneration,
            relativePath = relativePath,
            kind = kind,
        )
        val cached = synchronized(lock) {
            if (stopping) {
                throw CreativeException(
                    "staleGeneration", "workspacePrestageStopping", retryable = true)
            }
            pruneLocked()
            val existing = jobs[key]
            if (existing != null && existing.deferred.isCompleted) {
                val result = existing.completedResult()
                if (existing.failure == null && result != null && stagedFileExists(result)) {
                    existing.claimed = true
                    existing.lastUsedAt = System.currentTimeMillis()
                    return@synchronized result
                }
                jobs.remove(key)
            }
            null
        }
        if (cached != null) return cached

        val job = synchronized(lock) {
            if (stopping) {
                throw CreativeException(
                    "staleGeneration", "workspacePrestageStopping", retryable = true)
            }
            jobs[key] ?: run {
                val completed = AtomicReference<MediaPickedSource?>(null)
                val created = scope.async(Dispatchers.IO) {
                    val source = runStage(owner, relativePath, kind, isCurrent)
                    completed.set(source)
                    source
                }
                val record = Job(key, created, completed)
                created.invokeOnCompletion { cause ->
                    if (cause == null) {
                        record.directory = record.completedResult()?.let { source ->
                            source.uri.path?.let { path -> File(path).parentFile }
                        }
                    } else {
                        record.failure = cause
                    }
                }
                jobs[key] = record
                record
            }
        }
        job.lastUsedAt = System.currentTimeMillis()
        try {
            val source = job.deferred.await()
            // Only a result actually returned to an import caller becomes
            // claimed; a cancelled await leaves it eligible for Root cleanup.
            job.claimed = true
            return source
        } catch (cancelled: CancellationException) {
            // The App-owned job keeps running; a later composition can still
            // reattach to the same key. Only the caller's observation stops.
            throw cancelled
        } catch (error: Throwable) {
            synchronized(lock) {
                if (jobs[key] === job) jobs.remove(key)
            }
            throw error
        }
    }

    private suspend fun runStage(
        owner: MediaWorkspaceOwner,
        relativePath: String,
        kind: String,
        isCurrent: () -> Boolean,
    ): MediaPickedSource = withContext(Dispatchers.IO) {
        var lastProgress = 0L
        val staged = stager.stage(
            owner = owner,
            relativePath = relativePath,
            kind = kind,
            isCurrent = { !stopping && isCurrent() },
            onProgress = { stagedBytes, totalBytes ->
                if (stagedBytes == totalBytes ||
                    stagedBytes - lastProgress >= PROGRESS_STEP_BYTES
                ) {
                    lastProgress = stagedBytes
                    mutableProgress.value = Progress(stagedBytes, totalBytes)
                }
            },
        )
        val directory = staged.file.parentFile ?: staged.file
        val uri = Uri.fromFile(staged.file)
        CreativeDocumentSourceStaging.register(uri, directory)
        MediaPickedSource(
            uri = uri,
            displayName = staged.displayName,
            mimeType = mimeTypeFor(staged.displayName),
            byteCount = staged.byteCount,
        )
    }

    /** Deletes exactly the owned snapshot registered for [uri], if any. */
    fun consume(uri: Uri) {
        val directory = CreativeDocumentSourceStaging.consume(uri) ?: return
        val canonical = runCatching { directory.canonicalFile }.getOrNull() ?: directory
        synchronized(lock) {
            val entry = jobs.entries.firstOrNull { (_, job) ->
                val staged = job.directory ?: return@firstOrNull false
                runCatching { staged.canonicalFile == canonical }.getOrDefault(false)
            }
            entry?.let { jobs.remove(it.key) }
        }
    }

    /** Root-stop step: refuse new prestage work immediately. */
    fun fenceForRootStop() {
        stopping = true
    }

    /**
     * A new accepted native bind re-arms this process owner.
     *
     * Completed snapshots are deliberately retained here: a same-epoch
     * rebind may happen while a caller is between stage-commit and import,
     * and deleting that directory would break the real import. Old-epoch
     * entries are bounded and are cleaned by Root retire/TTL/consume.
     */
    fun onNativeCreativeBound() {
        stopping = false
    }

    /**
     * Cancels/awaits every App-owned staging worker (which closes its exact
     * native egress ticket) and deletes only snapshots never returned to a
     * caller. FALSE means a worker is still owned; Root must stay bound.
     */
    suspend fun retireForRootStop(timeoutMillis: Long = 15_000L): Boolean {
        stopping = true
        val snapshot = synchronized(lock) { jobs.values.toList() }
        val budget = timeoutMillis.coerceIn(0L, 60_000L)
        val deadline = System.currentTimeMillis() + budget
        for (job in snapshot) {
            val left = deadline - System.currentTimeMillis()
            if (left <= 0L) return false
            val done = withTimeoutOrNull(left) {
                try {
                    job.deferred.await()
                } catch (cancelled: CancellationException) {
                    // The timeout cancels this caller's await; never swallow
                    // it or the report would claim a worker was drained. A
                    // Deferred that is itself cancelled has completed its
                    // finally block (ticket close/cleanup) and is drained.
                    if (!job.deferred.isCancelled) throw cancelled
                } catch (_: Throwable) {
                    // The worker closed its ticket and cleaned its own
                    // directory; it is drained.
                }
                true
            } ?: false
            if (!done) return false
        }
        val removable = synchronized(lock) {
            val values = jobs.values.toList()
            jobs.clear()
            values
        }
        for (job in removable) {
            if (!job.claimed) ownedDirectory(job)?.let { deleteOwned(it) }
        }
        mutableProgress.value = null
        return true
    }

    /** Active workers only; a committed, not yet consumed snapshot is not work. */
    fun pendingCount(): Int = synchronized(lock) {
        jobs.values.count { !it.deferred.isCompleted }
    }

    fun diagnosticSummary(): String =
        "workspacePrestage=${pendingCount()}"

    private fun pruneLocked() {
        val now = System.currentTimeMillis()
        val iterator = jobs.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            val job = entry.value
            if (!job.deferred.isCompleted) continue
            if (now - job.lastUsedAt <= STAGE_TTL_MILLIS && jobs.size <= MAX_JOBS) continue
            if (!job.claimed) ownedDirectory(job)?.let { deleteOwned(it) }
            iterator.remove()
        }
    }

    private fun ownedDirectory(job: Job): File? =
        job.directory ?: job.completedResult()?.let { source ->
            source.uri.path?.let { path -> File(path).parentFile }
        }

    private fun stagedFileExists(source: MediaPickedSource): Boolean {
        val path = source.uri.path ?: return false
        return runCatching { File(path).isFile }.getOrDefault(false)
    }

    private fun deleteOwned(directory: File) {
        runCatching {
            directory.listFiles()?.forEach { it.delete() }
            directory.delete()
        }
    }

    private fun mimeTypeFor(displayName: String): String? {
        val extension = displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
    }
}
