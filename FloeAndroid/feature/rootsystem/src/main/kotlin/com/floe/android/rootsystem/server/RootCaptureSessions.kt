// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.content.Context
import android.os.Process
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

/**
 * Typed, root-only packet-capture helper process manager.
 *
 * This is the only place that executes a capture helper. The request supplies
 * a closed helper id, an interface name and numeric bounds; it never supplies
 * a command, shell expression or arbitrary executable path. The helper must
 * already exist in a fixed root-owned location (the project source/binding
 * document names the pinned build); this class never downloads one.
 */
internal class RootCaptureSessions(
    context: Context,
) : Closeable {

    class OpException(val code: String) : Exception(code)

    data class StartResult(val captureId: String, val helperPath: String)

    data class Chunk(
        val bytes: ByteArray,
        val done: Boolean,
        val bytesRead: Long,
        val endReason: String?,
    )

    private class Session(
        val id: String,
        val requestId: String,
        val process: Process,
        val file: File,
        val maxBytes: Long,
        val deadlineMillis: Long,
        val helperPath: String,
        var offset: Long = 0,
        var endReason: String? = null,
        var watchdog: Thread? = null,
    )

    private val lock = Any()
    private val directory = File(context.cacheDir, "floe-root-capture").apply { mkdirs() }
    private var session: Session? = null
    private var closed = false

    fun start(
        requestId: String,
        helperId: String,
        interfaceName: String,
        snaplen: Int,
        maxBytes: Long,
        maxMillis: Long,
    ): StartResult = synchronized(lock) {
        if (closed) throw OpException("closed")
        if (Process.myUid() != 0) throw OpException("root_required")
        if (session != null) throw OpException("capture_active")
        if (requestId.isBlank() || requestId.length > 128) throw OpException("request")
        if (helperId != HELPER_ID) throw OpException("helper_id")
        if (interfaceName != "any" && !INTERFACE.matches(interfaceName)) {
            throw OpException("interface")
        }
        if (snaplen !in 64..65_535) throw OpException("snaplen")
        if (maxBytes !in 1L..MAX_BYTES) throw OpException("max_bytes")
        if (maxMillis !in 1_000L..MAX_MILLIS) throw OpException("max_millis")
        val helper = helperCandidates().firstOrNull { candidate ->
            candidate.isFile && candidate.canExecute()
        } ?: throw OpException("helper_unavailable")
        val file = File(directory, "capture-${UUID.randomUUID()}.pcap")
        val process = try {
            ProcessBuilder(
                helper.absolutePath,
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
            helperPath = helper.absolutePath,
        )
        session = value
        drainAsync(process)
        value.watchdog = Thread({ watchdog(value) }, "floe-root-capture-watchdog").also {
            it.isDaemon = true
            it.start()
        }
        StartResult(value.id, helper.absolutePath)
    }

    fun read(captureId: String, maxBytes: Int): Chunk =
        synchronized(lock) { readLocked(captureId, maxBytes) }

    private fun readLocked(captureId: String, maxBytes: Int): Chunk {
        val current = requireSession(captureId)
        val limit = maxBytes.coerceIn(1, MAX_CHUNK)
        val file = current.file
        if (!file.isFile || file.length() <= current.offset) {
            val done = !current.process.isAlive
            if (done) finishSession(current)
            return Chunk(ByteArray(0), done, current.offset, current.endReason)
        }
        val remaining = (file.length() - current.offset).coerceAtMost(limit.toLong()).toInt()
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
        val done = !current.process.isAlive && current.offset >= file.length()
        if (done) finishSession(current)
        return Chunk(bytes.copyOf(read), done, current.offset, current.endReason)
    }

    fun stop(captureId: String): Chunk = synchronized(lock) { stopLocked(captureId) }

    private fun stopLocked(captureId: String): Chunk {
        val current = requireSession(captureId)
        current.endReason = current.endReason ?: "userStop"
        stopProcess(current)
        if (current.process.isAlive) {
            current.endReason = "stopTimeout"
        }
        return Chunk(ByteArray(0), false, current.offset, current.endReason)
    }

    fun cancel(requestId: String) {
        synchronized(lock) { cancelLocked(requestId) }
    }

    private fun cancelLocked(requestId: String) {
        val current = session?.takeIf { it.requestId == requestId } ?: return
        current.endReason = "cancelled"
        stopProcess(current)
        current.file.delete()
        if (session === current) session = null
    }

    private fun requireSession(captureId: String): Session =
        session?.takeIf { it.id == captureId } ?: throw OpException("capture_unknown")

    private fun stopProcess(current: Session) {
        runCatching { current.process.destroy() }
        if (current.process.isAlive) {
            runCatching { current.process.destroyForcibly() }
        }
        runCatching { current.process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS) }
    }

    private fun finishSession(current: Session) {
        stopProcess(current)
        current.file.delete()
        if (session === current) session = null
    }

    private fun watchdog(current: Session) {
        try {
            while (!closed && current.process.isAlive) {
                val size = runCatching { current.file.length() }.getOrDefault(0L)
                if (size >= current.maxBytes) {
                    current.endReason = "sizeLimit"
                    stopProcess(current)
                    return
                }
                if (System.currentTimeMillis() >= current.deadlineMillis) {
                    current.endReason = "durationLimit"
                    stopProcess(current)
                    return
                }
                Thread.sleep(250L)
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun drainAsync(process: Process) {
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
    }

    private fun helperCandidates(): List<File> = listOf(
        File("/data/local/tmp/floe/tcpdump"),
        File("/system/bin/tcpdump"),
        File("/system/xbin/tcpdump"),
    )

    private companion object {
        const val HELPER_ID = "tcpdump-v1"
        const val MAX_BYTES = 128L * 1024L * 1024L
        const val MAX_MILLIS = 5L * 60L * 1000L
        const val MAX_CHUNK = 256 * 1024
        val INTERFACE = Regex("^[A-Za-z0-9_.:-]{1,32}$")
    }
}
