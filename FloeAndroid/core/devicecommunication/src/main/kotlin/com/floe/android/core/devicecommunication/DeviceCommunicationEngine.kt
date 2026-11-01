// SPDX-License-Identifier: MPL-2.0
//
// C05 device communication engine. This is the ONE process-wide owner of real
// TCP/Telnet sockets, BLE GATT connections and USB serial ports for a native
// root epoch. It never asks for a permission, never opens a dialog and never
// executes a model instruction by itself: callers are the App-owned device
// controller and the trusted model-tool pump, both of which supply an explicit
// owner token and the live native epoch.
//
// Session ownership is per-token and per-epoch. A model run can only list,
// read, write or close sessions it created; a UI controller likewise. Root
// stop closes every session for the retiring epoch and reports an honest
// incomplete drain instead of pretending a socket/GATT/port is gone.

package com.floe.android.core.devicecommunication

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import com.hoho.android.usbserial.driver.UsbSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

class DeviceCommunicationEngine(
    private val context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val currentEpoch: () -> Long?,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val scanner: AndroidBleScanner = AndroidBleScanner(context),
) {
    private val registry = DeviceSessionRegistry()
    private val transports = HashMap<String, DeviceTransport>()
    private val transportLock = Any()
    @Volatile private var boundEpoch: Long = 0L
    private val maintenance: Job = scope.launch(ioDispatcher) {
        while (isActive) {
            delay(60_000)
            cleanupIdle()
        }
    }

    private val listener = object : DeviceTransportListener {
        override fun onTransportConnected(record: DeviceSessionRecord) {
            record.state = DeviceSessionState.CONNECTED
            record.errorCode = null
            record.errorDetail = null
            record.lastActivityMillis = clock()
        }

        override fun onTransportActivity(record: DeviceSessionRecord) {
            record.lastActivityMillis = clock()
        }

        override fun onTransportTerminated(
            record: DeviceSessionRecord,
            state: DeviceSessionState,
            code: DeviceErrorCode?,
            detail: String?,
        ) {
            record.state = state
            record.errorCode = code?.wire
            record.errorDetail = detail?.take(200)
            record.lastActivityMillis = clock()
        }
    }

    fun bindEpoch(epoch: Long): Boolean {
        if (epoch <= 0L) return false
        boundEpoch = epoch
        return true
    }

    fun boundEpoch(): Long = boundEpoch

    fun dispose() {
        maintenance.cancel()
        val records = synchronized(transportLock) { transports.keys.toList() }
        records.forEach { id ->
            synchronized(transportLock) { transports.remove(id) }
            registry.remove(id)
        }
        registry.clear()
    }

    suspend fun capabilities(): DeviceCapabilities = withContext(ioDispatcher) {
        val requirements = scanner.requirements()
        val usbHostSupported = context.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
        val attached = if (usbHostSupported) {
            runCatching { usbManager()?.deviceList?.size ?: 0 }.getOrDefault(0)
        } else {
            0
        }
        DeviceCapabilities(
            bleSupported = requirements.supported,
            bleEnabled = requirements.enabled,
            bleMissingPermissions = requirements.missingPermissions,
            usbHostSupported = usbHostSupported,
            attachedUsbDevices = attached,
            maximumSessions = DeviceLimits.MAXIMUM_SESSIONS,
            maximumReadBytes = DeviceLimits.MAXIMUM_READ_BYTES,
            maximumWriteBytes = DeviceLimits.MAXIMUM_WRITE_BYTES,
            maximumExchangeBytes = DeviceLimits.MAXIMUM_EXCHANGE_BYTES,
            sessionIdleTimeoutMillis = DeviceLimits.SESSION_IDLE_TIMEOUT_MILLIS,
        )
    }

    fun bleRequirements(): BleRequirements = scanner.requirements()

    suspend fun scanBle(owner: DeviceOwner, durationMillis: Long): List<BleScanResult> {
        requireEpoch(owner)
        return scanner.scan(
            durationMillis = durationMillis,
            maximumResults = DeviceLimits.MAXIMUM_SCAN_RESULTS,
        )
    }

    suspend fun usbDevices(owner: DeviceOwner): List<UsbDeviceInfo> {
        requireEpoch(owner)
        return withContext(ioDispatcher) { enumerateUsb() }
    }

    suspend fun open(owner: DeviceOwner, spec: DeviceEndpointSpec): DeviceSessionSnapshot {
        requireEpoch(owner)
        val validated = DeviceEndpointValidation.validate(spec)
        val endpoint = when (validated.protocol) {
            DeviceProtocol.TCP, DeviceProtocol.TELNET ->
                DeviceTargetPolicy.endpointLabel(validated.protocol, validated.host, validated.port)
            DeviceProtocol.BLE -> validated.bleAddress ?: "BLE"
            DeviceProtocol.USB -> validated.usbDeviceName ?: "USB"
        }
        val record = registry.register(owner, validated.protocol, endpoint, clock())
        record.bleAddress = validated.bleAddress
        record.usbDeviceName = validated.usbDeviceName
        val transport: DeviceTransport
        try {
            transport = when (validated.protocol) {
                DeviceProtocol.TCP, DeviceProtocol.TELNET -> TcpTelnetSession.openAndConnect(
                    record = record,
                    host = validated.host!!,
                    port = validated.port!!,
                    listener = listener,
                    scope = scope,
                    ioDispatcher = ioDispatcher,
                    clock = clock,
                )
                DeviceProtocol.BLE -> openBle(record, validated)
                DeviceProtocol.USB -> openUsb(record, validated)
            }
        } catch (error: DeviceCommunicationException) {
            registry.remove(record.id)
            throw error
        } catch (error: Throwable) {
            registry.remove(record.id)
            throw DeviceCommunicationException(
                DeviceErrorCode.CONNECT_FAILED,
                "The device connection could not be opened.",
                retryable = true,
            )
        }
        synchronized(transportLock) { transports[record.id] = transport }
        return record.snapshot()
    }

    suspend fun read(owner: DeviceOwner, sessionId: String, maxBytes: Int): ByteArray {
        val current = requireEpoch(owner)
        val record = registry.require(sessionId, owner, current)
        val transport = transport(record.id) ?: throw DeviceCommunicationException(
            DeviceErrorCode.SESSION_NOT_FOUND,
            "The device session is no longer open.",
        )
        return transport.read(maxBytes.coerceIn(1, DeviceLimits.MAXIMUM_READ_BYTES))
    }

    suspend fun write(owner: DeviceOwner, sessionId: String, bytes: ByteArray): Int {
        val current = requireEpoch(owner)
        val record = registry.require(sessionId, owner, current)
        val transport = transport(record.id) ?: throw DeviceCommunicationException(
            DeviceErrorCode.SESSION_NOT_FOUND,
            "The device session is no longer open.",
        )
        return transport.write(bytes)
    }

    suspend fun close(owner: DeviceOwner, sessionId: String): DeviceDrainReport {
        val current = requireEpoch(owner)
        val record = registry.require(sessionId, owner, current)
        val transport = transport(record.id) ?: run {
            registry.remove(record.id)
            return DeviceDrainReport(closed = true, complete = true, pendingBytes = 0)
        }
        val report = withTimeoutOrNull(DeviceLimits.CLOSE_JOIN_TIMEOUT_MILLIS + 1_000L) {
            transport.close()
        } ?: DeviceDrainReport(closed = false, complete = false, pendingBytes = 0)
        if (report.complete) {
            synchronized(transportLock) { transports.remove(record.id) }
            registry.remove(record.id)
        } else {
            record.state = DeviceSessionState.FAILED
            record.errorCode = DeviceErrorCode.CLEANUP_INCOMPLETE.wire
            record.errorDetail = "Some device resources could not be closed yet."
        }
        return report
    }

    fun list(owner: DeviceOwner): List<DeviceSessionSnapshot> {
        val epoch = currentEpoch() ?: 0L
        return registry.list(owner, epoch).map { it.snapshot() }
    }

    fun status(owner: DeviceOwner, sessionId: String): DeviceSessionSnapshot {
        val epoch = currentEpoch()
            ?: throw DeviceCommunicationException(DeviceErrorCode.STALE_EPOCH, null)
        return registry.require(sessionId, owner, epoch).snapshot()
    }

    suspend fun rootStop(expectedEpoch: Long, waitMillis: Long = 5_000L): DeviceRootStopReport {
        if (expectedEpoch <= 0L) {
            return DeviceRootStopReport(false, 0, 0, 0)
        }
        var closed = 0
        var failed = 0
        var pending = 0
        val records = registry.forEpoch(expectedEpoch)
        val complete = withTimeoutOrNull(waitMillis) {
            for (record in records) {
                val transport = transport(record.id)
                if (transport == null) {
                    registry.remove(record.id)
                    closed += 1
                    continue
                }
                val report = runCatching { transport.close() }.getOrNull()
                if (report?.complete == true) {
                    synchronized(transportLock) { transports.remove(record.id) }
                    registry.remove(record.id)
                    closed += 1
                } else {
                    failed += 1
                    pending += report?.pendingBytes ?: 0
                    record.state = DeviceSessionState.FAILED
                    record.errorCode = DeviceErrorCode.CLEANUP_INCOMPLETE.wire
                    record.errorDetail = "The device did not confirm closure."
                }
            }
            true
        } ?: false
        return DeviceRootStopReport(
            complete = complete && registry.forEpoch(expectedEpoch).isEmpty(),
            closedSessions = closed,
            failedSessions = failed,
            pendingBytes = pending,
        )
    }

    /** A USB detach is an OS fact, not a user action: close owned sessions
     * for that exact device and surface `notAttached`; never keep reading a
     * stale connection. */
    fun onUsbDetached(deviceName: String): Int {
        val matches = registry.all().filter {
            it.protocol == DeviceProtocol.USB && it.usbDeviceName == deviceName
        }
        matches.forEach { record ->
            val transport = transport(record.id)
            scope.launch(ioDispatcher) {
                runCatching { transport?.close() }
                synchronized(transportLock) { transports.remove(record.id) }
                record.state = DeviceSessionState.FAILED
                record.errorCode = DeviceErrorCode.NOT_ATTACHED.wire
                record.errorDetail = "The USB serial device was detached."
            }
        }
        return matches.size
    }

    /** Bluetooth being turned off invalidates every GATT connection. */
    fun onBluetoothOff(): Int {
        val matches = registry.all().filter { it.protocol == DeviceProtocol.BLE }
        matches.forEach { record ->
            val transport = transport(record.id)
            scope.launch(ioDispatcher) {
                runCatching { transport?.close() }
                synchronized(transportLock) { transports.remove(record.id) }
                record.state = DeviceSessionState.FAILED
                record.errorCode = DeviceErrorCode.BLUETOOTH_DISABLED.wire
                record.errorDetail = "Bluetooth was turned off."
            }
        }
        return matches.size
    }

    private suspend fun openBle(record: DeviceSessionRecord, spec: DeviceEndpointSpec): DeviceTransport {
        val requirements = scanner.requirements()
        if (!requirements.supported) {
            throw DeviceCommunicationException(
                DeviceErrorCode.UNSUPPORTED,
                "This device does not support Bluetooth Low Energy.",
            )
        }
        if (requirements.missingPermissions.isNotEmpty()) {
            throw DeviceCommunicationException(
                DeviceErrorCode.PERMISSION_REQUIRED,
                "Nearby devices permission is required for Bluetooth.",
            )
        }
        if (!requirements.enabled) {
            throw DeviceCommunicationException(
                DeviceErrorCode.BLUETOOTH_DISABLED,
                "Turn on Bluetooth to connect to this device.",
            )
        }
        val adapter = bluetoothAdapter() ?: throw DeviceCommunicationException(
            DeviceErrorCode.BLUETOOTH_UNAVAILABLE,
            "Bluetooth is unavailable.",
        )
        val device = try {
            adapter.getRemoteDevice(spec.bleAddress!!)
        } catch (_: IllegalArgumentException) {
            throw DeviceCommunicationException(
                DeviceErrorCode.INVALID_TARGET,
                "The Bluetooth address is invalid.",
            )
        } catch (_: SecurityException) {
            throw DeviceCommunicationException(
                DeviceErrorCode.PERMISSION_REQUIRED,
                "Nearby devices permission is required for Bluetooth.",
            )
        }
        return AndroidBleSession.open(
            context = context,
            device = device,
            serviceUuid = spec.bleServiceUuid!!,
            writeUuid = spec.bleWriteUuid!!,
            notifyUuid = spec.bleNotifyUuid,
            readUuid = spec.bleReadUuid,
            record = record,
            listener = listener,
            scope = scope,
            ioDispatcher = ioDispatcher,
            clock = clock,
        )
    }

    private suspend fun openUsb(record: DeviceSessionRecord, spec: DeviceEndpointSpec): DeviceTransport =
        withContext(ioDispatcher) {
            val manager = usbManager() ?: throw DeviceCommunicationException(
                DeviceErrorCode.UNSUPPORTED,
                "USB host mode is not available on this device.",
            )
            val deviceName = spec.usbDeviceName!!
            val device = manager.deviceList[deviceName] ?: throw DeviceCommunicationException(
                DeviceErrorCode.DEVICE_NOT_FOUND,
                "The USB serial device is no longer attached.",
            )
            val driver = usbDriver(manager, deviceName) ?: throw DeviceCommunicationException(
                DeviceErrorCode.DRIVER_NOT_FOUND,
                "No supported USB serial driver matched this device.",
            )
            AndroidUsbSerialSession.open(
                record = record,
                manager = manager,
                device = device,
                driverPorts = driver.ports,
                portIndex = spec.usbPortIndex,
                parity = parityConstant(spec.parity),
                baudRate = spec.baudRate,
                dataBits = spec.dataBits,
                stopBits = spec.stopBits,
                listener = listener,
                scope = scope,
                ioDispatcher = ioDispatcher,
                clock = clock,
            )
        }

    private fun enumerateUsb(): List<UsbDeviceInfo> {
        val manager = usbManager() ?: return emptyList()
        val drivers = runCatching {
            UsbSerialProber.getDefaultProber().findAllDrivers(manager)
                .associateBy { it.device.deviceName }
        }.getOrDefault(emptyMap())
        return manager.deviceList.values
            .take(DeviceLimits.MAXIMUM_USB_DEVICES)
            .map { device ->
                val driver: UsbSerialDriver? = drivers[device.deviceName]
                UsbDeviceInfo(
                    key = device.deviceName,
                    vendorId = device.vendorId,
                    productId = device.productId,
                    productName = runCatching { device.productName }.getOrNull()?.take(120),
                    manufacturerName = runCatching { device.manufacturerName }.getOrNull()?.take(120),
                    serialNumber = runCatching { device.serialNumber }.getOrNull()?.take(80),
                    driverName = driver?.javaClass?.simpleName,
                    portCount = driver?.ports?.size ?: 0,
                    permissionGranted = runCatching { manager.hasPermission(device) }.getOrDefault(false),
                    attached = true,
                )
            }
            .sortedBy { it.key }
    }

    private fun usbDriver(manager: UsbManager, deviceName: String): UsbSerialDriver? =
        runCatching {
            UsbSerialProber.getDefaultProber().findAllDrivers(manager)
                .firstOrNull { it.device.deviceName == deviceName }
        }.getOrNull()

    private fun usbManager(): UsbManager? =
        context.getSystemService(Context.USB_SERVICE) as? UsbManager

    private fun bluetoothAdapter(): BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun parityConstant(parity: DeviceParity): Int = when (parity) {
        DeviceParity.NONE -> UsbSerialPort.PARITY_NONE
        DeviceParity.ODD -> UsbSerialPort.PARITY_ODD
        DeviceParity.EVEN -> UsbSerialPort.PARITY_EVEN
        DeviceParity.MARK -> UsbSerialPort.PARITY_MARK
        DeviceParity.SPACE -> UsbSerialPort.PARITY_SPACE
    }

    private fun requireEpoch(owner: DeviceOwner): Long {
        val current = currentEpoch()
        if (current == null || current <= 0L) {
            throw DeviceCommunicationException(
                DeviceErrorCode.STALE_EPOCH,
                "The local runtime is not ready. Try again.",
                retryable = true,
            )
        }
        if (owner.nativeEpoch != current) {
            throw DeviceCommunicationException(
                DeviceErrorCode.STALE_EPOCH,
                "The local runtime restarted. Try again.",
                retryable = true,
            )
        }
        return current
    }

    private fun transport(sessionId: String): DeviceTransport? =
        synchronized(transportLock) { transports[sessionId] }

    private suspend fun cleanupIdle() {
        val cutoff = clock() - DeviceLimits.SESSION_IDLE_TIMEOUT_MILLIS
        val idle = registry.idleBefore(cutoff)
        for (record in idle) {
            val transport = transport(record.id)
            val report = runCatching { transport?.close() }.getOrNull()
            if (report == null || report.complete) {
                synchronized(transportLock) { transports.remove(record.id) }
                registry.remove(record.id)
            }
        }
    }

    /** Readiness is honest about platform support and the live epoch; a
     * feature that is absent or unpermitted is never reported ready. */
    fun readinessJson(): String {
        val requirements = runCatching { scanner.requirements() }.getOrNull()
        val usbSupported = runCatching {
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
        }.getOrDefault(false)
        val epoch = currentEpoch() ?: 0L
        val objectJson = buildString {
            append("{\"version\":1,\"epoch\":").append(epoch)
            append(",\"bound\":").append(boundEpoch > 0 && boundEpoch == epoch)
            append(",\"bleSupported\":").append(requirements?.supported == true)
            append(",\"bleEnabled\":").append(requirements?.enabled == true)
            append(",\"blePermissionsMissing\":").append(requirements?.missingPermissions?.size ?: 0)
            append(",\"usbHostSupported\":").append(usbSupported)
            append(",\"sessions\":").append(registry.size)
            append("}")
        }
        return objectJson
    }
}
