// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/**
 * Official GitHub REST asset alias: when the canonical browser route cannot
 * serve a release asset (the observed HTTP 504 class), the SAME asset is
 * fetched through its validated public REST address with
 * `Accept: application/octet-stream` and no account Authorization.
 *
 * The alias is bounded (canonical first, at most one alias attempt), keeps
 * the selected mirror and never weakens the release-integrity chain.
 */
class UpdateOfficialAssetRouteTest {
    private class Store : UpdateStore {
        override var autoCheckEnabled = true
        override var lastCheckAtMillis = 0L
        override var dismissedVersion: String? = null
        override var pendingDownloadJson: String? = null
        override var pendingInstallJson: String? = null
        override var downloadSource = UpdateDownloadSource.GITHUB
    }

    private val version = "0.1.0-alpha.60"
    private val apkName = "Floe-Android-$version-full-arm64-v8a.apk"
    private val patchName = "Floe-Android-$version-from-0.1.0-alpha.59.delta"
    private val canonical = "https://github.com/JiangNanGenius/floe-agent/releases/download/android/v$version/"
    private val apkApi = "https://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/723469213"
    private val sumsApi = "https://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/723469214"
    private val bytes = ByteArray(600_000) { (it * 17).toByte() }
    private fun sha(data: ByteArray) = MessageDigest.getInstance("SHA-256")
        .digest(data).joinToString("") { "%02x".format(it) }
    private fun response(data: ByteArray, code: Int = 200, offset: Long? = null,
        total: Long? = null, etag: String? = null, contentType: String? = null,
        stream: InputStream = ByteArrayInputStream(data)) =
        DownloadResponse(code, data.size.toLong(), offset, total, etag, stream, contentType)
    private fun sums() = response("${sha(bytes)}  $apkName\n".toByteArray())
    private fun release(apkApiUrl: String? = apkApi, sumsApiUrl: String? = sumsApi) = AndroidRelease(
        "android/v$version", FloeVersion.parse(version)!!, "notes",
        ReleaseAsset(apkName, bytes.size.toLong(), canonical + apkName, apkApiUrl),
        ReleaseAsset("SHA256SUMS", 128, canonical + "SHA256SUMS", sumsApiUrl),
    )

    private suspend fun await(description: String, condition: () -> Boolean) {
        repeat(500) { if (condition()) return; delay(10) }
        throw AssertionError("timeout: $description")
    }

    @Test fun officialAliasValidatorAcceptsOnlyThisRepositoriesAssetEndpoint() {
        assertEquals(apkApi, OfficialAssetRoute.validatedApiUrl(apkApi))
        for (bad in listOf(
            "",
            "https://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/",
            "https://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/abc",
            "https://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/723469213?x=1",
            "https://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/723469213#x",
            "https://api.github.com/repos/Other/floe-agent/releases/assets/723469213",
            "https://api.github.com/repos/JiangNanGenius/other/releases/assets/723469213",
            "https://github.com/JiangNanGenius/floe-agent/releases/assets/723469213",
            "http://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/723469213",
            "https://user@api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/723469213",
            "https://api.github.com:8443/repos/JiangNanGenius/floe-agent/releases/assets/723469213",
            "https://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/723469213/",
        )) {
            assertNull("accepted $bad", OfficialAssetRoute.validatedApiUrl(bad))
        }
    }

