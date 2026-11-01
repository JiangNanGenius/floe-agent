// SPDX-License-Identifier: MPL-2.0
//
// Application-owned C05 device controller.
//
// Owns the trusted `floe.device/14` profile lane, the REAL Kotlin device
// engine (TCP/Telnet/BLE/USB), the USB permission PendingIntent receiver, the
// Bluetooth grant trigger and the per-session terminal/input pumps. Sessions
// survive Activity reconstruction because this controller is App-scoped. It is
// fenced by the live native root epoch on every request and drained before the
// root retires.
//
// Permissions are always the user's explicit platform action. Neither a model
// call nor a saved profile can mint a BLE/USB/LAN grant.

package com.floe.android.host.devicecommunication

import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import com.floe.android.core.devicecommunication.BleRequirements
import com.floe.android.core.devicecommunication.DeviceCommunicationEngine
import com.floe.android.core.devicecommunication.DeviceCommunicationException
import com.floe.android.core.devicecommunication.DeviceEndpointSpec
import com.floe.android.core.devicecommunication.DeviceErrorCode
import com.floe.android.core.devicecommunication.DeviceLimits
import com.floe.android.core.devicecommunication.DeviceOwner
import com.floe.android.core.devicecommunication.DeviceProtocol
import com.floe.android.core.devicecommunication.DeviceSessionSnapshot
import com.floe.android.core.devicecommunication.DeviceSessionState
import com.floe.android.feature.devicecommunication.DeviceConnectionUi
import com.floe.android.feature.devicecommunication.DeviceDraft
import com.floe.android.feature.devicecommunication.DeviceProblemUi
import com.floe.android.feature.devicecommunication.DeviceProfileUi
import com.floe.android.feature.devicecommunication.DeviceScreenState
import com.floe.android.feature.devicecommunication.DeviceTab
import com.floe.android.feature.devicecommunication.toDraft
import com.floe.android.feature.terminal.G04TerminalEngine
import com.floe.android.feature.terminal.TerminalEngineHost
import com.floe.android.host.remote.C05RemoteFailure
import com.floe.android.host.remote.C05RemoteOwner
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal class C05DevicesHostController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val mainDispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val currentNativeEpoch: () -> Long?,
    private val lanGate: C05DeviceLanGate? = null,
    private val client: C05DeviceClient = C05DeviceClient(),
    private val engine: DeviceCommunicationEngine = DeviceCommunicationEngine(
        context = context,
        scope = scope,
        ioDispatcher = ioDispatcher,
        currentEpoch = currentNativeEpoch,
    ),
    private val log: (String, String) -> Unit = { level, message ->
        Log.println(if (level == "error") Log.ERROR else Log.DEBUG, "FloeC05Devices", message)
    },
) {
    private val ownerToken = "ui." + UUID.randomUUID().toString()
    private val _state = MutableStateFlow(DeviceScreenState())
    val state: StateFlow<DeviceScreenState> = _state.asStateFlow()
    private val _terminal = MutableStateFlow<G04TerminalEngine?>(null)
    val terminal: StateFlow<G04TerminalEngine?> = _terminal.asStateFlow()

    private val requestCounter = AtomicLong(0)
    private val consoles = LinkedHashMap<String, LiveConsole>()
    private var loaded = false
    private var receiversRegistered = false
    private var pendingBleConnect: DeviceDraft? = null
    @Volatile private var pendingUsbDeviceKey: String? = null
    private var pendingUsbTimeout: Job? = null
    private val toolPump = C05DeviceToolHostPump(
        context = context,
        scope = scope,
        ioDispatcher = ioDispatcher,
        currentNativeEpoch = currentNativeEpoch,
        engine = engine,
        lanGate = lanGate,
    )

    private data class LiveConsole(
        val sessionId: String,
        val epoch: Long,
        val engine: G04TerminalEngine,
        val input: Channel<ByteArray>,
        var inputJob: Job? = null,
        var readJob: Job? = null,
    )

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_USB_PERMISSION -> {
                    val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    val expected = pendingUsbDeviceKey
                    pendingUsbDeviceKey = null
                    pendingUsbTimeout?.cancel()
                    pendingUsbTimeout = null
                    if (device != null && expected != null && device.deviceName == expected) {
                        if (granted) {
                            refreshUsb()
                            val pending = _state.value.draft
                            scope.launch { connectNow(pending) }
                        } else {
                            fail(
                                DeviceCommunicationException(
                                    DeviceErrorCode.PERMISSION_DENIED,
                                    "USB access was not granted.",
                                ),
                                context = "usb",
                            )
                        }
                    }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                    val name = device?.deviceName ?: return
                    engine.onUsbDetached(name)
                    refreshUsb()
                }
            }
        }
    }

    fun enter() {
        if (!loaded) {
            loaded = true
            refresh()
        }
    }

    fun refresh() {
        val epoch = currentNativeEpoch() ?: run {
            _state.update {
                it.copy(
                    loading = false,
                    coreReady = false,
                    error = DeviceProblemUi(DeviceErrorCode.RUNTIME_NOT_INSTALLED.wire),
                )
            }
            return
        }
        val token = requestCounter.incrementAndGet()
        _state.update { it.copy(loading = true, error = null) }
        scope.launch {
            try {
                val capabilities = withContext(ioDispatcher) { client.capabilities() }
                if (token != requestCounter.get()) return@launch
                if (!capabilities.coreReady) {
                    _state.update {
                        it.copy(
                            loading = false,
                            coreReady = false,
                            coreUpdateRequired = false,
                            error = null,
                        )
                    }
                    return@launch
                }
                val owner = owner(epoch)
                val profiles = withContext(ioDispatcher) { client.profiles(owner) }
                if (token != requestCounter.get() || currentNativeEpoch() != epoch) return@launch
                val requirements = withContext(ioDispatcher) {
                    runCatching { engine.bleRequirements() }.getOrNull()
                }
                val sessions = withContext(ioDispatcher) {
                    runCatching { engine.list(engineOwner(epoch)) }.getOrDefault(emptyList())
                }
                if (token != requestCounter.get()) return@launch
                _state.update {
                    it.copy(
                        loading = false,
                        coreReady = true,
                        coreUpdateRequired = false,
                        profiles = profiles.mapNotNull(::mapProfile),
                        sessions = sessions,
                        bleRequirements = requirements,
                        usbHostSupported = context.packageManager.hasSystemFeature(
                            PackageManager.FEATURE_USB_HOST,
                        ),
                    )
                }
            } catch (failure: C05RemoteFailure) {
                if (token != requestCounter.get()) return@launch
                _state.update {
                    it.copy(
                        loading = false,
                        coreReady = false,
                        coreUpdateRequired = failure.code == "needsCoreUpdate",
                        error = mapRemoteFailure(failure),
                    )
                }
            } catch (error: Throwable) {
                if (token != requestCounter.get()) return@launch
                log("error", "device profile load failed: ${error.javaClass.simpleName}")
                _state.update {
                    it.copy(
                        loading = false,
                        error = DeviceProblemUi(DeviceErrorCode.INTERNAL_FAILURE.wire),
                    )
                }
            }
        }
    }

    fun selectTab(tab: DeviceTab) {
        _state.update { it.copy(tab = tab) }
    }

    fun updateDraft(draft: DeviceDraft) {
        _state.update { it.copy(draft = draft, error = null) }
    }

    fun openConnection(connection: DeviceConnectionUi) {
        val draft = connection.toDraft()
        _state.update { it.copy(tab = connection.tab, draft = draft, error = null) }
    }

    fun openProfile(profile: DeviceProfileUi) {
        profile.connections.firstOrNull()?.let(::openConnection)
    }

    fun openSession(sessionId: String) {
        _terminal.value = consoles[sessionId]?.engine
        _state.update { it.copy(activeSessionID = sessionId) }
    }

    fun saveConnection() {
        val draft = _state.value.draft
        if (draft.tab == DeviceTab.USB) {
            fail(
                DeviceCommunicationException(
                    DeviceErrorCode.INVALID_REQUEST,
                    "USB serial devices are chosen from the attached-device list.",
                ),
            )
            return
        }
        if (draft.displayName.isBlank()) {
            fail(
                DeviceCommunicationException(
                    DeviceErrorCode.INVALID_REQUEST,
                    "Enter a name for this connection.",
                ),
            )
            return
        }
        val spec = draft.toSpecOrNull() ?: run {
            fail(
                DeviceCommunicationException(
                    DeviceErrorCode.INVALID_REQUEST,
                    "Check the connection details and try again.",
                ),
            )
            return
        }
        val epoch = currentNativeEpoch() ?: run {
            fail(DeviceCommunicationException(DeviceErrorCode.RUNTIME_NOT_INSTALLED, null))
            return
        }
        if (_state.value.busy != null) return
        _state.update { it.copy(busy = "save", error = null) }
        val profileDraft = buildProfileDraft(draft, spec)
        scope.launch {
            try {
                val owner = owner(epoch)
                val saved = withContext(ioDispatcher) {
                    client.saveProfile(profileDraft, owner)
                }
                if (currentNativeEpoch() != epoch) return@launch
                val savedConnection = saved.connections.firstOrNull {
                    it.id == draft.connectionId
                } ?: saved.connections.firstOrNull()
                _state.update {
                    it.copy(
                        busy = null,
                        draft = savedConnection?.let { connection ->
                        mapConnection(connection).copy(profileId = saved.id).toDraft()
                    } ?: it.draft,
                    )
                }
                refresh()
            } catch (failure: C05RemoteFailure) {
                fail(mapRemoteFailure(failure), busy = null)
            } catch (error: Throwable) {
                fail(
                    DeviceCommunicationException(DeviceErrorCode.INTERNAL_FAILURE, null),
                    busy = null,
                )
            }
        }
    }

    fun deleteProfile(profileId: String) {
        val epoch = currentNativeEpoch() ?: return
        if (_state.value.busy != null) return
        _state.update { it.copy(busy = "delete", error = null) }
        scope.launch {
            try {
                withContext(ioDispatcher) { client.deleteProfile(profileId, owner(epoch)) }
                if (currentNativeEpoch() != epoch) return@launch
                _state.update { it.copy(busy = null) }
                refresh()
            } catch (failure: C05RemoteFailure) {
                fail(mapRemoteFailure(failure), busy = null)
            } catch (_: Throwable) {
                fail(
                    DeviceCommunicationException(DeviceErrorCode.INTERNAL_FAILURE, null),
                    busy = null,
                )
            }
        }
    }

    fun connect() {
        val draft = _state.value.draft
        scope.launch { connectNow(draft) }
    }

    private suspend fun connectNow(draft: DeviceDraft) {
        if (_state.value.busy != null) return
        val epoch = currentNativeEpoch() ?: run {
            fail(DeviceCommunicationException(DeviceErrorCode.RUNTIME_NOT_INSTALLED, null))
            return
        }
        val spec = draft.toSpecOrNull() ?: run {
            fail(
                DeviceCommunicationException(
                    DeviceErrorCode.INVALID_REQUEST,
                    "Check the connection details and try again.",
                ),
            )
            return
        }
        when (spec.protocol) {
            DeviceProtocol.BLE -> {
                val requirements = withContext(ioDispatcher) {
                    runCatching { engine.bleRequirements() }.getOrNull()
                } ?: run {
                    fail(DeviceCommunicationException(DeviceErrorCode.BLUETOOTH_UNAVAILABLE, null))
                    return
                }
                if (!requirements.supported) {
                    fail(DeviceCommunicationException(DeviceErrorCode.UNSUPPORTED, null))
                    return
                }
                if (requirements.missingPermissions.isNotEmpty()) {
                    pendingBleConnect = draft
                    _state.update {
                        it.copy(
                            permissionRequest = com.floe.android.feature.devicecommunication
                                .DevicePermissionRequestUi(requirements.missingPermissions),
                            busy = null,
                        )
                    }
                    return
                }
                if (!requirements.enabled) {
                    fail(
                        DeviceCommunicationException(
                            DeviceErrorCode.BLUETOOTH_DISABLED,
                            "Bluetooth is off.",
                        ),
                        context = "ble",
                    )
                    return
                }
                if (requirements.requiresLocationServices && !requirements.locationServicesEnabled) {
                    fail(
                        DeviceCommunicationException(
                            DeviceErrorCode.PERMISSION_REQUIRED,
                            "Location services are off.",
                        ),
                        context = "ble",
                    )
                    return
                }
            }
            DeviceProtocol.USB -> {
                val owner = engineOwner(epoch)
                val devices = withContext(ioDispatcher) {
                    runCatching { engine.usbDevices(owner) }.getOrDefault(emptyList())
                }
                val selected = devices.firstOrNull { it.key == spec.usbDeviceName }
                if (selected == null) {
                    fail(DeviceCommunicationException(DeviceErrorCode.DEVICE_NOT_FOUND, null))
                    return
                }
                if (selected.driverName == null) {
                    fail(DeviceCommunicationException(DeviceErrorCode.DRIVER_NOT_FOUND, null))
                    return
                }
                if (!selected.permissionGranted) {
                    requestUsbPermission(selected.key)
                    return
                }
            }
            DeviceProtocol.TCP, DeviceProtocol.TELNET -> {
                val endpoint = "${spec.host}:${spec.port}"
                val gate = lanGate
                if (gate != null && gate.isLocalLikely(endpoint) && gate.blocksConnectHop(endpoint)) {
                    fail(
                        DeviceCommunicationException(
                            DeviceErrorCode.LOCAL_NETWORK_PERMISSION_REQUIRED,
                            "Local network access is required.",
                        ),
                        context = "lan",
                    )
                    return
                }
            }
        }
        _state.update { it.copy(busy = "connect", error = null, permissionRequest = null) }
        try {
            val owner = engineOwner(epoch)
            val snapshot = withContext(ioDispatcher) { engine.open(owner, spec) }
            if (currentNativeEpoch() != epoch) {
                runCatching { withContext(ioDispatcher) { engine.close(owner, snapshot.id) } }
                fail(DeviceCommunicationException(DeviceErrorCode.STALE_EPOCH, null), busy = null)
                return
            }
            val created = withContext(mainDispatcher) {
                consoleFor(snapshot.id, epoch)
            }
            pendingBleConnect = null
            _state.update {
                it.copy(
                    busy = null,
                    activeSessionID = snapshot.id,
                    sessions = mergeSession(it.sessions, snapshot),
                    draft = it.draft.copy(
                        connectionId = it.draft.connectionId,
                    ),
                )
            }
            _terminal.value = created.engine
            startConsole(created)
        } catch (error: DeviceCommunicationException) {
            fail(error, busy = null, context = permissionContext(error))
        } catch (error: Throwable) {
            log("error", "device connect failed: ${error.javaClass.simpleName}")
            fail(
                DeviceCommunicationException(DeviceErrorCode.CONNECT_FAILED, null),
                busy = null,
            )
        }
    }

    fun closeSession() {
        val sessionId = _state.value.activeSessionID ?: return
        val epoch = currentNativeEpoch() ?: return
        val console = consoles.remove(sessionId)
        console?.input?.close()
        console?.inputJob?.cancel()
        console?.readJob?.cancel()
        if (_terminal.value === console?.engine) _terminal.value = null
        _state.update {
            it.copy(
                activeSessionID = null,
                sessions = it.sessions.filterNot { session -> session.id == sessionId },
            )
        }
        scope.launch {
            try {
                val report = withContext(ioDispatcher) {
                    engine.close(engineOwner(epoch), sessionId)
                }
                if (!report.complete) {
                    fail(
                        DeviceCommunicationException(
                            DeviceErrorCode.CLEANUP_INCOMPLETE,
                            "Some device resources could not be closed yet.",
                        ),
                        retryable = true,
                    )
                }
            } catch (_: Throwable) {
                // The session may already be gone; the list refresh is the
                // honest projection.
            }
            refreshSessions()
        }
    }

    fun scan() {
        if (_state.value.busy != null) return
        val epoch = currentNativeEpoch() ?: return
        _state.update { it.copy(busy = "scan", error = null) }
        scope.launch {
            try {
                val results = withContext(ioDispatcher) {
                    engine.scanBle(engineOwner(epoch), 5_000)
                }
                _state.update { it.copy(busy = null, bleScan = results) }
            } catch (error: DeviceCommunicationException) {
                fail(error, busy = null, context = permissionContext(error))
            } catch (_: Throwable) {
                fail(
                    DeviceCommunicationException(DeviceErrorCode.BLUETOOTH_UNAVAILABLE, null),
                    busy = null,
                )
            }
        }
    }

    fun refreshUsb() {
        if (_state.value.busy != null) return
        val epoch = currentNativeEpoch() ?: return
        _state.update { it.copy(busy = "usb", error = null) }
        scope.launch {
            try {
                val devices = withContext(ioDispatcher) {
                    engine.usbDevices(engineOwner(epoch))
                }
                _state.update { it.copy(busy = null, usbDevices = devices) }
            } catch (error: DeviceCommunicationException) {
                fail(error, busy = null, context = permissionContext(error))
            } catch (_: Throwable) {
                fail(
                    DeviceCommunicationException(DeviceErrorCode.UNSUPPORTED, null),
                    busy = null,
                )
            }
        }
    }

    fun requestUsbPermission(deviceKey: String) {
        val manager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: run {
            fail(DeviceCommunicationException(DeviceErrorCode.UNSUPPORTED, null))
            return
        }
        val device = manager.deviceList[deviceKey] ?: run {
            fail(DeviceCommunicationException(DeviceErrorCode.DEVICE_NOT_FOUND, null))
            return
        }
        if (manager.hasPermission(device)) {
            refreshUsb()
            scope.launch { connectNow(_state.value.draft) }
            return
        }
        pendingUsbDeviceKey = deviceKey
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            deviceKey.hashCode(),
            Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
            flags,
        )
        try {
            manager.requestPermission(device, pendingIntent)
        } catch (_: Throwable) {
            pendingUsbDeviceKey = null
            fail(
                DeviceCommunicationException(
                    DeviceErrorCode.PERMISSION_DENIED,
                    "The USB permission dialog could not be opened.",
                ),
                context = "usb",
            )
            return
        }
        pendingUsbTimeout?.cancel()
        pendingUsbTimeout = scope.launch {
            delay(60_000)
            if (pendingUsbDeviceKey == deviceKey) {
                pendingUsbDeviceKey = null
                fail(
                    DeviceCommunicationException(
                        DeviceErrorCode.TIMED_OUT,
                        "The USB permission request timed out.",
                    ),
                    context = "usb",
                )
            }
        }
    }

    fun requestBlePermissions() {
        val requirements = _state.value.bleRequirements
            ?: runCatching { engine.bleRequirements() }.getOrNull()
            ?: return
        if (requirements.missingPermissions.isNotEmpty()) {
            _state.update {
                it.copy(
                    permissionRequest = com.floe.android.feature.devicecommunication
                        .DevicePermissionRequestUi(requirements.missingPermissions),
                )
            }
        } else if (!requirements.enabled) {
            fail(
                DeviceCommunicationException(
                    DeviceErrorCode.BLUETOOTH_DISABLED,
                    "Bluetooth is off.",
                ),
                context = "ble",
            )
        }
    }

    fun onBluetoothEnableRequested(): Boolean {
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE)
            as? android.bluetooth.BluetoothManager)?.adapter ?: return false
        return runCatching { adapter.isEnabled }.getOrDefault(false)
    }

    fun onBlePermissionResult(granted: Boolean) {
        _state.update { it.copy(permissionRequest = null) }
        if (granted) {
            val pending = pendingBleConnect
            pendingBleConnect = null
            if (pending != null) {
                scope.launch { connectNow(pending) }
            } else {
                refreshBleRequirements()
            }
        } else {
            pendingBleConnect = null
            fail(
                DeviceCommunicationException(
                    DeviceErrorCode.PERMISSION_DENIED,
                    "Nearby devices permission was not granted.",
                ),
                context = "ble",
            )
        }
    }

    fun onBluetoothEnableResult(enabled: Boolean) {
        if (enabled) {
            refreshBleRequirements()
            pendingBleConnect?.let { draft ->
                pendingBleConnect = null
                scope.launch { connectNow(draft) }
            }
        } else {
            fail(
                DeviceCommunicationException(
                    DeviceErrorCode.BLUETOOTH_DISABLED,
                    "Bluetooth was not turned on.",
                ),
                context = "ble",
            )
        }
    }

    fun send(text: String, appendNewline: Boolean) {
        if (text.isEmpty()) return
        var bytes = text.toByteArray(Charsets.UTF_8)
        if (appendNewline) bytes += '\n'.code.toByte()
        enqueueInput(bytes)
    }

    fun consoleInput(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        enqueueInput(bytes)
    }

    fun consoleResize(columns: Int, rows: Int) {
        // TCP/BLE/USB device streams have no PTY window size; the reused
        // terminal renderer only adjusts its own local grid.
    }

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    fun onOwnedStoreReady() {
        val epoch = currentNativeEpoch() ?: return
        engine.bindEpoch(epoch)
        registerReceivers()
        toolPump.start(epoch)
        refresh()
    }

    fun onRootStopped() {
        unregisterReceivers()
        cancelAllConsoles()
        toolPump.stop()
        _state.update {
            DeviceScreenState(
                loading = false,
                coreReady = false,
                tab = it.tab,
                draft = it.draft,
                sessionLimit = it.sessionLimit,
            )
        }
        _terminal.value = null
    }

    suspend fun prepareForRootStop(waitMillis: Long = 5_000L): Boolean {
        val epoch = currentNativeEpoch() ?: engine.boundEpoch().takeIf { it > 0 } ?: return true
        cancelAllConsoles()
        toolPump.stopAndJoin(epoch, waitMillis)
        val report = withTimeoutOrNull(waitMillis + 1_000L) {
            engine.rootStop(epoch, waitMillis)
        } ?: return false
        if (report.complete) {
            _state.update {
                it.copy(
                    busy = null,
                    activeSessionID = null,
                    sessions = emptyList(),
                )
            }
            _terminal.value = null
        }
        return report.complete
    }

    private fun startConsole(console: LiveConsole) {
        console.inputJob = scope.launch(ioDispatcher) {
            for (chunk in console.input) {
                if (currentNativeEpoch() != console.epoch) break
                try {
                    engine.write(engineOwner(console.epoch), console.sessionId, chunk)
                } catch (error: DeviceCommunicationException) {
                    withContext(mainDispatcher) {
                        fail(error, context = permissionContext(error))
                    }
                    break
                } catch (_: Throwable) {
                    break
                }
            }
        }
        console.readJob = scope.launch(ioDispatcher) {
            var tick = 0
            while (isActive) {
                if (currentNativeEpoch() != console.epoch) break
                val bytes = try {
                    engine.read(engineOwner(console.epoch), console.sessionId, READ_PAGE_BYTES)
                } catch (_: Throwable) {
                    break
                }
                if (bytes.isNotEmpty()) {
                    withContext(mainDispatcher) {
                        console.engine.feed(bytes)
                        _state.update { it.copy(consoleRevision = it.consoleRevision + 1) }
                    }
                }
                tick += 1
                if (tick % 8 == 0) {
                    val snapshots = runCatching {
                        engine.list(engineOwner(console.epoch))
                    }.getOrNull()
                    if (snapshots != null) {
                        withContext(mainDispatcher) {
                            _state.update {
                                it.copy(
                                    sessions = snapshots,
                                    activeSessionID = it.activeSessionID
                                        ?.takeIf { id -> snapshots.any { s -> s.id == id } },
                                )
                            }
                        }
                        val current = snapshots.firstOrNull { it.id == console.sessionId }
                        if (current == null ||
                            current.state == DeviceSessionState.CLOSED ||
                            current.state == DeviceSessionState.FAILED
                        ) {
                            break
                        }
                    }
                }
                delay(READ_INTERVAL_MILLIS)
            }
        }
    }

    private fun consoleFor(sessionId: String, epoch: Long): LiveConsole =
        consoles.getOrPut(sessionId) {
            val engine = G04TerminalEngine(
                initialColumns = 100,
                initialRows = 30,
                host = object : TerminalEngineHost {
                    override fun writeToPty(bytes: ByteArray) {
                        if (bytes.isNotEmpty()) enqueueInput(bytes, sessionId)
                    }

                    override fun log(level: String, message: String) {
                        log(level, "terminal $sessionId: ${message.take(200)}")
                    }
                },
            )
            LiveConsole(
                sessionId = sessionId,
                epoch = epoch,
                engine = engine,
                input = Channel(capacity = 64),
            )
        }

    private fun enqueueInput(bytes: ByteArray, sessionId: String? = null) {
        val id = sessionId ?: _state.value.activeSessionID ?: return
        val console = consoles[id] ?: return
        if (bytes.size > DeviceLimits.MAXIMUM_WRITE_BYTES) {
            var offset = 0
            while (offset < bytes.size) {
                val end = minOf(offset + DeviceLimits.MAXIMUM_WRITE_BYTES, bytes.size)
                if (console.input.trySend(bytes.copyOfRange(offset, end)).isFailure) {
                    fail(
                        DeviceCommunicationException(
                            DeviceErrorCode.INPUT_FULL,
                            "The device input buffer is full.",
                        ),
                    )
                    return
                }
                offset = end
            }
            return
        }
        if (console.input.trySend(bytes.copyOf()).isFailure) {
            fail(
                DeviceCommunicationException(
                    DeviceErrorCode.INPUT_FULL,
                    "The device input buffer is full.",
                ),
            )
        }
    }

    private fun cancelAllConsoles() {
        consoles.values.forEach { console ->
            console.input.close()
            console.inputJob?.cancel()
            console.readJob?.cancel()
        }
        consoles.clear()
        _terminal.value = null
    }

    private suspend fun refreshSessions() {
        val epoch = currentNativeEpoch() ?: return
        val snapshots = runCatching { engine.list(engineOwner(epoch)) }.getOrNull() ?: return
        _state.update {
            it.copy(
                sessions = snapshots,
                activeSessionID = it.activeSessionID?.takeIf { id ->
                    snapshots.any { session -> session.id == id }
                },
            )
        }
    }

    private fun refreshBleRequirements() {
        val epoch = currentNativeEpoch() ?: return
        _state.update { it.copy(busy = "ble") }
        scope.launch {
            val requirements = withContext(ioDispatcher) {
                runCatching { engine.bleRequirements() }.getOrNull()
            }
            _state.update { it.copy(busy = null, bleRequirements = requirements) }
        }
    }

    private fun buildProfileDraft(
        draft: DeviceDraft,
        spec: DeviceEndpointSpec,
    ): C05DeviceProfileDraft {
        val existing = draft.profileId?.let { id -> _state.value.profiles.firstOrNull { it.id == id } }
        val connection = C05DeviceConnectionDraft(
            id = draft.connectionId ?: UUID.randomUUID().toString(),
            displayName = draft.displayName,
            kind = C05DeviceClient.kindFor(spec.protocol),
            host = spec.host,
            port = spec.port,
            peripheralAddress = spec.bleAddress,
            serviceUuid = spec.bleServiceUuid,
            writeUuid = spec.bleWriteUuid,
            notifyUuid = spec.bleNotifyUuid,
        )
        val connections = existing?.connections?.map { saved ->
            if (saved.id == draft.connectionId) connection else C05DeviceConnectionDraft(
                id = saved.id,
                displayName = saved.displayName,
                kind = when (saved.tab) {
                    DeviceTab.TCP -> "tcp"
                    DeviceTab.TELNET -> "telnet"
                    DeviceTab.BLE -> "bluetoothSerial"
                    DeviceTab.USB -> "usbSerial"
                },
                host = saved.host,
                port = saved.port,
                peripheralAddress = saved.peripheralAddress,
                serviceUuid = saved.serviceUuid,
                writeUuid = saved.writeUuid,
                notifyUuid = saved.notifyUuid,
            )
        }?.toMutableList() ?: mutableListOf()
        if (connections.none { it.id == connection.id }) connections.add(connection)
        return C05DeviceProfileDraft(
            id = existing?.id,
            displayName = existing?.displayName ?: draft.displayName,
            connections = connections,
        )
    }

    private fun mapProfile(profile: C05DeviceProfile): DeviceProfileUi? {
        val connections = profile.connections.mapNotNull { connection ->
            mapConnectionOrNull(connection)?.copy(profileId = profile.id)
        }
        if (connections.isEmpty()) return null
        return DeviceProfileUi(
            id = profile.id,
            displayName = profile.displayName,
            connections = connections,
        )
    }

    private fun mapConnectionOrNull(connection: C05DeviceConnection): DeviceConnectionUi? {
        val tab = when (connection.kind) {
            "tcp" -> DeviceTab.TCP
            "telnet" -> DeviceTab.TELNET
            "bluetoothSerial" -> DeviceTab.BLE
            else -> return null
        }
        return DeviceConnectionUi(
            id = connection.id,
            profileId = "",
            displayName = connection.displayName,
            tab = tab,
            host = connection.host,
            port = connection.port,
            peripheralAddress = connection.peripheralAddress,
            serviceUuid = connection.serviceUuid,
            writeUuid = connection.writeUuid,
            notifyUuid = connection.notifyUuid,
        )
    }

    private fun mapConnection(connection: C05DeviceConnection): DeviceConnectionUi {
        val tab = when (connection.kind) {
            "telnet" -> DeviceTab.TELNET
            "bluetoothSerial" -> DeviceTab.BLE
            else -> DeviceTab.TCP
        }
        return DeviceConnectionUi(
            id = connection.id,
            profileId = "",
            displayName = connection.displayName,
            tab = tab,
            host = connection.host,
            port = connection.port,
            peripheralAddress = connection.peripheralAddress,
            serviceUuid = connection.serviceUuid,
            writeUuid = connection.writeUuid,
            notifyUuid = connection.notifyUuid,
        )
    }

    private fun owner(epoch: Long): C05RemoteOwner =
        C05RemoteOwner(token = ownerToken, nativeEpoch = epoch)

    private fun engineOwner(epoch: Long): DeviceOwner =
        DeviceOwner(token = ownerToken, nativeEpoch = epoch)

    private fun mergeSession(
        sessions: List<DeviceSessionSnapshot>,
        snapshot: DeviceSessionSnapshot,
    ): List<DeviceSessionSnapshot> = sessions.filterNot { it.id == snapshot.id } + snapshot

    private fun permissionContext(error: DeviceCommunicationException): String? = when (error.code) {
        DeviceErrorCode.PERMISSION_REQUIRED,
        DeviceErrorCode.PERMISSION_DENIED,
        DeviceErrorCode.BLUETOOTH_DISABLED,
        -> "ble"
        DeviceErrorCode.LOCAL_NETWORK_PERMISSION_REQUIRED -> "lan"
        else -> null
    }

    private fun mapRemoteFailure(failure: C05RemoteFailure): DeviceProblemUi = when (failure.code) {
        "needsCoreUpdate" -> DeviceProblemUi(DeviceErrorCode.RUNTIME_NOT_INSTALLED.wire)
        "staleEpoch" -> DeviceProblemUi(DeviceErrorCode.STALE_EPOCH.wire)
        "profileNotFound" -> DeviceProblemUi(DeviceErrorCode.DEVICE_NOT_FOUND.wire)
        "profileLimit" -> DeviceProblemUi(DeviceErrorCode.INVALID_REQUEST.wire)
        "invalidProfile", "invalidRequest" -> DeviceProblemUi(DeviceErrorCode.INVALID_REQUEST.wire)
        "cancelled" -> DeviceProblemUi(DeviceErrorCode.CANCELLED.wire)
        "timedOut" -> DeviceProblemUi(DeviceErrorCode.TIMED_OUT.wire)
        else -> DeviceProblemUi(
            DeviceErrorCode.INTERNAL_FAILURE.wire,
            failure.detail,
            failure.retryable,
        )
    }

    private fun fail(
        problem: DeviceProblemUi,
        busy: String? = _state.value.busy,
    ) {
        _state.update { it.copy(busy = busy, error = problem) }
    }

    private fun fail(
        error: DeviceCommunicationException,
        busy: String? = _state.value.busy,
        retryable: Boolean = error.retryable,
        context: String? = null,
    ) {
        _state.update {
            it.copy(
                busy = busy,
                error = DeviceProblemUi(
                    code = error.code.wire,
                    detail = error.userSafeDetail(),
                    retryable = retryable,
                    context = context,
                ),
            )
        }
    }

    private fun registerReceivers() {
        if (receiversRegistered) return
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(usbReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(usbReceiver, filter)
            }
            receiversRegistered = true
        } catch (error: Throwable) {
            log("error", "device receiver registration failed: ${error.javaClass.simpleName}")
        }
        val bluetoothReceiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context?, intent: Intent?) {
                if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)
                if (state == BluetoothAdapter.STATE_OFF) {
                    engine.onBluetoothOff()
                    refreshSessionsAsync()
                }
            }
        }
        BluetoothStateReceiverHolder.receiver = bluetoothReceiver
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(
                    bluetoothReceiver,
                    IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                    Context.RECEIVER_NOT_EXPORTED,
                )
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(
                    bluetoothReceiver,
                    IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                )
            }
            BluetoothStateReceiverHolder.registered = true
        } catch (_: Throwable) {
            // The adapter state read on the next action is still honest.
        }
    }

    private fun unregisterReceivers() {
        if (receiversRegistered) {
            runCatching { context.unregisterReceiver(usbReceiver) }
            receiversRegistered = false
        }
        if (BluetoothStateReceiverHolder.registered) {
            BluetoothStateReceiverHolder.receiver?.let {
                runCatching { context.unregisterReceiver(it) }
            }
            BluetoothStateReceiverHolder.registered = false
            BluetoothStateReceiverHolder.receiver = null
        }
        pendingUsbTimeout?.cancel()
        pendingUsbDeviceKey = null
    }

    private fun refreshSessionsAsync() {
        scope.launch { refreshSessions() }
    }

    private object BluetoothStateReceiverHolder {
        var receiver: BroadcastReceiver? = null
        var registered: Boolean = false
    }

    companion object {
        const val ACTION_USB_PERMISSION = "com.floe.android.devicecommunication.USB_PERMISSION"
        private const val READ_PAGE_BYTES = 16 * 1024
        private const val READ_INTERVAL_MILLIS = 120L
    }
}
