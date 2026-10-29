// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Download state is deliberately SEPARATE from install state: stopping a
 * download never claims that an already-committed install was cancelled, and
 * a committed PackageInstaller session keeps its own system-owned lifecycle.
 */
internal sealed interface AppDownloadState {
    data object Idle : AppDownloadState
    data class InProgress(val versionName: String, val received: Long, val total: Long) : AppDownloadState
    data class Verifying(val versionName: String) : AppDownloadState
    data class Ready(val versionName: String, val fileName: String, val sha256: String) : AppDownloadState
    data class Paused(val versionName: String, val received: Long, val total: Long) : AppDownloadState
    data class Failed(
        val versionName: String,
        val kind: DownloadFailure,
        val resumable: Boolean,
    ) : AppDownloadState
}

internal enum class DownloadFailure {
    NETWORK,
    DISK,
    SIZE_BUDGET,
    NO_CHECKSUM,
    CHECKSUM_MISMATCH,
    APK_IDENTITY,
    INVALID_ASSET,
}

/** Persisted staging record: enough to resume or verify after process death. */
internal data class DownloadMeta(
    val tag: String,
    val versionName: String,
    val fileName: String,
    val apkUrl: String,
    val checksumsUrl: String,
    val expectedSha256: String,
    val totalBytes: Long,
    val receivedBytes: Long,
    val etag: String?,
    val completed: Boolean,
) {
    fun toJson(): String = buildJsonObject {
        put("tag", tag)
        put("versionName", versionName)
        put("fileName", fileName)
        put("apkUrl", apkUrl)
        put("checksumsUrl", checksumsUrl)
        put("expectedSha256", expectedSha256)
        put("totalBytes", totalBytes)
        put("receivedBytes", receivedBytes)
        put("etag", etag ?: "")
        put("completed", completed)
    }.toString()

    companion object {
        fun fromJson(text: String?): DownloadMeta? {
            if (text.isNullOrBlank()) return null
            val obj = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
            fun string(key: String): String? =
                (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
            fun long(key: String): Long? = (obj[key] as? JsonPrimitive)?.longOrNull
            val tag = string("tag") ?: return null
            val versionName = string("versionName") ?: return null
            val fileName = string("fileName") ?: return null
            val apkUrl = string("apkUrl") ?: return null
            val checksumsUrl = string("checksumsUrl") ?: return null
            val expected = string("expectedSha256") ?: return null
            if (expected.isNotEmpty() && !expected.matches(Regex("[0-9a-f]{64}"))) return null
            if (fileName.isEmpty() || fileName.contains('/') || fileName.contains('\\')) return null
            if (!apkUrl.startsWith("https://") || !checksumsUrl.startsWith("https://")) return null
            val total = long("totalBytes") ?: -1L
            val received = long("receivedBytes") ?: 0L
            if (total != -1L && (total < 0L || total > AndroidReleaseFeed.MAX_APK_BYTES)) return null
            if (received < 0L || (total > 0L && received > total)) return null
            val etag = string("etag")?.takeIf { it.isNotEmpty() }
            val completed = (obj["completed"] as? JsonPrimitive)?.booleanOrNull ?: false
            return DownloadMeta(
                tag = tag,
                versionName = versionName,
                fileName = fileName,
                apkUrl = apkUrl,
                checksumsUrl = checksumsUrl,
                expectedSha256 = expected,
                totalBytes = total,
                receivedBytes = received,
                etag = etag,
                completed = completed,
            )
        }
    }
}

internal sealed interface ResumePlan {
    data class AppendFrom(val offset: Long) : ResumePlan
    data object Restart : ResumePlan
}

/**
 * Resume decision shared by the downloader and its tests.
 *
 * Appending staged bytes is allowed ONLY for a real HTTP 206 partial response
 * whose `Content-Range` starts at the exact staged offset, whose total still
 * matches, and whose `ETag` equals the staged artifact's `ETag`. Anything
 * else restarts from byte zero — a changed artifact must never be extended
 * with bytes of the previous one.
 */
internal object DownloadPlanning {
    fun plan(
        stagedBytes: Long,
        stagedEtag: String?,
        httpStatus: Int,
        contentRangeStart: Long?,
        contentRangeTotal: Long?,
        responseEtag: String?,
        expectedTotal: Long,
    ): ResumePlan {
        if (stagedBytes <= 0L) return ResumePlan.Restart
        if (httpStatus != 206) return ResumePlan.Restart
        if (contentRangeStart == null || contentRangeStart != stagedBytes) return ResumePlan.Restart
        if (contentRangeTotal != null && expectedTotal > 0L && contentRangeTotal != expectedTotal) {
            return ResumePlan.Restart
        }
        // No stable validator means the staged prefix cannot be attributed to
        // the artifact being served now: restart rather than mix bytes.
        if (stagedEtag.isNullOrEmpty() || responseEtag.isNullOrEmpty()) return ResumePlan.Restart
        if (stagedEtag != responseEtag) return ResumePlan.Restart
        return ResumePlan.AppendFrom(stagedBytes)
    }
}

/**
 * App-owned download engine.
 *
 * Writer ownership (Main critical review, 2026-10-29): exactly ONE download
 * writer may own the staging files at a time. `start`/`resume`/`discard` are
 * serialized by [transitions]: an old writer is signalled, its job is
 * cancelled AND joined (so its blocking read/stream close actually completed
 * and its `use` blocks closed the stream) before any file is deleted or a new
 * writer starts. Each writer carries its OWN cancellation flag and generation,
 * and every state/store write is identity-fenced to that writer, so a stale
 * `finally` or a late progress publish can never clear/overwrite a newer
 * writer. Cancellation is checked after every blocking read and before every
 * publish/persist/rename.
 */
internal class UpdateDownloader(
    private val scope: CoroutineScope,
    private val transport: DownloadTransport,
    private val store: UpdateStore,
    private val stagingDir: File,
    private val validate: (File) -> DownloadFailure?,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val mutable = MutableStateFlow<AppDownloadState>(AppDownloadState.Idle)
    val state: StateFlow<AppDownloadState> = mutable.asStateFlow()

    /** Serializes start/resume/discard transitions (cancel + join + delete). */
    private val transitions = Mutex()

    /** Guards the current writer identity and every state/store write. */
    private val writerLock = Any()
    private var writer: Writer? = null
    private val generations = AtomicLong(0)

    private class Writer(val generation: Long, val cancelled: AtomicBoolean) {
        lateinit var job: Job
    }

    /** Process-restart reconciliation of a staged/incomplete download. */
    fun reconcile() {
        synchronized(writerLock) {
            if (writer != null || mutable.value !is AppDownloadState.Idle) return
        }
        val meta = DownloadMeta.fromJson(store.pendingDownloadJson) ?: return
        val apk = apkFile(meta)
        if (meta.completed && apk.isFile && (meta.totalBytes <= 0L || apk.length() == meta.totalBytes)) {
            scope.launch(Dispatchers.IO) { transitions.withLock { verifyCompleted(meta, apk) } }
            return
        }
        val part = partFile(meta)
        if (part.isFile && part.length() > 0L) {
            synchronized(writerLock) {
                if (writer == null) {
                    mutable.value = AppDownloadState.Paused(meta.versionName, part.length(), meta.totalBytes)
                }
            }
        } else {
            store.pendingDownloadJson = null
        }
    }

    /** Starts (or resumes) the download for [release]. Never runs twice at once. */
    fun start(release: AndroidRelease) {
        val fileName = release.apk.name
        if (fileName.contains('/') || fileName.contains('\\')) {
            mutable.value = AppDownloadState.Failed(release.version.toString(), DownloadFailure.INVALID_ASSET, false)
            return
        }
        scope.launch(Dispatchers.IO) {
            transitions.withLock {
                val current = mutable.value
                if (current is AppDownloadState.Ready && current.fileName == fileName) {
                    val ready = apkFile(fileName)
                    if (ready.isFile && ready.length() > 0L) return@withLock
                }
                val runningVersion = when (current) {
                    is AppDownloadState.InProgress -> current.versionName
                    is AppDownloadState.Verifying -> current.versionName
                    else -> null
                }
                if (runningVersion == release.version.toString()) {
                    // Controller.startDownload already began this exact
                    // writer; the service action must not cancel and restart it.
                    return@withLock
                }
                cancelAndJoinWriter()
                val persisted = DownloadMeta.fromJson(store.pendingDownloadJson)
                val reusable = persisted != null &&
                    persisted.fileName == fileName &&
                    persisted.apkUrl == release.apk.downloadUrl &&
                    !persisted.completed
                val meta = if (reusable && persisted != null) {
                    persisted
                } else {
                    DownloadMeta(
                        tag = release.tag,
                        versionName = release.version.toString(),
                        fileName = fileName,
                        apkUrl = release.apk.downloadUrl,
                        checksumsUrl = release.checksums.downloadUrl,
                        expectedSha256 = "",
                        totalBytes = release.apk.sizeBytes,
                        receivedBytes = 0L,
                        etag = null,
                        completed = false,
                    )
                }
                beginWriter(meta)
            }
        }
    }

    /** Resumes a paused/incomplete download from persisted metadata. */
    fun resume() {
        scope.launch(Dispatchers.IO) {
            transitions.withLock {
                val active = mutable.value
                if (active is AppDownloadState.InProgress || active is AppDownloadState.Verifying) return@withLock
                val meta = DownloadMeta.fromJson(store.pendingDownloadJson) ?: return@withLock
                cancelAndJoinWriter()
                if (meta.completed) {
                    val apk = apkFile(meta)
                    if (apk.isFile) {
                        verifyCompleted(meta, apk)
                        return@withLock
                    }
                }
                beginWriter(meta)
            }
        }
    }

    /** Signals the current writer; its own catch publishes the paused state. */
    fun cancel() {
        val current = synchronized(writerLock) { writer }
        if (current == null) {
            publishPausedNoWriter()
            return
        }
        current.cancelled.set(true)
        current.job.cancel()
    }

    /** Explicit "delete the downloaded package" action. */
    fun discard() {
        scope.launch(Dispatchers.IO) {
            transitions.withLock {
                // The old writer's blocking read/stream close/completion must
                // finish BEFORE any staging byte is deleted.
                cancelAndJoinWriter()
                DownloadMeta.fromJson(store.pendingDownloadJson)?.let { meta ->
                    partFile(meta).delete()
                    apkFile(meta).delete()
                }
                stagingDir.listFiles()?.forEach { file -> file.delete() }
                store.pendingDownloadJson = null
                synchronized(writerLock) {
                    if (writer == null) mutable.value = AppDownloadState.Idle
                }
            }
        }
    }

    fun readyFile(): File? {
        val ready = mutable.value as? AppDownloadState.Ready ?: return null
        val file = File(stagingDir, ready.fileName)
        return file.takeIf { it.isFile }
    }

    /**
     * Cancels and JOINS the current writer. Clears the identity first so the
     * old writer's late catch/finally cannot publish into the next owner.
     */
    private suspend fun cancelAndJoinWriter() {
        val previous = synchronized(writerLock) {
            val current = writer
            writer = null
            current
        } ?: return
        previous.cancelled.set(true)
        previous.job.cancel()
        previous.job.join()
    }

    private fun beginWriter(initial: DownloadMeta) {
        prepareStaging(initial)
        val generation = generations.incrementAndGet()
        val owner = Writer(generation, AtomicBoolean(false))
        val job = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            runWriter(owner, initial)
        }
        owner.job = job
        synchronized(writerLock) { writer = owner }
        job.start()
    }

    private suspend fun runWriter(owner: Writer, initial: DownloadMeta) {
        try {
            stageAndDownload(owner, initial)
        } catch (cancellation: CancellationException) {
            publishPaused(owner)
            throw cancellation
        } catch (failure: StageFailure) {
            publish(owner, AppDownloadState.Failed(
                versionName = failure.versionName,
                kind = failure.kind,
                resumable = failure.resumable,
            ))
        } catch (failure: Exception) {
            val versionName = synchronized(writerLock) {
                if (writer === owner) {
                    DownloadMeta.fromJson(store.pendingDownloadJson)?.versionName ?: ""
                } else {
                    ""
                }
            }
            if (!owner.cancelled.get()) {
                publish(owner, AppDownloadState.Failed(versionName, DownloadFailure.NETWORK, true))
            }
        } finally {
            synchronized(writerLock) {
                if (writer === owner) writer = null
            }
        }
    }

    private fun checkCancelled(owner: Writer) {
        if (owner.cancelled.get()) throw CancellationException("download-cancelled")
    }

    private fun publish(owner: Writer, state: AppDownloadState) {
        synchronized(writerLock) {
            if (writer === owner) mutable.value = state
        }
    }

    private fun persist(owner: Writer, meta: DownloadMeta) {
        synchronized(writerLock) {
            if (writer === owner) store.pendingDownloadJson = meta.toJson()
        }
    }

    private suspend fun stageAndDownload(owner: Writer, initial: DownloadMeta) {
        checkCancelled(owner)
        var working = initial
        prepareStaging(working)
        if (working.expectedSha256.isEmpty()) {
            working = working.copy(expectedSha256 = fetchExpectedSha256(owner, working))
        }
        checkCancelled(owner)
        checkDisk(working)

        val part = partFile(working)
        var existing = if (part.isFile) part.length() else 0L
        if (working.totalBytes > 0L && existing > working.totalBytes) {
            part.delete()
            existing = 0L
        }

        var response = transport.open(working.apkUrl, existing.takeIf { it > 0L }, working.etag)
        checkCancelled(owner)
        var plan = DownloadPlanning.plan(
            stagedBytes = existing,
            stagedEtag = working.etag,
            httpStatus = response.code,
            contentRangeStart = response.contentRangeStart,
            contentRangeTotal = response.contentRangeTotal,
            responseEtag = response.etag,
            expectedTotal = working.totalBytes,
        )
        if (plan is ResumePlan.Restart && existing > 0L) {
            // The server answered a ranged request that cannot be appended;
            // drop the staged prefix and issue a fresh full request.
            runCatching { response.stream.close() }
            part.delete()
            existing = 0L
            response = transport.open(working.apkUrl, null, null)
            checkCancelled(owner)
            plan = ResumePlan.Restart
        }
        val startOffset = when (plan) {
            is ResumePlan.AppendFrom -> plan.offset
            ResumePlan.Restart -> 0L
        }
        val total = when {
            working.totalBytes > 0L -> working.totalBytes
            response.code == 206 -> response.contentRangeTotal ?: -1L
            response.contentLength > 0L -> response.contentLength
            else -> -1L
        }
        working = working.copy(
            receivedBytes = startOffset,
            etag = response.etag ?: working.etag,
            totalBytes = total,
        )
        checkCancelled(owner)
        persist(owner, working)
        publish(owner, AppDownloadState.InProgress(working.versionName, startOffset, total))

        var received = startOffset
        var lastPublishedAt = 0L
        val versionName = working.versionName
        FileOutputStream(part, startOffset > 0L).use { output ->
            response.stream.use { input ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    checkCancelled(owner)
                    val count = input.read(buffer)
                    // The read may have blocked for a long time: never write,
                    // publish, persist or rename after a cancellation.
                    checkCancelled(owner)
                    if (count < 0) break
                    received += count
                    if (received > AndroidReleaseFeed.MAX_APK_BYTES) {
                        throw StageFailure(versionName, DownloadFailure.SIZE_BUDGET, resumable = false)
                    }
                    output.write(buffer, 0, count)
                    checkCancelled(owner)
                    val now = nowMillis()
                    if (now - lastPublishedAt >= PROGRESS_INTERVAL_MS) {
                        lastPublishedAt = now
                        publish(owner, AppDownloadState.InProgress(versionName, received, total))
                    }
                }
            }
            output.fd.sync()
        }
        checkCancelled(owner)

        val completedMeta = working.copy(receivedBytes = received)
        if (total > 0L && received != total) {
            persist(owner, completedMeta)
            throw StageFailure(versionName, DownloadFailure.NETWORK, resumable = true)
        }

        publish(owner, AppDownloadState.Verifying(versionName))
        val actual = sha256(owner, part)
        checkCancelled(owner)
        if (!actual.equals(working.expectedSha256, ignoreCase = true)) {
            part.delete()
            synchronized(writerLock) { if (writer === owner) store.pendingDownloadJson = null }
            throw StageFailure(versionName, DownloadFailure.CHECKSUM_MISMATCH, resumable = false)
        }
        val apk = apkFile(working)
        if (apk.exists()) apk.delete()
        checkCancelled(owner)
        if (!part.renameTo(apk)) {
            throw StageFailure(versionName, DownloadFailure.DISK, resumable = true)
        }
        checkCancelled(owner)
        persist(owner, completedMeta.copy(completed = true))
        validate(apk)?.let { failure ->
            apk.delete()
            synchronized(writerLock) { if (writer === owner) store.pendingDownloadJson = null }
            throw StageFailure(versionName, failure, resumable = false)
        }
        publish(owner, AppDownloadState.Ready(versionName, working.fileName, actual))
    }

    private suspend fun verifyCompleted(meta: DownloadMeta, apk: File) {
        mutable.value = AppDownloadState.Verifying(meta.versionName)
        val actual = sha256(apk)
        if (!actual.equals(meta.expectedSha256, ignoreCase = true)) {
            apk.delete()
            store.pendingDownloadJson = null
            mutable.value = AppDownloadState.Failed(meta.versionName, DownloadFailure.CHECKSUM_MISMATCH, false)
            return
        }
        validate(apk)?.let { failure ->
            apk.delete()
            store.pendingDownloadJson = null
            mutable.value = AppDownloadState.Failed(meta.versionName, failure, false)
            return
        }
        mutable.value = AppDownloadState.Ready(meta.versionName, meta.fileName, actual)
    }

    private fun publishPaused(owner: Writer) {
        val meta = DownloadMeta.fromJson(store.pendingDownloadJson)
        if (meta == null) {
            publish(owner, AppDownloadState.Idle)
            return
        }
        val part = partFile(meta)
        val bytes = if (part.isFile) part.length() else meta.receivedBytes
        publish(
            owner,
            if (bytes > 0L) {
                AppDownloadState.Paused(meta.versionName, bytes, meta.totalBytes)
            } else {
                AppDownloadState.Idle
            },
        )
    }

    private fun publishPausedNoWriter() {
        val meta = DownloadMeta.fromJson(store.pendingDownloadJson)
        if (meta == null) {
            if (mutable.value is AppDownloadState.InProgress) mutable.value = AppDownloadState.Idle
            return
        }
        val part = partFile(meta)
        val bytes = if (part.isFile) part.length() else meta.receivedBytes
        synchronized(writerLock) {
            if (writer == null) {
                mutable.value = if (bytes > 0L) {
                    AppDownloadState.Paused(meta.versionName, bytes, meta.totalBytes)
                } else {
                    AppDownloadState.Idle
                }
            }
        }
    }

    private fun prepareStaging(meta: DownloadMeta) {
        stagingDir.mkdirs()
        val prefix = tagPrefix(meta)
        stagingDir.listFiles()?.forEach { file ->
            if (!file.name.startsWith(prefix)) file.delete()
        }
    }

    private fun checkDisk(meta: DownloadMeta) {
        val needed = (meta.totalBytes.takeIf { it > 0L } ?: 0L) + UpdateConfig.DISK_HEADROOM_BYTES
        val usable = stagingDir.usableSpace
        if (usable in 1L until needed) {
            throw StageFailure(meta.versionName, DownloadFailure.DISK, resumable = false)
        }
    }

    private suspend fun fetchExpectedSha256(owner: Writer, meta: DownloadMeta): String {
        val response = transport.open(meta.checksumsUrl, null, null)
        checkCancelled(owner)
        val text = response.stream.use { readBounded(it, AndroidReleaseFeed.MAX_CHECKSUMS_BYTES) }
        checkCancelled(owner)
        return Sha256Sums.parse(text)[meta.fileName]
            ?: throw StageFailure(meta.versionName, DownloadFailure.NO_CHECKSUM, resumable = false)
    }

    private fun readBounded(input: InputStream, limit: Long): String {
        val builder = StringBuilder()
        val buffer = ByteArray(8 * 1024)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > limit) throw IOException("checksums-oversized")
            builder.append(String(buffer, 0, count, Charsets.UTF_8))
        }
        return builder.toString()
    }

    private fun sha256(file: File): String = sha256(null, file)

    private fun sha256(owner: Writer?, file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(256 * 1024)
            while (true) {
                owner?.let { checkCancelled(it) }
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun partFile(meta: DownloadMeta): File = File(stagingDir, "${tagPrefix(meta)}.part")

    private fun apkFile(meta: DownloadMeta): File = File(stagingDir, meta.fileName)

    private fun apkFile(fileName: String): File = File(stagingDir, fileName)

    private fun tagPrefix(meta: DownloadMeta): String =
        meta.tag.replace('/', '_').replace('\\', '_').take(80)

    private class StageFailure(
        val versionName: String,
        val kind: DownloadFailure,
        val resumable: Boolean,
    ) : Exception(kind.name)

    private companion object {
        const val PROGRESS_INTERVAL_MS = 200L
    }
}
