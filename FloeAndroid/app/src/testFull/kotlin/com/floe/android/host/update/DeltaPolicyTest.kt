// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Delta admission policy. Every refusal path must fall back to the full APK;
 * a delta is used only when the release tag/APK, the release's own SHA256SUMS,
 * the manifest, the optional patch asset and the INSTALLED base APK all agree.
 */
class DeltaPolicyTest {

    private val targetSha = "1".repeat(64)
    private val baseSha = "2".repeat(64)
    private val patchSha = "3".repeat(64)
    private val manifestSha = "4".repeat(64)
    private val signer = "5".repeat(64)

    private val apkName = "Floe-Android-0.1.0-alpha.17-full-arm64-v8a.apk"
    private val patchName = "Floe-Android-0.1.0-alpha.17-from-0.1.0-alpha.16.delta"
    private val baseName = "Floe-Android-0.1.0-alpha.16-full-arm64-v8a.apk"
    private val tag = "android/v0.1.0-alpha.17"

    private fun manifest(
        patchBytes: Long = 300L,
        targetBytes: Long = 1_000L,
        baseBytes: Long = 900L,
        baseVersionCode: Long = 18L,
    ) = UpdateDeltaManifest(
        schema = UpdateDeltaFormat.SCHEMA,
        channel = UpdateDeltaFormat.CHANNEL,
        packageName = "com.floe.agent.full",
        releaseTag = tag,
        base = DeltaBaseIdentity(baseName, baseSha, baseBytes, "0.1.0-alpha.16", baseVersionCode),
        target = DeltaTargetIdentity(
            apkName, targetSha, targetBytes, "0.1.0-alpha.17", 19L, 28, listOf("arm64-v8a"), listOf(signer),
        ),
        patch = DeltaPatch("floepatch", 1, patchName, patchBytes, patchSha),
    )

    private fun release(
        deltaAsset: ReleaseAsset? = ReleaseAsset(
            UpdateDeltaFormat.MANIFEST_ASSET, 500, "https://example.test/update-delta-v1.json",
        ),
        patchAsset: ReleaseAsset? = ReleaseAsset(patchName, 300, "https://example.test/$patchName"),
    ): AndroidRelease {
        val assets = LinkedHashMap<String, ReleaseAsset>()
        assets[apkName] = ReleaseAsset(apkName, 1_000, "https://example.test/$apkName")
        assets[AndroidReleaseFeed.CHECKSUMS_NAME] = ReleaseAsset(
            AndroidReleaseFeed.CHECKSUMS_NAME, 200, "https://example.test/SHA256SUMS",
        )
        if (deltaAsset != null) assets[deltaAsset.name] = deltaAsset
        if (patchAsset != null) assets[patchAsset.name] = patchAsset
        return AndroidRelease(
            tag = tag,
            version = FloeVersion.parse("0.1.0-alpha.17")!!,
            summary = "",
            apk = assets.getValue(apkName),
            checksums = assets.getValue(AndroidReleaseFeed.CHECKSUMS_NAME),
            delta = deltaAsset,
            assets = assets,
        )
    }

    private fun manifestText(value: UpdateDeltaManifest = manifest()): String = """
        {
          "schema": "${value.schema}",
          "channel": "${value.channel}",
          "package": "${value.packageName}",
          "releaseTag": "${value.releaseTag}",
          "base": {
            "apkName": "${value.base.apkName}",
            "sha256": "${value.base.sha256}",
            "sizeBytes": ${value.base.sizeBytes},
            "versionName": "${value.base.versionName}",
            "versionCode": ${value.base.versionCode}
          },
          "target": {
            "apkName": "${value.target.apkName}",
            "sha256": "${value.target.sha256}",
            "sizeBytes": ${value.target.sizeBytes},
            "versionName": "${value.target.versionName}",
            "versionCode": ${value.target.versionCode},
            "minSdk": ${value.target.minSdk},
            "abis": [${value.target.abis.joinToString(",") { "\"$it\"" }}],
            "signerSha256": [${value.target.signerSha256.joinToString(",") { "\"$it\"" }}]
          },
          "patch": {
            "format": "${value.patch.format}",
            "version": ${value.patch.version},
            "assetName": "${value.patch.assetName}",
            "sizeBytes": ${value.patch.sizeBytes},
            "sha256": "${value.patch.sha256}"
          }
        }
    """.trimIndent()

    private fun checksums(
        apkHash: String = targetSha,
        manifestHash: String = manifestSha,
        patchHash: String = patchSha,
        includePatch: Boolean = true,
    ): Map<String, String> {
        val map = LinkedHashMap<String, String>()
        map[apkName] = apkHash
        map[UpdateDeltaFormat.MANIFEST_ASSET] = manifestHash
        if (includePatch) map[patchName] = patchHash
        return map
    }

    private fun installed(
        file: File,
        versionCode: Long = 18L,
        versionName: String = "0.1.0-alpha.16",
        sizeBytes: Long = 900L,
        signers: Set<String> = setOf(signer),
        split: Boolean = false,
    ) = InstalledBaseInfo(
        apkFile = file,
        apkSizeBytes = sizeBytes,
        packageName = "com.floe.agent.full",
        versionName = versionName,
        versionCode = versionCode,
        signerSha256 = signers,
        hasSplitApks = split,
        sdkInt = 37,
    )

