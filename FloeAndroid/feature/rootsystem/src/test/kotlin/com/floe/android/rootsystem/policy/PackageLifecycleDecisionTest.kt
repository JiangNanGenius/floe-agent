// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PackageLifecycleDecisionTest {
    private fun install(exit: Int = 0, present: Boolean = true,
        actualVersion: Long? = 2L, signer: Boolean = true) =
        PackageLifecycleDecision.install(PackageLifecycleDecision.InstallFacts(
            pmExitCode = exit, presentAfter = present, archiveVersionCode = 2L,
            installedVersionCode = actualVersion, signingMatched = signer))

    @Test fun failedUpdateCannotUseOldInstalledPackageAsSuccess() {
        assertFalse(install(exit = 1, actualVersion = 1L).succeeded)
        assertFalse(install(exit = 1, actualVersion = 2L).succeeded)
    }

    @Test fun zeroExitRequiresActualRequestedVersionAndPresence() {
        assertFalse(install(present = false, actualVersion = null).succeeded)
        assertFalse(install(actualVersion = 1L).succeeded)
        assertFalse(install(actualVersion = 3L).succeeded)
        assertFalse(install(actualVersion = null).succeeded)
    }

    @Test fun missingOrDifferentSignerCannotVerifyAnInstall() {
        assertFalse(install(signer = false).succeeded)
    }

    @Test fun successfulCommandAndMatchingReadbackConfirmInstall() {
        assertTrue(install().succeeded)
    }

    @Test fun uninstallRequiresSuccessAndActualAbsence() {
        for (exit in listOf(0, 1)) for (present in listOf(false, true)) {
            val result = PackageLifecycleDecision.uninstall(
                PackageLifecycleDecision.UninstallFacts(exit, present))
            org.junit.Assert.assertEquals(exit == 0 && !present, result.succeeded)
        }
    }

    @Test fun perUserRemovalHasTheSameProofShapeAsUninstall() {
        for (exit in listOf(0, 1)) for (present in listOf(false, true)) {
            val result = PackageLifecycleDecision.removeForUser(
                PackageLifecycleDecision.UninstallFacts(exit, present))
            org.junit.Assert.assertEquals(exit == 0 && !present, result.succeeded)
            org.junit.Assert.assertEquals(
                if (exit == 0 && !present) "absent" else if (exit != 0) "uninstall_failed"
                    else "verify_failed",
                result.detailCode,
            )
        }
    }

    @Test fun restoreRequiresSuccessAndActualPresence() {
        for (exit in listOf(0, 1)) for (present in listOf(false, true)) {
            val result = PackageLifecycleDecision.restore(
                PackageLifecycleDecision.RestoreFacts(exit, present))
            org.junit.Assert.assertEquals(exit == 0 && present, result.succeeded)
            org.junit.Assert.assertEquals(
                if (exit == 0 && present) "present" else if (exit != 0) "restore_failed"
                    else "verify_failed",
                result.detailCode,
            )
        }
    }

    @Test fun setEnabledRequiresTheRequestedReadBackState() {
        for ((command, observed) in listOf(
            "enable" to "enabled", "disable" to "disabled", "disable-user" to "disabled-user",
        )) {
            assertTrue(PackageLifecycleDecision.setEnabled(0, command, observed).succeeded)
            assertFalse(PackageLifecycleDecision.setEnabled(0, command, command).succeeded)
        }
        assertFalse(PackageLifecycleDecision.setEnabled(0, "unknown", "unknown").succeeded)
        // A zero exit is not enough: the observed state must match.
        val mismatch = PackageLifecycleDecision.setEnabled(0, "disable", "enabled")
        org.junit.Assert.assertFalse(mismatch.succeeded)
        org.junit.Assert.assertEquals("verify_failed", mismatch.detailCode)
        // OS refusal (nonzero exit) is a real failure, never "unsupported".
        val refused = PackageLifecycleDecision.setEnabled(1, "disable", "disabled")
        org.junit.Assert.assertFalse(refused.succeeded)
        org.junit.Assert.assertEquals("state_failed", refused.detailCode)
    }
}
