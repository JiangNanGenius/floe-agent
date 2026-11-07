// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.ByteArrayInputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Exercises the production downloader, including real staging and failed reconstruction. */
class UpdateFallbackTest {
    private class Store : UpdateStore {
        override var autoCheckEnabled = true
        override var lastCheckAtMillis = 0L
        override var dismissedVersion: String? = null
        override var pendingDownloadJson: String? = null
        override var pendingInstallJson: String? = null
        override var downloadSource = UpdateDownloadSource.GITHUB
    }
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }
    private suspend fun awaitCondition(condition: () -> Boolean) {
        repeat(500) { if (condition()) return; delay(10) }
        fail("downloader did not reach the expected state")
    }

    @Test fun failedDeltaCanDownloadAndVerifyFullWithoutRetryingPatch() = runBlocking {
        exerciseFallback(recreate = false)
    }

    @Test fun interruptedDeltaRestoresFullChoiceWithoutFeedOrAutomaticNetwork() = runBlocking {
        exerciseFallback(recreate = true)
    }

    @Test fun explicitFullChoiceSkipsDeltaAndInstalledBaseAcrossVersions() = runBlocking {
        exerciseFallback(recreate = false, directFull = true)
    }

    @Test fun mirroredPatchFailureRestoresSameSourceForExplicitFullFallback() = runBlocking {
        exerciseFallback(recreate = true, source = UpdateDownloadSource.GH_PROXY)
    }

    private suspend fun exerciseFallback(recreate: Boolean, directFull: Boolean = false,
        source: UpdateDownloadSource = UpdateDownloadSource.GITHUB) {
        val dir = Files.createTempDirectory("floe-fallback-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val base = dir.resolve("installed.apk").apply { writeBytes(ByteArray(900) { 7 }) }
        val full = ByteArray(1000) { 8 }
        val patch = ByteArray(300) { 9 } // Hash-valid download, invalid FloePatch header.
        val signer = "5".repeat(64)
        val apkName = "Floe-Android-0.1.0-alpha.17-full-arm64-v8a.apk"
        val patchName = "Floe-Android-0.1.0-alpha.17-from-0.1.0-alpha.16.delta"
        val manifest = """{
          "schema":"floe.android.update.delta/1","channel":"full-arm64-v8a",
          "package":"com.floe.agent.full","releaseTag":"android/v0.1.0-alpha.17",
          "base":{"apkName":"Floe-Android-0.1.0-alpha.16-full-arm64-v8a.apk",
            "sha256":"${sha(base.readBytes())}","sizeBytes":900,"versionName":"0.1.0-alpha.16","versionCode":18},
          "target":{"apkName":"$apkName","sha256":"${sha(full)}","sizeBytes":1000,
            "versionName":"0.1.0-alpha.17","versionCode":19,"minSdk":28,
            "abis":["arm64-v8a"],"signerSha256":["$signer"]},
          "patch":{"format":"floepatch","version":1,"assetName":"$patchName",
            "sizeBytes":300,"sha256":"${sha(patch)}"}}
        """.trimIndent().toByteArray()
        val sums = "${sha(full)}  $apkName\n${sha(patch)}  $patchName\n${sha(manifest)}  update-delta-v1.json\n".toByteArray()
        val urls = java.util.Collections.synchronizedList(mutableListOf<String>())
        val patchOpens = AtomicInteger()
        val fullOpens = AtomicInteger()
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                urls += url
                val bytes = when (url.substringAfterLast('/')) {
                    "SHA256SUMS" -> sums
                    "update-delta-v1.json" -> manifest
                    patchName -> { patchOpens.incrementAndGet(); patch }
                    apkName -> { fullOpens.incrementAndGet(); full }
                    else -> error("unexpected URL")
                }
                return DownloadResponse(200, bytes.size.toLong(), null, null, null, ByteArrayInputStream(bytes))
            }
        }
        val canonical = if (source == UpdateDownloadSource.GITHUB) "https://example.test/" else
            "https://github.com/JiangNanGenius/floe-agent/releases/download/android/v0.1.0-alpha.17/"
        fun asset(name: String, size: Int) = ReleaseAsset(name, size.toLong(), canonical + name)
        val release = AndroidRelease(
            tag = "android/v0.1.0-alpha.17", version = FloeVersion.parse("0.1.0-alpha.17")!!, summary = "",
            apk = asset(apkName, full.size), checksums = asset("SHA256SUMS", sums.size),
            delta = asset("update-delta-v1.json", manifest.size),
            assets = mapOf(patchName to asset(patchName, patch.size)),
        )
        val store = Store().apply { downloadSource = source }
        val restoredScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val subject = UpdateDownloader(scope, transport, store, dir.resolve("staging"), { null },
            deltaBaseProvider = InstalledBaseProvider {
                check(!directFull) { "Full download must not require an installed delta base" }
                InstalledBaseInfo(base, base.length(), "com.floe.agent.full", "0.1.0-alpha.16", 18,
                    setOf(signer), false, 35)
            })
        try {
            if (directFull) {
                subject.startFull(release)
            } else {
                subject.start(release)
                awaitCondition { subject.state.value is AppDownloadState.DeltaFallback }
                assertEquals(1, patchOpens.get())
                assertEquals(0, fullOpens.get())
            }
            val downloader = if (directFull) subject else if (recreate) {
                scope.coroutineContext[Job]!!.cancelAndJoin()
                val restored = UpdateDownloader(restoredScope, transport, store, dir.resolve("staging"), { null })
                restored.reconcile()
                assertEquals(DeltaFallbackReason.INTERRUPTED,
                    (restored.state.value as AppDownloadState.DeltaFallback).reason)
                assertEquals(0, fullOpens.get())
                assertEquals(1, patchOpens.get())
                // Explicit full-package choice after recreation: no release object or feed.
                restored.resume()
                restored
            } else {
                subject.startFull(release)
                subject
            }
            awaitCondition { downloader.state.value is AppDownloadState.Ready }
            assertEquals(DownloadMode.FULL, (downloader.state.value as AppDownloadState.Ready).mode)
            assertEquals(if (directFull) 0 else 1, patchOpens.get())
            assertEquals(1, fullOpens.get())
            assertArrayEquals(full, downloader.readyFile()!!.readBytes())
            assertEquals(sha(ByteArray(900) { 7 }), sha(base.readBytes()))
            assertEquals(source, downloader.sourceState.value.selected)
            if (source != UpdateDownloadSource.GITHUB) {
                assertTrue(urls.contains(canonical + "SHA256SUMS"))
                assertTrue(urls.contains(canonical + "update-delta-v1.json"))
                assertTrue(urls.contains(source.assetUrl(canonical + patchName)))
                assertTrue(urls.contains(source.assetUrl(canonical + apkName)))
                assertFalse(urls.contains(source.assetUrl(canonical + apkName).substringBefore(canonical) + canonical + "SHA256SUMS"))
            }
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); restoredScope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun checksumPreparationIsVisibleAndDoesNotAdmitDuplicateWriter() = runBlocking {
        val dir = Files.createTempDirectory("floe-prepare-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val entered = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val checks = AtomicInteger()
        val full = "verified full apk".toByteArray()
        val name = "Floe-Android-0.1.0-alpha.17-full-arm64-v8a.apk"
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                val bytes = if (url.endsWith("SHA256SUMS")) {
                    checks.incrementAndGet(); entered.countDown()
                    check(unblock.await(15, TimeUnit.SECONDS))
                    "${sha(full)}  $name\n".toByteArray()
                } else full
                return DownloadResponse(200, bytes.size.toLong(), null, null, null, ByteArrayInputStream(bytes))
            }
        }
        val release = AndroidRelease("android/v0.1.0-alpha.17", FloeVersion.parse("0.1.0-alpha.17")!!, "",
            ReleaseAsset(name, full.size.toLong(), "https://example.test/$name"),
            ReleaseAsset("SHA256SUMS", 128, "https://example.test/SHA256SUMS"))
        val subject = UpdateDownloader(scope, transport, Store(), dir, { null })
        try {
            subject.startFull(release)
            assertTrue(entered.await(15, TimeUnit.SECONDS))
            assertTrue(subject.state.value is AppDownloadState.InProgress)
            subject.start(release)
            delay(100)
            assertEquals(1, checks.get())
            unblock.countDown()
            awaitCondition { subject.state.value is AppDownloadState.Ready }
            assertEquals(1, checks.get())
        } finally { unblock.countDown(); scope.cancel(); dir.deleteRecursively() }
    }
}
