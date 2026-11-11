// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused regression for the N02 AppOps UID write scope:
 *  - the scope vocabulary is closed and refuses anything else;
 *  - UID ownership admission is independent and unique-UID only;
 *  - the success proof binds to the REQUESTED scope's read-back row, so a
 *    package-override match is never reported as an effective UID change
 *    (frozen C1 evidence) and vice versa.
 */
class PermissionOpsUidScopePolicyTest {

    // ---------------------------------------------------------- vocabulary

    @Test
    fun scopeVocabularyIsClosed() {
        assertEquals("package", PermissionOpsPolicy.appOpScope("package"))
        assertEquals("uid", PermissionOpsPolicy.appOpScope("uid"))
        assertNull(PermissionOpsPolicy.appOpScope("UID"))
        assertNull(PermissionOpsPolicy.appOpScope("user"))
        assertNull(PermissionOpsPolicy.appOpScope(""))
        assertNull(PermissionOpsPolicy.appOpScope(null))
        assertEquals(
            setOf(PermissionOpsPolicy.SCOPE_PACKAGE, PermissionOpsPolicy.SCOPE_UID),
            PermissionOpsPolicy.APPOP_SCOPES,
        )
        assertEquals("appOps.manage.uid", PermissionOpsPolicy.CAPABILITY_APPOPS_UID)
    }

    // --------------------------------------------- uid ownership admission

    @Test
    fun uniqueUidOwnershipIsAccepted() {
        assertNull(
            PermissionOpsPolicy.uidScopeOwnershipRefusal(
                listOf("com.example.app"), "com.example.app",
            ),
        )
    }

    @Test
    fun sharedUidRefuses() {
        assertEquals(
            "shared_uid_refused",
            PermissionOpsPolicy.uidScopeOwnershipRefusal(
                listOf("com.example.app", "com.example.sibling"), "com.example.app",
            ),
        )
    }

    @Test
    fun unresolvableOrInconsistentOwnershipRefuses() {
        assertEquals(
            "uid_scope_unavailable",
            PermissionOpsPolicy.uidScopeOwnershipRefusal(null, "com.example.app"),
        )
        assertEquals(
            "uid_scope_unavailable",
            PermissionOpsPolicy.uidScopeOwnershipRefusal(emptyList(), "com.example.app"),
        )
        // Sibling set exists but does not contain the requested package: the
        // identity cannot be established for THIS package.
        assertEquals(
            "uid_scope_unavailable",
            PermissionOpsPolicy.uidScopeOwnershipRefusal(
                listOf("com.example.other"), "com.example.app",
            ),
        )
    }

    // ------------------------------------------------- decision proof layer

    @Test
    fun uidScopeConcreteModeRequiresMatchingUidRow() {
        val ok = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "ignore", overrideAfter = null,
            scope = PermissionOpsPolicy.SCOPE_UID, uidAfter = "ignore",
        )
        assertTrue(ok.succeeded)
        assertEquals("mode_matched", ok.detailCode)

        // The package override matching while the UID row differs is a real
        // failure: the effective UID mode did not become the request.
        val wrongLayer = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "ignore", overrideAfter = "ignore",
            scope = PermissionOpsPolicy.SCOPE_UID, uidAfter = "foreground",
        )
        assertFalse(wrongLayer.succeeded)
        assertEquals("verify_failed", wrongLayer.detailCode)
    }

    @Test
    fun uidScopeDefaultProvenByAbsentOrDefaultUidRowOnly() {
        val absent = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "default", overrideAfter = "ignore",
            scope = PermissionOpsPolicy.SCOPE_UID, uidAfter = null,
        )
        assertTrue(absent.succeeded)
        val explicitDefault = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "default", overrideAfter = null,
            scope = PermissionOpsPolicy.SCOPE_UID, uidAfter = "default",
        )
        assertTrue(explicitDefault.succeeded)
        // A lingering concrete UID mode is NOT a restore to default.
        val lingering = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "default", overrideAfter = null,
            scope = PermissionOpsPolicy.SCOPE_UID, uidAfter = "ignore",
        )
        assertFalse(lingering.succeeded)
        assertEquals("verify_failed", lingering.detailCode)
    }

    @Test
    fun uidScopeOsRefusalStaysARealFailure() {
        val refused = PermissionOpsDecision.appOps(
            pmExitCode = 1, requestedMode = "ignore", overrideAfter = null,
            scope = PermissionOpsPolicy.SCOPE_UID, uidAfter = "ignore",
        )
        assertFalse(refused.succeeded)
        assertEquals("mode_failed", refused.detailCode)
    }

    @Test
    fun packageScopeLegacyProofIsUnchangedByUidRows() {
        // Legacy callers (default scope) keep proving on the package override
        // row; a UID row appearing in the same read never fabricates success.
        val ok = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "ignore", overrideAfter = "ignore",
        )
        assertTrue(ok.succeeded)
        val mismatch = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "ignore", overrideAfter = "allow",
        )
        assertFalse(mismatch.succeeded)
        val uidRowIgnoredForPackageScope = PermissionOpsDecision.appOps(
            pmExitCode = 0, requestedMode = "ignore", overrideAfter = "allow",
            scope = PermissionOpsPolicy.SCOPE_PACKAGE, uidAfter = "ignore",
        )
        assertFalse(uidRowIgnoredForPackageScope.succeeded)
    }
}
