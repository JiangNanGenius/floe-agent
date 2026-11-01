package com.floe.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.floe.android.contracts.Availability
import com.floe.android.contracts.Distribution
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DistributionInstrumentedTest {
    @Test fun playBinaryCannotLoadFullModules() {
        for (name in listOf("com.floe.android.phonecontrol.PhoneControlModule", "com.floe.android.rootsystem.RootSystemModule")) {
            if (DistributionModules.distribution == Distribution.PLAY) {
                assertThrows(ClassNotFoundException::class.java) { Class.forName(name) }
            } else {
                assertNotNull(Class.forName(name))
            }
        }
        if (DistributionModules.distribution == Distribution.PLAY) {
            // PLAY physically excludes the Full modules and declares no
            // capability source, so it must advertise nothing.
            assertTrue(DistributionModules.sources.isEmpty())
            assertTrue(DistributionModules.availableTools().isEmpty())
        } else {
            // FULL is wired to the REAL backends. Their availability depends
            // on the actual Accessibility/ADB/Root state of this device, so the
            // assertion is the honest boundary (declared capability ids and
            // real Availability states), never "everything unavailable" and
            // never a forced test-environment disable.
            val capabilities = DistributionModules.sources.flatMap { it.capabilities() }
            assertFalse(capabilities.isEmpty())
            assertEquals(
                setOf(
                    "device.control",
                    "device.control.screenshot",
                    "system.adb",
                    "system.root",
                    "system.files",
                    "system.packages",
                    "system.diagnostics",
                ),
                capabilities.map { it.id }.toSet(),
            )
            assertTrue(capabilities.all { it.availability in Availability.values() })
        }
    }
}
