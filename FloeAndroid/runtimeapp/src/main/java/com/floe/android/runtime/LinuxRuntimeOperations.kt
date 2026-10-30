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

/** Service-owned composition. Original Swift registry + lease, real installer + PTY.
 *
 *  [onOwnedWorkReleased] — G03-R3 first-start admission repair: the kernel's
 *  stopping-fence convergence note. Invoked ONLY after finish() has REALLY
 *  released the held lease/running slot through the ORIGINAL authority
 *  hand-back (never on a pending-proof return, never on a failed release),
 *  so a stop that arrived while this pump thread was still draining no
 *  longer leaves a stale kernel fence refusing the next admission. The
 *  default keeps every other constructor call site byte-compatible. */
internal class LinuxRuntimeOperations(
    private val context: Context,
    private val onOwnedWorkReleased: () -> Unit = {},
) : RuntimeOperations {
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
    // G03-R3 runtime-start repair: the EXACT pending shell.start wire request
    // id currently executing inside start() on the owned control thread — the
    // SAME id the kernel tracks as its pendingShellID (the pump dispatches
    // shell.start with its own control UUID as the wire request id, and the
    // session-less stop carries that identical UUID). Set in the execute()
    // dispatch and cleared on return. A session-less stop is
    // validated ONLY against this exact id (target-scoped; never a broad
    // runtime cancel), so it can arm cancelPreparation while a start is still
    // executing before any session id has ever surfaced.
    private val pendingShellStartID = AtomicReference<String?>()
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
                          val workspace: RuntimeWorkspaceSession, val imported: WorkspaceImportReceipt,
                          /** G07.1 terminal04: bounded runtime phase composition for
                           *  THIS workload (diagnostic only; no admission effect). */
                          val latency: LinuxRuntimePhaseTiming.Run) {
        val terminal = AtomicReference<WorkloadTerminal?>()
        val finished = AtomicBoolean()
        @Volatile var authorityBound = false
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
        "shell.start" -> {
            // G03-R3 runtime-start repair: expose the EXACT in-flight start
            // request id for session-less cancellation validation for the
            // whole duration of start() (cleared on return, whether the
            // session was Accepted, Abandoned or thrown).
            pendingShellStartID.set(request.id)
            try {
                start(request.payload, checkNotNull(workspaceGrant), cancelled)
            } finally {
                pendingShellStartID.compareAndSet(request.id, null)
            }
        }
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
        // G07.1 terminal04: the runtime half of this start's composition.
        val latency = LinuxRuntimePhaseTiming.begin()
        fields(payload, setOf("projectID", "runID", "conversationID", "environmentID", "command", "cwd", "env", "rows", "columns", "timeoutSeconds", "stdinDelivery"))
        check(heldLease.get() == null && installID.get() == null)
        cancelPreparation.set(false)
        RuntimeExecutionTrace.mark(Stage.OPS_RECOVER)
        recover()
        latency.mark(LinuxRuntimePhaseTiming.Phase.RECOVER)
        RuntimeExecutionTrace.mark(Stage.OPS_CONFIGURE)
        configure()
        latency.mark(LinuxRuntimePhaseTiming.Phase.CONFIGURE)
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
        latency.mark(LinuxRuntimePhaseTiming.Phase.ACQUIRE)
        RuntimeExecutionTrace.mark(Stage.OPS_ACQUIRED)
        heldLease.set(lease)
        var child: Running? = null
        var preparedScratch: File? = null
        var preparedWorkspace: RuntimeWorkspaceSession? = null
        var safeToAbandon = true
        val terminal = AtomicReference<WorkloadTerminal?>()
        try {
            val descriptor = lease.descriptor
            val writable = ownedPath(descriptor.getString("writableLayer"))
            val layers = descriptor.getJSONArray("orderedLayers")
            val ordered = (0 until layers.length()).map { ownedPath(layers.getString(it)) }
            RuntimeExecutionTrace.mark(Stage.OPS_MATERIALIZE)
            LinuxRootfsMaterializer().prepare(LinuxRootfsMaterializer.Plan(lease.environmentID,
                descriptor.getString("baseRevision"), writable, ordered)) { cancelPreparation.get() || cancelled() }
            latency.mark(LinuxRuntimePhaseTiming.Phase.MATERIALIZE)
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
            latency.mark(LinuxRuntimePhaseTiming.Phase.IMPORT)
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
            latency.mark(LinuxRuntimePhaseTiming.Phase.SPEC)
            RuntimeExecutionTrace.mark(Stage.OPS_SPEC_READY)
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
                    latency.mark(LinuxRuntimePhaseTiming.Phase.SPAWN)
                    RuntimeExecutionTrace.mark(Stage.OPS_SPAWN_ACCEPTED)
                    safeToAbandon = false
                    child = Running(lease, outcome.job, SystemClock.elapsedRealtime() + (seconds * 1000).toLong(), scratch,
                        workspaceSession, imported, latency)
                    running.set(child)
                    val owned = checkNotNull(child)
                    synchronized(owned) {
                        authority.started(lease, outcome.job.rootBirth)
                        owned.authorityBound = true
                    }
                    latency.mark(LinuxRuntimePhaseTiming.Phase.BIND)
                    RuntimeExecutionTrace.mark(Stage.OPS_BIND_STARTED)
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
                        // G03-R3 runtime-start repair — the drain-loop break
                        // and a failed release attempt are no longer an
                        // ownership dead end. Retry ONLY the designed proof
                        // and release entries until the REAL release lands.
                        reconcileUntilReleased(owned, terminal)
                    }
                    return JSONObject().put("sessionID", lease.id).put("environmentID", lease.environmentID)
                }
            }
        } catch (failure: Exception) {
            RuntimeExecutionTrace.mark(Stage.OPS_START_EXCEPTION)
            // Diagnostic only: a start that never reached a live workload has
            // no terminal; name the honest state and the phases it did reach.
            latency.publish(
                if (safeToAbandon) LinuxRuntimePhaseTiming.TERMINAL_FAILED
                else LinuxRuntimePhaseTiming.TERMINAL_RETAINED)
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
                cancelPreparation.set(true)
                val stopped = runCatching { owned.job.requestCancel("start-binding-failed") }.getOrNull()
                if (stopped is CancelOutcome.Terminated) owned.terminal.set(stopped.terminal)
                // The pump may never have been admitted. This control thread
                // retains the same real child/lease until retryable proof and
                // authority hand-back succeed; the independent stop lane is
                // still available. Never replay the original command.
                reconcileUntilReleased(owned, terminal)
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
            // G07.1 terminal04: the pump loop ended on a REAL terminal, so the
            // process/stop-proof window closes here; export + native release
            // are measured separately below (diagnostic only).
            owned.latency.mark(LinuxRuntimePhaseTiming.Phase.RUN)
            val exit: ExitResult
            val proof: Quiescence.Proven
            when (terminal) {
                is WorkloadTerminal.Completed -> { exit = terminal.exit; proof = terminal.quiescence }
                is WorkloadTerminal.Cancelled -> { exit = terminal.exit; proof = terminal.quiescence }
                is WorkloadTerminal.SpawnAbandoned -> return
            }
            if (!owned.authorityBound) {
                // A lost binding reply is retryable with the exact measured
                // root birth. No export/completion can precede that binding.
                authority.started(owned.lease, owned.job.rootBirth)
                owned.authorityBound = true
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
                owned.workspaceResult = workspaceResult(outcome, owned.imported)
                runCatching { owned.workspace.close() }
            }
            owned.latency.mark(LinuxRuntimePhaseTiming.Phase.EXPORT)
            try {
                authority.complete(owned.lease, owned.job.rootBirth, exit, proof)
            } catch (failure: Exception) {
                owned.nativeReleaseFailed = true
                owned.latency.publish(LinuxRuntimePhaseTiming.TERMINAL_RETAINED)
                throw failure
            }
            owned.latency.mark(LinuxRuntimePhaseTiming.Phase.COMPLETE)
            // Native completion is authoritative. A later scratch-cleanup
            // failure must not turn a released lease into a fabricated live one.
            owned.nativeReleaseFailed = false
            owned.finished.set(true); completed.set(owned)
            heldLease.compareAndSet(owned.lease, null); running.compareAndSet(owned, null)
            RuntimeNetworkConfiguration.release() // the owned session's real resolver use has ended
            owned.cleanupDeferred = !cleanupScratch(owned.scratch, owned.lease.id)
            // G03-R3 first-start admission repair: notify the kernel that the
            // REAL owned-work release landed — exactly the completion the stop
            // executor's finally may have evaluated too early while this pump
            // thread was still draining (candidate08: the leaked fence then
            // refused the brand-new New task's first start). Lock order here
            // is owned-monitor -> fence-monitor and strictly one-way; the
            // fence re-checks the engine's OWN live ownership under its own
            // monitor, so a failed or duplicate notification can never
            // un-release the lease, admit work or bypass any stop.
            runCatching { onOwnedWorkReleased() }
            // Published exactly once, after the REAL release path succeeded.
            owned.latency.publish(
                if (terminal is WorkloadTerminal.Cancelled) LinuxRuntimePhaseTiming.TERMINAL_CANCELLED
                else LinuxRuntimePhaseTiming.TERMINAL_EXITED)
        }
    }

    private fun workspaceResult(outcome: WorkspaceExportOutcome, receipt: WorkspaceImportReceipt): JSONObject {
        val sessionKey = receipt.sessionKey
        val status = when (outcome) {
            is WorkspaceExportOutcome.Synced -> "synced"
            is WorkspaceExportOutcome.Conflict -> if (outcome.status == "aborted") "aborted" else "conflict"
            is WorkspaceExportOutcome.RecoverableFailure -> "error"
        }
        return JSONObject().put("workspaceStatus", status).also {
            if (status != "synced" && sessionKey.matches(Regex("^[0-9a-f]{32}$"))) {
                it.put("workspaceRecoveryRef", sessionKey)
            }
            // Additive OPTIONAL per-execution recovery projection built ONLY
            // from this session's OWN original receipt + typed outcome. It
            // never changes workspaceStatus semantics; consumers treat a
            // missing object exactly like the pre-feature legacy results.
            RuntimeWorkspaceSession.executionRecoveryJSON(receipt, outcome)?.let { recovery ->
                it.put("workspaceRecovery", recovery)
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
                if (files.has("workspaceRecovery")) result.put("workspaceRecovery", files.getJSONObject("workspaceRecovery"))
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
        if (running.get() !== owned) {
            // G03-R3 fast-exit stdin contract: the trusted one-shot backend
            // ALWAYS commands exactly one trailing EMPTY shell.input EOF
            // page after the start reply (including nil stdin); a fast
            // command can settle the session before that page is executed.
            // The lifecycle already closed the write end at the REAL
            // terminal, so the honest answer is the SAME rejected EOF the
            // running engine reports — bound to the actual terminal facts —
            // never a fabricated accepted delivery. A NON-empty input page
            // to a finished session still refuses (no data ever crosses
            // after terminal).
            val encoded = payload.getString("inputBase64")
            require(encoded.isEmpty()) { "Session already finished" }
            val terminal = owned.terminal.get()
            return JSONObject().put("sessionID", owned.lease.id).put("acceptedBytes", 0)
                .put("stdinEof", "rejected").put("reason", "sessionReleased")
                .put("leaseReleased", owned.finished.get())
                .also { page ->
                    (terminal as? WorkloadTerminal.Completed)?.let { page.put("exitCode", it.exit.exitCode) }
                    (terminal as? WorkloadTerminal.Cancelled)?.let {
                        page.put("cancelled", true).put("stopReason", it.reason)
                    }
                }
        }
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
            // G03-R3 runtime-start repair — exactly TWO target-scoped
            // shell.cancel grammars, decided by ONE pure function:
            //  * started session (unchanged primary path): the exact
            //    {sessionID} equal to the held lease id;
            //  * pending start (additive): the exact {requestID} equal to
            //    this service's own in-flight shell.start wire id — the
            //    same id RuntimeKernel already matched against its
            //    pendingShellID before routing this urgent stop. The old
            //    single-grammar check threw HERE (before stopOwnedWork's
            //    cancelPreparation.set(true)) and the stopExecutor
            //    swallowed it, so a user stop could never cancel a start
            //    still running recover/materialize/import — candidate 05's
            //    notification Stop retained ownership indefinitely.
            // Any other shape or identity mismatch still refuses, and
            // neither grammar ever touches unrelated work.
            val scope = shellCancelScope(
                keys = request.payload.keys().asSequence().toSet(),
                sessionID = request.payload.optString("sessionID").takeIf { it.isNotEmpty() },
                requestID = request.payload.optString("requestID").takeIf { it.isNotEmpty() },
                heldLeaseID = heldLease.get()?.id,
                pendingStartID = pendingShellStartID.get(),
            )
            require(scope != null) { "Cancellation does not address owned work" }
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
        else if (cancelled is CancelOutcome.Rejected && owned.job.stateNow == JobState.TERMINATED) {
            // G03-R3 runtime-start repair: the job already reached its REAL
            // terminal but an earlier release attempt failed (the frozen
            // native lease contract keeps a failed hand-back RETRYABLE, the
            // entry retained). A user stop retries the actual release;
            // finish() is idempotent and its export result stays cached.
            // Nothing is fabricated and a still-failing release keeps every
            // ownership exactly as claimed.
            runCatching { finish(owned) }
        }
    }

    /**
     * G03-R3 runtime-start repair — bounded OWNED release reconciliation.
     * The drain loop above ends on Blocked/QuiescePending/ReadFailed, and
     * finish() then either returned WITHOUT a terminal (proof pending: root
     * reap or whole-runtime-UID census not Proven yet) or threw at the
     * retryable authority hand-back. Nothing retried those DESIGNED entries
     * (SupervisedPtyJob.settleLease had no production caller at all), so a
     * transient proof miss became a permanent held lease: every later
     * shell.start refused as busy (exit=125 runtime_not_started, candidate
     * 05) and the Core foreground ownership kept the wake lock.
     *
     * This loop runs on the service's own pump thread and retries ONLY the
     * real completion paths: settleLease re-runs the missing terminal proof
     * (root reap re-poll + whole-runtime-UID census), and finish() re-runs
     * the export-cached authority completion, which the frozen native lease
     * contract keeps retryable. Invariants: a Pending settlement keeps
     * everything exactly as claimed; a release is NEVER granted on a budget,
     * never fabricated from an absent child at one sample, and the engine
     * deadline stays enforced here even after a transport read failure
     * (requestCancel performs the real stop + whole-UID proof). The loop
     * exits when the real release lands (finished) or when this session no
     * longer owns the running slot; it never bypasses quiescence, ownership,
     * cancellation or drain ordering.
     */
    private fun reconcileUntilReleased(owned: Running,
                                       terminal: AtomicReference<WorkloadTerminal?>) {
        while (!owned.finished.get() && (running.get() === owned || owned.terminal.get() != null)) {
            val action = nextReconcileAction(
                state = owned.job.stateNow,
                finished = owned.finished.get(),
                terminalPresent = owned.terminal.get() != null || terminal.get() != null,
                deadlinePassed = SystemClock.elapsedRealtime() >= owned.deadline,
                stopRequested = cancelPreparation.get(),
            )
            when (action) {
                ReconcileAction.DONE -> return
                ReconcileAction.REQUEST_STOP -> runCatching { owned.job.requestCancel("user-stop") }
                ReconcileAction.ENFORCE_DEADLINE -> runCatching { owned.job.requestCancel("timeout") }
                ReconcileAction.SETTLE -> {
                    val settlement = runCatching { supervisor.settleLease(owned.job.lease) }.getOrNull()
                    if (settlement is LeaseSettlement.Released) {
                        if (owned.terminal.get() == null) owned.terminal.set(terminal.get() ?: settlement.terminal)
                        runCatching { finish(owned) }
                    }
                }
                ReconcileAction.RETRY_FINISH -> {
                    if (owned.terminal.get() == null) owned.terminal.set(terminal.get())
                    runCatching { finish(owned) }
                }
                ReconcileAction.WAIT -> Unit
            }
            if (owned.finished.get()) return
            try { Thread.sleep(1_000) }
            catch (_: InterruptedException) { Thread.currentThread().interrupt(); return }
        }
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

    internal enum class ReconcileAction { DONE, REQUEST_STOP, ENFORCE_DEADLINE, SETTLE, RETRY_FINISH, WAIT }

    companion object {
        /**
         * Pure shell.cancel scope decision (no Android, no org.json): a
         * non-null answer means the cancellation addresses EXACTLY this
         * service's own owned work. "session" is the unchanged started
         * grammar; "pendingStart" is the additive session-less grammar
         * bound to the exact in-flight start request id (the same id the
         * kernel validated before routing the urgent stop — target-scoped,
         * never a broad runtime cancel). Anything else refuses.
         */
        internal fun shellCancelScope(
            keys: Set<String>,
            sessionID: String?,
            requestID: String?,
            heldLeaseID: String?,
            pendingStartID: String?,
        ): String? = when {
            keys == setOf("sessionID") ->
                if (sessionID != null && sessionID == heldLeaseID) "session" else null
            keys == setOf("requestID") ->
                if (requestID != null && requestID == pendingStartID) "pendingStart" else null
            else -> null
        }

        /**
         * Pure next-step decision for the bounded owned release
         * reconciliation. Only real, already-designed completion entries are
         * chosen; WAIT/SETTLE never release anything themselves — the
         * release happens only through settleLease's proven terminal plus
         * finish()'s authority hand-back success (finished).
         */
        internal fun nextReconcileAction(
            state: JobState,
            finished: Boolean,
            terminalPresent: Boolean,
            deadlinePassed: Boolean,
            stopRequested: Boolean = false,
        ): ReconcileAction = when {
            finished -> ReconcileAction.DONE
            state == JobState.TERMINATED ->
                if (terminalPresent) ReconcileAction.RETRY_FINISH else ReconcileAction.SETTLE
            state == JobState.LEASE_RETAINED ->
                if (terminalPresent) ReconcileAction.RETRY_FINISH else ReconcileAction.SETTLE
            state == JobState.RUNNING ->
                if (stopRequested) ReconcileAction.REQUEST_STOP
                else if (deadlinePassed) ReconcileAction.ENFORCE_DEADLINE else ReconcileAction.WAIT
            else -> ReconcileAction.WAIT // CANCELLING: the stop owner converges
        }
    }
}
