// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Drives the production downloader, staged bytes and cancellation, without network/provider calls. */
class UpdateMirrorDownloadTest {
    private class Store : UpdateStore {
        override var autoCheckEnabled = true
        override var lastCheckAtMillis = 0L
        override var dismissedVersion: String? = null
        override var pendingDownloadJson: String? = null
        override var pendingInstallJson: String? = null
        override var downloadSource = UpdateDownloadSource.GITHUB
    }

    private val name = "Floe-Android-0.1.0-alpha.54-full-arm64-v8a.apk"
    private val base = "https://github.com/JiangNanGenius/floe-agent/releases/download/android/v0.1.0-alpha.54/"
    private val bytes = ByteArray(700_000) { (it * 31).toByte() }
    private fun sha(data: ByteArray) = MessageDigest.getInstance("SHA-256")
        .digest(data).joinToString("") { "%02x".format(it) }
    private fun release() = AndroidRelease("android/v0.1.0-alpha.54", FloeVersion.parse("0.1.0-alpha.54")!!,
        "notes", ReleaseAsset(name, bytes.size.toLong(), base + name),
        ReleaseAsset("SHA256SUMS", 200, base + "SHA256SUMS"))
    private fun response(data: ByteArray, code: Int = 200, offset: Long? = null,
        total: Long? = null, etag: String = "stable") =
        DownloadResponse(code, data.size.toLong(), offset, total, etag, ByteArrayInputStream(data))
    private fun sums() = response("${sha(bytes)}  $name\n".toByteArray())

    private suspend fun await(description: String, condition: () -> Boolean) {
        repeat(500) { if (condition()) return; delay(10) }
        throw AssertionError("timeout: $description")
    }

