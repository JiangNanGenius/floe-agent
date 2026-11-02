// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.services

import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap

/**
 * C01 app-side managed-service admission/probe helpers.
 *
 * This object owns NO process, job row or engine lease: those remain in the
 * Core service domain, the ORIGINAL durable job store and the runtime-UID
 * engine. It only provides the bounded facts the trusted pump needs before
 * starting a service:
 *   * the exact runtime contract string required for the two service roles;
 *   * a loopback preflight that refuses a port already answering or already
 *     bound (ownership is proven AFTER start by the runtime's service.readiness
 *     /proc LISTEN-inode proof, never by this probe);
 *   * a process-local reservation so two service starts in this process cannot
 *     race onto the same port.
 *
 * Every answer is fail-closed. A model, prompt or command cannot mint a
 * reservation or claim readiness through this object.
 */
object C01ManagedServiceOwner {
    /** The only helper contract that adds the two service roles. */
    const val REQUIRED_CONTRACT = "floe-multi-workload-v3"

    private val reserved = ConcurrentHashMap.newKeySet<Int>()

    /** Pure: an older v2/invalid contract keeps ordinary exec but no service. */
    fun contractSupportsServices(contractVersion: String?): Boolean =
        contractVersion == REQUIRED_CONTRACT

    /** Pure declaration bounds used by focused tests and future callers. */
    fun declarationRefusal(runtime: String?, entry: String?, port: Int?): String? {
        if (runtime !in setOf("shell", "node", "python")) return "runtime"
        val path = entry ?: return "entry"
        if (path.isBlank() || path.length > 2048 || path.startsWith("/") ||
            path.startsWith("~") || path.split('/').contains("..")
        ) return "entry"
        if (port == null || port !in 1024..65535) return "port"
        return null
    }

    /** Reserve one loopback port for THIS process's managed service. */
    fun reservePort(port: Int): Boolean =
        port in 1024..65535 && reserved.add(port)

    fun releasePort(port: Int) {
        reserved.remove(port)
    }

    fun isReserved(port: Int): Boolean = reserved.contains(port)

    /**
     * Pre-start probe. Returns (inUse, detail). A refused connect with a
     * successful exclusive bind means available. Any exception/unknown is
     * treated as in-use (fail closed). This never claims readiness.
     */
    fun probeLoopback(port: Int): Pair<Boolean, String> {
        if (port !in 1024..65535) return true to "invalidPort"
        val address = InetSocketAddress("127.0.0.1", port)
        val connectable = try {
            java.net.Socket().use { socket ->
                socket.connect(address, 250)
                true
            }
        } catch (_: Exception) {
            false
        }
        if (connectable) return true to "alreadyAnswering"
        val bindable = try {
            java.net.ServerSocket().use { server ->
                server.reuseAddress = false
                server.bind(address, 1)
                true
            }
        } catch (_: Exception) {
            false
        }
        return if (bindable) false to "portAvailable" else true to "portBound"
    }
}
