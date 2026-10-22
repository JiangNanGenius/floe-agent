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
    private var foregroundObservation: kotlinx.coroutines.Job? = null
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
            linuxShell.stopAndDrain(linuxShell.boundNativeEpoch)
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
            if (!started && capability is RuntimeBootstrapCapability.OwnedStoreReady) {
                started = true
                runtimeHost?.start()
                kotlinx.coroutines.withContext(Dispatchers.IO) {
                    try { runtimeHost?.nativeRootEpoch()?.let { epoch -> linuxShell.start(epoch) } }
                    catch (_: Exception) {
                        // Local capability remains unqualified; the existing
                        // cloud runtime and its readiness observer stay live.
                    }
                }
                foregroundObservation = hostScope.launch(Dispatchers.IO) {
                    var observed = 0L
                    while (kotlinx.coroutines.currentCoroutineContext().isActive) {
                        val changed = com.floe.android.bridge.RunForegroundNative.waitChange(observed, 1_000)
                        if (changed != observed) runtimeHost?.runForeground?.nativeOwnedWorkChanged()
                        observed = changed
                    }
                }
            } else if (capability is RuntimeBootstrapCapability.Stopped) {
                // The coordinator published this only after actual native
                // owner/store drain, including the local-runtime gate.
                foregroundObservation?.cancel()
                kotlinx.coroutines.withContext(Dispatchers.IO) { runtimeHost?.runForeground?.releaseAllForShutdown() }
            }
        }
    }

    fun reconcileForegroundOnResume() {
        hostScope.launch(Dispatchers.IO) { runtimeHost?.runForeground?.reconcileAgentRuns() }
    }
}
