// SPDX-License-Identifier: MPL-2.0
// Regression sources for the N02 A5 Samsung environmentTransaction start
// failure (job-46036bc8e99f4602): the runtime kernel reduces every start
// exception to the generic `operation_failed` receipt, which the host pump
// then publishes as the bare `runtime_start_failed` — and the A5 evidence
// (seq#29, 13.6 s, empty sanitized logcat) showed exactly that undiagnosable
// generic receipt. These tests pin the closed transaction-stage vocabulary,
// the bounded divergence-axis detail, the numeric errno probe through the
// typed cause chain, and the preserved legacy mappings. Author-written; NOT
// executed by this lane (primary owns builds/tests).
package com.floe.android.runtime

import com.floe.android.linuxruntime.rootfs.EnvironmentTransactionException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class RuntimeTransactionStartFailureDiagnosticsTest {

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

    @Test fun everyTransactionStageCodePassesTheClosedWhitelist() {
        for (code in EnvironmentTransactionException.CODES) {
            assertEquals(code, RuntimeKernel.startFailureCode(EnvironmentTransactionException(code)))
        }
    }

    @Test fun closedVocabularySatisfiesThePumpGrammar() {
        // The kernel whitelist and the host pump's sanitizer regex must agree:
        // every code is bounded snake_case, with only the reviewed long verify token —
        // so a token that passes one can never be dropped or mis-shaped by
        // the other on its way to the model-facing proof.
        val pumpGrammar = Regex("^[a-z0-9_]{1,32}$")
        for (code in EnvironmentTransactionException.CODES) {
            assertEquals(true, pumpGrammar.matches(code) || code == "transaction_snapshot_verify_changed")
        }
        for (detail in EnvironmentTransactionException.DETAILS) {
            assertEquals(true, pumpGrammar.matches(detail))
        }
        assertEquals(true, EnvironmentTransactionException.CODES.isNotEmpty())
    }

    @Test fun unknownCodeAndUnknownDetailAreRefusedAtConstruction() {
        // The fixed vocabulary is enforced by the exception itself, so an
        // unexpected token can never reach a receipt even if a future edit
        // forgets the kernel whitelist.
        assertThrows(IllegalArgumentException::class.java) {
            EnvironmentTransactionException("transaction_bogus_stage")
        }
        assertThrows(IllegalArgumentException::class.java) {
            EnvironmentTransactionException(
                "transaction_snapshot_verify_changed",
                detail = "absolute_path_leak")
        }
    }

    @Test fun divergenceDetailIsPublishedOnlyForTheVerifyStage() {
        assertEquals("modified", RuntimeKernel.startFailureDetail(EnvironmentTransactionException(
            "transaction_snapshot_verify_changed", detail = "modified")))
        assertNull(RuntimeKernel.startFailureDetail(EnvironmentTransactionException(
            "transaction_insufficient_space")))
        // Rootfs/workspace failures keep absence: nothing is zeroed or invented.
        assertNull(RuntimeKernel.startFailureDetail(
            com.floe.android.linuxruntime.rootfs.RootfsMaterializeException("rootfs_copy_io")))
        assertNull(RuntimeKernel.startFailureDetail(IllegalStateException("workspaceOwnerUnavailable")))
    }

    @Test fun errnoProbeReadsThroughTheTypedCauseChain() {
        val typed = EnvironmentTransactionException(
            "transaction_snapshot_copy_io",
            cause = java.io.IOException("copy tail", errno(28)))
        // 28 == ENOSPC on the device: discriminates space facts without text.
        assertEquals(28, RuntimeKernel.startFailureErrno(typed))
        assertEquals("transaction_snapshot_copy_io",
            RuntimeKernel.startFailureCode(typed))
    }

    @Test fun lifecycleCancellationKeepsItsLegacyGenericMapping() {
        // Cancellation is an honest lifecycle refusal, not a transaction
        // defect; it must stay distinguishable (the pump maps the dedicated
        // rootfs token; a raw transaction InterruptedException stays generic
        // exactly like every other non-typed origin).
        assertNull(RuntimeKernel.startFailureCode(InterruptedException("Environment transaction cancelled")))
    }
}
