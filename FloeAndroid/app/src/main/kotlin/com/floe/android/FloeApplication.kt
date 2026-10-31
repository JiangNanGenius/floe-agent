// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.app.Application
import com.floe.android.host.RuntimeHost
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.withLock

/**
 * Application owner for the product-UID credential gateway, the RB-1 native
 * runtime bootstrap lifecycle AND (from the G02 App host binding) the
 * Application-owned [RuntimeHost] that wires the provider/conversation/
 * integrations/settings components to the shared runtime.
 *
 * GWS-1 repair (gateway, preserved verbatim): AOSP constructs Application
 * with `super(null)` and attaches the base context later. A property
 * initializer that reads `context.applicationContext` (or constructs the
 * context-dependent dispatcher) can therefore dereference an uninitialized
 * ContextWrapper base. No property initializer reads Context; the capability
 * owner and the context-dependent dispatcher are created in onCreate after
 * attach.
 *
 * UI-thread rules (rev4 startup + RB-1 runtime bootstrap + G02 host binding):
 *  * no native library load, JNI, Keystore/store construction or file I/O on
 *    the main thread;
 *  * the context-dependent dispatcher is created in onCreate AFTER
 *    super.onCreate(), i.e. at an attached lifecycle boundary;
 *  * onCreate publishes Loading and launches the off-main bootstrap;
 *  * the runtime bootstrap coordinator is data-only here: it waits for the
 *    REAL gateway Ready + readback off-main before touching any native
 *    runtime seam, and owns no disk/Keystore work itself;
 *  * the G02 [RuntimeHost] is created data-only in onCreate and STARTED
 *    only from the off-main observer when the owned store is actually
 *    ready — it performs no native/disk work at creation and outlives every
 *    Activity/Composition;
 *  * no Activity/Composition lifecycle owns registration or the watchdog;
 *  * onTerminate is never used as a shutdown/cleanup signal.
 */
class FloeApplication : Application() {
    // Lazy access occurs only from the ready main-process network destination.
    internal val diagnosticReports by lazy {
        com.floe.android.host.network.NetworkDiagnosticReportController(this)
    }
    internal lateinit var officePreviews: com.floe.android.host.OfficePreviewController
        private set
    /** D04 owned run-output consumer lane (Application-owned like the
     * Office preview controller; isolated/office processes never create it —
     * both early returns above run first). */
    internal var runOutputs: com.floe.android.host.output.RunOutputHostService? = null
        private set
    /** Lane 17: App-owned OPEN consumer for verified durable run-output PDFs
     * (staged proof -> owner-fenced non-exported preview -> the SAME isolated
     * renderer + system print seam). Main-process only, like [runOutputs];
     * it owns no credential/runtime state and never runs in the isolated
     * PDF or Office processes. */
    internal var runOutputPdf: com.floe.android.host.output.RunOutputPdfPreviewController? = null
        private set
    lateinit var linuxSetup: com.floe.android.host.linux.LocalRuntimeSetupHost
        private set
    private lateinit var linuxShell: com.floe.android.host.linux.LinuxShellPump
    private lateinit var workspaceSources: com.floe.android.host.WorkspaceSourcePump
    private lateinit var workspaceSourceHost: com.floe.android.host.WorkspaceSourceHostController
    private lateinit var networkWorkspaceHost: com.floe.android.host.NetworkWorkspaceHostController
    private lateinit var workspaceGitTrust: com.floe.android.host.G04GitTrustController
    private lateinit var workspaceTerminal: com.floe.android.host.G04TerminalHostController
    /** Application-owned, lazy Notes authority adapter; ordinary chat never opens the library. */
    internal lateinit var notesHost: com.floe.android.host.notes.NotesHostController
        private set
    internal val notesPdfPasswords = com.floe.android.notesplatform.NotesPdfPasswordPromptBroker {
        (runtimeHost?.nativeRootEpoch() ?: 0L) > 0L && isActivityInForeground()
    }
    internal fun cancelNotesPasswordPrompt() = notesPdfPasswords.cancelPending()

    @Volatile
    internal var notesOcrHost: com.floe.android.host.notesocr.NotesOcrHost? = null
        private set

    private val notesLifecycleMutex = kotlinx.coroutines.sync.Mutex()
    @Volatile private var notesStopping = false
    private var notesAcceptedEpoch = 0L
    private val notesPlatformLock = Any()
    private var notesPlatformJob: kotlinx.coroutines.Job? = null
    private val notesPlatformState = MutableStateFlow<NotesPlatformLoadState>(NotesPlatformLoadState.Idle)
    internal val notesPlatform: StateFlow<NotesPlatformLoadState> = notesPlatformState

