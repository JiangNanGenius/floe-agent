package com.floe.android

import androidx.test.ext.junit.runners.AndroidJUnit4
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
        assertTrue(DistributionModules.availableTools().isEmpty())
    }
}
