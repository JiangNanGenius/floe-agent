// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import com.floe.android.rootsystem.GrantRequest
import com.floe.android.rootsystem.OperationClaim
import com.floe.android.rootsystem.SystemOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused regression for the canonical grant binding of the N02 AppOps UID
 * write scope: the allowance is part of the registered grant, so a grant
 * minted for a package-scoped AppOps operation can never be replayed as a
 * UID-wide write, and an unknown/revoked claim fails closed.
 */
class GrantRegistryAppOpsUidScopeTest {

    private fun request(uidScopeAllowed: Boolean) = GrantRequest(
        grantId = "grant-n02",
        taskId = "task",
        runId = "run",
        epoch = 1L,
        expiresAtMillis = 60_000L,
        scopes = listOf(com.floe.android.rootsystem.ScopeRoot("root", "/data/local/tmp", true)),
        operations = setOf(SystemOperation.APP_OPS_MANAGE),
        packageManagementAllowed = true,
        appOpsUidScopeAllowed = uidScopeAllowed,
    )

    private fun claim() = OperationClaim(
        taskId = "task",
        runId = "run",
        epoch = 1L,
        grantId = "grant-n02",
        requestId = "req",
    )

    @Test
    fun uidScopeAllowanceRoundTripsThroughRegistration() {
        val registry = GrantRegistry(clock = { 0L })
        assertTrue(registry.register(request(uidScopeAllowed = true)) is GrantRegistry.Registration.Ok)
        assertTrue(registry.appOpsUidScopeAllowed(claim()))
    }

    @Test
    fun packageScopedGrantNeverAllowsUidScope() {
        val registry = GrantRegistry(clock = { 0L })
        assertTrue(registry.register(request(uidScopeAllowed = false)) is GrantRegistry.Registration.Ok)
        assertFalse(registry.appOpsUidScopeAllowed(claim()))
    }

    @Test
    fun absentAllowanceDefaultsToPackageScopeOnly() {
        val registry = GrantRegistry(clock = { 0L })
        val legacy = request(uidScopeAllowed = false).copy(grantId = "grant-legacy")
        assertTrue(registry.register(legacy) is GrantRegistry.Registration.Ok)
        assertFalse(registry.appOpsUidScopeAllowed(claim().copy(grantId = "grant-legacy")))
    }

    @Test
    fun unknownOrRevokedClaimFailsClosed() {
        val registry = GrantRegistry(clock = { 0L })
        assertFalse(registry.appOpsUidScopeAllowed(claim()))
        registry.register(request(uidScopeAllowed = true))
        assertTrue(registry.revoke("grant-n02"))
        assertFalse(registry.appOpsUidScopeAllowed(claim()))
    }

    @Test
    fun uidScopeAllowanceRejectsAnotherTaskRunOrEpoch() {
        val registry = GrantRegistry(clock = { 0L })
        registry.register(request(uidScopeAllowed = true))
        assertFalse(registry.appOpsUidScopeAllowed(claim().copy(taskId = "other-task")))
        assertFalse(registry.appOpsUidScopeAllowed(claim().copy(runId = "other-run")))
        assertFalse(registry.appOpsUidScopeAllowed(claim().copy(epoch = 2L)))
    }

    @Test
    fun expiredCancelledAndFencedClaimsCannotKeepUidScope() {
        var now = 0L
        val registry = GrantRegistry(clock = { now })
        registry.register(request(uidScopeAllowed = true))
        now = 60_000L
        assertFalse(registry.appOpsUidScopeAllowed(claim()))
        now = 0L
        registry.cancel("req")
        assertFalse(registry.appOpsUidScopeAllowed(claim()))
        registry.fenceAll()
        assertFalse(registry.appOpsUidScopeAllowed(claim()))
    }

    @Test
    fun allowanceDoesNotWidenTheOperationOrTargetChecks() {
        // The allowance is an ADDITIONAL binding, not a replacement: the
        // ordinary operation/management/target checks still decide.
        val registry = GrantRegistry(clock = { 0L })
        registry.register(request(uidScopeAllowed = true))
        val readClaim = claim().copy(requestId = "req-ro")
        assertEquals(
            GrantRegistry.Verdict.Ok,
            registry.check(readClaim, SystemOperation.APP_OPS_MANAGE, null, write = true),
        )
    }
}
