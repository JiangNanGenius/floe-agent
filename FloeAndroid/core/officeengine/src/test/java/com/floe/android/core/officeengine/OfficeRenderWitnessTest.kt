// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.*
import org.junit.Test

class OfficeRenderWitnessTest {
    @Test fun pendingOrAnotherMountCannotGrantReadiness() {
        val old = OfficeRenderWitness.parse("floe-renderwitness nonce=snapshot:1 kind=ready draws=1 width=1280 height=720")!!
        assertTrue(old.readyFor("snapshot:1"))
        assertFalse(old.readyFor("snapshot:2"))
        assertFalse(OfficeRenderWitness.parse("floe-renderwitness nonce=snapshot:2 kind=pending draws=0 width=1280 height=720")!!.readyFor("snapshot:2"))
    }
    @Test fun impossibleOrAmbiguousReceiptsFailClosed() {
        for (message in listOf(
            "floe-renderwitness nonce=s:1 kind=ready draws=0 width=10 height=10",
            "floe-renderwitness nonce=s:1 kind=ready draws=1 width=0 height=10",
            "floe-renderwitness nonce=s:1 kind=ready draws=1 width=10 height=99999999",
            "floe-renderwitness nonce=s:1 kind=ready kind=pending width=10 height=10",
            "floe-renderwitness nonce=s:1 kind=ready draws=99999999999999 width=10 height=10",
            "floe-renderwitness nonce=s:1 kind=ready draws=1 width=10 height=10\n",
        )) assertNull(message, OfficeRenderWitness.parse(message))
    }
    @Test fun rendererPacketsNeverReachNativeCommandTransport() {
        assertEquals(CoolMessageGate.Decision.BLOCK_WITHOUT_NOTICE,
            CoolMessageGate.decide("floe-renderwitness nonce=s:1 kind=ready draws=1 width=10 height=10", true).decision)
    }
}
