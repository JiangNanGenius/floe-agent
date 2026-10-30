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
    /** Bounded install/preparation cancellation lane (never a per-session stop). */
    private val cancelPreparation = AtomicBoolean()
    private val installID = AtomicReference<String?>()
    // G07.3A: EVERY in-flight shell.start wire request id (concurrent starts
    // are admitted). A session-less stop is validated ONLY against one of
    // these exact ids, so it can request cancellation of a preparation that
    // has not surfaced a session yet and never touches unrelated work.
    private val pendingShellStartIDs: MutableSet<String> =
        java.util.concurrent.ConcurrentHashMap.newKeySet()
    private val cancelledStarts: MutableMap<String, AtomicBoolean> =
        java.util.concurrent.ConcurrentHashMap()
    // R3 first-use preflight ownership (kernel admission serializes install /
    // preflight / first-start through the exclusive-work gate).
    private val activePreflightID = AtomicReference<String?>()
    /**
     * The preflight request id whose ORIGINAL never-started lease may still
     * be retained AFTER execute returned (a failed release keeps the lease in
     * `preflightLease`). It stays owned until that lease is really gone, so
     * the service never retires a still-required foreground permit merely
     * because the execute window closed.
     */
    private val retainedPreflightID = AtomicReference<String?>()
    private val preflightCancelled = AtomicBoolean()
    // The ACTUAL verified published-revision archive digest, set only after
    // the ORIGINAL installer manifest verification succeeds in configure().
    // Never minted from a string; absent (null) means NOT installed-proof.
    @Volatile private var rootfsReceiptDigest: String? = null
    private val progress = AtomicReference(JSONObject().put("phase", "not_installed"))
    /** The first-use preflight's own never-started lease (exclusive lane). */
    private val preflightLease = AtomicReference<LinuxAuthorityClient.Lease?>()
    /** Serializes the capacity snapshot with registration (no over-admission). */
    private val admissionBudget = Any()
    // G07.3A: one real PTY pump thread per admitted workload (max 3: two
    // interactive + one shared execution). A single thread would serialize two
    // live terminals and starve one session's output while the other blocks.
    private val pumpExecutor = java.util.concurrent.ThreadPoolExecutor(3, 3, 30,
        java.util.concurrent.TimeUnit.SECONDS, java.util.concurrent.ArrayBlockingQueue(16)) {
            Thread(it, "floe-linux-pty")
        }.apply { allowCoreThreadTimeOut(true) }
    /** Live environment leases keyed by the engine session/lease id. */
    private val heldLeases = java.util.concurrent.ConcurrentHashMap<String, LinuxAuthorityClient.Lease>()
    /**
     * Live lease id -> the exact `shell.start` request id that acquired it.
     * Removed only with the lease itself, so a preparation/acquire retained
     * after a failed start (or a failed cleanup) is still owned by its exact
     * permit association, never silently treated as settled.
     */
    private val leaseStartIDs = java.util.concurrent.ConcurrentHashMap<String, String>()
    private val leaseRoles = java.util.concurrent.ConcurrentHashMap<String, WorkloadRole>()
    /** Live workloads keyed by their engine lease id (== sessionID on the wire). */
    private val running = java.util.concurrent.ConcurrentHashMap<String, Running>()
    /** Bounded settled receipts for poll-after-terminal reads. */
    private val completed = java.util.concurrent.ConcurrentHashMap<String, Running>()
    /** projectID -> the ONE workspace owner lease still responsible for import/export. */
    private val workspaceOwners = java.util.concurrent.ConcurrentHashMap<String, String>()
    /** projectID -> live participant lease ids sharing the owner's guest workspace. */
    private val workspaceParticipants =
        java.util.concurrent.ConcurrentHashMap<String, MutableSet<String>>()
    /** projectID -> the deferred export obligation retained after the owner stops. */
    private val deferredExports = java.util.concurrent.ConcurrentHashMap<String, DeferredExport>()
    /** projectID -> the real export outcome (closed vocabulary) for status reads. */
    private val exportStatuses = java.util.concurrent.ConcurrentHashMap<String, JSONObject>()
    /**
     * Serializes a workload START against a global workspace EXPORT. The
     * ORIGINAL boundary is actual whole runtime-UID quiescence: while any
     * sibling is live, exports defer; the last workload proves global
     * quiescence and services every retained obligation. The gate guarantees
     * no new process can appear between that proof and the exports.
     */
    private val workspaceGate = java.util.concurrent.locks.ReentrantLock()
    // G03-R3 cleanup lane receiver (job-7e9db10b801940c2). Constructed after
    // the supervisor; consumes ONLY the typed `runtimeWorkspaceCopies.clear`
    // control and never runs during an admitted workload.
    private val workspaceCleanup by lazy {
        RuntimeWorkspaceCleanup(context, authority, supervisor) {
            installID.get() != null || activePreflightID.get() != null ||
                preflightLease.get() != null || heldLeases.isNotEmpty() || running.isNotEmpty() ||
                deferredExports.isNotEmpty()
        }
    }
    /** Live read-only guest file snapshots (bounded, identity-bound). */
    private val liveFiles by lazy { LiveWorkspaceFiles() }
    /** Validated first-use preparation receipts (rootfs/workspace generation). */
    private val preparation = WorkspacePreparationReceipts(File(root, "Prepare"))

    /**
     * One admitted workload. [workspace] is non-null ONLY for the workspace
     * owner; a participant mounts the owner's live guest workspace without an
     * import or export of its own.
     */
    private class Running(
        val lease: LinuxAuthorityClient.Lease,
        val job: SupervisedPtyJob,
        val deadline: Long,
        val scratch: File,
        val role: WorkloadRole,
        val projectID: String,
        val workspaceRoot: File,
        val workspaceOwner: Boolean,
        val workspace: RuntimeWorkspaceSession?,
        val imported: WorkspaceImportReceipt?,
        /** The exact `shell.start` request id that admitted this workload. */
        val startID: String,
        /** The SAME cancellation token as `cancelledStarts[startID]`, so a
         *  target stop can arm it before OR after this Running is published
         *  without a gap between the map handoff and `running[...]`. */
        startCancellation: AtomicBoolean,
        /** G07.1 terminal04: bounded runtime phase composition for
         *  THIS workload (diagnostic only; no admission effect). */
        val latency: LinuxRuntimePhaseTiming.Run,
    ) {
        val terminal = AtomicReference<WorkloadTerminal?>()
        val finished = AtomicBoolean()
        val startCancelled: AtomicBoolean = startCancellation
        @Volatile var authorityBound = false
        @Volatile var nativeReleaseFailed = false
        @Volatile var cleanupDeferred = false
        @Volatile var workspaceResult: JSONObject? = null
    }

    /** A workspace whose owner stopped while participants were still live. */
    private class DeferredExport(
        val projectID: String,
        val environmentID: String,
        val baseRevision: String,
        val workspaceRoot: java.io.File,
        val workspace: RuntimeWorkspaceSession,
        val imported: WorkspaceImportReceipt,
        /** The exact `shell.start` request id of the OWNER whose foreground
         *  grant/permit the deferred export still needs. This keeps the
         *  owner's permit association alive until the LAST global workload
         *  proves whole-UID quiescence and the real export settles. */
        val ownerStartID: String,
    ) {
        val completed = AtomicBoolean()
        val outcome = AtomicReference<JSONObject?>()
    }

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

    override fun hasOwnedWork(): Boolean =
        installID.get() != null || activePreflightID.get() != null ||
            preflightLease.get() != null || heldLeases.isNotEmpty() ||
            // A retained deferred export is real owned work even after its
            // process/lease settled: no install/root teardown may pass it.
            deferredExports.isNotEmpty()
    /** Install/first-use preflight are still exclusive with every workload. */
    override fun hasExclusiveWork(): Boolean =
        installID.get() != null || activePreflightID.get() != null
    override fun isExecuting(): Boolean = running.isNotEmpty()

    /**
     * Every exact request id that still owns runtime work: install/preflight,
     * pending start, retained lease/failed lease, live Running.startID and
     * the OWNER start id of every retained deferred export. A completed/stale
     * target is absent here; only that positive removal may retire its
     * foreground-permit association. No elapsed-time/budget term exists.
     */
    override fun ownedRequestIDs(): Set<String> {
        val ids = LinkedHashSet<String>()
        installID.get()?.let(ids::add)
        activePreflightID.get()?.let { ids.add(it) }
        if (preflightLease.get() != null) {
            (activePreflightID.get() ?: retainedPreflightID.get())?.let(ids::add)
        }
        ids.addAll(pendingShellStartIDs)
        ids.addAll(leaseStartIDs.values)
        for (owned in running.values) {
            if (!owned.finished.get()) ids.add(owned.startID)
        }
        for (deferred in deferredExports.values) ids.add(deferred.ownerStartID)
        return ids
    }
    override fun snapshot(request: RuntimeWire.Request): JSONObject? = when (request.operation) {
        "install.status" -> { fields(request.payload, emptySet()); JSONObject(progress.get().toString()) }
        "shell.poll" -> poll(request.payload)
        "workspace.exportStatus" -> exportStatus(request.payload)
        else -> null
    }

    override fun execute(request: RuntimeWire.Request, workspaceGrant: android.os.IBinder?, cancelled: () -> Boolean): JSONObject = when (request.operation) {
        "install.start" -> install(request, cancelled)
        "install.status" -> { fields(request.payload, emptySet()); JSONObject(progress.get().toString()) }
        "environment.list" -> { fields(request.payload, emptySet()); configure(); authority.list() }
        "shell.start" -> {
            // G07.3A: every in-flight start id is exposed for target-scoped
            // session-less cancellation; concurrent starts never share one.
            pendingShellStartIDs.add(request.id)
            try {
                start(request, checkNotNull(workspaceGrant), cancelled)
            } finally {
                pendingShellStartIDs.remove(request.id)
            }
        }
        "workspace.preflight" -> preflight(request, checkNotNull(workspaceGrant), cancelled)
        "shell.poll" -> poll(request.payload)
        "shell.input" -> input(request.payload)
        "shell.resize" -> resize(request.payload)
        // Bounded read-only guest file snapshot over the EXISTING runtime IPC.
        // Identity-bound (live session + project + generation) and never an
        // export path: nothing is written to Core, no terminal is closed and
        // the writable-export quiescence rules are untouched.
        "workspace.files.tree", "workspace.files.read" -> liveFiles(request)
        "workspace.exportStatus" -> exportStatus(request.payload)
        // G03-R3: the scoped runtime-UID workspace-copy wipe. The receiver
        // returns a TYPED cleared/refused result (never throws for a refusal
        // — an honest retention keeps the Core obligation retryable).
        "runtimeWorkspaceCopies.clear" -> workspaceCleanup.execute(request)
        else -> throw IllegalArgumentException("Unknown runtime operation")
    }

    private fun install(request: RuntimeWire.Request, cancelled: () -> Boolean): JSONObject {
        fields(request.payload, emptySet())
        check(heldLeases.isEmpty() && preflightLease.get() == null)
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
        check(running.isEmpty() && heldLeases.isEmpty() && installID.get() == null) { "preflightBusy" }
        check(activePreflightID.compareAndSet(null, request.id)) { "preflightBusy" }
        preflightCancelled.set(false)
        try {
            return RuntimeWorkspacePreflight.execute(
                PreflightHarness(
                    acquire = authority::acquire,
                    abandon = authority::abandonUnstarted,
                    snapshot = census::snapshot,
                    ensureConfigured = { recover(); configure() },
                    ownedPath = ::ownedPath,
                    heldLease = preflightLease,
                    installID = installID,
                    openWorkspace = { projectID, runID, workspace ->
                        val session = RuntimeWorkspaceSession(context, grant, projectID, runID, workspace)
                        PreflightWorkspace(
                            importBeforeLaunch = { cancel -> session.importBeforeLaunch(cancel) },
                            exportAfterQuiescence = { cancel ->
                                session.exportAfterQuiescence(cancel, faithfulMirror = true)
                            },
                            close = { session.close() },
                        )
                    },
                    // SAME authority instance/directory as the live start
                    // lane; the previous default silently used a SECOND
                    // File(context.filesDir, "Prepare") root, so invalidation
                    // and preflight receipts could never agree.
                    preparation = preparation,
                ),
                request.payload) { cancelled() || preflightCancelled.get() }
        } finally {
            activePreflightID.compareAndSet(request.id, null)
            // A failed ORIGINAL release keeps the never-started lease; the
            // exact request id remains owned until that lease really clears.
            if (preflightLease.get() != null) retainedPreflightID.set(request.id)
        }
    }

    private fun start(request: RuntimeWire.Request, workspaceGrant: android.os.IBinder,
                      cancelled: () -> Boolean): JSONObject {
        val payload = request.payload
        RuntimeExecutionTrace.mark(Stage.OPS_START_ENTER)
        // G07.1 terminal04: the runtime half of this start's composition.
        val latency = LinuxRuntimePhaseTiming.begin()
        fields(payload, setOf("projectID", "runID", "conversationID", "environmentID", "command", "cwd",
            "env", "rows", "columns", "timeoutSeconds", "stdinDelivery", "leaseRole", "workspaceReuse"))
        // G07.3A: a start may coexist with OTHER admitted workloads. The
        // exclusive lanes (install / first-use preflight) still fence it; the
        // destructive single-workload swap paths do not.
        check(installID.get() == null && activePreflightID.get() == null) { "runtimeBusy" }
        val role = WorkloadRole.fromWire(payload.optString("leaseRole", WorkloadRole.AGENT.wireName))
            ?: throw IllegalArgumentException("leaseRole invalid")
        synchronized(admissionBudget) {
            val live = running.values.filter { !it.finished.get() }
            require(live.count { it.role == role } < role.maximumConcurrent) {
                "workloadCapacity:${role.wireName}"
            }
            if (role.isExecution) {
                // Agent and run share the ONE execution slot.
                require(live.count { it.role.isExecution } < 1) {
                    "workloadCapacity:execution"
                }
            }
            require(live.size < MAX_CONCURRENT_WORKLOADS) { "workloadCapacity:total" }
        }
        check(cancelledStarts.putIfAbsent(request.id, AtomicBoolean()) == null) { "duplicateStart" }
        fun isCancelled(): Boolean = canceled(cancelled) || cancelledStarts[request.id]?.get() == true
        val reuse = payload.optJSONObject("workspaceReuse")
        val projectID = payload.getString("projectID")
        val runID = payload.getString("runID")
        // A full-UID recovery sweep is only safe when nothing is live. With a
        // sibling workload already admitted, the supervisor's SCOPED admission
        // proof is the gate (it excludes only other owned jobs and never kills
        // an unattributable process while one is live).
        if (running.isEmpty()) {
            RuntimeExecutionTrace.mark(Stage.OPS_RECOVER)
            recover()
            latency.mark(LinuxRuntimePhaseTiming.Phase.RECOVER)
        }
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
        val stdinDelivery = payload.optString("stdinDelivery", "pty")
        require(stdinDelivery in setOf("pty", "pipe")) { "stdinDelivery invalid" }
        RuntimeExecutionTrace.mark(Stage.OPS_ACQUIRE)
        val lease = authority.acquire(payload)
        latency.mark(LinuxRuntimePhaseTiming.Phase.ACQUIRE)
        RuntimeExecutionTrace.mark(Stage.OPS_ACQUIRED)
        heldLeases[lease.id] = lease
        leaseStartIDs[lease.id] = request.id
        leaseRoles[lease.id] = role
        var child: Running? = null
        var preparedScratch: File? = null
        var preparedWorkspace: RuntimeWorkspaceSession? = null
        var safeToAbandon = true
        var startedOwner = false
        var registeredParticipant = false
        val terminal = AtomicReference<WorkloadTerminal?>()
        try {
            // A start and a global export never overlap. The lock is released
            // after this workload is registered (or the start fails).
            workspaceGate.lock()
            val descriptor = lease.descriptor
            val writable = ownedPath(descriptor.getString("writableLayer"))
            val layers = descriptor.getJSONArray("orderedLayers")
            val ordered = (0 until layers.length()).map { ownedPath(layers.getString(it)) }
            RuntimeExecutionTrace.mark(Stage.OPS_MATERIALIZE)
            // Validated base-revision reuse: the ORIGINAL materializer returns
            // `reused = true` only when the writable layer's own marker names
            // this exact environment AND base revision. The marker is written
            // after a complete, fsynced, atomic publication; a half-copied tree
            // never carries it. No writable hardlink is ever created across
            // tasks: the copier uses CREATE_NEW + full byte copies.
            val prepareStart = SystemClock.elapsedRealtime()
            val materialized = LinuxRootfsMaterializer().prepare(
                LinuxRootfsMaterializer.Plan(lease.environmentID, descriptor.getString("baseRevision"),
                    writable, ordered)) { isCancelled() }
            val prepareMillis = SystemClock.elapsedRealtime() - prepareStart
            latency.mark(LinuxRuntimePhaseTiming.Phase.MATERIALIZE)
            check(!isCancelled())
            RuntimeExecutionTrace.mark(Stage.OPS_MATERIALIZED)
            val workspace = ownedPath(descriptor.getString("workspaceRoot"))
            // ONE workspace owner per project imports/exports; participant
            // sessions must name a LIVE owner of the SAME project. A hint that
            // cannot be validated is refused, never silently treated as an
            // owner (which would re-import over live guest files).
            val requestedShared = reuse?.optString("mode") == "shared"
            val ownerLeaseID = workspaceOwners[projectID]
            var sharedOwner: Running? = null
            if (requestedShared) {
                val expectedOwner = reuse?.optString("ownerSessionID")?.takeIf { it.isNotEmpty() }
                sharedOwner = expectedOwner?.let { running[it] }
                    ?.takeIf { !it.finished.get() && it.workspaceOwner && it.projectID == projectID }
                // The owner may already have stopped while its deferred export
                // is still retained; existing live participants keep the same
                // guest workspace addressable.
                // The owner may already have stopped while its deferred export
                // is retained; the shared guest tree is still the live truth.
                val deferredLive = deferredExports.containsKey(projectID)
                require(sharedOwner != null || deferredLive) { "workspaceOwnerUnavailable" }
            } else if (ownerLeaseID != null) {
                sharedOwner = running[ownerLeaseID]
                    ?.takeIf { !it.finished.get() && it.workspaceOwner && it.projectID == projectID }
                if (sharedOwner == null && deferredExports.containsKey(projectID)) {
                    // The owner stopped while participants remained: this session
                    // joins the same deferred workspace, not a new import.
                    sharedOwner = null
                }
            }
            val isReuseParticipant = when {
                requestedShared -> true
                sharedOwner != null -> true
                // A retained deferred export means the guest tree is still the
                // live truth: a new session joins it (never a fresh import),
                // even when the owner already stopped and no same-project
                // participant remains. The last global session exports it.
                else -> deferredExports.containsKey(projectID)
            }
            var workspaceSession: RuntimeWorkspaceSession? = null
            var imported: WorkspaceImportReceipt? = null
            var importMillis = 0L
            var importedEntries = 0L
            if (!isReuseParticipant) {
                // An owner start begins a new live workspace epoch. Any
                // earlier preparation receipt can no longer prove the guest
                // tree is unchanged, so it is invalidated BEFORE the import.
                preparation.invalidate(projectID)
                // A previous generation's export status must not be served to
                // this new live generation.
                exportStatuses.remove(projectID)
                val session = RuntimeWorkspaceSession(context, workspaceGrant, projectID, runID, workspace)
                workspaceSession = session
                preparedWorkspace = session
                RuntimeExecutionTrace.mark(Stage.OPS_IMPORT)
                val importStart = SystemClock.elapsedRealtime()
                val receipt = session.importBeforeLaunch(WorkspaceCancelSignal { isCancelled() })
                importMillis = SystemClock.elapsedRealtime() - importStart
                latency.mark(LinuxRuntimePhaseTiming.Phase.IMPORT)
                RuntimeExecutionTrace.mark(Stage.OPS_IMPORTED)
                check(receipt.skippedCount == 0) { "Workspace snapshot contains unsupported entries" }
                imported = receipt
                importedEntries = (receipt.createdCount + receipt.replacedSyncedCount +
                    receipt.preservedUnsyncedCount + receipt.unchangedCount).toLong()
                check(!isCancelled())
            } else {
                latency.mark(LinuxRuntimePhaseTiming.Phase.IMPORT)
            }
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
            when (val outcome = supervisor.start(
                spec, LeaseToken(lease.id, descriptor.getString("runID")),
                onTerminal = { terminal.set(it) },
                admission = WorkloadAdmission.concurrent,
            )) {
                is StartOutcome.Refused -> error("Linux process was not admitted")
                is StartOutcome.Abandoned -> {
                    safeToAbandon = outcome.terminal.quiescence == null || outcome.terminal.quiescence is Quiescence.Proven
                    error("Linux process launch failed")
                }
                is StartOutcome.Accepted -> {
                    latency.mark(LinuxRuntimePhaseTiming.Phase.SPAWN)
                    RuntimeExecutionTrace.mark(Stage.OPS_SPAWN_ACCEPTED)
                    safeToAbandon = false
                    val isOwner = !isReuseParticipant
                    // Hand the START's OWN cancellation token to the Running;
                    // the map entry is removed only by this start's finally,
                    // after Running is published. A target stop that lands in
                    // that handoff window therefore cannot be lost.
                    val startCancellation = checkNotNull(cancelledStarts[request.id]) {
                        "startCancellationMissing"
                    }
                    val owned = Running(lease, outcome.job, SystemClock.elapsedRealtime() + (seconds * 1000).toLong(),
                        scratch, role, projectID, workspace, isOwner, workspaceSession, imported,
                        request.id, startCancellation, latency)
                    owned.startCancelled.set(isCancelled())
                    child = owned
                    if (isOwner) {
                        workspaceOwners[projectID] = lease.id
                        startedOwner = true
                    } else {
                        workspaceParticipants.getOrPut(projectID) { java.util.concurrent.ConcurrentHashMap.newKeySet() }
                            .add(lease.id)
                        registeredParticipant = true
                    }
                    running[lease.id] = owned
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
                                if (isStartCancelled(owned) || canceled(cancelled)) owned.job.requestCancel("user-stop")
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
                        reconcileUntilReleased(owned, terminal)
                    }
                    return JSONObject().put("sessionID", lease.id).put("environmentID", lease.environmentID)
                        .put("runtimeGeneration", RuntimeProcessIdentity.bootToken)
                        .put("leaseRole", role.wireName)
                        .put("workspaceOwner", isOwner)
                        .put("prepareReused", materialized.reused)
                        .put("prepareMillis", prepareMillis)
                        .put("prepareCopiedBytes", materialized.copiedBytes)
                        .put("importMillis", importMillis)
                        .put("importedEntries", importedEntries)
                }
            }
        } catch (failure: Exception) {
            RuntimeExecutionTrace.mark(Stage.OPS_START_EXCEPTION)
            latency.publish(
                if (safeToAbandon) LinuxRuntimePhaseTiming.TERMINAL_FAILED
                else LinuxRuntimePhaseTiming.TERMINAL_RETAINED)
            if (safeToAbandon) {
                runCatching { preparedWorkspace?.close() }
                preparedScratch?.let { RuntimeNetworkConfiguration.release(it) }
                // The native abandon reply is the ONLY ack that settles this
                // never-started lease. A failed abandon retains the exact
                // held lease/start/role maps (and any owner/participant
                // registration) so a later foreground-permit loss is not
                // misread as an already-settled participant. The original
                // start failure is still the exception rethrown below.
                val abandonAcknowledged = runCatching { authority.abandonUnstarted(lease) }.isSuccess
                val cleanup = startAbandonCleanup(
                    abandonAcknowledged = abandonAcknowledged,
                    startedOwner = startedOwner,
                    registeredParticipant = registeredParticipant,
                )
                if (cleanup.removeHeldLease) heldLeases.remove(lease.id)
                if (cleanup.removeLeaseStart) leaseStartIDs.remove(lease.id)
                if (cleanup.removeLeaseRole) leaseRoles.remove(lease.id)
                if (cleanup.removeWorkspaceOwner) workspaceOwners.remove(projectID, lease.id)
                if (cleanup.removeParticipant) workspaceParticipants[projectID]?.remove(lease.id)
                preparedScratch?.let { cleanupScratch(it, lease.id) }
            } else child?.let { owned ->
                owned.startCancelled.set(true)
                val stopped = runCatching { owned.job.requestCancel("start-binding-failed") }.getOrNull()
                if (stopped is CancelOutcome.Terminated) owned.terminal.set(stopped.terminal)
                reconcileUntilReleased(owned, terminal)
            }
            throw failure
        } finally {
            cancelledStarts.remove(request.id)
            if (workspaceGate.isHeldByCurrentThread) workspaceGate.unlock()
        }
    }

    /** Per-session cancellation flag; a global stop uses the kernel's fence. */
    private fun isStartCancelled(owned: Running): Boolean = owned.startCancelled.get()

    /** A cancellation source that covers the global install/preflight flag. */
    private fun canceled(cancelled: () -> Boolean): Boolean = cancelPreparation.get() || cancelled()

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
            // The ORIGINAL writable-export boundary is actual whole-runtime-UID
            // quiescence. While ANY sibling owned workload is live, every
            // owner close defers; the LAST global workload proves quiescence
            // and services every retained obligation (all projects) with the
            // exact owner's grant/import baseline. The gate keeps a new start
            // out of the UID between that proof and those exports.
            workspaceGate.lock()
            try {
                if (owned.workspaceResult == null) {
                    val othersLive = running.entries.any {
                        it.key != owned.lease.id && !it.value.finished.get()
                    }
                    if (othersLive) {
                        if (owned.workspaceOwner) {
                            deferredExports[owned.projectID] = DeferredExport(
                                projectID = owned.projectID,
                                environmentID = owned.lease.environmentID,
                                baseRevision = owned.lease.descriptor.optString("baseRevision"),
                                workspaceRoot = owned.workspaceRoot,
                                workspace = checkNotNull(owned.workspace),
                                imported = checkNotNull(owned.imported),
                                ownerStartID = owned.startID,
                            )
                            preparation.invalidate(owned.projectID)
                        }
                        owned.workspaceResult = deferredResult(owned.projectID)
                    } else {
                        // Remove self FIRST so the global proof sees no live
                        // owned job; the whole-UID census then proves the exact
                        // ORIGINAL export boundary (and may reap strays).
                        running.remove(owned.lease.id, owned)
                        val globalProof = supervisor.globalQuiescence("workspace-export")
                        if (globalProof is Quiescence.Proven) {
                            if (owned.workspaceOwner) {
                                owned.workspaceResult = exportWorkspace(
                                    projectID = owned.projectID,
                                    environmentID = owned.lease.environmentID,
                                    baseRevision = owned.lease.descriptor.optString("baseRevision"),
                                    workspaceRoot = owned.workspaceRoot,
                                    workspace = checkNotNull(owned.workspace),
                                    imported = checkNotNull(owned.imported),
                                )
                            } else {
                                owned.workspaceResult = deferredResult(owned.projectID)
                            }
                            serviceDeferredExports(owned)
                        } else {
                            // Never export without the real whole-UID proof.
                            // There is no later workload to retry, so the
                            // obligation is reported unknown and closed, never
                            // a fake synced/deferred success.
                            if (owned.workspaceOwner) {
                                runCatching { owned.workspace?.close() }
                                owned.workspaceResult = JSONObject()
                                    .put("workspaceStatus", "unknown")
                                    .put("workspaceKey", owned.projectID)
                            }
                            failDeferredExports(owned)
                        }
                    }
                }
            } finally {
                workspaceGate.unlock()
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
            // The authority hand-back is real: release the supervisor's
            // transient job entry (the deferred workspace obligation, if any,
            // lives in `deferredExports`, not in the process table).
            runCatching { supervisor.retireSettled(owned.job.lease) }
            // Native completion is authoritative. A later scratch-cleanup
            // failure must not turn a released lease into a fabricated live one.
            owned.nativeReleaseFailed = false
            owned.finished.set(true)
            completed[owned.lease.id] = owned
            while (completed.size > 32) completed.keys.firstOrNull()?.let { completed.remove(it) }
            running.remove(owned.lease.id, owned)
            heldLeases.remove(owned.lease.id)
            leaseStartIDs.remove(owned.lease.id)
            leaseRoles.remove(owned.lease.id)
            if (owned.workspaceOwner) {
                workspaceOwners.remove(owned.projectID, owned.lease.id)
            } else {
                workspaceParticipants[owned.projectID]?.remove(owned.lease.id)
            }
            // Keep the participant set entry while a deferred export still
            // exists: the last participant is identified from it.
            val participants = workspaceParticipants[owned.projectID]
            if (participants != null && participants.isEmpty() && !deferredExports.containsKey(owned.projectID)) {
                workspaceParticipants.remove(owned.projectID)
            }
            RuntimeNetworkConfiguration.release(owned.scratch) // this session's resolver use ended
            owned.cleanupDeferred = !cleanupScratch(owned.scratch, owned.lease.id)
            // G03-R3 first-start admission repair: notify the kernel that the
            // REAL owned-work release landed. The fence re-checks ownership,
            // so a sibling still live keeps it raised.
            runCatching { onOwnedWorkReleased() }
            // Published exactly once, after the REAL release path succeeded.
            owned.latency.publish(
                if (terminal is WorkloadTerminal.Cancelled) LinuxRuntimePhaseTiming.TERMINAL_CANCELLED
                else LinuxRuntimePhaseTiming.TERMINAL_EXITED)
        }
    }

    private fun deferredResult(projectID: String): JSONObject =
        JSONObject().put("workspaceStatus", "deferred").put("workspaceKey", projectID)

    /**
     * Exports ONE exact owner's workspace after the caller has proven the
     * real whole-runtime-UID quiescence. Records the actual outcome/status and
     * the validated preparation receipt; closes the Core grant session.
     */
    private fun exportWorkspace(
        projectID: String,
        environmentID: String,
        baseRevision: String,
        workspaceRoot: java.io.File,
        workspace: RuntimeWorkspaceSession,
        imported: WorkspaceImportReceipt,
    ): JSONObject {
        val outcome = try {
            workspace.exportAfterQuiescence(WorkspaceCancelSignal {
                Thread.currentThread().isInterrupted
            })
        } catch (_: Exception) {
            WorkspaceExportOutcome.RecoverableFailure("exportUnknown", true, imported.sessionKey)
        }
        val result = workspaceResult(outcome, imported).put("workspaceKey", projectID)
        runCatching { workspace.close() }
        val status = result.optString("workspaceStatus")
        if (status == "synced") {
            preparation.record(projectID, environmentID, baseRevision, workspaceRoot, 0L, 0L)
        } else {
            preparation.invalidate(projectID)
        }
        exportStatuses[projectID] = result
        return result
    }

    /** Services EVERY retained deferred export after global quiescence. */
    private fun serviceDeferredExports(current: Running) {
        for (deferred in deferredExports.values.toList()) {
            val result = exportWorkspace(
                projectID = deferred.projectID,
                environmentID = deferred.environmentID,
                baseRevision = deferred.baseRevision,
                workspaceRoot = deferred.workspaceRoot,
                workspace = deferred.workspace,
                imported = deferred.imported,
            )
            if (deferred.projectID == current.projectID) current.workspaceResult = result
            deferredExports.remove(deferred.projectID)
        }
    }

    /** No whole-UID proof: every obligation is honestly unknown, never saved. */
    private fun failDeferredExports(current: Running) {
        for (deferred in deferredExports.values.toList()) {
            val result = JSONObject().put("workspaceStatus", "unknown")
                .put("workspaceKey", deferred.projectID)
            runCatching { deferred.workspace.close() }
            exportStatuses[deferred.projectID] = result
            if (deferred.projectID == current.projectID) current.workspaceResult = result
            deferredExports.remove(deferred.projectID)
        }
    }

    /**
     * Read-only live guest file snapshot over the EXISTING runtime IPC.
     * Every identity clause is re-proven on THIS call: the addressed session
     * must still be live, belong to the exact project and environment, and
     * carry the caller's runtime-generation token. A stale/foreign address is
     * refused before any path is touched. The root is the live session's own
     * canonical workspace; no caller path selects it.
     */
    private fun liveFiles(request: RuntimeWire.Request): JSONObject {
        val payload = request.payload
        fields(payload, setOf("sessionID", "workspaceKey", "environmentID", "generation",
            "relativePath", "maxEntries", "maxDepth", "recursive", "offset", "maxBytes"))
        val sessionID = payload.getString("sessionID")
        val owned = running[sessionID] ?: return liveFilesRefusal("staleSession")
        if (payload.getString("workspaceKey") != owned.projectID) {
            return liveFilesRefusal("pathOutOfScope")
        }
        if (payload.getString("environmentID") != owned.lease.environmentID) {
            return liveFilesRefusal("environmentMismatch")
        }
        if (payload.getString("generation") != RuntimeProcessIdentity.bootToken) {
            return liveFilesRefusal("staleGeneration")
        }
        if (owned.finished.get() || owned.terminal.get() != null) return liveFilesRefusal("staleSession")
        return if (request.operation == "workspace.files.tree") {
            liveFiles.tree(owned.workspaceRoot, payload)
        } else {
            liveFiles.read(owned.workspaceRoot, payload)
        }
    }

    private fun liveFilesRefusal(code: String): JSONObject =
        JSONObject().put("state", "refused").put("code", code)

    /** Recompute the authoritative export outcome for status reads. */
    private fun exportStatus(payload: JSONObject): JSONObject {
        fields(payload, setOf("workspaceKey"))
        val key = payload.getString("workspaceKey")
        return exportStatuses[key]?.let { JSONObject(it.toString()) }
            ?: JSONObject().put("workspaceStatus", if (deferredExports.containsKey(key)) "pending" else "unknown")
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
        return running[id] ?: completed[id] ?: error("Unknown Linux session")
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
                result.put("workspaceStatus", files.optString("workspaceStatus", "unknown"))
                if (files.has("workspaceKey")) result.put("workspaceKey", files.getString("workspaceKey"))
                result.put("workspaceOwner", owned.workspaceOwner)
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
        if (running[owned.lease.id] !== owned) {
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
        check(running[owned.lease.id] === owned)
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
        check(running[owned.lease.id] === owned)
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
            // Exactly TWO target-scoped shell.cancel grammars:
            //  * started session: {sessionID} must name an ACTUAL live lease
            //    (never another session's id, never a completed one);
            //  * pending start: {requestID} must name this service's own
            //    in-flight shell.start wire id.
            // Any other shape or identity mismatch refuses. A stop for one
            // session can never address another.
            val scope = shellCancelScope(
                keys = request.payload.keys().asSequence().toSet(),
                sessionID = request.payload.optString("sessionID").takeIf { it.isNotEmpty() },
                requestID = request.payload.optString("requestID").takeIf { it.isNotEmpty() },
                heldLeaseIDs = heldLeases.keys.toSet(),
                pendingStartIDs = pendingShellStartIDs.toSet(),
            )
            require(scope != null) { "Cancellation does not address owned work" }
        }
    }

    /**
     * ORIGINAL global / target-scoped stop receiver. The scope is resolved
     * from the CURRENT lifecycle facts at execution time, never from the
     * admission-time validation alone: a target that settled while queued is
     * a NO-OP, and it must never fall through to every held lease.
     */
    override fun stopOwnedWork(request: RuntimeWire.Request?) {
        val resolution = if (request == null) {
            StopResolution(StopTarget.ALL)
        } else {
            resolveStop(
                operation = request.operation,
                keys = request.payload.keys().asSequence().toSet(),
                requestID = request.payload.optString("requestID").takeIf { it.isNotEmpty() },
                sessionID = request.payload.optString("sessionID").takeIf { it.isNotEmpty() },
                installID = installID.get(),
                preflightID = activePreflightID.get(),
                heldLeaseIDs = heldLeases.keys,
                pendingStartIDs = cancelledStarts.keys,
                runningStartIDs = running.values.map { it.startID },
            )
        }
        when (resolution.target) {
            StopTarget.NONE -> Unit
            StopTarget.ALL -> {
                // A preflight has NO process: authority.cancel (the started-
                // lease path) does not apply. Flag the owning thread; it
                // performs the real recoverable abort and the no-children
                // lease release itself. (ORIGINAL global rule.)
                if (activePreflightID.get() != null) {
                    preflightCancelled.set(true)
                    return
                }
                val targets = running.values.toList()
                if (targets.isEmpty()) {
                    // Preparation or failed-spawn ownership still counts as
                    // real work. A stop request only cancels its token; it
                    // never invents an exit. This is the ONLY path that may
                    // touch every held lease, and ONLY for a genuine global
                    // stop (null request).
                    heldLeases.values.forEach { runCatching { authority.cancel(it) } }
                    return
                }
                // One failing target must not suppress the other exact
                // targets of a genuine global stop.
                targets.forEach { runCatching { cancelOwned(it) } }
            }
            StopTarget.INSTALL -> cancelPreparation.set(true)
            StopTarget.PREFLIGHT -> preflightCancelled.set(true)
            StopTarget.PENDING_START -> {
                // Session-less start cancellation: arm its OWN shared token
                // (covers a start before Running) and stop the exact published
                // start if it already exists. A settled/foreign id is a no-op.
                val target = checkNotNull(resolution.id)
                cancelledStarts[target]?.set(true)
                running.values.firstOrNull { it.startID == target && !it.finished.get() }
                    ?.let { runCatching { cancelOwned(it) } }
            }
            StopTarget.SESSION -> {
                val target = checkNotNull(resolution.id)
                running[target]?.let { runCatching { cancelOwned(it) } }
                    ?: heldLeases[target]?.let { lease ->
                        // Exact held lease (pre-Running/finish window): arm
                        // only ITS start token, then cancel only THIS lease.
                        leaseStartIDs[target]?.let { cancelledStarts[it]?.set(true) }
                        runCatching { authority.cancel(lease) }
                    }
            }
        }
    }

    /** Real stop + the designed completion retry for exactly this workload. */
    private fun cancelOwned(owned: Running) {
        owned.startCancelled.set(true)
        authority.cancel(owned.lease)
        val cancelled = supervisor.cancelActive(owned.job.lease, "user-stop")
        if (cancelled is CancelOutcome.Terminated) {
            owned.terminal.set(cancelled.terminal)
            finish(owned)
        } else if (cancelled is CancelOutcome.Rejected && owned.job.stateNow == JobState.TERMINATED) {
            // The job already reached its REAL terminal but an earlier
            // release attempt failed; retry only the designed completion.
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
        while (!owned.finished.get() && (running[owned.lease.id] === owned || owned.terminal.get() != null)) {
            val action = nextReconcileAction(
                state = owned.job.stateNow,
                finished = owned.finished.get(),
                terminalPresent = owned.terminal.get() != null || terminal.get() != null,
                deadlinePassed = SystemClock.elapsedRealtime() >= owned.deadline,
                stopRequested = owned.startCancelled.get(),
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

    /** Exact execution-time stop scope. */
    internal enum class StopTarget { NONE, ALL, INSTALL, PREFLIGHT, PENDING_START, SESSION }

    internal data class StopResolution(val target: StopTarget, val id: String? = null)

    /**
     * Exact ownership-map cleanup for the safe-to-abandon start path.
     * A failed/native-unacknowledged abandon is NOT settlement: every map
     * stays retained so the foreground permit association and the original
     * failure/recovery path keep the exact owned lease.
     */
    internal data class StartAbandonCleanup(
        val removeHeldLease: Boolean,
        val removeLeaseStart: Boolean,
        val removeLeaseRole: Boolean,
        val removeWorkspaceOwner: Boolean,
        val removeParticipant: Boolean,
    )

    companion object {
        /** Hard ceiling: 2 interactive + ONE shared Agent/run execution slot. */
        const val MAX_CONCURRENT_WORKLOADS = 3

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
            heldLeaseIDs: Collection<String>,
            pendingStartIDs: Collection<String>,
        ): String? = when {
            keys == setOf("sessionID") ->
                if (sessionID != null && heldLeaseIDs.contains(sessionID)) "session" else null
            keys == setOf("requestID") ->
                if (requestID != null && pendingStartIDs.contains(requestID)) "pendingStart" else null
            else -> null
        }

        /** Legacy single-lease shape retained for the authored older tests. */
        internal fun shellCancelScope(
            keys: Set<String>,
            sessionID: String?,
            requestID: String?,
            heldLeaseID: String?,
            pendingStartID: String?,
        ): String? = shellCancelScope(
            keys = keys,
            sessionID = sessionID,
            requestID = requestID,
            heldLeaseIDs = listOfNotNull(heldLeaseID),
            pendingStartIDs = listOfNotNull(pendingStartID),
        )

        /**
         * Pure safe-to-abandon ownership decision (no Android, no org.json).
         * The ORIGINAL native `abandonUnstarted` reply is the ONLY settlement
         * of this never-started lease. A thrown/failed abandon keeps the
         * held lease, its exact start id and its role (and any owner /
         * participant registration) retained; it must never be reported as
         * settled merely because the start itself failed.
         */
        internal fun startAbandonCleanup(
            abandonAcknowledged: Boolean,
            startedOwner: Boolean,
            registeredParticipant: Boolean,
        ): StartAbandonCleanup =
            if (!abandonAcknowledged) {
                StartAbandonCleanup(
                    removeHeldLease = false,
                    removeLeaseStart = false,
                    removeLeaseRole = false,
                    removeWorkspaceOwner = false,
                    removeParticipant = false,
                )
            } else {
                StartAbandonCleanup(
                    removeHeldLease = true,
                    removeLeaseStart = true,
                    removeLeaseRole = true,
                    removeWorkspaceOwner = startedOwner,
                    removeParticipant = registeredParticipant,
                )
            }

        /**
         * Pure EXECUTION-TIME stop resolution (no Android, no org.json). The
         * admission-time validation is deliberately NOT repeated here: a
         * target may settle while the bounded stop task is queued, and the
         * correct answer then is [StopTarget.NONE] — never a broad cancel of
         * other held leases. Only a null request is [StopTarget.ALL].
         *
         * A started session is addressed by its live lease id; a pending or
         * already-published start is addressed by the exact `shell.start`
         * request id (the same id the kernel/service ownership seam uses).
         * Install/preflight cancellations are exact request-id matches,
         * including a mismatch/absent owner -> NONE.
         */
        internal fun resolveStop(
            operation: String?,
            keys: Set<String>,
            requestID: String?,
            sessionID: String?,
            installID: String?,
            preflightID: String?,
            heldLeaseIDs: Collection<String>,
            pendingStartIDs: Collection<String>,
            runningStartIDs: Collection<String>,
        ): StopResolution {
            if (operation == null) return StopResolution(StopTarget.ALL)
            return when (operation) {
                "install.cancel" ->
                    if (keys == setOf("requestID") && requestID != null && requestID == installID) {
                        StopResolution(StopTarget.INSTALL, requestID)
                    } else StopResolution(StopTarget.NONE)
                RuntimeWire.PREFLIGHT_CANCEL ->
                    if (keys == setOf("requestID") && requestID != null && requestID == preflightID) {
                        StopResolution(StopTarget.PREFLIGHT, requestID)
                    } else StopResolution(StopTarget.NONE)
                "shell.cancel" -> when {
                    keys == setOf("sessionID") && sessionID != null &&
                        sessionID in heldLeaseIDs ->
                        StopResolution(StopTarget.SESSION, sessionID)
                    keys == setOf("requestID") && requestID != null &&
                        (requestID in pendingStartIDs || requestID in runningStartIDs) ->
                        StopResolution(StopTarget.PENDING_START, requestID)
                    else -> StopResolution(StopTarget.NONE)
                }
                else -> StopResolution(StopTarget.NONE)
            }
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
