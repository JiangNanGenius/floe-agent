// SPDX-License-Identifier: MPL-2.0
//
// Real Android BLE GATT serial-style session.
//
// * permissions are checked by the engine before this class is constructed;
// * connect + service discovery + CCCD subscription are a bounded sequence;
// * every read/write is single-flight through [BleOperationSerializer];
// * a close increments the generation fence, so a late binder callback from
//   the old connection can never mutate the current session or append bytes
//   after the user/owner closed it;
// * notifications are accumulated in one bounded queue; the MTU-derived
//   payload limit gates every write chunk.

package com.floe.android.core.devicecommunication

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

internal class AndroidBleSession(
    private val context: Context,
    private val device: BluetoothDevice,
    private val serviceUuid: UUID,
    private val writeUuid: UUID,
    private val notifyUuid: UUID?,
    private val readUuid: UUID?,
    private val record: DeviceSessionRecord,
    private val listener: DeviceTransportListener,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val clock: () -> Long = { System.currentTimeMillis() },
) : DeviceTransport {
    private val queue = BoundedByteQueue(DeviceLimits.MAXIMUM_BUFFERED_BYTES)
    private val fence = GenerationFence()
    private val generation = fence.next()
    private val serializer = BleOperationSerializer()
    @Volatile private var closed = false
    @Volatile private var gatt: BluetoothGatt? = null
    @Volatile private var writeCharacteristic: BluetoothGattCharacteristic? = null
    @Volatile private var notifyCharacteristic: BluetoothGattCharacteristic? = null
    @Volatile private var readCharacteristic: BluetoothGattCharacteristic? = null
    @Volatile private var mtu = DeviceLimits.BLE_DEFAULT_MTU
    private var connectSignal: CompletableDeferred<Unit>? = null
    private var servicesSignal: CompletableDeferred<Unit>? = null
    private var writeSignal: CompletableDeferred<Unit>? = null
    private var readSignal: CompletableDeferred<ByteArray>? = null
    private var mtuSignal: CompletableDeferred<Int>? = null
    private val signalLock = Any()

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (!fence.isCurrent(generation)) return
            this@AndroidBleSession.gatt = gatt
            if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                signal(connectSignal) { it.complete(Unit) }
                if (!gatt.discoverServices()) {
                    fail(DeviceErrorCode.PROTOCOL_ERROR, "The BLE service discovery did not start.")
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (!closed) {
                    term(DeviceSessionState.CLOSED, null, "The Bluetooth device disconnected.")
                }
            } else if (status != BluetoothGatt.GATT_SUCCESS) {
                fail(DeviceErrorCode.CONNECT_FAILED, "The Bluetooth connection failed (${status}).")
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (!fence.isCurrent(generation)) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                fail(DeviceErrorCode.PROTOCOL_ERROR, "BLE service discovery failed (${status}).")
                return
            }
            val service = gatt.getService(serviceUuid) ?: run {
                fail(DeviceErrorCode.DEVICE_NOT_FOUND, "The configured GATT service was not found.")
                return
            }
            val write = service.characteristics.firstOrNull {
                it.uuid == writeUuid && it.hasWriteProperty()
            } ?: run {
                fail(DeviceErrorCode.DEVICE_NOT_FOUND, "The configured GATT write characteristic was not found.")
                return
            }
            writeCharacteristic = write
            val notify = notifyUuid?.let { wanted ->
                service.characteristics.firstOrNull { it.uuid == wanted } ?: run {
                    fail(DeviceErrorCode.DEVICE_NOT_FOUND, "The configured GATT notify characteristic was not found.")
                    return
                }
            }
            notifyCharacteristic = notify
            readCharacteristic = readUuid?.let { wanted ->
                service.characteristics.firstOrNull { it.uuid == wanted } ?: run {
                    fail(DeviceErrorCode.DEVICE_NOT_FOUND, "The configured GATT read characteristic was not found.")
                    return
                }
            }
            if (notify == null) {
                signal(servicesSignal) { it.complete(Unit) }
                return
            }
            if (!gatt.setCharacteristicNotification(notify, true)) {
                fail(DeviceErrorCode.PROTOCOL_ERROR, "Notification registration was refused.")
                return
            }
            val descriptor = notify.getDescriptor(CCCD_UUID)
            if (descriptor == null) {
                fail(DeviceErrorCode.PROTOCOL_ERROR, "The notify characteristic has no CCCD descriptor.")
                return
            }
            writeDescriptor(gatt, descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (!fence.isCurrent(generation)) return
            if (descriptor.uuid != CCCD_UUID) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                record.notificationSubscribed = true
                signal(servicesSignal) { it.complete(Unit) }
            } else {
                fail(DeviceErrorCode.PROTOCOL_ERROR, "Notification subscription failed (${status}).")
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (!fence.isCurrent(generation)) return
            signal(mtuSignal) { it.complete(if (status == BluetoothGatt.GATT_SUCCESS) mtu else DeviceLimits.BLE_DEFAULT_MTU) }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (!fence.isCurrent(generation) || characteristic.uuid != writeUuid) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                signal(writeSignal) { it.complete(Unit) }
            } else {
                signal(writeSignal) { it.completeExceptionally(protocol("BLE write failed (${status}).")) }
            }
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            handleRead(characteristic, value, status)
        }

        @Deprecated("Deprecated in Android 13; retained for API 28-32.")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            handleRead(characteristic, characteristic.value, status)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            handleNotification(characteristic, value)
        }

        @Deprecated("Deprecated in Android 13; retained for API 28-32.")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            handleNotification(characteristic, characteristic.value)
        }

        private fun handleRead(
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            if (!fence.isCurrent(generation) || characteristic.uuid != readUuid) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                val copy = value.copyOf()
                signal(readSignal) { it.complete(copy) }
            } else {
                signal(readSignal) { it.completeExceptionally(protocol("BLE read failed (${status}).")) }
            }
        }

        private fun handleNotification(
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (!fence.isCurrent(generation) || closed) return
            if (notifyUuid == null || characteristic.uuid != notifyUuid) return
            val copy = BleGattBounds.notificationCopy(value) ?: return
            queue.append(copy)
            record.addBytesIn(copy.size.toLong())
            record.lastActivityMillis = clock()
            listener.onTransportActivity(record)
        }
    }

    suspend fun open(timeoutMillis: Long): AndroidBleSession {
        val connected = CompletableDeferred<Unit>()
        connectSignal = connected
        val gatt = try {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } catch (error: SecurityException) {
            throw DeviceCommunicationException(
                DeviceErrorCode.PERMISSION_REQUIRED,
                "Nearby devices permission is required for Bluetooth.",
            )
        }
        this.gatt = gatt
        try {
            withTimeout(timeoutMillis) { connected.await() }
            val services = CompletableDeferred<Unit>()
            servicesSignal = services
            withTimeout(timeoutMillis) { services.await() }
            requestMtu()
            record.bleServiceUuid = serviceUuid.toString()
            record.bleMtu = mtu
            record.notificationSubscribed = notifyUuid != null
            listener.onTransportConnected(record)
            return this
        } catch (error: TimeoutCancellationException) {
            closeNow()
            throw DeviceCommunicationException(
                DeviceErrorCode.TIMED_OUT,
                "The Bluetooth connection timed out.",
                retryable = true,
            )
        } catch (error: Throwable) {
            closeNow()
            if (error is DeviceCommunicationException) throw error
            throw DeviceCommunicationException(
                DeviceErrorCode.CONNECT_FAILED,
                "The Bluetooth connection could not be established.",
                retryable = true,
            )
        }
    }

    private suspend fun requestMtu() {
        val current = gatt ?: return
        val signal = CompletableDeferred<Int>()
        mtuSignal = signal
        val accepted = current.requestMtu(247)
        if (!accepted) {
            mtu = DeviceLimits.BLE_DEFAULT_MTU
            return
        }
        mtu = try {
            withTimeout(3_000) { signal.await() }
        } catch (_: TimeoutCancellationException) {
            DeviceLimits.BLE_DEFAULT_MTU
        }
    }

    override suspend fun read(maxBytes: Int): ByteArray {
        if (maxBytes <= 0) return ByteArray(0)
        val buffered = queue.drain(minOf(maxBytes, DeviceLimits.MAXIMUM_READ_BYTES))
        if (buffered.isNotEmpty()) {
            record.lastActivityMillis = clock()
            return buffered
        }
        val characteristic = readCharacteristic ?: return ByteArray(0)
        if (!characteristic.hasReadProperty()) return ByteArray(0)
        return serializer.run(generation, fence) {
            val current = gatt ?: throw closedError()
            val signal = CompletableDeferred<ByteArray>()
            readSignal = signal
            val accepted = current.readCharacteristic(characteristic)
            if (!accepted) throw protocol("BLE read could not start.")
            try {
                val value = withTimeout(READ_TIMEOUT_MILLIS) { signal.await() }
                record.addBytesIn(value.size.toLong())
                record.lastActivityMillis = clock()
                listener.onTransportActivity(record)
                value.copyOf(minOf(value.size, DeviceLimits.MAXIMUM_READ_BYTES))
            } catch (_: TimeoutCancellationException) {
                throw DeviceCommunicationException(
                    DeviceErrorCode.TIMED_OUT,
                    "The Bluetooth read timed out.",
                    retryable = true,
                )
            }
        }
    }

    override suspend fun write(bytes: ByteArray): Int {
        if (bytes.isEmpty()) return 0
        val plan = BleGattBounds.planWrite(bytes, mtu)
        return serializer.run(generation, fence) {
            val current = gatt ?: throw closedError()
            val characteristic = writeCharacteristic ?: throw closedError()
            for (chunk in plan.chunks) {
                if (characteristic.hasWriteProperty()) {
                    val signal = CompletableDeferred<Unit>()
                    writeSignal = signal
                    val started = if (Build.VERSION.SDK_INT >= 33) {
                        current.writeCharacteristic(
                            characteristic,
                            chunk,
                            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                        ) == BluetoothGatt.GATT_SUCCESS
                    } else {
                        @Suppress("DEPRECATION")
                        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                        @Suppress("DEPRECATION")
                        characteristic.value = chunk
                        @Suppress("DEPRECATION")
                        current.writeCharacteristic(characteristic)
                    }
                    if (!started) throw protocol("BLE write could not start.")
                    try {
                        withTimeout(WRITE_TIMEOUT_MILLIS) { signal.await() }
                    } catch (_: TimeoutCancellationException) {
                        throw DeviceCommunicationException(
                            DeviceErrorCode.TIMED_OUT,
                            "The Bluetooth write timed out.",
                            retryable = true,
                        )
                    }
                } else {
                    if (Build.VERSION.SDK_INT >= 33) {
                        current.writeCharacteristic(
                            characteristic,
                            chunk,
                            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE,
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                        @Suppress("DEPRECATION")
                        characteristic.value = chunk
                        @Suppress("DEPRECATION")
                        current.writeCharacteristic(characteristic)
                    }
                }
            }
            record.addBytesOut(bytes.size.toLong())
            record.lastActivityMillis = clock()
            listener.onTransportActivity(record)
            bytes.size
        }
    }

    override suspend fun close(): DeviceDrainReport {
        if (closed) {
            return DeviceDrainReport(closed = true, complete = true, pendingBytes = queue.bufferedBytes)
        }
        closed = true
        fence.next()
        val pending = queue.bufferedBytes
        val current = gatt
        val notification = notifyCharacteristic
        runCatching {
            if (current != null && notification != null) {
                current.setCharacteristicNotification(notification, false)
            }
        }
        val hadGatt = current != null
        val disconnected = hadGatt && runCatching { current?.disconnect() }.isSuccess
        val closedGatt = hadGatt && runCatching { current?.close() }.isSuccess
        queue.clear()
        listener.onTransportTerminated(record, DeviceSessionState.CLOSED, null, null)
        return DeviceDrainReport(
            closed = disconnected || closedGatt,
            complete = closedGatt || current == null,
            pendingBytes = pending,
        )
    }

    private fun closeNow() {
        closed = true
        fence.next()
        runCatching { gatt?.disconnect() }
        runCatching { gatt?.close() }
        gatt = null
        queue.clear()
    }

    private fun term(state: DeviceSessionState, code: DeviceErrorCode?, detail: String?) {
        if (closed) return
        if (code != null) {
            failSignal(code, detail ?: "The Bluetooth session ended.")
        }
        closed = true
        fence.next()
        runCatching { gatt?.close() }
        listener.onTransportTerminated(record, state, code, detail)
    }

    private fun fail(code: DeviceErrorCode, detail: String) {
        term(DeviceSessionState.FAILED, code, detail)
    }

    private fun failSignal(code: DeviceErrorCode, detail: String) {
        val error = DeviceCommunicationException(code, detail)
        signal(connectSignal) { it.completeExceptionally(error) }
        signal(servicesSignal) { it.completeExceptionally(error) }
        signal(writeSignal) { it.completeExceptionally(error) }
        signal(readSignal) { it.completeExceptionally(error) }
        signal(mtuSignal) { it.complete(DeviceLimits.BLE_DEFAULT_MTU) }
    }

    private inline fun <T> signal(
        target: CompletableDeferred<T>?,
        action: (CompletableDeferred<T>) -> Unit,
    ) {
        synchronized(signalLock) { target?.let(action) }
    }

    private fun writeDescriptor(
        gatt: BluetoothGatt,
        descriptor: BluetoothGattDescriptor,
        value: ByteArray,
    ) {
        val started = if (Build.VERSION.SDK_INT >= 33) {
            gatt.writeDescriptor(descriptor, value) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = value
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(descriptor)
        }
        if (!started) fail(DeviceErrorCode.PROTOCOL_ERROR, "Notification subscription could not start.")
    }

    private fun protocol(detail: String) = DeviceCommunicationException(
        DeviceErrorCode.PROTOCOL_ERROR,
        detail,
        retryable = true,
    )

    private fun closedError() = DeviceCommunicationException(
        DeviceErrorCode.SESSION_CLOSING,
        "The Bluetooth session is no longer connected.",
        retryable = true,
    )

    private fun BluetoothGattCharacteristic.hasWriteProperty(): Boolean =
        properties and (BluetoothGattCharacteristic.PROPERTY_WRITE or
            BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0

    private fun BluetoothGattCharacteristic.hasReadProperty(): Boolean =
        properties and BluetoothGattCharacteristic.PROPERTY_READ != 0

    companion object {
        val CCCD_UUID: UUID = UUID.fromString(DeviceLimits.BLE_CCCD_UUID)
        private const val READ_TIMEOUT_MILLIS = 5_000L
        private const val WRITE_TIMEOUT_MILLIS = 5_000L

        suspend fun open(
            context: Context,
            device: BluetoothDevice,
            serviceUuid: String,
            writeUuid: String,
            notifyUuid: String?,
            readUuid: String?,
            record: DeviceSessionRecord,
            listener: DeviceTransportListener,
            scope: CoroutineScope,
            ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
            timeoutMillis: Long = DeviceLimits.CONNECT_TIMEOUT_MILLIS,
            clock: () -> Long = { System.currentTimeMillis() },
        ): AndroidBleSession {
            val service = UUID.fromString(serviceUuid)
            val write = UUID.fromString(writeUuid)
            val notify = notifyUuid?.let(UUID::fromString)
            val read = readUuid?.let(UUID::fromString)
            val session = AndroidBleSession(
                context, device, service, write, notify, read, record, listener, scope, ioDispatcher, clock,
            )
            return session.open(timeoutMillis)
        }
    }
}
