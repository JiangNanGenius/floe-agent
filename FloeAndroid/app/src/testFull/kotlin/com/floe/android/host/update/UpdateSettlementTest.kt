// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Post-install settlement regression for the actual device sequence:
 * a verified target was installed, the process was killed by the system, the
 * app was reopened (installer adopted the installed version and showed
 * "update installed"), the user tapped Done, and the restored completed
 * download was re-admitted as a NEW update. Because the target versionCode now
 * equals the installed one, strict admission reported VERSION_NOT_HIGHER and
 * the UI showed the false "install package does not match" failure.
 *
 * Settlement must retire only the exact consumed target. Stale or genuinely
 * different bytes must still fail the normal admission checks.
 */
class UpdateSettlementTest {

    private class FakeStore : UpdateStore {
        override var autoCheckEnabled: Boolean = true
        override var lastCheckAtMillis: Long = 0L
        override var dismissedVersion: String? = null
        override var pendingDownloadJson: String? = null
        override var pendingInstallJson: String? = null
    }

    private class ForbiddenTransport : DownloadTransport {
        override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse =
            throw AssertionError("restore must not open a network connection")
    }

    private fun identity(
        packageName: String = "com.floe.agent.full",
        versionCode: Long = 21L,
        versionName: String = "0.1.0-alpha.19",
        signer: Set<String> = setOf("b".repeat(64)),
    ) = ApkIdentity(
        packageName = packageName,
        longVersionCode = versionCode,
        signerSha256 = signer,
        minSdk = 28,
        hasArm64Libraries = true,
        hasForeignAbiLibraries = false,
        versionName = versionName,
    )

    private fun record(
        versionName: String = "0.1.0-alpha.19",
        versionCode: Long = 21L,
        sha256: String = "a".repeat(64),
        fileName: String = "Floe-Android-0.1.0-alpha.19-full-arm64-v8a.apk",
        packageName: String = "com.floe.agent.full",
        signer: Set<String> = setOf("b".repeat(64)),
    ) = PendingInstall(
        versionName = versionName,
        versionCode = versionCode,
        sha256 = sha256,
        fileName = fileName,
        sessionID = 4242,
        packageName = packageName,
        signerSha256 = signer,
    )

