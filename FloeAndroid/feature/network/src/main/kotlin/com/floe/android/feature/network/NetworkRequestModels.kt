// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

/**
 * Typed UI → host command. The host serializes these exact frozen fields; it
 * never turns arbitrary form strings into booleans/numbers by guessing, and a
 * new method cannot smuggle a UI-only probe through the workbench.
 */
sealed interface NetworkExecuteCommand {
    val page: NetworkPage

    data class Simple(
        override val page: NetworkPage,
        val arguments: Map<String, String>,
    ) : NetworkExecuteCommand

    data class LanDiscovery(
        val input: LanDiscoveryInput,
    ) : NetworkExecuteCommand {
        override val page: NetworkPage get() = NetworkPage.LAN
    }

    data class SpeedTest(
        val input: SpeedTestInput,
    ) : NetworkExecuteCommand {
        override val page: NetworkPage get() = NetworkPage.SPEED
    }
}
