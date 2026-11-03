// SPDX-License-Identifier: MPL-2.0
//
// Synchronous trusted-host client for `floe.system/15`. Called only from the
// App-owned controller/lane on an IO dispatcher. Platform access is NOT here:
// the reverse mailbox lane owns LocationManager, ContactsContract, the NFC
// adapter and Health Connect.

package com.floe.android.host.systemservices

import com.floe.android.bridge.SwiftCore
import com.floe.android.core.systemservices.SystemAvailability
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

internal fun interface SystemServicesTransport {
    fun exchange(request: String): String
}

internal object SwiftSystemServicesTransport : SystemServicesTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal data class SystemServicesOwnerRef(
    val token: String,
    val nativeEpoch: Long,
    val taskID: String? = null,
    val conversationID: String? = null,
    val environmentID: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("token", token)
        put("nativeEpoch", nativeEpoch)
        taskID?.let { put("taskID", it) }
        conversationID?.let { put("conversationID", it) }
        environmentID?.let { put("environmentID", it) }
        put("temporary", false)
    }
}

internal class SystemServicesClientFailure(
    val code: String,
    override val message: String,
    val retryable: Boolean = false,
) : Exception(message)

internal data class SystemAvailabilityPush(
    val locationAvailable: Boolean,
    val contactsAvailable: Boolean,
    val nfcAvailable: Boolean,
    val healthAvailable: Boolean,
)

internal class C06SystemServicesClient(
    private val transport: SystemServicesTransport = SwiftSystemServicesTransport,
) {
    fun pushAvailability(
        owner: SystemServicesOwnerRef,
        availability: SystemAvailability,
    ): SystemAvailabilityPush {
        val response = exchange("c06.system.availability", owner) {
            put("revision", availability.revision)
            put("foreground", availability.foreground)
            put(
                "location",
                JSONObject().apply {
                    put("hardwareAvailable", availability.location.hardwareAvailable)
                    put("servicesEnabled", availability.location.servicesEnabled)
                    put("permission", availability.location.permission.wire)
                    put("precise", availability.location.precise)
                },
            )
            put(
                "contacts",
                JSONObject().apply {
                    put("providerAvailable", availability.contacts.providerAvailable)
                    put("permission", availability.contacts.permission.wire)
                },
            )
            put(
                "nfc",
                JSONObject().apply {
                    put("hardwareAvailable", availability.nfc.hardwareAvailable)
                    put("enabled", availability.nfc.enabled)
                },
            )
            put(
                "health",
                JSONObject().apply {
                    put("providerStatus", availability.health.providerStatus.wire)
                    put("grantedMetrics", JSONArray(availability.health.grantedMetrics.sorted()))
                },
            )
        }
        return SystemAvailabilityPush(
            locationAvailable = response.optBoolean("locationAvailable", false),
            contactsAvailable = response.optBoolean("contactsAvailable", false),
            nfcAvailable = response.optBoolean("nfcAvailable", false),
            healthAvailable = response.optBoolean("healthAvailable", false),
        )
    }

    fun status(owner: SystemServicesOwnerRef): JSONObject =
        exchange("c06.system.status", owner) { }

    private fun exchange(
        operation: String,
        owner: SystemServicesOwnerRef,
        build: JSONObject.() -> Unit,
    ): JSONObject {
        val requestID = UUID.randomUUID().toString()
        val request = JSONObject()
            .put("version", 15)
            .put("operation", operation)
            .put("requestID", requestID)
            .put("owner", owner.toJson())
        request.build()
        val raw = try {
            transport.exchange(request.toString())
        } catch (failure: Throwable) {
            throw SystemServicesClientFailure(
                "coreUnavailable",
                "system services core unavailable: ${failure.javaClass.simpleName}",
            )
        }
        val response = try {
            JSONObject(raw)
        } catch (_: Throwable) {
            throw SystemServicesClientFailure("invalidResponse", "invalid_system_services_reply")
        }
        if (!response.optBoolean("ok", false)) {
            throw SystemServicesClientFailure(
                response.optString("code", "internalFailure"),
                response.optString("reason", "system_services_operation_failed"),
                response.optBoolean("retryable", false),
            )
        }
        return response
    }
}
