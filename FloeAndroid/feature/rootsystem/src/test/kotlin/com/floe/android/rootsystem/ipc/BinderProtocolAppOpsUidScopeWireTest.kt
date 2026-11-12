// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused regression for the N02 AppOps UID write scope on the wire:
 *  - the AIDL transaction contract is untouched (VERSION 4, first 19 legacy
 *    positions, every appended method in order, 37 total) — the scope rides
 *    inside the existing manageAppOps Bundle, never a new transaction;
 *  - the new request/reply/grant keys are distinct, bounded and live in the
 *    closed permission/AppOps key block.
 */
class BinderProtocolAppOpsUidScopeWireTest {

    @Test
    fun wireContractIsUnchangedByTheUidScope() {
        assertEquals(4, BinderProtocol.VERSION)
        assertEquals(19, BinderProtocol.wire2LegacyMethods.size)
        assertEquals(
            listOf("queryPermissions", "managePermissions", "queryAppOps", "manageAppOps"),
            BinderProtocol.wire5AppendedMethods,
        )
        val all = BinderProtocol.wire2LegacyMethods + BinderProtocol.appendedMethods
        assertEquals(37, all.size)
        assertEquals(all.size, all.toSet().size)
    }

    @Test
    fun uidScopeKeysAreDistinctBoundedAndClosed() {
        val existing = listOf(
            BinderProtocol.KEY_PERMISSION_NAME,
            BinderProtocol.KEY_PERMISSION_ACTION,
            BinderProtocol.KEY_PERMISSIONS,
            BinderProtocol.KEY_APPOP_OPERATION,
            BinderProtocol.KEY_APPOP_MODE,
            BinderProtocol.KEY_APPOPS,
            BinderProtocol.KEY_GRANTED,
            BinderProtocol.KEY_GRANTED_BEFORE,
            BinderProtocol.KEY_PROTECTION_LEVEL,
            BinderProtocol.KEY_OVERRIDE_MODE,
            BinderProtocol.KEY_UID_MODE,
            BinderProtocol.KEY_DEFAULT_MODE,
            BinderProtocol.KEY_EFFECTIVE_MODE,
            BinderProtocol.KEY_OVERRIDE_BEFORE,
            BinderProtocol.KEY_UID_BEFORE,
            BinderProtocol.KEY_DEFAULT_BEFORE,
            BinderProtocol.KEY_EFFECTIVE_BEFORE,
            BinderProtocol.KEY_REQUESTED_MODE,
            BinderProtocol.KEY_OP_NAME,
        )
        val added = listOf(
            BinderProtocol.KEY_APPOP_SCOPE,
            BinderProtocol.KEY_RESOLVED_UID,
            BinderProtocol.KEY_UID_AFTER,
            BinderProtocol.KEY_APPOPS_UID_SCOPE,
        )
        for (key in added) {
            assertTrue(key.length <= 32)
            assertTrue(key.isNotEmpty())
        }
        assertEquals(added.size, added.toSet().size)
        // A new key must never shadow an existing closed key.
        assertTrue(existing.intersect(added.toSet()).isEmpty())
        // Reply-side scope key shares the appOp prefix block; the UID after
        // row is distinct from the historical uidBefore/uidMode keys.
        assertEquals("appOpScope", BinderProtocol.KEY_APPOP_SCOPE)
        assertEquals("resolvedUid", BinderProtocol.KEY_RESOLVED_UID)
        assertEquals("uidAfter", BinderProtocol.KEY_UID_AFTER)
        assertEquals("appOpsUidScope", BinderProtocol.KEY_APPOPS_UID_SCOPE)
    }

    @Test
    fun capabilityTokenMatchesThePolicyConstant() {
        // The App host gates scope=uid on this exact describe() string; the
        // protocol object mirrors the policy constant so a rename on one
        // side fails this test instead of silently splitting the contract.
        assertEquals(
            com.floe.android.rootsystem.policy.PermissionOpsPolicy.CAPABILITY_APPOPS_UID,
            "appOps.manage.uid",
        )
    }
}
