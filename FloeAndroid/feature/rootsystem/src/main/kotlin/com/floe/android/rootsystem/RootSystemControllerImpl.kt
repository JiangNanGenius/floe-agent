// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem

import android.content.Context
import android.os.Build
import android.os.SystemClock
import com.floe.android.contracts.CredentialStore
import com.floe.android.rootsystem.ipc.BinderHub
import com.floe.android.rootsystem.ipc.BinderProtocol
import com.floe.android.rootsystem.ipc.FloeBinderClient
import com.floe.android.rootsystem.pairing.AdbDiscovery
import com.floe.android.rootsystem.pairing.IdentityException
import com.floe.android.rootsystem.pairing.PairingManager
import com.floe.android.rootsystem.policy.AccessPolicy
import com.floe.android.rootsystem.policy.BackendOwnershipPolicy
import com.floe.android.rootsystem.policy.FloePackageFamily
import com.floe.android.rootsystem.policy.PathPolicy
import com.floe.android.rootsystem.policy.PermissionOpsPolicy
import com.floe.android.rootsystem.policy.ProtectedTargets
import com.floe.android.rootsystem.policy.SettingsKeyPolicy
import com.floe.android.rootsystem.policy.StagedApkPolicy
import com.floe.android.rootsystem.root.RootLauncher
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import moe.shizuku.adb.AdbClient
import moe.shizuku.pairing.KeyingMaterialExporters
import moe.shizuku.starter.StarterCommand

