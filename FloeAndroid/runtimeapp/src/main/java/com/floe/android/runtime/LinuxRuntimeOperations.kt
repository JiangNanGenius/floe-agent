// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.content.Context
import android.os.Process
import android.os.SystemClock
import com.floe.android.runtimeipc.RuntimeExecutionTrace
import com.floe.android.runtimeipc.RuntimeExecutionTrace.Stage
import android.util.Base64
import com.floe.android.linuxruntime.*
import com.floe.android.linuxruntime.install.*
import com.floe.android.linuxruntime.rootfs.LinuxRootfsMaterializer
import com.floe.android.linuxruntime.supervision.*
import com.floe.android.runtimeipc.RuntimePackages
import com.floe.android.runtimeipc.RuntimePeerVerifier
import com.floe.android.runtimeipc.RuntimeWire
import com.floe.android.workspacebridge.RuntimeWorkspaceSession
import com.floe.android.workspacebridge.WorkspaceCancelSignal
import com.floe.android.workspacebridge.WorkspaceImportReceipt
import com.floe.android.workspacebridge.WorkspaceExportOutcome
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/** Service-owned composition. Original Swift registry + lease, real installer + PTY. */
internal class LinuxRuntimeOperations(private val context: Context) : RuntimeOperations {
    private val root = context.filesDir.canonicalFile
    private val catalog = FloeRootfsCatalog.debianBookwormAarch64PdV470
    private val revision = "debian-bookworm-" + catalog.archiveSha256.take(16)
    private val revisionDirectory = File(root, "Base/$revision")
    private val installer = RootfsInstaller(File(root, "Installer"))
    private val authority = LinuxAuthorityClient(context)
    private val supervisor: RuntimeWorkSupervisor
    private val census: ProcCensus
    private val cancelPreparation = AtomicBoolean()
    private val installID = AtomicReference<String?>()
    // R3 first-use preflight ownership (kernel admission already serializes
    // this with install/shell work through hasOwnedWork()).
    private val activePreflightID = AtomicReference<String?>()
    private val preflightCancelled = AtomicBoolean()
    // The ACTUAL verified published-revision archive digest, set only after
    // the ORIGINAL installer manifest verification succeeds in configure().
    // Never minted from a string; absent (null) means NOT installed-proof.
    @Volatile private var rootfsReceiptDigest: String? = null
    private val progress = AtomicReference(JSONObject().put("phase", "not_installed"))
    private val pumpExecutor = java.util.concurrent.ThreadPoolExecutor(1, 1, 30,
        java.util.concurrent.TimeUnit.SECONDS, java.util.concurrent.ArrayBlockingQueue(1)) {
            Thread(it, "floe-linux-pty")
        }.apply { allowCoreThreadTimeOut(true) }
    private val heldLease = AtomicReference<LinuxAuthorityClient.Lease?>()
    // G03-R3 cleanup lane receiver (job-7e9db10b801940c2). Constructed after
    // the supervisor; consumes ONLY the typed `runtimeWorkspaceCopies.clear`
    // control and never runs during an admitted workload (the kernel executes
    // it on the same single control thread; the receiver re-probes busy).
    private val workspaceCleanup by lazy {
        RuntimeWorkspaceCleanup(context, authority, supervisor) {
            installID.get() != null || heldLease.get() != null || running.get() != null
        }
    }

    private class Running(val lease: LinuxAuthorityClient.Lease, val job: SupervisedPtyJob,
                          val deadline: Long, val scratch: File,
                          val workspace: RuntimeWorkspaceSession, val imported: WorkspaceImportReceipt) {
        val terminal = AtomicReference<WorkloadTerminal?>()
        val finished = AtomicBoolean()
        @Volatile var nativeReleaseFailed = false
        @Volatile var cleanupDeferred = false
        @Volatile var workspaceResult: JSONObject? = null
    }
    private val running = AtomicReference<Running?>()
    private val completed = AtomicReference<Running?>()

