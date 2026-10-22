// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import android.content.Context
import android.content.pm.PackageManager

/**
 * Device-side [PackageMetadataReader]. This is the only place in the package
 * that touches `PackageManager`; it reports raw facts and never judges them.
 *
 * Security notes that shape this implementation:
 * - Digests are taken over the full DER certificate bytes of the APK signing
 *   certificates. Self-signed debug keys are as valid as release keys here: the
 *   allowlist (supplied by Main) carries the expected digest, whatever it is.
 * - A query failure is `null` (fail closed); it is never an empty list and never
 *   a previously cached value.
 * - [packagesForUid] enforces Main's dedicated-UID decision: a runtime UID that
 *   is shared with any other package is refused by the validator.
 */
class AndroidPackageMetadataReader(context: Context) : PackageMetadataReader {

    private val manager: PackageManager = context.applicationContext.packageManager

    override fun read(packageName: String): PackageMetadata? = try {
        val info = manager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        val certs = info.signingInfo?.apkContentsSigners?.toList().orEmpty()
        if (certs.isEmpty()) null else PackageMetadata(
            packageName = packageName,
            uid = manager.getPackageUid(packageName, 0),
            signatureSha256 = certs.map { RuntimeUidBoundary.digestOf(it.toByteArray()) },
        )
    } catch (_: Exception) {
        null
    }

    override fun packagesForUid(uid: Int): List<String>? =
        try {
            manager.getPackagesForUid(uid)?.toList()
        } catch (_: Exception) {
            null
        }
}
