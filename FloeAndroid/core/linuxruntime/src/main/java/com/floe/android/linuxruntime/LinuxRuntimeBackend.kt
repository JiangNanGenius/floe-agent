// SPDX-License-Identifier: MPL-2.0
//
// Floe Android Linux runtime launch-transport backend (G03-R1).
//
// This module is a *launch transport only*: it creates PTYs, spawns owned
// child processes and reports their output/exit/cancellation. It is NOT a
// security sandbox and NOT an authoritative environment/job database.
// Environment/task/project identity and write-layer selection are explicit
// caller-supplied inputs (FloeEnvironments remains the authority); this
// backend only carries them, it never invents or resolves them.

package com.floe.android.linuxruntime

import org.json.JSONObject

/** Identity of this backend build, reported verbatim in self-test output. */
data class BackendIdentity(
    val name: String,
    val version: String,
    val abi: String,
    val pageSizeLink: Int,
    val note: String,
) {
    fun toJson(): String =
        JSONObject().put("name", name).put("version", version).put("abi", abi)
            .put("pageSizeLink", pageSizeLink).put("note", note).toString()
}

/**
 * Caller-resolved ownership snapshot for one launch. Carried verbatim by the
 * session for attribution and audit; the backend creates no registry and
 * grants no authority from these values.
 */
data class RunOwnership(
    val environmentId: String,
    val taskId: String,
    val projectId: String,
    val writeLayer: String,
) {
    init {
        require(environmentId.isNotEmpty() && taskId.isNotEmpty() &&
            projectId.isNotEmpty() && writeLayer.isNotEmpty()) {
            "RunOwnership fields must be explicit and non-empty"
        }
    }

    fun toJson(): String =
        JSONObject().put("environmentId", environmentId).put("taskId", taskId)
            .put("projectId", projectId).put("writeLayer", writeLayer).toString()
}

data class SpawnError(val errno: Int, val message: String)

/**
 * How one launch delivers the child's STDIN descriptor. Explicit and
 * platform-owned: the caller code (never a model/env string) selects it, and
 * it only chooses the child's stdin descriptor layout inside the same guest
 * launch — it never selects a host interpreter or any other execution path.
 */
enum class StdinDelivery {
    /** Child stdin is the PTY slave: explicit terminal input. This is the
     * unchanged interactive path (canonical line editing, VEOF/EOT tty
     * semantics belong to THIS mode and only to it). */
    PtyInput,

    /** Child stdin is a one-shot pipe whose write end the session owns.
     * Closing that descriptor delivers a REAL EOF exactly after the supplied
     * bytes; nil/empty stdin means close-before-any-write, never an EOT hack,
     * and stdout/stderr/resize/ISIG semantics still ride the PTY. */
    OneShotPipe,
}

sealed class SpawnOutcome {
    data class Spawned(val session: PtySession) : SpawnOutcome()
    data class Failed(val error: SpawnError) : SpawnOutcome()
}

/**
 * Terminal state of an owned child. [waitErrno] is non-zero when the state
 * came from a waitpid(2) error rather than a real exit/signal (never reported
 * as a benign "still running").
 */
data class ExitResult(
    val exitCode: Int,
    val signaled: Boolean,
    val termSig: Int,
    val waitErrno: Int = 0,
) {
    fun toJson(): String =
        """{"exitCode":$exitCode,"signaled":$signaled,"termSig":$termSig,"waitErrno":$waitErrno}"""
}

/** One owned child process running on a PTY. Handles are per-session; no kill-by-name. */
interface PtySession {
    val pid: Int

    /** Creation identity: pid plus the kernel start-time tick, captured at spawn. */
    val creationIdentity: String

    val executable: String
    val argv: List<String>
    val ownership: RunOwnership

    /**
     * Read up to [capacity] bytes of PTY output (stdout and stderr are merged
     * by the kernel PTY; there is no honest way to split them here).
     * Empty bytes mean timeout, null means EOF/closed; read failures throw.
     * Wait is at most 1000ms so cancellation can acquire the lifecycle lock.
     */
    fun read(capacity: Int, timeoutMs: Long): ByteArray?

    /**
     * Write bytes to the child's PTY master (stdin semantics). Returns the
     * accepted byte count (may be partial on a nonblocking PTY), or -errno on failure.
     */
    fun write(data: ByteArray, offset: Int = 0, length: Int = data.size): Int

