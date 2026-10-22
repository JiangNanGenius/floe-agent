// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import java.security.MessageDigest

/**
 * Package metadata this supervision needs, reduced to exactly the fields that
 * carry the credential/UID boundary: the package name, its Android UID and the
 * SHA-256 digests of its signing certificates. Anything else (paths, labels,
 * model-supplied strings) is *not* evidence of a boundary.
 */
data class PackageMetadata(
    val packageName: String,
    val uid: Int,
    val signatureSha256: List<String>,
) {
    init {
        require(packageName.isNotBlank()) { "packageName must be explicit" }
        require(uid >= 0) { "uid must be resolved" }
        require(signatureSha256.isNotEmpty()) { "at least one signing certificate digest is required" }
    }
}

/**
 * Reader seam for package metadata. Production implements it with
 * [AndroidPackageMetadataReader]; JVM fixtures implement it with a map. A
 * missing or unreadable package must be reported as `null` (fail closed), never
 * as a guessed value.
 */
interface PackageMetadataReader {
    fun read(packageName: String): PackageMetadata?

    /**
     * Reverse mapping used for the dedicated-UID rule. `null` means unresolved
     * and must fail closed; an empty list means the UID really has no package.
     */
    fun packagesForUid(uid: Int): List<String>?
}

/** Result of the trusted-boundary validation. Never partially accepted. */
sealed class BoundaryCheck {
    /** Fully validated boundary; the only way to obtain a [RuntimeUidBoundary]. */
    data class Accepted(val boundary: RuntimeUidBoundary) : BoundaryCheck()

    /** Explicit, aggregated refusal reasons. The caller must not start supervision. */
    data class Rejected(val reasons: List<String>) : BoundaryCheck() {
        init { require(reasons.isNotEmpty()) { "a rejection must state why" } }

        val reasonText: String get() = reasons.joinToString("; ")
    }
}

/**
 * Proof that *this* process runs as the allowlisted runtime UID of an
 * allowlisted runtime package, and that this UID is distinct from the exact
 * credential-bearing core App UID.
 *
 * Trust contract (enforced by a constructor that is private to validation):
 * - The only factory is [RuntimeUidBoundary.validate], which requires a real
 *   [PackageMetadataReader] result for BOTH packages, the exact expected
 *   certificate digests, a self UID equal to the runtime package UID, a self UID
 *   different from the core package UID, and a runtime UID dedicated to the
 *   runtime package (Main's RuntimePeerVerifier rule, re-proved here so this
 *   package never depends on the not-yet-wired IPC module).
 * - A caller cannot construct one from a path, a label, a package name alone or
 *   a model-provided description; there is no copy/deserialization form.
 * - [RuntimeWorkSupervisor] re-checks [selfPid] and [runtimeUid] against live
 *   kernel facts on every call, so a stale or transplanted proof cannot be reused.
 *
 * Bytecode caveat, stated for review rather than hidden: Kotlin emits a synthetic
 * `DefaultConstructorMarker` constructor for a class built by its own companion,
 * so a caller that hand-assembles JVM bytecode (or uses `setAccessible`) can still
 * reach an instance. That is why the effective control is NOT the type alone:
 * [RuntimeUidBoundary] re-checks its own invariants below, and
 * [RuntimeWorkSupervisor] re-verifies the live process UID/pid on every call and
 * only ever acts on kernel-derived census facts. Forging an instance therefore
 * grants no authority the attacker did not already have as that UID's process.
 */
