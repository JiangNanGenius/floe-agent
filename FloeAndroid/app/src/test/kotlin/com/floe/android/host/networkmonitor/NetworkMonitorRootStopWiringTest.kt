// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkmonitor

import com.floe.android.host.HostBridgeExchange
import com.floe.android.host.RuntimeHost
import com.floe.android.host.RuntimeHostCommandClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Root-stop wiring around the lazy monitoring host. It proves the two
 * properties that are not visible in the pure ledger:
 *
 *  * an untouched panel is never initialized merely to stop it; and
 *  * the native-root generation gate is armed even in that case, rejects the
 *    retired epoch (including a repeated drain with a null readback), and
 *    admits an explicit Start only after a different live epoch.
 *
 * The real Service/engine lifecycle is exercised by the ledger interleaving
 * tests and the existing core engine tests; this test performs no device,
 * Service, JNI or network action.
 */
class NetworkMonitorRootStopWiringTest {

    private class NoWireExchange : HostBridgeExchange {
        override fun exchange(request: String): String =
            error("root-stop wiring must not submit a host command")
    }

    private fun runtimeHost(): RuntimeHost {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        return RuntimeHost(
            commandClient = RuntimeHostCommandClient(
                exchange = NoWireExchange(),
                scope = scope,
                ioDispatcher = Dispatchers.Default,
            ),
            gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
            bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
            scope = scope,
            ioDispatcher = Dispatchers.Default,
        )
    }

    @Test
    fun rootStopArmsTheGenerationGateWithoutInitializingAnUntouchedMonitorHost() = runBlocking {
        val host = runtimeHost()
        host.nativeRootEpochReader = { 41L }
        assertFalse(host.isNetworkMonitorHostInitialized)

        assertTrue(host.prepareNetworkForRootStop())

        assertFalse(host.isNetworkMonitorHostInitialized)
        assertFalse(host.isNetworkMonitorLaunchAdmitted())
    }

    @Test
    fun repeatedRootStopKeepsTheRetiredEpochClosedAcrossANullReadback() = runBlocking {
        val host = runtimeHost()
        host.nativeRootEpochReader = { 41L }
        assertTrue(host.prepareNetworkForRootStop())
        assertFalse(host.isNetworkMonitorLaunchAdmitted())

        // A second drain observes the JNI epoch already gone. It must not
        // overwrite the retired 41 with null and re-admit 41.
        host.nativeRootEpochReader = { null }
        assertTrue(host.prepareNetworkForRootStop())
        assertFalse(host.isNetworkMonitorLaunchAdmitted())

        host.nativeRootEpochReader = { 41L }
        assertFalse(host.isNetworkMonitorLaunchAdmitted())
    }

    @Test
    fun aDifferentLiveNativeRootGenerationAdmitsANewExplicitLaunch() = runBlocking {
        val host = runtimeHost()
        host.nativeRootEpochReader = { 41L }
        assertTrue(host.prepareNetworkForRootStop())
        assertFalse(host.isNetworkMonitorLaunchAdmitted())

        host.nativeRootEpochReader = { 42L }
        assertTrue(host.isNetworkMonitorLaunchAdmitted())
        // The gate clears on the first observed new generation; the lazy host
        // is still untouched.
        assertTrue(host.isNetworkMonitorLaunchAdmitted())
        assertFalse(host.isNetworkMonitorHostInitialized)
    }
}
