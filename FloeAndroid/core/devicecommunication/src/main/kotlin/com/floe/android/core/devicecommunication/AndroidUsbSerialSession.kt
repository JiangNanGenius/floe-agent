// SPDX-License-Identifier: MPL-2.0
//
// Real Android USB-host serial session over the pinned
// usb-serial-for-android 3.11.0 library. Permission is always the per-device
// UsbManager grant obtained by the App's explicit PendingIntent flow; this
// class never requests it and never falls back to root/ADB.

package com.floe.android.core.devicecommunication

import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import com.hoho.android.usbserial.driver.SerialTimeoutException
import com.hoho.android.usbserial.driver.UsbSerialPort
import java.io.IOException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

internal class AndroidUsbSerialSession(
    private val record: DeviceSessionRecord,
    private val device: UsbDevice,
    private val port: UsbSerialPort,
    private val connection: UsbDeviceConnection,
    private val listener: DeviceTransportListener,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val clock: () -> Long = { System.currentTimeMillis() },
) : DeviceTransport {
    private val queue = BoundedByteQueue(DeviceLimits.MAXIMUM_BUFFERED_BYTES)
    @Volatile private var closed = false
    private var readerJob: Job? = null
    @Volatile private var readerStopped = false
    private val writeLock = Any()

    fun start() {
        record.bleServiceUuid = null
        record.usbVendorId = device.vendorId
        record.usbProductId = device.productId
        listener.onTransportConnected(record)
        readerJob = scope.launch(ioDispatcher) { readLoop() }
    }

    private fun readLoop() {
        val buffer = ByteArray(4 * 1024)
        while (!closed) {
            try {
                val count = port.read(buffer, DeviceLimits.USB_READ_TIMEOUT_MILLIS)
                if (count > 0) {
                    queue.append(buffer.copyOf(count))
                    record.addBytesIn(count.toLong())
                    record.lastActivityMillis = clock()
                    listener.onTransportActivity(record)
                }
            } catch (_: SerialTimeoutException) {
                // Normal bounded polling interval.
            } catch (error: Throwable) {
                if (!closed) terminate(DeviceSessionState.FAILED, classify(error))
                break
            }
        }
        readerStopped = true
    }

    override suspend fun read(maxBytes: Int): ByteArray {
        if (maxBytes <= 0) return ByteArray(0)
        val bytes = queue.drain(minOf(maxBytes, DeviceLimits.MAXIMUM_READ_BYTES))
        if (bytes.isNotEmpty()) record.lastActivityMillis = clock()
        return bytes
    }

    override suspend fun write(bytes: ByteArray): Int {
        if (bytes.isEmpty()) return 0
        if (bytes.size > DeviceLimits.MAXIMUM_USB_WRITE_TOTAL) {
            throw DeviceCommunicationException(
                DeviceErrorCode.INVALID_REQUEST,
                "A USB serial write is limited to ${DeviceLimits.MAXIMUM_USB_WRITE_TOTAL / 1024} KiB.",
            )
        }
        if (closed || record.state != DeviceSessionState.CONNECTED) {
            throw DeviceCommunicationException(
                DeviceErrorCode.SESSION_CLOSING,
                "The USB serial session is no longer connected.",
                retryable = true,
            )
        }
        return try {
            synchronized(writeLock) {
                port.write(bytes, DeviceLimits.USB_WRITE_TIMEOUT_MILLIS)
            }
            record.addBytesOut(bytes.size.toLong())
            record.lastActivityMillis = clock()
            listener.onTransportActivity(record)
            bytes.size
        } catch (error: Throwable) {
            throw classify(error)
        }
    }

    override suspend fun close(): DeviceDrainReport {
        if (closed) {
            return DeviceDrainReport(readerStopped, readerStopped, queue.bufferedBytes)
        }
        closed = true
        val pending = queue.bufferedBytes
        val portClosed = runCatching { port.close() }.isSuccess
        val connectionClosed = runCatching { connection.close() }.isSuccess
        val joined = withTimeoutOrNull(DeviceLimits.CLOSE_JOIN_TIMEOUT_MILLIS) {
            readerJob?.join()
            true
        } ?: false
        val complete = joined && readerStopped && portClosed && connectionClosed
        queue.clear()
        if (complete) {
            listener.onTransportTerminated(record, DeviceSessionState.CLOSED, null, null)
        }
        return DeviceDrainReport(closed = portClosed && connectionClosed, complete = complete, pendingBytes = pending)
    }

    private fun terminate(state: DeviceSessionState, error: DeviceCommunicationException?) {
        if (closed) return
        closed = true
        listener.onTransportTerminated(record, state, error?.code, error?.detail)
    }

    private fun classify(error: Throwable): DeviceCommunicationException = when (error) {
        is SecurityException -> DeviceCommunicationException(
            DeviceErrorCode.PERMISSION_DENIED,
            "USB permission for this device was not granted.",
        )
        is SerialTimeoutException -> DeviceCommunicationException(
            DeviceErrorCode.TIMED_OUT,
            "The USB serial write timed out.",
            retryable = true,
        )
        is IOException -> DeviceCommunicationException(
            DeviceErrorCode.IO_FAILED,
            "The USB serial connection ended.",
            retryable = true,
        )
        else -> DeviceCommunicationException(
            DeviceErrorCode.CONNECT_FAILED,
            "The USB serial port could not be opened.",
            retryable = true,
        )
    }

    companion object {
        fun open(
            record: DeviceSessionRecord,
            manager: UsbManager,
            device: UsbDevice,
            driverPorts: List<UsbSerialPort>,
            portIndex: Int,
            parity: Int,
            baudRate: Int,
            dataBits: Int,
            stopBits: Int,
            listener: DeviceTransportListener,
            scope: CoroutineScope,
            ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
            clock: () -> Long = { System.currentTimeMillis() },
        ): AndroidUsbSerialSession {
            if (!manager.hasPermission(device)) {
                throw DeviceCommunicationException(
                    DeviceErrorCode.PERMISSION_REQUIRED,
                    "Allow USB access to this device, then try again.",
                )
            }
            val port = driverPorts.getOrNull(portIndex) ?: throw DeviceCommunicationException(
                DeviceErrorCode.DRIVER_NOT_FOUND,
                "This USB device does not expose the selected serial port.",
            )
            val connection = manager.openDevice(device) ?: throw DeviceCommunicationException(
                DeviceErrorCode.IO_FAILED,
                "The USB serial device could not be opened.",
                retryable = true,
            )
            try {
                port.open(connection)
                port.setParameters(baudRate, dataBits, stopBits, parity)
                runCatching { port.dtr = true }
                runCatching { port.rts = true }
            } catch (error: Throwable) {
                runCatching { port.close() }
                runCatching { connection.close() }
                throw DeviceCommunicationException(
                    DeviceErrorCode.CONNECT_FAILED,
                    "The USB serial port could not be configured.",
                    retryable = true,
                )
            }
            val session = AndroidUsbSerialSession(
                record, device, port, connection, listener, scope, ioDispatcher, clock,
            )
            session.start()
            return session
        }
    }
}
