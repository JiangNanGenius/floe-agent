// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure regression for the App-local staged-APK manifest: stable staged ids,
 * tolerant parsing that drops malformed entries, and the bounded shape the
 * settings surface and the install tool consume. A corrupted manifest can
 * never mint an executable reference.
 *
 * Authored only; Main runs it in the batched JVM set. No compile/run claim.
 */
class ApkStagingManifestTest {

    @Test
    fun stagedIdsDeriveFromTheContentDigest() {
        assertEquals(
            "stage:abcdef0123456789",
            ApkStagingManifest.stagedIdFor("abcdef0123456789ff"),
        )
        assertTrue(ApkStagingManifest.stagedIdValid("stage:abcdef0123456789"))
        assertFalse(ApkStagingManifest.stagedIdValid("stage:"))
        assertFalse(ApkStagingManifest.stagedIdValid("../path"))
        assertFalse(ApkStagingManifest.stagedIdValid("stage:bad id!"))
    }

    @Test
    fun manifestRoundTripsEntries() {
        val entries = listOf(
            ApkStagingManifest.Entry(
                stagedId = "stage:aaaa1111bbbb2222",
                fileName = "sample.apk",
                sizeBytes = 1234,
                sha256 = "aaaa1111bbbb2222".repeat(4),
                packageName = "com.example.app",
                addedAtMillis = 42,
            ),
            ApkStagingManifest.Entry(
                stagedId = "stage:cccc3333dddd4444",
                fileName = "other.apk",
                sizeBytes = 99,
                sha256 = "cccc3333dddd4444".repeat(4),
                packageName = null,
                addedAtMillis = 0,
            ),
        )
        assertEquals(entries, ApkStagingManifest.fromJson(ApkStagingManifest.toJson(entries)))
    }

    @Test
    fun malformedEntriesAreDroppedNotFatal() {
        val validDigest = "aaaa1111bbbb2222".repeat(4)
        val text = """{"version":1,"entries":[
            {"stagedId":"stage:aaaa1111bbbb2222","fileName":"ok.apk","sizeBytes":5,"sha256":"$validDigest"},
            {"stagedId":"","fileName":"no-sha.apk","sizeBytes":5,"sha256":""},
            {"stagedId":"stage:x","fileName":"","sizeBytes":5,"sha256":"$validDigest"},
            {"stagedId":"stage:x","fileName":"neg.apk","sizeBytes":-1,"sha256":"$validDigest"},
            null
        ]}"""
        val parsed = ApkStagingManifest.fromJson(text)
        assertEquals(1, parsed.size)
        assertEquals("ok.apk", parsed[0].fileName)
        assertTrue(ApkStagingManifest.fromJson("not json").isEmpty())
        assertTrue(ApkStagingManifest.fromJson("""{"version":2,"entries":[]}""").isEmpty())
        assertTrue(ApkStagingManifest.fromJson(null).isEmpty())
    }

    @Test
    fun manifestIsCappedAtTheBatchBound() {
        val entries = (0 until ApkStagingManifest.MAX_ENTRIES + 4).map {
            ApkStagingManifest.Entry(
                stagedId = "stage:%016x".format(it),
                fileName = "app$it.apk",
                sizeBytes = it.toLong(),
                sha256 = ("%016x".format(it)).repeat(4),
                packageName = null,
                addedAtMillis = 0,
            )
        }
        val roundTrip = ApkStagingManifest.fromJson(ApkStagingManifest.toJson(entries))
        assertEquals(ApkStagingManifest.MAX_ENTRIES, roundTrip.size)
        // Encoding side is capped too.
        val encoded = ApkStagingManifest.toJson(entries)
        assertEquals(ApkStagingManifest.MAX_ENTRIES, ApkStagingManifest.fromJson(encoded).size)
    }
}
