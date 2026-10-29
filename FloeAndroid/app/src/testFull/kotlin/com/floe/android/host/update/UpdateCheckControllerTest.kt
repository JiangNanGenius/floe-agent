// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Update-check lifecycle: enabled/cooldown gating, manual bypass, single
 * flight, failure typing and "Later" de-duplication. Scripted feed doubles
 * only — no network, no device, no Android framework.
 */
class UpdateCheckControllerTest {

    private class FakeStore : UpdateStore {
        override var autoCheckEnabled: Boolean = true
        override var lastCheckAtMillis: Long = 0L
        override var dismissedVersion: String? = null
        override var pendingDownloadJson: String? = null
        override var pendingInstallJson: String? = null
    }

    private class FakeFeed(
        private val pages: List<String>,
        private val failure: FeedFailure? = null,
    ) : ReleaseFeed {
        var calls = 0
        override fun fetchPage(page: Int): FeedPage {
            calls += 1
            failure?.let { throw it }
            val body = pages[page - 1]
            return FeedPage(body, if (page < pages.size) page + 1 else null)
        }
    }

    private var now = 1_000_000L

    private fun asset(name: String, size: Long = 1_000L): String =
        """{"name":"$name","size":$size,"browser_download_url":"https://example.test/$name"}"""

    private fun release(version: String, tagPrefix: String = "android/v"): String =
        """{"tag_name":"$tagPrefix$version","draft":false,"prerelease":true,"body":"notes","assets":[${
            asset("Floe-Android-$version-full-arm64-v8a.apk", 432_697_008L)
        },${asset("SHA256SUMS", 235L)}]}"""

    private fun page(vararg releases: String): String = releases.joinToString(",", "[", "]")

    private fun controller(
        feed: ReleaseFeed,
        store: UpdateStore = FakeStore(),
        current: String = "0.1.0-alpha.13",
    ) = UpdateCheckController(
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        feed = feed,
        store = store,
        currentVersion = FloeVersion.parse(current),
        nowMillis = { now },
        ioDispatcher = Dispatchers.Unconfined,
    )

    @Test
    fun disabledAutomaticCheckDoesNothing() {
        val store = FakeStore().apply { autoCheckEnabled = false }
        val feed = FakeFeed(listOf(page(release("0.1.0-alpha.14"))))
        val subject = controller(feed, store)
        subject.maybeAutoCheck()
        assertEquals(0, feed.calls)
        assertEquals(AppCheckState.Idle, subject.state.value)
    }

    @Test
    fun cooldownSuppressesAutomaticCheck() {
        val store = FakeStore().apply { lastCheckAtMillis = now - 60_000L }
        val feed = FakeFeed(listOf(page(release("0.1.0-alpha.14"))))
        val subject = controller(feed, store)
        subject.maybeAutoCheck()
        assertEquals(0, feed.calls)

        store.lastCheckAtMillis = now - UpdateConfig.AUTO_CHECK_INTERVAL_MS - 1L
        subject.maybeAutoCheck()
        assertEquals(1, feed.calls)
        assertTrue(subject.state.value is AppCheckState.UpdateAvailable)
        assertEquals(now, store.lastCheckAtMillis)
    }

    @Test
    fun manualCheckBypassesCooldown() {
        val store = FakeStore().apply { lastCheckAtMillis = now }
        val feed = FakeFeed(listOf(page(release("0.1.0-alpha.14"))))
        val subject = controller(feed, store)
        subject.manualCheck()
        assertEquals(1, feed.calls)
        val state = subject.state.value as AppCheckState.UpdateAvailable
        assertTrue(state.manual)
    }

    @Test
    fun rateLimitIsTypedAndDoesNotThrow() {
        val subject = controller(FakeFeed(emptyList(), FeedFailure.RateLimited()))
        subject.manualCheck()
        assertEquals(
            AppCheckState.Unavailable(UnavailableKind.RATE_LIMITED),
            subject.state.value,
        )
    }

    @Test
    fun transportFailureIsTypedNetwork() {
        val subject = controller(FakeFeed(emptyList(), FeedFailure.Transport("io")))
        subject.manualCheck()
        assertEquals(
            AppCheckState.Unavailable(UnavailableKind.NETWORK),
            subject.state.value,
        )
    }

    @Test
    fun paginationMergesEveryPage() {
        val feed = FakeFeed(
            listOf(
                page(release("0.1.0-alpha.13")),
                page(release("0.1.0-alpha.14")),
            ),
        )
        val subject = controller(feed)
        subject.manualCheck()
        assertEquals(2, feed.calls)
        assertEquals(
            "0.1.0-alpha.14",
            (subject.state.value as AppCheckState.UpdateAvailable).release.version.toString(),
        )
    }

    @Test
    fun equalVersionReportsUpToDate() {
        val store = FakeStore()
        val subject = controller(
            FakeFeed(listOf(page(release("0.1.0-alpha.14")))),
            store,
            current = "0.1.0-alpha.14",
        )
        subject.manualCheck()
        assertEquals(AppCheckState.UpToDate(now), subject.state.value)
        assertEquals(now, store.lastCheckAtMillis)
    }

    @Test
    fun onlyNonAndroidReleasesReportsTypedState() {
        val page = page(release("1.7.54", "v"))
        val subject = controller(FakeFeed(listOf(page)))
        subject.manualCheck()
        assertEquals(
            AppCheckState.Unavailable(UnavailableKind.NO_ANDROID_RELEASE),
            subject.state.value,
        )
    }

    @Test
    fun laterSuppressesSameReleaseButManualCheckRepresents() {
        val store = FakeStore()
        val subject = controller(FakeFeed(listOf(page(release("0.1.0-alpha.14")))), store)
        subject.manualCheck()
        assertTrue(subject.shouldPresentDialog())
        val release = (subject.state.value as AppCheckState.UpdateAvailable).release
        subject.markDialogDismissed(release)
        assertFalse(subject.shouldPresentDialog())
        assertEquals("0.1.0-alpha.14", store.dismissedVersion)

        subject.manualCheck()
        assertTrue(subject.shouldPresentDialog())
    }

    @Test
    fun singleFlightDropsConcurrentCheck() = runBlocking {
        val gate = CountDownLatch(1)
        val entered = CountDownLatch(1)
        val blockingFeed = object : ReleaseFeed {
            @Volatile
            var calls = 0
            override fun fetchPage(page: Int): FeedPage {
                calls += 1
                entered.countDown()
                gate.await(5, TimeUnit.SECONDS)
                return FeedPage(
                    """[${release("0.1.0-alpha.14")}]""",
                    null,
                )
            }
        }
        val subject = UpdateCheckController(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
            feed = blockingFeed,
            store = FakeStore(),
            currentVersion = FloeVersion.parse("0.1.0-alpha.13"),
            nowMillis = { now },
            ioDispatcher = Dispatchers.IO,
        )
        subject.manualCheck()
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        subject.manualCheck()
        gate.countDown()
        withTimeout(5_000) {
            subject.state.first { it is AppCheckState.UpdateAvailable }
        }
        assertEquals(1, blockingFeed.calls)
    }
}
