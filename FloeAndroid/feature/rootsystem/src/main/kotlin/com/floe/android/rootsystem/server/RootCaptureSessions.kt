// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.content.Context
import android.os.Process as AndroidProcess
import android.system.Os
import android.system.OsConstants
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.util.LinkedHashMap
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
 * Lifetime is enforced inside the helper, not only by this Java process:
 * `RootCaptureSessions` sends one validated bound record over the child's
 * stdin pipe. The pinned helper contains [RootCaptureGuardPolicy]'s native
 * counterpart, which watches that pipe (the parent holds the write end, so a
 * daemon SIGKILL is an exact EOF), a monotonic deadline and the output size,
 * and guarantees a bounded exit. A daemon SIGKILL therefore cannot leave an
 * unguarded tcpdump growing forever.
 *
 * Before a start is acknowledged, a bounded root-owned journal records the
 * capture id, owning claim, daemon generation, exact helper pid/start-time/
 * executable/output identity and bounds. If this server dies, the guard stops
 * the helper; a replacement server proves the recorded process is dead from
 * `/proc` (never from a timer) and exposes a `daemonLost` tombstone so the
 * App's existing drain ledger settles as a data-plane failure instead of
 * retrying `capture_unknown` forever. File ownership still follows the
 * process: no read/finish/delete occurs while the exact helper is alive, and a
 * failed stop keeps the same session available for a later retry. Bytes are
 * deleted only after the process exited and the requested read offset reached
 * the final file length.
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

    /** Owner identity propagated by Main's binder patch; nullable until then. */
    data class OwnerIdentity(
        val taskId: String,
        val runId: String,
        val epoch: Long,
    ) {
        fun valid(): Boolean =
            taskId.isNotBlank() && taskId.length <= 128 &&
                runId.isNotBlank() && runId.length <= 128 && epoch > 0 &&
                taskId.none { it.code < 0x20 || it.code == 0x7f } &&
                runId.none { it.code < 0x20 || it.code == 0x7f }
    }

    private data class LeaseTombstone(
        val captureId: String,
        val endedAtMillis: Long,
        val endReason: String,
    )

    private data class HelperIdentity(
        val pid: Long,
        val startTicks: Long,
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
        val journalFile: File,
        val guard: GuardChannel,
        var offset: Long = 0,
        @Volatile var endReason: String? = null,
        @Volatile var lastClientActivityMillis: Long = System.currentTimeMillis(),
        var cancelRequested: Boolean = false,
        var watchdog: Thread? = null,
        var drainer: Thread? = null,
        var reaper: Thread? = null,
    )

    private class Recovered(
        val journal: CaptureJournal,
        val journalFile: File,
        var state: RootCaptureGuardPolicy.ProcessIdentity,
        var reason: String?,
        var lastCheckedMillis: Long,
    )

    private val lock = Any()
    // The helper runs in a root/SELinux domain, not the App sandbox. Its
    // output lives under our root-owned 0700 tree with validated no-symlink
    // ancestry, never in a shell-writable tmp path or App-owned cache. A
    // failure is reported per start instead of falling back to an unsafe path.
    private val directory: File? = runCatching {
        RootCaptureHelper.prepareWorkDirectory()
    }.getOrNull()
    private val stateDirectory: File? = runCatching {
        RootCaptureHelper.prepareStateDirectory()
    }.getOrNull()
    private val bootId: String = readBootId()
    @Volatile
    private var session: Session? = null
    @Volatile
    private var closed = false
    // A lease-ended capture can still be named by the App's existing client
    // (it may have been paused, not dead). Keep a bounded tombstone so a late
    // read/stop receives done=true with an honest reason instead of retrying
    // capture_unknown forever. No bytes or live owner are retained here.
    private var leaseTombstone: LeaseTombstone? = null
    // A previous root-server generation may have been SIGKILLed while a
    // capture was running. Its bounded journal survives; entries are settled
    // only after the recorded helper process is proven dead via /proc.
    private val recovered = LinkedHashMap<String, Recovered>()

    init {
        // Orderly root-server exit (typed stopServer or System.exit) must not
        // leave the helper process orphaned. SIGKILL cannot be handled from
        // inside the dying process; the native guard's stdin EOF and the
        // independent deadline/size bounds cover that case, and the journal
        // lets the replacement server prove the outcome.
        runCatching {
            Runtime.getRuntime().addShutdownHook(
                Thread({ runCatching { close() } }, "floe-root-capture-shutdown"),
            )
        }
        runCatching { recoverJournalsLocked() }
    }

    fun start(
        requestId: String,
        helperId: String,
        interfaceName: String,
        snaplen: Int,
        maxBytes: Long,
        maxMillis: Long,
        owner: OwnerIdentity? = null,
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
        if (maxBytes !in MIN_BYTES..MAX_BYTES) throw OpException("max_bytes")
        if (maxMillis !in 1_000L..MAX_MILLIS) throw OpException("max_millis")
        if (owner != null && !owner.valid()) throw OpException("capture_owner")
        val state = stateDirectory ?: throw OpException("capture_state")
        pruneRecoveredLocked(System.currentTimeMillis())
        val helper = try {
            RootCaptureHelper.resolveForServer(context)
        } catch (failure: RootCaptureHelper.HelperException) {
            throw OpException(failure.code)
        } catch (_: Throwable) {
            throw OpException("helper_unavailable")
        }
        val working = directory ?: throw OpException("helper_path_unsafe")
        val captureId = UUID.randomUUID().toString()
        val file = createCaptureFile(working, captureId)
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
        val identity = findHelperProcess(helper.path.absolutePath, file.absolutePath)
        if (identity == null) {
            abortStart(process, file, null, null)
            throw OpException("capture_journal")
        }
        val now = System.currentTimeMillis()
        val journal = CaptureJournal(
            captureId = captureId,
            requestId = requestId,
            owner = owner,
            daemonPid = AndroidProcess.myPid().toLong(),
            daemonStartTicks = readStartTimeTicks(AndroidProcess.myPid().toLong()) ?: 0L,
            bootId = bootId,
            helperPid = identity.pid,
            helperStartTicks = identity.startTicks,
            helperPath = helper.path.absolutePath,
            helperSha256 = helper.sha256,
            outputPath = file.absolutePath,
            startedAtMillis = now,
            deadlineMillis = now + maxMillis,
            maxMillis = maxMillis,
            maxBytes = maxBytes,
            guardSchema = RootCaptureHelper.GUARD_SCHEMA,
            guardVersion = RootCaptureHelper.GUARD_VERSION,
        )
        if (RootCaptureGuardPolicy.encodeJournal(journal) == null) {
            abortStart(process, file, null, null)
            throw OpException("capture_journal")
        }
        val journalFile = File(state, journalFileName(captureId))
        if (!writeJournal(journalFile, journal)) {
            abortStart(process, file, journalFile, null)
            throw OpException("capture_journal")
        }
        val guard = GuardChannel(process, file)
        if (!guard.send(maxMillis, maxBytes, file.absolutePath) ||
            !guard.awaitReady(identity.pid, maxMillis, maxBytes, GUARD_READY_TIMEOUT_MILLIS)
        ) {
            abortStart(process, file, journalFile, guard)
            throw OpException("helper_guard")
        }
        val value = Session(
            id = captureId,
            requestId = requestId,
            process = process,
            file = file,
            maxBytes = maxBytes,
            deadlineMillis = now + maxMillis,
            helperPath = helper.path.absolutePath,
            helperSha256 = helper.sha256,
            journalFile = journalFile,
            guard = guard,
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

    fun read(
        captureId: String,
        maxBytes: Int,
        owner: OwnerIdentity? = null,
    ): Chunk = synchronized(lock) { readLocked(captureId, maxBytes, owner) }

    private fun readLocked(captureId: String, maxBytes: Int, owner: OwnerIdentity?): Chunk {
        val current = session?.takeIf { it.id == captureId }
        if (current != null) {
            current.lastClientActivityMillis = System.currentTimeMillis()
            val limit = maxBytes.coerceIn(1, MAX_CHUNK)
            val file = current.file
            val length = runCatching { file.length() }.getOrDefault(0L)
            if (length <= current.offset) {
                val done = !current.process.isAlive && current.offset >= length
                if (done) {
                    resolveEndReason(current)
                    finishSession(current)
                }
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
            if (done) {
                resolveEndReason(current)
                finishSession(current)
            }
            return Chunk(bytes.copyOf(read), done, current.offset, current.endReason)
        }
        tombstoneChunkLocked(captureId)?.let { return it }
        recoveredChunkLocked(captureId, owner, System.currentTimeMillis())?.let { return it }
        throw OpException("capture_unknown")
    }

    fun stop(
        captureId: String,
        owner: OwnerIdentity? = null,
    ): Chunk = synchronized(lock) { stopLocked(captureId, owner) }

    private fun stopLocked(captureId: String, owner: OwnerIdentity?): Chunk {
        val current = session?.takeIf { it.id == captureId }
        if (current != null) {
            current.lastClientActivityMillis = System.currentTimeMillis()
            val nativeReason = current.guard.stopReason()
            when {
                nativeReason != null -> current.endReason = nativeReason
                current.endReason == null -> current.endReason = "userStop"
            }
            val exited = destroyAndAwait(current)
            if (!exited) {
                // The process still owns the file. Do not delete, rename,
                // finish or claim a clean stop; the same session is retried by
                // a later stop/read call.
                current.endReason = "stopTimeout"
                return Chunk(ByteArray(0), false, current.offset, current.endReason)
            }
            current.guard.close()
            joinAuxiliary(current)
            resolveEndReason(current)
            val length = runCatching { current.file.length() }.getOrDefault(0L)
            val done = current.offset >= length
            if (done) finishSession(current)
            return Chunk(ByteArray(0), done, current.offset, current.endReason)
        }
        tombstoneChunkLocked(captureId)?.let { return it }
        recoveredChunkLocked(captureId, owner, System.currentTimeMillis())?.let { return it }
        throw OpException("capture_unknown")
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
            current.guard.close()
            joinAuxiliary(current)
            // No reader will ask for this capture again: the grant is being
            // revoked. The process is proven dead before its file is removed.
            current.file.delete()
            File(current.file.path + GUARD_SIDECAR_SUFFIX).delete()
            current.journalFile.delete()
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
                current.guard.close()
                joinAuxiliary(current)
                current.file.delete()
                File(current.file.path + GUARD_SIDECAR_SUFFIX).delete()
                current.journalFile.delete()
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
        current.guard.close()
        current.file.delete()
        File(current.file.path + GUARD_SIDECAR_SUFFIX).delete()
        current.journalFile.delete()
        if (session === current) session = null
    }

    private fun reapCancelled(current: Session) {
        try {
            while (current.process.isAlive) {
                runCatching { current.process.destroyForcibly() }
                runCatching { current.process.waitFor(250, java.util.concurrent.TimeUnit.MILLISECONDS) }
            }
            if (!current.process.isAlive) {
                current.guard.close()
                joinAuxiliary(current)
                current.file.delete()
                File(current.file.path + GUARD_SIDECAR_SUFFIX).delete()
                current.journalFile.delete()
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
            while (!closed && session === current) {
                val now = System.currentTimeMillis()
                if (current.process.isAlive) {
                    val size = runCatching { current.file.length() }.getOrDefault(0L)
                    if (size >= current.maxBytes) {
                        current.endReason = current.endReason ?: "sizeLimit"
                        stopProcess(current)
                        current.endReason = current.endReason ?: current.guard.stopReason()
                    } else if (now >= current.deadlineMillis) {
                        current.endReason = current.endReason ?: "durationLimit"
                        stopProcess(current)
                        current.endReason = current.endReason ?: current.guard.stopReason()
                    }
                } else {
                    // The native guard (or an ordinary tcpdump exit) already
                    // ended the process. Keep the session available for the
                    // owner's tail read/stop, but retire it under the same
                    // client lease if the App never comes back.
                    resolveEndReason(current)
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
                        return
                    }
                }
                Thread.sleep(250L)
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun resolveEndReason(current: Session): String? {
        current.endReason?.let { return it }
        val native = current.guard.stopReason()
        if (native != null) {
            current.endReason = native
            return native
        }
        if (!current.process.isAlive) {
            current.endReason = "helperExit"
        }
        return current.endReason
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
        current.guard.close()
        current.file.delete()
        File(current.file.path + GUARD_SIDECAR_SUFFIX).delete()
        current.journalFile.delete()
        synchronized(lock) {
            if (session === current) session = null
            leaseTombstone = LeaseTombstone(
                captureId = current.id,
                endedAtMillis = System.currentTimeMillis(),
                endReason = "clientLease",
            )
        }
    }

    // ------------------------------------------------------- crash recovery

    private fun recoverJournalsLocked() {
        val state = stateDirectory ?: return
        val now = System.currentTimeMillis()
        val entries = state.listFiles()
            ?.filter { it.isFile && JOURNAL_NAME.matches(it.name) }
            ?.take(MAX_JOURNALS)
            .orEmpty()
        for (file in entries) {
            val text = readBounded(file, MAX_JOURNAL_BYTES) ?: continue
            val journal = RootCaptureGuardPolicy.parseJournal(text) ?: continue
            if (file.name != journalFileName(journal.captureId)) continue
            val facts = processFacts(journal.helperPid)
            val identity = RootCaptureGuardPolicy.identity(journal, facts, bootId)
            recovered[journal.captureId] = Recovered(
                journal = journal,
                journalFile = file,
                state = identity,
                // A replacement server cannot prove which tail bytes the dead
                // App consumed. Even if the guard recorded duration/size as
                // the helper's own stop reason, the App outcome is daemon
                // loss and the capture is published as a partial failure.
                reason = if (identity == RootCaptureGuardPolicy.ProcessIdentity.DEAD) {
                    "daemonLost"
                } else {
                    null
                },
                lastCheckedMillis = now,
            )
        }
    }

    private fun pruneRecoveredLocked(now: Long) {
        val iterator = recovered.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            val recoveredValue = entry.value
            val age = now - recoveredValue.journal.startedAtMillis
            if (age < RECOVERED_RETENTION_MILLIS) continue
            val facts = processFacts(recoveredValue.journal.helperPid)
            val identity = RootCaptureGuardPolicy.identity(
                recoveredValue.journal,
                facts,
                bootId,
            )
            if (identity == RootCaptureGuardPolicy.ProcessIdentity.DEAD) {
                runCatching { recoveredValue.journalFile.delete() }
                iterator.remove()
            } else {
                // An exact live helper may still be draining in the kernel;
                // never delete the journal that proves it. Its own deadline
                // and RLIMIT bound remain authoritative.
                recoveredValue.state = identity
            }
        }
    }

    /**
     * A replacement server answers the original capture id only after the
     * journaled process is proven dead from /proc. While it is alive (for
     * example a kernel-blocked exit) the answer is done=false; it is never
     * relabelled complete from elapsed time.
     */
    private fun recoveredChunkLocked(
        captureId: String,
        owner: OwnerIdentity?,
        now: Long,
    ): Chunk? {
        val recoveredValue = recovered[captureId] ?: return null
        if (owner != null && recoveredValue.journal.owner != null &&
            owner != recoveredValue.journal.owner
        ) {
            throw OpException("capture_owner")
        }
        if (now - recoveredValue.lastCheckedMillis >= RECOVERED_RECHECK_MILLIS ||
            recoveredValue.state != RootCaptureGuardPolicy.ProcessIdentity.DEAD
        ) {
            val facts = processFacts(recoveredValue.journal.helperPid)
            val identity = RootCaptureGuardPolicy.identity(
                recoveredValue.journal,
                facts,
                bootId,
            )
            recoveredValue.state = identity
            recoveredValue.lastCheckedMillis = now
            if (identity == RootCaptureGuardPolicy.ProcessIdentity.DEAD) {
                recoveredValue.reason = "daemonLost"
            }
        }
        return if (recoveredValue.state == RootCaptureGuardPolicy.ProcessIdentity.DEAD) {
            Chunk(
                bytes = ByteArray(0),
                done = true,
                bytesRead = 0L,
                endReason = recoveredValue.reason ?: "daemonLost",
            )
        } else {
            Chunk(
                bytes = ByteArray(0),
                done = false,
                bytesRead = 0L,
                endReason = "daemonLost",
            )
        }
    }

    private fun processFacts(pid: Long): RootCaptureGuardPolicy.ProcessFacts {
        val base = File("/proc/$pid")
        if (!base.exists()) return RootCaptureGuardPolicy.ProcessFacts(present = false)
        val stat = readProcText(pid, "stat")
        val startTicks = stat?.let(RootCaptureGuardPolicy::parseStartTimeTicks)
        val exe = runCatching { Os.readlink("/proc/$pid/exe") }.getOrNull()
        val cmdline = readProcText(pid, "cmdline")
            ?.split('\u0000')
            ?.filter { it.isNotEmpty() }
            .orEmpty()
        return RootCaptureGuardPolicy.ProcessFacts(
            present = true,
            startTicks = startTicks,
            exe = exe,
            cmdline = cmdline,
        )
    }

    private fun findHelperProcess(helperPath: String, outputPath: String): HelperIdentity? {
        val myPid = AndroidProcess.myPid().toLong()
        var found: HelperIdentity? = null
        val entries = File("/proc").listFiles()?.take(MAX_PROC_ENTRIES) ?: return null
        for (entry in entries) {
            val pid = entry.name.toLongOrNull() ?: continue
            if (pid <= 0L || pid == myPid) continue
            val stat = readProcText(pid, "stat") ?: continue
            if (RootCaptureGuardPolicy.parentPid(stat) != myPid) continue
            val cmdline = readProcText(pid, "cmdline")
                ?.split('\u0000')
                ?.filter { it.isNotEmpty() }
                ?: continue
            if (!RootCaptureGuardPolicy.commandMatches(cmdline, helperPath, outputPath)) continue
            val startTicks = RootCaptureGuardPolicy.parseStartTimeTicks(stat) ?: return null
            if (found != null) return null
            found = HelperIdentity(pid, startTicks)
        }
        return found
    }

    // ------------------------------------------------------------- journal

    private fun writeJournal(file: File, journal: CaptureJournal): Boolean {
        val text = RootCaptureGuardPolicy.encodeJournal(journal) ?: return false
        val fd = try {
            Os.open(
                file.absolutePath,
                OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or
                    OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC,
                0x180, // 0600
            )
        } catch (_: Throwable) {
            return false
        }
        return try {
            FileOutputStream(fd).use { output ->
                output.write(text.toByteArray(Charsets.UTF_8))
                output.flush()
                output.fd.sync()
            }
            // Durability for the directory entry matters for a daemon crash;
            // the content fsync alone can leave a missing name after power
            // loss. SIGKILL does not lose either, but this keeps the journal
            // contract honest for the stronger case.
            file.parentFile?.let { parent ->
                runCatching {
                    val directoryFd = Os.open(
                        parent.absolutePath,
                        OsConstants.O_RDONLY or OsConstants.O_CLOEXEC,
                        0,
                    )
                    try {
                        Os.fsync(directoryFd)
                    } finally {
                        Os.close(directoryFd)
                    }
                }
            }
            true
        } catch (_: Throwable) {
            runCatching { file.delete() }
            false
        }
    }

    private fun journalFileName(captureId: String): String = "capture-$captureId.journal"

    private fun abortStart(
        process: Process,
        file: File,
        journalFile: File?,
        guard: GuardChannel?,
    ) {
        runCatching { guard?.close() }
        runCatching { process.outputStream.close() }
        runCatching { process.destroy() }
        runCatching { process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS) }
        if (process.isAlive) runCatching { process.destroyForcibly() }
        runCatching { process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS) }
        runCatching { file.delete() }
        runCatching { File(file.path + GUARD_SIDECAR_SUFFIX).delete() }
        runCatching { journalFile?.delete() }
    }

    private fun createCaptureFile(directory: File, captureId: String): File {
        val file = File(directory, "capture-$captureId.pcap")
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

    private fun readBounded(file: File, maxBytes: Int): String? = runCatching {
        if (!file.isFile || file.length() > maxBytes.toLong()) return null
        file.readText(Charsets.UTF_8)
    }.getOrNull()

    private fun readStartTimeTicks(pid: Long): Long? =
        readProcText(pid, "stat")?.let(RootCaptureGuardPolicy::parseStartTimeTicks)

    private fun readProcText(pid: Long, name: String): String? = runCatching {
        val file = File("/proc/$pid/$name")
        if (!file.isFile || file.length() > PROC_READ_LIMIT) return null
        file.readText(Charsets.UTF_8)
    }.getOrNull()

    private fun guardStopReason(file: File): String? =
        readBounded(File(file.path + GUARD_SIDECAR_SUFFIX), MAX_SIDECAR_BYTES)
            ?.let(RootCaptureGuardPolicy::stopReason)

    private fun readBootId(): String = runCatching {
        File("/proc/sys/kernel/random/boot_id").readText(Charsets.UTF_8).trim()
    }.getOrNull().orEmpty().takeIf { it.matches(Regex("^[0-9a-fA-F-]{1,64}$")) }.orEmpty()

    private class GuardChannel(
        private val process: Process,
        private val output: File,
    ) {
        private val stream: OutputStream = process.outputStream

        fun send(maxMillis: Long, maxBytes: Long, outputPath: String): Boolean {
            val line = RootCaptureGuardPolicy.guardConfigLine(
                maxMillis,
                maxBytes,
                outputPath,
            ) ?: return false
            return runCatching {
                stream.write(line.toByteArray(Charsets.UTF_8))
                stream.flush()
            }.isSuccess
        }

        fun awaitReady(
            pid: Long,
            maxMillis: Long,
            maxBytes: Long,
            timeoutMillis: Long,
        ): Boolean {
            val sidecar = sidecar()
            val deadline = System.currentTimeMillis() + timeoutMillis
            while (System.currentTimeMillis() < deadline) {
                if (!process.isAlive) return false
                val text = readText(sidecar)
                if (text != null &&
                    RootCaptureGuardPolicy.readyRecord(text, pid, maxMillis, maxBytes)
                ) {
                    return true
                }
                Thread.sleep(10L)
            }
            return false
        }

        fun stopReason(): String? =
            readText(sidecar())?.let(RootCaptureGuardPolicy::stopReason)

        fun close() {
            runCatching { stream.close() }
        }

        private fun sidecar(): File = File(output.path + GUARD_SIDECAR_SUFFIX)

        private fun readText(file: File): String? = runCatching {
            if (!file.isFile || file.length() > MAX_SIDECAR_BYTES.toLong()) return null
            file.readText(Charsets.UTF_8)
        }.getOrNull()
    }

    private companion object {
        const val HELPER_ID = "tcpdump-v1"
        const val MAX_BYTES = 128L * 1024L * 1024L
        const val MIN_BYTES = 4L * 1024L
        const val MAX_MILLIS = 5L * 60L * 1000L
        const val MAX_CHUNK = 256 * 1024
        const val GUARD_SIDECAR_SUFFIX = ".guard"
        const val GUARD_READY_TIMEOUT_MILLIS = 1_500L
        const val MAX_SIDECAR_BYTES = 8 * 1024
        const val MAX_JOURNAL_BYTES = 8 * 1024
        const val MAX_JOURNALS = 64
        const val MAX_PROC_ENTRIES = 4_096
        const val PROC_READ_LIMIT = 64L * 1024L
        const val RECOVERED_RETENTION_MILLIS = 24L * 60L * 60L * 1000L
        const val RECOVERED_RECHECK_MILLIS = 250L
        /** No client read/stop for this long => the App owner is gone. */
        const val CLIENT_LEASE_MILLIS = 60_000L
        const val LEASE_TOMBSTONE_MILLIS = 10L * 60L * 1000L
        val INTERFACE = Regex("^[A-Za-z0-9_.:-]{1,32}$")
        val JOURNAL_NAME = Regex("^capture-[0-9a-fA-F-]{36}\\.journal$")
    }
}

/**
 * Durable capture-identity record written before a start is acknowledged.
 *
 * Values are strictly validated on both write and parse; a malformed or
 * truncated journal is never treated as proof of anything.
 */
internal data class CaptureJournal(
    val captureId: String,
    val requestId: String,
    val owner: RootCaptureSessions.OwnerIdentity?,
    val daemonPid: Long,
    val daemonStartTicks: Long,
    val bootId: String,
    val helperPid: Long,
    val helperStartTicks: Long,
    val helperPath: String,
    val helperSha256: String,
    val outputPath: String,
    val startedAtMillis: Long,
    val deadlineMillis: Long,
    val maxMillis: Long,
    val maxBytes: Long,
    val guardSchema: String,
    val guardVersion: Int,
)

/**
 * Pure policy shared by production and host/JVM tests. No Android calls here.
 */
internal object RootCaptureGuardPolicy {
    const val JOURNAL_SCHEMA = "floe.capture-journal.v1"
    const val CONFIG_SCHEMA = "floe-guard-v1"
    const val GUARD_SCHEMA = "floe.capture-guard.v1"
    const val GUARD_VERSION = 1
    const val MAX_GUARD_MILLIS = 600_000L
    const val MAX_GUARD_BYTES = 256L * 1024L * 1024L
    const val MIN_GUARD_BYTES = 4L * 1024L
    const val MAX_JOURNAL_CHARS = 8 * 1024
    const val MAX_PATH = 4_096
    const val MAX_HELPER_BYTES = 128L * 1024L * 1024L

    private val HEX64 = Regex("^[0-9a-f]{64}$")
    private val UUID_TEXT = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    private val BOOT_ID = Regex("^[0-9a-fA-F-]{0,64}$")
    private val STOP_REASONS = setOf(
        "durationLimit",
        "sizeLimit",
        "daemonLost",
        "outputError",
    )
    private val JOURNAL_KEYS = setOf(
        "schema", "captureId", "requestId", "ownerTaskId", "ownerRunId", "ownerEpoch",
        "daemonPid", "daemonStartTicks", "bootId", "helperPid", "helperStartTicks",
        "helperPath", "helperSha256", "outputPath", "startedAtMillis", "deadlineMillis",
        "maxMillis", "maxBytes", "guardSchema", "guardVersion",
    )

    enum class ProcessIdentity { ALIVE, DEAD, UNPROVEN, MISMATCH }

    data class ProcessFacts(
        val present: Boolean,
        val startTicks: Long? = null,
        val exe: String? = null,
        val cmdline: List<String> = emptyList(),
    )

    /** One config record for the native guard; null means fail closed. */
    fun guardConfigLine(maxMillis: Long, maxBytes: Long, outputPath: String): String? {
        if (maxMillis !in 1L..MAX_GUARD_MILLIS) return null
        if (maxBytes !in MIN_GUARD_BYTES..MAX_GUARD_BYTES) return null
        if (!validPath(outputPath)) return null
        val line = "$CONFIG_SCHEMA $maxMillis $maxBytes $outputPath\n"
        return line.takeIf { it.length <= MAX_PATH }
    }

    /**
     * A ready record must name this exact helper process, schema and the
     * exact validated bounds the server supplied; an echo of different bytes
     * means the guard did not consume the intended configuration.
     */
    fun readyRecord(text: String, pid: Long, maxMillis: Long, maxBytes: Long): Boolean {
        for (line in text.lineSequence()) {
            if (!line.startsWith("ready ")) continue
            val fields = fields(line.removePrefix("ready "))
            if (fields["schema"] != GUARD_SCHEMA) continue
            if (fields["version"] != GUARD_VERSION.toString()) continue
            if (fields["pid"] != pid.toString()) continue
            if (fields["max_millis"] != maxMillis.toString()) continue
            if (fields["max_bytes"] != maxBytes.toString()) continue
            return true
        }
        return false
    }

    /** Last structured stop reason, or null when the guard wrote none. */
    fun stopReason(text: String): String? {
        var reason: String? = null
        for (line in text.lineSequence()) {
            val trimmed = line.trim()
            if (!trimmed.startsWith("stop ") && !trimmed.startsWith("hard_stop ")) continue
            val value = fields(
                if (trimmed.startsWith("stop ")) trimmed.removePrefix("stop ")
                else trimmed.removePrefix("hard_stop "),
            )["reason"] ?: continue
            if (value in STOP_REASONS) reason = value
        }
        return reason
    }

    /** stat field 22 (starttime) with comm parentheses handled. */
    fun parseStartTimeTicks(stat: String): Long? = statFields(stat)?.getOrNull(19)?.toLongOrNull()
        ?.takeIf { it > 0L }

    /** stat field 4 (ppid). */
    fun parentPid(stat: String): Long? = statFields(stat)?.getOrNull(1)?.toLongOrNull()

    fun commandMatches(args: List<String>, helperPath: String, outputPath: String): Boolean {
        if (args.size !in 4..16) return false
        if (args[0] != helperPath) return false
        val index = args.indexOf("-w")
        if (index <= 0 || index + 1 >= args.size) return false
        if (args[index + 1] != outputPath) return false
        return args.last() == "-U" && args.contains("-i") && args.contains("-s")
    }

    fun exeMatches(exe: String?, helperPath: String): Boolean =
        exe == helperPath || exe == "$helperPath (deleted)"

    fun identity(journal: CaptureJournal, facts: ProcessFacts, bootId: String): ProcessIdentity {
        if (journal.bootId.isNotEmpty() && bootId.isNotEmpty() && journal.bootId != bootId) {
            return ProcessIdentity.DEAD
        }
        if (!facts.present) return ProcessIdentity.DEAD
        val startTicks = facts.startTicks ?: return ProcessIdentity.UNPROVEN
        if (startTicks != journal.helperStartTicks) return ProcessIdentity.DEAD
        if (!exeMatches(facts.exe, journal.helperPath)) return ProcessIdentity.MISMATCH
        if (!commandMatches(facts.cmdline, journal.helperPath, journal.outputPath)) {
            return ProcessIdentity.MISMATCH
        }
        return ProcessIdentity.ALIVE
    }

    fun encodeJournal(journal: CaptureJournal): String? {
        if (!validJournal(journal)) return null
        val builder = StringBuilder()
        fun put(key: String, value: String) {
            builder.append(key).append('=').append(value).append('\n')
        }
        put("schema", JOURNAL_SCHEMA)
        put("captureId", journal.captureId)
        put("requestId", journal.requestId)
        journal.owner?.let {
            put("ownerTaskId", it.taskId)
            put("ownerRunId", it.runId)
            put("ownerEpoch", it.epoch.toString())
        }
        put("daemonPid", journal.daemonPid.toString())
        put("daemonStartTicks", journal.daemonStartTicks.toString())
        put("bootId", journal.bootId)
        put("helperPid", journal.helperPid.toString())
        put("helperStartTicks", journal.helperStartTicks.toString())
        put("helperPath", journal.helperPath)
        put("helperSha256", journal.helperSha256)
        put("outputPath", journal.outputPath)
        put("startedAtMillis", journal.startedAtMillis.toString())
        put("deadlineMillis", journal.deadlineMillis.toString())
        put("maxMillis", journal.maxMillis.toString())
        put("maxBytes", journal.maxBytes.toString())
        put("guardSchema", journal.guardSchema)
        put("guardVersion", journal.guardVersion.toString())
        val text = builder.toString()
        return text.takeIf { it.length <= MAX_JOURNAL_CHARS }
    }

    fun parseJournal(text: String): CaptureJournal? {
        if (text.isBlank() || text.length > MAX_JOURNAL_CHARS) return null
        val values = HashMap<String, String>()
        for (line in text.lineSequence()) {
            if (line.isEmpty()) continue
            val separator = line.indexOf('=')
            if (separator <= 0) return null
            val key = line.substring(0, separator)
            val value = line.substring(separator + 1)
            if (key !in JOURNAL_KEYS || values.put(key, value) != null) return null
            if (!safeValue(value)) return null
        }
        if (values["schema"] != JOURNAL_SCHEMA) return null
        val captureId = values["captureId"] ?: return null
        val requestId = values["requestId"] ?: return null
        val daemonPid = values["daemonPid"]?.toLongOrNull() ?: return null
        val daemonStartTicks = values["daemonStartTicks"]?.toLongOrNull() ?: return null
        val bootId = values["bootId"] ?: return null
        val helperPid = values["helperPid"]?.toLongOrNull() ?: return null
        val helperStartTicks = values["helperStartTicks"]?.toLongOrNull() ?: return null
        val helperPath = values["helperPath"] ?: return null
        val helperSha256 = values["helperSha256"] ?: return null
        val outputPath = values["outputPath"] ?: return null
        val startedAtMillis = values["startedAtMillis"]?.toLongOrNull() ?: return null
        val deadlineMillis = values["deadlineMillis"]?.toLongOrNull() ?: return null
        val maxMillis = values["maxMillis"]?.toLongOrNull() ?: return null
        val maxBytes = values["maxBytes"]?.toLongOrNull() ?: return null
        val guardSchema = values["guardSchema"] ?: return null
        val guardVersion = values["guardVersion"]?.toIntOrNull() ?: return null
        val ownerTask = values["ownerTaskId"]
        val ownerRun = values["ownerRunId"]
        val ownerEpoch = values["ownerEpoch"]?.toLongOrNull()
        val owner = if (ownerTask != null || ownerRun != null || ownerEpoch != null) {
            if (ownerTask == null || ownerRun == null || ownerEpoch == null) return null
            RootCaptureSessions.OwnerIdentity(ownerTask, ownerRun, ownerEpoch)
                .takeIf { it.valid() } ?: return null
        } else {
            null
        }
        if (!UUID_TEXT.matches(captureId)) return null
        if (requestId.isEmpty() || requestId.length > 128) return null
        if (!BOOT_ID.matches(bootId)) return null
        if (daemonPid <= 0L || daemonStartTicks < 0L) return null
        if (helperPid <= 0L || helperStartTicks <= 0L) return null
        if (!validPath(helperPath)) return null
        if (!HEX64.matches(helperSha256.lowercase())) return null
        if (!validPath(outputPath)) return null
        if (outputPath != "${RootCaptureHelper.WORK_ROOT}/capture-$captureId.pcap") return null
        if (startedAtMillis <= 0L || deadlineMillis < startedAtMillis) return null
        if (maxMillis !in 1_000L..MAX_GUARD_MILLIS) return null
        if (maxBytes !in MIN_GUARD_BYTES..MAX_HELPER_BYTES) return null
        if (guardSchema != GUARD_SCHEMA || guardVersion != GUARD_VERSION) return null
        return CaptureJournal(
            captureId = captureId,
            requestId = requestId,
            owner = owner,
            daemonPid = daemonPid,
            daemonStartTicks = daemonStartTicks,
            bootId = bootId,
            helperPid = helperPid,
            helperStartTicks = helperStartTicks,
            helperPath = helperPath,
            helperSha256 = helperSha256.lowercase(),
            outputPath = outputPath,
            startedAtMillis = startedAtMillis,
            deadlineMillis = deadlineMillis,
            maxMillis = maxMillis,
            maxBytes = maxBytes,
            guardSchema = guardSchema,
            guardVersion = guardVersion,
        )
    }

    private fun validJournal(journal: CaptureJournal): Boolean {
        if (!UUID_TEXT.matches(journal.captureId)) return false
        if (journal.requestId.isEmpty() || journal.requestId.length > 128) return false
        if (!safeValue(journal.requestId)) return false
        journal.owner?.let { if (!it.valid()) return false }
        if (journal.daemonPid <= 0L || journal.daemonStartTicks < 0L) return false
        if (!BOOT_ID.matches(journal.bootId)) return false
        if (journal.helperPid <= 0L || journal.helperStartTicks <= 0L) return false
        if (!validPath(journal.helperPath)) return false
        if (!HEX64.matches(journal.helperSha256)) return false
        if (!validPath(journal.outputPath)) return false
        if (journal.outputPath !=
            "${RootCaptureHelper.WORK_ROOT}/capture-${journal.captureId}.pcap"
        ) {
            return false
        }
        if (journal.startedAtMillis <= 0L || journal.deadlineMillis < journal.startedAtMillis) {
            return false
        }
        if (journal.maxMillis !in 1_000L..MAX_GUARD_MILLIS) return false
        if (journal.maxBytes !in MIN_GUARD_BYTES..MAX_HELPER_BYTES) return false
        if (journal.guardSchema != GUARD_SCHEMA) return false
        if (journal.guardVersion != GUARD_VERSION) return false
        return true
    }

    private fun fields(text: String): Map<String, String> {
        val result = HashMap<String, String>()
        for (token in text.trim().split(' ')) {
            if (token.isEmpty()) continue
            val separator = token.indexOf('=')
            if (separator <= 0) continue
            result[token.substring(0, separator)] = token.substring(separator + 1)
        }
        return result
    }

    /** Fields 3.. of /proc/<pid>/stat, with comm parsed to the last ')'. */
    private fun statFields(stat: String): List<String>? {
        val close = stat.lastIndexOf(')')
        if (close < 0 || close + 2 >= stat.length) return null
        return stat.substring(close + 2).trim().split(Regex("\\s+"))
    }

    private fun safeValue(value: String): Boolean =
        value.length <= MAX_PATH &&
            value.none { it.code < 0x20 || it.code == 0x7f }

    private fun validPath(path: String): Boolean =
        path.startsWith("/") && path.length < MAX_PATH && safeValue(path)
}