class RuntimeUidBoundary private constructor(
    val runtimeUid: Int,
    val coreUid: Int,
    val runtimePackageName: String,
    val corePackageName: String,
    val runtimeSignatureSha256: String,
    val coreSignatureSha256: String,
    val selfPid: Int,
    val verifiedAtMs: Long,
) {
    init {
        // Self-consistency: a value-forged instance is still refused.
        require(runtimeUid > 0 && coreUid > 0) { "resolved UIDs are required" }
        require(runtimeUid != coreUid) { "runtime and core UIDs must differ" }
        require(runtimePackageName != corePackageName) { "runtime and core packages must differ" }
        require(selfPid > 0) { "self pid must be resolved" }
        require(runtimeSignatureSha256.length == 64 && coreSignatureSha256.length == 64) {
            "signature digests must be complete SHA-256 hex"
        }
    }

    override fun toString(): String =
        "RuntimeUidBoundary(runtimeUid=$runtimeUid, coreUid=$coreUid, " +
            "runtime=$runtimePackageName, core=$corePackageName, selfPid=$selfPid)"

    /** The trusted validator. Allowlists are supplied by Main, never derived here. */
    companion object {

        /** Hex SHA-256 of a DER certificate, the form allowlists are written in. */
        fun digestOf(der: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(der)
                .joinToString("") { "%02x".format(it) }

        fun validate(
            corePackageName: String,
            coreSignatureSha256: String,
            runtimePackageName: String,
            runtimeSignatureSha256: String,
            selfUid: Int,
            selfPid: Int,
            reader: PackageMetadataReader,
            clock: SupervisorClock = WallClock,
        ): BoundaryCheck {
            val reasons = mutableListOf<String>()
            if (corePackageName.isBlank() || runtimePackageName.isBlank()) {
                return BoundaryCheck.Rejected(listOf("allowlist package names are blank"))
            }
            if (corePackageName == runtimePackageName) {
                reasons += "runtime package must be a different package from the credential core App"
            }
            if (coreSignatureSha256.length < 16 || runtimeSignatureSha256.length < 16) {
                reasons += "expected signature digests are missing or too short"
            }

            val core = runCatching { reader.read(corePackageName) }.getOrElse {
                reasons += "core package metadata threw (${it.javaClass.simpleName})"
                null
            }
            val runtime = runCatching { reader.read(runtimePackageName) }.getOrElse {
                reasons += "runtime package metadata threw (${it.javaClass.simpleName})"
                null
            }
            if (core == null) reasons += "core package metadata unavailable"
            if (runtime == null) reasons += "runtime package metadata unavailable"
            if (core == null || runtime == null) {
                return BoundaryCheck.Rejected(reasons.ifEmpty { listOf("package metadata unavailable") })
            }

            if (core.signatureSha256.none { it.equals(coreSignatureSha256, ignoreCase = true) }) {
                reasons += "core App signature does not match the allowlist"
            }
            if (runtime.signatureSha256.none { it.equals(runtimeSignatureSha256, ignoreCase = true) }) {
                reasons += "runtime package signature does not match the allowlist"
            }
            if (core.uid == runtime.uid) {
                reasons += "runtime UID ${runtime.uid} is not distinct from the core App UID"
            }
            if (selfUid != runtime.uid) {
                reasons += "this process UID $selfUid is not the allowlisted runtime UID ${runtime.uid}"
            }
            if (selfUid == core.uid) {
                reasons += "refusing to supervise inside the credential-bearing core App UID $selfUid"
            }
            if (selfPid <= 0) reasons += "self pid unresolved"

            val runtimeUidOwners = runCatching { reader.packagesForUid(runtime.uid) }.getOrNull()
            when {
                runtimeUidOwners == null -> reasons += "runtime UID owners unresolved"
                runtimeUidOwners != listOf(runtimePackageName) ->
                    reasons += "runtime UID ${runtime.uid} is not dedicated to $runtimePackageName: $runtimeUidOwners"
            }
            val coreUidOwners = runCatching { reader.packagesForUid(core.uid) }.getOrNull()
            if (coreUidOwners == null) reasons += "core UID owners unresolved"
            else if (!coreUidOwners.contains(corePackageName)) {
                reasons += "core UID is not owned by $corePackageName"
            }

            if (reasons.isNotEmpty()) return BoundaryCheck.Rejected(reasons)
            return BoundaryCheck.Accepted(
                RuntimeUidBoundary(
                    runtimeUid = runtime.uid,
                    coreUid = core.uid,
                    runtimePackageName = runtime.packageName,
                    corePackageName = core.packageName,
                    runtimeSignatureSha256 = runtimeSignatureSha256.lowercase(),
                    coreSignatureSha256 = coreSignatureSha256.lowercase(),
                    selfPid = selfPid,
                    verifiedAtMs = clock.nowMs(),
                ),
            )
        }
    }
}
