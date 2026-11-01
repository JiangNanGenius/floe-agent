// SPDX-License-Identifier: MPL-2.0
//
// C05 remote-screen value surface. Presentation only: no transport, no
// persistence, no credential bytes. The App-owned controller maps the
// trusted `floe.remote/9` values into these types; the terminal engine and
// transport are supplied by `feature:terminal`, never reimplemented here.

package com.floe.android.feature.remote

import android.graphics.Bitmap
import com.floe.android.feature.terminal.G04TerminalEngine
import com.floe.android.feature.terminal.TerminalTransport

data class RemoteAuthUi(
    val kind: String,
    val keyType: String?,
    val credentialAccount: String?,
)

data class RemoteHostSummaryUi(
    val id: String,
    val displayName: String,
    val address: String,
    val port: Int,
    val user: String,
    val auth: RemoteAuthUi,
    val hostKeyPolicy: String,
    val pinnedFingerprint: String?,
    val allowsLegacyAlgorithms: Boolean,
    val jumpHopCount: Int,
    val vncEndpointCount: Int,
    val auxiliaryConnectionCount: Int,
) {
    val endpoint: String get() = if (address.isBlank()) displayName else "$user@$address:$port"
    val usesKey: Boolean get() = auth.kind == "importedKey" || auth.kind == "deviceGeneratedKey"
    val hasSSH: Boolean get() = auth.kind != "none"
}

data class RemoteVncEndpointUi(
    val id: String,
    val displayName: String,
    val transport: String,
    val host: String,
    val port: Int,
    val hasPassword: Boolean,
) {
    val target: String get() = "$host:$port"
}

data class RemoteVncFailureUi(
    val code: String,
    val message: String,
    val retryable: Boolean,
    val category: String,
    val stage: String,
)

data class RemoteVncUi(
    val sessionID: String,
    val profileID: String,
    val endpointID: String,
    val displayName: String,
    val host: String,
    val port: Int,
    val transport: String,
    val state: String,
    val width: Int,
    val height: Int,
    val revision: Long,
    val byteCount: Int,
    val bitmap: Bitmap?,
    val failure: RemoteVncFailureUi?,
    val inputIssue: String?,
    val measuredFps: Double,
    val sshSessionID: String?,
    val tunnelID: String?,
)

data class RemoteHostDetailUi(
    val summary: RemoteHostSummaryUi,
    val jumpHops: List<String>,
    val vncEndpoints: List<RemoteVncEndpointUi>,
    val auxiliaryConnectionCount: Int,
) {
    val vncEndpointCount: Int get() = vncEndpoints.size
}

data class RemoteSessionUi(
    val id: String,
    val displayName: String,
    val address: String,
    val port: Int,
    val user: String,
    val state: String,
    val transportConnected: Boolean,
    val ptyCount: Int,
    val tunnelCount: Int,
)

data class RemotePtyUi(
    val id: String,
    val state: String,
    val columns: Int,
    val rows: Int,
    val totalBytes: Long,
    val rolledOverBytes: Long,
)

data class RemoteTunnelUi(
    val id: String,
    val targetHost: String,
    val targetPort: Int,
    val localPort: Int?,
    val state: String,
    val acceptedConnections: Int,
    val activeConnections: Int,
    val bytesToRemote: Long,
    val bytesFromRemote: Long,
    val lastErrorCode: String?,
)

data class RemoteExecUi(
    val id: String,
    val state: String,
    val output: String,
    val stdoutBytes: Long,
    val stderrBytes: Long,
    val exitCode: Int?,
    val remoteOutcomeUnknown: Boolean,
    val truncated: Boolean,
)

data class RemoteTerminalUi(
    val pty: RemotePtyUi,
    val engine: G04TerminalEngine,
    val transport: TerminalTransport,
    val status: String,
    val inputIssue: String?,
)

data class RemoteHostKeyChallengeUi(
    val id: String,
    val profileID: String,
    val address: String,
    val port: Int,
    val keyType: String,
    val fingerprintSHA256: String,
    val expectedFingerprintSHA256: String?,
    val changed: Boolean,
)

data class RemoteHostUiError(
    val code: String,
    val detail: String?,
)

