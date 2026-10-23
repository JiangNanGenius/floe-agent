// SPDX-License-Identifier: MPL-2.0
// Focused origin-side regressions for the G03-R3 failed-start receipt
// emitter ceiling (job-150dee8e1ed14ba1) in RuntimeKernel.
// Author-written against the exact public 349a8690b91a73eae29a73df5cafdb9fdea2f878
// baseline; intended for the existing runtimeapp JVM unit-test source set
// (org.json and Android are deliberately absent there — the same constraint
// RuntimeStoppingFenceTest documents — so these tests drive the PURE
// decision helper the kernel catch delegates to; the org.json assembly and
// the WorkspaceBridgeException type gate are exercised by Main's real
// mid-import cancel device fixture, not by a mocked kernel).
// NOT executed by this lane.
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class RuntimeKernelFailedStartAddendaTest {

    private val recovery = """{"record":"importRestore","sessionKey":"${"ab".repeat(16)}","runID":"A1B2C3D4-0000-4000-9000-000000000004",""" +
        """"trigger":"cancelRequested","restoredPriorChanges":3,"revertedNewEntries":1,"retainedFailures":0}"""

    @Test fun typedOriginalCodeAndInBoundRecoveryPass() {
        val addenda = RuntimeKernel.failedStartReceiptAddenda("importCancelled", recovery)
        assertNotNull(addenda)
        assertEquals("importCancelled", addenda!!.first)
        assertEquals(recovery, addenda.second) // verbatim: the kernel never re-encodes counters
    }

    @Test fun colonSuffixedRealCodesStayValid() {
        // The original engine emits codes like "snapshotSizeUnderrun:5" or
        // "<code>:restoreFailures2" — printable ASCII with ':' stays valid;
        // the host-side closed parse is what gates publication anyway.
        val addenda = RuntimeKernel.failedStartReceiptAddenda("importCancelled:restoreFailures2", recovery)
        assertNotNull(addenda)
        assertEquals("importCancelled:restoreFailures2", addenda!!.first)
    }

    @Test fun missingRecoveryKeepsTheLegacySkeleton() {
        // A bridge failure WITHOUT its own measured recovery (e.g. a refusal
        // before the swap journal) never gets an addendum: the failed record
        // stays the byte-identical generic terminal.
        assertNull(RuntimeKernel.failedStartReceiptAddenda("grantClosed", null))
    }

    @Test fun oversizedRecoveryDropped() {
        val huge = "x".repeat(4_097)
        assertNull(RuntimeKernel.failedStartReceiptAddenda("importCancelled", huge))
        // Exactly at the ceiling the emitter passes; the host pump performs
        // the authoritative closed-grammar re-validation.
        assertNotNull(RuntimeKernel.failedStartReceiptAddenda("importCancelled", "x".repeat(4_096)))
    }

    @Test fun nonPrintableOrOverlongCodesDropped() {
        assertNull(RuntimeKernel.failedStartReceiptAddenda("x".repeat(49), recovery))
        assertNull(RuntimeKernel.failedStartReceiptAddenda("", recovery))
        assertNull(RuntimeKernel.failedStartReceiptAddenda("has space", recovery))
        assertNull(RuntimeKernel.failedStartReceiptAddenda("line\nbreak", recovery))
        assertNull(RuntimeKernel.failedStartReceiptAddenda("路径/private", recovery))
    }

    @Test fun exactlyFortyEightCharsStillValid() {
        val code = "c".repeat(48)
        assertEquals(code, RuntimeKernel.failedStartReceiptAddenda(code, recovery)?.first)
    }
}
