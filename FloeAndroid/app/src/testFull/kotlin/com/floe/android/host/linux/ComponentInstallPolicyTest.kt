// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Bundled runtime-component admission policy: the staged archive must be this
 * channel's exact runtime package, the SAME build as the installed Core app
 * and signed by the SAME certificate set. A missing fact is a refusal, never
 * a fallback or unsigned acceptance.
 */
class ComponentInstallPolicyTest {
    @Test fun callbacksFromOtherSessionsOrAppBuildsCannotReplaceCurrentConfirmation() {
        assertTrue(ComponentInstallPolicy.acceptsCallback(19, 97, 19, 97))
        assertFalse(ComponentInstallPolicy.acceptsCallback(19, 97, 18, 97))
        assertFalse(ComponentInstallPolicy.acceptsCallback(-1, 97, 19, 97))
        assertFalse(ComponentInstallPolicy.acceptsCallback(19, 96, 19, 97))
        assertFalse(ComponentInstallPolicy.acceptsCallback(19, 0, 19, 0))
    }

    private fun identity(
        packageName: String = "com.floe.agent.runtime.full",
        versionCode: Long = 87L,
        signers: Set<String> = setOf("a".repeat(64)),
    ) = ComponentIdentity(packageName, versionCode, signers)

    private fun reject(candidate: ComponentIdentity?, own: ComponentIdentity = identity()) =
        ComponentInstallPolicy.rejectIdentity(
            candidate = candidate,
            expectedPackage = "com.floe.agent.runtime.full",
            ownVersionCode = own.longVersionCode,
            ownSignerSha256 = own.signerSha256,
        )

    @Test fun acceptsExactMatchingComponent() {
        assertNull(reject(identity()))
        // Multiple signers are acceptable only when both sides agree exactly.
        assertNull(reject(identity(signers = setOf("a".repeat(64), "b".repeat(64))),
            own = identity(signers = setOf("b".repeat(64), "a".repeat(64)))))
    }

    @Test fun unparsableArchiveRefuses() {
        assertEquals(ComponentInstallRejection.ARCHIVE_UNREADABLE, reject(null))
    }

    @Test fun wrongPackageRefuses() {
        assertEquals(ComponentInstallRejection.PACKAGE_MISMATCH,
            reject(identity(packageName = "com.floe.agent.runtime")))
    }

    @Test fun differentBuildRefuses() {
        assertEquals(ComponentInstallRejection.VERSION_MISMATCH, reject(identity(versionCode = 88L)))
        assertEquals(ComponentInstallRejection.VERSION_MISMATCH, reject(identity(versionCode = 86L)))
    }

    @Test fun absentIdentityRefusesEvenWhenEverythingElseMatches() {
        assertEquals(ComponentInstallRejection.CERTIFICATE_UNAVAILABLE,
            reject(identity(signers = emptySet())))
        assertEquals(ComponentInstallRejection.CERTIFICATE_UNAVAILABLE,
            reject(identity(), own = identity(signers = emptySet())))
    }

    @Test fun foreignSignerRefuses() {
        assertEquals(ComponentInstallRejection.IDENTITY_MISMATCH,
            reject(identity(signers = setOf("c".repeat(64)))))
        // A strict superset is still a different identity.
        assertEquals(ComponentInstallRejection.IDENTITY_MISMATCH,
            reject(identity(signers = setOf("a".repeat(64), "b".repeat(64)))))
    }

    @Test fun everyRejectionMapsToClosedComponentDiagnostic() {
        val expectedCodes = mapOf(
            ComponentInstallRejection.STAGING_UNAVAILABLE to "storage",
            ComponentInstallRejection.ASSET_UNAVAILABLE to "component",
            ComponentInstallRejection.COPY_FAILED to "component",
            ComponentInstallRejection.SIZE_EXCEEDED to "component",
            ComponentInstallRejection.DIGEST_MISMATCH to "component",
            ComponentInstallRejection.ARCHIVE_UNREADABLE to "component",
            ComponentInstallRejection.PACKAGE_MISMATCH to "component",
            ComponentInstallRejection.VERSION_MISMATCH to "component",
            ComponentInstallRejection.CERTIFICATE_UNAVAILABLE to "component",
            ComponentInstallRejection.IDENTITY_MISMATCH to "component",
            ComponentInstallRejection.SESSION_FAILED to "component",
        )
        for ((rejection, category) in expectedCodes) {
            val diagnostic = ComponentInstallPolicy.diagnostic(rejection)
            assertEquals("component", diagnostic.stage)
            assertEquals(category, diagnostic.category)
            assertEquals(diagnostic.code, LinuxSetupDiagnostic.fromFields(diagnostic.code, diagnostic.stage, diagnostic.exceptionType).code)
        }
    }

    @Test fun preservesCancellationAndPermissionFailures() {
        val cancelled = kotlinx.coroutines.CancellationException("cancelled")
        assertSame(cancelled, ComponentInstallPolicy.failure(ComponentInstallRejection.SESSION_FAILED, cancelled))
        val denied = SecurityException("private permission context")
        assertSame(denied, ComponentInstallPolicy.failure(ComponentInstallRejection.SESSION_FAILED, denied))
        assertEquals("permission", LinuxSetupDiagnostic.fromThrowable(denied, "component").category)
    }

    @Test fun retainsCopyCauseButReportsOnlyClosedFields() {
        val cause = java.io.IOException("private/file/path and credential context")
        val failure = ComponentInstallPolicy.failure(ComponentInstallRejection.COPY_FAILED, cause)
        assertSame(cause, failure.cause)
        val report = LinuxSetupDiagnostic.fromThrowable(failure, "component")
        assertEquals("COMPONENT_COPY_FAILED", report.code)
        assertEquals("IOException", report.exceptionType)
        assertFalse(report.toString().contains("private/file"))
        assertFalse(report.toString().contains("credential"))
    }
}
