// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Author-written (NOT executed by this source stage) regressions for the
 * post112 owner/lease life cycle:
 *
 * A live one-shot session must not hold its Core foreground lease and grant
 * forever after the runtime component process was replaced (the actual
 * "open the Gallery, come back, exec.shell is refused" carrier). The pump
 * watcher may retire LOCAL ownership ONLY when it has two real, non-empty
 * measured process identities that differ AND the successor runtime reports
 * runtimeRecoveryProven (its original whole-UID recovery/census completed).
 * An absent token/proof, an equal token or any transport uncertainty keeps
 * the original retention: no timer, error-string or count-based release.
 */
class LinuxShellGenerationRetirementTest {

    @Test
    fun differentMeasuredGenerationsRetireTheLocalOwner() {
        assertTrue(LinuxShellPump.runtimeGenerationRetired("boot-A", "boot-B"))
    }

    @Test
    fun sameGenerationIsNotRetirement() {
        assertFalse(LinuxShellPump.runtimeGenerationRetired("boot-A", "boot-A"))
    }

    @Test
    fun absentOrEmptyTokensNeverProveRetirement() {
        assertFalse(LinuxShellPump.runtimeGenerationRetired(null, "boot-B"))
        assertFalse(LinuxShellPump.runtimeGenerationRetired("boot-A", null))
        assertFalse(LinuxShellPump.runtimeGenerationRetired("", "boot-B"))
        assertFalse(LinuxShellPump.runtimeGenerationRetired("boot-A", ""))
    }

    @Test
    fun changedTokenWithoutSuccessorRecoveryProofRetainsTheOwner() {
        // A new component PID can exist while its original whole-UID
        // recovery/census has not completed. The token change alone must not
        // release the old lease/FGS/ledger ownership.
        assertFalse(LinuxShellPump.canRetireByGeneration("boot-A", "boot-B", recoveryProven = false))
        assertFalse(LinuxShellPump.canRetireByGeneration("boot-A", "boot-B", recoveryProven = null))
    }

    @Test
    fun changedTokenWithProvenSuccessorRecoveryMayRetire() {
        assertTrue(LinuxShellPump.canRetireByGeneration("boot-A", "boot-B", recoveryProven = true))
    }

    @Test
    fun sameGenerationOrAbsentProofNeverRetires() {
        assertFalse(LinuxShellPump.canRetireByGeneration("boot-A", "boot-A", recoveryProven = true))
        assertFalse(LinuxShellPump.canRetireByGeneration(null, "boot-B", recoveryProven = true))
        assertFalse(LinuxShellPump.canRetireByGeneration("boot-A", null, recoveryProven = true))
        assertFalse(LinuxShellPump.canRetireByGeneration("boot-A", "", recoveryProven = true))
    }
}
