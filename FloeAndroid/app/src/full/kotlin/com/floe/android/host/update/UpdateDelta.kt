// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Full-flavor APK delta (FloePatch v1) release contract.
 *
 * The delta is an ADDITIONAL release artifact produced by
 * `scripts/update/produce-update-delta.py` from two exact signed Full APKs.
 * It never replaces the full APK or its checksum entry:
 *
 *  * `update-delta-v1.json` (the manifest) and the `.delta` patch are both
 *    listed in the release's own `SHA256SUMS`, so their bytes are bound by the
 *    same release-integrity chain as the APK;
 *  * the manifest's target hash must equal the release's full-APK checksum
 *    entry, so a patch can only ever reconstruct the exact published APK;
 *  * the installed base APK's own SHA-256, size, version, package and signer
 *    set must match the manifest before a single patch byte is applied.
 *
 * Everything here is framework-free so the full-flavor JVM tests can drive the
 * parser and the eligibility policy directly.
 */
internal data class DeltaBaseIdentity(
    val apkName: String,
    val sha256: String,
    val sizeBytes: Long,
    val versionName: String,
    val versionCode: Long,
)

internal data class DeltaTargetIdentity(
    val apkName: String,
    val sha256: String,
    val sizeBytes: Long,
    val versionName: String,
    val versionCode: Long,
    val minSdk: Int,
    val abis: List<String>,
    val signerSha256: List<String>,
)

internal data class DeltaPatch(
    val format: String,
    val version: Int,
    val assetName: String,
    val sizeBytes: Long,
    val sha256: String,
)

internal data class UpdateDeltaManifest(
    val schema: String,
    val channel: String,
    val packageName: String,
    val releaseTag: String,
    val base: DeltaBaseIdentity,
    val target: DeltaTargetIdentity,
    val patch: DeltaPatch,
)

/** The installed app's APK facts used to admit (or refuse) a delta. */
internal data class InstalledBaseInfo(
    val apkFile: File?,
    val apkSizeBytes: Long,
    val packageName: String,
    val versionName: String,
    val versionCode: Long,
    val signerSha256: Set<String>,
    val hasSplitApks: Boolean,
    val sdkInt: Int,
)

/**
 * Reads the installed APK facts. The implementation lives in the composition
 * root (Android types), while the policy and the applier stay framework-free.
 * Returning null means "cannot prove the base", which disables the delta.
 */
internal fun interface InstalledBaseProvider {
    fun read(): InstalledBaseInfo?
}

internal object UpdateDeltaFormat {
    const val SCHEMA = "floe.android.update.delta/1"
    const val CHANNEL = "full-arm64-v8a"
    const val MANIFEST_ASSET = "update-delta-v1.json"
    const val PATCH_FORMAT = "floepatch"
    const val PATCH_VERSION = 1
    const val MAX_MANIFEST_BYTES = 64L * 1024L
    const val MAX_PATCH_BYTES = AndroidReleaseFeed.MAX_APK_BYTES
    const val MAX_NAME_CHARS = 150

    /** 80% of the full APK: below that a patch is offered, above it is not. */
    const val MAX_BENEFIT_PERCENT = 80

    fun isSafeAssetName(name: String): Boolean =
        name.isNotEmpty() &&
            name.length <= MAX_NAME_CHARS &&
            name != AndroidReleaseFeed.CHECKSUMS_NAME &&
            name != MANIFEST_ASSET &&
            name.none { it == '/' || it == '\\' || it.isWhitespace() } &&
            name.all { it.isLetterOrDigit() || it == '.' || it == '_' || it == '-' }
}

/** Strict, bounded manifest parser (no lenient repair of a release document). */
internal object UpdateDeltaManifestParser {
    private val sha256 = Regex("[0-9a-f]{64}")

