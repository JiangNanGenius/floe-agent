// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Install admission policy: hash alone is never trust. The staged APK must be
 * this same package, a strictly higher real versionCode, signed by the same
 * certificate set as the installed app, ABI compatible and above the device
 * minimum SDK.
 */
class ApkValidationPolicyTest {

    private fun identity(
        packageName: String = "com.floe.agent.full",
        versionCode: Long = 16L,
        signer: Set<String> = setOf("b".repeat(64)),
        minSdk: Int = 28,
        hasArm64: Boolean = true,
        hasForeignAbis: Boolean = false,
    ) = ApkIdentity(
        packageName = packageName,
        longVersionCode = versionCode,
        signerSha256 = signer,
        minSdk = minSdk,
        hasArm64Libraries = hasArm64,
        hasForeignAbiLibraries = hasForeignAbis,
    )

    private val installed = identity(versionCode = 15L)

    @Test
    fun acceptsSamePackageHigherVersionSameSigner() {
        assertNull(ApkValidationPolicy.rejectReason(identity(versionCode = 16L), installed, sdkInt = 37))
    }

    @Test
    fun rejectsDifferentPackage() {
        assertEquals(
            ApkRejection.PACKAGE_MISMATCH,
            ApkValidationPolicy.rejectReason(
                identity(packageName = "com.floe.agent", versionCode = 16L),
                installed,
                sdkInt = 37,
            ),
        )
    }

    @Test
    fun rejectsEqualOrLowerVersionCode() {
        assertEquals(
            ApkRejection.VERSION_NOT_HIGHER,
            ApkValidationPolicy.rejectReason(identity(versionCode = 15L), installed, sdkInt = 37),
        )
        assertEquals(
            ApkRejection.VERSION_NOT_HIGHER,
            ApkValidationPolicy.rejectReason(identity(versionCode = 14L), installed, sdkInt = 37),
        )
    }

    @Test
    fun rejectsDifferentSigner() {
        assertEquals(
            ApkRejection.SIGNER_MISMATCH,
            ApkValidationPolicy.rejectReason(
                identity(versionCode = 16L, signer = setOf("c".repeat(64))),
                installed,
                sdkInt = 37,
            ),
        )
    }

    @Test
    fun rejectsMissingSignerOnEitherSide() {
        assertEquals(
            ApkRejection.SIGNER_MISMATCH,
            ApkValidationPolicy.rejectReason(
                identity(versionCode = 16L, signer = emptySet()),
                installed,
                sdkInt = 37,
            ),
        )
        assertEquals(
            ApkRejection.SIGNER_MISMATCH,
            ApkValidationPolicy.rejectReason(
                identity(versionCode = 16L),
                installed.copy(signerSha256 = emptySet()),
                sdkInt = 37,
            ),
        )
    }

    @Test
    fun rejectsForeignAbiOnlyPackage() {
        assertEquals(
            ApkRejection.ABI_INCOMPATIBLE,
            ApkValidationPolicy.rejectReason(
                identity(versionCode = 16L, hasArm64 = false, hasForeignAbis = true),
                installed,
                sdkInt = 37,
            ),
        )
        assertNull(
            ApkValidationPolicy.rejectReason(
                identity(versionCode = 16L, hasArm64 = true, hasForeignAbis = false),
                installed,
                sdkInt = 37,
            ),
        )
    }

    @Test
    fun rejectsMinSdkAboveDevice() {
        assertEquals(
            ApkRejection.MIN_SDK_TOO_HIGH,
            ApkValidationPolicy.rejectReason(
                identity(versionCode = 16L, minSdk = 34),
                installed,
                sdkInt = 33,
            ),
        )
        assertNull(
            ApkValidationPolicy.rejectReason(
                identity(versionCode = 16L, minSdk = 0),
                installed,
                sdkInt = 33,
            ),
        )
    }
}
