// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkInfo
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import java.io.Closeable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.json.JSONObject

/** Android platform binding for the frozen PhoneNetworkService API. */
internal class AndroidNetworkPlatform(context: Context) : NetworkPlatform {
    private val appContext = context.applicationContext
    private val connectivity: ConnectivityManager? =
        appContext.getSystemService(ConnectivityManager::class.java)
    private val wifi: WifiManager? = appContext.getSystemService(WifiManager::class.java)
    private val location: LocationManager? = appContext.getSystemService(LocationManager::class.java)

    override fun openSession(request: ParsedRequest): NetworkSession =
        AndroidNetworkSession(appContext, connectivity, wifi, location, request)
}

/**
 * One execute() call. The active Network is captured once and every method
 * uses that exact handle. Constructor and service construction perform no
 * probe or permission dialog.
 */
internal class AndroidNetworkSession(
    internal val context: Context,
    private val connectivity: ConnectivityManager?,
    internal val wifi: WifiManager?,
    private val location: LocationManager?,
    private val request: ParsedRequest,
) : NetworkSession {
    private val networkPermissionGranted = context.hasPermission(Manifest.permission.ACCESS_NETWORK_STATE)
    override val missingPermissions: List<String> =
        requiredPermissions(request).filterNot { context.hasPermission(it) }

    internal val activeNetwork: Network? = if (networkPermissionGranted) {
        runCatching { connectivity?.activeNetwork }.getOrNull()
    } else {
        null
    }
    private val linkProperties: LinkProperties? = activeNetwork?.let { network ->
        runCatching { connectivity?.getLinkProperties(network) }.getOrNull()
    }
    private val capabilities: NetworkCapabilities? = activeNetwork?.let { network ->
        runCatching { connectivity?.getNetworkCapabilities(network) }.getOrNull()
    }

    @Suppress("DEPRECATION")
    private val networkInfo: NetworkInfo? = activeNetwork?.let { network ->
        runCatching { connectivity?.getNetworkInfo(network) }.getOrNull()
    }

    internal val locationServicesEnabled: Boolean? = location?.let { manager ->
        runCatching { manager.isLocationEnabled() }.getOrNull()
    }

    override val snapshot: NetworkSnapshot = captureSnapshot()
    private val resources = SessionResources()

    /** API 28 has no cancellable resolver; bound its worker and close it with the session. */
    internal val api28Resolver: ExecutorService by lazy {
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "floe-network-dns28").apply { isDaemon = true }
        }.also { executor ->
            resources.track { executor.shutdownNow() }
        }
    }

    private val isClosed: Boolean get() = resources.isClosed

    override suspend fun status(): ProbeResult {
        if (connectivity == null) {
            return ProbeResult(
                status = ObservationStatus.UNSUPPORTED,
                observations = JSONObject().put("errorCode", "connectivityManagerUnavailable"),
                limitations = listOf("ConnectivityManager is unavailable on this device."),
            )
        }
        val observations = JSONObject()
        observations.put("activeNetwork", snapshot.available)
        snapshot.networkCount?.let { observations.put("networkCount", it) }
        airplaneMode()?.let { observations.put("airplaneMode", it) }
        wifi?.let { manager ->
            runCatching { manager.isWifiEnabled }.getOrNull()
                ?.let { observations.put("wifiEnabled", it) }
            runCatching { manager.wifiState }.getOrNull()
                ?.let { observations.put("wifiState", WifiChannels.wifiStateName(it)) }
            runCatching { manager.isScanAlwaysAvailable }.getOrNull()
                ?.let { observations.put("scanAlwaysAvailable", it) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                runCatching { manager.isScanThrottleEnabled }.getOrNull()
                    ?.let { observations.put("scanThrottleEnabled", it) }
            }
        }
        locationServicesEnabled?.let { observations.put("locationServicesEnabled", it) }
        snapshot.privateDnsActive?.let { observations.put("privateDnsActive", it) }
        snapshot.privateDnsServerName?.let { observations.put("privateDnsServerName", it) }
        snapshot.vpn.let { observations.put("vpnTransport", it) }
        snapshot.metered?.let { observations.put("metered", it) }
        snapshot.validated?.let { observations.put("validated", it) }
        snapshot.internet?.let { observations.put("internet", it) }
        snapshot.localNetwork?.let { observations.put("localNetworkCapability", it) }
        snapshot.captivePortal?.let { observations.put("captivePortal", it) }
        return ProbeResult(observations = observations, limitations = snapshot.limitations)
    }

    override suspend fun wifiScan(refresh: Boolean): ProbeResult =
        AndroidWifiScan.scan(this, refresh)

    override suspend fun dnsLookup(
        host: String,
        recordType: DnsRecordType,
        timeoutMs: Int,
    ): ProbeResult = AndroidDnsLookup.lookup(this, host, recordType, timeoutMs)

    override suspend fun ping(host: String, count: Int, timeoutMs: Int): ProbeResult =
        AndroidIcmpPing.ping(this, host, count, timeoutMs)

    override suspend fun tcpProbe(host: String, port: Int, timeoutMs: Int): ProbeResult =
        AndroidTcpProbe.probe(this, host, port, timeoutMs)

    override suspend fun http(
        target: HttpTarget,
        timeoutMs: Int,
        maxRedirects: Int,
    ): ProbeResult = AndroidHttpsProbe.probe(this, target, timeoutMs, maxRedirects)

    override fun close() {
        resources.closeAll()
    }

    internal fun trackCloseable(closeable: Closeable) {
        resources.track { runCatching { closeable.close() } }
    }

    internal fun trackAction(action: () -> Unit) {
        resources.track(action)
    }

    internal fun localNetworkPermissionMissing(): Boolean =
        Build.VERSION.SDK_INT >= 37 &&
            !context.hasPermission(LOCAL_NETWORK_PERMISSION)

    internal fun localNetworkMissingPermissions(): List<String> =
        if (localNetworkPermissionMissing()) listOf(LOCAL_NETWORK_PERMISSION) else emptyList()

    internal fun isSessionClosed(): Boolean = isClosed

    private fun captureSnapshot(): NetworkSnapshot {
        if (connectivity == null) {
            return NetworkSnapshot(
                available = false,
                limitations = listOf("ConnectivityManager is unavailable on this device."),
            )
        }
        if (!networkPermissionGranted) {
            return NetworkSnapshot(
                available = false,
                limitations = listOf(
                    "ACCESS_NETWORK_STATE is not granted; the active network could not be captured.",
                ),
            )
        }
        val networkCount = connectivity?.let { manager ->
            runCatching { manager.allNetworks.size }.getOrNull()
        }
        val network = activeNetwork ?: return NetworkSnapshot(
            available = false,
            networkCount = networkCount,
            limitations = listOf("No active default network."),
        )
        val limitations = ArrayList<String>()
        val caps = capabilities
        val link = linkProperties
        val info = networkInfo
        if (caps == null) limitations += "NetworkCapabilities are unavailable for the active network."
        if (link == null) limitations += "LinkProperties are unavailable for the active network."
        if (info == null) limitations += "Legacy NetworkInfo is unavailable; type/state fields are absent."

        val vpnTransport = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        if (vpnTransport) {
            limitations += "The active network is a VPN; the underlying physical transport is not exposed by NetworkCapabilities."
        }
        val transports = ArrayList<String>()
        if (caps != null) {
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) transports += "wifi"
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) transports += "cellular"
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) transports += "ethernet"
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) transports += "vpn"
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) transports += "bluetooth"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                caps.hasTransport(NetworkCapabilities.TRANSPORT_USB)
            ) {
                transports += "usb"
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
                caps.hasTransport(NetworkCapabilities.TRANSPORT_SATELLITE)
            ) {
                transports += "satellite"
            }
        }

        val capabilityNames = ArrayList<String>()
        if (caps != null) {
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) capabilityNames += "internet"
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) capabilityNames += "validated"
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) capabilityNames += "notMetered"
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING)) capabilityNames += "notRoaming"
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED)) capabilityNames += "notSuspended"
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)) capabilityNames += "notRestricted"
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)) capabilityNames += "trusted"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_LOCAL_NETWORK)
            ) {
                capabilityNames += "localNetwork"
            }
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL)) capabilityNames += "captivePortal"
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_WIFI_P2P)) capabilityNames += "wifiP2p"
        }

        val proxy = link?.httpProxy
        val proxyHost: String?
        val proxyPort: Int?
        if (proxy == null) {
            proxyHost = null
            proxyPort = null
        } else {
            proxyHost = proxy.host
            proxyPort = proxy.port.takeIf { it > 0 }
            if (proxy.pacFileUrl != null) {
                limitations += "The active network uses a PAC proxy; its proxy host/port are not exposed here."
            }
        }

        val signalStrength = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            caps?.getSignalStrength()?.takeIf { it > NetworkCapabilities.SIGNAL_STRENGTH_UNSPECIFIED }
        } else {
            null
        }

        val nat64Prefix = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            link?.nat64Prefix?.toString()
        } else {
            null
        }
        val dhcpServer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            link?.dhcpServerAddress?.hostAddress
        } else {
            null
        }
        val wakeOnLan = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            link?.isWakeOnLanSupported()
        } else {
            null
        }

        return NetworkSnapshot(
            available = true,
            handle = "0x${java.lang.Long.toHexString(network.networkHandle)}",
            networkCount = networkCount,
            transports = transports,
            capabilities = capabilityNames,
            typeName = info?.typeName,
            subtypeName = info?.subtypeName,
            state = info?.state?.name,
            detailedState = info?.detailedState?.name,
            connected = info?.isConnected,
            roaming = info?.isRoaming,
            metered = connectivity?.let { manager ->
                runCatching { manager.isActiveNetworkMetered }.getOrNull()
            },
            validated = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            internet = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            localNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
                caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_LOCAL_NETWORK)
            } else {
                null
            },
            captivePortal = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL),
            vpn = vpnTransport,
            interfaceName = link?.interfaceName,
            mtu = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) link?.mtu else null,
            dnsServers = link?.dnsServers?.mapNotNull { it.hostAddress } ?: emptyList(),
            domains = link?.domains,
            privateDnsActive = link?.isPrivateDnsActive(),
            privateDnsServerName = link?.privateDnsServerName,
            httpProxyHost = proxyHost,
            httpProxyPort = proxyPort,
            linkAddresses = link?.linkAddresses?.map {
                "${it.address.hostAddress}/${it.prefixLength}"
            } ?: emptyList(),
            routes = link?.routes?.size,
            nat64Prefix = nat64Prefix,
            dhcpServer = dhcpServer,
            wakeOnLanSupported = wakeOnLan,
            signalStrength = signalStrength,
            downstreamKbps = caps?.linkDownstreamBandwidthKbps?.takeIf { it >= 0 },
            upstreamKbps = caps?.linkUpstreamBandwidthKbps?.takeIf { it >= 0 },
            wifi = if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) {
                captureWifiLink(limitations)
            } else {
                null
            },
            limitations = limitations,
        )
    }

    private fun captureWifiLink(limitations: MutableList<String>): WifiLinkSnapshot? {
        val manager = wifi
        if (manager == null) {
            limitations += "WifiManager is unavailable on this device."
            return null
        }
        if (!context.hasPermission(Manifest.permission.ACCESS_WIFI_STATE)) {
            limitations += "ACCESS_WIFI_STATE is not granted; Wi-Fi link details are unavailable."
            return null
        }
        val info: WifiInfo = runCatching { manager.getConnectionInfo() }.getOrNull() ?: run {
            limitations += "WifiManager returned no connection info."
            return null
        }
        val ssidRaw = runCatching { info.getSSID() }.getOrNull()
        val ssid = WifiChannels.normalizeSsid(ssidRaw)
        val bssidRaw = runCatching { info.getBSSID() }.getOrNull()
        val bssid = WifiChannels.normalizeBssid(bssidRaw)
        if (ssid == null) {
            limitations += "Wi-Fi SSID is redacted or unavailable; fine location and location services may be required."
        }
        if (bssid == null) {
            limitations += "Wi-Fi BSSID is redacted or unavailable."
        }
        val frequency = runCatching { info.getFrequency() }.getOrNull()?.takeIf { it > 0 }
        val rssi = runCatching { info.getRssi() }.getOrNull()?.takeIf { it in -126..0 }
        val linkSpeed = runCatching { info.getLinkSpeed() }.getOrNull()?.takeIf { it > 0 }
        val rxSpeed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching { info.getRxLinkSpeedMbps() }.getOrNull()?.takeIf { it > 0 }
        } else {
            null
        }
        val txSpeed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching { info.getTxLinkSpeedMbps() }.getOrNull()?.takeIf { it > 0 }
        } else {
            null
        }
        val standard = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            runCatching { info.getWifiStandard() }.getOrNull()
                ?.takeIf { it > 0 }
                ?.let { WifiChannels.standardName(it) }
        } else {
            null
        }
        val hidden = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            runCatching { info.getHiddenSSID() }.getOrNull()
        } else {
            null
        }
        return WifiLinkSnapshot(
            ssid = ssid,
            ssidRedacted = ssid == null,
            bssid = bssid,
            bssidRedacted = bssid == null,
            rssiDbm = rssi,
            frequencyMhz = frequency,
            channel = frequency?.let { WifiChannels.channelForFrequency(it) },
            band = frequency?.let { WifiChannels.bandForFrequency(it).label },
            linkSpeedMbps = linkSpeed,
            rxLinkSpeedMbps = rxSpeed,
            txLinkSpeedMbps = txSpeed,
            wifiStandard = standard,
            hiddenSsid = hidden,
        )
    }

    private fun airplaneMode(): Boolean? = runCatching {
        Settings.Global.getInt(
            context.contentResolver,
            Settings.Global.AIRPLANE_MODE_ON,
            0,
        ) != 0
    }.getOrNull()

    private fun requiredPermissions(request: ParsedRequest): List<String> = buildList {
        add(Manifest.permission.ACCESS_NETWORK_STATE)
        when (request.method) {
            NetworkMethod.STATUS -> Unit
            NetworkMethod.WIFI_SCAN -> {
                add(Manifest.permission.ACCESS_WIFI_STATE)
                add(Manifest.permission.ACCESS_FINE_LOCATION)
                if (request.refresh) add(Manifest.permission.CHANGE_WIFI_STATE)
            }
            else -> add(Manifest.permission.INTERNET)
        }
    }

    private class SessionResources {
        private val lock = Any()
        private val actions = ArrayList<() -> Unit>()
        private var closed = false

        val isClosed: Boolean get() = synchronized(lock) { closed }

        fun track(action: () -> Unit) {
            val runNow = synchronized(lock) {
                if (closed) {
                    true
                } else {
                    actions += action
                    false
                }
            }
            if (runNow) runCatching { action() }
        }

        fun closeAll() {
            val copy = synchronized(lock) {
                if (closed) return
                closed = true
                actions.toList().also { actions.clear() }
            }
            copy.forEach { action -> runCatching { action() } }
        }
    }

    companion object {
        internal const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
    }
}

private fun Context.hasPermission(permission: String): Boolean =
    checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