    @Test fun feedCarriesValidatedAliasAndDropsEverythingElse() {
        fun asset(name: String, size: Long, url: String, api: String?) =
            """{"name":"$name","size":$size,"browser_download_url":"$url"""" +
                (api?.let { ""","url":"$it"""" } ?: "") + "}"
        fun rel(api: String?) = """{"tag_name":"android/v$version","draft":false,"prerelease":true,"body":"notes","assets":[""" +
            asset(apkName, bytes.size.toLong(), canonical + apkName, api) + "," +
            asset("SHA256SUMS", 128, canonical + "SHA256SUMS", api) + "]}"

        val parsed = AndroidReleaseFeed.parsePage("[" + rel(apkApi) + "]")
        assertEquals(1, parsed.size)
        assertEquals(apkApi, parsed[0].apk.apiUrl)
        assertEquals(apkApi, parsed[0].checksums.apiUrl)

        val foreign = AndroidReleaseFeed.parsePage(
            "[" + rel("https://api.github.com/repos/Other/floe-agent/releases/assets/723469213") + "]",
        )
        assertEquals(1, foreign.size)
        assertNull(foreign[0].apk.apiUrl)

        val missing = AndroidReleaseFeed.parsePage("[" + rel(null) + "]")
        assertNull(missing[0].apk.apiUrl)
    }

    @Test fun gatewayFailureOnCanonicalServesSameAssetThroughOfficialAlias() = runBlocking {
        val dir = Files.createTempDirectory("floe-alias-basic-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = Store()
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                requests += url
                return when (url) {
                    canonical + "SHA256SUMS" -> sums()
                    canonical + apkName -> throw DownloadStatusException(504)
                    apkApi -> response(bytes)
                    else -> error("unexpected URL $url")
                }
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { null })
        try {
            subject.startFull(release())
            await("alias-served download ready") { subject.state.value is AppDownloadState.Ready }
            assertArrayEquals(bytes, subject.readyFile()!!.readBytes())
            assertEquals(UpdateDownloadSource.GITHUB, store.downloadSource)
            assertTrue(subject.sourceState.value.officialAliasUsed)
            // Checksums came from the canonical route; the APK fell back once.
            assertEquals(listOf(canonical + "SHA256SUMS", canonical + apkName, apkApi), requests)
            val meta = DownloadMeta.fromJson(store.pendingDownloadJson)!!
            assertTrue(meta.completed)
            assertEquals(apkApi, meta.apkApiUrl)
            assertEquals(sumsApi, meta.checksumsApiUrl)
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun metadataSidecarFallsBackToOfficialAlias() = runBlocking {
        val dir = Files.createTempDirectory("floe-alias-sidecar-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = Store()
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                requests += url
                return when (url) {
                    canonical + "SHA256SUMS" -> throw DownloadStatusException(504)
                    sumsApi -> sums()
                    canonical + apkName -> response(bytes)
                    else -> error("unexpected URL $url")
                }
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { null })
        try {
            subject.startFull(release())
            await("sidecar alias download ready") { subject.state.value is AppDownloadState.Ready }
            assertArrayEquals(bytes, subject.readyFile()!!.readBytes())
            assertEquals(listOf(canonical + "SHA256SUMS", sumsApi, canonical + apkName), requests)
            assertTrue(subject.sourceState.value.officialAliasUsed)
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun persistedMetaRoundTripsAliasAndRejectsTamperedAlias() {
        val meta = DownloadMeta(
            tag = "android/v$version", versionName = version, fileName = apkName,
            apkUrl = canonical + apkName, checksumsUrl = canonical + "SHA256SUMS",
            expectedSha256 = sha(bytes), totalBytes = bytes.size.toLong(), receivedBytes = 0L,
            etag = null, completed = false, apkApiUrl = apkApi, checksumsApiUrl = sumsApi,
        )
        val parsed = DownloadMeta.fromJson(meta.toJson())!!
        assertEquals(apkApi, parsed.apkApiUrl)
        assertEquals(sumsApi, parsed.checksumsApiUrl)
        assertEquals(meta, parsed)

        val tampered = DownloadMeta.fromJson(
            meta.toJson().replace(apkApi, "http://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/723469213"),
        )!!
        assertNull(tampered.apkApiUrl)
        assertEquals(sumsApi, tampered.checksumsApiUrl)
    }

    @Test fun jsonMetadataBodyIsRefusedAndAliasRescuesTheDownload() = runBlocking {
        val dir = Files.createTempDirectory("floe-alias-json-rescue-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = Store()
        val validated = AtomicBoolean(false)
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val jsonBody = """{"id":723469213,"name":"$apkName"}""".toByteArray()
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                requests += url
                return when (url) {
                    canonical + "SHA256SUMS" -> sums()
                    canonical + apkName -> response(jsonBody, contentType = "application/json; charset=utf-8")
                    apkApi -> response(bytes)
                    else -> error("unexpected URL $url")
                }
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { validated.set(true); null })
        try {
            subject.startFull(release())
            await("alias rescued download ready") { subject.state.value is AppDownloadState.Ready }
            assertArrayEquals(bytes, subject.readyFile()!!.readBytes())
            assertTrue(subject.sourceState.value.officialAliasUsed)
            assertTrue(validated.get())
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun jsonMetadataBodyOnEveryRouteFailsClosedWithoutStagedBytes() = runBlocking {
        val dir = Files.createTempDirectory("floe-alias-json-both-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = Store()
        val validated = AtomicBoolean(false)
        val jsonBody = """{"message":"Not Acceptable"}""".toByteArray()
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                return when (url) {
                    canonical + "SHA256SUMS" -> sums()
                    else -> response(jsonBody, contentType = "application/json")
                }
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { validated.set(true); null })
        try {
            subject.startFull(release())
            await("json body refused") { subject.state.value is AppDownloadState.Failed }
            val failed = subject.state.value as AppDownloadState.Failed
            assertEquals(DownloadFailure.NETWORK, failed.kind)
            assertFalse(validated.get())
            assertNull(subject.readyFile())
            assertTrue(dir.listFiles().isNullOrEmpty())
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun partialPrefixRestartsCleanlyWhenAliasServesFullBody() = runBlocking {
        val dir = Files.createTempDirectory("floe-alias-restart-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val prefix = 128 * 1024
        val meta = DownloadMeta(
            tag = "android/v$version", versionName = version, fileName = apkName,
            apkUrl = canonical + apkName, checksumsUrl = canonical + "SHA256SUMS",
            expectedSha256 = sha(bytes), totalBytes = bytes.size.toLong(), receivedBytes = prefix.toLong(),
            etag = "\"stable\"", completed = false, apkApiUrl = apkApi, checksumsApiUrl = sumsApi,
        )
        val store = Store().apply { pendingDownloadJson = meta.toJson() }
        dir.resolve("android_v$version.part").writeBytes(bytes.copyOf(prefix))
        val ranged = Collections.synchronizedList(mutableListOf<Pair<String, Long?>>())
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                ranged += url to rangeFrom
                return when {
                    url == canonical + "SHA256SUMS" -> sums()
                    url == canonical + apkName && rangeFrom != null -> throw DownloadStatusException(504)
                    url == apkApi && rangeFrom != null -> response(bytes) // 200: alias cannot range here
                    url == canonical + apkName -> throw DownloadStatusException(504)
                    url == apkApi -> response(bytes)
                    else -> error("unexpected URL $url")
                }
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { null })
        try {
            subject.reconcile()
            assertTrue(subject.state.value is AppDownloadState.Paused)
            subject.resume()
            await("clean restart through alias") { subject.state.value is AppDownloadState.Ready }
            assertArrayEquals(bytes, subject.readyFile()!!.readBytes())
            assertEquals(bytes.size.toLong(), subject.readyFile()!!.length())
            assertTrue(subject.sourceState.value.restarted)
            assertTrue(subject.sourceState.value.officialAliasUsed)
            // Ranged try on both routes, then one clean full restart pair.
            assertEquals(
                listOf(canonical + apkName to prefix.toLong(), apkApi to prefix.toLong(),
                    canonical + apkName to null, apkApi to null),
                ranged,
            )
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun aliasHonoursRealPartialResponseAndAppendsExactPrefix() = runBlocking {
        val dir = Files.createTempDirectory("floe-alias-append-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val prefix = 64 * 1024
        val meta = DownloadMeta(
            tag = "android/v$version", versionName = version, fileName = apkName,
            apkUrl = canonical + apkName, checksumsUrl = canonical + "SHA256SUMS",
            expectedSha256 = sha(bytes), totalBytes = bytes.size.toLong(), receivedBytes = prefix.toLong(),
            etag = "\"stable\"", completed = false, apkApiUrl = apkApi, checksumsApiUrl = sumsApi,
        )
        val store = Store().apply { pendingDownloadJson = meta.toJson() }
        dir.resolve("android_v$version.part").writeBytes(bytes.copyOf(prefix))
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                return when {
                    url == canonical + "SHA256SUMS" -> sums()
                    url == canonical + apkName -> throw DownloadStatusException(504)
                    url == apkApi && rangeFrom == prefix.toLong() ->
                        response(bytes.copyOfRange(prefix, bytes.size), 206, prefix.toLong(),
                            bytes.size.toLong(), "\"stable\"")
                    else -> error("unexpected URL $url rangeFrom=$rangeFrom")
                }
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { null })
        try {
            subject.reconcile()
            subject.resume()
            await("alias partial append ready") { subject.state.value is AppDownloadState.Ready }
            assertArrayEquals(bytes, subject.readyFile()!!.readBytes())
            assertFalse(subject.sourceState.value.restarted)
            assertTrue(subject.sourceState.value.officialAliasUsed)
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun cancellationDuringAliasReadPausesWithoutRetryLoop() = runBlocking {
        val dir = Files.createTempDirectory("floe-alias-cancel-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = Store()
        val aliasOpens = AtomicInteger()
        val delivered = AtomicInteger()
        val closed = CountDownLatch(1)
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                return when (url) {
                    canonical + "SHA256SUMS" -> sums()
                    canonical + apkName -> throw DownloadStatusException(504)
                    apkApi -> {
                        aliasOpens.incrementAndGet()
                        val stream = object : InputStream() {
                            private var position = 0
                            override fun read(): Int = error("bulk reads only")
                            override fun read(buffer: ByteArray, off: Int, len: Int): Int {
                                if (position < bytes.size) {
                                    val count = minOf(len, bytes.size - position)
                                    System.arraycopy(bytes, position, buffer, off, count)
                                    position += count
                                    delivered.addAndGet(count)
                                    return count
                                }
                                closed.await(5, TimeUnit.SECONDS)
                                return -1
                            }
                            override fun close() { closed.countDown() }
                        }
                        response(bytes, stream = stream)
                    }
                    else -> error("unexpected URL $url")
                }
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { null })
        try {
            subject.startFull(release())
            await("alias stream delivering") { delivered.get() >= bytes.size }
            subject.cancel()
            await("cancelled writer paused") {
                subject.state.value is AppDownloadState.Paused || subject.state.value is AppDownloadState.Idle
            }
            assertEquals(1, aliasOpens.get())
            delay(100)
            assertEquals(1, aliasOpens.get()) // no retry loop after cancellation
            assertFalse(subject.state.value is AppDownloadState.Ready)
        } finally { closed.countDown(); scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun definitiveRefusalSkipsTheAlias() = runBlocking {
        val dir = Files.createTempDirectory("floe-alias-404-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = Store()
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                requests += url
                return when (url) {
                    canonical + "SHA256SUMS" -> sums()
                    canonical + apkName -> throw DownloadStatusException(404)
                    else -> error("unexpected URL $url")
                }
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { null })
        try {
            subject.startFull(release())
            await("definitive refusal failed") { subject.state.value is AppDownloadState.Failed }
            assertEquals(DownloadFailure.NETWORK, (subject.state.value as AppDownloadState.Failed).kind)
            assertFalse(requests.contains(apkApi))
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun sharedRouteDoesNotRetryProgrammingFailuresOrCancellation() = runBlocking {
        for (failure in listOf(IllegalStateException("local-state"),
            kotlinx.coroutines.CancellationException("cancelled"))) {
            val requests = mutableListOf<String>()
            val thrown = try {
                OfficialAssetRoute.open(canonical + apkName, apkApi, payload = true, request = { url ->
                    requests += url
                    throw failure
                })
                null
            } catch (caught: Exception) { caught }
            assertSame(failure, thrown)
            assertEquals(listOf(canonical + apkName), requests)
        }
    }

    @Test fun optionalComponentBytesUseTheSharedRouteAndSelectedMirror() = runBlocking {
        for (kind in listOf("Office", "CAD")) {
            val component = canonical + "Floe-$kind-Preview-$version-full-arm64-v8a.component"
            val requests = mutableListOf<String>()
            val received = OfficialAssetRoute.open(component, apkApi, payload = true, request = { url ->
                requests += url
                if (url == component) throw IOException("connection-reset")
                response(bytes)
            }).stream.use { it.readBytes() }
            assertArrayEquals(bytes, received)
            assertEquals(listOf(component, apkApi), requests)
            assertEquals("https://ghfast.top/$component", UpdateDownloadSource.GHFAST.assetUrl(component))
        }
    }

    @Test fun selectedMirrorNeverAliasesOrSwitchesBackToGitHub() = runBlocking {
        val dir = Files.createTempDirectory("floe-alias-mirror-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = Store().apply { downloadSource = UpdateDownloadSource.GHFAST }
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                requests += url
                return when (url) {
                    canonical + "SHA256SUMS" -> sums()
                    "https://ghfast.top/" + canonical + apkName -> throw DownloadStatusException(504)
                    else -> error("unexpected URL $url")
                }
            }
        }
        val subject = UpdateDownloader(scope, transport, store, dir, { null })
        try {
            subject.startFull(release())
            await("mirror failure surfaced") { subject.state.value is AppDownloadState.Failed }
            assertEquals(DownloadFailure.NETWORK, (subject.state.value as AppDownloadState.Failed).kind)
            assertTrue(requests.none { it.startsWith("https://api.github.com/") })
            assertEquals(UpdateDownloadSource.GHFAST, store.downloadSource)
            assertEquals(UpdateDownloadSource.GHFAST, subject.sourceState.value.selected)
            assertFalse(subject.sourceState.value.officialAliasUsed)
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun deltaManifestAndPatchUseTheSameOfficialAlias() = runBlocking {
        val dir = Files.createTempDirectory("floe-alias-delta-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val base = dir.resolve("installed.apk").apply { writeBytes(ByteArray(900) { 7 }) }
        val full = ByteArray(1000) { 8 }
        val patch = ByteArray(300) { 9 } // Hash-valid download, invalid FloePatch header.
        val signer = "5".repeat(64)
        val manifest = """{
          "schema":"floe.android.update.delta/1","channel":"full-arm64-v8a",
          "package":"com.floe.agent.full","releaseTag":"android/v$version",
          "base":{"apkName":"Floe-Android-0.1.0-alpha.59-full-arm64-v8a.apk",
            "sha256":"${sha(base.readBytes())}","sizeBytes":900,"versionName":"0.1.0-alpha.59","versionCode":85},
          "target":{"apkName":"$apkName","sha256":"${sha(full)}","sizeBytes":1000,
            "versionName":"$version","versionCode":86,"minSdk":28,
            "abis":["arm64-v8a"],"signerSha256":["$signer"]},
          "patch":{"format":"floepatch","version":1,"assetName":"$patchName",
            "sizeBytes":300,"sha256":"${sha(patch)}"}}
        """.trimIndent().toByteArray()
        val sums = "${sha(full)}  $apkName\n${sha(patch)}  $patchName\n${sha(manifest)}  update-delta-v1.json\n".toByteArray()
        val manifestApi = "https://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/723469336"
        val patchApi = "https://api.github.com/repos/JiangNanGenius/floe-agent/releases/assets/723469215"
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val transport = object : DownloadTransport {
            override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
                requests += url
                return when (url) {
                    canonical + "SHA256SUMS" -> response(sums)
                    canonical + "update-delta-v1.json" -> throw DownloadStatusException(504)
                    manifestApi -> response(manifest)
                    canonical + patchName -> throw DownloadStatusException(504)
                    patchApi -> response(patch)
                    canonical + apkName -> throw DownloadStatusException(504)
                    apkApi -> response(full)
                    else -> error("unexpected URL $url")
                }
            }
        }
        fun asset(name: String, size: Int, api: String?) =
            ReleaseAsset(name, size.toLong(), canonical + name, api)
        val release = AndroidRelease(
            tag = "android/v$version", version = FloeVersion.parse(version)!!, summary = "",
            apk = asset(apkName, full.size, apkApi),
            checksums = asset("SHA256SUMS", sums.size, sumsApi),
            delta = asset("update-delta-v1.json", manifest.size, manifestApi),
            assets = mapOf(patchName to asset(patchName, patch.size, patchApi)),
        )
        val subject = UpdateDownloader(scope, transport, Store(), dir.resolve("staging"), { null },
            deltaBaseProvider = InstalledBaseProvider {
                InstalledBaseInfo(base, base.length(), "com.floe.agent.full", "0.1.0-alpha.59", 85,
                    setOf(signer), false, 35)
            })
        try {
            subject.start(release)
            await("delta fallback after alias-served patch") {
                subject.state.value is AppDownloadState.DeltaFallback
            }
            assertTrue(requests.contains(manifestApi))
            assertTrue(requests.contains(patchApi))
            subject.startFull(release)
            await("full apk via alias ready") { subject.state.value is AppDownloadState.Ready }
            assertArrayEquals(full, subject.readyFile()!!.readBytes())
            assertTrue(requests.contains(apkApi))
            assertTrue(subject.sourceState.value.officialAliasUsed)
        } finally { scope.coroutineContext[Job]!!.cancelAndJoin(); dir.deleteRecursively() }
    }
}
