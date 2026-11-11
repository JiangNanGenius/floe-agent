// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

/**
 * Pure closed policy for the four typed permission/AppOps operations
 * (system.permissions.query/manage, system.appOps.query/manage).
 *
 * Everything the privileged service and the App host decide about shapes,
 * catalogs and SDK gates lives here so the exact rules are unit-testable
 * without an Android runtime. Platform constant values are mirrored locally
 * (the android.jar stubs are not callable from JVM tests); the service maps
 * the live PackageManager/AppOpsManager values onto these shapes at the
 * boundary, never the other way around.
 *
 * Command-name casing is load-bearing, not cosmetic: a dedicated Samsung/
 * API 33 read-only probe showed `appops get pkg camera` exits 255 with
 * "Unknown operation string: camera" while `CAMERA` and `android:camera`
 * both exit 0. The catalog therefore carries the canonical UPPERCASE
 * platform operation strings only.
 */
object PermissionOpsPolicy {

    // ---------------------------------------------------------- permissions

    /** Closed actions for system.permissions.manage. */
    const val ACTION_GRANT = "grant"
    const val ACTION_REVOKE = "revoke"
    val ACTIONS: Set<String> = setOf(ACTION_GRANT, ACTION_REVOKE)

    /** Manifest permission names share the dotted-segment shape of packages. */
    const val MAX_PERMISSION_NAME = 255
    val PERMISSION_NAME = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")

    // Mirror of android.content.pm.PackageManager protection constants. Keep
    // in sync with the platform values; only the bits the policy reads are
    // mirrored (base + development + privileged).
    const val PROTECTION_NORMAL = 0
    const val PROTECTION_DANGEROUS = 1
    const val PROTECTION_SIGNATURE = 2
    const val PROTECTION_MASK_BASE = 0x0F
    const val PROTECTION_FLAG_PRIVILEGED = 0x10
    const val PROTECTION_FLAG_DEVELOPMENT = 0x20

    /**
     * Bounded protection-level token for query rows and per-item receipts.
     * "dangerous" is the runtime group; "development" marks the development
     * permissions real ADB/Root may grant/revoke; signature/privileged/fixed
     * levels stay read-only disclosures.
     */
    fun protectionToken(protectionLevel: Int): String {
        val base = protectionLevel and PROTECTION_MASK_BASE
        val privileged = (protectionLevel and PROTECTION_FLAG_PRIVILEGED) != 0
        val development = (protectionLevel and PROTECTION_FLAG_DEVELOPMENT) != 0
        return when {
            base == PROTECTION_DANGEROUS && development -> "dangerous+development"
            base == PROTECTION_DANGEROUS -> "dangerous"
            development -> "development"
            base == PROTECTION_SIGNATURE -> "signature"
            privileged -> "privileged"
            base == PROTECTION_NORMAL -> "normal"
            else -> "other"
        }
    }

    /**
     * Only manifest-declared runtime (dangerous) or development permissions
     * are mutable through the real `pm grant/revoke --user` path this
     * service drives. Signature/privileged/fixed platform permissions refuse
     * with "permission_protected" before dispatch: the OS denial would
     * surface as a failure anyway, and the explicit refusal keeps the
     * per-item receipt bounded and honest. Returns null when mutable.
     */
    fun permissionMutable(protectionLevel: Int): String? {
        val base = protectionLevel and PROTECTION_MASK_BASE
        val development = (protectionLevel and PROTECTION_FLAG_DEVELOPMENT) != 0
        return when {
            base == PROTECTION_DANGEROUS -> null
            development -> null
            else -> "permission_protected"
        }
    }

    // ---------------------------------------------------------------- appops

    /**
     * One closed AppOps catalog entry. [opName] is the canonical UPPERCASE
     * platform operation string accepted by `appops get/set --user <u>
     * <pkg> <op>` in package form (never a UID). RUN_IN_BACKGROUND and
     * RUN_ANY_IN_BACKGROUND are deliberately separate entries: a dedicated
     * Samsung/API 33 probe shows BOTH are accepted, distinct operations
     * there — they are not a rename.
     */
    data class AppOpSpec(
        val token: String,
        val opName: String,
        val minSdk: Int,
    )

    /**
     * The closed practical AppOps catalog: camera, microphone, notification,
     * coarse/fine location, media/storage read+write, overlay, write-settings,
     * usage access, background execution (legacy and modern ops) and
     * install-package access. Tokens are the stable tool-facing names; op
     * names are the exact platform strings so the service can never invent
     * or free-type an operation.
     */
    val APP_OPS: List<AppOpSpec> = listOf(
        AppOpSpec("camera", "CAMERA", 28),
        AppOpSpec("microphone", "RECORD_AUDIO", 28),
        AppOpSpec("notification", "POST_NOTIFICATION", 28),
        AppOpSpec("location-coarse", "COARSE_LOCATION", 28),
        AppOpSpec("location-fine", "FINE_LOCATION", 28),
        AppOpSpec("storage-read", "READ_EXTERNAL_STORAGE", 28),
        AppOpSpec("storage-write", "WRITE_EXTERNAL_STORAGE", 28),
        AppOpSpec("overlay", "SYSTEM_ALERT_WINDOW", 28),
        AppOpSpec("write-settings", "WRITE_SETTINGS", 28),
        AppOpSpec("usage-access", "GET_USAGE_STATS", 28),
        AppOpSpec("background-run", "RUN_IN_BACKGROUND", 28),
        AppOpSpec("background-run-any", "RUN_ANY_IN_BACKGROUND", 28),
        AppOpSpec("install-packages", "REQUEST_INSTALL_PACKAGES", 28),
    )

    val APP_OP_TOKENS: Set<String> = APP_OPS.map { it.token }.toSet()

