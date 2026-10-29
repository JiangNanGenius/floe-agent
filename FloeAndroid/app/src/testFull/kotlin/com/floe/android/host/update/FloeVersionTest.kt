// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure semantic-version and Android-tag rules used by release discovery. */
class FloeVersionTest {

    @Test
    fun parsesAndroidAlphaVersion() {
        val version = FloeVersion.parse("0.1.0-alpha.13")
        assertEquals(FloeVersion(0, 1, 0, listOf("alpha", "13")), version)
        assertEquals("0.1.0-alpha.13", version!!.toString())
    }

    @Test
    fun comparesPrereleaseNumerically() {
        val nine = FloeVersion.parse("0.1.0-alpha.9")!!
        val ten = FloeVersion.parse("0.1.0-alpha.10")!!
        val thirteen = FloeVersion.parse("0.1.0-alpha.13")!!
        val fourteen = FloeVersion.parse("0.1.0-alpha.14")!!
        assertTrue(nine < ten)
        assertTrue(ten < thirteen)
        assertTrue(thirteen < fourteen)
    }

    @Test
    fun releaseOutranksPrereleaseOfSameBase() {
        val alpha = FloeVersion.parse("0.1.0-alpha.14")!!
        val stable = FloeVersion.parse("0.1.0")!!
        assertTrue(alpha < stable)
    }

    @Test
    fun minorBumpOutranksPrereleaseOfPreviousMinor() {
        val alphaOne = FloeVersion.parse("0.1.1-alpha.1")!!
        val alphaFourteen = FloeVersion.parse("0.1.0-alpha.14")!!
        assertTrue(alphaFourteen < alphaOne)
    }

    @Test
    fun ignoresBuildMetadataForOrdering() {
        val withMetadata = FloeVersion.parse("0.1.0-alpha.14+linux")!!
        val plain = FloeVersion.parse("0.1.0-alpha.14")!!
        assertEquals(plain, withMetadata)
    }

    @Test
    fun extractsVersionOnlyFromAndroidTags() {
        assertEquals(
            FloeVersion.parse("0.1.0-alpha.14"),
            FloeVersion.fromAndroidTag("android/v0.1.0-alpha.14"),
        )
        assertNull(FloeVersion.fromAndroidTag("v1.7.54"))
        assertNull(FloeVersion.fromAndroidTag("android/vnot-a-version"))
        assertNull(FloeVersion.fromAndroidTag("0.1.0-alpha.14"))
    }

    @Test
    fun rejectsMalformedVersions() {
        assertNull(FloeVersion.parse("1.2"))
        assertNull(FloeVersion.parse("1.2.3.4"))
        assertNull(FloeVersion.parse(""))
        assertNull(FloeVersion.parse("1.2.3-"))
    }
}