    init {
        // Validate the actual OS boundary before inspecting/stopping ANY process.
        val pair = RuntimePackages.forRuntime(context.packageName)
        RuntimePeerVerifier(context).verifyPeer(pair.core)
        val reader = AndroidPackageMetadataReader(context)
        val core = checkNotNull(reader.read(pair.core))
        val runtime = checkNotNull(reader.read(pair.runtime))
        val result = RuntimeUidBoundary.validate(pair.core, core.signatureSha256.first(),
            pair.runtime, runtime.signatureSha256.first(), Process.myUid(), Process.myPid(), reader)
        val boundary = (result as? BoundaryCheck.Accepted)?.boundary ?: error("Runtime UID boundary unavailable")
        val signals = PosixSignalBoundary()
        census = ProcCensus(boundary, LinuxProcReader, signals)
        val quiescer = RuntimeUidQuiescer(boundary, census, signals)
        supervisor = RuntimeWorkSupervisor(boundary, DefaultLinuxRuntimeBackend(), census, signals, quiescer)
        val handshake = authority.handshake()
        check(handshake.getInt("wireVersion") == 1 && !handshake.getBoolean("activeLease"))
        recover()
        RuntimeWorkspaceSession.sweepStaleRuntimeJournals(File(root, "Workspaces"),
            System.currentTimeMillis(), 24L * 60 * 60 * 1000)
        installer.sweepStaleWorkspace(maxAgeMs = 0)
        LinuxRootfsMaterializer().restoreMissingLayersBeforeRegistry(File(root, "Environments/Containers"))
        RuntimeNetworkConfiguration.sweepStaleSocketDirs(context)
        RuntimeNetworkConfiguration.installGuestResolverAssets(context) // fail-closed signed-asset staging
        if (revisionDirectory.exists()) {
            configure()
            progress.set(installedProgress())
        }
    }

    private fun recover() {
        val recovery = supervisor.recoverBeforeAdmission("service-admission")
        check(recovery is RecoveryOutcome.Swept && recovery.quiescence is Quiescence.Proven) {
            "Runtime process recovery is incomplete; environment retained"
        }
    }

    override fun hasOwnedWork(): Boolean = installID.get() != null || heldLease.get() != null
    override fun isExecuting(): Boolean = running.get() != null
    override fun snapshot(request: RuntimeWire.Request): JSONObject? = when (request.operation) {
        "install.status" -> { fields(request.payload, emptySet()); JSONObject(progress.get().toString()) }
        "shell.poll" -> poll(request.payload)
        else -> null
    }

    override fun execute(request: RuntimeWire.Request, workspaceGrant: android.os.IBinder?, cancelled: () -> Boolean): JSONObject = when (request.operation) {
        "install.start" -> install(request, cancelled)
        "install.status" -> { fields(request.payload, emptySet()); JSONObject(progress.get().toString()) }
        "environment.list" -> { fields(request.payload, emptySet()); configure(); authority.list() }
        "shell.start" -> start(request.payload, checkNotNull(workspaceGrant), cancelled)
        "workspace.preflight" -> preflight(request, checkNotNull(workspaceGrant), cancelled)
        "shell.poll" -> poll(request.payload)
        "shell.input" -> input(request.payload)
        "shell.resize" -> resize(request.payload)
        // G03-R3: the scoped runtime-UID workspace-copy wipe. The receiver
        // returns a TYPED cleared/refused result (never throws for a refusal
        // — an honest retention keeps the Core obligation retryable).
        "runtimeWorkspaceCopies.clear" -> workspaceCleanup.execute(request)
        else -> throw IllegalArgumentException("Unknown runtime operation")
    }

    private fun install(request: RuntimeWire.Request, cancelled: () -> Boolean): JSONObject {
        fields(request.payload, emptySet())
        check(heldLease.get() == null)
        recover()
        check(installID.compareAndSet(null, request.id))
        cancelPreparation.set(false)
        try {
            if (!revisionDirectory.exists()) {
                val parent = checkNotNull(revisionDirectory.parentFile)
                check(parent.mkdirs() || parent.isDirectory)
                installer.install(catalog, revisionDirectory,
                    ProgressListener { value -> progress.set(JSONObject().put("phase", value.phase.name.lowercase())
                        .put("requestID", request.id).put("archiveBytes", value.archiveBytesDone)
                        .put("archiveTotal", value.archiveBytesTotal).put("entries", value.entriesDone)
                        .put("extractedBytes", value.extractedBytesDone)) },
                    CancellationCheck { cancelPreparation.get() || cancelled() })
            }
            check(!cancelPreparation.get() && !cancelled())
            configure()
            progress.set(installedProgress(requestID = request.id))
            return JSONObject(progress.get().toString())
        } catch (failure: Exception) {
            progress.set(JSONObject().put("phase", if (cancelPreparation.get()) "cancelled" else "failed")
                .put("requestID", request.id))
            throw failure
        } finally { installID.compareAndSet(request.id, null) }
    }