    /** App lifetime, lazy on first Notes use; no native store or Linux bootstrap here. */
    internal fun ensureNotesPlatform() {
        val pending = synchronized(notesPlatformLock) {
            if (notesPlatformState.value is NotesPlatformLoadState.Ready || notesPlatformJob != null) return
            notesPlatformState.value = NotesPlatformLoadState.Loading
            hostScope.launch(Dispatchers.IO, start = kotlinx.coroutines.CoroutineStart.LAZY) {
                try {
                    notesLifecycleMutex.withLock {
                        if (notesStopping) {
                            notesPlatformState.value = NotesPlatformLoadState.Idle
                            return@withLock
                        }
                        val host = runtimeHost ?: error("notesHostUnavailable")
                        val workspaceImport = com.floe.android.notesplatform.NotesWorkspaceImportHost(host)
                        val platform = com.floe.android.notesplatform.createNotesPlatformHost(
                            this@FloeApplication, notesHost.service, hostScope,
                            passwordProvider = notesPdfPasswords,
                            workspaceImport = workspaceImport,
                        )
                        try {
                            platform.presentation.loadWorkspace()
                            val ocr = com.floe.android.host.notesocr.createNotesOcrHost(
                                service = notesHost.service,
                                media = platform.media,
                                transport = com.floe.android.host.notesocr.NotesOcrTransport {
                                    com.floe.android.host.notes.SwiftNotesTransport.exchange(it)
                                },
                                epochProvider = { runtimeHost?.nativeRootEpoch()?.takeIf { it > 0L } },
                            )
                            val assistant = com.floe.android.host.notesruntime.notesAssistantHost(
                                notesHost = notesHost,
                                commandClient = host.commandClient,
                                hostScope = hostScope,
                                epochProvider = { runtimeHost?.nativeRootEpoch()?.takeIf { it > 0L } ?: 0L },
                            )
                            // The real task-workspace file source is owned by
                            // the platform host above and participates in the
                            // same root-stop gate. The handle is read-only;
                            // the workspace file is never modified.
                            val ports = platform.hostPorts(assistant = assistant, indexing = ocr)
                            val session = com.floe.android.feature.notes.ui.state.createNotesWorkspaceSession(
                                notesHost.service, ports,
                            )
                            notesOcrHost = ocr
                            notesAcceptedEpoch = runtimeHost?.nativeRootEpoch() ?: 0L
                            notesPlatformState.value = NotesPlatformLoadState.Ready(
                                platform, NotesWorkspaceBinding(ports, session, assistant),
                            )
                        } catch (error: Throwable) {
                            platform.close()
                            throw error
                        }
                    }
                    // First initialization also discovers durable chat-copy recovery. It is
                    // outside the lock: the transfer target waits for Ready above.
                    if (notesPlatformState.value is NotesPlatformLoadState.Ready && !notesStopping) {
                        runtimeHost?.conversations?.notesChatTransfers?.resume()
                    }
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    if (notesPlatformState.value !is NotesPlatformLoadState.Ready) notesPlatformState.value = NotesPlatformLoadState.Idle
                    throw cancelled
                } catch (_: Throwable) {
                    // No note content, file paths or raw errors enter product copy/logs.
                    if (notesPlatformState.value !is NotesPlatformLoadState.Ready) {
                        notesPlatformState.value = NotesPlatformLoadState.Failed
                    }
                } finally {
                    synchronized(notesPlatformLock) { notesPlatformJob = null }
                }
            }.also { notesPlatformJob = it }
        }
        pending.start()
    }

