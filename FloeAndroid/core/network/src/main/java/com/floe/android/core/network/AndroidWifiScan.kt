// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.os.Build
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

/**
 * Real WifiManager scan-result measurement. `refresh=true` registers the
 * SCAN_RESULTS_AVAILABLE_ACTION receiver before requesting a scan and waits
 * cancellably for the real EXTRA_RESULTS_UPDATED signal or a bounded timeout.
 * The OS cache is always reported with its own timestamps/age; startScan()
 * acceptance alone never claims a refreshed measurement.
 */
internal object AndroidWifiScan {
    private const val SCAN_COMPLETION_TIMEOUT_MS = 5_000L

    suspend fun scan(session: AndroidNetworkSession, refresh: Boolean): ProbeResult {
        val manager = session.wifi
            ?: return ProbeResult(
                status = ObservationStatus.UNSUPPORTED,
                observations = JSONObject().put("errorCode", "wifiManagerUnavailable"),
                limitations = listOf("WifiManager is unavailable on this device."),
            )
        if (session.missingPermissions.isNotEmpty()) {
            return ProbeResult(
                status = ObservationStatus.PERMISSION_REQUIRED,
                observations = JSONObject().put("requiredFor", NetworkMethod.WIFI_SCAN.wire),
                limitations = session.snapshot.limitations,
                missingPermissions = session.missingPermissions,
            )
        }
        val wifiEnabled = runCatching { manager.isWifiEnabled() }.getOrNull()
        val wifiState = runCatching { manager.getWifiState() }.getOrNull()
        val locationEnabled = session.locationServicesEnabled
        val limitations = ArrayList<String>()
        val observations = JSONObject().apply {
            put("refreshRequested", refresh)
            wifiEnabled?.let { put("wifiEnabled", it) }
            wifiState?.let { put("wifiState", WifiChannels.wifiStateName(it)) }
            locationEnabled?.let { put("locationServicesEnabled", it) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                runCatching { manager.isScanThrottleEnabled }.getOrNull()
                    ?.let { put("scanThrottleEnabled", it) }
            }
        }

        if (locationEnabled == false) {
            observations.put("scanResultsAvailable", false)
            return ProbeResult(
                status = ObservationStatus.UNAVAILABLE,
                observations = observations,
                limitations = limitations + "Location services are disabled; Android hides Wi-Fi scan results from apps.",
            )
        }

        val completion = CompletableDeferred<Boolean>()
        val scanRequested = AtomicBoolean(false)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (!scanRequested.get()) return
                val updated = intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, false)
                completion.complete(updated)
            }
        }
        var receiverRegistered = false
        var scanAccepted: Boolean? = null
        var resultsUpdated: Boolean? = null
        try {
            if (refresh) {
                receiverRegistered = registerScanReceiver(session.context, receiver)
                if (!receiverRegistered) {
                    limitations += "The scan-completion broadcast receiver could not be registered; no scan was requested and cached rows are shown with their real age."
                    observations.put("scanRequested", false)
                    observations.put("scanCompletionObserved", false)
                } else {
                    observations.put("scanCompletionTimeoutMs", SCAN_COMPLETION_TIMEOUT_MS)
                    scanAccepted = try {
                        manager.startScan()
                    } catch (_: SecurityException) {
                        val missing = missingWifiPermissions(session, includeChange = true)
                        return ProbeResult(
                            status = ObservationStatus.PERMISSION_REQUIRED,
                            observations = observations.put("requiredFor", NetworkMethod.WIFI_SCAN.wire),
                            limitations = session.snapshot.limitations,
                            missingPermissions = missing,
                        )
                    } catch (_: Exception) {
                        false
                    }
                    scanRequested.set(true)
                    observations.put("scanAccepted", scanAccepted)
                    if (scanAccepted == false) {
                        limitations += "The OS refused the explicit scan request (Wi-Fi disabled, scan throttled or policy restricted)."
                    } else {
                        resultsUpdated = withTimeoutOrNull(SCAN_COMPLETION_TIMEOUT_MS) { completion.await() }
                        if (resultsUpdated == null) {
                            limitations += "No scan-completion broadcast arrived within 5 seconds; cached rows are shown with their real age."
                        } else {
                            observations.put("resultsUpdated", resultsUpdated)
                            if (resultsUpdated == false) {
                                limitations += "The scan-completion broadcast reported no updated results; cached rows are shown with their real age."
                            }
                        }
                    }
                    observations.put("scanCompletionObserved", resultsUpdated != null)
                }
            }

            val results = try {
                manager.getScanResults() ?: emptyList()
            } catch (_: SecurityException) {
                return ProbeResult(
                    status = ObservationStatus.PERMISSION_REQUIRED,
                    observations = observations.put("requiredFor", NetworkMethod.WIFI_SCAN.wire),
                    limitations = session.snapshot.limitations,
                    missingPermissions = missingWifiPermissions(session, includeChange = false),
                )
            } catch (failure: Exception) {
                return ProbeResult(
                    status = ObservationStatus.ERROR,
                    observations = observations
                        .put("errorCode", "wifiScanResultsFailed")
                        .put("errorClass", failure.javaClass.simpleName.take(64)),
                    limitations = limitations + "WifiManager did not return a scan result list.",
                )
            }

            if (results.isNotEmpty()) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                    limitations += "Wi-Fi standard requires Android 11 and security types require Android 13; only the capability text is reported."
                } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    limitations += "Wi-Fi security type fields require Android 13; only the capability text is reported."
                }
            }
            val nowMicros = SystemClock.elapsedRealtimeNanos() / 1_000L
            val rows = results.map { result -> result.toJson(nowMicros, limitations) }
                .sortedWith(
                    compareByDescending<JSONObject> { it.optInt("rssiDbm", -999) }
                        .thenBy { it.optInt("frequencyMhz", 0) }
                        .thenBy { it.optString("bssid", "") },
                )
            val total = rows.size
            val page = if (rows.size > NetworkLimits.MAX_ACCESS_POINTS) {
                rows.take(NetworkLimits.MAX_ACCESS_POINTS)
            } else {
                rows
            }
            if (page.size < total) {
                limitations += "Only the first ${NetworkLimits.MAX_ACCESS_POINTS} access points are reported."
            }
            val ages = rows.mapNotNull { row ->
                if (row.has("ageMs")) row.optLong("ageMs") else null
            }
            val cacheAgeMs = ages.minOrNull()
            if (cacheAgeMs != null) {
                observations.put("cacheAgeMs", cacheAgeMs)
                observations.put("freshness", WifiChannels.freshness(cacheAgeMs))
            } else {
                limitations += "No access point had a usable scan timestamp."
            }
            observations.put("totalAccessPoints", total)
            observations.put("truncated", page.size < total)
            observations.put("accessPoints", JSONArray().apply { page.forEach { put(it) } })
            observations.put("channelCounts", channelCounts(page))
            observations.put("hardware", hardware(session, manager))
            if (refresh && !receiverRegistered) {
                observations.put("refreshOutcome", "completionUnavailable")
            } else if (refresh && scanAccepted == true && resultsUpdated != true) {
                observations.put(
                    "refreshOutcome",
                    when {
                        resultsUpdated == null -> "completionTimeout"
                        else -> "notUpdated"
                    },
                )
            } else if (refresh && scanAccepted == false) {
                observations.put("refreshOutcome", "refused")
            } else if (refresh) {
                observations.put("refreshOutcome", "updated")
            }

            val status = when {
                page.isEmpty() && wifiEnabled == false -> ObservationStatus.UNAVAILABLE
                refresh && (scanAccepted != true || resultsUpdated != true) -> ObservationStatus.PARTIAL
                else -> ObservationStatus.OK
            }
            if (page.isEmpty()) {
                limitations += "The OS returned no cached access points."
            }
            if (wifiEnabled == false) {
                limitations += "Wi-Fi is disabled; cached results may be empty or stale."
            }
            return ProbeResult(
                status = status,
                observations = observations,
                limitations = limitations,
                cacheAgeMs = cacheAgeMs,
            )
        } finally {
            if (receiverRegistered) {
                runCatching { session.context.unregisterReceiver(receiver) }
            }
            if (!completion.isCompleted) completion.complete(false)
        }
    }

    private fun ScanResult.toJson(nowMicros: Long, limitations: MutableList<String>): JSONObject {
        val ageMs = if (timestamp > 0 && nowMicros >= timestamp) {
            (nowMicros - timestamp) / 1_000L
        } else {
            null
        }
        val ssid = WifiChannels.normalizeSsid(SSID)
        val bssid = WifiChannels.normalizeBssid(BSSID)
        if (ssid == null || bssid == null) {
            limitations += "One or more access point identifiers were redacted or unavailable."
        }
        return JSONObject().apply {
            ssid?.let { put("ssid", it) }
            if (ssid == null) put("ssidRedacted", true)
            bssid?.let { put("bssid", it) }
            if (bssid == null) put("bssidRedacted", true)
            put("rssiDbm", level)
            put("frequencyMhz", frequency)
            WifiChannels.channelForFrequency(frequency)?.let { put("channel", it) }
            WifiChannels.bandForFrequency(frequency).let { put("band", it.label) }
            WifiChannels.channelWidthMhz(channelWidth)?.let { put("widthMhz", it) }
            if (centerFreq0 > 0) put("centerFreq0Mhz", centerFreq0)
            if (centerFreq1 > 0) put("centerFreq1Mhz", centerFreq1)
            if (timestamp > 0) {
                put("timestampMicros", timestamp)
                put("timestampSource", "elapsedRealtimeMicros")
            }
            ageMs?.let {
                put("ageMs", it)
                put("freshness", WifiChannels.freshness(it))
            }
            WifiChannels.normalizeCapabilities(capabilities)?.let { put("capabilities", it) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                runCatching { getWifiStandard() }.getOrNull()
                    ?.let { WifiChannels.standardName(it) }
                    ?.let { put("wifiStandard", it) }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val security = runCatching { getSecurityTypes() }.getOrNull()
                if (security != null && security.isNotEmpty()) {
                    put("securityTypes", JSONArray().apply {
                        security.forEach { put(WifiChannels.securityTypeName(it)) }
                    })
                }
            }
            put("passpoint", isPasspointNetwork())
            venueName?.toString()?.takeIf { it.isNotBlank() }?.let { put("venue", it.take(100)) }
            operatorFriendlyName?.toString()?.takeIf { it.isNotBlank() }
                ?.let { put("operator", it.take(100)) }
        }
    }

    private fun registerScanReceiver(context: Context, receiver: BroadcastReceiver): Boolean = try {
        val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        true
    } catch (_: Exception) {
        false
    }

    private fun missingWifiPermissions(session: AndroidNetworkSession, includeChange: Boolean): List<String> {
        val required = ArrayList<String>()
        required += Manifest.permission.ACCESS_WIFI_STATE
        required += Manifest.permission.ACCESS_FINE_LOCATION
        if (includeChange) required += Manifest.permission.CHANGE_WIFI_STATE
        return required.filter { permission ->
            session.context.checkSelfPermission(permission) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    private fun channelCounts(rows: List<JSONObject>): JSONObject {
        var band24 = 0
        var band5 = 0
        var band6 = 0
        var other = 0
        rows.forEach { row ->
            when (row.optString("band")) {
                WifiBand.BAND_2_4.label -> band24++
                WifiBand.BAND_5.label -> band5++
                WifiBand.BAND_6.label -> band6++
                else -> other++
            }
        }
        return JSONObject()
            .put("2.4GHz", band24)
            .put("5GHz", band5)
            .put("6GHz", band6)
            .put("other", other)
    }

    private fun hardware(session: AndroidNetworkSession, manager: android.net.wifi.WifiManager): JSONObject {
        val hardware = JSONObject()
        runCatching { manager.is5GHzBandSupported() }.getOrNull()
            ?.let { hardware.put("supported5GHz", it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { manager.is24GHzBandSupported() }.getOrNull()
                ?.let { hardware.put("supported2_4GHz", it) }
            runCatching { manager.is60GHzBandSupported() }.getOrNull()
                ?.let { hardware.put("supported60GHz", it) }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            runCatching { manager.is6GHzBandSupported() }.getOrNull()
                ?.let { hardware.put("supported6GHz", it) }
            runCatching { manager.isWifiStandardSupported(ScanResult.WIFI_STANDARD_11AX) }.getOrNull()
                ?.let { hardware.put("supports11ax", it) }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            runCatching { manager.isWifiStandardSupported(ScanResult.WIFI_STANDARD_11BE) }.getOrNull()
                ?.let { hardware.put("supports11be", it) }
        }
        session.locationServicesEnabled?.let { hardware.put("locationServicesEnabled", it) }
        return hardware
    }
}