    @Test fun switchingClosesBlockedReadJoinsWriterAndResumesExactPrefix() = runBlocking {
        val dir = Files.createTempDirectory("floe-mirror-switch-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = Store()
        val blocked = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val prefix = 256 * 1024
        val requests = Collections.synchronizedList(mutableListOf<Pair<String, Long?>>())
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                requests += url to rangeFrom
                if (url == base + "SHA256SUMS") return sums()
                if (url == base + name) {
                    return DownloadResponse(200, bytes.size.toLong(), null, null, "stable", object : InputStream() {
                        private var position = 0
                        override fun read(): Int = error("bulk reads only")
                        override fun read(buffer: ByteArray, off: Int, len: Int): Int {
                            if (position < prefix) {
                                val size = minOf(prefix - position, len)
                                System.arraycopy(bytes, position, buffer, off, size); position += size
                                return size
                            }
                            blocked.countDown()
                            check(closed.await(5, TimeUnit.SECONDS)) { "old connection was not closed" }
                            // A late successful read must be fenced before touching staging.
                            buffer[off] = 99
                            return 1
                        }
                        override fun close() { closed.countDown() }
                    })
                }
                assertTrue(url.startsWith("https://ghfast.top/"))
                assertEquals(prefix.toLong(), rangeFrom)
                assertEquals("stable", ifRangeEtag)
                assertEquals(0L, closed.count)
                return response(bytes.copyOfRange(prefix, bytes.size), 206, rangeFrom, bytes.size.toLong())
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { null })
        try {
            subject.startFull(release())
            assertTrue(blocked.await(5, TimeUnit.SECONDS))
            subject.changeSource(UpdateDownloadSource.GHFAST)
            await("verified mirror result") { subject.state.value is AppDownloadState.Ready && !subject.sourceState.value.switching }
            assertArrayEquals(bytes, subject.readyFile()!!.readBytes())
            assertEquals(UpdateDownloadSource.GHFAST, store.downloadSource)
            assertFalse(subject.sourceState.value.restarted)
            assertEquals(3, requests.size) // Canonical checksums, direct prefix, mirrored suffix.
            assertTrue(DownloadMeta.fromJson(store.pendingDownloadJson)!!.completed)
        } finally { closed.countDown(); scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun switchDuringBlockedHeadersCancelsRequestBeforeOpeningNewSource() = runBlocking {
        val dir = Files.createTempDirectory("floe-mirror-headers-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = Store()
        val entered = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                return if (url == base + "SHA256SUMS") sums() else {
                    assertTrue(url.startsWith("https://gh-proxy.com/"))
                    assertEquals(0L, cancelled.count)
                    response(bytes)
                }
            }
            override fun newCall(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadCall {
                if (url != base + name) return super.newCall(url, rangeFrom, ifRangeEtag)
                return object : DownloadCall {
                    override fun execute(): DownloadResponse {
                        entered.countDown()
                        check(cancelled.await(5, TimeUnit.SECONDS)) { "header wait did not cancel" }
                        return response("stale response".toByteArray())
                    }
                    override fun cancel() { cancelled.countDown() }
                }
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { null })
        try {
            subject.startFull(release()); assertTrue(entered.await(5, TimeUnit.SECONDS))
            subject.changeSource(UpdateDownloadSource.GH_PROXY)
            await("headers cancelled and new source completed") { subject.state.value is AppDownloadState.Ready }
            assertArrayEquals(bytes, subject.readyFile()!!.readBytes())
        } finally { cancelled.countDown(); scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun ignoredRangeRestartsWithoutAppendingFullBody() = exerciseRestart(200, "stable", null, null)
    @Test fun changedEtagRestartsEvenWithMatchingRange() = exerciseRestart(206, "changed", 100, 700_000)
    @Test fun missingTotalCannotProveResume() = exerciseRestart(206, "stable", 100, null)

    private fun exerciseRestart(code: Int, etag: String, start: Long?, total: Long?) = runBlocking {
        val dir = Files.createTempDirectory("floe-mirror-restart-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val meta = DownloadMeta("android/v0.1.0-alpha.54", "0.1.0-alpha.54", name,
            base + name, base + "SHA256SUMS", sha(bytes), bytes.size.toLong(), 100, "stable", false)
        val store = Store().apply { pendingDownloadJson = meta.toJson() }
        dir.resolve("android_v0.1.0-alpha.54.part").writeBytes(bytes.copyOf(100))
        val requested = mutableListOf<Long?>()
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                assertEquals("https://gh-proxy.com/" + base + name, url)
                requested += rangeFrom
                return if (rangeFrom != null) response(bytes, code, start, total, etag) else response(bytes)
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { null })
        try {
            subject.reconcile(); assertTrue(subject.state.value is AppDownloadState.Paused)
            subject.changeSource(UpdateDownloadSource.GH_PROXY)
            await("source persisted") { store.downloadSource == UpdateDownloadSource.GH_PROXY }
            assertTrue(subject.state.value is AppDownloadState.Paused)
            assertTrue(requested.isEmpty()) // Source choice alone never retries failed/paused work.
            subject.resume()
            await("safe full restart") { subject.state.value is AppDownloadState.Ready }
            assertEquals(listOf(100L, null), requested)
            assertTrue(subject.sourceState.value.restarted)
            assertArrayEquals(bytes, subject.readyFile()!!.readBytes())
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun corruptMirrorBytesNeverBecomeReadyOrReachIdentityValidation() = runBlocking {
        val dir = Files.createTempDirectory("floe-mirror-corrupt-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = Store().apply { downloadSource = UpdateDownloadSource.GHFAST }
        val validated = AtomicBoolean(false)
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?) =
                if (url == base + "SHA256SUMS") sums() else {
                    assertEquals("https://ghfast.top/" + base + name, url)
                    response(bytes.copyOf().also { it[0] = (it[0] + 1).toByte() })
                }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { validated.set(true); null })
        try {
            subject.startFull(release())
            await("hash rejection") { subject.state.value is AppDownloadState.Failed }
            assertEquals(DownloadFailure.CHECKSUM_MISMATCH, (subject.state.value as AppDownloadState.Failed).kind)
            assertFalse(validated.get()); assertNull(subject.readyFile()); assertNull(store.pendingDownloadJson)
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun mirrorCannotProxyForeignOrMetadataUrlsAndOldPreferenceDefaultsDirect() {
        assertEquals(UpdateDownloadSource.GITHUB, UpdateDownloadSource.fromId(null))
        assertEquals(UpdateDownloadSource.GITHUB, UpdateDownloadSource.fromId("removed-provider"))
        for (bad in listOf("http://github.com/a.apk", base + "SHA256SUMS", base + "update-delta-v1.json",
            base + name + "?token=value", base + name + "#x", base.replace("github.com", "github.com.evil.test") + name,
            base.replace("github.com", "name@github.com") + name, base.replace("floe-agent", "other") + name,
            base + "../" + name, base + "%2F" + name)) {
            try { UpdateDownloadSource.GHFAST.assetUrl(bad); fail("accepted $bad") } catch (_: IOException) { }
        }
        val call = HttpsDownloadTransport().newCall(base + name, null, null)
        call.cancel()
        try { call.execute(); fail("cancelled request connected") } catch (_: IOException) { }
    }
}
