// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure LAN form policy: typed arrays/booleans, explicit RFC1918 input and the
 * frozen caps. No network I/O is exercised here (Main owns the service tests).
 *
 * AUTHORED SOURCE ONLY: not compiled or executed by this lane.
 */
class LanDiscoveryFormTest {

    @Test
    fun defaultSelectionIsExplicitCommonServiceAndStillRequiresStart() {
        val result = LanDiscoveryPolicy.parse(LanDiscoveryFormValues())
        assertTrue(result.errors.isEmpty())
        val input = requireNotNull(result.input)
        assertEquals(listOf("_http._tcp"), input.serviceTypes)
        assertEquals(4_000, input.discoveryDurationMs)
        assertFalse(input.includeAttributes)
        assertNull(input.subnetCidr)
        assertTrue(input.ports.isEmpty())
        assertEquals(5_000, input.timeoutMs)
    }

    @Test
    fun privateSubnetRequiresRfc1918ZeroHostBitsAndSlash24To30() {
        assertEquals(
            LanValidationError.SUBNET_PRIVATE,
            LanDiscoveryPolicy.parsePrivateSubnet("8.8.8.0/24").error,
        )
        assertEquals(
            LanValidationError.SUBNET_HOST_BITS,
            LanDiscoveryPolicy.parsePrivateSubnet("192.168.1.5/24").error,
        )
        assertEquals(
            LanValidationError.SUBNET_PREFIX,
            LanDiscoveryPolicy.parsePrivateSubnet("192.168.0.0/23").error,
        )
        assertEquals(
            LanValidationError.SUBNET_FORMAT,
            LanDiscoveryPolicy.parsePrivateSubnet("not-a-subnet").error,
        )
        val valid = LanDiscoveryPolicy.parsePrivateSubnet("192.168.1.0/24")
        assertEquals("192.168.1.0/24", valid.cidr)
        assertEquals(254, valid.hosts)
    }

    @Test
    fun subnetAndPortsAreRequiredTogetherAndMustFitTheAttemptBudget() {
        val missingPorts = LanDiscoveryPolicy.parse(
            LanDiscoveryFormValues(serviceTypes = emptySet(), subnetCidr = "192.168.1.0/30"),
        )
        assertTrue(missingPorts.errors.contains(LanValidationError.PORTS_FORMAT))

        val duplicate = LanDiscoveryPolicy.parse(
            LanDiscoveryFormValues(serviceTypes = emptySet(), subnetCidr = "192.168.1.0/30", ports = "80,80"),
        )
        assertTrue(duplicate.errors.contains(LanValidationError.PORTS_FORMAT))

        val tooMany = LanDiscoveryPolicy.parse(
            LanDiscoveryFormValues(
                serviceTypes = emptySet(),
                subnetCidr = "192.168.1.0/29",
                ports = "1,2,3,4,5,6,7,8,9",
            ),
        )
        assertTrue(tooMany.errors.contains(LanValidationError.PORTS_LIMIT))

        val overBudget = LanDiscoveryPolicy.parse(
            LanDiscoveryFormValues(
                serviceTypes = emptySet(),
                subnetCidr = "192.168.1.0/24",
                ports = "80,443,631,8080,8443",
            ),
        )
        assertTrue(overBudget.errors.contains(LanValidationError.ATTEMPT_BUDGET))
    }

    @Test
    fun tcpFallbackWorksWithoutMdnsAndUsesABoundedTimeout() {
        val result = LanDiscoveryPolicy.parse(
            LanDiscoveryFormValues(
                serviceTypes = emptySet(),
                discoverySeconds = "1",
                subnetCidr = "10.0.0.0/26",
                ports = "22,80",
                tcpConnectTimeoutMs = "300",
                tcpConcurrency = "8",
            ),
        )
        assertTrue(result.errors.isEmpty())
        val input = requireNotNull(result.input)
        assertFalse(input.hasMdns)
        assertTrue(input.hasTcp)
        assertEquals(listOf(22, 80), input.ports)
        assertTrue(input.timeoutMs in 2_000..30_000)
    }

    @Test
    fun oversizedWorstCaseTimeoutIsCappedAtThirtySeconds() {
        val input = LanDiscoveryInput(
            serviceTypes = listOf("_http._tcp"),
            subnetCidr = "192.168.1.0/24",
            ports = listOf(80, 443, 631, 8080),
            tcpConnectTimeoutMs = 500,
            tcpConcurrency = 16,
        )
        assertEquals(30_000, input.timeoutMs)
    }

    @Test
    fun serviceTypeAndNumericBoundsAreValidatedBeforeAnyRequest() {
        val nineTypes = LanServicePresets.all.take(9).toSet()
        val tooManyTypes = LanDiscoveryPolicy.parse(LanDiscoveryFormValues(serviceTypes = nineTypes))
        assertTrue(tooManyTypes.errors.contains(LanValidationError.SERVICE_LIMIT))

        val badDuration = LanDiscoveryPolicy.parse(LanDiscoveryFormValues(discoverySeconds = "16"))
        assertTrue(badDuration.errors.contains(LanValidationError.DISCOVERY_SECONDS))

        val badTimeout = LanDiscoveryPolicy.parse(
            LanDiscoveryFormValues(tcpConnectTimeoutMs = "99", tcpConcurrency = "33"),
        )
        assertTrue(badTimeout.errors.contains(LanValidationError.CONNECT_TIMEOUT))
        assertTrue(badTimeout.errors.contains(LanValidationError.CONCURRENCY))

        val noSelection = LanDiscoveryPolicy.parse(LanDiscoveryFormValues(serviceTypes = emptySet()))
        assertTrue(noSelection.errors.contains(LanValidationError.NO_SELECTION))
    }
}
