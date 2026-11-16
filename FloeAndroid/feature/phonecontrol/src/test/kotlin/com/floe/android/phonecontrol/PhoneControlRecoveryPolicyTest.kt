// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneControlRecoveryPolicyTest {
    @Test fun onlyNonSensitivePreDispatchExpiryIsEligible() {
        val observation = testObservation()
        assertTrue(PhoneControlRecoveryPolicy.eligible(
            PhoneControlDenial.OBSERVATION_EXPIRED, PhoneControlAction.Click("n0"), observation, false, false,
        ))
        assertFalse(PhoneControlRecoveryPolicy.eligible(
            PhoneControlDenial.STALE_OBSERVATION, PhoneControlAction.Click("n0"), observation, false, false,
        ))
        assertFalse(PhoneControlRecoveryPolicy.eligible(
            PhoneControlDenial.OBSERVATION_EXPIRED,
            PhoneControlAction.SetText("n0", "synthetic", sensitive = true), observation, false, false,
        ))
        assertFalse(PhoneControlRecoveryPolicy.eligible(
            PhoneControlDenial.OBSERVATION_EXPIRED, PhoneControlAction.Click("n0"), observation, true, false,
        ))
    }

    @Test fun freshObservationMustKeepOriginalWindowAndFence() {
        val old = testObservation()
        assertTrue(PhoneControlRecoveryPolicy.samePage(old, old.copy(observationId = "fresh")))
        assertFalse(PhoneControlRecoveryPolicy.samePage(old, old.copy(windowId = old.windowId + 1)))
        assertFalse(PhoneControlRecoveryPolicy.samePage(old, old.copy(packageName = "other")))
        assertFalse(PhoneControlRecoveryPolicy.samePage(old, old.copy(pageGeneration = old.pageGeneration + 1)))
        assertFalse(PhoneControlRecoveryPolicy.samePage(old, old.copy(fenceGeneration = old.fenceGeneration + 1)))
        assertFalse(PhoneControlRecoveryPolicy.samePage(old, old.copy(owner = testOwner(run = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))))
        assertFalse(PhoneControlRecoveryPolicy.samePage(old, old.copy(sensitiveWindow = true)))
    }
}
