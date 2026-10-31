// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PcapFilterFormTest {
    @Test
    fun parsesTypedFiltersAndConvertsSecondsToMillis() {
        val result = PcapFilterForm.parse(
            PcapFilterValues(
                protocols = setOf("tcp", "udp"),
                services = setOf("dns"),
                address = " 10.0.0.1 ",
                port = "443",
                startSeconds = "1700000000",
                endSeconds = "1700000100",
            ),
        )
        assertTrue(result.errors.isEmpty())
        val query = result.query!!
        assertEquals(setOf("tcp", "udp"), query.protocols)
        assertEquals(setOf("dns"), query.services)
        assertEquals("10.0.0.1", query.address)
        assertEquals(443, query.port)
        assertEquals(1_700_000_000_000L, query.startEpochMillis)
        assertEquals(1_700_000_100_000L, query.endEpochMillis)
    }

    @Test
    fun invalidValuesAreRefusedInsteadOfGuessed() {
        assertTrue(PcapFilterForm.parse(PcapFilterValues(address = "http://x/y")).errors.contains("address"))
        assertTrue(PcapFilterForm.parse(PcapFilterValues(port = "0")).errors.contains("port"))
        assertTrue(PcapFilterForm.parse(PcapFilterValues(port = "65536")).errors.contains("port"))
        assertTrue(PcapFilterForm.parse(PcapFilterValues(startSeconds = "20", endSeconds = "10")).errors.contains("time"))
        assertTrue(PcapFilterForm.parse(PcapFilterValues(startSeconds = "-1")).errors.contains("time"))
        assertNull(PcapFilterForm.parse(PcapFilterValues(port = "99999")).query)
    }

    @Test
    fun emptyValuesProduceAnEmptyQuery() {
        val query = PcapFilterForm.parse(PcapFilterValues()).query!!
        assertTrue(query.protocols.isEmpty())
        assertTrue(query.services.isEmpty())
        assertNull(query.address)
        assertNull(query.port)
        assertNull(query.startEpochMillis)
    }

    @Test
    fun valuesRoundTripForReopening() {
        val query = PcapFilterQuery(
            protocols = setOf("icmp"),
            services = setOf("http"),
            address = "2001:db8::1",
            port = 8080,
            startEpochMillis = 1_700_000_000_000L,
            endEpochMillis = 1_700_000_060_000L,
        )
        val values = PcapFilterForm.values(query)
        assertEquals(PcapFilterForm.parse(values).query, query)
    }
}

class CoverageFormTest {
    @Test
    fun normalizesCoordinatesAndAcceptsTypedProbe() {
        val result = CoverageForm.parse(
            label = " Desk ",
            x = 1.4,
            y = -0.2,
            probeEnabled = true,
            probe = CoverageProbeRequestUi(kind = "tcp", host = "192.168.1.1", port = "443"),
        )
        assertTrue(result.errors.isEmpty())
        val request = result.request!!
        assertEquals("Desk", request.label)
        assertEquals(1.0, request.x, 0.0)
        assertEquals(0.0, request.y, 0.0)
        assertEquals("tcp", request.probe!!.kind)
        assertNotNull(CoverageForm.parse("Room", 0.5, 0.5, false, CoverageProbeRequestUi()).request)
    }

    @Test
    fun probeValidationRefusesUrlsInHostAndInvalidPorts() {
        val invalidHost = CoverageForm.parse(
            "Room", 0.5, 0.5, true,
            CoverageProbeRequestUi(kind = "ping", host = "https://example.com/x"),
        )
        assertTrue(invalidHost.errors.contains("probeHost"))
        val invalidPort = CoverageForm.parse(
            "Room", 0.5, 0.5, true,
            CoverageProbeRequestUi(kind = "tcp", host = "example.com", port = "0"),
        )
        assertTrue(invalidPort.errors.contains("probePort"))
        val invalidUrl = CoverageForm.parse(
            "Room", 0.5, 0.5, true,
            CoverageProbeRequestUi(kind = "speedDownload", endpointUrl = "http://example.com"),
        )
        assertTrue(invalidUrl.errors.contains("probeUrl"))
        assertNull(invalidHost.request)
    }

    @Test
    fun probeIsIgnoredWhenDisabled() {
        val result = CoverageForm.parse(
            "Room", 0.25, 0.75, false,
            CoverageProbeRequestUi(kind = "tcp", host = "", port = ""),
        )
        assertTrue(result.errors.isEmpty())
        assertNull(result.request!!.probe)
    }
}
