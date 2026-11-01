// SPDX-License-Identifier: MPL-2.0
//
// Trusted Kotlin host pump for the C05 device model-tool mailbox.
//
// Swift owns the tickets and derives ownership from the runtime-issued
// ToolContext. This pump performs the REAL Android operation and returns one
// bounded reply. It never accepts a task/run/epoch from model JSON as
// authority: the descriptor's values are rechecked against the live epoch and
// the ticket's cancellation state, and side-effecting operations require the
// approval grant the Swift side already recorded.

package com.floe.android.host.devicecommunication

import android.content.Context
import android.util.Log
import com.floe.android.core.devicecommunication.BleScanResult
import com.floe.android.core.devicecommunication.C05DeviceToolNative
import com.floe.android.core.devicecommunication.DeviceCommunicationEngine
import com.floe.android.core.devicecommunication.DeviceCommunicationException
import com.floe.android.core.devicecommunication.DeviceDrainReport
import com.floe.android.core.devicecommunication.DeviceEndpointSpec
import com.floe.android.core.devicecommunication.DeviceEndpointValidation
import com.floe.android.core.devicecommunication.DeviceErrorCode
import com.floe.android.core.devicecommunication.DeviceLimits
import com.floe.android.core.devicecommunication.DeviceOwner
import com.floe.android.core.devicecommunication.DeviceParity
import com.floe.android.core.devicecommunication.DeviceProtocol
import com.floe.android.core.devicecommunication.DeviceRootStopReport
import com.floe.android.core.devicecommunication.DeviceSessionSnapshot
import com.floe.android.core.devicecommunication.DeviceTargetPolicy
import com.floe.android.core.devicecommunication.UsbDeviceInfo
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