    /** Resolve a closed catalog token at the real device SDK. */
    fun appOp(token: String, sdk: Int): AppOpSpec? =
        APP_OPS.firstOrNull { it.token == token }?.takeIf { sdk >= it.minSdk }

    /** Closed AppOps modes. "default" restores platform/UID behavior; it is
     *  never an arbitrary allow. */
    val MODES: Set<String> = setOf("allow", "ignore", "deny", "default", "foreground")

    fun modeSupported(mode: String, sdk: Int): Boolean =
        mode in MODES && (mode != "foreground" || sdk >= 29)

    // ---------------------------------------------------- appops get parsing

    /**
     * Parsed view of ONE bounded single-operation `appops get --user <u>
     * <pkg> <OP>` output (verified shapes from a dedicated Samsung/API 33
     * read-only probe; other builds may print the legacy bare forms, which
     * are accepted too):
     *
     *  - `No operations.` — the package holds no recorded entries (marker).
     *  - `Default mode: allow` — the platform default for this op.
     *  - `Uid mode: FINE_LOCATION: foreground` — UID-level mode; newer
     *    builds repeat the op name and may append ` (UID only)`.
     *  - `FINE_LOCATION: allow; time=...; rejectTime=...` — per-package
     *    override with a semicolon-delimited tail (a mode word of `default`
     *    here is an explicit default entry, still an override row).
     *  - legacy `Uid mode: allow` (no repeated op name) — UID-level mode.
     *
     * [overrideMode] is the per-package mode (null when no per-package row
     * printed); [uidMode] the UID-level mode; [defaultMode] the platform
     * default line. [unparseable] is set when non-empty content cannot be
     * classified: callers must refuse/fail closed with that flag instead of
     * reporting an absent-looking "default" that was never established.
     */
    data class AppOpsGet(
        val overrideMode: String?,
        val uidMode: String?,
        val defaultMode: String?,
        val noOperations: Boolean,
        val unparseable: Boolean,
    )

    fun parseAppOpsGet(output: String, opName: String): AppOpsGet {
        var overrideMode: String? = null
        var uidMode: String? = null
        var defaultMode: String? = null
        var noOperations = false
        var sawRecognized = false
        var unparseable = false
        for (rawLine in output.lineSequence()) {
            val line = rawLine.trim()
            if (line.isEmpty()) continue
            when {
                line.equals("No operations.", ignoreCase = true) -> {
                    noOperations = true
                    sawRecognized = true
                }
                line.startsWith("Default mode:", ignoreCase = true) -> {
                    val mode = normalizeMode(line.substringAfter(':'))
                    if (mode == null) unparseable = true else defaultMode = mode
                    sawRecognized = true
                }
                line.startsWith("Uid mode:", ignoreCase = true) -> {
                    // Newer: "Uid mode: <OP>: <mode>[ (UID only)]"; legacy:
                    // "Uid mode: <mode>". The repeated op name (when present)
                    // must be the requested op, else the line belongs to a
                    // different operation and cannot be trusted for this op.
                    val rest = line.substringAfter(':').trim()
                    val secondColon = rest.indexOf(':')
                    val candidate: String? = if (secondColon > 0) {
                        val name = rest.substring(0, secondColon).trim()
                        if (name.equals(opName, ignoreCase = true)) {
                            rest.substring(secondColon + 1)
                        } else {
                            // A UID-mode line for a DIFFERENT op inside a
                            // single-op response is ambiguous: fail closed.
                            null
                        }
                    } else {
                        rest
                    }
                    if (candidate == null) {
                        unparseable = true
                    } else {
                        val mode = normalizeMode(candidate)
                        if (candidate.isNotEmpty() && mode == null) {
                            unparseable = true
                        } else if (mode != null) {
                            uidMode = mode
                        }
                    }
                    sawRecognized = true
                }
                else -> {
                    val colon = line.indexOf(':')
                    if (colon > 0 && line.substring(0, colon).trim()
                            .equals(opName, ignoreCase = true)
                    ) {
                        val mode = normalizeMode(line.substring(colon + 1))
                        if (mode == null) unparseable = true else overrideMode = mode
                        sawRecognized = true
                    } else {
                        // Content we cannot classify: fail closed instead of
                        // letting an unknown line look like "no override".
                        unparseable = true
                    }
                }
            }
        }
        if (!sawRecognized && !unparseable) {
            // Completely empty output for a single-op query establishes
            // nothing; refuse rather than guess.
            unparseable = true
        }
        return AppOpsGet(overrideMode, uidMode, defaultMode, noOperations, unparseable)
    }

    /**
     * Map one raw `appops` mode field onto the closed token set. The field
     * may carry semicolon-delimited tails ("allow; time=..."), parenthetical
     * annotations ("foreground (UID only)") or whitespace; the mode word is
     * the leading token. Unknown words return null.
     */
    fun normalizeMode(raw: String): String? {
        val word = raw
            .trim()
            .substringBefore(';')
            .substringBefore(' ')
            .substringBefore('(')
            .trim()
            .lowercase()
        return when (word) {
            "allow", "ignore", "deny", "default", "foreground" -> word
            else -> null
        }
    }

    // ----------------------------------------------------------- shared uid

    /**
     * Mutations refuse when the target UID hosts more than one distinct
     * package: UID-scoped runtime grants/AppOps entries cannot avoid
     * collateral effect on the sibling, so the package-form argv alone is
     * not proof of a safe target. Pure and count-based so the decision is
     * unit-testable; the service resolves the real sibling set from the
     * live PackageManager. Read-only queries may still disclose honestly.
     */
    fun sharedUidRefusal(distinctPackageCount: Int): String? =
        if (distinctPackageCount > 1) "shared_uid_refused" else null
}
