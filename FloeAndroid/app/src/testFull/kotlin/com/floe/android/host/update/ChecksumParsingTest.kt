// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** SHA256SUMS parsing and bounded pagination-link reading. */
class ChecksumParsingTest {

    private val apkHash = "f0dc74b92287717c04844d505a02c199fe59a12561ec8f4b56e2ed86d2d69982"

    @Test
    fun parsesGnuFormatWithTwoSpaces() {
        val text = """
            $apkHash  Floe-Android-0.1.0-alpha.13-full-arm64-v8a.apk
            0de87b608c79357b8d109014083cb906a46ecf659a56d59426eb3db703bbbd00  floe-android-corresponding-source-0.1.0-alpha.13.tar.gz
        """.trimIndent()
        val sums = Sha256Sums.parse(text)
        assertEquals(2, sums.size)
        assertEquals(apkHash, sums["Floe-Android-0.1.0-alpha.13-full-arm64-v8a.apk"])
    }

    @Test
    fun acceptsBinaryMarkerAndUppercaseHash() {
        val sums = Sha256Sums.parse("${apkHash.uppercase()} *package.apk")
        assertEquals(apkHash, sums["package.apk"])
    }

    @Test
    fun skipsCommentsShortHashesAndPathTraversal() {
        val text = """
            # comment
            deadbeef  short.apk
            $apkHash  ../escape.apk
            $apkHash  sub/dir.apk
        """.trimIndent()
        assertTrue(Sha256Sums.parse(text).isEmpty())
    }

    @Test
    fun missingFilenameIsNotResolvedByPrefix() {
        val sums = Sha256Sums.parse("$apkHash  Floe-Android-0.1.0-alpha.13-full-arm64-v8a.apk")
        assertNull(sums["Floe-Android-0.1.0-alpha.14-full-arm64-v8a.apk"])
    }

    @Test
    fun readsNextPageFromGithubLinkHeader() {
        val header =
            "<https://api.github.com/repositories/1/releases?per_page=30&page=2>; rel=\"next\", " +
                "<https://api.github.com/repositories/1/releases?per_page=30&page=3>; rel=\"last\""
        assertEquals(2, GitHubLinkHeader.nextPage(header, maxPage = 3))
        assertNull(GitHubLinkHeader.nextPage("<https://example.test/releases?page=9>; rel=\"next\"", 3))
        assertNull(GitHubLinkHeader.nextPage(null, 3))
        assertNull(GitHubLinkHeader.nextPage("<https://example.test/releases>; rel=\"prev\"", 3))
    }
}