    private fun configure() {
        val manifest = installer.verifyPublishedRevision(revisionDirectory)
        check(manifest.archiveSha256 == catalog.archiveSha256 && manifest.catalogId == catalog.catalogId)
        authority.configure(File(revisionDirectory, "rootfs"), revision)
        // Published revision verification PASSED: this is the genuine
        // rootfs receipt the trusted host may ingest.
        rootfsReceiptDigest = manifest.archiveSha256
    }

    /** Honest installed snapshot: the receipt fields appear ONLY after a
     *  real verifyPublishedRevision pass; a mere directory presence never
     *  qualifies them. */
    private fun installedProgress(requestID: String? = null): JSONObject {
        val value = JSONObject().put("phase", "installed").put("baseRevision", revision)
        rootfsReceiptDigest?.let { value.put("rootfsReceiptDigest", it).put("rootfsVersion", revision) }
        requestID?.let { value.put("requestID", it) }
        return value
    }

    /** First-use NON-EXECUTING workspace preflight (R3). Same single-slot
     *  serialization as shell/install; the helper itself can spawn nothing. */
    private fun preflight(request: RuntimeWire.Request, grant: android.os.IBinder,
                          cancelled: () -> Boolean): JSONObject {
        check(activePreflightID.compareAndSet(null, request.id)) { "preflightBusy" }
        preflightCancelled.set(false)
        try {
            return RuntimeWorkspacePreflight.execute(
                PreflightHarness(context, authority, supervisor, census,
                    ensureConfigured = { recover(); configure() },
                    ownedPath = ::ownedPath, heldLease = heldLease, installID = installID),
                request.payload, grant) { cancelled() || preflightCancelled.get() }
        } finally { activePreflightID.compareAndSet(request.id, null) }
    }

