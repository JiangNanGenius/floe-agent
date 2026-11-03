// SPDX-License-Identifier: MPL-2.0
//
// C05 RDP presentation values. Presentation only: no transport, no
// persistence, no credential bytes. The App-owned controller maps the trusted
// `floe.rdp/17` values into these types; FreeRDP frames arrive as a real
// Bitmap from the app-owned binary frame pump.

package com.floe.android.feature.rdp

import android.graphics.Bitmap

data class RdpCapabilitiesUi(
    val coreReady: Boolean,
    val runtimeVersion: String,
    val supportsCertificateTrust: Boolean,
    val modelTools: Boolean,
)

data class RdpEndpointUi(
    val id: String,
    val displayName: String,
    val host: String,
    val port: Int,
    val username: String,
    val domain: String,
    val hasPassword: Boolean,
    val approvedFingerprintSHA256: String?,
    val credentialAccount: String?,
) {
    val target: String get() = "$host:$port"
    val trusted: Boolean get() = !approvedFingerprintSHA256.isNullOrBlank()
}

data class RdpHostDetailUi(
    val id: String,
    val displayName: String,
    val deviceKind: String,
    val isRemoteExecutionEnvironment: Boolean,
    val endpoints: List<RdpEndpointUi>,
) {
    val endpointCount: Int get() = endpoints.size
}

data class RdpFailureUi(
    val code: String,
    val message: String,
    val retryable: Boolean,
    val category: String,
    val stage: String,
)

data class RdpCertificatePromptUi(
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

data class RdpSessionUi(
    val sessionID: String,
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
    val revision: Long,
    val byteCount: Int,
    val bitmap: Bitmap?,
    val failure: RdpFailureUi?,
    val inputIssue: String?,
    val measuredFps: Double,
)

data class RdpUiState(
    val loading: Boolean = false,
    val coreReady: Boolean = true,
    val busy: String? = null,
    val hosts: List<RdpHostDetailUi> = emptyList(),
    val capabilities: RdpCapabilitiesUi? = null,
    val session: RdpSessionUi? = null,
    val prompt: RdpCertificatePromptUi? = null,
    val error: RdpFailureUi? = null,
    val savedMessage: String? = null,
)

data class RdpEndpointDraftUi(
    val id: String? = null,
    val displayName: String = "RDP",
    val host: String = "",
    val port: String = "3389",
    val username: String = "",
    val domain: String = "",
    val password: String = "",
    val keepPassword: Boolean = false,
)

data class RdpProfileDraftUi(
    val id: String? = null,
    val displayName: String = "",
    val deviceKind: String = "windows",
    val endpoints: List<RdpEndpointDraftUi> = emptyList(),
)

data class RdpActions(
    val onRefresh: () -> Unit,
    val onConnect: (profileID: String, endpointID: String?) -> Unit,
    val onTrust: () -> Unit,
    val onRejectTrust: () -> Unit,
    val onDisconnect: () -> Unit,
    val onReconnect: () -> Unit,
    val onReset: () -> Unit,
    val onDismissError: () -> Unit,
    val onVisible: (Boolean) -> Unit,
    val onPointerMove: (Int, Int) -> Unit,
    val onPointerButton: (button: String, down: Boolean, x: Int, y: Int) -> Unit,
    val onWheel: (up: Boolean, steps: Int, x: Int, y: Int) -> Unit,
    val onKey: (scancode: Int, extended: Boolean, down: Boolean) -> Unit,
    val onNamedKey: (String) -> Unit,
    val onModifier: (String, Boolean) -> Unit,
    val onText: (String) -> Unit,
    val onSubmit: () -> Unit,
    val onReleaseAll: () -> Unit,
    val onSave: (RdpProfileDraftUi) -> Unit,
    val onDeleteEndpoint: (profileID: String, endpointID: String) -> Unit,
    val onDeleteHost: (profileID: String) -> Unit,
)
