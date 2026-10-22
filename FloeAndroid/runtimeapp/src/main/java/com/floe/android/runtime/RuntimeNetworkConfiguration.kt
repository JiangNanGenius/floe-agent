// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.content.Context
import android.net.ConnectivityManager
import com.floe.android.linuxruntime.LinuxBind
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardOpenOption

/** Snapshot the currently assigned network DNS; no public resolver fallback. */
internal object RuntimeNetworkConfiguration {
    fun resolverBind(context: Context, ownedFreshScratch: File): LinuxBind? {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val active = manager.activeNetwork ?: return null // offline local work remains available
        val link = manager.getLinkProperties(active) ?: return null
        val addresses = link.dnsServers.mapNotNull { it.hostAddress }
            .distinct().take(8).filter { value ->
                value.length <= 128 && value.all { it.isDigit() || it.lowercaseChar() in 'a'..'z' || it in ":.%_-" }
            }
        if (addresses.isEmpty()) return null
        val resolver = File(ownedFreshScratch, "resolv.conf")
        Files.write(resolver.toPath(), addresses.joinToString("\n", postfix = "\n") { "nameserver $it" }
            .toByteArray(Charsets.US_ASCII), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)
        android.system.Os.chmod(resolver.path, 0x180) // owner read/write, no credential data
        return LinuxBind(resolver, "/etc/resolv.conf")
    }
}
