// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LanDiscoveryPolicyTest {
    @Test
    fun serviceTypesAreExplicitLowercaseDnsSdTypes() {
        assertEquals("_http._tcp", LanDiscoveryResult.normalizeServiceType("  _HTTP._TCP  "))
        assertEquals("_ipp._udp", LanDiscoveryResult.normalizeServiceType("_ipp._udp"))

        listOf("_http.tcp", "http._tcp", "_http._sctp", "_._tcp", "_http._tcp.", "x_http._tcp").forEach {
            assertThrows(RequestParseException::class.java) {
                LanDiscoveryResult.normalizeServiceType(it)
            }
        }
    }

    @Test
    fun privateCidrExpandsOnlyRfc1918HostAddresses() {
        val subnet = LanDiscoveryResult.parsePrivateSubnet("192.168.1.0/24")
        assertEquals("192.168.1.0/24", subnet.cidr)
        assertEquals(254, subnet.addresses.size)
        assertEquals("192.168.1.1", subnet.addresses.first())
        assertEquals("192.168.1.254", subnet.addresses.last())

        assertEquals(2, LanDiscoveryResult.parsePrivateSubnet("10.0.0.0/30").addresses.size)
        assertEquals(6, LanDiscoveryResult.parsePrivateSubnet("172.16.5.0/29").addresses.size)

        listOf(
            "8.8.8.0/24",
            "169.254.1.0/24",
            "192.168.1.0/23",
            "192.168.1.0/31",
            "192.168.1.1/24",
            "192.168.001.0/24",
            "::1/128",
        ).forEach { cidr ->
            assertThrows(RequestParseException::class.java) {
                LanDiscoveryResult.parsePrivateSubnet(cidr)
            }
        }
    }

    @Test
    fun attemptBudgetIsRejectedInsteadOfSilentlyClamped() {
        val slash24 = LanDiscoveryResult.parsePrivateSubnet("192.168.1.0/24")
        LanDiscoveryResult.checkAttemptBudget(slash24, listOf(80, 443, 631, 8080))
        assertThrows(RequestParseException::class.java) {
            LanDiscoveryResult.checkAttemptBudget(slash24, listOf(80, 443, 631, 8080, 8443))
        }

        val slash25 = LanDiscoveryResult.parsePrivateSubnet("192.168.1.0/25")
        LanDiscoveryResult.checkAttemptBudget(
            slash25,
            listOf(80, 443, 631, 8080, 8443, 9000, 9100, 5000),
        )
        assertThrows(RequestParseException::class.java) {
            LanDiscoveryResult.checkAttemptBudget(slash24, listOf(80, 80))
        }
    }

    @Test
    fun ownCapturedAddressesAreExcludedWithoutGuessing() {
        val subnet = LanDiscoveryResult.parsePrivateSubnet("192.168.1.0/29")
        val (remaining, excluded) = LanDiscoveryResult.excludeSelf(
            subnet,
            listOf("192.168.1.2/29", "fe80::1/64", "not-an-address"),
        )
        assertEquals(listOf("192.168.1.2"), excluded)
        assertEquals(listOf("192.168.1.1", "192.168.1.3", "192.168.1.4", "192.168.1.5", "192.168.1.6"), remaining)
    }

    @Test
    fun unresolvedServiceNeverInventsHostOrPort() {
        val record = LanServiceRecord(
            serviceName = "printer",
            serviceType = "_ipp._tcp.",
            state = "active",
            resolution = "unresolved",
        )
        val json = record.toJson()
        assertFalse(json.has("hostname"))
        assertFalse(json.has("port"))
        assertEquals(0, json.getJSONArray("addresses").length())
    }

    @Test
    fun zeroRepliesIsAnHonestOkObservationNotAFabricatedInventory() {
        val request = LanDiscoveryRequest(
            serviceTypes = listOf("_http._tcp"),
            discoveryDurationMs = 1_000,
            timeoutMs = 3_000,
        )
        val mdns = LanMdnsSummary(
            requestedServiceTypes = listOf("_http._tcp"),
            scope = "capturedNetwork",
            networkScoped = true,
            discoveryDurationMs = 1_000,
            elapsedMs = 1_010,
            services = emptyList(),
            perType = listOf(LanTypeRecord("_http._tcp", "stopped")),
            filteredForeignNetwork = 0,
            truncated = false,
            noReplies = true,
            multicastLockHeld = null,
            stoppedReason = "duration",
        )
        val result = LanDiscoveryResult.build(request, mdns, null, networkChanged = false)
        assertEquals(ObservationStatus.OK, result.status)
        assertTrue(result.observations.getBoolean("noReplies"))
        assertEquals(0, result.observations.getJSONObject("mdns").getInt("serviceCount"))
        assertNull(result.missingPermissions.firstOrNull())
    }

    @Test
    fun permissionAndNetworkChangeAndPartialStatesAreDistinct() {
        val request = LanDiscoveryRequest(
            serviceTypes = listOf("_http._tcp"),
            discoveryDurationMs = 1_000,
            timeoutMs = 3_000,
        )
        val denied = LanMdnsSummary(
            requestedServiceTypes = listOf("_http._tcp"),
            scope = "capturedNetwork",
            networkScoped = true,
            discoveryDurationMs = 1_000,
            elapsedMs = 10,
            services = emptyList(),
            perType = listOf(LanTypeRecord("_http._tcp", "startFailed", 7, "nsdPermissionDenied")),
            filteredForeignNetwork = 0,
            truncated = false,
            noReplies = false,
            multicastLockHeld = null,
            stoppedReason = "duration",
        )
        val permission = LanDiscoveryResult.build(request, denied, null, networkChanged = false)
        assertEquals(ObservationStatus.PERMISSION_REQUIRED, permission.status)
        assertEquals(listOf("android.permission.ACCESS_LOCAL_NETWORK"), permission.missingPermissions)

        val changed = LanDiscoveryResult.build(request, denied, null, networkChanged = true)
        assertEquals(ObservationStatus.ERROR, changed.status)
        assertEquals("networkChanged", changed.observations.getString("errorCode"))

        val truncated = denied.copy(truncated = true, perType = listOf(LanTypeRecord("_http._tcp", "started")))
        val partial = LanDiscoveryResult.build(request, truncated, null, networkChanged = false)
        assertEquals(ObservationStatus.PARTIAL, partial.status)
    }

    @Test
    fun tcpSummaryReportsOnlyActualOpenPortsAndStopReason() {
        val summary = LanTcpScanSummary(
            subnetCidr = "192.168.1.0/30",
            ports = listOf(80, 443),
            hostCount = 2,
            excludedSelfAddresses = listOf("192.168.1.1"),
            attemptedHosts = 1,
            plannedAttempts = 2,
            completedAttempts = 2,
            openPorts = listOf(LanTcpOpenPort("192.168.1.2", 443, 12)),
            refusedAttempts = 1,
            timedOutAttempts = 0,
            errorAttempts = 0,
            unreachableAttempts = 0,
            hostsWithResponse = 2,
            hostsWithOpenPort = 1,
            truncated = false,
            stoppedReason = "completed",
            cancelled = false,
            elapsedMs = 20,
        )
        val json = summary.toJson()
        assertEquals(1, json.getJSONArray("openPorts").length())
        assertEquals(80, json.getJSONArray("ports").getInt(0))
        assertEquals("completed", json.getString("stoppedReason"))
        assertEquals(2, json.getInt("completedAttempts"))
    }

    @Test
    fun tcpOnlyDiscoveryCanCompleteWithoutMdns() {
        val request = LanDiscoveryRequest(
            subnet = LanDiscoveryResult.parsePrivateSubnet("192.168.1.0/30"),
            ports = listOf(80),
            timeoutMs = 3_000,
        )
        val tcp = LanTcpScanSummary(
            subnetCidr = "192.168.1.0/30",
            ports = listOf(80),
            hostCount = 2,
            excludedSelfAddresses = emptyList(),
            attemptedHosts = 2,
            plannedAttempts = 2,
            completedAttempts = 2,
            openPorts = emptyList(),
            refusedAttempts = 2,
            timedOutAttempts = 0,
            errorAttempts = 0,
            unreachableAttempts = 0,
            hostsWithResponse = 2,
            hostsWithOpenPort = 0,
            truncated = false,
            stoppedReason = "completed",
            cancelled = false,
            elapsedMs = 30,
        )
        val result = LanDiscoveryResult.build(request, null, tcp, networkChanged = false)
        assertEquals(ObservationStatus.OK, result.status)
        assertFalse(result.observations.has("mdns"))
        assertEquals(2, result.observations.getJSONObject("tcp").getInt("plannedAttempts"))
    }
    @Test
    fun legacyUnscopedMdnsIsTypedUnsupportedNotNoReplies() {
        val request = LanDiscoveryRequest(
            serviceTypes = listOf("_http._tcp"),
            discoveryDurationMs = 1_000,
            timeoutMs = 3_000,
        )
        val summary = LanMdnsSummary(
            requestedServiceTypes = listOf("_http._tcp"),
            scope = "unsupportedLegacyApi",
            networkScoped = false,
            discoveryDurationMs = 1_000,
            elapsedMs = 0,
            services = emptyList(),
            perType = listOf(
                LanTypeRecord("_http._tcp", "startFailed", error = "nsdNetworkScopeUnsupported"),
            ),
            filteredForeignNetwork = 0,
            truncated = false,
            noReplies = false,
            multicastLockHeld = null,
            stoppedReason = "unsupported",
        )
        val result = LanDiscoveryResult.build(request, summary, null, networkChanged = false)
        assertEquals(ObservationStatus.UNSUPPORTED, result.status)
        assertEquals("nsdNetworkScopeUnsupported", result.observations.getString("errorCode"))
        assertFalse(result.observations.getBoolean("noReplies"))
        assertTrue(result.limitations.any { it.contains("no Network-scoped", ignoreCase = true) })
    }

}
