// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PhoneControlGuardedLabelTest {
    private val key = com.floe.android.contracts.SensitiveUiLabelKey.fromBytes(ByteArray(32) { it.toByte() })!!
    private val expected = com.floe.android.contracts.SensitiveUiLabelFingerprint.hmac(key, "Sign in", null)!!

    @Test fun inputsAndUnknownFlagsNeverReadText() {
        fun read(editable: Boolean?, password: Boolean?, known: Boolean, setText: Boolean, identity: String?) =
            PhoneControlGuardedLabel.read(true, false, editable, password, known, setText, true, key = key, expectedDigest = identity,
                text = { error("must not read text") }, description = { error("must not read description") })
        assertNull(read(true, false, true, false, expected))
        assertNull(read(null, false, true, false, expected))
        assertNull(read(false, null, true, false, expected))
        assertNull(read(false, false, false, false, expected))
        assertNull(read(false, false, true, true, expected))
        assertNull(read(false, false, true, false, null))
        assertNull(PhoneControlGuardedLabel.read(true, false, false, false, true, false, true,
            safeAncestry = false, key = key, expectedDigest = expected,
            text = { error("must not read text") }, description = { error("must not read description") }))
    }
    @Test fun unchangedKnownButtonRemainsVisibleButChangedContentIsHidden() {
        fun read(text: String) = PhoneControlGuardedLabel.read(true, false, false, false, true, false, true, key = key, expectedDigest = expected,
            text = { text }, description = { null })
        assertEquals("Sign in", read("Sign in")?.text)
        assertNull(read("other content"))
        val differentKey = com.floe.android.contracts.SensitiveUiLabelKey.fromBytes(ByteArray(32) { 7 })!!
        assertNull(PhoneControlGuardedLabel.read(true, false, false, false, true, false, true,
            key = differentKey, expectedDigest = expected, text = { "Sign in" }, description = { null }))
        assertNull(PhoneControlGuardedLabel.read(true, true, false, false, true, false, true,
            key = key, expectedDigest = expected,
            text = { error("sensitive text getter") }, description = { error("sensitive description getter") }))
    }
    @Test fun provenButtonChildIsIncludedButEditableAndUnrelatedTextAreNot() {
        val nodes = listOf(
            testRawNode(listOf(0), clickable = true).copy(semanticEligible = true),
            testRawNode(listOf(0, 0), text = "Sign in").copy(semanticEligible = true),
            testRawNode(listOf(0, 1), text = "secret", editable = true).copy(semanticEligible = true),
            testRawNode(listOf(1), text = "unrelated").copy(semanticEligible = true),
        )
        val records = PhoneControlTreeShaper.shape(nodes, PhoneControlObserveRequest(), false, false, false).records
        val all = records.values
        org.junit.Assert.assertTrue(PhoneControlGuardedLabel.canBaseline(records.getValue("n1"), all))
        org.junit.Assert.assertFalse(PhoneControlGuardedLabel.canBaseline(records.getValue("n2"), all))
        org.junit.Assert.assertFalse(PhoneControlGuardedLabel.canBaseline(records.getValue("n3"), all))
    }

}
