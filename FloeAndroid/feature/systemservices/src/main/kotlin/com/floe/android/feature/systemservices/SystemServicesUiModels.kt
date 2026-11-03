// SPDX-License-Identifier: MPL-2.0
//
// C06 system-services screen values. Presentation only; the App-owned
// controller owns permissions, the platform lane and the Swift bridge.

package com.floe.android.feature.systemservices

enum class CapabilityKind {
    LOCATION,
    CONTACTS,
    NFC,
    HEALTH,
}

enum class CapabilityState {
    READY,
    NEEDS_PERMISSION,
    DENIED,
    RESTRICTED,
    DISABLED,
    UPDATE_REQUIRED,
    NOT_INSTALLED,
    UNSUPPORTED,
}

data class CapabilityUi(
    val kind: CapabilityKind,
    val state: CapabilityState,
    val available: Boolean = state == CapabilityState.READY,
    val precise: Boolean? = null,
    val grantedMetricCount: Int = 0,
    val canRequest: Boolean = false,
    val canOpenSettings: Boolean = false,
    val detailCode: String? = null,
)

data class HealthMetricUi(
    val wire: String,
    val granted: Boolean,
)

data class DiagnosticRowUi(
    val key: String,
    val value: String,
)

data class SystemServicesUiState(
    val loading: Boolean = true,
    val coreReady: Boolean = false,
    val revision: Long = 0,
    val foreground: Boolean = false,
    val location: CapabilityUi = CapabilityUi(CapabilityKind.LOCATION, CapabilityState.UNSUPPORTED),
    val contacts: CapabilityUi = CapabilityUi(CapabilityKind.CONTACTS, CapabilityState.UNSUPPORTED),
    val nfc: CapabilityUi = CapabilityUi(CapabilityKind.NFC, CapabilityState.UNSUPPORTED),
    val health: CapabilityUi = CapabilityUi(CapabilityKind.HEALTH, CapabilityState.UNSUPPORTED),
    val healthMetrics: List<HealthMetricUi> = emptyList(),
    val notice: String? = null,
    val diagnostics: List<DiagnosticRowUi> = emptyList(),
)

/** Closed keys the destination maps to localized product copy. */
object SystemServicesNotice {
    const val GRANT_FAILED = "grantFailed"
    const val REFRESH_FAILED = "refreshFailed"
    const val SETTINGS_UNAVAILABLE = "settingsUnavailable"
    const val HEALTH_NOT_INSTALLED = "healthNotInstalled"
    const val NFC_DISABLED = "nfcDisabled"
    const val PERMISSION_DENIED = "permissionDenied"
    const val BUSY = "busy"
}
