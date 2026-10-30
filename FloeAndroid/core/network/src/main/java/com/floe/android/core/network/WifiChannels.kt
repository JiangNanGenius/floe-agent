// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.util.Locale

internal enum class WifiBand(val label: String) {
    BAND_2_4("2.4GHz"),
    BAND_5("5GHz"),
    BAND_6("6GHz"),
    BAND_60("60GHz"),
    UNKNOWN("unknown"),
}

/**
 * Pure frequency/channel mapping. Android reports frequencies in MHz; channel
 * numbers are derived for the three bands used by the G07 Wi-Fi workbench.
 * 60 GHz is labelled but intentionally not converted (unknown is not guessed).
 */
internal object WifiChannels {
    const val FRESH_AGE_MS = 120_000L
    const val STALE_AGE_MS = 300_000L

    fun bandForFrequency(frequencyMhz: Int): WifiBand = when {
        frequencyMhz in 2_400..2_500 -> WifiBand.BAND_2_4
        frequencyMhz in 5_150..5_925 -> WifiBand.BAND_5
        frequencyMhz in 5_925..7_125 -> WifiBand.BAND_6
        frequencyMhz in 57_000..71_000 -> WifiBand.BAND_60
        else -> WifiBand.UNKNOWN
    }

    fun channelForFrequency(frequencyMhz: Int): Int? = when (bandForFrequency(frequencyMhz)) {
        WifiBand.BAND_2_4 -> when (frequencyMhz) {
            2_484 -> 14
            in 2_407..2_483 -> (frequencyMhz - 2_407) / 5
            else -> null
        }
        WifiBand.BAND_5 -> ((frequencyMhz - 5_000) / 5).takeIf { it in 1..196 }
        WifiBand.BAND_6 -> ((frequencyMhz - 5_950) / 5).takeIf { it in 1..233 }
        else -> null
    }

    fun channelWidthMhz(raw: Int): Int? = when (raw) {
        0 -> 20
        1 -> 40
        2 -> 80
        3 -> 160
        4 -> 160 // 80+80 MHz: two non-contiguous 80 MHz segments
        5 -> 320
        else -> null
    }

    fun standardName(raw: Int): String? = when (raw) {
        0 -> "unknown"
        1 -> "legacy"
        4 -> "802.11n"
        5 -> "802.11ac"
        6 -> "802.11ax"
        7 -> "802.11ad"
        8 -> "802.11be"
        else -> null
    }

    fun securityTypeName(raw: Int): String = when (raw) {
        -1 -> "unknown"
        0 -> "open"
        1 -> "wep"
        2 -> "psk"
        3 -> "eap"
        4 -> "sae"
        5 -> "eap-wpa3-enterprise-192"
        6 -> "owe"
        7 -> "wapi-psk"
        8 -> "wapi-cert"
        9 -> "eap-wpa3-enterprise"
        10 -> "osen"
        11 -> "passpoint-r1-r2"
        12 -> "passpoint-r3"
        13 -> "dpp"
        else -> "type-$raw"
    }

    fun freshness(ageMs: Long?): String = when {
        ageMs == null -> "unknown"
        ageMs <= FRESH_AGE_MS -> "fresh"
        ageMs <= STALE_AGE_MS -> "aging"
        else -> "stale"
    }

    fun wifiStateName(raw: Int): String = when (raw) {
        0 -> "disabling"
        1 -> "disabled"
        2 -> "enabling"
        3 -> "enabled"
        4 -> "unknown"
        else -> "state-$raw"
    }

    fun normalizeSsid(raw: String?): String? {
        val value = raw ?: return null
        if (value.isEmpty()) return null
        if (value.equals("<unknown ssid>", ignoreCase = true)) return null
        return value
    }

    fun normalizeBssid(raw: String?): String? {
        val value = raw?.trim().orEmpty()
        if (value.isEmpty()) return null
        if (value.equals("02:00:00:00:00:00", ignoreCase = true)) return null
        return value.lowercase(Locale.ROOT)
    }

    fun normalizeCapabilities(raw: String?): String? =
        raw?.trim()?.takeIf { it.isNotEmpty() }?.take(200)
}
