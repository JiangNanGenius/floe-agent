// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

/**
 * Pure validation for App-staged APK paths handed to the privileged package
 * installer. The App stages user-picked APKs into a location the shell/root
 * service can actually read; the model never supplies a host path, and this
 * policy is the fail-closed ceiling on what the typed install operation will
 * touch.
 *
 * Allowed trees are exactly the shared-storage family (including adopted
 * volumes and the shell-reachable app-specific external staging folder) plus
 * the classic `/data/local/tmp` shell staging area. App-private data,
 * platform trees and virtual filesystems are always refused, every path is
 * segment-normalized (no `..`, no NUL/control characters, bounded segments)
 * and the result is a clean absolute path that callers canonicalize again on
 * the device before opening.
 */
object StagedApkPolicy {

    const val MAX_APK_PATH = 900
    const val MAX_SEGMENT = 255
    const val MAX_SEGMENTS = 32
    const val MAX_APK_BYTES = 2L * 1024 * 1024 * 1024

    /**
     * Service-owned staging lives in ONE leaf directory per owning service
     * identity, created DIRECTLY under the pre-existing trusted
     * `/data/local/tmp`: `floe-staging-<uid>-<hostPackage>`. Neither backend
     * (root uid 0 / shell uid 2000) ever needs write permission on a
     * directory created by the other UID, so a Root->ADB owner switch never
     * strands the new owner's cache; old global or foreign directories stay
     * untouched.
     */
    const val SERVICE_STAGING_PARENT = "/data/local/tmp"

    /** Back-compat alias: the trusted parent itself is the staging ceiling. */
    const val SERVICE_STAGING_DIRECTORY = SERVICE_STAGING_PARENT

    /** Strict leaf-directory name: uid + authenticated package, both bounded. */
    private const val LEAF_PREFIX = "floe-staging-"
    private val DIGEST = Regex("^[0-9a-f]{64}$")
    private val PACKAGE_SEGMENT = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")
    private val UID_SEGMENT = Regex("^[0-9]{1,5}$")

    /** The exact owned leaf directory for one backend/host identity. */
    fun ownedStageRoot(backendUid: Int, hostPackage: String): String? {
        if (backendUid < 0 || backendUid > 99999) return null
        if (!PACKAGE_SEGMENT.matches(hostPackage)) return null
        if (hostPackage.length > MAX_SEGMENT) return null
        return "$SERVICE_STAGING_PARENT/$LEAF_PREFIX$backendUid-$hostPackage"
    }

    /** The exact digest-named path inside this owner's leaf storage. */
    fun ownedStagedPath(backendUid: Int, hostPackage: String, sha256: String): String? {
        val root = ownedStageRoot(backendUid, hostPackage) ?: return null
        if (!DIGEST.matches(sha256)) return null
        return "$root/$sha256.apk"
    }

    /** True when [path] sits inside this owner's leaf directory exactly. */
    fun isOwnedStagePath(path: String, backendUid: Int, hostPackage: String): Boolean {
        val root = ownedStageRoot(backendUid, hostPackage) ?: return false
        val rel = path.removePrefix("$root/")
        return path.startsWith("$root/") && rel.isNotEmpty() && !rel.contains('/')
    }

    /**
     * Shape check for a service-issued staged path recorded by the App: it
     * must be a digest-named file directly inside a `floe-staging-<uid>-
     * <pkg>` leaf of the trusted tmp parent. The service re-verifies
     * ownership and the full digest at installation; the App never stats
     * another UID's private storage.
     */
    fun isServiceStagedPath(path: String): Boolean {
        val normalized = normalizeStagedPath(path) ?: return false
        if (!normalized.startsWith("$SERVICE_STAGING_PARENT/")) return false
        val rel = normalized.removePrefix("$SERVICE_STAGING_PARENT/").split('/')
        if (rel.size != 2) return false
        val leaf = rel[0]
        if (!leaf.startsWith(LEAF_PREFIX)) return false
        val identity = leaf.removePrefix(LEAF_PREFIX).split('-', limit = 2)
        if (identity.size != 2) return false
        if (!UID_SEGMENT.matches(identity[0])) return false
        if (!PACKAGE_SEGMENT.matches(identity[1])) return false
        val file = rel[1]
        if (!file.endsWith(".apk")) return false
        return DIGEST.matches(file.removeSuffix(".apk"))
    }

    private val ALLOWED_PREFIXES = listOf(
        "/data/local/tmp",
        "/data/media",
        "/sdcard",
        "/storage/emulated",
        "/storage/self",
        "/mnt/expand",
    )

    private val DENIED_PREFIXES = listOf(
        "/data/data",
        "/data/user",
        "/data/user_de",
        "/data/misc",
        "/system",
        "/vendor",
        "/product",
        "/system_ext",
        "/odm",
        "/apex",
        "/proc",
        "/sys",
        "/dev",
    )

    /**
     * Returns the normalized absolute staged path, or null when [raw] is not
     * a plain staged-APK path under an allowed shared tree. No filesystem
     * access: canonicalization and existence checks happen device-side with
     * the service's own UID right before the install attempt.
     */
    fun normalizeStagedPath(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.length !in 2..MAX_APK_PATH) return null
        if (!trimmed.startsWith("/")) return null
        if (trimmed.any { it == '\u0000' || it.isISOControl() || it == '\\' }) return null
        val segments = trimmed.split('/').filter { it.isNotEmpty() }
        if (segments.isEmpty() || segments.size > MAX_SEGMENTS) return null
        if (segments.any { it == "." || it == ".." || it.length > MAX_SEGMENT }) return null

        val normalized = "/" + segments.joinToString("/")
        if (DENIED_PREFIXES.any { normalized == it || normalized.startsWith("$it/") }) {
            return null
        }
        if (ALLOWED_PREFIXES.none { normalized == it || normalized.startsWith("$it/") }) {
            return null
        }
        return normalized
    }

    /** True when [normalizedPath] passes [normalizeStagedPath]. */
    fun isStagedPath(normalizedPath: String): Boolean = normalizeStagedPath(normalizedPath) != null
}
