// SPDX-License-Identifier: MPL-2.0
//
// Structured, synthetic, bounded self-tests for the Floe Android Linux
// runtime launch transport. No network, no model calls, no credentials.
// Everything reported here is observed through the host's real code path
// (LinuxRuntimeBackend -> JNI -> fork/exec/waitpid).

package com.floe.linuxruntime.host

import android.content.Context
import com.floe.android.linuxruntime.DefaultLinuxRuntimeBackend
import com.floe.android.linuxruntime.LaunchSpec
import com.floe.android.linuxruntime.LinuxRuntimeBackend
import com.floe.android.linuxruntime.PtySession
import com.floe.android.linuxruntime.PRootLaunchSpec
import com.floe.android.linuxruntime.LinuxBind
import com.floe.android.linuxruntime.RunOwnership
import com.floe.android.linuxruntime.SpawnOutcome
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class SelfTestRunner(
    private val context: Context,
    private var log: (String) -> Unit = {},
) {

    private val backend: LinuxRuntimeBackend = DefaultLinuxRuntimeBackend()
    private val libDir: String = context.applicationInfo.nativeLibraryDir
    private val filesDir: File = context.filesDir
    private val externalFiles: File? = context.getExternalFilesDir(null)

    // Fixed qualification identity; the transport only carries it.
    private val qualOwnership = RunOwnership(
        environmentId = "env.linuxruntime.qual.r1",
        taskId = "task.linuxruntime.selftest",
        projectId = "project.android-g03-r1",
        writeLayer = "qualification-host-private",
    )

    fun runAll(linuxOnly: Boolean = false, logLines: (String) -> Unit): JSONObject {
        log = logLines
        val report = JSONObject()
        report.put("reportVersion", 1)
        report.put("generatedAt", java.util.Date().toString())
        report.put("packageName", context.packageName)
        report.put("backend", JSONObject(backend.identity.toJson()))
        report.put("selection", if (linuxOnly) "linux-only" else "full")

        val tests = JSONArray()
        runTest(tests, "T1-host-identity") { hostIdentity() }
        if (!linuxOnly) {
        runTest(tests, "T2-probe-exec-from-apk-lib") { probeFromLib() }
        runTest(tests, "T3-probe-exec-from-files-dir") { probeFromFiles() }
        runTest(tests, "T4-seccomp-landlock-probe") { seccompLandlock() }
        runTest(tests, "T5-pty-semantics") { ptySemantics() }
        runTest(tests, "T6-cancellation-owns-child") { cancellation() }
        runTest(tests, "T7-bounded-output") { boundedOutput() }
        }
        runTest(tests, "T8-rootfs-guest-exec") { rootfsGuestExec() }
        runTest(tests, "T9-linux-child-cancellation") { linuxChildCancellation() }

        report.put("tests", tests)
        report.put(
            "conclusions",
            JSONObject()
                .put(
                    "execChannel",
                    "Packaged helpers execute from APK native-lib dir; targetSdk>=29 app-data exec is denied " +
                        "for untrusted_app (T2/T3). This does not restrict system executables.",
                )
                .put("sandbox", "PRoot is launch/path virtualisation, not an isolation boundary; same-UID children share all app-private data")
                .put("isolation", "isolatedProcess cannot open app_data_file (AOSP isolated_app_all.te) and is not used by this backend"),
        )
        return report
    }

    private fun runTest(tests: JSONArray, id: String, body: () -> JSONObject) {
        val t0 = System.nanoTime()
        val entry = JSONObject().put("id", id)
        try {
            val detail = body()
            entry.put("status", detail.optString("status", "pass"))
            entry.put("detail", detail)
        } catch (t: Throwable) {
            entry.put("status", "error")
            entry.put(
                "detail",
                JSONObject().put("exception", t.javaClass.name).put("message", t.message ?: "?"),
            )
        }
        entry.put("durationMs", (System.nanoTime() - t0) / 1_000_000)
        tests.put(entry)
        log("[$id] ${entry.getString("status")}")
    }

    // ---------------------------------------------------------------- T1

    private fun hostIdentity(): JSONObject {
        val d = JSONObject(DefaultLinuxRuntimeBackend.hostIdentityJson())
        d.put("seContextReadable", d.optString("seContext").isNotEmpty())
        d.put("libDir", libDir)
        d.put("filesDir", filesDir.absolutePath)
        d.put("externalFilesDir", externalFiles?.absolutePath ?: "<null>")
        d.put("probePath", "$libDir/libfloeprobe.so")
        d.put("probePresent", File(libDir, "libfloeprobe.so").exists())
        d.put("prootPresent", File(libDir, "libproot.so").exists())
        d.put(
            "rootfsTarball",
            externalFiles?.let { File(it, ROOTFS_TARBALL).absolutePath } ?: "<null>",
        )
        return d
    }

    // ---------------------------------------------------------------- T2

    private fun probeFromLib(): JSONObject {
        val exe = "$libDir/libfloeprobe.so"
        val outcome = backend.spawn(
            LaunchSpec(
                executable = exe,
                argv = listOf(exe, "identity"),
                env = baseEnv(),
                workingDir = filesDir.absolutePath,
                ownership = qualOwnership,
            ),
        )
        return when (outcome) {
            is SpawnOutcome.Failed -> JSONObject()
                .put("status", "fail")
                .put("reason", "spawn failed errno=${outcome.error.errno} (${outcome.error.message})")

            is SpawnOutcome.Spawned -> {
                val reader = PtyReader(outcome.session, capBytes = 64 * 1024)
                val exit = outcome.session.awaitExit(8_000)
                val text = reader.stop(2_000)
                val d = JSONObject()
                d.put("pid", outcome.session.pid)
                d.put("creationIdentity", outcome.session.creationIdentity)
                d.put("ownershipCarried", outcome.session.ownership.toJson())
                d.put("exit", exit?.toJson() ?: "<no-exit>")
                val identity = JSONObject(text.trim())
                val correctIdentity = identity.getInt("uid") == android.system.Os.getuid() &&
                    identity.getInt("pid") == outcome.session.pid && identity.getInt("pageSize") == com.floe.android.linuxruntime.PosixBridge.hostPageSize()
                d.put("status", if (exit != null && exit.exitCode == 0 && exit.waitErrno == 0 && correctIdentity) "pass" else "fail")
                d.put("probeJson", identity)
                d.put("rawTail", text.take(2_000))
                d
            }
        }
    }

    // ---------------------------------------------------------------- T3

    private fun probeFromFiles(): JSONObject {
        val src = File(libDir, "libfloeprobe.so")
        val copy = File(filesDir, "probe-copy")
        src.inputStream().use { input -> copy.outputStream().use { input.copyTo(it) } }
        android.system.Os.chmod(copy.absolutePath, 448) // owner rwx; exec denial must not be a missing mode bit
        val outcome = backend.spawn(
            LaunchSpec(
                executable = copy.absolutePath,
                argv = listOf(copy.absolutePath, "identity"),
                env = baseEnv(),
                workingDir = filesDir.absolutePath,
                ownership = qualOwnership,
            ),
        )
        val d = JSONObject()
        d.put("copiedTo", copy.absolutePath)
        val copiedStat = android.system.Os.stat(copy.absolutePath)
        d.put("copiedMode", Integer.toOctalString(copiedStat.st_mode))
        d.put("copiedUid", copiedStat.st_uid)
        require(copiedStat.st_mode and 64 != 0 && copiedStat.st_uid == android.system.Os.getuid())
        when (outcome) {
            is SpawnOutcome.Failed -> {
                d.put("execErrno", outcome.error.errno)
                d.put("execErrnoName", outcome.error.message)
                d.put(
                    "expected",
                    "EACCES(13): SELinux denies untrusted_app exec of app_data_file " +
                        "(AOSP main private/app.te; seapp_contexts minTargetSdkVersion=34)",
                )
                d.put("status", if (outcome.error.errno == 13) "pass" else "fail")
                if (outcome.error.errno != 13) {
                    d.put("reason", "unexpected errno; check device API/sepolicy level")
                }
            }

            is SpawnOutcome.Spawned -> {
                val reader = PtyReader(outcome.session, capBytes = 16 * 1024)
                val exit = outcome.session.awaitExit(4_000)
                val raw = reader.stop(500)
                d.put("status", "fail")
                d.put("reason", "exec from files dir unexpectedly succeeded; platform does not enforce the target>=29 restriction")
                d.put("exit", exit?.toJson() ?: "<no-exit>")
                d.put("raw", raw.take(500))
            }
        }
        copy.delete()
        return d
    }

    // ---------------------------------------------------------------- T4

    private fun seccompLandlock(): JSONObject {
        val exe = "$libDir/libfloeprobe.so"
        val outcome = backend.spawn(
            LaunchSpec(exe, listOf(exe, "seccomp"), baseEnv(), filesDir.absolutePath, qualOwnership),
        )
        if (outcome is SpawnOutcome.Failed) {
            return JSONObject().put("status", "fail")
                .put("reason", "spawn failed errno=${outcome.error.errno}")
        }
        val session = (outcome as SpawnOutcome.Spawned).session
        val reader = PtyReader(session, capBytes = 32 * 1024)
        Thread.sleep(1_500)
        val exit = session.pollExit()
        val text = if (exit == null) {
            session.cancel()
            reader.stop(1_000)
        } else {
            reader.stop(1_000)
        }
        val d = JSONObject()
        d.put("pid", session.pid)
        d.put("raw", text.take(4_000))
        if (exit == null) {
            d.put("status", "fail").put("reason", "probe did not finish; cancelled")
            return d
        }
        d.put("exit", exit.toJson())
        d.put("landlockInvoked", text.contains("\"landlock\":\"invoking\""))
        d.put("landlockAnswered", text.contains("landlockAbi"))
        d.put("sigsysDeath", exit.signaled && exit.termSig == 31)
        // Any honest answer (abi value, errno, or SIGSYS) is a pass.
        d.put("status", "pass")
        return d
    }

    // ---------------------------------------------------------------- T5

    private fun ptySemantics(): JSONObject {
        val exe = "$libDir/libfloeprobe.so"
        val outcome = backend.spawn(
            LaunchSpec(
                exe, listOf(exe, "echo"), baseEnv(), filesDir.absolutePath, qualOwnership,
                rows = 24, cols = 80,
            ),
        )
        if (outcome is SpawnOutcome.Failed) {
            return JSONObject().put("status", "fail")
                .put("reason", "spawn failed errno=${outcome.error.errno}")
        }
        val session = (outcome as SpawnOutcome.Spawned).session
        val reader = PtyReader(session, capBytes = 64 * 1024)
        val d = JSONObject()
        try {
            val rejectedOverflow = session.write(byteArrayOf(1), Int.MAX_VALUE, Int.MAX_VALUE) == -22
            d.put("rejectedWriteOverflow", rejectedOverflow)
            Thread.sleep(400)
            session.write("hello-floe\n".toByteArray())
            Thread.sleep(500)
            val resized = session.resize(rows = 40, cols = 120)
            Thread.sleep(700)
            session.sendCtrlC()
            Thread.sleep(700)
            session.write(byteArrayOf(0x04)) // VEOF -> canonical EOF
            val exit = session.awaitExit(6_000)
            d.put("resized", resized)
            d.put("exit", exit?.toJson() ?: "<no-exit>")
            val text = reader.stop(1_000)
            d.put("sawEcho", text.contains("hello-floe"))
            d.put("sawWinsz", text.contains("PROBE-WINSZ 120 40"))
            d.put("sawSigint", text.contains("PROBE-SIGINT"))
            d.put("sawEof", text.contains("PROBE-EOF"))
            d.put("rawTail", text.take(1_500))
            val pass = d.getBoolean("rejectedWriteOverflow") && resized && exit != null && exit.exitCode == 0 &&
                d.getBoolean("sawEcho") && d.getBoolean("sawWinsz") &&
                d.getBoolean("sawSigint") && d.getBoolean("sawEof")
            d.put("status", if (pass) "pass" else "fail")
        } finally {
            session.cancel()
        }
        return d
    }

    // ---------------------------------------------------------------- T6

    private fun cancellation(): JSONObject {
        val exe = "$libDir/libfloeprobe.so"
        val outcome = backend.spawn(
            LaunchSpec(exe, listOf(exe, "sleep", "60"), baseEnv(), filesDir.absolutePath, qualOwnership),
        )
        if (outcome is SpawnOutcome.Failed) {
            return JSONObject().put("status", "fail")
                .put("reason", "spawn failed errno=${outcome.error.errno}")
        }
        val session = (outcome as SpawnOutcome.Spawned).session
        val pid = session.pid
        Thread.sleep(1_000)
        val stillRunningBefore = session.pollExit() == null && session.lastWaitErrno() == 0
        val cancelResult = session.cancel()
        Thread.sleep(300)
        val existsAfter = com.floe.android.linuxruntime.PosixBridge.exists(pid)
        val procGone = !File("/proc/$pid").exists()
        val d = JSONObject()
        d.put("pid", pid)
        d.put("creationIdentity", session.creationIdentity)
        d.put("stillRunningBefore", stillRunningBefore)
        d.put("cancelResult", cancelResult?.toJson() ?: "<unreaped>")
        d.put("kill0After", existsAfter)
        d.put("kill0AfterESRCH", existsAfter == -3)
        d.put("procGoneAfter", procGone)
        val pass = stillRunningBefore && cancelResult != null && cancelResult.signaled &&
            cancelResult.termSig == 9 && cancelResult.waitErrno == 0 &&
            existsAfter == -3 && procGone
        d.put("status", if (pass) "pass" else "fail")
        return d
    }

    // ---------------------------------------------------------------- T7

    private fun boundedOutput(): JSONObject {
        val total = 262_144
        val exe = "$libDir/libfloeprobe.so"
        val outcome = backend.spawn(
            LaunchSpec(exe, listOf(exe, "flood", total.toString()), baseEnv(), filesDir.absolutePath, qualOwnership),
        )
        if (outcome is SpawnOutcome.Failed) {
            return JSONObject().put("status", "fail")
                .put("reason", "spawn failed errno=${outcome.error.errno}")
        }
        val session = (outcome as SpawnOutcome.Spawned).session
        val reader = PtyReader(session, capBytes = 64 * 1024)
        val exit = session.awaitExit(10_000)
        val kept = reader.stop(1_000)
        val d = JSONObject()
        d.put("requestedBytes", total)
        d.put("observedBytes", reader.totalBytes)
        d.put("keptBytes", kept.length)
        d.put("capBytes", 64 * 1024)
        d.put("exit", exit?.toJson() ?: "<no-exit>")
        val pass = exit != null && exit.exitCode == 0 && reader.totalBytes >= total &&
            kept.length <= 64 * 1024 + 8_192
        d.put("status", if (pass) "pass" else "fail")
        return d
    }

    // ---------------------------------------------------------------- T8

    private fun rootfsGuestExec(): JSONObject {
        val d = JSONObject()
        val proot = File(libDir, "libproot.so")
        val tarball = externalFiles?.let { File(it, ROOTFS_TARBALL) }
        if (tarball == null || !tarball.isFile) {
            d.put("status", "skipped")
            d.put(
                "reason",
                "no rootfs tarball at ${tarball?.absolutePath}; push with: adb push <rootfs.tar.gz> " +
                    "/sdcard/Android/data/${context.packageName}/files/",
            )
            return d
        }
        if (!proot.isFile) {
            d.put("status", "skipped")
            d.put("reason", "libproot.so not packaged in this build (proot cross-build pending)")
            return d
        }
        val rootfs = File(filesDir, "rootfs")
        d.put("tarball", tarball.absolutePath)
        d.put("tarballBytes", tarball.length())
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        tarball.inputStream().use { stream ->
            val chunk = ByteArray(64 * 1024)
            while (true) { val count = stream.read(chunk); if (count < 0) break; digest.update(chunk, 0, count) }
        }
        val fixtureHash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        d.put("fixtureSha256", fixtureHash)
        require(fixtureHash == "9341829d5fe914635e92bcb3f216f29ff31722b0097a10f191b04eae82cd24b9") {
            "Wrong qualification fixture; use prepare-fixture.py with the pinned source"
        }
        try {
            val extraction = TarGz.extract(tarball, rootfs)
            d.put("extraction", extraction.toString())
            d.put("rootfsExtractedTo", rootfs.absolutePath)
        } catch (t: Throwable) {
            return d.put("status", "error")
                .put("stage", "extract")
                .put("message", t.message ?: t.javaClass.name)
        }
        val guestSh = File(rootfs, "bin/sh")
        d.put("guestSh", guestSh.absolutePath)
        val guestStat = android.system.Os.stat(guestSh.absolutePath)
        d.put("guestCanonical", guestSh.canonicalPath)
        d.put("guestMode", Integer.toOctalString(guestStat.st_mode))
        d.put("guestUid", guestStat.st_uid)
        d.put("guestSize", guestStat.st_size)

        // (a) direct exec of the guest binary from app_data_file (no proot).
        val direct = backend.spawn(
            LaunchSpec(
                guestSh.absolutePath, listOf(guestSh.absolutePath, "-c", "id"),
                baseEnv(), rootfs.absolutePath, qualOwnership,
            ),
        )
        when (direct) {
            is SpawnOutcome.Failed -> d.put(
                "directGuestExec",
                JSONObject().put("errno", direct.error.errno).put("errnoName", direct.error.message),
            )

            is SpawnOutcome.Spawned -> {
                val r = PtyReader(direct.session, 32 * 1024)
                val e = direct.session.awaitExit(4_000)
                val raw = r.stop(500)
                d.put(
                    "directGuestExec",
                    JSONObject().put("unexpected", "spawned").put("exit", e?.toJson() ?: "?")
                        .put("raw", raw.take(500)),
                )
            }
        }

        // Kernel exec and loader mmap have different SELinux checks. Measure
        // the actual packaged-loader path; a captured error is not a pass.
        var linuxExecuted = false
        val prootRun = backend.spawn(linuxPlan(rootfs).command(
            listOf("/bin/sh", "-c", "id; uname -a; cat /etc/os-release; printf 'FLOE_LINUX_STDOUT\\n'; printf 'FLOE_LINUX_STDERR\\n' >&2; exit 23"),
        ))
        when (prootRun) {
            is SpawnOutcome.Failed -> d.put(
                "prootLaunch",
                JSONObject().put("spawnErrno", prootRun.error.errno)
                    .put("errnoName", prootRun.error.message),
            )

            is SpawnOutcome.Spawned -> {
                val r = PtyReader(prootRun.session, 64 * 1024)
                val e = prootRun.session.awaitExit(25_000) ?: prootRun.session.cancel()
                val raw = r.stop(1_000)
                linuxExecuted = e != null && !e.signaled && e.exitCode == 23 &&
                    raw.contains("ID=debian") && raw.contains("FLOE_LINUX_STDOUT") &&
                    raw.contains("FLOE_LINUX_STDERR")
                d.put(
                    "prootLaunch",
                    JSONObject()
                        .put("exit", e?.toJson() ?: "<unreaped>")
                        .put("raw", raw.takeLast(16_000)),
                )
            }
        }
        d.put("linuxExecuted", linuxExecuted)
        d.put("status", if (linuxExecuted) "pass" else "fail")
        return d
    }

    // ---------------------------------------------------------------- helpers

    private fun baseEnv(): Map<String, String> = mapOf(
        "PATH" to "/system/bin:/system/xbin",
        "HOME" to filesDir.absolutePath,
        "TERM" to "xterm-256color",
        "TMPDIR" to filesDir.absolutePath,
        "PROOT_LOADER" to File(libDir, "libproot_loader.so").absolutePath,
        "PROOT_TMP_DIR" to File(filesDir, "proot-tmp").apply { mkdirs() }.absolutePath,
    )

    private fun linuxPlan(rootfs: File) = PRootLaunchSpec(
        nativeLibraryDirectory = File(libDir), rootfs = rootfs,
        scratch = File(filesDir, "proot-tmp").apply { mkdirs() },
        guestWorkingDirectory = "/root", guestHome = "/root", guestTemporaryDirectory = "/tmp",
        binds = listOf(LinuxBind(File("/proc"), "/proc"), LinuxBind(File("/dev"), "/dev")),
        ownership = qualOwnership,
    )

    private fun linuxChildCancellation(): JSONObject {
        val proot = File(libDir, "libproot.so")
        val rootfs = File(filesDir, "rootfs")
        val command = "printf 'FLOE_LINUX_CHILD:%s\\n' \"\u0024\u0024\"; exec /usr/bin/setsid /usr/bin/sleep 60"
        val launched = backend.spawn(linuxPlan(rootfs).command(listOf("/bin/sh", "-c", command)))
        if (launched is SpawnOutcome.Failed) return JSONObject()
            .put("status", "fail").put("errno", launched.error.errno)
        val session = (launched as SpawnOutcome.Spawned).session
        var output = ""
        val deadline = android.os.SystemClock.elapsedRealtime() + 5000
        while (android.os.SystemClock.elapsedRealtime() < deadline && !output.contains("FLOE_LINUX_CHILD:")) {
            val data = session.read(4096, 250) ?: break
            output = (output + String(data, Charsets.UTF_8)).takeLast(32000)
        }
        val childPid = Regex("FLOE_LINUX_CHILD:(\\d+)").find(output)?.groupValues?.get(1)?.toInt()
        val childBirth = childPid?.let { com.floe.android.linuxruntime.PosixBridge.procStartTime(it) }
        // The Linux process deliberately leaves the tracer's process group.
        // EXITKILL must terminate it even when group SIGKILL cannot reach it.
        val detachedDeadline = android.os.SystemClock.elapsedRealtime() + 2000
        var childGroup = -1
        while (childPid != null && android.os.SystemClock.elapsedRealtime() < detachedDeadline) {
            childGroup = com.floe.android.linuxruntime.PosixBridge.processGroup(childPid)
            if (childGroup == childPid) break
            Thread.sleep(15)
        }
        val terminal = session.cancel()
        val goneDeadline = android.os.SystemClock.elapsedRealtime() + 2000
        while (childPid != null && com.floe.android.linuxruntime.PosixBridge.exists(childPid) == 0 &&
            android.os.SystemClock.elapsedRealtime() < goneDeadline) Thread.sleep(25)
        val childGone = childPid != null && com.floe.android.linuxruntime.PosixBridge.exists(childPid) == -3
        val pass = childPid != null && childGroup == childPid && childBirth != null && childBirth >= 0 && childGone &&
            terminal != null && terminal.waitErrno == 0 && terminal.signaled && terminal.termSig == 9
        return JSONObject().put("status", if (pass) "pass" else "fail")
            .put("pid", session.pid).put("creationIdentity", session.creationIdentity)
            .put("childPid", childPid).put("childStartTicks", childBirth).put("childProcessGroup", childGroup)
            .put("childGone", childGone).put("exit", terminal?.toJson() ?: "unreaped")
            .put("raw", output)
    }

    /**
     * Bounded PTY reader over the public session API: keeps only the last
     * [capBytes] of output, counts everything observed.
     */
    private class PtyReader(private val session: PtySession, private val capBytes: Int) {
        @Volatile var totalBytes: Long = 0
            private set

        private val chunks = java.util.concurrent.ArrayBlockingQueue<ByteArray>(256)
        private val thread = Thread {
            try {
                while (true) {
                    val chunk = session.read(16 * 1024, 400) ?: break
                    if (chunk.isEmpty()) continue
                    totalBytes += chunk.size
                    chunks.put(chunk)
                    while (chunks.size > 64) chunks.poll()
                }
            } catch (_: Throwable) {
            }
        }.apply { isDaemon = true }

        init { thread.start() }

        /** Returns the bounded tail (at most [capBytes] bytes) as UTF-8 text. */
        fun stop(joinMs: Long): String {
            thread.join(joinMs)
            session.closeMaster()
            thread.join(1_000)
            val all = mutableListOf<ByteArray>()
            chunks.drainTo(all)
            var out = ByteArray(0)
            for (c in all) {
                out = if (out.size + c.size <= capBytes) {
                    out + c
                } else {
                    (out + c).copyOfRange(out.size + c.size - capBytes, out.size + c.size)
                }
            }
            return String(out, Charsets.UTF_8)
        }
    }

    companion object {
        const val ROOTFS_TARBALL = "debian-rootfs.tar.gz"
    }
}
