// SPDX-License-Identifier: MPL-2.0
//
// Thin JNI bridge over PTY/spawn primitives. All heavy lifting lives in
// floe_pty_jni.c (bionic libc only, no third-party code). Strings cross this
// bridge as strict UTF-8 converted from UTF-16 in the native layer, so
// arbitrary non-BMP command text is preserved byte-accurately (no modified
// UTF-8 surprises).

package com.floe.android.linuxruntime

/** Raw process/PTY primitives. Not a public API; use LinuxRuntimeBackend. */
object PosixBridge {
    init {
        System.loadLibrary("floepty")
    }

    /** Open a PTY pair via posix_openpt/grantpt/unlockpt. Returns {masterFd, slaveFd}. */
    external fun openPty(): IntArray

    external fun ptsName(masterFd: Int): String

    /**
     * Fork+exec [executable] with [argv] (argv[0] already present) and envp on
     * the slave side of [slaveFd]; the child makes the slave its controlling
     * terminal and closes every other inherited fd. The wait for the child's
     * execve result is bounded by [timeoutMs]; on timeout the half-spawned
     * child is killed and reaped and -110 is returned. Other returns:
     * pid >= 0 spawned; -errno exec/chdir/setsid failure (e.g. -13 = EACCES);
     * -1 fork-level IOException.
     */
    external fun spawnOnPty(
        masterFd: Int,
        slaveFd: Int,
        executable: String,
        argv: Array<String>,
        envp: Array<String>,
        workingDir: String?,
        timeoutMs: Int,
    ): Int

    /** Set winsize on the PTY master. Returns 0 or -errno. */
    external fun setWinsize(masterFd: Int, rows: Int, cols: Int): Int

    /** waitpid(pid) without hanging: {state, code, extra}; state 0=running,1=exited,2=signaled,3=error(extra=errno). */
    external fun pollWaitPid(pid: Int): IntArray

    /** waitpid(pid, timeoutMs); state 0 on timeout. */
    external fun waitPidTimeout(pid: Int, timeoutMs: Int): IntArray

    /** kill(pid, sig); negative pid signals a process group. Returns 0 or -errno. */
    external fun kill(pid: Int, sig: Int): Int

    /** Real process group id, or -errno (for owned-process lifecycle checks). */
    external fun processGroup(pid: Int): Int

    /** kill(pid, 0) existence probe. Returns 0 alive, -ESRCH dead, other -errno. */
    external fun exists(pid: Int): Int

    /** Empty bytes on timeout, null on EOF; failures throw. */
    external fun readMasterTimeout(masterFd: Int, capacity: Int, timeoutMs: Int): ByteArray?

    /** Write bytes to master; returns bytes accepted or -errno. */
    external fun writeMaster(masterFd: Int, data: ByteArray, offset: Int, length: Int): Int

    /** Close fd. Returns 0 or -errno. */
    external fun closeFd(fd: Int): Int

    /** Host page size from sysconf(_SC_PAGESIZE). */
    external fun hostPageSize(): Int

    /** Kernel start-time of a live pid from /proc/<pid>/stat field 22, or -1. */
    external fun procStartTime(pid: Int): Long
}
