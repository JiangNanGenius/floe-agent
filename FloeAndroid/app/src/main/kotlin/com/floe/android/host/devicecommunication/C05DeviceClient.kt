// SPDX-License-Identifier: MPL-2.0
//
// Synchronous client for the trusted `floe.device/14` bridge. This channel
// carries device PROFILE metadata and capabilities only: live terminal/device
// bytes stay in the App-owned Kotlin engine lane and never cross the JSON
// bridge, so no large base64 body or binary paging is needed here.
//
// The caller is the trusted App host UI. It is NOT a BridgeV3 command, NOT a
// model tool and grants no device/LAN permission. Model tools use their own
// mailbox below and derive authority from ToolContext.

package com.floe.android.host.devicecommunication

import com.floe.android.core.devicecommunication.DeviceProtocol
import com.floe.android.host.remote.C05RemoteFailure
import com.floe.android.host.remote.C05RemoteOwner
import com.floe.android.host.remote.C05RemoteTransport
import com.floe.android.host.remote.SwiftC05RemoteTransport
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

internal const val C05_DEVICE_VERSION = 14

internal data class C05DeviceCapabilities(
    val coreReady: Boolean,
    val epoch: Long?,
    val maximumSessions: Int,
    val maximumProfiles: Int,
    val maximumConnectionsPerProfile: Int,
    val supportsTcp: Boolean,
    val supportsTelnet: Boolean,
    val supportsBle: Boolean,
    val supportsUsb: Boolean,
    val modelTools: Boolean,
)

internal data class C05DeviceConnectionDraft(
    val id: String?,
    val displayName: String,
    val kind: String,
    val host: String? = null,
    val port: Int? = null,
    val peripheralAddress: String? = null,
    val serviceUuid: String? = null,
    val writeUuid: String? = null,
    val notifyUuid: String? = null,
)

internal data class C05DeviceProfileDraft(
    val id: String?,
    val displayName: String,
    val connections: List<C05DeviceConnectionDraft>,
)

internal data class C05DeviceConnection(
    val id: String,
    val displayName: String,
    val kind: String,
    val host: String? = null,
    val port: Int? = null,
    val peripheralAddress: String? = null,
    val serviceUuid: String? = null,
    val writeUuid: String? = null,
    val notifyUuid: String? = null,
)

internal data class C05DeviceProfile(
    val id: String,
    val displayName: String,
    val connections: List<C05DeviceConnection>,
)

internal data class C05DeviceProfileDelete(
    val deleted: Boolean,
    val remainingConnections: Int,
)

