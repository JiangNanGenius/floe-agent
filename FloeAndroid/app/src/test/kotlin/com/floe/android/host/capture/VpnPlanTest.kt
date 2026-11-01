// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import com.floe.android.core.networkcapture.CaptureConfig
import com.floe.android.core.networkcapture.CaptureLimits
import com.floe.android.core.networkcapture.CaptureMode
import com.floe.android.core.networkcapture.CaptureOwner
import com.floe.android.core.networkcapture.Ipv6Policy
import com.floe.android.core.networkcapture.RootCaptureAvailability
import com.floe.android.core.networkcapture.RootCaptureRequest
import com.floe.android.core.networkcapture.VpnPlan
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnPlanTest {

    private val owner = CaptureOwner(
        ownerId = "plan-owner",
        nativeEpoch = 9,
        workspaceId = UUID.randomUUID().toString(),
    )

    private fun vpnConfig() = CaptureConfig(
        owner = owner,
        mode = CaptureMode.VPN,
        detailed = false,
        maxDurationMillis = 60_000,
        maxBytes = CaptureLimits.MAX_BYTES,
        maxPackets = CaptureLimits.MAX_PACKETS,
    )

    @Test
    fun installsOnlyIpv4DefaultRouteAndNeverAnIpv6Route() {
        val plan = VpnPlan.fromConfig(vpnConfig(), "com.floe.android")
        assertEquals(listOf("0.0.0.0/0"), plan.routes)
        assertTrue(plan.routes.none { it.contains(':') })
        assertTrue(plan.dnsServers.isEmpty())
        assertEquals(listOf("com.floe.android"), plan.disallowedPackages)
        assertEquals(Ipv6Policy.BYPASS, plan.ipv6Policy)
    }

    @Test
    fun rejectsIpv6RouteAtThePlanBoundary() {
        assertThrows(IllegalArgumentException::class.java) {
            VpnPlan(
                address = "10.111.222.1",
                prefixLength = 32,
                mtu = 1_500,
                routes = listOf("::/0"),
                sessionName = "capture",
            )
        }
    }

    @Test
    fun rootRequestRequiresRootModeAndPlayAvailabilityIsHonest() {
        assertThrows(IllegalArgumentException::class.java) {
            RootCaptureRequest(owner = owner, config = vpnConfig())
        }
        val play = RootCaptureAvailability.playBuild()
        assertEquals("playBuild", play.code)
        assertTrue(!play.available)
    }
}
