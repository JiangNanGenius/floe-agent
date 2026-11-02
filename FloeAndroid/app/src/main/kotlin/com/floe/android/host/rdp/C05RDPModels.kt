// SPDX-License-Identifier: MPL-2.0
//
// C05 RDP trusted-host values. Metadata/input only; framebuffer bytes travel
// through C05RDPVideoNative's bounded binary lane, never through JSON/base64.

package com.floe.android.host.rdp

import com.floe.android.host.remote.C05RemoteOwner
import com.floe.android.host.remote.requiredString
import com.floe.android.host.remote.string
import com.floe.android.host.remote.intValue
import com.floe.android.host.remote.longValue
import com.floe.android.host.remote.boolValue
import com.floe.android.host.remote.objectValue
import com.floe.android.host.remote.arrayValue

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

internal fun parseRdpCredentialRef(obj: JsonObject): C05RdpCredentialRef =
    C05RdpCredentialRef(
        keychainAccount = obj.requiredString("keychainAccount"),
        synchronizable = obj.boolValue("synchronizable"),
    )

internal fun parseRdpEndpoint(obj: JsonObject): C05RdpEndpoint =
    C05RdpEndpoint(
        id = obj.requiredString("id"),
        displayName = obj.string("displayName") ?: "RDP",
        host = obj.string("host") ?: "",
        port = obj.intValue("port") ?: 3389,
        username = obj.string("username") ?: "",
        domain = obj.string("domain") ?: "",
        hasPassword = obj.boolValue("hasPassword"),
        approvedFingerprintSHA256 = obj.string("approvedFingerprintSHA256"),
        passwordRef = obj.objectValue("passwordRef")?.let(::parseRdpCredentialRef),
    )

internal fun parseRdpHostSummary(obj: JsonObject): C05RdpHostSummary =
    C05RdpHostSummary(
        id = obj.requiredString("id"),
        displayName = obj.string("displayName") ?: "RDP",
        deviceKind = obj.string("deviceKind") ?: "unspecified",
        isRemoteExecutionEnvironment = obj.boolValue("isRemoteExecutionEnvironment"),
        endpointCount = obj.intValue("endpointCount") ?: 0,
    )

internal fun parseRdpHostDetail(obj: JsonObject): C05RdpHostDetail =
    C05RdpHostDetail(
        summary = parseRdpHostSummary(
            obj.objectValue("summary")
                ?: throw IllegalArgumentException("missingSummary"),
        ),
        endpoints = obj.arrayValue("endpoints").mapNotNull { element ->
            (element as? JsonObject)?.let(::parseRdpEndpoint)
        },
    )

internal fun parseRdpFailure(obj: JsonObject): C05RdpFailure =
    C05RdpFailure(
        code = obj.string("code") ?: "unknown",
        message = obj.string("message") ?: "",
        retryable = obj.boolValue("retryable"),
        category = obj.string("category") ?: "unknown",
        stage = obj.string("stage") ?: "unknown",
        fingerprintSHA256 = obj.string("fingerprintSHA256"),
    )

internal fun parseRdpChallenge(obj: JsonObject): C05RdpCertificatePrompt =
    C05RdpCertificatePrompt(
        profileID = obj.requiredString("profileID"),
        endpointID = obj.requiredString("endpointID"),
        host = obj.string("host") ?: "",
        port = obj.intValue("port") ?: 3389,
        fingerprintSHA256 = obj.requiredString("fingerprintSHA256"),
        subject = obj.string("subject") ?: "",
        kind = obj.string("kind") ?: "firstUse",
        reason = obj.string("reason") ?: "",
        notBefore = obj.string("notBefore"),
        notAfter = obj.string("notAfter"),
        expiresAt = obj.string("expiresAt") ?: "",
    )

internal fun parseRdpSession(obj: JsonObject): C05RdpSession =
    C05RdpSession(
        id = obj.requiredString("id"),
        profileID = obj.requiredString("profileID"),
        endpointID = obj.requiredString("endpointID"),
        displayName = obj.string("displayName") ?: "RDP",
        host = obj.string("host") ?: "",
        port = obj.intValue("port") ?: 3389,
        username = obj.string("username") ?: "",
        domain = obj.string("domain") ?: "",
        state = obj.string("state") ?: "unknown",
        width = obj.intValue("width") ?: 0,
        height = obj.intValue("height") ?: 0,
        frameRevision = obj.longValue("frameRevision") ?: 0L,
        frameBytes = obj.intValue("frameBytes") ?: 0,
        approvedFingerprintSHA256 = obj.string("approvedFingerprintSHA256"),
        certificateChallenge = obj.objectValue("certificateChallenge")?.let(::parseRdpChallenge),
        createdAt = obj.string("createdAt") ?: "",
        lastActivityAt = obj.string("lastActivityAt") ?: "",
        failure = obj.objectValue("failure")?.let(::parseRdpFailure),
    )

internal fun parseRdpCloseResult(obj: JsonObject): C05RdpCloseResult =
    C05RdpCloseResult(
        sessionID = obj.string("sessionID") ?: "",
        closed = obj.boolValue("closed"),
        complete = obj.boolValue("complete"),
    )
