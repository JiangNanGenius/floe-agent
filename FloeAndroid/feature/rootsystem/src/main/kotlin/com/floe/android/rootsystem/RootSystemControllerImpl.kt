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
import com.floe.android.rootsystem.policy.ProtectedTargets
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
        scope.launch { refresh() }
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
        if (!hasTrust) return AccessActionResult.Denied("pair_required")

        val port = requestedPort ?: config.connectPort ?: connectPort
            ?: withContext(Dispatchers.IO) { discovery.findConnectPort() }
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
            if (adoptBinder(BinderProtocol.MODE_ADB, 0)) {
                return AccessActionResult.Ok
            }
            setAdb(AdbStatus.Error("existing ADB service identity could not be adopted", "identity"))
            return AccessActionResult.Failed("service_identity")
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

        val identity = try {
            pairing.identity()
        } catch (e: IdentityException) {
            BinderHub.clearExpectedToken(BinderProtocol.MODE_ADB)
            return AccessActionResult.Denied(e.code)
        }

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
        } catch (_: Throwable) {
            false
        }

        if (!launched) {
            BinderHub.clearExpectedToken(BinderProtocol.MODE_ADB)
            setAdb(AdbStatus.Paired(port))
            return AccessActionResult.Failed("adb_connect")
        }
        if (adoptBinder(BinderProtocol.MODE_ADB, 12_000)) {
            // Keep the launch token: a same-token republish by this verified
            // server is accepted, while an older helper's token is rejected.
            return AccessActionResult.Ok
        }
        BinderHub.clearExpectedToken(BinderProtocol.MODE_ADB)
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
    ): RootResult<PackageQuery> = dispatch(claim, SystemOperation.PACKAGE_QUERY, packageName) { client ->
        client.packageQuery(claim, packageName, includeSystem, maxEntries.coerceIn(1, BinderProtocol.MAX_LIST))
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

    suspend fun cancelOperation(claim: OperationClaim): AccessActionResult {
        if (!claim.isWellFormed()) return AccessActionResult.Denied("claim_shape")
        val client = binderClient ?: return AccessActionResult.Ok
        withContext(Dispatchers.IO) { client.cancel(claim.requestId) }
        return AccessActionResult.Ok
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
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
        if (operation == SystemOperation.PACKAGE_FORCE_STOP && !grant.packageManagementAllowed) {
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
    private suspend fun inspectPublished(mode: String, waitMillis: Long): InspectedPublished? =
        withContext(Dispatchers.IO) {
            val record = (if (waitMillis > 0) BinderHub.await(mode, waitMillis) else BinderHub.peek(mode))
                ?: return@withContext null
            if (!runCatching { record.binder.pingBinder() }.getOrDefault(false)) {
                BinderHub.removeIfSame(mode, record.binder)
                return@withContext null
            }
            val client = FloeBinderClient(record.binder)
            val described = client.describe()
            if (described == null) {
                if (!runCatching { record.binder.pingBinder() }.getOrDefault(false)) {
                    BinderHub.removeIfSame(mode, record.binder)
                    return@withContext null
                }
                return@withContext InspectedPublished(
                    record,
                    client,
                    BackendOwnershipPolicy.PublishedVerdict.Refused("describe"),
                )
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
        val inspected = inspectPublished(mode, waitMillis) ?: return PublishedResolution.None
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
        withContext(Dispatchers.IO) {
            if (closed.get()) return@withContext false
            if (mode == binderMode &&
                binderClient?.let { runCatching { it.isAlive() }.getOrDefault(false) } == true
            ) {
                return@withContext true
            }
            val record = (if (waitMillis > 0) BinderHub.await(mode, waitMillis) else BinderHub.peek(mode))
                ?: return@withContext false
            val client = FloeBinderClient(record.binder)
            val described = client.describe() ?: run {
                failAdoption(mode, "describe")
                return@withContext false
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
                    return@withContext false
                }
                is BackendOwnershipPolicy.PublishedVerdict.Refused -> {
                    failAdoption(mode, verdict.code)
                    return@withContext false
                }
            }
            val previousOwner = currentOwner()
            if (mode == BinderProtocol.MODE_ADB &&
                previousOwner == BackendOwnershipPolicy.Owner.ROOT
            ) {
                // Root->ADB must go through the explicit bounded stop in
                // startAdbService; a refresh/adopt must never downgrade Root.
                setAdb(AdbStatus.Error("root backend is still active", "owner"))
                return@withContext false
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
            val serverUid = AccessPolicy.uidForMode(mode) ?: return@withContext false
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
                return@withContext false
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
            true
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
        if (SystemOperation.PACKAGE_FORCE_STOP in request.operations) {
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
