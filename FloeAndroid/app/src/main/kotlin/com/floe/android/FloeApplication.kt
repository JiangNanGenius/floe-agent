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
    lateinit var linuxSetup: com.floe.android.host.linux.LocalRuntimeSetupHost
        private set
    private lateinit var linuxShell: com.floe.android.host.linux.LinuxShellPump
    // G03-R3: app-owned Core->runtime-UID workspace-copy cleanup pump. It is
    // bound at the SAME actual accepted native Root epoch as the shell pump
    // and stays serviceable while shell/model admission is fenced.
    private lateinit var linuxCleanup: com.floe.android.host.linux.LinuxRuntimeCleanupPump
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
        linuxSetup = com.floe.android.host.linux.LocalRuntimeSetupHost(this, hostScope)
        linuxShell = com.floe.android.host.linux.LinuxShellPump(this, hostScope)
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
            // Retirement ordering (host contract): the shell/jobs mailbox is
            // drained FIRST so Core owned-work/CoreIO really settles, THEN
            // the cleanup pump services remaining runtime-UID wipe
            // obligations over the still-open signed channel. A retained
            // obligation keeps the drain retryable and never strands the
            // shutdown silently — the durable V36 retry + settlement trigger
            // remain the lifecycle authority.
            linuxShell.stopAndDrain(linuxShell.boundNativeEpoch) &&
                (linuxCleanup.boundNativeEpoch == 0L ||
                    linuxCleanup.drainAndStop(linuxCleanup.boundNativeEpoch))
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
        }
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
                kotlinx.coroutines.withContext(Dispatchers.IO) {
                    val epoch = runtimeHost?.nativeRootEpoch()
                    if (epoch != null && epoch > 0) startLinuxLanes(epoch)
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
                // The coordinator published this only after actual native
                // owner/store drain, including the local-runtime gate.
                foregroundObservation?.cancel()
                localRuntimeObservation?.cancel()
                linuxReadiness.stop(linuxShell.boundNativeEpoch)
                kotlinx.coroutines.withContext(Dispatchers.IO) { runtimeHost?.runForeground?.releaseAllForShutdown() }
            }
        }
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
        if (previous == epoch) return
        if (previous != 0L) {
            linuxReadiness.stop(previous)
            val cleanupDrained = runCatching { linuxCleanup.drainAndStop(previous) }.getOrDefault(false)
            val shellDrained = runCatching { linuxShell.stopAndDrain(previous) }.getOrDefault(false)
            if (!cleanupDrained || !shellDrained) return
        }
        // Cleanup remains available independently of model admission.
        runCatching { linuxCleanup.start(epoch) }
        val shellBound = runCatching { linuxShell.start(epoch) }.isSuccess
        // Existing cloud tasks remain available whatever happens here.
        runCatching { linuxReadiness.start(epoch) }
        if (!shellBound) {
            hostScope.launch(Dispatchers.IO) {
                repeat(LINUX_LANE_START_ATTEMPTS) {
                    kotlinx.coroutines.delay(LINUX_LANE_START_BACKOFF_MILLIS)
                    if (linuxShell.boundNativeEpoch == epoch) return@launch
                    if (runtimeHost?.nativeRootEpoch() != epoch) return@launch
                    if (runCatching { linuxShell.start(epoch) }.isSuccess) {
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