data class RemoteHostUiState(
    val loading: Boolean = true,
    val coreReady: Boolean = false,
    val credentialGatewayReady: Boolean = false,
    val profiles: List<RemoteHostSummaryUi> = emptyList(),
    val details: Map<String, RemoteHostDetailUi> = emptyMap(),
    val detail: RemoteHostDetailUi? = null,
    val busy: String? = null,
    val error: RemoteHostUiError? = null,
    val challenge: RemoteHostKeyChallengeUi? = null,
    val session: RemoteSessionUi? = null,
    val terminal: RemoteTerminalUi? = null,
    val tunnels: List<RemoteTunnelUi> = emptyList(),
    val exec: RemoteExecUi? = null,
    val vnc: RemoteVncUi? = null,
)

/**
 * User-editable portion of a host profile. Credential text never enters
 * this value after the save call returns; the controller forwards it once to
 * the approved credential gateway.
 */
data class RemoteHostDraft(
    val id: String? = null,
    val displayName: String = "",
    val address: String = "",
    val port: String = "22",
    val user: String = "",
    val authKind: String = "password",
    val keyType: String = "ed25519",
    val hostKeyPolicy: String = "trustOnFirstUse",
    val pinnedFingerprint: String = "",
    val allowsLegacyAlgorithms: Boolean = false,
) {
    val parsedPort: Int? get() = port.toIntOrNull()

    companion object {
        const val AUTH_PASSWORD = "password"
        const val AUTH_KEY = "importedKey"
        const val POLICY_TOFU = "trustOnFirstUse"
        const val POLICY_PINNED = "pinned"
        const val KEY_ED25519 = "ed25519"
        const val KEY_P256 = "ecdsaP256"
        const val KEY_RSA4096 = "rsa4096"

        fun from(detail: RemoteHostDetailUi?): RemoteHostDraft = if (detail == null) {
            RemoteHostDraft()
        } else {
            val summary = detail.summary
            val key = summary.auth.kind == "importedKey" || summary.auth.kind == "deviceGeneratedKey"
            RemoteHostDraft(
                id = summary.id,
                displayName = summary.displayName,
                address = summary.address,
                port = summary.port.toString(),
                user = summary.user,
                authKind = if (key) AUTH_KEY else AUTH_PASSWORD,
                keyType = summary.auth.keyType ?: KEY_ED25519,
                hostKeyPolicy = summary.hostKeyPolicy,
                pinnedFingerprint = summary.pinnedFingerprint.orEmpty(),
                allowsLegacyAlgorithms = summary.allowsLegacyAlgorithms,
            )
        }
    }
}

/** VNC-only host draft. No SSH identity is fabricated or required. */
data class RemoteVncHostDraft(
    val displayName: String = "",
    val host: String = "",
    val port: String = "5900",
    val password: String = "",
) {
    fun toProfileDraft(): RemoteVncProfileDraft = RemoteVncProfileDraft(
        displayName = displayName.trim(),
        host = host.trim(),
        port = port.trim().toIntOrNull() ?: 0,
        password = password,
    )
}

/** Endpoint editor draft for an existing profile (SSH or VNC-only). */
data class RemoteVncEndpointDraft(
    val id: String? = null,
    val displayName: String = "VNC",
    val transport: String = "direct",
    val host: String = "",
    val port: String = "5900",
    val password: String = "",
    val keepPassword: Boolean = true,
) {
    companion object {
        const val TRANSPORT_DIRECT = "direct"
        const val TRANSPORT_SSH = "sshTunnel"
    }
}

/** Local value used by the App controller; no secret is retained after save. */
data class RemoteVncProfileDraft(
    val displayName: String,
    val host: String,
    val port: Int,
    val password: String,
)

fun validateRemoteVncHostDraft(draft: RemoteVncHostDraft): String? {
    if (draft.displayName.trim().isEmpty()) return "displayNameRequired"
    if (draft.displayName.trim().length > 128) return "displayNameTooLong"
    if (draft.host.trim().isEmpty()) return "vncHostRequired"
    if (draft.host.trim().length > 255) return "vncHostTooLong"
    if (draft.host.any { it.isWhitespace() || it.code < 0x20 || it.code == 0x7F }) {
        return "vncHostInvalid"
    }
    val port = draft.port.trim().toIntOrNull() ?: return "vncPortInvalid"
    if (port !in 1..65535) return "vncPortInvalid"
    if (draft.password.toByteArray(Charsets.UTF_8).size > 1024) return "vncPasswordTooLong"
    return null
}