    private fun start(payload: JSONObject, workspaceGrant: android.os.IBinder, cancelled: () -> Boolean): JSONObject {
        RuntimeExecutionTrace.mark(Stage.OPS_START_ENTER)
        fields(payload, setOf("projectID", "runID", "conversationID", "environmentID", "command", "cwd", "env", "rows", "columns", "timeoutSeconds", "stdinDelivery"))
        check(heldLease.get() == null && installID.get() == null)
        cancelPreparation.set(false)
        RuntimeExecutionTrace.mark(Stage.OPS_RECOVER)
        recover()
        RuntimeExecutionTrace.mark(Stage.OPS_CONFIGURE)
        configure()
        val command = payload.getString("command")
        require(command.isNotBlank() && command.toByteArray(Charsets.UTF_8).size <= 16_384 && '\u0000' !in command)
        val extraEnvironment = mutableMapOf<String, String>()
        if (payload.has("env")) {
            val values = payload.getJSONObject("env")
            require(values.length() <= 32)
            var bytes = 0
            for (key in values.keys()) {
                require(key.matches(Regex("[A-Za-z_][A-Za-z0-9_]{0,63}")) &&
                    !key.startsWith("PROOT_") && !key.startsWith("FLOE_") && key !in setOf("HOME", "TMPDIR"))
                val value = values.get(key)
                require(value is String && '\u0000' !in value)
                bytes += key.toByteArray(Charsets.UTF_8).size + value.toByteArray(Charsets.UTF_8).size
                require(bytes <= 32_768)
                extraEnvironment[key] = value
            }
        }
        val cwd = payload.optString("cwd", ".")
        require(!cwd.startsWith('/') && '\u0000' !in cwd && cwd.length <= 4096 && cwd.split('/').none { it == ".." })
        val rows = payload.optInt("rows", 24); val columns = payload.optInt("columns", 80)
        require(rows in 1..512 && columns in 1..512)
        val seconds = payload.optDouble("timeoutSeconds", 600.0)
        require(seconds.isFinite() && seconds in 0.05..86_400.0)
        // Stdin delivery is explicit and platform-owned: the peer-verified
        // core host adapter (the same platform code path that already owns
        // command/env/lease fields) sends "pipe" only for one-shot job runs
        // and omits the field for interactive PTY input. The value set is
        // closed and unknown values refuse the start, so no model or
        // environment string can pick a descriptor mode or an execution
        // path; "pipe" only re-describes THIS guest launch's stdin.
        val stdinDelivery = payload.optString("stdinDelivery", "pty")
        require(stdinDelivery in setOf("pty", "pipe")) { "stdinDelivery invalid" }
        RuntimeExecutionTrace.mark(Stage.OPS_ACQUIRE)
        val lease = authority.acquire(payload)
        RuntimeExecutionTrace.mark(Stage.OPS_ACQUIRED)
        heldLease.set(lease)
        var child: Running? = null
        var preparedScratch: File? = null
        var preparedWorkspace: RuntimeWorkspaceSession? = null
        var safeToAbandon = true
        try {
            val descriptor = lease.descriptor
            val writable = ownedPath(descriptor.getString("writableLayer"))
            val layers = descriptor.getJSONArray("orderedLayers")
            val ordered = (0 until layers.length()).map { ownedPath(layers.getString(it)) }
            RuntimeExecutionTrace.mark(Stage.OPS_MATERIALIZE)
            LinuxRootfsMaterializer().prepare(LinuxRootfsMaterializer.Plan(lease.environmentID,
                descriptor.getString("baseRevision"), writable, ordered)) { cancelPreparation.get() || cancelled() }
            check(!cancelPreparation.get() && !cancelled())
            RuntimeExecutionTrace.mark(Stage.OPS_MATERIALIZED)
            val workspace = ownedPath(descriptor.getString("workspaceRoot"))
            val workspaceSession = RuntimeWorkspaceSession(context, workspaceGrant,
                payload.getString("projectID"), payload.getString("runID"), workspace)
            preparedWorkspace = workspaceSession
            RuntimeExecutionTrace.mark(Stage.OPS_IMPORT)
            val imported = workspaceSession.importBeforeLaunch(WorkspaceCancelSignal {
                cancelPreparation.get() || cancelled()
            })
            RuntimeExecutionTrace.mark(Stage.OPS_IMPORTED)
            check(imported.skippedCount == 0) { "Workspace snapshot contains unsupported entries" }
            check(!cancelPreparation.get() && !cancelled())
            val scratchParent = File(root, "Scratch").apply { check(mkdirs() || isDirectory) }
            check(scratchParent.canonicalFile == scratchParent)
            val scratch = File(scratchParent, lease.id)
            java.nio.file.Files.createDirectory(scratch.toPath())
            java.nio.file.Files.write(File(scratch, ".floe-owner").toPath(), lease.id.toByteArray(Charsets.UTF_8),
                java.nio.file.StandardOpenOption.CREATE_NEW, java.nio.file.StandardOpenOption.WRITE)
            preparedScratch = scratch
            RuntimeExecutionTrace.mark(Stage.OPS_BUILD_SPEC)
            val spec = PRootLaunchSpec(File(context.applicationInfo.nativeLibraryDir), writable, scratch,
                "/workspace" + (if (cwd == ".") "" else "/$cwd"), "/home/floe", "/tmp",
                listOf(LinuxBind(workspace, "/workspace"), LinuxBind(File("/dev"), "/dev"), LinuxBind(File("/proc"), "/proc")) +
                    RuntimeNetworkConfiguration.prepareBinds(context, scratch),
                RunOwnership(lease.environmentID, descriptor.getString("runID"), descriptor.getString("projectContainerID"), writable.path),
                emulateGuestRoot = true).command(listOf("/bin/sh", "-lc", command),
                    guestVariables(descriptor, writable, ordered) + extraEnvironment +
                        mapOf("FLOE_ENVIRONMENT_ID" to lease.environmentID), rows, columns,
                    stdinDelivery = if (stdinDelivery == "pipe") StdinDelivery.OneShotPipe
                    else StdinDelivery.PtyInput)
            RuntimeExecutionTrace.mark(Stage.OPS_SPEC_READY)
            val terminal = AtomicReference<WorkloadTerminal?>()
            RuntimeExecutionTrace.mark(Stage.OPS_SPAWN)
            when (val outcome = supervisor.start(spec, LeaseToken(lease.id, descriptor.getString("runID"))) { terminal.set(it) }) {
                is StartOutcome.Refused -> error("Linux process was not admitted")
                is StartOutcome.Abandoned -> {
                    // A real failed-spawn child must be proven stopped. No-child
                    // transport failure alone is safe to retire unstarted.
                    safeToAbandon = outcome.terminal.quiescence == null || outcome.terminal.quiescence is Quiescence.Proven
                    error("Linux process launch failed")
                }
                is StartOutcome.Accepted -> {
                    RuntimeExecutionTrace.mark(Stage.OPS_SPAWN_ACCEPTED)
                    safeToAbandon = false
                    child = Running(lease, outcome.job, SystemClock.elapsedRealtime() + (seconds * 1000).toLong(), scratch,
                        workspaceSession, imported)
                    running.set(child)
                    authority.started(lease, outcome.job.rootBirth)
                    RuntimeExecutionTrace.mark(Stage.OPS_BIND_STARTED)
                    val owned = checkNotNull(child)
                    pumpExecutor.execute {
                        RuntimeExecutionTrace.mark(Stage.OPS_PUMP_ENTER)
                        try {
                            while (owned.job.stateNow != JobState.TERMINATED) {
                                if (cancelPreparation.get() || cancelled()) owned.job.requestCancel("user-stop")
                                else if (SystemClock.elapsedRealtime() >= owned.deadline) owned.job.requestCancel("timeout")
                                val pumped = owned.job.pump()
                                if (pumped is PumpOutcome.Blocked || pumped is PumpOutcome.QuiescePending || pumped is PumpOutcome.ReadFailed) break
                            }
                            RuntimeExecutionTrace.mark(Stage.OPS_PUMP_ENDED)
                            owned.terminal.set(terminal.get())
                            finish(owned)
                            RuntimeExecutionTrace.mark(Stage.OPS_FINISH_RETURNED)
                        } catch (_: Exception) {
                            RuntimeExecutionTrace.mark(Stage.OPS_PUMP_EXCEPTION)
                            owned.nativeReleaseFailed = true
                        }
                    }
                    return JSONObject().put("sessionID", lease.id).put("environmentID", lease.environmentID)
                }
            }
        } catch (failure: Exception) {
            RuntimeExecutionTrace.mark(Stage.OPS_START_EXCEPTION)
            if (safeToAbandon) {
                runCatching { preparedWorkspace?.close() }
                RuntimeNetworkConfiguration.release() // real use ended before spawn
                authority.abandonUnstarted(lease)
                heldLease.compareAndSet(lease, null)
                preparedScratch?.let { cleanupScratch(it, lease.id) }
            }
            else child?.let { owned ->
                // If native binding failed after spawn, stop before attempting
                // any hand-back. Unknown stop keeps the original lease held.
                val stopped = owned.job.requestCancel("start-binding-failed")
                if (stopped is CancelOutcome.Terminated) {
                    owned.terminal.set(stopped.terminal)
                    // Re-issue exact binding before completion; both are idempotent.
                    runCatching { authority.started(lease, owned.job.rootBirth); finish(owned) }
                }
            }
            throw failure
        }
    }

