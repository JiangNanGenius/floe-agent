// SPDX-License-Identifier: MPL-2.0
//
// Synchronous client for the trusted `floe.rdp/17` host channel. The
// controller calls it off the main thread. Pixels are not part of this wire:
// C05RDPVideoNative owns the bounded binary frame lease.

package com.floe.android.host.rdp

import com.floe.android.host.remote.C05RemoteFailure
import com.floe.android.host.remote.C05RemoteOwner
import com.floe.android.host.remote.C05RemoteTransport
import com.floe.android.host.remote.SwiftC05RemoteTransport
import com.floe.android.host.remote.arrayValue
import com.floe.android.host.remote.boolValue
import com.floe.android.host.remote.intValue
import com.floe.android.host.remote.longValue
import com.floe.android.host.remote.objectValue
import com.floe.android.host.remote.requiredString
import com.floe.android.host.remote.string
import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

internal class C05RDPClient(
    private val transport: C05RemoteTransport = SwiftC05RemoteTransport,
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun capabilities(): C05RdpCapabilities {
        val response = exchange(request("c05.rdp.capabilities"))
        return C05RdpCapabilities(
            coreReady = response.boolValue("coreReady"),
            epoch = response.longValue("epoch"),
            credentialGatewayReady = response.boolValue("credentialGatewayReady"),
            runtimeVersion = response.string("runtimeVersion") ?: "unavailable",
            maximumSessions = response.intValue("maximumSessions") ?: 0,
            maximumEndpointsPerProfile = response.intValue("maximumEndpointsPerProfile") ?: 0,
            maximumInputEvents = response.intValue("maximumInputEvents") ?: 0,
            maximumTextBytes = response.intValue("maximumTextBytes") ?: 0,
            maximumFrameBytes = response.intValue("maximumFrameBytes") ?: 0,
            maximumLeases = response.intValue("maximumLeases") ?: 0,
            pixelFormat = response.string("pixelFormat") ?: "RGBA8888",
            supportsCertificateTrust = response.boolValue("supportsCertificateTrust"),
            modelTools = response.boolValue("modelTools"),
        )
    }

    fun listProfiles(owner: C05RemoteOwner): List<C05RdpHostDetail> {
        val response = exchange(request("c05.rdp.profile.list") {
            putOwner(owner)
        })
        return response.arrayValue("hosts").mapNotNull { element ->
            (element as? JsonObject)?.let(::parseRdpHostDetail)
        }
    }

    fun profileDetail(profileID: String, owner: C05RemoteOwner): C05RdpHostDetail {
        val response = exchange(request("c05.rdp.profile.detail") {
            putOwner(owner)
            put("profileID", profileID)
        })
        return parseRdpHostDetail(
            response.objectValue("host") ?: throw invalid("missingHost"),
        )
    }

    fun profileSave(draft: C05RdpProfileDraft, owner: C05RemoteOwner): C05RdpHostDetail {
        val response = exchange(request("c05.rdp.profile.save") {
            putOwner(owner)
            put("profile", buildJsonObject {
                draft.id?.let { put("id", it) }
                put("displayName", draft.displayName)
                put("deviceKind", draft.deviceKind)
                put("endpoints", buildJsonArray {
                    draft.endpoints.forEach { endpoint ->
                        add(buildJsonObject {
                            endpoint.id?.let { put("id", it) }
                            put("displayName", endpoint.displayName)
                            put("host", endpoint.host)
                            put("port", endpoint.port)
                            put("username", endpoint.username)
                            put("domain", endpoint.domain)
                            endpoint.passwordRef?.let { reference ->
                                put("passwordRef", buildJsonObject {
                                    put("keychainAccount", reference.keychainAccount)
                                    put("synchronizable", reference.synchronizable)
                                })
                            }
                        })
                    }
                })
            })
        })
        return parseRdpHostDetail(
            response.objectValue("host") ?: throw invalid("missingHost"),
        )
    }

    fun profileDelete(
        profileID: String,
        deleteHost: Boolean,
        owner: C05RemoteOwner,
    ) {
        exchange(request("c05.rdp.profile.delete") {
            putOwner(owner)
            put("profileID", profileID)
            put("deleteHost", deleteHost)
        })
    }

    fun endpointDelete(
        profileID: String,
        endpointID: String,
        owner: C05RemoteOwner,
    ): C05RdpHostDetail {
        val response = exchange(request("c05.rdp.endpoint.delete") {
            putOwner(owner)
            put("profileID", profileID)
            put("endpointID", endpointID)
        })
        return parseRdpHostDetail(
            response.objectValue("host") ?: throw invalid("missingHost"),
        )
    }

    fun connect(
        profileID: String,
        endpointID: String?,
        owner: C05RemoteOwner,
    ): C05RdpSession {
        val response = exchange(request("c05.rdp.connect") {
            putOwner(owner)
            put("profileID", profileID)
            endpointID?.let { put("endpointID", it) }
        })
        return parseRdpSession(
            response.objectValue("session") ?: throw invalid("missingSession"),
        )
    }

    fun status(sessionID: String, owner: C05RemoteOwner): C05RdpSession {
        val response = exchange(request("c05.rdp.status") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
        return parseRdpSession(
            response.objectValue("session") ?: throw invalid("missingSession"),
        )
    }

    fun input(sessionID: String, events: List<C05RdpInput>, owner: C05RemoteOwner): Int {
        if (events.isEmpty() || events.size > MAX_INPUT_EVENTS) {
            throw C05RemoteFailure("invalidRequest", "rdpInputBatchSize")
        }
        val textBytes = events.filterIsInstance<C05RdpInput.Text>()
            .sumOf { it.text.toByteArray(Charsets.UTF_8).size }
        if (textBytes > MAX_TEXT_BYTES) {
            throw C05RemoteFailure("invalidRequest", "rdpTextTooLarge")
        }
        val response = exchange(request("c05.rdp.input") {
            putOwner(owner)
            put("sessionID", sessionID)
            put("events", buildJsonArray {
                events.forEach { event -> add(inputJson(event)) }
            })
        })
        return response.intValue("accepted") ?: events.size
    }

    fun releaseAll(sessionID: String, owner: C05RemoteOwner) {
        exchange(request("c05.rdp.releaseAll") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
    }

    fun close(sessionID: String, owner: C05RemoteOwner): C05RdpCloseResult {
        val response = exchange(request("c05.rdp.close") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
        return parseRdpCloseResult(response)
    }

    fun reset(sessionID: String, owner: C05RemoteOwner): C05RdpCloseResult {
        val response = exchange(request("c05.rdp.reset") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
        return parseRdpCloseResult(response)
    }

    fun rootStop(expectedEpoch: Long) {
        exchange(request("c05.rdp.rootStop") {
            put("expectedEpoch", expectedEpoch)
        })
    }

    fun trust(
        profileID: String,
        endpointID: String,
        fingerprintSHA256: String,
        owner: C05RemoteOwner,
    ) {
        exchange(request("c05.rdp.trust") {
            putOwner(owner)
            put("profileID", profileID)
            put("endpointID", endpointID)
            put("fingerprintSHA256", fingerprintSHA256)
        })
    }

    fun revokeTrust(
        profileID: String,
        endpointID: String,
        owner: C05RemoteOwner,
    ) {
        exchange(request("c05.rdp.trust.revoke") {
            putOwner(owner)
            put("profileID", profileID)
            put("endpointID", endpointID)
        })
    }

    fun credentialSave(
        account: String,
        synchronizable: Boolean,
        secret: ByteArray,
        owner: C05RemoteOwner,
    ): C05RdpCredentialRef {
        if (secret.isEmpty() || secret.size > MAX_SECRET_BYTES) {
            throw C05RemoteFailure("credentialInvalid", "invalidCredentialSize")
        }
        val encoded = Base64.getEncoder().encodeToString(secret)
        if (encoded.length > 60_000) {
            throw C05RemoteFailure("credentialInvalid", "credentialTooLarge")
        }
        val response = exchange(request("c05.rdp.credential.save") {
            putOwner(owner)
            put("credential", buildJsonObject {
                put("keychainAccount", account)
                put("synchronizable", synchronizable)
            })
            put("secretBase64", encoded)
        })
        val reference = response.objectValue("reference")
            ?: throw invalid("missingCredentialReference")
        return C05RdpCredentialRef(
            keychainAccount = reference.requiredString("keychainAccount"),
            synchronizable = reference.boolValue("synchronizable"),
        )
    }

    fun credentialProbe(reference: C05RdpCredentialRef): Boolean {
        val response = exchange(request("c05.rdp.credential.probe") {
            put("credential", credentialJson(reference))
        })
        return response.boolValue("present")
    }

    fun credentialDelete(reference: C05RdpCredentialRef) {
        exchange(request("c05.rdp.credential.delete") {
            put("credential", credentialJson(reference))
        })
    }

    // MARK: - Plumbing

    private fun request(
        operation: String,
        builder: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {},
    ): JsonObject = buildJsonObject {
        put("version", C05_RDP_VERSION)
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
        val objectValue = try {
            json.parseToJsonElement(raw).jsonObject
        } catch (_: Throwable) {
            throw C05RemoteFailure("invalidResponse", "invalidBridgeResponse")
        }
        if ((objectValue["ok"] as? JsonPrimitive)?.contentOrNull != "true") {
            val error = objectValue.string("error")
            val code = when (error) {
                "unsupportedVersion", "unsupportedOperation" -> "needsCoreUpdate"
                else -> objectValue.string("code") ?: error ?: "unknown"
            }
            throw C05RDPException(
                code = code,
                reason = objectValue.string("reason"),
                retryable = objectValue.boolValue("retryable"),
                detail = objectValue.string("detail"),
                challenge = objectValue.objectValue("challenge")?.let(::parseRdpChallenge),
            )
        }
        val declaredOperation = objectValue.string("operation")
        if (declaredOperation != null &&
            declaredOperation != (request["operation"] as? JsonPrimitive)?.contentOrNull
        ) {
            throw C05RemoteFailure("invalidResponse", "operationMismatch")
        }
        return objectValue
    }

    private fun inputJson(event: C05RdpInput): JsonObject = buildJsonObject {
        when (event) {
            is C05RdpInput.PointerMove -> {
                put("kind", "pointerMove")
                put("x", event.x)
                put("y", event.y)
            }
            is C05RdpInput.PointerButton -> {
                put("kind", "pointerButton")
                put("button", event.button)
                put("down", event.down)
                put("x", event.x)
                put("y", event.y)
            }
            is C05RdpInput.Wheel -> {
                put("kind", "wheel")
                put("up", event.up)
                put("steps", event.steps)
                put("x", event.x)
                put("y", event.y)
            }
            is C05RdpInput.Key -> {
                put("kind", "key")
                put("scancode", event.scancode)
                put("extended", event.extended)
                put("down", event.down)
            }
            is C05RdpInput.NamedKey -> {
                put("kind", "namedKey")
                put("key", event.key)
            }
            is C05RdpInput.Modifier -> {
                put("kind", "modifier")
                put("modifier", event.modifier)
                put("down", event.down)
            }
            is C05RdpInput.Text -> {
                put("kind", "text")
                put("text", event.text)
                put("submit", event.submit)
            }
        }
    }

    private fun credentialJson(reference: C05RdpCredentialRef): JsonObject = buildJsonObject {
        put("keychainAccount", reference.keychainAccount)
        put("synchronizable", reference.synchronizable)
    }

    private fun kotlinx.serialization.json.JsonObjectBuilder.putOwner(owner: C05RemoteOwner) {
        put("owner", buildJsonObject {
            put("token", owner.token)
            put("nativeEpoch", owner.nativeEpoch)
            owner.taskID?.let { put("taskID", it) }
            put("temporary", owner.temporary)
        })
    }

    private fun invalid(reason: String): C05RemoteFailure =
        C05RemoteFailure("invalidResponse", reason)

    companion object {
        const val MAX_INPUT_EVENTS = 32
        const val MAX_TEXT_BYTES = 4 * 1024
        const val MAX_SECRET_BYTES = 40 * 1024
    }
}
