// SPDX-License-Identifier: MPL-2.0
//
// C05 VNC trusted-host values. Metadata/input only; framebuffer bytes travel
// through C05VNCVideoNative's bounded binary lane, never through JSON/base64.

package com.floe.android.host.remote

internal const val C05_VNC_VERSION = 11

internal data class C05VncPasswordRef(
    val keychainAccount: String,
    val synchronizable: Boolean,
)

internal data class C05VncEndpoint(
    val id: String,
    val displayName: String,
    val transport: String,
    val host: String,
    val port: Int,
    val passwordRef: C05VncPasswordRef?,
)

internal data class C05VncEndpointDraft(
    val id: String?,
    val displayName: String,
    val transport: String,
    val host: String,
    val port: Int,
    val passwordRef: C05VncPasswordRef?,
)

internal data class C05VncProfileDraft(
    val id: String?,
    val displayName: String,
    val deviceKind: String,
    val endpoints: List<C05VncEndpointDraft>,
)

internal data class C05VncFailureInfo(
    val code: String,
    val message: String,
    val retryable: Boolean,
    val category: String,
    val stage: String,
)

internal data class C05VncSession(
    val id: String,
    val profileID: String,
    val endpointID: String,
    val displayName: String,
    val host: String,
    val port: Int,
    val transport: String,
    val state: String,
    val width: Int,
    val height: Int,
    val frameRevision: Long,
    val frameBytes: Int,
    val sshSessionID: String?,
    val tunnelID: String?,
    val createdAt: String,
    val lastActivityAt: String,
    val failure: C05VncFailureInfo?,
)

internal data class C05VncCloseResult(
    val sessionID: String,
    val closed: Boolean,
    val complete: Boolean,
    val closedTunnel: Boolean,
    val closedSSHSession: Boolean,
)

internal data class C05VncFrameMeta(
    val leaseID: String,
    val sessionID: String,
    val width: Int,
    val height: Int,
    val stride: Int,
    val format: String,
    val byteCount: Int,
    val revision: Long,
)

internal sealed interface C05VncInput {
    data class PointerMove(val x: Int, val y: Int) : C05VncInput
    data class PointerButton(
        val button: String,
        val down: Boolean,
        val x: Int,
        val y: Int,
    ) : C05VncInput

    data class Wheel(val axis: String, val steps: Int, val x: Int, val y: Int) : C05VncInput
    data class Key(val keysym: Long, val down: Boolean) : C05VncInput
    data class Text(val text: String) : C05VncInput
}

internal fun parseVncPasswordRef(
    object: kotlinx.serialization.json.JsonObject,
): C05VncPasswordRef = C05VncPasswordRef(
    keychainAccount = object.requiredString("keychainAccount"),
    synchronizable = object.boolValue("synchronizable"),
)

internal fun parseVncEndpoint(
    object: kotlinx.serialization.json.JsonObject,
): C05VncEndpoint = C05VncEndpoint(
    id = object.requiredString("id"),
    displayName = object.string("displayName") ?: "VNC",
    transport = object.string("transport") ?: "direct",
    host = object.string("host") ?: "",
    port = object.intValue("port") ?: 5900,
    passwordRef = object.objectValue("passwordRef")?.let(::parseVncPasswordRef),
)

internal fun parseVncFailure(
    object: kotlinx.serialization.json.JsonObject,
): C05VncFailureInfo = C05VncFailureInfo(
    code = object.string("code") ?: "unknown",
    message = object.string("message") ?: "",
    retryable = object.boolValue("retryable"),
    category = object.string("category") ?: "unknown",
    stage = object.string("stage") ?: "unknown",
)

internal fun parseVncSession(
    object: kotlinx.serialization.json.JsonObject,
): C05VncSession = C05VncSession(
    id = object.requiredString("id"),
    profileID = object.requiredString("profileID"),
    endpointID = object.requiredString("endpointID"),
    displayName = object.string("displayName") ?: "VNC",
    host = object.string("host") ?: "",
    port = object.intValue("port") ?: 5900,
    transport = object.string("transport") ?: "direct",
    state = object.string("state") ?: "unknown",
    width = object.intValue("width") ?: 0,
    height = object.intValue("height") ?: 0,
    frameRevision = object.longValue("frameRevision") ?: 0L,
    frameBytes = object.intValue("frameBytes") ?: 0,
    sshSessionID = object.string("sshSessionID"),
    tunnelID = object.string("tunnelID"),
    createdAt = object.string("createdAt") ?: "",
    lastActivityAt = object.string("lastActivityAt") ?: "",
    failure = object.objectValue("failure")?.let(::parseVncFailure),
)

internal fun parseVncCloseResult(
    object: kotlinx.serialization.json.JsonObject,
): C05VncCloseResult = C05VncCloseResult(
    sessionID = object.string("sessionID") ?: "",
    closed = object.boolValue("closed"),
    complete = object.boolValue("complete"),
    closedTunnel = object.boolValue("closedTunnel"),
    closedSSHSession = object.boolValue("closedSSHSession"),
)

internal data class C05VncCapabilities(
    val coreReady: Boolean,
    val epoch: Long?,
    val credentialGatewayReady: Boolean,
    val maximumSessions: Int,
    val maximumProfiles: Int,
    val maximumEndpointsPerProfile: Int,
    val maximumInputEvents: Int,
    val maximumTextBytes: Int,
    val maximumCredentialBytes: Int,
    val maximumFrameBytes: Int,
    val maximumLeases: Int,
    val pixelFormat: String,
    val supportsDirect: Boolean,
    val supportsSSHTunnel: Boolean,
    val supportsPointer: Boolean,
    val supportsKeyboard: Boolean,
    val supportsWheel: Boolean,
    val modelTools: Boolean,
)

internal data class C05VncRootStopResult(
    val drained: Boolean,
    val closedSessions: Int,
    val closedTunnels: Int,
    val closedSSHSessions: Int,
)