    private fun <T> withBase(block: (File) -> T): T {
        val dir = Files.createTempDirectory("floe-delta-policy-").toFile()
        try {
            val file = File(dir, "base.apk")
            file.writeBytes(ByteArray(900) { 7 })
            return block(file)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun acceptsAFullyBoundDelta() = withBase { file ->
        val decision = UpdateDeltaPolicy.decide(
            enabled = true,
            release = release(),
            checksums = checksums(),
            manifestText = manifestText(),
            installed = installed(file),
            installedApkSha256 = baseSha,
        )
        assertTrue(decision is DeltaDecision.Use)
        assertEquals(300L, (decision as DeltaDecision.Use).patchAsset.sizeBytes)
    }

    private fun skip(
        releaseOverride: AndroidRelease = release(),
        sums: Map<String, String> = checksums(),
        text: String = manifestText(),
        installedInfo: (File) -> InstalledBaseInfo = { installed(it) },
        enabled: Boolean = true,
        baseSha: String? = this.baseSha,
    ): DeltaSkipReason = withBase { file ->
        val decision = UpdateDeltaPolicy.decide(
            enabled = enabled,
            release = releaseOverride,
            checksums = sums,
            manifestText = text,
            installed = installedInfo(file),
            installedApkSha256 = baseSha,
        )
        assertTrue("expected a skip, got $decision", decision is DeltaDecision.Skip)
        (decision as DeltaDecision.Skip).reason
    }

    @Test
    fun refusesWhenDisabledOrMissingOrUnbound() {
        assertEquals(DeltaSkipReason.DISABLED, skip(enabled = false))
        assertEquals(DeltaSkipReason.NO_MANIFEST_ASSET, skip(releaseOverride = release(deltaAsset = null)))
        assertEquals(DeltaSkipReason.MANIFEST_INVALID, skip(text = "{}"))
        assertEquals(DeltaSkipReason.MANIFEST_INVALID, skip(sums = checksums().minus(UpdateDeltaFormat.MANIFEST_ASSET)))
        assertEquals(DeltaSkipReason.RELEASE_MISMATCH, skip(releaseOverride = release().copy(tag = "android/v0.1.0-alpha.18")))
        assertEquals(DeltaSkipReason.TARGET_NOT_BOUND, skip(sums = checksums(apkHash = "9".repeat(64))))
    }

    @Test
    fun refusesUnboundOrOversizedPatch() {
        assertEquals(DeltaSkipReason.PATCH_NOT_BOUND, skip(releaseOverride = release(patchAsset = null)))
        assertEquals(DeltaSkipReason.PATCH_NOT_BOUND, skip(sums = checksums(includePatch = false)))
        assertEquals(DeltaSkipReason.PATCH_NOT_BOUND, skip(sums = checksums(patchHash = "9".repeat(64))))
        assertEquals(
            DeltaSkipReason.PATCH_OVERSIZED,
            withBase { file ->
                val manifest = manifest(patchBytes = 900L)
                val decision = UpdateDeltaPolicy.decide(
                    enabled = true,
                    release = release(patchAsset = ReleaseAsset(patchName, 900, "https://example.test/$patchName")),
                    checksums = checksums(),
                    manifestText = manifestText(manifest),
                    installed = installed(file),
                    installedApkSha256 = baseSha,
                )
                (decision as DeltaDecision.Skip).reason
            },
        )
    }

    @Test
    fun refusesWhenTheInstalledBaseDisagrees() {
        assertEquals(DeltaSkipReason.BASE_UNAVAILABLE, skip(installedInfo = { installed(it).also { info -> info.apkFile?.delete() } }))
        assertEquals(DeltaSkipReason.BASE_HASH_MISMATCH, skip(baseSha = "9".repeat(64)))
        assertEquals(DeltaSkipReason.BASE_HASH_MISMATCH, skip(baseSha = null))
        assertEquals(DeltaSkipReason.BASE_IDENTITY_MISMATCH, skip(installedInfo = { installed(it, versionCode = 17L) }))
        assertEquals(DeltaSkipReason.BASE_IDENTITY_MISMATCH, skip(installedInfo = { installed(it, sizeBytes = 800L) }))
        assertEquals(
            DeltaSkipReason.BASE_SIGNER_MISMATCH,
            skip(installedInfo = { installed(it, signers = setOf("9".repeat(64))) }),
        )
        assertEquals(DeltaSkipReason.SPLIT_APK, skip(installedInfo = { installed(it, split = true) }))
    }

    @Test
    fun refusesWhenTargetIdentityCannotBeInstalled() = withBase { file ->
        val manifest = manifest().copy(
            target = manifest().target.copy(minSdk = 99),
        )
        val decision = UpdateDeltaPolicy.decide(
            enabled = true,
            release = release(),
            checksums = checksums(),
            manifestText = manifestText(manifest),
            installed = installed(file),
            installedApkSha256 = baseSha,
        )
        assertEquals(DeltaSkipReason.TARGET_IDENTITY_UNSUPPORTED, (decision as DeltaDecision.Skip).reason)
    }
}
