// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure regression for the permission/AppOps outcome computation: a reported
 * success always means exit 0 plus an independent read-back equal to the
 * request; "default" is proven by the per-package override being gone OR
 * recorded default (restoring an inherited UID mode as a new package
 * override is never a restore); and effective-mode layering keeps the
 * restorable override/UID/default state separate from the actual behavior.
 */
class PermissionOpsDecisionTest {

    @Test
    fun permissionSuccessRequiresReadBackEquality() {
        val grant = PermissionOpsDecision.permission(
            pmExitCode = 0, action = "grant", grantedAfter = true,
        )
        assertTrue(grant.succeeded)
        assertEquals("state_matched", grant.detailCode)
        val revoke = PermissionOpsDecision.permission(
            pmExitCode = 0, action = "revoke", grantedAfter = false,
        )
        assertTrue(revoke.succeeded)
    }

    @Test
    fun permissionFailureCodesStayDistinct() {
        val refused = PermissionOpsDecision.permission(
            pmExitCode = 1, action = "grant", grantedAfter = false,
        )
        assertFalse(refused.succeeded)
        assertEquals("grant_failed", refused.detailCode)
        val revokeRefused = PermissionOpsDecision.permission(
            pmExitCode = 1, action = "revoke", grantedAfter = true,
        )
        assertEquals("revoke_failed", revokeRefused.detailCode)
        val drifted = PermissionOpsDecision.permission(
            pmExitCode = 0, action = "grant", grantedAfter = false,
        )
        assertFalse(drifted.succeeded)
        assertEquals("verify_failed", drifted.detailCode)
    }

    @Test
    fun concreteModeRequiresMatchingOverride() {
        val ok = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "ignore", overrideAfter = "ignore",
        )
        assertTrue(ok.succeeded)
        val mismatch = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "ignore", overrideAfter = "allow",
        )
        assertFalse(mismatch.succeeded)
        assertEquals("verify_failed", mismatch.detailCode)
        val commandFailed = PermissionOpsDecision.appOps(
            pmExitCode = 255, requestedMode = "ignore", overrideAfter = "ignore",
        )
        assertFalse(commandFailed.succeeded)
        assertEquals("mode_failed", commandFailed.detailCode)
    }

    @Test
    fun defaultIsProvenByGoneOrRecordedDefault() {
        val gone = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "default", overrideAfter = null,
        )
        assertTrue(gone.succeeded)
        val recorded = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "default", overrideAfter = "default",
        )
        assertTrue(recorded.succeeded)
        val stillThere = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "default", overrideAfter = "deny",
        )
        assertFalse(stillThere.succeeded)
    }

    @Test
    fun effectiveModeUsesUidPolicyBeforePackageAndDefault() {
        // Android's UID policy takes precedence over the package override.
        assertEquals(
            "foreground",
            PermissionOpsDecision.effectiveMode("allow", "foreground", "deny", false),
        )
        assertEquals("ignore",
            PermissionOpsDecision.effectiveMode("allow", "ignore", "allow", false))
        // An absent/default UID policy leaves the package policy in effect.
        assertEquals("ignore",
            PermissionOpsDecision.effectiveMode("ignore", "default", "allow", false))
        // An explicit "default" override row restores platform behavior: the
        // UID mode (an inherited mode, restorable as such) applies next.
        assertEquals(
            "foreground",
            PermissionOpsDecision.effectiveMode("default", "foreground", "allow", false),
        )
        // No override: UID mode, then platform default.
        assertEquals(
            "foreground",
            PermissionOpsDecision.effectiveMode(null, "foreground", "allow", false),
        )
        assertEquals(
            "allow",
            PermissionOpsDecision.effectiveMode(null, null, "allow", false),
        )
        // "No operations." with no default line: platform behavior applies.
        assertEquals(
            "default",
            PermissionOpsDecision.effectiveMode(null, null, null, true),
        )
        // Nothing recognized: unknown, never an invented allow.
        assertEquals(
            "unknown",
            PermissionOpsDecision.effectiveMode(null, null, null, false),
        )
    }
}