    /** Shared with lazy construction: retirement cannot overtake a newly created editor. */
    private suspend fun prepareNotesForRootStop(): Boolean = notesLifecycleMutex.withLock {
        notesStopping = true
        val epoch = runtimeHost?.nativeRootEpoch() ?: 0L
        val ready = notesPlatformState.value as? NotesPlatformLoadState.Ready
        var canRetire = false
        try {
            val editorOK = kotlinx.coroutines.withContext(Dispatchers.Main.immediate) {
                ready?.workspace?.session?.prepareForRootStop()?.canRetire != false
            }
            if (!editorOK) return@withLock false
            if (epoch > 0L) {
                if (ready?.workspace?.assistant?.prepareForRootStop(epoch)?.canRetire == false) return@withLock false
                if (notesOcrHost?.prepareForRootStop(epoch)?.canRetire == false) return@withLock false
            }
            if (runtimeHost?.conversations?.notesChatTransfers?.prepareForRootStop(epoch)?.canRetire == false) {
                return@withLock false
            }
            if (ready?.host?.prepareForRootStop(epoch) == false) return@withLock false
            canRetire = true
            true
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            false
        } finally {
            if (!canRetire) {
                // A refused local drain keeps the SAME accepted root. Re-arm all
                // owners, including when a later gate or recovery fsync failed.
                kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + Dispatchers.IO) {
                    if (epoch > 0L && runtimeHost?.nativeRootEpoch() == epoch) {
                        runCatching { ready?.workspace?.assistant?.abortRootStop(epoch) }
                        runCatching { notesOcrHost?.abortRootStop(epoch) }
                        runCatching { ready?.host?.abortRootStop(epoch) }
                        runtimeHost?.conversations?.notesChatTransfers?.abortRootStop(epoch)
                    }
                    runCatching {
                        kotlinx.coroutines.withContext(Dispatchers.Main.immediate) {
                            ready?.workspace?.session?.abortRootStop()
                        }
                    }
                    notesStopping = false
                }
            }
        }
    }

    private suspend fun resumeNotesAfterRootChange(epoch: Long) = notesLifecycleMutex.withLock {
        if (notesAcceptedEpoch == epoch && !notesStopping) return@withLock
        if (runtimeHost?.nativeRootEpoch() != epoch) return@withLock
        val ready = notesPlatformState.value as? NotesPlatformLoadState.Ready
        ready?.host?.resumeAfterRootChange(epoch)
        ready?.workspace?.assistant?.resumeAfterRootChange(epoch)
        notesOcrHost?.resumeAfterRootChange(epoch)
        kotlinx.coroutines.withContext(Dispatchers.Main.immediate) {
            ready?.workspace?.session?.resumeAfterRootChange()
        }
        notesAcceptedEpoch = epoch
        notesStopping = false
        if (ready != null) runtimeHost?.conversations?.notesChatTransfers?.resume()
    }

    private fun cancelPendingNotesLaunches() {
        notesPdfPasswords.cancelPending()
        (notesPlatformState.value as? NotesPlatformLoadState.Ready)?.host?.cancelPendingLaunches()
    }

    // G03-R3: app-owned Core->runtime-UID workspace-copy cleanup pump. It is
    // bound at the SAME actual accepted native Root epoch as the shell pump
    // and stays serviceable while shell/model admission is fenced.
    private lateinit var linuxCleanup: com.floe.android.host.linux.LinuxRuntimeCleanupPump
    // G07.3B: ONE App-owned environment-authority reader for scheduled tasks.
    // The platform dispatch worker and the schedule UI share this exact
    // instance; it reads the authenticated runtime IPC environment.list
    // snapshot and never invents rows.
    private lateinit var scheduleEnvironments: com.floe.android.host.RuntimeScheduleEnvironmentProvider
    // R3 trusted-host readiness authority: binds the seven live facts to the
    // ACTUAL accepted native epoch; the shell pump consults it BEFORE any
    // first-use workspace preflight dispatch (never a boolean override).
    private lateinit var linuxReadiness: com.floe.android.host.linux.LinuxRuntimeReadinessController
    private var foregroundObservation: kotlinx.coroutines.Job? = null
    /** G03-R3: Application-owned observer of the EXISTING LocalRuntimeSetupHost
     *  state authority (verified install lifecycle). Event-driven only — the
     *  StateFlow itself is the callback source; no idle poller, no network,
     *  no FGS/wakelock/PiP/model work. Cancelled by the root stop observation
     *  like every other owned job, so late emissions cannot revive a stopped
     *  or replaced generation. */
    private var localRuntimeObservation: kotlinx.coroutines.Job? = null
    // Created in onCreate AFTER attach; no property initializer reads Context.
    private lateinit var gatewayCapability: MutableStateFlow<SecretGatewayCapability>

    /** Loading | Ready | Failed(reason); ready iff the gateway is registered. */
    val secretGatewayCapability: StateFlow<SecretGatewayCapability>
        get() = gatewayCapability

    // Created in onCreate AFTER attach; context-dependent work happens only
    // inside the coordinator's off-main bootstrap job.
    private lateinit var runtimeCapability: MutableStateFlow<RuntimeBootstrapCapability>

    /**
     * Idle | WaitingGateway | Starting(receipt) | OwnedStoreReady |
     * Failed(reason) | Stopped. Separate typed facts from the gateway flow:
     * gateway Ready does NOT mean the runtime store bootstrap is done.
     */
    val runtimeBootstrapCapability: StateFlow<RuntimeBootstrapCapability>
        get() = runtimeCapability

    @Suppress("unused")
    private lateinit var gatewayDispatcher: SecretGatewayDispatcher

    @Suppress("unused")
    private lateinit var runtimeCoordinator: RuntimeBootstrapCoordinator

    /**
     * The Application-owned G02 host binding. Created data-only in onCreate;
     * started off-main when the owned store is ready. Activities and
     * compositions observe it but never own it.
     */
    @Volatile
    var runtimeHost: RuntimeHost? = null
        private set

    private val hostScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onCreate() {
        super.onCreate()
        // Isolated PDF rendering receives only verified file descriptors;
        // it must never bootstrap the credential, store or Agent owners.
        if (android.os.Process.isIsolated()) return
        // The native Office module owns its own service and engine in this
        // same-UID process. Starting another credential/store/Core owner here
        // would duplicate the main process's lifecycle and database writers.
        // Its standalone components must not access main-host lateinit state.
        if (Application.getProcessName() == "$packageName:floe_office") return
        officePreviews = com.floe.android.host.OfficePreviewController(this, hostScope)
        runOutputs = com.floe.android.host.output.RunOutputHostService(
            this, hostScope,
            currentNativeEpoch = { runtimeHost?.nativeRootEpoch() },
        )
        // Composed from the App's OWNED run-output lane only (no global
        // singleton, no first-document fallback: every launch re-enters the
        // exact conversation/run/output receipt through the stager).
        runOutputPdf = com.floe.android.host.output.RunOutputPdfPreviewController(this, hostScope)
        linuxSetup = com.floe.android.host.linux.LocalRuntimeSetupHost(this, hostScope)
        linuxShell = com.floe.android.host.linux.LinuxShellPump(this, hostScope)
        workspaceSources = com.floe.android.host.WorkspaceSourcePump(this, hostScope) {
            runtimeHost?.nativeRootEpoch()
        }
        workspaceSourceHost = com.floe.android.host.WorkspaceSourceHostController(
            recoveryRoot = java.io.File(cacheDir, "WorkspaceSourceRecovery"),
            scope = hostScope,
            ioDispatcher = Dispatchers.IO,
            currentNativeEpoch = { runtimeHost?.nativeRootEpoch() },
            gatewayProvider = { runtimeHost?.workspaceSources?.gatewayForEpoch(it) },
            backendProvider = { runtimeHost?.workspaceSources?.backendForEpoch(it) },
        )
        networkWorkspaceHost = com.floe.android.host.NetworkWorkspaceHostController(
            scope = hostScope, ioDispatcher = Dispatchers.IO,
            currentNativeEpoch = { runtimeHost?.nativeRootEpoch() },
            localNetwork = { runtimeHost?.integrations?.localNetwork },
        )
        workspaceGitTrust = com.floe.android.host.G04GitTrustController(this) { runtimeHost?.nativeRootEpoch() }
        workspaceTerminal = com.floe.android.host.G04TerminalHostController(hostScope) { runtimeHost?.nativeRootEpoch() }
        // Construction is data-only. Binding and all Notes storage/JNI access occur off-main
        // on explicit Notes operations, without requiring a provider or Linux installation.
        notesHost = com.floe.android.host.notes.NotesHostController(
            epochProvider = { runtimeHost?.nativeRootEpoch()?.takeIf { it > 0L } },
        )
        linuxCleanup = com.floe.android.host.linux.LinuxRuntimeCleanupPump(this, hostScope)
        // The controller receives the APPLICATION-owned scope only to run
        // BOUNDED, cancellable re-ingress attempts triggered by REAL
        // lifecycle events (verified install completion, binder loss).
        linuxReadiness = com.floe.android.host.linux.LinuxRuntimeReadinessController(this, hostScope)
        linuxShell.readiness = linuxReadiness
        // Attached boundary: this is now safe to read applicationContext.
        // The capability flow itself is data-only and published as Loading
        // before the dispatcher's off-main bootstrap starts.
        val capability = MutableStateFlow<SecretGatewayCapability>(
            SecretGatewayCapability.Loading)
        gatewayCapability = capability
        val dispatcher = SecretGatewayDispatcher.create(this, capability)
        gatewayDispatcher = dispatcher
        dispatcher.start()
        // RB-1: runtime bootstrap coordination. create() performs no native
        // or disk work; start() only schedules off-main waiting.
        val runtimeState = MutableStateFlow<RuntimeBootstrapCapability>(
            RuntimeBootstrapCapability.Idle)
        runtimeCapability = runtimeState
        val runtimeCoordinator = RuntimeBootstrapCoordinator.create(
            this,
            gatewayCapability = capability,
            capabilityState = runtimeState,
        )
        this.runtimeCoordinator = runtimeCoordinator
        runtimeCoordinator.localRuntimeDrain = {
            cancelPendingNotesLaunches()
            // Retirement ordering (host contract): the shell/jobs mailbox is
            // drained FIRST so Core owned-work/CoreIO really settles, THEN
            // the cleanup pump services remaining runtime-UID wipe
            // obligations over the still-open signed channel. A retained
            // obligation keeps the drain retryable and never strands the
            // shutdown silently — the durable V36 retry + settlement trigger
            // remain the lifecycle authority.
            // Drain the actual queued UI edits before native Root admission
            // is fenced; a timeout/refused recovery retains the owner.
            (runtimeHost?.workspaceEditors?.prepareForRootStop() != false) &&
                (workspaceTerminal.boundNativeEpoch == 0L || workspaceTerminal.stopAndJoin(workspaceTerminal.boundNativeEpoch, 5_000)) &&
                linuxShell.stopAndDrain(linuxShell.boundNativeEpoch) &&
                (linuxCleanup.boundNativeEpoch == 0L ||
                    linuxCleanup.drainAndStop(linuxCleanup.boundNativeEpoch)) &&
                prepareNotesForRootStop() &&
                // G07.1: the full-window PDF/image preview holds a verified
                // native-root snapshot plus an isolated renderer lease. Its
                // real quiescent closure must precede Root retirement.
                (runtimeHost?.prepareWorkspaceDocumentPreviewForRootStop() != false) &&
                // G08: the Full platform-tool pump/phone/ADB/Root extension
                // fences and joins its own work before the root retires.
                (runtimeHost?.preparePlatformForRootStop() != false) &&
                // The network lane remains the LAST drain clause.
                (runtimeHost?.prepareNetworkForRootStop() != false)
        }
        runtimeCoordinator.start()
        // G02 App host binding: data-only creation; commands stay off-main.
        // The privacy-clear confirmation issuer stays with the coordinator
        // that owns the live accepted epoch + owner token; the host only
        // exposes the typed request, so the token never reaches UI/wire.
        runtimeHost = RuntimeHost.create(
            context = this,
            gatewayCapability = capability,
            bootstrapCapability = runtimeState,
        ).also { host ->
            host.workspaceSources = workspaceSources
            host.workspaceSourceHost = workspaceSourceHost
            host.networkWorkspaceHost = networkWorkspaceHost
            host.workspaceGitTrust = workspaceGitTrust
            host.workspaceTerminal = workspaceTerminal
            host.runOutputs = runOutputs
            host.runForeground = com.floe.android.host.RunForegroundBinding(
                controller = com.floe.android.runlifecycle.RunForegroundController.forApplication(this),
                nativeSnapshot = com.floe.android.host.RunForegroundNativeSnapshotSource {
                    com.floe.android.runlifecycle.RunForegroundWire.parse(
                        com.floe.android.bridge.RunForegroundNative.snapshot())
                },
                cancelAgentRun = { conversationID, runID ->
                    hostScope.launch(Dispatchers.IO) { host.conversations.cancelRunFromNotification(conversationID, runID) }
                    true
                },
                releaseLocalSession = { sessionID -> linuxShell.requestSessionStop(sessionID) },
                onUnavailable = { _, failure -> host.reportBackgroundUnavailable(failure) },
                onDiagnostic = { counts -> android.util.Log.i("FloeRunLedger", counts); Unit },
            )
            host.privacyConfirmationIssuer = { expectedEpoch, operation,
                                               digest, invocation, action ->
                runtimeCoordinator.issuePrivacyConfirmation(
                    expectedNativeEpoch = expectedEpoch,
                    operation = operation,
                    previewDigest = digest,
                    invocationID = invocation,
                    action = action,
                )
            }
            // G05-R3 office-approval107: the owned-Office viewer may ask
            // (read-only) whether its OWNING conversation holds a captured
            // pending approval, so an Ask-first approval stays reachable
            // without closing the owned document. The lookup answers ONLY
            // for the currently visible conversation's selected-run card;
            // it grants nothing and never touches the resolve path.
            officePreviews.setApprovalNoticeLookup(host.conversations) { taskID ->
                host.conversations.approvalNoticeFor(taskID)
            }
        }
        // G05-R3 Alpha14 (user requirement): GitHub full-channel App
        // self-update. Application-owned, data-only creation here; checks,
        // downloads and installs run in hostScope and never block startup.
        // The Play flavour object is an empty Noop (no download/install code).
        com.floe.android.host.update.AppUpdateFeature.attach(this, hostScope)
        // G07.3B scheduled tasks: data-only platform attach with the ONE
        // Application-owned environment authority reader. The coordinator
        // binds to the REAL host only after the owned store is ready, so no
        // worker, alarm or runtime connection is created here.
        scheduleEnvironments = com.floe.android.host.RuntimeScheduleEnvironmentProvider(
            context = this,
            currentNativeEpoch = { runtimeHost?.nativeRootEpoch() },
        )
        com.floe.android.schedule.TaskSchedulePlatform.attach(this, scheduleEnvironments)
        hostScope.launch(Dispatchers.Default) { observeBootstrap(runtimeState) }
    }

    /**
     * Start the host exactly once when the Swift owner commits the original
     * store bootstrap; mirror every later typed capability change into the
     * host's separated readiness facts.
     */
    private suspend fun observeBootstrap(
        state: MutableStateFlow<RuntimeBootstrapCapability>,
    ) {
        var started = false
        state.collect { capability ->
            runtimeHost?.onBootstrapCapability(capability)
            if (capability is RuntimeBootstrapCapability.OwnedStoreReady) {
                // G03-R3 lane binding (Main steer 2026-10-23): the Linux
                // lanes follow the ACCEPTED native root epoch for the whole
                // process life. A mid-session root generation replacement
                // (a later OwnedStoreReady with a DIFFERENT epoch) must not
                // leave the old mailbox binding fenced forever; the rebind
                // runs through each lane's own stop/drain contract and
                // fails closed when a drain is unproven.
                val firstStart = !started
                started = true
                if (firstStart) runtimeHost?.start()
                // Bind the schedule platform on the FIRST ready epoch AND on
                // every later root-generation replacement. bindHost is
                // idempotent for the same live host and performs a bounded
                // schedule.rearm; it starts no UI and no Agent run.
                runtimeHost?.let {
                    com.floe.android.schedule.TaskSchedulePlatform.bindHost(it)
                }
                kotlinx.coroutines.withContext(Dispatchers.IO) {
                    val epoch = runtimeHost?.nativeRootEpoch()
                    if (epoch != null && epoch > 0) {
                        // Provider IO is independent of installed Linux. Rebind
                        // only after the previous actual provider pump drained.
                        startWorkspaceSourceLane(epoch)
                        startBrowserLane(epoch)
                        runtimeHost?.workspaceActions?.scene(activityForeground)
                        startLinuxLanes(epoch)
                        resumeNotesAfterRootChange(epoch)
                    }
                }
                if (!firstStart) {
                    // Root generation replacement: re-arm the two owned
                    // observers for the NEW accepted generation (cancel any
                    // survivor first — the jobs are owned by this scope, and
                    // the Stopped branch normally cancelled them already).
                    foregroundObservation?.cancel()
                    localRuntimeObservation?.cancel()
                }
                foregroundObservation = hostScope.launch(Dispatchers.IO) {
                    var observed = 0L
                    while (kotlinx.coroutines.currentCoroutineContext().isActive) {
                        val changed = com.floe.android.bridge.RunForegroundNative.waitChange(observed, 1_000)
                        if (changed != observed) runtimeHost?.runForeground?.nativeOwnedWorkChanged()
                        observed = changed
                    }
                }
                // G03-R3 fresh-install / live-loss wiring (REAL events from the
                // EXISTING setup authority only): the actual LocalRuntimeSetupHost
                // verified install transition drives a bounded fresh prerequisite
                // re-ingress for the CURRENT accepted root epoch, and leaving the
                // installed state (component/rootfs actually changed) falls ALL
                // facts NOW — even after prior qualification, which the old
                // preflight-call-only check could miss for an already-qualified
                // Core. The StateFlow is the event source; no polling loop.
                localRuntimeObservation = hostScope.launch(Dispatchers.Default) {
                    var previous: String? = null
                    linuxSetup.state.collect { value ->
                        val current = if (value.phase == com.floe.android.host.linux.LocalRuntimeSetupHost.Phase.INSTALLED)
                            com.floe.android.host.linux.LinuxRuntimeReadinessController.INSTALL_PHASE
                            else value.phase.name.lowercase()
                        val decision = com.floe.android.host.linux.LinuxRuntimeReadinessController
                            .lifecycleChange(previous, current)
                        previous = current
                        if (decision == com.floe.android.host.linux.LinuxRuntimeReadinessController
                                .LifecycleChange.NONE
                        ) return@collect
                        val epoch = linuxShell.boundNativeEpoch
                        if (epoch <= 0) return@collect
                        when (decision) {
                            com.floe.android.host.linux.LinuxRuntimeReadinessController
                                .LifecycleChange.REINGRESS -> linuxReadiness.onInstallVerified(epoch)
                            com.floe.android.host.linux.LinuxRuntimeReadinessController
                                .LifecycleChange.INVALIDATE -> linuxReadiness.invalidate("install_changed")
                            com.floe.android.host.linux.LinuxRuntimeReadinessController
                                .LifecycleChange.NONE -> Unit
                        }
                    }
                }
            } else if (capability is RuntimeBootstrapCapability.Stopped) {
                cancelPendingNotesLaunches()
                // Retirement: stop observing the retired root generation so a
                // late owned-work wake can never schedule work against a
                // stopped host. Alarms stay armed from the durable planner;
                // the next OwnedStoreReady rebinds through bindHost.
                com.floe.android.schedule.TaskSchedulePlatform.onRootStopped(runtimeHost)
                // The coordinator published this only after actual native
                // owner/store drain, including the local-runtime gate.
                foregroundObservation?.cancel()
                localRuntimeObservation?.cancel()
                linuxReadiness.stop(linuxShell.boundNativeEpoch)
                kotlinx.coroutines.withContext(Dispatchers.IO) {
                    val terminalEpoch = workspaceTerminal.boundNativeEpoch
                    if (terminalEpoch > 0) workspaceTerminal.stopAndJoin(terminalEpoch, 5_000)
                    val sourceEpoch = workspaceSources.boundNativeEpoch
                    if (sourceEpoch > 0) {
                        networkWorkspaceHost.retireEpoch(sourceEpoch)
                        workspaceSourceHost.retireEpoch(sourceEpoch)
                        workspaceSources.stopAndJoin(sourceEpoch, 5_000)
                    }
                    runtimeHost?.browser?.let { browser ->
                        val browserEpoch = browser.boundNativeEpoch
                        if (browserEpoch > 0) browser.stopAndJoin(browserEpoch, 8_000)
                    }
                    workspaceGitTrust.boundEpoch()?.let { workspaceGitTrust.retireStopped(it) }
                    // D04: settle any pending owned-output Save Copy pick;
                    // the native lane itself needs no epoch retire (every
                    // call re-validates the live root epoch and a stale
                    // claim is a typed refusal).
                    runOutputs?.onRuntimeStopped()
                    runtimeHost?.runForeground?.releaseAllForShutdown()
                }
            }
        }
    }

    @Volatile private var activityForeground = false

    /** Narrow read-only join for the G05-R2 Office AI host lane (Main
     * host20): the ACTUAL MainActivity resume/pause projection this App
     * already maintains for the workspace-actions scene. The AI lane uses it
     * ONLY as the transient admission BEFORE a NEW viewer launch (never as
     * the durable document-owner fence — opening the Office viewer pauses
     * this Activity, and an otherwise-owned VIEWING document must stay
     * valid). Reads no private state, grants nothing. */
    internal fun isActivityInForeground(): Boolean = activityForeground

    internal fun setActivityForeground(active: Boolean) {
        activityForeground = active
        runtimeHost?.workspaceActions?.scene(active)
        if (!active) runtimeHost?.browser?.flushPersistentState()
    }

    /** Channel flavour resume hook (FULL reconciles real phone/ADB status). */
    internal fun onPlatformActivityResumed(activity: android.app.Activity) {
        runCatching { runtimeHost?.platformExtension?.onActivityResumed(activity) }
    }

    internal fun onPlatformActivityPaused() {
        runCatching { runtimeHost?.platformExtension?.onActivityPaused() }
    }

    private suspend fun startBrowserLane(epoch: Long) {
        val browser = runtimeHost?.browser ?: return
        val previous = browser.boundNativeEpoch
        if (previous > 0 && previous != epoch && !browser.stopAndJoin(previous, 8_000)) return
        for (attempt in 0 until 4) {
            if (runtimeHost?.nativeRootEpoch() != epoch) return
            if (browser.start(epoch)) return
            kotlinx.coroutines.delay(100L * (attempt + 1))
        }
    }

    private suspend fun startWorkspaceSourceLane(epoch: Long) {
        val previous = workspaceSources.boundNativeEpoch
        if (previous > 0 && previous != epoch) {
            networkWorkspaceHost.retireEpoch(previous)
            workspaceSourceHost.retireEpoch(previous)
            if (!workspaceSources.stopAndJoin(previous, 5_000)) return
        }
        if (workspaceSources.start(epoch)) {
            workspaceSourceHost.beginEpoch(epoch)
            networkWorkspaceHost.beginEpoch(epoch)
        }
        workspaceGitTrust.ensureBound(epoch)
    }

    /**
     * Bind (or rebind) the three Linux host lanes to [epoch]. Independent
     * starts: a shell-bind refusal can never silently skip the readiness
     * ingress (the old shared try/catch let one lane's transient failure
     * kill the other — a restart-resistant dead lane). A refused pump bind
     * retries in ONE bounded owned attempt set (no idle poller); after a
     * late bind the readiness facts re-ingress ONCE from fresh proof so the
     * mailboxEpoch fact can pass its live cross-check. An old generation is
     * fenced only through its own stop/drain contract; an unproven drain
     * keeps the fenced old binding (fail closed — the new generation's
     * Linux capability stays honestly unqualified, ordinary chat untouched).
     */
    private suspend fun startLinuxLanes(epoch: Long) {
        val previous = linuxShell.boundNativeEpoch
        if (previous == epoch) {
            workspaceTerminal.start(epoch)
            return
        }
        if (previous != 0L) {
            linuxReadiness.stop(previous)
            val terminalEpoch = workspaceTerminal.boundNativeEpoch
            if (terminalEpoch > 0 && !workspaceTerminal.stopAndJoin(terminalEpoch, 5_000)) return
            val cleanupDrained = runCatching { linuxCleanup.drainAndStop(previous) }.getOrDefault(false)
            val shellDrained = runCatching { linuxShell.stopAndDrain(previous) }.getOrDefault(false)
            if (!cleanupDrained || !shellDrained) return
        }
        // Cleanup remains available independently of model admission.
        runCatching { linuxCleanup.start(epoch) }
        val shellBound = runCatching { linuxShell.start(epoch) }.isSuccess
        if (shellBound) workspaceTerminal.start(epoch)
        // Existing cloud tasks remain available whatever happens here.
        runCatching { linuxReadiness.start(epoch) }
        if (!shellBound) {
            hostScope.launch(Dispatchers.IO) {
                repeat(LINUX_LANE_START_ATTEMPTS) {
                    kotlinx.coroutines.delay(LINUX_LANE_START_BACKOFF_MILLIS)
                    if (linuxShell.boundNativeEpoch == epoch) return@launch
                    if (runtimeHost?.nativeRootEpoch() != epoch) return@launch
                    if (runCatching { linuxShell.start(epoch) }.isSuccess) {
                        workspaceTerminal.start(epoch)
                        runCatching { linuxReadiness.onInstallVerified(epoch) }
                        return@launch
                    }
                }
            }
        }
    }

    /** Bounded read-only diagnostic for Diagnostics & About: the honest
     * current local-task-execution stage token from the ORIGINAL readiness
     * authority (closed vocabulary; never paths/keys/prompts/commands). */
    internal suspend fun linuxTaskExecutionDiagnostic(): String =
        if (!::linuxReadiness.isInitialized) "lane:unbound"
        else kotlinx.coroutines.withContext(Dispatchers.IO) { linuxReadiness.diagnosticSnapshot() }

    /** User-initiated bounded retry from the Diagnostics surface: ONE fresh
     * full prerequisite re-ingress for the CURRENT accepted epoch (the SAME
     * authorized primitive the verified install transition uses). Never
     * fabricates qualification; every attempt re-measures live proof and
     * refuses on any real drift. */
    internal suspend fun retryLinuxTaskExecutionIngress(): Boolean =
        if (!::linuxReadiness.isInitialized) false
        else kotlinx.coroutines.withContext(Dispatchers.IO) {
            val epoch = linuxShell.boundNativeEpoch
            if (epoch <= 0) false else linuxReadiness.onInstallVerified(epoch)
        }

    /** Trusted-host read for the Settings local-environment card: the
     * ACTUAL seven-fact qualification of the CURRENT accepted root epoch,
     * observed through the ORIGINAL readiness ingress authority (one bounded
     * native status read off the main thread; no idle polling, no install-
     * status shortcut, no test flag). False whenever nothing is proven. */
    internal suspend fun linuxTaskExecutionReady(): Boolean =
        if (!::linuxReadiness.isInitialized) false
        else kotlinx.coroutines.withContext(Dispatchers.IO) { linuxReadiness.liveTaskExecutionReady() }

    /**
     * Bounded READ-ONLY proof details for the Diagnostics & About "Local
     * task execution" details popup. Composes only the CURRENT actual
     * closed projections of the ORIGINAL authorities: ONE metadata-only
     * runtime `status` observation through the readiness authority, the
     * cleanup lane's own `stats()` aggregate and per-ticket
     * `status(requestID)` receipt readback through the EXISTING JNI
     * surface, and the foreground coordinator's owned-operation kinds /
     * count with the honest CPU-wake flag. Nothing here mutates cleanup
     * records, re-ingresses or invalidates facts, starts work, opens
     * installers or resumes a paused Root, and a UI read NEVER marks tool
     * qualification ready. All reads are finite, generation-fenced and run
     * OFF the main thread; cancellation simply abandons the observation.
     */
    internal suspend fun localRuntimeProofDetails(): kotlinx.serialization.json.JsonObject =
        kotlinx.coroutines.withContext(Dispatchers.IO) {
            val resolver = if (::linuxReadiness.isInitialized) {
                runCatching { linuxReadiness.resolverObservation() }.getOrDefault(
                    com.floe.android.host.linux.LocalRuntimeProofProjection.unavailable("observation_failed"),
                )
            } else {
                com.floe.android.host.linux.LocalRuntimeProofProjection.unavailable("lane_unbound")
            }
            val cleanup = if (::linuxCleanup.isInitialized) {
                runCatching { linuxCleanup.cleanupProofEvidence() }.getOrDefault(
                    com.floe.android.host.linux.LocalRuntimeProofProjection.unavailable("lane_unreadable"),
                )
            } else {
                com.floe.android.host.linux.LocalRuntimeProofProjection.unavailable("lane_unbound")
            }
            val foreground = runtimeHost?.runForeground
            val owned = com.floe.android.host.linux.LocalRuntimeProofProjection.projectOwned(
                operationCount = foreground?.heldOperations()?.size,
                kinds = foreground?.heldOperationKinds()
                    ?.map { it.name.lowercase(java.util.Locale.ROOT) }?.toSet(),
                foregroundConfirmed = foreground?.isForegroundConfirmed(),
                cpuWakeHeld = foreground?.isCpuWakeHeld(),
            )
            kotlinx.serialization.json.JsonObject(
                mapOf("resolver" to resolver, "cleanup" to cleanup, "owned" to owned),
            )
        }

    fun reconcileForegroundOnResume() {
        hostScope.launch(Dispatchers.IO) { runtimeHost?.runForeground?.reconcileAgentRuns() }
    }

    companion object {
        /** Bounded lane-start retry doctrine: the SAME 12x5s shape the
         * readiness controller's owned re-ingress uses. No idle poller. */
        private const val LINUX_LANE_START_ATTEMPTS = 12
        private const val LINUX_LANE_START_BACKOFF_MILLIS = 5_000L
    }
}
