// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import java.net.NetworkInterface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Bounded discovery of THIS device's wireless-debugging pairing port
 * (`_adb-tls-pairing._tcp`). Android advertises the same pairing service the
 * system settings screen shows; the numeric port is ephemeral and stays in RAM.
 *
 * Safety: only a resolved address that belongs to one of this device's own
 * network interfaces is accepted. A foreign/other-device advertisement is
 * ignored. When discovery is unavailable (API < 30, NSD disabled, no answer in
 * the bounded window) the settings page keeps an explicit numeric pairing-port
 * field instead of guessing or scanning a port range.
 */
internal object AdbPairingPortDiscovery {

    private const val SERVICE_TYPE = "_adb-tls-pairing._tcp"
    private const val TIMEOUT_MILLIS = 6_000L

    /** Blocking; call from an IO dispatcher. */
    fun findPairingPort(context: Context, timeoutMillis: Long = TIMEOUT_MILLIS): Int? {
        if (Build.VERSION.SDK_INT < 30) return null
        val manager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
            ?: return null
        val localAddresses = localAddresses()
        if (localAddresses.isEmpty()) return null
        val result = AtomicInteger(-1)
        val latch = CountDownLatch(1)
        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) = Unit

            override fun onServiceResolved(serviceInfo: NsdServiceInfo?) {
                val host = serviceInfo?.host?.hostAddress ?: return
                val port = serviceInfo.port
                if (port in 1..65535 && host in localAddresses) {
                    if (result.compareAndSet(-1, port)) latch.countDown()
                }
            }
        }
        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String?) = Unit

            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                latch.countDown()
            }

            override fun onDiscoveryStopped(serviceType: String?) = Unit

            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo?) {
                if (serviceInfo == null) return
                try {
                    manager.resolveService(serviceInfo, resolveListener)
                } catch (_: Throwable) {
                    // A duplicate resolve/service loss must not abort discovery.
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo?) = Unit
        }
        return try {
            manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
            latch.await(timeoutMillis, TimeUnit.MILLISECONDS)
            manager.stopServiceDiscovery(discoveryListener)
            result.get().takeIf { it in 1..65535 }
        } catch (_: Throwable) {
            null
        }
    }

    fun localAddresses(): Set<String> = try {
        val interfaces = NetworkInterface.getNetworkInterfaces() ?: return emptySet()
        val addresses = HashSet<String>()
        for (networkInterface in java.util.Collections.list(interfaces)) {
            for (address in java.util.Collections.list(networkInterface.inetAddresses)) {
                address.hostAddress?.let { addresses += it }
            }
        }
        addresses
    } catch (_: Throwable) {
        emptySet()
    }

    /** Pure port acceptance; the pairing code itself is never handled here. */
    fun parsePort(raw: String): Int? {
        val digits = raw.filter { it.isDigit() }.take(5)
        val port = digits.toIntOrNull() ?: return null
        return port.takeIf { it in 1..65535 }
    }
}