    /** The stdin descriptor this session actually owns (default: PTY input). */
    val stdinDelivery: StdinDelivery get() = StdinDelivery.PtyInput

    /**
     * One-shot stdin pipe write ([StdinDelivery.OneShotPipe] sessions only).
     * Nonblocking; returns bytes accepted (may be partial) or -errno:
     * -11 EAGAIN (pipe full — reader has not consumed yet), -32 EPIPE (child
     * closed stdin), -9 EBADF (write end already closed). A PTY-delivery
     * session honestly refuses with -95 (ENOTSUP): its stdin rides [write].
     */
    fun writeStdinPipe(data: ByteArray, offset: Int = 0, length: Int = data.size - offset): Int =
        -95 /* ENOTSUP */

    /**
     * Close the one-shot stdin write end: REAL descriptor EOF for the child,
     * exactly after the bytes already accepted. Idempotent; returns 0 or
     * -errno. No-op success on a PTY-delivery session (it holds no pipe).
     */
    fun closeStdinPipe(): Int = 0

    /** Request terminal size change. Returns false if the master fd is closed. */
    fun resize(rows: Int, cols: Int): Boolean

    /** Send Ctrl-C (byte 0x03; SIGINT delivery depends on the child's termios ISIG). */
    fun sendCtrlC(): Int = write(byteArrayOf(3))

    /** Poll child exit status. null = still running (or not yet reaped); see lastWaitErrno. */
    fun pollExit(): ExitResult?

    /** Wait (bounded) for exit. null on timeout; wait errors are reported in ExitResult.waitErrno. */
    fun awaitExit(timeoutMs: Long): ExitResult?

    /**
     * Cancel this session: release any owned one-shot stdin write end (real
     * EOF, so no descriptor survives a cancelled session), verify the
     * creation identity (PID-reuse guard), SIGKILL the owned process group,
     * reap the child, then close the PTY master. Idempotent. The owned handle
     * is retained until quiescence.
     */
    fun cancel(): ExitResult?

    /** Close the PTY master only (EOF/HUP semantics to the child side). Does not kill or reap. */
    fun closeMaster()

    /** Non-zero if the last waitpid reported an error (e.g. ECHILD); 0 otherwise. */
    fun lastWaitErrno(): Int
}

/** Explicit inputs the caller must supply. Nothing here is invented by the backend. */
data class LaunchSpec(
    val executable: String,
    val argv: List<String>,
    val env: Map<String, String>,
    val workingDir: String?,
    val ownership: RunOwnership,
    val rows: Int = 24,
    val cols: Int = 80,
    /** Explicit, platform-owned stdin descriptor choice (default: unchanged PTY input). */
    val stdinDelivery: StdinDelivery = StdinDelivery.PtyInput,
) {
    init {
        require(executable.isNotEmpty() && '\u0000' !in executable) { "executable invalid" }
        require(workingDir == null || (workingDir.isNotEmpty() && '\u0000' !in workingDir)) { "workingDir invalid" }
        require(argv.isNotEmpty()) { "argv must include argv[0]; pass listOf(executable, ...)" }
        require(argv.all { '\u0000' !in it }) { "argv entries must not contain NUL" }
        require(env.keys.all { it.isNotEmpty() && '=' !in it && '\u0000' !in it }) {
            "env keys must be non-empty, without '=' or NUL"
        }
        require(env.values.all { '\u0000' !in it }) { "env values must not contain NUL" }
        require(rows in 1..1000 && cols in 1..1000) { "rows/cols out of range" }
    }
}

/**
 * Reusable launch backend. Implementations must be fake-free: a reported
 * "spawned" child really exists, a reported exit really came from waitpid()
 * of the owned pid, and a reported exec failure really came from the child's
 * execve(2) errno.
 */
interface LinuxRuntimeBackend {
    val identity: BackendIdentity

    /**
     * Spawn a child on a new PTY. The native wait for the child's execve
     * result is bounded by [timeoutMs]; on timeout the half-spawned child is
     * killed and reaped and the outcome is a failure with errno 110.
     * Cleanup retains ownership until exit; kernel reaping can extend the
     * startup deadline. Invoke this blocking transport off the UI thread.
     */
    fun spawn(spec: LaunchSpec, timeoutMs: Long = 10_000): SpawnOutcome
}
