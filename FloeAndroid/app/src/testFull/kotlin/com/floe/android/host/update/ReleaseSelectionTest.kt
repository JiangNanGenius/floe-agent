// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android release discovery over GitHub release JSON: only real Android
 * releases with the exact Full ARM64 asset pair are candidates; the iOS
 * releases in the same repository are never treated as Android updates.
 */
class ReleaseSelectionTest {

    private fun asset(name: String, size: Long, url: String = "https://example.test/$name"): String =
        """{"name":"$name","size":$size,"browser_download_url":"$url"}"""

    private fun release(
        tag: String,
        assets: List<String>,
        draft: Boolean = false,
        body: String = "Release notes",
    ): String = """{"tag_name":"$tag","draft":$draft,"prerelease":true,"body":"$body","assets":[${assets.joinToString(",")}]}"""

    private fun apk(version: String, size: Long = 432_697_008L, url: String = "https://example.test/apk/$version"): String =
        asset("Floe-Android-$version-full-arm64-v8a.apk", size, url)

    private fun sums(
        size: Long = 235L,
        url: String = "https://example.test/SHA256SUMS",
    ): String = asset("SHA256SUMS", size, url)

    private fun page(vararg releases: String): String = releases.joinToString(",", "[", "]")

    private fun select(json: String, current: String = "0.1.0-alpha.13") =
        AndroidReleaseSelection.newest(
            AndroidReleaseFeed.parsePage(json),
            FloeVersion.parse(current)!!,
        )

    @Test
    fun selectsNewestAndroidReleaseAndIgnoresIosStable() {
        val selected = select(
            page(
                release("v1.7.54", listOf(asset("Floe-Agent-1.7.54.ipa", 300_000_000L))),
                release("android/v0.1.0-alpha.12", listOf(apk("0.1.0-alpha.12"), sums())),
                release("android/v0.1.0-alpha.14", listOf(apk("0.1.0-alpha.14"), sums())),
                release("android/v0.1.0-alpha.13", listOf(apk("0.1.0-alpha.13"), sums())),
            ),
        )
        assertEquals("android/v0.1.0-alpha.14", selected?.tag)
        assertEquals("0.1.0-alpha.14", selected?.version?.toString())
    }

    @Test
    fun ignoresDraftsAndNonAndroidTags() {
        val candidates = AndroidReleaseFeed.parsePage(
            page(
                release("android/v0.1.0-alpha.15", listOf(apk("0.1.0-alpha.15"), sums()), draft = true),
                release("ios/v0.1.0-alpha.15", listOf(apk("0.1.0-alpha.15"), sums())),
            ),
        )
        assertTrue(candidates.isEmpty())
    }

    @Test
    fun ignoresReleaseWithMismatchedApkFilename() {
        val candidates = AndroidReleaseFeed.parsePage(
            page(
                release(
                    "android/v0.1.0-alpha.16",
                    listOf(apk("0.1.0-alpha.15"), sums()),
                ),
            ),
        )
        assertTrue(candidates.isEmpty())
    }

    @Test
    fun ignoresReleaseWithoutChecksumsAsset() {
        val candidates = AndroidReleaseFeed.parsePage(
            page(release("android/v0.1.0-alpha.14", listOf(apk("0.1.0-alpha.14")))),
        )
        assertTrue(candidates.isEmpty())
    }

    @Test
    fun ignoresInsecureAssetUrls() {
        val candidates = AndroidReleaseFeed.parsePage(
            page(
                release(
                    "android/v0.1.0-alpha.14",
                    listOf(
                        apk("0.1.0-alpha.14", url = "http://example.test/apk"),
                        sums(),
                    ),
                ),
            ),
        )
        assertTrue(candidates.isEmpty())
    }

    @Test
    fun ignoresOversizedApkAsset() {
        val candidates = AndroidReleaseFeed.parsePage(
            page(
                release(
                    "android/v0.1.0-alpha.14",
                    listOf(
                        apk("0.1.0-alpha.14", size = AndroidReleaseFeed.MAX_APK_BYTES + 1),
                        sums(),
                    ),
                ),
            ),
        )
        assertTrue(candidates.isEmpty())
    }

    @Test
    fun returnsNullWhenCandidateIsNotNewer() {
        val json = page(release("android/v0.1.0-alpha.14", listOf(apk("0.1.0-alpha.14"), sums())))
        assertNull(select(json, current = "0.1.0-alpha.14"))
        assertNull(select(json, current = "0.1.0-alpha.20"))
    }

    @Test
    fun ignoresMalformedJsonWithoutThrowing() {
        assertTrue(AndroidReleaseFeed.parsePage("not json").isEmpty())
        assertTrue(AndroidReleaseFeed.parsePage("{}").isEmpty())
    }

    @Test
    fun boundedSummaryStripsMarkupAndTruncates() {
        val longBody = "# Heading\n\n- first item\n- second item\n" + "x".repeat(4_000)
        val summary = ReleaseSummary.bounded(longBody)
        assertTrue(summary.startsWith("Heading"))
        assertTrue(summary.contains("first item"))
        assertTrue(summary.length <= ReleaseSummary.MAX_CHARS + 1)
    }
}
