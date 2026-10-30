// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Typed install outcomes and the process-death record. These are the exact
 * values the UI now distinguishes instead of one generic "Installation failed",
 * plus the storage preflight that prevents a mid-session STORAGE failure.
 */
class InstallPolicyTest {

    @Test
    fun mapsEveryPlatformStatusToATypedFailure() {
        assertEquals(InstallFailure.BLOCKED, InstallFailureClassifier.classify(2))
        assertEquals(InstallFailure.CANCELLED, InstallFailureClassifier.classify(3))
        assertEquals(InstallFailure.INVALID_PACKAGE, InstallFailureClassifier.classify(4))
        assertEquals(InstallFailure.CONFLICT, InstallFailureClassifier.classify(5))
        assertEquals(InstallFailure.STORAGE, InstallFailureClassifier.classify(6))
        assertEquals(InstallFailure.INCOMPATIBLE, InstallFailureClassifier.classify(7))
        assertEquals(InstallFailure.SYSTEM, InstallFailureClassifier.classify(1))
    }

    @Test
    fun usesTheLegacyCodeForTheSpecificCause() {
        assertEquals(
            InstallFailure.INCOMPATIBLE,
            InstallFailureClassifier.classify(1, InstallFailureClassifier.INSTALL_FAILED_UPDATE_INCOMPATIBLE),
        )
        assertEquals(
            InstallFailure.VERIFICATION,
            InstallFailureClassifier.classify(1, InstallFailureClassifier.INSTALL_FAILED_VERIFICATION_FAILURE),
        )
        assertEquals(
            InstallFailure.INVALID_PACKAGE,
            InstallFailureClassifier.classify(1, InstallFailureClassifier.INSTALL_FAILED_INVALID_APK),
        )
        assertEquals(
            InstallFailure.STORAGE,
            InstallFailureClassifier.classify(1, InstallFailureClassifier.INSTALL_FAILED_INSUFFICIENT_STORAGE),
        )
        assertEquals(
            InstallFailure.CANCELLED,
            InstallFailureClassifier.classify(1, InstallFailureClassifier.INSTALL_FAILED_ABORTED),
        )
    }

    @Test
    fun storagePreflightCoversTheInstallerCopy() {
        val apk = 445_796_721L
        val required = InstallStoragePolicy.requiredBytes(apk)
        assertTrue("installer needs its own copy plus headroom", required >= apk + UpdateConfig.INSTALL_HEADROOM_BYTES)
        assertFalse(InstallStoragePolicy.hasRoom(required - 1, apk))
        assertTrue(InstallStoragePolicy.hasRoom(required, apk))
        // Unknown reporting must not fabricate a failure.
        assertTrue(InstallStoragePolicy.hasRoom(0L, apk))
    }

    @Test
    fun pendingInstallRoundTripsIdentityForPostRestartProof() {
        val record = PendingInstall(
            versionName = "0.1.0-alpha.17",
            versionCode = 19L,
            sha256 = "a".repeat(64),
            fileName = "Floe-Android-0.1.0-alpha.17-full-arm64-v8a.apk",
            sessionID = 4242,
            packageName = "com.floe.agent.full",
            signerSha256 = setOf("b".repeat(64)),
        )
        val parsed = PendingInstall.fromJson(record.toJson())
        assertNotNull(parsed)
        requireNotNull(parsed)
        assertEquals(record, parsed)
    }

    @Test
    fun pendingInstallRejectsUnsafeOrMalformedRecords() {
        assertNull(PendingInstall.fromJson(null))
        assertNull(PendingInstall.fromJson("not json"))
        val valid = """{"versionName":"v","versionCode":19,"sha256":"${"a".repeat(64)}",
            "fileName":"ok.apk","sessionID":1,"packageName":"","signerSha256":""}"""
        assertNotNull(PendingInstall.fromJson(valid))
        assertNull(PendingInstall.fromJson(valid.replace("\"ok.apk\"", "\"../ok.apk\"")))
        assertNull(PendingInstall.fromJson(valid.replace("\"sha256\":\"${"a".repeat(64)}\"", "\"sha256\":\"zz\"")))
        assertNull(PendingInstall.fromJson(valid.replace("\"sessionID\":1", "\"sessionID\":0")))
    }

    @Test
    fun deltaDownloadRecordKeepsItsBoundIdentity() {
        val meta = DownloadMeta(
            tag = "android/v0.1.0-alpha.17",
            versionName = "0.1.0-alpha.17",
            fileName = "Floe-Android-0.1.0-alpha.17-full-arm64-v8a.apk",
            apkUrl = "https://example.test/apk",
            checksumsUrl = "https://example.test/SHA256SUMS",
            expectedSha256 = "a".repeat(64),
            totalBytes = 445_796_721L,
            receivedBytes = 445_796_721L,
            etag = null,
            completed = true,
            mode = DownloadMode.DELTA,
            deltaBaseSha256 = "b".repeat(64),
            deltaPatchName = "patch.delta",
            deltaPatchSha256 = "c".repeat(64),
            deltaPatchBytes = 143_477_820L,
        )
        val parsed = DownloadMeta.fromJson(meta.toJson())
        assertNotNull(parsed)
        assertEquals(meta, parsed)
        // A DELTA record without its patch binding is not resumable/adoptable.
        assertNull(
            DownloadMeta.fromJson(
                meta.toJson().replace("\"deltaPatchName\":\"patch.delta\"", "\"deltaPatchName\":\"\""),
            ),
        )
        // A pre-delta record still parses as a full download.
        val legacy = """{"tag":"android/v0.1.0-alpha.17","versionName":"0.1.0-alpha.17",
            "fileName":"Floe-Android-0.1.0-alpha.17-full-arm64-v8a.apk",
            "apkUrl":"https://example.test/apk","checksumsUrl":"https://example.test/SHA256SUMS",
            "expectedSha256":"${"a".repeat(64)}","totalBytes":445796721,"receivedBytes":445796721,
            "etag":"","completed":true}"""
        val legacyMeta = DownloadMeta.fromJson(legacy)
        assertNotNull(legacyMeta)
        assertEquals(DownloadMode.FULL, legacyMeta?.mode)
    }
}