internal class C05DeviceToolHostPump(
    private val context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val currentNativeEpoch: () -> Long?,
    private val engine: DeviceCommunicationEngine,
    private val lanGate: C05DeviceLanGate? = null,
    private val log: (String, String) -> Unit = { level, message ->
        Log.println(if (level == "error") Log.ERROR else Log.DEBUG, "FloeC05DeviceTools", message)
    },
) {
    private val json = Json { ignoreUnknownKeys = true }
    @Volatile private var boundEpoch: Long = 0L
    @Volatile private var running = false
    private var loop: Job? = null

    fun start(epoch: Long): Boolean {
        if (epoch <= 0L) return false
        if (running && boundEpoch == epoch) return true
        if (running) stop()
        val status = try {
            C05DeviceToolNative.bind(epoch)
        } catch (error: Throwable) {
            log("error", "device tool bind failed: ${error.javaClass.simpleName}")
            -1
        }
        if (status != 0) return false
        boundEpoch = epoch
        running = true
        loop = scope.launch(ioDispatcher) { runLoop(epoch) }
        return true
    }

    fun stop() {
        val epoch = boundEpoch
        running = false
        loop?.cancel()
        loop = null
        if (epoch > 0L) {
            runCatching { C05DeviceToolNative.close(epoch) }
        }
        boundEpoch = 0L
    }

    suspend fun stopAndJoin(epoch: Long, waitMillis: Long) {
        running = false
        val active = loop
        loop = null
        if (epoch > 0L) {
            runCatching { C05DeviceToolNative.close(epoch) }
        }
        if (active != null) {
            withTimeoutOrNull(waitMillis) { active.cancelAndJoin() }
        }
        if (boundEpoch == epoch) boundEpoch = 0L
    }

    private suspend fun runLoop(epoch: Long) {
        try {
        while (scope.isActive && running && boundEpoch == epoch) {
            val claim = try {
                C05DeviceToolNative.next(NEXT_TIMEOUT_MILLIS)
            } catch (error: Throwable) {
                log("error", "device tool next failed: ${error.javaClass.simpleName}")
                break
            }
            if (claim <= 0L) continue
            if (C05DeviceToolNative.isLive(claim) == 0) continue
            val descriptorBytes = C05DeviceToolNative.describe(claim)
            val descriptor = descriptorBytes?.let { decodeObject(it) }
            if (descriptor == null) {
                complete(claim, failure("descriptorInvalid", "The device request was invalid."))
                continue
            }
            if (C05DeviceToolNative.shouldStop(claim) != 0) {
                complete(claim, failure("cancelled", "The device operation was cancelled."))
                continue
            }
            val payload = C05DeviceToolNative.payload(claim)?.let { decodeObject(it) }
            val reply = try {
                execute(claim, epoch, descriptor, payload ?: JsonObject(emptyMap<String, JsonElement>()))
            } catch (error: DeviceCommunicationException) {
                failure(error.code.wire, error.userSafeDetail(), error.retryable)
            } catch (error: Throwable) {
                log("error", "device tool execution failed: ${error.javaClass.simpleName}")
                failure(DeviceErrorCode.INTERNAL_FAILURE.wire, null)
            }
            complete(claim, reply)
        }
        } finally {
            if (boundEpoch == epoch) {
                boundEpoch = 0L
                running = false
                runCatching { C05DeviceToolNative.close(epoch) }
            }
        }
    }

    private suspend fun execute(
        claim: Long,
        epoch: Long,
        descriptor: JsonObject,
        payload: JsonObject,
    ): String {
        val operation = descriptor.string("operation")
            ?: throw DeviceCommunicationException(DeviceErrorCode.INVALID_REQUEST, "Missing operation.")
        if (operation !in MUTATING_OPERATIONS && operation !in READ_OPERATIONS) {
            throw DeviceCommunicationException(DeviceErrorCode.INVALID_REQUEST, "Unsupported operation.")
        }
        val descriptorEpoch = descriptor.long("epoch") ?: 0L
        val live = currentNativeEpoch()
        if (descriptorEpoch <= 0L || descriptorEpoch != epoch || live != epoch) {
            throw DeviceCommunicationException(DeviceErrorCode.STALE_EPOCH, null)
        }
        val taskID = descriptor.string("taskID")?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            ?: throw DeviceCommunicationException(DeviceErrorCode.INVALID_REQUEST, "Missing task.")
        val runID = descriptor.string("runID")?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            ?: throw DeviceCommunicationException(DeviceErrorCode.INVALID_REQUEST, "Missing run.")
        val approval = descriptor.string("approvalGrantID")
        if (operation in MUTATING_OPERATIONS && approval.isNullOrBlank()) {
            throw DeviceCommunicationException(
                DeviceErrorCode.PERMISSION_REQUIRED,
                "This device action requires approval.",
            )
        }
        val owner = DeviceOwner(
            token = "tool." + runID.toString(),
            nativeEpoch = epoch,
            taskId = taskID.toString(),
        )
        if (C05DeviceToolNative.shouldStop(claim) != 0) {
            throw DeviceCommunicationException(DeviceErrorCode.CANCELLED, null)
        }
        return when (operation) {
            "open" -> executeOpen(claim, owner, payload)
            "exchange" -> executeExchange(claim, owner, payload)
            "close" -> executeClose(owner, payload)
            "status" -> executeStatus(owner, payload)
            "bleScan" -> executeBleScan(owner, payload)
            "usbList" -> executeUsbList(owner)
            else -> throw DeviceCommunicationException(DeviceErrorCode.INVALID_REQUEST, "Unsupported operation.")
        }
    }

    private suspend fun executeOpen(
        claim: Long,
        owner: DeviceOwner,
        payload: JsonObject,
    ): String {
        val kind = payload.string("kind") ?: throw invalid("Missing device type.")
        val spec = when (kind) {
            "tcp", "telnet" -> DeviceEndpointSpec(
                protocol = if (kind == "tcp") DeviceProtocol.TCP else DeviceProtocol.TELNET,
                host = payload.string("host"),
                port = payload.int("port"),
            )
            "ble" -> DeviceEndpointSpec(
                protocol = DeviceProtocol.BLE,
                bleAddress = payload.string("address"),
                bleServiceUuid = payload.string("serviceUUID"),
                bleWriteUuid = payload.string("writeUUID"),
                bleNotifyUuid = payload.string("notifyUUID"),
                bleReadUuid = payload.string("readUUID"),
            )
            "usb" -> DeviceEndpointSpec(
                protocol = DeviceProtocol.USB,
                usbDeviceName = payload.string("deviceName"),
                usbPortIndex = payload.int("portIndex") ?: 0,
                baudRate = payload.int("baudRate") ?: DeviceLimits.USB_DEFAULT_BAUD,
                dataBits = payload.int("dataBits") ?: 8,
                stopBits = payload.int("stopBits") ?: 1,
                parity = DeviceParity.fromWire(payload.string("parity"))
                    ?: DeviceParity.NONE,
            )
            else -> throw invalid("Unknown device type.")
        }
        val validated = DeviceEndpointValidation.validate(spec)
        if (validated.protocol == DeviceProtocol.TCP || validated.protocol == DeviceProtocol.TELNET) {
            val endpoint = "${validated.host}:${validated.port}"
            if (lanGate != null && lanGate.isLocalLikely(endpoint) && lanGate.blocksConnectHop(endpoint)) {
                throw DeviceCommunicationException(
                    DeviceErrorCode.LOCAL_NETWORK_PERMISSION_REQUIRED,
                    "Local network access is required. Allow it in the App and try again.",
                )
            }
        }
        val snapshot = raceCancellation(claim) { engine.open(owner, validated) }
        return buildJsonObject {
            put("ok", true)
            put("session", snapshot.json())
        }.toString()
    }

    private suspend fun executeExchange(
        claim: Long,
        owner: DeviceOwner,
        payload: JsonObject,
    ): String {
        val sessionID = payload.string("sessionID")
            ?: throw invalid("Missing device session.")
        val text = payload.string("text")
        val base64 = payload.string("base64")
        if (text != null && base64 != null) throw invalid("Use text or base64, not both.")
        var data = when {
            text != null -> text.toByteArray(StandardCharsets.UTF_8)
            base64 != null -> try {
                Base64.getDecoder().decode(base64)
            } catch (_: IllegalArgumentException) {
                throw invalid("Invalid base64 data.")
            }
            else -> ByteArray(0)
        }
        if (data.size > DeviceLimits.MAXIMUM_WRITE_BYTES) {
            throw DeviceCommunicationException(
                DeviceErrorCode.INVALID_REQUEST,
                "A device write is limited to ${DeviceLimits.MAXIMUM_WRITE_BYTES / 1024} KiB.",
            )
        }
        if (payload.bool("appendNewline")) {
            data += '\n'.code.toByte()
        }
        if (data.size > DeviceLimits.MAXIMUM_WRITE_BYTES) {
            throw DeviceCommunicationException(
                DeviceErrorCode.INVALID_REQUEST,
                "A device write is limited to ${DeviceLimits.MAXIMUM_WRITE_BYTES / 1024} KiB.",
            )
        }
        val waitMillis = (payload.long("waitMillis") ?: 500L).coerceIn(0L, 30_000L)
        val maxBytes = (payload.int("maxBytes") ?: DeviceLimits.MAXIMUM_EXCHANGE_BYTES)
            .coerceIn(1, DeviceLimits.MAXIMUM_EXCHANGE_BYTES)
        if (data.isNotEmpty()) {
            raceCancellation(claim) { engine.write(owner, sessionID, data) }
        }
        if (waitMillis > 0) {
            var waited = 0L
            while (waited < waitMillis) {
                if (C05DeviceToolNative.shouldStop(claim) != 0) {
                    throw DeviceCommunicationException(DeviceErrorCode.CANCELLED, null)
                }
                val step = minOf(100L, waitMillis - waited)
                delay(step)
                waited += step
            }
        }
        val received = raceCancellation(claim) { engine.read(owner, sessionID, maxBytes) }
        val snapshot = runCatching { engine.status(owner, sessionID) }.getOrNull()
        return buildJsonObject {
            put("ok", true)
            put("sessionID", sessionID)
            put("bytes", received.size)
            val decoded = decodeUtf8(received)
            if (decoded != null) put("text", decoded) else put("dataBase64", Base64.getEncoder().encodeToString(received))
            snapshot?.let { put("session", it.json()) }
        }.toString()
    }

    private suspend fun executeClose(owner: DeviceOwner, payload: JsonObject): String {
        val sessionID = payload.string("sessionID")
            ?: throw invalid("Missing device session.")
        val report = engine.close(owner, sessionID)
        return buildJsonObject {
            put("ok", report.complete)
            put("closed", report.closed)
            put("complete", report.complete)
            put("pendingBytes", report.pendingBytes)
            if (!report.complete) {
                put("code", DeviceErrorCode.CLEANUP_INCOMPLETE.wire)
                put("detail", "Some device resources could not be closed yet.")
            }
        }.toString()
    }

    private fun executeStatus(owner: DeviceOwner, payload: JsonObject): String {
        val sessionID = payload.string("sessionID")
        if (sessionID != null) {
            val snapshot = engine.status(owner, sessionID)
            return buildJsonObject {
                put("ok", true)
                put("session", snapshot.json())
            }.toString()
        }
        val sessions = engine.list(owner)
        return buildJsonObject {
            put("ok", true)
            put("sessions", buildJsonArray { sessions.forEach { add(it.json()) } })
        }.toString()
    }

    private suspend fun executeBleScan(owner: DeviceOwner, payload: JsonObject): String {
        val duration = (payload.long("durationMillis") ?: 5_000L).coerceIn(1_000L, 15_000L)
        val results = engine.scanBle(owner, duration)
        return buildJsonObject {
            put("ok", true)
            put("devices", buildJsonArray { results.forEach { add(it.json()) } })
        }.toString()
    }

    private suspend fun executeUsbList(owner: DeviceOwner): String {
        val devices = engine.usbDevices(owner)
        return buildJsonObject {
            put("ok", true)
            put("devices", buildJsonArray { devices.forEach { add(it.json()) } })
        }.toString()
    }

    private suspend fun <T> raceCancellation(claim: Long, block: suspend () -> T): T {
        if (C05DeviceToolNative.shouldStop(claim) != 0) {
            throw DeviceCommunicationException(DeviceErrorCode.CANCELLED, null)
        }
        val work = scope.async(ioDispatcher) { block() }
        try {
            while (!work.isCompleted) {
                if (C05DeviceToolNative.shouldStop(claim) != 0) {
                    work.cancel()
                    throw DeviceCommunicationException(DeviceErrorCode.CANCELLED, null)
                }
                delay(50)
            }
            return work.await()
        } finally {
            if (work.isActive) work.cancel()
        }
    }

    private fun complete(claim: Long, reply: String): Boolean {
        var bytes = reply.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > MAXIMUM_REPLY_BYTES) {
            bytes = failure(
                DeviceErrorCode.RESPONSE_TOO_LARGE.wire,
                "The device reply was too large.",
            ).toByteArray(StandardCharsets.UTF_8)
        }
        return runCatching { C05DeviceToolNative.complete(claim, 0, bytes) == 0 }.getOrDefault(false)
    }

    private fun failure(code: String, detail: String?, retryable: Boolean = false): String =
        buildJsonObject {
            put("ok", false)
            put("code", code)
            if (!detail.isNullOrBlank()) put("detail", detail.take(200))
            put("retryable", retryable)
        }.toString()

    private fun decodeObject(bytes: ByteArray): JsonObject? = try {
        json.parseToJsonElement(String(bytes, StandardCharsets.UTF_8)).jsonObject
    } catch (_: Throwable) {
        null
    }

    private fun decodeUtf8(bytes: ByteArray): String? {
        if (bytes.isEmpty()) return ""
        return try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (_: Throwable) {
            null
        }
    }

    private fun DeviceSessionSnapshot.json(): JsonObject = buildJsonObject {
        put("id", id)
        put("kind", protocol.wireName)
        put("endpoint", endpoint)
        put("state", state.wireName)
        put("bytesIn", bytesIn)
        put("bytesOut", bytesOut)
        put("createdAtMillis", createdAtMillis)
        put("lastActivityMillis", lastActivityMillis)
        errorCode?.let { put("errorCode", it) }
        errorDetail?.let { put("errorDetail", it) }
        bleServiceUuid?.let { put("serviceUUID", it) }
        bleMtu?.let { put("mtu", it) }
        put("notificationSubscribed", notificationSubscribed)
        usbVendorId?.let { put("vendorId", it) }
        usbProductId?.let { put("productId", it) }
        usbSerial?.let { put("serial", it) }
    }

    private fun BleScanResult.json(): JsonObject = buildJsonObject {
        put("address", address)
        name?.let { put("name", it) }
        put("rssi", rssi)
    }

    private fun UsbDeviceInfo.json(): JsonObject = buildJsonObject {
        put("deviceName", key)
        put("vendorId", vendorId)
        put("productId", productId)
        productName?.let { put("productName", it) }
        manufacturerName?.let { put("manufacturerName", it) }
        driverName?.let { put("driverName", it) }
        put("portCount", portCount)
        put("permissionGranted", permissionGranted)
        put("attached", attached)
    }

    private fun JsonObject.string(name: String): String? =
        (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.long(name: String): Long? = string(name)?.toLongOrNull()
        ?: (this[name] as? JsonPrimitive)?.contentOrNull?.toLongOrNull()

    private fun JsonObject.int(name: String): Int? = string(name)?.toIntOrNull()
        ?: (this[name] as? JsonPrimitive)?.contentOrNull?.toIntOrNull()

    private fun JsonObject.bool(name: String): Boolean =
        (this[name] as? JsonPrimitive)?.contentOrNull == "true"

    private fun invalid(detail: String) = DeviceCommunicationException(
        DeviceErrorCode.INVALID_REQUEST,
        detail,
    )

    companion object {
        private const val NEXT_TIMEOUT_MILLIS = 250
        private const val MAXIMUM_REPLY_BYTES = 48 * 1024
        private val MUTATING_OPERATIONS = setOf("open", "exchange", "close")
        private val READ_OPERATIONS = setOf("status", "bleScan", "usbList")
    }
}