fun validateRemoteVncEndpointDraft(
    draft: RemoteVncEndpointDraft,
    allowTunnel: Boolean,
): String? {
    if (draft.displayName.trim().isEmpty()) return "displayNameRequired"
    if (draft.displayName.trim().length > 64) return "displayNameTooLong"
    if (draft.transport != RemoteVncEndpointDraft.TRANSPORT_DIRECT &&
        draft.transport != RemoteVncEndpointDraft.TRANSPORT_SSH
    ) {
        return "vncTransportInvalid"
    }
    if (draft.transport == RemoteVncEndpointDraft.TRANSPORT_SSH && !allowTunnel) {
        return "vncTransportRequiresSSH"
    }
    if (draft.host.trim().isEmpty()) return "vncHostRequired"
    if (draft.host.trim().length > 255) return "vncHostTooLong"
    if (draft.host.any { it.isWhitespace() || it.code < 0x20 || it.code == 0x7F }) {
        return "vncHostInvalid"
    }
    val port = draft.port.trim().toIntOrNull() ?: return "vncPortInvalid"
    if (port !in 1..65535) return "vncPortInvalid"
    if (draft.password.toByteArray(Charsets.UTF_8).size > 1024) return "vncPasswordTooLong"
    return null
}

fun vncStatusLabel(state: String): String = when (state) {
    "connected" -> "connected"
    "connecting" -> "connecting"
    "closing" -> "closing"
    "failed" -> "failed"
    "closed" -> "closed"
    else -> "unknown"
}

/**
 * Local, deterministic validation before any bridge call. Returns a stable
 * reason code (the UI localizes it); `null` means the draft may be sent.
 */
fun validateRemoteHostDraft(draft: RemoteHostDraft): String? {
    if (draft.displayName.trim().isEmpty()) return "displayNameRequired"
    if (draft.displayName.trim().length > 128) return "displayNameTooLong"
    if (draft.address.trim().isEmpty()) return "addressRequired"
    if (draft.address.trim().length > 255) return "addressTooLong"
    if (draft.address.any { it.isWhitespace() || it.code < 0x20 || it.code == 0x7F }) return "addressInvalid"
    val port = draft.parsedPort ?: return "portInvalid"
    if (port !in 1..65535) return "portInvalid"
    if (draft.user.trim().isEmpty()) return "userRequired"
    if (draft.user.trim().length > 128) return "userTooLong"
    if (draft.authKind != RemoteHostDraft.AUTH_PASSWORD &&
        draft.authKind != RemoteHostDraft.AUTH_KEY
    ) {
        return "authRequired"
    }
    if (draft.authKind == RemoteHostDraft.AUTH_KEY &&
        draft.keyType !in setOf(
            RemoteHostDraft.KEY_ED25519,
            RemoteHostDraft.KEY_P256,
            RemoteHostDraft.KEY_RSA4096,
        )
    ) {
        return "keyTypeInvalid"
    }
    when (draft.hostKeyPolicy) {
        RemoteHostDraft.POLICY_TOFU -> Unit
        RemoteHostDraft.POLICY_PINNED -> {
            if (draft.pinnedFingerprint.trim().isEmpty()) return "fingerprintRequired"
            if (!normalizeFingerprint(draft.pinnedFingerprint).matches(Regex("[A-Za-z0-9+/]{43}"))) {
                return "fingerprintInvalid"
            }
        }
        else -> return "hostKeyPolicyInvalid"
    }
    return null
}

fun normalizeFingerprint(value: String): String =
    value.trim().replace("SHA256:", "", ignoreCase = true).replace("=", "")

/** `user@host:port` display for one jump hop; never a credential. */
fun jumpHopLabel(user: String, address: String, port: Int): String = "$user@$address:$port"

/** Loopback-only tunnel target validator; the local listener is always 127.0.0.1. */
fun validateTunnelTarget(host: String, portText: String): String? {
    val trimmed = host.trim()
    if (trimmed.isEmpty()) return "tunnelHostRequired"
    if (trimmed.length > 255) return "tunnelHostTooLong"
    if (trimmed.any { it.isWhitespace() || it.code < 0x20 || it.code == 0x7F }) return "tunnelHostInvalid"
    val port = portText.trim().toIntOrNull() ?: return "tunnelPortInvalid"
    if (port !in 1..65535) return "tunnelPortInvalid"
    return null
}

/** Compact status label for an SSH session. Unknown is never shown as stopped. */
fun sessionStatusLabel(state: String, connected: Boolean): String = when {
    state == "connected" && connected -> "connected"
    state == "unknown" || (state == "connected" && !connected) -> "unknown"
    state == "closing" -> "closing"
    state == "closed" -> "closed"
    else -> state
}