    private fun meta(
        fileName: String,
        sha256: String,
        completed: Boolean = true,
        versionName: String = "0.1.0-alpha.19",
        totalBytes: Long = 1L,
    ) = DownloadMeta(
        tag = "android/v0.1.0-alpha.19",
        versionName = versionName,
        fileName = fileName,
        apkUrl = "https://example.test/$fileName",
        checksumsUrl = "https://example.test/SHA256SUMS",
        expectedSha256 = sha256,
        totalBytes = totalBytes,
        receivedBytes = totalBytes,
        etag = "etag",
        completed = completed,
    )

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private suspend fun awaitState(description: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 15_000L
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            delay(20)
        }
        throw AssertionError("timeout waiting for $description")
    }

    @Test
    fun installedSuccessTargetIsSettledNotRejectedAsNewUpdate() {
        val installed = identity()
        val target = identity()

        // The target is exactly the installed app: settlement recognizes it.
        assertTrue(UpdateSettlementPolicy.isInstalledArtifact(target, installed))

        // The ordinary admission rule still says VERSION_NOT_HIGHER; restore
        // must recognize settlement BEFORE applying that new-install rule.
        assertEquals(
            ApkRejection.VERSION_NOT_HIGHER,
            ApkValidationPolicy.rejectReason(target, installed, sdkInt = 33),
        )
    }

    @Test
    fun staleOrWrongTargetStillFailsInstallAdmission() {
        val installed = identity()
        val older = identity(versionCode = 20L, versionName = "0.1.0-alpha.18")
        val wrongSigner = identity(
            versionCode = 22L,
            versionName = "0.1.0-alpha.20",
            signer = setOf("c".repeat(64)),
        )
        val wrongPackage = identity(packageName = "com.floe.agent")
        val wrongVersionName = identity(versionName = "0.1.0-alpha.18")

        assertFalse(UpdateSettlementPolicy.isInstalledArtifact(older, installed))
        assertEquals(
            ApkRejection.VERSION_NOT_HIGHER,
            ApkValidationPolicy.rejectReason(older, installed, sdkInt = 33),
        )

        assertFalse(UpdateSettlementPolicy.isInstalledArtifact(wrongSigner, installed))
        assertEquals(
            ApkRejection.SIGNER_MISMATCH,
            ApkValidationPolicy.rejectReason(wrongSigner, installed, sdkInt = 33),
        )

        assertFalse(UpdateSettlementPolicy.isInstalledArtifact(wrongPackage, installed))
        assertEquals(
            ApkRejection.PACKAGE_MISMATCH,
            ApkValidationPolicy.rejectReason(wrongPackage, installed, sdkInt = 33),
        )

        // Same code/signer but a different version name is not the installed
        // artifact either; settlement never widens on a partial identity match.
        assertFalse(UpdateSettlementPolicy.isInstalledArtifact(wrongVersionName, installed))
    }

    @Test
    fun consumedDownloadAndInstallRecordMustMatchExactly() {
        val installed = identity()
        val install = record()
        assertTrue(UpdateSettlementPolicy.installedMatchesRecord(installed, install))
        assertFalse(UpdateSettlementPolicy.installedMatchesRecord(installed.copy(longVersionCode = 20L), install))
        assertFalse(
            UpdateSettlementPolicy.installedMatchesRecord(
                installed.copy(packageName = "com.floe.agent"),
                install,
            ),
        )
        assertFalse(
            UpdateSettlementPolicy.installedMatchesRecord(
                installed.copy(signerSha256 = setOf("c".repeat(64))),
                install,
            ),
        )

        val completed = meta(install.fileName, install.sha256)
        assertTrue(UpdateSettlementPolicy.isConsumedDownload(completed, install))
        assertFalse(UpdateSettlementPolicy.isConsumedDownload(completed.copy(completed = false), install))
        assertFalse(UpdateSettlementPolicy.isConsumedDownload(completed.copy(expectedSha256 = "c".repeat(64)), install))
        assertFalse(UpdateSettlementPolicy.isConsumedDownload(completed.copy(fileName = "other.apk"), install))
        assertFalse(UpdateSettlementPolicy.isConsumedDownload(completed.copy(versionName = "0.1.0-alpha.18"), install))
    }

    @Test
    fun settledCompletedTargetRestoresAsIdleNotMismatch() = runBlocking {
        val dir = Files.createTempDirectory("floe-update-settled-").toFile()
        val store = FakeStore()
        val bytes = "the-exact-installed-release".toByteArray()
        val sha = sha256(bytes)
        val fileName = "Floe-Android-0.1.0-alpha.19-full-arm64-v8a.apk"
        File(dir, fileName).writeBytes(bytes)
        store.pendingDownloadJson = meta(fileName, sha, totalBytes = bytes.size.toLong()).toJson()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val validateCalls = AtomicInteger(0)
        val subject = UpdateDownloader(
            scope = scope,
            transport = ForbiddenTransport(),
            store = store,
            stagingDir = dir,
            validate = {
                validateCalls.incrementAndGet()
                DownloadFailure.APK_IDENTITY
            },
            settledTarget = { file -> file.isFile && file.readBytes().contentEquals(bytes) },
        )
        try {
            subject.reconcile()
            awaitState("settled target restore") {
                subject.state.value is AppDownloadState.Idle && store.pendingDownloadJson == null
            }
            // This is the regression: the strict new-install rule must not be
            // applied to a completed target that is already installed.
            assertEquals(0, validateCalls.get())
            assertFalse(File(dir, fileName).exists())
        } finally {
            dir.deleteRecursively()
            scope.cancel()
        }
    }

    @Test
    fun lateInstallSettlementSuppressesRestoredMismatch() = runBlocking {
        val dir = Files.createTempDirectory("floe-update-late-settlement-").toFile()
        val store = FakeStore()
        val bytes = "late-settled-release".toByteArray()
        val sha = sha256(bytes)
        val fileName = "Floe-Android-0.1.0-alpha.19-full-arm64-v8a.apk"
        File(dir, fileName).writeBytes(bytes)
        store.pendingDownloadJson = meta(fileName, sha, totalBytes = bytes.size.toLong()).toJson()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val subject = UpdateDownloader(
            scope = scope,
            transport = ForbiddenTransport(),
            store = store,
            stagingDir = dir,
            validate = {
                entered.countDown()
                check(release.await(15, TimeUnit.SECONDS)) { "test did not release validation" }
                DownloadFailure.APK_IDENTITY
            },
        )
        try {
            subject.reconcile()
            assertTrue("restore must reach the identity decision", entered.await(15, TimeUnit.SECONDS))
            assertTrue(subject.state.value is AppDownloadState.Verifying)

            // A completed install settles the same target while the restored
            // record is still being classified: the durable record is retired
            // and the exact staged file is removed by the install owner.
            store.pendingDownloadJson = null
            File(dir, fileName).delete()
            release.countDown()

            awaitState("late settlement result") { subject.state.value is AppDownloadState.Idle }
            assertFalse(
                "a settled install must not surface the restored mismatch",
                subject.state.value is AppDownloadState.Failed,
            )
            assertNull(store.pendingDownloadJson)
        } finally {
            release.countDown()
            dir.deleteRecursively()
            scope.cancel()
        }
    }

    @Test
    fun genuinelyWrongCompletedTargetStillReportsIdentityFailure() = runBlocking {
        val dir = Files.createTempDirectory("floe-update-wrong-target-").toFile()
        val store = FakeStore()
        val bytes = "genuinely-wrong-target".toByteArray()
        val sha = sha256(bytes)
        val fileName = "Floe-Android-0.1.0-alpha.19-full-arm64-v8a.apk"
        File(dir, fileName).writeBytes(bytes)
        store.pendingDownloadJson = meta(fileName, sha, totalBytes = bytes.size.toLong()).toJson()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val subject = UpdateDownloader(
            scope = scope,
            transport = ForbiddenTransport(),
            store = store,
            stagingDir = dir,
            validate = { DownloadFailure.APK_IDENTITY },
            settledTarget = { false },
        )
        try {
            subject.reconcile()
            awaitState("wrong target rejection") {
                subject.state.value is AppDownloadState.Failed
            }
            val failed = subject.state.value as AppDownloadState.Failed
            assertEquals(DownloadFailure.APK_IDENTITY, failed.kind)
            assertNull(store.pendingDownloadJson)
            assertFalse(File(dir, fileName).exists())
        } finally {
            dir.deleteRecursively()
            scope.cancel()
        }
    }

    @Test
    fun missingCompletedBytesClearStaleRecordInsteadOfMismatchOrCrash() = runBlocking {
        val dir = Files.createTempDirectory("floe-update-missing-bytes-").toFile()
        val store = FakeStore()
        val fileName = "Floe-Android-0.1.0-alpha.19-full-arm64-v8a.apk"
        store.pendingDownloadJson = meta(fileName, "a".repeat(64)).toJson()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val subject = UpdateDownloader(
            scope = scope,
            transport = ForbiddenTransport(),
            store = store,
            stagingDir = dir,
            validate = { DownloadFailure.APK_IDENTITY },
        )
        try {
            subject.reconcile()
            awaitState("missing completed bytes") { store.pendingDownloadJson == null }
            assertTrue(subject.state.value is AppDownloadState.Idle)
        } finally {
            dir.deleteRecursively()
            scope.cancel()
        }
    }
}
