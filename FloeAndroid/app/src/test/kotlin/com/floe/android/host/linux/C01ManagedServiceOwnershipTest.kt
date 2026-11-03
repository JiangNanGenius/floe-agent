// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import com.floe.android.host.services.C01ManagedServiceOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * C01 focused ownership rules. These are pure checks: no emulator, engine,
 * process, port listener or provider is started by this test.
 */
class C01ManagedServiceOwnershipTest {
    @Test
    fun onlyTheV3ContractAdvertisesManagedServiceRoles() {
        assertTrue(C01ManagedServiceOwner.contractSupportsServices("floe-multi-workload-v3"))
        assertFalse(C01ManagedServiceOwner.contractSupportsServices("floe-multi-workload-v2"))
        assertFalse(C01ManagedServiceOwner.contractSupportsServices("floe-single-workload-v1"))
        assertFalse(C01ManagedServiceOwner.contractSupportsServices(null))
        assertFalse(C01ManagedServiceOwner.contractSupportsServices(""))
    }

    @Test
    fun declarationRejectsEscapesAndOutOfRangePorts() {
        assertNull(C01ManagedServiceOwner.declarationRefusal("node", "server.js", 8080))
        assertEquals("runtime", C01ManagedServiceOwner.declarationRefusal("static", "index.html", 8080))
        assertEquals("entry", C01ManagedServiceOwner.declarationRefusal("node", "../server.js", 8080))
        assertEquals("entry", C01ManagedServiceOwner.declarationRefusal("node", "/etc/passwd", 8080))
        assertEquals("port", C01ManagedServiceOwner.declarationRefusal("python", "server.py", 80))
        assertEquals("port", C01ManagedServiceOwner.declarationRefusal("shell", "server.sh", 70000))
        assertEquals("port", C01ManagedServiceOwner.declarationRefusal("shell", "server.sh", null))
    }

    @Test
    fun onePortCanOnlyBeReservedOnceAndIsReleased() {
        val port = 43811
        assertTrue(C01ManagedServiceOwner.reservePort(port))
        assertFalse("a second service must not adopt the same port",
            C01ManagedServiceOwner.reservePort(port))
        assertTrue(C01ManagedServiceOwner.isReserved(port))
        C01ManagedServiceOwner.releasePort(port)
        assertFalse(C01ManagedServiceOwner.isReserved(port))
        assertTrue(C01ManagedServiceOwner.reservePort(port))
        C01ManagedServiceOwner.releasePort(port)
    }

    @Test
    fun invalidPortsAreNeverReserved() {
        assertFalse(C01ManagedServiceOwner.reservePort(80))
        assertFalse(C01ManagedServiceOwner.reservePort(0))
        assertFalse(C01ManagedServiceOwner.reservePort(65536))
        assertFalse(C01ManagedServiceOwner.isReserved(80))
        assertNotNull(C01ManagedServiceOwner.probeLoopback(80).second)
        assertTrue("an invalid port is fail-closed as in-use",
            C01ManagedServiceOwner.probeLoopback(80).first)
    }

    @Test
    fun anEphemeralFreePortIsProbedWithoutClaimingReadiness() {
        val port = java.net.ServerSocket(0).use { it.localPort }
        val (inUse, detail) = C01ManagedServiceOwner.probeLoopback(port)
        // The socket has been closed, so the free port must not be reported
        // in use. The probe still makes no readiness/ownership claim.
        assertFalse(inUse)
        assertTrue(detail == "portAvailable" || detail == "portBound")
    }
}
