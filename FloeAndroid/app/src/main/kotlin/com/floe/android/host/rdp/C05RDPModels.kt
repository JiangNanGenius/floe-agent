// SPDX-License-Identifier: MPL-2.0
//
// C05 RDP trusted-host values. Metadata/input only; framebuffer bytes travel
// through C05RDPVideoNative's bounded binary lane, never through JSON/base64.

package com.floe.android.host.rdp

import com.floe.android.host.remote.C05RemoteOwner
import kotlinx.serialization.json.JsonObject

internal const val C05_RDP_VERSION = 17
internal const val C05_RDP_SCHEMA = "floe.rdp/17"

internal class C05RDPException(
    val code: String,
    val reason: String? = null,
    val retryable: Boolean = false,
    val detail: String? = null,
    val challenge: C05RdpCertificatePrompt? = null,
) : Exception(code)

internal data class C05RdpCredentialRef(
    val keychainAccount: String,
    val synchronizable: Boolean,
)

internal data class C05RdpEndpoint(
    val id: String,
    val displayName: String,
    val host: String,
    val port: Int,
    val username: String,
    val domain: String,
    val hasPassword: Boolean,
    val approvedFingerprintSHA256: String?,
    val passwordRef: C05RdpCredentialRef?,
)

internal data class C05RdpEndpointDraft(
    val id: String?,
    val displayName: String,
    val host: String,
    val port: Int,
    val username: String,
    val domain: String,
    val passwordRef: C05RdpCredentialRef?,
)

internal data class C05RdpProfileDraft(
    val id: String?,
    val displayName: String,
    val deviceKind: String,
    val endpoints: List<C05RdpEndpointDraft>,
)

internal data class C05RdpHostSummary(
    val id: String,
    val displayName: String,
    val deviceKind: String,
    val isRemoteExecutionEnvironment: Boolean,
    val endpointCount: Int,
)

internal data class C05RdpHostDetail(
    val summary: C05RdpHostSummary,
    val endpoints: List<C05RdpEndpoint>,
)

internal data class C05RdpFailure(
    val code: String,
    val message: String,
    val retryable: Boolean,
    val category: String,
    val stage: String,
    val fingerprintSHA256: String?,
)

internal data class C05RdpCertificatePrompt(
    val profileID: String,
    val endpointID: String,
    val host: String,
    val port: Int,
    val fingerprintSHA256: String,
    val subject: String,
    val kind: String,
    val reason: String,
    val notBefore: String?,
    val notAfter: String?,
    val expiresAt: String,
)

internal data class C05RdpSession(
    val id: String,
    val profileID: String,
    val endpointID: String,
    val displayName: String,
    val host: String,
    val port: Int,
    val username: String,
    val domain: String,
    val state: String,
    val width: Int,
    val height: Int,
    val frameRevision: Long,
    val frameBytes: Int,
    val approvedFingerprintSHA256: String?,
    val certificateChallenge: C05RdpCertificatePrompt?,
    val createdAt: String,
    val lastActivityAt: String,
    val failure: C05RdpFailure?,
)

internal data class C05RdpCloseResult(
    val sessionID: String,
    val closed: Boolean,
    val complete: Boolean,
)

internal data class C05RdpFrameMeta(
    val leaseID: String,
    val sessionID: String,
    val width: Int,
    val height: Int,
    val stride: Int,
    val format: String,
    val byteCount: Int,
    val revision: Long,
)

internal data class C05RdpCapabilities(
    val coreReady: Boolean,
    val epoch: Long?,
    val credentialGatewayReady: Boolean,
    val runtimeVersion: String,
    val maximumSessions: Int,
    val maximumEndpointsPerProfile: Int,
    val maximumInputEvents: Int,
    val maximumTextBytes: Int,
    val maximumFrameBytes: Int,
    val maximumLeases: Int,
    val pixelFormat: String,
    val supportsCertificateTrust: Boolean,
    val modelTools: Boolean,
)

internal sealed interface C05RdpInput {
    data class PointerMove(val x: Int, val y: Int) : C05RdpInput
    data class PointerButton(
        val button: String,
        val down: Boolean,
        val x: Int,
        val y: Int,
    ) : C05RdpInput

    data class Wheel(val up: Boolean, val steps: Int, val x: Int, val y: Int) : C05RdpInput
    data class Key(val scancode: Int, val extended: Boolean, val down: Boolean) : C05RdpInput
    data class NamedKey(val key: String) : C05RdpInput
    data class Modifier(val modifier: String, val down: Boolean) : C05RdpInput
    data class Text(val text: String, val submit: Boolean) : C05RdpInput
}

