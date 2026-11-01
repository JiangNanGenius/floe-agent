// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.pairing

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Discovers the local wireless-debugging connect port (`_adb-tls-connect._tcp`)
 * as upstream does. Only services whose resolved address belongs to this device
 * are accepted, and the port must be the one actually listening locally. If no
 * service is found, the host-configured explicit port is used. Pairing uses a
 * separate `_adb-tls-pairing._tcp` port entered by the user.
 */
internal class AdbDiscovery(private val context: Context) {

    fun findConnectPort(timeoutMillis: Long = 4000): Int? {
        if (Build.VERSION.SDK_INT < 30) return null
        val manager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return null
        val result = AtomicInteger(-1)
        val latch = CountDownLatch(1)
        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) = Unit

            override fun onServiceResolved(serviceInfo: NsdServiceInfo?) {
                if (serviceInfo == null) return
                val host = serviceInfo.host ?: return
                if (isLocalAddress(host.hostAddress) && isListening(serviceInfo.port)) {
                    if (result.compareAndSet(-1, serviceInfo.port)) latch.countDown()
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
                    // Duplicate resolve or service disappeared; discovery continues.
                }
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo?) = Unit
        }

        return try {
            manager.discoverServices(TYPE_CONNECT, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
            latch.await(timeoutMillis, TimeUnit.MILLISECONDS)
            manager.stopServiceDiscovery(discoveryListener)
            result.get().takeIf { it in 1..65535 }
        } catch (_: Throwable) {
            null
        }
    }

    private fun isLocalAddress(hostAddress: String?): Boolean {
        if (hostAddress.isNullOrBlank()) return false
        return try {
            val interfaces = NetworkInterface.getNetworkInterfaces() ?: return false
            val list = java.util.Collections.list(interfaces)
            list.any { networkInterface ->
                java.util.Collections.list(networkInterface.inetAddresses)
                    .any { it.hostAddress == hostAddress }
            }
        } catch (_: Throwable) {
            false
        }
    }

    /** A local bind failure means adbd is already listening on that port. */
    private fun isListening(port: Int): Boolean = try {
        ServerSocket().use {
            it.bind(InetSocketAddress("127.0.0.1", port), 1)
            false
        }
    } catch (_: Throwable) {
        true
    }

    companion object {
        const val TYPE_CONNECT = "_adb-tls-connect._tcp"
        const val TYPE_PAIRING = "_adb-tls-pairing._tcp"
    }
}