    fun parse(text: String): UpdateDeltaManifest? {
        if (text.isBlank() || text.length > UpdateDeltaFormat.MAX_MANIFEST_BYTES) return null
        val root = runCatching { Json.parseToJsonElement(text) }.getOrNull() as? JsonObject ?: return null
        fun obj(key: String): JsonObject? = root[key] as? JsonObject
        fun JsonObject.string(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

        fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.longOrNull
        fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull

        val schema = root.string("schema") ?: return null
        val channel = root.string("channel") ?: return null
        val packageName = root.string("package") ?: return null
        val releaseTag = root.string("releaseTag") ?: return null
        val base = run {
            val node = obj("base") ?: return null
            val name = node.string("apkName") ?: return null
            val hash = node.string("sha256") ?: return null
            val size = node.long("sizeBytes") ?: return null
            val versionName = node.string("versionName") ?: return null
            val versionCode = node.long("versionCode") ?: return null
            if (!isSafeName(name) || !sha256.matches(hash)) return null
            if (size !in 1..AndroidReleaseFeed.MAX_APK_BYTES) return null
            if (versionName.isEmpty() || versionName.length > 64 || versionCode <= 0L) return null
            DeltaBaseIdentity(name, hash, size, versionName, versionCode)
        }
        val target = run {
            val node = obj("target") ?: return null
            val name = node.string("apkName") ?: return null
            val hash = node.string("sha256") ?: return null
            val size = node.long("sizeBytes") ?: return null
            val versionName = node.string("versionName") ?: return null
            val versionCode = node.long("versionCode") ?: return null
            val minSdk = node.int("minSdk") ?: return null
            val abis = (node["abis"] as? JsonArray)?.mapNotNull {
                (it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content
            } ?: return null
            val signers = (node["signerSha256"] as? JsonArray)?.mapNotNull {
                (it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content
            } ?: return null
            if (!isSafeName(name) || !sha256.matches(hash)) return null
            if (size !in 1..AndroidReleaseFeed.MAX_APK_BYTES) return null
            if (versionName.isEmpty() || versionName.length > 64 || versionCode <= 0L) return null
            if (minSdk < 0 || minSdk > 100) return null
            if (abis.isEmpty() || abis.size > 8 || abis.any { it.length > 24 }) return null
            if (signers.isEmpty() || signers.size > 8 || signers.any { !sha256.matches(it) }) return null
            DeltaTargetIdentity(name, hash, size, versionName, versionCode, minSdk, abis, signers)
        }
        val patch = run {
            val node = obj("patch") ?: return null
            val format = node.string("format") ?: return null
            val version = node.int("version") ?: return null
            val assetName = node.string("assetName") ?: return null
            val size = node.long("sizeBytes") ?: return null
            val hash = node.string("sha256") ?: return null
            if (!UpdateDeltaFormat.isSafeAssetName(assetName)) return null
            if (size !in 1..UpdateDeltaFormat.MAX_PATCH_BYTES) return null
            if (!sha256.matches(hash)) return null
            DeltaPatch(format, version, assetName, size, hash)
        }
        if (schema != UpdateDeltaFormat.SCHEMA) return null
        if (channel.length > 40 || packageName.length > 200 || releaseTag.length > 96) return null
        return UpdateDeltaManifest(schema, channel, packageName, releaseTag, base, target, patch)
    }

    private fun isSafeName(name: String): Boolean =
        name.isNotEmpty() && name.length <= UpdateDeltaFormat.MAX_NAME_CHARS &&
            name.none { it == '/' || it == '\\' || it.isWhitespace() }
}

internal enum class DeltaSkipReason {
    DISABLED,
    NO_MANIFEST_ASSET,
    MANIFEST_INVALID,
    RELEASE_MISMATCH,
    TARGET_NOT_BOUND,
    PATCH_NOT_BOUND,
    PATCH_OVERSIZED,
    NOT_BENEFICIAL,
    BASE_UNAVAILABLE,
    BASE_HASH_MISMATCH,
    BASE_IDENTITY_MISMATCH,
    BASE_SIGNER_MISMATCH,
    SPLIT_APK,
    TARGET_IDENTITY_UNSUPPORTED,
}

internal sealed interface DeltaDecision {
    data class Use(val manifest: UpdateDeltaManifest, val patchAsset: ReleaseAsset) : DeltaDecision
    data class Skip(val reason: DeltaSkipReason) : DeltaDecision
}

/**
 * Pure delta admission. Every input that decides trust is explicit: the
 * release (tag, full APK asset, all assets), the release's own checksum map,
 * the installed base facts and its actually-computed SHA-256. A missing or
 * contradictory fact is a refusal, never a guess.
 */
internal object UpdateDeltaPolicy {

    fun decide(
        enabled: Boolean,
        release: AndroidRelease,
        checksums: Map<String, String>,
        manifestText: String?,
        installed: InstalledBaseInfo,
        installedApkSha256: String?,
    ): DeltaDecision {
        if (!enabled) return DeltaDecision.Skip(DeltaSkipReason.DISABLED)
        val manifestAsset = release.delta ?: return DeltaDecision.Skip(DeltaSkipReason.NO_MANIFEST_ASSET)
        val manifest = UpdateDeltaManifestParser.parse(manifestText.orEmpty())
            ?: return DeltaDecision.Skip(DeltaSkipReason.MANIFEST_INVALID)

        if (manifest.channel != UpdateDeltaFormat.CHANNEL) return DeltaDecision.Skip(DeltaSkipReason.RELEASE_MISMATCH)
        if (manifest.packageName != installed.packageName) return DeltaDecision.Skip(DeltaSkipReason.RELEASE_MISMATCH)
        if (manifest.releaseTag != release.tag) return DeltaDecision.Skip(DeltaSkipReason.RELEASE_MISMATCH)
        if (manifest.target.apkName != release.apk.name ||
            manifest.target.versionName != release.version.toString() ||
            manifest.target.sizeBytes != release.apk.sizeBytes
        ) {
            return DeltaDecision.Skip(DeltaSkipReason.RELEASE_MISMATCH)
        }
        // The manifest is itself a release asset whose bytes are bound by the
        // release's own SHA256SUMS; the downloader re-verifies those bytes.
        if (checksums[manifestAsset.name].isNullOrEmpty()) {
            return DeltaDecision.Skip(DeltaSkipReason.MANIFEST_INVALID)
        }
        // The target hash must be the release's own full-APK hash.
        val apkChecksum = checksums[release.apk.name]
            ?: return DeltaDecision.Skip(DeltaSkipReason.TARGET_NOT_BOUND)
        if (!apkChecksum.equals(manifest.target.sha256, ignoreCase = true)) {
            return DeltaDecision.Skip(DeltaSkipReason.TARGET_NOT_BOUND)
        }

        if (manifest.patch.format != UpdateDeltaFormat.PATCH_FORMAT ||
            manifest.patch.version != UpdateDeltaFormat.PATCH_VERSION
        ) {
            return DeltaDecision.Skip(DeltaSkipReason.PATCH_NOT_BOUND)
        }
        val patchAsset = release.assets[manifest.patch.assetName]
            ?: return DeltaDecision.Skip(DeltaSkipReason.PATCH_NOT_BOUND)
        if (patchAsset.sizeBytes != manifest.patch.sizeBytes) {
            return DeltaDecision.Skip(DeltaSkipReason.PATCH_NOT_BOUND)
        }
        if (!checksums[manifest.patch.assetName].orEmpty().equals(manifest.patch.sha256, ignoreCase = true)) {
            return DeltaDecision.Skip(DeltaSkipReason.PATCH_NOT_BOUND)
        }
        if (manifest.patch.sizeBytes > manifest.target.sizeBytes / 100L * UpdateDeltaFormat.MAX_BENEFIT_PERCENT) {
            return DeltaDecision.Skip(DeltaSkipReason.PATCH_OVERSIZED)
        }
        if (manifest.patch.sizeBytes >= manifest.target.sizeBytes) {
            return DeltaDecision.Skip(DeltaSkipReason.NOT_BENEFICIAL)
        }

        if (installed.hasSplitApks) return DeltaDecision.Skip(DeltaSkipReason.SPLIT_APK)
        if (installed.apkFile == null || !installed.apkFile.isFile || installed.apkSizeBytes <= 0L) {
            return DeltaDecision.Skip(DeltaSkipReason.BASE_UNAVAILABLE)
        }
        if (installed.packageName != manifest.packageName) {
            return DeltaDecision.Skip(DeltaSkipReason.BASE_IDENTITY_MISMATCH)
        }
        if (installed.versionCode != manifest.base.versionCode ||
            installed.versionName != manifest.base.versionName ||
            installed.apkSizeBytes != manifest.base.sizeBytes
        ) {
            return DeltaDecision.Skip(DeltaSkipReason.BASE_IDENTITY_MISMATCH)
        }
        // The installed signer set is the authority the system installer will
        // enforce; the delta target must declare exactly that set.
        if (installed.signerSha256.isEmpty() ||
            installed.signerSha256 != manifest.target.signerSha256.toSet()
        ) {
            return DeltaDecision.Skip(DeltaSkipReason.BASE_SIGNER_MISMATCH)
        }
        if ("arm64-v8a" !in manifest.target.abis) {
            return DeltaDecision.Skip(DeltaSkipReason.TARGET_IDENTITY_UNSUPPORTED)
        }
        if (manifest.target.minSdk > installed.sdkInt) {
            return DeltaDecision.Skip(DeltaSkipReason.TARGET_IDENTITY_UNSUPPORTED)
        }
        if (manifest.target.versionCode <= installed.versionCode) {
            return DeltaDecision.Skip(DeltaSkipReason.BASE_IDENTITY_MISMATCH)
        }
        // A wrong/changed base must discard the whole delta before any write.
        if (installedApkSha256 == null ||
            !installedApkSha256.equals(manifest.base.sha256, ignoreCase = true)
        ) {
            return DeltaDecision.Skip(DeltaSkipReason.BASE_HASH_MISMATCH)
        }
        return DeltaDecision.Use(manifest, patchAsset)
    }
}
