// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WifiChannelsTest {
    @Test
    fun maps2_4GHzChannels() {
        assertEquals(WifiBand.BAND_2_4, WifiChannels.bandForFrequency(2_412))
        assertEquals(1, WifiChannels.channelForFrequency(2_412))
        assertEquals(6, WifiChannels.channelForFrequency(2_437))
        assertEquals(11, WifiChannels.channelForFrequency(2_462))
        assertEquals(14, WifiChannels.channelForFrequency(2_484))
    }

    @Test
    fun maps5GHzAnd6GHzChannels() {
        assertEquals(WifiBand.BAND_5, WifiChannels.bandForFrequency(5_180))
        assertEquals(36, WifiChannels.channelForFrequency(5_180))
        assertEquals(149, WifiChannels.channelForFrequency(5_745))
        assertEquals(WifiBand.BAND_6, WifiChannels.bandForFrequency(5_955))
        assertEquals(1, WifiChannels.channelForFrequency(5_955))
        assertEquals(37, WifiChannels.channelForFrequency(6_135))
    }

    @Test
    fun unknownOrOutOfBandFrequenciesStayUnavailable() {
        assertEquals(WifiBand.UNKNOWN, WifiChannels.bandForFrequency(0))
        assertNull(WifiChannels.channelForFrequency(0))
        assertNull(WifiChannels.channelForFrequency(2_000))
        assertEquals(WifiBand.BAND_60, WifiChannels.bandForFrequency(60_480))
        assertNull(WifiChannels.channelForFrequency(60_480))
    }

    @Test
    fun mapsWidthsStandardsAndSecurityLabels() {
        assertEquals(20, WifiChannels.channelWidthMhz(0))
        assertEquals(40, WifiChannels.channelWidthMhz(1))
        assertEquals(80, WifiChannels.channelWidthMhz(2))
        assertEquals(160, WifiChannels.channelWidthMhz(3))
        assertEquals(160, WifiChannels.channelWidthMhz(4))
        assertEquals(320, WifiChannels.channelWidthMhz(5))
        assertNull(WifiChannels.channelWidthMhz(99))
        assertEquals("802.11ax", WifiChannels.standardName(6))
        assertEquals("802.11be", WifiChannels.standardName(8))
        assertNull(WifiChannels.standardName(99))
        assertEquals("sae", WifiChannels.securityTypeName(4))
        assertEquals("passpoint-r3", WifiChannels.securityTypeName(12))
    }

    @Test
    fun freshnessUsesRealAgeBuckets() {
        assertEquals("unknown", WifiChannels.freshness(null))
        assertEquals("fresh", WifiChannels.freshness(0))
        assertEquals("fresh", WifiChannels.freshness(120_000))
        assertEquals("aging", WifiChannels.freshness(120_001))
        assertEquals("aging", WifiChannels.freshness(300_000))
        assertEquals("stale", WifiChannels.freshness(300_001))
    }

    @Test
    fun normalizesIdentifiersWithoutChangingSsidContent() {
        assertEquals("  spaced ssid  ", WifiChannels.normalizeSsid("  spaced ssid  "))
        assertNull(WifiChannels.normalizeSsid(null))
        assertNull(WifiChannels.normalizeSsid(""))
        assertNull(WifiChannels.normalizeSsid("<unknown ssid>"))
        assertEquals("aa:bb:cc:dd:ee:ff", WifiChannels.normalizeBssid("AA:BB:CC:DD:EE:FF"))
        assertNull(WifiChannels.normalizeBssid("02:00:00:00:00:00"))
        assertNull(WifiChannels.normalizeBssid(null))
    }

    @Test
    fun mapsWifiStateNames() {
        assertEquals("disabled", WifiChannels.wifiStateName(1))
        assertEquals("enabled", WifiChannels.wifiStateName(3))
        assertEquals("state-9", WifiChannels.wifiStateName(9))
    }
}
