// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.rootsystem.SystemOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** The host mirrors durable ceilings; canonical Swift issues actual grants. */
class AutomaticAdmissionPolicyTest {
    @Test
    fun fileMutationsRequireBothSelectedRootAndWriteCeiling() {
        for (selected in listOf(false, true)) for (writes in listOf(false, true)) {
            val ceiling = AutomaticAdmissionPolicy.Ceilings(
                requestedRootSelected = selected, fileWritesAllowed = writes,
                packageManagementAllowed = true)
            for (operation in listOf(SystemOperation.FILE_WRITE,
                SystemOperation.FILE_MOVE, SystemOperation.FILE_DELETE)) {
                assertEquals("$operation selected=$selected writes=$writes", selected && writes,
                    AutomaticAdmissionPolicy.isWithinEnabledCeilings(operation, ceiling))
            }
        }
    }

    @Test
    fun packageActionsRequireManagementRegardlessOfFileCeilings() {
        for (allowed in listOf(false, true)) {
            val ceiling = AutomaticAdmissionPolicy.Ceilings(
                requestedRootSelected = true, fileWritesAllowed = true,
                packageManagementAllowed = allowed)
            for (operation in listOf(SystemOperation.PACKAGE_STAGE,
                SystemOperation.PACKAGE_INSTALL, SystemOperation.PACKAGE_UNINSTALL,
                SystemOperation.PACKAGE_FORCE_STOP,
                SystemOperation.PACKAGE_SET_ENABLED,
                SystemOperation.PACKAGE_REMOVE_FOR_USER,
                SystemOperation.PACKAGE_RESTORE,
                SystemOperation.PERMISSIONS_MANAGE,
                SystemOperation.APP_OPS_MANAGE)) {
                assertEquals(operation.name, allowed,
                    AutomaticAdmissionPolicy.isWithinEnabledCeilings(operation, ceiling))
            }
        }
    }

    @Test
    fun unrelatedOperationsNeverAcquireAuthorityFromThisHostMirror() {
        val ordinary = setOf(SystemOperation.FILE_WRITE, SystemOperation.FILE_MOVE,
            SystemOperation.FILE_DELETE, SystemOperation.PACKAGE_STAGE,
            SystemOperation.PACKAGE_INSTALL, SystemOperation.PACKAGE_UNINSTALL,
            SystemOperation.PACKAGE_FORCE_STOP,
            SystemOperation.PACKAGE_SET_ENABLED,
            SystemOperation.PACKAGE_REMOVE_FOR_USER,
            SystemOperation.PACKAGE_RESTORE,
            SystemOperation.PERMISSIONS_MANAGE,
            SystemOperation.APP_OPS_MANAGE)
        val ceiling = AutomaticAdmissionPolicy.Ceilings(true, true, true)
        for (operation in SystemOperation.entries.filterNot { it in ordinary }) {
            assertFalse(operation.name,
                AutomaticAdmissionPolicy.isWithinEnabledCeilings(operation, ceiling))
        }
    }
}