internal class C05DeviceClient(
    private val transport: C05RemoteTransport = SwiftC05RemoteTransport,
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun capabilities(): C05DeviceCapabilities {
        val response = exchange(request("c05.device.capabilities"))
        return C05DeviceCapabilities(
            coreReady = response.bool("coreReady"),
            epoch = response.long("epoch"),
            maximumSessions = response.int("maximumSessions") ?: 4,
            maximumProfiles = response.int("maximumProfiles") ?: 64,
            maximumConnectionsPerProfile = response.int("maximumConnectionsPerProfile") ?: 8,
            supportsTcp = response.bool("supportsTcp"),
            supportsTelnet = response.bool("supportsTelnet"),
            supportsBle = response.bool("supportsBle"),
            supportsUsb = response.bool("supportsUsb"),
            modelTools = response.bool("modelTools"),
        )
    }

    fun profiles(owner: C05RemoteOwner): List<C05DeviceProfile> {
        val response = exchange(request("c05.device.profile.list") { putOwner(owner) })
        return response.array("profiles").mapNotNull { element ->
            val objectValue = element as? JsonObject ?: return@mapNotNull null
            parseProfile(objectValue)
        }
    }

    fun saveProfile(draft: C05DeviceProfileDraft, owner: C05RemoteOwner): C05DeviceProfile {
        val response = exchange(request("c05.device.profile.save") {
            putOwner(owner)
            put("profile", draft.toJson())
        })
        return response.objectValue("profile")?.let(::parseProfile)
            ?: throw invalid("missingDeviceProfile")
    }

    fun deleteProfile(profileId: String, owner: C05RemoteOwner): C05DeviceProfileDelete {
        val response = exchange(request("c05.device.profile.delete") {
            putOwner(owner)
            put("profileID", profileId)
        })
        return C05DeviceProfileDelete(
            deleted = response.bool("deleted"),
            remainingConnections = response.int("remainingConnections") ?: 0,
        )
    }

    private fun request(
        operation: String,
        builder: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {},
    ): JsonObject = buildJsonObject {
        put("version", C05_DEVICE_VERSION)
        put("operation", operation)
        put("requestID", UUID.randomUUID().toString())
        builder()
    }

    private fun exchange(request: JsonObject): JsonObject {
        val raw = try {
            transport.exchange(request.toString())
        } catch (_: Throwable) {
            throw C05RemoteFailure("coreUnavailable", "bridgeUnavailable", retryable = true)
        }
        val response = try {
            json.parseToJsonElement(raw).jsonObject
        } catch (_: Throwable) {
            throw C05RemoteFailure("invalidResponse", "invalidBridgeResponse")
        }
        if ((response["ok"] as? JsonPrimitive)?.contentOrNull != "true") {
            val error = response.string("error")
            throw C05RemoteFailure(
                code = when (error) {
                    "unsupportedVersion", "unsupportedOperation" -> "needsCoreUpdate"
                    else -> response.string("code") ?: error ?: "unknown"
                },
                reason = response.string("reason"),
                retryable = response.bool("retryable"),
                detail = response.string("detail"),
            )
        }
        val declared = response.string("operation")
        val expected = (request["operation"] as? JsonPrimitive)?.contentOrNull
        if (declared != null && expected != null && declared != expected) {
            throw C05RemoteFailure("invalidResponse", "operationMismatch")
        }
        return response
    }

    private fun parseProfile(value: JsonObject): C05DeviceProfile = C05DeviceProfile(
        id = value.requiredString("id"),
        displayName = value.requiredString("displayName"),
        connections = value.array("connections").mapNotNull { element ->
            val connection = element as? JsonObject ?: return@mapNotNull null
            C05DeviceConnection(
                id = connection.requiredString("id"),
                displayName = connection.requiredString("displayName"),
                kind = connection.requiredString("kind"),
                host = connection.string("host"),
                port = connection.int("port"),
                peripheralAddress = connection.string("peripheralAddress"),
                serviceUuid = connection.string("serviceUUID"),
                writeUuid = connection.string("writeUUID"),
                notifyUuid = connection.string("notifyUUID"),
            )
        },
    )

    private fun C05DeviceProfileDraft.toJson(): JsonObject = buildJsonObject {
        id?.let { put("id", it) }
        put("displayName", displayName)
        put("connections", buildJsonArray {
            connections.forEach { connection ->
                add(buildJsonObject {
                    connection.id?.let { put("id", it) }
                    put("displayName", connection.displayName)
                    put("kind", connection.kind)
                    connection.host?.let { put("host", it) }
                    connection.port?.let { put("port", it) }
                    connection.peripheralAddress?.let { put("peripheralAddress", it) }
                    connection.serviceUuid?.let { put("serviceUUID", it) }
                    connection.writeUuid?.let { put("writeUUID", it) }
                    connection.notifyUuid?.let { put("notifyUUID", it) }
                })
            }
        })
    }

    private fun JsonObject.array(name: String): List<kotlinx.serialization.json.JsonElement> =
        (this[name] as? kotlinx.serialization.json.JsonArray)?.toList() ?: emptyList()

    private fun JsonObject.objectValue(name: String): JsonObject? = this[name] as? JsonObject

    private fun JsonObject.string(name: String): String? =
        (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.requiredString(name: String): String =
        string(name) ?: throw invalid("missing_$name")

    private fun JsonObject.bool(name: String): Boolean =
        (this[name] as? JsonPrimitive)?.contentOrNull == "true"

    private fun JsonObject.int(name: String): Int? =
        (this[name] as? JsonPrimitive)?.contentOrNull?.toIntOrNull()

    private fun JsonObject.long(name: String): Long? =
        (this[name] as? JsonPrimitive)?.contentOrNull?.toLongOrNull()

    private fun kotlinx.serialization.json.JsonObjectBuilder.putOwner(owner: C05RemoteOwner) {
        put("owner", buildJsonObject {
            put("token", owner.token)
            put("nativeEpoch", owner.nativeEpoch)
            owner.taskID?.let { put("taskID", it) }
            put("temporary", owner.temporary)
        })
    }

    private fun invalid(reason: String) = C05RemoteFailure("invalidResponse", reason)

    companion object {
        fun kindFor(protocol: DeviceProtocol): String = when (protocol) {
            DeviceProtocol.TCP -> "tcp"
            DeviceProtocol.TELNET -> "telnet"
            DeviceProtocol.BLE -> "bluetoothSerial"
            DeviceProtocol.USB -> "usbSerial"
        }
    }
}