    /** Translate ORIGINAL authority paths into this complete guest snapshot.
     * Never inherit Core/Android process environment or guess a write layer. */
    private fun guestVariables(descriptor: JSONObject, writable: File, ordered: List<File>): Map<String, String> {
        val variables = descriptor.getJSONObject("variables")
        val roots = (listOf(writable) + ordered).map { it.canonicalFile.toPath() }.distinct()
        fun guest(path: String): String {
            require(path.startsWith('/') && '\u0000' !in path)
            val normalized = File(path).canonicalFile.toPath()
            for (root in roots) if (normalized.startsWith(root)) return "/" + root.relativize(normalized).toString()
            require(path in setOf("/usr/bin", "/bin", "/usr/local/bin", "/usr/sbin", "/sbin", "/usr/local/sbin"))
            return path
        }
        check(ownedPath(descriptor.getString("home")).toPath().startsWith(writable.toPath()))
        check(ownedPath(descriptor.getString("tmp")).toPath().startsWith(writable.toPath()))
        check(guest(descriptor.getString("home")) == "/home/floe" && guest(descriptor.getString("tmp")) == "/tmp")
        val result = mutableMapOf("HOME" to "/home/floe", "TMPDIR" to "/tmp")
        for (key in listOf("PATH", "PYTHONPATH", "NODE_PATH")) {
            val paths = variables.getString(key).split(':').filter { it.isNotEmpty() }.map(::guest)
            result[key] = (paths + if (key == "PATH") listOf("/usr/local/sbin", "/usr/sbin", "/sbin") else emptyList())
                .distinct().joinToString(":")
        }
        return result
    }

