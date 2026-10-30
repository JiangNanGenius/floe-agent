// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.network

import com.floe.android.core.network.PhoneNetworkService

/**
 * The ONE Application-owned `PhoneNetworkService` consumed by both the
 * network Agent pump and the feature/network workbench UI (Main-owned).
 *
 * This adapter is stateless and only forwards the frozen service contract:
 * `execute(requestJson)` and `cancel(operationID)`. It never constructs,
 * replaces or closes the service and stores no permission, target or
 * operation state. The Application owner creates exactly one service, hands
 * it to `RuntimeHost.networkService`, and closes it once after the pump has
 * drained at app teardown.
 */
internal interface PhoneNetworkServicePort {
    suspend fun execute(requestJson: String): String
    fun cancel(operationID: String)
}

internal class PhoneNetworkServiceAdapter(
    private val service: PhoneNetworkService,
) : PhoneNetworkServicePort {
    override suspend fun execute(requestJson: String): String =
        service.execute(requestJson)

    override fun cancel(operationID: String) = service.cancel(operationID)
}
