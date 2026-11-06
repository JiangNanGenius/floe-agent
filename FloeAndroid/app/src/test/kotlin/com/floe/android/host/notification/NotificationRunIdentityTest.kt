// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notification

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NotificationRunIdentityTest {
    private val run = "2a9bb479-f614-473c-b8e4-008e2dfe8222"

    @Test fun nativeRunSpellingSurvivesNotificationRoundtrip() {
        assertEquals(run.uppercase(), NotificationRunIdentity.resolve(run, run.uppercase()))
        assertEquals(run, NotificationRunIdentity.resolve(run.uppercase(), run))
    }

    @Test fun anotherRunOrIncompleteIdentityCannotCancel() {
        assertNull(NotificationRunIdentity.resolve(run, "6c3a1e44-3b8d-4ad1-9a1b-7a2f0d5e8c11"))
        assertNull(NotificationRunIdentity.resolve("1-1-1-1-1", "1-1-1-1-1"))
        assertNull(NotificationRunIdentity.resolve(run, run + " "))
        assertNull(NotificationRunIdentity.resolve(run, "not-a-uuid"))
    }
}