    private fun finish(owned: Running) {
        synchronized(owned) {
            if (owned.finished.get()) return
            val terminal = owned.terminal.get() ?: return
            val exit: ExitResult
            val proof: Quiescence.Proven
            when (terminal) {
                is WorkloadTerminal.Completed -> { exit = terminal.exit; proof = terminal.quiescence }
                is WorkloadTerminal.Cancelled -> { exit = terminal.exit; proof = terminal.quiescence }
                is WorkloadTerminal.SpawnAbandoned -> return
            }
            if (owned.workspaceResult == null) {
                // The actual whole-UID stop proof above precedes file export.
                // A Stop request does not discard partial user outputs; flush
                // them while the same operation still owns its Core grant.
                val outcome = try { owned.workspace.exportAfterQuiescence(WorkspaceCancelSignal {
                    Thread.currentThread().isInterrupted
                }) } catch (_: Exception) {
                    WorkspaceExportOutcome.RecoverableFailure("exportUnknown", true, owned.imported.sessionKey)
                }
                owned.workspaceResult = workspaceResult(outcome, owned.imported.sessionKey)
                runCatching { owned.workspace.close() }
            }
            try {
                authority.complete(owned.lease, owned.job.rootBirth, exit, proof)
            } catch (failure: Exception) { owned.nativeReleaseFailed = true; throw failure }
            // Native completion is authoritative. A later scratch-cleanup
            // failure must not turn a released lease into a fabricated live one.
            owned.nativeReleaseFailed = false
            owned.finished.set(true); completed.set(owned)
            heldLease.compareAndSet(owned.lease, null); running.compareAndSet(owned, null)
            RuntimeNetworkConfiguration.release() // the owned session's real resolver use has ended
            owned.cleanupDeferred = !cleanupScratch(owned.scratch, owned.lease.id)
        }
    }

    private fun workspaceResult(outcome: WorkspaceExportOutcome, sessionKey: String): JSONObject {
        val status = when (outcome) {
            is WorkspaceExportOutcome.Synced -> "synced"
            is WorkspaceExportOutcome.Conflict -> if (outcome.status == "aborted") "aborted" else "conflict"
            is WorkspaceExportOutcome.RecoverableFailure -> "error"
        }
        return JSONObject().put("workspaceStatus", status).also {
            if (status != "synced" && sessionKey.matches(Regex("^[0-9a-f]{32}$"))) {
                it.put("workspaceRecoveryRef", sessionKey)
            }
        }
    }

    private fun matching(payload: JSONObject): Running {
        val id = payload.getString("sessionID")
        return running.get()?.takeIf { it.lease.id == id }
            ?: completed.get()?.takeIf { it.lease.id == id } ?: error("Unknown Linux session")
    }

