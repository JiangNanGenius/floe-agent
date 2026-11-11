// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.rootsystem.SystemOperation
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-only regression for the durable-gate admission of the closed
 * settings write inside ordinary automatic mode.
 */
class AutomaticAdmissionPolicySettingsTest {

    private fun ceilings(
        management: Boolean = true,
        master: Boolean = true,
        tools: Set<String> = setOf(DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE),
    ) = AutomaticAdmissionPolicy.Ceilings(
        packageManagementAllowed = management,
        advancedSystemManagementAllowed = master,
        advancedAllowedTools = tools,
    )

    @Test
    fun settingsWriteNeedsEveryLayerOfTheDurableGate() {
        assertTrue(
            AutomaticAdmissionPolicy.isWithinEnabledCeilings(
                SystemOperation.SETTINGS_WRITE, ceilings(),
            ),
        )
        assertFalse(
            AutomaticAdmissionPolicy.isWithinEnabledCeilings(
                SystemOperation.SETTINGS_WRITE, ceilings(master = false),
            ),
        )
        assertFalse(
            AutomaticAdmissionPolicy.isWithinEnabledCeilings(
                SystemOperation.SETTINGS_WRITE, ceilings(management = false),
            ),
        )
        assertFalse(
            AutomaticAdmissionPolicy.isWithinEnabledCeilings(
                SystemOperation.SETTINGS_WRITE,
                ceilings(tools = setOf("system.packages.setEnabled")),
            ),
        )
        assertFalse(
            AutomaticAdmissionPolicy.isWithinEnabledCeilings(
                SystemOperation.SETTINGS_WRITE, ceilings(tools = emptySet()),
            ),
        )
    }

    @Test
    fun settingsWriteDoesNotWidenOtherOperations() {
        // Existing ceilings are unchanged by the settings addition.
        assertTrue(
            AutomaticAdmissionPolicy.isWithinEnabledCeilings(
                SystemOperation.PACKAGE_INSTALL,
                AutomaticAdmissionPolicy.Ceilings(packageManagementAllowed = true),
            ),
        )
        assertFalse(
            AutomaticAdmissionPolicy.isWithinEnabledCeilings(
                SystemOperation.PACKAGE_INSTALL,
                AutomaticAdmissionPolicy.Ceilings(packageManagementAllowed = false),
            ),
        )
        assertFalse(
            AutomaticAdmissionPolicy.isWithinEnabledCeilings(
                SystemOperation.FILE_WRITE,
                AutomaticAdmissionPolicy.Ceilings(
                    requestedRootSelected = true,
                    fileWritesAllowed = false,
                ),
            ),
        )
        // The read is never an automatic-mutation decision.
        assertFalse(
            AutomaticAdmissionPolicy.isWithinEnabledCeilings(
                SystemOperation.SETTINGS_READ, ceilings(),
            ),
        )
    }
}
