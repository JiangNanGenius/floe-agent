// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM checks for the numeric-only Writer viewport-sync diagnostic packet.
 * Authored here, NOT RUN — Main runs the grouped JVM pass.
 */
class OfficeViewportGeometryTest {

    private val valid =
        "floe-viewport-geometry" +
            " main=2560x0>2560x1071" +
            " doc=2560x0>2560x1071" +
            " canvas=0x0>2560x1071" +
            " viewport=2560x1311" +
            " html=2560x1311" +
            " body=2560x1311" +
            " sync=applied"

    @Test
    fun validNumericPacketBecomesBoundedDetail() {
        assertEquals(
            valid.removePrefix(OfficeViewportGeometry.COMMAND + " "),
            OfficeViewportGeometry.diagnosticDetail(valid),
        )
    }

    @Test
    fun everyOutcomeLabelIsAcceptedButNothingElseIs() {
        for (outcome in listOf("applied", "absent", "failed", "stale")) {
            val message = valid.substringBeforeLast('=') + "=" + outcome
            val detail = OfficeViewportGeometry.diagnosticDetail(message)
            assertTrue(outcome, detail != null && detail.endsWith("sync=$outcome"))
        }
        assertNull(OfficeViewportGeometry.diagnosticDetail(valid.substringBeforeLast('=') + "=ready"))
    }

    @Test
    fun malformedNumericPacketsFailClosed() {
        for (message in listOf(
            "",
            OfficeViewportGeometry.COMMAND,
            valid + " trailing",
            valid + "\n",
            valid.replace("main=", "main=content-"),
            valid.replace("main=2560x0>2560x1071", "main=2560x0"),
            valid.replace("canvas=0x0>2560x1071", "canvas=-1x0>2560x1071"),
            valid.replace("canvas=0x0>2560x1071", "canvas=0x0>2560x1234567"),
            valid.replace("viewport=2560x1311", "viewport=2560"),
            valid.replace("sync=applied", "sync=ready"),
            valid.replace(" main=", " doc="),
            // Reordered keys are refused even when each value is well formed.
            "floe-viewport-geometry doc=2560x0>2560x1071 main=2560x0>2560x1071" +
                " canvas=0x0>2560x1071 viewport=2560x1311 html=2560x1311 body=2560x1311 sync=applied",
        )) assertNull(message, OfficeViewportGeometry.diagnosticDetail(message))
    }

    @Test
    fun geometryPacketsNeverReachNativeCommandTransport() {
        for (mode in listOf(CoolMessageGate.Mode.READ_ONLY, CoolMessageGate.Mode.EDITABLE)) {
            assertEquals(
                mode.toString(),
                CoolMessageGate.Decision.BLOCK_WITHOUT_NOTICE,
                CoolMessageGate.decide(valid, mode).decision,
            )
        }
    }
}
