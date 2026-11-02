// SPDX-License-Identifier: MPL-2.0

package com.floe.android.linuxruntime

import android.os.Build
import android.system.Os
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import org.json.JSONObject

/**
 * Default fake-free backend: real PTY, real fork/exec, real waitpid.
 *
 * @param pageSizeLink the ELF page size the native library was linked with
 *        (16KiB builds pass 16384). The runtime value is independently
 *        reported by the probe from the auxiliary vector.
 */
class DefaultLinuxRuntimeBackend(
    override val identity: BackendIdentity = BackendIdentity(
        name = "floe-linuxruntime",
        version = "0.1-r1",
        abi = "arm64-v8a",
        pageSizeLink = 16384,
        note = "launch-transport only; not a sandbox; not an environment database",
    ),
) : LinuxRuntimeBackend {

    override fun spawn(spec: LaunchSpec, timeoutMs: Long): SpawnOutcome {
        require(timeoutMs in 1..60_000) { "timeoutMs out of range" }
        val pair = PosixBridge.openPty()
        val masterFd = pair[0]
        val slaveFd = pair[1]
        val pipeStdin = spec.stdinDelivery == StdinDelivery.OneShotPipe
        // pid >= 0 on success; stdinWriteFd is the owned write end, only ever
        // >= 0 together with a successful pipe-mode spawn. Any thrown host
        // failure means the native layer never handed an fd back.
        class Raw(val pid: Int, val stdinWriteFd: Int)
        val raw = try {
            val sizeResult = PosixBridge.setWinsize(masterFd, spec.rows, spec.cols)
            if (sizeResult < 0) Raw(sizeResult, -1) else {
                val env = spec.env.entries.map { "${it.key}=${it.value}" }.toTypedArray()
                if (pipeStdin) {
                    val r = PosixBridge.spawnOnPtyStdinPipe(
                        masterFd, slaveFd, spec.executable,
                        spec.argv.toTypedArray(), env, spec.workingDir, timeoutMs.toInt(),
                    )
                    Raw(r[0], r[1])
                } else {
                    Raw(
                        PosixBridge.spawnOnPty(
                            masterFd, slaveFd, spec.executable,
                            spec.argv.toTypedArray(), env, spec.workingDir, timeoutMs.toInt(),
                        ),
                        -1,
                    )
                }
            }
        } catch (failure: Throwable) {
            PosixBridge.closeFd(masterFd)
            throw failure
        } finally {
            PosixBridge.closeFd(slaveFd)
        }
        if (raw.pid < 0) {
            // Defense in depth: the native contract already closes both pipe
            // ends on every failure path; an unexpected positive fd here is
            // still owned and closed, never leaked into the session table.
            if (raw.stdinWriteFd >= 0) PosixBridge.closeFd(raw.stdinWriteFd)
            PosixBridge.closeFd(masterFd)
            val errno = -raw.pid
            return SpawnOutcome.Failed(SpawnError(errno, errnoName(errno)))
        }
        val startTicks = PosixBridge.procStartTime(raw.pid)
        return SpawnOutcome.Spawned(
            DefaultPtySession(
                pid = raw.pid,
                creationIdentity = "${raw.pid}:$startTicks",
                executable = spec.executable,
                argv = spec.argv,
                ownership = spec.ownership,
                masterFd = masterFd,
                stdinWriteFd = raw.stdinWriteFd,
            ),
        )
    }

    /**
     * C01 separated-stdio spawn: the SAME caller-resolved guest launch
     * (executable/argv/env/cwd) but with three independent pipes and no
     * controlling terminal. A failure really means no owned child survives.
     */
    override fun spawnPipes(spec: LaunchSpec, timeoutMs: Long): PipeSpawnOutcome {
        require(timeoutMs in 1..60_000) { "timeoutMs out of range" }
        class Raw(val pid: Int, val stdinWriteFd: Int, val stdoutReadFd: Int, val stderrReadFd: Int)
        val env = spec.env.entries.map { "${it.key}=${it.value}" }.toTypedArray()
        val raw = try {
            val r = PosixBridge.spawnPipeProcess(
                spec.executable, spec.argv.toTypedArray(), env, spec.workingDir, timeoutMs.toInt(),
            )
            Raw(r[0], r[1], r[2], r[3])
        } catch (failure: Throwable) {
            throw failure
        }
        if (raw.pid < 0) {
            // Defense in depth: the native contract closes every fd on failure;
            // any unexpectedly positive fd is still owned and closed here.
            if (raw.stdinWriteFd >= 0) PosixBridge.closeFd(raw.stdinWriteFd)
            if (raw.stdoutReadFd >= 0) PosixBridge.closeFd(raw.stdoutReadFd)
            if (raw.stderrReadFd >= 0) PosixBridge.closeFd(raw.stderrReadFd)
            val errno = -raw.pid
            return PipeSpawnOutcome.Failed(SpawnError(errno, errnoName(errno)))
        }
        if (raw.stdinWriteFd < 0 || raw.stdoutReadFd < 0 || raw.stderrReadFd < 0) {
            // A successful pid without all three owned descriptors is never a
            // usable stdio channel: stop the real child tree and report it.
            runCatching { PosixBridge.kill(-raw.pid, 9) }
            runCatching { PosixBridge.kill(raw.pid, 9) }
            runCatching { PosixBridge.waitPidTimeout(raw.pid, 2_000) }
            if (raw.stdinWriteFd >= 0) PosixBridge.closeFd(raw.stdinWriteFd)
            if (raw.stdoutReadFd >= 0) PosixBridge.closeFd(raw.stdoutReadFd)
            if (raw.stderrReadFd >= 0) PosixBridge.closeFd(raw.stderrReadFd)
            return PipeSpawnOutcome.Failed(SpawnError(5 /* EIO */, "incomplete stdio descriptor set"))
        }
        val startTicks = PosixBridge.procStartTime(raw.pid)
        return PipeSpawnOutcome.Spawned(
            DefaultPipeSession(
                pid = raw.pid,
                creationIdentity = "${raw.pid}:$startTicks",
                executable = spec.executable,
                argv = spec.argv,
                ownership = spec.ownership,
                stdinWriteFd = raw.stdinWriteFd,
                stdoutReadFd = raw.stdoutReadFd,
                stderrReadFd = raw.stderrReadFd,
            ),
        )
    }

    internal class DefaultPipeSession(
        override val pid: Int,
        override val creationIdentity: String,
        override val executable: String,
        override val argv: List<String>,
        override val ownership: RunOwnership,
        private val stdinWriteFd: Int,
        private val stdoutReadFd: Int,
        private val stderrReadFd: Int,
    ) : PipeProcessSession {
        private val lifecycleLock = ReentrantLock(true)
        private val stdinLock = ReentrantLock(true)
        private val stdoutLock = ReentrantLock(true)
        private val stderrLock = ReentrantLock(true)
        private val stdinClosed = AtomicBoolean(false)
        private val streamsClosed = AtomicBoolean(false)
        private var exit: ExitResult? = null
        private var waitErrno = 0

        override fun readStdout(capacity: Int, timeoutMs: Long): ByteArray? =
            readStream(stdoutReadFd, stdoutLock, capacity, timeoutMs)

        override fun readStderr(capacity: Int, timeoutMs: Long): ByteArray? =
            readStream(stderrReadFd, stderrLock, capacity, timeoutMs)

        private fun readStream(fd: Int, lock: ReentrantLock, capacity: Int,
                               timeoutMs: Long): ByteArray? {
            require(capacity in 1..(1 shl 20))
            require(timeoutMs in 0..1000) { "read wait must leave cancellation responsive" }
            return lock.withLock {
                if (streamsClosed.get()) return null
                PosixBridge.readPipeTimeout(fd, capacity, timeoutMs.toInt())
            }
        }

        override fun writeStdin(data: ByteArray, offset: Int, length: Int): Int =
            stdinLock.withLock {
                if (stdinClosed.get()) return -9 /* EBADF */
                PosixBridge.writePipe(stdinWriteFd, data, offset, length)
            }

        override fun closeStdin(): Int = stdinLock.withLock {
            if (stdinClosed.compareAndSet(false, true)) PosixBridge.closeFd(stdinWriteFd) else 0
        }

        override fun closeStreams() {
            if (!streamsClosed.compareAndSet(false, true)) return
            stdoutLock.withLock { PosixBridge.closeFd(stdoutReadFd) }
            stderrLock.withLock { PosixBridge.closeFd(stderrReadFd) }
        }

        override fun pollExit(): ExitResult? = lifecycleLock.withLock {
            exit?.let { return it }
            decode(PosixBridge.pollWaitPid(pid))?.also { exit = it }
        }

        override fun awaitExit(timeoutMs: Long): ExitResult? {
            require(timeoutMs in 0..86_400_000)
            val deadline = android.os.SystemClock.elapsedRealtime() + timeoutMs
            while (true) {
                pollExit()?.let { return it }
                val remaining = deadline - android.os.SystemClock.elapsedRealtime()
                if (remaining <= 0 || Thread.currentThread().isInterrupted) return null
                try {
                    Thread.sleep(minOf(15, remaining))
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return null
                }
            }
        }

        /**
         * Release stdin, then TERM the exact owned process group, bounded
         * wait, KILL if still alive, reap the root, close output streams.
         * Every signal is preceded by the pid+start-time identity check, so a
         * recycled PID is never signalled.
         */
        override fun cancel(): ExitResult? = lifecycleLock.withLock {
            closeStdin()
            var last = exit
            if (last == null) {
                last = decode(PosixBridge.pollWaitPid(pid))
                if (last != null) exit = last
            }
            if (last == null && !isReapError()) {
                val nowTicks = PosixBridge.procStartTime(pid)
                if (nowTicks >= 0 && creationIdentity == "$pid:$nowTicks") {
                    // Polite stop first (the guest launcher/PRoot forwards it),
                    // then the bounded hard stop. Both address EXACTLY this
                    // session's process group (setsid => pgid == pid).
                    PosixBridge.kill(-pid, 15 /* SIGTERM */)
                    PosixBridge.kill(pid, 15)
                    var term = decode(PosixBridge.waitPidTimeout(pid, 2_000))
                    if (term == null) {
                        PosixBridge.kill(-pid, 9 /* SIGKILL */)
                        PosixBridge.kill(pid, 9)
                        term = decode(PosixBridge.waitPidTimeout(pid, 2_000))
                    }
                    var attempts = 0
                    while (term == null && attempts < 3) {
                        attempts++
                        term = decode(PosixBridge.waitPidTimeout(pid, 1_000))
                    }
                    last = term
                    exit = last
                }
            }
            closeStreams()
            return last
        }

        override fun lastWaitErrno(): Int = lifecycleLock.withLock { waitErrno }

        private fun isReapError(): Boolean = waitErrno == 10 /* ECHILD */

        private fun decode(r: IntArray): ExitResult? = when (r[0]) {
            1 -> ExitResult(r[1], signaled = false, termSig = 0)
            2 -> ExitResult(-1, signaled = true, termSig = r[2])
            3 -> {
                waitErrno = r[2]
                ExitResult(-1, signaled = false, termSig = 0, waitErrno = r[2])
            }
            else -> null
        }
    }

    internal class DefaultPtySession(
        override val pid: Int,
        override val creationIdentity: String,
        override val executable: String,
        override val argv: List<String>,
        override val ownership: RunOwnership,
        private val masterFd: Int,
        private val stdinWriteFd: Int = -1,
    ) : PtySession {
        // Lifecycle lock serializes poll/wait/cancel against ECHILD races and
        // PID-reuse windows; fd closure is tracked independently.
        private val lifecycleLock = ReentrantLock(true)
        private val ioLock = ReentrantLock(true)
        private val stdinLock = ReentrantLock(true)
        private val masterClosed = AtomicBoolean(false)
        private val stdinClosed = AtomicBoolean(false)
        private var exit: ExitResult? = null
        private var waitErrno = 0

        override val stdinDelivery: StdinDelivery
            get() = if (stdinWriteFd >= 0) StdinDelivery.OneShotPipe else StdinDelivery.PtyInput

        override fun writeStdinPipe(data: ByteArray, offset: Int, length: Int): Int =
            stdinLock.withLock {
                if (stdinWriteFd < 0) return@withLock -95 /* ENOTSUP: PTY delivery */
                if (stdinClosed.get()) return@withLock -9 /* EBADF: EOF already delivered */
                PosixBridge.writeStdinPipe(stdinWriteFd, data, offset, length)
            }

        override fun closeStdinPipe(): Int = stdinLock.withLock {
            if (stdinWriteFd < 0) return@withLock 0 /* no pipe: idempotent no-op */
            if (stdinClosed.compareAndSet(false, true)) PosixBridge.closeFd(stdinWriteFd)
            else 0 /* already closed: idempotent success */
        }

        override fun read(capacity: Int, timeoutMs: Long): ByteArray? = ioLock.withLock {
            require(capacity in 1..(1 shl 20))
            require(timeoutMs in 0..1000) { "read wait must leave cancellation responsive" }
            if (masterClosed.get()) return null
            PosixBridge.readMasterTimeout(masterFd, capacity, timeoutMs.toInt())
        }

        override fun write(data: ByteArray, offset: Int, length: Int): Int = ioLock.withLock {
            if (masterClosed.get()) return -9 /* EBADF */
            PosixBridge.writeMaster(masterFd, data, offset, length)
        }

        override fun resize(rows: Int, cols: Int): Boolean = ioLock.withLock {
            if (masterClosed.get()) return false
            PosixBridge.setWinsize(masterFd, rows, cols) == 0
        }

        override fun pollExit(): ExitResult? = lifecycleLock.withLock {
            exit?.let { return it }
            val r = PosixBridge.pollWaitPid(pid)
            decode(r)?.also { exit = it }
        }

        override fun awaitExit(timeoutMs: Long): ExitResult? {
            require(timeoutMs in 0..86_400_000)
            val deadline = android.os.SystemClock.elapsedRealtime() + timeoutMs
            while (true) {
                pollExit()?.let { return it }
                val remaining = deadline - android.os.SystemClock.elapsedRealtime()
                if (remaining <= 0 || Thread.currentThread().isInterrupted) return null
                try {
                    Thread.sleep(minOf(15, remaining))
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return null
                }
            }
        }

        override fun cancel(): ExitResult? {
            lifecycleLock.withLock {
                // Release owned stdin write-end FIRST: a killed child (or any
                // group member that survives the SIGKILL window) sees real EOF
                // instead of a dangling write end, and no session-cancelling
                // path can leave the descriptor open behind the lease.
                closeStdinPipe()
                var last = exit
                if (last == null) {
                    last = decode(PosixBridge.pollWaitPid(pid))
                    if (last != null) exit = last
                }
                if (last == null && !isReapError()) {
                    // PID-reuse guard: only signal if the live process is the
                    // child we created (pid + kernel start-time match).
                    val nowTicks = PosixBridge.procStartTime(pid)
                    if (nowTicks >= 0 && creationIdentity == "$pid:$nowTicks") {
                        // The child called setsid(): its process group id is its
                        // pid, so a negative kill reaches the whole group.
                        PosixBridge.kill(-pid, 9 /* SIGKILL */)
                        PosixBridge.kill(pid, 9)
                    }
                    // Reap with retries; a failed reap stays retryable because
                    // no cancellation latch hides an unreaped child.
                    var r = PosixBridge.waitPidTimeout(pid, 2_000)
                    var decoded = decode(r)
                    var attempts = 0
                    while (decoded == null && attempts < 3) {
                        attempts++
                        r = PosixBridge.waitPidTimeout(pid, 1_000)
                        decoded = decode(r)
                    }
                    last = decoded
                    exit = last
                }
                closeMasterLocked()
                return last
            }
        }

        override fun closeMaster() {
            closeMasterLocked()
        }

        override fun lastWaitErrno(): Int = lifecycleLock.withLock { waitErrno }

        private fun closeMasterLocked() = ioLock.withLock {
            if (masterClosed.compareAndSet(false, true)) PosixBridge.closeFd(masterFd)
        }

        private fun isReapError(): Boolean = waitErrno == 10 /* ECHILD */

        // state: {1,exitCode,0} / {2,0,sig} / {3,0,errno}; state 3 is surfaced
        // as an ExitResult with waitErrno, never as a silent null.
        private fun decode(r: IntArray): ExitResult? = when (r[0]) {
            1 -> ExitResult(r[1], signaled = false, termSig = 0)
            2 -> ExitResult(-1, signaled = true, termSig = r[2])
            3 -> {
                waitErrno = r[2]
                ExitResult(-1, signaled = false, termSig = 0, waitErrno = r[2])
            }
            else -> null
        }
    }

    companion object {
        /** Process-level facts the host can state without spawning a child. */
        fun hostIdentityJson(): String {
            val uid = Os.getuid()
            val pid = Os.getpid()
            val sdk = Build.VERSION.SDK_INT
            val rel = Build.VERSION.RELEASE ?: "?"
            val pageSize = PosixBridge.hostPageSize()
            val kernel = procRead("/proc/sys/kernel/ostype") + " " +
                procRead("/proc/sys/kernel/osrelease")
            val secontext = procRead("/proc/self/attr/current")
            return JSONObject().put("uid", uid).put("pid", pid).put("sdk", sdk)
                .put("release", rel).put("hostPageSize", pageSize).put("kernel", kernel)
                .put("seContext", secontext).toString()
        }

        fun procRead(path: String): String = try {
            java.io.File(path).readText().trim().trimEnd('\u0000')
        } catch (e: Exception) {
            "<unreadable:${e.javaClass.simpleName}>"
        }

        fun errnoName(errno: Int): String = when (errno) {
            1 -> "EPERM"; 2 -> "ENOENT"; 5 -> "EIO"; 8 -> "ENOEXEC"; 9 -> "EBADF"
            10 -> "ECHILD"; 13 -> "EACCES"; 14 -> "EFAULT"; 20 -> "ENOTDIR"
            21 -> "EISDIR"; 26 -> "ETXTBSY"; 36 -> "ENAMETOOLONG"; 40 -> "ELOOP"
            110 -> "spawn-timeout"
            else -> "errno=$errno"
        }
    }
}
