// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Real-controller writer-ownership regression (Main critical review,
 * 2026-10-29). Drives the ACTUAL [UpdateDownloader] with a scripted transport
 * whose first APK read blocks: discard() must cancel AND join that writer
 * (stream closed) before it deletes any staged byte, and the next writer must
 * own the staging/state instead of being cleared by the old writer's finally.
 *
 * No Android framework and no planning-mirror helper: the production engine,
 * its real coroutines, its real file staging and its real state flow.
 */
class UpdateDownloaderOwnershipTest {

    private class FakeStore : UpdateStore {
        override var autoCheckEnabled: Boolean = true
        override var lastCheckAtMillis: Long = 0L
        override var dismissedVersion: String? = null
        override var pendingDownloadJson: String? = null
        override var pendingInstallJson: String? = null
    }

    /** Blocks the FIRST APK read until [release]; later opens are immediate. */
    private class ScriptedTransport(
        private val bytes: ByteArray,
        private val fileName: String,
        private val blockFirstApkRead: Boolean,
    ) : DownloadTransport {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        private var apkOpens = 0

        override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
            if (url.endsWith(AndroidReleaseFeed.CHECKSUMS_NAME)) {
                val body = "${sha256(bytes)}  $fileName\n"
                return DownloadResponse(
                    code = 200,
                    contentLength = body.length.toLong(),
                    contentRangeStart = null,
                    contentRangeTotal = null,
                    etag = "checksums-etag",
                    stream = ByteArrayInputStream(body.toByteArray()),
                )
            }
            val blocking = blockFirstApkRead && apkOpens++ == 0
            val stream = if (blocking) {
                object : InputStream() {
                    private var offset = 0
                    override fun read(): Int {
                        val one = ByteArray(1)
                        val count = read(one, 0, 1)
                        return if (count < 0) -1 else one[0].toInt() and 0xFF
                    }
                    override fun read(buffer: ByteArray, off: Int, len: Int): Int {
                        if (offset == 0) {
                            entered.countDown()
                            check(release.await(20, TimeUnit.SECONDS)) { "test did not release the blocked read" }
                        }
                        if (offset >= bytes.size) return -1
                        val count = minOf(len, bytes.size - offset)
                        System.arraycopy(bytes, offset, buffer, off, count)
                        offset += count
                        return count
                    }
                }
            } else {
                ByteArrayInputStream(bytes)
            }
            return DownloadResponse(
                code = 200,
                contentLength = bytes.size.toLong(),
                contentRangeStart = null,
                contentRangeTotal = null,
                etag = "apk-etag",
                stream = stream,
            )
        }
    }

    private fun release(fileName: String, size: Long) = AndroidRelease(
        tag = "android/v0.1.0-alpha.14",
        version = FloeVersion.parse("0.1.0-alpha.14")!!,
        summary = "notes",
        apk = ReleaseAsset(fileName, size, "https://example.test/$fileName"),
        checksums = ReleaseAsset(
            AndroidReleaseFeed.CHECKSUMS_NAME,
            128L,
            "https://example.test/${AndroidReleaseFeed.CHECKSUMS_NAME}",
        ),
    )

    private suspend fun awaitState(description: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 15_000L
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            delay(20)
        }
        throw AssertionError("timeout waiting for $description")
    }

    @Test
    fun discardJoinsBlockedWriterBeforeDeleteAndNextWriterOwnsState() = runBlocking {
        val dir = Files.createTempDirectory("floe-update-ownership-").toFile()
        val store = FakeStore()
        val apkBytes = "the-real-release-apk-bytes".toByteArray()
        val fileName = "Floe-Android-0.1.0-alpha.14-full-arm64-v8a.apk"
        val transport = ScriptedTransport(apkBytes, fileName, blockFirstApkRead = true)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val subject = UpdateDownloader(
            scope = scope,
            transport = transport,
            store = store,
            stagingDir = dir,
            validate = { null },
        )
        try {
            subject.start(release(fileName, apkBytes.size.toLong()))
            assertTrue("writer must block inside its blocking read", transport.entered.await(15, TimeUnit.SECONDS))
            val part = dir.listFiles()?.firstOrNull { it.name.endsWith(".part") }
            assertTrue("writer must have an open staged part file", part != null)

            // Discard cancels the writer, but MUST join it before deleting:
            // while the read is still blocked the part file must still exist.
            subject.discard()
            delay(300L)
            assertTrue(
                "discard deleted staging bytes before the blocked writer completed",
                part != null && part.exists(),
            )

            transport.release.countDown()
            awaitState("discard completion") {
                subject.state.value === AppDownloadState.Idle && store.pendingDownloadJson == null
            }
            assertEquals(0, dir.listFiles()?.size ?: 0)

            // Next writer: the old writer's finally must not clear/overwrite it.
            subject.start(release(fileName, apkBytes.size.toLong()))
            awaitState("second writer Ready") { subject.state.value is AppDownloadState.Ready }
            val ready = subject.state.value as AppDownloadState.Ready
            assertEquals(fileName, ready.fileName)
            assertEquals(sha256(apkBytes), ready.sha256)
            assertTrue("verified APK must exist", File(dir, fileName).isFile)
            assertEquals(1, dir.listFiles()?.count { it.name.endsWith(".apk") } ?: 0)
        } finally {
            transport.release.countDown()
            dir.deleteRecursively()
            scope.cancel()
        }
    }

    private companion object {
        fun sha256(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
