// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.contracts.SensitiveUiLabelBaseline
import com.floe.android.contracts.SensitiveUiLabelIdentity
import com.floe.android.contracts.SensitiveUiLabelKey
import com.floe.android.contracts.SensitiveUiLabelFingerprint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class UiSensitiveBaselineTest {
    private val key = SensitiveUiLabelKey.fromBytes(ByteArray(32) { it.toByte() })!!
    private val parent = SensitiveUiLabelIdentity("test.app", 1, 0, listOf(0), "Button", "button")
    private val child = SensitiveUiLabelIdentity("test.app", 1, 0, listOf(0, 1), "TextView", "label")

    @Test fun snapshotRetainsExactButtonAndDirectParentIdentity() {
        val digest = SensitiveUiLabelFingerprint.hmac(key, "Sign in", null)!!
        val entry = SensitiveUiLabelBaseline(child, parent, digest)
        val restored = UiSensitiveBaseline.fromSnapshot(listOf(entry))
        assertEquals(1, restored.size)
        val value = restored.values.single()
        assertEquals("button", value.safeParent?.viewId)
        assertEquals(digest, value.fingerprint)
        assertFalse(value.fingerprint == SensitiveUiLabelFingerprint.hmac(key, "changed", null))
        assertNull(restored.keys.firstOrNull { it.viewId == "unrelated" })
    }

    @Test fun malformedParentOrNonDirectChildIsNotAValidSnapshotEntry() {
        val digest = SensitiveUiLabelFingerprint.hmac(key, "Sign in", null)!!
        assertFalse(SensitiveUiLabelBaseline(child, parent.copy(path = listOf(2)), digest).isWellFormed())
        assertFalse(SensitiveUiLabelBaseline(child, parent.copy(packageName = "other"), digest).isWellFormed())
    }
}