internal fun parseRdpCredentialRef(object: JsonObject): C05RdpCredentialRef =
    C05RdpCredentialRef(
        keychainAccount = object.requiredString("keychainAccount"),
        synchronizable = object.boolValue("synchronizable"),
    )

internal fun parseRdpEndpoint(object: JsonObject): C05RdpEndpoint =
    C05RdpEndpoint(
        id = object.requiredString("id"),
        displayName = object.string("displayName") ?: "RDP",
        host = object.string("host") ?: "",
        port = object.intValue("port") ?: 3389,
        username = object.string("username") ?: "",
        domain = object.string("domain") ?: "",
        hasPassword = object.boolValue("hasPassword"),
        approvedFingerprintSHA256 = object.string("approvedFingerprintSHA256"),
        passwordRef = object.objectValue("passwordRef")?.let(::parseRdpCredentialRef),
    )

internal fun parseRdpHostSummary(object: JsonObject): C05RdpHostSummary =
    C05RdpHostSummary(
        id = object.requiredString("id"),
        displayName = object.string("displayName") ?: "RDP",
        deviceKind = object.string("deviceKind") ?: "unspecified",
        isRemoteExecutionEnvironment = object.boolValue("isRemoteExecutionEnvironment"),
        endpointCount = object.intValue("endpointCount") ?: 0,
    )

internal fun parseRdpHostDetail(object: JsonObject): C05RdpHostDetail =
    C05RdpHostDetail(
        summary = parseRdpHostSummary(
            object.objectValue("summary")
                ?: throw IllegalArgumentException("missingSummary"),
        ),
        endpoints = object.arrayValue("endpoints").mapNotNull { element ->
            (element as? JsonObject)?.let(::parseRdpEndpoint)
        },
    )

internal fun parseRdpFailure(object: JsonObject): C05RdpFailure =
    C05RdpFailure(
        code = object.string("code") ?: "unknown",
        message = object.string("message") ?: "",
        retryable = object.boolValue("retryable"),
        category = object.string("category") ?: "unknown",
        stage = object.string("stage") ?: "unknown",
        fingerprintSHA256 = object.string("fingerprintSHA256"),
    )

internal fun parseRdpChallenge(object: JsonObject): C05RdpCertificatePrompt =
    C05RdpCertificatePrompt(
        profileID = object.requiredString("profileID"),
        endpointID = object.requiredString("endpointID"),
        host = object.string("host") ?: "",
        port = object.intValue("port") ?: 3389,
        fingerprintSHA256 = object.requiredString("fingerprintSHA256"),
        subject = object.string("subject") ?: "",
        kind = object.string("kind") ?: "firstUse",
        reason = object.string("reason") ?: "",
        notBefore = object.string("notBefore"),
        notAfter = object.string("notAfter"),
        expiresAt = object.string("expiresAt") ?: "",
    )

internal fun parseRdpSession(object: JsonObject): C05RdpSession =
    C05RdpSession(
        id = object.requiredString("id"),
        profileID = object.requiredString("profileID"),
        endpointID = object.requiredString("endpointID"),
        displayName = object.string("displayName") ?: "RDP",
        host = object.string("host") ?: "",
        port = object.intValue("port") ?: 3389,
        username = object.string("username") ?: "",
        domain = object.string("domain") ?: "",
        state = object.string("state") ?: "unknown",
        width = object.intValue("width") ?: 0,
        height = object.intValue("height") ?: 0,
        frameRevision = object.longValue("frameRevision") ?: 0L,
        frameBytes = object.intValue("frameBytes") ?: 0,
        approvedFingerprintSHA256 = object.string("approvedFingerprintSHA256"),
        certificateChallenge = object.objectValue("certificateChallenge")?.let(::parseRdpChallenge),
        createdAt = object.string("createdAt") ?: "",
        lastActivityAt = object.string("lastActivityAt") ?: "",
        failure = object.objectValue("failure")?.let(::parseRdpFailure),
    )

internal fun parseRdpCloseResult(object: JsonObject): C05RdpCloseResult =
    C05RdpCloseResult(
        sessionID = object.string("sessionID") ?: "",
        closed = object.boolValue("closed"),
        complete = object.boolValue("complete"),
    )
