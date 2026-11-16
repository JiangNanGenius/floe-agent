// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AtomicSettingsUpdateTest {
    private data class Settings(val wholeScreen: Boolean, val anotherSetting: Boolean)

    @Test
    fun delayedUnrelatedUpdateCannotRestoreRevokedScreenConsent() {
        val gate = Any()
        var value = Settings(wholeScreen = true, anotherSetting = false)
        val ready = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        val worker = Thread {
            ready.countDown()
            check(proceed.await(2, TimeUnit.SECONDS))
            updateSettingsAtomically(gate, { value }, { value = it }) { it.copy(anotherSetting = true) }
        }
        worker.start()
        assertTrue(ready.await(2, TimeUnit.SECONDS))
        updateSettingsAtomically(gate, { value }, { value = it }) { it.copy(wholeScreen = false) }
        proceed.countDown()
        worker.join(2000)
        assertFalse(worker.isAlive)
        assertFalse(value.wholeScreen)
        assertTrue(value.anotherSetting)
    }
}
