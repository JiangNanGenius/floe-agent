// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.content.Context
import android.os.Process as AndroidProcess
import android.system.Os
import android.system.OsConstants
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

/**
 * Typed, root-only packet-capture helper process manager.
 *
 * This is the only place that executes a capture helper. The request supplies
 * a closed helper id, an interface name and numeric bounds; it never supplies
 * a command, shell expression or arbitrary executable path.
 *
 * The executable identity is not inferred from `isFile/canExecute`. It is
 * resolved by [RootCaptureHelper] from the signed/installed Floe Full package,
 * verified against the packaged digest manifest and executed either from the
 * package-manager native library directory or an exact digest-addressed copy
 * below a root-owned 0700 tree with validated ancestry. A writable tmp path or
 * an OEM system binary is never accepted merely because it is executable.
 *
 * File ownership follows the process: no read/finish/delete occurs while the
 * helper process is alive, and a failed stop keeps the same session available
 * for a later retry. Bytes are deleted only after the process exited and the
 * requested read offset reached the final file length. A 60 s client lease
 * watchdog (in this root-server process, independent of the destroyed App
 * Service) stops a helper whose App owner vanished and finishes only after the
 * actual process exit; the duration/size limits remain the hard outer bound.
 */
internal class RootCaptureSessions(
    private val context: Context,
) : Closeable {

    class OpException(val code: String) : Exception(code)

    data class StartResult(
        val captureId: String,
        val helperPath: String,
        val helperSha256: String,
    )

    data class Chunk(
        val bytes: ByteArray,
        val done: Boolean,
        val bytesRead: Long,
        val endReason: String?,
    )

    private data class LeaseTombstone(
        val captureId: String,
        val endedAtMillis: Long,
        val endReason: String,
    )

    private class Session(
        val id: String,
        val requestId: String,
        val process: Process,
        val file: File,
        val maxBytes: Long,
        val deadlineMillis: Long,
        val helperPath: String,
        val helperSha256: String,
        var offset: Long = 0,
        var endReason: String? = null,
        @Volatile var lastClientActivityMillis: Long = System.currentTimeMillis(),
        var cancelRequested: Boolean = false,
        var watchdog: Thread? = null,
        var drainer: Thread? = null,
        var reaper: Thread? = null,
    )

    private val lock = Any()
    // The helper runs in a root/SELinux domain, not the App sandbox. Its
    // output lives under our root-owned 0700 tree with validated no-symlink
    // ancestry, never in a shell-writable tmp path or App-owned cache. A
    // failure is reported per start instead of falling back to an unsafe path.
    private val directory: File? = runCatching {
        RootCaptureHelper.prepareWorkDirectory()
    }.getOrNull()
    private var session: Session? = null
    private var closed = false
    // A lease-ended capture can still be named by the App's existing client
    // (it may have been paused, not dead). Keep a bounded tombstone so a late
    // read/stop receives done=true with an honest reason instead of retrying
    // capture_unknown forever. No bytes or live owner are retained here.
    private var leaseTombstone: LeaseTombstone? = null

    init {
        // Orderly root-server exit (typed stopServer or System.exit) must not
        // leave the helper process orphaned. SIGKILL cannot be handled from
        // inside the dying process; the App-side lease (client) and the
        // duration bound cover the App-death case while this server is alive.
        runCatching {
            Runtime.getRuntime().addShutdownHook(
                Thread({ runCatching { close() } }, "floe-root-capture-shutdown"),
            )
        }
    }

    fun start(
        requestId: String,
        helperId: String,
        interfaceName: String,
        snaplen: Int,
        maxBytes: Long,
        maxMillis: Long,
    ): StartResult = synchronized(lock) {
        if (closed) throw OpException("closed")
        if (AndroidProcess.myUid() != 0) throw OpException("root_required")
        if (session != null) throw OpException("capture_active")
        if (requestId.isBlank() || requestId.length > 128) throw OpException("request")
        if (helperId != HELPER_ID) throw OpException("helper_id")
        if (interfaceName != "any" && !INTERFACE.matches(interfaceName)) {
            throw OpException("interface")
        }
        if (snaplen !in 64..65_535) throw OpException("snaplen")
        if (maxBytes !in 1L..MAX_BYTES) throw OpException("max_bytes")
        if (maxMillis !in 1_000L..MAX_MILLIS) throw OpException("max_millis")
        val helper = try {
            RootCaptureHelper.resolveForServer(context)
        } catch (failure: RootCaptureHelper.HelperException) {
            throw OpException(failure.code)
        } catch (_: Throwable) {
            throw OpException("helper_unavailable")
        }
        val working = directory ?: throw OpException("helper_path_unsafe")
        val file = createCaptureFile(working)
        val process = try {
            ProcessBuilder(
                helper.path.absolutePath,
                "-i", interfaceName,
                "-s", snaplen.toString(),
                "-w", file.absolutePath,
                "-U",
            ).redirectErrorStream(true).start()
        } catch (_: Throwable) {
            file.delete()
            throw OpException("helper_start")
        }
        val value = Session(
            id = UUID.randomUUID().toString(),
            requestId = requestId,
            process = process,
            file = file,
            maxBytes = maxBytes,
            deadlineMillis = System.currentTimeMillis() + maxMillis,
            helperPath = helper.path.absolutePath,
            helperSha256 = helper.sha256,
        )
        value.lastClientActivityMillis = System.currentTimeMillis()
        session = value
        value.drainer = drainAsync(process)
        value.watchdog = Thread({ watchdog(value) }, "floe-root-capture-watchdog").also {
            it.isDaemon = true
            it.start()
        }
        StartResult(value.id, value.helperPath, value.helperSha256)
    }

    fun read(captureId: String, maxBytes: Int): Chunk =
        synchronized(lock) { readLocked(captureId, maxBytes) }

    private fun readLocked(captureId: String, maxBytes: Int): Chunk {
        tombstoneChunkLocked(captureId)?.let { return it }
        val current = requireSession(captureId)
        current.lastClientActivityMillis = System.currentTimeMillis()
        val limit = maxBytes.coerceIn(1, MAX_CHUNK)
        val file = current.file
        val length = runCatching { file.length() }.getOrDefault(0L)
        if (length <= current.offset) {
            val done = !current.process.isAlive && current.offset >= length
            if (done) finishSession(current)
            return Chunk(ByteArray(0), done, current.offset, current.endReason)
        }
        val remaining = (length - current.offset).coerceAtMost(limit.toLong()).toInt()
        if (remaining <= 0) {
            return Chunk(ByteArray(0), false, current.offset, current.endReason)
        }
        val bytes = ByteArray(remaining)
        val read = try {
            RandomAccessFile(file, "r").use { input ->
                input.seek(current.offset)
                input.read(bytes)
            }
        } catch (_: Throwable) {
            throw OpException("capture_read")
        }
        if (read <= 0) {
            return Chunk(ByteArray(0), false, current.offset, current.endReason)
        }
        current.offset += read
        val finalLength = runCatching { file.length() }.getOrDefault(length)
        val done = !current.process.isAlive && current.offset >= finalLength
        if (done) finishSession(current)
        return Chunk(bytes.copyOf(read), done, current.offset, current.endReason)
    }

    fun stop(captureId: String): Chunk = synchronized(lock) { stopLocked(captureId) }

    private fun stopLocked(captureId: String): Chunk {
        tombstoneChunkLocked(captureId)?.let { return it }
        val current = requireSession(captureId)
        current.lastClientActivityMillis = System.currentTimeMillis()
        current.endReason = current.endReason ?: "userStop"
        val exited = destroyAndAwait(current)
        if (!exited) {
            // The process still owns the file. Do not delete, rename, finish
            // or claim a clean stop; the same session is retried by a later
            // stop/read call.
            current.endReason = "stopTimeout"
            return Chunk(ByteArray(0), false, current.offset, current.endReason)
        }
        joinAuxiliary(current)
        val length = runCatching { current.file.length() }.getOrDefault(0L)
        val done = current.offset >= length
        if (done) finishSession(current)
        return Chunk(ByteArray(0), done, current.offset, current.endReason)
    }

    fun cancel(requestId: String) {
        synchronized(lock) { cancelLocked(requestId) }
    }

    private fun cancelLocked(requestId: String) {
        val current = session?.takeIf { it.requestId == requestId } ?: return
        current.lastClientActivityMillis = System.currentTimeMillis()
        current.cancelRequested = true
        current.endReason = "cancelled"
        val exited = destroyAndAwait(current)
        if (exited) {
            joinAuxiliary(current)
            // No reader will ask for this capture again: the grant is being
            // revoked. The process is proven dead before its file is removed.
            current.file.delete()
            if (session === current) session = null
        } else if (current.reaper == null) {
            current.reaper = Thread({ reapCancelled(current) }, "floe-root-capture-reaper")
                .also { it.isDaemon = true; it.start() }
        }
    }

    override fun close() {
        val current = synchronized(lock) {
            if (closed) return
            closed = true
            session
        } ?: return
        synchronized(lock) {
            current.cancelRequested = true
            current.endReason = current.endReason ?: "serviceStop"
            if (destroyAndAwait(current)) {
                joinAuxiliary(current)
                current.file.delete()
                if (session === current) session = null
            } else {
                // The server process is exiting; keep a reaper that kills the
                // orphan and deletes only after its actual exit. Never unlink
                // a live writer's output.
                if (current.reaper == null) {
                    current.reaper = Thread({ reapCancelled(current) }, "floe-root-capture-reaper")
                        .also { it.isDaemon = true; it.start() }
                }
                if (session === current) session = null
            }
        }
    }

    private fun requireSession(captureId: String): Session =
        session?.takeIf { it.id == captureId } ?: throw OpException("capture_unknown")

    /** Returns true only after the actual process exited. */
    private fun destroyAndAwait(current: Session): Boolean {
        runCatching { current.process.destroy() }
        if (runCatching {
                current.process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)
            }.getOrDefault(false)
        ) {
            return true
        }
        runCatching { current.process.destroyForcibly() }
        return runCatching {
            current.process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)
        }.getOrDefault(false) && !current.process.isAlive
    }

    private fun joinAuxiliary(current: Session, includeWatchdog: Boolean = true) {
        if (includeWatchdog) {
            current.watchdog?.let { thread ->
                runCatching { thread.join(500L) }
            }
        }
        current.drainer?.let { thread ->
            runCatching { thread.join(500L) }
        }
    }

    private fun finishSession(current: Session) {
        if (current.process.isAlive) return
        stopProcess(current)
        joinAuxiliary(current)
        current.file.delete()
        if (session === current) session = null
    }

    private fun reapCancelled(current: Session) {
        try {
            while (current.process.isAlive) {
                runCatching { current.process.destroyForcibly() }
                runCatching { current.process.waitFor(250, java.util.concurrent.TimeUnit.MILLISECONDS) }
            }
            if (!current.process.isAlive) {
                joinAuxiliary(current)
                current.file.delete()
                synchronized(lock) {
                    if (session === current) session = null
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun stopProcess(current: Session) {
        runCatching { current.process.destroy() }
        if (current.process.isAlive) {
            runCatching { current.process.destroyForcibly() }
        }
        runCatching { current.process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS) }
    }

    private fun watchdog(current: Session) {
        try {
            while (!closed && current.process.isAlive) {
                val now = System.currentTimeMillis()
                val size = runCatching { current.file.length() }.getOrDefault(0L)
                if (size >= current.maxBytes) {
                    current.endReason = "sizeLimit"
                    stopProcess(current)
                    return
                }
                if (now >= current.deadlineMillis) {
                    current.endReason = "durationLimit"
                    stopProcess(current)
                    return
                }
                if (now - current.lastClientActivityMillis >= CLIENT_LEASE_MILLIS) {
                    // The App process that owns this capture stopped reading
                    // and stopping. Bound the orphaned helper here (this
                    // watchdog lives in the separate root-server process, not
                    // in the destroyed App Service) and retire only after the
                    // actual process exit.
                    current.endReason = "clientLease"
                    stopProcess(current)
                    if (!current.process.isAlive) {
                        // This thread is the watchdog itself; never join self.
                        current.watchdog = null
                        joinAuxiliary(current, includeWatchdog = false)
                        finishLease(current)
                    }
                    return
                }
                Thread.sleep(250L)
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun tombstoneChunkLocked(captureId: String): Chunk? {
        val tombstone = leaseTombstone ?: return null
        if (System.currentTimeMillis() - tombstone.endedAtMillis > LEASE_TOMBSTONE_MILLIS) {
            leaseTombstone = null
            return null
        }
        if (tombstone.captureId != captureId) return null
        return Chunk(
            bytes = ByteArray(0),
            done = true,
            bytesRead = 0L,
            endReason = tombstone.endReason,
        )
    }

    /** Client-lease end: process is already dead; no tail was consumed. */
    private fun finishLease(current: Session) {
        if (current.process.isAlive) return
        stopProcess(current)
        joinAuxiliary(current, includeWatchdog = false)
        current.file.delete()
        synchronized(lock) {
            if (session === current) session = null
            leaseTombstone = LeaseTombstone(
                captureId = current.id,
                endedAtMillis = System.currentTimeMillis(),
                endReason = "clientLease",
            )
        }
    }

    private fun createCaptureFile(directory: File): File {
        val file = File(directory, "capture-${UUID.randomUUID()}.pcap")
        val fd = try {
            Os.open(
                file.absolutePath,
                OsConstants.O_RDWR or OsConstants.O_CREAT or OsConstants.O_EXCL or
                    OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC,
                0x180, // 0600
            )
        } catch (_: Throwable) {
            throw OpException("capture_file")
        }
        runCatching { Os.close(fd) }
        runCatching { Os.chmod(file.absolutePath, 0x180) }
        return file
    }

    private fun drainAsync(process: Process): Thread =
        Thread({
            runCatching {
                process.inputStream.use { input ->
                    val buffer = ByteArray(8 * 1024)
                    while (input.read(buffer) >= 0) {
                        // Drain the helper's merged stderr/stdout; no content
                        // is retained or logged.
                    }
                }
            }
        }, "floe-root-capture-drain").also {
            it.isDaemon = true
            it.start()
        }

    private companion object {
        const val HELPER_ID = "tcpdump-v1"
        const val MAX_BYTES = 128L * 1024L * 1024L
        const val MAX_MILLIS = 5L * 60L * 1000L
        const val MAX_CHUNK = 256 * 1024
        /** No client read/stop for this long => the App owner is gone. */
        const val CLIENT_LEASE_MILLIS = 60_000L
        const val LEASE_TOMBSTONE_MILLIS = 10L * 60L * 1000L
        val INTERFACE = Regex("^[A-Za-z0-9_.:-]{1,32}$")
    }
}