internal class RootSystemControllerImpl(
    private val context: Context,
    private val config: RootSystemConfig,
    credentials: CredentialStore,
    private val authority: RootSystemAuthority,
    private val runtime: RootSystemRuntime,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val pairing = PairingManager(credentials, config)
    private val discovery = AdbDiscovery(context)
    private val rootLauncher = RootLauncher()
    private val grants = ConcurrentHashMap<String, GrantRequest>()
    private val activeRequests: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val pairingMutex = Mutex()
    private val lifecycleMutex = Mutex()
    private val closed = AtomicBoolean(false)

    // The real Floe family: the host package plus the stable parent, so the
    // sibling runtime package and its data stay outside every grant ceiling.
    private val protectedPackages = FloePackageFamily.protectedPackages(setOf(config.packageName))

    private val mutableAdb = MutableStateFlow<AdbStatus>(
        if (Build.VERSION.SDK_INT >= 30) AdbStatus.PairRequired else AdbStatus.Disabled,
    )
    private val mutableRoot = MutableStateFlow<RootStatus>(RootStatus.Off)
    val adbStatus: StateFlow<AdbStatus> = mutableAdb.asStateFlow()
    val rootStatus: StateFlow<RootStatus> = mutableRoot.asStateFlow()
    val pairingSupported: Boolean = KeyingMaterialExporters.adbPairingSupported(Build.VERSION.SDK_INT)

    @Volatile
    private var binderClient: FloeBinderClient? = null

    @Volatile
    private var binderMode: String? = null

    @Volatile
    private var binderPid: Int = -1

    @Volatile
    private var staleListenerRemover: (() -> Unit)? = null

    private val binderGeneration = AtomicLong(0)

    @Volatile
    private var connectPort: Int? = config.connectPort

    @Volatile
    private var rootEnabled = false

    @Volatile
    private var rootGrantVerified = false

    @Volatile
    private var adoptedRestartRequired = false

    init {
        runtime.notePairingSupported(pairingSupported)
        publish(mutableAdb.value, mutableRoot.value)
        staleListenerRemover = BinderHub.addStaleListener { onStaleLegacyPublished(it) }
        scope.launch { refresh() }
        // A stale helper may have republished before this controller existed
        // (the provider call restarts the App process on update). Sweep the
        // quarantine once so it is retired without waiting for another Start.
        scope.launch { sweepQuarantinedLegacy() }
    }

    fun snapshot(): RootSystemSnapshot = RootSystemSnapshot(
        adb = mutableAdb.value,
        root = mutableRoot.value,
        pairingSupported = pairingSupported,
        pairingCodeRequired = mutableAdb.value is AdbStatus.PairRequired ||
            mutableAdb.value is AdbStatus.Pairing,
    )

    suspend fun refresh() {
        if (closed.get()) return
        lifecycleMutex.withLock {
            if (!closed.get()) refreshLocked()
        }
    }

    /**
     * Refresh never chooses a new privileged owner. It preserves a verified
     * live Root owner, otherwise it may adopt the already published ADB binder
     * (Root stays default-off), otherwise it only republishes pairing standby.
     */
    private suspend fun refreshLocked() {
        val current = binderClient
        if (current != null && !runCatching { current.isAlive() }.getOrDefault(false)) {
            onServiceDied(binderMode ?: BinderProtocol.MODE_ADB, binderGeneration.get())
        }
        val action = BackendOwnershipPolicy.decideRefresh(
            currentOwner = currentOwner(),
            currentAlive = binderClient?.let { runCatching { it.isAlive() }.getOrDefault(false) } == true,
            adbPublished = BinderHub.peek(BinderProtocol.MODE_ADB) != null,
        )
        when (action) {
            BackendOwnershipPolicy.RefreshAction.KEEP_CURRENT -> {
                publishCurrentOwner()
                return
            }
            BackendOwnershipPolicy.RefreshAction.ADOPT_ADB -> {
                clearStaleActiveStatus()
                adoptBinder(BinderProtocol.MODE_ADB, 0)
                return
            }
            BackendOwnershipPolicy.RefreshAction.NO_SERVICE -> {
                clearStaleActiveStatus()
                if (adoptedRestartRequired) return
                try {
                    if (!pairingSupported) {
                        setAdb(AdbStatus.Disabled)
                        return
                    }
                    setAdb(
                        if (pairing.hasTrust()) AdbStatus.Paired(connectPort)
                        else AdbStatus.PairRequired,
                    )
                } catch (e: IdentityException) {
                    setAdb(AdbStatus.Error("stored pairing identity is unreadable", e.code))
                }
            }
        }
    }

    private fun currentOwner(): BackendOwnershipPolicy.Owner = when {
        binderClient == null -> BackendOwnershipPolicy.Owner.NONE
        binderMode == BinderProtocol.MODE_ADB -> BackendOwnershipPolicy.Owner.ADB
        binderMode == BinderProtocol.MODE_ROOT -> BackendOwnershipPolicy.Owner.ROOT
        else -> BackendOwnershipPolicy.Owner.NONE
    }

    /**
     * Republish only the states that the verified current binder proves. A Root
     * owner always demotes a former live ADB status to paired/standby, never
     * leaves it claiming the active service transport.
     */
    private fun publishCurrentOwner() {
        when (binderMode) {
            BinderProtocol.MODE_ADB -> {
                rootEnabled = false
                val root = if (mutableRoot.value is RootStatus.Enabled) {
                    BackendOwnershipPolicy.inactiveRootStatus(rootGrantVerified)
                } else {
                    mutableRoot.value
                }
                publish(AdbStatus.ServiceAlive(AccessPolicy.UID_SHELL, BinderProtocol.MODE_ADB), root)
            }
            BinderProtocol.MODE_ROOT -> {
                rootEnabled = true
                rootGrantVerified = true
                publish(adbStandbyStatus(), RootStatus.Enabled(AccessPolicy.UID_ROOT))
            }
            else -> clearStaleActiveStatus()
        }
    }

    private fun adbStandbyStatus(): AdbStatus = BackendOwnershipPolicy.standbyAdbStatus(
        current = mutableAdb.value,
        pairingSupported = pairingSupported,
        connectPort = connectPort,
    )

    /** Clear statuses that claim a live owner when no binder is attached. */
    private fun clearStaleActiveStatus() {
        if (binderClient != null) return
        if (mutableAdb.value is AdbStatus.ServiceAlive) {
            publish(adbStandbyStatus(), mutableRoot.value)
        }
        if (mutableRoot.value is RootStatus.Enabled) {
            rootEnabled = false
            publish(
                mutableAdb.value,
                BackendOwnershipPolicy.inactiveRootStatus(rootGrantVerified),
            )
        }
    }

    suspend fun pair(pairingPort: Int, pairingCode: CharArray): PairingResult {
        if (closed.get()) {
            pairingCode.fill('\u0000')
            return PairingResult.Failed("closed")
        }
        if (!pairingSupported) {
            pairingCode.fill('\u0000')
            return PairingResult.Unsupported("pairing_requires_api30")
        }
        return pairingMutex.withLock {
            // ADB is the live owner and cannot be re-paired underneath its own
            // binder. A Root owner may keep ADB paired/standby, so pairing is
            // still allowed there.
            if (binderClient != null && binderMode == BinderProtocol.MODE_ADB) {
                pairingCode.fill('\u0000')
                return@withLock PairingResult.Failed("service_alive")
            }
            setAdb(AdbStatus.Pairing)
            val result = try {
                pairing.pair(pairingPort, pairingCode)
            } catch (e: IdentityException) {
                PairingResult.Unsupported(e.code)
            } finally {
                pairingCode.fill('\u0000')
            }
            when (result) {
                is PairingResult.Success -> {
                    connectPort = config.connectPort ?: connectPort
                    setAdb(AdbStatus.Paired(connectPort))
                }
                is PairingResult.InvalidCode -> setAdb(AdbStatus.PairRequired)
                is PairingResult.Unsupported -> setAdb(
                    AdbStatus.Error("wireless pairing is not supported on this device", result.code),
                )
                is PairingResult.Timeout -> setAdb(AdbStatus.PairRequired)
                is PairingResult.Failed -> setAdb(AdbStatus.PairRequired)
            }
            result
        }
    }

    suspend fun cancelPairing() {
        pairing.cancel()
        if (mutableAdb.value is AdbStatus.Pairing) {
            setAdb(AdbStatus.PairRequired)
        }
    }

    suspend fun forgetPairing() {
        pairing.cancel()
        try {
            pairing.forget()
        } catch (e: IdentityException) {
            setAdb(AdbStatus.Error("pairing trust could not be removed", e.code))
            return
        }
        connectPort = null
        if (binderClient != null && binderMode == BinderProtocol.MODE_ADB) {
            // Service life and pairing trust are separate: forgetting trust does
            // not stop an already-running Floe service.
            setAdb(AdbStatus.ServiceAlive(2000, BinderProtocol.MODE_ADB))
        } else {
            setAdb(AdbStatus.PairRequired)
        }
    }

    suspend fun usbBootstrap(requestedPort: Int?): RootResult<UsbBootstrap> {
        if (closed.get()) return RootResult.Unavailable("closed")
        val port = requestedPort ?: config.connectPort ?: connectPort
        if (port != null && port !in 1..65535) return RootResult.Denied("port")
        val token = randomToken()
        BinderHub.expectToken(BinderProtocol.MODE_ADB, token)
        return try {
            val launch = StarterCommand.adbLaunch(
                nativeLibraryDir = config.nativeLibraryDir,
                apkPath = config.apkPath,
                packageName = config.packageName,
                token = token,
                callerUid = context.applicationInfo.uid,
                signingSha256 = config.signingSha256,
                appVersionCode = config.appVersionCode,
                serverClass = config.serverClass,
            )
            RootResult.Ok(
                UsbBootstrap(
                    adbShellCommand = StarterCommand.usbBootstrapCommand(launch),
                    script = StarterCommand.usbBootstrapScript(launch),
                ),
            )
        } catch (_: Throwable) {
            BinderHub.clearExpectedToken(BinderProtocol.MODE_ADB)
            RootResult.Failed("launch_configuration")
        }
    }

    suspend fun startAdbService(requestedPort: Int?): AccessActionResult {
        if (closed.get()) return AccessActionResult.Unavailable("closed")
        return lifecycleMutex.withLock {
            if (closed.get()) {
                AccessActionResult.Unavailable("closed")
            } else {
                startAdbServiceLocked(requestedPort)
            }
        }
    }

    private suspend fun startAdbServiceLocked(requestedPort: Int?): AccessActionResult {
        val current = binderClient
        if (current != null && binderMode == BinderProtocol.MODE_ADB) {
            if (runCatching { current.isAlive() }.getOrDefault(false)) {
                publishCurrentOwner()
                return AccessActionResult.Ok
            }
            onServiceDied(BinderProtocol.MODE_ADB, binderGeneration.get())
        }

        // Complete every non-destructive preflight before changing the owner.
        if (!pairingSupported) {
            return AccessActionResult.Unavailable("usb_bootstrap_required")
        }
        val hasTrust = try {
            pairing.hasTrust()
        } catch (e: IdentityException) {
            setAdb(AdbStatus.Error("stored pairing identity is unreadable", e.code))
            return AccessActionResult.Denied(e.code)
        }
        if (!hasTrust) {
            setAdb(AdbStatus.PairRequired)
            return AccessActionResult.Denied("pair_required")
        }

        // Android assigns a new TLS port after Wireless debugging is enabled
        // again. A remembered successful endpoint must not hide the current
        // locally discovered one. Explicit caller/configuration ports still
        // take precedence; this does not replay a launch or discard trust.
        val port = requestedPort ?: config.connectPort
            ?: withContext(Dispatchers.IO) { discovery.findConnectPort() }
            ?: connectPort
            ?: return AccessActionResult.Failed("no_connect_port")
        connectPort = port

        // Replacement is addressed by the exact PID verified through the
        // published binder, never by a process name or /proc scan. An older
        // same-package helper is stopped through its typed stopServer call;
        // the starter then rechecks that PID before any kill. Resolve it before
        // stopping Root so an unverifiable ADB helper cannot cost the live Root
        // owner.
        val resolution = resolvePublishedForStart(
            BinderProtocol.MODE_ADB,
            STALE_DISCOVERY_MILLIS,
        )
        val replacePid = when (resolution) {
            PublishedResolution.None, PublishedResolution.Current -> null
            is PublishedResolution.Replace -> resolution.pid
            is PublishedResolution.Refused -> {
                setAdb(
                    AdbStatus.Error(
                        "existing ADB service identity could not be verified",
                        resolution.code,
                    ),
                )
                return AccessActionResult.Failed(resolution.code)
            }
        }

        // The user explicitly selected ADB. Only now may a live Root owner be
        // stopped; a failed Root stop leaves the verified Root owner in place.
        if (BackendOwnershipPolicy.planExplicitAdb(currentOwner()).stopLiveRoot) {
            val failure = stopRootForSwitch()
            if (failure != null) return failure
        }
        clearStaleActiveStatus()

        if (resolution == PublishedResolution.Current) {
            when (val adoption = adoptBinderDetailed(BinderProtocol.MODE_ADB, 0)) {
                Adoption.Adopted -> return AccessActionResult.Ok
                is Adoption.Refused -> return AccessActionResult.Failed(adoption.code)
                Adoption.NotPublished -> {
                    setAdb(
                        AdbStatus.Error(
                            "existing ADB service identity could not be adopted",
                            "identity",
                        ),
                    )
                    return AccessActionResult.Failed("service_identity")
                }
            }
        }

        val token = randomToken()
        BinderHub.expectToken(BinderProtocol.MODE_ADB, token)
        val launch = try {
            StarterCommand.adbLaunch(
                nativeLibraryDir = config.nativeLibraryDir,
                apkPath = config.apkPath,
                packageName = config.packageName,
                token = token,
                callerUid = context.applicationInfo.uid,
                signingSha256 = config.signingSha256,
                appVersionCode = config.appVersionCode,
                serverClass = config.serverClass,
                replacePid = replacePid,
            )
        } catch (_: Throwable) {
            BinderHub.clearExpectedToken(BinderProtocol.MODE_ADB)
            return AccessActionResult.Failed("launch_configuration")
        }

        // Start may only present the identity whose pairing completed. This
        // path must never create a fresh key: a candidate or unreadable record
        // fails closed instead of presenting a key the device never authorized.
        val identity = try {
            pairing.pairedIdentity()
        } catch (e: IdentityException) {
            BinderHub.clearExpectedToken(BinderProtocol.MODE_ADB)
            if (e.code == "identity_unpaired") {
                setAdb(AdbStatus.PairRequired)
                return AccessActionResult.Denied("pair_required")
            }
            setAdb(AdbStatus.Error("stored pairing identity is unreadable", e.code))
            return AccessActionResult.Denied(e.code)
        }

        var connectFailure = AdbConnectDiagnostics.CONNECT
        val launched = try {
            withContext(Dispatchers.IO) {
                AdbClient(
                    host = "127.0.0.1",
                    port = port,
                    identity = identity,
                    readTimeoutMillis = 20_000,
                ).use { client ->
                    client.connect()
                    runCatching { client.shellCommand(launch.command, 32 * 1024) }.isSuccess
                }
            }
        } catch (e: AdbClient.AdbFailure) {
            connectFailure = AdbConnectDiagnostics.codeFor(e.failure)
            false
        } catch (_: Throwable) {
            false
        }

        if (!launched) {
            BinderHub.clearExpectedToken(BinderProtocol.MODE_ADB)
            // A client-side TLS-layer failure does not distinguish a rejected
            // client certificate from a local cipher/protocol/IO/server-cert
            // failure. Keep the recoverable identity and its recorded trust;
            // only an explicit user "forget pairing" removes it. The bounded
            // failure class is returned for diagnostics.
            setAdb(AdbStatus.Paired(port))
            return AccessActionResult.Failed(connectFailure)
        }
        val adoption = adoptBinderDetailed(BinderProtocol.MODE_ADB, 12_000)
        if (adoption is Adoption.Adopted) {
            // Keep the launch token: a same-token republish by this verified
            // server is accepted, while an older helper's token is rejected.
            return AccessActionResult.Ok
        }
        BinderHub.clearExpectedToken(BinderProtocol.MODE_ADB)
        if (adoption is Adoption.Refused) {
            // failAdoption already published the precise identity/verdict
            // reason. Never collapse it into the publication-wait outcome.
            return AccessActionResult.Failed(adoption.code)
        }
        setAdb(AdbStatus.Error("Floe service did not publish its binder", "binder_timeout"))
        return AccessActionResult.Failed("binder_timeout")
    }

    suspend fun stopAdbService(): AccessActionResult {
        if (closed.get()) return AccessActionResult.Unavailable("closed")
        return lifecycleMutex.withLock {
            if (closed.get()) AccessActionResult.Unavailable("closed") else stopAdbServiceLocked()
        }
    }

    private suspend fun stopAdbServiceLocked(): AccessActionResult {
        val current = binderClient
        if (current != null && binderMode == BinderProtocol.MODE_ADB) {
            if (!runCatching { current.isAlive() }.getOrDefault(false)) {
                onServiceDied(BinderProtocol.MODE_ADB, binderGeneration.get())
            } else {
                fenceClient(current)
                withContext(Dispatchers.IO) { current.stopOwnedService(binderPid) }
                awaitBinderDeath(current, STOP_TIMEOUT_MILLIS)
                BinderHub.clear(BinderProtocol.MODE_ADB)
                clearBinder()
                grants.clear()
                activeRequests.clear()
                clearInactiveRootClaim()
                setAdb(adbStandbyAfterStop())
                return AccessActionResult.Ok
            }
        }

        // A verified ADB standby may be stopped without touching a Root owner.
        if (binderMode != BinderProtocol.MODE_ADB) {
            val inspected = inspectPublished(BinderProtocol.MODE_ADB, 0)
            if (inspected != null) {
                when (val verdict = inspected.verdict) {
                    is BackendOwnershipPolicy.PublishedVerdict.Refused -> {
                        setAdb(
                            AdbStatus.Error(
                                "existing ADB service identity could not be verified",
                                verdict.code,
                            ),
                        )
                        return AccessActionResult.Failed(verdict.code)
                    }
                    BackendOwnershipPolicy.PublishedVerdict.Current -> {
                        val stopped = stopPublished(
                            BinderProtocol.MODE_ADB,
                            inspected,
                            inspected.record.serverPid,
                        )
                        when (stopped) {
                            is StaleStopResult.Refused -> return AccessActionResult.Failed(stopped.code)
                            is StaleStopResult.StillAlive -> {
                                setAdb(AdbStatus.Error("ADB service did not stop", "stop_timeout"))
                                return AccessActionResult.Failed("stop_timeout")
                            }
                            is StaleStopResult.Stopped -> Unit
                        }
                    }
                    is BackendOwnershipPolicy.PublishedVerdict.Replace -> {
                        val stopped = stopPublished(
                            BinderProtocol.MODE_ADB,
                            inspected,
                            verdict.pid,
                        )
                        when (stopped) {
                            is StaleStopResult.Refused -> return AccessActionResult.Failed(stopped.code)
                            is StaleStopResult.StillAlive -> {
                                setAdb(AdbStatus.Error("ADB service did not stop", "stop_timeout"))
                                return AccessActionResult.Failed("stop_timeout")
                            }
                            is StaleStopResult.Stopped -> Unit
                        }
                    }
                }
            }
        }
        setAdb(adbStandbyAfterStop())
        return AccessActionResult.Ok
    }

    suspend fun rebind(): AccessActionResult {
        if (closed.get()) return AccessActionResult.Unavailable("closed")
        return lifecycleMutex.withLock {
            if (closed.get()) {
                AccessActionResult.Unavailable("closed")
            } else {
                rebindLocked()
            }
        }
    }

    private suspend fun rebindLocked(): AccessActionResult {
        val current = binderClient
        if (current != null) {
            if (runCatching { current.isAlive() }.getOrDefault(false)) {
                publishCurrentOwner()
                return AccessActionResult.Ok
            }
            onServiceDied(binderMode ?: BinderProtocol.MODE_ADB, binderGeneration.get())
        }
        clearStaleActiveStatus()
        if (adoptBinder(BinderProtocol.MODE_ADB, 6_000)) return AccessActionResult.Ok
        if (adoptedRestartRequired) return AccessActionResult.Failed("restart_required")
        return AccessActionResult.Failed("service_not_running")
    }

    suspend fun probe(): AccessActionResult {
        if (closed.get()) return AccessActionResult.Unavailable("closed")
        return lifecycleMutex.withLock {
            if (closed.get()) {
                AccessActionResult.Unavailable("closed")
            } else {
                probeLocked()
            }
        }
    }

    private suspend fun probeLocked(): AccessActionResult {
        val current = binderClient
        if (current != null) {
            if (runCatching { current.isAlive() }.getOrDefault(false)) {
                publishCurrentOwner()
                return AccessActionResult.Ok
            }
            onServiceDied(binderMode ?: BinderProtocol.MODE_ADB, binderGeneration.get())
        }
        clearStaleActiveStatus()
        if (adoptBinder(BinderProtocol.MODE_ADB, 0)) return AccessActionResult.Ok
        if (adoptedRestartRequired) return AccessActionResult.Failed("restart_required")
        return AccessActionResult.Failed("service_not_running")
    }

    suspend fun setRootEnabled(enabled: Boolean): AccessActionResult {
        if (closed.get()) return AccessActionResult.Unavailable("closed")
        return lifecycleMutex.withLock {
            if (closed.get()) {
                AccessActionResult.Unavailable("closed")
            } else {
                setRootEnabledLocked(enabled)
            }
        }
    }

    private suspend fun setRootEnabledLocked(enabled: Boolean): AccessActionResult {
        if (!enabled) return disableRootLocked()

        val current = binderClient
        if (rootEnabled && current != null && binderMode == BinderProtocol.MODE_ROOT) {
            if (runCatching { current.isAlive() }.getOrDefault(false)) {
                publishCurrentOwner()
                return AccessActionResult.Ok
            }
            onServiceDied(BinderProtocol.MODE_ROOT, binderGeneration.get())
        }

        // A binder left by an earlier App process is not sufficient: root is
        // default-off, so this process must observe an explicit existing grant
        // before adopting or starting the root backend.
        val effectiveUid = rootLauncher.probeEffectiveUid()
        if (effectiveUid != AccessPolicy.UID_ROOT) {
            rootEnabled = false
            if (binderMode != BinderProtocol.MODE_ROOT) setRoot(RootStatus.GrantNotFound)
            return AccessActionResult.Denied("grant_not_found")
        }
        rootGrantVerified = true
        if (binderMode != BinderProtocol.MODE_ROOT) setRoot(RootStatus.GrantFound)

        when (
            val resolution = resolvePublishedForStart(
                BinderProtocol.MODE_ROOT,
                STALE_DISCOVERY_MILLIS,
            )
        ) {
            PublishedResolution.None -> Unit
            PublishedResolution.Current -> {
                if (adoptBinder(BinderProtocol.MODE_ROOT, 0)) {
                    rootEnabled = true
                    return AccessActionResult.Ok
                }
                setRoot(RootStatus.Refused("identity"))
                return AccessActionResult.Failed("root_service_identity")
            }
            is PublishedResolution.Replace -> {
                // Root has no native replace helper; do not launch a duplicate
                // while a verified old Root helper is still alive.
                if (resolution.stillAlive) {
                    setRoot(RootStatus.Refused("stop_timeout"))
                    return AccessActionResult.Failed("stale_stop_timeout")
                }
            }
            is PublishedResolution.Refused -> {
                setRoot(RootStatus.Refused(resolution.code))
                return AccessActionResult.Failed(resolution.code)
            }
        }

        val token = randomToken()
        BinderHub.expectToken(BinderProtocol.MODE_ROOT, token)
        val launch = try {
            StarterCommand.rootLaunch(
                apkPath = config.apkPath,
                packageName = config.packageName,
                token = token,
                callerUid = context.applicationInfo.uid,
                signingSha256 = config.signingSha256,
                appVersionCode = config.appVersionCode,
                serverClass = config.serverClass,
            )
        } catch (_: Throwable) {
            BinderHub.clearExpectedToken(BinderProtocol.MODE_ROOT)
            setRoot(RootStatus.Error("root launch configuration is invalid"))
            return AccessActionResult.Failed("launch_configuration")
        }
        if (!rootLauncher.launch(launch)) {
            BinderHub.clearExpectedToken(BinderProtocol.MODE_ROOT)
            setRoot(RootStatus.Refused("su_command_failed"))
            return AccessActionResult.Denied("root_start")
        }
        if (adoptBinder(BinderProtocol.MODE_ROOT, 12_000)) {
            rootEnabled = true
            return AccessActionResult.Ok
        }
        BinderHub.clearExpectedToken(BinderProtocol.MODE_ROOT)
        setRoot(RootStatus.Refused("uid0_unverified"))
        return AccessActionResult.Failed("root_service_not_started")
    }

    private suspend fun disableRootLocked(): AccessActionResult {
        val current = binderClient
        if (BackendOwnershipPolicy.mustStopLiveRoot(currentOwner()) && current != null) {
            if (!runCatching { current.isAlive() }.getOrDefault(false)) {
                onServiceDied(BinderProtocol.MODE_ROOT, binderGeneration.get())
            } else {
                fenceClient(current)
                withContext(Dispatchers.IO) { current.stopOwnedService(binderPid) }
                val gone = awaitBinderDeath(current, ROOT_STOP_TIMEOUT_MILLIS)
                if (gone) BinderHub.clear(BinderProtocol.MODE_ROOT)
                clearBinder()
                grants.clear()
                activeRequests.clear()
            }
        }
        rootEnabled = false
        rootGrantVerified = false
        setRoot(RootStatus.Off)
        return AccessActionResult.Ok
    }

    /**
     * Stop the verified live Root owner before an explicit ADB start. A failed
     * bounded stop keeps the Root owner and returns failure instead of letting
     * two privileged owners run at once.
     */
    private suspend fun stopRootForSwitch(): AccessActionResult? {
        if (!BackendOwnershipPolicy.mustStopLiveRoot(currentOwner())) return null
        val current = binderClient ?: return null
        if (!runCatching { current.isAlive() }.getOrDefault(false)) {
            onServiceDied(BinderProtocol.MODE_ROOT, binderGeneration.get())
            return null
        }
        fenceClient(current)
        withContext(Dispatchers.IO) { current.stopOwnedService(binderPid) }
        if (!awaitBinderDeath(current, ROOT_STOP_TIMEOUT_MILLIS)) {
            return AccessActionResult.Failed("root_stop_timeout")
        }
        BinderHub.clear(BinderProtocol.MODE_ROOT)
        clearBinder()
        grants.clear()
        activeRequests.clear()
        rootEnabled = false
        publish(
            adbStandbyStatus(),
            BackendOwnershipPolicy.inactiveRootStatus(rootGrantVerified),
        )
        return null
    }

    private fun clearInactiveRootClaim() {
        if (mutableRoot.value !is RootStatus.Enabled) return
        rootEnabled = false
        publish(
            mutableAdb.value,
            BackendOwnershipPolicy.inactiveRootStatus(rootGrantVerified),
        )
    }

    private fun adbStandbyAfterStop(): AdbStatus =
        if (pairingSupported) AdbStatus.Paired(connectPort) else AdbStatus.Disabled

    suspend fun registerGrant(request: GrantRequest): RootResult<GrantReceipt> {
        if (closed.get()) return RootResult.Unavailable("closed")
        val denial = validateGrantRequest(request)
        if (denial != null) return RootResult.Denied(denial)
        val client = activeClient() ?: return RootResult.Unavailable("service_not_alive")
        val mode = binderMode ?: BinderProtocol.MODE_ADB
        val generation = binderGeneration.get()
        val result = withContext(Dispatchers.IO) { client.registerGrant(request) }
        if (binderClient !== client) return RootResult.Unavailable("fenced")
        if (result is RootResult.Ok) {
            grants[request.grantId] = request
        } else if (result is RootResult.Unavailable) {
            onServiceDied(mode, generation)
        }
        return result
    }

    suspend fun revokeGrant(grantId: String): AccessActionResult {
        grants.remove(grantId)
        val client = binderClient ?: return AccessActionResult.Ok
        return withContext(Dispatchers.IO) { client.revokeGrant(grantId) }
    }

    suspend fun revokeAllGrants(): AccessActionResult {
        grants.clear()
        val client = binderClient ?: return AccessActionResult.Ok
        return withContext(Dispatchers.IO) { client.revokeAllGrants() }
    }

    suspend fun fileList(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        maxEntries: Int,
    ): RootResult<List<FileEntry>> = dispatch(claim, SystemOperation.FILE_LIST, relativePath) { client ->
        client.fileList(
            claim,
            scopeId,
            relativePath,
            maxEntries.coerceIn(1, minOf(BinderProtocol.MAX_LIST, config.maxListEntries)),
        )
    }

    suspend fun fileRead(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        offset: Long,
        maxBytes: Int,
    ): RootResult<FileRead> = dispatch(claim, SystemOperation.FILE_READ, relativePath) { client ->
        client.fileRead(
            claim,
            scopeId,
            relativePath,
            offset,
            maxBytes.coerceIn(1, minOf(BinderProtocol.MAX_READ_BYTES, config.maxFileReadBytes)),
        )
    }

    suspend fun fileWrite(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        data: ByteArray,
        overwrite: Boolean,
    ): RootResult<FileWriteReceipt> {
        if (data.size > minOf(BinderProtocol.MAX_WRITE_BYTES, config.maxFileWriteBytes)) {
            return RootResult.Denied("write_too_large")
        }
        return dispatch(claim, SystemOperation.FILE_WRITE, relativePath) { client ->
            client.fileWrite(claim, scopeId, relativePath, data, overwrite)
        }
    }

    suspend fun fileMove(
        claim: OperationClaim,
        scopeId: String,
        fromRelativePath: String,
        toRelativePath: String,
        overwrite: Boolean,
    ): RootResult<MoveReceipt> = dispatch(
        claim,
        SystemOperation.FILE_MOVE,
        "$fromRelativePath -> $toRelativePath",
        destructive = overwrite,
    ) { client ->
        client.fileMove(claim, scopeId, fromRelativePath, toRelativePath, overwrite)
    }

    suspend fun fileDelete(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        recursive: Boolean,
    ): RootResult<DeleteReceipt> = dispatch(
        claim,
        SystemOperation.FILE_DELETE,
        relativePath,
        destructive = true,
    ) { client ->
        client.fileDelete(claim, scopeId, relativePath, recursive)
    }

    suspend fun processQuery(
        claim: OperationClaim,
        filter: String?,
        maxEntries: Int,
    ): RootResult<List<ProcessRecord>> = dispatch(claim, SystemOperation.PROCESS_QUERY, filter) { client ->
        client.processQuery(claim, filter, maxEntries.coerceIn(1, BinderProtocol.MAX_LIST))
    }

    suspend fun serviceQuery(
        claim: OperationClaim,
        maxEntries: Int,
    ): RootResult<List<ServiceRecord>> = dispatch(claim, SystemOperation.SERVICE_QUERY, null) { client ->
        client.serviceQuery(claim, maxEntries.coerceIn(1, BinderProtocol.MAX_LIST))
    }

    suspend fun packageQuery(
        claim: OperationClaim,
        packageName: String?,
        includeSystem: Boolean,
        maxEntries: Int,
        includeUninstalled: Boolean = false,
    ): RootResult<PackageQuery> = dispatch(claim, SystemOperation.PACKAGE_QUERY, packageName) { client ->
        client.packageQuery(
            claim, packageName, includeSystem,
            maxEntries.coerceIn(1, BinderProtocol.MAX_LIST),
            includeUninstalled = includeUninstalled,
        )
    }

    suspend fun networkDiagnostics(claim: OperationClaim): RootResult<NetworkDiagnostics> =
        dispatch(claim, SystemOperation.NETWORK_DIAGNOSTICS, null) { client ->
            client.networkDiagnostics(claim)
        }

    suspend fun forceStopPackage(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<PackageManagementReceipt> {
        if (!config.allowPackageManagement) return RootResult.Denied("management_disabled")
        if (ProtectedTargets.isProtectedPackage(packageName, protectedPackages)) {
            return RootResult.Denied("protected_target")
        }
        return dispatch(
            claim,
            SystemOperation.PACKAGE_FORCE_STOP,
            packageName,
            destructive = true,
        ) { client -> client.managePackage(claim, packageName, userId) }
    }

    suspend fun installPackage(
        claim: OperationClaim,
        stagedApkPath: String,
        userId: Int,
        binding: com.floe.android.rootsystem.StagedApkBinding =
            com.floe.android.rootsystem.StagedApkBinding(null, -1L, null),
    ): RootResult<PackageLifecycleReceipt> {
        if (!config.allowPackageManagement) return RootResult.Denied("management_disabled")
        if (StagedApkPolicy.normalizeStagedPath(stagedApkPath) == null) {
            return RootResult.Denied("apk_path")
        }
        return dispatch(
            claim,
            SystemOperation.PACKAGE_INSTALL,
            stagedApkPath,
            destructive = true,
        ) { client -> client.installPackage(claim, stagedApkPath, userId, binding) }
    }

    suspend fun stageApk(
        claim: OperationClaim,
        sourcePath: String,
    ): RootResult<StagedCopyReceipt> {
        if (!config.allowPackageManagement) return RootResult.Denied("management_disabled")
        if (StagedApkPolicy.normalizeStagedPath(sourcePath) == null) {
            return RootResult.Denied("apk_path")
        }
        return dispatch(
            claim,
            SystemOperation.PACKAGE_STAGE,
            sourcePath,
            destructive = false,
        ) { client -> client.stageApk(claim, sourcePath) }
    }

    suspend fun uninstallPackage(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<PackageLifecycleReceipt> {
        if (!config.allowPackageManagement) return RootResult.Denied("management_disabled")
        if (ProtectedTargets.isProtectedPackage(packageName, protectedPackages)) {
            return RootResult.Denied("protected_target")
        }
        return dispatch(
            claim,
            SystemOperation.PACKAGE_UNINSTALL,
            packageName,
            destructive = true,
        ) { client -> client.uninstallPackage(claim, packageName, userId) }
    }

    suspend fun setPackageEnabled(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
        state: String,
    ): RootResult<com.floe.android.rootsystem.PackageStateReceipt> {
        if (!config.allowPackageManagement) return RootResult.Denied("management_disabled")
        if (state !in ProtectedTargets.SET_ENABLED_STATES) return RootResult.Denied("package_state")
        if (ProtectedTargets.isProtectedPackage(packageName, protectedPackages)) {
            return RootResult.Denied("protected_target")
        }
        return dispatch(
            claim,
            SystemOperation.PACKAGE_SET_ENABLED,
            packageName,
            destructive = true,
        ) { client -> client.setPackageEnabled(claim, packageName, userId, state) }
    }

    suspend fun removePackageForUser(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<com.floe.android.rootsystem.PackageLifecycleReceipt> {
        if (!config.allowPackageManagement) return RootResult.Denied("management_disabled")
        if (ProtectedTargets.isProtectedPackage(packageName, protectedPackages)) {
            return RootResult.Denied("protected_target")
        }
        return dispatch(
            claim,
            SystemOperation.PACKAGE_REMOVE_FOR_USER,
            packageName,
            destructive = true,
        ) { client -> client.removePackageForUser(claim, packageName, userId) }
    }

    suspend fun restorePackage(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<com.floe.android.rootsystem.PackageLifecycleReceipt> {
        if (!config.allowPackageManagement) return RootResult.Denied("management_disabled")
        if (ProtectedTargets.isProtectedPackage(packageName, protectedPackages)) {
            return RootResult.Denied("protected_target")
        }
        return dispatch(
            claim,
            SystemOperation.PACKAGE_RESTORE,
            packageName,
            destructive = true,
        ) { client -> client.restorePackage(claim, packageName, userId) }
    }

    suspend fun releaseStagedApk(sha256: String): AccessActionResult {
        val client = binderClient ?: return AccessActionResult.Unavailable("service_not_alive")
        if (!sha256.matches(Regex("^[0-9a-f]{64}$"))) return AccessActionResult.Denied("staged_shape")
        return withContext(Dispatchers.IO) { client.releaseStagedApk(sha256) }
    }

    // -------------------------------------------------- permissions/appops

    /**
     * Read the declared permissions and granted state for one app of the
     * current profile. Read-only dispatch: public package/permission
     * metadata is disclosable for any selected target, so unlike the
     * mutations this carries NO protected-target refusal; the service still
     * enforces the grant's selected-target ceiling.
     */
    suspend fun queryPermissions(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<com.floe.android.rootsystem.PermissionQueryResult> =
        dispatch(
            claim,
            SystemOperation.PERMISSIONS_QUERY,
            packageName,
            destructive = false,
        ) { client -> client.queryPermissions(claim, packageName, userId) }

    /**
     * Grant/revoke one declared runtime/development permission. The base
     * management ceiling applies; the service validates the declaration and
     * protection level again and reports OS refusals as real per-item
     * failures.
     */
    suspend fun managePermission(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
        permission: String,
        action: String,
    ): RootResult<com.floe.android.rootsystem.PermissionSetReceipt> {
        if (!config.allowPackageManagement) return RootResult.Denied("management_disabled")
        if (ProtectedTargets.isProtectedPackage(packageName, protectedPackages)) {
            return RootResult.Denied("protected_target")
        }
        if (!PermissionOpsPolicy.PERMISSION_NAME.matches(permission)) {
            return RootResult.Denied("permission")
        }
        if (action !in PermissionOpsPolicy.ACTIONS) return RootResult.Denied("permission_action")
        return dispatch(
            claim,
            SystemOperation.PERMISSIONS_MANAGE,
            packageName,
            destructive = true,
        ) { client -> client.managePermission(claim, packageName, userId, permission, action) }
    }

    /** Read the closed-catalog AppOps modes for one app. Read-only like
     *  [queryPermissions]: no protected-target refusal, selected-target
     *  ceiling enforced by the service. */
    suspend fun queryAppOps(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<com.floe.android.rootsystem.AppOpsQueryResult> =
        dispatch(
            claim,
            SystemOperation.APP_OPS_QUERY,
            packageName,
            destructive = false,
        ) { client -> client.queryAppOps(claim, packageName, userId) }

    /** Set one closed-catalog AppOps mode for one app of the current user. */
    suspend fun manageAppOps(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
        operation: String,
        mode: String,
    ): RootResult<com.floe.android.rootsystem.AppOpsSetReceipt> {
        if (!config.allowPackageManagement) return RootResult.Denied("management_disabled")
        if (ProtectedTargets.isProtectedPackage(packageName, protectedPackages)) {
            return RootResult.Denied("protected_target")
        }
        return dispatch(
            claim,
            SystemOperation.APP_OPS_MANAGE,
            packageName,
            destructive = true,
        ) { client -> client.manageAppOps(claim, packageName, userId, operation, mode) }
    }

    suspend fun readSetting(
        claim: OperationClaim,
        namespace: String,
        key: String,
    ): RootResult<SettingReadResult> {
        if (namespace !in SettingsKeyPolicy.SUPPORTED_NAMESPACES) {
            return RootResult.Denied("setting_namespace")
        }
        if (SettingsKeyPolicy.specFor(namespace, key) == null) {
            return RootResult.Denied("setting_key")
        }
        return dispatch(claim, SystemOperation.SETTINGS_READ, "$namespace/$key") { client ->
            client.readSettings(claim, namespace, key)
        }
    }

    suspend fun writeSettings(
        claim: OperationClaim,
        changes: List<SettingsChange>,
    ): RootResult<SettingsBatchReceipt> {
        val requests = changes.map {
            SettingsKeyPolicy.ChangeRequest(
                it.namespace,
                it.key,
                when (it.action) {
                    SettingsChangeAction.PUT -> SettingsKeyPolicy.ChangeAction.PUT
                    SettingsChangeAction.DELETE -> SettingsKeyPolicy.ChangeAction.DELETE
                },
                it.value,
            )
        }
        val checked = when (val result = SettingsKeyPolicy.checkBatch(requests)) {
            is SettingsKeyPolicy.BatchCheck.Ok -> result.changes
            is SettingsKeyPolicy.BatchCheck.Rejected -> return RootResult.Denied(result.code)
        }
        val typed = checked.map {
            SettingsChange(
                it.namespace,
                it.key,
                when (it.action) {
                    SettingsKeyPolicy.ChangeAction.PUT -> SettingsChangeAction.PUT
                    SettingsKeyPolicy.ChangeAction.DELETE -> SettingsChangeAction.DELETE
                },
                it.value,
            )
        }
        return dispatch(
            claim,
            SystemOperation.SETTINGS_WRITE,
            "${typed.size} settings change(s)",
            destructive = true,
        ) { client -> client.writeSettings(claim, typed) }
    }

    suspend fun cancelOperation(claim: OperationClaim): AccessActionResult {
        if (!claim.isWellFormed()) return AccessActionResult.Denied("claim_shape")
        val client = binderClient ?: return AccessActionResult.Ok
        withContext(Dispatchers.IO) { client.cancel(claim.requestId) }
        return AccessActionResult.Ok
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        staleListenerRemover?.invoke()
        staleListenerRemover = null
        pairing.cancel()
        fenceClient(binderClient)
        clearBinder()
        grants.clear()
        activeRequests.clear()
        scope.cancel()
    }

    // ------------------------------------------------------------- internals

    private suspend fun <T> dispatch(
        claim: OperationClaim,
        operation: SystemOperation,
        target: String?,
        destructive: Boolean = false,
        block: (FloeBinderClient) -> RootResult<T>,
    ): RootResult<T> {
        if (closed.get()) return RootResult.Unavailable("closed")
        if (!claim.isWellFormed()) return RootResult.Denied("claim_shape")
        val request = RootOperationRequest(claim, operation, target, destructive)
        when (val decision = try {
            authority.authorize(request)
        } catch (_: Throwable) {
            AuthorityDecision.Denied("authority")
        }) {
            is AuthorityDecision.Denied -> return RootResult.Denied(decision.code, decision.message)
            is AuthorityDecision.Allowed -> Unit
        }
        if (authority.isCancelled(request)) return RootResult.Denied("cancelled")

        val grant = grants[claim.grantId] ?: return RootResult.Denied("grant_unknown")
        if (grant.taskId != claim.taskId || grant.runId != claim.runId || grant.epoch != claim.epoch) {
            return RootResult.Denied("grant_mismatch")
        }
        if (System.currentTimeMillis() >= grant.expiresAtMillis) {
            grants.remove(claim.grantId)
            return RootResult.Denied("expired")
        }
        if (operation !in grant.operations) return RootResult.Denied("operation")
        if (SystemOperation.isPackageManagement(operation) && !grant.packageManagementAllowed) {
            return RootResult.Denied("management")
        }
        val client = activeClient() ?: return RootResult.Unavailable("service_not_alive")
        val result = try {
            activeRequests.add(claim.requestId)
            withContext(Dispatchers.IO) { block(client) }
        } finally {
            activeRequests.remove(claim.requestId)
        }
        // A mode switch/death during the call fences the result even if the
        // old backend returned a value after the owner changed.
        if (binderClient !== client ||
            !runCatching { client.isAlive() }.getOrDefault(false)
        ) {
            if (binderClient === client) {
                onServiceDied(binderMode ?: BinderProtocol.MODE_ADB, binderGeneration.get())
            }
            return RootResult.Denied("fenced")
        }
        if (authority.isCancelled(request)) return RootResult.Denied("cancelled")
        return result
    }

    private fun activeClient(): FloeBinderClient? {
        val client = binderClient ?: return null
        val mode = binderMode ?: BinderProtocol.MODE_ADB
        val generation = binderGeneration.get()
        if (!runCatching { client.isAlive() }.getOrDefault(false)) {
            onServiceDied(mode, generation)
            return null
        }
        return client
    }

    private sealed interface PublishedResolution {
        data object None : PublishedResolution
        data object Current : PublishedResolution
        data class Replace(val pid: Int, val stillAlive: Boolean) : PublishedResolution
        data class Refused(val code: String) : PublishedResolution
    }

    private sealed interface Adoption {
        data object Adopted : Adoption

        /** No publication became visible within the bounded wait. */
        data object NotPublished : Adoption

        /**
         * A visible publication was refused or needs replacement. The exact
         * reason has already been published to [AdbStatus]/[RootStatus].
         */
        data class Refused(val code: String) : Adoption
    }

    private data class InspectedPublished(
        val record: BinderHub.Published,
        val client: FloeBinderClient,
        val verdict: BackendOwnershipPolicy.PublishedVerdict,
    )

    private sealed interface StaleStopResult {
        data class Stopped(val pid: Int) : StaleStopResult
        data class StillAlive(val pid: Int) : StaleStopResult
        data class Refused(val code: String) : StaleStopResult
    }

    /**
     * Verify a published helper through the live binder, not through a process
     * name. A dead publication is simply no service; a live one that cannot
     * prove the exact Floe identity is refused and never killed.
     */
    private suspend fun inspectPublished(mode: String, waitMillis: Long): InspectedPublished? {
        val record = (if (waitMillis > 0) BinderHub.await(mode, waitMillis) else BinderHub.peek(mode))
            ?: return null
        return inspectRecord(mode, record)
    }

    /** Inspect the quarantined stale publication for [mode], if one is present. */
    private suspend fun inspectQuarantined(mode: String): InspectedPublished? {
        val record = BinderHub.stalePeek(mode) ?: return null
        return inspectRecord(mode, record, legacyWireOnly = true)
    }

    /**
     * Verify a helper record through the live binder. With [legacyWireOnly]
     * (quarantined publications) a live describe() whose wire marker is not a
     * known older Floe protocol drops the record from quarantine and is never
     * inspected for a stop, so an unknown or mismatched peer stays refused.
     */
    private suspend fun inspectRecord(
        mode: String,
        record: BinderHub.Published,
        legacyWireOnly: Boolean = false,
    ): InspectedPublished? =
        withContext(Dispatchers.IO) {
            if (!runCatching { record.binder.pingBinder() }.getOrDefault(false)) {
                BinderHub.removeIfSame(mode, record.binder)
                BinderHub.removeStaleIfSame(mode, record.binder)
                return@withContext null
            }
            val client = FloeBinderClient(record.binder)
            val described = client.describe()
            if (described == null) {
                if (!runCatching { record.binder.pingBinder() }.getOrDefault(false)) {
                    BinderHub.removeIfSame(mode, record.binder)
                    BinderHub.removeStaleIfSame(mode, record.binder)
                    return@withContext null
                }
                return@withContext InspectedPublished(
                    record,
                    client,
                    BackendOwnershipPolicy.PublishedVerdict.Refused("describe"),
                )
            }
            if (legacyWireOnly && !BackendOwnershipPolicy.isKnownLegacyWire(
                    described.getInt(BinderProtocol.KEY_PROTOCOL, -1),
                    BinderProtocol.VERSION,
                )
            ) {
                BinderHub.removeStaleIfSame(mode, record.binder)
                return@withContext null
            }
            val verdict = BackendOwnershipPolicy.classifyPublishedHelper(
                helper = publishedHelper(record, described),
                expectedMode = mode,
                expectedProtocol = BinderProtocol.VERSION,
                hostPackage = config.packageName,
                hostSigning = config.signingSha256,
                currentVersion = config.appVersionCode,
            )
            InspectedPublished(record, client, verdict)
        }

    private suspend fun resolvePublishedForStart(
        mode: String,
        waitMillis: Long,
    ): PublishedResolution {
        // A stale helper never enters the current-owner map, so the healthy
        // published service still wins; only when no current publication
        // exists does the quarantined legacy helper get a retirement verdict.
        val inspected = inspectPublished(mode, waitMillis) ?: inspectQuarantined(mode)
            ?: return PublishedResolution.None
        return when (val verdict = inspected.verdict) {
            BackendOwnershipPolicy.PublishedVerdict.Current -> PublishedResolution.Current
            is BackendOwnershipPolicy.PublishedVerdict.Refused -> {
                PublishedResolution.Refused(verdict.code)
            }
            is BackendOwnershipPolicy.PublishedVerdict.Replace -> {
                when (val stopped = stopPublished(mode, inspected, verdict.pid)) {
                    is StaleStopResult.Stopped -> PublishedResolution.Replace(verdict.pid, false)
                    is StaleStopResult.StillAlive -> PublishedResolution.Replace(verdict.pid, true)
                    is StaleStopResult.Refused -> PublishedResolution.Refused(stopped.code)
                }
            }
        }
    }

    private suspend fun stopPublished(
        mode: String,
        inspected: InspectedPublished,
        pid: Int,
    ): StaleStopResult = withContext(Dispatchers.IO) {
        val result = inspected.client.stopOwnedService(pid)
        if (result is AccessActionResult.Failed) {
            return@withContext StaleStopResult.Refused("stop")
        }
        if (!awaitBinderDeath(inspected.client, STALE_STOP_TIMEOUT_MILLIS)) {
            return@withContext StaleStopResult.StillAlive(pid)
        }
        BinderHub.removeIfSame(mode, inspected.record.binder)
        BinderHub.removeStaleIfSame(mode, inspected.record.binder)
        if (binderMode == mode && binderPid == pid) {
            clearBinder()
            grants.clear()
            activeRequests.clear()
            if (mode == BinderProtocol.MODE_ROOT) {
                rootEnabled = false
                setRoot(BackendOwnershipPolicy.inactiveRootStatus(rootGrantVerified))
            } else {
                setAdb(adbStandbyStatus())
            }
        }
        StaleStopResult.Stopped(pid)
    }

    /**
     * A publication carrying a known older Floe wire marker reached the hub
     * but was never cached as the current owner. Queue a bounded, one-shot
     * typed retirement under the lifecycle mutex: the healthy current service
     * and the same-build reconnect are never touched, and an unverifiable
     * peer is dropped, never killed.
     */
    private fun onStaleLegacyPublished(record: BinderHub.Published) {
        if (closed.get()) return
        val mode = record.mode
        scope.launch {
            lifecycleMutex.withLock {
                if (!closed.get()) retireQuarantinedLegacy(mode)
            }
        }
    }

    /** Retire helpers quarantined before this controller instance existed. */
    private suspend fun sweepQuarantinedLegacy() {
        lifecycleMutex.withLock {
            if (closed.get()) return@withLock
            retireQuarantinedLegacy(BinderProtocol.MODE_ADB)
            retireQuarantinedLegacy(BinderProtocol.MODE_ROOT)
        }
    }

    /**
     * Retire a quarantined legacy-wire helper when — and only when — the live
     * binder proves the exact Floe identity (mode UID, PID agreement, host
     * package, signing, version) and answers with a known older wire. The
     * stop is typed (stopOwnedService with the verified PID) through the
     * quarantined binder; the current owner, its grants and every user datum
     * are untouched. Any other outcome simply drops the quarantined record.
     */
    private suspend fun retireQuarantinedLegacy(mode: String) {
        val record = BinderHub.stalePeek(mode) ?: return
        val inspected = inspectRecord(mode, record, legacyWireOnly = true) ?: return
        val verdict = inspected.verdict
        if (verdict is BackendOwnershipPolicy.PublishedVerdict.Replace) {
            stopPublished(mode, inspected, verdict.pid)
        }
        BinderHub.removeStaleIfSame(mode, record.binder)
    }

    private fun publishedHelper(
        record: BinderHub.Published,
        described: android.os.Bundle,
    ): BackendOwnershipPolicy.PublishedHelper = BackendOwnershipPolicy.PublishedHelper(
        recordMode = record.mode,
        recordUid = record.serverUid,
        recordPid = record.serverPid,
        recordVersion = record.appVersionCode,
        recordSigning = record.signingSha256,
        describedOk = BinderProtocol.isOk(described),
        describedProtocol = described.getInt(BinderProtocol.KEY_PROTOCOL, -1),
        describedMode = described.getString(BinderProtocol.KEY_SERVER_MODE),
        describedUid = described.getInt(BinderProtocol.KEY_SERVER_UID, -1),
        describedPid = described.getInt(BinderProtocol.KEY_SERVER_PID, -1),
        describedPackage = described.getString(BinderProtocol.KEY_PACKAGE),
        describedVersion = described.getLong(BinderProtocol.KEY_APP_VERSION, -1),
        describedSigning = described.getString(BinderProtocol.KEY_SIGNING_SHA256),
    )

    private suspend fun awaitBinderDeath(
        client: FloeBinderClient,
        timeoutMillis: Long,
    ): Boolean {
        val deadline = SystemClock.elapsedRealtime() + timeoutMillis
        while (SystemClock.elapsedRealtime() < deadline) {
            if (!runCatching { client.isAlive() }.getOrDefault(false)) return true
            delay(BINDER_POLL_MILLIS)
        }
        return !runCatching { client.isAlive() }.getOrDefault(false)
    }

    private suspend fun adoptBinder(mode: String, waitMillis: Long): Boolean =
        adoptBinderDetailed(mode, waitMillis) is Adoption.Adopted

    private suspend fun adoptBinderDetailed(mode: String, waitMillis: Long): Adoption =
        withContext(Dispatchers.IO) {
            if (closed.get()) return@withContext Adoption.NotPublished
            if (mode == binderMode &&
                binderClient?.let { runCatching { it.isAlive() }.getOrDefault(false) } == true
            ) {
                return@withContext Adoption.Adopted
            }
            val record = (if (waitMillis > 0) BinderHub.await(mode, waitMillis) else BinderHub.peek(mode))
                ?: return@withContext Adoption.NotPublished
            val client = FloeBinderClient(record.binder)
            val described = client.describe() ?: run {
                failAdoption(mode, "describe")
                return@withContext Adoption.Refused("describe")
            }
            val verdict = BackendOwnershipPolicy.classifyPublishedHelper(
                helper = publishedHelper(record, described),
                expectedMode = mode,
                expectedProtocol = BinderProtocol.VERSION,
                hostPackage = config.packageName,
                hostSigning = config.signingSha256,
                currentVersion = config.appVersionCode,
            )
            when (verdict) {
                BackendOwnershipPolicy.PublishedVerdict.Current -> Unit
                is BackendOwnershipPolicy.PublishedVerdict.Replace -> {
                    failAdoption(mode, "restart_required", restartRequired = true)
                    return@withContext Adoption.Refused("restart_required")
                }
                is BackendOwnershipPolicy.PublishedVerdict.Refused -> {
                    failAdoption(mode, verdict.code)
                    return@withContext Adoption.Refused(verdict.code)
                }
            }
            val previousOwner = currentOwner()
            if (mode == BinderProtocol.MODE_ADB &&
                previousOwner == BackendOwnershipPolicy.Owner.ROOT
            ) {
                // Root->ADB must go through the explicit bounded stop in
                // startAdbService; a refresh/adopt must never downgrade Root.
                setAdb(AdbStatus.Error("root backend is still active", "owner"))
                return@withContext Adoption.Refused("owner")
            }

            // One owner at a time: fence every grant/operation of the previous
            // backend before the new owner is published. Old grants are never
            // re-registered into a different privileged owner.
            val previous = binderClient
            if (previous != null) {
                fenceClient(previous)
            } else {
                grants.clear()
                activeRequests.clear()
            }
            clearBinder()
            val serverPid = described.getInt(BinderProtocol.KEY_SERVER_PID, -1)
            val serverUid = AccessPolicy.uidForMode(mode) ?: run {
                failAdoption(mode, "mode")
                return@withContext Adoption.Refused("mode")
            }
            binderClient = client
            binderMode = mode
            binderPid = serverPid
            val generation = binderGeneration.incrementAndGet()
            runCatching {
                record.binder.linkToDeath({ onServiceDied(mode, generation) }, 0)
            }
            // The binder may have died between describe and linkToDeath. Never
            // publish a dead helper as the active owner.
            if (!runCatching { client.isAlive() }.getOrDefault(false)) {
                onServiceDied(mode, generation)
                return@withContext Adoption.Refused("binder_died")
            }
            adoptedRestartRequired = false
            if (mode == BinderProtocol.MODE_ADB) {
                rootEnabled = false
                val root = if (mutableRoot.value is RootStatus.Enabled) {
                    BackendOwnershipPolicy.inactiveRootStatus(rootGrantVerified)
                } else {
                    mutableRoot.value
                }
                publish(AdbStatus.ServiceAlive(serverUid, BinderProtocol.MODE_ADB), root)
            } else {
                rootEnabled = true
                rootGrantVerified = true
                publish(adbStandbyStatus(), RootStatus.Enabled(serverUid))
            }
            Adoption.Adopted
        }

    private fun failAdoption(mode: String, code: String, restartRequired: Boolean = false) {
        if (restartRequired) adoptedRestartRequired = true
        if (mode == BinderProtocol.MODE_ADB) {
            setAdb(
                if (restartRequired) {
                    AdbStatus.RestartRequired
                } else {
                    AdbStatus.Error("Floe service identity could not be verified", code)
                },
            )
        } else {
            setRoot(RootStatus.Refused(if (restartRequired) "restart_required" else code))
        }
    }

    private fun fenceClient(client: FloeBinderClient?) {
        if (client == null) return
        val requests = activeRequests.toList()
        activeRequests.clear()
        grants.clear()
        runCatching { client.revokeAllGrants() }
        // Server revokeAll clears its cancellation map, so cancel the in-flight
        // request IDs afterwards.
        requests.forEach { runCatching { client.cancel(it) } }
    }

    private fun clearBinder() {
        binderClient = null
        binderMode = null
        binderPid = -1
        binderGeneration.incrementAndGet()
    }

    private fun onServiceDied(mode: String, generation: Long) {
        if (binderMode != mode || binderGeneration.get() != generation) return
        clearBinder()
        grants.clear()
        activeRequests.clear()
        adoptedRestartRequired = false
        if (mode == BinderProtocol.MODE_ADB) {
            val root = if (mutableRoot.value is RootStatus.Enabled) {
                BackendOwnershipPolicy.inactiveRootStatus(rootGrantVerified)
            } else {
                mutableRoot.value
            }
            publish(AdbStatus.ServiceDied("binder_died"), root)
        } else {
            rootEnabled = false
            publish(
                adbStandbyStatus(),
                BackendOwnershipPolicy.inactiveRootStatus(rootGrantVerified),
            )
        }
    }

    private fun validateGrantRequest(request: GrantRequest): String? {
        if (!request.isWellFormed()) return "grant_shape"
        val now = System.currentTimeMillis()
        if (request.expiresAtMillis <= now) return "grant_expired"
        if (request.expiresAtMillis - now > MAX_GRANT_LIFETIME_MILLIS) return "grant_lifetime"
        if (request.operations.isEmpty()) return "grant_operations"
        if (request.operations.any { SystemOperation.isPackageManagement(it) }) {
            if (!config.allowPackageManagement) return "management_disabled"
            if (!request.packageManagementAllowed) return "management"
        }
        val packages = protectedPackages
        // The host configuration is the explicit user-granted ceiling. Invalid
        // entries are dropped, and an empty ceiling never means "all paths".
        val bases = config.allowedScopeBases.mapNotNull { base ->
            val normalized = PathPolicy.normalizeBase(base) ?: return@mapNotNull null
            if (PathPolicy.validateScopeBase(normalized, packages, writable = false) != null) {
                null
            } else {
                normalized
            }
        }
        if (bases.isEmpty()) return "scope_policy"
        for (scope in request.scopes) {
            val normalized = PathPolicy.normalizeBase(scope.path) ?: return "scope_syntax"
            PathPolicy.validateScopeBase(normalized, packages, scope.writable)?.let { return it }
            if (!PathPolicy.isWithinAny(bases, normalized)) return "scope_outside_policy"
        }
        return null
    }

    private fun setAdb(status: AdbStatus) = publish(status, mutableRoot.value)

    private fun setRoot(status: RootStatus) = publish(mutableAdb.value, status)

    private fun publish(adb: AdbStatus, root: RootStatus) {
        mutableAdb.value = adb
        mutableRoot.value = root
        runtime.publish(adb, root)
    }

    private fun randomToken(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private companion object {
        const val MAX_GRANT_LIFETIME_MILLIS = 6 * 60 * 60 * 1000L

        /** Brief wait for an App-death/update republish before declaring no helper. */
        const val STALE_DISCOVERY_MILLIS = 1_500L

        /** Bounded wait for a verified typed stopServer call to exit. */
        const val STALE_STOP_TIMEOUT_MILLIS = 2_000L
        const val ROOT_STOP_TIMEOUT_MILLIS = 2_000L
        const val STOP_TIMEOUT_MILLIS = 2_000L
        const val BINDER_POLL_MILLIS = 50L
    }
}