    private fun poll(payload: JSONObject): JSONObject {
        fields(payload, setOf("sessionID", "cursor", "maxBytes"))
        val owned = matching(payload)
        val cursor = payload.optLong("cursor", 0)
        val max = payload.optInt("maxBytes", 16_384)
        require(cursor >= 0 && max in 1..16_384)
        val page = owned.job.output(cursor, max)
        return JSONObject().put("sessionID", owned.lease.id)
            .put("state", if (owned.nativeReleaseFailed) "lease_retained" else owned.job.stateNow.name.lowercase())
            .put("outputBase64", Base64.encodeToString(page.bytes, Base64.NO_WRAP))
            .put("cursor", page.nextCursor).put("gapBytes", page.gapBytes).put("more", page.truncatedMore)
            .put("droppedBytes", page.totalDroppedBytes).put("leaseReleased", owned.finished.get())
            .put("cancelled", owned.terminal.get() is WorkloadTerminal.Cancelled)
            .put("cleanupDeferred", owned.cleanupDeferred)
            .also { result -> owned.workspaceResult?.let { files ->
                result.put("workspaceStatus", files.getString("workspaceStatus"))
                if (files.has("workspaceRecoveryRef")) result.put("workspaceRecoveryRef", files.getString("workspaceRecoveryRef"))
            } }
            .also { result -> (owned.terminal.get() as? WorkloadTerminal.Cancelled)?.let { result.put("stopReason", it.reason) } }
            .also { result -> owned.job.exitResult?.let { result.put("exitCode", it.exitCode).put("termSig", it.termSig).put("waitErrno", it.waitErrno) } }
            // Additive honest stdin facts for one-shot pipe sessions only
            // (counts and descriptor state, never stdin content).
            .also { result -> owned.job.stdinStatus()
                .takeIf { it.delivery == StdinDelivery.OneShotPipe }
                ?.let { s -> result.put("stdin", JSONObject().put("delivery", "pipe")
                    .put("acceptedBytes", s.acceptedBytes).put("eof", s.eofDelivered)
                    .also { e -> s.lastErrno?.let { e.put("lastErrno", it) } }) } }
    }

    private fun input(payload: JSONObject): JSONObject {
        fields(payload, setOf("sessionID", "inputBase64"))
        val owned = matching(payload)
        check(running.get() === owned)
        val encoded = payload.getString("inputBase64")
        require(encoded.length <= 22_000)
        val bytes = Base64.decode(encoded, Base64.NO_WRAP)
        require(bytes.size <= 16_384)
        if (bytes.isEmpty() && owned.job.stdinDelivery == StdinDelivery.OneShotPipe) {
            // EMPTY PAGE ON A ONE-SHOT PIPE SESSION = REAL EOF COMMAND: close
            // the owned stdin write end. Zero bytes can never be confused
            // with stdin data (unlike an EOT byte, which is ordinary data in
            // raw mode). This is distinct from process exit and output drain:
            // the shared PTY master stays open. On PTY-delivery sessions an
            // empty page remains the unchanged no-op.
            return when (val eof = owned.job.requestStdinEof()) {
                is StdinEof.Closed -> JSONObject().put("acceptedBytes", 0)
                    .put("stdinEof", if (eof.idempotent) "closed-idempotent" else "closed")
                is StdinEof.Failed -> JSONObject().put("acceptedBytes", 0)
                    .put("stdinEof", "failed").put("errno", eof.errno)
                is StdinEof.Rejected -> JSONObject().put("acceptedBytes", 0)
                    .put("stdinEof", "rejected").put("reason", eof.reason)
            }
        }
        // Feed one <=16 KiB wire page through the bounded stdin pump in
        // maxStdinChunkBytes chunks so a valid wire page is never refused
        // wholesale. acceptedBytes is the progress cursor: the caller re-sends
        // only the remainder after Partial/Failed, so bytes are never
        // duplicated and never silently dropped.
        var accepted = 0
        var partial = false
        var errno: Int? = null
        while (accepted < bytes.size) {
            val take = minOf(owned.job.maxStdinChunkBytes, bytes.size - accepted)
            when (val result = owned.job.writeStdin(bytes, accepted, take)) {
                is StdinWrite.Complete -> accepted += result.bytes
                is StdinWrite.Partial -> {
                    accepted += result.bytes
                    partial = true
                    errno = result.errno
                    break
                }
                is StdinWrite.Failed -> {
                    accepted += result.bytesAlreadyWritten
                    errno = result.errno
                    break
                }
            }
        }
        return JSONObject().put("acceptedBytes", accepted).also {
            if (partial) it.put("partial", true)
            if (errno != null) it.put("errno", errno)
        }
    }

