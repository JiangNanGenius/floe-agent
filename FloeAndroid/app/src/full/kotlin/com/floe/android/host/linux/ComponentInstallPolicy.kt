// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

/**
 * Identity facts read from the staged component archive and from the
 * installed Core app. Values are public certificate digests and platform
 * package facts only — never paths, commands or exception text.
 */
internal data class ComponentIdentity(
    val packageName: String,
    val longVersionCode: Long,
    val signerSha256: Set<String>,
)

/** Exactly one refusal per existing preparation check boundary. */
internal enum class ComponentInstallRejection {
    /** Private staging directory could not be created/validated. */
    STAGING_UNAVAILABLE,
    /** Embedded asset (hash sidecar or package stream) missing/unreadable. */
    ASSET_UNAVAILABLE,
    /** An embedded component could not be copied into private staging. */
    COPY_FAILED,
    /** Staged bytes exceeded the bounded copy budget. */
    SIZE_EXCEEDED,
    /** Staged bytes do not match the embedded hash sidecar. */
    DIGEST_MISMATCH,
    /** PackageManager could not parse the staged archive at all. */
    ARCHIVE_UNREADABLE,
    /** Parsed package name is not this channel's runtime component. */
    PACKAGE_MISMATCH,
    /** Component build differs from the installed Core build. */
    VERSION_MISMATCH,
    /** No signing identity could be proven for archive or Core. */
    CERTIFICATE_UNAVAILABLE,
    /** Archive and Core signing identities differ. */
    IDENTITY_MISMATCH,
    /** PackageInstaller session could not be created, written or committed. */
    SESSION_FAILED,
}

/**
 * Pure install-admission policy for the bundled Linux runtime component.
 * Hash alone is never trust: the staged archive must be this channel's exact
 * runtime package, the SAME build as the installed Core app, and signed by
 * the SAME certificate set as the installed Core. Every refusal maps to one
 * closed diagnostic (finite code + component stage), so the user-facing
 * recovery can name the single failed check. Fail-closed throughout: a
 * missing/unreadable fact is a refusal, never a fallback, downgrade or
 * unsigned acceptance.
 */
internal object ComponentInstallPolicy {
    const val STAGE = "component"

    fun rejectIdentity(
        candidate: ComponentIdentity?,
        expectedPackage: String,
        ownVersionCode: Long,
        ownSignerSha256: Set<String>,
    ): ComponentInstallRejection? {
        if (candidate == null) return ComponentInstallRejection.ARCHIVE_UNREADABLE
        if (candidate.packageName != expectedPackage) return ComponentInstallRejection.PACKAGE_MISMATCH
        if (candidate.longVersionCode != ownVersionCode) return ComponentInstallRejection.VERSION_MISMATCH
        if (candidate.signerSha256.isEmpty() || ownSignerSha256.isEmpty()) {
            return ComponentInstallRejection.CERTIFICATE_UNAVAILABLE
        }
        if (candidate.signerSha256 != ownSignerSha256) return ComponentInstallRejection.IDENTITY_MISMATCH
        return null
    }

    fun diagnostic(rejection: ComponentInstallRejection): LinuxSetupDiagnostic =
        LinuxSetupDiagnostic.fromFields(code(rejection), STAGE, type(rejection))

    /** Preserve cancellation and existing actionable causes without persisting their text. */
    fun failure(rejection: ComponentInstallRejection, cause: Exception): Exception {
        if (cause is kotlinx.coroutines.CancellationException || cause is LinuxSetupException) return cause
        val original = LinuxSetupDiagnostic.fromThrowable(cause, STAGE)
        if (original.category != "unknown") return cause
        return LinuxSetupException(diagnostic(rejection).copy(exceptionType = original.exceptionType), cause)
    }

    private fun code(rejection: ComponentInstallRejection): String = when (rejection) {
        ComponentInstallRejection.STAGING_UNAVAILABLE -> "COMPONENT_STAGING_UNAVAILABLE"
        ComponentInstallRejection.ASSET_UNAVAILABLE -> "COMPONENT_ASSET_UNAVAILABLE"
        ComponentInstallRejection.COPY_FAILED -> "COMPONENT_COPY_FAILED"
        ComponentInstallRejection.SIZE_EXCEEDED -> "COMPONENT_SIZE_EXCEEDED"
        ComponentInstallRejection.DIGEST_MISMATCH -> "COMPONENT_DIGEST_MISMATCH"
        ComponentInstallRejection.ARCHIVE_UNREADABLE -> "COMPONENT_ARCHIVE_UNREADABLE"
        ComponentInstallRejection.PACKAGE_MISMATCH -> "COMPONENT_PACKAGE_MISMATCH"
        ComponentInstallRejection.VERSION_MISMATCH -> "COMPONENT_VERSION_MISMATCH"
        ComponentInstallRejection.CERTIFICATE_UNAVAILABLE -> "COMPONENT_CERTIFICATE_UNAVAILABLE"
        ComponentInstallRejection.IDENTITY_MISMATCH -> "COMPONENT_IDENTITY_MISMATCH"
        ComponentInstallRejection.SESSION_FAILED -> "COMPONENT_SESSION_FAILED"
    }

    /** Closed cause family; stable across releases for report correlation. */
    private fun type(rejection: ComponentInstallRejection): String = when (rejection) {
        ComponentInstallRejection.STAGING_UNAVAILABLE,
        ComponentInstallRejection.ASSET_UNAVAILABLE,
        ComponentInstallRejection.COPY_FAILED,
        ComponentInstallRejection.SIZE_EXCEEDED,
        ComponentInstallRejection.DIGEST_MISMATCH,
        ComponentInstallRejection.ARCHIVE_UNREADABLE,
        ComponentInstallRejection.PACKAGE_MISMATCH,
        ComponentInstallRejection.VERSION_MISMATCH -> "ComponentPreparation"
        ComponentInstallRejection.CERTIFICATE_UNAVAILABLE,
        ComponentInstallRejection.IDENTITY_MISMATCH -> "ComponentIdentity"
        ComponentInstallRejection.SESSION_FAILED -> "ComponentSession"
    }
}
