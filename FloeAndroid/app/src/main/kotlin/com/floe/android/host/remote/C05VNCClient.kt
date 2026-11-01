// SPDX-License-Identifier: MPL-2.0
//
// Synchronous client for the trusted `floe.vnc/11` host channel. The
// controller calls it off the main thread. Pixels are not part of this wire:
// C05VNCVideoNative owns the bounded binary frame lease.

package com.floe.android.host.remote

import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

internal class C05VNCClient(
    private val transport: C05RemoteTransport = SwiftC05RemoteTransport,
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun capabilities(): C05VncCapabilities {
        val response = exchange(request("c05.vnc.capabilities"))
        return C05VncCapabilities(
            coreReady = response.boolValue("coreReady"),
            epoch = response.longValue("epoch"),
            credentialGatewayReady = response.boolValue("credentialGatewayReady"),
            maximumSessions = response.intValue("maximumSessions") ?: 0,
            maximumProfiles = response.intValue("maximumProfiles") ?: 0,
            maximumEndpointsPerProfile = response.intValue("maximumEndpointsPerProfile") ?: 0,
            maximumInputEvents = response.intValue("maximumInputEvents") ?: 0,
            maximumTextBytes = response.intValue("maximumTextBytes") ?: 0,
            maximumCredentialBytes = response.intValue("maximumCredentialBytes") ?: 0,
            maximumFrameBytes = response.intValue("maximumFrameBytes") ?: 0,
            maximumLeases = response.intValue("maximumLeases") ?: 0,
            pixelFormat = response.string("pixelFormat") ?: "RGBA8888",
            supportsDirect = response.boolValue("supportsDirect"),
            supportsSSHTunnel = response.boolValue("supportsSSHTunnel"),
            supportsPointer = response.boolValue("supportsPointer"),
            supportsKeyboard = response.boolValue("supportsKeyboard"),
            supportsWheel = response.boolValue("supportsWheel"),
            modelTools = response.boolValue("modelTools"),
        )
    }

    fun profileSaveVNCOnly(draft: C05VncProfileDraft, owner: C05RemoteOwner): C05HostDetail {
        val response = exchange(request("c05.vnc.profile.save") {
            putOwner(owner)
            put("profile", buildJsonObject {
                draft.id?.let { put("id", it) }
                put("displayName", draft.displayName)
                put("deviceKind", draft.deviceKind)
                put("vncEndpoints", buildJsonArray {
                    draft.endpoints.forEach { endpoint ->
                        add(buildJsonObject {
                            endpoint.id?.let { put("id", it) }
                            put("displayName", endpoint.displayName)
                            put("transport", endpoint.transport)
                            put("host", endpoint.host)
                            put("port", endpoint.port)
                            endpoint.passwordRef?.let { ref ->
                                put("passwordRef", buildJsonObject {
                                    put("keychainAccount", ref.keychainAccount)
                                    put("synchronizable", ref.synchronizable)
                                })
                            }
                        })
                    }
                })
            })
        })
        return parseDetail(response.objectValue("host") ?: throw invalid("missingHost"))
    }

    fun connect(
        profileID: String,
        endpointID: String?,
        sshSessionID: String?,
        owner: C05RemoteOwner,
    ): C05VncSession {
        val response = exchange(request("c05.vnc.connect") {
            putOwner(owner)
            put("profileID", profileID)
            endpointID?.let { put("endpointID", it) }
            sshSessionID?.let { put("sshSessionID", it) }
        })
        return parseVncSession(
            response.objectValue("session") ?: throw invalid("missingVncSession"),
        )
    }

    fun status(sessionID: String, owner: C05RemoteOwner): C05VncSession {
        val response = exchange(request("c05.vnc.status") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
        return parseVncSession(
            response.objectValue("session") ?: throw invalid("missingVncSession"),
        )
    }

    fun input(sessionID: String, events: List<C05VncInput>, owner: C05RemoteOwner): Int {
        if (events.isEmpty() || events.size > MAX_INPUT_EVENTS) {
            throw C05RemoteFailure("invalidRequest", "vncInputBatchSize")
        }
        val textBytes = events.filterIsInstance<C05VncInput.Text>()
            .sumOf { it.text.toByteArray(Charsets.UTF_8).size }
        if (textBytes > MAX_TEXT_BYTES) {
            throw C05RemoteFailure("invalidRequest", "vncTextTooLarge")
        }
        val response = exchange(request("c05.vnc.input") {
            putOwner(owner)
            put("sessionID", sessionID)
            put("events", buildJsonArray {
                events.forEach { event -> add(inputJson(event)) }
            })
        })
        return response.intValue("accepted") ?: events.size
    }

    fun releaseAll(sessionID: String, owner: C05RemoteOwner) {
        exchange(request("c05.vnc.releaseAll") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
    }

    fun close(sessionID: String, owner: C05RemoteOwner): C05VncCloseResult {
        val response = exchange(request("c05.vnc.close") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
        return parseVncCloseResult(response)
    }

    fun rootStop(expectedEpoch: Long): C05VncRootStopResult {
        val response = exchange(request("c05.vnc.rootStop") {
            put("expectedEpoch", expectedEpoch)
        })
        return C05VncRootStopResult(
            drained = response.boolValue("drained"),
            closedSessions = response.intValue("closedSessions") ?: 0,
            closedTunnels = response.intValue("closedTunnels") ?: 0,
            closedSSHSessions = response.intValue("closedSSHSessions") ?: 0,
        )
    }

    fun credentialSave(
        account: String,
        synchronizable: Boolean,
        secret: ByteArray,
        owner: C05RemoteOwner,
    ): C05VncPasswordRef {
        if (secret.isEmpty() || secret.size > MAX_SECRET_BYTES) {
            throw C05RemoteFailure("credentialInvalid", "invalidCredentialSize")
        }
        val encoded = Base64.getEncoder().encodeToString(secret)
        if (encoded.length > 60_000) {
            throw C05RemoteFailure("credentialInvalid", "credentialTooLarge")
        }
        val response = exchange(request("c05.vnc.credential.save") {
            putOwner(owner)
            put("credential", buildJsonObject {
                put("keychainAccount", account)
                put("synchronizable", synchronizable)
            })
            put("secretBase64", encoded)
        })
        val reference = response.objectValue("reference") ?: throw invalid("missingCredentialReference")
        return C05VncPasswordRef(
            keychainAccount = reference.requiredString("keychainAccount"),
            synchronizable = reference.boolValue("synchronizable"),
        )
    }

    fun credentialProbe(reference: C05VncPasswordRef): Boolean {
        val response = exchange(request("c05.vnc.credential.probe") {
            put("credential", passwordRefJson(reference))
        })
        return response.boolValue("present")
    }

    fun credentialDelete(reference: C05VncPasswordRef) {
        exchange(request("c05.vnc.credential.delete") {
            put("credential", passwordRefJson(reference))
        })
    }

    // MARK: - Plumbing

    private fun request(
        operation: String,
        builder: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {},
    ): JsonObject = buildJsonObject {
        put("version", C05_VNC_VERSION)
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
            throw C05RemoteFailure(
                code = code,
                reason = objectValue.string("reason"),
                retryable = objectValue.boolValue("retryable"),
                detail = objectValue.string("detail"),
                challenge = objectValue.objectValue("challenge")?.let(::parseChallenge),
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

    private fun inputJson(event: C05VncInput): JsonObject = buildJsonObject {
        when (event) {
            is C05VncInput.PointerMove -> {
                put("kind", "pointerMove")
                put("x", event.x)
                put("y", event.y)
            }
            is C05VncInput.PointerButton -> {
                put("kind", "pointerButton")
                put("button", event.button)
                put("down", event.down)
                put("x", event.x)
                put("y", event.y)
            }
            is C05VncInput.Wheel -> {
                put("kind", "wheel")
                put("axis", event.axis)
                put("steps", event.steps)
                put("x", event.x)
                put("y", event.y)
            }
            is C05VncInput.Key -> {
                put("kind", "key")
                put("keysym", event.keysym)
                put("down", event.down)
            }
            is C05VncInput.Text -> {
                put("kind", "text")
                put("text", event.text)
            }
        }
    }

    private fun passwordRefJson(reference: C05VncPasswordRef): JsonObject = buildJsonObject {
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