    private fun resize(payload: JSONObject): JSONObject {
        fields(payload, setOf("sessionID", "rows", "columns"))
        val owned = matching(payload)
        check(running.get() === owned)
        val rows = payload.getInt("rows"); val columns = payload.getInt("columns")
        require(rows in 1..512 && columns in 1..512)
        return JSONObject().put("resized", owned.job.resize(rows, columns))
    }

    override fun validateCancellation(request: RuntimeWire.Request) {
        if (request.operation == "install.cancel") {
            fields(request.payload, setOf("requestID"))
            require(request.payload.getString("requestID") == installID.get())
        } else if (request.operation == RuntimeWire.PREFLIGHT_CANCEL) {
            // Target-scoped: cancels ONLY the matching own preflight request;
            // an unrelated workload is never touched by this path.
            fields(request.payload, setOf("requestID"))
            require(request.payload.getString("requestID") == activePreflightID.get())
        } else {
            fields(request.payload, setOf("sessionID"))
            require(request.payload.getString("sessionID") == heldLease.get()?.id)
        }
    }

    override fun stopOwnedWork(request: RuntimeWire.Request?) {
        // Recheck at execution time; a stale cancellation never stops a new task.
        if (request != null) validateCancellation(request)
        if (request?.operation == RuntimeWire.PREFLIGHT_CANCEL ||
            (request == null && activePreflightID.get() != null)
        ) {
            // A preflight has NO process: authority.cancel (the started-lease
            // path) does not apply. Flag the owning thread; it performs the
            // real recoverable abort and the no-children lease release itself.
            preflightCancelled.set(true)
            return
        }
        cancelPreparation.set(true)
        if (request?.operation == "install.cancel") return
        val owned = running.get() ?: run {
            // Preparation or failed-spawn ownership still counts as real work.
            // A stop request only cancels its token; it never invents an exit.
            heldLease.get()?.let { authority.cancel(it) }
            return
        }
        authority.cancel(owned.lease)
        val cancelled = supervisor.cancelActive(owned.job.lease, "user-stop")
        if (cancelled is CancelOutcome.Terminated) { owned.terminal.set(cancelled.terminal); finish(owned) }
    }

    private fun ownedPath(path: String): File {
        val value = File(path)
        require(value.isAbsolute && value.canonicalPath == value.path && value.toPath().startsWith(root.toPath()))
        return value
    }

    private fun fields(payload: JSONObject, allowed: Set<String>) {
        require(payload.keys().asSequence().all { it in allowed })
    }

    /** Best-effort pruning only after proof/no-child retirement; never follows guest links. */
    private fun cleanupScratch(directory: File, leaseID: String): Boolean =
        runCatching {
            val expected = File(root, "Scratch/$leaseID")
            check(directory == expected && directory.canonicalFile == expected)
            val path = directory.toPath()
            val marker = path.resolve(".floe-owner")
            check(java.nio.file.Files.isRegularFile(marker, java.nio.file.LinkOption.NOFOLLOW_LINKS))
            check(java.nio.file.Files.size(marker) <= 64 && String(java.nio.file.Files.readAllBytes(marker), Charsets.UTF_8) == leaseID)
            java.nio.file.Files.walkFileTree(path, object : java.nio.file.SimpleFileVisitor<java.nio.file.Path>() {
                override fun preVisitDirectory(dir: java.nio.file.Path, attrs: java.nio.file.attribute.BasicFileAttributes): java.nio.file.FileVisitResult {
                    java.nio.file.Files.setAttribute(dir, "unix:mode", 0x1C0, java.nio.file.LinkOption.NOFOLLOW_LINKS)
                    return java.nio.file.FileVisitResult.CONTINUE
                }
                override fun visitFile(file: java.nio.file.Path, attrs: java.nio.file.attribute.BasicFileAttributes): java.nio.file.FileVisitResult {
                    java.nio.file.Files.delete(file); return java.nio.file.FileVisitResult.CONTINUE
                }
                override fun postVisitDirectory(dir: java.nio.file.Path, exc: java.io.IOException?): java.nio.file.FileVisitResult {
                    if (exc != null) throw exc
                    java.nio.file.Files.delete(dir); return java.nio.file.FileVisitResult.CONTINUE
                }
            })
        }.isSuccess // Failed ownership/IO checks retain only this marker-owned scratch.
}
