// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

/**
 * Identity facts read from one APK archive and from the installed app.
 * The digest is of the verified signing certificate's public bytes only —
 * never a private key, password or credential.
 */
internal data class ApkIdentity(
    val packageName: String,
    val longVersionCode: Long,
    val signerSha256: Set<String>,
    val minSdk: Int,
    val hasArm64Libraries: Boolean,
    val hasForeignAbiLibraries: Boolean,
)

internal enum class ApkRejection {
    NOT_AN_APK,
    PACKAGE_MISMATCH,
    VERSION_NOT_HIGHER,
    SIGNER_MISMATCH,
    ABI_INCOMPATIBLE,
    MIN_SDK_TOO_HIGH,
}

/**
 * Pure install-admission policy. A hash alone is never trust: the candidate
 * must be the same package, a strictly higher real versionCode, signed by the
 * SAME certificate set as the installed app, ABI-compatible and above the
 * device's minimum SDK. The tag number is never compared with versionCode.
 */
internal object ApkValidationPolicy {
    fun rejectReason(candidate: ApkIdentity, installed: ApkIdentity, sdkInt: Int): ApkRejection? {
        if (candidate.packageName != installed.packageName) return ApkRejection.PACKAGE_MISMATCH
        if (candidate.longVersionCode <= installed.longVersionCode) return ApkRejection.VERSION_NOT_HIGHER
        if (candidate.signerSha256.isEmpty() || installed.signerSha256.isEmpty()) {
            return ApkRejection.SIGNER_MISMATCH
        }
        if (candidate.signerSha256 != installed.signerSha256) return ApkRejection.SIGNER_MISMATCH
        if (candidate.hasForeignAbiLibraries && !candidate.hasArm64Libraries) {
            return ApkRejection.ABI_INCOMPATIBLE
        }
        if (candidate.minSdk > 0 && candidate.minSdk > sdkInt) return ApkRejection.MIN_SDK_TOO_HIGH
        return null
    }
}

/** Reads [ApkIdentity] from a staged APK file and from the installed app. */
internal class ApkIdentityReader(private val context: Context) {

    fun installed(): ApkIdentity? = runCatching {
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_SIGNING_CERTIFICATES,
        )
        ApkIdentity(
            packageName = info.packageName,
            longVersionCode = info.longVersionCode,
            signerSha256 = certificateDigests(info.signingInfo?.apkContentsSigners),
            minSdk = 0,
            hasArm64Libraries = true,
            hasForeignAbiLibraries = false,
        )
    }.getOrNull()

    fun read(apk: File): ApkIdentity? = runCatching {
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageArchiveInfo(
            apk.absolutePath,
            PackageManager.GET_SIGNING_CERTIFICATES,
        ) ?: return null
        val abis = archiveAbis(apk)
        ApkIdentity(
            packageName = info.packageName ?: return null,
            longVersionCode = info.longVersionCode,
            signerSha256 = certificateDigests(info.signingInfo?.apkContentsSigners),
            minSdk = info.applicationInfo?.minSdkVersion ?: 0,
            hasArm64Libraries = abis.contains("arm64-v8a"),
            hasForeignAbiLibraries = abis.any { it != "arm64-v8a" },
        )
    }.getOrNull()

    /** Device-independent admission check used before any install commit. */
    fun rejectionFor(apk: File): ApkRejection? {
        val candidate = read(apk) ?: return ApkRejection.NOT_AN_APK
        val installed = installed() ?: return ApkRejection.NOT_AN_APK
        return ApkValidationPolicy.rejectReason(candidate, installed, Build.VERSION.SDK_INT)
    }

    private fun certificateDigests(signatures: Array<android.content.pm.Signature>?): Set<String> {
        if (signatures == null) return emptySet()
        return signatures.mapTo(LinkedHashSet()) { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it) }
        }
    }

    private fun archiveAbis(apk: File): Set<String> {
        val abis = LinkedHashSet<String>()
        runCatching {
            ZipFile(apk).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val name = entries.nextElement().name
                    if (!name.startsWith("lib/")) continue
                    val rest = name.removePrefix("lib/")
                    val slash = rest.indexOf('/')
                    if (slash <= 0) continue
                    abis += rest.substring(0, slash)
                }
            }
        }
        return abis
    }
}
