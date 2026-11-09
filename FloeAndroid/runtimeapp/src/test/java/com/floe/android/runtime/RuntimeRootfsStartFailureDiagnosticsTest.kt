// SPDX-License-Identifier: MPL-2.0
// Regression sources for the Alpha68 Samsung materialization-start failure
// (job-d169dd02bbb941bd): the runtime kernel reduces every start exception to
// the generic `operation_failed` receipt, which the host pump then publishes
// as the bare `runtime_start_failed` — the exact device failure was
// undiagnosable. These tests pin the closed stage/type vocabulary for the
// rootfs materializer refusals, the cancellation lifecycle token, the
// message-mapped preparation refusals, and the bounded numeric errno probe.
// Author-written; NOT executed by this lane (primary owns builds/tests).
package com.floe.android.runtime

import com.floe.android.linuxruntime.rootfs.RootfsMaterializeException
import com.floe.android.linuxruntime.rootfs.RootfsPrepareCancelledException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RuntimeRootfsStartFailureDiagnosticsTest {

    // Use the actual Android stub's public errno field without running its
    // unimplemented host constructor or defining a java.base split package.
    private fun errno(value: Int): Throwable {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val unsafe = unsafeClass.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
        val type = Class.forName("android.system.ErrnoException")
        val instance = unsafeClass.getMethod("allocateInstance", Class::class.java)
            .invoke(unsafe, type) as Throwable
        type.getField("errno").apply { isAccessible = true }.setInt(instance, value)
        return instance
    }

    @Test fun everyMaterializerCodePassesTheClosedWhitelist() {
        for (code in RootfsMaterializeException.CODES) {
            assertEquals(code, RuntimeKernel.startFailureCode(RootfsMaterializeException(code)))
        }
    }

    @Test fun closedVocabularySatisfiesThePumpGrammar() {
        // The kernel whitelist and the host pump's sanitizer regex must agree:
        // every code is lowercase snake_case, <= 32 chars, printable ASCII —
        // so a token that passes one can never be dropped or mis-shaped by
        // the other on its way to the model-facing proof.
        val pumpGrammar = Regex("^[a-z0-9_]{1,32}$")
        for (code in RootfsMaterializeException.CODES) {
            assertEquals(true, pumpGrammar.matches(code))
        }
        assertEquals(true, RootfsMaterializeException.CODES.isNotEmpty())
    }

    @Test fun cancellationIsDistinguishableFromDefects() {
        assertEquals("rootfs_cancelled",
            RuntimeKernel.startFailureCode(RootfsPrepareCancelledException()))
        // A raw InterruptedException from another preparation lane (workspace
        // import, transaction snapshot) keeps the legacy generic mapping.
        assertNull(RuntimeKernel.startFailureCode(InterruptedException("Environment snapshot cancelled")))
    }

    @Test fun preparationRefusalMessagesMapToActionableCodes() {
        assertEquals("workspace_unsupported_entries",
            RuntimeKernel.startFailureCode(IllegalStateException("Workspace snapshot contains unsupported entries")))
        assertEquals("process_admission_refused",
            RuntimeKernel.startFailureCode(IllegalStateException("Linux process was not admitted")))
        assertEquals("process_launch_failed",
            RuntimeKernel.startFailureCode(IllegalStateException("Linux process launch failed")))
        // Arbitrary text (paths, native messages) still maps to nothing.
        assertNull(RuntimeKernel.startFailureCode(IllegalStateException("/data/user/0/private")))
    }

    @Test fun errnoProbeFindsBoundedErrnoInCauseChain() {
        val errno = errno(5)
        val wrapped = RuntimeException("copy", java.io.IOException("fsync failed", errno))
        assertEquals(5, RuntimeKernel.startFailureErrno(IllegalStateException("rootfs", wrapped)))
    }

    @Test fun errnoProbeStaysNullWithoutErrnoHolder() {
        assertNull(RuntimeKernel.startFailureErrno(IllegalStateException("no cause")))
        assertNull(RuntimeKernel.startFailureErrno(
            IllegalStateException("plain", java.io.IOException("no errno"))))
    }

    @Test fun errnoProbeBoundsAndReflectiveFailures() {
        // Out-of-range values are dropped, never clamped.
        val huge = errno(99999)
        assertNull(RuntimeKernel.startFailureErrno(IllegalStateException("x", huge)))
        val negative = errno(-1)
        assertNull(RuntimeKernel.startFailureErrno(IllegalStateException("x", negative)))
    }
}
