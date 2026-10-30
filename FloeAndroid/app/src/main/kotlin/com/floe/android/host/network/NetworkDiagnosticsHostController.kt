// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.network

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope

/**
 * A content-free `permissionRequired` request forwarded by the network pump.
 *
 * The pump stores NO permission state and launches NO dialog. Main routes
 * this to the EXISTING `IntegrationsHostController.LocalNetworkAccessBroker`
 * and host guidance surface (no duplicate permission DB, launcher or Manifest
 * entry). `targetHost` is host-only (no scheme, path, query, userinfo or
 * port); it is `null` for methods without a concrete endpoint
 * (status/wifiScan, mDNS-only lanDiscover). `targetLabel` is a bounded,
 * host-free human hint for the broker surface (for example an mDNS browse or
 * a subnet scan base) and is never used for dispatch.
 */
internal data class NetworkPermissionRequest(
    val operationID: String,
    val method: String,
    val missingPermissions: List<String>,
    val targetHost: String?,
    val targetLabel: String? = null,
)

/**
 * RuntimeHost-owned network diagnostics lane.
 *
 * Main constructs ONE controller against the single Application-owned
 * `PhoneNetworkService` (shared by this pump and the feature/network
 * workbench) and starts/stops it with the native root epoch. Construction is
 * side-effect free; the pump binds only in [start].
 */
internal class NetworkDiagnosticsHostController(
    scope: CoroutineScope,
    ioDispatcher: CoroutineDispatcher,
    currentNativeEpoch: () -> Long?,
    serviceProvider: () -> PhoneNetworkServicePort?,
    onPermissionRequired: (NetworkPermissionRequest) -> Unit = {},
    timing: NetworkDiagnosticsTiming = NetworkDiagnosticsTiming(),
) {
    private val pump = NetworkDiagnosticsHostPump(
        scope = scope,
        ioDispatcher = ioDispatcher,
        currentNativeEpoch = currentNativeEpoch,
        serviceProvider = serviceProvider,
        onPermissionRequired = onPermissionRequired,
        timing = timing,
    )

    /** Bind/start the exact current epoch. False = honestly unavailable. */
    suspend fun start(epoch: Long): Boolean = pump.start(epoch)

    /** Drain the exact epoch; false means the old generation is still owned. */
    suspend fun stopAndJoin(expectedEpoch: Long, waitMillis: Long): Boolean =
        pump.stopAndJoin(expectedEpoch, waitMillis)

    fun isRunning(): Boolean = pump.isRunning()

    fun boundEpoch(): Long = pump.boundNativeEpoch

    /** Typed mailbox counters JSON (no targets, paths, ids or payloads). */
    fun statsJson(): String? = pump.statsJson()

    /** Actual bound/registered capability JSON, or an honest local fallback. */
    fun readinessJson(): String? = pump.readinessJson()
        ?: """{"version":1,"tool":"network","bound":false,"available":false,"registered":[]}"""
}
